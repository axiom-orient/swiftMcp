import Foundation

public struct MCPProtocolVersion: Sendable, Hashable, RawRepresentable, CustomStringConvertible {
  public let rawValue: String

  private init(unchecked rawValue: String) { self.rawValue = rawValue }

  public init?(rawValue: String) {
    guard rawValue == Self.current.rawValue else { return nil }
    self.rawValue = rawValue
  }

  public static let current = MCPProtocolVersion(unchecked: "2026-07-28")
  public var description: String { rawValue }
}

public enum MCPMetaKey {
  public static let progressToken = "progressToken"
  public static let protocolVersion = "io.modelcontextprotocol/protocolVersion"
  public static let clientInfo = "io.modelcontextprotocol/clientInfo"
  public static let clientCapabilities = "io.modelcontextprotocol/clientCapabilities"
  public static let serverInfo = "io.modelcontextprotocol/serverInfo"
  public static let subscriptionID = "io.modelcontextprotocol/subscriptionId"
  public static let traceparent = "traceparent"
  public static let tracestate = "tracestate"
  public static let baggage = "baggage"

  public static let logLevel = "io.modelcontextprotocol/logLevel"

  static let requestReserved: Set<String> = [
    progressToken, protocolVersion, clientInfo, clientCapabilities,
    serverInfo, subscriptionID, logLevel,
    traceparent, tracestate, baggage,
  ]
}

/// The per-request logging threshold defined by the base protocol.
///
/// This field is deprecated by MCP 2026-07-28 but remains interoperable for the specification's
/// deprecation window. A request that omits it has explicitly opted out of protocol log messages.
public enum MCPLoggingLevel: String, Sendable, Hashable, CaseIterable, MCPJSONModel {
  case debug, info, notice, warning, error, critical, alert, emergency

  public init(json: MCPJSONValue) throws {
    guard case .string(let value) = json, let level = Self(rawValue: value) else {
      throw MCPJSONError.invalidField(field: MCPMetaKey.logLevel, reason: "invalid logging level")
    }
    self = level
  }

  public var json: MCPJSONValue { .string(rawValue) }

  var severity: Int {
    switch self {
    case .debug: 0
    case .info: 1
    case .notice: 2
    case .warning: 3
    case .error: 4
    case .critical: 5
    case .alert: 6
    case .emergency: 7
    }
  }
}

public struct MCPImplementation: Sendable, Hashable, MCPJSONModel {
  public var name: String
  public var version: String
  public var title: String?
  public var descriptionText: String?
  public var websiteURL: String?
  public var icons: [MCPIcon]

  public init(
    name: String,
    version: String,
    title: String? = nil,
    description: String? = nil,
    websiteURL: String? = nil,
    icons: [MCPIcon] = []
  ) throws {
    guard !name.isEmpty else {
      throw MCPJSONError.invalidField(field: "name", reason: "must not be empty")
    }
    guard !version.isEmpty else {
      throw MCPJSONError.invalidField(field: "version", reason: "must not be empty")
    }
    self.name = name
    self.version = version
    self.title = title
    self.descriptionText = description
    self.websiteURL = websiteURL
    self.icons = icons
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    name = try object.requiredNonEmptyString("name")
    version = try object.requiredNonEmptyString("version")
    title = try object.optionalString("title")
    descriptionText = try object.optionalString("description")
    websiteURL = try object.optionalString("websiteUrl")
    icons = try object.optionalArray("icons")?.map(MCPIcon.init(json:)) ?? []
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("name", .string(name)),
      ("title", title.map(MCPJSONValue.string)),
      ("description", descriptionText.map(MCPJSONValue.string)),
      ("version", .string(version)),
      ("websiteUrl", websiteURL.map(MCPJSONValue.string)),
      ("icons", icons.isEmpty ? nil : .array(icons.map(\.json))),
    ])
  }
}

public struct MCPIcon: Sendable, Hashable, MCPJSONModel {
  /// Icon source URI. The stored properties are immutable so a decoded icon cannot lose the
  /// scheme guarantee that `init` established.
  public let source: String
  public let mimeType: String?
  public let sizes: [String]
  public let theme: String?

