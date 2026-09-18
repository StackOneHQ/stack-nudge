#!/usr/bin/env python3
"""Tests for the Token Derby extension.

Run them with `python3 -m unittest discover extensions`, which is what CI does.

They ship inside the package on purpose. This and `system` are the two
extensions people read when writing their own, and "how do I test one of
these?" is a question the reference should answer rather than leave to taste.

Everything here is offline. The two functions that touch the network are the
two that aren't tested; everything they hand off to is pure and is.
"""

import importlib.machinery
import importlib.util
import json
import pathlib
import unittest

# The executable has no .py extension — the host runs it by path, not by
# import — so it is loaded explicitly rather than found on sys.path.
_PATH = pathlib.Path(__file__).with_name("run")
_LOADER = importlib.machinery.SourceFileLoader("derby_run", str(_PATH))
_SPEC = importlib.util.spec_from_loader(_LOADER.name, _LOADER)
derby = importlib.util.module_from_spec(_SPEC)
_LOADER.exec_module(derby)


class Formatting(unittest.TestCase):
    """Both mirror a Swift helper the panel uses for its own tabs. A Derby row
    that abbreviated differently from the Usage tab beside it would read as two
    apps sharing one panel."""

    def test_token_counts_abbreviate_like_the_panel_does(self):
        self.assertEqual(derby.short_tokens(42), "42")
        self.assertEqual(derby.short_tokens(999), "999")
        self.assertEqual(derby.short_tokens(1000), "1K")
        self.assertEqual(derby.short_tokens(218_000), "218K")
        self.assertEqual(derby.short_tokens(1_250_000), "1.2M")
        # A half-token double is a real value from this API, not a typo.
        self.assertEqual(derby.short_tokens(1500.5), "2K")

    # Half rounds *away from zero*, matching Swift's Double.rounded(). Python's
    # round() is half-to-even, so every x500 with an even thousands part
    # disagreed — and 1500, the only boundary the first version of this test
    # checked, is the one where the two happen to agree.
    def test_the_K_branch_rounds_half_away_from_zero(self):
        self.assertEqual(derby.short_tokens(2500), "3K")
        self.assertEqual(derby.short_tokens(4500), "5K")
        self.assertEqual(derby.short_tokens(6500), "7K")
        self.assertEqual(derby.short_tokens(1500), "2K")
        self.assertEqual(derby.short_tokens(3500), "4K")

    def test_countdowns_abbreviate_like_the_panel_does(self):
        self.assertEqual(derby.short_countdown(20_700), "5h45m")
        self.assertEqual(derby.short_countdown(7200), "2h")
        self.assertEqual(derby.short_countdown(180_000), "2d2h")
        self.assertEqual(derby.short_countdown(172_800), "2d")
        self.assertEqual(derby.short_countdown(720), "12m")

    def test_a_countdown_that_has_run_out_is_absent_rather_than_zero(self):
        # "0m" reads as a stopped clock; sub-minute is genuinely about to end.
        self.assertEqual(derby.short_countdown(30), "1m")
        self.assertIsNone(derby.short_countdown(0))
        self.assertIsNone(derby.short_countdown(-5))


class Colour(unittest.TestCase):

    def test_hex_parsing_accepts_both_lengths(self):
        self.assertEqual(derby.parse_hex("#ff0000"), (255, 0, 0))
        self.assertEqual(derby.parse_hex("#f00"), (255, 0, 0))
        self.assertEqual(derby.parse_hex("  #AbCdEf "), (0xAB, 0xCD, 0xEF))

    def test_hex_parsing_rejects_everything_else(self):
        for raw in ["red", "#ff00", "#gggggg", "#", "", None, 7, []]:
            self.assertIsNone(derby.parse_hex(raw), raw)

    # Read loosely, write strictly. The host requires the hash and drops a bare
    # "ff0000" back to the accent colour, so a horse whose silks arrived
    # without one would quietly lose them.
    def test_a_colour_without_its_hash_is_read_and_then_written_back_with_one(self):
        self.assertEqual(derby.parse_hex("ff0000"), (255, 0, 0))
        self.assertEqual(derby.normalise_hex("ff0000"), "#FF0000")
        self.assertEqual(derby.normalise_hex("#f00"), "#FF0000")
        self.assertIsNone(derby.normalise_hex("red"))

    def test_the_mane_is_darker_than_the_coat(self):
        # Without this the mane is the same colour as the body and the horse is
        # a blob at 1.5pt a cell.
        self.assertEqual(derby.mane_for("#FFFFFF"), "#8C8C8C")

    # The field has real black horses in it, and #000000 shaded toward black is
    # still #000000 — which drew them as flat silhouettes with no mane.
    def test_a_coat_too_dark_to_darken_gets_a_lighter_mane_instead(self):
        self.assertNotEqual(derby.mane_for("#000000"), "#000000")
        self.assertEqual(derby.mane_for("#000000"), "#737373")
        for coat in ["#000000", "#101010", "#1A0A0A"]:
            self.assertNotEqual(derby.mane_for(coat), coat, coat)

    def test_shading_something_unparseable_leaves_it_alone(self):
        self.assertEqual(derby.mane_for("nonsense"), "nonsense")


