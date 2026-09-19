"""/portal/archive/ — what the madrasah removed, and putting it back.

18 September 2026. Written with the screen, not after it.

Asked for, in the masjid's own words:

    "when removing any record from the madrasah database it should get
     archived, where someone is able to go into the archive and restore if
     needed, you keep that record for same amount as a pupil."

WHAT THIS FILE GUARDS:

  1  THE SCREEN IS FOR ADMINISTRATORS. Every function behind it calls
     verified_admin() and refuses anybody else regardless, so this is a
     courtesy — but it is the right courtesy: the archive lists children's
     names beside the one button in the madrasah that destroys a record.

  2  A ROW SAYS WHAT WENT, WHO REMOVED IT, WHY, AND HOW LONG IS LEFT.
     The retention promise is worth nothing if the screen does not say it.
     Three years, and the date it happens, on every row.

  3  NEITHER VERB ACTS UNTIL IT IS ANSWERED, and the count of calls is what
     proves it. A screen that has not written and a screen that has written
     and not said so look identical.

  4  RESTORE AND DELETE ARE NOT THE SAME WEIGHT.
     Restore is reversible; delete for good is the only irreversible control in
     the whole madrasah. So delete carries a tick box that has to be ticked
     before Yes will do anything, and Yes is DISABLED until it is. A person who
     has pressed Yes on six restores does not read the seventh — that is the
     whole reason the two questions differ, and it is checked here rather than
     assumed from the stylesheet.

  5  THE TICK IS NOT ONLY THE DISABLED ATTRIBUTE. A disabled button is one line
     of script away from not being disabled. The handler checks the tick too,
     and this proves it by re-enabling the button from the console and pressing
     it — which is exactly what a determined mis-click cannot do but a bug can.

  6  A ROW THAT CANNOT GO BACK DOES NOT OFFER A BUTTON THAT FAILS.
     madrasah_archive_list() works out can_restore in Postgres; the screen has
     to honour it, or somebody presses Put back and gets an error about a
     unique violation.

  7  REMOVING A CLASS ARCHIVES IT. The Classes screen used to call
     delete_madrasah_class(). Static check, on the file.

  8  THE SQL. Restore re-links only what still exists, and delete-for-good's
     audit row does not record the name — that is the function an erasure
     request is answered with, and writing the name into the audit would leave
     behind the very thing somebody asked to have erased.

Nothing here reaches Supabase.

Run:  python3 _test/archive_test.py
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
PAGE = "http://127.0.0.1:%d/portal/archive/" % httpd.server_address[1]

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


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


#  One of each kind, plus one that cannot be restored because something with
#  that reference is already back on the list. The days_left figures are the
#  three the screen words differently: nearly three years, a fortnight, and
#  overdue.
ROWS = [
    {"id": "a1", "kind": "staff", "label": "Apa Fatima Adam", "reason": "Left in July",
     "archived_at": "2026-09-18T14:05:00+00:00", "by": "A Person",
     "purges_on": "2029-09-18", "days_left": 1095, "can_restore": True},
    {"id": "a2", "kind": "class", "label": "Girls Year 4", "reason": None,
     "archived_at": "2026-09-01T17:30:00+00:00", "by": "A Person",
     "purges_on": "2029-09-01", "days_left": 14, "can_restore": True},
    {"id": "a3", "kind": "pupil", "label": "A Child", "reason": "Moved away",
     "archived_at": "2023-09-20T09:00:00+00:00", "by": None,
     "purges_on": "2026-09-20", "days_left": 2, "can_restore": False},
]


def stub(roles):
    return """
