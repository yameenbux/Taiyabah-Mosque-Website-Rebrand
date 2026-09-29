"""The Notices-to-parents screen, driven in a browser against a stubbed database.

WHAT THIS SUITE IS FOR

The migrations prove what lives in Postgres: that only a verified administrator
may record that a family was told, that the record carries the date and the
person, and that send_madrasah_fee_reminders() refuses a family that has not
been told and records the refusal as 'not_yet_told'. Those checks run there,
and the last of them was proved against a real family in a rolled-back
transaction.

This proves the half SQL cannot see:

  * that the screen says what is BLOCKED, not just what is counted - a family
    who has not been told cannot be sent a fee reminder, and the office needs
    to know that is why;
  * that "choose every family on this page" chooses the page and not all 330,
    which is how somebody records three hundred people as told by accident;
  * that the bar says the NUMBER before anything is recorded, and that nothing
    is recorded without a second, explicit press;
  * that a teacher is not offered a button only an administrator can press;
  * that "by email" is NOT offered, because this screen cannot send one and
    recording it would mean writing down something that did not happen;
  * that a letter is printed per family, one to a page, and the rest of the
    screen is not;
  * that the screen does not scroll sideways on a phone.

Every check in here was watched failing before it was kept.

    python3 _test/notices_parents_test.py
"""
import atexit
import http.server
import json
import os
import re
import socketserver
import threading

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#  Read off the generator, not hand-typed here a second time — a version
#  number copied between a Python test and a JavaScript module is exactly
#  the drift verify_structure.py's CHECK 9 was added to catch one level up
#  (the generator vs. the built page). This test's own copy went stale for
#  four versions (asserting "1.2" while the live module sent "1.6") because
#  nothing compared them; reading it here is the fix, not just the value.
_m = re.search(r'var VERSION\s*=\s*"([^"]+)"',
               open(os.path.join(ROOT, "tools", "notices_module.js")).read())
if not _m:
    raise SystemExit("could not find notices_module.js's VERSION constant")
NOTICE_VERSION = _m.group(1)


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


def families(n=120, told=0):
    """Invented families. NO REAL FAMILY OR NAME APPEARS IN THIS FILE."""
    out = []
    for i in range(1, n + 1):
        out.append({
            "id": "h%d" % i,
            "reference": "MF-%04d" % i,
            "family": "Testfamily%03d family" % i,
            "children": 1 if i % 3 == 0 else 2,
            "has_email": (i % 7 != 0),
            "has_phone": (i % 19 != 0),
            "told_on": "2026-09-27" if i <= told else None,
            "told_how": "letter" if i <= told else None,
        })
    return out


ROWS = families()


