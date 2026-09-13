"""/portals/ — the admin dashboard.

12 September 2026. The admin centre stopped being a list of five links and
became the page an administrator lands on.

WHAT THIS FILE GUARDS. The page draws whatever admin_dashboard() returned and
decides nothing itself — that is the design, and it is also the risk: a
renderer that quietly drops a field, mislabels money, or draws an office
account a panel it should not see would look completely normal.

So every section is driven by a STUBBED response, and the assertions are about
what ends up on screen:

  * 2  the calm state is a sentence, not a grid of noughts
  * 4  money owed shows the unpriced bookings SEPARATELY — the database counts
       them apart, and a renderer that folds them back in would undo that
  * 5  an office account is not drawn Gift Aid or the staff figures
  * 6  the log lists people, and counts the machine
  * 8  when the call fails the page says so instead of showing an empty
       dashboard that looks like a quiet day

Nothing here reaches Supabase. The client is replaced before the page's own
scripts run.

Run:  python3 _test/dashboard_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, re, json, http.server, socketserver, threading, functools
from datetime import datetime, timedelta, timezone

#  The log renders "Today HH:MM" only for a row dated today, so a fixture with
#  a hard-coded date passes on the day it was written and fails every day
#  after. This one failed the morning after — 12 September became "Sat" and the
#  assertion for "Today" went red with nothing wrong with the page.
#
#  A suite whose answer depends on the day it is run teaches people to ignore
#  it, which costs more than the assertion is worth. The times below are now
#  built from the clock. TODAY is deliberately mid-morning UTC rather than
#  "now minus an hour": at 00:30 that would land on yesterday and the same bug
#  would come back, once a night.
_now = datetime.now(timezone.utc)


def _today(hh, mm):
    return _now.replace(hour=hh, minute=mm, second=0, microsecond=0).isoformat()


def _ago(days, hh=9, mm=0):
    d = _now - timedelta(days=days)
    return d.replace(hour=hh, minute=mm, second=0, microsecond=0).isoformat()

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PAGE = "http://127.0.0.1:%d/portals/" % httpd.server_address[1]

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


BUSY = {
    "allowed": True, "is_admin": True,
    "as_at": _today(18, 41),
    "needs": [
        {"kind": "hall_hold", "urgency": "now", "ref": "HH-26-0009",
         "title": "Hall held, deposit not paid",
         "detail": "Ismail Desai - Sat 04 Oct", "where": "venue",
         "expires_at": None},
        {"kind": "nikah_new", "urgency": "soon", "ref": "NK-26-0004",
         "title": "Nikah date needs a call",
         "detail": "Fatima Patel - 07700900118", "where": "venue",
         "since": _ago(3)},
        {"kind": "volunteers", "urgency": "soon", "ref": None,
         "title": "2 food bank volunteers not yet rung",
         "detail": "1 free Sunday mornings", "where": "volunteers"},
    ],
    "estate": {"bookings_ahead": 6, "next_booking": "2026-09-20",
               "owed_p": 125000, "owed_count": 2, "owed_unknown": 1,
               "volunteers": 12, "volunteers_sun": 8,
               "class_places": 14, "class_waiting": 3},
    "areas": {
        "venue":      {"new": 2, "upcoming": 6, "holding": 1, "balance": 3},
        "courses":    {"open": 2, "signed": 14, "waiting": 3},
        "giftaid":    {"to_claim": 9, "worth_p": 31200, "incomplete": 0},
        "volunteers": {"willing": 12, "sundays": 8, "to_ring": 2},
    },
    "log": [
        {"at": _today(13, 20), "kind": "staff",
         "what": "Deposit taken in cash", "ref": "HH-26-0008", "who": "Yameen Bux"},
        {"at": _today(8, 38), "kind": "public",
         "what": "Hall booking came in", "ref": "HH-26-0009", "who": "from the website"},
    ],
    "auto_count": 120,
    "housekeeping": {"accounts": 7, "admins": 4, "no_2fa": 1,
                     "last_holds": _today(17, 20),
                     "last_purge": _today(2, 25)},
}

QUIET = json.loads(json.dumps(BUSY))
QUIET["needs"] = []
QUIET["log"] = []
QUIET["auto_count"] = 0
QUIET["housekeeping"] = dict(QUIET["housekeeping"], no_2fa=0)
QUIET["estate"] = dict(QUIET["estate"], owed_p=0, owed_count=0, owed_unknown=0)

OFFICE = json.loads(json.dumps(BUSY))
OFFICE["is_admin"] = False
OFFICE["areas"] = dict(OFFICE["areas"], giftaid=None, courses=None)
OFFICE["housekeeping"] = None
OFFICE["needs"] = [n for n in OFFICE["needs"] if n["kind"] != "giftaid"]


def stub(payload, roles, fail=False):
    return """
