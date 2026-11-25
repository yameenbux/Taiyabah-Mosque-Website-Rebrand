"""/screens/ — the In-mosque displays picker and per-screen editor.

Written after a real mix-up: the Ramadan/Eid greeting used to be editable
from every one of the four screen tiles, including "Prayer hall" and
"Downstairs" — which run the timetable program and never show it. Editing
something with no visible effect on the screen you are looking at is exactly
the kind of thing CLAUDE.md calls out, so this locks in the fix: a foyer
screen's detail view can edit the appeal, the progress bar and the greeting;
a hall screen's detail view is the live preview and a plain note saying
there is nothing else here.

Run:  python3 _test/screens_test.py
"""
import functools
import http.server
import json
import os
import socketserver
import sys
import threading

from playwright.sync_api import sync_playwright

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % httpd.server_address[1]

fails = []


def check(name, cond, got=None):
    if not cond:
        fails.append("%s%s" % (name, ("   [%s]" % got) if got else ""))


FOYER_CONTENT = {
    "_instructions": "edit on github",
    "newBuild": {
        "eyebrow": "The New Build", "heading": "h", "tagline": "t", "phaseDescription": "d",
        "phaseTag": "Current appeal", "phaseTitle": "Internal fixtures",
        "needs": ["Tiling", "Carpets"],
        "timeline": [{"date": "2018", "title": "Phase 1", "status": "done"},
                     {"date": "now", "title": "Fixtures", "status": "active"},
                     {"date": "next", "title": "Full", "status": "upcoming"}],
        "progress": {"done": "Phases done", "now": "Now", "next": "Next"},
        "give": {"scanLabel": "Scan", "otherAmountUrl": "https://buy.stripe.com/abc123",
                 "giftAidNote": "n", "bankHeading": "h", "bank": {"accountName": "a"}, "note": "n"}
    },
    "occasions": {
        "ramadan": {"enabled": True, "title": "Ramadan Mubarak", "arabic": "ar", "message": "msg"},
        "eidFitr": {"enabled": False, "title": "", "arabic": "", "message": "", "durationDays": 3},
        "eidAdha": {"enabled": False, "title": "", "arabic": "", "message": "", "durationDays": 4}
    },
    "app": {"label": "Download our app"}
}

STUB = """
(function(){
  var client = {
    auth: {
      getSession: function(){ return Promise.resolve({data:{session:{access_token:'tok',
        user:{id:'u1', email:'admin@example.test'}}}}); },
      getUser: function(){ return Promise.resolve({data:{user:{id:'u1',
        email:'admin@example.test'}}}); },
      signOut: function(){ return Promise.resolve({}); },
      mfa: { getAuthenticatorAssuranceLevel: function(){
               return Promise.resolve({data:{currentLevel:'aal2', nextLevel:'aal2'}}); },
             listFactors: function(){ return Promise.resolve({data:{totp:[{id:'f1'}]}}); } }
    },
    from: function(t){
      var rows = t === 'profiles' ? {full_name:'Admin Person', email:'admin@example.test'} : [{role:'admin'}];
      var q = { select:function(){ return q; }, eq:function(){ return q; },
        maybeSingle:function(){ return Promise.resolve({data:rows, error:null}); },
        then:function(res){ return Promise.resolve({data:rows, error:null}).then(res); } };
      return q;
    }
  };
  Object.defineProperty(window, 'supabase', { value:{createClient:function(){return client;}}, writable:false, configurable:false });
})();
"""


def open_page(browser, width=1400, height=1000):
    pg = browser.new_page(viewport={"width": width, "height": height})
    pg.set_default_timeout(7000)
    pg.add_init_script(STUB)

    def handle_route(route):
        url = route.request.url
        if url.endswith("foyer-content.json"):
            route.fulfill(status=200, content_type="application/json", body=json.dumps(FOYER_CONTENT))
        elif "taiyabahscreens.ysbdesigns.uk" in url:
            route.fulfill(status=200, content_type="text/html", body="<!doctype html><html><body>stub</body></html>")
        else:
            route.continue_()

    pg.route("**/*", handle_route)
    pg.goto(BASE + "/screens/", wait_until="load")
    pg.wait_for_selector("#view-app:not([hidden])", timeout=10000)
    pg.wait_for_timeout(500)
    return pg


def run():
    with sync_playwright() as p:
        b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
        pg = open_page(b)

        check("the picker grid loads", pg.is_visible("#sc-grid"))

        # ------------------------------------------------- a foyer screen ----
        pg.click("#sc-tile-foyerLand")
        pg.wait_for_timeout(200)
        check("foyer fields show for a foyer screen", pg.is_visible("#sc-foyer-fields"))
        check("the Ramadan/Eid section shows for a foyer screen",
              pg.is_visible("#sc-occ-fields"))
        check("the hall note is hidden for a foyer screen",
              pg.is_hidden("#sc-hall-note"))
        check("the save/undo actions show for a foyer screen",
              pg.is_visible("#sc-actions"))
        check("the Ramadan/Eid sub-text says foyer-only, not shared across all four",
              "foyer screens only" in pg.inner_text("#sc-occ-fields"),
              pg.inner_text("#sc-occ-fields")[:120])
        pg.click("#sc-back")
        pg.wait_for_timeout(150)

        # -------------------------------------------------- a hall screen ----
        #  THE ACTUAL BUG. The office saw Ramadan/Eid controls on "Prayer
        #  hall — landscape" and assumed editing them did something there —
        #  it did not, the greeting was already foyer-only on the real TVs.
        pg.click("#sc-tile-hallLand")
        pg.wait_for_timeout(200)
        check("foyer fields are hidden for a hall screen", pg.is_hidden("#sc-foyer-fields"))
        check("the Ramadan/Eid section is hidden for a hall screen",
              pg.is_hidden("#sc-occ-fields"))
        check("the hall note is shown instead", pg.is_visible("#sc-hall-note"))
        check("the hall note says there is nothing to edit",
              "nothing on this screen to edit" in pg.inner_text("#sc-hall-note"),
              pg.inner_text("#sc-hall-note"))
        check("the save/undo actions are hidden for a hall screen",
              pg.is_hidden("#sc-actions"))
        check("the live preview still shows for a hall screen",
              pg.locator("#sc-detail-frame-slot iframe").count() == 1)

        body = pg.inner_text("#sc-detail")
        for leak in ["Ramadan", "Eid al-Fitr", "Eid al-Adha", "Submit changes"]:
            check("a hall screen's detail view does not mention %r" % leak,
                  leak not in body, body[:300])

        if fails:
            print("FAILURES (%d):" % len(fails))
            for f in fails:
                print(" -", f)
            sys.exit(1)
        print("ALL PASS")
        b.close()
    httpd.shutdown()


if __name__ == "__main__":
    run()
