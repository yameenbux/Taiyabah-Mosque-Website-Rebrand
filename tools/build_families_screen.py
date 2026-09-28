#!/usr/bin/env python3
"""Write portal/families/index.html, app.js and config.js.

The mechanism lives in tools/screen_builder.py, which is shared by every staff
screen; this file is only the description of THIS screen.

WHAT THIS SCREEN IS FOR. A bill goes to a household, not to a child; a message
about a closure goes to a parent once, not to each of their four children; and
"who may collect this child" is a question about a family. The madrasah's own
language is families, so the screen is too.

It is also where the 56 sibling pairs left over from the register import
finally have somewhere to be settled, because joining two children into one
family is family work and the roll could only ever point at it.

NOT part of `python3 build.py`. Run it by hand; what it writes is committed
and served exactly as it lands.

    python3 tools/build_families_screen.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen_builder import Screen, build, ROOT  # noqa: E402

LEAD = ("Every family on the register, how many children are in it and whether "
        "there is anybody to ring. The list says whether they can be reached; "
        "the family's own record says how, and it is opened deliberately.")

SCREEN = Screen(
    name="Families",
    nav_key="md-families",
    folder="families",
    lead=LEAD,
    panel_id="fa-panel",
    module="families_module.js",
    var_name="families",
    css="families.css",
    #  The lead is the masthead's, and appears there once. The panel does not
    #  repeat it — see the note at the top of _families_body.html.
    body=open(os.path.join(ROOT, "tools", "_families_body.html"),
              encoding="utf-8").read(),
)

if __name__ == "__main__":
    build(SCREEN)
