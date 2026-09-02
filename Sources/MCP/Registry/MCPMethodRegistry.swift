import Foundation

public enum MCPMethodDirection: String, Sendable, Hashable {
  case clientToServerRequest
  case clientToServerNotification
  case serverToClientNotification
  case bidirectionalNotification
}

public enum MCPServerCapabilityPath: String, Sendable, Hashable {
  case none
  case tools
  case prompts
  case resources
  case completions
}

public enum MCPClientCapabilityPath: String, Sendable, Hashable {
  case none
  case elicitationForm
  case elicitationURL
}

public enum MCPCacheability: String, Sendable, Hashable {
  case none
  case discover
  case listing
  case resourceRead
}

public enum MCPHTTPNameSource: Sendable, Hashable {
  case none
  case parameter(String)
}

public struct MCPMethodDescriptor: Sendable, Hashable {
  public let name: String
  public let direction: MCPMethodDirection
  public let requiredServerCapability: MCPServerCapabilityPath
  public let requiredClientCapability: MCPClientCapabilityPath
  public let cacheability: MCPCacheability
  public let httpNameSource: MCPHTTPNameSource
  public let allowsMRTR: Bool
  public let extensionResultTypes: Set<String>
  public let isExtension: Bool
  /// Identifies the MCP extension that owns an otherwise core-shaped method or augments a
  /// standard method. Namespaced vendor methods may continue to omit this value.
  public let extensionIdentifier: String?

  public init(
    name: String,
    direction: MCPMethodDirection,
    requiredServerCapability: MCPServerCapabilityPath = .none,
    requiredClientCapability: MCPClientCapabilityPath = .none,
    cacheability: MCPCacheability = .none,
    httpNameSource: MCPHTTPNameSource = .none,
    allowsMRTR: Bool = false,
    extensionResultTypes: Set<String> = [],
    isExtension: Bool = false,
    extensionIdentifier: String? = nil
  ) throws {
    let namespacedExtension = MCPMethodRegistry.isValidMethodName(name, extensionMethod: true)
    let standardAugmentation = isExtension && MCPMethodRegistry.isStandardMethodName(name)
    let officialExtensionMethod =
      isExtension
      && extensionIdentifier.map(MCPMethodRegistry.isOfficialExtensionIdentifier) == true
      && MCPMethodRegistry.isValidMethodName(name, extensionMethod: false)
    let validName =
      isExtension
      ? namespacedExtension || standardAugmentation || officialExtensionMethod
      : MCPMethodRegistry.isValidMethodName(name, extensionMethod: false)
    guard validName, !isExtension || !MCPMethodRegistry.isRetiredCoreMethodName(name) else {
      throw MCPRegistryError.invalidMethodName(name)
    }
    if case .parameter(let parameter) = httpNameSource, parameter.isEmpty {
      throw MCPJSONError.invalidField(
        field: "httpNameSource", reason: "parameter key must not be empty")
    }
    if let extensionIdentifier {
      guard isExtension,
        MCPMethodRegistry.isValidExtensionIdentifier(extensionIdentifier)
      else {
        throw MCPRegistryError.invalidExtensionIdentifier(extensionIdentifier)
      }
    }
    guard
      extensionResultTypes.allSatisfy({ !$0.isEmpty && $0 != "complete" && $0 != "input_required" })
    else {
      throw MCPRegistryError.invalidExtensionResultType
    }
    self.init(
      validatedName: name,
      direction: direction,
      requiredServerCapability: requiredServerCapability,
      requiredClientCapability: requiredClientCapability,
      cacheability: cacheability,
      httpNameSource: httpNameSource,
      allowsMRTR: allowsMRTR,
      extensionResultTypes: extensionResultTypes,
      isExtension: isExtension,
      extensionIdentifier: extensionIdentifier
    )
  }

