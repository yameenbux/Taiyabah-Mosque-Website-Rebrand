"""Prove _test/progress_test.py can FAIL.

Each mutant changes one line of a generated screen (or the nav, or the landing
page) in a THROWAWAY COPY of the served files (PRG_SERVE_ROOT), runs the suite
against the copy, and requires it to go red. A suite that has never been seen
to fail is decoration. The real files are never touched.

    python3 _test/progress_mutants.py [words in a mutant's description, to run only those]
"""
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

T = "portal/progress/app.js"
P = "portal/parent/progress/app.js"

# (file, old, new, what the suite must notice)
MUTANTS = [
    # ---- the parent's screen ----
    (P, "C.esc(e.note)", "(e.note)", "a teacher's note is not escaped for a parent"),
    (P, "'<p class=\"pp-by\">'", "'<p class=\"pp-by\">' + C.esc(e.note_internal) + ", "the staff-only key is drawn if it is ever sent"),
    (P, 'if (!p.entries.length) return h + nothingShared(p.first_name) + "</section>";', "", "nothing shared is drawn as a blank section"),
    (P, "That is not a \"\n           + \"judgement of", "That is a \"\n           + \"judgement of", "the empty page stops saying it is not a judgement"),
    (P, '"From " + C.esc(e.teacher)', '"" + C.esc(e.teacher)', "the teacher's name is no longer said as from"),
    (P, 'C.call("parent_progress", { p_pupil: k.pupil_id })', 'C.call("progress_child", { p_pupil: k.pupil_id })', "the parent's screen calls a staff function"),
    (P, 'line("Manzil", "older revision", e.manzil)', '""', "manzil is dropped from the parent's page"),
    (P, "C.show(\"pp-fine\", any);", "C.show(\"pp-fine\", true);", "the footnote is drawn when nothing is shared"),
    # ---- the teacher's screen ----
    (T, "var shared = !!e.shared;", "var shared = true;", "a NEW entry starts on Share"),
    (T, "p_shared: shared, p_id: EDIT ? EDIT.id : null", "p_shared: false, p_id: EDIT ? EDIT.id : null", "the choice to share is not sent"),
    (T, "p_shared: shared, p_id: EDIT ? EDIT.id : null", "p_shared: shared, p_id: null", "an amendment does not pass the entry's id"),
    (T, "if (!sabaq && !sabqi && !manzil && !forp && !mine) {", "if (false) {", "an empty entry is sent"),
    (T, "if (shared && !sabaq && !sabqi && !manzil && !forp) {", "if (false) {", "an own note alone can be shared"),
    ("portal/progress/index.html", "whatever you choose", "as you like", "the rule stops saying the own note is never shown whatever is chosen"),
    ("portal/progress/index.html", "Two kinds of note.", "Notes.", "the rule stops saying there are two kinds of note"),
    (T, "Your own note <span class=\"tp-staff\">staff only</span>", "Your own note", "the own note is no longer marked staff only"),
    (T, "esc(e.note_internal) + \"</p>\"", "e.note_internal + \"</p>\"", "the own note is not escaped"),
    (T, "if (!d || d.allowed === false) { fail(refused()); show(\"tp-kids-wrap\", false); return; }", "", "{allowed:false} on a class is drawn as an empty list"),
    (T, "if (!d || d.allowed === false) { fail(noAccess()); return; }", "", "{allowed:false} on the class list is drawn as an empty screen"),
    (T, "+ '\" max=\"' + esc(todayIso()) + '\"></div>'", "+ '\"></div>'", "the date can be a future day"),
    (T, "(e.shared ? \"Shared with the family\" : \"Not shared\")", "(e.shared ? \"Shared\" : \"\")", "an entry no longer says whether it is shared"),
    (T, "if (CLASSES.length === 1) return openClass(CLASSES[0].id);", "", "one class no longer opens itself"),
    (T, "call(\"progress_class_children\", { p_class: id })", "call(\"progress_class_children\", { p_class: CLASSES[0].id })", "choosing a class asks for the first class"),
    ("portal/app.js", 'live: true, href: "progress/",', "live: true,", "the landing tile is not a link"),
    ("portal/app.js", 'live: true, href: "progress/",', "", "the landing tile is not live"),
    ("portal/nav.js", "needs: ANYSTAFF,\n          what: \"Where each child", "needs: BOTH,\n          what: \"Where each child", "a teacher is not offered the row"),
    ("portal/nav.js", "needs: ANYSTAFF,\n          what: \"Where each child", "needs: ANYSTAFF, soon: true,\n          what: \"Where each child", "the built row is still marked soon"),
    ("portal/nav.js", "name: \"Merits\",\n          needs: BOTH, soon: true", "name: \"Merits\",\n          needs: BOTH", "a neighbouring unbuilt row lost its soon"),
]


def main():
    tmp = tempfile.mkdtemp(prefix="prg_mut_")
    try:
        live = 0
        results = []
        for f, old, new, why in MUTANTS:
            if len(sys.argv) > 1 and not any(a in why for a in sys.argv[1:]):
                continue
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
            r = subprocess.run([sys.executable, os.path.join(ROOT, "_test", "progress_test.py")],
                               env=dict(os.environ, PRG_SERVE_ROOT=copy), capture_output=True, text=True, timeout=900)
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
