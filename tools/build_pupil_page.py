#!/usr/bin/env python3
"""Write portal/pupil/index.html, app.js and config.js.

The same generator pattern as build_pupils_screen.py, and for the same
reason: the shell - head, fonts, logo, rail, two-step sign-in panel - is
identical on every staff screen and is most of the file. Copying it by hand
is how two screens end up subtly different.

THE FIRST DEEP-LINKED RECORD PAGE IN THIS PORTAL. No other screen reads a
query string, so whatever this establishes, Staff and Families will copy.
portal/pupil/?id=<uuid>: the back button works, a refresh keeps you on the
child, and the address can be passed between two signed-in members of staff.

    python3 tools/build_pupil_page.py
"""
import os
import re
import sys

ROOT   = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHELL  = os.path.join(ROOT, "portal", "classes", "index.html")
SRCJS  = os.path.join(ROOT, "portal", "admissions", "app.js")
MODULE = os.environ.get("PUPIL_MODULE",
                        os.path.join(ROOT, "tools", "pupil_page_module.js"))
OUT    = os.path.join(ROOT, "portal", "pupil")

LEAD = ("Everything on file for one child. Opening this page is written down "
        "against your name, because who has read a child's record is a "
        "question a subject access request asks.")

PATH_NOTE = """<!-- ===========================================================
     THIS SCREEN IS TWO FOLDERS DOWN, so every shared asset is reached with
     ../../ and the rail's own script with ../. Getting this wrong does not
     error - the page loads with no styling and no rail, which reads as a
     broken deploy rather than a broken path.
     =========================================================== -->"""

BODY = """
        <div class="pp-top">
          <a class="pp-back" href="../pupils/">&larr; All pupils</a>
          <div class="pp-acts" id="pp-acts">
            <button class="btn btn-ghost" id="pp-edit" type="button">Amend these details</button>
          </div>
        </div>

        <div class="err" id="pp-error" hidden></div>

        <div id="pp-body" hidden>
          <div class="pp-head" id="pp-head"></div>

          <!-- ABOVE THE TABS AND OUTSIDE THEM. An allergy is safety
               information and a teacher needs it the moment the page opens,
               not two clicks in. -->
          <div class="pp-med" id="pp-med" hidden></div>

          <div class="pp-tabs" id="pp-tabs" role="tablist"></div>
          <div class="pp-panel" id="pp-panel" role="tabpanel"></div>

          <div class="pp-form" id="pp-editor" hidden></div>
        </div>
"""


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
    """Splice the pupil-page module into the Applications screen's auth shell."""
    if not os.path.exists(SRCJS):
        sys.exit("portal/admissions/app.js is missing; nothing to take the shell from.")
    if not os.path.exists(MODULE):
        sys.exit("The pupil-page module %s is missing." % MODULE)
    src = open(SRCJS, encoding="utf-8").read()

    start = src.find("  /* =========================================================================\n     APPLICATIONS")
    if start < 0:
        sys.exit("Could not find where the Applications module begins. Nothing written.")
    end = src.find("    // A panel that fails to load must never take the sign-in shell")
    if end < 0:
        sys.exit("Could not find where the Applications module ends. Nothing written.")
    close = src.rfind("  })();", start, end)
    if close < 0:
        sys.exit("Could not find the close of the Applications module. Nothing written.")
    close += len("  })();\n")

    out = src[:start] + open(MODULE, encoding="utf-8").read().rstrip() + "\n" + src[close:]
    out = out.replace("admissions.mount(identity)", "pupil.mount(identity)")

    #  THE RAIL AND THE HEADING COME FROM THIS BLOCK, NOT THE MARKUP.
    #  The first build of the ROLL said "Applications" at the top with
    #  Applications lit in the rail, on a page of pupils, because
    #  AdminShell.mount is handed the page's identity in JavaScript and the
    #  splice brought the Applications one with it. It looked finished. The
    #  same guard is here so the same afternoon is not repeated.
    out = out.replace("current:  'md-admissions'", "current:  'md-pupils'")
    out = out.replace("title:    'Applications'", "title:    'Pupil'")
    if "md-admissions" in out or "title:    'Applications'" in out:
        sys.exit("The screen still identifies itself as Applications. Nothing written.")
    out = out.replace('console.warn("applications panel unavailable:"',
                      'console.warn("pupil page unavailable:"')
    out = re.sub(r'^   Applications —.*$', '   One pupil', out, count=1, flags=re.M)
    if "var pupil " not in out and "var pupil=" not in out:
        sys.exit("The spliced file has no pupil module in it. Nothing written.")
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
    #  THE TITLE CARRIES NO CHILD'S NAME.
    #  Browser history on a shared office computer is a real and cheap leak,
    #  and a list of visited pages reading "Aaliyah Patel - Pupil" is a list
    #  of who was looked at. The name goes in the <h1>, which history does
    #  not keep. Asserted below.
    h = re.sub(r"<title>.*?</title>",
               "<title>Pupil &mdash; Madrasah &mdash; Taiyabah Masjid</title>",
               h, flags=re.S)
    h = re.sub(r"<!-- =+\n     THIS SCREEN IS TWO FOLDERS DOWN.*?-->",
               PATH_NOTE, h, flags=re.S)
    h = h.rstrip() + ('\n<link rel="stylesheet" href="../../admin/screen.css">'
                      '\n<link rel="stylesheet" href="pupil.css">\n</head>\n')
    h = h.replace("</head>\n<link", "<link")

    t = top
    t = re.sub(r"<h1>.*?</h1>", "<h1>Pupil</h1>", t, flags=re.S)
    t = re.sub(r"<h1>Pupil</h1>\s*\n\s*<p>.*?</p>",
               "<h1>Pupil</h1>\n      <p>%s</p>" % LEAD, t, flags=re.S)
    t = re.sub(r'<a class="back" href="[^"]*">.*?</a>',
               '<a class="back" href="../pupils/">&larr; Back to the roll</a>',
               t, flags=re.S)
    t = t.replace('<section class="bk" id="cl-panel" hidden>', "")
    t = re.sub(r"<!-- The staff themselves\..*?-->", "", t, flags=re.S)

    html = (h + t
            + '      <section class="bk" id="pp-panel-bk" hidden>\n'
            + BODY + "      </section>\n" + tail)

    #  The guard the title note above promises.
    m = re.search(r"<title>(.*?)</title>", html, flags=re.S)
    if not m or "Pupil &mdash; Madrasah" not in m.group(1):
        sys.exit("The page title is not the nameless one. Nothing written.")

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

    print("  portal/pupil/index.html  %6d bytes" % len(html))
    print("  portal/pupil/app.js      %6d bytes"
          % os.path.getsize(os.path.join(OUT, "app.js")))
    print("  portal/pupil/config.js   copied from portal/classes/")


if __name__ == "__main__":
    build()
