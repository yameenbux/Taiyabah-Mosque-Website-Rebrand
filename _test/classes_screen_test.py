"""/portal/classes/ — the classes, one class, and the line around a child.

18 September 2026. Written with the screen, because this is the first part of
the system that holds records about children and the mistakes here are not the
usual kind of bug.

EVERY NAME IN THIS FILE IS INVENTED. Not one of the masjid's children appears
in the fixture, in the repository, or anywhere a test run could print them.

WHAT THIS FILE GUARDS:

  1  THE REGISTER IS NOT READ UNTIL SOMEBODY ASKS FOR IT. Headcounts arrive
     with the class list, so the screen is useful without a single child's name
     leaving the database. "Who is in it" is the one control that changes that
     and it has to stay a deliberate act, not a side effect of opening a page.

  2  EVERYTHING YOU CAN DO IS INSIDE THE CLASS. The masjid asked for this and
     was right: four buttons on every row across forty-five classes is a
     hundred and eighty controls, two of them destructive, none of them what
     you came for.

  3  A TEACHER IS NOT OFFERED WHAT THE DATABASE WOULD REFUSE.

  4  REMOVING A CLASS WITH CHILDREN IN IT SAYS HOW MANY. A confirm that reads
     the same for an empty class and a class of thirty is a confirm that
     teaches people to press Yes.

  5  THE BOUNDARY IS A REFUSAL, NOT AN EMPTY LIST. Asking for a class that is
     not yours must raise. An empty list says "there are no children in this
     class", which is a different and false statement — and it is the answer
     that would let somebody map the madrasah by trying class ids one at a time.

  6  THE PUPIL TABLE HOLDS ONLY WHAT THE ASSESSMENT COVERS. No date of birth,
     no address, no parent's number, no medical note. Those fields arrive one
     at a time because somebody "might as well", and each one raises what a
     breach costs.

  7  RETENTION IS A DELETE, NOT A REMINDER — and it must never reach a
     safeguarding record, which is kept for many years longer than a pupil one.

Nothing here reaches Supabase.

Run:  python3 _test/classes_screen_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, re, json, http.server, socketserver, threading, functools, atexit

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True

fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

@atexit.register
def _report():
    if fails:
        print("FAIL (%d)" % len(fails))
        for f in fails: print("  - " + f)
    elif _report.done: print("ALL PASS")
    else: print("DID NOT FINISH — see the traceback above.")
_report.done = False

class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass

httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PAGE = "http://127.0.0.1:%d/portal/classes/" % httpd.server_address[1]

#  INVENTED. See the note at the top of this file.
MADE_UP = ["Amina Iqbal", "Bilal Osman", "Dawud Rahman", "Esa Karim",
           "Fatima Noor", "Hana Yusuf", "Idris Salim", "Jamila Tahir"]

def cls(i, name, sect, teachers, n, active=True):
    return {"id": "c%d" % i, "name": name, "section": sect, "year_label": "2026/27",
            "is_active": active, "sort_order": i, "pupils": n,
            "teachers": [{"id": "s%d" % i, "name": t} for t in teachers]}

CLASSES = [
    cls(1, "Girls OOLA", "girls", ["Apa Nafisa Chhadat"], 12),
    cls(2, "Girls Class 3", "girls", ["Apa Noorjahan Bhaiji"], 21),
    cls(5, "Boys Year 6", "boys", ["Hafiz Muhammed Yusuf"], 17),
    cls(7, "Boys Year 10", "boys", ["Moulana Usman Darvesh"], 2),
    cls(9, "Play and Pray 1 - 26/27", "mixed", ["Apa Fatima Omarji"], 9),
    cls(11, "Girls Class 9", "girls", [], 0),
    cls(12, "Boys Year 11 (2025/26)", "boys", ["Moulana Irfan Ahmed"], 0, False),
]
ROLL = [{"id": "p%d" % i, "name": n, "first_name": n.split()[0],
         "last_name": n.split()[1], "joined_on": None, "left_on": None}
        for i, n in enumerate(MADE_UP)]


def stub(roles, classes=None):
    return """
