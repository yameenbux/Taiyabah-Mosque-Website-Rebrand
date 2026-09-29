"""Messages - the parent's screen and the office's, driven against a stubbed database.

WHAT THIS SUITE IS FOR

db/125 proves what lives in Postgres, in a rolled-back proof inside the
migration and again as the real accounts: that a parent reaches only their own
household's conversations and gets {allowed:false} (not an empty list) for
another's, that a teacher and an anonymous caller are refused the office
screen, that every office read is audited without a word of the message, that
the office, Today and the Monday digest agree on the number waiting, and that
a merge, a purge and a delete each take (or, for a merge, keep) a family's
conversations. It cannot see the screens. This asserts what they SAY:

  PARENT
  * the words "this is not for emergencies", "ring the masjid" and "can sit
    unread over a weekend" are drawn INSIDE the compose section, above the box
    a parent types in, and again above the reply box - not in a footer;
  * a new reply is shown as "new reply", and opening it marks it read as a
    SEPARATE call after the read (reading is a pure read in the database);
  * "You", "Your household" and "The office" - never a staff name, never an id;
  * the database's own refusals (22023) are shown as written, and a technical
    error never is;
  * a login that is not a parent's is told so, and is not offered a box;
  * a closed conversation offers no reply box and says why.

  OFFICE
  * a role-less account is refused and nothing is fetched;
  * the LIST shows the family's reference, the parent's title, the age and the
    number of messages, and NOT a family name or a word of a message (a
    fixture that smuggles those keys in proves the screen shows only what it
    names);
  * opening one shows the family and the words, and is the only call that
    does; an empty reply is refused on the screen and never sent;
  * "closed" says replying reopens it; "waiting" says how long.

  BOTH
  * the generated files are what the generator makes now; ES5; [hidden] first;
    no horizontal scroll at 390px; every fixture has exactly the key set the
    live functions return (read off db/125's proof, which asserts them).

WHAT IT CANNOT PROVE. The stub answers as db/125's functions do and refuses in
their words. It is not the database. HTTP sign-in against the real auth
service has not been run from here.

    python3 _test/messages_test.py
    MSG_SERVE_ROOT=<a copy of the repo with one line changed> python3 _test/messages_test.py
        (tools/../_test/messages_mutants.py does that, to prove this can fail)
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
SERVE = os.environ.get("MSG_SERVE_ROOT") or ROOT
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

# Key sets the live functions return (asserted by db/125's proof).
LIVE = {
    "parent_thread": "created_at,id,last_message_at,state,subject,unread",
    "parent_message": "body,created_at,from_parent,who",
    "office_thread": "created_at,days,id,last_message_at,messages,reference,state,subject,unread",
    "office_open": "created_at,family,id,last_message_at,reference,state,subject,unread",
}


def keys(d):
    return ",".join(sorted(d))


# NO REAL FAMILY, CHILD OR PERSON APPEARS IN THIS FILE.
FAMILY = "Zzzfamily Testwood household"
BODY_1 = "Aaliyah will miss Thursday, she has a hospital appointment."
BODY_HTML = "<b>bold</b> & <script>window.__pwned=1</script>"
SECRET_BODY = "ZZ-SECRET-WORDS-OF-A-MESSAGE"


def pthread(i, subject, state="answered", unread=False):
    return {"id": "t%d" % i, "subject": subject, "state": state,
            "created_at": "2026-09-25T10:00:00+00:00",
            "last_message_at": "2026-09-27T14:30:00+00:00", "unread": unread}


def pmsg(who, body, at="2026-09-25T10:00:00+00:00"):
    return {"who": who, "body": body, "from_parent": who != "office",
            "created_at": at}


def othread(i, subject, ref, state="open", days=3, n=1, unread=True, **extra):
    d = {"id": "o%d" % i, "subject": subject, "state": state, "reference": ref,
         "created_at": "2026-09-25T10:00:00+00:00",
         "last_message_at": "2026-09-26T10:00:00+00:00",
         "unread": unread, "messages": n, "days": days}
    d.update(extra)
    return d


PARENT_THREADS = [
    pthread(1, "Thursday's absence", "answered", True),
    pthread(2, "Change of address", "open", False),
    pthread(3, "An old question", "closed", False),
]
PARENT_OPENED = {
    "t1": {"allowed": True, "thread": pthread(1, "Thursday's absence", "answered", True),
           "messages": [pmsg("you", BODY_1),
                        pmsg("household", "Adding: back on Friday.", "2026-09-25T11:00:00+00:00"),
                        pmsg("office", "Thank you, we have noted it.", "2026-09-26T09:15:00+00:00")]},
    "t3": {"allowed": True, "thread": pthread(3, "An old question", "closed", False),
           "messages": [pmsg("you", "Is there a class on the bank holiday?"),
                        pmsg("office", "No, the madrasah is closed that day.")]},
}


def stub(fixture):
    return """
