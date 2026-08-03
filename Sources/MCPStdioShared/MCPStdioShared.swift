@preconcurrency import Foundation
import MCP

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

// The installation flag is process-wide and may be reached from several transports at once.
// Every access is serialized by `lock` and the disposition is installed at most once.
private final class MCPStdioSignalState: @unchecked Sendable {
  static let shared = MCPStdioSignalState()

  private let lock = NSLock()
  private var installed = false

  func installOnce() {
    lock.lock()
    defer { lock.unlock() }
    guard !installed else { return }
    installed = true
    signal(SIGPIPE, SIG_IGN)
  }
}

public enum MCPStdioSignalHandling {
  /// Makes writes to a closed pipe fail with `EPIPE` instead of terminating the process.
  ///
  /// A stdio peer that exits closes the pipe this process writes to. The default disposition of
  /// `SIGPIPE` is termination, so the failure would kill the host before `MCPStdioWriter` could
  /// report it. A pipe has no per-descriptor equivalent of the socket `SO_NOSIGPIPE` option, so the
  /// only available guarantee is the process-wide disposition.
  ///
  /// This is idempotent and is installed automatically by the stdio server runner and client
  /// transport. A host that manages signals itself can opt out through the transport configuration
  /// and is then responsible for keeping `SIGPIPE` from terminating the process.
  public static func ignoreSIGPIPE() {
    MCPStdioSignalState.shared.installOnce()
  }
}

public enum MCPStdioError: Error, Sendable, Equatable, CustomStringConvertible {
  case lineTooLarge(limit: Int)
  case truncatedFrame
  case embeddedNewline
  case processNotRunning
  case processAlreadyRunning
  case duplicateRequestID(String)
  case unexpectedMessage(String)
  case io(String)
  case processExited(status: Int32)

  public var description: String {
    switch self {
    case .lineTooLarge(let limit): "stdio frame exceeds \(limit) bytes"
    case .truncatedFrame: "stdio ended with an unterminated JSON frame"
    case .embeddedNewline: "stdio JSON frame contains an embedded newline"
    case .processNotRunning: "stdio child process is not running"
    case .processAlreadyRunning: "stdio child process is already running"
    case .duplicateRequestID(let id): "duplicate stdio request id \(id)"
    case .unexpectedMessage(let message): "unexpected stdio message: \(message)"
    case .io(let message): "stdio I/O error: \(message)"
    case .processExited(let status): "stdio child process exited with status \(status)"
    }
  }
}

public struct MCPStdioLimits: Sendable, Hashable {
  public let maximumFrameBytes: Int
  public let readChunkBytes: Int
  public let jsonLimits: MCPJSONLimits

  public init(
    maximumFrameBytes: Int = MCPJSONLimits.default.maximumDocumentBytes,
    readChunkBytes: Int = 16_384,
    jsonLimits: MCPJSONLimits = .default
  ) throws {
    guard maximumFrameBytes > 0 else {
      throw MCPJSONError.invalidField(field: "maximumFrameBytes", reason: "must be positive")
    }
    guard readChunkBytes > 0 else {
      throw MCPJSONError.invalidField(field: "readChunkBytes", reason: "must be positive")
    }
    try jsonLimits.validate()
    self.maximumFrameBytes = maximumFrameBytes
    self.readChunkBytes = readChunkBytes
    self.jsonLimits = jsonLimits
  }

  public static let `default` = MCPStdioLimits(
    uncheckedMaximumFrameBytes: MCPJSONLimits.default.maximumDocumentBytes,
    readChunkBytes: 16_384,
    jsonLimits: .default
  )

  private init(
    uncheckedMaximumFrameBytes: Int,
    readChunkBytes: Int,
    jsonLimits: MCPJSONLimits
  ) {
    maximumFrameBytes = uncheckedMaximumFrameBytes
    self.readChunkBytes = readChunkBytes
    self.jsonLimits = jsonLimits
  }
}

public struct MCPStdioLineFramer: Sendable {
  private var buffer = Data()
  private let maximumFrameBytes: Int

  public init(maximumFrameBytes: Int) throws {
    guard maximumFrameBytes > 0 else {
      throw MCPJSONError.invalidField(field: "maximumFrameBytes", reason: "must be positive")
    }
    self.maximumFrameBytes = maximumFrameBytes
  }

