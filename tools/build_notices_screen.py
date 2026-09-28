#!/usr/bin/env python3
"""Write portal/notices/index.html, app.js and config.js.

The mechanism lives in tools/screen_builder.py; this file is the description
of THIS screen.

WHY IT OPENS ON ONE JOB. Publishing a privacy notice is half the duty:
Articles 13 and 14 require the masjid to INFORM parents, and a page nobody has
been pointed at has informed nobody. So the screen is a job with a number on
it - so many families told, so many not - and it is finished when the second
number is nought. The record it writes is the evidence the duty was
discharged.

    python3 tools/build_notices_screen.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen_builder import Screen, build, ROOT  # noqa: E402

LEAD = ("Telling parents what the madrasah keeps about their children, and "
        "writing down that they were told. Fee reminders will not go to a "
        "family that has not been told — the system refuses, so it is "
        "not a matter of remembering.")

SCREEN = Screen(
    name="Notices to parents",
    nav_key="md-notices",
    folder="notices",
    lead=LEAD,
    panel_id="nt-panel",
    module="notices_module.js",
    var_name="notices",
    css="notices.css",
    body=open(os.path.join(ROOT, "tools", "_notices_body.html"),
              encoding="utf-8").read(),
    page_title="Notices to parents",
)

if __name__ == "__main__":
    build(SCREEN)
