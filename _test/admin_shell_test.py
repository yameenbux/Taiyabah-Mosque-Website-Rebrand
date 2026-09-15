"""The rail that appears on every staff screen.

15 September 2026. The Admin Centre had a list of every area a person could
open. The nine screens you reach FROM it had nothing — no logo, no navigation,
no way back but the browser's own back button — so the shape of the job was
"go to the Admin Centre, read the rail, click through, do the thing, press
back, read the rail again".

That matters because of who is about to be using these screens. The committee
will run this day to day and Yameen is meant to be a last resort, so a
volunteer treasurer who opens Gift Aid once a month cannot be expected to
remember how they got there.

WHAT THIS GUARDS

  *  1  EVERY STAFF SCREEN LOADS THE SHELL, and calls it. A page that links
        the stylesheet but never mounts looks exactly like a page that has no
        rail, and nothing else would notice.

  *  2  THE RAIL IS DRAWN FROM ROLES, and an account with no roles is offered
        nothing but the Admin Centre. This is a convenience and NOT a
        permission — it is JavaScript in the visitor's browser and anybody can
        change it — but a rail that offered a teacher the Gift Aid screen
        would still be wrong, and would still send them to a locked door.

  *  3  A GROUP WITH NO ROWS IS NOT DRAWN. An office account should get a
        shorter rail, not a rail full of empty headings, because empty
        headings read as a broken screen.

  *  4  EVERY DESTINATION EXISTS. A rail row pointing at a folder that was
        never built is a 404 with the masjid's logo on it.

  *  5  YOU CAN SEE WHERE YOU ARE. aria-current does the announcing and the
        gold edge does the showing. Without it the rail says where you can go
        and not where you are, which is half a map.

  *  6  THE LOGO IS IN THE TOP-LEFT CORNER AND ACTUALLY LOADS. It is the
        thing everybody clicks when they are lost, so a broken image there is
        worse than no image.

  *  7  THE DRAWER CANNOT SWALLOW THE KEYBOARD. Off-screen menus are the
        classic way a page becomes untabbable: the links are invisible but
        still focusable, so Tab walks into a menu nobody can see. A closed
        drawer here is visibility:hidden, which takes it out of the tab order
        as well as out of sight.

  *  8  ESCAPE CLOSES IT AND GIVES FOCUS BACK. Otherwise a keyboard user is
        left focused on something that is no longer on the screen.

Run:  python3 _test/admin_shell_test.py
"""
from playwright.sync_api import sync_playwright
import functools
import http.server
import os
import re
import socketserver
import sys
import threading

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/" % httpd.server_address[1]

fails = []


def check(ok, why):
    if not ok:
        fails.append(why)


#  folder -> the key it should mark as "you are here"
SCREENS = {
    "venue": "venue", "courses": "courses", "giftaid": "giftaid",
    "volunteers": "volunteers", "collections": "collections",
    "access": "access", "newbuild": "newbuild", "portal": "madrasah",
    "times": "times", "notices": "notices", "rates": "rates",
    "classpages": "classpages",
}

#  What each role should be offered. Deliberately written out rather than
#  computed from the same table the shell uses — a test that derives its
#  expectation from the code under test proves only that the code is
#  self-consistent.
EXPECTED = {
    "admin": ["Admin Centre", "Hall Hire & Nikāḥ", "Charity collections",
              "Adult classes", "What a class says", "Food Bank volunteers",
              "Gift Aid",
              "Notices", "Hall hire charges", "Prayer timetable",
              "Madrasah portal", "The new build page", "User access"],
    "hall_office": ["Admin Centre", "Hall Hire & Nikāḥ", "Charity collections"],
    "teacher": ["Admin Centre", "Madrasah portal"],
    "__none__": ["Admin Centre"],
}

