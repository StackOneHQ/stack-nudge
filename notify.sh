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


# Set to "true" to speak notifications aloud via StackVox (offline TTS).
# Requires: pip install stackvox && stackvox serve
# Optional: set STACKNUDGE_VOICE_NAME to a StackVox voice ID (default: af_aoede)
# Optional: set STACKNUDGE_VOICE_SPEED to playback speed (default: 1.1)
VOICE_ENABLED="${STACKNUDGE_VOICE:-false}"
VOICE_NAME="${STACKNUDGE_VOICE_NAME:-af_aoede}"
VOICE_SPEED="${STACKNUDGE_VOICE_SPEED:-1.1}"

# Map a Kokoro voice prefix to a phrase-file language code.
voice_to_lang() {
  case "${1:0:2}" in
    af|am|bf|bm) echo "en" ;;
    ff)          echo "fr" ;;
    hf|hm)       echo "hi" ;;
    if|im)       echo "it" ;;
    pf|pm)       echo "pt" ;;
    *)           echo "en" ;;
  esac
}

# Map a Kokoro voice prefix to the --lang code stackvox expects.
voice_to_kokoro_lang() {
  case "${1:0:2}" in
    af|am) echo "en-us" ;;
    bf|bm) echo "en-gb" ;;
    ff)    echo "fr-fr" ;;
    hf|hm) echo "hi" ;;
    if|im) echo "it" ;;
    pf|pm) echo "pt-br" ;;
    *)     echo "en-us" ;;
  esac
}

# Light expansion for stackvox: split hyphens/underscores, fix a couple of
# stackvox-specific tokens that the model otherwise mispronounces.
repo_name_raw() {
  local repo parts=() word
  repo=$(basename "$PWD")
  for word in $(echo "$repo" | tr '_-' '  '); do
    case "$word" in
      cli|CLI)           word="C L I" ;;
      stackone|StackOne) word="stack one" ;;
    esac
    parts+=("$word")
  done
  echo "${parts[*]}"
}

# Heavier expansion for the macOS `say` fallback — that engine mispronounces
# more acronyms, so split a wider set into letters.
repo_name_expanded() {
  local repo parts=() word
  repo=$(basename "$PWD")
  for word in $(echo "$repo" | tr '_-' '  '); do
    case "$word" in
      mcp|MCP)           word="M C P" ;;
      api|API)           word="A P I" ;;
      cli|CLI)           word="C L I" ;;
      hris|HRIS)         word="H R I S" ;;
      ai|AI)             word="A I" ;;
      stackone|StackOne) word="stack one" ;;
    esac
    parts+=("$word")
  done
  echo "${parts[*]}"
}

