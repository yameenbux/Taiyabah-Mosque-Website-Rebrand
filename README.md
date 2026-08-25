<div align="center">

# Taiyabah Masjid — Website & Madrasah Portal

**Prayer times, the new build appeal, community info, and the madrasah's
staff and parent portal for Taiyabah Masjid, Bolton.**

[**taiyabah-mosque-website-rebrand**](https://yameenbux.github.io/Taiyabah-Mosque-Website-Rebrand/) · companion to the [prayer times app](https://yameenbux.github.io/Taiyabah-Mosque-App/)

![Taiyabah Masjid website preview](assets/preview-hero.png)

</div>

## About

Taiyabah Masjid has served Bolton's Muslim community since 1967 — one of the
first masjids in the city. This site is the front door for anyone who isn't
already using the [prayer times app](https://yameenbux.github.io/Taiyabah-Mosque-App/):
the masjid's history, the new build appeal, prayer times, and how to get in
touch, all in one place.

Since August 2026 the repo also holds the **madrasah portal** — a separate,
authenticated application backed by a real database, for parents, teaching
staff and administrators.

Bolton Central Islamic Society · Registered charity 1041569
31a Draycott Street, Bolton BL1 8HD

## Repository layout

Two independent things live here. Keep them that way.

```
/
├── index_template.html   ← EDIT THIS for the public site
├── build.py              ← inlines images/data, writes index.html
├── index.html            ← GENERATED. Do not edit by hand.
├── assets/
└── portal/               ← the authenticated madrasah app
    ├── index.html        ← page + inlined Supabase client
    ├── app.js            ← auth logic
    └── config.js         ← project URL + public key
```

The public site is built; the portal is not. `python3 build.py` only touches
the root `index.html`. Nothing in `portal/` goes through the build step.

---

## The public website

One `index.html`, with each "page" a section shown and hidden by JavaScript.
No server routing, no framework.

**Home** — hero, a live "next jamā'ah" countdown, and an at-a-glance strip
covering today's prayer times, the current community event, quick links, and
a donate card.

**Prayer times** — the same live countdown, plus a full-year timetable you can
browse month by month and print, straight from the masjid's own schedule.

**The new build** — current appeal status and what's planned side by side, a
timeline of progress so far, and donating online or by bank transfer.

**Madrasah** — the masjid's history as a centre for Deeni education since 1967,
the Whudhu Khana and mortuary facilities, and the digital portals section. The
Parents and Teachers tiles now link out to `/portal/`.

**Shop** — a preview of what the shop will sell. Nothing is orderable yet.

**Articles** — short reads, starting with "What Is Islam?".

**Services** — hall/room hire, birth/marriage/death, and imams' advice, each
with a detail page. Education and tours are marked coming soon. Hall hire also
carries the availability calendar and booking flow — see below.

**Media** — the masjid's YouTube videos.

**About** — history back to 1967, founders, and imams.

**Contact** — address, phone, email, live radio stream, socials, map.

**Get the app** — QR code and install steps for the prayer times app.

---

## Hall hire booking (Taiyabah Centre)

Lives on the Hall Hire service page. Calendar and booking panel on the left,
venue details and terms prompt on the right, terms of hire full width below.

**How it works.** Pick a date, tick the terms box, choose a slot, fill in the
form, see the price. Two slots per day per hall: **morning 9:00am–4:00pm** and
**evening 5:00pm–11:00pm**. The 4–5pm hour is deliberately unbookable
changeover time. Bookings open **12 months ahead** — the month arrow stops at
the horizon and later days are disabled, so nobody can request a date the
masjid will not honour.

**Nothing is connected yet.** No booking data exists, so every future day
renders "not published" and the slot buttons say **Ask**, never **Book**. A
button offering to book a slot we cannot confirm is free is a promise the
masjid would have to break. A "Preview with sample data" toggle shows how real
availability will look, off by default, with a loud red banner when on.

**Terms are a gate, not a notice.** Six terms of hire are listed on the page,
and the Book button stays disabled until the "I have read and agree" box is
ticked. Taken slots stay disabled regardless. When bookings go live, **store
that tick with a timestamp against the booking** — it is what answers "nobody
told me about the cleaning charge" six months later.

### ⚠ Pricing must move server-side before it is real

Pricing depends on whether the customer is a masjid member, and the customer
should only ever see the figure that applies to them. The UI does that
correctly — one number is rendered, never a comparison.

**But the calculation currently happens in the browser, so both rates are
readable in the page source.** That is acceptable only because the numbers are
placeholders. Before real pricing goes in, `priceFor()` must be replaced with a
server-side call (a Postgres function or edge function) so the browser is told
one figure and never sees the other. There is a warning comment on the
`PRICING` object saying the same thing.

Also unresolved: **nothing verifies the membership answer.** Anyone can tick
"Yes" and get the member rate. Either the office checks each booking against
the membership list, or the form should ask for a membership number instead.

### Gaps the masjid still needs to decide

- Real pricing (placeholders in the `PRICING` object).
- **Cancellation and refund policy** — payment is taken in full upfront and
  there is currently no stated position on cancellations. This will come up.
- **Damage and breakages** beyond the cleaning charge.
- Whether an online request confirms automatically or waits for approval.
  Approval is strongly advised: a double-booked walimah is not recoverable.

---

## The madrasah portal

Lives at `/portal/`, separate from the marketing site so its code never ships
to ordinary visitors. Backed by **Supabase** (managed Postgres + auth) in the
**London** region.

Working today: email/password sign-in, TOTP two-factor including first-time
enrolment with a QR code, session persistence, role lookup, and sign out.
Roles are `admin`, `teacher`, `parent`.

**Not built yet:** anything a signed-in user actually *does*. There are no
pupil, guardian, attendance or report tables — deliberately, see the
compliance note at the bottom.

### How access control works

Two separate gates, and you need both:

- **GRANT** decides which *operations* a role may attempt.
- **RLS** decides which *rows* it gets once allowed.

Postgres checks grants before it ever evaluates a policy. Migration 001 wrote
the policies but granted nothing, and every signed-in query failed with
`permission denied for table profiles` — the policies never ran. Migration 002
fixed it. If you add a table, it needs both.

Roles live in their own `user_roles` table, never as a column on `profiles`.
A role on a row users can edit means any parent can promote themselves.

### Database migrations

Held in the separate database working folder, not this repo:

- `001_foundation.sql` — roles enum, `user_roles`, `profiles`, `has_role()`,
  `is_admin()`, RLS policies, `admin_audit`, first-admin bootstrap.
- `002_grants.sql` — table privileges, plus default privileges so new tables
  don't repeat the bug above.

Validate new migrations against a local PostgreSQL 16 using
`_test_harness.sql` and `_test_rls.sql`. **Those files are local-only — never
run them against Supabase.** The suite includes escalation tests: a parent
account must not be able to grant itself admin, rewrite a role row, or delete
audit entries.

---

## Design

Built to feel like one product with the [companion app](https://yameenbux.github.io/Taiyabah-Mosque-App/) —
same colours, fonts, logo, and geometric motif, pulled from the app rather than
reinterpreted. The app is the tool for day-to-day use; this site is what a
browser or search engine finds first. The portal shares the same design tokens
so it doesn't feel like a different product.

Most mastheads use one pattern: a photo background with a dark gradient scrim
so the heading stays readable. New sub-pages should follow it — see any
`.pm-photo` or `.svc-hero-banner` section in `index_template.html`.

The footer carries a **YSB Designs** credit linking to `ysbdesigns.uk`. It sits
in the shared footer, so one edit covers every page; the portal has its own
copy in the brand panel because it has no footer.

External images degrade gracefully: YouTube thumbnails on the Media page fall
back to the brand gradient and play icon if `i.ytimg.com` is unreachable, which
happens on networks that block YouTube.

---

## For anyone maintaining this

Static files on GitHub Pages, no server. The public site is generated: edit
`index_template.html`, run `python3 build.py`, never edit the root
`index.html` directly. The portal has no build step — edit its files directly.

**Always run the structure check before building:**

```bash
python3 verify_structure.py && python3 build.py
```

It catches unbalanced `<div>`s per page, dead `data-nav` targets, broken
anchors and scroll targets, duplicate IDs, and template placeholders missing
from `build.py` — all without a browser. It exists because a single missing
`</div>` once broke seven pages, and it has been verified to catch exactly that
case.

### Keys and secrets

- The **anon / publishable key** in `portal/config.js` is *designed* to be
  public. Committing it is fine. RLS is what protects the data.
- **The `service_role` key must never appear anywhere in this repo.** It
  bypasses RLS entirely. GitHub secret scanning has already blocked one push
  containing it — if that happens, don't click "Allow Secret"; replace the key
  and rotate it.
- `SUPABASE_URL` is the bare project origin, `https://<ref>.supabase.co`, with
  no path. Pasting the REST endpoint (`…/rest/v1/`) gives
  `Invalid path specified in request URL`.

### Things that have bitten us

- **`portal/` must have no external file dependencies.** The Supabase client
  and the logo are inlined for a reason: `vendor/` is ignored by many default
  `.gitignore` templates and repeatedly failed to deploy, 404ing and hanging
  the portal on its loading spinner. `assets/` is referenced zero times by the
  built site, so don't assume it's committed either.
- **Deleting an auth user silently destroys their role.** Both tables cascade
  from `auth.users`. Delete the only admin and nobody can grant roles again,
  because only an admin may write to `user_roles`.
- **A test harness must not fabricate the thing it verifies.** The original
  suite granted table privileges itself while asserting Supabase did so
  automatically. Twelve tests passed against a database configured differently
  from production. Reproduce failures against a realistic environment first.
- **One missing `</div>` silently broke seven pages.** An unclosed page div on
  Hall Hire meant every page after it — Birth/Marriage/Death, Birth, Marriage,
  Islamic Will, Imams' Advice, Media and Contact — became *children* of Hall
  Hire, so they had nowhere to render. Clicking them changed the nav highlight
  and the URL and showed nothing. Every page div must close before the next
  one opens; `verify_structure.py` now checks this.
- **Test what a person can see, not what the DOM contains.** Three separate
  bugs slipped through because tests asked the wrong question. Navigation was
  tested by calling `showPage()` directly, so it passed while the click
  handlers were dead. The terms block was checked with `text_content`, which
  reads hidden nodes, so it passed while sitting on the wrong page entirely.
  The nested pages passed a content check because a swallowed page still
  returns text. Assert **visibility and rendered height**, and click real
  links.
- **A page widget must never break the whole site.** A dead reference in the
  hall hire calendar threw on load, which stopped the rest of that script block
  running — and the site's navigation binding lives in it. Every page-specific
  widget is now wrapped in `try/catch` so it fails alone.

### Testing

Playwright suites live outside the repo but are worth recreating if lost. What
matters is what they assert:

- **Full-site audit** — every page loaded and measured for rendered height,
  visible text, broken images and JS errors; page-nesting check; every internal
  link clicked for real; `rel="noopener"` on external links; static pass for
  dead nav targets, orphan pages, duplicate IDs and broken anchors.
- **Navigation** — clicks all nine top-level links plus a sub-page and back
  link, and fails on any uncaught exception.
- **Hall hire** — layout, two slots and their times, 12-month horizon, terms
  gate, form validation, membership pricing, and that no availability is
  asserted while unpublished.

Always attach a `pageerror` listener. Console-message listeners do **not**
catch uncaught exceptions, which is how the navigation break went unnoticed.

### Content

- **Content is sourced, not invented.** History, hadith, donation details and
  the timetable all come from the app or the masjid's own materials. Get
  anything new confirmed by the masjid rather than assuming.
- **The new build timeline is thin on detail, by design.** Dates come from the
  masjid's published video titles; the "Completed" status on Phase 2 and the
  fundraiser was confirmed verbally, not from a written record. If you have the
  fuller history, update `nb-timeline` in `index_template.html`.
- **Most masthead photos are stock, not the masjid's own.** Prayer Times,
  Madrasah, Shop, Articles, Services, Media and Contact all use royalty-free
  placeholders. None claim to depict Taiyabah Masjid. Swap them for real photos
  as they become available. The New Build page is the exception — that's the
  masjid's own architect's render.
- **The timetable needs a yearly refresh.** The full year is embedded as a JS
  array. Regenerate from the masjid's published timetable the way the app does
  (see the app repo's `parse_timetable.py`), then swap the array in.
- **The shop isn't live** and neither are the madrasah application form or
  holiday planner.

### Before real families use the portal

- **Create a second administrator.** There is currently one. See the cascade
  note above for why that is the most pressing operational risk here.
- **Remove the debug scaffolding** — the Diagnostics panel in `portal/app.js`
  and `portal/index.html`, and `drop function public.whoami();`.
- **MFA is enforced in the front-end only.** A determined user could call the
  API without completing it. Once pupil tables exist, their RLS policies must
  require `aal2` via the JWT claim rather than trusting the browser.

### The compliance line

A madrasah roll inherently reveals religious belief, which makes it **special
category data under UK GDPR Article 9** — the same tier as health records —
before a single report is attached to it.

**The hall hire form is also Article 9 data.** "Are you a member of the
masjid?" answered Yes discloses religious affiliation. It is legitimate to ask,
and the non-profit religious body condition covers it, but it is not the
ordinary contact form it looks like and belongs in the DPIA. That form also
collects name, address and phone number.

Staff accounts process no child's data, which is why the work so far has
stopped short of pupil tables. **A Data Protection Impact Assessment must be
completed before the first real pupil record is entered.** Also required
regardless of system: ICO registration (~£52/yr, Tier 1), a documented lawful
basis and Article 9 condition, an Appropriate Policy Document if safeguarding
data is held, and a breach procedure with a 72-hour route to the ICO.
