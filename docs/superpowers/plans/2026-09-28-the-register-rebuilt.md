# The Register, Rebuilt — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A register that cannot be submitted half-finished, keeps every mark it has ever held, and is chased when it is missed.

**Architecture:** `madrasah_attendance` stays as the current state that every screen already reads. Around it: `madrasah_registers` records the register as a thing that was or was not done; `madrasah_attendance_log` is append-only and holds every mark ever written with what it replaced; `madrasah_settings` holds which weekdays the madrasah runs. `mark_register()` keeps working and gains a submit attempt, so nothing breaks while the screens move over.

**Tech Stack:** PostgreSQL 17 (Supabase, eu-west-2), plpgsql `SECURITY DEFINER` functions, RLS-on-no-policy tables, ES5 browser JavaScript, Playwright suites in `_test/`.

**Spec:** `docs/superpowers/specs/2026-09-28-the-register-rebuilt-design.md`

## Global Constraints

- Migrations are numbered files in `db/` and are **a record of what is already applied**. Apply with the Supabase MCP tool, then commit the file. Never re-run an applied migration.
- Browser JavaScript is **ES5 only**: `var` and `function`, no arrow functions, no `const`/`let`, no template literals. `.finally()` is accepted precedent.
- Every new stylesheet opens with `[hidden] { display: none !important; }`.
- **Never edit `index.html` or `portal/*/app.js` by hand** where a generator exists. Edit `tools/register_module.js` and regenerate with `python3 tools/build_register_screen.py`.
- After any template change: `python3 verify_structure.py && python3 build.py`.
- **Never put a real pupil, parent or staff name in the repository**, including test fixtures and SQL comments. Invent names.
- New tables holding pupil data: `enable row level security`, `revoke all ... from anon, authenticated`. Access goes through `SECURITY DEFINER` functions only.
- Every function: `revoke all ... from public, anon;` then `grant execute ... to authenticated;`.
- **Prove every guard can fail before keeping it.** Add a throwaway that breaks it, watch it fail, drop the throwaway, confirm green.
- Marks are exactly `present | late | absent | excused`. Sources are exactly `register | parent | office`.

## Review Focus

1. **The roll changes between draft and submit.** A child joins the class after the draft is saved; submit must refuse because that child has no mark, counting against the roll as it is at that moment — not against `expected_count`. Test in Task 3.
2. **A child leaves the class mid-evening.** Marks already written for a child no longer on roll must not block submission, and must not vanish from the log. Test in Task 3.
3. **Two teachers submit the same class at once.** `UNIQUE (class_id, on_date)` will raise on the second insert; it must be an upsert, not a crash the teacher sees. Test in Task 2.
4. **A date on a closure boundary.** `madrasah_closures` ranges are inclusive at both ends; a register on the first and last day of a closure must be not-due. Off-by-one here silently chases teachers during half term. Test in Task 1.
5. **`register_days` missing or empty.** It must mean *no register is due*, never *every day is due*. A missing setting that makes the system chase 70 classes every Sunday is worse than one that chases nobody. Test in Task 1.

---

## File Structure

| File | Responsibility |
|---|---|
| `db/095_when_a_register_is_due.sql` | `madrasah_settings`, `register_days()`, `register_due()` |
| `db/096_the_register_and_its_history.sql` | `madrasah_registers`, `madrasah_attendance_log` |
| `db/097_draft_then_submit.sql` | `save_register_draft`, `submit_register`, `mark_register` rewrite, `record_parent_absence` |
| `db/098_what_was_missed_and_what_it_said.sql` | `registers_missing`, `my_registers_outstanding`, `register_history` |
| `db/099_the_guard_finds_its_own_tables.sql` | Widen `madrasah_notice_matches_schema()` to discover tables |
| `db/100_the_digest_counts_registers.sql` | `outstanding_summary()` gains missed registers |
| `db/101_today_counts_registers.sql` | `madrasah_today()` gains a missed-registers item |
| `tools/build_privacy_page.py` | Notice v1.6 — describes the log and the register |
| `tools/register_module.js` | Draft/submit UI, the office's missed-register and history panels; regenerates `portal/register/app.js` |
| `portal/index.html`, `portal/app.js` | Teacher landing prompt |
| `_test/register_test.py` | Extended |
| `_test/portal_test.py` | Extended for the landing prompt |

---

### Task 1: When a register is due

**Files:**
- Create: `db/095_when_a_register_is_due.sql`

**Interfaces:**
- Consumes: `madrasah_years`, `madrasah_closures`, `madrasah_classes`, `current_masjid()`, `verified_admin()`
- Produces: `register_days() -> text[]`, `register_due(p_class uuid, p_date date) -> jsonb` returning `{due boolean, why text}`, `set_register_days(p_days text[]) -> jsonb`

- [ ] **Step 1: Write the failing check**

Run this in Supabase. It rolls itself back via `raise exception`.

```sql
do $$
declare r text := '';
begin
  begin
    perform public.register_due('00000000-0000-0000-0000-000000000000'::uuid, current_date);
    r := r || E'\n  register_due exists';
  exception when undefined_function then
    r := r || E'\n  register_due DOES NOT EXIST (expected at this step)';
  end;
  raise exception '%', r;
end $$;
```

Expected: `register_due DOES NOT EXIST`.

- [ ] **Step 2: Write the migration**

```sql
--  =====================================================================
--  095 - WHEN A REGISTER IS DUE
--  =====================================================================
--  Until now nothing could answer "was a register missed", because
--  nothing knew which evenings a class runs. madrasah_classes has no
--  days. What the masjid DOES have is an academic year, eight closures,
--  and - decided 28 September - one setting for which weekdays the
--  madrasah runs. One fact, kept once, rather than 70 copies of it on 70
--  classes that would drift apart within a term.

create table if not exists public.madrasah_settings (
  masjid_id  uuid not null references public.masjids(id) on delete cascade,
  key        text not null,
  value      jsonb not null,
  changed_at timestamptz not null default now(),
  changed_by uuid references auth.users(id),
  primary key (masjid_id, key)
);
alter table public.madrasah_settings enable row level security;
revoke all on public.madrasah_settings from anon, authenticated;

--  FAILS CLOSED. No setting means NO register is due, never every day.
--  A missing row that made the system chase 70 classes every Sunday
--  would teach everybody to ignore it inside a week.
create or replace function public.register_days()
returns text[] language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(
    (select array(select jsonb_array_elements_text(value))
       from public.madrasah_settings
      where masjid_id = public.current_masjid() and key = 'register_days'),
    '{}'::text[]);
$$;

create or replace function public.set_register_days(p_days text[])
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_bad text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may '
                    'change when the madrasah runs.' using errcode = '42501';
  end if;
  select d into v_bad from unnest(p_days) d
   where d not in ('mon','tue','wed','thu','fri','sat','sun') limit 1;
  if v_bad is not null then
    raise exception '% is not a day.', v_bad using errcode = '22023';
  end if;
  insert into public.madrasah_settings (masjid_id, key, value, changed_by)
  values (public.current_masjid(), 'register_days', to_jsonb(p_days), auth.uid())
  on conflict (masjid_id, key) do update
    set value = excluded.value, changed_at = now(), changed_by = excluded.changed_by;
  return jsonb_build_object('days', p_days);
end $$;

create or replace function public.register_due(p_class uuid, p_date date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_days text[] := public.register_days();
  v_dow text := lower(to_char(p_date, 'Dy'));
  v_closure text;
begin
  if array_length(v_days, 1) is null then
    return jsonb_build_object('due', false,
      'why', 'Nobody has said which evenings the madrasah runs yet.');
  end if;
  if not exists (select 1 from public.madrasah_years y
                  where y.masjid_id = v_masjid and y.is_current
                    and p_date between y.starts_on and y.ends_on) then
    return jsonb_build_object('due', false,
      'why', 'That date is outside the academic year.');
  end if;
  if not (v_dow = any(v_days)) then
    return jsonb_build_object('due', false,
      'why', 'The madrasah does not run on a ' || to_char(p_date, 'Day') || '.');
  end if;
  --  INCLUSIVE AT BOTH ENDS, which is how madrasah_closures is written.
  select c.name into v_closure from public.madrasah_closures c
   where c.masjid_id = v_masjid and p_date between c.starts_on and c.ends_on
   limit 1;
  if v_closure is not null then
    return jsonb_build_object('due', false, 'why', v_closure || '.');
  end if;
  if not exists (select 1 from public.madrasah_classes c
                  where c.id = p_class and c.masjid_id = v_masjid and c.is_active
                    and exists (select 1 from public.madrasah_pupil_classes pc
                                  join public.madrasah_pupils p on p.id = pc.pupil_id
                                 where pc.class_id = c.id and p.left_on is null
                                   and p.status = 'on_roll')) then
    return jsonb_build_object('due', false,
      'why', 'That class is not running, or has nobody on its roll.');
  end if;
  return jsonb_build_object('due', true, 'why', '');
end $$;

revoke all on function public.register_days() from public, anon;
revoke all on function public.register_due(uuid, date) from public, anon;
revoke all on function public.set_register_days(text[]) from public, anon;
grant execute on function public.register_days() to authenticated;
grant execute on function public.register_due(uuid, date) to authenticated;
grant execute on function public.set_register_days(text[]) to authenticated;
```

