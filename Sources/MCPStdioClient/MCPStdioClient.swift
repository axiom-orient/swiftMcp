@preconcurrency import Foundation
import MCP
import MCPStdioShared

/// Framing and JSON limits used by the public stdio client configuration.
public typealias MCPStdioLimits = MCPStdioShared.MCPStdioLimits

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

public typealias MCPStdioDiagnosticHandler = @Sendable (String) async -> Void

public struct MCPStdioClientConfiguration: Sendable {
  public let executableURL: URL
  public let arguments: [String]
  public let environment: [String: String]?
  public let currentDirectoryURL: URL?
  public let limits: MCPStdioLimits
  public let diagnosticHandler: MCPStdioDiagnosticHandler?
  /// Whether the transport installs the process-wide `SIGPIPE` guard described by
  /// `MCPStdioSignalHandling.ignoreSIGPIPE()`. Disable it only when the host manages signals.
  public let ignoresSIGPIPE: Bool

  public init(
    executableURL: URL,
    arguments: [String] = [],
    environment: [String: String]? = nil,
    currentDirectoryURL: URL? = nil,
    limits: MCPStdioLimits = .default,
    diagnosticHandler: MCPStdioDiagnosticHandler? = nil,
    ignoresSIGPIPE: Bool = true
  ) throws {
    guard executableURL.isFileURL, !executableURL.path.isEmpty else {
      throw MCPStdioError.io("executableURL must be a non-empty file URL")
    }
    if let currentDirectoryURL, !currentDirectoryURL.isFileURL {
      throw MCPStdioError.io("currentDirectoryURL must be a file URL")
    }
    self.executableURL = executableURL
    self.arguments = arguments
    self.environment = environment
    self.currentDirectoryURL = currentDirectoryURL
    self.limits = limits
    self.diagnosticHandler = diagnosticHandler
    self.ignoresSIGPIPE = ignoresSIGPIPE
  }
}

// Immutable holder for Process/Pipe references. Access to the process and all
// handles is serialized by `MCPStdioClientRuntime`, the owning actor.
private final class MCPProcessBox: @unchecked Sendable {
  let process: Process
  let stdinPipe: Pipe
  let stdoutPipe: Pipe
  let stderrPipe: Pipe

  init(process: Process, stdinPipe: Pipe, stdoutPipe: Pipe, stderrPipe: Pipe) {
    self.process = process
    self.stdinPipe = stdinPipe
    self.stdoutPipe = stdoutPipe
    self.stderrPipe = stderrPipe
  }
}

