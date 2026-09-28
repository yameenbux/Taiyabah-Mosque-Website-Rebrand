#!/usr/bin/env python3
"""One generator for every madrasah staff screen.

WHY THIS EXISTS, AND WHY IT IS ONE LEVEL UP FROM build_pupils_screen.py.

tools/build_pupils_screen.py opens by saying why a generator is needed at all:
the shell - head, fonts, logo, rail, two-step sign-in panel - is identical on
every staff screen and is most of the file, and "copying it by hand is how two
screens end up subtly different."

That argument is exactly as true of the generators. There were three of them
(fees, admissions, pupils), each with its own copy of the splice, the rail
rename, the assertions and the node --check, and each slightly different: only
the newest two ran the parse check, and only one of them asserted that the
spliced screen had stopped calling itself Applications. Writing four more
copies for Families, Register, Notices and Today would have meant seven places
to fix the next thing found, and six of them would have been missed.

So the per-screen files are now a description - what the screen is called, what
it says, and what goes inside its panel - and every mechanism lives here once.

VALIDATED AGAINST A SCREEN THAT ALREADY WORKS. This module is not trusted
because it looks right. tools/build_pupils_screen.py's output is committed and
has 157 checks against it, so `python3 tools/screen_builder.py --verify-pupils`
regenerates that screen through here and diffs it against what is committed. A
shared builder that cannot reproduce a screen somebody has already reviewed is
not a shared builder, it is a second implementation.
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

#  The shell is read from a screen that is known to work rather than held as a
#  template here, for the reason build_pupils_screen.py gives: a template is a
#  fourth copy of the furniture and drifts from the three real ones.
SHELL = os.path.join(ROOT, "portal", "classes", "index.html")
SRCJS = os.path.join(ROOT, "portal", "admissions", "app.js")

PATH_NOTE = """<!-- ===========================================================
     THIS SCREEN IS TWO FOLDERS DOWN, so every shared asset is reached with
     ../../ and the rail's own script with ../. Getting this wrong does not
     error - the page loads with no styling and no rail, which reads as a
     broken deploy rather than a broken path.
     =========================================================== -->"""


class Screen(object):
    """Everything that differs between one staff screen and the next.

    name       what the rail and the masthead call it, e.g. "Families"
    nav_key    its key in portal/nav.js, e.g. "md-families"
    folder     where it is written, under portal/
    lead       the sentence under the masthead. Says what the screen is FOR,
               in the office's words, not the table's column names.
    panel_id   the id of the panel the module unhides on mount
    module     the module file under tools/
    var_name   the module's own variable, asserted to survive the splice
    css        the stylesheet beside index.html
    body       the markup inside the panel
    actions    optional (label, href) pairs for the masthead buttons
    """

    def __init__(self, name, nav_key, folder, lead, panel_id, module,
                 var_name, css, body, page_title=None):
        self.name = name
        self.nav_key = nav_key
        self.folder = folder
        self.lead = lead
        self.panel_id = panel_id
        self.module = module
        self.var_name = var_name
        self.css = css
        self.body = body
        self.page_title = page_title or name

    @property
    def out(self):
        return os.path.join(ROOT, "portal", self.folder)

    @property
    def module_path(self):
        return os.path.join(ROOT, "tools", self.module)


def read_shell(shell=SHELL):
    if not os.path.exists(shell):
        sys.exit("The shell screen %s is missing. Nothing written." % shell)
    src = open(shell, encoding="utf-8").read()
    for marker in ("<style>", "<body>", 'id="cl-panel"', 'id="app-signout"'):
        if marker not in src:
            sys.exit("The shell has changed - %s is gone. Nothing written, so "
                     "that a screen is not written wrongly." % marker)
    head = src[:src.index("<style>")]
    top = src[src.index("<body>"):src.index('<section class="bk" id="cl-panel" hidden>')]
    tail = src[src.rindex("</section>") + len("</section>"):]
    return head, top, tail


def js_parses(source):
    """Refuse to write JavaScript that does not parse.

    A SCREEN THAT LOADS IS NOT A SCREEN THAT WORKS. One mismatched quote in a
    module - a string opened with ' and closed with " - produced a page that
    fetched its shell, drew the masthead and the rail, and then did nothing at
    all, because the whole script died on a SyntaxError before the module was
    ever defined. It looked like a slow network. Thirteen checks passed
    against it before one finally did not.

    CHECKED BEFORE ANYTHING IS WRITTEN, not after. The first version of this
    wrote the file, checked it, and deleted it if it was bad - which left the
    screen with no app.js at all, so a typo turned a working page into a 404
    instead of leaving yesterday's good build in place. A failed build should
    change nothing.
    """
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


def build_js(screen, srcjs=SRCJS):
    """Splice a screen's module into the Applications screen's auth shell."""
    if not os.path.exists(srcjs):
        sys.exit("portal/admissions/app.js is missing; nothing to take the shell from.")
    if not os.path.exists(screen.module_path):
        sys.exit("The module %s is missing." % screen.module_path)
    src = open(srcjs, encoding="utf-8").read()

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

    body = open(screen.module_path, encoding="utf-8").read().rstrip() + "\n"
    out = src[:start] + body + src[close:]
    out = out.replace("admissions.mount(identity)", "%s.mount(identity)" % screen.var_name)

    #  THE RAIL AND THE HEADING COME FROM THIS BLOCK, NOT FROM THE MARKUP.
    #  The first build of the Pupils screen looked finished and said
    #  "Applications" at the top with Applications lit in the rail, because
    #  AdminShell.mount is handed the page's identity in JavaScript and the
    #  splice brought the Applications one with it.
    out = out.replace("current:  'md-admissions'", "current:  '%s'" % screen.nav_key)
    out = out.replace("title:    'Applications'", "title:    '%s'" % screen.name)
    if "md-admissions" in out or "title:    'Applications'" in out:
        sys.exit("The screen still identifies itself as Applications. Nothing written.")
    out = out.replace('console.warn("applications panel unavailable:"',
                      'console.warn("%s panel unavailable:"' % screen.folder)
    out = re.sub(r'^   Applications —.*$', '   %s' % screen.name,
                 out, count=1, flags=re.M)
    if ("var %s" % screen.var_name) not in out:
        sys.exit("The spliced file has no %s module in it. Nothing written."
                 % screen.var_name)
    if "var admissions" in out:
        sys.exit("The Applications module survived the splice. Nothing written.")
    return out


def build_html(screen):
    head, top, tail = read_shell()

    h = head
    h = re.sub(r"<title>.*?</title>",
               "<title>%s &mdash; Madrasah &mdash; Taiyabah Masjid</title>"
               % screen.page_title, h, flags=re.S)
    h = re.sub(r"<!-- =+\n     THIS SCREEN IS TWO FOLDERS DOWN.*?-->",
               PATH_NOTE, h, flags=re.S)
    #  Furniture first, screen second. admin/screen.css carries the tokens,
    #  the buttons and the sign-in panel; the screen's own sheet carries the
    #  screen.
    h = h.rstrip() + ('\n<link rel="stylesheet" href="../../admin/screen.css">'
                      '\n<link rel="stylesheet" href="%s">\n</head>\n' % screen.css)
    h = h.replace("</head>\n<link", "<link")

    t = top
    t = re.sub(r"<h1>.*?</h1>", "<h1>%s</h1>" % screen.name, t, flags=re.S)
    t = re.sub(r"<h1>%s</h1>\s*\n\s*<p>.*?</p>" % re.escape(screen.name),
               "<h1>%s</h1>\n      <p>%s</p>" % (screen.name, screen.lead),
               t, flags=re.S)
    t = re.sub(r'<a class="back" href="[^"]*">.*?</a>',
               '<a class="back" href="../">&larr; Back to the madrasah portal</a>',
               t, flags=re.S)
    t = t.replace('<section class="bk" id="cl-panel" hidden>', "")
    t = re.sub(r"<!-- The staff themselves\..*?-->", "", t, flags=re.S)

    return (h + t
            + '      <section class="bk" id="%s" hidden>\n' % screen.panel_id
            + screen.body + "      </section>\n" + tail)


def build(screen, quiet=False):
    html = build_html(screen)
    js = build_js(screen)

    #  BOTH ARE PROVED BEFORE EITHER IS WRITTEN. Writing the HTML and then
    #  finding the JavaScript will not parse leaves a screen whose markup is
    #  new and whose behaviour is yesterday's.
    ok, why = js_parses(js)
    if not ok:
        sys.exit("The JavaScript this would have written does not parse, so "
                 "NOTHING was written and the last good build is untouched:"
                 "\n  " + "\n  ".join(why[:4]))

    os.makedirs(screen.out, exist_ok=True)
    open(os.path.join(screen.out, "index.html"), "w", encoding="utf-8").write(html)
    open(os.path.join(screen.out, "app.js"), "w", encoding="utf-8").write(js)
    open(os.path.join(screen.out, "config.js"), "w", encoding="utf-8").write(
        open(os.path.join(ROOT, "portal", "classes", "config.js"),
             encoding="utf-8").read())

    if not quiet:
        print("  portal/%s/index.html  %6d bytes" % (screen.folder, len(html)))
        print("  portal/%s/app.js      %6d bytes" % (screen.folder, len(js)))
        print("  portal/%s/config.js   copied from portal/classes/" % screen.folder)
    return html, js


#  =======================================================================
#  THE CHECK THAT THIS MODULE IS NOT A SECOND IMPLEMENTATION
#  =======================================================================

def verify_pupils():
    """Regenerate the Pupils screen through here and diff it against what is
    committed.

    THE POINT IS THE DIFF, NOT THE RUN. A shared builder that produces
    something almost the same as a reviewed screen is worse than two
    generators, because the difference is invisible and nobody is looking for
    it. If this prints anything other than "identical", the shared builder is
    wrong and the per-screen generator it replaced was right.
    """
    import difflib
    lead = ("Every child on the roll, the class they are in, who teaches them "
            "and who to ring. The list says whether a child has a medical "
            "note; the record says what it is, and writes down who opened it.")
    body = open(os.path.join(ROOT, "tools", "_pupils_body.html"),
                encoding="utf-8").read()
    pupils = Screen(
        name="Pupils", nav_key="md-pupils", folder="pupils", lead=lead,
        panel_id="pu-panel", module="pupils_module.js", var_name="pupils",
        css="pupils.css", body=body)
    html = build_html(pupils)
    js = build_js(pupils)

    bad = 0
    for what, made, path in (("index.html", html, "index.html"),
                             ("app.js", js, "app.js")):
        live = open(os.path.join(ROOT, "portal", "pupils", path),
                    encoding="utf-8").read()
        if made == live:
            print("  %-12s identical" % what)
            continue
        bad += 1
        print("  %-12s DIFFERS" % what)
        for line in list(difflib.unified_diff(
                live.splitlines(), made.splitlines(),
                "committed", "through screen_builder", lineterm=""))[:40]:
            print("    " + line)
    return bad


if __name__ == "__main__":
    if "--verify-pupils" in sys.argv:
        sys.exit(1 if verify_pupils() else 0)
    sys.exit("This module is imported by the per-screen builders. "
             "Run one of those, or --verify-pupils.")