  public init(
    source: String,
    mimeType: String? = nil,
    sizes: [String] = [],
    theme: String? = nil
  ) throws {
    guard theme == nil || theme == "light" || theme == "dark" else {
      throw MCPJSONError.invalidField(field: "theme", reason: "expected light or dark")
    }
    try Self.validateSource(source)
    if let mimeType, !Self.isImageMediaType(mimeType) {
      throw MCPJSONError.invalidField(
        field: "mimeType",
        reason: "icon mimeType must be an image/* media type"
      )
    }
    self.source = source
    self.mimeType = mimeType
    self.sizes = sizes
    self.theme = theme
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let source = try object.requiredNonEmptyString("src")
    let mimeType = try object.optionalString("mimeType")
    let sizes: [String] =
      try object.optionalArray("sizes")?.map { value in
        guard case .string(let size) = value else {
          throw MCPJSONError.expectedString(field: "sizes[]")
        }
        return size
      } ?? []
    try self.init(
      source: source,
      mimeType: mimeType,
      sizes: sizes,
      theme: try object.optionalString("theme")
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("src", .string(source)),
      ("mimeType", mimeType.map(MCPJSONValue.string)),
      ("sizes", sizes.isEmpty ? nil : mcpStringArray(sizes)),
      ("theme", theme.map(MCPJSONValue.string)),
    ])
  }

  /// MCP requires icon consumers to reject sources that use unsafe schemes such as `javascript:`,
  /// `file:`, `ftp:`, `ws:`, or a local application scheme. Rejecting them here keeps a hostile
  /// server from handing an executable or local-file URI to an unsuspecting host application.
  ///
  /// An allowed scheme is necessary but not sufficient. A bare `data:text/html,<script>…` carries
  /// the `data:` scheme yet renders as markup in any host that loads the source into a web view,
  /// so the payload's media type is checked too; and a bare `https:` or `https:foo` names no host,
  /// leaving the reference for a renderer to resolve against whatever base URL it happens to hold.
  /// Both forms are rejected here rather than left for each consumer to rediscover.
  ///
  /// The grammar is matched directly instead of via `URL`, whose lenient parsing accepts forms that
  /// a renderer may later interpret differently.
  private static func validateSource(_ value: String) throws {
    func reject(_ reason: String) -> MCPJSONError {
      MCPJSONError.invalidField(field: "src", reason: reason)
    }

    // A raw control character or space cannot appear in a URI, and surviving one lets a source
    // split a line in any text-based context the host later writes it into.
    guard value.utf8.allSatisfy({ $0 > 0x20 && $0 != 0x7F }) else {
      throw reject("icon source must not contain spaces or control characters")
    }

    let bytes = Array(value.utf8)
    guard let first = bytes.first, isASCIIAlpha(first) else {
      throw reject("icon source must be an https: or data: URI")
    }
    var index = 1
    while index < bytes.count {
      let byte = bytes[index]
      if byte == 0x3A { break }
      guard isASCIIAlphanumeric(byte) || byte == 0x2B || byte == 0x2D || byte == 0x2E else {
        throw reject("icon source must be an https: or data: URI")
      }
      index += 1
    }
    guard index < bytes.count, bytes[index] == 0x3A else {
      throw reject("icon source must be an https: or data: URI")
    }
    let scheme = String(decoding: bytes[..<index], as: UTF8.self).lowercased()
    let remainder = String(decoding: bytes[bytes.index(after: index)...], as: UTF8.self)

    switch scheme {
    case "https":
      guard remainder.hasPrefix("//") else {
        throw reject("https icon source must be absolute with an authority")
      }
      let authority = remainder.dropFirst(2).prefix { $0 != "/" && $0 != "?" && $0 != "#" }
      // `userinfo@host` is legal but only serves to disguise the host it resolves to.
      guard !authority.isEmpty, !authority.contains("@") else {
        throw reject("https icon source must name a host")
      }
    case "data":
      guard let comma = remainder.firstIndex(of: ",") else {
        throw reject("data icon source must contain a comma-separated payload")
      }
      // RFC 2397 defaults an omitted media type to `text/plain`, so an absent one is not benign.
      let mediaType = remainder[..<comma].prefix { $0 != ";" }
      guard isImageMediaType(String(mediaType)) else {
        throw reject("data icon source must declare an image/* media type")
      }
    default:
      throw reject("icon source must be an https: or data: URI")
    }
  }

  /// Accepts `image/<subtype>` under the RFC 2045 token grammar. The subtype is not restricted to a
  /// known list: an unrecognized image format is a rendering concern, whereas a non-image type is
  /// the confusion the icon rules exist to prevent.
  ///
  /// `image/svg+xml` is accepted because it is a legitimate and widely used icon format, but SVG
  /// can carry script. A host that renders icons in a web view must still sandbox them; this check
  /// narrows the media type, it does not make an arbitrary source safe to execute.
  private static func isImageMediaType(_ value: String) -> Bool {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].lowercased() == "image", !parts[1].isEmpty else {
      return false
    }
    return parts[1].utf8.allSatisfy { byte in
      isASCIIAlphanumeric(byte) || "!#$%&'*+-.^_`|~".utf8.contains(byte)
    }
  }

  private static func isASCIIAlpha(_ value: UInt8) -> Bool {
    (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
  }

  private static func isASCIIAlphanumeric(_ value: UInt8) -> Bool {
    isASCIIAlpha(value) || (0x30...0x39).contains(value)
  }
}

