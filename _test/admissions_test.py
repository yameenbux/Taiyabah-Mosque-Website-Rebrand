"""The Applications screen, driven in a browser against a stubbed database.

WHAT THIS SUITE IS FOR

db/076 proves the rules that live in Postgres: that the list function cannot
carry a child's medical detail, that opening a record writes an audit row, that
anon reaches nothing. Those are checks on the database and they run there.

This proves the half SQL cannot see:

  * that a teaching account is refused the screen outright, rather than being
    shown an empty page and an error;
  * that the marks in the list say SEND and ALLERGY and never what they are;
  * that declining asks for a reason BEFORE it asks Postgres, so the person
    finds out at the button and not after;
  * that the notice changes shape when something has been waiting a week,
    because a band that reads the same either way stops being read;
  * that a row opens from the keyboard and not only from a mouse;
  * that changing a filter closes a record rather than leaving it on screen
    beside a list it is no longer in;
  * that the screen does not scroll sideways on a phone.

Every check in here was watched failing before it was kept.

    python3 _test/admissions_test.py
"""
import atexit
import http.server
import json
import os
import socketserver
import sys
import threading

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(("127.0.0.1", 0),
                               lambda *a: Quiet(*a, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % httpd.server_address[1]

FAILURES = []
CHECKS = [0]

#  THE SAME GUARD fees_test NEEDED.
#
#  That suite once reported ALL PASS having run 124 of its 202 checks, because
#  a click timed out and the exception left the counter where it was. A run
#  that stops early has to be distinguishable from a run that passed, and the
#  only thing that can tell them apart is whether the end of run() was reached.
FINISHED = [False]


@atexit.register
def report():
    if FAILURES:
        print("\n%d FAILURE(S) out of %d checks:" % (len(FAILURES), CHECKS[0]))
        for f in FAILURES:
            print("  - " + f)
    elif not FINISHED[0]:
        print("\nRUN INCOMPLETE — %d checks ran and the suite never reached its "
              "end. Something above stopped it. Do not read this as a pass."
              % CHECKS[0])
    else:
        print("\nALL PASS — %d checks" % CHECKS[0])


def check(name, ok, got=None):
    CHECKS[0] += 1
    if not ok:
        FAILURES.append(name + ("" if got is None else ": %s" % (got,)))


def says(haystack, needle):
    """Case-folded. CSS uppercases several of these labels, so a literal
    comparison would be testing the stylesheet rather than the words."""
    return needle.lower() in (haystack or "").lower()


# ---------------------------------------------------------------------------
#  The fixtures. One application of each shape the screen has to handle.
# ---------------------------------------------------------------------------
def iso(days_ago):
    import datetime
    return (datetime.datetime.now(datetime.timezone.utc)
            - datetime.timedelta(days=days_ago)).isoformat()


ROW_NEW = {
    "id": "a1", "reference": "AD-0001", "academic_year": "2026/27",
    "submitted_at": iso(11), "status": "new",
    "parent": "Fatima Khan", "relationship": "mother",
    "mobile": "07700900001", "email": "f@example.test", "town": "Bolton",
    "reviewed_at": None, "reviewed_by": None, "has_note": False,
    "children": 2, "child_names": "Yusuf Khan, Maryam Khan",
    "has_send": True, "has_ehcp": False, "has_allergies": True,
    "has_medical": True,
}
ROW_OFFERED = {
    "id": "a2", "reference": "AD-0002", "academic_year": "2026/27",
    "submitted_at": iso(3), "status": "offered",
    "parent": "Imran Patel", "relationship": "father",
    "mobile": "07700900002", "email": "i@example.test", "town": "Bolton",
    "reviewed_at": iso(1), "reviewed_by": "A Person", "has_note": True,
    "children": 1, "child_names": "Bilal Patel",
    "has_send": False, "has_ehcp": False, "has_allergies": False,
    "has_medical": False,
}

RECORD = {
    "id": "a1", "reference": "AD-0001", "academic_year": "2026/27",
    "submitted_at": iso(11), "status": "new", "office_notes": "",
    "reviewed_at": None, "reviewed_by": None,
    "parent": {
        "first_name": "Fatima", "surname": "Khan", "relationship": "mother",
        "email": "f@example.test", "telephone": None, "mobile": "07700900001",
        "address_line1": "14 Blackburn Road", "address_line2": None,
        "town": "Bolton", "postcode": "BL1 8DP",
    },
    "declaration_accepted": True, "privacy_accepted": True,
    "children": [
        {"id": "s1", "position": 1, "first_name": "Yusuf", "surname": "Khan",
         "date_of_birth": "2019-04-02", "age_years": 7, "gender": "boy",
         "school_name": "Clarendon Primary", "school_year": "Year 2",
         "previous_madrasah": None,
         "has_send": True, "send_detail": "Speech and language support",
         "has_eha_ehcp": False, "eha_ehcp_detail": None,
         "has_allergies": True, "allergy_detail": "Peanuts — carries an EpiPen",
         "medical_conditions": "Mild asthma, blue inhaler",
         "general_notes": None,
         "choices": [{"class_key": "boys_year1", "preference": 1}]},
        {"id": "s2", "position": 2, "first_name": "Maryam", "surname": "Khan",
         "date_of_birth": "2021-11-20", "age_years": 4, "gender": "girl",
         "school_name": "Clarendon Primary", "school_year": "Reception",
         "previous_madrasah": None,
         "has_send": False, "send_detail": None,
         "has_eha_ehcp": False, "eha_ehcp_detail": None,
         "has_allergies": False, "allergy_detail": None,
         "medical_conditions": None, "general_notes": None,
         "choices": [{"class_key": "girls_reception", "preference": 1}]},
    ],
    "contacts": [
        {"id": "k1", "position": 1, "full_name": "Fatima Khan",
         "relationship": "mother", "email": "f@example.test",
         "telephone": None, "mobile": "07700900001", "alt_mobile": None,
         "is_primary": True},
    ],
}


def overview(new=1, oldest=11, total=2):
    return {
        "as_at": iso(0), "new": new, "reviewing": 0, "offered": 1,
        "waitlisted": 0, "declined": 0, "withdrawn": 0, "total": total,
        "oldest_new_days": oldest, "children_waiting": 2 if new else 0,
        "years": ["2026/27"],
        "recent": [{"id": "a1", "reference": "AD-0001",
                    "submitted_at": iso(11), "status": "new", "children": 2}],
    }


def stub(roles, ov, rows):
    return """
(function(){
  var ROLES = %s, OVERVIEW = %s, ROWS = %s, RECORD = %s;
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
      if (name === 'madrasah_admissions_overview')
        return Promise.resolve({data:OVERVIEW, error:null});
      if (name === 'madrasah_admission_list') {
        var out = ROWS.slice();
        if (args && args.p_status)
          out = out.filter(function(r){ return r.status === args.p_status; });
        if (args && args.p_q) {
          var q = String(args.p_q).toLowerCase();
          out = out.filter(function(r){
            return (r.parent + ' ' + r.child_names + ' ' + r.reference)
                     .toLowerCase().indexOf(q) !== -1; });
        }
        return Promise.resolve({data:out, error:null});
      }
      if (name === 'madrasah_admission_one')
        return Promise.resolve({data:RECORD, error:null});
      if (name === 'set_admission_status') {
        if (args.p_status === 'declined' && !args.p_note)
          return Promise.resolve({data:null, error:{message:
            'Say why this application is being declined.'}});
        return Promise.resolve({data:{ok:true}, error:null});
      }
      if (name === 'save_admission_note')
        return Promise.resolve({data:{ok:true}, error:null});
      return Promise.resolve({data:null, error:{message:'unstubbed ' + name}});
    }
  };
  /*  PINNED, not assigned. admin/supabase.js loads after this script and
      sets window.supabase itself, so a plain assignment is overwritten and
      the page quietly talks to the REAL project instead of the stub - which
      returns no session, shows the sign-in card, and makes every check below
      fail in a way that looks like the screen is broken. fees_test learned
      this; the technique is lifted from it verbatim. */
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}},
     writable:false, configurable:false});
})();
""" % (json.dumps(roles), json.dumps(ov), json.dumps(rows), json.dumps(RECORD))


def open_page(browser, roles=("admin",), ov=None, rows=None,
              width=1500, height=1000):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.set_default_timeout(7000)
    pg.add_init_script(stub(list(roles),
                            ov if ov is not None else overview(),
                            rows if rows is not None else [ROW_NEW, ROW_OFFERED]))
    pg.goto(BASE + "/portal/admissions/", wait_until="load")
    pg.wait_for_timeout(700)
    return pg


def run():
    with sync_playwright() as p:
        b = p.chromium.launch()

        # --- who may open it at all ----------------------------------------
        pg = open_page(b, roles=("madrasah",))
        check("a teaching account is refused the screen",
              pg.locator("#ad-panel").is_hidden())
        check("and is told so rather than shown an empty page",
              pg.locator("#app-noaccess").is_visible())
        pg.close()

        pg = open_page(b, roles=("admin",))
        check("an administrator gets the panel", pg.locator("#ad-panel").is_visible())

        # --- the notice -----------------------------------------------------
        notice = pg.locator("#ad-notice")
        check("the notice is shown", notice.is_visible())
        cls = notice.get_attribute("class") or ""
        check("11 days waiting reads as late, not merely waiting",
              "is-late" in cls, cls)
        txt = notice.inner_text()
        #  "One application nobody has looked at", not "1 application".
        #  The check was written expecting the digit and the copy is better
        #  than the check was; a heading a person reads should read like one.
        #  Both forms are asserted, below and further down, because a plural
        #  bug that only shows at two is exactly the kind that ships.
        check("it says how many, in words at one",
              says(txt, "one application nobody has looked at"), txt[:90])
        check("it says how long, which is the number that makes it honest",
              says(txt, "11 days"))
        check("it says opening one does not clear it",
              says(txt, "opening one does not clear it"))
        check("the count is on screen", pg.locator("#ad-notice-count").inner_text() == "1")

        # --- the list carries marks, never detail ---------------------------
        rows_txt = pg.locator("#ad-rows").inner_text()
        check("the list shows the family", says(rows_txt, "Fatima Khan"))
        check("and the children's names, so it can be worked",
              says(rows_txt, "Yusuf Khan"))
        check("a SEND mark is shown", says(rows_txt, "SEND"))
        check("an allergy mark is shown", says(rows_txt, "Allergy"))

        #  THE CHECK THIS SUITE EXISTS FOR.
        for secret in ("Peanuts", "EpiPen", "asthma", "Speech and language"):
            check("the list never shows %r" % secret,
                  not says(rows_txt, secret), rows_txt[:120])

        # --- opening one ----------------------------------------------------
        pg.locator("tr.ad-row").first.click()
        pg.wait_for_timeout(500)
        rec = pg.locator("#ad-record")
        check("the record opens", rec.is_visible())
        rec_txt = rec.inner_text()
        check("the record does show the allergy", says(rec_txt, "Peanuts"))
        check("and the medical note", says(rec_txt, "asthma"))
        check("and the SEND detail", says(rec_txt, "Speech and language"))
        check("both children are shown", says(rec_txt, "Maryam"))
        check("the class asked for is named, not keyed",
              says(rec_txt, "Boys Year 1") and not says(rec_txt, "boys_year1"))
        check("the date of birth is not a day early",
              says(rec_txt, "2 Apr 2019"), rec_txt[:200])

        calls = pg.evaluate("() => window.__calls.map(c => c.name)")
        check("opening it called the audited function",
              "madrasah_admission_one" in calls, calls)

        # --- declining asks first -------------------------------------------
        pg.locator('#ad-record .btn[data-to="declined"]').click()
        pg.wait_for_timeout(250)
        check("declining reveals the reason box first",
              pg.locator("#ad-why").is_visible())
        before = pg.evaluate("() => window.__calls.filter(c => "
                             "c.name === 'set_admission_status').length")
        pg.locator("#ad-why-go").click()
        pg.wait_for_timeout(350)
        after = pg.evaluate("() => window.__calls.filter(c => "
                            "c.name === 'set_admission_status').length")
        check("an empty reason never reaches the database", before == after,
              "%d -> %d" % (before, after))
        check("and the screen says why not",
              says(pg.locator("#ad-rec-error").inner_text(), "say why"))

        pg.fill("#ad-why-text", "Full for this year group.")
        pg.locator("#ad-why-go").click()
        pg.wait_for_timeout(500)
        sent = pg.evaluate("""() => (window.__calls.filter(c =>
                 c.name === 'set_admission_status').pop() || {}).args""")
        check("a reason does reach it", (sent or {}).get("p_note", "").startswith("Full"),
              sent)

        # --- offering does not ask ------------------------------------------
        pg.locator("tr.ad-row").first.click()
        pg.wait_for_timeout(400)
        n0 = pg.evaluate("() => window.__calls.filter(c => "
                         "c.name === 'set_admission_status').length")
        pg.locator('#ad-record .btn[data-to="offered"]').click()
        pg.wait_for_timeout(500)
        n1 = pg.evaluate("() => window.__calls.filter(c => "
                         "c.name === 'set_admission_status').length")
        check("offering a place needs no reason", n1 == n0 + 1, "%d -> %d" % (n0, n1))

        # --- a filter closes an open record ---------------------------------
        pg.locator("tr.ad-row").first.click()
        pg.wait_for_timeout(400)
        check("record is open before the filter changes",
              pg.locator("#ad-record").is_visible())
        pg.select_option("#ad-status", "offered")
        pg.wait_for_timeout(500)
        check("changing a filter closes the record rather than stranding it",
              pg.locator("#ad-record").is_hidden())
        check("and the list is filtered",
              says(pg.locator("#ad-rows").inner_text(), "Imran Patel"))
        check("the filtered-out family is gone",
              not says(pg.locator("#ad-rows").inner_text(), "Fatima Khan"))
        pg.close()

        # --- the keyboard ----------------------------------------------------
        pg = open_page(b)
        pg.locator("tr.ad-row").first.focus()
        pg.keyboard.press("Enter")
        pg.wait_for_timeout(500)
        check("a row opens from the keyboard", pg.locator("#ad-record").is_visible())
        pg.close()

        # --- nothing waiting looks different ---------------------------------
        pg = open_page(b, ov=overview(new=0, oldest=None, total=2),
                       rows=[ROW_OFFERED])
        cls = pg.locator("#ad-notice").get_attribute("class") or ""
        check("nothing waiting reads as clear", "is-clear" in cls, cls)
        check("and the 'show them' button is not offered",
              pg.locator("#ad-notice-go").is_hidden())
        check("it does not claim an empty madrasah when applications exist",
              says(pg.locator("#ad-notice").inner_text(), "have been received"))
        pg.close()

        # --- a week is the line ----------------------------------------------
        pg = open_page(b, ov=overview(new=2, oldest=2))
        cls = pg.locator("#ad-notice").get_attribute("class") or ""
        check("two days waiting is waiting, not late",
              "is-waiting" in cls and "is-late" not in cls, cls)
        ntxt = pg.locator("#ad-notice").inner_text()
        check("and two reads as a plural, with the digit",
              says(ntxt, "2 applications nobody has looked at"), ntxt[:90])
        check("two children waiting is pluralised too",
              says(ntxt, "2 children are waiting"), ntxt[:120])
        pg.close()

        # --- no applications at all -------------------------------------------
        pg = open_page(b, ov=overview(new=0, oldest=None, total=0), rows=[])
        check("an empty madrasah says the form is live rather than showing 0s",
              says(pg.locator("#ad-notice").inner_text(),
                   "form is live on the website"))
        check("and the table says so too",
              pg.locator("#ad-empty").is_visible())
        pg.close()

        # --- the link to the public form --------------------------------------
        pg = open_page(b)
        href = pg.locator("#ad-form-link").get_attribute("href")
        check("the screen links to the live public form",
              href and href.endswith("/apply/"), href)
        check("and opens it in a new tab, so the list is not lost",
              pg.locator("#ad-form-link").get_attribute("target") == "_blank")
        real = os.path.join(ROOT, "apply", "index.html")
        check("and that form actually exists in the repository",
              os.path.exists(real), real)
        pg.close()

        # --- a phone ----------------------------------------------------------
        pg = open_page(b, width=390, height=900)
        pg.wait_for_timeout(400)
        over = pg.evaluate("() => document.documentElement.scrollWidth - "
                           "document.documentElement.clientWidth")
        check("the screen does not scroll sideways on a phone", over <= 1, over)
        check("the notice is still readable at 390px",
              pg.locator("#ad-notice").is_visible())
        pg.close()

        b.close()

    FINISHED[0] = True
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(run())
