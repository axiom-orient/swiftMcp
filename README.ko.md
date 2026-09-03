# SwiftMCP

SwiftMCP는 공식 [MCP `2026-07-28` 명세](https://modelcontextprotocol.io/specification/2026-07-28)를
따르며, upstream [`5f5440b`](https://github.com/modelcontextprotocol/modelcontextprotocol/commit/5f5440bb26a62e2cf3440b92da5a667efa03b267)
commit과 [그 commit의 schema](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/schema.json)를
고정 기준으로 사용합니다. Swift 6.2 이상용 SDK입니다.

이 SDK는 타입이 있는 Swift client와 server를 위한 엄격한 stateless MCP 프로필을 구현합니다. 외부
SwiftPM 의존성은 없습니다.
Canonical 제품 정체성은 strict 2026 stateless `MCP` runtime + 독립적인 공식 `MCPTasks`
extension implementation + sealed `MCPXcode` interoperability edge입니다.

English: [README.md](README.md)

## 범위

- `MCP` 코어는 MCP `2026-07-28`만 지원합니다. 모든 요청에는 자체 protocol metadata와 capabilities가 포함됩니다.
- HTTP 연결과 stdio 프로세스는 전송 수단일 뿐 MCP session이 아닙니다.
- 제공 범위는 discovery, tools, prompts, resources, completion, progress, cancellation,
  subscriptions, typed MRTR 입력(`elicitation`, deprecated `sampling`, deprecated `roots`),
  request-scoped logging, cache 계약, 범위가 제한된 로컬 JSON Schema 검증입니다.
  MRTR의 `requestState`는 opaque 값으로 보존하며 wire shape 검증과 application content policy를
  분리합니다. 자세한 내용은 [Documentation/MRTR.md](Documentation/MRTR.md)를 참고하세요.
- `MCPTasks`는 같은 2026-07-28 profile의 stable `io.modelcontextprotocol/tasks` extension을
  독립적으로 구현합니다. task lifecycle semantics를 소유하되 `MCP` core에 task state나 legacy
  task RPC를 넣지 않습니다. 자세한 내용은
  [Documentation/MCPTasks.md](Documentation/MCPTasks.md)를 참고하세요.
- modern core에는 `initialize`, session header, legacy transport, migration, downgrade 동작,
  JSON-RPC batch, server-originated request, 자동 OAuth 재시도가 없습니다.
- `MCPXcode`만 유일한 격리된 호환 경계입니다. macOS에서 Apple `xcrun mcpbridge`가 실제로
  요구하는 legacy handshake와 tool RPC만 구현하며 `MCPClient`와 2026 core의 의미를 바꾸지 않습니다.
  자세한 내용은 [Documentation/XcodeMCP.md](Documentation/XcodeMCP.md)를 참고하세요.

기본 validator는 local dynamic reference를 포함한 self-contained JSON Schema 2020-12와 draft-07
프로필을 처리합니다. 지원하지 않는 dialect 또는 외부 reference resolver가 필요한 유효한 schema는
암묵적인 네트워크 접근 없이 보존합니다. 해당 schema를 로컬에서 검증해야 할 때는 호스트가 다른
validator를 명시적으로 주입할 수 있습니다.

## 설치

GitHub에서는 현재 릴리스 태그 `0.4.1`을 사용합니다. 이 릴리스에는 독립적인 `MCPTasks`, strict
stateless core, 수정된 Xcode 26.3+ edge가 함께 포함됩니다.

```swift
dependencies: [
  .package(url: "https://github.com/axiom-orient/swiftMcp.git", from: "0.4.1")
]
```

product를 지정할 때는 `swiftmcp` 패키지 식별자를 사용합니다.

```swift
.target(
  name: "MyApp",
  dependencies: [
    .product(name: "MCP", package: "swiftmcp"),
    .product(name: "MCPStdioClient", package: "swiftmcp"),
  ]
)
```

로컬 체크아웃에서는 작업 공간에 맞는 상대 경로를 사용합니다.

```swift
.package(path: "../swift-mcp-sdk")
```

## 제품

| 제품 | 용도 |
| --- | --- |
| `MCP` | protocol model, JSON-RPC wire codec, stateless runtime, schema validation, MRTR, subscriptions, cache 계약 |
| `MCPTasks` | stable `io.modelcontextprotocol/tasks` extension, task-aware tool result와 `tasks/get`, `tasks/update`, `tasks/cancel` |
| `MCPHTTPClient` / `MCPHTTPServer` | 요청별 HTTP POST와 JSON 또는 SSE 응답 |
| `MCPStdioClient` / `MCPStdioServer` | 자식 프로세스 stdio 전송과 server runner |
| `MCPXcode` | Apple `xcrun mcpbridge` 전용 macOS adapter. legacy lifecycle은 2026 core 밖에 격리 |

`MCPHTTPShared`, `MCPStdioShared`는 구현 대상입니다.
`mcp-conformance-client`, `mcp-conformance-server`는 샘플 앱이 아니라 로컬 검증 fixture입니다.

## 샘플

실행 가능한 예제는 별도 저장소인
[AxiomSyncMCPSamples](https://github.com/axiom-orient/AxiomSyncMCPSamples)에서 관리합니다.
`MCPPingPong`을 포함한 예제는 그곳을 참고하세요. 이 저장소에는 SDK, 테스트, 검증 fixture만 두어
Swift package의 책임을 분명히 합니다.

## 최소 stdio server

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

## client 연결

stdio에서는 소스 코드에 특정 컴퓨터의 경로를 넣지 말고 host 설정으로 server executable을 전달합니다.

```swift
import Foundation
import MCP
import MCPStdioClient

guard let serverPath = ProcessInfo.processInfo.environment["MCP_SERVER_PATH"] else {
  fatalError("MCP_SERVER_PATH에 MCP server executable 경로를 지정하세요.")
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

HTTP에서는 `MCPHTTPClientConfiguration(endpoint:)`으로 `MCPHTTPClientTransport`를 구성합니다.
각 요청은 POST로 전송하며, JSON 응답 하나 또는 요청 범위의 SSE stream을 받습니다.

`MCPHTTPServer`는 기본적으로 loopback에 바인딩합니다. 외부 주소에 바인딩하려면 명시적인
authorization verifier가 필요합니다. 공개 배포에서는 신뢰할 수 있는 TLS terminator 뒤에 두고,
Origin 정책을 구성하세요.


## Xcode MCP

Xcode 26.3+는 `xcrun mcpbridge`로 실행되는 stdio MCP server를 외부 agent에 제공합니다. Xcode peer에는
strict 2026 `MCPClient`가 아니라 `MCPXcodeClient`를 사용합니다.

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

`MCPXcode`는 Xcode에서 실제 관찰된 `2024-11-05`, `2025-03-26`, `2025-06-18`만 qualified
revision으로 허용합니다. Xcode 26.3은 `2024-11-05`, 현재 Xcode 26.6 qualification은
`2025-03-26`과 `2025-06-18`을 사용하며 기본값은 `2025-06-18`입니다. 정수 JSON-RPC request ID를
사용하고 surface도 initialization과 `tools/list` / `tools/call`로 제한합니다. `requestTimeout` 기본값은
`.zero`(비활성)이므로 긴 Xcode 작업이 끝날 수 있으며, caller가 양수 timeout 또는 cancellation을
선택할 수 있습니다. `ioLimits`는 호스트가 조정하는 안전 정책이지 MCP frame-size 규칙이 아닙니다.
자동 legacy downgrade나 범용 compatibility runtime은 없습니다.

실제 Xcode qualification은 명시적으로만 실행합니다. `Documentation/XcodeQualification.md`의
절차는 production client를 test-only 투명 proxy를 통해 실행해 raw `mcpbridge` transcript를
보존하며, 이를 위해 범용 legacy runtime을 추가하지 않습니다.

## 검증

일반 개발 중에는 다음 명령을 사용합니다.

```bash
swift build
swift test
```

배포 전 검증 게이트는 다음과 같습니다.

```bash
SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh
```

`verify.sh`는 엄격한 형식 검사, warnings-as-errors Debug·Release build, 전체 로컬 test
(MCPTasks 및 JSON Schema 테스트 포함), 로컬 stdio conformance smoke를 실행합니다. 별도의 SwiftPM scratch
디렉터리를 사용하며 저장소의 `.build`를 읽거나 지우거나 바꾸지 않습니다. 외부 corpus를
다운로드하거나 다른 SDK를 호출하지 않습니다.

`Scripts/clean.sh`도 저장소 내부의 verification state만 정리하며 `.build`와 `.swiftpm`은 그대로 둡니다.
`.build`, `.swiftpm`, `.verification`, `Artifacts`, 생성된 ZIP 파일, Finder metadata는 커밋하지
마세요.

## 릴리스 점검표

1. `Package.swift`, `Sources/`, `Tests/`, `Scripts/`, `.gitignore`, `.swift-format`,
   두 README, `LICENSE`를 배포 입력으로 검토합니다.
2. 배포할 commit에서 `SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh`를 실행합니다.
3. `git status --short`가 비어 있는지, `git remote get-url origin`이 올바른 GitHub 저장소인지
   확인합니다.
4. 릴리스할 때 새 semantic version tag를 하나 만들고 push합니다. 이미 만든 tag를 다른 commit으로
   옮기지 마세요.
5. 태그를 만든 commit에서 release note를 작성하고, 작업 공간 ZIP 대신 GitHub가 생성한 source archive를
   사용합니다.

기존 릴리스 tag `0.3.0`, `0.4.0`, `0.4.1`은 변경하지 않습니다. 이후 변경은 새 semantic
version을 사용해야 하며, 어느 기존 버전도 다시 tag하지 마세요.

배포를 철회해야 하면 영향을 받는 tag의 배포를 중단하고, 마지막으로 검증한 tag를 안내합니다. 같은
버전으로 다른 commit을 다시 tag하지 마세요.

## 라이선스

SwiftMCP는 [MIT License](LICENSE)로 배포됩니다.
