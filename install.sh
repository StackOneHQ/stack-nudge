#!/usr/bin/env bash
# stack-nudge installer — wires up hooks for whichever agents you have

set -e

INSTALL_DIR="${HOME}/.stack-nudge"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing stack-nudge..."

# Copy notify.sh to shared install dir
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/notify.sh" "$INSTALL_DIR/notify.sh"
chmod +x "$INSTALL_DIR/notify.sh"
echo "  Installed notify.sh -> $INSTALL_DIR/notify.sh"
NOTIFY="$INSTALL_DIR/notify.sh"

# Copy example config only if no config exists yet (preserve user customisations on reinstall)
if [[ ! -f "$INSTALL_DIR/config" && -f "$SCRIPT_DIR/notify.conf.example" ]]; then
  cp "$SCRIPT_DIR/notify.conf.example" "$INSTALL_DIR/config"
  echo "  Created config      -> $INSTALL_DIR/config"
fi

# Detect agents and wire up their hooks
installed_any=false

# Claude Code
if [[ -d "$HOME/.claude" ]]; then
  echo ""
  echo "Detected Claude Code (~/.claude)"
  python3 - "$HOME/.claude/settings.json" "$NOTIFY" <<'PY'
import json, os, sys
from pathlib import Path

path = Path(sys.argv[1])
notify = sys.argv[2]
path.parent.mkdir(parents=True, exist_ok=True)
if path.exists():
    settings = json.loads(path.read_text() or "{}")
else:
    settings = {}

hooks = settings.setdefault("hooks", {})
for event, arg in [("Stop", "stop"), ("PermissionRequest", "permission")]:
    groups = hooks.setdefault(event, [])
    cmd = f"{notify} claude-code {arg}"
    if not any(
        any(h.get("command") == cmd for h in g.get("hooks", []))
        for g in groups
    ):
        groups.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})

path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"  Updated {path}")
PY
  installed_any=true
fi

# Cursor
if [[ -d "$HOME/.cursor" ]]; then
  echo ""
  echo "Detected Cursor (~/.cursor)"
  python3 - "$HOME/.cursor/hooks.json" "$NOTIFY" <<'PY'
import json, sys
from pathlib import Path

path = Path(sys.argv[1])
notify = sys.argv[2]
path.parent.mkdir(parents=True, exist_ok=True)
settings = json.loads(path.read_text()) if path.exists() else {}

hooks = settings.setdefault("hooks", {})
stop_cmd = f"{notify} cursor stop"
stop = hooks.setdefault("stop", [])
if not any(h.get("command") == stop_cmd for h in stop):
    stop.append({"type": "command", "command": stop_cmd})

path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"  Updated {path}")
PY
  installed_any=true
fi

# Gemini CLI
if [[ -d "$HOME/.gemini" ]]; then
  echo ""
  echo "Detected Gemini CLI (~/.gemini)"
  echo "  Note: Gemini CLI hook support is experimental. See README for manual setup."
  installed_any=true
fi

if [[ "$installed_any" == "false" ]]; then
  echo ""
  echo "No supported agents detected (Claude Code, Cursor, Gemini CLI)."
  echo "Install one, then re-run this script."
  exit 0
fi

echo ""
echo "Done! Hooks are wired up."
echo ""
echo "Config: edit ~/.stack-nudge/config to customise behaviour."
echo "  STACKNUDGE_VOICE=true                 — speak notifications aloud (requires StackVox)"
echo "  STACKNUDGE_ACTIVATE_IMMEDIATELY=true  — focus your editor without clicking"
echo "To uninstall, run: ./uninstall.sh"
