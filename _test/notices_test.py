"""Notices, both ends of them.

15 September 2026. `notices` was a table with no way in and no way out: the
website never read it, and the only thing that could write to it was a
SECURITY DEFINER function with no permission check, that nothing called.

Both ends were built at once, deliberately. A table the committee can write to
that no visitor can read is exactly as useless as the reverse, and this project
has already shipped the reverse — course sign-ups landed correctly in a table
no administrator could see, and nobody noticed for weeks.

WHAT THIS GUARDS

  *  1  THE EDITOR AND THE DATABASE AGREE ON WHAT A NOTICE IS. Every rule in
        041's check_notice() is also in the editor. Where they disagree, a
        volunteer is told a notice is fine and then handed a raw Postgres
        constraint name — which is precisely the fault 041 exists to fix, and
        it got into production once already.

  *  2  EVERY TOPIC THE DATABASE ALLOWS IS REACHABLE IN THE EDITOR. `kahf` is
        Sūrat al-Kahf on a Friday. A topic the table permits that no dropdown
        offers is dead code with a masjid's word on it; a topic the dropdown
        offers that the table refuses is an error nobody can act on. The list
        must match in BOTH directions. The topic is a filing label in the
        portal only; nothing about a notice reaches the website at present.

  *  3  NOTHING IS SAVEABLE UNTIL THE FORM IS VALID — tested against a Save
        button that has been deliberately ENABLED first, because the markup
        also disables it and a test that reads the button without forcing the
        wrong state passes whether the rule exists or has been deleted. That
        exact trap caught the timetable screen: the check was there, it read
        correctly, and it would have passed with the rule removed.

  *  4  NOTHING REACHES THE PUBLIC WEBSITE, and that is the current
        decision rather than an omission.

        Three designs were built and all three were rejected by the masjid:
        a section of its own under the at-a-glance row, a fifth card in that
        row showing the poster, and a band above the hero showing every
        notice as text. The work is not lost — the editor, the database, the
        poster uploads and the validation are all still here — but the
        website shows none of it until somebody decides how it should look.

        So this checks the public page stays CLEAN. A half-removed feature
        that leaves a fetch running, an empty section in the markup, or a
        stylesheet full of rules for nothing is the sort of thing that gets
        rediscovered a year later by somebody who cannot tell whether it is
        load-bearing.

Run:  python3 _test/notices_test.py
"""
from playwright.sync_api import sync_playwright
import functools
import http.server
import json
import os
import re
import socketserver
import sys
import threading

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/" % httpd.server_address[1]

fails = []


def check(ok, why):
    if not ok:
        fails.append(why)


#  The six topics, written out here rather than read from either the migration
#  or the page. A test that takes its expectation from one of the two things it
#  is comparing proves only that they are self-consistent.
TOPICS = ["announcements", "events", "janazah", "kahf", "ramadan", "madrasah"]

#  Cases the database accepts, taken from 041's own self-test so the two
#  cannot drift apart. If a row is added there it belongs here.
GOOD = [
    {"title": "Jumuʿah moves to 1.30pm", "topic": "announcements"},
    {"title": "Janāzah after Ẓuhr", "topic": "janazah"},
    {"title": "Sūrat al-Kahf, Friday", "topic": "kahf"},
    {"title": "Tarāwīḥ begins", "topic": "ramadan"},
    {"title": "Madrasah closed Monday", "topic": "madrasah"},
    {"title": "Eid prayer", "topic": "events"},
    {"title": "x" * 70, "topic": "events"},
    {"title": "With a body", "topic": "events", "body": "y" * 2000},
    {"title": "With a picture", "topic": "events",
     "image_url": "https://example.test/a.jpg", "image_w": "800", "image_h": "600"},
    #  A body is OPTIONAL. This is the one 041's self-test found the hard way:
    #  `body` was NOT NULL on the live table, so every bodyless notice failed
    #  in production. "Masjid closed Monday" needs no paragraph.
    {"title": "No body at all", "topic": "announcements", "body": ""},
]

