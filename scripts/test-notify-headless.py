#!/usr/bin/env python3
"""Behaviour tests for notify.sh's headless-run check.

A script driving an agent (`claude -p`, `codex exec`) fires the same hooks as a
person at a terminal, but nobody can answer its prompts, and a held hook stalls
the script for up to 550s. notify.sh therefore posts nothing for a headless run
unless STACKNUDGE_HEADLESS_NUDGES=on.

Most cases seed the agent through NUDGE_AGENT_PID: a stand-in process whose
command line carries the flags under test. Claude cases that set
CLAUDE_CODE_ENTRYPOINT check that the variable wins over the command line. One case leaves NUDGE_AGENT_PID unset
and runs the hook as the child of a process named `claude`, so notify.sh finds
the agent by walking up from $PPID, as it does under a real agent. The run
itself reuses the harness in test-notify-subagents.py (throwaway $HOME, fake
panel socket).

Usage: scripts/test-notify-headless.py [path/to/notify.sh]
"""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

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
    ("codex e prompt", "codex", ["e"], "permission", {}, None),
    ("codex review prompt", "codex", ["review"], "permission", {}, None),
    # codex's -p is --profile, not a headless flag.
    ("codex -p profile prompt", "codex", ["-p", "work"], "permission", {}, "Codex"),
    ("claude -p, opted back in", "claude-code", ["-p"], "permission",
     {"STACKNUDGE_HEADLESS_NUDGES": "on"}, "Claude Code"),
    # The entrypoint decides when it's set: a prompt that mentions -p is still
    # an interactive session, and an SDK run is headless whatever its argv.
    ("claude cli, prompt says -p", "claude-code", ["fix", "-p", "parsing"], "permission",
     {"CLAUDE_CODE_ENTRYPOINT": "cli"}, "Claude Code"),
    ("claude sdk-cli prompt", "claude-code", ["--resume", "abc"], "permission",
     {"CLAUDE_CODE_ENTRYPOINT": "sdk-cli"}, None),
    ("claude sdk-ts prompt", "claude-code", [], "permission",
     {"CLAUDE_CODE_ENTRYPOINT": "sdk-ts"}, None),
    # Global flags and their values come before codex's subcommand.
    ("codex -c value exec prompt", "codex", ["-c", "model=o3", "exec"], "permission", {}, None),
    ("codex --model value e prompt", "codex", ["--model", "m", "e"], "permission", {}, None),
    # A model named exec is the flag's value, not the subcommand.
    ("codex -m exec prompt", "codex", ["-m", "exec"], "permission", {}, "Codex"),
]

# Hook run as the child of `claude <flag>`, NUDGE_AGENT_PID unset. The
# interactive run is the control: it shows the stand-in parent is found at all,
# so the headless run passing means the flag was read, not that the walk missed.
PARENT_CASES = [
    ("hook under interactive claude", "--resume", "Claude Code"),
    ("hook under claude -p", "-p", None),
]

# Written out so deleting a case can't quietly lower the bar.
EXPECTED_CASE_COUNT = 16


def start_stand_in(agent, argv):
    """Start a sleeping process whose `ps -o args=` reads like the agent's."""
    if agent == "codex":
        # The codex check reads the words after the program, so the argv has
        # to start right there, under argv[0] "codex". yes parses no options,
        # and blocks once the pipe nobody reads is full.
        return subprocess.Popen(["codex", *argv], executable="/usr/bin/yes", stdout=subprocess.PIPE)
    # The claude check matches the flags anywhere, so a python stand-in will do.
    return subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)", *argv])


def run_under_claude_parent(workdir, flag, expect_event):
    """Run a permission hook as the child of `claude <flag>`, NUDGE_AGENT_PID unset.

    ps reports a process by the name it was launched under, so the parent is
    bash run through a symlink called `claude`. A copy of bash would need
    re-signing to launch at all, and on the CI runner the re-signed copy never
    ran the hook.
    """
    claude = os.path.join(workdir, "claude")
    if not os.path.lexists(claude):
        os.symlink("/bin/bash", claude)
    base_real = os.path.realpath(workdir)
    wrapper_real = os.path.realpath(os.path.join(workdir, "under-claude.sh"))
    if os.path.commonpath([base_real, wrapper_real]) != base_real:
        raise Exception("Invalid file path")
    with open(wrapper_real, "w", encoding="utf-8") as wrapper_file:
        # The trailing `exit` keeps bash from exec'ing notify.sh in its own
        # place, which would drop `claude` out of the process tree.
        wrapper_file.write('#!/bin/sh\nexec "$CLAUDE_STAND_IN" -c \'"$@"; exit $?\' "$CLAUDE_FLAG" "$REAL_NOTIFY" "$@"\n')
    os.chmod(wrapper_real, 0o755)
    real_notify = harness.NOTIFY
    harness.NOTIFY = wrapper_real
    try:
        env = {"CLAUDE_STAND_IN": claude, "CLAUDE_FLAG": flag, "REAL_NOTIFY": real_notify}
        return harness.posted_title("claude-code", {}, env, expect_event, False, "permission")
    finally:
        harness.NOTIFY = real_notify


def main():
    if sys.platform != "darwin":
        print("skipped: notify.sh only posts to the panel on macOS")
        return 0
    os.environ.pop("NUDGE_AGENT_PID", None)
    # Set when the tests themselves run under Claude Code; it would decide
    # every claude case.
    os.environ.pop("CLAUDE_CODE_ENTRYPOINT", None)
    workdir = tempfile.mkdtemp(prefix="stack-nudge-test-headless-")
    passed = 0
    try:
        for name, agent, argv, event, env, expected in CASES:
            stand_in = start_stand_in(agent, argv)
            try:
                actual = harness.posted_title(agent, {}, dict(env, NUDGE_AGENT_PID=str(stand_in.pid)),
                                              expected is not None, False, event)
            finally:
                stand_in.kill()
                stand_in.wait()
            ok = actual == expected
            passed += ok
            print("%-4s %-30s expected=%-16r actual=%r" % ("PASS" if ok else "FAIL", name, expected, actual))

        for name, flag, expected in PARENT_CASES:
            actual = run_under_claude_parent(workdir, flag, expected is not None)
            ok = actual == expected
            passed += ok
            print("%-4s %-30s expected=%-16r actual=%r" % ("PASS" if ok else "FAIL", name, expected, actual))
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    ran = len(CASES) + len(PARENT_CASES)
    if ran != EXPECTED_CASE_COUNT:
        print("FAIL ran %d cases, expected %d" % (ran, EXPECTED_CASE_COUNT))
        return 1
    return 0 if passed == ran else 1


if __name__ == "__main__":
    sys.exit(main())
