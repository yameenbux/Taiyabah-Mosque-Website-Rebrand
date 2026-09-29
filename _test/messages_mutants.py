"""Prove _test/messages_test.py can FAIL.

Each mutant changes one line of a generated screen in a THROWAWAY COPY of the
served files (MSG_SERVE_ROOT), runs the suite against the copy, and requires it
to go red. A suite that has never been seen to fail is decoration. The real
files are never touched.

    python3 _test/messages_mutants.py
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# (file, old, new, what the suite must notice)
MUTANTS = [
    ("portal/parent/messages/app.js", "not for emergencies", "a general channel",
     "the emergency notice's words are changed"),
    ("portal/parent/messages/app.js", '"unread over a weekend, so for anything', '"answered quickly, so for anything',
     "the weekend warning is removed"),
    ("portal/parent/messages/app.js",
     "return '<h2 class=\"pt-h\">Write to the office</h2>' + notice()",
     "return '<h2 class=\"pt-h\">Write to the office</h2>'",
     "the notice is taken out of the compose section"),
    ("portal/parent/messages/app.js", 'return C.call("parent_thread_mark_read", { p_thread: id }).then(loadList, function () {});',
     "return;", "opening no longer marks the reply read"),
    ("portal/parent/messages/app.js", "if (d.thread.unread) {", "if (true) {",
     "a thread that was not unread is marked read anyway"),
    ("portal/parent/messages/app.js", "if (!d || d.allowed === false) {\n          C.fail(\"pm-error\", { code: \"42501\", message: \"not yours\" });\n          return false;\n        }",
     "", "{allowed:false} is treated as an empty list"),
    ("portal/parent/messages/app.js", "C.esc(m[i].body)", "(m[i].body)",
     "a parent's message is not escaped"),
    ("portal/messages/app.js", "esc(m[i].body)", "(m[i].body)",
     "the office does not escape a parent's message"),
    ("portal/parent/messages/app.js", 'C.show("pm-compose", d.thread.state === "closed");', 'C.show("pm-compose", true);',
     "the new-message box stays open beside an open conversation"),
    ("portal/parent/messages/app.js", "(m[i].who === \"office\" ? \"The office\" : m[i].who === \"you\" ? \"You\" : \"Your household\")",
     "(m[i].who)", "who said what is shown raw"),
    ("portal/messages/app.js", '+ (r.state === "open" ? "waiting " + esc(waited(r.days))',
     '+ (r.state === "open" ? "" + esc(waited(r.days))', "the age is no longer said as waiting"),
    ("portal/messages/app.js", "'<span class=\"ms-meta\">Family ' + esc(r.reference)".replace('\\"','"'),
     "'<span class=\"ms-meta\">Family ' + esc(r.reference) + esc(r.family || '')".replace('\\"','"'),
     "a family name is drawn into the list"),
    ("portal/messages/app.js", 'if (!body) { inl.textContent = "Write the reply first."; inl.hidden = false; return; }',
     "", "an empty reply is sent"),
    ("portal/messages/app.js", "if (roles.indexOf(\"admin\") === -1 && roles.indexOf(\"madrasah\") === -1) {",
     "if (false) {", "a role-less account gets the screen"),
    ("portal/messages/app.js", "return afterChange(\"Reply sent.", "return afterChange(\"Done.",
     "the office is not told the reply went"),
    ("portal/messages/app.js", "if (!d || d.allowed === false) { fail(noAccess()); show(\"ms-loading\", false); return; }",
     "", "{allowed:false} on the office list is drawn as an empty list"),
]


def main():
    tmp = tempfile.mkdtemp(prefix="msg_mut_")
    try:
        live = 0
        results = []
        for f, old, new, why in MUTANTS:
            src = os.path.join(ROOT, f)
            text = open(src, encoding="utf-8").read()
            if text.count(old) < 1:
                results.append((why, "MUTANT DOES NOT APPLY (the line changed): fix the mutant"))
                live += 1
                continue
            copy = os.path.join(tmp, "copy")
            if os.path.exists(copy):
                shutil.rmtree(copy)
            shutil.copytree(ROOT, copy, ignore=shutil.ignore_patterns(".git", "img", "__pycache__", "node_modules", ".superpowers"))
            dst = os.path.join(copy, f)
            open(dst, "w", encoding="utf-8").write(text.replace(old, new, 1))
            r = subprocess.run([sys.executable, os.path.join(ROOT, "_test", "messages_test.py")],
                               env=dict(os.environ, MSG_SERVE_ROOT=copy), capture_output=True, text=True, timeout=600)
            red = "FAILURE(S)" in r.stdout
            results.append((why, "caught" if red else "SURVIVED"))
            if not red:
                live += 1
        for why, res in results:
            print("  %-9s %s" % ("red" if res == "caught" else res, why))
        print("\n%d mutants, %d survived" % (len(results), live))
        sys.exit(1 if live else 0)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
