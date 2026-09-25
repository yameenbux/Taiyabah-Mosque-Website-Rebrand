#!/usr/bin/env python3
"""
Turn the base64 image inputs into real files under img/.

WHY THIS EXISTS
---------------
Every photograph used to be inlined into index.html as a base64 data URI. That
made the site a single self-contained file, which was a reasonable call when it
was 2 MB. By September 2026 it was 10.3 MB, and a data URI has three costs that
only get worse as you add pages:

  * base64 is ~33% bigger than the bytes it encodes;
  * every visitor downloads EVERY image before the page renders at all, even
    the ones on pages they never open;
  * nothing is cacheable on its own, so one changed photo re-downloads all of
    it, and every commit stores another full copy of the document.

Real files fix all three. Each is fetched only when its page is shown (the
markup uses loading="lazy", and the pages are display:none until navigated to),
cached separately by the browser, and served without the base64 overhead.

FORMAT
------
Progressive JPEG, deliberately, not WebP. WebP would be roughly 25% smaller
again, but it is a compatibility bet — Safari only gained it in 2020 — and the
win here comes from not shipping the images at all until they are needed, not
from the codec. If someone later decides the extra 25% is worth the bet, it is
a one-line change to FORMAT below. Broken photographs on an older phone are a
worse failure than a slightly larger file.

SIZES
-----
Capped by role, because a masthead background sitting behind a 50%-opacity
scrim does not need the same resolution as a phone screenshot. Nothing is
cropped and no aspect ratio changes — the only thing that happens is a resize
and a re-encode, so every existing object-fit and object-position rule keeps
behaving exactly as it did.

RUN IT when an image in build-inputs/ changes:

    python3 optimise-images.py && python3 verify_structure.py && python3 build.py
"""
import base64, io, json, os, re, sys
from PIL import Image

OUT_DIR = "img"
FORMAT  = "JPEG"

# (longest edge, quality) by role. Anything not listed falls back to DEFAULT.
ROLES = {
    "hero":   (1400, 68),   # full-bleed mastheads, behind a scrim
    "card":   (800,  74),   # shop tiles, article thumbnails, course tiles
    "shot":   (700,  78),   # phone screenshots — flat colour, needs to stay crisp
    "photo":  (1200, 72),   # everything else
}
DEFAULT = "photo"

# A SECOND, NARROW COPY OF THE FULL-BLEED PHOTOGRAPHS.
#
# Measured on 25 September 2026, on the built page in a real browser at two
# widths. On a 1366px desktop the mastheads are already right: natural 1400
# shown at 1366, natural 1200 shown at 1366 - between 0.8x and 1.0x, which is
# the sizing work in this file doing its job.
#
# On a 390px phone the SAME FILES are 3.1x to 3.6x too wide. Because pixels go
# up with the square, a 1400px file shown at 390 carries about thirteen times
# the pixels the screen can use. Three of them load on the home view and come
# to 364 KB, which after gzip is essentially the entire remaining weight of the
# site - gzip does nothing for a JPEG.
#
# So the phone gets its own copy and the desktop keeps the one it already had.
# 760 rather than 390: a phone at 390 CSS pixels is usually 2x or 3x physical,
# and a masthead that goes soft when somebody pinches it is a worse outcome
# than the bytes are worth.
#
# ONLY hero AND photo. The card and shot roles were measured at 1.4x to 1.6x,
# which is roughly right for a 2x screen already, and a second file each would
# cost more in requests than it saves in bytes.
#  800, NOT 760, AND THE TWENTY PIXELS ARE THE WHOLE POINT.
#
#  760 was the first guess and it was never chosen. A 390px phone at 2x device
#  pixel ratio - which is most of them - needs 780 physical pixels for a
#  full-bleed image, and 780 is more than 760, so the browser correctly
#  ignored the phone copy and downloaded the master anyway. The files were
#  written, the srcset was correct, the markup was right, and not one visitor
#  would ever have received one.
#
#  Caught by asking a real browser which file it PICKED at 390px@2x rather
#  than by checking that the attribute was present. "The srcset is there" and
#  "the small image is used" are different claims and only the second one
#  matters.
NARROW_CAP     = 800
NARROW_QUALITY = 70
NARROW_ROLES   = ("hero", "photo")
NARROW_SUFFIX  = "-800"