- [ ] **Step 3: Apply it**

Apply via the Supabase MCP tool against project `phenbhmobxwyvdeshvqw`.

- [ ] **Step 4: Set the running days and prove the boundary cases**

Set the days first (as an admin, via `set_config` claims as the other test blocks do), then:

```sql
do $$
declare
  v_masjid uuid := 'f1a55e9e-2215-4831-b9b9-c257e9b1fe0e';
  v_class uuid; r text := ''; d jsonb; v_start date;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','dc998709-ceec-4a04-a56f-187bca229ff1',
      'role','authenticated','aal','aal2',
      'app_metadata', json_build_object('masjid_id', v_masjid))::text, true);

  select id into v_class from public.madrasah_classes
   where masjid_id = v_masjid and is_active limit 1;

  --  EMPTY SETTING MEANS NOTHING IS DUE. Review Focus 5.
  delete from public.madrasah_settings
   where masjid_id = v_masjid and key = 'register_days';
  d := public.register_due(v_class, current_date);
  r := r || E'\n  no setting      due=' || (d->>'due') || '  ' || (d->>'why');

  perform public.set_register_days(array['mon','tue','wed','thu','fri']);

  --  A SUNDAY IS NOT DUE.
  d := public.register_due(v_class, (date_trunc('week', current_date) + 6)::date);
  r := r || E'\n  sunday          due=' || (d->>'due') || '  ' || (d->>'why');

  --  BOTH ENDS OF A CLOSURE ARE INSIDE IT. Review Focus 4.
  select starts_on into v_start from public.madrasah_closures
   where masjid_id = v_masjid and ends_on > starts_on limit 1;
  d := public.register_due(v_class, v_start);
  r := r || E'\n  closure day 1   due=' || (d->>'due') || '  ' || (d->>'why');
  d := public.register_due(v_class,
        (select ends_on from public.madrasah_closures
          where masjid_id = v_masjid and starts_on = v_start limit 1));
  r := r || E'\n  closure last    due=' || (d->>'due') || '  ' || (d->>'why');

  --  OUTSIDE THE ACADEMIC YEAR.
  d := public.register_due(v_class, current_date + interval '3 years');
  r := r || E'\n  outside year    due=' || (d->>'due') || '  ' || (d->>'why');

  raise exception '%', r;
end $$;
```

Expected: `due=false` on all five, each with its own reason. The `raise exception` rolls the settings change back, so re-apply `set_register_days` for real afterwards.

- [ ] **Step 5: Set the days for real**

```sql
-- as an admin
select public.set_register_days(array['mon','tue','wed','thu','fri']);
```

Confirm the masjid actually runs Mon–Fri before committing to it; 36 of 41 staff are recorded Mon–Fri or Mon–Sat.

- [ ] **Step 6: Commit**

```bash
git add db/095_when_a_register_is_due.sql
git commit -m "A register is due on a running day, in term, outside a closure"
```

---

### Task 2: The register, and everything it has ever said

**Files:**
- Create: `db/096_the_register_and_its_history.sql`

**Interfaces:**
- Consumes: Task 1's `register_due()`
- Produces: tables `madrasah_registers` and `madrasah_attendance_log`; trigger function `log_attendance_change()`

- [ ] **Step 1: Write the failing check**

```sql
select to_regclass('public.madrasah_attendance_log') as log,
       to_regclass('public.madrasah_registers')      as reg;
```

Expected: both `null`.

- [ ] **Step 2: Write the migration**

```sql
--  =====================================================================
--  096 - THE REGISTER, AND EVERYTHING IT HAS EVER SAID
--  =====================================================================
--  madrasah_attendance is UNIQUE (pupil_id, on_date) and is updated in
--  place, so a mark changed is a mark gone. For a Tuesday that is fine.
--  For "where was this child on the evening in question", which is what
--  a safeguarding enquiry asks, "it says present and we cannot tell you
--  whether it always did" is not an answer.
--
--  So: attendance stays the CURRENT state and every screen keeps reading
--  it unchanged. The log holds what it used to say.

create table if not exists public.madrasah_registers (
  id             uuid primary key default gen_random_uuid(),
  masjid_id      uuid not null references public.masjids(id) on delete cascade,
  class_id       uuid not null references public.madrasah_classes(id) on delete cascade,
  on_date        date not null,
  state          text not null default 'draft' check (state in ('draft','submitted')),
  expected_count int  not null default 0,   --  what was true then. NOT what submit checks.
  marked_count   int  not null default 0,
  submitted_by   uuid references auth.users(id),
  submitted_at   timestamptz,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (class_id, on_date)
);
alter table public.madrasah_registers enable row level security;
revoke all on public.madrasah_registers from anon, authenticated;

--  APPEND ONLY. pupil_id cascades exactly as madrasah_attendance does, so
--  the log is deleted with the child three years after they leave and the
--  notice's promise holds without a purge rule of its own.
create table if not exists public.madrasah_attendance_log (
  id         uuid primary key default gen_random_uuid(),
  masjid_id  uuid not null references public.masjids(id) on delete cascade,
  pupil_id   uuid not null references public.madrasah_pupils(id) on delete cascade,
  class_id   uuid references public.madrasah_classes(id) on delete set null,
  on_date    date not null,
  mark       text not null,
  reason     text,
  source     text not null,
  was_mark   text,          --  null on the first mark of the evening
  was_reason text,
  was_source text,
  written_by uuid references auth.users(id),
  written_at timestamptz not null default now()
);
alter table public.madrasah_attendance_log enable row level security;
revoke all on public.madrasah_attendance_log from anon, authenticated;

create index if not exists madrasah_attendance_log_find
  on public.madrasah_attendance_log (class_id, on_date, written_at desc);

--  THE LOG IS WRITTEN BY A TRIGGER, NOT BY THE CALLER.
--  Every path that touches attendance - the register, the office, a
--  correction, anything added later - is logged without having to
--  remember to. A log you have to remember to write is a log with holes.
create or replace function public.log_attendance_change()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
begin
  insert into public.madrasah_attendance_log
    (masjid_id, pupil_id, class_id, on_date, mark, reason, source,
     was_mark, was_reason, was_source, written_by)
  values (new.masjid_id, new.pupil_id, new.class_id, new.on_date,
          new.mark, new.reason, new.source,
          case when tg_op = 'UPDATE' then old.mark   end,
          case when tg_op = 'UPDATE' then old.reason end,
          case when tg_op = 'UPDATE' then old.source end,
          auth.uid());
  return new;
end $$;

drop trigger if exists madrasah_attendance_logged on public.madrasah_attendance;
create trigger madrasah_attendance_logged
  after insert or update on public.madrasah_attendance
  for each row execute function public.log_attendance_change();
```

