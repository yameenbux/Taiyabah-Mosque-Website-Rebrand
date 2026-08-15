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

**Prayer times** — a live "next jamā'ah" countdown on the homepage, plus a
full-year timetable you can browse month by month and print, straight from
the masjid's own published schedule.

**The new build** — where the appeal stands, donation tiers, and bank
transfer details for anyone who'd rather give directly.

**About** — the masjid's history back to 1967, its founders, its imams, and
what's planned for the new building.

**Madrasah, contact, and the app** — how to reach the masjid, and a QR code
and install steps for the companion prayer times app.

## Design

Built to feel like one product with the [companion app](https://yameenbux.github.io/Taiyabah-Mosque-App/) —
same colours, fonts, logo, and geometric motif, pulled directly from the
app rather than reinterpreted. The app remains the tool for day-to-day use
(live countdowns, Qibla, alerts); this site is what a browser or a search
engine finds first.

## For anyone maintaining this

A static site — `index.html`, no build step, no framework, deployed via
GitHub Pages the same way as the app. A few things worth knowing:

- **Content is sourced, not invented.** Everything here — history, hadith,
  donation details, the timetable — comes directly from the app or the
  masjid's own materials. If you're adding something new (press coverage,
  updated figures), get it confirmed by the masjid rather than assuming.
- **The timetable needs a yearly refresh.** `index.html` embeds the full
  year's prayer times as a JS array. Regenerate it from the masjid's
  published timetable the same way the app does (see the app repo's
  `parse_timetable.py`), then swap the array in.
- **Madrasah portals aren't live yet** — the site says "coming soon,"
  matching the app. Update both once they exist.

