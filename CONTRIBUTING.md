# Contributing to stack-nudge

Thanks for your interest in making stack-nudge better. This doc covers local setup, how to run the app during development, and conventions for commits and PRs.

## Development setup

```bash
git clone https://github.com/StackOneHQ/stack-nudge.git
cd stack-nudge
./install.sh           # builds + installs the .apps, registers hooks, sets up the voice venv
```

`install.sh` is idempotent — re-run it any time after pulling changes to refresh the installed binaries and `notify.sh`.

System dependencies:

- **macOS** — Swift 5.9+ via the Xcode Command Line Tools (`xcode-select --install`). PortAudio ships with the system; voice will additionally pull `stackvox` from PyPI into a venv at `~/.stack-nudge/venv`.
- **Linux** — Bash, `paplay` / `aplay` / `notify-send` for sound notifications. The Swift panel app is macOS-only; on Linux only the `notify.sh` flow runs.

## Inner-loop development

```bash
make build      # builds both .app bundles into build/
make install    # full install (build + copy + register hooks + launchd)
make reload     # rebuild + replace installed panel + refresh notify.sh + bounce daemon
make dev        # watch sources; auto-reload on .swift / Info.plist / notify.sh / phrase changes
make uninstall  # remove apps, hooks, launchd agents, ~/.stack-nudge/
```

`make dev` is the main inner-loop tool. Leave it running in another terminal while you edit Swift files or `notify.sh` — the daemon bounces with the new build in ~2 seconds.

The Swift sources are compiled directly with `swiftc` for the shipping binaries — no Xcode project, no third-party Swift dependencies. There is a `Package.swift` manifest, but it exists only so `swift test` can run a unit-test suite over the testable parts of the panel; the apps themselves are still built by `build.sh`.

## Tests

```bash
make test     # equivalent to `swift test`
```

Tests live in `Tests/StackNudgePanelCoreTests/` and cover the pure-logic surfaces: `Hotkey.parse` / `encode`, `ConfigFile.parse` / `apply` / `bool`, `NudgeKind`, and `EventStore`.

`swift test` on macOS needs `XCTest`, which only ships with full Xcode. If you only have the Command Line Tools installed (`xcode-select -p` returns `/Library/Developer/CommandLineTools`), install Xcode and run:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Without Xcode the test sources are the one part of the repo that never gets
compiled locally, so an API change that breaks a test call site stays invisible
until CI fails on a build error. To catch that without installing Xcode:

```bash
make typecheck-tests   # compile-check the test sources; no XCTest required
```

It compiles the tests in-module against the real panel types, swapping XCTest for
the stand-ins in `scripts/xctest-shim.swift`. It does **not** run assertions —
`make test` and CI remain the authority on whether the tests pass. Run it after
any change that tightens a signature (a new required parameter, a renamed case).

CI runs the suite on every push and PR — `swift test` is one of the required checks.

## Source layout

- `notifier/` — the transient banner-renderer that fires per nudge and exits
- `panel/` — the persistent floating-panel daemon (hotkey, NSPanel, socket listener, menu bar, sessions list, settings, permissions window)
- `shared/` — code shared by both binaries (currently `AppActivator.swift`)
- `phrases/` — per-language voice phrase pools sourced by `notify.sh` at hook time
- `notify.sh` — the shell entry-point CC/Cursor/Gemini hooks invoke; routes events to banner / panel / voice surfaces
- `assets/` — logo / icon source files

## macOS permissions during development

The panel daemon needs **Accessibility** and **Automation → System Events** to send the approval keystroke. Each `make reload` re-signs the binary with a new ad-hoc signature, which invalidates prior TCC grants — System Settings still shows the entry as "on" but `AXIsProcessTrusted()` returns false. The Permissions checker (menu bar → Check permissions…) has a **Reset & prompt** button that runs `tccutil reset` and triggers a fresh dialog bound to the current cdhash. Use it whenever approval stops working after a build.

## Commit and branch style

- Branch names: `<type>/<short-topic>` (e.g. `feat/voice-phrases`, `fix/permissions-crash`, `chore/oss-readiness`).
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/):
  - `feat: add X`
  - `fix: handle Y`
  - `docs: update README`
  - `refactor: extract panel components`
  - `test: cover hotkey parser`
  - `chore: bump dependencies`
- Prefer small, focused commits over large omnibus ones. The exception is genuinely-coupled work that has to land together; in that case, structure the commit body to explain the coupling.

## Pull request checklist

- [ ] `make build` succeeds locally and you've manually verified the change with `make reload`.
- [ ] No new compiler warnings in your changed files (existing `NSUserNotification` deprecation warnings in `notifier/` are pre-existing — leave them).
- [ ] README updated if user-visible behavior changed.
- [ ] No credentials, API keys, or PII in the diff.
- [ ] Branch is rebased on the latest `main` if it's been more than a day.

## Code style notes

- **Swift**: keep the no-Xcode / no-SPM constraint. New files go under `panel/`, `notifier/`, or `shared/` and are added to the explicit file list in `build.sh`. No third-party Swift dependencies — the value of the build's simplicity outweighs the convenience of pulling libraries.
- **Shell**: `notify.sh` and the `phrases/*.sh` are POSIX-bash. Use `bash -n` to syntax-check before committing. Avoid `bashisms` that aren't strictly necessary.
- **Filesystem paths** should resolve relative to the script (`BASH_SOURCE` for shell, `NSHomeDirectory()` / `~/.stack-nudge/...` for Swift) rather than being hardcoded against `$HOME` or `/Users/...`.
- **Comments** explain the *why* — particularly for AppKit / AX edge cases that aren't obvious from the code. Don't comment what the code already says.

## Reporting security issues

Do not file public GitHub issues for security vulnerabilities — see [`SECURITY.md`](./SECURITY.md).
