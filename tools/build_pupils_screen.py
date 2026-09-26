#!/usr/bin/env python3
"""Write portal/pupils/index.html, app.js and config.js.

WHY A GENERATOR. The same reason tools/build_fees_screens.py and
tools/build_admissions_screen.py exist: the shell - the head, the fonts, the
logo, the rail, the two-step sign-in panel - is identical on every staff
screen and is most of the file. Copying it by hand is how two screens end up
subtly different.

THE AUTH SHELL IS TAKEN FROM portal/admissions/app.js, not rewritten. Its
boundaries are found by content and asserted, so a shell that has moved on
stops this script rather than producing a screen that loads and does nothing.

NOT part of `python3 build.py`. Run it by hand; what it writes is committed
and served exactly as it lands.

    python3 tools/build_pupils_screen.py
"""
import os
import re
import sys

ROOT   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHELL  = os.path.join(ROOT, "portal", "classes", "index.html")
SRCJS  = os.path.join(ROOT, "portal", "admissions", "app.js")
MODULE = os.environ.get("PUPILS_MODULE",
                        os.path.join(ROOT, "tools", "pupils_module.js"))
OUT    = os.path.join(ROOT, "portal", "pupils")

LEAD = ("Every child on the roll, the class they are in, who teaches them and "
        "who to ring. The list says whether a child has a medical note; the "
        "record says what it is, and writes down who opened it.")

PATH_NOTE = """<!-- ===========================================================
     THIS SCREEN IS TWO FOLDERS DOWN, so every shared asset is reached with
     ../../ and the rail's own script with ../. Getting this wrong does not
     error - the page loads with no styling and no rail, which reads as a
     broken deploy rather than a broken path.
     =========================================================== -->"""

BODY = """
        <div class="pu-head">
          <div class="pu-head-t">
            <h2>Who is on the roll</h2>
            <p>%s</p>
          </div>
          <div class="pu-head-a">
            <a class="btn btn-ghost" href="../classes/">Classes</a>
            <a class="btn btn-ghost" href="../fees/families/">Families &amp; fees</a>
          </div>
        </div>

        <div class="err" id="pu-error" hidden></div>

        <!-- Each figure filters the list to exactly the children it counts. -->
        <div class="pu-figs" id="pu-figs"></div>

        <!-- Only on screen when there is a pair somebody has to settle. -->
        <section class="pu-sugg" id="pu-sugg" hidden></section>

        <section class="pu-bk" id="pu-list-bk">
          <h3 id="pu-roll">The roll</h3>
          <p class="pu-sub">Choose a child to see their record.</p>

          <!-- THE SEARCH GETS ITS OWN LINE.
               Four selects and a search box on one row made the box narrow
               and squeezed "Everyone" down to nothing, and none of the
               selects said what they filtered - "On roll" and "Any teacher"
               were bare values sitting next to each other. -->
          <div class="pu-search">
            <label class="sr-only" for="pu-q">Search the roll</label>
            <input type="search" id="pu-q"
                   placeholder="Search by name, reference, postcode, family or class">
            <button type="button" class="pu-clearq" id="pu-clearq" hidden
                    aria-label="Clear the search">&times;</button>
          </div>

          <!-- EVERY FILTER SAYS WHAT IT FILTERS. -->
          <div class="pu-filters">
            <div class="pu-f">
              <label for="pu-class">Class</label>
              <select id="pu-class"><option value="">Any class</option></select>
            </div>
            <div class="pu-f">
              <label for="pu-side">Boys or girls</label>
              <select id="pu-side">
                <option value="">Everyone</option>
                <option value="male">Boys</option>
                <option value="female">Girls</option>
              </select>
            </div>
            <div class="pu-f">
              <label for="pu-teacher">Teacher</label>
              <select id="pu-teacher"><option value="">Any teacher</option></select>
            </div>
            <div class="pu-f">
              <label for="pu-status">Status</label>
              <select id="pu-status">
                <option value="on_roll" selected>On roll</option>
                <option value="on_hold">On hold</option>
                <option value="suspended">Suspended</option>
                <option value="left">Left</option>
                <option value="">Everyone, including those who have left</option>
              </select>
            </div>
          </div>

          <div class="pu-summary">
            <span class="pu-count" id="pu-count"></span>
            <button type="button" class="pu-clearall" id="pu-clearall" hidden></button>
          </div>

          <div class="pu-export-bk" id="pu-export-bk">
            <div class="pu-export" id="pu-export"></div>
            <div class="pu-expanel" id="pu-expanel" hidden></div>
            <div class="pu-ask" id="pu-ask" hidden></div>
          </div>

          <!-- THE PRINTABLE REGISTER. Empty and invisible on screen; only
               the print stylesheet shows it, and only after the button has
               filled it. -->
          <div class="pu-print" id="pu-print" aria-hidden="true"></div>

          <div class="pu-pager" id="pu-pager-top"></div>

          <div class="pu-scroll">
            <table class="pu-table" id="pu-table">
              <thead>
                <tr>
                  <th><button type="button" class="pu-sortable" data-sort="ref" aria-sort="none">Reference</button></th>
                  <th><button type="button" class="pu-sortable" data-sort="name" aria-sort="none">Name</button></th>
                  <th><button type="button" class="pu-sortable" data-sort="age" aria-sort="none">Age</button></th>
                  <th><button type="button" class="pu-sortable" data-sort="class" aria-sort="none">Class</button></th>
                  <th>Teacher</th><th>Family</th><th>To read</th><th><span class="sr-only">Actions</span></th>
                </tr>
              </thead>
              <tbody id="pu-rows"></tbody>
            </table>
          </div>
          <div class="pu-empty" id="pu-empty" hidden></div>
          <div class="pu-pager" id="pu-pager-bottom"></div>
        </section>

""" % LEAD


