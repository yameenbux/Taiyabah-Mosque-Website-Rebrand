-- ===========================================================================
--  153 — the card machine is a donation too
--
--  Taiyabah Masjid · 8 November 2026
--
--  WHAT THIS ADDS
--  --------------
--  The masjid has a Stripe Terminal card reader for in-person giving, and
--  until this file nothing here knew it existed. Every donation in this
--  table so far has come from the website — the donate page's own Stripe
--  Checkout, one-off or recurring. A tap on the card machine creates a
--  Stripe PaymentIntent directly, with no Checkout Session behind it at
--  all, and fires `payment_intent.succeeded` rather than
--  `checkout.session.completed` — an event stripe-webhook has never
--  subscribed to. See terminal-worker/README.md for the other half of this:
--  the reader was running under MasjidBox's own Stripe setup, not this
--  masjid's own account, so "record the payment" and "drive the reader
--  ourselves, branded" turned out to be two separate pieces of work.
--
--  `donations` gains `source` ('online' or 'in_person') and
--  `stripe_payment_intent_id` (the idempotency key for a card-machine row,
--  since it has no Checkout Session id to key off). Every row this database
--  has ever held before this file is online — that is not a guess, it is
--  the only thing this codebase could create before today — so the backfill
--  is exact, not an estimate.
--
--  record_card_machine_donation() is the one new way in. It is deliberately
--  thin next to record_public_donation():
--
--    * PURPOSE IS OPTIONAL AND UNVERIFIED. If terminal-worker's till screen
--      offers a fund choice, it rides on the PaymentIntent's own metadata —
--      the card-present equivalent of the donate page riding it on
--      client_reference_id — and is read back here as p_purpose. No screen
--      and no choice means unspecified, honestly, never guessed as
--      "general" by default.
--    * NO GIFT AID, EVER. Gift Aid needs a name and a home address, and
--      nothing about tapping a card on a reader collects either. gift_aid
--      is hard-coded false here, not left for a caller to get wrong, and
--      in_person_is_never_gift_aid enforces it at the table too.
--    * NO FREQUENCY. Stripe Terminal has no subscription concept — a tap is
--      a tap. frequency is always null on this path.
--
--  THE DOUBLE-COUNTING TRAP, AND HOW IT IS AVOIDED
--  ------------------------------------------------
--  A Checkout-Session-driven online payment ALSO has an underlying
--  PaymentIntent, and Stripe fires `payment_intent.succeeded` for THAT one
--  too — so subscribing to the event at all risks recording every online
--  donation twice, once correctly via checkout.session.completed and once
--  wrongly via this path. The two are told apart by `payment_method_types`:
--  a card machine's PaymentIntent is always `card_present`; Checkout's is
--  never that for a web donation. stripe-webhook only calls this function
--  when `card_present` is present — see its own comment for the rest of
--  that decision, including the iBeams caveat.
--
--  WHY donations_summary_v2() AND donations_recent_v2() EXIST, NOT A
--  STRAIGHT REPLACEMENT
--  -------------------------------------------------------------------
--  Both needed a new OUT-parameter shape — average_donation_p on one,
--  source on the other — and Postgres refuses CREATE OR REPLACE across that
--  (42P13, "cannot change return type of existing function"; HINT: DROP
--  FUNCTION first). DROP FUNCTION is exactly the statement that got stuck on
--  8 November 2026: the tool applying this migration asked for a
--  confirmation that never reached anyone to answer, three times, on three
--  different DROP statements, with no dialog appearing on the human side at
--  all. Rather than keep spending timeouts on it, the two functions were
--  versioned instead — an ugly name is a cheap price next to a migration
--  that cannot be applied. `donations_summary()` and `donations_recent()`
--  are LEFT RUNNING, untouched, superseded and unused once giftaid/app.js
--  calls the `_v2` names — orphaned, not broken, and safe to actually drop
--  by hand in the Supabase SQL editor whenever somebody can click through
--  that one confirmation directly, which this file could not do on its own.
-- ===========================================================================