class Numbers(unittest.TestCase):

    def test_token_counts_arrive_as_both_ints_and_floats(self):
        self.assertEqual(derby.number(5), 5.0)
        self.assertEqual(derby.number(5.5), 5.5)

    def test_a_missing_or_wrong_typed_count_falls_back(self):
        self.assertEqual(derby.number(None), 0.0)
        self.assertEqual(derby.number("12"), 0.0)
        self.assertEqual(derby.number(None, 3.0), 3.0)

    # json.loads accepts the bare literals Infinity, -Infinity and NaN, and
    # int(inf) raises rather than returning something wrong — so a server
    # sending one crashed the script instead of producing a document. A NaN
    # would also serialise back out as a bare NaN token, which the host's
    # JSONDecoder rejects.
    def test_a_non_finite_number_is_not_a_token_count(self):
        for value in [float("inf"), float("-inf"), float("nan")]:
            self.assertEqual(derby.number(value), 0.0, value)

    def test_a_bool_is_not_a_token_count(self):
        # True == 1 in Python, so a sloppy isinstance check draws a bar for it.
        self.assertEqual(derby.number(True), 0.0)
        self.assertEqual(derby.number(False), 0.0)


class Timestamps(unittest.TestCase):

    def test_the_services_own_stamp_parses(self):
        # It stamps milliseconds and a trailing Z.
        parsed = derby.parse_time("2026-09-18T08:00:00.000Z")
        self.assertIsNotNone(parsed)
        self.assertEqual(parsed.year, 2026)

    def test_a_stamp_without_fractional_seconds_parses_too(self):
        self.assertIsNotNone(derby.parse_time("2026-09-18T08:00:00Z"))
        self.assertIsNotNone(derby.parse_time("2026-09-18T08:00:00+00:00"))

    def test_an_unreadable_stamp_is_none_rather_than_a_crash(self):
        for raw in ["", None, "yesterday", "2026-13-45T99:99:99Z", 7]:
            self.assertIsNone(derby.parse_time(raw), raw)

    def test_duration_needs_both_ends_and_a_forward_direction(self):
        start, end = "2026-09-18T08:00:00Z", "2026-09-18T20:00:00Z"
        self.assertEqual(derby.duration_seconds(start, end), 43200)
        self.assertIsNone(derby.duration_seconds(end, start))
        self.assertIsNone(derby.duration_seconds(start, start))
        self.assertIsNone(derby.duration_seconds(start, None))


def race(status="live", **extra):
    base = {
        "join_code": "ABC",
        "name": "StackOne Token League",
        "status": status,
        "start_time": "2026-09-18T08:00:00.000Z",
        "end_time": "2026-09-18T20:00:00.000Z",
        "time_left_seconds": 21600,
        "league_division_names": ["Premier Division", "Second Division"],
        "horses": [],
    }
    base.update(extra)
    return base


def horse(id="h1", **extra):
    base = {"horse_id": id, "name": "black & white", "user_name": "Yashika",
            "rank": 1, "current_tokens": 1000, "scored_tokens": 900,
            "pace_15m": 36000, "division": 1, "colors": {"body": "#FFFFFF"}}
    base.update(extra)
    return base


