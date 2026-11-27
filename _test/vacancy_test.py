"""The Vacancies application form, and the portal that reads it back.

26 November 2026.

WHAT THIS FILE IS FOR. The form's job is to send one correct object to one
RPC. Everything else about it — the layout, the four category tiles, the
wording — is visible the moment anybody looks at the page. What is NOT
visible, and what nobody would notice for months, is the form quietly
posting the wrong field names, or posting without consent, or sending
nothing at all because a validation message never appeared.

So the network request is intercepted and read. Section 4 is the one that
matters: the exact keys and values that reach apply_for_vacancy must match
the argument names in db/176_vacancy_applications.sql, because a misspelled
key does not error — it arrives as null and the application is simply
refused or, worse, stored wrong.

THE BROWSER CHECKS ARE NOT THE GUARANTEE. The contact-number rule, the
consent rule and the known-category rule are all CHECK constraints in 176 as
well. What is asserted here is that a real person gets told what is wrong
instead of a raw database error.

Mirrors _test/volunteer_test.py, the closest template on this site for a
public form with a staff-only portal behind it.

Run:  python3 _test/vacancy_test.py
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
BASE = "http://127.0.0.1:%d/" % httpd.server_address[1]

fails = []
sent = []          # every RPC body the page tried to send


def check(cond, msg):
    if not cond:
        fails.append(msg)


def fill(pg, name="Zainab Hussain", phone="07700 900 202",
         email="zainab@example.test", category="community_outreach",
         message="I have run community events before.", consent=True,
         member="yes"):
    """Put the form into a known state, or record a failure and return False.

    THE RETURN VALUE IS LOAD-BEARING — see volunteer_test.py's fill() for why:
    a successful submission hides the form, and a later fill() against an
    invisible field would hang the whole suite instead of failing one check.

    member defaults to "yes" so every test that is not specifically about
    the membership question gets past it — the same reason consent defaults
    to True.
    """
    if not pg.is_visible("#va-form"):
        fails.append("the form was not on screen when the test tried to fill "
                     "it — something earlier submitted it when it should not "
                     "have")
        return False
    pg.fill("#va-name", name)
    pg.fill("#va-phone", phone)
    pg.fill("#va-email", email)
    pg.fill("#va-message", message)
    if category:
        pg.check('input[name="va-category"][value="%s"]' % category)
    if member:
        pg.check('input[name="va-member"][value="%s"]' % member)
    box = pg.query_selector("#va-consent")
    if box and box.is_checked() != consent:
        box.click()
    return True


def submit(pg):
    """Press the button, or record a failure — same reason as fill()."""
    if not pg.is_visible("#va-submit"):
        fails.append("the submit button was not on screen — something earlier "
                     "sent an application that should have been refused")
        return False
    pg.click("#va-submit")
    return True


def problems(pg):
    node = pg.query_selector("#va-problems")
    return re.sub(r"\s+", " ", node.inner_text()) if node else ""


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    pg = b.new_page(viewport={"width": 1280, "height": 1000})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))

    # Intercept the RPC. Nothing in this suite may reach Supabase: the table
    # holds real people's phone numbers and a test must never write to it.
    def handle(route):
        req = route.request
        try:
            sent.append(json.loads(req.post_data or "{}"))
        except Exception:
            sent.append({"unparseable": req.post_data})
        route.fulfill(status=200, content_type="application/json",
                      body=json.dumps({"reference": "VA-26-0099", "already": False}))

    pg.route("**/rest/v1/rpc/apply_for_vacancy", handle)

    pg.goto(BASE, wait_until="load")
    pg.wait_for_timeout(900)
    pg.evaluate("() => showPage('svc-vacancies')")
    pg.wait_for_timeout(500)

    check(pg.is_visible("#va-form"), "the vacancy application form is not on the page")

    # =====================================================================
    #  1. WHAT THE PAGE TELLS PEOPLE BEFORE THEY FILL IT IN
    #
    #  Consent is the lawful basis for holding any of this, and the page says
    #  plainly that no role is actually open — the one thing an applicant
    #  must not be allowed to misread.
    # =====================================================================
    page = re.sub(r"\s+", " ", pg.eval_on_selector(".page.page-active", "e => e.innerText"))
    low = page.lower()
    check("coming soon" in low or "not open" in low or "no role" in low or "nothing is open" in low,
          "the Vacancies page does not say plainly that nothing is open yet: %r" % page[:400])
    check("12 months" in low or "twelve months" in low,
          "the page does not say how long the details are kept: %r" % page[:600])
    check("01204" in page, "the page gives no phone number for anybody who cannot use it")

    # =====================================================================
    #  2. THE TIME TRAP
    #
    #  The form refuses anything submitted within two seconds of the page
    #  loading. A real person cannot fill five fields that fast; a bot can.
    #
    #  Filling and submitting happen inside ONE evaluate() so the whole thing
    #  lands in a single tick — see volunteer_test.py's section 2 for why
    #  filling with Playwright first would prove nothing.
    # =====================================================================
    del sent[:]
    pg.goto(BASE, wait_until="load")
    pg.wait_for_timeout(250)
    elapsed = pg.evaluate("""() => {
        const t0 = performance.now();
        showPage('svc-vacancies');
        const set = (id, v) => { document.getElementById(id).value = v; };
        set('va-name', 'Quick Bot'); set('va-phone', '07700900888');
        set('va-email', 'bot@example.test'); set('va-message', '');
        document.querySelector('input[name="va-category"][value="education"]').checked = true;
        document.querySelector('input[name="va-member"][value="yes"]').checked = true;
        document.getElementById('va-consent').checked = true;
        document.getElementById('va-form')
          .dispatchEvent(new Event('submit', {cancelable: true, bubbles: true}));
        return performance.now() - t0;
    }""")
    pg.wait_for_timeout(300)
    check(elapsed < 1500,
          "the fill-and-submit took %dms, so it may not have been inside the "
          "two-second window at all — this section would prove nothing" % elapsed)
    check(sent == [],
          "A SUBMISSION WITHIN TWO SECONDS OF LOAD WAS SENT ANYWAY: %r" % sent)
    check(pg.is_visible("#va-done"),
          "the trap fired but the person was shown nothing at all")

    #  A bot must not learn it was caught, so the screen is the same thank-you
    #  a real application gets — but with no reference on it, because nothing
    #  was stored.
    check(pg.eval_on_selector("#va-doneRef", "e => e.innerText").strip() in ("—", "-", ""),
          "the honeypot screen shows a reference for an application that was "
          "never made")

    #  And the honeypot, which is the half that catches a patient bot.
    del sent[:]
    pg.reload(wait_until="load")
    pg.wait_for_timeout(900)
    pg.evaluate("() => showPage('svc-vacancies')")
    pg.wait_for_timeout(2300)          # past the trap
    fill(pg)
    pg.fill("#va-web", "http://spam.example")
    submit(pg)
    pg.wait_for_timeout(400)
    check(sent == [],
          "a submission with the honeypot filled in was still sent: %r" % sent)

    # =====================================================================
    #  3. WHAT A PERSON IS TOLD WHEN SOMETHING IS MISSING
    # =====================================================================
    del sent[:]
    pg.reload(wait_until="load")
    pg.wait_for_timeout(900)
    pg.evaluate("() => showPage('svc-vacancies')")
    pg.wait_for_timeout(2300)          # past the trap

    submit(pg)
    pg.wait_for_timeout(250)
    msg = problems(pg)
    check(sent == [], "an empty form was sent to the database: %r" % sent)
    check(msg != "", "an empty form produced no message at all")
    check("name" in msg.lower(), "an empty form does not mention the name: %r" % msg)

    #  Nothing picked is not a default — the office must know which of the
    #  four areas somebody actually meant. Checked HERE, on the still-fresh
    #  page, before any other call to fill() ever clicks a category radio —
    #  a radio button cannot be unchecked by clicking it again, so this test
    #  would prove nothing once one has already been picked.
    fill(pg, category=None)
    submit(pg)
    pg.wait_for_timeout(250)
    check(sent == [], "AN APPLICATION WITH NO AREA CHOSEN WAS SENT: %r" % sent)
    check("area" in problems(pg).lower(),
          "no area chosen gives no useful message: %r" % problems(pg))

    #  A phone number too short to ring must say so, not just refuse.
    #  Reloaded first: the category radio above is now checked, and this and
    #  the sub-tests after it are deliberately cumulative, same as
    #  volunteer_test.py's section 3.
    pg.reload(wait_until="load")
    pg.wait_for_timeout(900)
    pg.evaluate("() => showPage('svc-vacancies')")
    pg.wait_for_timeout(2300)          # past the trap
    fill(pg, phone="07700")
    submit(pg)
    pg.wait_for_timeout(250)
    msg = problems(pg)
    check(sent == [], "A PHONE NUMBER TOO SHORT TO RING WAS SENT: %r" % sent)
    check("reach you" in msg.lower(), "the short-phone message is not useful: %r" % msg)

    #  An email the masjid cannot reply to is a dead end for an office that
    #  only has an application to go on.
    fill(pg, phone="07700 900 202", email="not-an-email")
    submit(pg)
    pg.wait_for_timeout(250)
    check(sent == [], "AN INVALID EMAIL ADDRESS WAS SENT: %r" % sent)
    check("reply to" in problems(pg).lower(),
          "an invalid email gives no useful message: %r" % problems(pg))

    #  THE MANDATORY MEMBERSHIP QUESTION. Unanswered must refuse, exactly
    #  like no area chosen above — RELOADED FIRST, same reason: a radio
    #  cannot be unchecked by clicking it again, so testing "unanswered"
    #  after any earlier fill() has ever touched it would prove nothing.
    pg.reload(wait_until="load")
    pg.wait_for_timeout(900)
    pg.evaluate("() => showPage('svc-vacancies')")
    pg.wait_for_timeout(2300)          # past the trap
    fill(pg, member=None)
    submit(pg)
    pg.wait_for_timeout(250)
    check(sent == [], "AN APPLICATION WITH NO MEMBERSHIP ANSWER WAS SENT: %r" % sent)
    check("member" in problems(pg).lower() or "family" in problems(pg).lower(),
          "no membership answer gives no useful message: %r" % problems(pg))

    #  "No" is a real, considered answer, not a blank — it must refuse the
    #  same way. A radio CAN be changed to a different value in its own
    #  group, so no reload is needed for this one, and the form stays
    #  visible and filled either way: neither submission is a success.
    fill(pg, member="no")
    submit(pg)
    pg.wait_for_timeout(250)
    check(sent == [], "AN APPLICATION ANSWERED 'NO' TO MEMBERSHIP WAS SENT: %r" % sent)
    check("member" in problems(pg).lower() or "family" in problems(pg).lower(),
          "'No' to membership gives no useful message: %r" % problems(pg))

    #  Continues cumulatively, same as before this block — fill()'s own
    #  member="yes" default puts the radio back for every test from here on,
    #  the same way its category default already does.

    #  Applying without ticking the box has no lawful basis behind it.
    fill(pg, email="zainab@example.test", consent=False)
    submit(pg)
    pg.wait_for_timeout(250)
    check(sent == [], "AN APPLICATION WITH NO CONSENT WAS SENT: %r" % sent)
    check("agreement" in problems(pg).lower() or "consent" in problems(pg).lower(),
          "no consent gives no useful message: %r" % problems(pg))

    #  ...but what somebody wrote about themselves is NOT required. The
    #  categories are broad plans, not job specs with questions to answer —
    #  see db/176's own header.
    fill(pg, consent=True, message="")
    submit(pg)
    pg.wait_for_timeout(500)
    check(len(sent) == 1,
          "an application with no message was refused — it should not be: %r"
          % problems(pg))

    # =====================================================================
    #  4. THE REQUEST ITSELF
    #
    #  THE ASSERTION THIS FILE EXISTS FOR. These key names are the contract
    #  with apply_for_vacancy, redefined by 177 to add is_member_or_family —
    #  176 is read for the original keys since that text has not changed,
    #  177 for the new one. A misspelled key does not error anywhere: it
    #  arrives as null, and the application is refused or stored wrong,
    #  months before anybody looks.
    # =====================================================================
    body = sent[-1] if sent else {}
    payload = body.get("payload", {})
    check(isinstance(payload, dict) and payload,
          "the request has no payload object: %r" % body)

    sql = open("db/176_vacancy_applications.sql", encoding="utf-8").read()
    for key in ["masjid", "full_name", "phone", "email", "category",
                "message", "consent"]:
        check(key in payload, "the form does not send %r: %r" % (key, payload))
        check("payload->>'%s'" % key in sql,
              "THE FORM SENDS %r AND 176 NEVER READS IT" % key)

    sql177 = open("db/177_vacancy_postings.sql", encoding="utf-8").read()
    check("is_member_or_family" in payload,
          "the form does not send 'is_member_or_family': %r" % payload)
    check("payload->>'is_member_or_family'" in sql177,
          "THE FORM SENDS 'is_member_or_family' AND 177 NEVER READS IT")

    #  Sent FROM THE RADIO, not as a literal. A hard-coded true means "No"
    #  would still arrive as membership confirmed, and the database's
    #  va_membership_required constraint — the real backstop — accepts it.
    check(payload.get("is_member_or_family") is True,
          "membership did not reach the database as true: %r" % payload.get("is_member_or_family"))

    #  Sent FROM THE CHECKBOX, not as a literal. A hard-coded true means an
    #  unticked box still arrives as consent given, and the database's
    #  va_consent_required constraint — the real backstop — accepts it.
    check(payload.get("consent") is True,
          "consent did not reach the database as true: %r" % payload.get("consent"))
    #  Scoped to the vacancy form's own script, not the whole built page —
    #  the volunteer form just above it on this site carries a comment
    #  explaining this exact anti-pattern, and that comment's own words are
    #  "consent:true", which a whole-page search would catch as a false
    #  alarm. Same class of mistake CLAUDE.md's div-balance note warns about.
    src = open("index.html", encoding="utf-8").read()
    va_js = src[src.find("apply_for_vacancy"):]
    va_js = va_js[:va_js.find("})();")] if "})();" in va_js else va_js[:4000]
    check("consent: true" not in va_js and "consent:true" not in va_js,
          "THE FORM HARD-CODES consent:true IN THE PAYLOAD. An unticked box "
          "would then be stored as consent given, and the database constraint "
          "could never refuse it.")
    check(payload.get("category") == "community_outreach",
          "the category was not sent: %r" % payload.get("category"))

    #  The value has to be one 176's CHECK constraint accepts, or every
    #  application fails at the database with the browser none the wiser.
    check(payload.get("category") in
          ["administration", "education", "community_outreach", "event_management"],
          "%r was sent as a category, which 176 will refuse" % payload.get("category"))

    # =====================================================================
    #  5. AND THE PERSON IS TOLD IT WORKED
    # =====================================================================
    check(pg.is_visible("#va-done"), "a successful application showed no confirmation")
    check("VA-26-0099" in pg.eval_on_selector("#va-doneRef", "e => e.innerText"),
          "the reference from the database was not shown back")
    check(not pg.is_visible("#va-form"),
          "the form is still on screen after a successful application — it "
          "invites a second one")

    # =====================================================================
    #  6. THE PORTAL EXISTS AND IS LOCKED
    #
    #  The list is people's names, phone numbers, email addresses and what
    #  they wrote about themselves. Signed out, the page must show a sign-in
    #  screen and nothing else — and the admin rail must link to it, or the
    #  office will never find it.
    # =====================================================================
    pg2 = b.new_page(viewport={"width": 1280, "height": 1000})
    perrs = []
    pg2.on("pageerror", lambda e: perrs.append(str(e)[:200]))
    pg2.goto(BASE + "vacancy-applications/", wait_until="load")
    pg2.wait_for_timeout(1400)
    check(pg2.is_visible("#view-signin"),
          "the vacancy-applications portal does not show a sign-in screen when signed out")
    check(not pg2.is_visible("#va-panel"),
          "THE APPLICATION LIST IS VISIBLE WITHOUT SIGNING IN")
    check(perrs == [], "the vacancy-applications portal threw on load: %s" % perrs)

    #  THE OFFICE CAN FIND IT, AND ONLY THE OFFICE.
    #
    #  db/176's own header is explicit that this is recruitment — the
    #  committee's own decision — and not a rota the hall office already
    #  runs, unlike the Food Bank row just above it in admin/shell.js. See
    #  volunteer_test.py's section 6 for why this asks "is there a row, and
    #  does it admit the people who use it" rather than hard-coding a path.
    shell = open("admin/shell.js", encoding="utf-8").read()
    row = re.search(r'\{\s*key:\s*"vacancies".*?needs:\s*\[([^\]]*)\]', shell, re.S)
    check(row is not None,
          "admin/shell.js has no row for the vacancy-applications portal, so "
          "neither the Admin Centre nor any staff screen offers a way to "
          "reach it")
    if row:
        admits = set(re.findall(r'"([a-z_]+)"', row.group(1)))
        check(admits == {"admin"},
              "the vacancies row is offered to %r, but this screen admits "
              "admin only (vacancy-applications/app.js). Widening this to "
              "hall_office is a decision for db/176's header to record, not "
              "a default to fall into." % sorted(admits))

    check(errs == [], "uncaught exceptions: %s" % errs)
    b.close()

httpd.shutdown()
print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
