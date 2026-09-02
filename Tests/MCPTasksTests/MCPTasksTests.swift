import MCP
import MCPHTTPClient
import MCPHTTPServer
import XCTest

@testable import MCPTasks

private actor HTTPTaskHeaderCapture {
  private var values: [MCPHTTPHeaders] = []

  func append(_ headers: MCPHTTPHeaders) {
    values.append(headers)
  }

  func snapshot() -> [MCPHTTPHeaders] {
    values
  }
}

private struct HTTPTaskAuthorizationVerifier: MCPHTTPAuthorizationVerifier {
  let capture: HTTPTaskHeaderCapture

  func authorize(
    headers: MCPHTTPHeaders,
    resource: URL,
    remoteAddress: String?
  ) async throws -> MCPAuthorizationContext {
    _ = resource
    _ = remoteAddress
    await capture.append(headers)
    return MCPAuthorizationContext(subject: "http-user", cachePartition: "http-user")
  }
}

final class MCPTasksModelTests: XCTestCase {
  func testTasksClientRejectsMismatchedTransportRegistry() throws {
    let transport = MCPHTTPClientTransport(
      configuration: try MCPHTTPClientConfiguration(
        endpoint: URL(string: "https://example.com/mcp")!
      ),
      registry: .standard
    )
    let configuration = try MCPClientConfiguration(
      implementation: MCPImplementation(name: "tasks-client", version: "1.0.0"),
      capabilities: try MCPTasksExtension.clientCapabilities()
    )

    XCTAssertThrowsError(
      try MCPTasksClient(transport: transport, configuration: configuration),
      "A Tasks client must reject a transport whose registry omits Tasks methods"
    ) { error in
      XCTAssertEqual(error as? MCPRegistryError, .registryMismatch)
    }
  }

  func testExtensionRegistryAugmentsToolsAndRegistersLifecycleMethods() throws {
    let registry = try MCPTasksExtension.methodRegistry()
    let callTool = try registry.require("tools/call")
    XCTAssertEqual(callTool.extensionResultTypes, ["task"])
    XCTAssertFalse(callTool.isExtension)
    XCTAssertNil(callTool.extensionIdentifier)
    XCTAssertEqual(
      try registry.require("tasks/get").httpName(from: ["taskId": .string("task-1")]),
      "task-1"
    )
    XCTAssertEqual(try registry.require("tasks/update").httpNameSource, .parameter("taskId"))
    XCTAssertEqual(try registry.require("tasks/cancel").httpNameSource, .parameter("taskId"))
  }

  func testTasksCapabilityAugmentationPreservesCoreCapabilitySettings() throws {
    let base = try MCPClientCapabilities(
      elicitation: MCPElicitationCapabilities(
        formSettings: ["ui": .string("native")],
        urlSettings: ["callback": .bool(true)]
      ),
      rootsSettings: ["scope": .string("workspace")],
      sampling: MCPSamplingCapabilities(
        contextSettings: ["mode": .string("server")],
        toolSettings: ["parallel": .bool(true)]
      )
    )

    let extended = try MCPTasksExtension.clientCapabilities(extending: base)

    XCTAssertEqual(extended.elicitation, base.elicitation)
    XCTAssertEqual(extended.rootsSettings, base.rootsSettings)
    XCTAssertEqual(extended.sampling, base.sampling)
    XCTAssertEqual(extended.extensions[MCPTasksExtension.identifier], .object([:]))
  }

  func testDetailedTaskRoundTripsEveryState() throws {
    let base = try task(status: .working)
    let values: [MCPDetailedTask] = [
      try MCPDetailedTask.working(base),
      try MCPDetailedTask.inputRequired(
        try task(status: .inputRequired),
        inputRequests: [
          "name": try MCPInputRequest(
            json: .object([
              "method": .string("elicitation/create"),
              "params": .object([
                "mode": .string("form"),
                "message": .string("Name"),
                "requestedSchema": .object([
                  "type": .string("object"),
                  "properties": .object([
                    "name": .object(["type": .string("string")])
                  ]),
                ]),
              ]),
            ]))
        ]
      ),
      try MCPDetailedTask.completed(
        try task(status: .completed),
        result: ["content": .array([.object(["type": .string("text"), "text": .string("ok")])])]
      ),
      try MCPDetailedTask.failed(
        try task(status: .failed),
        error: MCPRPCError(code: -32603, message: "failed")
      ),
      try MCPDetailedTask.cancelled(try task(status: .cancelled)),
    ]

    for value in values {
      XCTAssertEqual(try MCPDetailedTask(json: value.json), value)
      let result = MCPGetTaskResult(task: value)
      XCTAssertEqual(try MCPGetTaskResult(json: result.json), result)
    }
  }

