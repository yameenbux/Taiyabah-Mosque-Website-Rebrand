"""The Register screen, driven in a browser against a stubbed database.

WHAT THIS SUITE IS FOR

The migrations prove what lives in Postgres: that save_register_draft() and
submit_register() refuse until every family has been told the register is
being kept, that a child not in the class is ignored, that a register cannot
be taken for a day that has not happened or one more than a fortnight ago,
that a teacher's blanket mark never buries a parent's message, and that
submit_register() refuses a class with any child unmarked, naming how many.
Those were proved against real classes in rolled-back transactions.

This proves the half SQL cannot see:

  * that the gate is a JOB with a number on it and a way out, not a grey
    wall — "230 still to tell" and a button, not "not available";
  * that "Everyone is here" leaves a parent's message alone ON THE SCREEN as
    well as in the database, because a screen that appears to do something and
    is then silently corrected is worse than one that never appeared to;
  * that a medical note NEVER reaches this screen — only a mark, and a link to
    the child's own record, which is written down;
  * that typing a reason is what turns "away" into "away, reason given", so a
    teacher never has to choose between two kinds of away;
  * that a half-taken register warns before it is lost;
  * that Save always works, and Hand-in is shut until every child on the
    roll has a mark — and OPENS, on screen, the moment the last one does,
    with no reload;
  * that a refused hand-in tells the teacher how many children are missing
    and that their marks are safe, in words a volunteer can act on;
  * that the marks are big enough to hit standing up, and stay big on a phone;
  * that the paper register carries names and boxes and nothing else.

Every check in here was watched failing before it was kept.

    python3 _test/register_test.py
"""
import atexit
import datetime
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

FAILURES = []
CHECKS = [0]
FINISHED = [False]


def report():
    if FAILURES:
        print("\n%d FAILURE(S) out of %d checks:" % (len(FAILURES), CHECKS[0]))
        for f in FAILURES:
            print("  - " + f)
    elif not FINISHED[0]:
        print("\nRUN INCOMPLETE — %d checks ran and the suite never reached its "
              "end. Do not read this as a pass." % CHECKS[0])
    else:
        print("\nALL PASS — %d checks" % CHECKS[0])


def check(name, ok, got=None):
    CHECKS[0] += 1
    if not ok:
        FAILURES.append(name + ("" if got is None else ": %s" % (got,)))


TODAY = str(datetime.date.today())

#  The detail that must never reach this screen. Distinctive, so a leak is
#  unambiguous rather than a coincidence of common words.
SECRET_MEDICAL = "ZZASTHMA-BLUE-INHALER"
SECRET_PHONE   = "07ZZ000111222"
#  Fields the OFFICE record carries and a teacher must never be handed. If any
#  of these reaches the screen, madrasah_pupil_for_teacher has been replaced by
#  madrasah_pupil_one somewhere.
SECRET_ADDRESS = "ZZ99 Nowhere Lane, Bolton"
SECRET_DOB     = "ZZDOB-02-04-2016"

#  What madrasah_pupil_for_teacher() returns. Note what is NOT in it: address,
#  postcode, date of birth, fees, the family's other children.
CHILD = {
    "id": "p1", "name": "Aaliyah Test", "reference": "1001",
    "status": "on_roll", "school_year": "Year 4", "class": "Test Class One",
    "medical": SECRET_MEDICAL, "allergies": "ZZ peanuts",
    "send_detail": None, "ehcp_detail": None,
    "walk_home_consent": False,
    "ring_name": "Test Parent", "ring_phone": SECRET_PHONE,
    "away_last_four_weeks": 2,
}

#  NO REAL CHILD, CLASS OR TEACHER APPEARS IN THIS FILE.
CLASSES = [
    {"id": "c1", "name": "Test Class One", "section": "boys", "sort_order": 1,
     "teacher": "Apa Testname", "on_roll": 4, "marked": 0, "away": 0},
    #  db/113 (ruling B): madrasah_registers_list() now carries each class's
    #  own register state alongside its counts, additive. A genuinely
    #  finished class is one that was actually handed in, not merely one
    #  whose marked count happens to equal its roll — see STATE_CLASSES
    #  below for the fixture that proves the two are checked separately.
    {"id": "c2", "name": "Test Class Two", "section": "girls", "sort_order": 2,
     "teacher": "Apa Othername", "on_roll": 3, "marked": 3, "away": 1,
     "state": "submitted"},
    {"id": "c3", "name": "Test Class Three", "section": "boys", "sort_order": 3,
     "teacher": None, "on_roll": 2, "marked": 1, "away": 0},
]

ROWS = [
    {"id": "p1", "name": "Aaliyah Test", "reference": "1001", "status": "on_roll",
     "has_medical": True, "mark": None, "reason": None, "source": None},
    {"id": "p2", "name": "Bilal Test", "reference": "1002", "status": "on_roll",
     "has_medical": False, "mark": None, "reason": None, "source": None},
    #  A MOTHER RANG IN AN HOUR AGO.
    {"id": "p3", "name": "Zakariya Test", "reference": "1003", "status": "on_roll",
     "has_medical": False, "mark": "excused", "reason": "unwell, mother telephoned",
     "source": "parent"},
    {"id": "p4", "name": "Maryam Test", "reference": "1004", "status": "on_roll",
     "has_medical": False, "mark": None, "reason": None, "source": None},
]

#  HAND-IN: A CLASS OF THREE, TWO ALREADY MARKED. Its own small fixture
#  rather than the shared one above, so the gate-opening test is not tangled
#  up with the parent's-message rules the main flow already covers.
GATE_CLASSES = [
    {"id": "gc1", "name": "Test Class Gate", "section": "boys", "sort_order": 1,
     "teacher": "Apa Gatename", "on_roll": 3, "marked": 2, "away": 0},
]
GATE_ROWS = [
    {"id": "g1", "name": "Yusuf Test", "reference": "3001", "status": "on_roll",
     "has_medical": False, "mark": "present", "reason": None, "source": None},
    {"id": "g2", "name": "Zayd Test", "reference": "3002", "status": "on_roll",
     "has_medical": False, "mark": "present", "reason": None, "source": None},
    {"id": "g3", "name": "Amina Test", "reference": "3003", "status": "on_roll",
     "has_medical": False, "mark": None, "reason": None, "source": None},
]
#  THE SAME THREE, ALL MARKED — what a genuinely submitted register's roll
#  actually looks like (submit_register refuses a gap, so a real submitted
#  register is never missing a mark).
GATE_ROWS_FULL = [dict(GATE_ROWS[0]), dict(GATE_ROWS[1]),
                  dict(GATE_ROWS[2], mark="present")]

# =============================================================================
#  TASK 11 — WHAT WAS NEVER TAKEN, AND WHAT A MARK USED TO SAY.
#  No real class, teacher or child name appears in any of this.
# =============================================================================

#  registers_missing()'s shape, office-only — a class, a date, a teacher.
REGISTERS_MISSING = {
    "allowed": True, "count": 2,
    "rows": [
        {"class_id": "c5", "name": "Test Class Five", "on_date": "2026-09-14",
         "teacher": "Apa Fivename"},
        {"class_id": "c1", "name": "Test Class One", "on_date": "2026-09-16",
         "teacher": "Apa Testname"},
    ],
}

#  register_history()'s shape, office-only — every change to a mark, on one
#  evening, for one class. Distinctive names so a leak into the wrong screen
#  is unambiguous rather than a coincidence.
HISTORY = {
    "allowed": True,
    "rows": [
        {"child": "ZZHistoryOne Test", "mark": "absent", "reason": "unwell",
         "source": "office", "was_mark": "present", "was_reason": None,
         "was_source": "register", "written_at": "2026-09-28T18:05:00.000Z",
         "written_by": "Apa Historyname"},
        {"child": "ZZHistoryTwo Test", "mark": "present", "reason": None,
         "source": "register", "was_mark": None, "was_reason": None,
         "was_source": None, "written_at": "2026-09-28T18:00:00.000Z",
         "written_by": "Apa Historyname"},
    ],
}

#  RULING E — THE GRID MUST DISTINGUISH "HANDED IN" FROM "MERELY FULLY
#  MARKED". cs2 is the case db/102's demotion rule and db/110 both exist
#  for: every child marked, but never actually submitted.
STATE_CLASSES = [
    {"id": "cs1", "name": "Test Class Handed", "section": "boys", "sort_order": 1,
     "teacher": "Apa Handedname", "on_roll": 2, "marked": 2, "away": 0,
     "state": "submitted"},
    {"id": "cs2", "name": "Test Class Full Unsubmitted", "section": "boys",
     "sort_order": 2, "teacher": "Apa Fullname", "on_roll": 2, "marked": 2,
     "away": 0, "state": None},
]


