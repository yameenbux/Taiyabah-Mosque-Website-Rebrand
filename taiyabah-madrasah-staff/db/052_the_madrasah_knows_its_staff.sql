-- ===========================================================================
--  052_the_madrasah_knows_its_staff.sql
--  18 September 2026
--
--  The first tables of the Madrasah Portal. STAFF AND CLASSES ONLY — no pupil
--  record is created here and none may be until the list on /portal/ is
--  worked through: the DPIA finished, the ICO registered, the lawful basis and
--  Article 9 condition written down, and two-step made a DATABASE rule for
--  pupil tables rather than a page rule.
--
--  Staff are different, and the difference is worth stating rather than
--  assuming. A madrasah roll reveals a child's religion, which is Article 9
--  special category data before anybody adds a single note. An employment
--  record for an adult who works there is ordinary personal data, of the same
--  kind this project already holds in `profiles` for its administrators. So
--  this can be built now and the pupil tables cannot.
--
--  ---------------------------------------------------------------------------
--  THREE DESIGN DECISIONS THAT DIFFER FROM THE SYSTEM THIS REPLACES
--  ---------------------------------------------------------------------------
--
--  1. DBS STATUS IS DERIVED, NEVER STORED.
--
--     The current system shows a green "DBS Valid" badge on a staff row. If
--     that badge is a stored field then it is wrong from the morning after the
--     check lapses, and it goes on being wrong, in green, until somebody edits
--     the record. A safeguarding indicator that can quietly become a lie is
--     worse than no indicator.
--
--     Here the dates are stored and the status is worked out when it is read.
--     It cannot go stale because there is nothing to go stale.
--
--  2. A DBS CERTIFICATE HAS NO EXPIRY DATE, AND PRETENDING IT DOES IS WRONG.
--
--     DBS certificates do not expire. There is no date on them after which
--     they stop being valid. What actually happens is that an organisation
--     sets its own renewal period — three years is the common choice — and
--     re-checks; or the person is on the DBS Update Service and the
--     organisation re-checks that instead, which is free and instant.
--
--     So this stores what is true — the date on the certificate, whether the
--     person is on the Update Service, and when the masjid last looked — and
--     derives "due" from the masjid's own renewal period. Modelling a
--     non-existent expiry date would have produced a number nobody could
--     source from any document.
--
--  3. THE CERTIFICATE NUMBER IS NOT STORED AT ALL.
--
--     It is the one field here that would be genuinely damaging to leak and
--     the one the portal has no use for. What the masjid needs on a screen is
--     "is this in date"; the number is needed only when standing in front of
--     the certificate, which the masjid holds. Not collecting it is cheaper
--     than protecting it.
--
--  ---------------------------------------------------------------------------
--  AND ONE THAT IS ONLY A COURTESY, WHICH IS REASON ENOUGH
--  ---------------------------------------------------------------------------
--
--  The honorific is a SEPARATE COLUMN from the name. In the system this
--  replaces, "Apa" is part of the name string, so an alphabetical staff list
--  puts nineteen people under A and sorts them by their first names. Splitting
--  it means the list sorts by surname, which is how a person looks somebody up
--  — and it costs one column.
--
--  Prerequisites: verified_admin() from 011, admin_audit. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. Classes
--
--  Created before staff, because a staff row points at these.
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_classes (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  --  girls / boys / mixed. The madrasah teaches them separately and the lists
  --  are read separately, so this is a column rather than something parsed
  --  back out of the name later.
  section     text not null default 'girls',
  --  '26/27'. Nullable: several classes carry no year in their name.
  year_label  text,
  is_active   boolean not null default true,
  sort_order  integer not null default 100,
  created_at  timestamptz not null default now()
);

alter table public.madrasah_classes add column if not exists year_label text;
alter table public.madrasah_classes add column if not exists sort_order integer not null default 100;

create unique index if not exists madrasah_classes_name_once
  on public.madrasah_classes (lower(btrim(name)));

alter table public.madrasah_classes drop constraint if exists madrasah_class_section_known;
alter table public.madrasah_classes add constraint madrasah_class_section_known
  check (section in ('girls', 'boys', 'mixed'));

alter table public.madrasah_classes drop constraint if exists madrasah_class_has_a_name;
alter table public.madrasah_classes add constraint madrasah_class_has_a_name
  check (length(btrim(name)) between 1 and 80);

