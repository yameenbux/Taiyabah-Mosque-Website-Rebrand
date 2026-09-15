"""The prayer timetable, and the rule that it must never depend on a network.

15 September 2026. The timetable used to be a constant compiled into the page:
365 rows for 2026 and nothing else. Two problems with that, and the second is
the one with a date on it.

  *  The masjid could not change its own prayer times. Editing a jamāʿah time
     meant editing a JSON file, running two Python scripts and pushing to
     GitHub, which nobody on the committee can do and none of them should have
     to learn.

  *  ON 1 JANUARY 2027 IT STOPS. The page checks `y === 2026` in eleven
     places. On the first of January every one of them goes false, the
     countdown says "Timetable not loaded", and the most common reason anybody
     opens this website is gone — at exactly the point Yameen is meant to have
     stepped back.

The timetable now comes from the database, which the committee can edit. But
prayer times are the last thing on this site that should wait for a network,
so the built-in year is kept as the FLOOR: the page paints from it
immediately, then asks the database for something better and swaps only if
what comes back is complete and sane.

WHAT THIS GUARDS, AND EVERY ONE OF THEM IS A WAY OF BEING WRONG

  *  1  WITH NO NETWORK AT ALL, THE TIMES ARE STILL RIGHT. This is the whole
        design. It is also the state this test container is always in, which
        is convenient: the default case here is the worst case in Bolton.

  *  2  A GOOD YEAR IS ACCEPTED and actually reaches the screen.

  *  3  A BAD YEAR IS REFUSED, SILENTLY, and the built-in one stays. Tested
        six ways: truncated, wrong shape, a time that is not a time, a day
        listed twice, today missing, and outright nonsense. A wrong timetable
        that loads is far worse than a right one that does not update — the
        visitor cannot tell, and they will pray at the wrong time.

  *  4  NOTHING WAITS FOR THE FETCH. The times must be painted before the
        request is even made.

  *  5  THE YEAR IS NOT HARD-CODED ANY MORE. `2026` must not appear as a bare
        comparison in the timetable code; it comes from BUILT_IN_YEAR, which
        build.py derives from the data file's own name.

Run:  python3 _test/prayer_times_test.py
"""
from playwright.sync_api import sync_playwright
import datetime
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


# ------------------------------------------------------------------ 5. static
page = open("index.html", encoding="utf-8").read()
script = re.search(r"const BUILT_IN_TIMETABLE.*?upgradeTimetable\(\);", page, re.S)
check(script is not None, "the timetable script could not be found in index.html")
if script:
    body = script.group(0)
    #  The rows themselves are full of years; only look at the CODE after them.
    code = body[body.index("const BUILT_IN_YEAR"):]
    bare = re.findall(r"[=!]==\s*2026\b|\b2026\s*[=!]==", code)
    check(not bare,
          "the timetable code still compares against a hard-coded 2026 in %d "
          "place(s) — that is the thing that breaks on 1 January: %r"
          % (len(bare), bare[:4]))
    check("BUILT_IN_YEAR" in code and "TT_YEAR" in code,
          "BUILT_IN_YEAR / TT_YEAR are missing, so the year is not a variable")

built_in_year = re.search(r"const BUILT_IN_YEAR\s*=\s*(\d{4})", page)
check(built_in_year is not None, "BUILT_IN_YEAR was not substituted by build.py")
YEAR = int(built_in_year.group(1)) if built_in_year else 2026

rows = json.load(open("build-inputs/full%d.json" % YEAR))
days = (datetime.date(YEAR, 12, 31) - datetime.date(YEAR, 1, 1)).days + 1
check(len(rows) == days,
      "build-inputs/full%d.json has %d rows and %d has %d days"
      % (YEAR, len(rows), YEAR, days))


#  TODAY'S built-in Fajr jamāʿah, read from the same file the page is built
#  from. The first version of this test hard-coded "07:45", which is 1
#  January's time — so every assertion failed on 15 September while the code
#  was doing exactly the right thing. A test's baseline has to be derived from
#  the same source as the thing it is checking, or it is just a second guess.
_t = datetime.date.today()
_today_row = next((r for r in rows if r[0] == _t.month and r[1] == _t.day), None)
BUILT_IN_FAJR = _today_row[4] if _today_row else None
check(BUILT_IN_FAJR is not None,
      "the built-in timetable has no row for today (%s), so this test cannot "
      "tell a working page from a broken one" % _t)

#  Deliberately different from the built-in value, so "did it actually swap?"
#  is answerable by looking at one number on the screen.
NEW_FAJR = "04:04"


