-- ===========================================================================
--  010_nikah_requests.sql — requests for a Nikāḥ date
--
--  *** NOT APPLIED YET. *** The Marriage page ships with the calendar visible
--  and the office phone number where the form will go. Flipping REQUESTS_OPEN
--  in index_template.html turns the form on, and it must not be flipped until
--  this has been run.
--
--  A REQUEST, not a booking. Nothing here reserves anything. The office reads
--  the request, rings the person named on it, and confirms or declines. That
--  is why there is no capacity logic and no availability shown anywhere: the
--  masjid does not publish its nikāḥ diary, and a calendar that painted days
--  green would be inventing information.
--
--  Data kept deliberately thin: who to ring, when they would like it, and
--  anything they want us to know. NOT the couple's names, addresses,
--  documents or witnesses — the office takes those on the phone once a date is
--  agreed. There is no reason for the website to hold them.
--
--  Still personal data the masjid controls, so before this is applied:
--  ICO registration, a documented lawful basis, a retention period, and a line
--  in the privacy notice. Same shortlist as 009_courses.sql, and the same ICO
--  entry covers both.
--
--  Prerequisites: 001 and 002 applied. Depends on public.is_admin().
-- ===========================================================================

begin;

create table public.nikah_requests (
  id             uuid        primary key default gen_random_uuid(),
  reference      text        not null unique,
  submitted_at   timestamptz not null default now(),

  -- What they are asking for
  preferred_date date        not null,
  alternative_date date,
  -- WHAT they asked for, not just when. A nikāḥ is nearly always held straight
  -- after a congregational prayer, so the meaningful choice is the prayer;
  -- preferred_time is the jamā'ah clock time as published on the day they
  -- asked, kept alongside it because jamā'ah times move through the year and
  -- the office needs to know what the family were actually looking at.
  slot           text        not null
                   check (slot in ('after_fajr','after_zuhr','after_asr',
                                   'after_maghrib','after_isha',
                                   'saturday_11','flexible')),
  preferred_time text,                       -- 'HH:MM', null when flexible
  time_flexible  boolean     not null default false,
  guests_estimate int        check (guests_estimate is null or guests_estimate between 0 and 2000),

  -- Who to ring back
  contact_name   text        not null check (length(trim(contact_name)) > 0),
  contact_role   text        not null check (contact_role in ('groom','bride','family','other')),
  contact_phone  text        not null check (length(trim(contact_phone)) > 0),
  contact_email  text        not null check (contact_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  notes          text        check (length(coalesce(notes,'')) <= 600),

  privacy_accepted boolean   not null check (privacy_accepted),

  -- Office workflow
  status         text        not null default 'new'
                   check (status in ('new','contacted','confirmed','declined','withdrawn')),
  agreed_date    date,
  agreed_time    text,
  office_notes   text,
  reviewed_by    uuid references auth.users(id) on delete set null,
  reviewed_at    timestamptz,

  constraint alternative_after_or_equal_today
    check (alternative_date is null or alternative_date >= preferred_date - 365),
  constraint flexible_matches_slot
    check ((slot = 'flexible') = time_flexible),
  -- The Saturday late-morning slot exists for one reason: a nikāḥ before a
  -- wedding meal, which only ever happens on a Saturday. Anything else would
  -- be a mistake in the form.
  constraint saturday_slot_is_on_a_saturday
    check (slot <> 'saturday_11' or extract(isodow from preferred_date) = 6)
);

comment on table public.nikah_requests is
  'Requests for a Nikah date. A request only — nothing here is a confirmed booking.';

create sequence if not exists public.nikah_reference_seq;
create index nikah_status_idx on public.nikah_requests(status, preferred_date);

-- ---------------------------------------------------------------------------
-- Privileges — anon holds nothing on the table; one function is the only way in
-- ---------------------------------------------------------------------------
revoke all on public.nikah_requests from anon, authenticated;
grant select, update (status, agreed_date, agreed_time, office_notes, reviewed_by, reviewed_at)
  on public.nikah_requests to authenticated;

alter table public.nikah_requests enable row level security;

-- Not "force row level security" — same reasoning as 009_courses.sql. The
-- function below reads the table to spot a duplicate request, and FORCE would
-- apply RLS to the function's owner, silently returning nothing. anon still
-- holds no privileges here at all, and authenticated is filtered to is_admin().
-- The office works nikāḥ requests in the same place as hall bookings, so the
-- hall_office role reads and updates these too. Same rule as hall_bookings:
-- they may move the status and add notes, and may not touch what the family
-- actually asked for.
create policy office_read_nikah on public.nikah_requests
  for select to authenticated
  using (public.is_admin() or public.has_role(auth.uid(), 'hall_office'));
create policy office_update_nikah on public.nikah_requests
  for update to authenticated
  using (public.is_admin() or public.has_role(auth.uid(), 'hall_office'))
  with check (public.is_admin() or public.has_role(auth.uid(), 'hall_office'));
create policy definer_insert_nikah on public.nikah_requests
  for insert with check (true);
create policy definer_delete_nikah on public.nikah_requests
  for delete using (true);

-- ---------------------------------------------------------------------------
-- Submitting a request
-- ---------------------------------------------------------------------------

create or replace function public.request_nikah_date(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  HORIZON_DAYS constant int := 365;
  NOTICE_DAYS  constant int := 14;   -- the masjid needs a fortnight
  v_date  date := (payload ->> 'preferred_date')::date;
  v_alt   date := nullif(payload ->> 'alternative_date','')::date;
  v_email text := lower(trim(payload ->> 'contact_email'));
  v_flex  boolean := coalesce((payload ->> 'time_flexible')::boolean, false);
  v_slot  text := nullif(payload ->> 'slot','');
  v_time  text := nullif(payload ->> 'preferred_time','');
  v_ref   text;
begin
  if v_date is null then
    raise exception 'Please choose a date';
  end if;
  if v_date < current_date then
    raise exception 'That date has already passed';
  end if;
  -- Enforced here as well as in the page. The calendar simply does not offer
  -- the next fortnight, but a form can be driven from outside a browser and
  -- the office should never be handed a request it cannot honour.
  if v_date < current_date + NOTICE_DAYS then
    raise exception 'The masjid needs at least % days notice — the earliest date we can take is %',
      NOTICE_DAYS, to_char(current_date + NOTICE_DAYS, 'DD Mon YYYY');
  end if;
  if v_date > current_date + HORIZON_DAYS then
    raise exception 'Requests can only be made up to a year ahead';
  end if;
  if v_alt is not null and (v_alt < current_date or v_alt > current_date + HORIZON_DAYS) then
    raise exception 'The alternative date must also be within the next year';
  end if;
  if v_slot is null then
    raise exception 'Please choose a prayer, or tell us you are flexible';
  end if;
  if (v_slot = 'flexible') <> v_flex then
    raise exception 'The chosen slot and the flexible flag disagree';
  end if;
  if v_slot = 'saturday_11' and extract(isodow from v_date) <> 6 then
    raise exception 'The 11am slot is only available on a Saturday';
  end if;

  if exists (select 1 from public.nikah_requests
              where lower(contact_email) = v_email
                and preferred_date = v_date
                and status in ('new','contacted')) then
    raise exception 'We already have a request from this email address for that date. The office will be in touch.';
  end if;

  v_ref := 'NK-' || to_char(now(),'YY') || '-' ||
           lpad(nextval('public.nikah_reference_seq')::text, 4, '0');

  insert into public.nikah_requests (
    reference, preferred_date, alternative_date, slot, preferred_time, time_flexible,
    guests_estimate, contact_name, contact_role, contact_phone, contact_email,
    notes, privacy_accepted
  ) values (
    v_ref, v_date, v_alt, v_slot,
    case when v_flex then null else v_time end, v_flex,
    nullif(payload ->> 'guests_estimate','')::int,
    payload ->> 'contact_name', payload ->> 'contact_role',
    payload ->> 'contact_phone', v_email,
    nullif(payload ->> 'notes',''),
    (payload ->> 'privacy_accepted')::boolean
  );

  insert into public.admin_audit (action, detail)
  values ('nikah_request', jsonb_build_object('reference', v_ref, 'date', v_date));

  return jsonb_build_object('reference', v_ref, 'preferred_date', v_date, 'slot', v_slot);
end;
$$;

revoke all on function public.request_nikah_date(jsonb) from public;
grant execute on function public.request_nikah_date(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Retention
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_nikah_requests(retain_months int)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_deleted int;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator may purge requests';
  end if;
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be a positive number of months';
  end if;
  with gone as (
    delete from public.nikah_requests
     where status in ('declined','withdrawn')
       and submitted_at < now() - make_interval(months => retain_months)
    returning 1
  ) select count(*) into v_deleted from gone;
  insert into public.admin_audit (action, detail)
  values ('nikah_requests_purged',
          jsonb_build_object('deleted', v_deleted, 'retain_months', retain_months));
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_nikah_requests(int) from public;
grant execute on function public.purge_old_nikah_requests(int) to authenticated;

commit;
