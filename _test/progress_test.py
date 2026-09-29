"""Progress - the teacher's screen and the parent's, driven against a stubbed database.

WHAT THIS SUITE IS FOR

db/127 proves what lives in Postgres, in a rolled-back proof inside the
migration, run as the real test teacher and the real test parent: that a
teacher writes an entry with both notes and does NOT share it, and the parent
sees nothing; that sharing shows the parent the parent note and NEVER the
internal one (checked in the returned data, and by reading the installed
definition of parent_progress() and asserting the column's name is not in it);
that a teacher cannot reach a child outside their classes, a parent cannot
reach another household's child, and anon reaches nothing. It cannot see the
screens. This asserts what they SAY:

  TEACHER
  * a role-less account is refused and nothing is fetched;
  * before anything is typed the screen says there are two kinds of note and
    that the teacher's own is never shown to a family;
  * two classes are two choices and nothing is fetched for a class until it is
    chosen; one class opens itself;
  * the list says whether (how many entries, how many shared, when last) and
    the child says what;
  * the form has a note for the parent and an own note, the own note is marked
    "staff only", and the choice to share is two radio buttons that each say
    what they do and starts on "Only staff" for a new entry;
  * saving sends exactly the choice made (p_shared false / true, p_id null / the
    entry's id) and says in words whether the family can now read it;
  * an entry with nothing in it, and an entry with only an own note that is
    being shared, are not sent and are told why;
  * the database's own refusals (22023) are shown as written and the typing is
    kept; {allowed:false} is a sentence, not an empty list;
  * amending an entry fills the form with what it holds and re-selects its
    share state;
  * a note is escaped.

  PARENT
  * shared entries are drawn newest first as given, with the date, the
    teacher's name, the class, sabaq, sabqi and manzil, and the note for them;
  * the parent screen calls parent_progress and nothing on the staff side, and
    a fixture that smuggles a staff-only key into the answer proves the screen
    draws only what it names;
  * nothing shared is SAID, with "not a judgement", not left as a blank page;
  * two children, two sections, one call each with that child's id;
  * a login that is not a parent's is told so; a technical error never is shown.

  BOTH
  * the generated files are what the generators make now; ES5; [hidden] first;
    the rails; the teacher's landing tile is real and is a link; no sideways
    scroll at 390px; every fixture has exactly the key set the live functions
    return (asserted by db/127's proof).

WHAT IT CANNOT PROVE. The stub answers as db/127's functions do and refuses in
their words. It is not the database. HTTP sign-in against the real auth service
has not been run from here.

    python3 _test/progress_test.py
    PRG_SERVE_ROOT=<a copy of the repo with one line changed> python3 _test/progress_test.py
        (_test/progress_mutants.py does that, to prove this can fail)
"""
import atexit
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
SERVE = os.environ.get("PRG_SERVE_ROOT") or ROOT
sys.path.insert(0, os.path.join(ROOT, "tools"))


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(("127.0.0.1", 0),
                               lambda *a: Quiet(*a, directory=SERVE))
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


OFFICE = "01204 535 997"

# Key sets the live functions return (asserted by db/127's proof).
LIVE = {
    "class": "children,id,name",
    "kid": "entries,first_name,last_name,last_on,pupil_id,shared",
    "staff_entry": "id,manzil,note_for_parent,note_internal,on_date,sabaq,sabqi,shared,updated_at,written_at,written_by_name",
    "parent_entry": "class,manzil,note,on_date,sabaq,sabqi,teacher",
}


def keys(d):
    return ",".join(sorted(d))


# NO REAL CHILD, FAMILY OR PERSON APPEARS IN THIS FILE.
SECRET = "ZZ-SECRET-WORKING-NOTE"
FORP = "Aaliyah read with real care this week. Please listen to her once a day."
HTML = "<b>bold</b> & <script>window.__pwned=1</script>"


def kid(i, first, last, entries=0, shared=0, last_on=None):
    return {"pupil_id": "p%d" % i, "first_name": first, "last_name": last,
            "entries": entries, "shared": shared, "last_on": last_on}


def sentry(i, on, shared, sabaq="Surah al-Mulk, verses 1-10", sabqi="Surah an-Naba, 1-15",
           manzil="Juz Amma", forp=FORP, mine=SECRET, by="Mr Proofteacher Alpha"):
    return {"id": "e%d" % i, "on_date": on, "sabaq": sabaq, "sabqi": sabqi, "manzil": manzil,
            "note_for_parent": forp, "note_internal": mine, "shared": shared,
            "written_at": "%sT17:30:00+00:00" % on, "updated_at": "%sT17:30:00+00:00" % on,
            "written_by_name": by}