(function(){
  var ROLES=%s, CLASSES=%s, ROLL=%s;
  window.__rpc=[];
  var client={
    auth:{getSession:function(){return Promise.resolve({data:{session:{access_token:'t',user:{id:'u1',email:'a@b.test'}}}});},
      getUser:function(){return Promise.resolve({data:{user:{id:'u1',email:'a@b.test'}}});},
      signOut:function(){return Promise.resolve({});},
      updateUser:function(){return Promise.resolve({data:{},error:null});},
      mfa:{getAuthenticatorAssuranceLevel:function(){return Promise.resolve({data:{currentLevel:'aal2',nextLevel:'aal2'}});},
           listFactors:function(){return Promise.resolve({data:{totp:[{id:'f1'}]}});}}},
    from:function(t){var rows=t==='profiles'?{full_name:'A Person',email:'a@b.test'}:ROLES.map(function(r){return{role:r};});
      var q={select:function(){return q;},eq:function(){return q;},
        maybeSingle:function(){return Promise.resolve({data:rows,error:null});},
        then:function(f){return Promise.resolve({data:rows,error:null}).then(f);}};return q;},
    rpc:function(n,a){ window.__rpc.push([n,a]);
      if(n==='madrasah_class_list') return Promise.resolve({data:{
        may_amend: ROLES.indexOf('admin')!==-1, classes: CLASSES}, error:null});
      if(n==='madrasah_pupils_in_class') return Promise.resolve({data:ROLL,error:null});
      return Promise.resolve({data:{},error:null}); }};
  Object.defineProperty(window,'supabase',{value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % (json.dumps(roles), json.dumps(classes if classes is not None else CLASSES), json.dumps(ROLL))


def open_as(b, roles, classes=None, w=1500, h=1250):
    pg = b.new_page(viewport={"width": w, "height": h})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:220]))
    pg.add_init_script(stub(roles, classes))
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1400)
    return pg, errs


