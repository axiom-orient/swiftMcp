import Foundation

// MARK: - 2026-07-28 MRTR input model

/// The client-side capabilities for the deprecated-but-still-supported sampling input primitive.
/// `context` gates deprecated context inclusion and `tools` gates sampling tool use.
public struct MCPSamplingCapabilities: Sendable, Hashable, MCPJSONModel {
  /// The capability value is a JSONObject, not a Boolean. Keep the settings so decode/encode is
  /// lossless while exposing a Boolean view for request validation.
  public var contextSettings: [String: MCPJSONValue]?
  public var toolSettings: [String: MCPJSONValue]?

  public var context: Bool {
    get { contextSettings != nil }
    set { contextSettings = newValue ? (contextSettings ?? [:]) : nil }
  }

  public var tools: Bool {
    get { toolSettings != nil }
    set { toolSettings = newValue ? (toolSettings ?? [:]) : nil }
  }

  public init(context: Bool = false, tools: Bool = false) {
    contextSettings = context ? [:] : nil
    toolSettings = tools ? [:] : nil
  }

  public init(
    contextSettings: [String: MCPJSONValue]?,
    toolSettings: [String: MCPJSONValue]?
  ) {
    self.contextSettings = contextSettings
    self.toolSettings = toolSettings
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    contextSettings = try object.optionalObject("context")
    toolSettings = try object.optionalObject("tools")
  }

  public var json: MCPJSONValue {
    var object: [String: MCPJSONValue] = [:]
    if let contextSettings { object["context"] = .object(contextSettings) }
    if let toolSettings { object["tools"] = .object(toolSettings) }
    return .object(object)
  }
}

public struct MCPModelHint: Sendable, Hashable, MCPJSONModel {
  public let name: String?

  public init(name: String? = nil) throws {
    self.name = name
  }

  public init(json: MCPJSONValue) throws {
    try self.init(name: MCPJSONObject(json).optionalString("name"))
  }

  public var json: MCPJSONValue {
    mcpObject([("name", name.map(MCPJSONValue.string))])
  }
}

public struct MCPModelPreferences: Sendable, Hashable, MCPJSONModel {
  public let hints: [MCPModelHint]
  public let costPriority: MCPJSONNumber?
  public let speedPriority: MCPJSONNumber?
  public let intelligencePriority: MCPJSONNumber?

  public init(
    hints: [MCPModelHint] = [],
    costPriority: MCPJSONNumber? = nil,
    speedPriority: MCPJSONNumber? = nil,
    intelligencePriority: MCPJSONNumber? = nil
  ) throws {
    try Self.validatePriority(costPriority, field: "costPriority")
    try Self.validatePriority(speedPriority, field: "speedPriority")
    try Self.validatePriority(intelligencePriority, field: "intelligencePriority")
    self.hints = hints
    self.costPriority = costPriority
    self.speedPriority = speedPriority
    self.intelligencePriority = intelligencePriority
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      hints: try object.optionalArray("hints")?.map(MCPModelHint.init(json:)) ?? [],
      costPriority: try object.optionalNumber("costPriority"),
      speedPriority: try object.optionalNumber("speedPriority"),
      intelligencePriority: try object.optionalNumber("intelligencePriority")
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("hints", hints.isEmpty ? nil : .array(hints.map(\.json))),
      ("costPriority", costPriority.map(MCPJSONValue.number)),
      ("speedPriority", speedPriority.map(MCPJSONValue.number)),
      ("intelligencePriority", intelligencePriority.map(MCPJSONValue.number)),
    ])
  }

  private static func validatePriority(_ value: MCPJSONNumber?, field: String) throws {
    guard let value else { return }
    guard value.compare(to: MCPJSONNumber(0)) != .orderedAscending,
      value.compare(to: MCPJSONNumber(1)) != .orderedDescending
    else {
      throw MCPJSONError.invalidField(field: field, reason: "must be between 0 and 1")
    }
  }
}

public enum MCPSamplingIncludeContext: String, Sendable, Hashable, MCPJSONModel {
  case none
  case thisServer
  case allServers

  public init(json: MCPJSONValue) throws {
    guard case .string(let raw) = json, let value = Self(rawValue: raw) else {
      throw MCPJSONError.invalidField(
        field: "includeContext", reason: "expected none, thisServer, or allServers")
    }
    self = value
  }