public struct MCPElicitationCapabilities: Sendable, Hashable, MCPJSONModel {
  /// MCP models each elicitation mode as a JSONObject capability. The object is authoritative;
  /// the Boolean properties are convenience views used by request validation.
  public var formSettings: [String: MCPJSONValue]?
  public var urlSettings: [String: MCPJSONValue]?

  public var form: Bool {
    get { formSettings != nil }
    set {
      formSettings = newValue ? (formSettings ?? [:]) : nil
      if !newValue, urlSettings == nil { formSettings = [:] }
    }
  }

  public var url: Bool {
    get { urlSettings != nil }
    set {
      urlSettings = newValue ? (urlSettings ?? [:]) : nil
      if !newValue, formSettings == nil { formSettings = [:] }
    }
  }

  public init() {
    formSettings = [:]
    urlSettings = nil
  }

  public init(form: Bool, url: Bool) throws {
    guard form || url else {
      throw MCPJSONError.invalidField(
        field: "elicitation", reason: "strict mode requires form or url support")
    }
    formSettings = form ? [:] : nil
    urlSettings = url ? [:] : nil
  }

  public init(
    formSettings: [String: MCPJSONValue]?,
    urlSettings: [String: MCPJSONValue]?
  ) throws {
    guard formSettings != nil || urlSettings != nil else {
      throw MCPJSONError.invalidField(
        field: "elicitation", reason: "strict mode requires form or url support")
    }
    self.formSettings = formSettings
    self.urlSettings = urlSettings
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    formSettings = try object.optionalObject("form")
    urlSettings = try object.optionalObject("url")
    // MCP 2026-07-28 retains the historical empty-object meaning as form-mode support.
    if formSettings == nil, urlSettings == nil { formSettings = [:] }
  }

  public var json: MCPJSONValue {
    var result: [String: MCPJSONValue] = [:]
    if let formSettings { result["form"] = .object(formSettings) }
    if let urlSettings { result["url"] = .object(urlSettings) }
    return .object(result)
  }
}

public struct MCPClientCapabilities: Sendable, Hashable, MCPJSONModel {
  public var elicitation: MCPElicitationCapabilities?
  public var rootsSettings: [String: MCPJSONValue]?
  public var roots: Bool {
    get { rootsSettings != nil }
    set { rootsSettings = newValue ? (rootsSettings ?? [:]) : nil }
  }
  public var sampling: MCPSamplingCapabilities?
  public var experimental: [String: MCPJSONValue]
  public var extensions: [String: MCPJSONValue]
  /// Future non-standard capability fields. Standard 2026 capability names are typed above.
  public var additionalCapabilities: [String: MCPJSONValue]

  public init(
    elicitation: MCPElicitationCapabilities? = nil,
    roots: Bool = false,
    rootsSettings: [String: MCPJSONValue]? = nil,
    sampling: MCPSamplingCapabilities? = nil,
    experimental: [String: MCPJSONValue] = [:],
    extensions: [String: MCPJSONValue] = [:],
    additionalCapabilities: [String: MCPJSONValue] = [:]
  ) throws {
    try MCPProtocolValidation.validateExperimentalCapabilities(experimental)
    try MCPProtocolValidation.validateExtensions(extensions)
    try MCPProtocolValidation.validateAdditionalCapabilities(
      additionalCapabilities,
      knownKeys: ["elicitation", "experimental", "extensions", "roots", "sampling"]
    )
    self.elicitation = elicitation
    self.rootsSettings = rootsSettings ?? (roots ? [:] : nil)
    self.sampling = sampling
    self.experimental = experimental
    self.extensions = extensions
    self.additionalCapabilities = additionalCapabilities
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    elicitation = try object.values["elicitation"].map(MCPElicitationCapabilities.init(json:))
    rootsSettings = try object.optionalObject("roots")
    sampling = try object.values["sampling"].map(MCPSamplingCapabilities.init(json:))
    experimental = try object.optionalObject("experimental") ?? [:]
    try MCPProtocolValidation.validateExperimentalCapabilities(experimental)
    extensions = try object.optionalObject("extensions") ?? [:]
    try MCPProtocolValidation.validateExtensions(extensions)
    additionalCapabilities = object.values.filter {
      !["elicitation", "roots", "sampling", "experimental", "extensions"].contains($0.key)
    }
  }

  public var json: MCPJSONValue {
    var result = additionalCapabilities
    if let elicitation { result["elicitation"] = elicitation.json }
    if let rootsSettings { result["roots"] = .object(rootsSettings) }
    if let sampling { result["sampling"] = sampling.json }
    if !experimental.isEmpty { result["experimental"] = .object(experimental) }
    if !extensions.isEmpty { result["extensions"] = .object(extensions) }
    return .object(result)
  }
}