#  And the ones it refuses, each with a word the complaint must contain, so a
#  message that says merely "invalid" fails this test.
BAD = [
    ({"title": "", "topic": "events"}, "heading"),
    ({"title": "x" * 71, "topic": "events"}, "70"),
    ({"title": "x", "topic": "wedding"}, "topic"),
    ({"title": "x", "topic": "events", "body": "y" * 2001}, "2000"),
    ({"title": "x", "topic": "events",
      "image_url": "http://example.test/a.jpg"}, "https"),
    ({"title": "x", "topic": "events",
      "image_url": "https://example.test/a.jpg", "image_w": "800"}, "height"),
    ({"title": "x", "topic": "events", "image_w": "800", "image_h": "600"}, "picture"),
    ({"title": "x", "topic": "events", "expires_at": "2020-01-01T09:00"}, "passed"),
]

# ---------------------------------------------------- 2. the topic list, both ways
mig = open("db/041_one_definition_of_a_notice.sql", encoding="utf-8").read()
m = re.search(r"check \(topic in \(([^)]*)\)\)", mig, re.S)
check(m is not None, "041 no longer has a `check (topic in (...))` — this test "
                     "cannot tell what the database allows")
if m:
    in_db = sorted(re.findall(r"'([a-z]+)'", m.group(1)))
    check(in_db == sorted(TOPICS),
          "the database allows %r and this test expects %r. One of them has "
          "changed without the other." % (in_db, sorted(TOPICS)))

editor = open("notices/index.html", encoding="utf-8").read()
offered = sorted(set(re.findall(r'<option value="([a-z]+)"', editor)))
check(offered == sorted(TOPICS),
      "the editor's dropdown offers %r but the database allows %r. A topic the "
      "database permits that no dropdown offers is dead; one the dropdown "
      "offers that the database refuses is an error nobody can act on."
      % (offered, sorted(TOPICS)))

