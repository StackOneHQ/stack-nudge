#!/usr/bin/env python3
"""Behaviour tests for notify.sh's subagent handling.

Claude Code and Codex route a subagent's tool calls through the same
PermissionRequest hook as the main thread, so notify.sh decides from the hook
payload alone whether a nudge came from an agent the user spawned. That decision
(tag it, drop it, or leave it alone) is the thing these tests pin down.

They drive the real notify.sh end to end rather than unit-testing a function,
because the interesting part is the whole path: config parsing, payload
extraction with and without jq, and the title that finally reaches the panel.

How it stays out of the way:

- `$HOME` is a throwaway directory per case, so the developer's own
  ~/.stack-nudge (config, live panel.sock) is never read or written and no
  banner reaches their screen. The fake panel socket in that directory is what
  the assertions read.
- `$TMPDIR` points there too, so permission FIFOs land in the same disposable
  directory.
- The permission path blocks on that FIFO for up to 550s waiting for a decision.
  post_to_panel has already run by then, so each case takes its payload and
  kills the hook rather than answering.

macOS only: on Linux and Windows notify.sh plays a sound and never posts to the
panel, so there is no title to assert against.

Usage: scripts/test-notify-subagents.py [path/to/notify.sh]
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOTIFY = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO_ROOT, "notify.sh")
NOJQ_BIN = os.path.join(tempfile.gettempdir(), "stack-nudge-test-nojq-bin")

# How long to wait for the panel payload. A case expecting no event has nothing
# to wait for, so it only needs long enough that a regression would have posted.
POST_TIMEOUT_S = 20
NO_POST_WAIT_S = 5

# name, agent, payload fields, env, expected banner title (None = no event at all)
CASES = [
    ("main thread", "claude-code", {}, {}, "Claude Code"),
    ("subagent", "claude-code", {"agent_id": "a1", "agent_type": "Explore"}, {},
     "Claude Code · Explore"),
    # agent_type is absent on a subagent whose type didn't survive the payload;
    # agent_id alone still proves where the call came from.
    ("subagent, no agent_type", "claude-code", {"agent_id": "a1"}, {},
     "Claude Code · subagent"),
    ("subagent, plugin-scoped type", "claude-code",
     {"agent_id": "a1", "agent_type": "stackone-deep-dive:security-reviewer"}, {},
     "Claude Code · security-reviewer"),
    ("subagent, over-long type", "claude-code",
     {"agent_id": "a1", "agent_type": "an-extremely-long-subagent-name-here"}, {},
     "Claude Code · an-extremely-long-subag…"),
    # The false positive the agent_id gate exists to avoid: `claude --agent X`
    # sets agent_type on the main thread, where nudges must not be touched.
    ("main thread started with --agent", "claude-code", {"agent_type": "Explore"}, {},
     "Claude Code"),
    ("subagent, nudges off", "claude-code", {"agent_id": "a1", "agent_type": "Explore"},
     {"STACKNUDGE_SUBAGENT_NUDGES": "off"}, None),
    ("main thread, nudges off", "claude-code", {},
     {"STACKNUDGE_SUBAGENT_NUDGES": "off"}, "Claude Code"),
    # Codex names these fields identically; its subagents come from spawn_agent.
    ("codex subagent", "codex", {"agent_id": "a1", "agent_type": "worker"}, {},
     "Codex · worker"),
    ("codex subagent, nudges off", "codex", {"agent_id": "a1", "agent_type": "worker"},
     {"STACKNUDGE_SUBAGENT_NUDGES": "off"}, None),
    # Agents whose payloads carry no subagent id are left exactly as they were,
    # even if something in the payload happens to look like one.
    ("gemini is untouched", "gemini", {"agent_id": "a1", "agent_type": "Explore"}, {},
     "Gemini"),
]

# Both extractor paths matter: only macOS 15+ preinstalls jq, so the python3
# fallback is what most machines actually run.
NO_JQ_CASES = [CASES[0], CASES[1], CASES[5]]

EXPECTED_CASE_COUNT = len(CASES) + len(NO_JQ_CASES)


def build_nojq_path():
    """A PATH holding everything the hook needs except jq."""
    shutil.rmtree(NOJQ_BIN, ignore_errors=True)
    os.makedirs(NOJQ_BIN)
    for source_dir in ("/bin", "/usr/bin", "/usr/sbin", "/sbin"):
        if not os.path.isdir(source_dir):
            continue
        for entry in os.listdir(source_dir):
            if entry == "jq":
                continue
            link = os.path.join(NOJQ_BIN, entry)
            if not os.path.exists(link):
                os.symlink(os.path.join(source_dir, entry), link)


def posted_title(agent, payload_fields, env_overrides, expect_event, without_jq):
    """Run one hook invocation; return the title it posted, or None."""
    home = tempfile.mkdtemp(prefix="stack-nudge-test-home-")
    os.makedirs(os.path.join(home, ".stack-nudge"))

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(os.path.join(home, ".stack-nudge", "panel.sock"))
    server.listen(1)
    server.settimeout(POST_TIMEOUT_S)
    received = {}

    def accept_one():
        try:
            connection, _ = server.accept()
            connection.settimeout(POST_TIMEOUT_S)
            chunks = []
            while True:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
            connection.close()
            received["payload"] = b"".join(chunks).decode("utf-8", "replace")
        except OSError:
            pass

    listener = threading.Thread(target=accept_one, daemon=True)
    listener.start()

    payload = {
        "hook_event_name": "PermissionRequest",
        "session_id": "test-session",
        "transcript_path": os.path.join(home, "transcript.jsonl"),
        "tool_name": "Bash",
        "tool_input": {"command": "rg --files"},
    }
    payload.update(payload_fields)

    env = dict(os.environ, HOME=home, TMPDIR=home)
    if without_jq:
        env["PATH"] = NOJQ_BIN
    env.update(env_overrides)

    hook = subprocess.Popen(
        [NOTIFY, agent, "permission"],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    hook.stdin.write(json.dumps(payload).encode())
    hook.stdin.close()

    listener.join(timeout=POST_TIMEOUT_S if expect_event else NO_POST_WAIT_S)
    hook.kill()
    hook.wait()
    server.close()
    shutil.rmtree(home, ignore_errors=True)

    if "payload" not in received:
        return None
    try:
        return json.loads(received["payload"]).get("title")
    except ValueError:
        return "<unparseable payload: %s>" % received["payload"][:120]


def run_case(name, agent, payload_fields, env_overrides, expected, without_jq=False):
    actual = posted_title(agent, payload_fields, env_overrides, expected is not None,
                          without_jq)
    passed = actual == expected
    print("%-4s %-36s expected=%-34r actual=%r"
          % ("PASS" if passed else "FAIL",
             name + (" [no jq]" if without_jq else ""), expected, actual))
    return passed


def main():
    if sys.platform != "darwin":
        print("skipped: notify.sh only posts to the panel on macOS")
        return 0

    if not os.access(NOTIFY, os.X_OK):
        print("FAIL no executable notify.sh at %s" % NOTIFY)
        return 1

    build_nojq_path()
    try:
        results = [run_case(*case) for case in CASES]
        results += [run_case(*case, without_jq=True) for case in NO_JQ_CASES]
    finally:
        shutil.rmtree(NOJQ_BIN, ignore_errors=True)

    # A case silently dropped from the table would make a green run mean less
    # than it appears to, so assert the count as well as the results.
    if len(results) != EXPECTED_CASE_COUNT:
        print("\nFAIL ran %d cases, expected %d" % (len(results), EXPECTED_CASE_COUNT))
        return 1

    print("\n%d/%d passed" % (sum(results), len(results)))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
