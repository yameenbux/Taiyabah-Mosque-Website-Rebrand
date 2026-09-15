"""Opening and closing a class — the portal switch and what a visitor sees.

15 September 2026. `courses` held the name, the capacity and the is_open switch
that register_for_course() reads, and NOTHING COULD WRITE TO IT. No function,
no policy, no screen. The masjid could not close a class that was full.

The switch could not be added on its own. register_for_course() raises when a
course is closed, and the website's course list was a hard-coded object with
its own idea of what is open — so a volunteer closing the Arabic class would
have changed nothing a visitor could see, and the next person would have filled
in eleven fields and been handed a raw 400 by Postgres. This is the third time
on this project that half a feature was the whole bug.

WHAT THIS GUARDS

  *  1  THE EDITOR AND THE DATABASE AGREE ON WHAT A CLASS IS. Every rule in
        043's check_course() is in the editor too, tested against the same
        cases 043's own self-test runs against the real table.

  *  2  CAPACITY CANNOT BE CUT BELOW THE PEOPLE ALREADY HOLDING A PLACE. The
        database refuses it; the screen has to say so first, because the other
        order means a raw constraint message.

  *  3  NOTHING IS SAVEABLE UNTIL THE FORM IS VALID — checked from a
        deliberately ENABLED button, because the markup disables it too and a
        test that does not force the wrong state passes whether the rule is
        there or has been deleted. That trap caught the timetable screen.

  *  4  A CLOSED CLASS CLOSES ON THE WEBSITE. This is the whole point. When
        courses_public() says a class is shut, the visitor gets the "ring the
        office" panel instead of a form that cannot succeed.

  *  5  THE UPGRADE ONLY EVER TAKES AWAY. The built-in state is "open", so a
        failed or slow request leaves a form the database will decline
        politely, and can never wrongly close a class that is running.

  *  6  PLACES LEFT ARE SAID BEFORE THE FORM IS FILLED IN, not after. A full
        class still takes registrations onto a waiting list, and somebody is
        entitled to know which of the two they are joining.

Run:  python3 _test/courses_admin_test.py
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


#  The four 043's DO block inserts into the real table without complaint.
GOOD = [
    {"key": "probe_a", "name": "A class", "cohort_mode": "separate",
     "capacity": "15", "sort_order": "3"},
    {"key": "probe_b", "name": "Another", "cohort_mode": "single",
     "capacity": "1", "sort_order": "0"},
    {"key": "probe_c", "name": "At the ceiling", "cohort_mode": "single",
     "capacity": "500", "sort_order": "9999"},
    {"key": "ab", "name": "Shortest key allowed", "cohort_mode": "single",
     "capacity": "10"},
]

#  And the five it proves are refused, each with a word the complaint must use.
BAD = [
    ({"key": "Arabic Class", "name": "x", "cohort_mode": "single",
      "capacity": "10"}, "space"),
    ({"key": "ok", "name": "x", "cohort_mode": "mixed", "capacity": "10"}, "session"),
    ({"key": "ok", "name": "x", "cohort_mode": "single", "capacity": "501"}, "500"),
    ({"key": "ok", "name": "x", "cohort_mode": "single", "capacity": "0"}, "1"),
    ({"key": "a", "name": "x", "cohort_mode": "single", "capacity": "10"}, "40"),
    ({"key": "ok", "name": "", "cohort_mode": "single", "capacity": "10"}, "name"),
    ({"key": "ok", "name": "y" * 81, "cohort_mode": "single", "capacity": "10"}, "80"),
]

# ------------------------------- the migration and the editor say the same thing
mig = open("db/043_courses_the_committee_can_open_and_close.sql", encoding="utf-8").read()
check("'^[a-z0-9_]{2,40}$'" in mig,
      "043 no longer states the key pattern this test was written against")
check("capacity between 1 and 500" in mig or "1 and 500" in mig,
      "043 no longer states the 1-500 capacity range")

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # ================================================== the portal screen
    pg = b.new_page(viewport={"width": 1280, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:140]))
    pg.goto(BASE + "courses/", wait_until="load", timeout=45000)
    pg.wait_for_timeout(1000)

    check(pg.evaluate("() => !!(window.__COURSE_FORM && window.__COURSE_FORM.check)"),
          "the class validator is not exposed, so none of this can be tested")

    # ---------------------------------------------- 1. the two agree
    for case in GOOD:
        out = pg.evaluate(
            "c => { try { return { r: window.__COURSE_FORM.check(c) }; } "
            "catch (e) { return { threw: String(e) }; } }", case)
        check("threw" not in out,
              "the validator THREW on a class the database accepts — %r: %s"
              % (case["key"], out.get("threw")))
        if "threw" in out:
            continue
        check(out["r"] == [],
              "the editor REFUSES a class the database accepts, so a volunteer "
              "is stopped from saving something perfectly valid: %r -> %r"
              % (case, out["r"]))

    for case, must_say in BAD:
        out = pg.evaluate(
            "c => { try { return { r: window.__COURSE_FORM.check(c) }; } "
            "catch (e) { return { threw: String(e) }; } }", case)
        check("threw" not in out,
              "the validator THREW instead of complaining — %r: %s"
              % (case, out.get("threw")))
        if "threw" in out:
            continue
        check(out["r"] != [],
              "the editor ACCEPTS a class the database refuses: %r. The person "
              "presses Save and gets a raw constraint name." % case)
        check(any(must_say.lower() in c.lower() for c in out["r"]),
              "nothing in %r mentions %r, so the complaint does not say what to "
              "do about it" % (out["r"], must_say))

    # --------------------------- 2. capacity cannot be cut below what is taken
    over = pg.evaluate(
        "() => window.__COURSE_FORM.check({key:'arabic', name:'Arabic Classes', "
        "cohort_mode:'separate', capacity:'10', sort_order:'1', taken:12})")
    check(over != [],
          "the editor allows a class of 12 people to be cut to 10 places. The "
          "database refuses it, so this is a raw constraint error instead of a "
          "sentence — and if the database ever stopped refusing it, the masjid "
          "would be holding twelve names for ten seats.")
    check(any("12" in c for c in over),
          "the complaint %r does not say how many people are already holding a "
          "place, which is the number somebody needs to act on" % over)

    under = pg.evaluate(
        "() => window.__COURSE_FORM.check({key:'arabic', name:'Arabic Classes', "
        "cohort_mode:'separate', capacity:'15', sort_order:'1', taken:12})")
    check(under == [], "raising the capacity above what is taken was refused: %r" % under)

    # ------------------------------------ 3. nothing saveable until valid
    pg.evaluate("""() => {
      const g = document.getElementById('view-signin'); if (g) g.hidden = true;
      const a = document.getElementById('view-app');    if (a) a.hidden = false;
      const c = document.getElementById('cc-panel');    if (c) c.hidden = false;
      window.__COURSE_FORM.wire();
    }""")
    save = pg.query_selector("#cc-panel button[type=submit], #cc-save")
    check(save is not None, "the class form has no Save button with a findable id")

    if save:
        sel = "#cc-save" if pg.query_selector("#cc-save") else \
              "#cc-panel button[type=submit]"
        pg.evaluate("s => { document.querySelector(s).disabled = false; }", sel)

        def disabled():
            return pg.evaluate("s => document.querySelector(s).disabled", sel)

        #  Type first, then break it. Filling an already-empty box with an
        #  empty string fires no input event at all, so the other order
        #  asserts that a screen which recomputed nothing is still in the
        #  state the previous line forced it into.
        pg.fill("#cc-name", "Tajwīd Classes")
        pg.fill("#cc-key", "tajwid")
        pg.fill("#cc-capacity", "20")
        pg.wait_for_timeout(200)
        check(disabled() is False, "a perfectly good class could not be saved")

        pg.fill("#cc-key", "Tajwid Classes")
        pg.wait_for_timeout(200)
        check(disabled() is True,
              "a website key with a capital and a space left Save enabled, and "
              "the database refuses it")

        pg.fill("#cc-key", "tajwid")
        pg.fill("#cc-capacity", "501")
        pg.wait_for_timeout(200)
        check(disabled() is True,
              "a capacity of 501 left Save enabled, and the database caps it at 500")

        pg.fill("#cc-capacity", "20")
        pg.wait_for_timeout(200)
        check(disabled() is False,
              "Save stayed disabled after the form was corrected, so the screen "
              "cannot be recovered from once it has complained")

    # ========================= ONE SCREEN, NOT TWO
    #
    #  "What a class says" used to be a second rail row and a second folder,
    #  holding a class's website copy while this screen held its settings. A
    #  class is one thing to a volunteer and the split was mine, not theirs.
    #  Both halves live here now, and both validators have to be reachable
    #  from this one page or the other suite silently stops testing anything.
    check(os.path.isdir("classpages") is False,
          "the classpages/ folder is still there. It was merged into this "
          "screen; leaving it behind means two screens that will drift.")
    shell = open("admin/shell.js", encoding="utf-8").read()
    check("classpages" not in shell,
          "the rail still offers classpages/, which is now a 404 with the "
          "masjid's logo on it")

    check(pg.evaluate("() => !!(window.__CLASSPAGE_FORM "
                      "&& window.__CLASSPAGE_FORM.check)"),
          "the class-page validator is not exposed from this screen, so "
          "everything the merge absorbed is untested")

    #  The page half still agrees with check_course_page() in 047 — same four
    #  refusals the migration's own DO block probes.
    PAGE = {
        "tagline": "A one-line description.",
        "intro": "An opening paragraph about the class.",
        "facts": [{"k": "Time", "v": "6\u20137pm"}],
        "rules": [{"k": "When", "v": "Tuesdays."}],
        "cohorts": [{"key": "mens", "label": "Men's class"},
                    {"key": "womens", "label": "Women's class"}],
        "exp_label": "How much do you know already?",
        "exp": [{"key": "none", "label": "Nothing at all"},
                {"key": "some", "label": "A little"}],
        "open": "Fill in the form below.",
        "closed": "Ring the office to be told about the next one.",
    }

    def page_check(doc, mode="separate"):
        return pg.evaluate(
            "a => { try { return { r: window.__CLASSPAGE_FORM.check(a[0], a[1]) }; } "
            "catch (e) { return { threw: String(e) }; } }", [doc, mode])

    ok = page_check(PAGE)
    check(ok.get("r") == [],
          "a complete class page was refused by the merged screen: %r" % ok)

    #  A made-up cohort is the one that matters: it would save happily and then
    #  refuse every sign-up against it with a raw constraint error.
    invented = dict(PAGE, cohorts=PAGE["cohorts"] +
                    [{"key": "children", "label": "Children"}])
    r = page_check(invented)
    check(r.get("r") != [],
          "a made-up cohort was accepted. course_registrations allows only "
          "mens, womens and all, so every sign-up against it would be refused "
          "by the database with a message nobody can act on.")

    r = page_check(PAGE, "single")
    check(r.get("r") != [],
          "two sessions were accepted for a class set to one session for "
          "everyone")

    r = page_check(dict(PAGE, closed=""))
    check(r.get("r") != [],
          "a class page with no wording for when sign-ups are shut was "
          "accepted — that is what most people read, most of the year")

    r = page_check(dict(PAGE, exp=[{"key": "a", "label": "x"}]))
    check(r.get("r") != [],
          "an experience question with one answer was accepted")

    # ------------------------------------------------- removing a class
    #
    #  043 had no delete at all, which was right for a class people had signed
    #  up for and wrong for one created by mistake five minutes earlier. 048
    #  added it; 049 fixed the count-of-one wording. The refusal comes from the
    #  database, so the screen must not invent its own.
    mig = open("db/049_one_person_is_not_people.sql", encoding="utf-8").read()
    check("somebody has signed up for it" in mig,
          "049 no longer carries the singular wording this test was written "
          "against")
    check("% people have signed up for it" in mig,
          "049 no longer carries the plural wording")

    js = open("courses/app.js", encoding="utf-8").read()
    check("delete_course" in js,
          "the merged screen never calls delete_course, so a class created by "
          "mistake can never be taken out")
    check("window.confirm" in js or "confirm(" in js,
          "removing a class does not ask first, and it is permanent")
    check(pg.evaluate("() => !!document.getElementById('cc-list')"),
          "there is no class list on the merged screen")

    check(errs == [], "the courses screen threw: %s" % errs[:2])
    pg.close()

    # =================================================== the public page
    def home(rows, status=200):
        pg = b.new_page(viewport={"width": 1280, "height": 900})
        seen = []
        pg.on("pageerror", lambda e: seen.append(str(e)[:140]))
        pg.route("**/rest/v1/rpc/courses_public", lambda r: r.fulfill(
            status=status, content_type="application/json",
            body=json.dumps(rows) if status == 200 else "no"))
        pg.route("**/rest/v1/notices_live*", lambda r: r.fulfill(
            status=200, content_type="application/json", body="[]"))
        pg.goto(BASE, wait_until="load", timeout=45000)
        pg.wait_for_timeout(1500)
        return pg, seen

    def look(pg):
        return pg.evaluate("""() => {
          const out = {};
          for (const h of document.querySelectorAll('.course-reg')) {
            const k = h.getAttribute('data-course');
            out[k] = {
              form:   !!h.querySelector('form'),
              closed: !!h.querySelector('.adm-status'),
              lead:   (h.querySelector('.cform-lead') || {}).textContent || ''
            };
          }
          return out;
        }""")

    OPEN2 = [{"key": "arabic", "name": "Arabic Classes", "is_open": True,
              "capacity": 15, "sort_order": 1, "places_left": 3},
             {"key": "ghusl", "name": "Ghusl Workshop", "is_open": True,
              "capacity": 15, "sort_order": 2, "places_left": 15}]

    # ---------------------------------- 4. a closed class closes on the website
    shut = json.loads(json.dumps(OPEN2))
    shut[0]["is_open"] = False
    pg, seen = home(shut)
    r = look(pg)
    check(r.get("arabic", {}).get("closed") is True,
          "the database says the Arabic class is CLOSED and the website still "
          "shows the form. That is the whole bug this was built to prevent: "
          "register_for_course() raises on a closed course, so somebody fills "
          "in eleven fields and is handed a raw 400.")
    check(r.get("arabic", {}).get("form") is False,
          "the closed class still has a form in it")
    check(r.get("ghusl", {}).get("form") is True,
          "closing one class closed the other as well")
    check(seen == [], "the home page threw: %s" % seen[:2])
    pg.close()

    # -------------------------------------------- 6. places left, up front
    pg, seen = home(OPEN2)
    r = look(pg)
    check("3 places" in r.get("arabic", {}).get("lead", ""),
          "the Arabic class has 3 places left and the page does not say so "
          "before the form: %r" % r.get("arabic", {}).get("lead", "")[:120])
    full = json.loads(json.dumps(OPEN2))
    full[0]["places_left"] = 0
    pg.close()

    pg, seen = home(full)
    r = look(pg)
    lead = r.get("arabic", {}).get("lead", "")
    check("waiting list" in lead.lower(),
          "a full class does not say the registration goes on the waiting "
          "list, so somebody finds out on the confirmation screen: %r" % lead[:120])
    check(r.get("arabic", {}).get("form") is True,
          "a full class hid its form — a full class still takes registrations, "
          "they go on the waiting list")
    check(seen == [], "the home page threw: %s" % seen[:2])
    pg.close()

    # ------------------------------ 5. failure and nonsense take nothing away
    for label, rows, status in (("a 500", [], 500),
                                ("an empty list", [], 200),
                                ("rows for a class the page does not have",
                                 [{"key": "nosuch", "name": "x", "is_open": False,
                                   "capacity": 1, "sort_order": 1,
                                   "places_left": 0}], 200)):
        pg, seen = home(rows, status)
        r = look(pg)
        for k in ("arabic", "ghusl"):
            check(r.get(k, {}).get("form") is True,
                  "%s closed the %s class. The built-in state is open, so a "
                  "failed request must never take a form away." % (label, k))
        check(seen == [], "%s made the page throw: %s" % (label, seen[:2]))
        pg.close()

    b.close()

print("\n" + ("ALL PASS — %d good cases, %d bad, and the website opens, closes, "
              "counts and survives failure" % (len(GOOD), len(BAD))
              if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails[:20])))
sys.exit(1 if fails else 0)
