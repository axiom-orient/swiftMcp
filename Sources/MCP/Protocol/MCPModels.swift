import Foundation

// MARK: - Diagnostics and request-local execution context

public enum MCPDiagnosticLevel: String, Sendable, Hashable {
  case debug
  case info
  case warning
  case error
}

public struct MCPDiagnosticEvent: Sendable, Hashable {
  public let id: String
  public let level: MCPDiagnosticLevel
  public let fields: [String: String]

  public init(id: String, level: MCPDiagnosticLevel, fields: [String: String] = [:]) {
    self.id = id
    self.level = level
    self.fields = fields
  }
}

public protocol MCPDiagnosticSink: Sendable {
  func record(_ event: MCPDiagnosticEvent) async
}

public struct MCPNoopDiagnosticSink: MCPDiagnosticSink {
  public init() {}
  public func record(_ event: MCPDiagnosticEvent) async { _ = event }
}

public struct MCPAuthorizationContext: Sendable, Hashable {
  public var subject: String?
  public var scopes: Set<String>
  public var attributes: [String: String]
  public var cachePartition: String?

  public init(
    subject: String? = nil,
    scopes: Set<String> = [],
    attributes: [String: String] = [:],
    cachePartition: String? = nil
  ) {
    self.subject = subject
    self.scopes = scopes
    self.attributes = attributes
    self.cachePartition = cachePartition
  }

  public func requires(scope: String) -> Bool { scopes.contains(scope) }
}

public enum MCPOperationOutcome<Result: Sendable>: Sendable {
  case complete(Result)
  case inputRequired(Result)
}

public struct MCPProgressReporter: Sendable {
  private let body: @Sendable (MCPJSONNumber, MCPJSONNumber?, String?) async throws -> Void

  public init(
    _ body: @escaping @Sendable (MCPJSONNumber, MCPJSONNumber?, String?) async throws -> Void
  ) {
    self.body = body
  }

  public func report(
    progress: MCPJSONNumber,
    total: MCPJSONNumber? = nil,
    message: String? = nil
  ) async throws {
    try await body(progress, total, message)
  }

  public func report(progress: Double, total: Double? = nil, message: String? = nil) async throws {
    let progressNumber = try MCPJSONNumber(progress)
    let totalNumber = try total.map(MCPJSONNumber.init)
    try await body(progressNumber, totalNumber, message)
  }
}

public struct MCPRequestContext: Sendable {
  public let id: MCPRequestID
  public let method: MCPMethodDescriptor
  public let metadata: MCPRequestMetadata
  public let authorization: MCPAuthorizationContext
  public let progress: MCPProgressReporter?

  public init(
    id: MCPRequestID,
    method: MCPMethodDescriptor,
    metadata: MCPRequestMetadata,
    authorization: MCPAuthorizationContext,
    progress: MCPProgressReporter?
  ) {
    self.id = id
    self.method = method
    self.metadata = metadata
    self.authorization = authorization
    self.progress = progress
  }
}

// MARK: - Progress and cancellation

public enum MCPProgressToken: Sendable, Hashable, CustomStringConvertible, MCPJSONModel {
  case string(String)
  case number(MCPJSONNumber)

  public init(_ value: String) throws {
    self = .string(value)
  }

  public init(_ value: Int64) { self = .number(MCPJSONNumber(value)) }

  public init(_ value: MCPJSONNumber) { self = .number(value) }

  public init(json: MCPJSONValue) throws {
    switch json {
    case .string(let value):
      self = .string(value)
    case .number(let number):
      self = .number(number)
    default:
      throw MCPJSONError.invalidField(
        field: "progressToken", reason: "must be a string or number")
    }
  }

  public var json: MCPJSONValue {
    switch self {
    case .string(let value): .string(value)
    case .number(let value): .number(value)
    }
  }

  public var description: String {
    switch self {
    case .string(let value): value
    case .number(let value): value.rawValue
    }
  }
}

public struct MCPProgressParams: Sendable, Hashable, MCPJSONModel {
  public let progressToken: MCPProgressToken
  public let progress: MCPJSONNumber
  public let total: MCPJSONNumber?
  public let message: String?

  public init(
    progressToken: MCPProgressToken,
    progress: MCPJSONNumber,
    total: MCPJSONNumber? = nil,
    message: String? = nil
  ) throws {
    self.progressToken = progressToken
    self.progress = progress
    self.total = total
    self.message = message
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      progressToken: MCPProgressToken(
        json: object.values["progressToken"]
          ?? { throw MCPJSONError.missingField("progressToken") }()),
      progress: try object.requiredNumber("progress"),
      total: try object.optionalNumber("total"),
      message: try object.optionalString("message")
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("progressToken", progressToken.json),
      ("progress", .number(progress)),
      ("total", total.map(MCPJSONValue.number)),
      ("message", message.map(MCPJSONValue.string)),
    ])
  }
}

public struct MCPCancelledParams: Sendable, Hashable, MCPJSONModel {
  public let requestID: MCPRequestID
  public let reason: String?

  public init(requestID: MCPRequestID, reason: String? = nil) {
    self.requestID = requestID
    self.reason = reason
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard let id = object.values["requestId"] else { throw MCPJSONError.missingField("requestId") }
    requestID = try MCPRequestID(json: id)
    reason = try object.optionalString("reason")
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("requestId", requestID.json),
      ("reason", reason.map(MCPJSONValue.string)),
    ])
  }
}

// MARK: - Cache metadata

public enum MCPCacheScope: String, Sendable, Hashable, MCPJSONModel {
  case `private`
  case `public`

  public init(json: MCPJSONValue) throws {
    guard case .string(let value) = json, let scope = Self(rawValue: value) else {
      throw MCPJSONError.invalidField(field: "cacheScope", reason: "expected private or public")
    }
    self = scope
  }

  public var json: MCPJSONValue { .string(rawValue) }
}

public struct MCPCachePolicy: Sendable, Hashable {
  /// The exact non-negative JSON Schema integer carried on the wire.
  public let ttlMilliseconds: MCPJSONNumber
  public let scope: MCPCacheScope

  public init(ttlMilliseconds: MCPJSONNumber, scope: MCPCacheScope) throws {
    try mcpValidateNonnegativeInteger(ttlMilliseconds, field: "ttlMs")
    self.ttlMilliseconds = ttlMilliseconds
    self.scope = scope
  }

  public init(ttlMilliseconds: Int64, scope: MCPCacheScope) throws {
    try self.init(ttlMilliseconds: MCPJSONNumber(ttlMilliseconds), scope: scope)
  }

  private init(uncheckedTTL ttlMilliseconds: Int64, scope: MCPCacheScope) {
    self.ttlMilliseconds = MCPJSONNumber(ttlMilliseconds)
    self.scope = scope
  }

  public static let noStore = MCPCachePolicy(uncheckedTTL: 0, scope: .private)
  public static let defaultDiscovery = MCPCachePolicy(uncheckedTTL: 30_000, scope: .public)
  public static let defaultListing = MCPCachePolicy(uncheckedTTL: 0, scope: .private)
  public static let defaultResourceRead = MCPCachePolicy(uncheckedTTL: 0, scope: .private)

  public static func extract(from object: MCPJSONObject, required: Bool) throws -> MCPCachePolicy? {
    let ttl = try object.optionalNumber("ttlMs")
    let scopeValue = object.values["cacheScope"]
    if ttl == nil && scopeValue == nil {
      if required {
        throw MCPJSONError.invalidField(
          field: "ttlMs", reason: "ttlMs and cacheScope are required together")
      }
      return nil
    }
    guard let ttl, let scopeValue else {
      throw MCPJSONError.invalidField(
        field: "cacheScope", reason: "ttlMs and cacheScope are required together")
    }
    return try MCPCachePolicy(
      ttlMilliseconds: ttl,
      scope: try MCPCacheScope(json: scopeValue)
    )
  }

  fileprivate func insert(into object: inout [String: MCPJSONValue]) {
    object["ttlMs"] = .number(ttlMilliseconds)
    object["cacheScope"] = scope.json
  }
}

// MARK: - Discovery

public struct MCPDiscoverParams: Sendable, Hashable, MCPJSONModel {
  public init() {}
  public init(json: MCPJSONValue) throws { _ = try MCPJSONObject(json) }
  public var json: MCPJSONValue { .object([:]) }
}

