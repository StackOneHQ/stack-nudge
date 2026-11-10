# Notifications

How StackNudge hears from your agents, what it does with a permission prompt, and the ways it can reach you: banners, sound, voice and Slack.

## Where nudges come from

Each supported agent has a hooks system. `stack-nudge` registers these hooks:

| Agent | Event | What happens |
|-------|-------|--------------|
| Claude Code | `Stop` | Banner when the turn ends |
| Claude Code | `PermissionRequest` | Banner when Claude pauses for approval |
| Cursor | `stop` | Banner when agent turn ends |
| Codex | `Stop` | Banner when the turn ends |
| Codex | `PermissionRequest` | Banner when Codex pauses for approval |
| Gemini CLI | `AfterAgent` / `Notification` | Banner when the turn ends / when it asks for permission |
| Antigravity CLI | `AfterAgent` / `Notification` | Banner when the turn ends / when it asks for permission |
| pi | `agent_settled` (via extension) | Banner when the turn settles |

The hook calls `notify.sh <agent> <event>`, which plays a sound and shows a banner via:

1. **macOS** — the native `StackNudge.app` (click-to-focus routes back to your editor)
2. **Linux** — `paplay` / `aplay` / `notify-send`
3. **Windows** — `powershell [console]::beep`

## Click-to-focus (macOS)

When you click the banner, `StackNudge.app` uses System Events to raise the exact window that triggered the notification — even if you have multiple Cursor or terminal windows open. Clicking a permission banner also hands the prompt back to the agent, so it's waiting for you in the terminal (Codex won't show its own prompt while the hook is still holding it). Supported apps:

- Cursor, VS Code, Zed
- iTerm2, Warp, Ghostty, Terminal.app
- tmux panes inside any of those

With **Mute when focused** on (the default), a notification whose target app is already in focus shows no banner and only the sound plays, or nothing at all when voice is on.

> **Note on Zed:** Zed itself doesn't expose an external hook system, so stack-nudge relies on the agent's hooks (e.g. `~/.claude/settings.json` for Claude Code) firing from inside Zed's integrated terminal. Click-to-focus and frontmost-window suppression are wired up via `TERM_PROGRAM=zed`, which Zed sets automatically.

## Immediate focus mode

If you'd rather have your editor focus automatically — no click needed:

```bash
STACKNUDGE_ACTIVATE_IMMEDIATELY=true
```

Add that line to `~/.stack-nudge/config`. The panel reads it from there, not from your shell.

## Feed events

Besides agent nudges, the queue can show events from a script or an in-app feed. A script writes one JSON object per line to `~/.stack-nudge/panel.sock`:

```bash
printf '%s\n' '{"agent":"deploy-bot","event":"other","title":"Deployed","message":"api to production","source":"script","tag":"deploy","severity":"action","url":"https://example.com/deploys/9","repo":"acme/api","key":"deploy:9"}' \
  | nc -U ~/.stack-nudge/panel.sock
```

`agent`, `event`, `title` and `message` are required. The rest are optional:

| Field | Meaning |
|-------|---------|
| `source` | `script`, `github` or `calendar`. Anything else, or `agent`, makes it an ordinary agent event. A feed event is never a permission prompt: it ignores `event`, `fifo_path`, `hook_pid` and `has_action_button`. |
| `tag` | Free-form label that picks the row's icon: `review`, `review-request`, `ci`, `ready`, `deploy`, `pipeline` or `calendar`. Any other tag gets the source's icon. Searchable in history. |
| `severity` | `info` (default), `action` or `alert`. Colours the icon grey, orange or red. |
| `url` | Opened by `⏎` or `O` (the primary action reads **Open**). Only `http` and `https` links are kept. Without one, `⏎` just dismisses the row. |
| `repo`, `pr` | Shown in the row's chip, for example `GitHub · api#9`. |
| `key` | An event with the same `key` replaces the one already queued, so a build that fails and then passes is one row. |

Each source keeps its own 20 most recent events, so a busy feed can't push a permission prompt out of the queue. A feed banner doesn't clear other banners, and clicking it opens its `url`. History records the source, tag and link, and searches the source and tag.

