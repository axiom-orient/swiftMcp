import Foundation
import XCTest

@testable import MCP

private actor RuntimeCounter {
  private var value = 0
  func increment() -> Int {
    value += 1
    return value
  }
  func current() -> Int { value }
}

private actor RuntimeCapture<Value: Sendable> {
  private var values: [Value] = []
  func append(_ value: Value) { values.append(value) }
  func snapshot() -> [Value] { values }
}

private actor BlockingFirstInsertCache: MCPCacheStore {
  private var entries: [MCPCacheKey: MCPCacheEntry] = [:]
  private var shouldBlock = true
  private var insertIsBlocked = false
  private var blockedInsert: CheckedContinuation<Void, Never>?
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var invalidationCount = 0
  private var cleanupIsBlocked = false
  private var blockedCleanup: CheckedContinuation<Void, Never>?
  private var cleanupWaiters: [CheckedContinuation<Void, Never>] = []

  func value(for key: MCPCacheKey) -> MCPCacheEntry? { entries[key] }

  func insert(_ entry: MCPCacheEntry, for key: MCPCacheKey) async {
    if shouldBlock {
      shouldBlock = false
      insertIsBlocked = true
      let waiters = startWaiters
      startWaiters.removeAll(keepingCapacity: true)
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        blockedInsert = continuation
      }
      insertIsBlocked = false
    }
    entries[key] = entry
  }

  func invalidate(_ invalidation: MCPCacheInvalidation) async {
    invalidationCount += 1
    if invalidationCount == 2 {
      cleanupIsBlocked = true
      let waiters = cleanupWaiters
      cleanupWaiters.removeAll(keepingCapacity: true)
      for waiter in waiters { waiter.resume() }
      await withCheckedContinuation { continuation in
        blockedCleanup = continuation
      }
      cleanupIsBlocked = false
    }
    switch invalidation {
    case .tools:
      entries = entries.filter { $0.key.method != "tools/list" }
    case .all, .endpoint:
      entries.removeAll(keepingCapacity: true)
    case .prompts, .resources, .resource:
      break
    }
  }

  func waitUntilInsertIsBlocked() async {
    if insertIsBlocked { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func releaseInsert() {
    blockedInsert?.resume()
    blockedInsert = nil
  }

  func waitUntilCleanupIsBlocked() async {
    if cleanupIsBlocked { return }
    await withCheckedContinuation { continuation in
      cleanupWaiters.append(continuation)
    }
  }

  func releaseCleanup() {
    blockedCleanup?.resume()
    blockedCleanup = nil
  }
}

private enum RuntimeCacheFailure: Error {
  case invalidationFailed
}

private actor FailingInvalidationCache: MCPCacheStore {
  private var entries: [MCPCacheKey: MCPCacheEntry] = [:]

  func value(for key: MCPCacheKey) -> MCPCacheEntry? { entries[key] }

  func insert(_ entry: MCPCacheEntry, for key: MCPCacheKey) {
    entries[key] = entry
  }

  func invalidate(_ invalidation: MCPCacheInvalidation) throws {
    _ = invalidation
    throw RuntimeCacheFailure.invalidationFailed
  }
}

private struct RuntimeDiagnosticSink: MCPDiagnosticSink {
  let events: RuntimeCapture<MCPDiagnosticEvent>

  func record(_ event: MCPDiagnosticEvent) async {
    await events.append(event)
  }
}

private final class SchemaCompileCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  func increment() {
    lock.lock()
    storage += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }
}

private struct CountingSchemaValidator: MCPJSONSchemaValidating {
  let counter: SchemaCompileCounter
  let base = MCPJSONSchemaValidator()

  func compile(_ schema: MCPJSONValue) throws -> any MCPJSONSchemaValidationPlan {
    counter.increment()
    return try base.compile(schema)
  }
}

private struct NeverEndingTransport: MCPClientTransport {
  let endpointIdentity = "never"
  let cancellationReasons: RuntimeCapture<String?>

  func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream()
    return MCPClientExchange(
      frames: pair.stream,
      cancel: { reason in
        await cancellationReasons.append(reason)
        pair.continuation.finish()
      }
    )
  }
}

private struct CancellationInsensitiveOpenTransport: MCPClientTransport {
  let endpointIdentity = "slow-open"
  let delay: TimeInterval
  let cancellationReasons: RuntimeCapture<String?>

  func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    _ = request
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
        continuation.resume()
      }
    }
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream()
    return MCPClientExchange(
      frames: pair.stream,
      cancel: { reason in
        await cancellationReasons.append(reason)
        pair.continuation.finish()
      }
    )
  }
}

private struct CountingOpenTransport: MCPClientTransport {
  let endpointIdentity = "counting"
  let opens: RuntimeCounter

  func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    _ = request
    _ = await opens.increment()
    throw MCPClientError.transport("unexpected open")
  }
}

private struct ScriptedTransport: MCPClientTransport {
  let endpointIdentity = "scripted"
  let frames: @Sendable (MCPWireRequest) throws -> [MCPWireMessage]
  let cancellationReasons: RuntimeCapture<String?>

  func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    let scripted = try frames(request)
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream()
    for frame in scripted { pair.continuation.yield(frame) }
    pair.continuation.finish()
    return MCPClientExchange(
      frames: pair.stream,
      cancel: { reason in await cancellationReasons.append(reason) }
    )
  }
}

final class MCPRuntimeTests: XCTestCase {
  private func implementation(_ name: String = "test") throws -> MCPImplementation {
    try MCPImplementation(name: name, version: "1.0.0")
  }

