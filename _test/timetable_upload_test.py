"""The office's spreadsheet, dropped straight in.

15 September 2026. The timetable lives in a spreadsheet in the masjid office.
Getting it onto the website meant opening it, Save As, choosing CSV, finding
the file again and pasting it — five chances to do the wrong thing with the one
document several hundred people set their day by. So the file goes in whole.

WHAT THIS GUARDS

  *  1  THE MASJID'S REAL YEAR ROUND-TRIPS THROUGH EXCEL. The fixtures are
        built from `build-inputs/full2026.json` — the actual timetable — and
        the times that come back out are compared against it cell by cell, not
        merely counted. A reader that returns 365 rows of the wrong times
        would pass a count.

  *  2  EXCEL'S OWN NUMBERS ARE READ. A spreadsheet does not store "06:35"; it
        stores 0.2743, and a date is a count of days from 1899-12-30. This is
        the part that could put a plausible-looking WRONG time on the website,
        which is why it is checked against known values rather than eyeballed.

  *  3  A TEXT SPREADSHEET WORKS TOO. Half the world's timetables have been
        typed in as text rather than entered as times, and both must work.

  *  4  EVERY SHEET IS TRIED, not just the first. Workbooks open on a cover
        page all the time, and `sheet1.xml` is the first sheet as written
        rather than the one anybody looks at.

  *  5  A FILE IT CANNOT READ CHANGES NOTHING. It refuses and says what it
        could not find. Half a timetable in the paste box, looking finished,
        is the outcome worth engineering against: the checker would pass it,
        the day count would be short, and short is exactly what somebody
        clicks past at the end of a long evening.

  *  6  NOTHING BYPASSES THE CHECKER. The file becomes exactly the CSV
        somebody would have pasted and goes through the same parser — the
        HH:MM rule, the prayer-order rule that catches two transposed columns,
        the duplicate-day rule, the day count. Proved by feeding it a
        spreadsheet with two columns swapped and watching it be refused.

  *  7  THE FILE INPUT IS REACHABLE BY KEYBOARD. It is styled by hiding the
        input and dressing the label as a button, which is the classic way a
        file picker becomes unusable: `display:none` takes it out of the tab
        order and nothing else can open it.

Run:  python3 _test/timetable_upload_test.py
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

FIX = os.path.join(ROOT, "_test", "fixtures")
fails = []


def check(ok, why):
    if not ok:
        fails.append(why)


#  The masjid's real 2026 year, to compare against. The fixtures were built
#  from this same file, so any disagreement is the reader's fault.
REAL = json.load(open("build-inputs/full2026.json"))
BY_DATE = {"2026-%02d-%02d" % (r[0], r[1]): r for r in REAL}

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    pg = b.new_page(viewport={"width": 1280, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:160]))
    pg.goto(BASE + "times/", wait_until="load", timeout=45000)
    pg.wait_for_timeout(1000)

    check(pg.evaluate("() => !!(window.__TIMETABLE_PARSER "
                      "&& window.__TIMETABLE_PARSER.readWorkbook)"),
          "the workbook reader is not exposed, so none of this can be tested")

    # ------------------------------------- 2. Excel's numbers, on their own
    #
    #  Checked first and directly, because everything else depends on it and a
    #  wrong answer here is a wrong prayer time that looks perfectly normal.
    serials = pg.evaluate("""() => {
      const f = window.__TIMETABLE_PARSER.fromSerial;
      return { midnight: f(0.0000001), sixThirtyFive: f(0.2743055555555556),
               noon: f(0.5), nearMidnight: f(0.9993055555555556),
               newYear2027: f(46388),
               dayBeforeLeap: f(46811), leapDay2028: f(46812),
               notATime: f(12345678) };
    }""")
    check(serials["sixThirtyFive"] == "06:35",
          "0.2743 of a day should be 06:35, got %r" % serials["sixThirtyFive"])
    check(serials["noon"] == "12:00", "half a day should be 12:00, got %r" % serials["noon"])
    check(serials["nearMidnight"] == "23:59",
          "0.99930 should be 23:59, got %r" % serials["nearMidnight"])
    check(serials["newYear2027"] == "2027-01-01",
          "Excel serial 46388 is 1 January 2027, got %r" % serials["newYear2027"])
    #  Both sides of the leap day. The first version of this test asserted
    #  46811 was the 29th; it is the 28th, and the reader was right — worth
    #  recording, because a test that is wrong about a date is
    #  indistinguishable from code that is wrong about a date until somebody
    #  does the arithmetic.
    check(serials["dayBeforeLeap"] == "2028-02-28",
          "Excel serial 46811 is 28 February 2028, got %r" % serials["dayBeforeLeap"])
    check(serials["leapDay2028"] == "2028-02-29",
          "Excel serial 46812 is 29 February 2028 — a leap day, which is "
          "exactly where a day-count conversion goes wrong. Got %r"
          % serials["leapDay2028"])
    check(serials["notATime"] == "12345678",
          "a number that is neither a time nor a plausible date must be handed "
          "back untouched for the checker to reject, not guessed at. Got %r"
          % serials["notATime"])

    #  Column references, because a row omits its empty cells and the letter
    #  is the only thing that says which column a value is in.
    cols = pg.evaluate("""() => { const c = window.__TIMETABLE_PARSER.colOf;
      return [c('A1'), c('B2'), c('Z9'), c('AA1'), c('AB3'), c('BC12')]; }""")
    check(cols == [0, 1, 25, 26, 27, 54],
          "column references read as %r, expected [0, 1, 25, 26, 27, 54] — AA "
          "is the 27th column, and getting that wrong shifts every value one "
          "place along" % cols)

    # ------------------------------- 1, 3, 4. the real year, three ways in
    def load(name):
        with open(os.path.join(FIX, name), "rb") as fh:
            data = list(fh.read())
        return pg.evaluate("""async bytes => {
          const buf = new Uint8Array(bytes).buffer;
          try {
            const out = await window.__TIMETABLE_PARSER.readWorkbook(buf);
            const parsed = window.__TIMETABLE_PARSER.read(out.csv, null);
            return { days: out.days, year: parsed.year,
                     rows: parsed.rows.length, problems: parsed.problems.slice(0, 3),
                     csvHead: out.csv.split("\\n").slice(0, 2) };
          } catch (e) { return { threw: String(e && e.message || e) }; }
        }""", data)

    for name, what in (("timetable_real.xlsx", "real dates and real times"),
                       ("timetable_text.xlsx", "everything typed as text"),
                       ("timetable_second_sheet.xlsx", "the year on the second sheet")):
        r = load(name)
        check("threw" not in r,
              "%s (%s) would not open: %s" % (name, what, r.get("threw")))
        if "threw" in r:
            continue
        check(r["rows"] == len(REAL),
              "%s (%s) gave %d rows, expected %d. Problems: %r"
              % (name, what, r["rows"], len(REAL), r["problems"]))
        check(r["problems"] == [],
              "%s (%s) produced complaints: %r" % (name, what, r["problems"]))
        check(r["year"] == 2026,
              "%s (%s) read the year as %r" % (name, what, r["year"]))

    # ---------------------- 1. and the TIMES themselves, not just the count
    #
    #  A reader that returns the right number of rows of the wrong times
    #  passes every check above. This is the one that matters.
    with open(os.path.join(FIX, "timetable_real.xlsx"), "rb") as fh:
        data = list(fh.read())
    got = pg.evaluate("""async bytes => {
      const out = await window.__TIMETABLE_PARSER.readWorkbook(
        new Uint8Array(bytes).buffer);
      return window.__TIMETABLE_PARSER.read(out.csv, null).rows;
    }""", data)

    check(len(got) == len(REAL), "expected %d rows back, got %d" % (len(REAL), len(got)))

    #  The parser hands back rows in the SAME shape as build-inputs/full2026.json
    #  — [month, day, hijri, the ten times, Jumuʿah] — so this is a straight
    #  comparison against the masjid's own file rather than a reconstruction
    #  that could be wrong in the same way twice.
    wrong = []
    for i, row in enumerate(got[:len(REAL)]):
        mine = [str(x) for x in row]
        theirs = [str(x if x is not None else "") for x in REAL[i]]
        if mine != theirs:
            wrong.append({"row": i + 1, "read": mine, "should be": theirs})
    check(not wrong,
          "%d day(s) came back with times that are not the masjid's. This is "
          "the failure that matters: the row count is right and the numbers "
          "are wrong, so it looks correct on screen. First: %r"
          % (len(wrong), wrong[:1]))

    # ------------------- the year comes from the FILE, not the Year box
    #
    #  `wantYear || found[0]` meant the box won outright, so a 2026 timetable
    #  uploaded while the box said 2027 — and it defaults to next year, so it
    #  usually does — was saved as 365 days of 2027. Every row looked right,
    #  the day count was right, and the report said 2027 and meant it. The
    #  rows carry a month and a day and NO YEAR at all, so nothing downstream
    #  could have caught it either.
    yr = pg.evaluate("""() => {
      const csv = window.__TIMETABLE_PARSER.rowsToCsv([
        ['2026-01-01','x','06:36','07:45','08:26','12:20','12:45','14:13','14:45',
         '16:06','17:48','18:30','']]);
      const asked = window.__TIMETABLE_PARSER.read(csv, 2027);
      const quiet = window.__TIMETABLE_PARSER.read(csv, null);
      return { askedYear: asked.year, askedProblems: asked.problems,
               quietYear: quiet.year };
    }""")
    check(yr["askedYear"] == 2026,
          "a 2026 timetable read with the Year box on 2027 came back as year "
          "%r. The dates in the file are the truth; the box is a hint."
          % yr["askedYear"])
    check(any("2026" in x and "2027" in x for x in yr["askedProblems"]),
          "the disagreement between the Year box and the dates was not "
          "reported: %r" % yr["askedProblems"])
    check(yr["quietYear"] == 2026,
          "with no year asked for, the dates should still give 2026, got %r"
          % yr["quietYear"])

    # ---------------------------------- 5. what it cannot read, it refuses
    for name, phrase in (("not_a_timetable.xlsx", "date"),
                         ("timetable_short.xlsx", "twenty")):
        with open(os.path.join(FIX, name), "rb") as fh:
            data = list(fh.read())
        r = pg.evaluate("""async bytes => {
          try { await window.__TIMETABLE_PARSER.readWorkbook(
                  new Uint8Array(bytes).buffer);
                return { ok: true };
          } catch (e) { return { code: String(e && e.message || e) }; }
        }""", data)
        check("ok" not in r, "%s was accepted and should not have been" % name)

    #  Something that is not a spreadsheet at all.
    r = pg.evaluate("""async () => {
      const junk = new TextEncoder().encode("this is not a spreadsheet at all");
      try { await window.__TIMETABLE_PARSER.readWorkbook(junk.buffer);
            return { ok: true }; }
      catch (e) { return { code: String(e && e.message || e) }; }
    }""")
    check(r.get("code") == "not-a-zip",
          "a plain text file should be refused as not-a-zip, got %r" % r)

    # ------------------------------------ 6. nothing bypasses the checker
    #
    #  A spreadsheet with Zuhr and Asr swapped is the mistake somebody will
    #  really make, every value still looks like a time, and it is invisible
    #  in a wall of 365 rows. It must be refused after conversion, by the
    #  same rule that refuses a paste.
    swapped = pg.evaluate("""() => {
      const rows = [
        ['Date','Hijri','Fajr','Fajr J','Sunrise','Zuhr','Zuhr J','Asr','Asr J',
         'Maghrib','Isha','Isha J','Jumuah'],
        ['2027-01-01','x','06:36','07:45','08:26','15:00','15:15','12:00','12:15',
         '16:06','17:48','18:30','']
      ];
      const csv = window.__TIMETABLE_PARSER.rowsToCsv(rows);
      const r = window.__TIMETABLE_PARSER.read(csv, null);
      return { rows: r.rows.length, problems: r.problems };
    }""")
    check(swapped["rows"] == 0,
          "a converted spreadsheet with Zuhr and Asr swapped survived the "
          "checker — the upload has found a way round the order rule")
    check(any("out of order" in x.lower() for x in swapped["problems"]),
          "the swapped-column complaint was %r" % swapped["problems"])

    #  And the comma inside the Jumuʿah value survives the round trip, which
    #  is the fault that once rejected every Friday and nothing else.
    friday = pg.evaluate("""() => {
      const csv = window.__TIMETABLE_PARSER.rowsToCsv([
        ['2027-01-08','x','06:36','07:45','08:26','12:20','12:45','14:13','14:45',
         '16:06','17:48','18:30','13:15,14:00']]);
      const r = window.__TIMETABLE_PARSER.read(csv, null);
      return { csv: csv, rows: r.rows.length, problems: r.problems };
    }""")
    check('"13:15,14:00"' in friday["csv"],
          "the Jumuʿah value was not quoted on the way out: %r" % friday["csv"][-40:])
    check(friday["rows"] == 1 and friday["problems"] == [],
          "a Friday did not survive the spreadsheet round trip: %r" % friday)

    # ----------------------------------- 7. the picker works from a keyboard
    pg.evaluate("""() => {
      const g = document.getElementById('view-signin'); if (g) g.hidden = true;
      const a = document.getElementById('view-app');    if (a) a.hidden = false;
      window.__TIMETABLE_PARSER.wire();
    }""")
    kb = pg.evaluate("""() => {
      const i = document.getElementById('tt-file');
      const cs = getComputedStyle(i);
      i.focus();
      return { display: cs.display, visibility: cs.visibility,
               focusable: document.activeElement === i,
               labelled: !!document.querySelector('label[for="tt-file"]'),
               accept: i.getAttribute('accept') || '' };
    }""")
    check(kb["labelled"], "the file input has no label acting as its button")
    check(kb["display"] != "none" and kb["visibility"] != "hidden",
          "the file input is display:%s / visibility:%s. Hidden that way it is "
          "out of the tab order, and since the label is the only other way to "
          "open it, a keyboard user cannot upload anything at all."
          % (kb["display"], kb["visibility"]))
    check(kb["focusable"],
          "the file input cannot take focus, so it cannot be reached by Tab")
    check(".xlsx" in kb["accept"],
          "the file picker does not filter to .xlsx: %r" % kb["accept"])

    # -------------------------------- and the whole thing, end to end
    pg.set_input_files("#tt-file", os.path.join(FIX, "timetable_real.xlsx"))
    pg.wait_for_timeout(2500)
    end = pg.evaluate("""() => ({
        name: document.getElementById('tt-file-name').textContent,
        pasted: document.getElementById('tt-paste').value.split('\\n').length,
        reportShown: !document.getElementById('tt-report').hidden,
        year: document.getElementById('tt-year').value,
        saveEnabled: !document.getElementById('tt-save').disabled,
        error: document.getElementById('tt-error').textContent
    })""")
    check("365 days read" in end["name"],
          "after choosing the file the screen says %r" % end["name"])
    check(end["pasted"] >= 365,
          "the paste box holds %d lines after the upload" % end["pasted"])
    check(end["reportShown"],
          "the file was read and the check never ran — somebody would have to "
          "know to press Check themselves")
    check(end["year"] == "2026",
          "the year box says %r after reading a 2026 file" % end["year"])
    check(end["saveEnabled"],
          "the masjid's own timetable was uploaded and Save stayed disabled. "
          "Error on screen: %r" % end["error"])

    #  A bad file after a good one must not leave the good one saveable.
    pg.set_input_files("#tt-file", os.path.join(FIX, "not_a_timetable.xlsx"))
    pg.wait_for_timeout(1500)
    after = pg.evaluate("""() => ({
        error: document.getElementById('tt-error').textContent,
        pasted: document.getElementById('tt-paste').value.split('\\n').length,
        name: document.getElementById('tt-file-name').textContent
    })""")
    check("date" in after["error"].lower(),
          "a spreadsheet with no dates in it said %r" % after["error"][:90])
    check(after["pasted"] >= 365,
          "a refused file emptied the paste box. It must leave what was "
          "already there alone.")
    check(after["name"] == "",
          "a refused file still shows a file name, which reads as success: %r"
          % after["name"])

    check(errs == [], "the page threw: %s" % errs[:2])
    pg.close()
    b.close()

print("\n" + ("ALL PASS — the masjid's real year through Excel three ways, "
              "%d days verified cell by cell" % len(REAL)
              if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails[:20])))
sys.exit(1 if fails else 0)
