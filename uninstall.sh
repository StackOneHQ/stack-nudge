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

# Remove hooks from Claude Code. Matches anything inside a `tinynudge` or
# `stack-nudge` install dir — including quoted forms like
# `"$HOME/.stack-nudge/notify.sh"` — so legacy entries (and dev checkouts
# pointing at moved paths) get cleaned up too, not just the current $NOTIFY.
if [[ -f "$HOME/.claude/settings.json" ]]; then
  python3 - "$HOME/.claude/settings.json" <<'PY'
import json, re, sys
from pathlib import Path

path = Path(sys.argv[1])
STALE = re.compile(r'(?:^|/|")\.?(?:tinynudge|stack-nudge)/notify\.sh')
settings = json.loads(path.read_text())
hooks = settings.get("hooks", {})
for event in list(hooks.keys()):
    cleaned = []
    for g in hooks[event]:
        inner = g.get("hooks", [])
        kept = [h for h in inner if not STALE.search(h.get("command", "") or "")]
        if not kept:
            continue
        if kept != inner:
            g = {**g, "hooks": kept}
        cleaned.append(g)
    hooks[event] = cleaned
    if not hooks[event]:
        del hooks[event]
if not hooks:
    settings.pop("hooks", None)
path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"  Cleaned {path}")
PY
fi

# Remove hooks from Cursor. Same path-agnostic match as the Claude block.
if [[ -f "$HOME/.cursor/hooks.json" ]]; then
  python3 - "$HOME/.cursor/hooks.json" <<'PY'
import json, re, sys
from pathlib import Path

path = Path(sys.argv[1])
STALE = re.compile(r'(?:^|/|")\.?(?:tinynudge|stack-nudge)/notify\.sh')
settings = json.loads(path.read_text())
hooks = settings.get("hooks", {})
for event in list(hooks.keys()):
    hooks[event] = [h for h in hooks[event] if not STALE.search(h.get("command", "") or "")]
    if not hooks[event]:
        del hooks[event]
if not hooks:
    settings.pop("hooks", None)
path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"  Cleaned {path}")
PY
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