class Picking(unittest.TestCase):
    """The same rule the derby's own site uses. An extension that picked a
    different race from the page it mirrors would read as stale data."""

    def test_a_live_race_wins(self):
        chosen = derby.pick([race("finished", join_code="OLD"), race("live", join_code="NOW")])
        self.assertEqual(chosen["join_code"], "NOW")

    def test_the_newest_live_race_wins(self):
        chosen = derby.pick([
            race("live", join_code="OLD", start_time="2026-09-01T08:00:00Z"),
            race("live", join_code="NEW", start_time="2026-09-18T08:00:00Z"),
        ])
        self.assertEqual(chosen["join_code"], "NEW")

    def test_with_nothing_live_the_most_recent_finish_wins(self):
        chosen = derby.pick([
            race("finished", join_code="OLD", start_time="2026-09-01T08:00:00Z"),
            race("finished", join_code="RECENT", start_time="2026-09-17T08:00:00Z"),
            race("pending", join_code="SOON", start_time="2026-09-19T08:00:00Z"),
        ])
        self.assertEqual(chosen["join_code"], "RECENT")

    def test_pending_races_sort_the_other_way(self):
        # A race that hasn't started is interesting for being next, not recent.
        chosen = derby.pick([
            race("pending", join_code="LATER", start_time="2026-10-01T08:00:00Z"),
            race("pending", join_code="SOON", start_time="2026-09-19T08:00:00Z"),
        ])
        self.assertEqual(chosen["join_code"], "SOON")

    def test_an_entry_without_a_join_code_is_not_a_race(self):
        self.assertIsNone(derby.pick([{"status": "live"}, "nonsense", None]))
        self.assertIsNone(derby.pick([]))


class Track(unittest.TestCase):

    def test_a_finished_race_is_fully_run_whatever_the_clock_says(self):
        self.assertEqual(derby.elapsed_fraction(race("finished", time_left_seconds=999)), 1.0)

    def test_a_pending_race_leaves_the_field_at_the_gate(self):
        self.assertEqual(derby.elapsed_fraction(race("pending")), 0.0)

    def test_a_live_race_runs_on_the_clock(self):
        # 12 hours long, 6 remaining.
        self.assertAlmostEqual(derby.elapsed_fraction(race("live")), 0.5)

    def test_a_live_race_with_an_unusable_clock_stays_at_the_gate(self):
        self.assertEqual(derby.elapsed_fraction(race("live", end_time=None)), 0.0)
        self.assertEqual(derby.elapsed_fraction(race("live", time_left_seconds=None)), 0.0)
        self.assertEqual(derby.elapsed_fraction(race("live", time_left_seconds=True)), 0.0)

    def test_the_clock_is_clamped_at_both_ends(self):
        self.assertEqual(derby.elapsed_fraction(race("live", time_left_seconds=99_999)), 0.0)
        self.assertEqual(derby.elapsed_fraction(race("live", time_left_seconds=-10)), 1.0)

    def test_position_scales_by_the_clock_and_not_just_by_the_leader(self):
        # Leader-relative alone pins the front-runner to the finish line from
        # the first minute, which makes a twelve-hour race look permanently
        # over. The leader's position *is* the race's progress.
        self.assertAlmostEqual(derby.position(100, 100, 0.5), 0.5)
        self.assertAlmostEqual(derby.position(50, 100, 0.5), 0.25)

    def test_a_race_nobody_has_scored_in_does_not_divide_by_zero(self):
        self.assertEqual(derby.position(0, 0, 0.5), 0.0)


class Scoring(unittest.TestCase):

    def test_the_bar_draws_what_the_race_is_ranked_on(self):
        # Drawing current_tokens instead put a 4th-placed horse's bar ahead of
        # 2nd's: the league discounts raw usage, so the two diverge.
        self.assertEqual(derby.scored(horse(current_tokens=1000, scored_tokens=900)), 900)

    def test_a_race_that_is_not_scoring_falls_back_to_raw_usage(self):
        entry = horse()
        del entry["scored_tokens"]
        self.assertEqual(derby.scored(entry), 1000)


