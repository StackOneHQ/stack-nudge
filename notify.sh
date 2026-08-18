#!/usr/bin/env bash
# stack-nudge: Cross-platform notifications for AI coding agent hooks
#
# The installed copy at ~/.stack-nudge/notify.sh is what agent hooks actually
# invoke, and it is only written by install.sh / the first-launch wizard; app
# updates swap the .app bundle alone. The stamp below is how the app spots a copy
# older than itself and replaces it (Bootstrap.refreshNotifyScriptIfNeeded);
# release-please rewrites it in step with panel/Info.plist. Don't hand-edit it.
# stack-nudge-version: 1.28.2 # x-release-please-version
#
# Usage: notify.sh <agent> <event>
#   agent: claude-code | cursor | gemini | codex | <any name>
#   event: stop | permission
# Example: notify.sh claude-code stop

AGENT="${1:-agent}"
EVENT="${2:-stop}"
OS="$(uname -s 2>/dev/null || echo Windows)"

# Load user config (overrides defaults below). Parse as KEY=VALUE data only —
# never `source` it, so anything able to write to this file (a compromised
# postinstall, a stray tool) can't get arbitrary code to run on every hook
# event. Only STACKNUDGE_* keys are recognised; anything else is ignored.
# Copy notify.conf.example to ~/.stack-nudge/config to customise.
load_stacknudge_config() {
  local config="${HOME}/.stack-nudge/config"
  [[ -f "$config" ]] || return 0
  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?(STACKNUDGE_[A-Z0-9_]+)=(.*)$ ]] || continue
    key="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    # Strip one layer of matching surrounding quotes, if present.
    if [[ "$value" =~ ^\"(.*)\"$ ]] || [[ "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    printf -v "$key" '%s' "$value"
  done < "$config"
}
load_stacknudge_config

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
      # Truncate in jq (characters), not `cut -c` (bytes under a non-UTF-8 locale,
      # which hooks can inherit). A half-sliced multibyte character survives
      # python3's surrogateescape into the socket JSON, where EventListener fails
      # to decode the line and drops the whole event silently.
      printf '%s' "$HOOK_JSON" | jq -r '(.tool_input.command // empty) | .[0:60]' 2>/dev/null \
        | head -1
      ;;
    Write|Edit|MultiEdit)
      local file
      file=$(printf '%s' "$HOOK_JSON" | jq -r '.tool_input.file_path // empty' 2>/dev/null | sed 's|.*/||')
      [[ -n "$file" ]] && echo "${tool_name}: ${file}"
      ;;
    apply_patch)
      # Codex's edit tool. tool_input carries a patch envelope rather than a
      # plain file_path; pull the first target file out of the patch body.
      # tool_input may be the patch string itself or wrap it under .input/.patch.
      local patch file
      patch=$(printf '%s' "$HOOK_JSON" \
        | jq -r '.tool_input | if type=="string" then . else (.input // .patch // empty) end' 2>/dev/null)
      file=$(printf '%s\n' "$patch" \
        | grep -m1 -oE '^\*\*\* (Add|Update|Delete) File: .+' \
        | sed -E 's/^.*File: //; s|.*/||')
      if [[ -n "$file" ]]; then echo "apply_patch: ${file}"; else echo "apply_patch"; fi
      ;;
    AskUserQuestion)
      # Without this the body read a bare "AskUserQuestion". Same jq truncation as
      # the Bash case above.
      local question
      question=$(printf '%s' "$HOOK_JSON" \
        | jq -r '(.tool_input.questions[0].question // empty) | .[0:60]' 2>/dev/null | head -1)
      if [[ -n "$question" ]]; then echo "$question"; else echo "Needs your input"; fi
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
    apply_patch)
      local patch file
      patch=$(printf '%s' "$HOOK_JSON" \
        | jq -r '.tool_input | if type=="string" then . else (.input // .patch // empty) end' 2>/dev/null)
      file=$(printf '%s\n' "$patch" \
        | grep -m1 -oE '^\*\*\* (Add|Update|Delete) File: .+' \
        | sed -E 's/^.*File: //; s|.*/||')
      if [[ -n "$file" ]]; then echo "apply_patch: ${file}"; else echo "Edit needs approval"; fi
      ;;
    AskUserQuestion)
      # Speak the short header ("Widget cadence") rather than the full question,
      # which runs to a paragraph and doesn't read aloud well.
      local header
      header=$(printf '%s' "$HOOK_JSON" \
        | jq -r '.tool_input.questions[0].header // empty' 2>/dev/null | head -1)
      if [[ -n "$header" ]]; then echo "${header} needs your answer"; else echo "A question needs your answer"; fi
      ;;
    *)
      echo "$tool_name"
      ;;
  esac
}