  func testDetailedTaskFactoriesRejectStatusPayloadMismatches() throws {
    let working = try task(status: .working)
    XCTAssertThrowsError(
      try MCPDetailedTask.completed(working, result: [:])
    )
    XCTAssertThrowsError(
      try MCPDetailedTask.inputRequired(working, inputRequests: [:])
    )

    let completed = try task(status: .completed)
    XCTAssertThrowsError(
      try MCPDetailedTask.failed(completed, error: MCPRPCError(code: -32603, message: "failed"))
    )
  }

  func testTasksBuilderPreservesRequiredCapabilityWhenExtensionsAreChanged() throws {
    var builder = try MCPTasksServer.makeBuilder(
      implementation: MCPImplementation(name: "builder-test", version: "1.0.0"),
      taskStore: TestTaskStore(),
      idGenerator: FixedTaskIDGenerator()
    )
    XCTAssertEqual(builder.extensions[MCPTasksExtension.identifier], .object([:]))

    builder.extensions = [:]
    XCTAssertEqual(builder.extensions[MCPTasksExtension.identifier], .object([:]))

    builder.extensions = [
      MCPTasksExtension.identifier: .string("caller-must-not-mutate-this"),
      "com.example/other": .object(["enabled": .bool(true)]),
    ]
    XCTAssertEqual(builder.extensions[MCPTasksExtension.identifier], .object([:]))
    XCTAssertEqual(
      builder.extensions["com.example/other"], .object(["enabled": .bool(true)])
    )

    let server = try builder.build()
    XCTAssertEqual(server.capabilities.extensions[MCPTasksExtension.identifier], .object([:]))
  }

  func testRawServerBuilderRejectsUntrustedOfficialTasksRegistration() throws {
    XCTAssertThrowsError(
      try MCPServerBuilder(
        implementation: MCPImplementation(name: "raw-tasks-methods", version: "1.0.0"),
        extensionMethods: [try MCPTasksMethods.get.descriptor]
      )
    ) { error in
      XCTAssertEqual(
        error as? MCPServerBuildError,
        .untrustedOfficialExtension(MCPTasksExtension.identifier)
      )
    }

    XCTAssertThrowsError(
      try MCPServerBuilder(
        implementation: MCPImplementation(name: "raw-tasks-capability", version: "1.0.0"),
        extensions: [MCPTasksExtension.identifier: .object([:])]
      )
    ) { error in
      XCTAssertEqual(
        error as? MCPServerBuildError,
        .untrustedOfficialExtension(MCPTasksExtension.identifier)
      )
    }
  }

