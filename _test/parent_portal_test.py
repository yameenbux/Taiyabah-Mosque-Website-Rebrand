"""The parents' portal - My children, Attendance, Report an absence.

WHAT THIS SUITE IS FOR

db/119-124 prove what lives in Postgres, in rolled-back transactions: that a
parent sees only their own household's children, that record_parent_absence()
refuses another household's pupil id before it looks at anything else, that a
parent cannot overwrite a mark the madrasah made or touch a register that has
been handed in, and that every one of the register's old rules still holds.

This proves the half SQL cannot see, and it asserts what the screens SAY, not
that an element exists:

  * that a parent's rail names five screens, none of them "soon" (Progress came
    off on 29 September, db/127), and NOTHING that belongs to staff - not Fees,
    not Pupils, not even greyed out - and that a "soon" row, if one is ever
    added, is a span with no href, not a link;
  * that the register not being kept reads as "NOTHING HAS BEEN MARKED, and
    that is not a clean record", not as an empty table under "Attendance";
  * that a child's card shows medical, allergies, address and the teacher's
    name in words, says "Nothing recorded" where it is, and cannot be edited -
    the way to correct it is a message, and until messaging exists the page
    says so rather than linking to a page that is not there;
  * that the absence form offers only evenings the server offered, draws the
    ones it will not take as locked with the reason beside them, and turns
    "away, with a reason" into 'excused' without asking a parent to know that;
  * that a refusal is shown in the database's own words, and a technical error
    is NEVER shown;
  * that no request ever names a pupil the login does not own;
  * that no second factor is asked of a parent, and that the password gate
    tells a parent to ring the office;
  * that the generated screens are what the generator makes NOW (nobody
    hand-edited them) and parse as ES5.

WHAT IT CANNOT PROVE. The stub answers as db/124's functions do (shapes read
off the live functions on 29 September, listed below) and refuses in the words
db/124 uses. It is not the database. HTTP sign-in against the real auth
service has not been run from here; that is the first thing to do on a real
phone.

    python3 _test/parent_portal_test.py
"""
import atexit
import copy
import http.server
import json
import os
import re
import shutil
import socketserver
import subprocess
import sys
import threading

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))


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
FINISHED = [False]


def report():
    if FAILURES:
        print("\n%d FAILURE(S) out of %d checks:" % (len(FAILURES), CHECKS[0]))
        for f in FAILURES:
            print("  - " + f)
    elif not FINISHED[0]:
        print("\nRUN INCOMPLETE - %d checks ran and the suite never reached "
              "its end. Do not read this as a pass." % CHECKS[0])
    else:
        print("\nALL PASS - %d checks" % CHECKS[0])


atexit.register(report)


def check(name, ok, got=None):
    CHECKS[0] += 1
    if not ok:
        FAILURES.append(name + ("" if got is None else ": %s" % (got,)))


# ---------------------------------------------------------------------------
# WHAT THE LIVE FUNCTIONS RETURN. Key sets read from production on
# 29 September 2026 (keys only, never values) by calling each function as the
# test parent. A fixture with a different shape is a test of something else.
# ---------------------------------------------------------------------------
LIVE_KEYS = {
    "family": "children,family_reference,guardians",
    "child": "address,allergies,classes,date_of_birth,ehcp_detail,email,"
             "first_name,gender,joined_on,last_name,medical,postcode,"
             "previous_madrasah,pupil_id,school,school_year,send_detail,"
             "status,walk_home_consent",
    "class": "active,name,section,teacher",
    "guardian": "email,full_name,is_me,is_primary,phone",
    "att": "first_name,marks,opened_on,permitted,today",
    "opt": "evenings,first_name,opened_on,permitted,today,why",
}

# NO REAL CHILD, FAMILY, CLASS OR TEACHER APPEARS IN THIS FILE.
TODAY = "2026-09-29"          # a Tuesday; the server says what today is
OFFICE = "01204 535 997"

SECRET_NOTE = "ZZ-INTERNAL-OFFICE-NOTE"
SECRET_LEGACY = "ZZ-LEGACY-REF-77"

KID1 = {
    "pupil_id": "p-one", "first_name": "Aaliyah", "last_name": "Testwood",
    "status": "on_roll", "joined_on": "2024-09-09", "date_of_birth": "2016-03-14",
    "gender": "female", "school": "Fairbrook Primary", "school_year": "Year 4",
    "previous_madrasah": None,
    "medical": "Asthma; blue inhaler kept in her school bag",
    "allergies": "Peanuts",
    "send_detail": None, "ehcp_detail": None, "walk_home_consent": False,
    "address": "14 Example Road, Boltonshire", "postcode": "ZZ1 2AB",
    "email": None,
    "classes": [{"name": "Year 4 Girls", "section": "girls", "active": True,
                 "teacher": "Ustadha Nasserly"}],
    # Fields the server never sends. The screen is handed them anyway, in the
    # tests below, to prove it shows only what it names.
}
KID2 = {
    "pupil_id": "p-two", "first_name": "Bilal", "last_name": "Testwood",
    "status": "on_roll", "joined_on": "2025-09-08", "date_of_birth": "2018-11-02",
    "gender": "male", "school": None, "school_year": None,
    "previous_madrasah": "Almondine Madrasah",
    "medical": None, "allergies": "  ",
    "send_detail": "Dyslexia; needs printed text in a larger font",
    "ehcp_detail": None, "walk_home_consent": True,
    "address": "14 Example Road, Boltonshire", "postcode": "ZZ1 2AB",
    "email": "bilal.example@example.test",
    "classes": [{"name": "Year 2 Boys", "section": "boys", "active": True,
                 "teacher": None}],
}
FAMILY = {
    "family_reference": "MF-900001",
    "children": [KID1, KID2],
    "guardians": [
        {"full_name": "Parent Testwood", "phone": "07000 000001",
         "email": "parent.testwood@example.test", "is_primary": True, "is_me": True},
        {"full_name": "Other Testwood", "phone": None, "email": None,
         "is_primary": False, "is_me": False},
    ],
}
ONE_KID_FAMILY = dict(FAMILY, children=[KID1])


