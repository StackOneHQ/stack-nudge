#!/usr/bin/env bash
# stack-nudge: Cross-platform notifications for AI coding agent hooks
# Usage: notify.sh <agent> <event>
#   agent: claude-code | cursor | gemini | codex | <any name>
#   event: stop | permission
# Example: notify.sh claude-code stop

AGENT="${1:-agent}"
EVENT="${2:-stop}"
OS="$(uname -s 2>/dev/null || echo Windows)"

# Load user config (overrides defaults below).
# Copy notify.conf.example to ~/.stack-nudge/config to customise.
[[ -f "${HOME}/.stack-nudge/config" ]] && source "${HOME}/.stack-nudge/config"

# Read JSON piped from Claude Code hooks (contains transcript_path for Stop events).
# Skip if stdin is a terminal (manual invocation).
HOOK_JSON=""
if [[ ! -t 0 ]]; then
  HOOK_JSON=$(cat)
fi

# Extract context from the permission hook JSON: what tool/command needs approval.
# For Bash: shows the first line of the command (up to 60 chars).
# For Write/Edit: shows "<tool>: <filename>".
# Returns empty string if unavailable.
permission_context() {
  command -v jq &>/dev/null || return
  [[ -z "$HOOK_JSON" ]] && return
  local tool_name
  tool_name=$(printf '%s' "$HOOK_JSON" | jq -r '.tool_name // empty' 2>/dev/null)
  [[ -z "$tool_name" ]] && return
  case "$tool_name" in
    Bash)
      printf '%s' "$HOOK_JSON" | jq -r '.tool_input.command // empty' 2>/dev/null \
        | head -1 | cut -c1-60
      ;;
    Write|Edit|MultiEdit)
      local file
      file=$(printf '%s' "$HOOK_JSON" | jq -r '.tool_input.file_path // empty' 2>/dev/null | sed 's|.*/||')
      [[ -n "$file" ]] && echo "${tool_name}: ${file}"
      ;;
    *)
      echo "$tool_name"
      ;;
  esac
}

# Voice-friendly version of permission_context.
# For Bash: returns a generic phrase instead of the raw command.
# For Write/Edit/MultiEdit: same as permission_context (already concise).
voice_permission_context() {
  command -v jq &>/dev/null || return
  [[ -z "$HOOK_JSON" ]] && return
  local tool_name
  tool_name=$(printf '%s' "$HOOK_JSON" | jq -r '.tool_name // empty' 2>/dev/null)
  [[ -z "$tool_name" ]] && return
  case "$tool_name" in
    Bash)
      echo "Bash command needs approval"
      ;;
    Write|Edit|MultiEdit)
      local file
      file=$(printf '%s' "$HOOK_JSON" | jq -r '.tool_input.file_path // empty' 2>/dev/null | sed 's|.*/||')
      [[ -n "$file" ]] && echo "${tool_name}: ${file}"
      ;;
    *)
      echo "$tool_name"
      ;;
  esac
}

# Set to "true" to bring your editor to focus immediately when the notification
# fires, instead of waiting for you to click it.
ACTIVATE_IMMEDIATELY="${STACKNUDGE_ACTIVATE_IMMEDIATELY:-false}"

# Set to "true" to speak notifications aloud via StackVox (offline TTS).
# Requires: pip install stackvox && stackvox serve
# Optional: set STACKNUDGE_VOICE_NAME to a StackVox voice ID (default: af_heart)
# Optional: set STACKNUDGE_VOICE_SPEED to playback speed (default: 1.1)
VOICE_ENABLED="${STACKNUDGE_VOICE:-false}"
VOICE_NAME="${STACKNUDGE_VOICE_NAME:-af_heart}"
VOICE_SPEED="${STACKNUDGE_VOICE_SPEED:-1.1}"

# Banner and panel surfaces are independent; sound/voice always fire.
BANNER_ENABLED="${STACKNUDGE_BANNER:-true}"
PANEL_ENABLED="${STACKNUDGE_PANEL:-false}"
PANEL_SOCK="${HOME}/.stack-nudge/panel.sock"

# Pretty-print the agent name for the notification title
agent_label() {
  case "$1" in
    claude-code) echo "Claude Code" ;;
    cursor)      echo "Cursor" ;;
    gemini)      echo "Gemini" ;;
    codex)       echo "Codex" ;;
    *)           echo "$1" ;;
  esac
}