-- ---------------------------------------------------------------------------
--  2. Staff
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_staff (
  id            uuid primary key default gen_random_uuid(),

  --  'Apa', 'Moulana', 'Hafiz'. Separate from the name — see the header.
  honorific     text,
  first_name    text not null,
  last_name     text,

  employment    text not null default 'employed',
  started_on    date,
  left_on       date,

  --  Which days they are in. NULL means nobody has said, which is different
  --  from an empty array meaning "none" — and the screen says "not set"
  --  rather than showing an empty row.
  work_days     text[],

  --  DBS. No certificate number, by decision. See the header.
  dbs_issued        date,
  dbs_update_service boolean not null default false,
  dbs_last_checked  date,
  dbs_not_required  boolean not null default false,

  email         text,
  phone         text,
  note          text,

  --  If this person also has a sign-in on this site, this ties the two
  --  together. Nullable, and most staff will not have one for a long time.
  user_id       uuid references auth.users(id) on delete set null,

  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

alter table public.madrasah_staff add column if not exists dbs_not_required boolean not null default false;
alter table public.madrasah_staff add column if not exists dbs_update_service boolean not null default false;
alter table public.madrasah_staff add column if not exists dbs_last_checked date;
alter table public.madrasah_staff add column if not exists work_days text[];
alter table public.madrasah_staff add column if not exists user_id uuid;

alter table public.madrasah_staff drop constraint if exists madrasah_staff_employment_known;
alter table public.madrasah_staff add constraint madrasah_staff_employment_known
  check (employment in ('employed', 'volunteer', 'on_leave', 'left'));

alter table public.madrasah_staff drop constraint if exists madrasah_staff_has_a_name;
alter table public.madrasah_staff add constraint madrasah_staff_has_a_name
  check (length(btrim(first_name)) between 1 and 60);

--  Days are the seven real ones and nothing else. A typo'd 'Thurs' that sorts
--  into a rota is a teacher who is not expected on the day they turn up.
alter table public.madrasah_staff drop constraint if exists madrasah_staff_days_are_days;
alter table public.madrasah_staff add constraint madrasah_staff_days_are_days
  check (work_days is null or work_days <@ array['mon','tue','wed','thu','fri','sat','sun']);

--  Somebody who has left has a leaving date, and somebody who has not, has
--  not. Both halves, because only checking one lets a "left" record sit there
--  with no date and a dated record claim to be current.
alter table public.madrasah_staff drop constraint if exists madrasah_staff_left_makes_sense;
alter table public.madrasah_staff add constraint madrasah_staff_left_makes_sense
  check ((employment = 'left') = (left_on is not null));

-- ---------------------------------------------------------------------------
--  3. Who teaches what
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_staff_classes (
  staff_id uuid not null references public.madrasah_staff(id)  on delete cascade,
  class_id uuid not null references public.madrasah_classes(id) on delete cascade,
  primary key (staff_id, class_id)
);

--  Cascade is right HERE and wrong on a pupil: this table holds no fact of
--  its own, only the join. Deleting the staff row should take its
--  class links with it rather than leaving orphans.

create index if not exists madrasah_staff_classes_by_class
  on public.madrasah_staff_classes (class_id);

-- ---------------------------------------------------------------------------
--  4. Nobody reaches these tables directly
--
--  GRANT AND RLS ARE DIFFERENT THINGS AND YOU NEED BOTH. Forced RLS with no
--  policies denies everything including to the owner, which is what is wanted:
--  every read and write below goes through a security definer function.
-- ---------------------------------------------------------------------------
alter table public.madrasah_classes       enable row level security;
alter table public.madrasah_classes       force  row level security;
alter table public.madrasah_staff         enable row level security;
alter table public.madrasah_staff         force  row level security;
alter table public.madrasah_staff_classes enable row level security;
alter table public.madrasah_staff_classes force  row level security;

revoke all on public.madrasah_classes       from anon, authenticated;
revoke all on public.madrasah_staff         from anon, authenticated;
revoke all on public.madrasah_staff_classes from anon, authenticated;

-- ---------------------------------------------------------------------------
--  5. How long a check lasts, and how much warning is useful
--
--  TWO NUMBERS, WRITTEN HERE, NOT IN A SETTINGS TABLE.
--
--  The first draft of this put them in app_settings. That was wrong twice
--  over: app_settings is keyed by masjid and stores text rather than jsonb, so
--  it would have needed bending — and, more to the point, a setting with no
--  screen behind it is a switch nobody can reach. This project has already
--  written down that a switch that does nothing is worse than no switch.
--
--  A renewal period changes roughly never. When it does, it is one line here
--  and a migration, which is the honest amount of ceremony for a decision the
--  safeguarding lead has to sign off anyway.
--
--  36 months is the common renewal choice. 90 days is enough warning to book
--  an appointment and have the certificate come back.
-- ---------------------------------------------------------------------------

create or replace function public.dbs_state(
  p_issued date, p_update_service boolean, p_last_checked date,
  p_not_required boolean)
returns text
language plpgsql
stable
--  STABLE, not IMMUTABLE. It reads current_date, which changes. Marked
--  immutable, Postgres is entitled to fold the result in at plan time and
--  hand back yesterday's answer for ever — on a safeguarding indicator.
set search_path = public, pg_temp
as $fn$
declare
  v_months constant integer := 36;   -- the masjid's renewal period
  v_warn   constant integer := 90;   -- days of warning before it falls due
  v_due    date;
begin
  if coalesce(p_not_required, false) then
    return 'not_required';
  end if;
  if p_issued is null then
    return 'none';
  end if;

  --  ON THE UPDATE SERVICE, the certificate's own age stops mattering — what
  --  matters is when the masjid last looked, because a check can be revoked
  --  the week after it is issued. Twelve months is the sensible re-look, and
  --  a person on the service who has NEVER been re-checked is treated as due
  --  rather than as fine, because that is the honest reading.
  if coalesce(p_update_service, false) then
    v_due := coalesce(p_last_checked, p_issued) + interval '12 months';
  else
    v_due := p_issued + (v_months || ' months')::interval;
  end if;

  if v_due < current_date then
    return 'overdue';
  elsif v_due < current_date + (v_warn || ' days')::interval then
    return 'due_soon';
  end if;
  return 'valid';
end $fn$;

-- ---------------------------------------------------------------------------
--  6. Reading the staff list
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_staff_list()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the madrasah staff.'
      using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.sort_last, x.sort_first)
      from (
        select s.id, s.honorific, s.first_name, s.last_name,
               btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)) as display_name,
               s.employment, s.started_on, s.left_on, s.work_days,
               s.dbs_issued, s.dbs_update_service, s.dbs_last_checked,
               s.dbs_not_required,
               public.dbs_state(s.dbs_issued, s.dbs_update_service,
                                s.dbs_last_checked, s.dbs_not_required) as dbs,
               s.email, s.phone, s.note,
               --  Their classes, as names, so the screen needs one call.
               coalesce((
                 select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name)
                                  order by c.sort_order, c.name)
                   from public.madrasah_staff_classes sc
                   join public.madrasah_classes c on c.id = sc.class_id
                  where sc.staff_id = s.id), '[]'::jsonb) as classes,
               --  Sorted by SURNAME. See the header.
               lower(coalesce(nullif(btrim(s.last_name), ''), s.first_name)) as sort_last,
               lower(s.first_name) as sort_first
          from public.madrasah_staff s
      ) x
  ), '[]'::jsonb);
