#!/usr/bin/env python3
"""Tests for scripts/hook_wiring.py, the install.sh side of hook reconciling.

It's the code that deletes entries from people's agent configs, so every case
that must *not* be deleted is spelled out. Runs anywhere python3 does; each
case gets its own temporary HOME and manifest.
"""
import atexit
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MANIFEST = {"version": 2, "agents": {
    "claude": {"agent_arg": "claude-code", "shape": "matcher-groups", "hooks": [
        {"event": "Stop", "arg": "stop", "timeout": 30},
        {"event": "PermissionRequest", "arg": "permission", "timeout": 600}]},
    "cursor": {"agent_arg": "cursor", "shape": "flat", "hooks": [{"event": "stop", "arg": "stop"}]},
}}
OURS = "/Users/me/.stack-nudge/notify.sh"


def fresh(agent="claude", record=None, manifest=MANIFEST):
    """A new HOME with an optional hooks-applied.json; returns hook_wiring reloaded against it."""
    home = tempfile.mkdtemp(prefix="hook-wiring-test-")
    atexit.register(shutil.rmtree, home, True)
    os.makedirs(os.path.join(home, ".stack-nudge"))
    path = os.path.join(home, "manifest.json")
    with open(path, "w") as f:
        json.dump(manifest, f)
    if record is not None:
        with open(os.path.join(home, ".stack-nudge", "hooks-applied.json"), "w") as f:
            f.write(record if isinstance(record, str) else json.dumps(record))
    os.environ.update(HOME=home, HOOK_MANIFEST=path, HOOK_AGENT=agent)
    sys.modules.pop("hook_wiring", None)
    import hook_wiring
    return hook_wiring


def group(command):
    return {"matcher": "", "hooks": [{"type": "command", "command": command}]}


def commands(hooks, event):
    return [h.get("command") for g in hooks.get(event, []) for h in (g.get("hooks") or [g])]


results = []


def check(name, actual, expected):
    passed = actual == expected
    results.append(passed)
    print("%-4s %-52s %s" % ("PASS" if passed else "FAIL", name, "" if passed else "expected=%r actual=%r" % (expected, actual)))


# ours_exactly: our exact form only.
w = fresh()
for command, expected in [
    (OURS + " claude-code stop", True),
    (OURS + " claude-code session-start", True),
    ("/Users/me/.tinynudge/notify.sh claude-code stop", True),
    ("'/Users/Jo Smith/.stack-nudge/notify.sh' claude-code stop", True),
    (OURS + " claude-code stop 2>/dev/null", False),
    (OURS + " claude-code stop>>/tmp/log", False),
    (OURS + " claude-code stop&&say", False),
    ("FOO=1 " + OURS + " claude-code stop", False),
    ("bash -c '" + OURS + " claude-code stop; say done'", False),
    ("/Users/me/.stack-nudge/notify.sh.bak claude-code stop", False),
    ("/Users/me/src/stack-nudge/notify.sh claude-code stop", False),
    (OURS + " codex stop", False),
    (OURS + " claude-code", False),
    ("'unterminated " + OURS + " claude-code stop", False),
    (None, False),
    (7, False),
]:
    check("ours_exactly(%r)" % (command,), w.ours_exactly(command), expected)

# read_applied: anything but the app's shape reads as nothing applied.
for name, record, expected in [
    ("record missing", None, {}),
    ("record not JSON", "{", {}),
    ("record a list", [1], {}),
    ("record version a string", {"manifest_version": "2", "agents": {}}, {}),
    ("record version a bool", {"manifest_version": True, "agents": {}}, {}),
    ("record agents a list", {"manifest_version": 1, "agents": []}, {}),
    ("record keeps only string events",
     {"manifest_version": 1, "agents": {"claude": ["Stop", 5, None], "cursor": "stop"}},
     {"manifest_version": 1, "agents": {"claude": ["Stop"]}}),
]:
    check(name, fresh(record=record).read_applied(), expected)

# dropped_events: applied before, not in this manifest, and not from a newer one.
applied = {"manifest_version": 1, "agents": {"claude": ["Stop", "PermissionRequest", "SessionEnd"]}}
check("dropped: one event", fresh(record=applied).dropped_events(), ["SessionEnd"])
check("dropped: newer record leaves them alone",
      fresh(record=dict(applied, manifest_version=3)).dropped_events(), [])
check("dropped: no record", fresh().dropped_events(), [])