# STACKNUDGE_VOICE_NAME is read by the .app to pick the Kokoro voice. We
# keep a local copy here only for phrase-language selection — voice_phrase_for
# uses it to pick the right phrases/<lang>.sh file. Voice playback itself
# is the app's job (see Speaker.swift) so afplay/stackvox children get
# torn down when the user quits the app.
VOICE_NAME="${STACKNUDGE_VOICE_NAME:-af_aoede}"

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
#
# Results come back in two globals rather than on stdout: the app needs the
# chosen template with its %s intact so it can substitute the session's name
# (which lives in the app's own store, invisible from here), and it has to be
# the *same* pick as the substituted phrase, which a second function couldn't
# guarantee because the pool is sampled at random. VOICE_PHRASE stays the
# fallback for un-renamed sessions and for an app older than this field.
VOICE_PHRASE=""
VOICE_TEMPLATE=""
voice_phrase_for() {
  local event="$1"
  local lang repo
  VOICE_PHRASE=""
  VOICE_TEMPLATE=""

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
    VOICE_PHRASE="$repo"
    return
  fi

  # Parse the phrase arrays out of the file as DATA — never `source` it. The
  # file lives in a user-writable install dir, so sourcing ran arbitrary shell
  # on every hook event. extract_phrase_array does a pure text scan of the
  # `NAME=( "…" "…" )` literal (handles \" and \\; a `)` inside a quote is safe).
  extract_phrase_array() {
    awk -v name="$2" '
      BEGIN { active=0; instr=0; esc=0; cur=""; opener=name "=(" }
      {
        line=$0; i=1; n=length(line)
        if (!active) {
          if (substr(line,1,length(opener))==opener) { active=1; i=length(opener)+1 }
          else next
        }
        for (; i<=n; i++) {
          c=substr(line,i,1)
          if (instr) {
            if (esc) { cur=cur c; esc=0 }
            else if (c=="\\") { esc=1 }
            else if (c=="\"") { printf "%s%c", cur, 0; cur=""; instr=0 }
            else { cur=cur c }
          } else if (c=="\"") { instr=1 }
          else if (c==")") { active=0; exit }
        }
      }
    ' "$1"
  }
  local item
  TEMPLATES_RESPONSE=()
  TEMPLATES_NOTIFICATION=()
  while IFS= read -r -d '' item; do TEMPLATES_RESPONSE+=("$item"); done \
    < <(extract_phrase_array "$lang_file" TEMPLATES_RESPONSE)
  while IFS= read -r -d '' item; do TEMPLATES_NOTIFICATION+=("$item"); done \
    < <(extract_phrase_array "$lang_file" TEMPLATES_NOTIFICATION)

  # Layer user-managed phrases from phrases.user.json on top of the shipped
  # arrays (disabled removals + custom additions). No `eval`: each pool's
  # current items go in as positional args and the filtered result comes back
  # NUL-delimited, so a custom phrase containing $(...) or a quote stays inert.
  local user_json="${HOME}/.stack-nudge/phrases.user.json"
  if [[ -f "$user_json" ]] && command -v jq >/dev/null 2>&1; then
    apply_user_phrases() {
      local pool="$1"; shift
      local disabled d skip elem
      local result=()
      disabled=$(jq -r --arg lang "$lang" --arg pool "$pool" \
                 '.[$lang][$pool].disabled[]?' "$user_json" 2>/dev/null)
      for elem in "$@"; do
        skip=0
        if [[ -n "$disabled" ]]; then
          while IFS= read -r d; do
            [[ "$elem" == "$d" ]] && { skip=1; break; }
          done <<< "$disabled"
        fi
        [[ $skip -eq 0 ]] && result+=("$elem")
      done
      while IFS= read -r elem; do
        [[ -n "$elem" ]] && result+=("$elem")
      done < <(jq -r --arg lang "$lang" --arg pool "$pool" \
               '.[$lang][$pool].custom[]?' "$user_json" 2>/dev/null)
      [[ ${#result[@]} -gt 0 ]] && printf '%s\0' "${result[@]}"
    }
    local tmp=()
    while IFS= read -r -d '' item; do tmp+=("$item"); done \
      < <(apply_user_phrases response "${TEMPLATES_RESPONSE[@]}")
    TEMPLATES_RESPONSE=("${tmp[@]}")
    tmp=()
    while IFS= read -r -d '' item; do tmp+=("$item"); done \
      < <(apply_user_phrases notification "${TEMPLATES_NOTIFICATION[@]}")
    TEMPLATES_NOTIFICATION=("${tmp[@]}")
  fi

  local templates=()
  case "$event" in
    permission) templates=("${TEMPLATES_NOTIFICATION[@]}") ;;
    *)          templates=("${TEMPLATES_RESPONSE[@]}") ;;
  esac

  if [[ ${#templates[@]} -eq 0 ]]; then
    VOICE_PHRASE="$repo"
    return
  fi

  local template="${templates[$((RANDOM % ${#templates[@]}))]}"
  VOICE_TEMPLATE="$template"
  # Substitute the repo name into the %s placeholder ourselves rather than
  # letting the phrase be a printf format string — a phrase (especially a
  # user-supplied one from phrases.user.json) with stray % tokens would
  # otherwise corrupt or truncate the spoken output.
  VOICE_PHRASE="${template//%s/$repo}"
}

PANEL_SOCK="${HOME}/.stack-nudge/panel.sock"

# Pretty-print the agent name for the notification title
agent_label() {
  case "$1" in
    claude-code)         echo "Claude Code" ;;
    cursor)              echo "Cursor" ;;
    gemini)              echo "Gemini" ;;
    codex)               echo "Codex" ;;
    agy|antigravity|antigravity-cli)
                         echo "Antigravity" ;;
    *)                   echo "$1" ;;
  esac
}

