-- ===========================================================================
--  004_arabic_classes.sql — evening Arabic class registrations
--
--  *** NOT APPLIED YET. *** The Education page ships with registration closed
--  and the office phone number instead; flipping REGISTRATION_OPEN in
--  index_template.html is what turns the form on, and it must not be flipped
--  until this migration has been run.
--
--  This is a MUCH lighter ask than 003_admissions.sql. That one holds children's
--  medical, SEND and EHCP data and cannot move without a full DPIA. This holds
--  an adult's name, email, phone and which of the two classes they want.
--  Still personal data the masjid controls, so it still needs:
--    1. ICO registration (the same Tier 1 entry that 003 needs — one covers both).
--    2. A documented lawful basis. Consent is the natural fit: someone asked
--       to join a class.
--    3. A retention period, set in purge_old_arabic_registrations() below.
--    4. The privacy notice updated to name this list.
--  Whether a full DPIA is required here is a judgement for whoever signs off
--  003 — it is a shorter conversation, not the same one. Do not assume.
--
--  Prerequisites: 001 and 002 applied. Depends on public.is_admin().
-- ===========================================================================

begin;

create table public.arabic_class_registrations (
  id            uuid        primary key default gen_random_uuid(),
  reference     text        not null unique,
  submitted_at  timestamptz not null default now(),

  cohort        text        not null check (cohort in ('mens','womens')),
  first_name    text        not null check (length(trim(first_name)) > 0),
  surname       text        not null check (length(trim(surname))    > 0),
  email         text        not null check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  mobile        text        not null,
  experience    text        not null check (experience in ('none','some','confident')),
  notes         text        check (length(coalesce(notes,'')) <= 400),

  age_confirmed boolean     not null check (age_confirmed),
  privacy_accepted boolean  not null check (privacy_accepted),

  -- 'place' or 'waiting' is decided by the function, never by the browser.
  outcome       text        not null check (outcome in ('place','waiting')),
  status        text        not null default 'active'
                  check (status in ('active','withdrawn','attended','no_show')),
  office_notes  text,
  reviewed_by   uuid references auth.users(id) on delete set null,
  reviewed_at   timestamptz,

  -- One live registration per person per class. A withdrawn one frees the seat.
  constraint one_live_registration_per_cohort
    exclude (lower(email) with =, cohort with =) where (status = 'active')
);

comment on table public.arabic_class_registrations is
  'Sign-ups for the evening Arabic classes. Adults 16+. Ordinary personal data — no health, no children.';

create sequence if not exists public.arabic_reference_seq;
create index arabic_cohort_idx on public.arabic_class_registrations(cohort, outcome, submitted_at);

-- ---------------------------------------------------------------------------
-- Privileges — same shape as 003: anon gets nothing on the table at all.
-- ---------------------------------------------------------------------------
revoke all on public.arabic_class_registrations from anon, authenticated;
grant select, update (status, office_notes, reviewed_by, reviewed_at)
  on public.arabic_class_registrations to authenticated;

alter table public.arabic_class_registrations enable row level security;

-- NOT "force row level security", and that is deliberate.
--
-- 003_admissions.sql does force it, because nothing ever needs to read an
-- application back except an admin. This table is different: the fifteen-place
-- cap is enforced by COUNTING existing rows inside register_for_arabic_class(),
-- and FORCE applies RLS to the table owner too — which is who a SECURITY
-- DEFINER function runs as. With FORCE on and no SELECT policy for the owner,
-- that count silently returns 0. It does not error. Every single sign-up then
-- sees an empty class and is given a place, and the cap does nothing.
--
-- That is what happened on the first run of _test_arabic.sql: the sixteenth
-- person was handed the sixteenth seat in a room that holds fifteen.
--
-- Without FORCE, the owner bypasses RLS (so the function can count) while
-- everyone else is unchanged: anon holds no privileges on this table at all,
-- and authenticated is still filtered to is_admin() by the policies below.
-- Do not "tidy" this line to match 003 without re-running the cap tests.

