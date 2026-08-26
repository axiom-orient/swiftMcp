import Foundation
import MCP

public enum MCPTasksExtension {
  public static let identifier = "io.modelcontextprotocol/tasks"
  public static let taskResultType = "task"

  public static func clientCapabilities() throws -> MCPClientCapabilities {
    try clientCapabilities(extending: MCPClientCapabilities())
  }

  public static func clientCapabilities(
    extending base: MCPClientCapabilities
  ) throws -> MCPClientCapabilities {
    var extensions = base.extensions
    extensions[identifier] = .object([:])
    return try MCPClientCapabilities(
      elicitation: base.elicitation,
      experimental: base.experimental,
      extensions: extensions,
      additionalCapabilities: base.additionalCapabilities
    )
  }

  public static func supportsTasks(_ capabilities: MCPClientCapabilities) -> Bool {
    guard case .object(let value)? = capabilities.extensions[identifier] else { return false }
    return value.isEmpty
  }

  public static func methodRegistry() throws -> MCPMethodRegistry {
    try MCPMethodRegistry(extensionMethods: extensionDescriptors())
  }

  private static func extensionDescriptors() throws -> [MCPMethodDescriptor] {
    [
      try callToolExtensionDescriptor(),
      try getTaskDescriptor(),
      try updateTaskDescriptor(),
      try cancelTaskDescriptor(),
    ]
  }

  /// Produces the package-scoped proof used by the Tasks server wrapper.
  package static func officialRegistration() throws -> MCPOfficialExtensionRegistration {
    try MCPOfficialExtensionRegistration(
      identifier: identifier,
      methods: extensionDescriptors(),
      capability: .object([:])
    )
  }

  private static func callToolExtensionDescriptor() throws -> MCPMethodDescriptor {
    try MCPMethodDescriptor(
      name: "tools/call",
      direction: .clientToServerRequest,
      requiredServerCapability: .tools,
      cacheability: .none,
      httpNameSource: .parameter("name"),
      allowsMRTR: true,
      extensionResultTypes: [taskResultType],
      isExtension: true,
      extensionIdentifier: identifier
    )
  }

  private static func getTaskDescriptor() throws -> MCPMethodDescriptor {
    try MCPMethodDescriptor(
      name: "tasks/get",
      direction: .clientToServerRequest,
      httpNameSource: .parameter("taskId"),
      isExtension: true,
      extensionIdentifier: identifier
    )
  }

  private static func updateTaskDescriptor() throws -> MCPMethodDescriptor {
    try MCPMethodDescriptor(
      name: "tasks/update",
      direction: .clientToServerRequest,
      httpNameSource: .parameter("taskId"),
      isExtension: true,
      extensionIdentifier: identifier
    )
  }

  private static func cancelTaskDescriptor() throws -> MCPMethodDescriptor {
    try MCPMethodDescriptor(
      name: "tasks/cancel",
      direction: .clientToServerRequest,
      httpNameSource: .parameter("taskId"),
      isExtension: true,
      extensionIdentifier: identifier
    )
  }
}

public enum MCPTasksMethods {
  public static var callTool: MCPMethod<MCPCallToolParams, MCPTasksCallToolResult> {
    get throws { MCPMethod(try MCPTasksExtension.methodRegistry().require("tools/call")) }
  }

  public static var get: MCPMethod<MCPGetTaskParams, MCPGetTaskResult> {
    get throws { MCPMethod(try MCPTasksExtension.methodRegistry().require("tasks/get")) }
  }

  public static var update: MCPMethod<MCPUpdateTaskParams, MCPTaskAcknowledgement> {
    get throws { MCPMethod(try MCPTasksExtension.methodRegistry().require("tasks/update")) }
  }

  public static var cancel: MCPMethod<MCPCancelTaskParams, MCPTaskAcknowledgement> {
    get throws { MCPMethod(try MCPTasksExtension.methodRegistry().require("tasks/cancel")) }
  }
}

public enum MCPTaskStatus: String, Sendable, Hashable, CaseIterable {
  case working
  case inputRequired = "input_required"
  case completed
  case failed
  case cancelled

  public var isTerminal: Bool {
    switch self {
    case .completed, .failed, .cancelled: true
    case .working, .inputRequired: false
    }
  }
}

