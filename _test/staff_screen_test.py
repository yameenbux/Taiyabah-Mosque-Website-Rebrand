"""/portal/staff/ — the madrasah's staff list, one person's record, and the editor.

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

  2  EVERY ROW SAYS WHAT IS ON FILE, AND SAYS IT THE SAME WAY WHETHER OR NOT
     ANYTHING IS THERE. Five marks, always five, always in the same order. If
     an absent thing were left out, a person with nothing on file and a person
     with everything would differ only in how wide the row was, and the eye
     would have nothing to count. The marks also carry words, because roughly
     one man in twelve cannot separate the green from the grey.

  3  A ROW OPENS THAT PERSON'S RECORD, AND THE LIST GOES AWAY.
     The list half is five separate elements and every one of them has an
     author `display` rule. showStaff() first shipped naming three ids that do
     not exist in the page at all — el() returned null and the loop skipped
     them in silence, so the record would have drawn UNDERNEATH the whole
     staff list. Hence: this checks each piece of the list half is gone, and
     checks computed `display` as well as visibility.

  4  THE LIST HOLDS FLAGS AND THE RECORD HOLDS VALUES.
     Forty rows do not carry forty addresses and forty dates of birth. The
     proof is that the address is nowhere on the page until one record is
     opened — which is the whole reason the marks are marks.

  5  AMENDING SOMEBODY ASKS FIRST, AND NOTHING IS WRITTEN UNTIL IT IS ANSWERED.
     Forty rows that look alike; opening the wrong one and saving over it is a
     mistake nothing afterwards reveals. The question names the person, and
     the count of writes is what proves it is a question and not a notice.

  6  A SAVE MADE FROM INSIDE A RECORD REACHES THE RECORD.
     Saving used to re-read the list — which at that moment is hidden — and
     leave the record above the editor showing the number that had just been
     changed, beside the word "Saved". That reads as a failed save.

  7  REMOVING SOMEBODY ASKS, ARCHIVES, AND DELETES NOTHING.
     The question has to say the word archive and say the record can come
     back, or it is answered as though it were a delete.

  8  ADDING SOMEBODY NEW DOES NOT ASK. It overwrites nothing, and a confirm on
     every save is how a confirm stops being read.

  9  THE TWO SIDES LOOK DIFFERENT, MEASURED RATHER THAN ASSUMED.

 10  NO RECORD NAMES THE SYSTEM THE MADRASAH USED BEFORE, and what that system
     said about DBS still reaches the screen — those are two requirements, not
     one, and deleting the notes would have satisfied only the first.

 11  THE STAFF FUNCTIONS ARE SCOPED TO A MASJID, THE LIST RETURNS FLAGS AND NOT
     VALUES, AND REMOVING ARCHIVES. Static checks on the SQL, and the cheapest
     in the file.

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
#
#  THE FLAGS ARE WHAT madrasah_staff_list() RETURNS AFTER 065, AND THERE IS NO
#  address, date_of_birth OR work_times ANYWHERE IN THIS FIXTURE. That is not
#  an oversight — it is the fixture agreeing with the function. If the screen
#  ever starts reading a value off a list row, it will read undefined here and
#  the check in section 4 will say so.
STAFF = [
    {"id": "s1", "honorific": "Apa", "first_name": "Fatima", "last_name": "Adam",
     "side": "sisters", "employment": "employed", "work_days": ["mon", "tue"],
     "dbs_issued": None, "dbs_update_service": False, "dbs_last_checked": None,
     "dbs_not_required": False, "dbs": "none", "prior_dbs": "valid",
     "email": None, "phone": None, "note": None,
     "has_address": True, "has_phone": True, "has_email": False,
     "has_dob": True, "has_hours": True, "days_a_week": 2,
     "classes": [{"id": "c1", "name": "Girls OOLA"}],
     "display_name": "Apa Fatima Adam"},
    {"id": "s2", "honorific": "Moulana", "first_name": "Bilal", "last_name": "Bux",
     "side": "brothers", "employment": "employed", "work_days": [],
     "dbs_issued": None, "dbs_update_service": False, "dbs_last_checked": None,
     "dbs_not_required": False, "dbs": "none", "prior_dbs": "none",
     "email": None, "phone": None, "note": None,
     "has_address": False, "has_phone": False, "has_email": False,
     "has_dob": False, "has_hours": False, "days_a_week": 0,
     "classes": [], "display_name": "Moulana Bilal Bux"},
    {"id": "s3", "honorific": None, "first_name": "Aisha", "last_name": "Carr",
     "side": None, "employment": "employed", "work_days": None,
     "dbs_issued": None, "dbs_update_service": False, "dbs_last_checked": None,
     "dbs_not_required": False, "dbs": "none", "prior_dbs": "expired",
     "email": None, "phone": None, "note": None,
     "has_address": False, "has_phone": True, "has_email": False,
     "has_dob": False, "has_hours": False, "days_a_week": 0,
     "classes": [], "display_name": "Aisha Carr"},
]

#  What madrasah_staff_one() gives back, which is the only place a value ever
#  comes from. ADDRESS_S1 is deliberately a string that could not appear on the
#  page by accident.
ADDRESS_S1 = "14 Sutcliffe Street, Bolton"
ONE = {
    "s1": {"id": "s1", "name": "Apa Fatima Adam", "side": "sisters",
           "employment": "employed", "started_on": "2024-02-08", "left_on": None,
           "address": ADDRESS_S1, "date_of_birth": "1980-09-10",
           "phone": "07700 900000", "phone_alt": None, "email": None,
           "work_times": {"mon": "17:00-19:00", "tue": "17:00-19:00"},
           "dbs": "none", "dbs_issued": None, "dbs_update_service": False,
           "dbs_last_checked": None, "dbs_not_required": False,
           "prior_dbs": "valid", "note": None,
           "classes": [{"id": "c1", "name": "Girls OOLA"}],
           "main_teacher_of": [{"id": "c1", "name": "Girls OOLA"}]},
    "s2": {"id": "s2", "name": "Moulana Bilal Bux", "side": "brothers",
           "employment": "employed", "started_on": None, "left_on": None,
           "address": None, "date_of_birth": None, "phone": None,
           "phone_alt": None, "email": None, "work_times": {},
           "dbs": "none", "dbs_issued": None, "dbs_update_service": False,
           "dbs_last_checked": None, "dbs_not_required": False,
           "prior_dbs": "none", "note": None,
           "classes": [], "main_teacher_of": []},
}

CLASSES = [{"id": "c1", "name": "Girls OOLA", "section": "girls",
            "is_active": True, "sort_order": 1}]


def stub(roles):
    """A client that answers, and COUNTS THE WRITES.

    window.__saves is the whole point of half this file: "it did not write"
    cannot be checked by looking at the screen, because a screen that has not
    written yet and a screen that has written and not said so look identical.
    __archives does the same job for the remove button, and __reads records
    every time one person's record is fetched — which is how section 6 proves
    the record was RE-READ after a save rather than left as it was.

    A save on an existing person edits this stub's copy, so a record that is
    re-read comes back changed. A stub that always answered the same thing
    would let a screen that never re-reads pass section 6.
    """
    return """