  public mutating func append(_ chunk: Data) throws -> [Data] {
    guard buffer.count <= maximumFrameBytes - min(chunk.count, maximumFrameBytes) else {
      throw MCPStdioError.lineTooLarge(limit: maximumFrameBytes)
    }
    buffer.append(chunk)
    var frames: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var frame = Data(buffer[..<newline])
      buffer.removeSubrange(...newline)
      if frame.last == 0x0D { frame.removeLast() }
      guard !frame.contains(0x0D) else {
        throw MCPStdioError.embeddedNewline
      }
      guard frame.count <= maximumFrameBytes else {
        throw MCPStdioError.lineTooLarge(limit: maximumFrameBytes)
      }
      if frame.isEmpty { continue }
      frames.append(frame)
    }
    guard buffer.count <= maximumFrameBytes else {
      throw MCPStdioError.lineTooLarge(limit: maximumFrameBytes)
    }
    return frames
  }

  public mutating func finish() throws {
    guard buffer.isEmpty else { throw MCPStdioError.truncatedFrame }
  }
}

// FileHandle writes can block indefinitely when a child or an inherited descendant leaves stdin
// open without consuming it. This queue owns every descriptor operation and uses nonblocking writes
// plus bounded poll intervals, keeping Swift's cooperative executor free and allowing `close()` to
// interrupt a partially written frame without depending on any particular peer process exiting.
private final class MCPStdioWriteCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
}

private final class MCPStdioWriterIO: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.modelcontextprotocol.swift.stdio.writer")
  private let stateLock = NSLock()
  private var handle: FileHandle?
  private var preparedForNonblockingWrites = false
  private var closeRequested = false

  init(handle: FileHandle) {
    self.handle = handle
  }

  func requestClose() {
    stateLock.lock()
    closeRequested = true
    stateLock.unlock()
  }

  func write(_ data: Data) async throws {
    let cancellation = MCPStdioWriteCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        queue.async { [self] in
          do {
            try writeOnQueue(data, cancellation: cancellation)
            continuation.resume()
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      // A writer operation can be blocked in poll(2) while the peer is not consuming stdout. The
      // cancellation flag is checked on every bounded poll interval, so cancelling one request's
      // write releases that request without closing the shared descriptor for other requests.
      cancellation.cancel()
    }
  }

  func close() async throws {
    requestClose()
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      queue.async { [self] in
        guard let handle else {
          continuation.resume()
          return
        }
        self.handle = nil
        do {
          try handle.close()
          continuation.resume()
        } catch {
          continuation.resume(throwing: MCPStdioError.io(String(describing: error)))
        }
      }
    }
  }

  private func writeOnQueue(_ data: Data, cancellation: MCPStdioWriteCancellation) throws {
    guard let handle, !isCloseRequested else {
      throw MCPStdioError.io("writer is closed")
    }
    guard !cancellation.isCancelled else { throw CancellationError() }
    let descriptor = handle.fileDescriptor
    if !preparedForNonblockingWrites {
      let flags = fcntl(descriptor, F_GETFL, 0)
      guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw MCPStdioError.io(mcpStdioErrnoDescription())
      }
      preparedForNonblockingWrites = true
    }

    var offset = 0
    while offset < data.count {
      guard !isCloseRequested else { throw MCPStdioError.io("writer is closed") }
      guard !cancellation.isCancelled else { throw CancellationError() }
      let written = data.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return 0 }
        return mcpStdioWrite(
          descriptor,
          baseAddress.advanced(by: offset),
          data.count - offset
        )
      }
      if written > 0 {
        offset += written
        continue
      }
      if written == 0 {
        throw MCPStdioError.io("descriptor write returned zero bytes")
      }

      let writeErrno = errno
      if writeErrno == EINTR { continue }
      guard writeErrno == EAGAIN || writeErrno == EWOULDBLOCK else {
        throw MCPStdioError.io(String(cString: strerror(writeErrno)))
      }
      try waitUntilWritable(descriptor, cancellation: cancellation)
    }
  }

  private func waitUntilWritable(
    _ descriptor: Int32,
    cancellation: MCPStdioWriteCancellation
  ) throws {
    while true {
      guard !isCloseRequested else { throw MCPStdioError.io("writer is closed") }
      guard !cancellation.isCancelled else { throw CancellationError() }
      var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
      let result = poll(&pollDescriptor, nfds_t(1), 50)
      if result > 0 {
        guard pollDescriptor.revents & Int16(POLLNVAL) == 0 else {
          throw MCPStdioError.io("writer descriptor is invalid")
        }
        return
      }
      if result == 0 { continue }
      let pollErrno = errno
      if pollErrno == EINTR { continue }
      throw MCPStdioError.io(String(cString: strerror(pollErrno)))
    }
  }

  private var isCloseRequested: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return closeRequested
  }
}

// Keep CPU-bound JSON encoding off the writer actor. The writer must remain able to close its
// descriptor while a large frame is being encoded or cancelled.
private actor MCPStdioFrameEncoder {
  func encode(_ message: MCPWireMessage) throws -> Data {
    try Task.checkCancellation()
    return try message.encoded()
  }
}

