# Setup, updates and uninstall

Permissions, auto-update, uninstalling, wiring an agent by hand, and working on StackNudge itself.

## Permissions (macOS)

The panel needs up to four privacy grants to fully work:

| Permission | Why |
|------------|-----|
| **Accessibility** | Required for `AXIsProcessTrusted()` to return true — without it, the Enter-to-approve keystroke is silently skipped |
| **Automation → System Events** | Required for the AppleScript that focuses the right app and window when you act on a nudge |
| **Automation → iTerm2** | Reading iTerm2 tab titles and focusing the right tab. Only asked for while iTerm2 is running |
| **Notifications** | The macOS banners |

The Permissions page shows each grant's live status. It's a Settings sub-page: open it from **Settings › Actions › Check permissions**, the "Permissions needed" row at the top of Settings, **Check permissions…** in the menu bar, or **Grant permissions** on the setup screen.

| Key | Action |
|-----|--------|
| `↑ ↓` | Move selection |
| `⏎` | Prompt for the selected grant. For Accessibility and Automation that's **Reset & prompt**, which clears the existing TCC entry and then triggers macOS's grant dialog. Notifications only asks, and once you've answered, the switch is in System Settings. |
| `⌘⏎` | Open System Settings at the right pane |
| `⌘R` | Check every grant again |
| `←` | Back to Settings, or to setup if you came from there |

The panel (or the expanded widget) stays up on this page even when a grant prompt or System Settings takes focus, so you can work through every grant in one pass; drag it aside if it covers System Settings. The page checks again whenever the panel becomes key, so a grant made in System Settings shows up when you click back.

### The rebuild gotcha

A source build is **ad-hoc signed**, so every rebuild produces a new cdhash. macOS's TCC database binds permissions to that cdhash, which means a fresh build silently invalidates prior grants — even though System Settings still *shows* the entry as "on". `AXIsProcessTrusted()` returns false because the running binary's hash no longer matches.

If approval has stopped working after a rebuild, hit **Reset & prompt** on the Permissions page. It runs `tccutil reset`, then triggers a fresh dialog bound to the current cdhash.

## Auto-update

stack-nudge polls GitHub Releases on launch and every 2 hours. When a newer release exists, the Settings tab gets a small accent dot and an "Update available · vX.Y.Z" row above the categories. Click it (or press Enter while it's selected) for a confirmation view with the release notes, then "Update Now" runs the install:

1. Downloads the arch-appropriate `.tar.gz` artifact for your Mac (~150–200 MB)
2. Verifies the SHA256 against the sidecar checksum file
3. Extracts to a temp directory, strips the `com.apple.quarantine` xattr
4. Atomic-swaps `~/Applications/StackNudge.app` with the new bundle (keeps the old as `.app.old` for safety)
5. Runs `launchctl kickstart -k` — the current process dies, launchd brings up the new bundle
6. The new bundle's first launch shows a welcome-style "Updated to vX.Y.Z" screen with the release notes

Because the swap replaces only the bundle, the hook script the agents invoke (`~/.stack-nudge/notify.sh`) would otherwise stay at whatever version first installed it. Each launch compares its `stack-nudge-version` stamp against the bundled script's and rewrites it when they differ, so payload fields added by a release reach the panel without a reinstall.

No source clone, no swiftc rebuild on the user's machine — the new bundle is the already-signed-and-notarized artifact from CI. Updates are fast and don't disturb the user's Xcode CLT or Python install (or lack thereof).

## Uninstall

### macOS — in-app

Open the panel (`⌘⌥N`), go to **Settings → Actions → Uninstall StackNudge…**, confirm. The app tears down:

- Hook entries in `~/.claude/settings.json`, `~/.cursor/hooks.json`, `~/.codex/hooks.json`, `~/.gemini/settings.json` and `~/.gemini/antigravity-cli/settings.json`
- The launchd agents (`com.stackonehq.stack-nudge`, `…-daemon`)
- `~/.stack-nudge/` (config, `notify.sh`, phrases, history)
- Moves `StackNudge.app` to Trash and quits

Two things stay behind: the cached Kokoro voice model in `~/.cache/huggingface/`, and the GitHub and Slack tokens in your Keychain (items `stack-nudge-github` and `stack-nudge-slack`), which you can delete in Keychain Access.

### Linux / Windows / fallback

```bash
git pull        # if you cloned a while back — older uninstall.sh lacks hook cleanup
./uninstall.sh
```

Much the same cleanup as the in-app path, useful when the .app isn't reachable or the in-app uninstall failed mid-flight. It also removes the pi extension (`~/.pi/agent/extensions/stack-nudge.ts`) and deletes the app outright rather than moving it to the Trash.

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
make build               # builds StackNudge.app into build/
make install             # full install (build + copy + register hooks + launchd)
make reload              # rebuild + replace installed app + refresh notify.sh + bounce the daemon
make dev                 # watch sources; auto-reload on .swift / Info.plist / notify.sh / phrase changes
make test                # swift test (needs full Xcode for XCTest)
make test-without-xcode  # compile and run the tests with the Command Line Tools only
make test-notify         # drive notify.sh against a fake panel socket (macOS, no Xcode)
make test-extensions     # validate and test the bundled extensions
make uninstall           # remove app, hooks, launchd agents, ~/.stack-nudge/
```

`make dev` is the inner-loop tool — leave it running in another terminal, save a Swift file or `notify.sh`, and the daemon bounces with the new build in ~2 seconds. `make reload` prints "reloaded" even if the restart failed, so check the process start time if a change doesn't show up.

`scripts/render-screenshots.sh` renders the README screenshots (and the Extensions pages) from fixture data, without touching your setup.

Source layout:

- `panel/` — the single persistent `StackNudge.app` binary: hotkey, floating NSPanel, socket listener for incoming events, macOS banner posting via `UNUserNotificationCenter`, sessions list, settings and its Permissions page, auto-updater, quota probe, extension host
- `notify.sh` — the shell entry point every agent hook invokes; on macOS posts events to the running app via Unix-domain socket, on Linux/Windows handles audio + libnotify directly
- `hook-manifest.json` — which agent events get wired to `notify.sh`
- `hooks/` — the Claude Code plugin hooks and the pi extension
- `phrases/` — per-language voice phrase pools sourced by `notify.sh` at hook time
- `extensions/` — the extensions in the catalogue; see [extensions.md](extensions.md)
- `shared/` — code shared with the Linux/Windows surfaces
- `scripts/`, `Tests/` — release and packaging scripts, and the test suite

The app is compiled with `swiftc` directly by `build.sh`, with no dependencies. `Package.swift` exists only so `make test` can run the tests.
