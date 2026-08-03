import Foundation
import XCTest

@testable import MCP

private actor SourceTranscript {
  private var remainingFrames: [[MCPWireMessage]]
  private var cancellationReasons: [String] = []

  init(frames: [[MCPWireMessage]]) {
    remainingFrames = frames
  }

  func frames(for request: MCPWireRequest) throws -> [MCPWireMessage] {
    guard !remainingFrames.isEmpty else {
      throw MCPClientError.transport("unexpected request \(request.method)")
    }
    return remainingFrames.removeFirst()
  }

  func cancelled(reason: String?) {
    cancellationReasons.append(reason ?? "")
  }

  func cancellations() -> [String] { cancellationReasons }
}

private struct SourceTranscriptTransport: MCPClientTransport {
  let endpointIdentity = "source-lines"
  let transcript: SourceTranscript

  func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    let frames = try await transcript.frames(for: request)
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream()
    for frame in frames { pair.continuation.yield(frame) }
    pair.continuation.finish()
    return MCPClientExchange(
      frames: pair.stream,
      cancel: { reason in await transcript.cancelled(reason: reason) }
    )
  }
}

private final class SourceClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(_ value: Date) {
    self.value = value
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance(by interval: TimeInterval) {
    lock.lock()
    value.addTimeInterval(interval)
    lock.unlock()
  }
}

private actor SourceProgressCapture {
  private var values: [String] = []

  func append(_ value: MCPJSONNumber) {
    values.append(value.rawValue)
  }

  func snapshot() -> [String] { values }
}

final class MCPSourceLineBehaviorTests: XCTestCase {
  private func client(
    transcript: SourceTranscript,
    startingRequestID: Int64 = 1
  ) throws -> MCPClient {
    try MCPClient(
      transport: SourceTranscriptTransport(transcript: transcript),
      configuration: MCPClientConfiguration(
        implementation: try MCPImplementation(name: "source-client", version: "1.0"),
        capabilities: MCPClientCapabilities(),
        requestTimeout: nil
      ),
      startingRequestID: startingRequestID
    )
  }

  private func key(
    endpoint: String = "one",
    method: String,
    resourceURI: String? = nil
  ) -> MCPCacheKey {
    MCPCacheKey(
      endpointIdentity: endpoint,
      method: method,
      parameters: Data(method.utf8),
      clientCapabilities: Data(),
      semanticMetadata: Data(),
      authorizationPartition: nil,
      resourceURI: resourceURI
    )
  }

  private func entry(expiresAt: Date) -> MCPCacheEntry {
    MCPCacheEntry(
      value: ["resultType": .string("complete")],
      scope: .public,
      expiresAt: expiresAt
    )
  }