create policy admin_read_arabic on public.arabic_class_registrations
  for select to authenticated using (public.is_admin());
create policy admin_update_arabic on public.arabic_class_registrations
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- Open at the policy level, shut at the privilege level — see the note in 003.
create policy definer_insert_arabic on public.arabic_class_registrations
  for insert with check (true);
create policy definer_delete_arabic on public.arabic_class_registrations
  for delete using (true);

-- ---------------------------------------------------------------------------
-- Registration
--
-- The fifteen-place cap is enforced HERE, by counting rows inside a locked
-- transaction — not by a number typed into the web page. A page that says
-- "3 places left" is out of date the moment someone else presses send, and
-- two people can take the last seat at the same time. Counting at the point
-- of insert is the only version that cannot oversell the room.
-- ---------------------------------------------------------------------------

create or replace function public.register_for_arabic_class(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  CAP        constant int := 15;
  v_cohort   text := payload ->> 'cohort';
  v_email    text := lower(trim(payload ->> 'email'));
  v_taken    int;
  v_outcome  text;
  v_ref      text;
  v_position int;
begin
  if v_cohort not in ('mens','womens') then
    raise exception 'Please choose which class you would like to join';
  end if;

  -- Serialise everyone competing for the same room. Without this two people
  -- can both read "14 taken" and both be given the fifteenth seat.
  perform pg_advisory_xact_lock(hashtext('arabic_class:' || v_cohort));

  if exists (select 1 from public.arabic_class_registrations
              where lower(email) = v_email and cohort = v_cohort and status = 'active') then
    raise exception 'There is already a registration for this email address on this class';
  end if;

  select count(*) into v_taken
    from public.arabic_class_registrations
   where cohort = v_cohort and outcome = 'place' and status = 'active';

  v_outcome := case when v_taken < CAP then 'place' else 'waiting' end;
  v_ref := 'AR-' || to_char(now(), 'YY') || '-' ||
           lpad(nextval('public.arabic_reference_seq')::text, 4, '0');

  insert into public.arabic_class_registrations (
    reference, cohort, first_name, surname, email, mobile,
    experience, notes, age_confirmed, privacy_accepted, outcome
  ) values (
    v_ref, v_cohort,
    payload ->> 'first_name', payload ->> 'surname', v_email, payload ->> 'mobile',
    coalesce(payload ->> 'experience', 'none'),
    nullif(payload ->> 'notes', ''),
    (payload ->> 'age_confirmed')::boolean,
    (payload ->> 'privacy_accepted')::boolean,
    v_outcome
  );

  if v_outcome = 'waiting' then
    select count(*) into v_position
      from public.arabic_class_registrations
     where cohort = v_cohort and outcome = 'waiting' and status = 'active';
  end if;

  insert into public.admin_audit (action, detail)
  values ('arabic_registration', jsonb_build_object('reference', v_ref,
          'cohort', v_cohort, 'outcome', v_outcome));

  return jsonb_build_object('reference', v_ref, 'outcome', v_outcome,
                            'waiting_position', v_position,
                            'places_left', greatest(CAP - v_taken - 1, 0));
end;
$$;

revoke all on function public.register_for_arabic_class(jsonb) from public;
grant execute on function public.register_for_arabic_class(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Retention
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_arabic_registrations(retain_months int)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_deleted int;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator may purge registrations';
  end if;
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be a positive number of months';
  end if;
  with gone as (
    delete from public.arabic_class_registrations
     where status in ('withdrawn','no_show')
       and submitted_at < now() - make_interval(months => retain_months)
    returning 1
  ) select count(*) into v_deleted from gone;
  insert into public.admin_audit (action, detail)
  values ('arabic_registrations_purged',
          jsonb_build_object('deleted', v_deleted, 'retain_months', retain_months));
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_arabic_registrations(int) from public;
grant execute on function public.purge_old_arabic_registrations(int) to authenticated;

commit;
