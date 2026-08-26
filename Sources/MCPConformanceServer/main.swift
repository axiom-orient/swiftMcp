import Foundation
import MCP
import MCPHTTPServer
import MCPStdioServer
import MCPTasks

private struct StderrDiagnostics: MCPDiagnosticSink {
  func record(_ event: MCPDiagnosticEvent) async {
    let fields = event.fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(
      separator: " ")
    FileHandle.standardError.write(Data("\(event.level.rawValue) \(event.id) \(fields)\n".utf8))
  }
}

private enum ConformanceServerError: Error, CustomStringConvertible {
  case usage(String)

  var description: String {
    switch self {
    case .usage(let message): message
    }
  }
}

private enum LaunchMode {
  case stdio
  case http(bindAddress: String, port: UInt16)

  init(arguments: [String]) throws {
    guard !arguments.isEmpty else {
      self = .stdio
      return
    }
    guard arguments.count == 3, arguments[0] == "--http" else {
      throw ConformanceServerError.usage(
        "usage: mcp-conformance-server [--http <ipv4-address> <port>]"
      )
    }
    guard let port = UInt16(arguments[2]) else {
      throw ConformanceServerError.usage("port must be an integer between 0 and 65535")
    }
    self = .http(bindAddress: arguments[1], port: port)
  }
}

private actor ConformanceMutationHooks {
  private var server: MCPServer?

  func install(server: MCPServer) {
    self.server = server
  }

  func notifyToolsChanged() async throws {
    guard let server else {
      throw MCPClientError.transport("conformance mutation hooks are not installed")
    }
    try await server.notifyToolsChanged()
  }
}

private actor ConformanceTaskIDGenerator: MCPTaskIDGenerating {
  private var nextValue = 0

  func nextTaskID() async throws -> String {
    nextValue += 1
    return "conformance-task-\(nextValue)"
  }
}

/// A deterministic process-local fixture store. Production applications must provide their own
/// durable implementation; this actor exists only so the conformance executable can exercise the
/// public Tasks lifecycle without a hidden store default.
private actor ConformanceTaskStore: MCPTaskStore {
  private var tasks: [String: MCPDetailedTask] = [:]

  func create(
    _ task: MCPDetailedTask,
    authorization: MCPAuthorizationContext
  ) async throws {
    _ = authorization
    guard tasks[task.task.taskID] == nil else { throw MCPRPCError.invalidParams }
    tasks[task.task.taskID] = task
  }

  func task(
    taskID: String,
    authorization: MCPAuthorizationContext
  ) async throws -> MCPDetailedTask? {
    _ = authorization
    return tasks[taskID]
  }

  func update(
    taskID: String,
    inputResponses: [String: MCPJSONValue],
    authorization: MCPAuthorizationContext
  ) async throws -> Bool {
    _ = authorization
    guard let current = tasks[taskID] else { return false }
    guard current.task.status == .inputRequired,
      let pending = current.inputRequests
    else { return true }

    var answered = Set<String>()
    for (key, value) in inputResponses {
      guard let rawRequest = pending[key] else { continue }
      let response: MCPElicitationResult
      do {
        response = try MCPElicitationResult(json: value)
        let request = try MCPElicitationRequest(json: rawRequest)
        try request.params.validate(result: response)
      } catch {
        throw MCPRPCError.invalidParams
      }
      answered.insert(key)
    }
    guard !answered.isEmpty else { return true }

    let remaining = pending.filter { !answered.contains($0.key) }
    if remaining.isEmpty {
      tasks[taskID] = try completedTask(
        from: current,
        result: [
          "content": .array([
            MCPTextContent(text: "Task input accepted").json
          ])
        ]
      )
    } else {
      let base = try updatedTask(current.task, status: .inputRequired)
      tasks[taskID] = try MCPDetailedTask.inputRequired(base, inputRequests: remaining)
    }
    return true
  }

  func requestCancellation(
    taskID: String,
    authorization: MCPAuthorizationContext
  ) async throws -> Bool {
    _ = authorization
    guard let current = tasks[taskID] else { return false }
    guard !current.task.status.isTerminal else { return true }
    tasks[taskID] = try MCPDetailedTask.cancelled(try updatedTask(current.task, status: .cancelled))
    return true
  }

  func complete(taskID: String, result: [String: MCPJSONValue]) async {
    guard let current = tasks[taskID], !current.task.status.isTerminal else { return }
    do {
      tasks[taskID] = try completedTask(from: current, result: result)
    } catch {
      reportTransitionFailure(taskID: taskID, error: error)
    }
  }

  func fail(taskID: String, error: MCPRPCError) async {
    guard let current = tasks[taskID], !current.task.status.isTerminal else { return }
    do {
      let task = try updatedTask(current.task, status: .failed)
      tasks[taskID] = try MCPDetailedTask.failed(task, error: error)
    } catch {
      reportTransitionFailure(taskID: taskID, error: error)
    }
  }

  private func completedTask(
    from current: MCPDetailedTask,
    result: [String: MCPJSONValue]
  ) throws -> MCPDetailedTask {
    try MCPDetailedTask.completed(
      try updatedTask(current.task, status: .completed),
      result: result
    )
  }

  private func updatedTask(_ task: MCPTask, status: MCPTaskStatus) throws -> MCPTask {
    try MCPTask(
      taskID: task.taskID,
      status: status,
      createdAt: task.createdAt,
      lastUpdatedAt: "2026-08-26T00:00:01Z",
      ttlMilliseconds: task.ttlMilliseconds,
      pollIntervalMilliseconds: task.pollIntervalMilliseconds
    )
  }

  private func reportTransitionFailure(taskID: String, error: Error) {
    FileHandle.standardError.write(
      Data("fixture task transition failed taskId=\(taskID) error=\(error)\n".utf8)
    )
  }
}