public struct MCPTask: Sendable, Hashable, MCPJSONModel {
  public let taskID: String
  public let status: MCPTaskStatus
  public let statusMessage: String?
  public let createdAt: String
  public let lastUpdatedAt: String
  /// Nil represents the required JSON `null` value, meaning unlimited lifetime.
  public let ttlMilliseconds: MCPJSONNumber?
  public let pollIntervalMilliseconds: MCPJSONNumber?

  public init(
    taskID: String,
    status: MCPTaskStatus,
    statusMessage: String? = nil,
    createdAt: String,
    lastUpdatedAt: String,
    ttlMilliseconds: MCPJSONNumber?,
    pollIntervalMilliseconds: MCPJSONNumber? = nil
  ) throws {
    guard !taskID.isEmpty else {
      throw MCPJSONError.invalidField(field: "taskId", reason: "must not be empty")
    }
    try MCPTasksValidation.validateTimestamp(createdAt, field: "createdAt")
    try MCPTasksValidation.validateTimestamp(lastUpdatedAt, field: "lastUpdatedAt")
    if let ttlMilliseconds {
      try MCPTasksValidation.validateNonnegativeInteger(ttlMilliseconds, field: "ttlMs")
    }
    if let pollIntervalMilliseconds {
      try MCPTasksValidation.validateNonnegativeInteger(
        pollIntervalMilliseconds, field: "pollIntervalMs")
    }
    self.taskID = taskID
    self.status = status
    self.statusMessage = statusMessage
    self.createdAt = createdAt
    self.lastUpdatedAt = lastUpdatedAt
    self.ttlMilliseconds = ttlMilliseconds
    self.pollIntervalMilliseconds = pollIntervalMilliseconds
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let rawStatus = try object.requiredString("status")
    guard let status = MCPTaskStatus(rawValue: rawStatus) else {
      throw MCPJSONError.invalidField(field: "status", reason: "unsupported task status")
    }
    guard let ttl = object.values["ttlMs"] else {
      throw MCPJSONError.missingField("ttlMs")
    }
    let ttlMilliseconds: MCPJSONNumber?
    switch ttl {
    case .null:
      ttlMilliseconds = nil
    case .number(let number):
      ttlMilliseconds = number
    default:
      throw MCPJSONError.invalidField(field: "ttlMs", reason: "expected integer or null")
    }
    try self.init(
      taskID: try object.requiredNonEmptyString("taskId"),
      status: status,
      statusMessage: try object.optionalString("statusMessage"),
      createdAt: try object.requiredNonEmptyString("createdAt"),
      lastUpdatedAt: try object.requiredNonEmptyString("lastUpdatedAt"),
      ttlMilliseconds: ttlMilliseconds,
      pollIntervalMilliseconds: try object.optionalNumber("pollIntervalMs")
    )
  }

  public var json: MCPJSONValue {
    var object: [String: MCPJSONValue] = [
      "taskId": .string(taskID),
      "status": .string(status.rawValue),
      "createdAt": .string(createdAt),
      "lastUpdatedAt": .string(lastUpdatedAt),
      "ttlMs": ttlMilliseconds.map(MCPJSONValue.number) ?? .null,
    ]
    if let statusMessage { object["statusMessage"] = .string(statusMessage) }
    if let pollIntervalMilliseconds {
      object["pollIntervalMs"] = .number(pollIntervalMilliseconds)
    }
    return .object(object)
  }
}

/// A complete task snapshot whose status and status-specific payload are coupled by
/// construction. The storage is private so a caller cannot create, retain, or emit a snapshot
/// such as `status == working` with a completed-result payload.
public struct MCPDetailedTask: Sendable, Hashable, MCPJSONModel {
  private enum Payload: Sendable, Hashable {
    case working
    case inputRequired([String: MCPJSONValue])
    case completed([String: MCPJSONValue])
    case failed(MCPRPCError)
    case cancelled
  }

  private let taskValue: MCPTask
  private let payload: Payload

  private init(task: MCPTask, payload: Payload) {
    self.taskValue = task
    self.payload = payload
  }

  /// Constructs a working snapshot. The task must already carry the matching status.
  public static func working(_ task: MCPTask) throws -> Self {
    Self(task: try requireStatus(task, .working), payload: .working)
  }

  /// Constructs an input-required snapshot and validates every embedded request.
  public static func inputRequired(
    _ task: MCPTask,
    inputRequests: [String: MCPJSONValue]
  ) throws -> Self {
    let task = try requireStatus(task, .inputRequired)
    try MCPTasksValidation.validateInputRequests(inputRequests)
    return Self(task: task, payload: .inputRequired(inputRequests))
  }

