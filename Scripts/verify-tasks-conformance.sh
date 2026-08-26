#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Run the pinned official server-side Tasks scenarios against the deterministic fixture. Every
# scenario is reported independently; a non-zero result or an official warning is a failure.
# The fixture process is owned by this script and is stopped by its exact PID on every exit path.

CONFORMANCE_PIN="@modelcontextprotocol/conformance@0.2.0-alpha.11"
if [[ -n "${MCP_TASKS_CONFORMANCE_PORT:-}" ]]; then
  CONFORMANCE_PORT="$MCP_TASKS_CONFORMANCE_PORT"
else
  CONFORMANCE_PORT="$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
    probe.bind(("127.0.0.1", 0))
    print(probe.getsockname()[1])
PY
)"
fi
BUILD_ARGS=(--product mcp-conformance-server --jobs "${SWIFT_BUILD_JOBS:-1}")

VERIFY_SCRATCH_PATH="${SWIFTMCP_VERIFY_SCRATCH_PATH:-}"
VERIFY_OWNS_SCRATCH=false
if [[ -z "$VERIFY_SCRATCH_PATH" ]]; then
  VERIFY_SCRATCH_PATH="$(mktemp -d -t swiftmcp-tasks-verify 2>/dev/null || mktemp -d)"
  VERIFY_OWNS_SCRATCH=true
fi
BUILD_ARGS+=(--scratch-path "$VERIFY_SCRATCH_PATH")

TEMP_PATH="$(mktemp -d -t swiftmcp-tasks-conformance 2>/dev/null || mktemp -d)"
SERVER_PID=""

stop_server() {
  local pid="$SERVER_PID"
  [[ -n "$pid" ]] || return 0
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" >/dev/null 2>&1 || break
      sleep 0.1
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  fi
  wait "$pid" >/dev/null 2>&1 || true
  SERVER_PID=""
}

cleanup() {
  stop_server
  rm -rf -- "$TEMP_PATH"
  if [[ "$VERIFY_OWNS_SCRATCH" == true ]]; then
    rm -rf -- "$VERIFY_SCRATCH_PATH"
  fi
}
trap cleanup EXIT INT TERM

printf '== Tasks conformance build ==\n'
swift build "${BUILD_ARGS[@]}" -Xswiftc -warnings-as-errors
BIN_PATH="$(swift build --show-bin-path --scratch-path "$VERIFY_SCRATCH_PATH")"
SERVER_LOG="$TEMP_PATH/server.log"

printf '\n== Tasks fixture ==\n'
"$BIN_PATH/mcp-conformance-server" --http 127.0.0.1 "$CONFORMANCE_PORT" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

ready=false
for _ in $(seq 1 100); do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    printf 'FAIL fixture exited before readiness\n' >&2
    cat "$SERVER_LOG" >&2
    exit 1
  fi
  if curl --silent --output /dev/null --max-time 1 \
    -X POST "http://127.0.0.1:${CONFORMANCE_PORT}/mcp" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{}'; then
    ready=true
    break
  fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  printf 'FAIL fixture did not become ready on 127.0.0.1:%s\n' "$CONFORMANCE_PORT" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi

scenarios=(
  tasks-lifecycle
  tasks-capability-negotiation
  tasks-wire-fields
  tasks-request-state-removal
  tasks-mrtr-input
  tasks-request-headers
  tasks-dispatch-and-envelope
  tasks-status-notifications
  tasks-required-task-error
  tasks-mrtr-composition
)
failures=0
for scenario in "${scenarios[@]}"; do
  output_path="$TEMP_PATH/${scenario}.log"
  printf '\n== %s ==\n' "$scenario"
  set +e
  npx --yes "$CONFORMANCE_PIN" server \
    --url "http://127.0.0.1:${CONFORMANCE_PORT}/mcp" \
    --scenario "$scenario" --verbose >"$output_path" 2>&1
  scenario_status=$?
  set -e
  cat "$output_path"

  if rg -q '"status": "SKIPPED"' "$output_path"; then
    if ((scenario_status != 0)) || ! rg -q '^Passed: 0/0, 0 failed, 0 warnings$' "$output_path"; then
      failures=$((failures + 1))
      printf 'SCENARIO FAIL %s (unexpected skip result, exit=%s)\n' "$scenario" "$scenario_status"
    else
      printf 'SCENARIO SKIP %s (official harness skip)\n' "$scenario"
    fi
  elif ((scenario_status != 0)) || ! rg -q '^Passed: .*0 failed, 0 warnings$' "$output_path"; then
    failures=$((failures + 1))
    printf 'SCENARIO FAIL %s (exit=%s)\n' "$scenario" "$scenario_status"
  else
    printf 'SCENARIO PASS %s\n' "$scenario"
  fi
done

printf '\n== fixture diagnostics ==\n'
cat "$SERVER_LOG"
if ((failures != 0)); then
  printf '\nTasks conformance failures: %s\n' "$failures" >&2
  exit 1
fi
printf '\nTasks conformance scenarios completed without failures or warnings.\n'
