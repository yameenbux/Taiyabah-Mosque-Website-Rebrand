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
| **`courses/`** | **Adult classes** — everything about a class in one place: create one, remove one, open or close sign-ups, rename, change how many places there are, and **every word on its page of the website**. Plus the register: who signed up, places left, who is waiting. |
| **`rates/`** | **Hall hire charges** — the rate card on the hall hire page. The £100 deposit is not editable here and cannot be: it is a fixed Stripe payment link. |
| **`giftaid/`** | **Gift Aid** — the rows to send HMRC, and marking them claimed. |
| **`volunteers/`** | **Food bank volunteers** — who offered, who has been rung. |
| **`collections/`** | **Charity collections** — chanda requests from outside charities. Flags a paid collector and two charities booked for one day. |
| **`collection/`** | A four-line redirect, nothing else. `taiyabahmasjid.com/collection` → `/#collection`, because this link is read out on the phone and the hash is the part people drop. |
| **`access/`** | **User access** — every staff account, what each may do, and whether two-step is on. Invitations are sent from here; **no password is ever typed here, for anybody**. |
| **`newbuild/`** | **The new build page editor** — the appeal figure, what it pays for and the timeline of phases, so the masjid can keep its own page current. |
| **`notices/`** | **Notices** — what the masjid is telling people this week. Write it, attach a poster, publish it. It appears on the front page; nothing is visible to anybody until somebody presses Publish. |
| **`times/`** | **Prayer timetable** — paste a year in, check it, save it as a draft, publish it when it is complete. The masjid changes its own prayer times here; nobody needs a developer and nobody needs to push to GitHub. |
| **`app/`** | **Send a notification** — reaches every phone with the masjid's app on it. Behind a confirmation step, because it is the one thing in this portal that cannot be undone, and it keeps a list of what has been sent and by whom. |
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
access/   newbuild/  portal/  apply/  collections/  times/  notices/
rates/
                        each: index.html, app.js, config.js. Standalone —
                        NOT built from a template, edit them directly.
                        times/, notices/, rates/ and courses/ are the
                        committee's editors — all four described below.

admin/   what those fifteen pages SHARE.
         supabase.js  the vendored database client, once instead of eleven
                    times. Must load BEFORE each page's app.js.
         fonts.css  generated by tools/build_admin_fonts.py from the same
                    source build.py uses, so the staff screens and the public
                    site cannot drift onto different fonts.
         shell.css  the rail, the mobile drawer, and the rule that turns a
         shell.js   centred sign-in card into a working desk once you are
                    through. Mounted by each page from renderApp(identity),
                    which runs only AFTER sign-in.
tools/   scripts that generate committed files. Run them, commit the result.

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

### One rail, on every staff screen — and a desk under it

**The rail was only half of it, and a screenshot is what proved that.** Every
staff screen was built as a sign-in page that grows a working area once you are
through: `.shell` is a two-column grid, `1.03fr 1fr`, with a plum brand panel on
the left carrying a logo, the page title and a sentence of explanation.

Adding the rail narrowed that grid. It did not stop it splitting what was left
between the decorative panel and the actual work. On a 1440px screen the panel
was **forty-two per cent of the width**, repeating the logo, the page name and
the way back — all three of which the rail two inches to its left already
provided — and `/venue/`, the busiest screen in the building, was a small card
marooned in the top-left corner of a mostly empty page.

Every test passed. The rail was drawn on all ten screens at two widths, with
the right rows for each role, the logo in the corner, `aria-current` set,
nothing overflowing. **None of that asks whether the page is a good use of the
screen.**

So after sign-in the grid collapses, the brand panel is removed outright, and
`shell.js` draws the page's name at the top of the desk instead. Identity moved
with it: the avatar, name and email at the top of every card were the same fact
the rail's footer already carried, taking the first inch of the desk — where
the thing somebody came to do should be. The rail's sign-out **clicks the
page's own button** rather than reimplementing signing out, so whatever each
screen does on the way out still happens.

### A class with no rules behind it

`times/` shipped using `.fld`, `.lede` and `.row`, and defined none of them —
it was cloned from `giftaid/`, which has no form on it. **An unstyled `<label>`
is an inline label**, so "Year" and its box and "Paste the timetable" and its
box all sat on one line, three centimetres wide, on the screen the committee
uses to set the masjid's prayer times for a year.

The parser was tested. The save-gating was tested. The rail was checked at two
widths, nothing overflowed the viewport, every control had an accessible name
and a large enough tap target. **Not one of those asks whether a form is
readable**, and only a screenshot found it.

`admin_shell_test.py` now fails on any class that appears in a screen's markup
and in neither its stylesheet nor its script. The script matters: `access/` puts
`inv-r` on a checkbox purely so `app.js` can find it, and the styling comes from
`.inv-role input` on the parent — a check that ignored the JS would cry wolf
there, and a check that cries wolf gets deleted.

### The rail itself

The Admin Centre listed every area a person could open. The nine screens you
reached *from* it had nothing — no logo, no navigation, no way back but the
browser's back button — so the job was always "go to the Admin Centre, read
the rail, click through, do the thing, press back, read the rail again".

That matters because of who is about to be using these screens. The committee
will run this day to day; a volunteer treasurer who opens Gift Aid once a month
should not have to remember how they got there.

`admin/shell.js` puts the same rail on all of them: the masjid's wordmark in
the top-left corner linking back to the Admin Centre, every destination this
account can open, grouped, with the current one marked. Below 940px it becomes
a drawer behind a button in a slim top bar, and the logo stays in the corner.