end $fn$;

-- ---------------------------------------------------------------------------
--  7. Writing one. Create and amend in the same function, because two that
--     differ by an id are two sets of rules to keep in step.
-- ---------------------------------------------------------------------------
create or replace function public.save_madrasah_staff(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id    uuid := nullif(p->>'id', '')::uuid;
  v_first text := btrim(coalesce(p->>'first_name', ''));
  v_days  text[];
  v_row   public.madrasah_staff%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the madrasah staff.'
      using errcode = '42501';
  end if;

  if v_first = '' then
    raise exception 'A member of staff needs at least a first name.'
      using errcode = 'check_violation';
  end if;

  if p ? 'work_days' and jsonb_typeof(p->'work_days') = 'array' then
    select array_agg(lower(btrim(d))) into v_days
      from jsonb_array_elements_text(p->'work_days') d;
  end if;

  insert into public.madrasah_staff as s (
    id, honorific, first_name, last_name, employment, started_on, left_on,
    work_days, dbs_issued, dbs_update_service, dbs_last_checked,
    dbs_not_required, email, phone, note)
  values (
    coalesce(v_id, gen_random_uuid()),
    nullif(btrim(coalesce(p->>'honorific', '')), ''),
    v_first,
    nullif(btrim(coalesce(p->>'last_name', '')), ''),
    coalesce(nullif(p->>'employment', ''), 'employed'),
    nullif(p->>'started_on', '')::date,
    nullif(p->>'left_on', '')::date,
    v_days,
    nullif(p->>'dbs_issued', '')::date,
    coalesce((p->>'dbs_update_service')::boolean, false),
    nullif(p->>'dbs_last_checked', '')::date,
    coalesce((p->>'dbs_not_required')::boolean, false),
    nullif(btrim(coalesce(p->>'email', '')), ''),
    nullif(btrim(coalesce(p->>'phone', '')), ''),
    nullif(btrim(coalesce(p->>'note', '')), ''))
  on conflict (id) do update set
    honorific = excluded.honorific,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    employment = excluded.employment,
    started_on = excluded.started_on,
    left_on = excluded.left_on,
    work_days = excluded.work_days,
    dbs_issued = excluded.dbs_issued,
    dbs_update_service = excluded.dbs_update_service,
    dbs_last_checked = excluded.dbs_last_checked,
    dbs_not_required = excluded.dbs_not_required,
    email = excluded.email,
    phone = excluded.phone,
    note = excluded.note,
    updated_at = now()
  returning * into v_row;

  --  The classes, if the caller said anything about them. Absent means
  --  "leave them alone"; an empty array means "none", and those are
  --  different instructions.
  if p ? 'class_ids' and jsonb_typeof(p->'class_ids') = 'array' then
    delete from public.madrasah_staff_classes where staff_id = v_row.id;
    insert into public.madrasah_staff_classes (staff_id, class_id)
    select v_row.id, (c)::uuid
      from jsonb_array_elements_text(p->'class_ids') c
    on conflict do nothing;
  end if;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(),
          case when v_id is null then 'madrasah_staff_added' else 'madrasah_staff_changed' end,
          jsonb_build_object('id', v_row.id,
                             'name', btrim(concat_ws(' ', v_row.honorific,
                                                     v_row.first_name, v_row.last_name))));

  return jsonb_build_object('id', v_row.id);
