import base64
import json
import os
import re

with open('index_template.html', 'r') as f:
    tpl = f.read()

# Build inputs live in build-inputs/ and are committed. They used to be read
# from /tmp, which meant a fresh clone of this repo could not rebuild the site
# at all — the "never edit index.html by hand, edit the template and rebuild"
# rule only worked on the one machine that still had those temp files.
def load(path):
    with open(path) as f:
        return f.read().strip()


# ---------------------------------------------------------------------------
# Photographs are FILES, not data URIs.
#
# They used to be base64-inlined, which made index.html 10.3 MB — every visitor
# downloading every photograph on every page before anything rendered, on a
# site whose audience is overwhelmingly on phones. optimise-images.py writes
# them to img/ instead, and this substitutes the path.
#
# The favicon, the header logo, the QR codes and the two girih tiles stay
# inline on purpose: they are small, they are needed for the first paint, and a
# request each would cost more than it saves.
#
# THE FONTS NO LONGER DO. See fonts() below.
#
# img/ MUST therefore be uploaded with index.html. It is in DEPLOY.md.
# ---------------------------------------------------------------------------
def fonts():
    """Every face is a FILE. None of them is inlined any more.

    This used to inline Fraunces and Hanken Grotesk, on the reasoning that they
    set every word on the site, so a separate request before the first paint
    would show a flash of fallback text on every page. That was a fair argument
    when it was written. Measured on 15 September 2026, it had inverted, for
    three reasons.

    1. THE COST WAS 124 KB ON THE CRITICAL PATH. The document gzipped to 291 KB
       and 123 KB of that was base64 font. woff2 is already compressed, so
       base64-ing it inflates it by a third and gzip cannot win that back —
       the fonts compressed from 162 KB to 123 KB, while the same bytes as
       .woff2 files are 122 KB. Stripping them takes the render-blocking
       document from 291 KB to 167 KB, a 43% cut, for no increase in total
       bytes on a first visit.

    2. INLINING DEFEATED unicode-range ENTIRELY. Each family ships as two
       subsets — latin and latin-ext — with a unicode-range so a browser
       fetches only what the page actually needs. That mechanism only works on
       a FILE. Inlined, both subsets are already in the HTML, so every visitor
       to an English and Arabic website was downloading 52 KB of Central and
       Eastern European glyphs that nothing on the site can ever use.

    3. THE FLASH IT AVOIDED WAS PAID FOR WITH A BLANK SCREEN. Inlining does not
       make the font arrive sooner in absolute terms; it makes the FIRST PAINT
       arrive later, because nothing renders until the whole document is in.
       font-display:swap was already set on every face, and preload starts the
       font fetch in the same round trip as the HTML, so on any normal
       connection the font still wins the race. On a bad one the visitor now
       reads the page in Georgia for a moment instead of watching a white
       screen, which is the better of the two.

    Amiri was already a file, for the same reason arrived at earlier: it sets
    four Arabic words on four service pages, weighs 74 KB, and is fetched only
    when one of those pages is actually opened.

    Returns (css, preload_tags). Only the two latin subsets are preloaded —
    preloading latin-ext would reintroduce exactly the waste point 2 removes,
    and preloading Amiri would undo the decision above.
    """
    css = load('build-inputs/font_faces.txt')
    os.makedirs('fonts', exist_ok=True)

    chunks = re.split(r'(?=@font-face)', css)

    #  Two passes. The first works out what is there, because how a file
    #  should be NAMED depends on whether its family has more than one subset:
    #  Amiri has a single face and stays plain `amiri.woff2`, which is also the
    #  name DEPLOY.md and the previous build already used. Naming it
    #  `amiri-latin.woff2` — which a one-pass version did — would be both wrong
    #  (Amiri is Arabic) and a gratuitous rename of a file already in git.
    parsed = []
    for face in chunks:
        if '@font-face' not in face:
            parsed.append((face, None))
            continue
        fam = re.search(r"font-family:\s*['\"]?([^;'\"]+)", face)
        b64 = re.search(r'base64,([A-Za-z0-9+/=]+)', face)
        if not fam or not b64:
            parsed.append((face, None))
            continue
        rng = re.search(r'unicode-range:\s*([^;}]+)', face)
        parsed.append((face, {
            'family': fam.group(1).strip(),
            'b64': b64.group(1),
            # latin-ext is the one carrying U+0100-024F. Naming the subset
            # rather than numbering it means a future reader can see at a
            # glance which file is the one nobody in Bolton ever downloads.
            'subset': 'latin-ext' if (rng and '0100' in rng.group(1)) else 'latin',
        }))

    counts = {}
    for _, info in parsed:
        if info:
            counts[info['family']] = counts.get(info['family'], 0) + 1

    out, preload, seen = [], [], {}
    for face, info in parsed:
        if not info:
            out.append(face)
            continue

        slug = re.sub(r'[^a-z0-9]+', '-', info['family'].lower()).strip('-')
        name = (f"{slug}-{info['subset']}.woff2" if counts[info['family']] > 1
                else f'{slug}.woff2')

        # Fail loudly rather than silently overwrite one face with another.
        if name in seen:
            raise SystemExit(f'two @font-face blocks both want fonts/{name}')
        seen[name] = True

        with open(f'fonts/{name}', 'wb') as f:
            f.write(base64.b64decode(info['b64']))

        out.append(re.sub(r'url\(data:font/woff2;base64,[A-Za-z0-9+/=]+\)',
                          f'url(fonts/{name})', face))

        #  Preload ONLY the faces that set the words on the first screen. Amiri
        #  is excluded deliberately — preloading it would undo the earlier
        #  decision that it costs nothing until an Arabic page is opened — and
        #  so is latin-ext, which would reintroduce the exact waste this
        #  change removes.
        if info['subset'] == 'latin' and info['family'] != 'Amiri' \
                and counts[info['family']] > 1:
            preload.append(
                f'<link rel="preload" href="fonts/{name}" as="font" '
                f'type="font/woff2" crossorigin>')

    if not preload:
        raise SystemExit('no latin face found to preload — check font_faces.txt')

    return ''.join(out), '\n'.join(preload)