**It does not join each page's layout.** The rail is `position:fixed` beside
the page and the only thing asked of the page is `padding-left`. Twelve
screens built at different times by different hands did not have to be
restructured for a navigation change, and any of them can be rewritten
tomorrow without the rail noticing.

**It is a convenience, not a permission.** It is JavaScript in the visitor's
browser; hiding a row hides a row. Every area behind these links asks for the
authenticator again, and every table behind those is guarded by row-level
security running in Postgres. The rail's own footer says so, so that nobody
mistakes it for a lock.

`_test/admin_shell_test.py` covers it: every screen links *and mounts* the
shell, the rows match the account's roles, no group is drawn with nothing
under it, every destination is a folder that exists, the current page is
marked, the logo loads and sits in the corner, and the closed drawer is
`visibility:hidden` so Tab cannot walk into a menu nobody can see.

#### Two menus, and then one

The rail above was added to twelve screens and **the Admin Centre was not one
of them** — it is the place the rail links *back* to, so it kept drawing its
own list of areas. Two lists, agreeing by nothing but care.

They stopped agreeing. Notices, Hall hire charges and Prayer timetable were
built in September, given rows in `admin/shell.js`, and never added to the
Admin Centre's copy. So the home page offered **eight** ways in and every
screen you reached offered **eleven**: click any tile and three rows appeared
that had not been on the page you came from. Reported from the masjid as *"when
i click on one, more tabs appear … not straight forward and a tad confusing"* —
which is an exact description of the bug, not a complaint about layout.

Two smaller ones came out of the same root. `volunteers/app.js` admits admin
**or** hall office, the Admin Centre drew the row for both, and the rail said
admin-only — the office could open the screen and could not find it. And
because the home page's list was built from the dashboard payload rather than
from roles, a failed database call left the page saying *"the areas below still
work — open one directly"* above three links out of eleven.

There is one list now, in `admin/shell.js`. `portals/index.html` loads it and
`portals/app.js` calls `AdminShell.visible(roles)`; the `where` links on
**Needs you** and the *See who* link on the housekeeping pane look their
folders up in it rather than repeating them. Roles decide, not the payload, so
a dashboard that will not load no longer removes doors.

Guarded three ways, each proved by deliberately breaking it: `dashboard_test`
compares the home page's rows against `AdminShell.visible()` as **ordered
(heading, row) pairs** — same contents in a different order is still a menu
that changes shape when you click it; `admin_shell_test` refuses a hard-coded
destination or group heading in `portals/app.js`; and `ADMITS` in that file
records, by hand, what roles each screen's own `app.js` lets in, so a row that
is narrower or wider than the door behind it fails.

#### What the headings say

Five groups, and the one the masjid asked for is **not** called Settings:

| Heading | Rows |
|---|---|
| What people have asked for | Hall Hire & Nikāḥ, Charity collections, Adult classes, Food Bank volunteers |
| Money | Gift Aid |
| The madrasah | Madrasah portal |
| Change what the website says | Notices, Hall hire charges, Prayer timetable, The new build page |
| Settings | User access |

The request was for a Settings section at the bottom holding the screens that
amend pages. The grouping is right and the word is not: *settings* means
configuration — who may sign in, where mail goes — and a volunteer looking for
the hall hire prices will search for the word *website*, not the word
*settings*. The label it replaced, "The masjid's own pages", was vague in the
same way, which is how User access and the Madrasah portal ended up filed in
with the page editors. Those two now sit where they belong: one under Settings,
where the twice-a-year jobs are, and one under its own heading, because a
teacher account sees that row and nothing else.

### The phone app, and the seam nobody was watching

The masjid runs two things against **one** Supabase project: this website, and
the phone app (`yameenbux/Taiyabah-Mosque-App`), a PWA whose notifications are
sent by a Cloudflare Worker holding the OneSignal key. They share
`public.notices` — the app's own first migration says so and names this
project by id.

Neither repository's tests can see the other. So on the morning of 15 September,
`040` dropped `publish_notice()` — correctly, it had no admin check in it at
all — and the Worker went on calling it. Because the Worker sends the push
*after* writing the notice row, **the app's send button failed and no
notification went out either**. Every test in both repositories passed
throughout. A janāzah announcement would have gone nowhere, and the only sign
was an error the trustee had no way to interpret.

`_test/app_bridge_test.py` is the check that would have caught it. It reads the
Worker's own source, pulls out every `supaRpc(env, "…")` call by regex, and
fails if this project does not define that function. Not a list kept by hand
here — a list would have been exactly as out of date as the migration was. It
needs a checkout of the app repository and **skips loudly** without one, saying
in full what it did not check, because a cross-repository test that reports
success when it could not see the other repository is the kind of reassurance
that caused this.

It also holds the two vocabularies apart. Notice topics and push topics
*overlap* and are not the same set: `jamaah` is a push audience with no notice
behind it, `ramadan` and `madrasah` are notice topics the app has no switch
for. The test asserts the **difference**, not either list, so it fails if
somebody tidies them into one — which is the tempting and wrong fix the first
time one of them is edited.

#### Sending from the Admin Centre

The Worker authenticates with **one shared password**, and its bearer token's
entire payload is `{"exp": …}` — no subject, no name. Fine for one screen used
by two trustees on a phone. Wrong for the Admin Centre, where a committee
member has already signed in with an account *and* an authenticator, and where
asking for a second shared password would undo the point of both.