begin;

alter table public.donations
  add column if not exists source text,
  add column if not exists stripe_payment_intent_id text;

-- Exact, not an estimate: nothing in this codebase could create an
-- in-person donation before today, so every existing row is online.
update public.donations set source = 'online' where source is null;

alter table public.donations alter column source set default 'online';

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'donations_source_not_null') then
    alter table public.donations alter column source set not null;
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'donations_source_known') then
    alter table public.donations add constraint donations_source_known
      check (source in ('online', 'in_person'));
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'donations_stripe_payment_intent_id_key') then
    alter table public.donations add constraint donations_stripe_payment_intent_id_key
      unique (stripe_payment_intent_id);
  end if;

  -- A card-machine tap collects no name or address, so it can never be a
  -- Gift Aid declaration — enforced the same way no_donor_data_without_gift_aid
  -- already enforces "no Gift Aid, no donor data" the other way round.
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'in_person_is_never_gift_aid') then
    alter table public.donations add constraint in_person_is_never_gift_aid
      check (source <> 'in_person' or not gift_aid);
  end if;
end $$;

comment on column public.donations.source is
  '''online'' (the donate page''s Stripe Checkout, one-off or recurring) or '
  '''in_person'' (the masjid''s Stripe Terminal card reader). Every row before '
  '8 November 2026 is online — nothing else could have created it.';
comment on column public.donations.stripe_payment_intent_id is
  'Idempotency key for a card-machine row. A Checkout-driven row is keyed by '
  'stripe_session_id instead and leaves this null — it has no bare '
  'PaymentIntent of its own worth keying off.';

-- Make existing functions say what they have always meant: a Checkout-driven
-- row is online. Same signatures as db/152, so CREATE OR REPLACE applies
-- cleanly — nothing here needed the DROP that donations_summary/_recent did.

create or replace function public.record_public_donation(
  p_masjid text, p_session_id text, p_amount_p integer, p_purpose text,
  p_gift_aid boolean, p_name text, p_address text, p_postcode text,
  p_subscription_id text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare
  v_masjid  uuid;
  v_ga      boolean := coalesce(p_gift_aid, false);
  v_purpose text := lower(nullif(btrim(coalesce(p_purpose, '')), ''));
  v_sub     text := nullif(btrim(coalesce(p_subscription_id, '')), '');
  v_ref     text;
  v_id      uuid;
begin
  if p_session_id is null or btrim(p_session_id) = '' then
    raise exception 'A donation must carry the Stripe session it came from';
  end if;
  v_masjid := public.masjid_id_for(p_masjid);

  select id, reference into v_id, v_ref
    from public.donations
   where stripe_session_id = p_session_id and masjid_id = v_masjid;
  if found then
    return jsonb_build_object('reference', v_ref, 'status', 'paid',
                              'gift_aid', v_ga, 'already_recorded', true);
  end if;

  if v_purpose is not null and v_purpose not in ('general','sadaqah','lillah','newbuild') then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'donation_unknown_purpose',
            jsonb_build_object('session', p_session_id, 'purpose', p_purpose));
    v_purpose := null;
  end if;

  v_ref := 'DN-' || to_char(now(),'YY') || '-' ||
           lpad(nextval('public.donation_reference_seq')::text, 4, '0');

  insert into public.donations
    (masjid_id, reference, amount_p, status, stripe_session_id, paid_at, purpose,
     gift_aid, declaration_version, declared_at,
     donor_name, donor_address, donor_postcode, stripe_subscription_id, source)
  values
    (v_masjid, v_ref, p_amount_p, 'paid', p_session_id, now(), v_purpose, v_ga,
     case when v_ga then public.gift_aid_declaration_version() end,
     case when v_ga then now() end,
     case when v_ga then nullif(btrim(p_name), '') end,
     case when v_ga then nullif(btrim(p_address), '') end,
     case when v_ga then upper(nullif(btrim(p_postcode), '')) end,
     v_sub, 'online');

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'donation_paid', jsonb_build_object(
            'reference', v_ref, 'amount_pence', p_amount_p,
            'purpose', v_purpose, 'gift_aid', v_ga, 'subscription', v_sub,
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
                            'subscription', v_sub, 'already_recorded', false);
