"""Screenshots of what a parent lands on when they sign in at /portal/.

NOT a test. Three pictures at 1440 and 390:

  parent-landing    the parents' portal, reached by signing in at /portal/ as a
                    parent with no user_roles row and no authenticator - the
                    state the test parent was really in
  parent-fallback   the panel on /portal/ itself, which a parent sees only if
                    the redirect did not fire
  no-access         what somebody with no role and no parent login is told

The stubs and fixtures are the suites' own (parent_portal_test.py for the
parents' portal, the head of portal_test.py for /portal/), for the reason
parent_shots.py gives. Every name is invented.

    python3 _test/parent_landing_shots.py [outdir]
"""
import atexit
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import parent_portal_test as T                            # noqa: E402
from playwright.sync_api import sync_playwright           # noqa: E402

atexit.unregister(T.report)
T.FINISHED[0] = True

#  portal_test.py runs on import, so take only what precedes its browser run:
#  the fixtures, the local server, stub() and open_as().
src = open(os.path.join(HERE, "portal_test.py"), encoding="utf-8").read()
head = src[:src.index("with sync_playwright() as p:")]
PT = {"__name__": "portal_test_head", "__file__": os.path.join(HERE, "portal_test.py")}
exec(compile(head, "portal_test.py", "exec"), PT)
atexit.unregister(PT["_report"])
PT["_report"].reached_end = True

OUT = (sys.argv[1] if len(sys.argv) > 1 else
       os.path.join(T.ROOT, ".superpowers", "sdd", "2026-09-29-parents-portal", "shots"))
os.makedirs(OUT, exist_ok=True)
SIZES = (("1440", 1440, 900), ("390", 390, 844))

#  The parents' stub, taught the one call this page makes first. Everything
#  else in it is unchanged, including "aal1, no factor".
IS_PARENT_YES = "if (name==='is_parent') return Promise.resolve({data:true,error:null});\n      "
ANCHOR = "if (name==='parent_my_children')"


def landing(browser, w, h):
    s = T.stub(T.fx())
    assert s.count(ANCHOR) == 1
    pg = browser.new_page(viewport={"width": w, "height": h})
    pg.add_init_script(s.replace(ANCHOR, IS_PARENT_YES + ANCHOR))
    pg.goto(T.BASE + "/portal/", wait_until="networkidle")
    pg.wait_for_timeout(1500)
    assert pg.url.rstrip("/").endswith("/portal/parent"), pg.url
    return pg


with sync_playwright() as p:
    browser = p.chromium.launch()
    for tag, w, h in SIZES:
        jobs = (("parent-landing", landing(browser, w, h)),
                ("parent-fallback", PT["open_as"](browser, ["parent"], w=w, h=h)[0]),
                ("no-access", PT["open_as"](browser, [], w=w, h=h)[0]))
        for name, pg in jobs:
            pg.set_viewport_size({"width": w, "height": h})
            f = os.path.join(OUT, "%s-%s.png" % (name, tag))
            pg.screenshot(path=f, full_page=True)
            print("  " + os.path.relpath(f, T.ROOT))
            pg.close()
    browser.close()
PT["httpd"].shutdown()
