#if os(macOS)
  import Foundation
  import MCP
  @testable import MCPXcode
  import XCTest

  final class MCPXcodeTests: XCTestCase {
    func testQualifiedRevisionSetIsXcodeSpecificAndClosed() {
      XCTAssertEqual(
        Set(MCPXcodeProtocolRevision.allCases.map(\.rawValue)),
        Set(["2024-11-05", "2025-03-26", "2025-06-18"])
      )
      XCTAssertEqual(MCPXcodeProtocolRevision.preferred, .v2025June18)
    }

    func testConfigurationCanExplicitlyPinOlderQualifiedRevision() throws {
      let implementation = try MCPImplementation(name: "test-agent", version: "1.0.0")
      let configuration = try MCPXcodeConfiguration(
        implementation: implementation,
        preferredProtocolRevision: .v2024November05
      )

      XCTAssertEqual(configuration.preferredProtocolRevision, .v2024November05)
      XCTAssertEqual(configuration.arguments, ["mcpbridge"])
    }

    func testConfigurationDefaultsToDisabledRequestTimeoutAndRelaxedIO() throws {
      let implementation = try MCPImplementation(name: "test-agent", version: "1.0.0")
      let configuration = try MCPXcodeConfiguration(implementation: implementation)

      XCTAssertEqual(configuration.requestTimeout, .zero)
      XCTAssertTrue(configuration.allowsReconnect)
      XCTAssertEqual(configuration.ioLimits.maximumFrameBytes, 64 * 1024 * 1024)
      XCTAssertEqual(configuration.ioLimits.jsonLimits.maximumDocumentBytes, 64 * 1024 * 1024)
    }

    func testConfigurationRejectsNegativeTimeoutButAcceptsZero() throws {
      let implementation = try MCPImplementation(name: "test-agent", version: "1.0.0")
      XCTAssertNoThrow(
        try MCPXcodeConfiguration(
          implementation: implementation,
          requestTimeout: .zero
        )
      )
      XCTAssertThrowsError(
        try MCPXcodeConfiguration(
          implementation: implementation,
          requestTimeout: .seconds(-1)
        )
      )
    }

    func testMockBridgeConnectsAndCallsTools() async throws {
      let client = try makeClient(mode: "normal")
      let connection = try await client.connect()
      XCTAssertEqual(connection.protocolRevision, .v2025June18)

      let tools = try await client.listTools()
      XCTAssertEqual(tools.tools.map(\.name), ["XcodeListWindows"])

      let result = try await client.callTool(name: "XcodeListWindows")
      XCTAssertEqual(result.content.count, 1)
      XCTAssertEqual(result.content, [.text(MCPTextContent(text: "ok"))])
      XCTAssertNil(result.structuredContent)
      XCTAssertFalse(result.isError)
      await client.close()
    }

    func testEveryQualifiedRevisionCompletesFullHandshakeAndToolCall() async throws {
      for revision in MCPXcodeProtocolRevision.allCases {
        let client = try makeClient(mode: "normal", revision: revision)
        let connection = try await client.connect()
        XCTAssertEqual(connection.protocolRevision, revision)
        let tools = try await client.listTools()
        XCTAssertEqual(tools.tools.map(\.name), ["XcodeListWindows"])
        let result = try await client.callTool(name: "XcodeListWindows")
        XCTAssertEqual(result.content, [.text(MCPTextContent(text: "ok"))])
        XCTAssertNil(result.structuredContent)
        await client.close()
      }
    }

    func testNegotiatedOlderSupportedRevisionIsAccepted() async throws {
      let client = try makeClient(
        mode: "normal",
        revision: .v2024November05,
        preferredRevision: .v2025June18
      )

      let connection = try await client.connect()
      XCTAssertEqual(connection.protocolRevision, .v2024November05)
      let tools = try await client.listTools()
      XCTAssertEqual(tools.tools.map(\.name), ["XcodeListWindows"])
      await client.close()
    }

    func testLongToolCallCanCompleteWithoutSDKDeadline() async throws {
      let client = try makeClient(mode: "delay-tool-call", timeout: .zero)
      _ = try await client.connect()

      let result = try await client.callTool(name: "XcodeListWindows")
      XCTAssertEqual(result.content, [.text(MCPTextContent(text: "ok"))])
      await client.close()
    }

    func testConcurrentFirstCallsShareOneCommittedConnection() async throws {
      let client = try makeClient(mode: "normal")

      async let first = client.listTools()
      async let second = client.listTools()
      let (firstPage, secondPage) = try await (first, second)

      XCTAssertEqual(firstPage.tools.map(\.name), ["XcodeListWindows"])
      XCTAssertEqual(secondPage.tools.map(\.name), ["XcodeListWindows"])
      await client.close()
    }

    func testCancellingOneConnectWaiterDoesNotCancelSharedInitialize() async throws {
      let logURL = temporaryLogURL()
      let client = try makeClient(mode: "delay-initialize", logURL: logURL)

      let cancelled = Task { try await client.connect() }
      let surviving = Task { try await client.connect() }
      try await Task.sleep(for: .milliseconds(30))
      cancelled.cancel()

      do {
        _ = try await cancelled.value
        XCTFail("cancelled connect waiter unexpectedly completed")
      } catch is CancellationError {
        // Expected: only this waiter is cancelled.
      }

      let connection = try await surviving.value
      XCTAssertEqual(connection.protocolRevision, .v2025June18)
      let log = try logContents(logURL)
      XCTAssertEqual(log.components(separatedBy: "\"method\":\"initialize\"").count - 1, 1)
      XCTAssertFalse(log.contains("notifications/cancelled"))
      await client.close()
    }

    func testCancelledAttemptCleanupQueuesFreshConnectUntilStopCommits() async throws {
      let logURL = temporaryLogURL()
      let client = try makeClient(mode: "cancel-cleanup-reconnect", logURL: logURL)

      let abandoned = Task { try await client.connect() }
      try await Task.sleep(for: .milliseconds(30))
      abandoned.cancel()
      do {
        _ = try await abandoned.value
        XCTFail("cancelled connection attempt unexpectedly completed")
      } catch is CancellationError {
        // The cancellation commits stopping before this waiter is released.
      }

      let fresh = try await client.connect()
      XCTAssertEqual(fresh.protocolRevision, .v2025June18)

      let log = try logContents(logURL)
      XCTAssertEqual(log.components(separatedBy: "__launch__").count - 1, 2)
      XCTAssertEqual(log.components(separatedBy: "\"method\":\"initialize\"").count - 1, 2)
      XCTAssertFalse(log.contains("notifications/cancelled"))
      await client.close()
    }

    func testImmediateReconnectWaitsForProcessTeardownBarrier() async throws {
      let logURL = temporaryLogURL()
      let client = try makeClient(mode: "close-stdout-after-list", logURL: logURL)

      let first = try await client.listTools()
      XCTAssertEqual(first.tools.map(\.name), ["XcodeListWindows"])
      try await waitForLogMarker("__stdout_closed__", at: logURL)
      try await Task.sleep(for: .milliseconds(100))

      let second = try await client.listTools()
      XCTAssertEqual(second.tools.map(\.name), ["XcodeListWindows"])
      let log = try logContents(logURL)
      XCTAssertEqual(log.components(separatedBy: "__launch__").count - 1, 2)
      await client.close()
    }

    func testInitializeCancellationIsLocalOnly() async throws {
      let logURL = temporaryLogURL()
      let client = try makeClient(mode: "ignore-initialize", logURL: logURL)
      let task = Task { try await client.connect() }

      try await Task.sleep(for: .milliseconds(50))
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("cancelled initialize unexpectedly completed")
      } catch is CancellationError {
        // Expected: initialize is abandoned locally and never cancelled on the legacy wire.
      }

      await client.close()
      XCTAssertFalse(try logContents(logURL).contains("notifications/cancelled"))
    }

    func testInitializeTimeoutIsLocalOnly() async throws {
      let logURL = temporaryLogURL()
      let client = try makeClient(
        mode: "ignore-initialize",
        timeout: .milliseconds(50),
        logURL: logURL
      )

      do {
        _ = try await client.connect()
        XCTFail("initialize unexpectedly completed")
      } catch let error as MCPXcodeError {
        guard case .timeout(let method) = error else {
          return XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(method, "initialize")
      }

      await client.close()
      XCTAssertFalse(try logContents(logURL).contains("notifications/cancelled"))
    }

    func testOrdinaryToolCancellationNotifiesPeer() async throws {
      let logURL = temporaryLogURL()
      let client = try makeClient(mode: "ignore-tool-call", logURL: logURL)
      _ = try await client.connect()

      let task = Task { try await client.callTool(name: "XcodeListWindows") }
      try await Task.sleep(for: .milliseconds(50))
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("cancelled tool call unexpectedly completed")
      } catch is CancellationError {
        // Expected.
      }

      await client.close()
      XCTAssertTrue(try logContents(logURL).contains("notifications/cancelled"))
    }

    func testOrdinaryToolCancellationWithoutSDKDeadlineNotifiesPeer() async throws {
      let logURL = temporaryLogURL()
      let client = try makeClient(mode: "ignore-tool-call", timeout: .zero, logURL: logURL)
      _ = try await client.connect()

      let task = Task { try await client.callTool(name: "XcodeListWindows") }
      try await Task.sleep(for: .milliseconds(50))
      task.cancel()
      do {
        _ = try await task.value
        XCTFail("cancelled tool call unexpectedly completed")
      } catch is CancellationError {
        // Expected.
      }

      await client.close()
      XCTAssertTrue(try logContents(logURL).contains("notifications/cancelled"))
    }

    func testOrdinaryToolCancellationNotifiesPeerRepeatedly() async throws {
      for _ in 0..<10 {
        try await testOrdinaryToolCancellationNotifiesPeer()
      }
    }

    func testDuplicateRetiredResponseDoesNotPoisonConnection() async throws {
      let client = try makeClient(mode: "duplicate-list-response")
      _ = try await client.listTools()
      let result = try await client.callTool(name: "XcodeListWindows")
      XCTAssertFalse(result.isError)
      await client.close()
    }

    func testLateDuplicateAfterRetirementWindowDoesNotPoisonConnection() async throws {
      let client = try makeClient(mode: "late-response-after-retirement-window")
      _ = try await client.connect()

      for _ in 0..<256 {
        let tools = try await client.listTools()
        XCTAssertEqual(tools.tools.map(\.name), ["XcodeListWindows"])
      }
      let result = try await client.callTool(name: "XcodeListWindows")
      XCTAssertEqual(result.content, [.text(MCPTextContent(text: "ok"))])
      await client.close()
    }

    func testExitPreservesResponseBufferedBehindNotification() async throws {
      let client = try makeClient(
        mode: "exit-after-notification",
        toolsChangedHandler: { try? await Task.sleep(for: .milliseconds(200)) }
      )
      do {
        let tools = try await client.listTools()
        XCTAssertEqual(tools.tools.map(\.name), ["XcodeListWindows"])
        await client.close()
      } catch {
        await client.close()
        throw error
      }
    }

    func testResumedRequestRejectsObservedExitBeforeWriting() async throws {
      let entered = AsyncStream<Void>.makeStream()
      let release = AsyncStream<Void>.makeStream()
      let client = try makeClient(
        mode: "exit-after-notification",
        toolsChangedHandler: {
          entered.continuation.yield(())
          var iterator = release.stream.makeAsyncIterator()
          _ = await iterator.next()
        }
      )
      let pending = Task { try await client.listTools() }
      var notification = entered.stream.makeAsyncIterator()
      _ = await notification.next()
      var observedExit = false
      for _ in 0..<50 {
        do { _ = try await client.connect() } catch let error as MCPXcodeError {
          if case .processExited(0) = error {
            observedExit = true
            break
          }
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertTrue(observedExit, "the real mock process must exit before the resumed request")
      // Exercise the continuation after its earlier connect completed, without rechecking connect.
      // The stdout reader still holds an existing final response behind the notification handler.
      do {
        _ = try await client.request(method: "tools/list", params: [:])
        XCTFail("request wrote after an observed bridge exit")
      } catch let error as MCPXcodeError {
        if case .processExited(0) = error {} else { XCTFail("unexpected error: \(error)") }
      }
      release.continuation.yield(())
      release.continuation.finish()
      entered.continuation.finish()
      do {
        let tools = try await pending.value
        XCTAssertEqual(tools.tools.map(\.name), ["XcodeListWindows"])
        await client.close()
      } catch {
        await client.close()
        throw error
      }
    }

    func testExitDrainHasBoundWithoutRequestDeadline() async throws {
      let client = try makeClient(
        mode: "exit-after-notification", timeout: .zero,
        toolsChangedHandler: { try? await Task.sleep(for: .milliseconds(1400)) }
      )
      let clock = ContinuousClock()
      let start = clock.now
      do {
        _ = try await client.listTools()
        XCTFail("stalled stdout unexpectedly completed")
      } catch let error as MCPXcodeError {
        guard case .processExited(0) = error else {
          await client.close()
          return XCTFail("unexpected error: \(error)")
        }
        XCTAssertGreaterThanOrEqual(start.duration(to: clock.now), .milliseconds(800))
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(3))
      }
      await client.close()
    }

    func testSingleConnectionPolicyRejectsExplicitAndImplicitReconnect() async throws {
      let logURL = temporaryLogURL()
      defer { try? FileManager.default.removeItem(at: logURL) }
      let client = try makeClient(
        mode: "close-stdout-after-list", logURL: logURL, allowsReconnect: false
      )
      let tools = try await client.listTools()
      XCTAssertEqual(tools.tools.map(\.name), ["XcodeListWindows"])
      try await waitForLogMarker("__stdout_closed__", at: logURL)
      try await Task.sleep(for: .milliseconds(100))
      for operation in ["connect", "list", "call"] {
        do {
          switch operation {
          case "connect": _ = try await client.connect()
          case "list": _ = try await client.listTools()
          default: _ = try await client.callTool(name: "XcodeListWindows")
          }
          XCTFail("\(operation) reopened a single-connection client")
        } catch let error as MCPXcodeError {
          guard case .notConnected = error else {
            await client.close()
            return XCTFail("unexpected error: \(error)")
          }
        }
      }
      await client.close()
      XCTAssertEqual(try logContents(logURL).components(separatedBy: "__launch__").count - 1, 1)
    }

    func testBridgeExitAllowsFreshProcessGeneration() async throws {
      let client = try makeClient(mode: "exit-after-list")
      let first = try await client.listTools()
      XCTAssertEqual(first.tools.map(\.name), ["XcodeListWindows"])

      try await Task.sleep(for: .milliseconds(100))
      let second = try await client.listTools()
      XCTAssertEqual(second.tools.map(\.name), ["XcodeListWindows"])
      await client.close()
    }

    func testLiveXcodeQualificationWhenExplicitlyEnabled() async throws {
      let hostEnvironment = ProcessInfo.processInfo.environment
      guard hostEnvironment["MCP_XCODE_LIVE_QUALIFICATION"] == "1" else {
        throw XCTSkip("set MCP_XCODE_LIVE_QUALIFICATION=1 on a Mac with the target Xcode open")
      }
      guard let transcriptPath = hostEnvironment["MCP_XCODE_TRANSCRIPT_PATH"],
        !transcriptPath.isEmpty
      else {
        throw XCTSkip("set MCP_XCODE_TRANSCRIPT_PATH to retain qualification evidence")
      }
      guard
        let proxyURL = Bundle.module.url(
          forResource: "live-mcpbridge-proxy",
          withExtension: "py",
          subdirectory: "Fixtures"
        )
      else {
        throw XCTSkip("live-mcpbridge-proxy.py resource missing")
      }

      let requestedRevision =
        hostEnvironment["MCP_XCODE_PROTOCOL_REVISION"]
        .flatMap(MCPXcodeProtocolRevision.init(rawValue:)) ?? .preferred
      var environment = hostEnvironment
      environment["MCP_XCODE_TRANSCRIPT_PATH"] = transcriptPath
      environment["MCP_XCODE_PROTOCOL_REVISION"] = requestedRevision.rawValue

      let configuration = try MCPXcodeConfiguration(
        executableURL: URL(fileURLWithPath: "/usr/bin/python3"),
        arguments: [proxyURL.path],
        environment: environment,
        implementation: try MCPImplementation(
          name: "swiftmcp-xcode-qualification", version: "1.0.0"),
        preferredProtocolRevision: requestedRevision,
        requestTimeout: .seconds(30)
      )
      let client = MCPXcodeClient(configuration: configuration)
      let connection = try await client.connect()
      let tools = try await client.listTools()
      guard tools.tools.contains(where: { $0.name == "XcodeListWindows" }) else {
        await client.close()
        return XCTFail("qualified Xcode bridge did not expose XcodeListWindows")
      }
      let result = try await client.callTool(name: "XcodeListWindows")
      XCTAssertFalse(result.isError)
      XCTAssertTrue(MCPXcodeProtocolRevision.allCases.contains(connection.protocolRevision))
      await client.close()

      let transcript = try String(contentsOfFile: transcriptPath, encoding: .utf8)
      let methods = transcript.split(separator: "\n").compactMap { line -> String? in
        guard let data = String(line).data(using: .utf8),
          let entry = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let message = entry["message"] as? [String: Any]
        else { return nil }
        return message["method"] as? String
      }
      XCTAssertTrue(methods.contains("initialize"))
      XCTAssertTrue(methods.contains("notifications/initialized"))
      XCTAssertTrue(methods.contains("tools/list"))
      XCTAssertTrue(methods.contains("tools/call"))
    }

    private func makeClient(
      mode: String,
      timeout: Duration = .seconds(2),
      logURL: URL? = nil,
      revision: MCPXcodeProtocolRevision = .v2025June18,
      preferredRevision: MCPXcodeProtocolRevision? = nil,
      ioLimits: MCPXcodeIOLimits = .default,
      toolsChangedHandler: (@Sendable () async -> Void)? = nil,
      allowsReconnect: Bool = true
    ) throws -> MCPXcodeClient {
      guard
        let fixtureURL = Bundle.module.url(
          forResource: "mock-mcpbridge",
          withExtension: "sh",
          subdirectory: "Fixtures"
        )
      else {
        throw XCTSkip("mock-mcpbridge.sh resource missing")
      }

      var environment: [String: String] = [
        "MOCK_XCODE_MODE": mode,
        "MOCK_XCODE_REVISION": revision.rawValue,
      ]
      if let logURL { environment["MOCK_XCODE_LOG_FILE"] = logURL.path }

      let configuration = try MCPXcodeConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: [fixtureURL.path],
        environment: environment,
        implementation: try MCPImplementation(name: "test-agent", version: "1.0.0"),
        preferredProtocolRevision: preferredRevision ?? revision,
        requestTimeout: timeout,
        ioLimits: ioLimits,
        toolsChangedHandler: toolsChangedHandler,
        allowsReconnect: allowsReconnect
      )
      return MCPXcodeClient(configuration: configuration)
    }

    private func temporaryLogURL() -> URL {
      FileManager.default.temporaryDirectory
        .appendingPathComponent("swiftmcp-xcode-\(UUID().uuidString).log")
    }

    private func waitForLogMarker(_ marker: String, at url: URL) async throws {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(1))
      while clock.now < deadline {
        if try logContents(url).contains(marker) { return }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTFail("timed out waiting for mock bridge marker: \(marker)")
      throw MCPXcodeError.transport("mock bridge marker timeout: \(marker)")
    }

    private func logContents(_ url: URL) throws -> String {
      guard FileManager.default.fileExists(atPath: url.path) else { return "" }
      return try String(contentsOf: url, encoding: .utf8)
    }
  }
#endif
