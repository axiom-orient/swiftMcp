# Xcode MCP live qualification

`MCPXcode` supports Apple's external-agent `xcrun mcpbridge` tools surface on Xcode 26.3+. A revision is
qualified only after the production `MCPXcodeClient` completes this exact path against a real Xcode:

```text
initialize
-> notifications/initialized
-> tools/list
-> tools/call(XcodeListWindows)
-> close
```

No legacy method is added because another MCP implementation supports it. Expansion requires a real
Xcode transcript proving that the existing four-operation boundary is insufficient.

## Preconditions

- macOS with the target Xcode selected by `xcode-select`;
- the target project/workspace open when that Xcode release requires it;
- Xcode > Settings > Intelligence > Model Context Protocol > Allow external agents enabled;
- permission prompts accepted for the qualification agent;
- a writable path outside the repository for evidence.

Apple documents `xcrun mcpbridge` as the stdio entry point for external agents. Xcode 27 also has a
preview `xcrun mcp-server` management experience for headless service/permission setup; that does not
create a second wire adapter in SwiftMCP.

## Run

Run the package test only when you intentionally want live Xcode I/O:

```bash
MCP_XCODE_LIVE_QUALIFICATION=1 \
MCP_XCODE_PROTOCOL_REVISION=2025-06-18 \
MCP_XCODE_TRANSCRIPT_PATH="$PWD/../xcode-27-mcpbridge.jsonl" \
swift test --filter MCPXcodeTests/testLiveXcodeQualificationWhenExplicitlyEnabled
```

For Xcode 26.3, explicitly pin its qualified revision:

```bash
MCP_XCODE_PROTOCOL_REVISION=2024-11-05
```

For Xcode 26.6, either currently qualified revision may be used:

```bash
MCP_XCODE_PROTOCOL_REVISION=2025-03-26
# or 2025-06-18
```

Pin the revision that matches the target Xcode instead of enabling an automatic downgrade:

```bash
MCP_XCODE_PROTOCOL_REVISION=2024-11-05   # Xcode 26.3
```

The test launches a test-only transparent proxy, which launches `/usr/bin/xcrun mcpbridge`. The
production `MCPXcodeClient` still owns the handshake and tool RPC. The proxy only records raw JSONL
in both directions plus `xcodebuild -version`, `sw_vers`, requested revision, stderr, and exit status.
It is not linked into any library product.

## Evidence gate

A transcript is accepted only when all of these are true:

1. `initialize` uses a numeric JSON-RPC id.
2. Xcode returns one of the explicitly qualified revisions and advertises `tools`.
3. `notifications/initialized` follows the successful initialize result.
4. `tools/list` succeeds and exposes `XcodeListWindows`.
5. `tools/call` for `XcodeListWindows` succeeds.
6. No generic downgrade, session-header logic, legacy HTTP, sampling, roots, or elicitation RPC is
   needed.

Retain one transcript per qualified Xcode build. If a future Xcode fails this gate, record the
failure first and change `MCPXcode` only when the transcript demonstrates the smallest necessary
Xcode-specific delta.

The current workspace has live qualification evidence for Xcode 26.6 (17F113), macOS 26.6.2, for
both `2025-03-26` and `2025-06-18`. Actual runtime qualification on Xcode 26.3 is `NOT_PROVEN` on
this machine; the 26.3 support claim is based on Apple's Xcode 26.3 introduction and the qualified
`2024-11-05` mock/source handshake. Do not infer 26.3 runtime success from a 26.6 transcript.
The retained 26.6 evidence and transcript digests are recorded in
[`XcodeQualificationEvidence-20260903.md`](XcodeQualificationEvidence-20260903.md).

The client defaults to `requestTimeout: .zero`, which disables the SDK request deadline so
long-running operations can complete. Supply a positive `requestTimeout` or cancel the task when
the host needs a deadline. Its default `ioLimits` are a configurable SDK safety policy (64 MiB
frame/document, 32 MiB string), not an MCP protocol maximum.