Records live in `~/.stack-nudge/events.jsonl` (mode 0600), one JSON object per line, holding timestamp, agent, kind, title, message, repo path, and session id — the descriptive fields only, never the FIFO paths or PIDs. They're kept for 30 days or 10,000 records, whichever binds first, trimmed once per launch. **The log contains prompt and tool text**, so if that isn't something you want on disk, turn it off in Settings → **Event history** (`STACKNUDGE_EVENT_HISTORY=false`); Settings → **Clear event history** deletes the file outright. Nothing is ever sent anywhere — this is a local file, same as the rest of `~/.stack-nudge`.

## Permission prompts

**Answering elsewhere clears the prompt.** A permission prompt is tracked by two things: the FIFO notify.sh creates for your decision, and the hook process waiting to read it. Both are required. The FIFO alone isn't proof — its cleanup is skipped entirely on `SIGKILL`, which is what the agent does to the hook when you answer in its own UI. (It was also skipped on a clean exit until recently — the trap referenced a variable that had gone out of scope by the time it fired — so answered and timed-out prompts leaked their FIFO directory until the half-hourly sweep collected it.) So approving a plan in the terminal used to leave the panel convinced the prompt was still blocking, keeping it in the menu-bar count and re-nudging you (and Slack) for the full 550 seconds. Now a prompt whose hook has gone is retired within a tick, because there's nobody left to read a decision.

**Some prompts get a banner but no button.** Two kinds of Claude Code event arrive through the same permission hook as a tool call but are not a yes/no question, and stack-nudge shows them without an **Allow**:

- **Questions and plan approvals** (`AskUserQuestion`, `ExitPlanMode`). Claude Code renders its own dialog *concurrently* with the blocking hook, and whichever answers first wins. An **Allow** here isn't "approve" in either case — it arrives as Return on the dialog's first option, and what that option *is* differs. On a question it picks the highlighted answer, so the agent proceeds on a choice you never made. On a plan it approves the plan **and** the permission mode bundled into that first option (*"Yes, and auto-accept edits"* / *"and use auto mode"* / *"and bypass permissions"*, depending on the build), which loosens approvals for everything after it. The banner still tells you the agent is waiting; you answer in its own UI.
- **Payloads stack-nudge cannot read.** If the hook can't extract a `tool_name` — no `jq` and no `python3`, a broken `jq`, a schema change that moves or retypes the field — it can't tell a tool call from a question, so it fails open: banner, no button, and the hook exits rather than holding a FIFO nobody can answer. The agent prompts in its terminal exactly as it would without stack-nudge installed.

Both are a button withheld, never a prompt hidden and never an answer sent on your behalf — the asymmetry is the point, since the alternative failure answers for you.

**Reminders for prompts you didn't answer.** macOS slides a banner into Notification Center after a few seconds, so a permission prompt you missed used to leave the agent blocked with nothing on screen to say so. stack-nudge now re-nudges: while a prompt is still waiting, it fires again on an interval (`STACKNUDGE_REMIND_MIN`, one of 1 / 2 / 5 minutes, default 2, `Off` to disable), up to three times — or fewer at longer intervals, since reminders stop once the hook hits its own 550-second timeout. The reminder carries the same **Allow** / **Deny** buttons and reads *"Still waiting 4m · Bash(rm -rf build/)"*, and the menu-bar icon shows a live count of prompts waiting on you — the one signal that survives an expired banner.

Reminders only fire for prompts stack-nudge can *prove* are unanswered. Claude Code and Codex permission hooks block on a FIFO that's removed the moment the hook exits, so its presence means nobody has answered — in the panel, on the banner, or in the terminal. Gemini and Antigravity route permissions through fire-and-forget notification hooks with no such signal, so they get the single banner they always did rather than reminders that might be about something you already handled. Reminders stop at three, and stop early once the hook hits its own 550-second timeout and the agent falls back to prompting in the terminal. A per-session mute silences them like any other nudge. A *global* mute silences the banner and sound but not the Slack DM — see the Slack section for why.

