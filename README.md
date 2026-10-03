# SwiftMCP

Swift 6.2+ SDK for the official [Model Context Protocol (MCP) `2026-07-28`
specification](https://modelcontextprotocol.io/specification/2026-07-28), pinned to upstream
commit [`5f5440b`](https://github.com/modelcontextprotocol/modelcontextprotocol/commit/5f5440bb26a62e2cf3440b92da5a667efa03b267),
and its [schema reference at that commit](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/schema.json).

SwiftMCP implements a strict, stateless MCP profile for typed Swift clients and servers. It has no
external SwiftPM dependencies.
Its canonical product identity is the strict 2026 stateless `MCP` runtime, the independent official
`MCPTasks` extension implementation, and the sealed `MCPXcode` interoperability edge.

한국어 안내: [README.ko.md](README.ko.md)

## Scope

- The `MCP` core is MCP `2026-07-28` only. Every request carries its own protocol metadata and capabilities.
- HTTP connections and stdio processes are transports, not MCP sessions.
- Supported product surface: discovery, tools, prompts, resources, completion, progress,
  cancellation, subscriptions, typed MRTR input (`elicitation`, deprecated `sampling`, deprecated
  `roots`), request-scoped logging, cache contracts, and bounded local JSON Schema validation.
  MRTR keeps `requestState` opaque and separates wire-shape validation from application content
  policy; see [Documentation/MRTR.md](Documentation/MRTR.md).
- `MCPTasks` independently implements the stable `io.modelcontextprotocol/tasks` extension for the
  same 2026-07-28 profile. It owns task lifecycle semantics without adding task state or legacy task
  RPCs to `MCP`. See [Documentation/MCPTasks.md](Documentation/MCPTasks.md).
- The modern core does not include `initialize`, session headers, legacy transports, migration,
  downgrade behavior, JSON-RPC batch, server-originated requests, or automatic OAuth retries.
- `MCPXcode` is the one sealed compatibility boundary: a macOS-only client for Apple's
  `xcrun mcpbridge`. It implements only the legacy handshake and tool RPC surface required by
  qualified Xcode bridge revisions; it does not change `MCPClient` or the 2026 core. See
  [Documentation/XcodeMCP.md](Documentation/XcodeMCP.md).

The built-in validator handles self-contained JSON Schema 2020-12 and draft-07 profiles, including
local dynamic references. Valid schemas that require an unsupported dialect or external reference
resolver are preserved without implicit network access; a host can explicitly supply another
validator when it needs local validation for those schemas.

## Install

Add SwiftMCP from GitHub with the current release tag `0.4.2`. This release includes the independent
`MCPTasks` product, strict stateless core, and the corrected Xcode 26.3+ edge.

```swift
dependencies: [
  .package(url: "https://github.com/axiom-orient/swiftMcp.git", from: "0.4.2")
]
```

Use the `swiftmcp` package identity when selecting products:

```swift
.target(
  name: "MyApp",
  dependencies: [
    .product(name: "MCP", package: "swiftmcp"),
    .product(name: "MCPStdioClient", package: "swiftmcp"),
  ]
)
```

For a local checkout, use a relative path that matches your workspace:

```swift
.package(path: "../swift-mcp-sdk")
```

## Products

| Product | Purpose |
| --- | --- |
| `MCP` | Protocol models, JSON-RPC wire codec, stateless runtime, schema validation, MRTR, subscriptions, and cache contracts |
| `MCPTasks` | Stable `io.modelcontextprotocol/tasks` extension with task-aware tool results plus `tasks/get`, `tasks/update`, and `tasks/cancel` |
| `MCPHTTPClient` / `MCPHTTPServer` | Request-scoped HTTP POST with JSON or SSE responses |
| `MCPStdioClient` / `MCPStdioServer` | Child-process stdio transport and server runner |
| `MCPXcode` | macOS-only narrow adapter for Apple's `xcrun mcpbridge`; legacy lifecycle stays outside the 2026 core |

`MCPHTTPShared` and `MCPStdioShared` are implementation targets.
`mcp-conformance-client` and `mcp-conformance-server` are local verification fixtures, not sample
apps.

## Samples

Runnable examples are maintained separately in
[AxiomSyncMCPSamples](https://github.com/axiom-orient/AxiomSyncMCPSamples), including
`MCPPingPong`. This repository intentionally keeps only the SDK, its tests, and verification
fixtures so the package remains focused.

## Minimal stdio server

```swift
import MCP
import MCPStdioServer

let echo = try MCPTool(
  name: "echo",
  description: "Returns the supplied text.",
  inputSchema: [
    "type": .string("object"),
    "properties": .object(["text": .object(["type": .string("string")])]),
    "required": .array([.string("text")]),
    "additionalProperties": .bool(false),
  ]
)

var builder = try MCPServerBuilder(
  implementation: try MCPImplementation(name: "example-server", version: "1.0.0")
)
builder.setToolResolver { name, _ in name == echo.name ? echo : nil }
try builder.register(MCPStandardMethods.listTools) { _, _ in MCPListToolsResult(tools: [echo]) }
try builder.register(MCPStandardMethods.callTool) { params, _ in
  try MCPCallToolResult(
    content: [.text(MCPTextContent(text: params.arguments["text"]?.stringValue ?? ""))]
  )
}

try await MCPStdioServerRunner(server: builder.build()).run()
```

## Connect a client

For stdio, provide the server executable through host configuration instead of embedding a machine
path in source code:

```swift
import Foundation
import MCP
import MCPStdioClient

guard let serverPath = ProcessInfo.processInfo.environment["MCP_SERVER_PATH"] else {
  fatalError("Set MCP_SERVER_PATH to the MCP server executable.")
}

let transport = MCPStdioClientTransport(
  configuration: try MCPStdioClientConfiguration(executableURL: URL(fileURLWithPath: serverPath))
)
let client = try MCPClient(
  transport: transport,
  configuration: MCPClientConfiguration(
    implementation: try MCPImplementation(name: "example-client", version: "1.0.0"),
    capabilities: MCPClientCapabilities()
  )
)

let tools = try await client.listTools()
print(tools.tools.map(\.name))
await transport.shutdown()
```

For HTTP, use `MCPHTTPClientTransport` with `MCPHTTPClientConfiguration(endpoint:)`. Each request
is a POST and receives either one JSON response or a request-scoped SSE stream.

`MCPHTTPServer` binds to loopback by default. A non-loopback bind needs an explicit authorization
verifier. Put public deployments behind a trusted TLS terminator and configure the Origin policy.


## Xcode MCP

Xcode 26.3+ exposes its tools to external agents through a stdio server launched as `xcrun mcpbridge`.
Use `MCPXcodeClient` when the peer is Xcode; do not route Xcode through the strict 2026 `MCPClient`.

```swift
#if os(macOS)
import MCP
import MCPXcode

let configuration = try MCPXcodeConfiguration(
  implementation: try MCPImplementation(name: "my-agent", version: "1.0.0")
)
let xcode = MCPXcodeClient(configuration: configuration)
let connection = try await xcode.connect()
let tools = try await xcode.listTools()
let result = try await xcode.callTool(name: "XcodeListWindows")
print(connection.protocolRevision, tools.tools.count, result)
await xcode.close()
#endif
```

`MCPXcode` intentionally qualifies only the Xcode-observed revisions `2024-11-05`, `2025-03-26`,
and `2025-06-18`. The current default is `2025-06-18`; Xcode 26.3 uses `2024-11-05`, while the
current Xcode 26.6 qualification accepts `2025-03-26` and `2025-06-18`. Older deployments can pin
the matching qualified revision explicitly. It uses integer JSON-RPC request IDs and exposes only
initialization plus `tools/list` / `tools/call`. `requestTimeout` defaults to `.zero` (disabled), so
long Xcode operations can complete; callers may set a positive timeout or cancel. `ioLimits` is a
host-configurable safety policy, not an MCP frame-size rule. Unsupported bridge behavior fails
explicitly; there is no automatic legacy downgrade or general compatibility runtime.

Live qualification is explicit and test-only. `Documentation/XcodeQualification.md` records the
macOS procedure that runs the production client through a transparent proxy and preserves the raw
`mcpbridge` transcript without adding a generic legacy runtime.

## Verify

For a normal development loop:

```bash
swift build
swift test
```

For the release gate:

```bash
SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh
```

`verify.sh` runs strict formatting, warnings-as-errors Debug and Release builds, the full local test
suite (including MCPTasks and JSON Schema tests), and the local stdio conformance smoke flow. It uses an isolated
SwiftPM scratch directory and never reads, deletes, or replaces the repository’s `.build`; it does
not download external corpora or invoke another SDK.

`Scripts/clean.sh` removes only repository-local verification state; it leaves `.build` and
`.swiftpm` intact. Do not commit `.build`, `.swiftpm`, `.verification`, `Artifacts`, generated ZIP files, or Finder
metadata.

## Release checklist

1. Review the source inputs: `Package.swift`, `Sources/`, `Tests/`, `Scripts/`,
   `.gitignore`, `.swift-format`, both README files, and `LICENSE`.
2. Run `SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh` from the commit intended for release.
3. Confirm `git status --short` is empty and `git remote get-url origin` is the intended GitHub
   repository.
4. Create and push one new semantic version tag when publishing a release. Never move an existing
   tag.
5. Publish release notes from that tagged commit and use GitHub’s generated source archive rather
   than a workspace ZIP.

Existing release tags `0.3.0`, `0.4.0`, `0.4.1`, and `0.4.2` are immutable. Future changes require a new
semantic version; never retag an existing version.

If a release must be withdrawn, stop distribution of the affected tag and direct consumers to the
last verified tag. Do not retag a different commit under the same version.

## License

SwiftMCP is released under the [MIT License](LICENSE).

## GitHub 배포 분류

swiftMcp의 주 제품은 개발자가 import해 MCP client·server를 구성하는 Swift SDK이므로 canonical 조직은 [`axiom-orient`](https://github.com/axiom-orient)다. conformance executable은 패키지 검증과 예제를 위한 보조 표면이다.
