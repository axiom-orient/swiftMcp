import MCP
import XCTest

@testable import MCPTasks

final class MCPTasksModelTests: XCTestCase {
  func testExtensionRegistryAugmentsToolsAndRegistersLifecycleMethods() throws {
    let registry = try MCPTasksExtension.methodRegistry()
    let callTool = try registry.require("tools/call")
    XCTAssertTrue(callTool.extensionResultTypes.contains("task"))
    XCTAssertEqual(
      try registry.require("tasks/get").httpName(from: ["taskId": .string("task-1")]),
      "task-1"
    )
    XCTAssertEqual(try registry.require("tasks/update").httpNameSource, .taskID)
    XCTAssertEqual(try registry.require("tasks/cancel").httpNameSource, .taskID)
  }

  func testDetailedTaskRoundTripsEveryState() throws {
    let base = try task(status: .working)
    let values: [MCPDetailedTask] = [
      .working(base),
      .inputRequired(
        try task(status: .inputRequired),
        inputRequests: [
          "name": .object([
            "method": .string("elicitation/create"),
            "params": .object(["message": .string("Name")]),
          ])
        ]
      ),
      .completed(
        try task(status: .completed),
        result: ["content": .array([.object(["type": .string("text"), "text": .string("ok")])])]
      ),
      .failed(
        try task(status: .failed),
        error: MCPRPCError(code: -32603, message: "failed")
      ),
      .cancelled(try task(status: .cancelled)),
    ]

    for value in values {
      XCTAssertEqual(try MCPDetailedTask(json: value.json), value)
      let result = MCPGetTaskResult(task: value)
      XCTAssertEqual(try MCPGetTaskResult(json: result.json), result)
    }
  }

  func testTaskModelRejectsInvalidStatusPayload() throws {
    var raw = try task(status: .working).json.objectValue ?? [:]
    raw["result"] = .object([:])
    XCTAssertThrowsError(try MCPDetailedTask(json: .object(raw)))

    raw = try task(status: .inputRequired).json.objectValue ?? [:]
    raw["inputRequests"] = .object([:])
    XCTAssertThrowsError(try MCPDetailedTask(json: .object(raw)))
  }

  func testInputResponsesMayBeEmptyButMustContainObjectValues() throws {
    let empty = try MCPUpdateTaskParams(taskID: "task-1", inputResponses: [:])
    XCTAssertTrue(empty.inputResponses.isEmpty)

    XCTAssertThrowsError(
      try MCPUpdateTaskParams(
        taskID: "task-1",
        inputResponses: ["answer": .string("not-an-object")]
      )
    )
  }

  func testInputRequiredTaskRejectsMalformedEmbeddedRequest() throws {
    var raw = try task(status: .inputRequired).json.objectValue ?? [:]
    raw["inputRequests"] = .object([
      "answer": .object(["method": .string("elicitation/create")])
    ])
    XCTAssertThrowsError(try MCPDetailedTask(json: .object(raw)))

    raw["inputRequests"] = .object([
      "answer": .object([
        "method": .string("vendor/unknown"),
        "params": .object([:]),
      ])
    ])
    XCTAssertThrowsError(try MCPDetailedTask(json: .object(raw)))
  }

  func testInputResponsesRejectJSONRPCEnvelopeFields() throws {
    XCTAssertThrowsError(
      try MCPUpdateTaskParams(
        taskID: "task-1",
        inputResponses: [
          "answer": .object([
            "jsonrpc": .string("2.0"),
            "result": .object([:]),
          ])
        ]
      )
    )
  }

  func testCreateTaskRequiresTaskResultDiscriminator() throws {
    let created = MCPCreateTaskResult(task: try task(status: .working))
    XCTAssertEqual(try MCPCreateTaskResult(json: created.json), created)

    var raw = created.json.objectValue ?? [:]
    raw["resultType"] = .string("complete")
    XCTAssertThrowsError(try MCPCreateTaskResult(json: .object(raw)))
  }

