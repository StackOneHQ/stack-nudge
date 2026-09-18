# Security policy

## Reporting a vulnerability

Please **do not** open public GitHub issues for security reports. Instead, email **security@stackone.com** with:

- A description of the issue and the version of stack-nudge affected.
- Steps to reproduce or a proof-of-concept, if available.
- Any known mitigations.

We aim to acknowledge reports within 3 business days and to provide a remediation timeline within 10 business days of the initial acknowledgement.

## Scope

In scope:

- The `stack-nudge.app` and `stack-nudge-panel.app` macOS binaries (notifier and floating-panel daemon).
- The unix-socket protocol the panel daemon uses to receive nudges from `notify.sh` (`~/.stack-nudge/panel.sock`).
- File-permission handling in `~/.stack-nudge/` and the launchd plists installed by `install.sh`.
- The shell hook entry point `notify.sh` and its handling of agent-supplied JSON (Claude Code passes hook payloads on stdin).
- Supply-chain issues in the immediate stack-nudge repository (e.g. typo-squat risk on installer URLs).

Out of scope (report upstream instead):

- Vulnerabilities in `stackvox` (the offline TTS engine) — report to <https://github.com/StackOneHQ/stackvox>.
- Vulnerabilities in `kokoro-onnx`, `onnxruntime`, or any other dependency of stackvox — report to the respective project.
- macOS Accessibility / Automation TCC bugs — report to Apple.

## Supported versions

stack-nudge is pre-1.0. Only the latest published release receives security fixes. Once 1.0 ships, we will maintain the most recent minor release of the current major version.

## Privacy

There is no network telemetry, no analytics and no cloud component, and nothing is sent to StackOne. The panel does call out to GitHub, and to Slack once you configure it. [`PRIVACY.md`](./PRIVACY.md) lists every call it makes and what each one carries. Voice synthesis itself happens locally via stackvox, which `./install.sh` pip-installs from PyPI.
