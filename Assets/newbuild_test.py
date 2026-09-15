"""/newbuild/ — the new build page, edited by the masjid.

13 September 2026. The appeal figure used to live in index_template.html, so
moving it meant editing a file, running build.py and pushing. The headline
number on a charity's fundraising page depended on one person being reachable.

TWO THINGS ARE TESTED HERE, and they are different jobs:

  A. THE EDITOR (/newbuild/) — does it read the content back, does it refuse
     the three inputs that would break the public page, and does what it sends
     match what was typed.

  B. THE PUBLIC PAGE (index.html) — does the built copy survive when the
     database cannot be reached, and does the fetched copy replace it when it
     can. That fallback is the whole reason the appeal is still in the built
     HTML at all, and it is the half that would rot silently.

WHAT IS NOT TESTED HERE. Whether the content is valid — check_newbuild() in
Postgres settles that and db/028 proves it, eleven assertions inside a
transaction that rolls itself back. The editor's own checks exist to save a
round trip, not to be the rule.

Run:  python3 _test/newbuild_test.py
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
BASE = "http://127.0.0.1:%d" % httpd.server_address[1]
EDITOR = BASE + "/newbuild/"
SITE   = BASE + "/index.html"

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


#  £350,000 of £2,500,000 — 14%. The figures the page was built with, so a
#  fetched copy that happens to match the fallback would prove nothing. The
#  "after" body below is deliberately DIFFERENT in every field that matters.
BEFORE = {
    "appeal": {
        "tag": "Current appeal · Phase 3.3",
        "heading": "Internal fixtures & fittings",
        "body": "Tiling, carpets, heating, electrical works, lighting and décor.",
        "raised_p": 35000000, "target_p": 250000000,
        "needs": ["Tiling", "Carpets", "Heating"],
    },
    "timeline": [
        {"date": "2018", "title": "Phase 1", "status": "done",
         "label": "Completed", "body": "Ground works and superstructure."},
        {"date": "Now · Phase 3.3", "title": "Internal fixtures & fittings",
         "status": "active", "label": "Current appeal", "body": "To a full finish."},
        {"date": "What's next", "title": "Facilities & grounds", "status": "upcoming",
         "label": "Not yet costed", "body": "Car parking and landscaping."},
    ],
}

#  A different appeal entirely: 50% of a different target, different words,
#  one fewer phase.
AFTER = json.loads(json.dumps(BEFORE))
AFTER["appeal"]["tag"] = "Current appeal · Phase 3.4"
AFTER["appeal"]["heading"] = "Wuḍūʾ khāna and facilities"
AFTER["appeal"]["raised_p"] = 60000000      # £600,000
AFTER["appeal"]["target_p"] = 120000000     # £1,200,000  -> 50%
AFTER["appeal"]["needs"] = ["Plumbing", "Tiling", "Drainage"]
AFTER["timeline"] = AFTER["timeline"][:2]
AFTER["timeline"][1]["title"] = "Wuḍūʾ khāna"


def stub(body, roles=("admin",), fail=False):
    return """