def good_year(year):
    """A complete, valid timetable for `year`, built from the real one."""
    out = []
    d = datetime.date(year, 1, 1)
    src = {(r[0], r[1]): r for r in rows}
    while d.year == year:
        base = src.get((d.month, d.day)) or src[(1, 1)]
        r = list(base)
        r[0], r[1] = d.month, d.day
        #  A minute later than the built-in one, so "did it actually swap?" is
        #  answerable by looking at the screen.
        r[4] = NEW_FAJR
        out.append(r)
        d += datetime.timedelta(days=1)
    return out


THIS_YEAR = datetime.date.today().year
GOOD = good_year(THIS_YEAR)

#  Every way an incoming timetable can be wrong.
def broken(kind):
    g = [list(r) for r in GOOD]
    if kind == "truncated":
        return g[:100]
    if kind == "not a list":
        return {"oops": True}
    if kind == "short rows":
        return [r[:8] for r in g]
    if kind == "a time that is not a time":
        g[40][4] = "7.46"
        return g
    if kind == "a day listed twice":
        g[40] = list(g[39])
        return g
    if kind == "today is missing":
        t = datetime.date.today()
        return [r for r in g if not (r[0] == t.month and r[1] == t.day)]
    if kind == "nonsense":
        return ["banana"]
    raise AssertionError(kind)


#  The stub answers SLOWLY on purpose. "The page paints before the network
#  returns" cannot be tested against an instant reply — the swap would already
#  have happened by the time the first screenshot is read, which is exactly
#  what the first version of this test saw and misread as a failure.
STUB = """a => {
  const rows = a[0], delay = a[1];
  window.__fetched = false;
  window.fetch = function (url) {
    if (String(url).indexOf('prayer_year') === -1) {
      return Promise.reject(new Error('blocked by the test'));
    }
    window.__fetched = true;
    if (rows === null) return Promise.reject(new Error('offline'));
    return new Promise(res => setTimeout(
      () => res({ ok: true, json: () => Promise.resolve(rows) }), delay));
  };
}"""

READ = """() => ({
  fajr: (document.getElementById('s-fajr') || {}).textContent || '',
  ttYear: window.TT_YEAR !== undefined ? window.TT_YEAR : null,
  fetched: !!window.__fetched
})"""

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    def run(rows_or_none, label):
        pg = b.new_page(viewport={"width": 1100, "height": 900})
        errs = []
        pg.on("pageerror", lambda e: errs.append(str(e)[:140]))
        pg.add_init_script(
            "window.__stub = %s; window.__args = [%s, 900];"
            % (STUB, json.dumps(rows_or_none)))
        pg.add_init_script("window.__stub(window.__args);")
        pg.goto(BASE + "index.html", wait_until="load", timeout=45000)
        pg.wait_for_timeout(250)
        painted = pg.evaluate(READ)          # the reply is still 650ms away
        pg.wait_for_timeout(2600)
        after = pg.evaluate(READ)
        check(errs == [], "%s: the page threw: %s" % (label, errs[:2]))
        pg.close()
        return painted, after

    # ----------------------------------------------------- 1 and 4: no network
    painted, after = run(None, "offline")
    check(BUILT_IN_FAJR in painted["fajr"],
          "offline: the built-in Fajr jamāʿah (%s) was not painted straight "
          "away — got %r. The times must never wait for a request."
          % (BUILT_IN_FAJR, painted["fajr"]))
    check(BUILT_IN_FAJR in after["fajr"],
          "offline: the times changed after a FAILED request — got %r. A failed "
          "upgrade must leave the screen exactly as it was." % after["fajr"])

    # ------------------------------------------------------------- 2: accepted
    painted, after = run(GOOD, "a good year")
    check(BUILT_IN_FAJR in painted["fajr"],
          "a good year: the built-in times were not on screen while the request "
          "was still outstanding — got %r. Nothing may wait for the network."
          % painted["fajr"])
    check(NEW_FAJR in after["fajr"],
          "a good year was NOT taken up: Fajr is still %r. The masjid would "
          "publish a new timetable and nothing would change." % after["fajr"])

    # ------------------------------------------------------------- 3: refused
    for kind in ("truncated", "not a list", "short rows",
                 "a time that is not a time", "a day listed twice",
                 "today is missing", "nonsense"):
        _, after = run(broken(kind), kind)
        check(BUILT_IN_FAJR in after["fajr"],
              "A BAD TIMETABLE WAS ACCEPTED (%s): Fajr now reads %r. The "
              "built-in times must stand." % (kind, after["fajr"]))

    b.close()

print("\n" + ("ALL PASS — built-in year %d, %d rows; 1 good year taken up, "
              "7 bad ones refused" % (YEAR, len(rows))
              if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails[:20])))
sys.exit(1 if fails else 0)
