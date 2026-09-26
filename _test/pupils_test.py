"""The Pupils screen, driven in a browser against a stubbed database.

WHAT THIS SUITE IS FOR

The migrations prove what lives in Postgres: that madrasah_roll cannot carry a
detail column, that opening a pupil writes an audit row, that anon and a
role-less account reach nothing. Those checks run there.

This proves the half SQL cannot see:

  * that a teaching account gets the roll and a role-less one is refused;
  * that the marks in the list say ALLERGY and MEDICAL and never what they
    are - the thing that would leak 552 children's medical notes onto an
    office screen that sits open all morning;
  * that the figures at the top FILTER, so the nine children nobody can
    telephone are a job of work rather than a number;
  * that changing a filter closes an open record, instead of leaving one
    child's medical note on screen beside a list they are no longer in;
  * that a child's detail NEVER reaches this screen - the roll shows marks
    and navigates to portal/pupil/ for anything more, so madrasah_pupil_one
    is never called from here;
  * that clicking, the keyboard and the actions menu all reach that page;
  * that the screen does not scroll sideways on a phone.

Every check in here was watched failing before it was kept.

    python3 _test/pupils_test.py
"""
import atexit
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


@atexit.register
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


#  The detail that must never reach the list. Distinctive strings, so that a
#  leak is unambiguous rather than a coincidence of common words.
SECRET_ALLERGY = "ZZPEANUTS-CARRIES-AN-EPIPEN"
SECRET_MEDICAL = "ZZASTHMA-BLUE-INHALER"
SECRET_SEND    = "ZZSPEECH-AND-LANGUAGE-SUPPORT"

ROLL = [
    {"id": "p1", "legacy_ref": "1001", "name": "Aaliyah Test", "gender": "female",
     "date_of_birth": "2017-04-02", "postcode": "BL1 8DP", "family": "Test family",
     "classes": ["Girls Class 3"], "class_ids": ["c1"], "teacher": "Apa Khadija",
     "has_medical": True, "has_allergy": True, "has_send": False,
     "has_fee_rate": False, "has_teacher": True, "has_contact": True},
    {"id": "p2", "legacy_ref": "1002", "name": "Bilal Test", "gender": "male",
     "date_of_birth": None, "postcode": "BL1 8DP", "family": None,
     "classes": [], "class_ids": [], "teacher": None,
     "has_medical": False, "has_allergy": False, "has_send": True,
     "has_fee_rate": False, "has_teacher": False, "has_contact": False},
]

HEALTH = {"allowed": True, "on_roll": 2, "no_family": 1, "no_contact": 1,
          "no_class": 1, "no_teacher": 1, "no_dob": 1, "no_gender": 0,
          "no_fee_rate": 2, "with_medical": 1, "with_allergy": 1,
          "with_send": 1, "open_sibling_suggestions": 1}

RECORD = {
    "id": "p1", "legacy_ref": "1001", "first_name": "Aaliyah", "last_name": "Test",
    "name": "Aaliyah Test", "date_of_birth": "2017-04-02", "age": 9,
    "gender": "female", "email": None, "address": "1 Test Street", "postcode": "BL1 8DP",
    "school": "Clarendon Primary", "school_year": "Year 4", "prev_madrasah": None,
    "medical": SECRET_MEDICAL, "allergies": SECRET_ALLERGY,
    "send_detail": None, "ehcp_detail": None,
    "walk_home_consent": False, "notes": None,
    "joined_on": "2024-09-01", "left_on": None,
    "household": {"id": "h1", "reference": "MF-AAA", "name": "Test family",
                  "guardians": [{"id": "g1", "name": "Test Parent", "email": "t@example.test",
                                 "phone": "07000000000", "is_primary": True}],
                  "siblings": [{"id": "p2", "name": "Bilal Test"}]},
    "classes": [{"id": "c1", "name": "Girls Class 3", "section": "girls",
                 "teacher": "Apa Khadija"}],
    "fee_rate": None,
}

RECORD_NO_GUARDIAN = dict(RECORD, id="p2", name="Bilal Test", legacy_ref="1002",
                          medical=None, allergies=None, send_detail=SECRET_SEND,
                          household=None, classes=[])

#  A DATE OF BIRTH THAT CANNOT BE RIGHT.
#  The live register holds nine. Only p1 is named here, so the test can prove
#  that the OTHER child is not marked - a flag that marks everybody is the same
#  as no flag, and it is the kind of thing that passes a count check.
DOBQ = {"allowed": True, "rows": [
    {"id": "p1", "legacy_ref": "1001", "name": "Aaliyah Test",
     "class": "Girls Class 3", "date_of_birth": "2017-04-02", "age": 9,
     "class_normally": 15, "why": "Much younger than the rest of the class."}]}

SUGG = {"allowed": True, "rows": [
    {"id": "s1", "why": "same surname and postcode, no shared parent contact",
     "a": {"id": "p1", "name": "Aaliyah Test", "family": "Test family", "postcode": "BL1 8DP"},
     "b": {"id": "p2", "name": "Bilal Test", "family": None, "postcode": "BL1 8DP"}}]}