end $fn$;

-- ---------------------------------------------------------------------------
--  8. Classes, read and written
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_classes_list()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the madrasah classes.'
      using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.section, x.sort_order, x.name)
      from (
        select c.id, c.name, c.section, c.year_label, c.is_active, c.sort_order,
               (select count(*) from public.madrasah_staff_classes sc
                 where sc.class_id = c.id) as staff_count
          from public.madrasah_classes c
      ) x
  ), '[]'::jsonb);
end $fn$;

create or replace function public.save_madrasah_class(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id   uuid := nullif(p->>'id', '')::uuid;
  v_name text := btrim(coalesce(p->>'name', ''));
  v_row  public.madrasah_classes%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the madrasah classes.'
      using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'A class needs a name.' using errcode = 'check_violation';
  end if;

  insert into public.madrasah_classes as c (id, name, section, year_label, is_active, sort_order)
  values (coalesce(v_id, gen_random_uuid()), v_name,
          coalesce(nullif(p->>'section', ''), 'girls'),
          nullif(btrim(coalesce(p->>'year_label', '')), ''),
          coalesce((p->>'is_active')::boolean, true),
          coalesce((p->>'sort_order')::int, 100))
  on conflict (id) do update set
    name = excluded.name, section = excluded.section,
    year_label = excluded.year_label, is_active = excluded.is_active,
    sort_order = excluded.sort_order
  returning * into v_row;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'madrasah_class_saved',
          jsonb_build_object('id', v_row.id, 'name', v_row.name));

  return jsonb_build_object('id', v_row.id);
end $fn$;

-- ---------------------------------------------------------------------------
--  9. The figures the madrasah's own front screen needs
--
--  One call, not six. Six round trips is six ways to half-load a dashboard.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_overview()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_states jsonb;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may open the madrasah portal.'
      using errcode = '42501';
  end if;

  select jsonb_object_agg(st, n) into v_states
    from (select public.dbs_state(dbs_issued, dbs_update_service,
                                  dbs_last_checked, dbs_not_required) as st,
                 count(*) as n
            from public.madrasah_staff
           where employment <> 'left'
           group by 1) z;

  return jsonb_build_object(
    'as_at', now(),
    'staff',   (select count(*) from public.madrasah_staff where employment <> 'left'),
    'classes', (select count(*) from public.madrasah_classes where is_active),
    'staff_without_days',
      (select count(*) from public.madrasah_staff
        where employment <> 'left' and (work_days is null or cardinality(work_days) = 0)),
    'dbs', coalesce(v_states, '{}'::jsonb),
    --  Named, not just counted. A number tells somebody something is wrong
    --  and nothing about who to ring.
    'dbs_needs_attention', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', s.id,
               'name', btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)),
               'state', public.dbs_state(s.dbs_issued, s.dbs_update_service,
                                         s.dbs_last_checked, s.dbs_not_required))
             order by s.last_name, s.first_name)
        from public.madrasah_staff s
       where s.employment <> 'left'
         and public.dbs_state(s.dbs_issued, s.dbs_update_service,
                              s.dbs_last_checked, s.dbs_not_required)
             in ('none', 'overdue', 'due_soon')), '[]'::jsonb),
    --  Applications already arriving from /apply/ that nobody has a screen
    --  for yet. Counted here so the gap is visible rather than assumed empty.
    'admissions_waiting',
      (select count(*) from public.admission_applications)
  );