def pentry(on, sabaq="Surah al-Mulk, verses 1-10", sabqi="Surah an-Naba, 1-15", manzil="Juz Amma",
           note=FORP, teacher="Mr Proofteacher Alpha", klass="ZZ TEST CLASS"):
    return {"on_date": on, "sabaq": sabaq, "sabqi": sabqi, "manzil": manzil,
            "note": note, "class": klass, "teacher": teacher}


CLASSES = [{"id": "c1", "name": "ZZ Proof Class One", "children": 2},
           {"id": "c2", "name": "ZZ Proof Class Two", "children": 1}]
KIDS_1 = {"allowed": True, "class": {"id": "c1", "name": "ZZ Proof Class One"},
          "children": [kid(1, "Proofchilda", "Zzzone", 2, 1, "2026-09-26"),
                       kid(2, "Proofchildb", "Zzzone", 0, 0, None)]}
KIDS_2 = {"allowed": True, "class": {"id": "c2", "name": "ZZ Proof Class Two"},
          "children": [kid(3, "Proofchildc", "Zzztwo", 0, 0, None)]}
ENTRIES_A = [sentry(2, "2026-09-26", True), sentry(1, "2026-09-19", False, forp="Needs to slow down.", by="Mr Proofteacher Alpha")]


def child_answer(first, last, cls_id, cls_name, entries):
    return {"allowed": True, "child": {"first_name": first, "last_name": last},
            "class": {"id": cls_id, "name": cls_name}, "entries": entries}