private enum ConformanceTaskFixture {
  static let createdAt = "2026-08-26T00:00:00Z"
  static let pollInterval = MCPJSONNumber(50)

  static func workingTask(taskID: String) throws -> MCPDetailedTask {
    let task = try MCPTask(
      taskID: taskID,
      status: .working,
      createdAt: createdAt,
      lastUpdatedAt: createdAt,
      ttlMilliseconds: nil,
      pollIntervalMilliseconds: pollInterval
    )
    return try MCPDetailedTask.working(task)
  }

  static func inputTask(
    taskID: String,
    keys: [String]
  ) throws -> MCPDetailedTask {
    let task = try MCPTask(
      taskID: taskID,
      status: .inputRequired,
      createdAt: createdAt,
      lastUpdatedAt: createdAt,
      ttlMilliseconds: nil,
      pollIntervalMilliseconds: pollInterval
    )
    let requests = try Dictionary(
      uniqueKeysWithValues: keys.map { key in
        (
          key,
          MCPElicitationRequest(
            params: try MCPElicitationParams(
              mode: .form,
              message: "Provide \(key)",
              requestedSchema: [
                "type": .string("object"),
                "properties": .object([
                  "name": .object(["type": .string("string")]),
                  "confirm": .object(["type": .string("boolean")]),
                ]),
                "required": .array([.string("confirm")]),
              ]
            )
          )
        )
      })
    return try MCPDetailedTask.inputRequired(
      task,
      inputRequests: requests.mapValues(\.json)
    )
  }
}

private func missingTasksCapabilityError() -> MCPRPCError {
  .missingRequiredClientCapabilities(
    "Client did not declare the Tasks extension required by this tool",
    requiredCapabilities: try? MCPTasksExtension.clientCapabilities()
  )
}

