# The parents' portal, progress, and messages

**29 September 2026.** Spec 2 of two. Spec 1 was the register, and it is built.

---

## What this is for

A parent has no way in. Everything the madrasah knows about their child — the
class, the register, the medical note they gave the office themselves — is
behind a staff login. When they want to say their child is ill they ring, and
whoever answers writes it on paper. When they want to know how their child is
getting on they ask at the door.

Three things follow from giving them a door of their own, and this spec builds
all three:

1. **A parent can see their own children, and nobody else's.**
2. **A parent can tell the madrasah something** — my child is away today, and
   anything else, in writing, to the office.
3. **A parent can read what the teacher has written** about how their child is
   getting on.

### Success looks like

- A parent signs in, sees their children, and **cannot reach any other child
  by any route** — not by guessing an id, not by a function that forgets to
  scope, not through an export.
- Reporting an absence reaches the teacher's register **before** the evening,
  and the teacher's tick cannot quietly overwrite the parent's reason.
- A message from a parent lands somewhere a person will see it, and the office
  can reply. Both sides are kept.
- A teacher records progress once; the parent reads the part meant for them.
  **Not everything a teacher writes is for a parent** — that distinction is in
  the data, not in a habit.

### Decided, not assumed

| Question | Decision | Why |
|---|---|---|
| Who is a parent? | A **guardian row** on a household, given a login | The household already owns the contact details and the children. Nothing new to keep in step. |
| One login per parent or per family? | **Per guardian.** Several guardians may each have one on the same household | Two parents should not share a password, and a record must say which of them said a thing. |
| What can a parent see of the register? | Their child's **own** marks, and the reason recorded | It is their child's record. They are entitled to it under Article 15 anyway. |
| Can a parent change a mark? | **No.** They can report an absence, which is a `source = 'parent'` mark, and the existing rules decide the rest | The register is the madrasah's record of what it observed. |
| Progress: who decides what a parent sees? | The **teacher**, per entry, explicitly | A teacher must be able to write a working note without it being published to a family. |
| Messages: threads or one-offs? | **Threads**, parent ↔ office, subject per thread | "Did anyone answer this?" needs an answer that does not depend on memory. |
| Can a teacher message a parent? | **Not in this spec.** Office only | A teacher messaging a family directly is a safeguarding question the masjid has not settled. The tile stays `soon`. |

---

## Identity

### `madrasah_parent_logins`

One row per guardian who has a login.

```
id, masjid_id, guardian_id -> madrasah_guardians(id) ON DELETE CASCADE,
user_id -> auth.users(id),
created_at, created_by, last_seen_at
UNIQUE (guardian_id), UNIQUE (user_id)
```

The children a parent may see are derived, never stored:

```
guardian -> household -> pupils on that household
```

A child who moves household moves with it on the next page load. A stored list
would not.

### Gates

- `is_parent()` — the caller has a row in `madrasah_parent_logins`.
- `my_parent_children()` — the pupils on the caller's household, **and nothing
  else**. Every parent-facing function takes its pupil set from this one
  function so there is a single place to be wrong.
- A parent is **not** `verified_madrasah()` and must never satisfy it. Every
  existing staff function already refuses them; this spec adds tests that prove
  it rather than assuming it.

**Two-step is not required of a parent.** Staff accounts open 552 children's
records and are made to enrol an authenticator; a parent account opens one
family's. Requiring an authenticator app of 330 families would mean most of
them never get in, and a door nobody can open is not a security measure. The
compensating control is that a parent login reaches exactly one household.

---

## What a parent sees

**Their children.** Name, class, teacher, and the medical and contact details
the madrasah holds — because a notice that says *"tell us if this is wrong"*
is worthless if they cannot see what it says.

**Attendance.** Their own child's marks, evening by evening, with the reason
where one was given, and who recorded it as *the madrasah* or *you*.

**Progress.** What the teacher has chosen to share, newest first.

**Messages.** Threads with the office.

---

## Reporting an absence

Calls `record_parent_absence()`, which spec 1 built and `db/116`–`118` hardened.
The parent's caller gate widens from *office only* to *office, or a parent for
their own child* — and that is the single riskiest line in this spec, so the
widening is done in one function, scoped through `my_parent_children()`, and
tested from the other direction: a parent passing another family's pupil id
must be refused.

All of spec 1's rules still hold: not the future, not before the register
opened, not outside the academic year or a closure, and a teacher marking
`present` or `late` still overrides — because it means the child turned up
after all.

---

## Progress

### `madrasah_progress`

```
id, masjid_id, pupil_id, class_id, term_or_date,
sabaq, sabqi, manzil      -- where the child is up to
note_for_parent  text     -- NULL means nothing is shared
note_internal    text     -- never leaves the staff side
shared boolean            -- false until the teacher says otherwise
written_by, written_at, updated_at
```

`shared` and `note_for_parent` are two different questions and both are asked:
an entry can be shared with no note, and a note can be written and not yet
shared. The parent-facing function returns **only** `shared = true` rows and
**never** selects `note_internal` at all — not filtered in the application,
absent from the function body, so it cannot be returned by an accident of
refactoring.

Every write is audited, as `db/089` requires of anything a person does.

---

## Messages

### `madrasah_threads` and `madrasah_messages`

```
madrasah_threads
  id, masjid_id, household_id, subject, state 'open'|'answered'|'closed',
  opened_by_parent boolean, created_at, last_message_at,
  unread_for_office boolean, unread_for_parent boolean

madrasah_messages
  id, thread_id -> madrasah_threads ON DELETE CASCADE,
  body text, from_parent boolean, author_user, created_at
```

A thread belongs to a **household**, not to a guardian, so either parent can
read the reply — and so a thread survives a guardian's login being removed.

**The office is told.** A waiting thread appears on Today and in the Monday
digest, using the same gate-aware shape spec 1 established: the count is a
count, never a name, and the item links to the screen.

**Nothing here is a channel for an emergency**, and the screen says so in
words. A parent whose child is missing rings the masjid. A message that sits
unread over a weekend must not be the way a safeguarding matter arrives.

### Retention

Messages are about a child and are deleted with the child, by the same cascade
that carries attendance: `household_id` is `ON DELETE CASCADE`, and a household
is removed when its last pupil is purged three years after leaving. The privacy
notice must describe threads and messages, which means **notice v1.7**, and the
schema guard widened in `db/105` will fail until it does.

---

## The test family

One invented household, one invented child, one parent login, created by a
migration that can be replayed and a single documented statement that removes
it. Real names are never used. The test family **is counted** in the roll and
in the families figures like any other, which means it shifts 552 to 553 and
330 to 331 — the handover says so plainly rather than hiding it, and says how
to take it out.

---

## Explicitly out of scope

- A teacher messaging a parent directly — a safeguarding decision the masjid
  has not made.
- Homework, merits, exams, end-of-year reports, lesson log, fire drill.
- Online fee payment by a parent.
- Push notifications to the app.