public struct MCPDiscoverResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let supportedVersions: [String]
  public let capabilities: MCPServerCapabilities
  public let instructions: String?
  public let cache: MCPCachePolicy
  public let metadata: MCPResultMetadata?

  public init(
    capabilities: MCPServerCapabilities,
    instructions: String? = nil,
    cache: MCPCachePolicy = .defaultDiscovery,
    metadata: MCPResultMetadata? = nil
  ) throws {
    self.resultType = .complete
    self.supportedVersions = [MCPProtocolVersion.current.rawValue]
    self.capabilities = capabilities
    self.instructions = instructions
    self.cache = cache
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    resultType = try mcpRequiredCompleteResultType(object)
    let versions = try object.requiredArray("supportedVersions").map { value -> String in
      guard case .string(let version) = value else {
        throw MCPJSONError.expectedString(field: "supportedVersions[]")
      }
      return version
    }
    guard versions.contains(MCPProtocolVersion.current.rawValue) else {
      throw MCPJSONError.invalidField(
        field: "supportedVersions", reason: "server does not advertise 2026-07-28")
    }
    supportedVersions = versions
    capabilities = try MCPServerCapabilities(
      json: object.values["capabilities"] ?? { throw MCPJSONError.missingField("capabilities") }())
    instructions = try object.optionalString("instructions")
    guard let cache = try MCPCachePolicy.extract(from: object, required: true) else {
      throw MCPJSONError.missingField("ttlMs")
    }
    self.cache = cache
    metadata = try object.values["_meta"].map(MCPResultMetadata.init(json:))
  }

  public var json: MCPJSONValue {
    var object: [String: MCPJSONValue] = [
      "resultType": .string("complete"),
      "supportedVersions": .array(supportedVersions.map(MCPJSONValue.string)),
      "capabilities": capabilities.json,
    ]
    if let instructions { object["instructions"] = .string(instructions) }
    if let metadata { object["_meta"] = metadata.json }
    cache.insert(into: &object)
    return .object(object)
  }
}

// MARK: - Shared object metadata/content

public enum MCPRole: String, Sendable, Hashable, MCPJSONModel {
  case user
  case assistant

  public init(json: MCPJSONValue) throws {
    guard case .string(let value) = json, let role = Self(rawValue: value) else {
      throw MCPJSONError.invalidField(field: "role", reason: "expected user or assistant")
    }
    self = role
  }
  public var json: MCPJSONValue { .string(rawValue) }
}

public struct MCPAnnotations: Sendable, Hashable, MCPJSONModel {
  public var audience: [MCPRole]
  public var priority: MCPJSONNumber?
  public var lastModified: String?

  public init(
    audience: [MCPRole] = [],
    priority: MCPJSONNumber? = nil,
    lastModified: String? = nil
  ) throws {
    if let priority {
      guard priority.compare(to: MCPJSONNumber(0)) != .orderedAscending,
        priority.compare(to: MCPJSONNumber(1)) != .orderedDescending
      else {
        throw MCPJSONError.invalidField(field: "priority", reason: "must be between 0 and 1")
      }
    }
    self.audience = audience
    self.priority = priority
    self.lastModified = lastModified
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let audience = try object.optionalArray("audience")?.map(MCPRole.init(json:)) ?? []
    try self.init(
      audience: audience,
      priority: try object.optionalNumber("priority"),
      lastModified: try object.optionalString("lastModified")
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("audience", audience.isEmpty ? nil : .array(audience.map(\.json))),
      ("priority", priority.map(MCPJSONValue.number)),
      ("lastModified", lastModified.map(MCPJSONValue.string)),
    ])
  }
}

public struct MCPTextContent: Sendable, Hashable, MCPJSONModel {
  public let text: String
  public let annotations: MCPAnnotations?
  public let metadata: [String: MCPJSONValue]

  public init(text: String, annotations: MCPAnnotations? = nil) {
    self.text = text
    self.annotations = annotations
    self.metadata = [:]
  }

