-- ===========================================================================
--  014_whole_day_hire.sql — the hall is let by the day, not by the session
--
--  Why
--  ---
--  Migrations 003 and 006 modelled hall hire as two sessions a day (morning
--  9–4, evening 5–11) with one hall chosen out of three and the kitchen as an
--  optional extra. That model was built before anybody had seen the masjid's
--  actual price list.
--
--  The real charges (Astley Hall, effective 1 January 2024, confirmed by the
--  committee 7 September 2026) work quite differently:
--
--      Mon–Thu   1 hall + kitchen + cleaning   £350 per day
--                2 halls + kitchen + cleaning  £500 per day
--                3 halls + kitchen + cleaning  £600 per day
--      Fri–Sun   2 halls + kitchen + cleaning  £600 per day
--                3 halls + kitchen + cleaning  £700 per day
--      Kitchen only                            £125 per day
--
--  Three things follow, and each of them is a schema change rather than a
--  price change:
--
--    1. Hire is BY THE DAY. There is no morning and no evening. Two people
--       cannot have the same date.
--    2. What is chosen is HOW MANY halls, not WHICH hall. `hall` held '1',
--       '2' or '3' meaning the room; `halls_count` holds 1, 2 or 3 meaning the
--       quantity. Same digits, entirely different meaning — which is exactly
--       the kind of column that gets misread later, so the old one is retired
--       rather than reinterpreted.
--    3. The kitchen is INCLUDED in every hall band, so the yes/no question is
--       gone — but kitchen-only hire exists as its own product, which the site
--       never offered at all.
--
--  There is also no member rate. The membership question comes off the form
--  entirely, and with it the Article 9 exposure that migration 003 was written
--  around. Nothing needs doing here for that — the column never existed,
--  deliberately — but it is worth recording that the reason it never existed
--  has now been overtaken by the masjid simply not charging two prices.
--
--  Existing rows are kept and remain readable. Nothing is deleted.
--
--  A fourth thing had to be fixed to make that possible — see section 2. The
--  first attempt at this migration failed in production on a booking taken
--  on 26 August for 28 August, because touching a historic row re-checked a
--  constraint that said the booking date must not be in the past.
--
--  Prerequisites: 003 and 006. Idempotent.
--
--  *** STANDING RULE: re-run 011_require_two_step.sql after this. ***
-- ===========================================================================

begin;

do $$
begin
  if to_regclass('public.hall_bookings') is null then
    raise exception 'public.hall_bookings does not exist. Run 003_hall_bookings.sql first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. The new shape
-- ---------------------------------------------------------------------------
alter table public.hall_bookings
  add column if not exists hire_type   text,
  add column if not exists halls_count int;

