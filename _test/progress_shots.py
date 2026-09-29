"""Screenshots of the two Progress screens at the two sizes they are used at.

NOT a test. It imports the suite's stub and fixtures, so a picture is of the
same thing the suite proves. Every name and note in the pictures is invented
(see progress_test.py).

    python3 _test/progress_shots.py [outdir]
"""
import atexit
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import progress_test as T                                 # noqa: E402
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


def open_child(pg):
    pg.click('.tp-row[data-pupil="p1"]')
    pg.wait_for_timeout(400)
    pg.fill("#tp-sabaq", "Surah al-Mulk, verses 11-20")
    pg.fill("#tp-sabqi", "Surah an-Naba, 16-30")
    pg.fill("#tp-manzil", "Juz Amma")
    pg.fill("#tp-forp", "A good week. Please listen to her once a day.")
    pg.fill("#tp-mine", "Watch her tajweed on the heavy letters. Not for the family.")
    pg.wait_for_timeout(150)


with sync_playwright() as p:
    browser = p.chromium.launch()
    shot(browser, "progress-teacher", "/portal/progress/", T.teacher_fx(classes=[T.CLASSES[0]]), open_child)
    shot(browser, "progress-parent", "/portal/parent/progress/", T.parent_fx(
        kids=[{"pupil_id": "p1", "first_name": "Proofchilda"}],
        progress={"p1": {"first_name": "Proofchilda", "entries": [
            T.pentry("2026-09-26"),
            T.pentry("2026-09-19", sabaq="Surah al-Qalam, verses 1-8", sabqi="Surah al-Mulk, 1-30", manzil=None,
                     note="Reading with more confidence. She asked good questions about the meaning."),
            T.pentry("2026-09-12", sabaq="Surah al-Mulk, verses 1-10", sabqi=None, manzil=None, note=None, teacher=None)]}}))
    browser.close()
