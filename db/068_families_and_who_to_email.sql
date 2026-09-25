-- ===========================================================================
--  068_families_and_who_to_email.sql
--  20 September 2026
--
--  THE FEES SECTION CANNOT BE BUILT UNTIL THE MADRASAH KNOWS WHAT A FAMILY IS.
--
--  Everything the office actually does with money is done per FAMILY and not
--  per child. One bill covers three children. One bank transfer arrives for
--  all of them. The sibling discount is a statement about a family. A refund
--  when they leave in November goes back to the person who paid. Build fees
--  on the pupil and you get three bills to one house, three reminders to one
--  father, and a discount that has to be re-derived every time anybody asks.
--
--  So this file adds two things and nothing else:
--
--    madrasah_households   a family, with the payment reference they quote
--    madrasah_guardians    the adult to contact, and how
--
--  ---------------------------------------------------------------------------
--  THIS EXTENDS WHAT THE MASJID HOLDS. IT IS NOT COVERED BY THE DPIA AS WRITTEN.
--  ---------------------------------------------------------------------------
--
--  058's header set the rule for this table and it is being followed, not
--  dodged: "Add a column when a screen genuinely needs it and the DPIA covers
--  it." A screen genuinely needs it — the masjid asked for email reminders to
--  parents, and there is no parent's email anywhere in this database to send
--  one to. The DPIA does NOT presently cover it. The v1.0 assessment of
--  19 September scopes children's records and staff records. A guardian is a
--  new category of data subject.
--
--  That is an Article 35(11) review, not a blocker, and it is a small one:
--  the lawful basis is the same Article 6(1)(f) already argued for the
--  children's records, the data is ordinary rather than special category, and
--  the retention clock is the one already agreed. But it has to be WRITTEN
--  DOWN before reminders are switched on, and the privacy notice — which has
--  not been issued yet — has to say that the masjid holds a parent's name,
--  email and telephone number and what it does with them.
--
--  This migration therefore puts the obligation on the compliance list on the
--  madrasah portal rather than leaving it in a comment nobody opens. See the
--  bottom of this file. A note in a migration is not a control.
--
--  MINIMISATION. A guardian record is a name, an email, a phone number and
--  which family they belong to. No address — the masjid does not post fee
--  letters, and an address is the field that turns a mailing list into a
--  target list. No date of birth. No relationship-to-child, because the fees
--  screens never need to know and the admissions form asks it for a different
--  purpose. No second address for a separated parent; two guardians on the
--  same household covers that case without a schema for it.
--
--  RETENTION. A guardian is deleted when the last pupil in their household is
--  deleted, by the same three-year purge, because cascade from the household
--  does it. An EMPTY household — no pupils at all — is kept, because it may
--  be a family the office is mid-way through setting up, and is swept after
--  three years by purge_madrasah_households() which is scheduled at the foot
--  of this file. 067's rule applies: a purge nothing calls is not a purge.
--
--  Prerequisites: 058 (pupils), 067 (the purges are actually scheduled).
--  Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. A family
--
--  THE REFERENCE IS THE WHOLE POINT OF THIS TABLE.
--
--  Most madrasah fees arrive as a bank transfer, and a bank transfer carries
--  about eighteen usable characters of free text and nothing else. No email
--  address, no child's name, often not even the payer's full name — the
--  account is in the grandfather's name and the children are in the mother's.
--  Matching that to a family by eye is the job the Bank transfers screen
--  exists to do, and the only thing that makes it reliable is a short code
--  the family is told to quote every time.
--
--  MF-0001 upwards. Four digits because 543 pupils is perhaps 300 families
--  and 9,999 is comfortable for the life of the system. The prefix is MF and
--  not M or F because references get typed into a banking app by somebody
--  holding a toddler, and two letters of context stop it being confused with
--  the hall hire HH- and donation DN- references already in use.
--
--  The reference is generated here and is NOT editable. A reference somebody
--  can change is a reference that stops matching the transfers already sitting
--  in the bank statement.
-- ---------------------------------------------------------------------------
create sequence if not exists public.madrasah_household_ref_seq as integer start 1;

