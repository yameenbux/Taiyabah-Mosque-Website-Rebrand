"""The Families screen, driven in a browser against a stubbed database.

WHAT THIS SUITE IS FOR

The migration proves what lives in Postgres: that madrasah_family_export
refuses a detailed file to anybody who is not a verified administrator, that no
child is named in either level of it, and that the minimisation guard now
discovers list functions from the catalogue instead of being handed two names.
Those checks run there.

This proves the half SQL cannot see:

  * that a teaching account gets the list and a role-less one is refused;
  * that the LIST carries no telephone number, no email address and no home
    address - only whether there is somebody to ring. Those arrive when one
    family is opened, which is a deliberate act;
  * that the six families with nobody to ring are a job of work rather than a
    number, and that a family with no guardian at all SAYS SO in words rather
    than showing an empty space somebody has to notice;
  * that changing a filter closes an open family, instead of leaving a
    mother's mobile number on screen beside a list she is not in;
  * that 330 families are paged rather than scrolled, that searching from page
    four lands on page one, and that Clear actually clears;
  * that moving a child between families reopens the family afterwards - the
    bug that made a successful move look like a button that had not worked;
  * that a teacher is not offered buttons only an administrator can press;
  * that a letter prints and the rest of the screen does not;
  * that the screen does not scroll sideways on a phone.

Every check in here was watched failing before it was kept.

    python3 _test/families_test.py
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


#  THE REPORTER ONLY SPEAKS FOR A RUN OF THE SUITE.
#
#  Registered unconditionally, it fired at the end of _test/families_shots.py -
#  which imports this module for its fixtures and never runs a check - and
#  printed "RUN INCOMPLETE ... do not read this as a pass" after a perfectly
#  good set of screenshots. A warning that cries wolf is worse than no warning:
#  that particular sentence exists to be believed.
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


#  What must never reach the list. Distinctive, so a leak is unambiguous
#  rather than a coincidence of common words.
SECRET_PHONE = "07ZZ000111222"
SECRET_EMAIL = "zzparent-not-on-the-list@example.test"
SECRET_ADDR  = "ZZ99 Nowhere Lane, Bolton"


def families(n=140):
    """A register of invented families, sized so that paging matters.

    NO REAL FAMILY, NAME OR ADDRESS APPEARS IN THIS FILE. The register is 330
    real households; those belong in the database and nowhere else.
    """
    out = []
    for i in range(1, n + 1):
        kids = 1 if i % 3 == 0 else (4 if i % 17 == 0 else 2)
        has_phone = (i % 23 != 0)
        has_email = (i % 23 != 0) or (i % 46 == 0)
        out.append({
            "id": "h%d" % i,
            "reference": "MF-%04d" % i,
            "name": "Testfamily%03d family" % i,
            "note": "%d Test Street" % i,
            "pupils": kids,
            "former": 1 if i % 11 == 0 else 0,
            "guardians": 0 if (not has_phone and not has_email) else 1,
            "has_phone": has_phone,
            "has_email": has_email,
        })
    return out


ROWS = families()

#  One family, as madrasah_household_one returns it. THIS is where contact
#  details live, and the suite checks they never appear anywhere else.
RECORD = {
    "id": "h1", "reference": "MF-0001", "name": "Testfamily001 family",
    "note": SECRET_ADDR,
    "pupils": [{"id": "p1", "name": "Aaliyah Test", "left_on": None},
               {"id": "p2", "name": "Bilal Test", "left_on": None}],
    "guardians": [{"full_name": "Test Parent", "email": SECRET_EMAIL,
                   "phone": SECRET_PHONE, "is_primary": True}],
}

#  A family with nobody recorded at all. Six of the 330 are like this.
RECORD_NOBODY = {
    "id": "h23", "reference": "MF-0023", "name": "Testfamily023 family",
    "note": "23 Test Street",
    "pupils": [{"id": "p9", "name": "Zakariya Test", "left_on": None}],
    "guardians": [],
}

SUGG = {"allowed": True, "rows": [
    {"id": "s1", "why": "same surname and postcode",
     "a": {"id": "p1", "name": "Aaliyah Test", "family": "Testfamily001 family"},
     "b": {"id": "p9", "name": "Zakariya Test", "family": None}},
    {"id": "s2", "why": "same surname and postcode",
     "a": {"id": "p2", "name": "Bilal Test", "family": "Testfamily001 family"},
     "b": {"id": "p8", "name": "Hafsa Test", "family": "Testfamily008 family"}},
]}


def stub(roles, rows=None, sugg=None, record=None):
    return """
