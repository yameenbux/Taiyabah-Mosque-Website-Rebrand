"""/portal/ — the madrasah, three pages behind one door.

13 September 2026. /portal/ was live and broken before this: its index.html was
the madrasah sign-in page and its app.js was a copy of the admin-centre
signpost, looking for elements this page has never had. It threw on every load
and rendered nothing past the spinner.

WHAT THIS FILE GUARDS:

  1  an administrator gets the console
  2  THE FIGURES SAY WHERE THEY COME FROM, and they come from the database.
     This is the check that failed to fail. It used to assert the literal
     539 and the words "not imported" on the Students tile — both of which
     were true when it was written, and both of which the page went on
     saying after 543 children were imported on 18 September. The test
     passed and the page lied. It now asserts that every figure on screen
     MATCHES THE FIGURE THE DATABASE RETURNED, which is a thing that cannot
     go stale, rather than a number somebody has to remember to update here.
  3  WHAT NEEDS DOING IS A LIST OF JOBS, and a job with nothing in it is not
     drawn. Nine tiles of which seven say nought is a screen people stop
     reading, and then they stop seeing the two that matter.
  4  NO CHILD IS NAMED ON THE LANDING PAGE. It is the page on the monitor
     when somebody walks past the office and in every screenshot.
  5  the two ways out are in the heading, and the purple strip is gone
  6  a teacher gets the teachers' page, a parent gets the parents' page, and
     neither is shown an administrator's console
  7  neither is offered a link to the admin centre, which would refuse them
  8  somebody with none of those roles is told so
  9  the data-protection list says what is DONE as well as what is not — a
     finished item deleted takes its evidence with it

Nothing here reaches Supabase.

Run:  python3 _test/portal_test.py
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
PAGE = "http://127.0.0.1:%d/portal/" % httpd.server_address[1]

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


#  WHAT WENT WRONG SURVIVES A CRASH.
#
#  Added 19 September, after this file did exactly what staff_screen_test.py
#  was taught not to do a day earlier. A deliberate break was applied to prove
#  a check could fail; the page drew four jobs it should not have; the check
#  DID fail and recorded it — and then a KeyError four lines later killed the
#  interpreter and took the whole `fails` list with it. The output was a stack
#  trace about a dictionary. Run from a harness that greps for "FAILURES", it
#  looked exactly like a pass.
#
#  So the diagnosis is printed on the way out, whether this file finishes or
#  falls over. Every suite in this project that presses buttons carries this;
#  this one did not, and the gap was invisible until something crashed.
import atexit


@atexit.register
def _report():
    if fails:
        print("\nFAILURES (%d):" % len(fails))
        for f in sorted(set(fails)):
            print("  " + f)
    elif _report.reached_end:
        print("\nALL PASS")
    else:
        print("\nDID NOT FINISH — see the traceback above. Nothing above it "
              "failed before it stopped.")


_report.reached_end = False


#  WHAT madrasah_overview() RETURNS. Chosen so that three jobs are live and
#  four are not: the page must draw exactly three tiles, and the four at nought
#  must not appear at all.
OVERVIEW = {
    "as_at": "2026-09-19T15:00:00Z",
    "pupils": 543, "staff": 40, "classes": 45,
    "staff_without_days": 4,
    "staff_without_side": 0,
    "classes_no_main_teacher": 10,
    "pupils_without_class": 0,
    "admissions_waiting": 0,
    "dbs": {"none": 20, "overdue": 1, "valid": 19},
    "dbs_needs_attention": [
        {"id": "s%d" % i, "name": "Aisha Testperson %d" % i,
         "state": "overdue" if i == 0 else "none"} for i in range(21)],
    "archive_total": 0, "archive_going_soon": 0,
}

#  The jobs that must be drawn for that fixture, and the ones that must not.
#  WHAT madrasah_today() RETURNS. Since 087 THIS is what decides what is
#  waiting, next to the data, and the page draws what it says. The old JOBS
#  list in portal/app.js survives only as a fallback for when this call fails.
#  A TEACHER'S OWN CLASSES. One class, nobody marked yet, and the register
#  still shut because parents have not been told - which is the real state of
#  the system on 28 September and therefore the state worth drawing.
MYCLASSES = {
    "allowed": True, "on_date": "2026-09-28",
    "permitted": {"permitted": False, "families": 330, "told": 0,
                  "outstanding": 330,
                  "why": "The privacy notice promises parents they will be told "
                         "before the first mark is made. 330 families have not "
                         "been told yet."},
    "rows": [{"id": "c1", "name": "Boys Year 7", "on_roll": 10, "marked": 0,
              "away": 0, "section": "boys", "sort_order": 250,
              "i_am_the_main_teacher": False}],
}

#  THE SAME CLASSES, WITH THE REGISTER OPEN - every family told. The only
#  state in which #tc-outstanding (Task 9) is allowed to say anything at
#  all; see that section for why.
MYCLASSES_OPEN = dict(MYCLASSES)
MYCLASSES_OPEN["permitted"] = {
    "permitted": True, "families": 330, "told": 330, "outstanding": 0,
    "why": "Every family has been told the register is being kept."}

#  THE OCTOBER REVIEW - the third state, and the one production had never
#  been given. The 'permitted' KEY IS DELETED here, not set to False: a
#  stale/short RPC response, a caller not yet taught about attendance_gate,
#  or a version skew are all things a MISSING key, not an explicit false,
#  would look like. drawTonight()'s `var p = d.permitted || {}; permitted =
#  (p.permitted === true)` already fails closed for the invitations in this
#  state (undefined !== true), which the review confirmed is right. What
#  was wrong is that #tc-gate itself only spoke on the strict
#  `p.permitted === false`, so this exact fixture is the one that shows a
#  locked page with nothing saying why - "the worst of the three outcomes".
MYCLASSES_UNKNOWN = dict(MYCLASSES)
del MYCLASSES_UNKNOWN["permitted"]

#  A TEACHER WITH TWO REGISTERS BEHIND THEM, both from EARLIER evenings.
#  Invented class, invented dates - never a real pupil, parent or staff
#  name, per CLAUDE.md.
MY_OUTSTANDING = {
    "allowed": True, "count": 2,
    "rows": [{"class_id": "c9", "name": "Girls Year 4", "on_date": "2026-09-19"},
             {"class_id": "c9", "name": "Girls Year 4", "on_date": "2026-09-12"}]}
MY_OUTSTANDING_NONE = {"allowed": True, "count": 0, "rows": []}

#  ITEM 2 OF THE SEPT 28 REVIEW. my_registers_outstanding() (db/104) windows
#  current_date-14 TO current_date - INCLUSIVE OF TONIGHT - so its bare
#  'count' double-counts the same evening the Tonight tile already names.
#  This fixture mixes ONE row dated the SAME as MYCLASSES_OPEN["on_date"]
#  (tonight) in with the two earlier ones, bare count 3, to prove the page
#  shows the BACKLOG (2, excluding tonight) and says "earlier", not the
#  bare total (3).
MY_OUTSTANDING_WITH_TONIGHT = {
    "allowed": True, "count": 3,
    "rows": [{"class_id": "c1", "name": "Boys Year 7",
              "on_date": MYCLASSES_OPEN["on_date"]},
             {"class_id": "c9", "name": "Girls Year 4", "on_date": "2026-09-19"},
             {"class_id": "c9", "name": "Girls Year 4", "on_date": "2026-09-12"}]}

#  Tonight's own register is the ONLY thing outstanding - the backlog is
#  empty, and the prompt must say nothing even though the bare count is 1.
MY_OUTSTANDING_ONLY_TONIGHT = {
    "allowed": True, "count": 1,
    "rows": [{"class_id": "c1", "name": "Boys Year 7",
              "on_date": MYCLASSES_OPEN["on_date"]}]}

#  TASK 10, db/112. db/112's own count is (due dates x due classes) minus
#  already-submitted, over the fortnight BEFORE today. This fixture uses
#  the same shape with invented small numbers - 7 due evenings across 8
#  due classes, 45 of those 56 slots already submitted - so RM_COUNT is
#  BUILT, not typed, and cannot silently disagree with RM_TITLE below.
RM_DUE_DATES = 7
RM_DUE_CLASSES = 8
RM_ALREADY_SUBMITTED = 45
RM_COUNT = RM_DUE_DATES * RM_DUE_CLASSES - RM_ALREADY_SUBMITTED
RM_TITLE = str(RM_COUNT) + " register" + \
    (" was" if RM_COUNT == 1 else "s were") + " not taken"

TODAY = {
    "allowed": True, "admin": True, "on_date": "2026-09-27",
    "items": [
        {"key": "registers", "count": 7, "tone": "now",
         "title": "7 classes have no register yet",
         "said": "Tonight. A register taken tomorrow is somebody remembering.",
         "href": "register/", "action": "Take the register"},
        {"key": "dbs", "count": 21, "tone": "bad",
         "title": "21 of 40 members of staff need a DBS check looked at",
         "said": "20 with no check recorded and 1 whose check has lapsed.",
         "href": "staff/", "action": "Open the staff list"},
        #  TASK 10 (db/111, corrected by db/112 - see that file's header for
        #  why the window changed and why registers_missing() is no longer
        #  called at all). THE COUNT IS DERIVED, not a literal picked to
        #  match the title by eye: db/112's own shape is (due dates x due
        #  classes) minus already-submitted, over the fortnight BEFORE
        #  today (today's own registers are the separate 'registers' /
        #  'attendance_gate' item above, not this one) - so this fixture
        #  builds its count the same way, and a copy-paste that let the
        #  count and the title drift apart cannot survive it. See the
        #  assertion below (section 3) that recomputes the title text
        #  independently of this construction and checks it EXACTLY, not
        #  merely that it contains the right words.
        {"key": "registers_missed", "count": RM_COUNT, "tone": "bad",
         "title": RM_TITLE,
         "said": "In the last fortnight: a register not taken is not a "
                 "register taken late. Nobody was recorded as being in "
                 "that room.",
         "href": "register/", "action": "Open the registers"},
        {"key": "siblings", "count": 56, "tone": "quiet",
         "title": "56 pairs of children might be brothers and sisters",
         "said": "They share a surname and an address.",
         "href": "families/", "action": "Settle them"},
    ],
    "roll": {"children": 552, "families": 330, "classes": 44,
             "here_tonight": 0, "away_tonight": 0},
}

JOBS_LIVE = ["dbs", "main_teacher", "days"]
JOBS_QUIET = ["no_class", "side", "admissions", "purge"]


def stub(roles, today=True, must_change=False, myclasses=None, outstanding=None):
    return """
