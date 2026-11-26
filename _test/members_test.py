"""/members/ — the membership register, and the receipt it can now print.

Written when a member missing from the old Excel sheet needed three years of
arrears added and the office needed something to hand him for it. The portal
could already add a member and record a payment; it could not print a
receipt, so this adds that and tests the two things most likely to go wrong:

  A. THE RECEIPT READS THE REAL PAYMENTS BACK. Today's payment is ticked for
     the office automatically; an older one is there to tick by hand. The
     figure on the printed sheet must be the sum of what was actually ticked,
     not a guess.

  B. THE PRINTED SHEET MUST NOT TAKE THE WHOLE SCREEN WITH IT. CLAUDE.md
     names this exact bug: admin/shell.css's `body.has-ashell .shell {
     display:block !important }` beats a plain rule on anything still inside
     `.shell`, and families.css hit it first — the whole screen printed
     alongside the one thing that should have, with no error anywhere. This
     checks the computed style under print media, not just that the code
     ran, because a check that only asserts a function was called is not a
     check that it did the right thing.

Run:  python3 _test/members_test.py
"""
import functools
import http.server
import json
import os
import socketserver
import sys
import threading
from datetime import date, timedelta

from playwright.sync_api import sync_playwright

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % httpd.server_address[1]

fails = []


def check(name, cond, got=None):
    if not cond:
        fails.append("%s%s" % (name, ("   [%s]" % got) if got else ""))


TODAY = date.today().isoformat()
OLD_DATE = "2024-06-01"

OVERVIEW = {"year": 2026, "register": 5, "paid": 3, "owing": 2,
            "owing_p": 10000, "arrears_p": 15000, "unraised": 0}

OWING_LIST = {"year": 2026, "shown": 1, "total": 1, "rows": [
    {"id": "m1", "name": "Test Member", "reference": "TM-2026-0001",
     "arrears_p": 15000, "years_owing": 1, "outstanding_p": 10000,
     "settled": False, "waived": False, "paid_p": 0, "net_p": 10000,
     "method": None, "last_paid_on": None}
]}

MEMBER_ONE = {
    "id": "m1", "name": "Test Member", "reference": "TM-2026-0001", "ref_no": 1,
    "house_no": "14", "address_line": "14 Example Street", "postcode": "BL1 1AA",
    "telephone": None, "email": None, "member_since": "2023-01-01",
    "left_on": None, "note": None, "current_year": 2026,
    "years": [
        {"year": 2026, "fee_p": 10000, "waived_p": 0, "net_p": 10000,
         "paid_p": 15000, "outstanding_p": 0, "settled": True, "waived": False,
         "last_paid_on": TODAY, "method": "cash"}
    ],
    "outstanding_p": 0, "years_owing": 0, "last_paid_on": TODAY,
    "payments": [
        {"year": 2026, "amount_p": 10000, "method": "cash",
         "received_on": TODAY, "reference": None, "note": None, "by_a_person": True},
        {"year": 2026, "amount_p": 5000, "method": "bank",
         "received_on": OLD_DATE, "reference": "REF-OLD", "note": None, "by_a_person": True}
    ]
}


