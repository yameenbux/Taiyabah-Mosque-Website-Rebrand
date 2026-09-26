# The Pupils screen, and a page for one pupil

26 September 2026. Design agreed with Yameen in conversation; this is the
record of what was decided and why, before any code is written.

---

## Why

The roll went live this morning with 552 children on it. Looked at from a
screenshot at that size rather than from the suite's two-pupil fixture, it does
not hold up:

| measured | |
|---|---|
| desk | **28.6 screens** of continuous scrolling |
| phone | **37.9 screens** |
| column headers | scroll away entirely; by row 300 nothing says which column is the class |
| figure tiles | wrap to two rows and push the roll below the fold |
| sibling panel | renders all 56 pairs between the figures and the list |
| first screen, phone | contains **no pupil at all** — heading, seven tiles, sibling panel |

None of that is a failing assertion, and none of it was visible until
`_test/pupils_shots.py` existed. The suite's fixture holds two pupils; every
one of these problems needs twenty to appear.

The brief is the old student system the register came out of: a paginated list
with per-row actions, and a page per student. Copying its *shape* is right.
Copying it wholesale is not, and the section "What is deliberately not being
copied" says which parts and why.

## What success looks like

A teacher can find one child in a few seconds on a phone in a corridor. An
administrator can narrow the roll to a class, a teacher, boys or girls, or a
status, and take a list away as a file. Opening a child shows everything about
them on one page, and the system records that it was opened.

---

## 1. Routing — a real page, not a panel

No screen in this portal reads a query string today, so this establishes the
first deep-linked record page and Staff and Families will copy it.

**Decision: `portal/pupil/?id=<uuid>`** — its own folder, its own generator
(`tools/build_pupil_page.py`), like every other screen. Back button works,
refresh keeps you on the child, and the address can be passed between two
members of staff who are both signed in.

The alternative considered was hash routing inside the existing roll
(`portal/pupils/#p=<uuid>`). Rejected: the pupil page would share a document
with the list, so a phone loads 552 rows to show one child, and the browser
cannot tell the two pages apart in history or in a tab title.

### The URL carries a pupil id, and that is safe, but not for the obvious reason

The UUID is opaque and unguessable, but **the URL is not the access control.**
`madrasah_pupil_one()` is: it requires `verified_madrasah()`, it requires
two-step, and it writes an audit row. Pasting the address without a session
produces the sign-in panel and nothing else. This is worth stating because the
temptation with a deep link is to treat the hard-to-guess id as the protection.

**The page title is "Pupil — Taiyabah Madrasah" and never the child's name.**
Browser history on a shared office computer is a real, cheap leak; the name
belongs on the page, not in a list of visited pages. The `<h1>` carries the
name as normal.

---

## 2. The roll

### Pagination

**Over the rendered rows, not over the data.** One `madrasah_roll()` call as
now — it returns marks only and is already proven — and the page renders a
slice of the filtered result.

This is better than the system being copied, which paginates server-side and
therefore has to round-trip to find a child on page 4. Here, search and every
filter see all 552 and pagination applies to what they leave, so the count can
honestly read **"Showing 1–50 of 137 matching"**.

Per page: 25 / 50 / 100, defaulting to 50. (Yameen said 70; read as
illustrative. If 70 is meant literally it is a one-line change.)

Page controls above and below the table. The page resets to 1 whenever a
filter or the search text changes — otherwise filtering to 12 results while on
page 4 shows an empty table, which reads as "no results".

### Things the screenshots exposed, not asked for

- **Sticky column headers.** `position: sticky` on the header row.
- **Sortable columns** — reference, name, age, class. Click to sort, click
  again to reverse, and the sort survives a filter change.
- **The figure tiles become one row** on the desk and a single horizontally
  scrollable strip on the phone, so the first screen contains pupils.

### Filters

Agreed: **class, teacher, status, and boys/girls.** Age and school-year
filters were offered and declined.

The existing figure tiles (no contact / no class / no teacher / date looks
wrong / no fee rate) keep their present behaviour and continue to combine with
the other filters, as they already do in `matches()`.

**Boys/girls is a filter with "Everyone" as the default, not two tabs.** The
data supports a split cleanly — 236 boys, 315 girls, and not one pupil sits in
a class of the other side — but **one pupil has no gender recorded**, so
236 + 315 is 551, not 552, and 13 more are in the two mixed Play and Pray
classes. Two tabs would silently swallow that child. A filter defaulting to
everyone cannot: the total on screen always reconciles.

