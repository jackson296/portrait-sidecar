#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/portrait-sidecar-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc "$project_dir/Source/WorkspaceOptions.swift" "$project_dir/Tests/main.swift" -o "$test_dir/tests"
"$test_dir/tests"