# Bundled voice engine paths
VENV="${HOME}/.stack-nudge/venv"
STACKVOX="${VENV}/bin/stackvox"
STACKVOX_SAY="${VENV}/bin/stackvox-say"

# Speak a message aloud via the bundled StackVox daemon.
# Auto-starts the daemon if it isn't running. Falls back silently if the
# venv isn't installed or the daemon fails to respond.
speak_notification() {
  [[ "${VOICE_ENABLED}" != "true" ]] && return
  [[ ! -x "$STACKVOX_SAY" ]] && return
  local text="$1"
  # Start daemon if socket doesn't exist yet
  if [[ ! -S "${HOME}/.cache/stackvox/daemon.sock" ]]; then
    nohup "$STACKVOX" serve >/dev/null 2>&1 &
  fi
  "$STACKVOX_SAY" --voice "${VOICE_NAME}" --speed "${VOICE_SPEED}" "${text}" 2>/dev/null &
}

# Locate one of our .app bundles. Searches ~/Applications, the script's
# own directory, and the repo build/ output (for in-tree development).
# Args: app-bundle-name (e.g. "stack-nudge.app")
# Echoes the first match, empty string if none found.
find_app_bundle() {
  local name="$1"
  for candidate in \
    "$HOME/Applications/$name" \
    "$(dirname "$0")/$name" \
    "$(dirname "$0")/build/$name"; do
    if [[ -d "$candidate" ]]; then
      printf '%s' "$candidate"
      return
    fi
  done
}

ensure_panel_running() {
  [[ "${PANEL_ENABLED}" != "true" ]] && return
  [[ -S "$PANEL_SOCK" ]] && return
  local panel_app
  panel_app=$(find_app_bundle "stack-nudge-panel.app")
  [[ -z "$panel_app" ]] && return
  # -g: launch in the background, don't bring the panel app to foreground
  open -ga "$panel_app" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -S "$PANEL_SOCK" ]] && return
    sleep 0.1
  done
}

# Walk up the process tree from this hook's parent and detect the agent
# binary, parent shell, and terminal/helper. Sets AGENT_PID, SHELL_PID,
# TERMINAL_PID, TERMINAL_APP (each empty if not found).
walk_session_chain() {
  AGENT_PID=""; SHELL_PID=""; TERMINAL_PID=""; TERMINAL_APP=""
  local pid="$PPID"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [[ -z "$pid" || "$pid" -le 1 ]] && break
    local comm
    comm=$(ps -p "$pid" -o comm= 2>/dev/null)
    [[ -z "$comm" ]] && break
    local base="${comm##*/}"
    case "$base" in
      claude|gemini|codex)
        [[ -z "$AGENT_PID" ]] && AGENT_PID="$pid"
        ;;
      bash|zsh|sh|fish|dash|ksh)
        [[ -z "$SHELL_PID" ]] && SHELL_PID="$pid"
        ;;
    esac
    case "$base" in
      "Code Helper"|"Code Helper (Plugin)"|"Code Helper (Renderer)"|Code|\
      "Cursor Helper"|"Cursor Helper (Plugin)"|"Cursor Helper (Renderer)"|Cursor|\
      iTerm2|iTerm|Terminal|Warp|WarpTerminal|ghostty|Ghostty)
        TERMINAL_PID="$pid"; TERMINAL_APP="$base"; break ;;
    esac
    pid=$(ps -p "$pid" -o ppid= 2>/dev/null | tr -d ' ')
  done
}

