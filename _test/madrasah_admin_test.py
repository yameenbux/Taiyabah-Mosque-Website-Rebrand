"""The madrasah's Administration screens, its role, and its collapsing rail.

18 September 2026. Four screens went in at once and one new role; this is what
stops them drifting apart. Every check exists because of something that was
wrong or could quietly become wrong.

WHAT THIS FILE GUARDS:

  1  THE MADRASAH ROLE REACHES THE TEACHING SIDE AND NOTHING ELSE. A teaching
     account must not be shown Staff, DBS, Fees or Admissions in the menu. The
     database refuses those screens either way — this is about a menu not
     naming the safeguarding list to somebody who cannot open it.

  2  THE TICK BOX GRANTS THE ROLE THAT EXISTS. The access screen has always
     said "Madrasah" and always written `teacher`, which the madrasah portal
     has never looked at. Anybody given it landed on "you have no access here".

  3  A LONG RAIL COLLAPSES AND A SHORT ONE DOES NOT, and the group you are
     standing in is open either way.

  4  THE CALENDAR DRAWS THE WHOLE YEAR, marks the right days, and does not
     open its editor until asked.

  5  A NON-ADMINISTRATOR IS NOT OFFERED CONTROLS THAT WOULD BE REFUSED.

  6  THE UPLOAD REFUSES WHAT IT SHOULD, IN THE BROWSER, BEFORE THE WAIT — and
     SVG is refused outright, because an SVG is a document that can carry
     script and the brand bucket is public.

  7  ADMIN STAFF WRITES NOTHING. It shows who can get in; granting happens in
     one place. A writer appearing here is the two-lists problem returning.

Nothing here reaches Supabase.

Run:  python3 _test/madrasah_admin_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, re, json, http.server, socketserver, threading, functools, atexit

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True

fails = []
def check(cond, msg):
    if not cond: fails.append(msg)

@atexit.register
def _report():
    if fails:
        print("FAIL (%d)" % len(fails))
        for f in fails: print("  - " + f)
    elif _report.done: print("ALL PASS")
    else: print("DID NOT FINISH — see the traceback above.")
_report.done = False


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass

httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PORT = httpd.server_address[1]
def url(p): return "http://127.0.0.1:%d/%s" % (PORT, p)

CAL = {
 "year": {"label": "2026/27", "starts_on": "2026-09-01", "ends_on": "2027-08-31"},
 "closures": [
   {"id": "c1", "name": "Insert Day", "note": "Teachers in",
    "starts_on": "2026-09-01", "ends_on": "2026-09-01"},
   {"id": "c2", "name": "Half Term Break", "note": None,
    "starts_on": "2026-10-26", "ends_on": "2026-10-30"}],
 "events": [
   {"id": "e1", "name": "Eid al-Fitr", "hijri_label": "1 Shawwal",
    "on_date": "2027-03-09", "is_estimated": True}]}

PEOPLE = {"me": "u1", "people": [
  {"id": "u1", "name": "An Admin", "email": "a@x.test", "active": True,
   "roles": ["admin"], "reach": "everything", "two_step": True,
   "last_in": "2026-09-18T08:00:00Z", "is_me": True},
  {"id": "u2", "name": "A Teacher", "email": "t@x.test", "active": True,
   "roles": ["madrasah"], "reach": "madrasah only", "two_step": False,
   "last_in": None, "is_me": False}]}

PROF = {"legal_name": "Bolton Central Islamic Society", "short_name": "Taiyabah Masjid",
        "address": "Cannon Street", "postcode": "BL3 5BE", "phone": "01204 000000",
        "email": "o@x.test", "website": "https://x.test", "charity_no": "1041569",
        "updated_at": "2026-09-18T10:00:00Z", "images": []}


def stub(roles, answers):
    """Records every rpc AND every storage upload, in order.

    The order is not incidental: the profile screen must put the bytes in
    Storage BEFORE it writes the row, because a row pointing at a file that
    never arrived is a broken picture in a letter already posted.
    """
    return """
