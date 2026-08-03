@preconcurrency import Foundation
import MCP
import MCPStdioShared

/// Framing and JSON limits used by the public stdio server configuration.
public typealias MCPStdioLimits = MCPStdioShared.MCPStdioLimits

public struct MCPStdioServerConfiguration: Sendable {
  public let input: FileHandle
  public let output: FileHandle
  public let errorOutput: FileHandle
  public let limits: MCPStdioLimits
  /// Whether the runner installs the process-wide `SIGPIPE` guard described by
  /// `MCPStdioSignalHandling.ignoreSIGPIPE()`. Disable it only when the host manages signals.
  public let ignoresSIGPIPE: Bool

  public init(
    input: FileHandle = .standardInput,
    output: FileHandle = .standardOutput,
    errorOutput: FileHandle = .standardError,
    limits: MCPStdioLimits = .default,
    ignoresSIGPIPE: Bool = true
  ) {
    self.input = input
    self.output = output
    self.errorOutput = errorOutput
    self.limits = limits
    self.ignoresSIGPIPE = ignoresSIGPIPE
  }
}

private actor MCPStdioServerCoordinator {
  private struct Active: Sendable {
    let exchange: MCPServerExchange
    var task: Task<Void, Never>?
    let token: UUID
  }

  private let server: MCPServer
  private let writer: MCPStdioWriter
  private let errorWriter: MCPStdioWriter
  private let limits: MCPStdioLimits
  private var active: [MCPRequestID: Active] = [:]
  // A terminal frame has been selected but its writer task has not yet returned to this actor to
  // retire the ID. A peer may legally reuse the ID as soon as it receives that frame, so a new
  // request waits for retirement instead of being rejected during this narrow output boundary.
  private var terminalWrites: [MCPRequestID: UUID] = [:]
  private var terminalWriteWaiters: [MCPRequestID: [CheckedContinuation<Void, Never>]] = [:]

  init(
    server: MCPServer,
    writer: MCPStdioWriter,
    errorWriter: MCPStdioWriter,
    limits: MCPStdioLimits
  ) {
    self.server = server
    self.writer = writer
    self.errorWriter = errorWriter
    self.limits = limits
  }

  /// Consumes one client frame.
  ///
  /// A rejected frame is a client-scoped failure and must not end the channel: the peer is told
  /// what happened and the loop keeps serving every other request. Only a condition that makes the
  /// channel itself unusable — a request ID that is already in flight, or a failed write — is
  /// thrown, because after that no response can be routed correctly.
  func receive(_ data: Data) async throws {
    let message: MCPWireMessage
    do {
      message = try MCPWireMessage.decode(data, limits: limits.jsonLimits)
    } catch {
      // The ID is inside the frame that failed to decode, so no response can carry it. JSON-RPC
      // still requires the error to be reported rather than answered with silence or a closed pipe.
      await report("rejected malformed frame: \(error)")
      try await respond(Self.frameError(error), id: nil)
      return
    }
    switch message {
    case .request(let request):
      try await start(request)
    case .notification(let notification):
      guard notification.method == "notifications/cancelled" else {
        // Notifications are unanswerable by definition, so the diagnostic channel is the only
        // place this can surface.
        await report("ignored unaccepted client notification \(notification.method)")
        return
      }
      do {
        let params = try MCPCancelledParams(json: .object(notification.params))
        await cancel(id: params.requestID, reason: params.reason)
      } catch {
        await report("ignored malformed notifications/cancelled: \(error)")
      }
    case .result, .error:
      // Responding to a response would invent a second reply for an ID the peer already owns.
      await report("ignored forbidden client response frame")
    }
  }

  /// Mirrors the HTTP binding's mapping so one malformed frame produces the same JSON-RPC code on
  /// either transport.
  private static func frameError(_ error: Error) -> MCPRPCError {
    guard let json = error as? MCPJSONError else { return .invalidRequest }
    return MCPRPCError(code: -32700, message: "Parse error", data: .string(json.description))
  }

  private func respond(_ error: MCPRPCError, id: MCPRequestID?) async throws {
    try await writer.write(.error(MCPWireErrorResponse(id: id, error: error)))
  }

  func shutdown() async {
    let values = Array(active.values)
    active.removeAll(keepingCapacity: true)
    terminalWrites.removeAll(keepingCapacity: true)
    let waiters = terminalWriteWaiters.values.flatMap { $0 }
    terminalWriteWaiters.removeAll(keepingCapacity: true)
    for waiter in waiters { waiter.resume() }
    // Input termination ends this byte stream. Interrupt any response blocked on a full output
    // pipe, including one whose read descriptor outlives the direct peer process.
    writer.requestClose()
    errorWriter.requestClose()
    for value in values {
      value.task?.cancel()
      await value.exchange.cancel(reason: "stdio input closed")
    }
    for value in values {
      if let task = value.task {
        await task.value
      }
    }
  }

  private func start(_ request: MCPWireRequest) async throws {
    while let existing = active[request.id] {
      guard terminalWrites[request.id] == existing.token else {
        throw MCPStdioError.duplicateRequestID(request.id.description)
      }
      await withCheckedContinuation { continuation in
        terminalWriteWaiters[request.id, default: []].append(continuation)
      }
    }
    let exchange = server.execute(request)
    let token = UUID()
    // Reserve the ID before starting the child task. Task scheduling is eager enough that the
    // request can finish before `Task(...)` returns; a placeholder keeps its cleanup from racing
    // the registration and leaving a stale active entry behind.
    active[request.id] = Active(exchange: exchange, task: nil, token: token)
    let task = Task { [coordinator = self, writer] in
      do {
        for try await frame in exchange.frames {
          try Task.checkCancellation()
          if Self.isTerminal(frame) {
            await coordinator.beginTerminalWrite(id: request.id, token: token)
          }
          try await writer.write(frame)
        }
        await coordinator.finished(id: request.id, token: token)
      } catch let cancellation as MCPServerSubscriptionCancellation {
        await coordinator.beginTerminalWrite(id: request.id, token: token)
        await coordinator.sendSubscriptionCancellation(cancellation, expectedID: request.id)
        await coordinator.finished(id: request.id, token: token)
      } catch is CancellationError {
        await coordinator.finished(id: request.id, token: token)
      } catch {
        await coordinator.report("request \(request.id) output failed: \(error)")
        await coordinator.finished(id: request.id, token: token)
      }
    }
    active[request.id]?.task = task
  }

  private static func isTerminal(_ frame: MCPWireMessage) -> Bool {
    switch frame {
    case .result, .error:
      true
    case .request, .notification:
      false
    }
  }

  private func beginTerminalWrite(id: MCPRequestID, token: UUID) {
    guard active[id]?.token == token else { return }
    terminalWrites[id] = token
  }

  private func sendSubscriptionCancellation(
    _ cancellation: MCPServerSubscriptionCancellation,
    expectedID: MCPRequestID
  ) async {
    guard cancellation.requestID == expectedID else {
      await report(
        "subscription cancellation id \(cancellation.requestID) does not match \(expectedID)")
      return
    }
    do {
      let params = MCPCancelledParams(
        requestID: cancellation.requestID,
        reason: cancellation.reason
      )
      let notification = try MCPWireNotification(
        method: "notifications/cancelled",
        params: params.json.objectValue ?? [:]
      )
      try await writer.write(.notification(notification))
    } catch {
      await report("subscription cancellation output failed: \(error)")
    }
  }

  private func cancel(id: MCPRequestID, reason: String?) async {
    guard let value = active.removeValue(forKey: id) else { return }
    finishTerminalWrite(id: id, token: value.token)
    value.task?.cancel()
    await value.exchange.cancel(reason: reason)
  }

  private func finished(id: MCPRequestID, token: UUID) {
    guard active[id]?.token == token else { return }
    active.removeValue(forKey: id)
    finishTerminalWrite(id: id, token: token)
  }

  private func finishTerminalWrite(id: MCPRequestID, token: UUID) {
    guard terminalWrites[id] == token else { return }
    terminalWrites.removeValue(forKey: id)
    let waiters = terminalWriteWaiters.removeValue(forKey: id) ?? []
    for waiter in waiters { waiter.resume() }
  }

  private func report(_ message: String) async {
    do {
      try await errorWriter.writeFrame(Data(message.utf8))
    } catch {
      // stderr is the final diagnostic boundary. It must never be redirected to protocol stdout.
    }
  }
}

public struct MCPStdioServerRunner: Sendable {
  public let server: MCPServer
  public let configuration: MCPStdioServerConfiguration

  public init(server: MCPServer, configuration: MCPStdioServerConfiguration = .init()) {
    self.server = server
    self.configuration = configuration
  }

  public func run() async throws {
    if configuration.ignoresSIGPIPE { MCPStdioSignalHandling.ignoreSIGPIPE() }
    let writer = MCPStdioWriter(handle: configuration.output)
    let errorWriter = MCPStdioWriter(handle: configuration.errorOutput)
    let coordinator = MCPStdioServerCoordinator(
      server: server,
      writer: writer,
      errorWriter: errorWriter,
      limits: configuration.limits
    )
    do {
      for try await line in MCPStdioIO.lines(
        from: configuration.input,
        limits: configuration.limits
      ) {
        try await coordinator.receive(line)
      }
      await coordinator.shutdown()
    } catch {
      await coordinator.shutdown()
      throw error
    }
  }
}
