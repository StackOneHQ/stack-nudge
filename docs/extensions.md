# Writing a stack-nudge extension

An extension is a directory containing a manifest and an executable. stack-nudge
runs the executable, reads one JSON document from its stdout, and renders that
document as a tab.

There is no API to link against and no native code. Anything that can print JSON
works — a shell script, a Python file, a compiled binary.

```
~/.stack-nudge/extensions/derby/
    manifest.json
    run              # executable, any shebang
```

Extensions are **curated, not sandboxed**. The script runs as you, with your
permissions. Nothing installs that did not come through a reviewed pull request
into this repository — that review is the security control, so an extension is
read as code, not as content. See [Trust](#trust) below for what that does and
does not buy.

---

## The manifest

```json
{
  "id": "derby",
  "name": "Token Derby",
  "version": "1.2.0",
  "schema": 1,
  "tab": { "label": "Derby" },
  "run": "./run",
  "requires": ["python3"],
  "config": ["STACKNUDGE_EXT_DERBY_ORG"],
  "refresh": { "onOpen": true, "intervalSeconds": 30, "whileFocusedOnly": true }
}
```

| Field | Required | Notes |
|---|---|---|
| `id` | yes | `^[a-z0-9][a-z0-9-]{0,31}$`, and **must equal the directory name**. It becomes a path component, so it is validated before it is ever used as one. |
| `name` | yes | Human-readable. Used as the tab label when `tab.label` is absent. |
| `version` | yes | Yours to manage; the host only records it. |
| `schema` | yes | `1`. (`2` is also read, for service mode below.) Anything else is refused outright — see [Versioning](#versioning). |
| `tab.label` | no | Defaults to `name`. Trimmed, capped at 16 characters, falls back to `id` if empty. |
| `run` | no | Defaults to `./run`. Relative to the extension directory, no `..`, no absolute or `~` paths. |
| `requires` | no | Interpreters the extension needs. Checked at install time by **running** each one, not by resolving it. |
| `config` | no | Environment keys to pass through. Each must match `^STACKNUDGE_EXT_[A-Z0-9_]+$`. See [Configuration](#configuration). |
| `refresh.onOpen` | no | Default `true`. Fetch when the tab is opened. |
| `refresh.intervalSeconds` | no | Default off. Floored at 5 — every tick is a process spawn. |
| `refresh.whileFocusedOnly` | no | Default `true`. Only poll while your tab is the one on screen. Set `false` to keep polling while the tab is hidden; such an extension is also first run on the first tick after launch, without waiting for its tab to be opened. |
| `glance` | no | Default `false`. Let the widget show your header badge while it is urgent. See [The widget](#the-widget). |
| `surfaces` | no | Default `["tab"]`. `["settings"]` means no tab, only its page under Settings → Extensions. See [Where it appears](#where-it-appears). |

A manifest that fails any of these is **refused**, and the reason is reported —
it does not silently produce a missing tab.

> **Service mode.** A manifest with `"schema": 2` may also declare
> `"mode": "service"` and a `capabilities` list, which makes `run` a
> long-running process the host supervises and talks to over stdin and stdout,
> instead of a one-shot script. What it may be granted depends on its
> [tier](#tiers), and the protocol is in
> [docs/design/service-extensions.md](design/service-extensions.md). A view
> extension can ignore all of this and keep saying `"schema": 1`.

## Configuration

A `config` entry may be a bare key name, or an object describing it:

```json
"config": [
  "STACKNUDGE_EXT_DERBY_TRACE",
  {
    "key": "STACKNUDGE_EXT_DERBY_ORG",
    "label": "Organisation",
    "help": "Whose races to show. Ask whoever runs your league.",
    "placeholder": "stackone"
  }
]
```

Both forms declare the same thing — a key the host will pass to your script.
The object form adds what your page under **Settings → Extensions** needs to
render a labelled row for it rather than a raw environment variable name.
Without a `label` the field is titled by the key with its namespace stripped,
so a bare string still gets a usable form.

One list rather than two: a parallel array describing the keys would drift from
the list of keys actually passed, and what you would get is a form field for a
key nobody reads, or a key nobody can set.

A key must match `^STACKNUDGE_EXT_[A-Z0-9_]+$` — the whole name, not just the
prefix. Keys are written into `~/.stack-nudge/config` as `KEY=value` lines, so
a key is text that lands in a file: one containing a newline would write a
second, unrelated assignment, and one containing `=` would be read as setting
something else.

Values are stored in that same file, so the form refuses a value containing a
line break. A value naming a
URL scheme must name `https`. Clearing a field removes the key rather than
writing an empty one, which matters because a declared-but-unset key is
**omitted** from your environment rather than passed empty — so `[ -z "$KEY" ]`
and "the variable isn't there" are the same case, and you only have to handle
one of them.

### Typed keys

The object form may also say what kind of value a key holds, with `type`. Every
installed extension has a [page under Settings → Extensions](#where-it-appears),
and each type is drawn there as the matching control.

| `type` | Holds | Settings draws |
|---|---|---|
| `text` (default) | anything the config file can hold, as today | a row whose `⏎` turns it into a field: `⏎` saves, `Esc` (or `⌫` when empty) puts it back |
| `toggle` | `"true"` or `"false"` | an on/off row: `Space` or `⏎` flips it |
| `choice` | one of `options: [{"value": "…", "label": "…"}]` | a picker |
| `number` | one of `options: [15, 30, 60]`, with an optional `"unit": "seconds"` | a picker, labelled "15 s", "2 min" with the unit |
| `dynamic` | one of the values your running service offers (a `choices` message, below) | a picker over what you last offered, plus the saved value |

An optional `default` (`30`, `true`, or a string) is what the row shows while
the key is unset; your extension still decides what an unset key means.
Without one, a picker's first entry is "Default" (or "Not set" for `dynamic`),
which removes the key. A picker writes nothing while you step through it, only
when it settles, so your extension hears one change. Option values must be
storable as one line of the config file, exactly as given: no CR or LF anywhere
(not even at the ends, where a trim might otherwise hide one), no other line or
paragraph separator (NEL, U+2028, U+2029, vertical tab, form feed), no NUL or
other control character, no surrounding spaces, and at most 256 characters,
with at most 64 options. The same rule is applied to a manifest's options, to a
`choices` message, when a value is saved, and by the config writer itself. An unknown `type` or `unit`, missing or repeated options, or a
`default` that isn't one of the options is refused with the key named.

`dynamic` is for a service extension: it sends what may be picked as

```json
{"type": "choices", "key": "STACKNUDGE_EXT_AWAY_PHONE",
 "options": [{"value": "Alex's Pixel", "label": "Alex's Pixel · −70 dBm"}]}
```

whenever the list changes. The host keeps it only for a key the manifest
declared as `dynamic`, refuses the whole message for more than 64 options or
for any value or label that breaks the rule above (so leave out an entry you
can't tidy rather than sending it), and keeps the last list while the process restarts. The saved
value is always shown, even when it isn't on offer right now. Older hosts
ignore the message, like any type they don't know.

The object form is a **manifest** field, not an index field. The published
`extensions-index.json` carries key *names* only, whichever form the manifest
used — deliberately, because the index is a wire format read by binaries of
every version: the app fetches it from `/releases/latest`, so an old host reads
the *newest* index. Your page never needs the metadata there, since it
renders for an extension that is already installed and reads that extension's
own manifest.

## The environment

Your script gets exactly this, and nothing else:

```
PATH                    a minimal system PATH
HOME
STACKNUDGE_EXT_ID       your id
STACKNUDGE_EXT_SCHEMA   the document schema this host speaks
                        + any STACKNUDGE_EXT_* keys you declared in `config`
```

The environment **replaces** the app's rather than extending it, so you cannot
depend on something you did not declare and then break when the app is launched
from launchd. A declared key that is unset is omitted rather than passed empty.

`STACKNUDGE_EXT_` is the whole namespace you may name. The app's own settings live
under `STACKNUDGE_` and include secrets — a bare prefix was not a filter, so a
separate namespace makes them unnameable rather than merely discouraged.

Your working directory is your own extension directory. stdout is the document;
**stderr is discarded**, so it is safe to use for your own debugging noise.

Budget: **12 seconds** per invocation, and at most **8 MB** of stdout. Output past
the ceiling is read and discarded, and the result is marked incomplete.

## The view document

One JSON object on stdout. Every field except `schema` is optional.

```json
{
  "schema": 1,
  "state": "ok",
  "header": {
    "title": "StackOne Token League",
    "badge": { "text": "LIVE", "tone": "success" },
    "trailing": "5h44m"
  },
  "rows": [
    {
      "id": "h1",
      "lead": "1",
      "title": "black & white",
      "subtitle": "Yashika",
      "value": "14.5M",
      "footnote": "36K/15m · Premier Division",
      "track": { "fill": 0.52, "ghost": 0.60, "tint": "#7FD1B9" },
      "ornament": {
        "kind": "sprite", "fps": 7, "anchor": "fill-edge",
        "palette": { "H": "#FFFFFF", "M": "#202020" },
        "frames": [["...HHHH.", "..MHHHHH"], ["...HHHH.", "..MHHHHH"]]
      },
      "actions": [{ "id": "open", "label": "Open", "key": "return" }]
    }
  ],
  "actions": [{ "id": "refresh", "label": "Sync now", "key": "r" }]
}
```

### The primitives are deliberately generic

The host renders these without knowing what any of them mean. **"A grid of
coloured cells" is a primitive; "a horse" is not** — which is what lets a
pixel-art sprite survive the process boundary without the host knowing anything
about racing.

### `state`

`ok` | `empty` | `error`, with an optional `message`. This is how you report your
own failures rather than having the host guess.

An `empty` or `error` document shows its message instead of the list. `ok` with no
rows shows a placeholder too, so you do not have to get the distinction right to
avoid a blank pane.

> **Known limitation:** `error` and `empty` currently *replace* the list, so
> "degraded, but here is what I got" is not yet expressible. Send `ok` with a
> `header.badge` if you want to show partial data with a warning.

### `header`

`title` is required if you send a header at all; `badge.tone` is one of
`neutral` (default), `success`, `warning`, `danger`; `trailing` is rendered
monospaced and is a good place for a countdown.

#### The widget

With `"glance": true` in your manifest, the widget shows your header badge —
your tab label, the badge text and `trailing` — as a small chip while the
badge's tone is `warning` or `danger`, and nothing otherwise. Clicking it opens
your tab without leaving widget mode. There is room for one chip: the most
severe wins, first in tab order among equals, and a `+N` counts the rest.

It is the same badge your tab shows, so there is nothing new to send, but keep
it short. The pill is narrow and its session headline comes first: when the
chip doesn't fit it drops your label, then `trailing`, then the badge text,
leaving a dot in the badge's colour. The tooltip always has all of it.

A glance only stays current while you are polled, so it pairs with
`whileFocusedOnly: false`. If two of your intervals pass without a successful
refresh, whether your script is failing or nothing is polling it, the chip dims
and drops `trailing`: a countdown that has stopped is wrong. Hosts that predate
the field ignore it.

### `rows`

`id` and `title` are required — one addresses the row, the other is the only thing
guaranteed to be drawn. Everything else degrades.

Row ids must be unique; duplicates are dropped. A row missing `id` or `title` is
dropped **on its own**, without costing the rest of the list.

### `track`

A bar, with an optional paler bar behind it.

- `fill` — 0…1, clamped.
- `ghost` — 0…1, drawn behind `fill`. Useful for "expected by now" against
  "actual", which is where it came from.
- `tint` — `#RGB` or `#RRGGBB`. Anything else falls back to the accent colour.

Tints are **clamped toward legibility** against the viewer's current appearance,
so a `#FFFFFF` bar is not invisible in light mode. Hue is preserved.

### `ornament`

An animated pixel grid, drawn on the row's track band. A row may carry several —
send `ornaments` as a list instead, or alongside `ornament`, which reads first.
Up to 4; they draw in the order written, so the last one is on top.

Two are what a race needs: a still chequered post anchored `trailing`, which
stays at the end of the track, and the runner anchored `fill-edge`, which rides
the head of the fill. One `ornament` could only ever be one of them.


- `kind` — only `"sprite"` today. An unknown kind is dropped rather than guessed at.
- `fps` — `0` or absent means a still image. Capped at 30.
- `anchor` — `fill-edge` (default, rides the head of the fill), `leading`, `trailing`.
- `palette` — single-character key → colour. `.` is always transparent.
- `frames` — array of frames; each frame is an array of row strings.

Caps: 32 frames, 24 rows, 64 columns. Ragged frames are fine — the sprite is sized
from the largest across all frames so it does not resize mid-animation.

### `actions`

Document-level actions apply to the whole pane; row-level actions apply to their
row, and take precedence when that row is selected.

When an action fires, your script is run again with arguments:

```
run --action refresh
run --action open --row h1
```

Print a fresh document in response. **Your script stays stateless between
invocations** — anything you need to remember, store it yourself under your own
directory.

Only one invocation runs at a time per extension; presses while one is in flight
are ignored rather than queued.

#### Key bindings are requested, not granted

`key` may be a single ASCII letter or digit, or `"return"`. Everything else is
ignored — `Esc`, the arrow keys and every `⌘` combination belong to the panel.

> **Known limitation:** the pane is keyboard-driven and renders no action buttons,
> so an action whose key was refused (or that has no `key` at all) is currently
> unreachable. Give every action a valid `key` until that changes.

## Failures

The host distinguishes three, because they mean different things:

| | When | What the user sees |
|---|---|---|
| **missing** | script gone or not executable | a broken installation |
| **transient** | timeout, non-zero exit, killed by a signal, output cut off | the last good document, marked as older |
| **malformed** | output did not parse | your bug, surfaced as yours |

A non-zero exit is transient **even when stdout parsed**, because a script that
failed halfway may have printed a partial document.

## Versioning

The host refuses any `schema` it does not speak, rather than guessing. A refused
extension is listed in **Settings → Extensions** with the reason, so
"needs manifest schema 3; this version reads up to 2" reaches the person who can act on
it rather than only the log. Read
`STACKNUDGE_EXT_SCHEMA` to find out what this host can read before you print.

**Additive fields are the only compatible change.** Unknown fields are ignored, so
a new field is invisible to an older host — which also means a field that
*restricts* behaviour cannot be added safely without a schema bump.

## Publishing one

Extensions live in `extensions/<id>/` in this repository. Open a PR; CI validates
it on every push, and the release workflow packages whatever is on `main` when a
version ships.

```
extensions/
    derby/
        manifest.json
        run
        test_derby.py
    system/
        manifest.json
        run
```

Tests are optional but encouraged, and they ship inside the package on purpose:
`derby` is what somebody reads when writing their own, and "how do I test one of
these?" is a question the reference should answer. Any `extensions/*/test_*.py`
is run by CI and by `make test-extensions`; a suite that discovers zero tests is
a failure rather than a pass.

`scripts/package-extensions.sh validate` is what CI runs, and you can run it
yourself. It refuses:

- a manifest that doesn't parse, or whose `id` disagrees with the directory name
- an `id` outside `^[a-z0-9][a-z0-9-]{0,31}$`, or a `schema` that isn't 1 or 2
  (and `"mode": "service"` on anything but 2)
- a `run` path that is absolute or contains `..`
- a `run` file that is missing, not a regular file, or not executable
- **any symlink or non-regular file anywhere in the package**

That last one is not redundant with the `run` checks, and it is the reason the
whole script exists. An extension declaring `"run": "vendor/tool"` where `vendor`
is a symlink to `/usr/bin` passes every check on the run path itself — the file
exists, is regular, is executable, and is not itself a symlink, because its
*parent* is. Only walking the tree catches it, and that is exactly the manifest a
reviewer would read as in-package.

Your `run` script is also linted. CI runs shellcheck across the repository and
picks up extensionless files by shebang, at `severity: warning`.

### What a release publishes

```
extension-derby-1.0.0.tar.gz
extension-derby-1.0.0.tar.gz.sha256      <- "<hash>  <basename>"
extension-system-1.1.1.tar.gz
extension-system-1.1.1.tar.gz.sha256
extensions-index.json
```

The `extension-` prefix is not decoration. Extensions share a release with the
app, and the updater picks its own download by name — without the namespace an
extension called `stack-nudge` would be offered to the updater as an app build.

Each index entry carries what the browser needs before anything is downloaded:
the id, name, version, description, asset and its sha256, `requires`, config
key names, the reviewed `tier`, and the manifest's `capabilities`, so the
install confirmation can say what this extension asks for. The last two are
additive, and older hosts ignore them; a host reading an index without
`capabilities` says only that the extension gets more access than a tab.

The index is attached to the app's own release, so there is one trust anchor and
one fetch path. It ships even when there are no extensions, so the app always has
something well-formed to fetch.

### Tiers

A tier is how far the app trusts an extension: `view`, `service` or `trusted`.
The manifest says what an extension asks for; the tier says what it can have.
A service extension needs at least `service`, and `trusted` adds signals and
hardware capabilities such as `bluetooth`. The full table is in the design
note, under "Privilege tiers".

The tier is the reviewers' call, not the extension's, so it lives outside the
package, in `extensions/tiers.json`:

```json
{ "away": "trusted" }
```

Anything not listed is `view`. Validation refuses a `tiers.json` naming an
extension that doesn't exist or a tier that isn't one of the three, and an
extension asking for something its tier can't grant: a service at `view`, or
`bluetooth` at `service`.

The packager folds it into each index entry as `"tier"`. Hosts that predate
tiers ignore the field. A newer host records it in
`~/.stack-nudge/extensions/.tiers.json` when it installs from the index, and
re-checks the record whenever it loads the catalogue: the first time Settings
or the extensions browser opens in each launch, and on the browser's ⌘R or Try
again. A tier can go down to what the index now says, and drops to `view` if
the index stops listing the extension, but it never goes up without an install
or an update. A change found then reloads the extensions straight away, so a
demoted service restarts with its smaller grant (or stops, below `service`).
Until the catalogue loads, the recorded tier stands. Removing an extension
forgets its tier.

**For developing an extension** that no release's index lists yet, set
`STACKNUDGE_EXTENSIONS_LOCAL_TIERS=true` in `~/.stack-nudge/config`. The host
then never re-checks `.tiers.json` against the index, so a tier you write there
by hand stays (installing from the index still records the index's tier). It's
a testing setting, not a way to ship: like the file itself, anything running as
you could set it, so it rests on review the same way the file does.

### What installing checks

In this order, and each step refuses before the next one runs:

1. `requires` — each interpreter is **executed**, because `command -v python3`
   succeeds on the Command Line Tools stub and then fails the moment anything runs
2. the payload is verified against its `.sha256` sidecar — **a missing sidecar is
   fatal**, never a soft pass
3. the sidecar must also agree with the index; the index naming the asset *and*
   carrying its hash proves nothing on its own
4. the archive is listed and inspected before it is extracted — absolute paths,
   any `..` component, anything outside the extension's own directory, and any
   symlink or special file are all refused
5. the unpacked `manifest.json` is validated with the same parser the runtime
   uses, before anything is moved into place

## Where it appears

```json
{ "surfaces": ["settings"] }
```

Every installed extension is listed under **Settings → Extensions**, one row
each: its name, its `description` (keep it to one line, it's all the row has
room for), and a short status on the right. A pending update says "Update x.y";
otherwise a service says what it's doing (Running, Starting, Broken, Stopped,
or Present / Away for the one holding `presence`), and a view says "Tab ⌘N"
when it has a tab. Below the list, **Browse extensions** opens the catalogue,
where an extension above the `view` tier asks before it installs.

`→` or `⏎` on a row opens the extension's own page, and `←` goes back to the
list. Top to bottom it shows:

- a one-line status from your latest document (the header badge, then the
  first row's title and value), as a readout, not a row;
- one row per config key, as its [type](#typed-keys) draws it. The keys are
  every Settings page's: `Space` or `⏎` flips a toggle, starts and settles a
  picker, or turns a text row into a field; `←` / `→` step a picker only once
  it's started;
- the app's own **Lock screen when away** row, on the page of whichever
  extension holds `presence`. Should the holder have no page (it failed to
  load, say), the row sits on the Extensions list instead, so the toggle
  exists whenever something can lock the screen;
- read-only lines saying what it was **allowed** (its granted capabilities, in
  plain words: "Bluetooth", "Tell StackNudge you're away") and where else it
  **appears** ("Tab ⌘3", or "this page only");
- **Update to x.y**, only when there is one, and **Remove**. Remove takes `⌘⌫`
  (not `⏎`, since it has no confirmation), which also removes from the
  extension's row on the list; nowhere else binds it.

So `surfaces` only decides about the tab. `["tab"]`, the default, gives one as
described above; `["settings"]` means no tab, no `⌘1`…`⌘9` slot and no widget
chip, just the page, which suits something you set and forget; `["tab",
"settings"]` is the same as `["tab"]` today. A view extension without a tab is
fetched when its page is opened, since there is no tab whose opening would do
that.

Any tier may use it, since it grants nothing. It's a manifest field, so older
hosts ignore it and show a tab, which still works. An unknown surface, or an
empty list, is refused.

## Trust

Out-of-process buys **crash and hang containment**: a wedged or crashing extension
costs its own tab, not the app. It is not isolation. The script runs as you, and
macOS may attribute a child's TCC access to the responsible parent — so an
extension can plausibly reach permissions the app has already been granted, and do
things you would normally be prompted for.

The control is curation. An extension PR is reviewed as code. Two things a
reviewer should check that are easy to miss:

- **`run` and every path in the package.** Containment is enforced on resolved
  paths, but a symlink in a tarball is how a manifest tells a reviewer one thing
  and does another.
- **Declared `config` keys.** They are restricted to the `STACKNUDGE_EXT_`
  namespace and to a plain environment-variable shape, but that namespace is
  still yours to justify — and a declared key now appears as a
  field in Settings, so it is also a request for the user's attention. An
  extension that asks for five values it could infer is asking for five
  decisions nobody wanted to make.

## Limits, in one place

| | |
|---|---|
| stdout | 8 MB, 12 s |
| rows | 500 |
| actions | 16 per list |
| text fields | 256 characters |
| sprite | 32 frames × 24 rows × 64 columns, 30 fps |
| ornaments | 4 per row |
| tab label | 16 characters |
| poll interval | 5 s minimum |

Exceeding a cap truncates rather than fails — an over-long title is a formatting
slip, not a reason to blank the pane.
