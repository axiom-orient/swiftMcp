# SwiftMCP

Swift 6.2+ SDK for the official [MCP `2026-07-28` specification](https://modelcontextprotocol.io/specification/2026-07-28)
and [schema reference](https://modelcontextprotocol.io/specification/2026-07-28/schema).
SwiftMCP implements one strict stateless profile for typed MCP servers and clients.

한국어 안내: [README.ko.md](README.ko.md)

## Start here

SwiftMCP is a Swift Package with no external SwiftPM dependencies. It declares macOS 13+ and iOS
16+ as its Apple platform baseline.

```swift
dependencies: [
  .package(url: "https://github.com/<owner>/swift-mcp-sdk.git", from: "0.1.0")
]
```

Replace `<owner>` and `0.1.0` with the published repository owner and an existing release tag.

For a local checkout:

```swift
.package(path: "../swift-mcp-sdk")
```

## Products

| Product | Purpose |
| --- | --- |
| `MCP` | Protocol models, JSON-RPC wire codec, stateless runtime, schema validation, MRTR, subscriptions, and cache contracts |
| `MCPStdioClient` / `MCPStdioServer` | Child-process stdio transport and server runner |
| `MCPHTTPClient` / `MCPHTTPServer` | Request-scoped HTTP POST with JSON or SSE responses |
| `MCPOAuth` | Optional OAuth client discovery and token flow |

`MCPHTTPShared`, `MCPStdioShared`, and `MCPPlatformCrypto` are implementation targets. The
`mcp-conformance-client` and `mcp-conformance-server` executables are verification fixtures.

## Protocol boundary

- Supports MCP `2026-07-28` only.
- Every request carries its own protocol metadata and capabilities.
- HTTP connections and stdio processes are not MCP sessions.
- No `initialize`, session headers, legacy transports, migration, downgrade retry, JSON-RPC batch,
  server-originated request, or automatic OAuth retry.
- HTTP authorization, TLS termination, browser UI, callbacks, credential storage, and replay policy
  belong to the host application.

The default schema validator supports self-contained JSON Schema 2020-12 and draft-07 profiles,
including local dynamic references. Unsupported dialects and external references fail closed. A host
can inject a different validator explicitly.

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

## Client example

```swift
import Foundation
import MCP
import MCPStdioClient

let transport = MCPStdioClientTransport(
  configuration: try MCPStdioClientConfiguration(
    executableURL: URL(fileURLWithPath: "/absolute/path/to/mcp-server")
  )
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

For HTTP, replace the transport with `MCPHTTPClientTransport` and an
`MCPHTTPClientConfiguration(endpoint:)`. The client sends each request as a POST and accepts either a
single JSON response or a request-scoped SSE stream.

## HTTP deployment

`MCPHTTPServer` binds to `127.0.0.1` by default. A non-loopback bind requires an explicit authorization
verifier. Put public deployments behind a trusted TLS terminator, configure the Origin policy, and
provide OAuth Protected Resource Metadata in the host HTTP application when OAuth is used.

The optional `x-mcp-header` tool binding is strict by default: a declared `Mcp-Param-*` value must match
the request body, or the server returns HTTP 400 with JSON-RPC error `-32020`.

## Verify locally

```bash
swift build
swift test

./Scripts/clean.sh
SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh
```

The release gate checks the strict protocol surface, formatting, warnings-as-errors builds, the full
test suite, release targets, and the stdio conformance smoke flow. GitHub Actions runs the same gate on
macOS 14.

Do not commit `.build`, `.swiftpm`, `.verification`, or `Artifacts`.

For a first GitHub publication, review and commit `Package.swift`, `Sources/`, `Tests/`, `Scripts/`,
`.github/`, `.gitignore`, `.swift-format`, both README files, and `LICENSE`. Add the remote and push a
real tag only after replacing the placeholders with the actual repository owner and release version:

```bash
git add Package.swift Sources Tests Scripts .github .gitignore .swift-format README.md README.ko.md LICENSE
git commit -m "Initial SwiftMCP release"
git remote add origin https://github.com/<owner>/swift-mcp-sdk.git
git push -u origin main
git tag -a 0.1.0 -m "SwiftMCP 0.1.0"
git push origin 0.1.0
```

## License

SwiftMCP is released under the [MIT License](LICENSE).
