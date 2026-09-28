# Before you press go live

**Written 27 September 2026.** Every figure here was read from production or
from the repository on that date, not remembered. Where something could only
be checked by a person, it says so and says who.

Ordered by **what breaks if you skip it**, not by how hard it is.

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

### B1. Re-sign the privacy notice at v1.4, and record an Article 35(11) review

The signed v1.1 said the madrasah held no date of birth, address, telephone
number or medical information. The register import made all four false. The
published page is now **v1.4** and true; the signed document in the masjid's
files is still v1.1.

**Do:** sign v1.4, and note on the DPIA that three things have widened the
scope you already signed, which is what Article 35(11) asks you to review:

1. the register import (dates of birth, addresses, telephone numbers, medical
   and allergy notes, SEND marks),
2. the attendance register — a daily record of where a child was,
3. **teachers reading their own class**, including the medical note and who to
   ring, and being able to raise a safeguarding concern.

Version 1.4 of the page already says all three. The signature is what is
missing, and a notice the controller has not signed is a draft.

*Drift check: `madrasah_notice_matches_schema()` runs inside `health_check()`
and fails if the schema holds something the notice does not describe. Nobody
has to remember this one.*

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

### B3. Tell parents the notice exists — all 330 families

**This is the one with the most consequences attached.** Publishing a notice
is half the duty; the ICO's position is that you must take an active step.

Until a family is recorded as told:

- **fee reminders will not go to them.** Enforced in the database, per family.
- Today shows *330 families have not been told*.

**Do:** Notices to parents → Choose every family shown → Print 330 letters →
hand them out → Record as told. The date goes against your name, and that
record is the evidence.

### B4. Tell parents again before the first register is marked

The notice promises: *we will tell you before the first mark is made, not
afterwards.* The database enforces it — `mark_register()` refuses until every
family with a child on the roll is recorded as told under
`kind = 'attendance_notice'`. The Register screen shows the count and a way to
go and do it.

You can do B3 and B4 in one pass with one letter, but they are **two separate
records** and both must exist.

### B5. Turn on leaked-password protection

Supabase reports it disabled. It is one switch in Auth settings and it stops
staff choosing a password that is already in a breach corpus. These accounts
open 552 children's records.

---

## C. Only a person can check these

### C1. Sign in as a teacher yourself before you hand out a single slip

> **28 September — this was done, and it found that every login was dead.**
>
> All 40 teacher accounts returned *"Database error querying schema"* at the
> sign-in page. `create_teacher_login()` had left four columns NULL in
> `auth.users` that Supabase's auth service reads as text, so it failed on the
> row before it ever checked the password. **Not one of the 39 slips would have
> worked.** Fixed in `db/094`: all rows backfilled, the function patched, and
> `auth_rows_readable()` added to `health_check()` so the next one is caught by
> the system rather than by a teacher standing at a screen.
>
> **Still do the walkthrough below.** The fault is fixed; the journey past the
> sign-in box — forced password change, landing on your classes, opening a
> child — has still not been walked by a person.

**Nothing here had been signed in to over the web.** The 39 teacher accounts
were created inside the database, and this machine has no network route to
Supabase, so no password had ever been typed into the login box. All 39 showed
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
38 were made the same way by the same code.

Keep one slip back for yourself and destroy the sheet once they are handed out
— it is 39 passwords on one page. The table that held them has already been
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
| **9 functions with a mutable `search_path`** | All `SECURITY INVOKER` trigger helpers, so low risk, but tidy them. |

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
- **`/madrasah-privacy/`** is published and true.
- **Families**, **Notices to parents** and the **Register** are built; Today
  draws real state.
- **39 teachers have their own login**, scoped to their own classes — 70 classes
  covered, one teacher per active class.
- The register **will not open** until parents are told.
- Fee reminders **will not send** to a family that has not been told.

## The order these have to happen in

Three of the items above are chained, and doing them out of order means 39
people sign in to a portal that refuses them.

```
B3  tell 330 families the notice exists
      ↓  (mark_register refuses until this is done)
B4  tell them again, before the first mark
      ↓
C1  you sign in with one teacher slip and mark a register
      ↓
    hand the other 38 slips out
```

A teacher who signs in before B3 and B4 gets *"The register is not open yet"*
and a line telling them to go and tell the parents, which is not their job and
not a door they can open. **Do not distribute the slips until a register has
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
