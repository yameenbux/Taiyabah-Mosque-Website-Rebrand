#!/usr/bin/env python3
"""Write portal/messages/index.html, app.js and config.js.

The mechanism lives in tools/screen_builder.py; this file is the description
of THIS screen.

WHY THIS IS THE OFFICE'S SCREEN AND NOT A TEACHER'S. A teacher messaging a
family directly is a safeguarding question the masjid has not settled, and the
database refuses a teacher (verified_madrasah() fails for one). The parents'
side is portal/parent/messages/, built by build_parent_screens.py.

    python3 tools/build_messages_screen.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen_builder import Screen, build, ROOT  # noqa: E402

LEAD = ("What parents have written to the office, and your replies. A "
        "family that has written is waiting to hear back: the ones that have "
        "waited longest are at the top, and a conversation stays waiting "
        "until somebody replies.")

SCREEN = Screen(
    name="Messages",
    nav_key="md-messages",
    folder="messages",
    lead=LEAD,
    panel_id="ms-panel",
    module="messages_module.js",
    var_name="messages",
    css="messages.css",
    body=open(os.path.join(ROOT, "tools", "_messages_body.html"),
              encoding="utf-8").read(),
    page_title="Messages from parents",
)

if __name__ == "__main__":
    build(SCREEN)
