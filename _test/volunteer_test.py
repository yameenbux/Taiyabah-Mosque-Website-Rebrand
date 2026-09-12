"""The food bank volunteer form, and the portal that reads it back.

12 September 2026.

WHAT THIS FILE IS FOR. The form's job is to send one correct object to one
RPC. Everything else about it — the layout, the wording, the radio buttons —
is visible the moment anybody looks at the page. What is NOT visible, and what
nobody would notice for months, is the form quietly posting the wrong field
names, or posting an under-16, or sending nothing at all because a validation
message never appeared.

So the network request is intercepted and read. Section 4 is the one that
matters: the exact keys and values that reach register_foodbank_volunteer must
match the argument names in db/023_foodbank_volunteers.sql, because a
misspelled key does not error — it arrives as null and the registration is
simply refused or, worse, stored wrong.

THE BROWSER CHECKS ARE NOT THE GUARANTEE. The under-16 rule, the consent
rule and the contactable-by-the-method-you-chose rule are all CHECK
constraints in 023 as well, proved by db/_test_volunteers.sql. What is
asserted here is that a real person gets told what is wrong instead of a raw
database error.

Run:  python3 _test/volunteer_test.py
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


def fill(pg, name="Aisha Patel", phone="07700 900 101", email="",
         gender="female", age="34", pref="text", sun="yes", freq="weekly",
         skills="Driver", consent=True):
    """Put the form into a known state, or record a failure and return False.

    THE RETURN VALUE IS LOAD-BEARING. A successful submission hides the form,
    so if an earlier assertion fails in a way that lets a bad registration
    through, every later fill() would sit waiting for an invisible field until
    Playwright's timeout — and the suite would hang instead of reporting. That
    has happened on this project enough times to be a rule: a suite that stops
    early hides every assertion after the first fault, which is exactly when
    you most need the rest of them.
    """
    if not pg.is_visible("#vol-form"):
        fails.append("the form was not on screen when the test tried to fill "
                     "it — something earlier submitted it when it should not "
                     "have")
        return False
    pg.fill("#vol-name", name)
    pg.fill("#vol-phone", phone)
    pg.fill("#vol-email", email)
    pg.fill("#vol-age", age)
    pg.fill("#vol-skills", skills)
    for group, value in [("vol-gender", gender), ("vol-pref", pref),
                         ("vol-sun", sun), ("vol-freq", freq)]:
        if value:
            pg.check('input[name="%s"][value="%s"]' % (group, value))
    box = pg.query_selector("#vol-consent")
    if box and box.is_checked() != consent:
        box.click()
    return True


def submit(pg):
    """Press the button, or record a failure. Same reason as fill(): after a
    successful registration the button is gone, and clicking a hidden element
    stops the whole suite rather than failing one assertion."""
    if not pg.is_visible("#vol-submit"):
        fails.append("the submit button was not on screen — something earlier "
                     "sent a registration that should have been refused")
        return False
    pg.click("#vol-submit")
    return True


def problems(pg):
    node = pg.query_selector("#vol-problems")
    return re.sub(r"\s+", " ", node.inner_text()) if node else ""


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    pg = b.new_page(viewport={"width": 1280, "height": 1000})
    pg.set_default_timeout(4000)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))

    # Intercept the RPC. Nothing in this suite may reach Supabase: the table
    # holds real people's mobile numbers and a test must never write to it.
    def handle(route):
        req = route.request
        try:
            sent.append(json.loads(req.post_data or "{}"))
        except Exception:
            sent.append({"unparseable": req.post_data})
        route.fulfill(status=200, content_type="application/json",
                      body=json.dumps({"reference": "FV-26-0007", "already": False}))

    pg.route("**/rest/v1/rpc/register_foodbank_volunteer", handle)

    pg.goto(BASE, wait_until="load")
    pg.wait_for_timeout(900)
    pg.evaluate("() => showPage('volunteer')")
    pg.wait_for_timeout(500)

    check(pg.is_visible("#vol-form"), "the volunteer form is not on the page")

    # =====================================================================
    #  1. WHAT THE PAGE TELLS PEOPLE BEFORE THEY FILL IT IN
    #
    #  Consent is the lawful basis for holding any of this, so the page has
    #  to say what it is keeping, for how long, and how to get out.
    # =====================================================================
    page = re.sub(r"\s+", " ", pg.eval_on_selector(".page.page-active", "e => e.innerText"))
    low = page.lower()
    check("12 months" in low or "twelve months" in low,
          "the page does not say how long the details are kept: %r" % page[:400])
    check("16" in page,
          "the page does not state the minimum age anywhere")
    check("rota" in low,
          "the page asks for gender without saying why — under Article 5(1)(c) "
          "every field needs a reason and the person filling it in should see it")
    check("privacy" in low, "the page does not link to the privacy notice")
    check("01204" in page, "the page gives no phone number for anybody who cannot use it")

    consent_label = pg.eval_on_selector("#vw_consent", "e => e.innerText").lower()
    check("twelve months" in consent_label or "12 months" in consent_label,
          "the consent wording does not say how long: %r" % consent_label)

    # =====================================================================
    #  2. THE TIME TRAP
    #
    #  The form refuses anything submitted within two seconds of the page
    #  loading. A real person cannot fill nine fields that fast; a bot can.
    #
    #  THE FIRST VERSION OF THIS SECTION WAS WRONG AND PASSED ANYWAY. It
    #  filled the form with Playwright, which takes well over two seconds on
    #  its own, so the submission was never inside the window and the test
    #  proved nothing about the trap — it recorded the ordinary path and
    #  called it a trap. Filling and submitting now happen inside ONE
    #  evaluate() so the whole thing lands in a single tick, a few hundred
    #  milliseconds after load.
    # =====================================================================
    del sent[:]
    pg.goto(BASE, wait_until="load")
    pg.wait_for_timeout(250)
    elapsed = pg.evaluate("""() => {
        const t0 = performance.now();
        showPage('volunteer');
        const set = (id, v) => { document.getElementById(id).value = v; };
        set('vol-name', 'Quick Bot'); set('vol-phone', '07700900999');
        set('vol-age', '30'); set('vol-skills', '');
        document.querySelector('input[name="vol-gender"][value="male"]').checked = true;
        document.querySelector('input[name="vol-pref"][value="phone"]').checked = true;
        document.querySelector('input[name="vol-sun"][value="yes"]').checked = true;
        document.querySelector('input[name="vol-freq"][value="weekly"]').checked = true;
        document.getElementById('vol-consent').checked = true;
        document.getElementById('vol-form')
          .dispatchEvent(new Event('submit', {cancelable: true, bubbles: true}));
        return performance.now() - t0;
    }""")
    pg.wait_for_timeout(300)
    check(elapsed < 1500,
          "the fill-and-submit took %dms, so it may not have been inside the "
          "two-second window at all — this section would prove nothing" % elapsed)
    check(sent == [],
          "A SUBMISSION WITHIN TWO SECONDS OF LOAD WAS SENT ANYWAY: %r" % sent)
    check(pg.is_visible("#vol-done"),
          "the trap fired but the person was shown nothing at all")

    #  A bot must not learn it was caught, so the screen is the same thank-you
    #  a real registration gets — but with no reference on it, because nothing
    #  was stored.
    check(pg.eval_on_selector("#vol-doneRef", "e => e.innerText").strip() in ("\u2014", "-", ""),
          "the honeypot screen shows a reference for a registration that was "
          "never made")

    #  And the honeypot, which is the half that catches a patient bot.
    del sent[:]
    pg.reload(wait_until="load")
    pg.wait_for_timeout(900)
    pg.evaluate("() => showPage('volunteer')")
    pg.wait_for_timeout(2300)          # past the trap
    fill(pg)
    pg.fill("#vol-web", "http://spam.example")
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
    pg.evaluate("() => showPage('volunteer')")
    pg.wait_for_timeout(2300)          # past the trap

    submit(pg)
    pg.wait_for_timeout(250)
    msg = problems(pg)
    check(sent == [], "an empty form was sent to the database: %r" % sent)
    check(msg != "", "an empty form produced no message at all")
    check("name" in msg.lower(), "an empty form does not mention the name: %r" % msg)

    #  An under-16 must be told what to do instead, not just refused.
    fill(pg, age="14")
    submit(pg)
    pg.wait_for_timeout(250)
    msg = problems(pg)
    check(sent == [], "A FOURTEEN-YEAR-OLD'S DETAILS WERE SENT: %r" % sent)
    check("16" in msg, "the under-16 message does not say what the rule is: %r" % msg)
    check("parent" in msg.lower(),
          "an under-16 is refused with no route to take instead: %r" % msg)

    #  Choosing email and giving no email address is a volunteer nobody can
    #  reach. The database refuses it; the person should be told first.
    fill(pg, age="34", pref="email", email="")
    submit(pg)
    pg.wait_for_timeout(250)
    check(sent == [], "email-preferred with no address was sent: %r" % sent)
    check("email" in problems(pg).lower(),
          "choosing email without an address gives no useful message: %r" % problems(pg))

    #  Registering without ticking the box has no lawful basis behind it.
    fill(pg, pref="phone", email="", consent=False)
    submit(pg)
    pg.wait_for_timeout(250)
    check(sent == [], "A REGISTRATION WITH NO CONSENT WAS SENT: %r" % sent)
    check("agreement" in problems(pg).lower() or "consent" in problems(pg).lower(),
          "no consent gives no useful message: %r" % problems(pg))

    #  ...but an email address is NOT required of somebody who asked for a
    #  phone call. Requiring one would turn away the people most likely to
    #  have a free Sunday morning.
    fill(pg, pref="phone", email="", consent=True)
    submit(pg)
    pg.wait_for_timeout(500)
    check(len(sent) == 1,
          "a phone-preferred registration with no email was refused — it "
          "should not be: %r" % problems(pg))

    # =====================================================================
    #  4. THE REQUEST ITSELF
    #
    #  THE ASSERTION THIS FILE EXISTS FOR. These key names are the contract
    #  with register_foodbank_volunteer in 023. A misspelled key does not
    #  error anywhere: it arrives as null, and the registration is refused or
    #  stored wrong, months before anybody looks.
    # =====================================================================
    body = sent[-1] if sent else {}
    payload = body.get("payload", {})
    check(isinstance(payload, dict) and payload,
          "the request has no payload object: %r" % body)

    sql = open("db/023_foodbank_volunteers.sql", encoding="utf-8").read()
    for key in ["full_name", "phone", "email", "gender", "age",
                "preferred_contact", "sunday_mornings", "frequency",
                "skills", "consent"]:
        check(key in payload, "the form does not send %r: %r" % (key, payload))
        check("payload->>'%s'" % key in sql or "'%s'" % key in sql,
              "THE FORM SENDS %r AND 023 NEVER READS IT" % key)

    #  Sent FROM THE CHECKBOX, not as a literal. A hard-coded true means an
    #  unticked box still arrives as consent given, and the database's
    #  fbv_consent_required constraint — the real backstop — accepts it. The
    #  first version of this form did exactly that, and a negative control on
    #  this file is what caught it.
    check(payload.get("consent") is True,
          "consent did not reach the database as true: %r" % payload.get("consent"))
    src = open("index.html", encoding="utf-8").read()
    check("consent: true" not in src,
          "THE FORM HARD-CODES consent:true IN THE PAYLOAD. An unticked box "
          "would then be stored as consent given, and the database constraint "
          "could never refuse it.")
    check(payload.get("sunday_mornings") is True,
          "'Yes' to Sunday mornings was not sent as a boolean true: %r"
          % payload.get("sunday_mornings"))
    check(payload.get("age") == 34,
          "age was not sent as a number: %r" % payload.get("age"))
    check(payload.get("preferred_contact") == "phone",
          "the contact method was not sent: %r" % payload.get("preferred_contact"))

    #  The values have to be ones 023's CHECK constraints accept, or every
    #  registration fails at the database with the browser none the wiser.
    for field, allowed in [("gender", ["male", "female"]),
                           ("preferred_contact", ["phone", "text", "email"]),
                           ("frequency", ["weekly", "fortnightly", "monthly"])]:
        check(payload.get(field) in allowed,
              "%r was sent as %r, which 023 will refuse" % (field, payload.get(field)))

    # =====================================================================
    #  5. AND THE PERSON IS TOLD IT WORKED
    # =====================================================================
    check(pg.is_visible("#vol-done"), "a successful registration showed no confirmation")
    check("FV-26-0007" in pg.eval_on_selector("#vol-doneRef", "e => e.innerText"),
          "the reference from the database was not shown back")
    check(not pg.is_visible("#vol-form"),
          "the form is still on screen after a successful registration — it "
          "invites a second one")

    # =====================================================================
    #  6. THE PORTAL EXISTS AND IS LOCKED
    #
    #  The list is people's names, ages and mobile numbers. Signed out, the
    #  page must show a sign-in screen and nothing else — and the admin hub
    #  must link to it, or the office will never find it.
    # =====================================================================
    pg2 = b.new_page(viewport={"width": 1280, "height": 1000})
    perrs = []
    pg2.on("pageerror", lambda e: perrs.append(str(e)[:200]))
    pg2.goto(BASE + "volunteers/", wait_until="load")
    pg2.wait_for_timeout(1400)
    check(pg2.is_visible("#view-signin"),
          "the volunteers portal does not show a sign-in screen when signed out")
    check(not pg2.is_visible("#vol-panel"),
          "THE VOLUNTEER LIST IS VISIBLE WITHOUT SIGNING IN")
    check(perrs == [], "the volunteers portal threw on load: %s" % perrs)

    hub = open("portals/app.js", encoding="utf-8").read()
    check('"../volunteers/"' in hub,
          "the admin centre does not link to the volunteers portal, so the "
          "office has no way to find it")

    check(errs == [], "uncaught exceptions: %s" % errs)
    b.close()

httpd.shutdown()
print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
