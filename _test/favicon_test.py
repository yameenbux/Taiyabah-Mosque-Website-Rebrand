"""Every page has a usable tab icon, and the mark is drawn for 16px.

Written 7 September 2026. The site had one icon — the full logo lock-up as a
data URI on the home page only — which is illegible at tab size and which
Safari has never handled reliably. Six pages had no icon at all.
"""
from playwright.sync_api import sync_playwright
import sys, os, struct, http.server, socketserver, threading, functools

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), "..")); os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True
class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/" % httpd.server_address[1]

fails, errs = [], []
def check(c, m):
    if not c: fails.append(m)

# ---- the icon file itself, before any browser is involved ----------------
raw = open(os.path.join(ROOT, "favicon.ico"), "rb").read()
reserved, kind, count = struct.unpack("<HHH", raw[:6])
check(kind == 1, "favicon.ico is not an icon file (type %d)" % kind)
check(count >= 3, "favicon.ico carries %d size(s); 16, 32 and 48 are all used "
                  "in different places" % count)
sizes = sorted(struct.unpack("<BB", raw[6 + 16*i : 8 + 16*i])[0] for i in range(count))
check(sizes == [16, 32, 48], "sizes in favicon.ico are %s" % sizes)

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1280, "height": 900})
    pg.on("pageerror", lambda e: errs.append(str(e)))

    # ---- the file is actually served, and so is the manifest ----
    for path in ["favicon.ico", "site.webmanifest", "apple-touch-icon.png",
                 "icon-192.png", "icon-512.png"]:
        r = pg.request.get(BASE + path)
        check(r.status == 200, "%s does not resolve (%d)" % (path, r.status))

    man = pg.request.get(BASE + "site.webmanifest").json()
    check(man.get("name") == "Taiyabah Masjid", "the manifest names the site wrongly")
    check(man.get("theme_color") == "#3C0B2A", "the manifest is not in the masjid's colours")
    check(any(i.get("purpose") == "maskable" for i in man.get("icons", [])),
          "no maskable icon, so Android crops the home screen icon badly")

    # ---- every page declares one. Six of these had nothing at all. ----
    for path in ["index.html", "404.html", "account/", "portal/", "portals/",
                 "venue/", "courses/", "giftaid/", "apply/"]:
        pg.goto(BASE + path); pg.wait_for_timeout(250)
        icons = pg.eval_on_selector_all(
            'link[rel~="icon"]', "els=>els.map(e=>e.getAttribute('href'))")
        check(len(icons) >= 1, "%s declares no icon at all" % path)
        touch = pg.eval_on_selector_all(
            'link[rel="apple-touch-icon"]', "els=>els.length")
        check(touch >= 1, "%s has no apple-touch-icon" % path)

    # ---- the home page keeps the data URI as well as the file ----
    pg.goto(BASE + "index.html"); pg.wait_for_timeout(300)
    hrefs = pg.eval_on_selector_all('link[rel~="icon"]', "els=>els.map(e=>e.getAttribute('href'))")
    check(any(h.startswith("data:image/png") for h in hrefs),
          "the data-URI icon is gone, so the site loses its icon over file://")
    check(any(h == "/favicon.ico" for h in hrefs),
          "no /favicon.ico declared, so Safari and bookmarks get nothing")
    check(pg.eval_on_selector_all('link[rel="manifest"]', "e=>e.length") == 1,
          "the home page does not link the web manifest")
    b.close()

httpd.shutdown()
print("JS errors:", errs or "none")
print("FAILURES:", len(fails))
for f in fails: print("  -", f)
sys.exit(1 if (fails or errs) else 0)