create table if not exists public.madrasah_households (
  id          uuid primary key default gen_random_uuid(),
  masjid_id   uuid not null references public.masjids(id) on delete cascade,
  reference   text not null,
  name        text not null,
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint madrasah_household_has_a_name
    check (length(btrim(name)) between 1 and 120),
  constraint madrasah_household_note_is_short
    check (note is null or length(note) <= 500),
  constraint madrasah_household_reference_shape
    check (reference ~ '^MF-[0-9]{4,6}$')
);

create unique index if not exists madrasah_household_reference_idx
  on public.madrasah_households (reference);

create index if not exists madrasah_household_masjid_idx
  on public.madrasah_households (masjid_id, name);

alter table public.madrasah_households enable row level security;
alter table public.madrasah_households force row level security;
revoke all on public.madrasah_households from anon, authenticated;

-- ---------------------------------------------------------------------------
--  2. The adult to contact
--
--  is_primary marks the one person a reminder goes to. It is a partial unique
--  index rather than a flag anybody can set twice, because "who do we email"
--  has to have exactly one answer or the office will send two reminders to
--  one family and hear about it.
--
--  A household may have NO guardian. That is allowed and it is important that
--  it is allowed: the office will create families from the class list long
--  before it has chased everybody for an email address. The Outstanding
--  screen has to be able to say "12 families owe money and 4 of them have
--  nobody to email", which it cannot do if the schema pretends the case
--  cannot happen.
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_guardians (
  id            uuid primary key default gen_random_uuid(),
  masjid_id     uuid not null references public.masjids(id) on delete cascade,
  household_id  uuid not null references public.madrasah_households(id) on delete cascade,
  full_name     text not null,
  email         text,
  phone         text,
  is_primary    boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint madrasah_guardian_has_a_name
    check (length(btrim(full_name)) between 1 and 120),
  --  Deliberately loose. The purpose of this check is to refuse a phone
  --  number typed into the email box and a blank that is not null, not to
  --  adjudicate RFC 5322. A parent with an unusual but valid address who
  --  cannot be added is a parent who never gets a reminder.
  constraint madrasah_guardian_email_shape
    check (email is null or (email ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
                             and length(email) <= 160)),
  constraint madrasah_guardian_phone_shape
    check (phone is null or (length(btrim(phone)) between 6 and 24
                             and phone ~ '^[0-9+()[:space:]-]+$'))
);

create unique index if not exists madrasah_guardian_one_primary_idx
  on public.madrasah_guardians (household_id) where is_primary;

create index if not exists madrasah_guardian_household_idx
  on public.madrasah_guardians (household_id);

alter table public.madrasah_guardians enable row level security;
alter table public.madrasah_guardians force row level security;
revoke all on public.madrasah_guardians from anon, authenticated;

-- ---------------------------------------------------------------------------
--  3. A pupil belongs to a family
--
--  NULLABLE, and it stays nullable. 543 children were imported from a class
--  list that has no family column in it. Making this NOT NULL would mean
--  inventing 543 households on the day this migration runs, most of them
--  wrong, and a wrong family is worse than no family because it produces a
--  bill addressed to the wrong house.
--
--  ON DELETE SET NULL, not CASCADE, and this is the same trap 058 warned
--  about with safeguarding records: deleting a household must never delete a
--  child. A check at the foot of this file fails if anybody ever changes it.
-- ---------------------------------------------------------------------------
alter table public.madrasah_pupils
  add column if not exists household_id uuid
    references public.madrasah_households(id) on delete set null;

create index if not exists madrasah_pupil_household_idx
  on public.madrasah_pupils (household_id);

