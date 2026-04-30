#!/usr/bin/env bash
# stack-nudge uninstaller

set -e

INSTALL_DIR="${HOME}/.stack-nudge"
NOTIFY="$INSTALL_DIR/notify.sh"

echo "Uninstalling stack-nudge..."

# Remove hooks from Claude Code
if [[ -f "$HOME/.claude/settings.json" ]]; then
  python3 - "$HOME/.claude/settings.json" "$NOTIFY" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
notify = sys.argv[2]
prefix = f"{notify} claude-code"
settings = json.loads(path.read_text())
hooks = settings.get("hooks", {})
for event in list(hooks.keys()):
    hooks[event] = [
        g for g in hooks[event]
        if not all((h.get("command") or "").startswith(prefix) for h in g.get("hooks", []))
    ]
    if not hooks[event]:
        del hooks[event]
if not hooks:
    settings.pop("hooks", None)
path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"  Cleaned {path}")
PY
fi

# Remove hooks from Cursor
if [[ -f "$HOME/.cursor/hooks.json" ]]; then
  python3 - "$HOME/.cursor/hooks.json" "$NOTIFY" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
notify = sys.argv[2]
prefix = f"{notify} cursor"
settings = json.loads(path.read_text())
hooks = settings.get("hooks", {})
for event in list(hooks.keys()):
    hooks[event] = [h for h in hooks[event] if not (h.get("command") or "").startswith(prefix)]
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
for app in stack-nudge.app stack-nudge-panel.app; do
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
