#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f Package.swift && -d Sources ]] || {
  echo "FAIL not a SwiftMCP package root: $PWD" >&2
  exit 1
}

# SwiftPM and release outputs are reproducible from the source inputs. Finder metadata is local
# machine state and must not become an input to a build or release.
rm -rf .build .swiftpm .verification Artifacts
find . -name .DS_Store -type f -delete

printf 'PASS clean source tree\n'
