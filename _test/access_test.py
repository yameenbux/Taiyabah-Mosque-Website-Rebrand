"""/access/ — who can get in.

12 September 2026. The highest-privilege screen on the site: it can make
somebody an administrator.

WHAT THIS FILE GUARDS. Not the rules — those are in Postgres (staff_list,
set_person_roles, set_person_active, the keep_two_admins trigger, and
db/025_access_control.sql proves them). What it guards is the page:

  * 2  an office account is shown nothing at all
  * 3  roles are shown in plain English — nobody in a masjid office should
       have to know what "hall_office" means
  * 4  you cannot act on your own account, and the page says why
  * 5  the last two administrators are not offered a Suspend button
  * 6  granting admin or teacher makes you type the address again — a tick
       box is too easy to press by accident for something that reaches every
       payment, or children's records
  * 7  the invite shows the LINK, because no email is sent and a screen that
       implies one was is worse than no screen

Nothing here reaches Supabase: the client is replaced before the page's own
scripts run, and every call is answered from a stub.

Run:  python3 _test/access_test.py
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
PAGE = "http://127.0.0.1:%d/access/" % httpd.server_address[1]

fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


ME = "11111111-1111-1111-1111-111111111111"

STAFF = {
    "allowed": True, "me": ME, "admins": 3,
    "people": [
        {"id": ME, "name": "Yameen Bux", "email": "yameen@example.test",
         "active": True, "roles": ["admin"], "two_step": True,
         "last_in": "2026-09-12T18:00:00+00:00", "is_me": True},
        {"id": "22222222-2222-2222-2222-222222222222", "name": "Office Person",
         "email": "office@example.test", "active": True, "roles": ["hall_office"],
         "two_step": True, "last_in": "2026-09-11T09:00:00+00:00", "is_me": False},
        {"id": "33333333-3333-3333-3333-333333333333", "name": "Mubaraq",
         "email": "mubaraq@example.test", "active": True, "roles": ["admin"],
         "two_step": False, "last_in": "2026-09-12T19:05:00+00:00", "is_me": False},
        {"id": "44444444-4444-4444-4444-444444444444", "name": "A Teacher",
         "email": "teacher@example.test", "active": True, "roles": ["teacher"],
         "two_step": True, "last_in": None, "is_me": False},
        {"id": "55555555-5555-5555-5555-555555555555", "name": "Third Admin",
         "email": "third@example.test", "active": True, "roles": ["admin"],
         "two_step": True, "last_in": "2026-09-01T09:00:00+00:00", "is_me": False},
    ],
    "invites": [
        {"email": "newcomer@example.test", "roles": ["hall_office"],
         "invited_at": "2026-09-12T17:00:00+00:00",
         "expires_at": "2026-09-26T17:00:00+00:00", "expired": False, "by": "Yameen Bux"},
    ],
}

TWO_ADMINS = json.loads(json.dumps(STAFF))
TWO_ADMINS["admins"] = 2
TWO_ADMINS["people"] = [p for p in TWO_ADMINS["people"]
                        if p["email"] != "third@example.test"]


def stub(payload, roles):
    return """
