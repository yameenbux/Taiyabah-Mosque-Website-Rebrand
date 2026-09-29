#!/usr/bin/env python3
"""Write the parents' portal: portal/parent/, .../attendance/, .../progress/, .../absence/, .../messages/.

The mechanism lives in tools/screen_builder.py; this file is the description of
the four screens. See the section headed THE PARENTS' PORTAL in that file for
what differs from a staff screen (no two-step, its own rail, its own words on
the password gate) and why each difference is a patch on the staff shell and
not a second shell.

portal/parent/nav.js is written by hand and is not generated: it is a short
list, and it is the thing that decides what a parent is shown.

    python3 tools/build_parent_screens.py

Each screen is checked for ES5 (no arrow functions, const, let, template
literals or spread) here, as well as parsed: `node --check` accepts modern
syntax, and the phones some parents use do not.
"""
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from screen_builder import Screen, build, ROOT  # noqa: E402


def body(name):
    return open(os.path.join(ROOT, "tools", name), encoding="utf-8").read()


SCREENS = [
    Screen(
        name="My children", nav_key="pt-children", folder="parent",
        lead=("What the madrasah holds about each of your children: their "
              "class and teacher, and the medical, allergy, contact and "
              "address details on their record. If any of it is wrong, this "
              "is where you check, and the page says how to tell us."),
        panel_id="pk-panel", module="parent_children_module.js",
        var_name="parentKids", css="parent.css",
        body=body("_parent_children_body.html"),
        audience="parent", depth=2, preamble="parent_common.js"),
    Screen(
        name="Attendance", nav_key="pt-attendance", folder="parent/attendance",
        lead=("Your child's marks, evening by evening, with the reason where "
              "one was given and whether the madrasah or you recorded it."),
        panel_id="pa-panel", module="parent_attendance_module.js",
        var_name="parentAtt", css="../parent.css",
        body=body("_parent_attendance_body.html"),
        audience="parent", depth=3, preamble="parent_common.js"),
    Screen(
        name="Progress", nav_key="pt-progress", folder="parent/progress",
        lead=("What your child's teacher has chosen to share about how they "
              "are getting on, newest first, with the date and the teacher's "
              "name."),
        panel_id="pp-panel", module="parent_progress_module.js",
        var_name="parentProgress", css="../parent.css",
        body=body("_parent_progress_body.html"),
        audience="parent", depth=3, preamble="parent_common.js"),
    Screen(
        name="Report an absence", nav_key="pt-absence", folder="parent/absence",
        lead=("Tell the madrasah that your child will be away or late, for "
              "tonight or an evening in the last fortnight."),
        panel_id="pb-panel", module="parent_absence_module.js",
        var_name="parentAbsence", css="../parent.css",
        body=body("_parent_absence_body.html"),
        audience="parent", depth=3, preamble="parent_common.js"),
    Screen(
        name="Messages", nav_key="pt-messages", folder="parent/messages",
        lead=("Write to the madrasah office and read what they write back. "
              "Either parent on your family can read the reply."),
        panel_id="pm-panel", module="parent_messages_module.js",
        var_name="parentMessages", css="../parent.css",
        body=body("_parent_messages_body.html"),
        audience="parent", depth=3, preamble="parent_common.js"),
]

BANNED = [
    (r"=>", "an arrow function"),
    (r"(?<![\w.$])const\s", "const"),
    (r"(?<![\w.$])let\s", "let"),
    (r"`", "a template literal"),
    (r"\.\.\.", "spread or rest"),
    (r"(?<![\w.$])async\s", "async"),
    (r"(?<![\w.$])await\s", "await"),
]


def es5_problems(path):
    """Refuse anything that is not ES5.

    acorn --ecma5 is a real parser and is used wherever it is installed
    (it ships with node). The fallback is a scan for the seven constructs the
    project bans, after block and line comments are removed; it is coarser -
    a regex literal holding a quote can fool it - and says so when it runs.
    """
    acorn = shutil.which("acorn")
    if acorn:
        r = subprocess.run([acorn, "--ecma5", "--silent", path],
                           capture_output=True, text=True)
        if r.returncode:
            return ["%s: %s" % (os.path.basename(path),
                                (r.stderr or r.stdout).strip().splitlines()[0]
                                .replace(path, "the file"))]
        return []
    print("  (acorn not installed: falling back to a line scan for %s)"
          % os.path.basename(path))
    src = open(path, encoding="utf-8").read()
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    out = []
    for n, line in enumerate(src.splitlines(), 1):
        code = re.sub(r"(?<![:\"'])//.*$", "", line)
        for pat, what in BANNED:
            if re.search(pat, code):
                out.append("%s:%d: %s" % (os.path.basename(path), n, what))
    return out


if __name__ == "__main__":
    bad = []
    for scr in SCREENS:
        bad += es5_problems(scr.module_path)
    bad += es5_problems(os.path.join(ROOT, "tools", "parent_common.js"))
    bad += es5_problems(os.path.join(ROOT, "portal", "parent", "nav.js"))
    if bad:
        sys.exit("Not ES5, so NOTHING was written:\n  " + "\n  ".join(bad))
    for scr in SCREENS:
        print(scr.name)
        build(scr)