  public var json: MCPJSONValue { .string(rawValue) }
}

public enum MCPSamplingToolChoiceMode: String, Sendable, Hashable, MCPJSONModel {
  case auto
  case required
  case none

  public init(json: MCPJSONValue) throws {
    guard case .string(let raw) = json, let value = Self(rawValue: raw) else {
      throw MCPJSONError.invalidField(
        field: "toolChoice.mode", reason: "expected auto, required, or none")
    }
    self = value
  }

  public var json: MCPJSONValue { .string(rawValue) }
}

public struct MCPSamplingToolChoice: Sendable, Hashable, MCPJSONModel {
  public let mode: MCPSamplingToolChoiceMode?

  public init(mode: MCPSamplingToolChoiceMode? = nil) { self.mode = mode }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    mode = try object.values["mode"].map(MCPSamplingToolChoiceMode.init(json:))
  }

  public var json: MCPJSONValue {
    mcpObject([("mode", mode?.json)])
  }
}

public struct MCPToolUseContent: Sendable, Hashable, MCPJSONModel {
  public let id: String
  public let name: String
  public let input: [String: MCPJSONValue]
  public let metadata: [String: MCPJSONValue]

  public init(
    id: String,
    name: String,
    input: [String: MCPJSONValue],
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.id = id
    self.name = name
    self.input = input
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard object.values["type"] == .string("tool_use") else {
      throw MCPJSONError.invalidField(field: "type", reason: "expected tool_use")
    }
    try self.init(
      id: try object.requiredString("id"),
      name: try object.requiredString("name"),
      input: try object.requiredObject("input"),
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("type", .string("tool_use")),
      ("id", .string(id)),
      ("name", .string(name)),
      ("input", .object(input)),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPToolResultContent: Sendable, Hashable, MCPJSONModel {
  public let toolUseID: String
  public let content: [MCPContentBlock]
  public let structuredContent: MCPJSONValue?
  public let isError: Bool
  public let metadata: [String: MCPJSONValue]

  public init(
    toolUseID: String,
    content: [MCPContentBlock],
    structuredContent: MCPJSONValue? = nil,
    isError: Bool = false,
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.toolUseID = toolUseID
    self.content = content
    self.structuredContent = structuredContent
    self.isError = isError
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard object.values["type"] == .string("tool_result") else {
      throw MCPJSONError.invalidField(field: "type", reason: "expected tool_result")
    }
    try self.init(
      toolUseID: try object.requiredString("toolUseId"),
      content: try object.requiredArray("content").map(MCPContentBlock.init(json:)),
      structuredContent: object.values["structuredContent"],
      isError: try object.optionalBool("isError") ?? false,
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("type", .string("tool_result")),
      ("toolUseId", .string(toolUseID)),
      ("content", .array(content.map(\.json))),
      ("structuredContent", structuredContent),
      ("isError", isError ? .bool(true) : nil),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public enum MCPSamplingContentBlock: Sendable, Hashable, MCPJSONModel {
  case text(MCPTextContent)
  case image(MCPBinaryContent)
  case audio(MCPBinaryContent)
  case toolUse(MCPToolUseContent)
  case toolResult(MCPToolResultContent)

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    switch try object.requiredString("type") {
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
    case "tool_use": self = .toolUse(try MCPToolUseContent(json: json))
    case "tool_result": self = .toolResult(try MCPToolResultContent(json: json))
    default:
      throw MCPJSONError.invalidField(field: "type", reason: "unsupported sampling content block")
    }
  }

  public var json: MCPJSONValue {
    switch self {
    case .text(let value): value.json
    case .image(let value), .audio(let value): value.json
    case .toolUse(let value): value.json
    case .toolResult(let value): value.json
    }
  }
}

public struct MCPSamplingMessage: Sendable, Hashable, MCPJSONModel {
  public let role: MCPRole
  public let content: [MCPSamplingContentBlock]
  public let metadata: [String: MCPJSONValue]

  public init(
    role: MCPRole,
    content: [MCPSamplingContentBlock],
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    guard !content.isEmpty else {
      throw MCPJSONError.invalidField(field: "content", reason: "must not be empty")
    }
    let containsToolUse = content.contains { block in
      if case .toolUse = block { return true }
      return false
    }
    let containsToolResult = content.contains { block in
      if case .toolResult = block { return true }
      return false
    }
    if containsToolUse, role != .assistant {
      throw MCPJSONError.invalidField(
        field: "content", reason: "tool_use blocks require the assistant role")
    }
    if containsToolResult {
      guard role == .user else {
        throw MCPJSONError.invalidField(
          field: "content", reason: "tool_result blocks require the user role")
      }
      guard
        content.allSatisfy({ block in
          if case .toolResult = block { return true }
          return false
        })
      else {
        throw MCPJSONError.invalidField(
          field: "content",
          reason: "a user message containing tool_result may contain only tool_result blocks")
      }
    }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.role = role
    self.content = content
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard let rawContent = object.values["content"] else {
      throw MCPJSONError.missingField("content")
    }
    let blocks: [MCPSamplingContentBlock]
    if case .array(let values) = rawContent {
      blocks = try values.map(MCPSamplingContentBlock.init(json:))
    } else {
      blocks = [try MCPSamplingContentBlock(json: rawContent)]
    }
    try self.init(
      role: MCPRole(json: object.values["role"] ?? { throw MCPJSONError.missingField("role") }()),
      content: blocks,
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    let contentJSON: MCPJSONValue =
      content.count == 1 ? content[0].json : .array(content.map(\.json))
    return mcpObject([
      ("role", role.json),
      ("content", contentJSON),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPCreateMessageParams: Sendable, Hashable, MCPJSONModel {
  public let messages: [MCPSamplingMessage]
  public let modelPreferences: MCPModelPreferences?
  public let systemPrompt: String?
  public let includeContext: MCPSamplingIncludeContext?
  public let temperature: MCPJSONNumber?
  public let maxTokens: MCPJSONNumber
  public let stopSequences: [String]
  public let metadata: [String: MCPJSONValue]?
  public let tools: [MCPTool]
  public let toolChoice: MCPSamplingToolChoice?

  public init(
    messages: [MCPSamplingMessage],
    modelPreferences: MCPModelPreferences? = nil,
    systemPrompt: String? = nil,
    includeContext: MCPSamplingIncludeContext? = nil,
    temperature: MCPJSONNumber? = nil,
    maxTokens: MCPJSONNumber,
    stopSequences: [String] = [],
    metadata: [String: MCPJSONValue]? = nil,
    tools: [MCPTool] = [],
    toolChoice: MCPSamplingToolChoice? = nil
  ) throws {
    guard maxTokens.isMathematicalInteger else {
      throw MCPJSONError.expectedInteger(field: "maxTokens")
    }
    try Self.validateToolSequence(messages)
    self.messages = messages
    self.modelPreferences = modelPreferences
    self.systemPrompt = systemPrompt
    self.includeContext = includeContext
    self.temperature = temperature
    self.maxTokens = maxTokens
    self.stopSequences = stopSequences
    self.metadata = metadata
    self.tools = tools
    self.toolChoice = toolChoice
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      messages: try object.requiredArray("messages").map(MCPSamplingMessage.init(json:)),
      modelPreferences: try object.values["modelPreferences"].map(MCPModelPreferences.init(json:)),
      systemPrompt: try object.optionalString("systemPrompt"),
      includeContext: try object.values["includeContext"].map(
        MCPSamplingIncludeContext.init(json:)),
      temperature: try object.optionalNumber("temperature"),
      maxTokens: try object.requiredNumber("maxTokens"),
      stopSequences: try object.optionalArray("stopSequences")?.map { value in
        guard case .string(let string) = value else {
          throw MCPJSONError.expectedString(field: "stopSequences[]")
        }
        return string
      } ?? [],
      metadata: try object.optionalObject("metadata"),
      tools: try object.optionalArray("tools")?.map(MCPTool.init(json:)) ?? [],
      toolChoice: try object.values["toolChoice"].map(MCPSamplingToolChoice.init(json:))
    )
  }

  private static func validateToolSequence(_ messages: [MCPSamplingMessage]) throws {
    var pendingToolUseIDs: Set<String> = []

    for (index, message) in messages.enumerated() {
      let toolUseIDs = message.content.compactMap { block -> String? in
        if case .toolUse(let value) = block { return value.id }
        return nil
      }
      let toolResultIDs = message.content.compactMap { block -> String? in
        if case .toolResult(let value) = block { return value.toolUseID }
        return nil
      }

      if !pendingToolUseIDs.isEmpty {
        let responseIDs = Set(toolResultIDs)
        guard message.role == .user,
          toolResultIDs.count == message.content.count,
          responseIDs.count == toolResultIDs.count,
          responseIDs == pendingToolUseIDs
        else {
          throw MCPJSONError.invalidField(
            field: "messages[\(index)]",
            reason: "must immediately answer every preceding tool_use exactly once")
        }
        pendingToolUseIDs.removeAll(keepingCapacity: true)
      } else if !toolResultIDs.isEmpty {
        throw MCPJSONError.invalidField(
          field: "messages[\(index)]", reason: "tool_result has no preceding tool_use")
      }

      if !toolUseIDs.isEmpty {
        let uniqueIDs = Set(toolUseIDs)
        guard uniqueIDs.count == toolUseIDs.count else {
          throw MCPJSONError.invalidField(
            field: "messages[\(index)]", reason: "tool_use ids must be unique within a message")
        }
        pendingToolUseIDs = uniqueIDs
      }
    }

    guard pendingToolUseIDs.isEmpty else {
      throw MCPJSONError.invalidField(
        field: "messages", reason: "the final tool_use message is missing its tool_result response")
    }
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("messages", .array(messages.map(\.json))),
      ("modelPreferences", modelPreferences?.json),
      ("systemPrompt", systemPrompt.map(MCPJSONValue.string)),
      ("includeContext", includeContext?.json),
      ("temperature", temperature.map(MCPJSONValue.number)),
      ("maxTokens", .number(maxTokens)),
      (
        "stopSequences",
        stopSequences.isEmpty ? nil : .array(stopSequences.map(MCPJSONValue.string))
      ),
      ("metadata", metadata.map(MCPJSONValue.object)),
      ("tools", tools.isEmpty ? nil : .array(tools.map(\.json))),
      ("toolChoice", toolChoice?.json),
    ])
  }
}

public struct MCPCreateMessageRequest: Sendable, Hashable, MCPJSONModel {
  public let params: MCPCreateMessageParams

  public init(params: MCPCreateMessageParams) { self.params = params }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard try object.requiredString("method") == "sampling/createMessage" else {
      throw MCPJSONError.invalidField(field: "method", reason: "expected sampling/createMessage")
    }
    params = try MCPCreateMessageParams(
      json: object.values["params"] ?? { throw MCPJSONError.missingField("params") }())
  }

  public var json: MCPJSONValue {
    .object(["method": .string("sampling/createMessage"), "params": params.json])
  }
}

public struct MCPCreateMessageResult: Sendable, Hashable, MCPJSONModel {
  public let role: MCPRole
  public let content: [MCPSamplingContentBlock]
  public let model: String
  public let stopReason: String?
  public let metadata: [String: MCPJSONValue]

  public init(
    role: MCPRole,
    content: [MCPSamplingContentBlock],
    model: String,
    stopReason: String? = nil,
    metadata: [String: MCPJSONValue] = [:]
  ) throws {
    _ = try MCPSamplingMessage(role: role, content: content, metadata: metadata)
    self.role = role
    self.content = content
    self.model = model
    self.stopReason = stopReason
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let message = try MCPSamplingMessage(json: json)
    try self.init(
      role: message.role,
      content: message.content,
      model: try object.requiredString("model"),
      stopReason: try object.optionalString("stopReason"),
      metadata: message.metadata
    )
  }

  public var json: MCPJSONValue {
    let contentJSON: MCPJSONValue =
      content.count == 1 ? content[0].json : .array(content.map(\.json))
    var object: [String: MCPJSONValue] = [
      "role": role.json,
      "content": contentJSON,
      "model": .string(model),
    ]
    if let stopReason { object["stopReason"] = .string(stopReason) }
    if !metadata.isEmpty { object["_meta"] = .object(metadata) }
    return .object(object)
  }
}

public struct MCPRoot: Sendable, Hashable, MCPJSONModel {
  public let uri: String
  public let name: String?
  public let metadata: [String: MCPJSONValue]

  public init(uri: String, name: String? = nil, metadata: [String: MCPJSONValue] = [:]) throws {
    guard uri.hasPrefix("file://") else {
      throw MCPJSONError.invalidField(field: "uri", reason: "roots currently require file:// URIs")
    }
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.uri = uri
    self.name = name
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      uri: try object.requiredNonEmptyString("uri"),
      name: try object.optionalString("name"),
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("uri", .string(uri)),
      ("name", name.map(MCPJSONValue.string)),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public struct MCPListRootsRequest: Sendable, Hashable, MCPJSONModel {
  public let metadata: [String: MCPJSONValue]

  public init(metadata: [String: MCPJSONValue] = [:]) throws {
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    guard try object.requiredString("method") == "roots/list" else {
      throw MCPJSONError.invalidField(field: "method", reason: "expected roots/list")
    }
    if let rawParams = object.values["params"] {
      metadata = try MCPJSONObject(rawParams).optionalObject("_meta") ?? [:]
      try MCPProtocolValidation.validateMetadataExtensions(metadata)
    } else {
      metadata = [:]
    }
  }

  public var json: MCPJSONValue {
    var object: [String: MCPJSONValue] = ["method": .string("roots/list")]
    if !metadata.isEmpty { object["params"] = .object(["_meta": .object(metadata)]) }
    return .object(object)
  }
}

public struct MCPListRootsResult: Sendable, Hashable, MCPJSONModel {
  public let roots: [MCPRoot]
  public let metadata: [String: MCPJSONValue]

  public init(roots: [MCPRoot], metadata: [String: MCPJSONValue] = [:]) throws {
    try MCPProtocolValidation.validateMetadataExtensions(metadata)
    self.roots = roots
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      roots: try object.requiredArray("roots").map(MCPRoot.init(json:)),
      metadata: try object.optionalObject("_meta") ?? [:]
    )
  }

  public var json: MCPJSONValue {
    mcpObject([
      ("roots", .array(roots.map(\.json))),
      ("_meta", metadata.isEmpty ? nil : .object(metadata)),
    ])
  }
}

public enum MCPInputRequest: Sendable, Hashable, MCPJSONModel {
  case elicitation(MCPElicitationRequest)
  case sampling(MCPCreateMessageRequest)
  case roots(MCPListRootsRequest)

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    switch try object.requiredString("method") {
    case "elicitation/create": self = .elicitation(try MCPElicitationRequest(json: json))
    case "sampling/createMessage": self = .sampling(try MCPCreateMessageRequest(json: json))
    case "roots/list": self = .roots(try MCPListRootsRequest(json: json))
    default:
      throw MCPJSONError.invalidField(field: "method", reason: "unsupported MRTR input request")
    }
  }

  public var json: MCPJSONValue {
    switch self {
    case .elicitation(let value): value.json
    case .sampling(let value): value.json
    case .roots(let value): value.json
    }
  }

  /// Validates only the discriminated response kind required by the MRTR wire contract.
  /// Application-level validation of elicitation content against `requestedSchema` is explicit and
  /// remains available through `MCPElicitationParams.validate(result:)`.
  public func validateResponseKind(_ response: MCPInputResponse) throws {
    switch (self, response) {
    case (.elicitation, .elicitation), (.sampling, .sampling), (.roots, .roots):
      break
    default:
      throw MCPJSONError.invalidField(
        field: "inputResponses", reason: "response type does not match input request")
    }
  }
}

public enum MCPInputResponse: Sendable, Hashable, MCPJSONModel {
  case elicitation(MCPElicitationResult)
  case sampling(MCPCreateMessageResult)
  case roots(MCPListRootsResult)

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let markers = [
      object.values["action"] != nil,
      object.values["model"] != nil && object.values["role"] != nil,
      object.values["roots"] != nil,
    ]
    guard markers.filter({ $0 }).count == 1 else {
      throw MCPJSONError.invalidField(
        field: "inputResponses", reason: "input response is ambiguous or unsupported")
    }
    if markers[0] {
      self = .elicitation(try MCPElicitationResult(json: json))
    } else if markers[1] {
      self = .sampling(try MCPCreateMessageResult(json: json))
    } else {
      self = .roots(try MCPListRootsResult(json: json))
    }
  }

  public var json: MCPJSONValue {
    switch self {
    case .elicitation(let value): value.json
    case .sampling(let value): value.json
    case .roots(let value): value.json
    }
  }
}
