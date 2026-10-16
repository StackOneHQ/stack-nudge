#!/usr/bin/env python3
"""Behaviour tests for which permission events notify.sh blocks on.

A permission hook that creates a FIFO blocks for up to 550s waiting for the
panel's Allow/Deny. That is correct for an ordinary tool approval and wrong for
anything else. Claude Code renders its own dialog either way, so there the harm
is not a hidden prompt — it is that the panel offers an Allow which the agent
reads as "press Enter on the highlighted option", answering a question with a
default the user never chose; and that answering in the agent's own UI does not
end our hook, so it holds its FIFO for the full 550s while the panel keeps
reminding about a prompt already answered (#177). Codex draws its prompt only
once the hook returns, so a blocked Codex hook does hide it until the panel
answers.

notify.sh decides this from the hook payload alone, in permission_is_blockable.
These cases pin down the decision for the shapes that reach it, including the
ones it cannot parse — an unrecognised payload must decline to block rather than
swallow a prompt it failed to classify.

The panel's answer is pinned too. It writes allow, deny or release to the FIFO.
allow and deny become the hook's decision. release is what a banner click or
`O` sends when the user goes to the terminal instead, and the hook has to exit
straight away with no decision, or Codex's prompt stays hidden.

They drive the real notify.sh end to end, like the subagent tests beside them,
because the decision depends on the whole path: payload extraction with and
without jq, the agent gate, and the has_action_button that finally reaches the
panel. The same isolation applies — a throwaway $HOME and $TMPDIR per case, and
a fake panel socket there, so the developer's own ~/.stack-nudge is untouched
and no banner reaches their screen.

macOS only: elsewhere notify.sh plays a sound and never posts to the panel.

Usage: scripts/test-notify-permission-blocking.py [path/to/notify.sh]
"""

import errno
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NOTIFY = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO_ROOT, "notify.sh")
# Unique per run: a fixed path is shared state, and two suites running at once
# (a local run beside a CI run on the same box) would rebuild it under each
# other mid-case.
_FAKE_BIN_ROOT = tempfile.mkdtemp(prefix="stack-nudge-test-bin-")
NOJQ_BIN = os.path.join(_FAKE_BIN_ROOT, "nojq")
BADJQ_BIN = os.path.join(_FAKE_BIN_ROOT, "badjq")

POST_TIMEOUT_S = 20

# How long a non-blocking hook gets to exit on its own. The blocking path waits
# 550s, so anything that returns inside this window demonstrably took the other
# branch. Generous because a cold python3 start is on this path.
EXIT_TIMEOUT_S = 25

# name, agent, payload overrides (None deletes the key), expected has_action_button
#
# `blockable` here means: the panel offers Allow/Deny and the hook waits on a
# FIFO for the answer. False means the banner still shows — only the button and
# the wait are dropped.
CASES = [
    # The ordinary case the FIFO exists for.
    ("bash approval", "claude-code", {}, True),
    ("codex approval", "codex", {}, True),
    ("codex apply_patch", "codex", {"tool_name": "apply_patch"}, True),
    # Questions: the user answers in the agent's own UI, so an Allow would pick
    # a default for them. Already handled before this test existed.
    ("AskUserQuestion", "claude-code",
     {"tool_name": "AskUserQuestion",
      "tool_input": {"questions": [{"question": "Which one?"}]}}, False),
    ("ExitPlanMode", "claude-code", {"tool_name": "ExitPlanMode"}, False),
    # An agent whose hook cannot consume a decision at all.
    ("gemini approval", "gemini", {}, False),
    # The shapes that cannot be classified. Each one must decline to block:
    # we do not know that this is a tool approval, and guessing wrong hides a
    # prompt for 550s.
    ("tool_name absent", "claude-code", {"tool_name": None}, False),
    ("tool_name empty", "claude-code", {"tool_name": ""}, False),
    ("tool_name nested, not top level", "claude-code",
     {"tool_name": None, "tool_use": {"name": "Bash"}}, False),
    ("tool_name camelCased", "claude-code",
     {"tool_name": None, "toolName": "Bash"}, False),
    # Not a string. jq stringifies any JSON type and the python3 fallback
    # returns empty, so before `| strings` these took OPPOSITE branches
    # depending on whether the machine had jq. Either way it is a shape we
    # cannot classify, so both must fail open.
    ("tool_name is a number", "claude-code", {"tool_name": 123}, False),
    ("tool_name is an object", "claude-code",
     {"tool_name": {"name": "Bash"}}, False),
    # A question tool we have never heard of. The allowlist cannot name it, so
    # the unreadable-payload rule is what has to carry it — it stays blockable
    # only because it DOES carry a tool_name, which is the honest trade: we
    # cannot tell a future question tool from a future approval tool by shape.
    ("unknown tool with a name", "claude-code", {"tool_name": "SomeFutureTool"}, True),
]

