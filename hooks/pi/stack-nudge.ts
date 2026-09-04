// stack-nudge integration for pi (@earendil-works/pi-coding-agent).
//
// pi has no Claude-Code-style hook system, but it does auto-load extensions
// from ~/.pi/agent/extensions/*.ts in every session. This extension forwards
// pi's lifecycle events to stack-nudge's installed hook entrypoint (notify.sh)
// exactly as the Claude Code / Codex hooks do, so pi sessions get the same
// banner, voice, attention-focus, and per-ticket handoff capture with no
// stack-nudge-side special-casing (the panel keys everything off the `pi` agent
// string, which flows through the same unix socket as every other agent).
//
// Install: copy to ~/.pi/agent/extensions/stack-nudge.ts (install.sh does this
// automatically when ~/.pi/agent is present).

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";

// stack-nudge's installed hook entrypoint — the same script Claude/Codex invoke.
const NOTIFY = join(homedir(), ".stack-nudge", "notify.sh");

// Per-pid tmux sidecar. pi renames its process title to "pi", which clobbers the
// argv+env memory region `ps -e` reads — so the panel CANNOT read pi's env from
// outside to resolve its tmux pane (unlike claude, whose env stays readable).
// The extension runs inside pi, so it's the only place that can read TMUX_PANE;
// it writes the pane here for the panel's tmux focus to consume by pid. Analogous
// to Claude Code's ~/.claude/sessions/<pid>.json sidecar.
const SIDECAR_DIR = join(homedir(), ".stack-nudge", "pi-sessions");
const sidecarPath = join(SIDECAR_DIR, `${process.pid}.json`);

const writeTmuxSidecar = (): void => {
  const pane = process.env.TMUX_PANE;
  if (!pane) return; // not inside tmux — nothing for the pane-focus path to use
  // TMUX is "<socket>,<serverPID>,<sessionN>"; the socket is the first field.
  const socket = process.env.TMUX?.split(",")[0];
  try {
    mkdirSync(SIDECAR_DIR, { recursive: true });
    writeFileSync(sidecarPath, JSON.stringify({
      pane,
      socket,
      lcTerminal: process.env.LC_TERMINAL,
    }));
  } catch {
    // never surface to the session
  }
};

const removeTmuxSidecar = (): void => {
  try {
    rmSync(sidecarPath, { force: true });
  } catch {
    // ignore
  }
};

// pi's session id is the uuid half of "<timestamp>_<uuid>.jsonl". Deriving it
// from the filename avoids reading the file just to echo the header id back.
const sessionIdFromFile = (file: string | undefined): string | undefined => {
  if (!file) return undefined;
  const stem = basename(file, ".jsonl");
  const underscore = stem.indexOf("_");
  return underscore >= 0 ? stem.slice(underscore + 1) : stem;
};

// Fire the hook without ever blocking or throwing back into pi: a missing
// notify.sh, a permission error, or a broken pipe must stay invisible to the
// coding session. The payload mirrors the subset of the Claude hook JSON that
// notify.sh reads (session_id, transcript_path, cwd); NUDGE_AGENT_PID seeds the
// agent pid that walk_session_chain can't infer for a node-hosted agent.
const fireHook = (event: string, sessionFile: string | undefined): void => {
  const payload = JSON.stringify({
    hook_event_name: event,
    session_id: sessionIdFromFile(sessionFile),
    transcript_path: sessionFile,
    cwd: process.cwd(),
  });
  try {
    const child = spawn("/bin/bash", [NOTIFY, "pi", event], {
      stdio: ["pipe", "ignore", "ignore"],
      env: { ...process.env, NUDGE_AGENT_PID: String(process.pid) },
    });
    child.on("error", () => {});
    child.stdin?.on("error", () => {});
    child.stdin?.end(payload);
    child.unref();
  } catch {
    // never surface to the session
  }
};

export default function (pi: ExtensionAPI): void {
  // Write the tmux pane sidecar up front (the session is already running when
  // the factory loads) and again on session_start, so the panel can focus the
  // pane by pid from the first turn. Removed on shutdown to avoid a stale entry
  // focusing the wrong pane if the pid is later reused.
  writeTmuxSidecar();
  pi.on("session_start", async () => writeTmuxSidecar());
  pi.on("session_shutdown", async () => removeTmuxSidecar());

  // agent_settled is pi's "won't continue on its own" signal — the analog of
  // Claude Code's Stop hook. That's the moment the user's attention is wanted,
  // and the point at which the handoff/token snapshot should be captured.
  pi.on("agent_settled", async (_event, ctx) => {
    if (!ctx.isIdle()) return;
    // sessionManager is absent under `pi --no-session`; guard so the handler
    // never throws (the event still fires, just without a transcript path).
    let sessionFile: string | undefined;
    try {
      sessionFile = ctx.sessionManager?.getSessionFile();
    } catch {
      sessionFile = undefined;
    }
    fireHook("stop", sessionFile);
  });
}