  func testRepeatedProgressValueIsRejectedAndCancelsTheExchange() async throws {
    let first = try MCPProgressParams(
      progressToken: MCPProgressToken(1), progress: MCPJSONNumber(0.5), total: MCPJSONNumber(1)
    )
    let second = try MCPProgressParams(
      progressToken: MCPProgressToken(1), progress: MCPJSONNumber(0.5), total: MCPJSONNumber(1)
    )
    let result = try MCPCallToolResult(content: [])
    let transcript = SourceTranscript(frames: [
      [
        .notification(
          try MCPWireNotification(
            method: "notifications/progress", params: first.json.objectValue ?? [:]
          )),
        .notification(
          try MCPWireNotification(
            method: "notifications/progress", params: second.json.objectValue ?? [:]
          )),
        .result(MCPWireResult(id: MCPRequestID(1), value: result.json.objectValue ?? [:])),
      ]
    ])

    do {
      _ = try await client(transcript: transcript).callTool(
        try MCPCallToolParams(name: "work"),
        progress: { _ in }
      )
      XCTFail("equal progress values must be rejected")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("progress"))
    }
    let cancellations = await transcript.cancellations()
    XCTAssertEqual(cancellations, ["request failed"])
  }

  func testClientAcceptsExactProgressBeyondDoublePrecision() async throws {
    let rawProgress = ["9007199254740992", "9007199254740993", "1e400"]
    let notifications = try rawProgress.map { raw -> MCPWireMessage in
      let params = try MCPProgressParams(
        progressToken: MCPProgressToken(1),
        progress: MCPJSONNumber(rawValue: raw)
      )
      return .notification(
        try MCPWireNotification(
          method: "notifications/progress",
          params: params.json.objectValue ?? [:]
        ))
    }
    let result = try MCPCallToolResult(content: [])
    let transcript = SourceTranscript(frames: [
      notifications + [
        .result(MCPWireResult(id: MCPRequestID(1), value: result.json.objectValue ?? [:]))
      ]
    ])
    let capture = SourceProgressCapture()

    _ = try await client(transcript: transcript).callTool(
      try MCPCallToolParams(name: "work"),
      progress: { value in await capture.append(value.progress) }
    )

    let received = await capture.snapshot()
    XCTAssertEqual(received, rawProgress)
    let cancellations = await transcript.cancellations()
    XCTAssertTrue(cancellations.isEmpty)
  }

  func testServerAcceptsExactProgressBeyondDoublePrecision() async throws {
    let rawProgress = ["9007199254740992", "9007199254740993", "1e400"]
    let exactProgress = try rawProgress.map(MCPJSONNumber.init(rawValue:))
    let tool = try MCPTool(name: "work", inputSchema: ["type": .string("object")])
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "exact-progress-server", version: "1.0")
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [tool]) }
    try builder.register(MCPStandardMethods.callTool) { _, context in
      for progress in exactProgress {
        try await context.progress?.report(progress: progress)
      }
      return try MCPCallToolResult(content: [])
    }
    let server = try builder.build()
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      progressToken: MCPProgressToken(52)
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(52),
      method: "tools/call",
      params: metadata.inserting(into: try MCPCallToolParams(name: "work").json.objectValue ?? [:])
    )

    var frames: [MCPWireMessage] = []
    for try await frame in server.execute(request).frames { frames.append(frame) }

    let received = try frames.compactMap { frame -> String? in
      guard case .notification(let notification) = frame else { return nil }
      return try MCPProgressParams(json: .object(notification.params)).progress.rawValue
    }
    XCTAssertEqual(received, rawProgress)
    guard case .result? = frames.last else {
      return XCTFail("expected terminal success after exact progress notifications")
    }
  }

  func testProgressOverflowDropsUpdatesButPreservesTerminalResult() async throws {
    let tool = try MCPTool(name: "work", inputSchema: ["type": .string("object")])
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "bounded-progress-server", version: "1.0"),
      configuration: MCPServerConfiguration(subscriptionBufferLimit: 1)
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [tool]) }
    try builder.register(MCPStandardMethods.callTool) { _, context in
      try await context.progress?.report(progress: 1)
      try await context.progress?.report(progress: 2)
      return try MCPCallToolResult(content: [])
    }
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(), progressToken: MCPProgressToken(53)
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(53),
      method: "tools/call",
      params: metadata.inserting(
        into: try MCPCallToolParams(name: tool.name).json.objectValue ?? [:]
      )
    )
    let exchange = try builder.build().execute(request)

    // The handler completes before consumption, forcing the one-element progress buffer to drop.
    try await Task.sleep(for: .milliseconds(50))
    var frames: [MCPWireMessage] = []
    for try await frame in exchange.frames { frames.append(frame) }

    XCTAssertEqual(frames.count, 1)
    guard case .result? = frames.last else {
      return XCTFail("dropped progress must not replace the terminal result with an internal error")
    }
  }

  func testDecreasingExactProgressIsRejectedByClientAndServer() async throws {
    let high = try MCPJSONNumber(rawValue: "9007199254740993")
    let low = try MCPJSONNumber(rawValue: "9007199254740992")
    let first = try MCPProgressParams(progressToken: MCPProgressToken(61), progress: high)
    let second = try MCPProgressParams(progressToken: MCPProgressToken(61), progress: low)
    let transcript = SourceTranscript(frames: [
      [
        .notification(
          try MCPWireNotification(
            method: "notifications/progress", params: first.json.objectValue ?? [:]
          )),
        .notification(
          try MCPWireNotification(
            method: "notifications/progress", params: second.json.objectValue ?? [:]
          )),
      ]
    ])

    do {
      _ = try await client(transcript: transcript, startingRequestID: 61).callTool(
        try MCPCallToolParams(name: "work"), progress: { _ in }
      )
      XCTFail("decreasing client progress must be rejected")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected client error: \(error)")
      }
      XCTAssertTrue(reason.contains("strictly increase"))
    }

    let tool = try MCPTool(name: "work", inputSchema: ["type": .string("object")])
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "decreasing-progress-server", version: "1.0")
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [tool]) }
    try builder.register(MCPStandardMethods.callTool) { _, context in
      try await context.progress?.report(progress: high)
      try await context.progress?.report(progress: low)
      return try MCPCallToolResult(content: [])
    }
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      progressToken: MCPProgressToken(62)
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(62),
      method: "tools/call",
      params: metadata.inserting(into: try MCPCallToolParams(name: "work").json.objectValue ?? [:])
    )
    let server = try builder.build()
    var frames: [MCPWireMessage] = []
    for try await frame in server.execute(request).frames { frames.append(frame) }
    XCTAssertEqual(frames.count, 2)
    guard case .error(let terminal)? = frames.last else {
      return XCTFail("expected decreasing server progress to terminate with an error")
    }
    XCTAssertEqual(terminal.error, .internalError)
  }

  func testServerRejectsRepeatedProgressValueBeforeSendingItsTerminalResult() async throws {
    let tool = try MCPTool(name: "work", inputSchema: ["type": .string("object")])
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "progress-server", version: "1.0")
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [tool]) }
    try builder.register(MCPStandardMethods.callTool) { _, context in
      try await context.progress?.report(progress: 0.5, total: 1)
      try await context.progress?.report(progress: 0.5, total: 1)
      return try MCPCallToolResult(content: [])
    }
    let server = try builder.build()
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      progressToken: MCPProgressToken(42)
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(42),
      method: "tools/call",
      params: metadata.inserting(into: try MCPCallToolParams(name: "work").json.objectValue ?? [:])
    )

    var frames: [MCPWireMessage] = []
    for try await frame in server.execute(request).frames { frames.append(frame) }

    XCTAssertEqual(frames.count, 2)
    guard case .notification(let first)? = frames.first else {
      return XCTFail("expected first progress notification")
    }
    XCTAssertEqual(first.method, "notifications/progress")
    guard case .error(let terminal)? = frames.last else {
      return XCTFail("expected server-side progress validation error")
    }
    XCTAssertEqual(terminal.error, .internalError)
  }

  func testUnknownToolIsARequestErrorBeforeItsHandlerRuns() async throws {
    let known = try MCPTool(name: "known", inputSchema: ["type": .string("object")])
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "unknown-tool-server", version: "1.0")
    )
    builder.setToolResolver { name, _ in name == known.name ? known : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [known])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      XCTFail("the unknown tool must not reach the call handler")
      return try MCPCallToolResult(content: [])
    }
    let client = try MCPClient(
      transport: MCPInMemoryClientTransport(server: builder.build()),
      configuration: MCPClientConfiguration(
        implementation: try MCPImplementation(name: "unknown-tool-client", version: "1.0"),
        capabilities: MCPClientCapabilities(),
        requestTimeout: nil
      )
    )

    do {
      _ = try await client.callTool(try MCPCallToolParams(name: "missing"))
      XCTFail("unknown tool must return invalid params")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(rpc.code, -32602)
      XCTAssertEqual(rpc.message, "Unknown tool")
      XCTAssertEqual(rpc.data, .object(["name": .string("missing")]))
    }
  }

  func testUnknownPromptAndResourcePropagateInvalidParamsFromAuthoritativeHandlers() async throws {
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "catalog-server", version: "1.0")
    )
    try builder.register(MCPStandardMethods.listPrompts) { _, _ in MCPListPromptsResult(prompts: [])
    }
    try builder.register(MCPStandardMethods.getPrompt) { params, _ in
      throw MCPRPCError(
        code: -32602,
        message: "Unknown prompt",
        data: .object(["name": .string(params.name)])
      )
    }
    try builder.register(MCPStandardMethods.listResources) { _, _ in
      MCPListResourcesResult(resources: [])
    }
    try builder.register(MCPStandardMethods.readResource) { params, _ in
      throw MCPRPCError(
        code: -32602,
        message: "Resource not found",
        data: .object(["uri": .string(params.uri)])
      )
    }
    let client = try MCPClient(
      transport: MCPInMemoryClientTransport(server: builder.build()),
      configuration: MCPClientConfiguration(
        implementation: try MCPImplementation(name: "catalog-client", version: "1.0"),
        capabilities: MCPClientCapabilities(),
        requestTimeout: nil
      )
    )

    do {
      _ = try await client.getPrompt(try MCPGetPromptParams(name: "missing-prompt"))
      XCTFail("unknown prompt must return invalid params")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(rpc.code, -32602)
      XCTAssertEqual(rpc.data, .object(["name": .string("missing-prompt")]))
    }

    do {
      _ = try await client.readResource(try MCPReadResourceParams(uri: "file:///missing"))
      XCTFail("unknown resource must return invalid params")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(rpc.code, -32602)
      XCTAssertEqual(rpc.data, .object(["uri": .string("file:///missing")]))
    }
  }

  func testInputRequiredResultNamesTheMissingClientCapability() async throws {
    let tool = try MCPTool(name: "needs-confirmation", inputSchema: ["type": .string("object")])
    let request = MCPElicitationRequest(
      params: try MCPElicitationParams(
        mode: .form,
        message: "Confirm",
        requestedSchema: [
          "type": .string("object"),
          "properties": .object(["ok": .object(["type": .string("boolean")])]),
        ]
      )
    )
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "elicitation-server", version: "1.0")
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [tool]) }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(
        resultType: .inputRequired,
        inputRequests: ["confirm": request],
        requestState: "confirmation-1"
      )
    }
    let client = try MCPClient(
      transport: MCPInMemoryClientTransport(server: builder.build()),
      configuration: MCPClientConfiguration(
        implementation: try MCPImplementation(name: "no-elicitation-client", version: "1.0"),
        capabilities: MCPClientCapabilities(),
        requestTimeout: nil
      )
    )

    do {
      _ = try await client.callTool(try MCPCallToolParams(name: "needs-confirmation"))
      XCTFail("missing elicitation capability must be explicit")
    } catch let error as MCPClientError {
      guard case .rpc(let rpc) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertEqual(rpc.code, -32021)
      guard case .object(let data)? = rpc.data else {
        return XCTFail("missing requiredCapabilities data")
      }
      let capabilities = try MCPClientCapabilities(
        json: data["requiredCapabilities"] ?? .null
      )
      XCTAssertEqual(capabilities.elicitation?.form, true)
      XCTAssertEqual(capabilities.elicitation?.url, false)
    }
  }

  func testSubscriptionRejectsAcknowledgementsThatAreNotFirstOrNotCorrelated() async throws {
    let requested = try MCPSubscriptionFilter(toolsListChanged: true)
    let wrongID = try MCPSubscriptionsAcknowledgedParams(
      notifications: requested,
      subscriptionID: MCPRequestID(101)
    )
    let transcript = SourceTranscript(frames: [
      [
        .notification(
          try MCPWireNotification(
            method: "notifications/subscriptions/acknowledged",
            params: wrongID.json.objectValue ?? [:]
          ))
      ]
    ])

    do {
      _ = try await client(transcript: transcript, startingRequestID: 100).listen(
        notifications: requested
      )
      XCTFail("acknowledgement must use the subscription request id")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("acknowledgement id"))
    }

    let notificationBeforeAcknowledgement = SourceTranscript(frames: [
      [
        .notification(
          try MCPWireNotification(method: "notifications/tools/list_changed")
        )
      ]
    ])
    do {
      _ = try await client(transcript: notificationBeforeAcknowledgement, startingRequestID: 102)
        .listen(notifications: requested)
      XCTFail("the acknowledgement must be the first subscription frame")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("first frame"))
    }
  }

  func testSubscriptionRejectsUnrequestedNotificationsAfterAcknowledgement() async throws {
    let requested = try MCPSubscriptionFilter(toolsListChanged: true)
    let acknowledgement = try MCPSubscriptionsAcknowledgedParams(
      notifications: requested,
      subscriptionID: MCPRequestID(110)
    )
    let metadata = try MCPNotificationMetadata(subscriptionID: MCPRequestID(110))
    let transcript = SourceTranscript(frames: [
      [
        .notification(
          try MCPWireNotification(
            method: "notifications/subscriptions/acknowledged",
            params: acknowledgement.json.objectValue ?? [:]
          )),
        .notification(
          try MCPWireNotification(
            method: "notifications/prompts/list_changed",
            params: ["_meta": metadata.json]
          )),
      ]
    ])

    let subscription = try await client(transcript: transcript, startingRequestID: 110).listen(
      notifications: requested
    )
    var events = subscription.events.makeAsyncIterator()
    let acknowledgementEvent = try await events.next()
    XCTAssertEqual(acknowledgementEvent, .acknowledged(requested))
    do {
      _ = try await events.next()
      XCTFail("notifications outside the accepted filter must be rejected")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("unrequested prompts/list_changed"))
    }
  }

  func testSubscriptionRejectsCancellationForAnotherRequestID() async throws {
    let requested = try MCPSubscriptionFilter(toolsListChanged: true)
    let acknowledgement = try MCPSubscriptionsAcknowledgedParams(
      notifications: requested,
      subscriptionID: MCPRequestID(120)
    )
    let cancellation = MCPCancelledParams(requestID: MCPRequestID(121), reason: "maintenance")
    let transcript = SourceTranscript(frames: [
      [
        .notification(
          try MCPWireNotification(
            method: "notifications/subscriptions/acknowledged",
            params: acknowledgement.json.objectValue ?? [:]
          )),
        .notification(
          try MCPWireNotification(
            method: "notifications/cancelled",
            params: cancellation.json.objectValue ?? [:]
          )),
      ]
    ])

    let subscription = try await client(transcript: transcript, startingRequestID: 120).listen(
      notifications: requested
    )
    var events = subscription.events.makeAsyncIterator()
    let acknowledgementEvent = try await events.next()
    XCTAssertEqual(acknowledgementEvent, .acknowledged(requested))
    do {
      _ = try await events.next()
      XCTFail("cancellation for another request must be rejected")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("cancellation id"))
    }
  }

  func testToolsListExcludesOnlyToolsWhoseSchemasCannotBeSafelyCompiled() async throws {
    let rejected = try MCPTool(
      name: "unsafe-pattern",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "value": .object([
            "type": .string("string"),
            "pattern": .string("^(a+)+$"),
          ])
        ]),
      ]
    )
    let accepted = try MCPTool(
      name: "safe-pattern",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "value": .object([
            "type": .string("string"),
            "pattern": .string("^([A-Za-z0-9]|-)*$"),
          ])
        ]),
      ]
    )
    let listing = MCPListToolsResult(tools: [rejected, accepted], nextCursor: "next-page")
    let transcript = SourceTranscript(frames: [
      [
        .result(MCPWireResult(id: MCPRequestID(1), value: listing.json.objectValue ?? [:]))
      ]
    ])

    let response = try await client(transcript: transcript).listTools()

    XCTAssertEqual(response.tools.map(\.name), ["safe-pattern"])
    XCTAssertEqual(response.nextCursor, "next-page")
  }

  func testToolsListCanReturnAnEmptyPageWhenEveryToolIsRejected() async throws {
    let rejected = try MCPTool(
      name: "unsafe-pattern",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "value": .object([
            "type": .string("string"),
            "pattern": .string("^(a+)+$"),
          ])
        ]),
      ]
    )
    let listing = MCPListToolsResult(tools: [rejected], nextCursor: "next-page")
    let transcript = SourceTranscript(frames: [
      [
        .result(MCPWireResult(id: MCPRequestID(1), value: listing.json.objectValue ?? [:]))
      ]
    ])

    let response = try await client(transcript: transcript).listTools()

    XCTAssertTrue(response.tools.isEmpty)
    XCTAssertEqual(response.nextCursor, "next-page")
  }

  func testOrdinaryExchangeRejectsServerOriginatedRequests() async throws {
    let serverRequest = try MCPWireRequest(
      id: MCPRequestID(900),
      method: "tools/list",
      params: [:]
    )
    let transcript = SourceTranscript(frames: [[.request(serverRequest)]])

    do {
      _ = try await client(transcript: transcript).listTools()
      XCTFail("strict clients must reject server-originated requests")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("server-originated requests"))
    }
    let cancellations = await transcript.cancellations()
    XCTAssertEqual(cancellations, ["request failed"])
  }

  func testOrdinaryExchangeRejectsMismatchedAndPostTerminalResults() async throws {
    let result = MCPListToolsResult(tools: [])
    let wrongTerminal = SourceTranscript(frames: [
      [
        .result(
          MCPWireResult(id: MCPRequestID(131), value: result.json.objectValue ?? [:])
        )
      ]
    ])

    do {
      _ = try await client(transcript: wrongTerminal, startingRequestID: 130).listTools()
      XCTFail("terminal results must use the request id")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("terminal result id"))
    }
    let wrongIDCancels = await wrongTerminal.cancellations()
    XCTAssertEqual(wrongIDCancels, ["request failed"])

    let afterTerminal = SourceTranscript(frames: [
      [
        .result(
          MCPWireResult(id: MCPRequestID(140), value: result.json.objectValue ?? [:])
        ),
        .notification(try MCPWireNotification(method: "notifications/progress")),
      ]
    ])
    do {
      _ = try await client(transcript: afterTerminal, startingRequestID: 140).listTools()
      XCTFail("frames after a terminal result must be rejected")
    } catch let error as MCPClientError {
      guard case .protocolViolation(let reason) = error else {
        return XCTFail("unexpected error: \(error)")
      }
      XCTAssertTrue(reason.contains("after terminal response"))
    }
    let postTerminalCancels = await afterTerminal.cancellations()
    XCTAssertEqual(postTerminalCancels, ["request failed"])
  }

  func testMemoryCacheExpiresAndInvalidatesOnlyItsDeclaredScope() async throws {
    let clock = SourceClock(Date(timeIntervalSinceReferenceDate: 1_000))
    let cache = try MCPMemoryCache(now: { clock.now() })
    let live = entry(expiresAt: clock.now().addingTimeInterval(10))
    let expired = entry(expiresAt: clock.now())
    let tools = key(method: "tools/list")
    let prompts = key(method: "prompts/list")
    let resourceList = key(method: "resources/list")
    let templates = key(method: "resources/templates/list")
    let resourceA = key(method: "resources/read", resourceURI: "file:///a")
    let resourceB = key(method: "resources/read", resourceURI: "file:///b")
    let otherEndpoint = key(endpoint: "two", method: "server/discover")

    await cache.insert(expired, for: tools)
    let discardedExpiredEntry = await cache.value(for: tools)
    XCTAssertNil(discardedExpiredEntry)

    for cacheKey in [tools, prompts, resourceList, templates, resourceA, resourceB, otherEndpoint] {
      await cache.insert(live, for: cacheKey)
    }
    await cache.invalidate(.tools)
    let removedTools = await cache.value(for: tools)
    let retainedPrompts = await cache.value(for: prompts)
    XCTAssertNil(removedTools)
    XCTAssertNotNil(retainedPrompts)

    await cache.invalidate(.prompts)
    let removedPrompts = await cache.value(for: prompts)
    XCTAssertNil(removedPrompts)
    await cache.invalidate(.resources)
    let removedResourceList = await cache.value(for: resourceList)
    let removedTemplates = await cache.value(for: templates)
    let retainedResource = await cache.value(for: resourceA)
    XCTAssertNil(removedResourceList)
    XCTAssertNil(removedTemplates)
    XCTAssertNotNil(retainedResource)

    await cache.invalidate(.resource(uri: "file:///a"))
    let removedResourceA = await cache.value(for: resourceA)
    let retainedResourceB = await cache.value(for: resourceB)
    XCTAssertNil(removedResourceA)
    XCTAssertNotNil(retainedResourceB)
    await cache.invalidate(.endpoint("two"))
    let removedEndpoint = await cache.value(for: otherEndpoint)
    XCTAssertNil(removedEndpoint)

    clock.advance(by: 11)
    let expiredResourceB = await cache.value(for: resourceB)
    XCTAssertNil(expiredResourceB)
    let future = entry(expiresAt: clock.now().addingTimeInterval(10))
    await cache.insert(future, for: resourceB)
    let insertedBeforeAll = await cache.value(for: resourceB)
    XCTAssertNotNil(insertedBeforeAll)
    await cache.invalidate(.all)
    let removedAll = await cache.value(for: resourceB)
    XCTAssertNil(removedAll)
  }

  func testMemoryCacheRejectsNonPositiveBoundWithoutTrapping() throws {
    XCTAssertThrowsError(try MCPMemoryCache(maximumEntries: 0))
    XCTAssertThrowsError(try MCPMemoryCache(maximumEntries: -1))
    XCTAssertNoThrow(try MCPMemoryCache(maximumEntries: 1))
  }

  func testMemoryCacheBoundsEntriesAndEvictsLeastRecentlyUsed() async throws {
    let clock = SourceClock(Date(timeIntervalSinceReferenceDate: 2_000))
    let cache = try MCPMemoryCache(maximumEntries: 2, now: { clock.now() })
    let first = key(method: "tools/list")
    let second = key(method: "prompts/list")
    let third = key(method: "resources/list")
    let live = entry(expiresAt: clock.now().addingTimeInterval(10))

    await cache.insert(live, for: first)
    await cache.insert(live, for: second)
    _ = await cache.value(for: first)
    await cache.insert(live, for: third)

    let retainedFirst = await cache.value(for: first)
    let evictedSecond = await cache.value(for: second)
    let retainedThird = await cache.value(for: third)
    let boundedCount = await cache.count
    XCTAssertNotNil(retainedFirst)
    XCTAssertNil(evictedSecond)
    XCTAssertNotNil(retainedThird)
    XCTAssertEqual(boundedCount, 2)

    clock.advance(by: 11)
    let replacement = key(method: "server/discover")
    await cache.insert(
      entry(expiresAt: clock.now().addingTimeInterval(10)),
      for: replacement
    )
    let prunedCount = await cache.count
    XCTAssertEqual(prunedCount, 1)
  }

  func testMRTRAndSubscriptionReducersRejectImpossibleStateTransitions() throws {
    let initial = MCPMRTRState.ready(round: 0, totalInputRequests: 0)
    let collecting = try MCPMRTRReducer.reduce(
      state: initial,
      event: .inputRequired(requestKeys: ["confirm"], requestState: "state")
    )
    XCTAssertEqual(collecting.1, [.collectInput(keys: ["confirm"])])
    let retrying = try MCPMRTRReducer.reduce(state: collecting.0, event: .inputCollected(count: 1))
    XCTAssertEqual(retrying.1, [.issueRetry])
    let ready = try MCPMRTRReducer.reduce(state: retrying.0, event: .retryIssued)
    let completed = try MCPMRTRReducer.reduce(state: ready.0, event: .completed)
    XCTAssertEqual(completed.1, [.finish])

    let emptyRound = try MCPMRTRReducer.reduce(
      state: initial,
      event: .inputRequired(requestKeys: [], requestState: "retry-without-input")
    )
    XCTAssertEqual(emptyRound.1, [.delayBeforeRetry, .issueRetry])
    XCTAssertNoThrow(try MCPMRTRReducer.reduce(state: emptyRound.0, event: .retryIssued))
    XCTAssertThrowsError(
      try MCPMRTRReducer.reduce(state: collecting.0, event: .inputCollected(count: 0))
    ) { error in
      XCTAssertEqual(error as? MCPMRTRReducerError, .invalidInputCount)
    }
    XCTAssertThrowsError(try MCPMRTRReducer.reduce(state: completed.0, event: .completed))

    let requested = try MCPSubscriptionFilter(toolsListChanged: true)
    XCTAssertThrowsError(
      try MCPSubscriptionReducer.reduce(
        state: .opening(requested: requested), event: .beginListening)
    ) { error in
      XCTAssertEqual(error as? MCPSubscriptionReducerError, .invalidTransition)
    }
    let accepted = try MCPSubscriptionReducer.reduce(
      state: .opening(requested: requested), event: .acknowledge(requested)
    )
    let listening = try MCPSubscriptionReducer.reduce(state: accepted.0, event: .beginListening)
    let interrupted = try MCPSubscriptionReducer.reduce(
      state: listening.0, event: .serverCancel("maintenance")
    )
    XCTAssertEqual(interrupted.0, .interrupted(reason: "maintenance", notificationCount: 0))
  }

  func testMRTRPolicyRejectsUnsafeLimitsBeforeAnyRequestCanStart() {
    XCTAssertThrowsError(try MCPMRTRPolicy(maximumRoundTrips: 0))
    XCTAssertThrowsError(try MCPMRTRPolicy(maximumInputRequestsPerRound: 0))
    XCTAssertThrowsError(
      try MCPMRTRPolicy(maximumInputRequestsPerRound: 2, maximumTotalInputRequests: 1)
    )
    XCTAssertThrowsError(try MCPMRTRPolicy(maximumRequestStateBytes: 0))
    XCTAssertThrowsError(try MCPMRTRPolicy(retryDelay: .milliseconds(-1)))
  }
}
