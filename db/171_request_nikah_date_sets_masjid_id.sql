-- 171 — request_nikah_date() sets masjid_id.
--
-- WHY. The multi-masjid change added a NOT NULL masjid_id to nikah_requests,
-- nikah_people and admin_audit, and the sibling request functions (hall, imam,
-- charity) were updated to resolve the masjid and set it. request_nikah_date was
-- missed: it never called masjid_or_sole() and set masjid_id on none of its three
-- inserts. So EVERY nikah date request failed on the first insert with
--
--   null value in column "masjid_id" of relation "nikah_requests"
--
-- and the app showed a bare "That didn't send." It has been broken for all users,
-- on every build, since the column became NOT NULL.
--
-- The fix mirrors the working functions: resolve v_masjid at the top (which, via
-- db/170, is the sole live masjid when the caller passes no slug) and set it on
-- the nikah_requests, nikah_people and admin_audit inserts. The duplicate-request
-- check is scoped to the masjid too. Nothing else about the function changes.
--
-- Applied to production directly on 2026-11-20 (Supabase migration
-- request_nikah_date_sets_masjid_id); this file is the record.

create or replace function public.request_nikah_date(payload jsonb)
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  HORIZON_DAYS constant int := 365;
  NOTICE_DAYS  constant int := 14;   -- the masjid needs a fortnight
  ROLES constant text[] := array['groom','bride','wali','witness_1','witness_2'];
  TITLES constant text[] := array['The bridegroom','The bride',
                                  'The bride''s representative',
                                  'Witness 1','Witness 2'];
  v_masjid uuid := public.masjid_or_sole(payload ->> 'masjid');
  v_date  date := (payload ->> 'preferred_date')::date;
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
              where masjid_id = v_masjid
                and lower(contact_email) = v_email
                and preferred_date = v_date
                and status in ('new','contacted')) then
    raise exception 'We already have a request from this email address for that date. The office will be in touch.';
  end if;

  v_ref := 'NK-' || to_char(now(),'YY') || '-' ||
           lpad(nextval('public.nikah_reference_seq')::text, 4, '0');

  insert into public.nikah_requests (
    masjid_id, reference, preferred_date, alternative_date, slot, preferred_time, time_flexible,
    guests_estimate, contact_name, contact_role, contact_phone, contact_email,
    notes, privacy_accepted
  ) values (
    v_masjid, v_ref, v_date, v_alt, v_slot,
    case when v_flex then null else v_time end, v_flex,
    nullif(payload ->> 'guests_estimate','')::int,
    payload ->> 'contact_name', payload ->> 'contact_role',
    payload ->> 'contact_phone', v_email,
    nullif(payload ->> 'notes',''),
    (payload ->> 'privacy_accepted')::boolean
  )
  returning id into v_id;

  insert into public.nikah_people (
    masjid_id, request_id, role, full_name, age, address_line, town, postcode,
    occupation, proof_address, proof_id)
  select v_masjid, v_id,
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

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'nikah_request', jsonb_build_object('reference', v_ref, 'date', v_date));

  return jsonb_build_object('reference', v_ref, 'preferred_date', v_date, 'slot', v_slot);
end;
$function$;
