import Foundation
import MCP

/// Host-owned durable task persistence. Implementations must survive the endpoint process restart
/// when the advertised task lifetime does.
public protocol MCPTaskStore: Sendable {
  /// Inserts a new task and rejects duplicate task IDs.
  func create(_ task: MCPDetailedTask) async throws

  /// Returns the current complete task snapshot, or nil when the task is unknown or expired.
  func task(taskID: String) async throws -> MCPDetailedTask?

  /// Accepts zero or more currently outstanding input responses. Return false for an unknown task.
  func update(
    taskID: String,
    inputResponses: [String: MCPJSONValue]
  ) async throws -> Bool

  /// Records cooperative cancellation intent. Return false for an unknown task.
  func requestCancellation(taskID: String) async throws -> Bool
}

public protocol MCPTaskIDGenerating: Sendable {
  func nextTaskID() async throws -> String
}

public struct MCPUUIDTaskIDGenerator: MCPTaskIDGenerating {
  public init() {}

  public func nextTaskID() async throws -> String {
    UUID().uuidString.lowercased()
  }
}

public struct MCPTaskDurabilityPolicy: Sendable, Hashable {
  public let maximumReadAttempts: Int
  public let retryDelay: Duration

  public init(
    maximumReadAttempts: Int = 20,
    retryDelay: Duration = .milliseconds(25)
  ) throws {
    guard maximumReadAttempts > 0 else {
      throw MCPJSONError.invalidField(
        field: "maximumReadAttempts", reason: "must be greater than zero")
    }
    guard retryDelay >= .zero else {
      throw MCPJSONError.invalidField(field: "retryDelay", reason: "must not be negative")
    }
    self.maximumReadAttempts = maximumReadAttempts
    self.retryDelay = retryDelay
  }

  private init(uncheckedMaximumReadAttempts: Int, retryDelay: Duration) {
    self.maximumReadAttempts = uncheckedMaximumReadAttempts
    self.retryDelay = retryDelay
  }

  public static let `default` = MCPTaskDurabilityPolicy(
    uncheckedMaximumReadAttempts: 20,
    retryDelay: .milliseconds(25)
  )
}

public enum MCPTaskCreationError: Error, Sendable, Equatable, CustomStringConvertible {
  case emptyGeneratedTaskID
  case taskWasNotDurable(String)
  case persistedTaskIDMismatch(expected: String, actual: String)

  public var description: String {
    switch self {
    case .emptyGeneratedTaskID:
      "Task ID generator returned an empty identifier"
    case .taskWasNotDurable(let taskID):
      "Task \(taskID) was not readable after creation"
    case .persistedTaskIDMismatch(let expected, let actual):
      "Persisted task ID \(actual) does not match created task ID \(expected)"
    }
  }
}

/// The only task creation path exposed to a tool handler. It verifies the durable-before-return
/// invariant by reading the task through the same store used by `tasks/get`.
public struct MCPTaskCreator: Sendable {
  private let store: any MCPTaskStore
  private let ids: any MCPTaskIDGenerating
  private let durability: MCPTaskDurabilityPolicy

  public init(
    store: any MCPTaskStore,
    idGenerator: any MCPTaskIDGenerating = MCPUUIDTaskIDGenerator(),
    durability: MCPTaskDurabilityPolicy = .default
  ) {
    self.store = store
    self.ids = idGenerator
    self.durability = durability
  }

  public func nextTaskID() async throws -> String {
    let taskID = try await ids.nextTaskID()
    guard !taskID.isEmpty else { throw MCPTaskCreationError.emptyGeneratedTaskID }
    return taskID
  }

  /// Persists a fully formed initial task snapshot, re-reads it, and only then creates the wire
  /// handle. A worker may advance the task between those operations; existence and identity are
  /// the required invariant, not byte-for-byte equality with the seed snapshot.
  public func create(
    _ task: MCPDetailedTask,
    metadata: MCPResultMetadata? = nil
  ) async throws -> MCPCreateTaskResult {
    try await store.create(task)
    for attempt in 0..<durability.maximumReadAttempts {
      if let persisted = try await store.task(taskID: task.task.taskID) {
        guard persisted.task.taskID == task.task.taskID else {
          throw MCPTaskCreationError.persistedTaskIDMismatch(
            expected: task.task.taskID,
            actual: persisted.task.taskID
          )
        }
        return MCPCreateTaskResult(task: persisted.task, metadata: metadata)
      }
      if attempt + 1 < durability.maximumReadAttempts, durability.retryDelay > .zero {
        try await Task.sleep(for: durability.retryDelay)
      }
    }
    throw MCPTaskCreationError.taskWasNotDurable(task.task.taskID)
  }
}

