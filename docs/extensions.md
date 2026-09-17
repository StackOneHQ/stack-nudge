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
| `id` | yes | `^[a-z0-9-]{1,32}$`, and **must equal the directory name**. It becomes a path component, so it is validated before it is ever used as one. |
| `name` | yes | Human-readable. Used as the tab label when `tab.label` is absent. |
| `version` | yes | Yours to manage; the host only records it. |
| `schema` | yes | Must be `1`. Anything else is refused outright — see [Versioning](#versioning). |
| `tab.label` | no | Defaults to `name`. Trimmed, capped at 16 characters, falls back to `id` if empty. |
| `run` | no | Defaults to `./run`. Relative to the extension directory, no `..`, no absolute or `~` paths. |
| `requires` | no | Interpreters the extension needs. **Parsed but not yet enforced** — install-time checking arrives with distribution. |
| `config` | no | Environment keys to pass through. Must be under `STACKNUDGE_EXT_`. |
| `refresh.onOpen` | no | Default `true`. Fetch when the tab is opened. |
| `refresh.intervalSeconds` | no | Default off. Floored at 5 — every tick is a process spawn. |
| `refresh.whileFocusedOnly` | no | Default `true`. Only poll while your tab is the one on screen. |

A manifest that fails any of these is **refused**, and the reason is reported —
it does not silently produce a missing tab.

## The environment

Your script gets exactly this, and nothing else:

```
PATH                    a minimal system PATH
HOME
STACKNUDGE_EXT_ID       your id
STACKNUDGE_EXT_SCHEMA   the schema this host speaks
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

An animated pixel grid, drawn on the row's track band.

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

The host refuses any `schema` it does not speak, rather than guessing. Read
`STACKNUDGE_EXT_SCHEMA` to find out what this host can read before you print.

**Additive fields are the only compatible change.** Unknown fields are ignored, so
a new field is invisible to an older host — which also means a field that
*restricts* behaviour cannot be added safely without a schema bump.

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
- **Declared `config` keys.** They are restricted to `STACKNUDGE_EXT_`, but that
  namespace is still yours to justify.

## Limits, in one place

| | |
|---|---|
| stdout | 8 MB, 12 s |
| rows | 500 |
| actions | 16 per list |
| text fields | 256 characters |
| sprite | 32 frames × 24 rows × 64 columns, 30 fps |
| tab label | 16 characters |
| poll interval | 5 s minimum |

Exceeding a cap truncates rather than fails — an over-long title is a formatting
slip, not a reason to blank the pane.
