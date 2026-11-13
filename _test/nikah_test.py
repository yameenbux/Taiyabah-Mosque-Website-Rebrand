"""The Nikāḥ page — the calendar, and the particulars of five people.

14 September 2026. The form stopped asking for a second date, stopped offering
Fajr, and started asking for the bridegroom, the bride, the bride's
representative and two witnesses.

WHAT THIS FILE GUARDS. Not the rules — those are in Postgres
(request_nikah_date, and the couple_must_be_adults constraint on
nikah_people). What it guards is the page:

  *  1  one date, not two. The 1st/2nd choice toggle is gone, and so is any
        way of picking a second date by accident
  *  2  THE TIME IS A CLOCK TIME, NOT A PRAYER. It was five prayer chips with
        the jamāʿah time printed under each, and that time came from the
        FIRST of the two dates a family may offer — so it was wrong for
        anyone the office booked on the second. No prayer name is offered
        here now, and the control is a real <input type="time"> held to the
        masjid's window on the quarter hour
  *  3  the form does not appear until a date AND a time are chosen — the
        thirty-odd fields below are not something to drop on somebody who has
        not picked a day yet
  *  4  five people, numbered 02 to 06, each with the six fields
  *  5  AN UNDER-18 BRIDE OR GROOM IS REFUSED, in words that say why. Since
        27 February 2023 a nikāḥ for a child is a criminal offence in England
        and Wales whether or not it is legally binding, so this is not a
        masjid preference and must not quietly become one
  *  6  a 17-year-old WITNESS is accepted — without this, test 5 would also
        pass on a form that refuses every age
  *  7  the declaration says the other four people were told. Four of the five
        are not at the screen and have agreed to nothing
  *  8  nothing is posted until the form is valid

Nothing here reaches Supabase; the fetch is stubbed and the payload is
captured so the assertions can be about what WOULD have been sent.

Run:  python3 _test/nikah_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, re, json, http.server, socketserver, threading, functools
from datetime import date, timedelta

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PAGE = "http://127.0.0.1:%d/index.html" % httpd.server_address[1]

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


#  The page needs config to exist before it will post at all, and a fetch that
#  records instead of sending. Both are installed before the page's own scripts
#  run, and the client is made non-writable — a harness that lets the page
#  overwrite its own stub has been proving nothing on this project before.
STUB = """
(function(){
  window.__POSTED = [];
  var realFetch = window.fetch;
  window.fetch = function(url, opts){
    if (String(url).indexOf('request_nikah_date') !== -1) {
      window.__POSTED.push(JSON.parse(opts.body));
      return Promise.resolve(new Response(
        JSON.stringify({reference:'NK-26-9999', preferred_date:'2026-10-30'}),
        {status:200, headers:{'Content-Type':'application/json'}}));
    }
    return realFetch.apply(this, arguments);
  };
  Object.defineProperty(window, 'TAIYABAH_PUBLIC', {
    value: { SUPABASE_URL:'https://stub.test', SUPABASE_ANON_KEY:'stub' },
    writable:false, configurable:false });
})();
"""

PEOPLE = ["Groom", "Bride", "Wali", "W1", "W2"]
GOOD = {"Name": "Test Person", "Age": "30", "Addr": "1 Test Street",
        "Town": "Bolton", "Post": "BL1 8HD"}


def open_page(b):
    pg = b.new_page(viewport={"width": 1360, "height": 1000})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:300]))
    pg.add_init_script(STUB)
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(900)
    pg.evaluate("""() => { const g = document.querySelector('[data-nav="svc-marriage"]');
                           if (g) g.click(); }""")
    pg.wait_for_timeout(600)
    return pg, errs


def pick_date(pg):
    days = pg.query_selector_all('[data-page="svc-marriage"] .hh-day:not([disabled])')
    assert days, "no selectable day this month"
    days[min(6, len(days) - 1)].click()
    pg.wait_for_timeout(350)


def pick_time(pg, hhmm="14:30"):
    """Set the time field the way a person would, and let the page react.

    fill() alone does not fire `change` on every browser, and the page
    listens for `change` rather than `input` so the summary does not
    flicker through half-typed hours — so the event is dispatched here
    explicitly. Without it this helper would silently set a value the page
    never hears about, and every assertion after it would be testing a form
    that had not been told anything.
    """
    sel = '[data-page="svc-marriage"] #nkTime'
    el = pg.query_selector(sel)
    assert el is not None, "there is no time field to set"
    pg.fill(sel, hhmm)
    pg.dispatch_event(sel, "change")
    pg.wait_for_timeout(450)


def fill_everything(pg, ages=None):
    """A complete, valid request. `ages` overrides one or more ages."""
    ages = ages or {}
    pg.fill("#nkName", "Test Contact")
    pg.select_option("#nkRole", "family")
    pg.fill("#nkPhone", "07700900000")
    pg.fill("#nkEmail", "harness@example.test")
    for who in PEOPLE:
        for suffix, val in GOOD.items():
            if suffix == "Age":
                val = str(ages.get(who, GOOD["Age"]))
            pg.fill("#nk%s%s" % (who, suffix), val)
    pg.check("#nkPriv")


def problems(pg):
    node = pg.query_selector("#nkProblems")
    return re.sub(r"\s+", " ", node.text_content()) if node else ""


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    pg, errs = open_page(b)

    # =====================================================================
    #  1. ONE DATE, NOT TWO
    # =====================================================================
    check(pg.query_selector('[data-page="svc-marriage"] .nk-mode') is None,
          "the 1st/2nd choice buttons are still on the page")
    check(pg.query_selector('[data-page="svc-marriage"] #nkV2') is None,
          "the 2nd choice row is still on the page")
    keys = pg.eval_on_selector_all('[data-page="svc-marriage"] .nk-pick .k',
                                   "els => els.map(e => e.innerText.toLowerCase())")
    check(not any("2nd" in k for k in keys),
          "something still labels a second choice: %r" % keys)

    # =====================================================================
    #  2. NO FAJR
    #
    #  Asserted on what is RENDERED, not on the source: the control is built
    #  from a string and redrawn, and every prayer name appears all over this
    #  page for the timetable, so the source would match on the wrong thing.
    # =====================================================================
    pick_date(pg)
    slots = pg.text_content('[data-page="svc-marriage"] #nkSlots')
    for prayer in ["Fajr", "Zuhr", "Asr", "Maghrib", "Isha"]:
        check(prayer not in slots,
              "%s is still offered as a nikāḥ time: %r" % (prayer, slots))
    check("flexible" in slots.lower(),
          "the time control did not render at all: %r" % slots)

    field = pg.query_selector('[data-page="svc-marriage"] #nkTime')
    check(field is not None, "there is no time field on the form")
    if field:
        check(field.get_attribute("type") == "time",
              "the time control is not a real <input type=time>, so phones "
              "will not give their own wheel: %r" % field.get_attribute("type"))
        #  The window has to match db/161 and native/src/nikah-time.js. Three
        #  places enforce it, so a change to one that misses the others shows
        #  up here rather than as a form that passes and then throws.
        check(field.get_attribute("min") == "08:00",
              "the earliest time is not 08:00: %r" % field.get_attribute("min"))
        check(field.get_attribute("max") == "22:00",
              "the latest time is not 22:00: %r" % field.get_attribute("max"))
        check(field.get_attribute("step") == "900",
              "the step is not a quarter hour: %r" % field.get_attribute("step"))

    # =====================================================================
    #  3. THE FORM WAITS FOR A DATE AND A TIME
    # =====================================================================
    check(pg.query_selector("#nkForm") is None,
          "the whole form appeared before a time was chosen — that is thirty "
          "fields dropped on somebody who has not picked a day yet")
    pick_time(pg, "14:30")
    check(pg.query_selector("#nkForm") is not None,
          "the form never appeared after a date and a time were chosen")

    # =====================================================================
    #  4. FIVE PEOPLE, NUMBERED, WITH THE SIX FIELDS
    # =====================================================================
    nums = pg.eval_on_selector_all(".nk-person .num", "els => els.map(e => e.innerText)")
    check(nums == ["01", "02", "03", "04", "05", "06"],
          "the sections are not numbered 01-06: %r" % nums)
    titles = " ".join(pg.eval_on_selector_all(".nk-person h5", "els => els.map(e => e.innerText)"))
    for want in ["Bridegroom", "Bride", "Representative of the bride",
                 "Witness 1", "Witness 2"]:
        check(want in titles, "%r is not a section on the form: %r" % (want, titles))
    for who in PEOPLE:
        for suffix in GOOD:
            check(pg.query_selector("#nk%s%s" % (who, suffix)) is not None,
                  "#nk%s%s is missing from the form" % (who, suffix))
    #  Documents for the couple only. A witness is not asked for their passport.
    for who in ["Groom", "Bride"]:
        check(pg.query_selector("#nk%sPoA" % who) is not None,
              "%s is not asked which proof of address they can bring" % who)
    for who in ["Wali", "W1", "W2"]:
        check(pg.query_selector("#nk%sPoA" % who) is None,
              "%s is being asked for documents, which the masjid does not need"
              % who)
    #  Nothing anywhere on this form uploads a document.
    files = pg.eval_on_selector_all("#nkForm input", "els => els.map(e => e.type)")
    check("file" not in files,
          "there is a file input on this form. No document should ever be "
          "uploaded to this website: %r" % files)

    # =====================================================================
    #  7. THE DECLARATION NAMES THE OTHER PEOPLE
    # =====================================================================
    dec = re.sub(r"\s+", " ", pg.text_content("#nkW_priv"))
    check("told the other people" in dec.lower(),
          "the declaration does not say the other four people were told their "
          "details are being handed over: %r" % dec)

    # =====================================================================
    #  5. AN UNDER-18 GROOM, THEN AN UNDER-18 BRIDE
    # =====================================================================
    fill_everything(pg, ages={"Groom": 17})
    pg.click("#nkSubmit")
    pg.wait_for_timeout(400)
    msg = problems(pg)
    check("18 or over" in msg,
          "a 17-year-old bridegroom was not refused: %r" % msg)
    check("criminal offence" in msg.lower(),
          "the refusal does not say WHY, so it reads as the masjid being "
          "awkward rather than the law: %r" % msg)
    check(pg.evaluate("window.__POSTED.length") == 0,
          "AN UNDER-18 REQUEST WAS SENT TO THE DATABASE")

    #  If the refusal is gone the form SUBMITS and hides itself, and every
    #  fill() below then waits thirty seconds on an invisible field. Fail
    #  loudly here instead: a suite that hangs is a suite people stop running.
    if not pg.is_visible("#nkForm"):
        fails.append("the form was SENT with a 17-year-old bridegroom — "
                     "everything below this point was skipped")
    else:
        pg.fill("#nkGroomAge", "30")
        pg.fill("#nkBrideAge", "16")
        pg.click("#nkSubmit")
        pg.wait_for_timeout(400)
        check("18 or over" in problems(pg),
              "a 16-year-old bride was not refused: %r" % problems(pg))
        check(pg.evaluate("window.__POSTED.length") == 0,
              "AN UNDER-18 REQUEST WAS SENT TO THE DATABASE")

        # =====================================================================
        #  6. A 17-YEAR-OLD WITNESS IS FINE
        #
        #  Without this, every assertion above would also pass on a form that
        #  refused every age it was given.
        # =====================================================================
        pg.fill("#nkBrideAge", "26")
        pg.fill("#nkW1Age", "17")
        pg.click("#nkSubmit")
        pg.wait_for_timeout(600)
        check(pg.evaluate("window.__POSTED.length") == 1,
              "a 17-year-old WITNESS was refused. The age rule is about the couple: "
              "%r" % problems(pg))

    # =====================================================================
    #  8. WHAT WAS ACTUALLY SENT
    # =====================================================================
    posted = pg.evaluate("window.__POSTED")
    check(bool(posted), "nothing was ever sent, so section 8 could not run")
    sent = posted[0]["payload"] if posted else None
    if sent:
        check("alternative_date" not in sent or not sent.get("alternative_date"),
              "a second date is still being sent: %r" % sent.get("alternative_date"))
        roles = [x["role"] for x in sent["people"]]
        check(sorted(roles) == sorted(["groom", "bride", "wali", "witness_1", "witness_2"]),
              "the wrong people were sent: %r" % roles)
        groom = [x for x in sent["people"] if x["role"] == "groom"][0]
        check(groom["postcode"] == "BL1 8HD",
              "the postcode was not normalised to upper case: %r" % groom["postcode"])
        check(isinstance(groom["age"], int),
              "the age was sent as text, so the database would have to guess: %r"
              % groom["age"])
        #  The one thing that must NOT travel.
        check("privacy_accepted" in sent and sent["privacy_accepted"] is True,
              "the declaration was not recorded with the request")
        #  THE TIME, AS THE DATABASE WILL RECEIVE IT. db/161 accepts
        #  slot='specific' only with an HH:MM preferred_time, so a page that
        #  sent the old shape would be refused on arrival with the family
        #  watching.
        check(sent.get("slot") == "specific",
              "the slot sent was %r, not 'specific'" % sent.get("slot"))
        check(sent.get("preferred_time") == "14:30",
              "the chosen time did not reach the payload: %r"
              % sent.get("preferred_time"))
        check(sent.get("time_flexible") is False,
              "a chosen time was sent as flexible: %r" % sent.get("time_flexible"))

    # =====================================================================
    #  9. A BAD POSTCODE IS CAUGHT HERE, NOT ONLY IN POSTGRES
    # =====================================================================
    pg2, errs2 = open_page(b)
    pick_date(pg2); pick_time(pg2)
    fill_everything(pg2)
    pg2.fill("#nkW2Post", "07700900123")
    pg2.click("#nkSubmit")
    pg2.wait_for_timeout(400)
    check("postcode" in problems(pg2).lower(),
          "a phone number in the postcode box was accepted: %r" % problems(pg2))
    check(pg2.evaluate("window.__POSTED.length") == 0,
          "a request with a nonsense postcode was sent")
    check(errs2 == [], "uncaught exceptions on the marriage page: %s" % errs2)
    pg2.close()

    check(errs == [], "uncaught exceptions on the marriage page: %s" % errs)
    pg.close()
    b.close()

httpd.shutdown()
if fails:
    print("\nFAILURES (%d):" % len(fails))
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("\nALL PASS")
