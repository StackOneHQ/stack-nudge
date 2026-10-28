#!/usr/bin/env python3
"""Behaviour tests for notify.sh's headless-run check.

A script driving an agent (`claude -p`, `codex exec`) fires the same hooks as a
person at a terminal, but nobody can answer its prompts, and a held hook stalls
the script for up to 550s. notify.sh therefore posts nothing for a headless run
unless STACKNUDGE_HEADLESS_NUDGES=on.

The agent is a stand-in process whose command line carries the flags under
test, seeded through NUDGE_AGENT_PID; the run itself reuses the harness in
test-notify-subagents.py (throwaway $HOME, fake panel socket).

Usage: scripts/test-notify-headless.py [path/to/notify.sh]
"""

import importlib.util
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("harness", os.path.join(HERE, "test-notify-subagents.py"))
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)

# name, agent, stand-in argv after the program, event, env, expected title (None = nothing posted)
CASES = [
    ("interactive claude prompt", "claude-code", ["--resume", "abc"], "permission", {}, "Claude Code"),
    ("claude -p prompt", "claude-code", ["-p", "--output-format", "json"], "permission", {}, None),
    ("claude --print stop", "claude-code", ["--print", "hi"], "stop", {}, None),
    ("codex exec prompt", "codex", ["exec", "fix it"], "permission", {}, None),
    ("claude -p, opted back in", "claude-code", ["-p"], "permission",
     {"STACKNUDGE_HEADLESS_NUDGES": "on"}, "Claude Code"),
]

# Written out so deleting a case can't quietly lower the bar.
EXPECTED_CASE_COUNT = 5


def main():
    if sys.platform != "darwin":
        print("skipped: notify.sh only posts to the panel on macOS")
        return 0
    passed = 0
    for name, agent, argv, event, env, expected in CASES:
        # A sleeping python whose args read like the agent's; only the args are inspected.
        stand_in = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)", *argv])
        try:
            actual = harness.posted_title(agent, {}, dict(env, NUDGE_AGENT_PID=str(stand_in.pid)),
                                          expected is not None, False, event)
        finally:
            stand_in.kill()
            stand_in.wait()
        ok = actual == expected
        passed += ok
        print("%-4s %-30s expected=%-16r actual=%r" % ("PASS" if ok else "FAIL", name, expected, actual))
    if len(CASES) != EXPECTED_CASE_COUNT:
        print("FAIL ran %d cases, expected %d" % (len(CASES), EXPECTED_CASE_COUNT))
        return 1
    return 0 if passed == len(CASES) else 1


if __name__ == "__main__":
    sys.exit(main())
