"""The Food Bank card on the home page, and what it replaced.

12 September 2026. The third card in the home page's glance row used to be
"Quick Links" — Shop, Services, Madrasah, Contact. The committee wanted a
Taiyabah Food Bank announcement there instead.

THE RISK IN THIS CHANGE IS NOT THE NEW CARD, IT IS THE OLD ONE. Deleting a
block of navigation is safe only for as long as every link in it survives
somewhere else. That was true on the day it was removed — all four are in the
top bar, the mobile menu and the footer — and it would stop being true the
first time somebody tidies the footer. Section 2 is what notices.

Section 3 is the other half: the card announces something that does not exist
yet, so it must not look like something you can open.

Run:  python3 _test/foodbank_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, re, http.server, socketserver, threading, functools

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


def check(cond, msg):
    if not cond:
        fails.append(msg)


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    pg = b.new_page(viewport={"width": 1280, "height": 900})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:160]))
    pg.goto(BASE, wait_until="load")
    pg.wait_for_timeout(900)

    # =====================================================================
    #  1. THE CARD IS THERE AND SAYS WHAT IT PROMISED TO SAY
    # =====================================================================
    check(pg.is_visible(".glance-foodbank"), "the Food Bank card is not on the home page")
    txt = re.sub(r"\s+", " ", pg.eval_on_selector(".glance-foodbank", "e => e.innerText"))

    check("Taiyabah Food Bank" in txt.title() or "TAIYABAH FOOD BANK" in txt.upper(),
          "the card does not carry the name: %r" % txt)
    check("Coming soon" in txt.title() or "COMING SOON" in txt.upper(),
          "the card does not say Coming soon: %r" % txt)

    # The committee has not agreed a scheme. Until they have, the card must not
    # say what the masjid will hand out, to whom, or when — a line on the home
    # page is a promise, and a promise the masjid cannot keep costs more than
    # an empty slot would have.
    low = txt.lower()
    for word in ["parcel", "voucher", "every week", "weekly", "free food",
                 "open ", "opens", "opening", "referral"]:
        check(word not in low,
              "THE CARD COMMITS THE MASJID TO SOMETHING NOBODY HAS AGREED — "
              "it contains %r: %r" % (word, txt))

    # =====================================================================
    #  2. NOTHING BECAME UNREACHABLE
    #
    #  The four links that were in this slot. Counted OUTSIDE the glance row,
    #  because finding them in the card that replaced them would prove
    #  nothing.
    # =====================================================================
    for nav in ["shop", "services", "madrasah", "contact"]:
        n = pg.evaluate(
            "n => document.querySelectorAll('[data-nav=\"' + n + '\"]').length "
            "  - document.querySelectorAll('.glance-row [data-nav=\"' + n + '\"]').length",
            nav)
        check(n > 0,
              "REMOVING QUICK LINKS ORPHANED %r — it is no longer linked from "
              "anywhere outside the glance row" % nav)

    # A menu can exist in the markup and be unreachable on screen. Check the
    # top bar specifically, since that is the route most visitors take.
    for nav in ["shop", "services", "madrasah", "contact"]:
        check(pg.evaluate(
            "n => !!document.querySelector('nav [data-nav=\"' + n + '\"]')", nav),
            "%r is missing from the main navigation" % nav)

    # =====================================================================
    #  3. THE CARD LEADS EXACTLY ONE PLACE
    #
    #  Until 12 September 2026 this section asserted the OPPOSITE: that
    #  nothing on the card was clickable, because there was nothing behind
    #  it. There is now — a volunteer registration form — so the assertion
    #  has been turned round rather than deleted. What it guards is the same
    #  thing either way: the card must not offer a tap that goes nowhere.
    #
    #  The card itself is still not a link. "Coming soon" and "Register as a
    #  volunteer" are two different statements and only one of them leads
    #  anywhere; making the whole card tappable would merge them.
    # =====================================================================
    check(not pg.evaluate("""() => {
        const c = document.querySelector('.glance-foodbank');
        if (!c) return true;
        return c.matches('a, [data-nav], [data-scroll-to], [onclick], button');
    }"""),
        "the whole Food Bank card is clickable — only the volunteer link "
        "should be")
    check(pg.eval_on_selector(".glance-foodbank", "e => getComputedStyle(e).cursor") != "pointer",
          "the Food Bank card shows a pointer cursor")

    links = pg.eval_on_selector_all(
        ".glance-foodbank a, .glance-foodbank [data-nav], .glance-foodbank button",
        "els => els.map(e => ({nav: e.getAttribute('data-nav'), "
        "text: (e.innerText||'').trim(), href: e.getAttribute('href')}))")
    check(len(links) == 1,
          "expected exactly one link on the Food Bank card, found %d: %r"
          % (len(links), links))
    if links:
        check((links[0]["nav"] or "") == "volunteer",
              "the card's link does not point at the volunteer page: %r" % links[0])
        check("volunteer" in (links[0]["text"] or "").lower(),
              "the card's link does not say what it is for: %r" % links[0])

    #  A link to a page that does not exist is the failure this whole section
    #  is about, so follow it rather than trusting the attribute.
    pg.click(".glance-foodbank a[data-nav='volunteer']")
    pg.wait_for_timeout(600)
    check(pg.evaluate("document.querySelector('.page.page-active').dataset.page") == "volunteer",
          "clicking the card's link did not open the volunteer page")
    check(pg.is_visible("#vol-form"),
          "the volunteer page opened but has no form on it")

    pg.evaluate("() => showPage('home')")
    pg.wait_for_timeout(400)

    # =====================================================================
    #  4. THE DRAWING
    #
    #  Inline SVG, not an image file: it has to survive being inlined into a
    #  single-file build, and it has to be described for a screen reader.
    # =====================================================================
    art = pg.query_selector(".glance-foodbank .fb-art svg")
    check(art is not None, "the card has no illustration")
    if art is not None:
        box = art.bounding_box()
        check(box and box["width"] > 120 and box["height"] > 80,
              "the illustration is barely drawn: %r" % box)
        check((art.get_attribute("aria-label") or "").strip() != "",
              "the illustration has no aria-label, so a screen reader reads nothing")

    #  The crescent is a circle with a second circle masked out of it. If the
    #  mask ever stops resolving — a renamed id, a duplicate id somewhere else
    #  on the 650KB single-file build, a build step that rewrites ids — the
    #  browser draws the circle UNMASKED. No error, no warning: the moon
    #  silently becomes a plum dot, and the only way anyone finds out is by
    #  looking at the home page.
    check(pg.evaluate("""() => {
        const c = document.querySelector('.glance-foodbank .fb-art svg circle[mask]');
        if (!c) return false;
        const m = (c.getAttribute('mask') || '').match(/url\\(#([^)]+)\\)/);
        if (!m) return false;
        const els = document.querySelectorAll('[id="' + m[1] + '"]');
        return els.length === 1 && els[0].tagName.toLowerCase() === 'mask';
    }"""),
        "THE CRESCENT'S MASK DOES NOT RESOLVE — the moon renders as a solid "
        "plum circle and nothing errors")

    # Dead CSS is how a file rots. The Quick Links rules went with the card.
    css = open("index.html", encoding="utf-8").read()
    for cls in [".gl-link", ".gl-ic", ".gl-text", ".gl-arrow"]:
        check(cls not in css,
              "%s is still in the stylesheet with nothing using it" % cls)

    # =====================================================================
    #  5. THE ROW STILL WORKS AT THE WIDTHS PEOPLE USE
    # =====================================================================
    for w in [1280, 1024, 760, 390]:
        pg.set_viewport_size({"width": w, "height": 900})
        pg.wait_for_timeout(250)
        check(pg.evaluate("document.documentElement.scrollWidth") <= w + 2,
              "the home page scrolls sideways at %dpx" % w)
        bb = pg.query_selector(".glance-foodbank").bounding_box()
        check(bb and bb["height"] > 200,
              "the Food Bank card has collapsed at %dpx: %r" % (w, bb))
        soon = pg.query_selector(".glance-foodbank .fb-soon").bounding_box()
        check(soon and soon["width"] > 60,
              "'Coming soon' has no size at %dpx: %r" % (w, soon))

    check(errs == [], "uncaught exceptions: %s" % errs)
    b.close()

httpd.shutdown()
print("\n" + ("ALL PASS" if not fails else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
