"""portal/pupil/ — one child's record, as a page of its own.

LOCAL ONLY. Never run against Supabase. Everything here talks to a stub that
is pinned onto window before the page's own script runs.

WHAT THIS SUITE IS REALLY FOR. The page shows a child's allergies, medical
notes and home address, and opening it writes an audit row saying who looked.
So the checks that matter are not "does it render" but:

  - is the allergy on screen the moment the page opens, or behind a tab
  - is the audit written ONCE, on load, and not once per tab
  - does the page title carry the child's name into browser history
  - does a signed-out visitor holding a valid id get anything at all

    python3 _test/pupil_page_test.py
"""
import atexit
import http.server
import json
import os
import socketserver
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

FAILS = []
COUNT = [0]
FINISHED = [False]


def check(name, ok, got=None):
    COUNT[0] += 1
    if not ok:
        FAILS.append(name + ("" if got is None else ": %s" % (got,)))


def report():
    #  A run that stops early must never read as a pass.
    if not FINISHED[0]:
        print("\nRUN INCOMPLETE — %d checks ran and the suite never reached "
              "its end. Do not read this as a pass." % COUNT[0])
    elif FAILS:
        print("\n%d FAILURE(S) out of %d checks:" % (len(FAILS), COUNT[0]))
        for f in FAILS:
            print("  - " + f)
    else:
        print("\nALL PASS — %d checks" % COUNT[0])


atexit.register(report)

#  These strings must appear on the page when the tab is open, and the audit
#  must have been written before they do.
SECRET_ALLERGY = "ZZPEANUTS-CARRIES-AN-EPIPEN"
SECRET_MEDICAL = "ZZASTHMA-BLUE-INHALER"

PUPIL = {
    "id": "p1", "legacy_ref": "1001", "first_name": "Aaliyah",
    "last_name": "Testerson", "name": "Aaliyah Testerson",
    "date_of_birth": "2015-04-02", "age": 11, "gender": "female",
    "email": None, "address": "1 Test Street", "postcode": "BL1 8DP",
    "school": "Clarendon Primary", "school_year": "Year 6",
    "prev_madrasah": None,
    "medical": SECRET_MEDICAL, "allergies": SECRET_ALLERGY,
    "send_detail": None, "ehcp_detail": None,
    "walk_home_consent": False, "notes": "Collected by an aunt on Thursdays.",
    "joined_on": "2024-09-01", "left_on": None,
    "household": {"id": "h1", "reference": "MF-0042", "name": "Testerson family",
                  "guardians": [{"id": "g1", "name": "A Testerson",
                                 "email": "t@example.test",
                                 "phone": "07000000000", "is_primary": True}],
                  "siblings": [{"id": "p2", "name": "Bilal Testerson"}]},
    "classes": [{"id": "c1", "name": "Girls Class 6", "section": "girls",
                 "teacher": "Apa Somebody"}],
    "fee_rate": None,
}

PLAIN = dict(PUPIL, id="p2", name="Bilal Testerson", legacy_ref="1002",
             medical=None, allergies=None, send_detail=None, ehcp_detail=None,
             notes=None, household=None, classes=[])


