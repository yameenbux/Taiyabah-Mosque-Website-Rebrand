-- ===========================================================================
--  023_foodbank_volunteers.sql — register to help at the Taiyabah Food Bank
--
--  Asked for on 12 September 2026. The food bank is not open. The point of
--  registering early is twofold: somebody who wants to help can say so while
--  they are thinking about it, and the committee can see how many people are
--  actually willing before they commit to opening.
--
--  So this table answers one question — "how many, and who do we ring?" — and
--  is deleted twelve months after somebody registers.
--
--  WHAT THIS TABLE HOLDS AND WHY EACH FIELD IS HERE. Under Article 5(1)(c)
--  every field needs a reason, and "it was on the form" is not one:
--
--    full_name, phone           how the masjid rings them. Required.
--    email                      only if they asked to be contacted by email.
--    gender                     the rota. Confirmed with the committee on
--                               12 September 2026; the form says so out loud.
--    age                        16 is the floor (see section 2).
--    preferred_contact          so nobody texts a person who wanted a call.
--    sunday_mornings, frequency what the rota is actually built from.
--    skills                     optional. A driver or a first-aider is worth
--                               knowing about.
--    consent, consented_at      the lawful basis. Consent, because nobody has
--                               to volunteer and they must be able to say no.
--
--  There is no address, no date of birth and no ethnicity. None of them help
--  ring somebody about a Sunday morning.
--
--  Prerequisites: 011 (verified_admin / verified_office), and admin_audit.
--  Idempotent — safe to run twice.
--
--  *** STANDING RULE: re-run 011_require_two_step.sql after this. ***
-- ===========================================================================

begin;

do $$
begin
  if to_regprocedure('public.verified_office()') is null then
    raise exception 'public.verified_office() does not exist. Run 011_require_two_step.sql first.';
  end if;
  if to_regclass('public.admin_audit') is null then
    raise exception 'public.admin_audit does not exist. Run the earlier migrations first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
--  1. The table
-- ---------------------------------------------------------------------------
create table if not exists public.foodbank_volunteers (
  id                uuid primary key default gen_random_uuid(),
  reference         text        not null unique,

  full_name         text        not null,
  phone             text        not null,
  email             text,

  gender            text        not null,
  age               int         not null,

  preferred_contact text        not null,
  sunday_mornings   boolean     not null,
  frequency         text        not null,
  skills            text,

  consent           boolean     not null,
  consented_at      timestamptz not null default now(),

  -- The office's own working state. Nothing the volunteer sees.
  status            text        not null default 'waiting',
  contacted_at      timestamptz,
  contacted_by      uuid,
  note              text,

  created_at        timestamptz not null default now()
);

-- Constraints as a separate idempotent block so re-running the file does not
-- fail on an already-constrained table.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'fbv_gender_known') then
    alter table public.foodbank_volunteers add constraint fbv_gender_known
      check (gender in ('male', 'female'));
  end if;

  -- ---------------------------------------------------------------------
  --  2. SIXTEEN IS A CONSTRAINT, NOT A MESSAGE ON A FORM
  --
  --  A check that only exists in JavaScript does not exist: anybody can post
  --  straight at the API. If a fourteen-year-old's name, mobile number and
  --  email land in this table, the masjid is holding a child's contact
  --  details gathered through a web form with no parent anywhere near it —
  --  and it would be holding them for a year.
  --
  --  The floor is 16, agreed 12 September 2026. Under-16s are told on the
  --  form to have a parent ring the office instead, which is the right
  --  conversation to have with a person rather than a form.
  --
  --  The upper bound is not a joke: it catches a year of birth typed into an
  --  age box, which is the single most common way this field gets filled in
  --  wrong, and which would otherwise sit in the office's list as a
  --  2,026-year-old volunteer.
  -- ---------------------------------------------------------------------
  if not exists (select 1 from pg_constraint where conname = 'fbv_age_sixteen_or_over') then
    alter table public.foodbank_volunteers add constraint fbv_age_sixteen_or_over
      check (age >= 16 and age <= 110);
  end if;

  if not exists (select 1 from pg_constraint where conname = 'fbv_contact_method_known') then
    alter table public.foodbank_volunteers add constraint fbv_contact_method_known
      check (preferred_contact in ('phone', 'text', 'email'));
  end if;

  --  Choosing email as the way to be contacted and leaving the email box
  --  empty is a volunteer the masjid cannot reach. The form asks; this makes
  --  sure.
  if not exists (select 1 from pg_constraint where conname = 'fbv_email_if_email_preferred') then
    alter table public.foodbank_volunteers add constraint fbv_email_if_email_preferred
      check (preferred_contact <> 'email'
             or (email is not null and length(btrim(email)) > 3));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'fbv_frequency_known') then
    alter table public.foodbank_volunteers add constraint fbv_frequency_known
      check (frequency in ('weekly', 'fortnightly', 'monthly'));
  end if;

  if not exists (select 1 from pg_constraint where conname = 'fbv_status_known') then
    alter table public.foodbank_volunteers add constraint fbv_status_known
      check (status in ('waiting', 'contacted', 'helping', 'withdrawn'));
  end if;

  --  ---------------------------------------------------------------------
  --   CONSENT IS THE LAWFUL BASIS, SO A ROW WITHOUT IT IS NOT LAWFUL TO HOLD
  --
  --   Not "the form has a tick box". The row cannot exist without the tick,
  --   which means no amount of careless code upstream can create one.
  --  ---------------------------------------------------------------------
  if not exists (select 1 from pg_constraint where conname = 'fbv_consent_required') then
    alter table public.foodbank_volunteers add constraint fbv_consent_required
      check (consent is true);
  end if;