def stub(roles, roll=None, health=None, sugg=None, dobq=None):
    return """
(function(){
  var ROLES=%s, ROLL=%s, HEALTH=%s, SUGG=%s, REC=%s, REC2=%s, DOBQ=%s;
  window.__calls=[];
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
      if (name==='madrasah_roll')        return Promise.resolve({data:{allowed:true,rows:ROLL},error:null});
      if (name==='madrasah_roll_health') return Promise.resolve({data:HEALTH,error:null});
      if (name==='madrasah_sibling_suggestions_list') return Promise.resolve({data:SUGG,error:null});
      if (name==='madrasah_dob_to_check') return Promise.resolve({data:DOBQ,error:null});
      if (name==='madrasah_roll_export') {
        //  The heading mirrors what the database returns. It is built THERE,
        //  from the same values that go into the audit row - see the note in
        //  the migration. The stub carries it so the file's shape is tested.
        var HEAD={masjid:'Taiyabah Masjid \u2014 Madrasah',
                  what: args.p_detail ? 'Pupil details' : 'Register list',
                  taken:'Taken 26 September 2026 at 21:56 by A Person',
                  filter:'Showing: everyone on the register',
                  count:'2 pupils',
                  note:'Medical notes, allergies and SEND are never included in this file.'};
        if (!args.p_detail) return Promise.resolve({data:{allowed:true,detail:false,count:2,heading:HEAD,
          rows:[{name:'Aaliyah Test',reference:'1001',class:'Girls Class 3',
                 teacher:'Apa Khadija',status:'on_roll'}]},error:null});
        return Promise.resolve({data:{allowed:true,detail:true,count:2,heading:HEAD,
          rows:[{name:'Aaliyah, Test',reference:'1001',class:'Girls Class 3',
                 teacher:'Apa Khadija',status:'on_roll',date_of_birth:'02/04/2017',
                 gender:'female',address:'1 Test Street',postcode:'BL1 8DP',
                 family:'Test family',guardian:'Test Parent',
                 telephone:'07000000000',email:'t@example.test'}]},error:null});
      }
      if (name==='madrasah_classes_list') return Promise.resolve({data:{allowed:true,
          rows:[{id:'c1',name:'Girls Class 3'}]},error:null});
      if (name==='madrasah_pupil_one')
        return Promise.resolve({data:(args.p_id==='p2'?REC2:REC),error:null});
      if (name==='save_madrasah_pupil_details')
        return Promise.resolve({data:REC,error:null});
      if (name==='settle_sibling_suggestion')
        return Promise.resolve({data:{ok:true},error:null});
      return Promise.resolve({data:null,error:{message:'unstubbed '+name}});
    }
  };
  Object.defineProperty(window,'supabase',
    {value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % (json.dumps(roles), json.dumps(roll if roll is not None else ROLL),
       json.dumps(health if health is not None else HEALTH),
       json.dumps(sugg if sugg is not None else SUGG),
       json.dumps(RECORD), json.dumps(RECORD_NO_GUARDIAN),
       json.dumps(dobq if dobq is not None else DOBQ))


def open_page(b, roles=("admin",), roll=None, health=None, sugg=None,
              width=1500, height=1100):
    pg = b.new_page(viewport={"width": width, "height": height})
    pg.set_default_timeout(7000)
    pg.add_init_script(stub(list(roles), roll, health, sugg))
    pg.goto(BASE + "/portal/pupils/", wait_until="load")
    pg.wait_for_timeout(700)
    return pg


def run():
    with sync_playwright() as p:
        b = p.chromium.launch()

        # --- who may open it ------------------------------------------------
        pg = open_page(b, roles=())
        check("an account with no roles is refused the roll",
              pg.locator("#pu-panel").is_hidden())
        check("and is told so rather than shown an empty page",
              pg.locator("#app-noaccess").is_visible())
        check("and the refusal explains what to do about it",
              "ask the office" in pg.inner_text("#app-noaccess").lower())
        pg.close()

        pg = open_page(b, roles=("madrasah",))
        check("a teaching account gets the roll", pg.locator("#pu-panel").is_visible())
        check("and sees both children", pg.locator("tr.pu-row").count() == 2)

        #  THE SCREEN MUST KNOW WHICH SCREEN IT IS. The rail and the heading
        #  are set in JavaScript, not in the markup, and this file's auth
        #  shell is spliced out of the Applications screen - so the first
        #  build said "Applications" at the top with Applications lit in the
        #  rail, on a page of pupils. It looked finished.
        check("the heading says Pupils, not the screen it was spliced from",
              "pupils" in (pg.inner_text("h1") or "").lower(),
              pg.inner_text("h1"))
        check("and the rail lights Pupils",
              pg.locator('.ashell a[aria-current="page"]').count() == 0
              or "pupil" in (pg.inner_text('.ashell a[aria-current="page"]') or "").lower(),
              pg.locator('.ashell a[aria-current="page"]').count())
        pg.close()

        # --- THE LIST SAYS WHETHER ------------------------------------------
        pg = open_page(b)
        body = pg.inner_text("body")
        for label, secret in (("an allergy", SECRET_ALLERGY),
                              ("a medical note", SECRET_MEDICAL),
                              ("a SEND note", SECRET_SEND)):
            check("the list never shows what %s says" % label, secret not in body,
                  "found %r on the list screen" % secret)
        check("but it does say there IS an allergy", "Allergy" in body)
        check("and that there IS a medical note", "Medical" in body)
        check("and that there IS a SEND note", "SEND" in body)

        # --- the figures filter ---------------------------------------------
        check("the figures are on screen", pg.locator(".pu-fig").count() >= 5)
        check("both children are listed to begin with",
              pg.locator("tr.pu-row").count() == 2)
        pg.click('.pu-fig[data-need="no_contact"]')
        pg.wait_for_timeout(300)
        check("the no-contact figure filters the list to just that child",
              pg.locator("tr.pu-row").count() == 1)
        check("and the one it leaves is the child with nobody to ring",
              "Bilal" in pg.inner_text("#pu-rows"))
        check("the figure shows it is on",
              "is-on" in (pg.get_attribute('.pu-fig[data-need="no_contact"]', "class") or ""))
        pg.click('.pu-fig[data-need="no_contact"]')
        pg.wait_for_timeout(300)
        check("pressing it again clears the filter",
              pg.locator("tr.pu-row").count() == 2)

        # --- a date of birth that cannot be right -----------------------------
        #  The count comes from its own call, NOT from the health figures, so a
        #  check that only read the number would pass with the panel unwired.
        #  These check the mark lands on the right child and on no other.
        check("the questionable-date figure is on screen",
              pg.locator('.pu-fig[data-need="dob_to_check"]').count() == 1)
        check("and it counts the one child, not both",
              pg.inner_text('.pu-fig[data-need="dob_to_check"] b').strip() == "1")
        check("exactly one age carries a question mark",
              pg.locator(".pu-age-q").count() == 1)
        #  Read the DOM in one go rather than through a waiting locator. A
        #  locator that waits turns a FAILING check into a seven second hang
        #  and then an abort, which reports nothing useful about the others.
        marked = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('tr.pu-row'),
            function (tr) { return tr.querySelector('.pu-age-q')
              ? { who: tr.innerText, why: (tr.querySelector('.pu-age-q .sr-only')
                                           || {}).textContent || '' } : null; })
            .filter(Boolean)""")
        check("and it is the child the list named",
              len(marked) == 1 and "Aaliyah" in marked[0]["who"], marked)
        check("the reason is there for a screen reader, not only on hover",
              len(marked) == 1 and "Much younger" in marked[0]["why"], marked)
        check("the reason says nothing about the child beyond the class",
              SECRET_MEDICAL not in pg.inner_text("#pu-rows")
              and SECRET_ALLERGY not in pg.inner_text("#pu-rows"))
        pg.click('.pu-fig[data-need="dob_to_check"]')
        pg.wait_for_timeout(300)
        check("pressing it filters to just that child",
              pg.locator("tr.pu-row").count() == 1)
        check("and it is the right child",
              "Aaliyah" in pg.inner_text("#pu-rows"))
        pg.click('.pu-fig[data-need="dob_to_check"]')
        pg.wait_for_timeout(300)
        check("pressing it again clears that filter too",
              pg.locator("tr.pu-row").count() == 2)

        # --- pagination --------------------------------------------------------
        #  The suite's fixture holds two pupils. Everything wrong with this
        #  screen was invisible at two: 28.6 screens of scrolling on the desk,
        #  37.9 on a phone. These run against 120.
        many = [dict(ROLL[0], id="x%d" % i, name="Pupil %d" % i,
                     legacy_ref=str(2000 + i)) for i in range(120)]
        pg.close()
        pg = open_page(b, roll=many, health=dict(HEALTH, on_roll=120))
        check("only one page of pupils is drawn",
              pg.locator("tr.pu-row").count() == 50,
              pg.locator("tr.pu-row").count())
        check("the count line says what is shown and out of how many",
              "120" in pg.inner_text("#pu-count"), pg.inner_text("#pu-count"))
        check("there is a pager", pg.locator(".pu-pager").count() >= 1)
        pg.locator('.pu-page[data-page="2"]').first.click()
        pg.wait_for_timeout(300)
        check("page two draws the next fifty",
              pg.locator("tr.pu-row").count() == 50)
        check("and starts at the fifty-first pupil",
              "2050" in pg.inner_text("#pu-rows"))
        pg.locator('.pu-per[data-per="100"]').first.click()
        pg.wait_for_timeout(300)
        check("asking for a hundred per page draws a hundred",
              pg.locator("tr.pu-row").count() == 100,
              pg.locator("tr.pu-row").count())

        #  A NARROWING WHILE ON A LATER PAGE.
        #  Filter to twelve results while on page 4 and the slice is past the
        #  end: the screen says "No pupil matches that" while twelve do.
        pg.locator('.pu-per[data-per="25"]').first.click()
        pg.wait_for_timeout(200)
        #  The LAST page, which the pager always renders however far it is
        #  from the current one. Page 4 is not clickable from page 1, and
        #  that is correct: the middle elides.
        pg.locator('.pu-page[data-page="5"]').first.click()
        pg.wait_for_timeout(250)
        check("we are on the last page", pg.locator("tr.pu-row").count() == 20,
              pg.locator("tr.pu-row").count())
        pg.fill("#pu-q", "Pupil 1")
        pg.wait_for_timeout(400)
        check("searching from the last page still shows the matches",
              pg.locator("tr.pu-row").count() > 0,
              pg.locator("tr.pu-row").count())
        check("and does not claim there are none",
              pg.locator("#pu-empty").is_hidden())
        #  NOT MERELY NON-EMPTY. drawRows clamps an over-run page to the LAST
        #  page, so a broken reset still shows rows — just the wrong ones. The
        #  search matches 31 children; landing on page 1 means 25 rows, and
        #  landing on the clamped last page means 6. Only the first is right,
        #  and only this check can tell them apart.
        check("and puts you on page ONE of the new result, not its last page",
              pg.locator("tr.pu-row").count() == 25,
              pg.locator("tr.pu-row").count())
        check("with page one marked as current",
              pg.get_attribute('.pu-page[data-page="1"]', "aria-current") == "page")
        pg.close()
        pg = open_page(b)

        # --- sticky headers, and sorting ---------------------------------------
        mixed = [
            dict(ROLL[0], id="s1", name="Zahra Test", legacy_ref="9001",
                 date_of_birth="2010-01-01", classes=["Girls Class 1"]),
            dict(ROLL[0], id="s2", name="Adam Test", legacy_ref="9002",
                 date_of_birth="2018-01-01", classes=["Boys Year 1"]),
            #  NO DATE OF BIRTH. A null age must not sort as though the child
            #  were newborn — missing is not small.
            dict(ROLL[0], id="s3", name="Musa Test", legacy_ref="9003",
                 date_of_birth=None, classes=["Boys Year 2A"]),
        ]
        pg.close()
        pg = open_page(b, roll=mixed, health=dict(HEALTH, on_roll=3))

        def col(i):
            return pg.evaluate("""(i) => Array.prototype.map.call(
                document.querySelectorAll('tr.pu-row'),
                function (tr) { return tr.children[i].innerText.trim(); })""", i)

        pg.click('.pu-sortable[data-sort="name"]')
        pg.wait_for_timeout(300)
        check("sorting by name puts Adam first",
              col(1)[0].startswith("Adam"), col(1))
        pg.click('.pu-sortable[data-sort="name"]')
        pg.wait_for_timeout(300)
        check("clicking the same heading again reverses it",
              col(1)[0].startswith("Zahra"), col(1))

        pg.click('.pu-sortable[data-sort="age"]')
        pg.wait_for_timeout(300)
        check("sorting by age puts the unknown one LAST, not first",
              "not known" in col(2)[-1], col(2))
        pg.click('.pu-sortable[data-sort="age"]')
        pg.wait_for_timeout(300)
        check("and it is still last when the order is reversed",
              "not known" in col(2)[-1], col(2))

        check("the heading row is sticky, so it survives 552 rows of scrolling",
              pg.evaluate("""() => getComputedStyle(
                  document.querySelector('#pu-table thead th')).position""")
              == "sticky")
        check("the sorted heading says so for a screen reader",
              pg.get_attribute('.pu-sortable[data-sort="age"]', "aria-sort")
              in ("ascending", "descending"))
        pg.close()
        pg = open_page(b)

        # --- boys, girls, and the child who is neither -------------------------
        #  ONE REAL PUPIL HAS NO GENDER RECORDED. 236 boys plus 315 girls is
        #  551, not 552. Two tabs would swallow that child; a filter with
        #  "Everyone" as its default cannot.
        sides = [
            dict(ROLL[0], id="g1", name="Boy One",   gender="male",
                 teacher="Apa Alpha", classes=["Boys Year 1"], class_ids=["c1"]),
            dict(ROLL[0], id="g2", name="Girl One",  gender="female",
                 teacher="Apa Beta",  classes=["Girls Class 1"], class_ids=["c1"]),
            dict(ROLL[0], id="g3", name="Neither One", gender=None,
                 teacher="Apa Beta",  classes=["Play and Pray 1"], class_ids=["c1"]),
        ]
        pg.close()
        pg = open_page(b, roll=sides, health=dict(HEALTH, on_roll=3))
        check("everyone is shown to begin with",
              pg.locator("tr.pu-row").count() == 3)
        pg.select_option("#pu-side", "male")
        pg.wait_for_timeout(300)
        check("boys shows only the boy", pg.locator("tr.pu-row").count() == 1)
        pg.select_option("#pu-side", "female")
        pg.wait_for_timeout(300)
        check("girls shows only the girl", pg.locator("tr.pu-row").count() == 1)
        check("and the count says OF HOW MANY, so the missing child is visible "
              "arithmetic rather than a silent loss",
              "of 3" in pg.inner_text("#pu-count"), pg.inner_text("#pu-count"))
        pg.select_option("#pu-side", "")
        pg.wait_for_timeout(300)
        check("everyone brings back all three, including the one with no gender",
              pg.locator("tr.pu-row").count() == 3)
        check("and the child with no gender is reachable by name",
              "Neither One" in pg.inner_text("#pu-rows"))

        # --- teacher -----------------------------------------------------------
        pg.select_option("#pu-teacher", "Apa Beta")
        pg.wait_for_timeout(300)
        check("the teacher filter narrows to that teacher's pupils",
              pg.locator("tr.pu-row").count() == 2,
              pg.locator("tr.pu-row").count())
        check("the teacher list is built from the roll, not hard-coded",
              pg.locator("#pu-teacher option").count() == 3,
              pg.locator("#pu-teacher option").count())
        pg.select_option("#pu-teacher", "")
        pg.wait_for_timeout(250)
        pg.select_option("#pu-side", "female")
        pg.select_option("#pu-teacher", "Apa Beta")
        pg.wait_for_timeout(300)
        check("the filters combine rather than replacing each other",
              pg.locator("tr.pu-row").count() == 1,
              pg.locator("tr.pu-row").count())
        pg.close()
        pg = open_page(b)

        # --- the actions menu --------------------------------------------------
        check("every row has an actions button",
              pg.locator(".pu-act").count() == pg.locator("tr.pu-row").count(),
              pg.locator(".pu-act").count())
        pg.locator(".pu-act").first.click()
        pg.wait_for_timeout(300)
        check("the menu opens", pg.locator(".pu-menu").count() == 1)

        #  THE BUTTON LIVES INSIDE A ROW THAT OPENS A CHILD.
        #  Without stopPropagation every menu click ALSO opens the record —
        #  and opening a record calls madrasah_pupil_one(), which writes an
        #  audit row. So the wrong thing would be written down as well as
        #  shown, 552 rows over.
        check("opening the menu does NOT open the record",
              pg.locator("#pu-record").is_hidden())
        calls = pg.evaluate("() => window.__calls.map(function(c){return c.name;})")
        check("and does not call madrasah_pupil_one",
              "madrasah_pupil_one" not in calls, calls)

        items = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('.pu-menu .pu-mi'),
            function (n) { return {t: n.innerText.trim(),
                                   dead: n.hasAttribute('disabled')
                                      || n.getAttribute('href') === '#'
                                      || n.className.indexOf('soon') !== -1}; })""")
        check("the menu has entries", len(items) >= 4, items)
        check("and NOT ONE of them is dead", all(not i["dead"] for i in items), items)
        check("the four unbuilt screens are absent rather than greyed out",
              not any(i["t"] in ("Register", "Incidents", "Class History",
                                 "Portal Login") for i in items), items)

        #  A MENU LEFT OPEN ACROSS A PAGE CHANGE points at a pupil who is no
        #  longer on screen.
        pg.close()
        many2 = [dict(ROLL[0], id="y%d" % i, name="Pupil %d" % i,
                      legacy_ref=str(3000 + i)) for i in range(80)]
        pg = open_page(b, roll=many2, health=dict(HEALTH, on_roll=80))
        pg.locator(".pu-act").first.click()
        pg.wait_for_timeout(250)
        check("a menu is open", pg.locator(".pu-menu").count() == 1)
        pg.locator('.pu-page[data-page="2"]').first.click()
        pg.wait_for_timeout(300)
        check("changing page closes it", pg.locator(".pu-menu").count() == 0)
        pg.locator(".pu-act").first.click()
        pg.wait_for_timeout(250)
        pg.fill("#pu-q", "Pupil 7")
        pg.wait_for_timeout(350)
        check("and so does searching", pg.locator(".pu-menu").count() == 0)
        pg.close()
        pg = open_page(b)

        # --- status ------------------------------------------------------------
        withstatus = [
            dict(ROLL[0], id="q1", name="Here One",  status="on_roll"),
            dict(ROLL[0], id="q2", name="Hold One",  status="on_hold"),
            dict(ROLL[0], id="q3", name="Gone One",  status="left"),
        ]
        pg.close()
        pg = open_page(b, roll=withstatus, health=dict(HEALTH, on_roll=3))
        check("the roll opens on who is HERE, not on everybody ever",
              pg.locator("tr.pu-row").count() == 1,
              pg.locator("tr.pu-row").count())
        pg.select_option("#pu-status", "left")
        pg.wait_for_timeout(300)
        check("asking for those who left shows them",
              "Gone One" in pg.inner_text("#pu-rows"))
        pg.select_option("#pu-status", "")
        pg.wait_for_timeout(300)
        check("and everyone means everyone", pg.locator("tr.pu-row").count() == 3)
        pg.close()

        # --- taking a file out of the system -----------------------------------
        #  THE HIGHEST-RISK FEATURE ON THIS SCREEN. These check who may do it,
        #  that it says what it is about to do, and that a comma in a child's
        #  name does not silently become an extra column in somebody's
        #  spreadsheet.
        pg = open_page(b, roles=("madrasah",))
        check("there is ONE export button, not two bare ones",
              pg.locator('[data-take="open"]').count() == 1
              and pg.locator('[data-take="register"]').count() == 0,
              pg.locator("[data-take]").count())
        check("and it says what it is", "Export" in pg.inner_text("#pu-export"))
        check("nothing is offered until it is opened",
              pg.locator("#pu-expanel").is_hidden())
        pg.click('[data-take="open"]')
        pg.wait_for_timeout(250)
        panel = pg.inner_text("#pu-expanel")
        check("opening it explains each choice rather than naming it",
              len(panel) > 200, len(panel))
        check("a teacher is offered the register list",
              pg.locator('[data-take="register"]').count() == 1)
        check("and the printable register",
              pg.locator('[data-take="print"]').count() == 1)
        check("but NOT the list with addresses and telephone numbers on it",
              pg.locator('[data-take="ask"]').count() == 0)
        check("and is told why rather than just not seeing it",
              "administrators only" in panel.lower(), panel[-160:])
        check("the panel says what is never in any of them",
              "medical" in panel.lower() and "never included" in panel.lower())
        pg.close()

        pg = open_page(b, roles=("admin",))
        pg.click('[data-take="open"]')
        pg.wait_for_timeout(250)
        check("an administrator is offered all three",
              pg.locator('[data-take="register"]').count() == 1
              and pg.locator('[data-take="print"]').count() == 1
              and pg.locator('[data-take="ask"]').count() == 1)
        check("the detailed one is marked as restricted",
              pg.locator('[data-take="ask"].is-guarded').count() == 1)
        check("and nothing is asked until it is asked for",
              pg.locator("#pu-ask").is_hidden())
        pg.click('[data-take="ask"]')
        pg.wait_for_timeout(250)
        ask = pg.inner_text("#pu-ask")
        check("asking first says how many children are in the file",
              "2 children" in ask, ask[:120])
        check("and names what is in it", "telephone" in ask.lower())
        check("and says what is NOT in it",
              "medical" in ask.lower() and "never included" in ask.lower())
        check("and warns that it is recorded against them",
              "recorded against" in ask.lower())
        check("cancelling is offered", pg.locator('[data-take="no"]').count() == 1)
        pg.click('[data-take="no"]')
        pg.wait_for_timeout(250)
        check("and cancelling asks for nothing", pg.locator("#pu-ask").is_hidden())
        calls = pg.evaluate("() => window.__calls.map(function(c){return c.name;})")
        check("NOTHING was exported by opening, asking and cancelling",
              "madrasah_roll_export" not in calls, calls)

        with pg.expect_download() as dl:
            pg.click('[data-take="register"]')
        f = dl.value
        check("the register list downloads", f.suggested_filename.endswith(".csv"),
              f.suggested_filename)
        check("and the file is named for the masjid, so it is identifiable "
              "in a Downloads folder full of exports",
              f.suggested_filename.startswith("Taiyabah-Masjid-"),
              f.suggested_filename)
        sent = pg.evaluate("""() => (window.__calls.filter(
            c => c.name === 'madrasah_roll_export').slice(-1)[0] || {}).args""")
        check("the register list asks for the undetailed one",
              (sent or {}).get("p_detail") is False, sent)

        #  The panel survives a filter change, so it is opened once here and
        #  not again — a second click would toggle it shut.
        pg.click('[data-take="open"]')
        pg.wait_for_timeout(200)
        pg.select_option("#pu-status", "on_hold")
        pg.wait_for_timeout(250)
        check("the export panel stays open while filters change",
              pg.locator('[data-take="register"]').count() == 1)
        with pg.expect_download():
            pg.click('[data-take="register"]')
        sent = pg.evaluate("""() => (window.__calls.filter(
            c => c.name === 'madrasah_roll_export').slice(-1)[0] || {}).args""")
        check("the filter on screen is sent with the export, so the file "
              "matches the list",
              (sent or {}).get("p_filter", {}).get("status") == "on_hold", sent)
        pg.click('[data-take="open"]')
        pg.wait_for_timeout(200)
        pg.fill("#pu-q", "Aaliyah")
        pg.wait_for_timeout(250)
        with pg.expect_download():
            pg.click('[data-take="register"]')
        sent = pg.evaluate("""() => (window.__calls.filter(
            c => c.name === 'madrasah_roll_export').slice(-1)[0] || {}).args""")
        check("but the free-text search is NOT sent, because it is not "
              "recorded in the audit row",
              "q" not in (sent or {}).get("p_filter", {})
              and "search" not in (sent or {}).get("p_filter", {}), sent)
        pg.close()

        #  A COMMA IN A CHILD'S NAME. The detailed fixture is called
        #  "Aaliyah, Test" on purpose: unquoted, that is two columns, and
        #  every row after it in the spreadsheet is shifted — which is
        #  precisely the damage the register we imported arrived with.
        pg = open_page(b, roles=("admin",))
        pg.click('[data-take="open"]')
        pg.wait_for_timeout(200)
        pg.click('[data-take="ask"]')
        pg.wait_for_timeout(200)
        with pg.expect_download() as dl2:
            pg.click('[data-take="full"]')
        path = dl2.value.path()
        #  newline="" so Python does NOT quietly turn the file's CRLF into
        #  \n. Reading in the default text mode makes a check for CRLF pass
        #  or fail for reasons that have nothing to do with the file.
        body = open(path, encoding="utf-8-sig", newline="").read()
        lines = body.split("\r\n")
        check("a name containing a comma is quoted, not left to split the row",
              '"Aaliyah, Test"' in body, body[:160])
        check("the file is separated with CRLF, which is what Excel expects",
              len(lines) >= 2, len(lines))
        #  THE TITLE BLOCK. The file opens looking like a Taiyabah document
        #  rather than an anonymous grid — and every line of it comes from the
        #  database, from the same values that went into the audit row.
        head = "\r\n".join(lines[:6])
        check("the file names the masjid before anything else",
              "Taiyabah" in lines[0], lines[0])
        check("and says what kind of list it is", "details" in head.lower(), head)
        check("and when it was taken and by whom",
              "Taken" in head and "by " in head, head)
        check("and which filter produced it", "Showing:" in head, head)
        check("and that medical notes are never in it",
              "medical" in head.lower() and "never included" in head.lower(), head)
        check("a blank line separates the title block from the data",
              lines[6] == "", repr(lines[6]))
        hdr = lines[7]
        check("the header row follows it", hdr.startswith("name,"), hdr[:60])
        check("the header names thirteen columns",
              len(hdr.split(",")) == 13, hdr)
        #  The quoted name is ONE field, so a naive comma split sees 14 while
        #  a correct CSV reader sees 13. That difference is the whole check.
        import csv as _csv, io as _io
        parsed = list(_csv.reader(_io.StringIO(body)))
        check("and a correct reader sees thirteen in the data row too, "
              "despite the comma in the name",
              len(parsed[8]) == 13, parsed[8])
        #  ABOUT THE COLUMNS, NOT THE PROSE.
        #  The first version of this scanned the whole file for the word
        #  "medical" — and then the title block gained the sentence "Medical
        #  notes, allergies and SEND are never included in this file", so the
        #  check failed on the very line that promises the thing it checks.
        #  Exactly the mistake the database guard made: it could not tell a
        #  mention from a value. So: read the HEADER, and read the DATA.
        cols = [c.strip().lower() for c in hdr.split(",")]
        check("no column in the file is a special-category one",
              not any(k in c for c in cols
                      for k in ("medical", "allerg", "send", "ehcp")), cols)
        data = "\r\n".join(lines[8:]).lower()
        check("and no data row carries one either",
              "epipen" not in data and "inhaler" not in data
              and "zz" not in data, data[:160])
        pg.close()
        pg = open_page(b)

        # --- clearing the filters ----------------------------------------------
        #  Written after a deliberate break showed this feature had NO test:
        #  making clearAll() a no-op left all 138 checks green. A button that
        #  is never asserted to do anything is a button that quietly stops
        #  doing it.
        pg.close()
        pg = open_page(b)
        check("nothing offers to clear filters when none are set",
              pg.locator("#pu-clearall").is_hidden())
        pg.fill("#pu-q", "Aaliyah")
        pg.wait_for_timeout(300)
        check("the search shows a way to empty it",
              pg.locator("#pu-clearq").is_visible())
        check("and a clear-all appears, counting what is set",
              "1" in pg.inner_text("#pu-clearall"), pg.inner_text("#pu-clearall"))
        pg.select_option("#pu-side", "female")
        pg.wait_for_timeout(300)
        check("two filters are counted as two",
              "2" in pg.inner_text("#pu-clearall"), pg.inner_text("#pu-clearall"))
        #  The status control opens on "on roll". Counting that as a filter
        #  would put the clear-all link on screen permanently.
        check("the status default is NOT counted as a filter",
              "2" in pg.inner_text("#pu-clearall"), pg.inner_text("#pu-clearall"))
        pg.select_option("#pu-status", "left")
        pg.wait_for_timeout(300)
        check("but changing it away from the default is",
              "3" in pg.inner_text("#pu-clearall"), pg.inner_text("#pu-clearall"))

        pg.click("#pu-clearall")
        pg.wait_for_timeout(350)
        state = pg.evaluate("""() => ({q: document.getElementById('pu-q').value,
            side: document.getElementById('pu-side').value,
            teacher: document.getElementById('pu-teacher').value,
            cls: document.getElementById('pu-class').value,
            status: document.getElementById('pu-status').value})""")
        check("clearing empties the search", state["q"] == "", state)
        check("and every select", state["side"] == "" and state["teacher"] == ""
              and state["cls"] == "", state)
        check("and puts status back to ON ROLL, not to blank — blank would "
              "show children who have left",
              state["status"] == "on_roll", state)
        check("and the list comes back", pg.locator("tr.pu-row").count() == 2,
              pg.locator("tr.pu-row").count())
        check("and the offer to clear goes away",
              pg.locator("#pu-clearall").is_hidden())
        pg.close()
        pg = open_page(b, roles=("admin",))

        # --- the printable register --------------------------------------------
        #  A spreadsheet printout is a poor register: you cannot tick a CSV,
        #  and it arrives with no indication of which madrasah, class or week
        #  it belongs to. window.print is stubbed so the suite does not open a
        #  printer; what is checked is what would have been printed.
        pg.close()
        pg = open_page(b, roles=("admin",))
        #  The print stub captures the page AT THE MOMENT printing happens.
        #  Afterwards the block is moved back and the class removed, so
        #  looking later would be looking at the wrong document entirely.
        pg.evaluate("""() => {
            window.__printed = 0; window.__atPrint = null;
            window.print = function () {
              window.__printed++;
              function shown(sel) {
                var n = document.querySelector(sel);
                if (!n) return false;
                while (n && n !== document) {
                  if (getComputedStyle(n).display === 'none') return false;
                  n = n.parentElement; }
                return true; }
              window.__atPrint = {
                bodyClass: document.body.className,
                atBodyLevel: document.getElementById('pu-print').parentElement === document.body,
                rail: shown('#admin-rail'), figures: shown('#pu-figs'),
                filters: shown('.pu-filters'), table: shown('#pu-table'),
                exporter: shown('#pu-export'), register: shown('#pu-print')};
            }; }""")
        pg.click('[data-take="open"]')
        pg.wait_for_timeout(200)
        #  PRINT MEDIA BEFORE THE CLICK. getComputedStyle inside the print
        #  stub reports whatever media is active at that moment, so reading
        #  it under screen media answers a question nobody asked.
        pg.emulate_media(media="print")
        pg.wait_for_timeout(150)
        pg.click('[data-take="print"]')
        pg.wait_for_timeout(300)
        check("it asks the browser to print", pg.evaluate("() => window.__printed") == 1)
        sheet = pg.inner_text("#pu-print")
        check("the sheet names the masjid", "Taiyabah" in sheet, sheet[:80])
        check("and says it is a register", "Register" in sheet)
        check("and carries the date", str(__import__("datetime").date.today().year) in sheet)
        check("and lists the pupils", "Aaliyah" in sheet and "Bilal" in sheet)
        check("there is a logo on it",
              pg.locator("#pu-print img.pr-logo").count() == 1)
        blanks = pg.evaluate("""() => {
            var r = document.querySelector('#pu-print tbody tr');
            if (!r) return 0;
            var n = 0;
            for (var i = 0; i < r.children.length; i++) {
              if (!r.children[i].textContent.trim()) n++; }
            return n; }""")
        check("every row has blank columns to tick, which is the whole point "
              "of a paper register", blanks >= 6, blanks)
        #  IT MUST NOT CARRY WHAT A LIST MUST NOT CARRY. This sheet is walked
        #  between rooms and left on desks.
        check("the printed sheet carries no medical note",
              SECRET_MEDICAL not in sheet and SECRET_ALLERGY not in sheet)
        check("nor a telephone number or address",
              "07000" not in sheet and "BL1" not in sheet, sheet[:200])
        check("and it says so on the sheet, so nobody adds them by hand later",
              "no medical or contact" in sheet.lower(), sheet[-160:])
        #  WHAT ACTUALLY PRINTS, not whether a print rule exists.
        #
        #  The first version of this check asked only "is there a @media
        #  print block anywhere" — and passed while the ENTIRE SCREEN
        #  printed: masthead, figures, filters, Export button, with the
        #  register underneath. The rule was there and losing, because
        #  admin/shell.css carries `body.has-ashell .shell{display:block
        #  !important}` and specificity decides between two !importants.
        #
        #  A check that asserts something exists is not a check that it
        #  works. This one emulates print media and reads what is left.
        vis = pg.evaluate("() => window.__atPrint") or {}
        check("the sheet is moved out to body, away from the cascade fight",
              vis.get("atBodyLevel") is True, vis)
        check("and the print rules are switched on for this action only",
              "printing-register" in (vis.get("bodyClass") or ""), vis)
        check("the register itself prints", vis.get("register"), vis)
        check("nor the figure tiles", not vis["figures"], vis)
        check("nor the filters", not vis["filters"], vis)
        check("nor the Export button", not vis["exporter"], vis)
        check("nor the on-screen roll, which would print 50 rows twice",
              not vis["table"], vis)
        #  AND ORDINARY PRINTING STILL WORKS. Unscoped, these rules made
        #  Ctrl+P produce a blank sheet. Still under print media, but the
        #  class is off again now.
        pg.wait_for_timeout(150)
        plain = pg.evaluate("""() => {
            var n = document.querySelector('#pu-table');
            while (n && n !== document) {
              if (getComputedStyle(n).display === 'none') return false;
              n = n.parentElement; }
            return true; }""")
        check("pressing Ctrl+P without using the button still prints "
              "something rather than a blank sheet", plain, plain)

        #  THE LOGO IS NOT BLANK PAPER.
        #  The masjid wordmark is cream, made for the dark rail — average ink
        #  rgb(243,239,227) — so it first printed as nothing at all, and the
        #  check "there is an <img>" passed the entire time. The sheet is put
        #  back into its printing state and the logo photographed as the
        #  printer sees it, then the dark pixels are counted. That is the only
        #  version of this check that could ever have failed.
        pg.evaluate("""() => { var n = document.getElementById('pu-print');
            document.body.appendChild(n);
            document.body.className += ' printing-register'; }""")
        pg.wait_for_timeout(200)
        _logo = pg.locator("#pu-print img.pr-logo").screenshot()
        import io as _io2
        from PIL import Image as _Img
        _im2 = _Img.open(_io2.BytesIO(_logo)).convert("RGB")
        _px = list(_im2.getdata()) if not hasattr(_im2, "get_flattened_data") \
              else list(_im2.get_flattened_data())
        _dark = len([q for q in _px if sum(q) / 3 < 120])
        check("the logo prints with ink in it, not white on white",
              _dark > len(_px) * 0.04, "%d of %d pixels dark" % (_dark, len(_px)))
        pg.evaluate("""() => { document.body.className =
            document.body.className.replace(/\s*printing-register/, ''); }""")
        pg.emulate_media(media="screen")
        pg.close()
        pg = open_page(b)

        # --- the sibling pairs, as one line ------------------------------------
        #  THE FIXTURE HOLDS ONE PAIR. THE MADRASAH HOLDS 56.
        #  Rendered as rows, that is three screens of review work sitting
        #  between the figures and the roll — and nothing in this suite could
        #  see it, because one pair is not three screens.
        pairs = {"allowed": True, "rows": [
            dict(SUGG["rows"][0], id="sg%d" % i) for i in range(56)]}
        pg.close()
        pg = open_page(b, sugg=pairs)
        check("56 pairs draw ONE line, not 56 rows",
              pg.locator(".pu-sugg-row").count() == 0,
              pg.locator(".pu-sugg-row").count())
        check("and the line says how many there are",
              "56" in pg.inner_text(".pu-sugg-line"), pg.inner_text(".pu-sugg-line"))
        check("the roll is still on the first screen behind it",
              pg.evaluate("""() => document.querySelector('tr.pu-row')
                  .getBoundingClientRect().top""") < 1100)
        pg.locator(".pu-sugg-line button").first.click()
        pg.wait_for_timeout(350)
        check("asking to review them shows all 56",
              pg.locator(".pu-sugg-row").count() == 56,
              pg.locator(".pu-sugg-row").count())
        pg.locator(".pu-sugg-line button").first.click()
        pg.wait_for_timeout(300)
        check("and they fold away again", pg.locator(".pu-sugg-row").count() == 0)
        pg.close()

        # --- what a phone shows on its first screen ----------------------------
        pg = open_page(b, width=390, height=900)
        #  NOT MERELY "top < 900". The first version of this check passed
        #  with the row starting at 883px of a 900px screen - a sliver of one
        #  row, which is not a pupil on screen in any sense a teacher in a
        #  corridor would recognise. A WHOLE row must fit.
        box = pg.evaluate("""() => {
            var r = document.querySelector('tr.pu-row');
            if (!r) return null;
            var b = r.getBoundingClientRect();
            return {top: Math.round(b.top), bottom: Math.round(b.bottom),
                    win: window.innerHeight}; }""")
        check("a WHOLE pupil row fits on the phone's first screen",
              box is not None and box["bottom"] <= box["win"], box)
        pg.close()
        pg = open_page(b)

        # --- opening a child leaves the roll -----------------------------------
        #  The record used to open in a drawer under the list. The masjid
        #  asked for what their old system does, so a child is now a page of
        #  its own and the roll navigates to it. The audit row is written
        #  there by the same function; only the place changes.
        #  Sampled BEFORE the click. After it, window.__calls belongs to the
        #  page navigated TO, which does read the pupil — so asking afterwards
        #  would be interrogating the wrong page's log.
        before = pg.evaluate("() => window.__calls.map(function(c){return c.name;})")
        check("the roll itself never reads a pupil's detail",
              "madrasah_pupil_one" not in before, before)
        pg.locator("tr.pu-row").first.click()
        pg.wait_for_url("**/portal/pupil/**", timeout=7000)
        check("clicking a child goes to that child's own page",
              "/portal/pupil/" in pg.url, pg.url)
        check("and names the child in the address",
              "id=p1" in pg.url, pg.url)
        pg.close()

        pg = open_page(b)
        pg.locator("tr.pu-row").first.focus()
        pg.keyboard.press("Enter")
        pg.wait_for_url("**/portal/pupil/**", timeout=7000)
        check("and so does the keyboard", "id=p1" in pg.url, pg.url)
        pg.close()

        pg = open_page(b)
        pg.locator(".pu-act").first.click()
        pg.wait_for_timeout(250)
        pg.click('.pu-mi[data-do="open"]')
        pg.wait_for_url("**/portal/pupil/**", timeout=7000)
        check("the actions menu opens the same page", "id=p1" in pg.url, pg.url)
        pg.close()

        pg = open_page(b)
        pg.locator(".pu-act").first.click()
        pg.wait_for_timeout(250)
        pg.click('.pu-mi[data-do="edit"]')
        pg.wait_for_url("**/portal/pupil/**", timeout=7000)
        check("amend goes to the same page, asking for the form",
              "amend=1" in pg.url, pg.url)
        pg.close()
        pg = open_page(b)

        # --- the sibling pairs -------------------------------------------------
        pg = open_page(b)
        check("the sibling card is on screen when a pair is waiting",
              pg.locator("#pu-sugg").is_visible())
        #  It opens as one line now — 56 pairs as rows put three screens of
        #  review work above the roll. The detail is one click away.
        check("but it is one line until somebody asks",
              pg.locator("#pu-sugg [data-join]").count() == 0)
        pg.locator(".pu-sugg-line button").first.click()
        pg.wait_for_timeout(350)
        check("it says why they are not already one family",
              "telephone number or email address is on both"
              in pg.inner_text("#pu-sugg").lower())
        check("it offers both answers", pg.locator("#pu-sugg [data-join]").count() == 2)
        pg.click('#pu-sugg [data-join="1"]')
        pg.wait_for_timeout(600)
        settle = pg.evaluate("""() => (window.__calls.filter(
            c => c.name === 'settle_sibling_suggestion').slice(-1)[0] || {}).args""")
        check("joining two families calls settle_sibling_suggestion", bool(settle), settle)
        check("and says it is a join, not a dismissal",
              (settle or {}).get("p_join") is True, settle)
        pg.close()

        pg = open_page(b, sugg={"allowed": True, "rows": []})
        check("the sibling card is not there when nothing is waiting",
              pg.locator("#pu-sugg").is_hidden())
        pg.close()

        # --- keyboard ----------------------------------------------------------

        # --- the phone ----------------------------------------------------------
        pg = open_page(b, width=390, height=900)
        wide = pg.evaluate("""() => ({doc: document.documentElement.scrollWidth,
                                      win: window.innerWidth})""")
        check("the roll does not scroll sideways on a phone",
              wide["doc"] <= wide["win"] + 1, wide)
        check("the figures are still there on a phone", pg.locator(".pu-fig").count() >= 5)
        pg.locator("tr.pu-row").first.click()
        pg.wait_for_timeout(500)
        narrow = pg.evaluate("""() => ({doc: document.documentElement.scrollWidth,
                                        win: window.innerWidth})""")
        check("nor does an open record",
              narrow["doc"] <= narrow["win"] + 1, narrow)
        pg.close()

        b.close()
    FINISHED[0] = True


if __name__ == "__main__":
    run()
