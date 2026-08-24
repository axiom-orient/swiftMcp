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

# Verification must not read, replace, or delete a shared repository `.build`. A caller may
# provide a reusable scratch path; otherwise this script owns and removes only the directory it
# creates under the platform temporary directory.
VERIFY_SCRATCH_PATH="${SWIFTMCP_VERIFY_SCRATCH_PATH:-}"
VERIFY_OWNS_SCRATCH=false
if [[ -z "$VERIFY_SCRATCH_PATH" ]]; then
  VERIFY_SCRATCH_PATH="$(mktemp -d -t swiftmcp-verify 2>/dev/null || mktemp -d)"
  VERIFY_OWNS_SCRATCH=true
fi
if [[ "$VERIFY_OWNS_SCRATCH" == true ]]; then
  trap 'rm -rf -- "$VERIFY_SCRATCH_PATH"' EXIT
fi

printf '\n== repository contract ==\n'
grep -q '// swift-tools-version: 6.2' Package.swift
grep -q '.swiftLanguageMode(.v6)' Package.swift
grep -q 'swiftLanguageModes: \[.v6\]' Package.swift
! grep -q '\.package(' Package.swift
! test -e Package.resolved
printf 'PASS self-contained SwiftPM package\n'

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

printf '\n== distribution hygiene ==\n'
python3 - <<'PY'
import pathlib
import re

root = pathlib.Path.cwd()
paths = [root / "Package.swift", root / "README.md", root / "README.ko.md"]
paths += sorted((root / "Sources").rglob("*"))
paths += sorted((root / "Scripts").rglob("*"))
paths += sorted((root / ".github").rglob("*"))
for path in paths:
    if not path.is_file() or path.suffix not in {"", ".swift", ".c", ".h", ".md", ".sh", ".yml"}:
        continue
    # Hidden files such as Finder .DS_Store metadata are distribution debris, not scanned
    # inputs; skipping them keeps the gate failing on real violations instead of crashing
    # on binary metadata that must never be committed in the first place.
    if any(part.startswith(".") for part in path.relative_to(root).parts):
        continue
    text = path.read_text(encoding="utf-8")
    for label, pattern in {
        "personal absolute path": r"/(?:Users|home)/",
        "fixed repository build-product path": r"\.build/(?:debug|release)/",
    }.items():
        assert re.search(pattern, text) is None, f"{label}: {path.relative_to(root)}"

print("PASS portable distribution inputs")
PY

printf '\n== format lint ==\n'
# --strict turns lint warnings into a non-zero exit; without it the gate passes while
# swift-format still reports diagnostics.
"${SWIFT_FORMAT_CMD[@]}" lint --strict --recursive Package.swift Sources Tests

printf '\n== debug build ==\n'
swift build --scratch-path "$VERIFY_SCRATCH_PATH" --jobs "${SWIFT_BUILD_JOBS:-1}" -Xswiftc -warnings-as-errors

printf '\n== tests ==\n'
swift test --scratch-path "$VERIFY_SCRATCH_PATH" --jobs "${SWIFT_BUILD_JOBS:-1}" -Xswiftc -warnings-as-errors

printf '\n== release build ==\n'
swift build --scratch-path "$VERIFY_SCRATCH_PATH" -c release --jobs "${SWIFT_BUILD_JOBS:-1}" -Xswiftc -warnings-as-errors

printf '\n== JSON Schema 2020-12 corpus ==\n'
SWIFTMCP_VERIFY_SCRATCH_PATH="$VERIFY_SCRATCH_PATH" bash ./Scripts/verify-json-schema-corpus.sh

BIN_PATH="$(swift build --scratch-path "$VERIFY_SCRATCH_PATH" --show-bin-path)"

printf '\n== stdio conformance smoke ==\n'
CONFORMANCE_OUTPUT="$("$BIN_PATH/mcp-conformance-client" "$BIN_PATH/mcp-conformance-server")"
[[ "$CONFORMANCE_OUTPUT" == 'PASS strict discovery/list/call/unknown-tool' ]] || {
  printf 'FAIL unexpected conformance output: %s\n' "$CONFORMANCE_OUTPUT" >&2
  exit 1
}
printf '%s\n' "$CONFORMANCE_OUTPUT"

printf '\n== external SDK conformance ==\n'
SWIFTMCP_VERIFY_SCRATCH_PATH="$VERIFY_SCRATCH_PATH" bash ./Scripts/verify-external-conformance.sh

printf '\nPASS all repository verification gates\n'