# ---------------------------------------------------------------- 1. wiring
for d in SCREENS:
    html = open(f"{d}/index.html", encoding="utf-8").read()
    js = open(f"{d}/app.js", encoding="utf-8").read()
    check("admin/shell.css" in html, "%s/ does not link admin/shell.css" % d)
    check("admin/shell.js" in html, "%s/ does not load admin/shell.js" % d)
    check("AdminShell.mount" in js,
          "%s/app.js never calls AdminShell.mount, so the stylesheet loads and "
          "no rail is ever drawn — which looks exactly like having no rail" % d)
    #  Mounted from renderApp, which runs only once identity is known. If it
    #  ever moves somewhere that runs earlier, the rail would be drawn for
    #  somebody who is not signed in.
    m = re.search(r"function renderApp\(identity\)\s*\{(.{0,900})", js, re.S)
    check(m and "AdminShell.mount" in m.group(1),
          "%s/app.js calls AdminShell.mount from outside renderApp(identity). "
          "It must mount only after sign-in." % d)

# ------------------------------------------------------- 4. every link real
shell_js = open("admin/shell.js", encoding="utf-8").read()
for href in sorted(set(re.findall(r'href:\s*"([a-z/]+)"', shell_js))):
    folder = href.rstrip("/")
    check(os.path.isdir(folder) and os.path.exists(os.path.join(folder, "index.html")),
          "the rail offers %r and that folder has no index.html" % href)
check(os.path.exists("img/masjid-logo.png"),
      "img/masjid-logo.png is missing — the logo in the corner of every staff "
      "screen would be a broken image")

# ------------------------------------------- 9. the screen says what it is
#
#  Every staff screen is a COPY of another staff screen — that is how they are
#  made, they are standalone rather than templated. So the failure mode is not
#  a typo, it is a whole paragraph belonging to a different screen, and it
#  survives because the page works perfectly.
#
#  times/ shipped greeting people with "Gift Aid" over a paragraph about adult
#  classes, on the prayer-timetable page. Every other check passed: the rail
#  was right, the parser was right, the title tag was right, nothing threw.
#  The one person it would have confused is the volunteer it was built for.
for d in SCREENS:
    html = open(f"{d}/index.html", encoding="utf-8").read()
    title = re.search(r"<title>(.*?)\s*—", html, re.S)
    h1 = re.search(r"<h1>(.*?)</h1>", html, re.S)
    check(title and h1, "%s/ has no <title> or no <h1>" % d)
    if title and h1:
        t, h = title.group(1).strip(), h1.group(1).strip()
        check(t.lower() == h.lower(),
              "%s/ has <title> %r but greets people with <h1> %r. These pages "
              "are made by copying each other, so a heading from the screen it "
              "was copied from is the likeliest thing to be wrong here — and "
              "nothing else would ever notice." % (d, t, h))
        check(re.search(r"<h1>.*?</h1>\s*<p>(.*?)</p>", html, re.S) is not None,
              "%s/ has no paragraph under its heading" % d)

#  TWO SCREENS DESCRIBING THEMSELVES IDENTICALLY.
#
#  The first draft of this check looked for a word from the heading inside the
#  paragraph. It found the real bug and two false alarms — collections/ says
#  "Charities" where the heading says "Charity", and portal/ says "Pupils,
#  teachers, classes", which is unmistakably the madrasah without using the
#  word. A check that cries wolf twice for every genuine catch gets deleted,
#  and deleting it is the right response, so it is not worth having.
#
#  This is the sharp version of the same idea. When one of these pages is made
#  by copying another, the paragraph is carried over BYTE FOR BYTE — that is
#  what happened to times/, which described adult classes. Two identical
#  paragraphs on two different screens is not a heuristic. It cannot be a
#  coincidence, and one of the two is wrong.
seen_blurbs = {}
for d in SCREENS:
    html = open(f"{d}/index.html", encoding="utf-8").read()
    m = re.search(r"<h1>.*?</h1>\s*<p>(.*?)</p>", html, re.S)
    if not m:
        continue
    blurb = re.sub(r"\s+", " ", m.group(1)).strip()
    if blurb in seen_blurbs:
        check(False,
              "%s/ and %s/ introduce themselves with the SAME paragraph, word "
              "for word. These screens are made by copying each other, so one "
              "of the two is describing the wrong screen: %r"
              % (seen_blurbs[blurb], d, blurb[:110]))
    seen_blurbs[blurb] = d

