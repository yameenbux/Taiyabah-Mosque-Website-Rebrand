# Before you press go live

**Written 27 September 2026, updated 28 September 2026.** Every figure here
was read from production or from the repository on the date next to it, not
remembered. Where something could only be checked by a person, it says so and
says who.

Ordered by **what breaks if you skip it**, not by how hard it is.

**28 September — the register is built.** The register itself, the
attendance history behind each mark, the missed-register lists (both the
office's and each teacher's own), the teacher's own prompt on their landing
page, the Today item, and the Monday digest's register section — all built,
all tested, all read against the live database as both an office account and
a teacher account. **None of it can be used yet.** Nothing about attendance
works — not for a single class, not for a single evening — until **B3 and
B4** below are done. Read those two before anything else in this document.
They are no longer two items on a list; they are the gate every other line
about the register sits behind.

---

## A. The site is wrong until these are done

### A1. The domain does not match what the site says about itself

| | |
|---|---|
| `CNAME` says | `taiyabahwebsite.ysbdesigns.uk` |
| The site says, in 17 places | `taiyabahmasjid.com` |
| `sitemap.xml` says | `https://www.taiyabahmasjid.com` |
| **The privacy notice printed for parents says** | `taiyabahmasjid.com/madrasah-privacy` |

That last one is the sharp end. Several hundred parents are about to be given
an address that does not resolve.

**Do:** point `taiyabahmasjid.com` at GitHub Pages, change `CNAME` to match,
and confirm `https://taiyabahmasjid.com/madrasah-privacy/` loads before a
single letter goes out. Decide `www.` or bare and make all three agree —
`sitemap.xml` currently says `www.`, the notice says bare.

### A2. Search engines are still blocked

`robots.txt` is the staging one and blocks everything. `robots.live.txt` is
the real one, and its first line says: *rename this file to robots.txt once
taiyabahmasjid.com points at this site.*

**Do:** after A1, `git mv robots.live.txt robots.txt`. Not before — you do not
want the staging domain indexed.

### A3. Delete the test application

`TM-26-00014`, parent surname **"DELETE THIS"**, status `new`. I submitted it
to prove the emails work. It is sitting in the Applications screen and on the
Today screen as a family waiting to hear.

**Do:** open it in the portal and delete or decline it.

---

## B. Legal. The masjid is exposed until these are done

### B1. Re-sign the privacy notice at v1.7, and record an Article 35(11) review

The signed v1.1 said the madrasah held no date of birth, address, telephone
number or medical information. The register import made all four false. The
published page is now **v1.7** and true; the signed document in the masjid's
files is still v1.1.

**What changed between v1.6 and v1.7, in one line:** the notice now says the
madrasah keeps a teacher's notes on how a child is getting on (including a
working note the family is never shown, and why) and the conversations a family
has with the office, and no longer says it holds nothing about progress.

**Do:** sign v1.7, and note on the DPIA that five things have widened the
scope you already signed, which is what Article 35(11) asks you to review:

1. the register import (dates of birth, addresses, telephone numbers, medical
   and allergy notes, SEND marks),
2. the attendance register — a daily record of where a child was,
3. **teachers reading their own class**, including the medical note and who to
   ring, and being able to raise a safeguarding concern,
4. **the register's own history** — what an attendance mark said before it was
   corrected and who corrected it, the date a child was put in their class,
   and a system guess, made from the old system's records, that two children
   might be siblings, sitting there unconfirmed until a member of staff
   checks it,
5. **teachers' notes on how a child is getting on** — what a child worked on,
   a note written for the family, and a **teacher's own working note that the
   family is not shown** — and **written conversations between a family and
   the office**, which are a record about the family and are kept with it.

Version 1.7 of the page already says all five. The signature is what is
missing, and a notice the controller has not signed is a draft. **Nothing here
has been signed.**

*Drift check: `madrasah_notice_matches_schema()` runs inside `health_check()`
and fails if the schema holds something the notice does not describe. Nobody
has to remember this one — it is how item 4 above was found at all.
`db/105` made that check discover its own tables instead of being told them,
and what it found sitting undescribed was 554 real rows recording when a
child joined their class and 56 real rows guessing at brothers and sisters.
`db/106` describes both.*