end $fn$;

-- ---------------------------------------------------------------------------
--  10. The grants. Revoke first — Postgres grants EXECUTE to PUBLIC.
-- ---------------------------------------------------------------------------
revoke all on function public.dbs_state(date, boolean, date, boolean) from public, anon;
revoke all on function public.madrasah_staff_list()      from public, anon;
revoke all on function public.save_madrasah_staff(jsonb) from public, anon;
revoke all on function public.madrasah_classes_list()    from public, anon;
revoke all on function public.save_madrasah_class(jsonb) from public, anon;
revoke all on function public.madrasah_overview()        from public, anon;

grant execute on function public.madrasah_staff_list()      to authenticated;
grant execute on function public.save_madrasah_staff(jsonb) to authenticated;
grant execute on function public.madrasah_classes_list()    to authenticated;
grant execute on function public.save_madrasah_class(jsonb) to authenticated;
grant execute on function public.madrasah_overview()        to authenticated;

-- ---------------------------------------------------------------------------
--  PROVE IT
-- ---------------------------------------------------------------------------
do $check$
declare
  v_wrote boolean := false;
  v_pol   integer;
begin
  --  1. dbs_state answers every case, including the two the old system had
  --     no word for.
  if public.dbs_state(null::date, false, null::date, false) <> 'none' then
    raise exception 'a member of staff with no DBS is not reported as none';
  end if;
  if public.dbs_state((current_date - interval '10 years')::date, false, null::date, false) <> 'overdue' then
    raise exception 'a ten-year-old check is not reported as overdue';
  end if;
  if public.dbs_state(current_date, false, null::date, false) <> 'valid' then
    raise exception 'a check issued today is not reported as valid';
  end if;
  --  The warning tier. This is the whole reason for building it rather than
  --  copying a green/red badge: a check that lapses next month must read
  --  differently from one that lapsed last month.
  if public.dbs_state((current_date - interval '36 months' + interval '30 days')::date, false, null::date, false) <> 'due_soon' then
    raise exception 'a check due in 30 days is not reported as due_soon';
  end if;
  if public.dbs_state(null::date, false, null::date, true) <> 'not_required' then
    raise exception 'not_required is not honoured';
  end if;
  --  On the Update Service and never re-checked is DUE, not fine.
  if public.dbs_state((current_date - interval '2 years')::date, true, null::date, false) <> 'overdue' then
    raise exception 'somebody on the Update Service who has never been re-checked reads as fine';
  end if;

  --  2. RLS on, forced, no policies, on all three tables.
  for v_pol in
    select 1 from unnest(array['madrasah_staff','madrasah_classes','madrasah_staff_classes']) t
     where not (select relrowsecurity and relforcerowsecurity
                  from pg_class where oid = ('public.' || t)::regclass)
  loop
    raise exception 'row level security is not enabled and forced on every madrasah table';
  end loop;

  select count(*) into v_pol from pg_policies
   where schemaname = 'public' and tablename like 'madrasah%';
  if v_pol <> 0 then
    raise exception 'a madrasah table has % policy(ies); they are meant to have none', v_pol;
  end if;

  --  3. A session with no JWT is refused by verified_admin(), not by a
  --     constraint. Both fail; only one of them is the check doing its job.
  begin
    perform public.save_madrasah_staff('{"first_name":"negative control"}'::jsonb);
    v_wrote := true;
  exception
    when insufficient_privilege then null;
    when others then
      raise exception 'save_madrasah_staff() failed with SQLSTATE % for a session with no JWT; '
                      'it should be refused by verified_admin()', sqlstate;
  end;
  if v_wrote then
    raise exception 'save_madrasah_staff() WROTE A ROW with no JWT at all';
  end if;

  --  4. Grants.
  if has_function_privilege('anon', 'public.madrasah_staff_list()', 'execute') then
    raise exception 'anon can read the madrasah staff list';
  end if;

  raise notice 'madrasah staff and classes are in place; DBS status is derived, not stored.';
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--  NO PUPIL TABLE IS CREATED HERE AND NONE MAY BE until the list on /portal/
--  is worked through. That list is on the page it gates for a reason.
--
--  The renewal period (36 months) and the warning window (90 days) are
--  constants at the top of dbs_state(). Changing either is one line and a
--  migration — which is the right amount of ceremony for a decision the
--  safeguarding lead signs off.
-- ===========================================================================