def called(pg, name):
    return [r for r in pg.evaluate("window.__rpc") if r[0] == name]


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1 & 2. THE LIST, AND NOTHING READ ABOUT A CHILD
    # =====================================================================
    pg, errs = open_as(b, ["admin"])
    check(not errs, "the classes screen threw: %r" % errs[:2])
    check(pg.is_visible("#cl-panel"), "the classes panel did not open")
    check(pg.is_visible("#cl-list-view"), "the list is not showing on arrival")
    check(not pg.is_visible("#cl-detail"), "a class page is open before any class was pressed")

    check(not called(pg, "madrasah_pupils_in_class"),
          "THE REGISTER WAS READ ON PAGE LOAD. Opening a list of classes must not "
          "pull five hundred children's names out of the database; the headcounts "
          "come with the class list and that is all this screen needs to be useful.")

    #  THE LIST CARRIES NO VERBS. This is the whole of what the masjid asked
    #  for, and the count is what makes it checkable rather than a matter of
    #  taste.
    verbs = pg.eval_on_selector_all("#cl-list-view button",
        "els => els.map(e => e.innerText.trim().toLowerCase())")
    for bad in ["edit", "delete", "remove", "amend", "manage", "pdf", "download"]:
        hits = [v for v in verbs if bad in v]
        check(not hits,
              "the LIST carries a %r control on it: %r. Forty-five classes times four "
              "buttons is a hundred and eighty controls on one screen, two of them "
              "destructive. Everything you can DO belongs inside the class."
              % (bad, hits[:3]))

    cards = pg.eval_on_selector_all(".cl-card", "e => e.length")
    check(cards == 6, "expected six running classes on the list, drew %d" % cards)

    #  Nought children is shown as nought, loudly. An empty class is either one
    #  nobody has filled in or one that should not be running.
    body = pg.inner_text("#cl-list-view")
    check("0 children" in body.replace("\n", " "),
          "a class with nobody in it does not say so: %r" % body[:200])

    # =====================================================================
    #  2b. INTO ONE CLASS
    # =====================================================================
    pg.click('.cl-card[data-id="c5"]')
    pg.wait_for_timeout(350)
    check(not pg.is_visible("#cl-list-view"), "the list is still showing behind the class")
    check(pg.is_visible("#cl-detail"), "pressing a class did not open it")
    check("Boys Year 6" in pg.inner_text("#cl-d-name"),
          "the wrong class opened: %r" % pg.inner_text("#cl-d-name"))
    facts = pg.inner_text("#cl-d-facts").replace("\n", " ")
    check("17" in facts and "Hafiz Muhammed Yusuf" in facts,
          "the class page does not carry its headcount and teacher: %r" % facts)

    for want in ["Amend this class", "Who is in it", "Print the class list", "Remove this class"]:
        check(want in pg.inner_text("#cl-d-acts"),
              "the class page is missing the %r action" % want)

    check(not called(pg, "madrasah_pupils_in_class"),
          "OPENING A CLASS READ ITS REGISTER. Pressing a class to see who teaches it "
          "and how many are in it must not pull the children's names; that is what "
          "the separate control is for.")

    pg.click("#cl-roll-btn")
    pg.wait_for_timeout(500)
    got = called(pg, "madrasah_pupils_in_class")
    check(len(got) == 1, "expected exactly one register read, got %d" % len(got))
    check(got and got[0][1].get("p_class") == "c5",
          "the register was fetched for the wrong class: %r" % (got[0][1] if got else None))
    rows = pg.eval_on_selector_all(".cl-pupil", "e => e.length")
    check(rows == len(MADE_UP), "expected %d children listed, drew %d" % (len(MADE_UP), rows))

    # =====================================================================
    #  4. REMOVING A CLASS SAYS HOW MANY CHILDREN ARE IN IT
    # =====================================================================
    pg.click("#cl-remove")
    pg.wait_for_timeout(300)
    q = pg.inner_text("#cl-confirm-q")
    check("17" in q,
          "the confirm does not say how many children are in the class: %r. A question "
          "that reads the same for an empty class and a class of seventeen is a "
          "question people learn to say Yes to." % q)
    check("still running" in q.lower() or "no longer" in q.lower(),
          "the confirm does not offer the thing they probably meant — ending the class "
          "for the year rather than deleting it: %r" % q)
    n = len(called(pg, "delete_madrasah_class"))
    check(n == 0, "the class was deleted while the question was still on screen")
    pg.click("#cl-confirm-no")
    pg.wait_for_timeout(200)
    check(not pg.is_visible("#cl-confirm"), "“No” left the question up")

    #  An EMPTY class asks a different question, or the number above proves
    #  nothing — it could be in the sentence by accident.
    pg.click("#cl-back"); pg.wait_for_timeout(250)
    pg.click('.cl-card[data-id="c11"]'); pg.wait_for_timeout(300)
    pg.click("#cl-remove"); pg.wait_for_timeout(300)
    q2 = pg.inner_text("#cl-confirm-q")
    check("Nobody" in q2 or "nobody" in q2,
          "removing an empty class asks the same question as removing a full one: %r" % q2)
    pg.close()

    # =====================================================================
    #  3. A TEACHER IS NOT OFFERED WHAT WOULD BE REFUSED
    # =====================================================================
    pg, errs = open_as(b, ["madrasah"])
    check(pg.is_visible("#cl-panel"), "a madrasah account cannot open the classes screen")
    pg.click('.cl-card[data-id="c5"]')
    pg.wait_for_timeout(350)
    check(not pg.is_visible("#cl-d-acts"),
          "a teaching account is offered Amend and Remove, which the database refuses. "
          "A control that always fails teaches people the screen is broken.")
    check(pg.is_visible("#cl-d-acts-read"),
          "a teaching account is offered nothing at all — it should still be able to "
          "see the register for its own classes and print it")
    check("Who is in it" in pg.inner_text("#cl-d-acts-read"),
          "a teacher cannot open the register for a class they take")
    pg.close()
    b.close()