class Document(unittest.TestCase):

    def build(self, **kwargs):
        return derby.document(race(**kwargs))

    def test_the_header_names_the_race_and_its_state(self):
        doc = self.build(horses=[horse()])
        self.assertEqual(doc["schema"], 1)
        self.assertEqual(doc["state"], "ok")
        self.assertEqual(doc["header"]["title"], "StackOne Token League")
        self.assertEqual(doc["header"]["badge"], {"text": "LIVE", "tone": "success"})
        self.assertEqual(doc["header"]["trailing"], "6h")

    def test_only_a_live_race_gets_a_countdown(self):
        self.assertNotIn("trailing", self.build(status="finished", horses=[horse()])["header"])
        self.assertEqual(self.build(status="pending", horses=[horse()])["header"]["badge"]["tone"],
                         "warning")

    def test_a_row_carries_every_field_the_built_in_tab_drew(self):
        row = self.build(horses=[horse()])["rows"][0]
        self.assertEqual(row["id"], "h1")
        self.assertEqual(row["lead"], "1")
        self.assertEqual(row["title"], "black & white")
        self.assertEqual(row["subtitle"], "Yashika")
        self.assertEqual(row["value"], "900")
        self.assertEqual(row["footnote"], "36K/15m · Premier Division")
        self.assertEqual(row["track"]["tint"], "#FFFFFF")

    def test_an_unranked_horse_still_lines_up_with_the_ranked_ones(self):
        self.assertEqual(self.build(horses=[horse(rank=None)])["rows"][0]["lead"], "–")

    def test_a_horse_with_no_colour_gets_the_default_coat(self):
        row = self.build(horses=[horse(colors=None)])["rows"][0]
        self.assertEqual(row["track"]["tint"], derby.DEFAULT_COAT)
        self.assertEqual(row["ornament"]["palette"]["H"], derby.DEFAULT_COAT)

    # Every colour the document carries has to be one the host will read back.
    def test_every_emitted_colour_is_in_the_form_the_host_accepts(self):
        doc = self.build(horses=[horse(colors={"body": "ff0000"}),
                                 horse("h2", colors={"body": "bogus"}),
                                 horse("h3", colors=None)])
        emitted = []
        for row in doc["rows"]:
            emitted.append(row["track"]["tint"])
            emitted.extend(row["ornament"]["palette"].values())
        for colour in emitted:
            self.assertIsNotNone(derby.parse_hex(colour), colour)
            self.assertTrue(colour.startswith("#"), colour)
            self.assertEqual(len(colour), 7, colour)

    def test_the_mane_differs_from_the_coat(self):
        for body in ["#FFFFFF", "#000000", "#7FD1B9"]:
            palette = self.build(
                horses=[horse(colors={"body": body})])["rows"][0]["ornament"]["palette"]
            self.assertNotEqual(palette["H"], palette["M"], body)

    def test_only_a_live_runner_burning_tokens_animates(self):
        # A finished race is a standings table, and a timeline that redraws a
        # row to show the same thing is the cost the compact widget already
        # learned to avoid.
        live = self.build(horses=[horse()])["rows"][0]["ornament"]
        self.assertEqual(live["fps"], 7)
        self.assertEqual(len(live["frames"]), 2)

        for still in (self.build(status="finished", horses=[horse()]),
                      self.build(horses=[horse(pace_15m=0)])):
            ornament = still["rows"][0]["ornament"]
            self.assertEqual(ornament["fps"], 0)
            self.assertEqual(len(ornament["frames"]), 1)

    def test_server_order_is_the_ranking(self):
        doc = self.build(horses=[horse("c", rank=3), horse("a", rank=1), horse("b", rank=2)])
        self.assertEqual([r["id"] for r in doc["rows"]], ["c", "a", "b"])

    def test_the_footnote_degrades_one_half_at_a_time(self):
        self.assertEqual(self.build(horses=[horse(pace_15m=0)])["rows"][0]["footnote"],
                         "Premier Division")
        self.assertEqual(self.build(horses=[horse(division=None)])["rows"][0]["footnote"],
                         "36K/15m")
        self.assertEqual(
            self.build(horses=[horse(pace_15m=0, division=99)])["rows"][0]["footnote"], "")

    def test_a_division_index_outside_the_names_is_dropped(self):
        # It is 1-based into league_division_names, and 0 is the off-by-one
        # this invites.
        self.assertEqual(derby.division_of(horse(division=0), ["Premier"]), None)
        self.assertEqual(derby.division_of(horse(division=1), ["Premier"]), "Premier")
        self.assertEqual(derby.division_of(horse(division=True), ["Premier"]), None)

    def test_an_entry_without_an_id_is_not_a_horse(self):
        doc = self.build(horses=[horse(), {"name": "nameless"}, "nonsense", None])
        self.assertEqual([r["id"] for r in doc["rows"]], ["h1"])

    def test_a_race_with_no_runners_says_so_rather_than_drawing_nothing(self):
        doc = self.build(horses=[])
        self.assertEqual(doc["state"], "empty")
        self.assertTrue(doc["message"])
        self.assertEqual(doc["rows"], [])

    def test_the_sync_action_is_bound_to_a_key_the_host_will_accept(self):
        # An action whose key request is refused has no shortcut and no button,
        # so it would be unreachable.
        action = self.build(horses=[horse()])["actions"][0]
        self.assertEqual(action["key"], "r")

    def test_a_race_carrying_a_non_finite_number_still_produces_a_document(self):
        doc = self.build(horses=[horse(scored_tokens=float("inf"),
                                       current_tokens=float("nan"),
                                       pace_15m=float("inf"))])
        self.assertEqual(doc["rows"][0]["value"], "0")
        # And it still round-trips: a bare NaN in the output is a blank pane.
        self.assertEqual(json.loads(json.dumps(doc)), doc)

    def test_the_whole_document_survives_a_json_round_trip(self):
        # The host reads one JSON object from stdout and nothing else. A value
        # json.dump refuses is a blank pane, not a wrong number.
        doc = self.build(horses=[horse(), horse("h2", rank=2, colors={"body": "#123"})])
        self.assertEqual(json.loads(json.dumps(doc)), doc)


