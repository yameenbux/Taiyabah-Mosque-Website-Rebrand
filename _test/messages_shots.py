"""Screenshots of the two Messages screens at the two sizes they are used at.

NOT a test. It imports the suite's stub and fixtures, so a picture is of the
same thing the suite proves. Every name, reference and message in the pictures
is invented (see messages_test.py).

    python3 _test/messages_shots.py [outdir]
"""
import atexit
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import messages_test as T                                 # noqa: E402
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


def open_office(pg):
    pg.click('.ms-row[data-id="o1"]')
    pg.wait_for_timeout(300)
    pg.fill("#ms-reply", "Thank you for letting us know. We have marked Thursday.")
    pg.wait_for_timeout(100)


def open_parent(pg):
    pg.click('.pm-row[data-id="t1"]')
    pg.wait_for_timeout(400)


with sync_playwright() as p:
    browser = p.chromium.launch()
    shot(browser, "messages-office", "/portal/messages/", T.office_fx())
    shot(browser, "messages-office-open", "/portal/messages/", T.office_fx(), open_office)
    shot(browser, "messages-parent", "/portal/parent/messages/", T.parent_fx())
    shot(browser, "messages-parent-open", "/portal/parent/messages/", T.parent_fx(), open_parent)
    browser.close()