# ---------------------------------------------------------------------------
def stub(fixture):
    return """
(function(){
  var F=%s;
  window.__calls=[]; window.__auth=[]; window.__tables=[];
  var signedIn=true;
  var USER={id:'u1',email:'x@example.test'};
  var seqIx={};
  var client={
    auth:{
      getSession:function(){ return Promise.resolve({data:{session:signedIn?{access_token:'t',user:USER}:null}}); },
      getUser:function(){ return Promise.resolve({data:{user:signedIn?USER:null}}); },
      signInWithPassword:function(){ signedIn=true; return Promise.resolve({data:{user:USER},error:null}); },
      signOut:function(){ signedIn=false; return Promise.resolve({}); },
      onAuthStateChange:function(){ return {data:{subscription:{unsubscribe:function(){}}}}; },
      mfa:{
        getAuthenticatorAssuranceLevel:function(){ window.__auth.push('mfa'); return Promise.resolve({data:{currentLevel:F.aal||'aal1',nextLevel:F.aal||'aal1'},error:null}); },
        listFactors:function(){ window.__auth.push('mfa'); return Promise.resolve({data:{totp:F.aal==='aal2'?[{id:'f1'}]:[]},error:null}); },
        enroll:function(){ return Promise.resolve({error:{message:'no'}}); },
        challenge:function(){ return Promise.resolve({error:{message:'no'}}); }
      }
    },
    from:function(t){
      window.__tables.push(t);
      var rows = t==='profiles' ? {full_name:'A Person',email:'x@example.test',must_change_password:false}
                                : (F.roles||[]).map(function(r){ return {role:r}; });
      var q={ select:function(){return q;}, eq:function(){return q;},
              maybeSingle:function(){return Promise.resolve({data:rows,error:null});},
              then:function(f){return Promise.resolve({data:rows,error:null}).then(f);} };
      return q;
    },
    rpc:function(name,args){
      window.__calls.push({name:name,args:JSON.parse(JSON.stringify(args||{}))});
      var E=(F.errors||{})[name];
      if (E) return Promise.resolve({data:null,error:E});
      var R=(F.answers||{})[name];
      if (typeof R==='undefined') return Promise.resolve({data:null,error:{code:'42883',message:'unstubbed '+name}});
      if (R && R.__by) return Promise.resolve({data:JSON.parse(JSON.stringify(R.__by[args[R.key]] || {allowed:false})),error:null});
      if (R && R.__seq) { var i=seqIx[name]||0; seqIx[name]=i+1; return Promise.resolve({data:JSON.parse(JSON.stringify(R.__seq[Math.min(i,R.__seq.length-1)])),error:null}); }
      return Promise.resolve({data:JSON.parse(JSON.stringify(R)),error:null});
    }
  };
  Object.defineProperty(window,'supabase',
    {value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % json.dumps(fixture)


def open_page(browser, path, fixture, width=1280, height=900):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.add_init_script(stub(fixture))
    pg.goto(BASE + path, wait_until="networkidle")
    pg.wait_for_timeout(450)
    return pg


def calls(pg, name):
    return [c for c in pg.evaluate("() => window.__calls") if c["name"] == name]


def all_calls(pg):
    return [c["name"] for c in pg.evaluate("() => window.__calls")]


def text(pg, sel):
    """inner_text with runs of whitespace collapsed: the source wraps lines."""
    return re.sub(r"\s+", " ", pg.inner_text(sel)).strip()


def no_sideways_scroll(pg):
    return pg.evaluate("() => document.documentElement.scrollWidth <= "
                       "document.documentElement.clientWidth + 1")


def teacher_fx(classes=None, **over):
    classes = CLASSES if classes is None else classes
    #  aal2 because the staff shell routes anybody without a verified factor to
    #  enrolment (the register's own suite stubs it the same way).
    base = {"roles": ["teacher"], "aal": "aal2",
            "answers": {"progress_my_classes": {"allowed": True, "classes": classes},
                        "progress_class_children": {"__by": {"c1": KIDS_1, "c2": KIDS_2}, "key": "p_class"},
                        "progress_child": {"__by": {
                            "p1": child_answer("Proofchilda", "Zzzone", "c1", "ZZ Proof Class One", ENTRIES_A),
                            "p2": child_answer("Proofchildb", "Zzzone", "c1", "ZZ Proof Class One", []),
                            "p3": child_answer("Proofchildc", "Zzztwo", "c2", "ZZ Proof Class Two", [])},
                            "key": "p_pupil"},
                        "progress_save": {"allowed": True, "id": "e9", "shared": False}},
            "errors": {}}
    base.update(over)
    return base


def parent_fx(progress=None, kids=None, **over):
    kids = kids or [{"pupil_id": "p1", "first_name": "Proofchilda"}]
    progress = progress or {"p1": {"first_name": "Proofchilda",
                                   "entries": [pentry("2026-09-26"),
                                               pentry("2026-09-19", sabaq="Surah al-Qalam, 1-8", sabqi=None, manzil=None,
                                                      note=None, teacher=None)]}}
    base = {"roles": [], "aal": "aal1",
            "answers": {"parent_my_children": {"family_reference": "MF-000000", "children": kids},
                        "parent_progress": {"__by": progress, "key": "p_pupil"}},
            "errors": {}}
    base.update(over)
    return base


def es5_ok(path):
    acorn = shutil.which("acorn")
    if acorn:
        r = subprocess.run([acorn, "--ecma5", "--silent", path], capture_output=True, text=True)
        return r.returncode == 0, (r.stderr or "").strip()[:160]
    src = re.sub(r"/\*.*?\*/", "", open(path, encoding="utf-8").read(), flags=re.S)
    bad = [p for p in (r"=>", r"`", r"(?<![\w.$])const\s", r"(?<![\w.$])let\s") if re.search(p, src)]
    return not bad, bad


def run():
    # ============ THE FIXTURES ARE THE LIVE SHAPES ============
    check("fixture: a class has exactly the live keys", keys(CLASSES[0]) == LIVE["class"], keys(CLASSES[0]))
    check("fixture: a class child has exactly the live keys", keys(KIDS_1["children"][0]) == LIVE["kid"], keys(KIDS_1["children"][0]))
    check("fixture: a staff entry has exactly the live keys", keys(sentry(1, "2026-09-19", True)) == LIVE["staff_entry"], keys(sentry(1, "2026-09-19", True)))
    check("fixture: a parent's entry has exactly the live keys", keys(pentry("2026-09-19")) == LIVE["parent_entry"], keys(pentry("2026-09-19")))
    check("fixture: the parent's entry does NOT carry the staff-only key", "note_internal" not in pentry("2026-09-19"))

    # ============ THE GENERATED FILES ARE WHAT THE GENERATORS MAKE ============
    import screen_builder as SB
    import build_progress_screen as BG
    import build_parent_screens as BP
    scr = BG.SCREEN
    check("portal/progress/index.html is what the generator makes now",
          SB.build_html(scr) == open(os.path.join(ROOT, "portal/progress/index.html"), encoding="utf-8").read())
    check("portal/progress/app.js is what the generator makes now",
          SB.build_js(scr) == open(os.path.join(ROOT, "portal/progress/app.js"), encoding="utf-8").read())
    pp = [s for s in BP.SCREENS if s.folder == "parent/progress"]
    check("the parent screens include Progress", len(pp) == 1)
    if pp:
        check("portal/parent/progress/app.js is what the generator makes now",
              SB.build_js(pp[0]) == open(os.path.join(ROOT, "portal/parent/progress/app.js"), encoding="utf-8").read())
        check("portal/parent/progress/index.html is what the generator makes now",
              SB.build_html(pp[0]) == open(os.path.join(ROOT, "portal/parent/progress/index.html"), encoding="utf-8").read())
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "screen_builder.py"), "--verify-pupils"],
                       capture_output=True, text=True)
    check("the shared generator still reproduces the Pupils screen byte-for-byte",
          r.returncode == 0, r.stdout[-160:])

    # ============ ES5, [hidden], THE NAVS, THE LANDING TILE ============
    for f in ("portal/progress/app.js", "portal/parent/progress/app.js", "portal/app.js",
              "tools/progress_module.js", "tools/parent_progress_module.js", "portal/parent/nav.js", "portal/nav.js"):
        ok, why = es5_ok(os.path.join(ROOT, f))
        check("%s parses as ES5" % f, ok, why)
    for f in ("portal/progress/progress.css", "portal/parent/parent.css"):
        css = re.sub(r"/\*.*?\*/", "", open(os.path.join(ROOT, f), encoding="utf-8").read(), flags=re.S).strip()
        check("%s opens with [hidden] { display: none !important; }" % f,
              css.splitlines()[0].replace(" ", "") == "[hidden]{display:none!important;}", css.splitlines()[0])
    nav = open(os.path.join(SERVE, "portal/nav.js"), encoding="utf-8").read()
    row = re.search(r'key:\s*"md-progress"[^}]*}', nav, re.S)
    check("the office rail has a Progress notes row", bool(row))
    check("and it is not marked soon", bool(row) and "soon" not in row.group(0), row.group(0) if row else None)
    check("and it is for every kind of staff, teachers included", bool(row) and "ANYSTAFF" in row.group(0))
    for key in ("md-merits", "md-exams", "md-reports", "md-homework", "md-lessons"):
        r2 = re.search(r'key:\s*"%s"[^}]*}' % key, nav, re.S)
        check("%s is still soon: this slice leaves the others alone" % key, bool(r2) and "soon: true" in r2.group(0))

    with sync_playwright() as p:
        browser = p.chromium.launch()

        # ================================================================
        #  THE TEACHER'S LANDING TILE
        # ================================================================
        pg = browser.new_page(viewport={"width": 1280, "height": 900})
        pg.add_init_script(stub({"roles": ["teacher"], "aal": "aal2", "answers": {
            "madrasah_my_classes": {"allowed": True, "on_date": "2026-09-29", "permitted": False, "rows": []},
            "my_outstanding": {}}, "errors": {}}))
        pg.goto(BASE + "/portal/", wait_until="networkidle")
        pg.wait_for_timeout(500)
        tile = pg.locator("#tc-list a.rl-item", has_text="Record how each child is getting on")
        check("the teacher's tile is a real link now", tile.count() == 1)
        if tile.count() == 1:
            check("and it goes to the progress screen", tile.get_attribute("href") == "progress/", tile.get_attribute("href"))
            t = tile.inner_text()
            check("and it says it is open, and that a family sees only what the teacher chooses",
                  "open now" in t.lower() and "You choose what a family sees" in t and "never shown to them" in t, t)
        others = pg.eval_on_selector_all("#tc-list .rl-item", "els => els.map(e => e.tagName + '|' + (e.className.indexOf('rl-live') >= 0))")
        check("exactly two rows on the teacher's list are live (raise a concern, progress) and only one is a link",
              sum(1 for o in others if o.endswith("true")) == 2 and sum(1 for o in others if o.startswith("A|")) == 1, others)
        check("the unbuilt rows are still plain blocks, not links",
              all(o.startswith("DIV|") for o in others if o.endswith("false")), others)
        pg.close()

        # ================================================================
        #  THE TEACHER'S SCREEN
        # ================================================================
        # ---- A ROLE-LESS ACCOUNT ----
        pg = open_page(browser, "/portal/progress/", teacher_fx(roles=[]))
        check("a role-less account is refused in words, by the shell or by the screen",
              "cannot open the madrasah portal" in text(pg, "#app-noaccess") or "teacher of a class" in text(pg, "#app-noaccess"),
              text(pg, "#app-noaccess"))
        check("and is shown no progress panel", pg.locator("#tp-panel").is_hidden())
        check("and nothing about any child is fetched", not any(n.startswith("progress_") for n in all_calls(pg)), all_calls(pg))
        pg.close()

        # ---- TWO CLASSES ----
        pg = open_page(browser, "/portal/progress/", teacher_fx())
        check("the screen is called Progress notes", "Progress notes" in text(pg, "h1"), text(pg, "h1"))
        rule = text(pg, "#tp-rule")
        check("before anything is typed the screen says there are two kinds of note",
              "Two kinds of note" in rule and "note for the parent" in rule, rule)
        check("and that the teacher's own note is never shown to a family, whatever is chosen",
              "never shown to a family, whatever you choose" in rule, rule)
        pills = text(pg, "#tp-classes")
        check("both classes are offered, with how many children", "ZZ Proof Class One" in pills and "2 children" in pills
              and "ZZ Proof Class Two" in pills and "1 child" in pills, pills)
        check("nothing is fetched for a class until one is chosen", len(calls(pg, "progress_class_children")) == 0)
        check("and no child is listed yet", pg.locator("#tp-kids-wrap").is_hidden())
        pg.click('.tp-pill[data-class="c1"]'); pg.wait_for_timeout(300)
        check("choosing a class asks for that class only", [c["args"] for c in calls(pg, "progress_class_children")] == [{"p_class": "c1"}],
              calls(pg, "progress_class_children"))
        lst = text(pg, "#tp-kids")
        check("the list says WHETHER: entries, how many shared, when last",
              "2 entries" in lst and "1 shared" in lst and "last 26 September 2026" in lst, lst)
        check("a child with nothing says so", "nothing recorded yet" in lst, lst)
        check("the list says nothing of WHAT was written", SECRET not in lst and "Surah" not in lst and FORP not in lst)
        check("the list is headed with the class name", "Children in ZZ Proof Class One" in text(pg, "#tp-kids-h"), text(pg, "#tp-kids-h"))

        pg.click('.tp-pill[data-class="c2"]'); pg.wait_for_timeout(300)
        check("choosing the OTHER class asks for that class, and lists its children",
              [c["args"] for c in calls(pg, "progress_class_children")][-1] == {"p_class": "c2"}
              and "Children in ZZ Proof Class Two" in text(pg, "#tp-kids-h") and "Proofchildc" in text(pg, "#tp-kids")
              and "Proofchilda" not in text(pg, "#tp-kids"), calls(pg, "progress_class_children"))
        pg.click('.tp-pill[data-class="c1"]'); pg.wait_for_timeout(300)

        # ---- OPEN A CHILD ----
        pg.click('.tp-row[data-pupil="p1"]'); pg.wait_for_timeout(300)
        check("opening a child asks for that child in that class",
              [c["args"] for c in calls(pg, "progress_child")] == [{"p_pupil": "p1", "p_class": "c1"}], calls(pg, "progress_child"))
        ch = text(pg, "#tp-child")
        check("the child's name and class head the record", "Proofchilda Zzzone" in ch and "ZZ Proof Class One" in ch, ch[:120])
        check("the form names sabaq, sabqi and manzil",
              "Sabaq" in ch and "Sabqi" in ch and "Manzil" in ch, ch[:400])
        form = text(pg, "#tp-f")
        check("the form has a note for the parent AND an own note, and the OWN NOTE'S LABEL says staff only",
              "Note for the parent" in form and "Your own note staff only" in form, form[:600])
        check("the own note says it is never shown to a family whether or not the entry is shared",
              "Never shown to a family, whether or not the entry is shared" in ch)
        check("the choice to share is two answers, each saying what it does",
              "Only staff" in ch and "Share with the family" in ch and "Not your own note" in ch, ch[:1200])
        check("a NEW entry starts on Only staff, never on share",
              pg.is_checked('input[name="tp-share"][value="no"]') and not pg.is_checked('input[name="tp-share"][value="yes"]'))
        check("the date starts on a day and cannot be a future one",
              re.match(r"\d{4}-\d{2}-\d{2}$", pg.input_value("#tp-on") or "") is not None
              and pg.get_attribute("#tp-on", "max") == pg.input_value("#tp-on"))
        entries = text(pg, ".tp-entries")
        check("entries so far show the date, and whether each is shared",
              "26 September 2026" in entries and "Shared with the family" in entries and "19 September 2026" in entries
              and "Not shared" in entries, entries)
        check("an entry shows the note for the parent and the own note, each labelled",
              "for the parent" in entries.lower() and FORP in entries and "your own note - staff only" in entries.lower() and SECRET in entries, entries)
        check("an entry says who wrote it", "Written by Mr Proofteacher Alpha" in entries, entries)

        # ---- SAVE, NOT SHARED ----
        pg.fill("#tp-on", "2026-09-28")
        pg.fill("#tp-sabaq", "Surah al-Mulk 11-20"); pg.fill("#tp-sabqi", "Surah an-Naba 16-30")
        pg.fill("#tp-manzil", "Juz Amma"); pg.fill("#tp-forp", "A good week."); pg.fill("#tp-mine", SECRET + " watch her tajweed")
        pg.click("#tp-save"); pg.wait_for_timeout(500)
        sv = calls(pg, "progress_save")
        check("saving sends exactly what was typed and the choice made: NOT shared, a new entry",
              len(sv) == 1 and sv[0]["args"] == {
                  "p_pupil": "p1", "p_class": "c1", "p_on": "2026-09-28",
                  "p_sabaq": "Surah al-Mulk 11-20", "p_sabqi": "Surah an-Naba 16-30", "p_manzil": "Juz Amma",
                  "p_note_for_parent": "A good week.", "p_note_internal": SECRET + " watch her tajweed",
                  "p_shared": False, "p_id": None}, sv)
        ok_msg = text(pg, "#tp-ok")
        check("the teacher is told in words that only staff can see it", "Saved." in ok_msg and "not shared" in ok_msg and "only staff can see it" in ok_msg, ok_msg)
        check("the child is reloaded from the server, not edited locally", len(calls(pg, "progress_child")) >= 2)
        check("and the class list is refreshed", len(calls(pg, "progress_class_children")) >= 2)

        # ---- SAVE, SHARED ----
        pg.fill("#tp-sabaq", "Surah al-Mulk 21-30")
        pg.check('input[name="tp-share"][value="yes"]')
        pg.click("#tp-save"); pg.wait_for_timeout(500)
        sv = calls(pg, "progress_save")
        check("choosing Share sends p_shared true", len(sv) == 2 and sv[1]["args"]["p_shared"] is True, sv[-1:])
        ok_msg = text(pg, "#tp-ok")
        check("and the teacher is told the family can read it", "shared" in ok_msg and "the family can read it" in ok_msg, ok_msg)

        # ---- AN EMPTY ENTRY, AND AN ENTRY WITH NOTHING TO SHARE ----
        n0 = len(calls(pg, "progress_save"))
        pg.fill("#tp-sabaq", ""); pg.fill("#tp-sabqi", ""); pg.fill("#tp-manzil", ""); pg.fill("#tp-forp", ""); pg.fill("#tp-mine", "")
        pg.click("#tp-save"); pg.wait_for_timeout(200)
        check("an entry with nothing in it is not sent", len(calls(pg, "progress_save")) == n0)
        check("and says what to do", "Write something first" in text(pg, "#tp-inline"), text(pg, "#tp-inline"))
        pg.fill("#tp-mine", "just a working note")
        pg.check('input[name="tp-share"][value="yes"]')
        pg.click("#tp-save"); pg.wait_for_timeout(200)
        check("an own note alone cannot be shared: not sent", len(calls(pg, "progress_save")) == n0)
        check("and it says there is nothing for the family to read",
              "nothing to share with the family" in text(pg, "#tp-inline"), text(pg, "#tp-inline"))
        pg.check('input[name="tp-share"][value="no"]')
        pg.click("#tp-save"); pg.wait_for_timeout(400)
        check("the same own note, not shared, IS sent: a working note is kept without publishing it",
              len(calls(pg, "progress_save")) == n0 + 1 and calls(pg, "progress_save")[-1]["args"]["p_shared"] is False)
        pg.close()

        # ---- AMEND ----
        pg = open_page(browser, "/portal/progress/", teacher_fx(classes=[CLASSES[0]]))
        check("one class opens itself", [c["args"] for c in calls(pg, "progress_class_children")] == [{"p_class": "c1"}]
              and pg.locator(".tp-row").count() == 2, calls(pg, "progress_class_children"))
        pg.click('.tp-row[data-pupil="p1"]'); pg.wait_for_timeout(300)
        pg.click('.tp-entry >> nth=0 >> .tp-link'); pg.wait_for_timeout(200)
        check("amending fills the form with what the entry holds",
              pg.input_value("#tp-sabaq") == "Surah al-Mulk, verses 1-10" and pg.input_value("#tp-forp") == FORP
              and pg.input_value("#tp-mine") == SECRET and pg.input_value("#tp-on") == "2026-09-26")
        check("and re-selects its share state (this one is shared)",
              pg.is_checked('input[name="tp-share"][value="yes"]') and "Change this entry" in text(pg, "#tp-f"))
        pg.click("#tp-save"); pg.wait_for_timeout(400)
        check("saving an amendment passes the entry's id", calls(pg, "progress_save")[-1]["args"]["p_id"] == "e2"
              and calls(pg, "progress_save")[-1]["args"]["p_shared"] is True, calls(pg, "progress_save")[-1:])
        pg.click('.tp-entry >> nth=1 >> .tp-link'); pg.wait_for_timeout(200)
        check("an entry that is not shared re-selects Only staff", pg.is_checked('input[name="tp-share"][value="no"]'))
        pg.click("#tp-cancel"); pg.wait_for_timeout(200)
        check("cancelling puts back a new-entry form", "New entry" in text(pg, "#tp-f") and pg.input_value("#tp-sabaq") == "")
        pg.close()

        # ---- A DATABASE REFUSAL, AND allowed:false ----
        pg = open_page(browser, "/portal/progress/", teacher_fx(classes=[CLASSES[0]],
                       errors={"progress_save": {"code": "22023", "message": "Please keep sabaq, sabqi and manzil to 200 characters each."}}))
        pg.click('.tp-row[data-pupil="p2"]'); pg.wait_for_timeout(300)
        pg.fill("#tp-sabaq", "x" * 50); pg.click("#tp-save"); pg.wait_for_timeout(300)
        check("a database refusal is shown as written, beside the form", "200 characters each" in text(pg, "#tp-inline"), text(pg, "#tp-inline"))
        check("and what was typed is kept", pg.input_value("#tp-sabaq") == "x" * 50)
        pg.close()
        pg = open_page(browser, "/portal/progress/", teacher_fx(classes=[CLASSES[0]],
                       answers={"progress_my_classes": {"allowed": True, "classes": [CLASSES[0]]},
                                "progress_class_children": {"allowed": False}}))
        check("{allowed:false} for a class is a sentence, not an empty list",
              "cannot record progress for that child" in text(pg, "#tp-error") and pg.locator("#tp-kids-wrap").is_hidden(), text(pg, "#tp-error"))
        pg.close()
        pg = open_page(browser, "/portal/progress/", teacher_fx(
            answers={"progress_my_classes": {"allowed": False}}))
        check("{allowed:false} on the class list is a sentence, not an empty screen",
              "teacher of a class" in text(pg, "#tp-error"), text(pg, "#tp-error"))
        pg.close()
        pg = open_page(browser, "/portal/progress/", teacher_fx(
            answers={"progress_my_classes": {"allowed": True, "classes": [], "why": "This login is not linked to a member of staff yet, so the madrasah does not know which classes are yours. Ask the office."}}))
        check("a teacher with no classes is told why, in the database's words",
              "not linked to a member of staff" in text(pg, "#tp-empty"), text(pg, "#tp-empty"))
        pg.close()

        # ---- ESCAPING ----
        ent = [sentry(5, "2026-09-26", True, forp=HTML, mine=HTML)]
        pg = open_page(browser, "/portal/progress/", teacher_fx(classes=[CLASSES[0]], answers={
            "progress_my_classes": {"allowed": True, "classes": [CLASSES[0]]},
            "progress_class_children": {"__by": {"c1": KIDS_1}, "key": "p_class"},
            "progress_child": {"__by": {"p1": child_answer("Proofchilda", "Zzzone", "c1", "ZZ Proof Class One", ent)}, "key": "p_pupil"}}))
        pg.click('.tp-row[data-pupil="p1"]'); pg.wait_for_timeout(300)
        check("both notes are escaped, not run (the tag is shown as text twice: once per note)",
              pg.evaluate("() => window.__pwned") is None and text(pg, ".tp-entries").count("<b>bold</b>") == 2, text(pg, ".tp-entries"))
        pg.close()

        # ---- A PHONE ----
        pg = open_page(browser, "/portal/progress/", teacher_fx(), width=390, height=844)
        check("no sideways scroll at 390px (classes)", no_sideways_scroll(pg))
        pg.click('.tp-pill[data-class="c1"]'); pg.wait_for_timeout(300)
        pg.click('.tp-row[data-pupil="p1"]'); pg.wait_for_timeout(300)
        check("no sideways scroll at 390px (a child's form and entries)", no_sideways_scroll(pg))
        pg.close()

        # ================================================================
        #  THE PARENT'S SCREEN
        # ================================================================
        pg = open_page(browser, "/portal/parent/progress/", parent_fx())
        check("the parent screen is called Progress", "Progress" in text(pg, "h1"), text(pg, "h1"))
        check("it asks which children are mine, then for each one, and nothing on the staff side",
              all_calls(pg) == ["parent_my_children", "parent_progress"], all_calls(pg))
        check("and asks for that child by id and nothing else", [c["args"] for c in calls(pg, "parent_progress")] == [{"p_pupil": "p1"}])
        body = text(pg, "#pp-kids")
        check("the child's name heads the section", "Proofchilda" in body)
        check("an entry shows the date in words", "26 September 2026" in body and "19 September 2026" in body, body)
        check("newest first, in the order the database gave", body.index("26 September 2026") < body.index("19 September 2026"))
        check("sabaq, sabqi and manzil are named, with what they mean",
              "Sabaq" in body and "new lesson" in body and "Sabqi" in body and "recent revision" in body
              and "Manzil" in body and "older revision" in body, body)
        check("the values are shown", "Surah al-Mulk, verses 1-10" in body and "Surah an-Naba, 1-15" in body and "Juz Amma" in body)
        check("the note for the parent is shown, labelled as for them", "a note for you" in body.lower() and FORP in body, body)
        check("the teacher's name and the class are shown", "From Mr Proofteacher Alpha" in body and "ZZ TEST CLASS" in body, body)
        check("an entry with no teacher name says it is from the child's teacher", "From your child’s teacher" in body, body)
        check("an entry with only a sabaq draws only a sabaq (no empty Sabqi row for the second entry)",
              body.count("Sabqi") == 1 and body.count("Manzil") == 1, body)
        check("the footnote says it is not a full report and to ring the office", "not a full report" in text(pg, "#pp-fine") and pg.locator("#pp-fine").is_visible())
        check("no working note, staff-only label or staff phrase appears", SECRET not in body and "staff only" not in body.lower()
              and "Your own note" not in body and "Only staff" not in body)
        pg.close()

        # ---- A SMUGGLED STAFF-ONLY KEY ----
        smuggled = pentry("2026-09-26")
        smuggled["note_internal"] = SECRET
        smuggled["shared"] = False
        pg = open_page(browser, "/portal/parent/progress/", parent_fx(progress={
            "p1": {"first_name": "Proofchilda", "entries": [smuggled], "note_internal": SECRET}}))
        check("even if the answer carried a staff-only key, the screen draws only what it names (defence in depth: the database never sends it)",
              SECRET not in pg.content() and SECRET not in text(pg, "body"))
        pg.close()

        # ---- NOTHING SHARED ----
        pg = open_page(browser, "/portal/parent/progress/", parent_fx(progress={"p1": {"first_name": "Proofchilda", "entries": []}}))
        body = text(pg, "#pp-kids")
        check("nothing shared is SAID, not left as a blank page", "Nothing has been shared about Proofchilda yet." in body, body)
        check("and it says this is not a judgement of the child", "not a judgement" in body, body)
        check("and the footnote about shared entries is not drawn when there are none", pg.locator("#pp-fine").is_hidden())
        pg.close()

        # ---- TWO CHILDREN ----
        pg = open_page(browser, "/portal/parent/progress/", parent_fx(
            kids=[{"pupil_id": "p1", "first_name": "Proofchilda"}, {"pupil_id": "p2", "first_name": "Proofchildb"}],
            progress={"p1": {"first_name": "Proofchilda", "entries": [pentry("2026-09-26")]},
                      "p2": {"first_name": "Proofchildb", "entries": []}}))
        check("two children, two calls, each with its own id",
              sorted(c["args"]["p_pupil"] for c in calls(pg, "parent_progress")) == ["p1", "p2"], calls(pg, "parent_progress"))
        check("two sections", pg.locator("#pp-kids section.pt-card").count() == 2)
        secs = pg.eval_on_selector_all("#pp-kids section.pt-card", "els => els.map(e => e.innerText)")
        check("the first child's entry is in the first section and the second child has nothing shared",
              "Surah al-Mulk" in secs[0] and "Nothing has been shared about Proofchildb yet." in secs[1], secs)
        pg.close()

        # ---- NOT A PARENT, AND A TECHNICAL ERROR ----
        pg = open_page(browser, "/portal/parent/progress/", parent_fx(
            errors={"parent_my_children": {"code": "42501", "message": "not yours"}}))
        check("a login that is not a parent's is told so, in words", "not set up as a parent" in text(pg, "#pp-error"), text(pg, "#pp-error"))
        check("and is shown no progress", pg.locator("#pp-kids").is_hidden())
        pg.close()
        pg = open_page(browser, "/portal/parent/progress/", parent_fx(
            errors={"parent_progress": {"code": "42883", "message": "function public.parent_progress does not exist"}}))
        e = text(pg, "#pp-error")
        check("a technical error is never shown to a parent", "42883" not in e and "does not exist" not in e and OFFICE in e, e)
        pg.close()

        # ---- ESCAPING ----
        pg = open_page(browser, "/portal/parent/progress/", parent_fx(progress={
            "p1": {"first_name": "Proofchilda", "entries": [pentry("2026-09-26", note=HTML)]}}))
        check("a note is escaped on the parent's screen", pg.evaluate("() => window.__pwned") is None and "<b>bold</b>" in text(pg, "#pp-kids"))
        pg.close()

        # ---- THE RAIL ----
        pg = open_page(browser, "/portal/parent/progress/", parent_fx())
        rail = pg.eval_on_selector_all(".ashell a.area, .ashell .area.soon", "els => els.map(e => e.innerText.trim().replace(/\\s+/g, ' '))")
        joined = " | ".join(rail)
        check("the parent's rail has Progress, and nothing on it is tagged soon", any(x.startswith("Progress") for x in rail)
              and not any(x.endswith("soon") for x in rail), joined)
        check("and the rail row is a link", pg.locator('.ashell a.area[href$="portal/parent/progress/"]').count() == 1)
        pg.close()

        # ---- A PHONE ----
        pg = open_page(browser, "/portal/parent/progress/", parent_fx(), width=390, height=844)
        check("no sideways scroll at 390px (parent progress)", no_sideways_scroll(pg))
        pg.close()

        browser.close()
    FINISHED[0] = True


if __name__ == "__main__":
    run()
