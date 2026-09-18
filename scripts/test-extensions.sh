#!/usr/bin/env bash
#
# Run the reference extensions' own test suites.
#
# They are Python rather than XCTest because the extensions are: nothing in an
# extension is Swift, and a script's tests belong beside the script. They also
# ship inside the package deliberately — these are what somebody reads when
# writing their own extension, and "how do I test one of these?" is a question
# the reference should answer.
#
# A suite that discovers zero tests is a failure, not a pass. Discovery
# silently finding nothing is how this repo's Swift harness went a whole PR
# without calling setUpWithError, and every filesystem fixture in it passed by
# never running.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Keeps __pycache__ out of the extension directories. The packager excludes it
# anyway, but a directory that grows bytecode the first time anyone runs the
# tests is a working tree that differs from a fresh checkout for no reason.
export PYTHONDONTWRITEBYTECODE=1

ran=0
for dir in extensions/*/; do
  compgen -G "${dir}test_*.py" > /dev/null || continue
  echo "→ ${dir}"
  output="$(python3 -m unittest discover -s "$dir" -t "$dir" -p 'test_*.py' 2>&1)"
  echo "$output"
  if ! grep -qE '^Ran [1-9][0-9]* tests?' <<< "$output"; then
    echo "no tests ran in $dir" >&2
    exit 1
  fi
  ran=$((ran + 1))
done

if [[ "$ran" -eq 0 ]]; then
  echo "no extension test suites found" >&2
  exit 1
fi
