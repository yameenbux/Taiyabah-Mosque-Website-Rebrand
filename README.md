# Taiyabah Masjid — website, accounts and staff portals

Prayer times, the new build appeal, donations with Gift Aid, community
information, madrasah admissions, adult courses, hall hire with online payment,
nikāḥ requests, food bank volunteering, visitor accounts and **seven staff
areas** behind one sign-in.

**Bolton Central Islamic Society** · Registered charity 1041569 ·
31a Draycott Street, Bolton BL1 8HD

![The Taiyabah Masjid website home page](docs/screenshot-home.jpg)

> **Not live yet.** `robots.txt` blocks every search engine. See
> [Launch day](#launch-day) before that changes.

---

## Start here

Three commands cover almost everything.

```bash
# 1. Change the site
#    Edit index_template.html — NEVER index.html, which is generated.
python3 verify_structure.py && python3 build.py

# 2. Change the database
#    Paste the migration into the Supabase SQL editor, then ALWAYS:
#    paste 011_require_two_step.sql again.

# 3. Prove it still works
cd db/harness && ./run-all.sh
```

If you only remember three things about this repository:

1. **`index.html` is generated.** Editing it works until the next build wipes it.
2. **Re-run `011_require_two_step.sql` after every migration.** It only protects
   the policies that exist at the moment it runs, so a new table arrives
   unprotected until you do.
3. **Pushing to GitHub *is* deploying.** Pages serves this repository's root.
   `_config.yml` is the only thing standing between a file and the public web.

---

## What is in here

| | |
|---|---|
| **The public website** | One document, one template. Prayer times, the appeal, services, madrasah, hall hire, contact. |
| **`account/`** | Where a visitor registers, confirms their email and signs in. |
| **`auth/`** | Where every link in an email from the masjid lands — invitations, password resets, email confirmations. Sets a password, asks for a display name, and enrols the authenticator **before** letting anyone through. |
| **`portals/`** | **The Admin Centre** — where staff land. A rail of the areas this account can open, and a working column: what needs you, four figures, the daily log, and what the site did to itself overnight. One database call, not eight. |
| **`venue/`** | **Hall hire & nikāḥ** — the office's working screen. |
| **`courses/`** | **Adult classes** — who signed up, places left, who is waiting. |
| **`giftaid/`** | **Gift Aid** — the rows to send HMRC, and marking them claimed. |
| **`volunteers/`** | **Food bank volunteers** — who offered, who has been rung. |
| **`access/`** | **User access** — every staff account, what each may do, and whether two-step is on. Invitations are sent from here; **no password is ever typed here, for anybody**. |
| **`newbuild/`** | **The new build page editor** — the appeal figure, what it pays for and the timeline of phases, so the masjid can keep its own page current. |
| **`portal/`** | **Madrasah portal** — for parents, teachers and administrators. |
| **`apply/`** | The madrasah application form, published as a **preview that cannot send**. |

All sign-in areas share one Supabase project, one set of accounts and one
two-factor setup. A person sees only what their role allows.

**Roles.** `admin` sees everything. `teacher` reaches madrasah data and not hall
bookings. `hall_office` reaches hall bookings and provably nothing else.
`parent` is granted by the madrasah portal, not from `access/`.

**As of 14 September 2026 the only role actually granted is `admin`, to three
accounts.** The other three are unused but every policy that honours them is
intact, so separating the duties again is one `grant` — done from `access/`,
with no SQL.

---

## Repository layout

```
index_template.html     THE SOURCE of the website. Edit this.
404_template.html       the source of the 404 page
build.py                substitutes {{PLACEHOLDERS}} -> index.html, 404.html
verify_structure.py     static checks. Run BEFORE build.py, every time.
optimise-images.py      only when a photograph changed
index.html              GENERATED — do not edit
404.html                GENERATED — do not edit

_config.yml             what is in git but NOT on the web. Read it before
                        adding any file to the root.
robots.txt              blocks all crawlers (staging)
robots.live.txt         becomes robots.txt on launch day
sitemap.xml
og-image.jpg            link preview picture — must sit in the web ROOT
favicon.ico             the girih star drawn at 16/32/48, not a shrunk logo
site.webmanifest        name, colours, home-screen icons

account/  auth/  portals/  venue/  courses/  giftaid/  volunteers/
access/   newbuild/  portal/  apply/
                        each: index.html, app.js, config.js. Standalone —
                        NOT built from a template, edit them directly.

img/     photographs, fetched only when their page opens
fonts/   self-hosted woff2 — no Google Fonts, so no visitor IP leaves the UK
build-inputs/  base64 sources inlined at build time

db/            migrations, read-only check scripts, and the SQL test suites
db/harness/    builds a throwaway local Postgres and runs every suite
_test/         browser suites — Playwright against the built pages
supabase/      Edge Functions (notify, invite-user, stripe-webhook) —
               deployed, not served
docs/          setup guides and screenshots — not published
```

**`img/` and `fonts/` sit at the root on purpose.** The repository already
contains a folder committed as `Assets` with a capital A. Adding `assets`
alongside it collides on Windows and macOS, where the filesystem cannot tell
them apart, and GitHub Pages — which is case-sensitive — then 404s every
photograph.

### Building

`verify_structure.py` exists because one missing `</div>` once nested seven
pages inside another. Navigation highlighted correctly, the URL changed, and
nothing rendered. It checks div balance, dead `data-nav` targets, unresolved
anchors, duplicate ids and undefined placeholders. **Exit 0 is clean.**

It also shouts about two things that would otherwise ship silently and cost the
masjid money: a donate link still pointing at the old WordPress site, and a
Stripe link containing `test_`. A test-mode link is a complete, convincing
checkout that takes nothing at all, and nothing on screen tells you.

Fonts and a few always-needed graphics are inlined as data URIs from
`build-inputs/`. **Photographs are not** — they are files under `img/`, marked
`loading="lazy"`, so a browser fetches one only when its page is opened. That
took the home page from 10.3 MB to about 615 KB on first load.

To check a fresh clone can still rebuild the site, make it fail:

```bash
rm index.html 404.html && python3 verify_structure.py && python3 build.py
```

Both should come back byte-identical.

---

## Deploying

**GitHub Pages serves the repository root, so pushing is deploying.** There is
no build step on the server and no staging environment. `_config.yml`'s
`exclude:` list is the entire boundary between "committed" and "on the
internet" — `db/`, `supabase/`, `docs/`, the templates and the build inputs are
all in git and none of them are pages.

Anything not excluded is live the moment it is pushed. That includes stray
notes dropped in the root, which is why `_config.yml` carries patterns like
`READ-ME*.txt` and `DO-THIS*.txt` as well as named files.

---

## The database

Supabase — Postgres in **London**, so booking data never leaves the UK.
Migrations are pasted into the SQL editor in order.

| Migration | What it does |
|---|---|
| `001`–`007` | Foundation: roles, profiles, RLS, audit, hall bookings, the `hall_office` role, retention. In the sister repo. |
| `004_courses` | **Superseded and never applied.** Still in `db/` and replaced by `009_courses`. Do not run it — it is kept only because its header records why courses became data rather than schema. |
| `008_admissions` | Madrasah applications. Applied; the form is still a preview. |
| `009_courses` | Adult courses and sign-ups. Live. |
| `010_nikah_requests` | Nikāḥ date requests. Live. |
| `011_require_two_step` | Makes the database refuse staff data to a session that has not entered its authenticator code. **Re-run after every later migration.** |
| `012_remove_ethnicity` | Drops the ethnicity column. Refuses to run if any value is present. |
| `013_course_admin` | `promote_from_waiting()` — give a waiting person a place without being able to overfill the session. |
| `014_whole_day_hire` | Hall hire by the **day** and by the **number of halls**, not by session and room. Moves every insert-time rule out of CHECK constraints into a trigger. |
| `015_retention` | Purges everything past twelve months, adds `dry_run`, puts both purges on weekly `pg_cron` jobs. |
| `016_deposit_holds_the_date` | Paying the £100 deposit reserves the date. Booking references, a 30-minute hold during checkout, a submit function that refuses a date somebody is already paying for, and `mark_deposit_paid()` for the webhook. |
| `017_paid_is_booked` | **A paid deposit is the confirmation.** Nobody in the office agrees to a date the masjid has already sold. Stores the rate on the booking at the price in force that day, lets the office add extras, tracks the balance. Undoing a paid booking is `cancel_paid_booking()`, which demands a written reason and audits it. |
| `018_nikah_fee_online` | The nikāḥ fee can be paid online — and deliberately **books nothing**. See [Money](#money). |
| `019_weekly_digest` | The Monday summary. `outstanding_summary()` counts what still needs a human; `send_weekly_digest()` posts it on a weekly `pg_cron` job. **Sends nothing when nothing is outstanding.** Adds `app_settings`, readable by nobody but the owner. |
| `020_digest_auth_header` | Fixes the digest: `019` sent no `Authorization` header, so Supabase's gateway refused every send with `401` before the function ever ran. |
| `021_unpaid_is_not_booked` | Refuses the UPDATE that confirms a hall booking nobody has paid for. The portal had a Confirm button that sold a date with no money behind it. |
| `022_donations_and_gift_aid` | Donations and Gift Aid declarations. **APPLIED TO THE DATABASE BUT MISSING FROM THIS REPOSITORY** — see [Known limitations](#known-limitations). |
| `023_foodbank_volunteers` | Food bank volunteer registrations, and the office screen's states: rung, helping, withdrawn. |
| `024_admin_dashboard` | One `admin_dashboard()` returning needs / estate / areas / log / housekeeping. The role check is at the top, so what comes back is decided in the database, not by the browser choosing what to ask for. |
| `025_access_control` | Managing staff accounts without SQL: `staff_list()`, `record_invite()`, `set_person_roles()`, `set_person_active()`, and a `keep_two_admins` **trigger** — so it refuses from the SQL editor too, not just from the screen. |
| `026_invite_contact_details` | A name and a contact number are required on every invitation. Uses the *same* phone rule as `hall_bookings`, deliberately: two ideas of a valid UK number in one database is how you get one that passes on one screen and fails on another. |
| `027_password_reset` | An administrator can **send** a reset. An administrator can never **set** a password — one they chose is one they know, and every later sign-in by that person is then deniable. |
| `028_site_content` | `site_content`, so the new build page's figures and timeline have one source the masjid can edit. Validates strictly about money and leniently about words. Oversubscribed appeals are allowed on purpose. |
| `029_nikah_people` | The particulars of the five people at a nikāḥ. Cascades off the request, so the twelve-month purge already covers it. **Bride and groom are refused under 18** — see [Nikāḥ](#nikāḥ). |

**Read-only scripts, safe in the SQL editor:**
`CHECK_retention.sql` answers what is about to be deleted and whether the jobs
are running. `CHECK_course_registrations.sql` shows what has actually arrived
from the website — it exists because "the sign-up never reached the database"
and "it arrived and nothing read it back" look identical from outside, and that
ambiguity cost an evening. Granting somebody a role used to mean running a
STAFF_give_someone_a_role script; **that script is gone and `access/` does it
now**, with an audit row and without anybody opening the SQL editor.

**Files beginning `_test_` are LOCAL ONLY.** They create roles, reassign
ownership, insert fixtures and delete rows. Never run one against Supabase.

---

## Sign-in and two-step

```
email link  ->  auth/  ->  set password  ->  give a display name  ->
enrol authenticator  ->  portals/  ->  the area you have a role for
```

`auth/` completes every kind of email link, then **enrols the authenticator
before handing over a session**. It used to happen the other way round: staff
reached the portal first and were only challenged when they clicked something,
which reads as a locked door behind an open one.

Two policies are deliberately left at `aal1`: `profiles: read own` and
`user_roles: read own`. The signpost has to know which buttons to show before it
can ask for anything sensitive. Everything with real data behind it is `aal2`.

`011_require_two_step.sql` **refuses to run** while any account holding `admin`,
`hall_office` or `teacher` has no verified authenticator. That is intentional:
it stops you locking a colleague out by tightening the policies before they have
set their phone up.

### Staff accounts and invitations

Everything here used to need somebody running SQL.

**An invitation records the role INTENDED. The role is not granted until the
person has signed in and enrolled their authenticator.** Granting on invite
would mean one slow volunteer blocking every later migration, because `011`
refuses to run while a role-holder has no authenticator.

- **A name, an email and a contact number are required.** An account nobody can
  put a name to and nobody can ring is no use at handover — and this masjid had
  three of them.
- **The number is so somebody can be RUNG.** The sign-in link is **never** sent
  by text. A text from an unrecognised number containing a link asking you to
  sign in is indistinguishable from a phishing message, and sending them teaches
  masjid staff that such a text is normal.
- **The invitation is emailed from the masjid's own address and names the
  administrator who sent it** — the one detail an attacker without the database
  cannot supply. The link is shown on screen whether or not the email went, and
  the page says which happened.
- **`notify` cannot be used as a phishing relay.** The fence is on the LINK, not
  the recipient: it must be a sign-in URL on this project's own Supabase domain.
  The worst a leaked `NOTIFY_SECRET` can send from the masjid's address is a
  genuine Supabase link for this project, and minting one already needs the
  service key.
- **Granting `admin` or `teacher` makes you type the address again.** A tick box
  is too easy to press by accident for something that reaches every payment, or
  children's records.
- **Suspend, never delete**, and never fewer than two administrators — enforced
  by a trigger, so it refuses from the SQL editor too.

---

## Money

Two payment flows share one Stripe webhook, which routes on the reference
prefix — `HH-` to `mark_deposit_paid()`, `NK-` to `mark_nikah_fee_paid()`.

### Hall hire

1. The hirer picks a whole day and how many halls, and agrees the terms.
2. `request_hall_booking()` takes an advisory lock, refuses a date already held
   or taken, and **holds the date for thirty minutes** while they are in Stripe.
   The public calendar closes it immediately.
3. Paying the £100 deposit **confirms the booking**. No office step.
4. The office adds extras (utensils, catering) in `venue/`; the line reads
   `£500 base + £154 extras − £100 deposit = £554 outstanding`.

The base rate is computed and **stored on the booking**, so one taken in March
keeps March's price. An unpaid hold releases itself. A repeated webhook delivery
changes nothing. A payment for a date somebody else took is marked
`refund_due` and logged.

**What is deliberately not stored:** the form no longer asks whether the hirer
is a member. It existed only to choose between two prices, there is now one
rate for everybody, and asking somebody whether they belong to a mosque is
asking about their religion — Article 9 data under UK GDPR. **Do not put the
question back without a second rate to justify it.**

**The website does not work out a total.** Two charges depend on what happens on
the day. Any figure the page produced would be incomplete and argued about at
the door. The rate card is printed as the masjid prints it; the office quotes.

### Nikāḥ

**Nobody under 18.** Since 27 February 2023 it is a criminal offence in England
and Wales to cause a child under 18 to enter a marriage, and the offence
expressly covers a religious ceremony **whether or not it is legally binding** —
a nikāḥ counts, it carries up to seven years, and no force or coercion is
needed. The form refuses a bride or groom under 18 saying why, and
`request_nikah_date` refuses it again. A witness may be any age: the rule is
about the couple, and a test asserts a 17-year-old witness **is** accepted —
without it, a function that refused every age would pass.

**The form asks for five people.** Bridegroom, bride, the bride's
representative and two witnesses: a name, an age, a home address and an
optional occupation, plus which proof-of-address and identity document the
couple can bring. **No document is ever uploaded** — only the name of the one
they say they can bring; the office sees the original in person. An age is
asked for rather than a date of birth, because what the masjid needs to know is
that both parties are adults.

Migration `010` said in its own header that none of this should be collected on
a public form. The masjid was shown that argument on 14 September 2026 and
chose otherwise; `029`'s header records the argument, and what was done to make
the decision survivable. **Four of those five people never filled anything in**,
which is why the declaration says the sender has told them, and the privacy
notice tells anyone named that they can ring the office to be removed.

Paying the fee records money and **does not touch `status`**. This is not an
inconsistency — it is the difference between a diary the site can see and one it
cannot. `hall_availability` is computed from real bookings; the masjid does not
publish its nikāḥ diary, so every day on that calendar looks identical because
as far as the website knows it is. Making nikāḥ behave "consistently" would mean
selling dates the imam may not be free for.

`_test_nikah_fee.sql` section 03 fails the moment `status` moves. **If a future
change makes that section fail, the change is wrong, not the assertion.**

---

## Email

```
stripe-webhook   ─┐
database webhook ─┤
weekly pg_cron   ─┼─► notify ──(SMTP)──► send.one.com:465 ──► the office
invite-user      ─┘                                          or a new member
                                                             of staff
```

`supabase/functions/notify/` sends through **one.com SMTP** — the masjid's own
mail, no third-party sending service. Port 465, implicit TLS, a fresh
connection per message. `messages.ts` holds pure message builders and is tested
with no network at all.

**Subjects must be plain ASCII.** The first live alert arrived showing
`=?utf-8?Q?Nik=c4=81...` because RFC 2047 caps a MIME encoded-word at 75
characters and three non-ASCII characters pushed it to 78. Fixed at the root:
every subject goes through `ascii()`, and a test fails if any character above
U+007E appears in one. Bodies are unaffected — they are HTML with a charset, so
`nikāḥ` renders properly where the masjid's own words matter.

**"ATTENTION REQUIRED" appears only where a human must act** — ring the family,
issue a refund. A paid deposit does not carry it: the payment already did the
work. If everything shouts, nothing does.

**The hirer's home address is never in an email.** Most sensitive thing on the
form, least useful for ringing somebody back. A test fails if it appears.

**The Monday digest** lists only what is still outstanding, and sends nothing
when there is nothing. A weekly email that always arrives becomes furniture
within a month; one that only arrives when something needs doing is still being
read a year later.

**`invite-user` is the only caller that emails an address somebody typed in.**
Everything else emails the office. That is why the fence described under
[Staff accounts and invitations](#staff-accounts-and-invitations) is on the link rather than the
recipient.

The shared notify secret lives in **three places** — the function's
`NOTIFY_SECRET`, the nikāḥ webhook's header, and `app_settings.notify_secret` —
and nothing keeps them in step. **After ever changing it, run
`select public.send_weekly_digest(force => true);` and check
`net._http_response` for a `200`.** That one test exercises all three.

---

## Testing

```bash
cd db/harness && ./run-all.sh          # 16 SQL suites
deno test supabase/functions/notify/messages_test.ts    # 45 assertions
python3 _test/<name>.py                # 11 browser suites
```

`db/harness/` builds a throwaway Postgres, stubs `pg_net` and `pg_cron`
(`net.http_post` records into `net._sent` instead of sending), applies the right
migrations for each suite, and reports one line per suite. It needs the sister
repo `taiyabah-madrasah-db` beside this one for migrations 001–007; override
with `MADRASAH_DB=/path/to/it`.

**Every harness reassigns table ownership to a `NOSUPERUSER NOBYPASSRLS` role
before asserting anything.** Skip that and the tests run as a superuser, which
ignores RLS entirely — and a broken policy set passes.

Three browser-test habits, each bought with a bug:

- **Attach `page.on("pageerror")`.** Console listeners do not catch uncaught
  exceptions. A null reference once killed the whole script block, including
  the navigation binding, and the tests passed.
- **Navigate by clicking real links**, never by calling `showPage()`. That
  function is hoisted, so it works even when the click handler is broken.
- **Assert what is visible**, not what is in the DOM. `text_content` reads
  hidden nodes.

---

## Security

- **Only the anon (publishable) key reaches a browser.** It is safe to commit.
  RLS is the real boundary.
- **The `service_role` key must never appear in this repository, in any file,
  ever.** If GitHub secret scanning blocks a push, do **not** click "Allow
  secret" — cancel, remove the key, and rotate it in Supabase.
- **Roles live in their own table**, never as a column on `profiles`, so nobody
  can promote themselves by updating their own row.
- **Keep two administrators.** Deleting the only admin destroys its roles and
  profile by cascade, and nobody can grant the role back.
- **Secrets live in Supabase**, never in `config.js` or this repository.
  Edge Function secrets are **project-wide**, not per-function.
- **`STRIPE_SECRET_KEY` is not in Supabase.** The webhook needs only
  `STRIPE_WEBHOOK_SECRET`.
- **The SMTP credential is the `noreply@` mailbox only.** It holds no mail, so a
  leak exposes nothing to read.

`admin` is the role to be sparing with: it is the only one that opens roughly
800 children's records — names, dates of birth, and in time medical and SEND
notes, which are special-category data. **The question to revisit annually** is
whether every person holding `admin` is somebody the masjid would be content to
name in an ICO response as having lawful access to every child's file. If the
answer is ever "not quite", grant the narrower role instead.

---

## Content the masjid edits itself

`newbuild/` writes the new build page's appeal figure, what it pays for and the
timeline of phases into `site_content`. The public page **reads it and falls
back to what was built in** — progressive enhancement, so a failed fetch shows
the last published figures rather than an empty bar.

The percentage is computed in exactly one place. The note under the bar says
"kept up to date by the masjid office" and a real *Last updated* date, rather
than a hard-coded month that quietly goes stale.

`set_site_content()` validates strictly about money (a target of zero, a
negative amount, a non-numeric figure and an empty timeline are all refused) and
leniently about words. **An oversubscribed appeal is allowed on purpose** —
raising more than the target is not an error.

This exists for handover. The alternative is the masjid ringing somebody every
time a figure moves.

---

## Things behind a switch

| Feature | Where | Switch | State |
|---|---|---|---|
| Nikāḥ date requests | Marriage page | `REQUESTS_OPEN` | **live** |
| Course sign-ups | Education pages | `REGISTRATION_OPEN` | **live** |
| Pay the nikāḥ fee online | Marriage page | `NIKAH_LINKS` | **hidden** until the masjid's two Stripe Payment Links exist |
| Madrasah application form | `apply/` | `PREVIEW_ONLY` | **preview only** |

**Apply the migration before flipping the switch, never the other way round.**
With the switch on and the table missing, a visitor fills in a form and is
handed an error — worse than an honest "ring the office".

`008` holds children's medical conditions, SEND and EHCP status — Article 9 data
— so the form is published but **cannot send**: `PREVIEW_ONLY` disables the
button and removes the network call. It stays that way until the DPIA is signed.

**Turning a form on is only half the job.** Course sign-ups went live and landed
correctly in `course_registrations` — where no administrator could see them,
because nothing in the site read that table. Whenever a switch is flipped, check
there is somewhere for the data to arrive *and* somewhere for a human to read it
back.

---

## Launch day

In this order:

1. **Decide what happens to the madrasah preview link.** Fine on a staging
   address where crawlers are blocked. Not fine on the public domain. Either
   finish the `008` pre-flight and make it a real Apply button, or remove the
   link. Most likely item to be forgotten.
2. **Transfer the GitHub repository to a masjid-owned organisation** — before
   pointing DNS, not after.
3. Point `taiyabahmasjid.com` at the Pages site. The canonical tag and sitemap
   already name that domain.
4. **Delete `robots.txt` and rename `robots.live.txt` to `robots.txt`.** Miss
   this and the site works perfectly and never appears in Google. Doing it
   *before* step 3 lets Google index the temporary address, after which the two
   compete with each other.
5. Move `PORTAL_URL` in the Edge Function settings to the live address.
6. **Transfer the Supabase project** — transfer, not migrate.

Stripe and the domain are already in the masjid's name. GitHub and Supabase are
not, which is what steps 2 and 6 fix.

---

## Rules learned the hard way

**GRANT and RLS are different things and you need both.** Postgres checks table
privileges *before* it evaluates any policy. Migration 002 shipped with policies
and no grants; every signed-in query failed with `permission denied`.

**A grant is the control; a comment is not.** Migration 003 granted UPDATE on
the whole of `hall_bookings`. This README claimed for months that the office
"may only change status, notes and handled_at", and the code said the same in a
comment. Neither was true — the portal simply never wrote anything else.
Migration 016 made the documentation true. **If you find yourself writing down a
restriction, check that something enforces it.**

**A CHECK constraint must be true forever, not just today.** Three booking rules
were written as CHECK constraints. Postgres re-evaluates every constraint on
UPDATE, so each froze a booking the moment it stopped satisfying it — the office
could not add a note to a booking after the event, and nobody had noticed
because nobody had tried. `NOT VALID` does not help. **If a rule contains
`now()`, or describes what somebody is allowed to do, it is not a constraint.**

**Gold is a background colour, not a text colour.** `--gold` (#C6A24C) reads at
2.3:1 on the cream cards — below the 4.5:1 minimum, and the real reason people
said the site "makes you squint" in September 2026: the small print was not just
small, it was pale. Three text variants exist for exactly this, and every light
surface must use them:

| colouring a background or a border | colouring text on anything light |
|---|---|
| `--gold` | `--gold-ink` (#7A5D14) |
| `--success` | `--success-ink` (#2F5E36) |
| `--danger` | `--danger-ink` (#A0451F) |

Gold on the dark plum is 5.2:1 and stays `--gold`. **Never hand-pick a darker
gold inline** — that had already been done four separate times in four files,
each a slightly different hex, and two of them still failed.

**Type is in `rem`, spacing is in `px`, and that is deliberate.** `body` sets no
`font-size`, so the root is the browser's own 16px and every size on the site is
a fraction of it — a reader who turns their browser text size up actually gets
bigger text. Because no spacing value is in `rem`, changing type sizes moves
words without moving boxes. That makes a scale change safe to do wholesale and
means it must be re-checked for overflow afterwards, since the boxes did not
grow to match. **Nothing on the site may be set below 12px.**

**A grid child will not shrink below its own content.** `min-width:auto` is the
default, so a column whose text got longer or larger pushes past the screen
edge — and since `body` has `overflow-x:hidden`, the page does not scroll to
reveal it. The right-hand edge is simply cut off, and no error appears anywhere.
Put `min-width:0` on grid children.

**A check that only exists in JavaScript does not exist.** The staff portals
asked for an authenticator code for months, and it was checked in the browser
and nowhere else. Anybody with a staff password could have read hall bookings
and admission applications straight from the API. `011` moved the check into the
policies. **If a control is not in the database, assume it is decoration.**

**A count inside a `SECURITY DEFINER` function returns nothing under FORCE.** No
error at all. The fifteen-place cap on adult courses silently counted zero and
handed out unlimited places. `009` and `010` therefore enable RLS but do not
force it, with the reasoning written above the line so nobody "tidies" it.

**Two payment flows that look alike and must not behave alike.** Paying the hall
deposit books the date. Paying the nikāḥ fee books nothing. The difference is
whether the site can see what is free — see [Money](#money).

**Access control for scheduled jobs is by GRANT, not `is_admin()`.** pg_cron
holds no JWT, so `auth.uid()` is null and such a check fails silently every
week.

**`pg_net` is asynchronous.** `net.http_post` queues the request and returns, so
a function calling it cannot know what happened. The digest reported
`{"sent": true}` while every send was being refused at the door. **The truth is
in `net._http_response`** — and the shape of the error body says which layer
rejected it: JSON with a `code` field is Supabase's gateway, a plain string is
our own function.

**A test that cannot fail is worse than no test.** One browser suite installed
its fake Supabase client by intercepting a file that no longer existed, so every
scenario silently began asserting against a sign-in screen — and still printed
PASS. Separately, four SQL suites had stopped running altogether: one had been
dead for a fortnight because a migration made a column NOT NULL and its fixture
did not supply one. The folder still had eleven test files in it the whole time.

The root cause was that the scripts building the test databases lived in a
scratch directory on one machine. **They are in `db/harness/` now.** And the
general rule this bought: **deliberately break the code and check the suite
notices.** Every suite here has been negative-controlled that way.

**Vacuous passes are the failure mode to watch for.** An `eok()` on an UPDATE
that matched zero rows "passes". An `expect_fail()` on an `INSERT … SELECT` that
matched no rows "passes", because inserting nothing raises nothing. And until
September 2026 a `NULL` assertion printed as FAIL but was counted as neither
passed nor failed — a suite could have reported "0 failed" while proving
nothing. **After an `eok` on a write, read the row back.**

---

## Known limitations

- **TWO LIVE TABLES HAVE NO MIGRATION IN THIS REPOSITORY.** `donations` and
  the Gift Aid work (what would be `022`), and `notices`. Both are on the
  production database; neither has a file in `db/`. So **the database cannot be
  rebuilt from a clean clone**, and `_test/giftaid_test.py` fails on one.
  Whoever has those files should commit them; failing that they have to be
  reconstructed from the live schema. This is the single worst thing about the
  repository as it stands, because it is the kind of gap nobody notices until
  the day they need it.
- **One administrator has no authenticator**, so `011_require_two_step.sql`
  cannot be re-run and every later migration is unprotected until it is. Nobody
  can fix this for them — they have to sign in and scan the square. The Admin
  Centre says so on the front page every time anybody signs in.
- **All three administrators have no phone number on file.** One minute each
  from their page under `access/`.
- **The nikāḥ form now holds five people's details, and the DPIA is not done.**
  It was on the list for the madrasah; the nikāḥ form has moved into the same
  territory. The ICO entry and the lawful-basis note should be checked against
  what is actually held.
- **The proof-of-address and ID lists on the nikāḥ form are placeholders** —
  the ordinary UK lists, in one place in `index_template.html`. The masjid
  should replace them with what it actually accepts.
- **The Stripe payment path has never recorded a real payment.** Everything is
  proved against fixtures and a local signature check. One test-mode card
  through the booking form proves the webhook, the database, the office alert
  and the hirer's confirmation together. Until then the masjid is taking
  deposits on trust.
- **Prayer times end 31 December 2026.** The 2027 timetable must be supplied.
- **Adult class fees** are still "ring the office".
- **`MAIL_TO` has one address.** One inbox is a single point of failure the
  first time somebody is on holiday.
- **The madrasah portal is a shell.** No DPIA, no real pupil data. The four
  figures on its console are real *somewhere else*, and the page says so on
  every tile — a screenshot of one tile has to carry the caveat with it.
- **`site_content` has no version history.** A bad edit to the new build page
  is fixed by editing it again, not by rolling back.
- **No content/editor role.** Anything a non-admin should be able to edit needs
  one entry in `GRANTABLE` and one line in the role list.
- **No shop, no mobile app, no in-mosque screens yet.** All separate work; none
  of it blocks the website.

## For the committee

1. **Cancelling a paid booking refunds in full**, while the published terms call
   the deposit non-refundable. The asymmetry is right — it only applies when the
   *masjid* cancels — but it should be minuted.
2. **Retention versus accounting records.** Bookings are deleted six months
   after the date, nikāḥ requests twelve months after they are sent; both now
   carry Stripe payments, and charities are generally expected to keep
   transaction records for six years. Likely answer: keep a minimal financial
   record for six years, delete the personal data on the published schedule.

---

## Credits

Built for Bolton Central Islamic Society. Fraunces, Hanken Grotesk and Amiri are
self-hosted under their open licences. Photographs by the masjid.