def att(first, permitted, opened_on, marks):
    return {"first_name": first, "permitted": permitted, "opened_on": opened_on,
            "today": TODAY, "marks": marks}


def opts(first, evenings, why=None, permitted=True, opened="2026-09-21"):
    return {"first_name": first, "permitted": permitted, "opened_on": opened,
            "today": TODAY, "evenings": evenings, "why": why}


def ev(d, mark=None, reason=None, source=None, by_me=False, can=True):
    return {"on_date": d, "existing_mark": mark, "existing_reason": reason,
            "existing_source": source, "existing_by_me": by_me, "can_change": can}


MARKS = [
    {"on_date": "2026-09-28", "mark": "excused", "reason": "Unwell, mother rang",
     "source": "parent", "by_me": True, "class": "Year 4 Girls"},
    {"on_date": "2026-09-25", "mark": "late", "reason": None,
     "source": "madrasah", "by_me": False, "class": "Year 4 Girls"},
    {"on_date": "2026-09-24", "mark": "present", "reason": None,
     "source": "madrasah", "by_me": False, "class": "Year 4 Girls"},
    {"on_date": "2026-09-23", "mark": "absent", "reason": None,
     "source": "parent", "by_me": False, "class": "Year 4 Girls"},
]
OPEN_EVENINGS = [
    ev(TODAY),
    ev("2026-09-28", "excused", "unwell", "parent", True),
    ev("2026-09-25", "present", None, "madrasah", False, False),
    ev("2026-09-24", "absent", None, "parent", False, False),
    ev("2026-09-23"),
]

EV_TODAY = 'input[name="pb-ev"][value="%s"]' % TODAY
EV_23 = 'input[name="pb-ev"][value="2026-09-23"]'

MSG_NOT_YOURS = "not yours"
MSG_FUTURE = ("You can tell us about tonight, or an evening in the last "
              "fortnight - not one that has not happened yet. To let us know "
              "about a later evening, please ring the office.")
MSG_RECORDED = ("The madrasah has already recorded that evening. If that is "
                "not right, please ring the office.")
INTERNAL = "relation \"madrasah_secret_thing\" does not exist"