-- ---------------------------------------------------------------------------
--  4. Reading families
--
--  ADMINISTRATORS ONLY, all of it. A teacher may see the children in their
--  own class — 058 settled that — but a teacher has no business seeing what a
--  family pays, owes, or has been let off. Money is an office matter, and the
--  Fees rows in the madrasah rail are all marked `needs: ADMIN` for the same
--  reason. Every function the screens call tests verified_admin(), and there
--  is no teacher branch to get wrong.
--
--  An earlier draft of this comment said "every function in this file and in
--  069-071", which was not true: madrasah_sibling_discount_p() was granted to
--  `authenticated` with no check at all, because it is arithmetic rather than
--  a read. It is arithmetic ON TWO FORCE-RLS TABLES, which makes it an oracle
--  — a non-zero answer confirms that a given pupil belongs to a given family,
--  and the size of it discloses the masjid's discount rule. It now tests
--  verified_admin() like everything else, and the check in 069 that was meant
--  to catch this omission has been given its name.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_household_list(p_q text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_q      text := nullif(btrim(coalesce(p_q, '')), '');
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see families.'
      using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(x order by x->>'name')
      from (
        select jsonb_build_object(
                 'id',        h.id,
                 'reference', h.reference,
                 'name',      h.name,
                 'note',      h.note,
                 'pupils',    (select count(*) from public.madrasah_pupils p
                                where p.household_id = h.id and p.left_on is null),
                 'former',    (select count(*) from public.madrasah_pupils p
                                where p.household_id = h.id and p.left_on is not null),
                 --  The list says WHETHER there is somebody to email, not who.
                 --  065 settled this shape for the staff list: a list is read
                 --  far more often than a record is opened, so it should not
                 --  carry a contact detail into every screenshot and every
                 --  browser cache for the sake of a tick.
                 --
                 --  `is_primary` IS PART OF THE TEST, and leaving it out was a
                 --  bug worth naming: send_madrasah_fee_reminders() writes to
                 --  the primary contact and nobody else, so a family whose
                 --  primary has a telephone number and whose second parent has
                 --  an email showed a green "email" flag, was tickable on the
                 --  Outstanding screen, survived the "only families we can
                 --  email" filter — and came back no_contact. Three screens
                 --  promising something the sender would not do.
                 'has_email', exists (select 1 from public.madrasah_guardians g
                                       where g.household_id = h.id
                                         and g.is_primary
                                         and g.email is not null),
                 'has_phone', exists (select 1 from public.madrasah_guardians g
                                       where g.household_id = h.id
                                         and g.phone is not null),
                 'guardians', (select count(*) from public.madrasah_guardians g
                                where g.household_id = h.id)
               ) as x
          from public.madrasah_households h
         where h.masjid_id = v_masjid
           --  ILIKE with the wildcards escaped, not a regex. A search box is
           --  typed into by the office, and "50% off" or "Khan_" in a family
           --  note would otherwise either match everything or throw.
           and (v_q is null
                or h.name      ilike '%' || replace(replace(replace(v_q,
                                       '\', '\\'), '%', '\%'), '_', '\_') || '%' escape '\'
                or h.reference ilike '%' || replace(replace(replace(v_q,
                                       '\', '\\'), '%', '\%'), '_', '\_') || '%' escape '\')
      ) s), '[]'::jsonb);
end $fn$;

--  One family, in full, including the contact details the list withholds.
create or replace function public.madrasah_household_one(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_out    jsonb;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see a family.'
      using errcode = '42501';
  end if;

  select jsonb_build_object(
           'id',        h.id,
           'reference', h.reference,
           'name',      h.name,
           'note',      h.note,
           'guardians', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', g.id, 'full_name', g.full_name,
                      'email', g.email, 'phone', g.phone,
                      'is_primary', g.is_primary)
                    order by g.is_primary desc, g.full_name)
               from public.madrasah_guardians g
              where g.household_id = h.id), '[]'::jsonb),
           'pupils', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', p.id,
                      'name', btrim(p.first_name || ' ' || coalesce(p.last_name, '')),
                      'left_on', p.left_on)
                    order by p.first_name)
               from public.madrasah_pupils p
              where p.household_id = h.id), '[]'::jsonb)
         )
    into v_out
    from public.madrasah_households h
   where h.id = p_id and h.masjid_id = v_masjid;

  if v_out is null then
    raise exception 'There is no such family at this masjid.' using errcode = 'no_data_found';
  end if;
  return v_out;
end $fn$;