@main
enum MCPConformanceServer {
  static func main() async throws {
    let mode = try LaunchMode(arguments: Array(CommandLine.arguments.dropFirst()))
    let hooks = ConformanceMutationHooks()
    let cache = try MCPCachePolicy(ttlMilliseconds: 1_000, scope: .public)
    let echo = try MCPTool(
      name: "echo",
      description: "Deterministic conformance echo tool.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "text": .object(["type": .string("string")])
        ]),
        "required": .array([.string("text")]),
        "additionalProperties": .bool(false),
      ]
    )
    let wait = try MCPTool(
      name: "wait",
      description: "Cancellable delay used to verify timeout recovery.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )
    let streamingElicitation = try MCPTool(
      name: "test_streaming_elicitation",
      description: "Returns a response without emitting independent server requests.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )
    let logging = try MCPTool(
      name: "test_logging_tool",
      description: "Exercises the request-scoped logging boundary.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )
    let triggerToolChange = try MCPTool(
      name: "test_trigger_tool_change",
      description: "Publishes a tools/list_changed notification to active subscriptions.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )
    let missingCapability = try MCPTool(
      name: "test_missing_capability",
      description: "Returns the standard missing-client-capability error.",
      inputSchema: [
        "type": .string("object"),
        "additionalProperties": .bool(false),
      ]
    )

    let greet = try MCPTool(
      name: "greet",
      description: "Synchronous greeting used by the Tasks conformance scenarios.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "name": .object(["type": .string("string")])
        ]),
        "required": .array([.string("name")]),
        "additionalProperties": .bool(false),
      ]
    )
    let slowCompute = try MCPTool(
      name: "slow_compute",
      description: "Creates a durable task for a bounded computation.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "seconds": .object([
            "type": .string("integer"),
            "minimum": .number(MCPJSONNumber(0)),
          ]),
          "label": .object(["type": .string("string")]),
        ]),
        "required": .array([.string("seconds")]),
        "additionalProperties": .bool(false),
      ]
    )
    let failingJob = try MCPTool(
      name: "failing_job",
      description: "Completes as a task with a tool execution error.",
      inputSchema: ["type": .string("object"), "additionalProperties": .bool(false)]
    )
    let protocolErrorJob = try MCPTool(
      name: "protocol_error_job",
      description: "Completes as a failed task with a protocol-level error.",
      inputSchema: ["type": .string("object"), "additionalProperties": .bool(false)]
    )
    let confirmDelete = try MCPTool(
      name: "confirm_delete",
      description: "Waits for an elicitation response before completing.",
      inputSchema: [
        "type": .string("object"),
        "properties": .object([
          "filename": .object(["type": .string("string")])
        ]),
        "required": .array([.string("filename")]),
        "additionalProperties": .bool(false),
      ]
    )
    let multiInput = try MCPTool(
      name: "multi_input",
      description: "Waits for two independent elicitation responses.",
      inputSchema: ["type": .string("object"), "additionalProperties": .bool(false)]
    )
    let testToolWithTask = try MCPTool(
      name: "test_tool_with_task",
      description: "Exercises MRTR input followed by task creation.",
      inputSchema: ["type": .string("object"), "additionalProperties": .bool(false)]
    )
    let tools = [
      echo, wait, streamingElicitation, logging, triggerToolChange, missingCapability,
      greet, slowCompute, failingJob, protocolErrorJob, confirmDelete, multiInput,
      testToolWithTask,
    ]

    let taskStore = ConformanceTaskStore()
    let taskIDs = ConformanceTaskIDGenerator()
    var builder = try MCPTasksServer.makeBuilder(
      implementation: try MCPImplementation(name: "mcp-conformance-server", version: "1.0.0"),
      taskStore: taskStore,
      instructions: "Deterministic MCP 2026-07-28 strict conformance fixture.",
      idGenerator: taskIDs
    )
    builder.setToolResolver { name, _ in
      tools.first { $0.name == name }
    }
    builder.enableToolListChanged()
    try builder.register(MCPStandardMethods.listTools) { _, _ in
      MCPListToolsResult(tools: tools, cache: cache)
    }
    try builder.registerCallTool { params, context, creator in
      switch params.name {
      case "echo":
        guard case .string(let text)? = params.arguments["text"] else {
          return .immediate(
            try MCPCallToolResult(
              content: [.text(MCPTextContent(text: "invalid echo request"))],
              isError: true
            ))
        }
        try await context.progress?.report(progress: 0.5, total: 1, message: "half")
        try await context.progress?.report(progress: 1, total: 1, message: "done")
        return .immediate(
          try MCPCallToolResult(
            content: [.text(MCPTextContent(text: text))],
            structuredContent: .object(["text": .string(text)])
          ))

      case "wait":
        try await Task.sleep(for: .seconds(2))
        return .immediate(
          try MCPCallToolResult(
            content: [.text(MCPTextContent(text: "wait completed"))]
          ))

      case "test_streaming_elicitation":
        return .immediate(
          try MCPCallToolResult(
            content: [.text(MCPTextContent(text: "stream observed: result frames only"))]
          ))

      case "test_logging_tool":
        return .immediate(
          try MCPCallToolResult(
            content: [.text(MCPTextContent(text: "logging evaluated"))]
          ))

      case "test_trigger_tool_change":
        try await hooks.notifyToolsChanged()
        return .immediate(
          try MCPCallToolResult(
            content: [.text(MCPTextContent(text: "tools_list_changed published"))]
          ))

      case "test_missing_capability":
        throw MCPRPCError(
          code: -32021,
          message: "Missing required client capability sampling",
          data: .object([
            "requiredCapabilities": .object(["sampling": .object([:])])
          ])
        )

      case "greet":
        let name: String
        if case .string(let value)? = params.arguments["name"] {
          name = value
        } else {
          name = "World"
        }
        return .immediate(
          try MCPCallToolResult(
            content: [.text(MCPTextContent(text: "Hello, \(name)!"))]
          )
        )

      case "slow_compute":
        let seconds: Int64
        if case .number(let value)? = params.arguments["seconds"] {
          seconds = value.int64Value ?? 0
        } else {
          seconds = 0
        }
        let label: String
        if case .string(let value)? = params.arguments["label"] {
          label = value
        } else {
          label = "computation"
        }
        let immediate = try MCPCallToolResult(
          content: [.text(MCPTextContent(text: "Computed \(label)"))]
        )
        guard seconds > 0, let creator else { return .immediate(immediate) }
        let taskID = try await creator.nextTaskID()
        let handle = try await creator.create(ConformanceTaskFixture.workingTask(taskID: taskID))
        let result = immediate.json.objectValue ?? [:]
        Task.detached {
          do {
            try await Task.sleep(for: .seconds(seconds))
            await taskStore.complete(taskID: taskID, result: result)
          } catch is CancellationError {
            // Process shutdown can cancel fixture workers after the response is complete.
          } catch {
            FileHandle.standardError.write(
              Data("fixture slow_compute worker failed taskId=\(taskID) error=\(error)\n".utf8)
            )
          }
        }
        return .task(handle)

      case "failing_job":
        guard let creator else { throw missingTasksCapabilityError() }
        let taskID = try await creator.nextTaskID()
        let handle = try await creator.create(ConformanceTaskFixture.workingTask(taskID: taskID))
        Task.detached {
          do {
            try await Task.sleep(for: .seconds(1))
            let result = try MCPCallToolResult(
              content: [.text(MCPTextContent(text: "job failed"))],
              isError: true
            )
            await taskStore.complete(taskID: taskID, result: result.json.objectValue ?? [:])
          } catch is CancellationError {
            // Process shutdown can cancel fixture workers after the response is complete.
          } catch {
            FileHandle.standardError.write(
              Data("fixture failing_job worker failed taskId=\(taskID) error=\(error)\n".utf8)
            )
          }
        }
        return .task(handle)

      case "protocol_error_job":
        guard let creator else { throw missingTasksCapabilityError() }
        let taskID = try await creator.nextTaskID()
        let handle = try await creator.create(ConformanceTaskFixture.workingTask(taskID: taskID))
        Task.detached {
          do {
            try await Task.sleep(for: .seconds(1))
            await taskStore.fail(
              taskID: taskID,
              error: MCPRPCError(code: -32603, message: "fixture protocol failure")
            )
          } catch is CancellationError {
            // Process shutdown can cancel fixture workers after the response is complete.
          } catch {
            FileHandle.standardError.write(
              Data(
                "fixture protocol_error_job worker failed taskId=\(taskID) error=\(error)\n".utf8)
            )
          }
        }
        return .task(handle)

      case "confirm_delete":
        guard let creator else {
          return .immediate(
            try MCPCallToolResult(
              content: [.text(MCPTextContent(text: "confirmation required"))]
            )
          )
        }
        let taskID = try await creator.nextTaskID()
        let detailed = try ConformanceTaskFixture.inputTask(
          taskID: taskID,
          keys: ["confirmation"]
        )
        return .task(try await creator.create(detailed))

      case "multi_input":
        guard let creator else {
          return .immediate(
            try MCPCallToolResult(
              content: [.text(MCPTextContent(text: "input required"))]
            )
          )
        }
        let taskID = try await creator.nextTaskID()
        let detailed = try ConformanceTaskFixture.inputTask(
          taskID: taskID,
          keys: ["first", "second"]
        )
        return .task(try await creator.create(detailed))

      case "test_tool_with_task":
        guard let creator else { throw missingTasksCapabilityError() }
        if params.inputResponses.isEmpty {
          let request = try MCPElicitationRequest(
            params: MCPElicitationParams(
              mode: .form,
              message: "What is your name?",
              requestedSchema: [
                "type": .string("object"),
                "properties": .object([
                  "name": .object(["type": .string("string")])
                ]),
                "required": .array([.string("name")]),
              ]
            )
          )
          return .immediate(
            try MCPCallToolResult(
              resultType: .inputRequired,
              inputRequests: ["user_name": request],
              requestState: "conformance-mrtr"
            )
          )
        }
        let userName: String
        if case .string(let value)? = params.inputResponses["user_name"]?.content?["name"] {
          userName = value
        } else {
          userName = "unknown"
        }
        let taskID = try await creator.nextTaskID()
        let handle = try await creator.create(ConformanceTaskFixture.workingTask(taskID: taskID))
        Task.detached {
          do {
            let result = try MCPCallToolResult(
              content: [.text(MCPTextContent(text: "Hello, \(userName)!"))]
            )
            await taskStore.complete(taskID: taskID, result: result.json.objectValue ?? [:])
          } catch {
            FileHandle.standardError.write(
              Data(
                "fixture test_tool_with_task worker failed taskId=\(taskID) error=\(error)\n".utf8)
            )
          }
        }
        return .task(handle)

      default:
        return .immediate(
          try MCPCallToolResult(
            content: [.text(MCPTextContent(text: "unknown tool \(params.name)"))],
            isError: true
          ))
      }
    }
    let server = try builder.build(diagnostics: StderrDiagnostics())
    await hooks.install(server: server)
    switch mode {
    case .stdio:
      try await MCPStdioServerRunner(server: server).run()

    case .http(let bindAddress, let port):
      let configuration = try MCPHTTPConfiguration(
        bindAddress: bindAddress,
        port: port,
        endpointPath: "/mcp"
      )
      let httpServer = MCPHTTPServer(server: server, configuration: configuration)
      let endpoint = try httpServer.start()
      FileHandle.standardError.write(
        Data("mcp-conformance-server listening at \(endpoint.absoluteString)\n".utf8)
      )
      do {
        while !Task.isCancelled {
          try await Task.sleep(for: .seconds(3_600))
        }
      } catch is CancellationError {
        // Cancellation is the graceful in-process shutdown path.
      }
      await httpServer.shutdown()
    }
  }
}
