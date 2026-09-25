"""Screenshots of the eight Fees screens, for review before a push.

NOT a test. It imports the stub and the server out of `fees_test.py` rather
than building a second set, because a screenshot taken against different
fixtures from the ones the suite proves is a picture of something nobody
checked. If the suite's stub changes, these pictures change with it.

    python3 _test/fees_shots.py [outdir]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fees_test as T                                    # noqa: E402
from playwright.sync_api import sync_playwright          # noqa: E402

#  fees_test registers an atexit reporter. Importing it for the stub arms
#  that reporter on a script that is not a test run, so a screenshot session
#  signed off either with "RUN INCOMPLETE - do not read this as a pass" or,
#  worse, with "ALL PASS - 0 checks". A screenshot script must not print
#  anything that can be mistaken for a test result. Unregister it here
#  rather than weaken the guard there, where it is doing its job.
import atexit                                            # noqa: E402
atexit.unregister(T.report)
T.FINISHED[0] = True

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/claude-0/shots"

#  Two widths. The desk is what an administrator uses; the phone is what
#  gets used when somebody asks a question in the corridor, and it is the
#  width that has broken twice before.
SHOTS = [
    ("00-landing",   "/portal/fees/",            "Fees — the landing screen"),
    ("01-families",  "/portal/fees/families/",   "Families"),
    ("02-transfers", "/portal/fees/transfers/",  "Bank transfers"),
    ("03-owing",     "/portal/fees/owing/",      "Outstanding & reminders"),
    ("04-discounts", "/portal/fees/discounts/",  "Discounts & waivers"),
    ("05-refunds",   "/portal/fees/refunds/",    "Refunds"),
    ("06-structure", "/portal/fees/structure/",  "What things cost"),
    ("07-annual",    "/portal/fees/annual/",     "Annual report"),
]


def main():
    os.makedirs(OUT, exist_ok=True)
    made = []
    with sync_playwright() as p:
        b = p.chromium.launch()
        for key, path, label in SHOTS:
            pg = T.open_page(b, path, roles=("admin",))
            f = os.path.join(OUT, key + ".png")
            pg.screenshot(path=f, full_page=True)
            made.append((label, f))
            pg.close()

            pg = T.open_page(b, path, roles=("admin",), width=390, height=1000)
            f = os.path.join(OUT, key + "-phone.png")
            pg.screenshot(path=f, full_page=True)
            made.append((label + " (phone)", f))
            pg.close()
        b.close()

    #  A screenshot run that half-worked and said nothing would send the
    #  wrong impression of a section nobody has seen yet.
    #
    #  Count only the files THIS run wrote, and check each one is on disk
    #  with bytes in it. The first version counted every .png in the output
    #  directory, which included fourteen left over from something else and
    #  cheerfully reported "30 of 16" - a check scoped wider than the claim
    #  it was testing, which is the same mistake three times over now.
    want = len(SHOTS) * 2
    got = len([f for _, f in made
               if os.path.exists(f) and os.path.getsize(f) > 1000])
    for label, f in made:
        print("  %-28s %s" % (label, os.path.basename(f)))
    print("%d of %d images written to %s" % (got, want, OUT))
    return 0 if got == want else 1


if __name__ == "__main__":
    sys.exit(main())
