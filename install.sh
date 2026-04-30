#!/usr/bin/env bash
# stack-nudge installer — wires up hooks for whichever agents you have

set -e

INSTALL_DIR="${HOME}/.stack-nudge"
VENV="$INSTALL_DIR/venv"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing stack-nudge..."

mkdir -p "$INSTALL_DIR"

# Build and install the native app bundle (single persistent binary).
# build.sh's output (stdout + stderr — Swift emits ~120 lines of UserNotifications
# deprecation warnings on every build) is redirected to a log so the install
# transcript stays scannable. On real build failure the log's last 20 lines
# are dumped so the actual error doesn't get hidden.
BUILD_LOG="/tmp/stack-nudge-install-build.log"
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo ""
  echo "Building stack-nudge.app..."
  if ! bash "$SCRIPT_DIR/build.sh" > "$BUILD_LOG" 2>&1; then
    echo ""
    echo "  ✗ Build failed. Last 20 lines of $BUILD_LOG:"
    tail -20 "$BUILD_LOG" | sed 's/^/      /'
    exit 1
  fi
  rm -rf "$HOME/Applications/stack-nudge.app"
  rm -rf "$HOME/Applications/stack-nudge-panel.app"  # clean up old panel binary
  cp -r "$SCRIPT_DIR/build/stack-nudge.app" "$HOME/Applications/stack-nudge.app"
  echo "  Installed stack-nudge.app -> ~/Applications/stack-nudge.app"
fi

# Pick a Python ≥ 3.10 for the venv. stackvox requires it, but `python3` on
# PATH is often the system 3.9 (especially in non-interactive shells).
find_python() {
  if [[ -n "${STACKNUDGE_PYTHON:-}" && -x "${STACKNUDGE_PYTHON}" ]]; then
    echo "${STACKNUDGE_PYTHON}"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      command -v python3
      return
    fi
  fi
  for cand in /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.13 \
              /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 \
              /opt/homebrew/bin/python3.10 \
              /usr/local/bin/python3.14 /usr/local/bin/python3.13 \
              /usr/local/bin/python3.12 /usr/local/bin/python3.11 \
              /usr/local/bin/python3.10; do
    [[ -x "$cand" ]] && { echo "$cand"; return; }
  done
}

# Install the voice engine (stackvox) from PyPI into an isolated venv.
echo ""
echo "Setting up voice engine..."
STACKVOX_SPEC="stackvox>=0.4.0"
PYTHON=$(find_python)
if [[ -z "$PYTHON" ]]; then
  echo ""
  echo "  ✗ Could not find Python ≥ 3.10 — required by the bundled voice engine (stackvox)."
  echo ""
  echo "    Install one of these and re-run ./install.sh:"
  echo "      brew install python@3.13"
  echo "      STACKNUDGE_PYTHON=/path/to/python3 ./install.sh"
  echo ""
  exit 1
fi
if [[ ! -x "$VENV/bin/stackvox" ]]; then
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet "$STACKVOX_SPEC"
  echo "  Voice engine installed -> $VENV  (using $PYTHON)"
else
  "$VENV/bin/pip" install --quiet --upgrade "$STACKVOX_SPEC"
  echo "  Voice engine updated   -> $VENV"
fi

# Write a LaunchAgent plist and (re)load it.
# Args: label keep_alive_mode log_path program_args...
#   keep_alive_mode = "always" (restart on any exit) | "on_crash" (only on non-zero exit)
register_launchd_agent() {
  local label="$1" keep_alive_mode="$2" log_path="$3"
  shift 3
  local plist_path="$HOME/Library/LaunchAgents/${label}.plist"

  local program_xml=""
  for arg in "$@"; do
    program_xml+="        <string>${arg}</string>"$'\n'
  done

  local keep_alive_xml
  case "$keep_alive_mode" in
    always)   keep_alive_xml="<true/>" ;;
    on_crash) keep_alive_xml="<dict><key>SuccessfulExit</key><false/></dict>" ;;
    *) echo "register_launchd_agent: bad mode '$keep_alive_mode'" >&2; return 1 ;;
  esac

  cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
${program_xml}    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    ${keep_alive_xml}
    <key>StandardOutPath</key>
    <string>${log_path}</string>
    <key>StandardErrorPath</key>
    <string>${log_path}</string>
</dict>
</plist>
PLIST
  launchctl unload "$plist_path" 2>/dev/null || true
  launchctl load "$plist_path"
}

