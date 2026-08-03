# SwiftMCP

Swift 6.2 이상에서 [MCP 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28)와
[공식 schema reference](https://modelcontextprotocol.io/specification/2026-07-28/schema)에 맞춰
stateless 프로토콜을 구현할 수 있는 SDK입니다.

English: [README.md](README.md)

## 한눈에 보기

| 항목 | 내용 |
| --- | --- |
| 프로토콜 | MCP `2026-07-28`만 지원 |
| 전송 | newline-delimited stdio, Streamable HTTP POST(JSON 또는 request-scoped SSE) |
| 플랫폼 선언 | macOS 13 이상, iOS 16 이상 |
| 의존성 | 외부 Swift Package 의존성 없음 |
| 라이선스 | [MIT License](LICENSE) |

## 무엇을 제공하나요?

- `MCP`: JSON-RPC wire codec, 타입 모델, 요청 metadata, `server/discover`, tools, prompts,
  resources, completion, progress, cancellation, subscriptions, MRTR, cache, JSON Schema 검증
- `MCPStdioClient` / `MCPStdioServer`: 자식 프로세스 기반 stdio client와 server
- `MCPHTTPClient` / `MCPHTTPServer`: 요청별 HTTP POST와 JSON/SSE 응답
- `MCPOAuth`: 선택적인 OAuth client 흐름. MCP core나 일반 stdio/HTTP 사용에 필수는 아닙니다.

`MCPHTTPShared`, `MCPStdioShared`, `MCPPlatformCrypto`는 구현 target이며 공개 product가 아닙니다.
`mcp-conformance-client`와 `mcp-conformance-server`는 저장소 검증에 사용하는 실행 파일입니다.

## 가장 중요한 경계

SwiftMCP는 이전 요청이나 연결에 남은 상태를 바탕으로 동작하지 않습니다. 각 요청에는 protocol version,
client capabilities, client 정보와 필요한 `_meta`가 함께 들어갑니다. HTTP 연결이나 stdio 프로세스는
MCP session이 아닙니다.

다음 기능은 이 패키지의 범위에 포함하지 않습니다.

- `initialize`, `notifications/initialized`, protocol session, `MCP-Session-Id`
- legacy transport, migration, version downgrade/retry, HTTP GET stream/resume
- JSON-RPC batch, server-originated request, 자동 OAuth retry
- OAuth authorization server, browser UI, callback 수신, credential 저장
- roots·sampling·logging handler 구현

### JSON Schema 정책

기본 validator는 self-contained JSON Schema 2020-12와 draft-07 프로필을 지원합니다. local
`$dynamicAnchor`·`$dynamicRef`는 해석하지만, 외부 참조나 지원하지 않는 dialect는 자동으로 가져오지
않고 거부합니다. 다른 resolver나 validator가 필요하면 host가 명시적으로 주입해야 합니다.

서버가 광고한 tool의 schema를 안전하게 컴파일하지 못하면 `MCPClient.listTools()`는 해당 tool만
제외하고 나머지 tool과 pagination 결과는 유지합니다.

### HTTP 정책

`MCPHTTPServer`는 기본적으로 `127.0.0.1`에 바인딩합니다. 외부 주소에 바인딩하려면 명시적인
authorization verifier가 필요합니다. TLS 종료, 사용자 인증, Protected Resource Metadata discovery는
[MCP authorization 명세](https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization/authorization-server-discovery)에
따라 host가 담당합니다.

`x-mcp-header`를 선언한 tool은 인자가 있을 때 `Mcp-Param-*` 헤더를 사용합니다. 기본 설정에서는
헤더가 본문과 일치하지 않거나 필요한 헤더가 빠지면 HTTP 400과 JSON-RPC `-32020`을 반환합니다.

## 설치

### 로컬 체크아웃

```swift
dependencies: [
  .package(path: "../swift-mcp-sdk")
]

targets: [
  .target(
    name: "MyApp",
    dependencies: [
      .product(name: "MCP", package: "swift-mcp-sdk"),
      .product(name: "MCPStdioClient", package: "swift-mcp-sdk"),
    ]
  )
]
```

### GitHub 공개 후

저장소를 GitHub에 올린 뒤 `<owner>`를 실제 소유자로 바꾸고, 실제로 존재하는 시맨틱 버전 태그를
사용합니다.

```swift
dependencies: [
  .package(
    url: "https://github.com/<owner>/swift-mcp-sdk.git",
    from: "0.1.0"
  )
]
```

`from: "0.1.0"`은 예시입니다. 게시할 때 만든 tag로 바꿔야 합니다.

## 최소 stdio 서버

아래 코드는 `echo` tool 하나를 등록한 stdio server입니다. `tools/list`와 `tools/call`을 함께
등록하고, resolver가 현재 tool schema를 반환하도록 구성합니다.

```swift
import MCP
import MCPStdioServer

let echo = try MCPTool(
  name: "echo",
  description: "Returns the supplied text.",
  inputSchema: [
    "type": .string("object"),
    "properties": .object([
      "text": .object(["type": .string("string")])
    ]),
    "required": .array([.string("text")]),
    "additionalProperties": .bool(false),
  ]
)

var builder = try MCPServerBuilder(
  implementation: try MCPImplementation(name: "example-server", version: "1.0.0")
)
builder.setToolResolver { name, _ in name == echo.name ? echo : nil }

try builder.register(MCPStandardMethods.listTools) { _, _ in
  MCPListToolsResult(tools: [echo])
}
try builder.register(MCPStandardMethods.callTool) { params, _ in
  try MCPCallToolResult(
    content: [
      .text(MCPTextContent(text: params.arguments["text"]?.stringValue ?? ""))
    ]
  )
}

try await MCPStdioServerRunner(server: builder.build()).run()
```

## 클라이언트 연결

### stdio

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

### HTTP

```swift
import Foundation
import MCP
import MCPHTTPClient

let transport = MCPHTTPClientTransport(
  configuration: try MCPHTTPClientConfiguration(
    endpoint: URL(string: "https://example.com/mcp")!
  )
)
let client = try MCPClient(
  transport: transport,
  configuration: MCPClientConfiguration(
    implementation: try MCPImplementation(name: "example-client", version: "1.0.0"),
    capabilities: MCPClientCapabilities()
  )
)

let discovery = try await client.discover()
print(discovery.supportedVersions)
```

`MCPHTTPClient`는 요청마다 POST를 만들고 JSON 응답 또는 request-scoped SSE를 처리합니다. subscription
stream을 닫으면 해당 HTTP 요청을 취소한 것으로 처리합니다. OAuth가 필요한 HTTP 401은
`MCPHTTPUnauthorizedResponse`로 전달되며, 재인증과 재요청 여부는 host가 결정합니다.

## 로컬 검증

빠른 개발 루프:

```bash
swift build
swift test
```

Pull Request를 열기 전에는 깨끗한 source tree에서 전체 검증 게이트를 실행합니다.

```bash
./Scripts/clean.sh
SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh
```

`verify.sh`는 다음을 확인합니다.

- strict stateless protocol 범위와 금지된 legacy API의 부재
- Swift format lint
- warnings-as-errors Debug 빌드
- 전체 테스트
- warnings-as-errors Release 빌드
- stdio conformance smoke (`discover` → `tools/list` → `tools/call`)

GitHub Actions도 같은 gate를 macOS 14에서 실행합니다. `.build`, `.swiftpm`, `.verification`,
`Artifacts`는 검증·배포 입력이 아니므로 커밋하지 않습니다.

## 릴리스 순서

1. `./Scripts/clean.sh`와 `SWIFT_BUILD_JOBS=1 ./Scripts/verify.sh`가 통과하는지 확인합니다.
2. `Package.swift`, `Sources/`, `Tests/`, `Scripts/`, `.github/`, `.gitignore`, `.swift-format`,
   README, `LICENSE`를 배포 입력으로 검토해 커밋합니다. 저장소 운영 파일은 공개 여부를 따로
   결정합니다.
3. GitHub Actions의 push·pull request 검증이 통과한 뒤 시맨틱 버전 태그를 만듭니다.
4. 태그의 SwiftPM 설치 예시와 실제 GitHub URL이 README의 자리표시자와 일치하는지 확인합니다.
5. 문제가 생기면 해당 태그의 배포를 중단하고, 마지막으로 검증된 태그를 기준으로 복구합니다.

GitHub 저장소를 만든 뒤에는 실제 소유자와 태그를 확인한 다음 아래처럼 연결합니다.

```bash
git add Package.swift Sources Tests Scripts .github .gitignore .swift-format README.md README.ko.md LICENSE
git commit -m "Initial SwiftMCP release"
git remote add origin https://github.com/<owner>/swift-mcp-sdk.git
git push -u origin main
git tag -a 0.1.0 -m "SwiftMCP 0.1.0"
git push origin 0.1.0
```

위 명령의 `<owner>`와 `0.1.0`은 예시입니다. 원격 저장소와 태그를 실제 값으로 바꿔야 합니다.

## 라이선스

SwiftMCP는 [MIT License](LICENSE)로 배포됩니다.