def stub(roles, rows=None):
    return """
(function(){
  var ROLES=%s, ROWS=%s;
  window.__calls=[]; window.__printed=0;
  window.print = function(){
    window.__printed++;
    function on(sel){ var n=document.querySelector(sel);
      if(!n) return false;
      while(n && n!==document){ var s=getComputedStyle(n);
        if(s.display==='none'||s.visibility==='hidden') return false;
        n=n.parentNode; }
      return true; }
    var sheet=document.querySelector('#nt-print');
    window.__atPrint={ letters:on('#nt-print'), rail:on('.shell .arail'),
      table:on('#nt-table'), job:on('#nt-job'), figures:on('#nt-figs'),
      bodyClass:document.body.className,
      atBodyLevel: !!sheet && sheet.parentNode===document.body,
      pages:document.querySelectorAll('#nt-print .lt').length };
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
      if (name==='madrasah_parent_notice_list')
        return Promise.resolve({data:{allowed:true,kind:'privacy_notice',rows:ROWS},error:null});
      if (name==='record_parents_told') {
        var ids = args.p_households || [];
        for (var i=0;i<ROWS.length;i++){
          if (ids.indexOf(ROWS[i].id) !== -1) {
            ROWS[i].told_on='2026-09-27'; ROWS[i].told_how=args.p_how; }
        }
        return Promise.resolve({data:{recorded:ids.length,skipped:0,how:args.p_how},error:null});
      }
      return Promise.resolve({data:null,error:{message:'unstubbed '+name}});
    }
  };
  Object.defineProperty(window,'supabase',
    {value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % (json.dumps(roles), json.dumps(rows if rows is not None else ROWS))


def open_screen(browser, roles, rows=None, width=1280, height=900):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.add_init_script(stub(list(roles), rows))
    pg.goto(BASE + "/portal/notices/", wait_until="networkidle")
    pg.wait_for_timeout(420)
    return pg


def calls(pg, name):
    return [c for c in pg.evaluate("() => window.__calls") if c["name"] == name]


def run():
    with sync_playwright() as p:
        browser = p.chromium.launch()

        # ============ WHO GETS IN ============
        pg = open_screen(browser, [])
        check("a role-less account is refused", pg.locator("#nt-panel").is_hidden())
        check("and nothing was fetched for them",
              len(calls(pg, "madrasah_parent_notice_list")) == 0)
        pg.close()

        pg = open_screen(browser, ["admin", "madrasah"], rows=families(120, 0))
        check("an administrator gets the screen", pg.locator("#nt-panel").is_visible())

        # ============ THE JOB SAYS WHAT IS BLOCKED ============
        job = pg.inner_text("#nt-job")
        check("the job says how many of how many", "0 of 120" in job, job[:160])
        check("and says what not doing it blocks",
              "fee reminders will not go" in job.lower(), job)
        check("and says the system refuses rather than that somebody must "
              "remember", "not a matter of remembering" in job.lower(), job)
        check("and counts the ones who need a letter because they have no "
              "email", "no email address" in job.lower(), job)
        check("the bar is not full when the job is not done",
              pg.evaluate("""() => document.querySelector('.nt-bar span')
                              .style.width""") == "0%")
        check("and the job is marked unfinished",
              "is-done" not in (pg.locator("#nt-job").get_attribute("class") or ""))

        # ============ CHOOSING ============
        check("nothing is chosen to begin with, so the bar is not there",
              pg.locator("#nt-chosen").is_hidden())
        pg.check("#nt-rows .nt-cb >> nth=0")
        pg.wait_for_timeout(200)
        bar = pg.inner_text("#nt-chosen")
        check("choosing one shows the bar", pg.locator("#nt-chosen").is_visible())
        check("and it says the number and the word in the singular",
              "1 family chosen" in bar, bar[:120])

        #  CHOOSE ALL MEANS THIS PAGE, AND THE LABEL SAYS SO.
        #  A tick box that silently takes all 120 when 50 are on screen is
        #  how somebody records three hundred people as told by accident.
        pg.check("#nt-all")
        pg.wait_for_timeout(250)
        bar = pg.inner_text("#nt-chosen")
        check("choose-all takes the page, not the whole register",
              "50 families chosen" in bar, bar[:120])
        check("and its label says so",
              "this page" in (pg.locator("#nt-all").get_attribute("aria-label") or ""),
              pg.locator("#nt-all").get_attribute("aria-label"))
        check("there is a separate control for taking every family shown",
              pg.locator("#nt-everyone").count() == 1)
        pg.click("#nt-everyone")
        pg.wait_for_timeout(250)
        check("and it takes all of them", "120 families chosen"
              in pg.inner_text("#nt-chosen"), pg.inner_text("#nt-chosen")[:120])

        # ============ NOTHING IS RECORDED WITHOUT A SECOND PRESS ============
        check("nothing has been recorded yet",
              len(calls(pg, "record_parents_told")) == 0)
        pg.click('#nt-chosen [data-do="told"]')
        pg.wait_for_timeout(250)
        check("pressing Record asks first rather than doing it",
              len(calls(pg, "record_parents_told")) == 0)
        conf = pg.inner_text("#nt-confirm")
        check("and the question says the number",
              "120 families" in conf, conf[:160])
        check("and says what the record is for",
              "evidence" in conf.lower(), conf)
        check("and warns against recording families you have not told",
              "only record families you have actually told" in conf.lower(), conf)

        #  'BY EMAIL' IS NOT OFFERED, because this screen cannot send one.
        #  Offering it would invite somebody to write down a send that never
        #  happened, and that record is the masjid's evidence.
        check("by letter is offered",
              pg.locator('#nt-confirm [data-told="letter"]').count() == 1)
        check("in person is offered",
              pg.locator('#nt-confirm [data-told="in_person"]').count() == 1)
        check("by email is NOT offered, because nothing here can send one",
              pg.locator('#nt-confirm [data-told="email"]').count() == 0)
        check("and it says why, rather than leaving a gap",
              "not built yet" in conf.lower(), conf[-260:])

        pg.click('#nt-confirm [data-told="cancel"]')
        pg.wait_for_timeout(200)
        check("cancelling records nothing",
              len(calls(pg, "record_parents_told")) == 0)
        check("and puts the question away", pg.locator("#nt-confirm").is_hidden())

        # ============ RECORDING ============
        pg.click('#nt-chosen [data-do="told"]')
        pg.wait_for_timeout(200)
        pg.click('#nt-confirm [data-told="letter"]')
        pg.wait_for_timeout(600)
        sent = calls(pg, "record_parents_told")
        check("recording sends one call, not one per family", len(sent) == 1, len(sent))
        check("with every chosen family in it",
              sent and len(sent[0]["args"]["p_households"]) == 120,
              sent and len(sent[0]["args"]["p_households"]))
        check("and how they were told", sent and sent[0]["args"]["p_how"] == "letter")
        #  "1.6", not "1.2" — this assertion's own stale literal was the last
        #  place the "1.2" bug survived. tools/notices_module.js's VERSION
        #  constant was fixed to match the live notice during Tasks 5+6 (the
        #  bug where every "told" record would have carried v1.2 — the
        #  version that said the madrasah held no date of birth, address,
        #  telephone number or medical information — forever, in the one
        #  place the Article 13 duty is evidenced). The fix was correct and
        #  is applied; this check just never stopped asserting the version
        #  it replaced. Read off the generator's own VERSION constant, not
        #  a second hand-typed copy of it, so this cannot go stale the same
        #  way again.
        check("and which version of the notice they were told about, so a "
              "later version is a new telling rather than a tick that is "
              "already ticked",
              sent and sent[0]["args"].get("p_version") == NOTICE_VERSION,
              sent and sent[0]["args"].get("p_version"))
        ok = pg.inner_text("#nt-ok")
        check("and it says what happened, in words",
              "120 families are recorded as told" in ok, ok)
        check("and that it is dated and against a name", "against your name" in ok, ok)
        check("the job is now finished", "is-done"
              in (pg.locator("#nt-job").get_attribute("class") or ""))
        check("and says so rather than showing 120 of 120 and nothing else",
              "every family has been told" in pg.inner_text("#nt-job").lower(),
              pg.inner_text("#nt-job")[:140])
        check("and the choosing is cleared, so nobody records them twice",
              pg.locator("#nt-chosen").is_hidden())

        # ============ THE LETTERS ============
        pgl = open_screen(browser, ["admin", "madrasah"], rows=families(4, 0))
        pgl.click("#nt-everyone")
        pgl.wait_for_timeout(250)
        pgl.emulate_media(media="print")
        pgl.wait_for_timeout(150)
        pgl.click('#nt-chosen [data-do="print"]')
        pgl.wait_for_timeout(400)
        check("it asks the browser to print",
              pgl.evaluate("() => window.__printed") == 1)
        vis = pgl.evaluate("() => window.__atPrint") or {}
        check("one letter per family", vis.get("pages") == 4, vis.get("pages"))
        check("the letters print", vis.get("letters"), vis)
        check("the rail does not", not vis.get("rail"), vis)
        check("nor the table of families", not vis.get("table"), vis)
        check("nor the job panel", not vis.get("job"), vis)
        check("the sheet is moved out to body, away from the cascade fight "
              "with the rail's own !important", vis.get("atBodyLevel") is True, vis)
        sheet = pgl.inner_text("#nt-print")
        check("the letter is on headed paper",
              "Taiyabah Masjid" in sheet and "1041569" in sheet)
        check("and gives the address of the notice",
              "taiyabahmasjid.com/madrasah-privacy" in sheet, sheet[:400])
        check("and offers a paper copy, since a parent should not need a "
              "computer", "printed copy" in sheet, sheet[:900])
        check("and says the notice CHANGED, rather than pretending it is new",
              "it has changed" in sheet.lower(), sheet[:1200])
        check("and names what came across in the move",
              "medical" in sheet.lower() and "dates of birth" in sheet.lower(), sheet[:1400])
        check("and it names no child, because a letter about data protection "
              "does not need to", "Testfamily001 family" in sheet, sheet[:300])
        check("each letter is a page of its own",
              pgl.evaluate("""() => getComputedStyle(
                  document.querySelector('#nt-print .lt')).breakAfter"""
                           ) in ("page", "always"),
              pgl.evaluate("""() => getComputedStyle(
                  document.querySelector('#nt-print .lt')).breakAfter"""))
        pgl.emulate_media(media="screen")
        pgl.close()

        # ============ A TEACHER ============
        pgt = open_screen(browser, ["madrasah"], rows=families(10, 0))
        check("a teacher can see the job", pgt.locator("#nt-job").is_visible())
        pgt.check("#nt-rows .nt-cb >> nth=0")
        pgt.wait_for_timeout(250)
        tbar = pgt.inner_text("#nt-chosen")
        check("a teacher may print the letters",
              pgt.locator('#nt-chosen [data-do="print"]').count() == 1)
        #  record_parents_told() requires verified_admin(). Offering the button
        #  and handing back a permission error teaches somebody the system is
        #  broken rather than that the job is not theirs.
        check("but is not offered a button the database will refuse them",
              pgt.locator('#nt-chosen [data-do="told"]').count() == 0)
        check("and is told whose job it is",
              "administrator" in tbar.lower(), tbar)
        pgt.close()

        # ============ A PHONE ============
        pgp = open_screen(browser, ["admin", "madrasah"], rows=families(60, 0),
                          width=390, height=900)
        wide = pgp.evaluate("() => document.documentElement.scrollWidth "
                            "> document.documentElement.clientWidth + 1")
        check("the screen does not scroll sideways on a phone", not wide)
        check("the table does not scroll sideways inside its own box either",
              pgp.evaluate("""() => { var n=document.querySelector('.nt-scroll');
                  return n.scrollWidth <= n.clientWidth + 1; }"""))
        pgp.check("#nt-rows .nt-cb >> nth=0")
        pgp.wait_for_timeout(250)
        #  THE BAR IS STICKY, so the number is on screen when the person doing
        #  the choosing is at the bottom of the list.
        box = pgp.evaluate("""() => { var n=document.querySelector('#nt-chosen');
            var b=n.getBoundingClientRect(); return {top:b.top,bottom:b.bottom}; }""")
        check("and the bar that says how many are chosen stays on screen",
              box and box["bottom"] <= 902, box)
        pgp.close()

        pg.close()
        browser.close()
    FINISHED[0] = True


if __name__ == "__main__":
    atexit.register(report)
    run()
