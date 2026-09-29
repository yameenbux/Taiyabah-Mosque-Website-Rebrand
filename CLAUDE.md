# Working on the Taiyabah Masjid site

Bolton Central Islamic Society, registered charity 1041569. This repository is
the masjid's public website, its admin portal, and the madrasah's record system.

**Read this before touching anything.** Most of it exists because something
went wrong once.

---

## The two facts that change how you work

### 1. This repository is public, and pushing is deploying

GitHub Pages serves the repository root. **Anything committed is a public web
page within a minute of a push** unless `_config.yml` `exclude:` lists it — and
even then it is still readable in the public repo. There is no staging.

`_config.yml` is long and worth reading once. Its comments are a list of things
that were briefly published by accident, including the build scripts, the
database migrations, and — caught the day before a push — a confidential DPIA.

**A confidential document does not belong here at all**, excluded or not. The
DPIA and the breach procedure are deliberately absent. Do not add them.

### 2. There are 552 real children in the database

Names, dates of birth, home addresses, guardians' phone numbers, medical notes,
allergies, SEND marks. That is special category data under Article 9.

- **Never put a real pupil, parent or staff name in this repository.** Not in a
  test fixture, not in a SQL comment, not in an example. This has happened four
  times and each time the names had to be hunted out of served files. Invent
  names.
- **Never paste real personal data into a chat.** That includes your own
  debugging output — `RAISE EXCEPTION '%', <whole json row>` has leaked a family
  surname and twenty-one staff names into a transcript. Select named scalar
  fields, never whole rows.
- **Some functions return names because that is their job. Do not call them to
  check a number — use the count-only companion instead.**
  `registers_missing()`, `register_history()`, `madrasah_registers_list()`,
  `madrasah_roll()`, `madrasah_pupil_one()` and the rest of the office's screen
  functions exist to put names in front of the person entitled to see them.
  A bare call to one while verifying a count puts every name in the
  transcript — 44 teachers on 28 September, 3 more the same day, both times
  after this rule was already written down. Telling people to be careful is
  the weakest control there is, so `db/115` gave the four functions above a
  count-only sibling — `registers_missing_count()`, `register_history_count()`,
  `madrasah_registers_list_count()`, `madrasah_roll_count()` — same
  arguments, same gates, same `current_masjid()` scoping, and **no names in
  the body at all**. **When you want a figure, call the `_count()` function.**
  For a function with no count-only sibling yet, wrap the call and select
  `count(*)`, `jsonb_array_length(result->'rows')`, or a boolean — never
  `select * from` a function whose purpose is to return people, and never
  select the `rows` key itself, even to compare it against something else.
- **Never run ad hoc DML against `madrasah_pupils` bare — not even inside a
  transaction you intend to roll back.** A failed CHECK on that table prints
  **the whole row** into Postgres's error DETAIL: medical notes, allergies,
  SEND and EHCP detail, address, postcode, date of birth. Live settings are
  `log_min_error_statement = error` and `log_error_verbosity = default`, so
  that DETAIL reaches the **Supabase-retained server log** — not only your
  transcript, and a rollback does not take it back. This has now happened
  **twice**, on 27 and 28 September, both times inside a block that rolled
  back cleanly, both times by someone proving a guard worked.

  If you must touch that table, wrap it so only the `sqlstate` escapes:

  ```sql
  begin
    update public.madrasah_pupils set ... where id = ...;
  exception when others then
    raise exception 'refused: %', sqlstate;   --  sqlstate ONLY. Never sqlerrm,
                                              --  never the row, never a column.
  end;
  ```

  `sqlerrm` is not safe here: for a constraint violation it carries the
  DETAIL. And prefer not to touch it at all — most proofs can be made
  against a throwaway table or by reading, and a proof that needs a real
  child's row is usually the wrong proof.

---

## Building

```bash
python3 verify_structure.py && python3 build.py
```

**`index.html` is generated. Never edit it by hand.** It is 634 KB, it is the
whole public site in one file, and it is built from `index_template.html`. An
edit to `index.html` is overwritten by the next build and looks, in the diff,
exactly like an edit that worked.

`verify_structure.py` runs first for a reason — it refuses to let the build
proceed on a broken structure. It checks div balance, that every `data-nav` and
anchor resolves, that no `id` is duplicated, that no build placeholder is left
unsubstituted, that donation links still point somewhere that takes money, and
that the portal tiles agree with the paragraph under them.

Portal screens are generated too, by `tools/screen_builder.py` and the
`tools/build_*_screen.py` scripts. Regenerate rather than hand-editing
`portal/*/app.js`, and check `--verify-pupils` still reproduces the Pupils
screen byte-for-byte after changing the generator.