def stub(roles, permitted=True, families=330, told=330, rows=None, classes=None,
         save_fails=None, submit_fails=None, register_state=None,
         reload_fails_after_submit=None, missing=None, history=None,
         missing_fails=None, history_fails=None,
         register_days=None, academic_year=None, closures=None):
    return """
(function(){
  var ROLES=%s, CLASSES=%s, ROWS=%s;
  var GATE=%s, CHILD=%s, ADDRESS=%s, DOB=%s, MEDICAL=%s;
  var SAVE_FAILS=%s, SUBMIT_FAILS=%s, RELOAD_FAILS_AFTER_SUBMIT=%s;
  //  Task 12 — save_register_draft()'s OWN gates, read off the installed
  //  function (pg_get_functiondef), not invented: register_due() (Sunday /
  //  closure / outside the academic year) runs BEFORE
  //  attendance_permitted(), and both run before a mark is ever written.
  //  Carried forward from Task 8: this stub used to have no gate of its
  //  own here at all — save_register_draft simply always succeeded, which
  //  is kinder than the database ever is.
  var REGISTER_DAYS=%s, ACADEMIC_YEAR=%s, CLOSURES=%s;
  function computeDue(dateStr) {
    if (!REGISTER_DAYS.length) {
      return { due: false,
        why: 'Nobody has said which evenings the madrasah runs yet.' };
    }
    if (dateStr < ACADEMIC_YEAR.starts_on || dateStr > ACADEMIC_YEAR.ends_on) {
      return { due: false, why: 'That date is outside the academic year.' };
    }
    var parts = dateStr.split('-');
    var utc = new Date(Date.UTC(parseInt(parts[0],10),
                                 parseInt(parts[1],10)-1, parseInt(parts[2],10)));
    var DOW = ['sun','mon','tue','wed','thu','fri','sat'];
    var DOWNAME = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
    var i = utc.getUTCDay();
    if (REGISTER_DAYS.indexOf(DOW[i]) === -1) {
      return { due: false, why: 'The madrasah does not run on a ' + DOWNAME[i] + '.' };
    }
    for (var z = 0; z < CLOSURES.length; z++) {
      if (dateStr >= CLOSURES[z].starts_on && dateStr <= CLOSURES[z].ends_on) {
        return { due: false, why: CLOSURES[z].name + '.' };
      }
    }
    return { due: true, why: '' };
  }
  //  Task 11 — office-only. Mirrors the live functions' own gate
  //  (verified_madrasah()): a teacher calling either of these through the
  //  stub gets exactly what the database gives them, allowed:false, never
  //  the fixture data — so a test proving the screen hides these panels
  //  from a teacher is backed by the stub also refusing them, the same
  //  two-halves-agree shape the live database proof used.
  var MISSING_DATA=%s, HISTORY_DATA=%s, MISSING_FAILS=%s, HISTORY_FAILS=%s;
  function isOffice() {
    for (var z = 0; z < ROLES.length; z++) {
      if (ROLES[z] === 'admin' || ROLES[z] === 'madrasah') return true;
    }
    return false;
  }
  //  Flips true the instant submit_register succeeds — models a reload
  //  (madrasah_registers_list / madrasah_register_list) that fails ONLY
  //  after the write it is reloading has already gone through, same as a
  //  network glitch landing between a successful write and its refresh.
  var RELOAD_BROKEN = false;
  window.__calls=[]; window.__printed=0;
  //  db/110 — madrasah_register_list()'s 'class' object now carries the
  //  register's own state and submitted_at (left-joined off
  //  madrasah_registers, additive to the class row). Keyed by class id,
  //  since a page can open more than one class in a test. Absent entry ==
  //  no row for this class/date yet == draft in everything but name, same
  //  as the live left join returning null.
  var REGISTER_STATE = %s;
  function registerState(id) {
    return REGISTER_STATE[id] || { state: null, submitted_at: null };
  }
  //  SAVED MARKS. Seeded from whatever ROWS already carries — a mark a row
  //  already has came from an earlier, real save. A mark made on THIS page
  //  only reaches here once save_register_draft (or mark_register) is
  //  actually called, same as the live database: submit_register reads
  //  what has been WRITTEN, never what is only sitting on screen.
  var SAVED = {};
  (function () {
    for (var z = 0; z < ROWS.length; z++) {
      if (ROWS[z].mark) SAVED[ROWS[z].id] = { mark: ROWS[z].mark,
        reason: ROWS[z].reason, source: ROWS[z].source };
    }
  })();
  function classOnRoll(id) {
    for (var z = 0; z < CLASSES.length; z++) {
      if (CLASSES[z].id === id) return CLASSES[z].on_roll;
    }
    return ROWS.length;
  }
  function savedCount() {
    var have = 0;
    for (var z = 0; z < ROWS.length; z++) { if (SAVED[ROWS[z].id]) have++; }
    return have;
  }
  function rowsWithSaved() {
    var out = [];
    for (var z = 0; z < ROWS.length; z++) {
      var r = ROWS[z], s = SAVED[r.id];
      out.push(s ? { id: r.id, name: r.name, reference: r.reference,
        status: r.status, has_medical: r.has_medical,
        mark: s.mark, reason: s.reason, source: s.source } : r);
    }
    return out;
  }
  //  Mirrors save_register_draft(): a parent's mark is kept unless the new
  //  mark is present/late, in which case it is written and stops being
  //  parent-sourced — same rule as the live function.
  function applyDraft(marks) {
    var kept = 0, marked = 0, j, m, was;
    for (j = 0; j < (marks || []).length; j++) {
      m = marks[j]; was = SAVED[m.pupil_id];
      if (was && was.source === 'parent' && m.mark !== 'present' && m.mark !== 'late') {
        kept++; continue;
      }
      marked++;
      SAVED[m.pupil_id] = { mark: m.mark, reason: m.reason || null, source: null };
    }
    return { marked: marked, kept: kept };
  }
  //  db/102's OWN RULE, mirrored: a save can only ever DEMOTE a submitted
  //  register (when the roll has grown past what is marked), never
  //  promote one — only submit_register writes 'submitted'.
  function demoteIfNeeded(classId) {
    var cur = REGISTER_STATE[classId];
    if (cur && cur.state === 'submitted'
        && savedCount() < classOnRoll(classId)) {
      REGISTER_STATE[classId] = { state: 'draft', submitted_at: cur.submitted_at };
    }
  }
  window.print = function(){
    window.__printed++;
    function on(sel){ var n=document.querySelector(sel);
      if(!n) return false;
      while(n && n!==document){ var s=getComputedStyle(n);
        if(s.display==='none'||s.visibility==='hidden') return false;
        n=n.parentNode; }
      return true; }
    var sheet=document.querySelector('#rg-print');
    window.__atPrint={ paper:on('#rg-print'), rail:on('.shell .arail'),
      marks:on('.rg-list'), gate:on('#rg-gate'),
      bodyClass:document.body.className,
      atBodyLevel: !!sheet && sheet.parentNode===document.body,
      text:(document.querySelector('#rg-print')||{}).innerText||'' };
  };
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
      if (name==='madrasah_registers_list') {
        if (RELOAD_BROKEN) return Promise.resolve({data:null,
          error:{message:RELOAD_FAILS_AFTER_SUBMIT || 'network glitch'}});
        return Promise.resolve({data:{allowed:true,on_date:args.p_date,
          permitted:GATE,rows:CLASSES},error:null});
      }
      if (name==='madrasah_register_list') {
        if (RELOAD_BROKEN) return Promise.resolve({data:null,
          error:{message:RELOAD_FAILS_AFTER_SUBMIT || 'network glitch'}});
        var c=null;
        for(var i=0;i<CLASSES.length;i++){ if(CLASSES[i].id===args.p_class) c=CLASSES[i]; }
        var rs = c && registerState(c.id);
        return Promise.resolve({data:{allowed:true,on_date:args.p_date,
          permitted:GATE,
          'class': c && {id:c.id,name:c.name,section:c.section,teacher:c.teacher,
            state: rs.state, submitted_at: rs.submitted_at},
          rows:rowsWithSaved()},error:null});
      }
      if (name==='registers_missing') {
        if (!isOffice()) return Promise.resolve({data:{allowed:false},error:null});
        if (MISSING_FAILS) return Promise.resolve({data:null,error:{message:MISSING_FAILS}});
        return Promise.resolve({data:MISSING_DATA,error:null});
      }
      if (name==='register_history') {
        if (!isOffice()) return Promise.resolve({data:{allowed:false},error:null});
        if (HISTORY_FAILS) return Promise.resolve({data:null,error:{message:HISTORY_FAILS}});
        return Promise.resolve({data:HISTORY_DATA,error:null});
      }
      if (name==='madrasah_pupil_for_teacher')
        return Promise.resolve({data:CHILD,error:null});
      if (name==='raise_concern')
        return Promise.resolve({data:{reference:'SC-26-0007',
          said:'This has gone to the safeguarding lead.'},error:null});
      //  THE OFFICE RECORD. If the screen ever calls this as a teacher it is a
      //  breach, so the stub answers with the fields a teacher must not see.
      if (name==='madrasah_pupil_one')
        return Promise.resolve({data:{id:'p1',name:'Aaliyah Test',
          address:ADDRESS,date_of_birth:DOB,medical:MEDICAL},error:null});
      //  save_register_draft(p_class, p_date, p_marks) — SAVE ONLY. Live
      //  contract as read from the installed function: returns marked,
      //  parent_reports_kept, on_roll, has_mark and missing. Save always
      //  works, so this has no gate of its own.
      if (name==='save_register_draft') {
        //  register_due() THEN attendance_permitted() — the installed
        //  function's own order, checked before a single mark is written.
        var due1 = computeDue(args.p_date);
        if (!due1.due) return Promise.resolve({data:null,error:{message:due1.why}});
        if (!GATE.permitted) return Promise.resolve({data:null,error:{message:GATE.why}});
        if (SAVE_FAILS) return Promise.resolve({data:null,error:{message:SAVE_FAILS}});
        var d1 = applyDraft(args.p_marks);
        demoteIfNeeded(args.p_class);
        var roll1 = classOnRoll(args.p_class), have1 = savedCount();
        return Promise.resolve({data:{marked:d1.marked,parent_reports_kept:d1.kept,
          on_roll:roll1, has_mark:have1, missing:Math.max(roll1-have1,0)},error:null});
      }
      //  mark_register(p_class, p_date, p_marks) — I5: NOTHING ON THIS
      //  SCREEN CALLS THIS ANY MORE (save() calls save_register_draft,
      //  Hand-in calls submit_register). Kept truthful here anyway: the
      //  live function is now only a thin wrapper round save_register_draft
      //  that appends submitted:false. It no longer submits.
      if (name==='mark_register') {
        //  Same two gates — the live mark_register is now a thin wrapper
        //  round save_register_draft (I3), so it inherits both for free.
        var due2 = computeDue(args.p_date);
        if (!due2.due) return Promise.resolve({data:null,error:{message:due2.why}});
        if (!GATE.permitted) return Promise.resolve({data:null,error:{message:GATE.why}});
        if (SAVE_FAILS) return Promise.resolve({data:null,error:{message:SAVE_FAILS}});
        var d2 = applyDraft(args.p_marks);
        demoteIfNeeded(args.p_class);
        var roll2 = classOnRoll(args.p_class), have2 = savedCount();
        return Promise.resolve({data:{marked:d2.marked,parent_reports_kept:d2.kept,
          on_roll:roll2, has_mark:have2, missing:Math.max(roll2-have2,0),
          submitted:false},error:null});
      }
      //  submit_register(p_class, p_date) — reads what has been WRITTEN
      //  (SAVED), never what is only sitting in this tab. Refuses with the
      //  live wording, naming how many children are missing.
      if (name==='submit_register') {
        if (SUBMIT_FAILS) return Promise.resolve({data:null,error:{message:SUBMIT_FAILS}});
        var roll3 = classOnRoll(args.p_class), have3 = savedCount();
        var missing3 = Math.max(roll3 - have3, 0);
        if (roll3 === 0) {
          return Promise.resolve({data:null,
            error:{message:'That class has nobody on its roll.'}});
        }
        if (missing3 > 0) {
          return Promise.resolve({data:null,error:{message:
            missing3+' of '+roll3+' children have no mark yet. Every child '
            +'needs one before the register can be handed in.'}});
        }
        REGISTER_STATE[args.p_class] = { state: 'submitted',
          submitted_at: new Date().toISOString() };
        if (RELOAD_FAILS_AFTER_SUBMIT) RELOAD_BROKEN = true;
        return Promise.resolve({data:{submitted:true,children:roll3},error:null});
      }
      return Promise.resolve({data:null,error:{message:'unstubbed '+name}});
    }
  };
  Object.defineProperty(window,'supabase',
    {value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % (json.dumps(roles),
       json.dumps(classes if classes is not None else CLASSES),
       json.dumps(rows if rows is not None else ROWS),
       json.dumps({"permitted": permitted, "families": families, "told": told,
                   "outstanding": max(families - told, 0),
                   "why": "ok" if permitted else
                          ("The privacy notice promises parents they will be "
                           "told before the first mark is made. %d families "
                           "have not been told yet." % (families - told))}),
       json.dumps(CHILD), json.dumps(SECRET_ADDRESS), json.dumps(SECRET_DOB),
       json.dumps(SECRET_MEDICAL),
       json.dumps(save_fails), json.dumps(submit_fails),
       json.dumps(reload_fails_after_submit),
       json.dumps(register_days if register_days is not None
                   else ["mon", "tue", "wed", "thu", "fri"]),
       json.dumps(academic_year if academic_year is not None
                   else {"starts_on": "2026-09-01", "ends_on": "2027-08-31"}),
       json.dumps(closures if closures is not None else []),
       json.dumps(missing if missing is not None
                   else {"allowed": True, "count": 0, "rows": []}),
       json.dumps(history if history is not None
                   else {"allowed": True, "rows": []}),
       json.dumps(missing_fails), json.dumps(history_fails),
       json.dumps(register_state or {}))


def open_screen(browser, roles, permitted=True, families=330, told=330,
                rows=None, classes=None, width=1280, height=900,
                save_fails=None, submit_fails=None, register_state=None,
                reload_fails_after_submit=None, missing=None, history=None,
                missing_fails=None, history_fails=None,
                register_days=None, academic_year=None, closures=None):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.add_init_script(stub(list(roles), permitted, families, told, rows, classes,
                            save_fails, submit_fails, register_state,
                            reload_fails_after_submit, missing, history,
                            missing_fails, history_fails,
                            register_days, academic_year, closures))
    pg.goto(BASE + "/portal/register/", wait_until="networkidle")
    pg.wait_for_timeout(420)
    return pg


def calls(pg, name):
    return [c for c in pg.evaluate("() => window.__calls") if c["name"] == name]


def run():
    with sync_playwright() as p:
        browser = p.chromium.launch()

        # ============ WHO GETS IN ============
        pg = open_screen(browser, [])
        check("a role-less account is refused", pg.locator("#rg-panel").is_hidden())
        check("and no class was fetched for them",
              len(calls(pg, "madrasah_registers_list")) == 0)
        pg.close()

        # ============ THE GATE ============
        pg = open_screen(browser, ["madrasah"], permitted=False, told=100)
        check("a teacher sees the gate when parents have not been told",
              pg.locator("#rg-gate").is_visible())
        g = pg.inner_text("#rg-gate")
        check("and it says how many are left", "230" in g, g[:240])
        check("and says the notice promised them",
              "privacy notice" in g.lower(), g)
        check("and says the database refuses it too, not just this page",
              "another screen" in g.lower() or "database refuses" in g.lower(), g)
        check("and gives a way out rather than being a wall",
              pg.locator('#rg-gate a[href="../notices/"]').count() == 1)
        check("the bar shows the job partly done",
              pg.evaluate("""() => document.querySelector('#rg-bar span, .rg-bar span')
                              .style.width""") == "30%",
              pg.evaluate("""() => document.querySelector('.rg-bar span').style.width"""))
        #  THE CLASSES ARE STILL LISTED. Refusing to save is not a reason to
        #  hide the evening — a teacher can still see what is on, and print a
        #  paper register, which is exactly what they would do.
        check("the evening is still on screen, so paper is still possible",
              pg.locator(".rg-class").count() == 3)
        pg.close()

        pg = open_screen(browser, ["madrasah"])
        check("with every family told, the gate is gone",
              pg.locator("#rg-gate").is_hidden())

        # ============ THE EVENING ============
        check("every class is listed", pg.locator(".rg-class").count() == 3)
        ev = pg.inner_text("#rg-classes")
        check("and it says how many still need a register",
              "2 classes still need" in ev, ev[:200])
        check("a class with a full register looks finished",
              "is-done" in (pg.locator('.rg-class[data-class="c2"]')
                            .get_attribute("class") or ""))
        check("and says how many were away rather than just 'done'",
              "1 away" in pg.inner_text('.rg-class[data-class="c2"]'),
              pg.inner_text('.rg-class[data-class="c2"]'))
        check("a half-taken one is marked as half-taken",
              "is-part" in (pg.locator('.rg-class[data-class="c3"]')
                            .get_attribute("class") or ""))
        check("a class with no teacher says so, because that is somebody's job",
              "no teacher set" in pg.inner_text('.rg-class[data-class="c3"]'),
              pg.inner_text('.rg-class[data-class="c3"]'))

        # ============ ONE CLASS ============
        pg.click('.rg-class[data-class="c1"]')
        pg.wait_for_timeout(350)
        check("opening a class puts the evening away",
              pg.locator("#rg-classes").is_hidden())
        check("and shows the children", pg.locator(".rg-row").count() == 4)
        t = pg.inner_text("#rg-taking")
        check("it names the class and the teacher",
              "Test Class One" in t and "Apa Testname" in t, t[:200])

        #  A MARK, NEVER THE NOTE.
        check("a child with something recorded carries a mark",
              pg.locator('.rg-row[data-pupil="p1"] .rg-med').count() == 1)
        check("and the mark is a link to that child's own record, which is "
              "written down",
              (pg.locator('.rg-row[data-pupil="p1"] .rg-med')
                 .get_attribute("href") or "").startswith("../pupil/?id="))
        check("and the note itself is nowhere on this screen",
              SECRET_MEDICAL not in pg.inner_text("body"))
        check("no other child is marked",
              pg.locator(".rg-med").count() == 1)

        #  A PARENT'S MESSAGE IS ON SCREEN BEFORE ANYBODY MARKS ANYTHING.
        check("a parent who rang in is shown to the teacher",
              "mother telephoned" in pg.inner_text('.rg-row[data-pupil="p3"]'),
              pg.inner_text('.rg-row[data-pupil="p3"]'))

        # ============ EVERYONE IS HERE ============
        pg.click('[data-all="present"]')
        pg.wait_for_timeout(250)
        on = pg.locator(".rg-present.is-on").count()
        check("'everyone is here' marks the children who have no message",
              on == 3, on)
        #  THE ONE THAT MATTERS. The database refuses it too, but a screen that
        #  appears to sweep a mother's message away and is then silently
        #  corrected is worse than one that never appeared to.
        check("and it does NOT sweep away the parent's message on screen",
              pg.locator('.rg-row[data-pupil="p3"] .rg-present.is-on').count() == 0)
        check("that child still shows as away",
              pg.locator('.rg-row[data-pupil="p3"] .rg-absent.is-on').count() == 1)
        check("the tally counts them", "3" in pg.inner_text(".rg-t-present"),
              pg.inner_text(".rg-tally"))

        # ============ AWAY, AND A REASON ============
        pg.click('.rg-row[data-pupil="p2"] .rg-absent')
        pg.wait_for_timeout(200)
        check("marking a child away opens a box for a reason",
              pg.locator('.rg-row[data-pupil="p2"] .rg-reason-i').count() == 1)
        check("and the reason is optional, so a teacher who does not know "
              "is not stuck",
              "optional" in (pg.locator('.rg-row[data-pupil="p2"] .rg-reason-i')
                             .get_attribute("placeholder") or ""))
        pg.fill('.rg-row[data-pupil="p2"] .rg-reason-i', "at a funeral")
        pg.wait_for_timeout(200)

        # ============ SAVING ============
        #  save() now calls save_register_draft — the RPC that only ever
        #  saves and never submits, so an interrupted teacher loses nothing.
        #  (Every row is marked by this point — "Everyone is here" plus the
        #  parent's own mark on p3 — so Hand-in has already opened; that
        #  transition is proved properly, with its own fixture, below.)
        pg.click("#rg-save")
        pg.wait_for_timeout(500)
        sent = calls(pg, "save_register_draft")
        check("saving sends one call for the whole class", len(sent) == 1, len(sent))
        check("and never the old submit-on-save mark_register",
              len(calls(pg, "mark_register")) == 0)
        marks = sent[0]["args"]["p_marks"] if sent else []
        by = dict((m["pupil_id"], m) for m in marks)
        check("the class and the day go with it",
              sent and sent[0]["args"]["p_class"] == "c1"
              and sent[0]["args"]["p_date"] == TODAY, sent and sent[0]["args"])
        check("a child who was here is sent as present",
              by.get("p1", {}).get("mark") == "present", by.get("p1"))
        #  TYPING A REASON IS THE DECISION. A teacher never has to choose
        #  between two kinds of away.
        check("a child away WITH a reason is sent as 'excused'",
              by.get("p2", {}).get("mark") == "excused", by.get("p2"))
        check("and the reason goes with it",
              by.get("p2", {}).get("reason") == "at a funeral", by.get("p2"))
        ok = pg.inner_text("#rg-ok")
        check("and it says what happened", "saved" in ok.lower(), ok)
        check("including that a parent's message was left alone",
              "left as it was" in ok.lower(), ok)

        # ============ LOSING A HALF-TAKEN REGISTER ============
        pg.click('.rg-class[data-class="c1"]') if pg.locator("#rg-classes").is_visible() \
            else None
        pg.wait_for_timeout(300)
        if pg.locator("#rg-taking").is_hidden():
            pg.click('.rg-class[data-class="c1"]')
            pg.wait_for_timeout(300)
        pg.click('.rg-row[data-pupil="p4"] .rg-late')
        pg.wait_for_timeout(200)
        #  Leaving with marks unsaved must ask. A mis-tap losing twenty marks
        #  is how somebody goes back to paper and never comes back.
        asked = {"n": 0}
        pg.on("dialog", lambda d: (asked.__setitem__("n", asked["n"] + 1),
                                   d.dismiss()))
        pg.click("#rg-back")
        pg.wait_for_timeout(300)
        check("leaving a half-taken register asks first", asked["n"] == 1, asked)
        check("and dismissing keeps you where you were",
              pg.locator("#rg-taking").is_visible())

        # ============ THE PAPER REGISTER ============
        pg.emulate_media(media="print")
        pg.wait_for_timeout(150)
        pg.click('[data-do="print"]')
        pg.wait_for_timeout(400)
        check("it asks the browser to print",
              pg.evaluate("() => window.__printed") == 1)
        vis = pg.evaluate("() => window.__atPrint") or {}
        check("the paper register prints", vis.get("paper"), vis)
        check("the rail does not", not vis.get("rail"), vis)
        check("nor the marking buttons", not vis.get("marks"), vis)
        check("the sheet is moved out to body, away from the cascade fight "
              "with the rail's own !important", vis.get("atBodyLevel") is True, vis)
        sheet = pg.inner_text("#rg-print")
        check("it names the masjid, the class and the evening",
              "Taiyabah" in sheet and "Test Class One" in sheet, sheet[:200])
        check("and lists the children", "Aaliyah Test" in sheet and "Maryam Test" in sheet)
        check("with columns to tick", "Here" in sheet and "Late" in sheet
              and "Away" in sheet, sheet[:400])
        #  IT IS CARRIED BETWEEN ROOMS AND LEFT ON DESKS.
        check("the paper carries NO medical mark at all",
              pg.locator("#rg-print .rg-med").count() == 0
              and "medical" not in sheet.lower().split("carries no")[0])
        check("and it says so on the sheet, so nobody adds one by hand",
              "no medical or contact" in sheet.lower(), sheet[-180:])
        check("and it says where the sheet goes afterwards",
              "office" in sheet.lower(), sheet[-220:])
        pg.emulate_media(media="screen")
        pg.close()

        # ============ A DAY THAT HAS NOT HAPPENED ============
        pg = open_screen(browser, ["madrasah"])
        check("the date box will not offer tomorrow",
              pg.locator("#rg-date").get_attribute("max") == TODAY,
              pg.locator("#rg-date").get_attribute("max"))
        pg.close()

        # =====================================================================
        #  HAND-IN: THE GATE, AND THE GATE OPENING
        #
        #  A CHECK THAT FINDS A SHUT GATE IS NOT A CHECK THAT IT OPENS. The
        #  state that matters to a teacher is the transition: they mark the
        #  last child and the button must become usable WITHOUT A RELOAD.
        #  Three states, proved in order: shut with one child left, open the
        #  moment the last one is marked, and handed in.
        # =====================================================================
        pgh = open_screen(browser, ["madrasah"], rows=GATE_ROWS, classes=GATE_CLASSES)
        pgh.click('.rg-class[data-class="gc1"]')
        pgh.wait_for_timeout(350)

        # ---- STATE 1: one child of three is unmarked ----
        state = pgh.evaluate("""() => {
          var s = document.getElementById('rg-submit');
          var n = document.querySelector('.rg-save-n');
          return s ? {disabled: !!s.disabled,
                      counter: n ? n.textContent : null,
                      unmarkedRows: document.querySelectorAll('.rg-row:not(.is-marked)').length}
                   : null;
        }""")
        check("the register has a Hand-in button", state is not None)
        check("Hand-in is disabled while a child is unmarked",
              state and state["disabled"], state)
        check("the unmarked child is distinguishable in the list",
              state and state["unmarkedRows"] == 1, state)
        check("the counter says what is left",
              state and state["counter"] and "not marked yet" in state["counter"], state)
        #  VISIBLY, not only structurally — a different rule fires for the
        #  unmarked row, not merely the absence of .is-marked.
        colours = pgh.evaluate("""() => {
          var m = document.querySelector('.rg-row.is-marked');
          var u = document.querySelector('.rg-row:not(.is-marked)');
          return { marked: m && getComputedStyle(m).backgroundColor,
                   unmarked: u && getComputedStyle(u).backgroundColor };
        }""")
        check("and it reads differently on screen, not just in a class name",
              colours["marked"] != colours["unmarked"], colours)

        #  A marker that only survives if the page is NOT reloaded.
        pgh.evaluate("() => { window.__stillHere = 'yes'; }")

        # ---- STATE 2: the last child is marked ----
        pgh.click('.rg-row[data-pupil="g3"] .rg-present')
        pgh.wait_for_timeout(250)
        check("marking the last child does not reload the page",
              pgh.evaluate("() => window.__stillHere") == "yes")
        state2 = pgh.evaluate(
            "() => { var s = document.getElementById('rg-submit'); "
            "return s ? !!s.disabled : null; }")
        check("HAND-IN BECOMES ENABLED THE MOMENT THE LAST CHILD IS MARKED, "
              "WITH NO RELOAD — this is the bug the task exists to fix if it "
              "does not",
              state2 is False, state2)
        check("marking alone made no network call yet",
              len(calls(pgh, "save_register_draft")) == 0
              and len(calls(pgh, "submit_register")) == 0)

        # ---- STATE 3: handed in ----
        pgh.click("#rg-submit")
        pgh.wait_for_timeout(500)
        drafted = calls(pgh, "save_register_draft")
        check("Hand-in saves the newly-marked child first — submit_register "
              "reads what is WRITTEN, not what is only on screen, so handing "
              "in without saving first would be refused for a register the "
              "teacher can see is complete",
              len(drafted) == 1, drafted)
        submitted = calls(pgh, "submit_register")
        check("and then hands the register in, once, for the right class and day",
              submitted and submitted[0]["args"]["p_class"] == "gc1"
              and submitted[0]["args"]["p_date"] == TODAY, submitted)
        ok = pgh.inner_text("#rg-ok")
        check("the register renders as done — the teacher is told it was handed in",
              "handed in" in ok.lower(), ok)
        check("no error is left showing", pgh.locator("#rg-error").is_hidden())
        state3 = pgh.evaluate(
            "() => { var n = document.querySelector('.rg-save-n'); "
            "return n ? n.textContent : null; }")
        check("and the count reads as fully marked",
              state3 and "every child is marked" in state3.lower(), state3)

        #  I5 — mark_register STILL EXISTS AND NOW ONLY SAVES. Nothing on
        #  this screen calls it any more; this proves the STUB tells the
        #  truth about the live function rather than the old db/091 shape,
        #  because a stub that lies passes a test that proves nothing.
        shape = pgh.evaluate(
            "(d) => window.supabase.createClient().rpc('mark_register', "
            "{p_class:'gc1', p_date:d, "
            "p_marks:[{pupil_id:'g3', mark:'present', reason:null}]})"
            ".then(function(r){ return r.data; })", TODAY)
        check("mark_register's stub now matches the live save-only contract",
              shape and shape.get("submitted") is False and "missing" in shape,
              shape)
        pgh.close()

        # ---- A REFUSED HAND-IN IS SHOWN TO THE TEACHER, IN PLAIN WORDS ----
        #  Simulates the database refusing submit_register (a race on the
        #  roll, say) on an otherwise fully-marked class, to prove the
        #  wording a volunteer actually reads — not just that an error
        #  banner exists.
        pgr = open_screen(
            browser, ["madrasah"],
            rows=[{"id": "r1", "name": "Ibrahim Test", "reference": "4001",
                   "status": "on_roll", "has_medical": False, "mark": "present",
                   "reason": None, "source": None}],
            classes=[{"id": "rc1", "name": "Test Class Refused", "section": "boys",
                      "sort_order": 1, "teacher": "Apa Refusedname",
                      "on_roll": 1, "marked": 1, "away": 0}],
            submit_fails="2 of 9 children have no mark yet. Every child needs "
                         "one before the register can be handed in.")
        pgr.click('.rg-class[data-class="rc1"]')
        pgr.wait_for_timeout(350)
        pgr.click("#rg-submit")
        pgr.wait_for_timeout(500)
        err = pgr.inner_text("#rg-error")
        check("a refused hand-in is put in front of the teacher in plain "
              "words, not swallowed",
              "not handed in" in err.lower(), err)
        check("and it names how many children are missing, the way a "
              "volunteer can act on, not just 'refused'",
              "2 of 9" in err, err)
        check("and it says clearly that their marks are safe, so nobody "
              "thinks a refusal lost their work",
              "saved" in err.lower(), err)
        pgr.close()

        #  THE OTHER HALF OF THE SAME PROMISE: when the marks themselves
        #  could not be written, the teacher is told that too, and told to
        #  try again — never left thinking a save happened when it did not.
        pgs = open_screen(
            browser, ["madrasah"], rows=GATE_ROWS, classes=GATE_CLASSES,
            save_fails="That evening is more than a fortnight ago. Ask the "
                       "office to correct it.")
        pgs.click('.rg-class[data-class="gc1"]')
        pgs.wait_for_timeout(350)
        pgs.click('.rg-row[data-pupil="g3"] .rg-present')
        pgs.wait_for_timeout(200)
        pgs.click("#rg-submit")
        pgs.wait_for_timeout(500)
        err2 = pgs.inner_text("#rg-error")
        check("when the save behind Hand-in fails, the teacher is told "
              "their marks were NOT saved, not reassured wrongly",
              "not saved" in err2.lower(), err2)
        check("submit_register was never reached", len(calls(pgs, "submit_register")) == 0)
        pgs.close()

        # =====================================================================
        #  THE STUB NOW MATCHES save_register_draft()'s OWN GATES (Task 12).
        #
        #  Carried forward from Task 8: this stub's save_register_draft
        #  handler had no gate of its own — it always succeeded regardless
        #  of the day, a closure, or whether parents had been told, which is
        #  KINDER THAN THE DATABASE. These three cases are read off the
        #  installed function (pg_get_functiondef, not the migration file,
        #  in case a later fix-round changed it): register_due()'s weekday
        #  check, its closure check, and save_register_draft()'s own
        #  attendance_permitted() recheck — a FOURTH, independent gate from
        #  the page-load #rg-gate this screen already draws.
        #
        #  Changing #rg-date closes whatever class is open (register_module.
        #  js sets OPEN=null on the 'change' handler), so each case changes
        #  the date FIRST, on the evening view, then opens the class.
        # =====================================================================
        _today = datetime.date.today()
        #  The most recent Sunday on or before today (today.isoweekday() is
        #  1=Monday..7=Sunday, so %7 turns Sunday itself into 0).
        _sunday = _today - datetime.timedelta(days=_today.isoweekday() % 7)
        #  Exactly one week before today — the same day of the week, so it
        #  passes the WEEKDAY check on its own and isolates the CLOSURE
        #  check this case is actually testing.
        _closure_day = _today - datetime.timedelta(days=7)

        # ---- SAVING ON A SUNDAY: register_due()'s weekday check ----
        pgsun = open_screen(browser, ["madrasah"], rows=GATE_ROWS, classes=GATE_CLASSES)
        pgsun.fill("#rg-date", str(_sunday))
        pgsun.evaluate("document.getElementById('rg-date')"
                       ".dispatchEvent(new Event('change'))")
        pgsun.wait_for_timeout(350)
        pgsun.click('.rg-class[data-class="gc1"]')
        pgsun.wait_for_timeout(350)
        pgsun.click('.rg-row[data-pupil="g1"] .rg-present')
        pgsun.wait_for_timeout(200)
        pgsun.click("#rg-save")
        pgsun.wait_for_timeout(500)
        errsun = pgsun.inner_text("#rg-error")
        check("save_register_draft's OWN register_due() gate refuses a "
              "Sunday, in the database's own words — not a screen "
              "assumption of which evenings are register evenings",
              "does not run on a Sunday" in errsun, errsun)
        check("and the teacher is told the save itself did not happen",
              "would not save" in errsun.lower(), errsun)
        check("the refusal came from the stub's own gate, not a hand-typed "
              "save_fails string standing in for it",
              len(calls(pgsun, "save_register_draft")) == 1)
        pgsun.close()

        # ---- SAVING INSIDE A CLOSURE: register_due()'s closure check ----
        pgclo = open_screen(
            browser, ["madrasah"], rows=GATE_ROWS, classes=GATE_CLASSES,
            closures=[{"name": "Test Closure Week",
                       "starts_on": str(_closure_day),
                       "ends_on": str(_closure_day)}])
        pgclo.fill("#rg-date", str(_closure_day))
        pgclo.evaluate("document.getElementById('rg-date')"
                       ".dispatchEvent(new Event('change'))")
        pgclo.wait_for_timeout(350)
        pgclo.click('.rg-class[data-class="gc1"]')
        pgclo.wait_for_timeout(350)
        pgclo.click('.rg-row[data-pupil="g1"] .rg-present')
        pgclo.wait_for_timeout(200)
        pgclo.click("#rg-save")
        pgclo.wait_for_timeout(500)
        errclo = pgclo.inner_text("#rg-error")
        check("register_due()'s closure check refuses a save too, naming "
              "the closure the same way the live function does",
              "Test Closure Week" in errclo, errclo)
        check("a date one week earlier, same weekday, outside the closure, "
              "is unaffected — this is the closure check, not the weekday "
              "check firing again",
              _closure_day.isoweekday() == _today.isoweekday())
        pgclo.close()

        # ---- SAVING WHILE THE REGISTER IS NOT OPEN: save_register_draft's
        #      OWN attendance_permitted() RECHECK, independent of the
        #      page-load #rg-gate. A teacher can still see and open a class
        #      while the gate is up ("the evening is still on screen, so
        #      paper is still possible", proved earlier) and Save is never
        #      disabled by GATE.permitted — so this is the one path by
        #      which a save attempt actually reaches the server while
        #      parents have not been told. ----
        pgnp = open_screen(
            browser, ["madrasah"], permitted=False, told=100,
            rows=GATE_ROWS, classes=GATE_CLASSES)
        pgnp.click('.rg-class[data-class="gc1"]')
        pgnp.wait_for_timeout(350)
        pgnp.click('.rg-row[data-pupil="g1"] .rg-present')
        pgnp.wait_for_timeout(200)
        pgnp.click("#rg-save")
        pgnp.wait_for_timeout(500)
        errnp = pgnp.inner_text("#rg-error")
        check("save_register_draft's attendance_permitted() RECHECK refuses "
              "a save while the register is not open, naming how many "
              "families are left — the database's own words, not the "
              "screen's",
              "230" in errnp and "told" in errnp.lower(), errnp)
        check("this is a database refusal reached through a real save "
              "attempt, not the client-side #rg-gate quietly eating the "
              "click",
              len(calls(pgnp, "save_register_draft")) == 1)
        pgnp.close()

        # =====================================================================
        #  A SUBMITTED REGISTER SAYS SO (db/110)
        #
        #  madrasah_register_list() now returns the register's own state and
        #  submitted_at alongside the class. A teacher who hands a register
        #  in and comes back to it later must be told — not shown the
        #  identical screen a fully-marked draft would show.
        # =====================================================================
        SUBMITTED_AT = "2026-09-28T17:32:00.000Z"

        # ---- A: draft and incomplete — no acknowledgement of any kind ----
        pgd = open_screen(browser, ["madrasah"], rows=GATE_ROWS, classes=GATE_CLASSES)
        pgd.click('.rg-class[data-class="gc1"]')
        pgd.wait_for_timeout(350)
        check("a draft, incomplete register carries no handed-in badge",
              pgd.locator(".rg-handed").count() == 0)
        head_text = pgd.inner_text(".rg-taking-head")
        check("and nothing in the header claims it was handed in",
              "handed in" not in head_text.lower(), head_text)
        check("Hand-in is still the outstanding action, disabled with a "
              "child left",
              pgd.locator("#rg-submit").get_attribute("disabled") is not None)
        pgd.close()

        # ---- B: handed in — shown as handed in, WITH ITS TIME ----
        pgb = open_screen(
            browser, ["madrasah"], rows=GATE_ROWS_FULL, classes=GATE_CLASSES,
            register_state={"gc1": {"state": "submitted",
                                     "submitted_at": SUBMITTED_AT}})
        #  Derived the same way the screen derives it, so this check does not
        #  assume a timezone — only that the screen's arithmetic is the
        #  same arithmetic, on the same instant.
        expected_time = pgb.evaluate(
            "(iso) => { var d = new Date(iso); var h = d.getHours(); "
            "var ap = h>=12?'pm':'am'; var h12=h%12; if(h12===0)h12=12; "
            "function p(n){return (n<10?'0':'')+n;} "
            "return h12+':'+p(d.getMinutes())+ap; }", SUBMITTED_AT)
        pgb.click('.rg-class[data-class="gc1"]')
        pgb.wait_for_timeout(350)
        check("a handed-in register carries a handed-in badge",
              pgb.locator(".rg-handed").count() == 1)
        badge = pgb.inner_text(".rg-handed")
        check("in words a teacher would use", "handed in" in badge.lower(), badge)
        check("and gives the actual TIME it was handed in, not just the "
              "fact of it", expected_time in badge, (badge, expected_time))
        check("the button that would invite a second press is gone",
              pgb.locator("#rg-submit").count() == 0)
        check("but Save is still there and enabled — submitting is not a lock",
              pgb.locator("#rg-save").count() == 1
              and pgb.locator("#rg-save").get_attribute("disabled") is None)
        pgb.close()

        # ---- C: handed in, then a mark corrected — STILL handed in ----
        pgc = open_screen(
            browser, ["madrasah"], rows=GATE_ROWS_FULL, classes=GATE_CLASSES,
            register_state={"gc1": {"state": "submitted",
                                     "submitted_at": SUBMITTED_AT}})
        pgc.click('.rg-class[data-class="gc1"]')
        pgc.wait_for_timeout(350)
        check("opens already showing handed in", pgc.locator(".rg-handed").count() == 1)
        #  A CORRECTION. g1 was marked "present"; the teacher now knows they
        #  were actually late. Every child on the roll still has a mark.
        pgc.click('.rg-row[data-pupil="g1"] .rg-late')
        pgc.wait_for_timeout(200)
        check("correcting a mark, before Save, does not clear the "
              "acknowledgement on its own",
              pgc.locator(".rg-handed").count() == 1)
        pgc.click("#rg-save")
        pgc.wait_for_timeout(500)
        check("Save still works on a submitted register — handing in is not "
              "a lock", len(calls(pgc, "save_register_draft")) == 1)
        check("and a correction that leaves every child marked keeps it "
              "handed in — db/102 only ever demotes, never promotes",
              pgc.locator(".rg-handed").count() == 1)
        badge_after = pgc.inner_text(".rg-handed")
        check("with the SAME time as before — a correction is not a "
              "resubmission", expected_time in badge_after, badge_after)
        pgc.close()

        # ---- CONTROL: a child joins the roll afterwards — falls back to
        #      draft, and the screen follows it. THE CASE NOBODY WOULD THINK
        #      TO CHECK (db/102's own reason for existing), proved here on
        #      the screen rather than only in the database. ----
        GATE_ROWS_PLUS_ONE = GATE_ROWS_FULL + [
            {"id": "g4", "name": "Ismail Test", "reference": "3004",
             "status": "on_roll", "has_medical": False, "mark": None,
             "reason": None, "source": None}]
        GATE_CLASSES_PLUS_ONE = [dict(GATE_CLASSES[0], on_roll=4)]
        pgf2 = open_screen(
            browser, ["madrasah"], rows=GATE_ROWS_PLUS_ONE,
            classes=GATE_CLASSES_PLUS_ONE,
            register_state={"gc1": {"state": "submitted",
                                     "submitted_at": SUBMITTED_AT}})
        pgf2.click('.rg-class[data-class="gc1"]')
        pgf2.wait_for_timeout(350)
        check("still opens showing handed in — the new child has not been "
              "saved against yet", pgf2.locator(".rg-handed").count() == 1)
        pgf2.click("#rg-save")
        pgf2.wait_for_timeout(500)
        check("a child joining the roll drops the register below complete, "
              "and the screen follows it back to draft on its own",
              pgf2.locator(".rg-handed").count() == 0,
              pgf2.inner_text("#rg-taking"))
        check("Hand-in is the outstanding action again",
              pgf2.locator("#rg-submit").count() == 1)
        pgf2.close()

        # =====================================================================
        #  TWO CONTRADICTORY MESSAGES AT ONCE (Task 8 review, Important)
        #
        #  submit_register() can succeed and the RELOAD that follows it can
        #  still fail (a network glitch between the two). Before the busy-
        #  guard fix above, that reload never actually ran, so this could
        #  not happen. It can now: without a fix, the teacher would see
        #  "Register handed in. Thank you." and a failure banner together,
        #  with nothing telling them which one describes their register.
        # =====================================================================
        pgx = open_screen(
            browser, ["madrasah"], rows=GATE_ROWS_FULL, classes=GATE_CLASSES,
            reload_fails_after_submit="a network glitch")
        pgx.click('.rg-class[data-class="gc1"]')
        pgx.wait_for_timeout(350)
        pgx.click("#rg-submit")
        pgx.wait_for_timeout(600)
        ok_visible = pgx.locator("#rg-ok").is_visible()
        err_visible = pgx.locator("#rg-error").is_visible()
        check("the teacher is never shown a success banner and a failure "
              "banner at the same time",
              not (ok_visible and err_visible),
              {"ok_visible": ok_visible, "err_visible": err_visible})
        err_text = pgx.inner_text("#rg-error") if err_visible else ""
        check("the register did go in — submit_register was actually called "
              "and succeeded", len(calls(pgx, "submit_register")) == 1)
        check("but the message names the SCREEN NOT REFRESHING, not the "
              "hand-in — the write is not in doubt",
              "handed in" in err_text.lower()
              and "refresh" in err_text.lower()
              and "was not handed in" not in err_text.lower(),
              err_text)
        pgx.close()

        # ---- NEGATIVE CONTROLS, FOR REAL — each of A, B and C above, broken
        #      one throwaway edit at a time in the real module, watched
        #      failing, then restored. See task-8-report.md for the
        #      break/restore transcript; this comment marks where in the
        #      run those three checks live.
        # =====================================================================
        #  A TEACHER
        #
        #  THE POINT OF THIS WHOLE SECTION. The `teacher` role has existed in
        #  the enum since the beginning and granted nothing, so the obvious way
        #  to give a teacher the register was to grant them `madrasah` - which
        #  hands over all 552 children, every family's address and telephone
        #  number, every medical mark, the fees and the applications. The role
        #  that looks like the answer is the breach.
        #
        #  The scoping lives in the database (db/090), so these checks are
        #  about the screen not UNDOING it: not calling the office's functions,
        #  not linking somewhere a teacher will be refused, and not showing a
        #  field the teacher's own function never returned.
        # =====================================================================
        pgt = open_screen(browser, ["teacher"],
                          classes=[CLASSES[0]])   # the database returns theirs only
        check("a teacher gets the register screen",
              pgt.locator("#rg-panel").is_visible())
        check("and sees the classes the database gave them",
              pgt.locator(".rg-class").count() == 1,
              pgt.locator(".rg-class").count())

        pgt.click('.rg-class[data-class="c1"]')
        pgt.wait_for_timeout(350)
        check("and can open one", pgt.locator("#rg-taking").is_visible())

        #  THE MEDICAL MARK MUST NOT LINK TO THE OFFICE'S PAGE.
        #  ../pupil/ calls madrasah_pupil_one(), which refuses a teacher. A
        #  link there is a dead end dressed up as a safeguard: the teacher
        #  taps it, is refused, and learns the system is broken rather than
        #  that the job is not theirs.
        check("the medical mark is not a link to the office's record",
              pgt.locator('.rg-med[href]').count() == 0)
        check("it is something that opens here instead",
              pgt.locator('.rg-med[data-child]').count() == 1)
        check("and every child can be opened, not only the marked one",
              pgt.locator(".rg-open[data-child]").count() == 4,
              pgt.locator(".rg-open[data-child]").count())

        pgt.click('.rg-row[data-pupil="p1"] .rg-med')
        pgt.wait_for_timeout(400)
        check("opening a child asks the TEACHER'S function",
              len(calls(pgt, "madrasah_pupil_for_teacher")) == 1)
        check("and never the office's",
              len(calls(pgt, "madrasah_pupil_one")) == 0,
              "madrasah_pupil_one was called by a teacher")

        card = pgt.inner_text("#rg-child")
        check("the card carries the medical note, which is why it is held",
              SECRET_MEDICAL in card, card[:200])
        check("and the allergy", "peanuts" in card)
        check("and who to ring", SECRET_PHONE in card, card[:300])
        check("and that this child must not walk home alone",
              "walk home" in card.lower(), card)
        #  THE OFFICE FIELDS MUST NOT BE ANYWHERE ON THE PAGE.
        body = pgt.inner_text("body")
        check("the child's home address is nowhere on a teacher's screen",
              SECRET_ADDRESS not in body)
        check("nor their date of birth", SECRET_DOB not in body)

        # ---- raising a concern ----
        pgt.click("#rg-concern")
        pgt.wait_for_timeout(250)
        conc = pgt.inner_text("#rg-concern-box")
        #  THE ONLY PART OF THIS FORM THAT COULD SAVE ANYBODY.
        check("the form says first that it is the wrong tool in an emergency",
              "wrong tool" in conc.lower(), conc[:200])
        check("and says what to do instead",
              "999" in conc and "safeguarding lead" in conc.lower(), conc[:300])
        #  READ OFF THE PLACEHOLDER, not the text content. A placeholder is an
        #  attribute and never appears in inner_text - the first version of
        #  this check looked for it in the text and failed for a reason that
        #  had nothing to do with the screen. Same mistake as looking for a
        #  ::before label in inner_text on the Families cards.
        ph = (pgt.locator("#rg-c-what").get_attribute("placeholder") or "")
        check("and asks for what happened rather than what it means, where "
              "the teacher is actually typing",
              "rather than what you" in ph.lower(), ph)

        check("nothing has been sent yet", len(calls(pgt, "raise_concern")) == 0)
        pgt.click("#rg-c-send")
        pgt.wait_for_timeout(250)
        check("it refuses to send an empty concern",
              len(calls(pgt, "raise_concern")) == 0)
        check("and says why", "what happened" in pgt.inner_text("#rg-error").lower(),
              pgt.inner_text("#rg-error"))

        pgt.fill("#rg-c-what", "ZZ test: something I was told this evening.")
        pgt.fill("#rg-c-when", "second half")
        pgt.click("#rg-c-send")
        pgt.wait_for_timeout(500)
        sent = calls(pgt, "raise_concern")
        check("sending it calls raise_concern once", len(sent) == 1, len(sent))
        check("with the child and what was said",
              sent and sent[0]["args"]["p_pupil"] == "p1"
              and "ZZ test" in sent[0]["args"]["p_what"], sent)
        told = pgt.inner_text("#rg-ok")
        check("the teacher is given the reference", "SC-26-0007" in told, told)
        #  WRITE-ONLY, AND THE SCREEN SAYS SO. A concern may be about a
        #  colleague; a screen that lets the raiser watch what happened next
        #  turns a safeguarding report into a conversation.
        check("and told they cannot look it up here",
              "cannot look it up" in told.lower(), told)
        check("the card closes, so the concern is not left on screen",
              pgt.locator("#rg-child").is_hidden())
        pgt.close()

        # =====================================================================
        #  TASK 11 — WHAT WAS NEVER TAKEN.
        # =====================================================================
        EXPECT_FROM = str(datetime.date.today() - datetime.timedelta(days=14))
        EXPECT_TO = str(datetime.date.today() - datetime.timedelta(days=1))

        pgm = open_screen(browser, ["madrasah"], missing=REGISTERS_MISSING)
        check("the office is shown what was never taken",
              pgm.locator("#rg-missing").is_visible())
        miss = pgm.inner_text("#rg-missing")
        check("headed as what it is", "never taken" in miss.lower(), miss[:200])
        check("and it names the class", "Test Class Five" in miss, miss[:300])
        check("and the teacher, so the office knows who to follow up with",
              "Apa Fivename" in miss, miss[:300])
        mcalls = calls(pgm, "registers_missing")
        check("registers_missing is asked exactly once for the evening load",
              len(mcalls) == 1, len(mcalls))
        #  RULING C. The default window (p_from/p_to omitted) reads a
        #  different, larger number on this masjid than the fortnight the
        #  panel's own words promise — the window must be named explicitly
        #  so the number and the sentence above it are the same claim.
        check("the window is explicit and excludes tonight, not "
              "registers_missing()'s own default",
              mcalls and mcalls[0]["args"] == {"p_from": EXPECT_FROM, "p_to": EXPECT_TO},
              mcalls and mcalls[0]["args"])

        #  THE PANEL IS PART OF THE EVENING VIEW, LIKE THE GRID BESIDE IT —
        #  put away the moment a class opens, and no second network call to
        #  come back to it.
        pgm.click('.rg-class[data-class="c1"]')
        pgm.wait_for_timeout(300)
        check("opening a class puts the missed list away too",
              pgm.locator("#rg-missing").is_hidden())
        pgm.click("#rg-back")
        pgm.wait_for_timeout(300)
        check("and closing it brings the missed list back",
              pgm.locator("#rg-missing").is_visible())
        check("without asking the database again for it",
              len(calls(pgm, "registers_missing")) == 1)
        pgm.close()

        #  RULING D. attendance_permitted() is false, live, today — 330
        #  families untold. A "Registers never taken" panel in that state
        #  would read as an accusation against every teacher for a lock the
        #  office itself holds. #rg-gate already says the true thing; this
        #  panel must not invent a second, different way of saying it.
        pgl = open_screen(browser, ["madrasah"], permitted=False, told=100,
                          missing=REGISTERS_MISSING)
        check("the missed-registers panel does not contradict a locked "
              "register — it is not drawn at all while marking is not "
              "permitted",
              pgl.locator("#rg-missing").is_hidden())
        check("and the question is not even asked of the database",
              len(calls(pgl, "registers_missing")) == 0)
        check("the gate above it is what says the true thing",
              pgl.locator("#rg-gate").is_visible())
        pgl.close()

        # =====================================================================
        #  REVIEW FIX — A GENUINE FAILURE MUST NOT LOOK LIKE "ALL CLEAR".
        #
        #  Three different causes for the missed-registers panel showing
        #  nothing behind it, and three different, deliberately DIFFERENT
        #  outcomes on screen: a real RPC error gets a line saying so; a
        #  legitimate refusal (allowed:false) and an honestly empty list
        #  both stay silent, same as before — because those are not
        #  failures, they are answers.
        # =====================================================================

        #  1. A GENUINE FAILURE. Distinguishable from all-clear: the panel
        #     is ON SCREEN, not hidden, and says it could not check.
        pgerr = open_screen(browser, ["madrasah"], missing_fails="a network glitch")
        check("a genuine registers_missing() failure is shown, not hidden",
              pgerr.locator("#rg-missing").is_visible())
        merr = pgerr.inner_text("#rg-missing")
        check("and says it could not check, in words that say so",
              "could not" in merr.lower() and "check" in merr.lower(), merr[:200])
        check("naming what failed, not a generic error",
              "registers never taken" in merr.lower(), merr[:200])
        pgerr.close()

        #  2. A LEGITIMATE REFUSAL. Not a failure — stays silent, exactly as
        #     ruling D already established for the client-side gate. Here
        #     the gate is OPEN and the database itself refuses, proving the
        #     silence is about what allowed:false MEANS, not merely about
        #     never asking.
        pgref = open_screen(browser, ["madrasah"],
                            missing={"allowed": False})
        check("a database refusal (allowed:false) stays silent, not an "
              "error line", pgref.locator("#rg-missing").is_hidden())
        check("registers_missing WAS asked — this is a real refusal, not "
              "the client-side gate skipping the question",
              len(calls(pgref, "registers_missing")) == 1)
        pgref.close()

        #  3. AN HONESTLY EMPTY LIST. Also not a failure — also silent.
        pgemp = open_screen(browser, ["madrasah"],
                            missing={"allowed": True, "count": 0, "rows": []})
        check("nothing missing reads as nothing on screen, not an error",
              pgemp.locator("#rg-missing").is_hidden())
        pgemp.close()

        #  The negative control for check #1 above — proving it can actually
        #  fail, not only pass by construction — is run against the real
        #  module (break the real fetchMissing(), watch this exact check
        #  fail, restore), not simulated here. See task-11-report.md for the
        #  break/restore transcript; a control faked by poking the DOM in
        #  the test itself would prove nothing about the real code.

        #  THE SAME QUESTION, FOR THE HISTORY. If the office presses "show
        #  the history" and the call fails, they must be told — not left
        #  looking at a control that did nothing.
        pgherr = open_screen(browser, ["madrasah"], rows=GATE_ROWS_FULL,
                             classes=GATE_CLASSES,
                             history_fails="a network glitch")
        pgherr.click('.rg-class[data-class="gc1"]')
        pgherr.wait_for_timeout(300)
        before_press = pgherr.inner_text("#rg-history-toggle")
        pgherr.click("#rg-history-toggle")
        pgherr.wait_for_timeout(400)
        herr = pgherr.inner_text("#rg-error")
        check("a failed history fetch tells the office, not just a silent "
              "collapse",
              "history" in herr.lower() and "would not open" in herr.lower(), herr)
        check("the panel does not sit open claiming to hold an answer it "
              "does not have",
              pgherr.locator("#rg-history").is_hidden()
              or pgherr.locator("#rg-history").count() == 0)
        after_press = pgherr.inner_text("#rg-history-toggle")
        check("and the control resets so the office can press it again, "
              "rather than being left stuck open on nothing",
              after_press.strip() == before_press.strip(),
              (before_press, after_press))
        pgherr.close()

        # =====================================================================
        #  TASK 11 — WHAT A MARK USED TO SAY. Ruling A: named children, so
        #  this is a control the office presses, not a panel drawn the
        #  moment a class opens.
        # =====================================================================
        pgh2 = open_screen(browser, ["madrasah"], rows=GATE_ROWS_FULL,
                           classes=GATE_CLASSES, history=HISTORY)
        pgh2.click('.rg-class[data-class="gc1"]')
        pgh2.wait_for_timeout(350)
        check("a class opening does NOT fetch the history",
              len(calls(pgh2, "register_history")) == 0)
        check("and the panel is not on screen",
              pgh2.locator("#rg-history").count() == 0
              or pgh2.locator("#rg-history").is_hidden())
        btn = pgh2.inner_text("#rg-history-toggle")
        check("a collapsed control invites the office to open it",
              "what this register has said" in btn.lower(), btn)

        pgh2.click("#rg-history-toggle")
        pgh2.wait_for_timeout(400)
        hcalls = calls(pgh2, "register_history")
        check("pressing it is what asks the database, once",
              len(hcalls) == 1, len(hcalls))
        check("for the right class and evening",
              hcalls and hcalls[0]["args"]["p_class"] == "gc1"
              and hcalls[0]["args"]["p_date"] == TODAY, hcalls)
        check("now it is on screen", pgh2.locator("#rg-history").is_visible())
        hist = pgh2.inner_text("#rg-history")
        check("naming the child", "ZZHistoryOne" in hist, hist[:300])
        check("what a mark used to say, in words that say so",
              "was" in hist.lower() or "changed" in hist.lower(), hist[:300])
        check("and who wrote it", "Apa Historyname" in hist, hist[:300])

        #  CLOSING IT COSTS NO NETWORK CALL.
        pgh2.click("#rg-history-toggle")
        pgh2.wait_for_timeout(250)
        check("closing it hides the panel", pgh2.locator("#rg-history").is_hidden())
        check("without a second call to the database",
              len(calls(pgh2, "register_history")) == 1)

        #  OPENING IT AGAIN ASKS AGAIN — the record must never be shown
        #  stale after the marks underneath it could have changed.
        pgh2.click("#rg-history-toggle")
        pgh2.wait_for_timeout(400)
        check("opening it a second time asks the database again, not a "
              "cached answer",
              len(calls(pgh2, "register_history")) == 2)
        pgh2.close()

        # =====================================================================
        #  TASK 11, RULING E — THE EVENING GRID SAYS WHICH REGISTERS ARE
        #  HANDED IN, NOT ONLY WHICH ARE FULLY MARKED.
        # =====================================================================
        pge = open_screen(browser, ["madrasah"], classes=STATE_CLASSES)
        handed = pge.inner_text('.rg-class[data-class="cs1"]')
        check("a register actually handed in reads as handed in",
              "handed in" in handed.lower(), handed)
        check("and carries the finished styling",
              "is-done" in (pge.locator('.rg-class[data-class="cs1"]')
                            .get_attribute("class") or ""))
        full_unsub = pge.inner_text('.rg-class[data-class="cs2"]')
        check("a class every child is marked in, but never handed in, "
              "does NOT read as handed in — the exact gap db/110 closed on "
              "the single-class view, one level up",
              "handed in" not in full_unsub.lower()
              or "not handed in" in full_unsub.lower(), full_unsub)
        check("and does not carry the finished styling either",
              "is-done" not in (pge.locator('.rg-class[data-class="cs2"]')
                                .get_attribute("class") or ""))
        pge.close()

        # =====================================================================
        #  FINAL REVIEW I3 - THE SUMMARY SENTENCE AND THE CARDS AGREE.
        #  "Done" is state === 'submitted' in both places. The sentence used
        #  to test "every child has a mark" and read "Every class has a
        #  register for this evening" over 44 cards each saying it was NOT
        #  handed in. And a class with nobody on its roll is not due.
        # =====================================================================
        def cls(i, roll, marked, state):
            return {"id": "fx%d" % i, "name": "Test Class Fx%d" % i,
                    "section": "boys", "sort_order": i, "teacher": "Apa Fxname",
                    "on_roll": roll, "marked": marked, "away": 0, "state": state}

        pf = open_screen(browser, ["madrasah"], classes=[
            cls(1, 2, 2, None), cls(2, 2, 2, "draft"), cls(3, 2, 2, None),
            cls(4, 0, 0, None)])
        evf = pf.inner_text("#rg-classes")
        check("EVERY CLASS FULLY MARKED, NONE HANDED IN: the sentence does not "
              "say every class has a register",
              "every class has a register" not in evf.lower()
              and "every register is handed in" not in evf.lower(), evf[:240])
        check("it counts the three classes that still need handing in, and "
              "not the class with nobody on its roll",
              "3 classes still need a register" in evf, evf[:240])
        check("the class with nobody on its roll says so, rather than asking "
              "for a register the database would refuse",
              "nobody on the roll" in pf.inner_text('.rg-class[data-class="fx4"]').lower(),
              pf.inner_text('.rg-class[data-class="fx4"]'))
        pf.close()

        pf = open_screen(browser, ["madrasah"], classes=[
            cls(1, 2, 2, "submitted"), cls(2, 3, 3, "submitted"), cls(4, 0, 0, None)])
        evf = pf.inner_text("#rg-classes")
        check("every DUE class handed in reads as every register handed in, "
              "and an empty class does not spoil it",
              "every register is handed in for this evening" in evf.lower(), evf[:240])
        pf.close()

        pf = open_screen(browser, ["madrasah"], classes=[cls(4, 0, 0, None)])
        evf = pf.inner_text("#rg-classes")
        check("with nobody on any roll no register is due, and it says that "
              "rather than claiming all are done or asking for one",
              "no register is due" in evf.lower()
              and "every register" not in evf.lower()
              and "still need" not in evf.lower(), evf[:240])
        pf.close()

        # =====================================================================
        #  FINAL REVIEW C1 - THE MISSED-REGISTERS WINDOW STARTS WHEN THE
        #  REGISTER OPENED, AND SAYS SO IN WORDS WHEN THAT LEAVES NOTHING.
        # =====================================================================
        SWALLOWED = {"allowed": True, "count": 0, "rows": [], "swallowed": True,
                     "opened_on": str(datetime.date.today()),
                     "note": "The register opened on 3 October; there is "
                             "nothing before it to report."}
        pgs = open_screen(browser, ["madrasah"], missing=SWALLOWED)
        check("a window the floor swallowed is SAID, not drawn as nothing "
              "(a hidden panel reads as 'every register was taken')",
              pgs.locator("#rg-missing").is_visible())
        sw = pgs.inner_text("#rg-missing")
        check("in the database's own words",
              "The register opened on 3 October; there is nothing before it "
              "to report." in sw, sw[:240])
        check("and lists no class, date or teacher",
              pgs.locator("#rg-missing li").count() == 0)
        pgs.close()

        TRIMMED = dict(REGISTERS_MISSING, swallowed=False,
                       note="Counted from 24 September, when the register opened.")
        pgt2 = open_screen(browser, ["madrasah"], missing=TRIMMED)
        tr = pgt2.inner_text("#rg-missing")
        check("a trimmed window says where the count starts, beside the list",
              "Counted from 24 September, when the register opened." in tr
              and "Test Class Five" in tr, tr[:300])
        pgt2.close()

        # =====================================================================
        #  TASK 11, RULING G — A TEACHER SEES NEITHER PANEL, AND THE
        #  DATABASE REFUSES BOTH. The screen and the database are checked
        #  together, which is worth more than either proved alone.
        # =====================================================================
        pgn = open_screen(browser, ["teacher"], classes=[CLASSES[0]],
                          missing=REGISTERS_MISSING, history=HISTORY)
        check("a teacher's screen carries no missed-registers panel",
              pgn.locator("#rg-missing").count() == 0
              or pgn.locator("#rg-missing").is_hidden())
        check("and never asks the database for it",
              len(calls(pgn, "registers_missing")) == 0)
        pgn.click('.rg-class[data-class="c1"]')
        pgn.wait_for_timeout(350)
        check("and opening a class gives a teacher no history control at "
              "all — not even a collapsed one",
              pgn.locator("#rg-history-toggle").count() == 0)
        check("so register_history is never asked either",
              len(calls(pgn, "register_history")) == 0)
        #  THE DATABASE HALF. Calling the same two RPCs directly, the way a
        #  browser console or a modified page could, proves the refusal is
        #  not merely the screen choosing not to ask — the stub mirrors the
        #  live verified_madrasah() gate, the same two-halves-agree shape
        #  the live database proof (this task's report) used.
        direct = pgn.evaluate(
            "() => { var c = window.supabase.createClient(); "
            "return Promise.all(["
            "c.rpc('registers_missing', {p_from:'2020-01-01', p_to:'2020-01-02'})"
            ".then(function(r){return r.data;}),"
            "c.rpc('register_history', {p_class:'c1', p_date:'2020-01-01'})"
            ".then(function(r){return r.data;})]); }")
        check("registers_missing refuses a teacher directly, too",
              direct[0].get("allowed") is False, direct[0])
        check("and so does register_history",
              direct[1].get("allowed") is False, direct[1])
        pgn.close()

        # ============ A PHONE ============
        pgp = open_screen(browser, ["madrasah"], width=390, height=900)
        wide = pgp.evaluate("() => document.documentElement.scrollWidth "
                            "> document.documentElement.clientWidth + 1")
        check("the screen does not scroll sideways on a phone", not wide)
        pgp.click('.rg-class[data-class="c1"]')
        pgp.wait_for_timeout(350)
        #  A REGISTER IS TAKEN STANDING UP, HOLDING A TABLET, IN A ROOM FULL OF
        #  CHILDREN. A mark that shrinks to fit beside a name is a mark a
        #  teacher hits for the wrong child.
        box = pgp.evaluate("""() => { var b=document.querySelector('.rg-mark')
            .getBoundingClientRect(); return {w:b.width,h:b.height}; }""")
        check("the marks stay big enough to hit on a phone",
              box and box["h"] >= 44, box)
        check("and wide enough", box and box["w"] >= 60, box)
        rows = pgp.evaluate("""() => { var r=document.querySelector('.rg-row');
            return r ? r.getBoundingClientRect().bottom : null; }""")
        check("and a whole child fits on the screen", rows and rows < 900, rows)
        pgp.close()

        browser.close()
    FINISHED[0] = True


if __name__ == "__main__":
    atexit.register(report)
    run()
