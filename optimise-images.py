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
def input_map():
    src = open("build.py").read()
    return dict(re.findall(r"'\{\{([A-Z_0-9]+)\}\}':\s*load\('build-inputs/([^']+)'\)", src))


def source_path(placeholder, mapping):
    if placeholder not in mapping:
        sys.exit(f"build.py does not define {{{{{placeholder}}}}}")
    return os.path.join("build-inputs", mapping[placeholder])


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
        src = source_path(ph, mapping)
        if not os.path.exists(src):
            sys.exit(f"missing input for {ph}: {src}")
        data = decode(src)
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
        note = ""
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
        was = len(open(src).read())
        path = os.path.join(OUT_DIR, slug + ".jpg")
        with open(path, "wb") as f:
            f.write(out)

        before += was
        after += len(out)
        manifest[ph] = {"file": f"{OUT_DIR}/{slug}.jpg",
                        "w": im.size[0], "h": im.size[1], "bytes": len(out)}
        print(f"{slug + '.jpg':26} {was//1024:>7}K {len(out)//1024:>7}K "
              f"{100 - len(out)*100//max(was,1):>6}%  "
              f"{im.size[0]}x{im.size[1]} {note}")

    with open("build-inputs/image-manifest.json", "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)

    print(f"\n{len(manifest)} files written to {OUT_DIR}/")
    print(f"in the document before: {before/1024/1024:.2f} MB of base64")
    print(f"on disk now:            {after/1024/1024:.2f} MB of JPEG "
          f"({100 - after*100//before}% smaller, and none of it loads up front)")


if __name__ == "__main__":
    main()
