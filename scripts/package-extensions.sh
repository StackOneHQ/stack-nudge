#!/usr/bin/env bash
#
# Validate and package the extensions under extensions/ for a release.
#
#   scripts/package-extensions.sh validate        # CI gate, on every PR
#   scripts/package-extensions.sh package [outdir]
#
# Validation is the curation gate doing real work. An extension PR is reviewed
# as code, but a reviewer reads a diff — and a diff does not show where a symlink
# points. A tarball carries symlinks perfectly well, so without this an approved
# manifest can say one thing and the package do another. The host refuses an
# escaping run path at spawn time, but by then the review has already happened.
#
# Packaging mirrors the app's own convention (release.yml): <asset>.tar.gz plus a
# <asset>.tar.gz.sha256 sidecar holding "<hash>  <basename>". The app refuses to
# install anything whose sidecar is missing, so the sidecar is not optional.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ext_root="$repo_root/extensions"

mode="${1:-validate}"
outdir="${2:-$repo_root/dist/extensions}"

fail() {
  echo "  ✗ $1" >&2
  return 1
}

# Every path inside a package must be a regular file or a directory. Symlinks are
# the point of this check; device nodes, sockets and fifos are refused for the
# same reason, which is that nothing legitimate needs them and a tar can carry
# them.
validate_tree() {
  local dir="$1" id="$2" rc=0
  local entries=()
  while IFS= read -r -d '' entry; do
    entries+=("$entry")
  done < <(find "$dir" -mindepth 1 -print0)

  for entry in ${entries[@]+"${entries[@]}"}; do
    local rel="${entry#"$dir"/}"
    if [[ -L "$entry" ]]; then
      fail "$id: '$rel' is a symlink -> $(readlink "$entry")" || rc=1
    elif [[ ! -f "$entry" && ! -d "$entry" ]]; then
      fail "$id: '$rel' is not a regular file or directory" || rc=1
    fi
  done
  return "$rc"
}

# The manifest is read with python3 rather than jq: jq is not guaranteed on a
# runner, python3 is already a hard dependency of notify.sh.
manifest_field() {
  python3 -c '
import json, sys
with open(sys.argv[1]) as fh:
    print(json.load(fh).get(sys.argv[2], ""))
' "$1" "$2"
}

validate_one() {
  local dir="$1" rc=0
  local id manifest run_rel run_path declared_id schema version

  id="$(basename "$dir")"
  manifest="$dir/manifest.json"

  if [[ ! -f "$manifest" ]]; then
    fail "$id: no manifest.json"
    return 1
  fi
  if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$manifest" 2>/dev/null; then
    fail "$id: manifest.json is not valid JSON"
    return 1
  fi

  # The directory name is what every path and every tab id is built from, so a
  # manifest claiming a different id would let one extension answer to another's.
  declared_id="$(manifest_field "$manifest" id)"
  [[ "$declared_id" == "$id" ]] || fail "$id: manifest declares id '$declared_id'" || rc=1

  # Mirrors ExtensionManifest.isValidID — it becomes a directory name.
  [[ "$id" =~ ^[a-z0-9-]{1,32}$ ]] || fail "$id: id is not ^[a-z0-9-]{1,32}\$" || rc=1

  schema="$(manifest_field "$manifest" schema)"
  [[ "$schema" == "1" ]] || fail "$id: schema is '$schema', expected 1" || rc=1

  version="$(manifest_field "$manifest" version)"
  [[ -n "$version" ]] || fail "$id: no version" || rc=1

  run_rel="$(manifest_field "$manifest" run)"
  [[ -n "$run_rel" ]] || run_rel="./run"
  case "$run_rel" in
    /*|~*)  fail "$id: run '$run_rel' is absolute" || rc=1 ;;
    *..*)   fail "$id: run '$run_rel' escapes the package" || rc=1 ;;
  esac

  run_path="$dir/${run_rel#./}"
  if [[ ! -e "$run_path" ]]; then
    fail "$id: run '$run_rel' does not exist" || rc=1
  elif [[ -L "$run_path" ]]; then
    fail "$id: run '$run_rel' is a symlink" || rc=1
  elif [[ ! -f "$run_path" ]]; then
    fail "$id: run '$run_rel' is not a regular file" || rc=1
  elif [[ ! -x "$run_path" ]]; then
    fail "$id: run '$run_rel' is not executable" || rc=1
  fi

  validate_tree "$dir" "$id" || rc=1

  [[ "$rc" -eq 0 ]] && echo "  ✓ $id $version"
  return "$rc"
}

package_one() {
  local dir="$1" id version asset
  id="$(basename "$dir")"
  version="$(manifest_field "$dir/manifest.json" version)"
  asset="${id}-${version}.tar.gz"

  # -C so the archive root is the id directory, matching what the installer
  # expects to find after extraction.
  tar czf "$outdir/$asset" -C "$ext_root" "$id"
  ( cd "$outdir" && shasum -a 256 "$asset" | awk '{print $1 "  " "'"$asset"'"}' > "$asset.sha256" )
  echo "  → $asset"
}

extension_dirs() {
  [[ -d "$ext_root" ]] || return 0
  find "$ext_root" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z
}

main() {
  local dirs=() rc=0
  while IFS= read -r -d '' dir; do
    dirs+=("$dir")
  done < <(extension_dirs)

  if [[ "${#dirs[@]}" -eq 0 ]]; then
    # Not an error. Until the first extension lands, a release still publishes an
    # empty index so the app has something well-formed to fetch.
    echo "no extensions to $mode"
    [[ "$mode" == "package" ]] || return 0
  fi

  case "$mode" in
    validate)
      echo "validating ${#dirs[@]} extension(s)"
      for dir in ${dirs[@]+"${dirs[@]}"}; do
        validate_one "$dir" || rc=1
      done
      ;;
    package)
      for dir in ${dirs[@]+"${dirs[@]}"}; do
        validate_one "$dir" || rc=1
      done
      [[ "$rc" -eq 0 ]] || { echo "refusing to package: validation failed" >&2; return 1; }

      mkdir -p "$outdir"
      for dir in ${dirs[@]+"${dirs[@]}"}; do
        package_one "$dir"
      done
      write_index "${dirs[@]+"${dirs[@]}"}"
      echo "  → extensions-index.json"
      ;;
    *)
      echo "usage: $0 [validate|package] [outdir]" >&2
      return 2
      ;;
  esac
  return "$rc"
}

# The index is what the app fetches to know what is installable. Written by
# python3 so the JSON is actually encoded rather than string-concatenated.
write_index() {
  python3 - "$outdir" "$@" <<'PY'
import hashlib, json, os, sys

outdir, dirs = sys.argv[1], sys.argv[2:]
entries = []
for d in dirs:
    with open(os.path.join(d, "manifest.json")) as fh:
        m = json.load(fh)
    asset = "{}-{}.tar.gz".format(m["id"], m["version"])
    with open(os.path.join(outdir, asset), "rb") as fh:
        digest = hashlib.sha256(fh.read()).hexdigest()
    entries.append({
        "id": m["id"],
        "name": m.get("name", m["id"]),
        "version": m["version"],
        "description": m.get("description", ""),
        "asset": asset,
        "sha256": digest,
        "requires": m.get("requires", []),
        "config": m.get("config", []),
    })

entries.sort(key=lambda e: e["id"])
with open(os.path.join(outdir, "extensions-index.json"), "w") as fh:
    json.dump({"schema": 1, "extensions": entries}, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

main "$@"