# Which placeholders become files, and how each is treated.
# Everything NOT listed here stays inline: the fonts, the favicon, the header
# logo, the QR codes and the two tiny girih tiles. They are small, they are
# needed for the first paint, and a request each would cost more than it saves.
EXTERNAL = {
    "ARTICLES_HERO_B64":        ("articles-hero",        "hero"),
    "ARTICLE_HAJJ_HERO_B64":    ("article-hajj-hero",    "hero"),
    "ARTICLE_ISLAM_HERO_B64":   ("article-islam-hero",   "hero"),
    "ARTICLE_PILLARS_HERO_B64": ("article-pillars-hero", "hero"),
    "ARTICLE_RAMADAN_HERO_B64": ("article-ramadan-hero", "hero"),
    "CONTACT_HERO_B64":         ("contact-hero",         "hero"),
    "MADRASAH_HERO_B64":        ("madrasah-hero",        "hero"),
    "MEDIA_HERO_B64":           ("media-hero",           "hero"),
    "PRAYER_HERO_B64":          ("prayer-hero",          "hero"),
    "SERVICES_HERO_B64":        ("services-hero",        "hero"),
    "SHOP_HERO_B64":            ("shop-hero",            "hero"),
    "HALLHIRE_BAND_B64":        ("hallhire-band",        "hero"),
    "BANNER_PHOTO_B64":         ("banner-photo",         "hero"),
    "BANNER_ACCENT_B64":        ("banner-accent",        "hero"),

    "ARTICLE_HAJJ_THUMB_B64":    ("article-hajj-thumb",    "card"),
    "ARTICLE_PILLARS_THUMB_B64": ("article-pillars-thumb", "card"),
    "ARTICLE_RAMADAN_THUMB_B64": ("article-ramadan-thumb", "card"),
    "EDU_ARABIC_B64":            ("edu-arabic",            "card"),
    "EDU_GHUSL_B64":             ("edu-ghusl",             "card"),
    "SHOP_BOOKS_B64":            ("shop-books",            "card"),
    "SHOP_DATES_B64":            ("shop-dates",            "card"),
    "SHOP_HAJJ_B64":             ("shop-hajj",             "card"),
    "SHOP_HERBAL_B64":           ("shop-herbal",           "card"),
    "SHOP_HONEY_B64":            ("shop-honey",            "card"),
    "SHOP_OILS_B64":             ("shop-oils",             "card"),
    "SHOP_PERFUME_B64":          ("shop-perfume",          "card"),
    "SHOP_PRAYER_B64":           ("shop-prayer",           "card"),
    "SHOP_ZAMZAM_B64":           ("shop-zamzam",           "card"),

    "APP_SHOT_TIMES_B64":  ("app-shot-times",  "shot"),
    "APP_SHOT_LIVE_B64":   ("app-shot-live",   "shot"),
    "APP_SHOT_DONATE_B64": ("app-shot-donate", "shot"),

    "HOME_BUILDING_B64":    ("home-building",    "photo"),
    "CONTACT_BUILDING_B64": ("contact-building", "photo"),
}

# Deliberately NOT here: WA_QR_B64. Re-encoding a QR code as JPEG made it eight
# times BIGGER (4 KB of PNG became 32 KB) because JPEG is built for photographs
# and falls apart on flat black and white — and worse, the ringing it adds
# around the squares is exactly the kind of noise that stops a phone camera
# reading the code. It stays inline as PNG, where it costs 4 KB and works.


