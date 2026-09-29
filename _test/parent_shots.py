"""Screenshots of the parents' portal at the two sizes it is used at.

NOT a test. It imports the suite's stub and fixtures for the reason
pupils_shots.py gives: a picture taken against different fixtures from the ones
the suite proves is a picture of something nobody checked. Every name, class,
address and family in the pictures is invented (see the fixtures in
parent_portal_test.py), so anybody can review the screens at full size without
being shown a real child's details.

    python3 _test/parent_shots.py [outdir]

Default outdir is .superpowers/sdd/2026-09-29-parents-portal/shots/.
"""
import atexit
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import parent_portal_test as T                            # noqa: E402
from playwright.sync_api import sync_playwright           # noqa: E402

atexit.unregister(T.report)
T.FINISHED[0] = True

OUT = (sys.argv[1] if len(sys.argv) > 1 else
       os.path.join(T.ROOT, ".superpowers", "sdd", "2026-09-29-parents-portal", "shots"))
os.makedirs(OUT, exist_ok=True)

SIZES = (("1440", 1440, 900), ("390", 390, 844))


def shot(browser, name, path, fixture, prep=None):
    for tag, w, h in SIZES:
        pg = T.open_page(browser, path, fixture, width=w, height=h)
        if prep:
            prep(pg)
        f = os.path.join(OUT, "%s-%s.png" % (name, tag))
        pg.screenshot(path=f, full_page=True)
        print("  " + os.path.relpath(f, T.ROOT))
        pg.close()


def absence_filled(pg):
    pg.check(T.EV_23)
    pg.check("#pb-t-away")
    pg.fill("#pb-why", "Unwell, has a temperature")
    pg.wait_for_timeout(150)


def absence_refused(pg):
    pg.check(T.EV_TODAY)
    pg.check("#pb-t-away")
    pg.click("#pb-go")
    pg.wait_for_timeout(300)


with sync_playwright() as p:
    browser = p.chromium.launch()
    shot(browser, "children", "/portal/parent/", T.fx())
    shot(browser, "attendance", "/portal/parent/attendance/", T.fx())
    shot(browser, "absence", "/portal/parent/absence/", T.fx(family=T.ONE_KID_FAMILY),
         absence_filled)
    # the two states a parent is most likely to meet first, and least likely
    # to have seen drawn properly
    shot(browser, "attendance-not-started", "/portal/parent/attendance/",
         T.fx(family=T.ONE_KID_FAMILY,
              att={"p-one": T.att("Aaliyah", False, None, [])}))
    shot(browser, "absence-refused", "/portal/parent/absence/",
         T.fx(family=T.ONE_KID_FAMILY,
              errors={"record_parent_absence": {"code": "22023", "message": T.MSG_FUTURE}}),
         absence_refused)
    browser.close()
