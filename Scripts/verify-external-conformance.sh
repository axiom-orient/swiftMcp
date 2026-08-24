#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# External SDK conformance gate.
#
# Provisions the pinned official Python SDK in an isolated venv (or reuses
# MCP_PYTHON_SDK_VENV), launches its stateless streamable-HTTP reference server on a
# loopback port, and requires this repository's conformance client to pass its strict
# sequence through that peer. The gate follows the corpus pattern: a pinned upstream
# revision, isolated scratch directories, and no contact with the repository `.build`.
#
# Environment:
#   MCP_PYTHON_SDK_VENV   path to a pre-built venv containing `mcp` + uvicorn; skips download
#   SWIFTMCP_VERIFY_SCRATCH_PATH  shared verification scratch path from verify.sh

PYTHON_BIN="${MCP_PYTHON_BIN:-python3}"
SDK_PIN="mcp==2.0.0"
REFERENCE_PORT=""

OWNED_VENV=false
VENV_PATH="${MCP_PYTHON_SDK_VENV:-}"

if [[ -z "$VENV_PATH" ]]; then
  VENV_PATH="$(mktemp -d -t swiftmcp-python-sdk 2>/dev/null || mktemp -d)"
  OWNED_VENV=true
fi

cleanup() {
  if [[ -n "$REFERENCE_PORT" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "$OWNED_VENV" == true ]]; then
    rm -rf -- "$VENV_PATH"
  fi
}
trap cleanup EXIT

if [[ "$OWNED_VENV" == true ]]; then
  printf 'provisioning isolated Python SDK environment (%s)\n' "$SDK_PIN"
  "$PYTHON_BIN" -m venv "$VENV_PATH"
  "$VENV_PATH/bin/pip" install --quiet --disable-pip-version-check "$SDK_PIN" uvicorn
elif [[ ! -x "$VENV_PATH/bin/python" ]]; then
  printf 'FAIL external SDK venv is missing bin/python: %s\n' "$VENV_PATH" >&2
  exit 1
fi

# set -e aborts when the pinned SDK does not advertise the strict protocol version.
"$VENV_PATH/bin/python" - <<'PY'
from mcp.types import LATEST_PROTOCOL_VERSION
assert LATEST_PROTOCOL_VERSION == "2026-07-28", LATEST_PROTOCOL_VERSION
PY

BUILD_ARGS=(--product mcp-conformance-client --jobs "${SWIFT_BUILD_JOBS:-1}")
if [[ -n "${SWIFTMCP_VERIFY_SCRATCH_PATH:-}" ]]; then
  BUILD_ARGS+=(--scratch-path "$SWIFTMCP_VERIFY_SCRATCH_PATH")
fi
swift build "${BUILD_ARGS[@]}" -Xswiftc -warnings-as-errors >/dev/null

BIN_ARGS=(--show-bin-path)
if [[ -n "${SWIFTMCP_VERIFY_SCRATCH_PATH:-}" ]]; then
  BIN_ARGS+=(--scratch-path "$SWIFTMCP_VERIFY_SCRATCH_PATH")
fi
BIN_PATH="$(swift build "${BIN_ARGS[@]}")"

REFERENCE_PORT="$("$PYTHON_BIN" - <<'PY'
import socket
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    print(probe.getsockname()[1])
PY
)"

printf 'launching reference server on 127.0.0.1:%s\n' "$REFERENCE_PORT"
MCP_REFERENCE_PORT="$REFERENCE_PORT" \
  "$VENV_PATH/bin/python" Scripts/reference/mcp_reference_server.py \
  >/dev/null 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    printf 'FAIL reference server exited before accepting connections\n' >&2
    exit 1
  fi
  if curl --fail --silent --output /dev/null --max-time 2 \
    -X POST "http://127.0.0.1:${REFERENCE_PORT}/mcp" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{}'; then
    break
  fi
  sleep 0.2
done

CONFORMANCE_OUTPUT="$("$BIN_PATH/mcp-conformance-client" --http "http://127.0.0.1:${REFERENCE_PORT}/mcp")"
[[ "$CONFORMANCE_OUTPUT" == 'PASS strict discovery/list/call/unknown-tool' ]] || {
  printf 'FAIL unexpected external conformance output: %s\n' "$CONFORMANCE_OUTPUT" >&2
  exit 1
}
printf '%s\n' "$CONFORMANCE_OUTPUT"

REVERSE_PORT="$("$PYTHON_BIN" - <<'PY'
import socket
with socket.socket() as probe:
    probe.bind(("127.0.0.1", 0))
    print(probe.getsockname()[1])
PY
)"

printf 'launching Swift conformance server on 127.0.0.1:%s for the reverse direction\n' \
  "$REVERSE_PORT"
"$BIN_PATH/mcp-conformance-server" --http 127.0.0.1 "$REVERSE_PORT" >/dev/null 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    printf 'FAIL conformance server exited before accepting connections\n' >&2
    exit 1
  fi
  if curl --fail --silent --output /dev/null --max-time 2 \
    -X POST "http://127.0.0.1:${REVERSE_PORT}/mcp" \
    -H 'content-type: application/json' \
    -H 'accept: application/json, text/event-stream' \
    -d '{}'; then
    break
  fi
  sleep 0.2
done

REVERSE_OUTPUT="$("$VENV_PATH/bin/python" Scripts/reference/mcp_reference_client.py \
  "http://127.0.0.1:${REVERSE_PORT}/mcp")"
[[ "$REVERSE_OUTPUT" == 'PASS strict discovery/list/call/unknown-tool' ]] || {
  printf 'FAIL unexpected reverse conformance output: %s\n' "$REVERSE_OUTPUT" >&2
  exit 1
}
printf '%s\n' "$REVERSE_OUTPUT"
[[ "$OWNED_VENV" == true ]] && printf 'verified external SDK pin: %s\n' "$SDK_PIN"
exit 0
