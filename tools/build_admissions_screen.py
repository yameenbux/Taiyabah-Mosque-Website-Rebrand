#!/usr/bin/env python3
"""Write portal/admissions/index.html from the shared staff-screen shell.

WHY A GENERATOR FOR ONE SCREEN

The same reason tools/build_fees_screens.py exists. The shell - the head, the
fonts, the logo, the rail, the sign-in panel - is identical on every staff
screen and is about 40 KB of it. Copying it by hand is how two screens end up
subtly different, and how the fees section ended up with the sign-out button
in a different place on one of eight.

This is NOT part of the build. `python3 build.py` does not run it. Run it by
hand when this file or portal/classes/index.html changes; what it writes is
committed and served exactly as it lands.

    python3 tools/build_admissions_screen.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHELL = os.path.join(ROOT, "portal", "classes", "index.html")
OUT = os.path.join(ROOT, "portal", "admissions")

LEAD = ("Applications parents have sent through the form on the website. "
        "The list says whether a child has a medical note; the record says "
        "what it is, and writes down who opened it.")


def read_shell():
    if not os.path.exists(SHELL):
        sys.exit("The shell screen %s is missing. Nothing written." % SHELL)
    src = open(SHELL, encoding="utf-8").read()

    #  Fails loudly rather than writing a broken screen. The fees generator
    #  learned this: a shell that has moved on produces a file that looks
    #  plausible, loads, and has no panel in it.
    for marker in ('<style>', '<body>', 'id="cl-panel"', 'id="app-signout"'):
        if marker not in src:
            sys.exit("The shell has changed - %s is gone. Nothing written, so "
                     "that a screen is not written wrongly." % marker)

    head = src[:src.index("<style>")]
    shell_top = src[src.index("<body>"):src.index('<section class="bk" id="cl-panel" hidden>')]
    tail = src[src.rindex("</section>") + len("</section>"):]
    return head, shell_top, tail


#  Two folders down, exactly like portal/fees/.
PATH_NOTE = """<!-- ===========================================================
     THIS SCREEN IS TWO FOLDERS DOWN, so every shared asset is reached with
     ../../ and the rail's own script with ../. Getting this wrong does not
     error - the page loads with no styling and no rail, which reads as a
     broken deploy rather than a broken path.
     =========================================================== -->"""

BODY = """
        <div class="ad-head">
          <div class="ad-head-t">
            <!-- NOT "Applications" again. The h1 above already says that,
                 and a heading that repeats the one above it teaches people
                 to stop reading headings. Every other staff screen names the
                 screen in the h1 and says what the panel is in plain words
                 underneath it: "What is still owed", "What things cost". -->
            <h2>What has come in</h2>
            <p>%s</p>
          </div>
          <div class="ad-head-a">
            <a class="btn btn-ghost" id="ad-form-link" href="../../apply/" target="_blank" rel="noopener">See the form parents fill in</a>
          </div>
        </div>

        <div class="err" id="ad-error" hidden></div>

        <!-- The notice. Loud when something is waiting, quiet when it is not. -->
        <div class="ad-notice is-clear" id="ad-notice" hidden>
          <div class="ad-notice-t">
            <strong class="ad-count" id="ad-notice-count">0</strong>
            <h3 id="ad-notice-h">Nothing waiting</h3>
            <p id="ad-notice-p"></p>
          </div>
          <button class="btn btn-gold" id="ad-notice-go" type="button" hidden>Show them</button>
        </div>

        <div class="ad-figs" id="ad-figs"></div>

        <!-- The list. -->
        <section class="ad-bk" id="ad-list-bk">
          <h3>All applications</h3>
          <p class="ad-sub">Newest first, with anything nobody has looked at
             yet at the top whatever else is filtered.</p>

          <div class="ad-filters">
            <input type="search" id="ad-q" placeholder="Reference, parent, child, email or mobile">
            <select id="ad-status" aria-label="Status">
              <option value="">Any status</option>
              <option value="new">New</option>
              <option value="reviewing">Reviewing</option>
              <option value="offered">Offered</option>
              <option value="waitlisted">Waiting list</option>
              <option value="declined">Declined</option>
              <option value="withdrawn">Withdrawn</option>
            </select>
            <select id="ad-year" aria-label="Academic year">
              <option value="">Any year</option>
            </select>
          </div>

          <div class="ad-scroll">
            <table class="ad-table" id="ad-table">
              <thead>
                <tr>
                  <th>Reference</th>
                  <th>Who applied</th>
                  <th>Children</th>
                  <th>To read</th>
                  <th>Status</th>
                  <th>Came in</th>
                </tr>
              </thead>
              <tbody id="ad-rows"></tbody>
            </table>
          </div>
          <div class="ad-empty" id="ad-empty" hidden></div>
        </section>

        <!-- One application. Hidden until a row is opened. -->
        <section class="ad-bk" id="ad-record" hidden></section>
""" % LEAD


def build():
    head, shell_top, tail = read_shell()

    h = head
    h = re.sub(r"<title>.*?</title>",
               "<title>Applications &mdash; Admissions &mdash; Madrasah "
               "&mdash; Taiyabah Masjid</title>", h, flags=re.S)
    h = re.sub(r"<!-- =+\n     THIS SCREEN IS TWO FOLDERS DOWN.*?-->",
               PATH_NOTE, h, flags=re.S)
    h = h.replace("../../fonts/", "../../fonts/")
    h = h.replace('src="../nav.js"', 'src="../nav.js"')
    #  THE SHARED FURNITURE, AND WHY IT IS NAMED HERE.
    #  The shell this screen is cut from keeps its tokens, its sign-in panel,
    #  its buttons and its fields in an inline <style> block, and read_shell()
    #  deliberately drops that block. The first version of this screen linked
    #  only shell.css and its own sheet, and was missing twenty-three classes
    #  - including the whole two-step sign-in panel, which no signed-in test
    #  fixture ever renders. admin/screen.css is that furniture, shared.
    h = h.rstrip() + ('\n<link rel="stylesheet" href="../../admin/screen.css">'
                      '\n<link rel="stylesheet" href="admissions.css">\n</head>\n')
    h = h.replace("</head>\n<link", "<link")

    top = shell_top
    top = re.sub(r"<h1>.*?</h1>", "<h1>Applications</h1>", top, flags=re.S)
    top = re.sub(r"<h1>Applications</h1>\s*\n\s*<p>.*?</p>",
                 "<h1>Applications</h1>\n      <p>%s</p>" % LEAD, top, flags=re.S)
    top = re.sub(r'<a class="back" href="[^"]*">.*?</a>',
                 '<a class="back" href="../">&larr; Back to the madrasah portal</a>',
                 top, flags=re.S)
    top = top.replace('<section class="bk" id="cl-panel" hidden>', "")
    top = re.sub(r"<!-- The staff themselves\..*?-->", "", top, flags=re.S)

    t = tail.replace('<script src="app.js"></script>',
                     '<script src="app.js"></script>')

    html = (h + top
            + '      <section class="bk" id="ad-panel" hidden>\n'
            + BODY
            + "      </section>\n" + t)

    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(html)

    #  config.js is byte-for-byte identical in every portal screen.
    src_cfg = os.path.join(ROOT, "portal", "classes", "config.js")
    open(os.path.join(OUT, "config.js"), "w", encoding="utf-8").write(
        open(src_cfg, encoding="utf-8").read())

    print("  portal/admissions/index.html  %6d bytes" % len(html))
    print("  portal/admissions/config.js   copied from portal/classes/")


if __name__ == "__main__":
    build()
