"""Shared by install.sh's per-agent hook blocks (HOOK_MANIFEST and HOOK_AGENT
come from the environment). The app does the same in HookManifest.swift; keep
the two in step."""
import json
import os
import re
import shlex

# Match any prior stack-nudge / tinynudge entry regardless of where it was
# installed (legacy ~/.tinynudge, moved checkouts, etc.), quoted or not, so
# upgrades replace the stale entry instead of appending a duplicate.
STALE = re.compile(r"(?:^|/)\.?(?:tinynudge|stack-nudge)/notify\.sh['\"]?(?:\s|$)")


def manifest_hooks():
    # This version's hooks for the agent, from hook-manifest.json: the same
    # list the app reconciles against at launch.
    with open(os.environ["HOOK_MANIFEST"]) as f:
        spec = json.load(f)["agents"][os.environ["HOOK_AGENT"]]
    return [(h["event"], h["arg"], h.get("timeout")) for h in spec["hooks"]]


APPLIED = os.path.expanduser("~/.stack-nudge/hooks-applied.json")


def manifest_version():
    with open(os.environ["HOOK_MANIFEST"]) as f:
        return json.load(f)["version"]


def read_applied():
    try:
        with open(APPLIED) as f:
            record = json.load(f)
        return record if isinstance(record, dict) and isinstance(record.get("agents"), dict) else {}
    except Exception:
        return {}


def dropped_events():
    # Events an earlier version applied (the app's hooks-applied.json) that
    # this manifest no longer lists: ours to remove. An older manifest than the
    # one last applied leaves them alone, as the app does.
    record = read_applied()
    if record.get("manifest_version", 0) > manifest_version():
        return []
    applied = record.get("agents", {}).get(os.environ["HOOK_AGENT"], [])
    current = {event for event, _, _ in manifest_hooks()}
    return [e for e in applied if isinstance(e, str) and e not in current]


def ours_exactly(command):
    # Only our exact form, `<installed notify.sh> <agent> <arg>`, under a dropped
    # event: a wrapper or a checkout wired by hand is the user's, as in the app.
    with open(os.environ["HOOK_MANIFEST"]) as f:
        agent_arg = json.load(f)["agents"][os.environ["HOOK_AGENT"]]["agent_arg"]
    try:
        words = shlex.split(command or "")
    except ValueError:
        return False
    return (len(words) == 3 and words[1] == agent_arg
            and re.search(r"(?:^|/)\.(?:tinynudge|stack-nudge)/notify\.sh$", words[0]) is not None)


def record_applied():
    # Tell the app which events are now ours, so it doesn't read what this
    # script added or removed as the user's hand edits.
    record = read_applied()
    if record.get("manifest_version", 0) > manifest_version():
        return
    record.setdefault("agents", {})[os.environ["HOOK_AGENT"]] = sorted(e for e, _, _ in manifest_hooks())
    record["manifest_version"] = manifest_version()
    os.makedirs(os.path.dirname(APPLIED), exist_ok=True)
    tmp = APPLIED + ".tmp"
    with open(tmp, "w") as f:
        json.dump(record, f, indent=2, sort_keys=True)
    os.replace(tmp, APPLIED)