def timetable_year():
    """The year build-inputs/fullYYYY.json covers, taken from its filename.

    The page needs to know which year its built-in rows are for: it decides
    whether today is inside the timetable, whether to highlight a row as
    today, and whether the database has a newer year worth swapping in.

    Derived, not declared. A constant written here would be one more thing to
    remember to change, and the failure it causes is silent and lasts twelve
    months — the page would believe it held 2027, match today's date against
    2026's rows, and display the wrong prayer times while looking completely
    normal.
    """
    names = [f for f in os.listdir('build-inputs') if re.fullmatch(r'full\d{4}\.json', f)]
    if len(names) != 1:
        raise SystemExit(
            "expected exactly one build-inputs/fullYYYY.json, found %d: %s. "
            "Which year is the site's built-in timetable?" % (len(names), names))
    return re.search(r'(\d{4})', names[0]).group(1)


def timetable_js():
    """A year of prayer times, ONE DAY PER LINE.

    This used to be substituted straight in as the raw file, which is one JSON
    array on one line: 365 rows and **forty-two thousand characters without a
    single newline**. It was correct, it was the smallest thing to write, and
    it was the largest single line in the repository by a factor of four.

    That caused a real problem the day somebody tried to put the site on
    GitHub through a browser. A 42,000-character line is not a size problem —
    the whole file is only 624 KB — it is a RENDERING problem: a diff viewer,
    a syntax highlighter or an editor asked to lay out one line that long will
    sit there chewing, and on a phone or a modest laptop the tab stops
    responding. "Git crashes on the HTML files" is what that looks like from
    the outside, and nothing about it says "one long line".

    So: one row per line. The data is IDENTICAL — it is parsed and re-emitted,
    and the round trip is asserted below, because a build step that silently
    reshapes a year of prayer times would be a far worse bug than the one it
    fixes. The cost is 364 newlines and some indentation, about 2 KB, which
    gzip gives back almost entirely. The gain is a file a human being can open.

    json.dumps with separators, NOT str(), because Python would write True and
    None and single quotes, none of which are JavaScript.
    """
    raw = load('build-inputs/full2026.json')
    rows = json.loads(raw)

    if not isinstance(rows, list) or not rows:
        raise SystemExit('build-inputs/full2026.json is not a list of rows')

    out = ',\n'.join(
        '    ' + json.dumps(r, ensure_ascii=False, separators=(',', ':'))
        for r in rows
    )
    js = '[\n' + out + '\n  ]'

    #  THE ROUND TRIP, CHECKED. Not ceremony: this function's whole promise is
    #  that it changes the whitespace and nothing else, and the thing it would
    #  quietly break is the masjid's prayer times for a year.
    if json.loads(js) != rows:
        raise SystemExit(
            'the timetable changed while being reformatted — refusing to build')

    return js


