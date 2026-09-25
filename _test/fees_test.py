"""The eight Fees screens, driven in a browser against a stubbed database.

WHY THIS SUITE IS LONGER THAN THE OTHERS
----------------------------------------
This is the money section. A wrong figure on the classes screen is a wrong
figure; a wrong figure here is a family told they owe something they do not,
or a child quietly not billed for a year.

`db/_test_fees.sql` proves the arithmetic in Postgres — 41 assertions, all
running. This proves the OTHER half, which SQL cannot see:

  * that a teacher gets the refusal panel and not the fees panel;
  * that nothing is ticked when the reminder screen loads, because a "select
    all" that is on at load is how somebody emails the whole madrasah by
    pressing the wrong thing first;
  * that the send button asks before it sends, since an email cannot be
    unsent;
  * that the landing screen says "—" and not "£0.00 outstanding" when nothing
    has been charged — 066's rule, and the two look identical on a tile while
    meaning opposite things;
  * that changing a sort code makes you type the account number twice;
  * that none of the seven scrolls sideways on a phone.

Every check in here was watched failing before it was kept.

    python3 _test/fees_test.py
"""
import atexit
import functools
import http.server
import json
import os
import socketserver
import sys
import threading

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0),
                               functools.partial(Quiet, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % httpd.server_address[1]

FAILURES = []
CHECKS = [0]


#  PLAYWRIGHT'S inner_text APPLIES text-transform, AND HALF THIS STYLESHEET
#  UPPERCASES THINGS. Three checks in this file failed on their first run for
#  that reason and nothing else — a tile label written "Children with no
#  family" comes back as "CHILDREN WITH NO FAMILY". A test that fails for a
#  reason unrelated to what it is testing gets "fixed" by weakening it, so the
#  comparison is folded here instead.
def says(haystack, needle):
    return needle.lower() in haystack.lower()


def check(name, ok, got=None):
    CHECKS[0] += 1
    if not ok:
        FAILURES.append("%s%s" % (name, ("   [%s]" % got) if got else ""))


#  A CRASH MUST NOT LOOK LIKE A PASS.
#  _test_fees.sql was bitten by exactly this on its first run: two blocks died,
#  four assertions never ran, and the report said 37 of 37. portal_test.py was
#  bitten by it in September. An atexit reporter prints what was collected even
#  when the run dies half way through.
#  AND NOR MUST A RUN THAT STOPPED HALF WAY. The reporter above prints what
#  was collected, which is what makes a crash visible at all — but it printed
#  "ALL PASS" on 124 checks of the 205 this file contains, because a click
#  timed out and everything after it never ran. `db/_test_fees.sql` already
#  refuses to report a pass on a short run; this is the same guard.
#
#  A FLAG, NOT A COUNT. The first version of this guard hard-coded the number
#  of checks and was immediately wrong, because several of them run in loops
#  over the screen list — so "205" was a guess that would have had to be
#  re-guessed every time a screen was added, and a number somebody keeps
#  adjusting to make the suite quiet is not a guard.
#
#  run() sets this on its last line. Anything that stops the run early leaves
#  it false, whatever the count happens to be.
FINISHED = [False]

@atexit.register
def report():
    print("")
    if FAILURES:
        print("%d FAILURE(S) out of %d checks:" % (len(FAILURES), CHECKS[0]))
        for f in FAILURES:
            print("  - " + f)
    elif not FINISHED[0]:
        print("RUN INCOMPLETE — %d checks ran and the suite never reached its "
              "end. Something above stopped it; scroll up for the traceback. "
              "Do not read this as a pass." % CHECKS[0])
    else:
        print("ALL PASS — %d checks across %d screens" % (CHECKS[0], len(SCREENS)))


# ---------------------------------------------------------------------------
#  The stub. One object, shaped like the answers the real functions give.
# ---------------------------------------------------------------------------
FAMILIES = [
    {"id": "h1", "reference": "MF-0001", "name": "Khan — 14 Blackburn Road",
     "pupils": 3, "former": 0, "has_email": True, "has_phone": True, "guardians": 1},
    {"id": "h2", "reference": "MF-0002", "name": "Patel — 3 Deane Road",
     "pupils": 1, "former": 0, "has_email": True, "has_phone": False, "guardians": 1},
    {"id": "h3", "reference": "MF-0003", "name": "Begum — 88 Derby Street",
     "pupils": 1, "former": 0, "has_email": False, "has_phone": True, "guardians": 1},
]

BALANCES = [
    {"id": "h1", "reference": "MF-0001", "name": "Khan — 14 Blackburn Road",
     "charged_p": 22750, "paid_p": 0, "balance_p": 22750, "last_paid_on": None,
     "pupils": 3, "can_email": True, "last_reminded_at": None,
     "last_reminder": None},
    {"id": "h3", "reference": "MF-0003", "name": "Begum — 88 Derby Street",
     "charged_p": 13000, "paid_p": 5000, "balance_p": 8000,
     "last_paid_on": "2026-09-10", "pupils": 1, "can_email": False,
     "last_reminded_at": None, "last_reminder": None},
    {"id": "h2", "reference": "MF-0002", "name": "Patel — 3 Deane Road",
     "charged_p": 13000, "paid_p": 15000, "balance_p": -2000,
     "last_paid_on": "2026-09-14", "pupils": 1, "can_email": True,
     "last_reminded_at": "2026-09-19T09:00:00Z",
     "last_reminder": {"at": "2026-09-19T09:00:00Z", "outcome": "sent",
                       "error": None}},
]

OVERVIEW_LIVE = {
    "as_at": "2026-09-20T10:00:00Z",
    "outstanding_p": 30750, "in_credit_p": 2000, "families_owing": 2,
    "received_30_days_p": 20000, "received_7_days_p": 15000,
    "charged_total_p": 48750, "waived_total_p": 5000,
    "families": 3, "families_no_contact": 1, "pupils_no_family": 2, "pupils": 5,
    "has_default_rate": True, "rates_confirmed": True, "has_bank_details": True,
    "has_card_link": False,
    "open_period": {"id": "p1", "name": "Autumn term 2026", "status": "issued",
                    "weeks": 13},
    "periods": 1,
    "recent": [
        {"id": "y1", "received_on": "2026-09-14", "amount_p": 15000,
         "method": "bank", "kind": "payment", "family": "Patel — 3 Deane Road",
         "reference": "MF-0002"},
        {"id": "y2", "received_on": "2026-09-10", "amount_p": 5000,
         "method": "cash", "kind": "payment", "family": "Begum — 88 Derby Street",
         "reference": "MF-0003"},
    ],
}

#  The day this ships: children, no families, no terms, nothing charged.
OVERVIEW_FRESH = dict(OVERVIEW_LIVE, **{
    "outstanding_p": 0, "in_credit_p": 0, "families_owing": 0,
    "received_30_days_p": 0, "received_7_days_p": 0,
    "charged_total_p": 0, "waived_total_p": 0,
    "families": 0, "families_no_contact": 0, "pupils_no_family": 543,
    "pupils": 543, "has_default_rate": True, "rates_confirmed": False,
    "has_bank_details": False, "open_period": None, "periods": 0, "recent": [],
})

STRUCTURE = {
    "rates": [
        {"id": "r1", "name": "All classes", "amount_p": 1000, "is_default": True,
         "active": True, "sort": 1, "pupils": 4},
        {"id": "r2", "name": "Hifz", "amount_p": 1400, "is_default": False,
         "active": True, "sort": 2, "pupils": 1},
    ],
    "periods": [
        {"id": "p1", "name": "Autumn term 2026", "starts_on": "2026-09-07",
         "ends_on": "2026-12-18", "weeks": 13, "status": "issued",
         "issued_at": "2026-09-08T09:00:00Z", "charges": 5},
    ],
    "settings": {
        "sibling_rule": [{"from": 2, "kind": "percent", "value": 25},
                         {"from": 3, "kind": "free"}],
        "bank_name": "HSBC", "bank_account_name": "Bolton Central Islamic Society",
        "bank_sort_code": "30-99-50", "bank_account_number": "59286668",
        "card_link": "", "reminder_subject": "", "reminder_body": "",
    },
    "settings_changed": {
        "bank_account_number": {"at": "2026-09-01T10:00:00Z", "by": "A Trustee"},
    },
    "pupils_total": 5, "pupils_no_family": 2,
}

STATEMENT = {
    "household": {"id": "h1", "reference": "MF-0001",
                  "name": "Khan — 14 Blackburn Road", "note": None,
                  "guardians": [], "pupils": []},
    "charges": [
        {"id": "c1", "charged_on": "2026-09-08", "kind": "tuition",
         "description": "Aisha Khan — Autumn term 2026", "weeks": 13,
         "rate_p": 1000, "gross_p": 13000, "discount_p": 0,
         "discount_note": None, "waived_p": 0, "waiver_note": None,
         "net_p": 13000, "period": "Autumn term 2026"},
        {"id": "c2", "charged_on": "2026-09-08", "kind": "tuition",
         "description": "Bilal Khan — Autumn term 2026", "weeks": 13,
         "rate_p": 1000, "gross_p": 13000, "discount_p": 3250,
         "discount_note": "Sibling discount", "waived_p": 0,
         "waiver_note": None, "net_p": 9750, "period": "Autumn term 2026"},
    ],
    "payments": [],
    "charged_p": 22750, "paid_p": 0,
}

REPORT = {
    "from": "2026-09-01", "to": "2026-09-20",
    "generated_at": "2026-09-20T10:00:00Z",
    "gross_p": 52000, "discount_p": 3250, "waived_p": 5000, "charged_p": 43750,
    "received_p": 20000, "refunded_p": 2000,
    "by_method": [{"method": "bank", "amount_p": 15000, "count": 1},
                  {"method": "cash", "amount_p": 5000, "count": 1}],
    "by_period": [{"id": "p1", "name": "Autumn term 2026",
                   "starts_on": "2026-09-07", "status": "issued", "weeks": 13,
                   "pupils": 5, "gross_p": 52000, "discount_p": 3250,
                   "waived_p": 5000, "charged_p": 43750}],
    "outstanding_now_p": 30750,
    "waivers": [{"family": "Begum — 88 Derby Street", "reference": "MF-0003",
                 "waived_p": 5000, "why": "Hardship — agreed by trustees",
                 "charged_on": "2026-09-08"}],
}

RECENT = [
    {"id": "y1", "received_on": "2026-09-14", "kind": "payment", "method": "bank",
     "amount_p": 15000, "bank_reference": "MF-0002 PATEL", "note": None,
     "family": "Patel — 3 Deane Road", "reference": "MF-0002",
     "household_id": "h2"},
    {"id": "y3", "received_on": "2026-09-12", "kind": "refund", "method": "bank",
     "amount_p": -2000, "bank_reference": None, "note": "Left in November",
     "family": "Patel — 3 Deane Road", "reference": "MF-0002",
     "household_id": "h2"},
]

UNHOUSED = [
    {"id": "p9", "name": "Nobody Athome", "joined_on": "2024-09-01",
     "classes": "Year 3 girls", "household_id": None, "household": None,
     "household_ref": None},
    {"id": "p8", "name": "Another Child", "joined_on": "2025-09-01",
     "classes": "Year 1 boys", "household_id": None, "household": None,
     "household_ref": None},
]

WAIVERS = [{"id": "c9", "family": "Begum — 88 Derby Street",
            "reference": "MF-0003", "household_id": "h3",
            "description": "Maryam Begum — Autumn term 2026",
            "why": "Hardship — agreed by trustees", "charged_on": "2026-09-08",
            "gross_p": 13000, "waived_p": 5000, "net_p": 8000}]


def stub(roles, overview, structure=None):
    return """
(function(){
  var ROLES = %s, OVERVIEW = %s, STRUCTURE = %s;
  var FAMILIES = %s, BALANCES = %s, STATEMENT = %s, REPORT = %s;
  var RECENT = %s, WAIVERS = %s, UNHOUSED = %s;
  window.__calls = [];
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
      window.__calls.push({name:name, args:args});
      var D = {
        madrasah_fees_overview:      OVERVIEW,
        madrasah_fee_structure:      STRUCTURE,
        madrasah_household_list:     FAMILIES,
        madrasah_household_statement:STATEMENT,
        madrasah_fee_balances:       (args && args.p_only_owing)
                                       ? BALANCES.filter(function(r){
                                           return r.balance_p > 0; })
                                       : BALANCES,
        madrasah_fee_annual_report:  REPORT,
        madrasah_recent_payments:    RECENT,
        madrasah_waivers:            WAIVERS,
        madrasah_pupils_for_family:  UNHOUSED,
        madrasah_household_one:      {id:'h1', reference:'MF-0001',
          name:'Khan — 14 Blackburn Road', note:null,
          guardians:[{id:'g1', full_name:'Imran Khan',
                      email:'khan@example.test', phone:null, is_primary:true}],
          pupils:[{id:'p1', name:'Aisha Khan', left_on:null},
                  {id:'p2', name:'Bilal Khan', left_on:null}]},
        set_pupil_household:         {ok:true},
        save_madrasah_household:     {id:'h1', reference:'MF-0001'},
        reconcile_madrasah_fee_reminders: {sent:1, failed:0, unanswered:0},
        delete_madrasah_household:   {ok:true},
        send_madrasah_fee_reminders: {sent:1, no_contact:1, too_soon:0,
          nothing_owed:0, results:[
            {id:'h1', name:'Khan — 14 Blackburn Road', outcome:'queued'},
            {id:'h3', name:'Begum — 88 Derby Street', outcome:'no_contact'}]},
        raise_madrasah_charges:      {raised:5, skipped_no_family:2,
                                      already_there:0, total_p:48750,
                                      period:'Autumn term 2026'},
        record_madrasah_payment:     {id:'new', reference:'MF-0001'},
        save_madrasah_fee_setting:   {ok:true},
        save_madrasah_fee_rate:      {id:'r1'},
        save_madrasah_fee_period:    {id:'p1', status:'issued'},
        adjust_madrasah_charge:      {ok:true, net_p:8000},
        delete_madrasah_payment:     {ok:true}
      };
      if (name in D) return Promise.resolve({data: D[name], error: null});
      return Promise.resolve({data: [], error: null});
    }
  };
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}},
     writable:false, configurable:false});
})();
""" % (json.dumps(roles), json.dumps(overview),
       json.dumps(structure or STRUCTURE), json.dumps(FAMILIES),
       json.dumps(BALANCES), json.dumps(STATEMENT), json.dumps(REPORT),
       json.dumps(RECENT), json.dumps(WAIVERS), json.dumps(UNHOUSED))


SCREENS = [
    ("/portal/fees/",            "Fees"),
    ("/portal/fees/families/",   "Families"),
    ("/portal/fees/transfers/",  "Bank transfers"),
    ("/portal/fees/owing/",      "Outstanding"),
    ("/portal/fees/discounts/",  "Discounts"),
    ("/portal/fees/refunds/",    "Refunds"),
    ("/portal/fees/structure/",  "What things cost"),
    ("/portal/fees/annual/",     "Annual report"),
]


def open_page(browser, path, roles=("admin",), overview=None, structure=None,
              width=1600, height=1100):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.set_default_timeout(7000)
    pg.add_init_script(stub(list(roles), overview or OVERVIEW_LIVE, structure))
    pg.goto(BASE + path, wait_until="load")
    pg.wait_for_timeout(900)
    return pg


def run():
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

        # ------------------------------------------------ every screen ----
        for path, word in SCREENS:
            pg = open_page(b, path)

            check("%s loads its panel" % path,
                  pg.is_visible("#fx-panel"))
            check("%s has no unexpected error on load" % path,
                  not pg.is_visible("#fx-error"),
                  pg.inner_text("#fx-error") if pg.is_visible("#fx-error") else None)
            check("%s draws the madrasah rail" % path,
                  pg.is_visible(".ashell"))
            #  The rail must be the MADRASAH one. Falling back to the site list
            #  would put Gift Aid and Hall Hire in a madrasah screen with no
            #  error anywhere — classes/app.js warns about exactly this.
            rail = pg.inner_text(".ashell")
            check("%s shows the madrasah rail, not the site one" % path,
                  "Fees" in rail and "Hall Hire" not in rail)
            check("%s highlights its own row" % path,
                  pg.locator('.ashell .area[aria-current="page"]').count() == 1,
                  pg.locator('.ashell .area[aria-current="page"]').count())
            pg.close()

        # --------------------------------------- a teacher gets nothing ----
        #  The rail is cosmetic and the database is the real lock, but a
        #  teacher landing on a fees screen should see a sentence, not a panel
        #  of errors. nav.js marks all seven ADMIN; this is the other half.
        for path, _ in SCREENS:
            pg = open_page(b, path, roles=("madrasah",))
            check("%s refuses a teacher" % path,
                  pg.is_visible("#app-noaccess") and not pg.is_visible("#fx-panel"))
            body = pg.inner_text("body")
            for leak in ["22750", "£227.50", "Khan", "Blackburn"]:
                check("%s shows a teacher no family or figure (%s)" % (path, leak),
                      leak not in body)
            pg.close()

        # ------------------------------------- landing: nothing charged ----
        pg = open_page(b, "/portal/fees/", overview=OVERVIEW_FRESH)
        figs = pg.inner_text("#fx-figs")
        #  066's rule. "£0.00 outstanding" and "nothing has been charged" look
        #  identical on a tile and mean opposite things.
        check("a fresh madrasah does not claim £0.00 is outstanding",
              "£0.00" not in figs, figs.replace("\n", " ")[:90])
        check("a fresh madrasah says nothing has been charged",
              "Nothing has been charged" in figs)
        check("the set-up list appears when fees cannot yet be collected",
              pg.is_visible("#fx-setup"))
        setup = pg.inner_text("#fx-setup")
        check("the set-up list names the unconfirmed rates",
              "Confirm the figures" in setup)
        check("the set-up list says how many children have no family",
              "543" in setup, setup.replace("\n", " ")[:120])
        pg.close()

        # ------------------------------------------ landing: with money ----
        pg = open_page(b, "/portal/fees/")
        check("the set-up list is gone once everything is set up",
              not pg.is_visible("#fx-setup"))
        figs = pg.inner_text("#fx-figs")
        check("outstanding is shown in pounds, not pence",
              "£307.50" in figs, figs.replace("\n", " ")[:120])
        att = pg.inner_text("#fx-attention")
        check("the landing screen flags children who are in no family",
              "not in a family" in att)
        check("money arriving is listed",
              "£150.00" in pg.inner_text("#fx-recent"))
        pg.close()

        # ------------------------------------------- owing: the big one ----
        pg = open_page(b, "/portal/fees/owing/")

        check("the outstanding list shows only families who owe",
              "Patel" not in pg.inner_text("#ow-list"),
              pg.inner_text("#ow-list")[:120])
        check("the biggest debt is first",
              pg.inner_text("#ow-list").index("Khan")
              < pg.inner_text("#ow-list").index("Begum"))

        #  NOTHING IS TICKED AT LOAD. A select-all that is on when the screen
        #  opens is how somebody emails the whole madrasah by pressing the
        #  wrong thing first.
        check("nothing is ticked when the screen loads",
              pg.locator("#ow-list input[type=checkbox]:checked").count() == 0,
              pg.locator("#ow-list input[type=checkbox]:checked").count())
        check("the send bar is hidden until something is ticked",
              not pg.is_visible("#ow-bar"))

        #  A family with no email address cannot be ticked at all.
        check("a family with no email has no tick box",
              pg.locator('#ow-list input[data-tick="h3"]').count() == 0)
        #  .fx-flag is uppercased by the stylesheet, and inner_text applies
        #  text-transform. Comparing case-sensitively here made this check
        #  fail for a reason that had nothing to do with the flag.
        check("that family is flagged rather than silently dropped",
              says(pg.inner_text("#ow-list"), "no email"))

        pg.check('#ow-list input[data-tick="h1"]')
        pg.wait_for_timeout(200)
        check("ticking a family shows the send bar", pg.is_visible("#ow-bar"))
        check("the send bar says how much is between them",
              "£227.50" in pg.inner_text("#ow-picked"),
              pg.inner_text("#ow-picked"))

        #  SENDING ASKS FIRST. An email cannot be unsent.
        before = pg.evaluate("window.__calls.length")
        pg.click("#ow-send")
        pg.wait_for_timeout(300)
        sent = pg.evaluate(
            "window.__calls.filter(c => c.name === 'send_madrasah_fee_reminders').length")
        check("pressing send does NOT send — it asks", sent == 0, sent)
        check("the confirm strip appears", pg.is_visible("#ow-confirm"))
        check("the confirmation says how many and how much",
              "1 famil" in pg.inner_text("#ow-confirm-t")
              and "£227.50" in pg.inner_text("#ow-confirm-t"),
              pg.inner_text("#ow-confirm-t")[:140])
        check("the confirmation promises no child is named",
              "never names a child" in pg.inner_text("#ow-confirm-t"))

        pg.click("#ow-no")
        pg.wait_for_timeout(150)
        sent = pg.evaluate(
            "window.__calls.filter(c => c.name === 'send_madrasah_fee_reminders').length")
        check("saying no sends nothing", sent == 0, sent)

        pg.click("#ow-send")
        pg.wait_for_timeout(200)
        pg.click("#ow-yes")
        pg.wait_for_timeout(500)
        sent = pg.evaluate(
            "window.__calls.filter(c => c.name === 'send_madrasah_fee_reminders').length")
        check("saying yes sends once", sent == 1, sent)
        res = pg.inner_text("#ow-result") if pg.is_visible("#ow-result-bk") else ""
        check("the result reports the ones that were NOT sent",
              says(res, "no email address"), res.replace("\n", " ")[:120])
        pg.close()

        # --------------------------------------------- owing: select all ----
        pg = open_page(b, "/portal/fees/owing/")
        pg.check("#ow-all")
        pg.wait_for_timeout(300)
        #  Only families that can actually be emailed, and only visible ones.
        picked = pg.evaluate(
            "document.querySelectorAll('#ow-list input[data-tick]:checked').length")
        check("select-all only ticks families that can be emailed",
              picked == 1, picked)
        pg.close()

        # -------------------------------------------------- families -------
        #  THE SCREEN THAT WAS NEARLY NOT BUILT. Every other fees screen has a
        #  family picker; for an afternoon nothing could put a row into the
        #  table they all search, and every test still passed because each
        #  screen was correct about its own job. These checks are the ones
        #  that would have caught it.
        pg = open_page(b, "/portal/fees/families/")
        check("a family can be created from this screen",
              pg.locator("#fm-new").count() == 1)
        check("children with no family are listed, not just searchable",
              "Nobody Athome" in pg.inner_text("#fm-unhoused"))
        check("the child's class is shown, because two children share a name",
              "Year 3 girls" in pg.inner_text("#fm-unhoused"))
        check("the backlog is counted where it can be seen",
              says(pg.inner_text("#fm-figs"), "Children with no family"),
              pg.inner_text("#fm-figs").replace("\n", " ")[:120])

        pg.click('#fm-unhoused button[data-place="p9"]')
        pg.wait_for_timeout(300)
        check("placing a child offers an existing family AND a new one",
              pg.is_visible("#pl-fam") and pg.is_visible("#pl-new"))
        check("the new-family box suggests the child's surname",
              "Athome" in (pg.get_attribute("#pl-new", "placeholder") or ""),
              pg.get_attribute("#pl-new", "placeholder"))

        pg.click('[data-plsave="p9"]')
        pg.wait_for_timeout(250)
        check("placing a child with no family chosen is refused",
              pg.is_visible("#fx-error"))
        moved = pg.evaluate(
            "window.__calls.filter(c => c.name === 'set_pupil_household').length")
        check("and nothing was moved", moved == 0, moved)

        pg.fill("#pl-new", "Athome — 2 Chorley Old Road")
        pg.click('[data-plsave="p9"]')
        pg.wait_for_timeout(700)
        made = pg.evaluate(
            "window.__calls.filter(c => c.name === 'save_madrasah_household').length")
        moved = pg.evaluate(
            "window.__calls.filter(c => c.name === 'set_pupil_household').length")
        check("a new family is created and the child put in it",
              made == 1 and moved == 1, "created %d, moved %d" % (made, moved))

        pg.click('#fm-list button[data-fam="h1"]')
        pg.wait_for_timeout(500)
        check("opening a family shows its contacts", pg.is_visible("#fm-editor-bk"))
        check("and its children", "Aisha Khan" in pg.inner_text("#fm-editor"))
        check("exactly one contact is marked as the one we write to",
              pg.locator("#fm-gs .g-primary:checked").count() == 1,
              pg.locator("#fm-gs .g-primary:checked").count())
        #  065's rule: the LIST says whether there is an email, never what it is.
        check("the family list does not carry email addresses",
              "@" not in pg.inner_text("#fm-list"),
              pg.inner_text("#fm-list")[:120])
        check("a family with children in it cannot be removed from here",
              pg.locator("#fm-del").count() == 0)
        pg.close()

        # ----------------------- "sent" has to mean sent (migration 072) ----
        #  071 queued a message and wrote 'sent' on the next line, which it
        #  could not have known. The screen repeated the claim. These check
        #  the screen tells the truth now.
        pg = open_page(b, "/portal/fees/owing/")
        calls = pg.evaluate(
            "window.__calls.filter(c => c.name === "
            "'reconcile_madrasah_fee_reminders').length")
        check("the screen reconciles delivery before it draws the list",
              calls == 1, calls)

        pg.check('#ow-list input[data-tick="h1"]')
        pg.wait_for_timeout(150)
        pg.click("#ow-send")
        pg.wait_for_timeout(200)
        pg.click("#ow-yes")
        pg.wait_for_timeout(600)
        res = pg.inner_text("#ow-result")
        #  Not "Sent". Nothing here can promise delivery.
        check("a queued message is not reported as sent",
              not says(res, "accepted") and says(res, "handed to the mail server"),
              res.replace("\n", " ")[:140])
        pg.close()

        #  A family whose last reminder FAILED is the one thing on this screen
        #  somebody should act on, so it has to be visible and actionable.
        broke = json.loads(json.dumps(BALANCES))
        broke[0]["last_reminded_at"] = "2026-09-19T09:00:00Z"
        broke[0]["last_reminder"] = {"at": "2026-09-19T09:00:00Z",
                                     "outcome": "failed",
                                     "error": "The mail server answered 401."}
        pg = b.new_page(viewport={"width": 1600, "height": 1100})
        pg.set_default_timeout(7000)
        pg.add_init_script(stub(["admin"], OVERVIEW_LIVE).replace(
            json.dumps(BALANCES), json.dumps(broke)))
        pg.goto(BASE + "/portal/fees/owing/", wait_until="load")
        pg.wait_for_timeout(900)

        check("a failed reminder is flagged on the family's row",
              says(pg.inner_text("#ow-list"), "last one did not go"),
              pg.inner_text("#ow-list").replace("\n", " ")[:160])
        check("and counted where it can be seen",
              says(pg.inner_text("#ow-figs"), "Last one did not go"),
              pg.inner_text("#ow-figs").replace("\n", " ")[:160])
        check("the reason is on the flag for somebody who wants it",
              "401" in (pg.get_attribute('#ow-list .fx-flag.warn', "title") or ""),
              pg.get_attribute('#ow-list .fx-flag.warn', "title"))

        pg.click("#ow-again")
        pg.wait_for_timeout(300)
        picked = pg.evaluate(
            "document.querySelectorAll('#ow-list input[data-tick]:checked').length")
        check("one press picks up the families whose message did not go",
              picked == 1, picked)
        #  It selects; it does not send. A retry is as unrecallable as a first
        #  attempt and still has to be read.
        sent = pg.evaluate("window.__calls.filter(c => c.name === "
                           "'send_madrasah_fee_reminders').length")
        check("and it does not send them — it selects them", sent == 0, sent)
        pg.close()

        # ------------------------- regressions found by review, 20 Sept ----
        #  Every one of these was a real defect in the first draft.

        #  THE CRITICAL ONE. A "£ off" sibling rule was stored in pence and
        #  re-rendered raw into a pounds box, so each save multiplied it by a
        #  hundred. Two saves and the clamp in Postgres made every sibling
        #  from position 2 onwards free, silently, at the next "Raise
        #  charges". A percentage round-tripped fine, which is why it hid.
        pence_rule = json.loads(json.dumps(STRUCTURE))
        pence_rule["settings"]["sibling_rule"] = [
            {"from": 2, "kind": "pence", "value": 250}]     # 250p = £2.50
        pg = open_page(b, "/portal/fees/discounts/", structure=pence_rule)
        box = pg.input_value('#sd-rules input[data-value="0"]')
        check("a £-off rule comes back into the box in pounds",
              box == "2.50", box)
        ex = pg.inner_text("#sd-example")
        check("and the worked example reads it as £2.50, not £250",
              "£127.50" in ex, ex[:160])

        pg.click("#sd-save")
        pg.wait_for_timeout(500)
        call = pg.evaluate(
            "JSON.stringify((window.__calls.filter(c => c.name === "
            "'save_madrasah_fee_setting' && c.args.p_key === 'sibling_rule')[0] "
            "|| {}).args || {})")
        check("saving it again stores the same 250, not 25000",
              '"value":250' in call, call[:200])

        #  Changing the scale must not carry the number across: 25 means 25%
        #  under one kind and 25p under the other.
        pg.select_option('#sd-rules select[data-kind="0"]', "percent")
        pg.wait_for_timeout(250)
        check("changing % to £ (or back) clears the number",
              pg.input_value('#sd-rules input[data-value="0"]') == "",
              pg.input_value('#sd-rules input[data-value="0"]'))
        pg.close()

        #  THE WRONG-FAMILY REFUND. An open "£130 back to Khan" confirmation
        #  survived a press on the Patel row, and "Yes" posted Khan's amount
        #  against Patel.
        pg = open_page(b, "/portal/fees/refunds/")
        pg.click('#rf-credit button[data-ref="h2"]')
        pg.wait_for_timeout(250)
        pg.fill("#rf-note", "Left in November")
        pg.click("#rf-save")
        pg.wait_for_timeout(250)
        check("the refund confirmation is showing", pg.is_visible("#rf-confirm"))
        pg.click('#rf-credit button[data-ref="h2"]')
        pg.wait_for_timeout(250)
        check("changing family tears the confirmation down",
              not pg.is_visible("#rf-confirm"))
        pg.close()

        #  THE SELECTION THAT ESCAPED THE FILTER. Tick a family, filter it off
        #  the screen, and send — it went anyway.
        pg = open_page(b, "/portal/fees/owing/")
        pg.check('#ow-list input[data-tick="h1"]')
        pg.wait_for_timeout(200)
        pg.fill("#ow-search", "Begum")
        pg.wait_for_timeout(300)
        check("a ticked family filtered off the screen is not counted",
              not pg.is_visible("#ow-bar")
              or "0 famil" in pg.inner_text("#ow-picked")
              or pg.inner_text("#ow-picked") == "",
              pg.inner_text("#ow-picked"))

        pg.fill("#ow-search", "zzzz")
        pg.wait_for_timeout(300)
        check("a filter matching nothing leaves no live send bar",
              not pg.is_visible("#ow-bar"))
        check("and says so", says(pg.inner_text("#ow-list"), "Nothing matches"))
        pg.close()

        #  A BILLED TERM COULD NOT BE SAVED AT ALL, so it could never be
        #  closed — which is exactly when anybody would want to.
        pg = open_page(b, "/portal/fees/structure/")
        pg.click('#st-periods button[data-period="p1"]')
        pg.wait_for_timeout(300)
        check("a billed term's week count is locked",
              pg.is_disabled("#pd-weeks"))
        check("but its name is not", not pg.is_disabled("#pd-name"))
        pg.select_option("#pd-status", "closed")
        pg.click("[data-pdsave]")
        pg.wait_for_timeout(500)
        call = pg.evaluate(
            "JSON.stringify((window.__calls.filter(c => c.name === "
            "'save_madrasah_fee_period')[0] || {}).args || {})")
        check("closing a billed term sends no weeks at all, rather than null",
              '"weeks"' not in call and '"status":"closed"' in call, call[:180])
        check("and the screen reports no error",
              not pg.is_visible("#fx-error"),
              pg.inner_text("#fx-error") if pg.is_visible("#fx-error") else None)

        #  The "over a term" column used to hard-code 13 weeks.
        check("the term column uses the madrasah's own week count",
              says(pg.inner_text("#st-rates"), "13-week"),
              pg.inner_text("#st-rates").replace("\n", " ")[:100])

        #  Bank details are four separate writes; a bad sort code used to
        #  commit the first two and then say "Nothing was saved".
        pg.fill("#st-bank-sort", "309950")
        pg.click("#st-bank-save")
        pg.wait_for_timeout(300)
        saved = pg.evaluate(
            "window.__calls.filter(c => c.name === 'save_madrasah_fee_setting').length")
        check("a badly formed sort code writes nothing at all", saved == 0, saved)
        check("and says nothing was changed",
              says(pg.inner_text("#fx-error"), "Nothing has been changed"),
              pg.inner_text("#fx-error") if pg.is_visible("#fx-error") else "none")
        pg.close()

        #  CSV FORMULA INJECTION. A family name beginning "=" is a formula
        #  to Excel, and these files are full of names by design.
        #
        #  THE FIRST VERSION OF THIS CHECK COULD NOT FAIL: it built an "evil"
        #  balances list, passed it to pg.evaluate instead of to the page, and
        #  then asserted that "=1+1" was absent from a download that had never
        #  contained it. Three conditions OR'd together, one of which was
        #  vacuously true. The stub now serves the name, so the download
        #  really does carry it.
        evil = json.loads(json.dumps(BALANCES))
        evil[0]["name"] = "=1+1"
        pg = b.new_page(viewport={"width": 1600, "height": 1100})
        pg.set_default_timeout(7000)
        pg.add_init_script(
            stub(["admin"], OVERVIEW_LIVE).replace(
                json.dumps(BALANCES), json.dumps(evil)))
        pg.goto(BASE + "/portal/fees/owing/", wait_until="load")
        pg.wait_for_timeout(900)
        check("the dangerous name really is on the page",
              "=1+1" in pg.inner_text("#ow-list"),
              pg.inner_text("#ow-list")[:100])

        out = pg.evaluate("""() => {
          var got = null;
          var orig = window.Blob;
          window.Blob = function (parts, opts) {
            got = parts.join(''); return new orig(parts, opts);
          };
          window.URL.createObjectURL = function () { return 'blob:x'; };
          window.URL.revokeObjectURL = function () {};
          document.querySelector('#ow-csv').click();
          return got;
        }""")
        check("the download was captured", out is not None)
        check("a family name starting with = is neutralised in the download",
              out is not None and "=1+1" in out and "'=1+1" in out,
              (out or "").replace("\r\n", " | ")[:160])
        pg.close()

        # ------------------------------------------------- transfers -------
        pg = open_page(b, "/portal/fees/transfers/")
        pg.fill("#tr-amount", "40")
        pg.click("#tr-save")
        pg.wait_for_timeout(250)
        check("money with no family attached is refused",
              pg.is_visible("#fx-error")
              and "family" in pg.inner_text("#fx-error").lower(),
              pg.inner_text("#fx-error") if pg.is_visible("#fx-error") else "no error")
        recorded = pg.evaluate(
            "window.__calls.filter(c => c.name === 'record_madrasah_payment').length")
        check("and nothing was recorded", recorded == 0, recorded)

        pg.fill("#tr-family", "Khan")
        pg.wait_for_timeout(500)
        check("the family picker offers matches", pg.is_visible("#tr-results"))
        check("the picker shows the reference beside the name",
              "MF-0001" in pg.inner_text("#tr-results"))
        pg.click('#tr-results .fx-pick[data-id="h1"]')
        pg.wait_for_timeout(500)
        check("choosing a family shows what they owe before the amount is typed",
              "£227.50" in pg.inner_text("#tr-balance"),
              pg.inner_text("#tr-balance"))
        check("the family's own reference is offered",
              pg.input_value("#tr-ref") == "MF-0001", pg.input_value("#tr-ref"))

        pg.fill("#tr-amount", "0")
        pg.click("#tr-save")
        pg.wait_for_timeout(200)
        recorded = pg.evaluate(
            "window.__calls.filter(c => c.name === 'record_madrasah_payment').length")
        check("a payment of nothing is refused", recorded == 0, recorded)

        pg.fill("#tr-amount", "£40.00")
        pg.click("#tr-save")
        pg.wait_for_timeout(500)
        call = pg.evaluate(
            "JSON.stringify((window.__calls.filter(c => c.name === "
            "'record_madrasah_payment')[0] || {}).args || {})")
        check("£40.00 is sent as 4000 pence", '"amount_p":4000' in call, call[:160])
        check("a pound sign typed into the box does not break it",
              '"amount_p":4000' in call)
        check("it is recorded as a payment, not a refund",
              '"kind":"payment"' in call)
        pg.close()

        # ------------------------------------------------- structure -------
        pg = open_page(b, "/portal/fees/structure/")
        check("the rate card is shown in pounds a week",
              "£10.00" in pg.inner_text("#st-rates"))
        #  £10 a week does not read as £130 until somebody multiplies it.
        check("and what that is over a term",
              "£130.00" in pg.inner_text("#st-rates"),
              pg.inner_text("#st-rates").replace("\n", " ")[:140])
        check("a billed term says how many bills are against it",
              "5" in pg.inner_text("#st-periods"))
        check("the screen says who last changed the bank details",
              "A Trustee" in pg.inner_text("#st-bank-when"),
              pg.inner_text("#st-bank-when"))

        check("the retype box is hidden until the account number changes",
              not pg.is_visible("#st-bank-again"))
        pg.fill("#st-bank-no", "12345678")
        pg.wait_for_timeout(200)
        check("changing the account number asks for it twice",
              pg.is_visible("#st-bank-again"))
        pg.click("#st-bank-save")
        pg.wait_for_timeout(300)
        saved = pg.evaluate(
            "window.__calls.filter(c => c.name === 'save_madrasah_fee_setting').length")
        check("a mismatched retype saves nothing", saved == 0, saved)
        check("and says why",
              pg.is_visible("#fx-error")
              and "do not match" in pg.inner_text("#fx-error"),
              pg.inner_text("#fx-error") if pg.is_visible("#fx-error") else "none")

        pg.fill("#st-bank-again", "12345678")
        pg.click("#st-bank-save")
        pg.wait_for_timeout(600)
        saved = pg.evaluate(
            "window.__calls.filter(c => c.name === 'save_madrasah_fee_setting').length")
        check("a matching retype does save", saved >= 4, saved)
        pg.close()

        # ------------------------------ structure: unconfirmed rate card ----
        fresh = json.loads(json.dumps(STRUCTURE))
        fresh["settings"].pop("rates_confirmed_on", None)
        pg = open_page(b, "/portal/fees/structure/", structure=fresh)
        check("an unconfirmed rate card says so on the screen",
              pg.is_visible("#st-unconfirmed"))
        confirmed = json.loads(json.dumps(STRUCTURE))
        confirmed["settings"]["rates_confirmed_on"] = "2026-09-20"
        pg.close()
        pg = open_page(b, "/portal/fees/structure/", structure=confirmed)
        check("a confirmed rate card does not",
              not pg.is_visible("#st-unconfirmed"))
        pg.close()

        # ------------------------------------------------- discounts -------
        pg = open_page(b, "/portal/fees/discounts/")
        ex = pg.inner_text("#sd-example")
        #  25% off the second child, third free: £130 + £97.50 + 0 + 0.
        check("the sibling rule is worked through in pounds",
              "£97.50" in ex and "£227.50" in ex, ex[:180])
        check("the worked example says what it would cost without the discount",
              "£520.00" in ex, ex[:180])
        check("fees already written off are listed with the reason",
              "Hardship" in pg.inner_text("#wv-list"))
        pg.close()

        # --------------------------------------------------- refunds -------
        pg = open_page(b, "/portal/fees/refunds/")
        check("families in credit are listed for refunding",
              "Patel" in pg.inner_text("#rf-credit"),
              pg.inner_text("#rf-credit").replace("\n", " ")[:120])
        check("and the credit is shown as a positive amount",
              "£20.00" in pg.inner_text("#rf-credit"))
        check("refunds already made are listed",
              "£20.00" in pg.inner_text("#rf-list"))

        pg.click('#rf-credit button[data-ref="h2"]')
        pg.wait_for_timeout(300)
        check("pressing refund fills the form rather than refunding",
              pg.evaluate("window.__calls.filter(c => c.name === "
                          "'record_madrasah_payment').length") == 0)
        check("the amount is suggested from the credit",
              pg.input_value("#rf-amount") == "20.00", pg.input_value("#rf-amount"))

        pg.click("#rf-save")
        pg.wait_for_timeout(250)
        check("a refund with no reason is refused",
              pg.is_visible("#fx-error") and "why" in pg.inner_text("#fx-error").lower(),
              pg.inner_text("#fx-error") if pg.is_visible("#fx-error") else "none")

        pg.fill("#rf-note", "Left in November having paid the term")
        pg.click("#rf-save")
        pg.wait_for_timeout(250)
        check("money leaving is confirmed before it is recorded",
              pg.is_visible("#rf-confirm"))
        check("the confirmation states the amount in words",
              "£20.00" in pg.inner_text("#rf-confirm-t"))
        check("and says this does not move any money",
              "does not move" in pg.inner_text("#rf-confirm-t"))
        pg.click("#rf-yes")
        pg.wait_for_timeout(600)
        call = pg.evaluate(
            "JSON.stringify((window.__calls.filter(c => c.name === "
            "'record_madrasah_payment')[0] || {}).args || {})")
        check("a refund is sent as kind=refund", '"kind":"refund"' in call, call[:160])
        #  The sign is applied in Postgres, so the screen sends a positive
        #  number and says which it is. A screen that sent -2000 AND kind
        #  refund would be double-negating.
        check("the screen sends a positive amount and lets Postgres sign it",
              '"amount_p":2000' in call, call[:160])
        pg.close()

        # ---------------------------------------------------- annual -------
        pg = open_page(b, "/portal/fees/annual/")
        figs = pg.inner_text("#an-figs")
        check("the annual report shows what was charged", "£437.50" in figs, figs[:120])
        check("and what was received", "£200.00" in figs)
        #  Outstanding is as at TODAY and the report says so, because the data
        #  for a point-in-time balance is not kept.
        check("outstanding is labelled as today, not as at the end date",
              "today" in figs.lower(), figs.replace("\n", " ")[:200])
        check("the terms are broken out", "Autumn term 2026" in pg.inner_text("#an-periods"))
        check("how the money came in is broken out",
              "Bank transfer" in pg.inner_text("#an-methods"))
        check("every write-off is itemised with its reason",
              "Hardship" in pg.inner_text("#an-waivers"))
        pg.close()

        # ------------------------------------------------ the phone --------
        #  An item that may not shrink is a minimum width in disguise, and it
        #  breaks phones. portal_test.py caught this twice in September.
        for path, _ in SCREENS:
            pg = open_page(b, path, width=390, height=850)
            over = pg.evaluate(
                "document.documentElement.scrollWidth - document.documentElement.clientWidth")
            check("%s does not scroll sideways on a phone" % path,
                  over <= 1, "%dpx over" % over)
            pg.close()

        # ------------------------------------------- the whole desk --------
        #  Commit 9a4a21e: nothing stops halfway across a wide screen.
        for path, _ in SCREENS:
            pg = open_page(b, path, width=1920, height=1200)
            worst = pg.evaluate("""() => {
              const panel = document.querySelector('.panel');
              if (!panel) return {pct: 100};
              const avail = panel.clientWidth - 2;
              let worst = {pct: 100, cls: ''};
              for (const bk of document.querySelectorAll('#fx-panel > .fx-bk, '
                   + '#fx-panel > .fx-head, #fx-panel > .fx-figs')) {
                const r = bk.getBoundingClientRect();
                if (r.width < 40 || r.height < 12) continue;
                const pct = Math.round(r.width / avail * 100);
                if (pct < worst.pct) worst = {pct: pct, cls: bk.className};
              }
              return worst;
            }""")
            check("%s uses the whole desk at 1920px" % path,
                  worst["pct"] >= 90,
                  "%s fills %d%%" % (worst.get("cls", "?"), worst["pct"]))
            pg.close()

        b.close()

    FINISHED[0] = True
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(run())