  private func task(status: MCPTaskStatus) throws -> MCPTask {
    try MCPTask(
      taskID: "task-1",
      status: status,
      createdAt: "2026-08-26T00:00:00Z",
      lastUpdatedAt: "2026-08-26T00:00:01Z",
      ttlMilliseconds: MCPJSONNumber(60_000),
      pollIntervalMilliseconds: MCPJSONNumber(500)
    )
  }
}

final class MCPTasksRuntimeTests: XCTestCase {
  func testTaskCreationIsDurableBeforeHandleReturnsAndLifecycleIsReachable() async throws {
    let store = TestTaskStore()
    let server = try makeServer(store: store)
    let transport = InProcessTransport(server: server)
    let capabilities = try MCPTasksExtension.clientCapabilities()
    let configuration = try MCPClientConfiguration(
      implementation: MCPImplementation(name: "tasks-test-client", version: "1.0.0"),
      capabilities: capabilities
    )
    let client = try MCPTasksClient(transport: transport, configuration: configuration)

    let outcome = try await client.callTool(try MCPCallToolParams(name: "long-work"))
    guard case .task(let created) = outcome else {
      return XCTFail("expected task result")
    }
    XCTAssertEqual(created.task.taskID, "fixed-task-id")
    XCTAssertNotNil(await store.task(taskID: created.task.taskID))

    let current = try await client.getTask(taskID: created.task.taskID)
    XCTAssertEqual(current.task.task.status, .working)

    try await store.requireInput(taskID: created.task.taskID)
    let input = try await client.getTask(taskID: created.task.taskID)
    guard case .inputRequired(_, let requests) = input.task else {
      return XCTFail("expected input_required")
    }
    XCTAssertNotNil(requests["answer"])

    _ = try await client.updateTask(
      taskID: created.task.taskID,
      inputResponses: [
        "answer": .object([
          "action": .string("accept"), "content": .object(["value": .string("42")]),
        ])
      ]
    )
    XCTAssertEqual(await store.updateCount, 1)

    _ = try await client.cancelTask(taskID: created.task.taskID)
    XCTAssertEqual(await store.cancellationCount, 1)
  }

  func testTaskCreatorWaitsForStoreVisibilityBeforeReturningHandle() async throws {
    let store = DelayedVisibilityTaskStore(hiddenReads: 2)
    let creator = MCPTaskCreator(
      store: store,
      idGenerator: FixedTaskIDGenerator(),
      durability: try MCPTaskDurabilityPolicy(maximumReadAttempts: 3, retryDelay: .zero)
    )
    let seed = try MCPTask(
      taskID: "fixed-task-id",
      status: .working,
      createdAt: "2026-08-26T00:00:00Z",
      lastUpdatedAt: "2026-08-26T00:00:00Z",
      ttlMilliseconds: MCPJSONNumber(60_000)
    )

    let result = try await creator.create(.working(seed))
    XCTAssertEqual(result.task.taskID, "fixed-task-id")
    XCTAssertEqual(await store.readCount, 3)
  }

  func testLifecycleRejectsClientWithoutTasksCapability() async throws {
    let store = TestTaskStore()
    let server = try makeServer(store: store)
    let transport = InProcessTransport(server: server)
    let configuration = try MCPClientConfiguration(
      implementation: MCPImplementation(name: "plain-client", version: "1.0.0"),
      capabilities: MCPClientCapabilities()
    )
    let client = try MCPClient(
      transport: transport,
      configuration: configuration,
      extensionMethods: MCPTasksExtension.extensionMethods()
    )

    do {
      _ = try await client.call(
        MCPTasksMethods.get,
        params: MCPGetTaskParams(taskID: "fixed-task-id")
      )
      XCTFail("expected capability failure")
    } catch MCPClientError.rpc(let error) {
      XCTAssertEqual(error.code.int64Value, -32021)
    }
  }