**Prompts raised by a subagent say so.** Claude Code's `Task` agents and Codex's `spawn_agent` children run their tool calls through the same permission hook as the main thread, so a prompt from an `Explore` agent used to be indistinguishable from one you'd asked for; that's the case where attribution matters most, since the reaction to an unexpected approval prompt is *"I didn't ask for that"*. Those banners now read **Claude Code · Explore** (plugin-scoped agent names are shown unscoped). If you'd rather not hear from them at all, set `STACKNUDGE_SUBAGENT_NUDGES=off` and they're dropped: the agent still prompts in its own terminal, so nothing is auto-approved, but nothing tells you it's waiting either, which is why tagging is the default. Turn-end nudges never needed this: both agents convert a subagent's turn end to their own `SubagentStop` event, which stack-nudge doesn't wire.

**Headless runs stay quiet.** A script driving an agent (`claude -p` / `--print`, `codex exec` / `e` / `review`) fires the same hooks as a person at a terminal, but nobody can answer its prompts, and a held hook would stall the script for up to 550 seconds. stack-nudge posts nothing for those runs and leaves the decision to the agent's own permission setting; their turns ending aren't nudged either. Set `STACKNUDGE_HEADLESS_NUDGES=on` to treat them like any other session.

## Slack

**Slack, for when you're not at the Mac.** Banners only work if you're looking at the screen. Point stack-nudge at a Slack bot token and a permission prompt also arrives as a DM **from StackNudge** — which, unlike a message you send yourself, actually notifies you.

| Setting | Default | |
|---|---|---|
| `STACKNUDGE_SLACK` | off | Master switch; turned on for you by a successful test message |
| `STACKNUDGE_SLACK_IDLE_MIN` | `5` | Minutes idle before Slack is used. `Always`, or 5–60 in steps of 5 |
| `STACKNUDGE_SLACK_DETAIL` | off | Include the tool call, not just the headline |
| `STACKNUDGE_SLACK_STOP` | off | Also DM on finished turns, not just permission prompts |
| `STACKNUDGE_SLACK_MEMBER_ID` | — | Who to DM. Detected for you; not secret |

**Setup, once per person:** Settings → **Paste Slack setup** reads your clipboard and takes either an `xoxb-…` bot token, a `U…` member ID, or a JSON blob with both — so an org can keep one password-manager entry and onboarding is a single paste. stack-nudge then looks you up from your `git config user.email` and shows who it found; that's a *suggestion*, and pasting a member ID overrides it. **Send test message** confirms the whole chain and switches delivery on.

**Setup, once per org:** create a Slack app, give its **bot** token `chat:write` (plus `users:read.email` and `users:read` if you want the automatic user lookup), install it, and share the `xoxb-` token internally. There is deliberately **no default app and no embedded credentials** — every install points at its own workspace.

The token lives in the **Keychain**, never `~/.stack-nudge/config`. For scripted provisioning you can plant `STACKNUDGE_SLACK_BOT_TOKEN` in the config file; stack-nudge moves it into the Keychain on next launch and deletes the line. (The config file is now written `0600` regardless — it never needed to be world-readable.)

Three things worth knowing about how it behaves:

- **It's idle-gated, not a mirror.** By default nothing reaches Slack until the Mac has been untouched for 5 minutes — there's no point pinging your phone about a prompt you're already looking at. Set it to `Always` if you'd rather have everything — that removes the *idle* gate, not the rate limit below. Reminders for prompts you never answered skip the gate: you may be back at the desk and still not have seen the banner.
- **Finished turns are rate-limited; permission prompts aren't.** The limit is global rather than per session, so with several agents running the headline names one of them and the rest are folded into the count — the DM means "go and look", not "look here specifically". The idle setting decides *whether* you're away, not how often you're interrupted while you are — so on its own it would send a DM per event, and an unattended hour can produce fifty. Finished turns are therefore folded into one message per 15 minutes, which says what it swallowed (*"finished a turn · 7 more while you were away"*). Permission prompts are never batched: each one is blocking something until you answer it, and repeats of a single prompt are already capped at three. Coming back to the machine clears the wait — but only a stay longer than the idle threshold does, since a single stray keystroke is indistinguishable from a trackpad bump.
- **A global mute does *not* silence Slack.** Mute means "stop interrupting me *here*", and Slack exists precisely because you're elsewhere. Use the Slack switch to stop it. A *per-session* mute does apply, same as it does to banners.
- **Titles only, by default.** A DM reads *"Claude Code in web-app needs permission"*. The tool call itself (`Bash(rm -rf build/)`) stays on your machine unless you turn on **Include message text**, because command lines carry paths, hostnames, and sometimes secrets, and this is the one path that leaves the Mac.