end $$;

create index if not exists fbv_created_idx  on public.foodbank_volunteers (created_at desc);
create index if not exists fbv_status_idx   on public.foodbank_volunteers (status);

comment on table public.foodbank_volunteers is
  'People who have registered to help at the Taiyabah Food Bank before it opens. Deleted twelve months after registering — see purge_old_volunteers().';


-- ---------------------------------------------------------------------------
--  3. Row level security
--
--  Nobody reads this table without being signed in, verified at aal2, and
--  holding office or admin. It is a list of names, ages and mobile numbers of
--  people who offered to help; there is no version of "public" that is right.
--
--  There is no INSERT policy at all. The public writes through the function
--  in section 4 and nowhere else, so the shape of what can be written is
--  fixed in one place rather than being whatever the browser felt like
--  sending.
-- ---------------------------------------------------------------------------
alter table public.foodbank_volunteers enable row level security;

drop policy if exists fbv_read   on public.foodbank_volunteers;
drop policy if exists fbv_update on public.foodbank_volunteers;

create policy fbv_read on public.foodbank_volunteers
  for select using (public.verified_office() or public.verified_admin());

create policy fbv_update on public.foodbank_volunteers
  for update using (public.verified_office() or public.verified_admin())
          with check (public.verified_office() or public.verified_admin());

--  Supabase grants ALL on a new table in public to both anon and
--  authenticated by default, so "grant select, update" ADDS to that rather
--  than describing it. Found by reading the grants back off production after
--  applying this file, not by reasoning about it — which is the only way
--  anybody finds it.
--
--  RLS was already blocking INSERT and DELETE, because there is no policy for
--  either. But a table protected only by the ABSENCE of a policy is one
--  careless "for all" policy away from being writable by any signed-in user,
--  and this one holds people's mobile numbers.
revoke all on public.foodbank_volunteers from anon;
revoke all on public.foodbank_volunteers from authenticated;
grant select, update on public.foodbank_volunteers to authenticated;