# True when this agent's permission hook blocks on stdout for an allow/deny
# decision, so the panel's Approve/Deny can actually drive it. Claude Code and
# Codex use the blocking PermissionRequest hook with the hookSpecificOutput
# decision schema. Gemini and Antigravity route permission alerts through the
# fire-and-forget Notification hook, which can't consume a decision — creating
# a FIFO and blocking on it for those just burns the hook's timeout budget and
# shows an Allow button that does nothing. (Phase 2 will add antigravity here
# once it's wired via the decision-capable PreToolUse hook.)
agent_supports_decision() {
  case "$AGENT" in
    claude-code|codex) return 0 ;;
    *)                 return 1 ;;
  esac
}

# Agent-initiated question (multi-select / open prompt), not a tool
# permission. Approving in the panel would write "allow" to the FIFO,
# which CC interprets as "press Enter on the highlighted option" — making
# it pick a default. By emitting has_action=false, panel Enter falls
# through to focusing the editor so the user answers in the terminal.
is_question_event() {
  [[ "$AGENT" != "claude-code" ]] && return 1
  command -v jq &>/dev/null || return 1
  [[ -z "$HOOK_JSON" ]] && return 1
  local tool_name
  tool_name=$(printf '%s' "$HOOK_JSON" | jq -r '.tool_name // empty' 2>/dev/null)
  case "$tool_name" in
    AskUserQuestion) return 0 ;;
    *)               return 1 ;;
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