You can't approve or deny from Slack — that needs an inbound endpoint this app deliberately doesn't have.

> **Why a bot token and not "Connect with Slack"?** We tried. Slack supports OAuth with PKCE, which lets a desktop app authenticate with no client secret and no server — but *"desktop redirects are not allowed to request bot scopes"*, so it only yields a **user** token, and a user token can only post *as you*. Slack never notifies you about your own messages, so those DMs arrive silently. A notifying DM requires a bot token, a bot token requires the client-secret exchange, and a desktop app can't hold a secret. Slackbot reminders were the remaining workaround and Slack retired that API in March 2023. Hence: provision the token, paste it once.

## Voice

stack-nudge uses [stackvox](https://github.com/StackOneHQ/stackvox), an offline Kokoro-82M TTS engine that speaks notifications aloud with ~13 ms latency. The release app ships with it bundled; a source install (`./install.sh`) pip-installs it from PyPI into an isolated venv at `~/.stack-nudge/venv`. No separate setup either way.

**Enable** via Settings → Voice → "Voice notifications". Until the voice model is downloaded, that category offers **Download voice model** in place of the Voice and Speed rows. **Read aloud shortcut** (`STACKNUDGE_SPEAK_HOTKEY`, default `cmd+opt+s`) speaks whatever text you have selected, in any app.

The voice daemon starts automatically on first notification and is registered as a login item so it stays running across reboots.

Voice fires alongside the banner and panel surfaces. The frontmost-suppression check still applies — when the source window is already focused, sound, banner, panel post, *and* voice are all suppressed (you don't need a nudge for the thing you're looking at).

When voice is enabled, the chime is suppressed automatically — voice replaces sound rather than playing alongside it.

### Phrasing

Voice messages are picked at random from per-event phrase pools and labelled with the project name (cwd basename, with hyphens/underscores split and a few acronyms expanded — `CLI` → `C L I`, `MCP` → `M C P`, etc.). For a project called `checkout-service` you'll hear things like:

- **Stop:** *"checkout service is ready for you"* / *"task complete in checkout service"* / *"output ready in checkout service"*
- **Permission:** *"checkout service requires a decision"* / *"checkout service has a question for you"* / *"checkout service is awaiting approval"*

Phrase pools live in `~/.stack-nudge/phrases/` — `en.sh`, `fr.sh`, `hi.sh`, `it.sh`, `pt.sh`. The right pool is picked from the configured voice's prefix (`af_*`/`am_*`/`bf_*`/`bm_*` → en, `ff_*` → fr, `hf_*`/`hm_*` → hi, `if_*`/`im_*` → it, `pf_*`/`pm_*` → pt) so a French voice speaks French phrasing.

Tune via Settings → Voice → "Voice" (cycle voices with preview) and "Speed" (1.0 = normal).

## Sounds

| Event | macOS | Linux | Windows |
|-------|-------|-------|---------|
| Agent done | `Glass.aiff` | freedesktop bell | 800 Hz beep |
| Waiting for approval | `Ping.aiff` | freedesktop bell | 1200 Hz beep |

Any file from `/System/Library/Sounds/` works on macOS: Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink. Override per-event via Settings → Notifications → "Agent done" / "Permission", with **Sound enabled** on (cycle plays a preview on each step).

## Phrase editor

The phrase pools that power [voice notifications](#voice) can be customised in-app. Settings → Actions → "Edit phrases…" opens a keyboard-driven editor where you can:

- Toggle individual built-in phrases on or off (`Space`)
- Add your own custom phrases (typed inline, `Enter` to commit)
- Remove custom phrases (`⌘⌫`)

Per-pool customisations are stored in `~/.stack-nudge/phrases.user.json` and merged with the built-in pools at notification time. Disable a built-in phrase you find too cheery, add ones in your own voice — the same random-selection logic still applies.
