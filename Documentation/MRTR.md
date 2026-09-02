# MRTR boundary

SwiftMCP treats MCP `2026-07-28` multi-round-trip requests (MRTR) as a protocol transport for
additional client input, not as an application validation engine.

## Canonical input union

`MCPInputRequest` / `MCPInputResponse` are the single core contract for:

- `elicitation/create`;
- deprecated `sampling/createMessage`;
- deprecated `roots/list`.

These types are owned by the core `MCP` target; no extension target defines a second raw-JSON MRTR
contract.

## `requestState` is opaque

`requestState` is server-owned opaque state. The core model:

- accepts any string, including the empty string;
- preserves the exact string when retrying the original operation;
- does not parse, normalize, sign, or interpret it;
- applies only the caller-configurable `MCPMRTRPolicy.maximumRequestStateBytes` resource bound in
  the automatic client coordinator.

The byte limit is a local resource policy, not wire semantics. A server that relies on
`requestState` for integrity or authorization must mint and verify its own opaque value.

Input request/response map keys are likewise treated as arbitrary server-assigned strings. The
protocol layer does not invent a non-empty-key requirement.

## Wire validation vs application validation

The MRTR coordinator validates only what it must know to continue safely:

1. the result is `input_required`;
2. each `inputResponses[key]` has the same discriminated input kind as `inputRequests[key]`;
3. configured round/count/byte resource limits are not exceeded.

For Elicitation, accepted `content` is **not** automatically revalidated against
`requestedSchema` by the wire driver. Application code that wants that policy calls:

```swift
try elicitationParams.validate(result: elicitationResult)
```

This keeps untrusted input visible to the handler and prevents protocol decoding from silently
owning application data policy.

## State transition

```text
ready
  -> input_required
  -> collecting input (or delayed state-only retry)
  -> retrying
  -> ready
  -> complete
```

Every retry uses a fresh JSON-RPC request identity. The opaque `requestState` and collected
`inputResponses` are explicit ordinary operation parameters; no protocol session is created.

## References

- MCP 2026-07-28 schema
  <https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/schema/2026-07-28/schema.ts>
- Official TypeScript SDK 2026 migration guide
  <https://github.com/modelcontextprotocol/typescript-sdk/blob/main/docs/migration/support-2026-07-28.md>
