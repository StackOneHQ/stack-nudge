<div align="center">
  <img src="assets/logo_full.png" alt="StackNudge" width="200" />
  <h1>StackNudge</h1>
  <p><strong>Notifications for AI coding agents.</strong></p>
  <p>Get a banner + sound when your agent finishes a task or pauses for your approval — step away without missing a beat.</p>
  <p>
    <a href="https://github.com/StackOneHQ/stack-nudge/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/StackOneHQ/stack-nudge?display_name=tag&sort=semver"></a>
    <a href="https://github.com/StackOneHQ/stack-nudge/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/StackOneHQ/stack-nudge/actions/workflows/ci.yml/badge.svg"></a>
    <a href="LICENSE"><img alt="MIT licensed" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
    <img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-black?logo=apple">
  </p>
  <p>
    Maintained by <a href="https://www.stackone.com/">StackOne</a> ·
    <a href="https://github.com/StackOneHQ">@StackOneHQ</a>
  </p>
</div>

---
  <p align="center">
    <img src="https://github.com/user-attachments/assets/c73cb65b-ff96-48bf-9371-3f1d3241c6cb" width="48%" alt="StackNudge banner" />
    &nbsp;
    <img src="https://github.com/user-attachments/assets/e4fecb5d-376e-44eb-a68a-220cb0b30507" width="48%" alt="StackNudge panel" />
  </p>

## Supports

| Agent | Status |
|-------|--------|
| Claude Code | ✅ |
| Cursor | ✅ |
| Codex | ✅ |
| Gemini CLI | ✅ † |
| Antigravity CLI | ✅ † |
| Any hooks-capable agent | ✅ — point it at `notify.sh` |

† Gemini CLI and Antigravity route tool-permission prompts through an observability-only hook — the banner shows the prompt, but the Allow / Deny click still has to happen in the agent's own terminal. Claude Code and Codex permission events can be approved from the panel directly.

**Platforms:** macOS — full app with panel, click-to-focus banners, auto-update, quota tracking, voice. Linux (PulseAudio / ALSA / libnotify) and Windows (Git Bash / WSL) get audio + basic notifications via `notify.sh` only.

## Install

### macOS