def stub(roles, standalone=False, print_throws=False, raise_made=1):
    return """
(function(){
  var ROLES = %s, OVERVIEW = %s, OWING_LIST = %s, MEMBER_ONE = %s;
  var PRINT_THROWS = %s;
  var RAISE_MADE = %s;
  if (%s) {
    Object.defineProperty(window.navigator, 'standalone', {value: true, configurable: true});
  }
  window.__printCalls = [];
  window.__rpcCalls = [];
  window.print = function(){
    var host = document.getElementById('mb-receipt-print');
    window.__printCalls.push({
      bodyClass: document.body.className,
      hostIsBodyChild: host.parentNode === document.body,
      hostHtml: host.innerHTML,
      shellDisplay: getComputedStyle(document.querySelector('.shell')).display,
      hostDisplay: getComputedStyle(host).display
    });
    if (PRINT_THROWS) throw new Error('printing is not available here');
  };
  var client = {
    auth: {
      getSession: function(){ return Promise.resolve({data:{session:{access_token:'t',
        user:{id:'u1', email:'a@b.test'}}}}); },
      getUser: function(){ return Promise.resolve({data:{user:{id:'u1',
        email:'a@b.test'}}}); },
      signOut: function(){ return Promise.resolve({}); },
      mfa: {
        getAuthenticatorAssuranceLevel: function(){
          return Promise.resolve({data:{currentLevel:'aal2', nextLevel:'aal2'}}); },
        listFactors: function(){ return Promise.resolve({data:{totp:[{id:'f1'}]}}); }
      }
    },
    from: function(t){
      var rows = t === 'profiles'
        ? {full_name:'A Person', email:'a@b.test'}
        : ROLES.map(function(r){ return {role:r}; });
      var q = { select:function(){return q;}, eq:function(){return q;},
                maybeSingle:function(){return Promise.resolve({data:rows,error:null});},
                then:function(f){return Promise.resolve({data:rows,error:null}).then(f);} };
      return q;
    },
    rpc: function(name, args){
      window.__rpcCalls.push({name: name, args: args});
      var D = {
        membership_overview:    OVERVIEW,
        membership_owing_list:  OWING_LIST,
        membership_one:         MEMBER_ONE,
        membership_legacy:      {rows: []},
        membership_set_rate:    {ok: true, year: args && args.p_year, fee_p: args && args.p_fee_p},
        membership_raise_year:  {ok: true, year: args && args.p_year, made: RAISE_MADE}
      };
      if (name in D) return Promise.resolve({data: D[name], error: null});
      return Promise.resolve({data: [], error: null});
    }
  };
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}},
     writable:false, configurable:false});
})();
""" % (json.dumps(list(roles)), json.dumps(OVERVIEW), json.dumps(OWING_LIST), json.dumps(MEMBER_ONE),
       json.dumps(bool(print_throws)), json.dumps(raise_made), json.dumps(bool(standalone)))


def open_page(browser, roles=("admin",), width=1400, height=1100,
              standalone=False, print_throws=False, raise_made=1):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.set_default_timeout(7000)
    pg.add_init_script(stub(roles, standalone=standalone, print_throws=print_throws,
                             raise_made=raise_made))
    pg.goto(BASE + "/members/", wait_until="load")
    pg.wait_for_timeout(900)
    return pg


