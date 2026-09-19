"""The README describes this repository. This checks it still does.

A README goes stale silently: it keeps rendering, every link keeps looking
like a link, and nobody notices until somebody follows one. Three of these
assertions found real faults the first time they ran — a link to a heading
that never existed, a script the README told you to run that is not in the
repository, and a folder list that had fallen four folders behind.

Run:  python3 _test/readme_test.py
"""
import os, re, sys, pathlib

ROOT = pathlib.Path(os.environ.get("SITE_ROOT") or
                    pathlib.Path(__file__).resolve().parent.parent)
os.chdir(ROOT)
s = (ROOT / "README.md").read_text()
fails = []


def check(cond, msg):
    if not cond:
        fails.append(msg)


#  GitHub slugs a heading by lowercasing, dropping anything that is not a
#  letter, number, space or hyphen, then replacing EACH space with a hyphen —
#  it does not collapse runs. Both spellings are accepted here so the test is
#  about dead links, not about one renderer's edge case.
def slugs(h):
    h = re.sub(r"[^\w\s-]", "", h.strip().lower(), flags=re.UNICODE)
    return {re.sub(r"\s", "-", h), re.sub(r"\s+", "-", h)}


heads = set()
for m in re.finditer(r"^#{1,6}\s+(.*)$", s, re.M):
    heads |= slugs(m.group(1))
for m in re.finditer(r"\]\(#([^)]+)\)", s):
    check(m.group(1) in heads, "dead link in the README: #%s" % m.group(1))

#  Every path with a directory in it must exist. A bare filename may live
#  anywhere, so it is only checked if nothing in the tree matches.
for m in re.finditer(r"`([\w./-]+\.(?:sql|py|ts|html|js|yml|txt|xml|ico|jpg))`", s):
    f = m.group(1)
    #  The README names these precisely BECAUSE they are missing. Skipping
    #  them here is not looking away: the sentence that names them is the
    #  warning, and a test that failed on it would push somebody to delete
    #  the warning rather than find the file.
    if "<" in f or f.endswith("022_donations_and_gift_aid.sql"):
        continue
    if "/" in f:
        check(pathlib.Path(f).exists(),
              "the README names %s, which is not in this repository" % f)
    else:
        check(any(ROOT.rglob(f)),
              "the README names %s, which is nowhere in this repository" % f)

for m in re.finditer(r"!\[[^\]]*\]\(([^)]+)\)", s):
    check(pathlib.Path(m.group(1)).exists(), "missing image: %s" % m.group(1))

#  THE FOLDER LIST. This is the assertion that goes stale first: a new staff
#  area is built, and the README keeps listing the old set.
served = sorted(d.name for d in ROOT.iterdir()
                if d.is_dir() and (d / "index.html").exists())
#  Asserted against the ROW SPELLING used in that table, not "does the name
#  appear anywhere". The loose version passed a control that deleted the row,
#  because the folder was still named in a paragraph further down — which is
#  the whole failure this is meant to catch.
for d in served:
    check(("**`%s/`**" % d) in s,
          "%s/ is served to the public and is not a row in the README's "
          '"What is in here" table' % d)

#  And the migrations. Same failure, one layer down.
for f in sorted((ROOT / "db").glob("0*.sql")):
    n = f.name
    if "_test" in n or "PRECHECK" in n or "ROLLBACK" in n:
        continue
    stem = n[:-4]
    check(stem in s or stem.split("_")[0] in s,
          "db/%s is applied and the README does not list it" % n)

#  =========================================================================
#  .gitattributes MARKS ONE GENERATED FILE, NOT SEVENTEEN HAND-WRITTEN ONES
#
#  Found on 18 September, three days after the rule was added. A
#  .gitattributes pattern with no slash in it matches a file of that name at
#  EVERY level, exactly like .gitignore. Written as `index.html`, the rule
#  meant for the one 624 KB generated page at the root was silently applied to
#  all seventeen index.html files in this repository — every madrasah screen,
#  /venue/, /apply/, the lot.
#
#  The cost was not cosmetic. `-diff` makes git print "Binary files differ",
#  so no change to any hand-written screen could be read as a diff by anybody,
#  and `linguist-generated` told GitHub to collapse them in pull requests as
#  machine output. It had already hidden a real fault: two portal files went
#  stale in an upload zip and the only way to catch it was comparing tree
#  hashes by hand.
#
#  The fix is one character — a leading slash — which is exactly the kind of
#  fix that gets undone by somebody tidying the file. So it is asserted, and
#  asserted by ASKING GIT rather than by reading the pattern: git is the thing
#  whose opinion matters, and a regex over .gitattributes would pass on a
#  pattern spelled some other equally leaky way.
#  =========================================================================
import subprocess

hand_written = sorted(str(p.relative_to(ROOT)) for p in ROOT.glob("*/index.html"))
hand_written += sorted(str(p.relative_to(ROOT)) for p in ROOT.glob("*/*/index.html"))
hand_written = [p for p in hand_written if not p.startswith(("_", "."))]
check(len(hand_written) >= 10,
      "only %d hand-written index.html files found — this check is not looking "
      "at the repository it thinks it is" % len(hand_written))

if hand_written:
    out = subprocess.run(["git", "check-attr", "diff", "linguist-generated", "--"]
                         + hand_written, capture_output=True, text=True).stdout
    marked = sorted(set(
        ln.rsplit(":", 2)[0] for ln in out.splitlines()
        if ln.endswith(": diff: unset") or ln.endswith(": linguist-generated: true")))
    check(not marked,
          ".gitattributes marks %d HAND-WRITTEN page(s) as generated output: %s. "
          "A pattern with no leading slash matches at every level, so `index.html` "
          "means all of them and `/index.html` means the one at the root. The "
          "effect is that no change to these screens can be read as a diff — by "
          "anybody, including the person reviewing a fix to them."
          % (len(marked), ", ".join(marked[:4]) + (" …" if len(marked) > 4 else "")))

#  And the generated one IS still marked, or the rule has been deleted rather
#  than fixed and eight thousand lines of machine output come back into every
#  diff. Both halves, because a check that only asserts the first half passes
#  on an empty .gitattributes.
gen = subprocess.run(["git", "check-attr", "diff", "--", "index.html"],
                     capture_output=True, text=True).stdout
check("diff: unset" in gen,
      "the generated index.html is no longer marked `-diff`. It is 624 KB of "
      "build output, and rendering its diff is what made git appear to crash on "
      "a phone. Anchor the pattern, do not remove it.")

if fails:
    print("\nFAILURES (%d):" % len(fails))
    for f in sorted(set(fails)):
        print("  " + f)
    sys.exit(1)
print("\nALL PASS — %d headings, %d served folders, %d pages that diff normally"
      % (len(heads), len(served), len(hand_written)))
