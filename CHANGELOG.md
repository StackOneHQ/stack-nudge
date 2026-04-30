# Changelog

All notable changes to stack-nudge are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Pre-1.0, breaking changes bump the **minor** version.

## [Unreleased]

### Added

- Repo prepared for open-source release: `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `NOTICE`, this changelog, GitHub issue / PR templates, dependabot config for actions, and a CI workflow that verifies the Swift build and shell scripts on macOS.

## [0.3.0] — 2026-04-30

### Added

- **Tabbed keyboard panel** — Events / Sessions / Settings tabs reachable via `Cmd+1` / `Cmd+2` / `Cmd+3` or the in-panel tab strip.
- **Sessions tab** — live list of running `claude` / `gemini` / `codex` agent processes (including node-hosted variants like `gemini-cli`). Polls `ps` + `lsof` every 3 seconds while visible. Supports focus-source-terminal (⏎), inline rename (`n`), and SIGTERM kill (⌫). Closes #3.
- **Settings tab** — keyboard-driven rows for hotkey, banner / voice toggles, sound picks (with audio preview on cycle), voice picker (with conversational-phrase preview on cycle), speed, plus action shortcuts to permissions / open config / quit.
- **Hotkey recorder** — record a new global hotkey from inside Settings; re-registers live and persists to `~/.stack-nudge/config`. Surfaces an inline error when the OS rejects the combo.
- **Per-pane focus in VS Code / Cursor** — before sending the approval keystroke, the panel walks the editor's accessibility tree to focus the terminal pane labelled with the agent's binary name (claude / gemini / codex). Falls back gracefully if no match.
- **Per-language voice phrase pools** — `phrases/{en,fr,hi,it,pt}.sh` provide event-specific (response / notification) phrasing keyed off the configured Kokoro voice's language prefix. Voice messages now sound like *"unified cloud api is ready for you"* or *"unified cloud api requires a decision"* instead of the literal "Done".
- **Config file watcher** — external edits to `~/.stack-nudge/config` flow back into the running panel without a restart. Re-arms on rename/delete so atomic-save editors don't orphan the watcher.
- **Permissions window** with a Reset & prompt action that clears the TCC entry and triggers macOS's standard grant dialog — recovers the rebuild-invalidates-cdhash gotcha that bites every iteration of an ad-hoc-signed dev build.
- **Voice replaces sound** — when `STACKNUDGE_VOICE=true`, the chime is suppressed across all surfaces so the user doesn't get double-cued.
- **`make dev`** watch-loop for inner-loop development; rebuild + reinstall + bounce in ~2s on any `.swift` / `notify.sh` / `phrases/` save.

### Changed

- Default hotkey switched from `cmd+shift+n` (collides with "New Incognito Window" in browsers, "New Window" in many editors, "New Folder" in Finder) to `cmd+opt+n`.
- stackvox vendored copy removed; `install.sh` now pulls `stackvox>=0.3.0` from PyPI into the venv. The `find_python` helper in `install.sh` selects a Python ≥ 3.10 from common Homebrew paths when the system `python3` is too old.

### Fixed

- Permissions window crash on open (`NSInternalInconsistencyException` from setting both `.canJoinAllSpaces` and `.moveToActiveSpace` on `collectionBehavior`).
- Hotkey recording-mode trap — ↑/↓/Tab now cancel recording so users who entered by mistake aren't stuck.
- Banner suppression when source window is frontmost respects the voice / sound interplay.

## [0.2.0] — 2026-04-25

### Added

- **Keyboard-native floating panel** — opt-in `STACKNUDGE_PANEL=true` runs a persistent daemon that surfaces nudges in a borderless HUD-blur window summoned by global hotkey. Acts on events with the keyboard (↑/↓ select, ⏎ approve / focus, ⌫ dismiss, esc hide).
- **Menu bar bell icon** with quick toggles for banner / voice, links to the panel and config file, and a Quit action.
- **Per-event PID / session enrichment** — `notify.sh` walks the parent process tree on each hook and emits `agent_pid`, `shell_pid`, `terminal_pid`, `terminal_app`, `term_program`, and `session_id` alongside the existing fields. Used by the panel for session correlation.

## [0.1.0] — 2026-04-22

### Added

- Initial release. Supports Claude Code, Cursor, Gemini CLI, and Codex via `notify.sh <agent> <event>`.
- macOS native banners with click-to-focus that route back to the source editor / terminal window. Supported apps: VS Code, Cursor, iTerm2, Warp, Ghostty, Terminal.app.
- Voice notifications via [stackvox](https://github.com/StackOneHQ/stackvox) — bundled and set up automatically by `./install.sh`.
- `STACKNUDGE_ACTIVATE_IMMEDIATELY=true` for click-free editor focus.

[Unreleased]: https://github.com/StackOneHQ/stack-nudge/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/StackOneHQ/stack-nudge/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/StackOneHQ/stack-nudge/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/StackOneHQ/stack-nudge/releases/tag/v0.1.0
