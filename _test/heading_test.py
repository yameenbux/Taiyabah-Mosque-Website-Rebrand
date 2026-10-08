"""Exactly one <h1> reaches a screen reader at a time.

8 October 2026, from an external code review. index.html has 31 literal
<h1> elements — one per page, all living in the same DOM at once, shown and
hidden by showPage(). Flagged as worth checking rather than assumed safe: a
screen reader's rotor walks the accessibility tree, not the raw DOM, and the
two only agree if every inactive page is actually excluded from that tree.

They do agree, and this is what proves it rather than asserts it. Playwright's
role locator (get_by_role) resolves against the same computed accessibility
tree a screen reader reads from — display:none and [hidden] ancestors
correctly drop their descendants from it, the same way they would for
VoiceOver or NVDA. This is the right proxy for that, not a replacement for
actually running one; nothing here drives a real screen reader.

WHAT THIS GUARDS

  On every one of the site's 30 navigable pages, exactly one heading with
  role=heading, level=1 is exposed to the accessibility tree — never zero
  (a page with no landmark heading) and never more than one (the fault this
  review raised: every hidden page's h1 leaking through at once).

Nothing here reaches Supabase. It serves the built index.html from a local
port and drives it.

Run:  python3 _test/heading_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, http.server, socketserver, threading, functools

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

# Every data-page target in index_template.html's nav, 404/privacy aside
# (privacy is included; it is reachable from the drawer like any other page).
PAGES = [
    "home", "newbuild", "prayer", "madrasah", "madrasah-admissions",
    "madrasah-holidays", "services", "contact", "articles",
    "article-five-pillars", "article-hajj", "article-ramadan",
    "article-what-is-islam", "media", "shop", "donate", "about",
    "collection", "volunteer", "privacy", "svc-advice", "svc-birth",
    "svc-bmd", "svc-edu-arabic", "svc-edu-ghusl", "svc-education",
    "svc-funeral", "svc-hallhire", "svc-marriage", "svc-will", "getapp",
]

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
    pg.wait_for_timeout(600)

    for name in PAGES:
        ok = pg.evaluate(f"""() => {{
            if (typeof showPage !== 'function') return false;
            showPage('{name}');
            return true;
        }}""")
        check(ok, f"{name}: showPage() is not defined — can't navigate to it")
        if not ok:
            continue
        pg.wait_for_timeout(200)

        exposed = [n for n in pg.get_by_role("heading", level=1).all() if n.is_visible()]
        check(len(exposed) == 1,
              f"{name}: {len(exposed)} <h1> elements reach the accessibility tree "
              f"at once (want exactly 1): {[n.inner_text().strip()[:50] for n in exposed]}")

    check(errs == [], "uncaught exceptions: %s" % errs)
    b.close()
httpd.shutdown()

print("\n" + (f"ALL PASS — {len(PAGES)} pages, exactly one accessible <h1> each" if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
