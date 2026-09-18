"""/portal/staff/ — the madrasah's staff list, its editor, and its two sides.

18 September 2026. Written after this screen shipped with three separate
faults that nobody's tests could see, because nothing tested this screen: it
sits two folders deep, and sweep_test.py and admin_shell_test.py both stop at
one. Every check below exists because of something that actually went wrong.

WHAT THIS FILE GUARDS:

  1  THE EDITOR IS NOT ON SCREEN UNTIL SOMEBODY ASKS FOR IT.
     It was. `.st-form{display:flex}` beats `[hidden]{display:none}` on
     specificity, so the form sat under the list from page load with every box
     empty, and "Add somebody" appeared to do nothing but scroll. The property
     was true the whole time — which is why this checks what is VISIBLE and
     never checks `.hidden`. A test that asserted the property would have
     passed on the broken page.

  2  AMENDING SOMEBODY ASKS FIRST, AND NOTHING IS WRITTEN UNTIL IT IS ANSWERED.
     Forty rows that look alike; opening the wrong one and saving over it is a
     mistake nothing afterwards reveals. The question names the person, and
     the count of writes is what proves it is a question and not a notice.

  3  ADDING SOMEBODY NEW DOES NOT ASK. It overwrites nothing, and a confirm on
     every save is how a confirm stops being read.

  4  A CHANGE MADE WHILE THE QUESTION IS UP WITHDRAWS IT. Otherwise the strip
     names a save that is no longer the one that would happen.

  5  THE TWO SIDES LOOK DIFFERENT, MEASURED RATHER THAN ASSUMED.

  6  NO RECORD NAMES THE SYSTEM THE MADRASAH USED BEFORE, and what that system
     said about DBS still reaches the screen — those are two requirements, not
     one, and deleting the notes would have satisfied only the first.

  7  THE STAFF FUNCTIONS ARE SCOPED TO A MASJID. 053 rebuilt them from 052's
     text, which predates the tenancy columns, and dropped the masjid_id out
     of the insert. Every save on this screen failed with a not-null violation
     — including amendments, because the constraint is checked before ON
     CONFLICT looks for a conflict. This is a static check on the SQL, and it
     is the cheapest of the seven.

Nothing here reaches Supabase.

Run:  python3 _test/staff_screen_test.py
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
PAGE = "http://127.0.0.1:%d/portal/staff/" % httpd.server_address[1]

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


#  WHAT WENT WRONG SURVIVES A CRASH.
#
#  Found while proving these checks can fail. Break the confirm step and the
#  run dies on a Playwright timeout hunting a button that is no longer there —
#  the assertions that had already failed were collected and then thrown away
#  with the interpreter, so the only output was a stack trace about a locator.
#  A reader learns nothing from that. Printing on the way out means the
#  diagnosis is there whether the file finished or fell over.
import atexit


@atexit.register
def _report():
    if fails:
        print("FAIL (%d)" % len(fails))
        for f in fails:
            print("  - " + f)
    elif _report.reached_end:
        print("ALL PASS")
    else:
        print("DID NOT FINISH — see the traceback above. Nothing above failed "
              "before it stopped.")


_report.reached_end = False


#  Three people, one per side plus one with none, because the "side not set"
#  group only draws when somebody is in it. Two carry a prior_dbs word and no
#  note, which is the shape every imported record has after 054.
STAFF = [
    {"id": "s1", "honorific": "Apa", "first_name": "Fatima", "last_name": "Adam",
     "side": "sisters", "employment": "employed", "work_days": ["mon", "tue"],
     "dbs_issued": None, "dbs_update_service": False, "dbs_last_checked": None,
     "dbs_not_required": False, "dbs": "none", "prior_dbs": "valid",
     "email": None, "phone": None, "note": None,
     "classes": [{"id": "c1", "name": "Girls OOLA"}],
     "display_name": "Apa Fatima Adam"},
    {"id": "s2", "honorific": "Moulana", "first_name": "Bilal", "last_name": "Bux",
     "side": "brothers", "employment": "employed", "work_days": [],
     "dbs_issued": None, "dbs_update_service": False, "dbs_last_checked": None,
     "dbs_not_required": False, "dbs": "none", "prior_dbs": "none",
     "email": None, "phone": None, "note": None,
     "classes": [], "display_name": "Moulana Bilal Bux"},
    {"id": "s3", "honorific": None, "first_name": "Aisha", "last_name": "Carr",
     "side": None, "employment": "employed", "work_days": None,
     "dbs_issued": None, "dbs_update_service": False, "dbs_last_checked": None,
     "dbs_not_required": False, "dbs": "none", "prior_dbs": "expired",
     "email": None, "phone": None, "note": None,
     "classes": [], "display_name": "Aisha Carr"},
]

CLASSES = [{"id": "c1", "name": "Girls OOLA", "section": "girls",
            "is_active": True, "sort_order": 1}]


def stub(roles):
    """A client that answers, and COUNTS THE WRITES.

    window.__saves is the whole point of half this file: "it did not write"
    cannot be checked by looking at the screen, because a screen that has not
    written yet and a screen that has written and not said so look identical.
    """
    return """