def image(slug):
    path = f"img/{slug}.jpg"
    if not os.path.exists(path):
        raise SystemExit(
            f"{path} is missing. Run: python3 optimise-images.py")
    return path

_font_css, _font_preload = fonts()

#  The 404 needs only the two families that set its handful of words, and only
#  their latin subsets — it has no Arabic on it and never will.
_font_css_404 = "".join(
    f"@font-face{{font-family:'{fam}';font-style:normal;font-weight:100 900;"
    f"font-display:swap;src:url(fonts/{f}) format('woff2');}}"
    for fam, f in (('Fraunces', 'fraunces-latin.woff2'),
                   ('Hanken Grotesk', 'hanken-grotesk-latin.woff2'))
)

subs = {
    '{{FONT_FACES}}': _font_css,
    '{{FONT_PRELOAD}}': _font_preload,
    '{{PRIVACY_DATE}}': load('build-inputs/privacy_date.txt'),
    '{{ICON_B64}}': load('build-inputs/icon_b64.txt'),
    '{{CONTACT_BUILDING_B64}}': image('contact-building'),
    '{{LOGO_B64}}': load('build-inputs/logo_b64.txt'),
    '{{QR_B64}}': load('build-inputs/qr_b64.txt'),
    '{{WA_QR_B64}}': load('build-inputs/wa_qr_b64.txt'),
    '{{BANNER_PHOTO_B64}}': image('banner-photo'),
    '{{BANNER_ACCENT_B64}}': image('banner-accent'),
    '{{GIRIH_TILE_B64}}': load('build-inputs/girih_tile_b64.txt'),
    '{{GIRIH_SOLID_B64}}': load('build-inputs/girih_solid_b64.txt'),
    '{{FULL_2026_JSON}}': timetable_js(),
    #  Which year that file covers. Read from its NAME rather than written
    #  here as a literal, so the two cannot disagree — a page that believes it
    #  holds 2027 while carrying 2026's rows would show the wrong prayer times
    #  for a whole year and look entirely normal doing it.
    '{{TIMETABLE_YEAR}}': timetable_year(),
    '{{APP_SHOT_TIMES_B64}}': image('app-shot-times'),
    '{{APP_SHOT_LIVE_B64}}': image('app-shot-live'),
    '{{APP_SHOT_DONATE_B64}}': image('app-shot-donate'),
    '{{HALLHIRE_BAND_B64}}': image('hallhire-band'),
    '{{SHOP_HONEY_B64}}': image('shop-honey'),
    '{{SHOP_DATES_B64}}': image('shop-dates'),
    '{{SHOP_HERBAL_B64}}': image('shop-herbal'),
    '{{SHOP_PRAYER_B64}}': image('shop-prayer'),
    '{{SHOP_BOOKS_B64}}': image('shop-books'),
    '{{SHOP_HAJJ_B64}}': image('shop-hajj'),
    '{{HOME_BUILDING_B64}}': image('home-building'),
    '{{SHOP_OILS_B64}}': image('shop-oils'),
    '{{SHOP_PERFUME_B64}}': image('shop-perfume'),
    '{{MADRASAH_HERO_B64}}': image('madrasah-hero'),
    '{{PRAYER_HERO_B64}}': image('prayer-hero'),
    '{{SHOP_HERO_B64}}': image('shop-hero'),
    '{{ARTICLES_HERO_B64}}': image('articles-hero'),
    '{{SHOP_ZAMZAM_B64}}': image('shop-zamzam'),
    '{{CONTACT_HERO_B64}}': image('contact-hero'),
    '{{SERVICES_HERO_B64}}': image('services-hero'),
    '{{MEDIA_HERO_B64}}': image('media-hero'),
    '{{ARTICLE_ISLAM_HERO_B64}}': image('article-islam-hero'),
    '{{ARTICLE_PILLARS_HERO_B64}}': image('article-pillars-hero'),
    '{{ARTICLE_PILLARS_THUMB_B64}}': image('article-pillars-thumb'),
    '{{ARTICLE_RAMADAN_HERO_B64}}': image('article-ramadan-hero'),
    '{{ARTICLE_RAMADAN_THUMB_B64}}': image('article-ramadan-thumb'),
    '{{ARTICLE_HAJJ_HERO_B64}}': image('article-hajj-hero'),
    '{{ARTICLE_HAJJ_THUMB_B64}}': image('article-hajj-thumb'),
    '{{EDU_ARABIC_B64}}': image('edu-arabic'),
    '{{EDU_GHUSL_B64}}': image('edu-ghusl'),
}