public struct MCPServerCapabilities: Sendable, Hashable, MCPJSONModel {
  public var toolSettings: [String: MCPJSONValue]?
  public var tools: Bool {
    get { toolSettings != nil }
    set { toolSettings = newValue ? (toolSettings ?? [:]) : nil }
  }
  public var toolListChanged: Bool {
    get { Self.boolSetting(toolSettings, key: "listChanged") }
    set { Self.setBoolSetting(&toolSettings, key: "listChanged", value: newValue) }
  }

  public var promptSettings: [String: MCPJSONValue]?
  public var prompts: Bool {
    get { promptSettings != nil }
    set { promptSettings = newValue ? (promptSettings ?? [:]) : nil }
  }
  public var promptListChanged: Bool {
    get { Self.boolSetting(promptSettings, key: "listChanged") }
    set { Self.setBoolSetting(&promptSettings, key: "listChanged", value: newValue) }
  }

  public var resourceSettings: [String: MCPJSONValue]?
  public var resources: Bool {
    get { resourceSettings != nil }
    set { resourceSettings = newValue ? (resourceSettings ?? [:]) : nil }
  }
  public var resourceListChanged: Bool {
    get { Self.boolSetting(resourceSettings, key: "listChanged") }
    set { Self.setBoolSetting(&resourceSettings, key: "listChanged", value: newValue) }
  }
  public var resourceSubscriptions: Bool {
    get { Self.boolSetting(resourceSettings, key: "subscribe") }
    set { Self.setBoolSetting(&resourceSettings, key: "subscribe", value: newValue) }
  }

  public var completionSettings: [String: MCPJSONValue]?
  public var completions: Bool {
    get { completionSettings != nil }
    set { completionSettings = newValue ? (completionSettings ?? [:]) : nil }
  }

  public var loggingSettings: [String: MCPJSONValue]?
  public var logging: Bool {
    get { loggingSettings != nil }
    set { loggingSettings = newValue ? (loggingSettings ?? [:]) : nil }
  }

  public var experimental: [String: MCPJSONValue]
  public var extensions: [String: MCPJSONValue]
  /// Future non-standard capability fields. Standard 2026 capability names are typed above.
  public var additionalCapabilities: [String: MCPJSONValue]

  public init(
    tools: Bool = false,
    toolListChanged: Bool = false,
    toolSettings: [String: MCPJSONValue]? = nil,
    prompts: Bool = false,
    promptListChanged: Bool = false,
    promptSettings: [String: MCPJSONValue]? = nil,
    resources: Bool = false,
    resourceListChanged: Bool = false,
    resourceSubscriptions: Bool = false,
    resourceSettings: [String: MCPJSONValue]? = nil,
    completions: Bool = false,
    completionSettings: [String: MCPJSONValue]? = nil,
    logging: Bool = false,
    loggingSettings: [String: MCPJSONValue]? = nil,
    experimental: [String: MCPJSONValue] = [:],
    extensions: [String: MCPJSONValue] = [:],
    additionalCapabilities: [String: MCPJSONValue] = [:]
  ) throws {
    try MCPProtocolValidation.validateExperimentalCapabilities(experimental)
    try MCPProtocolValidation.validateExtensions(extensions)
    try MCPProtocolValidation.validateAdditionalCapabilities(
      additionalCapabilities,
      knownKeys: [
        "tools", "prompts", "resources", "completions", "logging", "experimental", "extensions",
      ]
    )

    let hasTools = tools || toolSettings != nil
    let hasPrompts = prompts || promptSettings != nil
    let hasResources = resources || resourceSettings != nil
    guard hasTools || !toolListChanged else {
      throw MCPJSONError.invalidField(field: "toolListChanged", reason: "requires tools capability")
    }
    guard hasPrompts || !promptListChanged else {
      throw MCPJSONError.invalidField(
        field: "promptListChanged", reason: "requires prompts capability")
    }
    guard hasResources || (!resourceListChanged && !resourceSubscriptions) else {
      throw MCPJSONError.invalidField(
        field: "resources", reason: "listChanged and subscribe require resources capability")
    }

    self.toolSettings = toolSettings ?? (tools ? [:] : nil)
    if toolListChanged {
      var settings = self.toolSettings ?? [:]
      settings["listChanged"] = .bool(true)
      self.toolSettings = settings
    }
    self.promptSettings = promptSettings ?? (prompts ? [:] : nil)
    if promptListChanged {
      var settings = self.promptSettings ?? [:]
      settings["listChanged"] = .bool(true)
      self.promptSettings = settings
    }
    self.resourceSettings = resourceSettings ?? (resources ? [:] : nil)
    if resourceListChanged || resourceSubscriptions {
      var settings = self.resourceSettings ?? [:]
      if resourceListChanged { settings["listChanged"] = .bool(true) }
      if resourceSubscriptions { settings["subscribe"] = .bool(true) }
      self.resourceSettings = settings
    }
    self.completionSettings = completionSettings ?? (completions ? [:] : nil)
    self.loggingSettings = loggingSettings ?? (logging ? [:] : nil)
    self.experimental = experimental
    self.extensions = extensions
    self.additionalCapabilities = additionalCapabilities
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    toolSettings = try object.optionalObject("tools")
    promptSettings = try object.optionalObject("prompts")
    resourceSettings = try object.optionalObject("resources")
    completionSettings = try object.optionalObject("completions")
    loggingSettings = try object.optionalObject("logging")
    experimental = try object.optionalObject("experimental") ?? [:]
    try MCPProtocolValidation.validateExperimentalCapabilities(experimental)
    extensions = try object.optionalObject("extensions") ?? [:]
    try MCPProtocolValidation.validateExtensions(extensions)
    additionalCapabilities = object.values.filter {
      !["tools", "prompts", "resources", "completions", "logging", "experimental", "extensions"]
        .contains($0.key)
    }

    // Known capability settings remain type-checked while the complete JSONObject is preserved.
    _ = try Self.optionalBool(toolSettings, key: "listChanged", field: "tools.listChanged")
    _ = try Self.optionalBool(promptSettings, key: "listChanged", field: "prompts.listChanged")
    _ = try Self.optionalBool(resourceSettings, key: "listChanged", field: "resources.listChanged")
    _ = try Self.optionalBool(resourceSettings, key: "subscribe", field: "resources.subscribe")
  }