- [ ] **Step 3: Apply it**

- [ ] **Step 4: Prove the trigger logs a change, and that a second submit upserts**

```sql
do $$
declare
  v_masjid uuid := 'f1a55e9e-2215-4831-b9b9-c257e9b1fe0e';
  v_pupil uuid; v_class uuid; r text := ''; n int;
begin
  select pc.pupil_id, pc.class_id into v_pupil, v_class
    from public.madrasah_pupil_classes pc limit 1;

  insert into public.madrasah_attendance
    (masjid_id, pupil_id, class_id, on_date, mark, source)
  values (v_masjid, v_pupil, v_class, current_date, 'absent', 'register')
  on conflict (pupil_id, on_date) do update set mark = 'absent';

  update public.madrasah_attendance set mark = 'present'
   where pupil_id = v_pupil and on_date = current_date;

  select count(*) into n from public.madrasah_attendance_log
   where pupil_id = v_pupil and on_date = current_date;
  r := r || E'\n  log rows after two writes: ' || n || ' (expect 2)';

  select was_mark into r from public.madrasah_attendance_log
   where pupil_id = v_pupil and on_date = current_date
     and was_mark is not null limit 1;
  r := coalesce(r, '(null)');
  r := E'\n  the change records what it replaced: ' || r;

  --  REVIEW FOCUS 3: a second register row for the same class and date
  --  must upsert rather than raise at the teacher.
  insert into public.madrasah_registers (masjid_id, class_id, on_date)
  values (v_masjid, v_class, current_date)
  on conflict (class_id, on_date) do update set updated_at = now();
  insert into public.madrasah_registers (masjid_id, class_id, on_date)
  values (v_masjid, v_class, current_date)
  on conflict (class_id, on_date) do update set updated_at = now();
  r := r || E'\n  two inserts for one class+date: upserted, no error';

  raise exception '%', r;
end $$;
```

Expected: 2 log rows, `was_mark = absent`, no error on the second register insert.

- [ ] **Step 5: Commit**

```bash
git add db/096_the_register_and_its_history.sql
git commit -m "The register is a record, and the log keeps what it used to say"
```

---

### Task 3: Draft, then submit

**Files:**
- Create: `db/097_draft_then_submit.sql`

**Interfaces:**
- Consumes: Task 1 `register_due()`, Task 2 tables
- Produces: `save_register_draft(uuid, date, jsonb) -> jsonb`, `submit_register(uuid, date) -> jsonb`, `record_parent_absence(uuid, date, text, text) -> jsonb`; `mark_register()` rewritten to `{marked, parent_reports_kept, submitted, missing}`

- [ ] **Step 1: Write the failing check**

```sql
do $$
declare r text := '';
begin
  begin
    perform public.submit_register(
      '00000000-0000-0000-0000-000000000000'::uuid, current_date);
  exception
    when undefined_function then r := 'submit_register DOES NOT EXIST (expected)';
    when others then r := 'exists: ' || sqlerrm;
  end;
  raise exception '%', r;
end $$;
```

Expected: `DOES NOT EXIST`.

- [ ] **Step 2: Write the migration**