(function(){
  var ROLES = %s, STAFF = %s, CLASSES = %s;
  window.__saves = [];
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
    rpc: function(name, args){
      if (name === 'madrasah_staff_list')   return Promise.resolve({data:STAFF, error:null});
      if (name === 'madrasah_classes_list') return Promise.resolve({data:CLASSES, error:null});
      if (name === 'save_madrasah_staff') {
        window.__saves.push(args && args.p);
        return Promise.resolve({data:{id:(args&&args.p&&args.p.id)||'new'}, error:null});
      }
      return Promise.resolve({data:{}, error:null});
    }
  };
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}}, writable:false, configurable:false});
})();
""" % (json.dumps(roles), json.dumps(STAFF), json.dumps(CLASSES))


def open_as(b, roles, w=1400, h=1400):
    pg = b.new_page(viewport={"width": w, "height": h})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.add_init_script(stub(roles))
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1300)
    return pg, errs


def shown(pg, sel):
    """VISIBLE, not `hidden`.

    The bug this file was written for made those two disagree: the property
    was true and the element was on screen. Playwright's is_visible() asks the
    layout, which is the only witness that cannot be fooled by a `display`
    rule outranking the attribute.
    """
    return pg.is_visible(sel)


def text(pg, sel):
    n = pg.query_selector(sel)
    return re.sub(r"\s+", " ", n.inner_text()) if n else ""


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1. THE EDITOR IS NOT ON SCREEN UNTIL SOMEBODY ASKS FOR IT
    # =====================================================================
    pg, errs = open_as(b, ["admin"])
    check(not errs, "the page threw on load: %r" % errs[:2])
    check(shown(pg, "#st-panel"), "the staff panel did not open for an administrator")
    check(shown(pg, "#st-list-sisters"), "the sisters' list did not render")

    check(not shown(pg, "#st-editor"),
          "THE EDITOR IS ON SCREEN BEFORE ANYBODY PRESSED ANYTHING. This is the "
          "exact fault reported: an empty form for a person who does not exist, "
          "sitting under the list from page load, which also makes "
          "“Add somebody” look like it does nothing.")
    #  And the cause, named, so a future `display` rule on this element fails
    #  here rather than on somebody's screen.
    css_display = pg.evaluate(
        "getComputedStyle(document.getElementById('st-editor')).display")
    check(css_display == "none",
          "the editor's computed display is %r while it is `hidden` — an author "
          "`display` rule is outranking [hidden]{display:none}. See the note at "
          "the top of the stylesheet." % css_display)

    check(not shown(pg, "#st-confirm"),
          "the save confirmation is on screen before anything has been saved")

    # =====================================================================
    #  2. ADD SOMEBODY OPENS IT, BACK TO THE LIST CLOSES IT
    # =====================================================================
    pg.click("#st-add")
    pg.wait_for_timeout(250)
    check(shown(pg, "#st-editor"), "“Add somebody” did not open the editor")
    check("add somebody" in text(pg, "#st-form-head").lower(),
          "the editor opened on something other than a new person: %r"
          % text(pg, "#st-form-head"))
    check(text(pg, "#st-first") == "" and pg.input_value("#st-first") == "",
          "a new person's form opened with a name already in it")

    pg.click("#st-cancel")
    pg.wait_for_timeout(250)
    check(not shown(pg, "#st-editor"), "“Back to the list” did not close the editor")

    # =====================================================================
    #  3. A ROW OPENS THAT PERSON, AND AMENDING THEM ASKS FIRST
    # =====================================================================
    pg.click("#st-list-sisters button.st-row")
    pg.wait_for_timeout(250)
    check(shown(pg, "#st-editor"), "pressing a row did not open the editor")
    check(pg.input_value("#st-first") == "Fatima",
          "the row opened somebody else's record: first name is %r"
          % pg.input_value("#st-first"))

    before = pg.evaluate("window.__saves.length")
    pg.fill("#st-phone", "01204 000000")
    pg.click("#st-save")
    pg.wait_for_timeout(300)

    asked = shown(pg, "#st-confirm")
    check(asked, "saving a change to an existing record wrote without asking")
    q = text(pg, "#st-confirm-q")
    check("Fatima" in q,
          "the question does not name the person, which is the one fact that "
          "tells somebody whether they have the right record open: %r" % q)
    check(pg.evaluate("window.__saves.length") == before,
          "THE RECORD WAS WRITTEN WHILE THE QUESTION WAS STILL ON SCREEN. That "
          "makes the confirm a notice, not a question.")

    #  EVERYTHING BELOW PRESSES BUTTONS THAT ONLY EXIST ONCE THE QUESTION IS UP.
    #  Without this gate, a build that never asks fails here as a four-second
    #  Playwright timeout on a missing locator — which says nothing about what
    #  is wrong. Proved by removing the confirm and reading the output.
    if asked:
        # ---- "No" keeps everything and still writes nothing ---------------
        pg.click("#st-confirm-no")
        pg.wait_for_timeout(250)
        check(not shown(pg, "#st-confirm"), "“No” left the question on screen")
        check(shown(pg, "#st-editor"), "“No” closed the editor — it should keep editing")
        check(pg.input_value("#st-phone") == "01204 000000",
              "“No” threw away what had been typed; it is not an undo")
        check(pg.evaluate("window.__saves.length") == before,
              "saying No still wrote the record")

        # =====================================================================
        #  4. A CHANGE WITHDRAWS THE QUESTION
        # =====================================================================
        pg.click("#st-save")
        pg.wait_for_timeout(250)
        check(shown(pg, "#st-confirm"), "the question did not come back up")
        pg.fill("#st-phone", "01204 111111")
        pg.wait_for_timeout(250)
        check(not shown(pg, "#st-confirm"),
              "the record was changed while the question was up and the question "
              "stayed — it now describes a save that is not the one that would happen")

    # =====================================================================
    #  5. YES WRITES ONCE, CLOSES, AND PUTS THE LIST BACK
    # =====================================================================
    pg.click("#st-save")
    pg.wait_for_timeout(250)
    if shown(pg, "#st-confirm"):
        pg.click("#st-confirm-yes")
    pg.wait_for_timeout(600)

    saves = pg.evaluate("window.__saves")
    check(len(saves) == before + 1,
          "expected exactly one write after saying Yes, got %d" % (len(saves) - before))
    if len(saves) > before:
        wrote = saves[-1]
        check(wrote.get("id") == "s1",
              "the write did not carry the id of the record that was open, so it "
              "would have created a second Fatima: %r" % wrote.get("id"))
        check(wrote.get("phone") == "01204 111111",
              "the write carried the value from before the last edit: %r"
              % wrote.get("phone"))
    check(not shown(pg, "#st-editor"),
          "the editor stayed open after saving — it should close and show the list")
    check(not shown(pg, "#st-confirm"), "the question stayed up after saving")
    check(shown(pg, "#st-list-sisters"), "the staff list is not back on screen after saving")

    # =====================================================================
    #  6. ADDING SOMEBODY NEW DOES NOT ASK
    # =====================================================================
    n_before = pg.evaluate("window.__saves.length")
    pg.click("#st-add")
    pg.wait_for_timeout(250)
    pg.fill("#st-first", "Zainab")
    pg.fill("#st-last", "Dawood")
    pg.click("#st-save")
    pg.wait_for_timeout(600)
    check(not shown(pg, "#st-confirm"),
          "adding a brand new person asked whether to overwrite something. It "
          "overwrites nothing, and a confirm on every save is how a confirm "
          "stops being read.")
    check(pg.evaluate("window.__saves.length") == n_before + 1,
          "adding a new person did not write")

    # =====================================================================
    #  7. THE TWO SIDES LOOK DIFFERENT — MEASURED
    # =====================================================================
    bg = pg.evaluate("""() => {
      const g = s => { const n = document.querySelector(s);
        return n ? getComputedStyle(n).backgroundColor : null; };
      const e = s => { const n = document.querySelector(s);
        return n ? getComputedStyle(n).borderLeftColor : null; };
      return { sis: g('.st-col-sisters'), bro: g('.st-col-brothers'),
               sisEdge: e('.st-col-sisters'), broEdge: e('.st-col-brothers'),
               unset: g('.st-unset') };
    }""")
    check(bg["sis"] and bg["bro"] and bg["sis"] != bg["bro"],
          "the two sides have the same background: %r" % bg)
    check(bg["sisEdge"] != bg["broEdge"],
          "the two sides have the same edge colour: %r" % bg)
    #  And neither may collide with the "side not set" group directly above
    #  them, which is the third coloured panel on the same screen.
    check(bg["sis"] != bg["unset"] and bg["bro"] != bg["unset"],
          "a side is the same colour as the “side not set” group above it: %r" % bg)

    #  THE COLOUR IS NOT THE SIGNAL. Roughly one man in twelve cannot separate
    #  these two hues, so the words have to be there whatever the colour does.
    check("sisters" in text(pg, "#st-h-sisters").lower(),
          "the sisters' column is not titled in words")
    check("brothers" in text(pg, "#st-h-brothers").lower(),
          "the brothers' column is not titled in words")

    #  THE ROW'S OWN EDGE STILL BELONGS TO THE DBS STATE. If tinting the sides
    #  had reached the rows, the safeguarding colour would have been the one
    #  that lost.
    row_edge = pg.evaluate(
        "getComputedStyle(document.querySelector('#st-list-sisters .st-row'))"
        ".borderLeftColor")
    check(row_edge != bg["sisEdge"],
          "a row's left edge is now its side's colour, which is where the DBS "
          "state is shown: %r" % row_edge)

    # =====================================================================
    #  8. NO RECORD NAMES THE OLD SYSTEM, AND WHAT IT SAID STILL ARRIVES
    # =====================================================================
    page_text = pg.inner_text("body")
    check("ibeams" not in page_text.lower(),
          "the previous system is named on the staff screen")

    notes = pg.eval_on_selector_all("#st-panel .st-note",
                                    "els => els.map(e => e.innerText)")
    check(notes, "no record carries what the previous records said about DBS. "
                 "Every one of these forty shows “nothing on file”, so without "
                 "this the twenty-two waiting on a certificate date cannot be "
                 "told from the sixteen with nothing — and it is the sixteen "
                 "that are the safeguarding question.")
    joined = " ".join(notes).lower()
    check("previous records" in joined or "previous system" in joined,
          "the DBS sentence does not say it is a report of older records, so it "
          "reads as something this system checked: %r" % notes[:2])
    check("invented" in joined or "off the certificate" in joined,
          "the DBS sentence does not say the date still has to be keyed in: %r"
          % notes[:2])

    pg.close()

    # =====================================================================
    #  9. THE STAFF FUNCTIONS ARE SCOPED TO A MASJID  (static, on the SQL)
    #
    #  This is the check that would have stopped the outage. Every table here
    #  carries `masjid_id not null` with no default; 053 rebuilt these two
    #  functions from 052's text, which predates that column, and every save
    #  on the screen has failed ever since with a not-null violation.
    # =====================================================================
    #  `.sql` and nothing else. Found while proving these checks can fail: a
    #  scratch copy left beside a migration as `054_....sql.bak` sorted AFTER
    #  the real file, so the last definition read was the stale one and the
    #  check passed over a broken migration. A test that reads whatever is
    #  lying about in a folder reports on the folder, not on the code.
    sql = ""
    for name in sorted(os.listdir("db")):
        if re.match(r"^05[0-9]_.*\.sql$", name):
            sql += open(os.path.join("db", name), encoding="utf-8").read()

    for fn in ("madrasah_staff_list", "save_madrasah_staff"):
        m = re.search(r"create or replace function public\.%s\s*\(" % fn, sql)
        check(m, "no migration in db/ contains the text of %s(). 053 wrote "
                 "“see the migration history for the full text” instead of the "
                 "function, which is exactly why a column went missing without "
                 "anybody being able to read the diff." % fn)

    save_fn = sql[sql.rfind("create or replace function public.save_madrasah_staff"):]
    save_fn = save_fn[:save_fn.find("$fn$;") + 5] if "$fn$;" in save_fn else save_fn
    check("current_masjid()" in save_fn,
          "save_madrasah_staff() never asks which masjid it is writing for. The "
          "insert will fail on masjid_id, for amendments as well as for new "
          "people, because the not-null is checked before ON CONFLICT looks for "
          "a conflict.")
    check(re.search(r"insert into public\.madrasah_staff[\s\S]{0,400}?masjid_id", save_fn),
          "masjid_id is not among the columns save_madrasah_staff() inserts")
    check("where s.masjid_id = v_masjid" in save_fn,
          "the ON CONFLICT update in save_madrasah_staff() is not restricted to "
          "this masjid, so a known id could amend another masjid's record")

    list_fn = sql[sql.rfind("create or replace function public.madrasah_staff_list"):]
    list_fn = list_fn[:list_fn.find("$fn$;") + 5] if "$fn$;" in list_fn else list_fn
    check("current_masjid()" in list_fn and "s.masjid_id = v_masjid" in list_fn,
          "madrasah_staff_list() is not scoped to a masjid — it returns every "
          "masjid's staff to any administrator")

    b.close()

_report.reached_end = True
if fails:
    sys.exit(1)