**Why v1.6 exists, and why it is not v1.5.** Items 1–3 were true at v1.5, and
v1.5 was never signed. Before it could be, the same drift check kept
finding more: the attendance-history table, the class-join date, the sibling
guess — real data, held and undescribed, the moment the check was made to
look for its own tables rather than be told them. Re-signing v1.5 and then
immediately reissuing v1.6 a day later would have meant two signatures where
one does the job; v1.6 was to be the version that got signed, until progress
notes and messages were built the next day (see B4a) and made v1.7 the one.
Nothing was signed at v1.6, so nothing is superseded.

**And why it is not v1.4 — the reason this keeps happening.** The published
v1.4 contradicted itself. It listed the attendance register under what the
madrasah holds, and three paragraphs later — under the heading *"What we do
NOT hold about your child"* — still carried the sentence written at v1.2:
*"We are building an attendance register. When it starts being used we will
issue a new version of this notice and tell you before the first mark is
made."* Both sentences were in the document about to go to 330 families.

The schema guard could not catch it. It compares the notice against the
**columns**, and by that test v1.4 was correct. **Prose contradicting other
prose is invisible to a check that reads the schema.** Fixed at v1.5 by
removing the stale sentence. The same blind spot applies to the "This notice
changed" banner at the top of the page: nothing checks that it names the
right change, only that the words underneath match the schema — so v1.6's
banner was written, and read back, by a person, on purpose. **v1.7's was too:**
the banner leads with progress notes and messages, keeps the earlier changes
under a line saying they are earlier, and the built page was read top to
bottom afterwards. Doing it found three more sentences the schema guard could
not see — "Administrators … and nobody else", "we did not add anything to it",
and the attendance line's "nobody outside the madrasah sees it" — each made
untrue by a teacher's notes and a parent's login existing. Nothing extra to
sign for v1.4, because v1.4 had not been signed either.

### B2. Name the Data Protection Lead

Article 13(1)(a) requires the controller's contact details. The page currently
points at the masjid office and `info@taiyabahmasjid.com`, which is a real
route a parent can use — so the notice is not defective — but a named person
is better and the DPIA lists it as an open action.

**Do:** decide who, then rebuild the page:

```
DP_LEAD_NAME="..." DP_LEAD_EMAIL="..." DP_LEAD_PHONE="..." \
ARTICLE_9_CONDITION=both python3 tools/build_privacy_page.py
```

Use the masjid's own address and number, not a personal one — it is a public
web page.

### B3 and B4 — read this first. These two are now the whole gate.

**28 September, read live:** 330 families, 0 told. `attendance_permitted()`
returns `permitted: false`.

The register, the attendance history, both missed-register lists, the
teacher's prompt, the Today item and the Monday digest are all built and all
work. **None of that matters until these two are done.** They are not two
items among many any more — they are the single fact that everything else
about attendance hangs from:

- **A teacher who signs in sees a locked page.** Their own class list is
  still there, but the gate above it says why marking is shut, in words a
  volunteer can act on, not "not available".
- **The office sees no missed-register list on screen.** The Register screen's
  missing-panel is hidden while the gate is shut — deliberately, so there is
  never a second, differently-worded version of the same fact on screen.
  The *function* `registers_missing()` is not hidden: it still answers any
  office caller while the gate is shut, and it is the panel, not the function,
  that stands down. There is nothing to chase because nothing could have been
  taken.
- **The Monday digest reports the families, not the registers.** Told 330
  families and 0 registers missed would read as forty-four teachers doing
  their job; the digest knows the difference (`db/109`) and names the
  outstanding families instead, addressed to the office, not the teachers.

Nothing above is a defect. It is the gate working exactly as designed. It
stays true until B3 and B4 are both done.

### B3. Tell parents the notice exists — all 330 families

**This is the one with the most consequences attached.** Publishing a notice
is half the duty; the ICO's position is that you must take an active step.

Until a family is recorded as told:

- **fee reminders will not go to them.** Enforced in the database, per family.
- Today shows *330 families have not been told*.
- **nothing about the register works for anyone** — see above.