```sql
--  =====================================================================
--  097 - DRAFT, THEN SUBMIT
--  =====================================================================
--  A register is not taken until every child on the roll carries a mark.
--  But a teacher marking ten children on a phone gets interrupted, and
--  all-or-nothing would lose seven marks to answer a door. So: marks
--  save as they are made, and SUBMIT is the thing that demands a full
--  register.
--
--  Submit counts against the roll AS IT IS AT THAT MOMENT, never against
--  madrasah_registers.expected_count. A child can join the class between
--  the draft and the submit, and a stored number would call a register
--  complete that is missing the newest child on the roll.

create or replace function public.save_register_draft(
  p_class uuid, p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_gate jsonb; v_m jsonb; v_pupil uuid; v_mark text;
  v_n int := 0; v_kept int := 0; v_on_roll int; v_marked int;
begin
  if not public.may_take_register(p_class) then
    raise exception 'That is not one of your classes.' using errcode = '42501';
  end if;

  v_gate := public.attendance_permitted();
  if not (v_gate ->> 'permitted')::boolean then
    raise exception '%', v_gate ->> 'why' using errcode = '42501';
  end if;

  if p_date > current_date then
    raise exception 'A register cannot be taken for a day that has not happened.'
      using errcode = '22023';
  end if;
  if p_date < current_date - 14 and not public.verified_madrasah() then
    raise exception 'That evening is more than a fortnight ago. Ask the office '
                    'to correct it, so the record says it was corrected rather '
                    'than taken.' using errcode = '22023';
  end if;

  for v_m in select * from jsonb_array_elements(p_marks) loop
    v_pupil := (v_m ->> 'pupil_id')::uuid;
    v_mark  := v_m ->> 'mark';
    if v_pupil is null or v_mark is null then continue; end if;

    if not exists (select 1 from public.madrasah_pupil_classes pc
                    join public.madrasah_pupils p on p.id = pc.pupil_id
                   where pc.pupil_id = v_pupil and pc.class_id = p_class
                     and p.masjid_id = v_masjid) then
      continue;
    end if;

    --  A PARENT'S WORD IS NOT OVERWRITTEN BY A TICK. Unchanged from 084.
    if exists (select 1 from public.madrasah_attendance a
                where a.pupil_id = v_pupil and a.on_date = p_date
                  and a.source = 'parent')
       and v_mark not in ('present','late') then
      v_kept := v_kept + 1;
      continue;
    end if;

    insert into public.madrasah_attendance
      (masjid_id, pupil_id, class_id, on_date, mark, reason, source, marked_by)
    values (v_masjid, v_pupil, p_class, p_date, v_mark,
            nullif(btrim(v_m ->> 'reason'), ''),
            case when public.verified_madrasah() and not public.is_teacher()
                 then 'office' else 'register' end,
            auth.uid())
    on conflict (pupil_id, on_date) do update
      set mark = excluded.mark, reason = excluded.reason,
          class_id = excluded.class_id, source = excluded.source,
          marked_by = excluded.marked_by, marked_at = now();
    v_n := v_n + 1;
  end loop;

  select count(*) into v_on_roll
    from public.madrasah_pupil_classes pc
    join public.madrasah_pupils p on p.id = pc.pupil_id
   where pc.class_id = p_class and p.left_on is null and p.status = 'on_roll';
  select count(*) into v_marked
    from public.madrasah_attendance a
    join public.madrasah_pupil_classes pc on pc.pupil_id = a.pupil_id
    join public.madrasah_pupils p on p.id = a.pupil_id
   where pc.class_id = p_class and a.on_date = p_date
     and p.left_on is null and p.status = 'on_roll';

  insert into public.madrasah_registers
    (masjid_id, class_id, on_date, expected_count, marked_count)
  values (v_masjid, p_class, p_date, v_on_roll, v_marked)
  on conflict (class_id, on_date) do update
    set expected_count = excluded.expected_count,
        marked_count   = excluded.marked_count,
        updated_at     = now();

  return jsonb_build_object('marked', v_n, 'parent_reports_kept', v_kept,
                            'on_roll', v_on_roll, 'has_mark', v_marked,
                            'missing', greatest(v_on_roll - v_marked, 0));
end $$;

create or replace function public.submit_register(p_class uuid, p_date date)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_on_roll int; v_marked int; v_missing int;
begin
  if not public.may_take_register(p_class) then
    raise exception 'That is not one of your classes.' using errcode = '42501';
  end if;

  --  AGAINST THE ROLL AS IT IS NOW. Not expected_count.
  select count(*) into v_on_roll
    from public.madrasah_pupil_classes pc
    join public.madrasah_pupils p on p.id = pc.pupil_id
   where pc.class_id = p_class and p.left_on is null and p.status = 'on_roll';
  select count(*) into v_marked
    from public.madrasah_attendance a
    join public.madrasah_pupil_classes pc on pc.pupil_id = a.pupil_id
    join public.madrasah_pupils p on p.id = a.pupil_id
   where pc.class_id = p_class and a.on_date = p_date
     and p.left_on is null and p.status = 'on_roll';

  v_missing := greatest(v_on_roll - v_marked, 0);
  if v_on_roll = 0 then
    raise exception 'That class has nobody on its roll.' using errcode = '22023';
  end if;
  if v_missing > 0 then
    raise exception '% of % children have no mark yet. Every child needs one '
                    'before the register can be handed in.', v_missing, v_on_roll
      using errcode = '22023';
  end if;

  insert into public.madrasah_registers
    (masjid_id, class_id, on_date, state, expected_count, marked_count,
     submitted_by, submitted_at)
  values (v_masjid, p_class, p_date, 'submitted', v_on_roll, v_marked,
          auth.uid(), now())
  on conflict (class_id, on_date) do update
    set state = 'submitted', expected_count = excluded.expected_count,
        marked_count = excluded.marked_count,
        submitted_by = excluded.submitted_by,
        submitted_at = now(), updated_at = now();

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'register_submitted',
          jsonb_build_object('class', p_class, 'on_date', p_date,
                             'children', v_on_roll,
                             'by', case when public.verified_madrasah()
                                        then 'office' else 'teacher' end));

  return jsonb_build_object('submitted', true, 'children', v_on_roll);
end $$;

--  KEPT, AND NOT A THIN WRAPPER. The current Register screen calls this
--  and makes partial saves; if it started refusing them the screen would
--  break the moment this lands. So it saves, then TRIES to submit, and
--  says which happened.
create or replace function public.mark_register(
  p_class uuid, p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_saved jsonb; v_sub jsonb := null;
begin
  v_saved := public.save_register_draft(p_class, p_date, p_marks);
  if (v_saved ->> 'missing')::int = 0 then
    begin
      v_sub := public.submit_register(p_class, p_date);
    exception when others then v_sub := null;
    end;
  end if;
  return v_saved || jsonb_build_object('submitted', v_sub is not null);
end $$;

--  THE OFFICE TAKES A PHONE CALL. Spec 2's parent login calls this same
--  function; it adds a front door, not a second mechanism.
create or replace function public.record_parent_absence(
  p_pupil uuid, p_date date, p_mark text, p_reason text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid(); v_class uuid;
begin
  if not public.verified_madrasah() then
    raise exception 'Only the madrasah office may record what a parent has said.'
      using errcode = '42501';
  end if;
  if p_mark not in ('absent','excused','late') then
    raise exception 'A parent can report a child away or late, not present.'
      using errcode = '22023';
  end if;
  select pc.class_id into v_class from public.madrasah_pupil_classes pc
   where pc.pupil_id = p_pupil limit 1;

  insert into public.madrasah_attendance
    (masjid_id, pupil_id, class_id, on_date, mark, reason, source, marked_by)
  values (v_masjid, p_pupil, v_class, p_date, p_mark,
          nullif(btrim(p_reason), ''), 'parent', auth.uid())
  on conflict (pupil_id, on_date) do update
    set mark = excluded.mark, reason = excluded.reason,
        source = 'parent', marked_by = excluded.marked_by, marked_at = now();

  return jsonb_build_object('recorded', true);
end $$;

revoke all on function public.save_register_draft(uuid, date, jsonb) from public, anon;
revoke all on function public.submit_register(uuid, date) from public, anon;
revoke all on function public.record_parent_absence(uuid, date, text, text) from public, anon;
grant execute on function public.save_register_draft(uuid, date, jsonb) to authenticated;
grant execute on function public.submit_register(uuid, date) to authenticated;
grant execute on function public.record_parent_absence(uuid, date, text, text) to authenticated;
```

- [ ] **Step 3: Apply it**

- [ ] **Step 4: Prove an incomplete register is refused, and the roll-change cases**

Note: `attendance_permitted()` currently refuses everything because no family has been told. Run this block with a throwaway `madrasah_parent_notices` row for every family inside the transaction, then let the `raise exception` roll it back.

```sql
do $$
declare
  v_masjid uuid := 'f1a55e9e-2215-4831-b9b9-c257e9b1fe0e';
  v_class uuid; v_pupil uuid; r text := ''; d jsonb;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','dc998709-ceec-4a04-a56f-187bca229ff1',
      'role','authenticated','aal','aal2',
      'app_metadata', json_build_object('masjid_id', v_masjid))::text, true);

  --  Throwaway: satisfy the parents-told gate for the length of this block.
  insert into public.madrasah_parent_notices
    (masjid_id, household_id, kind, notice_version, how, told_on, recorded_by)
  select v_masjid, h.id, 'attendance_notice', '1.5', 'letter', current_date,
         auth.uid()
    from public.madrasah_households h where h.masjid_id = v_masjid
  on conflict do nothing;

  select c.id into v_class from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active
     and (select count(*) from public.madrasah_pupil_classes pc
           join public.madrasah_pupils p on p.id = pc.pupil_id
          where pc.class_id = c.id and p.left_on is null
            and p.status='on_roll') between 2 and 12
   limit 1;

  --  ONE CHILD SHORT: must refuse and say how many.
  select pc.pupil_id into v_pupil from public.madrasah_pupil_classes pc
   where pc.class_id = v_class limit 1;
  perform public.save_register_draft(v_class, current_date,
    jsonb_build_array(jsonb_build_object('pupil_id', v_pupil, 'mark', 'present')));
  begin
    perform public.submit_register(v_class, current_date);
    r := r || E'\n  WRONG: an incomplete register submitted';
  exception when others then
    r := r || E'\n  ok  incomplete refused: ' || left(sqlerrm, 78);
  end;

  --  ALL MARKED: must submit.
  perform public.save_register_draft(v_class, current_date,
    (select jsonb_agg(jsonb_build_object('pupil_id', pc.pupil_id, 'mark','present'))
       from public.madrasah_pupil_classes pc
       join public.madrasah_pupils p on p.id = pc.pupil_id
      where pc.class_id = v_class and p.left_on is null and p.status='on_roll'));
  d := public.submit_register(v_class, current_date);
  r := r || E'\n  ok  complete submitted, children=' || (d->>'children');

  raise exception '%', r;
end $$;
```

Expected: the refusal names the number missing; the complete one submits.

- [ ] **Step 5: Prove the roll-change cases and that submitting is not a lock**

Review Focus 1, 2 and the spec's "a submitted register can still be corrected".
Same throwaway-notices preamble as Step 4.