public actor MCPStdioWriter {
  private let io: MCPStdioWriterIO
  private let encoder = MCPStdioFrameEncoder()
  private var nextEncodingID: UInt64 = 0
  private var activeEncodings: [UInt64: Task<Data, Error>] = [:]

  public init(handle: FileHandle) {
    io = MCPStdioWriterIO(handle: handle)
  }

  public func write(_ message: MCPWireMessage) async throws {
    let encoder = self.encoder
    let encodingTask = Task.detached(priority: Task.currentPriority) {
      try await encoder.encode(message)
    }
    nextEncodingID &+= 1
    let encodingID = nextEncodingID
    activeEncodings[encodingID] = encodingTask
    defer { activeEncodings.removeValue(forKey: encodingID) }
    let data = try await withTaskCancellationHandler {
      try await encodingTask.value
    } onCancel: {
      encodingTask.cancel()
    }
    try Task.checkCancellation()
    try await writeFrame(data)
  }

  public func writeFrame(_ data: Data) async throws {
    guard !data.contains(0x0A), !data.contains(0x0D) else {
      throw MCPStdioError.embeddedNewline
    }
    var framed = data
    framed.append(0x0A)
    try await io.write(framed)
  }

  package nonisolated func requestClose() {
    io.requestClose()
  }

  public func close() async throws {
    for task in activeEncodings.values { task.cancel() }
    activeEncodings.removeAll(keepingCapacity: true)
    try await io.close()
  }
}

private func mcpStdioWrite(
  _ descriptor: Int32,
  _ bytes: UnsafeRawPointer,
  _ count: Int
) -> Int {
  #if canImport(Darwin)
    Darwin.write(descriptor, bytes, count)
  #elseif canImport(Glibc)
    Glibc.write(descriptor, bytes, count)
  #endif
}

private func mcpStdioRead(
  _ descriptor: Int32,
  _ bytes: UnsafeMutableRawPointer,
  _ count: Int
) -> Int {
  #if canImport(Darwin)
    return Darwin.read(descriptor, bytes, count)
  #elseif canImport(Glibc)
    return Glibc.read(descriptor, bytes, count)
  #endif
}

private func mcpStdioDuplicate(_ descriptor: Int32) -> Int32 {
  #if canImport(Darwin)
    return Darwin.dup(descriptor)
  #elseif canImport(Glibc)
    return Glibc.dup(descriptor)
  #else
    return -1
  #endif
}

private func mcpStdioClose(_ descriptor: Int32) {
  #if canImport(Darwin)
    _ = Darwin.close(descriptor)
  #elseif canImport(Glibc)
    _ = Glibc.close(descriptor)
  #endif
}

