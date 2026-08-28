#!/usr/bin/env python3
"""
Regenerate the Stripe branding files from the masjid's master logos.

Run from the repository root:

    python3 brand/make-stripe-assets.py

Sources (do not delete these — everything here is derived from them):
    assets/logo-dark.png    plum wordmark on transparent
    assets/logo-cream.png   cream wordmark on transparent

Outputs:
    brand/taiyabah-stripe-logo-on-dark.png   1000x198  cream ink  -> "Logo" slot
    brand/taiyabah-stripe-logo-on-light.png  1000x198  plum ink   -> "Logo" slot
    brand/taiyabah-stripe-icon.png            512x512             -> "Icon" slot

Named for the BACKGROUND each is for, not for its own colour — that is the
mistake that gets made. The masjid's checkout background is plum #3C0B2A, so
the -on-dark (cream) file is the one to upload.

Stripe's limits: PNG or JPG, under 512 KB, at least 128x128. Both outputs are
checked against those before the script exits.
"""
import os
import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ASSETS = os.path.join(ROOT, "assets")

PLUM  = (60, 11, 42)    # #3C0B2A  --brand-900
PLUM2 = (34, 7, 26)     # #22071A  darker end of the site's gradient
GOLD  = (220, 187, 99)  # #DCBB63  --gold-bright

# The master logo stacks three elements. These row ranges split them apart;
# they were found by looking for blank rows in the alpha channel.
ARABIC_BAND = (0, 261)     # the calligraphy
WORD_BAND   = (300, None)  # TAIYABAH over MASJID


def trim(im):
    """Crop to the ink. Whitespace in the source would otherwise shrink the
    artwork inside whatever box Stripe scales it into."""
    a = np.array(im.convert("RGBA"))[:, :, 3]
    rows = np.where(a.max(axis=1) > 8)[0]
    cols = np.where(a.max(axis=0) > 8)[0]
    return im.crop((cols.min(), rows.min(), cols.max() + 1, rows.max() + 1))


def band(im, span):
    top, bottom = span
    return trim(im.crop((0, top, im.width, bottom if bottom else im.height)))


def build_logo(source):
    """Horizontal lockup on transparent.

    Deliberately NOT the stacked master. Stripe's checkout header is a short,
    wide slot and scales the logo to fit its height — a tall logo ends up with
    an unreadable wordmark. Roughly 5:1 fills the space it is actually given.

    `source` decides the ink colour. Transparent artwork is invisible when its
    ink matches the background behind it, which is exactly what happened when a
    plum logo met a plum checkout: pick by background, not by preference.
    """
    src = Image.open(os.path.join(ASSETS, source)).convert("RGBA")
    arabic = band(src, ARABIC_BAND)
    word = band(src, WORD_BAND)

    H = 300
    a_h = round(H * 0.94)
    a = arabic.resize((round(arabic.width * a_h / arabic.height), a_h), Image.LANCZOS)
    w_h = round(H * 0.76)
    w = word.resize((round(word.width * w_h / word.height), w_h), Image.LANCZOS)
    gap = round(H * 0.22)

    logo = Image.new("RGBA", (a.width + gap + w.width, H), (0, 0, 0, 0))
    logo.alpha_composite(a, (0, (H - a.height) // 2))
    logo.alpha_composite(w, (a.width + gap, (H - w.height) // 2))
    logo = trim(logo)

    target = 1000
    return logo.resize((target, round(logo.height * target / logo.width)), Image.LANCZOS)


def build_icon(size=512):
    """Square tile: the calligraphy ONLY, in gold on the plum gradient.

    The full lockup turns to mush below about 96px, and the icon is what
    becomes the favicon and appears on every receipt and email. The
    calligraphy alone still reads at 32px.
    """
    cream = Image.open(os.path.join(ASSETS, "logo-cream.png")).convert("RGBA")
    arabic = band(cream, ARABIC_BAND)

    arr = np.array(arabic)                    # recolour cream ink to gold,
    arr[:, :, 0], arr[:, :, 1], arr[:, :, 2] = GOLD   # keeping the anti-aliasing
    arabic = Image.fromarray(arr)

    icon = Image.new("RGBA", (size, size))
    d = ImageDraw.Draw(icon)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)],
               fill=tuple(round(PLUM[i] + (PLUM2[i] - PLUM[i]) * t) for i in range(3)) + (255,))

    mw = round(size * 0.72)                   # ~72% wide: readable small, not cramped
    mark = arabic.resize((mw, round(arabic.height * mw / arabic.width)), Image.LANCZOS)
    icon.alpha_composite(mark, ((size - mark.width) // 2, (size - mark.height) // 2))
    return icon.convert("RGB")


def check(path, must_be_square):
    im = Image.open(path)
    kb = os.path.getsize(path) / 1024
    problems = []
    if kb >= 512:
        problems.append("over Stripe's 512 KB limit (%.0f KB)" % kb)
    if min(im.size) < 128:
        problems.append("smaller than Stripe's 128x128 minimum %s" % (im.size,))
    if must_be_square and im.width != im.height:
        problems.append("icon must be square, got %s" % (im.size,))
    if not must_be_square and im.width == im.height:
        problems.append("logo should be non-square, got %s" % (im.size,))
    status = "OK" if not problems else "PROBLEM"
    print("  %-7s %-28s %-11s %6.0f KB" % (status, os.path.basename(path), "%dx%d" % im.size, kb))
    for p in problems:
        print("          - " + p)
    return not problems


if __name__ == "__main__":
    outputs = []

    for source, name in (("logo-cream.png", "taiyabah-stripe-logo-on-dark.png"),
                         ("logo-dark.png",  "taiyabah-stripe-logo-on-light.png")):
        path = os.path.join(HERE, name)
        build_logo(source).save(path, optimize=True)
        outputs.append((path, False))

    icon_path = os.path.join(HERE, "taiyabah-stripe-icon.png")
    build_icon().save(icon_path, optimize=True)
    outputs.append((icon_path, True))

    print("Checked against Stripe's requirements:")
    ok = all(check(p, must_be_square=sq) for p, sq in outputs)
    raise SystemExit(0 if ok else 1)