```sql
do $$
declare
  v_masjid uuid := 'f1a55e9e-2215-4831-b9b9-c257e9b1fe0e';
  v_class uuid; v_new uuid; v_leaver uuid; r text := ''; st text;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub','dc998709-ceec-4a04-a56f-187bca229ff1',
      'role','authenticated','aal','aal2',
      'app_metadata', json_build_object('masjid_id', v_masjid))::text, true);
  insert into public.madrasah_parent_notices
    (masjid_id, household_id, kind, notice_version, how, told_on, recorded_by)
  select v_masjid, h.id, 'attendance_notice', '1.5', 'letter', current_date, auth.uid()
    from public.madrasah_households h where h.masjid_id = v_masjid
  on conflict do nothing;

  select c.id into v_class from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active limit 1;

  --  Mark everyone, submit.
  perform public.save_register_draft(v_class, current_date,
    (select jsonb_agg(jsonb_build_object('pupil_id', pc.pupil_id, 'mark','present'))
       from public.madrasah_pupil_classes pc
       join public.madrasah_pupils p on p.id = pc.pupil_id
      where pc.class_id = v_class and p.left_on is null and p.status='on_roll'));
  perform public.submit_register(v_class, current_date);
  r := r || E'\n  submitted once';

  --  REVIEW FOCUS 1: a child joins the class AFTER the submit. Submitting
  --  again must refuse, because it counts against the roll as it is now.
  select p.id into v_new from public.madrasah_pupils p
   where p.masjid_id = v_masjid and p.left_on is null and p.status='on_roll'
     and not exists (select 1 from public.madrasah_pupil_classes pc
                      where pc.pupil_id = p.id and pc.class_id = v_class)
   limit 1;
  insert into public.madrasah_pupil_classes (masjid_id, pupil_id, class_id)
  values (v_masjid, v_new, v_class);
  begin
    perform public.submit_register(v_class, current_date);
    r := r || E'\n  WRONG: submitted with a newly joined child unmarked';
  exception when others then
    r := r || E'\n  ok    new child blocks it: ' || left(sqlerrm, 60);
  end;

  --  REVIEW FOCUS 2: a child leaves. Their mark stays in the log and must
  --  not block the submit.
  update public.madrasah_pupils set left_on = current_date where id = v_new;
  perform public.submit_register(v_class, current_date);
  r := r || E'\n  ok    leaver does not block it';
  r := r || E'\n  leaver marks still in the log: '
         || (select count(*)::text from public.madrasah_attendance_log
              where pupil_id = v_new and on_date = current_date);

  --  SUBMITTING IS NOT A LOCK. A correction after handing in still saves,
  --  and the register stays submitted.
  perform public.save_register_draft(v_class, current_date,
    jsonb_build_array(jsonb_build_object(
      'pupil_id', (select pc.pupil_id from public.madrasah_pupil_classes pc
                    where pc.class_id = v_class limit 1),
      'mark', 'late')));
  select state into st from public.madrasah_registers
   where class_id = v_class and on_date = current_date;
  r := r || E'\n  after a correction the state is: ' || st || ' (expect submitted)';

  raise exception '%', r;
end $$;
```

- [ ] **Step 6: Commit**

```bash
git add db/097_draft_then_submit.sql
git commit -m "Every child carries a mark before a register is handed in"
```

---

### Task 4: What was missed, and what it said

**Files:**
- Create: `db/098_what_was_missed_and_what_it_said.sql`

**Interfaces:**
- Consumes: Tasks 1–3
- Produces: `registers_missing(date, date) -> jsonb`, `my_registers_outstanding() -> jsonb`, `register_history(uuid, date) -> jsonb`

- [ ] **Step 1: Write the failing check**

```sql
select to_regprocedure('public.registers_missing(date,date)') as missing;
```

Expected: `null`.

- [ ] **Step 2: Write the migration**

```sql
--  =====================================================================
--  098 - WHAT WAS MISSED, AND WHAT IT SAID
--  =====================================================================
--  A register taken was always visible. A register NOT taken was not,
--  which is the half that matters: a class could go three weeks unmarked
--  and the only way to find out was to open the right screen on the
--  right evening.

create or replace function public.registers_missing(
  p_from date default (current_date - 14), p_to date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid(); v_rows jsonb;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.on_date desc, x.name), '[]'::jsonb)
    into v_rows
  from (
    select c.id as class_id, c.name, d::date as on_date,
           btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name)) as teacher
      from generate_series(p_from, p_to, interval '1 day') d
      cross join public.madrasah_classes c
      left join public.madrasah_staff st on st.id = c.main_teacher_id
     where c.masjid_id = v_masjid and c.is_active
       and (public.register_due(c.id, d::date) ->> 'due')::boolean
       and not exists (select 1 from public.madrasah_registers rg
                        where rg.class_id = c.id and rg.on_date = d::date
                          and rg.state = 'submitted')
  ) x;
  return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to,
                            'count', jsonb_array_length(v_rows), 'rows', v_rows);
end $$;

--  THE TEACHER'S OWN. Their only channel is this portal - a teacher login
--  holds no email address - so it has to be on the page they land on.
create or replace function public.my_registers_outstanding()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_staff uuid := public.my_staff_id(); v_rows jsonb;
begin
  if v_staff is null then
    return jsonb_build_object('allowed', true, 'count', 0, 'rows', '[]'::jsonb);
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.on_date desc, x.name), '[]'::jsonb)
    into v_rows
  from (
    select c.id as class_id, c.name, d::date as on_date
      from generate_series(current_date - 14, current_date, interval '1 day') d
      cross join public.madrasah_classes c
     where c.is_active and public.teaches_class(c.id)
       and (public.register_due(c.id, d::date) ->> 'due')::boolean
       and not exists (select 1 from public.madrasah_registers rg
                        where rg.class_id = c.id and rg.on_date = d::date
                          and rg.state = 'submitted')
  ) x;
  return jsonb_build_object('allowed', true,
                            'count', jsonb_array_length(v_rows), 'rows', v_rows);
end $$;

--  WHAT IT USED TO SAY. Office only: a change history names children and
--  is a record about them, not a working list.
create or replace function public.register_history(p_class uuid, p_date date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.written_at desc), '[]'::jsonb)
    into v_rows
  from (
    select btrim(p.first_name || ' ' || p.last_name) as child,
           l.mark, l.reason, l.source,
           l.was_mark, l.was_reason, l.was_source,
           l.written_at,
           coalesce(pr.full_name, '(system)') as written_by
      from public.madrasah_attendance_log l
      join public.madrasah_pupils p on p.id = l.pupil_id
      left join public.profiles pr on pr.id = l.written_by
     where l.class_id = p_class and l.on_date = p_date
  ) x;
  return jsonb_build_object('allowed', true, 'rows', v_rows);
end $$;

revoke all on function public.registers_missing(date, date) from public, anon;
revoke all on function public.my_registers_outstanding() from public, anon;
revoke all on function public.register_history(uuid, date) from public, anon;
grant execute on function public.registers_missing(date, date) to authenticated;
grant execute on function public.my_registers_outstanding() to authenticated;
grant execute on function public.register_history(uuid, date) to authenticated;
```

- [ ] **Step 3: Apply it**

- [ ] **Step 4: Prove a teacher sees only their own outstanding, and an admin sees all**

Run `my_registers_outstanding()` under the test teacher's claims
(`42a0f447-f2b6-4a31-86c3-8bc2bddaad1b`, `aal1`) and confirm every row's
`class_id` is one `teaches_class()` returns true for. Run `registers_missing()`
under the same claims and confirm `allowed:false`.

- [ ] **Step 5: Commit**

```bash
git add db/098_what_was_missed_and_what_it_said.sql
git commit -m "A register not taken is now as visible as one that was"
```

---

### Task 5: The guard finds its own tables

**Files:**
- Create: `db/099_the_guard_finds_its_own_tables.sql`

**Interfaces:**
- Consumes: `madrasah_notice_matches_schema()` as it stands
- Produces: the same function, with `watched` discovered rather than listed

- [ ] **Step 1: Show the hard-coded list**

