"""Screenshots of the Pupils screen at the size it is actually used at.

NOT a test. Same idea as fees_shots.py, and it imports the suite's stub for
the same reason: a picture taken against different fixtures from the ones the
suite proves is a picture of something nobody checked.

WHY THIS EXISTS. The suite's fixture holds two pupils. The madrasah holds 552,
and everything that has gone wrong with this screen has been invisible at two:
the column headers scroll away by row 300; the figure tiles wrap to two rows
and push the roll below the fold; the sibling panel renders all 56 pairs, not
the fixture's one, between the figures and the list. None of that is a failing
assertion. All of it is obvious in a picture.

A REGISTER YOU CAN LOOK AT WITHOUT OPENING THE REGISTER. The 44 class names and
their 44 roll sizes are the real ones, because a layout that reads well at 3
rows and badly at 20 must be judged at 20. Everything else - every name, date,
postcode and family - is generated from a fixed seed. No real pupil data goes
near this file, so anybody can review the screen at full size without being
shown 552 children's details to do it.

    python3 _test/pupils_shots.py [outdir]
"""
import atexit
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pupils_test as T                                  # noqa: E402
from PIL import Image                                    # noqa: E402
from playwright.sync_api import sync_playwright          # noqa: E402

atexit.unregister(T.report)
T.FINISHED[0] = True

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/claude-0/pupilshots"

#  The real 44 classes and their real rolls. Nothing else real.
CLASSES = [
    ("Boys Alimiyyah - Arbi Dawm", 7), ("Boys Alimiyyah - Arbi awwal", 7),
    ("Boys Hafiz Class - A", 12), ("Boys Hafiz Class - B", 12),
    ("Boys Hafiz Class - C", 12), ("Boys Hafiz Class - D", 13),
    ("Boys Reception 2026", 19), ("Boys Year 1", 14), ("Boys Year 2A", 14),
    ("Boys Year 2B", 10), ("Boys Year 3", 14), ("Boys Year 4", 18),
    ("Boys Year 5", 19), ("Boys Year 6", 16), ("Boys Year 7", 10),
    ("Boys Year 8", 14), ("Boys Year 9", 17), ("Girls Class 1", 18),
    ("Girls Class 2", 20), ("Girls Class 3", 20), ("Girls Class 4", 12),
    ("Girls Class 5A", 16), ("Girls Class 5B", 14), ("Girls Class 6", 20),
    ("Girls Class 7", 14), ("Girls Class 8", 12), ("Girls EDAADIYAH", 11),
    ("Girls Further Education A", 9), ("Girls Further Education B", 17),
    ("Girls Hafiza A", 11), ("Girls Hafiza B", 10), ("Girls Hafiza C", 11),
    ("Girls Khamisah", 7), ("Girls OOLA", 12), ("Girls RAABI'AH Class", 9),
    ("Girls Reception 2026", 17), ("Girls THAALITHAH Class", 3),
    ("Girls THAANIYAH", 11), ("Ladies EDAADIYAH", 4), ("Ladies Hifz Class", 10),
    ("Ladies Naazirah Class", 19), ("Ladies Thaaniyah Class", 6),
    ("Play and Pray 1 - 26/27", 9), ("Play and Pray 2 - 26/27", 4),
]
FIRST = ["Aaliyah", "Bilal", "Zainab", "Yusuf", "Maryam", "Idris", "Safiyyah",
         "Ismail", "Khadija", "Hamza", "Ruqayyah", "Musa", "Aisha", "Harun",
         "Sumayyah", "Ilyas", "Nusaybah", "Dawud", "Asiya", "Salim"]
LAST = ["Patel", "Omarji", "Bhaiji", "Chhadat", "Mathar", "Sakeria", "Khoda",
        "Umarji", "Bapu", "Ibrahim", "Bagas", "Bhaloda", "Mallu", "Teylor"]