(function(){
  var STAFF = %s, ROLES = %s;
  window.__CALLS = [];
  var client = {
    auth: {
      getSession: function(){ return Promise.resolve({data:{session:{
        access_token:'tok', user:{id:'%s', email:'yameen@example.test'}}}}); },
      getUser: function(){ return Promise.resolve({data:{user:{
        id:'%s', email:'yameen@example.test'}}}); },
      signOut: function(){ return Promise.resolve({}); },
      mfa: { getAuthenticatorAssuranceLevel: function(){
               return Promise.resolve({data:{currentLevel:'aal2', nextLevel:'aal2'}}); },
             listFactors: function(){ return Promise.resolve({data:{totp:[{id:'f1'}]}}); } }
    },
    from: function(t){
      var rows = t === 'profiles' ? {full_name:'Yameen Bux', email:'yameen@example.test'}
               : ROLES.map(function(r){ return {role:r}; });
      var q = { select:function(){return q;}, eq:function(){return q;},
        maybeSingle:function(){ return Promise.resolve({data:rows, error:null}); },
        then:function(res){ return Promise.resolve({data:rows, error:null}).then(res); } };
      return q;
    },
    rpc: function(name, args){
      window.__CALLS.push({name:name, args:args||{}});
      if (name === 'staff_list') return Promise.resolve({data:STAFF, error:null});
      return Promise.resolve({data:{}, error:null});
    }
  };
  var s = { createClient: function(){ return client; } };
  Object.defineProperty(window, 'supabase', {value:s, writable:false, configurable:false});

  // The invite goes over fetch to the Edge Function, not through the client.
  var realFetch = window.fetch;
  window.fetch = function(url, opts){
    if (String(url).indexOf('/functions/v1/invite-user') !== -1) {
      window.__INVITE = JSON.parse((opts && opts.body) || '{}');
      return Promise.resolve(new Response(JSON.stringify({
        ok:true, email:window.__INVITE.email, roles:window.__INVITE.roles,
        kind:'invite', link:'https://example.test/auth/?token=ABC123'
      }), {status:200, headers:{'content-type':'application/json'}}));
    }
    return realFetch.apply(this, arguments);
  };
})();
""" % (json.dumps(payload), json.dumps(roles), ME, ME)


def open_page(b, payload, roles):
    pg = b.new_page(viewport={"width": 1280, "height": 1200})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.on("dialog", lambda d: d.accept("everything"))
    pg.add_init_script(stub(payload, roles))
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1200)
    return pg, errs


def type_confirm(pg, value):
    """Fill the confirm box, or record a failure and carry on.

    If the box is not on screen, Playwright's fill() raises and the suite stops
    there — hiding every assertion after it, which on THIS page includes
    whether an invite was sent at all. A control that removes the confirm step
    is exactly when the rest of the file matters most.
    """
    if not pg.is_visible("#inv-confirm"):
        fails.append("the confirm box is not on screen when it should be — "
                     "a far-reaching role was chosen and the page did not ask twice")
        return False
    pg.fill("#inv-confirm", value)
    return True


def text(pg, sel):
    node = pg.query_selector(sel)
    return re.sub(r"\s+", " ", node.inner_text()) if node else ""


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1. IT OPENS FOR AN ADMINISTRATOR
    # =====================================================================
    pg, errs = open_page(b, STAFF, ["admin"])
    check(pg.is_visible("#acc-panel"), "the access screen did not open for an administrator")
    rows = pg.eval_on_selector_all("#acc-list .acc-row", "els => els.map(e => e.innerText)")
    check(len(rows) == 5, "expected five staff accounts, drew %d" % len(rows))

    # =====================================================================
    #  3. PLAIN ENGLISH
    # =====================================================================
    joined = " ".join(rows)
    check("hall_office" not in joined,
          "a raw role name is on screen — nobody in a masjid office should "
          "have to know what hall_office means: %r" % joined[:300])
    check("Hall bookings and nik" in joined, "the office role is not named in plain English")
    check("Everything" in joined, "the admin role is not named in plain English")
    check("Madrasah" in joined, "the teacher role is not named in plain English")

    #  The column the whole screen exists for.
    check("No authenticator" in joined, "the account without two-step is not flagged")
    check("blocks the next database change" in joined,
          "the page does not say WHY an account without two-step matters")
    check("Two-step on" in joined, "accounts with two-step are not marked")
    check("never" in joined.lower(), "an account that has never signed in is not shown as such")

    # =====================================================================
    #  4. YOU CANNOT ACT ON YOURSELF
    # =====================================================================
    mine = pg.query_selector("#acc-list .acc-row.me")
    check(mine is not None, "your own row is not marked")
    if mine:
        own = re.sub(r"\s+", " ", mine.inner_text())
        check("cannot change your own access" in own,
              "the page does not say why your own row has no buttons: %r" % own)
        check(mine.query_selector("button") is None,
              "YOUR OWN ROW HAS BUTTONS ON IT — self-lockout and self-escalation "
              "are both one press away")

    # =====================================================================
    #  5. THE LAST TWO ADMINISTRATORS
    # =====================================================================
    #  With three admins, suspending one is offered.
    third = pg.query_selector('#acc-list .acc-row[data-id="55555555-5555-5555-5555-555555555555"]')
    check(third is not None, "the third administrator is missing from the list")
    if third:
        btn = third.query_selector('button[data-act="suspend"]')
        check(btn is not None and not btn.is_disabled(),
              "with three administrators, suspending one should be offered")
    pg.close()

    #  With only two, it is not.
    pg, errs2 = open_page(b, TWO_ADMINS, ["admin"])
    admins = pg.eval_on_selector_all(
        "#acc-list .acc-row", "els => els.map(e => e.innerText)")
    joined2 = " ".join(admins)
    check("One of the last two administrators" in joined2,
          "with two administrators left, the page does not say why they cannot "
          "be suspended: %r" % joined2[:300])
    #  ONLY the administrators' buttons. The first version asserted that every
    #  Suspend button was dead, which would also have "passed" a page that
    #  refused to suspend anybody at all — including the office account, who
    #  has nothing to do with the two-admin floor.
    state = pg.eval_on_selector_all("#acc-list .acc-row", """els => els.map(e => ({
        admin: e.innerText.indexOf('Everything') !== -1,
        btn:   !!e.querySelector('button[data-act="suspend"]'),
        off:   !!(e.querySelector('button[data-act="suspend"]') || {}).disabled
    }))""")
    for row in state:
        if row["admin"] and row["btn"]:
            check(row["off"],
                  "a Suspend button is live on one of the last two administrators")
        if not row["admin"] and row["btn"]:
            check(not row["off"],
                  "the two-admin floor disabled Suspend on somebody who is not "
                  "an administrator")
    check(errs2 == [], "uncaught exceptions with two administrators: %s" % errs2)
    pg.close()

    # =====================================================================
    #  6. THE LOUD PATH
    # =====================================================================
    pg, errs = open_page(b, STAFF, ["admin"])
    pg.click("#acc-invite-open")
    pg.wait_for_timeout(200)
    check(pg.is_visible("#acc-invite"), "the invite form did not open")
    check(not pg.is_visible("#inv-confirm-wrap"),
          "the confirm box is showing before anything far-reaching is chosen")

    pg.check('.inv-r[value="hall_office"]')
    pg.wait_for_timeout(150)
    check(not pg.is_visible("#inv-confirm-wrap"),
          "hall bookings is an ordinary role and should not ask twice")

    pg.check('.inv-r[value="admin"]')
    pg.wait_for_timeout(150)
    check(pg.is_visible("#inv-confirm-wrap"),
          "GRANTING ADMIN DOES NOT ASK TWICE. A tick box is too easy to press "
          "by accident for something that reaches every payment and record")
    check("change what other people can do" in text(pg, "#inv-confirm-wrap"),
          "the confirm box does not say what is being granted: %r"
          % text(pg, "#inv-confirm-wrap"))

    #  Teacher reaches children's records, so it is loud too. hall_office is
    #  unticked here so the assertion further down is about ONE role and says
    #  what it means — the first version left it ticked and then complained
    #  that two roles were sent, which was the test's own doing.
    pg.uncheck('.inv-r[value="admin"]')
    pg.uncheck('.inv-r[value="hall_office"]')
    pg.check('.inv-r[value="teacher"]')
    pg.wait_for_timeout(150)
    check(pg.is_visible("#inv-confirm-wrap"),
          "granting the madrasah role does not ask twice — it reaches "
          "children's records")

    #  Typing the wrong address must stop it.
    pg.fill("#inv-email", "newperson@example.test")
    type_confirm(pg, "someoneelse@example.test")
    pg.click("#inv-send")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__INVITE") is None,
          "AN INVITE WAS SENT WITH THE CONFIRMATION TYPED WRONG")
    check("again" in text(pg, "#acc-error").lower(),
          "no useful message when the confirmation does not match: %r" % text(pg, "#acc-error"))

    # =====================================================================
    #  7. THE LINK, NOT AN EMAIL
    # =====================================================================
    type_confirm(pg, "newperson@example.test")
    pg.click("#inv-send")
    pg.wait_for_timeout(600)

    sent = pg.evaluate("window.__INVITE")
    check(sent is not None, "the invite never reached the function")
    if sent:
        check(sent.get("email") == "newperson@example.test",
              "the wrong address was invited: %r" % sent)
        check(sent.get("roles") == ["teacher"],
              "the wrong roles were sent: %r" % sent)

    check(pg.is_visible("#inv-result"), "the invite link was not shown")
    link = text(pg, "#inv-url")
    check("token=ABC123" in link, "the link itself is not on screen: %r" % link)
    shown = text(pg, "#inv-result")
    check("Nothing has been emailed" in shown,
          "THE PAGE DOES NOT SAY NO EMAIL WAS SENT. An admin who thinks one "
          "went will wait for a reply that never comes: %r" % shown)
    check("authenticator" in shown.lower(),
          "the page does not explain that nothing is granted until they enrol")

    # =====================================================================
    #  8. AN INVITE WAITING IS NOT ACCESS
    # =====================================================================
    pend = text(pg, "#acc-pending")
    check("newcomer@example.test" in pend, "the pending invitation is not listed")
    check("Not accepted yet" in pend, "the pending invitation is not marked as unaccepted")
    #  The pending list renders roles separately from the accounts list, so it
    #  can drift into raw names on its own. A negative control on the accounts
    #  list passed while this list was showing "hall_office" — the control is
    #  what found the gap.
    check("hall_office" not in pend,
          "a raw role name is in the pending invitations: %r" % pend)
    check("Hall bookings and nik" in pend,
          "the pending invitation does not name the role in plain English: %r" % pend)
    check("Nothing is granted until" in pend,
          "the page does not say an invitation grants nothing: %r" % pend)

    check(errs == [], "uncaught exceptions: %s" % errs)
    pg.close()

    # =====================================================================
    #  2. AN OFFICE ACCOUNT SEES NOTHING
    # =====================================================================
    pg, errs = open_page(b, {"allowed": False}, ["hall_office"])
    check(not pg.is_visible("#acc-panel"),
          "AN OFFICE ACCOUNT WAS SHOWN THE STAFF LIST")
    check(pg.is_visible("#app-noaccess"),
          "an office account is not told why it cannot see anything")
    check(pg.query_selector("#acc-list .acc-row") is None,
          "staff rows were drawn for an office account")
    check(errs == [], "uncaught exceptions for an office account: %s" % errs)
    pg.close()

    # =====================================================================
    #  9. IT SURVIVES A PHONE
    # =====================================================================
    pg, errs = open_page(b, STAFF, ["admin"])
    for w in [1280, 900, 390]:
        pg.set_viewport_size({"width": w, "height": 1000})
        pg.wait_for_timeout(250)
        check(pg.evaluate("document.documentElement.scrollWidth") <= w + 2,
              "the access screen scrolls sideways at %dpx" % w)
    check(errs == [], "uncaught exceptions while resizing: %s" % errs)
    pg.close()

    b.close()

httpd.shutdown()
print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
