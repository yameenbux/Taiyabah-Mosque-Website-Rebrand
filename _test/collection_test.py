"""/collection/ and /collections/ — the charity collection (chanda) booking.

14 September 2026. Replaces a paper CHARITY DATA FORM and a poster carrying
two committee members' mobile numbers.

WHAT THIS FILE GUARDS. Not the rules — those are in Postgres (030:
request_charity_collection, the notice period, the duplicate check, the
column-level GRANT). What it guards is the two pages:

   1  the public form refuses to submit empty, and marks every field
   2  the wage/commission question is answerable, keyboard-reachable, and
      its note follows the answer rather than appearing as an error
   3  a date inside the notice period is refused in the browser as well as
      in the database
   4  THE PAYLOAD. Every key the page sends is a key the function reads, and
      no key is missing. A field the page calls org_phone and the function
      reads as phone does not error — it inserts a null and the form looks
      like it worked. This is the check that catches that.
   5  the reference that comes back is shown to the visitor, and the form
      goes away
   6  the office screen draws, and surfaces the two things on it that are
      NOT administration: a collector who is PAID, and two charities asking
      for one day
   7  the tab counts are right
   8  a UK charity number links to the register and an overseas registration
      number does not — a dead link to the Commission looks like the masjid
      checked and found nothing

WHAT IT CANNOT CHECK. Whether the browser can actually reach Supabase: this
sandbox's egress proxy refuses the project host, so the submission in section
4 is intercepted and answered locally. The payload it captures was separately
fed to the real function, and every field landed. That is recorded in the
commit, not here, because a test cannot assert something it cannot reach.

Nothing here touches the live project. The office screen's client is replaced
before the page's own scripts run.

Run:  python3 _test/collection_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, base64, json, datetime, http.server, socketserver, threading, functools

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % httpd.server_address[1]

#  A one-pixel PNG. The form only cares that the type is one it takes and
#  that the file is under 5 MB; the bytes are never looked at.
PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM"
    "IQAAAABJRU5ErkJggg==")

#  The certificate has to be dated inside the window the form allows, which
#  is the last CERT_MONTHS months up to today. A month back is safely inside
#  it whatever today happens to be.
CERT_ON = (datetime.date.today() - datetime.timedelta(days=30)).isoformat()

fails = []


def check(ok, why):
    if not ok:
        fails.append(why)


D = '[data-page="collection"] '
WHEN = (datetime.date.today() + datetime.timedelta(days=45)).isoformat()
SOON = (datetime.date.today() + datetime.timedelta(days=3)).isoformat()

D1   = (datetime.date.today() + datetime.timedelta(days=30)).isoformat()
D2   = (datetime.date.today() + datetime.timedelta(days=60)).isoformat()
PAST = (datetime.date.today() - datetime.timedelta(days=10)).isoformat()


def row(i, name, date, status, paid, num):
    return {"id": "id-%d" % i, "reference": "CC-26-000%d" % i,
            "submitted_at": "2026-09-12T09:00:00Z", "requested_date": date,
            "agreed_date": None, "status": status, "org_name": name,
            "org_address": "1 Some Street, Somewhere",
            "org_phone": "07000000%03d" % i, "org_email": "a%d@example.test" % i,
            "charity_number": num, "collector_name": "Collector %d" % i,
            "collector_role": "Fundraiser", "collector_paid": paid,
            "trustee_name": "Trustee %d" % i, "trustee_phone": "07111111%03d" % i,
            "trustee_email": "t%d@example.test" % i, "rules_version": "2026-09-14",
            "signed_name": "Collector %d" % i, "office_notes": None}


#  Deliberately shaped: two charities on ONE day (one of them paid), one
#  approved later, one in the past. A fixture where nothing collides never
#  exercises the only two things on that screen that matter.
ROWS = [
    row(1, "Al-Noor Relief",    D1,   "new",       False, "1041569"),
    row(2, "Sahara Aid",        D1,   "new",       True,  "9999999999-OVERSEAS"),
    row(3, "Baitul Maal Trust", D2,   "approved",  False, None),
    row(4, "Old Appeal",        PAST, "completed", False, "1122334"),
]

STUB = """
(function(){
  var ROWS = %s;
  function q(t){
    var self={};
    ['select','eq','neq','in','is','not','gt','gte','lt','lte','like','ilike',
     'order','limit','range','filter','or','match','update','upsert','delete'
    ].forEach(function(m){ self[m]=function(){ return self; }; });
    self.maybeSingle=function(){ return Promise.resolve({data:{full_name:'A Person',
      email:'office@example.test'}, error:null}); };
    self.single=self.maybeSingle;
    self.then=function(a,b){
      var data = t==='user_roles' ? [{role:'hall_office'}]
               : t==='charity_collections' ? ROWS : [];
      return Promise.resolve({data:data, error:null}).then(a,b); };
    return self;
  }
  var client={
    auth:{ getUser:function(){ return Promise.resolve({data:{user:{id:'u1',
             email:'office@example.test'}}, error:null}); },
      getSession:function(){ return Promise.resolve({data:{session:{access_token:'t'}}}); },
      signOut:function(){ return Promise.resolve({}); },
      onAuthStateChange:function(){ return {data:{subscription:{unsubscribe:function(){}}}}; },
      mfa:{ getAuthenticatorAssuranceLevel:function(){ return Promise.resolve(
              {data:{currentLevel:'aal2',nextLevel:'aal2'},error:null}); },
            listFactors:function(){ return Promise.resolve({data:{totp:[{id:'f1'}]},error:null}); } } },
    from:function(t){ return q(t); },
    rpc:function(){ return q('rpc'); }
  };
  Object.defineProperty(window,'supabase',
    {value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % json.dumps(ROWS)


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1-5. THE PUBLIC FORM
    # =====================================================================
    seen = {}

    def handler(route, request):
        seen["url"] = request.url
        seen["hdr"] = {k.lower(): v for k, v in request.headers.items()}
        seen["body"] = json.loads(request.post_data or "{}")
        route.fulfill(status=200, content_type="application/json",
                      body=json.dumps({"reference": "CC-26-TEST",
                                       "requested_date": WHEN}))

    pg = b.new_page(viewport={"width": 1400, "height": 1100})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:220]))
    pg.route("**/rest/v1/rpc/**", handler)

    #  THE CERTIFICATE UPLOAD. The form stores the BMCC certificate in a
    #  private bucket BEFORE it writes the request, so that a request can
    #  never name a file that is not there. Nothing here is routed by the
    #  rpc handler above - it is a storage call, not an RPC - so without
    #  this it leaves for the real internet and the chain never resolves.
    uploaded = {}

    def storage(route, request):
        uploaded["url"] = request.url
        uploaded["hdr"] = {k.lower(): v for k, v in request.headers.items()}
        uploaded["bytes"] = len(request.post_data_buffer or b"")
        route.fulfill(status=200, content_type="application/json", body="{}")

    pg.route("**/storage/v1/object/**", storage)
    pg.goto(BASE + "/index.html", wait_until="load")
    pg.wait_for_timeout(1400)
    pg.evaluate("() => { if (window.showPage) showPage('collection'); }")
    pg.wait_for_timeout(500)

    #  1. an empty form must not submit
    pg.click(D + "#ccSubmit")
    pg.wait_for_timeout(400)
    bad = pg.eval_on_selector_all(D + ".bad", "e => e.length")
    check(bad > 5, "an empty form raised only %d errors" % bad)
    check(pg.is_visible(D + "#ccForm"), "AN EMPTY FORM WAS SUBMITTED")

    #  2. the wage question
    check(not pg.is_visible(D + "#ccPaidNote"),
          "the paid note is showing before anybody answered")
    pg.click(D + '.cc-yn label:has(input[value="yes"])')
    pg.wait_for_timeout(250)
    check(pg.is_visible(D + "#ccPaidNote"), "answering Yes showed nothing")
    pg.click(D + '.cc-yn label:has(input[value="no"])')
    pg.wait_for_timeout(250)
    check(not pg.is_visible(D + "#ccPaidNote"),
          "the paid note stayed after switching to No")
    #  The radio is visually hidden. It must still be reachable, or the
    #  question cannot be answered without a mouse.
    focusable = pg.evaluate("""() => { const r = document.querySelector(
        '[data-page="collection"] input[name=ccPaid][value=yes]');
        if (!r) return false; r.focus(); return document.activeElement === r; }""")
    check(focusable, "THE WAGE QUESTION CANNOT BE FOCUSED FROM THE KEYBOARD")

    #  3. short notice, refused in the browser too
    pg.fill(D + "#ccDate", SOON)
    pg.click(D + "#ccSubmit")
    pg.wait_for_timeout(300)
    check("bad" in (pg.get_attribute(D + "#ccr-date", "class") or ""),
          "three days' notice was accepted by the page")

    #  4-5. a full submission
    pg.fill(D + "#ccDate", WHEN)
    pg.fill(D + "#ccOrg", "  Testville Relief Trust  ")      # padded on purpose
    pg.fill(D + "#ccAddr", "1 Test Street, Testville TE1 1ST")
    pg.fill(D + "#ccPhone", "07000000000")
    pg.fill(D + "#ccEmail", "  ZZ-Test@Example.TEST ")       # cased on purpose
    pg.fill(D + "#ccNum", "1041569")
    pg.fill(D + "#ccCName", "Test Collector")
    pg.fill(D + "#ccCRole", "Volunteer")
    pg.click(D + '.cc-yn label:has(input[value="yes"])')
    pg.fill(D + "#ccTName", "Test Trustee")
    pg.fill(D + "#ccTPhone", "07000000001")
    pg.fill(D + "#ccTEmail", "zz-trustee@example.test")
    pg.check(D + "#ccRules")
    pg.check(D + "#ccPriv")
    pg.fill(D + "#ccSign", "Test Collector")

    #  THE BMCC CERTIFICATE. Required since the form was rewritten, and the
    #  reason this suite was red: it filled every field the certificate
    #  replaced and none of the ones that replaced them, so the page refused
    #  the form, the request was never sent, and the "which endpoint did it
    #  post to" check read the page-load call to courses_public instead.
    pg.set_input_files(D + "#ccFile", files=[{
        "name": "bmcc.png", "mimeType": "image/png", "buffer": PNG}])
    pg.fill(D + "#ccCertDate", CERT_ON)
    pg.click(D + "#ccSubmit")
    try:
        pg.wait_for_selector(D + "#ccDone:not([hidden])", timeout=12000)
        check((pg.text_content(D + "#ccRef") or "").strip() == "CC-26-TEST",
              "the reference the server sent was not shown to the visitor")
        check(not pg.is_visible(D + "#ccForm"),
              "the form was still on screen after it had been sent")
    except Exception:
        check(False, "a complete form never reached the finished state")

    check(errs == [], "the collection page threw: %s" % errs)

    if "url" not in seen:
        check(False, "THE FORM NEVER CALLED THE DATABASE AT ALL")
    else:
        check(seen["url"].endswith("/rest/v1/rpc/request_charity_collection"),
              "the form posts to the wrong place: %s" % seen["url"])
        check(str(seen["hdr"].get("apikey", "")).startswith("sb_publishable_"),
              "the form did not send the publishable key")
        check("service_role" not in json.dumps(seen["hdr"]),
              "A SECRET KEY IS BEING SENT FROM THE BROWSER")

        pl = seen["body"].get("payload", {})
        EXPECT = ["requested_date", "org_name", "org_address", "org_phone",
                  "org_email", "charity_number", "collector_name",
                  "collector_role", "collector_paid", "trustee_name",
                  "trustee_phone", "trustee_email", "rules_version",
                  "rules_accepted", "signed_name", "privacy_accepted",
                  #  The BMCC certificate and the two madrasah figures.
                  #  Checked against the live function before being added
                  #  here rather than assumed: public.request_charity_
                  #  collection(payload jsonb) reads all four. A list that
                  #  is merely kept in step with the page proves only that
                  #  the page agrees with itself.
                  "bmcc_certificate_path", "bmcc_certificate_date",
                  "students_total", "students_boarding"]
        missing = [k for k in EXPECT if k not in pl]
        extra = [k for k in pl if k not in EXPECT]
        check(not missing, "the page never sends these, so they arrive null: %s" % missing)
        check(not extra, "the page sends fields the function ignores: %s" % extra)
        check(pl.get("collector_paid") is True,
              "Yes did not become true: %r" % pl.get("collector_paid"))
        check(pl.get("org_name") == "Testville Relief Trust",
              "the charity name was not trimmed: %r" % pl.get("org_name"))
        check(bool(pl.get("rules_version")),
              "NO RULES VERSION TRAVELLED — nobody could say later what was agreed")
    pg.close()

    # =====================================================================
    #  6-8. THE OFFICE SCREEN
    # =====================================================================
    pg = b.new_page(viewport={"width": 1400, "height": 1200})
    errs2 = []
    pg.on("pageerror", lambda e: errs2.append(str(e)[:220]))
    pg.add_init_script(STUB)
    pg.goto(BASE + "/collections/", wait_until="load")
    pg.wait_for_timeout(2200)

    check(errs2 == [], "the office screen threw: %s" % errs2)
    check(pg.is_visible("#cc-panel"), "the collections panel never appeared")

    #  text_content, NOT inner_text: .cc-paid is text-transform:uppercase and
    #  innerText returns the transformed text, so the badge comes back as
    #  "COLLECTOR IS PAID" and the assertion fails on a correct page.
    txt = pg.text_content("#cc-list") or ""
    check("Al-Noor Relief" in txt and "Sahara Aid" in txt,
          "the requests are not listed")
    check("Collector is paid" in txt,
          "A PAID COLLECTOR IS NOT FLAGGED ON THE ROW")
    check("Another request already wants" in txt,
          "TWO CHARITIES ASKING FOR ONE DAY IS NOT FLAGGED")

    def n(i):
        return (pg.text_content("#cc-n-" + i) or "").strip()

    check(n("open") == "2", "'To answer' counts %s, expected 2" % n("open"))
    check(n("paid") == "1", "'Paid collector' counts %s, expected 1" % n("paid"))
    check(n("clash") == "2", "'Same day' counts %s, expected 2" % n("clash"))
    check(n("past") == "1", "'Past' counts %s, expected 1" % n("past"))
    check(n("all") == "4", "'Everything' counts %s, expected 4" % n("all"))

    #  On Everything, because the past row carries a UK number too.
    pg.click('#cc-tabs .bk-tab[data-filter="all"]')
    pg.wait_for_timeout(300)
    pg.eval_on_selector_all("#cc-list details", "els => els.forEach(e => e.open = true)")
    pg.wait_for_timeout(200)
    links = pg.eval_on_selector_all("#cc-list a[href*='charitycommission']", "e => e.length")
    check(links == 2, "expected both UK numbers to link to the register, got %d" % links)
    check("not a UK charity number" in (pg.text_content("#cc-list") or ""),
          "an overseas registration number was treated as a UK one — a dead link "
          "to the Commission reads as 'the masjid checked and found nothing'")

    #  The office may write notes and move the status. It must not be offered a
    #  way to edit what the charity declared — that is enforced by the GRANT in
    #  030, and a box on screen that silently fails to save is worse than no box.
    editable = pg.eval_on_selector_all(
        "#cc-list input:not([type=search]), #cc-list textarea:not(.cc-notes)",
        "els => els.length")
    check(editable == 0,
          "the office screen offers %d field(s) that the database will refuse to "
          "save — the only writable box may be office notes" % editable)
    pg.close()

    b.close()

httpd.shutdown()
print("\n" + ("ALL PASS" if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