So `/app/` calls the `app-notify` Edge Function, which holds the password as a
secret nobody on the committee sees. The order is the design:

1. `app_notification_start()` **with the caller's own token** — which runs
   `verified_admin()` and writes a row whose actor is `auth.uid()`. The Edge
   Function is never told who the sender is and cannot say. A bug there can
   fail to send; it cannot write the wrong person's name against an
   announcement of a death.
2. Send.
3. `app_notification_finish()` with the service key, saying only how it went.

**Nothing in Cloudflare or the app repository changes.** This is server to
server, so there is no `Origin` header and nothing for the Worker's CORS to
reject — `ALLOWED_ORIGIN` does not need the website adding to it.

**`ok` means received, not saved.** The Worker answers HTTP 200 with
`sent: {sent:false, error:…}` when the notice was stored and the push refused.
`app-notify` reads success from `sent.sent` and the bridge test enforces that,
because a screen saying "sent" about something nobody received is worse than
one that says nothing.

The app's own trustee screen stays. A janāzah notice usually needs sending from
a phone, at the masjid, in a hurry — the worst possible moment to be asked for
a desktop sign-in and a six-digit code. That is the fast path; this is the
considered one, and it is the one that leaves a record.

**Setup, once:** `APP_SENDER_URL` and `APP_SENDER_PASSWORD` in *Project
settings → Edge Functions → Secrets*. Until both are set the screen says so
plainly and records nothing — a log entry saying somebody tried to send, when
the site was never configured to send, is a misleading entry in a log that has
to be trustworthy.

### The prayer timetable

**This was a deadline, not a feature request.** The timetable was
`const FULL_2026 = [...]`, 365 rows compiled into the page by `build.py`, and
the page compared `y === 2026` in eleven places. On 1 January 2027 every one
of those goes false: the live countdown reads "Timetable not loaded" and the
year view empties — on the page that is the most common reason anybody opens
this website, at exactly the point Yameen is meant to have stepped back.

It also meant the masjid could not change its own prayer times. Editing one
jamāʿah time meant editing JSON, running two Python scripts and pushing to
GitHub.

Now the year comes from the database, where the committee can edit it, and
**the built-in year is kept as the floor rather than the ceiling**:

1. the page paints from the year compiled into it, immediately
2. it asks `prayer_year(<this year>)` for a better one, in the background
3. it swaps only if what comes back is complete and sane
4. on any failure — offline, slow, malformed, blocked — it keeps what is
   already on the screen and says nothing

Rule 4 is why there is no spinner and no error message. Somebody who wanted
Maghrib does not care that a background request failed; they care that the
number in front of them is right, and it already is.

**A wrong timetable that loads is far worse than a right one that does not
update**, because the visitor cannot tell and will pray at the wrong time. So
an incoming year has to be an array of at least 300 days, every row 14 fields,
every time `HH:MM`, no day listed twice, and it must contain today.
`_test/prayer_times_test.py` feeds it one good year and **seven bad ones** —
truncated, wrong shape, a time that is not a time, a day twice, today missing,
nonsense, and no network at all — and checks the built-in times are still on
screen after each.

`BUILT_IN_YEAR` is derived by `build.py` from the data file's own name, so the
page cannot believe it holds 2027 while carrying 2026's rows.

#### The screen the committee uses — `times/`

`db/039_prayer_times.sql` adds `prayer_times` and `prayer_years`, and four
functions: `prayer_year(int)` (the only one anonymous visitors may call, and
it returns published years only), `prayer_years_list()`, `save_prayer_year()`
and `set_prayer_year_published()`. The table carries three CHECK constraints —
`prayer_times_are_hh_mm`, `prayer_times_in_order`, `prayer_jummah_shape` — so
the database refuses a broken row even if every layer above it is wrong.

`times/` is where a year gets pasted in. **Saving and publishing are two
separate acts**: a save lands as a draft that nobody outside the portal can
see, and it stays a draft until somebody presses Publish, which the screen
will not offer at all unless the year is complete (365 days, 366 in a leap
year). That separation exists because the alternative is a committee member
pasting half a spreadsheet at nine in the evening and the whole masjid getting
the wrong Fajr.

The parser is the part worth testing, because it decides what reaches the
database and what reaches the database is what several hundred people set
their day by. Two faults in it were real and both were found by writing the
wrong spreadsheet on purpose:

- **The Jumuʿah column contains the delimiter.** It is two times with a comma
  between them. A spreadsheet exports that quoted, a person pasting by hand
  does not, and the first parser accepted only the quoted form — so it
  rejected *every Friday and nothing else*. That is the sort of fault that
  gets diagnosed as "the upload is broken" a month later.
- **`01/02/2027` is the first of February.** Reading it the American way
  shifts the whole year by up to eleven months with every individual row still
  looking perfectly valid.

#### The office's spreadsheet, dropped straight in

The timetable lives in a spreadsheet in the masjid office. Getting it onto the
website meant opening it, Save As, choosing CSV, finding the file again and
pasting it — **five chances to do the wrong thing with the one document several
hundred people set their day by**. So the `.xlsx` goes in whole.

**No library, deliberately.** SheetJS is about 900 KB to read a file this
screen opens a few times a year, and this project vendors rather than reaching
for a CDN on principle. An `.xlsx` is a ZIP of XML, and the browser inflates a
stream on its own through `DecompressionStream`, so the whole reader is about
200 lines. Entries are found through the ZIP's central directory rather than by
scanning for local headers, because a local header records a length of zero
when the writer streamed the file — and half the spreadsheet software in the
world streams.