  fileprivate init(
    validatedName name: String,
    direction: MCPMethodDirection,
    requiredServerCapability: MCPServerCapabilityPath = .none,
    requiredClientCapability: MCPClientCapabilityPath = .none,
    cacheability: MCPCacheability = .none,
    httpNameSource: MCPHTTPNameSource = .none,
    allowsMRTR: Bool = false,
    extensionResultTypes: Set<String> = [],
    isExtension: Bool = false,
    extensionIdentifier: String? = nil
  ) {
    self.name = name
    self.direction = direction
    self.requiredServerCapability = requiredServerCapability
    self.requiredClientCapability = requiredClientCapability
    self.cacheability = cacheability
    self.httpNameSource = httpNameSource
    self.allowsMRTR = allowsMRTR
    self.extensionResultTypes = extensionResultTypes
    self.isExtension = isExtension
    self.extensionIdentifier = extensionIdentifier
  }

  public func accepts(_ requestedDirection: MCPMethodDirection) -> Bool {
    direction == requestedDirection
      || (direction == .bidirectionalNotification
        && (requestedDirection == .clientToServerNotification
          || requestedDirection == .serverToClientNotification))
  }

  public func httpName(from params: [String: MCPJSONValue]) throws -> String? {
    let key: String
    switch httpNameSource {
    case .none: return nil
    case .parameter(let parameter): key = parameter
    }
    guard !key.isEmpty else {
      throw MCPJSONError.invalidField(
        field: "Mcp-Name", reason: "parameter key must not be empty")
    }
    guard case .string(let value)? = params[key], !value.isEmpty else {
      throw MCPJSONError.invalidField(field: key, reason: "required for Mcp-Name")
    }
    return value
  }
}

public struct MCPMethod<Params: MCPJSONModel, Result: MCPJSONModel>: Sendable {
  public let descriptor: MCPMethodDescriptor

  public init(_ descriptor: MCPMethodDescriptor) { self.descriptor = descriptor }

  public func decodeParams(_ value: MCPJSONValue) throws -> Params { try Params(json: value) }
  public func decodeResult(_ value: MCPJSONValue) throws -> Result { try Result(json: value) }
  public func encodeParams(_ value: Params) -> MCPJSONValue { value.json }
  public func encodeResult(_ value: Result) -> MCPJSONValue { value.json }
}

public enum MCPRegistryError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidMethodName(String)
  case invalidExtensionIdentifier(String)
  case invalidExtensionResultType
  case duplicateMethod(String)
  case standardMethodCollision(String)
  case invalidStandardAugmentation(String)
  case unsupportedMethod(String)
  case wrongDirection(method: String, expected: MCPMethodDirection, actual: MCPMethodDirection)
  case registryMismatch

  public var description: String {
    switch self {
    case .invalidMethodName(let name): "Invalid MCP method name: \(name)"
    case .invalidExtensionIdentifier(let identifier):
      "Invalid MCP extension identifier: \(identifier)"
    case .invalidExtensionResultType: "Invalid extension resultType"
    case .duplicateMethod(let name): "Duplicate MCP method: \(name)"
    case .standardMethodCollision(let name): "Extension collides with standard method: \(name)"
    case .invalidStandardAugmentation(let name):
      "Invalid extension augmentation of standard MCP method: \(name)"
    case .unsupportedMethod(let name): "Unsupported MCP method: \(name)"
    case .wrongDirection(let method, let expected, let actual):
      "MCP method \(method) has direction \(actual.rawValue), expected \(expected.rawValue)"
    case .registryMismatch:
      "MCP client and transport method registries must match"
    }
  }
}

public struct MCPMethodRegistry: Sendable, Equatable {
  private let descriptorsByName: [String: MCPMethodDescriptor]

  public init(extensionMethods: [MCPMethodDescriptor] = []) throws {
    let standards = Self.standardDescriptors
    var result = Dictionary(uniqueKeysWithValues: standards.map { ($0.name, $0) })
    for descriptor in extensionMethods {
      guard descriptor.isExtension else {
        throw MCPRegistryError.invalidMethodName(descriptor.name)
      }
      if let standard = result[descriptor.name],
        Self.standardDescriptorNames.contains(descriptor.name)
      {
        guard descriptor.extensionIdentifier != nil else {
          throw MCPRegistryError.standardMethodCollision(descriptor.name)
        }
        result[descriptor.name] = try Self.augment(standard: standard, with: descriptor)
        continue
      }
      guard Self.isValidMethodName(name: descriptor.name, descriptor: descriptor) else {
        throw MCPRegistryError.invalidMethodName(descriptor.name)
      }
      guard result[descriptor.name] == nil else {
        throw MCPRegistryError.duplicateMethod(descriptor.name)
      }
      result[descriptor.name] = descriptor
    }
    descriptorsByName = result
  }

