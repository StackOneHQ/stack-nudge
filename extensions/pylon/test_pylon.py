#!/usr/bin/env python3
"""Tests for the Pylon extension.

Run them with `python3 -m unittest discover extensions`, which is what CI does.

Everything here is offline. Pylon is a fake that answers by route, and the two
seams that reach outside the process — the banner and the browser — are
recorders, so a test can never post a notification or open a page.
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import pathlib
import tempfile
import unittest
import urllib.error
import urllib.parse
from datetime import datetime, timedelta, timezone
from unittest import mock

_PATH = pathlib.Path(__file__).with_name("run")
_LOADER = importlib.machinery.SourceFileLoader("pylon_run", str(_PATH))
_SPEC = importlib.util.spec_from_loader(_LOADER.name, _LOADER)
pylon = importlib.util.module_from_spec(_SPEC)
_LOADER.exec_module(pylon)

NOW = datetime(2026, 10, 28, 15, 0, tzinfo=timezone.utc)
ME, ALEX = "user-me", "user-alex"


class _Forbidden:
    def open(self, request, timeout=None):
        raise AssertionError("a test reached the network: %s" % request.full_url)


def _forbidden_side_effect(*args):
    raise AssertionError("a test reached outside the process: %r" % (args,))


def setUpModule():
    pylon._opener = _Forbidden()
    pylon._notifier = _forbidden_side_effect
    pylon._launcher = _forbidden_side_effect


def stamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def issue(number=1, **overrides):
    base = {
        "id": "issue-%d" % number,
        "number": number,
        "title": "Workday sync failing",
        "link": "https://app.usepylon.com/issues?issueNumber=%d" % number,
        "state": "new",
        "source": "slack",
        "account": {"id": "acct-1"},
        "assignee": None,
        "first_response_time": None,
        "first_response_breach_time": stamp(NOW + timedelta(minutes=30)),
        "latest_message_time": stamp(NOW),
        "created_at": stamp(NOW),
    }
    base.update(overrides)
    return base


def item(left_minutes=30, mine=True, unowned=False, number=1, snoozed=False, kind="first"):
    due = NOW + timedelta(minutes=left_minutes)
    return {
        "id": "issue-%d" % number, "number": number, "title": "Workday sync failing",
        "account": "Acme", "link": None, "source": "slack", "kind": kind,
        "due": due, "left": left_minutes * 60.0,
        "mine": mine, "unowned": unowned,
        "who": "yours" if mine else ("unowned" if unowned else "Alex"),
        "snoozed": snoozed,
    }


def timeline(mine, unowned=False, minutes=range(0, 40)):
    """Poll once a minute from the moment an issue arrives on a 30-minute SLA;
    return {minute: stage} for every banner this person gets."""
    ledger, heard = {}, {}
    for minute in minutes:
        banners, ledger = pylon.plan_banners(
            [item(left_minutes=30 - minute, mine=mine, unowned=unowned)], ledger)
        for stage, _ in banners:
            heard[minute] = stage
    return heard


class Classification(unittest.TestCase):

    def test_an_unanswered_issue_on_an_sla_needs_a_first_response(self):
        waiting = pylon.classify(issue())
        self.assertEqual(waiting["kind"], "first")
        self.assertEqual(waiting["due"], NOW + timedelta(minutes=30))

    def test_our_own_outreach_is_not_waiting_on_us(self):
        # Pylon runs no SLA on an issue we opened, which is exactly what
        # separates it from a customer nobody has answered.
        outreach = issue(first_response_breach_time=None, tags=["proactive-nudge"])
        self.assertIsNone(pylon.classify(outreach))

    def test_the_customers_turn_and_parked_issues_are_not_waiting_on_us(self):
        for state in ("waiting_on_customer", "on_hold", "closed"):
            self.assertIsNone(pylon.classify(issue(state=state)), state)

    def test_an_answered_issue_the_customer_came_back_to_owes_a_reply(self):
        waiting = pylon.classify(issue(
            state="waiting_on_you", first_response_time=stamp(NOW),
            next_reply={"time": None, "breach_time": stamp(NOW + timedelta(hours=2))}))
        self.assertEqual(waiting, {"kind": "reply", "due": NOW + timedelta(hours=2)})

    def test_a_met_reply_sla_means_nothing_is_owed(self):
        waiting = pylon.classify(issue(
            state="waiting_on_you", first_response_time=stamp(NOW),
            next_reply={"time": stamp(NOW), "breach_time": stamp(NOW)}))
        self.assertIsNone(waiting)

    def test_waiting_on_you_after_our_own_reply_is_not_a_reply_owed(self):
        # Pylon leaves an issue "waiting on you" after we answer until somebody
        # moves it; with no next-reply SLA running, the customer isn't waiting.
        answered = issue(state="waiting_on_you", first_response_time=stamp(NOW),
                         latest_message_time=stamp(NOW))
        self.assertIsNone(pylon.classify(answered))


class Escalation(unittest.TestCase):
    """The schedule this was built for: the owner instantly,
    again at 10 and 20 minutes, everyone at 25, and everyone at the breach."""

    def test_the_owner_hears_instantly_then_at_10_20_25_and_the_breach(self):
        self.assertEqual(timeline(mine=True), {0: 1, 10: 2, 20: 3, 25: 4, 30: 5})

    def test_everyone_else_hears_at_25_minutes_and_at_the_breach(self):
        self.assertEqual(timeline(mine=False), {25: 4, 30: 5})

    def test_an_issue_nobody_owns_goes_to_everyone_at_every_stage(self):
        self.assertEqual(timeline(mine=False, unowned=True),
                         {0: 1, 10: 2, 20: 3, 25: 4, 30: 5})

    def test_a_late_poll_sends_one_banner_not_one_per_missed_stage(self):
        banners, _ = pylon.plan_banners([item(left_minutes=4)], {"issue-1": 1})
        self.assertEqual([stage for stage, _ in banners], [4])

    def test_an_overnight_issue_is_quiet_until_its_sla_window_opens(self):
        banners, ledger = pylon.plan_banners([item(left_minutes=10 * 60)], {})
        self.assertEqual(banners, [])
        self.assertEqual(ledger, {"issue-1": 0})

    def test_first_sight_long_after_the_breach_is_shown_but_not_bannered(self):
        banners, ledger = pylon.plan_banners([item(left_minutes=-3 * 60)], {})
        self.assertEqual(banners, [])
        # Recorded, so it stays quiet on every later poll too.
        self.assertEqual(ledger, {"issue-1": 5})

    def test_a_fresh_breach_on_first_sight_is_still_bannered(self):
        banners, _ = pylon.plan_banners([item(left_minutes=-5)], {})
        self.assertEqual([stage for stage, _ in banners], [5])

    def test_a_snoozed_issue_is_not_bannered(self):
        banners, _ = pylon.plan_banners([item(left_minutes=4, snoozed=True)], {})
        self.assertEqual(banners, [])

    def test_the_ledger_only_keeps_issues_still_waiting(self):
        _, ledger = pylon.plan_banners([item(number=2)], {"issue-1": 3, "issue-2": 1})
        self.assertEqual(ledger, {"issue-2": 1})

    def test_replies_owed_never_banner(self):
        banners, ledger = pylon.plan_banners([item(left_minutes=-5, kind="reply")], {})
        self.assertEqual((banners, ledger), ([], {}))


class Banners(unittest.TestCase):

    def test_customer_text_never_reaches_the_script_source(self):
        hostile = 'x" & (do shell script "touch /tmp/pwned") & "'
        with mock.patch.object(pylon.subprocess, "run") as run:
            pylon._post_banner("t", "s", hostile, "Ping")
        args = run.call_args[0][0]
        scripts = [args[i + 1] for i, arg in enumerate(args) if arg == "-e"]
        self.assertEqual(tuple(scripts), pylon._APPLESCRIPT)
        self.assertIn(hostile, args)
        self.assertNotIn(hostile, " ".join(scripts))

    def test_banner_names_the_issue_the_time_left_and_whose_it_is(self):
        title, subtitle, body, sound = pylon.banner_text(2, item(left_minutes=20))
        self.assertEqual(title, "Pylon #1 · 20m left")
        self.assertEqual(subtitle, "Acme · yours")
        self.assertEqual(body, "Workday sync failing")
        self.assertEqual(sound, "Ping")
        title, subtitle, _, _ = pylon.banner_text(5, item(left_minutes=0, mine=False))
        self.assertEqual(title, "Pylon #1 · first response missed")
        self.assertEqual(subtitle, "Acme · Alex")

    def test_more_than_three_collapse_into_one_summary(self):
        sent = []
        with mock.patch.object(pylon, "_notifier", lambda *a: sent.append(a)):
            pylon.send_banners([(1, item(number=n)) for n in range(5)])
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0][0], "Pylon · 5 issues need a first response")
        self.assertEqual(sent[0][1], "5 yours")

    def test_only_pylon_links_are_opened(self):
        self.assertTrue(pylon.is_pylon_link("https://app.usepylon.com/issues?issueNumber=1"))
        for link in ("http://app.usepylon.com/x", "https://usepylon.com.evil.io/x",
                     "file:///etc/passwd", None):
            self.assertFalse(pylon.is_pylon_link(link), link)


class Rows(unittest.TestCase):

    def test_live_soonest_first_then_most_recently_missed_then_replies(self):
        items = [
            item(number=1, left_minutes=25),
            item(number=2, left_minutes=-120),
            item(number=3, left_minutes=5),
            item(number=4, left_minutes=-10),
            item(number=5, left_minutes=60, kind="reply"),
        ]
        rows = pylon.document(items, NOW, False, True)["rows"]
        self.assertEqual([r["id"] for r in rows],
                         ["issue-3", "issue-1", "issue-4", "issue-2", "issue-5"])

    def test_values_and_bars_follow_the_clock(self):
        rows = {r["id"]: r for r in pylon.document(
            [item(number=1, left_minutes=25), item(number=2, left_minutes=5),
             item(number=3, left_minutes=-90)], NOW, False, True)["rows"]}
        self.assertEqual(rows["issue-1"]["value"], "25m left")
        self.assertEqual(rows["issue-1"]["track"]["tint"], pylon.GREEN)
        self.assertEqual(rows["issue-2"]["track"]["tint"], pylon.AMBER)
        self.assertEqual(rows["issue-3"]["value"], "late 1h 30m")
        self.assertEqual(rows["issue-3"]["track"], {"fill": 1.0, "tint": pylon.RED})
        self.assertEqual(rows["issue-1"]["lead"], "#1")

    def test_mine_only_hides_only_replies_owed_on_other_peoples_accounts(self):
        items = [item(number=1, mine=True, kind="reply", left_minutes=60),
                 item(number=2, mine=False, kind="reply", left_minutes=60),
                 item(number=3, mine=False, unowned=True, kind="reply", left_minutes=90),
                 # Somebody else's first response stays: the team catches those.
                 item(number=4, mine=False, left_minutes=12)]
        rows = pylon.document(items, NOW, True, True)["rows"]
        self.assertEqual([r["id"] for r in rows], ["issue-4", "issue-1", "issue-3"])

    def test_the_badge_says_the_worst_thing_that_is_yours(self):
        def badge(items):
            return pylon.document(items, NOW, False, True)["header"]["badge"]
        self.assertEqual(badge([]), {"text": "CLEAR", "tone": "success"})
        self.assertEqual(badge([item(left_minutes=25)]), {"text": "1 DUE", "tone": "warning"})
        self.assertEqual(badge([item(left_minutes=8)]), {"text": "1 DUE", "tone": "danger"})
        self.assertEqual(badge([item(left_minutes=-1)]), {"text": "1 LATE", "tone": "danger"})
        # Somebody else's late issue isn't yours to be red about.
        self.assertEqual(badge([item(left_minutes=-1, mine=False)])["text"], "CLEAR")

    def test_not_knowing_who_you_are_is_said_out_loud(self):
        header = pylon.document([], NOW, False, False)["header"]
        self.assertIn("set your email", header["title"])

    def test_titles_are_one_line(self):
        self.assertEqual(pylon.text("Sync\nfailing\t again"), "Sync failing again")

    def test_message_html_reads_as_one_line_of_what_a_person_sees(self):
        html = ('<html><head><style>p { color: red }</style></head><body>'
                '<h1></h1><p>Hi <span class="mention">@Sam Taylor</span>,</p>'
                '<ul><li>Q&amp;A&nbsp;done</li><li>next</li></ul><br>Thanks</body></html>')
        self.assertEqual(pylon.plain(html), "Hi @Sam Taylor, Q&A done next Thanks")
        self.assertEqual(pylon.plain(None), "")

    def test_the_latest_message_wins_whatever_order_it_arrives_in(self):
        users = {ALEX: {"name": "Alex Rivera", "email": "alex@example.com"}}
        preview = pylon.preview_of([message(ALEX, "<p>newer</p>", 5),
                                    message("Dana", "<p>older</p>", 50)], users)
        self.assertEqual((preview["who"], preview["text"], preview["note"]),
                         ("Alex", "newer", False))
        self.assertIsNone(pylon.preview_of([], users))

    def test_footnote_puts_the_message_last_so_truncation_eats_it_first(self):
        row = pylon.row_for(dict(item(), preview={
            "who": "Dana", "at": stamp(NOW - timedelta(hours=3)), "text": "It broke", "note": False}), NOW)
        self.assertEqual(row["footnote"], "yours · Dana, 3h ago: It broke")

    def test_durations(self):
        self.assertEqual(pylon.short_duration(30), "<1m")
        self.assertEqual(pylon.short_duration(25 * 60), "25m")
        self.assertEqual(pylon.short_duration(2 * 3600), "2h")
        self.assertEqual(pylon.short_duration(26 * 3600), "1d 2h")


# --- End to end against a fake Pylon ----------------------------------------

class _Response:
    def __init__(self, payload):
        self._body = io.BytesIO(json.dumps(payload).encode("utf-8"))
        self.headers = {"Content-Type": "application/json"}

    def read1(self, size):
        return self._body.read1(size)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(status, code=None):
    body = json.dumps({"code": code, "request_id": "r"} if code else {"request_id": "r"})
    return urllib.error.HTTPError("https://api.usepylon.com", status, "error", {},
                                  io.BytesIO(body.encode("utf-8")))


class _FakePylon:
    def __init__(self, routes):
        self.routes = routes
        self.requests = []

    def open(self, request, timeout=None):
        url = urllib.parse.urlsplit(request.full_url)
        body = json.loads(request.data) if request.data else None
        self.requests.append((url.netloc, request.get_method(), url.path, body, request))
        handler = self.routes.get((request.get_method(), url.path))
        if handler is None and url.path.startswith("/issues/") and url.path.endswith("/messages"):
            handler = self.routes.get((request.get_method(), "/issues/*/messages"))
        if handler is None:
            raise AssertionError("unexpected %s %s" % (request.get_method(), url.path))
        result = handler(url.netloc, body, url.path) if callable(handler) else handler
        if isinstance(result, Exception):
            raise result
        return _Response(result)


def message(author, html, minutes_ago, private=False):
    who = ({"user": {"id": author}, "name": "ignored"} if author.startswith("user-")
           else {"contact": {"id": "c-" + author}, "name": author})
    return {"id": "m-%s-%d" % (author, minutes_ago), "author": who, "message_html": html,
            "is_private": private, "timestamp": stamp(NOW - timedelta(minutes=minutes_ago))}


THREADS = {
    "issue-1": [message("Robin Vale", "<p>Hi team,</p><p>Any update on the &amp; export fix?</p>", 125)],
    "issue-2": [message("Dana", "<p>It broke again</p>", 300),
                message(ALEX, "<p>Looking into it with engineering</p>", 40, private=True)],
    "issue-3": [],
}


def messages_route(host, body, path):
    return {"data": THREADS.get(path.split("/")[2], []), "request_id": "r"}


def message_calls(fake):
    return [r[2].split("/")[2] for r in fake.requests if r[2].endswith("/messages")]


def workspace():
    return {
        ("GET", "/issues/*/messages"): messages_route,
        ("GET", "/me"): {"data": {"id": "org", "name": "StackOne",
                                  "user": {"id": ME, "email": "me@example.com"}}},
        ("GET", "/users"): {"data": [
            {"id": ME, "name": "Sam Taylor", "email": "me@example.com"},
            {"id": ALEX, "name": "Alex Rivera", "email": "alex@example.com"},
        ]},
        ("POST", "/issues/search"): {"data": [
            issue(1, account={"id": "acct-mine"}),
            issue(2, account={"id": "acct-alex"},
                  first_response_breach_time=stamp(NOW + timedelta(minutes=4))),
            issue(3, account=None,
                  first_response_breach_time=stamp(NOW - timedelta(days=3))),
            issue(4, first_response_breach_time=None, tags=["proactive-nudge"]),
            issue(7, account={"id": "acct-feedback"}),
        ], "pagination": {"has_next_page": False}},
        # Owners come back as a bare id: the live API omits the email the docs
        # promise, so "yours" has to go through /users.
        ("POST", "/accounts/search"): {"data": [
            {"id": "acct-mine", "name": "Acme", "type": "customer", "owner": {"id": ME}},
            {"id": "acct-alex", "name": "Globex", "type": "customer", "owner": {"id": ALEX}},
            {"id": "acct-feedback", "name": "Product Feedback", "type": "internal", "owner": None},
        ]},
    }


class EndToEnd(unittest.TestCase):

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.dir.cleanup)
        patcher = mock.patch.object(pylon, "_state_path", os.path.join(self.dir.name, "state.json"))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.env = {pylon.TOKEN_KEY: "secret-token"}
        self.banners, self.opened = [], []

    def run_once(self, fake, argv=(), env=None, now=NOW):
        out = io.StringIO()
        with mock.patch.object(pylon, "_opener", fake), \
                mock.patch.object(pylon, "_notifier", lambda *a: self.banners.append(a)), \
                mock.patch.object(pylon, "_launcher", self.opened.append), \
                mock.patch.dict(os.environ, self.env if env is None else env, clear=True), \
                contextlib.redirect_stdout(out), \
                contextlib.redirect_stderr(io.StringIO()):
            status = pylon.main(list(argv), now=now)
        return status, (json.loads(out.getvalue()) if out.getvalue() else None)

    def test_without_a_token_it_asks_for_one(self):
        status, doc = self.run_once(_Forbidden(), env={})
        self.assertEqual((status, doc["state"]), (0, "empty"))
        self.assertIn("API token", doc["message"])

    def test_a_poll_lists_what_is_waiting_and_pings_the_owner(self):
        fake = _FakePylon(workspace())
        status, doc = self.run_once(fake)
        self.assertEqual(status, 0)
        self.assertEqual([r["id"] for r in doc["rows"]], ["issue-2", "issue-1", "issue-3"])
        footnotes = {r["id"]: r["footnote"] for r in doc["rows"]}
        self.assertIn("yours", footnotes["issue-1"])
        self.assertIn("Alex", footnotes["issue-2"])
        self.assertIn("unowned", footnotes["issue-3"])
        # Mine at 30 left, Alex's at 4 left (a team stage). The three-day-old
        # breach is on screen and silent.
        self.assertEqual(sorted(b[0] for b in self.banners),
                         ["Pylon #1 · 30m left", "Pylon #2 · 4m left"])

        # The token rides only as an unredirected header, so it can't follow a
        # redirect anywhere.
        request = fake.requests[0][4]
        self.assertIn("Authorization", request.unredirected_hdrs)
        self.assertNotIn("Authorization", request.headers)

        # The next run, inside the sync interval, asks Pylon nothing and pings
        # nobody again.
        fake.requests.clear()
        self.banners.clear()
        self.run_once(fake)
        self.assertEqual(fake.requests, [])
        self.assertEqual(self.banners, [])

        # A sync reuses who-is-who: one search, and no thread fetched again.
        self.run_once(fake, argv=["--action", "refresh"])
        self.assertEqual([r[2] for r in fake.requests], ["/issues/search"])

    def test_internal_channels_routed_into_pylon_are_not_customers(self):
        status, doc = self.run_once(_FakePylon(workspace()))
        self.assertEqual(status, 0)
        self.assertNotIn("issue-7", [r["id"] for r in doc["rows"]])
        self.assertNotIn("Pylon #7", " ".join(b[0] for b in self.banners))

    def test_the_search_asks_only_for_issues_that_could_be_on_us(self):
        fake = _FakePylon(workspace())
        self.run_once(fake)
        search = next(r[3] for r in fake.requests if r[2] == "/issues/search")
        state_filter, window = search["filter"]["subfilters"]
        self.assertEqual(state_filter, {"field": "state", "operator": "not_in",
                                        "values": ["closed", "waiting_on_customer", "on_hold"]})
        # Windowed on the latest message, not on creation: a customer writing
        # today on an old thread is owed a reply today.
        self.assertEqual(window["field"], "latest_message_activity_at")
        self.assertEqual(window["value"], stamp(NOW - timedelta(days=pylon.LOOKBACK_DAYS)))

    def test_notifications_off_keeps_the_tab_and_drops_the_banners(self):
        env = dict(self.env, **{pylon.NOTIFY_KEY: "off"})
        status, doc = self.run_once(_FakePylon(workspace()), env=env)
        self.assertEqual((status, len(doc["rows"]), self.banners), (0, 3, []))

    def test_the_email_setting_decides_whose_issues_are_yours(self):
        env = dict(self.env, **{pylon.EMAIL_KEY: "alex@example.com"})
        routes = workspace()
        del routes[("GET", "/me")]  # the setting means /me isn't asked
        _, doc = self.run_once(_FakePylon(routes), env=env)
        footnotes = {r["id"]: r["footnote"] for r in doc["rows"]}
        self.assertIn("yours", footnotes["issue-2"])
        self.assertIn("Sam", footnotes["issue-1"])

    def test_a_refused_token_says_so(self):
        routes = workspace()
        routes[("GET", "/me")] = http_error(401, "invalid_api_token")
        status, doc = self.run_once(_FakePylon(routes))
        self.assertEqual((status, doc["state"]), (0, "error"))
        self.assertIn("refused the API token", doc["message"])

    def test_an_eu_token_falls_back_and_the_region_is_remembered(self):
        routes = workspace()
        for key, payload in list(routes.items()):
            routes[key] = (lambda payload: lambda host, body, path: (
                (payload(host, body, path) if callable(payload) else payload)
                if host == "api.eu.usepylon.com"
                else http_error(401, "wrong_region_token")))(payload)
        fake = _FakePylon(routes)
        status, doc = self.run_once(fake)
        self.assertEqual((status, len(doc["rows"])), (0, 3))
        fake.requests.clear()
        self.run_once(fake, argv=["--action", "refresh"])
        self.assertEqual({r[0] for r in fake.requests}, {"api.eu.usepylon.com"})

    def test_rate_limiting_is_transient_and_keeps_the_last_document(self):
        routes = workspace()
        routes[("POST", "/issues/search")] = http_error(429, "rate_limited")
        status, doc = self.run_once(_FakePylon(routes))
        self.assertEqual((status, doc), (1, None))

    def test_return_opens_the_selected_issue_in_pylon(self):
        fake = _FakePylon(workspace())
        self.run_once(fake)
        self.run_once(fake, argv=["--action", "open", "--row", "issue-1"])
        self.assertEqual(self.opened, ["https://app.usepylon.com/issues?issueNumber=1"])

    def test_m_toggles_mine_only(self):
        routes = workspace()
        routes[("POST", "/issues/search")]["data"].append(issue(
            8, account={"id": "acct-alex"}, state="waiting_on_you",
            first_response_time=stamp(NOW), first_response_breach_time=None,
            next_reply={"time": None, "breach_time": stamp(NOW + timedelta(hours=2))}))
        fake = _FakePylon(routes)
        _, doc = self.run_once(fake, argv=["--action", "mine"])
        # Alex's reply owed goes; every first response, Alex's included, stays.
        self.assertEqual([r["id"] for r in doc["rows"]], ["issue-2", "issue-1", "issue-3"])
        _, doc = self.run_once(fake, argv=["--action", "mine"])
        self.assertEqual(len(doc["rows"]), 4)

    def test_rows_say_who_spoke_last_how_long_ago_and_what_they_said(self):
        _, doc = self.run_once(_FakePylon(workspace()))
        footnotes = {r["id"]: r["footnote"] for r in doc["rows"]}
        self.assertEqual(footnotes["issue-1"],
                         "yours · Robin Vale, 2h 05m ago: Hi team, Any update on the & export fix?")
        # A teammate by first name, and an internal note says so.
        self.assertEqual(footnotes["issue-2"],
                         "Alex · Alex (note), 40m ago: Looking into it with engineering")
        # No messages: the ordinary footnote stays.
        self.assertIn("first response missed", footnotes["issue-3"])

    def test_a_thread_is_fetched_again_only_when_it_moves(self):
        routes = workspace()
        fake = _FakePylon(routes)
        sync = ["--action", "refresh"]
        self.run_once(fake)
        self.assertEqual(sorted(message_calls(fake)), ["issue-1", "issue-2", "issue-3"])
        fake.requests.clear()
        self.run_once(fake, argv=sync)
        self.assertEqual(message_calls(fake), [])
        search = routes[("POST", "/issues/search")]["data"]
        search[0]["latest_message_time"] = stamp(NOW + timedelta(minutes=1))
        fake.requests.clear()
        self.run_once(fake, argv=sync)
        self.assertEqual(message_calls(fake), ["issue-1"])

    def test_previews_fill_in_over_polls_most_urgent_first(self):
        fake = _FakePylon(workspace())
        with mock.patch.object(pylon, "PREVIEWS_PER_POLL", 1):
            _, doc = self.run_once(fake)
            self.assertEqual(message_calls(fake), ["issue-2"])  # 4 minutes left: first
            self.assertIn("Alex (note)", doc["rows"][0]["footnote"])
            fake.requests.clear()
            self.run_once(fake, argv=["--action", "refresh"])
            self.assertEqual(message_calls(fake), ["issue-1"])

    def test_a_failed_preview_costs_the_footnote_not_the_poll(self):
        routes = workspace()
        routes[("GET", "/issues/*/messages")] = http_error(404, "not_found")
        status, doc = self.run_once(_FakePylon(routes))
        self.assertEqual((status, len(doc["rows"])), (0, 3))
        self.assertIn("first response due", doc["rows"][1]["footnote"])

    def test_rate_limited_previews_stop_for_this_poll(self):
        routes = workspace()
        routes[("GET", "/issues/*/messages")] = http_error(429, "rate_limited")
        fake = _FakePylon(routes)
        status, doc = self.run_once(fake)
        self.assertEqual((status, len(doc["rows"])), (0, 3))
        self.assertEqual(len(message_calls(fake)), 1)

    def test_a_preview_of_a_thread_that_moved_on_is_dropped_not_shown(self):
        routes = workspace()
        fake = _FakePylon(routes)
        self.run_once(fake)
        routes[("POST", "/issues/search")]["data"][0]["latest_message_time"] = stamp(
            NOW + timedelta(minutes=1))
        with mock.patch.object(pylon, "PREVIEWS_PER_POLL", 0):
            _, doc = self.run_once(fake, argv=["--action", "refresh"])
        footnote = next(r["footnote"] for r in doc["rows"] if r["id"] == "issue-1")
        self.assertNotIn("Robin", footnote)

    # --- Sync interval ---------------------------------------------------

    def test_between_syncs_pylon_is_not_asked_and_the_clock_still_runs(self):
        self.run_once(_FakePylon(workspace()))
        status, doc = self.run_once(_Forbidden(), now=NOW + timedelta(minutes=2))
        self.assertEqual(status, 0)
        rows = {r["id"]: r for r in doc["rows"]}
        self.assertEqual(rows["issue-1"]["value"], "28m left")
        self.assertIn("Robin Vale", rows["issue-1"]["footnote"])  # previews survive
        self.assertEqual(doc["header"]["title"], "Waiting on us · synced 2m ago")

    def test_the_sync_setting_decides_how_often_pylon_is_asked(self):
        env = dict(self.env, **{pylon.SYNC_KEY: "5"})
        fake = _FakePylon(workspace())
        self.run_once(fake, env=env)
        fake.requests.clear()
        self.run_once(fake, env=env, now=NOW + timedelta(minutes=4, seconds=59))
        self.assertEqual(fake.requests, [])
        self.run_once(fake, env=env, now=NOW + timedelta(minutes=5))
        self.assertEqual([r[2] for r in fake.requests], ["/issues/search"])

    def test_the_default_is_every_three_minutes(self):
        fake = _FakePylon(workspace())
        self.run_once(fake)
        fake.requests.clear()
        self.run_once(fake, now=NOW + timedelta(minutes=2, seconds=59))
        self.assertEqual(fake.requests, [])
        self.run_once(fake, now=NOW + timedelta(minutes=3))
        self.assertEqual([r[2] for r in fake.requests], ["/issues/search"])

    def test_r_syncs_now(self):
        fake = _FakePylon(workspace())
        self.run_once(fake)
        fake.requests.clear()
        self.run_once(fake, argv=["--action", "refresh"], now=NOW + timedelta(seconds=30))
        self.assertEqual([r[2] for r in fake.requests], ["/issues/search"])

    def test_reminders_fire_on_the_minute_between_syncs(self):
        # Synced once an hour, and the owner's 20-minute reminder still lands
        # at ten minutes in, from the deadline the last sync already had.
        env = dict(self.env, **{pylon.SYNC_KEY: "60"})
        self.run_once(_FakePylon(workspace()), env=env)
        self.banners.clear()
        self.run_once(_Forbidden(), env=env, now=NOW + timedelta(minutes=10))
        # Alex's issue breached in the same ten minutes: everyone hears that too.
        self.assertEqual(sorted(b[0] for b in self.banners),
                         ["Pylon #1 · 20m left", "Pylon #2 · first response missed"])

    def test_a_failed_sync_keeps_drawing_the_last_snapshot(self):
        routes = workspace()
        fake = _FakePylon(routes)
        self.run_once(fake)
        routes[("POST", "/issues/search")] = http_error(429, "rate_limited")
        status, doc = self.run_once(fake, now=NOW + timedelta(minutes=3))
        self.assertEqual((status, len(doc["rows"])), (0, 3))
        self.assertEqual(doc["header"]["title"], "Waiting on us · sync failed, retrying")

    def test_the_snapshot_keeps_no_message_bodies(self):
        routes = workspace()
        routes[("POST", "/issues/search")]["data"][0]["body_html"] = "<p>the customer's whole message</p>"
        self.run_once(_FakePylon(routes))
        with open(pylon._state_path) as handle:
            self.assertNotIn("whole message", handle.read())

    def test_the_sync_setting_is_read_forgivingly(self):
        for raw, minutes in (("", 3), ("abc", 3), ("2.5", 3), ("0", 1), ("999", 60), (" 7 ", 7)):
            with mock.patch.dict(os.environ, {pylon.SYNC_KEY: raw}, clear=True):
                self.assertEqual(pylon.sync_minutes(), minutes, raw)

    def test_a_new_token_forgets_what_the_old_one_learned(self):
        fake = _FakePylon(workspace())
        self.run_once(fake)
        fake.requests.clear()
        self.run_once(fake, env={pylon.TOKEN_KEY: "another-token"})
        self.assertIn("/me", [r[2] for r in fake.requests])


if __name__ == "__main__":
    unittest.main()
