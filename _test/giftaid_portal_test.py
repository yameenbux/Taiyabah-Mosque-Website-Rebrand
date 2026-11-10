"""/giftaid/ — the Donations dashboard, and getting an HMRC claim out of the
database.

Built 12 September 2026 as a Gift Aid claim screen only. Until then there was
exactly one way to extract a claim: run SQL in the Supabase editor. A masjid
treasurer will not do that, so the claim would not get made and every
carefully recorded declaration would have been for nothing.

Grew a Donations dashboard above it on 8 November 2026, covering one-off and
recurring gifts together, with purpose and recent-donation breakdowns — but
NO donor name or address anywhere in that part of the page. That stays
entirely inside the Gift Aid panel this file already tested, which section 06A
below now checks explicitly: a dashboard built to be seen by more eyes than
"the treasurer alone" must not quietly widen what those eyes can read.

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

  // The dashboard's own fixtures. Deliberately different numbers from
  // DB.claim above, so a test checking one panel's text cannot pass by
  // accident against the other panel's.
  DB.summary = [{ total_collected_p:245000, donations_count:11, average_donation_p:22273,
                  recurring_monthly_count:2, recurring_monthly_last_p:1500,
                  recurring_weekly_count:1,  recurring_weekly_last_p:500 }];
  DB.daily = [
    { day:"2026-11-06", total_p:5000,  donations_count:1 },
    { day:"2026-11-07", total_p:0,     donations_count:0 },
    { day:"2026-11-08", total_p:10000, donations_count:2 }
  ];
  DB.byPurpose = [
    { purpose:"general", total_p:80000, donations_count:4 },
    { purpose:"sadaqah", total_p:53000, donations_count:3 }
  ];
  DB.bySource = [
    { source:"online",    total_p:200000, donations_count:9 },
    { source:"in_person", total_p:45000,  donations_count:2 },
    { source:"cash",      total_p:7500,   donations_count:1 }
  ];
  // One row per standing gift, not per donor — NO donor name or address, the
  // same rule section 00A's leak check already enforces for the rest of this
  // panel. Two funds, one Gift Aid and one not, so both render paths are hit.
  DB.recurring = [
    { reference:"DN-26-0041", frequency:"monthly", purpose:"general", gift_aid:true,
      last_amount_p:1500, total_collected_p:4500, charges_count:3,
      first_paid_at:"2026-09-08T09:00:00Z", last_paid_at:"2026-11-08T09:00:00Z" },
    { reference:"DN-26-0009", frequency:"weekly", purpose:"sadaqah", gift_aid:false,
      last_amount_p:500, total_collected_p:6000, charges_count:12,
      first_paid_at:"2026-08-07T09:00:00Z", last_paid_at:"2026-11-07T09:00:00Z" }
  ];
  DB.recent = [
    { reference:"DN-26-0010", paid_at:"2026-11-08T10:00:00Z", purpose:"general",
      amount_p:5000, gift_aid:true,  frequency:null,    source:"online" },
    { reference:"DN-26-0009", paid_at:"2026-11-07T09:00:00Z", purpose:"sadaqah",
      amount_p:1500, gift_aid:false, frequency:"monthly", source:"online" },
    { reference:"DN-26-0008", paid_at:"2026-11-07T08:00:00Z", purpose:null,
      amount_p:500,  gift_aid:false, frequency:null,    source:"in_person" }
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
      if (name === "donations_summary_v2") return Promise.resolve({ data:copy(DB.summary),   error:null });
      if (name === "donations_daily")      return Promise.resolve({ data:copy(DB.daily),     error:null });
      if (name === "donations_by_purpose") return Promise.resolve({ data:copy(DB.byPurpose), error:null });
      if (name === "donations_by_source")  return Promise.resolve({ data:copy(DB.bySource),  error:null });
      if (name === "donations_recent_v2")  return Promise.resolve({ data:copy(DB.recent),    error:null });
      if (name === "donations_recurring_donors") return Promise.resolve({ data:copy(DB.recurring), error:null });
      if (name === "mark_gift_aid_claimed") {
        var refs = (args || {}).p_references || [];
        DB.claim = DB.claim.filter(function (r) { return refs.indexOf(r.reference) === -1; });
        return Promise.resolve({ data:refs.length, error:null });
      }
      if (name === "record_cash_donation") {
        return Promise.resolve({ data:{ reference:"DN-26-0200", status:"paid",
          gift_aid:!!(args||{}).p_gift_aid, already_recorded:false }, error:null });
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
    #  00A. THE DONATIONS DASHBOARD — built 8 November 2026
    # =====================================================================
    check(pg.eval_on_selector("#donations-panel", "e=>!e.hidden"),
          "the donations dashboard is hidden from an administrator")
    for rpc in ["donations_summary_v2", "donations_daily", "donations_by_purpose",
                "donations_by_source", "donations_recent_v2", "donations_recurring_donors"]:
        check(rpc in names, "the dashboard never called %s" % rpc)

    dn_sum = pg.inner_text("#dn-sum")
    check("£2450.00" in dn_sum, "total collected is wrong or missing: %r" % dn_sum)
    check("11" in dn_sum, "the donations count is wrong or missing: %r" % dn_sum)
    check("£222.73" in dn_sum, "the average donation is wrong or missing: %r" % dn_sum)

    dn_recur = pg.inner_text("#dn-recur")
    check("2" in dn_recur and "monthly" in dn_recur and "£15.00" in dn_recur,
          "the monthly givers are not summarised: %r" % dn_recur)
    check("1" in dn_recur and "weekly" in dn_recur and "£5.00" in dn_recur,
          "the weekly givers are not summarised: %r" % dn_recur)

    bars = pg.query_selector_all("#dn-chart .bar")
    check(len(bars) == 3, "expected one chart bar per day, got %d" % len(bars))
    has_bars = pg.query_selector_all("#dn-chart .bar.has")
    check(len(has_bars) == 2, "the empty day is drawn as though something came in")

    # Lower-cased for the comparison, not the display: .dn-purpose .label is
    # CSS text-transform:capitalize, which is what inner_text reports back —
    # "General", not "general" — even though the markup itself is lower case.
    dn_purpose = pg.inner_text("#dn-purpose").lower()
    check("general" in dn_purpose and "£800.00" in dn_purpose,
          "the general fund's total is wrong or missing: %r" % dn_purpose)
    check("sadaqah" in dn_purpose and "£530.00" in dn_purpose,
          "sadaqah's total is wrong or missing: %r" % dn_purpose)

    dn_heads = pg.eval_on_selector_all("#dn-recent th", "els=>els.map(e=>e.textContent.trim())")
    check(dn_heads == ["Reference", "Date", "Fund", "Amount", "Gift Aid", "Frequency", "Source"],
          "the recent-donations table has the wrong columns: %r" % dn_heads)
    dn_rows = pg.query_selector_all("#dn-recent tbody tr")
    check(len(dn_rows) == 3, "not every recent donation is listed: %d rows" % len(dn_rows))
    dn_recent_text = pg.inner_text("#dn-recent")
    check("DN-26-0010" in dn_recent_text and "£50.00" in dn_recent_text,
          "the gift-aided one-off donation is not shown right: %r" % dn_recent_text)
    check("DN-26-0009" in dn_recent_text and "monthly" in dn_recent_text,
          "the recurring donation's frequency is not shown: %r" % dn_recent_text)
    check("DN-26-0008" in dn_recent_text and "In person" in dn_recent_text,
          "the card-machine donation's source is not shown: %r" % dn_recent_text)
    check(dn_recent_text.count("Online") == 2,
          "the two online donations should both read 'Online': %r" % dn_recent_text)

    # "Collected by source" — the other half of "collected by fund".
    dn_source = pg.inner_text("#dn-source")
    check("Online" in dn_source and "£2000.00" in dn_source,
          "the online total is wrong or missing: %r" % dn_source)
    check("In person" in dn_source and "£450.00" in dn_source,
          "the in-person total is wrong or missing: %r" % dn_source)
    check("Cash" in dn_source and "£75.00" in dn_source,
          "the cash total is wrong or missing, or labelled something other than 'Cash': %r" % dn_source)

    # "Recurring gifts" — one row per standing gift, not per donor. Built
    # 9 November 2026 alongside cash logging.
    dn_recur_heads = pg.eval_on_selector_all(
        "#dn-recur-list th", "els=>els.map(e=>e.textContent.trim())")
    check(dn_recur_heads == ["Reference", "Fund", "Frequency", "Gift Aid", "Last amount",
                             "Times charged", "Total raised", "Last charged"],
          "the recurring-gifts table has the wrong columns: %r" % dn_recur_heads)
    dn_recur_rows = pg.query_selector_all("#dn-recur-list tbody tr")
    check(len(dn_recur_rows) == 2, "not every standing gift is listed: %d rows" % len(dn_recur_rows))
    dn_recur_text = pg.inner_text("#dn-recur-list")
    check("DN-26-0041" in dn_recur_text and "monthly" in dn_recur_text and "£45.00" in dn_recur_text,
          "the monthly standing gift is not shown right: %r" % dn_recur_text)
    check("DN-26-0009" in dn_recur_text and "weekly" in dn_recur_text and "£60.00" in dn_recur_text,
          "the weekly standing gift is not shown right: %r" % dn_recur_text)
    check(dn_recur_text.count("Yes") == 1,
          "exactly one of the two standing gifts is Gift Aid: %r" % dn_recur_text)

    # THE ASSERTION THAT MATTERS MOST ON THIS PANEL: a dashboard built to be
    # glanced at more often than the Gift Aid claim must not have quietly
    # widened who can see a donor's name. None of DB.claim's donors — the
    # very thing the Gift Aid panel exists to protect — may appear anywhere
    # inside the dashboard's own markup.
    dn_all_text = pg.inner_text("#donations-panel")
    for donor in ["Imran Ali", "Yusuf Patel", "Sara Bi", "Bilal Khan", "Astley Street", "BL1 8HD"]:
        check(donor not in dn_all_text,
              "a Gift Aid donor's details leaked into the donations dashboard: %r found" % donor)

    # =====================================================================
    #  00B. LOGGING A CASH DONATION — built 9 November 2026
    # =====================================================================
    check(pg.is_hidden("#dn-cash-form"), "the cash-logging form is open before anyone asked for it")
    rpcs_before_open = len(pg.evaluate("window.__DB.rpcs"))

    pg.click("#dn-cash-open")
    pg.wait_for_timeout(150)
    check(not pg.is_hidden("#dn-cash-form"), "clicking 'Log a cash donation' did not open the form")
    check(pg.is_hidden("#dn-cash-donor"),
          "the Gift Aid name/address fields are showing before the box is ticked")

    # A non-Gift-Aid cash gift: no name, no address, no postcode sent at all —
    # same discipline as the card machine, just because this one COULD carry
    # Gift Aid does not mean every cash gift does.
    pg.fill("#dn-cash-amount", "20.00")
    pg.select_option("#dn-cash-purpose", "sadaqah")
    pg.click("#dn-cash-submit")
    pg.wait_for_timeout(400)

    cash_calls = [c for c in pg.evaluate("window.__DB.rpcs") if c["name"] == "record_cash_donation"]
    check(len(cash_calls) == 1, "logging the cash donation did not reach the database")
    if cash_calls:
        args = cash_calls[0]["args"]
        check(args.get("p_amount_p") == 2000,
              "£20.00 was not converted to 2000 pence: %r" % args.get("p_amount_p"))
        check(args.get("p_purpose") == "sadaqah", "the fund was not sent: %r" % args.get("p_purpose"))
        check(args.get("p_gift_aid") is False, "Gift Aid was sent true when the box was never ticked")
        check(args.get("p_name") is None and args.get("p_address") is None and args.get("p_postcode") is None,
              "donor details were sent for a gift nobody declared Gift Aid on: %r" % args)

    check(pg.is_hidden("#dn-cash-form"), "the form did not close after a successful save")
    # Saving reloads the whole dashboard, so the treasurer sees the new total
    # without having to refresh the page by hand.
    check(len(pg.evaluate("window.__DB.rpcs")) > rpcs_before_open + 1,
          "the dashboard was not reloaded after the cash donation was saved")

    # A Gift Aid cash gift: the donor fields must appear, and must be sent.
    pg.click("#dn-cash-open")
    pg.wait_for_timeout(150)
    pg.fill("#dn-cash-amount", "15.00")
    pg.check("#dn-cash-ga")
    check(not pg.is_hidden("#dn-cash-donor"),
          "ticking Gift Aid did not reveal the name/address/postcode fields")
    pg.fill("#dn-cash-name", "Test Donor")
    pg.fill("#dn-cash-address", "1 Example Street, Bolton")
    pg.fill("#dn-cash-postcode", "bl1 1aa")
    pg.click("#dn-cash-submit")
    pg.wait_for_timeout(400)

    cash_calls = [c for c in pg.evaluate("window.__DB.rpcs") if c["name"] == "record_cash_donation"]
    check(len(cash_calls) == 2, "the second cash donation did not reach the database")
    if len(cash_calls) == 2:
        args = cash_calls[1]["args"]
        check(args.get("p_gift_aid") is True, "Gift Aid was not sent true after the box was ticked")
        check(args.get("p_name") == "Test Donor", "the donor's name was not sent: %r" % args.get("p_name"))
        check(args.get("p_postcode") == "bl1 1aa",
              "the postcode was not sent as typed (uppercasing is the database's job): %r" % args.get("p_postcode"))

    # An empty/zero amount must be refused before it ever reaches the database.
    pg.click("#dn-cash-open")
    pg.wait_for_timeout(150)
    rpcs_before_bad = len(pg.evaluate("window.__DB.rpcs"))
    pg.click("#dn-cash-submit")
    pg.wait_for_timeout(200)
    check(len(pg.evaluate("window.__DB.rpcs")) == rpcs_before_bad,
          "a blank cash-donation form reached the database instead of being refused on the page")
    check(not pg.is_hidden("#dn-cash-error"), "a blank amount was accepted with no warning shown")
    pg.click("#dn-cash-cancel")

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
    check(pg2.eval_on_selector("#donations-panel", "e=>e.hidden"),
          "hall office staff can see the donations dashboard")
    check(not pg2.is_hidden("#app-noaccess"),
          "a non-administrator is shown nothing at all, with no explanation")
    check(errs2 == [], "uncaught exceptions on the non-admin page: %s" % errs2)

    check(errs == [], "uncaught exceptions: %s" % errs)
    b.close()

print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