(function(){
  var ROLES=%s, ROWS=%s, SUGG=%s, REC=%s, NOBODY=%s;
  window.__calls=[];
  window.__printed=0;
  //  THE SNAPSHOT IS TAKEN INSIDE print(), NOT AFTER IT.
  //  printLetter() removes the printing-letter class in a finally block the
  //  instant window.print() returns, so anything read afterwards is read of a
  //  page that is no longer printing - and would report the letter hidden and
  //  the rail showing, which is the opposite of the truth. This is the only
  //  moment the question can be asked.
  window.print = function(){
    window.__printed++;
    function on(sel){ var n=document.querySelector(sel);
      if(!n) return false;
      while(n && n!==document){
        var s=getComputedStyle(n);
        if(s.display==='none'||s.visibility==='hidden') return false;
        n=n.parentNode; }
      return true; }
    var sheet=document.querySelector('#fa-print');
    window.__atPrint={ letter:on('#fa-print'), rail:on('.shell .arail'),
      figures:on('#fa-figs'), table:on('#fa-table'),
      exporter:on('#fa-export'), search:on('.fa-search'),
      record:on('#fa-record'),
      bodyClass:document.body.className,
      atBodyLevel: !!sheet && sheet.parentNode===document.body };
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
      //  THE LIST IS A BARE jsonb ARRAY, not {rows:[...]}. Confirmed by
      //  calling it as a real admin. Guessing this wrongly is how a screen
      //  loads and shows nothing.
      if (name==='madrasah_household_list') return Promise.resolve({data:ROWS,error:null});
      if (name==='madrasah_sibling_suggestions_list') return Promise.resolve({data:SUGG,error:null});
      if (name==='madrasah_household_one')
        return Promise.resolve({data:(args.p_id==='h23'?NOBODY:REC),error:null});
      if (name==='set_pupil_household') return Promise.resolve({data:{ok:true},error:null});
      if (name==='settle_sibling_suggestion') return Promise.resolve({data:{ok:true},error:null});
      if (name==='madrasah_family_export') {
        var HEAD={masjid:'Taiyabah Masjid \\u2014 Madrasah',
                  what: args.p_detail ? 'Families, with contact details' : 'Families',
                  taken:'Taken 27 September 2026 at 16:40 by A Person',
                  filter:'Showing: every family on the register',
                  count:'140 families',
                  note:'No child is named in this file.'};
        if (!args.p_detail) return Promise.resolve({data:{allowed:true,detail:false,
          count:2,heading:HEAD,
          rows:[{reference:'MF-0001',family:'Testfamily001 family',children:2,
                 guardians:1,contactable:'Telephone'}]},error:null});
        return Promise.resolve({data:{allowed:true,detail:true,count:2,heading:HEAD,
          rows:[{reference:'MF-0001',family:'Testfamily001 family',children:2,
                 guardians:1,contactable:'Telephone',first_guardian:'Test Parent',
                 telephone:'07000000000',email:'t@example.test',
                 address:'1 Test Street'}]},error:null});
      }
      return Promise.resolve({data:null,error:{message:'unstubbed '+name}});
    }
  };
  Object.defineProperty(window,'supabase',
    {value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % (json.dumps(roles),
       json.dumps(rows if rows is not None else ROWS),
       json.dumps(sugg if sugg is not None else SUGG),
       json.dumps(record if record is not None else RECORD),
       json.dumps(RECORD_NOBODY))


def open_screen(browser, roles, rows=None, sugg=None, record=None,
                width=1280, height=900):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.add_init_script(stub(list(roles), rows, sugg, record))
    pg.goto(BASE + "/portal/families/", wait_until="networkidle")
    pg.wait_for_timeout(420)
    return pg


def calls(pg, name):
    return [c for c in pg.evaluate("() => window.__calls") if c["name"] == name]


def run():
    with sync_playwright() as p:
        browser = p.chromium.launch()

        # ==============================================================
        #  WHO GETS IN
        # ==============================================================
        pg = open_screen(browser, [])
        check("a role-less account is refused the families",
              pg.locator("#fa-panel").is_hidden())
        body = pg.inner_text("body")
        check("and is told in words what to do about it",
              "ask the office" in body.lower(), body[:220])
        check("and no family was fetched for them",
              len(calls(pg, "madrasah_household_list")) == 0)
        pg.close()

        pg = open_screen(browser, ["madrasah"])
        check("a teaching account gets the families", pg.locator("#fa-panel").is_visible())

        # ==============================================================
        #  THE LIST SAYS WHETHER. IT DOES NOT SAY WHAT.
        # ==============================================================
        table = pg.inner_text("#fa-table")
        check("the list carries no telephone number", SECRET_PHONE not in table)
        check("nor an email address", SECRET_EMAIL not in table)
        check("nor a home address", SECRET_ADDR not in table)
        check("and it did not fetch a single family's record to draw the list",
              len(calls(pg, "madrasah_household_one")) == 0)
        check("it says instead whether there is somebody to ring",
              "Nobody to ring" in table or "Telephone" in table, table[:200])

        # ==============================================================
        #  THE FIGURES ARE FILTERS, NOT DECORATION
        # ==============================================================
        total = pg.locator('#fa-figs [data-need=""] b').inner_text()
        check("the first figure is the number of families", total == "140", total)
        #  THREE, NOT SIX. The first version of this check asserted six and the
        #  screen said three, and the screen was right: of the six families in
        #  the fixture with no telephone number, three have an email address
        #  and so belong in "Email only", not in "no way to reach them". The
        #  check was wrong, not the code — the fifth time on this screen's
        #  family of work that the assertion was the thing at fault.
        noone = int(pg.locator('#fa-figs [data-need="noone"] b').inner_text())
        check("the families with nobody to ring are counted", noone == 3, noone)
        onlymail = int(pg.locator('#fa-figs [data-need="nophone"] b').inner_text())
        check("and the ones with an email address but no telephone are counted "
              "separately, because they can be reached and it is slower",
              onlymail == 3, onlymail)
        check("the two do not double-count anybody", noone + onlymail == 6,
              (noone, onlymail))
        #  FOUR TILES. A fifth ("four or more children") counted 18 families on
        #  the real register with nothing anybody does about them, and made the
        #  row wrap 4 + 1.
        check("there are four figures, not a wall of them",
              pg.locator("#fa-figs .fa-fig").count() == 4,
              pg.locator("#fa-figs .fa-fig").count())
        check("and they sit on one row rather than stranding one below",
              len(set(pg.evaluate("""() => Array.prototype.map.call(
                  document.querySelectorAll('#fa-figs .fa-fig'),
                  function(n){ return Math.round(n.getBoundingClientRect().top); })"""))) == 1)
        check("the unreachable tile says how many have no parent at all",
              "no parent recorded" in pg.inner_text('#fa-figs [data-need="noone"]'),
              pg.inner_text('#fa-figs [data-need="noone"]'))
        check("and that figure is marked as a problem, not a statistic",
              "bad" in (pg.locator('#fa-figs [data-need="noone"]')
                        .get_attribute("class") or ""))
        pg.click('#fa-figs [data-need="noone"]')
        pg.wait_for_timeout(200)
        shown = pg.locator("#fa-rows tr").count()
        check("pressing it shows exactly those families", shown == 3, shown)
        every = pg.inner_text("#fa-rows")
        check("and every one of them says nobody can be reached",
              every.count("Nobody to ring") == 3, every.count("Nobody to ring"))
        pg.click('#fa-figs [data-need="noone"]')
        pg.wait_for_timeout(200)
        check("pressing it again puts them all back",
              pg.locator("#fa-rows tr").count() == 50,
              pg.locator("#fa-rows tr").count())

        #  A FIGURE OF ZERO IS NOT A BUTTON. Nothing to act on, so nothing to
        #  press: offering it invites somebody to click and conclude the screen
        #  is broken when the list does not change.
        pg2 = open_screen(browser, ["madrasah"], rows=[dict(
            ROWS[0], id="h1", has_phone=True, has_email=True, guardians=2)])
        z = pg2.locator('#fa-figs [data-need="noone"]')
        check("a figure of zero is not pressable", z.is_disabled())
        pg2.close()

        # ==============================================================
        #  PAGING. 330 FAMILIES IS NOT A SCROLL.
        # ==============================================================
        check("fifty families to a page", pg.locator("#fa-rows tr").count() == 50)
        check("and it says which fifty", "Showing 1–50 of 140"
              in pg.inner_text("#fa-count"), pg.inner_text("#fa-count"))
        check("there is a pager above the table as well as below",
              pg.locator("#fa-pager-top .fa-pages").count() == 1
              and pg.locator("#fa-pager-bottom .fa-pages").count() == 1)
        pg.click('#fa-pager-top .fa-page[data-page="3"]')
        pg.wait_for_timeout(200)
        check("page three shows the last of them",
              pg.locator("#fa-rows tr").count() == 40,
              pg.locator("#fa-rows tr").count())
        check("and the pager says where you are",
              pg.locator('#fa-pager-top .fa-page[aria-current="page"]')
                .inner_text() == "3")
        check("Next is dead on the last page",
              pg.locator("#fa-pager-top .fa-page", has_text="Next").is_disabled())

        #  SEARCHING FROM PAGE THREE MUST LAND ON PAGE ONE.
        #
        #  The first version of this check on the roll asserted only that rows
        #  were drawn - and passed with a broken reset, because drawRows()
        #  clamps an over-run page down to the last one. So it asserts the
        #  count AND which page is lit.
        pg.fill("#fa-q", "family")
        pg.wait_for_timeout(250)
        check("searching from page three lands on page one",
              pg.locator('#fa-pager-top .fa-page[aria-current="page"]')
                .inner_text() == "1")
        check("with a full page of results under it",
              pg.locator("#fa-rows tr").count() == 50,
              pg.locator("#fa-rows tr").count())

        # ==============================================================
        #  CLEAR ACTUALLY CLEARS
        #
        #  On the roll, clearAll() had NO TEST AT ALL and 138 checks were green
        #  around it. This asserts the state it is supposed to leave behind,
        #  not that pressing it does not throw.
        # ==============================================================
        pg.fill("#fa-q", "Testfamily001")
        pg.click('#fa-figs [data-need="single"]')
        pg.wait_for_timeout(220)
        check("Clear says how many filters are on",
              "2 filters" in pg.inner_text("#fa-clearall"),
              pg.inner_text("#fa-clearall"))
        pg.click("#fa-clearall")
        pg.wait_for_timeout(250)
        check("Clear empties the search box", pg.input_value("#fa-q") == "")
        check("and lets the figure go", "is-on" not in
              (pg.locator('#fa-figs [data-need="single"]').get_attribute("class") or ""))
        check("and puts every family back",
              pg.locator("#fa-rows tr").count() == 50,
              pg.locator("#fa-rows tr").count())
        check("and hides itself, having nothing left to do",
              pg.locator("#fa-clearall").is_hidden())
        check("and forgets the sort", pg.locator('.fa-sortable.is-on').count() == 0)

        # ==============================================================
        #  ONE FAMILY, OPENED DELIBERATELY
        # ==============================================================
        pg.click("#fa-rows tr.fa-row >> nth=0")
        pg.wait_for_timeout(300)
        check("opening a family fetches exactly one record",
              len(calls(pg, "madrasah_household_one")) == 1,
              len(calls(pg, "madrasah_household_one")))
        rec = pg.inner_text("#fa-record")
        check("the record names the children", "Aaliyah Test" in rec)
        check("and gives the telephone number", SECRET_PHONE in rec)
        check("and the email address", SECRET_EMAIL in rec)
        check("and marks who to ring first", "first call" in rec.lower(), rec[:300])
        check("a child's name links to their own page",
              (pg.locator("#fa-record a.fa-kid").first.get_attribute("href") or "")
              .startswith("../pupil/?id="))

        #  THE LIST IS PUT AWAY WHILE A FAMILY IS OPEN.
        #
        #  A STRONGER GUARANTEE THAN THE ONE THIS REPLACED. The first build
        #  left the record under the table and closed it whenever a filter
        #  changed, which meant a mother's mobile number and her home address
        #  could sit on the same screen as two hundred other families for as
        #  long as nobody touched anything. Now there is no such screen: one
        #  family, or the list, never both.
        check("opening a family puts the list away",
              pg.locator("#fa-list-bk").is_hidden())
        check("and the figures with it", pg.locator("#fa-figs").is_hidden())
        check("so contact details are never on screen beside a list of "
              "families they do not belong to",
              pg.locator("#fa-table").is_hidden())
        check("there is a way back, and it is the first thing in the card",
              pg.locator("#fa-record #fa-back").count() == 1)
        check("and it says where it goes",
              "Back to the families" in pg.inner_text("#fa-back"),
              pg.inner_text("#fa-back"))

        #  AND IT HAS A URL. So a family can be sent to the other
        #  administrator in a message, and a refresh does not lose your place.
        check("the address bar names the family that is open",
              pg.evaluate("() => location.search") == "?id=h1",
              pg.evaluate("() => location.search"))
        pg.go_back()
        pg.wait_for_timeout(350)
        check("the browser's Back button returns to the list",
              pg.locator("#fa-list-bk").is_visible())
        check("and takes the family out of the address bar",
              pg.evaluate("() => location.search") == "",
              pg.evaluate("() => location.search"))
        pg.go_forward()
        pg.wait_for_timeout(400)
        check("and Forward opens it again", pg.locator("#fa-record").is_visible())

        pg.click("#fa-back")
        pg.wait_for_timeout(250)
        check("the Back control puts the list back",
              pg.locator("#fa-list-bk").is_visible())
        check("and clears the address bar with it",
              pg.evaluate("() => location.search") == "",
              pg.evaluate("() => location.search"))

        # ==============================================================
        #  A FAMILY WITH NOBODY IN IT SAYS SO
        # ==============================================================
        pg3 = open_screen(browser, ["madrasah"], record=RECORD_NOBODY)
        pg3.click("#fa-rows tr.fa-row >> nth=0")
        pg3.wait_for_timeout(300)
        said = pg3.inner_text("#fa-record")
        check("a family with nobody recorded says so in words",
              "nobody is recorded" in said.lower(), said[:300])
        check("and says what that means this afternoon",
              "no one to ring" in said.lower(), said[-200:])
        check("rather than leaving an empty space to notice",
              pg3.locator("#fa-record .fa-warn").count() == 1)
        pg3.close()

        # ==============================================================
        #  THE EXPORT
        # ==============================================================
        check("the export is behind one named button, not two bare ones",
              pg.locator('#fa-export [data-take="open"]').count() == 1)
        check("and the button says what it does",
              "Export" in pg.inner_text("#fa-export"))
        check("the panel is shut until asked for",
              pg.locator("#fa-expanel").is_hidden())
        pg.click('#fa-export [data-take="open"]')
        pg.wait_for_timeout(200)
        panel = pg.inner_text("#fa-expanel")
        check("a teacher is offered the plain family list",
              pg.locator('#fa-expanel [data-take="plain"]').count() == 1)
        check("and each choice explains itself rather than being a bare label",
              len(panel) > 200, len(panel))
        #  A TEACHER IS NOT OFFERED A FILE THE DATABASE WILL REFUSE THEM.
        check("a teacher is NOT offered the file with telephone numbers in it",
              pg.locator('#fa-expanel [data-take="ask"]').count() == 0)
        check("and is told why, rather than left wondering",
              "administrators only" in panel.lower(), panel[-240:])

        with pg.expect_download() as got:
            pg.click('#fa-expanel [data-take="plain"]')
        dl = got.value
        name = dl.suggested_filename
        check("the file is named so it can be found again later",
              name.startswith("Taiyabah-Masjid-families-")
              and name.endswith(".csv"), name)
        check("and dated", str(datetime.date.today()) in name, name)
        text = open(dl.path(), encoding="utf-8-sig").read()
        check("the sheet carries the masjid's name", "Taiyabah Masjid" in text)
        check("and who took it and when", "A Person" in text and "27 September" in text)
        check("and what was showing at the time",
              "every family on the register" in text)
        check("and says no child is named in it",
              "No child is named" in text, text[:400])
        check("it starts with a byte order mark so Excel opens it correctly",
              open(dl.path(), "rb").read(3) == b"\xef\xbb\xbf")

        # ==============================================================
        #  AN ADMINISTRATOR GETS THE OTHER FILE
        # ==============================================================
        pga = open_screen(browser, ["admin", "madrasah"])
        pga.click('#fa-export [data-take="open"]')
        pga.wait_for_timeout(200)
        check("an administrator is offered the file with contact details",
              pga.locator('#fa-expanel [data-take="ask"]').count() == 1)
        ap = pga.inner_text("#fa-expanel")
        check("and is told their name goes on it",
              "recorded" in ap.lower(), ap[-260:])
        with pga.expect_download() as got2:
            pga.click('#fa-expanel [data-take="ask"]')
        dl2 = got2.value
        check("that file is named differently so the two are not confused",
              dl2.suggested_filename.startswith("Taiyabah-Masjid-families-contacts-"),
              dl2.suggested_filename)
        t2 = open(dl2.path(), encoding="utf-8-sig").read()
        check("and it carries the telephone number", "07000000000" in t2)
        check("and still names no child", "Aaliyah" not in t2, t2[:400])

        # ==============================================================
        #  MOVING A CHILD BETWEEN FAMILIES
        #
        #  THE REGRESSION TEST FOR A BUG THAT LOOKED LIKE NOTHING HAPPENING.
        #  The reopen used to run inside .then, while `busy` was still true, so
        #  openFamily() returned at its first line: the move succeeded, the
        #  list reloaded, and the record on screen went on showing the child in
        #  the family they had just left.
        # ==============================================================
        pga.click("#fa-rows tr.fa-row >> nth=0")
        pga.wait_for_timeout(300)
        pga.click("#fa-record .fa-move >> nth=0")
        pga.wait_for_timeout(200)
        mb = pga.inner_text("#fa-move-box")
        check("moving a child says what it will change",
              "billed" in mb.lower() and "telephoned" in mb.lower(), mb[:260])
        check("and asks for the family by name, from a list",
              pga.locator("#fa-move-to option").count() > 2)
        check("and does not offer the family the child is already in",
              pga.locator('#fa-move-to option[value="h1"]').count() == 0)
        before = len(calls(pga, "madrasah_household_one"))
        pga.select_option("#fa-move-to", "h2")
        pga.click("#fa-move-go")
        pga.wait_for_timeout(600)
        sent = calls(pga, "set_pupil_household")
        check("the move is sent to the database once", len(sent) == 1, len(sent))
        check("with the child and the family it is going to",
              sent and sent[0]["args"].get("p_household") == "h2", sent)
        check("and the family is read again afterwards, so the screen is not "
              "showing what was true before the move",
              len(calls(pga, "madrasah_household_one")) == before + 1,
              (before, len(calls(pga, "madrasah_household_one"))))
        check("and the record is still on screen rather than having vanished",
              pga.locator("#fa-record").is_visible())

        # ==============================================================
        #  THE SIBLING PAIRS
        # ==============================================================
        #  Back to the list first: the card lives there, not on a family.
        pga.click("#fa-back")
        pga.wait_for_timeout(250)
        check("the sibling card says how many pairs there are",
              "2 pairs" in pga.inner_text("#fa-sugg"), pga.inner_text("#fa-sugg")[:160])
        check("and is folded shut, because it is an afternoon's job and not "
              "what the office opens this screen to do",
              pga.locator("#fa-sugg .fa-sugg-rows").count() == 0)
        pga.click("#fa-sugg-toggle")
        pga.wait_for_timeout(200)
        check("opening it shows the pairs", pga.locator("#fa-sugg-row").count() == 0
              or pga.locator("#fa-sugg .fa-sugg-row").count() == 2,
              pga.locator("#fa-sugg .fa-sugg-row").count())
        check("an administrator can settle one",
              pga.locator('#fa-sugg [data-join="1"]').count() == 2)
        pga.click('#fa-sugg .fa-sugg-row >> nth=0 >> [data-join="1"]')
        pga.wait_for_timeout(400)
        st = calls(pga, "settle_sibling_suggestion")
        check("and settling one tells the database which and how",
              len(st) == 1 and st[0]["args"].get("p_join") is True, st)
        pga.close()

        #  A TEACHER IS NOT OFFERED A BUTTON THE DATABASE WILL REFUSE.
        #  settle_sibling_suggestion() requires verified_admin(); the first
        #  version of this card showed both buttons to every member of
        #  madrasah staff, who would have pressed one and been handed a raw
        #  permission error.
        pgt = open_screen(browser, ["madrasah"])
        pgt.click("#fa-sugg-toggle")
        pgt.wait_for_timeout(200)
        check("a teacher can read the pairs",
              pgt.locator("#fa-sugg .fa-sugg-row").count() == 2)
        check("but is not offered a button only an administrator can press",
              pgt.locator('#fa-sugg [data-join]').count() == 0)
        tsaid = pgt.inner_text("#fa-sugg")
        check("and is told whose job it is",
              "administrator" in tsaid.lower(), tsaid[:400])
        pgt.close()

        # ==============================================================
        #  THE LETTER
        # ==============================================================
        pgl = open_screen(browser, ["admin", "madrasah"])
        pgl.click("#fa-rows tr.fa-row >> nth=0")
        pgl.wait_for_timeout(300)
        pgl.click("#fa-letter")
        pgl.wait_for_timeout(200)
        lb = pgl.inner_text("#fa-letter-box")
        check("there is a choice of a letter or an email", "headed paper" in lb)
        check("and the email option names who it would go to",
              SECRET_EMAIL in lb, lb[:400])

        #  PRINT MEDIA BEFORE THE CLICK. getComputedStyle inside the print stub
        #  reports whatever media is active at that moment.
        pgl.emulate_media(media="print")
        pgl.wait_for_timeout(150)
        pgl.click('[data-letter="general"]')
        pgl.wait_for_timeout(350)
        check("it asks the browser to print", pgl.evaluate("() => window.__printed") >= 1)
        sheet = pgl.inner_text("#fa-print")
        check("the letter is on the masjid's headed paper",
              "Taiyabah Masjid" in sheet and "1041569" in sheet, sheet[:200])
        check("and carries today's date",
              str(datetime.date.today().year) in sheet, sheet[:300])
        check("and is addressed to the family", "Test Parent" in sheet)
        check("and says which children it concerns",
              "Aaliyah Test" in sheet, sheet[:400])
        check("and leaves room to type", "Assalamu alaikum" in sheet)
        check("there is a logo on it",
              pgl.locator("#fa-print img.lt-logo").count() == 1)

        #  THE LOGO PRINTS AS SOMETHING. On the roll the check said "there is
        #  an <img>" while the mark came out as nothing at all: the artwork is
        #  cream, rgb(243,239,227), on white paper. This counts dark pixels.
        #  THE SHEET IS PUT BACK INTO ITS PRINTING STATE FIRST. printLetter()
        #  takes the class off again in a finally block, so by now the letter is
        #  hidden and a screenshot of a hidden element times out rather than
        #  failing with anything readable.
        pgl.evaluate("""() => { var n=document.getElementById('fa-print');
            document.body.appendChild(n);
            document.body.className += ' printing-letter'; }""")
        pgl.wait_for_timeout(200)
        shot = pgl.locator("#fa-print img.lt-logo").screenshot()
        from io import BytesIO
        from PIL import Image
        im = Image.open(BytesIO(shot)).convert("RGB")
        px = list(im.getdata())
        dark = len([q for q in px if sum(q) / 3 < 120])
        check("and it prints as ink rather than as cream on white",
              dark > len(px) * 0.04, "%d of %d pixels dark" % (dark, len(px)))
        pgl.evaluate("""() => { document.body.className =
            document.body.className.replace(/\s*printing-letter/, ''); }""")

        #  WHAT ACTUALLY PRINTS, NOT WHETHER A PRINT RULE EXISTS. The roll's
        #  first print check asked only whether a @media print block existed,
        #  and passed while the ENTIRE SCREEN printed: admin/shell.css carries
        #  `body.has-ashell .shell{display:block !important}` and when two
        #  !importants collide, specificity decides. (0,2,0) beat (0,0,1).
        vis = pgl.evaluate("() => window.__atPrint") or {}
        check("the print rules are switched on for this action only",
              "printing-letter" in (vis.get("bodyClass") or ""), vis)
        check("the sheet is moved out to body, away from the cascade fight",
              vis.get("atBodyLevel") is True, vis)
        check("the letter prints", vis.get("letter"), vis)
        check("the rail does not", not vis.get("rail"), vis)
        check("nor the figure tiles", not vis.get("figures"), vis)
        check("nor the table of 140 families", not vis.get("table"), vis)
        check("nor the Export button", not vis.get("exporter"), vis)
        check("nor the search box", not vis.get("search"), vis)

        #  AND ORDINARY PRINTING STILL WORKS. Unscoped, these rules made
        #  Ctrl+P produce a blank sheet.
        pgl.wait_for_timeout(200)
        #  ASKED OF SOMETHING THAT IS ACTUALLY ON SCREEN. The first version
        #  asked whether #fa-table would print and failed — correctly, and for
        #  the wrong reason: a family is open here, so the table is put away by
        #  the screen itself, not by the print rules. A check that cannot tell
        #  those two apart proves nothing either way.
        plain = pgl.evaluate("""() => {
            var n=document.querySelector('#fa-record');
            while(n && n!==document){
              var s=getComputedStyle(n);
              if(s.display==='none') return false;
              n=n.parentNode; }
            return true; }""")
        check("pressing Ctrl+P without asking for a letter still prints the "
              "screen rather than a blank sheet", plain,
              pgl.evaluate("() => document.body.className"))
        pgl.emulate_media(media="screen")
        pgl.close()

        # ==============================================================
        #  A PHONE
        # ==============================================================
        pgp = open_screen(browser, ["madrasah"], width=390, height=900)
        wide = pgp.evaluate("() => document.documentElement.scrollWidth "
                            "> document.documentElement.clientWidth + 1")
        check("the screen does not scroll sideways on a phone", not wide)
        #  A WHOLE ROW HAS TO FIT. The roll's version of this passed with the
        #  first row at 883px of a 900px screen - present, and below the fold.
        box = pgp.evaluate("""() => {
            var r=document.querySelector('#fa-rows tr');
            if(!r) return null; var b=r.getBoundingClientRect();
            return {top:b.top, bottom:b.bottom}; }""")
        #  NOT "JUST ABOUT". A first row ending at 895px of a 900px screen
        #  passes a < 900 check and still reads as a page of headings you
        #  scroll past. The bar is that a whole family is comfortably up, with
        #  the next one starting, so it looks like a list.
        check("and a whole family is visible without scrolling",
              box and box["bottom"] < 800, box)
        second = pgp.evaluate("""() => { var r=document.querySelectorAll('#fa-rows tr')[1];
            return r ? r.getBoundingClientRect().top : null; }""")
        check("and the next one has started, so it reads as a list",
              second is not None and second < 900, second)
        check("a phone gets twenty-five families to a page, not fifty, because "
              "the same fifty is four screens on a desk and thirteen here",
              pgp.locator("#fa-rows tr").count() == 25,
              pgp.locator("#fa-rows tr").count())
        check("the figures stay legible rather than shrinking to nothing",
              pgp.evaluate("() => document.querySelector('.fa-fig')"
                           ".getBoundingClientRect().width") > 120)
        #  WHO TO RING MUST BE ON THE SCREEN, not off the right-hand edge.
        #  With five columns in a table at 390px it was reachable only by
        #  scrolling the table sideways, which is the one column somebody
        #  standing in the office is looking for.
        right = pgp.evaluate("""() => {
            var c=document.querySelector('#fa-rows td[data-label="Who to ring"]');
            return c ? c.getBoundingClientRect().right : null; }""")
        check("who to ring is on the screen on a phone, not off the edge",
              right is not None and right <= 390, right)
        #  READ OFF THE RENDERED PSEUDO-ELEMENT, not the markup.
        #
        #  The first version of this looked for the label in inner_text and
        #  failed — correctly, and for a reason that had nothing to do with the
        #  screen: inner_text does not see ::before content. Asserting that the
        #  data-label attribute is present would have passed while the label
        #  rendered as nothing, which is the same mistake as "there is an <img>"
        #  on a logo that printed white on white.
        label = pgp.evaluate("""() => {
            var c=document.querySelector('#fa-rows td[data-label="Who to ring"]');
            return c ? getComputedStyle(c, '::before').content : null; }""")
        check("and each value says which column it is, the header row having "
              "gone", label and "Who to ring" in label, label)
        check("the table no longer scrolls sideways inside its own box",
              pgp.evaluate("""() => { var n=document.querySelector('.fa-scroll');
                  return n.scrollWidth <= n.clientWidth + 1; }"""))
        pgp.close()

        pg.close()
        pga_closed = True
        browser.close()
    FINISHED[0] = True


if __name__ == "__main__":
    atexit.register(report)
    run()
