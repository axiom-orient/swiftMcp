import Foundation

enum MCPStdioTestTimeout: Error {
  case elapsed
}

func withMCPStdioTestTimeout<Value: Sendable>(
  _ timeout: Duration = .seconds(1),
  operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
  try await withThrowingTaskGroup(of: Value.self) { group in
    group.addTask(operation: operation)
    group.addTask {
      try await Task.sleep(for: timeout)
      try Task.checkCancellation()
      throw MCPStdioTestTimeout.elapsed
    }
    defer { group.cancelAll() }
    guard let result = try await group.next() else { throw MCPStdioTestTimeout.elapsed }
    return result
  }
}

func collectMCPStdioTestFrames<Value: Sendable>(
  from frames: AsyncThrowingStream<Value, Error>,
  timeout: Duration = .seconds(1)
) async throws -> [Value] {
  try await withMCPStdioTestTimeout(timeout) {
    var values: [Value] = []
    for try await frame in frames {
      values.append(frame)
    }
    return values
  }
}
