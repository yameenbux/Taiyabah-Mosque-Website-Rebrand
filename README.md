# Taiyabah Masjid — Website, Madrasah Portal & Venue Portal

**Prayer times, the new build appeal, community information, hall hire bookings,
and two staff portals for Taiyabah Masjid, Bolton.**

Bolton Central Islamic Society · Registered charity 1041569 · 31a Draycott Street, Bolton BL1 8HD

![The Taiyabah Masjid website home page](docs/screenshot-home.jpg)

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

## Tech stack

| Layer | What's used | Why |
| --- | --- | --- |
| **Frontend** | HTML5, CSS3, vanilla JavaScript | No framework and no bundler. One self-contained file a browser runs directly — fewer moving parts on a site a volunteer may have to edit years from now |
| **CSS** | Custom properties, Grid, Flexbox, `clamp()` fluid type | One layout from a 390px phone to a desktop with no breakpoint sprawl. Verified: zero horizontal overflow on all 20 pages |
| **Routing** | Hash-based, single document | Every page is one HTTP response. No server, no router library, and the whole site works from a file:// URL |
| **Build** | Python 3, standard library only | Substitutes `{{PLACEHOLDER}}` tokens into the template. `verify_structure.py` runs first and refuses to build a broken document |
| **Typography** | Fraunces, Hanken Grotesk, Amiri — self-hosted woff2 | Google Fonts would send every visitor's IP to Google before they consented. Subset with fontTools; Arabic keeps its full shaping tables |
| **Images** | Pillow — resize, unsharp mask, base64 inline | Everything is a data URI, so the page makes no image requests at all |
| **Backend** | Supabase — Postgres 15, GoTrue auth, PostgREST | Managed Postgres in **London**, so booking data never leaves the UK |
| **Access control** | Row Level Security + column-level `GRANT` | The anon key can insert seven named columns and cannot read a single row back. Office staff can change three columns and no others |
| **Authentication** | Supabase Auth with TOTP two-factor | Roles live in their own table, never on the user's own row, so nobody can promote themselves |
| **Notifications** | Supabase Edge Functions (Deno) + Resend | A booking that arrives on a Friday night should not wait until Tuesday |
| **Testing** | Playwright (Python) for the browser, `psql` for the database | Policies are proved against a real Postgres with a Supabase stub *before* they reach the live project |
| **Hosting** | GitHub Pages | Static; a push to `main` is the deploy |

## What it looks like

**Hall hire** — real availability read from the database, two sessions a day, a
twelve-month horizon, and terms that must be agreed before a slot unlocks.

![The hall hire booking calendar, showing session availability for a chosen date](docs/screenshot-hallhire.jpg)

**The venue portal** — where the office works through requests. Staff signed in
here can see bookings and provably nothing else; they may change a request's
status and notes, but never the applicant's own details.

![The venue hire portal listing new booking requests](docs/screenshot-venue-portal.jpg)

## Engineering notes

Each of these came from something that actually went wrong.

**Nothing reaches another company.** The site sets no cookies and makes zero
third-party requests — fonts self-hosted, the Google Maps embed replaced with an
address card, YouTube thumbnails removed. The one exception is the hall hire
page, which asks the booking database which dates are taken; that fetch is
deferred so that reading the prayer times contacts nobody. All of this is
asserted by a test against the rendered page, so a future change that
reintroduces a tracker fails the build rather than the privacy notice.

**A structural checker that runs before every build.** One missing `</div>`
once left seven pages nested inside another. Navigation highlighted correctly,
the URL changed, and nothing rendered — because the pages were still in the DOM,
which is exactly what the tests were checking. `verify_structure.py` now checks
div balance per page and document-wide, dead `data-nav` targets, unresolved
anchors, duplicate ids, and placeholders `build.py` does not define.

**Special category data that is asked for and then thrown away.** The booking
form asks whether the enquirer is a masjid member, because that decides the rate
quoted. Membership of a mosque discloses religious belief — Article 9 data. The
answer is used on screen and never transmitted; the resulting price is withheld
too, since with two possible figures storing one would disclose the answer just
as plainly.

**Least privilege between two audiences sharing one login system.** Venue office
staff and madrasah staff sign in through the same Supabase project, but a
`hall_office` role sees bookings and provably nothing else — a test asserts they
can read zero other profiles and zero other role rows.

**Failing honestly when the truth is unknown.** If availability cannot be
fetched, every date stays "unknown" rather than claiming to be free. If a
booking cannot be submitted, the screen says so and gives the office number
instead of showing a false confirmation. Both paths are tested by aborting the
request.

**Tests that ask the right question.** Three bugs shipped because tests checked
the DOM rather than what a person can see. The suite now attaches
`page.on("pageerror")` (console listeners do not catch uncaught exceptions),
navigates by clicking real links rather than calling the hoisted `showPage()`,
and asserts visibility and rendered height rather than presence.

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

## About this project

Part of a wider *Taiyabah Masjid — Complete Overhaul*, alongside the
[prayer times app](https://github.com/yameenbux/Taiyabah-Mosque-App) and the
[home smart screen](https://github.com/yameenbux/Taiyabah-Masjid-HomeSmartScreen).
Branding, fonts and prayer data are shared with those sibling repositories
rather than reinvented here.

## Credits

Built for Bolton Central Islamic Society. The Taiyabah Masjid name, the masjid's
logo and the prayer timetable belong to the charity — the timetable is the
masjid's own published times, not calculated by this site and not taken from a
third-party aggregator.

Typefaces are [Fraunces](https://github.com/undercasetype/Fraunces),
[Hanken Grotesk](https://github.com/globalfoundries/HankenGrotesk) and
[Amiri](https://github.com/aliftype/amiri), all under the SIL Open Font License
1.1, self-hosted here as that licence expressly permits. Photography of the
masjid and the new build was supplied by the masjid. Shop category images are
stock photography standing in until the masjid's own product photographs are
available.

Bolton Council of Mosques contact details on the funeral services page are taken
from BCoM's own published information and should be confirmed with the masjid
before they are relied upon.

Designed and built by **[YSB Designs](https://ysbdesigns.uk)**.
