-- ===========================================================================
--  022_donations_and_gift_aid.sql — donations, and the Gift Aid declaration
--
--  *** THIS FILE IS A RECONSTRUCTION, WRITTEN 15 September 2026. ***
--
--  READ THIS BEFORE TRUSTING IT.
--
--  The donations table and its functions have been live since 12 September
--  2026. They were created in the Supabase SQL editor and THE MIGRATION FILE
--  WAS NEVER WRITTEN. For three days the most sensitive table in this
--  database — donor names, home addresses and postcodes, kept solely so the
--  masjid can claim 25p in the pound from HMRC — existed nowhere in this
--  repository. Nobody could review it, nobody could rebuild it, and the one
--  test that referred to it (_test/giftaid_test.py) CRASHED with
--  FileNotFoundError rather than failing, which is why nobody noticed.
--
--  Every statement below was read back out of the live database with
--  pg_get_functiondef() and pg_get_constraintdef() on 15 September 2026 and
--  is what is actually running. But it is a transcription of the end state,
--  not the original migration:
--
--    * the ORDER of statements is a reasonable reconstruction, not history
--    * `purpose`, its CHECK, the DN- sequence and record_public_donation()
--      are NOT here — they came later and are in 032, which is a real file
--    * anything dropped and recreated between the 12th and the 15th is
--      invisible to this file
--
--  RUNNING THIS AGAINST A DATABASE THAT ALREADY HAS DONATIONS WILL NOT
--  RECREATE THEM. It is written to be safe to re-run — `if not exists`
--  throughout, `create or replace` for the functions — but its real purpose
--  is to be READ and REVIEWED, and to let the repository rebuild from empty.
--
--  THE LESSON, WHICH THIS PROJECT HAS NOW LEARNED THREE TIMES
--  ----------------------------------------------------------
--  Things built in a dashboard are invisible to this folder: this table, the
--  `notices` table, and every database webhook. Each time it has cost
--  something. See 033 and 035.
--
--  WHAT IT IS FOR
--  --------------
--  Gift Aid is worth 25% on top of every eligible donation, and HMRC's price
--  for it is a record: who gave it, where they live, when they declared, and
--  which wording they were shown. That last one is why
--  gift_aid_declaration_version() exists. If the masjid rewords the
--  declaration, old records must still say what the donor actually agreed to;
--  a version that is edited in place is a record of nothing.
--
--  AND THE RULE THAT MATTERS MOST
--  ------------------------------
--  A DONOR WHO DID NOT CLAIM GIFT AID IS ANONYMOUS. Not "we do not show it" —
--  the columns are null and a CHECK constraint refuses the row otherwise. The
--  masjid has no reason to keep a name and address for a gift it cannot claim
--  on, so it does not keep them. That is enforced twice: in the webhook
--  (donorDetails() in giftaid.ts returns nulls) and here, because the webhook
--  is code somebody can change and this is not.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  The declaration version.
--
--  IMMUTABLE and deliberately a hard-coded date rather than a lookup: it is
--  stamped onto every declaration as it is made, and what it meant on the day
--  must never change afterwards. Changing the wording on the website means
--  changing this date IN THE SAME COMMIT — _test/giftaid_test.py compares the
--  two and fails if they drift, which is the only thing keeping them honest.
-- ---------------------------------------------------------------------------
create or replace function public.gift_aid_declaration_version()
returns text language sql immutable
as $fn$ select '2026-09-12' $fn$;

-- ---------------------------------------------------------------------------
--  The table.
-- ---------------------------------------------------------------------------
create table if not exists public.donations (
  id                  uuid primary key default gen_random_uuid(),
  reference           text not null unique,
  created_at          timestamptz not null default now(),
  amount_p            integer,
  status              text not null default 'paid',
  gift_aid            boolean not null default false,
  declaration_version text,
  declared_at         timestamptz,
  donor_name          text,
  donor_address       text,
  donor_postcode      text,
  stripe_session_id   text unique,
  paid_at             timestamptz,
  claimed_at          timestamptz
);

do $$
begin
  -- A gift the masjid cannot claim on is not allowed to carry a name.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'no_donor_data_without_gift_aid') then
    alter table public.donations add constraint no_donor_data_without_gift_aid
      check (gift_aid or (donor_name is null
                      and donor_address is null
                      and donor_postcode is null));
  end if;

  -- And a claim with no record of what was agreed is not a claim.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'gift_aid_needs_a_declaration') then
    alter table public.donations add constraint gift_aid_needs_a_declaration
      check ((not gift_aid) or (declaration_version is not null
                            and declared_at is not null));
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'donation_status_valid') then
    alter table public.donations add constraint donation_status_valid
      check (status in ('pending','paid'));
  end if;
end $$;

-- The only query the Gift Aid screen runs, so the index matches it exactly.
create index if not exists donations_unclaimed
  on public.donations (paid_at)
  where gift_aid and claimed_at is null;

-- ---------------------------------------------------------------------------
--  RLS: ON, WITH NO POLICIES AT ALL.
--
--  That is not an oversight and it is the strongest setting available. No
--  policy means no row passes, for anybody, ever — so donations are reachable
--  only through the SECURITY DEFINER functions below, each of which checks
--  verified_admin() for itself. anon and authenticated hold no grants on this
--  table either, which is the belt to that pair of braces.
--
--  GRANT AND RLS ARE DIFFERENT THINGS AND YOU NEED BOTH.
-- ---------------------------------------------------------------------------
alter table public.donations enable row level security;