# build.py is the single source of truth for which file feeds which
# placeholder — the names do not follow a rule (APP_SHOT_TIMES_B64 reads
# shot_times_sm_b64.txt). Parse it rather than guessing, so the two cannot
# drift apart.
#  THIS TOOL HAD BEEN DEAD SINCE THE IMAGES MOVED OUT, and nothing said so.
#
#  input_map() looks for  '{{X_B64}}': load('build-inputs/x.txt')  in build.py.
#  That is exactly what build.py said WHILE the photographs were still base64
#  inside the document. The moment they became files, those lines changed to
#  image('some-slug') - and the mapping this tool depends on stopped existing.
#  Every entry in EXTERNAL then failed the lookup, so the script exited on the
#  first one, alphabetically, before writing anything:
#
#      build.py does not define {{APP_SHOT_DONATE_B64}}
#
#  The header above still says "RUN IT when an image in build-inputs/ changes".
#  Running it would have done nothing at all. The same shape as the retention
#  policy nothing called and the reconciler that had never been run: a thing
#  that exists, is documented, and cannot work.
#
#  Resolution order now, most faithful source first, and it SAYS which it used:
#    1. an explicit load('build-inputs/...') in build.py, if one survives
#    2. build-inputs/<slug with underscores>_b64.txt, which most of them match
#    3. img/<slug>.jpg - the master already on disk
#
#  Step 3 is a second generation through a lossy encoder and is marked as such
#  in the output. It is accepted only because the alternative is a tool that
#  cannot run: a slightly softer phone-sized copy beats no phone-sized copy.
def input_map():
    src = open("build.py").read()
    return dict(re.findall(r"'\{\{([A-Z_0-9]+)\}\}':\s*load\('build-inputs/([^']+)'\)", src))


def source_path(placeholder, mapping, slug=None):
    if placeholder in mapping:
        return os.path.join("build-inputs", mapping[placeholder])
    if slug:
        guess = os.path.join("build-inputs", slug.replace("-", "_") + "_b64.txt")
        if os.path.exists(guess):
            return guess
        master = os.path.join(OUT_DIR, slug + ".jpg")
        if os.path.exists(master):
            return master
    sys.exit(
        f"no source for {{{{{placeholder}}}}}: build.py has no load() line for "
        f"it, build-inputs/{(slug or '').replace('-', '_')}_b64.txt does not "
        f"exist, and neither does {OUT_DIR}/{slug}.jpg. Nothing was written.")


