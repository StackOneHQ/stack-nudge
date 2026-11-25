# A local MCP server

Status: phases 1 to 3 are built: the bridge, the server on its own socket, the
settings registry, every tool below, the resources with their update
notifications, the write switch, the audit lines, and the app's events over
push and poll. Extension contributions (phase 4) are marked *not yet
delivered*. Each phase is its own PR, and this doc is updated as they land, the
way [service-extensions.md](service-extensions.md) was.

## Why

Coding agents and chat apps can't tell stack-nudge anything except through the
hooks we install, and those only cover the agents we wrote hooks for, at the
moments those hooks fire. stack-nudge can't be asked anything either: its
settings live in a panel and a config file, and an agent that wants to change
one has to edit `~/.stack-nudge/config` by hand.

An MCP server inside stack-nudge fixes both, with one surface every agent
already speaks:

1. **Any client can raise a nudge.** Claude Code, Codex, Claude Desktop and the
   web apps call a tool to say "done", "waiting on you" or "look at this", and
   it lands in Events like a hook's would. Acting on it takes you back to where
   it came from: the terminal tab, the app, or the conversation's page.
2. **Settings are readable and writable by agents.** "Turn voice off for the
   rest of the day", "mute this repo", "switch me to nightly" become tool calls,
   which is the main use so far.
3. **What stack-nudge knows is subscribable.** A session waiting on you, a
   session stalling, a quota crossing its threshold, a setting changing, and
   whatever extensions add, as MCP events.

It also replaces the CLI and command channel proposed in #274, which covered a
subset of the same ground over a bespoke protocol.

## What the spec gives us