-- ---------------------------------------------------------------------------
--  4. Registering
--
--  security definer, because the anon role cannot touch the table. Everything
--  the public can put in this table goes through here.
-- ---------------------------------------------------------------------------
create or replace function public.register_foodbank_volunteer(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_name  text := btrim(coalesce(payload->>'full_name', ''));
  v_phone text := btrim(coalesce(payload->>'phone', ''));
  v_email text := nullif(btrim(lower(coalesce(payload->>'email', ''))), '');
  v_gender text := lower(btrim(coalesce(payload->>'gender', '')));
  v_age   int;
  v_pref  text := lower(btrim(coalesce(payload->>'preferred_contact', '')));
  v_sun   boolean;
  v_freq  text := lower(btrim(coalesce(payload->>'frequency', '')));
  v_skills text := nullif(btrim(coalesce(payload->>'skills', '')), '');
  v_consent boolean := coalesce((payload->>'consent')::boolean, false);
  v_ref   text;
  v_existing record;
begin
  --  Age is read defensively: a non-numeric age must come back as a polite
  --  refusal, not as a 22P02 the browser shows the volunteer as a raw
  --  Postgres error.
  begin
    v_age := (payload->>'age')::int;
  exception when others then
    raise exception 'Please give your age as a number.' using errcode = 'check_violation';
  end;

  begin
    v_sun := (payload->>'sunday_mornings')::boolean;
  exception when others then
    v_sun := null;
  end;

  if v_name = '' or length(v_name) < 2 then
    raise exception 'Please give your name.' using errcode = 'check_violation';
  end if;
  if v_phone = '' or length(regexp_replace(v_phone, '\D', '', 'g')) < 10 then
    raise exception 'Please give a contact number the masjid can reach you on.'
      using errcode = 'check_violation';
  end if;
  if not v_consent then
    raise exception 'The masjid cannot keep your details without your agreement.'
      using errcode = 'check_violation';
  end if;
  if v_age is null or v_age < 16 then
    raise exception 'You need to be 16 or over to register online. If you are younger and would like to help, please ask a parent to ring the office.'
      using errcode = 'check_violation';
  end if;
  if v_sun is null then
    raise exception 'Please say whether you are free on Sunday mornings.'
      using errcode = 'check_violation';
  end if;

  --  Registering twice is not an error worth showing anybody. Somebody who
  --  presses the button again a fortnight later gets their own reference back
  --  and one row, rather than an error message or a duplicate in the office's
  --  list. Matched on phone first because that is the field everybody fills
  --  in.
  select * into v_existing
    from public.foodbank_volunteers
   where regexp_replace(phone, '\D', '', 'g') = regexp_replace(v_phone, '\D', '', 'g')
      or (v_email is not null and lower(email) = v_email)
   order by created_at
   limit 1;

  if found then
    update public.foodbank_volunteers
       set full_name = v_name,
           email     = coalesce(v_email, email),
           gender    = case when v_gender in ('male','female') then v_gender else gender end,
           age       = v_age,
           preferred_contact = case when v_pref in ('phone','text','email') then v_pref else preferred_contact end,
           sunday_mornings   = v_sun,
           frequency = case when v_freq in ('weekly','fortnightly','monthly') then v_freq else frequency end,
           skills    = coalesce(v_skills, skills)
     where id = v_existing.id;

    return jsonb_build_object('reference', v_existing.reference, 'already', true);
  end if;

  --  FV-26-0001. The year is the masjid's own reference, not a key.
  v_ref := 'FV-' || to_char(now(), 'YY') || '-' ||
           lpad((select count(*) + 1 from public.foodbank_volunteers)::text, 4, '0');

  insert into public.foodbank_volunteers
    (reference, full_name, phone, email, gender, age, preferred_contact,
     sunday_mornings, frequency, skills, consent)
  values
    (v_ref, v_name, v_phone, v_email, v_gender, v_age, v_pref,
     v_sun, v_freq, v_skills, v_consent);

  return jsonb_build_object('reference', v_ref, 'already', false);
end $$;

grant execute on function public.register_foodbank_volunteer(jsonb) to anon, authenticated;

comment on function public.register_foodbank_volunteer(jsonb) is
  'The only way the public can write to foodbank_volunteers. Refuses under-16s and rows without consent.';


-- ---------------------------------------------------------------------------
--  5. What the office sees
-- ---------------------------------------------------------------------------
create or replace function public.foodbank_volunteer_summary()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case when not (public.verified_office() or public.verified_admin())
              then jsonb_build_object('allowed', false)
         else jsonb_build_object(
           'allowed',     true,
           'total',       count(*),
           'waiting',     count(*) filter (where status = 'waiting'),
           'contacted',   count(*) filter (where status = 'contacted'),
           'helping',     count(*) filter (where status = 'helping'),
           'withdrawn',   count(*) filter (where status = 'withdrawn'),
           'sundays',     count(*) filter (where sunday_mornings and status <> 'withdrawn'),
           'weekly',      count(*) filter (where frequency = 'weekly' and status <> 'withdrawn'),
           'fortnightly', count(*) filter (where frequency = 'fortnightly' and status <> 'withdrawn'),
           'monthly',     count(*) filter (where frequency = 'monthly' and status <> 'withdrawn'),
           'male',        count(*) filter (where gender = 'male' and status <> 'withdrawn'),
           'female',      count(*) filter (where gender = 'female' and status <> 'withdrawn'))
         end
    from public.foodbank_volunteers
$$;

revoke all     on function public.foodbank_volunteer_summary() from public, anon;
grant  execute on function public.foodbank_volunteer_summary() to authenticated;

create or replace function public.set_volunteer_status(p_reference text, p_status text, p_note text default null)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not (public.verified_office() or public.verified_admin()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  if p_status not in ('waiting', 'contacted', 'helping', 'withdrawn') then
    raise exception 'Unknown status %', p_status using errcode = 'check_violation';
  end if;

  update public.foodbank_volunteers
     set status       = p_status,
         note         = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note),
         contacted_at = case when p_status = 'waiting' then contacted_at else now() end,
         contacted_by = case when p_status = 'waiting' then contacted_by else auth.uid() end
   where reference = p_reference;

  if not found then
    raise exception 'No volunteer with reference %', p_reference using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (action, detail)
  values ('volunteer_status', jsonb_build_object(
            'reference', p_reference, 'status', p_status, 'by', auth.uid()));
end $$;

revoke all     on function public.set_volunteer_status(text, text, text) from public, anon;
grant  execute on function public.set_volunteer_status(text, text, text) to authenticated;


-- ---------------------------------------------------------------------------
--  6. Twelve months, on a timer
--
--  The website tells people their details are kept for twelve months. Under
--  Article 5(1)(e) the published period is the promise, and migration 015 is
--  the record of what happens when a promise like that depends on somebody
--  remembering: three of them had quietly not been kept.
--
--  No is_admin() check here, deliberately, for the reason set out at length
--  in 015: pg_cron holds no JWT, auth.uid() is null, and a purge that checks
--  for an administrator would raise every night and delete nothing. Access is
--  controlled by the revoke below, which is the right tool for a job that
--  nobody signs in to do.
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_volunteers(dry_run boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_n int;
begin
  if dry_run then
    select count(*) into v_n
      from public.foodbank_volunteers
     where created_at < now() - interval '12 months';
    return jsonb_build_object('would_delete', v_n, 'dry_run', true);
  end if;

  delete from public.foodbank_volunteers
   where created_at < now() - interval '12 months';
  get diagnostics v_n = row_count;

  if v_n > 0 then
    insert into public.admin_audit (action, detail)
    values ('volunteers_purged', jsonb_build_object('deleted', v_n));
  end if;

  return jsonb_build_object('deleted', v_n, 'dry_run', false);
end $$;

revoke all on function public.purge_old_volunteers(boolean) from public, anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
--  7. The schedule, outside the transaction
--
--  03:25, between the retention purge and the donations purge, so a slow
--  night does not have three of them contending at once.
-- ---------------------------------------------------------------------------
select cron.unschedule('purge-volunteers')
 where exists (select 1 from cron.job where jobname = 'purge-volunteers');

select cron.schedule('purge-volunteers', '25 3 * * *',
                     $$select public.purge_old_volunteers()$$);

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
--
--  Then prove the two guarantees are real. BOTH of these must fail:
--
--    select public.register_foodbank_volunteer(
--      '{"full_name":"A Child","phone":"07700900000","gender":"male","age":14,
--        "preferred_contact":"phone","sunday_mornings":true,
--        "frequency":"weekly","consent":true}'::jsonb);
--
--    insert into public.foodbank_volunteers
--      (reference, full_name, phone, gender, age, preferred_contact,
--       sunday_mornings, frequency, consent)
--    values ('FV-TEST-X','No Consent','07700900001','male',30,'phone',
--            true,'weekly', false);
--
--  And this must return nothing at all when signed out:
--
--    select count(*) from public.foodbank_volunteers;
-- ===========================================================================
