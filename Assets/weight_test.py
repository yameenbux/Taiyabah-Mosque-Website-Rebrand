"""What the site WEIGHS, and the shape of the critical path.

15 September 2026. Page weight is the classic thing that rots without anybody
deciding to let it: nobody ever commits "make the site 4 KB slower", it just
happens forty times. These are budgets, not measurements — they fail when
somebody spends the improvement rather than when the site is merely large.

The numbers come from a measured change on 15 September. Fraunces and Hanken
Grotesk used to be base64'd into the document; taking them out cut the
render-blocking HTML from 291 KB gzipped to 168 KB and the first paint on a
throttled phone from 1096 ms to 668 ms. These checks exist so that cannot be
undone by accident.

WHAT IT GUARDS

  *  1  THE DOCUMENT STAYS UNDER ITS GZIPPED BUDGET. GitHub Pages compresses
        text, so the number a visitor actually waits for is the compressed
        one, and that is what is budgeted.

  *  2  NO FONT IS EVER INLINED AGAIN. woff2 is already compressed; base64
        inflates it by a third and gzip cannot win that back, so an inlined
        font is pure loss on the one resource that blocks the first paint.
        It also silently defeats unicode-range — see build.py's fonts().

  *  3  THE LATIN FACES ARE PRELOADED. Without it the browser does not
        discover them until it has parsed the stylesheet, which is most of
        the benefit of point 2 given away again.

  *  4  EVERY FONT THE CSS ASKS FOR EXISTS. A url() pointing at a file that
        was never written is a 404 and a page set in Times New Roman, and it
        would look completely fine in this container, where the build has
        just run.

  *  5  EVERY FACE SETS font-display. Without swap the browser hides the text
        for up to three seconds while it waits, which on a bad connection is
        a blank white page for somebody who could have been reading.

  *  6  EVERY NON-LATIN FACE HAS A METRIC-MATCHED FALLBACK. Amiri's ascent is
        112.4% of the em against roughly 100% for an ordinary serif, so
        swapping it in grew one line in the hero by 14px and pushed the whole
        page down while somebody was reading. Measured CLS 0.0235, fixed by
        an 'Amiri fallback' face, now 0.0013.

  *  7  THE 404 IS TINY. It exists to say one sentence.

Run:  python3 _test/weight_test.py
"""
import gzip
import os
import re
import sys

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)

fails = []


def check(ok, why):
    if not ok:
        fails.append(why)


#  Budgets, in KB of gzipped bytes. Set a little above where the site actually
#  sits, so ordinary editing does not trip them, but close enough that adding
#  a photograph as a data URI or re-inlining a font does.
DOC_BUDGET_KB = 200        # measured 168 on 15 September 2026
PAGE_404_BUDGET_KB = 10    # measured 2.4

html = open("index.html", "rb").read()
doc_kb = len(gzip.compress(html, 9)) / 1024
check(doc_kb <= DOC_BUDGET_KB,
      "index.html is %.0f KB gzipped, over the %d KB budget. Something large "
      "has been inlined — check for a new data: URI, and read build.py's "
      "fonts() before deciding the budget is simply too small."
      % (doc_kb, DOC_BUDGET_KB))

text = html.decode("utf-8", "replace")

#  2. No inlined fonts, anywhere.
inlined = re.findall(r'data:font/[a-z0-9+.-]+;base64', text)
check(not inlined,
      "%d font(s) are inlined as data URIs in index.html. woff2 is already "
      "compressed, so base64 inflates it by a third for nothing, and it "
      "defeats unicode-range — every visitor then downloads the latin-ext "
      "subset that nothing on this site uses. See build.py fonts()."
      % len(inlined))

#  3. The two families that set the first screen are preloaded.
preloads = re.findall(r'<link[^>]+rel="preload"[^>]+as="font"[^>]*>', text)
for want in ("fraunces-latin.woff2", "hanken-grotesk-latin.woff2"):
    check(any(want in p for p in preloads),
          "fonts/%s is not preloaded. The browser will not discover it until "
          "it has parsed the stylesheet." % want)
for p in preloads:
    check("crossorigin" in p,
          "a font preload has no crossorigin attribute, so the browser will "
          "fetch the font TWICE — fonts are always fetched anonymously: %s"
          % p[:90])
    check("latin-ext" not in p,
          "a latin-ext subset is being preloaded. Nothing on this site needs "
          "Central European glyphs up front: %s" % p[:90])

#  4. Everything the CSS asks for is actually on disk.
for url in sorted(set(re.findall(r'url\((fonts/[^)]+)\)', text))):
    check(os.path.exists(url),
          "the stylesheet asks for %s and it does not exist — that is a 404 "
          "and a page set in a fallback" % url)

#  5 and 6. Every face declares font-display, and every family that is not a
#  plain Latin one has a metric-matched fallback declared alongside it.
faces = re.findall(r'@font-face\s*\{([^}]*)\}', text)
check(len(faces) >= 5, "expected at least five @font-face blocks, found %d" % len(faces))
for f in faces:
    fam = re.search(r"font-family:\s*['\"]?([^;'\"]+)", f)
    name = fam.group(1).strip() if fam else "(unnamed)"
    #  A fallback face is a re-declaration of a font the device already has;
    #  it downloads nothing, so font-display does not apply to it.
    if "fallback" in name.lower():
        check("ascent-override" in f,
              "the '%s' face overrides no metrics, so it does nothing at all" % name)
        continue
    check("font-display" in f,
          "the '%s' face does not set font-display, so the browser may hide "
          "the text for up to three seconds waiting for it" % name)

