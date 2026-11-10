-- ===========================================================================
--  154 — cash in the tin, and the standing gifts the dashboard couldn't list
--
--  Taiyabah Masjid · 9 November 2026
--
--  WHAT THIS ADDS
--  ---------------
--  1. CASH DONATIONS. Not every donation touches Stripe — a note in the
--     collection box on Jumu'ah, a cheque, a gift handed to the office. Until
--     this file the only donations this database could ever hold were ones
--     Stripe told stripe-webhook about; a cash gift simply had nowhere to go,
--     so it never appeared in a total, a fund breakdown, or a Gift Aid claim.
--
--     `source` gains a third value, 'cash', alongside 'online' and
--     'in_person'. record_cash_donation() is the one way in — called
--     DIRECTLY by a signed-in administrator from /giftaid/, the same pattern
--     mark_gift_aid_claimed() already uses, not service_role the way the
--     Stripe-driven paths are. There is no Stripe id to key idempotency off,
--     so there is no idempotency check here at all — each call is one
--     donation, the same as pressing "record" once on a paper form.
--
--     UNLIKE A CARD-MACHINE TAP, A CASH GIFT CAN CARRY GIFT AID. The
--     card-reader path hard-codes gift_aid false because tapping a card
--     collects no name or address at all. Logging cash is a form filled in
--     by a human who can ask the donor and write down what they say — the
--     same declaration the donate page collects, just typed in by staff
--     instead of the donor. in_person_is_never_gift_aid is untouched: it only
--     ever constrained 'in_person', so 'cash' + gift_aid was already legal
--     the moment the column allowed a third source value.
--
--     recorded_by says which signed-in administrator logged it — not shown
--     anywhere yet, but cash handling is exactly the kind of thing an
--     audit trail should be able to answer "who entered this" for, and a
--     column added later cannot be backfilled for rows that already forgot.
--
--  2. THE RECURRING DONOR LIST. The dashboard already shows HOW MANY standing
--     gifts have been charged in the last 40 days and what they're worth in
--     total (db/152's donations_summary()). What it has never shown is the
--     list itself — which standing gifts there are, one row each.
--
--     donations_recurring_donors() returns ONE ROW PER SUBSCRIPTION, not per
--     donor: reference, fund, frequency, Gift Aid (yes/no), the most recent
--     amount, how many times it has been charged, the total raised on it,
--     and when it first and most recently charged. NO NAME. NO ADDRESS. The
--     existing dashboard's own rule — "No donor name or address is shown
--     here, that stays in the Gift Aid section" — holds for this table too;
--     it would be a strange place to start making an exception. Where a
--     subscription is Gift Aid, its name still lives only in the Gift Aid
--     section below, findable by matching the reference shown in both.
--
--     IT DOES NOT CLAIM "ACTIVE" OR "LAPSED", for the same reason
--     donations_summary() does not: nothing in this codebase listens for
--     customer.subscription.deleted, so there is no way to tell a
--     subscription that stopped from one simply waiting for its next charge
--     date. It reports when each one was last actually charged and leaves
--     the reading to the treasurer, in those words, same as db/152.
-- ===========================================================================

begin;

alter table public.donations
  add column if not exists recorded_by uuid references auth.users(id);

comment on column public.donations.recorded_by is
  'The signed-in administrator who logged this row by hand (record_cash_donation()). '
  'Null for every Stripe-driven row — nobody "enters" those, Stripe reports them.';

-- Widen the source check rather than drop and recreate from scratch, so a
-- concurrent reader never sees a moment with no constraint at all.
alter table public.donations drop constraint if exists donations_source_known;
alter table public.donations add constraint donations_source_known
  check (source in ('online', 'in_person', 'cash'));

comment on column public.donations.source is
  '''online'' (the donate page''s Stripe Checkout, one-off or recurring), '
  '''in_person'' (the masjid''s Stripe Terminal card reader, never Gift Aid — '
  'tapping a card collects no name or address), or ''cash'' (logged by hand '
  'from /giftaid/, which CAN carry Gift Aid because a human filled in the form).';

-- ---------------------------------------------------------------------------
--  record_cash_donation — called directly by a signed-in administrator, the
--  same pattern as mark_gift_aid_claimed(): current_masjid() + verified_admin(),
--  not a service-role path, because nothing but a human decides a cash gift
--  happened.
-- ---------------------------------------------------------------------------
create or replace function public.record_cash_donation(
  p_amount_p     integer,
  p_purpose      text    default null,
  p_gift_aid     boolean default false,
  p_name         text    default null,
  p_address      text    default null,
  p_postcode     text    default null,
  p_collected_on date    default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid  uuid := public.current_masjid();
  v_ga      boolean := coalesce(p_gift_aid, false);
  v_purpose text := lower(nullif(btrim(coalesce(p_purpose, '')), ''));
  v_ref     text;
  v_paid_at timestamptz;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  if p_amount_p is null or p_amount_p <= 0 then
    raise exception 'A cash donation must have a positive amount' using errcode = '22023';
  end if;

  if p_collected_on is not null and p_collected_on > current_date then
    raise exception 'Cannot log a cash donation for a date in the future' using errcode = '22023';
  end if;

  if v_purpose is not null and v_purpose not in ('general','sadaqah','lillah','newbuild') then
    v_purpose := null;
  end if;

  v_paid_at := coalesce(p_collected_on::timestamptz, now());
  v_ref := 'DN-' || to_char(now(),'YY') || '-' ||
           lpad(nextval('public.donation_reference_seq')::text, 4, '0');

  insert into public.donations
    (masjid_id, reference, amount_p, status, paid_at, source, purpose,
     gift_aid, declaration_version, declared_at,
     donor_name, donor_address, donor_postcode, recorded_by)
  values
    (v_masjid, v_ref, p_amount_p, 'paid', v_paid_at, 'cash', v_purpose, v_ga,
     case when v_ga then public.gift_aid_declaration_version() end,
     case when v_ga then now() end,
     case when v_ga then nullif(btrim(p_name), '') end,
     case when v_ga then nullif(btrim(p_address), '') end,
     case when v_ga then upper(nullif(btrim(p_postcode), '')) end,
     auth.uid());

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'donation_paid', jsonb_build_object(
            'reference', v_ref, 'amount_pence', p_amount_p, 'purpose', v_purpose,
            'gift_aid', v_ga, 'source', 'cash', 'collected_on', v_paid_at::date,
            'declaration_version',
              case when v_ga then public.gift_aid_declaration_version() end));

  if v_ga and (nullif(btrim(coalesce(p_postcode,'')), '') is null
            or nullif(btrim(coalesce(p_name,'')), '') is null) then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'gift_aid_incomplete', jsonb_build_object(
              'reference', v_ref,
              'has_name', nullif(btrim(coalesce(p_name,'')), '') is not null,
              'has_postcode', nullif(btrim(coalesce(p_postcode,'')), '') is not null));
  end if;

  return jsonb_build_object('reference', v_ref, 'status', 'paid',
                            'gift_aid', v_ga, 'purpose', v_purpose,
                            'already_recorded', false);
end;
$fn$;

revoke all on function public.record_cash_donation(integer,text,boolean,text,text,text,date) from public;
grant execute on function public.record_cash_donation(integer,text,boolean,text,text,text,date) to authenticated;

-- ---------------------------------------------------------------------------
--  donations_recurring_donors — one row per subscription. Fails closed the
--  same way as db/152's four read functions: `mine` is empty for anybody who
--  is not verified_admin(), so the whole result is empty, not an error.
-- ---------------------------------------------------------------------------
create or replace function public.donations_recurring_donors()
returns table (
  reference         text,
  frequency         text,
  purpose           text,
  gift_aid          boolean,
  last_amount_p     bigint,
  total_collected_p bigint,
  charges_count     bigint,
  first_paid_at     timestamptz,
  last_paid_at      timestamptz
)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  with mine as (
    select * from public.donations d
     where d.masjid_id = public.current_masjid()
       and d.status = 'paid'
       and d.stripe_subscription_id is not null
       and public.verified_admin()
  ),
  -- the sign-up row — the earliest charge — carries the reference, fund and
  -- Gift Aid flag; a renewal charge inherits all three from it rather than
  -- re-declaring them, the same inheritance record_subscription_charge()
  -- already relies on in db/152.
  seed as (
    select distinct on (stripe_subscription_id)
           stripe_subscription_id, reference, purpose, gift_aid
      from mine
     order by stripe_subscription_id, paid_at asc
  ),
  latest as (
    select distinct on (stripe_subscription_id)
           stripe_subscription_id, amount_p, frequency
      from mine
     order by stripe_subscription_id, paid_at desc
  ),
  totals as (
    select stripe_subscription_id,
           sum(amount_p)   as total_collected_p,
           count(*)        as charges_count,
           min(paid_at)    as first_paid_at,
           max(paid_at)    as last_paid_at
      from mine
     group by stripe_subscription_id
  )
  select seed.reference, latest.frequency, seed.purpose, seed.gift_aid,
         latest.amount_p, totals.total_collected_p, totals.charges_count,
         totals.first_paid_at, totals.last_paid_at
    from totals
    join seed   using (stripe_subscription_id)
    join latest using (stripe_subscription_id)
   order by totals.last_paid_at desc
$fn$;

revoke all on function public.donations_recurring_donors() from public;
grant execute on function public.donations_recurring_donors() to authenticated;

commit;