(function(){
  var ROLES = %s, STAFF = %s, ONE = %s, CLASSES = %s;
  window.__saves = []; window.__archives = []; window.__reads = [];
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
      if (name === 'madrasah_staff_one') {
        var id = args && args.p_id;
        window.__reads.push(id);
        return Promise.resolve({data: ONE[id] || null, error:null});
      }
      if (name === 'archive_madrasah_staff') {
        window.__archives.push(args);
        return Promise.resolve({data:{ok:true}, error:null});
      }
      if (name === 'save_madrasah_staff') {
        var p = (args && args.p) || {};
        window.__saves.push(p);
        if (p.id && ONE[p.id]) {          // the database kept it; so does the stub
          if ('phone' in p) ONE[p.id].phone = p.phone;
          if ('email' in p) ONE[p.id].email = p.email;
        }
        return Promise.resolve({data:{id: p.id || 'new'}, error:null});
      }
      return Promise.resolve({data:{}, error:null});
    }
  };
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}}, writable:false, configurable:false});
})();
""" % (json.dumps(roles), json.dumps(STAFF), json.dumps(ONE), json.dumps(CLASSES))


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
    check(not shown(pg, "#st-record"),
          "somebody's record is open before any row has been pressed")

    # ---- "Add somebody" opens it, "Back to the list" closes it -----------
    pg.click("#st-add")
    pg.wait_for_timeout(250)
    check(shown(pg, "#st-editor"), "“Add somebody” did not open the editor")
    check("add somebody" in text(pg, "#st-form-head").lower(),
          "the editor opened on something other than a new person: %r"
          % text(pg, "#st-form-head"))
    check(pg.input_value("#st-first") == "",
          "a new person's form opened with a name already in it")

    pg.click("#st-cancel")
    pg.wait_for_timeout(250)
    check(not shown(pg, "#st-editor"), "“Back to the list” did not close the editor")

    # =====================================================================
    #  2. EVERY ROW SAYS WHAT IS ON FILE, IN THE SAME FIVE PLACES
    #
    #  Asked for: "you can showcase little icons on the teachers each specific
    #  section to show what the teacher has available of them."
    # =====================================================================
    marks = pg.evaluate("""() => {
      const out = {};
      for (const row of document.querySelectorAll('#st-panel button.st-row')) {
        const id = row.getAttribute('data-id');
        out[id] = [...row.querySelectorAll('.st-mark')].map(m => ({
          cls: m.className,
          letter: m.querySelector('[aria-hidden="true"]')?.textContent || '',
          words: m.querySelector('.sr-only')?.textContent || '',
          title: m.getAttribute('title') || ''
        }));
      }
      return out;
    }""")

    check(set(marks) == {"s1", "s2", "s3"},
          "not every row drew the on-file marks: %r" % sorted(marks))
    #  THE COUNT IS THE CHECK. Five on the person with nothing exactly as on
    #  the person with something — drop the absent ones and this fails.
    for who, ms in marks.items():
        check(len(ms) == 5,
              "row %s drew %d marks, not five. A missing thing has to be DRAWN, "
              "or a thin row and a full row look like the same row with less in "
              "it and there is nothing to count against." % (who, len(ms)))
    if all(len(ms) == 5 for ms in marks.values()):
        #  The order is fixed, so the eye learns the positions.
        for who, ms in marks.items():
            check([m["letter"] for m in ms] == ["A", "T", "E", "B", "H"],
                  "row %s put the marks in a different order: %r"
                  % (who, [m["letter"] for m in ms]))
        s1 = marks["s1"]
        check([("yes" in m["cls"]) for m in s1] == [True, True, False, True, True],
              "Fatima's marks do not match her flags: %r"
              % [m["cls"] for m in s1])
        check(all("no" in m["cls"] for m in marks["s2"]),
              "Bilal has nothing on file and some of his marks say he has")
        #  NOT A COLOUR-ONLY SIGNAL. One man in twelve cannot separate these
        #  two, so each mark says what it means in words a screen reader and a
        #  hover both reach.
        check(all("not on file" in m["words"].lower() for m in marks["s2"]),
              "an absent thing is shown only by its colour: %r"
              % [m["words"] for m in marks["s2"]])
        check(any("2 days a week" in m["title"] for m in s1),
              "the hours mark does not say how many days, which is the one number "
              "worth reading off it: %r" % [m["title"] for m in s1])

    #  And the two states are told apart by more than hue — the absent one is
    #  dashed, so it survives a black and white printout.
    styles = pg.evaluate("""() => {
      const g = s => { const n = document.querySelector(s); if (!n) return null;
        const c = getComputedStyle(n);
        return {bg: c.backgroundColor, style: c.borderTopStyle}; };
      return {yes: g('#st-list-sisters .st-mark.yes'),
              no:  g('#st-list-brothers .st-mark.no')};
    }""")
    check(styles["yes"] and styles["no"], "the marks did not render on both sides")
    if styles["yes"] and styles["no"]:
        check(styles["yes"]["bg"] != styles["no"]["bg"],
              "on file and not on file are the same colour: %r" % styles)
        check(styles["yes"]["style"] != styles["no"]["style"],
              "on file and not on file differ only by colour — the border style is "
              "the same, so the distinction disappears in black and white: %r"
              % styles)

    # =====================================================================
    #  3. A ROW OPENS THAT PERSON'S RECORD, AND THE LIST HALF GOES AWAY
    #
    #  The check that catches showStaff() naming ids that are not in the page.
    #  Every one of these five has an author `display` rule, so both questions
    #  are asked: is it visible, and is its computed display none.
    # =====================================================================
    LIST_HALF = ["#dbs", "#st-controls", "#st-cols", "#st-list-acts", "#st-unset"]
    for sel in LIST_HALF:
        check(shown(pg, sel), "%s is not on screen with the list showing" % sel)

    pg.click("#st-list-sisters button.st-row")
    pg.wait_for_timeout(400)

    check(shown(pg, "#st-record"), "pressing a row did not open that person's record")
    check(not shown(pg, "#st-editor"),
          "pressing a row dropped straight into the editor. Most of the time "
          "somebody is LOOKING a person up, and a form full of live inputs "
          "invites a change nobody meant to make.")
    for sel in LIST_HALF:
        check(not shown(pg, sel),
              "%s IS STILL ON SCREEN WITH A RECORD OPEN. The record is drawing "
              "underneath the whole staff list — showStaff() is naming an id that "
              "is not in the page, and el() returns null and the loop skips it "
              "without a word." % sel)
    displays = pg.evaluate("""(sels) => Object.fromEntries(sels.map(s => {
        const n = document.querySelector(s);
        return [s, n ? getComputedStyle(n).display : 'MISSING'];
    }))""", LIST_HALF)
    for sel, d in displays.items():
        check(d == "none",
              "%s computes display:%s while it is `hidden` — either the element "
              "does not exist (MISSING) or an author `display` rule is outranking "
              "[hidden]. Both have happened on this page." % (sel, d))

    check(pg.evaluate("window.__reads").count("s1") == 1,
          "opening a record did not fetch that one person, or fetched them twice: %r"
          % pg.evaluate("window.__reads"))
    check("Fatima" in text(pg, "#st-rec-name"),
          "the record opened on somebody else: %r" % text(pg, "#st-rec-name"))

    # =====================================================================
    #  4. THE LIST HOLDS FLAGS; THE RECORD HOLDS VALUES
    # =====================================================================
    body = pg.inner_text("body")
    check(ADDRESS_S1 in body,
          "the record does not show the address, which is the whole point of "
          "opening one")
    check("17:00-19:00" in body.replace("–", "-"),
          "the record does not show the hours the marks say are on file")
    check("Girls OOLA" in body, "the record does not say which class they take")

    pg.click("#st-rec-back")
    pg.wait_for_timeout(300)
    check(shown(pg, "#st-list-sisters"), "“All staff” did not put the list back")
    check(not shown(pg, "#st-record"), "“All staff” left the record on screen")
    for sel in LIST_HALF:
        check(shown(pg, sel), "%s did not come back with the list" % sel)

    back = pg.inner_text("body")
    check(ADDRESS_S1 not in back,
          "AN ADDRESS IS ON THE LIST SCREEN. Forty rows are not supposed to carry "
          "forty addresses and forty dates of birth — the marks exist precisely so "
          "that the values stay in madrasah_staff_one(). Either the list function "
          "has started returning values, or the record was left in the page.")

    # =====================================================================
    #  5. AMENDING FROM THE RECORD ASKS FIRST AND WRITES NOTHING UNTIL ANSWERED
    # =====================================================================
    pg.click("#st-list-sisters button.st-row")
    pg.wait_for_timeout(400)
    pg.click("#st-rec-edit")
    pg.wait_for_timeout(300)
    check(shown(pg, "#st-editor"), "“Amend this record” did not open the editor")
    check(pg.input_value("#st-first") == "Fatima",
          "the editor opened on somebody else: first name is %r"
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
        pg.click("#st-confirm-no")
        pg.wait_for_timeout(250)
        check(not shown(pg, "#st-confirm"), "“No” left the question on screen")
        check(shown(pg, "#st-editor"), "“No” closed the editor — it should keep editing")
        check(pg.input_value("#st-phone") == "01204 000000",
              "“No” threw away what had been typed; it is not an undo")
        check(pg.evaluate("window.__saves.length") == before,
              "saying No still wrote the record")

        #  A CHANGE WITHDRAWS THE QUESTION, or the strip names a save that is no
        #  longer the one that would happen.
        pg.click("#st-save")
        pg.wait_for_timeout(250)
        check(shown(pg, "#st-confirm"), "the question did not come back up")
        pg.fill("#st-phone", "01204 111111")
        pg.wait_for_timeout(250)
        check(not shown(pg, "#st-confirm"),
              "the record was changed while the question was up and the question "
              "stayed — it now describes a save that is not the one that would happen")

    # =====================================================================
    #  6. YES WRITES ONCE — AND THE RECORD BEHIND THE EDITOR IS RE-READ
    # =====================================================================
    reads_before = len(pg.evaluate("window.__reads"))
    pg.click("#st-save")
    pg.wait_for_timeout(250)
    if shown(pg, "#st-confirm"):
        pg.click("#st-confirm-yes")
    pg.wait_for_timeout(700)

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
    check(not shown(pg, "#st-editor"), "the editor stayed open after saving")
    check(not shown(pg, "#st-confirm"), "the question stayed up after saving")

    check(shown(pg, "#st-record"),
          "saving from inside a record closed the record. It should close the "
          "editor and leave the person on screen, because that is where they were.")
    check(len(pg.evaluate("window.__reads")) == reads_before + 1,
          "THE RECORD WAS NOT RE-READ AFTER THE SAVE. What is on screen is still "
          "what the record held before the change, sitting under the word “Saved” "
          "— which is how somebody concludes it did not work and types it again.")
    check("01204 111111" in pg.inner_text("#st-rec-grid"),
          "the record still shows the old number after saving a new one: %r"
          % text(pg, "#st-rec-grid")[:160])
    #  And the list half stayed away throughout — re-reading the list must not
    #  bring the "side not set" group back over the top of the record.
    for sel in LIST_HALF:
        check(not shown(pg, sel),
              "%s came back on screen when the list was re-read after a save, "
              "over the top of the record being read" % sel)

    # =====================================================================
    #  7. REMOVING SOMEBODY ASKS, ARCHIVES, AND DELETES NOTHING
    #
    #  Asked for: "when removing any record from the madrasah database it should
    #  get archived, where someone is able to go into the archive and restore if
    #  needed, you keep that record for same amount as a pupil."
    # =====================================================================
    check(shown(pg, "#st-rec-remove"),
          "there is no way to remove somebody from their own record")
    check(not shown(pg, "#st-rec-confirm"),
          "the remove question is up before anybody pressed remove")

    pg.click("#st-rec-remove")
    pg.wait_for_timeout(300)
    asked_rm = shown(pg, "#st-rec-confirm")
    check(asked_rm, "“Remove this person” did not ask anything")
    rq = text(pg, "#st-rec-confirm-q").lower()
    check("fatima" in rq, "the remove question does not name the person: %r" % rq)
    check("archive" in rq,
          "the remove question does not say the record goes to the archive, so it "
          "is answered as though it were a delete: %r" % rq)
    check("restore" in rq or "put them back" in rq or "can be restored" in rq,
          "the remove question does not say the record can come back: %r" % rq)
    check("three years" in rq,
          "the remove question does not say how long the record is kept, which is "
          "the same three years a pupil's record is kept: %r" % rq)
    check(pg.evaluate("window.__archives.length") == 0,
          "THE RECORD WAS ARCHIVED WHILE THE QUESTION WAS STILL ON SCREEN.")

    if asked_rm:
        pg.click("#st-rec-no")
        pg.wait_for_timeout(250)
        check(not shown(pg, "#st-rec-confirm"), "“No, go back” left the question up")
        check(shown(pg, "#st-record"), "“No, go back” closed the record as well")
        check(pg.evaluate("window.__archives.length") == 0, "saying No still archived")

        pg.click("#st-rec-remove")
        pg.wait_for_timeout(250)
        pg.fill("#st-rec-reason", "Left in July")
        pg.click("#st-rec-yes")
        pg.wait_for_timeout(700)

        arc = pg.evaluate("window.__archives")
        check(len(arc) == 1, "expected exactly one archive call, got %d" % len(arc))
        if arc:
            check(arc[0].get("p_id") == "s1",
                  "the archive call named the wrong person: %r" % arc[0])
            check(arc[0].get("p_reason") == "Left in July",
                  "the reason typed in was not passed on: %r" % arc[0])
        #  NOT A DELETE. The screen must never call one.
        check("delete_madrasah_staff" not in open("portal/staff/app.js",
                                                  encoding="utf-8").read(),
              "the staff screen still has a path that deletes a person outright")

        check(not shown(pg, "#st-record"),
              "the record stayed open after the person was archived")
        check(shown(pg, "#st-list-sisters"), "the list did not come back after archiving")
        ok = text(pg, "#st-ok").lower()
        check("archive" in ok,
              "nothing on screen says where the record went: %r" % ok)

    # =====================================================================
    #  8. ADDING SOMEBODY NEW DOES NOT ASK
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
    #  9. THE TWO SIDES LOOK DIFFERENT — MEASURED
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
    #  10. NO RECORD NAMES THE OLD SYSTEM, AND WHAT IT SAID STILL ARRIVES
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
    #  11. THE SQL  (static)
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
        if re.match(r"^0[5-9][0-9]_.*\.sql$", name):
            sql += open(os.path.join("db", name), encoding="utf-8").read()

    for fn in ("madrasah_staff_list", "save_madrasah_staff",
               "madrasah_staff_one", "archive_madrasah_staff"):
        m = re.search(r"create or replace function public\.%s\s*\(" % fn, sql)
        check(m, "no migration in db/ contains the text of %s(). 053 wrote "
                 "“see the migration history for the full text” instead of the "
                 "function, which is exactly why a column went missing without "
                 "anybody being able to read the diff." % fn)

    def body_of(fn):
        i = sql.rfind("create or replace function public." + fn)
        if i < 0:
            return ""
        s = sql[i:]
        return s[:s.find("$fn$;") + 5] if "$fn$;" in s else s

    save_fn = body_of("save_madrasah_staff")
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

    list_fn = body_of("madrasah_staff_list")
    check("current_masjid()" in list_fn and "s.masjid_id = v_masjid" in list_fn,
          "madrasah_staff_list() is not scoped to a masjid — it returns every "
          "masjid's staff to any administrator")

    #  THE LIST RETURNS FLAGS. The address and the date of birth are the two
    #  fields that make this list a list of personal data rather than a staff
    #  rota, and forty rows do not need either to draw a mark.
    for flag in ("has_address", "has_phone", "has_email", "has_dob",
                 "has_hours", "days_a_week"):
        check(flag in list_fn,
              "madrasah_staff_list() does not return %s, so the marks on the rows "
              "have nothing to read" % flag)
    #  AND IT DOES NOT RETURN THE VALUES THEMSELVES.
    #
    #  A plain `"s.address" not in list_fn` cannot be used and was tried: the
    #  flag is BUILT from the column, so `coalesce(btrim(s.address), '') <> ''`
    #  contains that text and the check would pass on any function, broken or
    #  not — a check that cannot fail. What distinguishes a returned column from
    #  a column being read is that the returned one stands alone on its line in
    #  the select list, so that is what is looked for. Proved by adding
    #  `s.address,` to a copy of the function and watching this fail.
    sel = list_fn[:list_fn.find("from public.madrasah_staff s")]
    bare = [ln.strip() for ln in sel.splitlines()
            if not ln.strip().startswith("--")
            and re.match(r"^s\.(address|date_of_birth|work_times)\s*(,|$)", ln.strip())]
    check(not bare,
          "madrasah_staff_list() returns %r as a column. Every row of forty would "
          "carry it to the browser to draw a 24-pixel square — the flags exist so "
          "that an address leaves the database only when one person is opened."
          % bare)

    one_fn = body_of("madrasah_staff_one")
    check("current_masjid()" in one_fn and "masjid_id = v_masjid" in one_fn,
          "madrasah_staff_one() is not scoped to a masjid — a known id would read "
          "another masjid's staff record, and this is the call that returns the "
          "address and the date of birth")

    arc_fn = body_of("archive_madrasah_staff")
    check("insert into public.madrasah_archive" in arc_fn,
          "archive_madrasah_staff() does not write to the archive, so 'remove' is "
          "a delete wearing a different word")
    check(re.search(r"delete from public\.madrasah_staff", arc_fn),
          "archive_madrasah_staff() never takes the person off the staff list")
    check("to_jsonb" in arc_fn,
          "archive_madrasah_staff() does not keep the record itself, only a "
          "reference to it — there would be nothing to restore")

    b.close()

_report.reached_end = True
if fails:
    sys.exit(1)