The current revision is
[2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/changelog).
It drops the `initialize` session handshake for `server/discover` plus
per-request `_meta`, and replaces `resources/subscribe` with one long-lived
[`subscriptions/listen`](https://modelcontextprotocol.io/specification/2026-07-28/basic/patterns/subscriptions.md)
request whose filter asks for `toolsListChanged`, `resourcesListChanged` and
`resourceSubscriptions`. The server acknowledges with
`notifications/subscriptions/acknowledged` and tags every notification with
`_meta["io.modelcontextprotocol/subscriptionId"]`.

[Events](https://modelcontextprotocol.io/extensions/events/overview)
(`io.modelcontextprotocol/events`, [SEP-3415](https://modelcontextprotocol.io/seps/3415-events-extension),
spec in [ext-events](https://github.com/modelcontextprotocol/ext-events)) is an
official extension, Beta. A server lists event types with `events/list`
(`name`, `inputSchema`, `payloadSchema`, `delivery`), and each occurrence is
`{eventId, name, timestamp, data, cursor}`. Of its three delivery modes we use
two:

- **push**, `events/stream`: one long-lived request per subscription,
  confirmed by `notifications/events/active`, then `notifications/events/event`,
  `heartbeat`, `error` and finally `terminated`. Made for local stdio servers.
- **poll**, `events/poll`: no server state, for clients that can't hold a
  stream.

Webhook delivery needs an authenticated principal and an `https` callback, so it
only comes in with the relay (below).

Client support is thin today. The
[extension matrix](https://modelcontextprotocol.io/extensions/client-matrix)
lists Events in no client we care about except ChatGPT, and there webhook only.
Tools and resources work in all of them now, so every feature here has a
tools-first path, and events are built to the spec so they light up as clients
adopt it.

The official Swift SDK doesn't claim 2026-07-28. We write the JSON-RPC layer
ourselves: stack-nudge already speaks JSON-RPC to `codex app-server`, the
surface is small, and it keeps the app free of a dependency we'd have to track.

## Transport: a stdio bridge to the running app

MCP clients launch local servers as child processes over stdio. Ours is the app
binary in a bridge mode:

```
claude mcp add stack-nudge -- ~/Applications/StackNudge.app/Contents/MacOS/stack-nudge --mcp
```

The bridge does no MCP itself. It connects to the running app over
`~/.stack-nudge/mcp.sock` (user-only, 0600, beside the hooks' `panel.sock`),
sends a hello naming who launched it (below), then copies JSON-RPC lines both
ways until either side closes. Everything else lives in the app, once: one
settings model, one event store, one place to audit.

The socket is separate from `panel.sock` because that one reads each
connection to its end, one at a time, and a bridge holds its connection open
for as long as its client runs. Each MCP connection gets its own reader and a
writer queue with a cap, so a client that stops reading is dropped rather than
blocking the main thread that sends it change notifications.

- **No port.** Nothing listens on TCP, so there's no DNS rebinding, Origin check
  or bearer token to get right. The trust boundary is the one the hook socket
  has today: processes running as you.
- **The app isn't running.** The bridge answers `server/discover` and
  `initialize` itself with no tools and an `instructions` string saying
  stack-nudge isn't running, rather than failing the client's startup. It
  doesn't launch the app.
- **Both protocol revisions.** Claude Code, Codex and Claude Desktop still speak
  2025-11-25 with `initialize`, so the server answers both that and
  `server/discover`, and both `resources/subscribe` and `subscriptions/listen`.
  It drops the older revision once the clients have.

### Knowing who's calling

A nudge is only useful if acting on it takes you back, so every bridge
connection opens with what it can learn about its client. The model can't
supply this: it doesn't know its own conversation or session ID, and Claude
Code puts only a per-call `claudecode/toolUseId` in `_meta`
([anthropics/claude-code#41836](https://github.com/anthropics/claude-code/issues/41836)).

| Client | What the bridge learns | Where acting on a nudge takes you |
|---|---|---|
| Claude Code | `CLAUDE_CODE_SESSION_ID` in its environment (checked: Claude Code sets it for the processes it starts), and its parent's PID | the session's terminal tab, through the same session match and focus the hooks use |
| Codex | its parent PID, the `codex` process | the session's terminal tab, matched by PID as SessionStore does today |
| Claude Desktop | its parent is Claude.app | Claude Desktop, brought forward. Not the conversation: Desktop passes nothing that names it |
| claude.ai, ChatGPT | through the relay, the connector's identity | the site. A conversation link only when the tool call carries one |

`clientInfo` from the handshake names the client for the feed row ("Claude
Code · Done"). The `notify` tool also takes an optional `url`: an `https` link
a client that knows where it is can pass, which wins over the table. Only
`https` is accepted, as on the socket today (`EventStore.webURL`).

## What the server exposes

### Tools

| Tool | Does |
|---|---|
| `notify` | raises a nudge: `title`, `message`, `kind` (`done`, `waiting`, `info`), optional `url` and `tag`. It lands as a feed event with source `mcp:<client>`, so it can never be a permission prompt and has its own cap in the queue, like extension feed events |
| `settings_list` | every setting: key, label, category, type, allowed values, current value, whether MCP may write it |
| `settings_get` | one setting's current value |
| `settings_set` | changes one, through the same code the Settings row runs, so side effects happen (launch at login, event history, re-checking the update channel) |
| `sessions_list` | the sessions stack-nudge sees, what each is doing and whether it's waiting on you. Replaces #274's `busy` |
| `mute` | mutes for a duration, or until resumed. Separate from `settings_set` because it's timed and app state, not config |

### Resources

- `stacknudge://settings` and `stacknudge://settings/<category>`: the same data
  as `settings_list`, subscribable. Any change, from Settings, the config file
  or a tool, sends `notifications/resources/updated`.
- `stacknudge://sessions`: as `sessions_list`, updated as sessions change.

### Events

Advertised under `io.modelcontextprotocol/events` with `listChanged: true`,
since extensions add and remove types.

| Event | Payload | Fires when |
|---|---|---|
| `session.waiting` | agent, repo, session id, since | an agent blocks on you: a permission prompt or a question |
| `session.stopped` | agent, repo, session id | a turn finishes |
| `session.stalled` | agent, repo, session id, quiet for | the stalled-session rule fires |
| `nudge.raised` | source, client, title, url | anything lands in Events, including another client's `notify` |
| `quota.threshold` | client, window, utilization | a quota crosses the alert threshold |
| `settings.changed` | key, old value, new value, who changed it | a setting changes |
| `<extension>.<name>` | the extension's schema | an extension emits it (below) |

Payloads are minimal: no prompt text, tool input or message bodies, by default.
`session.waiting` with the prompt's text needs its own opt-in, like
`event:nudge` does for extensions. The spec's security model says payloads are
untrusted input to a model, and a permission prompt's text is exactly what
prompt injection would aim for.

Cursors are positions in a ring of the last 500 occurrences, stamped with an
epoch that changes every launch, so a client that reconnects gets what it
missed while it's still in the ring. A cursor from before a relaunch, older
than the ring, or behind the client's `maxAgeMs` floor comes back as a gap
(`truncated: true` and a fresh cursor), never an error. The ring is in memory on
purpose: replaying events from before a relaunch would replay prompts long since
answered. Push streams are confirmed with `notifications/events/active`, carry a
heartbeat with the current cursor every interval that passes in silence
(30 seconds unless the client asks, between 5 seconds and 5 minutes), and end
when the client cancels.

A change from an MCP client is credited to it in `settings.changed`'s `by`;
anything else (Settings, the config file) is credited to `stack-nudge`.

## Writes

Settings writes are the main use, so v1 has them. One switch governs them,
Settings → Actions → **MCP clients can change settings** (`STACKNUDGE_MCP_WRITES`),
on by default. It is a client-side opt-in already: nothing reaches stack-nudge
until you add the server, and **Copy MCP setup for Claude Code** on the same
page copies the line that does it, pointing at the installed app.

Any process running as you could already change these by editing the config
file, so writes aren't a new privilege. What's new is an agent doing it in one
tool call, possibly steered by injected text. So:

- **Never writable by MCP:** anything that stops a permission prompt reaching
  you (banners for prompts, the reminder rule, Focus holding prompts), hooks
  and agent wiring, installing or removing extensions, uninstall, and the MCP
  switch itself. These are refused with a reason naming Settings as the place
  to change them.
- **Secrets are never readable:** the Slack and GitHub tokens live in the
  Keychain and aren't settings. Identifiers that behave like secrets (the Slack
  member ID) are listed as set or unset only.
- **Every write is visible.** It posts a feed event, "Claude Code set Voice to
  Off", so a change you didn't ask for shows up where you'll see it, and
  `settings.changed` carries who made it.
- **Mute is bounded and leaves prompts alone.** A mute from the panel silences
  every banner, permission prompts included (docs/notifications.md). One from
  `mute` lasts at most a day and doesn't: an agent that could silence its own
  prompts could hide what it's asking for, which is the hole #274's Focus mute
  had.

The settings model behind this is new. Today each setting is a hand-written
case in PanelNav. Phase 1 adds a registry: one entry per `STACKNUDGE_*` key with
its type, allowed values, label, category and whether MCP may read or write it.
The Settings rows keep their own drawing and keys, but read and write through
the registry, so the panel and MCP can't drift apart.

## Extensions

Both directions, built on what service extensions already have.

**Contributing to the server.** A service extension's manifest gains an `mcp`
block declaring the tools, resources and event types it offers, each named
under its ID (`pylon.sla_breach`). The NDJSON protocol gains `mcp.call` and
`mcp.result` for tool calls, `mcp.event` to emit an occurrence and
`mcp.resource.updated`. The host checks every call's arguments and every
event's payload against the declared schemas before passing them on.
Installing, removing, updating or a crash sends `tools/list_changed` and
`events/list_changed`. Contributing needs a new capability, `mcp`, granted at
service tier and above and listed in the install prompt like the others.

**Consuming events.** An extension that wants to react to a nudge from Claude
Desktop or a setting changing doesn't speak MCP. It gets them on the event path
it already has, behind `event:*` capabilities: `event:nudge` (already designed)
and a new `event:settings`. That's the straight path, and it keeps extensions
out of the MCP client business.

Extension output reaches a model marked with where it came from, and payloads
are treated like tool results, per the spec's security model.

## The web apps: a relay

claude.ai and ChatGPT connect to MCP servers from their own cloud, so they need
a server on the public internet
([Claude's connector docs](https://claude.com/docs/connectors/custom/remote-mcp)).
That's a relay we host: a remote MCP endpoint with OAuth per user, and the app
holding an outbound connection to it, so nothing on your Mac listens.

The relay is emit-only at first: `notify` and nothing else. A cloud endpoint
that can change settings on your Mac is a bigger trust question than a local
socket, and the web apps' main need is telling you a long task finished. It's
the last phase, and gets its own design once the local server has settled.

## Replacing #274's CLI

#274 adds a `stack-nudge` shell CLI and a command channel on the socket:
`say`, `state`, `focus`, `settings`, `poll`, `busy` and `ping`. The MCP server
covers all of it for agents, through tools they already know how to call:

| #274 | Here |
|---|---|
| `say` | `notify` |
| `settings` | `settings_list`, `settings_get`, `settings_set` |
| `busy` | `sessions_list`, `stacknudge://sessions` |
| `focus` | a setting, `focus_mute`, except that Focus never holds permission prompts |
| `state`, `poll` | dropped: nothing backed them in #274 either |
| `ping` | the handshake |

Scripts outside an agent can still use the socket's event format, as they do
today. If a human-facing CLI turns out to be needed, it becomes a thin MCP
client over the same bridge rather than a second protocol. #274's Focus summary
and per-tag quiet list carry over as settings.

## Security, in one place

- Local only: stdio plus a 0600 socket, no port. The relay is separate,
  emit-only, and comes last.
- Read and write as you, which is what the config file allows already, plus a
  denylist for what protects permission prompts, a visible feed event for every
  write, and no secrets.
- Nudges from MCP are feed events with their own source and cap: never a
  permission prompt, never able to push the user's own events out of the queue.
- Only `https` links are opened.
- Payloads are minimal and treated as untrusted. Prompt text needs its own
  opt-in.

## Phases

1. **Read.** The settings registry, the bridge, the app-side JSON-RPC server for
   both revisions, `settings_list` and `settings_get`, `sessions_list`, the
   resources and their update notifications. Tested with MCP Inspector and
   golden JSON-RPC transcripts.
2. **Write and notify.** `settings_set` and `mute` with the switch, denylist and
   audit events, `notify` with the client-identity table, and Settings → Actions
   showing the `claude mcp add` line to copy. #274's CLI is closed in favour of
   this.
3. **Events.** The app's event types over `events/stream` and `events/poll`,
   cursors from the event log, `subscriptions/listen` for the list changes.
4. **Extensions.** The manifest `mcp` block, the NDJSON messages, schema
   checks, the `mcp` capability and tier gating, and `event:settings` for
   consuming.
5. **The relay** for claude.ai and ChatGPT, emit-only, in its own design.

## Open questions

- **Codex's session.** Codex may pass a session ID to MCP children as Claude
  Code does. Until that's checked, Codex nudges match by PID.
- **Claude Desktop conversations.** Desktop passes nothing naming the
  conversation, so its nudges bring the app forward but can't open the chat. A
  `_meta` key from Desktop would fix it; worth asking for.
- **One server per client.** Each client launches its own bridge, so three
  clients mean three connections to the app. That's fine for a socket, but the
  event store has to fan out per subscription, not per client.
