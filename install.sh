#!/usr/bin/env bash
# stack-nudge installer
#
# macOS users: prefer the prebuilt .app from GitHub Releases —
#   https://github.com/StackOneHQ/stack-nudge/releases/latest
# Download the .tar.gz, drag StackNudge.app to ~/Applications/, and
# launch it. The first-launch wizard runs the same install steps this
# script does, in-process, with no Xcode CLT or Python prerequisite.
#
# This script remains for:
#   - Linux + Windows (where the panel .app doesn't apply; notify.sh +
#     audio is all that's needed)
#   - Source-build devs on macOS who want to iterate without the
#     prebuilt cycle
#
# Wires hooks for whichever agents you have, sets up the Python venv
# for stackvox voice notifications, and registers launchd agents on
# macOS.

set -e

INSTALL_DIR="${HOME}/.stack-nudge"
VENV="$INSTALL_DIR/venv"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing stack-nudge..."

mkdir -p "$INSTALL_DIR"

# Build (or use a prebuilt) native app bundle. Release tarballs ship with a
# universal binary already at build/StackNudge.app — in that case skip the
# rebuild so users who download a release don't need swiftc on their machine.
# build.sh's output (Swift emits ~120 lines of UserNotifications deprecation
# warnings on every build) goes to a log so the install transcript stays
# scannable. On real build failure the log's last 20 lines are dumped.
PREBUILT_APP="$SCRIPT_DIR/build/StackNudge.app"
BUILD_LOG="/tmp/stack-nudge-install-build.log"
if [[ "$(uname -s)" == "Darwin" ]]; then
  echo ""
  echo "# STAGE: building"
  if [[ -d "$PREBUILT_APP" ]]; then
    echo "Using prebuilt StackNudge.app from release bundle..."
  else
    echo "Building StackNudge.app..."
    if ! bash "$SCRIPT_DIR/build.sh" > "$BUILD_LOG" 2>&1; then
      echo ""
      echo "  ✗ Build failed. Last 20 lines of $BUILD_LOG:"
      tail -20 "$BUILD_LOG" | sed 's/^/      /'
      exit 1
    fi
  fi
  # Don't destroy the installed copy until we've confirmed the new bundle
  # actually carries an executable — a corrupt or incomplete artifact would
  # otherwise leave the user with no app installed at all.
  if ! ls "$PREBUILT_APP"/Contents/MacOS/* >/dev/null 2>&1; then
    echo "  ✗ $PREBUILT_APP has no executable in Contents/MacOS — refusing to replace the installed app."
    exit 1
  fi
  rm -rf "$HOME/Applications/StackNudge.app"
  rm -rf "$HOME/Applications/stack-nudge-panel.app"  # clean up old panel binary
  cp -r "$PREBUILT_APP" "$HOME/Applications/StackNudge.app"
  echo "  Installed StackNudge.app -> ~/Applications/StackNudge.app"
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
echo "# STAGE: venv"
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
  # Clear any partial/incompatible venv first. `python -m venv` over an
  # existing directory can fail with "[Errno 17] File exists" — e.g. a venv
  # left by a different Python, or an interrupted earlier install — so make
  # creation idempotent rather than aborting the whole install (set -e).
  rm -rf "$VENV"
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

  # Escape XML metacharacters before interpolating any value into the plist —
  # a program arg or path containing & < > (e.g. an install dir whose name
  # contains them) would otherwise produce a malformed plist launchd rejects.
  xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"; s="${s//</&lt;}"; s="${s//>/&gt;}"
    printf '%s' "$s"
  }

  local program_xml=""
  for arg in "$@"; do
    program_xml+="        <string>$(xml_escape "$arg")</string>"$'\n'
  done
  local label_xml log_xml
  label_xml=$(xml_escape "$label")
  log_xml=$(xml_escape "$log_path")

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
    <string>${label_xml}</string>
    <key>ProgramArguments</key>
    <array>
${program_xml}    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    ${keep_alive_xml}
    <key>StandardOutPath</key>
    <string>${log_xml}</string>
    <key>StandardErrorPath</key>
    <string>${log_xml}</string>
</dict>
</plist>
PLIST
  launchctl unload "$plist_path" 2>/dev/null || true
  launchctl load "$plist_path"
}

if [[ "$(uname -s)" == "Darwin" ]]; then
  # Rotate logs (>10 MB) before launchd starts writing to them again. We move
  # rather than truncate so users can still inspect the previous session if a
  # bug shows up post-upgrade.
  rotate_log() {
    local log="$1"
    [[ ! -f "$log" ]] && return
    local size
    size=$(stat -f%z "$log" 2>/dev/null || echo 0)
    if (( size > 10485760 )); then
      mv -f "$log" "${log}.old"
    fi
  }
  rotate_log "${INSTALL_DIR}/daemon.log"
  rotate_log "${INSTALL_DIR}/app.log"

  echo "# STAGE: launchd"
  # Belt-and-suspenders: kill any survivor processes from a prior install
  # BEFORE we re-register the launchd agents, so the unload-then-load below
  # doesn't race with an old instance still hanging on. Matching the exact
  # binary path so we don't reap unrelated processes.
  pkill -f "Applications/stack-nudge\.app/Contents/MacOS/stack-nudge$" 2>/dev/null || true
  pkill -f "venv/bin/stackvox serve$"                                  2>/dev/null || true

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
    "$HOME/Applications/StackNudge.app/Contents/MacOS/stack-nudge"
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

echo "# STAGE: hooks"
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

# Codex
# Codex's hooks file shares Claude Code's matcher-group JSON shape and event
# names (Stop + PermissionRequest), in seconds — only the path and agent-arg
# differ. See https://developers.openai.com/codex/hooks
if [[ -d "$HOME/.codex" ]]; then
  echo ""
  echo "Detected Codex (~/.codex)"
  python3 - "$HOME/.codex/hooks.json" "$NOTIFY" "codex" <<'PY'
import json, os, re, sys
from pathlib import Path

path = Path(sys.argv[1])
notify = sys.argv[2]
agent = sys.argv[3]
path.parent.mkdir(parents=True, exist_ok=True)
if path.exists():
    settings = json.loads(path.read_text() or "{}")
else:
    settings = {}

STALE = re.compile(r"(?:^|/)\.?(?:tinynudge|stack-nudge)/notify\.sh(?:\s|$)")

hooks = settings.setdefault("hooks", {})
# PermissionRequest blocks on a FIFO until the user approves via stack-nudge,
# so it needs a longer timeout than the default.
for event, arg, timeout in [("Stop", "stop", 30), ("PermissionRequest", "permission", 600)]:
    groups = hooks.setdefault(event, [])

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

    cmd = f"{notify} {agent} {arg}"
    groups.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": cmd, "timeout": timeout}],
    })

path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"  Updated {path}")
PY
  installed_any=true
fi

# Gemini CLI
if [[ -d "$HOME/.gemini" ]]; then
  echo ""
  echo "Detected Gemini CLI (~/.gemini)"
  python3 - "$HOME/.gemini/settings.json" "$NOTIFY" "gemini" <<'PY'
import json, os, re, sys
from pathlib import Path

path = Path(sys.argv[1])
notify = sys.argv[2]
agent = sys.argv[3]
path.parent.mkdir(parents=True, exist_ok=True)
if path.exists():
    settings = json.loads(path.read_text() or "{}")
else:
    settings = {}

STALE = re.compile(r"(?:^|/)\.?(?:tinynudge|stack-nudge)/notify\.sh(?:\s|$)")

hooks = settings.setdefault("hooks", {})
for event, arg, timeout in [("AfterAgent", "stop", 30000), ("Notification", "permission", 30000)]:
    groups = hooks.setdefault(event, [])

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

    cmd = f"{notify} {agent} {arg}"
    groups.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": cmd, "timeout": timeout}],
    })

path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"  Updated {path}")
PY
  installed_any=true
fi

# Antigravity CLI
if [[ -d "$HOME/.gemini/antigravity-cli" ]]; then
  echo ""
  echo "Detected Antigravity CLI (~/.gemini/antigravity-cli)"
  python3 - "$HOME/.gemini/antigravity-cli/settings.json" "$NOTIFY" "antigravity" <<'PY'
import json, os, re, sys
from pathlib import Path

path = Path(sys.argv[1])
notify = sys.argv[2]
agent = sys.argv[3]
path.parent.mkdir(parents=True, exist_ok=True)
if path.exists():
    settings = json.loads(path.read_text() or "{}")
else:
    settings = {}

STALE = re.compile(r"(?:^|/)\.?(?:tinynudge|stack-nudge)/notify\.sh(?:\s|$)")

hooks = settings.setdefault("hooks", {})
for event, arg, timeout in [("AfterAgent", "stop", 30000), ("Notification", "permission", 30000)]:
    groups = hooks.setdefault(event, [])

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

    cmd = f"{notify} {agent} {arg}"
    groups.append({
        "matcher": "",
        "hooks": [{"type": "command", "command": cmd, "timeout": timeout}],
    })

path.write_text(json.dumps(settings, indent=2) + "\n")
print(f"  Updated {path}")
PY
  installed_any=true
fi

if [[ "$installed_any" == "false" ]]; then
  echo ""
  echo "No supported agents detected (Claude Code, Cursor, Codex, Gemini CLI, Antigravity CLI)."
  echo "Install one, then re-run this script."
  exit 0
fi

echo ""
echo "# STAGE: done"
echo "Done! Hooks are wired up."
echo ""
echo "  ┌──────────────────────────────────────────────┐"
echo "  │  Press  ⌘ + ⌥ + N  to open the stack-nudge   │"
echo "  │  panel — events, sessions, and settings.     │"
echo "  └──────────────────────────────────────────────┘"
echo ""
echo "macOS may ask for notification + accessibility permissions on first launch."
echo "Grant them so banners appear and 'Allow' on permission nudges can press Enter."
echo ""
echo "Config: edit ~/.stack-nudge/config (or use the Settings tab in the panel)."
echo "  STACKNUDGE_VOICE=true                 — speak notifications aloud"
echo "  STACKNUDGE_ACTIVATE_IMMEDIATELY=true  — focus your editor without clicking"
echo "  STACKNUDGE_BANNER=false               — suppress macOS banner notifications"
echo "  STACKNUDGE_PANEL_HOTKEY=cmd+opt+n     — global hotkey for the floating panel"
echo ""
echo "To uninstall, run: ./uninstall.sh"

# Fire a welcome notification so the user immediately sees what a nudge
# looks like AND macOS prompts for notification permission now (during
# install) rather than ambushing them mid-task later. Briefly wait for
# the launchd-managed app to come up before posting.
if [[ "$(uname -s)" == "Darwin" ]]; then
  for _ in 1 2 3 4 5 6 7 8; do
    [[ -S "$INSTALL_DIR/panel.sock" ]] && break
    sleep 0.25
  done
  "$NOTIFY" stack-nudge welcome >/dev/null 2>&1 &
fi
