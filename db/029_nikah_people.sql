-- ===========================================================================
--  029_nikah_people.sql — the particulars of the five people at a nikāḥ
--
--  WHAT CHANGED, AND WHY IT IS WORTH WRITING DOWN.
--
--  010 said, in its own header: "Data kept deliberately thin… NOT the couple's
--  names, addresses, documents or witnesses — the office takes those on the
--  phone once a date is agreed. There is no reason for the website to hold
--  them."
--
--  On 14 September 2026 the masjid decided otherwise: the public form now
--  collects, for the bridegroom, the bride, the bride's representative and
--  two witnesses, a full name, an age, a home address and an occupation —
--  plus, for the bride and groom, which proof-of-address and identity
--  document they can bring.
--
--  That was put to the masjid with the argument against it (five households'
--  details held for weddings that may never happen; two witnesses who filled
--  in nothing themselves and agreed to nothing; a form long enough that fewer
--  people will finish it) and the masjid chose it anyway. That is their call
--  to make. What this file must do is make the consequences survivable:
--
--    * the rows die with their request, so the existing twelve-month purge
--      covers them and nobody has to remember a second job;
--    * anon can INSERT through this function and can never read back;
--    * the under-18 rule is in the database, not only in a browser.
--
--  THE UNDER-18 RULE IS NOT A PREFERENCE. Since 27 February 2023 it is a
--  criminal offence in England and Wales to cause a child under 18 to enter a
--  marriage, and the offence expressly covers a religious ceremony whether or
--  not it is legally binding — a nikāḥ counts, and no coercion is needed for
--  the offence to be made out. The form refuses it; so does this.
--
--  STILL OUTSTANDING before this is a comfortable thing to be running: the
--  privacy notice has to describe what is now held and about whom, and the
--  masjid's ICO entry and lawful-basis note have to match. The retention
--  promise itself does not change — twelve months, inherited by cascade.
--
--  Prerequisites: 010 applied. Depends on public.verified_office().
-- ===========================================================================

begin;

do $$
begin
  if to_regclass('public.nikah_requests') is null then
    raise exception 'public.nikah_requests does not exist. Run 010_nikah_requests.sql first.';
  end if;
end $$;

create table if not exists public.nikah_people (
  id           uuid primary key default gen_random_uuid(),
  request_id   uuid not null
                 references public.nikah_requests(id) on delete cascade,

  --  The five people, named. `wali` is the bride's representative.
  role         text not null
                 check (role in ('groom','bride','wali','witness_1','witness_2')),

  full_name    text not null check (length(btrim(full_name)) >= 2),
  --  AGE, not date of birth. The masjid needs to know somebody is an adult,
  --  not the day they were born, and a date of birth is the more damaging
  --  field to be holding about five people.
  age          int  not null check (age between 0 and 120),

  address_line text not null check (length(btrim(address_line)) >= 2),
  town         text not null check (length(btrim(town)) >= 2),
  --  Loose on purpose. A clever postcode pattern rejects real addresses —
  --  this only catches a phone number typed into the wrong box.
  postcode     text not null
                 check (upper(regexp_replace(postcode, '\s', '', 'g'))
                        ~ '^[A-Z]{1,2}[0-9][A-Z0-9]?[0-9][A-Z]{2}$'),
  occupation   text,

  --  WHICH document they can bring, never the document itself. Nothing on
  --  this site uploads a passport, and nothing should.
  proof_address text,
  proof_id      text,

  created_at   timestamptz not null default now(),

  --  One of each per request. A request with two brides is a mistake, not a
  --  configuration.
  unique (request_id, role),

  --  The rule the whole file exists for.
  constraint couple_must_be_adults
    check (role not in ('groom','bride') or age >= 18)
);

create index if not exists nikah_people_request_idx
  on public.nikah_people (request_id);

alter table public.nikah_people enable row level security;

--  Supabase grants ALL on a new public table to anon and authenticated by
--  default. It has bitten this project before, so it is revoked explicitly
--  rather than left to RLS alone.
revoke all on public.nikah_people from anon, authenticated;
grant select on public.nikah_people to authenticated;

drop policy if exists nikah_people_read on public.nikah_people;
create policy nikah_people_read on public.nikah_people
  for select using (public.verified_office());

--  No insert policy, on purpose. Rows arrive only through
--  request_nikah_date(), which is security definer. There is nothing for a
--  visitor to write to directly and nothing to read back.

comment on table public.nikah_people is
  'Particulars of the five people at a nikāḥ, collected on the public form. '
  'Cascades off nikah_requests, so the twelve-month purge covers it. '
  'Bride and groom must be 18 or over — a nikāḥ for a child is a criminal '
  'offence in England and Wales, legally binding or not.';

-- ---------------------------------------------------------------------------
--  request_nikah_date — now takes the people with it
--
--  All five in the same transaction as the request. A request that saved and
--  then lost its people would look complete to the office and be useless, and
--  they would have no way of telling which rows were which.
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
    raise exception 'Please choose a prayer, or tell us you are flexible';
  end if;
  if (v_slot = 'flexible') <> v_flex then
    raise exception 'The chosen slot and the flexible flag disagree';
  end if;
  if v_slot = 'saturday_11' and extract(isodow from v_date) <> 6 then
    raise exception 'The 11am slot is only available on a Saturday';
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

revoke all on function public.request_nikah_date(jsonb) from public;
grant execute on function public.request_nikah_date(jsonb) to anon, authenticated;

commit;
