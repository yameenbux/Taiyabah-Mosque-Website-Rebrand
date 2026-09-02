-- ===========================================================================
--  009_courses.sql — classes and workshops, and the people signed up to them
--
--  *** NOT APPLIED YET. *** The Education pages ship with registration closed
--  and the office phone number instead. Flipping REGISTRATION_OPEN in
--  index_template.html is what turns the forms on, and it must not be flipped
--  until this has been run.
--
--  This replaces an earlier 009_courses.sql that was never applied.
--  That version hardcoded one class and a capacity of fifteen into the
--  function name and body. A second class — the Ghusl workshop — arrived
--  within a day, which is the usual fate of a table named after its first row.
--  Courses are DATA here, not schema: adding a third is one INSERT, not a
--  migration and a deploy.
--
--  Much lighter than 008_admissions.sql: adult names, emails and phone
--  numbers, no children and no health data. It still needs ICO registration
--  (the same Tier 1 entry covers both), a documented lawful basis — consent
--  is the natural fit — a retention period, and a line in the privacy notice.
--  Whether it needs a full DPIA is a judgement for whoever signs off 003. It
--  is a shorter conversation, not the same one.
--
--  Prerequisites: 001 and 002 applied. Depends on public.is_admin().
-- ===========================================================================

begin;

create table public.courses (
  key          text        primary key check (key ~ '^[a-z0-9_]{2,40}$'),
  name         text        not null,
  -- 'separate' means men's and women's cohorts are counted independently;
  -- 'single' means one mixed list.
  cohort_mode  text        not null default 'separate'
                 check (cohort_mode in ('separate','single')),
  capacity     int         not null check (capacity between 1 and 500),
  is_open      boolean     not null default false,
  sort_order   int         not null default 0,
  created_at   timestamptz not null default now()
);

comment on column public.courses.capacity is
  'Places per cohort when cohort_mode = separate, otherwise places in total.';
comment on column public.courses.is_open is
  'The office can close a course to new sign-ups without a code change.';

insert into public.courses (key, name, cohort_mode, capacity, is_open, sort_order) values
  ('arabic', 'Arabic Classes',  'separate', 15, true, 1),
  ('ghusl',  'Ghusl Workshop',  'separate', 15, true, 2);

create table public.course_registrations (
  id            uuid        primary key default gen_random_uuid(),
  reference     text        not null unique,
  submitted_at  timestamptz not null default now(),

  course_key    text        not null references public.courses(key) on update cascade,
  cohort        text        not null check (cohort in ('mens','womens','all')),

  first_name    text        not null check (length(trim(first_name)) > 0),
  surname       text        not null check (length(trim(surname))    > 0),
  email         text        not null check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  mobile        text        not null,
  -- Free text, because what "experience" means differs by course. The page
  -- offers sensible choices; the database does not care which.
  experience    text,
  notes         text        check (length(coalesce(notes,'')) <= 400),

  age_confirmed    boolean  not null check (age_confirmed),
  privacy_accepted boolean  not null check (privacy_accepted),

  -- 'place' or 'waiting' is decided by the function, never by the browser.
  outcome       text        not null check (outcome in ('place','waiting')),
  status        text        not null default 'active'
                  check (status in ('active','withdrawn','attended','no_show')),
  office_notes  text,
  reviewed_by   uuid references auth.users(id) on delete set null,
  reviewed_at   timestamptz,

  -- One live registration per person per course per cohort. Withdrawing frees
  -- the seat and lets the same person sign up again later.
  constraint one_live_registration
    exclude (lower(email) with =, course_key with =, cohort with =) where (status = 'active')
);

create sequence if not exists public.course_reference_seq;
create index course_reg_lookup_idx
  on public.course_registrations(course_key, cohort, outcome, submitted_at);

-- ---------------------------------------------------------------------------
-- Privileges — anon gets nothing on either table. Sign-up goes through one
-- SECURITY DEFINER function; the course list is read through another.
-- ---------------------------------------------------------------------------
revoke all on public.courses, public.course_registrations from anon, authenticated;
grant select on public.courses to authenticated;
grant select, update (status, office_notes, reviewed_by, reviewed_at)
  on public.course_registrations to authenticated;

alter table public.courses               enable row level security;
alter table public.course_registrations  enable row level security;