(function(){
  var ROLES = %s, ROWS = %s;
  window.__restores = []; window.__deletes = [];
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
      if (name === 'madrasah_archive_list') return Promise.resolve({data:ROWS, error:null});
      if (name === 'restore_madrasah_record') {
        window.__restores.push(args && args.p_id);
        ROWS = ROWS.filter(function(r){ return r.id !== (args && args.p_id); });
        return Promise.resolve({data:{restored:'ok'}, error:null});
      }
      if (name === 'delete_archived_record') {
        window.__deletes.push(args && args.p_id);
        ROWS = ROWS.filter(function(r){ return r.id !== (args && args.p_id); });
        return Promise.resolve({data:{deleted:'ok'}, error:null});
      }
      return Promise.resolve({data:{}, error:null});
    }
  };
  Object.defineProperty(window, 'supabase',
    {value:{createClient:function(){return client;}}, writable:false, configurable:false});
})();
""" % (json.dumps(roles), json.dumps(ROWS))


def open_as(b, roles, w=1400, h=1400):
    pg = b.new_page(viewport={"width": w, "height": h})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.add_init_script(stub(roles))
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1300)
    return pg, errs


def text(pg, sel):
    n = pg.query_selector(sel)
    return re.sub(r"\s+", " ", n.inner_text()) if n else ""


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1. A TEACHER DOES NOT GET THIS SCREEN
    # =====================================================================
    pg, errs = open_as(b, ["madrasah"])
    check(not errs, "the page threw on load for a madrasah account: %r" % errs[:2])
    check(not pg.is_visible("#ar-panel"),
          "A TEACHER CAN OPEN THE ARCHIVE. It lists children's names beside the "
          "one button in the madrasah that destroys a record.")
    check(pg.is_visible("#app-noaccess"),
          "a madrasah account that cannot use this screen is shown nothing at all "
          "— neither the panel nor the reason")
    pg.close()

    # =====================================================================
    #  2. AN ADMINISTRATOR SEES EVERY ROW, WITH ALL FOUR FACTS ON IT
    # =====================================================================
    pg, errs = open_as(b, ["admin"])
    check(not errs, "the page threw on load: %r" % errs[:2])
    check(pg.is_visible("#ar-panel"), "the archive did not open for an administrator")

    rows = pg.eval_on_selector_all(
        "#ar-list .ar-row",
        "els => els.map(e => ({id: e.getAttribute('data-id'), t: e.innerText}))")
    check(len(rows) == 3, "expected three archived records, drew %d" % len(rows))
    by_id = {r["id"]: r["t"] for r in rows}

    #  WHAT IT WAS. "Child" and "Class" are four letters apart, so the kind is a
    #  word and never only a colour.
    #
    #  READ OFF THE CHIP, NOT OUT OF THE ROW'S TEXT. The first version of this
    #  check looked for "Child" anywhere in the row and passed on a row whose
    #  LABEL happened to be "A Child" — it would have passed with no kind drawn
    #  at all. And the chip is uppercased by the stylesheet, so the comparison
    #  is case-folded: asserting on "MEMBER OF STAFF" would make this test fail
    #  the day somebody changes text-transform, which is not what it is for.
    kinds = pg.eval_on_selector_all("#ar-list .ar-row", """els => Object.fromEntries(
        els.map(e => [e.getAttribute('data-id'),
                      (e.querySelector('.ar-kind')||{}).innerText || '']))""")
    check(kinds.get("a1", "").strip().lower() == "member of staff",
          "a staff record's kind chip reads %r" % kinds.get("a1"))
    check(kinds.get("a3", "").strip().lower() == "child",
          "a pupil record's kind chip reads %r" % kinds.get("a3"))
    check(kinds.get("a2", "").strip().lower() == "class",
          "a class record's kind chip reads %r" % kinds.get("a2"))

    #  WHO AND WHY.
    check("A Person" in by_id.get("a1", ""),
          "the row does not say who removed the record: %r" % by_id.get("a1"))
    check("Left in July" in by_id.get("a1", ""),
          "the reason typed in when it was removed is not on the row: %r"
          % by_id.get("a1"))
    check("18 September 2026" in by_id.get("a1", ""),
          "the row does not say when it was archived: %r" % by_id.get("a1"))
    #  The TIME as well as the date: two records archived four minutes apart on
    #  one afternoon are nearly always the same mistake, and a list that shows
    #  both as "18 September 2026" hides the one fact that says so.
    check(re.search(r"\d{2}:\d{2}", by_id.get("a1", "")),
          "the row gives the date but not the time: %r" % by_id.get("a1"))

    #  HOW LONG IS LEFT — and in the unit a person thinks in.
    check("3 years" in by_id.get("a1", ""),
          "a record with three years to run does not say so: %r" % by_id.get("a1"))
    check("18 September 2029" in by_id.get("a1", ""),
          "the row does not say the date the record will be deleted: %r"
          % by_id.get("a1"))
    check("14 days left" in by_id.get("a2", ""),
          "a record a fortnight from deletion does not say so in days — under a "
          "month is where the exact number starts to matter: %r" % by_id.get("a2"))

    #  AND THE ONE ABOUT TO GO IS THE ONE THAT STANDS OUT, measured rather than
    #  assumed. Quiet at three years; loud at a fortnight.
    loud = pg.evaluate("""() => {
      const c = s => { const n = document.querySelector(s);
        return n ? {color: getComputedStyle(n).color,
                    weight: getComputedStyle(n).fontWeight} : null; };
      return {far: c('.ar-row[data-id="a1"] .ar-left'),
              soon: c('.ar-row[data-id="a2"] .ar-left')};
    }""")
    check(loud["far"] and loud["soon"], "the time-left line did not render")
    if loud["far"] and loud["soon"]:
        check(loud["far"] != loud["soon"],
              "a record a fortnight from deletion looks exactly like one with "
              "three years to run: %r" % loud)

    #  AND THE PROMISE ITSELF IS ON THE SCREEN, not only in the migration.
    scope = text(pg, ".ar-scope").lower()
    check("three years" in scope, "the screen never says how long records are kept")
    check("not" in scope and "delete" in scope,
          "the screen does not say that removing something is not a deletion: %r" % scope)

    # =====================================================================
    #  3. A ROW THAT CANNOT GO BACK OFFERS NO BUTTON
    # =====================================================================
    puts = pg.eval_on_selector_all(
        '#ar-list button[data-do="restore"]', "els => els.map(e => e.getAttribute('data-id'))")
    check(sorted(puts) == ["a1", "a2"],
          "Put back is offered on the wrong rows. a3 is already back on the "
          "register, so pressing it would fail with a unique violation: %r" % puts)
    check("Already back on" in by_id.get("a3", ""),
          "a row that cannot be restored does not say why: %r" % by_id.get("a3"))
    dels = pg.eval_on_selector_all(
        '#ar-list button[data-do="delete"]', "els => els.map(e => e.getAttribute('data-id'))")
    check(sorted(dels) == ["a1", "a2", "a3"],
          "Delete for good is not offered on every row: %r" % dels)

    # =====================================================================
    #  4. PUT BACK ASKS FIRST, AND WRITES NOTHING UNTIL IT IS ANSWERED
    # =====================================================================
    check(not pg.is_visible("#ar-confirm"),
          "the question is on screen before anything has been pressed")

    pg.click('#ar-list button[data-do="restore"][data-id="a1"]')
    pg.wait_for_timeout(250)
    check(pg.is_visible("#ar-confirm"), "Put back did not ask anything")
    q = text(pg, "#ar-confirm-q")
    check("Fatima" in q, "the question does not name the record: %r" % q)
    check(pg.evaluate("window.__restores.length") == 0,
          "THE RECORD WAS PUT BACK WHILE THE QUESTION WAS STILL ON SCREEN.")
    #  Restore is reversible and the question says so, because a question that
    #  warns about everything is one nobody reads.
    check("undone" in q.lower() or "can be undone" in q.lower(),
          "the restore question does not say the action is reversible: %r" % q)
    #  NO TICK BOX ON THIS ONE.
    check(not pg.is_visible("#ar-understand-wrap"),
          "putting a record back demands the same ceremony as destroying one. "
          "Ceremony on a reversible action is how ceremony stops being read.")
    check(not pg.is_disabled("#ar-yes"),
          "the Yes button is disabled on a question with nothing to tick")

    pg.click("#ar-no")
    pg.wait_for_timeout(200)
    check(not pg.is_visible("#ar-confirm"), "“No, go back” left the question up")
    check(pg.evaluate("window.__restores.length") == 0, "saying No still put it back")

    pg.click('#ar-list button[data-do="restore"][data-id="a1"]')
    pg.wait_for_timeout(200)
    pg.click("#ar-yes")
    pg.wait_for_timeout(600)
    check(pg.evaluate("window.__restores") == ["a1"],
          "expected exactly one restore of a1, got %r" % pg.evaluate("window.__restores"))
    check(pg.evaluate("window.__deletes.length") == 0,
          "putting a record back also deleted something")
    left = pg.eval_on_selector_all("#ar-list .ar-row", "els => els.length")
    check(left == 2, "the restored record is still in the archive list (%d rows)" % left)
    check("back on" in text(pg, "#ar-ok").lower(),
          "nothing on screen says where the record went: %r" % text(pg, "#ar-ok"))

    # =====================================================================
    #  5. DELETE FOR GOOD IS A DIFFERENT QUESTION
    # =====================================================================
    pg.click('#ar-list button[data-do="delete"][data-id="a2"]')
    pg.wait_for_timeout(250)
    dq = text(pg, "#ar-confirm-q")
    check("Girls Year 4" in dq, "the delete question does not name the record: %r" % dq)
    check("cannot be undone" in dq.lower(),
          "the delete question does not say it cannot be undone: %r" % dq)
    check(pg.is_visible("#ar-understand-wrap"),
          "DELETE FOR GOOD ASKS EXACTLY WHAT RESTORE ASKS. It is the only control "
          "in the madrasah that destroys a record, and a Yes button is the same "
          "press somebody has already made six times today.")
    check(pg.is_disabled("#ar-yes"),
          "Yes is pressable before the tick box has been ticked")
    check(pg.evaluate("window.__deletes.length") == 0, "it deleted on being asked")

    #  THE TICK IS CHECKED BY THE HANDLER TOO, not only by the disabled
    #  attribute. A disabled button is a courtesy; it is one line of script away
    #  from not being disabled, and this is the irreversible one. Proved by
    #  taking the attribute off and pressing.
    pg.evaluate("document.getElementById('ar-yes').disabled = false")
    pg.click("#ar-yes")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__deletes.length") == 0,
          "THE RECORD WAS DESTROYED WITH THE TICK BOX UNTICKED. The disabled "
          "attribute was the only thing standing in the way, and it is one line "
          "of script — or one browser extension — away from not being there.")

    #  EVERYTHING BELOW NEEDS A TICK BOX THAT IS STILL THERE AND A RECORD THAT
    #  HAS NOT GONE. Without this gate, a build with no tick box — or one that
    #  destroyed the record on the press above — dies here on a four-second
    #  Playwright timeout hunting an invisible checkbox, and the real diagnosis
    #  is buried under the locator's stack trace. Proved by removing the tick
    #  check from the handler and reading the output both ways.
    if pg.is_visible("#ar-understand-wrap") and pg.evaluate("window.__deletes.length") == 0:
        #  Now tick it properly and finish.
        pg.check("#ar-understand")
        pg.wait_for_timeout(150)
        check(not pg.is_disabled("#ar-yes"), "ticking the box did not enable Yes")
        pg.click("#ar-yes")
        pg.wait_for_timeout(600)
        check(pg.evaluate("window.__deletes") == ["a2"],
              "expected exactly one delete of a2, got %r" % pg.evaluate("window.__deletes"))
        check(not pg.is_visible("#ar-confirm"), "the question stayed up after deleting")
        check("nothing left to put back" in text(pg, "#ar-ok").lower(),
              "the screen does not say the record is gone for good: %r" % text(pg, "#ar-ok"))

        #  AND THE TICK DOES NOT CARRY OVER TO THE NEXT QUESTION. A box left
        #  ticked from the last delete is the ceremony happening once for two
        #  records.
        pg.click('#ar-list button[data-do="delete"][data-id="a3"]')
        pg.wait_for_timeout(250)
        check(not pg.is_checked("#ar-understand"),
              "the tick box is still ticked from the last record, so the second "
              "deletion asks for nothing at all")
        check(pg.is_disabled("#ar-yes"), "Yes is pressable on a fresh delete question")
        pg.click("#ar-no")
        pg.wait_for_timeout(150)

    # =====================================================================
    #  6. THE FILTER AND THE SEARCH
    # =====================================================================
    pg.select_option("#ar-kind", "pupil")
    pg.wait_for_timeout(250)
    kinds = pg.eval_on_selector_all("#ar-list .ar-row",
                                    "els => els.map(e => e.getAttribute('data-id'))")
    check(kinds == ["a3"], "filtering to children showed %r" % kinds)
    check(not pg.is_visible("#ar-confirm"),
          "changing the filter left a question up about a row that is no longer "
          "on screen")
    pg.select_option("#ar-kind", "all")
    pg.fill("#ar-find", "moved")
    pg.wait_for_timeout(300)
    found = pg.eval_on_selector_all("#ar-list .ar-row",
                                    "els => els.map(e => e.getAttribute('data-id'))")
    check(found == ["a3"],
          "searching the reason text found %r — the reason is often the only "
          "thing somebody remembers" % found)

    pg.close()

    # =====================================================================
    #  7. REMOVING A CLASS ARCHIVES IT  (static)
    # =====================================================================
    cls = open("portal/classes/app.js", encoding="utf-8").read()
    check("archive_madrasah_class" in cls,
          "the Classes screen does not archive a class it removes")
    check(not re.search(r'rpc\(\s*"delete_madrasah_class"', cls),
          "the Classes screen still calls delete_madrasah_class(). Removing a "
          "class leaves thirty children in no class at all and takes the register "
          "that said which thirty with it.")
    staff = open("portal/staff/app.js", encoding="utf-8").read()
    check(not re.search(r'rpc\(\s*"delete_madrasah_staff"', staff),
          "the Staff screen still deletes a person outright")

    #  AND IT IS IN THE RAIL. An archive nobody can find is not an archive; the
    #  person who needs it has just made a mistake and is looking for the undo.
    nav = open("portal/nav.js", encoding="utf-8").read()
    check('href: "portal/archive/"' in nav,
          "the Archive is not in the madrasah rail, so the only way to reach it "
          "is to know the URL")
    m = re.search(r'\{\s*key:\s*"md-archive"[\s\S]{0,400}?\}', nav)
    check(m and "needs: ADMIN" in m.group(0),
          "the Archive row in the rail is not restricted to administrators: %r"
          % (m.group(0)[:200] if m else None))
    check(m and "soon: true" not in m.group(0),
          "the Archive is in the rail as “soon”, which renders as a span and "
          "cannot be pressed — the screen exists")

    # =====================================================================
    #  8. THE SQL  (static)
    # =====================================================================
    sql = ""
    for name in sorted(os.listdir("db")):
        if re.match(r"^0[5-9][0-9]_.*\.sql$", name):
            sql += open(os.path.join("db", name), encoding="utf-8").read()

    def body_of(fn):
        i = sql.rfind("create or replace function public." + fn)
        if i < 0:
            return ""
        s = sql[i:]
        return s[:s.find("$fn$;") + 5] if "$fn$;" in s else s

    for fn in ("madrasah_archive_list", "restore_madrasah_record",
               "delete_archived_record", "purge_madrasah_archive",
               "archive_madrasah_staff", "archive_madrasah_pupil",
               "archive_madrasah_class"):
        check(body_of(fn), "no migration in db/ contains the text of %s()" % fn)

    #  THE RETENTION FIGURE IS THE SAME IN BOTH PLACES, and it is three years.
    #  "3 years" would also match "30 years" and "13 years", which is how a
    #  check like this quietly stops meaning anything — found in the pupil purge
    #  and fixed there, so it is not repeated here.
    purge = body_of("purge_madrasah_archive")
    check(re.search(r"interval\s+'3 years'", purge),
          "the archive purge does not delete after three years: the retention "
          "promise on the screen and the one in the database disagree")
    lst = body_of("madrasah_archive_list")
    check(re.search(r"interval\s+'3 years'", lst),
          "madrasah_archive_list() works out the deletion date with a different "
          "interval from the purge, so the screen will drift from what happens")

    #  RESTORE RE-LINKS ONLY WHAT STILL EXISTS. A class archived after the
    #  teacher who taught it would otherwise fail the foreign key and take the
    #  whole restore down with it.
    rest = body_of("restore_madrasah_record")
    check(rest.count("where exists (select 1 from public.madrasah_classes c") >= 2,
          "restore_madrasah_record() re-links classes without checking they are "
          "still there")
    check("already back on the list" in rest or "already back on the register" in rest,
          "restoring a record that is already back does not say so — it fails on "
          "a primary key and the person reads a database error")

    #  THE ERASURE PATH DOES NOT RECORD THE NAME. This is the function an
    #  erasure request is answered with; writing the label into admin_audit
    #  would leave behind the very thing somebody asked to have erased.
    dele = body_of("delete_archived_record")
    #  THE INSERT ONLY, not everything after it. The first version of this ran
    #  to the end of the function and caught the RETURN — which hands the label
    #  straight back to the person who just pressed the button so the screen can
    #  say whose record went. That is in memory for one second; the audit row
    #  outlives the record by years. Confusing the two made the check fail on
    #  correct code, which is the other way a check stops being useful.
    i = dele.find("insert into public.admin_audit")
    audit = dele[i:dele.find(";", i) + 1] if i >= 0 else ""
    check(audit, "delete_archived_record() writes no audit row at all")
    check("a.label" not in audit,
          "delete_archived_record() writes the name of the deleted record into "
          "the audit trail. That is the one thing an erasure request asks to be "
          "rid of, and the audit row outlives the record.")
    check("'kind', a.kind" in audit,
          "the audit row for a permanent deletion does not say what kind of "
          "record went, so the trail records nothing useful either")

    b.close()

_report.reached_end = True
if fails:
    sys.exit(1)