  private init(validatedDescriptors: [MCPMethodDescriptor]) {
    descriptorsByName = Dictionary(uniqueKeysWithValues: validatedDescriptors.map { ($0.name, $0) })
  }

  public static let standard = MCPMethodRegistry(validatedDescriptors: standardDescriptors)

  public var descriptors: [MCPMethodDescriptor] {
    descriptorsByName.values.sorted { $0.name < $1.name }
  }

  public func descriptor(for method: String) -> MCPMethodDescriptor? {
    descriptorsByName[method]
  }

  public func require(
    _ method: String,
    direction: MCPMethodDirection = .clientToServerRequest
  ) throws -> MCPMethodDescriptor {
    guard let descriptor = descriptor(for: method) else {
      throw MCPRegistryError.unsupportedMethod(method)
    }
    guard descriptor.accepts(direction) else {
      throw MCPRegistryError.wrongDirection(
        method: method, expected: direction, actual: descriptor.direction)
    }
    return descriptor
  }

  public var requestMethods: [MCPMethodDescriptor] {
    descriptors.filter { $0.direction == .clientToServerRequest }
  }

  public var serverNotificationMethods: [MCPMethodDescriptor] {
    descriptors.filter {
      $0.direction == .serverToClientNotification || $0.direction == .bidirectionalNotification
    }
  }

  public static func isValidMethodName(_ value: String, extensionMethod: Bool) -> Bool {
    guard !value.isEmpty, !value.contains(where: { $0.isWhitespace || $0.isNewline }) else {
      return false
    }
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
    if extensionMethod {
      guard !isRetiredCoreMethodName(value) else { return false }
      return value.contains(".") || parts.count >= 3
    }
    return true
  }