-- NOT "force row level security", and that is deliberate.
--
-- 008_admissions.sql does force it, because nothing ever needs to read an
-- application back except an admin. Here the capacity cap is enforced by
-- COUNTING existing rows inside register_for_course(), and FORCE applies RLS
-- to the table owner too — which is who a SECURITY DEFINER function runs as.
-- With FORCE on and no SELECT policy for the owner, that count silently
-- returns 0. It does not error. Every sign-up then sees an empty room and is
-- given a place, and the cap does nothing at all.
--
-- That is exactly what the first run of _test_courses.sql caught: the
-- sixteenth person was handed the sixteenth seat in a room that holds fifteen.
--
-- Without FORCE the owner bypasses RLS (so the function can count) while
-- everyone else is unchanged: anon holds no privileges on these tables, and
-- authenticated is still filtered by the policies below. Do not "tidy" this to
-- match 003 without re-running the capacity tests.

create policy admin_read_courses on public.courses
  for select to authenticated using (public.is_admin());
create policy admin_read_registrations on public.course_registrations
  for select to authenticated using (public.is_admin());
create policy admin_update_registrations on public.course_registrations
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy definer_insert_registrations on public.course_registrations
  for insert with check (true);
create policy definer_delete_registrations on public.course_registrations
  for delete using (true);

-- ---------------------------------------------------------------------------
-- Sign-up
--
-- The cap is enforced here, by counting inside a lock — not by a number typed
-- into a web page. A page that says "3 places left" is wrong the moment
-- somebody else presses send, and two people can take the last seat at once.
-- ---------------------------------------------------------------------------

create or replace function public.register_for_course(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key      text := payload ->> 'course_key';
  v_cohort   text := coalesce(payload ->> 'cohort', 'all');
  v_email    text := lower(trim(payload ->> 'email'));
  v_course   public.courses%rowtype;
  v_taken    int;
  v_outcome  text;
  v_ref      text;
  v_position int;
begin
  select * into v_course from public.courses where key = v_key;
  if not found then
    raise exception 'That course does not exist';
  end if;
  if not v_course.is_open then
    raise exception 'Sign-ups for % are closed at the moment', v_course.name;
  end if;
  if v_course.cohort_mode = 'separate' and v_cohort not in ('mens','womens') then
    raise exception 'Please choose which session you would like to join';
  end if;
  if v_course.cohort_mode = 'single' then
    v_cohort := 'all';
  end if;

  -- Serialise everyone competing for the same room. Without this two people
  -- can both read "14 taken" and both be given the fifteenth seat.
  perform pg_advisory_xact_lock(hashtext('course:' || v_key || ':' || v_cohort));

  if exists (select 1 from public.course_registrations
              where lower(email) = v_email and course_key = v_key
                and cohort = v_cohort and status = 'active') then
    raise exception 'There is already a registration for this email address on this course';
  end if;

  select count(*) into v_taken
    from public.course_registrations
   where course_key = v_key and cohort = v_cohort
     and outcome = 'place' and status = 'active';

  v_outcome := case when v_taken < v_course.capacity then 'place' else 'waiting' end;
  v_ref := upper(left(v_key, 2)) || '-' || to_char(now(), 'YY') || '-' ||
           lpad(nextval('public.course_reference_seq')::text, 4, '0');

  insert into public.course_registrations (
    reference, course_key, cohort, first_name, surname, email, mobile,
    experience, notes, age_confirmed, privacy_accepted, outcome
  ) values (
    v_ref, v_key, v_cohort,
    payload ->> 'first_name', payload ->> 'surname', v_email, payload ->> 'mobile',
    nullif(payload ->> 'experience', ''), nullif(payload ->> 'notes', ''),
    (payload ->> 'age_confirmed')::boolean,
    (payload ->> 'privacy_accepted')::boolean,
    v_outcome
  );

  if v_outcome = 'waiting' then
    select count(*) into v_position
      from public.course_registrations
     where course_key = v_key and cohort = v_cohort
       and outcome = 'waiting' and status = 'active';
  end if;

  insert into public.admin_audit (action, detail)
  values ('course_registration', jsonb_build_object(
            'reference', v_ref, 'course', v_key, 'cohort', v_cohort, 'outcome', v_outcome));

  return jsonb_build_object(
    'reference', v_ref, 'outcome', v_outcome, 'course', v_course.name,
    'capacity', v_course.capacity, 'waiting_position', v_position,
    'places_left', greatest(v_course.capacity - v_taken - 1, 0));
end;
$$;

revoke all on function public.register_for_course(jsonb) from public;
grant execute on function public.register_for_course(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Retention
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_course_registrations(retain_months int)
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
    delete from public.course_registrations
     where status in ('withdrawn','no_show')
       and submitted_at < now() - make_interval(months => retain_months)
    returning 1
  ) select count(*) into v_deleted from gone;
  insert into public.admin_audit (action, detail)
  values ('course_registrations_purged',
          jsonb_build_object('deleted', v_deleted, 'retain_months', retain_months));
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_course_registrations(int) from public;
grant execute on function public.purge_old_course_registrations(int) to authenticated;

commit;
