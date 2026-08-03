#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f Package.swift && -d Sources ]] || {
  echo "FAIL not a SwiftMCP package root: $PWD" >&2
  exit 1
}

# Repository-local verification outputs are reproducible from source inputs. `.build` and
# `.swiftpm` are shared workspace state and are deliberately not removed by this script.
rm -rf -- .verification Artifacts .docc-build
find . -name .DS_Store -type f -delete

printf 'PASS clean source tree\n'
