#if os(macOS)
  @preconcurrency import Foundation
  import Darwin
  import MCP
  import MCPStdioShared

  /// Protocol revisions that Apple's Xcode MCP bridge has been observed to negotiate.
  ///
  /// This is deliberately not a general legacy MCP version table. Add a revision only when an
  /// Xcode release requires it and the adapter's narrow tools-only surface has been qualified.
  public enum MCPXcodeProtocolRevision: String, Sendable, Hashable, CaseIterable {
    case v2024November05 = "2024-11-05"
    case v2025March26 = "2025-03-26"
    case v2025June18 = "2025-06-18"

    /// The newest revision currently observed on the Xcode bridge tools surface.
    public static let preferred: Self = .v2025June18
  }

  public enum MCPXcodeError: Error, Sendable, CustomStringConvertible {
    case launch(String)
    case notConnected
    case processExited(Int32)
    case transport(String)
    case timeout(method: String)
    case unsupportedProtocolVersion(String)
    case missingToolsCapability
    case malformedResponse(String)
    case rpc(code: Int64, message: String, data: MCPJSONValue?)
    case serverRequestNotSupported(String)

    public var description: String {
      switch self {
      case .launch(let message): "Xcode MCP launch failed: \(message)"
      case .notConnected: "Xcode MCP is not connected"
      case .processExited(let status): "Xcode MCP bridge exited with status \(status)"
      case .transport(let message): "Xcode MCP transport failed: \(message)"
      case .timeout(let method): "Xcode MCP request timed out: \(method)"
      case .unsupportedProtocolVersion(let version):
        "Xcode MCP negotiated unsupported protocol version \(version)"
      case .missingToolsCapability: "Xcode MCP server did not advertise tools capability"
      case .malformedResponse(let message): "Malformed Xcode MCP response: \(message)"
      case .rpc(let code, let message, _): "Xcode MCP RPC error \(code): \(message)"
      case .serverRequestNotSupported(let method):
        "Xcode MCP sent unsupported server-originated request \(method)"
      }
    }
  }

  public struct MCPXcodeConnectionInfo: Sendable, Hashable {
    public let protocolRevision: MCPXcodeProtocolRevision
    public let serverInfo: MCPImplementation
    public let capabilities: [String: MCPJSONValue]
    public let instructions: String?
  }

  public struct MCPXcodeToolPage: Sendable, Hashable {
    public let tools: [MCPTool]
    public let nextCursor: String?
  }

  public struct MCPXcodeConfiguration: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]?
    public let currentDirectoryURL: URL?
    public let implementation: MCPImplementation
    public let preferredProtocolRevision: MCPXcodeProtocolRevision
    public let requestTimeout: Duration
    public let diagnosticHandler: (@Sendable (String) async -> Void)?
    public let toolsChangedHandler: (@Sendable () async -> Void)?

    public init(
      executableURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
      arguments: [String] = ["mcpbridge"],
      environment: [String: String]? = nil,
      currentDirectoryURL: URL? = nil,
      implementation: MCPImplementation,
      preferredProtocolRevision: MCPXcodeProtocolRevision = .preferred,
      requestTimeout: Duration = .seconds(30),
      diagnosticHandler: (@Sendable (String) async -> Void)? = nil,
      toolsChangedHandler: (@Sendable () async -> Void)? = nil
    ) throws {
      guard requestTimeout > .zero else {
        throw MCPJSONError.invalidField(field: "requestTimeout", reason: "must be positive")
      }
      guard executableURL.isFileURL else {
        throw MCPJSONError.invalidField(field: "executableURL", reason: "must be a file URL")
      }
      self.executableURL = executableURL
      self.arguments = arguments
      self.environment = environment
      self.currentDirectoryURL = currentDirectoryURL
      self.implementation = implementation
      self.preferredProtocolRevision = preferredProtocolRevision
      self.requestTimeout = requestTimeout
      self.diagnosticHandler = diagnosticHandler
      self.toolsChangedHandler = toolsChangedHandler
    }
  }

  private final class MCPXcodeProcessBox: @unchecked Sendable {
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

  private struct MCPXcodePendingRequest: Sendable {
    let continuation: AsyncThrowingStream<[String: MCPJSONValue], Error>.Continuation
  }

  private enum MCPXcodeCancellationPolicy: Sendable {
    case notifyPeer
    case localOnly
  }

  private enum MCPXcodeLifecycle: Sendable {
    case idle
    case connecting(UInt64)
    case connected(MCPXcodeConnectionInfo)
    case stopping(UInt64, closeAfterStop: Bool)
    case closed
  }

  private struct MCPXcodeStopEffect: Sendable {
    let id: UInt64
    let writer: MCPStdioWriter?
    let processBox: MCPXcodeProcessBox?
  }

  /// A deliberately narrow compatibility boundary for Apple's `xcrun mcpbridge`.
  ///
  /// This is not a general legacy MCP client. It owns only the legacy lifecycle needed to expose
  /// Xcode's tool surface: `initialize`, `notifications/initialized`, `tools/list`, and `tools/call`.
  /// The canonical `MCP` product remains 2026-07-28-only and stateless.
  public actor MCPXcodeClient {
    private static let stdioLimits = MCPStdioLimits.default

    private let configuration: MCPXcodeConfiguration
    private var processBox: MCPXcodeProcessBox?
    private var writer: MCPStdioWriter?
    private var generation: UInt64 = 0
    private static let maximumRetiredRequestIDs = 256

    private var nextRequestID: Int64 = 1
    private var pending: [Int64: MCPXcodePendingRequest] = [:]
    private var retiredRequestIDs: Set<Int64> = []
    private var retiredRequestOrder: [Int64] = []
    private var lifecycle: MCPXcodeLifecycle = .idle
    private var lifecycleTransitionID: UInt64 = 0
    private var connectTask: Task<Void, Never>?
    private var connectWaiters: [UUID: CheckedContinuation<MCPXcodeConnectionInfo, Error>] = [:]
    private var stopCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    public init(configuration: MCPXcodeConfiguration) {
      self.configuration = configuration
    }

    public func connect() async throws -> MCPXcodeConnectionInfo {
      switch lifecycle {
      case .connected(let info):
        return info
      case .closed:
        throw MCPXcodeError.notConnected
      case .stopping(_, closeAfterStop: true):
        throw MCPXcodeError.notConnected
      case .idle, .connecting, .stopping:
        break
      }

      let waiterID = UUID()
      return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
          // Cancellation can race with continuation registration. Re-check here so an early
          // cancellation cannot leave an orphan waiter after the onCancel handler already ran.
          guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
          }
          connectWaiters[waiterID] = continuation
          startConnectionAttemptIfNeeded()
        }
      } onCancel: { [weak self] in
        guard let self else { return }
        Task { await self.cancelConnectionWaiter(waiterID) }
      }
    }

    /// Starts exactly one initialize effect from the idle state. Calls arriving while the previous
    /// process is stopping remain queued and begin a fresh attempt only after teardown commits idle.
    private func startConnectionAttemptIfNeeded() {
      guard !connectWaiters.isEmpty else { return }
      guard case .idle = lifecycle else { return }

      lifecycleTransitionID &+= 1
      let attemptID = lifecycleTransitionID
      lifecycle = .connecting(attemptID)
      connectTask = Task { [weak self] in
        guard let self else { return }
        await self.runConnectionAttempt(attemptID)
      }
    }

    private func runConnectionAttempt(_ attemptID: UInt64) async {
      do {
        let value = try await initializeConnection()
        try Task.checkCancellation()
        finishConnectionAttempt(attemptID, value: value)
      } catch {
        guard case .connecting(let currentAttemptID) = lifecycle,
          currentAttemptID == attemptID
        else { return }
        connectTask = nil
        _ = startStop(failure: error)
      }
    }

    /// Commits the connection before releasing any waiter. This is the only transition to connected.
    private func finishConnectionAttempt(
      _ attemptID: UInt64,
      value: MCPXcodeConnectionInfo
    ) {
      guard case .connecting(let currentAttemptID) = lifecycle,
        currentAttemptID == attemptID
      else { return }

      connectTask = nil
      lifecycle = .connected(value)
      let waiters = Array(connectWaiters.values)
      connectWaiters.removeAll(keepingCapacity: true)
      for waiter in waiters { waiter.resume(returning: value) }
    }

    private func cancelConnectionWaiter(_ waiterID: UUID) {
      guard let waiter = connectWaiters.removeValue(forKey: waiterID) else { return }

      // Commit stopping before releasing the final cancelled waiter. A new caller can therefore never
      // attach itself to an initialize effect that this cancellation has already abandoned.
      if connectWaiters.isEmpty, case .connecting = lifecycle {
        _ = startStop(failure: CancellationError())
      }
      waiter.resume(throwing: CancellationError())
    }

    public func listTools(cursor: String? = nil) async throws -> MCPXcodeToolPage {
      let connection = try await connect()
      try requireToolsCapability(connection)
      var params: [String: MCPJSONValue] = [:]
      if let cursor { params["cursor"] = .string(cursor) }
      let result = try await request(method: "tools/list", params: params)
      let object = try MCPJSONObject(.object(result))
      let tools = try object.requiredArray("tools").map(MCPTool.init(json:))
      return MCPXcodeToolPage(tools: tools, nextCursor: try object.optionalString("nextCursor"))
    }

    /// Calls an Xcode tool and normalizes its legacy result to the modern semantic result model.
    /// The compatibility wire shape never escapes this module.
    public func callTool(
      name: String,
      arguments: [String: MCPJSONValue] = [:]
    ) async throws -> MCPCallToolResult {
      let connection = try await connect()
      try requireToolsCapability(connection)
      guard !name.isEmpty else {
        throw MCPJSONError.invalidField(field: "name", reason: "must not be empty")
      }
      var params: [String: MCPJSONValue] = ["name": .string(name)]
      if !arguments.isEmpty { params["arguments"] = .object(arguments) }
      let result = try await request(method: "tools/call", params: params)
      let object = try MCPJSONObject(.object(result))

      // Xcode has shipped tool results that omit modern structuredContent even when a tool declares
      // outputSchema, but the legacy content array itself is present. Preserve that wire truth; do
      // not manufacture structured data by heuristically parsing text payloads.
      let content = try object.requiredArray("content").map(MCPContentBlock.init(json:))
      return try MCPCallToolResult(
        content: content,
        structuredContent: object.values["structuredContent"],
        isError: try object.optionalBool("isError") ?? false,
        resultType: .complete
      )
    }

    public func close() async {
      guard
        let stopID = startStop(
          failure: MCPXcodeError.notConnected,
          closeAfterStop: true
        )
      else { return }
      await waitForStopCompletion(stopID)
    }

    private func initializeConnection() async throws -> MCPXcodeConnectionInfo {
      try await ensureProcess()
      let result = try await request(
        method: "initialize",
        params: [
          "protocolVersion": .string(configuration.preferredProtocolRevision.rawValue),
          "capabilities": .object([:]),
          "clientInfo": configuration.implementation.json,
        ],
        requiresConnection: false,
        cancellationPolicy: .localOnly
      )
      let object = try MCPJSONObject(.object(result))
      let rawRevision = try object.requiredNonEmptyString("protocolVersion")
      guard let revision = MCPXcodeProtocolRevision(rawValue: rawRevision) else {
        throw MCPXcodeError.unsupportedProtocolVersion(rawRevision)
      }
      let serverInfo = try MCPImplementation(
        json: object.values["serverInfo"] ?? { throw MCPJSONError.missingField("serverInfo") }())
      let capabilities = try object.requiredObject("capabilities")
      guard let tools = capabilities["tools"], case .object = tools else {
        throw MCPXcodeError.missingToolsCapability
      }

      // If the final local waiter disappeared after initialize returned, abandon the connection
      // locally rather than completing the legacy lifecycle for nobody.
      try Task.checkCancellation()
      try await sendNotification(method: "notifications/initialized", params: [:])
      return MCPXcodeConnectionInfo(
        protocolRevision: revision,
        serverInfo: serverInfo,
        capabilities: capabilities,
        instructions: try object.optionalString("instructions")
      )
    }

    private func requireToolsCapability(_ info: MCPXcodeConnectionInfo) throws {
      guard let value = info.capabilities["tools"], case .object = value else {
        throw MCPXcodeError.missingToolsCapability
      }
    }

    private func request(
      method: String,
      params: [String: MCPJSONValue],
      requiresConnection: Bool = true,
      cancellationPolicy: MCPXcodeCancellationPolicy = .notifyPeer
    ) async throws -> [String: MCPJSONValue] {
      if requiresConnection {
        guard case .connected = lifecycle else { throw MCPXcodeError.notConnected }
      }
      guard let writer else { throw MCPXcodeError.notConnected }
      let id = try allocateRequestID()
      let stream = AsyncThrowingStream<[String: MCPJSONValue], Error>.makeStream(
        bufferingPolicy: .bufferingOldest(1))
      pending[id] = MCPXcodePendingRequest(continuation: stream.continuation)

      let envelope: MCPJSONValue = .object([
        "jsonrpc": .string("2.0"),
        // Xcode 26.6 mcpbridge rejects spec-valid string request IDs. Numeric IDs are therefore an
        // explicit Xcode boundary invariant rather than a change to the canonical MCP wire model.
        "id": .number(MCPJSONNumber(id)),
        "method": .string(method),
        "params": .object(params),
      ])
      do {
        try await writer.writeFrame(envelope.encoded(limits: Self.stdioLimits.jsonLimits))
      } catch {
        if let request = pending.removeValue(forKey: id) {
          rememberRetiredRequest(id)
          request.continuation.finish(throwing: error)
        }
        throw MCPXcodeError.transport("write \(method) failed: \(error)")
      }

      do {
        return try await awaitResponse(stream.stream, id: id, method: method)
      } catch is CancellationError {
        switch cancellationPolicy {
        case .localOnly:
          retirePendingRequest(id: id, failure: CancellationError())
        case .notifyPeer:
          // The caller task is already cancelled here. Run the peer notification as an owned
          // unstructured effect so the writer sees a live task, then await it before returning.
          let cancellationEffect = Task { [self] in
            try await cancelRequest(id: id, reason: "client task cancelled")
          }
          do {
            try await cancellationEffect.value
          } catch {
            throw MCPXcodeError.transport(
              "request \(method) was cancelled; cancellation notification failed: \(error)")
          }
        }
        throw CancellationError()
      } catch let error as MCPXcodeError {
        guard case .timeout = error else { throw error }
        switch cancellationPolicy {
        case .localOnly:
          retirePendingRequest(id: id, failure: error)
        case .notifyPeer:
          let cancellationEffect = Task { [self] in
            try await cancelRequest(id: id, reason: "request timed out")
          }
          do {
            try await cancellationEffect.value
          } catch let cancellationError {
            throw MCPXcodeError.transport(
              "request \(method) timed out; cancellation notification failed: \(cancellationError)")
          }
        }
        throw error
      }
    }

    private func awaitResponse(
      _ stream: AsyncThrowingStream<[String: MCPJSONValue], Error>,
      id: Int64,
      method: String
    ) async throws -> [String: MCPJSONValue] {
      try await withThrowingTaskGroup(of: [String: MCPJSONValue].self) { group in
        group.addTask {
          var iterator = stream.makeAsyncIterator()
          guard let value = try await iterator.next() else {
            // Cancellation may make AsyncThrowingStream finish its iterator without preserving
            // the continuation's error. Reclassify that terminal nil while the caller is cancelled
            // so the owning request path can retire the ID and notify the peer.
            try Task.checkCancellation()
            throw MCPXcodeError.transport("response stream ended for request \(id)")
          }
          return value
        }
        group.addTask { [timeout = configuration.requestTimeout] in
          try await ContinuousClock().sleep(for: timeout)
          throw MCPXcodeError.timeout(method: method)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
          throw MCPXcodeError.transport("request race produced no result")
        }
        return first
      }
    }

    private func sendNotification(
      method: String,
      params: [String: MCPJSONValue]
    ) async throws {
      guard let writer else { throw MCPXcodeError.notConnected }
      let envelope: MCPJSONValue = .object([
        "jsonrpc": .string("2.0"),
        "method": .string(method),
        "params": .object(params),
      ])
      do {
        try await writer.writeFrame(envelope.encoded(limits: Self.stdioLimits.jsonLimits))
      } catch {
        throw MCPXcodeError.transport("write \(method) failed: \(error)")
      }
    }

    @discardableResult
    private func retirePendingRequest(id: Int64, failure: Error) -> Bool {
      guard let request = pending.removeValue(forKey: id) else { return false }
      rememberRetiredRequest(id)
      request.continuation.finish(throwing: failure)
      return true
    }

    private func cancelRequest(id: Int64, reason: String) async throws {
      // A response can win the timeout/cancellation race while the actor is suspended. Do not emit a
      // cancellation notification for an id that is no longer an in-flight request.
      guard retirePendingRequest(id: id, failure: CancellationError()) else { return }
      try await sendNotification(
        method: "notifications/cancelled",
        params: ["requestId": .number(MCPJSONNumber(id)), "reason": .string(reason)]
      )
    }

    private func allocateRequestID() throws -> Int64 {
      guard nextRequestID < Int64.max else {
        throw MCPXcodeError.transport("numeric request id space exhausted")
      }
      let value = nextRequestID
      nextRequestID += 1
      return value
    }

    private func rememberRetiredRequest(_ id: Int64) {
      retiredRequestOrder.removeAll { $0 == id }
      retiredRequestIDs.insert(id)
      retiredRequestOrder.append(id)
      while retiredRequestOrder.count > Self.maximumRetiredRequestIDs {
        retiredRequestIDs.remove(retiredRequestOrder.removeFirst())
      }
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

    private func ensureProcess() async throws {
      if let processBox, processBox.process.isRunning { return }
      guard case .connecting = lifecycle else { throw MCPXcodeError.notConnected }

      // mcpbridge is a child-process stdio peer. Ignore SIGPIPE before creating the writer so an
      // Xcode exit becomes an ordinary EPIPE transport failure instead of terminating the host.
      MCPStdioSignalHandling.ignoreSIGPIPE()

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
      let processGeneration = generation
      process.terminationHandler = { [weak self] process in
        guard let self else { return }
        Task {
          await self.processExited(
            generation: processGeneration,
            status: process.terminationStatus
          )
        }
      }
      do {
        try process.run()
      } catch {
        throw MCPXcodeError.launch(String(describing: error))
      }

      let box = MCPXcodeProcessBox(
        process: process,
        stdinPipe: stdinPipe,
        stdoutPipe: stdoutPipe,
        stderrPipe: stderrPipe
      )
      processBox = box
      writer = MCPStdioWriter(handle: stdinPipe.fileHandleForWriting)

      let stdout = MCPStdioIO.lines(
        from: stdoutPipe.fileHandleForReading,
        limits: Self.stdioLimits
      )
      Task { [weak self] in
        guard let self else { return }
        do {
          for try await line in stdout {
            try await self.receive(line, generation: processGeneration)
          }
          await self.outputEnded(generation: processGeneration, error: nil)
        } catch {
          await self.outputEnded(generation: processGeneration, error: error)
        }
      }

      let stderr = MCPStdioIO.lines(
        from: stderrPipe.fileHandleForReading,
        limits: Self.stdioLimits
      )
      Task { [handler = configuration.diagnosticHandler] in
        do {
          for try await line in stderr {
            guard let handler else { continue }
            await handler(String(decoding: line, as: UTF8.self))
          }
        } catch {
          if let handler { await handler("Xcode MCP stderr read failed: \(error)") }
        }
      }
    }

    private func receive(_ data: Data, generation: UInt64) async throws {
      guard generation == self.generation else { return }
      let value = try MCPJSONValue.parse(data, limits: Self.stdioLimits.jsonLimits)
      let envelope = try MCPJSONObject(value)
      guard try envelope.requiredString("jsonrpc") == "2.0" else {
        throw MCPXcodeError.malformedResponse("jsonrpc must equal 2.0")
      }

      // Requests have both method and id. Xcode's supported bridge surface is server-only tools;
      // do not accidentally interpret a future server-originated request as a response.
      if let rawMethod = envelope.values["method"], envelope.values["id"] != nil {
        guard case .string(let method) = rawMethod, !method.isEmpty else {
          throw MCPXcodeError.malformedResponse("request method must be a non-empty string")
        }
        throw MCPXcodeError.serverRequestNotSupported(method)
      }

      if let rawID = envelope.values["id"] {
        guard case .number(let number) = rawID,
          number.isInteger,
          let id = number.int64Value
        else {
          throw MCPXcodeError.malformedResponse("Xcode responses must use integer ids")
        }
        guard let pendingRequest = pending[id] else {
          if retiredRequestIDs.contains(id) {
            return
          }
          throw MCPXcodeError.malformedResponse("response id \(id) has no pending request")
        }
        let rawError = envelope.values["error"]
        let rawResult = envelope.values["result"]
        guard (rawError == nil) != (rawResult == nil) else {
          throw MCPXcodeError.malformedResponse(
            "response must contain exactly one of result or error")
        }
        if let rawError {
          let errorObject = try MCPJSONObject(rawError)
          let codeNumber = try errorObject.requiredNumber("code")
          guard codeNumber.isInteger, let code = codeNumber.int64Value else {
            throw MCPXcodeError.malformedResponse("RPC error code must be an integer")
          }
          let error = MCPXcodeError.rpc(
            code: code,
            message: try errorObject.requiredString("message"),
            data: errorObject.values["data"]
          )
          pending.removeValue(forKey: id)
          rememberRetiredRequest(id)
          pendingRequest.continuation.finish(throwing: error)
          return
        }
        guard let rawResult, case .object(let result) = rawResult else {
          throw MCPXcodeError.malformedResponse("response result must be an object")
        }
        pending.removeValue(forKey: id)
        rememberRetiredRequest(id)
        _ = pendingRequest.continuation.yield(result)
        pendingRequest.continuation.finish()
        return
      }

      if let rawMethod = envelope.values["method"] {
        guard case .string(let method) = rawMethod, !method.isEmpty else {
          throw MCPXcodeError.malformedResponse("notification method must be a non-empty string")
        }
        switch method {
        case "notifications/tools/list_changed":
          if let handler = configuration.toolsChangedHandler { await handler() }
        case "notifications/message":
          if let handler = configuration.diagnosticHandler, let params = envelope.values["params"] {
            await handler("Xcode MCP log: \(params)")
          }
        default:
          if let handler = configuration.diagnosticHandler {
            await handler("Xcode MCP ignored notification: \(method)")
          }
        }
        return
      }

      throw MCPXcodeError.malformedResponse("envelope has neither id nor method")
    }

    private func processExited(generation: UInt64, status: Int32) {
      guard generation == self.generation else { return }
      _ = startStop(failure: MCPXcodeError.processExited(status))
    }

    private func outputEnded(generation: UInt64, error: Error?) {
      guard generation == self.generation else { return }
      _ = startStop(
        failure: error.map { MCPXcodeError.transport(String(describing: $0)) }
          ?? MCPXcodeError.transport("Xcode MCP stdout ended"))
    }

    private func failConnectionWaiters(with error: Error) {
      let waiters = Array(connectWaiters.values)
      connectWaiters.removeAll(keepingCapacity: true)
      for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func waitForStopCompletion(_ stopID: UInt64) async {
      await withCheckedContinuation { continuation in
        guard case .stopping(let currentStopID, _) = lifecycle, currentStopID == stopID else {
          continuation.resume()
          return
        }
        stopCompletionWaiters.append(continuation)
      }
    }

    private func finishStop(_ stopID: UInt64) {
      guard case .stopping(let currentStopID, let closeAfterStop) = lifecycle,
        currentStopID == stopID
      else { return }

      lifecycle = closeAfterStop ? .closed : .idle
      let waiters = stopCompletionWaiters
      stopCompletionWaiters.removeAll(keepingCapacity: true)
      for waiter in waiters { waiter.resume() }

      if !closeAfterStop { startConnectionAttemptIfNeeded() }
    }

    /// Commits the stopping state synchronously, then runs child-process cleanup as one owned effect.
    /// New connect callers can queue while the effect is running but cannot attach to the retired attempt.
    @discardableResult
    private func startStop(failure: Error, closeAfterStop: Bool = false) -> UInt64? {
      switch lifecycle {
      case .closed:
        return nil

      case .stopping(let stopID, let existingCloseAfterStop):
        if closeAfterStop, !existingCloseAfterStop {
          lifecycle = .stopping(stopID, closeAfterStop: true)
          failConnectionWaiters(with: MCPXcodeError.notConnected)
        }
        return stopID

      case .idle, .connecting, .connected:
        break
      }

      lifecycleTransitionID &+= 1
      let stopID = lifecycleTransitionID
      lifecycle = .stopping(stopID, closeAfterStop: closeAfterStop)

      connectTask?.cancel()
      connectTask = nil
      failConnectionWaiters(with: failure)

      generation &+= 1
      let requests = pending.values
      pending.removeAll(keepingCapacity: true)
      retiredRequestIDs.removeAll(keepingCapacity: true)
      retiredRequestOrder.removeAll(keepingCapacity: true)
      for request in requests { request.continuation.finish(throwing: failure) }

      let effect = MCPXcodeStopEffect(id: stopID, writer: writer, processBox: processBox)
      writer = nil
      processBox = nil

      // Teardown is an owned effect and must finish even if the caller releases its last client handle.
      Task { await self.runStopEffect(effect) }
      return stopID
    }

    private func runStopEffect(_ effect: MCPXcodeStopEffect) async {
      // Legacy stdio lifecycle: close stdin first, then allow a bounded graceful exit before TERM/KILL.
      effect.writer?.requestClose()
      do {
        try await effect.writer?.close()
      } catch {
        if let handler = configuration.diagnosticHandler {
          await handler("Xcode MCP stdin close failed: \(error)")
        }
      }

      if let box = effect.processBox {
        let process = box.process
        var exited = await Self.waitForExit(process, attempts: 10)
        if !exited, process.isRunning {
          process.terminate()
          exited = await Self.waitForExit(process, attempts: 10)
        }
        if !exited, process.isRunning {
          _ = kill(pid_t(process.processIdentifier), SIGKILL)
          _ = await Self.waitForExit(process, attempts: 10)
        }
        try? box.stdoutPipe.fileHandleForReading.close()
        try? box.stderrPipe.fileHandleForReading.close()
      }

      finishStop(effect.id)
    }
  }
#endif