  /// Constructs a completed snapshot. The result object is preserved without interpretation.
  public static func completed(
    _ task: MCPTask,
    result: [String: MCPJSONValue]
  ) throws -> Self {
    Self(task: try requireStatus(task, .completed), payload: .completed(result))
  }

  /// Constructs a failed snapshot. The error is the protocol-level task error payload.
  public static func failed(_ task: MCPTask, error: MCPRPCError) throws -> Self {
    Self(task: try requireStatus(task, .failed), payload: .failed(error))
  }

  /// Constructs a cancelled snapshot. The task must already carry the matching status.
  public static func cancelled(_ task: MCPTask) throws -> Self {
    Self(task: try requireStatus(task, .cancelled), payload: .cancelled)
  }

  public var task: MCPTask { taskValue }

  /// The payload is present only for the corresponding task status.
  public var inputRequests: [String: MCPJSONValue]? {
    guard case .inputRequired(let requests) = payload else { return nil }
    return requests
  }

  /// The payload is present only for the completed task status.
  public var result: [String: MCPJSONValue]? {
    guard case .completed(let result) = payload else { return nil }
    return result
  }

  /// The payload is present only for the failed task status.
  public var error: MCPRPCError? {
    guard case .failed(let error) = payload else { return nil }
    return error
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let task = try MCPTask(json: json)
    let hasInput = object.values["inputRequests"] != nil
    let hasResult = object.values["result"] != nil
    let hasError = object.values["error"] != nil

    switch task.status {
    case .working:
      try MCPTasksValidation.requireNoPayload(
        hasInput: hasInput, hasResult: hasResult, hasError: hasError, status: task.status)
      self = try Self.working(task)
    case .inputRequired:
      guard !hasResult, !hasError else {
        throw MCPJSONError.invalidField(
          field: "status", reason: "input_required forbids result and error")
      }
      self = try Self.inputRequired(
        task, inputRequests: try object.requiredObject("inputRequests"))
    case .completed:
      guard !hasInput, !hasError else {
        throw MCPJSONError.invalidField(
          field: "status", reason: "completed forbids inputRequests and error")
      }
      self = try Self.completed(task, result: try object.requiredObject("result"))
    case .failed:
      guard !hasInput, !hasResult else {
        throw MCPJSONError.invalidField(
          field: "status", reason: "failed forbids inputRequests and result")
      }
      self = try Self.failed(
        task,
        error: try MCPRPCError(
          json: object.values["error"] ?? { throw MCPJSONError.missingField("error") }())
      )
    case .cancelled:
      try MCPTasksValidation.requireNoPayload(
        hasInput: hasInput, hasResult: hasResult, hasError: hasError, status: task.status)
      self = try Self.cancelled(task)
    }
  }

  public var json: MCPJSONValue {
    var object = task.json.objectValue ?? [:]
    switch payload {
    case .working, .cancelled:
      break
    case .inputRequired(let inputRequests):
      object["inputRequests"] = .object(inputRequests)
    case .completed(let result):
      object["result"] = .object(result)
    case .failed(let error):
      object["error"] = error.json
    }
    return .object(object)
  }

  private static func requireStatus(_ task: MCPTask, _ expected: MCPTaskStatus) throws -> MCPTask {
    guard task.status == expected else {
      throw MCPJSONError.invalidField(
        field: "status",
        reason: "\(expected.rawValue) payload cannot be used with \(task.status.rawValue) task"
      )
    }
    return task
  }
}

public struct MCPCreateTaskResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let task: MCPTask
  public let metadata: MCPResultMetadata?

  public init(task: MCPTask, metadata: MCPResultMetadata? = nil) {
    resultType = .extensionValue(MCPTasksExtension.taskResultType)
    self.task = task
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let resultType = try MCPTasksValidation.resultType(object)
    guard resultType == .extensionValue(MCPTasksExtension.taskResultType) else {
      throw MCPJSONError.invalidField(field: "resultType", reason: "expected task")
    }
    guard object.values["inputRequests"] == nil, object.values["result"] == nil,
      object.values["error"] == nil
    else {
      throw MCPJSONError.invalidField(
        field: "resultType", reason: "CreateTaskResult contains DetailedTask payload")
    }
    self.resultType = resultType
    task = try MCPTask(json: json)
    metadata = try object.values["_meta"].map(MCPResultMetadata.init(json:))
  }

  public var json: MCPJSONValue {
    var object = task.json.objectValue ?? [:]
    object["resultType"] = .string(MCPTasksExtension.taskResultType)
    if let metadata { object["_meta"] = metadata.json }
    return .object(object)
  }
}