  func testRawServerBuilderCannotReintroduceOfficialCapabilityAfterMutation() throws {
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "raw-mutation", version: "1.0.0")
    )

    builder.extensions = [MCPTasksExtension.identifier: .object([:])]
    XCTAssertNil(builder.extensions[MCPTasksExtension.identifier])
    XCTAssertThrowsError(try builder.build()) { error in
      XCTAssertEqual(
        error as? MCPServerBuildError,
        .untrustedOfficialExtension(MCPTasksExtension.identifier)
      )
    }
  }

  func testRawServerBuilderRejectsOfficialDescriptorRegistration() throws {
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "raw-descriptor", version: "1.0.0")
    )
    XCTAssertThrowsError(
      try builder.register(try MCPTasksMethods.get) { _, _ in
        throw MCPRPCError.internalError
      }
    ) { error in
      XCTAssertEqual(
        error as? MCPServerBuildError,
        .untrustedOfficialExtension(MCPTasksExtension.identifier)
      )
    }
  }

  func testRawServerBuilderStillAcceptsVendorCapabilities() throws {
    let builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "vendor-capability", version: "1.0.0"),
      extensions: ["com.example/feature": .object(["enabled": .bool(true)])]
    )
    XCTAssertEqual(
      builder.extensions["com.example/feature"],
      .object(["enabled": .bool(true)])
    )
    XCTAssertNoThrow(try builder.build())
  }

  func testTasksBuilderRejectsGenericCallToolRegistration() throws {
    var standardBuilder = try MCPTasksServer.makeBuilder(
      implementation: MCPImplementation(name: "standard-register-test", version: "1.0.0"),
      taskStore: TestTaskStore()
    )
    XCTAssertThrowsError(
      try standardBuilder.register(MCPStandardMethods.callTool) { _, _ in
        try MCPCallToolResult(content: [])
      }
    ) { error in
      XCTAssertEqual(
        error as? MCPTasksServerBuildError,
        .callToolRequiresTaskAwareRegistration
      )
    }

    var tasksBuilder = try MCPTasksServer.makeBuilder(
      implementation: MCPImplementation(name: "tasks-register-test", version: "1.0.0"),
      taskStore: TestTaskStore()
    )
    XCTAssertThrowsError(
      try tasksBuilder.register(try MCPTasksMethods.callTool) { _, _ in
        .immediate(try MCPCallToolResult(content: []))
      }
    ) { error in
      XCTAssertEqual(
        error as? MCPTasksServerBuildError,
        .callToolRequiresTaskAwareRegistration
      )
    }

    var standardOutcomeBuilder = try MCPTasksServer.makeBuilder(
      implementation: MCPImplementation(name: "standard-outcome-test", version: "1.0.0"),
      taskStore: TestTaskStore()
    )
    XCTAssertThrowsError(
      try standardOutcomeBuilder.registerOutcome(MCPStandardMethods.callTool) { _, _ in
        .complete(try MCPCallToolResult(content: []))
      }
    ) { error in
      XCTAssertEqual(
        error as? MCPTasksServerBuildError,
        .callToolRequiresTaskAwareRegistration
      )
    }

    var tasksOutcomeBuilder = try MCPTasksServer.makeBuilder(
      implementation: MCPImplementation(name: "tasks-outcome-test", version: "1.0.0"),
      taskStore: TestTaskStore()
    )
    XCTAssertThrowsError(
      try tasksOutcomeBuilder.registerOutcome(try MCPTasksMethods.callTool) { _, _ in
        .complete(.immediate(try MCPCallToolResult(content: [])))
      }
    ) { error in
      XCTAssertEqual(
        error as? MCPTasksServerBuildError,
        .callToolRequiresTaskAwareRegistration
      )
    }
  }

  func testTasksCapabilityRequiresExactlyEmptyObject() throws {
    var empty = try MCPClientCapabilities(
      extensions: [MCPTasksExtension.identifier: .object([:])]
    )
    XCTAssertTrue(MCPTasksExtension.supportsTasks(empty))

    empty.extensions[MCPTasksExtension.identifier] = .object(["future": .bool(true)])
    XCTAssertFalse(MCPTasksExtension.supportsTasks(empty))

    empty.extensions[MCPTasksExtension.identifier] = .string("not-an-object")
    XCTAssertFalse(MCPTasksExtension.supportsTasks(empty))
  }

  func testTasksClientRejectsNonEmptyTasksCapability() throws {
    let capabilities = try MCPClientCapabilities(
      extensions: [
        MCPTasksExtension.identifier: .object(["future": .bool(true)])
      ]
    )
    let configuration = try MCPClientConfiguration(
      implementation: MCPImplementation(name: "invalid-tasks-client", version: "1.0.0"),
      capabilities: capabilities
    )
    let server = try MCPServerBuilder(
      implementation: MCPImplementation(name: "unused-server", version: "1.0.0")
    ).build()
    XCTAssertThrowsError(
      try MCPTasksClient(
        transport: MCPInMemoryClientTransport(server: server),
        configuration: configuration
      )
    ) { error in
      XCTAssertEqual(error as? MCPTasksClientError, .capabilityNotDeclared)
    }
  }

  func testTaskModelRejectsInvalidStatusPayload() throws {
    var raw = try task(status: .working).json.objectValue ?? [:]
    raw["result"] = .object([:])
    XCTAssertThrowsError(try MCPDetailedTask(json: .object(raw)))

    raw = try task(status: .inputRequired).json.objectValue ?? [:]
    raw["inputRequests"] = .object([:])
    XCTAssertNoThrow(try MCPDetailedTask(json: .object(raw)))
  }

  func testTaskIDMustBeNonEmptyAtTheProtocolBoundary() throws {
    XCTAssertThrowsError(try MCPGetTaskParams(taskID: ""))
    XCTAssertThrowsError(try MCPUpdateTaskParams(taskID: "", inputResponses: [:]))
    XCTAssertThrowsError(try MCPCancelTaskParams(taskID: ""))
    XCTAssertThrowsError(
      try MCPTask(
        taskID: "",
        status: .working,
        createdAt: "2026-07-28T00:00:00Z",
        lastUpdatedAt: "2026-07-28T00:00:00Z",
        ttlMilliseconds: nil
      )
    )
  }

  func testTaskMillisecondDurationsAcceptTheCompleteSafeIntegerRange() throws {
    let negative = try MCPTask(
      taskID: "negative",
      status: .working,
      createdAt: "2026-07-28T00:00:00Z",
      lastUpdatedAt: "2026-07-28T00:00:00Z",
      ttlMilliseconds: MCPJSONNumber(-1),
      pollIntervalMilliseconds: MCPJSONNumber(-1)
    )
    XCTAssertEqual(negative.ttlMilliseconds, MCPJSONNumber(-1))
    XCTAssertEqual(negative.pollIntervalMilliseconds, MCPJSONNumber(-1))

    XCTAssertThrowsError(
      try MCPTask(
        taskID: "too-small",
        status: .working,
        createdAt: "2026-07-28T00:00:00Z",
        lastUpdatedAt: "2026-07-28T00:00:00Z",
        ttlMilliseconds: try MCPJSONNumber(rawValue: "-9007199254740992")
      )
    )
    XCTAssertThrowsError(
      try MCPTask(
        taskID: "too-large",
        status: .working,
        createdAt: "2026-07-28T00:00:00Z",
        lastUpdatedAt: "2026-07-28T00:00:00Z",
        ttlMilliseconds: try MCPJSONNumber(rawValue: "9007199254740992")
      )
    )
    XCTAssertThrowsError(
      try MCPTask(
        taskID: "fractional",
        status: .working,
        createdAt: "2026-07-28T00:00:00Z",
        lastUpdatedAt: "2026-07-28T00:00:00Z",
        ttlMilliseconds: try MCPJSONNumber(rawValue: "1.5")
      )
    )
  }

  func testTaskTimestampsUseStrictInternetTimestampSubset() throws {
    for timestamp in [
      "2026-07-28T00:00:00Z",
      "2026-07-28T00:00:00.1Z",
      "2026-07-28T00:00:00.123456789Z",
      "2026-07-28T12:34:56+09:00",
      "2026-07-28T12:34:56-05:30",
    ] {
      XCTAssertNoThrow(
        try MCPTask(
          taskID: "valid-(timestamp)",
          status: .working,
          createdAt: timestamp,
          lastUpdatedAt: timestamp,
          ttlMilliseconds: nil
        )
      )
    }

    for timestamp in [
      "2026-02-30T00:00:00Z",
      "2026-07-28T24:00:00Z",
      "2026-07-28T00:60:00Z",
      "2026-07-28T00:00:60Z",
      "2026-07-28T00:00:00z",
      "2026-07-28T00:00:00+24:00",
      "2026-07-28T00:00:00+00:60",
      "2026-07-28T00:00:00.1234567890Z",
      "2026-7-28T00:00:00Z",
      "2026-07-28T0:00:00Z",
    ] {
      XCTAssertThrowsError(
        try MCPTask(
          taskID: "invalid",
          status: .working,
          createdAt: timestamp,
          lastUpdatedAt: "2026-07-28T00:00:00Z",
          ttlMilliseconds: nil
        ),
        "invalid timestamp should fail closed: \(timestamp)"
      )
    }
  }

  func testInputResponsesMayBeEmptyButMustDecodeStableUnionMembers() throws {
    let empty = try MCPUpdateTaskParams(taskID: "task-1", inputResponses: [:])
    XCTAssertTrue(empty.inputResponses.isEmpty)

    XCTAssertThrowsError(
      try MCPUpdateTaskParams(
        json: .object([
          "taskId": .string("task-1"),
          "inputResponses": .object(["answer": .string("not-an-object")]),
        ])
      )
    )
  }

  func testInputResponsePreservesValidElicitationObjectShape() throws {
    let raw = MCPJSONValue.object([
      "action": .string("accept"),
      "content": .object([
        "vendorField": .array([.string("preserved")]),
        "count": .number(MCPJSONNumber(7)),
      ]),
    ])
    let response = try MCPUpdateTaskParams(
      taskID: "task-1",
      inputResponses: ["vendor/input": try MCPInputResponse(json: raw)]
    )

    XCTAssertEqual(response.inputResponses["vendor/input"]?.json, raw)
    XCTAssertEqual(try MCPUpdateTaskParams(json: response.json), response)
  }

  func testInputResponseRejectsObjectOutsideStableUnion() throws {
    XCTAssertThrowsError(
      try MCPUpdateTaskParams(
        json: .object([
          "taskId": .string("task-1"),
          "inputResponses": .object([
            "vendor/input": .object(["vendorField": .bool(true)])
          ]),
        ])
      )
    )
  }

  func testInputResponsesAcceptEveryStableUnionMember() throws {
    let responses = try MCPUpdateTaskParams(
      taskID: "task-1",
      inputResponses: [
        "elicitation": try MCPInputResponse(
          json: .object(["action": .string("decline")])
        ),
        "roots": try MCPInputResponse(
          json: .object([
            "roots": .array([.object(["uri": .string("file:///workspace")])])
          ])
        ),
        "sampling": try MCPInputResponse(
          json: .object([
            "content": .object(["type": .string("text"), "text": .string("sampled")]),
            "model": .string("fixture-model"),
            "role": .string("assistant"),
          ])
        ),
      ]
    )

    XCTAssertEqual(responses.inputResponses.count, 3)
  }

  func testInputResponsesRejectMalformedElicitationResult() throws {
    XCTAssertThrowsError(
      try MCPUpdateTaskParams(
        json: .object([
          "taskId": .string("task-1"),
          "inputResponses": .object([
            "elicitation": .object([
              "action": .string("unsupported")
            ])
          ]),
        ])
      )
    )
  }

  func testInputResponsesRejectMalformedRootsResult() throws {
    XCTAssertThrowsError(
      try MCPUpdateTaskParams(
        json: .object([
          "taskId": .string("task-1"),
          "inputResponses": .object([
            "roots": .object([
              "roots": .array([.object(["uri": .number(MCPJSONNumber(7))])])
            ])
          ]),
        ])
      )
    )
  }

  func testInputResponsesRejectMalformedSamplingResult() throws {
    XCTAssertThrowsError(
      try MCPUpdateTaskParams(
        json: .object([
          "taskId": .string("task-1"),
          "inputResponses": .object([
            "sampling": .object([
              "content": .object(["type": .string("text")]),
              "model": .string("fixture-model"),
              "role": .string("assistant"),
            ])
          ]),
        ])
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

  func testRootsInputRequestMayOmitParams() throws {
    var raw = try task(status: .inputRequired).json.objectValue ?? [:]
    raw["inputRequests"] = .object([
      "roots": .object(["method": .string("roots/list")])
    ])
    XCTAssertNoThrow(try MCPDetailedTask(json: .object(raw)))
  }

  func testInputResponsesRejectJSONRPCEnvelopeFields() throws {
    XCTAssertThrowsError(
      try MCPUpdateTaskParams(
        json: .object([
          "taskId": .string("task-1"),
          "inputResponses": .object([
            "answer": .object([
              "jsonrpc": .string("2.0"),
              "result": .object([:]),
            ])
          ]),
        ])
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
    let persisted = try await store.task(
      taskID: created.task.taskID, authorization: MCPAuthorizationContext())
    XCTAssertNotNil(persisted)

    let current = try await client.getTask(taskID: created.task.taskID)
    XCTAssertEqual(current.task.task.status, .working)

    try await store.requireInput(taskID: created.task.taskID)
    let input = try await client.getTask(taskID: created.task.taskID)
    XCTAssertEqual(input.task.task.status, .inputRequired)
    XCTAssertNotNil(input.task.inputRequests?["answer"])

    _ = try await client.updateTask(
      taskID: created.task.taskID,
      inputResponses: [
        "answer": try MCPInputResponse(
          json: .object([
            "action": .string("accept"), "content": .object(["value": .string("42")]),
          ])
        )
      ]
    )
    let updateCount = await store.updateCount
    XCTAssertEqual(updateCount, 1)
    let resumed = try await client.getTask(taskID: created.task.taskID)
    XCTAssertEqual(resumed.task.task.status, .working)
    XCTAssertNil(resumed.task.inputRequests)

    _ = try await client.cancelTask(taskID: created.task.taskID)
    let cancellationCount = await store.cancellationCount
    XCTAssertEqual(cancellationCount, 1)
    let cancelled = try await client.getTask(taskID: created.task.taskID)
    XCTAssertEqual(cancelled.task.task.status, .cancelled)
  }

  func testUnknownInputResponseIsAcknowledgedWithoutChangingTaskState() async throws {
    let store = TestTaskStore()
    let server = try makeServer(store: store)
    let transport = InProcessTransport(server: server)
    let configuration = try MCPClientConfiguration(
      implementation: MCPImplementation(name: "tasks-unknown-input-client", version: "1.0.0"),
      capabilities: try MCPTasksExtension.clientCapabilities()
    )
    let client = try MCPTasksClient(transport: transport, configuration: configuration)
    let created = try await client.callTool(try MCPCallToolParams(name: "long-work"))
    guard case .task(let task) = created else {
      return XCTFail("expected task result")
    }

    let acknowledgement = try await client.updateTask(
      taskID: task.task.taskID,
      inputResponses: [
        "already-satisfied-or-unknown": try MCPInputResponse(
          json: .object([
            "action": .string("accept"),
            "content": .object(["value": .string("ignored")]),
          ])
        )
      ]
    )
    XCTAssertEqual(acknowledgement.resultType, .complete)
    let current = try await client.getTask(taskID: task.task.taskID)
    XCTAssertEqual(current.task.task.status, .working)
    let updateCount = await store.updateCount
    XCTAssertEqual(updateCount, 1)
  }

  func testTaskCreatorWaitsForStoreVisibilityBeforeReturningHandle() async throws {
    let store = DelayedVisibilityTaskStore(hiddenReads: 2)
    let creator = MCPTaskCreator(
      store: store,
      authorization: MCPAuthorizationContext(),
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

    let result = try await creator.create(try MCPDetailedTask.working(seed))
    XCTAssertEqual(result.task.taskID, "fixed-task-id")
    let readCount = await store.readCount
    XCTAssertEqual(readCount, 3)
  }

  func testTaskCreationFailsAmbiguouslyWhenDurabilityCannotBeConfirmed() async throws {
    let store = DelayedVisibilityTaskStore(hiddenReads: .max)
    let server = try makeServer(
      store: store,
      durability: try MCPTaskDurabilityPolicy(maximumReadAttempts: 3, retryDelay: .zero)
    )
    let configuration = try MCPClientConfiguration(
      implementation: MCPImplementation(name: "tasks-durability-client", version: "1.0.0"),
      capabilities: try MCPTasksExtension.clientCapabilities()
    )
    let client = try MCPTasksClient(
      transport: InProcessTransport(server: server),
      configuration: configuration
    )

    do {
      _ = try await client.callTool(try MCPCallToolParams(name: "long-work"))
      XCTFail("a task handle must not escape before durability is confirmed")
    } catch MCPClientError.rpc(let error) {
      XCTAssertEqual(error.code.int64Value, -32603)
      XCTAssertEqual(error.message, "Task durability could not be confirmed")
      XCTAssertEqual(error.data?.objectValue?["taskId"], .string("fixed-task-id"))
      XCTAssertEqual(error.data?.objectValue?["ambiguous"], .bool(true))
    }
    let readCount = await store.readCount
    XCTAssertEqual(readCount, 3)
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
      registry: try MCPTasksExtension.methodRegistry()
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

  func testServerNeverReturnsTaskHandleForUnsupportedTasksCapability() async throws {
    let store = TestTaskStore()
    let server = try makeServer(store: store, allowTaskWithoutCapability: true)
    let capabilities = try MCPClientCapabilities(
      extensions: [
        MCPTasksExtension.identifier: .object(["future": .bool(true)])
      ]
    )
    let configuration = try MCPClientConfiguration(
      implementation: MCPImplementation(name: "unsupported-tasks-client", version: "1.0.0"),
      capabilities: capabilities
    )
    let client = try MCPClient(
      transport: MCPInMemoryClientTransport(server: server),
      configuration: configuration,
      registry: try MCPTasksExtension.methodRegistry()
    )

    do {
      _ = try await client.call(
        MCPTasksMethods.callTool,
        params: MCPCallToolParams(name: "long-work")
      )
      XCTFail("unsupported Tasks capability must not receive a task handle")
    } catch MCPClientError.rpc(let error) {
      XCTAssertEqual(error.code.int64Value, -32021)
    }
  }

  func testAuthorizationContextIsolatesTaskLifecycle() async throws {
    let store = TestTaskStore()
    let server = try makeServer(store: store)
    let capabilities = try MCPTasksExtension.clientCapabilities()

    func makeClient(
      subject: String,
      endpointIdentity: String
    ) throws -> MCPTasksClient {
      let transport = MCPInMemoryClientTransport(
        server: server,
        endpointIdentity: endpointIdentity,
        authorization: MCPAuthorizationContext(subject: subject, cachePartition: subject)
      )
      let configuration = try MCPClientConfiguration(
        implementation: MCPImplementation(name: "tasks-\(subject)", version: "1.0.0"),
        capabilities: capabilities
      )
      return try MCPTasksClient(transport: transport, configuration: configuration)
    }

    let alice = try makeClient(subject: "alice", endpointIdentity: "in-process:alice")
    let bob = try makeClient(subject: "bob", endpointIdentity: "in-process:bob")
    let created = try await alice.callTool(try MCPCallToolParams(name: "long-work"))
    guard case .task(let task) = created else {
      return XCTFail("expected Alice to create a task")
    }

    for operation in ["get", "update", "cancel"] {
      do {
        switch operation {
        case "get": _ = try await bob.getTask(taskID: task.task.taskID)
        case "update": _ = try await bob.updateTask(taskID: task.task.taskID, inputResponses: [:])
        default: _ = try await bob.cancelTask(taskID: task.task.taskID)
        }
        XCTFail("Bob must not access Alice's task through \(operation)")
      } catch MCPClientError.rpc(let error) {
        XCTAssertEqual(error.code.int64Value, -32602, operation)
      }
    }

    let aliceTask = try await alice.getTask(taskID: task.task.taskID)
    XCTAssertEqual(aliceTask.task.task.taskID, task.task.taskID)
    _ = try await alice.updateTask(taskID: task.task.taskID, inputResponses: [:])
    _ = try await alice.cancelTask(taskID: task.task.taskID)
    let updateCount = await store.updateCount
    let cancellationCount = await store.cancellationCount
    XCTAssertEqual(updateCount, 1)
    XCTAssertEqual(cancellationCount, 1)
  }

  func testStreamableHTTPRoutesTaskLifecycleWithTaskIDNameHeader() async throws {
    let store = TestTaskStore()
    let server = try makeServer(store: store)
    let capture = HTTPTaskHeaderCapture()
    let httpConfiguration = try MCPHTTPConfiguration(
      authorizationVerifier: HTTPTaskAuthorizationVerifier(capture: capture),
      socketTimeout: 5
    )
    let httpServer = MCPHTTPServer(server: server, configuration: httpConfiguration)
    let endpoint = try httpServer.start()

    do {
      let transport = MCPHTTPClientTransport(
        configuration: try MCPHTTPClientConfiguration(endpoint: endpoint, networkTimeout: 5),
        registry: try MCPTasksExtension.methodRegistry()
      )
      let configuration = try MCPClientConfiguration(
        implementation: MCPImplementation(name: "http-tasks-client", version: "1.0.0"),
        capabilities: try MCPTasksExtension.clientCapabilities(),
        requestTimeout: .seconds(5)
      )
      let client = try MCPTasksClient(transport: transport, configuration: configuration)

      let created = try await client.callTool(try MCPCallToolParams(name: "long-work"))
      guard case .task(let task) = created else {
        await httpServer.shutdown()
        return XCTFail("expected task result over Streamable HTTP")
      }
      _ = try await client.getTask(taskID: task.task.taskID)
      _ = try await client.updateTask(taskID: task.task.taskID, inputResponses: [:])
      _ = try await client.cancelTask(taskID: task.task.taskID)

      let headers = await capture.snapshot()
      XCTAssertEqual(
        headers.map { $0["Mcp-Method"] },
        ["tools/call", "tasks/get", "tasks/update", "tasks/cancel"]
      )
      XCTAssertEqual(
        headers.map { $0["Mcp-Name"] },
        ["long-work", task.task.taskID, task.task.taskID, task.task.taskID]
      )
    } catch {
      await httpServer.shutdown()
      throw error
    }

    await httpServer.shutdown()
    XCTAssertNil(httpServer.boundEndpoint)
  }

  private func makeServer(
    store: any MCPTaskStore,
    allowTaskWithoutCapability: Bool = false,
    durability: MCPTaskDurabilityPolicy = .default
  ) throws -> MCPServer {
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
      taskStore: store,
      idGenerator: FixedTaskIDGenerator(),
      durability: durability
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.registerCallTool { params, _, creator in
      guard params.name == tool.name else {
        throw MCPRPCError.invalidParams
      }
      if creator == nil, allowTaskWithoutCapability {
        let task = try MCPTask(
          taskID: "unnegotiated-task",
          status: .working,
          createdAt: "2026-08-26T00:00:00Z",
          lastUpdatedAt: "2026-08-26T00:00:00Z",
          ttlMilliseconds: MCPJSONNumber(60_000)
        )
        return .task(MCPCreateTaskResult(task: task))
      }
      guard let creator else { throw MCPRPCError.invalidParams }
      let taskID = try await creator.nextTaskID()
      let seed = try MCPTask(
        taskID: taskID,
        status: .working,
        createdAt: "2026-08-26T00:00:00Z",
        lastUpdatedAt: "2026-08-26T00:00:00Z",
        ttlMilliseconds: MCPJSONNumber(60_000),
        pollIntervalMilliseconds: MCPJSONNumber(100)
      )
      return .task(try await creator.create(try MCPDetailedTask.working(seed)))
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

  func create(
    _ task: MCPDetailedTask,
    authorization: MCPAuthorizationContext
  ) async throws {
    _ = authorization
    stored = task
  }

  func task(
    taskID: String,
    authorization: MCPAuthorizationContext
  ) async throws -> MCPDetailedTask? {
    _ = authorization
    readCount += 1
    guard readCount > hiddenReads, stored?.task.taskID == taskID else { return nil }
    return stored
  }

  func update(
    taskID: String,
    inputResponses: [String: MCPInputResponse],
    authorization: MCPAuthorizationContext
  ) async throws -> Bool {
    _ = inputResponses
    _ = authorization
    return stored?.task.taskID == taskID
  }

  func requestCancellation(
    taskID: String,
    authorization: MCPAuthorizationContext
  ) async throws -> Bool {
    _ = authorization
    return stored?.task.taskID == taskID
  }
}

private actor TestTaskStore: MCPTaskStore {
  private var tasks: [String: MCPDetailedTask] = [:]
  private var owners: [String: String] = [:]
  private(set) var updateCount = 0
  private(set) var cancellationCount = 0

  func create(
    _ task: MCPDetailedTask,
    authorization: MCPAuthorizationContext
  ) async throws {
    guard tasks[task.task.taskID] == nil else { throw MCPRPCError.invalidParams }
    tasks[task.task.taskID] = task
    owners[task.task.taskID] = ownerKey(authorization)
  }

  func task(
    taskID: String,
    authorization: MCPAuthorizationContext
  ) async throws -> MCPDetailedTask? {
    guard owners[taskID] == ownerKey(authorization) else { return nil }
    return tasks[taskID]
  }

  func update(
    taskID: String,
    inputResponses: [String: MCPInputResponse],
    authorization: MCPAuthorizationContext
  ) async throws -> Bool {
    guard let current = tasks[taskID], owners[taskID] == ownerKey(authorization) else {
      return false
    }
    if current.task.status == .inputRequired,
      let outstanding = current.inputRequests,
      inputResponses.keys.contains(where: { outstanding[$0] != nil })
    {
      let working = try MCPTask(
        taskID: current.task.taskID,
        status: .working,
        createdAt: current.task.createdAt,
        lastUpdatedAt: "2026-08-26T00:00:02Z",
        ttlMilliseconds: current.task.ttlMilliseconds,
        pollIntervalMilliseconds: current.task.pollIntervalMilliseconds
      )
      tasks[taskID] = try MCPDetailedTask.working(working)
    }
    updateCount += 1
    return true
  }

  func requestCancellation(
    taskID: String,
    authorization: MCPAuthorizationContext
  ) async throws -> Bool {
    guard let current = tasks[taskID], owners[taskID] == ownerKey(authorization) else {
      return false
    }
    let cancelled = try MCPTask(
      taskID: current.task.taskID,
      status: .cancelled,
      createdAt: current.task.createdAt,
      lastUpdatedAt: "2026-08-26T00:00:03Z",
      ttlMilliseconds: current.task.ttlMilliseconds,
      pollIntervalMilliseconds: current.task.pollIntervalMilliseconds
    )
    tasks[taskID] = try MCPDetailedTask.cancelled(cancelled)
    cancellationCount += 1
    return true
  }

  private func ownerKey(_ authorization: MCPAuthorizationContext) -> String {
    authorization.subject ?? "<anonymous>"
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
    tasks[taskID] = try MCPDetailedTask.inputRequired(
      base,
      inputRequests: [
        "answer": try MCPInputRequest(
          json: .object([
            "method": .string("elicitation/create"),
            "params": .object([
              "mode": .string("form"),
              "message": .string("Answer"),
              "requestedSchema": .object([
                "type": .string("object"),
                "properties": .object([:]),
              ]),
            ]),
          ]))
      ]
    )
  }
}
