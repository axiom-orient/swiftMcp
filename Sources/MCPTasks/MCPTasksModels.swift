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

  public static func serverExtensions(
    extending base: [String: MCPJSONValue] = [:]
  ) -> [String: MCPJSONValue] {
    var result = base
    result[identifier] = .object([:])
    return result
  }

  public static func supportsTasks(_ capabilities: MCPClientCapabilities) -> Bool {
    capabilities.extensions[identifier] != nil
  }

  public static func requiredClientCapabilities() throws -> MCPClientCapabilities {
    try clientCapabilities()
  }

  public static func extensionMethods() throws -> [MCPMethodDescriptor] {
    [
      try callToolAugmentationDescriptor(),
      try getTaskDescriptor(),
      try updateTaskDescriptor(),
      try cancelTaskDescriptor(),
    ]
  }

  public static func methodRegistry() throws -> MCPMethodRegistry {
    try MCPMethodRegistry(extensionMethods: extensionMethods())
  }

  static func callToolAugmentationDescriptor() throws -> MCPMethodDescriptor {
    try MCPMethodDescriptor(
      name: "tools/call",
      direction: .clientToServerRequest,
      requiredServerCapability: .tools,
      cacheability: .none,
      httpNameSource: .toolName,
      allowsMRTR: true,
      extensionResultTypes: [taskResultType],
      isExtension: true,
      extensionIdentifier: identifier
    )
  }

  static func callToolDescriptor() throws -> MCPMethodDescriptor {
    try MCPMethodDescriptor(
      name: "tools/call",
      direction: .clientToServerRequest,
      requiredServerCapability: .tools,
      cacheability: .none,
      httpNameSource: .toolName,
      allowsMRTR: true,
      extensionResultTypes: [taskResultType]
    )
  }

  static func getTaskDescriptor() throws -> MCPMethodDescriptor {
    try MCPMethodDescriptor(
      name: "tasks/get",
      direction: .clientToServerRequest,
      httpNameSource: .taskID,
      isExtension: true,
      extensionIdentifier: identifier
    )
  }

  static func updateTaskDescriptor() throws -> MCPMethodDescriptor {
    try MCPMethodDescriptor(
      name: "tasks/update",
      direction: .clientToServerRequest,
      httpNameSource: .taskID,
      isExtension: true,
      extensionIdentifier: identifier
    )
  }

  static func cancelTaskDescriptor() throws -> MCPMethodDescriptor {
    try MCPMethodDescriptor(
      name: "tasks/cancel",
      direction: .clientToServerRequest,
      httpNameSource: .taskID,
      isExtension: true,
      extensionIdentifier: identifier
    )
  }
}

public enum MCPTasksMethods {
  public static var callTool: MCPMethod<MCPCallToolParams, MCPTasksCallToolResult> {
    get throws { MCPMethod(try MCPTasksExtension.callToolDescriptor()) }
  }

  public static var get: MCPMethod<MCPGetTaskParams, MCPGetTaskResult> {
    get throws { MCPMethod(try MCPTasksExtension.getTaskDescriptor()) }
  }

  public static var update: MCPMethod<MCPUpdateTaskParams, MCPTaskAcknowledgement> {
    get throws { MCPMethod(try MCPTasksExtension.updateTaskDescriptor()) }
  }

  public static var cancel: MCPMethod<MCPCancelTaskParams, MCPTaskAcknowledgement> {
    get throws { MCPMethod(try MCPTasksExtension.cancelTaskDescriptor()) }
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

public enum MCPDetailedTask: Sendable, Hashable, MCPJSONModel {
  case working(MCPTask)
  case inputRequired(MCPTask, inputRequests: [String: MCPJSONValue])
  case completed(MCPTask, result: [String: MCPJSONValue])
  case failed(MCPTask, error: MCPRPCError)
  case cancelled(MCPTask)

  public var task: MCPTask {
    switch self {
    case .working(let task), .inputRequired(let task, _), .completed(let task, _),
      .failed(let task, _), .cancelled(let task):
      task
    }
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
      self = .working(task)
    case .inputRequired:
      guard !hasResult, !hasError else {
        throw MCPJSONError.invalidField(
          field: "status", reason: "input_required forbids result and error")
      }
      let requests = try object.requiredObject("inputRequests")
      guard !requests.isEmpty else {
        throw MCPJSONError.invalidField(
          field: "inputRequests", reason: "must contain at least one outstanding request")
      }
      try MCPTasksValidation.validateInputRequests(requests)
      self = .inputRequired(task, inputRequests: requests)
    case .completed:
      guard !hasInput, !hasError else {
        throw MCPJSONError.invalidField(
          field: "status", reason: "completed forbids inputRequests and error")
      }
      self = .completed(task, result: try object.requiredObject("result"))
    case .failed:
      guard !hasInput, !hasResult else {
        throw MCPJSONError.invalidField(
          field: "status", reason: "failed forbids inputRequests and result")
      }
      self = .failed(
        task,
        error: try MCPRPCError(
          json: object.values["error"] ?? { throw MCPJSONError.missingField("error") }())
      )
    case .cancelled:
      try MCPTasksValidation.requireNoPayload(
        hasInput: hasInput, hasResult: hasResult, hasError: hasError, status: task.status)
      self = .cancelled(task)
    }
  }

  public var json: MCPJSONValue {
    var object = task.json.objectValue ?? [:]
    switch self {
    case .working, .cancelled:
      break
    case .inputRequired(_, let inputRequests):
      object["inputRequests"] = .object(inputRequests)
    case .completed(_, let result):
      object["result"] = .object(result)
    case .failed(_, let error):
      object["error"] = error.json
    }
    return .object(object)
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
    } else {
      self = .immediate(try MCPCallToolResult(json: json))
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
    metadata = try MCPJSONObject(.object(notification.params)).optionalObject("_meta") ?? [:]
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
  static func resultType(_ object: MCPJSONObject) throws -> MCPResultType {
    let raw = try object.requiredString("resultType")
    return try MCPResultType(rawValue: raw)
  }

  static func validateNonnegativeInteger(_ value: MCPJSONNumber, field: String) throws {
    guard value.isMathematicalInteger else { throw MCPJSONError.expectedInteger(field: field) }
    guard value.compare(to: MCPJSONNumber(0)) != .orderedAscending else {
      throw MCPJSONError.invalidField(field: field, reason: "must be non-negative")
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
      guard ["sampling/createMessage", "roots/list", "elicitation/create"].contains(method) else {
        throw MCPJSONError.invalidField(
          field: "inputRequests.\(key).method", reason: "unsupported input request method")
      }
      _ = try request.requiredObject("params")
      if request.values["id"] != nil || request.values["jsonrpc"] != nil {
        throw MCPJSONError.invalidField(
          field: "inputRequests.\(key)",
          reason: "embedded requests contain method and params only")
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
