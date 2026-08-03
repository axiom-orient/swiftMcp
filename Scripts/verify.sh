#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

printf '== toolchain ==\n'
swift --version
SWIFT_FORMAT_BIN="$(command -v swift-format || true)"
if [[ -z "$SWIFT_FORMAT_BIN" ]] && command -v xcrun >/dev/null 2>&1; then
  SWIFT_FORMAT_BIN="$(xcrun --find swift-format 2>/dev/null || true)"
fi
SWIFT_FORMAT_CMD=()
if [[ -n "$SWIFT_FORMAT_BIN" && -x "$SWIFT_FORMAT_BIN" ]]; then
  SWIFT_FORMAT_CMD=("$SWIFT_FORMAT_BIN")
elif swift format lint --help >/dev/null 2>&1; then
  # Swift 6 toolchains may expose swift-format as the `swift format` subcommand instead of a
  # standalone executable.
  SWIFT_FORMAT_CMD=(swift format)
fi
[[ "${#SWIFT_FORMAT_CMD[@]}" -gt 0 ]] || {
  echo 'FAIL swift-format is required by the gate' >&2
  exit 1
}

printf '\n== repository contract ==\n'
[[ ! -d .build && ! -d .swiftpm && ! -d .verification ]] || {
  echo 'FAIL run ./Scripts/clean.sh before verification' >&2
  exit 1
}
grep -q '// swift-tools-version: 6.2' Package.swift
grep -q '.swiftLanguageMode(.v6)' Package.swift
grep -q 'swiftLanguageModes: \[.v6\]' Package.swift
! grep -q '\.package(' Package.swift
! test -e Package.resolved
printf 'PASS clean, self-contained SwiftPM package\n'

printf '\n== strict protocol surface ==\n'
python3 - <<'PY'
import pathlib
import re

root = pathlib.Path.cwd()
production_files = [root / "Package.swift"] + sorted((root / "Sources").rglob("*"))
production_files = [path for path in production_files if path.suffix in {".swift", ".c", ".h"}]
production = "\n".join(path.read_text(encoding="utf-8") for path in production_files)
for label, pattern in {
    "pre-2026 protocol version": r"20(?:24|25)-[0-9]{2}-[0-9]{2}",
    "removed lifecycle method": r'"(?:initialize|notifications/initialized)"',
    "removed resource subscription method": r'"resources/(?:subscribe|unsubscribe)"',
    "removed logging method": r'"logging/setLevel"',
    "legacy public type": r"\bMCP(?:Initialize|Session|Migration|Legacy|Compatibility)[A-Za-z0-9_]*\b",
    "legacy header emission": r'"(?:mcp-session-id|last-event-id)"\s*:',
}.items():
    assert re.search(pattern, production, flags=re.IGNORECASE) is None, label

print("PASS strict-only production surface")
PY

printf '\n== format lint ==\n'
# --strict turns lint warnings into a non-zero exit; without it the gate passes while
# swift-format still reports diagnostics.
"${SWIFT_FORMAT_CMD[@]}" lint --strict --recursive Package.swift Sources Tests

printf '\n== debug build ==\n'
swift build --jobs "${SWIFT_BUILD_JOBS:-1}" -Xswiftc -warnings-as-errors

printf '\n== tests ==\n'
swift test --jobs "${SWIFT_BUILD_JOBS:-1}" -Xswiftc -warnings-as-errors

printf '\n== release build ==\n'
swift build -c release --jobs "${SWIFT_BUILD_JOBS:-1}" -Xswiftc -warnings-as-errors

BIN_PATH="$(swift build --show-bin-path)"

printf '\n== stdio conformance smoke ==\n'
CONFORMANCE_OUTPUT="$("$BIN_PATH/mcp-conformance-client" "$BIN_PATH/mcp-conformance-server")"
[[ "$CONFORMANCE_OUTPUT" == 'PASS stdio strict discovery/list/call' ]] || {
  printf 'FAIL unexpected conformance output: %s\n' "$CONFORMANCE_OUTPUT" >&2
  exit 1
}
printf '%s\n' "$CONFORMANCE_OUTPUT"

printf '\nPASS all repository verification gates\n'