private actor MCPStdioClientRuntime {
  private struct Pending: Sendable {
    let method: String
    let progressToken: MCPProgressToken?
    let continuation: AsyncThrowingStream<MCPWireMessage, Error>.Continuation
  }

  private let configuration: MCPStdioClientConfiguration
  private var processBox: MCPProcessBox?
  private var writer: MCPStdioWriter?
  private var pending: [MCPRequestID: Pending] = [:]
  // A cancelled request may still produce a late response or progress notification on the shared
  // stdio channel. Keep bounded tombstones so those frames are ignored as the protocol requires
  // without allowing a cancellation-heavy caller to grow memory without limit.
  private let maximumIgnoredRequestIDs = 4_096
  private var ignoredRequestIDs: Set<MCPRequestID> = []
  private var ignoredProgressTokens: Set<MCPProgressToken> = []
  private var ignoredProgressTokensByRequest: [MCPRequestID: MCPProgressToken] = [:]
  private var ignoredRequestOrder: [MCPRequestID] = []
  private var generation: UInt64 = 0
  private var shuttingDown = false
  // Explicit shutdown rejects new exchanges. Automatic failure cleanup instead makes a later
  // open wait until the old child has been reaped, so a retry cannot race a stale process.
  private var rejectsNewOpensDuringShutdown = false
  private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
  private var processExitStatus: Int32?

  init(configuration: MCPStdioClientConfiguration) {
    self.configuration = configuration
  }

  func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    while shuttingDown {
      guard !rejectsNewOpensDuringShutdown else { throw MCPStdioError.processNotRunning }
      await withCheckedContinuation { continuation in
        shutdownWaiters.append(continuation)
      }
    }
    try Task.checkCancellation()
    try await ensureRunning()
    guard pending[request.id] == nil else {
      throw MCPStdioError.duplicateRequestID(request.id.description)
    }
    guard let writer, let activeProcessBox = processBox else {
      throw MCPStdioError.processNotRunning
    }
    let metadata = try MCPRequestMetadata.extract(from: request.params)
    let pair = AsyncThrowingStream<MCPWireMessage, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(4_096))
    pending[request.id] = Pending(
      method: request.method,
      progressToken: metadata.progressToken,
      continuation: pair.continuation
    )
    do {
      try await withTaskCancellationHandler {
        try await writer.write(.request(request))
      } onCancel: {
        // Cancelling before `open` returns can leave a partial request frame. Such a byte stream
        // cannot be reused, so interrupt this writer and let the catch path tear down the process.
        writer.requestClose()
      }
      // If cancellation arrived after the frame write but before the handler scope closed, its
      // on-cancel path already retired this writer. Route that race through the same teardown.
      try Task.checkCancellation()
    } catch {
      let reportedError: Error
      if Task.isCancelled {
        reportedError = CancellationError()
      } else {
        reportedError = await normalizedWriteFailure(error, processBox: activeProcessBox)
      }
      pending.removeValue(forKey: request.id)?.continuation.finish(throwing: reportedError)
      // A failed or cancelled frame may already be partially present on the byte stream. Tear the
      // channel down before it can be reused or accumulate more writes behind the failed frame.
      await failConnection(reportedError)
      throw reportedError
    }
    return MCPClientExchange(
      frames: pair.stream,
      cancel: { [runtime = self] reason in
        try await runtime.cancel(id: request.id, reason: reason)
      }
    )
  }

  func shutdown() async {
    if shuttingDown {
      await withCheckedContinuation { continuation in
        shutdownWaiters.append(continuation)
      }
      return
    }
    shuttingDown = true
    rejectsNewOpensDuringShutdown = true
    let shutdownWriter = writer
    let shutdownProcessBox = processBox
    writer = nil
    processBox = nil
    processExitStatus = nil
    generation &+= 1

    let error = MCPStdioError.io("stdio client shut down")
    finishAll(throwing: error)
    await stopProcess(writer: shutdownWriter, processBox: shutdownProcessBox, reason: error)
    finishShutdown()
  }

  private nonisolated static func waitForExit(_ process: Process, attempts: Int) async -> Bool {
    for _ in 0..<attempts {
      if !process.isRunning {
        process.waitUntilExit()
        return true
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    if !process.isRunning { process.waitUntilExit() }
    return !process.isRunning
  }

  private func ensureRunning() async throws {
    if configuration.ignoresSIGPIPE { MCPStdioSignalHandling.ignoreSIGPIPE() }
    if let processBox, processBox.process.isRunning { return }
    if processBox != nil {
      // The termination callback can precede delivery of the final stdout bytes. Do not replace
      // the process generation while a pending exchange still depends on that drain.
      guard pending.isEmpty else { throw MCPStdioError.processNotRunning }
      finishAll(throwing: MCPStdioError.processNotRunning)
      self.processBox = nil
      writer = nil
      processExitStatus = nil
    }

    let process = Process()
    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = configuration.executableURL
    process.arguments = configuration.arguments
    process.environment = configuration.environment
    process.currentDirectoryURL = configuration.currentDirectoryURL
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    generation &+= 1
    let currentGeneration = generation
    process.terminationHandler = { [runtime = self] terminated in
      Task {
        await runtime.processExited(
          generation: currentGeneration,
          status: terminated.terminationStatus
        )
      }
    }
    do {
      try process.run()
    } catch {
      throw MCPStdioError.io("failed to launch \(configuration.executableURL.path): \(error)")
    }

    let box = MCPProcessBox(
      process: process,
      stdinPipe: stdinPipe,
      stdoutPipe: stdoutPipe,
      stderrPipe: stderrPipe
    )
    processBox = box
    writer = MCPStdioWriter(handle: stdinPipe.fileHandleForWriting)

    let lines = MCPStdioIO.lines(
      from: stdoutPipe.fileHandleForReading,
      limits: configuration.limits
    )
    Task { [runtime = self] in
      do {
        for try await line in lines {
          try await runtime.receive(line, generation: currentGeneration)
        }
        await runtime.outputEnded(generation: currentGeneration, error: nil)
      } catch {
        await runtime.outputEnded(generation: currentGeneration, error: error)
      }
    }

    let diagnostics = MCPStdioIO.lines(
      from: stderrPipe.fileHandleForReading,
      limits: configuration.limits
    )
    Task { [handler = configuration.diagnosticHandler] in
      do {
        for try await line in diagnostics {
          guard let handler else { continue }
          await handler(String(decoding: line, as: UTF8.self))
        }
      } catch {
        if let handler {
          await handler("stderr read failed: \(error)")
        }
      }
    }
  }

  private func receive(_ data: Data, generation: UInt64) async throws {
    guard generation == self.generation else { return }
    let message: MCPWireMessage
    do {
      message = try MCPWireMessage.decode(data, limits: configuration.limits.jsonLimits)
    } catch {
      await failConnection(MCPStdioError.unexpectedMessage("invalid JSON-RPC frame: \(error)"))
      throw error
    }

    switch message {
    case .result(let result):
      await deliverTerminal(message, id: result.id)
    case .error(let response):
      guard let id = response.id else {
        let error = MCPStdioError.unexpectedMessage(
          "id-less JSON-RPC error cannot be routed on a shared stdio channel")
        await failConnection(error)
        throw error
      }
      await deliverTerminal(message, id: id)
    case .notification(let notification):
      do {
        guard let id = try route(notification) else { return }
        guard let entry = pending[id] else {
          throw MCPStdioError.unexpectedMessage(
            "notification \(notification.method) has no active request")
        }
        let terminatesExchange = notification.method == "notifications/cancelled"
        if terminatesExchange {
          pending.removeValue(forKey: id)
          rememberCancelled(id: id, progressToken: entry.progressToken)
        }
        switch entry.continuation.yield(message) {
        case .enqueued:
          if terminatesExchange { entry.continuation.finish() }
        case .dropped:
          pending.removeValue(forKey: id)
          entry.continuation.finish(
            throwing: MCPStdioError.io("request frame buffer overflow"))
        case .terminated:
          pending.removeValue(forKey: id)
        @unknown default:
          pending.removeValue(forKey: id)
          entry.continuation.finish(
            throwing: MCPStdioError.io("unknown request stream state"))
        }
      } catch {
        await failConnection(error)
        throw error
      }
    case .request(let request):
      let error = MCPStdioError.unexpectedMessage(
        "server-originated request \(request.method) is forbidden")
      await failConnection(error)
      throw error
    }
  }

  private func route(_ notification: MCPWireNotification) throws -> MCPRequestID? {
    switch notification.method {
    case "notifications/progress":
      let params = try MCPProgressParams(json: .object(notification.params))
      if let match = pending.first(where: { $0.value.progressToken == params.progressToken }) {
        return match.key
      }
      if ignoredProgressTokens.contains(params.progressToken) { return nil }
      throw MCPStdioError.unexpectedMessage("unmatched progress token")
    case "notifications/cancelled":
      _ = try MCPMethodRegistry.standard.require(
        notification.method,
        direction: .serverToClientNotification
      )
      let params = try MCPCancelledParams(json: .object(notification.params))
      guard let entry = pending[params.requestID] else {
        // Cancellation can race with an already completed subscription.
        return nil
      }
      guard entry.method == "subscriptions/listen" else {
        throw MCPStdioError.unexpectedMessage(
          "server may only cancel subscriptions/listen on stdio")
      }
      return params.requestID
    default:
      guard let metadataValue = notification.params["_meta"] else {
        throw MCPStdioError.unexpectedMessage(
          "server notification \(notification.method) is missing subscription metadata")
      }
      let metadata = try MCPNotificationMetadata(json: metadataValue)
      guard let id = metadata.subscriptionID else {
        throw MCPStdioError.unexpectedMessage(
          "server notification \(notification.method) is missing subscription id")
      }
      return id
    }
  }

  private func deliverTerminal(_ message: MCPWireMessage, id: MCPRequestID) async {
    guard let entry = pending.removeValue(forKey: id) else {
      if ignoredRequestIDs.contains(id) {
        forgetIgnoredRequest(id)
        return
      }
      await failConnection(
        MCPStdioError.unexpectedMessage("terminal response has unknown id \(id)"))
      return
    }
    switch entry.continuation.yield(message) {
    case .enqueued:
      entry.continuation.finish()
    case .dropped:
      entry.continuation.finish(throwing: MCPStdioError.io("terminal response buffer overflow"))
    case .terminated:
      break
    @unknown default:
      entry.continuation.finish(throwing: MCPStdioError.io("unknown request stream state"))
    }
  }

  private func cancel(id: MCPRequestID, reason: String?) async throws {
    guard let entry = pending.removeValue(forKey: id) else { return }
    rememberCancelled(id: id, progressToken: entry.progressToken)
    guard let writer else {
      entry.continuation.finish(throwing: MCPStdioError.processNotRunning)
      throw MCPStdioError.processNotRunning
    }
    let params = MCPCancelledParams(requestID: id, reason: reason)
    let notification = try MCPWireNotification(
      method: "notifications/cancelled",
      params: params.json.objectValue ?? [:]
    )
    do {
      try await writer.write(.notification(notification))
      entry.continuation.finish(throwing: CancellationError())
    } catch {
      entry.continuation.finish(throwing: error)
      await shutdown()
      throw error
    }
  }

  private func rememberCancelled(id: MCPRequestID, progressToken: MCPProgressToken?) {
    // A reused request ID must replace its old tombstone rather than inheriting its eviction
    // position. The protocol only requires uniqueness among outstanding requests.
    ignoredRequestOrder.removeAll { $0 == id }
    ignoredRequestIDs.insert(id)
    if let oldToken = ignoredProgressTokensByRequest.removeValue(forKey: id) {
      ignoredProgressTokens.remove(oldToken)
    }
    if let progressToken { ignoredProgressTokens.insert(progressToken) }
    if let progressToken { ignoredProgressTokensByRequest[id] = progressToken }
    ignoredRequestOrder.append(id)
    while ignoredRequestOrder.count > maximumIgnoredRequestIDs {
      let evicted = ignoredRequestOrder.removeFirst()
      ignoredRequestIDs.remove(evicted)
      if let progressToken = ignoredProgressTokensByRequest.removeValue(forKey: evicted) {
        ignoredProgressTokens.remove(progressToken)
      }
    }
  }

  private func forgetIgnoredRequest(_ id: MCPRequestID) {
    ignoredRequestIDs.remove(id)
    if let progressToken = ignoredProgressTokensByRequest.removeValue(forKey: id) {
      ignoredProgressTokens.remove(progressToken)
    }
    ignoredRequestOrder.removeAll { $0 == id }
  }

  private func processExited(generation: UInt64, status: Int32) {
    guard generation == self.generation else { return }
    writer = nil
    processExitStatus = status
  }

  private func normalizedWriteFailure(_ error: Error, processBox: MCPProcessBox) async -> Error {
    if let status = await observedProcessExitStatus(processBox: processBox) {
      return MCPStdioError.processExited(status: status)
    }
    return error
  }

  private func observedProcessExitStatus(processBox: MCPProcessBox? = nil) async -> Int32? {
    if let processExitStatus { return processExitStatus }
    guard let process = processBox?.process ?? self.processBox?.process else { return nil }
    if process.isRunning {
      // Foundation can report pipe EOF or EPIPE a scheduling turn before its termination handler
      // is delivered. Give the direct child one bounded turn so the exit status wins when present.
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard !process.isRunning else { return nil }
    process.waitUntilExit()
    return process.terminationStatus
  }

  private func outputEnded(generation: UInt64, error: Error?) async {
    guard generation == self.generation else { return }
    let observedExitStatus = await observedProcessExitStatus()
    let failure: Error
    if let observedExitStatus, !pending.isEmpty {
      failure = MCPStdioError.processExited(status: observedExitStatus)
    } else if let error {
      failure = error
    } else if !pending.isEmpty {
      failure = MCPStdioError.io("stdout closed before pending requests completed")
    } else {
      failure = MCPStdioError.io("stdout closed")
    }
    await failConnection(failure)
  }

  private func failConnection(_ error: Error) async {
    guard !shuttingDown else {
      finishAll(throwing: error)
      return
    }
    shuttingDown = true
    rejectsNewOpensDuringShutdown = false
    let failedWriter = writer
    let failedProcessBox = processBox
    writer = nil
    processBox = nil
    processExitStatus = nil
    generation &+= 1
    finishAll(throwing: error)
    await stopProcess(writer: failedWriter, processBox: failedProcessBox, reason: error)
    finishShutdown()
  }

  private func stopProcess(
    writer: MCPStdioWriter?,
    processBox: MCPProcessBox?,
    reason: Error
  ) async {
    // Stop filling stdin independently of the child lifecycle. A descendant can retain the pipe's
    // read descriptor after the direct child exits, so process termination alone cannot release a
    // full writer.
    writer?.requestClose()
    if let processBox {
      if processBox.process.isRunning { processBox.process.terminate() }
      let exited = await Self.waitForExit(processBox.process, attempts: 10)
      if !exited, processBox.process.isRunning {
        _ = kill(pid_t(processBox.process.processIdentifier), SIGKILL)
        _ = await Self.waitForExit(processBox.process, attempts: 10)
      }
      try? processBox.stdoutPipe.fileHandleForReading.close()
      try? processBox.stderrPipe.fileHandleForReading.close()
    }
    if let writer {
      do {
        try await writer.close()
      } catch {
        if let handler = configuration.diagnosticHandler {
          await handler("stdin close failed during stdio shutdown: \(reason)")
        }
      }
    }
  }

  private func finishShutdown() {
    shuttingDown = false
    rejectsNewOpensDuringShutdown = false
    // Tombstones belong to a single child-process generation. Clear them before a later child can
    // reuse an ID or progress token, otherwise a valid response could be mistaken for a stale one.
    ignoredRequestIDs.removeAll(keepingCapacity: true)
    ignoredProgressTokens.removeAll(keepingCapacity: true)
    ignoredProgressTokensByRequest.removeAll(keepingCapacity: true)
    ignoredRequestOrder.removeAll(keepingCapacity: true)
    let waiters = shutdownWaiters
    shutdownWaiters.removeAll(keepingCapacity: true)
    for waiter in waiters { waiter.resume() }
  }

  private func finishAll(throwing error: Error) {
    let values = Array(pending.values)
    pending.removeAll(keepingCapacity: true)
    for entry in values {
      entry.continuation.finish(throwing: error)
    }
  }
}

// Immutable facade over an actor-isolated runtime. No mutable state is stored
// directly on this reference type.
public final class MCPStdioClientTransport: MCPClientTransport, @unchecked Sendable {
  public let endpointIdentity: String
  private let runtime: MCPStdioClientRuntime

  public init(configuration: MCPStdioClientConfiguration) {
    endpointIdentity = "stdio:\(configuration.executableURL.path)"
    runtime = MCPStdioClientRuntime(configuration: configuration)
  }

  public func open(_ request: MCPWireRequest) async throws -> MCPClientExchange {
    try await runtime.open(request)
  }

  public func shutdown() async {
    await runtime.shutdown()
  }

  deinit {
    let runtime = self.runtime
    Task { await runtime.shutdown() }
  }
}
