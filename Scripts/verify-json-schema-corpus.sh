#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CORPUS_COMMIT="fb7372e8763a1417bddc65fa4c911b3e79b57b65"
CORPUS_ARCHIVE_URL="https://github.com/json-schema-org/JSON-Schema-Test-Suite/archive/${CORPUS_COMMIT}.tar.gz"
CORPUS_ROOT="${MCP_JSON_SCHEMA_CORPUS_PATH:-}"
OWNED_CORPUS=false

if [[ -z "$CORPUS_ROOT" ]]; then
  CORPUS_ROOT="$(mktemp -d -t swiftmcp-json-schema 2>/dev/null || mktemp -d)"
  OWNED_CORPUS=true
  trap 'rm -rf -- "$CORPUS_ROOT"' EXIT
  curl --fail --location --retry 3 --silent --show-error "$CORPUS_ARCHIVE_URL" \
    | tar -xz --strip-components=1 -C "$CORPUS_ROOT"
fi

[[ -d "$CORPUS_ROOT/tests/draft2020-12" ]] || {
  echo "FAIL JSON Schema corpus root is missing tests/draft2020-12: $CORPUS_ROOT" >&2
  exit 1
}

VERIFY_SCRATCH_PATH="${SWIFTMCP_VERIFY_SCRATCH_PATH:-}"
BUILD_ARGS=(--product mcp-json-schema-corpus --jobs "${SWIFT_BUILD_JOBS:-1}")
if [[ -n "$VERIFY_SCRATCH_PATH" ]]; then
  BUILD_ARGS+=(--scratch-path "$VERIFY_SCRATCH_PATH")
fi
swift build "${BUILD_ARGS[@]}" -Xswiftc -warnings-as-errors >/dev/null

BIN_ARGS=(--show-bin-path)
if [[ -n "$VERIFY_SCRATCH_PATH" ]]; then
  BIN_ARGS+=(--scratch-path "$VERIFY_SCRATCH_PATH")
fi
BIN_PATH="$(swift build "${BIN_ARGS[@]}")"
"$BIN_PATH/mcp-json-schema-corpus" "$CORPUS_ROOT"

if [[ "$OWNED_CORPUS" == true ]]; then
  echo "verified corpus commit: $CORPUS_COMMIT"
else
  echo "verified corpus path: $CORPUS_ROOT"
fi