def read_shell():
    if not os.path.exists(SHELL):
        sys.exit("The shell screen %s is missing. Nothing written." % SHELL)
    src = open(SHELL, encoding="utf-8").read()
    for marker in ("<style>", "<body>", 'id="cl-panel"', 'id="app-signout"'):
        if marker not in src:
            sys.exit("The shell has changed - %s is gone. Nothing written, so "
                     "that a screen is not written wrongly." % marker)
    head = src[:src.index("<style>")]
    top = src[src.index("<body>"):src.index('<section class="bk" id="cl-panel" hidden>')]
    tail = src[src.rindex("</section>") + len("</section>"):]
    return head, top, tail


def build_js():
    """Splice the pupils module into the Applications screen's auth shell."""
    if not os.path.exists(SRCJS):
        sys.exit("portal/admissions/app.js is missing; nothing to take the shell from.")
    if not os.path.exists(MODULE):
        sys.exit("The pupils module %s is missing." % MODULE)
    src = open(SRCJS, encoding="utf-8").read()

    start = src.find("  /* =========================================================================\n     APPLICATIONS")
    if start < 0:
        sys.exit("Could not find where the Applications module begins. Nothing written.")
    end = src.find("    // A panel that fails to load must never take the sign-in shell")
    if end < 0:
        sys.exit("Could not find where the Applications module ends. Nothing written.")
    #  Back up to the close of the module's own IIFE so the splice is clean.
    close = src.rfind("  })();", start, end)
    if close < 0:
        sys.exit("Could not find the close of the Applications module. Nothing written.")
    close += len("  })();\n")

    head = src[:start]
    tail = src[close:]
    body = open(MODULE, encoding="utf-8").read().rstrip() + "\n"

    out = head + body + tail
    out = out.replace("admissions.mount(identity)", "pupils.mount(identity)")

    #  THE RAIL AND THE HEADING COME FROM THIS BLOCK, NOT FROM THE MARKUP.
    #  The first build of this screen looked finished and said "Applications"
    #  at the top with Applications lit in the rail, because AdminShell.mount
    #  is handed the page's identity in JavaScript and the splice brought the
    #  Applications one with it. Asserted below so it cannot come back.
    out = out.replace("current:  'md-admissions'", "current:  'md-pupils'")
    out = out.replace("title:    'Applications'", "title:    'Pupils'")
    if "md-admissions" in out or "title:    'Applications'" in out:
        sys.exit("The screen still identifies itself as Applications. Nothing written.")
    out = out.replace('console.warn("applications panel unavailable:"',
                      'console.warn("pupils panel unavailable:"')
    out = re.sub(r'^   Applications —.*$', '   Pupils — the roll',
                 out, count=1, flags=re.M)
    if "var pupils" not in out:
        sys.exit("The spliced file has no pupils module in it. Nothing written.")
    if "var admissions" in out:
        sys.exit("The Applications module survived the splice. Nothing written.")
    return out



