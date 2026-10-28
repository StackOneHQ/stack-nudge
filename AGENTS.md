# AGENTS.md

Guidance for AI agents working in this repo. `CLAUDE.md` is a symlink to this file, so edit this one.

## Keyboard navigation

The panel is meant to be driven entirely from the keyboard, and every page should feel like the same app. Before adding or changing a binding, check it against the rules below and against the page that already does the same thing. If a change has to break a rule, say why in a comment at the binding and add it to the known exceptions at the end of this section.

Key routing lives in `panel/Panel.swift`. `panelHandlesGlobalKey` owns the keys that mean the same thing everywhere, and `panelHandlesKey` has one branch per `nav.mode` for the rest. Selection and value state live on `PanelNav`.

### Keys that mean the same thing on every page

These are handled once, in `panelHandlesGlobalKey`, which `FloatingPanel.sendEvent` calls before the first responder sees the key. That is what makes them work while a text field has focus too. Don't bind them in a page's branch, and don't give a text field its own handling for them (`.onExitCommand` and the like): it can never fire.

| Key | Meaning |
|-----|---------|
| `Esc` | In a text field, or while a shortcut is being recorded, cancel it. Everywhere else, hide the panel: on every page, in every state, including setup, update and uninstall screens. Nothing else. |
| `⌘←` / `⌘→` | Previous / next top-level tab, without wrapping. Left alone only while recording a hotkey, so the combo can be recorded. |
| `⌫` in an empty text field | Cancel the field, as `Esc` does. |

Cancelling a field puts it back the way it was before you started and hands the keyboard back to its page. Recording a shortcut counts as editing one: cancelling keeps the old shortcut. A search, filter or new-entry field empties. A field holding a value goes back to that value: a rename keeps the old name, an extension config field its saved value. `cancelField` in `Panel.swift` does this per page, so a page that adds a text field adds its case there.

### Moving through a page

- **Into and out of a level inside a tab** (Settings categories and rows, Usage clients and detail, Outcomes overview and tickets): `→` or `⏎` steps in, `←` steps back out. Stepping in lands on the first row or pane, so the path is predictable.
- **Carousels** (Usage detail panes): `←` / `→` walk the panes. `→` stops on the last pane rather than wrapping, and `←` on the first pane steps out a level, so the key that brought you in takes you back.
- **Sub-pages** opened from another page (Phrases, Permissions, extension config, the extensions browser, the history pane, update and uninstall confirm): `←` goes back to the page it belongs under (Settings for most; setup for Permissions when setup opened it). Never `Esc`.
- **`⌘1`…`⌘9`** jump straight to a tab. The order comes from one list in `PanelNav`, so the strip, the numbers and `⌘←/→` can't disagree.

| Key | Meaning |
|-----|---------|
| `↑` / `↓` | Move the selection one row. On a page that scrolls instead of selecting, scroll it. |
| `⌘↑` / `⌘↓` | Jump to the first / last item. Shared by every page through `jumpToEdge`; a page with nothing to jump returns false so the key passes through. |
| `Tab` / `⇧Tab` | Next / previous row on pages that have them (Settings). Never a different action. |
| `→` / `←` | Step into / out of a level, or through a carousel. While a value is being picked, they step the value instead (see `Space`). |
| `⏎` | The selected row's main action: open, approve, activate. Every row that shows a `⏎` hint has to do something with it. |
| `Space` | Flip a toggle (Phrases defaults, the update log). In Settings it does what `⏎` does on every row: flips an on/off row, fires an action row, and on a value row (a sound, a duration, a threshold) starts picking. While picking, `←` / `→` step through the values and `Space` or `⏎` settles on one; moving to another row settles it too. |
| `⌫` / `⌦` | Dismiss the selected item, where that loses nothing (an Events nudge, an Outcomes row). Anything destructive that has no confirmation step takes `⌘⌫` (killing a session, removing a phrase or an extension), and ignores autorepeat. |
| `/` | Focus the page's text field, where it has one. |

### Rules

- **Arrows never change a setting on their own.** `←` / `→` move through the app. A toggle only changes on `Space` or `⏎`, and a value only steps once `Space` has started picking it. Otherwise a key pressed to look around changes a setting without anyone noticing. `PanelNav.selectedRowIsPicker` and `pickingValue` gate this for Settings.
- **One meaning per key.** Don't give `→` a different job on one row than on the row above it. If a row can't use a key, the key does nothing there, and the footer hint dims.
- **Single letters only where there's no text field.** List pages use single-letter shortcuts (`M` mute, `H` history, `O`, `S` / `⇧S` snooze, `N` rename, `W` window, `P` pause). On a page with a search or filter field, typing a letter goes into the field (type-to-search), so that page's commands take `⌘`: `⌘R` reload, `⌘⏎` configure, `⌘S` save.
- **A destructive action with no confirmation takes `⌘⌫`**, the macOS "move to trash" key, rather than a bare `⌫` that a text field also wants.
- **Leave other `⌘` combinations to the app.** Each branch checks `plain` (no modifiers) and returns false on anything it doesn't own, so `⌘Q` and friends keep working.
- **Never fall through to Events.** Routing is scoped to the mode: each page's branch either handles a key, swallows it, or returns false, and returning false hands the key to AppKit (a text field, the app's menu), never to another page's branch. Only the Events branch binds `⏎` to approve, and a key that reached it from another page could answer a permission prompt.
- **Ignore autorepeat on keys that start work** (`⌘R`, anything that spawns a process or fetches), so holding the key doesn't queue one job per repeat.
- **Let an input method finish.** While a field has marked text (an IME composing), `Esc` and `⌫` belong to it. `⌘←/→` still switch tabs.

### Footers and docs

- Every page's `PageFooter` lists the keys that work there, and only those. A footer that advertises a dead key is a bug.
- `PageFooter` adds the `Esc` hint itself, as the rightmost hint, outside the shedding layout so a narrow panel never drops it. It reads "Cancel" while a text field has focus or a shortcut is being recorded, and "Hide" otherwise, from `PanelNav.escapeCancels`. Pages never list `Esc`.
- Keep hints in place as the selection moves and dim the ones that don't apply (`opacity(0.35)`) instead of hiding them, so the footer doesn't reflow.
- Name where a key goes, not the key's generic meaning: "Categories" for a `←` that goes back to them, "Overview" for one that goes back to the overview.
- Update the key tables in `README.md` in the same change.

### Testing

Put the routing for a page in a pure static function that maps a key and modifiers to an action enum (`globalKeyAction`, `historyKeyAction`, `extensionsKeyAction`, `extensionConfigKeyAction`, `permissionsKeyAction`, `settingsDetailKeyAction`, plus `isForceRefresh` for the extension tab's ⌘R), and test that function. Bugs in key routing have mostly been ordering mistakes, like a branch sitting after a `guard plain` it needed to come before, and a pure function is the only place a test can see the order. For row behaviour on `PanelNav`, drive the real entry points (`cycleForward`, `cycleBackward`, `activate`) rather than only reading the predicate behind them.

### Known exceptions

These predate the rules. Fix them when you're in the area, or move them up into the rules if they turn out to be right.

- **`R`** means dismiss on Events and refresh on Usage.
- **Extension config's `Tab` / `⇧Tab`** activate the selected item at level one, as `⏎` does, since `Tab` is how a macOS form is entered.