  public var json: MCPJSONValue {
    var result = additionalCapabilities
    if let toolSettings { result["tools"] = .object(toolSettings) }
    if let promptSettings { result["prompts"] = .object(promptSettings) }
    if let resourceSettings { result["resources"] = .object(resourceSettings) }
    if let completionSettings { result["completions"] = .object(completionSettings) }
    if let loggingSettings { result["logging"] = .object(loggingSettings) }
    if !experimental.isEmpty { result["experimental"] = .object(experimental) }
    if !extensions.isEmpty { result["extensions"] = .object(extensions) }
    return .object(result)
  }

  private static func boolSetting(
    _ settings: [String: MCPJSONValue]?,
    key: String
  ) -> Bool {
    guard case .bool(let value)? = settings?[key] else { return false }
    return value
  }

  private static func setBoolSetting(
    _ settings: inout [String: MCPJSONValue]?,
    key: String,
    value: Bool
  ) {
    guard settings != nil || value else { return }
    var object = settings ?? [:]
    object[key] = .bool(value)
    settings = object
  }

  private static func optionalBool(
    _ settings: [String: MCPJSONValue]?,
    key: String,
    field: String
  ) throws -> Bool? {
    guard let raw = settings?[key] else { return nil }
    guard case .bool(let value) = raw else {
      throw MCPJSONError.invalidField(field: field, reason: "expected boolean")
    }
    return value
  }
}

public struct MCPRequestMetadata: Sendable, Hashable, MCPJSONModel {
  public var protocolVersion: MCPProtocolVersion
  public var clientCapabilities: MCPClientCapabilities
  public var clientInfo: MCPImplementation?
  public var progressToken: MCPProgressToken?
  /// The deprecated, but still supported, per-request logging threshold.
  public var logLevel: MCPLoggingLevel?
  public var traceContext: [String: String]
  public var extensions: [String: MCPJSONValue]

  public init(
    clientCapabilities: MCPClientCapabilities,
    clientInfo: MCPImplementation? = nil,
    progressToken: MCPProgressToken? = nil,
    logLevel: MCPLoggingLevel? = nil,
    traceContext: [String: String] = [:],
    extensions: [String: MCPJSONValue] = [:]
  ) throws {
    try MCPProtocolValidation.validateRequestMetadataExtensions(extensions)
    try MCPProtocolValidation.validateTraceContext(traceContext)
    protocolVersion = .current
    self.clientCapabilities = clientCapabilities
    self.clientInfo = clientInfo
    self.progressToken = progressToken
    self.logLevel = logLevel
    self.traceContext = traceContext
    self.extensions = extensions
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let rawVersion = try object.requiredString(MCPMetaKey.protocolVersion)
    guard let version = MCPProtocolVersion(rawValue: rawVersion) else {
      throw MCPRPCError.unsupportedProtocolVersion(rawVersion)
    }
    protocolVersion = version
    guard let capabilities = object.values[MCPMetaKey.clientCapabilities] else {
      throw MCPJSONError.missingField(MCPMetaKey.clientCapabilities)
    }
    clientCapabilities = try MCPClientCapabilities(json: capabilities)
    clientInfo = try object.values[MCPMetaKey.clientInfo].map(MCPImplementation.init(json:))
    progressToken = try object.values[MCPMetaKey.progressToken].map(MCPProgressToken.init(json:))
    logLevel = try object.values[MCPMetaKey.logLevel].map(MCPLoggingLevel.init(json:))
    var trace: [String: String] = [:]
    for key in [MCPMetaKey.traceparent, MCPMetaKey.tracestate, MCPMetaKey.baggage] {
      if let value = object.values[key] {
        guard case .string(let string) = value else {
          throw MCPJSONError.expectedString(field: key)
        }
        trace[key] = string
      }
    }
    traceContext = trace
    try MCPProtocolValidation.validateTraceContext(traceContext)
    let known = Set([
      MCPMetaKey.protocolVersion, MCPMetaKey.clientCapabilities, MCPMetaKey.clientInfo,
      MCPMetaKey.progressToken, MCPMetaKey.traceparent, MCPMetaKey.tracestate,
      MCPMetaKey.baggage, MCPMetaKey.logLevel,
    ])
    extensions = object.values.filter { !known.contains($0.key) }
    try MCPProtocolValidation.validateRequestMetadataExtensions(extensions)
  }