**It is not a shortcut past anything.** The file becomes exactly the CSV
somebody would have pasted, lands in the paste box, and the ordinary Check
runs. Every rule still applies, and a spreadsheet with two columns transposed
is refused by the same order rule that refuses a paste.

Excel stores a time as a fraction of a day and a date as a count of days from
1899-12-30, and converting those wrongly is the one failure that would put a
**plausible-looking wrong time** on the website. So the fixtures are built from
`build-inputs/full2026.json` — the masjid's actual year — written out three
ways (real date and time cells, everything as text, and the year on a second
sheet behind a cover page) and **every one of the 365 days is compared cell by
cell**, not counted. A reader returning 365 rows of the wrong times passes a
count.

#### The Year box used to beat the file

`var year = wantYear || found[0]` meant the number in the Year box won
outright. The box defaults to next year, so uploading or pasting the current
timetable while it still said 2027 filed **365 days of 2026 times as 2027** —
silently. Every row looked right, the day count was right, and the report said
2027 and meant it. The rows carry a month and a day and **no year at all**, so
nothing downstream could have caught it.

The dates in the file are the truth now, and a box that disagrees is a
complaint rather than an override. Found by writing a test that checked which
year came back, rather than only how many rows did.

`_test/timetable_editor_test.py` round-trips the masjid's real 2026 file
through the parser — all 365 days, no complaints — and then feeds it twelve
wrong pastes: a time written `6.36`, two columns transposed, a day listed
twice, two years at once, four columns, a heading row, an empty box and
outright nonsense.

### Notices

**Both ends were built at once, on purpose.** `notices` was a table with one
row in it, nothing on the website read it, and the only way to write to it was
`publish_notice()` — `SECURITY DEFINER`, granted to `service_role`, and **with
no permission check inside it at all**. It was safe only because of the grant.
Nothing called it, so it is dropped rather than guarded: the honest fix for an
unused function with a hole in it is to remove it.

A table the committee can write to that no visitor can read is exactly as
useless as the reverse, and this project has already shipped the reverse —
course sign-ups landed correctly in a table no administrator could see.

`db/040` adds four functions, every one behind `verified_admin()`:
`notices_list`, `save_notice`, `set_notice_published`, `delete_notice`. As with
the timetable, **saving and publishing are two acts**. The column defaults to
`published = true`, which is the wrong default for a screen a committee uses:
somebody half-types a janāzah notice, the phone rings, and a half-written death
notice is on the front page of the masjid's website.

`db/042` adds four storage policies so a verified admin can attach a poster.
`storage.objects` had RLS on and **not one policy**, so the picture field would
have been a box asking a volunteer for an `https://` address with no way on
earth to produce one. Every policy tests `bucket_id = 'notices'` — without that
they would apply to every bucket the project ever gains, including one somebody
creates later for something private.

**Nothing about a notice reaches the public website at the moment, and that is
a decision rather than an omission.** Three designs were built and all three
were rejected: a section of its own under the at-a-glance row, a fifth card in
that row showing the poster, and a band above the hero showing every notice as
text. The editor, the database, the poster uploads and the validation are all
here and working; the website shows none of it until somebody decides how it
should look.

`_test/notices_test.py` checks the public page stays **clean** — no fetch, no
empty section, no stylesheet full of rules for nothing. A half-removed feature
is worse than either keeping it or taking it out, because the next person
cannot tell which it is.

**What the attempts cost, and what they bought.** The band above the hero
measured **CLS 0.5397 on a phone**, against a "good" threshold of 0.1 —
anything revealed above the fold after the page has painted pushes the whole
page down. Starting the request in the `<head>` instead of at the bottom of a
630 KB document took it to **0.0000**, and remembering the band's height in the
browser kept repeat visits at 0.0000 even on a slow reply. Neither is in the
site now, but the measurement is the reason to be careful about ever putting
anything above that hero.

Three other faults came out of the same work, each invisible at a glance:
`[hidden]` does nothing against `.glance-card{display:flex}`, because an author
rule beats the browser's own; `loading="lazy"` on an image inside a
`display:none` element **never loads at all**; and `object-fit:cover` on a
poster slices the sides off a picture whose whole job is to be read.

### Classes the masjid can open and close

`courses` held the name, the capacity and the `is_open` switch that
`register_for_course()` reads, and **nothing could write to it** — no function,
no policy, no screen. The two rows in it were put there by `004` and had never
changed.

**The switch could not be added on its own.** `register_for_course()` raises
when a course is closed, and the website's course list was a hard-coded object
with its own idea of what was open. A volunteer closing the Arabic class in the
portal would have changed nothing a visitor could see; the next person would
have filled in eleven fields and been handed a raw 400 by Postgres. **This is
the third time on this project that half a feature was the whole bug.**

So the website reads `courses_public()` now, and **the upgrade only ever takes
away**. The built-in state is "open", so the worst a failed or slow request can
do is leave up a form the database will decline politely.

`044` exists because `043`'s capacity check read its count outside any lock,
while the comment above it explained at length why holding sixteen names for
fifteen seats matters. **A comment that claims more than the code delivers** is
what this project keeps being bitten by, so the code was changed rather than
the comment softened. What is still open — an administrator saving while a
visitor registers — is written into `044`'s header rather than left to be
discovered.

There is **no delete**, deliberately: `course_registrations` has a foreign key
to `courses`, so deleting a class somebody signed up for either fails or erases
the record of the people who registered.

