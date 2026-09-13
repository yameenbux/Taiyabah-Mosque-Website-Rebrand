"""/portal/ — the madrasah, three pages behind one door.

13 September 2026. /portal/ was live and broken before this: its index.html was
the madrasah sign-in page and its app.js was a copy of the admin-centre
signpost, looking for elements this page has never had. It threw on every load
and rendered nothing past the spinner.

WHAT THIS FILE GUARDS:

  1  an administrator gets the console
  2  THE FIGURES SAY WHERE THEY COME FROM. 539 pupils is true of the masjid and
     false of this database, and a number on the screen an administrator lands
     on becomes a number reported to the committee
  3  nothing is clickable, and nothing pretends to be — a dead button teaches
     people the page is broken
  4  a teacher gets the teachers' page, a parent gets the parents' page, and
     neither is shown an administrator's console
  5  neither is offered a link to the admin centre, which would refuse them
  6  somebody with none of those roles is told so
  7  the page that gates the first pupil record carries the list of what has to
     happen before it

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


def stub(roles):
    return """
(function(){
  var ROLES = %s;
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
    rpc: function(){ return Promise.resolve({data:{}, error:null}); }
  };
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}}, writable:false, configurable:false});
})();
""" % json.dumps(roles)


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

    counts = text(pg, "#md-counts")
    for n in ["539", "39", "43", "962"]:
        check(n in counts, "the %s count is missing: %r" % (n, counts[:200]))

    # =====================================================================
    #  2. THE FIGURES SAY WHERE THEY COME FROM
    #
    #  Twice: once in the panel above them, once on EVERY tile. Somebody
    #  screenshots one tile for a committee paper and the caveat has to travel
    #  with the number.
    # =====================================================================
    check("nothing has been imported" in text(pg, "#md-lead").lower(),
          "the panel above the figures does not say nothing has been imported: %r"
          % text(pg, "#md-lead"))
    tiles = pg.eval_on_selector_all("#md-counts .md-count", "els => els.map(e => e.innerText)")
    check(len(tiles) == 4, "expected four count tiles, drew %d" % len(tiles))
    for t in tiles:
        check("not imported" in t.lower(),
              "A FIGURE IS ON SCREEN WITH NOTHING SAYING IT IS NOT THIS "
              "SYSTEM'S: %r" % t[:160])
    check("no pupil records at all" in text(pg, "#md-lead").lower(),
          "the page does not say the database is empty: %r" % text(pg, "#md-lead"))

    # =====================================================================
    #  3. NOTHING PRETENDS TO BE CLICKABLE
    # =====================================================================
    clickable = pg.eval_on_selector_all(
        "#md-counts a, #md-counts button, #md-areas a, #md-areas button",
        "els => els.length")
    check(clickable == 0,
          "%d things on the console look pressable and go nowhere. A dead "
          "control teaches people the page is broken, and then they stop "
          "reporting when it really is" % clickable)
    #  .lower(), because `.md-area .w` is text-transform:uppercase and innerText
    #  returns what the CSS made of it. Three assertions in this session have
    #  been caught by that.
    check("not open yet" in text(pg, "#md-areas").lower(),
          "the areas do not say they are not open: %r" % text(pg, "#md-areas")[:200])

    # =====================================================================
    #  7. THE GATE IS ON THE PAGE IT GATES
    # =====================================================================
    before = text(pg, "#md-before-list").lower()
    for want in ["dpia", "ico", "article 9", "export", "aal2"]:
        check(want in before,
              "%r is missing from what must happen before the first pupil "
              "record: %r" % (want, before[:300]))
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
    check(not pg.is_visible("#app-top-back"),
          "a teacher is offered a link to the admin centre, which refuses them")
    check("teachers" in text(pg, "#app-top-where").lower(),
          "the bar does not say which portal this is: %r" % text(pg, "#app-top-where"))
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
print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
