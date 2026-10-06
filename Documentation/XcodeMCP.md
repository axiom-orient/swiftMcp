# MCPXcode

`MCPXcode` is a narrow macOS adapter for Apple's `xcrun mcpbridge` on Xcode 26.3+. It is not a
general pre-2026 MCP implementation and it is not part of the modern protocol core.

## Boundary

`MCP` remains authoritative for MCP `2026-07-28`: request-scoped metadata, stateless execution,
`server/discover`, MRTR, subscriptions, and the modern transports. It never performs an
`initialize` handshake and never owns protocol-session state.

`MCPXcode` owns only the state required to talk to Xcode:

```text
spawn xcrun mcpbridge
  -> initialize with one explicitly selected Xcode-qualified revision
  -> validate returned revision + tools capability
  -> notifications/initialized
  -> tools/list | tools/call
  -> explicit shutdown / failure
```

Apple's public external-agent documentation names `xcrun mcpbridge` over stdio as the client entry
point. Xcode 27 also exposes `xcrun mcp-server` management commands for headless service/permission
setup; that does not require a second wire adapter here. `MCPXcode` continues to target
`mcpbridge` only.

## Qualified revisions

Apple does not publish a stable `mcpbridge` wire revision contract. The adapter therefore admits
only revisions with concrete Xcode interoperability evidence:

- `2024-11-05` — the Xcode 26.3 qualified revision.
- `2025-03-26` — observed with current Xcode 26.6.
- `2025-06-18` — observed with current Xcode 26.6 and Xcode 27 integrations; used as the default.

The configured revision is a deliberate policy choice, not an automatic fallback chain. The
revision returned by `initialize` is the connection authority and must also be in the qualified set.
A caller targeting an older Xcode deployment can pin the corresponding revision through
`MCPXcodeConfiguration.preferredProtocolRevision`.

Xcode 26.6 has also been observed rejecting JSON-RPC string request IDs while accepting integer
IDs. `MCPXcode` therefore uses monotonically increasing integer IDs internally. This quirk is not
propagated into `MCP`.

## State and concurrency

`MCPXcodeClient` is an actor because a single bridge process has real shared mutable state. One
actor-local lifecycle is the authoritative connection state:

```text
idle -> connecting(attempt) -> connected(info)
  ^            |                    |
  |            v                    v
  +-------- stopping(effect) <-------+
                 |
                 +-> idle | closed
```

The actor also owns:

- process lifetime and stdin writer;
- monotonically increasing request ID;
- pending request continuations;
- process generation;
- the monotonic request-ID invariant used to discard late/duplicate responses without a tombstone
  retention cap.

Connection establishment is single-flight but cancellation is waiter-local. Each caller gets a
separate waiter identity. Exactly one initialize effect runs, and the actor commits `connected(info)`
before any successful waiter resumes. Cancelling one waiter does not cancel a shared initialize while
other waiters remain. When the final waiter disappears, the actor commits `stopping` before releasing
that cancelled waiter; a new caller therefore queues behind teardown and starts a fresh initialize
only after `stopping -> idle`. It can never attach to the abandoned attempt.

Legacy MCP explicitly forbids cancelling `initialize` with `notifications/cancelled`, so initialize
uses a local-only cancellation policy. Ordinary tool requests still send the cancellation
notification when they are cancelled or time out.

A generation change makes output from an old process stale. A request ID is retired when the
request completes, fails, times out, or is cancelled. Because IDs are strictly positive,
monotonically increasing, and never reused, a late or duplicate response whose ID is lower than the
next allocation is discarded without retaining an unbounded tombstone set. An unknown or future
response ID is still a protocol failure.

Shutdown owns the child-process effect to completion: close stdin, wait briefly for graceful exit,
then TERM, wait again, and finally KILL if necessary. Process generation prevents any late output
from an older bridge from committing new state.

`MCPXcodeConfiguration.allowsReconnect` defaults to `true`, preserving the ability of a later
caller to create a fresh bridge after teardown. Setting it to `false` makes every stop terminal
for that client, including failed or abandoned initialization. Explicit `connect` and implicit
connections from tool calls are rejected thereafter. The SDK never replays a request. Selection
of Xcode identity, effect authorization and recovery remain caller responsibilities.

