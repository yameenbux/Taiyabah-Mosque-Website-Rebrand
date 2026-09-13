"""/access/ — who can get in.

13 September 2026. The highest-privilege screen on the site: it can make
somebody an administrator.

WHAT THIS FILE GUARDS. Not the rules — those are in Postgres (staff_list,
record_invite, set_person_roles, set_person_contact, set_person_active, the
keep_two_admins trigger; db/025 and db/026 prove them). What it guards is the
page:

  *  2  an office account is shown nothing at all
  *  3  roles are shown in plain English — nobody in a masjid office should
        have to know what "hall_office" means
  *  4  a tile opens that person's page, and the list goes away
  *  5  you cannot change your own roles, and the page says why — but you CAN
        correct your own phone number, because that is not a privilege
  *  6  the last two administrators are not offered a Suspend button, and
        somebody who is NOT an administrator still is
  *  7  granting admin or teacher makes you type the address again — a tick
        box is too easy to press by accident for something that reaches every
        payment, or children's records
  *  8  an invitation cannot be sent without a name and a phone number
  *  9  the page says whether the invitation was EMAILED, and shows the link
        either way. A screen that says "emailed" when nothing was sent is the
        failure this is written against
  * 10  an account with no phone number is visibly incomplete, and can be
        fixed from that person's page
  * 11  the page goes full width and keeps a way back
  * 12  THERE IS NOWHERE ON THIS PAGE TO TYPE SOMEBODY ELSE'S PASSWORD. An
        administrator can send a reset link; an administrator can never set a
        password. A password an administrator chose is one they know, and from
        then on every sign-in by that person is deniable
  * 13  a message about something that just worked survives the redraw that
        follows it

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


ME     = "11111111-1111-1111-1111-111111111111"
OFFICE = "22222222-2222-2222-2222-222222222222"
MUB    = "33333333-3333-3333-3333-333333333333"
TEACH  = "44444444-4444-4444-4444-444444444444"
THIRD  = "55555555-5555-5555-5555-555555555555"

STAFF = {
    "allowed": True, "me": ME, "admins": 3,
    "people": [
        {"id": ME, "name": "Yameen Bux", "email": "yameen@example.test",
         "phone": "07700 900111", "active": True, "roles": ["admin"],
         "two_step": True, "last_in": "2026-09-12T18:00:00+00:00",
         "since": "2026-08-24T09:00:00+00:00", "needs": [], "is_me": True},
        {"id": OFFICE, "name": "Office Person", "email": "office@example.test",
         "phone": "07700 900222", "active": True, "roles": ["hall_office"],
         "two_step": True, "last_in": "2026-09-11T09:00:00+00:00",
         "since": "2026-08-24T09:00:00+00:00", "needs": [], "is_me": False},
        # No phone number, and no authenticator. The two gaps this screen exists
        # to make visible, on one account.
        {"id": MUB, "name": "Mubaraq", "email": "mubaraq@example.test",
         "phone": None, "active": True, "roles": ["admin"], "two_step": False,
         "last_in": "2026-09-12T19:05:00+00:00", "since": "2026-08-24T09:00:00+00:00",
         "needs": ["phone", "two_step"], "is_me": False},
        {"id": TEACH, "name": "A Teacher", "email": "teacher@example.test",
         "phone": "07700 900444", "active": True, "roles": ["teacher"],
         "two_step": True, "last_in": None, "since": "2026-09-01T09:00:00+00:00",
         "needs": [], "is_me": False},
        {"id": THIRD, "name": "Third Admin", "email": "third@example.test",
         "phone": "07700 900555", "active": True, "roles": ["admin"],
         "two_step": True, "last_in": "2026-09-01T09:00:00+00:00",
         "since": "2026-08-24T09:00:00+00:00", "needs": [], "is_me": False},
    ],
    "invites": [
        {"email": "newcomer@example.test", "name": "New Comer",
         "phone": "07700 900777", "roles": ["hall_office"],
         "invited_at": "2026-09-12T17:00:00+00:00",
         "expires_at": "2026-09-26T17:00:00+00:00", "expired": False,
         "incomplete": False, "by": "Yameen Bux"},
        # Written before 026. claim_pending_access() will refuse it, so the
        # page has to say so rather than let somebody wait for it.
        {"email": "old@example.test", "name": None, "phone": None,
         "roles": ["admin"], "invited_at": "2026-09-01T17:00:00+00:00",
         "expires_at": "2026-09-30T17:00:00+00:00", "expired": False,
         "incomplete": True, "by": "Yameen Bux"},
    ],
}

TWO_ADMINS = json.loads(json.dumps(STAFF))
TWO_ADMINS["admins"] = 2
TWO_ADMINS["people"] = [p for p in TWO_ADMINS["people"]
                        if p["email"] != "third@example.test"]


def stub(payload, roles, emailed=True, email_note=""):
    return """