end;
$fn$;

create or replace function public.record_donation_paid(
  p_masjid text, p_reference text, p_session_id text, p_amount_p integer default null,
  p_gift_aid boolean default false, p_name text default null,
  p_address text default null, p_postcode text default null
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare v_ga boolean := coalesce(p_gift_aid, false); v_id uuid; v_masjid uuid;
begin
  if p_masjid is null then
    raise exception 'Which masjid is this donation for?' using errcode = '22023';
  end if;
  v_masjid := public.masjid_id_for(p_masjid);

  select id into v_id from public.donations
   where stripe_session_id = p_session_id and masjid_id = v_masjid;
  if found then
    return jsonb_build_object('reference', p_reference, 'status', 'paid',
                              'gift_aid', v_ga, 'already_recorded', true);
  end if;

  insert into public.donations
    (masjid_id, reference, amount_p, status, stripe_session_id, paid_at,
     gift_aid, declaration_version, declared_at, donor_name, donor_address,
     donor_postcode, source)
  values
    (v_masjid, p_reference, p_amount_p, 'paid', p_session_id, now(), v_ga,
     case when v_ga then public.gift_aid_declaration_version() end,
     case when v_ga then now() end,
     case when v_ga then nullif(trim(p_name), '') end,
     case when v_ga then nullif(trim(p_address), '') end,
     case when v_ga then upper(nullif(trim(p_postcode), '')) end,
     'online');

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'donation_paid', jsonb_build_object(
            'reference', p_reference, 'amount_pence', p_amount_p, 'gift_aid', v_ga,
            'declaration_version',
              case when v_ga then public.gift_aid_declaration_version() end));

  if v_ga and (nullif(trim(coalesce(p_postcode, '')), '') is null
            or nullif(trim(coalesce(p_name, '')), '') is null) then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'gift_aid_incomplete', jsonb_build_object(
              'reference', p_reference,
              'has_name', nullif(trim(coalesce(p_name, '')), '') is not null,
              'has_postcode', nullif(trim(coalesce(p_postcode, '')), '') is not null));
  end if;

  return jsonb_build_object('reference', p_reference, 'status', 'paid',
                            'gift_aid', v_ga, 'already_recorded', false);
end $fn$;

-- ---------------------------------------------------------------------------
--  record_card_machine_donation — the new way in, from the Terminal reader.
-- ---------------------------------------------------------------------------
create or replace function public.record_card_machine_donation(
  p_masjid             text,
  p_payment_intent_id  text,
  p_amount_p           integer,
  p_purpose            text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid; v_ref text; v_id uuid; v_purpose text;
begin
  if p_payment_intent_id is null or btrim(p_payment_intent_id) = '' then
    raise exception 'A card-machine donation must carry the Stripe payment intent it came from';
  end if;
  v_masjid := public.masjid_id_for(p_masjid);

  select id into v_id from public.donations
   where stripe_payment_intent_id = p_payment_intent_id and masjid_id = v_masjid;
  if found then
    return jsonb_build_object('status', 'paid', 'already_recorded', true);
  end if;

  -- The till screen's fund choice rides on the PaymentIntent's own metadata
  -- (set by terminal-worker), same as the donate page rides it on
  -- client_reference_id. Unrecognised is unspecified, never guessed at.
  v_purpose := lower(nullif(btrim(coalesce(p_purpose, '')), ''));
  if v_purpose is not null and v_purpose not in ('general','sadaqah','lillah','newbuild') then
    v_purpose := null;
  end if;

  v_ref := 'DN-' || to_char(now(),'YY') || '-' ||
           lpad(nextval('public.donation_reference_seq')::text, 4, '0');

  insert into public.donations
    (masjid_id, reference, amount_p, status, paid_at, source,
     gift_aid, purpose, stripe_payment_intent_id)
  values
    (v_masjid, v_ref, p_amount_p, 'paid', now(), 'in_person',
     false, v_purpose, p_payment_intent_id);

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'donation_paid', jsonb_build_object(
            'reference', v_ref, 'amount_pence', p_amount_p, 'purpose', v_purpose,
            'source', 'in_person', 'payment_intent', p_payment_intent_id));

  return jsonb_build_object('reference', v_ref, 'status', 'paid', 'already_recorded', false);
