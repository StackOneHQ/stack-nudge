#!/usr/bin/env bash
# Type-check the XCTest sources without Xcode.
#
# `swift test` needs the XCTest module, which only ships with full Xcode. On a
# Command Line Tools-only machine the whole test target fails to load, so the
# test sources are the one part of the repo that never gets compiled locally —
# and a production API change that breaks a test call site stays invisible until
# CI fails on a build error.
#
# This compiles the test sources in-module against the real panel types, with
# XCTest swapped for the stand-ins in scripts/xctest-shim.swift. It catches
# compile breakage in seconds. It does NOT run any assertions: `swift test`
# (locally via `make test`, or in CI) remains the authority on whether the tests
# pass.
#
# Usage: scripts/typecheck-tests.sh

set -euo pipefail

cd "$(dirname "$0")/.."

SHIM="scripts/xctest-shim.swift"
TESTS_DIR="Tests/StackNudgePanelCoreTests"

if [[ ! -f "$SHIM" ]]; then
  echo "missing $SHIM" >&2
  exit 1
fi

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

# Swap the imports so the test sources compile as part of the panel module:
#   - XCTest is replaced (not deleted) because it re-exports Foundation; several
#     test files rely on that for Calendar/TimeZone and fail if it just goes away.
#   - @testable import is dropped since everything is one module here.
checked=0
for source in "$TESTS_DIR"/*.swift; do
  sed -e 's/^import XCTest$/import AppKit\nimport SwiftUI/' \
      -e 's/^@testable import StackNudgePanelCore$//' \
      "$source" > "$stage/$(basename "$source")"
  checked=$((checked + 1))
done

if [[ "$checked" -eq 0 ]]; then
  echo "no test sources found in $TESTS_DIR" >&2
  exit 1
fi

# panel/main.swift owns the app entry point; it is excluded so its top-level code
# doesn't clash with the test sources being compiled alongside it. build.sh
# type-checks that file as part of the real build.
sources=()
for source in panel/*.swift shared/*.swift; do
  [[ "$source" == "panel/main.swift" ]] && continue
  sources+=("$source")
done

echo "type-checking $checked test file(s) against panel/ + shared/..."

# -suppress-warnings because panel/ carries a stack of pre-existing macOS 14
# deprecation warnings that bury the errors this script exists to surface.
# build.sh and CI still report them.
#
# Diagnostics are captured so the staging paths can be rewritten back to the real
# test files — otherwise every error points at a temp directory that no longer
# exists by the time you read it.
if ! swiftc -typecheck -suppress-warnings \
      "${sources[@]}" "$SHIM" "$stage"/*.swift 2> "$stage/diagnostics.txt"; then
  sed "s|$stage/|$TESTS_DIR/|g" "$stage/diagnostics.txt" >&2
  exit 1
fi

echo "OK — test sources compile (assertions not run; use 'make test' or CI for that)"