  private func makeServer(store: TestTaskStore) throws -> MCPServer {
    let tool = try MCPTool(
      name: "long-work",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([:]),
        "additionalProperties": .bool(false),
      ]
    )
    var builder = try MCPTasksServer.makeBuilder(
      implementation: MCPImplementation(name: "tasks-test-server", version: "1.0.0"),
      taskStore: store
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try MCPTasksServer.registerCallTool(
      on: &builder,
      store: store,
      idGenerator: FixedTaskIDGenerator()
    ) { params, _, creator in
      guard params.name == tool.name, let creator else {
        throw MCPRPCError.invalidParams
      }
      let taskID = try await creator.nextTaskID()
      let seed = try MCPTask(
        taskID: taskID,
        status: .working,
        createdAt: "2026-08-26T00:00:00Z",
        lastUpdatedAt: "2026-08-26T00:00:00Z",
        ttlMilliseconds: MCPJSONNumber(60_000),
        pollIntervalMilliseconds: MCPJSONNumber(100)
      )
      return .task(try await creator.create(.working(seed)))
    }
    return try builder.build()
  }
}

private struct InProcessTransport: MCPClientTransport {
  let server: MCPServer
  let endpointIdentity = "in-process:tasks"

  func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    let exchange = server.execute(request)
    return MCPClientExchange(
      frames: exchange.frames,
      cancel: { reason in await exchange.cancel(reason: reason) }
    )
  }
}

private struct FixedTaskIDGenerator: MCPTaskIDGenerating {
  func nextTaskID() async throws -> String { "fixed-task-id" }
}

private actor DelayedVisibilityTaskStore: MCPTaskStore {
  private let hiddenReads: Int
  private var stored: MCPDetailedTask?
  private(set) var readCount = 0

  init(hiddenReads: Int) { self.hiddenReads = hiddenReads }

  func create(_ task: MCPDetailedTask) async throws { stored = task }

  func task(taskID: String) async throws -> MCPDetailedTask? {
    readCount += 1
    guard readCount > hiddenReads, stored?.task.taskID == taskID else { return nil }
    return stored
  }

  func update(taskID: String, inputResponses: [String: MCPJSONValue]) async throws -> Bool {
    stored?.task.taskID == taskID
  }

  func requestCancellation(taskID: String) async throws -> Bool {
    stored?.task.taskID == taskID
  }
}

private actor TestTaskStore: MCPTaskStore {
  private var tasks: [String: MCPDetailedTask] = [:]
  private(set) var updateCount = 0
  private(set) var cancellationCount = 0

  func create(_ task: MCPDetailedTask) async throws {
    guard tasks[task.task.taskID] == nil else { throw MCPRPCError.invalidParams }
    tasks[task.task.taskID] = task
  }

  func task(taskID: String) async throws -> MCPDetailedTask? { tasks[taskID] }

  func update(taskID: String, inputResponses: [String: MCPJSONValue]) async throws -> Bool {
    guard tasks[taskID] != nil else { return false }
    updateCount += 1
    return true
  }

  func requestCancellation(taskID: String) async throws -> Bool {
    guard tasks[taskID] != nil else { return false }
    cancellationCount += 1
    return true
  }

  func requireInput(taskID: String) throws {
    guard let current = tasks[taskID] else { return }
    let base = try MCPTask(
      taskID: current.task.taskID,
      status: .inputRequired,
      createdAt: current.task.createdAt,
      lastUpdatedAt: "2026-08-26T00:00:01Z",
      ttlMilliseconds: current.task.ttlMilliseconds,
      pollIntervalMilliseconds: current.task.pollIntervalMilliseconds
    )
    tasks[taskID] = .inputRequired(
      base,
      inputRequests: [
        "answer": .object([
          "method": .string("elicitation/create"),
          "params": .object(["message": .string("Answer")]),
        ])
      ]
    )
  }
}
