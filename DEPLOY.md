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

* **Finish the list below**, apply `003_admissions.sql`, and change the link on
  the Admissions page from "Have a look at the new form" to a real Apply
  button — search `index_template.html` for `PREVIEW LINK`; or
* **remove that link and its note**, and put `apply/` back behind the wall.

Whichever you choose, `apply/` must be on the server for the link to work, so
add it to the upload list at the same time as you make the link real.

It writes through `db/003_admissions.sql`, **which has not been applied**. So
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

Then: apply `003_admissions.sql`, add `apply/` to the upload list above, and
change the Admissions page on the main site from "applications open soon" to a
link to `/apply/`.

Until then the public Madrasah → Admissions page carries the fees, class times
and guidelines only, and asks people to ring the office.