# Both extractor paths matter: only macOS 15+ preinstalls jq, so the python3
# fallback is what most machines actually run. The unreadable cases matter most
# here, since that is where the two paths could disagree.
# Selected by name, not by index: `CASES[0], CASES[3], CASES[6]` silently
# re-aimed at different rows the moment anything was inserted above them,
# dropping the unreadable-payload coverage this set exists for.
_NO_JQ_NAMES = ("bash approval", "AskUserQuestion", "tool_name absent",
                "tool_name is a number")
NO_JQ_CASES = [case for case in CASES if case[0] in _NO_JQ_NAMES]
# A raise, not an assert: `python3 -O` strips asserts, and a guard that can be
# optimised away is a guard that silently stops guarding.
if len(NO_JQ_CASES) != len(_NO_JQ_NAMES):
    raise SystemExit("no-jq selection missed a name: %s"
                     % (set(_NO_JQ_NAMES) - {case[0] for case in CASES}))

# agent, what the panel writes to the FIFO, decision the hook prints (None = no
# output). allow and deny are the control: they prove a reply reaches the hook,
# so an empty stdout on release is the hook letting go, not one that never read.
REPLY_CASES = [
    ("claude-code", "allow", "allow"),
    ("claude-code", "deny", "deny"),
    ("claude-code", "release", None),
    ("codex", "allow", "allow"),
    ("codex", "deny", "deny"),
    ("codex", "release", None),
]

# Written out rather than derived from len(CASES), which would fall with the
# table it is meant to guard: deleting a row would quietly lower the
# expectation too, and the run would stay green. Adding a case means changing
# this number on purpose, which is the point.
#
# 13 table cases + 4 no-jq repeats + 6 FIFO replies + 2 that assert on the
# process as well as the payload (the timing case and the broken-jq question)
# + 1 that asserts on the posted button alone (the broken-jq approval — it pins
# that the fallback keeps the button, and deliberately does not wait out the
# FIFO).
EXPECTED_CASE_COUNT = 26


def _link_system_bins(target, skip=("jq",)):
    shutil.rmtree(target, ignore_errors=True)
    os.makedirs(target)
    for source_dir in ("/bin", "/usr/bin", "/usr/sbin", "/sbin"):
        if not os.path.isdir(source_dir):
            continue
        for entry in os.listdir(source_dir):
            if entry in skip:
                continue
            link = os.path.join(target, entry)
            if not os.path.exists(link):
                os.symlink(os.path.join(source_dir, entry), link)


def build_nojq_path():
    """A PATH holding everything the hook needs except jq."""
    _link_system_bins(NOJQ_BIN)


def build_badjq_path():
    """A PATH whose jq exists but exits non-zero on every input.

    This is the reachable trigger for the whole change. jq is tried first and,
    before the fix beside it in hook_json_field, a jq that failed returned the
    same empty string as "field absent" — so a broken jq made every permission
    event unclassifiable, and unclassifiable meant block.
    """
    _link_system_bins(BADJQ_BIN)
    fake = os.path.join(BADJQ_BIN, "jq")
    with open(fake, "w", encoding="utf-8") as handle:
        handle.write('#!/bin/sh\necho "jq: error" >&2\nexit 5\n')
    os.chmod(fake, 0o755)