Process termination does not retire the generation before stdout can deliver buffered responses.
The actor records the exit status, rejects new connections/requests to that dead bridge, and waits
for EOF with a one-second drain bound. EOF or the bound commits the existing stopping transition;
explicit close and transport failures may stop sooner. This bound applies only after the bridge
has exited, not to a running Xcode operation.

## Deadlines and I/O policy

`MCPXcodeConfiguration.requestTimeout` defaults to `.zero`: this disables the SDK deadline and
does not impose an arbitrary cutoff on a long-running Xcode operation such as `BuildProject`. A
caller can still cancel the task, close the client, or provide an explicit positive timeout when an
application-level deadline is required.

`MCPXcodeConfiguration.ioLimits` is a host-configurable safety policy. The relaxed default permits
64 MiB frames and JSON documents, 32 MiB strings, and 16 KiB read chunks. These limits protect the
host from accidental resource exhaustion; they are not MCP protocol limits. MCP defines no fixed
16 MiB stdio maximum, so a host that expects larger Xcode results can raise the limits explicitly.

Dependency direction is one-way:

```text
MCPXcode -> MCP + MCPStdioShared
MCP      -/-> MCPXcode
```

## Qualification harness

`MCPXcodeTests` includes a package-local mock stdio bridge covering the required interoperability
paths without teaching the production adapter any generic legacy behavior:

- initialize -> initialized -> tools/list -> tools/call;
- two concurrent first callers sharing one committed connection;
- cancellation of one connection waiter while another survives;
- initialize cancellation and timeout remaining local-only;
- ordinary tool cancellation notifying the peer;
- duplicate/late responses, including one arriving after more than 256 later requests;
- complete handshakes for every qualified revision and negotiation to an older supported revision;
- preservation of legacy `content` when `structuredContent` is absent;
- bridge exit followed by a fresh process generation;
- final response buffered behind a notification when termination arrives first;
- bounded stdout drain with the request deadline disabled;
- single-connection policy rejecting explicit and implicit reconnect without a second launch;
- cancellation followed immediately by a new connect while the retired process is still stopping;
- reconnect while an old process has closed stdout but has not exited yet.

These fixtures are deterministic qualification assets. A separate opt-in live qualification test
uses a test-only transparent stdio proxy to run the production `MCPXcodeClient` against the real
`/usr/bin/xcrun mcpbridge` and retain a raw JSONL transcript. See `XcodeQualification.md`. Real Xcode
qualification still requires macOS with the target Xcode release. This workspace has live evidence
for Xcode 26.6; an actual Xcode 26.3 runtime qualification remains explicitly `NOT_PROVEN` on this
machine.

## Result fidelity

`MCPXcode` does not fabricate successful tool output. `tools/call` must contain the legacy
`content` array or the response is rejected as malformed.

Xcode 26.3 has been observed returning JSON-serialized structured data inside a text content block
while omitting `structuredContent`, even for tools that declare `outputSchema`. The adapter
preserves that wire result as-is. It deliberately does not parse arbitrary text and manufacture
`structuredContent`, because doing so would hide an upstream contract violation and could accept a
payload that does not satisfy the declared schema.

## Explicit non-goals

No support is added for generic legacy MCP, HTTP+SSE, session headers, batching, ping keepalives,
legacy resource subscriptions, `logging/setLevel`, server-originated sampling/roots/elicitation, or
revision downgrade heuristics. Official initialization negotiation is trusted: the configured
revision is sent once and a supported revision returned by Xcode is accepted. Automatic retries
are intentionally absent because forcing an older revision can initialize successfully and then
leave Xcode's bridge wedged at `tools/list` until Xcode is restarted. If Xcode later requires one
of those operations, it must be justified by Xcode-specific evidence before this boundary expands.

## References

- Apple: Giving external agents access to Xcode
  <https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode>
- MCP 2026-07-28 overview
  <https://blog.modelcontextprotocol.io/posts/2026-07-28/>
- Xcode 26.3 observed `2024-11-05`
  <https://github.com/kirodotdev/Kiro/issues/6122>
- Xcode 26.6 integer-ID / `2025-03-26` interoperability report
  <https://github.com/can1357/oh-my-pi/issues/7053>
- Xcode 27 observed `2025-06-18` integration
  <https://github.com/nanshanyi/dsh-mcp-xcode>
- Xcode 26.3 missing `structuredContent` report
  <https://github.com/google-gemini/gemini-cli/issues/18371>