(function(){
  var STAFF = %s, ROLES = %s, EMAILED = %s, NOTE = %s;
  window.__CALLS = [];
  var client = {
    auth: {
      getSession: function(){ return Promise.resolve({data:{session:{
        access_token:'tok', user:{id:'%s', email:'yameen@example.test'}}}}); },
      getUser: function(){ return Promise.resolve({data:{user:{
        id:'%s', email:'yameen@example.test'}}}); },
      signOut: function(){ return Promise.resolve({}); },
      updateUser: function(o){ window.__PWCHANGE = o; return Promise.resolve({data:{},error:null}); },
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
      var sent = JSON.parse((opts && opts.body) || '{}');
      if (sent.action === 'reset') {
        window.__RESET = sent;
        return Promise.resolve(new Response(JSON.stringify({
          ok:true, action:'reset', email:sent.email, name:sent.full_name,
          roles:[], kind:'existing',
          link:'https://example.test/auth/v1/verify?token=RESET9',
          emailed:EMAILED, email_note:NOTE
        }), {status:200, headers:{'content-type':'application/json'}}));
      }
      window.__INVITE = sent;
      return Promise.resolve(new Response(JSON.stringify({
        ok:true, email:sent.email, name:sent.full_name,
        roles:sent.roles, kind:'invite',
        link:'https://example.test/auth/v1/verify?token=ABC123',
        emailed:EMAILED, email_note:NOTE
      }), {status:200, headers:{'content-type':'application/json'}}));
    }
    return realFetch.apply(this, arguments);
  };
})();
""" % (json.dumps(payload), json.dumps(roles), json.dumps(emailed),
       json.dumps(email_note), ME, ME)


def open_page(b, payload, roles, emailed=True, email_note=""):
    pg = b.new_page(viewport={"width": 1280, "height": 1200})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.on("dialog", lambda d: d.accept())
    pg.add_init_script(stub(payload, roles, emailed, email_note))
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1200)
    return pg, errs


# --- guards -----------------------------------------------------------------
#  Every one of these exists because a suite that raises stops dead and hides
#  every assertion after it — which on THIS page includes whether an invite was
#  sent at all. A control that removes a step is exactly when the rest of the
#  file matters most.

def type_confirm(pg, value):
    if not pg.is_visible("#inv-confirm"):
        fails.append("the confirm box is not on screen when it should be — "
                     "a far-reaching role was chosen and the page did not ask twice")
        return False
    pg.fill("#inv-confirm", value)
    return True


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


def open_tile(pg, pid):
    sel = '#acc-list .acc-tile[data-id="%s"]' % pid
    if not pg.is_visible(sel):
        fails.append("no tile for %s to open" % pid)
        return False
    pg.click(sel)
    pg.wait_for_timeout(250)
    if not pg.is_visible("#acc-person-view"):
        fails.append("clicking a tile did not open that person's page")
        return False
    return True


def text(pg, sel):
    node = pg.query_selector(sel)
    return re.sub(r"\s+", " ", node.inner_text()) if node else ""


def tiles_text(pg):
    return " ".join(pg.eval_on_selector_all(
        "#acc-list .acc-tile", "els => els.map(e => e.innerText)"))


def calls(pg, name):
    return [c for c in pg.evaluate("window.__CALLS") if c["name"] == name]


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1. IT OPENS FOR AN ADMINISTRATOR, AS TILES
    # =====================================================================
    pg, errs = open_page(b, STAFF, ["admin"])
    check(pg.is_visible("#acc-panel"), "the access screen did not open for an administrator")
    n = len(pg.query_selector_all("#acc-list .acc-tile"))
    check(n == 5, "expected five staff tiles, drew %d" % n)

    #  A tile is a real button. A div with a click handler has no keyboard
    #  focus, no Enter, no Space and no role a screen reader announces.
    tags = pg.eval_on_selector_all("#acc-list .acc-tile", "els => els.map(e => e.tagName)")
    check(set(tags) == {"BUTTON"},
          "the tiles are not buttons, so they cannot be reached from a keyboard: %r" % tags)

    # =====================================================================
    #  11. IT TAKES THE WHOLE PAGE, AND KEEPS A WAY BACK
    # =====================================================================
    check(pg.evaluate("document.querySelector('.shell').classList.contains('wide-mode')"),
          "the page did not go full width for the staff list")
    check(not pg.is_visible(".brand"),
          "the brand panel is still taking half the page next to a list of people")
    check(pg.is_visible("#app-top"),
          "the page went full width but the bar carrying the way back did not appear")
    #  Hiding .brand takes the 'Back to the admin centre' link with it. If the
    #  bar did not replace it, the only way out would be closing the tab.
    check(pg.query_selector('#app-top a[href="../portals/"]') is not None,
          "THERE IS NO WAY BACK TO THE ADMIN CENTRE")
    check(pg.is_visible("#app-signout-top"), "there is no way to sign out")

    # =====================================================================
    #  3. PLAIN ENGLISH
    # =====================================================================
    joined = tiles_text(pg)
    check("hall_office" not in joined,
          "a raw role name is on screen — nobody in a masjid office should "
          "have to know what hall_office means: %r" % joined[:300])
    check("Hall bookings and nik" in joined, "the office role is not named in plain English")
    check("Everything" in joined, "the admin role is not named in plain English")
    check("Madrasah" in joined, "the teacher role is not named in plain English")
    check("No authenticator" in joined, "the account without two-step is not flagged")
    check("Two-step on" in joined, "accounts with two-step are not marked")

    # =====================================================================
    #  10a. A MISSING PHONE NUMBER IS VISIBLE FROM THE LIST
    # =====================================================================
    check("No phone number" in joined,
          "an account with no contact number looks the same as one with a "
          "number — which is how three administrators ended up without one: %r" % joined[:400])
    check("07700 900111" in joined, "the numbers that ARE on file are not shown")

    # =====================================================================
    #  4. A TILE OPENS THAT PERSON, AND THE LIST GOES AWAY
    # =====================================================================
    if open_tile(pg, MUB):
        check(not pg.is_visible("#acc-list-view"),
              "the list is still on screen behind the person's page")
        check("Mubaraq" in text(pg, "#pp-name"),
              "the wrong person's page opened: %r" % text(pg, "#pp-name"))
        check("mubaraq@example.test" in text(pg, "#pp-mail"),
              "the person's page does not show their email address")

        #  10b. and can be fixed from there.
        gap = text(pg, "#pp-contact-gap")
        check("no phone number" in gap.lower(),
              "the person's page does not say the number is missing: %r" % gap)
        check(pg.is_visible("#pp-edit-phone"),
              "there is nowhere to put the missing number in")

        #  The two-step warning, on the account that actually blocks migrations.
        signin = text(pg, "#pp-signin")
        check("blocks" in signin.lower(),
              "the page does not say WHY an account without two-step matters: %r" % signin)

        fill(pg, "#pp-edit-phone", "07700 900333")
        fill(pg, "#pp-edit-name", "Mubaraq Patel")
        click(pg, "#pp-save-contact")
        pg.wait_for_timeout(500)
        saved = calls(pg, "set_person_contact")
        check(len(saved) == 1, "the contact details were not saved: %r" % saved)
        if saved:
            a = saved[0]["args"]
            check(a.get("p_user") == MUB, "saved against the wrong person: %r" % a)
            check(a.get("p_phone") == "07700 900333", "the wrong number was saved: %r" % a)
            check(a.get("p_full_name") == "Mubaraq Patel", "the wrong name was saved: %r" % a)

        #  A number that is not a number must not reach the database. The
        #  database refuses it too — this is only so the person is told before
        #  a round trip.
        fill(pg, "#pp-edit-phone", "ring me")
        click(pg, "#pp-save-contact")
        pg.wait_for_timeout(300)
        check(len(calls(pg, "set_person_contact")) == 1,
              "'ring me' was sent to the database as a phone number")
        check("phone number" in text(pg, "#pp-error").lower(),
              "no useful message for a phone number that is not one: %r" % text(pg, "#pp-error"))

        click(pg, "#pp-back")
        pg.wait_for_timeout(250)
        check(pg.is_visible("#acc-list-view"), "the back button did not return to the list")

    # =====================================================================
    #  5. YOU CANNOT CHANGE YOUR OWN ACCESS
    # =====================================================================
    if open_tile(pg, ME):
        check(not pg.is_visible("#pp-roles-edit"),
              "YOUR OWN PAGE OFFERS TO CHANGE YOUR OWN ROLES — self-lockout and "
              "self-escalation are both one press away")
        check(pg.is_visible("#pp-roles-mine"),
              "your own page does not say why the roles cannot be changed")
        check("another administrator" in text(pg, "#pp-roles-mine").lower(),
              "it does not say who to ask: %r" % text(pg, "#pp-roles-mine"))
        check(pg.query_selector("#pp-access-acts button") is None,
              "your own page offers to suspend your own account")
        #  Contact details ARE editable on your own account, deliberately: a
        #  number is not a privilege. If this ever fails, somebody has applied
        #  the roles rule to the wrong thing.
        check(pg.is_visible("#pp-edit-phone"),
              "you cannot correct your own phone number without finding another "
              "administrator — a contact detail is not a privilege")
        click(pg, "#pp-back")
        pg.wait_for_timeout(200)


    # =====================================================================
    #  12. PASSWORDS
    #
    #  The single rule: an administrator can SEND a reset, never SET one.
    # =====================================================================
    if open_tile(pg, ME):
        check(pg.is_visible("#pp-pw-mine"),
              "there is no way to change your own password")
        check(not pg.is_visible("#pp-pw-theirs"),
              "your own page offers to send YOU a reset link")

        #  Too short, and it must not reach Supabase.
        fill(pg, "#pp-pw-new", "short")
        fill(pg, "#pp-pw-again", "short")
        click(pg, "#pp-pw-save")
        pg.wait_for_timeout(300)
        check(pg.evaluate("window.__PWCHANGE") is None,
              "a five-character password was sent to be saved")
        check("twelve" in text(pg, "#pp-error").lower(),
              "no useful message for a password that is too short: %r" % text(pg, "#pp-error"))

        #  Mistyped, and it must not reach Supabase either.
        fill(pg, "#pp-pw-new", "correct horse battery staple")
        fill(pg, "#pp-pw-again", "correct horse battery stapel")
        click(pg, "#pp-pw-save")
        pg.wait_for_timeout(300)
        check(pg.evaluate("window.__PWCHANGE") is None,
              "A MISTYPED PASSWORD WAS SAVED. They would be locked out of their "
              "own account by a typo they never saw")

        fill(pg, "#pp-pw-again", "correct horse battery staple")
        click(pg, "#pp-pw-save")
        pg.wait_for_timeout(400)
        got = pg.evaluate("window.__PWCHANGE")
        check(got and got.get("password") == "correct horse battery staple",
              "the password change never happened: %r" % got)
        check("authenticator" in text(pg, "#pp-ok").lower(),
              "it does not say the authenticator is unaffected: %r" % text(pg, "#pp-ok"))
        #  And it is not left sitting in the box afterwards.
        check(pg.input_value("#pp-pw-new") == "",
              "the new password is still on screen after it was changed")
        click(pg, "#pp-back")
        pg.wait_for_timeout(200)

    if open_tile(pg, TEACH):
        check(pg.is_visible("#pp-pw-theirs"),
              "there is no way to send somebody a reset link")
        check(not pg.is_visible("#pp-pw-mine"),
              "SOMEBODY ELSE'S PAGE HAS A PASSWORD BOX ON IT")

        #  The assertion this whole section exists for, made against the page
        #  rather than against one element: no visible password field anywhere
        #  on a page that is not your own.
        boxes = pg.eval_on_selector_all(
            "#acc-person-view input[type=password]",
            "els => els.filter(e => e.offsetParent !== null).length")
        check(boxes == 0,
              "there are %d password boxes on somebody else's page. An "
              "administrator must never be able to set a password they will "
              "then know" % boxes)

        why = text(pg, "#pp-pw-why").lower()
        check("cannot see or set" in why,
              "the page does not say why there is no password box: %r" % why)

        click(pg, "#pp-pw-send")
        pg.wait_for_timeout(700)
        sent = pg.evaluate("window.__RESET")
        check(sent is not None, "the reset never reached the function")
        if sent:
            check(sent.get("action") == "reset",
                  "the reset was not sent as a reset: %r" % sent)
            check(sent.get("email") == "teacher@example.test",
                  "the reset went to the wrong address: %r" % sent)
            #  A reset must not carry roles. If it did, it would be a quiet
            #  second route to changing what somebody can do.
            check(not sent.get("roles"),
                  "the reset carried roles with it: %r" % sent)

        shown = text(pg, "#pp-pw-result")
        check("emailed to teacher@example.test" in shown.lower(),
              "the page does not say the reset was emailed: %r" % shown)
        check("token=RESET9" in text(pg, "#pp-pw-url"),
              "the reset link is not on screen: %r" % text(pg, "#pp-pw-url"))

        # =================================================================
        #  13. THE MESSAGE SURVIVES THE REDRAW
        #
        #  Every save calls load(), which redraws the page. The first version
        #  cleared the messages and hid the reset link inside that redraw, so
        #  "saved" appeared and vanished in the same frame and the link
        #  flashed away before it could be copied. Drawing and resetting are
        #  two jobs.
        # =================================================================
        pg.wait_for_timeout(600)
        check(pg.is_visible("#pp-pw-result"),
              "THE RESET LINK DISAPPEARED when the page redrew")
        check("emailed" in text(pg, "#pp-ok").lower(),
              "the confirmation vanished when the page redrew: %r" % text(pg, "#pp-ok"))

        #  And the email address is where somebody would look for it.
        check(pg.input_value("#pp-edit-email") == "teacher@example.test",
              "the email address is not in the contact details")
        check(pg.eval_on_selector("#pp-edit-email", "e => e.readOnly") is True,
              "the email address is editable, which would put the sign-in and "
              "the record at different addresses")
        click(pg, "#pp-back")
        pg.wait_for_timeout(200)

    #  Contact details: the same redraw trap.
    if open_tile(pg, MUB):
        fill(pg, "#pp-edit-phone", "07700 900333")
        click(pg, "#pp-save-contact")
        pg.wait_for_timeout(700)
        check("saved" in text(pg, "#pp-ok").lower(),
              "'Contact details saved' vanished in the redraw that followed it: %r"
              % text(pg, "#pp-ok"))
        click(pg, "#pp-back")
        pg.wait_for_timeout(200)

    # =====================================================================
    #  6a. WITH THREE ADMINISTRATORS, SUSPENDING ONE IS OFFERED
    # =====================================================================
    if open_tile(pg, THIRD):
        btn = pg.query_selector('#pp-access-acts button[data-act="suspend"]')
        check(btn is not None and not btn.is_disabled(),
              "with three administrators, suspending one should be offered")
        click(pg, "#pp-back")
        pg.wait_for_timeout(200)

    #  Changing what somebody can do, from tick boxes rather than a text box
    #  asking for a comma-separated list, which is what this screen used to do.
    if open_tile(pg, TEACH):
        pg.check('.pp-r[value="hall_office"]')
        click(pg, "#pp-save-roles")
        pg.wait_for_timeout(500)
        rc = calls(pg, "set_person_roles")
        check(len(rc) == 1, "the roles were not saved: %r" % rc)
        if rc:
            got = sorted(rc[0]["args"].get("p_roles") or [])
            check(got == ["hall_office", "teacher"],
                  "the wrong roles were sent: %r" % got)
        click(pg, "#pp-back")
        pg.wait_for_timeout(200)
    check(errs == [], "uncaught exceptions: %s" % errs)
    pg.close()

    # =====================================================================
    #  6b. WITH ONLY TWO, IT IS NOT — AND ONLY FOR THE ADMINISTRATORS
    # =====================================================================
    pg, errs2 = open_page(b, TWO_ADMINS, ["admin"])
    if open_tile(pg, MUB):
        btn = pg.query_selector('#pp-access-acts button[data-act="suspend"]')
        check(btn is not None and btn.is_disabled(),
              "a Suspend button is live on one of the last two administrators")
        check("last two administrators" in text(pg, "#pp-access-note"),
              "the page does not say why it cannot be suspended: %r" % text(pg, "#pp-access-note"))
        click(pg, "#pp-back")
        pg.wait_for_timeout(200)
    #  The other half. Asserting only the line above would also "pass" a page
    #  that refused to suspend anybody at all, including the office account,
    #  who has nothing to do with the two-admin floor.
    if open_tile(pg, OFFICE):
        btn = pg.query_selector('#pp-access-acts button[data-act="suspend"]')
        check(btn is not None and not btn.is_disabled(),
              "the two-admin floor disabled Suspend on somebody who is not "
              "an administrator")
    check(errs2 == [], "uncaught exceptions with two administrators: %s" % errs2)
    pg.close()

    # =====================================================================
    #  7 + 8. THE INVITE
    # =====================================================================
    pg, errs = open_page(b, STAFF, ["admin"])
    click(pg, "#acc-invite-open")
    pg.wait_for_timeout(200)
    check(pg.is_visible("#acc-invite"), "the invite form did not open")
    check(not pg.is_visible("#inv-confirm-wrap"),
          "the confirm box is showing before anything far-reaching is chosen")

    #  8. NAME AND NUMBER ARE REQUIRED.
    fill(pg, "#inv-email", "newperson@example.test")
    pg.check('.inv-r[value="hall_office"]')
    click(pg, "#inv-send")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__INVITE") is None,
          "AN INVITATION WAS SENT WITH NO NAME — an account nobody can put a "
          "name to is no use at handover, which is the whole point of this")
    check("name" in text(pg, "#acc-error").lower(),
          "no useful message when the name is missing: %r" % text(pg, "#acc-error"))

    fill(pg, "#inv-name", "New Person")
    click(pg, "#inv-send")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__INVITE") is None,
          "AN INVITATION WAS SENT WITH NO CONTACT NUMBER")
    check("phone" in text(pg, "#acc-error").lower(),
          "no useful message when the number is missing: %r" % text(pg, "#acc-error"))

    fill(pg, "#inv-phone", "nought seven hundred")
    click(pg, "#inv-send")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__INVITE") is None,
          "an invitation was sent with something that is not a phone number")

    fill(pg, "#inv-phone", "07700 900123")

    #  7. THE LOUD PATH.
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
    #  unticked so the assertion below is about ONE role and says what it means.
    pg.uncheck('.inv-r[value="admin"]')
    pg.uncheck('.inv-r[value="hall_office"]')
    pg.check('.inv-r[value="teacher"]')
    pg.wait_for_timeout(150)
    check(pg.is_visible("#inv-confirm-wrap"),
          "granting the madrasah role does not ask twice — it reaches "
          "children's records")

    type_confirm(pg, "someoneelse@example.test")
    click(pg, "#inv-send")
    pg.wait_for_timeout(400)
    check(pg.evaluate("window.__INVITE") is None,
          "AN INVITE WAS SENT WITH THE CONFIRMATION TYPED WRONG")

    # =====================================================================
    #  9a. SENT BY EMAIL — AND THE LINK IS STILL SHOWN
    # =====================================================================
    type_confirm(pg, "newperson@example.test")
    click(pg, "#inv-send")
    pg.wait_for_timeout(800)

    sent = pg.evaluate("window.__INVITE")
    check(sent is not None, "the invite never reached the function")
    if sent:
        check(sent.get("email") == "newperson@example.test",
              "the wrong address was invited: %r" % sent)
        check(sent.get("full_name") == "New Person", "the name was not sent: %r" % sent)
        check(sent.get("phone") == "07700 900123", "the number was not sent: %r" % sent)
        check(sent.get("roles") == ["teacher"], "the wrong roles were sent: %r" % sent)
        check(sent.get("send_email") is True,
              "the 'email it to them' box was ticked and the request said otherwise")

    shown = text(pg, "#inv-result")
    check(pg.is_visible("#inv-result"), "nothing was shown after the invitation was made")
    check("emailed to newperson@example.test" in shown.lower(),
          "the page does not say the invitation was emailed: %r" % shown)
    #  The link is shown EVEN WHEN the email went. "They say it never arrived"
    #  is the commonest thing that happens next, and the answer to it should be
    #  on the screen rather than require making a second invitation.
    check("token=ABC123" in text(pg, "#inv-url"),
          "the link is not on screen when the email was sent: %r" % text(pg, "#inv-url"))
    check("authenticator" in shown.lower(),
          "the page does not explain that nothing is granted until they enrol")
    check(errs == [], "uncaught exceptions: %s" % errs)
    pg.close()

    # =====================================================================
    #  9b. NOT SENT — AND THE PAGE SAYS SO IN SO MANY WORDS
    #
    #  The failure this is written against: the screen saying "emailed" when
    #  nothing was sent, because the mail step answered 200. An administrator
    #  who believes one went will wait for a reply that never comes.
    # =====================================================================
    pg, errs = open_page(b, STAFF, ["admin"], emailed=False,
                         email_note="email is not set up on this site yet")
    click(pg, "#acc-invite-open")
    fill(pg, "#inv-name", "New Person")
    fill(pg, "#inv-email", "newperson@example.test")
    fill(pg, "#inv-phone", "07700 900123")
    pg.check('.inv-r[value="hall_office"]')
    click(pg, "#inv-send")
    pg.wait_for_timeout(800)

    shown = text(pg, "#inv-result")
    check("nothing was emailed" in shown.lower(),
          "THE PAGE DOES NOT SAY NO EMAIL WAS SENT: %r" % shown)
    check("not set up on this site yet" in shown.lower(),
          "the page does not say WHY nothing was emailed: %r" % shown)
    check("emailed to" not in shown.lower(),
          "the page claims it was emailed to somebody when it was not: %r" % shown)
    check("token=ABC123" in text(pg, "#inv-url"),
          "no email went AND the link is not on screen — the invitation is lost")
    check(errs == [], "uncaught exceptions when the email could not be sent: %s" % errs)

    #  Unticking the box must be honoured.
    click(pg, "#inv-done")
    click(pg, "#acc-invite-open")
    fill(pg, "#inv-name", "Second Person")
    fill(pg, "#inv-email", "second@example.test")
    fill(pg, "#inv-phone", "07700 900456")
    pg.check('.inv-r[value="hall_office"]')
    pg.uncheck("#inv-send-email")
    click(pg, "#inv-send")
    pg.wait_for_timeout(800)
    sent = pg.evaluate("window.__INVITE")
    check(sent and sent.get("send_email") is False,
          "the 'email it to them' box was UNTICKED and the request asked for an "
          "email anyway: %r" % sent)

    # =====================================================================
    #  AN INVITE WAITING IS NOT ACCESS
    # =====================================================================
    pend = text(pg, "#acc-pending")
    check("newcomer@example.test" in pend, "the pending invitation is not listed")
    check("New Comer" in pend, "the invited person's name is not shown")
    check("07700 900777" in pend, "the invited person's number is not shown")
    check("Not accepted yet" in pend, "the pending invitation is not marked as unaccepted")
    #  The pending list renders roles separately from the tiles, so it can drift
    #  into raw names on its own. A control on the tiles passed while this list
    #  was showing "hall_office" — the control is what found the gap.
    check("hall_office" not in pend,
          "a raw role name is in the pending invitations: %r" % pend)
    check("Hall bookings and nik" in pend,
          "the pending invitation does not name the role in plain English: %r" % pend)
    check("Nothing is granted until" in pend,
          "the page does not say an invitation grants nothing: %r" % pend)
    #  The pre-026 invitation, which the database will refuse.
    check("Missing a name or a number" in pend,
          "an invitation that cannot be claimed looks the same as one that can: %r" % pend)
    check("invite them again" in pend.lower(),
          "the page does not say what to do about it: %r" % pend)
    pg.close()

    # =====================================================================
    #  2. AN OFFICE ACCOUNT SEES NOTHING
    # =====================================================================
    pg, errs = open_page(b, {"allowed": False}, ["hall_office"])
    check(not pg.is_visible("#acc-panel"),
          "AN OFFICE ACCOUNT WAS SHOWN THE STAFF LIST")
    check(pg.is_visible("#app-noaccess"),
          "an office account is not told why it cannot see anything")
    check(pg.query_selector("#acc-list .acc-tile") is None,
          "staff tiles were drawn for an office account")
    #  The page must NOT go full width for somebody with nothing to show, or
    #  they get a blank wall where the masjid's own panel should be.
    check(not pg.evaluate("document.querySelector('.shell').classList.contains('wide-mode')"),
          "the page went full width for an account that can see nothing")
    check(errs == [], "uncaught exceptions for an office account: %s" % errs)
    pg.close()

    # =====================================================================
    #  IT SURVIVES A PHONE
    # =====================================================================
    pg, errs = open_page(b, STAFF, ["admin"])
    for w in [1600, 1280, 900, 390]:
        pg.set_viewport_size({"width": w, "height": 1000})
        pg.wait_for_timeout(250)
        check(pg.evaluate("document.documentElement.scrollWidth") <= w + 2,
              "the staff list scrolls sideways at %dpx" % w)
    #  And so does one person's page, which has a two-column grid in it.
    pg.set_viewport_size({"width": 1280, "height": 1000})
    pg.wait_for_timeout(200)
    if open_tile(pg, MUB):
        for w in [1280, 900, 390]:
            pg.set_viewport_size({"width": w, "height": 1000})
            pg.wait_for_timeout(250)
            check(pg.evaluate("document.documentElement.scrollWidth") <= w + 2,
                  "a person's page scrolls sideways at %dpx" % w)
    check(errs == [], "uncaught exceptions while resizing: %s" % errs)
    pg.close()

    # =====================================================================
    #  CONTROLS — do the assertions above actually bite?
    #
    #  Each of these breaks the page in one specific way and checks the
    #  matching assertion turns red. An unchecked control is worse than none,
    #  because it certifies. Two on this project passed for weeks while testing
    #  a string the built file never contained — so each one below also proves
    #  it changed something.
    # =====================================================================
    def control(name, script, before, after, setup=None):
        pg, _ = open_page(b, STAFF, ["admin"])
        #  `before` is called TWICE — once for the state, once to prove the
        #  script changed it — so anything that only makes sense once, like
        #  opening a person's page, belongs in `setup`. The first version put
        #  open_tile() inside `before`, and the second call went looking for a
        #  tile on a page that was already showing one person.
        if setup:
            setup(pg)
        was = before(pg)
        pg.evaluate(script)
        pg.wait_for_timeout(200)
        now = before(pg)
        if was == now:
            fails.append("CONTROL '%s' changed nothing on the page, so it proves "
                         "nothing" % name)
        elif not after(pg):
            fails.append("CONTROL '%s' did not bite — the matching assertion "
                         "would pass on a broken page" % name)
        pg.close()

    control("a tile that is a div, not a button",
            """(() => {
                 document.querySelectorAll('#acc-list .acc-tile').forEach(t => {
                   const d = document.createElement('div');
                   d.className = t.className; d.innerHTML = t.innerHTML;
                   t.replaceWith(d);
                 });
               })()""",
            lambda pg: pg.eval_on_selector_all("#acc-list .acc-tile",
                                               "els => els.map(e => e.tagName)"),
            lambda pg: set(pg.eval_on_selector_all(
                "#acc-list .acc-tile", "els => els.map(e => e.tagName)")) != {"BUTTON"})

    control("the way back removed from the bar",
            "document.querySelector('#app-top a').remove()",
            lambda pg: pg.query_selector('#app-top a[href="../portals/"]') is not None,
            lambda pg: pg.query_selector('#app-top a[href="../portals/"]') is None)

    control("the missing-phone warning removed from the tiles",
            "document.querySelectorAll('#acc-list .gap').forEach(e => e.remove())",
            tiles_text,
            lambda pg: "No phone number" not in tiles_text(pg))

    control("raw role names put back on the tiles",
            """(() => {
                 document.querySelectorAll('#acc-list .can').forEach(c => {
                   if (c.textContent.indexOf('Hall') === 0) c.textContent = 'hall_office';
                 });
               })()""",
            tiles_text,
            lambda pg: "hall_office" in tiles_text(pg))

    control("the incomplete flag removed from a pending invitation",
            "document.querySelectorAll('#acc-pending .no2fa').forEach(e => e.remove())",
            lambda pg: text(pg, "#acc-pending"),
            lambda pg: "Missing a name or a number" not in text(pg, "#acc-pending"))

    control("a password box put on somebody else's page",
            """(() => {
                 document.getElementById('pp-pw-mine').hidden = false;
                 document.getElementById('pp-pw-theirs').hidden = true;
               })()""",
            lambda pg: pg.eval_on_selector_all(
                "#acc-person-view input[type=password]",
                "els => els.filter(e => e.offsetParent !== null).length"),
            lambda pg: pg.eval_on_selector_all(
                "#acc-person-view input[type=password]",
                "els => els.filter(e => e.offsetParent !== null).length") > 0,
            setup=lambda pg: open_tile(pg, TEACH))

    control("the page kept in two columns",
            "document.querySelector('.shell').classList.remove('wide-mode')",
            lambda pg: pg.evaluate(
                "document.querySelector('.shell').classList.contains('wide-mode')"),
            lambda pg: pg.is_visible(".brand"))

    b.close()

httpd.shutdown()
print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
