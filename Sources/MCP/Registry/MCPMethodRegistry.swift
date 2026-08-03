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

public enum MCPHTTPNameSource: String, Sendable, Hashable {
  case none
  case toolName
  case promptName
  case resourceURI
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

  public init(
    name: String,
    direction: MCPMethodDirection,
    requiredServerCapability: MCPServerCapabilityPath = .none,
    requiredClientCapability: MCPClientCapabilityPath = .none,
    cacheability: MCPCacheability = .none,
    httpNameSource: MCPHTTPNameSource = .none,
    allowsMRTR: Bool = false,
    extensionResultTypes: Set<String> = [],
    isExtension: Bool = false
  ) throws {
    guard MCPMethodRegistry.isValidMethodName(name, extensionMethod: false),
      !isExtension || !MCPMethodRegistry.isRetiredCoreMethodName(name)
    else {
      throw MCPRegistryError.invalidMethodName(name)
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
      isExtension: isExtension
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
    isExtension: Bool = false
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
    case .toolName, .promptName: key = "name"
    case .resourceURI: key = "uri"
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
  case invalidExtensionResultType
  case duplicateMethod(String)
  case standardMethodCollision(String)
  case unsupportedMethod(String)
  case wrongDirection(method: String, expected: MCPMethodDirection, actual: MCPMethodDirection)

  public var description: String {
    switch self {
    case .invalidMethodName(let name): "Invalid MCP method name: \(name)"
    case .invalidExtensionResultType: "Invalid extension resultType"
    case .duplicateMethod(let name): "Duplicate MCP method: \(name)"
    case .standardMethodCollision(let name): "Extension collides with standard method: \(name)"
    case .unsupportedMethod(let name): "Unsupported MCP method: \(name)"
    case .wrongDirection(let method, let expected, let actual):
      "MCP method \(method) has direction \(actual.rawValue), expected \(expected.rawValue)"
    }
  }
}

public struct MCPMethodRegistry: Sendable {
  private let descriptorsByName: [String: MCPMethodDescriptor]

  public init(extensionMethods: [MCPMethodDescriptor] = []) throws {
    let standards = Self.standardDescriptors
    var result = Dictionary(uniqueKeysWithValues: standards.map { ($0.name, $0) })
    for descriptor in extensionMethods {
      guard descriptor.isExtension else {
        throw MCPRegistryError.invalidMethodName(descriptor.name)
      }
      guard Self.standardDescriptorNames.contains(descriptor.name) == false else {
        throw MCPRegistryError.standardMethodCollision(descriptor.name)
      }
      guard Self.isValidMethodName(descriptor.name, extensionMethod: true) else {
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

  // These MCP-owned method names existed before the stateless 2026-07-28 core. They are not
  // extension namespaces and cannot be reintroduced through the generic extension registry.
  fileprivate static func isRetiredCoreMethodName(_ value: String) -> Bool {
    retiredCoreMethodNames.contains(value)
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
    "tools/call", capability: .tools, httpName: .toolName, mrtr: true)
  fileprivate static let listPromptsDescriptor = request(
    "prompts/list", capability: .prompts, cache: .listing)
  fileprivate static let getPromptDescriptor = request(
    "prompts/get", capability: .prompts, httpName: .promptName, mrtr: true)
  fileprivate static let listResourcesDescriptor = request(
    "resources/list", capability: .resources, cache: .listing)
  fileprivate static let listResourceTemplatesDescriptor = request(
    "resources/templates/list", capability: .resources, cache: .listing)
  fileprivate static let readResourceDescriptor = request(
    "resources/read",
    capability: .resources,
    cache: .resourceRead,
    httpName: .resourceURI,
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
