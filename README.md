<div align="center">
  <img src="assets/logo_full.png" alt="stack-nudge" width="300" />
  <p><strong>Notifications for AI coding agents.</strong></p>
  <p>Get a banner + sound when your agent finishes a task or pauses for your approval — step away without missing a beat.</p>
</div>

---

## Supports

| Agent | Status |
|-------|--------|
| Claude Code | ✅ |
| Cursor | ✅ |
| Gemini CLI | ✅ *(experimental)* |
| Codex | ✅ *(experimental)* |
| Any hooks-capable agent | ✅ — point it at `notify.sh` |

**Platforms:** macOS (native banners + click-to-focus) · Linux (PulseAudio / ALSA / libnotify) · Windows (Git Bash / WSL)

## Install

**Prerequisites:** Python ≥ 3.10 (the bundled voice engine [stackvox](https://github.com/StackOneHQ/stackvox) requires it). macOS ships 3.9 by default — install a newer one with `brew install python@3.13`, or set `STACKNUDGE_PYTHON=/path/to/python3` to point at one explicitly.

```bash
git clone https://github.com/StackOneHQ/stack-nudge.git
cd stack-nudge
./install.sh
```

The installer auto-detects which agents you have configured (`~/.claude`, `~/.cursor`, `~/.gemini`) and wires up their hooks.

On macOS it also installs the native `stack-nudge.app` for click-to-focus banners. Without the binary, macOS falls back to `osascript` notifications (no click-to-focus).

## How it works

Each supported agent has a hooks system. `stack-nudge` registers these hooks:

| Agent | Event | What happens |
|-------|-------|--------------|
| Claude Code | `Stop` | Banner when the turn ends |
| Claude Code | `PermissionRequest` | Banner when Claude pauses for approval |
| Cursor | `stop` | Banner when agent turn ends |
| Gemini CLI | session end | Banner when agent finishes |

The hook calls `notify.sh <agent> <event>`, which plays a sound and shows a banner via:

1. **macOS** — the native `stack-nudge.app` (click-to-focus routes back to your editor)
2. **Linux** — `paplay` / `aplay` / `notify-send`
3. **Windows** — `powershell [console]::beep`

### Click-to-focus (macOS)

When you click the banner, `stack-nudge.app` uses System Events to raise the exact window that triggered the notification — even if you have multiple Cursor or terminal windows open. Supported apps:

- Cursor, VS Code, Zed
- iTerm2, Warp, Ghostty, Terminal.app

If the target app is already in focus when the notification fires, the banner is suppressed and only the sound plays.

> **Note on Zed:** Zed itself doesn't expose an external hook system, so stack-nudge relies on the agent's hooks (e.g. `~/.claude/settings.json` for Claude Code) firing from inside Zed's integrated terminal. Click-to-focus and frontmost-window suppression are wired up via `TERM_PROGRAM=zed`, which Zed sets automatically.

### Immediate focus mode

If you'd rather have your editor focus automatically — no click needed:

```bash
export STACKNUDGE_ACTIVATE_IMMEDIATELY=true
```

Add that to your shell profile.

### Keyboard-native panel (macOS)

If you'd rather not click banners with the mouse, stack-nudge can run a small floating panel that you summon with a hotkey. It has three tabs — **Events**, **Sessions**, and **Settings** — and is fully keyboard-driven.

Enable it in `~/.stack-nudge/config`:

```bash
STACKNUDGE_PANEL=true
STACKNUDGE_BANNER=false   # optional — suppress macOS banners when using the panel
```

Default hotkey is `cmd+opt+n`. Hit it from anywhere to summon the panel; hit it again while focused to hide. Switch tabs with `Cmd+1` (Events), `Cmd+2` (Sessions), `Cmd+3` (Settings) — or click them.

The panel registers a launchd agent so it starts at login when enabled. Banner and panel can run together, alone, or both off — the sound and voice still fire as passive signals.

#### Events tab

Recent nudges in chronological order. Each shows agent, message, project name, time.

| Key | Action |
|-----|--------|
| `↑ ↓` | Move selection |
| `⏎` | Approve permission / focus source editor |
| `O` | Focus source editor without approving |
| `⌫` | Dismiss the selected nudge locally |
| `Esc` | Hide the panel |

When you press `⏎` on a permission event in a VS Code / Cursor terminal pane, stack-nudge walks the editor's accessibility tree to focus the right pane (matched by the agent name in the tab title) before sending Enter — so the approval keystroke lands in the agent's terminal, not whatever was last focused. Falls back gracefully if the pane can't be found.

#### Sessions tab

Live list of running agent processes (`claude`, `gemini`, `codex` — including node-hosted variants like `gemini-cli`). Polls every 3 seconds while visible. Sessions that exit linger for 30s with `ended Ns ago`.

| Key | Action |
|-----|--------|
| `↑ ↓` | Move selection |
| `⏎` | Focus the session's source terminal |
| `n` | Rename the selected session inline |
| `⌫` | Send SIGTERM to the agent process |
| `Esc` | Hide the panel |

#### Settings tab

Reachable from the tab strip or `Cmd+3`. Keyboard-driven rows for hotkey, banner/voice toggles, sound picks (with preview-on-cycle), voice picker (with preview-on-cycle using a random conversational phrase), speed, and shortcuts to the permissions checker, config file, and quit.

| Key | Action |
|-----|--------|
| `↑ ↓` / `Tab` | Move selection |
| `← →` | Cycle the selected row's value (toggles flip, sounds/voices step) |
| `⏎` | Activate (toggles flip, action rows fire, hotkey row records a new combo) |
| `Esc` | Back to events |

The hotkey row records live: press `⏎` on it, press the new combo, and stack-nudge re-registers the global hotkey and writes it to config. If the combo is already grabbed by another app, the previous one stays and an inline error explains why.

stack-nudge also watches `~/.stack-nudge/config` for external edits, so changes you make via "Open config file…" or another editor flow back into the running panel without a restart.

### Menu bar (macOS)

When the panel daemon is running, a bell icon appears in your menu bar. The same items you can reach from the in-panel Settings tab are mirrored here for one-click access without summoning the panel:

| Item | What it does |
|------|--------------|
| `Hotkey · …` | Shows your current hotkey (info only) |
| `Show banners` | Toggles `STACKNUDGE_BANNER`. Enabling fires a confirmation banner. |
| `Voice notifications` | Toggles `STACKNUDGE_VOICE`. Enabling speaks *"Voice notifications enabled"*. |
| `Show panel` | Brings the floating panel up (handy when no events are queued) |
| `Check permissions…` | Opens the permissions checker (see below) |
| `Open config file…` | Opens `~/.stack-nudge/config` in your default editor |
| `Quit stack-nudge panel` | Exits the daemon |

Toggles re-read the live config every time the menu opens, so changes you make to `~/.stack-nudge/config` directly stay in sync. Banner and voice changes take effect immediately for the next nudge — no daemon restart needed.

### Permissions (macOS)

The panel needs two privacy grants to fully work:

| Permission                       | Why                                                                                                |
|----------------------------------|----------------------------------------------------------------------------------------------------|
| **Accessibility**                | Required for `AXIsProcessTrusted()` to return true — without it, the Enter-to-approve keystroke is silently skipped |
| **Automation → System Events**   | Required for the AppleScript that focuses the right app and window when you act on a nudge        |

Open **Check permissions…** from the menu bar for a live status view. Each row has:

- **Reset & prompt** — clears the existing TCC entry, then triggers macOS's standard grant dialog
- **Settings** — opens System Settings to the right pane

The window is set to float above System Settings so you can grant both in one pass without losing it.

#### The rebuild gotcha

stack-nudge's apps are **ad-hoc signed**, so every rebuild produces a new cdhash. macOS's TCC database binds permissions to that cdhash, which means a fresh build silently invalidates prior grants — even though System Settings still *shows* the entry as "on". `AXIsProcessTrusted()` returns false because the running binary's hash no longer matches.

If approval has stopped working after a rebuild, hit **Reset & prompt** in the permissions checker. It runs `tccutil reset`, then triggers a fresh dialog bound to the current cdhash.

### Voice notifications

stack-nudge uses [stackvox](https://github.com/StackOneHQ/stackvox), an offline Kokoro-82M TTS engine that speaks notifications aloud with ~13 ms latency. `./install.sh` pip-installs it from PyPI into an isolated venv at `~/.stack-nudge/venv` — no separate setup needed.

**Enable in your config** (`~/.stack-nudge/config`):

```bash
STACKNUDGE_VOICE=true
```

The voice daemon starts automatically on first notification and is registered as a login item so it stays running across reboots.

Voice fires whenever `STACKNUDGE_VOICE=true`, alongside the banner and panel surfaces. The frontmost-suppression check still applies — when the source window is already focused, sound, banner, panel post, *and* voice are all suppressed (you don't need a nudge for the thing you're looking at).

When voice is enabled, the chime is suppressed automatically — voice replaces sound rather than playing alongside it.

#### Phrasing

Voice messages are picked at random from per-event phrase pools and labelled with the project name (cwd basename, with hyphens/underscores split and a few acronyms expanded — `CLI` → `C L I`, `MCP` → `M C P`, etc.). For a project called `unified-cloud-api` you'll hear things like:

- **Stop:** *"unified cloud api is ready for you"* / *"task complete in unified cloud api"* / *"output ready in unified cloud api"*
- **Permission:** *"unified cloud api requires a decision"* / *"unified cloud api has a question for you"* / *"unified cloud api is awaiting approval"*

Phrase pools live in `~/.stack-nudge/phrases/` — `en.sh`, `fr.sh`, `hi.sh`, `it.sh`, `pt.sh`. The right pool is picked from the configured voice's prefix (`af_*`/`am_*`/`bf_*`/`bm_*` → en, `ff_*` → fr, `hf_*`/`hm_*` → hi, `if_*`/`im_*` → it, `pf_*`/`pm_*` → pt) so a French voice speaks French phrasing.

Optional tuning (also in `~/.stack-nudge/config`):

```bash
STACKNUDGE_VOICE_NAME=af_heart   # voice ID (run `~/.stack-nudge/venv/bin/stackvox voices` for the full list)
STACKNUDGE_VOICE_SPEED=1.1       # playback speed (1.0 = normal)
```

## Sounds

| Event | macOS | Linux | Windows |
|-------|-------|-------|---------|
| Agent done | `Glass.aiff` | freedesktop bell | 800 Hz beep |
| Waiting for approval | `Ping.aiff` | freedesktop bell | 1200 Hz beep |

Any file from `/System/Library/Sounds/` works on macOS: Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink. Override per-event in `~/.stack-nudge/config`:

```bash
STACKNUDGE_SOUND_STOP=Glass
STACKNUDGE_SOUND_PERMISSION=Ping
```

The Settings tab exposes the same picks with audio preview on each change.

## Uninstall

```bash
./uninstall.sh
```

Removes the hooks from each agent's config and deletes `~/.stack-nudge/`.

## Manual setup

Every supported agent just needs a hook that runs `notify.sh <agent-name> <event>`. Example for Codex (or any other hooks-capable agent):

```json
{
  "hooks": {
    "stop": [
      {
        "type": "command",
        "command": "$HOME/.stack-nudge/notify.sh codex stop"
      }
    ]
  }
}
```

## Development

```bash
make build      # builds both .app bundles into build/
make install    # full install (build + copy + register hooks + launchd)
make reload     # rebuild + replace installed panel + refresh notify.sh + bounce daemon
make dev        # watch sources; auto-reload on .swift / Info.plist / notify.sh / phrase changes
make uninstall  # remove apps, hooks, launchd agents, ~/.stack-nudge/
```

`make dev` is the inner-loop tool — leave it running in another terminal, save a Swift file or `notify.sh`, and the daemon bounces with the new build in ~2 seconds.

Source layout:

- `notifier/` — the transient banner-renderer that fires per nudge and exits
- `panel/` — the persistent floating-panel daemon (hotkey, NSPanel, socket listener, menu bar, sessions list, settings, permissions window)
- `shared/` — code shared by both binaries (currently `AppActivator.swift`)
- `phrases/` — per-language voice phrase pools sourced by `notify.sh` at hook time
- `notify.sh` — the shell entry-point CC/Cursor/Gemini hooks invoke; routes events to banner / panel / voice surfaces

Swift compiled with `swiftc` directly. No Xcode, no SPM, no dependencies.

## Credits

Click-routing architecture (process exits after delivery, macOS re-launches on click) is adapted from [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) by Eloy Durán and Julien Blanchard.

## License

MIT
