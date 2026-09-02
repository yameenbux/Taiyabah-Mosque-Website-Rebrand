-- ===========================================================================
--  005_nikah_requests.sql — requests for a Nikāḥ date
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
--  in the privacy notice. Same shortlist as 004_courses.sql, and the same ICO
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
  constraint flexible_or_a_time
    check (time_flexible or preferred_time is not null)
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

-- Not "force row level security" — same reasoning as 004_courses.sql. The
-- function below reads the table to spot a duplicate request, and FORCE would
-- apply RLS to the function's owner, silently returning nothing. anon still
-- holds no privileges here at all, and authenticated is filtered to is_admin().
create policy admin_read_nikah on public.nikah_requests
  for select to authenticated using (public.is_admin());
create policy admin_update_nikah on public.nikah_requests
  for update to authenticated using (public.is_admin()) with check (public.is_admin());
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
  v_date  date := (payload ->> 'preferred_date')::date;
  v_alt   date := nullif(payload ->> 'alternative_date','')::date;
  v_email text := lower(trim(payload ->> 'contact_email'));
  v_flex  boolean := coalesce((payload ->> 'time_flexible')::boolean, false);
  v_time  text := nullif(payload ->> 'preferred_time','');
  v_ref   text;
begin
  if v_date is null then
    raise exception 'Please choose a date';
  end if;
  if v_date < current_date then
    raise exception 'That date has already passed';
  end if;
  if v_date > current_date + HORIZON_DAYS then
    raise exception 'Requests can only be made up to a year ahead';
  end if;
  if v_alt is not null and (v_alt < current_date or v_alt > current_date + HORIZON_DAYS) then
    raise exception 'The alternative date must also be within the next year';
  end if;
  if not v_flex and v_time is null then
    raise exception 'Please choose a time, or tell us you are flexible';
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
    reference, preferred_date, alternative_date, preferred_time, time_flexible,
    guests_estimate, contact_name, contact_role, contact_phone, contact_email,
    notes, privacy_accepted
  ) values (
    v_ref, v_date, v_alt, case when v_flex then null else v_time end, v_flex,
    nullif(payload ->> 'guests_estimate','')::int,
    payload ->> 'contact_name', payload ->> 'contact_role',
    payload ->> 'contact_phone', v_email,
    nullif(payload ->> 'notes',''),
    (payload ->> 'privacy_accepted')::boolean
  );

  insert into public.admin_audit (action, detail)
  values ('nikah_request', jsonb_build_object('reference', v_ref, 'date', v_date));

  return jsonb_build_object('reference', v_ref, 'preferred_date', v_date);
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
