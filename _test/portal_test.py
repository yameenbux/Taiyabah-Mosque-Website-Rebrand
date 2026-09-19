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
JOBS_LIVE = ["dbs", "main_teacher", "days"]
JOBS_QUIET = ["no_class", "side", "admissions", "purge"]


def stub(roles):
    return """
(function(){
  var ROLES = %s, OV = %s;
  var client = {
    auth: {
      getSession: function(){ return Promise.resolve({data:{session:{
        access_token:'t', user:{id:'u1', email:'someone@example.test'}}}}); },
      getUser: function(){ return Promise.resolve({data:{user:{
        id:'u1', email:'someone@example.test'}}}); },
      signOut: function(){ return Promise.resolve({}); },
      updateUser: function(){ return Promise.resolve({data:{},error:null}); },
      mfa: { getAuthenticatorAssuranceLevel: function(){
               return Promise.resolve({data:{currentLevel:'aal2', nextLevel:'aal2'}}); },
             listFactors: function(){ return Promise.resolve({data:{totp:[{id:'f1'}]}}); } }
    },
    from: function(t){
      var rows = t === 'profiles' ? {full_name:'A Person', email:'someone@example.test'}
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
      if (n === 'madrasah_overview') return Promise.resolve({data: OV, error:null});
      return Promise.resolve({data:{}, error:null});
    }
  };
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}}, writable:false, configurable:false});
})();
""" % (json.dumps(roles), json.dumps(OVERVIEW))


def open_as(b, roles, w=1400, h=1200):
    pg = b.new_page(viewport={"width": w, "height": h})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.add_init_script(stub(roles))
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
    #  3. WHAT NEEDS DOING IS A LIST OF JOBS, AND NOUGHTS ARE NOT DRAWN
    # =====================================================================
    jobs = pg.eval_on_selector_all("#md-doing .md-job",
                                   "els => els.map(e => e.getAttribute('data-job'))")
    check(sorted(jobs) == sorted(JOBS_LIVE),
          "the jobs drawn are %r, expected %r" % (sorted(jobs), sorted(JOBS_LIVE)))
    for q in JOBS_QUIET:
        check(q not in jobs,
              "a job with nothing in it (%r) was drawn anyway. Seven tiles "
              "reading nought is a screen people stop reading, and then they "
              "stop seeing the two that matter." % q)

    #  SAFEGUARDING IS FIRST. Decided by rank in the page, not by where a field
    #  happens to sit in the JSON.
    check(jobs and jobs[0] == "dbs",
          "DBS is not the first job on the screen: %r" % jobs)

    #  EACH JOB CARRIES ITS NUMBER AND SOMEWHERE TO GO. A dashboard that names
    #  a problem and leaves you to find the screen is a worse note on a fridge.
    detail = pg.eval_on_selector_all("#md-doing .md-job", """els => els.map(e => ({
        job: e.getAttribute('data-job'),
        n: (e.querySelector('.md-job-n')||{}).innerText,
        t: (e.querySelector('.md-job-t')||{}).innerText,
        go: (e.querySelector('.md-job-go')||{}).getAttribute
              ? e.querySelector('.md-job-go').getAttribute('href') : null }))""")
    want_n = {"dbs": len(OVERVIEW["dbs_needs_attention"]),
              "main_teacher": OVERVIEW["classes_no_main_teacher"],
              "days": OVERVIEW["staff_without_days"]}
    for d in detail:
        #  .get() and not [], because an UNEXPECTED job is precisely what the
        #  check above is looking for — and looking it up with [] turns that
        #  finding into a KeyError that kills the run. Found the hard way.
        if d["job"] not in want_n:
            check(False, "an unexpected job %r is on the screen" % d["job"])
            continue
        check(d["n"].strip() == str(want_n[d["job"]]),
              "the %s job shows %r, the database said %s"
              % (d["job"], d["n"], want_n[d["job"]]))
        check(d["go"], "the %s job has nowhere to go" % d["job"])
    dbs = [d for d in detail if d["job"] == "dbs"]
    check(dbs and "21 of 40" in dbs[0]["t"],
          "the DBS job does not read as a sentence with both numbers in it: %r"
          % (dbs or [{}])[0].get("t"))

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
        done: e.classList.contains('md-done'),
        t: e.innerText }))""")
    check(len(items) >= 5, "the data-protection list has only %d items" % len(items))
    done = [i for i in items if i["done"]]
    todo = [i for i in items if not i["done"]]
    check(done, "NOTHING is marked done, on a system that has already imported "
                "543 pupil records — so the list is describing a gate it is "
                "standing on the far side of")
    check(todo, "EVERYTHING is marked done. Two items were still open when this "
                "was written and nobody has said otherwise; marking them done "
                "because the rest are is the failure this list exists to avoid")

    #  DONE ITEMS ARE NOT DELETED. A finished item removed takes its evidence
    #  with it, and the next person to ask "did we ever do the DPIA?" has
    #  nothing to read.
    joined = " ".join(i["t"] for i in items).lower()
    #  "dpia" was in this list until the item was retitled "data protection
    #  impact assessment" in full - which is better English on a screen a
    #  trustee reads, and broke a check looking for the acronym. Both spellings
    #  are accepted so the test is about the SUBJECT being covered, not about
    #  which of two names for the same thing the screen happens to use.
    check("dpia" in joined or "impact assessment" in joined,
          "the data-protection list no longer mentions the impact assessment "
          "at all: %r" % joined[:300])
    for want in ["privacy notice", "ico", "article 9", "aal2"]:
        check(want in joined,
              "%r is no longer anywhere in the data-protection list: %r"
              % (want, joined[:300]))

    #  AND THE HEADING COUNTS WHAT IS LEFT, so somebody reads the number
    #  rather than the whole list.
    head = text(pg, "#md-before-h").lower()
    check(str(len(todo)) in head or "outstanding" in head,
          "the data-protection heading does not say how much is left: %r" % head)

    check(errs == [], "uncaught exceptions for an administrator: %s" % errs)
    pg.close()

    # =====================================================================
    #  4. A TEACHER
    # =====================================================================
    pg, errs = open_as(b, ["teacher"])
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
    check(errs == [], "uncaught exceptions for a teacher: %s" % errs)
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

    b.close()

httpd.shutdown()

#  The report itself is _report(), registered with atexit at the top, so it
#  prints whether this file finished or fell over. All that happens here is
#  saying it DID finish - which is the difference between "ALL PASS" and
#  "DID NOT FINISH", and the distinction that was missing when a KeyError
#  made a run with ten failures look like a clean one.
_report.reached_end = True
sys.exit(1 if fails else 0)
