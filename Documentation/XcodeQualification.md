# Xcode MCP live qualification

`MCPXcode` supports only Apple's external-agent `xcrun mcpbridge` tools surface. A revision is
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

For an older qualified Xcode, explicitly pin the observed revision instead of enabling downgrade:

```bash
MCP_XCODE_PROTOCOL_REVISION=2025-03-26   # qualified Xcode 26.x profile when required
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