#  A CLASS IN THE MARKUP THAT NOTHING STYLES AND NOTHING READS.
#
#  times/ shipped using .fld, .lede and .row — none of which it defined,
#  because it was cloned from giftaid/, which has no form on it. A
#  <label class="fld"> with no rules behind it is an inline label, so "Year"
#  and its box and "Paste the timetable" and ITS box all sat on one line,
#  three centimetres wide, on the screen the committee uses to set the
#  masjid's prayer times for a year.
#
#  EVERY TEST PASSED THE WHOLE TIME. The parser was exercised, the save
#  gating was exercised, the rail was checked at two widths, nothing
#  overflowed the viewport, every control had an accessible name and a big
#  enough tap target — and not one of those asks whether a form is READABLE.
#  A screenshot found it.
#
#  The JS is searched as well as the CSS, because some classes are selector
#  hooks rather than styles: access/ puts `inv-r` on a checkbox purely so
#  app.js can find it, and the visible styling comes from `.inv-role input`
#  on the parent. Those are correct and must not be reported.
SHARED = ""
for sheet in ("admin/shell.css", "admin/fonts.css"):
    if os.path.exists(sheet):
        SHARED += open(sheet, encoding="utf-8").read()

for d in SCREENS:
    html = open(f"{d}/index.html", encoding="utf-8").read()
    js = open(f"{d}/app.js", encoding="utf-8").read()
    css = "\n".join(re.findall(r"<style>(.*?)</style>", html, re.S)) + SHARED
    body = html[html.find("<body>"):]

    styled = set(re.findall(r"\.([A-Za-z][A-Za-z0-9_-]*)", css))
    #  app.js both builds markup and queries it, so a class it mentions at all
    #  is one somebody is using on purpose.
    in_js = set(re.findall(r"[A-Za-z][A-Za-z0-9_-]*", js))

    orphans = sorted({c for attr in re.findall(r'class="([^"]+)"', body)
                        for c in attr.split()
                        if c not in styled and c not in in_js})
    check(not orphans,
          "%s/ uses %s in its markup, and no stylesheet defines %s and no "
          "script reads %s. A class with no rules behind it is not a small "
          "cosmetic miss: an unstyled <label> is an INLINE label, which is "
          "how times/ came to render a year's prayer times into a box three "
          "centimetres wide with every test passing."
          % (d, ", ".join(repr(o) for o in orphans),
             "them" if len(orphans) > 1 else "it",
             "them" if len(orphans) > 1 else "it"))

MOUNT = """a => {
  const [key, title, roles] = a;
  AdminShell.mount({ current:key, title:title, roles:roles,
                     name:'Committee Member', email:'c@example.test' });
}"""

