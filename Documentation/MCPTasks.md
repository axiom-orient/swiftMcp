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

Intentionally absent from the runtime surface:

- optional `notifications/tasks` delivery over `subscriptions/listen`
- task-specific subscription additions

Polling through `tasks/get` is a complete recovery path for the required lifecycle. No disconnected
notification model is exposed. If task notifications are added later, they must enter through one
generic subscription-extension boundary; do not add a Tasks-specific branch to the core subscription
reducer.

## Wire contract and semantic validation

The immutable `2026-07-28` generated schema leaves `taskId` as a plain string and models `ttlMs` /
`pollIntervalMs` as JSON safe integers without a sign restriction. SwiftMCP accepts every
mathematical integer in the inclusive interoperable range
`-9007199254740991...9007199254740991`, including `-1`, and rejects only non-integers or values
outside that range. A host that wants non-negative producer values may apply that as a local policy;
it is not imposed by this protocol model. Invalid task IDs remain protocol errors, and server-
generated task IDs must be unguessable.

Server-side creation remains a separate authority boundary: the default generator uses UUIDs, custom
generators MUST preserve sufficient entropy, and the durable store MUST bind every operation to the
request authorization context. `createdAt` and `lastUpdatedAt` accept this exact RFC3339-style
internet timestamp subset: `YYYY-MM-DD'T'HH:mm:ss`, optionally followed by 1–9 fractional digits,
then uppercase `Z` or a numeric `±HH:MM` offset. Invalid calendar dates/times, variable-width
fields, lowercase `z`, and invalid offsets are rejected; this is not a claim to accept every ISO 8601
form.
The upstream schema/semantic mismatch is recorded in `UNRESOLVED.md` instead of hidden behind a
compatibility fallback.

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
      let milliseconds = Int64(interval), milliseconds > 0
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

## Contract ownership

Tasks does not define a second MRTR wire model. `MCPInputRequest` and `MCPInputResponse` in the core
`MCP` target are the single typed authority for task `inputRequests` / `inputResponses`, including
elicitation, sampling, and roots. The Tasks layer owns only task lifecycle semantics such as status,
TTL, update, cancellation, and store behavior.

## Verification commands

When qualification is desired, the repository exposes these existing commands:

```bash
swift build
swift test
SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh
```

The official `modelcontextprotocol/conformance` runner is available as a diagnostic tool, but its
Tasks scenarios are currently unscored requirements and upstream issue #424 can report false
wire-schema failures for valid `resultType: "task"` responses. `MCPTasksTests` therefore own the
local extension contract, while `Scripts/verify.sh` protects the package boundary and the strict
2026 core. The runner and its schema corpus are not installed or vendored here, and this package
does not claim that the external Tasks qualification has passed.