(function(){
  var DASH = %s, ROLES = %s, FAIL = %s;
  var client = {
    auth: {
      getSession: function(){ return Promise.resolve({data:{session:{user:{
        id:'u1', email:'yameen@example.test'}}}}); },
      getUser: function(){ return Promise.resolve({data:{user:{
        id:'u1', email:'yameen@example.test'}}}); },
      signOut: function(){ return Promise.resolve({}); },
      mfa: { getAuthenticatorAssuranceLevel: function(){
               return Promise.resolve({data:{currentLevel:'aal2', nextLevel:'aal2'}}); },
             listFactors: function(){ return Promise.resolve({data:{totp:[{id:'f1'}]}}); } }
    },
    from: function(t){
      var rows = t === 'profiles' ? {full_name:'Yameen Bux', email:'yameen@example.test'}
               : ROLES.map(function(r){ return {role:r}; });
      var q = {
        select:function(){ return q; }, eq:function(){ return q; },
        maybeSingle:function(){ return Promise.resolve({data:rows, error:null}); },
        then:function(res){ return Promise.resolve({data:rows, error:null}).then(res); }
      };
      return q;
    },
    rpc: function(name){
      window.__RPCS = window.__RPCS || [];
      window.__RPCS.push(name);
      if (FAIL) return Promise.resolve({data:null, error:{message:'the database said no'}});
      return Promise.resolve({data:DASH, error:null});
    }
  };
  var s = { createClient: function(){ return client; } };
  Object.defineProperty(window, 'supabase',
    { value:s, writable:false, configurable:false });
})();
""" % (json.dumps(payload), json.dumps(roles), "true" if fail else "false")


def open_page(b, payload, roles, fail=False):
    pg = b.new_page(viewport={"width": 1280, "height": 1200})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.add_init_script(stub(payload, roles, fail))
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1200)
    return pg, errs


def text(pg, sel):
    node = pg.query_selector(sel)
    return re.sub(r"\s+", " ", node.inner_text()) if node else ""


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1. A BUSY DAY, AS AN ADMINISTRATOR
    # =====================================================================
    pg, errs = open_page(b, BUSY, ["admin", "hall_office"])

    check(pg.is_visible("#view-list"), "the dashboard did not open for an administrator")
    check(pg.evaluate("document.querySelector('.shell').classList.contains('dash-mode')"),
          "the shell stayed in its 420px sign-in layout — a dashboard needs the width")

    #  ONE call, not eight. Eight round trips is eight ways to half-fail.
    rpcs = pg.evaluate("window.__RPCS || []")
    check(rpcs.count("admin_dashboard") == 1,
          "expected exactly one admin_dashboard call, saw %r" % rpcs)

    # =====================================================================
    #  2. NEEDS YOU
    # =====================================================================
    needs = pg.eval_on_selector_all(".need", "els => els.map(e => e.innerText)")
    check(len(needs) == 3, "expected three things waiting, drew %d" % len(needs))
    check(pg.eval_on_selector(".need", "e => e.className").find("now") != -1,
          "the expiring hold is not marked urgent")
    check("HH-26-0009" in " ".join(needs), "the hold's reference is not shown")
    check("Ismail Desai" in " ".join(needs), "the hirer's name is not shown")
    check(pg.eval_on_selector(".need", "e => e.getAttribute('href')") == "../venue/",
          "the hold does not link to the venue portal")
    check("waiting 2 days" in " ".join(needs).lower(),
          "the nikah request does not say how long it has been waiting: %r" % needs)

    # =====================================================================
    #  3. WHAT YOU CAN DO, NOT JUST WHAT IS THERE
    # =====================================================================
    areas = pg.eval_on_selector_all(".area", "els => els.map(e => e.innerText)")
    check(len(areas) == 6, "expected six areas for an admin, drew %d" % len(areas))
    joined = " ".join(areas)
    for name in ["Hall Hire", "Adult classes", "Gift Aid", "Food Bank", "Madrasah",
                 "Who can get in"]:
        check(name in joined, "%r is missing from the areas" % name)
    check("cash deposit" in joined,
          "the hall card does not say what you can do there — that is the "
          "difference between a dashboard and a list of links")
    check("£312" in joined, "the Gift Aid card does not show what is worth claiming")
    #  lowercased: the chip is uppercased by CSS and innerText returns the
    #  transformed text. Third time today.
    check("without 2fa" in joined.lower(),
          "the access card does not flag the account with no authenticator: %r" % joined[:200])
    hrefs = pg.eval_on_selector_all(".area", "els => els.map(e => e.getAttribute('href'))")
    check("../access/" in hrefs,
          "the Who can get in card does not link to the access screen: %r" % hrefs)

    # =====================================================================
    #  4. THE MONEY
    #
    #  The database deliberately counts unpriced bookings SEPARATELY. A
    #  renderer that folds them back into the total would undo that in one
    #  line and look completely normal doing it.
    # =====================================================================
    tiles = text(pg, "#dash-tiles")
    check("£1,250" in tiles, "money owed is not shown in pounds: %r" % tiles)
    check("old rate" in tiles.lower() and "not priced" in tiles.lower(),
          "THE UNPRICED BOOKING IS NOT DECLARED. The masjid would read £1,250 "
          "as everything it is owed: %r" % tiles)
    check("6" in tiles and "12" in tiles, "the estate tiles are not filled in: %r" % tiles)
    check("20 Sep" in tiles, "the next booking date is not shown: %r" % tiles)

    # =====================================================================
    #  6. THE LOG
    # =====================================================================
    log = text(pg, "#dash-log")
    check("Deposit taken in cash" in log, "the staff action is missing from the log")
    check("Yameen Bux" in log, "the log does not say who did it")
    check("from the website" in log, "arrivals are not marked as coming from the public")
    check("Today" in log, "the log carries no times: %r" % log)
    check("Expired holds cleared" not in log,
          "AUTOMATIC JOBS ARE IN THE LOG. 120 of 130 rows are one purge; a "
          "feed with them in is 92% noise")
    auto = text(pg, "#dash-auto")
    check("120" in auto, "the automatic jobs are not counted: %r" % auto)

    # =====================================================================
    #  7. THE WARNING THAT HAS BEEN INVISIBLE
    # =====================================================================
    house = text(pg, "#dash-house")
    check("no authenticator" in house.lower(),
          "the account without an authenticator is not flagged: %r" % house)
    check("7 accounts" in house and "4 administrators" in house,
          "the account figures are not shown: %r" % house)

    check(errs == [], "uncaught exceptions on a busy day: %s" % errs)
    pg.close()

    # =====================================================================
    #  2b. THE QUIET DAY — the whole reason this layout was argued over
    # =====================================================================
    pg, errs = open_page(b, QUIET, ["admin"])
    clear = text(pg, "#dash-needs")
    check("Nothing is waiting" in clear,
          "on a quiet day the page does not say so in words: %r" % clear)
    check(pg.query_selector(".need") is None,
          "empty cards were drawn on a quiet day")
    check(text(pg, "#dash-tiles") != "",
          "the estate tiles vanished on a quiet day — they are the half that "
          "is still worth reading")
    check("Nobody has needed" in text(pg, "#dash-log"),
          "the empty log says nothing: %r" % text(pg, "#dash-log"))
    #  is_visible, NOT the `hidden` property: the property was true while the
    #  element was still on screen, because .logauto{display:flex} beats the
    #  browser's [hidden]{display:none}. Asserting the property passed and
    #  proved nothing.
    check(not pg.is_visible("#dash-auto"),
          "the automatic-jobs line is drawn with nothing to count")
    check("Every staff account has an authenticator" in text(pg, "#dash-house"),
          "the all-clear on two-step is not stated: %r" % text(pg, "#dash-house"))
    check(errs == [], "uncaught exceptions on a quiet day: %s" % errs)
    pg.close()

    # =====================================================================
    #  5. AN OFFICE ACCOUNT
    #
    #  Gift Aid is donors' names and home addresses. The database already
    #  withholds it; this checks the page does not invent a card for it.
    # =====================================================================
    pg, errs = open_page(b, OFFICE, ["hall_office"])
    areas = " ".join(pg.eval_on_selector_all(".area", "els => els.map(e => e.innerText)"))
    check("Gift Aid" not in areas, "AN OFFICE ACCOUNT WAS DRAWN GIFT AID: %r" % areas)
    check("Adult classes" not in areas, "an office account was drawn adult classes")
    check("Madrasah" not in areas, "an office account was drawn the madrasah portal")
    check("Who can get in" not in areas,
          "AN OFFICE ACCOUNT WAS DRAWN THE ACCESS SCREEN")
    check("Hall Hire" in areas, "an office account cannot see hall hire")
    check("Food Bank" in areas, "an office account cannot see the volunteers")
    check(not pg.is_visible("#dash-house-pane"),
          "an office account was shown the staff account figures")
    check(errs == [], "uncaught exceptions for an office account: %s" % errs)
    pg.close()

    # =====================================================================
    #  8. WHEN THE CALL FAILS
    #
    #  An empty dashboard looks exactly like a quiet day. It must not.
    # =====================================================================
    pg, errs = open_page(b, BUSY, ["admin"], fail=True)
    err = text(pg, "#dash-error")
    check(pg.is_visible("#dash-error"),
          "the dashboard failed to load and said nothing — indistinguishable "
          "from a quiet day")
    check("Couldn't load" in err or "could not load" in err.lower(),
          "the error does not say what went wrong: %r" % err)
    check(pg.query_selector(".area") is not None,
          "a failed load left no way to reach any area at all")
    check(errs == [], "uncaught exceptions on a failed load: %s" % errs)
    pg.close()

    # =====================================================================
    #  9. IT SURVIVES A PHONE
    # =====================================================================
    pg, errs = open_page(b, BUSY, ["admin"])
    for w in [1280, 900, 760, 390]:
        pg.set_viewport_size({"width": w, "height": 1000})
        pg.wait_for_timeout(250)
        check(pg.evaluate("document.documentElement.scrollWidth") <= w + 2,
              "the dashboard scrolls sideways at %dpx" % w)
        bb = pg.query_selector(".need").bounding_box()
        check(bb and bb["width"] > 120, "the cards collapsed at %dpx: %r" % (w, bb))
    check(errs == [], "uncaught exceptions while resizing: %s" % errs)
    pg.close()

    b.close()

httpd.shutdown()
print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
