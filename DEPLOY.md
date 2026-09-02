# Where each file goes

Two piles. **Upload** goes on the web server. **Keep** stays in the repo and is
never uploaded — it is how the site is rebuilt.

## Upload — this is the website

Everything in `taiyabah-site-upload.zip`. Unzip it and put the contents in the
web root (the folder the domain points at — often `public_html`, `www` or
`htdocs`), keeping the folder structure exactly as it is.

```
/                       the web root
├── index.html          the entire public site — all 25 pages are in this one file
├── 404.html            shown when someone types an address that doesn't exist
├── og-image.jpg        the WhatsApp/Facebook link preview picture.
│                       MUST sit in the root. The site refers to it as
│                       https://www.taiyabahmasjid.com/og-image.jpg —
│                       one folder deeper and every shared link loses its picture.
├── robots.txt          currently BLOCKS all search engines (see launch day below)
├── robots.live.txt     the version to switch to on launch day
├── sitemap.xml         tells Google the site exists
├── assets/             the logo and icons the 404 page uses
├── account/            where visitors register and sign in
│   ├── index.html
│   ├── app.js
│   └── config.js
├── venue/              the HALL HIRE office portal — staff accept/decline bookings
│   ├── index.html
│   ├── app.js
│   └── config.js
└── portal/             the MADRASAH portal — parents, pupils, madrasah admins
    ├── index.html
    ├── app.js
    └── config.js
```

`account`, `venue` and `portal` must keep those exact folder names. The site
links to them by name, so renaming one breaks the link that points at it.

## Keep — never upload these

| File | What it is |
|---|---|
| `index_template.html` | The real source. All editing happens here. |
| `404_template.html` | Same, for the 404 page. |
| `build.py` | Turns the templates into `index.html` and `404.html`. |
| `verify_structure.py` | Checks the template before building. |
| `README.md`, `DEPLOY.md` | Documentation. |
| `docs/` | Screenshots for the README. |
| `brand/` | Logo and icon files for Stripe and other third-party services, plus the script that generates them. Not part of the website. |
| `newbuild-photos/` | Original photographs, already compressed into the site. |
| `build-inputs/` | **The 41 files `build.py` reads to make `index.html`** — fonts, compressed photographs, the prayer timetable, QR codes. Committed, so a fresh clone can rebuild the site. |
| `apply/` | **The madrasah application form. Finished, tested, and deliberately NOT deployed — see below.** |
| `db/` | Database migrations and their local test harness. `_test_` files are local-only and must never be run against Supabase. |

**Never edit `index.html` by hand.** It is generated. Edit
`index_template.html`, then run:

```
python3 verify_structure.py && python3 build.py
```

Anything typed straight into `index.html` is wiped the next time that runs.

## On launch day, in this order

1. Decide what happens to the madrasah form preview link — see
   "The madrasah application form" below. Do not skip this one.
2. Point `taiyabahmasjid.com` at this site.
2. Only then: delete `robots.txt` and rename `robots.live.txt` to `robots.txt`.

That order matters. Doing it the other way round lets Google index the
temporary address, and the old and new sites then compete with each other.

## Before launch: the donate buttons

The five donate links on the New Build page still point at
`www.taiyabahmasjid.com/product/bronze-donor/` and the four beside it. Those are
pages on the **current WordPress site**. The moment the domain points here
instead, all five become "page not found" — including "Give any other amount".

Somebody has to decide where donations go after the move, and the links have to
be changed to match. This is the one thing on the site that cannot be allowed to
break silently.

## Later: when the shop actually opens

The "What Is Hajj?" article carries a call-out pointing at the Ihram &
Hajj/Umrah category in the shop. While the shop is a preview, that call-out
promises a **look**, not a purchase — "It isn't taking orders yet."

The day the shop takes its first order, that wording becomes untrue in the
other direction: it will be talking people out of buying. Search
`index_template.html` for `LAUNCH-DAY SWAP` — the replacement heading, sentence
and button label are sitting in a comment directly above the block. Swap the
three lines, rebuild, done.

Same applies to the nine `Coming soon` tags on the Shop page and the page
heading, "The Taiyabah Shop is on its way."

## The madrasah application form is finished but must not be uploaded yet

`apply/` is a complete, working application form. It is kept out of
`taiyabah-site-upload.zip` on purpose.