### Hall hire charges

`045`. The rate card was hard-coded, so £350 becoming £375 meant editing a
template, running two Python scripts and pushing — which in practice meant
ringing Yameen, and in the meantime the website quoted a price the office had
stopped charging. **A figure on screen that turns out to be wrong is worse than
no figure**, because somebody books on the strength of it and then argues
about it.

Prices are stored as TEXT and that is a decision, not laziness: the card says
"£350" on one line and "45p per person" on another, and a numeric column cannot
hold the second. The rule is that a price must contain a digit — enough to stop
a blank or an "ask in the office", loose enough for every shape the masjid
charges in.

`046` is a one-line follow-up found by a subagent reading the grant table:
`check_newbuild()` was executable by `anon` while every other validator on the
project is executable by nobody. Not a hole — it is `immutable`, reads no table
and returns an English sentence about a shape — but **an inconsistent grant is
a question somebody has to answer again at every audit**.

**The £100 deposit is not editable and cannot be.** It is a Stripe Payment Link
with the amount fixed at Stripe; change the number on the page and the button
underneath still takes £100, so the site would be lying about money in the one
place where being wrong costs a dispute rather than an apology. The deposit
paragraph sits OUTSIDE the element the JavaScript replaces, `check_hallhire()`
**refuses a body that so much as mentions a deposit**, and the editor says why.
A boundary that lives only in the user interface lasts until somebody calls the
function directly.

### What a class says

`047`. `043` let the committee open, close, rename and re-size a class but not
add one, and the screen said so: the website held more about a course than the
table did — which sessions it runs, what the experience question asks, the
wording shown when sign-ups are shut — and none of it was anywhere but a
hard-coded object.

**The one thing they still cannot invent is a cohort.** `course_registrations`
has carried `check (cohort = any (array['mens','womens','all']))` since `004`.
A screen that let somebody type a fourth would save happily and then refuse
every sign-up against it with a raw constraint error. The labels are theirs —
"Men's class", "Brothers", "Men's session"; the three keys underneath are not.
Widening that vocabulary is a real option and a bigger change than it looks:
cohort is what `venue/` and `courses/` group by, what the confirmation email
says, and what the waiting list is counted within.

**The two existing class pages are not regenerated from the database**, and
that is deliberate. The tempting design is one path — every page drawn from
the database, the existing two seeded so nothing changes. They are not the same
shape as each other: Arabic's fact strip is Time and Places, the Ghusl
workshop's is Format and Places, with different markup around the value. One
template cannot reproduce both without flattening prose somebody wrote
carefully. So the copy is applied to them **in place**, and a class with no page
in the markup gets a generated one. Two paths, chosen on purpose.

A class is only published **once its copy is complete** — tagline, opening
paragraph, at least one what-to-know row, session labels, the experience
question with at least two answers, and both blurbs. A masthead over an empty
body is worse than no page, so a half-written class is skipped entirely rather
than drawn badly.

#### One screen, after I made it two

I built the class's settings and the class's website copy as two screens —
`courses/` and `classpages/` — because the second form is large. The masjid's
answer: *"two separate tabs for the classes seems overkill when users should be
able to change all info, create and remove classes etc from one place."*

They are right, and the reasoning is worth keeping: **a class is one thing to a
volunteer.** Splitting it by which table the fields happen to live in is an
engineer's boundary, not theirs. It is one screen and one rail row now.

`048` added the delete that `043` had argued against. `043` was right about a
class people have signed up for and wrong about the case that actually comes
up: a class created with a typo five minutes ago, stuck in the list for ever
because "close it" is the only verb. So a class **may** be removed, and only
while nothing references it — not a cascade, because a cascade is how the
record of forty people who signed up disappears during a tidy-up. Withdrawn
registrations count too: a withdrawn registration is still a record that
somebody asked, and the retention policy decides when that goes.

`049` exists because the refusal read **"1 people have signed up for it."** A
subagent reading the migration asked whether that was accepted. It was not — it
was written and not read back. The person reading it is a volunteer who opens
this screen twice a year, and a system that cannot count to one is one they
will not quite trust about anything else either.

#### Two static NodeLists, and what they cost

Adding a page at runtime exposed a pair of bugs that had been latent since the
site was written:

```js
const pages    = document.querySelectorAll('.page');
const navLinks = document.querySelectorAll('[data-nav]');
```

Both are **static** — a snapshot of the document as it was when those lines
ran. A page added afterwards was invisible to `showPage()`, and a link added
afterwards had no click handler at all. Together that meant a class the
committee created would have had a card that did nothing and a page that could
never be shown, **while nothing threw and nothing 404'd**. `pages` is a
function now and navigation is delegated from the document — one listener that
cannot go stale, instead of eighty that can.

#### And the ten minutes the forms did not exist

Lifting the per-course renderer out of the `forEach` that called it left
**nothing calling it on load**. Every registration form on the site then
existed only if the database answered — so with no network, a slow reply or a
500, the Arabic and Ghusl pages had no form on them at all. The site is meant
to work without the database and merely be *better* with it; that had been
quietly inverted, and the only thing that caught it was a test asserting that a
failed request takes nothing away.

### Speed

Measured on 15 September 2026 with a throttled phone profile — 390px viewport,
4x CPU slowdown, cold cache — against a server that gzips like GitHub Pages
does.