Filtering is on the pupil's own `gender`, not the class's `section`. Where a
pupil has no gender they appear under "Everyone" only, and the Boys and Girls
counts are shown as "236 of 552" rather than as a bare number, so the missing
one is arithmetic anybody can see.

### Per-row actions

A dropdown per row containing **only what exists**: Open record, Edit, Fees,
Family, Archive.

Register, Incidents, Class History and Portal Login — four of the nine in the
old system — are `soon: true` in the rail or do not exist at all. They are
left out and added when their screens are built, which is the rule `nav.js`
already states for the rail. A menu that is half dead teaches people not to
open it.

### The sibling suggestions

The section goes, replaced by **one line: "56 pairs of children might be
siblings — review"**, which opens the list in place and will link to Families
when that screen exists.

Recorded because it was argued about: removing them entirely was the original
request, on the reasoning that admins can manage families from the Families
screen. **That screen does not exist** — `portal/families/` is not there and
`md-families` is still `soon: true`. Deleting the panel outright would leave
the rows in the database with nothing in the interface showing them, and the
finding — 56 pairs of children share a surname and an address and nobody has
checked whether they are one family — would stop being visible to anyone. That
matters beyond tidiness: families drive sibling discounts in the fees system,
so wrong families are wrong money, and knowing who is related to whom matters
when deciding who may collect a child.

One line keeps the finding and gets it off the roll, which was the legitimate
complaint.

---

## 3. The pupil page

Tabs: **Details · Contacts & family · Classes · Fees · Notes.**

**Medical and allergy information stays on Details, visible on open.** This
reverses something said while the question was being asked, where tabs were
described as usefully keeping the medical note off the opening screen. That
was wrong. A medical note and an allergy are safety information and a teacher
needs them the moment the page opens, not two clicks in. The old system puts
Medical in a red box near the top and it is right to.

Details carries: name, reference, photo slot, class and teacher, age and date
of birth, gender, family, contact, and the medical/allergy/SEND box.

**One audit row per pupil opened, written on load, not one per tab.** Opening
the child is the auditable act; the tabs are a display convenience over data
already fetched. `madrasah_pupil_one()` keeps its existing contract and must
remain **not `stable`** — a stable call may be elided by the planner and the
audit row lost with it.

### What is deliberately not being copied

The old profile page's "Custom Fields" block, which in the supplied screenshot
shows `Allergy:` twice with both blank, `Ethnicity:` blank, and `NA` six
times. That is the export artefact normalised away during the import — the one
that was about to mark 537 of 552 children as SEND because the spreadsheet
writes "NA" as a value. Fields with nothing in them say "not recorded" once,
or do not appear.

Ethnicity has no column and is not being added. It was blank for all 552 in
the sound export, unreadable in the damaged one, and is Article 9 data; an
empty column is an invitation to fill it.

---

## 4. Status

A `status` column on `madrasah_pupils`: **on roll / on hold / suspended /
left**, defaulting to on roll, with a constraint that status is `left` exactly
when `left_on` is set, so the two can never disagree.

Backfill: every existing row is derived, not defaulted — `left` where
`left_on` is set, `on_roll` otherwise. On today's data that is 552 on roll and
0 left, and the migration asserts exactly that rather than trusting the
default to have done the right thing.

The old system's eleven statuses are not copied. Waiting List, Accepted, On
Hold at application time and Rejected are **application** states, and this
system has an Admissions section that owns them — the old system needs them on
the student table only because it keeps applicants and pupils together. Nine of
the eleven would sit permanently at zero.

---

## 5. Export

The highest-risk feature in the portal: a file containing children's details
that leaves the system, lands in a Downloads folder, and gets emailed.

**Two exports.**

| | who | columns |
|---|---|---|
| **Register list** | any signed-in madrasah staff | reference, name, class, teacher |
| **Full list** | administrators only | adds date of birth, gender, address, postcode, family, guardian name and contact |

**Neither includes medical, allergies, SEND or EHCP.** Adding them was offered
and declined; if it is ever wanted, the DPIA needs updating first.

### `madrasah_roll_export(p_detail boolean, p_filter jsonb)`

- `p_detail = false` requires `verified_madrasah()`; `true` requires
  `verified_admin()`.
