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

  *  2  EVERY TOPIC THE DATABASE ALLOWS IS REACHABLE. `kahf` is Sūrat al-Kahf
        on a Friday. A topic the table permits that no dropdown offers is dead
        code with a masjid's word on it; a topic the dropdown offers that the
        table refuses is an error message nobody can act on. The list must
        match in BOTH directions.

  *  3  NOTHING IS SAVEABLE UNTIL THE FORM IS VALID — tested against a Save
        button that has been deliberately ENABLED first, because the markup
        also disables it and a test that reads the button without forcing the
        wrong state passes whether the rule exists or has been deleted. That
        exact trap caught the timetable screen: the check was there, it read
        correctly, and it would have passed with the rule removed.

  *  4  THE PUBLIC PAGE RENDERS NOTICES, AND ESCAPES THEM. These rows are
        written by verified administrators, so the realistic risk is small —
        but "only trustworthy people can write here" holds exactly until one
        of their accounts does not, and escaping costs nothing.

  *  5  AN EMPTY OR FAILING FETCH LEAVES NO TRACE. An empty "Notices" heading
        on the front page of a masjid reads as neglect, which is worse than
        no section. For most of the year there will be nothing to say.

  *  6  A PICTURE CANNOT MOVE THE PAGE. width and height come from the
        database, which requires both or neither, so the box is the right
        shape before the image lands.

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

#  And the public page has to have a readable label for every one of them, or
#  a notice appears on the front page of the masjid labelled `janazah`.
public = open("index.html", encoding="utf-8").read()
tm = re.search(r"var TOPIC = \{(.*?)\};", public, re.S)
check(tm is not None, "the public page has no TOPIC label table")
if tm:
    labelled = sorted(re.findall(r"([a-z]+):\s*'", tm.group(1)))
    check(labelled == sorted(TOPICS),
          "the public page labels %r but the database allows %r — an unlabelled "
          "topic shows on the front page as its own database key."
          % (labelled, sorted(TOPICS)))

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

    # =================================================== the public page
    #
    #  The fetch is intercepted, because the point is what the page DOES with
    #  rows — not whether the live database has any today.
    POISON = "</h3><img src=x onerror=\"window.__pwned=1\">"

    def serve(rows):
        pg = b.new_page(viewport={"width": 1280, "height": 900})
        seen = []
        pg.on("pageerror", lambda e: seen.append(str(e)[:140]))
        pg.route("**/rest/v1/notices_live*", lambda r: r.fulfill(
            status=200, content_type="application/json", body=json.dumps(rows)))
        pg.goto(BASE, wait_until="load", timeout=45000)
        pg.wait_for_timeout(1400)
        return pg, seen

    # ------------------------------------------- 4 and 6. it renders
    pg, seen = serve([
        {"id": "1", "topic": "janazah", "title": "Janāzah after Ẓuhr",
         "body": "Brother Yusuf, may Allah have mercy on him.",
         "image_url": None, "image_w": None, "image_h": None,
         "event_at": "2026-09-20T13:30:00+00:00"},
        {"id": "2", "topic": "kahf", "title": POISON, "body": None,
         "image_url": "https://example.test/poster.jpg",
         "image_w": 800, "image_h": 600, "event_at": None},
    ])
    r = pg.evaluate("""() => {
      const row = document.getElementById('noticesRow');
      const cards = [...document.querySelectorAll('.nt-card')];
      const img = document.querySelector('.nt-card img');
      return {
        shown: !row.hidden,
        cards: cards.length,
        chips: cards.map(c => c.querySelector('.nt-chip').textContent),
        heads: cards.map(c => c.querySelector('h3').textContent),
        pwned: !!window.__pwned,
        extraImgs: document.querySelectorAll('.nt-card img').length,
        imgW: img ? img.getAttribute('width') : null,
        imgH: img ? img.getAttribute('height') : null,
        lazy: img ? img.getAttribute('loading') : null
      };
    }""")
    check(r["shown"], "two notices came back and the section stayed hidden")
    check(r["cards"] == 2, "expected 2 notice cards, drew %d" % r["cards"])
    check(r["chips"] == ["Janāzah", "Sūrat al-Kahf"],
          "the topic chips read %r — a notice on the front page of the masjid "
          "must not be labelled with a database key" % r["chips"])
    check(r["pwned"] is False,
          "A NOTICE'S HEADING WAS EXECUTED AS HTML. Only verified "
          "administrators can write these rows, which is an argument that "
          "holds until one of their accounts does not.")
    check(r["extraImgs"] == 1,
          "%d images were drawn for one picture — the escaped heading has been "
          "parsed as markup" % r["extraImgs"])
    check(POISON in r["heads"],
          "the poisoned heading was not rendered as literal text: %r" % r["heads"])
    check(r["imgW"] == "800" and r["imgH"] == "600",
          "the picture has width %r height %r — without both from the database "
          "the page moves under the reader when it loads" % (r["imgW"], r["imgH"]))
    check(r["lazy"] == "lazy", "the notice picture is not lazily loaded")
    check(seen == [], "the home page threw: %s" % seen[:2])
    pg.close()

    # --------------------------------- 5. empty, and broken, leave no trace
    for label, rows in (("an empty list", []),
                        ("rows with no heading", [{"id": "1", "topic": "events",
                                                   "title": None, "body": "x"}])):
        pg, seen = serve(rows)
        hidden = pg.evaluate("() => document.getElementById('noticesRow').hidden")
        check(hidden is True,
              "%s left the Notices section on screen. An empty heading on the "
              "front page of a masjid reads as neglect — worse than nothing."
              % label)
        check(seen == [], "%s made the page throw: %s" % (label, seen[:2]))
        pg.close()

    #  And an outright failure.
    pg = b.new_page(viewport={"width": 1280, "height": 900})
    seen = []
    pg.on("pageerror", lambda e: seen.append(str(e)[:140]))
    pg.route("**/rest/v1/notices_live*", lambda r: r.fulfill(status=500, body="no"))
    pg.goto(BASE, wait_until="load", timeout=45000)
    pg.wait_for_timeout(1400)
    check(pg.evaluate("() => document.getElementById('noticesRow').hidden") is True,
          "a failed request left the Notices section on screen")
    check(seen == [], "a failed notices request threw an uncaught error: %s" % seen[:2])
    pg.close()

    b.close()

print("\n" + ("ALL PASS — %d good cases, %d bad, %d topics, and the public page "
              "renders, escapes and hides" % (len(GOOD), len(BAD), len(TOPICS))
              if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails[:20])))
sys.exit(1 if fails else 0)