#  There is no matching check on the PUBLIC page, and its absence is
#  deliberate. One version of the front page showed a topic chip on every
#  notice and needed a readable label for all six keys, or a notice appeared
#  on the masjid's home page labelled `janazah`. Nothing about a notice
#  reaches the website now, so there is no chip to label — the topic survives
#  as a way of filing notices in the portal and nothing more.

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =================================================== the editor
    pg = b.new_page(viewport={"width": 1280, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:140]))
    pg.goto(BASE + "notices/", wait_until="load", timeout=45000)
    pg.wait_for_timeout(1000)

    check(pg.evaluate("() => !!(window.__NOTICE_FORM && window.__NOTICE_FORM.check)"),
          "the notice validator is not exposed, so none of this can be tested")

    # ------------------------------------------------ 1. the two agree
    for case in GOOD:
        out = pg.evaluate(
            "c => { try { return { r: window.__NOTICE_FORM.check(c) }; } "
            "catch (e) { return { threw: String(e) }; } }", case)
        check("threw" not in out,
              "the validator THREW on a notice the database accepts — %s: %s"
              % (case.get("title", "")[:30], out.get("threw")))
        if "threw" in out:
            continue
        check(out["r"] == [],
              "the editor REFUSES a notice the database accepts. The person is "
              "stopped from saving something that is perfectly valid, and the "
              "only place that is written down is a test. %r -> %r"
              % ({k: v[:24] for k, v in case.items()}, out["r"]))

    for case, must_say in BAD:
        out = pg.evaluate(
            "c => { try { return { r: window.__NOTICE_FORM.check(c) }; } "
            "catch (e) { return { threw: String(e) }; } }", case)
        check("threw" not in out,
              "the validator THREW instead of complaining — %r: %s"
              % (case, out.get("threw")))
        if "threw" in out:
            continue
        check(out["r"] != [],
              "the editor ACCEPTS a notice the database refuses: %r. The person "
              "presses Save and gets a raw Postgres constraint name." % case)
        check(any(must_say.lower() in c.lower() for c in out["r"]),
              "nothing in %r mentions %r, so the complaint does not say what to "
              "do about it" % (out["r"], must_say))

    # ------------------------------------ 3. nothing saveable until valid
    #
    #  Force the WRONG state first. The Save button is disabled in the markup
    #  too, so without this the check reads "disabled" whether the rule is
    #  there or has been deleted — which is how the same check on the
    #  timetable screen passed with its rule removed.
    pg.evaluate("""() => {
      const g = document.getElementById('view-signin'); if (g) g.hidden = true;
      const a = document.getElementById('view-app');    if (a) a.hidden = false;
      window.__NOTICE_FORM.wire();
      document.getElementById('nt-save').disabled = false;
    }""")

    #  Type, then delete — in that order, and not the other way round. Filling
    #  an already-empty box with an empty string fires no `input` event at all,
    #  so the first version of this asserted that a screen which had recomputed
    #  nothing was still in the state the previous line had forced it into. It
    #  failed honestly, which is the only reason it is written down here; had
    #  it been ordered the other way it would have passed and proved nothing.
    def save_disabled():
        return pg.evaluate("() => document.getElementById('nt-save').disabled")

    pg.fill("#nt-title", "Eid prayer is at 8am")
    pg.wait_for_timeout(150)
    check(save_disabled() is False, "a perfectly good notice could not be saved")

    pg.fill("#nt-title", "")
    pg.wait_for_timeout(150)
    check(save_disabled() is True,
          "deleting the heading left Save enabled — the database requires one, "
          "so pressing it would produce a raw constraint error")

    pg.fill("#nt-title", "x" * 71)
    pg.wait_for_timeout(150)
    check(save_disabled() is True,
          "a 71-character heading left Save enabled, and the database caps it "
          "at 70")

    pg.fill("#nt-title", "Back to something sensible")
    pg.wait_for_timeout(150)
    check(save_disabled() is False,
          "Save stayed disabled after the heading was corrected, so the screen "
          "cannot be recovered from once it has complained")

    check(errs == [], "the editor threw: %s" % errs[:2])
    pg.close()

    # ============================================ nothing on the public page
    #
    #  Read from the BUILT page, because that is what a visitor gets, and the
    #  whole risk here is a fragment left behind in a file nobody re-reads.
    built = open("index.html", encoding="utf-8").read()
    for trace, what in [
        ("notices_live",  "a request to the notices view"),
        ("eventsRow",     "the events band markup"),
        ("eventsList",    "the events band's list"),
        ("ev-item",       "the events band's stylesheet"),
        ("events-row",    "the events band's stylesheet"),
        ("has-events",    "the events band's layout class"),
        ("ev-expect",     "the events band's space reservation"),
        ("tm_events_h",   "the events band's remembered height"),
        ("__eventsReady", "the early events fetch"),
        ("noticeCard",    "the poster card in the at-a-glance row"),
        ("glance-notice", "the poster card's stylesheet"),
    ]:
        check(trace not in built,
              "%r is still in the built page — %s. Notices are edited in the "
              "portal and shown nowhere on the website at the moment; a "
              "half-removed feature is worse than either keeping it or taking "
              "it out, because the next person cannot tell which it is."
              % (trace, what))

    #  And the at-a-glance row is back to the four cards it has always had.
    pg = b.new_page(viewport={"width": 1280, "height": 900})
    seen = []
    pg.on("pageerror", lambda e: seen.append(str(e)[:140]))
    pg.on("request", lambda r: seen.append("requested notices_live")
          if "notices_live" in r.url else None)
    pg.route("**/rest/v1/rpc/courses_public", lambda r: r.fulfill(
        status=200, content_type="application/json", body="[]"))
    pg.route("**/rest/v1/site_content*", lambda r: r.fulfill(
        status=200, content_type="application/json", body="[]"))
    pg.goto(BASE, wait_until="load", timeout=45000)
    pg.wait_for_timeout(1500)
    r = pg.evaluate("""() => ({
        cards: [...document.querySelectorAll('.glance-grid > .glance-card')]
                 .filter(c => c.getBoundingClientRect().width > 1).length,
        heroTop: Math.round(document.querySelector('.hero').getBoundingClientRect().top)
    })""")
    check(r["cards"] == 4,
          "the at-a-glance row has %d cards. It should be back to the four it "
          "has always had." % r["cards"])
    check(r["heroTop"] <= 1,
          "the hero starts %dpx down the page — something is still being drawn "
          "above it." % r["heroTop"])
    check(seen == [], "the home page threw, or still asks for notices: %s" % seen[:2])
    pg.close()

    b.close()

print("\n" + ("ALL PASS — %d good cases, %d bad, %d topics, and the public "
              "page shows nothing" % (len(GOOD), len(BAD), len(TOPICS))
              if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails[:20])))
sys.exit(1 if fails else 0)