# Construct one JSON line and write it to the panel socket. Pass values via
# env vars rather than positional argv to keep the heredoc readable now that
# we have ~15 fields.
# Args: title message bundle_id window_title has_action(true|false)
post_to_panel() {
  [[ "${PANEL_ENABLED}" != "true" ]] && return
  ensure_panel_running
  [[ ! -S "$PANEL_SOCK" ]] && return

  walk_session_chain

  NUDGE_AGENT="$AGENT" \
  NUDGE_EVENT="$EVENT" \
  NUDGE_TITLE="$1" \
  NUDGE_MESSAGE="$2" \
  NUDGE_PROJECT="$PWD" \
  NUDGE_BUNDLE="$3" \
  NUDGE_WINDOW="$4" \
  NUDGE_IPC_HOOK="${VSCODE_IPC_HOOK_CLI:-}" \
  NUDGE_HAS_ACTION="$5" \
  NUDGE_SOCK="$PANEL_SOCK" \
  NUDGE_AGENT_PID="${AGENT_PID:-}" \
  NUDGE_SHELL_PID="${SHELL_PID:-}" \
  NUDGE_TERMINAL_PID="${TERMINAL_PID:-}" \
  NUDGE_TERMINAL_APP="${TERMINAL_APP:-}" \
  NUDGE_TERM_PROGRAM="${TERM_PROGRAM:-}" \
  NUDGE_SESSION_ID="${TERM_SESSION_ID:-${ITERM_SESSION_ID:-}}" \
  python3 - <<'PY' 2>/dev/null
import json, os, socket, time

env = os.environ
out = {
    "agent":             env["NUDGE_AGENT"],
    "event":             env["NUDGE_EVENT"],
    "title":             env["NUDGE_TITLE"],
    "message":           env["NUDGE_MESSAGE"],
    "timestamp":         time.time(),
    "has_action_button": env["NUDGE_HAS_ACTION"] == "true",
}

# Only emit fields that have values — keeps the wire payload clean.
optional = {
    "project_path":  env.get("NUDGE_PROJECT"),
    "bundle_id":     env.get("NUDGE_BUNDLE"),
    "window_title":  env.get("NUDGE_WINDOW"),
    "ipc_hook":      env.get("NUDGE_IPC_HOOK"),
    "agent_pid":     env.get("NUDGE_AGENT_PID"),
    "shell_pid":     env.get("NUDGE_SHELL_PID"),
    "terminal_pid":  env.get("NUDGE_TERMINAL_PID"),
    "terminal_app":  env.get("NUDGE_TERMINAL_APP"),
    "term_program":  env.get("NUDGE_TERM_PROGRAM"),
    "session_id":    env.get("NUDGE_SESSION_ID"),
}
for key, value in optional.items():
    if not value:
        continue
    if key.endswith("_pid"):
        try:
            out[key] = int(value)
        except ValueError:
            continue
    else:
        out[key] = value

data = (json.dumps(out) + "\n").encode()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
try:
    s.connect(env["NUDGE_SOCK"])
    s.sendall(data)
finally:
    s.close()
PY
}

notify_macos() {
  local title="$1"
  local message="$2"
  local sound="$3"
  local voice_message="${4:-$message}"

  # Detect terminal / editor bundle ID for click-to-focus
  local bundle_id
  case "${TERM_PROGRAM}" in
    vscode)
      if [[ -n "${CURSOR_TRACE_ID}" ]]; then
        bundle_id="com.todesktop.230313mzl4w4u92"  # Cursor
      else
        bundle_id="com.microsoft.VSCode"
      fi
      ;;
    iTerm.app)    bundle_id="com.googlecode.iterm2" ;;
    WarpTerminal) bundle_id="dev.warp.Warp-Stable" ;;
    ghostty)      bundle_id="com.mitchellh.ghostty" ;;
    *)            bundle_id="com.apple.Terminal" ;;
  esac

  # Map bundle ID → System Events process name for window-title capture
  local process_name
  case "$bundle_id" in
    com.todesktop.230313mzl4w4u92) process_name="Cursor" ;;
    com.microsoft.VSCode)           process_name="Code" ;;
    com.googlecode.iterm2)          process_name="iTerm2" ;;
    dev.warp.Warp-Stable)           process_name="Warp" ;;
    com.mitchellh.ghostty)          process_name="Ghostty" ;;
    com.apple.Terminal)             process_name="Terminal" ;;
    *)                              process_name="" ;;
  esac

  # Identify the source window by matching the project name ($PWD basename)
  # to window titles. This lets us suppress and focus the right window even
  # when multiple windows of the same app are open.
  local win_title=""
  if [[ -n "$process_name" ]]; then
    local project_name
    project_name=$(basename "$PWD")
    win_title=$(osascript \
      -e "tell application \"System Events\"" \
      -e "  tell process \"${process_name}\"" \
      -e "    try" \
      -e "      get title of first window whose title contains \"${project_name}\"" \
      -e "    end try" \
      -e "  end tell" \
      -e "end tell" 2>/dev/null)
  fi

  # Suppress banner only if the exact source window is currently frontmost
  local frontmost_id
  frontmost_id=$(osascript -e "id of app (path to frontmost application as text)" 2>/dev/null)
  if [[ "$frontmost_id" == "$bundle_id" && -n "$process_name" && -n "$win_title" ]]; then
    local frontmost_win
    frontmost_win=$(osascript \
      -e "tell application \"System Events\"" \
      -e "  tell process \"${process_name}\"" \
      -e "    get title of window 1" \
      -e "  end tell" \
      -e "end tell" 2>/dev/null)
    if [[ "$frontmost_win" == "$win_title" ]]; then
      afplay "/System/Library/Sounds/${sound}.aiff" 2>/dev/null
      return
    fi
  fi

  local has_action="false"
  [[ "${EVENT}" == "permission" ]] && has_action="true"

  # Post first so the panel has the event queued by the time the sound plays.
  # Backgrounded — the python3 cold-start (~50ms) shouldn't block the agent's hook.
  post_to_panel "${title}" "${message}" "${bundle_id}" "${project_name:-}" "${has_action}" &

  if [[ "${BANNER_ENABLED}" == "true" ]]; then
    fire_banner "$title" "$message" "$sound" "$bundle_id" \
      "${project_name:-}" "${win_title}" "${has_action}"
  else
    afplay "/System/Library/Sounds/${sound}.aiff" 2>/dev/null &
  fi

  speak_notification "${voice_message}"
}

