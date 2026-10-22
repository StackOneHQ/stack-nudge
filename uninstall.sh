#!/usr/bin/env bash
# stack-nudge uninstaller
#
# macOS users: prefer the in-app uninstall — open the panel via your
# hotkey (default ⌘⌥N), go to Settings, click "Uninstall stack-nudge…".
# It removes the same things this script does (hooks, launchd agents,
# ~/.stack-nudge/) plus trashes the .app.
#
# This script remains as a fallback for Linux/Windows + source-build
# macOS dev cycles, and as a safety net if the in-app uninstall fails
# partway and leaves state behind.

set -e

INSTALL_DIR="${HOME}/.stack-nudge"

echo "Uninstalling stack-nudge..."

# Remove our hooks from each agent's config, as the in-app uninstall does:
# under the events StackNudge wires (hook-manifest.json), anything inside a
# `tinynudge` or `stack-nudge` install dir goes, legacy and quoted forms
# included; under any other event only our exact `notify.sh <agent> <arg>`
# form does, so a wrapper or a checkout's script there stays. A file with
# nothing of ours is left untouched.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export HOOK_MANIFEST="$SCRIPT_DIR/hook-manifest.json"
export HOOK_HELPERS="$SCRIPT_DIR/scripts"
unwire_hooks() {
  [[ -f "$2" ]] || return 0
  HOOK_AGENT="$1" python3 - "$2" <<'PY'
import json, os, sys
sys.path.insert(0, os.environ["HOOK_HELPERS"])
from hook_wiring import prune_for_uninstall
from pathlib import Path

path = Path(sys.argv[1])
settings = json.loads(path.read_text() or "{}")
hooks = settings.get("hooks")
if isinstance(hooks, dict) and prune_for_uninstall(hooks):
    if not hooks:
        settings.pop("hooks", None)
    path.write_text(json.dumps(settings, indent=2) + "\n")
    print(f"  Cleaned {path}")
PY
}
unwire_hooks claude "$HOME/.claude/settings.json"
unwire_hooks cursor "$HOME/.cursor/hooks.json"
unwire_hooks gemini "$HOME/.gemini/settings.json"
unwire_hooks antigravity "$HOME/.gemini/antigravity-cli/settings.json"
unwire_hooks codex "$HOME/.codex/hooks.json"

# pi has no hook config to splice — it loads an extension from
# ~/.pi/agent/extensions/. Left behind it would keep spawning a now-removed
# notify.sh on every pi turn. (Its ~/.stack-nudge/pi-sessions/ sidecars are
# removed with $INSTALL_DIR below.)
if [[ -f "$HOME/.pi/agent/extensions/stack-nudge.ts" ]]; then
  rm -f "$HOME/.pi/agent/extensions/stack-nudge.ts"
  echo "  Removed ~/.pi/agent/extensions/stack-nudge.ts"
fi

# Stop and remove launchd agents (macOS)
for label in com.stackonehq.stack-nudge com.stackonehq.stack-nudge-daemon com.stackonehq.stack-nudge-panel; do
  plist="$HOME/Library/LaunchAgents/${label}.plist"
  if [[ -f "$plist" ]]; then
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
    echo "  Removed launchd agent ($label)"
  fi
done

# Stop any running app process the launchd agent didn't catch
pkill -f "stack-nudge$" 2>/dev/null || true

# Remove app bundles (including old two-binary setup)
for app in StackNudge.app stack-nudge.app stack-nudge-panel.app; do
  if [[ -d "$HOME/Applications/$app" ]]; then
    rm -rf "$HOME/Applications/$app"
    echo "  Removed ~/Applications/$app"
  fi
done

# Remove install dir (includes venv and notify.sh)
if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  echo "  Removed $INSTALL_DIR"
fi

echo ""
echo "Done."
