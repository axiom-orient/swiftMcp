# SwiftMCP

Swift 6.2+ SDK for the official [Model Context Protocol (MCP) `2026-07-28`
specification](https://modelcontextprotocol.io/specification/2026-07-28), pinned to upstream
commit [`5f5440b`](https://github.com/modelcontextprotocol/modelcontextprotocol/commit/5f5440bb26a62e2cf3440b92da5a667efa03b267),
and its [schema reference at that commit](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/schema.json).

SwiftMCP implements a strict, stateless MCP profile for typed Swift clients and servers. It has no
external SwiftPM dependencies.

한국어 안내: [README.ko.md](README.ko.md)

## Scope

- MCP `2026-07-28` only. Every request carries its own protocol metadata and capabilities.
- HTTP connections and stdio processes are transports, not MCP sessions.
- Supported product surface: discovery, tools, prompts, resources, completion, progress,
  cancellation, subscriptions, MRTR, cache contracts, bounded JSON Schema validation, and the
  optional `MCPTasks` product.
- `MCPTasks` implements the Stable 2026-07-28 Tasks extension with request-scoped capability and
  authorization checks. A host-owned durable store is required; there is no production in-memory
  fallback. See [Documentation/MCPTasks.md](Documentation/MCPTasks.md).
- Not included: `initialize`, session headers, legacy transports, migration, downgrade behavior,
  JSON-RPC batch, server-originated requests, or automatic OAuth retries.
- `MCPOAuth` is optional. HTTP authorization, TLS termination, browser UI, callbacks, credential
  storage, and retry policy remain host responsibilities.

The built-in validator handles self-contained JSON Schema 2020-12 and draft-07 profiles, including
local dynamic references. Unsupported dialects and unresolved external references fail closed; a
host can explicitly supply another validator.

### Breaking wire-code API

`MCPRPCError.code` is an `MCPRPCErrorCode`, not an `Int64`. This preserves every wire-valid
mathematical integer, including values outside `Int64`, and retains its exact JSON number lexeme.
Use `error.code.rawValue` for the exact wire number or `error.code.int64Value` when an `Int64?` is
appropriate. Integer literals and the existing `MCPRPCError(code: Int64, ...)` initializer remain
available for ordinary error construction.

## Install

Add SwiftMCP from GitHub. The current repository tag is `0.1.3`.

```swift
dependencies: [
  .package(url: "https://github.com/axiom-orient/swiftMcp.git", from: "0.1.3")
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
| `MCPTasks` | Stable 2026-07-28 Tasks extension models, client helpers, and durable-store-bound server lifecycle |
| `MCPHTTPClient` / `MCPHTTPServer` | Request-scoped HTTP POST with JSON or SSE responses |
| `MCPStdioClient` / `MCPStdioServer` | Child-process stdio transport and server runner |
| `MCPOAuth` | Optional OAuth client discovery and token flow |

`MCPHTTPShared`, `MCPStdioShared`, and `MCPPlatformCrypto` are implementation targets.
`mcp-conformance-client`, `mcp-conformance-server`, and `mcp-json-schema-corpus` are verification
fixtures, not sample apps.

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
verifier. Put public deployments behind a trusted TLS terminator, configure the Origin policy, and
provide OAuth Protected Resource Metadata in the surrounding HTTP application when OAuth is used.

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

`verify.sh` runs strict formatting, warnings-as-errors Debug and Release builds, the full test suite,
the pinned JSON Schema 2020-12 corpus, the stdio conformance smoke flow, and external SDK
conformance. It uses isolated SwiftPM and corpus directories and never reads, deletes, or replaces
the repository’s `.build`. The corpus runner validates the self-contained profile and reports
external references or unsupported dialects as explicit skips. Set `MCP_JSON_SCHEMA_CORPUS_PATH` to
a local checkout to avoid downloading the pinned corpus commit
[`fb7372e`](https://github.com/json-schema-org/JSON-Schema-Test-Suite/commit/fb7372e8763a1417bddc65fa4c911b3e79b57b65).

The external SDK conformance gate verifies both directions against a pinned official Python SDK
revision: `mcp-conformance-client --http` drives a stateless HTTP reference server, and the SDK's
own client drives this repository's HTTP conformance server. This cross-checks the wire format
against an ecosystem reference implementation, not only against itself. The SDK environment is
provisioned in an isolated venv; point `MCP_PYTHON_SDK_VENV` at a pre-built venv to reuse it
without downloading.

`Scripts/clean.sh` removes only repository-local verification state; it leaves `.build` and
`.swiftpm` intact. Do not commit `.build`, `.swiftpm`, `.verification`, `Artifacts`, generated ZIP files, or Finder
metadata.

## Release checklist

1. Review the source inputs: `Package.swift`, `Sources/`, `Tests/`, `Scripts/`,
   `.gitignore`, `.swift-format`, both README files, and `LICENSE`.
2. Run `SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh` from the commit intended for release.
3. Confirm `git status --short` is empty and `git remote get-url origin` is the intended GitHub
   repository.
4. Confirm the pinned MCP and JSON Schema corpus revisions used by the gate, then create and push
   one new semantic version tag. Never move an existing tag.
5. Publish release notes from that tagged commit and use GitHub’s generated source archive rather
   than a workspace ZIP.

Example tag commands, after the checks above:

```bash
RELEASE_TAG=0.1.4
git tag -a "$RELEASE_TAG" -m "SwiftMCP $RELEASE_TAG"
git push origin "$RELEASE_TAG"
```

If a release must be withdrawn, stop distribution of the affected tag and direct consumers to the
last verified tag. Do not retag a different commit under the same version.

## License

SwiftMCP is released under the [MIT License](LICENSE).
