"""/giftaid/ — getting an HMRC claim out of the database.

Built 12 September 2026. Until this page there was exactly one way to extract a
Gift Aid claim: run SQL in the Supabase editor. A masjid treasurer will not do
that, so the claim would not get made and every carefully recorded declaration
would have been for nothing.

THE ASSERTIONS THAT MATTER ARE 03 AND 04.

  03  The clipboard carries HMRC's columns, in HMRC's order, tab separated, in
      DD/MM/YY. Any of those wrong and the paste lands in one column or the
      dates read as the 13th month, and the claim is rejected.

  04  Every row the automatic split is unsure about is listed BEFORE the
      download. Stripe gives one name and one address; HMRC wants a first
      name, a surname and the house number on its own. Splitting is guesswork,
      and guesswork on a tax claim is how a claim gets disallowed — so the
      guessing is done, and then it is confessed.

The stub is frozen with Object.defineProperty before the page's own scripts
run: the vendored Supabase build declares `var supabase` at global scope and
would otherwise overwrite a plain assignment, leaving every assertion running
against a sign-in screen.

Run:  python3 _test/giftaid_portal_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, re, json, http.server, socketserver, threading, functools

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PAGE = "http://127.0.0.1:%d/giftaid/" % httpd.server_address[1]

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


# HMRC's columns, in HMRC's order. From gov.uk, "schedule spreadsheet to claim
# back tax on Gift Aid donations".
COLUMNS = ["Title", "First name", "Last name", "House name or number",
           "Postcode", "Aggregated donations", "Sponsored event",
           "Donation date", "Amount"]

STUB = r"""
(function () {
  var DB = window.__DB = { roles: ["admin"], rpcs: [], copied: null };

  // Deliberately awkward. Every one of these is something Stripe really hands
  // over, and every one of them is a way an HMRC claim goes wrong.
  DB.claim = [
    // ordinary: splits cleanly
    { reference:"DN-0001", donated_on:"2026-09-03", donor_name:"Imran Ali",
      donor_address:"12 Astley Street, Bolton", donor_postcode:"BL1 8HD",
      amount_p:25000, declaration_version:"2026-09-12" },
    // a title in the name field — "Mr" is not a first name
    { reference:"DN-0002", donated_on:"2026-09-11", donor_name:"Mr Yusuf Patel",
      donor_address:"7 Bury Road, Bolton", donor_postcode:"bl1 2aa",
      amount_p:5000, declaration_version:"2026-09-12" },
    // ONE WORD. HMRC need a surname AND a first name.
    { reference:"DN-0003", donated_on:"2026-09-11", donor_name:"Abdullah",
      donor_address:"3 Deane Road, Bolton", donor_postcode:"BL3 1AA",
      amount_p:1000, declaration_version:"2026-09-12" },
    // a house with a name and no number: cannot be taken automatically
    { reference:"DN-0004", donated_on:"2026-09-12", donor_name:"Sara Bi",
      donor_address:"Rose Cottage, Chorley New Road, Bolton", donor_postcode:"BL1 4AA",
      amount_p:100000, declaration_version:"2026-09-12" },
    // NO POSTCODE: cannot be claimed at all
    { reference:"DN-0005", donated_on:"2026-09-12", donor_name:"Bilal Khan",
      donor_address:"9 Mill Street, Bolton", donor_postcode:null,
      amount_p:2000, declaration_version:"2026-09-12" }
  ];

  function copy(v){ return JSON.parse(JSON.stringify(v)); }

  function makeQ(table) {
    var q = {
      select:function(){ return q; }, order:function(){ return q; },
      eq:function(){ return q; },
      maybeSingle:function(){ return run().then(function(r){
        return { data:(r.data && r.data[0]) || null, error:r.error }; }); },
      then:function(a,b){ return run().then(a,b); }
    };
    function run(){
      if (table === "profiles")
        return Promise.resolve({ data:[{ full_name:"A Treasurer", email:"treasurer@example.test" }], error:null });
      if (table === "user_roles")
        return Promise.resolve({ data:DB.roles.map(function(r){ return { role:r }; }), error:null });
      return Promise.resolve({ data:[], error:null });
    }
    return q;
  }

  var client = {
    auth: {
      getSession:function(){ return Promise.resolve({ data:{ session:{ user:{ id:"u1" } } }, error:null }); },
      getUser:function(){ return Promise.resolve({ data:{ user:{ id:"u1", email:"treasurer@example.test" } }, error:null }); },
      signOut:function(){ return Promise.resolve({ error:null }); },
      signInWithPassword:function(){ return Promise.resolve({ error:{ message:"not used" } }); },
      mfa:{
        getAuthenticatorAssuranceLevel:function(){
          return Promise.resolve({ data:{ currentLevel:"aal2", nextLevel:"aal2" }, error:null }); },
        listFactors:function(){ return Promise.resolve({ data:{ totp:[{ id:"f1" }] }, error:null }); }
      }
    },
    from:function(t){ return makeQ(t); },
    rpc:function(name, args){
      DB.rpcs.push({ name:name, args:copy(args || {}) });
      if (name === "gift_aid_to_claim") return Promise.resolve({ data:copy(DB.claim), error:null });
      if (name === "mark_gift_aid_claimed") {
        var refs = (args || {}).p_references || [];
        DB.claim = DB.claim.filter(function (r) { return refs.indexOf(r.reference) === -1; });
        return Promise.resolve({ data:refs.length, error:null });
      }
      return Promise.resolve({ data:null, error:null });
    }
  };

  var stub = { createClient:function(){ return client; } };
  Object.defineProperty(window, "supabase", { value:stub, writable:false, configurable:false });
  window.__STUB = stub;

  // Capture the clipboard rather than touching the real one.
  Object.defineProperty(navigator, "clipboard", {
    value: { writeText: function (t) { DB.copied = t; return Promise.resolve(); } },
    configurable: true
  });
})();
"""

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    pg = b.new_page(viewport={"width": 1400, "height": 1200})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:160]))
    pg.on("dialog", lambda d: d.accept())
    pg.add_init_script(STUB)
    pg.goto(PAGE)
    pg.wait_for_timeout(1200)

    # =====================================================================
    #  00. is this testing anything?
    # =====================================================================
    check(pg.evaluate("window.supabase === window.__STUB"),
          "the page replaced the stub — every assertion below is meaningless")
    check(pg.eval_on_selector("#ga-panel", "e=>!e.hidden"),
          "the Gift Aid panel is hidden from an administrator")
    names = [c["name"] for c in pg.evaluate("window.__DB.rpcs")]
    check("gift_aid_to_claim" in names,
          "the page never asked the database for anything: %r" % names)

    # =====================================================================
    #  01. WHAT IS WAITING, IN MONEY
    #
    #  The number that gets a claim filed is not "5 donations", it is what the
    #  masjid is leaving on the table.
    # =====================================================================
    summ = pg.inner_text("#ga-sum")
    check("5" in summ, "the count of donations is not shown: %r" % summ)
    check("£1,330.00" in summ or "£1330.00" in summ,
          "the total given is wrong or missing: %r" % summ)
    # 25% of £1,330 = £332.50
    check("£332.50" in summ,
          "the Gift Aid the masjid is owed is not shown: %r" % summ)

    # =====================================================================
    #  02. THE TABLE
    # =====================================================================
    heads = pg.eval_on_selector_all(".ga-table th", "els=>els.map(e=>e.textContent.trim())")
    check(heads[1:] == COLUMNS,
          "the table is not in HMRC's column order: %r" % heads)
    check(len(pg.query_selector_all(".ga-table tbody tr")) == 5,
          "not every donation is listed")

    # =====================================================================
    #  03. WHAT GETS PASTED INTO HMRC'S SPREADSHEET
    # =====================================================================
    pg.click("#ga-copy")
    pg.wait_for_timeout(300)
    copied = pg.evaluate("window.__DB.copied")
    check(copied, "nothing reached the clipboard")
    lines = (copied or "").split("\n")
    check(len(lines) == 5, "expected five rows on the clipboard, got %d" % len(lines))

    first = lines[0].split("\t") if lines else []
    check(len(first) == 9,
          "a row has %d columns, HMRC's schedule has 9: %r" % (len(first), first))

    # Pad rather than index blindly. A malformed row would otherwise raise
    # IndexError and abort the file, hiding every assertion after it — the
    # failure this project has now been bitten by six times.
    first = (first + [""] * 9)[:9]
    # TAB separated. A comma-separated paste lands in one column and somebody
    # spends an evening on Text to Columns.
    check("\t" in (lines[0] if lines else ""),
          "the rows are not tab separated, so they will paste into one column")
    check(first[:5] == ["", "Imran", "Ali", "12", "BL1 8HD"],
          "the first row is not split as HMRC need it: %r" % first[:5])
    check(first[7] == "03/09/26",
          "the date is not DD/MM/YY — a US-locale browser would silently "
          "produce MM/DD/YY: %r" % first[7])
    check(first[8] == "250.00",
          "the amount is not plain pounds to two places: %r" % first[8])
    check("£" not in (copied or ""), "a £ sign is in the amounts; HMRC reject those")

    rows = [(l.split("\t") + [""] * 9)[:9] for l in lines]
    # "Mr" belongs in the Title column, not in First name.
    mr = [r for r in rows if r[2] == "Patel"]
    check(mr and mr[0][0] == "Mr" and mr[0][1] == "Yusuf",
          "a title was left in the name: %r" % (mr[0] if mr else None))
    # Postcodes are matched by HMRC, so they are normalised once here.
    check(mr and mr[0][4] == "BL1 2AA",
          "a lower-case postcode was not tidied: %r" % (mr[0][4] if mr else None))

    # =====================================================================
    #  04. THE ROWS A HUMAN HAS TO LOOK AT
    #
    #  Splitting one name and one address into HMRC's fields is guesswork.
    #  The guessing is done — and then confessed, before anything is filed.
    # =====================================================================
    check(not pg.is_hidden("#ga-warn"), "nothing warns about the unsplittable rows")
    warn = pg.inner_text("#ga-warn")
    check("DN-0003" in warn, "a one-word name is not flagged: %r" % warn)
    check("DN-0004" in warn, "a house with no number is not flagged")
    check("DN-0005" in warn, "A DONATION WITH NO POSTCODE IS NOT FLAGGED")
    check("DN-0001" not in warn, "a perfectly good row was flagged: %r" % warn)
    check("postcode" in warn.lower(), "the warning does not say what is wrong")

    bad_ids = pg.eval_on_selector_all(
        ".ga-table tbody tr.bad td:first-child", "els=>els.map(e=>e.textContent.trim())")
    check(sorted(bad_ids) == ["DN-0003", "DN-0004", "DN-0005"],
          "the wrong rows are marked in the table: %r" % bad_ids)

    # =====================================================================
    #  05. MARKING THEM CLAIMED
    # =====================================================================
    pg.click("#ga-claimed")
    pg.wait_for_timeout(500)
    marked = [c for c in pg.evaluate("window.__DB.rpcs") if c["name"] == "mark_gift_aid_claimed"]
    check(marked, "marking as claimed did not reach the database")
    if marked:
        refs = marked[0]["args"].get("p_references") or []
        check(sorted(refs) == ["DN-0001", "DN-0002", "DN-0003", "DN-0004", "DN-0005"],
              "the wrong references were marked: %r" % refs)
    pg.wait_for_timeout(400)
    check("Nothing waiting" in pg.inner_text("#ga-list"),
          "the list did not empty after the claim was filed")

    # =====================================================================
    #  06. WHO MAY SEE IT
    #
    #  A list of donors' names and home addresses. The database refuses a
    #  non-administrator regardless; this is so nobody is shown an empty panel
    #  and left thinking the page is broken.
    # =====================================================================
    # A SECOND PAGE, not a re-navigation. The stub freezes window.supabase with
    # Object.defineProperty, so running a second init script on the same page
    # throws "Cannot redefine property" — which the first attempt at this
    # section did, and the resulting failures looked like an access-control bug
    # rather than a mistake in the test.
    pg2 = b.new_page(viewport={"width": 1400, "height": 1000})
    errs2 = []
    pg2.on("pageerror", lambda e: errs2.append(str(e)[:160]))
    pg2.add_init_script(STUB.replace('roles: ["admin"]', 'roles: ["hall_office"]'))
    pg2.goto(PAGE)
    pg2.wait_for_timeout(1400)
    check(pg2.eval_on_selector("#ga-panel", "e=>e.hidden"),
          "HALL OFFICE STAFF CAN SEE DONORS' NAMES AND ADDRESSES")
    check(not pg2.is_hidden("#app-noaccess"),
          "a non-administrator is shown nothing at all, with no explanation")
    check(errs2 == [], "uncaught exceptions on the non-admin page: %s" % errs2)

    check(errs == [], "uncaught exceptions: %s" % errs)
    b.close()

print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