public struct MCPGetTaskResult: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let task: MCPDetailedTask
  public let metadata: MCPResultMetadata?

  public init(task: MCPDetailedTask, metadata: MCPResultMetadata? = nil) {
    resultType = .complete
    self.task = task
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let resultType = try MCPTasksValidation.resultType(object)
    guard resultType == .complete else {
      throw MCPJSONError.invalidField(field: "resultType", reason: "expected complete")
    }
    self.resultType = resultType
    task = try MCPDetailedTask(json: json)
    metadata = try object.values["_meta"].map(MCPResultMetadata.init(json:))
  }

  public var json: MCPJSONValue {
    var object = task.json.objectValue ?? [:]
    object["resultType"] = .string("complete")
    if let metadata { object["_meta"] = metadata.json }
    return .object(object)
  }
}

public struct MCPTaskAcknowledgement: Sendable, Hashable, MCPJSONModel {
  public let resultType: MCPResultType
  public let metadata: MCPResultMetadata?

  public init(metadata: MCPResultMetadata? = nil) {
    resultType = .complete
    self.metadata = metadata
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let resultType = try MCPTasksValidation.resultType(object)
    guard resultType == .complete else {
      throw MCPJSONError.invalidField(field: "resultType", reason: "expected complete")
    }
    self.resultType = resultType
    metadata = try object.values["_meta"].map(MCPResultMetadata.init(json:))
  }

  public var json: MCPJSONValue {
    var object: [String: MCPJSONValue] = ["resultType": .string("complete")]
    if let metadata { object["_meta"] = metadata.json }
    return .object(object)
  }
}

public struct MCPGetTaskParams: Sendable, Hashable, MCPJSONModel {
  public let taskID: String

  public init(taskID: String) throws {
    guard !taskID.isEmpty else {
      throw MCPJSONError.invalidField(field: "taskId", reason: "must not be empty")
    }
    self.taskID = taskID
  }

  public init(json: MCPJSONValue) throws {
    try self.init(taskID: MCPJSONObject(json).requiredNonEmptyString("taskId"))
  }

  public var json: MCPJSONValue { .object(["taskId": .string(taskID)]) }
}

public struct MCPUpdateTaskParams: Sendable, Hashable, MCPJSONModel {
  public let taskID: String
  public let inputResponses: [String: MCPJSONValue]

  public init(taskID: String, inputResponses: [String: MCPJSONValue]) throws {
    guard !taskID.isEmpty else {
      throw MCPJSONError.invalidField(field: "taskId", reason: "must not be empty")
    }
    guard inputResponses.keys.allSatisfy({ !$0.isEmpty }) else {
      throw MCPJSONError.invalidField(
        field: "inputResponses", reason: "response keys must not be empty")
    }
    try MCPTasksValidation.validateInputResponses(inputResponses)
    self.taskID = taskID
    self.inputResponses = inputResponses
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      taskID: try object.requiredNonEmptyString("taskId"),
      inputResponses: try object.requiredObject("inputResponses")
    )
  }

  public var json: MCPJSONValue {
    .object(["taskId": .string(taskID), "inputResponses": .object(inputResponses)])
  }
}

public struct MCPCancelTaskParams: Sendable, Hashable, MCPJSONModel {
  public let taskID: String

  public init(taskID: String) throws {
    guard !taskID.isEmpty else {
      throw MCPJSONError.invalidField(field: "taskId", reason: "must not be empty")
    }
    self.taskID = taskID
  }

  public init(json: MCPJSONValue) throws {
    try self.init(taskID: MCPJSONObject(json).requiredNonEmptyString("taskId"))
  }

  public var json: MCPJSONValue { .object(["taskId": .string(taskID)]) }
}

