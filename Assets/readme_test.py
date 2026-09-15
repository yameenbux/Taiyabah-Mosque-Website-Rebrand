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

if fails:
    print("\nFAILURES (%d):" % len(fails))
    for f in sorted(set(fails)):
        print("  " + f)
    sys.exit(1)
print("\nALL PASS — %d headings, %d served folders" % (len(heads), len(served)))