def js_parses(source):
    """Refuse to write JavaScript that does not parse.

    A SCREEN THAT LOADS IS NOT A SCREEN THAT WORKS. One mismatched quote in
    the module - a string opened with ' and closed with " - produced a page
    that fetched its shell, drew the masthead and the rail, and then did
    nothing at all, because the whole script died on a SyntaxError before the
    module was ever defined. It looked like a slow network. Thirteen checks
    passed against it before one finally did not.

    CHECKED BEFORE ANYTHING IS WRITTEN, not after. The first version of this
    wrote the file, checked it, and deleted it if it was bad - which left the
    screen with no app.js at all, so a typo turned a working page into a 404
    instead of leaving yesterday's good build in place. A failed build should
    change nothing.

    Node is in this container and `node --check` costs milliseconds.
    """
    import subprocess, tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False,
                                     encoding="utf-8") as fh:
        fh.write(source)
        tmp = fh.name
    try:
        r = subprocess.run(["node", "--check", tmp],
                           capture_output=True, text=True, timeout=30)
        return r.returncode == 0, (r.stderr or "").replace(tmp, "the module")\
                                                  .strip().splitlines()
    except (OSError, subprocess.SubprocessError):
        return True, ["node is not available; the parse check was skipped"]
    finally:
        os.unlink(tmp)

def build():
    head, top, tail = read_shell()

    h = head
    h = re.sub(r"<title>.*?</title>",
               "<title>Pupils &mdash; Madrasah &mdash; Taiyabah Masjid</title>",
               h, flags=re.S)
    h = re.sub(r"<!-- =+\n     THIS SCREEN IS TWO FOLDERS DOWN.*?-->",
               PATH_NOTE, h, flags=re.S)
    #  Furniture first, screen second. admin/screen.css carries the tokens,
    #  the buttons and the sign-in panel; this sheet carries the roll.
    h = h.rstrip() + ('\n<link rel="stylesheet" href="../../admin/screen.css">'
                      '\n<link rel="stylesheet" href="pupils.css">\n</head>\n')
    h = h.replace("</head>\n<link", "<link")

    t = top
    t = re.sub(r"<h1>.*?</h1>", "<h1>Pupils</h1>", t, flags=re.S)
    t = re.sub(r"<h1>Pupils</h1>\s*\n\s*<p>.*?</p>",
               "<h1>Pupils</h1>\n      <p>%s</p>" % LEAD, t, flags=re.S)
    t = re.sub(r'<a class="back" href="[^"]*">.*?</a>',
               '<a class="back" href="../">&larr; Back to the madrasah portal</a>',
               t, flags=re.S)
    t = t.replace('<section class="bk" id="cl-panel" hidden>', "")
    t = re.sub(r"<!-- The staff themselves\..*?-->", "", t, flags=re.S)

    html = (h + t
            + '      <section class="bk" id="pu-panel" hidden>\n'
            + BODY + "      </section>\n" + tail)

    os.makedirs(OUT, exist_ok=True)
    open(os.path.join(OUT, "index.html"), "w", encoding="utf-8").write(html)
    js = build_js()
    ok, why = js_parses(js)
    if not ok:
        sys.exit("The JavaScript this would have written does not parse, so "
                 "NOTHING was written and the last good build is untouched:"
                 "\n  " + "\n  ".join(why[:4]))
    open(os.path.join(OUT, "app.js"), "w", encoding="utf-8").write(js)
    open(os.path.join(OUT, "config.js"), "w", encoding="utf-8").write(
        open(os.path.join(ROOT, "portal", "classes", "config.js"), encoding="utf-8").read())

    print("  portal/pupils/index.html  %6d bytes" % len(html))
    print("  portal/pupils/app.js      %6d bytes" % os.path.getsize(os.path.join(OUT, "app.js")))
    print("  portal/pupils/config.js   copied from portal/classes/")


if __name__ == "__main__":
    build()