class Sprite(unittest.TestCase):

    def test_both_frames_stay_inside_the_hosts_caps(self):
        # 32 frames x 24 rows x 64 columns, per docs/extensions.md.
        for frame in (derby.HORSE_STANDING, derby.HORSE_EXTENDED):
            self.assertLessEqual(len(frame), 24)
            self.assertTrue(all(len(row) <= 64 for row in frame))

    def test_the_two_frames_differ(self):
        # An animation whose frames are identical costs a timeline and buys
        # nothing.
        self.assertNotEqual(derby.HORSE_STANDING, derby.HORSE_EXTENDED)

    def test_every_frame_is_rectangular(self):
        # Ragged frames are legal — the host sizes from the largest — but a
        # ragged horse is a typo, not a design.
        for frame in (derby.HORSE_STANDING, derby.HORSE_EXTENDED):
            self.assertEqual(len({len(row) for row in frame}), 1, frame)

    def test_the_sprite_uses_only_palette_keys_it_declares(self):
        palette = set(derby.ornament_for("#FFFFFF", True)["palette"])
        for frame in (derby.HORSE_STANDING, derby.HORSE_EXTENDED):
            used = {c for row in frame for c in row if c != "."}
            self.assertTrue(used <= palette, used - palette)


class Base(unittest.TestCase):
    """The value comes from the user's own config file, so this is not a trust
    boundary — but a base silently downgraded to http would send a request the
    user believes is encrypted."""

    def test_an_unset_base_means_the_public_instance(self):
        self.assertEqual(derby.valid_base(""), derby.DEFAULT_BASE)
        self.assertEqual(derby.valid_base(None), derby.DEFAULT_BASE)

    def test_https_is_accepted_and_its_trailing_slash_dropped(self):
        self.assertEqual(derby.valid_base("https://example.test/api/"),
                         "https://example.test/api")

    def test_anything_but_https_is_refused(self):
        for raw in ["http://example.test/api", "file:///etc/passwd",
                    "ftp://example.test", "https://", "example.test",
                    "https://user:pw@example.test/api"]:
            self.assertIsNone(derby.valid_base(raw), raw)