end;
$fn$;

revoke all on function public.record_card_machine_donation(text,text,integer,text) from public;
grant execute on function public.record_card_machine_donation(text,text,integer,text) to service_role;

-- ---------------------------------------------------------------------------
--  donations_by_source — "collected per source", the other half of the
--  "collected by fund" breakdown already on the dashboard.
-- ---------------------------------------------------------------------------
create or replace function public.donations_by_source()
returns table (source text, total_p bigint, donations_count bigint)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  select d.source, sum(d.amount_p), count(*)
    from public.donations d
   where d.masjid_id = public.current_masjid()
     and d.status = 'paid'
     and public.verified_admin()
   group by d.source
   order by sum(d.amount_p) desc
$fn$;

revoke all on function public.donations_by_source() from public;
grant execute on function public.donations_by_source() to authenticated;

-- ---------------------------------------------------------------------------
--  donations_summary_v2 / donations_recent_v2 — see the header note on why
--  these are new functions and not db/152's donations_summary() /
--  donations_recent() replaced in place.
-- ---------------------------------------------------------------------------
create or replace function public.donations_summary_v2()
returns table (
  total_collected_p bigint,
  donations_count   bigint,
  average_donation_p bigint,
  recurring_monthly_count     bigint,
  recurring_monthly_last_p    bigint,
  recurring_weekly_count      bigint,
  recurring_weekly_last_p     bigint
)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  with mine as (
    select * from public.donations d
     where d.masjid_id = public.current_masjid()
       and d.status = 'paid'
       and public.verified_admin()
  ),
  latest as (
    select distinct on (stripe_subscription_id)
           stripe_subscription_id, frequency, amount_p, paid_at
      from mine
     where stripe_subscription_id is not null
     order by stripe_subscription_id, paid_at desc
  )
  select
    coalesce(sum(m.amount_p), 0),
    count(*),
    case when count(*) > 0 then round(sum(m.amount_p)::numeric / count(*)) else 0 end,
    (select count(*) from latest l where l.frequency = 'monthly' and l.paid_at > now() - interval '40 days'),
    (select coalesce(sum(l.amount_p), 0) from latest l where l.frequency = 'monthly' and l.paid_at > now() - interval '40 days'),
    (select count(*) from latest l where l.frequency = 'weekly' and l.paid_at > now() - interval '40 days'),
    (select coalesce(sum(l.amount_p), 0) from latest l where l.frequency = 'weekly' and l.paid_at > now() - interval '40 days')
  from mine m
$fn$;

revoke all on function public.donations_summary_v2() from public;
grant execute on function public.donations_summary_v2() to authenticated;

create or replace function public.donations_recent_v2(p_limit integer default 15)
returns table (reference text, paid_at timestamptz, purpose text,
               amount_p integer, gift_aid boolean, frequency text, source text)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  select d.reference, d.paid_at, d.purpose, d.amount_p, d.gift_aid, d.frequency, d.source
    from public.donations d
   where d.masjid_id = public.current_masjid()
     and d.status = 'paid'
     and public.verified_admin()
   order by d.paid_at desc
   limit greatest(coalesce(p_limit, 15), 1)
$fn$;

revoke all on function public.donations_recent_v2(integer) from public;
grant execute on function public.donations_recent_v2(integer) to authenticated;

commit;
