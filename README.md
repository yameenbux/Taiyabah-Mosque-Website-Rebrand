<div align="center">

# Taiyabah Masjid — Website, Madrasah Portal & Venue Portal

**Prayer times, the new build appeal, community information, hall hire
bookings, and two staff portals for Taiyabah Masjid, Bolton.**

Bolton Central Islamic Society · Registered charity 1041569
31a Draycott Street, Bolton BL1 8HD

</div>

## What this is

Taiyabah Masjid has served Bolton's Muslim community since 1967 — one of the
first masjids in the city. This repository holds three things:

| | |
|---|---|
| **The public website** | Prayer times, the new build appeal, services, the madrasah, hall hire with online booking, and contact details. |
| **`portal/`** | The **Madrasah Portal** — authenticated, for parents, teaching staff and administrators. Reached from the Madrasah page. |
| **`venue/`** | The **Venue Hire Portal** — authenticated, for the office staff who handle bookings at the Taiyabah Centre. Reached from the Hall Hire page. |

Both portals share one Supabase project, one set of accounts and one
two-factor setup, but a person only sees what their role allows.

> **The site is not live yet.** `robots.txt` currently blocks all search
> engines. See [Launch day](#launch-day) before that changes.

---

## Repository layout

```
index_template.html     the SOURCE of the website — edit this, never index.html
build.py                substitutes {{PLACEHOLDERS}} -> writes index.html
verify_structure.py     static checks; run BEFORE build.py, every time
index.html              GENERATED. Do not edit by hand.

robots.txt              currently blocks all crawlers (staging)
robots.live.txt         rename to robots.txt on launch day
sitemap.xml
404.html

portal/                 Madrasah Portal   (index.html, app.js, config.js)
venue/                  Venue Hire Portal (index.html, app.js, config.js)
```

### Building

```bash
python3 verify_structure.py && python3 build.py
```

`verify_structure.py` exists because a single missing `</div>` once left seven
pages nested inside another one — the navigation highlighted correctly, the URL
changed, and nothing rendered. It checks div balance per page and document-wide,
dead `data-nav` targets, unresolved anchors, duplicate ids, and placeholders the
template uses that `build.py` does not define. **Exit 0 is clean.**

Images and fonts are base64 data URIs substituted at build time from
`/tmp/*_b64.txt`. Nothing is fetched from another server at runtime.

---

## The database

Migrations live in a separate directory and are applied by pasting them into the
Supabase SQL editor, in order.

| Migration | What it does |
|---|---|
| `001_foundation.sql` | Roles, profiles, `has_role()`, `is_admin()`, RLS, audit table |
| `002_grants.sql` | Table privileges for `authenticated` |
| `003_hall_bookings.sql` | The bookings table, flood control, retention function |
| `004_hall_office_role.sql` | The `hall_office` role — **run in two parts** |
| `005_availability_by_hall.sql` | Superseded by 006; keep for history |
| `006_halls_and_kitchen.sql` | Named halls, the kitchen option, whole-venue availability |
| `007_retention_and_cleanup.sql` | Schedules the deletion job, drops `whoami()` |

`STAFF_give_someone_a_role.sql` is the one you will reuse — it grants a role to
an account by email address and prints the full staff list.

Files beginning `_test_` are **local only**. They insert junk rows and call
`set role`. Never run one against Supabase. `_test_supabase_stub.sql` recreates
enough of Supabase on a throwaway Postgres to prove policies before they ship.

### Two rules that were learned the hard way

**GRANT and RLS are different things and you need both.** Postgres checks table
privileges *before* it evaluates any policy. Migration 002 shipped with policies
but no grants, and every signed-in query failed with `permission denied`.

**Blanket default privileges are a foot-gun.** Migration 002 ends with
`alter default privileges … grant … on tables to authenticated`, which applies
to tables created *afterwards*. `hall_bookings` therefore arrived with DELETE
and unrestricted INSERT for every signed-in user. RLS held, so nothing leaked,
but migration 006 takes those privileges back explicitly. Check the grants on
any new table rather than assuming.

---

## Hall bookings

1. Someone fills in the form on the Hall Hire page.
2. The request is inserted into `hall_bookings` with status `new`. The anon key
   can insert seven named columns and **cannot read a single row back**.
3. Office staff see it in `venue/`, ring the enquirer, and confirm or decline.
   They may only change `status`, `office_notes` and `handled_at` — never the
   applicant's name, address or requested date.
4. A **confirmed** booking closes that session for everyone, whichever hall it
   was for. The public calendar reads `hall_availability`, a view containing
   nothing but a date and a session.

### What is deliberately not stored

The form asks whether the enquirer is a member of the masjid, because the answer
decides which rate they are quoted. **That answer is never transmitted or
stored**, and neither is the resulting price. Membership of a mosque discloses
religious belief, which is special category data under Article 9 of the UK GDPR;
with only two possible prices, storing one would disclose the answer just as
plainly.

The consequence the office must know: when they ring back, they cannot see which
rate the website quoted. They quote it themselves.

### Retention

`purge_old_hall_bookings()` deletes requests six months after the event date, and
declined or cancelled ones after three. Migration 007 puts it on a weekly
schedule. **Those periods are also written into the privacy notice on the
website** — change one and you must change all three.

---

## Privacy

The site sets **no cookies**, uses no analytics, and makes **zero requests to
third-party servers**. Fonts are self-hosted, the Google Maps embed was replaced
with an address card, and YouTube thumbnails were removed. Everything that
reaches another company does so only when a visitor chooses to click it.

This is asserted by an automated test against the rendered page, not just
believed. If a future change reintroduces a tracker, that test fails.

The privacy notice lives at the `privacy` page and is linked from the footer.

---

## Security

- **Only the anon (publishable) key ever reaches a browser.** It is safe to
  commit. RLS is the real boundary.
- **The `service_role` key must never appear in this repo**, in any file, ever.
  If GitHub secret scanning blocks a push, do **not** click "Allow secret" —
  cancel, remove the key, and rotate it in Supabase.
- **Roles live in their own table**, never as a column on `profiles`, so a user
  cannot promote themselves by updating their own row.
- **`hall_office` cannot reach madrasah data.** Venue staff see bookings and
  nothing else — proved by a test that asserts they see zero other profiles.
- **Keep two administrators.** Deleting the only admin account destroys its
  roles and profile by cascade, and nobody can then grant the role back.

---

## Testing

Browser tests use Playwright. Three habits, each from a bug that shipped:

- **Attach `page.on("pageerror")`.** Console listeners do not catch uncaught
  exceptions. A null reference once killed the whole script block, including the
  navigation binding, and the tests passed.
- **Navigate by clicking real links**, never by calling `showPage()`. That
  function is hoisted, so it works even when the click handler is broken.
- **Assert what is visible**, not what is in the DOM. `text_content` reads
  hidden nodes, so a block that rendered on the wrong page still passed.

---

## Launch day

In this order:

1. Point `taiyabahmasjid.com` at this site. The canonical tag and sitemap
   already name that domain.
2. **Delete `robots.txt` and rename `robots.live.txt` to `robots.txt`.** Miss
   this and the site works perfectly but never appears in Google.
3. Update `PORTAL_URL` in the Edge Function settings, and the QR code if the app
   has moved to its own domain by then.

---

## Known limitations

- **The prayer timetable holds 2026 only.** It degrades honestly — the header
  falls back to "open the app" — but it needs the 2027 timetable before
  1 January 2027.
- **Booking emails are not connected.** The Edge Function is written and tested;
  it needs a verified sending domain. Until then a request waits in the portal.
- **The app is still served from a personal GitHub Pages address**, which the QR
  code and five links resolve to.
- **The notification function always replies OK to Supabase, even on failure.**
  That prevents a retry loop emailing the office repeatedly, but it means a
  silent failure stays silent. Send a test booking every few months.

---

<div align="center">
<sub>Designed &amp; built by <a href="https://ysbdesigns.uk">YSB Designs</a></sub>
</div>
