#!/usr/bin/env bash
#
# Refuse a change to an extension that doesn't bump its version.
#
#   scripts/check-extension-versions.sh [base-ref]
#
# The published index names an asset and carries its sha256, and the app
# decides an update exists by comparing version strings. So shipping different
# bytes under the same version is not a cosmetic slip: the extension is
# unreachable to everyone who already installed it, because
# `installedVersion != availableVersion` is false and no update is ever
# offered. That happened — derby's script was rewritten across a PR, the
# version stayed 1.0.0, and the release published code nobody with it already
# installed could ever get.
#
# Every file in the directory counts, tests included, because every file is in
# the tarball the checksum is taken over.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

base="${1:-origin/main}"
# The merge base, then compared against the *working tree* rather than HEAD, so
# this catches an uncommitted bump locally as well as a pushed one in CI. Using
# "$base...HEAD" looked right and silently passed every local run, because the
# change under review had not been committed yet.
merge_base="$(git merge-base "$base" HEAD)"

version_at() {
  # $1 = ref ("" for the working tree), $2 = directory
  local manifest
  if [[ -z "$1" ]]; then
    manifest="$(cat "$2/manifest.json" 2>/dev/null || true)"
  else
    manifest="$(git show "$1:$2/manifest.json" 2>/dev/null || true)"
  fi
  [[ -n "$manifest" ]] || return 0
  printf '%s' "$manifest" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))'
}

rc=0
checked=0
for dir in extensions/*/; do
  dir="${dir%/}"
  id="$(basename "$dir")"

  # Nothing touched in this extension: nothing to require.
  #
  # Untracked files count. A new test or helper dropped into an extension
  # directory is invisible to `git diff` and still ends up in the tarball the
  # index checksums, so skipping on the diff alone let exactly the change this
  # check exists for walk past it locally.
  untracked="$(git ls-files --others --exclude-standard -- "$dir")"
  if git diff --quiet "$merge_base" -- "$dir" && [[ -z "$untracked" ]]; then
    continue
  fi
  checked=$((checked + 1))

  before="$(version_at "$merge_base" "$dir")"
  after="$(version_at "" "$dir")"

  # A brand new extension has no previous version to differ from.
  if [[ -z "$before" ]]; then
    echo "  ✓ $id is new at $after"
    continue
  fi

  if [[ "$before" == "$after" ]]; then
    echo "  ✗ $id changed but its version is still $after" >&2
    echo "    Bump \"version\" in $dir/manifest.json. The app offers an update" >&2
    echo "    only when the published version differs from the installed one," >&2
    echo "    so republishing under $after reaches nobody who already has it." >&2
    rc=1
  else
    echo "  ✓ $id $before → $after"
  fi
done

if [[ "$checked" -eq 0 ]]; then
  echo "no extension changed against ${base}"
fi
exit "$rc"