public typealias MCPTasksToolHandler = @Sendable (
  _ params: MCPCallToolParams,
  _ context: MCPRequestContext,
  _ taskCreator: MCPTaskCreator?
) async throws -> MCPTasksCallToolResult

public enum MCPTasksServer {
  /// Constructs a core server builder with the official Tasks extension methods and discovery
  /// capability. The caller still registers the endpoint's tools/list handler and tool resolver.
  public static func makeBuilder(
    implementation: MCPImplementation,
    instructions: String? = nil,
    configuration: MCPServerConfiguration = MCPServerConfiguration(),
    extensions: [String: MCPJSONValue] = [:]
  ) throws -> MCPServerBuilder {
    try MCPServerBuilder(
      implementation: implementation,
      instructions: instructions,
      configuration: configuration,
      extensionMethods: MCPTasksExtension.extensionMethods(),
      extensions: MCPTasksExtension.serverExtensions(extending: extensions)
    )
  }

  /// Registers task-aware tools/call. If the client omitted the Tasks capability, the handler gets
  /// no creator and may still return an immediate result. A task result without negotiated support
  /// is rejected fail-closed.
  public static func registerCallTool(
    on builder: inout MCPServerBuilder,
    store: any MCPTaskStore,
    idGenerator: any MCPTaskIDGenerating = MCPUUIDTaskIDGenerator(),
    durability: MCPTaskDurabilityPolicy = .default,
    handler: @escaping MCPTasksToolHandler
  ) throws {
    try builder.register(MCPTasksMethods.callTool) { params, context in
      let supportsTasks = MCPTasksExtension.supportsTasks(context.metadata.clientCapabilities)
      let creator =
        supportsTasks
        ? MCPTaskCreator(store: store, idGenerator: idGenerator, durability: durability)
        : nil
      let result = try await handler(params, context, creator)
      guard case .task(let taskResult) = result else { return result }
      guard supportsTasks else { throw try missingCapabilityError() }
      guard let persisted = try await store.task(taskID: taskResult.task.taskID) else {
        throw MCPRPCError.internalError
      }
      guard persisted.task.taskID == taskResult.task.taskID else {
        throw MCPRPCError.internalError
      }
      return result
    }
  }

  public static func registerLifecycle(
    on builder: inout MCPServerBuilder,
    store: any MCPTaskStore
  ) throws {
    try builder.register(MCPTasksMethods.get) { params, context in
      try requireCapability(context)
      guard let task = try await store.task(taskID: params.taskID) else {
        throw unknownTask(params.taskID)
      }
      return MCPGetTaskResult(task: task)
    }

    try builder.register(MCPTasksMethods.update) { params, context in
      try requireCapability(context)
      guard
        try await store.update(
          taskID: params.taskID,
          inputResponses: params.inputResponses
        )
      else {
        throw unknownTask(params.taskID)
      }
      return MCPTaskAcknowledgement()
    }

    try builder.register(MCPTasksMethods.cancel) { params, context in
      try requireCapability(context)
      guard try await store.requestCancellation(taskID: params.taskID) else {
        throw unknownTask(params.taskID)
      }
      return MCPTaskAcknowledgement()
    }
  }

  private static func requireCapability(_ context: MCPRequestContext) throws {
    guard MCPTasksExtension.supportsTasks(context.metadata.clientCapabilities) else {
      throw try missingCapabilityError()
    }
  }

  private static func missingCapabilityError() throws -> MCPRPCError {
    .missingRequiredClientCapabilities(
      "Client did not declare the Tasks extension required by this request",
      requiredCapabilities: try MCPTasksExtension.requiredClientCapabilities()
    )
  }

  private static func unknownTask(_ taskID: String) -> MCPRPCError {
    MCPRPCError(
      code: -32602,
      message: "Unknown task",
      data: .object(["taskId": .string(taskID)])
    )
  }
}
