"""The Register screen, driven in a browser against a stubbed database.

WHAT THIS SUITE IS FOR

The migrations prove what lives in Postgres: that mark_register() refuses
until every family has been told the register is being kept, that a child not
in the class is ignored, that a register cannot be taken for a day that has
not happened or one more than a fortnight ago, and that a teacher's blanket
mark never buries a parent's message. Those were proved against real classes
in rolled-back transactions.

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
    {"id": "c2", "name": "Test Class Two", "section": "girls", "sort_order": 2,
     "teacher": "Apa Othername", "on_roll": 3, "marked": 3, "away": 1},
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


def stub(roles, permitted=True, families=330, told=330, rows=None, classes=None):
    return """
(function(){
  var ROLES=%s, CLASSES=%s, ROWS=%s;
  var GATE=%s, CHILD=%s, ADDRESS=%s, DOB=%s, MEDICAL=%s;
  window.__calls=[]; window.__printed=0;
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
      if (name==='madrasah_registers_list')
        return Promise.resolve({data:{allowed:true,on_date:args.p_date,
          permitted:GATE,rows:CLASSES},error:null});
      if (name==='madrasah_register_list') {
        var c=null;
        for(var i=0;i<CLASSES.length;i++){ if(CLASSES[i].id===args.p_class) c=CLASSES[i]; }
        return Promise.resolve({data:{allowed:true,on_date:args.p_date,
          permitted:GATE,
          'class': c && {id:c.id,name:c.name,section:c.section,teacher:c.teacher},
          rows:ROWS},error:null});
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
      if (name==='mark_register') {
        var kept=0, marked=0;
        for(var j=0;j<(args.p_marks||[]).length;j++){
          var m=args.p_marks[j];
          var was=null;
          for(var k=0;k<ROWS.length;k++){ if(ROWS[k].id===m.pupil_id) was=ROWS[k]; }
          if(was && was.source==='parent' && m.mark!=='present' && m.mark!=='late'){
            kept++; continue; }
          marked++;
        }
        return Promise.resolve({data:{marked:marked,parent_reports_kept:kept},error:null});
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
       json.dumps(SECRET_MEDICAL))


def open_screen(browser, roles, permitted=True, families=330, told=330,
                rows=None, classes=None, width=1280, height=900):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.add_init_script(stub(list(roles), permitted, families, told, rows, classes))
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
        pg.click("#rg-save")
        pg.wait_for_timeout(500)
        sent = calls(pg, "mark_register")
        check("saving sends one call for the whole class", len(sent) == 1, len(sent))
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
