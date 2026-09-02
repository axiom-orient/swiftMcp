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
CORE_PATHS=(Package.swift Sources/MCP Sources/MCPHTTPShared Sources/MCPHTTPClient Sources/MCPHTTPServer Sources/MCPStdioShared Sources/MCPStdioClient Sources/MCPStdioServer Sources/MCPConformanceClient Sources/MCPConformanceServer)
for pattern in \
  '20(24|25)-[0-9]{2}-[0-9]{2}' \
  '"(initialize|notifications/initialized)"' \
  '"resources/(subscribe|unsubscribe)"' \
  '"logging/setLevel"' \
  '\bMCP(Initialize|Session|Migration|Legacy|Compatibility)[A-Za-z0-9_]*\b' \
  '"(mcp-session-id|last-event-id)"[[:space:]]*:'; do
  if rg -n -i --glob '*.swift' --glob '*.c' --glob '*.h' "$pattern" "${CORE_PATHS[@]}"; then
    printf 'FAIL forbidden modern-core surface: %s\n' "$pattern" >&2
    exit 1
  fi
done

XCODE_PATH=Sources/MCPXcode/MCPXcode.swift
test -f "$XCODE_PATH" || { echo 'FAIL MCPXcode boundary is missing' >&2; exit 1; }
for revision in 2024-11-05 2025-03-26 2025-06-18; do
  rg -q "= \"$revision\"" "$XCODE_PATH" || {
    printf 'FAIL missing qualified Xcode revision: %s\n' "$revision" >&2
    exit 1
  }
done
for method in '"initialize"' '"notifications/initialized"' '"tools/list"' '"tools/call"'; do
  rg -q "$method" "$XCODE_PATH" || {
    printf 'FAIL missing Xcode method: %s\n' "$method" >&2
    exit 1
  }
done
for pattern in '"resources/(subscribe|unsubscribe)"' '"logging/setLevel"' '"sampling/createMessage"' '"roots/list"' '"elicitation/create"' '"mcp-session-id"' '"last-event-id"'; do
  if rg -n -i "$pattern" "$XCODE_PATH"; then
    printf 'FAIL forbidden Xcode surface: %s\n' "$pattern" >&2
    exit 1
  fi
done
printf 'PASS strict modern core + sealed Xcode compatibility boundary\n'

printf '\n== Tasks extension boundary ==\n'
test -f Sources/MCPTasks/MCPTasksModels.swift || { echo 'FAIL MCPTasks product is missing' >&2; exit 1; }
grep -q '.library(name: "MCPTasks", targets: \["MCPTasks"\])' Package.swift
grep -q '.target(name: "MCPTasks", dependencies: \["MCP"\]' Package.swift
rg -q 'io\.modelcontextprotocol/tasks' Sources/MCPTasks/MCPTasksModels.swift
for method in '"tasks/get"' '"tasks/update"' '"tasks/cancel"'; do
  rg -q "$method" Sources/MCPTasks/MCPTasksModels.swift || {
    printf 'FAIL missing Tasks method: %s\n' "$method" >&2
    exit 1
  }
done
for pattern in '"tasks/(result|list)"' '"notifications/tasks"' '"(submitted|unknown)"' 'tasks\.requests\.'; do
  if rg -n "$pattern" Sources/MCPTasks; then
    printf 'FAIL forbidden Tasks legacy/unwired surface: %s\n' "$pattern" >&2
    exit 1
  fi
done
if rg -n 'MCPTasks|io\.modelcontextprotocol/tasks|"tasks/(get|update|cancel)"' Sources/MCP; then
  echo 'FAIL Tasks-specific implementation leaked into MCP core' >&2
  exit 1
fi
printf 'PASS independent stable Tasks extension boundary\n'

printf '\n== distribution hygiene ==\n'
if rg -n '/(Users|home)/|\.build/(debug|release)/' Package.swift README.md README.ko.md Sources Scripts; then
  echo 'FAIL non-portable path in distribution inputs' >&2
  exit 1
fi
printf 'PASS portable distribution inputs\n'

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

BIN_PATH="$(swift build --scratch-path "$VERIFY_SCRATCH_PATH" --show-bin-path)"

printf '\n== stdio conformance smoke ==\n'
CONFORMANCE_OUTPUT="$("$BIN_PATH/mcp-conformance-client" "$BIN_PATH/mcp-conformance-server")"
[[ "$CONFORMANCE_OUTPUT" == 'PASS strict discovery/list/call/unknown-tool' ]] || {
  printf 'FAIL unexpected conformance output: %s\n' "$CONFORMANCE_OUTPUT" >&2
  exit 1
}
printf '%s\n' "$CONFORMANCE_OUTPUT"

printf '\nPASS all repository verification gates\n'