  public init(
    text: String,
    annotations: MCPAnnotations? = nil,
    metadata: [String: MCPJSONValue]
  ) throws {
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.text = text
    self.annotations = annotations
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard object.values["type"] == .string("text") else {
      throw MCPJSONError.invalidField(field: "type", reason: "expected text")
    }
    try self.init(
      text: try object.requiredString("text"),
      annotations: try object.values["annotations"].map(MCPAnnotations.init(json:)),
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("type", .string("text")),
      ("text", .string(text)),
      ("annotations", annotations?.json),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPBinaryContent: Sendable, Hashable, MCPJSONModel {
  public enum Kind: String, Sendable, Hashable { case image, audio }
  public let kind: Kind
  public let data: String
  public let mimeType: String
  public let annotations: MCPAnnotations?
  public let metadata: [String: MCPJSONValue]

  public init(
    kind: Kind,
    data: String,
    mimeType: String,
    annotations: MCPAnnotations? = nil,
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    guard Data(base64Encoded: data) != nil else {
      throw MCPJSONError.invalidField(field: "data", reason: "must be base64")
    }
    guard !mimeType.isEmpty else {
      throw MCPJSONError.invalidField(field: "mimeType", reason: "must not be empty")
    }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.kind = kind
    self.data = data
    self.mimeType = mimeType
    self.annotations = annotations
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard let raw = try object.optionalString("type"), let kind = Kind(rawValue: raw) else {
      throw MCPJSONError.invalidField(field: "type", reason: "expected image or audio")
    }
    try self.init(
      kind: kind,
      data: try object.requiredString("data"),
      mimeType: try object.requiredNonEmptyString("mimeType"),
      annotations: try object.values["annotations"].map(MCPAnnotations.init(json:)),
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("type", .string(kind.rawValue)),
      ("data", .string(data)),
      ("mimeType", .string(mimeType)),
      ("annotations", annotations?.json),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPResourceContents: Sendable, Hashable, MCPJSONModel {
  public let uri: String
  public let mimeType: String?
  public let text: String?
  public let blob: String?
  public let metadata: [String: MCPJSONValue]

  public init(
    uri: String,
    mimeType: String? = nil,
    text: String? = nil,
    blob: String? = nil,
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    guard !uri.isEmpty else {
      throw MCPJSONError.invalidField(field: "uri", reason: "must not be empty")
    }
    guard (text == nil) != (blob == nil) else {
      throw MCPJSONError.invalidField(
        field: "contents", reason: "exactly one of text or blob is required")
    }
    if let blob, Data(base64Encoded: blob) == nil {
      throw MCPJSONError.invalidField(field: "blob", reason: "must be base64")
    }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.uri = uri
    self.mimeType = mimeType
    self.text = text
    self.blob = blob
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      uri: try object.requiredNonEmptyString("uri"),
      mimeType: try object.optionalString("mimeType"),
      text: try object.optionalString("text"),
      blob: try object.optionalString("blob"),
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("uri", .string(uri)),
      ("mimeType", mimeType.map(MCPJSONValue.string)),
      ("text", text.map(MCPJSONValue.string)),
      ("blob", blob.map(MCPJSONValue.string)),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPResourceLinkContent: Sendable, Hashable, MCPJSONModel {
  public let uri: String
  public let name: String
  public let title: String?
  public let descriptionText: String?
  public let mimeType: String?
  /// The exact JSON Schema integer size, when the server provides one.
  public let size: MCPJSONNumber?
  public let annotations: MCPAnnotations?
  public let icons: [MCPIcon]
  public let metadata: [String: MCPJSONValue]

  public init(
    uri: String,
    name: String,
    title: String? = nil,
    description: String? = nil,
    mimeType: String? = nil,
    size: MCPJSONNumber? = nil,
    annotations: MCPAnnotations? = nil,
    icons: [MCPIcon] = [],
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    guard !uri.isEmpty, !name.isEmpty else {
      throw MCPJSONError.invalidField(field: "resource_link", reason: "uri and name are required")
    }
    if let size { try mcpValidateInteger(size, field: "size") }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.uri = uri
    self.name = name
    self.title = title
    self.descriptionText = description
    self.mimeType = mimeType
    self.size = size
    self.annotations = annotations
    self.icons = icons
    self.metadata = metadata
  }

  public init(
    uri: String,
    name: String,
    title: String? = nil,
    description: String? = nil,
    mimeType: String? = nil,
    size: Int64,
    annotations: MCPAnnotations? = nil,
    icons: [MCPIcon] = [],
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    try self.init(
      uri: uri, name: name, title: title, description: description, mimeType: mimeType,
      size: MCPJSONNumber(size), annotations: annotations, icons: icons, metadata: metadata)
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard object.values["type"] == .string("resource_link") else {
      throw MCPJSONError.invalidField(field: "type", reason: "expected resource_link")
    }
    try self.init(
      uri: try object.requiredNonEmptyString("uri"),
      name: try object.requiredNonEmptyString("name"),
      title: try object.optionalString("title"),
      description: try object.optionalString("description"),
      mimeType: try object.optionalString("mimeType"),
      size: try object.optionalNumber("size"),
      annotations: try object.values["annotations"].map(MCPAnnotations.init(json:)),
      icons: try object.optionalArray("icons")?.map(MCPIcon.init(json:)) ?? [],
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("type", .string("resource_link")),
      ("uri", .string(uri)),
      ("name", .string(name)),
      ("title", title.map(MCPJSONValue.string)),
      ("description", descriptionText.map(MCPJSONValue.string)),
      ("mimeType", mimeType.map(MCPJSONValue.string)),
      ("size", size.map(MCPJSONValue.number)),
      ("annotations", annotations?.json),
      ("icons", icons.isEmpty ? nil : .array(icons.map(\.json))),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPEmbeddedResourceContent: Sendable, Hashable, MCPJSONModel {
  public let resource: MCPResourceContents
  public let annotations: MCPAnnotations?
  public let metadata: [String: MCPJSONValue]

  public init(resource: MCPResourceContents, annotations: MCPAnnotations? = nil) {
    self.resource = resource
    self.annotations = annotations
    self.metadata = [:]
  }

  public init(
    resource: MCPResourceContents,
    annotations: MCPAnnotations? = nil,
    metadata: [String: MCPJSONValue]
  ) throws {
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.resource = resource
    self.annotations = annotations
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard object.values["type"] == .string("resource") else {
      throw MCPJSONError.invalidField(field: "type", reason: "expected resource")
    }
    try self.init(
      resource: MCPResourceContents(
        json: object.values["resource"] ?? { throw MCPJSONError.missingField("resource") }()),
      annotations: try object.values["annotations"].map(MCPAnnotations.init(json:)),
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("type", .string("resource")),
      ("resource", resource.json),
      ("annotations", annotations?.json),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public enum MCPContentBlock: Sendable, Hashable, MCPJSONModel {
  case text(MCPTextContent)
  case image(MCPBinaryContent)
  case audio(MCPBinaryContent)
  case resourceLink(MCPResourceLinkContent)
  case resource(MCPEmbeddedResourceContent)

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let type = try object.requiredString("type")
    switch type {
    case "text": self = .text(try MCPTextContent(json: json))
    case "image":
      let value = try MCPBinaryContent(json: json)
      guard value.kind == .image else {
        throw MCPJSONError.invalidField(field: "type", reason: "expected image")
      }
      self = .image(value)
    case "audio":
      let value = try MCPBinaryContent(json: json)
      guard value.kind == .audio else {
        throw MCPJSONError.invalidField(field: "type", reason: "expected audio")
      }
      self = .audio(value)
    case "resource_link": self = .resourceLink(try MCPResourceLinkContent(json: json))
    case "resource": self = .resource(try MCPEmbeddedResourceContent(json: json))
    default:
      throw MCPJSONError.invalidField(field: "type", reason: "unsupported content block \(type)")
    }
  }

  public var json: MCPJSONValue {
    switch self {
    case .text(let value): value.json
    case .image(let value), .audio(let value): value.json
    case .resourceLink(let value): value.json
    case .resource(let value): value.json
    }
  }
}

// MARK: - Elicitation / MRTR

public enum MCPElicitationMode: String, Sendable, Hashable { case form, url }
public enum MCPElicitationAction: String, Sendable, Hashable { case accept, decline, cancel }

public struct MCPElicitationParams: Sendable, Hashable, MCPJSONModel {
  public let mode: MCPElicitationMode
  public let message: String
  public let requestedSchema: [String: MCPJSONValue]?
  public let url: String?

  public init(
    mode: MCPElicitationMode,
    message: String,
    requestedSchema: [String: MCPJSONValue]? = nil,
    url: String? = nil
  ) throws {
    guard !message.isEmpty else {
      throw MCPJSONError.invalidField(field: "message", reason: "must not be empty")
    }
    switch mode {
    case .form:
      guard let requestedSchema, url == nil else {
        throw MCPJSONError.invalidField(
          field: "requestedSchema", reason: "form mode requires a schema and forbids url")
      }
      try Self.validateRestrictedSchema(requestedSchema)
    case .url:
      guard requestedSchema == nil, let url, let parsed = URL(string: url), parsed.scheme != nil
      else {
        throw MCPJSONError.invalidField(
          field: "url", reason: "url mode requires an absolute URI and forbids requestedSchema")
      }
    }
    self.mode = mode
    self.message = message
    self.requestedSchema = requestedSchema
    self.url = url
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let mode: MCPElicitationMode
    if let raw = try object.optionalString("mode") {
      guard let value = MCPElicitationMode(rawValue: raw) else {
        throw MCPJSONError.invalidField(field: "mode", reason: "expected form or url")
      }
      mode = value
    } else {
      mode = object.values["url"] == nil ? .form : .url
    }
    try self.init(
      mode: mode,
      message: try object.requiredNonEmptyString("message"),
      requestedSchema: try object.optionalObject("requestedSchema"),
      url: try object.optionalString("url")
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("mode", .string(mode.rawValue)),
      ("message", .string(message)),
      ("requestedSchema", requestedSchema.map(MCPJSONValue.object)),
      ("url", url.map(MCPJSONValue.string)),
    ])
  }

  public func validate(result: MCPElicitationResult) throws {
    switch result.action {
    case .decline, .cancel:
      guard result.content == nil else {
        throw MCPJSONError.invalidField(
          field: "content", reason: "decline and cancel responses must not include content")
      }
    case .accept:
      switch mode {
      case .url:
        guard result.content == nil else {
          throw MCPJSONError.invalidField(
            field: "content", reason: "URL acceptance has no form content")
        }
      case .form:
        let content = result.content ?? [:]
        try Self.validateFormContent(content, schema: requestedSchema ?? [:])
      }
    }
  }

  private static func validateRestrictedSchema(_ schema: [String: MCPJSONValue]) throws {
    guard schema["type"] == .string("object") else {
      throw MCPJSONError.invalidField(field: "requestedSchema.type", reason: "must equal object")
    }
    guard case .object(let properties)? = schema["properties"] else {
      throw MCPJSONError.invalidField(
        field: "requestedSchema.properties", reason: "must be an object")
    }
    let allowedTypes = Set(["string", "number", "integer", "boolean", "array"])
    for (name, value) in properties {
      guard case .object(let definition) = value,
        case .string(let type)? = definition["type"], allowedTypes.contains(type)
      else {
        throw MCPJSONError.invalidField(
          field: "requestedSchema.properties.\(name)", reason: "must be a primitive schema")
      }
      if type == "array" {
        guard case .object(let items)? = definition["items"], items["type"] == .string("string")
        else {
          throw MCPJSONError.invalidField(
            field: "requestedSchema.properties.\(name).items",
            reason: "strict form arrays are arrays of strings")
        }
      }
      if definition["properties"] != nil || definition["additionalProperties"] != nil {
        throw MCPJSONError.invalidField(
          field: "requestedSchema.properties.\(name)", reason: "nested objects are not allowed")
      }
    }
    if let rawRequired = schema["required"] {
      guard case .array(let required) = rawRequired else {
        throw MCPJSONError.expectedArray(field: "requestedSchema.required")
      }
      for value in required {
        guard case .string(let name) = value, properties[name] != nil else {
          throw MCPJSONError.invalidField(
            field: "requestedSchema.required", reason: "must reference a declared property")
        }
      }
    }
  }

  private static func validateFormContent(
    _ content: [String: MCPJSONValue],
    schema: [String: MCPJSONValue]
  ) throws {
    guard case .object(let properties)? = schema["properties"] else { return }
    let requiredNames: Set<String>
    if case .array(let values)? = schema["required"] {
      requiredNames = try Set(
        values.map { value in
          guard case .string(let name) = value else {
            throw MCPJSONError.expectedString(field: "requestedSchema.required[]")
          }
          return name
        })
    } else {
      requiredNames = []
    }
    let missing = requiredNames.subtracting(content.keys)
    guard missing.isEmpty else {
      throw MCPJSONError.invalidField(
        field: "content", reason: "missing required values \(missing.sorted())")
    }
    guard Set(content.keys).isSubset(of: properties.keys) else {
      throw MCPJSONError.invalidField(field: "content", reason: "contains undeclared fields")
    }
    for (name, value) in content {
      guard case .object(let definition)? = properties[name],
        case .string(let type)? = definition["type"]
      else { continue }
      let valid: Bool =
        switch (type, value) {
        case ("string", .string), ("number", .number), ("boolean", .bool): true
        case ("integer", .number(let number)): number.isMathematicalInteger
        case ("array", .array(let values)):
          values.allSatisfy { if case .string = $0 { true } else { false } }
        default: false
        }
      guard valid else {
        throw MCPJSONError.invalidField(field: "content.\(name)", reason: "does not match \(type)")
      }
      if case .array(let enumValues)? = definition["enum"], !enumValues.contains(value) {
        throw MCPJSONError.invalidField(field: "content.\(name)", reason: "is not in enum")
      }
      if case .string(let text) = value {
        let length = text.unicodeScalars.count
        if let min = definition["minLength"]?.numberValue?.int64Value,
          length < min
        {
          throw MCPJSONError.invalidField(
            field: "content.\(name)", reason: "is shorter than minLength")
        }
        if let max = definition["maxLength"]?.numberValue?.int64Value,
          length > max
        {
          throw MCPJSONError.invalidField(
            field: "content.\(name)", reason: "is longer than maxLength")
        }
      }
      if case .number(let number) = value {
        if let minimum = definition["minimum"]?.numberValue,
          number.compare(to: minimum) == .orderedAscending
        {
          throw MCPJSONError.invalidField(field: "content.\(name)", reason: "is below minimum")
        }
        if let maximum = definition["maximum"]?.numberValue,
          number.compare(to: maximum) == .orderedDescending
        {
          throw MCPJSONError.invalidField(field: "content.\(name)", reason: "is above maximum")
        }
      }
    }
  }
}

public struct MCPElicitationRequest: Sendable, Hashable, MCPJSONModel {
  public let method: String
  public let params: MCPElicitationParams

  public init(params: MCPElicitationParams) {
    self.method = "elicitation/create"
    self.params = params
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard object.values["method"] == .string("elicitation/create") else {
      throw MCPJSONError.invalidField(field: "method", reason: "expected elicitation/create")
    }
    method = "elicitation/create"
    params = try MCPElicitationParams(
      json: object.values["params"] ?? { throw MCPJSONError.missingField("params") }())
  }

  public var json: MCPJSONValue {
    .object(["method": .string(method), "params": params.json])
  }
}

public struct MCPElicitationResult: Sendable, Hashable, MCPJSONModel {
  public let action: MCPElicitationAction
  public let content: [String: MCPJSONValue]?
  public let metadata: [String: MCPJSONValue]

  public init(
    action: MCPElicitationAction,
    content: [String: MCPJSONValue]? = nil,
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    if action != .accept, content != nil {
      throw MCPJSONError.invalidField(field: "content", reason: "only accept may include content")
    }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.action = action
    self.content = content
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let rawAction = try object.requiredString("action")
    guard let action = MCPElicitationAction(rawValue: rawAction) else {
      throw MCPJSONError.invalidField(
        field: "action", reason: "expected accept, decline, or cancel")
    }
    try self.init(
      action: action,
      content: try object.optionalObject("content"),
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("action", .string(action.rawValue)),
      ("content", content.map(MCPJSONValue.object)),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

// MARK: - Tools

public struct MCPTool: Sendable, Hashable, MCPJSONModel {
  public let name: String
  public let title: String?
  public let descriptionText: String?
  public let inputSchema: [String: MCPJSONValue]
  public let outputSchema: [String: MCPJSONValue]?
  public let annotations: [String: MCPJSONValue]?
  public let icons: [MCPIcon]
  public let metadata: [String: MCPJSONValue]

  public init(
    name: String,
    title: String? = nil,
    description: String? = nil,
    inputSchema: [String: MCPJSONValue],
    outputSchema: [String: MCPJSONValue]? = nil,
    annotations: [String: MCPJSONValue]? = nil,
    icons: [MCPIcon] = [],
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    guard !name.isEmpty else {
      throw MCPJSONError.invalidField(field: "name", reason: "must not be empty")
    }
    guard inputSchema["type"] == .string("object") else {
      throw MCPJSONError.invalidField(field: "inputSchema.type", reason: "must equal object")
    }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.name = name
    self.title = title
    self.descriptionText = description
    self.inputSchema = inputSchema
    self.outputSchema = outputSchema
    self.annotations = annotations
    self.icons = icons
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      name: try object.requiredNonEmptyString("name"),
      title: try object.optionalString("title"),
      description: try object.optionalString("description"),
      inputSchema: try object.requiredObject("inputSchema"),
      outputSchema: try object.optionalObject("outputSchema"),
      annotations: try object.optionalObject("annotations"),
      icons: try object.optionalArray("icons")?.map(MCPIcon.init(json:)) ?? [],
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("name", .string(name)),
      ("title", title.map(MCPJSONValue.string)),
      ("description", descriptionText.map(MCPJSONValue.string)),
      ("inputSchema", .object(inputSchema)),
      ("outputSchema", outputSchema.map(MCPJSONValue.object)),
      ("annotations", annotations.map(MCPJSONValue.object)),
      ("icons", icons.isEmpty ? nil : .array(icons.map(\.json))),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPListToolsParams: Sendable, Hashable, MCPJSONModel {
  public let cursor: String?
  public init(cursor: String? = nil) { self.cursor = cursor }
  public init(json: MCPJSONValue) throws {
    cursor = try MCPJSONObject(json).optionalString("cursor")
  }
  public var json: MCPJSONValue { mcpObject([("cursor", cursor.map(MCPJSONValue.string))]) }
}

public struct MCPListToolsResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let tools: [MCPTool]
  public let nextCursor: String?
  public let cache: MCPCachePolicy
  public let metadata: MCPResultMetadata?

  public init(
    tools: [MCPTool],
    nextCursor: String? = nil,
    cache: MCPCachePolicy = .defaultListing,
    metadata: MCPResultMetadata? = nil
  ) {
    resultType = .complete
    self.tools = tools
    self.nextCursor = nextCursor
    self.cache = cache
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    resultType = try mcpRequiredCompleteResultType(object)
    tools = try object.requiredArray("tools").map(MCPTool.init(json:))
    nextCursor = try object.optionalString("nextCursor")
    guard let cache = try MCPCachePolicy.extract(from: object, required: true) else {
      throw MCPJSONError.missingField("ttlMs")
    }
    self.cache = cache
    metadata = try object.values["_meta"].map(MCPResultMetadata.init(json:))
  }

  public var json: MCPJSONValue {
    var object: [String: MCPJSONValue] = [
      "resultType": .string("complete"), "tools": .array(tools.map(\.json)),
    ]
    if let nextCursor { object["nextCursor"] = .string(nextCursor) }
    if let metadata { object["_meta"] = metadata.json }
    cache.insert(into: &object)
    return .object(object)
  }
}

public struct MCPCallToolParams: Sendable, Hashable, MCPJSONModel {
  public let name: String
  public let arguments: [String: MCPJSONValue]
  public let inputResponses: [String: MCPElicitationResult]
  public let requestState: String?

  public init(
    name: String,
    arguments: [String: MCPJSONValue] = [:],
    inputResponses: [String: MCPElicitationResult] = [:],
    requestState: String? = nil
  ) throws {
    guard !name.isEmpty else {
      throw MCPJSONError.invalidField(field: "name", reason: "must not be empty")
    }
    try mcpValidateMRTRRetry(inputResponses: inputResponses, requestState: requestState)
    self.name = name
    self.arguments = arguments
    self.inputResponses = inputResponses
    self.requestState = requestState
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let responses = try mcpDecodeInputResponses(object.values["inputResponses"])
    try self.init(
      name: try object.requiredNonEmptyString("name"),
      arguments: try object.optionalObject("arguments") ?? [:],
      inputResponses: responses,
      requestState: try object.optionalString("requestState")
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("name", .string(name)),
      ("arguments", arguments.isEmpty ? nil : .object(arguments)),
      ("inputResponses", inputResponses.isEmpty ? nil : .object(inputResponses.mapValues(\.json))),
      ("requestState", requestState.map(MCPJSONValue.string)),
    ])
  }
}

public struct MCPCallToolResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let content: [MCPContentBlock]
  public let structuredContent: MCPJSONValue?
  public let isError: Bool
  public let inputRequests: [String: MCPElicitationRequest]
  public let requestState: String?
  public let metadata: MCPResultMetadata?

  public init(
    content: [MCPContentBlock] = [],
    structuredContent: MCPJSONValue? = nil,
    isError: Bool = false,
    resultType: MCPResultType = .complete,
    inputRequests: [String: MCPElicitationRequest] = [:],
    requestState: String? = nil,
    metadata: MCPResultMetadata? = nil
  ) throws {
    try mcpValidateOperationResult(
      resultType: resultType,
      hasCompleteField: true,
      inputRequests: inputRequests,
      requestState: requestState,
      completeField: "content"
    )
    self.resultType = resultType
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
    self.inputRequests = inputRequests
    self.requestState = requestState
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let resultType = try mcpResultType(object)
    let hasContent = object.values["content"] != nil
    let content = try object.optionalArray("content")?.map(MCPContentBlock.init(json:)) ?? []
    let decoded = try Self(
      content: content,
      structuredContent: object.values["structuredContent"],
      isError: try object.optionalBool("isError") ?? false,
      resultType: resultType,
      inputRequests: try mcpDecodeInputRequests(object.values["inputRequests"]),
      requestState: try object.optionalString("requestState"),
      metadata: try object.values["_meta"].map(MCPResultMetadata.init(json:))
    )
    if resultType == .complete, !hasContent {
      throw MCPJSONError.missingField("content")
    }
    self = decoded
  }

  public var json: MCPJSONValue {
    mcpOperationResultJSON(
      resultType: resultType,
      completeFields: [
        ("content", .array(content.map(\.json))),
        ("structuredContent", structuredContent),
        ("isError", isError ? .bool(true) : nil),
      ],
      inputRequests: inputRequests,
      requestState: requestState,
      metadata: metadata
    )
  }
}

// MARK: - Prompts

public struct MCPPromptArgument: Sendable, Hashable, MCPJSONModel {
  public let name: String
  public let title: String?
  public let descriptionText: String?
  public let required: Bool

  public init(
    name: String, title: String? = nil, description: String? = nil, required: Bool = false
  ) throws {
    guard !name.isEmpty else {
      throw MCPJSONError.invalidField(field: "name", reason: "must not be empty")
    }
    self.name = name
    self.title = title
    self.descriptionText = description
    self.required = required
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      name: try object.requiredNonEmptyString("name"),
      title: try object.optionalString("title"),
      description: try object.optionalString("description"),
      required: try object.optionalBool("required") ?? false)
  }
  public var json: MCPJSONValue {
    mcpObject([
      ("name", .string(name)), ("title", title.map(MCPJSONValue.string)),
      ("description", descriptionText.map(MCPJSONValue.string)),
      ("required", required ? .bool(true) : nil),
    ])
  }
}

public struct MCPPrompt: Sendable, Hashable, MCPJSONModel {
  public let name: String
  public let title: String?
  public let descriptionText: String?
  public let arguments: [MCPPromptArgument]
  public let icons: [MCPIcon]
  public let metadata: [String: MCPJSONValue]

  public init(
    name: String,
    title: String? = nil,
    description: String? = nil,
    arguments: [MCPPromptArgument] = [],
    icons: [MCPIcon] = [],
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    guard !name.isEmpty else {
      throw MCPJSONError.invalidField(field: "name", reason: "must not be empty")
    }
    let names = arguments.map(\.name)
    guard Set(names).count == names.count else {
      throw MCPJSONError.invalidField(field: "arguments", reason: "argument names must be unique")
    }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.name = name
    self.title = title
    self.descriptionText = description
    self.arguments = arguments
    self.icons = icons
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      name: try object.requiredNonEmptyString("name"),
      title: try object.optionalString("title"),
      description: try object.optionalString("description"),
      arguments: try object.optionalArray("arguments")?.map(MCPPromptArgument.init(json:)) ?? [],
      icons: try object.optionalArray("icons")?.map(MCPIcon.init(json:)) ?? [],
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("name", .string(name)),
      ("title", title.map(MCPJSONValue.string)),
      ("description", descriptionText.map(MCPJSONValue.string)),
      ("arguments", arguments.isEmpty ? nil : .array(arguments.map(\.json))),
      ("icons", icons.isEmpty ? nil : .array(icons.map(\.json))),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPPromptMessage: Sendable, Hashable, MCPJSONModel {
  public let role: MCPRole
  public let content: MCPContentBlock
  public init(role: MCPRole, content: MCPContentBlock) {
    self.role = role
    self.content = content
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    role = try MCPRole(json: object.values["role"] ?? { throw MCPJSONError.missingField("role") }())
    content = try MCPContentBlock(
      json: object.values["content"] ?? { throw MCPJSONError.missingField("content") }())
  }
  public var json: MCPJSONValue { .object(["role": role.json, "content": content.json]) }
}

public struct MCPListPromptsParams: Sendable, Hashable, MCPJSONModel {
  public let cursor: String?
  public init(cursor: String? = nil) { self.cursor = cursor }
  public init(json: MCPJSONValue) throws {
    cursor = try MCPJSONObject(json).optionalString("cursor")
  }
  public var json: MCPJSONValue { mcpObject([("cursor", cursor.map(MCPJSONValue.string))]) }
}

public struct MCPListPromptsResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let prompts: [MCPPrompt]
  public let nextCursor: String?
  public let cache: MCPCachePolicy
  public let metadata: MCPResultMetadata?

  public init(
    prompts: [MCPPrompt],
    nextCursor: String? = nil,
    cache: MCPCachePolicy = .defaultListing,
    metadata: MCPResultMetadata? = nil
  ) {
    resultType = .complete
    self.prompts = prompts
    self.nextCursor = nextCursor
    self.cache = cache
    self.metadata = metadata
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    resultType = try mcpRequiredCompleteResultType(object)
    prompts = try object.requiredArray("prompts").map(MCPPrompt.init(json:))
    nextCursor = try object.optionalString("nextCursor")
    guard let cache = try MCPCachePolicy.extract(from: object, required: true) else {
      throw MCPJSONError.missingField("ttlMs")
    }
    self.cache = cache
    metadata = try object.values["_meta"].map(MCPResultMetadata.init(json:))
  }
  public var json: MCPJSONValue {
    var object: [String: MCPJSONValue] = [
      "resultType": .string("complete"), "prompts": .array(prompts.map(\.json)),
    ]
    if let nextCursor { object["nextCursor"] = .string(nextCursor) }
    if let metadata { object["_meta"] = metadata.json }
    cache.insert(into: &object)
    return .object(object)
  }
}

public struct MCPGetPromptParams: Sendable, Hashable, MCPJSONModel {
  public let name: String
  public let arguments: [String: String]
  public let inputResponses: [String: MCPElicitationResult]
  public let requestState: String?

  public init(
    name: String,
    arguments: [String: String] = [:],
    inputResponses: [String: MCPElicitationResult] = [:],
    requestState: String? = nil
  ) throws {
    guard !name.isEmpty else {
      throw MCPJSONError.invalidField(field: "name", reason: "must not be empty")
    }
    try mcpValidateMRTRRetry(inputResponses: inputResponses, requestState: requestState)
    self.name = name
    self.arguments = arguments
    self.inputResponses = inputResponses
    self.requestState = requestState
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let rawArguments = try object.optionalObject("arguments") ?? [:]
    var arguments: [String: String] = [:]
    for (key, value) in rawArguments {
      guard case .string(let string) = value else {
        throw MCPJSONError.expectedString(field: "arguments.\(key)")
      }
      arguments[key] = string
    }
    try self.init(
      name: try object.requiredNonEmptyString("name"),
      arguments: arguments,
      inputResponses: try mcpDecodeInputResponses(object.values["inputResponses"]),
      requestState: try object.optionalString("requestState")
    )
  }
  public var json: MCPJSONValue {
    mcpObject([
      ("name", .string(name)),
      ("arguments", arguments.isEmpty ? nil : .object(arguments.mapValues(MCPJSONValue.string))),
      ("inputResponses", inputResponses.isEmpty ? nil : .object(inputResponses.mapValues(\.json))),
      ("requestState", requestState.map(MCPJSONValue.string)),
    ])
  }
}

public struct MCPGetPromptResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let descriptionText: String?
  public let messages: [MCPPromptMessage]
  public let inputRequests: [String: MCPElicitationRequest]
  public let requestState: String?
  public let metadata: MCPResultMetadata?

  public init(
    description: String? = nil,
    messages: [MCPPromptMessage] = [],
    resultType: MCPResultType = .complete,
    inputRequests: [String: MCPElicitationRequest] = [:],
    requestState: String? = nil,
    metadata: MCPResultMetadata? = nil
  ) throws {
    try mcpValidateOperationResult(
      resultType: resultType,
      hasCompleteField: true,
      inputRequests: inputRequests,
      requestState: requestState,
      completeField: "messages"
    )
    self.resultType = resultType
    self.descriptionText = description
    self.messages = messages
    self.inputRequests = inputRequests
    self.requestState = requestState
    self.metadata = metadata
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let resultType = try mcpResultType(object)
    let hasMessages = object.values["messages"] != nil
    let decoded = try Self(
      description: try object.optionalString("description"),
      messages: try object.optionalArray("messages")?.map(MCPPromptMessage.init(json:)) ?? [],
      resultType: resultType,
      inputRequests: try mcpDecodeInputRequests(object.values["inputRequests"]),
      requestState: try object.optionalString("requestState"),
      metadata: try object.values["_meta"].map(MCPResultMetadata.init(json:))
    )
    if resultType == .complete, !hasMessages {
      throw MCPJSONError.missingField("messages")
    }
    self = decoded
  }
  public var json: MCPJSONValue {
    mcpOperationResultJSON(
      resultType: resultType,
      completeFields: [
        ("description", descriptionText.map(MCPJSONValue.string)),
        ("messages", .array(messages.map(\.json))),
      ],
      inputRequests: inputRequests,
      requestState: requestState,
      metadata: metadata
    )
  }
}

// MARK: - Resources

public struct MCPResource: Sendable, Hashable, MCPJSONModel {
  public let uri: String
  public let name: String
  public let title: String?
  public let descriptionText: String?
  public let mimeType: String?
  /// The exact JSON Schema integer size, when the server provides one.
  public let size: MCPJSONNumber?
  public let annotations: MCPAnnotations?
  public let icons: [MCPIcon]
  public let metadata: [String: MCPJSONValue]

  public init(
    uri: String,
    name: String,
    title: String? = nil,
    description: String? = nil,
    mimeType: String? = nil,
    size: MCPJSONNumber? = nil,
    annotations: MCPAnnotations? = nil,
    icons: [MCPIcon] = [],
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    guard !uri.isEmpty, !name.isEmpty else {
      throw MCPJSONError.invalidField(field: "resource", reason: "uri and name are required")
    }
    if let size { try mcpValidateInteger(size, field: "size") }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.uri = uri
    self.name = name
    self.title = title
    self.descriptionText = description
    self.mimeType = mimeType
    self.size = size
    self.annotations = annotations
    self.icons = icons
    self.metadata = metadata
  }
  public init(
    uri: String,
    name: String,
    title: String? = nil,
    description: String? = nil,
    mimeType: String? = nil,
    size: Int64,
    annotations: MCPAnnotations? = nil,
    icons: [MCPIcon] = [],
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    try self.init(
      uri: uri, name: name, title: title, description: description, mimeType: mimeType,
      size: MCPJSONNumber(size), annotations: annotations, icons: icons, metadata: metadata)
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      uri: try object.requiredNonEmptyString("uri"),
      name: try object.requiredNonEmptyString("name"),
      title: try object.optionalString("title"),
      description: try object.optionalString("description"),
      mimeType: try object.optionalString("mimeType"), size: try object.optionalNumber("size"),
      annotations: try object.values["annotations"].map(MCPAnnotations.init(json:)),
      icons: try object.optionalArray("icons")?.map(MCPIcon.init(json:)) ?? [],
      metadata: try object.optionalObject("_meta") ?? [:])
  }
  public var json: MCPJSONValue {
    mcpObject([
      ("uri", .string(uri)), ("name", .string(name)), ("title", title.map(MCPJSONValue.string)),
      ("description", descriptionText.map(MCPJSONValue.string)),
      ("mimeType", mimeType.map(MCPJSONValue.string)), ("size", size.map(MCPJSONValue.number)),
      ("annotations", annotations?.json),
      ("icons", icons.isEmpty ? nil : .array(icons.map(\.json))),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPResourceTemplate: Sendable, Hashable, MCPJSONModel {
  public let uriTemplate: String
  public let name: String
  public let title: String?
  public let descriptionText: String?
  public let mimeType: String?
  public let annotations: MCPAnnotations?
  public let icons: [MCPIcon]
  public let metadata: [String: MCPJSONValue]

  public init(
    uriTemplate: String,
    name: String,
    title: String? = nil,
    description: String? = nil,
    mimeType: String? = nil,
    annotations: MCPAnnotations? = nil,
    icons: [MCPIcon] = [],
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    guard !uriTemplate.isEmpty, !name.isEmpty else {
      throw MCPJSONError.invalidField(
        field: "resourceTemplate", reason: "uriTemplate and name are required")
    }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.uriTemplate = uriTemplate
    self.name = name
    self.title = title
    self.descriptionText = description
    self.mimeType = mimeType
    self.annotations = annotations
    self.icons = icons
    self.metadata = metadata
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      uriTemplate: try object.requiredNonEmptyString("uriTemplate"),
      name: try object.requiredNonEmptyString("name"),
      title: try object.optionalString("title"),
      description: try object.optionalString("description"),
      mimeType: try object.optionalString("mimeType"),
      annotations: try object.values["annotations"].map(MCPAnnotations.init(json:)),
      icons: try object.optionalArray("icons")?.map(MCPIcon.init(json:)) ?? [],
      metadata: try object.optionalObject("_meta") ?? [:])
  }
  public var json: MCPJSONValue {
    mcpObject([
      ("uriTemplate", .string(uriTemplate)), ("name", .string(name)),
      ("title", title.map(MCPJSONValue.string)),
      ("description", descriptionText.map(MCPJSONValue.string)),
      ("mimeType", mimeType.map(MCPJSONValue.string)), ("annotations", annotations?.json),
      ("icons", icons.isEmpty ? nil : .array(icons.map(\.json))),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPListResourcesParams: Sendable, Hashable, MCPJSONModel {
  public let cursor: String?
  public init(cursor: String? = nil) { self.cursor = cursor }
  public init(json: MCPJSONValue) throws {
    cursor = try MCPJSONObject(json).optionalString("cursor")
  }
  public var json: MCPJSONValue { mcpObject([("cursor", cursor.map(MCPJSONValue.string))]) }
}

public struct MCPListResourceTemplatesParams: Sendable, Hashable, MCPJSONModel {
  public let cursor: String?
  public init(cursor: String? = nil) { self.cursor = cursor }
  public init(json: MCPJSONValue) throws {
    cursor = try MCPJSONObject(json).optionalString("cursor")
  }
  public var json: MCPJSONValue { mcpObject([("cursor", cursor.map(MCPJSONValue.string))]) }
}

public struct MCPListResourcesResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let resources: [MCPResource]
  public let nextCursor: String?
  public let cache: MCPCachePolicy
  public let metadata: MCPResultMetadata?
  public init(
    resources: [MCPResource], nextCursor: String? = nil, cache: MCPCachePolicy = .defaultListing,
    metadata: MCPResultMetadata? = nil
  ) {
    resultType = .complete
    self.resources = resources
    self.nextCursor = nextCursor
    self.cache = cache
    self.metadata = metadata
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    resultType = try mcpRequiredCompleteResultType(object)
    resources = try object.requiredArray("resources").map(MCPResource.init(json:))
    nextCursor = try object.optionalString("nextCursor")
    guard let cache = try MCPCachePolicy.extract(from: object, required: true) else {
      throw MCPJSONError.missingField("ttlMs")
    }
    self.cache = cache
    metadata = try object.values["_meta"].map(MCPResultMetadata.init(json:))
  }
  public var json: MCPJSONValue {
    var object: [String: MCPJSONValue] = [
      "resultType": .string("complete"), "resources": .array(resources.map(\.json)),
    ]
    if let nextCursor { object["nextCursor"] = .string(nextCursor) }
    if let metadata { object["_meta"] = metadata.json }
    cache.insert(into: &object)
    return .object(object)
  }
}

public struct MCPListResourceTemplatesResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let resourceTemplates: [MCPResourceTemplate]
  public let nextCursor: String?
  public let cache: MCPCachePolicy
  public let metadata: MCPResultMetadata?
  public init(
    resourceTemplates: [MCPResourceTemplate], nextCursor: String? = nil,
    cache: MCPCachePolicy = .defaultListing, metadata: MCPResultMetadata? = nil
  ) {
    resultType = .complete
    self.resourceTemplates = resourceTemplates
    self.nextCursor = nextCursor
    self.cache = cache
    self.metadata = metadata
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    resultType = try mcpRequiredCompleteResultType(object)
    resourceTemplates = try object.requiredArray("resourceTemplates").map(
      MCPResourceTemplate.init(json:))
    nextCursor = try object.optionalString("nextCursor")
    guard let cache = try MCPCachePolicy.extract(from: object, required: true) else {
      throw MCPJSONError.missingField("ttlMs")
    }
    self.cache = cache
    metadata = try object.values["_meta"].map(MCPResultMetadata.init(json:))
  }
  public var json: MCPJSONValue {
    var object: [String: MCPJSONValue] = [
      "resultType": .string("complete"), "resourceTemplates": .array(resourceTemplates.map(\.json)),
    ]
    if let nextCursor { object["nextCursor"] = .string(nextCursor) }
    if let metadata { object["_meta"] = metadata.json }
    cache.insert(into: &object)
    return .object(object)
  }
}

public struct MCPReadResourceParams: Sendable, Hashable, MCPJSONModel {
  public let uri: String
  public let inputResponses: [String: MCPElicitationResult]
  public let requestState: String?
  public init(
    uri: String, inputResponses: [String: MCPElicitationResult] = [:], requestState: String? = nil
  ) throws {
    guard !uri.isEmpty else {
      throw MCPJSONError.invalidField(field: "uri", reason: "must not be empty")
    }
    try mcpValidateMRTRRetry(inputResponses: inputResponses, requestState: requestState)
    self.uri = uri
    self.inputResponses = inputResponses
    self.requestState = requestState
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      uri: try object.requiredNonEmptyString("uri"),
      inputResponses: try mcpDecodeInputResponses(object.values["inputResponses"]),
      requestState: try object.optionalString("requestState"))
  }
  public var json: MCPJSONValue {
    mcpObject([
      ("uri", .string(uri)),
      ("inputResponses", inputResponses.isEmpty ? nil : .object(inputResponses.mapValues(\.json))),
      ("requestState", requestState.map(MCPJSONValue.string)),
    ])
  }
}

public struct MCPReadResourceResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let contents: [MCPResourceContents]
  public let cache: MCPCachePolicy?
  public let inputRequests: [String: MCPElicitationRequest]
  public let requestState: String?
  public let metadata: MCPResultMetadata?

  public init(
    contents: [MCPResourceContents] = [],
    cache: MCPCachePolicy? = .defaultResourceRead,
    resultType: MCPResultType = .complete,
    inputRequests: [String: MCPElicitationRequest] = [:],
    requestState: String? = nil,
    metadata: MCPResultMetadata? = nil
  ) throws {
    try mcpValidateOperationResult(
      resultType: resultType, hasCompleteField: true, inputRequests: inputRequests,
      requestState: requestState, completeField: "contents")
    if resultType == .complete, cache == nil { throw MCPJSONError.missingField("ttlMs") }
    if resultType == .inputRequired, cache != nil {
      throw MCPJSONError.invalidField(field: "ttlMs", reason: "input_required is not cacheable")
    }
    self.resultType = resultType
    self.contents = contents
    self.cache = cache
    self.inputRequests = inputRequests
    self.requestState = requestState
    self.metadata = metadata
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let resultType = try mcpResultType(object)
    let hasContents = object.values["contents"] != nil
    let decoded = try Self(
      contents: try object.optionalArray("contents")?.map(MCPResourceContents.init(json:)) ?? [],
      cache: try MCPCachePolicy.extract(from: object, required: resultType == .complete),
      resultType: resultType,
      inputRequests: try mcpDecodeInputRequests(object.values["inputRequests"]),
      requestState: try object.optionalString("requestState"),
      metadata: try object.values["_meta"].map(MCPResultMetadata.init(json:)))
    if resultType == .complete, !hasContents {
      throw MCPJSONError.missingField("contents")
    }
    self = decoded
  }
  public var json: MCPJSONValue {
    var value = mcpOperationResultJSON(
      resultType: resultType, completeFields: [("contents", .array(contents.map(\.json)))],
      inputRequests: inputRequests, requestState: requestState, metadata: metadata)
    guard case .object(var object) = value else { return value }
    cache?.insert(into: &object)
    value = .object(object)
    return value
  }
}

public struct MCPResourceUpdatedParams: Sendable, Hashable, MCPJSONModel {
  public let uri: String
  public init(uri: String) throws {
    guard !uri.isEmpty else {
      throw MCPJSONError.invalidField(field: "uri", reason: "must not be empty")
    }
    self.uri = uri
  }
  public init(json: MCPJSONValue) throws {
    try self.init(uri: MCPJSONObject(json).requiredNonEmptyString("uri"))
  }
  public var json: MCPJSONValue { .object(["uri": .string(uri)]) }
}

// MARK: - Completion

public enum MCPCompletionReference: Sendable, Hashable, MCPJSONModel {
  case prompt(name: String)
  case resource(uri: String)
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let type = try object.requiredString("type")
    switch type {
    case "ref/prompt": self = .prompt(name: try object.requiredNonEmptyString("name"))
    case "ref/resource": self = .resource(uri: try object.requiredNonEmptyString("uri"))
    default:
      throw MCPJSONError.invalidField(
        field: "ref.type", reason: "expected ref/prompt or ref/resource")
    }
  }
  public var json: MCPJSONValue {
    switch self {
    case .prompt(let name): .object(["type": .string("ref/prompt"), "name": .string(name)])
    case .resource(let uri): .object(["type": .string("ref/resource"), "uri": .string(uri)])
    }
  }
}

public struct MCPCompletionArgument: Sendable, Hashable, MCPJSONModel {
  public let name: String
  public let value: String
  public init(name: String, value: String) throws {
    guard !name.isEmpty else {
      throw MCPJSONError.invalidField(field: "argument.name", reason: "must not be empty")
    }
    self.name = name
    self.value = value
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      name: try object.requiredNonEmptyString("name"), value: try object.requiredString("value"))
  }
  public var json: MCPJSONValue { .object(["name": .string(name), "value": .string(value)]) }
}

public struct MCPCompleteParams: Sendable, Hashable, MCPJSONModel {
  public let reference: MCPCompletionReference
  public let argument: MCPCompletionArgument
  public let contextArguments: [String: String]
  public init(
    reference: MCPCompletionReference, argument: MCPCompletionArgument,
    contextArguments: [String: String] = [:]
  ) {
    self.reference = reference
    self.argument = argument
    self.contextArguments = contextArguments
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    reference = try MCPCompletionReference(
      json: object.values["ref"] ?? { throw MCPJSONError.missingField("ref") }())
    argument = try MCPCompletionArgument(
      json: object.values["argument"] ?? { throw MCPJSONError.missingField("argument") }())
    let context = try object.optionalObject("context") ?? [:]
    let arguments: [String: MCPJSONValue]
    if let raw = context["arguments"] {
      guard case .object(let value) = raw else {
        throw MCPJSONError.invalidField(field: "context.arguments", reason: "expected object")
      }
      arguments = value
    } else {
      arguments = [:]
    }
    var strings: [String: String] = [:]
    for (key, value) in arguments {
      guard case .string(let string) = value else {
        throw MCPJSONError.expectedString(field: "context.arguments.\(key)")
      }
      strings[key] = string
    }
    contextArguments = strings
  }
  public var json: MCPJSONValue {
    mcpObject([
      ("ref", reference.json), ("argument", argument.json),
      (
        "context",
        contextArguments.isEmpty
          ? nil : .object(["arguments": .object(contextArguments.mapValues(MCPJSONValue.string))])
      ),
    ])
  }
}

public struct MCPCompletion: Sendable, Hashable, MCPJSONModel {
  public let values: [String]
  /// The exact JSON Schema integer total, when the server provides one.
  public let total: MCPJSONNumber?
  public let hasMore: Bool?
  public init(values: [String], total: MCPJSONNumber? = nil, hasMore: Bool? = nil) throws {
    guard values.count <= 100 else {
      throw MCPJSONError.invalidField(field: "values", reason: "must contain at most 100 items")
    }
    if let total { try mcpValidateInteger(total, field: "total") }
    self.values = values
    self.total = total
    self.hasMore = hasMore
  }
  public init(values: [String], total: Int64, hasMore: Bool? = nil) throws {
    try self.init(values: values, total: MCPJSONNumber(total), hasMore: hasMore)
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      values: try object.requiredArray("values").map {
        guard case .string(let value) = $0 else {
          throw MCPJSONError.expectedString(field: "values[]")
        }
        return value
      }, total: try object.optionalNumber("total"), hasMore: try object.optionalBool("hasMore"))
  }
  public var json: MCPJSONValue {
    mcpObject([
      ("values", mcpStringArray(values)), ("total", total.map(MCPJSONValue.number)),
      ("hasMore", hasMore.map(MCPJSONValue.bool)),
    ])
  }
}

public struct MCPCompleteResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let completion: MCPCompletion
  public let metadata: MCPResultMetadata?
  public init(completion: MCPCompletion, metadata: MCPResultMetadata? = nil) {
    resultType = .complete
    self.completion = completion
    self.metadata = metadata
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    resultType = try mcpRequiredCompleteResultType(object)
    completion = try MCPCompletion(
      json: object.values["completion"] ?? { throw MCPJSONError.missingField("completion") }())
    metadata = try object.values["_meta"].map(MCPResultMetadata.init(json:))
  }
  public var json: MCPJSONValue {
    mcpObject([
      ("resultType", .string("complete")), ("completion", completion.json),
      ("_meta", metadata?.json),
    ])
  }
}

// MARK: - Subscriptions

public struct MCPSubscriptionFilter: Sendable, Hashable, MCPJSONModel {
  public let toolsListChanged: Bool
  public let promptsListChanged: Bool
  public let resourcesListChanged: Bool
  public let resourceSubscriptions: Set<String>

  public init(
    toolsListChanged: Bool = false, promptsListChanged: Bool = false,
    resourcesListChanged: Bool = false, resourceSubscriptions: Set<String> = []
  ) throws {
    guard resourceSubscriptions.allSatisfy({ !$0.isEmpty }) else {
      throw MCPJSONError.invalidField(
        field: "resourceSubscriptions", reason: "URIs must not be empty")
    }
    self.toolsListChanged = toolsListChanged
    self.promptsListChanged = promptsListChanged
    self.resourcesListChanged = resourcesListChanged
    self.resourceSubscriptions = resourceSubscriptions
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let uris: [String] =
      try object.optionalArray("resourceSubscriptions")?.map { value in
        guard case .string(let uri) = value, !uri.isEmpty else {
          throw MCPJSONError.expectedString(field: "resourceSubscriptions[]")
        }
        return uri
      } ?? []
    try self.init(
      toolsListChanged: try object.optionalBool("toolsListChanged") ?? false,
      promptsListChanged: try object.optionalBool("promptsListChanged") ?? false,
      resourcesListChanged: try object.optionalBool("resourcesListChanged") ?? false,
      resourceSubscriptions: Set(uris))
  }
  public var json: MCPJSONValue {
    mcpObject([
      ("toolsListChanged", toolsListChanged ? .bool(true) : nil),
      ("promptsListChanged", promptsListChanged ? .bool(true) : nil),
      ("resourcesListChanged", resourcesListChanged ? .bool(true) : nil),
      (
        "resourceSubscriptions",
        resourceSubscriptions.isEmpty ? nil : mcpStringArray(resourceSubscriptions.sorted())
      ),
    ])
  }

  public func accepted(by capabilities: MCPServerCapabilities) throws -> MCPSubscriptionFilter {
    try MCPSubscriptionFilter(
      toolsListChanged: toolsListChanged && capabilities.tools && capabilities.toolListChanged,
      promptsListChanged: promptsListChanged && capabilities.prompts
        && capabilities.promptListChanged,
      resourcesListChanged: resourcesListChanged && capabilities.resources
        && capabilities.resourceListChanged,
      resourceSubscriptions: capabilities.resources && capabilities.resourceSubscriptions
        ? resourceSubscriptions : [])
  }

  func isSubset(of requested: MCPSubscriptionFilter) -> Bool {
    (!toolsListChanged || requested.toolsListChanged)
      && (!promptsListChanged || requested.promptsListChanged)
      && (!resourcesListChanged || requested.resourcesListChanged)
      && resourceSubscriptions.isSubset(of: requested.resourceSubscriptions)
  }
}

public struct MCPSubscriptionsListenParams: Sendable, Hashable, MCPJSONModel {
  public let notifications: MCPSubscriptionFilter
  public init(notifications: MCPSubscriptionFilter) { self.notifications = notifications }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    notifications = try MCPSubscriptionFilter(
      json: object.values["notifications"] ?? { throw MCPJSONError.missingField("notifications") }()
    )
  }
  public var json: MCPJSONValue { .object(["notifications": notifications.json]) }
}

public struct MCPSubscriptionsAcknowledgedParams: Sendable, Hashable, MCPJSONModel {
  public let notifications: MCPSubscriptionFilter
  public let metadata: MCPNotificationMetadata
  public init(notifications: MCPSubscriptionFilter, subscriptionID: MCPRequestID) throws {
    self.notifications = notifications
    metadata = try MCPNotificationMetadata(subscriptionID: subscriptionID)
  }
  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    notifications = try MCPSubscriptionFilter(
      json: object.values["notifications"] ?? { throw MCPJSONError.missingField("notifications") }()
    )
    metadata = try MCPNotificationMetadata(
      json: object.values["_meta"] ?? { throw MCPJSONError.missingField("_meta") }())
    guard metadata.subscriptionID != nil else {
      throw MCPJSONError.missingField(MCPMetaKey.subscriptionID)
    }
  }
  public var json: MCPJSONValue {
    .object(["notifications": notifications.json, "_meta": metadata.json])
  }
}

public struct MCPSubscriptionsListenResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let subscriptionID: MCPRequestID
  public let serverInfo: MCPImplementation?
  public let metadataExtensions: [String: MCPJSONValue]

  public init(
    subscriptionID: MCPRequestID,
    serverInfo: MCPImplementation? = nil,
    metadataExtensions: [String: MCPJSONValue] = [:]
  ) throws {
    try MCPProtocolValidation.validateMetadataExtensions(
      metadataExtensions,
      sdkOwnedKeys: [MCPMetaKey.subscriptionID, MCPMetaKey.serverInfo]
    )
    resultType = .complete
    self.subscriptionID = subscriptionID
    self.serverInfo = serverInfo
    self.metadataExtensions = metadataExtensions
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    _ = try mcpRequiredCompleteResultType(object)
    let metadata = try MCPJSONObject(
      object.values["_meta"] ?? { throw MCPJSONError.missingField("_meta") }())
    try self.init(
      subscriptionID: MCPRequestID(
        json: metadata.values[MCPMetaKey.subscriptionID]
          ?? { throw MCPJSONError.missingField(MCPMetaKey.subscriptionID) }()),
      serverInfo: try metadata.values[MCPMetaKey.serverInfo].map(MCPImplementation.init(json:)),
      metadataExtensions: metadata.values.filter {
        $0.key != MCPMetaKey.subscriptionID && $0.key != MCPMetaKey.serverInfo
      }
    )
  }

  public var json: MCPJSONValue {
    var meta = metadataExtensions
    meta[MCPMetaKey.subscriptionID] = subscriptionID.json
    if let serverInfo { meta[MCPMetaKey.serverInfo] = serverInfo.json }
    return .object(["resultType": .string("complete"), "_meta": .object(meta)])
  }
}

public enum MCPSubscriptionState: Sendable, Equatable {
  case opening(requested: MCPSubscriptionFilter)
  case acknowledged(requested: MCPSubscriptionFilter, accepted: MCPSubscriptionFilter)
  case listening(accepted: MCPSubscriptionFilter, notificationCount: Int)
  case completed(notificationCount: Int)
  case interrupted(reason: String, notificationCount: Int)
}

public enum MCPSubscriptionEvent: Sendable, Equatable {
  case acknowledge(MCPSubscriptionFilter)
  case beginListening
  case receiveNotification
  case gracefulClose
  case serverCancel(String?)
  case disconnect(String)
}

public enum MCPSubscriptionReducerError: Error, Sendable, Equatable {
  case invalidTransition
  case acceptedFilterIsNotSubset
}

public enum MCPSubscriptionEffect: Sendable, Equatable {
  case sendAcknowledgement
  case sendTerminalResult
}

public enum MCPSubscriptionReducer {
  public static func reduce(
    state: MCPSubscriptionState,
    event: MCPSubscriptionEvent
  ) throws -> (MCPSubscriptionState, [MCPSubscriptionEffect]) {
    switch (state, event) {
    case (.opening(let requested), .acknowledge(let accepted)):
      guard accepted.isSubset(of: requested) else {
        throw MCPSubscriptionReducerError.acceptedFilterIsNotSubset
      }
      return (.acknowledged(requested: requested, accepted: accepted), [.sendAcknowledgement])
    case (.acknowledged(_, let accepted), .beginListening):
      return (.listening(accepted: accepted, notificationCount: 0), [])
    case (.listening(let accepted, let count), .receiveNotification):
      return (.listening(accepted: accepted, notificationCount: count + 1), [])
    case (.listening(_, let count), .gracefulClose):
      return (.completed(notificationCount: count), [.sendTerminalResult])
    case (.listening(_, let count), .serverCancel(let reason)):
      return (.interrupted(reason: reason ?? "server cancelled", notificationCount: count), [])
    case (.listening(_, let count), .disconnect(let reason)):
      return (.interrupted(reason: reason, notificationCount: count), [])
    default: throw MCPSubscriptionReducerError.invalidTransition
    }
  }
}

// MARK: - Helpers

private func mcpResultType(_ object: MCPJSONObject) throws -> MCPResultType {
  guard let value = object.values["resultType"] else {
    throw MCPJSONError.missingField("resultType")
  }
  guard case .string(let raw) = value else {
    throw MCPJSONError.invalidField(field: "resultType", reason: "expected string")
  }
  return try MCPResultType(rawValue: raw)
}

private func mcpValidateNonnegativeInteger(_ value: MCPJSONNumber, field: String) throws {
  try mcpValidateInteger(value, field: field)
  guard value.compare(to: MCPJSONNumber(0)) != .orderedAscending else {
    throw MCPJSONError.invalidField(field: field, reason: "must be non-negative")
  }
}

private func mcpValidateInteger(_ value: MCPJSONNumber, field: String) throws {
  guard value.isMathematicalInteger else { throw MCPJSONError.expectedInteger(field: field) }
}

private func mcpRequiredCompleteResultType(_ object: MCPJSONObject) throws -> MCPResultType {
  let resultType = try mcpResultType(object)
  guard resultType == .complete else {
    throw MCPJSONError.invalidField(field: "resultType", reason: "expected complete")
  }
  return resultType
}

private func mcpDecodeInputRequests(_ value: MCPJSONValue?) throws -> [String:
  MCPElicitationRequest]
{
  guard let value else { return [:] }
  guard case .object(let object) = value else {
    throw MCPJSONError.invalidField(field: "inputRequests", reason: "expected object")
  }
  var result: [String: MCPElicitationRequest] = [:]
  for (key, request) in object {
    guard !key.isEmpty else {
      throw MCPJSONError.invalidField(field: "inputRequests", reason: "keys must not be empty")
    }
    result[key] = try MCPElicitationRequest(json: request)
  }
  return result
}

private func mcpDecodeInputResponses(_ value: MCPJSONValue?) throws -> [String:
  MCPElicitationResult]
{
  guard let value else { return [:] }
  guard case .object(let object) = value else {
    throw MCPJSONError.invalidField(field: "inputResponses", reason: "expected object")
  }
  var result: [String: MCPElicitationResult] = [:]
  for (key, response) in object {
    guard !key.isEmpty else {
      throw MCPJSONError.invalidField(field: "inputResponses", reason: "keys must not be empty")
    }
    result[key] = try MCPElicitationResult(json: response)
  }
  return result
}

private func mcpValidateMRTRRetry(
  inputResponses: [String: MCPElicitationResult], requestState: String?
) throws {
  guard inputResponses.keys.allSatisfy({ !$0.isEmpty }) else {
    throw MCPJSONError.invalidField(field: "inputResponses", reason: "keys must not be empty")
  }
  if let requestState, requestState.isEmpty {
    throw MCPJSONError.invalidField(field: "requestState", reason: "must not be empty")
  }
}

private func mcpValidateOperationResult(
  resultType: MCPResultType,
  hasCompleteField: Bool,
  inputRequests: [String: MCPElicitationRequest],
  requestState: String?,
  completeField: String
) throws {
  switch resultType {
  case .complete:
    guard hasCompleteField else { throw MCPJSONError.missingField(completeField) }
    guard inputRequests.isEmpty, requestState == nil else {
      throw MCPJSONError.invalidField(
        field: "inputRequests", reason: "complete results must not carry MRTR state")
    }
  case .inputRequired:
    guard !inputRequests.isEmpty || requestState != nil else {
      throw MCPJSONError.invalidField(
        field: "resultType", reason: "input_required requires inputRequests or requestState")
    }
    guard inputRequests.keys.allSatisfy({ !$0.isEmpty }) else {
      throw MCPJSONError.invalidField(field: "inputRequests", reason: "keys must not be empty")
    }
    if let requestState, requestState.isEmpty {
      throw MCPJSONError.invalidField(field: "requestState", reason: "must not be empty")
    }
  case .extensionValue:
    break
  }
}

private func mcpOperationResultJSON(
  resultType: MCPResultType,
  completeFields: [(String, MCPJSONValue?)],
  inputRequests: [String: MCPElicitationRequest],
  requestState: String?,
  metadata: MCPResultMetadata?
) -> MCPJSONValue {
  var object: [String: MCPJSONValue] = ["resultType": .string(resultType.rawValue)]
  switch resultType {
  case .complete, .extensionValue:
    for (key, value) in completeFields { if let value { object[key] = value } }
  case .inputRequired:
    if !inputRequests.isEmpty { object["inputRequests"] = .object(inputRequests.mapValues(\.json)) }
    if let requestState { object["requestState"] = .string(requestState) }
  }
  if let metadata { object["_meta"] = metadata.json }
  return .object(object)
}