def run():
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

        # ----------------------------------------------- an administrator ----
        pg = open_page(b)
        check("the register panel loads", pg.is_visible("#fx-panel"))
        check("no unexpected error on load", not pg.is_visible("#fx-error"),
              pg.inner_text("#fx-error") if pg.is_visible("#fx-error") else None)

        rail = pg.inner_text(".ashell")
        check("the SITE rail is drawn, not the madrasah one",
              "Donations" in rail and "Hall Hire" in rail)
        check("Membership itself is on the rail", "Membership" in rail)

        # ---------------------------------------------- open the member ----
        pg.click(".mb-open")
        pg.wait_for_timeout(300)
        check("the member's record opens", pg.is_visible("#mb-one"))
        check("the receipt table is shown for a member with payments",
              pg.is_visible("#mb-receipt-table"))
        check("the 'no payments' note is hidden", pg.is_hidden("#mb-receipt-none"))

        boxes = pg.locator("#mb-receipt-rows input[type=checkbox]")
        check("both payments are listed", boxes.count() == 2, boxes.count())
        check("today's payment is ticked for you",
              boxes.nth(0).is_checked())
        check("the older payment is left for the office to tick",
              not boxes.nth(1).is_checked())

        total = pg.inner_text("#mb-receipt-total")
        check("the total reflects only the ticked payment", "£100.00" in total, total)
        check("the untouched total does not already include the old payment",
              "£150.00" not in total, total)
        check("printing is disabled with nothing — no, one — ticked is fine",
              not pg.is_disabled("#mb-receipt-go"))

        # tick the older payment too
        boxes.nth(1).check()
        pg.wait_for_timeout(150)
        total2 = pg.inner_text("#mb-receipt-total")
        check("ticking the second payment updates the total live",
              "£150.00" in total2, total2)
        check("the total says two payments", "2 payments" in total2, total2)

        # ------------------------------------------------- print it ----
        pg.emulate_media(media="print")
        pg.click("#mb-receipt-go")
        pg.wait_for_timeout(200)

        calls = pg.evaluate("window.__printCalls")
        check("window.print was called exactly once", len(calls) == 1, len(calls))
        if calls:
            c = calls[0]
            check("the receipt sheet was moved to document.body at print time",
                  c["hostIsBodyChild"], c)
            check("the printing-receipt class was on body at print time",
                  "printing-receipt" in c["bodyClass"], c["bodyClass"])
            #  THE ACTUAL CLAUDE.md BUG. Not whether the code ran, but whether
            #  the stylesheet it depends on actually hides the rail and shows
            #  the receipt, under real print-media computed styles.
            check("the sign-in shell computes to display:none under print",
                  c["shellDisplay"] == "none", c["shellDisplay"])
            check("the receipt sheet computes to display:block under print",
                  c["hostDisplay"] == "block", c["hostDisplay"])

            html = c["hostHtml"]
            for needle in ["Taiyabah Masjid", "Bolton Central Islamic Society",
                           "1041569", "Test Member", "TM-2026-0001",
                           "£100.00", "£50.00", "£150.00"]:
                check("the receipt mentions %r" % needle, needle in html, html[:200])
            check("the receipt does not claim Gift Aid",
                  "Gift Aid" not in html or "no claim" in html, html)

        # -------------------------------------------- cleans up after ----
        check("the printing-receipt class is removed after printing",
              "printing-receipt" not in pg.evaluate("document.body.className"))
        check("the receipt sheet is moved back off document.body",
              pg.evaluate("document.getElementById('mb-receipt-print').parentNode.id") ==
              "mb-receipt-card")
        check("the receipt sheet is invisible on screen again",
              pg.is_hidden("#mb-receipt-print"))
        pg.close()

        # -------------------------- charging one member, not the register ----
        #  The actual feature: a member who walks in outside Ramadan can be
        #  charged for a year nobody has raised yet, without the office
        #  running "Raise the year's charge" — the whole-register action —
        #  just for them.
        pg5 = open_page(b)
        pg5.click(".mb-open")
        pg5.wait_for_timeout(300)

        check("the charge-year field defaults to the member's current year",
              pg5.input_value("#mb-charge-year") == "2026",
              pg5.input_value("#mb-charge-year"))
        check("the charge-fee field starts empty",
              pg5.input_value("#mb-charge-fee") == "")

        # submitting with no fee must refuse before any RPC runs
        pg5.click("#mb-charge-go")
        pg5.wait_for_timeout(150)
        check("an empty fee is refused with a message", pg5.is_visible("#fx-error"))
        before = pg5.evaluate(
            "window.__rpcCalls.filter(function(c){return c.name==='membership_raise_year';}).length")
        check("no charge RPC ran for an empty fee", before == 0, before)

        pg5.fill("#mb-charge-fee", "25.00")
        pg5.click("#mb-charge-go")
        pg5.wait_for_timeout(300)

        rate_call = pg5.evaluate(
            "window.__rpcCalls.find(function(c){return c.name==='membership_set_rate';})")
        raise_call = pg5.evaluate(
            "window.__rpcCalls.find(function(c){return c.name==='membership_raise_year' "
            "&& c.args && c.args.p_member;})")
        check("the year's fee is set before the charge is raised",
              bool(rate_call) and rate_call["args"]["p_year"] == 2026
              and rate_call["args"]["p_fee_p"] == 2500, rate_call)
        check("the charge is raised for this member only, never the whole register",
              bool(raise_call) and raise_call["args"]["p_year"] == 2026
              and raise_call["args"]["p_member"] == "m1", raise_call)
        check("a success message names the amount and the year",
              pg5.is_visible("#fx-ok") and "£25.00" in pg5.inner_text("#fx-ok")
              and "2026" in pg5.inner_text("#fx-ok"),
              pg5.inner_text("#fx-ok") if pg5.is_visible("#fx-ok") else "hidden")
        pg5.close()

        # -------------------------------------------- already charged ----
        pg6 = open_page(b, raise_made=0)
        pg6.click(".mb-open")
        pg6.wait_for_timeout(300)
        pg6.fill("#mb-charge-fee", "25.00")
        pg6.click("#mb-charge-go")
        pg6.wait_for_timeout(300)
        check("made:0 is reported as already charged, not as a second success",
              pg6.is_visible("#fx-ok") and "already charged" in pg6.inner_text("#fx-ok"),
              pg6.inner_text("#fx-ok") if pg6.is_visible("#fx-ok") else "hidden")
        pg6.close()

        # ------------------------------------------- bulk raise is unaffected ----
        #  membership_raise_year({p_year}) with no p_member — the Ramadan
        #  action — must still be able to run exactly as it always did.
        pg7 = open_page(b)
        pg7.click("#mb-raise-open")
        pg7.wait_for_timeout(200)
        pg7.fill("#mr-year", "2027")
        pg7.fill("#mr-fee", "30.00")
        pg7.once("dialog", lambda d: d.accept())
        pg7.click("#mr-go")
        pg7.wait_for_timeout(300)
        bulk_call = pg7.evaluate(
            "window.__rpcCalls.find(function(c){return c.name==='membership_raise_year' "
            "&& c.args && c.args.p_year===2027;})")
        check("the bulk raise still calls membership_raise_year with no p_member",
              bool(bulk_call) and not bulk_call["args"].get("p_member"), bulk_call)
        pg7.close()

        # -------------------------------- the iOS home-screen limitation ----
        #  Reported from a real phone: "nothing happens when I click it."
        #  iOS Safari refuses window.print() from a page opened through its
        #  home-screen icon — no dialog, no error — because site.webmanifest
        #  sets "display": "standalone" for the whole site. This checks the
        #  warning is shown before anyone presses the button, not found out
        #  the same way the office found it.
        pg3 = open_page(b, standalone=True)
        pg3.click(".mb-open")
        pg3.wait_for_timeout(300)
        check("the standalone warning is shown on an iOS home-screen session",
              pg3.is_visible("#mb-receipt-standalone-note"))
        check("the warning names the actual fix",
              "Safari" in pg3.inner_text("#mb-receipt-standalone-note"))
        pg3.close()

        pg3b = open_page(b)
        pg3b.click(".mb-open")
        pg3b.wait_for_timeout(300)
        check("the standalone warning is hidden in an ordinary browser session",
              pg3b.is_hidden("#mb-receipt-standalone-note"))
        pg3b.close()

        # ----------------------------- a browser that refuses to print ----
        #  Not every failure is the iOS case above. If window.print() itself
        #  throws, that must become a sentence on screen, not a button that
        #  silently does nothing a second way.
        pg4 = open_page(b, print_throws=True)
        pg4.click(".mb-open")
        pg4.wait_for_timeout(300)
        pg4.click("#mb-receipt-go")
        pg4.wait_for_timeout(150)
        check("a thrown print failure is shown, not swallowed",
              pg4.is_visible("#fx-error"))
        check("the message says printing did not start",
              "did not start" in pg4.inner_text("#fx-error"),
              pg4.inner_text("#fx-error"))
        check("the receipt sheet is still cleaned up after a thrown failure",
              "printing-receipt" not in pg4.evaluate("document.body.className")
              and pg4.evaluate(
                "document.getElementById('mb-receipt-print').parentNode.id") ==
                "mb-receipt-card")
        pg4.close()

        # ------------------------------------------- nothing is leaked ----
        pg2 = open_page(b, roles=("madrasah",))
        check("a non-admin account is refused",
              pg2.is_visible("#app-noaccess") and not pg2.is_visible("#fx-panel"))
        body = pg2.inner_text("body")
        for leak in ["Test Member", "TM-2026-0001", "£150.00"]:
            check("a refused account sees no %r" % leak, leak not in body)
        pg2.close()

        b.close()

    httpd.shutdown()
    print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    run()