#  Written out plainly rather than as one clever comprehension: the first
#  version of this was a nested generator that was very hard to read and
#  impossible to be sure of, which is the wrong quality for a test.
declared = []
for f in faces:
    fam = re.search(r"font-family:\s*['\"]?([^;'\"]+)", f)
    if fam:
        declared.append(fam.group(1).strip().lower())

for family in ("Fraunces", "Hanken", "Amiri"):
    want = family.lower() + " fallback"
    check(want in declared,
          "%s has no metric-matched fallback face ('%s'). When it swaps in, "
          "every line set in it changes height and the page moves under the "
          "reader — that is exactly how Amiri shifted the hero 14px."
          % (family, want))
    #  And it has to be USED, not merely declared. A fallback family that no
    #  stack names is 200 bytes of decoration.
    check(('"%s"' % want) in text.lower() or ("'%s'" % want) in text.lower(),
          "the '%s' face is declared but no font stack names it, so nothing "
          "ever uses it" % want)

#  THE STAFF SCREENS. Twelve standalone pages that are not built from a
#  template, so anything common to them is either duplicated or shared through
#  a file. The fonts were duplicated: 162 KB of base64 per page, 2 MB across
#  the folder, the same four faces every time, all of it blocking the first
#  paint — and a committee member moving between three screens downloaded them
#  three times. They share admin/fonts.css now.
STAFF = ["portals", "venue", "courses", "giftaid", "volunteers", "collections",
         "access", "newbuild", "portal", "apply", "account", "auth", "times",
         "notices", "rates", "classpages"]
STAFF_BUDGET_KB = 30   # the heaviest measured 23 on 15 September 2026

check(os.path.exists("admin/fonts.css"),
      "admin/fonts.css is missing — every staff screen links to it, so all "
      "twelve would fall back to a system font at once")

for d in STAFF:
    page = os.path.join(d, "index.html")
    if not os.path.exists(page):
        continue
    raw = open(page, "rb").read()
    kb = len(gzip.compress(raw, 9)) / 1024
    body = raw.decode("utf-8", "replace")

    check("data:font/woff2" not in body,
          "%s/ has gone back to inlining its fonts. That is 123 KB gzipped on "
          "the one resource that blocks its first paint, and it is the same "
          "123 KB the other eleven screens already have." % d)
    check(kb <= STAFF_BUDGET_KB,
          "%s/index.html is %.0f KB gzipped, over the %d KB staff budget"
          % (d, kb, STAFF_BUDGET_KB))
    check("admin/fonts.css" in body,
          "%s/ does not link admin/fonts.css, so it has no fonts at all" % d)

#  THE SUPABASE LIBRARY, ONCE. It was vendored INSIDE every staff page —
#  207 KB raw, 53 KB gzipped, byte-identical in eleven of them. 583 KB of the
#  same library, downloaded again on every screen anybody opened. It is a
#  shared file now. Vendoring it at all is deliberate and stays: no third
#  party gets to see who signs in to the masjid's portal.
check(os.path.exists("admin/supabase.js"),
      "admin/supabase.js is missing — every staff screen loads it, so the "
      "sign-in on all of them would throw")

for d in STAFF:
    page = os.path.join(d, "index.html")
    if not os.path.exists(page):
        continue
    body = open(page, encoding="utf-8").read()
    inlined = re.search(r"<script[^>]*>\s*/\* @supabase/supabase-js", body)
    check(inlined is None,
          "%s/ has gone back to vendoring the Supabase library inside the "
          "page. That is 53 KB gzipped of a library the other eleven screens "
          "already have." % d)
    #  apply/ is the exception and always was: it is published as a preview
    #  that cannot send, so it has no database client at all.
    if d != "apply":
        check("admin/supabase.js" in body,
              "%s/ does not load admin/supabase.js, so createClient is "
              "undefined and its sign-in throws" % d)
        i_lib = body.find("admin/supabase.js")
        i_app = body.find('src="app.js"')
        check(i_lib != -1 and i_app != -1 and i_lib < i_app,
              "%s/ loads app.js before the Supabase library, so app.js runs "
              "against an undefined client" % d)

#  And the shared sheet must point at files that exist. A missing font file
#  looks completely fine in a browser — it just quietly renders in Times.
sheet = open("admin/fonts.css", encoding="utf-8").read()
for url in sorted(set(re.findall(r"url\(\.\./(fonts/[^)]+)\)", sheet))):
    check(os.path.exists(url),
          "admin/fonts.css asks for %s and it does not exist, so every staff "
          "screen silently falls back" % url)

#  7. The 404.
p404 = open("404.html", "rb").read()
kb404 = len(gzip.compress(p404, 9)) / 1024
check(kb404 <= PAGE_404_BUDGET_KB,
      "404.html is %.0f KB gzipped, over the %d KB budget — it exists to say "
      "one sentence. It used to inline its own copy of the fonts."
      % (kb404, PAGE_404_BUDGET_KB))

print("\nindex.html %.0f KB gzipped (budget %d) · 404.html %.1f KB (budget %d) · "
      "%d @font-face · %d preloaded"
      % (doc_kb, DOC_BUDGET_KB, kb404, PAGE_404_BUDGET_KB, len(faces), len(preloads)))
print("ALL PASS" if not fails
      else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails))
sys.exit(1 if fails else 0)