-- ---------------------------------------------------------------------------
--  5. Writing a family
-- ---------------------------------------------------------------------------
create or replace function public.save_madrasah_household(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id     uuid := nullif(p->>'id', '')::uuid;
  v_masjid uuid := public.current_masjid();
  v_name   text := btrim(coalesce(p->>'name', ''));
  v_row    public.madrasah_households%rowtype;
  v_g          jsonb;
  v_keep       uuid[] := '{}';
  v_gid        uuid;
  v_first_id   uuid;
  v_claimed_id uuid;
  v_primary    uuid;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change a family.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected.' using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'A family needs a name — usually the surname and the street.'
      using errcode = 'check_violation';
  end if;

  if v_id is null then
    insert into public.madrasah_households (masjid_id, reference, name, note)
    values (v_masjid,
            'MF-' || lpad(nextval('public.madrasah_household_ref_seq')::text, 4, '0'),
            v_name, nullif(btrim(coalesce(p->>'note', '')), ''))
    returning * into v_row;
  else
    update public.madrasah_households
       set name = v_name,
           note = nullif(btrim(coalesce(p->>'note', '')), ''),
           updated_at = now()
     where id = v_id and masjid_id = v_masjid
    returning * into v_row;
    if v_row.id is null then
      raise exception 'There is no such family at this masjid.' using errcode = 'no_data_found';
    end if;
  end if;

  --  Guardians, if the caller said anything about them. 058's rule: absent
  --  means leave them alone, an empty array means none, and those are
  --  different instructions.
  if p ? 'guardians' and jsonb_typeof(p->'guardians') = 'array' then
    --  EVERY GUARDIAN IS WRITTEN WITH is_primary FALSE, AND THE PRIMARY IS
    --  CHOSEN AFTERWARDS IN ONE STATEMENT.
    --
    --  The obvious version — set each row's flag from its own line of the
    --  form — is wrong, and wrong in a way that only shows up on the second
    --  parent. The partial unique index permits one true per household, so a
    --  form listing the mother first and ticking the father second tries to
    --  hold two true rows for the length of the loop and fails on the second
    --  insert with "duplicate key value violates unique constraint", which
    --  tells the office nothing about what it did. Deciding first and writing
    --  once cannot get into that state.
    v_primary := null;
    for v_g in select * from jsonb_array_elements(p->'guardians') loop
      if btrim(coalesce(v_g->>'full_name', '')) = '' then
        continue;
      end if;
      v_gid := nullif(v_g->>'id', '')::uuid;

      insert into public.madrasah_guardians as t
        (id, masjid_id, household_id, full_name, email, phone, is_primary)
      values (coalesce(v_gid, gen_random_uuid()), v_masjid, v_row.id,
              btrim(v_g->>'full_name'),
              lower(nullif(btrim(coalesce(v_g->>'email', '')), '')),
              nullif(btrim(coalesce(v_g->>'phone', '')), ''),
              false)
      on conflict (id) do update set
        full_name  = excluded.full_name,
        email      = excluded.email,
        phone      = excluded.phone,
        is_primary = false,
        updated_at = now()
      where t.household_id = v_row.id
      returning id into v_gid;

      --  An id belonging to ANOTHER household reaches the ON CONFLICT branch,
      --  fails the WHERE, and returns nothing. Letting a null into v_keep
      --  would make the tidy-up delete below compare against an array
      --  containing null, which evaluates to null rather than true and
      --  silently keeps every row it was supposed to remove.
      if v_gid is null then
        raise exception 'One of those contacts belongs to a different family.'
          using errcode = 'no_data_found';
      end if;

      v_keep := v_keep || v_gid;

      --  Two facts, remembered separately, because they answer different
      --  questions: who did the form actually tick, and who came first.
      if v_first_id is null then
        v_first_id := v_gid;
      end if;
      if v_claimed_id is null and coalesce((v_g->>'is_primary')::boolean, false) then
        v_claimed_id := v_gid;
      end if;
    end loop;

    delete from public.madrasah_guardians
     where household_id = v_row.id and not (id = any(v_keep));

    --  Whoever the form ticked; failing that, whoever was listed first. A
    --  household whose form forgot to tick anybody still has somebody to
    --  write to, which is the whole reason the Outstanding screen can promise
    --  that a family either has a contact or is listed as having none.
    v_primary := coalesce(v_claimed_id, v_first_id);
    if v_primary is not null then
      update public.madrasah_guardians
         set is_primary = (id = v_primary)
       where household_id = v_row.id;
    end if;
  end if;

  --  THE AUDIT RECORDS THE ACT, NOT THE PEOPLE. 058's rule, and it matters
  --  more here: an audit row outlives the guardian record it describes, so
  --  writing an email address into one would defeat the retention period.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(),
          case when v_id is null then 'madrasah_household_added'
               else 'madrasah_household_changed' end,
          jsonb_build_object('id', v_row.id, 'reference', v_row.reference));

  return jsonb_build_object('id', v_row.id, 'reference', v_row.reference);