```sql
select substr(pg_get_functiondef(oid),
              position('watched text[]' in pg_get_functiondef(oid)), 260)
  from pg_proc where proname = 'madrasah_notice_matches_schema';
```

Expected: a literal array of five table names.

- [ ] **Step 2: Write the migration**

Read the live definition and replace the literal `watched` assignment with a
query, the same splice-and-refuse technique `db/081` and `db/094` use:

```sql
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='madrasah_notice_matches_schema';
  if v_def is null then raise exception '099: the guard is not there to patch.'; end if;
  if position('information_schema.key_column_usage' in v_def) > 0 then
    raise notice '099: already discovering.'; return;
  end if;

  v_new := replace(v_def,
$a$  watched text[] := array[
    'madrasah_pupils', 'madrasah_households', 'madrasah_guardians',
    'madrasah_attendance', 'madrasah_concerns'
  ];$a$,
$b$  --  DISCOVERED, NOT LISTED. The literal five tables that used to be
  --  here meant a new table holding children's data was invisible to
  --  this guard until somebody remembered to add it - which is the exact
  --  failure the guard exists to prevent. db/080 made the minimisation
  --  guard discover its list functions for the same reason.
  --
  --  Anything that references madrasah_pupils is about a child, plus the
  --  family tables which are about a child's household.
  watched text[] := (
    select array_agg(distinct t) from (
      select 'madrasah_pupils'::text as t
      union select 'madrasah_households'
      union select 'madrasah_guardians'
      union select cl.relname::text
        from pg_constraint con
        join pg_class cl on cl.oid = con.conrelid
        join pg_class rf on rf.oid = con.confrelid
        join pg_namespace ns on ns.oid = cl.relnamespace
       where con.contype = 'f' and ns.nspname = 'public'
         and rf.relname = 'madrasah_pupils'
    ) z);$b$);

  if v_new = v_def then
    raise exception '099: the watched list did not match. NOT changed.';
  end if;
  execute v_new;
end $mig$;
```

- [ ] **Step 3: Apply it, then confirm the new tables are now watched**

```sql
select e.value->>'ok' as ok, left(e.value->>'detail', 200) as detail
  from jsonb_array_elements(public.health_check()->'checks') e
 where e.value->>'check' = 'notice_matches_the_schema';
```

Expected: **`ok = false`**, naming `madrasah_attendance_log` and
`madrasah_registers` columns as undescribed. That failure is the guard working;
Task 6 makes it pass.

- [ ] **Step 4: Prove it catches a table nobody added by hand**

```sql
do $$
declare r text;
begin
  create table public.zz_throwaway_child_thing (
    id uuid primary key default gen_random_uuid(),
    pupil_id uuid references public.madrasah_pupils(id),
    something_private text);
  select left(e.value->>'detail', 150) into r
    from jsonb_array_elements(public.health_check()->'checks') e
   where e.value->>'check' = 'notice_matches_the_schema';
  raise exception 'with a throwaway table: %', r;
end $$;
```

Expected: the detail names `zz_throwaway_child_thing.something_private`. The
`raise exception` drops the table with the transaction.

- [ ] **Step 5: Commit**

```bash
git add db/099_the_guard_finds_its_own_tables.sql
git commit -m "The notice guard finds its own tables instead of being told"
```

---

### Task 6: Notice v1.6

**Files:**
- Modify: `tools/build_privacy_page.py`
- Regenerate: `madrasah-privacy/index.html`
- Modify: `docs/GO-LIVE.md` (v1.5 → v1.6)

**Interfaces:**
- Consumes: Task 5's now-failing guard
- Produces: a notice the guard passes

- [ ] **Step 1: Confirm the guard is failing and read exactly what it names**

```sql
select left(e.value->>'detail', 400)
  from jsonb_array_elements(public.health_check()->'checks') e
 where e.value->>'check' = 'notice_matches_the_schema';
```

Every column it names must be described or the build refuses.

- [ ] **Step 2: Add the entries to `WHAT_WE_HOLD`**

In `tools/build_privacy_page.py`, alongside the attendance entry:

```python
    #  ADDED AT v1.6. The log exists because a mark changed used to be a
    #  mark gone, and "where was this child that evening" is a question
    #  that can be asked years later.
    ("Every change to your child's attendance mark",
     "When a mark is corrected we keep what it said before, who changed "
     "it and when. It is kept for exactly as long as the attendance "
     "record itself and is deleted with it.",
     ["madrasah_attendance_log.mark", "madrasah_attendance_log.reason",
      "madrasah_attendance_log.source", "madrasah_attendance_log.on_date",
      "madrasah_attendance_log.was_mark", "madrasah_attendance_log.was_reason",
      "madrasah_attendance_log.was_source",
      "madrasah_registers.state", "madrasah_registers.on_date",
      "madrasah_registers.expected_count", "madrasah_registers.marked_count"]),
```

- [ ] **Step 3: Bump the version**

```python
VERSION = "1.6"
```

- [ ] **Step 4: Regenerate and confirm the guard passes**

```bash
ARTICLE_9_CONDITION=both python3 tools/build_privacy_page.py
```

Then re-run the `health_check()` query from Step 1. Expected: `ok = true`.

- [ ] **Step 5: Update the go-live checklist**

Replace every "v1.5" in `docs/GO-LIVE.md` section B1 with "v1.6", and add one
line saying the change is the attendance history.

- [ ] **Step 6: Commit**

```bash
git add tools/build_privacy_page.py madrasah-privacy/index.html docs/GO-LIVE.md
git commit -m "Notice v1.6: the attendance history is described"
```

---

### Task 7: The Monday digest counts registers

**Files:**
- Create: `db/100_the_digest_counts_registers.sql`

**Interfaces:**
- Consumes: Task 4 `registers_missing()`
- Produces: `outstanding_summary()` with a `registers_missed` key

- [ ] **Step 1: Confirm it is absent**

```sql
select (public.outstanding_summary('f1a55e9e-2215-4831-b9b9-c257e9b1fe0e')
        ? 'registers_missed') as present;
```

Expected: `false`.

- [ ] **Step 2: Write the migration**

Splice a key into the existing `jsonb_build_object`, refusing if the anchor is
not found:

```sql
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
   where n.nspname='public' and p.proname='outstanding_summary';
  if position('registers_missed' in v_def) > 0 then
    raise notice '100: already there.'; return;
  end if;
  v_new := replace(v_def,
$a$    'generated_at', now()$a$,
$b$    --  ADDED BY 100. A register NOT taken was invisible to everybody:
    --  no trigger, nothing in the notify function, nothing here. A class
    --  could go three weeks unmarked in silence.
    'registers_missed',
      (select count(*) from generate_series(
                (select d from today) - 7, (select d from today) - 1,
                interval '1 day') g
         cross join public.madrasah_classes c
        where c.masjid_id = (select m from me) and c.is_active
          and (public.register_due(c.id, g::date) ->> 'due')::boolean
          and not exists (select 1 from public.madrasah_registers rg
                           where rg.class_id = c.id and rg.on_date = g::date
                             and rg.state = 'submitted')),
    'generated_at', now()$b$);
  if v_new = v_def then
    raise exception '100: could not find generated_at. NOT changed.';
  end if;
  execute v_new;
end $mig$;
```

- [ ] **Step 3: Apply and confirm**

Re-run Step 1's query. Expected: `true`, with a count.

- [ ] **Step 4: Commit**

```bash
git add db/100_the_digest_counts_registers.sql
git commit -m "Last week's missed registers reach the Monday email"
```

---

### Task 8: The Register screen — draft and submit

**Files:**
- Modify: `tools/register_module.js`
- Regenerate: `portal/register/app.js` via `python3 tools/build_register_screen.py`
- Modify: `_test/register_test.py`