# Auto-launch the .app if the panel socket isn't already up. Checks the
# new bundle name first (StackNudge.app, 1.7+) then falls back to the
# pre-rename name (stack-nudge.app) so an in-flight upgrade — where the
# old bundle is still running with the new hook script — keeps working.
ensure_app_running() {
  [[ -S "$PANEL_SOCK" ]] && return
  # User explicitly Quit. Stay quiet until they reopen the app. Marker
  # is cleared on the next manual launch by Bootstrap.clearUserQuitMarker.
  [[ -f "$HOME/.stack-nudge/user-quit" ]] && return
  local app_path=""
  if [[ -d "$HOME/Applications/StackNudge.app" ]]; then
    app_path="$HOME/Applications/StackNudge.app"
  elif [[ -d "$HOME/Applications/stack-nudge.app" ]]; then
    app_path="$HOME/Applications/stack-nudge.app"
  else
    return
  fi
  # -g: launch in the background, don't steal focus from the editor
  open -ga "$app_path" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [[ -S "$PANEL_SOCK" ]] && return
    sleep 0.1
  done
}

# Ask iTerm2 for the user-visible name of the session running on the
# current tty (i.e. the tab/pane the agent lives in). Sets ITERM_TAB_NAME
# to the empty string on any failure path — first-run TCC prompt, iTerm2
# not running, osascript timeout, no match. We deliberately match by tty
# rather than "current session" so a backgrounded iTerm2 still resolves.
#
# Cost: ~30-80ms per event on a warm osascript. Skipped entirely outside
# iTerm.app so non-iTerm users pay nothing.
detect_iterm_tab_name() {
  ITERM_TAB_NAME=""
  [[ "${TERM_PROGRAM:-}" != "iTerm.app" ]] && return
  local tty_path
  tty_path=$(tty 2>/dev/null) || return
  [[ -z "$tty_path" || "$tty_path" == "not a tty" ]] && return

  # Pass the tty path through the environment and read it back with
  # `system attribute` inside a quoted heredoc, rather than letting bash
  # interpolate it into the script text — keeps an unusual /dev path (or a
  # symlinked pseudo-tty name) from breaking out of the AppleScript string.
  ITERM_TAB_NAME=$(STACKNUDGE_TTY="$tty_path" osascript <<'APPLESCRIPT' 2>/dev/null || true
set ttyPath to system attribute "STACKNUDGE_TTY"
tell application "iTerm2"
  repeat with w in windows
    repeat with t in tabs of w
      repeat with s in sessions of t
        if (tty of s) is equal to ttyPath then
          return name of s
        end if
      end repeat
    end repeat
  end repeat
  return ""
end tell
APPLESCRIPT
  )
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
      claude|gemini|codex|agy)
        [[ -z "$AGENT_PID" ]] && AGENT_PID="$pid"
        ;;
      bash|zsh|sh|fish|dash|ksh)
        [[ -z "$SHELL_PID" ]] && SHELL_PID="$pid"
        ;;
    esac
    case "$base" in
      "Code Helper"|"Code Helper (Plugin)"|"Code Helper (Renderer)"|Code|\
      "Cursor Helper"|"Cursor Helper (Plugin)"|"Cursor Helper (Renderer)"|Cursor|\
      "Antigravity Helper"|"Antigravity Helper (Plugin)"|"Antigravity Helper (Renderer)"|Antigravity|\
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
#       fifo_path voice_message sound_name bypass_mute(true|false)
# The matching voice template rides along from the VOICE_TEMPLATE global that
# voice_phrase_for sets, alongside the other globals read here ($AGENT, $PWD,
# the session chain) rather than being threaded through as a tenth positional.
post_to_panel() {
  ensure_app_running
  [[ ! -S "$PANEL_SOCK" ]] && return

  walk_session_chain
  detect_iterm_tab_name

  # Cap what the exec carries: env and argv share ARG_MAX (1 MiB on macOS), and a
  # PermissionRequest payload can hold a whole file's contents in tool_input.
  # Overflowing it fails the python3 exec, which would lose the event entirely.
  # The fields read from it are a few hundred bytes deep in a Stop payload, so a
  # 32 KiB cap never bites for the events that need them.
  local hook_json="$HOOK_JSON"
  (( ${#hook_json} > 32768 )) && hook_json=""

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
  NUDGE_VOICE_MESSAGE="${7:-}" \
  NUDGE_VOICE_TEMPLATE="${VOICE_TEMPLATE:-}" \
  NUDGE_SOUND="${8:-}" \
  NUDGE_BYPASS_MUTE="${9:-false}" \
  NUDGE_SOCK="$PANEL_SOCK" \
  NUDGE_AGENT_PID="${AGENT_PID:-}" \
  NUDGE_SHELL_PID="${SHELL_PID:-}" \
  NUDGE_TERMINAL_PID="${TERMINAL_PID:-}" \
  NUDGE_TERMINAL_APP="${TERMINAL_APP:-}" \
  NUDGE_TERM_PROGRAM="${TERM_PROGRAM:-}" \
  NUDGE_SESSION_ID="${TERM_SESSION_ID:-${ITERM_SESSION_ID:-}}" \
  NUDGE_ITERM_TAB_NAME="${ITERM_TAB_NAME:-}" \
  NUDGE_HOOK_JSON="$hook_json" \
  python3 - <<'PY' 2>/dev/null
import json, os, socket, time

env = os.environ

# session_id / transcript_path come straight out of the hook JSON. Parsed here
# rather than with jq upstream: only macOS 15+ ships /usr/bin/jq, and the old
# `command -v jq && … || true` form degraded to an empty string when it was
# absent, which the panel can't distinguish from "no session". Missing
# claude_session_id silently drops the whole handoff record
# (PanelController.captureHandoff), leaving the Tickets tab empty. python3 is
# already required to reach the socket at all, so parsing here adds no dependency.
def hook_field(name):
    raw = env.get("NUDGE_HOOK_JSON") or ""
    if not raw:
        return None
    try:
        parsed = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(parsed, dict):
        return None
    value = parsed.get(name)
    return value if isinstance(value, str) and value else None

out = {
    "agent":             env["NUDGE_AGENT"],
    "event":             env["NUDGE_EVENT"],
    "title":             env["NUDGE_TITLE"],
    "message":           env["NUDGE_MESSAGE"],
    "timestamp":         time.time(),
    "has_action_button": env["NUDGE_HAS_ACTION"] == "true",
    "bypass_mute":       env.get("NUDGE_BYPASS_MUTE", "false") == "true",
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
    "iterm_tab_name": env.get("NUDGE_ITERM_TAB_NAME"),
    "claude_session_id": hook_field("session_id"),
    "transcript_path":   hook_field("transcript_path"),
    "voice_message": env.get("NUDGE_VOICE_MESSAGE"),
    "voice_template": env.get("NUDGE_VOICE_TEMPLATE"),
    "sound_name":    env.get("NUDGE_SOUND"),
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

  # Ghostty same-project tab disambiguation (deferred to upstream):
  # When multiple Ghostty tabs share the same cwd, the AppleScript in
  # AppActivator.focusGhosttyTab lands on whichever cwd-matching tab
  # comes first — which may not be the source tab. The right fix
  # requires the hook to identify the Ghostty tab hosting this shell's
  # PID. Ghostty 1.3.x exposes only id/name/working-directory/class on
  # terminals — no pid, no tty — so there's no AppleScript-only way
  # to map "this PID" → "this tab". An earlier attempt captured
  # `id of terminal of selected tab of front window` at event time,
  # but `selected tab` reflects the user's current focus, not the
  # agent's tab, so it gave wrong results when the user had switched
  # away before the hook fired.
  # Ghostty PR #11922 adds `pid` to terminals (target: 1.4.0). When
  # that ships we can match agent_pid directly — replace the cwd-only
  # AppleScript with a pid match in AppActivator.

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
  # to window titles. The app uses this to disambiguate which editor window
  # is the source (for both click-to-focus and mute-when-focused).
  local win_title=""
  local project_name
  project_name=$(basename "$PWD")
  if [[ -n "$process_name" ]]; then
    # Pass the project name through the environment and read it back inside
    # AppleScript via `system attribute`, rather than interpolating it into the
    # script text — a directory named `foo" & do shell script "…` would
    # otherwise close the string and inject AppleScript/shell. process_name is
    # safe to interpolate (it comes from the fixed bundle-id allowlist above).
    win_title=$(STACKNUDGE_PROJECT_NAME="$project_name" osascript \
      -e "set projectName to system attribute \"STACKNUDGE_PROJECT_NAME\"" \
      -e "tell application \"System Events\"" \
      -e "  tell process \"${process_name}\"" \
      -e "    try" \
      -e "      get title of first window whose title contains projectName" \
      -e "    end try" \
      -e "  end tell" \
      -e "end tell" 2>/dev/null)
  fi

  # Only offer the in-panel Allow/Deny (and block on a FIFO for the response)
  # when the agent's hook can actually consume a decision. For observability-
  # only agents the banner still shows; the user approves in the agent's own UI.
  local has_action="false"
  local fifo_path=""
  if [[ "${EVENT}" == "permission" ]] && agent_supports_decision && ! is_question_event; then
    has_action="true"
    fifo_path=$(create_perm_fifo)
  fi

  # Audio (chime + voice) and mute-when-focused now live in the .app —
  # so quitting stack-nudge actually silences the bell, and the cdhash-
  # stable signed bundle can manage afplay/stackvox child lifetimes.
  # This hook just forwards the curated phrase and sound name; the app
  # decides whether to play them based on PanelConfig + frontmost window.
  #
  # The welcome event (legacy install.sh post-install confirmation) sets
  # bypass_mute=true so the user hears it even while looking at the
  # install terminal.
  local bypass_mute="false"
  [[ "${EVENT}" == "welcome" ]] && bypass_mute="true"

  # Pass the captured window title (not the project basename) so the
  # in-app mute-when-focused check has the right value to compare
  # against the frontmost window. project_name is still derived from $PWD
  # via NUDGE_PROJECT inside post_to_panel.
  post_to_panel "${title}" "${message}" "${bundle_id}" "${win_title}" \
    "${has_action}" "${fifo_path}" "${voice_message}" "${sound}" "${bypass_mute}" &

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
  # Place the FIFO inside a private mktemp dir (mode 0700, CSPRNG-named) rather
  # than a $RANDOM-suffixed /tmp path — $RANDOM is only 16-bit, so the old name
  # was guessable, letting a local attacker pre-create the FIFO or inject a
  # decision. The dir is removed alongside the FIFO in wait_for_permission_response.
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/stack-nudge-perm.XXXXXXXX" 2>/dev/null) || return
  local fifo="$dir/fifo"
  if mkfifo -m 0600 "$fifo" 2>/dev/null; then
    echo "$fifo"
  else
    rmdir "$dir" 2>/dev/null
  fi
}

# Block reading the user's decision from the FIFO with a timeout. Outputs
# the PermissionRequest JSON to stdout when read; silent on timeout so
# Claude Code falls back to its own UI prompt.
# Uses Python because bash's `read -t` doesn't time out the FIFO open() call.
wait_for_permission_response() {
  local fifo="$1"
  local timeout=550  # Claude Code's hook timeout defaults to 600s — leave buffer

  trap 'rm -f "$fifo"; rmdir "$(dirname "$fifo")" 2>/dev/null' EXIT

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
        # Called plainly, not in a command substitution: the results come back
        # in globals and a subshell would drop VOICE_TEMPLATE.
        voice_phrase_for permission
        notify_macos "$TITLE" "${ctx:-Waiting for your approval}" "$SOUND_PERMISSION" "$VOICE_PHRASE"
        ;;
      welcome)
        # Fired once by install.sh so the user sees what a notification
        # looks like and macOS prompts for notification permission while
        # they're still in the install terminal, not mid-work later.
        #
        # The banner keeps the ⌘⌥ glyphs; the spoken variant spells them out.
        # stackvox's --normalize doesn't expand modifier glyphs, so leaving the
        # voice text to default to the banner text made the engine read the
        # shortcut as nothing. Passing "" here did NOT opt out of speech — the
        # ${4:-$message} default treats empty as unset and falls back to the
        # glyph text, which is exactly what went wrong.
        notify_macos "stack-nudge" "You're all set. Press ⌘⌥N to open the panel." "$SOUND_STOP" \
          "You're all set. Press command option N to open the panel."
        ;;
      *)
        voice_phrase_for stop
        notify_macos "$TITLE" "Done" "$SOUND_STOP" "$VOICE_PHRASE"
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
