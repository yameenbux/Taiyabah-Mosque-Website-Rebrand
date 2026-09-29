# The register, rebuilt

**28 September 2026.** Design for spec 1 of two. Spec 2 is the parents' portal
and is not covered here.

---

## What this is for

A teacher takes a register on a phone, in a classroom, at ten past five. The
madrasah needs that to be a **record** — complete, kept, attributable, and
retrievable years later — and it needs somebody to notice when it does not
happen.

Today it is none of those things. `mark_register()` accepts a half-finished
register without complaint, overwrites the previous marks in place so no history
survives, and tells nobody when a class goes unmarked. A class could go three
weeks without a register and the only way anyone would find out is by opening
the right screen on the right evening.

### Success looks like

1. A register cannot be submitted until **every child on the roll carries a
   mark**. Any mark — present, late, absent, excused — but not nothing.
2. **Every mark ever written is kept**, including the one it replaced, so
   "what did this say on 12 November, and who changed it" has an answer.
3. **A missed register is noticed** — by the office, and by the teacher who
   should have taken it.
4. **A parent's report of absence reaches the teacher**, entered by the office
   today and by the parent directly once spec 2 exists.

### Decided with the masjid, not assumed

| Question | Decision |
|---|---|
| How does a parent report an absence? | A real parent login — **spec 2**. Not a code scheme, not an open form. |
| Sequencing | Two specs. This one builds the receiving side; spec 2 adds the front door. |
| Half-finished register | **Draft, then submit.** Marks are kept as made; the register is not *taken* until complete. |
| How is a register known to be due? | **One masjid-wide setting** for running weekdays, plus the academic year and closures already held. |
| How is the office told? | **In the portal, plus the Monday digest.** |
| How is the teacher told? | **In the portal only** — teacher logins hold no email address. |

---

## What already exists and is not being rebuilt

Checked against the live database on 28 September:

- `madrasah_attendance` — one row per child per evening, `UNIQUE (pupil_id,
  on_date)`. Marks are `present | late | absent | excused`. Source is
  `register | parent | office` — **the parent and office values already
  exist**.
- `mark_register()` — already gates on `may_take_register()`, on
  `attendance_permitted()`, on the date not being in the future or more than 14
  days past, on the child actually being in that class, and already refuses to
  let a teacher's tick overwrite a parent's report of absence unless the mark is
  present or late.
- `madrasah_years` — one row, 2026/27, 1 Sep 2026 to 31 Aug 2027, `is_current`.
- `madrasah_closures` — 8 rows, each a named range.
- `admin_audit` — already receives a `register_taken` row with the actor.
- `outstanding_summary()` — the Monday digest, already emailing the office.

None of that changes shape. The work sits around it.

---

## Data model

### `madrasah_registers` — the register as a thing in its own right

One row per class per evening.

```
id, masjid_id, class_id, on_date,
state            'draft' | 'submitted'
expected_count   children on roll when it was last touched -- a record of
                 what was true then, NOT the thing submit checks against
marked_count     how many carry a mark
submitted_by, submitted_at,
created_at, updated_at
UNIQUE (class_id, on_date)
```

**Why a table rather than counting marks.** "Was the register taken?" is
currently inferred by counting attendance rows, which cannot tell a finished
register of 10 from an abandoned one that happens to have 10 children left on
the roll after somebody left. A register is a thing that was or was not done,
and it should be recorded as one.

### `madrasah_attendance_log` — append-only

One row per mark ever written.

```
id, masjid_id, pupil_id, class_id, on_date,
mark, reason, source,
was_mark, was_reason, was_source   -- what it replaced, null on the first
written_by, written_at
```

Never updated. Never deleted except by the cascade that removes the child.
`madrasah_attendance` remains the current state and every existing screen
reads it unchanged; the log answers "what did it used to say".

**Retention is unchanged by this.** `pupil_id` is `ON DELETE CASCADE` against
`madrasah_pupils`, exactly as `madrasah_attendance` is, so the log is deleted
with the child three years after they leave. The privacy notice's promise holds
without a new purge rule.

### `madrasah_settings` — key/value, per masjid

Following the shape `madrasah_fee_settings` already uses
(`masjid_id, key, value jsonb, changed_at, changed_by`). One key to begin with:

```
register_days   ["mon","tue","wed","thu","fri"]
```

A separate table rather than a column on `madrasah_classes`, because the answer
is the same for all 70 classes and keeping 70 copies of one fact is 70 chances
for it to differ. Per-class overrides can be added later without moving this.

---

## When a register is due

`register_due(class, date)` returns whether one is expected and, when not, why
not. A register is due when **all** of these hold:

- the date falls inside the current academic year
- its weekday is in `register_days`
- it is not inside any `madrasah_closures` range
- the class is active and has at least one child on roll

Everything it reads is already populated. Nothing new has to be filled in for
this to work on day one.