(function(){
  var ROLES = %s, OV = %s, TODAY = %s, MUSTCHANGE = %s, MYCLASSES = %s,
      MY_OUTSTANDING = %s;
  var client = {
    auth: {
      getSession: function(){ return Promise.resolve({data:{session:{
        access_token:'t', user:{id:'u1', email:'someone@example.test'}}}}); },
      getUser: function(){ return Promise.resolve({data:{user:{
        id:'u1', email:'someone@example.test'}}}); },
      signOut: function(){ return Promise.resolve({}); },
      updateUser: function(a){ window.__UPDATED = a;
                              return Promise.resolve({data:{},error:null}); },
      mfa: { getAuthenticatorAssuranceLevel: function(){
               return Promise.resolve({data:{currentLevel:'aal2', nextLevel:'aal2'}}); },
             listFactors: function(){ return Promise.resolve({data:{totp:[{id:'f1'}]}}); } }
    },
    from: function(t){
      var rows = t === 'profiles' ? {full_name:'A Person', email:'someone@example.test',
                                     must_change_password: MUSTCHANGE}
               : ROLES.map(function(r){ return {role:r}; });
      var q = { select:function(){return q;}, eq:function(){return q;},
        maybeSingle:function(){ return Promise.resolve({data:rows, error:null}); },
        then:function(res){ return Promise.resolve({data:rows, error:null}).then(res); } };
      return q;
    },
    rpc: function(n){
      //  THE FIXTURE IS THE EXPECTED ANSWER. Every figure the page draws is
      //  checked against THIS object rather than against a literal typed into
      //  the assertions, which is what let the old version of this file pass
      //  while the page showed a number from a different system.
      //  NEVER SETTLES, ON PURPOSE. On success the gate calls this and then
      //  window.location.reload(). A reload wipes window.__UPDATED and empties
      //  the form, so a test that clicks Save and then looks for the evidence
      //  destroys the thing it is measuring - which is exactly what the first
      //  version of the gate assertion did, and it read as "updateUser was
      //  never called". Holding this promise open stops the flow one step
      //  before the reload, with the evidence still on the page.
      if (n === 'madrasah_my_classes') return Promise.resolve({data: MYCLASSES, error:null});
      if (n === 'clear_must_change_password') return new Promise(function(){});
      if (n === 'madrasah_overview') return Promise.resolve({data: OV, error:null});
      //  null means "this call fails", which is how the fallback is exercised.
      if (n === 'madrasah_today') return TODAY
        ? Promise.resolve({data: TODAY, error:null})
        : Promise.resolve({data:null, error:{message:'today is unavailable'}});
      //  TASK 9. null (the default) answers exactly as an unconfigured RPC
      //  always has in this stub - {} with no error - so every OTHER test
      //  in this file, which never mentions my_registers_outstanding at
      //  all, keeps seeing the same nothing it always has.
      if (n === 'my_registers_outstanding') return Promise.resolve(
        {data: (MY_OUTSTANDING === null ? {} : MY_OUTSTANDING), error:null});
      return Promise.resolve({data:{}, error:null});
    }
  };
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}}, writable:false, configurable:false});
})();
""" % (json.dumps(roles), json.dumps(OVERVIEW),
       json.dumps(TODAY) if today else "null", json.dumps(bool(must_change)),
       json.dumps(myclasses if myclasses is not None else MYCLASSES),
       json.dumps(outstanding))


def open_as(b, roles, w=1400, h=1200, today=True, must_change=False,
            myclasses=None, outstanding=None):
    pg = b.new_page(viewport={"width": w, "height": h})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.add_init_script(stub(roles, today, must_change, myclasses, outstanding))
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1200)
    return pg, errs


def text(pg, sel):
    n = pg.query_selector(sel)
    return re.sub(r"\s+", " ", n.inner_text()) if n else ""


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1. AN ADMINISTRATOR GETS THE CONSOLE
    # =====================================================================
    pg, errs = open_as(b, ["admin"])
    check(pg.is_visible("#md-panel"), "the madrasah console did not open for an administrator")
    check(not pg.is_visible("#tc-panel") and not pg.is_visible("#pa-panel"),
          "an administrator was shown a role landing page as well as the console")
    check(pg.evaluate("document.querySelector('.shell').classList.contains('wide-mode')"),
          "the console did not go full width")

    # =====================================================================
    #  2. EVERY FIGURE ON SCREEN IS THE FIGURE THE DATABASE RETURNED
    #
    #  THIS IS THE CHECK THAT FAILED TO FAIL. The old version asserted the
    #  literal "539" and the words "not imported" on the Students tile. Both
    #  were true the day they were written. Then 543 children were imported on
    #  18 September, the page went on saying 539 and "not imported", and THIS
    #  TEST WENT ON PASSING — because it was asserting the same stale facts the
    #  page was.
    #
    #  A test that agrees with the page is not a test. So nothing below is a
    #  literal: each figure is compared with the fixture the stub answered
    #  with, which is the only thing that cannot drift from what the page was
    #  given.
    # =====================================================================
    counts = text(pg, "#md-counts")
    tiles = pg.eval_on_selector_all("#md-counts .md-count", "els => els.map(e => e.innerText)")
    check(len(tiles) == 4, "expected four count tiles, drew %d" % len(tiles))

    #  MATCHED ON THE TILE'S OWN LABEL, not on its whole text. The first
    #  version of this searched the innerText for "CLASSES" and matched the
    #  TEACHERS tile, whose description contains the word classes - so it
    #  checked the wrong tile and reported the right one as broken.
    labelled = pg.eval_on_selector_all("#md-counts .md-count", """els => els.map(e => ({
        k: ((e.querySelector('.k')||{}).innerText || '').trim().toUpperCase(),
        t: e.innerText }))""")
    for want, key in (("CHILDREN", "pupils"), ("TEACHERS", "staff"), ("CLASSES", "classes")):
        tile = [x["t"] for x in labelled if x["k"] == want]
        check(tile, "there is no %s tile" % want.title())
        if tile:
            check(str(OVERVIEW[key]) in tile[0],
                  "the %s tile does not show the number the database returned "
                  "(%s): %r" % (want.title(), OVERVIEW[key], tile[0][:140]))
            check("in this system" in tile[0].lower(),
                  "the %s tile does not say the figure is this system's own. It "
                  "IS this system's own — saying otherwise is what sends a figure "
                  "from a different system into a committee paper: %r"
                  % (want.title(), tile[0][:140]))

    #  AND THE ONE THAT IS STILL SOMEWHERE ELSE MUST STILL SAY SO. Contacts is
    #  the last tile this database cannot answer for; the day there is a
    #  families table, this is the assertion that has to be changed on purpose.
    contacts = [x["t"] for x in labelled if x["k"] == "CONTACTS"]
    check(contacts and "not imported" in contacts[0].lower(),
          "the Contacts tile no longer says the figure is not this system's. "
          "There is no families table, so it is not: %r"
          % (contacts or [""])[0][:140])

    #  THE PANEL AND THE TILES ARE THE SAME NUMBERS READ TWICE, so they cannot
    #  disagree. The old page had a panel saying "no pupil records at all" over
    #  a tile showing 539 — two statements, one screen, both wrong, and nothing
    #  in the way of either.
    lead = text(pg, "#md-lead")
    for key in ("pupils", "staff", "classes"):
        check(str(OVERVIEW[key]) in lead,
              "the panel above the figures does not carry the %s figure (%s), so "
              "it can drift from the tiles underneath it: %r"
              % (key, OVERVIEW[key], lead[:200]))
    check("no pupil record" not in lead.lower() and "not been imported" not in lead.lower(),
          "THE PANEL STILL SAYS THERE ARE NO PUPIL RECORDS. There are %d: %r"
          % (OVERVIEW["pupils"], lead[:200]))

    # =====================================================================
    #  3. WHAT NEEDS DOING COMES FROM madrasah_today(), AND NOUGHTS ARE NOT
    #     DRAWN
    #
    #  THIS SECTION USED TO PASS FOR THE WRONG REASON. The stub answered every
    #  unknown rpc with {} and no error, so madrasah_today() "succeeded" with
    #  no items in it, the page fell through to its old JavaScript job list,
    #  and every assertion here was checking the FALLBACK while reading as
    #  though it checked the new path. The stub now answers madrasah_today()
    #  properly, and the fallback is exercised on purpose further down.
    # =====================================================================
    jobs = pg.eval_on_selector_all("#md-doing .md-job",
                                   "els => els.map(e => e.getAttribute('data-job'))")
    want = [i["key"] for i in TODAY["items"]]
    check(jobs == want,
          "the jobs drawn are %r, expected exactly what madrasah_today() "
          "returned, in its order: %r" % (jobs, want))

    #  THE ORDER IS THE DATABASE'S, NOT THE PAGE'S. madrasah_today() puts
    #  tonight's registers first because they are the only thing with a
    #  deadline of this evening, and the quiet fifty-six last. A page that
    #  re-sorts by size would put the sibling pairs at the top.
    check(jobs and jobs[0] == "registers",
          "the first job is %r; madrasah_today() put the registers first and "
          "the page has re-ordered them" % (jobs[0] if jobs else None))
    check(jobs and jobs[-1] == "siblings",
          "the quiet job is not last: %r" % jobs)

    detail = pg.eval_on_selector_all("#md-doing .md-job", """els => els.map(e => ({
        job: e.getAttribute('data-job'),
        n: (e.querySelector('.md-job-n')||{}).innerText,
        t: (e.querySelector('.md-job-t')||{}).innerText,
        w: (e.querySelector('.md-job-w')||{}).innerText,
        cls: e.getAttribute('class'),
        go: (e.querySelector('.md-job-go')||{}).getAttribute
              ? e.querySelector('.md-job-go').getAttribute('href') : null }))""")
    by = dict((d["job"], d) for d in detail)
    for it in TODAY["items"]:
        d = by.get(it["key"])
        if not d:
            check(False, "madrasah_today() returned %r and the page did not "
                         "draw it" % it["key"])
            continue
        check(d["n"].strip() == str(it["count"]),
              "the %s job shows %r, the database said %s"
              % (it["key"], d["n"], it["count"]))
        check(it["title"] in d["t"],
              "the %s job does not use the database's own wording: %r"
              % (it["key"], d["t"]))
        #  THE SENTENCE TRAVELS WITH THE NUMBER. "21" on its own is a figure;
        #  "20 with no check recorded and 1 whose check has lapsed" is two
        #  different conversations with two different people.
        check(it["said"][:30] in d["w"],
              "the %s job shows a number with no reason beside it: %r"
              % (it["key"], d["w"]))
        #  A DASHBOARD THAT NAMES A PROBLEM AND LEAVES YOU TO FIND THE SCREEN
        #  IS A WORSE NOTE ON A FRIDGE.
        check(d["go"] == it["href"],
              "the %s job goes to %r, not %r" % (it["key"], d["go"], it["href"]))

    #  THREE TONES, AND THEY MUST NOT ALL LOOK THE SAME. A safeguarding matter
    #  and a quiet afternoon's job rendered identically is a screen where
    #  nothing stands out, which is the same as a screen where nothing is
    #  wrong.
    tones = set(by[k]["cls"].split("md-job-")[1].split()[0]
                for k in by if "md-job-" in by[k]["cls"])
    check(len(tones) == 3, "the three jobs render in %d tone(s): %r"
          % (len(tones), tones))
    check("bad" in by["dbs"]["cls"],
          "the DBS job is not drawn as the worst kind: %r" % by["dbs"]["cls"])
    #  THE DENOMINATOR IS NOT DECORATION. "21" is a number somebody files
    #  away; "21 of 40" is half the people who teach here, and it reads that
    #  way at a glance. This assertion is the only reason anybody noticed when
    #  a rewrite dropped it - see db/088.
    dbs = [d for d in detail if d["job"] == "dbs"]
    check(dbs and "21 of 40" in dbs[0]["t"],
          "the DBS job does not read as a sentence with both numbers in it: %r"
          % (dbs or [{}])[0].get("t"))

    #  TASK 10, db/112. A CHECK THAT FINDS THE ITEM IS NOT A CHECK THAT THE
    #  ITEM IS RIGHT - db/111 shipped a count that contradicted its own "in
    #  the last fortnight" sentence (484 vs a true 440), and the earlier
    #  version of this suite only ever checked the item was DRAWN, never
    #  that its own two halves agreed. So the expected title here is
    #  recomputed by an expression written FRESH at this assertion, not by
    #  reusing RM_TITLE from the fixture above - a bug in how RM_TITLE was
    #  built would otherwise mark its own homework.
    rm = [d for d in detail if d["job"] == "registers_missed"]
    check(rm, "the registers_missed job was not drawn at all")
    if rm:
        want_n = RM_DUE_DATES * RM_DUE_CLASSES - RM_ALREADY_SUBMITTED
        want_title = "%d register%s not taken" % (
            want_n, (" was" if want_n == 1 else "s were"))
        check(rm[0]["n"].strip() == str(want_n),
              "the registers_missed count (%r) does not equal the fortnight "
              "figure computed independently (%d due dates x %d due classes "
              "minus %d already submitted = %d)"
              % (rm[0]["n"], RM_DUE_DATES, RM_DUE_CLASSES,
                 RM_ALREADY_SUBMITTED, want_n))
        #  EXACT, not "contains" - the generic loop above only checks the
        #  fixture's own title is a substring of what is drawn; this checks
        #  the drawn title IS the formula's output for this count, word for
        #  word, so a pluralisation slip ("11 registers was not taken") or
        #  a stale count baked into the title string cannot pass.
        check(rm[0]["t"].strip() == want_title,
              "the registers_missed title (%r) is not exactly what the "
              "count (%s) implies (%r) - the number and the words have "
              "drifted apart, which is the exact fault db/112 fixed once"
              % (rm[0]["t"], rm[0]["n"], want_title))

    # =====================================================================
    #  3b. WHEN madrasah_today() FAILS, THE PAGE STILL SAYS SOMETHING
    #
    #  The old JavaScript job list is kept in portal/app.js for exactly this,
    #  and until now nothing had ever run it in that state. A fallback nobody
    #  exercises is a fallback that does not work: this is the screen somebody
    #  opens to find out whether anything is wrong, and a blank panel on it
    #  reads as "nothing is wrong".
    # =====================================================================
    fb, fb_errs = open_as(b, ["admin", "madrasah"], today=False)
    fb_jobs = fb.eval_on_selector_all(
        "#md-doing .md-job", "els => els.map(e => e.getAttribute('data-job'))")
    check(sorted(fb_jobs) == sorted(JOBS_LIVE),
          "with madrasah_today() unavailable the page fell back to %r, "
          "expected the old list %r" % (sorted(fb_jobs), sorted(JOBS_LIVE)))
    check(fb_jobs and fb_jobs[0] == "dbs",
          "the fallback does not put safeguarding first: %r" % fb_jobs)
    check(len(fb_jobs) > 0,
          "the panel is EMPTY when madrasah_today() fails, which on this "
          "screen reads as 'nothing is wrong'")
    check(fb_errs == [],
          "a failing madrasah_today() threw on the page: %s" % fb_errs)
    fb.close()

    # =====================================================================
    #  4. NO CHILD, AND NO MEMBER OF STAFF, IS NAMED ON THE LANDING PAGE
    #
    #  The old page listed nineteen teachers' names here as chips. This is the
    #  screen on the office monitor when somebody walks past it, the one in
    #  every screenshot and on every shared screen in a meeting. The names are
    #  one press away on the staff screen, where somebody chose to go.
    # =====================================================================
    body = pg.inner_text("body")
    named = [p["name"] for p in OVERVIEW["dbs_needs_attention"] if p["name"] in body]
    check(not named,
          "%d PERSON'S NAME IS ON THE LANDING PAGE: %r. The count belongs here; "
          "the names belong on the screen somebody opened on purpose."
          % (len(named), named[:3]))

    # =====================================================================
    #  5. THE TWO WAYS OUT ARE IN THE HEADING, AND THE PURPLE STRIP IS GONE
    # =====================================================================
    check(not pg.is_visible(".wide-top"),
          "the dark strip above the working area is back. It held a THIRD copy "
          "of Admin centre and Sign out — the rail already has both.")
    acts = text(pg, "#ashell-head-acts").lower()
    check("admin centre" in acts, "the heading has no way back to the Admin Centre")
    check("sign out" in acts, "the heading has no way to sign out")
    #  Sign out CLICKS the page's own button rather than reimplementing it. If
    #  it ever stops doing that, this catches it: the page's button is the one
    #  wired to Supabase.
    clicked = pg.evaluate("""() => {
        var hit = false;
        var b = document.getElementById('app-signout');
        if (!b) return 'no page button';
        b.addEventListener('click', function(){ hit = true; }, {once:true});
        var h = document.querySelector('#ashell-head-acts .ashell-ha-out');
        if (!h) return 'no heading button';
        h.click();
        return hit ? 'ok' : 'did not reach the page button';
    }""")
    check(clicked == "ok",
          "the heading's Sign out does not click the page's own sign-out "
          "button (%s), so it is a second implementation to keep in step" % clicked)

    # =====================================================================
    #  6. NOTHING PRETENDS TO BE CLICKABLE
    #
    #  The count tiles are DIVs. A control that looks pressable and does
    #  nothing teaches people the page is broken, and then they stop reporting
    #  it when it really is. (The JOB tiles DO have links — that is the point
    #  of them — so only the counts are checked here.)
    # =====================================================================
    clickable = pg.eval_on_selector_all(
        "#md-counts a, #md-counts button", "els => els.length")
    check(clickable == 0,
          "%d things among the count tiles look pressable and go nowhere"
          % clickable)

    # =====================================================================
    #  9. THE DATA-PROTECTION LIST SAYS WHAT IS DONE AS WELL AS WHAT IS NOT
    #
    #  It used to be headed "Before the first pupil record" with every item
    #  un-ticked — describing a gate that had been walked through on 18
    #  September, 543 times. A compliance list that is wrong is worse than
    #  none: it is read once, found stale, and ignored thereafter, including
    #  on the day one of its items genuinely is outstanding.
    # =====================================================================
    items = pg.eval_on_selector_all("#md-before-list li", """els => els.map(e => ({
        done:    e.classList.contains('md-done'),
        waiting: e.classList.contains('md-waiting'),
        todo:    e.classList.contains('md-todo'),
        next:    !!e.querySelector('.md-next'),
        t: e.innerText }))""")
    check(len(items) >= 6, "the data-protection list has only %d items" % len(items))
    done    = [i for i in items if i["done"]]
    waiting = [i for i in items if i["waiting"]]
    todo    = [i for i in items if i["todo"]]

    #  EXACTLY ONE STATE EACH. Two classes on one row would render a tick and
    #  a pen together and mean nothing.
    for i in items:
        n = sum([i["done"], i["waiting"], i["todo"]])
        check(n == 1,
              "an item carries %d states at once, so it shows two marks: %r"
              % (n, i["t"][:70]))

    check(done, "NOTHING is marked done, on a system that has already imported "
                "543 pupil records \u2014 so the list is describing a gate it is "
                "standing on the far side of")

    #  THE MIDDLE STATE IS THE WHOLE POINT OF THIS SECTION.
    #
    #  The list was done / not done, and on 19 September the assessment, the
    #  privacy notice and the breach procedure were all written \u2014 and all
    #  three still read STILL OUTSTANDING, next to "it needs to exist before it
    #  is needed" against a procedure that existed. The screen was RIGHT (a
    #  document is not an adopted procedure) and USELESS (it hid that the work
    #  was finished and the decision was somebody else's).
    #
    #  A two-state list forces a lie in one direction or the other whenever
    #  real work sits between starting and finishing, which is where most of
    #  the work on a list like this sits.
    check(waiting,
          "NOTHING is 'with the trustees'. Three documents were written on 19 "
          "September and none of them can be ticked until it is signed \u2014 if "
          "the list has no middle state it must be calling them either finished "
          "or not started, and both are false.")

    #  AND ANYTHING NOT DONE SAYS WHAT WOULD CLOSE IT. A status list that
    #  reports a thing is outstanding without saying what finishes it is a list
    #  that gets read once.
    for i in waiting + todo:
        check(i["next"],
              "%r is not done and does not say what would close it"
              % i["t"].split("\n")[0][:60])

    joined = " ".join(i["t"] for i in items).lower()
    for want in ["dpia", "impact assessment"]:
        if want in joined:
            break
    else:
        check(False, "the list no longer mentions the impact assessment: %r" % joined[:200])
    for want in ["ico", "article 9", "aal2", "privacy notice", "breach"]:
        check(want in joined,
              "%r is no longer anywhere in the data-protection list" % want)

    #  THE HEADING COUNTS WHAT IS LEFT, split by state, so somebody reads the
    #  number instead of the whole list.
    head = text(pg, "#md-before-h").lower()
    check("trustees" in head or "outstanding" in head or "confirmed" in head,
          "the data-protection heading does not say where things stand: %r" % head)
    if waiting:
        check(str(len(waiting)) in head,
              "the heading does not say how many are with the trustees (%d): %r"
              % (len(waiting), head))

    check(errs == [], "uncaught exceptions for an administrator: %s" % errs)
    pg.close()

    # =====================================================================
    #  4. A TEACHER
    # =====================================================================
    #  outstanding=MY_OUTSTANDING (2 registers, not 0) ON PURPOSE, even
    #  though this fixture's register is NOT open. If #tc-outstanding ever
    #  stopped checking attendance_permitted() before drawing itself, THIS
    #  is the fixture that would catch it - a zero-outstanding fixture here
    #  would let a real regression through unnoticed, because there would
    #  be nothing for a broken version to wrongly show.
    pg, errs = open_as(b, ["teacher"], outstanding=MY_OUTSTANDING)
    check(pg.is_visible("#tc-panel"), "a teacher was not shown the teachers' page")
    check(not pg.is_visible("#md-panel"),
          "A TEACHER WAS SHOWN THE ADMINISTRATOR'S CONSOLE")
    check(not pg.is_visible("#pa-panel"), "a teacher was shown the parents' page")
    items = pg.eval_on_selector_all("#tc-list .rl-item", "els => els.map(e => e.innerText)")
    check(len(items) >= 6, "the teachers' page lists only %d things" % len(items))
    joined = " ".join(items).lower()
    for want in ["register", "homework", "report"]:
        check(want in joined, "the teachers' page does not mention %r: %r" % (want, joined[:300]))
    check("coming soon" in text(pg, "#tc-panel").lower(),
          "THE TEACHERS' PAGE DOES NOT SAY IT IS NOT OPEN YET. A list of "
          "promises is only worth showing if the last line is honest")

    # 5. and it is not offered a door that will be shut in its face.
    #  AND IT IS NOT OFFERED A DOOR THAT WILL BE SHUT IN ITS FACE.
    #
    #  This assertion used to look at #app-top-back, in the dark strip above
    #  the working area. That strip is gone, and the two controls moved into
    #  the page heading - where, for about ten minutes, they were drawn for
    #  EVERYBODY. This check caught it. It now looks where they actually live,
    #  which is the thing an assertion about a removed element cannot do: the
    #  old one would have passed for ever, because is_visible() on an element
    #  that does not exist is False.
    head_acts = text(pg, "#ashell-head-acts").lower()
    check("admin centre" not in head_acts,
          "A TEACHER IS OFFERED A LINK TO THE ADMIN CENTRE, which refuses them: "
          "%r" % head_acts)
    check("sign out" in head_acts,
          "a teacher has no way to sign out from the heading: %r" % head_acts)

    #  AND THE SAME QUESTION ASKED OF THE RAIL, WHICH IS WHERE IT WAS WRONG.
    #
    #  The assertion above passed on 28 September while the first teacher to
    #  sign in was looking at a rail headed "← Admin Centre". It was true and
    #  it was narrow: the heading was gated on the admin role, the rail's own
    #  back row was not, and this file only ever looked at the heading.
    #
    #  The comment above records that this check once moved because it was
    #  looking in the wrong place. It moved to the right place and stopped
    #  covering the old one. So ask the whole rail, not one element of it.
    # ------------------------------------------------------------------
    #  THE PAGE GREETS THEM, AND EVERY FIGURE ON IT IS THEIRS.
    #
    #  Asked for on 28 September: "I'd like this page to be a bit more
    #  welcoming." A teacher opens this in the dark before teaching ten
    #  children for an hour, unpaid, and the first thing it said was "What
    #  needs doing" over an empty page.
    #  .ashell-head h1 is where shell.js puts the page title. Named exactly,
    #  because a bare "h1" selector matches the rail's brand mark first and
    #  then reports that the page says "madrasah" - which it does, and which
    #  is not what is being asked.
    head = text(pg, ".ashell-head h1")
    check("assalamu alaikum" in head.lower(),
          "the page does not greet the teacher: %r" % head[:90])
    check("A Person" in head,
          "the greeting does not use the teacher's name: %r" % head[:90])

    #  THE HADITH IS CITED, NOT FLOATED. A prophetic narration put in front
    #  of 39 teachers carries who narrated it and where it is recorded, or it
    #  should not be on the screen. The Arabic is checked by its own script
    #  rather than by the class name, so deleting the text fails even if the
    #  element survives.
    ar = text(pg, ".h-ar")
    check(any("\u0600" <= ch <= "\u06ff" for ch in ar),
          "the hadith has no Arabic text in it: %r" % ar)
    src = text(pg, ".h-src")
    check("bukh" in src.lower() and "5027" in src,
          "the hadith is not attributed to a source: %r" % src)

    #  AND IT IS A BANNER, NOT A STACK.
    #
    #  Asked for twice. The first build centred the Arabic above its
    #  translation down the middle of the page - "I wanted the Arabic text /
    #  hadeeth more like a banner underneath the Name, not centrally and
    #  stacked." Wording assertions cannot tell those two apart: the same
    #  text, the same classes, the same source line, laid out differently.
    #  So this asks the geometry. On a wide viewport the Arabic and the
    #  English sit BESIDE each other, which means their boxes overlap
    #  vertically and do not overlap horizontally.
    band = pg.evaluate("""() => {
      var a = document.querySelector('.h-ar');
      var t = document.querySelector('.tcb-text');
      var b = document.querySelector('.tc-banner');
      if (!a || !t || !b) return null;
      var ar = a.getBoundingClientRect(), tr = t.getBoundingClientRect(),
          br = b.getBoundingClientRect();
      return {
        sideBySide: (ar.right <= tr.left + 1) &&
                    (ar.top < tr.bottom) && (tr.top < ar.bottom),
        bannerWidth: br.width,
        columnWidth: (document.querySelector('#tc-panel') || {}).clientWidth || 0
      };
    }""")
    check(band is not None, "the hadith banner is not on the page at all")
    if band:
        check(band["sideBySide"],
              "THE HADITH IS STACKED, NOT A BANNER - the Arabic is not beside "
              "its translation: %r" % band)
        #  A banner spans its column. A centred block does not.
        check(band["bannerWidth"] >= band["columnWidth"] * 0.9,
              "the banner does not span the column (%d of %d px), so it reads "
              "as a centred card rather than a band"
              % (round(band["bannerWidth"]), round(band["columnWidth"])))

    #  TONIGHT'S FIGURES ARE THE TEACHER'S OWN, drawn from the fixture rather
    #  than from a number typed in here - the mistake this file's own header
    #  records making with the Students tile.
    tonight = text(pg, "#tc-tonight")
    check(str(MYCLASSES["rows"][0]["on_roll"]) in tonight,
          "tonight does not show the children in this teacher's care: %r" % tonight)
    #  Nobody has marked anybody, so "here tonight" must not be drawn. A
    #  nought before the lesson starts reads as an empty room.
    check("here tonight" not in tonight.lower(),
          "an empty 'here tonight' tile is drawn before any mark is made: %r"
          % tonight)

    #  THE GATE IS EXPLAINED WHERE THEY WILL READ IT, not only on the
    #  register screen they cannot open.
    gate = text(pg, "#tc-gate")
    check("not open yet" in gate.lower() and "330" in gate,
          "the teacher is not told why the register will not open: %r" % gate)

    #  ITEM 1 OF THE SEPT 28 REVIEW. WHEN THE REGISTER IS NOT OPEN, NO
    #  ELEMENT ON THE PAGE INVITES THE TEACHER TO TAKE ONE - not the
    #  Tonight tile, not the line beside "Your classes", not a class
    #  card's action or link. Production had all three, directly beside
    #  #tc-gate's own "there is nothing for you to do about it". Asserted
    #  by WHAT IS ON SCREEN, not by which function was called - a control
    #  proving each one can fail sits in the CONTROLS section below.
    check("still to take" not in tonight.lower()
          and "every register taken" not in tonight.lower(),
          "THE TONIGHT TILE STILL INVITES A REGISTER WHILE THE GATE SAYS IT "
          "IS NOT OPEN: %r" % tonight)
    when_text = text(pg, "#tc-when")
    check(when_text == "",
          "the line beside 'Your classes' still invites a register while "
          "the gate says it is not open: %r" % when_text)
    classes_html = pg.eval_on_selector_all(
        "#tc-classes .tc-class", "els => els.map(e => e.outerHTML)")
    check(classes_html, "no class cards were drawn at all")
    for h in classes_html:
        check("<a" not in h.lower(),
              "A CLASS CARD IS STILL A LINK WHILE THE REGISTER IS NOT OPEN, "
              "and the link goes to a screen that will refuse: %r" % h[:160])
        check("take the register" not in h.lower(),
              "A CLASS CARD STILL INVITES 'TAKE THE REGISTER' WHILE THE "
              "GATE SAYS IT IS NOT OPEN: %r" % h[:160])
    #  AND THE ROLL ITSELF IS STILL THERE - #tc-gate promises the class
    #  list is correct in the meantime, and the fix must not have thrown
    #  the roll out along with the invitation to act on it.
    check(any(MYCLASSES["rows"][0]["name"] in h for h in classes_html),
          "the class card itself is gone, not just its 'take the register' "
          "invitation - #tc-gate promises the roll is still correct: %r"
          % classes_html)

    #  ITEM 1, GEOMETRY. THE GATE IS READ FIRST, since it governs what is
    #  beneath it - a caveat printed underneath what it contradicts is read
    #  second, if at all.
    order = pg.evaluate("""() => {
      var g = document.getElementById('tc-gate'),
          t = document.getElementById('tc-tonight');
      if (!g || !t) return null;
      return g.getBoundingClientRect().top < t.getBoundingClientRect().top;
    }""")
    check(order is True,
          "#tc-gate is not ABOVE the Tonight tiles it governs (top-to-top): %r"
          % order)

    #  TASK 9, RULING A. THE PROMPT MUST NOT APPEAR WHILE THE GATE ABOVE
    #  DOES. This fixture is configured with two real outstanding registers
    #  (MY_OUTSTANDING, above) so this is a genuine control: a version that
    #  drew #tc-outstanding without checking attendance_permitted() first
    #  would show "2 registers are still to hand in" right here, sending a
    #  teacher who was just told "there is nothing for you to do about it"
    #  to a register screen that will refuse them.
    check(not pg.is_visible("#tc-outstanding"),
          "THE OUTSTANDING-REGISTERS PROMPT IS SHOWN WHILE THE REGISTER GATE "
          "SAYS IT IS NOT OPEN - the page now tells the same teacher both "
          "'there is nothing for you to do' and 'take them now', and the "
          "second sends them to a screen that will refuse them: %r"
          % text(pg, "#tc-outstanding"))

    #  AND NO CHILD IS NAMED. This page sits open on a desk in a room people
    #  walk through. Ten children is a fact; these ten children is a record
    #  left on display.
    panel = text(pg, "#tc-panel")
    for word in ("date of birth", "allerg", "medical", "postcode"):
        check(word not in panel.lower(),
              "a teacher's landing page mentions %r, which belongs on a "
              "record and not on a page left open: %r" % (word, panel[:120]))

    rail = text(pg, ".ashell").lower()
    check("admin centre" not in rail,
          "A TEACHER'S RAIL OFFERS THE ADMIN CENTRE, which refuses them: %r"
          % rail[:200])

    #  AND IT MUST NOT BE TOLD TO USE AN AUTHENTICATOR IT HAS NOT GOT.
    #  Teacher logins are password-only by decision - scoped tightly instead
    #  of two-stepped. "Every area asks for your authenticator code" sends a
    #  teacher to ring the office about a code that does not exist.
    check("authenticator" not in rail,
          "a teacher is told every area asks for an authenticator code, which "
          "is false for a password-only login: %r" % rail[-260:])
    check(errs == [], "uncaught exceptions for a teacher: %s" % errs)
    pg.close()

    # =====================================================================
    #  4a. TASK 9 - THE OUTSTANDING-REGISTERS PROMPT, WITH THE REGISTER OPEN
    #
    #  The one state #tc-outstanding is allowed to speak in: every family
    #  told, attendance_permitted() true, #tc-gate empty. MYCLASSES_OPEN is
    #  the same classes as MYCLASSES with only 'permitted' changed, so this
    #  is not a different teacher, only a different evening.
    # =====================================================================
    pg, errs = open_as(b, ["teacher"], myclasses=MYCLASSES_OPEN,
                        outstanding=MY_OUTSTANDING)
    check(pg.is_visible("#tc-gate") is False or text(pg, "#tc-gate") == "",
          "the register-not-open gate is still showing once the register is "
          "open: %r" % text(pg, "#tc-gate"))
    nag = text(pg, "#tc-outstanding")
    check(nag.strip() != "",
          "a teacher with two outstanding registers, register open, is told "
          "nothing")
    check("2" in nag,
          "the prompt does not say how many are outstanding: %r" % nag)
    #  ITEM 2 OF THE SEPT 28 REVIEW. The Tonight tile says "1 register
    #  still to take"; this prompt says "2" for something else. Nothing
    #  told a teacher which was which - so the prompt now names its own
    #  subject ("earlier"), the same way db/112's Today item names its own
    #  window ("in the last fortnight") for the identical reason.
    check("earlier register" in nag.lower(),
          "the prompt does not say it is about EARLIER evenings, so its "
          "'2' reads as a second, disagreeing answer to the Tonight tile's "
          "'1': %r" % nag)
    check("take them now" in nag.lower(),
          "the prompt does not say where to go: %r" % nag)

    #  ITEM 3 OF THE SEPT 28 REVIEW. "A register taken tomorrow is somebody
    #  remembering." lives in ONE place now - said twice on the same
    #  screen it reads as a template that slipped, not as a point.
    whole_page = pg.inner_text("#tc-panel")
    check(whole_page.count("A register taken tomorrow is somebody remembering.") == 1,
          "'A register taken tomorrow is somebody remembering.' appears %d "
          "times on the teacher landing page, not once"
          % whole_page.count("A register taken tomorrow is somebody remembering."))
    check(errs == [], "uncaught exceptions for a teacher with outstanding "
                      "registers: %s" % errs)
    pg.close()

    # =====================================================================
    #  4a-bis. TASK 9, ITEM 2 - THE PROMPT COUNTS THE BACKLOG, NOT THE
    #  BARE TOTAL
    #
    #  MY_OUTSTANDING_WITH_TONIGHT mixes tonight's own register in with two
    #  earlier ones (bare count 3). The prompt must say "2" and "earlier",
    #  not "3" - my_registers_outstanding()'s own window includes tonight,
    #  and the page must not repeat that number under a different name.
    # =====================================================================
    pg, errs = open_as(b, ["teacher"], myclasses=MYCLASSES_OPEN,
                        outstanding=MY_OUTSTANDING_WITH_TONIGHT)
    nag = text(pg, "#tc-outstanding")
    check(nag.strip() != "", "a teacher with a real backlog is told nothing")
    check("2" in nag,
          "the prompt shows the BARE total (3, including tonight) rather "
          "than the backlog (2, excluding it): %r" % nag)
    check("3" not in nag,
          "the prompt shows my_registers_outstanding()'s bare count (3), "
          "which double-counts the same evening the Tonight tile already "
          "names: %r" % nag)
    check(errs == [], "uncaught exceptions for a teacher with a mixed "
                      "backlog: %s" % errs)
    pg.close()

    # =====================================================================
    #  4a-ter. TASK 9, ITEM 2 - SAY NOTHING WHEN THE BACKLOG IS EMPTY
    #
    #  Tonight's own register is the ONLY thing outstanding (bare count 1)
    #  - the prompt must stay silent, not report "1" for a fact the
    #  Tonight tile already states.
    # =====================================================================
    pg, errs = open_as(b, ["teacher"], myclasses=MYCLASSES_OPEN,
                        outstanding=MY_OUTSTANDING_ONLY_TONIGHT)
    check(not pg.is_visible("#tc-outstanding"),
          "the prompt speaks when the only thing outstanding is tonight's "
          "own register, which the Tonight tile already covers: %r"
          % text(pg, "#tc-outstanding"))
    check(errs == [], "uncaught exceptions for a teacher whose only "
                      "outstanding register is tonight's: %s" % errs)
    pg.close()

    # =====================================================================
    #  4b. TASK 9, RULING F - NOTHING OUTSTANDING, REGISTER OPEN
    #
    #  THE REAL NEGATIVE. Register open (so the gate is not the reason), and
    #  my_registers_outstanding() answers zero - the prompt must not appear,
    #  and this is checked with a CONTROL, not an absence nobody looked at:
    #  the control below forces the same box visible by hand and confirms
    #  is_visible() would have caught it if the real page had done that.
    # =====================================================================
    pg, errs = open_as(b, ["teacher"], myclasses=MYCLASSES_OPEN,
                        outstanding=MY_OUTSTANDING_NONE)
    check(not pg.is_visible("#tc-outstanding"),
          "a teacher with NOTHING outstanding is shown the outstanding-"
          "registers prompt anyway: %r" % text(pg, "#tc-outstanding"))
    check(errs == [], "uncaught exceptions for a teacher with nothing "
                      "outstanding: %s" % errs)
    pg.close()
    #  The control proving the assertion above can actually fail lives in
    #  the CONTROLS section below, alongside the other controls (control()
    #  is defined there) - see "the outstanding prompt forced visible".

    # =====================================================================
    #  4c. THE OCTOBER REVIEW - permitted MISSING IS NOT THE SAME AS FINE
    #
    #  MYCLASSES_UNKNOWN: the 'permitted' key is DELETED, not set to False.
    #  Every invitation must still fail closed (drawTonight()'s exact-true
    #  test already guarantees that, and does here too) - but #tc-gate must
    #  NOT be empty, because a locked page with nothing on it reads as
    #  broken, not closed, and "they are not wrong to" go back to paper.
    #  outstanding=MY_OUTSTANDING (non-empty) for the same reason section 4
    #  uses it: a fixture with nothing outstanding would let a broken
    #  #tc-outstanding guard through unnoticed.
    # =====================================================================
    pg, errs = open_as(b, ["teacher"], myclasses=MYCLASSES_UNKNOWN,
                        outstanding=MY_OUTSTANDING)
    tonight_u = text(pg, "#tc-tonight")
    check("still to take" not in tonight_u.lower()
          and "every register taken" not in tonight_u.lower(),
          "THE TONIGHT TILE INVITES A REGISTER WHILE 'permitted' IS MISSING "
          "(NOT known to be allowed): %r" % tonight_u)
    when_u = text(pg, "#tc-when")
    check(when_u == "",
          "the line beside 'Your classes' invites a register while "
          "'permitted' is missing: %r" % when_u)
    classes_html_u = pg.eval_on_selector_all(
        "#tc-classes .tc-class", "els => els.map(e => e.outerHTML)")
    check(classes_html_u, "no class cards were drawn at all")
    for h in classes_html_u:
        check("<a" not in h.lower() and "take the register" not in h.lower(),
              "A CLASS CARD INVITES A REGISTER WHILE 'permitted' IS "
              "MISSING: %r" % h[:160])
    check(not pg.is_visible("#tc-outstanding"),
          "the outstanding-registers prompt is shown while 'permitted' is "
          "missing, which is not known to be open: %r"
          % text(pg, "#tc-outstanding"))

    #  THE FINDING ITSELF. A page with every invitation correctly
    #  suppressed and nothing saying why is the worst of the three
    #  outcomes, not a safe default - so the gate must SPEAK here, with
    #  its own honest line rather than silence or the false-branch
    #  sentence it has no evidence for.
    gate_u = text(pg, "#tc-gate")
    check(gate_u.strip() != "",
          "#TC-GATE IS EMPTY WHILE 'permitted' IS MISSING - the teacher is "
          "shown a locked page (no tile, no line, no class-card link) and "
          "told NOTHING about why, which reads as the system being "
          "broken rather than closed: %r" % gate_u)
    check("330" not in gate_u and "not yet been told" not in gate_u.lower(),
          "the 'permitted missing' gate message invents or reuses the "
          "330-families reason, which this branch has no evidence for: %r"
          % gate_u)
    check("not open" in gate_u.lower(),
          "the 'permitted missing' gate message does not say the register "
          "is not open: %r" % gate_u)
    check(errs == [], "uncaught exceptions for a teacher whose 'permitted' "
                      "is missing: %s" % errs)
    pg.close()
    #  The controls proving these assertions can fail are in the CONTROLS
    #  section below - "... while permitted is missing".

    # =====================================================================
    #  4d. FINAL REVIEW I2 - "DONE" IS HANDED IN, NOT FULLY MARKED
    #
    #  madrasah_my_classes() now sends state (db/118). A teacher who marks
    #  all ten children and presses Save but not Hand-in has NOT finished:
    #  the office is emailed about that class on Monday, and this page used
    #  to say "every register taken - nothing left to do" for it.
    # =====================================================================
    def with_row(**kw):
        d = json.loads(json.dumps(MYCLASSES_OPEN))
        d["rows"][0].update(kw)
        return d

    pg, errs = open_as(b, ["teacher"], myclasses=with_row(marked=10, state="draft"),
                        outstanding=MY_OUTSTANDING_NONE)
    t_d = text(pg, "#tc-tonight")
    check("1 register still to take" in t_d.lower() or "still to take" in t_d.lower(),
          "ALL TEN MARKED BUT NOT HANDED IN, and the Tonight tile does not "
          "say a register is still to take: %r" % t_d)
    check("every register taken" not in t_d.lower(),
          "ALL TEN MARKED BUT NOT HANDED IN reads as 'every register taken': %r" % t_d)
    check(text(pg, "#tc-when").lower().startswith("1 register still to take"),
          "the line beside 'Your classes' says the register is done when it "
          "is only fully marked: %r" % text(pg, "#tc-when"))
    card_d = pg.eval_on_selector_all("#tc-classes .tc-class",
                                     "els => els.map(e => e.outerHTML)")[0]
    check("is-done" not in card_d and "register taken" not in card_d.lower(),
          "a fully marked, not handed in class card looks finished: %r" % card_d[:200])
    check("not handed in" in card_d.lower(),
          "the card does not tell the teacher the last step is still theirs: %r"
          % card_d[:200])
    check(errs == [], "uncaught exceptions, marked-not-handed-in: %s" % errs)
    pg.close()

    pg, errs = open_as(b, ["teacher"], myclasses=with_row(marked=10, state="submitted"),
                        outstanding=MY_OUTSTANDING_NONE)
    t_s = text(pg, "#tc-tonight")
    check("every register taken" in t_s.lower(),
          "a HANDED IN register does not read as done on the landing page: %r" % t_s)
    card_s = pg.eval_on_selector_all("#tc-classes .tc-class",
                                     "els => els.map(e => e.outerHTML)")[0]
    check("is-done" in card_s and "register taken" in card_s.lower(),
          "a handed in class card does not look finished: %r" % card_s[:200])
    pg.close()

    #  A class with nobody on its roll is not due: not "still to take", not
    #  "taken", and not an invitation to a screen that would refuse it.
    pg, errs = open_as(b, ["teacher"], myclasses=with_row(on_roll=0, marked=0),
                        outstanding=MY_OUTSTANDING_NONE)
    t_z = text(pg, "#tc-tonight")
    check("still to take" not in t_z.lower() and "every register taken" not in t_z.lower(),
          "a class with nobody on its roll is counted as a register to take "
          "(or as taken): %r" % t_z)
    card_z = pg.eval_on_selector_all("#tc-classes .tc-class",
                                     "els => els.map(e => e.outerHTML)")[0]
    check("<a" not in card_z.lower(),
          "a class with nobody on its roll invites a register: %r" % card_z[:200])
    pg.close()

    # =====================================================================
    #  4e. FINAL REVIEW C1 - THE BACKLOG STARTS WHEN THE REGISTER OPENED
    # =====================================================================
    on_date = MYCLASSES_OPEN["on_date"]
    #  Opened TONIGHT: nothing earlier to hand in, and it SAYS so instead of
    #  going quiet as if the teacher were caught up.
    pg, errs = open_as(b, ["teacher"], myclasses=MYCLASSES_OPEN, outstanding={
        "allowed": True, "count": 1, "opened_on": on_date, "swallowed": False,
        "note": None,
        "rows": [{"class_id": "c1", "name": "Boys Year 7", "on_date": on_date}]})
    check(pg.is_visible("#tc-outstanding"),
          "the register opened tonight and the page says nothing about it")
    o_t = text(pg, "#tc-outstanding")
    check("opened tonight" in o_t.lower() and "no earlier registers" in o_t.lower(),
          "the opening-night line is wrong: %r" % o_t)
    check("take them now" not in o_t.lower() and "still to hand in" not in o_t.lower(),
          "a teacher is invited to hand in registers that pre-date the "
          "register: %r" % o_t)
    pg.close()

    #  Opened part-way through the window: the database's own sentence about
    #  where the count starts is shown beside the backlog.
    pg, errs = open_as(b, ["teacher"], myclasses=MYCLASSES_OPEN, outstanding={
        "allowed": True, "count": 2, "opened_on": "2026-09-24", "swallowed": False,
        "note": "Counted from 24 September, when the register opened.",
        "rows": [{"class_id": "c9", "name": "Girls Year 4", "on_date": "2026-09-26"},
                 {"class_id": "c9", "name": "Girls Year 4", "on_date": "2026-09-25"}]})
    o_p = text(pg, "#tc-outstanding")
    check("2 earlier registers are still to hand in" in o_p
          and "Counted from 24 September, when the register opened." in o_p,
          "a trimmed backlog does not say where it starts: %r" % o_p)
    pg.close()

    # ------------------------------------------------------------------
    #  THE PASSWORD GATE COVERS THE PAGE, ON THIS PAGE.
    #
    #  Every teacher login is created with a password somebody else chose and
    #  wrote on a slip, so the first thing a teacher meets is this gate. On
    #  28 September the first one to sign in met it spread across the whole
    #  window with its left third underneath the rail, the portal drawn
    #  underneath it, and the rail still offering Admin Centre.
    #
    #  It looked right on the generated screens, because THEY load
    #  admin/screen.css, which is where .pw-gate's width lives, and a screen
    #  stylesheet, which is where [hidden]{display:none!important} lives.
    #  This page loads neither. The gate was styled by files it could not
    #  count on and hid things with an attribute nothing was honouring.
    #
    #  So these assertions are about GEOMETRY, not markup. "The overlay
    #  exists" would have passed on the broken version.
    pg, errs = open_as(b, ["teacher"], must_change=True)
    box = pg.evaluate("""() => {
      var s = document.getElementById('pw-shade');
      if (!s) return null;
      var r = s.getBoundingClientRect();
      var c = document.getElementById('pw-gate');
      var cr = c ? c.getBoundingClientRect() : null;
      var rail = document.querySelector('.ashell, .shell');
      return {
        shade: {x:r.left, y:r.top, w:r.width, h:r.height},
        card:  cr ? {x:cr.left, w:cr.width} : null,
        vw: window.innerWidth, vh: window.innerHeight,
        railVisible: !!(rail && rail.getBoundingClientRect().width > 0
                        && getComputedStyle(rail).display !== 'none'),
        topAtCentre: (function(){
          var e = document.elementFromPoint(window.innerWidth/2, window.innerHeight/2);
          while (e) { if (e.id === 'pw-shade') return 'gate'; e = e.parentElement; }
          return 'NOT THE GATE';
        })(),
        topAtRail: (function(){
          var e = document.elementFromPoint(60, window.innerHeight/2);
          while (e) { if (e.id === 'pw-shade') return 'gate'; e = e.parentElement; }
          return 'NOT THE GATE';
        })()
      };
    }""")
    check(box is not None, "a teacher with must_change_password sees no password gate")
    if box:
        check(box["shade"]["w"] >= box["vw"] - 2 and box["shade"]["h"] >= box["vh"] - 2,
              "THE GATE DOES NOT COVER THE WINDOW: %sx%s over a %sx%s viewport"
              % (round(box["shade"]["w"]), round(box["shade"]["h"]),
                 box["vw"], box["vh"]))
        check(box["shade"]["x"] <= 0 and box["shade"]["y"] <= 0,
              "the gate does not start at the top left: %r" % box["shade"])
        #  The bug in one assertion: the card must be a card, not the width
        #  of the window with its left edge behind the rail.
        check(box["card"] and box["card"]["w"] <= 600,
              "THE GATE CARD IS NOT A CARD - it is %s px wide, which means "
              "admin/screen.css is not loaded and it has no max-width"
              % (round(box["card"]["w"]) if box["card"] else "missing"))
        check(box["card"] and box["card"]["x"] > 0,
              "the gate card starts at or left of x=0, so it is cut off")
        #  What is actually on top where the rail used to be.
        check(box["topAtRail"] == "gate",
              "SOMETHING ELSE IS ON TOP WHERE THE RAIL IS: %s" % box["topAtRail"])
        check(box["topAtCentre"] == "gate",
              "something else is on top in the middle of the page: %s"
              % box["topAtCentre"])
        check(not box["railVisible"],
              "the rail is still visible behind the password gate")
    #  AND NOTHING BEHIND IT IS STILL RENDERED.
    #
    #  Asked as computed display, not as text. The first version of this
    #  assertion read inner_text("#md-panel") and failed against a panel that
    #  was correctly display:none - because innerText falls back to
    #  textContent on an element that is not rendered. The check was wrong,
    #  not the page, which is the fourth time that happened in one evening.
    #
    #  Asking "is anything beside the gate still displayed" also catches the
    #  containers a list of class names would miss, which is how .md-lead and
    #  .tc-classes stayed visible behind the first fix.
    left = pg.evaluate("""() => {
      var out = [];
      var sib = document.body.children;
      for (var i = 0; i < sib.length; i++) {
        var n = sib[i];
        if (n.id === 'pw-shade') continue;
        if (n.tagName === 'SCRIPT' || n.tagName === 'STYLE') continue;
        if (getComputedStyle(n).display !== 'none') {
          out.push(n.tagName.toLowerCase() + (n.id ? '#' + n.id : '') +
                   (n.className ? '.' + String(n.className).split(' ')[0] : ''));
        }
      }
      return out;
    }""")
    check(left == [],
          "STILL RENDERED BEHIND THE PASSWORD GATE: %s" % left)
    #  THE CURRENT PASSWORD IS ASKED FOR, AND ACTUALLY SENT.
    #
    #  Supabase is configured to require the current password when setting a
    #  new one, and the first version of this gate did not ask for it. The
    #  teacher got "Current password required when setting new password" and
    #  could go no further. Keeping that setting is right - these screens open
    #  on a shared office machine, and without it anyone finding a signed-in
    #  session owns the account - so the gate has to satisfy it.
    #
    #  Asserting the FIELD EXISTS would not have caught the bug it is here to
    #  prevent, which is the value never reaching the API. So fill the form in
    #  and check what updateUser was actually handed.
    check(pg.query_selector("#pw-now") is not None,
          "the gate does not ask for the current password, so Supabase will "
          "refuse the change")
    pg.fill("#pw-now", "TheSlipPassword1")
    pg.fill("#pw-one", "three unrelated words")
    pg.fill("#pw-two", "three unrelated words")
    pg.click("#pw-go")
    pg.wait_for_timeout(400)
    sent = pg.evaluate("() => window.__UPDATED || null")
    check(sent is not None, "pressing Save did not call updateUser at all")
    if sent:
        check(sent.get("password") == "three unrelated words",
              "the new password did not reach updateUser: %r" % sent)
        #  SNAKE CASE, and the case is the whole assertion.
        #
        #  The first version of this checked for "currentPassword" and passed,
        #  because the page did send that - and the change still failed live.
        #  The API is Go and its field is
        #      CurrentPassword *string `json:"current_password,omitempty"`
        #  so current_password is the only spelling it reads. The vendored
        #  client does no camelCase mapping; it forwards the attributes object
        #  verbatim. A green test and a broken screen, over one underscore.
        check(sent.get("current_password") == "TheSlipPassword1",
              "current_password (SNAKE CASE) was not sent, so the API will "
              "refuse the change: %r" % sent)
        check("currentPassword" not in sent,
              "camelCase currentPassword is being sent; the API does not read "
              "it and the vendored client does not convert it: %r" % sent)

    check(errs == [], "uncaught exceptions at the password gate: %s" % errs)
    pg.close()

    # =====================================================================
    #  4b. A PARENT
    # =====================================================================
    pg, errs = open_as(b, ["parent"])
    check(pg.is_visible("#pa-panel"), "a parent was not shown the parents' page")
    check(not pg.is_visible("#md-panel"), "A PARENT WAS SHOWN THE ADMINISTRATOR'S CONSOLE")
    check(not pg.is_visible("#tc-panel"), "a parent was shown the teachers' page")
    items = pg.eval_on_selector_all("#pa-list .rl-item", "els => els.map(e => e.innerText)")
    check(len(items) >= 6, "the parents' page lists only %d things" % len(items))
    joined = " ".join(items).lower()
    for want in ["fee", "absent", "collect"]:
        check(want in joined, "the parents' page does not mention %r: %r" % (want, joined[:300]))
    check("coming soon" in text(pg, "#pa-panel").lower(),
          "the parents' page does not say it is not open yet")
    #  The one thing a parent needs while it is not open.
    check("01204" in text(pg, "#pa-panel"),
          "the parents' page does not say how to reach the office in the meantime")
    check(not pg.is_visible("#app-top-back"),
          "a parent is offered a link to the admin centre, which refuses them")
    check(errs == [], "uncaught exceptions for a parent: %s" % errs)
    pg.close()

    # =====================================================================
    #  Somebody who is BOTH. An administrator who also teaches is here to
    #  administer — otherwise the console becomes unreachable for the person
    #  most likely to hold both roles.
    # =====================================================================
    pg, errs = open_as(b, ["admin", "teacher"])
    check(pg.is_visible("#md-panel"),
          "an administrator who also teaches was sent to the teachers' page and "
          "cannot reach the console at all")
    check(not pg.is_visible("#tc-panel"), "both pages were shown at once")
    pg.close()

    # =====================================================================
    #  6. NEITHER
    # =====================================================================
    pg, errs = open_as(b, ["hall_office"])
    check(pg.is_visible("#app-noaccess"),
          "an account with no madrasah role is not told why there is nothing here")
    for sel in ["#md-panel", "#tc-panel", "#pa-panel"]:
        check(not pg.is_visible(sel), "%s was shown to an account with no madrasah role" % sel)
    check(not pg.evaluate("document.querySelector('.shell').classList.contains('wide-mode')"),
          "the page went full width for an account with nothing to show")
    check(errs == [], "uncaught exceptions for an account with no role: %s" % errs)
    pg.close()

    # =====================================================================
    #  IT SURVIVES A PHONE
    # =====================================================================
    for roles in (["admin"], ["parent"]):
        pg, errs = open_as(b, roles)
        for w in [1400, 900, 390]:
            pg.set_viewport_size({"width": w, "height": 1000})
            pg.wait_for_timeout(250)
            check(pg.evaluate("document.documentElement.scrollWidth") <= w + 2,
                  "the %s view scrolls sideways at %dpx" % (roles[0], w))
        check(errs == [], "uncaught exceptions while resizing: %s" % errs)
        pg.close()

    # =====================================================================
    #  CONTROLS — do the assertions bite?
    # =====================================================================
    def control(name, roles, script, before, after):
        pg, _ = open_as(b, roles)
        was = before(pg)
        pg.evaluate(script)
        pg.wait_for_timeout(200)
        if before(pg) == was:
            fails.append("CONTROL '%s' changed nothing, so it proves nothing" % name)
        elif not after(pg):
            fails.append("CONTROL '%s' did not bite" % name)
        pg.close()

    control("the caveat stripped off the count tiles", ["admin"],
            "document.querySelectorAll('#md-counts .s b').forEach(e => e.remove())",
            lambda pg: text(pg, "#md-counts"),
            lambda pg: not all("not imported" in t.lower() for t in pg.eval_on_selector_all(
                "#md-counts .md-count", "els => els.map(e => e.innerText)")))

    control("a link put on a count tile", ["admin"],
            """(() => {
                 const t = document.querySelector('#md-counts .md-count');
                 const a = document.createElement('a');
                 a.href = '#'; a.textContent = 'Open';
                 t.appendChild(a);
               })()""",
            lambda pg: pg.eval_on_selector_all("#md-counts a, #md-counts button", "e => e.length"),
            lambda pg: pg.eval_on_selector_all(
                "#md-counts a, #md-counts button, #md-areas a, #md-areas button",
                "e => e.length") > 0)

    control("'coming soon' removed from the parents' page", ["parent"],
            "document.querySelector('#pa-panel .rl-soon h3').textContent = 'Notes'",
            lambda pg: text(pg, "#pa-panel"),
            lambda pg: "coming soon" not in text(pg, "#pa-panel").lower())

    #  TASK 9, RULING F. Proves the "nothing outstanding -> no prompt"
    #  assertion (section 4b, above) is a real check and not an absence
    #  nobody looked at: this fixture (default teacher, nothing outstanding
    #  configured) already has #tc-outstanding hidden, exactly like 4b, so
    #  forcing it visible by hand is exactly the failure 4b exists to catch.
    control("the outstanding prompt forced visible with nothing outstanding",
            ["teacher"],
            "var b=document.getElementById('tc-outstanding'); "
            "if(b){b.hidden=false; b.textContent='forced for the control';}",
            lambda pg: pg.is_visible("#tc-outstanding"),
            lambda pg: pg.is_visible("#tc-outstanding"))

    #  ITEM 1 OF THE SEPT 28 REVIEW. Proves each of the three "no
    #  invitation while the register is not open" assertions (section 4,
    #  above) is a real check and not an absence nobody looked at. All
    #  three use the default teacher fixture (register not open), which is
    #  exactly what section 4 examines.
    control("the Tonight tile forced back on while the register is not open",
            ["teacher"],
            "document.getElementById('tc-tonight').insertAdjacentHTML("
            "'beforeend', '<div class=\"md-count\"><span class=\"k\">"
            "register still to take</span></div>');",
            lambda pg: text(pg, "#tc-tonight"),
            lambda pg: "still to take" in text(pg, "#tc-tonight").lower())

    control("the 'Your classes' line forced back on while the register is "
            "not open",
            ["teacher"],
            "document.getElementById('tc-when').textContent = "
            "'1 register still to take';",
            lambda pg: text(pg, "#tc-when"),
            lambda pg: "still to take" in text(pg, "#tc-when").lower())

    control("a class card forced back into a 'Take the register' link "
            "while the register is not open",
            ["teacher"],
            "(function(){"
            "var c = document.querySelector('#tc-classes .tc-class');"
            "if (!c) return;"
            "var a = document.createElement('a');"
            "a.className = c.className; a.href = 'register/';"
            "a.innerHTML = c.innerHTML + "
            "'<span class=\"tc-state\">Take the register</span>';"
            "c.parentNode.replaceChild(a, c);"
            "})();",
            lambda pg: pg.eval_on_selector_all(
                "#tc-classes .tc-class", "els => els.map(e => e.outerHTML).join('')"),
            lambda pg: "take the register" in pg.eval_on_selector_all(
                "#tc-classes .tc-class",
                "els => els.map(e => e.outerHTML).join('')").lower())

    #  THE OCTOBER REVIEW. Same three "no invitation" controls as above,
    #  now run against MYCLASSES_UNKNOWN (permitted missing, not False) -
    #  proving section 4c's assertions are real checks on this exact
    #  fixture, not just inherited from section 4's.
    def open_unknown():
        return open_as(b, ["teacher"], myclasses=MYCLASSES_UNKNOWN,
                        outstanding=MY_OUTSTANDING)

    def control_unknown(name, script, before, after):
        pg, _ = open_unknown()
        was = before(pg)
        pg.evaluate(script)
        pg.wait_for_timeout(200)
        if before(pg) == was:
            fails.append("CONTROL '%s' changed nothing, so it proves nothing" % name)
        elif not after(pg):
            fails.append("CONTROL '%s' did not bite" % name)
        pg.close()

    control_unknown(
        "the Tonight tile forced back on while permitted is missing",
        "document.getElementById('tc-tonight').insertAdjacentHTML("
        "'beforeend', '<div class=\"md-count\"><span class=\"k\">"
        "register still to take</span></div>');",
        lambda pg: text(pg, "#tc-tonight"),
        lambda pg: "still to take" in text(pg, "#tc-tonight").lower())

    control_unknown(
        "the outstanding prompt forced visible while permitted is missing",
        "var b=document.getElementById('tc-outstanding'); "
        "if(b){b.hidden=false; b.textContent='forced for the control';}",
        lambda pg: pg.is_visible("#tc-outstanding"),
        lambda pg: pg.is_visible("#tc-outstanding"))

    control_unknown(
        "a class card forced back into a 'Take the register' link while "
        "permitted is missing",
        "(function(){"
        "var c = document.querySelector('#tc-classes .tc-class');"
        "if (!c) return;"
        "var a = document.createElement('a');"
        "a.className = c.className; a.href = 'register/';"
        "a.innerHTML = c.innerHTML + "
        "'<span class=\"tc-state\">Take the register</span>';"
        "c.parentNode.replaceChild(a, c);"
        "})();",
        lambda pg: pg.eval_on_selector_all(
            "#tc-classes .tc-class", "els => els.map(e => e.outerHTML).join('')"),
        lambda pg: "take the register" in pg.eval_on_selector_all(
            "#tc-classes .tc-class",
            "els => els.map(e => e.outerHTML).join('')").lower())

    #  THE NEW GUARD ITSELF. #tc-gate not empty (section 4c) is the
    #  assertion this whole review turn exists for - prove it can fail by
    #  emptying the gate by hand and confirming the check would have
    #  caught a version that went back to silence on the 'missing' branch.
    control_unknown(
        "#tc-gate emptied while permitted is missing",
        "var g=document.getElementById('tc-gate'); "
        "if(g){g.textContent=''; g.hidden=true;}",
        lambda pg: text(pg, "#tc-gate"),
        lambda pg: text(pg, "#tc-gate").strip() == "")

    b.close()

httpd.shutdown()

#  The report itself is _report(), registered with atexit at the top, so it
#  prints whether this file finished or fell over. All that happens here is
#  saying it DID finish - which is the difference between "ALL PASS" and
#  "DID NOT FINISH", and the distinction that was missing when a KeyError
#  made a run with ten failures look like a clean one.
_report.reached_end = True
sys.exit(1 if fails else 0)
