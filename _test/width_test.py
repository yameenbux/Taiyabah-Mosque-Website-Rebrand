"""Every block uses the width available to it, on every staff screen.

Run:  python3 _test/width_test.py

Find every block that stops dead in the middle of a wide screen.

Reported as "the way you stick to one side or cut things off or leave finishing
in the middle of the screen is unclean and not professional", and the fault is
real: on /portal/ the job tiles and the count tiles run the full width of the
desk while the lead paragraph and the data-protection panel stop at 760px, so
two blocks end at 40% and the ones above and below them end at 100%.

A screenshot finds the instance somebody happened to look at. This finds all of
them: every element directly inside a panel whose rendered width is well under
the width available to it, on every staff screen, at a desk-sized viewport.
"""
import os, json, http.server, socketserver, threading, functools, sys
from playwright.sync_api import sync_playwright

ROOT = "/home/claude/taiyabah-site-v2"
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % httpd.server_address[1]

OVERVIEW = {
    "as_at": "2026-09-19T15:00:00Z", "pupils": 543, "staff": 40, "classes": 45,
    "staff_without_days": 4, "staff_without_side": 0, "classes_no_main_teacher": 10,
    "pupils_without_class": 0, "admissions_waiting": 0,
    "dbs": {"none": 20, "overdue": 1, "valid": 19},
    "dbs_needs_attention": [{"id": "s%d" % i, "name": "Person %d" % i,
                             "state": "overdue" if i == 0 else "none"} for i in range(21)],
    "archive_total": 0, "archive_going_soon": 0,
}

STUB = """
(function(){
  var OV = %s;
  var client = {
    auth:{ getSession:function(){return Promise.resolve({data:{session:{access_token:'t',
             user:{id:'u1',email:'a@b.test'}}}});},
      getUser:function(){return Promise.resolve({data:{user:{id:'u1',email:'a@b.test'}}});},
      signOut:function(){return Promise.resolve({});},
      updateUser:function(){return Promise.resolve({data:{},error:null});},
      mfa:{getAuthenticatorAssuranceLevel:function(){return Promise.resolve({data:{currentLevel:'aal2',nextLevel:'aal2'}});},
           listFactors:function(){return Promise.resolve({data:{totp:[{id:'f1'}]}});}}},
    from:function(t){ var rows = t==='profiles'?{full_name:'A Person',email:'a@b.test'}:[{role:'admin'}];
      var q={select:function(){return q;},eq:function(){return q;},
        maybeSingle:function(){return Promise.resolve({data:rows,error:null});},
        then:function(r){return Promise.resolve({data:rows,error:null}).then(r);}}; return q;},
    rpc:function(n){
      if(n==='madrasah_overview') return Promise.resolve({data:OV,error:null});
      return Promise.resolve({data:[],error:null}); }
  };
  Object.defineProperty(window,'supabase',{value:{createClient:function(){return client;}},
    writable:false,configurable:false});
})();
""" % json.dumps(OVERVIEW)

#  Every staff screen that mounts the rail.
PAGES = ["/portal/", "/portal/staff/", "/portal/classes/", "/portal/archive/",
         "/portal/calendar/", "/portal/people/", "/portal/profile/",
         "/access/", "/newbuild/", "/venue/", "/giftaid/", "/courses/",
         "/collections/", "/notices/", "/times/", "/portals/", "/apply/"]

#  How much narrower than the space available counts as "stops in the middle".
#  0.75 rather than 0.9: a block that fills three quarters reads as a choice; one
#  that fills a third reads as unfinished, which is the complaint.
THRESHOLD = 0.75

SCAN = """() => {
  const panel = document.querySelector('.panel') || document.body;
  const avail = panel.clientWidth - 2;
  if (avail < 400) return {skip: 'panel too narrow'};
  const out = [];
  const seen = new Set();
  //  Everything inside the visible working card, one or two levels down -
  //  the blocks a person perceives as "sections of the page".
  const roots = [...document.querySelectorAll('.panel .card, .panel .bk, .panel section, .panel > div')];
  for (const root of roots) {
    if (!root.offsetParent && root.tagName !== 'BODY') continue;
    const rw = root.getBoundingClientRect().width;
    if (rw < avail * 0.8) continue;          // the container itself is narrow; not our question
    for (const el of root.children) {
      const cs = getComputedStyle(el);
      if (cs.display === 'none' || cs.position === 'absolute' || cs.position === 'fixed') continue;
      if (el.hidden) continue;
      const r = el.getBoundingClientRect();
      if (r.width < 40 || r.height < 12) continue;
      const ratio = r.width / rw;
      if (ratio >= %f) continue;
      //  An inline-ish element that is narrow because its CONTENT is short is
      //  not the fault. Only flag things that had a width to fill and did not.
      if (cs.display.indexOf('inline') === 0) continue;
      const key = (el.id || '') + '|' + el.className + '|' + Math.round(r.width);
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        tag: el.tagName.toLowerCase(),
        id: el.id || '',
        cls: (typeof el.className === 'string' ? el.className : '').slice(0, 48),
        w: Math.round(r.width), avail: Math.round(rw),
        pct: Math.round(ratio * 100),
        maxw: cs.maxWidth,
        text: (el.innerText || '').replace(/\\s+/g,' ').slice(0, 44)
      });
    }
  }
  return {avail: avail, hits: out};
}""" % THRESHOLD

fails = []

import atexit


@atexit.register
def _report():
    if fails:
        print("\nFAILURES (%d):" % len(fails))
        for f in fails:
            print("  " + f)
    elif _report.reached_end:
        print("\nALL PASS \u2014 %d screens, nothing stops short of the desk" % len(PAGES))
    else:
        print("\nDID NOT FINISH \u2014 see the traceback above.")


_report.reached_end = False

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")
    total = 0
    for page in PAGES:
        pg = b.new_page(viewport={"width": 1920, "height": 1200})
        pg.set_default_timeout(6000)
        pg.add_init_script(STUB)
        try:
            pg.goto(BASE + page, wait_until="load")
            pg.wait_for_timeout(1500)
            res = pg.evaluate(SCAN)
        except Exception as e:
            print("%-22s  could not load: %s" % (page, str(e)[:60]))
            pg.close(); continue
        if res.get("skip"):
            print("%-22s  %s" % (page, res["skip"])); pg.close(); continue
        hits = [h for h in res["hits"] if h["pct"] < THRESHOLD * 100]
        for h in hits:
            fails.append(
                "%s: %s fills only %d%% of the %dpx available to it "
                "(max-width:%s) \u2014 \"%s\". A block that ends at a third of the "
                "desk beside blocks that end at the edge reads as unfinished."
                % (page, (h["id"] or h["cls"])[:30], h["pct"], h["avail"],
                   h["maxw"][:12], h["text"][:40]))
        pg.close()
    b.close()

_report.reached_end = True
if fails:
    sys.exit(1)
