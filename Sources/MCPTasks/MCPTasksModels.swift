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
      rootsSettings: base.rootsSettings,
      sampling: base.sampling,
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
      try MCPTasksValidation.validateSafeInteger(ttlMilliseconds, field: "ttlMs")
    }
    if let pollIntervalMilliseconds {
      try MCPTasksValidation.validateSafeInteger(
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
    case inputRequired([String: MCPInputRequest])
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
    inputRequests: [String: MCPInputRequest]
  ) throws -> Self {
    let task = try requireStatus(task, .inputRequired)
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
  public var inputRequests: [String: MCPInputRequest]? {
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
      let rawInputRequests = try object.requiredObject("inputRequests")
      self = try Self.inputRequired(
        task,
        inputRequests: try rawInputRequests.mapValues { try MCPInputRequest(json: $0) }
      )
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
      object["inputRequests"] = .object(inputRequests.mapValues { $0.json })
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
  public let inputResponses: [String: MCPInputResponse]

  public init(taskID: String, inputResponses: [String: MCPInputResponse]) throws {
    guard !taskID.isEmpty else {
      throw MCPJSONError.invalidField(field: "taskId", reason: "must not be empty")
    }
    self.taskID = taskID
    self.inputResponses = inputResponses
  }

  public init(json: MCPJSONValue) throws {
    let object = try MCPJSONObject(json)
    try self.init(
      taskID: try object.requiredNonEmptyString("taskId"),
      inputResponses: try object.requiredObject("inputResponses").mapValues {
        try MCPInputResponse(json: $0)
      }
    )
  }

  public var json: MCPJSONValue {
    .object([
      "taskId": .string(taskID),
      "inputResponses": .object(inputResponses.mapValues { $0.json }),
    ])
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

private enum MCPTasksValidation {
  /// Millisecond fields are JSON safe integers. Keep their exact JSON number lexeme and accept
  /// the complete interoperable safe-integer range, including negative values permitted by the
  /// stable schema. A host may apply a stricter producer policy separately.
  private static let minimumSafeInteger = MCPJSONNumber(-9_007_199_254_740_991)
  private static let maximumSafeInteger = MCPJSONNumber(9_007_199_254_740_991)

  static func resultType(_ object: MCPJSONObject) throws -> MCPResultType {
    let raw = try object.requiredString("resultType")
    return try MCPResultType(rawValue: raw)
  }

  static func validateSafeInteger(_ value: MCPJSONNumber, field: String) throws {
    guard value.isMathematicalInteger else { throw MCPJSONError.expectedInteger(field: field) }
    guard value.compare(to: minimumSafeInteger) != .orderedAscending,
      value.compare(to: maximumSafeInteger) != .orderedDescending
    else {
      throw MCPJSONError.invalidField(
        field: field,
        reason: "must be an integer in the safe range -9007199254740991...9007199254740991"
      )
    }
  }

  static func validateTimestamp(_ value: String, field: String) throws {
    guard isStrictInternetTimestamp(value) else {
      throw MCPJSONError.invalidField(
        field: field,
        reason: "must match YYYY-MM-DD'T'HH:mm:ss[.fraction]Z or ±HH:MM"
      )
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

  /// Accept the RFC3339-style internet timestamp subset used by the Tasks wire contract:
  /// four-digit date, two-digit time, optional 1-9 digit fraction, and uppercase Z or ±HH:MM.
  /// Lexical validation is paired with Gregorian calendar checks so Foundation cannot normalize
  /// an invalid date such as February 30 into a different valid date.
  private static func isStrictInternetTimestamp(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard bytes.count >= 20 else { return false }
    guard digits(bytes, from: 0, count: 4), bytes[4] == 45,
      digits(bytes, from: 5, count: 2), bytes[7] == 45,
      digits(bytes, from: 8, count: 2), bytes[10] == 84,
      digits(bytes, from: 11, count: 2), bytes[13] == 58,
      digits(bytes, from: 14, count: 2), bytes[16] == 58,
      digits(bytes, from: 17, count: 2)
    else { return false }

    let year = number(bytes, from: 0, count: 4)
    let month = number(bytes, from: 5, count: 2)
    let day = number(bytes, from: 8, count: 2)
    let hour = number(bytes, from: 11, count: 2)
    let minute = number(bytes, from: 14, count: 2)
    let second = number(bytes, from: 17, count: 2)
    guard (1...12).contains(month), day >= 1,
      day <= daysInMonth(year: year, month: month), hour <= 23, minute <= 59, second <= 59
    else { return false }

    var timezoneStart = 19
    if bytes[timezoneStart] == 46 {
      let fractionStart = timezoneStart + 1
      var fractionEnd = fractionStart
      while fractionEnd < bytes.count, bytes[fractionEnd] >= 48, bytes[fractionEnd] <= 57 {
        fractionEnd += 1
      }
      let fractionCount = fractionEnd - fractionStart
      guard (1...9).contains(fractionCount) else { return false }
      timezoneStart = fractionEnd
    }

    var offsetSeconds = 0
    if timezoneStart < bytes.count, bytes[timezoneStart] == 90 {
      guard timezoneStart + 1 == bytes.count else { return false }
    } else {
      guard timezoneStart + 6 == bytes.count,
        bytes[timezoneStart] == 43 || bytes[timezoneStart] == 45,
        bytes[timezoneStart + 3] == 58,
        digits(bytes, from: timezoneStart + 1, count: 2),
        digits(bytes, from: timezoneStart + 4, count: 2)
      else { return false }
      let offsetHours = number(bytes, from: timezoneStart + 1, count: 2)
      let offsetMinutes = number(bytes, from: timezoneStart + 4, count: 2)
      guard offsetHours <= 23, offsetMinutes <= 59 else { return false }
      offsetSeconds = (offsetHours * 60 + offsetMinutes) * 60
      if bytes[timezoneStart] == 45 { offsetSeconds = -offsetSeconds }
    }

    guard let timeZone = TimeZone(secondsFromGMT: offsetSeconds) else { return false }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    components.nanosecond = 0
    guard let date = calendar.date(from: components) else { return false }
    let roundTrip = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: date)
    return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
      && roundTrip.hour == hour && roundTrip.minute == minute && roundTrip.second == second
  }

  private static func digits(_ bytes: [UInt8], from start: Int, count: Int) -> Bool {
    guard start >= 0, count >= 0, start + count <= bytes.count else { return false }
    return bytes[start..<(start + count)].allSatisfy { $0 >= 48 && $0 <= 57 }
  }

  private static func number(_ bytes: [UInt8], from start: Int, count: Int) -> Int {
    bytes[start..<(start + count)].reduce(0) { value, digit in value * 10 + Int(digit - 48) }
  }

  private static func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2:
      let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
      return leap ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }
}