public enum MCPTasksCallToolResult: Sendable, Hashable, MCPJSONModel {
  case immediate(MCPCallToolResult)
  case task(MCPCreateTaskResult)

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    let resultType = try MCPTasksValidation.resultType(object)
    if resultType == .extensionValue(MCPTasksExtension.taskResultType) {
      self = .task(try MCPCreateTaskResult(json: json))
    } else if resultType == .complete || resultType == .inputRequired {
      self = .immediate(try MCPCallToolResult(json: json))
    } else {
      throw MCPJSONError.invalidField(
        field: "resultType", reason: "unsupported tools/call result type")
    }
  }

  public var json: MCPJSONValue {
    switch self {
    case .immediate(let result): result.json
    case .task(let result): result.json
    }
  }
}

public struct MCPTaskStatusNotification: Sendable, Hashable {
  public let task: MCPDetailedTask
  public let metadata: [String: MCPJSONValue]

  public init(task: MCPDetailedTask, metadata: [String: MCPJSONValue] = [:]) {
    self.task = task
    self.metadata = metadata
  }

  public init(_ notification: MCPWireNotification) throws {
    guard notification.method == "notifications/tasks" else {
      throw MCPJSONError.invalidField(
        field: "method", reason: "expected notifications/tasks")
    }
    task = try MCPDetailedTask(json: .object(notification.params))
    let rawMetadata = try MCPJSONObject(.object(notification.params)).optionalObject("_meta") ?? [:]
    // Notification metadata has a distinct reserved-key set from result metadata. Keep the
    // public dictionary shape while validating it through the core model.
    let validatedMetadata = try MCPNotificationMetadata(json: .object(rawMetadata))
    metadata = validatedMetadata.json.objectValue ?? [:]
  }

  public var wireNotification: MCPWireNotification {
    get throws {
      var params = task.json.objectValue ?? [:]
      if !metadata.isEmpty { params["_meta"] = .object(metadata) }
      return try MCPWireNotification(method: "notifications/tasks", params: params)
    }
  }
}

private enum MCPTasksValidation {
  /// JSON Schema's safe integer range. SwiftMCP keeps the exact JSON number lexeme, so this
  /// explicit bound is required instead of converting through Double or Int64.
  private static let maximumSafeInteger = MCPJSONNumber(9_007_199_254_740_991)

  static func resultType(_ object: MCPJSONObject) throws -> MCPResultType {
    let raw = try object.requiredString("resultType")
    return try MCPResultType(rawValue: raw)
  }

  static func validateNonnegativeInteger(_ value: MCPJSONNumber, field: String) throws {
    guard value.isMathematicalInteger else { throw MCPJSONError.expectedInteger(field: field) }
    guard value.compare(to: MCPJSONNumber(0)) != .orderedAscending else {
      throw MCPJSONError.invalidField(field: field, reason: "must be non-negative")
    }
    guard value.compare(to: maximumSafeInteger) != .orderedDescending else {
      throw MCPJSONError.invalidField(
        field: field, reason: "must be a safe integer (at most 9007199254740991)")
    }
  }

  static func validateTimestamp(_ value: String, field: String) throws {
    guard !value.isEmpty, isISO8601(value) else {
      throw MCPJSONError.invalidField(field: field, reason: "must be an ISO 8601 timestamp")
    }
  }

  static func validateInputRequests(_ requests: [String: MCPJSONValue]) throws {
    guard requests.keys.allSatisfy({ !$0.isEmpty }) else {
      throw MCPJSONError.invalidField(
        field: "inputRequests", reason: "request keys must not be empty")
    }
    for (key, value) in requests {
      let request = try MCPJSONObject(value)
      let method = try request.requiredNonEmptyString("method")
      if request.values["id"] != nil || request.values["jsonrpc"] != nil {
        throw MCPJSONError.invalidField(
          field: "inputRequests.\(key)",
          reason: "embedded requests contain method and params only")
      }
      switch method {
      case "elicitation/create":
        // The core model owns the complete form/URL validation, including its restricted schema.
        _ = try MCPElicitationRequest(json: value)
      case "roots/list":
        // params is optional for roots/list in the Stable schema. If present, it is an object.
        if let params = request.values["params"] {
          guard case .object = params else {
            throw MCPJSONError.invalidField(
              field: "inputRequests.\(key).params", reason: "expected object")
          }
        }
      case "sampling/createMessage":
        try validateSamplingRequest(request, key: key)
      default:
        throw MCPJSONError.invalidField(
          field: "inputRequests.\(key).method", reason: "unsupported input request method")
      }
    }
  }