(function(){
  var ROLES=%s, A=%s;
  window.__rpc=[]; window.__up=[]; window.__seq=[];
  var client={
    auth:{getSession:function(){return Promise.resolve({data:{session:{access_token:'t',user:{id:'u1',email:'a@b.test'}}}});},
      getUser:function(){return Promise.resolve({data:{user:{id:'u1',email:'a@b.test'}}});},
      signOut:function(){return Promise.resolve({});},
      updateUser:function(){return Promise.resolve({data:{},error:null});},
      mfa:{getAuthenticatorAssuranceLevel:function(){return Promise.resolve({data:{currentLevel:'aal2',nextLevel:'aal2'}});},
           listFactors:function(){return Promise.resolve({data:{totp:[{id:'f1'}]}});}}},
    from:function(t){var rows=t==='profiles'?{full_name:'A Person',email:'a@b.test'}:ROLES.map(function(r){return{role:r};});
      var q={select:function(){return q;},eq:function(){return q;},
        maybeSingle:function(){return Promise.resolve({data:rows,error:null});},
        then:function(f){return Promise.resolve({data:rows,error:null}).then(f);}};return q;},
    storage:{from:function(b){return {upload:function(path,file,opt){
      window.__up.push({bucket:b,path:path,type:file&&file.type,size:file&&file.size});
      window.__seq.push('upload');
      return Promise.resolve({data:{path:path},error:null});}};}},
    rpc:function(n,a){ window.__rpc.push([n,a]); window.__seq.push('rpc:'+n);
      if(A[n]!==undefined) return Promise.resolve({data:A[n],error:null});
      return Promise.resolve({data:{id:'new'},error:null}); }};
  Object.defineProperty(window,'supabase',{value:{createClient:function(){return client;}},writable:false,configurable:false});
})();
""" % (json.dumps(roles), json.dumps(answers))


def open_page(b, path, roles, answers, w=1500, h=1200, tz=None):
    """tz is not decoration — see the two calendar runs below."""
    ctx = b.new_context(viewport={"width": w, "height": h},
                        timezone_id=tz or "Europe/London")
    pg = ctx.new_page()
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:220]))
    pg.add_init_script(stub(roles, answers))
    pg.goto(url(path), wait_until="load")
    pg.wait_for_timeout(1400)
    return pg, errs


def rail(pg):
    """textContent, NOT innerText.

    Found the hard way while writing this file: innerText is what the LAYOUT
    renders, and the contents of a closed <details> render as nothing at all.
    Read that way, a collapsed rail looks like an empty rail, and "an
    administrator cannot see DBS in the menu" fails on a page where the row is
    perfectly present. Worse, the mirror-image check — "a teaching account is
    not shown DBS" — would have PASSED for the wrong reason the moment that
    rail grew past the collapsing threshold, which is exactly the check that
    must never pass by accident.
    """
    return pg.eval_on_selector_all(".ashell-sec", """els => els.map(e => ({
      label: e.querySelector('summary').textContent.trim(),
      open: e.open,
      rows: Array.from(e.querySelectorAll('.area')).map(a => a.textContent.trim())
    }))""")


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1. THE MADRASAH ROLE REACHES THE TEACHING SIDE AND NOTHING ELSE
    # =====================================================================
    pg, errs = open_page(b, "portal/", ["madrasah"], {})
    check(not errs, "the console threw for a madrasah account: %r" % errs[:2])
    check(pg.is_visible("#md-panel"),
          "a madrasah account was refused the console it was granted. A role that "
          "opens nothing is worse than no role — somebody has been told they were "
          "given one.")

    words = " ".join(g["label"] + " " + " ".join(g["rows"]) for g in rail(pg)).lower()
    for banned, why in [
        ("dbs", "the DBS list names sixteen people working with children with "
                "nothing on file — it is the most sensitive list in the building"),
        ("staff", "staff records hold home contact details and DBS positions"),
        ("fees", "fees are not the teaching side"),
        ("admissions", "admissions hold applications from families"),
        ("concerns", "safeguarding concerns are administrators only"),
    ]:
        check(banned not in words,
              "A TEACHING ACCOUNT IS SHOWN %r IN ITS MENU — %s. The database refuses "
              "it either way; naming it here is still wrong." % (banned, why))

    #  And it must still be shown the things it CAN do, or the gate is simply
    #  a blank screen with extra steps.
    for want in ["register", "classes", "homework"]:
        check(want in words, "a teaching account cannot see %r in its menu" % want)
    pg.close()

    # ---- an administrator sees all of it ---------------------------------
    pg, errs = open_page(b, "portal/", ["admin"], {})
    groups = rail(pg)
    words = " ".join(g["label"] + " " + " ".join(g["rows"]) for g in groups).lower()
    for want in ["dbs", "fees", "admissions", "admin staff", "school profile",
                 "calendar", "concerns"]:
        check(want in words, "an administrator cannot see %r in the madrasah menu" % want)

    # =====================================================================
    #  3. A LONG RAIL COLLAPSES; THE GROUP YOU ARE IN STAYS OPEN
    # =====================================================================
    total = sum(len(g["rows"]) for g in groups)
    check(total > 18, "the madrasah rail is only %d rows, so this test is no longer "
                      "exercising the collapsing rule it was written for" % total)
    opened = [g for g in groups if g["open"]]
    check(len(opened) == 1,
          "a %d-row rail drew %d groups open. Over the threshold exactly one — the "
          "one you are standing in — should be: %r"
          % (total, len(opened), [g["label"] for g in opened]))
    check("TODAY" in opened[0]["label"].upper(),
          "the open group is not the one holding the current page: %r" % opened[0]["label"])

    #  The heading has to be a real control, not a div somebody attached a
    #  click to. <summary> is what brings keyboard operation and the
    #  expanded/collapsed state a screen reader announces.
    tag = pg.eval_on_selector(".ashell-sec > *", "e => e.tagName")
    check(tag == "SUMMARY",
          "the group heading is a <%s>. It must be a <summary> inside <details>, "
          "or it is not keyboard operable and announces nothing." % tag.lower())

    #  Opening one and reloading must remember it — a rule that fights the
    #  person every visit is a rule they stop using.
    pg.eval_on_selector_all(".ashell-sec",
        "els => { const g = els.find(e => !e.open); if (g) g.open = true; }")
    pg.wait_for_timeout(250)
    saved = pg.evaluate("Object.keys(window.localStorage).filter(k => k.indexOf('taiyabah.rail') === 0).length")
    check(saved > 0, "opening a group was not remembered, so the rail re-collapses "
                     "it on every single visit")
    pg.close()

    # ---- the Admin Centre's own rail must NOT have changed ---------------
    pg, errs = open_page(b, "portals/", ["admin"], {})
    groups = rail(pg)
    if groups:
        total = sum(len(g["rows"]) for g in groups)
        shut = [g["label"] for g in groups if not g["open"]]
        check(total <= 18 and not shut,
              "the Admin Centre rail is %d rows and %d of its groups came up shut. "
              "It was legible whole and collapsing it is a regression, not a "
              "feature: %r" % (total, len(shut), shut))
    pg.close()

    # =====================================================================
    #  4 & 5. THE CALENDAR
    # =====================================================================
    pg, errs = open_page(b, "portal/calendar/", ["admin"], {"madrasah_calendar": CAL})
    check(not errs, "the calendar threw: %r" % errs[:2])

    mons = pg.eval_on_selector_all(".cal-mon h3", "e => e.map(x => x.innerText.replace(/\\s+/g,' ').trim())")
    check(len(mons) == 12, "expected twelve months on one page, drew %d" % len(mons))
    check(mons and mons[0].startswith("September 2026"),
          "the year does not start in September. A madrasah year runs September to "
          "August; starting in January splits the summer holiday across both ends "
          "of the page: %r" % (mons[:1]))
    check(mons and mons[-1].startswith("August 2027"),
          "the year does not end in August: %r" % (mons[-1:] or [""]))

    #  Half Term Break is 26-30 October: five days, inclusive at both ends.
    #  An off-by-one here is a parent booking a flight on a teaching day.
    shut = pg.eval_on_selector_all(".cal-d.shut", "e => e.map(x => x.getAttribute('data-d'))")
    for d in ["2026-10-26", "2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30",
              "2026-09-01"]:
        check(d in shut, "%s should be marked shut and is not" % d)
    for d in ["2026-10-25", "2026-10-31"]:
        check(d not in shut, "%s is marked shut and should not be — the closure runs "
                             "26 to 30 October inclusive" % d)

    evt = pg.eval_on_selector_all(".cal-d.evt", "e => e.map(x => x.getAttribute('data-d'))")
    check("2027-03-09" in evt, "Eid al-Fitr is not on 9 March: %r" % evt)

    check(not pg.is_visible("#cal-editor"),
          "the calendar's editor is on screen before anybody asked for it")
    check(not pg.is_visible("#cal-day"),
          "a day's card is open before any day was pressed")

    pg.click('button.cal-d[data-d="2027-03-09"]')
    pg.wait_for_timeout(300)
    check(pg.is_visible("#cal-day"), "pressing a day did not open its card")
    day = pg.inner_text("#cal-day-items")
    check("Eid al-Fitr" in day, "the day card does not name what is on it: %r" % day[:120])
    check("estimated" in day.lower(),
          "an Islamic date is shown without saying it is an estimate. It is "
          "calculated and settled by moon sighting; presented as fact it is how a "
          "family turns up on the wrong morning: %r" % day[:160])
    check(pg.is_visible("#cal-day-acts"), "an administrator is not offered the amend controls")
    before = pg.evaluate("window.__rpc.length")
    pg.close()

    # ---- a teaching account may read it and not change it ----------------
    pg, errs = open_page(b, "portal/calendar/", ["madrasah"], {"madrasah_calendar": CAL})
    check(pg.is_visible("#cal-panel"),
          "a madrasah account cannot read the calendar. The public website shows "
          "these same dates to anybody at all, so there is nothing here to keep back.")
    check(pg.eval_on_selector_all(".cal-mon", "e => e.length") == 12,
          "a madrasah account was not drawn the year")
    check(not pg.is_visible("#cal-acts"),
          "a teaching account is offered “Add a closure”, which the database would "
          "refuse. A button that always fails teaches people the screen is broken.")
    pg.click('button.cal-d[data-d="2027-03-09"]')
    pg.wait_for_timeout(300)
    check(not pg.is_visible("#cal-day-acts"),
          "a teaching account is offered the amend controls on a day")
    check("change" not in pg.inner_text("#cal-day-items").lower(),
          "a teaching account is offered Change/Remove on an entry")
    pg.close()

    # =====================================================================
    #  4b. THE SAME CALENDAR WHEREVER IT IS OPENED
    #
    #  new Date("2027-03-09") is parsed as MIDNIGHT UTC, not as a local day.
    #  Read back with getDate() that lands on the 8th in every timezone behind
    #  UTC — so a calendar built the lazy way shows Eid on the wrong morning to
    #  anybody reading it from outside Europe, which for a masjid whose families
    #  travel is not a theoretical audience.
    #
    #  Europe/London alone would NEVER catch it: UTC midnight is the same day in
    #  GMT and 01:00 the same day in BST. The bug is invisible from Bolton and
    #  perfectly real. So the year is drawn twice, in two timezones five hours
    #  apart, and the two have to be identical. That is the actual property —
    #  this calendar means the same thing wherever it is opened.
    # =====================================================================
    def cells(tz):
        q, _ = open_page(b, "portal/calendar/", ["admin"],
                         {"madrasah_calendar": CAL}, tz=tz)
        got = {
          "shut": q.eval_on_selector_all(".cal-d.shut", "e => e.map(x => x.getAttribute('data-d'))"),
          "evt":  q.eval_on_selector_all(".cal-d.evt",  "e => e.map(x => x.getAttribute('data-d'))"),
          "mons": q.eval_on_selector_all(".cal-mon h3", "e => e.map(x => x.textContent.replace(/\\s+/g,' ').trim())"),
        }
        q.close()
        return got

    here = cells("Europe/London")
    away = cells("America/Chicago")
    #  Report WHICH part differed. A failure that prints two lists that look
    #  alike sends the reader hunting; naming the key and the first day that
    #  moved points straight at it.
    differing = [k for k in here if here[k] != away[k]]
    detail = ""
    if differing:
        k = differing[0]
        moved = [d for d in here[k] if d not in away[k]][:3]
        detail = " First difference in %r — %r is there from Bolton and not from Chicago." % (k, moved)
    check(not differing,
          "THE CALENDAR CHANGES SHAPE DEPENDING ON WHERE IT IS OPENED. The iso "
          "dates are being handed to new Date(), which parses them as midnight UTC "
          "and reads back as the previous day anywhere behind it." + detail)

    # =====================================================================
    #  6. THE UPLOAD REFUSES WHAT IT SHOULD, BEFORE THE WAIT
    # =====================================================================
    pg, errs = open_page(b, "portal/profile/", ["admin"], {"masjid_profile_get": PROF})
    check(not errs, "the profile screen threw: %r" % errs[:2])
    check(pg.is_visible("#pf-panel"), "the profile panel did not open for an administrator")

    kinds = pg.eval_on_selector_all(".pf-kind h4", "e => e.map(x => x.innerText)")
    check(len(kinds) == 3, "expected three kinds of image, drew %d: %r" % (len(kinds), kinds))

    #  SVG IS NOT ON THE ACCEPT LIST, and this is a security check rather than
    #  a tidiness one: an SVG is a document that can carry script and the brand
    #  bucket is public.
    accept = pg.eval_on_selector(".pf-file", "e => e.getAttribute('accept')")
    check("svg" not in (accept or "").lower(),
          "the picker accepts SVG. An SVG can carry script and this bucket is "
          "public: %r" % accept)

    def put(kind, name, mime, size):
        pg.evaluate("""([k,n,m,s]) => {
          const inp = document.getElementById('pf-file-' + k);
          const f = new File([new Uint8Array(s)], n, {type:m});
          const dt = new DataTransfer(); dt.items.add(f); inp.files = dt.files;
          inp.dispatchEvent(new Event('change', {bubbles:true}));
        }""", [kind, name, mime, size])
        pg.wait_for_timeout(150)
        pg.click('.pf-up[data-kind="%s"]' % kind)
        pg.wait_for_timeout(350)

    n0 = pg.evaluate("window.__up.length")
    put("email_banner", "logo.svg", "image/svg+xml", 500)
    check(pg.evaluate("window.__up.length") == n0,
          "AN SVG WAS UPLOADED. It is a document that can carry script and the "
          "brand bucket is public and served to mail clients.")
    check("PNG" in pg.inner_text("#pf-error") or "png" in pg.inner_text("#pf-error").lower(),
          "the refusal does not say what would be accepted: %r" % pg.inner_text("#pf-error"))

    put("email_banner", "huge.png", "image/png", 4 * 1024 * 1024)
    check(pg.evaluate("window.__up.length") == n0,
          "a 4MB picture was uploaded past a 3MB limit")

    pg.evaluate("window.__seq = []")
    put("email_banner", "banner.png", "image/png", 4000)
    seq = pg.evaluate("window.__seq")
    check(seq and seq[0] == "upload",
          "the row was written before the bytes were stored: %r. A row pointing at "
          "a file that never arrived is a broken picture in a letter already "
          "posted; an orphaned file is just a file." % seq[:3])
    check("rpc:record_masjid_image" in seq,
          "the upload never recorded the image: %r" % seq[:4])
    rec = [r for r in pg.evaluate("window.__rpc") if r[0] == "record_masjid_image"]
    check(rec and rec[-1][1]["p"].get("is_current") is True,
          "an uploaded banner was not made the current one, so nothing would use it")
    path = rec[-1][1]["p"].get("storage_path", "") if rec else ""
    check(path and path != "email_banner/banner.png" and "/" in path,
          "the stored path is a fixed name (%r). Mail clients and CDNs cache by "
          "URL, so overwriting one leaves the old artwork in half the world's "
          "inboxes with nothing to clear it." % path)
    pg.close()

    # =====================================================================
    #  7. ADMIN STAFF WRITES NOTHING
    # =====================================================================
    pg, errs = open_page(b, "portal/people/", ["admin"], {"madrasah_people": PEOPLE})
    check(not errs, "the admin staff screen threw: %r" % errs[:2])
    called = [r[0] for r in pg.evaluate("window.__rpc")]
    for w in ["set_person_roles", "invite", "save_person", "set_person_active"]:
        check(not any(w in c for c in called),
              "the Admin Staff screen called %r. It shows access; it does not grant "
              "it. Two screens that both grant is how somebody is removed from one "
              "and left on the other." % w)
    body = pg.inner_text("#pp-panel")
    check("Not set up" in body,
          "an account with no authenticator is not flagged. This portal will hold "
          "children's records and that account is one leaked password away from "
          "them: %r" % body[:200])
    check("teaching side only" in body.lower(),
          "the screen does not say what a madrasah account actually reaches")
    href = pg.eval_on_selector("#pp-link", "e => e.getAttribute('href')")
    check(href and "access" in href,
          "there is no way through to the screen that does grant access: %r" % href)
    pg.close()
    b.close()

# =====================================================================
#  2. THE TICK BOX GRANTS THE ROLE THAT EXISTS  (static, on the markup)
# =====================================================================
access = open("access/index.html", encoding="utf-8").read()
boxes = re.findall(r'<input type="checkbox" value="([a-z_]+)"[^>]*class="(?:inv|pp)-r"', access)
check(boxes.count("madrasah") == 2,
      "the access screen does not offer the `madrasah` role in both places "
      "(invite and edit). Found: %r" % boxes)
check("teacher" not in boxes,
      "a tick box still writes `teacher`. It is labelled Madrasah and the madrasah "
      "portal has never looked at that role, so anybody given it signs in and is "
      "told they have no access: %r" % boxes)

nav = open("portal/nav.js", encoding="utf-8").read()
for key, who in [("md-staff", "ADMIN"), ("md-dbs", "ADMIN"), ("md-fees", "ADMIN"),
                 ("md-admissions", "ADMIN"), ("md-concerns", "ADMIN"),
                 ("md-register", "BOTH"), ("md-classes", "BOTH")]:
    m = re.search(r'key:\s*"%s".{0,260}?needs:\s*(\w+)' % key, nav, re.S)
    check(m and m.group(1) == who,
          "%s should need %s and needs %r" % (key, who, m.group(1) if m else None))

check("Gift Aid cannot be claimed on madrasah fees" in nav.replace("GIFT AID CANNOT BE CLAIMED ON", "Gift Aid cannot be claimed on")
      or "GIFT AID CANNOT BE CLAIMED ON" in nav,
      "the note about Gift Aid not applying to fees has gone. A fee buys a place "
      "in a class, so it is payment for a service and not a gift, and the Gift Aid "
      "machinery is sitting right there in the Admin Centre for somebody to join up.")

_report.done = True
if fails:
    sys.exit(1)
