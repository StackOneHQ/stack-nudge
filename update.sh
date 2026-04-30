#!/usr/bin/env bash
# stack-nudge auto-updater
# Checks npm for a newer version and installs it if available.
# Designed to run unattended via launchd (macOS).

set -e

INSTALL_DIR="${HOME}/.stack-nudge"
LOG="$INSTALL_DIR/update.log"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Rotate log if > 100KB
if [[ -f "$LOG" ]]; then
  size=$(stat -f%z "$LOG" 2>/dev/null || stat -c%s "$LOG" 2>/dev/null || echo 0)
  (( size > 102400 )) && { tail -50 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"; }
fi

# Find npm — launchd doesn't source shell profiles, so check common paths.
find_npm() {
  [[ -f "$INSTALL_DIR/.npm-path" ]] && {
    local stored
    stored=$(cat "$INSTALL_DIR/.npm-path")
    [[ -x "$stored" ]] && { echo "$stored"; return; }
  }
  for cand in /opt/homebrew/bin/npm /usr/local/bin/npm \
              "$HOME/.nvm/versions/node"/*/bin/npm \
              "$HOME/.volta/bin/npm" \
              "$HOME/.fnm/aliases/default/bin/npm"; do
    for match in $cand; do
      [[ -x "$match" ]] && { echo "$match"; return; }
    done
  done
  command -v npm 2>/dev/null || true
}

NPM=$(find_npm)
if [[ -z "$NPM" || ! -x "$NPM" ]]; then
  log "npm not found — skipping update check"
  exit 0
fi

# Compare installed vs latest version
CURRENT=$("$NPM" ls -g stack-nudge --depth=0 --json 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('dependencies',{}).get('stack-nudge',{}).get('version',''))" 2>/dev/null || echo "")

if [[ -z "$CURRENT" ]]; then
  log "stack-nudge not found in npm global — skipping"
  exit 0
fi

LATEST=$("$NPM" view stack-nudge version 2>/dev/null || echo "")
if [[ -z "$LATEST" ]]; then
  log "Could not reach npm registry — skipping"
  exit 0
fi

if [[ "$CURRENT" == "$LATEST" ]]; then
  log "Up to date (v${CURRENT})"
  exit 0
fi

log "Updating: v${CURRENT} -> v${LATEST}"
if "$NPM" install -g "stack-nudge@${LATEST}" >> "$LOG" 2>&1; then
  log "Update complete (v${LATEST})"
else
  log "Update failed (exit $?)"
fi
