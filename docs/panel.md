# The panel

Everything the floating panel does, tab by tab, and the keys for each. Start with the [README](../README.md) for install and the short tour.

## Opening it and moving around

If you'd rather not click banners with the mouse, stack-nudge runs a small floating panel that you summon with a hotkey. Its tabs are **Events**, **Sessions**, **Usage** and **Outcomes**, then one per installed extension that adds a tab, then **Settings**, and it is fully keyboard-driven.

The panel is registered as a launchd agent by the first-launch wizard (or `./install.sh` for a source install) — no opt-in needed. To run quietly without macOS banners, toggle **Settings → Notifications → Banner notifications** off (panel-only mode).

Default hotkey is `cmd+opt+n`. Hit it from anywhere to summon the panel; hit it again while focused to hide. Switch tabs with `Cmd+1` (Events), `Cmd+2` (Sessions), `Cmd+3` (Usage), `Cmd+4` (Outcomes) and so on in strip order, or click them; Settings is always last, so it's `Cmd+5` only with no extension tabs. `Cmd+,` opens Settings from anywhere, and so does **Settings…** in the menu bar menu. Banner and panel can run together, alone, or both off; the sound and voice still fire as passive signals.

These keys work the same on every page, including while a text field has focus:

| Key | Action |
|-----|--------|
| `Esc` | Hide the panel. In a text field it cancels the field instead: a filter, search or new phrase empties and hands the keyboard back to the page, a rename or config field keeps its saved value. While a shortcut is being recorded it cancels that and keeps the old one, and `Esc` with a modifier is recorded as the shortcut. The footer's last hint shows which. |
| `⌘←` / `⌘→` | Previous / next tab. From a sub-page, the tabs either side of the one it belongs to. Not while recording a hotkey, where they do nothing (a shortcut can't use an arrow), and not on the setup screen or Permissions opened from it, which have no tabs. |
| `⌘,` | Open Settings, as in any Mac app. Works from a text field too; not while recording a hotkey, or on the setup and update screens. |
| `⌫` in an empty text field | Cancel the field, as `Esc` does. A fresh press only: holding `⌫` to clear a field stops once it's empty. |
| `⌘↑` / `⌘↓` | First / last row of a list. In Settings they move to the previous / next category instead. |

Outside a text field, `←` is back a level on sub-pages and detail panes: out of a detail pane, or from a sub-page to the page it belongs under. The exception is picking a value in Settings, where `←` / `→` step the value.

## Events

Recent nudges in chronological order. Each shows agent, message, project name, time. What happens to a permission prompt, reminders, feed events and Slack are in [notifications.md](notifications.md).

| Key | Action |
|-----|--------|
| `↑ ↓` | Move selection |
| `⏎` | Approve permission / focus source editor |
| `O` | Focus source editor without approving, a waiting prompt goes back to the agent to answer there |
| `S` / `⇧S` | Snooze a waiting permission prompt for 5 / 15 minutes: the hook keeps waiting and the banner fires again afterwards |
| `M` | Mute all notifications for the configured duration (press again to resume) |
| `⌫` / `⌦` / `R` | Dismiss the selected nudge locally |
| `H` | Open the searchable history pane |
| `F` | Focus the tag chips above the list (feed events only); `F` or `↓` returns to the list |
| `← →` `⏎` `Space` `⇧⏎` | On the chips: move, toggle the chip (or All/None), show only that tag |
| `U` | Mark the selected feed event read or unread |
| `A` | Mark all feed events read |
| `C` | Clear all feed events; press `C` again to confirm, any other key backs out. Permission prompts are never cleared |
| `Space` / `→` / `←` | Expand or collapse a grouped feedback row |
| `Esc` | Hide the panel |

When you press `⏎` on a permission event in a VS Code / Cursor terminal pane, stack-nudge walks the editor's accessibility tree to focus the right pane (matched by the agent name in the tab title) before sending Enter — so the approval keystroke lands in the agent's terminal, not whatever was last focused. Falls back gracefully if the pane can't be found.

**Mute for a while.** Press `M` (or use the bell button in the panel header, or the menu-bar **Mute notifications** submenu) to silence *everything* — banner, sound, voice, and the focus jump — for a set duration, **including permission prompts**. Events keep flowing into the panel while muted; only the interruptions are suppressed. A live countdown shows on the header bell and the menu-bar icon (the compact widget just shows a muted-bell glyph), and the mute lifts itself when the timer runs out (or immediately if you press `M` / **Resume** again). The default duration is configurable (`STACKNUDGE_MUTE_DURATION_MIN`, one of 15 / 30 / 60 / 120, default 30) and can be cycled in Settings. Mute is in-memory only — it resets on relaunch.

**History.** The list above is a live triage queue — capped, pruned per session, and gone when you quit. Press `H` for the durable log behind it: every nudge, newest first, with a filter box that matches on message, agent, and repo. `↑↓` and `⌘↑↓` walk the rows; start typing (or press `/`) to filter, `⏎` hands the keyboard back to the rows, and `←` steps back to the queue.

History is deliberately a separate pane rather than more rows in the queue. The queue is an action list — `⏎` approves, `⌫` dismisses — and a replayed record has no FIFO to answer and no process to focus, so mixing the two would make those keys mean different things depending on which row you happened to land on.

## Sessions

Live list of running agent processes (`claude`, `gemini`, `codex`, `agy`, `pi` — including node-hosted variants like `gemini-cli`). Polls every 3 seconds while visible and every 10 seconds in the background for the compact widget. Sessions that exit linger for 30s with `ended Ns ago`.

**Stalled sessions.** An agent that reports itself busy but has produced nothing for a while is usually a wedged tool call. Set `Settings → Notifications → Flag stalled after` (`STACKNUDGE_STALLED_MIN`, one of 10 / 20 / 30 / 60 minutes, default `Off`) and those rows turn amber and read `stalled · no output 24m` instead of a `busy` that implies progress. Flagging only — no banner, since there's nothing to approve and a stall often clears itself.

For Claude Code sessions specifically, stack-nudge reads `~/.claude/sessions/<pid>.json` (Claude Code's per-process sidecar) to surface live data without waiting for a hook event:

- **Live status dot** — yellow for `busy` (turn in flight), green for `idle` (waiting for input).
- **Session name** from the sidecar when set to anything other than the default `main-agent` (falls back to the project name otherwise).
- **Context-window usage** — `293K tokens · opus-4-7` beneath the project path, updated on each Claude turn.

**Terminal tab titles.** Each row's meta line shows the terminal, the tab's title, and the working directory — `iTerm2 · ✳ Fixing the parser · ~/src/stackone`. Where the title comes from depends on the terminal:

| Terminal | Source | Can name a session? |
|---|---|---|
| iTerm2 | AppleScript `autoName` | yes |
| Terminal.app | AppleScript `custom title` (set by a human, or absent) | yes |
| tmux | `#{pane_title}` per pane | yes |
| VS Code / Cursor | the OS **window** title, shipped by the hook | no — see below |
| Warp | — | no title available |
| Ghostty | — | no title available |

VS Code and Cursor are the odd one out: what's shown there is the editor's window title (`Panel.swift — stackone — Cursor`), which names whichever file is open and changes on every editor tab switch. It's useful context on the row, so it stays visible — but it's never used as a session name.

By default a tab title is *shown* but never used as the session's **name**. It can't be trusted as one: on iTerm2 a manual rename, an OSC escape and the profile name all write the same value, tmux's `#{pane_title}` is the same OSC signal, and Claude Code rewrites the title every turn — so there's no way to tell "the user chose this" from "the agent just overwrote it".

If you do title your tabs deliberately and want those names back, turn on `Settings → Panel → Name from tab titles` (`STACKNUDGE_TAB_TITLE_NAMES`, default off). It applies everywhere a session is named — Sessions rows, the compact widget, event rows, banner titles and spoken nudges — and sits below the two signals that *are* deliberate: a rename in the Sessions pane (`n`) and a name set inside the agent both still win. It only ever replaces the fallback to the project folder, and it never applies to VS Code / Cursor sessions, per the table above. A leading spinner glyph is trimmed, since Claude Code cycles one into the title frame by frame (`✳ Fixing the parser`) and it would otherwise churn the name and be read aloud as *"eight spoked asterisk"*.

**Slack is the exception:** a DM only uses the tab title when `Include message text` (`STACKNUDGE_SLACK_DETAIL`) is also on, and falls back to the project name otherwise. That switch exists because a DM is the one path that leaves your machine, and a tab title is whatever the program in that pane wrote — oh-my-zsh, starship and most prompt frameworks put `user@host: /full/path` there via a `precmd` title hook. If you turned detail off deliberately, this doesn't route your paths out through a different door.

Rows are ordered busy-first, then by most-recent activity. Status label reads `busy · 2 min ago` / `idle · 1 hr ago`.

| Key | Action |
|-----|--------|
| `↑ ↓` | Move selection |
| `⏎` | Focus the session's source terminal |
| `n` | Rename the selected session inline |
| `M` | Mute / unmute this session's nudges |
| `⌘⌫` | Send SIGTERM to the agent process |
| `o` | Resume a recent Claude Code session (one that isn't running) in a new terminal window |
| `t` | Start a new Claude Code session in one of your repos, in a new terminal window |
| `Esc` | Hide the panel |

`o` lists your 15 newest Claude Code transcripts from `~/.claude/projects`, by project and title. `t` lists the git repos directly under `STACKNUDGE_CHECKOUTS_ROOT` when it's set, or else the folders of your recent sessions. Both open Ghostty when it's installed and Terminal.app otherwise; `STACKNUDGE_SESSION_TERMINAL` (`ghostty`, `terminal` or `iterm`) picks one. Both open a menu at the panel's top-left that you drive with `↑ ↓` and `⏎`; `Esc` closes the menu, and the panel stays.

## Usage

Reachable from the tab strip or `Cmd+3`. Renders your Claude Code subscription quota — the same numbers `claude /usage` shows in the terminal — but always available without typing the command:

- **Current session** (5-hour rolling window)
- **Current week (all models)**
- **Current week (Opus only)** *(when your plan has the tier)*
- **Current week (Sonnet only)** *(when your plan has the tier)*

Bars are color-coded: green below 50%, yellow 50–80%, red 80%+. Reset times shown per tier.

Claude Code keeps one login per config dir, so a second account run with `CLAUDE_CONFIG_DIR` (a team seat beside your own plan, say) never shows up in a plain `claude /usage`. stack-nudge looks for them by the `.claude.json` every one has, whatever it's called: any dir up to two levels under home holding one (rescanned hourly, skipping Desktop, Documents, Downloads, Library and the media folders, which macOS would prompt for), any dir in the `CLAUDE_CONFIG_DIR` of a `claude` running now (remembered in `~/.stack-nudge/claude-config-dirs`, so its row stays after the session ends), and any dir listed comma-separated in `STACKNUDGE_CLAUDE_CONFIG_DIRS` in `~/.stack-nudge/config`. Only dirs signed in to a different account or organization from the default count. Each gets the same `/usage` probe with `CLAUDE_CONFIG_DIR` set to it, at most every five minutes, which also keeps that dir's own usage cache current for anything else reading it.

Each of those logins also gets its own row in the client list, straight under the default Claude one: titled Claude, with the organization (or the dir's name, for a second personal plan) and plan underneath. Every Claude card, the default one included, opens with the email it's signed in as and its organization ("Personal" for your own plan). Its History pane reads that login's own transcripts. Quota alerts fire for every login, and name it. While any Claude row is selected, the mascot's stress takes the hottest Claude login, so a team seat running out shows even while you're looking at your own plan.

Each bar is really two: a pale bar showing how far through the window you are, with the solid usage bar inset inside it. Compare the two right-hand edges — usage short of elapsed means you're spending quota slower than the clock is running it down; usage past elapsed means you'll hit the cap before the reset. It answers “am I above 50% usage with 50% of the window left?” at a glance. When usage leads the clock by five points or more, the row also says so outright — *“22% ahead of pace”*. Only that direction is called out: there's no “on track” line to learn to ignore, so the warning still means something when it shows up. The pale bar needs both a reset time and a window length, so it's absent where either is missing: Antigravity publishes a reset time per model but never a window length, and its monthly credit pool has neither. It's also absent once a tier's reset time has passed, since a snapshot that outlived its own window can't be placed on one.

Numbers come from the vendor's own CLI, never from a provider API directly. For Claude, stack-nudge reads the usage payload Claude Code caches to `~/.claude.json` when that cache is under a minute old, and otherwise shells out to `claude --print /usage`. Because the CLI holds its *own* keychain grant, **stack-nudge never touches your keychain or calls the Anthropic API, so there's no password prompt**. If `claude` isn't on your `PATH` or you're signed out, the tab shows *"Claude usage unavailable — run `claude /usage` to check your session"* rather than falling back to any other source; if the CLI breaks with a usable reading still on disk, the tab shows that reading dated to when it was taken rather than nothing at all.

Codex works the same way through a different door: stack-nudge asks the local `codex app-server` for `account/rateLimits/read`, which returns **account-wide** limits, quota you spent on the web, in the IDE or on another machine included. A `codex` too old to serve it falls back to the newest rollout file under `~/.codex/sessions`, which only sees turns run on this machine. The same exchange asks `account/read` who's signed in, and the Codex card opens with that email. Codex has no organization name to go with it, so the line is the email alone.

Codex keeps one login per `CODEX_HOME` (`~/.codex` by default), and those get rows too. stack-nudge looks for them the same three ways: any dir up to two levels under home holding an `auth.json` and a file Codex writes on its first run there (`installation_id` or `version.json`, so pi's `~/.pi/agent/auth.json` doesn't count), any dir in the `CODEX_HOME` of a `codex` running now (remembered in `~/.stack-nudge/codex-homes`), and any dir listed comma-separated in `STACKNUDGE_CODEX_HOMES`. It only checks that `auth.json` is there and never opens it. Each one gets the same `codex app-server` exchange with `CODEX_HOME` set to it, at most every five minutes, and its `account/read` says who it's signed in as. A dir signed out, on an API key, or signed in to the same ChatGPT workspace as another login (the default one included) gets no row of its own; the same email in another workspace does. Each row sits straight under the default Codex one, titled Codex with the dir's name and plan underneath, opens with its email, reads its History from its own `sessions` dir, and alerts on its own numbers. While any Codex row is selected, the mascot's stress takes the hottest Codex login. Antigravity is unchanged: its usage comes from the running `agy` process over loopback.

Polls every 60 seconds while the full panel is open, and otherwise every 5 minutes by default (configurable via Settings → Usage → "Poll frequency"). The collapsed widget counts as background, so it polls at your configured frequency rather than the faster open-panel rate. Opening the panel syncs immediately if the last one is over a minute old. On the Usage tab: `r` triggers a manual sync, `p` pauses/resumes the poller.

Claude, Codex, Antigravity and pi each appear in the tab's client list when they have something to show; `↑`/`↓` switch between them, and `→` / `⏎` step into the selected client's detail. The detail is a carousel of two panes, the quota bars and then **History**, a graph of tokens over time: `→` / `←` move between them, and on History `↑`/`↓` change the metric and `W` the window. **The compact widget's gauge follows whatever you select here** — pick Codex in the Usage tab and the pill's rings, hover legend, and reset countdown all switch to Codex, with the client name shown in the legend on hover. All four are read on the same poll tick, so switching costs nothing. The selection is in-memory and resets to the first connected client on relaunch.

For Claude and Codex the two rings are the 5-hour and weekly windows. A Claude account with no 5-hour limit (a verified Ultra plan) shows the weekly window in the inner ring, with its reset countdown beside it. Codex reports the window length per limit rather than a fixed pair, and on some accounts publishes only a weekly one, so its Usage tab headings are named from what it actually reports. Antigravity reports neither — it publishes one window per model plus a monthly credit pool — so its inner ring shows whichever model is closest to its limit and the outer ring shows monthly prompt credits. Gemini CLI has no usage counter: unlike the others it writes no rate-limit data to disk and serves no local endpoint, so there's nothing to read.

**pi is the one client whose bars are not a quota.** It enforces none: its API models bill per token against your own keys, and its local models cost nothing. What its page tracks is a fair-usage budget you set yourself, one daily token allowance for API models and one for local models, with the week being seven days of it. The page lists one row per model, the same bar, reset line and pace warning as the other clients, each measured against the allowance for its kind and naming it (*"of 1.5M API budget"*), and the tab labels it `Budget` where the others show a subscription tier. `W` toggles the page between today and this week. The windows are calendar ones rather than rolling, which is what gives the reset time and the ahead-of-pace warning something to measure against, and the widget's rings follow whichever model is closest to its budget in each. Tokens are counted the way the history graph's "no cache reads" metric counts them, so resuming a long session doesn't burn the budget by replaying itself, and a turn counts as local when pi priced it at zero. Set the two allowances in Settings → Usage (`STACKNUDGE_PI_API_BUDGET` / `STACKNUDGE_PI_LOCAL_BUDGET`, tokens per day, `Off` to drop that kind's models from the page). Going over is reported rather than clamped: that is the only thing a budget you set for yourself can usefully tell you.

### Quota alerts

When any quota tier reaches your configured threshold, stack-nudge fires a banner (*"Weekly quota at 85%"*, with when it resets) once per period per tier, so you get a heads-up before hitting the cap. Claude's and Codex's do, for every login: an extra login's banner names it, and Codex's all start with Codex (*"Codex · Weekly quota at 85%"*, *"Codex · work · Session quota at 90%"*). Configure in Settings → Usage:

- **Quota tracking** — master switch for the whole feature (default on; off disables polling entirely)
- **Quota alerts** — banner toggle (default on)
- **Alert threshold** — 50% / 70% / 80% / 90% / 95% (default 80%)
- **Poll frequency** — 1 / 2 / 5 / 10 / 15 / 30 min (default 5)

### Per-session context alerts

Independent of quota: stack-nudge can also fire a banner when an individual Claude Code session's context window fills past a threshold you pick. The banner names the session — *"Context filling up — web-app — at 175K tokens (opus-4-7). Consider /compact."* — so you know exactly which one to act on.

- **Context alert at** — `Off` / 100K / 150K / 175K / 200K / 300K / 500K / 750K (default Off)
- Absolute tokens, not a percent — Claude 4.x context windows vary (Opus/Sonnet 1M, Haiku 200K, opt-in betas), and there's no reliable way to infer the limit from the model ID alone.
- One banner per session per threshold; the dedup re-arms whenever the session's token count drops by ≥20K (the characteristic shape of a `/compact` or `/clear`), so refilling after a compact alerts you again.

## Settings

Reachable from the tab strip, `Cmd+,`, or the last `Cmd`-number. A sidebar of categories on the left, the selected category's rows on the right:

| Category | Rows |
|----------|------|
| **Notifications** | Banner notifications, Mute when focused, Mute / Resume notifications, Mute duration, Remind unanswered, Flag stalled after, Sound enabled, and the Agent done / Permission sounds (preview as you cycle) |
| **Voice** | Voice notifications, the read-aloud shortcut, then Voice and Speed (preview as you cycle) once the voice model is downloaded, or **Download voice model** until it is |
| **Appearance** | Floating widget (`Pill`, `Companion` or `Off`), then the pill's own rows: Snap to corners, Widget corner, Widget opacity, Widget type, Mascot, Accent color |
| **Companion** | Size, Count badge, Preview pose, Reset position; **Turn on companion** while it's off. See [Companion](#companion) |
| **Usage** | Quota tracking, Quota alerts, Alert threshold, Poll frequency, Context alert, Show remaining, and the two pi budgets |
| **Integrations** | Slack (paste setup, detected user, test message, on/off, idle threshold, message text, finished turns) and GitHub (PR links, Hide shipped, Disconnect) |
| **Extensions** | What's installed, then **Browse extensions** (see [Extensions](#extensions)) |
| **Panel** | Hotkey, Pin panel, Keep open when empty, Launch at login, Name from tab titles |
| **Events** | History per session, Event history, Clear event history |
| **Actions** | Edit phrases, Check permissions, Open config file, View release notes, Check for updates, Uninstall, Quit |
| **About** | The version and hook-script status, and a link to this repo |

An extension that asks for a Settings page gets one under Extensions. A pending update, an extension update, a missing permission, or an agent whose hooks aren't wired yet shows as a row above every category. An app or extension update also puts a dot on the Settings tab.

| Key | Action |
|-----|--------|
| `↑ ↓` in the sidebar | Choose a category |
| `→` / `⏎` / `Tab` in the sidebar | Open it |
| `↑ ↓` / `Tab` / `⇧Tab` | Move between rows |
| `⌘↑` / `⌘↓` | Previous / next category |
| `Space` / `⏎` | Activate (toggles flip, action rows fire, hotkey row records a new combo, an extension's text setting opens its field). On a value row (sound, voice, duration, threshold, an extension's picker) it starts picking. |
| `←` / `→` while picking | Step through the values (sounds and voices preview as you go) |
| `Space` / `⏎` while picking | Settle on the value. Moving to another row settles it too. |
| `→` / `⏎` on an Extensions row | Open that extension's page (or the browser, from Browse extensions) |
| `⌘⌫` on an Extensions row or a page's Remove row | Remove the extension (no confirmation; ignores autorepeat) |
| `←` | Back to the category list, or from an extension's page back to the Extensions list |
| `Esc` | Hide the panel |

The hotkey row records live: press `⏎` on it, press the new combo, and stack-nudge re-registers the global hotkey. If the combo is already grabbed by another app, the previous one stays and an inline error explains why.

All Settings choices persist to `~/.stack-nudge/config` (a `KEY=value` text file). You don't need to edit it directly — Settings is the source of truth — but it's there for backup/sync or scripted setup.

## Outcomes

The **Outcomes** tab (`⌘4`) is two views of one dataset. It opens on the **Overview** (the aggregate); press `→` to carousel into the per-ticket **Tickets** list, `←` to step back.

### Overview

The spend-to-outcome picture over a trailing window, so you see not just *what* your agents did but *what share of it shipped*.

- **Shipped share**: the headline. Of the effort spent in the window, how much sits on work that merged or pushed, versus in-flight, versus **abandoned** (committed / needs-review work that's gone quiet for over 14 days).
- **Spend bar**: one bar partitioning tokens across those three buckets, coloured shipped (green) / in-flight (blue) / abandoned (orange).
- **Top tickets by spend**: the heaviest tickets (or unticketed repos) in the window, each with its dominant outcome. Click a row to open the ticket (when `STACKNUDGE_TICKET_URL` is set) or its PR.
- **Agents**: the token mix per agent alongside each agent's **shipped share**, so you can see whose work actually merges. Plus the model mix.

The Overview is a scroll page: `↑ ↓` scroll, `⌘↑ ⌘↓` jump to top/bottom, `W` cycles the trailing window (24h / 7d / 30d / 90d; 90d is the ledger's own retention ceiling). Because "abandoned" needs 14 days of quiet, it only appears on the 30d and 90d windows. It's token-only today; per-model dollar cost and reclaimed-time are planned follow-ups.

### Tickets

Every captured agent session rolled up **by ticket**, derived from your branch naming (`eng-123/…` → `ENG-123`), falling back to the branch when there's no ticket. Shows the tokens spent, files changed, and the live git outcome: *needs-review → committed → pushed → merged*. `↑ ↓` select rows, `⏎` opens the ticket or PR, `⌫` dismisses one, `←` steps back to the Overview.

The two panes agree by construction: both read the same per-branch outcome and PR state, so a squash-merged branch reads as shipped in each.

Opt-in GitHub linking adds real **PR + CI status** (so even squash-merged work reads as *merged*). Turn it on in Settings → Integrations → **GitHub PR links**, then sign in via the in-panel device flow (no `gh` needed). Config keys (all optional; the toggles in Settings write the same file):

| Key | What it does |
|-----|--------------|
| `STACKNUDGE_GITHUB` | `true` to enable GitHub PR/CI linking (off by default) |
| `STACKNUDGE_GITHUB_CLIENT_ID` | Override the embedded OAuth app Client ID (rarely needed) |
| `STACKNUDGE_TICKET_URL` | Deep-link template for ticket rows, e.g. `https://linear.app/acme/issue/{key}`; `{key}` is replaced with the ticket |
| `STACKNUDGE_HIDE_SHIPPED` | `true` to drop groups once their PR reads merged, keeping the list on in-flight work |

The sign-in finishes only once the token is saved to the Keychain and reads back. If the Keychain refuses the write, the sign-in card says so (with the `OSStatus`) instead of showing you as signed in, and `~/.stack-nudge/app.log` gets a line. If an earlier sign-in's token is still there, you stay signed in on it, and Settings notes under **Disconnect GitHub…** that the new sign-in didn't save.

**Nothing showing up?** A session is recorded when an agent's turn ends *inside a git repo*, and only if the hook payload carries a session id. The Tickets empty state names which of those failed; `~/.stack-nudge/app.log` has a line per dropped turn. The usual cause is an installed hook script older than the app, since updates swap the `.app` alone: the app repairs that on launch, and Settings warns in the footer if the rewrite couldn't be applied. To fix it by hand:

```bash
grep -c stack-nudge-version ~/.stack-nudge/notify.sh   # 0 means the script predates v1.26
./install.sh                                            # or reinstall from the app
```

## Extensions

**Settings → Extensions** lists what's installed: name, a one-line description, and a status (Update x.y, Running, Present / Away, Broken, Tab ⌘N…). `→` or `⏎` opens an extension's page: its status, its settings, what it's allowed, where it appears, and **Update** / **Remove**. The catalogues are checked for updates in the background, a minute after launch and then hourly, so an extension update shows without opening Settings: an **Extension update** row above every category names each one and the version it would get, and `⏎` on it opens the browser. Nothing installs from there without the browser's two presses. **Browse extensions**, below them, says how many are available and opens the catalogue: updates first, then what you haven't installed, ten at a time until you search, which matches names and descriptions.

| Key | On the browse page |
|-----|--------|
| `↑ ↓` / `⌘↑ ⌘↓` | Select / first or last |
| `⏎` | Install or update, or open an installed one's page in Settings → Extensions. Every install and update takes two: the first says what it is (and, if it gets more than a tab, what it asks for), `⏎` again does it. A held `⏎` never counts, and a row that needs something missing or broken ("Needs python3", "/usr/bin/python3 won't run") does nothing |
| `⌘⏎` | Open an installed one's page (when `⏎` is busy updating) |
| `/`, or just type | Search |
| `⌘R` | Reload the catalogue |
| `←` | Back to Settings |

To see another team's catalogue too, a private one included, add its repository under **Other catalogues**, the row below **Browse extensions**. Its rows in the browser show the repository's name. A private one is read with your GitHub sign-in, or the `gh` CLI's if you haven't signed in here. The page lists `StackOneHQ/stack-nudge-extensions-marketplace`, the app's own catalogue, first, which is always read, then each repository you added with when it last synced and how many extensions it lists, or why it couldn't be read and when it last could, plus how many updates it has for what you installed from it ("· 1 update"). Each says what it can grant: up to trusted for the catalogues the app names, view only for any other. The list is `STACKNUDGE_EXTENSIONS_SOURCES` in `~/.stack-nudge/config` (comma separated `owner/repo`), so an edit there shows up on the page and one made on the page is in the file. Every change syncs the catalogue again. Removing a repository keeps what you installed from it, but each of those drops to view on the next full sync. See [Other catalogues](extensions.md#other-catalogues) for what such a source may grant.

| Key | On Other catalogues |
|-----|--------|
| `↑ ↓` / `⌘↑ ⌘↓` | Select / first or last |
| `⏎`, `/`, or just type | Start adding a repository. In the field, `⏎` adds it, or says why it can't: it isn't `owner/repo`, it's the app's own, or it's already listed |
| `⌘⌫` | Remove the selected repository (not the app's own) |
| `⌘R` | Sync every catalogue now |
| `←` | Back to Settings |

### Away

Away is an extension that notices when you walk away from the Mac with your phone, so StackNudge can lock the screen. It's a convenience, not a security control: it recognises your phone only by the name it broadcasts over Bluetooth, so any nearby device using that name stops Away from locking it. Install it from **Settings → Extensions → Browse extensions**. It has no tab: open it from the list in **Settings → Extensions**, and its page's first line says what it hears (e.g. "Present · Alex's Pixel · −75 dBm · 3 s ago"). Pick your phone in **Phone**, which lists the devices paired with the Mac that Away can hear nearby, and optionally change **Idle for** (10 s to 2 min, default 30 s) and **Phone silent for** (90 s to 10 min, default 2 min). Nothing needs installing on the phone: Away listens for the Bluetooth LE signal a paired phone sends anyway, and shows it as a signal, not a connection. You count as away once nobody has touched the Mac for the Idle time *and* the phone has gone quiet for the Silent time. An idle phone lying on the desk was measured going 75 s between signals, with its signal strength dropping as low as it does when you leave, so only a long silence counts. Quiet means out of Bluetooth range altogether, which reaches through walls, so walking to another room on the same floor may not be far enough. Time the Mac spends asleep never counts as silence. If the phone isn't paired with the Mac, or two nearby devices share its name, the status line says so and Away won't lock until that's fixed. Typing always counts as being there, and you're back as soon as there's input or a strong signal again. If the phone goes quiet for good (left at home, switched off), the screen locks once, and not again until the phone is heard. Whether to lock is the app's setting, not the extension's: **Lock screen when away** on the page (`STACKNUDGE_AWAY_LOCK`, on by default) is StackNudge's own. macOS asks for Bluetooth permission for StackNudge itself the first time Away starts, because an extension's Bluetooth access is attributed to the app. Away is a small Swift program that compiles itself on first start, so it needs the Xcode Command Line Tools (`xcode-select --install`), which any Mac running a coding agent already has. Whether a phone advertises varies by model and settings, and a phone that advertises no name (often an iPhone) may not be listed, so check the Away page shows your phone with a signal before relying on it.

## Companion

The companion is a small animated character that floats on your desktop and takes the pill widget's place while it is on. New installs start with it; on an existing install you are offered it once after an update, or you can choose it in **Settings → Appearance → Floating widget**, which is `Pill`, `Companion` or `Off` (`STACKNUDGE_FLOATING_WIDGET`). The pill's own rows (corner, opacity, type, mascot, snap) apply only to `Pill`. A config from before that setting is migrated on first load: `STACKNUDGE_COMPANION=true` becomes `companion`, else the old `STACKNUDGE_COMPACT_MODE` (on unless `false`) becomes `pill`, else `off`. On the update screen, `Tab` / `⇧Tab` move between **Turn on** and **Got it** (focus starts on **Got it**) and `⏎` presses the one with the ring.

- **Click** the character to open the panel beside it. The hotkey opens it there too.
- **Drag** it anywhere; it stays where you drop it, and comes back on screen if a display it was on goes away.
- **Right-click** for the menu, including a **Companion** submenu with its size and **Reset position**, which puts it back where a fresh install starts it.

Its pose follows what stack-nudge knows: thinking while an agent is busy, watching while agent sessions are live, waiting when an event or a permission prompt is queued, alert when a quota is past your alert threshold, muted while notifications are muted, and asleep after five quiet minutes. The waiting pose is a wave: it means something wants you to act, and a finished agent turn is one of those, so it still waves. A new finished turn also gets a single small nod on arrival, when the character is otherwise calm (idle or asleep), not muted, and Reduce Motion is off. A count badge at its corner shows how many events are waiting, grey while muted. It animates on the render server and pauses while it is covered, the display sleeps or the screen is locked, so it stays near 0% CPU. With Reduce Motion on, it holds still.

| Setting | Key | Values |
|---------|-----|--------|
| Floating widget (Appearance) | `STACKNUDGE_FLOATING_WIDGET` | `pill`, `companion`, `off` |
| Size | `STACKNUDGE_COMPANION_SIZE` | `small`, `medium` (default), `large` |
| Count badge | `STACKNUDGE_COMPANION_BADGE` | `true` (default) / `false` |

The Companion category holds only the character's own settings. While Floating widget isn't `Companion` it shows a note and a **Turn on companion** row that switches it, and the settings are dimmed. `Space` or `⏎` flips Count badge, runs Reset position and Turn on companion, and on Floating widget, Size and Preview pose starts picking, as on every other row. Preview pose shows any pose on the character without changing anything else; it isn't saved. Holding `⌥` while the menu is open also reveals a **Debug** submenu under Companion with the same pose preview and an **Info (nod)** entry that plays the nod once. The character's last spot is kept in `STACKNUDGE_COMPANION_POS`.

## Menu bar (macOS)

When the panel daemon is running, the StackNudge mark appears in your menu bar, with a count of permission prompts still waiting on you (`2⏳`). The same items you can reach from the in-panel Settings tab are mirrored here for one-click access without summoning the panel:

| Item | What it does |
|------|--------------|
| `Hotkey · …` | Shows your current hotkey (info only) |
| `Show banners` | Toggles macOS banner notifications. Enabling fires a confirmation banner. |
| `Voice notifications` | Toggles spoken notifications. Enabling speaks *"Voice notifications enabled"*. |
| `Mute when focused` | Toggles skipping the banner when the agent's window is already in front |
| `Mute notifications ▸` | Submenu (For 15m / 30m / 1h / 2h) to silence all nudges for a set time. While muted a `Muted · Xm left` line shows above it, the item becomes `Resume notifications`, and the menu-bar icon shows a `bell.slash` + countdown. |
| `Companion ▸` | While the companion is on: size, Reset position, and (with `⌥` held) Debug |
| `Show panel` | Brings the floating panel up (handy when no events are queued) |
| `Settings…` (⌘,) | Opens the panel straight on Settings |
| `Check permissions…` | Opens the Permissions page in the panel (see [Permissions](setup.md#permissions-macos)) |
| `Open config file…` | Opens `~/.stack-nudge/config` in your default editor |
| `Quit StackNudge panel` (⌘Q) | Exits the daemon |

Menu changes take effect immediately for the next nudge — no daemon restart needed.
