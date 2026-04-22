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

# Speak a message aloud via StackVox if enabled and the daemon is reachable.
# Falls back silently if StackVox is not installed or daemon is not running.
speak_notification() {
  [[ "${VOICE_ENABLED}" != "true" ]] && return
  local text="$1"
  if command -v stackvox-say &>/dev/null; then
    stackvox-say --voice "${VOICE_NAME}" --speed "${VOICE_SPEED}" "${text}" 2>/dev/null &
  elif command -v stackvox &>/dev/null; then
    stackvox say --voice "${VOICE_NAME}" --speed "${VOICE_SPEED}" "${text}" 2>/dev/null &
  fi
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

  # Find the stack-nudge .app bundle: ~/Applications or repo
  local app_bundle
  for candidate in \
    "$HOME/Applications/stack-nudge.app" \
    "$(dirname "$0")/stack-nudge.app" \
    "$(dirname "$0")/build/stack-nudge.app"; do
    if [[ -d "$candidate" ]]; then
      app_bundle="$candidate"
      break
    fi
  done

  if [[ -n "$app_bundle" ]]; then
    # Build args array — avoids quoting hazards with window titles containing spaces
    local open_args=(
      --args
      --title "${title}" --message "${message}"
      --sound "${sound}" --activate "${bundle_id}"
    )
    [[ "${ACTIVATE_IMMEDIATELY}" == "true" ]] && open_args+=(--activate-immediately)
    [[ -n "$win_title" ]] && open_args+=(--window-title "${project_name}")
    [[ -n "${VSCODE_IPC_HOOK_CLI}" ]] && open_args+=(--ipc-hook "${VSCODE_IPC_HOOK_CLI}")
    open_args+=(--project-path "${PWD}")
    [[ "${EVENT}" == "permission" ]] && open_args+=(--has-action-button)
    # Launch via `open -a` so LaunchServices registers it — required for click-to-focus
    open -a "$app_bundle" "${open_args[@]}"
    speak_notification "${voice_message}"
  else
    # Fallback: osascript notification + sound (no click-to-focus)
    afplay "/System/Library/Sounds/${sound}.aiff" 2>/dev/null &
    osascript -e "display notification \"${message}\" with title \"${title}\" sound name \"${sound}\"" 2>/dev/null
    speak_notification "${voice_message}"
  fi
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
    case "$EVENT" in
      permission)
        ctx=$(permission_context)
        voice_ctx=$(voice_permission_context)
        notify_macos "$TITLE" "${ctx:-Waiting for your approval}" "Ping" "${voice_ctx:-Waiting for your approval}"
        ;;
      *) notify_macos "$TITLE" "Done" "Glass" ;;
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
