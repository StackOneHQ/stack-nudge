# Privacy Policy

stack-nudge has no backend. There is no account, no analytics, no crash
reporting, and nothing is sent to StackOne. Your sessions, events, transcript
statistics and config live in `~/.stack-nudge/` and are never uploaded.

It is not offline, though. The panel makes the network calls below, each to the
third party named, and each revealing to that party what any HTTPS request
reveals: your IP address and a standard user agent. None of them carry a
StackNudge identifier, because there isn't one.

## Always on

- **Update check.** `api.github.com`, on launch and every two hours, asking for
  this repo's latest release. There is currently no setting to turn this off.
- **Update download.** `github.com` and `objects.githubusercontent.com`, only
  once you accept an update.

## Only once you enable them

- **GitHub PR links** (`STACKNUDGE_GITHUB`). Signs you in through GitHub's
  device flow on `github.com`, then queries `api.github.com` for pull requests
  on branches you have worked on. The token is stored locally and is used for
  nothing else.
- **Slack notifications** (`STACKNUDGE_SLACK`). Posts to `slack.com` with the
  bot token you supply, and looks your account up by email once to find the DM
  channel. Nudge text is included only if `STACKNUDGE_SLACK_DETAIL` is on.
- **Extensions.** The catalogue and each extension you install are fetched from
  the releases of `StackOneHQ/stack-nudge-extensions-marketplace` on
  `api.github.com` and `github.com`. If the anonymous
  GitHub API is rate-limiting your machine and you have the `gh` CLI installed,
  the catalogue fetch and the update check retry through it, which authenticates
  as you against your own GitHub account.

  If `STACKNUDGE_EXTENSIONS_SOURCES` names other repositories, their catalogues
  and packages are fetched from their releases on `api.github.com` too, with
  your GitHub token (stack-nudge's own sign-in, or the `gh` CLI's) so a private
  one can be read. The token is only sent to those repositories' release
  assets on `api.github.com`, never to the storage host GitHub redirects
  downloads to. Without that setting nothing reads either token for this.

  An installed extension is a separate program that stack-nudge runs, and
  **whatever network calls it makes are its own**. What each of the app's own
  extensions reads and sends is in the marketplace's
  [PRIVACY.md](https://github.com/StackOneHQ/stack-nudge-extensions-marketplace/blob/main/PRIVACY.md).
- **Voice** (`STACKNUDGE_VOICE`). Downloading a voice model runs `stackvox` in
  the bundled Python environment, which fetches the model over the network.
  That download is the only part that leaves your machine: synthesis runs
  locally against the downloaded model, and alert sounds play through your
  operating system's own tools (`afplay`, `paplay`, `powershell`). The model is
  about 350 MB and lands in `~/.cache/stackvox/`, outside `~/.stack-nudge/` —
  worth knowing if you are removing stack-nudge by deleting that directory.

## Tools it runs on your behalf

Usage tracking (`STACKNUDGE_QUOTA_TRACKING`) reads your quota by shelling out to
the `claude` and `codex` CLIs you already have installed, and by asking
Antigravity's language server on `127.0.0.1`. The first two make their own calls
to their own vendors, under those vendors' privacy policies, exactly as they
would if you ran them yourself.

## What is never sent, anywhere

No telemetry, no usage statistics, no device or install identifier, no prompt or
response content, no transcripts, no file contents, no session or project names.
