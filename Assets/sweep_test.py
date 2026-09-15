"""Every page, every viewport — the checks no other file makes.

15 September 2026. The other files in here each guard one thing well: the
nikāḥ form, the donate links, the collection page, type size and contrast.
Nothing walked the WHOLE site looking for the ordinary faults that do not
belong to any one feature, so this does.

WHAT IT GUARDS, AND WHY EACH ONE IS HERE

  *  1  NOTHING THROWS. A JavaScript error on page nine stops every script
        that was going to run after it, including the one that submits a
        form. The site is one document with thirty-three pages in it, so an
        error thrown while looking at the madrasah page can break the donate
        button without anybody connecting the two.

  *  2  NOTHING 404s. A missing image is a broken page to a visitor and
        invisible to everybody else, because the page still renders.

  *  3  NO SIDEWAYS SCROLL, AND THIS IS THE SUBTLE ONE. `body` carries
        `overflow-x: hidden`, which does not FIX horizontal overflow — it
        HIDES it. Content wider than the screen is then silently cut off
        instead of visibly scrolling. So this measures elements against the
        viewport rather than asking whether the page scrolls, because the
        page has been told not to.

  *  4  NO DUPLICATE IDs. Thirty-three pages in one document share one id
        namespace. getElementById returns the first match, so a second
        element with the same id means a script quietly operates on the wrong
        one, on a page the author was not looking at.

  *  5  EVERY CONTROL HAS A NAME. A button whose only content is an icon is
        an unlabelled button to a screen reader, and this masjid's own brief
        was that the site must work for people with poor vision.

  *  6  EVERY IMAGE HAS an alt ATTRIBUTE. Empty is fine and correct for
        decoration; absent is not, because a screen reader then reads the
        file name out loud.

  *  7  EVERY INPUT HAS A LABEL. A form that cannot be filled in by somebody
        using a screen reader is a form that quietly excludes them.

  *  8  TAP TARGETS ARE BIG ENOUGH ON A PHONE. WCAG 2.2 asks for 24x24 CSS
        pixels. The masjid asked for a site that works for its older
        congregation, and a 19-pixel button fails them before the text size
        ever becomes the problem.

Inline links inside prose are deliberately exempt from 8 — WCAG exempts them
too, and lifting every sentence's line height to make room would undo the
typography work rather than help it.

Run:  python3 _test/sweep_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, re, http.server, socketserver, threading, functools

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PORT = httpd.server_address[1]
BASE = "http://127.0.0.1:%d/" % PORT

fails = []


def check(ok, why):
    if not ok:
        fails.append(why)


PAGES = sorted(set(re.findall(r'<div class="page" data-page="([a-z0-9-]+)"',
                              open("index_template.html", encoding="utf-8").read())))

#  Every folder that is served with its own index.html — the staff screens.
#  Read from the filesystem so one added later is covered without anybody
#  remembering to come back here.
FOLDERS = sorted(d for d in os.listdir(ROOT)
                 if os.path.isdir(d) and os.path.exists(os.path.join(d, "index.html"))
                 and not d.startswith((".", "_")))

VIEWPORTS = [(360, 780), (768, 1000), (1280, 900), (1920, 1080)]

#  Hosts this machine cannot reach. The sandbox refuses them, and their
#  failure says nothing about the page. Everything served out of this
#  repository must load. Note "upabase.co" and not "supabase": the URL
#  reaches us truncated to its last 70 characters.
OFFSITE = ("upabase.co", "ytimg.com", "youtube.com", "gstatic", "googleapis")

#  A minimum tap target, in CSS pixels. WCAG 2.2 Success Criterion 2.5.8.
MIN_TARGET = 24

OVERFLOW = """
() => {
  const vw = document.documentElement.clientWidth;
  const out = [];
  const page = document.querySelector('.page.page-active') || document.body;
  for (const el of page.querySelectorAll('*')) {
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') continue;
    //  An element deliberately placed in its own scroller is allowed to be
    //  wider than the screen — that is what the scroller is for.
    let inScroller = false;
    for (let p = el.parentElement; p; p = p.parentElement) {
      const pcs = getComputedStyle(p);
      if (pcs.overflowX === 'auto' || pcs.overflowX === 'scroll') { inScroller = true; break; }
    }
    if (inScroller) continue;
    //  Parked off-screen on purpose: the spam honeypot lives at -9999px, and
    //  so does anything else a developer has deliberately pushed out of the
    //  way. Something at -9999px is not a layout fault; something at -30px is.
    if (r.right < -1000) continue;
    //  Decorative bleed. The girih corner marks are 200px ornaments at 5%
    //  opacity, positioned -30px into the corner ON PURPOSE and marked
    //  pointer-events:none. A decoration that runs off the edge is a design,
    //  not a defect; anything a visitor can actually touch is still checked.
    if (cs.pointerEvents === 'none') continue;
    if (r.right > vw + 1 || r.left < -1) {
      out.push({ tag: el.tagName.toLowerCase(),
                 //  getAttribute, NOT .className. On an SVG element className
                 //  is an SVGAnimatedString object, and stringifying it gives
                 //  "[object SVGAnimatedString]" for every shape on the page.
                 cls: (el.getAttribute('class') || '').slice(0, 60),
                 left: Math.round(r.left), right: Math.round(r.right) });
    }
  }
  return out.slice(0, 6);
}
"""

CONTROLS = """
() => {
  const page = document.querySelector('.page.page-active') || document.body;
  const named = [], small = [];
  const sel = 'a, button, [role="button"], summary, input[type="submit"]';
  for (const el of page.querySelectorAll(sel)) {
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) continue;
    const cs = getComputedStyle(el);
    if (cs.visibility === 'hidden' || cs.display === 'none') continue;

    const name = (el.getAttribute('aria-label') || el.getAttribute('title') ||
                  el.textContent || '').replace(/\\s+/g, ' ').trim() ||
                 [...el.querySelectorAll('img[alt]')].map(i => i.alt).join(' ').trim();
    if (!name && el.getAttribute('aria-hidden') !== 'true') {
      named.push({ tag: el.tagName.toLowerCase(),
                   cls: (el.getAttribute('class') || '').slice(0, 60),
                   html: el.outerHTML.slice(0, 90) });
    }

    //  Inline links inside a paragraph are exempt, as they are in WCAG.
    const inProse = el.tagName === 'A' &&
      !!el.closest('p, li, dd, .cf-note, .ga-more, small, label');
    if (!inProse && (r.width < %d || r.height < %d)) {
      small.push({ tag: el.tagName.toLowerCase(),
                   cls: (el.getAttribute('class') || '').slice(0, 60),
                   w: Math.round(r.width), h: Math.round(r.height),
                   name: name.slice(0, 30) });
    }
  }
  return { named: named.slice(0, 5), small: small.slice(0, 5) };
}
""" % (MIN_TARGET, MIN_TARGET)

FIELDS = """
() => {
  const page = document.querySelector('.page.page-active') || document.body;
  const out = [];
  for (const el of page.querySelectorAll('input, select, textarea')) {
    const t = (el.getAttribute('type') || '').toLowerCase();
    if (t === 'hidden') continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) continue;
    const labelled = !!(el.getAttribute('aria-label') ||
                        el.getAttribute('aria-labelledby') ||
                        (el.id && document.querySelector('label[for="' + CSS.escape(el.id) + '"]')) ||
                        el.closest('label'));
    if (!labelled) {
      out.push({ tag: el.tagName.toLowerCase(), type: t,
                 name: el.getAttribute('name') || '(no name)',
                 id: el.id || '(no id)' });
    }
  }
  return out.slice(0, 5);
}
"""

IMAGES = """
() => {
  const page = document.querySelector('.page.page-active') || document.body;
  return [...page.querySelectorAll('img')]
    .filter(i => !i.hasAttribute('alt'))
    .slice(0, 5)
    .map(i => ({ src: (i.getAttribute('src') || '').slice(-60) }));
}
"""

DUPLICATE_IDS = """
() => {
  const seen = new Map(), dup = [];
  for (const el of document.querySelectorAll('[id]')) {
    const id = el.id;
    if (seen.has(id)) { if (!dup.includes(id)) dup.push(id); }
    else seen.set(id, true);
  }
  return dup.slice(0, 12);
}
"""

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  THE MAIN SITE — every page, every viewport
    # =====================================================================
    for width, height in VIEWPORTS:
        pg = b.new_page(viewport={"width": width, "height": height})
        errs, bad_req = [], []
        pg.on("pageerror", lambda e: errs.append(str(e)[:140]))
        pg.on("console",
              lambda m: errs.append("console.error: " + m.text[:120])
              if m.type == "error" else None)
        pg.on("requestfailed",
              lambda r: bad_req.append((r.url, "%s %s" % (r.failure, r.url[-70:]))))
        pg.on("response",
              lambda r: bad_req.append((r.url, "HTTP %d %s" % (r.status, r.url[-70:])))
              if r.status >= 400 else None)

        pg.goto(BASE + "index.html", wait_until="load")
        pg.wait_for_timeout(1400)

        #  Once per run, not once per viewport: the id namespace is a property
        #  of the document, not of how wide the window is.
        if width == VIEWPORTS[0][0]:
            for d in pg.evaluate(DUPLICATE_IDS):
                fails.append("DUPLICATE id in the document: #%s — "
                             "getElementById will silently pick the first" % d)

        for name in PAGES:
            pg.evaluate("""n => { const a=document.querySelector('[data-nav="'+n+'"]');
                                  if(a) a.click(); else if(window.showPage) showPage(n); }""",
                        name)
            pg.wait_for_timeout(230)
            where = "%s @%dpx" % (name, width)

            for o in pg.evaluate(OVERFLOW):
                check(False, "%s: <%s class=%r> runs from %dpx to %dpx, past the "
                             "%dpx viewport — body{overflow-x:hidden} hides this, "
                             "it does not fix it"
                             % (where, o["tag"], o["cls"], o["left"], o["right"], width))

            c = pg.evaluate(CONTROLS)
            for n in c["named"]:
                check(False, "%s: a <%s class=%r> has no accessible name — %s"
                             % (where, n["tag"], n["cls"], n["html"]))
            if width == 360:
                for s in c["small"]:
                    check(False, "%s: tap target %dx%d is under %dpx — <%s class=%r> %r"
                                 % (where, s["w"], s["h"], MIN_TARGET,
                                    s["tag"], s["cls"], s["name"]))

            if width == VIEWPORTS[0][0]:
                for f in pg.evaluate(FIELDS):
                    check(False, "%s: <%s type=%s name=%s> has no label"
                                 % (where, f["tag"], f["type"], f["name"]))
                for im in pg.evaluate(IMAGES):
                    check(False, "%s: <img src=...%s> has no alt attribute"
                                 % (where, im["src"]))

        #  This machine cannot reach Supabase or YouTube's thumbnail CDN --
        #  the sandbox refuses those hosts -- and their failure says nothing
        #  about the page. Everything served from this repository must load.
        #  MATCH ON THE WHOLE URL, DISPLAY ONLY THE TAIL. The first version
        #  tested OFFSITE against the truncated string, which works right up
        #  until a request carries a query longer than seventy characters —
        #  the notices fetch does — and then the host has been cut off before
        #  the filter ever sees it. One Supabase call was then reported as a
        #  broken link on every page at every width, which is a test that has
        #  started lying rather than a page that has started failing.
        local_bad  = [shown for url, shown in sorted(set(bad_req))
                      if not any(o in url for o in OFFSITE)]
        real_errs  = [e for e in errs
                      if "ERR_TUNNEL_CONNECTION_FAILED" not in e
                      and "Failed to fetch" not in e
                      and "NetworkError" not in e
                      and not any(o in e for o in OFFSITE)]
        check(real_errs == [], "@%dpx the main site threw: %s" % (width, real_errs[:4]))
        check(local_bad == [], "@%dpx the main site requested something that failed: %s"
                             % (width, local_bad[:4]))
        pg.close()

    # =====================================================================
    #  THE STAFF SCREENS
    #
    #  These sit behind a sign-in, so what loads is the sign-in state. That
    #  is still the state every member of staff sees first, and a script that
    #  throws here never gets as far as asking for a password.
    # =====================================================================
    for folder in FOLDERS:
        pg = b.new_page(viewport={"width": 1280, "height": 900})
        errs, bad_req = [], []
        pg.on("pageerror", lambda e: errs.append(str(e)[:140]))
        pg.on("console",
              lambda m: errs.append("console.error: " + m.text[:120])
              if m.type == "error" else None)
        pg.on("requestfailed",
              lambda r: bad_req.append((r.url, "%s %s" % (r.failure, r.url[-70:]))))
        pg.on("response",
              lambda r: bad_req.append((r.url, "HTTP %d %s" % (r.status, r.url[-70:])))
              if r.status >= 400 else None)
        try:
            pg.goto(BASE + folder + "/", wait_until="load", timeout=20000)
            pg.wait_for_timeout(1100)
        except Exception as e:
            check(False, "%s/ did not load: %s" % (folder, str(e)[:90]))
            pg.close()
            continue

        #  A network call to Supabase cannot succeed from a test machine, and
        #  its failure is not a fault in the page. Everything else is.
        #  Same rule as the main site: this machine cannot reach Supabase,
        #  and the URL arrives truncated to its last 70 characters, so the
        #  leading "s" of "supabase" is often already gone.
        local_bad = [shown for url, shown in sorted(set(bad_req))
                     if not any(o in url for o in OFFSITE)]
        real_errs = [e for e in errs
                     if "ERR_TUNNEL_CONNECTION_FAILED" not in e
                     and "Failed to fetch" not in e and "NetworkError" not in e
                     and not any(o in e for o in OFFSITE)]
        check(real_errs == [], "%s/ threw on load: %s" % (folder, real_errs[:3]))
        check(local_bad == [], "%s/ requested something that failed: %s"
                               % (folder, local_bad[:3]))
        pg.close()

    b.close()

print("\n" + ("ALL PASS — %d pages x %d viewports, %d staff screens"
              % (len(PAGES), len(VIEWPORTS), len(FOLDERS))
              if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails[:40])))
sys.exit(1 if fails else 0)
