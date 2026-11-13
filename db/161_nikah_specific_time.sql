-- 161 — the nikāḥ form asks for a clock time, not a prayer.
--
-- WHY. The form takes two dates: a first choice and an alternative. A
-- jamāʿah clock time belongs to exactly one of them, so the screen — which
-- only ever had the first date to work from — printed the first date's times
-- underneath every prayer, and they were wrong for anybody the office ended
-- up booking on the second. The masjid decided to ask for the time itself.
--
-- NOTHING IS TAKEN AWAY. Every old slot value stays legal:
--   * requests already recorded as 'after_zuhr' and the rest must still read
--     back, and the office screens still render them;
--   * the build currently in the App Store and on Play goes on sending them
--     until every phone has updated, which is weeks, not days.
-- So this widens the CHECK rather than replacing the vocabulary.
--
-- WHERE EACH RULE LIVES. The table enforces the SHAPE of preferred_time for
-- a 'specific' request, because a row without one is meaningless whoever
-- wrote it. The window (08:00-22:00) and the quarter-hour step are enforced
-- in request_nikah_date() instead — they are rules about what a FAMILY may
-- ask for through the form, and the office must stay free to record an
-- agreed 7:30am in preferred_time when it has spoken to somebody.
--
-- NOT YET APPLIED to production.

begin;

-- ---- slot: add 'specific', keep every historical value --------------------
-- The original CHECK was written inline on the column in db/010, so its name
-- is whatever Postgres generated. Find it by what it says rather than by a
-- name this file is guessing at.
do $mig$
declare c text;
begin
  select conname into c
    from pg_constraint
   where conrelid = 'public.nikah_requests'::regclass
     and contype  = 'c'
     and pg_get_constraintdef(oid) like '%after_maghrib%'
     and pg_get_constraintdef(oid) not like '%specific%'
   limit 1;
  if c is not null then
    execute format('alter table public.nikah_requests drop constraint %I', c);
  end if;
end
$mig$;

-- Idempotent: the DO block above only recognises the ORIGINAL constraint (it
-- excludes any definition already mentioning 'specific'), so on a second run
-- it finds nothing and this ADD would collide with the one it made the first
-- time. Dropping by the known name first makes re-running this file harmless.
alter table public.nikah_requests
  drop constraint if exists nikah_requests_slot_check;
alter table public.nikah_requests
  add constraint nikah_requests_slot_check
  check (slot in ('after_fajr','after_zuhr','after_asr','after_maghrib',
                  'after_isha','saturday_11','flexible','specific'));

-- ---- a chosen time has to actually be one -------------------------------
alter table public.nikah_requests
  drop constraint if exists specific_slot_has_a_time;