def roll():
    random.seed(7)
    rows, n = [], 0
    for ci, (cname, size) in enumerate(CLASSES):
        girls = cname.startswith(("Girls", "Ladies"))
        for _ in range(size):
            n += 1
            rows.append({
                "id": "p%d" % n, "legacy_ref": str(400 + n),
                "name": random.choice(FIRST) + " " + random.choice(LAST),
                "gender": "female" if girls else "male",
                "date_of_birth": "%d-%02d-%02d" % (
                    random.randint(2008, 2021), random.randint(1, 12),
                    random.randint(1, 28)),
                "age": random.randint(5, 17),
                "postcode": "BL%d %dJY" % (random.randint(1, 6), random.randint(1, 9)),
                "family": random.choice(LAST) + " family",
                "classes": [cname], "class_ids": ["c%d" % ci],
                "teacher": "Apa " + random.choice(LAST),
                "has_medical": n % 14 == 0, "has_allergy": n % 23 == 0,
                "has_send": n % 31 == 0, "has_fee_rate": False,
                "has_teacher": cname != "Girls OOLA",
                "has_contact": n % 184 != 0,
            })
    return rows


ROWS = roll()
HEALTH = {"allowed": True, "on_roll": len(ROWS), "no_family": 0,
          "no_contact": 3, "no_class": 1, "no_teacher": 12, "no_dob": 0,
          "no_gender": 1, "no_fee_rate": len(ROWS), "with_medical": 38,
          "with_allergy": 24, "with_send": 17, "dob_to_check": 9,
          "open_sibling_suggestions": 56}
DOBQ = {"allowed": True, "rows": [
    {"id": ROWS[i]["id"], "legacy_ref": ROWS[i]["legacy_ref"],
     "name": ROWS[i]["name"], "class": ROWS[i]["classes"][0],
     "date_of_birth": ROWS[i]["date_of_birth"], "age": 51, "class_normally": 10,
     "why": "An adult in a children's class."} for i in range(0, 90, 10)]}


def main():
    os.makedirs(OUT, exist_ok=True)
    made = []
    with sync_playwright() as p:
        b = p.chromium.launch()
        for key, w, h in [("desk", 1500, 1100), ("phone", 390, 900)]:
            pg = b.new_page(viewport={"width": w, "height": h})
            pg.set_default_timeout(9000)
            pg.add_init_script(T.stub(["admin"], ROWS, HEALTH, T.SUGG, DOBQ))
            pg.goto(T.BASE + "/portal/pupils/", wait_until="load")
            pg.wait_for_timeout(1400)
            n = pg.locator("tr.pu-row").count()
            #  TWO PICTURES PER WIDTH, because they answer different
            #  questions. The full page says how far the screen scrolls. The
            #  first screen says what somebody actually sees when it opens -
            #  which on the phone is the more damning of the two, because it
            #  contains no pupil at all.
            f = os.path.join(OUT, key + ".png")
            pg.screenshot(path=f, full_page=True)
            made.append((key + " (whole page)", f, n))
            f1 = os.path.join(OUT, key + "-first-screen.png")
            pg.screenshot(path=f1, full_page=False)
            made.append((key + " (first screen)", f1, n))
            if key == "desk":
                pg.locator("tr.pu-row").first.click()
                pg.wait_for_timeout(700)
                f2 = os.path.join(OUT, "desk-record.png")
                pg.screenshot(path=f2, full_page=True)
                made.append(("desk record open (whole page)", f2, n))
            pg.close()
        b.close()
    #  Report the page HEIGHT, not just that a file was written. The whole
    #  point of this script is how far the screen scrolls, and "3 images
    #  written" says nothing about that. 28 screens is the finding.
    ok = 0
    for k, f, n in made:
        if not (os.path.exists(f) and os.path.getsize(f) > 1000):
            print("  %-14s NOT WRITTEN" % k)
            continue
        ok += 1
        with Image.open(f) as im:
            print("  %-14s %5dx%-6d  %4.1f screens of scrolling  %d rows"
                  % (k, im.size[0], im.size[1], im.size[1] / 1100.0, n))
    print("%d of %d images written to %s" % (ok, len(made), OUT))
    return 0 if ok == len(made) else 1


if __name__ == "__main__":
    sys.exit(main())