**Do:** Notices to parents → Choose every family shown → Print 330 letters →
hand them out → Record as told. The date goes against your name, and that
record is the evidence.

### B4. Tell parents again before the first register is marked

The notice promises: *we will tell you before the first mark is made, not
afterwards.* The database enforces it — `save_register_draft()` (the function
behind both Save and Hand-in) refuses until every family with a child on the
roll is recorded as told under `kind = 'attendance_notice'`, and rechecks this
on every save, not only once at page-load. The Register screen shows the
count and a way to go and do it.

You can do B3 and B4 in one pass with one letter, but they are **two separate
records** and both must exist.

**What happens on the evening the gate opens (`db/117`).** A register is only
"missed" from the day it could first have been taken. Without that floor, the
first evening after B3 and B4 are done would have shown every class as missed
for the whole fortnight before the register existed: every due evening of
the 14-day window for each of the 44 active classes, an office list and a Monday digest naming teachers for
evenings on which marking was forbidden, and an "outstanding" count on every
teacher's landing page from their first sign-in. The floor is
*derived*, not stored: the earliest date on which every household that then
had a child on the roll had been told (`kind = 'attendance_notice'`). A family
who enrols later, or is told again, does not move it. It applies in
`registers_missing()`, `registers_missing_count()`,
`my_registers_outstanding()`, the Today item and the Monday digest, and when it
swallows the whole window the screen says so in words ("the register opened
on ...; nothing before that could have been taken") rather than showing a bare
zero. Its answer is only known once B3 and B4 are complete; until then it is
unset and the gate is shut anyway.

### B4a. Progress notes: the notice said the madrasah holds none

**Notice work: satisfied by `db/128` and v1.7. What remains is a person's.**

`db/127` built the teacher's Progress notes screen and the parent's Progress
screen while the notice (v1.6) listed *"anything about your child's progress or
ability"* under **what the madrasah does not hold**, and
`madrasah_notice_matches_schema()` listed `madrasah_progress` as an absent
table. The table was empty, so `health_check()` was green; **the first entry a
real teacher saved would have made the notice false and turned
`notice_matches_the_schema` red** - proved twice on 29 September against a
rolled-back row, and that is the guard doing its job.

What was done, all on 29 September:

- `tools/build_privacy_page.py`: `madrasah_progress` left `NOT_HELD` (that
  line is now "a grade, a mark or a ranking", which is still true) and joined
  `WHAT_WE_HOLD`, saying who reads it, that a teacher may keep a note the
  family is never shown and why, and that it is deleted with the child. The
  messages are described too.
- `db/128`: the progress columns and the four message columns added to
  `described`, **and `madrasah_progress` removed from `absent_tables`** -
  describing the columns alone would have left the guard red forever on the
  "you said this was not held" half. Applied to production and proved: one
  rolled-back progress row, before `db/128` `ok = false`, after `ok = true`.
- Version 1.7 published; `tools/notices_module.js` moved to 1.7 so the Notices
  screen records families against the right version (CHECK 9).

**Still to do, and not done by any of the above:** sign v1.7 (B1) and **tell
parents (B3)** - the notice says parents are told before any of this is used.
Do not tell a teacher the Progress screen exists, and do not give a parent a
login, until that has happened.

### B5. Turn on leaked-password protection

Supabase reports it disabled. It is one switch in Auth settings and it stops
staff choosing a password that is already in a breach corpus. These accounts
open 552 children's records.

### B6. A real family's surname was in the public repository, and still is in its history

Found 28 September in `db/080_families_screen_and_a_wider_guard.sql`, in the
comment block headed **"NO CHILD IS NAMED IN THIS FILE"** — used as an example
in the paragraph arguing that a name beside an address is the worst artefact
this system could produce. It was committed on 27 September and the repository
is public, so it has been readable by anyone since then.

The file now carries an invented surname and a note saying what happened.
**That does not undo it.** Git keeps every earlier version, so the name is
still in the history of a public repository and will stay there until the
history is rewritten — which is a decision for the masjid, not for me, because
it rewrites every commit hash and anyone holding a clone keeps the old one.

**Do:** decide whether this needs recording under the breach procedure. One
family surname, no first name, no address, no child named alongside it — but
it is personal data about an identifiable household, it was public for a day,
and the assessment is the controller's to make, not a developer's.

Three further disclosures of the same shape are listed in **D** and need the
same judgement. Two are working-transcript only. **The third is not** — on 27
and 28 September a failed CHECK on `madrasah_pupils` printed a real child's
whole row, medical notes and address included, into Postgres's error DETAIL,
and with `log_min_error_statement = error` that reaches the **Supabase-retained
server log**. Both times the transaction rolled back; the log entry does not
roll back with it. Neither log was read afterwards, because reading it would be
a second disclosure — so how long Supabase keeps it, and whether anything needs
doing about it, is a question for the controller and for Supabase's retention
settings, not something a developer should answer by going and looking.

---

## C. Only a person can check these

### C1. Sign in as a teacher yourself before you hand out a single slip

> **28 September — this was done, and it found that every login was dead.**
>
> All 40 teacher accounts returned *"Database error querying schema"* at the
> sign-in page. `create_teacher_login()` had left four columns NULL in
> `auth.users` that Supabase's auth service reads as text, so it failed on the
> row before it ever checked the password. **Not one of the 40 slips would have
> worked.** Fixed in `db/094`: all rows backfilled, the function patched, and
> `auth_rows_readable()` added to `health_check()` so the next one is caught by
> the system rather than by a teacher standing at a screen.
>
> **Still do the walkthrough below.** The fault is fixed; the journey past the
> sign-in box — forced password change, landing on your classes, opening a
> child — has still not been walked by a person.

**Nothing here had been signed in to over the web.** The 40 teacher accounts
were created inside the database, and this machine has no network route to
Supabase, so no password had ever been typed into the login box. All 40 showed
`must_change_password = true`, which is exactly what you would expect whether
the accounts work perfectly or do not work at all — **the figure could not tell
the two apart, and they did not work.**

What has been proved is the part that matters most and is hardest to check by
hand: a real teacher account cannot reach anything outside its own classes.
Tested as one of them — the whole roll refused, every family refused, both
exports refused, the applications refused, the staff list refused, another
class refused, a child in another class refused. Their own class opens, the
medical note reaches the teacher who teaches that child, and opening it is
audited with a name.

What has **not** been proved is that the front door opens.

**Do:** take one slip, go to the madrasah page, press **Teacher Portal**, sign
in, change the password when asked, and confirm you land on your classes and
can mark a register. Then hand the rest out. If the first one works, the other
39 were made the same way by the same code.

Keep one slip back for yourself and destroy the sheet once they are handed out
— it is 40 passwords on one page. The table that held them has already been
dropped from the database; that paper is the only copy.

### C2. Confirm both application emails actually arrive

I proved the system sends them. The webhook returned HTTP 200 with
`{"ok":true,"note":"office:sent hirer:sent"}` — the SMTP server accepted both.

**Accepted is not delivered.** I cannot read the masjid's mailbox.

**Do:** the confirmation for `TM-26-00014` went to `yameen_bee@hotmail.co.uk`.
Check it arrived and is not in spam. Then check the office notification
arrived at whatever `MAIL_TO` points at — **`MAIL_TO` has one address**, and
if it is wrong or unread, applications pile up and nobody knows.

### C3. Exercise the Stripe payment path end to end

**Still the biggest untested thing in the system.** Since migration 021,
paying is the only way a hall date gets sold online — so if the webhook is
broken, nothing books at all, and the failure looks like silence.

**Do:** make a real hall booking, pay the real £100, confirm the date is held,
the office email arrives, the hirer confirmation arrives, and the booking
shows as confirmed. Then refund it.

### C4. Check the questionable dates of birth

34 pupils have a date of birth that is either under 3 or over 25. At least one
is provably wrong: pupil #514 shows 03/12/1974 — age 51, Boys Year 6 — and the
old system agrees, so the old system is wrong too.

**Do:** somebody who knows the families should go through them. The privacy
notice invites parents to correct them, which is the other half of this.

---

## D. Soon after, not blocking

| | |
|---|---|
| **The 307 pupil email addresses** | 307 children carry an email on their own row; 207 are already on a guardian of the same family. The fee-reminder design depends on parent details living on the family. 7 of the 10 "unreachable" families can actually be reached — the contact is in the wrong place. Nothing has been written to live records: clearing 207 real addresses wants an explicit yes. |
| **Email to parents from the Notices screen** | Needs a new message type in the notify Edge Function, which sends every email on the site. Deliberately left out. Do it at the start of a session with room to test it. |
| **New applications are not in the weekly digest** | `outstanding_summary()` reports nikāḥ, refunds and balances only. An application would never appear on the Monday email. It does appear instantly and on Today, so this is a second net, not the only one. |
| **The four `import_` landing tables** | 1,093 rows — a second copy of the register, medical notes included. Sealed, but `health_check` reports a deliberate failure until they are dropped. Keep them only until the questionable dates and the 56 sibling pairs are settled, then drop them. |
| **The 56 sibling pairs** | Families screen → Settle these. |
| **3 children sit on two active class rolls at once** | `health_check()`'s other deliberate red, added in `db/102`. `madrasah_attendance` is `UNIQUE (pupil_id, on_date)` masjid-wide, so a shared child can hold only one mark a night — one class's register can read complete on marking made by the *other* class's teacher, and neither teacher can see that from their own screen. **This is a real data problem, not a code fault**, escalated to Yameen to settle (which class each child actually belongs to) — not something a migration can decide on its own. Still 3, still unresolved, as of 28 September. |
| **`madrasah_charges` is not in the privacy notice — blocker for the fees go-live** | The table is empty today, so `notice_matches_the_schema` (widened in db/105 to discover its own tables) stays quiet about it. **The first fee charged turns `health_check()` red** on `kind, description, weeks, rate_p, gross_p, discount_p, discount_note, waived_p, waiver_note, net_p, charged_on, created_by` — the guard finds it whether or not anyone remembers to add it. Describing fees in a legal notice is the fees spec's own work, not guessed here where the fees screens cannot be checked against the words. **Do this before the first charge is created**, not before this go-live — it blocks the fees go-live, not this one. |
| **9 functions with a mutable `search_path`** | All `SECURITY INVOKER` trigger helpers, so low risk, but tidy them. |
| **Two name disclosures into working transcripts, 28 September** | Neither reached the repository, the database or anything published, and both were self-caught. **One:** roughly 44 teachers' names, from calling `registers_missing()` — a function whose job is to return people — merely to read a count. **Two:** three more, the same way, from `madrasah_registers_list()`, *after* the rule against it had been written into `CLAUDE.md`. Because telling people to be careful had by then visibly failed twice in a day, `db/115` gave the four screen functions count-only siblings (`registers_missing_count()` and the rest) so the right tool exists and there is no reason to reach for the wrong one. Staff names, not children's, and not special category data — but they are personal data about identifiable people and **whether either is recordable is the controller's call, not a developer's**. Listed here with **B6** so all three sit together. |
| **A separate business shares the masjid's Supabase organisation** | A second project, unrelated to the masjid, sits in the same Supabase organisation as the database holding 552 children's records. Billing, ownership and administrator access are organisation-level. This is a handover problem — whoever runs the masjid's systems in a year should not need a second party's cooperation — and a data-protection one. Moving the masjid's project to an organisation of its own is the fix. |
| **Eleven migrations were undocumented until 28 September** | `readme_test.py` checks that every applied migration has a row in the README, and it had accumulated eleven failures — `db/080` to `db/092`, including the register table itself and the guard behind the privacy notice — because **nobody had run it in weeks.** Now written and green. The lesson is the suite, not the rows: a suite nobody runs looks exactly like a suite that passes, which is why the sweep runs all 41 and not the eight the plan named. `admin_shell_test.py` was in the same state and was holding six real failures. |

---

## E. Reviewed and deliberately left alone

Say this to anyone who looks at the Supabase dashboard and panics.

| Warning | Why it stays |
|---|---|
| **~35 tables with RLS enabled and no policy** | Deliberate, and the safest setting there is. RLS on with no policy denies all direct table access; everything reaches those tables through functions that check who is asking first. A policy would be a second way in. |
| **31 `SECURITY DEFINER` functions callable by `anon`** | Every one is either a public submission (`submit_admission_application`, `request_hall_booking`, `request_nikah_date`) or a public read (`prayer_year`, `notices_live`, `masjid_brand`) or a predicate about the caller (`is_admin`). No madrasah data function is among them. |
| **Two `SECURITY DEFINER` views** | `hall_availability` and `notices_live`. Both are public by design. |
| **2,468 of 2,485 audit rows have no actor** | Not a fault, and this was carried as a worry for days before anyone asked the right question. 2,288 are hall holds purged by a cron job; the rest are anonymous submissions and webhook callbacks. **Nobody did those.** The right question was "is there an action a person performs that does not record them", and the seven that did were fixed in `db/089` — including opening a child's medical record, which is the one that most needed it. |

---

## What is on the site that was not a fortnight ago

- The **madrasah application form is live** and takes real children's records.
- **`/madrasah-privacy/`** is published and true, at **v1.7** (see B1).
- **Families**, **Notices to parents** and the **Register** are built; Today
  draws real state.
- **The register is built in full**: saving and hand-in with their own gates,
  the attendance history behind every mark, the office's missed-register
  list and each teacher's own, the teacher's own prompt on their landing
  page, the Today item, and the Monday digest's register section. All of it
  reads `permitted: false` correctly and stands down rather than inviting a
  mark nobody may make (see **B3 and B4** — this is the whole reason it
  cannot be used yet).
- The `notify` Edge Function (every email the site sends, including the
  Monday digest) was **redeployed four times for this**, v14 → v15 → v16 → v17.
  The first three went out before the migration each depended on was applied.
  v17 (for `db/117`) went out *after* it, which is the wrong way round: its new
  fields are additive and optional and the gate is shut, so nothing half-built
  could render, but it was not the order the rule asks for.
- **40 teachers have their own login**, scoped to their own classes. Measured
  on 29 September against production: 48 classes, of which 44 are active; every
  active class has at least one teacher on it, but **one active class has no
  main teacher** (an assistant only), and 4 classes are inactive. The 40 logins
  are 37 main teachers plus 3 assistant-only. One current staff member has no
  login. (Earlier drafts of this file said "70 classes covered, one teacher per
  active class". That was not measured and was wrong.)
- The register **will not open** until parents are told, and rechecks this
  on every save, not only once when the page loads.
- Fee reminders **will not send** to a family that has not been told.

## The order these have to happen in

Three of the items above are chained, and doing them out of order means 40
people sign in to a portal that refuses them.

```
B3  tell 330 families the notice exists
      ↓  (save_register_draft refuses until this is done — checked on
      ↓   every save, not only once)
B4  tell them again, before the first mark
      ↓
C1  you sign in with one teacher slip and mark a register
      ↓
    hand the other 39 slips out
```

A teacher who signs in before B3 and B4 sees their own classes with the gate
above them saying why marking is shut — a job with a number on it and a way
out, not a grey wall — and cannot save a mark: pressing Save reaches the
database's own refusal, in the database's own words, not just a screen that
happens to agree. **Do not distribute the slips until a register has
actually been marked.** Everything else in section A and B can happen in any
order.

## Still deliberately "coming soon"

Fire drill and roll call, concerns and incidents, safeguarding reports,
homework, lesson log, merits, exams, end-of-year reports, academic year,
settings, and messages to parents. Each is a `soon` tag in `portal/nav.js`,
which renders as a muted, unclickable row rather than a link that goes nowhere.

One of those is not quite honest and is worth knowing: **raising a safeguarding
concern works** — a teacher can file one and it is stored with their name
against it. What is "coming soon" is *reading* them. Today there is no screen
that lists concerns; they can only be read out of the database. So if you tell
teachers they can report a concern, somebody has to be checking, and right now
that somebody is me running a query. **Either build the triage screen before
teachers are told they can raise concerns, or tell them to keep using whatever
they use today and treat the button as not there yet.** A report nobody reads
is worse than no button at all, because the teacher believes they have
discharged their duty.
