"""The screen the committee uses to upload a prayer timetable.

15 September 2026. The timetable moved into the database so the masjid can
change its own prayer times without a developer. This is the screen that makes
that true, and the parser inside it is the thing worth testing: it decides
what reaches the database, and what reaches the database is what several
hundred people set their day by.

WHAT THIS GUARDS

  *  1  THE REAL TIMETABLE ROUND-TRIPS. The masjid's own 2026 file, written
        out as CSV and read back by this parser, must give 365 clean rows and
        no complaints. If the parser cannot read the masjid's actual data then
        nothing else here matters.

  *  2  A COMMA INSIDE A VALUE. The Jumuʿah column is two times separated by a
        comma — the value contains the delimiter. A spreadsheet exports that
        quoted; a person pasting by hand does not. BOTH have to work. The
        first version of this parser accepted only the quoted form, which
        rejected every Friday and nothing else — the sort of fault that gets
        diagnosed as "the upload is broken" a month later.

  *  3  A TRANSPOSED COLUMN IS CAUGHT. Two columns swapped in a spreadsheet is
        the mistake somebody will really make, every value still looks like a
        time, and it is invisible in a wall of 365 rows.

  *  4  BRITISH DATES ARE READ AS BRITISH. 01/02/2027 is the first of
        February. Reading it the American way would shift the whole timetable
        by up to eleven months with every individual row still looking valid.

  *  5  NOTHING IS SAVEABLE UNTIL IT HAS BEEN CHECKED, and editing the paste
        after a check disables saving again.

  *  6  THE PARSER NEVER THROWS. Somebody pasting a spreadsheet should get a
        list of what is wrong, not a blank screen.

Run:  python3 _test/timetable_editor_test.py
"""
from playwright.sync_api import sync_playwright
import functools
import http.server
import json
import os
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


ROW = "2027-01-01,x,06:36,07:45,08:26,12:20,12:45,14:13,14:45,16:06,17:48,18:30,"

#  (label, csv, how many rows should survive, a phrase the complaint must contain)
CASES = [
    ("a plain day",                ROW, 1, None),
    ("a Friday, quoted",
     '2027-01-08,x,06:36,07:45,08:26,12:20,12:45,14:13,14:45,16:06,17:48,18:30,"13:15,14:00"',
     1, None),
    ("a Friday, NOT quoted",
     "2027-01-08,x,06:36,07:45,08:26,12:20,12:45,14:13,14:45,16:06,17:48,18:30,13:15,14:00",
     1, None),
    ("a heading row is ignored",
     "Date,Hijri,Fajr,Fajr J,Sunrise,Zuhr,Zuhr J,Asr,Asr J,Maghrib,Isha,Isha J,Jumuah\n" + ROW,
     1, None),
    ("a time written 6.36",
     ROW.replace("06:36", "6.36"), 0, "not a 24-hour time"),
    ("Zuhr and Asr swapped",
     "2027-01-01,x,06:36,07:45,08:26,15:00,15:15,12:00,12:15,16:06,17:48,18:30,",
     0, "out of order"),
    ("the same day twice",       ROW + "\n" + ROW, 1, "listed twice"),
    ("only four columns",        "2027-01-01,x,06:36,07:45", 0, "columns"),
    ("two years at once",
     ROW + "\n" + ROW.replace("2027", "2028"), 2, "more than one year"),
    ("a broken Jumuah value",    ROW + "1315", 0, "Jumu"),
    ("an empty paste",           "", 0, "nothing pasted"),
    ("utter nonsense",           "banana\nsplit", 0, None),
]

#  1. The masjid's real year, written out the way a spreadsheet would.
rows = json.load(open("build-inputs/full2026.json"))


def as_csv(rows):
    out = []
    for r in rows:
        jum = r[13]
        cells = ["2026-%02d-%02d" % (r[0], r[1]), r[2]] + [str(x) for x in r[3:13]]
        cells.append('"%s"' % jum if jum else "")
        out.append(",".join(cells))
    return "\n".join(out)