  static func validateInputResponses(_ responses: [String: MCPJSONValue]) throws {
    for (key, value) in responses {
      guard case .object(let response) = value else {
        throw MCPJSONError.invalidField(
          field: "inputResponses.\(key)", reason: "response must be an object")
      }
      if response["id"] != nil || response["jsonrpc"] != nil {
        throw MCPJSONError.invalidField(
          field: "inputResponses.\(key)",
          reason: "embedded responses contain result fields only")
      }
      try validateInputResponse(response, key: key)
    }
  }

  private static func validateInputResponse(
    _ response: [String: MCPJSONValue],
    key: String
  ) throws {
    // InputResponse is an open union: unknown members are ignored by the task store, but every
    // value must still be one of the three stable response shapes. Try each branch so an
    // extension field that happens to overlap another branch does not change validity.
    do {
      try validateElicitationResult(response, key: key)
      return
    } catch {
      // Try the remaining stable union members.
    }
    do {
      try validateRootsResult(response, key: key)
      return
    } catch {
      // Try the remaining stable union member.
    }
    do {
      try validateCreateMessageResult(response, key: key)
      return
    } catch {
      throw MCPJSONError.invalidField(
        field: "inputResponses.\(key)",
        reason: "must be a valid ElicitResult, ListRootsResult, or CreateMessageResult")
    }
  }

  private static func validateElicitationResult(
    _ response: [String: MCPJSONValue],
    key: String
  ) throws {
    let result = try MCPElicitationResult(json: .object(response))
    try validatePrimitiveElicitationContent(result.content, key: key)
  }

  private static func validatePrimitiveElicitationContent(
    _ content: [String: MCPJSONValue]?,
    key: String
  ) throws {
    guard let content else { return }
    for (name, value) in content {
      let field = "inputResponses.\(key).content.\(name)"
      switch value {
      case .string, .bool:
        continue
      case .number(let number):
        guard number.isMathematicalInteger else {
          throw MCPJSONError.invalidField(
            field: field, reason: "expected string, integer, boolean, or string array")
        }
      case .array(let values):
        guard values.allSatisfy({ if case .string = $0 { true } else { false } }) else {
          throw MCPJSONError.invalidField(
            field: field, reason: "expected string, integer, boolean, or string array")
        }
      default:
        throw MCPJSONError.invalidField(
          field: field, reason: "expected string, integer, boolean, or string array")
      }
    }
  }

  private static func validateRootsResult(
    _ response: [String: MCPJSONValue],
    key: String
  ) throws {
    let object = try MCPJSONObject(.object(response))
    let roots = try object.requiredArray("roots")
    for (index, root) in roots.enumerated() {
      let rootObject = try MCPJSONObject(root)
      let uri = try rootObject.requiredNonEmptyString("uri")
      try validateURI(uri, field: "inputResponses.\(key).roots[\(index)].uri")
      if let name = rootObject.values["name"] {
        guard case .string = name else {
          throw MCPJSONError.expectedString(
            field: "inputResponses.\(key).roots[\(index)].name")
        }
      }
      if let metadata = rootObject.values["_meta"] {
        guard case .object = metadata else {
          throw MCPJSONError.invalidField(
            field: "inputResponses.\(key).roots[\(index)]._meta", reason: "expected object")
        }
      }
    }
  }

  private static func validateCreateMessageResult(
    _ response: [String: MCPJSONValue],
    key: String
  ) throws {
    let object = try MCPJSONObject(.object(response))
    _ = try object.requiredString("model")
    _ = try MCPRole(
      json: object.values["role"]
        ?? {
          throw MCPJSONError.missingField(
            "inputResponses.\(key).role")
        }())
    let content =
      try object.values["content"]
      ?? {
        throw MCPJSONError.missingField(
          "inputResponses.\(key).content")
      }()
    try validateSamplingContent(content, field: "inputResponses.\(key).content")
    _ = try object.optionalString("stopReason")
    if let metadata = object.values["_meta"] {
      guard case .object = metadata else {
        throw MCPJSONError.invalidField(
          field: "inputResponses.\(key)._meta", reason: "expected object")
      }
    }
  }

  private static func validateSamplingContent(
    _ value: MCPJSONValue,
    field: String
  ) throws {
    switch value {
    case .object:
      try validateSamplingContentBlock(value, field: field)
    case .array(let values):
      for (index, value) in values.enumerated() {
        try validateSamplingContentBlock(value, field: "\(field)[\(index)]")
      }
    default:
      throw MCPJSONError.invalidField(field: field, reason: "expected content object or array")
    }
  }

