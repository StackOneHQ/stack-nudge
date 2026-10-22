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
    # Anything but the shape the app writes reads as "nothing applied yet", as
    # in the app; this record must never be what stops an install.
    try:
        with open(APPLIED) as f:
            record = json.load(f)
    except Exception:
        return {}
    if not isinstance(record, dict):
        return {}
    version = record.get("manifest_version", 0)
    agents = record.get("agents")
    if not isinstance(version, int) or isinstance(version, bool) or not isinstance(agents, dict):
        return {}
    return {"manifest_version": version,
            "agents": {k: [e for e in v if isinstance(e, str)]
                       for k, v in agents.items() if isinstance(k, str) and isinstance(v, list)}}


def dropped_events():
    # Events an earlier version applied (the app's hooks-applied.json) that
    # this manifest no longer lists: ours to remove. An older manifest than the
    # one last applied leaves them alone, as the app does.
    record = read_applied()
    if record.get("manifest_version", 0) > manifest_version():
        return []
    applied = record.get("agents", {}).get(os.environ["HOOK_AGENT"], [])
    current = {event for event, _, _ in manifest_hooks()}
    return [e for e in applied if e not in current]


def manifest_agent_arg():
    # The agent's notify.sh arg, from the manifest; without one (uninstall.sh
    # from a partial checkout) the arg every version has used.
    agent = os.environ["HOOK_AGENT"]
    try:
        with open(os.environ["HOOK_MANIFEST"]) as f:
            return json.load(f)["agents"][agent]["agent_arg"]
    except Exception:
        return "claude-code" if agent == "claude" else agent


def ours_exactly(command):
    # Only our exact form, `<installed notify.sh> <agent> <arg>`, under a dropped
    # event: a wrapper or a checkout wired by hand is the user's, as in the app.
    agent_arg = manifest_agent_arg()
    if not isinstance(command, str):
        return False
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    # The arg must be a plain word: shlex keeps `stop>>/tmp/log` as one word.
    return (len(words) == 3 and words[1] == agent_arg
            and re.fullmatch(r"[A-Za-z0-9_-]+", words[2]) is not None
            and re.search(r"(?:^|/)\.(?:tinynudge|stack-nudge)/notify\.sh$", words[0]) is not None)


def prune_dropped(hooks):
    """Removes our exact-form commands from the events dropped_events() names,
    in place, for both shapes: matcher groups ({matcher, hooks: [...]}) and
    Cursor's flat entries. Anything of a shape we don't know is kept as is."""
    for event in dropped_events():
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        cleaned = []
        for entry in entries:
            if not isinstance(entry, dict):
                cleaned.append(entry)
            elif "hooks" in entry:
                inner = entry["hooks"]
                if not isinstance(inner, list):
                    cleaned.append(entry)
                    continue
                kept = [h for h in inner if not (isinstance(h, dict) and ours_exactly(h.get("command")))]
                if kept:
                    cleaned.append(entry if kept == inner else {**entry, "hooks": kept})
            elif not ours_exactly(entry.get("command")):
                cleaned.append(entry)
        if cleaned:
            hooks[event] = cleaned
        else:
            del hooks[event]


# What uninstall always stripped broadly, for a checkout without a manifest.
LEGACY_EVENTS = {"Stop", "PermissionRequest", "AfterAgent", "Notification", "stop"}
UNINSTALL_STALE = re.compile(r'(?:^|/|")\.?(?:tinynudge|stack-nudge)/notify\.sh')


def prune_for_uninstall(hooks):
    """uninstall.sh, matching the app's uninstall: under the manifest's events
    every entry the stale-path regex matches goes, as it always has; under any
    other event only our exact form does. Returns True if anything changed."""
    try:
        broad = {event for event, _, _ in manifest_hooks()}
    except Exception:
        broad = LEGACY_EVENTS
    changed = False
    for event in list(hooks):
        entries = hooks[event]
        if not isinstance(entries, list):
            continue

        def ours(command):
            if event in broad:
                return isinstance(command, str) and UNINSTALL_STALE.search(command) is not None
            return ours_exactly(command)

        cleaned = []
        for entry in entries:
            if not isinstance(entry, dict):
                cleaned.append(entry)
            elif "hooks" in entry:
                inner = entry["hooks"]
                if not isinstance(inner, list):
                    cleaned.append(entry)
                    continue
                kept = [h for h in inner if not (isinstance(h, dict) and ours(h.get("command")))]
                if kept:
                    cleaned.append(entry if kept == inner else {**entry, "hooks": kept})
            elif not ours(entry.get("command")):
                cleaned.append(entry)
        if cleaned != entries:
            changed = True
            if cleaned:
                hooks[event] = cleaned
            else:
                del hooks[event]
    return changed


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