  private func client(
    transport: any MCPClientTransport,
    capabilities: MCPClientCapabilities? = nil,
    timeout: Duration? = .seconds(2),
    cache: (any MCPCacheStore)? = nil,
    partition: String? = nil,
    schemaValidator: any MCPJSONSchemaValidating = MCPJSONSchemaValidator()
  ) throws -> MCPClient {
    try MCPClient(
      transport: transport,
      configuration: MCPClientConfiguration(
        implementation: implementation("client"),
        capabilities: try capabilities ?? MCPClientCapabilities(),
        requestTimeout: timeout,
        schemaValidator: schemaValidator,
        cache: cache,
        cacheAuthorizationPartition: partition
      )
    )
  }

  private func tool() throws -> MCPTool {
    try MCPTool(
      name: "echo",
      description: "Echo input",
      inputSchema: [
        "type": .string("object"),
        "properties": .object(["text": .object(["type": .string("string")])]),
        "required": .array([.string("text")]),
        "additionalProperties": .bool(false),
      ],
      outputSchema: ["type": .string("object")]
    )
  }

  private func makeToolServer(
    calls: RuntimeCounter = RuntimeCounter(),
    contexts: RuntimeCapture<MCPRequestContext>? = nil,
    progress: Bool = false,
    listChanged: Bool = false,
    cacheScope: MCPCacheScope = .public
  ) throws -> MCPServer {
    var builder = try MCPServerBuilder(implementation: implementation("server"))
    let tool = try tool()
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, context in
      await contexts?.append(context)
      _ = await calls.increment()
      return MCPListToolsResult(
        tools: [tool],
        cache: try MCPCachePolicy(ttlMilliseconds: 60_000, scope: cacheScope)
      )
    }
    try builder.register(MCPStandardMethods.callTool) { params, context in
      await contexts?.append(context)
      if progress {
        try await context.progress?.report(progress: 0.25, total: 1, message: "started")
        try await context.progress?.report(progress: 1, total: 1, message: "done")
      }
      let text = params.arguments["text"]?.stringValue ?? ""
      return try MCPCallToolResult(
        content: [.text(MCPTextContent(text: text))],
        structuredContent: .object(["echo": .string(text)])
      )
    }
    builder.enableToolListChanged(listChanged)
    return try builder.build()
  }

  func testRequestMetadataSizeLimitIsEnforcedBeforeTransportOrHandler() async throws {
    let opens = RuntimeCounter()
    let client = try MCPClient(
      transport: CountingOpenTransport(opens: opens),
      configuration: MCPClientConfiguration(
        implementation: implementation("small-client"),
        capabilities: MCPClientCapabilities(),
        maximumMetadataBytes: 1
      )
    )
    do {
      _ = try await client.discover()
      XCTFail("expected client metadata size rejection")
    } catch let error as MCPJSONError {
      XCTAssertTrue(error.description.contains("configured limit"))
    }
    let openCount = await opens.current()
    XCTAssertEqual(openCount, 0)

    let builder = try MCPServerBuilder(
      implementation: implementation("small-server"),
      configuration: MCPServerConfiguration(maximumMetadataBytes: 1)
    )
    let server = try builder.build()
    let metadata = try MCPRequestMetadata(clientCapabilities: MCPClientCapabilities())
    let request = try MCPWireRequest(
      id: MCPRequestID(1),
      method: "server/discover",
      params: metadata.inserting(into: [:])
    )
    do {
      _ = try await server.prepare(request)
      XCTFail("expected metadata size rejection")
    } catch let error as MCPJSONError {
      XCTAssertTrue(error.description.contains("configured limit"))
    }
  }

  func testStructuredDiagnosticsCarryRequestCorrelationWithoutPayloads() async throws {
    let serverEvents = RuntimeCapture<MCPDiagnosticEvent>()
    let clientEvents = RuntimeCapture<MCPDiagnosticEvent>()
    let server = try MCPServerBuilder(
      implementation: implementation("diagnostic-server")
    ).build(diagnostics: RuntimeDiagnosticSink(events: serverEvents))
    let client = try MCPClient(
      transport: MCPInMemoryClientTransport(server: server),
      configuration: MCPClientConfiguration(
        implementation: implementation("diagnostic-client"),
        capabilities: MCPClientCapabilities()
      ),
      diagnostics: RuntimeDiagnosticSink(events: clientEvents)
    )

    _ = try await client.discover()

    let recordedServerEvents = await serverEvents.snapshot()
    let recordedClientEvents = await clientEvents.snapshot()
    let serverCompletion = try XCTUnwrap(
      recordedServerEvents.first { $0.id == "mcp.request.completed" })
    let clientCompletion = try XCTUnwrap(
      recordedClientEvents.first { $0.id == "mcp.client.request.completed" })

    XCTAssertEqual(serverCompletion.fields["requestID"], "1")
    XCTAssertEqual(clientCompletion.fields["requestID"], "1")
    XCTAssertEqual(serverCompletion.fields["method"], "server/discover")
    XCTAssertEqual(clientCompletion.fields["method"], "server/discover")
    XCTAssertNil(serverCompletion.fields["params"])
    XCTAssertNil(clientCompletion.fields["result"])
  }

  func testPreparedRequestCannotCrossServerAuthorityBoundary() async throws {
    let first = try MCPServerBuilder(implementation: implementation("first")).build()
    let second = try MCPServerBuilder(implementation: implementation("second")).build()
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("client")
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(1),
      method: "server/discover",
      params: metadata.inserting(into: [:])
    )

    let prepared = try await first.prepare(request)
    XCTAssertThrowsError(try second.execute(prepared)) { error in
      XCTAssertEqual(error as? MCPServerExecutionError, .preparedRequestOwnerMismatch)
    }
  }

  func testBuilderRejectsPartialFeaturesAndDerivesCapabilities() throws {
    var incomplete = try MCPServerBuilder(implementation: implementation("partial"))
    try incomplete.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [])
    }
    XCTAssertThrowsError(try incomplete.build()) { error in
      guard case MCPServerBuildError.incompleteFeature = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    let server = try makeToolServer(listChanged: true)
    XCTAssertTrue(server.capabilities.tools)
    XCTAssertTrue(server.capabilities.toolListChanged)
    XCTAssertFalse(server.capabilities.prompts)
    XCTAssertFalse(server.capabilities.resources)
  }

  func testInMemoryDiscoveryToolCallProgressAndRequestLocalAuthorization() async throws {
    let contexts = RuntimeCapture<MCPRequestContext>()
    let server = try makeToolServer(contexts: contexts, progress: true)
    let authorization = MCPAuthorizationContext(
      subject: "alice",
      scopes: ["tools:call"],
      attributes: ["tenant": "a"],
      cachePartition: "tenant-a"
    )
    let transport = MCPInMemoryClientTransport(server: server, authorization: authorization)
    let client = try client(transport: transport)

    let discovery = try await client.discover()
    XCTAssertEqual(discovery.supportedVersions, [MCPProtocolVersion.current.rawValue])
    XCTAssertTrue(discovery.capabilities.tools)

    let listed = try await client.listTools()
    XCTAssertEqual(listed.tools.map(\.name), ["echo"])

    let progressValues = RuntimeCapture<Double>()
    let result = try await client.callTool(
      try MCPCallToolParams(name: "echo", arguments: ["text": .string("hello")]),
      progress: { update in
        guard let value = update.progress.doubleValue else {
          throw MCPClientError.protocolViolation("progress is not representable")
        }
        await progressValues.append(value)
      }
    )
    XCTAssertEqual(result.resultType, .complete)
    XCTAssertEqual(result.structuredContent, .object(["echo": .string("hello")]))
    let observedProgress = await progressValues.snapshot()
    XCTAssertEqual(observedProgress, [0.25, 1.0])

    let captured = await contexts.snapshot()
    XCTAssertEqual(captured.count, 2)
    XCTAssertTrue(captured.allSatisfy { $0.authorization.subject == "alice" })
    XCTAssertTrue(captured.allSatisfy { $0.metadata.protocolVersion == .current })
    XCTAssertEqual(captured.last?.metadata.progressToken, MCPProgressToken(3))
  }

  func testBuilderRequiresToolResolverForSchemaEnforcement() throws {
    let tool = try tool()
    var builder = try MCPServerBuilder(implementation: implementation("no-resolver"))
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }

    XCTAssertThrowsError(try builder.build()) { error in
      guard case MCPServerBuildError.incompleteFeature(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("schema validation"))
    }
  }

  func testServerRejectsInvalidToolInputBeforeInvokingHandler() async throws {
    let calls = RuntimeCounter()
    let tool = try tool()
    var builder = try MCPServerBuilder(implementation: implementation("validated-input"))
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      _ = await calls.increment()
      return try MCPCallToolResult(content: [])
    }
    let client = try client(
      transport: MCPInMemoryClientTransport(server: builder.build())
    )

    do {
      _ = try await client.callTool(
        MCPCallToolParams(name: "echo", arguments: ["text": .integer(1)])
      )
      XCTFail("expected invalid params")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(rpc.code, -32602)
      XCTAssertEqual(rpc.message, "Invalid tool arguments")
    }
    let callCount = await calls.current()
    XCTAssertEqual(callCount, 0)
  }

  func testServerClassifiesToolArgumentResourceLimitsAsInvalidParams() async throws {
    let calls = RuntimeCounter()
    let tool = try MCPTool(
      name: "bounded",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "nested": .object([
            "type": .string("object"),
            "properties": .object(["value": .object(["type": .string("string")])]),
          ])
        ]),
      ]
    )
    var builder = try MCPServerBuilder(
      implementation: implementation("bounded-input"),
      configuration: MCPServerConfiguration(
        schemaValidator: MCPJSONSchemaValidator(
          limits: MCPJSONSchemaLimits(maximumInstanceDepth: 1)
        )
      )
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [tool]) }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      _ = await calls.increment()
      return try MCPCallToolResult(content: [])
    }
    let client = try client(transport: MCPInMemoryClientTransport(server: builder.build()))

    do {
      _ = try await client.callTool(
        MCPCallToolParams(
          name: tool.name,
          arguments: ["nested": .object(["value": .string("too deep")])]
        )
      )
      XCTFail("expected a bounded input rejection")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(rpc.code, -32602)
      XCTAssertEqual(rpc.message, "Invalid tool arguments")
    }
    let callCount = await calls.current()
    XCTAssertEqual(callCount, 0)
  }

  func testDefaultRuntimeSupportsSelfContainedDynamicSchemas() async throws {
    let tool = try MCPTool(
      name: "dynamic",
      inputSchema: [
        "type": .string("object"),
        "$dynamicAnchor": .string("arguments"),
        "properties": .object([
          "children": .object([
            "type": .string("array"),
            "items": .object(["$dynamicRef": .string("#arguments")]),
          ])
        ]),
      ]
    )
    do {
      _ = try MCPOpaqueJSONSchemaValidator().compile(.object(tool.inputSchema))
    } catch {
      XCTFail("opaque validator rejected a JSON Schema payload: \(error)")
    }
    var defaultBuilder = try MCPServerBuilder(implementation: implementation("default-schema"))
    defaultBuilder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try defaultBuilder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try defaultBuilder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }
    let defaultServer = try defaultBuilder.build()
    XCTAssertNoThrow(
      try defaultServer.configuration.schemaValidator.compile(.object(tool.inputSchema)))
    let metadata = try MCPRequestMetadata(clientCapabilities: MCPClientCapabilities())
    let request = try MCPWireRequest(
      id: MCPRequestID(1),
      method: "tools/call",
      params: try metadata.inserting(
        into: MCPCallToolParams(name: tool.name, arguments: [:]).json.objectValue ?? [:]
      )
    )
    _ = try await defaultServer.prepare(request)

    let defaultClient = try MCPClient(
      transport: MCPInMemoryClientTransport(server: defaultServer),
      configuration: MCPClientConfiguration(
        implementation: implementation("default-client"),
        capabilities: MCPClientCapabilities()
      )
    )
    _ = try await defaultClient.listTools()
  }

  func testServerRejectsStructuredOutputThatViolatesDeclaredSchema() async throws {
    let tool = try tool()
    var builder = try MCPServerBuilder(implementation: implementation("validated-output"))
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(
        content: [],
        structuredContent: .array([.string("invalid")])
      )
    }
    let client = try client(
      transport: MCPInMemoryClientTransport(server: builder.build())
    )

    do {
      _ = try await client.callTool(
        MCPCallToolParams(name: "echo", arguments: ["text": .string("ok")])
      )
      XCTFail("expected server output rejection")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(rpc, .internalError)
    }
  }

  func testServerClassifiesMissingDeclaredStructuredOutputAsInternalError() async throws {
    let tool = try tool()
    var builder = try MCPServerBuilder(implementation: implementation("missing-output"))
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }
    let client = try client(transport: MCPInMemoryClientTransport(server: builder.build()))

    do {
      _ = try await client.callTool(
        MCPCallToolParams(name: "echo", arguments: ["text": .string("ok")])
      )
      XCTFail("expected missing structured output rejection")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(rpc, .internalError)
    }
  }

  func testStrictServerDoesNotEmitRetiredOrUnallocatedReservedErrorCodes() async throws {
    let params = try MCPCompleteParams(
      reference: .prompt(name: "prompt"),
      argument: MCPCompletionArgument(name: "value", value: "x")
    )
    for code: MCPRPCErrorCode in [-32002, -32042, -32023] {
      var builder = try MCPServerBuilder(implementation: implementation("reserved-error"))
      try builder.register(MCPStandardMethods.complete) { _, _ -> MCPCompleteResult in
        throw MCPRPCError(code: code, message: "must not escape")
      }
      let client = try client(transport: MCPInMemoryClientTransport(server: builder.build()))
      do {
        _ = try await client.complete(params)
        XCTFail("expected RPC error")
      } catch let error as MCPClientError {
        guard case .rpc(let rpc) = error else {
          return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(rpc, .internalError)
      }
    }
  }

  func testRPCErrorUsesCanonicalTypedCodeInitializer() {
    let code = MCPRPCErrorCode(-32002)
    let error = MCPRPCError(code: code, message: "typed")

    XCTAssertEqual(error.code, code)
  }

  func testClientValidatesKnownToolInputAndStructuredOutput() async throws {
    let tool = try tool()
    let cancellations = RuntimeCapture<String?>()
    let transport = ScriptedTransport(
      frames: { request in
        switch request.method {
        case "tools/list":
          let result = MCPListToolsResult(tools: [tool])
          return [.result(MCPWireResult(id: request.id, value: result.json.objectValue ?? [:]))]
        case "tools/call":
          let result = try MCPCallToolResult(
            content: [],
            structuredContent: .array([.string("invalid")])
          )
          return [.result(MCPWireResult(id: request.id, value: result.json.objectValue ?? [:]))]
        default:
          return [.error(MCPWireErrorResponse(id: request.id, error: .methodNotFound))]
        }
      },
      cancellationReasons: cancellations
    )
    let client = try client(transport: transport)
    _ = try await client.listTools()

    do {
      _ = try await client.callTool(
        MCPCallToolParams(name: "echo", arguments: ["text": .integer(1)])
      )
      XCTFail("expected client-side input validation")
    } catch {
      guard case MCPJSONSchemaError.validationFailed = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }

    do {
      _ = try await client.callTool(
        MCPCallToolParams(name: "echo", arguments: ["text": .string("ok")])
      )
      XCTFail("expected invalid structured output")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("structuredContent"))
    }
  }

  func testClientReusesCompiledToolSchemasFromItsCatalog() async throws {
    let tool = try tool()
    let compileCounter = SchemaCompileCounter()
    let transport = ScriptedTransport(
      frames: { request in
        switch request.method {
        case "tools/list":
          let result = MCPListToolsResult(tools: [tool])
          return [.result(MCPWireResult(id: request.id, value: result.json.objectValue ?? [:]))]
        case "tools/call":
          let result = try MCPCallToolResult(
            content: [],
            structuredContent: .object(["echo": .string("ok")])
          )
          return [.result(MCPWireResult(id: request.id, value: result.json.objectValue ?? [:]))]
        default:
          return [.error(MCPWireErrorResponse(id: request.id, error: .methodNotFound))]
        }
      },
      cancellationReasons: RuntimeCapture<String?>()
    )
    let client = try client(
      transport: transport,
      schemaValidator: CountingSchemaValidator(counter: compileCounter)
    )

    _ = try await client.listTools()
    XCTAssertEqual(compileCounter.value, 2)

    for _ in 0..<2 {
      _ = try await client.callTool(
        MCPCallToolParams(name: "echo", arguments: ["text": .string("ok")])
      )
    }
    XCTAssertEqual(compileCounter.value, 2)
  }

  func testServerReusesCompiledResolvedToolSchemasAcrossListAndCallRequests() async throws {
    let compileCounter = SchemaCompileCounter()
    let tool = try tool()
    var builder = try MCPServerBuilder(
      implementation: implementation("compiled-server"),
      configuration: MCPServerConfiguration(
        schemaValidator: CountingSchemaValidator(counter: compileCounter)
      )
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { params, _ in
      try MCPCallToolResult(
        content: [],
        structuredContent: .object(["echo": params.arguments["text"] ?? .null])
      )
    }
    let client = try client(
      transport: MCPInMemoryClientTransport(server: builder.build())
    )

    for _ in 0..<2 {
      _ = try await client.listTools()
      _ = try await client.callTool(
        MCPCallToolParams(name: "echo", arguments: ["text": .string("ok")])
      )
    }
    XCTAssertEqual(compileCounter.value, 2)
  }

  func testServerRejectsNonPositiveSubscriptionBufferLimit() throws {
    for invalidLimit in [0, -1] {
      var builder = try MCPServerBuilder(
        implementation: implementation("invalid-buffer"),
        configuration: MCPServerConfiguration(subscriptionBufferLimit: invalidLimit)
      )
      try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: []) }
      try builder.register(MCPStandardMethods.callTool) { _, _ in
        try MCPCallToolResult(content: [])
      }
      builder.setToolResolver { _, _ in nil }

      XCTAssertThrowsError(try builder.build()) { error in
        XCTAssertEqual(
          error as? MCPServerBuildError,
          .invalidConfiguration("subscriptionBufferLimit must be greater than zero")
        )
      }
    }
  }

  func testServerRejectsNonPositiveToolSchemaCacheLimit() throws {
    var builder = try MCPServerBuilder(
      implementation: implementation("invalid-schema-cache"),
      configuration: MCPServerConfiguration(maximumToolSchemaCacheEntries: 0)
    )
    try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: []) }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }
    builder.setToolResolver { _, _ in nil }

    XCTAssertThrowsError(try builder.build()) { error in
      XCTAssertEqual(
        error as? MCPServerBuildError,
        .invalidConfiguration("maximumToolSchemaCacheEntries must be greater than zero")
      )
    }
  }

  func testMissingMetadataIsRejectedBeforeHandler() async throws {
    let calls = RuntimeCounter()
    let server = try makeToolServer(calls: calls)
    let request = try MCPWireRequest(
      id: MCPRequestID(1),
      method: "tools/list",
      params: [:]
    )
    let exchange = server.execute(request)
    var messages: [MCPWireMessage] = []
    for try await frame in exchange.frames { messages.append(frame) }
    let callCount = await calls.current()
    XCTAssertEqual(callCount, 0)
    guard case .error(let response) = messages.first else {
      return XCTFail("expected error response")
    }
    XCTAssertEqual(response.error.code, -32602)
  }

  func testPublicCacheHitAndInvalidation() async throws {
    let calls = RuntimeCounter()
    let server = try makeToolServer(calls: calls)
    let cache = try MCPMemoryCache()
    let client = try client(
      transport: MCPInMemoryClientTransport(server: server),
      cache: cache
    )

    _ = try await client.listTools()
    _ = try await client.listTools()
    let initialCallCount = await calls.current()
    let initialCacheCount = await cache.count
    XCTAssertEqual(initialCallCount, 1)
    XCTAssertEqual(initialCacheCount, 1)

    try await client.invalidateCache(.tools)
    _ = try await client.listTools()
    let invalidatedCallCount = await calls.current()
    XCTAssertEqual(invalidatedCallCount, 2)
  }

  func testSubscriptionNotificationsInvalidateFreshCacheAutomatically() async throws {
    let calls = RuntimeCounter()
    let server = try makeToolServer(calls: calls, listChanged: true)
    let cache = try MCPMemoryCache()
    let client = try client(
      transport: MCPInMemoryClientTransport(server: server),
      cache: cache
    )

    _ = try await client.listTools()
    _ = try await client.listTools()
    let initialCalls = await calls.current()
    XCTAssertEqual(initialCalls, 1)

    let subscription = try await client.listen(
      notifications: MCPSubscriptionFilter(toolsListChanged: true)
    )
    var iterator = subscription.events.makeAsyncIterator()
    guard case .acknowledged? = try await iterator.next() else {
      return XCTFail("expected subscription acknowledgement")
    }
    try await server.notifyToolsChanged()
    guard case .notification(let notification)? = try await iterator.next() else {
      return XCTFail("expected tools/list_changed notification")
    }
    XCTAssertEqual(notification.method, "notifications/tools/list_changed")

    _ = try await client.listTools()
    let invalidatedCalls = await calls.current()
    XCTAssertEqual(invalidatedCalls, 2)
    await server.closeAllSubscriptions()
  }

  func testInflightListCannotResurrectCacheOrToolCatalogAfterNotification() async throws {
    let calls = RuntimeCounter()
    let server = try makeToolServer(calls: calls, listChanged: true)
    let cache = BlockingFirstInsertCache()
    let client = try client(
      transport: MCPInMemoryClientTransport(server: server),
      cache: cache
    )
    let subscription = try await client.listen(
      notifications: MCPSubscriptionFilter(toolsListChanged: true)
    )
    var iterator = subscription.events.makeAsyncIterator()
    guard case .acknowledged? = try await iterator.next() else {
      return XCTFail("expected subscription acknowledgement")
    }

    let inflightList = Task { try await client.listTools() }
    await cache.waitUntilInsertIsBlocked()
    try await server.notifyToolsChanged()
    guard case .notification? = try await iterator.next() else {
      return XCTFail("expected list-changed notification")
    }
    await cache.releaseInsert()
    await cache.waitUntilCleanupIsBlocked()

    do {
      _ = try await client.callTool(MCPCallToolParams(name: "echo", arguments: [:]))
      XCTFail("server must reject the invalid tool input")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("stale client tool catalog was resurrected: \(error)")
      }
      XCTAssertEqual(rpc.code, -32602)
    }

    let freshList = Task { try await client.listTools() }
    for _ in 0..<100 {
      if await calls.current() >= 2 { break }
      try await Task.sleep(for: .milliseconds(1))
    }
    let callsWhileCleanupBlocked = await calls.current()
    XCTAssertEqual(callsWhileCleanupBlocked, 2, "stale insert must not be readable during cleanup")
    await cache.releaseCleanup()
    _ = try await inflightList.value
    _ = try await freshList.value
    let finalCallCount = await calls.current()
    XCTAssertEqual(finalCallCount, 2)
    await server.closeAllSubscriptions()
  }

  func testToolCatalogIsClearedEvenWhenExternalCacheInvalidationFails() async throws {
    let calls = RuntimeCounter()
    let server = try makeToolServer(calls: calls, listChanged: true)
    let client = try client(
      transport: MCPInMemoryClientTransport(server: server),
      cache: FailingInvalidationCache()
    )
    _ = try await client.listTools()

    let subscription = try await client.listen(
      notifications: MCPSubscriptionFilter(toolsListChanged: true)
    )
    var iterator = subscription.events.makeAsyncIterator()
    guard case .acknowledged? = try await iterator.next() else {
      return XCTFail("expected subscription acknowledgement")
    }
    try await server.notifyToolsChanged()
    do {
      _ = try await iterator.next()
      XCTFail("the injected cache invalidation failure must end the subscription")
    } catch RuntimeCacheFailure.invalidationFailed {
      // The notification was accepted and internal authority must already be invalidated.
    }

    do {
      _ = try await client.callTool(MCPCallToolParams(name: "echo", arguments: [:]))
      XCTFail("server must reject the invalid tool input")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("stale client tool catalog survived cache failure: \(error)")
      }
      XCTAssertEqual(rpc.code, -32602)
    }

    _ = try await client.listTools()
    _ = try await client.listTools()
    let listCallCount = await calls.current()
    XCTAssertEqual(listCallCount, 3, "cache hits must stay disabled after invalidation failure")
    await server.closeAllSubscriptions()
  }

  func testPrivateCacheRequiresAuthorizationPartition() async throws {
    let calls = RuntimeCounter()
    let server = try makeToolServer(calls: calls, cacheScope: .private)
    let cache = try MCPMemoryCache()
    let withoutPartition = try client(
      transport: MCPInMemoryClientTransport(server: server),
      cache: cache
    )
    _ = try await withoutPartition.listTools()
    _ = try await withoutPartition.listTools()
    let uncachedCallCount = await calls.current()
    let uncachedEntryCount = await cache.count
    XCTAssertEqual(uncachedCallCount, 2)
    XCTAssertEqual(uncachedEntryCount, 0)

    let withPartition = try client(
      transport: MCPInMemoryClientTransport(server: server, endpointIdentity: "private"),
      cache: cache,
      partition: "subject:alice"
    )
    _ = try await withPartition.listTools()
    _ = try await withPartition.listTools()
    let cachedCallCount = await calls.current()
    let cachedEntryCount = await cache.count
    XCTAssertEqual(cachedCallCount, 3)
    XCTAssertEqual(cachedEntryCount, 1)
  }

  func testTimeoutCancelsRequestScopedExchange() async throws {
    let cancellations = RuntimeCapture<String?>()
    let client = try client(
      transport: NeverEndingTransport(cancellationReasons: cancellations),
      timeout: .milliseconds(30)
    )
    do {
      _ = try await client.discover()
      XCTFail("expected timeout")
    } catch let error as MCPClientError {
      guard case .timeout = error else { return XCTFail("unexpected error: \(error)") }
    }
    let reasons = await cancellations.snapshot().compactMap { $0 }
    XCTAssertEqual(reasons, ["request timed out"])
  }

  func testOpenTimeoutReturnsPromptlyAndCancelsLateExchange() async throws {
    let cancellations = RuntimeCapture<String?>()
    let client = try client(
      transport: CancellationInsensitiveOpenTransport(
        delay: 0.25,
        cancellationReasons: cancellations
      ),
      timeout: .milliseconds(20)
    )
    let started = ContinuousClock.now
    do {
      _ = try await client.discover()
      XCTFail("expected timeout")
    } catch let error as MCPClientError {
      guard case .timeout = error else { return XCTFail("unexpected error: \(error)") }
    }
    XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(100))
    try await Task.sleep(for: .milliseconds(300))
    let reasons = await cancellations.snapshot().compactMap { $0 }
    XCTAssertEqual(reasons, ["transport opened after request deadline"])
  }

  func testCancelledServerRequestFinishesWithoutAnyResponseFrame() async throws {
    let fixtureTool = try tool()
    var builder = try MCPServerBuilder(implementation: implementation("cancel-server"))
    builder.setToolResolver { name, _ in name == fixtureTool.name ? fixtureTool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      try await Task.sleep(for: .seconds(10))
      return MCPListToolsResult(tools: [fixtureTool])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }
    let server = try builder.build()
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("cancel-client")
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(99),
      method: "tools/list",
      params: metadata.inserting(into: MCPListToolsParams().json.objectValue ?? [:])
    )
    let exchange = server.execute(request)
    let collector = Task { () throws -> [MCPWireMessage] in
      var frames: [MCPWireMessage] = []
      for try await frame in exchange.frames { frames.append(frame) }
      return frames
    }

    try await Task.sleep(for: .milliseconds(20))
    await exchange.cancel(reason: "test cancellation")

    let collected = try await collector.value
    XCTAssertEqual(collected, [])
  }

  func testProtocolViolationCancelsExchangeInsteadOfLeakingIt() async throws {
    let cancellations = RuntimeCapture<String?>()
    let transport = ScriptedTransport(
      frames: { request in
        let result = MCPWireResult(
          id: request.id,
          value: MCPListToolsResult(tools: []).json.objectValue ?? [:]
        )
        let late = try MCPWireNotification(method: "notifications/tools/list_changed")
        return [.result(result), .notification(late)]
      },
      cancellationReasons: cancellations
    )
    let client = try client(transport: transport)
    do {
      _ = try await client.listTools()
      XCTFail("expected protocol violation")
    } catch let error as MCPClientError {
      guard case .protocolViolation = error else {
        return XCTFail("unexpected error: \(error)")
      }
    }
    let cancellationValues = await cancellations.snapshot().compactMap { $0 }
    XCTAssertEqual(cancellationValues, ["request failed"])
  }

  func testSubscriptionIsAcknowledgementFirstFilteredAndTerminal() async throws {
    let server = try makeToolServer(listChanged: true)
    let client = try client(transport: MCPInMemoryClientTransport(server: server))
    let requested = try MCPSubscriptionFilter(toolsListChanged: true)
    let subscription = try await client.listen(notifications: requested)

    let collector = Task { () throws -> [MCPClientSubscriptionEvent] in
      var events: [MCPClientSubscriptionEvent] = []
      for try await event in subscription.events { events.append(event) }
      return events
    }
    try await Task.sleep(for: .milliseconds(10))
    try await server.notifyToolsChanged()
    await server.closeAllSubscriptions()
    let events = try await collector.value

    XCTAssertEqual(events.count, 3)
    guard case .acknowledged(let accepted) = events[0] else {
      return XCTFail("first event must acknowledge")
    }
    XCTAssertEqual(accepted, requested)
    guard case .notification(let notification) = events[1] else {
      return XCTFail("second event must be notification")
    }
    XCTAssertEqual(notification.method, "notifications/tools/list_changed")
    let metadata = try MCPNotificationMetadata(json: notification.params["_meta"] ?? .null)
    XCTAssertEqual(metadata.subscriptionID, subscription.id)
    guard case .completed(let result) = events[2] else {
      return XCTFail("last event must complete")
    }
    XCTAssertEqual(result.subscriptionID, subscription.id)
  }

  func testIndependentSubscriptionsMayReuseTheSameRequestID() async throws {
    let server = try makeToolServer(listChanged: true)
    let filter = try MCPSubscriptionFilter(toolsListChanged: true)
    let params = MCPSubscriptionsListenParams(notifications: filter)
    let requestID = MCPRequestID(1)

    func request(for client: String) throws -> MCPWireRequest {
      let metadata = try MCPRequestMetadata(
        clientCapabilities: MCPClientCapabilities(),
        clientInfo: implementation(client)
      )
      return try MCPWireRequest(
        id: requestID,
        method: "subscriptions/listen",
        params: metadata.inserting(into: params.json.objectValue ?? [:])
      )
    }

    let first = server.execute(try request(for: "subscription-client-a"))
    let second = server.execute(try request(for: "subscription-client-b"))
    var firstIterator = first.frames.makeAsyncIterator()
    var secondIterator = second.frames.makeAsyncIterator()

    guard case .notification(let firstAcknowledgement)? = try await firstIterator.next(),
      case .notification(let secondAcknowledgement)? = try await secondIterator.next()
    else {
      return XCTFail("independent subscriptions must both acknowledge")
    }
    XCTAssertEqual(firstAcknowledgement.method, "notifications/subscriptions/acknowledged")
    XCTAssertEqual(secondAcknowledgement.method, "notifications/subscriptions/acknowledged")

    try await server.notifyToolsChanged()
    guard case .notification(let firstNotification)? = try await firstIterator.next(),
      case .notification(let secondNotification)? = try await secondIterator.next()
    else {
      return XCTFail("a change must fan out to both subscriptions")
    }
    for notification in [firstNotification, secondNotification] {
      let metadata = try MCPNotificationMetadata(json: notification.params["_meta"] ?? .null)
      XCTAssertEqual(notification.method, "notifications/tools/list_changed")
      XCTAssertEqual(metadata.subscriptionID, requestID)
    }

    await first.cancel(reason: "first subscriber disconnected")
    let firstEnd = try await firstIterator.next()
    XCTAssertNil(firstEnd)

    try await server.notifyToolsChanged()
    guard case .notification(let remainingNotification)? = try await secondIterator.next() else {
      return XCTFail("cancelling one subscription must not stop the other")
    }
    XCTAssertEqual(remainingNotification.method, "notifications/tools/list_changed")
    await second.cancel(reason: "test complete")
    let secondEnd = try await secondIterator.next()
    XCTAssertNil(secondEnd)
  }

  func testInMemoryTransportMapsServerSubscriptionCancellationToPeerError() async throws {
    let server = try makeToolServer(listChanged: true)
    let client = try client(transport: MCPInMemoryClientTransport(server: server))
    let subscription = try await client.listen(
      notifications: MCPSubscriptionFilter(toolsListChanged: true)
    )
    var iterator = subscription.events.makeAsyncIterator()
    guard case .acknowledged? = try await iterator.next() else {
      return XCTFail("in-memory subscription did not acknowledge")
    }

    await server.cancelAllSubscriptions(reason: "maintenance")
    do {
      _ = try await iterator.next()
      XCTFail("server cancellation must terminate the client event stream")
    } catch let error as MCPClientError {
      guard case .peerCancelled(let reason) = error else {
        return XCTFail("unexpected client error: \(error)")
      }
      XCTAssertEqual(reason, "maintenance")
    }
  }

  func testServerCancellationInterruptsSubscriptionWithoutTerminalResult() async throws {
    let server = try makeToolServer(listChanged: true)
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("subscription-cancel-client")
    )
    let requestID = MCPRequestID(404)
    let params = MCPSubscriptionsListenParams(
      notifications: try MCPSubscriptionFilter(toolsListChanged: true)
    )
    let request = try MCPWireRequest(
      id: requestID,
      method: "subscriptions/listen",
      params: metadata.inserting(into: params.json.objectValue ?? [:])
    )
    let exchange = server.execute(request)
    var iterator = exchange.frames.makeAsyncIterator()

    guard case .notification(let acknowledgement)? = try await iterator.next() else {
      return XCTFail("subscription must acknowledge before server cancellation")
    }
    XCTAssertEqual(acknowledgement.method, "notifications/subscriptions/acknowledged")

    await server.cancelAllSubscriptions(reason: "maintenance")
    do {
      _ = try await iterator.next()
      XCTFail("server cancellation must terminate the exchange without a result")
    } catch let cancellation as MCPServerSubscriptionCancellation {
      XCTAssertEqual(cancellation.requestID, requestID)
      XCTAssertEqual(cancellation.reason, "maintenance")
    }
  }

  func testExchangeCancelsExactlyOneSubscriptionWhenIDsOverlap() async throws {
    let server = try makeToolServer(listChanged: true)
    let filter = try MCPSubscriptionFilter(toolsListChanged: true)
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("single-subscription-cancel-client")
    )
    let params = MCPSubscriptionsListenParams(notifications: filter)

    func request() throws -> MCPWireRequest {
      try MCPWireRequest(
        id: MCPRequestID(17),
        method: "subscriptions/listen",
        params: metadata.inserting(into: params.json.objectValue ?? [:])
      )
    }

    let first = server.execute(try request())
    let second = server.execute(try request())
    var firstIterator = first.frames.makeAsyncIterator()
    var secondIterator = second.frames.makeAsyncIterator()
    guard case .notification? = try await firstIterator.next(),
      case .notification? = try await secondIterator.next()
    else {
      return XCTFail("both subscriptions must acknowledge")
    }

    await first.cancelSubscription(reason: "rotate first stream")
    do {
      _ = try await firstIterator.next()
      XCTFail("the cancelled exchange must terminate with a peer-visible cancellation")
    } catch let cancellation as MCPServerSubscriptionCancellation {
      XCTAssertEqual(cancellation.requestID, MCPRequestID(17))
      XCTAssertEqual(cancellation.reason, "rotate first stream")
    }

    try await server.notifyToolsChanged()
    guard case .notification? = try await secondIterator.next() else {
      return XCTFail("cancelling one same-ID subscription must preserve the other")
    }
    await second.cancel(reason: "test complete")
    _ = try? await secondIterator.next()
  }

  func testResourceUpdateSubscriptionInvalidatesOnlyTheMatchingResourceCache() async throws {
    let reads = RuntimeCounter()
    let firstURI = "memory://document/first"
    let secondURI = "memory://document/second"
    var builder = try MCPServerBuilder(implementation: implementation("resource-update-server"))
    try builder.register(MCPStandardMethods.listResources) { _, _ in
      MCPListResourcesResult(resources: [])
    }
    try builder.register(MCPStandardMethods.readResource) { params, _ in
      _ = await reads.increment()
      return try MCPReadResourceResult(
        contents: [MCPResourceContents(uri: params.uri, text: "current \(params.uri)")],
        cache: try MCPCachePolicy(ttlMilliseconds: 60_000, scope: .public)
      )
    }
    builder.enableResourceSubscriptions()
    let server = try builder.build()
    let cache = try MCPMemoryCache()
    let client = try client(
      transport: MCPInMemoryClientTransport(server: server),
      cache: cache
    )

    let first = try MCPReadResourceParams(uri: firstURI)
    let second = try MCPReadResourceParams(uri: secondURI)
    _ = try await client.readResource(first)
    _ = try await client.readResource(first)
    _ = try await client.readResource(second)
    _ = try await client.readResource(second)
    var observedReads = await reads.current()
    XCTAssertEqual(observedReads, 2, "each URI must have its own cached response")

    let subscription = try await client.listen(
      notifications: MCPSubscriptionFilter(resourceSubscriptions: [firstURI])
    )
    var iterator = subscription.events.makeAsyncIterator()
    guard case .acknowledged? = try await iterator.next() else {
      return XCTFail("expected a resource-update subscription acknowledgement")
    }
    try await server.notifyResourceUpdated(uri: firstURI)
    guard case .notification(let notification)? = try await iterator.next() else {
      return XCTFail("requested resource update must be delivered")
    }
    XCTAssertEqual(notification.method, "notifications/resources/updated")
    XCTAssertEqual(
      try MCPResourceUpdatedParams(json: .object(notification.params)).uri,
      firstURI
    )

    _ = try await client.readResource(first)
    observedReads = await reads.current()
    XCTAssertEqual(observedReads, 3, "the updated resource must be refetched")
    _ = try await client.readResource(second)
    observedReads = await reads.current()
    XCTAssertEqual(observedReads, 3, "an unupdated resource must remain cached")
    await server.closeAllSubscriptions()
  }

  func testResourceCacheInvalidationUsesSemanticURIWithoutReparsingParameters() async throws {
    let cache = try MCPMemoryCache()
    let entry = MCPCacheEntry(
      value: ["resultType": .string("complete")],
      scope: .public,
      expiresAt: .distantFuture
    )
    let first = MCPCacheKey(
      endpointIdentity: "endpoint",
      method: "resources/read",
      parameters: Data("not-json-a".utf8),
      clientCapabilities: Data(),
      semanticMetadata: Data(),
      authorizationPartition: nil,
      resourceURI: "file:///a"
    )
    let second = MCPCacheKey(
      endpointIdentity: "endpoint",
      method: "resources/read",
      parameters: Data("not-json-b".utf8),
      clientCapabilities: Data(),
      semanticMetadata: Data(),
      authorizationPartition: nil,
      resourceURI: "file:///b"
    )
    await cache.insert(entry, for: first)
    await cache.insert(entry, for: second)

    await cache.invalidate(.resource(uri: "file:///a"))

    let firstValue = await cache.value(for: first)
    let secondValue = await cache.value(for: second)
    XCTAssertNil(firstValue)
    XCTAssertNotNil(secondValue)
  }

}
