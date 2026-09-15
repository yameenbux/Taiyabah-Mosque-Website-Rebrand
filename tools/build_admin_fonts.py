"""Generate admin/fonts.css — the one @font-face sheet the staff screens share.

WHY THIS EXISTS. The twelve pages under venue/, courses/, giftaid/ and the
rest are standalone: they are not built from a template, so anything common to
them has to be either duplicated or shared through a file. The fonts were
duplicated — 162 KB of base64 in each page, 2 MB across the folder, the same
four faces every time, all of it blocking the first paint. A committee member
moving between three screens downloaded them three times.

WHY IT IS GENERATED RATHER THAN HAND-WRITTEN. The unicode-ranges are long and
must match the ranges the font files were actually subset to. Retyping them is
how a page ends up silently missing the glyphs for `nikāḥ` or `Jumuʿah`, and
nobody notices because the browser quietly falls back. They are copied
verbatim from build-inputs/font_faces.txt — the same source build.py reads for
the public site — so the staff screens and the website cannot drift apart.

Run:  python3 tools/build_admin_fonts.py
"""
import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)

#  Which extracted file each (family, subset) belongs to. build.py names these;
#  if it ever renames one, this raises rather than writing a sheet full of
#  404s, because a missing font file looks completely fine until you look.
FILE_FOR = {
    ("Fraunces", "latin"):           "fraunces-latin.woff2",
    ("Fraunces", "latin-ext"):       "fraunces-latin-ext.woff2",
    ("Hanken Grotesk", "latin"):     "hanken-grotesk-latin.woff2",
    ("Hanken Grotesk", "latin-ext"): "hanken-grotesk-latin-ext.woff2",
    ("Amiri", "latin"):              "amiri.woff2",
}

HEADER = """/* ===========================================================================
   The fonts, for the staff screens.  GENERATED — do not edit.
   Source: build-inputs/font_faces.txt, via tools/build_admin_fonts.py

   Each staff page used to carry its own base64 copy of these faces: 162 KB a
   page, 2 MB across the folder, the same four files every time, all of it on
   the one resource that blocks the first paint. Shared, the browser fetches
   each face once for the whole session.
   =========================================================================== */"""

FALLBACKS = """
/*  Metric-matched fallbacks. src:local() only, so these download nothing.
    They force the real font's vertical metrics onto whatever the device
    already has, so a line box is the same height before and after the swap
    and the page does not jump under the reader. Measured on the public site:
    without them CLS 0.0235, with them 0.0013. */
@font-face{font-family:'Fraunces fallback';src:local('Georgia'),local('Times New Roman'),local('DejaVu Serif'),local('Liberation Serif'),local('Nimbus Roman'),local('Times');ascent-override:97.8%;descent-override:25.5%;line-gap-override:0%;}
@font-face{font-family:'Hanken fallback';src:local('Arial'),local('Helvetica Neue'),local('Helvetica'),local('Roboto'),local('DejaVu Sans'),local('Liberation Sans');ascent-override:100%;descent-override:30.3%;line-gap-override:0%;}
@font-face{font-family:'Amiri fallback';src:local('Scheherazade New'),local('Noto Naskh Arabic'),local('Geeza Pro'),local('Times New Roman'),local('DejaVu Serif'),local('FreeSerif');ascent-override:112.4%;descent-override:63.4%;line-gap-override:0%;}
"""


def main():
    src = open("build-inputs/font_faces.txt", encoding="utf-8").read()
    out, listed = [], []

    for face in re.split(r"(?=@font-face)", src):
        if "@font-face" not in face:
            continue
        fam = re.search(r"font-family:\s*['\"]?([^;'\"]+)", face).group(1).strip()
        wt = re.search(r"font-weight:\s*([^;}]+)", face)
        rng = re.search(r"unicode-range:\s*([^;}]+)", face)
        subset = "latin-ext" if (rng and "0100" in rng.group(1)) else "latin"

        key = (fam, subset)
        if key not in FILE_FOR:
            raise SystemExit(
                "no file mapped for %r. build.py's naming has changed, and "
                "writing this sheet anyway would point the staff screens at "
                "fonts that do not exist." % (key,))
        name = FILE_FOR[key]
        if not os.path.exists(os.path.join("fonts", name)):
            raise SystemExit(
                "fonts/%s does not exist — run python3 build.py first, which "
                "is what extracts it." % name)

        listed.append((fam, subset, name))
        out.append(
            "@font-face{font-family:'%s';font-style:normal;font-weight:%s;"
            "font-display:swap;src:url(../fonts/%s) format('woff2');%s}"
            % (fam, wt.group(1).strip() if wt else "400", name,
               ("unicode-range:%s;" % rng.group(1).strip()) if rng else ""))

    if len(out) < 4:
        raise SystemExit("only %d faces found; expected at least 4" % len(out))

    os.makedirs("admin", exist_ok=True)
    with open("admin/fonts.css", "w", encoding="utf-8") as f:
        f.write(HEADER + "\n" + "\n".join(out) + "\n" + FALLBACKS)

    print("wrote admin/fonts.css — %d faces, %d bytes"
          % (len(out), os.path.getsize("admin/fonts.css")))
    for fam, subset, name in listed:
        print("   %-16s %-10s -> fonts/%s" % (fam, subset, name))


if __name__ == "__main__":
    main()