# prune_dropped: only our exact form goes, everything else stays as it was.
w = fresh(record=applied)
hooks = {
    "SessionEnd": [group(OURS + " claude-code session-end"),
                   group(OURS + " claude-code session-end 2>/dev/null"),
                   group("/Users/me/.stack-nudge/notify.sh.bak claude-code session-end"),
                   {"matcher": "", "hooks": [{"command": OURS + " claude-code session-end"}, {"command": "keep"}]},
                   "a string", {"matcher": "", "hooks": "x"}, {"hooks": [5, {"command": 7}]}],
    "SubagentStop": [group(OURS + " claude-code stop")],
}
w.prune_dropped(hooks)
check("prune: wrappers, .bak and odd shapes kept", hooks["SessionEnd"], [
    group(OURS + " claude-code session-end 2>/dev/null"),
    group("/Users/me/.stack-nudge/notify.sh.bak claude-code session-end"),
    {"matcher": "", "hooks": [{"command": "keep"}]},
    "a string", {"matcher": "", "hooks": "x"}, {"hooks": [5, {"command": 7}]}])
check("prune: never-applied event untouched", commands(hooks, "SubagentStop"), [OURS + " claude-code stop"])
hooks = {"SessionEnd": [group(OURS + " claude-code session-end")]}
w.prune_dropped(hooks)
check("prune: emptied event removed", hooks, {})

w = fresh("cursor", record={"manifest_version": 1, "agents": {"cursor": ["stop", "beforeSubmitPrompt"]}})
hooks = {"beforeSubmitPrompt": [{"command": OURS + " cursor prompt"}, {"command": "keep"}, 3]}
w.prune_dropped(hooks)
check("prune: Cursor's flat entries", hooks, {"beforeSubmitPrompt": [{"command": "keep"}, 3]})

# record_applied: written for this agent, never over a newer manifest's record.
w = fresh(record={"manifest_version": 1, "agents": {"cursor": ["stop"]}})
w.record_applied()
check("record: updated", w.read_applied(),
      {"manifest_version": 2, "agents": {"claude": ["PermissionRequest", "Stop"], "cursor": ["stop"]}})
newer = {"manifest_version": 3, "agents": {"claude": ["SessionStart", "Stop"]}}
w = fresh(record=newer)
w.record_applied()
check("record: a newer one is left alone", w.read_applied(), newer)

# prune_for_uninstall: broad under the manifest's events, exact elsewhere.
w = fresh()
wrapper = "bash -c '" + OURS + " claude-code stop; say done'"
hooks = {
    "Stop": [group(OURS + " claude-code stop"), group(wrapper), group("keep")],
    "PreToolUse": [group(wrapper), group("/Users/me/.stack-nudge/notify.sh.bak claude-code stop"),
                   group("/Users/me/src/stack-nudge/notify.sh claude-code stop"), group(OURS + " claude-code future")],
}
check("uninstall: reports a change", w.prune_for_uninstall(hooks), True)
check("uninstall: broad under a manifest event", commands(hooks, "Stop"), ["keep"])
check("uninstall: exact elsewhere", commands(hooks, "PreToolUse"),
      [wrapper, "/Users/me/.stack-nudge/notify.sh.bak claude-code stop", "/Users/me/src/stack-nudge/notify.sh claude-code stop"])
check("uninstall: nothing of ours is no change", w.prune_for_uninstall({"PreToolUse": [group("keep")]}), False)
w = fresh("cursor")
hooks = {"stop": [{"command": OURS + " cursor stop"}, {"command": "keep"}]}
w.prune_for_uninstall(hooks)
check("uninstall: Cursor's flat entries", hooks, {"stop": [{"command": "keep"}]})
w = fresh()
os.environ["HOOK_MANIFEST"] = os.path.join(os.environ["HOME"], "missing.json")
hooks = {"Stop": [group(wrapper)], "PreToolUse": [group(OURS + " claude-code future"), group(wrapper)]}
w.prune_for_uninstall(hooks)
check("uninstall: no manifest falls back, without crashing", hooks, {"PreToolUse": [group(wrapper)]})

# The installed path is quoted exactly as the app quotes it (HookReconciler.shellQuoted).
import shlex
for path, expected in [("/Users/me/.stack-nudge/notify.sh", "/Users/me/.stack-nudge/notify.sh"),
                       ("/Users/a@b%c/x", "/Users/a@b%c/x"),
                       ("", "''"),
                       ("/Users/Jo Smith/x", "'/Users/Jo Smith/x'")]:
    check("shlex.quote(%r)" % path, shlex.quote(path), expected)

EXPECTED = 42
if len(results) != EXPECTED:
    print("\nFAIL ran %d cases, expected %d" % (len(results), EXPECTED))
    sys.exit(1)
print("\n%d/%d passed" % (sum(results), len(results)))
sys.exit(0 if all(results) else 1)
