<div align="center">

# Taiyabah Masjid — Website

**Prayer times, the new build appeal, and community info for Taiyabah Masjid, Bolton.**

[**taiyabah-mosque-website-rebrand**](https://yameenbux.github.io/Taiyabah-Mosque-Website-Rebrand/) · companion to the [prayer times app](https://yameenbux.github.io/Taiyabah-Mosque-App/)

![Taiyabah Masjid website preview](assets/preview-hero.png)

</div>

## About

Taiyabah Masjid has served Bolton's Muslim community since 1967 — one of the
first masjids in the city. This site is the front door for anyone who isn't
already using the [prayer times app](https://yameenbux.github.io/Taiyabah-Mosque-App/):
the masjid's history, the new build appeal, prayer times, and how to get in
touch, all in one place.

Bolton Central Islamic Society · Registered charity 1041569
31a Draycott Street, Bolton BL1 8HD

## What's here

The site has grown from a single-page prayer-times front door into a small
multi-page hub. Each "page" is really a section of one `index.html`, shown
and hidden by JS — there's no server routing.

**Home** — the hero, a live "next jamā'ah" countdown, and an at-a-glance
strip covering today's prayer times, the current community event, quick
links to the rest of the site, and a donate card.

**Prayer times** — the same live countdown, plus a full-year timetable you
can browse month by month and print, straight from the masjid's own
published schedule.

**The new build** — current appeal status and what's planned side by side,
a timeline of the build's progress so far (Phase 1 through the current
appeal), and donating online or by bank transfer in one place.

**Madrasah** — the masjid's history as a centre for Deeni education since
1967, the Whudhu Khana and mortuary facilities, and a "digital portals"
section (application form, parents/teachers portals, holiday planner) that
isn't live yet.

**Shop** — a preview of what the masjid's shop will sell (books, dates,
herbal medicine, honey, Ihram/Hajj items, oils, perfume, prayer
accessories, Zamzam water). Nothing is orderable yet.

**Articles** — short reads from the masjid, starting with "What Is Islam?"
More will be added here over time following the same layout.

**Services** — hall/room hire, birth/marriage/death services, and imams'
advice, each with their own detail page; education and tours are marked
"coming soon."

**Media** — a gallery of the masjid's YouTube videos (new build updates,
history, talks from visiting scholars).

**About** — the masjid's history back to 1967, its founders, and its imams.

**Contact** — address, phone, email, live radio stream, socials, and a map.

**Get the app** — a QR code and install steps for the companion prayer
times app.

## Design

Built to feel like one product with the [companion app](https://yameenbux.github.io/Taiyabah-Mosque-App/) —
same colours, fonts, logo, and geometric motif, pulled directly from the
app rather than reinterpreted. The app remains the tool for day-to-day use
(live countdowns, Qibla, alerts); this site is what a browser or a search
engine finds first.

Most page mastheads use the same pattern: a photo background with a dark
gradient scrim so the heading stays readable, matching the masjid's brand
colours. New sub-pages should follow this (see any `.pm-photo` or
`.svc-hero-banner` section in `index_template.html` for the markup).

## For anyone maintaining this

A static site — `index.html`, no build step, no framework, deployed via
GitHub Pages the same way as the app. Editing happens in
`index_template.html` and `build.py`; `python3 build.py` substitutes the
image/data placeholders and writes the final `index.html` — don't edit
`index.html` directly, changes will be overwritten on the next build.

A few things worth knowing:

- **Content is sourced, not invented.** Everything here — history, hadith,
  donation details, the timetable — comes directly from the app or the
  masjid's own materials. If you're adding something new (press coverage,
  updated figures), get it confirmed by the masjid rather than assuming.
- **The new build timeline is thin on detail, by design.** The dates on it
  (Phase 1, Phase 2, the 2022 fundraiser, the current Phase 3.3 appeal)
  come from the masjid's own published video titles on the Media page;
  the "Completed" status on Phase 2 and the fundraiser was confirmed
  verbally rather than from a written record. If you have the fuller
  project history — what each phase covered, exact completion dates,
  costs raised — update the timeline in `index_template.html` (search
  for `nb-timeline`) rather than leaving it thin.
- **Most masthead photos are stock photography, not the masjid's own.**
  The Prayer Times, Madrasah, Shop, Articles, Services, Media and Contact
  page backgrounds currently use royalty-free photos as placeholders
  (mosque interiors, a Qur'an, Makkah, children studying, app icons,
  etc.) — none claim to depict Taiyabah Masjid itself. Swap these for
  real photos of the masjid and its students as they become available.
  The New Build page is the exception — its background is the masjid's
  own architect's render of the actual building.
- **The timetable needs a yearly refresh.** `index.html` embeds the full
  year's prayer times as a JS array. Regenerate it from the masjid's
  published timetable the same way the app does (see the app repo's
  `parse_timetable.py`), then swap the array in.
- **Madrasah portals and the shop aren't live yet** — both say "coming
  soon," matching the app. Update once they exist.

