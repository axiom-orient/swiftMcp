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

This delivery intentionally does not execute macOS/Xcode runtime verification. Real Apple
interoperability therefore remains external: run the live qualification on each target Xcode release
and retain its transcript. Until that is done, live Xcode compatibility is **UNKNOWN** rather than
inferred from the mock.
