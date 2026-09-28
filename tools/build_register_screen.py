#!/usr/bin/env python3
"""Write portal/register/index.html, app.js and config.js.

The mechanism lives in tools/screen_builder.py; this file is the description
of THIS screen.

HOW A REGISTER IS ACTUALLY TAKEN, which is the whole design: a teacher stands
in front of twenty children, most of whom are there. One press marks everyone
here and the teacher changes the three who are not. That is the same order of
work as a paper register, and the reason paper registers are a column of ticks
and a few crosses rather than twenty empty boxes.

    python3 tools/build_register_screen.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen_builder import Screen, build, ROOT  # noqa: E402

LEAD = ("Who came in this evening, a class at a time. The list shows a mark "
        "where a child has something medical recorded — never what it "
        "says — and a parent who has already rung in is never overwritten "
        "by a tick.")

SCREEN = Screen(
    name="Register",
    nav_key="md-register",
    folder="register",
    lead=LEAD,
    panel_id="rg-panel",
    module="register_module.js",
    var_name="register",
    css="register.css",
    body=open(os.path.join(ROOT, "tools", "_register_body.html"),
              encoding="utf-8").read(),
)

if __name__ == "__main__":
    build(SCREEN)
