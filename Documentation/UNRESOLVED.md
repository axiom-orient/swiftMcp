# Unresolved external constraints

These items are intentionally not hidden behind fallback behavior.

## Xcode `mcpbridge` revision is not an Apple-stable wire contract

Apple documents `xcrun mcpbridge` as the stdio entry point for external agents but does not publish
a stable protocol revision matrix for Xcode releases. `MCPXcode` therefore qualifies only
`2024-11-05`, `2025-03-26`, and `2025-06-18`, all backed by observed Xcode interoperability, and
fails closed for any other revision.

**Required action for a future Xcode revision:** qualify the new bridge behavior on macOS first,
then add exactly that revision if the existing four-operation surface remains sufficient. Do not
add a generic legacy negotiation layer.

## Xcode 26.3 omits `structuredContent`

Observed Xcode 26.3 `mcpbridge` responses can return JSON serialized as text in `content` while
omitting `structuredContent` even when the tool declares an `outputSchema`. `MCPXcode` preserves the
wire truth and does not heuristically parse text into structured output.

A general repair inside this package would require the adapter to retain the exact tool
`outputSchema`, parse text conditionally, validate the parsed JSON against that schema, and expose
that as a separate explicitly repaired result. That would be a compatibility policy rather than a
wire decoder, so it is intentionally not part of the minimal adapter.

## Live Xcode qualification

The repository contains deterministic mock-bridge qualification for single-flight connection,
waiter-local cancellation, cancellation/timeout, tools, duplicate responses, cancelled-attempt
teardown, immediate reconnect, and process restart. It also contains an opt-in live test and a
test-only transparent proxy that record the production client's real `xcrun mcpbridge` JSONL wire.
See `XcodeQualification.md`.

Live qualification was executed on Xcode 26.6 (17F113), macOS 26.6.2. After the per-agent approval
alert was explicitly allowed, both qualified revisions `2025-03-26` and `2025-06-18` passed
initialize, `tools/list`, `XcodeListWindows`, and clean bridge exit end to end. The approval was
deliberately not persisted (`Don't ask again` remained unchecked), so an unapproved alert can leave
Xcode waiting and appear as a `tools/list` timeout; that is an environment/operation condition, not
evidence of an MCPXcode transport or protocol defect.

The live `BuildProject` call against the `kairos.xcworkspace` workspace also reached Xcode and
returned a structured result. The active Analytics build then failed downstream because
`TCAFoundation` could not resolve 13 module dependencies; this is a kairosi project dependency
failure, not an MCPXcode transport or protocol failure.

## Official conformance runner and Tasks diagnostics

The official `modelcontextprotocol/conformance` runner is available, with requirements frozen for
the `2026-07-28` specification. Its Tasks scenarios are currently unscored requirements, and
upstream issue #424 can report false wire-schema failures for a valid `resultType: "task"` response.
SwiftMCP treats that runner as a useful diagnostic input, not as a passed qualification. The runner
and its schema corpus are not installed, downloaded, or vendored into this package.

## Tasks schema lower-bound interpretation

The stable `modelcontextprotocol/ext-tasks` `2026-07-28` schema represents `taskId` as a string and
`ttlMs` / `pollIntervalMs` as safe integers without `minLength` or `minimum: 0` constraints. SwiftMCP
rejects empty task IDs because they cannot provide a valid lifecycle or HTTP `Mcp-Name` routing key,
but its millisecond model accepts every mathematical integer in the inclusive JSON safe range
`-9007199254740991...9007199254740991`, including negative values. A host may reject negative
producer values as a local policy; that is not a protocol-level MUST enforced by this SDK.
