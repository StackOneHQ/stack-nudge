#!/usr/bin/env python3
"""Tests for the Away service extension.

Run them with `scripts/test-extensions.sh`, which is what CI does.

Away is Swift, because it needs CoreBluetooth, so most of what's worth testing
lives in the program itself: `away --self-test` replays recorded advertisement
timings through the presence rule and exits non-zero on a failure. These tests
build it and run that, check the line protocol without starting a Bluetooth
scan, and check the launcher fails cleanly where it can't build.

The Swift parts need macOS and are skipped elsewhere (CI validates extensions
on Linux). The launcher and manifest tests run everywhere.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
ON_MAC = sys.platform == "darwin"


def build(into):
    """Compiles away.swift the way ./run does, into a scratch directory, so a
    test never leaves a build behind in the extension itself."""
    binary = pathlib.Path(into) / "away"
    subprocess.run(["swiftc", "-O", str(HERE / "away.swift"), "-o", str(binary)],
                   check=True, capture_output=True, timeout=300)
    return binary


@unittest.skipUnless(ON_MAC and shutil.which("swiftc"), "needs macOS and swiftc")
class Program(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.mkdtemp(prefix="away-test-")
        cls.binary = build(cls.scratch)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.scratch, ignore_errors=True)

    def test_the_presence_rule_passes_its_self_test(self):
        # The desk recording (gaps of 66 and 75 s, readings down to -99) never
        # counts as away, even at the shortest silence; the configured silence
        # while idle does; a -72 advert brings you back and a -85 one doesn't;
        # a phone gone for good locks once; waking from sleep doesn't lock;
        # two devices with the phone's name bind to neither; names compare
        # loosely; the phone row reads as a signal. See selfTest() in away.swift.
        result = subprocess.run([str(self.binary), "--self-test"],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("away self-test: ok", result.stdout)

    def test_before_hello_it_answers_pings_skips_unknown_types_and_stops(self):
        # No hello, so no Bluetooth scan starts: this is the protocol alone.
        lines = [
            {"type": "something-from-a-newer-host", "x": 1},
            {"type": "ping", "id": 17},
            {"type": "stop"},
        ]
        result = subprocess.run(
            [str(self.binary)],
            input="".join(json.dumps(line) + "\n" for line in lines),
            capture_output=True, text=True, timeout=10, env={"PATH": "/usr/bin:/bin"})
        self.assertEqual(result.returncode, 0)
        # Nothing but protocol lines on stdout, and nothing before `ready`
        # except the pong the host asked for.
        out = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(out, [{"type": "pong", "id": 17}])

    def test_it_exits_when_the_host_closes_stdin(self):
        result = subprocess.run([str(self.binary)], input="", capture_output=True,
                                text=True, timeout=10, env={"PATH": "/usr/bin:/bin"})
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


class Launcher(unittest.TestCase):

    def test_without_swiftc_it_fails_with_a_reason_and_prints_nothing(self):
        # A copy with no build in it, and a PATH with nothing on it, so the
        # launcher has to build and can't. The supervisor marks it broken; what
        # matters here is that stdout stays empty, since the host would read
        # anything there as a protocol line.
        with tempfile.TemporaryDirectory() as scratch:
            copy = pathlib.Path(scratch) / "away"
            copy.mkdir()
            for name in ("run", "away.swift", "manifest.json"):
                shutil.copy2(HERE / name, copy / name)
            empty = pathlib.Path(scratch) / "empty-path"
            empty.mkdir()
            result = subprocess.run(["/bin/bash", str(copy / "run")], cwd=copy,
                                    capture_output=True, text=True, timeout=10,
                                    env={"PATH": str(empty)})
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("swiftc", result.stderr)
            self.assertFalse((copy / ".build" / "away").exists())


class Manifest(unittest.TestCase):

    def setUp(self):
        with open(HERE / "manifest.json") as fh:
            self.manifest = json.load(fh)

    def test_it_is_a_service_asking_only_for_what_it_uses(self):
        self.assertEqual(self.manifest["schema"], 2)
        self.assertEqual(self.manifest["mode"], "service")
        self.assertEqual(sorted(self.manifest["capabilities"]), ["bluetooth", "signal:presence"])

    def test_it_lives_in_settings_with_typed_config(self):
        # Set and forget, so a Settings page rather than a tab, and its keys
        # are controls: the phone from what the service offers, the two waits
        # from fixed lists that keep the silence above the 75 s an idle phone
        # was measured going quiet.
        self.assertEqual(self.manifest["surfaces"], ["settings"])
        kinds = {entry["key"]: entry for entry in self.manifest["config"]}
        self.assertEqual(kinds["STACKNUDGE_EXT_AWAY_PHONE"]["type"], "dynamic")
        idle, silence = kinds["STACKNUDGE_EXT_AWAY_IDLE"], kinds["STACKNUDGE_EXT_AWAY_SILENCE"]
        self.assertEqual((idle["type"], idle["unit"]), ("number", "seconds"))
        self.assertIn(idle["default"], idle["options"])
        self.assertIn(silence["default"], silence["options"])
        self.assertGreaterEqual(min(silence["options"]), 90)

    def test_its_config_keys_are_the_ones_the_program_reads(self):
        keys = [entry["key"] for entry in self.manifest["config"]]
        self.assertEqual(keys, ["STACKNUDGE_EXT_AWAY_PHONE", "STACKNUDGE_EXT_AWAY_IDLE",
                                "STACKNUDGE_EXT_AWAY_SILENCE"])
        source = (HERE / "away.swift").read_text()
        for key in keys:
            self.assertIn('"%s"' % key, source)

    def test_its_tier_is_recorded_for_review(self):
        # Away can't do its job below `trusted`: bluetooth and presence are
        # both trusted capabilities. The tier lives in the reviewer-owned
        # extensions/tiers.json rather than here, so it can't promote itself.
        tiers_path = HERE.parent / "tiers.json"
        if not tiers_path.exists():
            self.skipTest("not in a checkout of the extensions repository")
        with open(tiers_path) as fh:
            self.assertEqual(json.load(fh).get("away"), "trusted")


if __name__ == "__main__":
    unittest.main()