# =====================================================================
#  5, 6, 7. THE DATABASE, STATICALLY
# =====================================================================
sql = ""
for name in sorted(os.listdir("db")):
    if re.match(r"^05[0-9]_.*\.sql$", name):
        sql += open(os.path.join("db", name), encoding="utf-8").read()

def body(fn):
    i = sql.rfind("create or replace function public.%s" % fn)
    if i < 0: return ""
    t = sql[i:]
    return t[:t.find("$fn$;") + 5] if "$fn$;" in t else t

#  5. THE BOUNDARY RAISES.
inclass = body("madrasah_pupils_in_class")
check(inclass, "madrasah_pupils_in_class() is not in any migration file")
check("madrasah_classes_i_may_see" in inclass,
      "madrasah_pupils_in_class() does not check which classes the caller may see")
check(re.search(r"not exists[\s\S]{0,160}madrasah_classes_i_may_see[\s\S]{0,200}raise exception", inclass),
      "asking for a class that is not yours does not RAISE. Returning an empty list "
      "says 'there are no children in this class', which is a different and false "
      "statement — and it is the answer that lets somebody map the madrasah by trying "
      "class ids one at a time.")

mayseee = body("madrasah_classes_i_may_see")
check("verified_admin" in mayseee and "madrasah_staff_classes" in mayseee,
      "madrasah_classes_i_may_see() does not join a teacher to their own classes")
check("s.user_id = auth.uid()" in mayseee,
      "a teacher's classes are not tied to the signed-in account")

#  6. NOTHING SENSITIVE IN THE PUPIL TABLE.
tbl = sql[sql.rfind("create table if not exists public.madrasah_pupils"):]
tbl = tbl[:tbl.find(");") + 2]
for bad in ["date_of_birth", "dob", "address", "postcode", "phone", "email",
            "medical", "photo", "nationality", "ethnicity", "notes"]:
    check(bad not in tbl,
          "madrasah_pupils has grown a %r column. The import has no such data and the "
          "assessment does not cover it; an empty column is an invitation, and each "
          "one raises what a breach would cost." % bad)

#  7. RETENTION IS A DELETE, AND IT CANNOT REACH A SAFEGUARDING RECORD.
purge = body("purge_madrasah_pupils")
check("delete from public.madrasah_pupils" in purge,
      "purge_madrasah_pupils() does not delete anything. A policy that says three "
      "years while the rows sit there is not a retention period.")
#  THE EXACT INTERVAL, NOT A SUBSTRING.
#
#  Found while proving these checks can fail. This read `"3 years" in purge`,
#  which is contained in "30 years" — so widening the retention tenfold sailed
#  straight through the check meant to guard it. A test that passes on the
#  change it exists to catch is worse than no test, because somebody has
#  already stopped looking.
check(re.search(r"interval\s*'3 years'", purge),
      "the purge is not set to the three years the masjid chose: %r"
      % (re.findall(r"interval\s*'[^']+'", purge) or "no interval at all"))
check("left_on is not null" in purge,
      "the purge does not require a leaving date. `null < anything` is null rather "
      "than true so it happens to work, but a clever condition is what somebody "
      "breaks later — and breaking this one deletes children who are still here.")
check("confdeltype" in sql and "madrasah_pupil_classes" in sql,
      "nothing checks that a safeguarding table can never cascade-delete from "
      "madrasah_pupils. A concern is kept many years longer than a pupil record; "
      "cascading turns the three-year purge into a safeguarding purge.")

#  And the import file must never have been committed.
for root, dirs, files in os.walk("."):
    if ".git" in root: continue
    for f in files:
        if "pupil" in f.lower() and f.endswith(".sql") and "import" in f.lower():
            fails.append("A PUPIL IMPORT FILE IS IN THE REPOSITORY: %s. This repository "
                         "is the public website." % os.path.join(root, f))

_report.done = True
if fails:
    sys.exit(1)
