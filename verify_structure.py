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

    if problems:
        print("STRUCTURE CHECK FAILED (%d)" % len(problems))
        for p in problems:
            print("  -", p)
        return 1

    print("structure OK — %d pages, all divs balanced, all links resolve" % len(pages))
    return 0


if __name__ == "__main__":
    sys.exit(main())
