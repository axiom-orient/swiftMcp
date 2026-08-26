# MCPTasks

`MCPTasks` implements the `io.modelcontextprotocol/tasks` extension for the strict stateless MCP
`2026-07-28` profile used by SwiftMCP.

Reference input:

- extension repository: `modelcontextprotocol/ext-tasks`
- reviewed commit: `0d0a6bd4c258b35caa3c810a1dd506cf105b1501`
- schema profile: `schema/2026-07-28/schema.ts`

## Scope

Implemented:

- task-aware `tools/call` with `resultType: "task"`
- `tasks/get`
- `tasks/update`
- `tasks/cancel`
- exact task status models
- task input request/response payload preservation
- HTTP `Mcp-Name = params.taskId` descriptor contract
- durable-before-return task creation check
- host-owned durable store interface
- cooperative cancellation acknowledgement semantics
- client capability and server discovery extension helpers

Not implemented in the runtime surface:

- optional `notifications/tasks` delivery over `subscriptions/listen`

The notification wire model is provided, but the existing core subscription filter remains closed to
core notifications. Polling is the normative recovery path and is sufficient for the required task
lifecycle. Adding task subscriptions later requires one generic subscription-extension boundary; it
must not add a Tasks-specific branch to the core subscription reducer.

## Client

```swift
import MCP
import MCPStdioClient
import MCPTasks

let capabilities = try MCPTasksExtension.clientCapabilities()
let configuration = try MCPClientConfiguration(
  implementation: MCPImplementation(name: "example-client", version: "1.0.0"),
  capabilities: capabilities
)
let transport = MCPStdioClientTransport(
  configuration: try MCPStdioClientConfiguration(executableURL: serverURL)
)
let client = try MCPTasksClient(transport: transport, configuration: configuration)

switch try await client.callTool(try MCPCallToolParams(name: "long-work")) {
case .immediate(let result):
  print(result)
case .task(let created):
  var current = try await client.getTask(taskID: created.task.taskID)
  while !current.task.task.status.isTerminal {
    if let interval = current.task.task.pollIntervalMilliseconds?.rawValue,
      let milliseconds = Int64(interval)
    {
      try await Task.sleep(for: .milliseconds(milliseconds))
    }
    current = try await client.getTask(taskID: created.task.taskID)
  }
}
```

For HTTP, construct `MCPHTTPClientTransport` with the same registry used by the Tasks client:

```swift
let transport = MCPHTTPClientTransport(
  configuration: httpConfiguration,
  registry: try MCPTasksExtension.methodRegistry()
)
```

This is required so `tasks/get`, `tasks/update`, and `tasks/cancel` emit `Mcp-Name` with the task ID.
There is no automatic fallback to a transport lacking that routing contract.

## Server

```swift
import MCP
import MCPTasks

var builder = try MCPTasksServer.makeBuilder(
  implementation: MCPImplementation(name: "example-server", version: "1.0.0")
)

builder.setToolResolver { name, _ in name == longWork.name ? longWork : nil }
try builder.register(MCPStandardMethods.listTools) { _, _ in
  MCPListToolsResult(tools: [longWork])
}
try MCPTasksServer.registerCallTool(on: &builder, store: durableStore) {
  params, context, creator in
  guard params.name == longWork.name else { throw MCPRPCError.invalidParams }
  guard let creator else {
    throw MCPRPCError.missingRequiredClientCapabilities(
      "This tool requires durable task execution",
      requiredCapabilities: try MCPTasksExtension.requiredClientCapabilities()
    )
  }
  let taskID = try await creator.nextTaskID()
  let initial = try MCPTask(
    taskID: taskID,
    status: .working,
    createdAt: clock.now,
    lastUpdatedAt: clock.now,
    ttlMilliseconds: MCPJSONNumber(3_600_000),
    pollIntervalMilliseconds: MCPJSONNumber(1_000)
  )
  let result = try await creator.create(.working(initial))
  worker.start(taskID: taskID)
  return .task(result)
}
try MCPTasksServer.registerLifecycle(on: &builder, store: durableStore)
let server = try builder.build()
```

`MCPTaskCreator.create` does not return a handle until the task can be read through the same store
used by `tasks/get`. Its bounded durability policy supports eventually-consistent stores without
allowing an unbounded request.

## Host invariants

1. Task IDs are unguessable and never enumerable.
2. `MCPTaskStore.create` is durable before it returns.
3. Reusing a task ID is rejected.
4. Input request keys are unique for the full task lifetime.
5. Unknown or already-satisfied input responses are ignored by the store.
6. A cancellation acknowledgement records intent only; it does not assert a cancelled terminal state.
7. Task IDs needed after process restart are persisted by the client host.
8. The endpoint retains task state for the advertised TTL.
9. A client without the extension capability never receives `resultType: "task"`.
10. Optional notifications never replace the polling recovery path.

## Verification

Repository qualification must run:

```bash
swift build
swift test
SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh
```

The branch was authored through the GitHub API because the execution environment could not clone
GitHub directly. Until the commands above run against the complete checkout, full repository
qualification remains unverified.