def run_hook(agent, payload_overrides, without_jq, path_override=None,
             capture_stdout=False):
    """Run one permission hook.

    Returns (posted payload or None, hook process, home, started). `started` is
    taken before the hook is spawned: a caller timing the run must not clock
    from after the panel post, which already waited for it.
    """
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
    for key, value in payload_overrides.items():
        if value is None:
            payload.pop(key, None)
        else:
            payload[key] = value

    env = dict(os.environ, HOME=home, TMPDIR=home)
    if path_override:
        env["PATH"] = path_override
    elif without_jq:
        env["PATH"] = NOJQ_BIN

    started = time.time()
    hook = subprocess.Popen(
        [NOTIFY, agent, "permission"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE if capture_stdout else subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        env=env,
    )
    hook.stdin.write(json.dumps(payload).encode())
    hook.stdin.close()

    listener.join(timeout=POST_TIMEOUT_S)
    server.close()

    parsed = None
    if "payload" in received:
        try:
            parsed = json.loads(received["payload"])
        except ValueError:
            parsed = {"<unparseable>": received["payload"][:120]}

    return parsed, hook, home, started


def finish(hook, home):
    hook.kill()
    hook.wait()
    shutil.rmtree(home, ignore_errors=True)


def run_case(name, agent, payload_overrides, expected, without_jq=False):
    posted, hook, home, _ = run_hook(agent, payload_overrides, without_jq)
    finish(hook, home)
    actual = posted.get("has_action_button") if posted else None
    passed = actual == expected
    print("%-4s %-38s blockable expected=%-5r actual=%r"
          % ("PASS" if passed else "FAIL",
             name + (" [no jq]" if without_jq else ""), expected, actual))
    return passed


def run_badjq_case():
    """A broken jq must not put a question on the FIFO path.

    The payload is well formed and names AskUserQuestion; only the parser is
    broken. Before the fix the hook could not read tool_name, so the question
    gate missed it and the FIFO was created — offering an Allow that would
    answer the question with a default, and holding the hook for 550s.
    Asserts on the process as well as the button, since the hook outliving the
    answer is the half that nags.
    """
    posted, hook, home, _ = run_hook(
        "claude-code",
        {"tool_name": "AskUserQuestion",
         "tool_input": {"questions": [{"question": "Tabs or spaces?"}]}},
        False,
        path_override=BADJQ_BIN,
    )
    try:
        hook.wait(timeout=EXIT_TIMEOUT_S)
        exited = True
    except subprocess.TimeoutExpired:
        exited = False
    blockable = posted.get("has_action_button") if posted else None
    finish(hook, home)

    passed = exited and blockable is False
    print("%-4s %-38s exited=%-5r blockable=%r"
          % ("PASS" if passed else "FAIL", "broken jq keeps a question off the FIFO",
             exited, blockable))
    return passed


def run_badjq_approval_case():
    """A broken jq must not cost an ordinary approval its Allow button.

    This is what hook_json_field's python3 fallback buys that the gate alone
    does not. With the gate fix but no fallback, a broken jq makes every
    permission event unclassifiable, so the banner still shows but nothing can
    be approved from it. With the fallback, tool_name resolves and the event is
    blockable again.
    """
    posted, hook, home, _ = run_hook("claude-code", {}, False, path_override=BADJQ_BIN)
    blockable = posted.get("has_action_button") if posted else None
    finish(hook, home)

    passed = blockable is True
    print("%-4s %-38s blockable expected=%-5r actual=%r"
          % ("PASS" if passed else "FAIL", "broken jq keeps an approval's button",
             True, blockable))
    return passed


def run_timing_case():
    """An unclassifiable payload must let the hook EXIT, not just drop the button.

    has_action_button is the visible half of the decision; the FIFO wait is the
    half that costs 550s. A regression could restore the wait while still
    reporting has_action_button=false, so assert on the process, not the payload.
    """
    posted, hook, home, started = run_hook("claude-code", {"tool_name": None}, False)
    try:
        hook.wait(timeout=EXIT_TIMEOUT_S)
        exited = True
    except subprocess.TimeoutExpired:
        exited = False
    elapsed = time.time() - started
    finish(hook, home)

    passed = exited and posted is not None
    print("%-4s %-38s exited=%-5r after %.1fs (banner posted=%r)"
          % ("PASS" if passed else "FAIL", "unreadable payload does not block",
             exited, elapsed, posted is not None))
    return passed


def write_reply(fifo, reply):
    """Write a reply once the hook has opened its end of the FIFO.

    The banner is posted before the hook opens the FIFO to read, so the first
    open can find no reader (ENXIO) and is retried. False if it never could.
    """
    deadline = time.time() + EXIT_TIMEOUT_S
    while True:
        try:
            fd = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError as error:
            if error.errno != errno.ENXIO or time.time() > deadline:
                return False
            time.sleep(0.05)
    try:
        os.write(fd, (reply + "\n").encode())
    finally:
        os.close(fd)
    return True


def run_reply_case(agent, reply, expected):
    """What the hook prints for each reply the panel can write.

    Asserts on the process as well as stdout: a release the hook ignored would
    leave it waiting out the FIFO, which is the stall release exists to end.
    """
    posted, hook, home, _ = run_hook(agent, {}, False, capture_stdout=True)
    fifo = posted.get("fifo_path") if posted else None
    exited, output = False, ""
    if fifo and write_reply(fifo, reply):
        try:
            stdout, _ = hook.communicate(timeout=EXIT_TIMEOUT_S)
            exited, output = True, stdout.decode().strip()
        except subprocess.TimeoutExpired:
            pass
    finish(hook, home)

    decision = None
    if output:
        try:
            decision = json.loads(output)["hookSpecificOutput"]["decision"]["behavior"]
        except (ValueError, KeyError, TypeError):
            decision = "<unparseable: %r>" % output[:60]
    passed = exited and decision == expected
    print("%-4s %-38s exited=%-5r decision=%r"
          % ("PASS" if passed else "FAIL", "%s replies %s" % (agent, reply),
             exited, decision))
    return passed


def main():
    if sys.platform != "darwin":
        print("skipped: notify.sh only posts to the panel on macOS")
        return 0

    if not os.access(NOTIFY, os.X_OK):
        print("FAIL no executable notify.sh at %s" % NOTIFY)
        return 1

    build_nojq_path()
    build_badjq_path()
    try:
        results = [run_case(*case) for case in CASES]
        results += [run_case(*case, without_jq=True) for case in NO_JQ_CASES]
        results += [run_reply_case(*case) for case in REPLY_CASES]
        results.append(run_timing_case())
        results.append(run_badjq_case())
        results.append(run_badjq_approval_case())
    finally:
        shutil.rmtree(_FAKE_BIN_ROOT, ignore_errors=True)

    # A case silently dropped from the table would make a green run mean less
    # than it appears to, so assert the count as well as the results.
    if len(results) != EXPECTED_CASE_COUNT:
        print("\nFAIL ran %d cases, expected %d" % (len(results), EXPECTED_CASE_COUNT))
        return 1

    print("\n%d/%d passed" % (sum(results), len(results)))
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
