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

subs = {
    '{{FONT_FACES}}': load('build-inputs/font_faces.txt'),
    '{{PRIVACY_DATE}}': load('build-inputs/privacy_date.txt'),
    '{{ICON_B64}}': load('build-inputs/icon_b64.txt'),
    '{{CONTACT_BUILDING_B64}}': load('build-inputs/contact_building_b64.txt'),
    '{{LOGO_B64}}': load('build-inputs/logo_b64.txt'),
    '{{QR_B64}}': load('build-inputs/qr_b64.txt'),
    '{{WA_QR_B64}}': load('build-inputs/wa_qr_b64.txt'),
    '{{BANNER_PHOTO_B64}}': load('build-inputs/banner_photo_b64.txt'),
    '{{BANNER_ACCENT_B64}}': load('build-inputs/banner_accent_b64.txt'),
    '{{GIRIH_TILE_B64}}': load('build-inputs/girih_tile_b64.txt'),
    '{{GIRIH_SOLID_B64}}': load('build-inputs/girih_solid_b64.txt'),
    '{{FULL_2026_JSON}}': load('build-inputs/full2026.json'),
    '{{APP_SHOT_TIMES_B64}}': load('build-inputs/shot_times_sm_b64.txt'),
    '{{APP_SHOT_LIVE_B64}}': load('build-inputs/shot_live_sm_b64.txt'),
    '{{APP_SHOT_DONATE_B64}}': load('build-inputs/shot_donate_sm_b64.txt'),
    '{{HALLHIRE_BAND_B64}}': load('build-inputs/hallhire_band_b64.txt'),
    '{{SHOP_HONEY_B64}}': load('build-inputs/shop_honey_b64.txt'),
    '{{SHOP_DATES_B64}}': load('build-inputs/shop_dates_b64.txt'),
    '{{SHOP_HERBAL_B64}}': load('build-inputs/shop_herbal_b64.txt'),
    '{{SHOP_PRAYER_B64}}': load('build-inputs/shop_prayer_b64.txt'),
    '{{SHOP_BOOKS_B64}}': load('build-inputs/shop_books_b64.txt'),
    '{{SHOP_HAJJ_B64}}': load('build-inputs/shop_hajj_b64.txt'),
    '{{HOME_BUILDING_B64}}': load('build-inputs/home_building_b64.txt'),
    '{{SHOP_OILS_B64}}': load('build-inputs/shop_oils_b64.txt'),
    '{{SHOP_PERFUME_B64}}': load('build-inputs/shop_perfume_b64.txt'),
    '{{MADRASAH_HERO_B64}}': load('build-inputs/madrasah_hero_b64.txt'),
    '{{PRAYER_HERO_B64}}': load('build-inputs/prayer_hero_b64.txt'),
    '{{SHOP_HERO_B64}}': load('build-inputs/shop_hero_b64.txt'),
    '{{ARTICLES_HERO_B64}}': load('build-inputs/articles_hero_b64.txt'),
    '{{SHOP_ZAMZAM_B64}}': load('build-inputs/shop_zamzam_b64.txt'),
    '{{CONTACT_HERO_B64}}': load('build-inputs/contact_hero_b64.txt'),
    '{{SERVICES_HERO_B64}}': load('build-inputs/services_hero_b64.txt'),
    '{{MEDIA_HERO_B64}}': load('build-inputs/media_hero_b64.txt'),
    '{{ARTICLE_ISLAM_HERO_B64}}': load('build-inputs/article_islam_hero_b64.txt'),
    '{{ARTICLE_PILLARS_HERO_B64}}': load('build-inputs/article_pillars_hero_b64.txt'),
    '{{ARTICLE_PILLARS_THUMB_B64}}': load('build-inputs/article_pillars_thumb_b64.txt'),
    '{{ARTICLE_RAMADAN_HERO_B64}}': load('build-inputs/article_ramadan_hero_b64.txt'),
    '{{ARTICLE_RAMADAN_THUMB_B64}}': load('build-inputs/article_ramadan_thumb_b64.txt'),
    '{{ARTICLE_HAJJ_HERO_B64}}': load('build-inputs/article_hajj_hero_b64.txt'),
    '{{ARTICLE_HAJJ_THUMB_B64}}': load('build-inputs/article_hajj_thumb_b64.txt'),
    '{{EDU_ARABIC_B64}}': load('build-inputs/edu_arabic_b64.txt'),
    '{{EDU_GHUSL_B64}}': load('build-inputs/edu_ghusl_b64.txt'),
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