  public var json: MCPJSONValue {
    var result = extensions
    result[MCPMetaKey.protocolVersion] = .string(protocolVersion.rawValue)
    result[MCPMetaKey.clientCapabilities] = clientCapabilities.json
    if let clientInfo { result[MCPMetaKey.clientInfo] = clientInfo.json }
    if let progressToken { result[MCPMetaKey.progressToken] = progressToken.json }
    if let logLevel { result[MCPMetaKey.logLevel] = logLevel.json }
    for (key, value) in traceContext { result[key] = .string(value) }
    return .object(result)
  }

  public func inserting(into params: [String: MCPJSONValue]) throws -> [String: MCPJSONValue] {
    guard params["_meta"] == nil else {
      throw MCPJSONError.invalidField(
        field: "_meta",
        reason: "caller cannot override SDK-owned request metadata"
      )
    }
    var result = params
    result["_meta"] = json
    return result
  }

  public static func extract(from params: [String: MCPJSONValue]) throws -> MCPRequestMetadata {
    guard let meta = params["_meta"] else { throw MCPJSONError.missingField("_meta") }
    return try MCPRequestMetadata(json: meta)
  }

  func validateEncodedSize(maximumBytes: Int) throws {
    guard maximumBytes > 0 else {
      throw MCPJSONError.invalidField(field: "maximumMetadataBytes", reason: "must be positive")
    }
    let byteCount = try json.encoded().count
    guard byteCount <= maximumBytes else {
      throw MCPJSONError.invalidField(
        field: "_meta",
        reason: "encoded metadata exceeds the configured limit of \(maximumBytes) bytes"
      )
    }
  }
}

public struct MCPResultMetadata: Sendable, Hashable, MCPJSONModel {
  public var serverInfo: MCPImplementation?
  public var extensions: [String: MCPJSONValue]

  public init(serverInfo: MCPImplementation? = nil, extensions: [String: MCPJSONValue] = [:]) throws
  {
    try MCPProtocolValidation.validateMetadataExtensions(
      extensions, sdkOwnedKeys: [MCPMetaKey.serverInfo])
    self.serverInfo = serverInfo
    self.extensions = extensions
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    serverInfo = try object.values[MCPMetaKey.serverInfo].map(MCPImplementation.init(json:))
    extensions = object.values.filter { $0.key != MCPMetaKey.serverInfo }
    try MCPProtocolValidation.validateMetadataExtensions(extensions)
  }

  public var json: MCPJSONValue {
    var result = extensions
    if let serverInfo { result[MCPMetaKey.serverInfo] = serverInfo.json }
    return .object(result)
  }
}

public struct MCPNotificationMetadata: Sendable, Hashable, MCPJSONModel {
  public var subscriptionID: MCPRequestID?
  public var extensions: [String: MCPJSONValue]

  public init(subscriptionID: MCPRequestID? = nil, extensions: [String: MCPJSONValue] = [:]) throws
  {
    try MCPProtocolValidation.validateMetadataExtensions(
      extensions, sdkOwnedKeys: [MCPMetaKey.subscriptionID])
    self.subscriptionID = subscriptionID
    self.extensions = extensions
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    subscriptionID = try object.values[MCPMetaKey.subscriptionID].map(MCPRequestID.init(json:))
    extensions = object.values.filter { $0.key != MCPMetaKey.subscriptionID }
    try MCPProtocolValidation.validateMetadataExtensions(extensions)
  }

  public var json: MCPJSONValue {
    var result = extensions
    if let subscriptionID { result[MCPMetaKey.subscriptionID] = subscriptionID.json }
    return .object(result)
  }
}

enum MCPProtocolValidation {
  static func validateExperimentalCapabilities(
    _ experimental: [String: MCPJSONValue]
  ) throws {
    for (name, value) in experimental {
      guard case .object = value else {
        throw MCPJSONError.invalidField(
          field: "experimental.\(name)", reason: "settings must be an object")
      }
    }
  }

