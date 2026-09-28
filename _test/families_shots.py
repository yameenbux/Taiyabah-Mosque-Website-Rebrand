"""Photograph the Families screen, for reviewing it without a database.

It drives the same stub the suite does, so what comes out is what the office
will see - the real layout, the real type, the real spacing - with an invented
register. NO REAL FAMILY, NAME, ADDRESS OR TELEPHONE NUMBER APPEARS ANYWHERE
IN OR OUT OF THIS FILE.

    python3 _test/families_shots.py [outdir]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import families_test as T  # noqa: E402
from playwright.sync_api import sync_playwright  # noqa: E402

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/families"


def shot(pg, name, full=True):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, name + ".png")
    pg.screenshot(path=path, full_page=full)
    h = pg.evaluate("() => document.documentElement.scrollHeight")
    v = pg.evaluate("() => window.innerHeight")
    print("  %-28s %5dpx  =  %.1f screens" % (name + ".png", h, h / float(v)))


def run():
    with sync_playwright() as p:
        b = p.chromium.launch()

        pg = T.open_screen(b, ["admin", "madrasah"])
        shot(pg, "1-the-list")

        pg.click('#fa-figs [data-need="noone"]')
        pg.wait_for_timeout(250)
        shot(pg, "2-nobody-to-ring")
        pg.click("#fa-clearall")
        pg.wait_for_timeout(200)

        pg.click('#fa-export [data-take="open"]')
        pg.wait_for_timeout(250)
        shot(pg, "3-the-export-choice")
        pg.click('#fa-export [data-take="open"]')
        pg.wait_for_timeout(150)

        pg.click("#fa-rows tr.fa-row >> nth=0")
        pg.wait_for_timeout(350)
        shot(pg, "4-one-family")

        pg.click("#fa-record .fa-move >> nth=0")
        pg.wait_for_timeout(250)
        shot(pg, "5-moving-a-child")

        pg.click("#fa-move-no")
        pg.wait_for_timeout(150)
        pg.click("#fa-letter")
        pg.wait_for_timeout(250)
        shot(pg, "6-writing-to-them")

        #  Back to the list: the sibling card lives there, not on a family.
        pg.click("#fa-back")
        pg.wait_for_timeout(250)
        pg.click("#fa-sugg-toggle")
        pg.wait_for_timeout(250)
        shot(pg, "7-the-sibling-pairs")
        pg.close()

        #  A FAMILY WITH NOBODY RECORDED. Six of the 330 are like this and the
        #  screen has to say so rather than showing a gap.
        pg = T.open_screen(b, ["admin", "madrasah"], record=T.RECORD_NOBODY)
        pg.click("#fa-rows tr.fa-row >> nth=0")
        pg.wait_for_timeout(350)
        shot(pg, "8-nobody-recorded")
        pg.close()

        #  WHAT A TEACHER SEES. No detailed export, no settle buttons.
        pg = T.open_screen(b, ["madrasah"])
        pg.click('#fa-export [data-take="open"]')
        pg.wait_for_timeout(250)
        shot(pg, "9-what-a-teacher-sees")
        pg.close()

        #  THE PHONE. Measured, not assumed.
        pg = T.open_screen(b, ["admin", "madrasah"], width=390, height=900)
        shot(pg, "10-phone")
        box = pg.evaluate("""() => { var r=document.querySelector('#fa-rows tr');
            return r ? r.getBoundingClientRect().bottom : null; }""")
        print("  first whole family ends at %spx of 900" % box)
        pg.close()

        b.close()
    print("\n  %s" % OUT)


if __name__ == "__main__":
    run()
