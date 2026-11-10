# Service extensions

Status: **proposal**, for review before any code. The reference prototype is the
`feat/away-proximity` branch, a built-in version of the first service extension.

## Why

Extensions today ([docs/extensions.md](../extensions.md)) are **view
extensions**. The host runs `run`, reads one JSON document from stdout, and
renders it as a tab, plus the widget chip for one that opts into `glance`. That
model is deliberately small, and it rules out four things:

1. **Nothing can keep running.** Each refresh is a new process with 12 s and 8 MB
   of stdout, at most every 5 s. A Bluetooth scan, a socket, a file watcher or a
   model kept warm doesn't fit.
2. **Output is only a view.** An extension can't tell the app something it acts
   on, like "the user has left", "mute" or "hold permission prompts".
3. **No input from the app.** The environment is a minimal PATH, HOME, the
   extension's ID and schema, and its declared `STACKNUDGE_EXT_*` keys. It never
   hears about sessions, events or the panel.
4. **Permissions belong to the app.** A child process's TCC access is attributed
   to StackNudge, and usage strings live in the app's Info.plist. An extension
   can't bring its own.

The direction is a **thin core**: an agent stops or asks, and you get nudged.
Everything else (voice, token counting, insights, away detection) becomes an
extension with only the privileges it needs. That gives the internals boundaries
we can reason about and harden. It also lets us run a StackOne-internal
extensions repo and a public one with different trust.

A **service extension** is the missing piece: a long-running, supervised
process that exchanges events with the app.

## What doesn't change

- **Curated, not sandboxed.** Every extension runs as the user. Review is still
  the security control, so tiers decide what the *app* will do on an extension's
  behalf. They don't contain what the extension can do on its own.
- **Install checks.** Hash sidecars, archive inspection, and validating the
  manifest before anything moves into place (docs/extensions.md, "What
  installing checks") apply unchanged.
- **View extensions keep working as they are.** A service extension may also
  render a tab, through the same document schema.

## Manifest

Two new fields. Unknown fields are ignored today, so on their own an older host
would run a service extension as a view extension and wait for a document that
never comes. A service manifest therefore says `"schema": 2`. Older hosts check
`schema` for equality with 1 and refuse anything else with a reason, which is
what we want:

```json
{
  "id": "away",
  "schema": 2,
  "mode": "service",
  "capabilities": ["bluetooth", "signal:presence", "event:idle"],
  "run": "./run"
}
```

The other fields (`name`, `version`, `tab`, `requires`, `config`) are as today; `refresh` doesn't apply to a service.

What the bump touches:

- **The host** accepts manifest schema 1 and 2. A view extension keeps saying 1.
- **The index.** Entries gain `schema` and `mode`, so a new host can leave out
  what it can't run. Old hosts read the newest index (it's fetched from
  `/releases/latest`), so they will still list a service extension and refuse it
  only at install, at the manifest check. The reason is clear, but it's a wasted
  download, and we accept it.
- **`STACKNUDGE_EXT_SCHEMA`** stays the *document* schema. The manifest schema is
  never passed to the script, so a view extension isn't told "2" and doesn't
  print a schema 2 document.
- **`scripts/package-extensions.sh`** hard-codes schema 1 and needs to accept 2.