comment on column public.hall_bookings.hire_type is
  '''halls'' or ''kitchen_only''. Kitchen-only hire is a separate product at a separate rate; it is not a hall booking with the halls left out.';
comment on column public.hall_bookings.halls_count is
  'HOW MANY halls, 1 to 3 — not which one. Null for kitchen-only hire. The kitchen and the cleaning are included in every hall band, which is why there is no longer a kitchen flag to set.';


-- ---------------------------------------------------------------------------
-- 2. A landmine that had to be cleared first
--
-- Migration 003 wrote these two rules as CHECK constraints:
--
--     date_not_past    check (booking_date >= today)
--     date_within_year check (booking_date <= today + 12 months)
--
-- A CHECK constraint is meant to state something that is true for as long as
-- the row exists. "This date is in the future" is not that. It is true when
-- the booking is taken and false the following week, and Postgres re-checks
-- every constraint on a row whenever that row is UPDATED.
--
-- So the moment a booking date passed, the row froze: the office could no
-- longer change its status or add a note, because doing so re-evaluated
-- date_not_past against a date that was now in the past. Nobody had noticed
-- because nobody had tried to edit an old booking — until the backfill below
-- tried to touch every row in the table and was refused by a real, confirmed,
-- paid booking from 28 August.
--
-- The rule itself is right; it is an INSERT-time rule and belongs in a
-- trigger. Moving it there fixes the frozen-history bug as well, which is
-- worth more than the migration it was blocking.
-- ---------------------------------------------------------------------------
alter table public.hall_bookings drop constraint if exists date_not_past;
alter table public.hall_bookings drop constraint if exists date_within_year;

create or replace function public.hall_bookings_date_window()
returns trigger
language plpgsql
as $$
declare
  today date := (now() at time zone 'Europe/London')::date;
begin
  if new.booking_date < today then
    raise exception 'That date has already passed.'
      using errcode = 'check_violation';
  end if;
  if new.booking_date > today + interval '12 months' then
    raise exception 'Bookings can only be made up to 12 months in advance.'
      using errcode = 'check_violation';
  end if;

  -- Friday, Saturday and Sunday have no one-hall rate on the price list, so
  -- the masjid does not sell that booking. Here rather than in a CHECK
  -- constraint for the same reason as the dates above: it is a rule about
  -- what may be TAKEN, not about what a stored row may contain. As a
  -- constraint it froze every historic one-hall weekend booking — which is a
  -- real thing that existed, because the old session rates allowed it.
  if new.hire_type = 'halls'
     and coalesce(new.halls_count, 0) = 1
     and extract(dow from new.booking_date) in (0, 5, 6) then
    raise exception 'One hall is only available Monday to Thursday. At the weekend the smallest booking is two halls.'
      using errcode = 'check_violation';
  end if;

  return new;
end$$;

comment on function public.hall_bookings_date_window() is
  'Every INSERT-time rule for hall bookings, in one place: the date window and the weekend minimum. These were CHECK constraints, which froze rows the moment they aged — any UPDATE re-checked them and failed, so the office could not record what happened to a booking after the event. A rule about when a row may be CREATED does not belong in a constraint about what a stored row may CONTAIN.';

-- BEFORE INSERT, and deliberately not BEFORE UPDATE: the office must be able
-- to record what happened to a booking after the event.
drop trigger if exists hall_bookings_date_window_trg on public.hall_bookings;
create trigger hall_bookings_date_window_trg
  before insert on public.hall_bookings
  for each row execute function public.hall_bookings_date_window();


-- ---------------------------------------------------------------------------
-- 3. Existing rows
--
-- Every booking taken under the old model was for one room, on one session,
-- so it becomes a one-hall booking. The session it was for is not thrown
-- away — session_slot is kept, just no longer required — because the office
-- may still need to know what somebody actually asked for.
-- ---------------------------------------------------------------------------
update public.hall_bookings
   set hire_type   = 'halls',
       halls_count = 1
 where hire_type is null;

alter table public.hall_bookings
  alter column hire_type set not null,
  alter column hire_type set default 'halls';


-- ---------------------------------------------------------------------------
-- 4. What the old columns become
--
-- Retired, not dropped. Dropping them would destroy the record of what past
-- hirers were told they were getting, and the office reads these rows.
-- ---------------------------------------------------------------------------
alter table public.hall_bookings
  alter column session_slot drop not null,
  alter column kitchen      drop not null,
  alter column hall         drop not null,
  alter column hall         drop default;

comment on column public.hall_bookings.session_slot is
  'RETIRED September 2026. Hire is now by the day. Kept, and kept populated on old rows, because it records what those hirers actually asked for. New bookings leave it null.';
comment on column public.hall_bookings.kitchen is
  'RETIRED September 2026. The kitchen is included in every hall band. New bookings leave it null.';
comment on column public.hall_bookings.hall is
  'RETIRED September 2026. Held WHICH hall (1, 2 or 3). Superseded by halls_count, which holds HOW MANY. New bookings leave it null.';

-- The old check named the three rooms and forbade null. Both are wrong now.
alter table public.hall_bookings drop constraint if exists hall_valid;
alter table public.hall_bookings
  add constraint hall_valid check (hall is null or hall in ('any','1','2','3'));


-- ---------------------------------------------------------------------------
-- 5. The rules the price list implies
-- ---------------------------------------------------------------------------
alter table public.hall_bookings drop constraint if exists hire_type_valid;
alter table public.hall_bookings
  add constraint hire_type_valid check (hire_type in ('halls','kitchen_only'));

alter table public.hall_bookings drop constraint if exists halls_count_valid;
-- The `is not null` is not belt and braces. A CHECK constraint is satisfied
-- when it evaluates to NULL, and `null between 1 and 3` is NULL — so without
-- it, a hall booking with no room count sails straight through. The local
-- test caught exactly that on the first run of this migration.
alter table public.hall_bookings
  add constraint halls_count_valid check (
    (hire_type = 'halls'
       and halls_count is not null and halls_count between 1 and 3)
    or
    (hire_type = 'kitchen_only' and halls_count is null)
  );

-- The weekend minimum lives in the INSERT trigger in section 2, not here.
-- It was a NOT VALID check constraint in the first draft of this migration,
-- on the reasoning that NOT VALID would leave history alone. It does not:
-- NOT VALID skips the one-off validation scan, but the constraint is still
-- evaluated on every UPDATE. A confirmed one-hall booking on Friday
-- 28 August — perfectly valid under the old session rates — could no longer
-- be edited by the office at all.
alter table public.hall_bookings drop constraint if exists weekend_needs_two_halls;


-- ---------------------------------------------------------------------------
-- 6. What the public may insert
--
-- Column-level INSERT grants are the real gate: anything not named here
-- cannot be set from a browser, whatever the request body says. `status`
-- stays out, so a request always arrives as 'new'.
-- ---------------------------------------------------------------------------
revoke insert on public.hall_bookings from anon;
grant insert (booking_date, hire_type, halls_count,
              first_name, last_name, address, phone)
  on public.hall_bookings to anon;


-- ---------------------------------------------------------------------------
-- 7. Availability
--
-- One confirmed booking closes the whole date. That was already true per
-- session — the venue is let as a whole — so this is the same rule with the
-- session removed from it.
--
-- Kitchen-only hire closes the date too. It is arguable that the halls are
-- still free that day, but the kitchen and its cleaning are part of every
-- hall band: letting the halls as well would sell the same kitchen twice.
-- The office can always take a second booking by hand if it genuinely works.
--
-- World-readable, because the public calendar reads it. Nothing personal may
-- ever be added to it. Pending requests stay out — otherwise a stranger could
-- close every Saturday by filling in forms.
-- ---------------------------------------------------------------------------
drop view if exists public.hall_availability;

create view public.hall_availability
with (security_invoker = off) as
  select booking_date
    from public.hall_bookings
   where status = 'confirmed'
     and booking_date >= (now() at time zone 'Europe/London')::date
   group by booking_date;

comment on view public.hall_availability is
  'Dates already taken. One confirmed booking closes the whole venue for that day, so the date is the entire answer. World-readable; nothing personal may ever be added. Pending requests are excluded by design.';

grant select on public.hall_availability to anon, authenticated;

commit;
