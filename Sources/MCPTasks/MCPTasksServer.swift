import Foundation
import MCP

/// Host-owned durable task persistence.
///
/// The authorization context is supplied on every operation so a store can enforce ownership
/// independently for every request. Implementations must retain task state for the advertised
/// lifetime and must not use endpoint-local process memory as the production source of truth.
public protocol MCPTaskStore: Sendable {
  /// Inserts a new task and rejects duplicate task IDs.
  func create(
    _ task: MCPDetailedTask,
    authorization: MCPAuthorizationContext
  ) async throws

  /// Returns the current complete task snapshot, or nil when the task is unknown or expired.
  func task(
    taskID: String,
    authorization: MCPAuthorizationContext
  ) async throws -> MCPDetailedTask?

  /// Accepts zero or more currently outstanding input responses. Return false for an unknown
  /// task. Unknown or already-satisfied response keys should be ignored by the store.
  func update(
    taskID: String,
    inputResponses: [String: MCPInputResponse],
    authorization: MCPAuthorizationContext
  ) async throws -> Bool

  /// Records cooperative cancellation intent. Return false for an unknown task.
  func requestCancellation(
    taskID: String,
    authorization: MCPAuthorizationContext
  ) async throws -> Bool
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
  /// The store accepted the write, but the task was not readable through the lifecycle read path
  /// within the configured bound. The task may exist and is therefore an ambiguous/orphaned
  /// creation from the caller's perspective.
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
/// invariant by reading the task through the same authorized store used by tasks/get.
public struct MCPTaskCreator: Sendable {
  private let store: any MCPTaskStore
  private let ids: any MCPTaskIDGenerating
  private let durability: MCPTaskDurabilityPolicy
  private let authorization: MCPAuthorizationContext