READ = """() => {
  const rail = document.querySelector('.ashell');
  if (!rail) return null;
  const logo = rail.querySelector('.ashell-top img');
  const cur  = rail.querySelector('[aria-current="page"]');
  const vw   = document.documentElement.clientWidth;
  let over = 0;
  const railHidden = getComputedStyle(rail).visibility === 'hidden';
  for (const el of document.body.querySelectorAll('*')) {
    const b = el.getBoundingClientRect();
    if (b.width === 0 && b.height === 0) continue;
    if (getComputedStyle(el).visibility === 'hidden') continue;
    if (railHidden && el.closest('.ashell')) continue;
    if (b.right > vw + 1) over++;
  }
  return {
    rows:   [...rail.querySelectorAll('.area .n')].map(n => n.textContent),
    labels: [...rail.querySelectorAll('.ashell-lab')].map(n => n.textContent),
    current: cur ? cur.querySelector('.n').textContent : null,
    logoOk: !!logo && logo.complete && logo.naturalWidth > 0,
    logoLeft: logo ? Math.round(logo.getBoundingClientRect().left) : -1,
    over: over
  };
}"""

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # ------------------------------------------- 2, 3, 5, 6 across the screens
    for d, key in SCREENS.items():
        for width in (1280, 360):
            pg = b.new_page(viewport={"width": width, "height": 880})
            errs = []
            pg.on("pageerror", lambda e: errs.append(str(e)[:120]))
            pg.goto(BASE + d + "/", wait_until="load", timeout=30000)
            pg.wait_for_timeout(700)
            pg.evaluate(MOUNT, [key, d, ["admin"]])
            pg.wait_for_timeout(450)
            r = pg.evaluate(READ)
            where = "%s/ @%dpx" % (d, width)

            check(r is not None, "%s: no rail was drawn at all" % where)
            if r:
                check(r["rows"] == EXPECTED["admin"],
                      "%s: rail rows are %r, expected %r" % (where, r["rows"], EXPECTED["admin"]))
                check(r["current"] is not None,
                      "%s: nothing is marked aria-current, so the rail does not "
                      "say where you are" % where)
                check(r["logoOk"], "%s: the logo did not load" % where)
                check(r["logoLeft"] < 80,
                      "%s: the logo is %dpx from the left edge, not in the corner"
                      % (where, r["logoLeft"]))
                check(r["over"] == 0,
                      "%s: %d element(s) run past the right edge with the rail up"
                      % (where, r["over"]))
            check(errs == [], "%s threw: %s" % (where, errs[:2]))
            pg.close()

    # --------------------------------------------- 2 and 3: the other roles
    pg = b.new_page(viewport={"width": 1280, "height": 880})
    pg.goto(BASE + "venue/", wait_until="load", timeout=30000)
    pg.wait_for_timeout(700)
    for role, want in EXPECTED.items():
        roles = [] if role == "__none__" else [role]
        pg.evaluate("() => { const r = document.querySelector('.ashell'); if (r) r.remove(); "
                    "const b = document.querySelector('.ashell-bar'); if (b) b.remove(); "
                    "const s = document.querySelector('.ashell-scrim'); if (s) s.remove(); "
                    "document.body.classList.remove('has-ashell'); }")
        pg.evaluate(MOUNT, ["venue", "Hall Hire", roles])
        pg.wait_for_timeout(200)
        r = pg.evaluate(READ)
        check(r["rows"] == want,
              "a %s account is offered %r, expected %r" % (role, r["rows"], want))
        #  No group may be drawn with nothing under it.
        check(len(r["labels"]) <= max(0, len(want) - 1),
              "a %s account sees headings %r for only %d row(s) — an empty "
              "heading reads as a broken screen" % (role, r["labels"], len(want) - 1))
    pg.close()

    # ------------------------------------------------ 7 and 8: the drawer
    pg = b.new_page(viewport={"width": 390, "height": 844})
    pg.goto(BASE + "venue/", wait_until="load", timeout=30000)
    pg.wait_for_timeout(700)
    pg.evaluate(MOUNT, ["venue", "Hall Hire", ["admin"]])
    pg.wait_for_timeout(400)

    shut = pg.evaluate("""() => {
      const rail = document.querySelector('.ashell');
      const a = rail.querySelector('a');
      a.focus();
      return { vis: getComputedStyle(rail).visibility,
               focusable: document.activeElement === a,
               expanded: document.querySelector('.ashell-burger').getAttribute('aria-expanded') };
    }""")
    check(shut["vis"] == "hidden",
          "the closed drawer is not visibility:hidden, so Tab can walk into a "
          "menu that is not on the screen")
    check(shut["focusable"] is False,
          "a link inside the CLOSED drawer took focus — that is the bug where "
          "Tab disappears into an invisible menu")
    check(shut["expanded"] == "false", "the burger claims to be expanded while shut")

    pg.click(".ashell-burger")
    pg.wait_for_timeout(400)
    op = pg.evaluate("""() => ({
        open: document.body.classList.contains('ashell-open'),
        vis: getComputedStyle(document.querySelector('.ashell')).visibility,
        expanded: document.querySelector('.ashell-burger').getAttribute('aria-expanded'),
        focusInRail: !!document.activeElement.closest('.ashell') })""")
    check(op["open"] and op["vis"] == "visible", "the burger did not open the drawer")
    check(op["expanded"] == "true", "aria-expanded was not updated on opening")
    check(op["focusInRail"], "opening the drawer did not move focus into it")

    pg.keyboard.press("Escape")
    pg.wait_for_timeout(400)
    esc = pg.evaluate("""() => ({
        open: document.body.classList.contains('ashell-open'),
        onBurger: document.activeElement.classList.contains('ashell-burger') })""")
    check(not esc["open"], "Escape did not close the drawer")
    check(esc["onBurger"],
          "Escape closed the drawer but left focus on something no longer "
          "visible, instead of returning it to the button")
    pg.close()
    b.close()

print("\n" + ("ALL PASS — %d staff screens x 2 widths, %d role sets, drawer"
              % (len(SCREENS), len(EXPECTED))
              if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails[:25])))
sys.exit(1 if fails else 0)
