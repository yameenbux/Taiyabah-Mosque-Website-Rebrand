# Where each file goes

**There is no upload step any more.** GitHub Pages serves this repository from
its root at `taiyabahwebsite.ysbdesigns.uk`, so **committing and pushing IS
deploying**. Nothing is copied anywhere by hand.

That has one consequence that is easy to miss: *everything in the repository is
a public web page unless it is excluded*. `_config.yml` is what excludes things
— it keeps a file in git and out of the published site. Anything not listed in
its `exclude` block goes live the moment it is pushed.

```
taiyabah-site-v2/
│
├── PUBLISHED — this is the website
│   ├── index.html          all 27 pages. NOT the photographs — see assets/
│   ├── 404.html
│   ├── assets/
│   │   ├── img/            every photograph (33 files, 3.1 MB)
│   │   ├── fonts/          amiri.woff2
│   │   └── *.png           logo and icons used by 404.html
│   ├── account/            visitor register / sign in
│   ├── venue/              hall hire office portal
│   ├── portal/             madrasah portal
│   ├── og-image.jpg        WhatsApp/Facebook preview — must stay in the ROOT
│   ├── robots.txt          currently BLOCKS all search engines
│   ├── robots.live.txt     rename to robots.txt on launch day
│   ├── sitemap.xml
│   └── _config.yml         the exclude list below
│
└── IN GIT, NOT PUBLISHED — excluded by _config.yml
    ├── index_template.html the real source. All editing happens here.
    ├── 404_template.html
    ├── build.py            templates -> index.html and 404.html
    ├── optimise-images.py  base64 sources -> img/
    ├── verify_structure.py static checks, run before every build
    ├── build-inputs/       13 MB: fonts, compressed photos, timetable, QR codes
    ├── db/                 migrations 008-010 and their local test harness
    ├── apply/              madrasah application form — NOT LIVE, see below
    ├── brand/              logo files for Stripe
    ├── newbuild-photos/    original photographs
    ├── docs/               screenshots for the README
    └── README.md, DEPLOY.md, DONATIONS.md
```

**Never edit `index.html` or `404.html` by hand.** They are generated. Edit
`index_template.html`, then:

```
python3 verify_structure.py && python3 build.py
python3 optimise-images.py        # only when a photograph changed
```

Then commit everything, including the regenerated `index.html` and anything new
in `img/`. Forget the assets and every photograph on the site becomes a
broken icon.

## If the site ever moves off GitHub Pages

`taiyabah-site-upload.zip` holds exactly the PUBLISHED list above. Unzip it into
the web root — often `public_html`, `www` or `htdocs` — keeping the folder
structure exactly as it is. Nothing else from the repository goes on the server.