  public init(
    store: any MCPTaskStore,
    authorization: MCPAuthorizationContext,
    idGenerator: any MCPTaskIDGenerating = MCPUUIDTaskIDGenerator(),
    durability: MCPTaskDurabilityPolicy = .default
  ) {
    self.store = store
    self.authorization = authorization
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
    try await store.create(task, authorization: authorization)
    for attempt in 0..<durability.maximumReadAttempts {
      if let persisted = try await store.task(
        taskID: task.task.taskID,
        authorization: authorization
      ) {
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

public typealias MCPTasksToolHandler =
  @Sendable (
    _ params: MCPCallToolParams,
    _ context: MCPRequestContext,
    _ taskCreator: MCPTaskCreator?
  ) async throws -> MCPTasksCallToolResult

public enum MCPTasksServerBuildError: Error, Sendable, Equatable, CustomStringConvertible {
  /// Generic registration cannot be used for tools/call because it would bypass the Tasks
  /// capability gate and durable creator binding. Call registerCallTool instead.
  case callToolRequiresTaskAwareRegistration

  public var description: String {
    switch self {
    case .callToolRequiresTaskAwareRegistration:
      "tools/call must be registered with MCPTasksServerBuilder.registerCallTool"
    }
  }
}

/// A Tasks-bound builder. Keeping the durable store and its lifecycle handlers in one value makes
/// it impossible to register task creation against a different store than tasks/get/update/cancel.
/// The underlying MCPServerBuilder remains private so callers cannot accidentally split the
/// authority boundary.
public struct MCPTasksServerBuilder: Sendable {
  fileprivate var core: MCPServerBuilder
  fileprivate let store: any MCPTaskStore
  fileprivate let idGenerator: any MCPTaskIDGenerating
  fileprivate let durability: MCPTaskDurabilityPolicy

  fileprivate init(
    core: MCPServerBuilder,
    store: any MCPTaskStore,
    idGenerator: any MCPTaskIDGenerating,
    durability: MCPTaskDurabilityPolicy
  ) {
    self.core = core
    self.store = store
    self.idGenerator = idGenerator
    self.durability = durability
  }

  public var implementation: MCPImplementation { core.implementation }
  public var instructions: String? {
    get { core.instructions }
    set { core.instructions = newValue }
  }
  public var configuration: MCPServerConfiguration {
    get { core.configuration }
    set { core.configuration = newValue }
  }
  public var extensions: [String: MCPJSONValue] {
    get { core.extensions }
    set {
      // The Stable Tasks capability is always an empty object. Filter the reserved entry before
      // re-applying it so callers cannot remove it or replace it with mutable configuration.
      var callerExtensions = newValue
      callerExtensions[MCPTasksExtension.identifier] = .object([:])
      core.extensions = callerExtensions
    }
  }

  public mutating func register<Params: MCPJSONModel, Result: MCPJSONModel>(
    _ method: MCPMethod<Params, Result>,
    handler: @escaping @Sendable (Params, MCPRequestContext) async throws -> Result
  ) throws {
    try rejectGenericCallToolRegistration(method.descriptor)
    try core.register(method, handler: handler)
  }

  public mutating func registerOutcome<Params: MCPJSONModel, Result: MCPJSONModel>(
    _ method: MCPMethod<Params, Result>,
    handler:
      @escaping @Sendable (Params, MCPRequestContext) async throws -> MCPOperationOutcome<Result>
  ) throws {
    try rejectGenericCallToolRegistration(method.descriptor)
    try core.registerOutcome(method, handler: handler)
  }

  public mutating func setToolResolver(_ resolver: @escaping MCPToolResolver) {
    core.setToolResolver(resolver)
  }

  public mutating func enableToolListChanged(_ enabled: Bool = true) {
    core.enableToolListChanged(enabled)
  }

  public mutating func enablePromptListChanged(_ enabled: Bool = true) {
    core.enablePromptListChanged(enabled)
  }

  public mutating func enableResourceListChanged(_ enabled: Bool = true) {
    core.enableResourceListChanged(enabled)
  }

  public mutating func enableResourceSubscriptions(_ enabled: Bool = true) {
    core.enableResourceSubscriptions(enabled)
  }

  /// Registers the task-aware tools/call handler against the same store bound at construction.
  public mutating func registerCallTool(
    handler: @escaping MCPTasksToolHandler
  ) throws {
    try MCPTasksServer.registerCallTool(on: &self, handler: handler)
  }

  public func build(diagnostics: any MCPDiagnosticSink = MCPNoopDiagnosticSink()) throws
    -> MCPServer
  {
    try core.build(diagnostics: diagnostics)
  }

  private func rejectGenericCallToolRegistration(_ descriptor: MCPMethodDescriptor) throws {
    guard descriptor.name != "tools/call" else {
      throw MCPTasksServerBuildError.callToolRequiresTaskAwareRegistration
    }
  }
}

public enum MCPTasksServer {
  /// Constructs a Tasks-bound server builder with all lifecycle methods and the discovery
  /// capability already installed. A durable host store is mandatory; there is no production
  /// in-memory default.
  public static func makeBuilder(
    implementation: MCPImplementation,
    taskStore: any MCPTaskStore,
    instructions: String? = nil,
    configuration: MCPServerConfiguration = MCPServerConfiguration(),
    extensions: [String: MCPJSONValue] = [:],
    idGenerator: any MCPTaskIDGenerating = MCPUUIDTaskIDGenerator(),
    durability: MCPTaskDurabilityPolicy = .default
  ) throws -> MCPTasksServerBuilder {
    // The package-scoped registration owns the official capability. Preserve the wrapper's
    // historical "caller value is ignored" behavior for this one reserved key while allowing
    // unrelated vendor capabilities to pass through unchanged.
    var callerExtensions = extensions
    callerExtensions.removeValue(forKey: MCPTasksExtension.identifier)
    let core = try MCPServerBuilder(
      implementation: implementation,
      instructions: instructions,
      configuration: configuration,
      officialExtension: try MCPTasksExtension.officialRegistration(),
      extensions: callerExtensions
    )
    var result = MCPTasksServerBuilder(
      core: core,
      store: taskStore,
      idGenerator: idGenerator,
      durability: durability
    )
    try registerLifecycle(on: &result)
    return result
  }

  /// Registers task-aware tools/call against the store and authority already bound to the
  /// Tasks-bound builder. A handler receives nil when the request did not negotiate Tasks and may
  /// then return an immediate result. A task result without negotiated support is rejected
  /// fail-closed.
  public static func registerCallTool(
    on builder: inout MCPTasksServerBuilder,
    handler: @escaping MCPTasksToolHandler
  ) throws {
    let store = builder.store
    let idGenerator = builder.idGenerator
    let durability = builder.durability
    try builder.core.register(MCPTasksMethods.callTool) { params, context in
      let supportsTasks = MCPTasksExtension.supportsTasks(context.metadata.clientCapabilities)
      let creator =
        supportsTasks
        ? MCPTaskCreator(
          store: store,
          authorization: context.authorization,
          idGenerator: idGenerator,
          durability: durability
        )
        : nil
      let result: MCPTasksCallToolResult
      do {
        result = try await handler(params, context, creator)
      } catch let error as MCPTaskCreationError {
        throw creationRPCError(error)
      }
      guard case .task(let taskResult) = result else { return result }
      guard supportsTasks else { throw missingCapabilityError() }
      guard
        let persisted = try await store.task(
          taskID: taskResult.task.taskID,
          authorization: context.authorization
        )
      else {
        throw MCPRPCError.internalError
      }
      guard persisted.task.taskID == taskResult.task.taskID else {
        throw MCPRPCError.internalError
      }
      return result
    }
  }

  private static func registerLifecycle(
    on builder: inout MCPTasksServerBuilder
  ) throws {
    let store = builder.store
    try builder.core.register(MCPTasksMethods.get) { params, context in
      try requireCapability(context)
      guard
        let task = try await store.task(
          taskID: params.taskID,
          authorization: context.authorization
        )
      else {
        throw unknownTask(params.taskID)
      }
      return MCPGetTaskResult(task: task)
    }

    try builder.core.register(MCPTasksMethods.update) { params, context in
      try requireCapability(context)
      guard
        try await store.update(
          taskID: params.taskID,
          inputResponses: params.inputResponses,
          authorization: context.authorization
        )
      else {
        throw unknownTask(params.taskID)
      }
      return MCPTaskAcknowledgement()
    }

    try builder.core.register(MCPTasksMethods.cancel) { params, context in
      try requireCapability(context)
      guard
        try await store.requestCancellation(
          taskID: params.taskID,
          authorization: context.authorization
        )
      else {
        throw unknownTask(params.taskID)
      }
      return MCPTaskAcknowledgement()
    }
  }

  private static func requireCapability(_ context: MCPRequestContext) throws {
    guard MCPTasksExtension.supportsTasks(context.metadata.clientCapabilities) else {
      throw missingCapabilityError()
    }
  }

  private static func missingCapabilityError() -> MCPRPCError {
    .missingRequiredClientCapabilities(
      "Client did not declare the Tasks extension required by this request",
      requiredCapabilities: try? MCPTasksExtension.clientCapabilities()
    )
  }

  private static func unknownTask(_ taskID: String) -> MCPRPCError {
    MCPRPCError(
      code: -32602,
      message: "Unknown task",
      data: .object(["taskId": .string(taskID)])
    )
  }

  private static func creationRPCError(_ error: MCPTaskCreationError) -> MCPRPCError {
    switch error {
    case .taskWasNotDurable(let taskID):
      return MCPRPCError(
        code: -32603,
        message: "Task durability could not be confirmed",
        data: .object([
          "taskId": .string(taskID),
          "ambiguous": .bool(true),
        ])
      )
    case .emptyGeneratedTaskID, .persistedTaskIDMismatch:
      return MCPRPCError(
        code: -32603,
        message: "Task creation failed",
        data: .string(error.description)
      )
    }
  }
}