# Pick a phrase from the right pool (TEMPLATES_RESPONSE for stop events,
# TEMPLATES_NOTIFICATION for permission events) and format it with the
# repo name. Phrase files live next to notify.sh in phrases/<lang>.sh
# so they're co-located with the script wherever it's installed.
voice_phrase_for() {
  local event="$1"
  local lang repo

  if [[ -x "$STACKVOX" ]]; then
    lang=$(voice_to_lang "$VOICE_NAME")
    repo=$(repo_name_raw)
  else
    lang="en"
    repo=$(repo_name_expanded)
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local phrases_dir="$script_dir/phrases"
  local lang_file="$phrases_dir/$lang.sh"
  [[ -f "$lang_file" ]] || lang_file="$phrases_dir/en.sh"
  if [[ ! -f "$lang_file" ]]; then
    echo "$repo"
    return
  fi

  # shellcheck disable=SC1090
  source "$lang_file"

  local templates=()
  case "$event" in
    permission) templates=("${TEMPLATES_NOTIFICATION[@]}") ;;
    *)          templates=("${TEMPLATES_RESPONSE[@]}") ;;
  esac

  if [[ ${#templates[@]} -eq 0 ]]; then
    echo "$repo"
    return
  fi

  local template="${templates[$((RANDOM % ${#templates[@]}))]}"
  # shellcheck disable=SC2059
  printf "$template" "$repo"
}

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

# Bundled voice engine paths. stackvox 0.3.x consolidated the CLI — there
# is no separate `stackvox-say` console script anymore; speech goes through
# `stackvox say <text>` as a subcommand.
VENV="${HOME}/.stack-nudge/venv"
STACKVOX="${VENV}/bin/stackvox"

# Log a debug line when STACKNUDGE_DEBUG=true. Used for "voice was
# requested but couldn't fire" cases that previously failed silently.
nudge_debug() {
  [[ "${STACKNUDGE_DEBUG:-}" == "true" ]] || return 0
  printf '[stack-nudge] %s\n' "$*" >&2
}

# Speak a message aloud via the bundled StackVox daemon.
# Auto-starts the daemon if it isn't running. Falls back silently if the
# venv isn't installed or the daemon fails to respond — set STACKNUDGE_DEBUG=true
# to surface why.
speak_notification() {
  [[ "${VOICE_ENABLED}" != "true" ]] && return
  if [[ ! -x "$STACKVOX" ]]; then
    nudge_debug "voice requested but stackvox not found at $STACKVOX"
    return
  fi
  local text="$1"
  if [[ ! -S "${HOME}/.cache/stackvox/daemon.sock" ]]; then
    nudge_debug "stackvox daemon socket missing — starting daemon"
    nohup "$STACKVOX" serve >/dev/null 2>&1 &
  fi
  local kokoro_lang
  kokoro_lang=$(voice_to_kokoro_lang "$VOICE_NAME")
  "$STACKVOX" say --voice "${VOICE_NAME}" --lang "${kokoro_lang}" --speed "${VOICE_SPEED}" "${text}" 2>/dev/null &
}

# Locate one of our .app bundles. Searches ~/Applications, the script's
# own directory, and the repo build/ output (for in-tree development).
# Args: app-bundle-name (e.g. "stack-nudge.app")
# Echoes the first match, empty string if none found.
ensure_app_running() {
  [[ -S "$PANEL_SOCK" ]] && return
  local app_path="$HOME/Applications/stack-nudge.app"
  [[ ! -d "$app_path" ]] && return
  # -g: launch in the background, don't steal focus from the editor
  open -ga "$app_path" 2>/dev/null
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
      Zed|zed|\
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
  ensure_app_running
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
  NUDGE_FIFO="${6:-}" \
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
    "fifo_path":     env.get("NUDGE_FIFO"),
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

  # Detect terminal / editor bundle ID for click-to-focus.
  # Zed sets TERM_PROGRAM=zed in its integrated terminal as of zed-industries/zed#14213.
  local bundle_id
  case "${TERM_PROGRAM}" in
    vscode)
      if [[ -n "${CURSOR_TRACE_ID}" ]]; then
        bundle_id="com.todesktop.230313mzl4w4u92"  # Cursor
      else
        bundle_id="com.microsoft.VSCode"
      fi
      ;;
    zed)          bundle_id="dev.zed.Zed" ;;
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
    dev.zed.Zed)                    process_name="Zed" ;;
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

  # Suppress banner only if the exact source window is currently frontmost.
  # Gated on STACKNUDGE_MUTE_WHEN_FOCUSED — set to false to always notify
  # regardless of which window has focus.
  local mute_when_focused="${STACKNUDGE_MUTE_WHEN_FOCUSED:-true}"
  if [[ "$mute_when_focused" == "true" ]]; then
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
        # Source window is already focused — minimal signal. Skip sound when
        # voice is on (voice itself is suppressed here too, but keep the
        # "voice replaces sound" rule consistent across all paths).
        if [[ "${VOICE_ENABLED}" != "true" ]]; then
          afplay "/System/Library/Sounds/${sound}.aiff" 2>/dev/null
        fi
        return
      fi
    fi
  fi

  local has_action="false"
  local fifo_path=""
  if [[ "${EVENT}" == "permission" ]]; then
    has_action="true"
    fifo_path=$(create_perm_fifo)
  fi

  # Post to the persistent app — it handles both the panel history and the
  # UNUserNotification banner based on the user's config. Backgrounded so
  # Python startup (~50ms) doesn't block the agent hook.
  post_to_panel "${title}" "${message}" "${bundle_id}" "${project_name:-}" "${has_action}" "${fifo_path}" &

  # Sound fires independently via afplay — guaranteed even if macOS throttles
  # or the app isn't running yet. Voice replaces the chime when enabled.
  if [[ "${VOICE_ENABLED}" != "true" ]]; then
    afplay "/System/Library/Sounds/${sound}.aiff" 2>/dev/null &
  fi

  speak_notification "${voice_message}"

  # For permission events, block reading from the FIFO. The user's Allow
  # click in the panel/banner writes "allow" to it; we then output the
  # PermissionRequest decision JSON to stdout so Claude Code skips its
  # own UI prompt entirely. Timeout falls back to Claude Code's UI.
  if [[ -n "$fifo_path" ]]; then
    wait_for_permission_response "$fifo_path"
  fi
}

# Create a unique FIFO at /tmp for the user's response. Echoes the path.
# Returns empty if mkfifo fails.
create_perm_fifo() {
  local fifo
  fifo="/tmp/stack-nudge-perm-$$-$(date +%s)-$RANDOM.fifo"
  if mkfifo -m 0600 "$fifo" 2>/dev/null; then
    echo "$fifo"
  fi
}

# Block reading the user's decision from the FIFO with a timeout. Outputs
# the PermissionRequest JSON to stdout when read; silent on timeout so
# Claude Code falls back to its own UI prompt.
# Uses Python because bash's `read -t` doesn't time out the FIFO open() call.
wait_for_permission_response() {
  local fifo="$1"
  local timeout=550  # Claude Code's hook timeout defaults to 600s — leave buffer

  trap 'rm -f "$fifo"' EXIT

  local decision
  decision=$(NUDGE_FIFO="$fifo" NUDGE_TIMEOUT="$timeout" python3 - <<'PY' 2>/dev/null
import os, select, sys
fifo = os.environ["NUDGE_FIFO"]
timeout = float(os.environ["NUDGE_TIMEOUT"])
try:
    fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
except OSError:
    sys.exit(0)
try:
    r, _, _ = select.select([fd], [], [], timeout)
    if r:
        data = os.read(fd, 1024).decode("utf-8", errors="replace").strip()
        sys.stdout.write(data)
finally:
    os.close(fd)
PY
)

  case "$decision" in
    allow)
      printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}\n'
      ;;
    deny)
      printf '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"Denied via stack-nudge"}}}\n'
      ;;
  esac
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
        # Banner stays specific (tool / file context) so the user can read
        # what's pending. Voice picks from the conversational notification
        # pool, formatted with the repo name — same shape as
        # stackone-say-hooks.
        ctx=$(permission_context)
        voice_msg=$(voice_phrase_for permission)
        notify_macos "$TITLE" "${ctx:-Waiting for your approval}" "$SOUND_PERMISSION" "$voice_msg"
        ;;
      *)
        voice_msg=$(voice_phrase_for stop)
        notify_macos "$TITLE" "Done" "$SOUND_STOP" "$voice_msg"
        ;;
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