REAL = as_csv(rows)

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    pg = b.new_page(viewport={"width": 1280, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:140]))
    pg.goto(BASE + "times/", wait_until="load", timeout=45000)
    pg.wait_for_timeout(1200)

    check(pg.evaluate("() => !!window.__TIMETABLE_PARSER"),
          "the parser is not exposed, so none of this can be tested")

    # ---------------------------------------------------- 1. the real thing
    real = pg.evaluate(
        "t => { const r = window.__TIMETABLE_PARSER.read(t, null); "
        "return { rows: r.rows.length, year: r.year, problems: r.problems.slice(0,3) }; }",
        REAL)
    check(real["rows"] == len(rows),
          "the masjid's own 2026 timetable did not round-trip: %d of %d rows "
          "survived. Problems: %r" % (real["rows"], len(rows), real["problems"]))
    check(real["problems"] == [],
          "the masjid's own timetable produced complaints: %r" % real["problems"])
    check(real["year"] == 2026,
          "the year was read as %r, not 2026" % real["year"])

    # --------------------------------------------------- 2,3,4,6. the cases
    for label, csv, want_rows, want_says in CASES:
        r = pg.evaluate(
            "t => { try { const x = window.__TIMETABLE_PARSER.read(t, null); "
            "return { rows: x.rows.length, problems: x.problems }; } "
            "catch (e) { return { threw: String(e) }; } }", csv)
        check("threw" not in r,
              "%s: the parser THREW instead of reporting — %s" % (label, r.get("threw")))
        if "threw" in r:
            continue
        check(r["rows"] == want_rows,
              "%s: %d row(s) survived, expected %d. Problems: %r"
              % (label, r["rows"], want_rows, r["problems"][:2]))
        if want_says:
            check(any(want_says.lower() in p.lower() for p in r["problems"]),
                  "%s: nothing said %r. Problems: %r" % (label, want_says, r["problems"]))
        else:
            check(r["problems"] == [] or want_rows == 0,
                  "%s: unexpected complaints %r" % (label, r["problems"]))

    #  4, stated as its own assertion because getting it backwards is silent.
    d = pg.evaluate("() => window.__TIMETABLE_PARSER.readDate('01/02/2027')")
    check(d and d["m"] == 2 and d["d"] == 1,
          "01/02/2027 was read as month %r day %r. In Bolton that is the FIRST "
          "OF FEBRUARY; reading it the other way shifts the whole timetable "
          "and every row still looks valid." % (d and d["m"], d and d["d"]))

    #  Leap years, because the database refuses to publish a year that is not
    #  complete and 'complete' is 366 one year in four.
    check(pg.evaluate("() => window.__TIMETABLE_PARSER.daysIn(2028)") == 366,
          "2028 was not counted as a leap year, so a complete timetable for it "
          "would be refused as short")
    check(pg.evaluate("() => window.__TIMETABLE_PARSER.daysIn(2027)") == 365,
          "2027 was counted as a leap year")

    # ------------------------------------------------- 5. check before save
    #
    #  THIS BLOCK USED TO PASS WHATEVER THE CODE DID, and that is worth
    #  recording. The editor's listeners were attached inside mount(), which
    #  runs only after a real sign-in, so in a test they were never attached
    #  at all. The Save button is ALSO disabled in the markup — so reading it
    #  showed "disabled" whether the rule existed or had been deleted. The
    #  negative control caught it: deleting the line that disables Save on
    #  edit changed nothing and the suite still said ALL PASS.
    #
    #  So: wire the editor for real, then deliberately ENABLE the button
    #  first. Now "disabled" can only come from the code under test.
    pg.evaluate("""() => {
      const g = document.getElementById('view-signin'); if (g) g.hidden = true;
      const a = document.getElementById('view-app');    if (a) a.hidden = false;
      window.__TIMETABLE_PARSER.wire();
      document.getElementById('tt-save').disabled = false;
    }""")

    pg.fill("#tt-year", "2027")
    pg.fill("#tt-paste", ROW)
    after_type = pg.evaluate("() => document.getElementById('tt-save').disabled")
    check(after_type is True,
          "typing in the paste box did not disable Save. Somebody can check a "
          "good year, paste a bad one over it and save what was never checked.")

    #  A good paste, checked, enables it.
    pg.click("#tt-check")
    pg.wait_for_timeout(250)
    ok_state = pg.evaluate("""() => ({
        disabled: document.getElementById('tt-save').disabled,
        shown: !document.getElementById('tt-report').hidden })""")
    check(ok_state["disabled"] is False,
          "a clean single row was checked and Save stayed disabled, so nothing "
          "can ever be saved")
    check(ok_state["shown"], "the check produced no report")

    #  And a bad paste, checked, does not.
    pg.fill("#tt-paste", ROW.replace("06:36", "6.36"))
    pg.click("#tt-check")
    pg.wait_for_timeout(250)
    bad_state = pg.evaluate("""() => ({
        disabled: document.getElementById('tt-save').disabled,
        bad: document.getElementById('tt-report').classList.contains('tt-bad') })""")
    check(bad_state["disabled"] is True,
          "a paste the checker REJECTED left Save enabled — the one thing this "
          "screen must never do is write a broken timetable to the database")
    check(bad_state["bad"], "a rejected paste was not shown as a problem")

    check(errs == [], "the page threw: %s" % errs[:2])
    pg.close()
    b.close()

print("\n" + ("ALL PASS — the real %d-day timetable round-trips, %d paste cases"
              % (len(rows), len(CASES))
              if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails[:20])))
sys.exit(1 if fails else 0)