**Interfaces:**
- Consumes: `save_register_draft`, `submit_register`
- Produces: a screen with a Save that always works and a Submit gated on completeness

- [ ] **Step 1: Write the failing test**

In `_test/register_test.py`, with a stub where one child of three is unmarked:

```python
    # THE SUBMIT BUTTON IS THE GATE, AND IT IS SHUT UNTIL THE REGISTER IS FULL.
    state = pg.evaluate("""() => {
      var s = document.getElementById('rg-submit');
      var n = document.querySelector('.rg-save-n');
      return s ? {disabled: !!s.disabled,
                  counter: n ? n.textContent : null,
                  unmarkedRows: document.querySelectorAll('.rg-row:not(.is-marked)').length}
               : null;
    }""")
    check(state is not None, "the register has no Hand-in button")
    check(state["disabled"],
          "HAND-IN IS ENABLED WITH A CHILD UNMARKED: %r" % state)
    check(state["unmarkedRows"] > 0,
          "the unmarked child is not distinguishable in the list: %r" % state)
    check(state["counter"] and "not marked yet" in state["counter"],
          "the existing counter does not say what is left: %r" % state)
```

- [ ] **Step 2: Run it and watch it fail**

```bash
python3 _test/register_test.py
```

Expected: FAIL, "the register has no Submit button".

- [ ] **Step 3: Add the Submit button beside the Save that already exists**

**Read `tools/register_module.js` around line 301 first.** The footer is
already there and already counts: `rg-save-n` renders either
"N children are not marked yet" or "Every child is marked", and `#rg-save`
is disabled only when *nothing* is marked. Rows are `<li class="rg-row">`
with `data-pupil`, and a marked row already carries `is-marked`. **Do not
invent a counter or row ids — both exist.**

Change the footer block to add a second button:

```javascript
      var save = '<div class="rg-save">'
        + '<span class="rg-save-n">'
        + (c.unmarked
            ? esc(c.unmarked) + (c.unmarked === 1 ? " child is" : " children are")
              + " not marked yet"
            : "Every child is marked")
        + "</span>"
        + '<button type="button" class="btn" id="rg-save"'
        + (c.unmarked === ROWS.length ? " disabled" : "") + ">Save</button>"
        //  THE GATE. Save always works so an interrupted teacher loses
        //  nothing; handing in is the thing that demands a full register.
        + '<button type="button" class="btn btn-gold" id="rg-submit"'
        + (c.unmarked > 0 ? " disabled" : "") + ">Hand the register in</button>"
        + "</div>";
```

- [ ] **Step 4: Point Save at the draft function and wire Submit**

Replace the RPC name inside `save()`:

```javascript
      sb.rpc("save_register_draft",
             { p_class: OPEN.id, p_date: DATE, p_marks: list })
```

Add the submit handler:

```javascript
    function submitRegister() {
      if (busy || !OPEN) return;
      busy = true; clearFail();
      sb.rpc("submit_register", { p_class: OPEN.id, p_date: DATE })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          say("Register handed in. Thank you.");
          return load().then(function () { if (OPEN) openClass(OPEN.id); });
        })["catch"](function (e) {
          fail("The register was not handed in. "
               + (e && e.message ? e.message : "")
               + " Your marks are saved.");
        })["finally"](function () { busy = false; });
    }
```

And route the click, beside the existing `rg-save` case near line 595:

```javascript
          if (t.id === "rg-submit") { submitRegister(); return; }
```

- [ ] **Step 5: Add the stylesheet rules**

In `portal/register/register.css`, after the `[hidden]` rule. The row class
already exists, so this styles its absence rather than adding a new class:

```css
/*  An unmarked child is the only thing left to do, so it is the only thing
    on the row that draws the eye. .is-marked is already set by the module;
    this styles the rows that do not have it. */
.rg-row:not(.is-marked){background:rgba(198,162,76,.10);
  box-shadow:inset 3px 0 0 var(--gold-ink);}
.rg-save{display:flex;align-items:center;gap:12px;flex-wrap:wrap;}
.rg-save-n{font-weight:700;color:var(--muted);margin-right:auto;}
```

- [ ] **Step 6: Regenerate, build and run the test**

```bash
python3 tools/build_register_screen.py
python3 verify_structure.py && python3 build.py
python3 _test/register_test.py
```

Expected: PASS.

- [ ] **Step 7: Prove the gate can fail**

Temporarily change `s.disabled = (total === 0 || done < total);` to
`s.disabled = false;`, regenerate, run the test, watch it fail, then restore and
confirm green.

- [ ] **Step 8: Screenshot it**

Render the screen at 1440 and 390 with a class one child short, and look at the
image before claiming it works.

- [ ] **Step 9: Commit**

```bash
git add tools/register_module.js portal/register/ _test/register_test.py
git commit -m "Save always works; handing in needs every child marked"
```

---

### Task 9: The teacher is told, on the only channel they have

**Files:**
- Modify: `portal/index.html` (markup + styles)
- Modify: `portal/app.js`
- Modify: `_test/portal_test.py`

**Interfaces:**
- Consumes: Task 4 `my_registers_outstanding()`
- Produces: a prompt on the teacher landing page

- [ ] **Step 1: Write the failing test**

In `_test/portal_test.py`, add `MY_OUTSTANDING` to the stub with two rows, then:

```python
    #  A TEACHER WITH A REGISTER BEHIND THEM IS TOLD ON THE PAGE THEY LAND
    #  ON. It is the only channel they have - their logins hold no email.
    nag = text(pg, "#tc-outstanding")
    check(nag.strip() != "",
          "a teacher with two outstanding registers is told nothing")
    check("2" in nag,
          "the prompt does not say how many are outstanding: %r" % nag)
```

- [ ] **Step 2: Run it and watch it fail**

```bash
python3 _test/portal_test.py
```

Expected: FAIL, "a teacher ... is told nothing".

- [ ] **Step 3: Add the markup**

In `portal/index.html`, immediately after `<div class="md-counts" id="tc-tonight"></div>`:

```html
        <p class="tc-nag" id="tc-outstanding" hidden></p>
```

- [ ] **Step 4: Add the style**

```css
/*  Not an error, and not decoration either. Gold, like every other thing
    on this site that is waiting for somebody. */
.tc-nag{
  margin:0 0 18px;padding:13px 16px;border-radius:12px;
  border:1px solid var(--gold);background:rgba(198,162,76,.10);
  font-size:.99rem;line-height:1.55;color:var(--ink);
}
.tc-nag a{color:var(--brand-700);font-weight:700;}
```

- [ ] **Step 5: Draw it**

In `portal/app.js`, inside the teacher branch after `drawMyClasses()`:

```javascript
          sb.rpc("my_registers_outstanding").then(function (res) {
            if (res.error) return;
            var d = res.data || {}, n = d.count || 0, box = el("tc-outstanding");
            if (!box || !n) return;
            box.innerHTML = "<strong>" + esc(n)
              + (n === 1 ? " register is" : " registers are")
              + " still to hand in.</strong> "
              + "A register taken tomorrow is somebody remembering. "
              + '<a href="register/">Take them now</a>';
            box.hidden = false;
          })["catch"](function () { /* the page is useful without it */ });
```

- [ ] **Step 6: Build and run the test**

```bash
python3 verify_structure.py && python3 build.py
python3 _test/portal_test.py
```

Expected: PASS.

- [ ] **Step 7: Screenshot it and look at it**

- [ ] **Step 8: Commit**

```bash
git add portal/index.html portal/app.js _test/portal_test.py
git commit -m "A teacher with a register behind them is told where they land"
```

---

### Task 10: The office sees it on Today

**Files:**
- Create: `db/101_today_counts_registers.sql`
- Modify: `_test/portal_test.py` (TODAY fixture gains the item)