def stub(roles, pupil=None, error=None):
    return """
(function(){
  var ROLES=%s, PUPIL=%s, ERR=%s;
  window.__calls=[];
  var client={
    auth:{
      getSession:function(){ return Promise.resolve({data:{session:{access_token:'t',
        user:{id:'u1',email:'a@b.test'}}}}); },
      getUser:function(){ return Promise.resolve({data:{user:{id:'u1',email:'a@b.test'}}}); },
      signOut:function(){ return Promise.resolve({}); },
      onAuthStateChange:function(){ return {data:{subscription:{unsubscribe:function(){}}}}; },
      mfa:{ getAuthenticatorAssuranceLevel:function(){ return Promise.resolve(
              {data:{currentLevel:'aal2',nextLevel:'aal2'},error:null}); },
            listFactors:function(){ return Promise.resolve({data:{totp:[{id:'f1'}]},error:null}); } }
    },
    from:function(t){
      var rows = t==='profiles' ? {full_name:'A Person', email:'a@b.test'}
                                : ROLES.map(function(r){ return {role:r}; });
      var q={ select:function(){return q;}, eq:function(){return q;},
              maybeSingle:function(){return Promise.resolve({data:rows,error:null});},
              then:function(f){return Promise.resolve({data:rows,error:null}).then(f);} };
      return q;
    },
    rpc:function(name,args){
      window.__calls.push({name:name,args:args});
      if (name==='madrasah_pupil_one') {
        if (ERR) return Promise.resolve({data:null,error:{message:ERR}});
        return Promise.resolve({data:PUPIL,error:null});
      }
      if (name==='save_madrasah_pupil_details')
        return Promise.resolve({data:PUPIL,error:null});
      return Promise.resolve({data:null,error:{message:'unstubbed '+name}});
    }
  };
  Object.defineProperty(window,'supabase',
    {value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % (json.dumps(roles), json.dumps(pupil if pupil is not None else PUPIL),
       json.dumps(error))


def open_page(b, pid="p1", roles=("admin",), pupil=None, error=None,
              width=1500, height=1100):
    pg = b.new_page(viewport={"width": width, "height": height})
    pg.set_default_timeout(7000)
    pg.add_init_script(stub(list(roles), pupil, error))
    q = ("?id=" + pid) if pid is not None else ""
    pg.goto(BASE + "/portal/pupil/" + q, wait_until="load")
    pg.wait_for_timeout(700)
    return pg


def run():
    with sync_playwright() as p:
        b = p.chromium.launch()

        # --- who may see it ----------------------------------------------------
        pg = open_page(b, roles=())
        check("an account with no roles is refused the record",
              pg.locator("#pp-body").is_hidden())
        check("and is told so rather than shown an empty page",
              pg.locator("#app-noaccess").is_visible())
        calls = pg.evaluate("() => window.__calls.map(function(c){return c.name;})")
        check("and NO audit row is written for somebody who was refused",
              "madrasah_pupil_one" not in calls, calls)
        pg.close()

        # --- the page ----------------------------------------------------------
        pg = open_page(b)
        check("a madrasah account sees the record", pg.locator("#pp-body").is_visible())
        check("the child's name is the heading",
              "Aaliyah Testerson" in pg.inner_text("#pp-head"))

        #  THE TITLE MUST NOT CARRY THE NAME.
        #  Browser history on a shared office computer is a list of who was
        #  looked at, and the title is what history keeps.
        title = pg.title()
        check("the page title carries NO child's name", "Aaliyah" not in title, title)
        check("and says what the page is", "Pupil" in title, title)

        # --- the audit ---------------------------------------------------------
        calls = pg.evaluate("() => window.__calls.map(function(c){return c.name;})")
        n_one = len([c for c in calls if c == "madrasah_pupil_one"])
        check("opening the page reads the pupil exactly once", n_one == 1, calls)
        args = pg.evaluate("""() => (window.__calls.filter(
            c => c.name === 'madrasah_pupil_one')[0] || {}).args""")
        check("and asks for the child named in the address",
              (args or {}).get("p_id") == "p1", args)

        # --- safety information is not behind a tab ----------------------------
        check("the allergy is on screen the MOMENT the page opens, not two "
              "clicks in",
              SECRET_ALLERGY in pg.inner_text("#pp-med"))
        check("and so is the medical note",
              SECRET_MEDICAL in pg.inner_text("#pp-med"))
        check("the details tab is the one showing",
              "Clarendon Primary" in pg.inner_text("#pp-panel"))

        # --- the tabs ----------------------------------------------------------
        check("there are tabs", pg.locator(".pp-tab").count() == 5,
              pg.locator(".pp-tab").count())
        pg.click('.pp-tab[data-tab="family"]')
        pg.wait_for_timeout(250)
        check("the family tab shows who to ring",
              "07000000000" in pg.inner_text("#pp-panel"))
        check("and the brother is a LINK to his own page, not a button",
              pg.locator('#pp-panel a.pp-mini[href*="p2"]').count() == 1)
        check("the allergy is STILL on screen on another tab",
              SECRET_ALLERGY in pg.inner_text("#pp-med"))

        pg.click('.pp-tab[data-tab="classes"]')
        pg.wait_for_timeout(250)
        check("the classes tab names the class and the teacher",
              "Girls Class 6" in pg.inner_text("#pp-panel")
              and "Apa Somebody" in pg.inner_text("#pp-panel"))
        pg.click('.pp-tab[data-tab="fees"]')
        pg.wait_for_timeout(250)
        check("the fees tab says plainly that no rate is set",
              "cannot be charged" in pg.inner_text("#pp-panel").lower())
        pg.click('.pp-tab[data-tab="notes"]')
        pg.wait_for_timeout(250)
        check("the notes tab shows the office note",
              "Collected by an aunt" in pg.inner_text("#pp-panel"))

        #  ONE AUDIT ROW PER PUPIL, NOT ONE PER TAB. Opening the child is the
        #  auditable act; the tabs arrange what was already fetched. Five tabs
        #  writing five rows would make the audit trail useless for answering
        #  "who read this child's record".
        calls = pg.evaluate("() => window.__calls.map(function(c){return c.name;})")
        n_one = len([c for c in calls if c == "madrasah_pupil_one"])
        check("after four tab changes it is STILL one audit read, not five",
              n_one == 1, n_one)
        pg.close()

        # --- a child with nothing recorded -------------------------------------
        pg = open_page(b, pid="p2", pupil=PLAIN)
        check("a child with no medical note shows no red box",
              pg.locator("#pp-med").is_hidden())
        pg.click('.pp-tab[data-tab="family"]')
        pg.wait_for_timeout(250)
        check("a child with no family is called out in words, not left blank",
              "no one to call" in pg.inner_text("#pp-panel").lower(),
              pg.inner_text("#pp-panel")[:120])
        pg.click('.pp-tab[data-tab="classes"]')
        pg.wait_for_timeout(250)
        check("and so is a child in no class",
              "no class" in pg.inner_text("#pp-panel").lower())
        pg.close()

        # --- amending ----------------------------------------------------------
        pg = open_page(b)
        pg.click("#pp-edit")
        pg.wait_for_timeout(300)
        check("the amend form opens", pg.locator("#pp-editor").is_visible())
        check("it says that clearing a box removes what was there",
              "removes what was there" in pg.inner_text("#pp-editor").lower())
        pg.fill("#pf-school", "A New School")
        pg.click("#pp-save")
        pg.wait_for_timeout(500)
        saved = pg.evaluate("""() => (window.__calls.filter(
            c => c.name === 'save_madrasah_pupil_details').slice(-1)[0] || {}).args""")
        check("saving sends the change", bool(saved), saved)
        check("and sends it for the right child",
              (saved or {}).get("p_id") == "p1", saved)
        check("an emptied box is sent as null, which means remove it",
              (saved or {}).get("p_patch", {}).get("prev_madrasah") is None, saved)
        pg.close()

        # --- when things are wrong ---------------------------------------------
        pg = open_page(b, pid=None)
        check("no id in the address is explained, not left blank",
              pg.locator("#pp-error").is_visible())
        check("and the error says what to do",
              "roll" in pg.inner_text("#pp-error").lower())
        pg.close()

        pg = open_page(b, error="permission denied")
        check("a refusal from the database is shown to the person",
              pg.locator("#pp-error").is_visible())
        check("and no child's details are on screen",
              SECRET_ALLERGY not in pg.content())
        pg.close()

        # --- the phone ---------------------------------------------------------
        pg = open_page(b, width=390, height=900)
        wide = pg.evaluate("""() => ({doc: document.documentElement.scrollWidth,
                                      win: window.innerWidth})""")
        check("the record does not scroll sideways on a phone",
              wide["doc"] <= wide["win"] + 1, wide)
        check("the allergy is above the fold on a phone too",
              pg.evaluate("""() => document.getElementById('pp-med')
                  .getBoundingClientRect().bottom""") < 900)
        pg.close()

        b.close()
    FINISHED[0] = True


if __name__ == "__main__":
    run()