  private static func validateSamplingContentBlock(
    _ value: MCPJSONValue,
    field: String
  ) throws {
    let object = try MCPJSONObject(value)
    let type = try object.requiredString("type")
    switch type {
    case "text":
      _ = try MCPTextContent(json: value)
    case "image":
      let image = try MCPBinaryContent(json: value)
      guard image.kind == .image else {
        throw MCPJSONError.invalidField(field: "\(field).type", reason: "expected image")
      }
    case "audio":
      let audio = try MCPBinaryContent(json: value)
      guard audio.kind == .audio else {
        throw MCPJSONError.invalidField(field: "\(field).type", reason: "expected audio")
      }
    case "tool_use":
      try validateToolUseContent(object, field: field)
    case "tool_result":
      try validateToolResultContent(object, field: field)
    default:
      throw MCPJSONError.invalidField(
        field: "\(field).type",
        reason: "expected text, image, audio, tool_use, or tool_result")
    }
  }

  private static func validateToolUseContent(
    _ object: MCPJSONObject,
    field: String
  ) throws {
    _ = try object.requiredString("id")
    _ = try object.requiredString("name")
    _ = try object.requiredObject("input")
    if let metadata = object.values["_meta"] {
      guard case .object = metadata else {
        throw MCPJSONError.invalidField(field: "\(field)._meta", reason: "expected object")
      }
    }
  }

  private static func validateToolResultContent(
    _ object: MCPJSONObject,
    field: String
  ) throws {
    _ = try object.requiredString("toolUseId")
    let content = try object.requiredArray("content")
    for block in content {
      _ = try MCPContentBlock(json: block)
    }
    if let isError = object.values["isError"] {
      guard case .bool = isError else {
        throw MCPJSONError.expectedBool(field: "\(field).isError")
      }
    }
    if let metadata = object.values["_meta"] {
      guard case .object = metadata else {
        throw MCPJSONError.invalidField(field: "\(field)._meta", reason: "expected object")
      }
    }
  }

  private static func validateURI(_ value: String, field: String) throws {
    let hasControlCharacter = value.unicodeScalars.contains { scalar in
      scalar.value <= 0x20 || scalar.value == 0x7F
    }
    guard !hasControlCharacter, let url = URL(string: value), url.scheme != nil else {
      throw MCPJSONError.invalidField(field: field, reason: "must be a valid URI")
    }
  }

  private static func validateSamplingRequest(
    _ request: MCPJSONObject,
    key: String
  ) throws {
    let params = try request.requiredObject("params")
    let paramsObject = try MCPJSONObject(.object(params))
    let maxTokens = try paramsObject.requiredNumber("maxTokens")
    guard maxTokens.isMathematicalInteger else {
      throw MCPJSONError.expectedInteger(field: "inputRequests.\(key).params.maxTokens")
    }
    guard case .array(let messages)? = paramsObject.values["messages"] else {
      throw MCPJSONError.invalidField(
        field: "inputRequests.\(key).params.messages", reason: "expected array")
    }
    for (index, message) in messages.enumerated() {
      let messageObject = try MCPJSONObject(message)
      let role = try messageObject.requiredString("role")
      guard role == "assistant" || role == "user" else {
        throw MCPJSONError.invalidField(
          field: "inputRequests.\(key).params.messages[\(index)].role",
          reason: "expected assistant or user")
      }
      guard let content = messageObject.values["content"] else {
        throw MCPJSONError.missingField(
          "inputRequests.\(key).params.messages[\(index)].content")
      }
      switch content {
      case .object, .array:
        break
      default:
        throw MCPJSONError.invalidField(
          field: "inputRequests.\(key).params.messages[\(index)].content",
          reason: "expected content object or array")
      }
    }
  }

  static func requireNoPayload(
    hasInput: Bool,
    hasResult: Bool,
    hasError: Bool,
    status: MCPTaskStatus
  ) throws {
    guard !hasInput, !hasResult, !hasError else {
      throw MCPJSONError.invalidField(
        field: "status", reason: "\(status.rawValue) forbids status-specific payload fields")
    }
  }

  private static func isISO8601(_ value: String) -> Bool {
    let formatter = ISO8601DateFormatter()
    if formatter.date(from: value) != nil { return true }
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) != nil
  }
}