- **Writes an audit row on every call**, recording who, when, the detail level,
  how many rows left the system, and the filter in force — so "exported all
  552" and "exported one class of 12" are different entries. This is the event
  a subject access request or an ICO enquiry asks about.
- **Must not be `stable`,** for the same reason as `madrasah_pupil_one()`.
- The CSV is assembled in the browser from the returned rows. The function
  returns data; it does not build files.

The filter in force at the time is passed and applied server-side, so the file
matches what is on screen rather than silently exporting everything.

`p_filter` is a fixed shape, not free-form — `{class_id, teacher_id, status,
gender}`, each optional. Anything else in the object is ignored rather than
interpreted. A function that accepts arbitrary filter structure from the
browser and applies it to a query is how an export becomes a way of asking the
database questions it was not meant to answer.

The free-text search box is **not** part of `p_filter`. It narrows what is
drawn on screen; an export takes what the structured filters select. Otherwise
the file's contents depend on a string nobody recorded, and the audit row
saying "exported 137 rows" could not be reproduced.

---

## 6. A guard that was assumed and is not there

While designing the export, the claim that `madrasah_roll()` is protected from
learning detail columns was checked against the live catalogue. **It is not.**

The assertion exists inside migration 077 and ran once, at migration time. It
is not a database object, nothing re-runs it, and nothing prevents a detail
column being added to `madrasah_roll()` tomorrow. The project note written this
morning states the opposite and is wrong; it is corrected as part of this work.

The browser suites cannot close this, because `_test/*.py` run against a local
server with stubs and never touch Supabase — deliberately.

**Fix: add the assertion to `health_check()`,** which is a live function that
already runs a list of named checks and reports which fail. It reads
`madrasah_roll`'s source from `pg_proc` and fails the check if it names
`medical`, `allergies`, `send_detail`, `ehcp_detail`, `address` or `notes`.
Same for `madrasah_roll_export` at the non-detail level. A check that runs
every time health is read is a guard; a check that ran once during a migration
is a historical note.

---

## 7. Testing

**`_test/pupils_test.py` extends** — pagination arithmetic (the count line
reconciles with the rows drawn), page reset on filter change, sort order and
reversal, sticky header, each new filter alone and combined, the boys/girls
counts reconciling to 552 including the child with no gender, the Actions menu
containing no disabled entry, and the sibling line replacing the section.

**`_test/pupil_page_test.py` is new** — the tabs, medical visible on open
without a click, one audit call per page load and not one per tab, the title
carrying no name, a bad id failing gracefully, and a signed-out visitor with a
valid id getting the sign-in panel and no data.

**Export is tested for what it must not contain** as well as what it must: the
register-level file must not carry a date of birth or an address, and neither
file may carry a medical note or an allergy. The audit row is asserted, not
assumed.

**`_test/pupils_shots.py` runs at both widths** at 552 rows, and the scroll
depth is the acceptance figure: the roll must open in roughly one screen with
pagination, not 28.

Every new check is watched failing before it is trusted, as the last round
was — the four date-of-birth checks were run against a deliberately broken
build first, and two of them only reported properly after being rewritten not
to hang.

---

## Sequencing — this is three pieces, not one

Reviewing the above as a single implementation plan, it is too large for one:
it touches the roll's rendering, adds a whole new screen, and changes the
database. Three plans, in this order, each finishing green and shippable on
its own:

**One — the roll.** Pagination, sticky headers, sorting, the class / teacher /
boys-girls filters, the Actions menu, the sibling line, the phone layout.
Touches `tools/pupils_module.js`, `portal/pupils/pupils.css`, the generator and
`_test/pupils_test.py`. No database change at all, so it can ship the day it is
done and it fixes the 28-screen problem on its own.

**Two — the pupil page.** `portal/pupil/`, its generator, the tabs, and
`_test/pupil_page_test.py`. Depends on One only for the Actions menu entry that
links to it.

**Three — status, export, and the health-check guard.** The one migration, the
two export functions, the status filter on the roll, and the export button.
Last because it is the only part that changes the database, and because the
guard in section 6 should land with the export that made it necessary.

If only one gets built, it should be One: the measured problem is the roll.

## Out of scope

- The Families screen. Named here because the sibling line points at it and
  because the original reasoning assumed it exists.
- Register, Incidents, Class History, Portal Login.
- Photographs. The old system has them; there is no storage bucket, no consent
  record and no retention rule for children's photographs, and adding all three
  is its own piece of work with its own DPIA question.
- Ethnicity, permanently.
