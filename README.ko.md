# SwiftMCP

SwiftMCP는 공식 [MCP `2026-07-28` 명세](https://modelcontextprotocol.io/specification/2026-07-28)와
[schema reference](https://modelcontextprotocol.io/specification/2026-07-28/schema)를 따르는 Swift
6.2 이상용 SDK입니다.

이 SDK는 타입이 있는 Swift client와 server를 위한 엄격한 stateless MCP 프로필을 구현합니다. 외부
SwiftPM 의존성은 없습니다.

English: [README.md](README.md)

## 범위

- MCP `2026-07-28`만 지원합니다. 모든 요청에는 자체 protocol metadata와 capabilities가 포함됩니다.
- HTTP 연결과 stdio 프로세스는 전송 수단일 뿐 MCP session이 아닙니다.
- 제공 범위는 discovery, tools, prompts, resources, completion, progress, cancellation,
  subscriptions, MRTR, cache 계약, 범위가 제한된 JSON Schema 검증입니다.
- `initialize`, session header, legacy transport, migration, downgrade 동작, JSON-RPC batch,
  server-originated request, 자동 OAuth 재시도는 제공하지 않습니다.
- `MCPOAuth`는 선택 기능입니다. HTTP authorization, TLS 종료, 브라우저 UI, callback, credential
  저장, 재시도 정책은 호스트 애플리케이션이 맡습니다.

기본 validator는 local dynamic reference를 포함한 self-contained JSON Schema 2020-12와 draft-07
프로필을 처리합니다. 지원하지 않는 dialect와 해석할 수 없는 외부 reference는 fail-closed로
거부합니다. 다른 validator가 필요하면 호스트가 명시적으로 주입해야 합니다.

## 설치

GitHub에서 SwiftMCP를 추가합니다. 현재 공개 태그는 `0.1.0`입니다.

```swift
dependencies: [
  .package(url: "https://github.com/axiom-orient/swiftMcp.git", from: "0.1.0")
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
| `MCPHTTPClient` / `MCPHTTPServer` | 요청별 HTTP POST와 JSON 또는 SSE 응답 |
| `MCPStdioClient` / `MCPStdioServer` | 자식 프로세스 stdio 전송과 server runner |
| `MCPOAuth` | 선택적인 OAuth client discovery와 token 흐름 |

`MCPHTTPShared`, `MCPStdioShared`, `MCPPlatformCrypto`는 구현 대상입니다.
`mcp-conformance-client`와 `mcp-conformance-server`는 샘플 앱이 아니라 검증 fixture입니다.

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
Origin 정책을 구성하세요. OAuth를 쓸 때 Protected Resource Metadata는 주변 HTTP 애플리케이션이
제공해야 합니다.

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

`verify.sh`는 엄격한 형식 검사, warnings-as-errors Debug·Release build, 전체 test, stdio conformance
smoke를 실행합니다. 이 스크립트는 별도의 SwiftPM 격리 빌드 디렉터리를 사용하며, 저장소의 `.build`를
읽거나 지우거나 바꾸지 않습니다. GitHub Actions도 macOS 14에서 같은 게이트를 실행합니다.

`Scripts/clean.sh`도 저장소 내부의 verification state만 정리하며 `.build`와 `.swiftpm`은 그대로 둡니다.
`.build`, `.swiftpm`, `.verification`, `Artifacts`, 생성된 ZIP 파일, Finder metadata는 커밋하지
마세요.

## 릴리스 점검표

1. `Package.swift`, `Sources/`, `Tests/`, `Scripts/`, `.github/`, `.gitignore`, `.swift-format`,
   두 README, `LICENSE`를 배포 입력으로 검토합니다.
2. 배포할 commit에서 `SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh`를 실행합니다.
3. `git status --short`가 비어 있는지, `git remote get-url origin`이 올바른 GitHub 저장소인지
   확인합니다.
4. 같은 revision의 GitHub Actions가 통과한 뒤 새 semantic version tag를 하나 만들고 push합니다.
   이미 만든 tag를 다른 commit으로 옮기지 마세요.
5. 태그를 만든 commit에서 release note를 작성하고, 작업 공간 ZIP 대신 GitHub가 생성한 source archive를
   사용합니다.

위 확인이 끝난 뒤 tag를 만드는 예시는 다음과 같습니다.

```bash
RELEASE_TAG=0.1.1
git tag -a "$RELEASE_TAG" -m "SwiftMCP $RELEASE_TAG"
git push origin "$RELEASE_TAG"
```

배포를 철회해야 하면 영향을 받는 tag의 배포를 중단하고, 마지막으로 검증한 tag를 안내합니다. 같은
버전으로 다른 commit을 다시 tag하지 마세요.

## 라이선스

SwiftMCP는 [MIT License](LICENSE)로 배포됩니다.