if [[ "$(uname -s)" == "Darwin" ]]; then
  register_launchd_agent \
    "com.stackonehq.stack-nudge-daemon" \
    "always" \
    "${INSTALL_DIR}/daemon.log" \
    "${VENV}/bin/stackvox" "serve"
  echo "  Voice daemon registered as launchd agent (starts at login)"

  # Single persistent app — always running, restarts on crash.
  register_launchd_agent \
    "com.stackonehq.stack-nudge" \
    "always" \
    "${INSTALL_DIR}/app.log" \
    "$HOME/Applications/stack-nudge.app/Contents/MacOS/stack-nudge"
  echo "  App registered as launchd agent (starts at login)"

  # Remove old panel launchd agent if upgrading from two-binary setup
  OLD_PANEL_PLIST="$HOME/Library/LaunchAgents/com.stackonehq.stack-nudge-panel.plist"
  if [[ -f "$OLD_PANEL_PLIST" ]]; then
    launchctl unload "$OLD_PANEL_PLIST" 2>/dev/null || true
    rm -f "$OLD_PANEL_PLIST"
  fi
fi

# Copy notify.sh and the phrase pools (sourced by notify.sh at runtime
# based on the configured voice's language) to the shared install dir.
cp "$SCRIPT_DIR/notify.sh" "$INSTALL_DIR/notify.sh"
chmod +x "$INSTALL_DIR/notify.sh"
echo "  Installed notify.sh    -> $INSTALL_DIR/notify.sh"

if [[ -d "$SCRIPT_DIR/phrases" ]]; then
  rm -rf "$INSTALL_DIR/phrases"
  cp -R "$SCRIPT_DIR/phrases" "$INSTALL_DIR/phrases"
  echo "  Installed phrases/     -> $INSTALL_DIR/phrases"
fi
NOTIFY="$INSTALL_DIR/notify.sh"

# Copy example config only if no config exists yet (preserve user customisations on reinstall)
if [[ ! -f "$INSTALL_DIR/config" && -f "$SCRIPT_DIR/notify.conf.example" ]]; then
  cp "$SCRIPT_DIR/notify.conf.example" "$INSTALL_DIR/config"
  echo "  Created config         -> $INSTALL_DIR/config"
fi

# Detect agents and wire up their hooks
installed_any=false

# Claude Code
if [[ -d "$HOME/.claude" ]]; then
  echo ""
  echo "Detected Claude Code (~/.claude)"
  python3 - "$HOME/.claude/settings.json" "$NOTIFY" <<'PY'
import json, os, re, sys
from pathlib import Path

path = Path(sys.argv[1])
notify = sys.argv[2]
path.parent.mkdir(parents=True, exist_ok=True)
if path.exists():
    settings = json.loads(path.read_text() or "{}")
else:
    settings = {}

# Match any prior stack-nudge / tinynudge hook entry regardless of where it
# was installed (legacy ~/.tinynudge, moved checkouts, etc.) so upgrades
# replace the stale entry instead of appending a duplicate that points at a
# dead path.
STALE = re.compile(r"(?:^|/)\.?(?:tinynudge|stack-nudge)/notify\.sh(?:\s|$)")

hooks = settings.setdefault("hooks", {})
# Permission hook blocks on a FIFO until the user approves via stack-nudge,
# so it needs a longer timeout than Claude Code's 600s default.
for event, arg, timeout in [("Stop", "stop", 30), ("PermissionRequest", "permission", 600)]:
    groups = hooks.setdefault(event, [])

    # Drop any existing group whose inner hook commands all look like ours
    # (or are entirely empty after pruning ours). Mixed groups keep the
    # non-stack-nudge entries intact.
    cleaned = []
    for g in groups:
        inner = g.get("hooks", [])
        kept = [h for h in inner if not STALE.search(h.get("command", "") or "")]
        if not kept:
            continue
        if kept != inner:
            g = {**g, "hooks": kept}
        cleaned.append(g)
    groups[:] = cleaned

    cmd = f"{notify} claude-code {arg}"
    groups.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": cmd, "timeout": timeout}],
    })

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
import json, re, sys
from pathlib import Path

path = Path(sys.argv[1])
notify = sys.argv[2]
path.parent.mkdir(parents=True, exist_ok=True)
settings = json.loads(path.read_text()) if path.exists() else {}

# Match any prior stack-nudge / tinynudge entry regardless of install path
# so upgrades replace stale entries rather than appending duplicates.
STALE = re.compile(r"(?:^|/)\.?(?:tinynudge|stack-nudge)/notify\.sh(?:\s|$)")

hooks = settings.setdefault("hooks", {})
stop_cmd = f"{notify} cursor stop"
stop = hooks.setdefault("stop", [])
stop[:] = [h for h in stop if not STALE.search(h.get("command", "") or "")]
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
echo "  STACKNUDGE_VOICE=true                 — speak notifications aloud"
echo "  STACKNUDGE_ACTIVATE_IMMEDIATELY=true  — focus your editor without clicking"
echo "  STACKNUDGE_BANNER=false               — suppress macOS banner notifications"
echo "  STACKNUDGE_PANEL_HOTKEY=cmd+opt+n     — global hotkey for the floating panel"
echo "To uninstall, run: ./uninstall.sh"
