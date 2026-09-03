import base64
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
# Anything not listed in that script stays inline on purpose: the fonts, the
# favicon, the header logo, the QR codes and the two girih tiles are all small
# and all needed for the first paint, so a request each would cost more than it
# saves.
#
# img/ MUST therefore be uploaded with index.html. It is in DEPLOY.md.
# ---------------------------------------------------------------------------
def fonts():
    """Inline the Latin faces; serve Amiri from a file.

    Fraunces and Hanken Grotesk set every word on the site, so they are inlined
    — a separate request before the first paint would show a flash of fallback
    text on every page.

    Amiri is different. It sets four Arabic words, on four service pages, and
    weighs 74 KB — which every visitor was downloading on every page whether
    they ever opened one of those pages or not. As a file it is fetched only
    when an element that uses it is actually rendered, and those pages are
    display:none until someone navigates to them. So it costs nothing until it
    is needed, and font-display:swap means the heading shows in a fallback
    serif for a moment rather than not at all.
    """
    css = load('build-inputs/font_faces.txt')
    faces = re.split(r'(?=@font-face)', css)
    kept, amiri = [], None
    for face in faces:
        if "font-family:'Amiri'" in face.replace(' ', ''):
            amiri = face
        else:
            kept.append(face)
    if amiri is None:
        raise SystemExit("no Amiri @font-face found in font_faces.txt")

    m = re.search(r'base64,([A-Za-z0-9+/=]+)', amiri)
    os.makedirs('fonts', exist_ok=True)
    with open('fonts/amiri.woff2', 'wb') as f:
        f.write(base64.b64decode(m.group(1)))

    kept.append(
        "@font-face{font-family:'Amiri';font-style:normal;font-weight:400;"
        "font-display:swap;src:url(fonts/amiri.woff2) format('woff2');}")
    return "".join(kept)


def image(slug):
    path = f"img/{slug}.jpg"
    if not os.path.exists(path):
        raise SystemExit(
            f"{path} is missing. Run: python3 optimise-images.py")
    return path

subs = {
    '{{FONT_FACES}}': fonts(),
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
    '{{FULL_2026_JSON}}': load('build-inputs/full2026.json'),
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
orphans = sorted(on_disk - referenced)
if orphans:
    print(f"  NOTE: {len(orphans)} unused file(s) in img/, safe to delete: "
          + ", ".join(os.path.basename(o) for o in orphans))

# The 404 page is built too, so it cannot drift back to Google Fonts.
with open('404_template.html') as f:
    tpl404 = f.read()
out404 = tpl404.replace('{{FONT_FACES_404}}', load('build-inputs/font_faces_404.txt'))
remaining404 = re.findall(r'\{\{[A-Z_0-9]+\}\}', out404)
if remaining404:
    raise SystemExit(f"Unsubstituted placeholders in 404: {remaining404}")
with open('404.html', 'w') as f:
    f.write(out404)
print(f"wrote 404.html: {len(out404)} bytes ({len(out404)/1024:.0f} KB)")