end $fn$;

--  Putting a child in a family, and taking them out again.
create or replace function public.set_pupil_household(p_pupil uuid, p_household uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_n      int;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change a pupil record.'
      using errcode = '42501';
  end if;

  if p_household is not null and not exists (
       select 1 from public.madrasah_households
        where id = p_household and masjid_id = v_masjid) then
    raise exception 'There is no such family at this masjid.' using errcode = 'no_data_found';
  end if;

  update public.madrasah_pupils
     set household_id = p_household, updated_at = now()
   where id = p_pupil and masjid_id = v_masjid;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    raise exception 'There is no such pupil at this masjid.' using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_pupil_household_set',
          jsonb_build_object('pupil', p_pupil, 'household', p_household));

  return jsonb_build_object('ok', true);
end $fn$;

-- ---------------------------------------------------------------------------
--  6. Deleting a family
--
--  Refused while it still has anybody in it. The alternative — cascading, or
--  quietly setting 3 children's household to null — is how a family's fee
--  history disappears because somebody was tidying up a duplicate.
-- ---------------------------------------------------------------------------
create or replace function public.delete_madrasah_household(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_ref    text;
  v_kids   int;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may remove a family.'
      using errcode = '42501';
  end if;

  select reference into v_ref from public.madrasah_households
   where id = p_id and masjid_id = v_masjid;
  if v_ref is null then
    raise exception 'There is no such family at this masjid.' using errcode = 'no_data_found';
  end if;

  select count(*) into v_kids from public.madrasah_pupils where household_id = p_id;
  if v_kids > 0 then
    raise exception 'That family still has % pupil(s) attached. Move them first.', v_kids
      using errcode = 'foreign_key_violation';
  end if;

  delete from public.madrasah_households where id = p_id and masjid_id = v_masjid;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_household_removed',
          jsonb_build_object('id', p_id, 'reference', v_ref));

  return jsonb_build_object('ok', true);
end $fn$;

-- ---------------------------------------------------------------------------
--  7. Retention
--
--  A household with no pupil and no money against it, untouched for three
--  years, is swept. The money test is there because an empty household that
--  paid something is a financial record and belongs on the charity's own
--  six-year clock, not this one. 070 creates those tables; this function is
--  written to tolerate their absence so that 068 can be applied on its own.
-- ---------------------------------------------------------------------------
create or replace function public.purge_madrasah_households()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_n     int := 0;
  v_money boolean := to_regclass('public.madrasah_payments') is not null;
begin
  if v_money then
    execute $q$
      delete from public.madrasah_households h
       where h.updated_at < now() - interval '3 years'
         and not exists (select 1 from public.madrasah_pupils p where p.household_id = h.id)
         and not exists (select 1 from public.madrasah_payments y where y.household_id = h.id)
         and not exists (select 1 from public.madrasah_charges c where c.household_id = h.id)
    $q$;
  else
    delete from public.madrasah_households h
     where h.updated_at < now() - interval '3 years'
       and not exists (select 1 from public.madrasah_pupils p where p.household_id = h.id);
  end if;
  get diagnostics v_n = row_count;
  return v_n;
end $fn$;

revoke all on function public.purge_madrasah_households() from public, anon, authenticated;

--  067's rule, applied to the function this file just created: a retention
--  policy that nothing calls is not a retention policy. Scheduled 15 minutes
--  after the pupil purge so that a household emptied by that purge is swept
--  in the same night rather than waiting a week.
do $sched$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule('purge-madrasah-households')
      where exists (select 1 from cron.job where jobname = 'purge-madrasah-households');
    perform cron.schedule('purge-madrasah-households', '35 3 * * 1',
                          $$select public.purge_madrasah_households()$$);
  end if;
end $sched$;


