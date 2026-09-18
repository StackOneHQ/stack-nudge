# Privacy Policy

stack-nudge collects no analytics and no telemetry. Nothing about you, your
machine or your work is reported to its authors, and there is no account to
sign up for.

It is not, however, an offline application, and an earlier version of this
document said it was. What follows is what it actually does.

## What stays on your machine

Everything it observes. stack-nudge watches local coding-agent sessions and
writes what it finds under `~/.stack-nudge/`:

- `config` — your settings, including any values you set for an extension
- `events.jsonl` — the local event history shown in the panel
- session names, dismissed agents, and similar panel state

Tokens are kept in the macOS Keychain rather than in that directory, except
briefly during setup when the Keychain is locked.

None of this is uploaded anywhere.

## What it sends, and when

**GitHub — always.** It checks for its own updates, and fetches the extension
index and any extension you install, from this project's GitHub releases. These
are anonymous requests; GitHub sees your IP address, as it would for any
download.

**GitHub sign-in — only if you start it.** Signing in links pull requests to
your sessions. It uses GitHub's device flow, asks for the `repo` scope, and
stores the token in your Keychain. It queries GitHub's API for your own pull
requests. You can disconnect it from Settings.

**Slack — only if you configure it.** With Slack set up, stack-nudge posts the
notifications you asked for to the channel or DM you chose, and looks up your
member id by email once to address them. With Slack not set up, it makes no
Slack requests.

**Extensions — whatever they do.** An extension is a separate program that
stack-nudge runs and reads a document from. It runs as you, with your
permissions, and nothing stops it making its own network requests. Two ship
with the app:

- `system` — CPU, memory and disk. Makes no network requests.
- `derby` — the Token Derby, a shared horse race scored on tokens produced. It
  is off until you set an organisation. When set, it GETs that organisation's
  current race from **token-derby.mauricode.co.uk**, a third-party service not
  operated by this project and covered by its own privacy policy. It is
  read-only: nothing about your machine, your sessions or your usage is sent to
  it, and the request carries no identifier beyond the organisation name you
  typed and your IP address.

Any other extension you install is subject to whatever *it* does. Extensions are
reviewed before publication, which is a real control and not the same as a
guarantee — see the Trust section of `docs/extensions.md`.

## Audio and voice

Sounds are played with your operating system's own tools (`afplay`, `paplay` or
`powershell`). No audio is recorded, ever.

Spoken notifications are optional and off until you enable them. Turning them on
downloads a speech model once, through the bundled `stackvox` package, from that
package's own model host. After that, synthesis runs locally on your machine —
the text of a notification is never sent anywhere to be spoken.

## Removing it

`./uninstall.sh` removes the app and the launch agent. Deleting
`~/.stack-nudge/` removes everything listed above.
