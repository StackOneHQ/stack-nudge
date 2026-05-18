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

**Platforms:** macOS — full app with panel, click-to-focus banners, auto-update, quota tracking, voice. Linux (PulseAudio / ALSA / libnotify) and Windows (Git Bash / WSL) get audio + basic notifications via `notify.sh` only.

## Install

**Prerequisites:** Python ≥ 3.10 (the bundled voice engine [stackvox](https://github.com/StackOneHQ/stackvox) requires it). macOS ships 3.9 by default — install a newer one with `brew install python@3.13`, or set `STACKNUDGE_PYTHON=/path/to/python3` to point at one explicitly.

```bash
git clone https://github.com/StackOneHQ/stack-nudge.git
cd stack-nudge
./install.sh
```

The installer auto-wires hooks for **Claude Code** (`~/.claude/settings.json`) and **Cursor** (`~/.cursor/hooks.json`). Gemini CLI and Codex are supported through the same `notify.sh` entry-point, but their hooks must be wired manually — see [Manual setup](#manual-setup) below.

On macOS it also installs the native `stack-nudge.app`, which provides the floating panel, click-to-focus banners, auto-update, and quota tracking. The first launch will show a welcome screen with a "Grant permissions" button — taking that step up-front unlocks click-to-focus and the keystroke-based "Allow" approvals.

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

If you'd rather not click banners with the mouse, stack-nudge runs a small floating panel that you summon with a hotkey. It has four tabs — **Events**, **Sessions**, **Usage**, and **Settings** — and is fully keyboard-driven.

The panel is installed and registered as a launchd agent by `./install.sh` — no opt-in needed. To run quietly without macOS banners (panel-only):

```bash
STACKNUDGE_BANNER=false   # optional — suppress macOS banners when using the panel
```

Default hotkey is `cmd+opt+n`. Hit it from anywhere to summon the panel; hit it again while focused to hide. Switch tabs with `Cmd+1` (Events), `Cmd+2` (Sessions), `Cmd+3` (Usage), `Cmd+4` (Settings) — or click them. Banner and panel can run together, alone, or both off — the sound and voice still fire as passive signals.

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

#### Usage tab

Reachable from the tab strip or `Cmd+3`. Renders your Claude Code subscription quota — the same numbers `claude /usage` shows in the terminal — but always available without typing the command:

- **Current session** (5-hour rolling window)
- **Current week (all models)**
- **Current week (Opus only)** *(when your plan has the tier)*
- **Current week (Sonnet only)** *(when your plan has the tier)*

Bars are color-coded: green below 50%, yellow 50–80%, red 80%+. Reset times shown per tier.

Data is fetched from the same endpoint Claude Code's own statusline uses (`/api/oauth/usage`), reading your OAuth token from the macOS Keychain. **The first time stack-nudge polls you'll see a keychain dialog — click "Always Allow"** to grant access (one-time, per release).

Polls every 60 seconds while the panel is visible, or every 5 minutes (`STACKNUDGE_USAGE_POLL_MIN`) in the background.

#### Threshold-crossing notifications

When any tier reaches your configured threshold, stack-nudge fires a banner — *"Weekly quota at 85% — resets May 17"* — once per period per tier, so you get a heads-up before hitting the cap. Configure in Settings → Usage:

- **Quota alerts** — master switch (default on)
- **Alert threshold** — 50% / 70% / 80% / 90% / 95% (default 80%)

#### Settings tab

Reachable from the tab strip or `Cmd+4`. Keyboard-driven rows for hotkey, banner/voice toggles, sound picks (with preview-on-cycle), voice picker (with preview-on-cycle using a random conversational phrase), speed, quota alert config, and shortcuts to the permissions checker, config file, phrase editor, and quit.

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

### Auto-update

stack-nudge polls GitHub Releases on launch and every 6 hours. When a newer release exists, the Settings tab gets a small accent dot and an "Update available · vX.Y.Z" row at the top of the list. Click it (or press Enter while it's selected) for a confirmation view with the release notes, then "Update Now" runs the install:

1. Clones the repo to `/tmp`
2. Runs `install.sh` against the cloned source (rebuild + replace `~/Applications/stack-nudge.app` + reload launchd)
3. After completion, the panel auto-quits; launchd brings up the new bundle
4. The new bundle's first launch shows a welcome-style "Updated to vX.Y.Z" screen with the release notes

While the StackOne stack-nudge repo is private the auto-updater falls back to your local `gh` CLI auth (`gh api`) to read the release metadata; the in-app git clone uses your existing git credentials (keychain or SSH). Org members with `gh` configured see no friction.

### Phrase editor

The phrase pools that power [Voice notifications](#voice-notifications) can be customised in-app. Settings → "Edit phrases…" opens a keyboard-driven editor where you can:

- Toggle individual built-in phrases on or off (`Space`)
- Add your own custom phrases (typed inline, `Enter` to commit)
- Remove custom phrases (`⌫`)

Per-pool customisations are stored in `~/.stack-nudge/phrases.user.json` and merged with the built-in pools at notification time. Disable a built-in phrase you find too cheery, add ones in your own voice — the same random-selection logic still applies.

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
git pull        # if you cloned a while back — older uninstall.sh lacks hook cleanup
./uninstall.sh
```

Cleans up:

- Hook entries in `~/.claude/settings.json`, `~/.cursor/hooks.json`, and `~/.gemini/settings.json`
- The launchd agents (`com.stackonehq.stack-nudge`, `…-daemon`)
- `~/Applications/stack-nudge.app`
- `~/.stack-nudge/` (including the Python venv and `notify.sh`)

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
make build      # builds stack-nudge.app into build/
make install    # full install (build + copy + register hooks + launchd)
make reload     # rebuild + replace installed app + refresh notify.sh + bounce the daemon
make dev        # watch sources; auto-reload on .swift / Info.plist / notify.sh / phrase changes
make uninstall  # remove app, hooks, launchd agents, ~/.stack-nudge/
```

`make dev` is the inner-loop tool — leave it running in another terminal, save a Swift file or `notify.sh`, and the daemon bounces with the new build in ~2 seconds.

Source layout:

- `panel/` — the single persistent `stack-nudge.app` binary: hotkey, floating NSPanel, socket listener for incoming events, macOS banner posting via `UNUserNotificationCenter`, sessions list, settings, permissions window, auto-updater, quota probe
- `shared/` — code shared with the standalone Linux/Windows surfaces (currently `AppActivator.swift`)
- `phrases/` — per-language voice phrase pools sourced by `notify.sh` at hook time
- `notify.sh` — the shell entry-point CC/Cursor/Gemini hooks invoke; on macOS posts events to the running app via Unix-domain socket, on Linux/Windows handles audio + libnotify directly

Swift compiled with `swiftc` directly. No Xcode, no SPM, no dependencies.

## Credits

Click-routing architecture (process exits after delivery, macOS re-launches on click) is adapted from [`terminal-notifier`](https://github.com/julienXX/terminal-notifier) by Eloy Durán and Julien Blanchard.

## License

MIT