| | before | after |
|---|---|---|
| `index.html`, gzipped | 291 KB | **168 KB** |
| `404.html`, gzipped | 96 KB | **1.3 KB** |
| First paint, slow 4G | 1096 ms | **668 ms** |
| First paint, 3G | 3996 ms | **2380 ms** |
| Largest paint, 3G | 12444 ms | **2704 ms** |
| Layout shift (CLS) | 0.001 | 0.001 |
| The twelve staff screens, combined | 2368 KB | **218 KB** |
| The heaviest single staff screen | 200 KB | **23 KB** |

**The change was to stop inlining the fonts.** They were base64'd into the
document, which inflates already-compressed woff2 by a third, puts 123 KB on
the one resource that blocks the first paint, and silently defeats
`unicode-range` — so every visitor to an English and Arabic site was
downloading Central European glyphs nothing here can use. They are files now,
with `preload` on the two that set the first screen.

That introduced a layout shift, which is worth recording because the cause was
not the obvious one. CLS went to 0.0235: the hero dropped 14px two seconds in.
It was not the body font. It was **Amiri**, whose ascent is 112.4% of the em
against about 100% for an ordinary serif, so the Arabic greeting grew when the
real font arrived and pushed the page down under the reader. Fixed with
metric-matched fallback faces — `local()` only, so they download nothing — and
CLS is back to 0.0013.

**The staff screens had two copies of everything.** Each vendored the whole
Supabase client — 207 KB raw, 53 KB gzipped, byte-identical in eleven of them —
*inside the page*, so a committee member opening three screens downloaded the
same library three times. It is `admin/supabase.js` now. Vendoring it at all is
deliberate and stays: no third party gets to see who signs in to the masjid's
portal, and the pages keep working if a CDN is blocked.

**And the same problem again with the fonts.** They are
standalone pages, not built from a template, so each carried its own base64
They are standalone pages, not built from a
template, so each carried its own base64 copy of the same four faces — 162 KB
each, 2 MB across the folder. They share `admin/fonts.css` now, so the browser
fetches each face once for the session.

Between them: **the average staff screen went from about 200 KB gzipped to
about 18 KB**, and everything it does still need is cached after the first
one.

`_test/weight_test.py` holds the line: a gzipped budget for both pages, no
inlined fonts, preloads present and `crossorigin`, every `url()` resolving to a
real file, `font-display` on every face, and a metric-matched fallback for
every family.