-- ---------------------------------------------------------------------------
--  5b. Finding a child to put in a family
--
--  THE BULK JOB THIS SYSTEM ACTUALLY FACES. 543 children were imported from a
--  class list with no family column in it, so on day one every one of them is
--  unhoused and the office has to work through them. A search box alone is not
--  enough for that; the screen needs the whole backlog, shortest first.
--
--  The search says which family a child is ALREADY in. Twelve names at this
--  masjid are shared by two children each, and without that line the office
--  would move the wrong Yusuf into a family and only find out when a bill
--  went to the wrong house.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_pupils_for_family(
  p_q text default null, p_unhoused boolean default false, p_limit integer default 60)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_q      text := nullif(btrim(coalesce(p_q, '')), '');
  v_like   text;
  v_n      integer := least(greatest(coalesce(p_limit, 60), 1), 500);
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may look up a pupil.'
      using errcode = '42501';
  end if;

  v_like := case when v_q is null then null
                 else '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%' end;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id',        p.id,
             'name',      btrim(p.first_name || ' ' || coalesce(p.last_name, '')),
             'joined_on', p.joined_on,
             --  The class is here because it is the ONLY thing that tells two
             --  children of the same name apart — 058 holds no date of birth,
             --  deliberately, and the privacy notice already warns parents
             --  they will be asked which class their child is in.
             'classes',   coalesce((select string_agg(c.name, ', ' order by c.name)
                                      from public.madrasah_pupil_classes pc
                                      join public.madrasah_classes c on c.id = pc.class_id
                                     where pc.pupil_id = p.id), ''),
             'household_id',   h.id,
             'household',      h.name,
             'household_ref',  h.reference)
           order by p.first_name, p.last_name)
      from (select * from public.madrasah_pupils
             where masjid_id = v_masjid
               and left_on is null
               and (not p_unhoused or household_id is null)
               and (v_like is null
                    or first_name ilike v_like escape '\'
                    or coalesce(last_name, '') ilike v_like escape '\'
                    or (first_name || ' ' || coalesce(last_name, '')) ilike v_like escape '\')
             order by first_name, last_name
             limit v_n) p
      left join public.madrasah_households h on h.id = p.household_id), '[]'::jsonb);
end $fn$;

grant execute on function public.madrasah_household_list(text)      to authenticated;
grant execute on function public.madrasah_pupils_for_family(text, boolean, integer) to authenticated;
grant execute on function public.madrasah_household_one(uuid)       to authenticated;
grant execute on function public.save_madrasah_household(jsonb)     to authenticated;
grant execute on function public.set_pupil_household(uuid, uuid)    to authenticated;
grant execute on function public.delete_madrasah_household(uuid)    to authenticated;

commit;

-- ===========================================================================
--  CHECKS. Every one of these was proved by deliberately breaking the code it
--  guards and watching it fail. A check that cannot fail is worse than no
--  check, because it is a claim nobody re-examines.
-- ===========================================================================

--  #1  Deleting a family must never delete a child.
--      Broken deliberately by changing SET NULL to CASCADE; this failed.
do $check1$
declare v_rule text;
begin
  select c.confdeltype into v_rule
    from pg_constraint c
   where c.conrelid = 'public.madrasah_pupils'::regclass
     and c.contype  = 'f'
     and c.confrelid = 'public.madrasah_households'::regclass;

  if v_rule is null then
    raise exception 'CHECK 1 FAILED: madrasah_pupils has no foreign key to madrasah_households.';
  end if;
  if v_rule <> 'n' then
    raise exception
      'CHECK 1 FAILED: pupil.household_id is ON DELETE % — deleting a family would touch a child. It must be SET NULL.',
      case v_rule when 'c' then 'CASCADE' when 'a' then 'NO ACTION'
                  when 'r' then 'RESTRICT' when 'd' then 'SET DEFAULT' else v_rule end;
  end if;
  raise notice 'CHECK 1 passed: deleting a family leaves the children alone.';
end $check1$;

--  #2  A family can only have one person we email.
--      Broken deliberately by dropping the partial index; this failed.
do $check2$
declare v_ok boolean;
begin
  select exists (
    select 1 from pg_indexes
     where schemaname = 'public'
       and indexname  = 'madrasah_guardian_one_primary_idx'
       and indexdef ilike '%UNIQUE%' and indexdef ilike '%WHERE%is_primary%')
    into v_ok;
  if not v_ok then
    raise exception 'CHECK 2 FAILED: two guardians on one family could both be primary. Reminders would go out twice.';
  end if;
  raise notice 'CHECK 2 passed: exactly one guardian per family is the one we write to.';