- `mode`: `"view"` (the default, today's behaviour) or `"service"`.
- `capabilities`: what the extension asks the app for. The app can only
  *enforce* what passes through it (signals, events, feed events), and it refuses
  those unless declared and granted. Hardware capabilities such as `bluetooth` are
  declarations for review and for the install prompt, not a gate: a child process
  inherits the app's TCC access whether it declared it or not (docs/extensions.md,
  Trust). See [Privilege tiers](#privilege-tiers).

## Lifecycle

The host owns the process; the extension never daemonises itself.

| When | The host |
|---|---|
| Extension enabled, or app launch with it enabled | starts `run` with the same minimal environment as today, plus `STACKNUDGE_EXT_MODE=service` |
| It exits or crashes | restarts it with backoff of 1 s, 2 s, 4 s … up to 5 min. After 5 crashes in 10 min, it is marked **broken** with its last exit status (or, when the host killed it, why: no `ready` in time, or no `pong`), shown in Settings → Extensions like a refusal |
| It goes silent | sends a `ping` every 30 s. No `pong` within 10 s counts as a hang: kill, then restart under the same backoff |
| Extension disabled, removed or updated, or the app quits | sends `{"type":"stop"}` on stdin, waits 3 s, then SIGTERM, then SIGKILL after 2 s more |
| The Mac sleeps | nothing special. The process is suspended with everything else, and the next missed `pong` after wake is tolerated once |

One process per extension, at most. The host keeps the process group, so
children die with it.

## Protocol

Newline-delimited JSON, one object per line, both ways. stderr is discarded, as
it is for view extensions today: the docs promise it's safe for debugging noise,
and scripts may print secrets there.

Every message has a `type`. The host's first message carries the protocol
version, and the extension's first message must answer it.

**App → extension (stdin)**

```json
{"type": "hello", "protocol": 1, "capabilities": ["bluetooth", "signal:presence", "event:idle"]}
{"type": "config", "values": {"STACKNUDGE_EXT_AWAY_WAIT": "30"}}
{"type": "event", "name": "idle", "seconds": 42}
{"type": "event", "name": "panel", "open": true}
{"type": "ping", "id": 17}
{"type": "stop"}
```

`capabilities` in `hello` is what was **granted**, which may be less than
declared. `config` can arrive again at any point while running, whenever the
user saves the extension's settings, so apply each one as it comes. Events are delivered only for granted `event:*` capabilities.

**Extension → app (stdout)**

```json
{"type": "ready", "protocol": 1}
{"type": "document", "document": { "schema": 1, "header": {}, "rows": [] }}
{"type": "signal", "name": "presence", "value": "away"}
{"type": "feed", "event": { "title": "Left the desk", "tag": "away", "severity": "info" }}
{"type": "pong", "id": 17}
{"type": "choices", "key": "STACKNUDGE_EXT_AWAY_PHONE", "options": [{"value": "Pixel", "label": "Pixel · −70 dBm"}]}
```

- `document` replaces the tab's document, with the same schema and caps as a view
  extension's stdout today (8 MB).
- `signal` sets a named value the app's features read. See [Signals](#signals).
- `feed` posts a feed event on the same path as the socket's
  `"source":"script"` events (#235), so it can never be a permission prompt. It
  gets its own source, `extension:<id>`, with its own cap of 20, so an extension
  can't push the user's own script events out of the queue.
- `choices` offers the values a `dynamic` config key may take right now, for its
  Settings picker (see [Where an extension appears](#where-an-extension-appears)).
  Kept only for a key the manifest declared as `dynamic`; at most 64 options,
  each storable in the config file. Additive: no protocol bump, since unknown
  types are already ignored.

Limits: a `document` line up to 8 MB, any other line up to 64 KB, and at most 20
messages a second on average. Past
either, the host drops messages and marks the extension degraded rather than
killing it. Unknown `type`s are ignored, so the protocol grows the same way the
document does: additive only, with a protocol bump for anything that restricts.

## Signals

A signal is how an extension changes what the app does, so each one is defined
by the app, not by the extension. The app owns the name, the allowed values and
what reacts. For the pilot there is one:

| Signal | Values | The app reacts by |
|---|---|---|
| `presence` | `present`, `away` | locking the screen if the user asked for it; later, holding permission prompts, muting voice, showing away in the exchange roster |

At most one extension may hold a given signal. The first to be granted it keeps
it, and the host records that, so it doesn't depend on launch order. A second
one asking is refused with the reason in Settings, where the user can switch the
signal to it. Disabling
or crashing the holder resets the signal to its neutral value (`present`), so a
dead extension can never leave the app locked or muted.

## Events

What the app tells service extensions, each behind an `event:*` capability:

| Event | Payload | Why |
|---|---|---|
| `idle` | seconds since the last input, every 2 s | so a script needn't call CoreGraphics. The app reads it with one `CGEventSource` call that needs no TCC grant (`IdleTime`, already on main), and a compiled extension can make the same call itself |
| `panel` | `open` | refresh what's on screen when it matters |
| `session` | session started, stopped or waiting, with agent and repo | token counting, insights |
| `nudge` | an agent nudge as delivered, without FIFO paths or PIDs | voice, Slack-style relays |

`nudge` carries prompt and tool text, the same content as the event log, so it
gets its own capability and its own line in the install prompt.

## Privilege tiers

Tiers decide which capabilities an extension may be **granted**. Its manifest
decides which it **asks for**.

| Tier | Who | May hold |
|---|---|---|
| **view** | any curated extension | today's view mode only |
| **service** | curated extensions flagged `service` in the index | service mode, `event:idle`, `event:panel`, `feed` |
| **trusted** | first-party extensions flagged `trusted` in the index | also `signal:*`, `event:session`, `event:nudge`, and hardware capabilities (`bluetooth`) |

The tier comes from the **index**, not the manifest, so an extension can't
promote itself. The host records the tier at install, in a host-owned file under
`~/.stack-nudge`. An extension runs as the user and could edit that file, so like
everything else here it relies on review, not containment. The file is new: there's no install record today, and the installed version is read from
the manifest itself. The host re-checks the tier on every index fetch: a
demotion revokes the capabilities at once and restarts the process with the
smaller grant. An extension on disk with no index entry, put there by hand, gets
`view`. Settings → Extensions shows each extension's tier and granted
capabilities. Installing one that asks for more than `view` lists what it asks
for and needs confirming.

Hardware capabilities need the app's Info.plist to carry the usage string, as
`NSBluetoothAlwaysUsageDescription` does on the prototype branch. We add those
one at a time, deliberately, and the app asks for the permission only when the
first extension holding that capability starts.

## The pilot: Away

The prototype's pieces map onto this design like this:

| Prototype (`feat/away-proximity`) | Service extension | Stays in the app |
|---|---|---|
| `ProximityMonitor` (CoreBluetooth scan, paired-device filter) | the extension's process | |
| `PresenceTracker` (the rule) | the extension | |
| `IdleTime.seconds()` (already on main) | the extension reads idle itself, or subscribes to `idle` | |
| `ScreenLock.lock()` | | the reaction to `presence: away` |
| Settings → Away rows (phone, wait, lock) | phone and wait as config keys | "Lock screen when away" as an app setting on the `presence` signal |
| `nav.isAway` | | set from the signal |

**In the host** (this PR), the app's half is built: it reacts to `presence` with
`ScreenLock` and `nav.isAway`, and its one setting, **Lock screen when away**
(`STACKNUDGE_AWAY_LOCK`, default on), is drawn on the page of whichever
extension holds presence (or on the Extensions list, should the holder have no
page). Saving an extension's settings sends a running service a `config`
message instead of restarting it. Tiers come from the index as described above:
`extensions/tiers.json` in the repository, folded into each index entry as
`"tier"`, recorded at install and re-checked whenever the catalogue loads, with
`STACKNUDGE_EXTENSIONS_LOCAL_TIERS=true` to turn the re-check off when testing
an extension no index lists yet. The Away extension itself is the pilot, in the
stacked PR.

**The open problem is the language.** The extension needs CoreBluetooth, which
means a small compiled Swift binary (or Python with PyObjC, which we don't
bundle). The view extensions so far are scripts. A compiled `run` is already
allowed ("anything that can print JSON"), but it changes what the reviewer reads
and what CI builds. Proposal: the source lives in the extension's directory, CI
builds and signs the binary into the release tarball, and the reviewer reads the
source.

## Migration

Each step is its own PR. Steps 3 and 4 move existing features, which must
work the same before and after. Step 2 ships Away for the first time, as an
installable extension:

1. **Service mode in the host**: lifecycle, protocol, tiers, Settings UI, with
   no extension using it yet. Tests drive a fake extension script.
2. **Away** as the first service extension, replacing the prototype branch.
3. **Voice.** The speech engine already runs out of process (`stackvox serve`,
   registered as a launchd agent and also started by `Speaker`). But the rest
   lives in the app: phrase pools, suppressing speech for the frontmost window,
   mute, the voice and speed settings, retries. Moving it means moving all of
   that behind `event:nudge`, not just who starts the engine.
4. **Token counting and insights**, behind `event:session`. The largest, since the
   Usage and Outcomes tabs read their state directly today.

"Core" afterwards: hooks and the socket, the event queue, banners, permission
prompts, the panel and widget shell, Settings, updates, and the extension host.

## UI

The new surfaces follow AGENTS.md's keyboard rules like any other page:

- **Settings → Extensions** gains each extension's tier, its granted
  capabilities, the broken state, and which signal it holds.
- **The install confirmation** for anything above `view` lists what it asks for.

That means key routing in a pure, tested function, footers that list only live
keys, and the README key tables updated in the same change.

## Where an extension appears

**Built** in this PR; Away, the pilot in the stacked PR, is its first user.
Before it, every extension got a tab. That suits
one you look at, but Away is set and forget, and a tab would take one of the
nine `⌘1`…`⌘9` slots for a page nobody opens. So the author chooses, with a
manifest field:

```json
{ "surfaces": ["settings"] }
```

- `["tab"]` is the default and today's behaviour. `["settings"]` means no tab.
  As built, the page isn't a sidebar item: every installed extension has one,
  a level below **Settings → Extensions**, whose list shows each extension's
  description and status.
- **The Settings page** shows the extension's config as typed controls: a
  number with a range, a toggle, a fixed set of choices, or choices the running
  service supplies (Away offering the paired phones nearby). Under them, a
  read-only status taken from its document.
- It follows AGENTS.md like the built-in Settings categories: the same keys,
  footers and pure key-routing function.
- As built: the Extensions list opens each page with `→` / `⏎`, `←` goes back,
  and the page holds the status, the settings, the app's lock row for the
  presence holder, what it was allowed in plain words, where it appears, and
  Update and Remove (`⌘⌫`). It replaced the old per-extension config page. The
  browser asks before every install and update, and lists what one above `view`
  asks for, from the index entry's `mode` and `capabilities`; installing
  refuses a package whose manifest differs from that entry. Config keys gain an
  optional `type` (`text`, `toggle`,
  `choice`, `number` with an optional `unit: "seconds"`, `dynamic`), checked at
  parse time and again on save. The status is a readout above the rows rather
  than a selectable row, like About's version. A picker writes only when it
  settles, so a service hears one `config` per change. The page of whichever
  extension holds `presence` also carries the app's own "Lock screen when away"
  row. docs/extensions.md has the details.
- **Any tier** may use it, since it grants nothing.
- **Older hosts** ignore the unknown field and show a tab, which still works.

## Open questions

- **Signing the index.** Today the index is trusted because it's attached to the
  app's own release over HTTPS, and each payload is checked against its sha256.
  Tiers make the index more powerful, so should we sign it (e.g. with the
  release's Developer ID) before `trusted` exists?
- **Battery.** Any persistent process costs power. Do we want a per-extension
  energy note in Settings, or a host-wide "pause service extensions on battery"?
- **Two repos.** An internal StackOne repo and a public one: is the tier
  per-repo (internal = trusted) or per-extension within each index?
- **Compiled extensions.** See the pilot. Swift is fine for first-party, but do
  we allow compiled binaries from the public repo at all?
- **Prompt and tool text.** Is `event:nudge` too much to hand any extension, even
  a trusted one, or should voice stay in core?
