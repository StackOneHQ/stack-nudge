#!/usr/bin/env bash
#
# Renders the Extensions pages from fixture state into PNGs, for reviewing a
# UI change without installing anything. Dev-only: see panel/ScreenshotRenderer.swift.
#
#   scripts/render-screenshots.sh [outdir]     # default: build/screenshots
#
# Builds the app, then runs its binary with --render-screenshots. Nothing is
# read from or written to ~/.stack-nudge; the PNGs are not committed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
outdir="${1:-$repo_root/build/screenshots}"

"$repo_root/build.sh" > /dev/null
"$repo_root/build/StackNudge.app/Contents/MacOS/stack-nudge" --render-screenshots "$outdir"