class FakeResponse:
    """Just enough of http.client.HTTPResponse for get_json."""

    def __init__(self, body, content_type):
        self._body = body.encode("utf-8")
        self.headers = {"Content-Type": content_type}

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class Fetching(unittest.TestCase):
    """The two functions that touch the network, with the socket taken out.

    These exist because of what the derby actually does with a name it doesn't
    recognise, which is not what anything about the response suggests: it
    answers with the single-page app's own index.html and a 200, so a mistyped
    organisation is indistinguishable from a corrupt response unless something
    checks the content type.
    """

    def stub(self, *responses):
        remaining = list(responses)
        calls = []

        def urlopen(request, timeout=None):
            calls.append(request.full_url)
            return remaining.pop(0)

        self.calls = calls
        return urlopen

    def setUp(self):
        self._real = derby.urllib.request.urlopen

    def tearDown(self):
        derby.urllib.request.urlopen = self._real

    def test_a_json_response_is_parsed(self):
        derby.urllib.request.urlopen = self.stub(
            FakeResponse('{"races": []}', "application/json"))
        self.assertEqual(derby.get_json("https://example.test/api"), {"races": []})

    # The guard the whole error message rests on. Without it, index.html
    # reaches json.loads and the failure reads as "the response wasn't
    # readable" — which sends somebody looking for a fault that isn't there.
    def test_a_web_page_is_refused_rather_than_parsed(self):
        derby.urllib.request.urlopen = self.stub(
            FakeResponse("<!DOCTYPE html>", "text/html; charset=utf-8"))
        with self.assertRaises(derby.NotJSON):
            derby.get_json("https://example.test/api")

    # The literals are not valid JSON, and letting them in only moves the
    # failure somewhere less legible.
    def test_infinity_and_nan_literals_are_refused_at_the_parse(self):
        for literal in ["Infinity", "-Infinity", "NaN"]:
            derby.urllib.request.urlopen = self.stub(
                FakeResponse('{"x": %s}' % literal, "application/json"))
            with self.assertRaises(ValueError, msg=literal):
                derby.get_json("https://example.test/api")

    def test_a_response_with_no_content_type_is_refused(self):
        derby.urllib.request.urlopen = self.stub(FakeResponse('{"races": []}', ""))
        with self.assertRaises(derby.NotJSON):
            derby.get_json("https://example.test/api")

    # The field is the service's, and a non-string there put a JSON object
    # where the host's decoder wants a string — which fails the *whole*
    # document, so the pane would say "wrong type for message" instead of
    # showing the API's error.
    def test_a_non_string_error_message_does_not_reach_the_document(self):
        import urllib.error, io
        for body in ['{"code":"X","message":{"a":1}}', '{"code":"X","message":7}',
                     '{"code":"X"}', 'not json']:
            def raiser(request, timeout=None, _b=body):
                raise urllib.error.HTTPError(
                    request.full_url, 500, "err", {}, io.BytesIO(_b.encode()))
            derby.urllib.request.urlopen = raiser
            os_environ = derby.os.environ
            derby.os.environ = {derby.ORG_KEY: "StackOne"}
            try:
                doc = derby.build()
            finally:
                derby.os.environ = os_environ
            self.assertIsInstance(doc["message"], str, body)
            self.assertEqual(json.loads(json.dumps(doc)), doc)

    def test_a_web_page_on_the_org_route_means_no_such_org(self):
        derby.urllib.request.urlopen = self.stub(
            FakeResponse("<!DOCTYPE html>", "text/html"))
        with self.assertRaises(derby.UnknownOrg):
            derby.fetch("https://example.test/api", "stackone")

    def test_the_org_name_reaches_the_url_percent_encoded(self):
        derby.urllib.request.urlopen = self.stub(
            FakeResponse('{"races": [{"join_code": "A B", "status": "live"}]}',
                         "application/json"),
            FakeResponse('{"join_code": "A B", "horses": []}', "application/json"))
        derby.fetch("https://example.test/api", "Stack One")
        self.assertEqual(self.calls[0], "https://example.test/api/organisations/Stack%20One/races")
        self.assertEqual(self.calls[1], "https://example.test/api/races/A%20B")

    def test_an_org_with_no_races_is_nothing_rather_than_an_error(self):
        derby.urllib.request.urlopen = self.stub(
            FakeResponse('{"races": []}', "application/json"))
        self.assertIsNone(derby.fetch("https://example.test/api", "StackOne"))

    # An unknown org is empty, not an error: nothing is broken and nothing
    # needs reporting — the name just isn't one.
    # Building the document used to sit outside build()'s try, so anything it
    # raised escaped as a traceback. The host reads that as a crashed
    # extension rather than as the extension reporting something.
    def test_a_race_that_cannot_be_rendered_is_reported_rather_than_raised(self):
        derby.urllib.request.urlopen = self.stub(
            FakeResponse('{"races": [{"join_code": "A", "status": "live"}]}',
                         "application/json"),
            FakeResponse('{"join_code": "A", "horses": "not a list"}', "application/json"))
        os_environ = derby.os.environ
        derby.os.environ = {derby.ORG_KEY: "StackOne"}
        try:
            doc = derby.build()
        finally:
            derby.os.environ = os_environ
        self.assertIn(doc["state"], ("ok", "empty", "error"))
        self.assertEqual(json.loads(json.dumps(doc)), doc)

    def test_build_reports_an_unknown_org_as_empty_and_says_why(self):
        derby.urllib.request.urlopen = self.stub(
            FakeResponse("<!DOCTYPE html>", "text/html"))
        os_environ = derby.os.environ
        derby.os.environ = {derby.ORG_KEY: "stackone"}
        try:
            doc = derby.build()
        finally:
            derby.os.environ = os_environ
        self.assertEqual(doc["state"], "empty")
        self.assertIn("case-sensitive", doc["message"])


if __name__ == "__main__":
    unittest.main()