**The Admissions page now carries a link to it, labelled as a preview.** That is
fine while the site sits on the staging address (`robots.txt` blocks every
crawler and the form says plainly that it will not send anything). It is NOT
fine once `taiyabahmasjid.com` points here — a parent would fill in their
child's medical details and get an error.

So before the domain is pointed, do one of two things:

* **Finish the list below**, apply `008_admissions.sql`, and change the link on
  the Admissions page from "Have a look at the new form" to a real Apply
  button — search `index_template.html` for `PREVIEW LINK`; or
* **remove that link and its note**, and put `apply/` back behind the wall.

Whichever you choose, `apply/` must be on the server for the link to work, so
add it to the upload list at the same time as you make the link real.

It writes through `db/008_admissions.sql`, **which has not been applied**. So
even if the folder were uploaded by accident today, a submission would fail:
there is nowhere for a child's medical, SEND, EHCP or ethnicity data to go.
That is the safety property. Do not "tidy up" by applying the migration early.

Before any of it ships, all of the following must be done:

1. DPIA completed and signed off.
2. ICO registration in place (Tier 1, around £52 a year).
3. Lawful basis under Article 6 documented, plus an Article 9 condition for the
   health, SEND and ethnicity fields.
4. Appropriate Policy Document written.
5. Breach procedure written, with a 72-hour route to the ICO.
6. A retention period agreed for unsuccessful applications, and set in
   `purge_old_admission_applications()`.
7. A **second administrator** created — deleting the only admin cascades away
   its roles and profile with no recovery.
8. `apply/config.js` updated with the current academic year, deadline and
   date-of-birth windows. Every year-specific value lives in that one block so
   the page can never go stale the way the old IBEUK form did.

Then: apply `008_admissions.sql`, add `apply/` to the upload list above, and
change the Admissions page on the main site from "applications open soon" to a
link to `/apply/`.

Until then the public Madrasah → Admissions page carries the fees, class times
and guidelines only, and asks people to ring the office.

## Turning on course registration

The Education pages are live with the class details and the office phone
number. The sign-up forms are written and tested but hidden behind one switch.

To turn them on:

1. Apply `db/009_courses.sql`. Much lighter than the madrasah migration —
   adult names, emails and phone numbers, no children and no health data — but
   it still needs ICO registration, a documented lawful basis, a retention
   period and a line in the privacy notice. Read the header of that file first.
2. In `index_template.html`, find `REGISTRATION_OPEN = false` and set it true.
   One switch covers every course.
3. While you are there, set `day` on the arabic entry in `COURSES` to the
   evening it runs, e.g. `'Tuesdays'`. Leave it empty and the page just says
   "one evening a week".
4. Rebuild and upload.

Do not do step 2 before step 1. With the switch on and the tables missing, a
visitor fills the form in and is handed an error.

**Adding a third course** is a `.course-reg` div on a new page plus an entry in
`COURSES` in `index_template.html`, and one row in `public.courses`. The
capacity, the cohorts and whether sign-ups are open all live in that row, so
the office can close a course without a code change.

The place cap is enforced in the database, not in the page — the function
counts existing sign-ups inside a lock and returns either a place or a
waiting-list position. Nobody has to keep a "places left" number up to date,
and two people cannot take the last seat at once.

## Turning on Nikah date requests

The Marriage page is live with the calendar, the time slots and a notice saying
plainly that it is a request rather than a booking. Where the form will go, it
currently shows the office phone number.

To turn it on:

1. Apply `db/010_nikah_requests.sql`. Same shortlist as `009_courses.sql` — ICO
   registration, a documented lawful basis, a retention period and a line in
   the privacy notice. The same ICO entry covers all of them.
2. In `index_template.html`, find `REQUESTS_OPEN = false` and set it true.
3. Rebuild and upload.

Do not do step 2 before step 1.

Worth knowing about the design:

* **Nothing on that calendar shows availability, on purpose.** The masjid does
  not publish its nikah diary, so every future day inside the year looks the
  same — because as far as the website is concerned, it is. Colouring days
  green would be inventing information the site does not have.
* **The form asks for very little**: who to ring, when they would like it, and
  anything they want to add. It does not collect the couple's names, addresses,
  documents or witnesses. The office takes those on the phone once a date is
  agreed, and there is no reason for the website to hold them.
* **Two couples may request the same day.** The office decides. The only thing
  refused is the same email asking twice for the same date.
* The office works requests through `status` — new, contacted, confirmed,
  declined, withdrawn — plus `agreed_date` and `agreed_time` for what was
  actually settled, which may differ from what was asked for.