```
/                       the web root
├── index.html          all 27 pages, but NOT the photographs — see assets/ below
├── 404.html            shown when someone types an address that doesn't exist
├── og-image.jpg        the WhatsApp/Facebook link preview picture.
│                       MUST sit in the root. The site refers to it as
│                       https://www.taiyabahmasjid.com/og-image.jpg —
│                       one folder deeper and every shared link loses its picture.
├── robots.txt          currently BLOCKS all search engines (see launch day below)
├── robots.live.txt     the version to switch to on launch day
├── sitemap.xml         tells Google the site exists
├── assets/             MUST be uploaded — the site does not work without it
│   ├── img/            every photograph on the site (33 files, 3.1 MB).
│   │                   These used to be inside index.html. They are not any
│   │                   more, so index.html on its own is NOT the website.
│   ├── fonts/          amiri.woff2 — the Arabic typeface
│   └── *.png           the logo and icons the 404 page uses
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

## The madrasah application form is published, as a preview that cannot send

`apply/` is a complete, working application form, and it **is** on the public
site so that the "have a look at the new form" link on the Admissions page
resolves. What stops it being used is `PREVIEW_ONLY` at the top of the script
in `apply/index.html`.

While `PREVIEW_ONLY` is true the page:

* shows a banner, before anyone types, saying it cannot send an application and
  giving the office number;
* disables the Send button and relabels it;
* returns from the submit handler **before the network call**, so nothing about
  a child ever leaves the browser.

That last point is the one that matters, and it is why excluding the folder was
the wrong tool. Between 3 and 4 September `apply/` was in `_config.yml`'s
exclude list, which did not hide the form so much as turn the Admissions
page's button into a 404. Worse, it protected nobody from the real risk: before
`PREVIEW_ONLY` existed the form was live-looking, and a parent could type their
child's name, date of birth and medical notes, press Send, and have all of it
transmitted to Supabase — which refused it only because the table does not
exist. Nothing would have been stored. It would still have been sent, before
the DPIA was written. **Being unable to keep data is not the same as not
collecting it.**

There are now two independent gates, and both must be opened deliberately:

1. `PREVIEW_ONLY = true` in `apply/index.html` — the browser never sends.
2. `db/008_admissions.sql` **not applied** — there is nowhere for a child's
   medical, SEND, EHCP or ethnicity data to go even if it did.

Do not "tidy up" by applying the migration early, and do not flip the flag
because the form looks finished. It is finished. That is not the question.

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

Then, in this order: apply `008_admissions.sql`, set `PREVIEW_ONLY = false` in
`apply/index.html`, and change the Admissions page from "applications open soon"
and "have a look at the new form" to a real Apply button — search
`index_template.html` for `PREVIEW LINK`.

`_test/apply_test.py` proves both halves: that the published form sends nothing
even when a complete, valid application is entered and the disabled button is
re-enabled from the console, and that the submission path still works when the
flag is off — so the day you flip it, it will not have quietly rotted.

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

## The admin signpost, and two-step verification

### What an administrator sees

An administrator signs in at `account/` like anybody else — same email, same
password, no authenticator code, because that page is also the shop. Once
signed in, they get a second button: **Go to the admin area**. It leads to
`portals/`, which lists the staff areas their account can open.

Three things to understand before changing any of it:

* **The button is a signpost, not a door.** It grants nothing. `portals/` holds
  no data — no booking, no application, no child's record. If someone got past
  every check on it they would see a list of two links.
* **It fails closed.** The role is read from `user_roles` under RLS. If that
  read errors for any reason, the button stays hidden and the hub shows "no
  access". A signpost that guesses is worse than no signpost, because it tells
  an attacker which login is worth pursuing.
* **Administrators only, for now.** Hall office staff and teachers still reach
  their portals by their own links. `AREAS` in `portals/app.js` already carries
  the role each area needs, so widening it later is one line, not a rewrite.

### Turning on the database side of two-step (`011`)

Until this migration is applied, the authenticator code on the staff portals is
checked **in JavaScript only**. Anyone with a staff email address and password
can skip the page and read the data straight from the API. Apply it.

**Run `db/011_PRECHECK.sql` first** — it is read-only and tells you who is
missing an authenticator, whether you have a second administrator, and whether
anything is currently unprotected.

**And re-run `011` after applying `008`, `009` or `010`.** Those migrations
create their own policies, and they create them *without* the two-step check.
`011` only alters policies that exist when it runs, so on the masjid's project
today it protects seven and skips ten, naming them in a notice. Running it again
later is safe and is the whole fix. `011_PRECHECK.sql` reports `still_open` at
any time — that number must be zero.

1. Every member of staff must have set up their authenticator first. The
   migration checks, and refuses to apply while anyone holding `admin`,
   `hall_office` or `teacher` has no verified factor — it prints their email
   addresses. Get those people to sign in to their portal once; it walks them
   through it. **Do not work around that check.** An administrator locked out is
   an administrator who cannot grant roles to let themselves back in.
2. Apply `db/011_require_two_step.sql` in the Supabase SQL editor.
3. Sign in to `venue/` and confirm a booking still opens and saves. If it does,
   the aal2 path works.

What it changes: every policy that lets a signed-in member of staff reach
across accounts now goes through `verified_admin()` or `verified_office()`,
which are `is_admin()` / `can_see_bookings()` **and** an `aal2` JWT claim.

What it deliberately does not change:

* `profiles: read own` and `user_roles: read own`. `account/` and `portals/`
  read those before the code is entered, to decide whether to show the admin
  button. They return the signed-in person's own two rows.
* Every public submission path. Members of the public are not signed in at all;
  if this migration caught them the site would stop taking bookings, which is a
  worse fault than the one it fixes.

`is_admin()` and `can_see_bookings()` are left telling the truth. A function
called `is_admin()` that returns false for an actual administrator is the sort
of thing that costs somebody an evening.

The bottom of `011` carries the exact SQL to put every policy back as it was.
Reverting reopens the hole — treat it as buying an hour, not as a fix.

**What it does not solve.** Two-step stops a stolen password. It does nothing
about a borrowed, unlocked laptop: a session already at aal2 stays trusted
until it expires. The office still needs to lock its screens.

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
* **Two weeks' notice.** The calendar starts a fortnight out and the days in
  between are struck through rather than hidden, so it is obvious why they
  cannot be picked. The database checks the same thing again — a browser can be
  edited, the database cannot. To change the period, edit `MIN_NOTICE_DAYS` in
  `index_template.html` **and** `NOTICE_DAYS` in `db/010_nikah_requests.sql`.
  Changing one without the other is the way this breaks.
* **Times are prayers, not hours.** The picker offers After Fajr, Zuhr, Asr,
  Maghrib and Isha and shows the real jamāʿah time for the chosen date, read
  out of the 2026 timetable already on the page. Beyond 2026 it shows the
  prayer name without a time rather than inventing one. Saturdays additionally
  offer 11:00am, for a nikāḥ before a separate wedding meal; picking that and
  then moving to a weekday clears it, and the database refuses it anyway.
* **Requests appear in the venue portal, alongside hall bookings.** One list,
  one place to check. Nikāḥ rows are badged and say "Agree date" rather than
  "Confirm", because the office still has to ring and take payment. Anyone with
  the `hall_office` role sees both. Nothing is emailed yet — see below.
* The office works requests through `status` — new, contacted, confirmed,
  declined, withdrawn — plus `agreed_date` and `agreed_time` for what was
  actually settled, which may differ from what was asked for.

**The office is not emailed yet.** Both hall bookings and nikāḥ requests arrive
silently and sit in the portal until somebody opens it. Email needs a verified
sending domain with SPF and DKIM records before anything sent from it will
reliably arrive, and an Edge Function to do the sending. Until that is in place,
tell the office plainly that the portal is the only place a new request shows
up — an alert that half-works is worse than none, because people stop checking.

## The one thing that changed about uploading

Until September 2026 `index.html` contained every photograph, base64-encoded
inside the document. It was 10.3 MB, and every visitor downloaded all of it —
including the pictures on pages they never opened — before anything appeared on
screen.

The photographs now live in `img/` as ordinary files, fetched only when
the page using them is opened. First load went from about 10.5 MB to about
615 KB.

**So `index.html` is no longer the whole website.** Upload it without
`img/` and every page loads, reads correctly, and shows a broken icon
where each photograph should be. There is nothing on screen to tell you why.

Two things stop that happening:

* `build.py` refuses to build at all if a photograph it needs is missing from
  `img/`, and prints the command that fixes it.
* Every build prints how many image files the site references and how much they
  weigh, so a number that suddenly drops is visible.

Neither helps if the folder is simply left out of the upload. Upload the whole
of `assets/`, every time.

### When you change or add a photograph

```
python3 optimise-images.py      # only when an image changed
python3 verify_structure.py && python3 build.py
```

`optimise-images.py` reads the base64 sources in `build-inputs/`, resizes each
one to a sensible cap for its role, re-encodes it as a progressive JPEG and
writes it to `img/`. It refuses to write a file that came out *bigger*
than the source — that is how the WhatsApp QR code was caught trying to become
a 32 KB JPEG when it is a perfectly good 4 KB PNG.