---

## Functions

| Function | Who | What it does |
|---|---|---|
| `save_register_draft(class, date, marks)` | teacher, office | Writes the marks given, appends to the log, leaves state `draft`. Accepts any number. |
| `submit_register(class, date)` | teacher, office | **Refuses unless every child on roll carries a mark**, naming how many are missing. Counts against the roll **as it is at that moment**, never against a stored number, because a child can join or leave between the draft and the submit. Sets state `submitted`, writes the audit row. |
| `record_parent_absence(pupil, date, mark, reason)` | office | Writes with `source = 'parent'`. Spec 2's parent login calls this same function. |
| `registers_missing(from, to)` | office | Classes and dates where a register was due and is not submitted. |
| `my_registers_outstanding()` | teacher | The same, scoped to their own classes. |
| `register_history(class, date)` | office | The log for that evening, most recent first. |

`mark_register()` is kept and becomes: **save the marks, then attempt to
submit, and report which happened.** A partial call still saves exactly as it
does today and simply does not submit — so the current Register screen keeps
working unchanged during the switch, rather than starting to refuse the partial
saves it makes now. It returns `{marked, parent_reports_kept, submitted:
true|false, missing: n}` and is marked deprecated in its own comment.

**A submitted register can still be corrected by the teacher** within the
same 14-day window they have today, and each correction is written to the log.
Submitting is not a lock; it is a statement that the register was completed.
Taking away a correction teachers currently have, in the same change that makes
the record stricter, would push them to ring the office over a mistyped tick.

**All existing gates are preserved**: your own class, parents told, no future
dates, nothing older than 14 days for a teacher. The office keeps the ability to
correct an older evening, and a correction is written to the log **as a
correction** — the existing refusal message already promises this ("so the
record says it was corrected rather than taken") and nothing currently delivers
it.

---

## Screens

**Register (teacher and office).** A "7 of 10 marked" counter, a Save button
that always works, and a Submit button disabled until the count is full. The
unmarked rows are highlighted in the class list so the teacher can see at a
glance who is left — they are looking at their own class and are entitled to
every name on it. A submitted register renders as done.

**Teacher landing page.** A prompt when they have a register due and not
submitted — tonight's, and anything outstanding behind it. This is the only
channel a teacher has; their logins carry no email address.

**Today (office).** A line for missed registers, alongside the existing lines.

**Registers (office).** The existing screen gains the outstanding list and, per
evening, a history panel drawn from `register_history()`.

---

## The Monday digest

`outstanding_summary()` gains one section: registers due last week and not
submitted, by class. It currently covers nikāḥ, refunds and balances and
mentions attendance nowhere.

---

## The privacy notice, and a correction to the guard

`madrasah_attendance_log` and `madrasah_registers` hold data about children, so
the notice must describe them. **This work requires notice v1.6.**

**A correction to what I said when presenting this design.** I said the guard
would fail the moment the new table existed. That is not true, and the
difference matters. `madrasah_notice_matches_schema()` checks a **hard-coded**
`watched` list:

```sql
watched text[] := array[
  'madrasah_pupils', 'madrasah_households', 'madrasah_guardians',
  'madrasah_attendance', 'madrasah_concerns'
];
```

A new table holding children's data is invisible to it until somebody remembers
to add it — which is exactly the failure the guard exists to prevent. A guard
that depends on remembering is the thing it was built to replace.

**So this spec widens it the way `db/080` widened the minimisation guard**:
discover the tables rather than list them. Any table in `public` with a
`pupil_id` column referencing `madrasah_pupils` is watched automatically. Then a
future table holding children's data fails the notice check on the day it is
created, without anybody deciding to be careful.

---

## Testing

Extends `_test/register_test.py` and the database checks:

- a register with one child unmarked **cannot be submitted**, and the refusal
  names the number missing
- a draft survives: marks saved, page reloaded, marks still there, state still
  draft
- the log captures a change: mark absent, submit, change to present, and the
  log holds both with the earlier one as `was_mark`
- `register_due()` is false on a Sunday, false inside a closure, false outside
  the academic year, true on an ordinary Tuesday
- a missed register appears in `registers_missing()`, on the teacher's landing
  page, and in the digest
- a parent report is not overwritten by a teacher marking absent, and **is**
  overwritten by a teacher marking present
- the widened guard fails when a throwaway table with a `pupil_id` is created
  and the notice does not describe it — proved by creating one, watching it
  fail, and dropping it

Every guard is proved capable of failing before it is kept, per the standing
practice in `CLAUDE.md`.

---

## Explicitly out of scope

- The parents' portal and parent logins — **spec 2**
- Attendance reports and percentages — no aggregate reporting is built here
- Per-class timetables — one masjid-wide setting, overrides later if needed
- Lesson logs, homework, merits — untouched