(function(){
  var BODY = %s, ROLES = %s, FAIL = %s;
  window.__SET = null;
  var client = {
    auth: {
      getSession: function(){ return Promise.resolve({data:{session:{
        access_token:'t', user:{id:'u1', email:'yameen@example.test'}}}}); },
      getUser: function(){ return Promise.resolve({data:{user:{
        id:'u1', email:'yameen@example.test'}}}); },
      signOut: function(){ return Promise.resolve({}); },
      updateUser: function(){ return Promise.resolve({data:{},error:null}); },
      mfa: { getAuthenticatorAssuranceLevel: function(){
               return Promise.resolve({data:{currentLevel:'aal2', nextLevel:'aal2'}}); },
             listFactors: function(){ return Promise.resolve({data:{totp:[{id:'f1'}]}}); } }
    },
    from: function(t){
      var rows = t === 'profiles' ? {full_name:'Yameen Bux', email:'yameen@example.test'}
               : t === 'site_content'
                   ? {body:BODY, updated_at:'2026-09-13T09:00:00Z', updated_by:'u1'}
               : ROLES.map(function(r){ return {role:r}; });
      var q = { select:function(){return q;}, eq:function(){return q;},
        maybeSingle:function(){ return Promise.resolve({data:rows, error:null}); },
        then:function(res){ return Promise.resolve({data:rows, error:null}).then(res); } };
      return q;
    },
    rpc: function(n, a){
      if (n === 'set_site_content') {
        window.__SET = a;
        if (FAIL) return Promise.resolve({data:null, error:{message:'the database said no'}});
      }
      return Promise.resolve({data:{}, error:null});
    }
  };
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}}, writable:false, configurable:false});
})();
""" % (json.dumps(body), json.dumps(list(roles)), "true" if fail else "false")


def open_editor(b, body, roles=("admin",), fail=False):
    pg = b.new_page(viewport={"width": 1400, "height": 1200})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.on("dialog", lambda d: d.accept())
    pg.add_init_script(stub(body, roles, fail))
    pg.goto(EDITOR, wait_until="load")
    pg.wait_for_timeout(1200)
    return pg, errs


def text(pg, sel):
    n = pg.query_selector(sel)
    return re.sub(r"\s+", " ", n.inner_text()) if n else ""


def lower(pg, sel):
    """innerText returns the CSS-text-transformed text.

    `.ph-pct` and `.nb-pv-top span:last-child` are uppercase in the stylesheet,
    so "14% funded" comes back as "14% FUNDED" and an assertion looking for the
    lower-case form fails on a page that is perfectly correct. This project has
    now been caught by that three times — "December 2021", "without 2FA", and
    every percentage in this file. Anything that might be transformed goes
    through here.
    """
    return text(pg, sel).lower()


def fill(pg, sel, value):
    if not pg.is_visible(sel):
        fails.append("%s is not on screen to type into" % sel)
        return False
    pg.fill(sel, value)
    return True


def click(pg, sel):
    if not pg.is_visible(sel):
        fails.append("%s is not on screen to press" % sel)
        return False
    pg.click(sel)
    return True


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  A1. IT SHOWS WHAT IS ON THE WEBSITE
    # =====================================================================
    pg, errs = open_editor(b, BEFORE)
    check(pg.is_visible("#nb-panel"), "the editor did not open for an administrator")
    check(pg.input_value("#nbf-heading") == BEFORE["appeal"]["heading"],
          "the heading was not read back: %r" % pg.input_value("#nbf-heading"))
    #  POUNDS in the box, pence in the database. Showing 35000000 to somebody
    #  who has to type over it is how a £350,000 appeal becomes £35,000,000.
    check(pg.input_value("#nbf-raised") == "350,000",
          "the amount raised is not shown in pounds: %r" % pg.input_value("#nbf-raised"))
    check(pg.input_value("#nbf-target") == "2,500,000",
          "the target is not shown in pounds: %r" % pg.input_value("#nbf-target"))
    check(pg.input_value("#nbf-needs") == "Tiling, Carpets, Heating",
          "what the money pays for was not read back: %r" % pg.input_value("#nbf-needs"))
    n = len(pg.query_selector_all("#nb-items .nb-item"))
    check(n == 3, "expected three phases, drew %d" % n)
    check("13 Sep 2026" in text(pg, "#nb-meta"),
          "the page does not say when it was last changed: %r" % text(pg, "#nb-meta"))

    # =====================================================================
    #  A2. THE PERCENTAGE IS WORKED OUT, NOT TYPED
    # =====================================================================
    check("14% funded" in lower(pg, "#nb-preview"),
          "the preview does not work out the percentage: %r" % text(pg, "#nb-preview"))
    check(pg.query_selector("#nb-panel input[id*=pct], #nb-panel input[id*=percent]") is None,
          "THERE IS A BOX FOR TYPING THE PERCENTAGE. It must be derived, or the "
          "words, the bar and the caption drift apart — which is exactly what "
          "the comment in the old template was written to prevent")

    fill(pg, "#nbf-raised", "1,250,000")
    pg.wait_for_timeout(200)
    check("50% funded" in lower(pg, "#nb-preview"),
          "the preview did not follow the figure: %r" % text(pg, "#nb-preview"))
    check("1,250,000 still to raise" in lower(pg, "#nb-preview"),
          "the preview does not say what is left: %r" % text(pg, "#nb-preview"))

    #  Oversubscribed is good news, not an error. The bar caps; nothing refuses.
    fill(pg, "#nbf-raised", "3,000,000")
    pg.wait_for_timeout(200)
    check("120% funded" in lower(pg, "#nb-preview"),
          "an oversubscribed appeal is not shown honestly: %r" % text(pg, "#nb-preview"))
    w = pg.eval_on_selector("#nb-pv-fill", "e => e.style.width")
    check(w == "100%", "the bar overflows its track at 120%%: %r" % w)
    check("fully funded" in text(pg, "#nb-preview").lower(),
          "an appeal that is met does not say so: %r" % text(pg, "#nb-preview"))

    # =====================================================================
    #  A3. THE THREE INPUTS THAT WOULD BREAK THE PUBLIC PAGE
    # =====================================================================
    fill(pg, "#nbf-raised", "350,000")
    fill(pg, "#nbf-target", "0")
    pg.wait_for_timeout(200)
    check("no target" in text(pg, "#nb-preview").lower(),
          "a target of zero draws a bar rather than saying it cannot: %r"
          % text(pg, "#nb-preview"))
    click(pg, "#nb-save")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__SET") is None,
          "A TARGET OF ZERO WAS SENT. The public page divides by it")

    fill(pg, "#nbf-target", "2,500,000")
    fill(pg, "#nbf-heading", "")
    click(pg, "#nb-save")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__SET") is None, "an appeal with no heading was sent")
    fill(pg, "#nbf-heading", BEFORE["appeal"]["heading"])

    #  Two current appeals, then none. The page can only ask for one thing.
    pg.select_option('#nb-items .nb-item[data-i="0"] select[data-f="status"]', "active")
    pg.wait_for_timeout(200)
    click(pg, "#nb-save")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__SET") is None,
          "TWO phases were both saved as the current appeal")
    check("one thing at a time" in text(pg, "#nb-error").lower(),
          "no useful message when two phases are both current: %r" % text(pg, "#nb-error"))

    pg.select_option('#nb-items .nb-item[data-i="0"] select[data-f="status"]', "done")
    pg.select_option('#nb-items .nb-item[data-i="1"] select[data-f="status"]', "done")
    pg.wait_for_timeout(200)
    click(pg, "#nb-save")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__SET") is None,
          "a timeline with NO current appeal was saved — the page would stop asking")
    pg.select_option('#nb-items .nb-item[data-i="1"] select[data-f="status"]', "active")
    pg.wait_for_timeout(200)

    # =====================================================================
    #  A4. WHAT IS SENT IS WHAT WAS TYPED
    # =====================================================================
    fill(pg, "#nbf-heading", "Wuḍūʾ khāna and facilities")
    fill(pg, "#nbf-raised", "£600,000")     # a £ sign and commas must be fine
    fill(pg, "#nbf-target", "1,200,000")
    fill(pg, "#nbf-needs", "Plumbing , Tiling,Drainage ,")
    pg.fill('#nb-items .nb-item[data-i="1"] input[data-f="title"]', "Wuḍūʾ khāna")
    click(pg, "#nb-save")
    pg.wait_for_timeout(600)

    sent = pg.evaluate("window.__SET")
    check(sent is not None, "nothing was sent to the database")
    if sent:
        check(sent.get("p_key") == "newbuild", "the wrong section was written: %r" % sent)
        a = (sent.get("p_body") or {}).get("appeal") or {}
        check(a.get("raised_p") == 60000000,
              "POUNDS WERE NOT CONVERTED TO PENCE. £600,000 was sent as %r" % a.get("raised_p"))
        check(a.get("target_p") == 120000000,
              "the target was not converted to pence: %r" % a.get("target_p"))
        check(a.get("heading") == "Wuḍūʾ khāna and facilities",
              "the heading was not sent: %r" % a.get("heading"))
        #  Trailing commas and stray spaces are what a person actually types.
        check(a.get("needs") == ["Plumbing", "Tiling", "Drainage"],
              "the tags were not tidied: %r" % a.get("needs"))
        tl = (sent.get("p_body") or {}).get("timeline") or []
        check(len(tl) == 3, "the timeline lost or gained entries: %d" % len(tl))
        check(tl[1].get("title") == "Wuḍūʾ khāna",
              "a change typed into a phase was not sent: %r" % tl[1])
    check("saved" in text(pg, "#nb-ok").lower(),
          "it does not confirm the save: %r" % text(pg, "#nb-ok"))
    check(errs == [], "uncaught exceptions: %s" % errs)
    pg.close()

    # =====================================================================
    #  A5. ADDING, MOVING AND REMOVING A PHASE
    # =====================================================================
    pg, errs = open_editor(b, BEFORE)
    click(pg, "#nb-add")
    pg.wait_for_timeout(300)
    check(len(pg.query_selector_all("#nb-items .nb-item")) == 4, "adding a phase did nothing")

    #  Moving must not lose what is in the boxes. The rows are redrawn on every
    #  reorder, so anything typed since the last draw has to be read back first
    #  — which is the trap this assertion exists for.
    pg.fill('#nb-items .nb-item[data-i="0"] input[data-f="title"]', "Renamed first")
    pg.click('#nb-items .nb-item[data-i="0"] button[data-act="down"]')
    pg.wait_for_timeout(300)
    got = pg.input_value('#nb-items .nb-item[data-i="1"] input[data-f="title"]')
    check(got == "Renamed first",
          "MOVING A PHASE THREW AWAY WHAT WAS TYPED INTO IT: %r" % got)

    pg.click('#nb-items .nb-item[data-i="3"] button[data-act="remove"]')
    pg.wait_for_timeout(300)
    check(len(pg.query_selector_all("#nb-items .nb-item")) == 3, "removing a phase did nothing")

    #  The first row cannot go up and the last cannot go down.
    check(pg.eval_on_selector('#nb-items .nb-item[data-i="0"] button[data-act="up"]',
                              "e => e.disabled") is True,
          "the first phase is offered a way to move above itself")
    check(pg.eval_on_selector('#nb-items .nb-item:last-child button[data-act="down"]',
                              "e => e.disabled") is True,
          "the last phase is offered a way to move below itself")

    #  Undo goes back to what the website is showing, not to blank.
    click(pg, "#nb-revert")
    pg.wait_for_timeout(400)
    check(len(pg.query_selector_all("#nb-items .nb-item")) == 3, "undo did not restore the phases")
    check(pg.input_value('#nb-items .nb-item[data-i="0"] input[data-f="title"]') == "Phase 1",
          "undo did not put the original wording back")
    check(errs == [], "uncaught exceptions while editing the timeline: %s" % errs)
    pg.close()

    # =====================================================================
    #  A6. A REFUSAL FROM THE DATABASE IS SHOWN, NOT SWALLOWED
    # =====================================================================
    pg, errs = open_editor(b, BEFORE, fail=True)
    click(pg, "#nb-save")
    pg.wait_for_timeout(600)
    check("the database said no" in text(pg, "#nb-error").lower(),
          "the database refused and the screen did not say so: %r" % text(pg, "#nb-error"))
    check("saved" not in text(pg, "#nb-ok").lower(),
          "IT SAID SAVED WHEN THE DATABASE REFUSED")
    pg.close()

    # =====================================================================
    #  A7. AN OFFICE ACCOUNT CANNOT CHANGE THE WEBSITE
    # =====================================================================
    pg, errs = open_editor(b, BEFORE, roles=("hall_office",))
    check(not pg.is_visible("#nb-panel"),
          "AN OFFICE ACCOUNT WAS SHOWN THE EDITOR FOR THE PUBLIC WEBSITE")
    check(pg.is_visible("#app-noaccess"), "it does not say why there is nothing here")
    check(errs == [], "uncaught exceptions for an office account: %s" % errs)
    pg.close()

    # =====================================================================
    #  B1. THE PUBLIC PAGE WITHOUT THE DATABASE
    #
    #  The built HTML still carries the appeal. This is the half that would
    #  rot silently: it only matters on the day Supabase is unreachable, and
    #  nobody checks it on the other days.
    # =====================================================================
    pg = b.new_page(viewport={"width": 1280, "height": 1000})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    #  Every call to site_content fails, exactly as it would with the project
    #  paused or the network down.
    pg.route("**/rest/v1/site_content*", lambda route: route.abort())
    pg.goto(SITE + "#newbuild", wait_until="load")
    pg.wait_for_timeout(1500)
    pg.eval_on_selector("[data-nav='newbuild'], a[href='#newbuild']", "e => e.click()")
    pg.wait_for_timeout(600)

    built = text(pg, "#nb-appeal")
    check("£350,000" in built,
          "THE APPEAL IS BLANK WHEN THE DATABASE IS UNREACHABLE. The built copy "
          "exists precisely for this: %r" % built[:300])
    check("14% funded" in built.lower(), "the built percentage is missing: %r" % built[:300])
    check(len(pg.query_selector_all("#nb-timeline .nb-tl-item")) >= 5,
          "the built timeline is missing when the database is unreachable")
    check("last updated" not in text(pg, ".nb-tl-note").lower(),
          "the page claims a last-updated date it could not have read: %r"
          % text(pg, ".nb-tl-note"))
    check(errs == [], "the page threw when the database was unreachable: %s" % errs)
    pg.close()

    # =====================================================================
    #  B2. AND WITH IT
    # =====================================================================
    pg = b.new_page(viewport={"width": 1280, "height": 1000})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.route("**/rest/v1/site_content*", lambda route: route.fulfill(
        status=200, content_type="application/json",
        body=json.dumps([{"body": AFTER, "updated_at": "2026-09-13T09:00:00Z"}])))
    pg.goto(SITE + "#newbuild", wait_until="load")
    pg.wait_for_timeout(1500)
    pg.eval_on_selector("[data-nav='newbuild'], a[href='#newbuild']", "e => e.click()")
    pg.wait_for_timeout(800)

    live = text(pg, "#nb-appeal")
    check("£600,000" in live,
          "the page did not take the figure from the database: %r" % live[:300])
    check("£1,200,000" in live,
          "the page did not take the target from the database: %r" % live[:300])
    check("50% funded" in live.lower(),
          "the percentage was not recomputed from the new figures: %r" % live[:300])
    check("£600,000 still to raise" in live,
          "what is left was not recomputed: %r" % live[:300])
    #  And the built copy is GONE, not sitting underneath.
    check("£350,000" not in live,
          "the old built figure is still on the page next to the new one: %r" % live[:300])
    check("Plumbing" in live, "the tags were not replaced: %r" % live[:300])
    check("Tiling" in live and "Carpets" not in live,
          "the tags were added to rather than replaced: %r" % live[:300])

    #  The note under the timeline used to name a fixed date ("as displayed on
    #  the board, September 2026"), which was true only while the figures could
    #  not be changed without a rebuild. It now says when the office last
    #  touched them, and says nothing at all on the fallback path — there is no
    #  honest date to give there.
    note = text(pg, ".nb-tl-note")
    check("last updated" in note.lower(),
          "the page does not say when the figures were last changed: %r" % note)
    #  Split off the real date before looking for a baked-in one. The first
    #  version of this assertion searched the whole sentence for "September
    #  2026" and then failed on the genuine "Last updated 13 September 2026" —
    #  a test complaining about the very thing it had just asked for.
    prose = note.lower().split("last updated")[0]
    check("september 2026" not in prose,
          "the wording still names a fixed date, which the page can no longer "
          "stand behind: %r" % prose)

    items = pg.eval_on_selector_all("#nb-timeline .nb-tl-item",
                                    "els => els.map(e => e.innerText)")
    check(len(items) == 2,
          "the timeline was not replaced — expected two phases, found %d" % len(items))
    check("Wu" in " ".join(items), "the new phase name is missing: %r" % items)
    check(pg.eval_on_selector("#nb-timeline .nb-tl-item:nth-child(2)",
                              "e => e.className").find("active") != -1,
          "the current appeal is not marked as such after the replacement")

    #  A name typed into the editor is text, not markup. If somebody ever pastes
    #  a tag into a phase title it must appear as characters.
    check(errs == [], "the page threw while taking content from the database: %s" % errs)
    pg.close()

    # =====================================================================
    #  B3. CONTROL — does B1 actually bite?
    #
    #  If the built copy were removed from the template, B1 would have to fail.
    #  Proving it here means the fallback is a real thing and not a sentence in
    #  a comment.
    # =====================================================================
    pg = b.new_page(viewport={"width": 1280, "height": 1000})
    pg.route("**/rest/v1/site_content*", lambda route: route.abort())
    pg.goto(SITE + "#newbuild", wait_until="load")
    pg.wait_for_timeout(1200)
    pg.eval_on_selector("[data-nav='newbuild'], a[href='#newbuild']", "e => e.click()")
    pg.wait_for_timeout(400)
    before_ctl = text(pg, "#nb-appeal")
    pg.evaluate("document.getElementById('nb-raised').textContent = ''")
    after_ctl = text(pg, "#nb-appeal")
    if before_ctl == after_ctl:
        fails.append("CONTROL changed nothing, so B1 proves nothing")
    elif "£350,000" in after_ctl:
        fails.append("CONTROL did not bite — B1 would pass with the figure gone")
    pg.close()

    b.close()

httpd.shutdown()
print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