  public static func isValidExtensionIdentifier(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return false }
    let labels = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard labels.count >= 2, labels.allSatisfy(isValidExtensionPrefixLabel) else { return false }
    return isValidExtensionName(parts[1])
  }

  /// Official MCP extensions are installed through their owning product's package-scoped
  /// registration. This predicate is intentionally not public: callers may validate identifier
  /// syntax, but they cannot claim ownership of the official namespace through the raw builder.
  package static func isOfficialExtensionIdentifier(_ value: String) -> Bool {
    value.hasPrefix("io.modelcontextprotocol/") && isValidExtensionIdentifier(value)
  }

  package static func isOfficialExtensionDescriptor(_ descriptor: MCPMethodDescriptor) -> Bool {
    if let identifier = descriptor.extensionIdentifier {
      return isOfficialExtensionIdentifier(identifier)
    }
    return descriptor.name.hasPrefix("io.modelcontextprotocol/")
  }

  private static func isValidMethodName(
    name: String,
    descriptor: MCPMethodDescriptor
  ) -> Bool {
    if isValidMethodName(name, extensionMethod: true) { return true }
    if standardDescriptorNames.contains(name) { return descriptor.extensionIdentifier != nil }
    guard let identifier = descriptor.extensionIdentifier,
      isOfficialExtensionIdentifier(identifier)
    else {
      return false
    }
    return isValidMethodName(name, extensionMethod: false)
  }

  private static func augment(
    standard: MCPMethodDescriptor,
    with extensionDescriptor: MCPMethodDescriptor
  ) throws -> MCPMethodDescriptor {
    guard let extensionIdentifier = extensionDescriptor.extensionIdentifier,
      isValidExtensionIdentifier(extensionIdentifier),
      !extensionDescriptor.extensionResultTypes.isEmpty,
      extensionDescriptor.direction == standard.direction,
      extensionDescriptor.requiredServerCapability == standard.requiredServerCapability,
      extensionDescriptor.requiredClientCapability == standard.requiredClientCapability,
      extensionDescriptor.cacheability == standard.cacheability,
      extensionDescriptor.httpNameSource == standard.httpNameSource,
      extensionDescriptor.allowsMRTR == standard.allowsMRTR
    else {
      throw MCPRegistryError.invalidStandardAugmentation(standard.name)
    }
    return MCPMethodDescriptor(
      validatedName: standard.name,
      direction: standard.direction,
      requiredServerCapability: standard.requiredServerCapability,
      requiredClientCapability: standard.requiredClientCapability,
      cacheability: standard.cacheability,
      httpNameSource: standard.httpNameSource,
      allowsMRTR: standard.allowsMRTR,
      extensionResultTypes: standard.extensionResultTypes.union(
        extensionDescriptor.extensionResultTypes),
      isExtension: false,
      extensionIdentifier: nil
    )
  }

  // These MCP-owned method names existed before the stateless 2026-07-28 core. They are not
  // extension namespaces and cannot be reintroduced through the generic extension registry.
  fileprivate static func isRetiredCoreMethodName(_ value: String) -> Bool {
    retiredCoreMethodNames.contains(value)
  }

  fileprivate static func isStandardMethodName(_ value: String) -> Bool {
    standardDescriptorNames.contains(value)
  }

  private static let retiredCoreMethodNames: Set<String> = [
    "notifications/elicitation/complete",
    "notifications/roots/list_changed",
    "notifications/tasks/status",
  ]

  fileprivate static let discoverDescriptor = request("server/discover", cache: .discover)
  fileprivate static let listToolsDescriptor = request(
    "tools/list", capability: .tools, cache: .listing)
  fileprivate static let callToolDescriptor = request(
    "tools/call", capability: .tools, httpName: .parameter("name"), mrtr: true)
  fileprivate static let listPromptsDescriptor = request(
    "prompts/list", capability: .prompts, cache: .listing)
  fileprivate static let getPromptDescriptor = request(
    "prompts/get", capability: .prompts, httpName: .parameter("name"), mrtr: true)
  fileprivate static let listResourcesDescriptor = request(
    "resources/list", capability: .resources, cache: .listing)
  fileprivate static let listResourceTemplatesDescriptor = request(
    "resources/templates/list", capability: .resources, cache: .listing)
  fileprivate static let readResourceDescriptor = request(
    "resources/read",
    capability: .resources,
    cache: .resourceRead,
    httpName: .parameter("uri"),
    mrtr: true
  )
  fileprivate static let completeDescriptor = request(
    "completion/complete", capability: .completions)
  fileprivate static let listenDescriptor = request("subscriptions/listen")

  private static let standardDescriptors: [MCPMethodDescriptor] = [
    discoverDescriptor,
    listToolsDescriptor,
    callToolDescriptor,
    listPromptsDescriptor,
    getPromptDescriptor,
    listResourcesDescriptor,
    listResourceTemplatesDescriptor,
    readResourceDescriptor,
    completeDescriptor,
    listenDescriptor,
    bidirectionalNotification("notifications/cancelled"),
    serverNotification("notifications/progress"),
    serverNotification("notifications/message"),
    serverNotification("notifications/subscriptions/acknowledged"),
    serverNotification("notifications/tools/list_changed"),
    serverNotification("notifications/prompts/list_changed"),
    serverNotification("notifications/resources/list_changed"),
    serverNotification("notifications/resources/updated"),
  ]

  private static let standardDescriptorNames = Set(standardDescriptors.map(\.name))

  private static func request(
    _ name: String,
    capability: MCPServerCapabilityPath = .none,
    cache: MCPCacheability = .none,
    httpName: MCPHTTPNameSource = .none,
    mrtr: Bool = false
  ) -> MCPMethodDescriptor {
    MCPMethodDescriptor(
      validatedName: name,
      direction: .clientToServerRequest,
      requiredServerCapability: capability,
      cacheability: cache,
      httpNameSource: httpName,
      allowsMRTR: mrtr
    )
  }

  private static func serverNotification(_ name: String) -> MCPMethodDescriptor {
    MCPMethodDescriptor(validatedName: name, direction: .serverToClientNotification)
  }

  private static func bidirectionalNotification(_ name: String) -> MCPMethodDescriptor {
    MCPMethodDescriptor(validatedName: name, direction: .bidirectionalNotification)
  }

  private static func isValidExtensionPrefixLabel(_ value: Substring) -> Bool {
    guard let first = value.utf8.first, let last = value.utf8.last,
      isASCIIAlpha(first), isASCIIAlphanumeric(last)
    else { return false }
    return value.utf8.allSatisfy { isASCIIAlphanumeric($0) || $0 == 0x2D }
  }

  private static func isValidExtensionName(_ value: Substring) -> Bool {
    guard let first = value.utf8.first, let last = value.utf8.last,
      isASCIIAlphanumeric(first), isASCIIAlphanumeric(last)
    else { return false }
    return value.utf8.allSatisfy {
      isASCIIAlphanumeric($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E
    }
  }

  private static func isASCIIAlpha(_ value: UInt8) -> Bool {
    (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
  }

  private static func isASCIIAlphanumeric(_ value: UInt8) -> Bool {
    isASCIIAlpha(value) || (0x30...0x39).contains(value)
  }
}

/// A package-scoped proof that an official extension owns a method set and capability value.
/// Public consumers can still construct client/HTTP registries from descriptors, but only the
/// owning product can pass this validated registration to `MCPServerBuilder`.
package struct MCPOfficialExtensionRegistration: Sendable {
  package let identifier: String
  package let methods: [MCPMethodDescriptor]
  package let capability: MCPJSONValue

  package init(
    identifier: String,
    methods: [MCPMethodDescriptor],
    capability: MCPJSONValue
  ) throws {
    guard MCPMethodRegistry.isOfficialExtensionIdentifier(identifier),
      !methods.isEmpty,
      Set(methods.map(\.name)).count == methods.count,
      methods.allSatisfy({
        $0.isExtension && $0.extensionIdentifier == identifier
      }),
      case .object = capability
    else {
      throw MCPServerBuildError.untrustedOfficialExtension(identifier)
    }

    // Re-run all ordinary registry validation before the capability and descriptors become an
    // atomic server-builder installation.
    _ = try MCPMethodRegistry(extensionMethods: methods)
    self.identifier = identifier
    self.methods = methods
    self.capability = capability
  }
}

public enum MCPStandardMethods {
  public static let discover = MCPMethod<MCPDiscoverParams, MCPDiscoverResult>(
    MCPMethodRegistry.discoverDescriptor)
  public static let listTools = MCPMethod<MCPListToolsParams, MCPListToolsResult>(
    MCPMethodRegistry.listToolsDescriptor)
  public static let callTool = MCPMethod<MCPCallToolParams, MCPCallToolResult>(
    MCPMethodRegistry.callToolDescriptor)
  public static let listPrompts = MCPMethod<MCPListPromptsParams, MCPListPromptsResult>(
    MCPMethodRegistry.listPromptsDescriptor)
  public static let getPrompt = MCPMethod<MCPGetPromptParams, MCPGetPromptResult>(
    MCPMethodRegistry.getPromptDescriptor)
  public static let listResources = MCPMethod<MCPListResourcesParams, MCPListResourcesResult>(
    MCPMethodRegistry.listResourcesDescriptor)
  public static let listResourceTemplates = MCPMethod<
    MCPListResourceTemplatesParams, MCPListResourceTemplatesResult
  >(MCPMethodRegistry.listResourceTemplatesDescriptor)
  public static let readResource = MCPMethod<MCPReadResourceParams, MCPReadResourceResult>(
    MCPMethodRegistry.readResourceDescriptor)
  public static let complete = MCPMethod<MCPCompleteParams, MCPCompleteResult>(
    MCPMethodRegistry.completeDescriptor)
  public static let listen = MCPMethod<MCPSubscriptionsListenParams, MCPSubscriptionsListenResult>(
    MCPMethodRegistry.listenDescriptor)
}
