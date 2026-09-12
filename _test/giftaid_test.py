"""Gift Aid on the New Build donation card.

Asked for by the committee, 12 September 2026, after they saw another Bolton
masjid doing it: a Stripe checkout with a "Gift Aid Eligible" dropdown on it.

THE DONOR ANSWERS ON STRIPE'S PAGE, NOT THIS ONE. A custom field on each
donation Payment Link, with the declaration in the product description beside
it. So most of what this file checks is what the website SAYS, plus the one
thing it does: putting a DN- reference on each donation link so the webhook can
record the payment against a row the masjid owns.

The assertion that matters is 02: the tax-liability sentence, word for word.
The masjid the committee copied this from has the dropdown and not the
sentence, which makes their claim a preference rather than a declaration.

Run:  python3 _test/giftaid_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, re, http.server, socketserver, threading, functools

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/" % httpd.server_address[1]

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


# HMRC's model wording. Not paraphrased here on purpose: if somebody softens it
# in the template, this test is what notices.
TAX_STATEMENT = (
    "I am a UK taxpayer and understand that if I pay less Income Tax "
    "and/or Capital Gains Tax in the current tax year than the amount "
    "of Gift Aid claimed on all my donations it is my responsibility "
    "to pay any difference."
)

src = open("index.html", encoding="utf-8").read()


def variant(path, switch_on):
    """A copy of the built page with the switch forced one way.

    Forced BOTH ways on purpose. An earlier version tested the off-state
    against whatever index.html happened to ship — which passed until the
    switch was turned on for real, and then failed for a reason that had
    nothing to do with the code. A test should not depend on which state the
    site is in this week.
    """
    out = src.replace("var GIFT_AID_OPEN = true;",  "var GIFT_AID_OPEN = false;") \
          if not switch_on else src.replace("var GIFT_AID_OPEN = false;", "var GIFT_AID_OPEN = true;")
    open(path, "w", encoding="utf-8").write(out)
    return path


def open_give(pg, path):
    pg.goto(BASE + path, wait_until="load")
    pg.wait_for_timeout(700)
    pg.evaluate("() => showPage('newbuild')")
    pg.wait_for_timeout(400)


def hrefs(pg):
    return pg.eval_on_selector_all(
        ".nb-give-card .tier, .nb-give-card .donate-cta",
        "els => els.map(e => e.getAttribute('href'))")


made = []
with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    pg = b.new_page(viewport={"width": 1440, "height": 1100})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:160]))

    # =====================================================================
    #  01. SWITCHED OFF
    #
    #  Explaining Gift Aid and then sending somebody to a checkout that does
    #  not offer it is worse than saying nothing, so the switch stays off
    #  until the five Payment Links carry the dropdown.
    # =====================================================================
    made.append(variant("_gaoff.html", False))
    open_give(pg, "_gaoff.html")
    shipped = hrefs(pg)
    check(len(shipped) == 5, "expected five giving buttons, found %d" % len(shipped))
    check(all("stripe.com" in v for v in shipped),
          "a giving button does not point at Stripe: %r" % shipped)
    check(not pg.is_visible("#ga-block"),
          "THE GIFT AID BLOCK IS SHOWING WITH THE SWITCH OFF")
    nb = pg.evaluate("() => document.querySelector('.page.page-active').innerText")
    check("gift aid" not in nb.lower(),
          "the page explains Gift Aid while the offer is switched off")

    # =====================================================================
    #  02. WHAT THE DONOR READS
    #
    #  The part that decides whether the claim survives an audit.
    # =====================================================================
    made.append(variant("_gaopen.html", True))
    open_give(pg, "_gaopen.html")
    check(pg.is_visible("#ga-block"), "the Gift Aid block does not appear when switched on")

    pg.click("#ga-block .ga-more summary")
    pg.wait_for_timeout(200)
    flat = re.sub(r"\s+", " ", pg.inner_text("#ga-block"))

    check(TAX_STATEMENT in flat,
          "THE TAX-LIABILITY STATEMENT IS MISSING OR REWORDED — without it "
          "this is a preference, not a declaration.\nsaw: %r" % flat[:400])
    check("Bolton Central Islamic Society" in flat, "the declaration does not name the charity")
    check("1041569" in flat, "the declaration does not carry the registered charity number")
    check("Zakat" in flat and "not taken through this page" in flat,
          "the page does not say Zakat is outside this route")

    # The donor has to know the payment page asks for an address, or they
    # abandon it thinking something is wrong — and an address is the one thing
    # HMRC will not do without.
    low = flat.lower()
    check("postcode" in low and "payment page" in low,
          "the page does not say the payment screen asks for name and postcode")

    # =====================================================================
    #  03. THE WORDING VERSION MUST MATCH THE DATABASE
    #
    #  The page shows a version; the database stamps one against every
    #  declaration. If they drift, the masjid cannot say what a donor was
    #  shown on a given day — which is the whole reason for versioning it.
    # =====================================================================
    page_ver = re.search(r"version (\d{4}-\d{2}-\d{2})", flat)
    check(page_ver is not None, "the declaration carries no version date")
    sql = open("db/022_donations_and_gift_aid.sql", encoding="utf-8").read()
    db_ver = re.search(r"gift_aid_declaration_version\(\)\s*returns text.*?select '([\d-]+)'",
                       sql, re.S)
    check(db_ver is not None, "022 has no declaration version to compare against")
    if page_ver and db_ver:
        check(page_ver.group(1) == db_ver.group(1),
              "THE PAGE SAYS VERSION %s AND THE DATABASE STAMPS %s"
              % (page_ver.group(1), db_ver.group(1)))

    # =====================================================================
    #  04. THE ONE THING THIS PAGE ACTUALLY DOES
    #
    #  Puts a reference on each donation link. Without it the webhook cannot
    #  tell a donation from a hall deposit, and the payment is audited as
    #  money with no record behind it.
    # =====================================================================
    before = hrefs(pg)
    check(all("client_reference_id" not in h for h in before),
          "references are on the links before anybody has clicked: %r" % before)

    seen = []
    for sel in [".nb-give-card .tier.t-bronze", ".nb-give-card .tier.t-silver",
                ".nb-give-card .tier.t-gold", ".nb-give-card .tier.t-plat",
                ".nb-give-card .donate-cta"]:
        # dispatch rather than click: these links open a new tab, and the test
        # cares about the href the browser would follow, not about following it
        pg.eval_on_selector(sel, "e => e.dispatchEvent(new MouseEvent('click', {bubbles:true}))")
        pg.wait_for_timeout(60)
        h = pg.eval_on_selector(sel, "e => e.getAttribute('href')")
        m = re.search(r"client_reference_id=(DN-[A-Z0-9-]+)", h or "")
        if not m:
            fails.append("no DN- reference on %s after a click: %r" % (sel, h))
            continue
        seen.append(m.group(1))
        base = (h or "").split("?")[0]
        check(base in shipped,
              "clicking changed where %s points: %r" % (sel, base))

    check(len(set(seen)) == len(seen),
          "two donations would share a reference: %r" % seen)
    check(all(r.startswith("DN-") for r in seen),
          "a reference does not carry the DN- prefix the webhook routes on: %r" % seen)

    # Clicking the same button twice is two donations, and the office has to
    # see two. A reference fixed at page load would merge them.
    pg.eval_on_selector(".nb-give-card .tier.t-bronze",
                        "e => e.dispatchEvent(new MouseEvent('click', {bubbles:true}))")
    pg.wait_for_timeout(60)
    again = re.search(r"client_reference_id=(DN-[A-Z0-9-]+)",
                      pg.eval_on_selector(".nb-give-card .tier.t-bronze", "e => e.getAttribute('href')"))
    check(again is not None and again.group(1) != seen[0],
          "donating twice from the same page reuses one reference")

    check(errs == [], "uncaught exceptions: %s" % errs)
    b.close()

for f in made:
    try:
        os.remove(f)
    except OSError:
        pass

print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
