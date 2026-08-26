# MCPTasks

`MCPTasks` implements the `io.modelcontextprotocol/tasks` extension for the strict stateless MCP
`2026-07-28` profile used by SwiftMCP.

Reference input:

- extension repository: `modelcontextprotocol/ext-tasks`
- reviewed commit: `0d0a6bd4c258b35caa3c810a1dd506cf105b1501`
- schema profile: `schema/2026-07-28/schema.json`

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
- client capability and canonical method registry helpers

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
The Tasks client rejects a registry-reporting transport whose registry differs during construction;
there is no automatic fallback to a transport lacking that routing contract.

## Server

```swift
import MCP
import MCPTasks

var builder = try MCPTasksServer.makeBuilder(
  implementation: MCPImplementation(name: "example-server", version: "1.0.0"),
  taskStore: durableStore
)

builder.setToolResolver { name, _ in name == longWork.name ? longWork : nil }
try builder.register(MCPStandardMethods.listTools) { _, _ in
  MCPListToolsResult(tools: [longWork])
}
try builder.registerCallTool {
  params, context, creator in
  guard params.name == longWork.name else { throw MCPRPCError.invalidParams }
  guard let creator else {
    throw MCPRPCError.missingRequiredClientCapabilities(
      "This tool requires durable task execution",
      requiredCapabilities: try MCPTasksExtension.clientCapabilities()
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
  let result = try await creator.create(try MCPDetailedTask.working(initial))
  worker.start(taskID: taskID)
  return .task(result)
}
let server = try builder.build()
```

`MCPTasksServer.makeBuilder` requires the durable store and installs all lifecycle handlers before
advertising the Tasks extension. This prevents a server from claiming Tasks support while omitting
`tasks/get`, `tasks/update`, or `tasks/cancel`.

`MCPServerBuilder` is not an official-extension installation path. Use
`MCPTasksServer.makeBuilder` and `registerCallTool` so the capability and lifecycle descriptors are
installed as one validated unit. Clients and HTTP transports share the canonical registry returned
by `MCPTasksExtension.methodRegistry()`.

The store receives the request's `MCPAuthorizationContext` on every create, read, update, and
cancel operation. It must enforce task ownership and provide durable storage; the package has no
production in-memory fallback. `MCPTaskCreator.create` reports an explicit ambiguous/orphaned
failure if the store write cannot be confirmed through the authorized read path within the bound.

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
7. Task IDs and task records needed after process restart are persisted by the server host.
8. The endpoint retains task state for the advertised TTL.
9. A client without the extension capability never receives `resultType: "task"`.
10. Optional notifications never replace the polling recovery path.

## Verification

Repository qualification used:

```bash
swift build
swift test
SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh
SWIFT_BUILD_JOBS=1 ./Scripts/verify-tasks-conformance.sh
```

In the current checkout, `swift build`, `swift test`, and the release verification script were
executed successfully. The schema corpus reports explicit skips for external-reference and
unsupported-dialect cases, as required by the self-contained validator profile.

The pinned official Tasks diagnostic is intentionally non-zero in this checkout:
`SWIFT_BUILD_JOBS=1 ./Scripts/verify-tasks-conformance.sh` exits `1`. Seven scenarios fail only
because the alpha.11 wire-schema check rejects valid SEP-2663 `resultType: "task"` envelopes
([upstream issue #424](https://github.com/modelcontextprotocol/conformance/issues/424)).
`tasks-dispatch-and-envelope` also sends an arbitrary object under an unknown `inputResponses` key;
the strict SDK correctly rejects that schema-invalid `InputResponse` value. The official
`tasks-status-notifications` scenario is `SKIPPED`, while `tasks-required-task-error` passes 3/3.
This diagnostic does not establish full official Tasks conformance.