**Interfaces:**
- Consumes: Task 4 `registers_missing()`
- Produces: a `registers_missed` item in `madrasah_today()`

- [ ] **Step 1: Write the migration**

Splice a new item into `madrasah_today()` after the DBS block, using the same
read-patch-refuse technique, keyed `registers_missed`, tone `bad`, href
`register/`, action `Open the registers`, and wording:

```
title: n || ' register' || (n=1 ? ' was' : 's were') || ' not taken'
said:  'A register not taken is not a register taken late. Nobody was
        recorded as being in that room.'
```

Gate it on `v_admin`, and count over the last 14 days.

- [ ] **Step 2: Apply and confirm it appears**

```sql
select e.value->>'title'
  from jsonb_array_elements(public.madrasah_today()->'items') e
 where e.value->>'key' = 'registers_missed';
```

- [ ] **Step 3: Add the item to the portal test's TODAY fixture and re-run**

`_test/portal_test.py` asserts every fixture item is drawn, so adding it to the
fixture proves the page renders it.

```bash
python3 _test/portal_test.py
```

- [ ] **Step 4: Commit**

```bash
git add db/101_today_counts_registers.sql _test/portal_test.py
git commit -m "Today tells the office which registers were never taken"
```

---

### Task 11: The office sees what was missed, and what it used to say

The spec promises the Registers screen "gains the outstanding list and, per
evening, a history panel drawn from `register_history()`". Nothing else in this
plan builds it — found in self-review.

**Files:**
- Modify: `tools/register_module.js`
- Regenerate: `portal/register/app.js`
- Modify: `_test/register_test.py`

**Interfaces:**
- Consumes: Task 4 `registers_missing(date, date)`, `register_history(uuid, date)`
- Produces: an outstanding panel and a per-evening history panel, office only

- [ ] **Step 1: Write the failing test**

Add `REGISTERS_MISSING` and `HISTORY` fixtures to the office stub in
`_test/register_test.py`, then:

```python
    # THE OFFICE IS TOLD WHAT WAS NEVER TAKEN, not only what is outstanding
    # tonight. A class can go three weeks unmarked and this is where that
    # becomes visible.
    miss = text(pg, "#rg-missing")
    check(miss.strip() != "", "the office is shown no missed registers")
    check(REGISTERS_MISSING["rows"][0]["name"] in miss,
          "the missed list does not name the class: %r" % miss[:140])

    # AND WHAT A MARK USED TO SAY.
    hist = text(pg, "#rg-history")
    check("was" in hist.lower() or "changed" in hist.lower(),
          "the history panel does not show what a mark replaced: %r" % hist[:140])
```

- [ ] **Step 2: Run it and watch it fail**

```bash
python3 _test/register_test.py
```

Expected: FAIL, "the office is shown no missed registers".

- [ ] **Step 3: Draw the outstanding panel on the evening view**

In `tools/register_module.js`, in the evening view built around line 126, after
the class grid and only when `!TEACHER_ONLY`:

```javascript
      //  OFFICE ONLY. A teacher already has their own prompt on the landing
      //  page; showing them the whole madrasah's misses is a list they can
      //  do nothing about.
      if (!TEACHER_ONLY) {
        out.push('<section class="rg-missing" id="rg-missing" hidden></section>');
      }
```

and a draw function:

```javascript
    function drawMissing() {
      var host = el("rg-missing");
      if (!host) return;
      sb.rpc("registers_missing", {}).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        var d = res.data || {}, rows = d.rows || [];
        if (d.allowed === false || !rows.length) { host.hidden = true; return; }
        var i, out = ['<h3>Registers never taken</h3>'
          + '<p class="rg-sub">The last fortnight. A register not taken is '
          + 'not a register taken late \u2014 nobody was recorded as being '
          + 'in that room.</p><ul class="rg-missing-l">'];
        for (i = 0; i < rows.length; i++) {
          out.push("<li><strong>" + esc(rows[i].name) + "</strong> "
            + '<span class="rg-q">' + esc(dateSaid(rows[i].on_date))
            + (rows[i].teacher ? " \u00b7 " + esc(rows[i].teacher) : "")
            + "</span></li>");
        }
        out.push("</ul>");
        host.innerHTML = out.join("");
        host.hidden = false;
      })["catch"](function () { host.hidden = true; });
    }
```

Call `drawMissing()` at the end of the evening render.

- [ ] **Step 4: Draw the history panel inside an open class**

Append to the class panel markup, office only:

```javascript
      if (!TEACHER_ONLY) {
        host.innerHTML += '<section class="rg-history" id="rg-history" hidden></section>';
        drawHistory(c.id);
      }
```

```javascript
    function drawHistory(classId) {
      var host = el("rg-history");
      if (!host) return;
      sb.rpc("register_history", { p_class: classId, p_date: DATE })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {}, rows = d.rows || [], i, out;
          if (d.allowed === false || !rows.length) { host.hidden = true; return; }
          out = ["<h3>What this register has said</h3><ul class=\"rg-hist-l\">"];
          for (i = 0; i < rows.length; i++) {
            out.push("<li><strong>" + esc(rows[i].child) + "</strong> "
              + esc(rows[i].mark)
              + (rows[i].was_mark
                  ? ' <span class="rg-q">was ' + esc(rows[i].was_mark) + "</span>"
                  : ' <span class="rg-q">first mark</span>')
              + ' <span class="rg-q">' + esc(rows[i].written_by) + "</span></li>");
          }
          out.push("</ul>");
          host.innerHTML = out.join("");
          host.hidden = false;
        })["catch"](function () { host.hidden = true; });
    }
```

- [ ] **Step 5: Style both panels**

In `portal/register/register.css`:

```css
.rg-missing,.rg-history{margin-top:24px;padding:16px 18px;
  border:1px solid var(--line);border-radius:var(--radius);
  background:var(--card);}
.rg-missing h3,.rg-history h3{font-size:1.05rem;margin:0 0 6px;}
.rg-missing-l,.rg-hist-l{list-style:none;margin:10px 0 0;padding:0;}
.rg-missing-l li,.rg-hist-l li{padding:7px 0;border-top:1px solid var(--line);}
```

- [ ] **Step 6: Regenerate, build and run the test**

```bash
python3 tools/build_register_screen.py
python3 verify_structure.py && python3 build.py
python3 _test/register_test.py
```

Expected: PASS.

- [ ] **Step 7: Prove a teacher does not see either panel**

Run the same test under teacher claims and assert `#rg-missing` and
`#rg-history` are absent or hidden. `register_history()` and
`registers_missing()` both return `allowed:false` to a teacher, so this checks
the screen and the database agree.

- [ ] **Step 8: Commit**

```bash
git add tools/register_module.js portal/register/ _test/register_test.py
git commit -m "The office sees the registers nobody took, and what marks used to say"
```

---

### Task 12: The whole suite, and the screenshots

**Files:**
- No new files

- [ ] **Step 1: Run every suite**

```bash
python3 verify_structure.py
for t in register_test portal_test madrasah_admin_test pupils_test \
         admissions_test families_test notices_parents_test fees_test; do
  echo "== $t"; python3 _test/$t.py 2>&1 | tail -1
done
```

Expected: ALL PASS on each.

- [ ] **Step 2: Confirm `health_check()` has only its one deliberate failure**

```sql
select e.value->>'check'
  from jsonb_array_elements(public.health_check()->'checks') e
 where (e.value->>'ok')::boolean = false;
```

Expected: only `register_landing_tables_dropped`.

- [ ] **Step 3: Screenshot the register at 1440 and 390, complete and incomplete, and look at all four**

- [ ] **Step 4: Commit the final state and prepare the delivery bundle**