fire_banner() {
  local title="$1" message="$2" sound="$3" bundle_id="$4"
  local project_name="$5" win_title="$6" has_action="$7"

  local app_bundle
  app_bundle=$(find_app_bundle "stack-nudge.app")

  if [[ -z "$app_bundle" ]]; then
    afplay "/System/Library/Sounds/${sound}.aiff" 2>/dev/null &
    osascript -e "display notification \"${message}\" with title \"${title}\" sound name \"${sound}\"" 2>/dev/null
    return
  fi

  local open_args=(
    --args
    --title "${title}" --message "${message}"
    --sound "${sound}" --activate "${bundle_id}"
  )
  [[ "${ACTIVATE_IMMEDIATELY}" == "true" ]] && open_args+=(--activate-immediately)
  [[ -n "$win_title" ]]               && open_args+=(--window-title "${project_name}")
  [[ -n "${VSCODE_IPC_HOOK_CLI}" ]]   && open_args+=(--ipc-hook "${VSCODE_IPC_HOOK_CLI}")
  open_args+=(--project-path "${PWD}")
  [[ "${has_action}" == "true" ]]     && open_args+=(--has-action-button)

  open -a "$app_bundle" "${open_args[@]}"
}

play_linux() {
  local sound_complete="/usr/share/sounds/freedesktop/stereo/complete.oga"
  local sound_bell="/usr/share/sounds/freedesktop/stereo/bell.oga"
  if command -v paplay >/dev/null 2>&1; then
    paplay "$sound_complete" 2>/dev/null || paplay "$sound_bell" 2>/dev/null
  elif command -v aplay >/dev/null 2>&1; then
    aplay -q "$sound_bell" 2>/dev/null
  elif command -v notify-send >/dev/null 2>&1; then
    notify-send "$(agent_label "$AGENT")" "Needs your attention" 2>/dev/null
  fi
}

play_windows() {
  local freq="$1"
  local dur="$2"
  powershell.exe -c "[console]::beep(${freq},${dur})" 2>/dev/null \
    || powershell -c "[console]::beep(${freq},${dur})" 2>/dev/null
}

TITLE="$(agent_label "$AGENT")"

case "$OS" in
  Darwin)
    SOUND_STOP="${STACKNUDGE_SOUND_STOP:-Glass}"
    SOUND_PERMISSION="${STACKNUDGE_SOUND_PERMISSION:-Ping}"
    case "$EVENT" in
      permission)
        ctx=$(permission_context)
        voice_ctx=$(voice_permission_context)
        notify_macos "$TITLE" "${ctx:-Waiting for your approval}" "$SOUND_PERMISSION" "${voice_ctx:-Waiting for your approval}"
        ;;
      *) notify_macos "$TITLE" "Done" "$SOUND_STOP" ;;
    esac
    ;;
  Linux)
    play_linux
    ;;
  *)
    case "$EVENT" in
      permission) play_windows 1200 400 ;;
      *)          play_windows 800 600 ;;
    esac
    ;;
esac