(function(){
  var F=%s;
  window.__calls=[]; window.__auth=[]; window.__tables=[];
  var signedIn=true;
  var USER={id:'u1',email:'x@example.test'};
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
      if (R && R.__byId) return Promise.resolve({data:R.__byId[args.p_thread]||{allowed:false},error:null});
      if (R && R.__byWhich) return Promise.resolve({data:R.__byWhich[args.p_which]||R.__byWhich.waiting,error:null});
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
    return pg.inner_text(sel)


def no_sideways_scroll(pg):
    return pg.evaluate("() => document.documentElement.scrollWidth <= "
                       "document.documentElement.clientWidth + 1")


def parent_fx(**over):
    base = {"roles": [], "aal": "aal1",
            "answers": {"parent_threads": {"allowed": True, "unread": 1, "threads": PARENT_THREADS},
                        "parent_thread_read": {"__byId": PARENT_OPENED},
                        "parent_thread_mark_read": {"allowed": True},
                        "parent_thread_start": {"allowed": True, "id": "t9"},
                        "parent_thread_reply": {"allowed": True, "state": "open"}},
            "errors": {}}
    base.update(over)
    return base


def waiting_list():
    return {"allowed": True, "which": "waiting",
            "counts": {"waiting": 2, "answered": 1, "closed": 4},
            "threads": [othread(1, "Absence on Thursday", "MF-000123", days=3, n=2),
                        othread(2, "Question about fees", "MF-000456", days=0, n=1, unread=False)]}


OFFICE_OPENED = {
    "o1": {"allowed": True,
           "thread": {"id": "o1", "subject": "Absence on Thursday", "state": "open",
                      "created_at": "2026-09-25T10:00:00+00:00",
                      "last_message_at": "2026-09-26T10:00:00+00:00", "unread": False,
                      "reference": "MF-000123", "family": FAMILY},
           "messages": [pmsg("Proofparent Alpha", BODY_1),
                        pmsg("Proofparent Alpha", BODY_HTML, "2026-09-26T10:00:00+00:00")]},
    "o9": {"allowed": True,
           "thread": {"id": "o9", "subject": "An old question", "state": "closed",
                      "created_at": "2026-09-20T10:00:00+00:00",
                      "last_message_at": "2026-09-21T10:00:00+00:00", "unread": False,
                      "reference": "MF-000777", "family": FAMILY},
           "messages": [pmsg("Proofparent Alpha", "Question."),
                        pmsg("The office", "Answer.", "2026-09-21T10:00:00+00:00")]},
}


def office_fx(**over):
    base = {"roles": ["admin", "madrasah"], "aal": "aal2",
            "answers": {"office_threads": {"__byWhich": {
                            "waiting": waiting_list(),
                            "all": dict(waiting_list(), which="all", threads=waiting_list()["threads"]
                                        + [othread(9, "An old question", "MF-000777", state="closed", days=8, n=2, unread=False)])}},
                        "office_thread_read": {"__byId": OFFICE_OPENED},
                        "office_thread_reply": {"allowed": True, "state": "answered"},
                        "office_thread_close": {"allowed": True, "state": "closed"}},
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
    check("fixture: a parent's thread has exactly the live keys",
          keys(PARENT_THREADS[0]) == LIVE["parent_thread"], keys(PARENT_THREADS[0]))
    check("fixture: a parent's message has exactly the live keys",
          keys(pmsg("you", "x")) == LIVE["parent_message"])
    check("fixture: an office list row has exactly the live keys",
          keys(othread(1, "s", "MF-1")) == LIVE["office_thread"], keys(othread(1, "s", "MF-1")))
    check("fixture: an opened office thread has exactly the live keys",
          keys(OFFICE_OPENED["o1"]["thread"]) == LIVE["office_open"])

    # ============ THE GENERATED FILES ARE WHAT THE GENERATOR MAKES ============
    import screen_builder as SB
    import build_messages_screen as BM
    import build_parent_screens as BP
    scr = BM.SCREEN
    check("portal/messages/index.html is what the generator makes now",
          SB.build_html(scr) == open(os.path.join(ROOT, "portal/messages/index.html"), encoding="utf-8").read())
    check("portal/messages/app.js is what the generator makes now",
          SB.build_js(scr) == open(os.path.join(ROOT, "portal/messages/app.js"), encoding="utf-8").read())
    pm = [s for s in BP.SCREENS if s.folder == "parent/messages"]
    check("the parent screens include Messages", len(pm) == 1)
    if pm:
        check("portal/parent/messages/app.js is what the generator makes now",
              SB.build_js(pm[0]) == open(os.path.join(ROOT, "portal/parent/messages/app.js"), encoding="utf-8").read())
        check("portal/parent/messages/index.html is what the generator makes now",
              SB.build_html(pm[0]) == open(os.path.join(ROOT, "portal/parent/messages/index.html"), encoding="utf-8").read())
    r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "screen_builder.py"), "--verify-pupils"],
                       capture_output=True, text=True)
    check("the shared generator still reproduces the Pupils screen byte-for-byte",
          r.returncode == 0, r.stdout[-160:])

    # ============ ES5, [hidden], THE NAV ============
    for f in ("portal/messages/app.js", "portal/parent/messages/app.js",
              "tools/messages_module.js", "tools/parent_messages_module.js"):
        ok, why = es5_ok(os.path.join(ROOT, f))
        check("%s parses as ES5" % f, ok, why)
    for f in ("portal/messages/messages.css", "portal/parent/parent.css"):
        css = re.sub(r"/\*.*?\*/", "", open(os.path.join(ROOT, f), encoding="utf-8").read(), flags=re.S).strip()
        check("%s opens with [hidden] { display: none !important; }" % f,
              css.splitlines()[0].replace(" ", "") == "[hidden]{display:none!important;}", css.splitlines()[0])
    nav = open(os.path.join(ROOT, "portal/nav.js"), encoding="utf-8").read()
    row = re.search(r'key:\s*"md-messages"[^}]*}', nav, re.S)
    check("the office rail's Messages row is not marked soon",
          bool(row) and "soon" not in row.group(0), row.group(0) if row else None)

    with sync_playwright() as p:
        browser = p.chromium.launch()

        # ================================================================
        #  THE PARENT'S SCREEN
        # ================================================================
        pg = open_page(browser, "/portal/parent/messages/", parent_fx())
        check("the heading says Messages", "Messages" in text(pg, "h1"), text(pg, "h1"))
        names = pg.evaluate("""() => Array.prototype.map.call(document.querySelectorAll('.ashell .area'),
            function (n) { return n.textContent.replace(/\\s+/g, ' ').trim(); })""")
        here = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('.ashell a.area[aria-current="page"]'),
            function (n) { return n.textContent.replace(/\\s+/g, ' ').trim(); })""")
        check("the rail says Messages is where you are", len(here) == 1 and here[0].startswith("Messages"), here)
        check("a parent's rail still names no staff screen",
              not re.search(r"pupils|families|fees|register|admissions", " ".join(names).lower()), names)
        check("no second factor was asked of a parent", "mfa" not in pg.evaluate("() => window.__auth"))

        # ---- THE EMERGENCY WORDS, BESIDE THE BOX ----
        comp = text(pg, "#pm-compose")
        check("the compose section says this is not for emergencies",
              "not for emergencies" in comp.lower(), comp[:300])
        check("it says a missing child means ringing the masjid, with the number",
              "child is missing" in comp and "ring the masjid" in comp and OFFICE in comp, comp[:400])
        check("it says a message can sit unread over a weekend",
              "sit unread over a weekend" in comp, comp[:500])
        order = pg.evaluate("""() => { var c = document.getElementById('pm-compose');
            var n = c.querySelector('.pm-notice'), t = document.getElementById('pm-text');
            if (!n || !t) return 'missing';
            return (n.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING) ? 'above' : 'below'; }""")
        check("the notice is drawn ABOVE the message box, inside the same section (not a footer)",
              order == "above", order)
        check("the notice is not small print: at least 15px",
              pg.evaluate("() => parseFloat(getComputedStyle(document.querySelector('#pm-compose .pm-notice p')).fontSize)") >= 15)
        check("no staff is named and no id shown in the list",
              not re.search(r"\bt[123]\b", text(pg, "#pm-list")), text(pg, "#pm-list"))
        lst = text(pg, "#pm-list")
        check("the list names each conversation by the title the parent gave",
              "Thursday's absence" in lst and "Change of address" in lst and "An old question" in lst, lst)
        check("a conversation with a reply not yet read says 'new reply'",
              "new reply" in lst and lst.count("new reply") == 1, lst)
        check("each says where it stands, in words",
              "The office has replied" in lst and "Sent, waiting for the office" in lst
              and "Closed by the office" in lst, lst)
        check("the page did not ask for anything but the parent's own threads",
              set(all_calls(pg)) == {"parent_threads"}, all_calls(pg))

        # ---- OPEN ONE: reading is separate from being marked read ----
        pg.click('.pm-row[data-id="t1"]')
        pg.wait_for_timeout(300)
        th = text(pg, "#pm-thread")
        check("opening a conversation shows the words in order",
              th.index(BODY_1) < th.index("Adding: back on Friday.") < th.index("Thank you, we have noted it."), th[:300])
        check("who said what: You, Your household, The office",
              "You" in th and "Your household" in th and "The office" in th, th)
        seq = all_calls(pg)
        check("it read the thread, and THEN marked it read (two calls, in that order)",
              seq[-2:] == ["parent_thread_read", "parent_thread_mark_read"] or
              ("parent_thread_read" in seq and "parent_thread_mark_read" in seq
               and seq.index("parent_thread_read") < seq.index("parent_thread_mark_read")), seq)
        check("the read asked for that conversation's id and nothing else",
              calls(pg, "parent_thread_read")[0]["args"] == {"p_thread": "t1"})
        check("while a conversation is open the new-message box is put away (one set of emergency words, above the reply box)",
              pg.locator("#pm-compose").is_hidden() and pg.locator("#pm-title").is_hidden())
        pg.click("#pm-back")
        check("going back to the list brings the new-message box back",
              pg.locator("#pm-compose").is_visible() and pg.locator("#pm-thread").is_hidden())
        pg.click('.pm-row[data-id="t1"]'); pg.wait_for_timeout(300)
        check("the reply box has the same emergency words above it",
              "not for emergencies" in text(pg, "#pm-thread").lower()
              and pg.evaluate("""() => { var n = document.querySelector('#pm-thread .pm-notice'),
                  t = document.getElementById('pm-rtext');
                  return !!n && !!t && !!(n.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING); }"""))

        # reply: blank refused on the screen, never sent
        pg.click("#pm-rgo")
        check("a blank reply is refused on the screen in words",
              "Please write your message." in text(pg, "#pm-rinline"), text(pg, "#pm-rinline"))
        check("and nothing was sent", len(calls(pg, "parent_thread_reply")) == 0)
        pg.fill("#pm-rtext", "   Thank you.  ")
        pg.click("#pm-rgo")
        pg.wait_for_timeout(400)
        rc = calls(pg, "parent_thread_reply")
        check("a reply is sent for that conversation with the trimmed words",
              len(rc) == 1 and rc[0]["args"] == {"p_thread": "t1", "p_body": "Thank you."}, rc)
        check("the parent is told it has gone",
              "Your reply has been sent." in text(pg, "#pm-done"), text(pg, "#pm-done"))
        pg.close()

        # ---- A CLOSED CONVERSATION ----
        pg = open_page(browser, "/portal/parent/messages/", parent_fx())
        pg.click('.pm-row[data-id="t3"]')
        pg.wait_for_timeout(300)
        th = text(pg, "#pm-thread")
        check("a closed conversation says so, and to write a new message",
              "The office has closed this conversation" in th and "write a new message" in th, th)
        check("and offers no reply box",
              pg.locator("#pm-rtext").count() == 0 and pg.locator("#pm-reply").count() == 0)
        check("and keeps the new-message box, since that is what it tells the parent to use",
              pg.locator("#pm-compose").is_visible() and pg.locator("#pm-title").is_visible())
        check("and did not mark a thread read that was not unread",
              len(calls(pg, "parent_thread_mark_read")) == 0)
        pg.close()

        # ---- A NEW MESSAGE ----
        pg = open_page(browser, "/portal/parent/messages/", parent_fx())
        pg.click("#pm-go")
        check("no title is refused in the database's own words",
              "Please give your message a short title, so the office can see what it is about."
              in text(pg, "#pm-inline"), text(pg, "#pm-inline"))
        pg.fill("#pm-title", "Pickup on Friday")
        pg.click("#pm-go")
        check("no message is refused", "Please write your message." in text(pg, "#pm-inline"))
        check("and neither was sent", len(calls(pg, "parent_thread_start")) == 0)
        pg.fill("#pm-title", "  Pickup on Friday ")
        pg.fill("#pm-text", "  Grandad will collect.  ")
        pg.click("#pm-go")
        pg.wait_for_timeout(400)
        sc = calls(pg, "parent_thread_start")
        check("the message is sent trimmed, as a title and a body",
              len(sc) == 1 and sc[0]["args"] == {"p_subject": "Pickup on Friday", "p_body": "Grandad will collect."}, sc)
        done = text(pg, "#pm-done")
        check("the parent is told the office has it", "Thank you, the office has it." in done, done)
        check("and told again it can take a while, and that ringing is for what cannot wait",
              "reads messages on working days" in done and OFFICE in done, done)
        check("the box is emptied for the next message",
              pg.input_value("#pm-title") == "" and pg.input_value("#pm-text") == "")
        pg.close()

        # ---- THE DATABASE'S REFUSALS ARE SHOWN AS WRITTEN; A TECHNICAL ONE NEVER ----
        CAP = ("You already have five conversations open with the office. Please add to one of "
               "those, or wait for a reply before starting another.")
        pg = open_page(browser, "/portal/parent/messages/",
                       parent_fx(errors={"parent_thread_start": {"code": "22023", "message": CAP}}))
        pg.fill("#pm-title", "A sixth"); pg.fill("#pm-text", "Hello")
        pg.click("#pm-go"); pg.wait_for_timeout(300)
        check("a refusal (22023) is shown as the database wrote it",
              CAP in text(pg, "#pm-error") and pg.locator("#pm-error").is_visible(), text(pg, "#pm-error"))
        check("and the box is kept, so nothing typed is lost",
              pg.input_value("#pm-text") == "Hello")
        pg.close()
        INTERNAL = 'relation "madrasah_threads" does not exist'
        pg = open_page(browser, "/portal/parent/messages/",
                       parent_fx(errors={"parent_thread_start": {"code": "42P01", "message": INTERNAL}}))
        pg.fill("#pm-title", "x"); pg.fill("#pm-text", "y")
        pg.click("#pm-go"); pg.wait_for_timeout(300)
        e = text(pg, "#pm-error")
        check("a technical error is never shown to a parent",
              "madrasah_threads" not in e and "relation" not in e and OFFICE in e, e)
        pg.close()
        pg = open_page(browser, "/portal/parent/messages/",
                       parent_fx(errors={"parent_thread_start": {"message": "Failed to fetch"}}))
        pg.fill("#pm-title", "x"); pg.fill("#pm-text", "y")
        pg.click("#pm-go"); pg.wait_for_timeout(300)
        check("no connection is said plainly", "could not reach the madrasah" in text(pg, "#pm-error"), text(pg, "#pm-error"))
        pg.close()

        # ---- NOT A PARENT ----
        pg = open_page(browser, "/portal/parent/messages/",
                       parent_fx(answers={"parent_threads": {"allowed": False}}))
        e = text(pg, "#pm-error")
        check("a login that is not a parent's is told so, in words, with the number",
              "not set up as a parent's" in e and OFFICE in e, e)
        check("and is offered no box to write in",
              pg.locator("#pm-compose").is_hidden() and pg.locator("#pm-title").count() == 0)
        check("and an empty list was NOT shown as if it were theirs",
              pg.locator("#pm-list-wrap").is_hidden())
        pg.close()

        # ---- NEVER WROTE ----
        pg = open_page(browser, "/portal/parent/messages/",
                       parent_fx(answers={"parent_threads": {"allowed": True, "unread": 0, "threads": []}}))
        check("a family that has never written is told so and offered the box",
              "You have not written to the office yet." in text(pg, "#pm-compose")
              and pg.locator("#pm-title").is_visible())
        check("and no empty 'Your conversations' heading is drawn", pg.locator("#pm-list-wrap").is_hidden())
        pg.close()

        # ---- FROM MY CHILDREN: #details ----
        pg = open_page(browser, "/portal/parent/messages/#details", parent_fx())
        check("arriving from 'tell us if this is wrong' opens the box with a title already in it",
              pg.input_value("#pm-title") == "Something on my child's record is wrong", pg.input_value("#pm-title"))
        pg.close()

        # ---- WHAT THE PARENT SCREEN NEVER DOES ----
        pg = open_page(browser, "/portal/parent/messages/", parent_fx())
        pg.click('.pm-row[data-id="t1"]'); pg.wait_for_timeout(300)
        used = set(all_calls(pg))
        check("it never calls an office function",
              not [n for n in used if n.startswith("office_")], used)
        check("and never touches the tables directly",
              "madrasah_threads" not in pg.evaluate("() => window.__tables")
              and "madrasah_messages" not in pg.evaluate("() => window.__tables"))
        pg.close()

        # ---- HOSTILE TEXT IS TEXT ----
        hostile = {"allowed": True, "thread": pthread(1, "<img src=x onerror=window.__pwned=1>", "answered", False),
                   "messages": [pmsg("you", BODY_HTML), pmsg("office", "<i>x</i>")]}
        fx = parent_fx()
        fx["answers"]["parent_thread_read"] = {"__byId": {"t1": hostile}}
        pg = open_page(browser, "/portal/parent/messages/", fx)
        pg.click('.pm-row[data-id="t1"]'); pg.wait_for_timeout(300)
        check("a message with markup in it is shown as text, and runs nothing",
              BODY_HTML in text(pg, "#pm-thread") and pg.evaluate("() => window.__pwned") is None
              and pg.locator("#pm-thread .pm-body b, #pm-thread .pm-body i, #pm-thread script").count() == 0)
        pg.close()

        # ---- A PHONE ----
        pg = open_page(browser, "/portal/parent/messages/", parent_fx(), width=390, height=844)
        check("no sideways scroll at 390px (list)", no_sideways_scroll(pg))
        pg.click('.pm-row[data-id="t1"]'); pg.wait_for_timeout(300)
        check("no sideways scroll at 390px (a conversation)", no_sideways_scroll(pg))
        small = pg.evaluate("""() => Array.prototype.filter.call(
            document.querySelectorAll('#pm-panel button, #pm-panel input[type=text], #pm-panel textarea'),
            function (n) { var r = n.getBoundingClientRect(); return r.width > 0 && r.height < 44; }).length""")
        check("every button and box is at least 44px tall on a phone", small == 0, small)
        pg.close()

        # ================================================================
        #  THE OFFICE'S SCREEN
        # ================================================================
        pg = open_page(browser, "/portal/messages/", office_fx(roles=[]))
        check("a role-less account is refused", pg.locator("#ms-panel").is_hidden())
        check("and nothing was fetched for them", len(calls(pg, "office_threads")) == 0, all_calls(pg))
        pg.close()

        pg = open_page(browser, "/portal/messages/", office_fx(roles=["teacher"]))
        check("a teacher gets no screen", pg.locator("#ms-panel").is_hidden())
        check("and nothing was fetched for a teacher", len(calls(pg, "office_threads")) == 0, all_calls(pg))
        pg.close()

        # ---- THE DATABASE REFUSES (a teacher who slips through, two-step missing) ----
        pg = open_page(browser, "/portal/messages/", office_fx(answers={"office_threads": {"allowed": False}}))
        check("{allowed:false} becomes a sentence, and never an empty list",
              "for the madrasah office" in text(pg, "#ms-error")
              and pg.locator("#ms-list").is_hidden() and pg.locator("#ms-empty").is_hidden(),
              text(pg, "#ms-error"))
        pg.close()

        # ---- THE LIST ----
        wl = waiting_list()
        wl["threads"][0].update({"body": SECRET_BODY, "family": FAMILY, "first_message": SECRET_BODY,
                                 "child": "Aaliyah"})
        pg = open_page(browser, "/portal/messages/",
                       office_fx(answers={"office_threads": {"__byWhich": {"waiting": wl}},
                                          "office_thread_read": {"__byId": OFFICE_OPENED},
                                          "office_thread_reply": {"allowed": True, "state": "answered"},
                                          "office_thread_close": {"allowed": True, "state": "closed"}}))
        check("the office screen is shown", pg.locator("#ms-panel").is_visible())
        check("the heading says Messages", "Messages" in text(pg, "h1"), text(pg, "h1"))
        check("the rail's Messages row is a link and is where you are",
              pg.locator('.ashell a.area[aria-current="page"]', has_text="Messages").count() == 1)
        lst = text(pg, "#ms-list")
        tabs = text(pg, "#ms-tabs")
        check("the list shows the parent's title and the family's REFERENCE",
              "Absence on Thursday" in lst and "MF-000123" in lst, lst)
        check("it says how long a message has waited, in words",
              "waiting 3 days" in lst and "waiting today" in lst, lst)
        check("it says how many messages are in each", "2 messages" in lst and "1 message" in lst, lst)
        check("an unread one says 'new'", lst.count("new") == 1, lst)
        check("the list shows NO family name", FAMILY not in lst and "Zzzfamily" not in lst, lst)
        check("the list shows NO word of a message, even when the server sent one",
              SECRET_BODY not in lst and SECRET_BODY not in pg.content(), lst)
        check("nor a child's name", "Aaliyah" not in lst)
        check("the tabs carry the counts: waiting 2, answered 1, closed 4, all 7",
              re.search(r"Waiting for a reply\s*2", tabs) and re.search(r"Answered\s*1", tabs)
              and re.search(r"Closed\s*4", tabs) and re.search(r"All\s*7", tabs), tabs)
        check("the page says a name is shown only when a conversation is opened, and that this is recorded",
              "only when you open a conversation" in text(pg, "#ms-sub")
              and "opening one is recorded" in text(pg, "#ms-sub"), text(pg, "#ms-sub"))
        check("listing opened no conversation: nothing that audits was called",
              "office_thread_read" not in all_calls(pg), all_calls(pg))

        # ---- OPEN ONE ----
        pg.click('.ms-row[data-id="o1"]'); pg.wait_for_timeout(300)
        th = text(pg, "#ms-thread")
        check("opening a conversation shows the family and the reference",
              FAMILY in th and "MF-000123" in th, th[:200])
        check("and the words, with who wrote each",
              BODY_1 in th and "Proofparent Alpha" in th, th[:400])
        check("hostile markup in a parent's message is text and runs nothing",
              BODY_HTML in th and pg.evaluate("() => window.__pwned") is None
              and pg.locator("#ms-thread .ms-body b, #ms-thread script").count() == 0)
        check("opening it is exactly one office_thread_read for that id",
              [c["args"] for c in calls(pg, "office_thread_read")] == [{"p_thread": "o1"}])
        check("it says who will see the reply as coming from the office, not a person",
              "message from the office, not from you by name" in th, th)
        check("a waiting conversation offers Close without replying",
              "Close without replying" in th)

        pg.click("#ms-send")
        check("an empty reply is refused on the screen with the database's own words",
              "Write the reply first." in text(pg, "#ms-inline"), text(pg, "#ms-inline"))
        check("and was never sent", len(calls(pg, "office_thread_reply")) == 0)
        pg.fill("#ms-reply", "  Thank you, noted.  ")
        pg.click("#ms-send"); pg.wait_for_timeout(500)
        rc = calls(pg, "office_thread_reply")
        check("the reply is sent for that conversation, trimmed",
              len(rc) == 1 and rc[0]["args"] == {"p_thread": "o1", "p_body": "Thank you, noted."}, rc)
        check("the office is told it was sent, and what the family will see",
              "Reply sent." in text(pg, "#ms-ok"), text(pg, "#ms-ok"))
        check("the list is reloaded from the server, not edited locally",
              len(calls(pg, "office_threads")) >= 2)
        check("and the conversation panel is put away", pg.locator("#ms-thread").is_hidden())
        pg.close()

        # ---- CLOSE, AND A CLOSED ONE ----
        pg = open_page(browser, "/portal/messages/", office_fx())
        pg.click('.ms-row[data-id="o1"]'); pg.wait_for_timeout(300)
        pg.click("#ms-close"); pg.wait_for_timeout(500)
        check("Close calls office_thread_close for that conversation only",
              [c["args"] for c in calls(pg, "office_thread_close")] == [{"p_thread": "o1"}])
        check("and says it is closed", "Conversation closed." in text(pg, "#ms-ok"), text(pg, "#ms-ok"))
        pg.click('.ms-tab[data-tab="all"]'); pg.wait_for_timeout(300)
        check("the All tab lists a closed conversation and says it is closed",
              "An old question" in text(pg, "#ms-list") and "closed" in text(pg, "#ms-list"), text(pg, "#ms-list"))
        pg.click('.ms-row[data-id="o9"]'); pg.wait_for_timeout(300)
        th = text(pg, "#ms-thread")
        check("a closed conversation says replying reopens it, and offers no close button",
              "Replying reopens it" in th and pg.locator("#ms-close").count() == 0, th)
        check("the tab that was pressed asked the server for that tab",
              [c["args"] for c in calls(pg, "office_threads")][-1] == {"p_which": "all"}, calls(pg, "office_threads")[-1])
        pg.close()

        # ---- THE EMPTY TAB ----
        pg = open_page(browser, "/portal/messages/",
                       office_fx(answers={"office_threads": {"__byWhich": {"waiting": {
                           "allowed": True, "which": "waiting",
                           "counts": {"waiting": 0, "answered": 3, "closed": 0}, "threads": []}}}}))
        e = text(pg, "#ms-empty")
        check("nothing waiting is SAID, not left as a blank table",
              "Nothing is waiting for a reply" in e and pg.locator("#ms-empty").is_visible(), e)
        check("and the waiting tab is not styled as an alert when it holds nothing",
              pg.locator(".ms-tab-alert").count() == 0)
        pg.close()

        # ---- A REFUSED REPLY IS SHOWN ----
        pg = open_page(browser, "/portal/messages/",
                       office_fx(errors={"office_thread_reply": {"code": "22023", "message": "That reply is longer than 4,000 characters. Please shorten it or send it as two."}}))
        pg.click('.ms-row[data-id="o1"]'); pg.wait_for_timeout(300)
        pg.fill("#ms-reply", "x"); pg.click("#ms-send"); pg.wait_for_timeout(300)
        check("a database refusal to the office is shown as written",
              "longer than 4,000 characters" in text(pg, "#ms-error"), text(pg, "#ms-error"))
        check("and the reply typed is kept", pg.input_value("#ms-reply") == "x")
        pg.close()

        # ---- A PHONE ----
        pg = open_page(browser, "/portal/messages/", office_fx(), width=390, height=844)
        check("no sideways scroll at 390px (office list)", no_sideways_scroll(pg))
        pg.click('.ms-row[data-id="o1"]'); pg.wait_for_timeout(300)
        check("no sideways scroll at 390px (office conversation)", no_sideways_scroll(pg))
        pg.close()

        browser.close()
    FINISHED[0] = True


if __name__ == "__main__":
    run()
