@preconcurrency import Foundation
import XCTest

@testable import MCP
@testable import MCPStdioClient
@testable import MCPStdioServer
@testable import MCPStdioShared

private actor StdioProgressCapture {
  private var values: [Double] = []
  func append(_ value: Double) { values.append(value) }
  func snapshot() -> [Double] { values }
}

final class MCPStdioTests: XCTestCase {
  private func implementation(_ name: String) throws -> MCPImplementation {
    try MCPImplementation(name: name, version: "1.0.0")
  }

  private func conformanceServerURL() throws -> URL {
    if let configured = ProcessInfo.processInfo.environment["MCP_CONFORMANCE_SERVER_PATH"] {
      let url = URL(fileURLWithPath: configured)
      guard FileManager.default.isExecutableFile(atPath: url.path) else {
        throw XCTSkip("MCP_CONFORMANCE_SERVER_PATH is not executable")
      }
      return url
    }
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let direct = root.appendingPathComponent(".build/debug/mcp-conformance-server")
    guard FileManager.default.isExecutableFile(atPath: direct.path) else {
      throw XCTSkip("run swift build before tests to build mcp-conformance-server")
    }
    return direct
  }

  private func makeClient(
    executable: URL,
    arguments: [String] = [],
    timeout: Duration = .seconds(5)
  ) throws -> (MCPClient, MCPStdioClientTransport) {
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: executable,
        arguments: arguments
      ))
    let client = try MCPClient(
      transport: transport,
      configuration: MCPClientConfiguration(
        implementation: implementation("stdio-test-client"),
        capabilities: MCPClientCapabilities(),
        requestTimeout: timeout
      )
    )
    return (client, transport)
  }

  func testStdioTransportOwnsJSONDecodeLimits() throws {
    let limits = try MCPStdioLimits(
      jsonLimits: MCPJSONLimits(maximumNumberBytes: 1)
    )
    XCTAssertEqual(limits.jsonLimits.maximumNumberBytes, 1)
    XCTAssertThrowsError(
      try MCPStdioLimits(jsonLimits: MCPJSONLimits(maximumDocumentBytes: 0))
    )
  }

  func testLineFramerHandlesFragmentationCRLFMultipleFramesAndLimits() throws {
    var framer = try MCPStdioLineFramer(maximumFrameBytes: 8)
    XCTAssertEqual(try framer.append(Data("a".utf8)), [])
    XCTAssertEqual(
      try framer.append(Data("\r\nb\nc\n".utf8)),
      [
        Data("a".utf8), Data("b".utf8), Data("c".utf8),
      ])
    XCTAssertNoThrow(try framer.finish())

    var multiple = try MCPStdioLineFramer(maximumFrameBytes: 2)
    XCTAssertEqual(try multiple.append(Data("a\nb\nc\n".utf8)).count, 3)

    var oversized = try MCPStdioLineFramer(maximumFrameBytes: 3)
    XCTAssertThrowsError(try oversized.append(Data("1234".utf8))) { error in
      XCTAssertEqual(error as? MCPStdioError, .lineTooLarge(limit: 3))
    }

    var embeddedCR = try MCPStdioLineFramer(maximumFrameBytes: 16)
    XCTAssertThrowsError(try embeddedCR.append(Data("a\rb\n".utf8))) { error in
      XCTAssertEqual(error as? MCPStdioError, .embeddedNewline)
    }

    var truncated = try MCPStdioLineFramer(maximumFrameBytes: 16)
    _ = try truncated.append(Data("{}".utf8))
    XCTAssertThrowsError(try truncated.finish()) { error in
      XCTAssertEqual(error as? MCPStdioError, .truncatedFrame)
    }
  }

  func testWriterProducesExactlyOneNewlineDelimitedFrame() async throws {
    let pipe = Pipe()
    let writer = MCPStdioWriter(handle: pipe.fileHandleForWriting)
    try await writer.writeFrame(Data("{}".utf8))
    try await writer.close()
    XCTAssertEqual(pipe.fileHandleForReading.readDataToEndOfFile(), Data("{}\n".utf8))

    let invalidPipe = Pipe()
    let invalidWriter = MCPStdioWriter(handle: invalidPipe.fileHandleForWriting)
    do {
      try await invalidWriter.writeFrame(Data("a\nb".utf8))
      XCTFail("expected embedded newline rejection")
    } catch let error as MCPStdioError {
      XCTAssertEqual(error, .embeddedNewline)
    }
    try await invalidWriter.close()
  }

  func testRealChildProcessDiscoveryListCallAndProgressRouting() async throws {
    let (client, transport) = try makeClient(executable: conformanceServerURL())
    defer { Task { await transport.shutdown() } }

    let discovery = try await client.discover()
    XCTAssertEqual(discovery.supportedVersions, [MCPProtocolVersion.current.rawValue])
    let listed = try await client.listTools()
    let toolNames = Set(listed.tools.map(\.name))
    XCTAssertTrue(toolNames.contains("echo"))
    XCTAssertTrue(toolNames.contains("wait"))

    let progress = StdioProgressCapture()
    let result = try await client.callTool(
      MCPCallToolParams(name: "echo", arguments: ["text": .string("stdio")]),
      progress: { update in
        if let value = update.progress.doubleValue { await progress.append(value) }
      }
    )
    XCTAssertFalse(result.isError)
    let progressValues = await progress.snapshot()
    XCTAssertEqual(progressValues, [0.5, 1])
  }

  func testTimedOutRequestIsCancelledWithoutKillingReusableProcess() async throws {
    let (client, transport) = try makeClient(
      executable: conformanceServerURL(), timeout: .milliseconds(500))
    defer { Task { await transport.shutdown() } }

    _ = try await client.discover()
    do {
      _ = try await client.callTool(MCPCallToolParams(name: "wait"))
      XCTFail("expected timeout")
    } catch let error as MCPClientError {
      guard case .timeout = error else { return XCTFail("unexpected error \(error)") }
    }

    let listed = try await client.listTools()
    XCTAssertTrue(listed.tools.contains { $0.name == "echo" })
  }

  /// A rejected frame is one client mistake on a long-lived channel. The server must answer or
  /// log it and keep serving; ending the channel would take down every other request the peer has
  /// in flight.
  func testStdioServerRejectsBadFramesWithoutEndingTheChannel() async throws {
    var builder = try MCPServerBuilder(implementation: implementation("stdio-recovery-server"))
    let tool = try MCPTool(name: "noop", inputSchema: ["type": .string("object")])
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }
    let server = try builder.build()

    let input = Pipe()
    let output = Pipe()
    let diagnostics = Pipe()
    let runner = MCPStdioServerRunner(
      server: server,
      configuration: MCPStdioServerConfiguration(
        input: input.fileHandleForReading,
        output: output.fileHandleForWriting,
        errorOutput: diagnostics.fileHandleForWriting
      )
    )
    let runTask = Task { try await runner.run() }
    let requestWriter = MCPStdioWriter(handle: input.fileHandleForWriting)

    let requestID = MCPRequestID(41)
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("stdio-recovery-client")
    )
    let listTools = try MCPWireRequest(
      id: requestID,
      method: "tools/list",
      params: metadata.inserting(into: MCPListToolsParams().json.objectValue ?? [:])
    )

    let received: [Data]
    do {
      received = try await withMCPStdioTestTimeout(.seconds(5)) {
        var outputIterator = MCPStdioIO.lines(from: output.fileHandleForReading).makeAsyncIterator()

        // Unparseable JSON: answerable only without an ID, and it must be answered.
        try await requestWriter.writeFrame(Data(#"{"jsonrpc":"2.0","method":"#.utf8))
        guard let parseError = try await outputIterator.next() else { return [] }

        // A notification and a client response frame are both unanswerable; neither may produce
        // output and neither may end the channel.
        try await requestWriter.writeFrame(
          Data(#"{"jsonrpc":"2.0","method":"notifications/progress","params":{}}"#.utf8))
        try await requestWriter.writeFrame(
          Data(#"{"jsonrpc":"2.0","id":9,"result":{"resultType":"complete"}}"#.utf8))
        try await requestWriter.writeFrame(
          Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{}}"#.utf8))

        // The channel must still serve an ordinary request after all of that.
        try await requestWriter.write(.request(listTools))
        guard let result = try await outputIterator.next() else { return [parseError] }
        return [parseError, result]
      }
      try await requestWriter.close()
      try await withMCPStdioTestTimeout(.seconds(5)) { try await runTask.value }
    } catch {
      try? await requestWriter.close()
      runTask.cancel()
      _ = try? await withMCPStdioTestTimeout(.seconds(5)) { try await runTask.value }
      try? output.fileHandleForWriting.close()
      try? diagnostics.fileHandleForWriting.close()
      throw error
    }
    try output.fileHandleForWriting.close()
    try diagnostics.fileHandleForWriting.close()

    guard received.count == 2 else {
      return XCTFail("expected a parse error and a later result, got \(received.count) frames")
    }
    guard case .error(let failure) = try MCPWireMessage.decode(received[0]) else {
      return XCTFail("malformed frame must be answered with a JSON-RPC error")
    }
    XCTAssertEqual(failure.error.code, -32700)
    XCTAssertNil(failure.id, "an unparseable frame has no recoverable id")

    guard case .result(let result) = try MCPWireMessage.decode(received[1]) else {
      return XCTFail("the channel must still serve requests after rejected frames")
    }
    XCTAssertEqual(result.id, requestID)
    XCTAssertEqual(try MCPListToolsResult(json: .object(result.value)).tools.map(\.name), ["noop"])
  }

  func testStdioServerAllowsImmediateRequestIDReuseAfterTerminalResponse() async throws {
    let server = try MCPServerBuilder(
      implementation: implementation("stdio-id-reuse-server")
    ).build()
    let input = Pipe()
    let output = Pipe()
    let diagnostics = Pipe()
    let runner = MCPStdioServerRunner(
      server: server,
      configuration: MCPStdioServerConfiguration(
        input: input.fileHandleForReading,
        output: output.fileHandleForWriting,
        errorOutput: diagnostics.fileHandleForWriting
      )
    )
    let runTask = Task { try await runner.run() }
    let requestWriter = MCPStdioWriter(handle: input.fileHandleForWriting)

    let requestID = MCPRequestID(1)
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("stdio-id-reuse-client")
    )
    let discovery = try MCPWireRequest(
      id: requestID,
      method: "server/discover",
      params: metadata.inserting(into: [:])
    )

    do {
      try await withMCPStdioTestTimeout(.seconds(5)) {
        var outputIterator = MCPStdioIO.lines(
          from: output.fileHandleForReading
        ).makeAsyncIterator()
        // The peer may reuse an ID after receiving its terminal response. Repeat the handoff to
        // exercise the output-commit/active-request boundary rather than relying on scheduling.
        for _ in 0..<64 {
          try await requestWriter.write(.request(discovery))
          guard let frame = try await outputIterator.next(),
            case .result(let result) = try MCPWireMessage.decode(frame)
          else {
            return XCTFail("stdio server did not return a terminal discovery response")
          }
          XCTAssertEqual(result.id, requestID)
        }
      }
      try await requestWriter.close()
      try await withMCPStdioTestTimeout(.seconds(5)) { try await runTask.value }
    } catch {
      try? await requestWriter.close()
      runTask.cancel()
      _ = try? await withMCPStdioTestTimeout(.seconds(5)) { try await runTask.value }
      try? output.fileHandleForWriting.close()
      try? diagnostics.fileHandleForWriting.close()
      throw error
    }
    try output.fileHandleForWriting.close()
    try diagnostics.fileHandleForWriting.close()
  }

  func testStdioServerMapsSubscriptionCancellationToWireNotification() async throws {
    var builder = try MCPServerBuilder(
      implementation: implementation("stdio-cancellation-server")
    )
    builder.enableToolListChanged()
    let tool = try MCPTool(
      name: "noop",
      inputSchema: ["type": .string("object")]
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }
    let server = try builder.build()

    let input = Pipe()
    let output = Pipe()
    let diagnostics = Pipe()
    let runner = MCPStdioServerRunner(
      server: server,
      configuration: MCPStdioServerConfiguration(
        input: input.fileHandleForReading,
        output: output.fileHandleForWriting,
        errorOutput: diagnostics.fileHandleForWriting
      )
    )
    let runTask = Task { try await runner.run() }
    let requestWriter = MCPStdioWriter(handle: input.fileHandleForWriting)

    let requestID = MCPRequestID(73)
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("stdio-cancellation-client")
    )
    let params = MCPSubscriptionsListenParams(
      notifications: try MCPSubscriptionFilter(toolsListChanged: true)
    )
    let request = try MCPWireRequest(
      id: requestID,
      method: "subscriptions/listen",
      params: metadata.inserting(into: params.json.objectValue ?? [:])
    )
    let received: [Data]
    do {
      received = try await withMCPStdioTestTimeout {
        var outputIterator = MCPStdioIO.lines(from: output.fileHandleForReading).makeAsyncIterator()
        try await requestWriter.write(.request(request))
        guard let acknowledgement = try await outputIterator.next() else { return [] }
        await server.cancelAllSubscriptions(reason: "maintenance")
        guard let cancellation = try await outputIterator.next() else {
          return [acknowledgement]
        }
        return [acknowledgement, cancellation]
      }
      try await requestWriter.close()
      try await withMCPStdioTestTimeout { try await runTask.value }
    } catch {
      try? await requestWriter.close()
      runTask.cancel()
      _ = try? await withMCPStdioTestTimeout { try await runTask.value }
      try? output.fileHandleForWriting.close()
      try? diagnostics.fileHandleForWriting.close()
      throw error
    }
    try output.fileHandleForWriting.close()
    try diagnostics.fileHandleForWriting.close()

    guard received.count == 2 else {
      return XCTFail("stdio server did not emit acknowledgement and cancellation")
    }
    guard case .notification(let acknowledgement) = try MCPWireMessage.decode(received[0]) else {
      return XCTFail("first stdio frame must be a notification")
    }
    XCTAssertEqual(acknowledgement.method, "notifications/subscriptions/acknowledged")

    guard case .notification(let cancellation) = try MCPWireMessage.decode(received[1]) else {
      return XCTFail("stdio cancellation must be a notification")
    }
    XCTAssertEqual(cancellation.method, "notifications/cancelled")
    let cancelled = try MCPCancelledParams(json: .object(cancellation.params))
    XCTAssertEqual(cancelled.requestID, requestID)
    XCTAssertEqual(cancelled.reason, "maintenance")
  }

  /// A server ending a subscription on its own initiative signals a graceful end by responding to
  /// the original `subscriptions/listen` request with an empty complete result before closing the
  /// stream. That response is what distinguishes a clean close from an abrupt transport drop, so it
  /// must carry the subscription id and must not be replaced by a bare stream end.
  func testStdioServerGracefulCloseSendsEmptyListenResult() async throws {
    var builder = try MCPServerBuilder(
      implementation: implementation("stdio-graceful-close-server")
    )
    builder.enableToolListChanged()
    let tool = try MCPTool(
      name: "noop",
      inputSchema: ["type": .string("object")]
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }
    let server = try builder.build()

    let input = Pipe()
    let output = Pipe()
    let diagnostics = Pipe()
    let runner = MCPStdioServerRunner(
      server: server,
      configuration: MCPStdioServerConfiguration(
        input: input.fileHandleForReading,
        output: output.fileHandleForWriting,
        errorOutput: diagnostics.fileHandleForWriting
      )
    )
    let runTask = Task { try await runner.run() }
    let requestWriter = MCPStdioWriter(handle: input.fileHandleForWriting)

    let requestID = MCPRequestID(91)
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: implementation("stdio-graceful-close-client")
    )
    let params = MCPSubscriptionsListenParams(
      notifications: try MCPSubscriptionFilter(toolsListChanged: true)
    )
    let request = try MCPWireRequest(
      id: requestID,
      method: "subscriptions/listen",
      params: metadata.inserting(into: params.json.objectValue ?? [:])
    )
    let received: [Data]
    do {
      received = try await withMCPStdioTestTimeout {
        var outputIterator = MCPStdioIO.lines(from: output.fileHandleForReading).makeAsyncIterator()
        try await requestWriter.write(.request(request))
        guard let acknowledgement = try await outputIterator.next() else { return [] }
        await server.closeAllSubscriptions()
        guard let terminal = try await outputIterator.next() else { return [acknowledgement] }
        return [acknowledgement, terminal]
      }
      try await requestWriter.close()
      try await withMCPStdioTestTimeout { try await runTask.value }
    } catch {
      try? await requestWriter.close()
      runTask.cancel()
      _ = try? await withMCPStdioTestTimeout { try await runTask.value }
      try? output.fileHandleForWriting.close()
      try? diagnostics.fileHandleForWriting.close()
      throw error
    }
    try output.fileHandleForWriting.close()
    try diagnostics.fileHandleForWriting.close()

    guard received.count == 2 else {
      return XCTFail("stdio server did not emit acknowledgement and terminal result")
    }
    guard case .notification(let acknowledgement) = try MCPWireMessage.decode(received[0]) else {
      return XCTFail("first stdio frame must be a notification")
    }
    XCTAssertEqual(acknowledgement.method, "notifications/subscriptions/acknowledged")

    guard case .result(let result) = try MCPWireMessage.decode(received[1]) else {
      return XCTFail("graceful close must terminate with a JSON-RPC result, not a bare stream end")
    }
    XCTAssertEqual(result.id, requestID)
    XCTAssertEqual(result.resultType, .complete)
    let decoded = try MCPSubscriptionsListenResult(json: .object(result.value))
    XCTAssertEqual(decoded.subscriptionID, requestID)
  }

  func testStdioClientSurfacesServerSubscriptionCancellationReason() async throws {
    let script = #"""
      IFS= read -r _
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/subscriptions/acknowledged","params":{"notifications":{},"_meta":{"io.modelcontextprotocol/subscriptionId":1}}}'
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1,"reason":"maintenance"}}'
      sleep 1
      """#
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
      )
    )
    let client = try MCPClient(
      transport: transport,
      configuration: MCPClientConfiguration(
        implementation: implementation("stdio-cancellation-client"),
        capabilities: MCPClientCapabilities(),
        requestTimeout: .seconds(2)
      )
    )
    do {
      let subscription = try await client.listen(notifications: MCPSubscriptionFilter())
      let outcome = try await withMCPStdioTestTimeout {
        var iterator = subscription.events.makeAsyncIterator()
        let acknowledgement = try await iterator.next()
        do {
          _ = try await iterator.next()
          return (acknowledgement, nil as String?)
        } catch let error as MCPClientError {
          guard case .peerCancelled(let reason) = error else { throw error }
          return (acknowledgement, reason)
        }
      }
      guard case .acknowledged? = outcome.0 else {
        await transport.shutdown()
        return XCTFail("client did not surface acknowledgement")
      }
      XCTAssertEqual(outcome.1, "maintenance")
    } catch {
      await transport.shutdown()
      throw error
    }
    await transport.shutdown()
  }

  func testUnexpectedChildExitIsSurfaced() async throws {
    let shell = URL(fileURLWithPath: "/bin/sh")
    let (client, transport) = try makeClient(
      executable: shell,
      arguments: ["-c", "exit 7"],
      timeout: .seconds(2)
    )
    defer { Task { await transport.shutdown() } }

    do {
      _ = try await client.discover()
      XCTFail("expected process exit")
    } catch let error as MCPClientError {
      guard case .transport(let message) = error else {
        return XCTFail("unexpected error \(error)")
      }
      XCTAssertTrue(message.contains("status 7") || message.contains("stdout closed"))
    }
  }

  func testIDLessErrorFailsSharedStdioConnectionInsteadOfGuessingARequest() async throws {
    let shell = URL(fileURLWithPath: "/bin/sh")
    let script =
      #"IFS= read -r _; printf '%s\n' '{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}'; sleep 1"#
    let (client, transport) = try makeClient(
      executable: shell,
      arguments: ["-c", script],
      timeout: .seconds(2)
    )
    defer { Task { await transport.shutdown() } }

    do {
      _ = try await client.discover()
      XCTFail("expected unroutable id-less error")
    } catch let error as MCPClientError {
      guard case .transport(let message) = error else {
        return XCTFail("unexpected error \(error)")
      }
      XCTAssertTrue(message.contains("id-less JSON-RPC error"), message)
    }
  }
}