end $check2$;

--  #3  Nobody but an administrator reaches a family.
--      This is the check that matters most in the whole file. A teacher who
--      can read madrasah_household_one() can read every parent's email and
--      telephone number at the masjid — about 300 adults — from a screen that
--      was only ever meant to show them their own class register.
--
--      Line-based, not `'verified_admin' not in v_def`. 065's lesson: a
--      substring test against a whole function body passes on a function that
--      merely MENTIONS the word in a comment, so it is a check that cannot
--      fail. This one requires the call to be on a line that is not commented
--      out, in every one of the five functions.
do $check3$
declare
  v_fn    text;
  v_def   text;
  v_line  text;
  v_found boolean;
begin
  foreach v_fn in array array['madrasah_household_list', 'madrasah_household_one',
                              'save_madrasah_household', 'set_pupil_household',
                              'delete_madrasah_household', 'madrasah_pupils_for_family'] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn
     limit 1;

    if v_def is null then
      raise exception 'CHECK 3 FAILED: public.%() does not exist.', v_fn;
    end if;

    v_found := false;
    foreach v_line in array string_to_array(v_def, E'\n') loop
      if btrim(v_line) not like '--%'
         and v_line like '%public.verified_admin()%' then
        v_found := true;
        exit;
      end if;
    end loop;

    if not v_found then
      raise exception
        'CHECK 3 FAILED: public.%() never calls public.verified_admin() in live code. A teacher could read every parent''s contact details.', v_fn;
    end if;
  end loop;
  raise notice 'CHECK 3 passed: all six family functions are administrators only.';
end $check3$;

--  #4  The purge this file created is actually scheduled.
--      067's rule. Skipped rather than failed where pg_cron is absent, because
--      the local test harness has no scheduler and a check that fails in the
--      harness is a check somebody comments out.
do $check4$
declare v_n int;
begin
  if to_regclass('cron.job') is null then
    raise notice 'CHECK 4 skipped: pg_cron is not installed here. It IS installed in production — re-run this file there.';
    return;
  end if;
  select count(*) into v_n from cron.job where jobname = 'purge-madrasah-households';
  if v_n = 0 then
    raise exception 'CHECK 4 FAILED: purge_madrasah_households() exists but nothing calls it. That is not a retention policy.';
  end if;
  raise notice 'CHECK 4 passed: families are swept weekly.';
end $check4$;

--  #5  The tables cannot be read directly, only through the functions above.
do $check5$
declare v_t text; v_pol int; v_forced boolean; v_priv text;
begin
  foreach v_t in array array['madrasah_households', 'madrasah_guardians'] loop
    select relforcerowsecurity into v_forced
      from pg_class where oid = ('public.' || v_t)::regclass;
    select count(*) into v_pol from pg_policies
     where schemaname = 'public' and tablename = v_t;
    select string_agg(privilege_type, ',') into v_priv
      from information_schema.role_table_grants
     where table_schema = 'public' and table_name = v_t
       and grantee in ('anon', 'authenticated');

    if not v_forced then
      raise exception 'CHECK 5 FAILED: %.FORCE ROW LEVEL SECURITY is off.', v_t;
    end if;
    if v_pol > 0 then
      raise exception 'CHECK 5 FAILED: % has % policy/policies. The house pattern is forced RLS with NO policies — the table is unreachable and the functions are the only door.', v_t, v_pol;
    end if;
    if v_priv is not null then
      raise exception 'CHECK 5 FAILED: anon or authenticated holds % on %.', v_priv, v_t;
    end if;
  end loop;
  raise notice 'CHECK 5 passed: both tables are unreachable except through SECURITY DEFINER functions.';
end $check5$;

-- ===========================================================================
--  AFTER APPLYING THIS FILE
--
--  1. Re-run db/011_require_two_step.sql. It rebuilds verified_admin() and
--     every migration that touches these functions has to be followed by it.
--
--  2. The DPIA review is now on the compliance list on /portal/ — it was
--     added to the BEFORE list in portal/app.js in the same commit as this
--     file. Do not switch on fee reminders until it is done. The privacy
--     notice has not been issued at all yet, and issuing one that does not
--     mention parents' contact details, having already collected them, is a
--     worse position than not having issued one.
-- ===========================================================================