out = tpl
for k, v in subs.items():
    out = out.replace(k, v)

remaining = re.findall(r'\{\{[A-Z_]+\}\}', out)
if remaining:
    raise SystemExit(f"Unsubstituted placeholders remain: {remaining}")

with open('index.html', 'w') as f:
    f.write(out)

print(f"wrote index.html: {len(out)} bytes ({len(out)/1024:.0f} KB)")

# ---------------------------------------------------------------------------
# index.html stopped being self-contained when the photographs moved out, which
# is a large win and exactly one new way to break the site: upload the document
# without img/ and every photograph on every page becomes a broken icon,
# with nothing to warn you. image() already refuses to substitute a path that
# does not exist, so what is left to check is the other direction — files being
# uploaded to the masjid's server that no page will ever ask for.
# ---------------------------------------------------------------------------
referenced = set(re.findall(r'img/[A-Za-z0-9._-]+', out))
on_disk = {f"img/{f}" for f in os.listdir("img")
           if not f.startswith(".")}
total = sum(os.path.getsize(p) for p in referenced)
print(f"  images: {len(referenced)} files, {total/1024/1024:.2f} MB in img/ "
      f"— none of it loads until the page using it is opened")

#  THE STAFF SCREENS ALSO USE img/, and this check could not see them.
#
#  It scanned the built index.html and nothing else, so it announced
#  "masjid-logo.png — safe to delete" about the logo in the corner of every
#  staff screen. A note that confidently recommends deleting a file that is
#  needed is worse than no note: somebody will believe it, the logo will
#  vanish from thirteen screens at once, and the build will not say a word
#  because index.html never wanted it in the first place. The staff folders
#  are standalone rather than templated, which is exactly why they were
#  missed — nothing about them passes through here.
for folder in sorted(d for d in os.listdir(".")
                     if os.path.isdir(d) and not d.startswith((".", "_"))):
    for name in ("index.html", "app.js", "shell.js", "shell.css"):
        f = os.path.join(folder, name)
        if os.path.exists(f):
            with open(f, encoding="utf-8", errors="replace") as fh:
                referenced |= {m.lstrip("./") for m in
                               re.findall(r'(?:\.\./)?img/[A-Za-z0-9._-]+', fh.read())}

orphans = sorted(on_disk - referenced)
if orphans:
    print(f"  NOTE: {len(orphans)} file(s) in img/ that NO page asks for — "
          f"check the staff screens before deleting: "
          + ", ".join(os.path.basename(o) for o in orphans))

# The 404 page is built too, so it cannot drift back to Google Fonts.
with open('404_template.html') as f:
    tpl404 = f.read()
#  THE 404 SHARES THE SITE'S FONT FILES rather than inlining its own copy.
#
#  build-inputs/font_faces_404.txt carries the same two latin faces the main
#  site uses, base64'd again — 93 KB of a 96 KB page, for a page whose entire
#  job is to say "that page has moved" and offer a link home.
#
#  Referencing the files instead takes 404.html from 96 KB to about 4 KB, and
#  because anybody who lands here has almost certainly just come from the site,
#  the fonts are already in their cache and cost nothing at all. If they are
#  not, font-display:swap shows the message immediately in a fallback, which
#  for this page is entirely fine.
out404 = tpl404.replace('{{FONT_FACES_404}}', _font_css_404)
remaining404 = re.findall(r'\{\{[A-Z_0-9]+\}\}', out404)
if remaining404:
    raise SystemExit(f"Unsubstituted placeholders in 404: {remaining404}")
with open('404.html', 'w') as f:
    f.write(out404)
print(f"wrote 404.html: {len(out404)} bytes ({len(out404)/1024:.0f} KB)")