  static func validateExtensions(_ extensions: [String: MCPJSONValue]) throws {
    for (name, value) in extensions {
      guard isExtensionIdentifier(name) else {
        throw MCPJSONError.invalidField(
          field: "extensions",
          reason: "extension identifier must be vendor/name"
        )
      }
      guard case .object = value else {
        throw MCPJSONError.invalidField(
          field: "extensions.\(name)",
          reason: "settings must be an object"
        )
      }
    }
  }

  static func validateAdditionalCapabilities(
    _ capabilities: [String: MCPJSONValue],
    knownKeys: Set<String>
  ) throws {
    guard Set(capabilities.keys).isDisjoint(with: knownKeys) else {
      throw MCPJSONError.invalidField(
        field: "capabilities", reason: "additional capability collides with a modeled capability")
    }
  }

  static func validateRequestMetadataExtensions(_ extensions: [String: MCPJSONValue]) throws {
    try validateMetadataExtensions(extensions, sdkOwnedKeys: MCPMetaKey.requestReserved)
  }

  static func validateMetadataExtensions(
    _ extensions: [String: MCPJSONValue],
    sdkOwnedKeys: Set<String> = []
  ) throws {
    guard Set(extensions.keys).isDisjoint(with: sdkOwnedKeys) else {
      throw MCPJSONError.invalidField(
        field: "_meta", reason: "extension metadata collides with an SDK-owned key")
    }
    for key in extensions.keys {
      guard parseMetadataKey(key) != nil else {
        throw MCPJSONError.invalidField(field: key, reason: "invalid metadata key")
      }
    }
  }

  static func validateTraceContext(_ values: [String: String]) throws {
    let accepted = Set([MCPMetaKey.traceparent, MCPMetaKey.tracestate, MCPMetaKey.baggage])
    guard Set(values.keys).isSubset(of: accepted) else {
      throw MCPJSONError.invalidField(field: "_meta", reason: "unsupported trace-context key")
    }
    if let value = values[MCPMetaKey.traceparent], !isValidTraceparent(value) {
      throw MCPJSONError.invalidField(
        field: MCPMetaKey.traceparent, reason: "must follow W3C Trace Context")
    }
    if let value = values[MCPMetaKey.tracestate], !isValidTracestate(value) {
      throw MCPJSONError.invalidField(
        field: MCPMetaKey.tracestate, reason: "must follow W3C Trace Context")
    }
    if let value = values[MCPMetaKey.baggage], !isValidBaggage(value) {
      throw MCPJSONError.invalidField(
        field: MCPMetaKey.baggage, reason: "must follow W3C Baggage")
    }
  }

  private static func isExtensionIdentifier(_ value: String) -> Bool {
    guard let parsed = parseMetadataKey(value) else { return false }
    return !parsed.prefixLabels.isEmpty
  }

  private struct ParsedMetadataKey {
    let prefixLabels: [Substring]

    var hasProtocolReservedPrefix: Bool {
      guard prefixLabels.count >= 2 else { return false }
      let second = prefixLabels[1].lowercased()
      return second == "mcp" || second == "modelcontextprotocol"
    }
  }

  private static func parseMetadataKey(_ value: String) -> ParsedMetadataKey? {
    let segments = value.split(separator: "/", omittingEmptySubsequences: false)
    guard segments.count <= 2 else { return nil }

    let name: Substring
    let labels: [Substring]
    if segments.count == 2 {
      guard !segments[0].isEmpty else { return nil }
      labels = segments[0].split(separator: ".", omittingEmptySubsequences: false)
      guard !labels.isEmpty, labels.allSatisfy(isValidMetadataPrefixLabel) else { return nil }
      name = segments[1]
    } else {
      labels = []
      name = segments[0]
    }

    guard isValidMetadataName(name) else { return nil }
    return ParsedMetadataKey(prefixLabels: labels)
  }

  private static func isValidMetadataPrefixLabel(_ value: Substring) -> Bool {
    guard let first = value.utf8.first, let last = value.utf8.last,
      isASCIIAlpha(first), isASCIIAlphanumeric(last)
    else { return false }
    return value.utf8.allSatisfy { isASCIIAlphanumeric($0) || $0 == 0x2D }
  }