-- ---------------------------------------------------------------------------
--  Recording a payment. Called by stripe-webhook and nobody else.
--
--  IDEMPOTENT ON THE STRIPE SESSION. Stripe retries a delivery for days, and
--  a retry must never become a second donation.
-- ---------------------------------------------------------------------------
create or replace function public.record_donation_paid(
  p_reference  text,
  p_session_id text,
  p_amount_p   integer default null,
  p_gift_aid   boolean default false,
  p_name       text default null,
  p_address    text default null,
  p_postcode   text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare
  v_ga boolean := coalesce(p_gift_aid, false);
  v_id uuid;
begin
  select id into v_id from public.donations where stripe_session_id = p_session_id;
  if found then
    return jsonb_build_object('reference', p_reference, 'status', 'paid',
                              'gift_aid', v_ga, 'already_recorded', true);
  end if;

  insert into public.donations
    (reference, amount_p, status, stripe_session_id, paid_at,
     gift_aid, declaration_version, declared_at,
     donor_name, donor_address, donor_postcode)
  values
    (p_reference, p_amount_p, 'paid', p_session_id, now(),
     v_ga,
     case when v_ga then public.gift_aid_declaration_version() end,
     case when v_ga then now() end,
     case when v_ga then nullif(trim(p_name), '') end,
     case when v_ga then nullif(trim(p_address), '') end,
     case when v_ga then upper(nullif(trim(p_postcode), '')) end);

  insert into public.admin_audit (action, detail)
  values ('donation_paid', jsonb_build_object(
            'reference', p_reference, 'amount_pence', p_amount_p,
            'gift_aid', v_ga,
            'declaration_version',
              case when v_ga then public.gift_aid_declaration_version() end));

  -- Gift Aid claimed with no name or no postcode cannot actually be claimed:
  -- HMRC matches on the house number and the postcode. Better the office
  -- knows now than when the claim is disallowed years later.
  if v_ga and (nullif(trim(coalesce(p_postcode, '')), '') is null
            or nullif(trim(coalesce(p_name, '')), '') is null) then
    insert into public.admin_audit (action, detail)
    values ('gift_aid_incomplete', jsonb_build_object(
              'reference', p_reference,
              'has_name', nullif(trim(coalesce(p_name, '')), '') is not null,
              'has_postcode', nullif(trim(coalesce(p_postcode, '')), '') is not null));
  end if;

  return jsonb_build_object('reference', p_reference, 'status', 'paid',
                            'gift_aid', v_ga, 'already_recorded', false);
end $fn$;

-- ---------------------------------------------------------------------------
--  What the Gift Aid screen reads.
--
--  NOTE THE GUARD IS IN THE WHERE CLAUSE, not a raise. A caller who is not a
--  verified administrator gets an empty table rather than an error — it fails
--  closed and says nothing about what it is hiding. verified_admin() means an
--  admin who has completed two-step; see 011.
-- ---------------------------------------------------------------------------
create or replace function public.gift_aid_to_claim()
returns table (reference text, donated_on date, donor_name text,
               donor_address text, donor_postcode text, amount_p integer,
               declaration_version text)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  select d.reference, d.paid_at::date, d.donor_name, d.donor_address,
         d.donor_postcode, d.amount_p, d.declaration_version
    from public.donations d
   where d.gift_aid
     and d.status = 'paid'
     and d.claimed_at is null
     and public.verified_admin()
   order by d.paid_at
$fn$;

-- ---------------------------------------------------------------------------
--  Marking a batch as claimed, after it has been submitted to HMRC.
-- ---------------------------------------------------------------------------
create or replace function public.mark_gift_aid_claimed(p_references text[])
returns integer
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare v_n int;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  update public.donations
     set claimed_at = now()
   where reference = any(p_references)
     and gift_aid and status = 'paid' and claimed_at is null;
  get diagnostics v_n = row_count;

  insert into public.admin_audit (action, detail)
  values ('gift_aid_claimed', jsonb_build_object(
            'count', v_n, 'references', to_jsonb(p_references),
            'by', auth.uid()));

  return v_n;
end $fn$;

-- ---------------------------------------------------------------------------
--  Retention. SEVEN YEARS, not the twelve months that covers everything else
--  in 015, because HMRC may inspect a Gift Aid claim for six years after the
--  end of the tax year it was claimed in. Deleting sooner would leave the
--  masjid unable to support a claim it has already spent.
--
--  A donation with no Gift Aid carries no personal data at all, so there is
--  nothing to purge and it is deliberately kept: it is the masjid's own
--  financial record.
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_donations()
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare v_expired int;
begin
  delete from public.donations
   where gift_aid and status = 'paid'
     and paid_at < now() - interval '7 years';
  get diagnostics v_expired = row_count;

  insert into public.admin_audit (action, detail)
  values ('donations_purged', jsonb_build_object('gift_aid_expired', v_expired));

  return jsonb_build_object('gift_aid_expired', v_expired);
end $fn$;

-- ---------------------------------------------------------------------------
--  Who may call what. service_role is the webhook; it records payments and
--  can read nothing. authenticated covers the two admin screens, and each
--  function checks verified_admin() for itself rather than trusting the grant.
-- ---------------------------------------------------------------------------
revoke all on function public.record_donation_paid(text,text,integer,boolean,text,text,text) from public;
grant execute on function public.record_donation_paid(text,text,integer,boolean,text,text,text) to service_role;

grant execute on function public.gift_aid_to_claim()                to authenticated;
grant execute on function public.mark_gift_aid_claimed(text[])      to authenticated;

commit;