**Not done, deliberately.** Amiri can be subset from 74 KB to 35 KB, but the
subset sets the Arabic about 2% tighter — kerning is lost — and that is
Qur'anic and hadith text. It is a decision for the masjid, not a build script.
The command is in the commit that added this section.

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
| `022_donations_and_gift_aid` | Donations and Gift Aid declarations. **RECONSTRUCTED 15 September 2026** from the live schema, having been applied to the database and never committed — the file says so in its own header. RLS is on with *no policies at all*, which is the strongest setting there is: donations are reachable only through the `SECURITY DEFINER` functions, each of which checks `verified_admin()` itself. A donor who did not claim Gift Aid is anonymous by CHECK constraint, not by convention. |
| `023_foodbank_volunteers` | Food bank volunteer registrations, and the office screen's states: rung, helping, withdrawn. |
| `024_admin_dashboard` | One `admin_dashboard()` returning needs / estate / areas / log / housekeeping. The role check is at the top, so what comes back is decided in the database, not by the browser choosing what to ask for. |
| `025_access_control` | Managing staff accounts without SQL: `staff_list()`, `record_invite()`, `set_person_roles()`, `set_person_active()`, and a `keep_two_admins` **trigger** — so it refuses from the SQL editor too, not just from the screen. |
| `026_invite_contact_details` | A name and a contact number are required on every invitation. Uses the *same* phone rule as `hall_bookings`, deliberately: two ideas of a valid UK number in one database is how you get one that passes on one screen and fails on another. |
| `027_password_reset` | An administrator can **send** a reset. An administrator can never **set** a password — one they chose is one they know, and every later sign-in by that person is then deniable. |
| `028_site_content` | `site_content`, so the new build page's figures and timeline have one source the masjid can edit. Validates strictly about money and leniently about words. Oversubscribed appeals are allowed on purpose. |
| `029_nikah_people` | The particulars of the five people at a nikāḥ. Cascades off the request, so the twelve-month purge already covers it. **Bride and groom are refused under 18** — see [Nikāḥ](#nikāḥ). |
| `030_charity_collections` | The chanda collection booking — the online replacement for a paper CHARITY DATA FORM. Stores **which version of the rules** was on screen when it was signed, so changing the rules cannot rewrite what somebody agreed to. The wage/commission answer is `not null` on purpose: *blank* and *no* must never be the same row. |
| `031_dashboard_charity` | Puts collection requests into the Admin Centre's **Needs you** and gives them a tile. 024's three functions, read back out of the catalogue and patched rather than retyped. |
| `032_donate_page_donations` | **Written after the masjid's first real card payment did not appear anywhere.** The donate page sends the purpose as `client_reference_id`; the webhook was already routing on the first three characters of that field, so `sadaqah` matched nothing and no donation was recorded. And the safety net that should have made that visible could not write either — `service_role` had no INSERT on `admin_audit` and no USAGE on its sequence. Adds `donations.purpose`, `record_public_donation()` which mints its own `DN-` reference, and both grants. |
| `033_notify_charity_collections` | **Written after the first charity collection request emailed nobody.** The form, the table, the portal tile and the email text all worked; the database webhook connecting a row appearing to a message being sent had never been created. Creates it by **copying the `notify-nikah` trigger inside the database** — a Supabase webhook stores a `service_role` JWT and the `NOTIFY_SECRET` in plain text in its own definition, so one written out by hand would put both in this repository. |
| `034_views_must_not_bypass_rls` | **Any signed-in account could delete the masjid's screen notices.** `notices` had RLS on with no policies — correct — but `notices_live`, the view in front of it, runs as its owner (`security_invoker` is off by default) and so bypasses that RLS entirely, and it had been given away with `grant all`. A simple view is auto-updatable, so the DELETE went straight through. **A view is a hole in RLS unless you say otherwise; never `grant all` on one.** Takes every privilege except `SELECT` off both views. |
| `036_charity_collection_rate_limit` | **The collection form accepted 8 submissions from one phone and email in a single go.** Harmless yesterday; since `033` every accepted row sends two emails through the same `noreply@` mailbox that carries nikāḥ requests, hall confirmations and donation receipts — so a flood would get that mailbox throttled and stop *all* the masjid's email at once. Three per contact per 24 hours, refused **before** insert so the webhook never fires. |
| `039_prayer_times` | **The masjid's own prayer times, editable by the masjid.** They were a constant compiled into the page — changing a jamāʿah time meant editing JSON, running two scripts and pushing to GitHub — and the file held 2026 and nothing else, so **on 1 January 2027 the countdown and the whole timetable would have stopped**, on the page that is the most common reason anybody opens this site. Adds the table, a public `prayer_year()` the website reads, and admin-only save/publish. A year is published or it is not, and it cannot be published unless it has every day of that year. Times must be `HH:MM` and must run Fajr → sunrise → Zuhr → Asr → Maghrib → Isha on every row, by CHECK — a transposed spreadsheet column is the mistake somebody will actually make and it is invisible in a wall of 365 rows. |
| `038_retention_actually_runs` | **The two most sensitive tables were the two nothing ever purged.** Eight cron jobs ran the retention policy; `purge_old_admission_applications` and `purge_old_charity_collections` existed and were never scheduled — so children's dates of birth, SEND status, allergies and medical conditions, and charity trustees who never contacted the masjid at all, were kept indefinitely while everything else was purged on time. They could not have been scheduled either: both opened with `if not is_admin()`, and pg_cron has no JWT, so a schedule would have failed silently every night. The guard now allows an internal caller and requires `verified_admin()` of a signed-in one — which also matters because one administrator still has no authenticator. Both now run nightly at twelve months. |
| `037_rate_limit_every_public_form` | **Four more forms with no limit at all.** A first pass searching each function for "rate" or "limit" said they were protected; the word that matched was `limit` in unrelated SQL. Searching source for a reassuring word is not a test. Looking for `now() - interval` gave the real answer: nikāḥ, admissions, courses and volunteers had nothing. One generic `rate_limit_by_contact()` trigger, parameterised by column names, applied to all four. It does **not** stop somebody varying both phone and email — nothing in Postgres can, since it cannot see an IP — and if that ever happens the answer is Cloudflare in front of the site, not a lower number here. |
| `035_notify_the_other_three_forms` | **Three more forms that wrote a row and told nobody**, found by asking of every anon-callable function "and then who is told?" Madrasah admissions, course registrations and foodbank volunteers all collected an email address and never used it. Adds their webhooks the same way `033` does, plus `grant select on courses to service_role` so a course key becomes its real name. The madrasah email deliberately carries **nothing at all about a child** — no name, date of birth, school, SEND, EHCP, allergy or medical detail. |
| `050_the_app_can_publish_a_notice_again` | **A production outage this project caused, and did not notice.** `040` dropped `publish_notice()` — rightly; it had no admin check at all and was safe only by its grant. What nobody asked was who else was calling it. The phone app's Cloudflare Worker was, and it sends the push *after* writing the row, so from that morning **pressing "Send notification" on the app's trustee screen failed and no notification went out either**. Restores it with the same name, argument and return shape the Worker expects, service_role only, and validating through `check_notice()` — so the app and the website have one definition of a valid notice and two doors to it. |
| `051_a_push_has_a_sender` | **The one irreversible action in the whole system had no record of who took it.** Every hall booking, Gift Aid claim and role change leaves an `admin_audit` row naming a person; a notification reaching every phone in the congregation left nothing, and its history lived in one browser's `localStorage` — so two trustees could not see each other's sends. Adds `app_notifications` and **two** functions rather than one: `app_notification_start()` runs under the caller's own JWT so `auth.uid()` decides who the sender is, and `app_notification_finish()` is service_role only and may change nothing but how it went. The row is written **before** the send, because a record written afterwards is missing exactly the sends somebody will be trying to reconstruct. |

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
deno test supabase/functions/notify/messages_test.ts    # 66 assertions
python3 _test/<name>.py                # 25 suites
python3 tools/build_admin_fonts.py     # after changing the site's fonts
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

**Two bare-class rules setting `display` is a tie, and the later one wins.**
This has now bitten the same stylesheet three times, and every time it looked
like a design choice rather than a rule that failed: `.cc-yn input` stretched a
checkbox across its row, `.glance-notice` put a white border round a poster,
and `.fb-vol` — declared `inline-flex` early and `inline-block` by a later
tap-target rule — wrapped the food bank arrow onto a line of its own, which the
masjid noticed before any test did. `sweep_test.py` now reads the stylesheet
and fails on any class given two different **layout** displays at the top
level. `none` against anything is left alone: that is the ordinary
hide-by-default, show-in-a-media-query idiom, and the first draft of the check
reported six of those as faults, which is how a check gets deleted.

**A CHECK constraint nobody wrote down is still a CHECK constraint, and CHECKs
are AND.** A table made in the dashboard carries rules that exist only in
`pg_constraint` — no file, nothing to read, nothing to review. Reconstructing
one from a column listing reconstructs half of it, and the half you miss does
not conflict loudly: it silently narrows the table to the intersection of
everything anybody ever added. That is how three of the six notice topics came
to be unreachable while the migration and the validator each looked correct on
their own, and how volunteers were told the heading limit was 120 against a
table that refused 71. **Nullability is part of that truth and is not in
`pg_constraint` at all** — it is in `information_schema.columns` — and `create
table if not exists` will not tell you it did nothing.

**A check that cannot fail is worse than no check.** `_test/timetable_editor_test.py`
had a block asserting the Save button is disabled until the paste has been
checked. It passed. It would have passed with the rule deleted, for two reasons
at once: the listeners were attached inside `mount()`, which runs only after a
real sign-in, so in a test they were never attached at all — and the button is
`disabled` in the markup as well, so reading it showed "disabled" either way.
The only thing that found this was deleting the line and watching the suite
still say ALL PASS. **Every check added here is proved by deliberately breaking
the code it guards**, and this is why: an unproved check is a claim of safety
that has never once been tested, and it is believed. Where a control fails to
bite, the fix is usually to make the code reachable — `times/app.js` now splits
`wireEditor()` out of `mount()` — and then to start from the WRONG state, so a
pass can only come from the code under test.

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

- **`notices` AND `notices_live` HAVE NO MIGRATION IN THIS REPOSITORY.** They
  are on the production database and have no file in `db/`, so that part of the
  schema still cannot be rebuilt from a clean clone. `022` was in the same
  state until 15 September 2026 and has now been reconstructed from the live
  schema — read the header of `db/022_donations_and_gift_aid.sql`, which is
  honest about being a transcription of the end state rather than the original
  migration.

  This is not a filing problem. Everything built in a dashboard rather than in
  a migration is invisible to this folder, and it has now cost four separate
  things: the missing `022` crashed `_test/giftaid_test.py` before it could
  print its failures, so a broken Gift Aid test fixture sat green for days;
  the missing charity-collection webhook meant a live request emailed nobody
  (`033`); three more forms turned out to have the same gap (`035`); and
  `notices_live` was granted away with what was plainly `grant all`, which let
  any signed-in account delete the masjid's screen notices (`034`).
- **Two Supabase advisor findings are deliberate and must not be "fixed".**
  `notices_live` and `hall_availability` are reported at ERROR level as
  SECURITY DEFINER views. That is exactly what they are for: both sit in front
  of tables whose RLS denies everybody, and running as the owner is how the
  website and the prayer-hall screens can read a narrow, published slice.
  Setting `security_invoker = on` would blank the notices and the hall
  calendar. The danger was never the view — it was the `grant all` on it, and
  `034` took that off. Read `034` before touching either.

  `donations`, `notices` and `app_settings` are reported as "RLS enabled, no
  policy". Also deliberate: no policy means no row passes, which is the
  strongest setting available, and each is reached only through
  `SECURITY DEFINER` functions that check `verified_admin()` themselves.
- **Leaked-password protection is off.** Supabase can check new passwords
  against HaveIBeenPwned. It is a switch in Auth settings, it costs nothing,
  and for a charity whose volunteers will reuse passwords it is worth more
  than most of what is in this file. Nobody can turn it on from code — an
  owner has to click it.
- **TWO ABANDONED EDGE FUNCTIONS ARE STILL LIVE AND NOBODY KNOWS THEY EXIST.**
  `quick-processor` and `hyper-service` are both `ACTIVE` on public URLs on the
  Supabase project. They are the same code as each other — the pre-`notify`
  generation of the hall booking email, last touched 27 August 2026 — and they
  have no directory in `supabase/functions/`, no mention anywhere in this
  repository, and nothing calls them: all five database webhooks point at
  `notify`, and nothing in the site's JavaScript names them. They are gated
  only by a shared secret.

  They were found on 15 September by listing the deployed functions and
  comparing against this folder, which is not something anybody had done. A
  public endpoint that still runs, still holds a secret, and appears in no
  document is exactly the thing that is still there in three years. **They
  should almost certainly be deleted** — but deleting production endpoints is
  not something to do on a hunch at one in the morning, so they are written
  down here instead. Check nothing calls them, then remove them.
- **The repository has been caught FOUR times holding an Edge Function that
  did not match production** — twice on `stripe-webhook`, once on `notify`,
  once on `invite-user`. Every time, production was the newer one, so
  deploying from the repo would have silently deleted live behaviour. Once it
  nearly deleted a whole email that donors receive.

  **Read what is deployed before you deploy over it**, with
  `mcp__Supabase__get_edge_function` or `supabase functions download`. Do not
  trust a comment that claims a file is current: one in `stripe-webhook`
  claimed to match "version 16" while production ran 18, and that line has
  been removed for exactly that reason.
- **Every database webhook exists only in the database.** A Supabase webhook
  stores a `service_role` JWT and the `NOTIFY_SECRET` in plain text inside its
  own trigger definition, so none of them can be committed. `033` and `035`
  create them by *copying* the working one inside Postgres, which is the
  closest thing to a reviewable record that is safe to keep. **If you add a
  table that should email somebody, the webhook is a separate job and nothing
  will remind you.**
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