  private static func isValidMetadataName(_ value: Substring) -> Bool {
    guard !value.isEmpty else { return true }
    guard let first = value.utf8.first, let last = value.utf8.last,
      isASCIIAlphanumeric(first), isASCIIAlphanumeric(last)
    else { return false }
    return value.utf8.allSatisfy {
      isASCIIAlphanumeric($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E
    }
  }

  private static func isValidTraceparent(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count >= 55, bytes[2] == 0x2D, bytes[35] == 0x2D, bytes[52] == 0x2D else {
      return false
    }
    let version = bytes[0..<2]
    let traceID = bytes[3..<35]
    let parentID = bytes[36..<52]
    let flags = bytes[53..<55]
    guard version.allSatisfy(isLowerHex), !version.elementsEqual([0x66, 0x66]),
      traceID.allSatisfy(isLowerHex), traceID.contains(where: { $0 != 0x30 }),
      parentID.allSatisfy(isLowerHex), parentID.contains(where: { $0 != 0x30 }),
      flags.allSatisfy(isLowerHex)
    else { return false }
    if version.elementsEqual([0x30, 0x30]) { return bytes.count == 55 }
    guard bytes.count == 55 || (bytes[55] == 0x2D && bytes.count > 56) else { return false }
    return bytes.dropFirst(56).allSatisfy { isLowerHex($0) || $0 == 0x2D }
  }

  private static func isValidTracestate(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 512 else { return false }
    let members = value.split(separator: ",", omittingEmptySubsequences: false)
    guard members.count <= 32 else { return false }
    var keys = Set<String>()
    for rawMember in members {
      let member = rawMember.trimmingCharacters(in: .whitespaces)
      guard !member.isEmpty, let separator = member.firstIndex(of: "=") else { return false }
      let key = String(member[..<separator])
      let memberValue = String(member[member.index(after: separator)...])
      guard isValidTracestateKey(key), isValidTracestateValue(memberValue),
        keys.insert(key).inserted
      else { return false }
    }
    return true
  }

  private static func isValidTracestateKey(_ value: String) -> Bool {
    let parts = value.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count <= 2 else { return false }
    if parts.count == 1 {
      guard parts[0].utf8.count <= 256, let first = parts[0].utf8.first, isASCIILower(first) else {
        return false
      }
      return parts[0].utf8.allSatisfy(isTracestateKeyCharacter)
    }
    guard !parts[0].isEmpty, parts[0].utf8.count <= 241,
      let tenantFirst = parts[0].utf8.first,
      isASCIILower(tenantFirst) || isASCIIDigit(tenantFirst),
      parts[0].utf8.allSatisfy(isTracestateKeyCharacter),
      !parts[1].isEmpty, parts[1].utf8.count <= 14,
      let systemFirst = parts[1].utf8.first, isASCIILower(systemFirst),
      parts[1].utf8.allSatisfy(isTracestateKeyCharacter)
    else { return false }
    return true
  }

  private static func isValidTracestateValue(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard !bytes.isEmpty, bytes.count <= 256, bytes.last != 0x20 else { return false }
    return bytes.allSatisfy { byte in
      (0x20...0x2B).contains(byte) || (0x2D...0x3C).contains(byte)
        || (0x3E...0x7E).contains(byte)
    }
  }

  private static func isValidBaggage(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 8_192 else { return false }
    let members = value.split(separator: ",", omittingEmptySubsequences: false)
    guard members.count <= 64 else { return false }
    return members.allSatisfy { rawMember in
      let parts = rawMember.split(separator: ";", omittingEmptySubsequences: false)
      guard let first = parts.first, isValidBaggagePair(first, valueRequired: true) else {
        return false
      }
      return parts.dropFirst().allSatisfy { isValidBaggagePair($0, valueRequired: false) }
    }
  }

  private static func isValidBaggagePair(_ rawPair: Substring, valueRequired: Bool) -> Bool {
    let pair = rawPair.trimmingCharacters(in: .whitespaces)
    guard !pair.isEmpty else { return false }
    let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
    guard let key = pieces.first, !key.isEmpty, key.utf8.allSatisfy(isHTTPTokenCharacter) else {
      return false
    }
    if pieces.count == 1 { return !valueRequired }
    let value = pieces[1].trimmingCharacters(in: .whitespaces)
    return value.utf8.allSatisfy(isBaggageValueCharacter)
  }

  private static func isASCIIAlpha(_ value: UInt8) -> Bool {
    (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
  }

  private static func isASCIILower(_ value: UInt8) -> Bool { (0x61...0x7A).contains(value) }
  private static func isASCIIDigit(_ value: UInt8) -> Bool { (0x30...0x39).contains(value) }
  private static func isASCIIAlphanumeric(_ value: UInt8) -> Bool {
    isASCIIAlpha(value) || isASCIIDigit(value)
  }

  private static func isLowerHex(_ value: UInt8) -> Bool {
    isASCIIDigit(value) || (0x61...0x66).contains(value)
  }

  private static func isTracestateKeyCharacter(_ value: UInt8) -> Bool {
    isASCIILower(value) || isASCIIDigit(value)
      || [0x5F, 0x2D, 0x2A, 0x2F].contains(value)
  }

  private static func isHTTPTokenCharacter(_ value: UInt8) -> Bool {
    isASCIIAlphanumeric(value)
      || [
        0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F,
        0x60, 0x7C, 0x7E,
      ].contains(value)
  }

  private static func isBaggageValueCharacter(_ value: UInt8) -> Bool {
    value == 0x21 || (0x23...0x2B).contains(value) || (0x2D...0x3A).contains(value)
      || (0x3C...0x5B).contains(value) || (0x5D...0x7E).contains(value)
  }
}