alter table public.nikah_requests
  add constraint specific_slot_has_a_time
  -- `is not null` is not decoration. A CHECK passes when it evaluates to
  -- NULL, and `null ~ '...'` is NULL, so without this a 'specific' request
  -- with no time at all sails straight through. Proved against Postgres 16
  -- before this line existed: the row was accepted.
  check (slot <> 'specific'
         or (preferred_time is not null
             and preferred_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'));

comment on column public.nikah_requests.preferred_time is
  'HH:MM. For slot=''specific'' it is the time the family chose and is '
  'required. For the older prayer slots it is the jamāʿah time as published '
  'on the day they asked, kept so the office knows what they were looking '
  'at. Null when flexible.';

-- ---- request_nikah_date(): accept 'specific' ----------------------------
-- Lifted verbatim from db/029 and changed in two places only: the 'specific'
-- validation block below the Saturday rule, and the null-slot message, which
-- still said "choose a prayer".

create or replace function public.request_nikah_date(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  HORIZON_DAYS constant int := 365;
  NOTICE_DAYS  constant int := 14;   -- the masjid needs a fortnight
  ROLES constant text[] := array['groom','bride','wali','witness_1','witness_2'];
  TITLES constant text[] := array['The bridegroom','The bride',
                                  'The bride''s representative',
                                  'Witness 1','Witness 2'];
  v_date  date := (payload ->> 'preferred_date')::date;
  --  Still read, still stored. The page stopped asking for a second choice in
  --  September 2026; requests taken before that keep theirs, and anything
  --  else posting one is still honoured.
  v_alt   date := nullif(payload ->> 'alternative_date','')::date;
  v_email text := lower(trim(payload ->> 'contact_email'));
  v_flex  boolean := coalesce((payload ->> 'time_flexible')::boolean, false);
  v_slot  text := nullif(payload ->> 'slot','');
  v_time  text := nullif(payload ->> 'preferred_time','');
  v_ref   text;
  v_id    uuid;
  v_people jsonb := coalesce(payload -> 'people', '[]'::jsonb);
  v_p     jsonb;
  v_age   int;
  i       int;
begin
  if v_date is null then
    raise exception 'Please choose a date';
  end if;
  if v_date < current_date then
    raise exception 'That date has already passed';
  end if;
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
    raise exception 'Please choose a time, or tell us you are flexible';
  end if;
  if (v_slot = 'flexible') <> v_flex then
    raise exception 'The chosen slot and the flexible flag disagree';
  end if;
  if v_slot = 'saturday_11' and extract(isodow from v_date) <> 6 then
    raise exception 'The 11am slot is only available on a Saturday';
  end if;

  --  'specific' is a clock time the family chose themselves, and it arrives
  --  as the HH:MM string preferred_time has always held. The app and the
  --  website both hold their clicker inside 08:00-22:00 on quarter hours
  --  (native/src/nikah-time.js, and the time input's min/max/step on the
  --  site). This is that same gate applied on the way in, because a form is
  --  a convenience and not a boundary — anyone can post this payload.
  if v_slot = 'specific' then
    if v_time is null then
      raise exception 'Please choose a time';
    end if;
    if v_time !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      raise exception 'That is not a valid time';
    end if;
    if v_time::time < time '08:00' or v_time::time > time '22:00' then
      raise exception 'Please choose a time between 8:00am and 10:00pm';
    end if;
    if extract(minute from v_time::time)::int % 15 <> 0 then
      raise exception 'Please choose a time on the quarter hour';
    end if;
  end if;

  -- ---- the five people, checked BEFORE anything is written ---------------
  for i in 1 .. array_length(ROLES, 1) loop
    select p into v_p
      from jsonb_array_elements(v_people) p
     where p ->> 'role' = ROLES[i]
     limit 1;

    if v_p is null then
      raise exception '% is missing from the request', TITLES[i];
    end if;
    if coalesce(btrim(v_p ->> 'full_name'), '') = '' then
      raise exception '% needs a full name', TITLES[i];
    end if;

    v_age := nullif(v_p ->> 'age', '')::int;
    if v_age is null then
      raise exception '% needs an age', TITLES[i];
    end if;
    --  Said in full, because whoever reads this error should understand it is
    --  not the masjid being awkward.
    if ROLES[i] in ('groom','bride') and v_age < 18 then
      raise exception '% must be 18 or over. The masjid cannot perform a nikah for anyone under 18 — since February 2023 that is a criminal offence in England and Wales, whether or not the marriage is registered.',
        TITLES[i];
    end if;
    if coalesce(btrim(v_p ->> 'address_line'), '') = ''
       or coalesce(btrim(v_p ->> 'town'), '') = ''
       or coalesce(btrim(v_p ->> 'postcode'), '') = '' then
      raise exception '% needs a full address', TITLES[i];
    end if;
  end loop;

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
  )
  returning id into v_id;

  insert into public.nikah_people (
    request_id, role, full_name, age, address_line, town, postcode,
    occupation, proof_address, proof_id)
  select v_id,
         p ->> 'role',
         btrim(p ->> 'full_name'),
         (p ->> 'age')::int,
         btrim(p ->> 'address_line'),
         btrim(p ->> 'town'),
         upper(btrim(p ->> 'postcode')),
         nullif(btrim(coalesce(p ->> 'occupation','')), ''),
         nullif(btrim(coalesce(p ->> 'proof_address','')), ''),
         nullif(btrim(coalesce(p ->> 'proof_id','')), '')
    from jsonb_array_elements(v_people) p
   where p ->> 'role' = any(ROLES);

  --  THE AUDIT ROW STAYS THIN. admin_audit is read on a dashboard by every
  --  administrator; a witness's home address has no business being in it.
  insert into public.admin_audit (action, detail)
  values ('nikah_request', jsonb_build_object('reference', v_ref, 'date', v_date));

  return jsonb_build_object('reference', v_ref, 'preferred_date', v_date, 'slot', v_slot);
end;
$$;
grant execute on function public.request_nikah_date(jsonb) to anon, authenticated;

commit;