Download the latest release from [GitHub Releases](https://github.com/StackOneHQ/stack-nudge/releases/latest) — pick the `.tar.gz` matching your Mac's architecture (`arm64` for Apple Silicon, `x86_64` for Intel), expand, and drag `StackNudge.app` into `~/Applications/`.

CLI shortcut (requires [`gh`](https://cli.github.com/)):

```bash
ARCH=$(uname -m)
gh release download --repo StackOneHQ/stack-nudge --pattern "stack-nudge-*-macos-${ARCH}.tar.gz*"
shasum -a 256 -c stack-nudge-*-macos-${ARCH}.tar.gz.sha256
tar xzf stack-nudge-*-macos-${ARCH}.tar.gz
mv StackNudge.app ~/Applications/
open ~/Applications/StackNudge.app
```

On first launch, stack-nudge runs a one-screen wizard:

1. Detects which agents you have configured (`~/.claude`, `~/.cursor`, `~/.gemini`).
2. Wires their hook configs to `notify.sh`.
3. Registers itself + the voice engine as launchd agents so they start at login.

Everything is self-contained inside the `.app` — no Xcode CLT, no Python, no shell-script bootstrap required. The bundle ships with a portable Python + stackvox (the offline voice engine) already installed. The Kokoro voice model downloads lazily the first time you enable voice notifications.

Subsequent releases install automatically via the in-app auto-updater (Settings → "Update available · vX.Y.Z" when a new release exists).

### Linux / Windows

These platforms get the audio + libnotify path only — no panel, no click-to-focus, no auto-update. The shell installer is what wires `notify.sh` into agent hooks:

```bash
git clone https://github.com/StackOneHQ/stack-nudge.git
cd stack-nudge
./install.sh
```

**Prerequisites:** Python ≥ 3.10 (the bundled voice engine [stackvox](https://github.com/StackOneHQ/stackvox) requires it).

The installer auto-wires hooks for every detected agent — **Claude Code** (`~/.claude`), **Cursor** (`~/.cursor`), **Codex** (`~/.codex`), **Gemini CLI** (`~/.gemini`), and **Antigravity CLI** (`~/.gemini/antigravity-cli`). Any other hooks-capable agent can be wired by hand — see [Manual setup](#manual-setup) below.

### From source (macOS dev)

If you're working on stack-nudge itself and want to build from source rather than download a release:

```bash
git clone https://github.com/StackOneHQ/stack-nudge.git
cd stack-nudge
./install.sh
```

Same script as Linux/Windows; on macOS it additionally builds and installs the panel `.app`. Requires Xcode CLT. See [Development](#development) for the inner-loop tools.

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

If you'd rather not click banners with the mouse, stack-nudge runs a small floating panel that you summon with a hotkey. It has five tabs (**Events**, **Sessions**, **Usage**, **Outcomes**, and **Settings**) and is fully keyboard-driven.

The panel is installed and registered as a launchd agent by `./install.sh` — no opt-in needed. To run quietly without macOS banners, toggle **Settings → Banner notifications** off (panel-only mode).

Default hotkey is `cmd+opt+n`. Hit it from anywhere to summon the panel; hit it again while focused to hide. Switch tabs with `Cmd+1` (Events), `Cmd+2` (Sessions), `Cmd+3` (Usage), `Cmd+4` (Outcomes), `Cmd+5` (Settings), or click them. Banner and panel can run together, alone, or both off; the sound and voice still fire as passive signals.

#### Events tab

Recent nudges in chronological order. Each shows agent, message, project name, time.

| Key | Action |
|-----|--------|
| `↑ ↓` | Move selection |
| `⏎` | Approve permission / focus source editor |
| `O` | Focus source editor without approving |
| `M` | Mute all notifications for the configured duration (press again to resume) |
| `⌫` | Dismiss the selected nudge locally |
| `Esc` | Hide the panel |

When you press `⏎` on a permission event in a VS Code / Cursor terminal pane, stack-nudge walks the editor's accessibility tree to focus the right pane (matched by the agent name in the tab title) before sending Enter — so the approval keystroke lands in the agent's terminal, not whatever was last focused. Falls back gracefully if the pane can't be found.

**Mute for a while.** Press `M` (or use the bell button in the panel header, or the menu-bar **Mute notifications** submenu) to silence *everything* — banner, sound, voice, and the focus jump — for a set duration, **including permission prompts**. Events keep flowing into the panel while muted; only the interruptions are suppressed. A live countdown shows on the header bell and the menu-bar icon (the compact widget just shows a muted-bell glyph), and the mute lifts itself when the timer runs out (or immediately if you press `M` / **Resume** again). The default duration is configurable (`STACKNUDGE_MUTE_DURATION_MIN`, one of 15 / 30 / 60 / 120, default 30) and can be cycled in Settings. Mute is in-memory only — it resets on relaunch.

#### Sessions tab

Live list of running agent processes (`claude`, `gemini`, `codex` — including node-hosted variants like `gemini-cli`). Polls every 3 seconds while visible and every 15 seconds in the background for the compact widget. Sessions that exit linger for 30s with `ended Ns ago`.

For Claude Code sessions specifically, stack-nudge reads `~/.claude/sessions/<pid>.json` (Claude Code's per-process sidecar) to surface live data without waiting for a hook event:

- **Live status dot** — yellow for `busy` (turn in flight), green for `idle` (waiting for input).
- **Session name** from the sidecar when set to anything other than the default `main-agent` (falls back to the project name otherwise).
- **Context-window usage** — `293K tokens · opus-4-7` beneath the project path, updated on each Claude turn.

Rows are ordered busy-first, then by most-recent activity. Status label reads `busy · 2 min ago` / `idle · 1 hr ago`.

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

Numbers come straight from the `claude` CLI — stack-nudge shells out to `claude --print /usage` and parses the result. Because the CLI reads its *own* keychain grant, **stack-nudge never touches your keychain or calls the Anthropic API, so there's no password prompt**. If `claude` isn't on your `PATH` or you're signed out, the tab shows *"Claude usage unavailable — run `claude /usage` to check your session"* rather than falling back to any other source. (Codex and Antigravity usage are read from their own local files, unaffected.)

Polls every 60 seconds while the panel is visible, or every 5 minutes by default in the background (configurable via Settings → Usage → "Poll frequency"). On the Usage tab: `r` triggers a manual sync, `p` pauses/resumes the poller.

#### Threshold-crossing notifications

When any quota tier reaches your configured threshold, stack-nudge fires a banner — *"Weekly quota at 85% — resets May 17"* — once per period per tier, so you get a heads-up before hitting the cap. Configure in Settings → Usage:

- **Quota tracking** — master switch for the whole feature (default on; off disables polling entirely)
- **Quota alerts** — banner toggle (default on)
- **Alert threshold** — 50% / 70% / 80% / 90% / 95% (default 80%)
- **Poll frequency** — 1 / 2 / 5 / 10 / 15 / 30 min (default 5)

#### Per-session context alerts

Independent of quota: stack-nudge can also fire a banner when an individual Claude Code session's context window fills past a threshold you pick. The banner names the session — *"Context filling up — classifier-evolution-2 — at 175K tokens (opus-4-7). Consider /compact."* — so you know exactly which one to act on.

- **Context alert at** — `Off` / 100K / 150K / 175K / 200K / 300K / 500K / 750K (default Off)
- Absolute tokens, not a percent — Claude 4.x context windows vary (Opus/Sonnet 1M, Haiku 200K, opt-in betas), and there's no reliable way to infer the limit from the model ID alone.
- One banner per session per threshold; the dedup re-arms whenever the session's token count drops by ≥20K (the characteristic shape of a `/compact` or `/clear`), so refilling after a compact alerts you again.

#### Settings tab

Reachable from the tab strip or `Cmd+5`. Keyboard-driven rows for hotkey, behavior toggles (banner, mute when focused, a Mute/Resume action row with mute duration, pin panel, launch at login), widget (corner, mascot picker, opacity), sound picks (with preview-on-cycle), voice notifications + picker + speed (with preview-on-cycle using a random conversational phrase), usage config (quota tracking + alerts + threshold + poll frequency + context alert threshold + show-remaining), and action rows (edit phrases, check permissions, open config file, view release notes, check for updates, uninstall, quit).

| Key | Action |
|-----|--------|
| `↑ ↓` / `Tab` | Move selection |
| `← →` | Cycle the selected row's value (toggles flip, sounds/voices step) |
| `⏎` | Activate (toggles flip, action rows fire, hotkey row records a new combo) |
| `Esc` | Back to events |

The hotkey row records live: press `⏎` on it, press the new combo, and stack-nudge re-registers the global hotkey. If the combo is already grabbed by another app, the previous one stays and an inline error explains why.

All Settings choices persist to `~/.stack-nudge/config` (a `KEY=value` text file). You don't need to edit it directly — Settings is the source of truth — but it's there for backup/sync or scripted setup.

### Outcomes (usage → shipped)

The **Outcomes** tab (`⌘4`) is two views of one dataset. It opens on the **Overview** (the aggregate); press `→` to carousel into the per-ticket **Tickets** list, `←` to step back.

#### Overview

The spend-to-outcome picture over a trailing window, so you see not just *what* your agents did but *what share of it shipped*.

- **Shipped share**: the headline. Of the effort spent in the window, how much sits on work that merged or pushed, versus in-flight, versus **abandoned** (committed / needs-review work that's gone quiet for over 14 days).
- **Spend bar**: one bar partitioning tokens across those three buckets, coloured shipped (green) / in-flight (blue) / abandoned (orange).
- **Top tickets by spend**: the heaviest tickets (or unticketed repos) in the window, each with its dominant outcome. Click a row to open the ticket (when `STACKNUDGE_TICKET_URL` is set) or its PR.
- **Agents**: the token mix per agent alongside each agent's **shipped share**, so you can see whose work actually merges. Plus the model mix.

The Overview is a scroll page: `↑ ↓` scroll, `⌘↑ ⌘↓` jump to top/bottom, `W` cycles the trailing window (24h / 7d / 30d / 90d; 90d is the ledger's own retention ceiling). Because "abandoned" needs 14 days of quiet, it only appears on the 30d and 90d windows. It's token-only today; per-model dollar cost and reclaimed-time are planned follow-ups.

#### Tickets

Every captured agent session rolled up **by ticket**, derived from your branch naming (`eng-123/…` → `ENG-123`), falling back to the branch when there's no ticket. Shows the tokens spent, files changed, and the live git outcome: *needs-review → committed → pushed → merged*. `↑ ↓` select rows, `⏎` opens the ticket or PR, `⌫` dismisses one, `←` steps back to the Overview.

The two panes agree by construction: both read the same per-branch outcome and PR state, so a squash-merged branch reads as shipped in each.

Opt-in GitHub linking adds real **PR + CI status** (so even squash-merged work reads as *merged*). Turn it on in Settings → Tickets → **GitHub PR links**, then sign in via the in-panel device flow (no `gh` needed). Config keys (all optional; the toggles in Settings write the same file):

| Key | What it does |
|-----|--------------|
| `STACKNUDGE_GITHUB` | `true` to enable GitHub PR/CI linking (off by default) |
| `STACKNUDGE_GITHUB_CLIENT_ID` | Override the embedded OAuth app Client ID (rarely needed) |
| `STACKNUDGE_TICKET_URL` | Deep-link template for ticket rows, e.g. `https://linear.app/acme/issue/{key}`; `{key}` is replaced with the ticket |
| `STACKNUDGE_HIDE_SHIPPED` | `true` to drop groups once their PR reads merged, keeping the list on in-flight work |

**Nothing showing up?** A session is recorded when an agent's turn ends *inside a git repo*, and only if the hook payload carries a session id. The Tickets empty state names which of those failed; `~/.stack-nudge/app.log` has a line per dropped turn. The usual cause is an installed hook script older than the app, since updates swap the `.app` alone: the app repairs that on launch, and Settings warns in the footer if the rewrite couldn't be applied. To fix it by hand:

```bash
grep -c stack-nudge-version ~/.stack-nudge/notify.sh   # 0 means the script predates v1.26
./install.sh                                            # or reinstall from the app
```

### Menu bar (macOS)

When the panel daemon is running, a bell icon appears in your menu bar. The same items you can reach from the in-panel Settings tab are mirrored here for one-click access without summoning the panel:

| Item | What it does |
|------|--------------|
| `Hotkey · …` | Shows your current hotkey (info only) |
| `Show banners` | Toggles macOS banner notifications. Enabling fires a confirmation banner. |
| `Voice notifications` | Toggles spoken notifications. Enabling speaks *"Voice notifications enabled"*. |
| `Mute notifications ▸` | Submenu (For 15m / 30m / 1h / 2h) to silence all nudges for a set time. While muted the item becomes `Resume notifications` and the menu-bar icon shows a `bell.slash` + countdown. |
| `Show panel` | Brings the floating panel up (handy when no events are queued) |
| `Check permissions…` | Opens the permissions checker (see below) |
| `Open config file…` | Opens `~/.stack-nudge/config` in your default editor |
| `Quit stack-nudge panel` | Exits the daemon |

Menu changes take effect immediately for the next nudge — no daemon restart needed.

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

1. Downloads the arch-appropriate `.tar.gz` artifact for your Mac (~150–200 MB)
2. Verifies the SHA256 against the sidecar checksum file
3. Extracts to a temp directory, strips the `com.apple.quarantine` xattr
4. Atomic-swaps `~/Applications/stack-nudge.app` with the new bundle (keeps the old as `.app.old` for safety)
5. Runs `launchctl kickstart -k` — the current process dies, launchd brings up the new bundle
6. The new bundle's first launch shows a welcome-style "Updated to vX.Y.Z" screen with the release notes

Because the swap replaces only the bundle, the hook script the agents invoke (`~/.stack-nudge/notify.sh`) would otherwise stay at whatever version first installed it. Each launch compares its `stack-nudge-version` stamp against the bundled script's and rewrites it when they differ, so payload fields added by a release reach the panel without a reinstall.

No source clone, no swiftc rebuild on the user's machine — the new bundle is the already-signed-and-notarized artifact from CI. Updates are fast and don't disturb the user's Xcode CLT or Python install (or lack thereof).

While the StackOne stack-nudge repo is private the auto-updater falls back to your local `gh` CLI auth (`gh api`) to read the release metadata. Org members with `gh` configured see no friction; the actual artifact download uses the release's signed asset URL.

### Phrase editor

The phrase pools that power [Voice notifications](#voice-notifications) can be customised in-app. Settings → "Edit phrases…" opens a keyboard-driven editor where you can:

- Toggle individual built-in phrases on or off (`Space`)
- Add your own custom phrases (typed inline, `Enter` to commit)
- Remove custom phrases (`⌫`)

Per-pool customisations are stored in `~/.stack-nudge/phrases.user.json` and merged with the built-in pools at notification time. Disable a built-in phrase you find too cheery, add ones in your own voice — the same random-selection logic still applies.

### Voice notifications

stack-nudge uses [stackvox](https://github.com/StackOneHQ/stackvox), an offline Kokoro-82M TTS engine that speaks notifications aloud with ~13 ms latency. `./install.sh` pip-installs it from PyPI into an isolated venv at `~/.stack-nudge/venv` — no separate setup needed.

**Enable** via Settings → Voice → "Voice notifications".

The voice daemon starts automatically on first notification and is registered as a login item so it stays running across reboots.

Voice fires alongside the banner and panel surfaces. The frontmost-suppression check still applies — when the source window is already focused, sound, banner, panel post, *and* voice are all suppressed (you don't need a nudge for the thing you're looking at).

When voice is enabled, the chime is suppressed automatically — voice replaces sound rather than playing alongside it.

#### Phrasing

Voice messages are picked at random from per-event phrase pools and labelled with the project name (cwd basename, with hyphens/underscores split and a few acronyms expanded — `CLI` → `C L I`, `MCP` → `M C P`, etc.). For a project called `unified-cloud-api` you'll hear things like:

- **Stop:** *"unified cloud api is ready for you"* / *"task complete in unified cloud api"* / *"output ready in unified cloud api"*
- **Permission:** *"unified cloud api requires a decision"* / *"unified cloud api has a question for you"* / *"unified cloud api is awaiting approval"*

Phrase pools live in `~/.stack-nudge/phrases/` — `en.sh`, `fr.sh`, `hi.sh`, `it.sh`, `pt.sh`. The right pool is picked from the configured voice's prefix (`af_*`/`am_*`/`bf_*`/`bm_*` → en, `ff_*` → fr, `hf_*`/`hm_*` → hi, `if_*`/`im_*` → it, `pf_*`/`pm_*` → pt) so a French voice speaks French phrasing.

Tune via Settings → Voice → "Voice" (cycle voices with preview) and "Speed" (1.0 = normal).

## Sounds

| Event | macOS | Linux | Windows |
|-------|-------|-------|---------|
| Agent done | `Glass.aiff` | freedesktop bell | 800 Hz beep |
| Waiting for approval | `Ping.aiff` | freedesktop bell | 1200 Hz beep |

Any file from `/System/Library/Sounds/` works on macOS: Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink. Override per-event via Settings → Sounds → "Agent done" / "Permission" (cycle plays a preview on each step).

## Uninstall

### macOS — in-app

Open the panel (`⌘⌥N`), go to **Settings → Uninstall stack-nudge…**, confirm. The app tears down:

- Hook entries in `~/.claude/settings.json`, `~/.cursor/hooks.json`, and `~/.gemini/settings.json`
- The launchd agents (`com.stackonehq.stack-nudge`, `…-daemon`)
- `~/.stack-nudge/` (config, `notify.sh`, phrases)
- Moves `stack-nudge.app` to Trash and quits

Settings (config, the cached Kokoro voice model in `~/.cache/huggingface/`) are not touched. stack-nudge never creates its own keychain entries, so there's nothing of ours to clean up there.

### Linux / Windows / fallback

```bash
git pull        # if you cloned a while back — older uninstall.sh lacks hook cleanup
./uninstall.sh
```

Same set of cleanups as the in-app path, useful when the .app isn't reachable or the in-app uninstall failed mid-flight.

## Manual setup

Claude Code, Cursor, Codex, Gemini CLI, and Antigravity CLI are auto-wired by the first-launch wizard. For other hooks-capable agents (or to integrate from a custom script), all you need is to invoke `notify.sh <agent-label> <event>` from wherever your agent emits lifecycle events. `<event>` should be `stop` (agent finished a turn) or `permission` (waiting for approval); `<agent-label>` can be anything — it just controls the banner title.

Example block in any agent's hooks config:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          { "type": "command", "command": "$HOME/.stack-nudge/notify.sh my-agent stop", "timeout": 30 }
        ]
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

## Terms of use

By using stack-nudge or its source code, you agree to the following:

- Use is governed by the [MIT License](LICENSE). The software is provided "as is", without warranty of any kind.
- Participation in the project (issues, pull requests, discussions) is subject to the [Code of Conduct](CODE_OF_CONDUCT.md).
- Suspected security vulnerabilities should be reported privately per [SECURITY.md](SECURITY.md), not via public issues.
- The project is maintained by [StackOne](https://www.stackone.com/); contributions remain under the licence the contributor submits them under (MIT unless otherwise noted).

## License

MIT — see [LICENSE](LICENSE) for the full text. Copyright © 2026 StackOne Technologies Ltd. and contributors.
