#!/usr/bin/env python3
"""Write portal/progress/index.html, app.js and config.js.

The mechanism lives in tools/screen_builder.py; this file is the description
of THIS screen.

WHO IT IS FOR. The teacher of a class (main teacher or listed against it) and
the office with two-step - the same people may_take_register() lets in. The
scoping is in the database (db/127); this screen only decides who is shown a
screen at all.

WHY NOT EVERYTHING A TEACHER WRITES IS FOR A FAMILY. The screen carries two
notes and an explicit choice to share, and says so in words before anything is
typed. The parents' side is portal/parent/progress/, built by
build_parent_screens.py, and it never receives the teacher's own note.

    python3 tools/build_progress_screen.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen_builder import Screen, build, ROOT  # noqa: E402
from build_parent_screens import es5_problems  # noqa: E402

LEAD = ("Where each child in your class is up to - sabaq, sabqi and manzil - "
        "with a note for the family and a note for yourself. Nothing reaches "
        "a parent unless you choose to share it.")

SCREEN = Screen(
    name="Progress notes",
    nav_key="md-progress",
    folder="progress",
    lead=LEAD,
    panel_id="tp-panel",
    module="progress_module.js",
    var_name="teacherProgress",
    css="progress.css",
    body=open(os.path.join(ROOT, "tools", "_progress_body.html"),
              encoding="utf-8").read(),
    page_title="Progress notes",
)

if __name__ == "__main__":
    bad = es5_problems(SCREEN.module_path)
    if bad:
        sys.exit("Not ES5, so NOTHING was written:\n  " + "\n  ".join(bad))
    build(SCREEN)