def stub(fixture):
    return """
(function(){
  var F=%s;
  window.__calls=[]; window.__auth=[]; window.__tables=[];
  var signedIn=!!F.session;
  var USER={id:'u-parent',email:'parent.testwood@example.test'};
  var STATE=JSON.parse(JSON.stringify({opts:F.opts||{}}));
  var client={
    auth:{
      getSession:function(){ return Promise.resolve({data:{session:signedIn?{access_token:'t',user:USER}:null}}); },
      getUser:function(){ return Promise.resolve({data:{user:signedIn?USER:null}}); },
      signInWithPassword:function(){ window.__auth.push('signIn'); signedIn=true;
        return Promise.resolve({data:{user:USER},error:null}); },
      signOut:function(){ signedIn=false; return Promise.resolve({}); },
      onAuthStateChange:function(){ return {data:{subscription:{unsubscribe:function(){}}}}; },
      mfa:{
        getAuthenticatorAssuranceLevel:function(){ window.__auth.push('mfa'); return Promise.resolve({data:{currentLevel:'aal1',nextLevel:'aal1'},error:null}); },
        listFactors:function(){ window.__auth.push('mfa'); return Promise.resolve({data:{totp:[]},error:null}); },
        enroll:function(){ window.__auth.push('mfa'); return Promise.resolve({error:{message:'no'}}); },
        challenge:function(){ window.__auth.push('mfa'); return Promise.resolve({error:{message:'no'}}); }
      }
    },
    from:function(t){
      window.__tables.push(t);
      var rows = t==='profiles' ? F.profile : [];
      var q={ select:function(){return q;}, eq:function(){return q;},
              maybeSingle:function(){return Promise.resolve({data:rows,error:null});},
              then:function(f){return Promise.resolve({data:rows,error:null}).then(f);} };
      return q;
    },
    rpc:function(name,args){
      window.__calls.push({name:name,args:JSON.parse(JSON.stringify(args||{}))});
      var E=(F.errors||{})[name];
      if (E) return Promise.resolve({data:null,error:E});
      if (name==='parent_my_children') return Promise.resolve({data:F.family,error:null});
      if (name==='parent_attendance') return Promise.resolve({data:F.att[args.p_pupil],error:null});
      if (name==='parent_absence_options') return Promise.resolve({data:STATE.opts[args.p_pupil],error:null});
      if (name==='record_parent_absence') {
        var o=STATE.opts[args.p_pupil], e=null, i;
        for (i=0;i<((o&&o.evenings)||[]).length;i++) if (o.evenings[i].on_date===args.p_date) e=o.evenings[i];
        if (!e) return Promise.resolve({data:null,error:{code:'22023',message:F.msg_future}});
        if (!e.can_change) return Promise.resolve({data:null,error:{code:'22023',message:F.msg_recorded}});
        e.existing_mark=args.p_mark; e.existing_reason=args.p_reason; e.existing_source='parent'; e.existing_by_me=true;
        return Promise.resolve({data:{recorded:true},error:null});
      }
      return Promise.resolve({data:null,error:{code:'42883',message:'unstubbed '+name}});
    }
  };
  Object.defineProperty(window,'supabase',
    {value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % json.dumps(fixture)


def fx(**over):
    base = {
        "session": True,
        "profile": {"full_name": "Parent Testwood", "email": "x@example.test",
                    "must_change_password": False},
        "family": FAMILY,
        "att": {"p-one": att("Aaliyah", True, "2026-09-21", MARKS),
                "p-two": att("Bilal", True, "2026-09-21", [])},
        "opts": {"p-one": opts("Aaliyah", OPEN_EVENINGS),
                 "p-two": opts("Bilal", [ev(TODAY), ev("2026-09-28")])},
        "errors": {},
        "msg_future": MSG_FUTURE, "msg_recorded": MSG_RECORDED,
    }
    base.update(over)
    return base


def open_page(browser, path, fixture, width=1280, height=900):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.add_init_script(stub(fixture))
    pg.goto(BASE + path, wait_until="networkidle")
    pg.wait_for_timeout(450)
    return pg


def calls(pg, name):
    return [c for c in pg.evaluate("() => window.__calls") if c["name"] == name]


def text(pg, sel):
    return pg.inner_text(sel)


def rail_names(pg):
    return pg.evaluate("""() => Array.prototype.map.call(
        document.querySelectorAll('.ashell .area'),
        function (n) { return n.textContent.replace(/\\s+/g, ' ').trim(); })""")


def run():
    # ============ THE FIXTURES ARE THE LIVE SHAPES ============
    check("fixture: the family has exactly the keys the live function returns",
          ",".join(sorted(FAMILY)) == LIVE_KEYS["family"], sorted(FAMILY))
    check("fixture: a child has exactly the live keys",
          ",".join(sorted(KID1)) == LIVE_KEYS["child"], sorted(KID1))
    check("fixture: a class has exactly the live keys",
          ",".join(sorted(KID1["classes"][0])) == LIVE_KEYS["class"])
    check("fixture: a guardian has exactly the live keys",
          ",".join(sorted(FAMILY["guardians"][0])) == LIVE_KEYS["guardian"])
    check("fixture: attendance has exactly the live keys",
          ",".join(sorted(att("A", True, None, []))) == LIVE_KEYS["att"])
    check("fixture: absence options have exactly the live keys",
          ",".join(sorted(opts("A", []))) == LIVE_KEYS["opt"])

    # ============ THE GENERATED FILES ARE WHAT THE GENERATOR MAKES ============
    import screen_builder as SB
    import build_parent_screens as BP
    for scr in BP.SCREENS:
        html = SB.build_html(scr)
        js = SB.build_js(scr)
        live_h = open(os.path.join(scr.out, "index.html"), encoding="utf-8").read()
        live_j = open(os.path.join(scr.out, "app.js"), encoding="utf-8").read()
        check("portal/%s/index.html is what the generator makes now (nobody "
              "hand-edited it)" % scr.folder, html == live_h)
        check("portal/%s/app.js is what the generator makes now" % scr.folder,
              js == live_j)
        check("portal/%s/app.js has no MadrasahNav in it - the parent rail "
              "cannot be handed the staff list" % scr.folder,
              "MadrasahNav" not in live_j)
        check("portal/%s/app.js never asks user_roles what a parent may do"
              % scr.folder, 'from("user_roles")' not in live_j)
        check("portal/%s never loads the staff nav script" % scr.folder,
              not re.search(r'src="(\.\./)+nav\.js"', live_h)
              or re.search(r'src="(\.\./)*nav\.js"', live_h)
              and "portal/nav.js" not in live_h)
    ok_pupils = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "screen_builder.py"),
                                "--verify-pupils"], capture_output=True, text=True)
    check("the shared generator still reproduces the Pupils screen "
          "byte-for-byte", ok_pupils.returncode == 0, ok_pupils.stdout[-200:])

    # ============ ES5 ============
    files = ["portal/parent/nav.js", "portal/parent/app.js",
             "portal/parent/attendance/app.js", "portal/parent/absence/app.js",
             "portal/parent/messages/app.js", "portal/parent/progress/app.js",
             "tools/parent_common.js", "tools/parent_children_module.js",
             "tools/parent_attendance_module.js", "tools/parent_absence_module.js",
             "tools/parent_messages_module.js", "tools/parent_progress_module.js"]
    acorn = shutil.which("acorn")
    for f in files:
        if acorn:
            r = subprocess.run([acorn, "--ecma5", "--silent", os.path.join(ROOT, f)],
                               capture_output=True, text=True)
            check("%s parses as ES5" % f, r.returncode == 0,
                  (r.stderr or "").strip()[:160])
        else:
            src = re.sub(r"/\*.*?\*/", "", open(os.path.join(ROOT, f), encoding="utf-8").read(), flags=re.S)
            bad = [p for p in (r"=>", r"`", r"(?<![\w.$])const\s", r"(?<![\w.$])let\s")
                   if re.search(p, src)]
            check("%s has no ES6 constructs (acorn not installed; line scan)" % f, not bad, bad)
    css = open(os.path.join(ROOT, "portal/parent/parent.css"), encoding="utf-8").read()
    first_rule = re.sub(r"/\*.*?\*/", "", css, flags=re.S).strip().splitlines()[0]
    check("parent.css opens with [hidden] { display: none !important; }",
          first_rule.replace(" ", "") == "[hidden]{display:none!important;}", first_rule)

    with sync_playwright() as p:
        browser = p.chromium.launch()

        # ============ THE RAIL ============
        pg = open_page(browser, "/portal/parent/", fx())
        names = rail_names(pg)
        joined = " | ".join(names)

        #  THE HEADING ABOVE THE ROWS, AND WHY IT IS ASSERTED BY ITS EXACT
        #  WORDS. A parent does not arrive through the Admin Centre the way
        #  staff do — they come from a letter or a text with a link in it, so
        #  the first thing they read has to say what this is. It said
        #  "Parents" until the masjid looked at the live rail on 29 September
        #  and asked for "Parents portal".
        #
        #  This check exists because the whole suite passed either way. The
        #  same week, ten pages quietly went back to crediting the wrong
        #  company and nothing noticed that either. A word a person reads is
        #  worth asserting by its exact spelling; "the heading is not empty"
        #  would have passed through both.
        head = pg.evaluate(
            """() => { var n = document.querySelector('.ashell-top strong');
                       return n ? n.textContent.trim() : null; }""")
        check("the parent rail is headed 'Parents portal', not 'Parents'",
              head == "Parents portal", repr(head))
        check("the rail has exactly five rows",
              len(names) == 5, joined)
        for n in ("My children", "Attendance", "Report an absence"):
            check("the rail offers '%s'" % n,
                  any(x.startswith(n) for x in names), joined)
        check("'Progress' is on the rail and is NOT tagged soon (slice 3 built it)",
              any(x.startswith("Progress") and not x.endswith("soon") for x in names), joined)
        check("'Messages' is on the rail and is NOT tagged soon (slice 4 built it)",
              any(x.startswith("Messages") and not x.endswith("soon") for x in names), joined)
        for staff in ("Pupils", "Families", "Classes", "Staff", "Fees", "Register",
                      "Admissions", "Today", "Homework", "Safeguarding",
                      "Admin Centre", "Gift Aid", "Hall"):
            check("a parent's rail never shows '%s', not even greyed out" % staff,
                  staff.lower() not in joined.lower(), joined)
        soon = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('.ashell .area.soon'),
            function (n) { return [n.tagName, n.getAttribute('href'), n.getAttribute('tabindex')]; })""")
        check("no row on a parent's rail is soon any more, and any that is added must be "
              "a span with no href and no focus stop",
              len(soon) == 0 and all(s[0] == "SPAN" and s[1] is None and s[2] is None
                                     for s in soon), soon)
        hrefs = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('.ashell a.area'),
            function (n) { return n.getAttribute('href'); })""")
        check("the five live rows go to the parent screens, from two folders down",
              hrefs == ["../../portal/parent/", "../../portal/parent/attendance/",
                        "../../portal/parent/progress/",
                        "../../portal/parent/absence/",
                        "../../portal/parent/messages/"], hrefs)
        here = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('.ashell a.area[aria-current="page"]'),
            function (n) { return n.textContent.replace(/\\s+/g, ' ').trim(); })""")
        check("the rail says which screen you are on",
              len(here) == 1 and here[0].startswith("My children"), here)
        check("no link anywhere on the page reaches a staff area",
              pg.evaluate("""() => Array.prototype.filter.call(document.querySelectorAll('a[href]'),
                  function (a) { return /portal\\/(pupils|families|classes|staff|fees|register|admissions|notices|calendar|people|archive|profile)\\//.test(a.getAttribute('href')); }).length""") == 0)
        check("the staff rail's list never loaded on a parent page",
              pg.evaluate("() => typeof window.MadrasahNav") == "undefined")
        check("the heading says My children",
              "My children" in text(pg, "h1"), text(pg, "h1"))
        check("no second factor was asked of a parent",
              "mfa" not in pg.evaluate("() => window.__auth"))
        check("and user_roles was never queried - a parent has none, by design",
              "user_roles" not in pg.evaluate("() => window.__tables"))
        check("the logo goes to the website, not the Admin Centre",
              (pg.get_attribute(".ashell-top a", "href") or "").endswith("index.html")
              and "portals" not in (pg.get_attribute(".ashell-top a", "href") or ""))
        pg.close()

        # ============ MY CHILDREN ============
        pg = open_page(browser, "/portal/parent/", fx())
        panel = text(pg, "#pk-panel")
        check("both children have a card", pg.locator(".pt-card").count() == 2)
        c1 = text(pg, ".pt-card >> nth=0")
        c2 = text(pg, ".pt-card >> nth=1")
        check("the card names the child", "Aaliyah Testwood" in c1, c1[:80])
        check("it says the class and the teacher's name in a sentence",
              "In Year 4 Girls, taught by Ustadha Nasserly" in c1, c1[:200])
        check("a class with no teacher set says the class and does not invent one",
              "In Year 2 Boys" in c2 and "taught by" not in c2, c2[:200])
        check("the medical detail is shown in words",
              "Asthma; blue inhaler kept in her school bag" in c1)
        check("the allergy is shown", "Peanuts" in c1)
        check("the address and postcode are shown",
              "14 Example Road, Boltonshire" in c1 and "ZZ1 2AB" in c1)
        check("the date of birth is written for a person, not a machine",
              "14 March 2016" in c1, c1[:400])
        check("day school and year are shown", "Fairbrook Primary, Year 4" in c1)
        check("'walking home' is said in words",
              "No, must be collected" in c1 and "Yes, may walk home on their own" in c2)
        check("nothing recorded is SAID: medical",
              re.search(r"Medical\s+Nothing recorded", c2) is not None, c2)
        check("nothing recorded is SAID: allergies, even when the field is blank spaces",
              re.search(r"Allergies\s+Nothing recorded", c2) is not None, c2)
        check("SEND detail appears where there is some",
              "Dyslexia" in c2 and "Special educational needs" in c2)
        check("and no SEND row is drawn where there is none",
              "Special educational needs" not in c1)
        check("no EHCP row where there is none",
              "care plan" not in c1.lower() and "care plan" not in c2.lower())
        check("a previous madrasah is shown where it is recorded",
              "Almondine Madrasah" in c2)
        check("the family reference is shown", "MF-900001" in panel)
        check("guardians are listed, with 'you' against this login",
              "Parent Testwood" in text(pg, "#pk-people")
              and pg.locator("#pk-people .pt-chip", has_text="you").count() == 1)
        check("a guardian with no phone number says so",
              "No phone number" in text(pg, "#pk-people"))
        # THE WAY TO CORRECT IT IS A MESSAGE, NOT A FORM.
        check("nothing on this screen is editable: no form, input or textarea",
              pg.locator("#pk-panel form, #pk-panel input, #pk-panel textarea, "
                         "#pk-panel select").count() == 0)
        h = text(pg, "#pk-help")
        check("it says what to do about a wrong detail",
              "Something wrong or out of date" in h and "Tell us" in h, h[:200])
        check("it says WHY it is not editable", "who changed it" in h, h)
        check("messaging exists now, so it no longer says 'coming soon'",
              "coming soon" not in h.lower(), h)
        check("'tell us' is a real link to the messages screen, opened on the "
              "details title",
              pg.locator('#pk-help a[href="messages/#details"]').count() == 1
              and "Message the office about this" in h, h)
        check("the page admits the madrasah's own notes are kept back, and how "
              "to ask for them",
              "not shown on this page" in h and "full copy" in h, h)
        # whatever else the server might send is not drawn
        leaky = copy.deepcopy(FAMILY)
        leaky["children"][0]["notes"] = SECRET_NOTE
        leaky["children"][0]["legacy_ref"] = SECRET_LEGACY
        leaky["children"][0]["fee_rate_id"] = "rate-zz"
        leaky["note"] = SECRET_NOTE
        pg2 = open_page(browser, "/portal/parent/", fx(family=leaky))
        body = text(pg2, "body")
        check("a field the screen does not name is never drawn: office note, "
              "legacy ref, fee rate, household note",
              SECRET_NOTE not in body and SECRET_LEGACY not in body
              and "rate-zz" not in body)
        pg2.close()
        pg.close()

        # who is this login
        pg = open_page(browser, "/portal/parent/",
                       fx(errors={"parent_my_children": {"code": "42501", "message": MSG_NOT_YOURS}}))
        e = text(pg, "#pk-error")
        check("a login that is not a parent's is told so, and to ring or sign in elsewhere",
              "not set up as a parent's" in e and "madrasah portal" in e and OFFICE in e, e)
        check("and no card is drawn", pg.locator(".pt-card").count() == 0)
        pg.close()

        pg = open_page(browser, "/portal/parent/", fx(errors={"parent_my_children": {"message": "Failed to fetch"}}))
        e = text(pg, "#pk-error")
        check("a network failure says we could not reach the madrasah, and to try again",
              "could not reach the madrasah" in e and "try again" in e, e)
        pg.close()

        pg = open_page(browser, "/portal/parent/", fx(errors={"parent_my_children": {"code": "42883", "message": INTERNAL}}))
        e = text(pg, "#pk-error")
        check("a technical error is NEVER shown to a parent",
              "madrasah_secret_thing" not in text(pg, "body") and "Something went wrong" in e, e)
        pg.close()

        pg = open_page(browser, "/portal/parent/", fx(family={"family_reference": "MF-900002", "children": [], "guardians": []}))
        check("a login with no children says so and gives the number",
              "no children on this login" in text(pg, "#pk-error") and OFFICE in text(pg, "#pk-error"))
        pg.close()

        # ============ ATTENDANCE ============
        pg = open_page(browser, "/portal/parent/attendance/", fx())
        check("both children have a section", pg.locator(".pt-card").count() == 2)
        a1 = text(pg, ".pt-card >> nth=0")
        check("the child's marks are a table, newest first",
              a1.index("28 September") < a1.index("25 September")
              < a1.index("24 September") < a1.index("23 September"), a1)
        check("the date is written as a day and a date",
              "Monday 28 September" in a1 and "Friday 25 September" in a1, a1)
        check("an absence with a reason is said as absent, with a reason",
              "Absent, with a reason" in a1 and "Unwell, mother rang" in a1, a1)
        rows = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('.pt-card:first-child .pt-table tbody tr'),
            function (r) { return Array.prototype.map.call(r.children,
                function (c) { return c.innerText.replace(/\\s+/g, ' ').trim(); }); })""")
        check("that report is shown as made by 'You'",
              rows[0][1] == "Absent, with a reason" and rows[0][2] == "Unwell, mother rang"
              and rows[0][3] == "You", rows[0])
        check("the madrasah's own marks say The madrasah",
              rows[1][3] == "The madrasah" and rows[2][3] == "The madrasah", rows)
        check("a report from another login in the household is 'Your household', "
              "not 'You'", rows[3][3] == "Your household" and rows[3][1] == "Absent", rows[3])
        check("a late mark says Late, and no reason is shown as a dash, not blank",
              rows[1][1] == "Late" and rows[1][2] == "\u2014", rows[1])
        check("the tally counts what is there",
              "1 present" in a1 and "1 late" in a1 and "2 absent" in a1, a1)
        check("the second child, with no marks yet but the register open, is told "
              "when it opened",
              "No evenings marked yet" in text(pg, ".pt-card >> nth=1")
              and "21 September 2026" in text(pg, ".pt-card >> nth=1"),
              text(pg, ".pt-card >> nth=1"))
        check("attendance is asked for each child by that child's own id, and no other",
              sorted(c["args"]["p_pupil"] for c in calls(pg, "parent_attendance"))
              == ["p-one", "p-two"])
        pg.close()

        # THE HARD CASE: the register is not being kept.
        shut = fx(att={"p-one": att("Aaliyah", False, None, []),
                       "p-two": att("Bilal", False, None, [])})
        pg = open_page(browser, "/portal/parent/attendance/", shut)
        s = text(pg, ".pt-card >> nth=0")
        check("with the register not kept, it says NOTHING HAS BEEN MARKED",
              "Nothing has been marked for Aaliyah yet" in s, s)
        check("and says that is not the same as a clean record",
              "not the same as a clean record" in s, s)
        check("and draws no table, so there is no empty grid to read as perfect",
              pg.locator(".pt-table").count() == 0)
        check("and the footnote about marks is not shown when there are none",
              pg.locator("#pa-fine").is_hidden())
        check("and shows no '0 present' tally to read as a score",
              "present" not in s.lower().replace("marked present", ""), s)
        pg.close()

        paused = fx(att={"p-one": att("Aaliyah", False, "2026-09-21", MARKS[:2]),
                         "p-two": att("Bilal", False, None, [])})
        pg = open_page(browser, "/portal/parent/attendance/", paused)
        s = text(pg, ".pt-card >> nth=0")
        check("a register paused after opening still shows what was recorded",
              pg.locator(".pt-table").count() == 1 and "Unwell, mother rang" in s)
        check("and says it is not being kept at the moment",
              "not being kept at the moment" in s, s)
        pg.close()

        pg = open_page(browser, "/portal/parent/attendance/",
                       fx(errors={"parent_attendance": {"code": "42501", "message": MSG_NOT_YOURS}}))
        check("a login that is not a parent's is told so here too",
              "not set up as a parent's" in text(pg, "#pa-error"))
        pg.close()

        # ============ REPORT AN ABSENCE ============
        ONE = fx(family=ONE_KID_FAMILY)
        pg = open_page(browser, "/portal/parent/absence/", ONE)
        f = text(pg, "#pb-form")
        check("one child: the form opens straight to that child's evenings",
              "Aaliyah" in f and "Which evening" in f, f[:120])
        check("only the evenings the server offered are radio buttons",
              pg.locator('input[name="pb-ev"]').count() == 3,
              pg.locator('input[name="pb-ev"]').count())
        check("tonight says so", "tonight" in text(pg, ".pt-ev >> nth=0"))
        check("an evening the parent already reported says what they said, and "
              "that it can be changed",
              "You told us: Absent, with a reason (unwell)" in f and "You can change it" in f, f)
        check("an evening the madrasah recorded is LOCKED, with why, and no radio",
              "The madrasah has recorded this evening as present" in f
              and "Friday 25 September" in text(pg, ".pt-locked >> nth=0")
              and pg.locator('.pt-locked input').count() == 0, f)
        check("and says to ring if that is not right",
              "If that is not right, please ring the office" in f)
        check("an evening a parent reported but the register has closed on says "
              "only the office can change it",
              "handed in" in text(pg, ".pt-locked >> nth=1")
              and "only the office can change it" in text(pg, ".pt-locked >> nth=1"),
              text(pg, ".pt-locked >> nth=1"))
        check("it says a teacher marking present is what counts",
              "marks them present and that is what counts" in f, f)
        check("it says later evenings are by telephone, with the number",
              "later evening" in f and OFFICE in f, f)
        check("the reason is capped at the database's 500",
              pg.get_attribute("#pb-why", "maxlength") == "500")

        # Nothing chosen: refused on screen, no request sent.
        pg.click("#pb-go")
        pg.wait_for_timeout(200)
        check("pressing the button with no evening chosen says so",
              "choose which evening" in text(pg, "#pb-inline").lower(), text(pg, "#pb-inline"))
        check("and sent nothing", len(calls(pg, "record_parent_absence")) == 0)
        pg.check(EV_TODAY)
        pg.click("#pb-go")
        pg.wait_for_timeout(200)
        check("with an evening but no away/late, it asks which",
              "away or late" in text(pg, "#pb-inline"), text(pg, "#pb-inline"))
        check("and still sent nothing", len(calls(pg, "record_parent_absence")) == 0)

        # Away with a reason -> excused.
        pg.check("#pb-t-away")
        pg.fill("#pb-why", "Unwell, has a temperature")
        pg.click("#pb-go")
        pg.wait_for_timeout(300)
        sent = calls(pg, "record_parent_absence")
        check("away with a reason is sent as 'excused', for the chosen evening and "
              "this parent's own child",
              len(sent) == 1 and sent[0]["args"] == {
                  "p_pupil": "p-one", "p_date": TODAY, "p_mark": "excused",
                  "p_reason": "Unwell, has a temperature"}, sent)
        d = text(pg, "#pb-done")
        check("the confirmation says what was recorded, for whom and which evening",
              "We have recorded that Aaliyah will be away on Tuesday 29 September" in d, d)
        check("and repeats the reason back", "Unwell, has a temperature" in d)
        check("and the form is gone, so it cannot be sent twice by a second press",
              pg.locator("#pb-form").is_hidden())
        check("there is a way on: another evening, or the attendance page",
              pg.locator('#pb-done a[href="../attendance/"]').count() == 1
              and "Report another evening" in d)
        pg.click("#pb-again")
        pg.wait_for_timeout(300)
        f2 = text(pg, "#pb-form")
        check("reporting another evening reloads the options, which now show the "
              "report just made",
              "You told us: Absent, with a reason (Unwell, has a temperature)" in f2, f2)
        pg.close()

        # Away, no reason -> absent. Late -> late.
        pg = open_page(browser, "/portal/parent/absence/", ONE)
        pg.check(EV_23); pg.check("#pb-t-away"); pg.click("#pb-go"); pg.wait_for_timeout(300)
        sent = calls(pg, "record_parent_absence")
        check("away with no reason is 'absent' and the reason is null, not ''",
              len(sent) == 1 and sent[0]["args"]["p_mark"] == "absent"
              and sent[0]["args"]["p_reason"] is None
              and sent[0]["args"]["p_date"] == "2026-09-23", sent)
        pg.close()
        pg = open_page(browser, "/portal/parent/absence/", ONE)
        pg.check(EV_TODAY); pg.check("#pb-t-late"); pg.fill("#pb-why", "Bus"); pg.click("#pb-go"); pg.wait_for_timeout(300)
        sent = calls(pg, "record_parent_absence")
        check("late is 'late', with its reason",
              len(sent) == 1 and sent[0]["args"]["p_mark"] == "late"
              and sent[0]["args"]["p_reason"] == "Bus", sent)
        check("and the confirmation says late, not away",
              "will be late on" in text(pg, "#pb-done"), text(pg, "#pb-done"))
        pg.close()

        # The server refuses: its words, verbatim; the form stays.
        refuse = fx(family=ONE_KID_FAMILY,
                    errors={"record_parent_absence": {"code": "22023", "message": MSG_FUTURE}})
        pg = open_page(browser, "/portal/parent/absence/", refuse)
        pg.check(EV_TODAY); pg.check("#pb-t-away"); pg.click("#pb-go"); pg.wait_for_timeout(300)
        e = text(pg, "#pb-error")
        check("a refusal is shown in the database's own words",
              e == MSG_FUTURE, e)
        check("and no thank-you is shown", pg.locator("#pb-done").is_hidden())
        check("and the form is still there, with the button usable again",
              pg.locator("#pb-form").is_visible() and pg.locator("#pb-go").is_enabled()
              and text(pg, "#pb-go") == "Tell the madrasah")
        pg.close()

        boom = fx(family=ONE_KID_FAMILY,
                  errors={"record_parent_absence": {"code": "XX000", "message": INTERNAL}})
        pg = open_page(browser, "/portal/parent/absence/", boom)
        pg.check(EV_TODAY); pg.check("#pb-t-away"); pg.click("#pb-go"); pg.wait_for_timeout(300)
        check("a technical failure is NEVER shown; the parent is told to try again "
              "or ring",
              "madrasah_secret_thing" not in text(pg, "body")
              and "Something went wrong" in text(pg, "#pb-error")
              and OFFICE in text(pg, "#pb-error"), text(pg, "#pb-error"))
        pg.close()

        # The four reasons there may be nothing to offer.
        for why, want, label in (
                ("not_started", "not being kept at the moment", "register not kept"),
                ("not_on_roll", "not on the roll of a class", "child not on a roll"),
                ("no_evenings", "no madrasah evenings in the last fortnight", "no evenings")):
            fxx = fx(family=ONE_KID_FAMILY, opts={"p-one": opts("Aaliyah", [], why=why,
                                                                  permitted=(why != "not_started"))})
            pg = open_page(browser, "/portal/parent/absence/", fxx)
            t = text(pg, "#pb-form")
            check("%s: says so in a sentence" % label, want in t, t)
            check("%s: offers no form" % label, pg.locator("#pb-f").count() == 0)
            if why != "no_evenings":
                check("%s: says to ring the office, with the number" % label, OFFICE in t, t)
            pg.close()

        # Two children: the parent chooses, and nothing is offered before they do.
        pg = open_page(browser, "/portal/parent/absence/", fx())
        check("two children: asked which child first",
              "Which child" in text(pg, "#pb-pick")
              and pg.locator('input[name="pb-k"]').count() == 2)
        check("and no evening is offered, and no options were fetched, before choosing",
              pg.locator("#pb-form").is_hidden()
              and len(calls(pg, "parent_absence_options")) == 0)
        pg.check('input[name="pb-k"][value="p-two"]', force=True)
        pg.wait_for_timeout(300)
        opt = calls(pg, "parent_absence_options")
        check("choosing Bilal asks for Bilal's evenings, by Bilal's id",
              len(opt) == 1 and opt[0]["args"]["p_pupil"] == "p-two", opt)
        check("and the form is for Bilal", "Bilal" in text(pg, "#pb-form"))
        pg.check(EV_TODAY); pg.check("#pb-t-away"); pg.click("#pb-go"); pg.wait_for_timeout(300)
        sent = calls(pg, "record_parent_absence")
        check("the report goes against the child that was chosen",
              len(sent) == 1 and sent[0]["args"]["p_pupil"] == "p-two", sent)
        pg.close()

        # ============ EVERY REQUEST NAMES ONLY THIS LOGIN'S OWN CHILDREN ============
        own = {"p-one", "p-two"}
        seen = []
        for path in ("/portal/parent/attendance/", "/portal/parent/absence/", "/portal/parent/"):
            pg = open_page(browser, path, fx())
            if path.endswith("absence/"):
                pg.check('input[name="pb-k"][value="p-one"]', force=True)
                pg.wait_for_timeout(250)
                pg.check(EV_TODAY); pg.check("#pb-t-late"); pg.click("#pb-go"); pg.wait_for_timeout(250)
            for c in pg.evaluate("() => window.__calls"):
                if "p_pupil" in c["args"]:
                    seen.append(c["args"]["p_pupil"])
            pg.close()
        check("across all the screens, every pupil id sent is one of this login's own",
              len(seen) >= 4 and set(seen) <= own, seen)

        # ============ THE PASSWORD GATE ============
        pg = open_page(browser, "/portal/parent/",
                       fx(profile={"full_name": "Parent Testwood", "email": "x@example.test",
                                   "must_change_password": True}))
        gate = text(pg, "#pw-gate")
        check("a parent on their first password is stopped at the gate",
              "Choose your own password" in gate, gate[:100])
        check("the gate greets the parent by name, escaped",
              "Assalamu alaikum, Parent Testwood" in gate, gate[:160])
        check("the gate tells a parent to ring the office, with the number",
              "ring the madrasah office on " + OFFICE in gate, gate)
        check("and does not say the madrasah 'does not hold your email address'",
              "does not hold your email" not in gate)
        check("and nothing behind it was drawn: no children were fetched",
              len(calls(pg, "parent_my_children")) == 0)
        pg.close()

        # ============ SIGNING IN ============
        pg = open_page(browser, "/portal/parent/", fx(session=False))
        si = text(pg, "#view-signin")
        check("signed out, the sign-in says the madrasah office gave the details",
              "email address and password the madrasah office gave you" in si, si)
        check("and does not ask for a staff member's email",
              "holds for you" not in si)
        pg.fill("#signin-email", "parent.testwood@example.test")
        pg.fill("#signin-password", "x" * 12)
        pg.click("#signin-submit")
        pg.wait_for_timeout(600)
        check("after the password, the parent goes straight in - no authenticator step",
              pg.locator(".pt-card").count() == 2 and "mfa" not in pg.evaluate("() => window.__auth"),
              pg.evaluate("() => window.__auth"))
        pg.close()

        # ============ THE PHONE ============
        for path, needs in (("/portal/parent/", ".pt-card"),
                            ("/portal/parent/attendance/", ".pt-card"),
                            ("/portal/parent/absence/", None)):
            pg = open_page(browser, path, fx(), width=390, height=844)
            if needs is None:
                pg.check('input[name="pb-k"][value="p-one"]', force=True)
                pg.wait_for_timeout(300)
            over = pg.evaluate("() => document.documentElement.scrollWidth - window.innerWidth")
            check("%s at 390px does not scroll sideways" % path, over <= 0, over)
            pg.close()
        pg = open_page(browser, "/portal/parent/absence/", ONE, width=390, height=844)
        small = pg.evaluate("""() => Array.prototype.filter.call(
            document.querySelectorAll('.pt-ev label, .pt-seg label, #pb-go'),
            function (n) { return n.getBoundingClientRect().height < 48; }).length""")
        check("every choice and the button on the absence form is 48px tall or more, "
              "on a phone", small == 0, small)
        fs = pg.evaluate("() => parseFloat(getComputedStyle(document.querySelector('.pt-ev-d')).fontSize)")
        check("the text on it is never below 15px", fs >= 15, fs)
        pg.close()

        browser.close()
    FINISHED[0] = True


if __name__ == "__main__":
    run()