private func mcpStdioReaderHandle(from handle: FileHandle) throws -> FileHandle {
  let duplicatedDescriptor = mcpStdioDuplicate(handle.fileDescriptor)
  guard duplicatedDescriptor >= 0 else {
    throw MCPStdioError.io(mcpStdioErrnoDescription())
  }
  let descriptorFlags = fcntl(duplicatedDescriptor, F_GETFD, 0)
  guard descriptorFlags >= 0,
    fcntl(duplicatedDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
  else {
    let message = mcpStdioErrnoDescription()
    mcpStdioClose(duplicatedDescriptor)
    throw MCPStdioError.io(message)
  }
  return FileHandle(fileDescriptor: duplicatedDescriptor, closeOnDealloc: true)
}

private func mcpStdioErrnoDescription() -> String {
  String(cString: strerror(errno))
}

// A dispatch read source observes both bytes and EOF even when the writer closed before this reader
// was installed. Readiness is checked with a zero-timeout poll before every read, so a quiet peer
// never occupies a Swift cooperative-executor thread and the caller's descriptor flags are not
// changed.
private final class MCPStdioLineReaderState: @unchecked Sendable {
  private let lock = NSLock()
  private var handle: FileHandle?
  private var source: DispatchSourceRead?
  private let readChunkBytes: Int
  private var framer: MCPStdioLineFramer
  private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
  private var finished = false

  init(
    handle: FileHandle,
    limits: MCPStdioLimits,
    continuation: AsyncThrowingStream<Data, Error>.Continuation
  ) throws {
    self.handle = handle
    readChunkBytes = limits.readChunkBytes
    framer = try MCPStdioLineFramer(maximumFrameBytes: limits.maximumFrameBytes)
    self.continuation = continuation
  }

  func start() {
    guard let handle else {
      finish(throwing: MCPStdioError.io("stdio read handle was released"))
      return
    }
    continuation?.onTermination = { [weak self] _ in self?.stop() }
    let descriptor = handle.fileDescriptor
    let source = DispatchSource.makeReadSource(
      fileDescriptor: descriptor,
      queue: DispatchQueue(label: "org.modelcontextprotocol.swift.stdio.reader")
    )
    source.setEventHandler { [self] in consumeAvailableBytes(from: descriptor) }
    source.setCancelHandler { [self] in closeReaderHandle() }
    lock.lock()
    guard !finished else {
      lock.unlock()
      source.cancel()
      return
    }
    self.source = source
    lock.unlock()

    // `DispatchSourceRead` does not reliably deliver an event for a pipe that reached EOF before
    // the source was resumed on every supported Foundation/libdispatch combination. A single drain
    // closes that installation race; later activity is handled by the source.
    consumeAvailableBytes(from: descriptor)
    lock.lock()
    let shouldResume = !finished && self.source != nil
    lock.unlock()
    guard shouldResume else {
      source.cancel()
      source.resume()
      return
    }
    source.resume()
  }

  private func consumeAvailableBytes(from descriptor: Int32) {
    var buffer = [UInt8](repeating: 0, count: readChunkBytes)
    let requestedBytes = buffer.count
    while true {
      var readiness = pollfd(
        fd: descriptor,
        events: Int16(POLLIN) | Int16(POLLHUP) | Int16(POLLERR),
        revents: 0
      )
      let pollResult = poll(&readiness, nfds_t(1), 0)
      if pollResult == 0 { return }
      if pollResult < 0 {
        if errno == EINTR { continue }
        finish(throwing: MCPStdioError.io(mcpStdioErrnoDescription()))
        return
      }
      let count = buffer.withUnsafeMutableBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return 0 }
        return mcpStdioRead(descriptor, baseAddress, requestedBytes)
      }
      if count > 0 {
        guard append(Data(buffer.prefix(count))) else { return }
        continue
      }
      if count == 0 {
        finishAtEOF()
        return
      }
      let readErrno = errno
      if readErrno == EINTR { continue }
      if readErrno == EAGAIN || readErrno == EWOULDBLOCK { return }
      finish(throwing: MCPStdioError.io(String(cString: strerror(readErrno))))
      return
    }
  }

  private func finishAtEOF() {
    do {
      lock.lock()
      guard !finished else {
        lock.unlock()
        return
      }
      try framer.finish()
      lock.unlock()
      finish(throwing: nil)
    } catch {
      lock.unlock()
      finish(throwing: error)
    }
  }

  private func append(_ chunk: Data) -> Bool {
    let lines: [Data]
    do {
      lock.lock()
      guard !finished else {
        lock.unlock()
        return false
      }
      lines = try framer.append(chunk)
      lock.unlock()
    } catch {
      lock.unlock()
      finish(throwing: error)
      return false
    }

    for line in lines {
      lock.lock()
      let current = finished ? nil : continuation
      lock.unlock()
      guard let current else { return false }
      switch current.yield(line) {
      case .enqueued:
        continue
      case .dropped:
        finish(throwing: MCPStdioError.io("stdio line stream buffer overflow"))
        return false
      case .terminated:
        stop()
        return false
      @unknown default:
        finish(throwing: MCPStdioError.io("unknown stdio line stream state"))
        return false
      }
    }
    return true
  }

  private func finish(throwing error: Error?) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    let current = continuation
    continuation = nil
    let source = self.source
    self.source = nil
    lock.unlock()

    if let source {
      source.cancel()
    } else {
      closeReaderHandle()
    }
    if let error {
      current?.finish(throwing: error)
    } else {
      current?.finish()
    }
  }

  private func stop() {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    finished = true
    continuation = nil
    let source = self.source
    self.source = nil
    lock.unlock()
    if let source {
      source.cancel()
    } else {
      closeReaderHandle()
    }
  }

  private func closeReaderHandle() {
    lock.lock()
    let handle = self.handle
    self.handle = nil
    lock.unlock()
    try? handle?.close()
  }
}

public enum MCPStdioIO {
  public static func lines(
    from handle: FileHandle,
    limits: MCPStdioLimits = .default
  ) -> AsyncThrowingStream<Data, Error> {
    let pair = AsyncThrowingStream<Data, Error>.makeStream(
      bufferingPolicy: .bufferingNewest(256))
    do {
      // The caller owns the supplied FileHandle. A reader-owned duplicate prevents process teardown
      // or another transport from closing/reusing the descriptor while this dispatch source is
      // still draining it, and keeps the caller's blocking/nonblocking flags unchanged.
      let readerHandle = try mcpStdioReaderHandle(from: handle)
      let state = try MCPStdioLineReaderState(
        handle: readerHandle,
        limits: limits,
        continuation: pair.continuation
      )
      state.start()
    } catch {
      pair.continuation.finish(throwing: error)
    }
    return pair.stream
  }
}
