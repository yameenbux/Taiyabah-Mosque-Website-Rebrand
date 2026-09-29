#!/usr/bin/env python3
"""
Structural check for index_template.html.

Catches the class of bug that broke seven pages in August 2026: a single
missing </div> left the Hall Hire page unclosed, so every page after it became
a child of it and had nowhere to render. Clicking those pages changed the nav
highlight and the URL, and showed nothing.

Nothing here needs a browser. Run it before every build:

    python3 verify_structure.py && python3 build.py

Exit code 0 = clean, 1 = problems found.
"""

import glob
import re
import sys
from collections import Counter

TEMPLATE = "index_template.html"
VOID = {"img", "br", "hr", "input", "meta", "link", "source", "track", "wbr", "col", "area", "base"}


def page_regions(src):
    """Yield (name, text) for each .page block, split at the next page or </main>."""
    starts = [m.start() for m in re.finditer(r'<div class="page" data-page="', src)]
    if not starts:
        return []
    end = src.index("</main>")
    bounds = starts + [end]
    out = []
    for i in range(len(starts)):
        chunk = src[bounds[i]:bounds[i + 1]]
        name = re.search(r'data-page="([^"]+)"', chunk).group(1)
        out.append((name, chunk))
    return out


def main():
    src = open(TEMPLATE, encoding="utf-8").read()
    problems = []

    # 1. every page block must balance its divs, or the next page gets swallowed
    for name, chunk in page_regions(src):
        depth = len(re.findall(r"<div\b", chunk)) - len(re.findall(r"</div>", chunk))
        if depth != 0:
            word = "unclosed" if depth > 0 else "over-closed"
            problems.append(
                "page '%s' has %d %s <div> — the next page will be nested inside it"
                % (name, abs(depth), word)
            )

    # 2. whole-document div balance
    total = len(re.findall(r"<div\b", src)) - len(re.findall(r"</div>", src))
    if total != 0:
        problems.append("document-wide <div> imbalance: %+d" % total)

    # 3. every data-nav must point at a page that exists
    pages = set(re.findall(r'data-page="([^"]+)"', src))
    for target in set(re.findall(r'data-nav="([^"]+)"', src)):
        if target not in pages and not target.startswith("'"):
            problems.append("data-nav=\"%s\" points at a page that does not exist" % target)

    # 4. scroll targets and #anchors must resolve
    ids = set(re.findall(r'\sid="([^"]+)"', src))
    for target in set(re.findall(r'data-scroll-to="([^"]+)"', src)):
        if target not in ids:
            problems.append('data-scroll-to="%s" has no matching element id' % target)
    for anchor in set(re.findall(r'href="#([^"]+)"', src)):
        if anchor and anchor not in ids:
            problems.append('href="#%s" has no matching element id' % anchor)

    # 5. duplicate ids silently break getElementById
    for elem_id, count in Counter(re.findall(r'\sid="([^"]+)"', src)).items():
        if count > 1:
            problems.append('id="%s" appears %d times — getElementById will pick one' % (elem_id, count))

    # 6. unsubstituted build placeholders
    for ph in set(re.findall(r"\{\{[A-Z_]+\}\}", src)):
        if ph not in open("build.py", encoding="utf-8").read():
            problems.append("%s is used in the template but build.py does not define it" % ph)

    # 7. A portal tile must not disagree with the paragraph under it.
    #
    #    This check exists because of a real near-miss. Thirty-nine teachers
    #    were given working logins while the Teachers Portal tile still read
    #    "Preview" and the paragraph beneath it still said the sign-in screens
    #    "are not yet connected and no account will work." Both sentences were
    #    true when they were written and neither was reviewed when the accounts
    #    were built. The first thing a teacher holding a slip would have read
    #    is the site telling them not to bother.
    #
    #    The tile is one edit and the paragraph is another, so a person doing
    #    half the job leaves no visible mark. This makes the half-done state
    #    fail the build instead.
    for who in ("Parents", "Teachers"):
        m = re.search(
            r'<span class="sh-label">%s Portal</span>\s*'
            r'<span class="live-tag">([^<]+)</span>' % who, src)
        if not m:
            problems.append("the %s Portal tile has gone, or its markup changed — "
                            "check 7 in verify_structure.py can no longer see it" % who)
            continue
        live = m.group(1).strip().lower() != "preview"
        #  The paragraph names each audience and says whether it is open.
        says_shut = re.search(
            r"<strong>%s:</strong>[^<]*?(not open yet|will not work|no \w+ account)"
            % who, src, re.S | re.I) is not None
        if live and says_shut:
            problems.append(
                '%s Portal tile says "%s" but the paragraph under it still tells '
                "%s their accounts do not work" % (who, m.group(1), who.lower()))
        if not live and not says_shut:
            problems.append(
                "%s Portal tile says Preview but the paragraph does not tell %s "
                "their portal is not open — somebody will try to sign in"
                % (who, who.lower()))

    # 8. A new file in the repository root is a public web page.
    #
    #    _config.yml excludes README.md, DEPLOY.md and DONATIONS.md BY NAME, not
    #    by "*.md". So the next .md or .txt somebody drops in the root is live on
    #    the masjid's website at a guessable address the moment it is pushed.
    #
    #    This check was written after CLAUDE.md — a file whose whole subject is
    #    "this repository is public and pushing is deploying" — was created in
    #    the root and would itself have been published. It is not a hypothetical
    #    failure mode: _config.yml's own comments record the build scripts, the
    #    database migrations, a working-notes file that sat live for a fortnight,
    #    and a confidential DPIA, all published or nearly published this way.
    import os
    cfg = open("_config.yml", encoding="utf-8").read()
    excluded = set(re.findall(r'^\s+-\s+"?([^"\n]+?)"?\s*$', cfg, re.M))
    for name in sorted(os.listdir(".")):
        if not os.path.isfile(name):
            continue
        if not name.lower().endswith((".md", ".txt", ".yaml", ".json", ".csv")):
            continue
        if name in ("_config.yml", "CNAME", "robots.txt", "robots.live.txt",
                    "sitemap.xml", "manifest.json", "site.webmanifest"):
            continue
        if name in excluded:
            continue
        problems.append(
            '%s sits in the repository root and _config.yml does not exclude it '
            "— GitHub Pages will publish it on the masjid's website. Add it to "
            "exclude:, or delete it." % name)

    # 9. The Notices screen's own record of "which version was this family
    #    told about" must match the version the privacy notice is actually
    #    at.
    #
    #    tools/build_privacy_page.py sets VERSION for the published notice.
    #    tools/notices_module.js sets its own VERSION by hand, spliced into
    #    portal/notices/app.js, and sent as p_version whenever a family is
    #    recorded as told. Nothing compared the two, and the notices module
    #    stayed at "1.2" through v1.3, v1.4, v1.5 and the first draft of
    #    v1.6 - so every family recorded as told from that screen would have
    #    been recorded, permanently, against a version that told parents the
    #    madrasah held no date of birth, address, telephone number or
    #    medical information. That is the one place the Article 13 duty to
    #    parents is evidenced, and it would have been wrong for all 330
    #    families before anyone noticed.
    notices_js = open("tools/notices_module.js", encoding="utf-8").read()
    privacy_py = open("tools/build_privacy_page.py", encoding="utf-8").read()
    m_notices_version = re.search(r'var VERSION = "([^"]+)";', notices_js)
    m_privacy_version = re.search(r'^VERSION = "([^"]+)"', privacy_py, re.M)
    if not m_notices_version:
        problems.append(
            "tools/notices_module.js has no `var VERSION = \"...\";` — check 9 "
            "in verify_structure.py can no longer find it")
    elif not m_privacy_version:
        problems.append(
            "tools/build_privacy_page.py has no `VERSION = \"...\"` — check 9 "
            "in verify_structure.py can no longer find it")
    elif m_notices_version.group(1) != m_privacy_version.group(1):
        problems.append(
            'tools/notices_module.js VERSION is "%s" but tools/build_privacy_page.py '
            'VERSION is "%s" — a family recorded as told from the Notices screen '
            "would be recorded against the wrong version of the privacy notice. "
            "Change tools/notices_module.js to match, then regenerate with "
            "python3 tools/build_notices_screen.py."
            % (m_notices_version.group(1), m_privacy_version.group(1)))

    #  CHECK 10 — THE PASSWORD GATE MUST NOT REACH OUTSIDE ITSELF.
    #
    #  mustChangeGate() is the forced password change every new login meets,
    #  and it is deliberately self-contained: its own styles, its own markup,
    #  its own overlay, so that it works on whichever screen somebody opens
    #  first. One line broke that. The greeting called esc(), which in every
    #  one of these files is a LOCAL of some other function, so the gate threw
    #  "esc is not defined" the moment it tried to greet anybody by name.
    #
    #  Every teacher login is created with a name and with
    #  must_change_password set, so that was the first screen all 39 would
    #  have met, and the failure is a blank overlay with nothing in the
    #  console anybody was watching. It is the second fault this project has
    #  had that made every teacher login unusable; db/094 was the first.
    #
    #  A comment saying "keep this self-contained" would not have caught it.
    #  This does. Found 29 September by _test/parent_portal_test.py, because
    #  a parent meets this screen before any other.
    gate_files = sorted(glob.glob("portal/**/app.js", recursive=True))
    for gf in gate_files:
        src_gate = open(gf, encoding="utf-8").read()
        lines = src_gate.split("\n")
        start = end = -1
        for i, line in enumerate(lines):
            if line.startswith("  function mustChangeGate("):
                start = i
            elif start >= 0 and end < 0 and line.rstrip() == "  }":
                end = i
        if start < 0:
            continue
        body = "\n".join(lines[start:end + 1])
        body = re.sub(r"/\*[\s\S]*?\*/", "", body)
        body = re.sub(r"^\s*//.*$", "", body, flags=re.M)
        if "function pwEsc(" not in body:
            problems.append(
                "%s: mustChangeGate() no longer defines its own pwEsc(). The "
                "gate must escape with a function of its own — check 10." % gf)
        #  Only an identifier the gate CALLS but does not DEFINE is out of
        #  scope. fail() and say() are defined inside the gate and are fine;
        #  esc() was not, and that was the whole fault.
        called = set(re.findall(r"[^.\w]([a-z][A-Za-z0-9_]*)\s*\(", body))
        defined = set(re.findall(r"function\s+([A-Za-z0-9_]+)\s*\(", body))
        stray = sorted((called & {"esc", "el", "say", "fail", "sb", "who",
                                  "toast", "note", "render", "draw"})
                       - defined)
        if stray:
            problems.append(
                "%s: mustChangeGate() calls %s, which is a local of another "
                "function in this file and is NOT in the gate's scope. It will "
                "throw at the first sign-in of every new account. Give the gate "
                "its own, as pwEsc() is — check 10."
                % (gf, ", ".join(x + "()" for x in stray)))

    if problems:
        print("STRUCTURE CHECK FAILED (%d)" % len(problems))
        for p in problems:
            print("  -", p)
        return 1

    print("structure OK — %d pages, all divs balanced, all links resolve" % len(pages))

    # 7. Donation links that would silently take no money.
    #    Two ways this goes wrong, and neither shows on screen:
    #      a) a link still pointing at the old WordPress site — 404 once the
    #         domain moves, but the button still looks fine;
    #      b) a Stripe link created in TEST mode — a complete, convincing
    #         checkout that never charges anyone.
    warnings = []
    stale = sorted(set(re.findall(r'https://www\.taiyabahmasjid\.com/product/[a-z0-9-]+/', src)))
    if stale:
        warnings.append(("%d DONATE LINK(S) STILL POINT AT THE OLD WORDPRESS SITE" % len(stale),
                         stale,
                         "These break the moment taiyabahmasjid.com points at THIS site."))
    testmode = sorted(set(re.findall(r'https://buy\.stripe\.com/test_[A-Za-z0-9]+', src)))
    if testmode:
        warnings.append(("%d STRIPE LINK(S) ARE IN TEST MODE" % len(testmode),
                         testmode,
                         "These look like a real checkout and take no money at all."))
    for head, urls, why in warnings:
        print("")
        print("  " + "!" * 68)
        print("  !!  " + head)
        print("  !!")
        for u in urls:
            print("  !!    " + u)
        print("  !!")
        print("  !!  " + why)
        print("  !!  See DONATIONS.md.")
        print("  " + "!" * 68)
        print("")

    return 0


if __name__ == "__main__":
    sys.exit(main())
