@preconcurrency import Foundation
import XCTest

@testable import MCP
@testable import MCPStdioClient
@testable import MCPStdioServer
@testable import MCPStdioShared

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

private final class StdioTestPipe: @unchecked Sendable {
  let read: FileHandle
  let write: FileHandle

  init() {
    let pipe = Pipe()
    read = pipe.fileHandleForReading
    write = pipe.fileHandleForWriting
  }
}

final class MCPStdioSourceLineBehaviorTests: XCTestCase {
  private func request(id: Int64) throws -> MCPWireRequest {
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: MCPImplementation(name: "stdio-source-client", version: "1.0.0")
    )
    return try MCPWireRequest(
      id: MCPRequestID(id),
      method: "server/discover",
      params: metadata.inserting(into: [:])
    )
  }

  private func oversizedRequest(id: Int64) throws -> MCPWireRequest {
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: MCPImplementation(name: "stdio-source-client", version: "1.0.0")
    )
    var params = try metadata.inserting(into: [:])
    params["payload"] = .string(String(repeating: "x", count: 4 * 1_024 * 1_024))
    return try MCPWireRequest(
      id: MCPRequestID(id),
      method: "server/discover",
      params: params
    )
  }

  private func childPIDs(at url: URL, count: Int) async -> [pid_t]? {
    for _ in 0..<100 {
      if let text = try? String(contentsOf: url, encoding: .utf8) {
        let values: [pid_t] = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
        if values.count == count { return values }
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
  }

  private func waitUntilProcessExited(_ pid: pid_t) async -> Bool {
    for _ in 0..<100 {
      if kill(pid, 0) != 0 { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return kill(pid, 0) != 0
  }

  private static func collectLines(from handle: FileHandle) async throws -> [Data] {
    var values: [Data] = []
    for try await line in MCPStdioIO.lines(
      from: handle,
      limits: try MCPStdioLimits(maximumFrameBytes: 64, readChunkBytes: 8)
    ) {
      values.append(line)
    }
    return values
  }

  private func waitUntilReadable(_ handle: FileHandle) async -> Bool {
    // The oversized response is encoded before the first byte reaches the pipe. Observe the actual
    // descriptor state rather than assuming encoding finishes within the one-second fast path; the
    // full-suite warnings-as-errors run can legitimately add scheduler pressure here.
    for _ in 0..<500 {
      var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
      if poll(&descriptor, nfds_t(1), 0) > 0 { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }

  func testLineReaderTreatsEOFAsCleanOnlyAfterCompleteFrames() async throws {
    let complete = StdioTestPipe()
    try complete.write.write(contentsOf: Data("first\nsecond\r\n".utf8))
    try complete.write.close()
    let completeLines = try await Self.collectLines(from: complete.read)
    XCTAssertEqual(
      completeLines,
      [Data("first".utf8), Data("second".utf8)]
    )

    let truncated = StdioTestPipe()
    try truncated.write.write(contentsOf: Data("partial".utf8))
    try truncated.write.close()
    do {
      _ = try await Self.collectLines(from: truncated.read)
      XCTFail("EOF must not silently discard an unterminated stdio JSON frame")
    } catch let error as MCPStdioError {
      XCTAssertEqual(error, .truncatedFrame)
    }
  }

  func testLineReaderOwnsADescriptorDuplicateWithoutChangingCallerFlags() async throws {
    let pipe = StdioTestPipe()
    let initialFlags = fcntl(pipe.read.fileDescriptor, F_GETFL, 0)
    XCTAssertGreaterThanOrEqual(initialFlags, 0)

    try pipe.write.write(contentsOf: Data("owned\n".utf8))
    try pipe.write.close()

    let observed = try await Self.collectLines(from: pipe.read)
    XCTAssertEqual(observed, [Data("owned".utf8)])
    let finalFlags = fcntl(pipe.read.fileDescriptor, F_GETFL, 0)
    XCTAssertEqual(finalFlags, initialFlags)
    try pipe.read.close()
  }

  func testCancellingAQuietLineReaderDoesNotWaitForAnotherByte() async throws {
    let quiet = StdioTestPipe()
    let finished = expectation(description: "quiet stdio reader stopped")
    let reader = Task {
      defer { finished.fulfill() }
      do {
        for try await _ in MCPStdioIO.lines(from: quiet.read) {}
      } catch is CancellationError {
        // Cancellation is the expected terminal state for a quiet descriptor.
      }
    }

    await Task.yield()
    reader.cancel()
    await fulfillment(of: [finished], timeout: 0.25)
    try quiet.write.close()
    _ = await reader.result
  }

  func testClientCancellationWritesAProtocolFrameAndKeepsTheChildReusable() async throws {
    let script = #"""
      IFS= read -r _
      IFS= read -r cancellation
      case "$cancellation" in
        *'"method":"notifications/cancelled"'*) ;;
        *) exit 12 ;;
      esac
      case "$cancellation" in
        *'"requestId":1'*) ;;
        *) exit 13 ;;
      esac
      case "$cancellation" in
        *'"reason":"caller no longer needs the response"'*) ;;
        *) exit 14 ;;
      esac
      IFS= read -r _
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete"}}'
      """#
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
      )
    )
    do {
      let cancelled = try await transport.open(try request(id: 1))
      try await cancelled.cancel(reason: "caller no longer needs the response")
      do {
        _ = try await collectMCPStdioTestFrames(from: cancelled.frames)
        XCTFail("cancelling a stdio exchange must finish its local stream")
      } catch is CancellationError {
        // The shell only reads its third line after this cancellation notification arrives.
      }

      let reusable = try await transport.open(try request(id: 2))
      let frames = try await collectMCPStdioTestFrames(from: reusable.frames)
      if frames.count == 1, case .result(let result) = frames[0] {
        XCTAssertEqual(result.id, MCPRequestID(2))
      } else {
        XCTFail("child did not process the request after the cancellation notification")
      }
    } catch is MCPStdioTestTimeout {
      await transport.shutdown()
      XCTFail("child did not complete the cancellation/reuse protocol within one second")
      return
    } catch {
      await transport.shutdown()
      throw error
    }
    await transport.shutdown()
  }

  func testLateResponseAfterCancellationDoesNotPoisonTheSharedChild() async throws {
    let script = #"""
      IFS= read -r _
      IFS= read -r _
      printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"resultType":"complete"}}'
      IFS= read -r _
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete"}}'
      """#
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script]
      )
    )
    do {
      let cancelled = try await transport.open(try request(id: 1))
      try await cancelled.cancel(reason: "ignore late response")
      _ = try? await collectMCPStdioTestFrames(from: cancelled.frames)

      let reusable = try await transport.open(try request(id: 2))
      let frames = try await collectMCPStdioTestFrames(from: reusable.frames)
      guard frames.count == 1, case .result(let result) = frames[0] else {
        await transport.shutdown()
        return XCTFail("a late response for a cancelled request must not poison stdio")
      }
      XCTAssertEqual(result.id, MCPRequestID(2))
    } catch is MCPStdioTestTimeout {
      await transport.shutdown()
      XCTFail("stdio child did not survive the late response")
      return
    } catch {
      await transport.shutdown()
      throw error
    }
    await transport.shutdown()
  }

  func testCancellingAWriteBlockedOnAFullPipeReturnsPromptly() async throws {
    MCPStdioSignalHandling.ignoreSIGPIPE()
    let pipe = StdioTestPipe()
    let writer = MCPStdioWriter(handle: pipe.write)
    let payload = Data(repeating: 0x78, count: 4 * 1_024 * 1_024)
    let writeTask = Task { try await writer.writeFrame(payload) }
    let responseStarted = await waitUntilReadable(pipe.read)
    XCTAssertTrue(responseStarted, "writer did not begin filling the pipe")

    let finished = expectation(description: "cancelled stdio write finished")
    writeTask.cancel()
    let observer = Task {
      _ = await writeTask.result
      finished.fulfill()
    }
    let result = await XCTWaiter.fulfillment(of: [finished], timeout: 1)
    if result != .completed {
      // Unblock a regressed implementation before awaiting its result, keeping the test process
      // from retaining a writer task after the failure is reported.
      try? pipe.read.close()
    }
    await observer.value
    let writeResult = await writeTask.result
    guard case .failure(let error) = writeResult else {
      try? await writer.close()
      try? pipe.read.close()
      return XCTFail("cancelling a blocked write must fail the write task")
    }
    XCTAssertTrue(error is CancellationError, "unexpected cancellation error: (error)")
    try? await writer.close()
    try? pipe.read.close()
    XCTAssertEqual(result, .completed)
  }

  func testClientFailsPendingRequestsWhenChildClosesStdoutBeforeResponding() async throws {
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "exec 1>&-; cat >/dev/null"]
      )
    )
    do {
      let exchange = try await transport.open(try request(id: 1))
      do {
        _ = try await collectMCPStdioTestFrames(from: exchange.frames)
        XCTFail("a pending stdio request cannot survive server stdout EOF")
      } catch let error as MCPStdioError {
        XCTAssertEqual(error, .io("stdout closed before pending requests completed"))
      }
    } catch is MCPStdioTestTimeout {
      await transport.shutdown()
      XCTFail("stdout EOF did not fail the pending exchange within one second")
      return
    } catch {
      await transport.shutdown()
      throw error
    }
    await transport.shutdown()
  }

  func testRoutingFailureKillsTermIgnoringChildBeforeTransportRestart() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    var environment = ProcessInfo.processInfo.environment
    environment["MCP_TEST_STATE_DIRECTORY"] = temporaryDirectory.path
    let script = #"""
      run_file="$MCP_TEST_STATE_DIRECTORY/run"
      run=0
      if [ -f "$run_file" ]; then run=$(cat "$run_file"); fi
      run=$((run + 1))
      printf '%s' "$run" > "$run_file"
      printf '%s\n' "$$" > "$MCP_TEST_STATE_DIRECTORY/pid-$run"
      IFS= read -r _
      if [ "$run" -eq 1 ]; then
        trap '' TERM
        printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"unmatched","progress":1}}'
        while :; do sleep 1; done
      fi
      printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"resultType":"complete"}}'
      """#
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        environment: environment
      )
    )

    let exchange = try await transport.open(try request(id: 1))
    let firstPIDFile = temporaryDirectory.appendingPathComponent("pid-1")
    guard let firstPID = await childPIDs(at: firstPIDFile, count: 1)?.first else {
      await transport.shutdown()
      return XCTFail("child did not record its process ID")
    }
    defer {
      if kill(firstPID, 0) == 0 { _ = kill(firstPID, SIGKILL) }
    }

    do {
      _ = try await collectMCPStdioTestFrames(from: exchange.frames)
      XCTFail("an unmatched progress token must fail the shared stdio channel")
    } catch is MCPStdioError {
      // The routing error is intentionally channel-fatal; the child must be reaped as well.
    }

    let exitedBeforeRestart = await waitUntilProcessExited(firstPID)
    XCTAssertTrue(exitedBeforeRestart, "routing failure left the TERM-ignoring child process alive")

    let restarted = try await transport.open(try request(id: 2))
    let restartedFrames = try await collectMCPStdioTestFrames(from: restarted.frames)
    guard restartedFrames.count == 1, case .result(let result) = restartedFrames[0] else {
      await transport.shutdown()
      return XCTFail("transport did not serve a normal request after restarting its child")
    }
    XCTAssertEqual(result.id, MCPRequestID(2))
    let secondPIDFile = temporaryDirectory.appendingPathComponent("pid-2")
    guard let secondPID = await childPIDs(at: secondPIDFile, count: 1)?.first else {
      await transport.shutdown()
      return XCTFail("restarted child did not record its process ID")
    }
    XCTAssertNotEqual(firstPID, secondPID)
    await transport.shutdown()
  }

  func testShutdownPreventsAConcurrentOpenFromOrphaningANewChild() async throws {
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "trap '' TERM; while :; do sleep 1; done"]
      )
    )
    _ = try await transport.open(try request(id: 1))

    let firstShutdown = Task { await transport.shutdown() }
    try await Task.sleep(for: .milliseconds(20))
    let secondShutdown = Task { await transport.shutdown() }
    do {
      _ = try await transport.open(try request(id: 2))
      XCTFail("open must not launch a replacement child while shutdown is in progress")
    } catch let error as MCPStdioError {
      XCTAssertEqual(error, .processNotRunning)
    }

    await firstShutdown.value
    await secondShutdown.value
  }

  func testShutdownInterruptsAFullPipeHeldOpenByALongLivedDescendant() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let pidFile = temporaryDirectory.appendingPathComponent("child.pid")
    var environment = ProcessInfo.processInfo.environment
    environment["MCP_TEST_PID_FILE"] = pidFile.path

    let script = #"""
      trap '' TERM
      exec 3<&0
      /usr/bin/tail -f /dev/null <&3 &
      descendant=$!
      printf '%s %s' "$$" "$descendant" > "$MCP_TEST_PID_FILE"
      wait "$descendant"
      """#
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        environment: environment
      )
    )
    let request = try oversizedRequest(id: 1)
    let openTask = Task { try await transport.open(request) }
    guard let pids = await childPIDs(at: pidFile, count: 2) else {
      openTask.cancel()
      await transport.shutdown()
      return XCTFail("child and descendant did not expose their process ids")
    }
    let childPID = pids[0]
    let descendantPID = pids[1]
    defer {
      _ = kill(childPID, SIGKILL)
      _ = kill(descendantPID, SIGKILL)
    }
    try await Task.sleep(for: .milliseconds(50))

    let shutdownFinished = expectation(description: "blocked stdio write was interrupted")
    let shutdownTask = Task {
      await transport.shutdown()
      shutdownFinished.fulfill()
    }
    let result = await XCTWaiter.fulfillment(of: [shutdownFinished], timeout: 2)
    if result != .completed {
      // Keep a regressed implementation from leaking the deliberately unresponsive child.
      _ = kill(childPID, SIGKILL)
      _ = kill(descendantPID, SIGKILL)
    }
    await shutdownTask.value
    _ = await openTask.result
    if result == .completed {
      XCTAssertEqual(
        kill(descendantPID, 0),
        0,
        "shutdown must complete even while the descendant still owns the pipe read descriptor"
      )
    }
    XCTAssertEqual(result, .completed)
  }

  func testCancellingABlockedOpenClosesTheCorruptedClientChannel() async throws {
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: temporaryDirectory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let pidFile = temporaryDirectory.appendingPathComponent("child.pid")
    var environment = ProcessInfo.processInfo.environment
    environment["MCP_TEST_PID_FILE"] = pidFile.path
    let script = #"""
      trap '' TERM
      exec 3<&0
      /usr/bin/tail -f /dev/null <&3 &
      descendant=$!
      printf '%s %s' "$$" "$descendant" > "$MCP_TEST_PID_FILE"
      wait "$descendant"
      """#
    let transport = MCPStdioClientTransport(
      configuration: try MCPStdioClientConfiguration(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", script],
        environment: environment
      )
    )
    let request = try oversizedRequest(id: 2)
    let openTask = Task { try await transport.open(request) }
    guard let pids = await childPIDs(at: pidFile, count: 2) else {
      openTask.cancel()
      await transport.shutdown()
      return XCTFail("child and descendant did not expose their process ids")
    }
    let childPID = pids[0]
    let descendantPID = pids[1]
    defer {
      _ = kill(childPID, SIGKILL)
      _ = kill(descendantPID, SIGKILL)
    }
    try await Task.sleep(for: .milliseconds(50))

    let openFinished = expectation(description: "cancelled blocked open finished")
    openTask.cancel()
    let observer = Task {
      _ = await openTask.result
      openFinished.fulfill()
    }
    let result = await XCTWaiter.fulfillment(of: [openFinished], timeout: 2)
    if result != .completed {
      _ = kill(childPID, SIGKILL)
      _ = kill(descendantPID, SIGKILL)
    }
    await observer.value
    let openResult = await openTask.result
    if case .failure(let error) = openResult {
      XCTAssertTrue(error is CancellationError)
    } else {
      XCTFail("cancelling the blocked open must fail it")
    }
    if result == .completed {
      XCTAssertEqual(
        kill(descendantPID, 0),
        0,
        "client cancellation must not rely on terminating a descriptor-owning descendant"
      )
    }
    await transport.shutdown()
    XCTAssertEqual(result, .completed)
  }

  func testServerInputEOFInterruptsAResponseBlockedOnAFullOutputPipe() async throws {
    var builder = try MCPServerBuilder(
      implementation: MCPImplementation(name: "blocked-stdio-server", version: "1.0.0")
    )
    let tool = try MCPTool(
      name: "large",
      description: String(repeating: "x", count: 4 * 1_024 * 1_024),
      inputSchema: ["type": .string("object")]
    )
    builder.setToolResolver { name, _ in name == tool.name ? tool : nil }
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: [tool])
    }
    try builder.register(MCPStandardMethods.callTool) { _, _ in
      try MCPCallToolResult(content: [])
    }
    let input = Pipe()
    let output = Pipe()
    let diagnostics = Pipe()
    let runner = MCPStdioServerRunner(
      server: try builder.build(),
      configuration: MCPStdioServerConfiguration(
        input: input.fileHandleForReading,
        output: output.fileHandleForWriting,
        errorOutput: diagnostics.fileHandleForWriting
      )
    )
    let runTask = Task { try await runner.run() }
    let requestWriter = MCPStdioWriter(handle: input.fileHandleForWriting)
    let metadata = try MCPRequestMetadata(
      clientCapabilities: MCPClientCapabilities(),
      clientInfo: MCPImplementation(name: "blocked-stdio-client", version: "1.0.0")
    )
    let request = try MCPWireRequest(
      id: MCPRequestID(3),
      method: MCPStandardMethods.listTools.descriptor.name,
      params: try metadata.inserting(into: [:])
    )
    try await requestWriter.write(.request(request))
    let responseStarted = await waitUntilReadable(output.fileHandleForReading)
    XCTAssertTrue(
      responseStarted,
      "server did not begin its oversized response"
    )
    try await Task.sleep(for: .milliseconds(50))
    try await requestWriter.close()

    let runFinished = expectation(description: "server stopped after input EOF")
    let observer = Task {
      _ = await runTask.result
      runFinished.fulfill()
    }
    let result = await XCTWaiter.fulfillment(of: [runFinished], timeout: 1)
    if result != .completed {
      try? output.fileHandleForReading.close()
    }
    await observer.value
    let runResult = await runTask.result
    if case .failure(let error) = runResult {
      throw error
    }
    try? output.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? diagnostics.fileHandleForReading.close()
    try? diagnostics.fileHandleForWriting.close()
    XCTAssertEqual(result, .completed)
  }
}