def decode(path):
    raw = open(path).read().strip()
    if raw.startswith("data:"):
        raw = raw.split(",", 1)[1]
    return base64.b64decode(raw)


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    mapping = input_map()
    manifest, before, after = {}, 0, 0
    print(f"{'file':26} {'was':>8} {'now':>8} {'saved':>7}  pixels")

    for ph, (slug, role) in sorted(EXTERNAL.items()):
        src = source_path(ph, mapping, slug)
        if not os.path.exists(src):
            sys.exit(f"missing input for {ph}: {src}")
        from_master = src.endswith(".jpg")
        data = open(src, "rb").read() if from_master else decode(src)
        im = Image.open(io.BytesIO(data))
        im_format = im.format
        im = im.convert("RGB")
        cap, quality = ROLES.get(role, ROLES[DEFAULT])

        # Only ever shrink. Upscaling a source to hit a cap would add bytes and
        # no detail.
        resized = max(im.size) > cap
        if resized:
            im.thumbnail((cap, cap), Image.LANCZOS)

        buf = io.BytesIO()
        im.save(buf, FORMAT, quality=quality, optimize=True, progressive=True,
                subsampling=2)
        out = buf.getvalue()

        # Never ship a file that a re-encode made bigger. Two ways that
        # happens, and they want different answers:
        #
        #  * the source is already a JPEG compressed harder than our target,
        #    so re-encoding only adds generation loss AND bytes. Keep the
        #    original bytes untouched — it is already the better file.
        #  * the source is flat-colour artwork (a QR code, a logo). JPEG is
        #    the wrong format for it entirely and the ringing it introduces
        #    can stop a phone camera reading a code. That is a mistake in
        #    EXTERNAL, so stop and say so.
        note = "FROM MASTER (2nd generation)" if from_master else ""
        if len(out) >= len(data):
            if im_format == "JPEG" and not resized:
                out, note = data, "kept original"
            else:
                sys.exit(
                    f"{slug}: re-encoding {im_format} made it bigger "
                    f"({len(data)//1024}K -> {len(out)//1024}K). Flat-colour "
                    f"artwork does not belong in a JPEG — take it out of "
                    f"EXTERNAL and leave it inline.")

        # base64 in the document costs 4 bytes per 3, which is what we compare
        # against — that is what the page actually carried.
        was = os.path.getsize(src) if from_master else len(open(src).read())
        path = os.path.join(OUT_DIR, slug + ".jpg")

        #  WHEN THE SOURCE IS THE MASTER, THE MASTER IS NOT REWRITTEN.
        #
        #  Three phone screenshots have no file left in build-inputs/, so they
        #  resolve to img/<slug>.jpg - they are their own source. Re-encoding
        #  those and writing the result back is a second generation through a
        #  lossy encoder that cannot improve anything, and they are flat-colour
        #  UI shots, which is exactly what JPEG rings around. It shaved twenty
        #  bytes off two files and cost quality on both.
        #
        #  The re-encode still happens above, because the narrow copy below
        #  needs the decoded pixels. Only the write back is skipped.
        if from_master:
            out = data
            note = "left alone (it is its own source)"
        with open(path, "wb") as f:
            f.write(out)

        before += was
        after += len(out)
        manifest[ph] = {"file": f"{OUT_DIR}/{slug}.jpg",
                        "w": im.size[0], "h": im.size[1], "bytes": len(out)}
        print(f"{slug + '.jpg':26} {was//1024:>7}K {len(out)//1024:>7}K "
              f"{100 - len(out)*100//max(was,1):>6}%  "
              f"{im.size[0]}x{im.size[1]} {note}")

        #  The phone's copy. Built from the SOURCE, not from the file just
        #  written - downscaling an image that has already been through a
        #  lossy encoder keeps its artefacts and adds a second generation of
        #  its own.
        #
        #  Skipped when the master is already at or under the narrow cap:
        #  a second identical file would be a second request for nothing, and
        #  srcset() below leaves the attribute off when there is no variant.
        if role in NARROW_ROLES:
            master_w = im.size[0]
            if master_w > NARROW_CAP:
                sm = Image.open(io.BytesIO(data)).convert("RGB")
                sm.thumbnail((NARROW_CAP, NARROW_CAP), Image.LANCZOS)
                sbuf = io.BytesIO()
                sm.save(sbuf, FORMAT, quality=NARROW_QUALITY, optimize=True,
                        progressive=True, subsampling=2)
                sout = sbuf.getvalue()
                spath = os.path.join(OUT_DIR, slug + NARROW_SUFFIX + ".jpg")
                with open(spath, "wb") as f:
                    f.write(sout)
                after += len(sout)
                manifest[ph]["narrow"] = {
                    "file": f"{OUT_DIR}/{slug}{NARROW_SUFFIX}.jpg",
                    "w": sm.size[0], "h": sm.size[1], "bytes": len(sout)}
                print(f"{'  + ' + slug + NARROW_SUFFIX + '.jpg':26} "
                      f"{'':>7}  {len(sout)//1024:>7}K "
                      f"{100 - len(sout)*100//max(len(out),1):>6}%  "
                      f"{sm.size[0]}x{sm.size[1]} phone copy")

    with open("build-inputs/image-manifest.json", "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)

    print(f"\n{len(manifest)} files written to {OUT_DIR}/")
    print(f"in the document before: {before/1024/1024:.2f} MB of base64")
    print(f"on disk now:            {after/1024/1024:.2f} MB of JPEG "
          f"({100 - after*100//before}% smaller, and none of it loads up front)")


if __name__ == "__main__":
    main()
