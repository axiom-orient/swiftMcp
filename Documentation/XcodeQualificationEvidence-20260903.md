# Xcode qualification evidence — 2026-09-03

These records capture live `MCPXcodeClient` qualification against Xcode 26.6. The host was Xcode
26.6 build 17F113 on macOS 26.6.2.

## Qualified revisions

| Requested revision | Result | Duration | Raw transcript SHA-256 | Sanitized JSONL artifact |
| --- | --- | ---: | --- | --- |
| `2025-06-18` | PASS | 25.957s | `ac221ff9aab005cacd8d7755f2f799b9ce64656a597068de19fcd18dca0896b6` | [xcode-26.6-2025-06-18.jsonl](XcodeQualificationEvidence/xcode-26.6-2025-06-18.jsonl) |
| `2025-03-26` | PASS | 12.836s | `db51383a392ca56c334cbfa4856c4358bab96a89e0c754a773559dc0c73c30d3` | [xcode-26.6-2025-03-26.jsonl](XcodeQualificationEvidence/xcode-26.6-2025-03-26.jsonl) |

The SHA-256 values identify the original raw proxy transcripts. The linked JSONL files are durable,
sanitized evidence artifacts derived from those transcripts; they are intentionally not byte-for-byte
copies and contain no private workspace path or raw tool catalog.

Each run completed the same production path:

```text
initialize
→ notifications/initialized
→ tools/list
→ XcodeListWindows
→ clean bridge exit
```

Xcode displayed an external-agent approval prompt for each qualification. `Allow` was selected
explicitly each time; no persistent permission option was selected.

This evidence qualifies the two revisions on Xcode 26.6. It does not prove an actual Xcode 26.3
runtime; that remains `NOT_PROVEN` on this machine.