## Testing

```bash
python3 _test/register_test.py        # and the other 40 in _test/
```

They drive a real browser against the built files. They are slow — the full
sweep is several minutes — and they are the only reason most of the bugs in
this repo were found rather than shipped.

`_test/` is excluded from Pages but committed. It is not optional: four suites
once lived in a scratch directory where they quietly stopped running, and **a
suite nobody can run looks exactly like a suite that passes.**

---

## Rules that are not negotiable

**Secrets.** The `service_role` / secret Supabase key must never appear in any
file here or in any client-side code. The anon publishable key (`sb_publishable_…`)
**is** safe to commit — RLS is the real protection. The Stripe secret key stays
local and `STRIPE_SECRET_KEY` must **not** be added to Supabase. A
`service_role` JWT and the `NOTIFY_SECRET` are stored in plaintext inside
database-webhook trigger definitions; **never write them to a file.**

**If GitHub secret scanning blocks a push, do not click "Allow secret."**
Cancel, remove the key, rotate it.

**Browser JavaScript is ES5.** `var` and `function` only — no arrow functions,
no `const`, no `let`, no template literals. `.finally()` is accepted precedent.
Older phones in the community run browsers that do not parse the rest, and the
failure is a blank screen, not a warning.

**Every new stylesheet opens with `[hidden] { display: none !important; }`.**

**Keep two administrators.** One locked-out admin must not be able to strand
the masjid.

**The `db/*.sql` files are a record, not a queue.** Every migration through 093
is already applied to production. They are numbered history. Do not re-run
them; write a new numbered file.

---

## How to think about this codebase

These are not style preferences. Each one is the shape of a bug that shipped.

**The list says WHETHER, the record says WHAT.** A list screen says *nine
children have no date of birth*. It does not name them. A screen that sits open
on a desk all evening should not have children's records on it.

**A check that asserts something EXISTS is not a check that it WORKS.** A test
that finds a button is not a test that the button does anything.

**Never test a guard by breaking the real thing.** Add a throwaway, watch the
guard fail, drop the throwaway, confirm green.

**Prove a guard can fail before keeping it.** A guard that has never been seen
to fire is decoration. One here read correctly and could never fire, because
the state it tested was pre-populated by construction.

**When a rewrite replaces something that works, the failing test is usually
telling you what the old version knew.** A rewrite of the Today page silently
dropped "21 **of 40**" down to "21". The denominator was the point.

**When two `!important` declarations collide, specificity decides.**
`admin/shell.css` has `body.has-ashell .shell { display: block !important }` at
(0,2,0), which beats `body > *` at (0,0,1). Print sheets must be moved to
`document.body`.

**Check whether the check is wrong before you change the code.** Roughly half
the failures in this project were the test, not the system: `inner_text` does
not see `::before` content or a `placeholder` attribute; `git apply --check` run
against a tree that already has the commit reports every hunk as a conflict. Read
the failure before you believe it.

**Ask the right question before answering the wrong one.** "2,468 of 2,485 audit
rows have no actor" was carried as a security worry for days. 2,288 were a cron
job purging hall holds, the rest anonymous submissions and webhooks — **nobody
did those.** The right question was "is there an action a *person* performs that
does not record them." There were seven, fixed in `db/089`.

**Put a promise where it can fail.** The signed privacy notice was made false
three times by ordinary schema changes, because prose cannot fail a build.
`madrasah_notice_matches_schema()` inside `health_check()` now does. When you
find something the system claims about itself, prefer a check over a comment —
and a comment over nothing.

---

## Before you say it works

Run the thing. Read the output. The pattern to avoid: a Python heredoc with a
syntax error meant a "negative control" never ran, and the ALL PASS that
followed proved nothing.

Say what you verified and how. Do not say a migration is applied because you
wrote the file, or that emails arrive because the server accepted them —
**accepted is not delivered.**

---

## Where things stand

`docs/GO-LIVE.md` is the live checklist and is ordered by what breaks if you
skip it. Read it before starting anything; it is more current than this file.

The two things most likely to bite:

1. **`CNAME` says `taiyabahwebsite.ysbdesigns.uk`; the site says
   `taiyabahmasjid.com` in 17 places**, including the privacy notice printed for
   330 families. Fix the domain before any letter goes out.
2. **Raising a safeguarding concern works; reading concerns does not exist.**
   There is no triage screen — only a database query. A report nobody reads is
   worse than no button, because the teacher believes they have discharged their
   duty.

The committee runs this site day to day, not a developer. When choosing between
a clever thing and an obvious thing, choose the one a volunteer can still
operate in a year.
