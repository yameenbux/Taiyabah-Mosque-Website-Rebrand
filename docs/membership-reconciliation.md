# Membership: reconciling the two backends

_Written 20 November 2026. What changed, why, and what is still owed._

For a while there were **two membership systems** in this project, and they did
not agree with each other. This is the record of folding them into one, and of
the decisions taken on the way that someone will otherwise have to reconstruct
from the migrations.

## The two that existed

1. **A flat `public.members` table** behind the first lock-down work — one row
   per person, a `balance` column written by hand. It was what the email-OTP
   login read. It had no concept of a fee that changes by year, no payment
   history, and its balance was a number somebody typed, not a number the
   system could defend.

2. **The canonical schema in `db/157`–`db/160`** — `masjid_members` (the
   register), `membership_rates` (the fee per year, with history),
   `membership_years` (the charge raised against a member for a year) and
   `membership_payments` (what actually came in, by method). Here a balance is
   **computed** by `membership_state()` from charges minus payments, so the
   office screen and the member's own screen in the app cannot disagree about
   what is owed. This was written but had never been deployed.

Keeping both was not an option: the login would say one thing and the office
screen another, and the first time those differed in front of a member the
register would lose its authority for good.

## What was done

- **The canonical schema is now the source of truth.** `db/157`–`db/160` are
  deployed. `masjid_members` is the register; balances are computed, never
  stored.
- **The flat `public.members` table is retired.** Its rows were cleared and the
  login re-pointed. The empty shell is harmless; dropping it is noted under
  _still owed_ below.
- **The register was imported into `masjid_members`:** **879** members, of whom
  **675** carry an email and **598** of those are distinct — **63** households
  share an address with another member, which is why the login offers a
  household picker rather than assuming one email is one person.
- **The fee schedule was set, not guessed:** £80 for 2021–2023, £100 for
  2024–2026, in `membership_rates`.
- **The login now matches on `email_norm`** (`db/164`) — a normalised, indexed,
  case- and space-insensitive copy of the email — so a match is exact and an
  underscore in an address is never read as a SQL wildcard.

## The decision not to invent arrears

The spreadsheet the register came from carried **general-ledger totals**
(QuickBooks-style running figures with £22k and £147k outliers), not clean
per-year membership fees. It would have been easy to divide those into
per-year arrears and import them, and the result would have **looked**
researched while being fiction.

Per `db/157`'s own principle — _guessing makes the figure look researched_ — we
did **not**. We imported the **register and the fee schedule only**. Charges are
raised going forward by the office (`membership_raise_year`), and payments are
recorded as they come in. The system therefore never shows a member an arrears
figure it cannot account for line by line. Where the old sheet's method of
payment was unknown, a payment carried in reads **"from the old register"**,
never a fabricated "Cash".

## The security hole that was closed by not building it

`db/158` contained public, `anon`-granted name-search functions
(`membership_name_matches`, `membership_claim` and friends) — the design that
let **anyone search anyone's name**. Those sections were **deliberately never
deployed**. Only the office functions (`membership_state`,
`membership_current_year`, `membership_reference`) went in, and the first two
are granted to `service_role` only, revoked from `anon`/`authenticated`. The
hole was closed structurally: the door was never cut, not merely locked.

## The office screen (`members/`)

The hand-written office screen now carries every door the register lost when it
left the Excel sheet, each one **`verified_admin()`-gated and audited in
Postgres**, so the gate holds even if the browser is bypassed:

| Action | Function | Note |
|---|---|---|
| Add a member | `membership_upsert_member` | name required, rest optional |
| Amend details | `membership_upsert_member` | keyed on the member's `ref_no` |
| Record a payment | `membership_record_payment` | cash / card terminal / transfer / cheque |
| Set a year aside | `membership_waive_year` | reason recorded against the admin's name |
| Mark as left | `membership_mark_left` | keeps the record and payment history |
| Delete a mistake | `membership_delete_member` | refused once any payment exists |
| Download this list | (client CSV) | names and figures, **no addresses** |
| Full backup | `membership_export` | the whole register, every column, audited |

`membership_delete_member` refusing the moment a payment exists is the line
between "a real member who left" and "an entry typed by mistake": the first is
kept with `mark_left`, only the second is ever removed.

All four write/export functions were observed to **refuse with `42501 "Not
allowed"`** when the caller is not a verified admin — the guard was seen to
fire, not merely assumed.

## Done since

- **The empty `public.members` shell is dropped** (`db/165`). It held no rows,
  had no incoming foreign keys, no view and no function referencing it, so an
  empty table that once carried a second, disagreeing balance is gone rather
  than left as a trap.

## Still owed

- **The Sheet is now a backup, not the source.** The office takes a _Full
  backup_ CSV from the screen; the Google Sheet is kept only as a belt-and-braces
  copy and is no longer written back to.
