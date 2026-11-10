-- ===========================================================================
--  152 — recurring donations, and a dashboard that is not just Gift Aid
--
--  Taiyabah Masjid · 8 November 2026
--
--  THE BUG THIS FOUND, FIXED HERE RATHER THAN LEFT FOR LATER
--  ----------------------------------------------------------
--  "Monthly" and "Friday Pay" on the donate page are separate Stripe Payment
--  Links from the one-off amounts, which is the standard way Stripe does a
--  recurring gift: the Payment Link runs in SUBSCRIPTION mode. A subscription
--  fires `checkout.session.completed` exactly once, at sign-up. Every charge
--  after that fires `invoice.paid` instead — an event stripe-webhook has
--  never subscribed to.
--
--  So the first £10 of a £10-a-month gift was recorded. Every £10 after it,
--  for as long as the standing instruction ran, left NO row in `donations`
--  and NO row in `admin_audit` — Stripe never called this endpoint for it at
--  all, so even the safety net that catches a payment nothing else matches
--  never saw it. The only trace was in Stripe itself.
--
--  WHAT THIS FILE ADDS
--  --------------------
--    * donations gains `frequency`, `stripe_subscription_id` and
--      `stripe_invoice_id`. A one-off gift (everything before this file, and
--      everything from the one-off links after it) has frequency NULL — NULL
--      means "a single gift", not "monthly, we just don't know it yet". A
--      row that cannot say which it is should not say either.
--    * record_public_donation(p_masjid, ...) gains one more trailing
--      argument, p_subscription_id, so the SIGN-UP charge can carry the
--      subscription it started.
--    * record_subscription_frequency() patches that sign-up row's frequency
--      once Stripe's first invoice says what the recurring interval actually
--      is — the Checkout Session itself does not carry it.
--    * record_subscription_charge() is the new row for every charge AFTER
--      the first: it inherits purpose, Gift Aid and the donor's declaration
--      from the sign-up row (a Gift Aid declaration covers the gifts that
--      follow it, which is the HMRC rule this mirrors, not an invention), and
--      is idempotent on the Stripe invoice id rather than a session id, since
--      a renewal charge has no Checkout Session at all.
--
--      AN UNMATCHED SUBSCRIPTION CHARGE IS NOT GUESSED AT. The masjid's
--      Stripe account is shared with iBeams (see db/032's note in
--      stripe-webhook), and nothing says a subscription on that account is
--      necessarily one of these donations. record_subscription_charge()
--      audits 'subscription_charge_unmatched' and writes no donation row
--      when it cannot find the sign-up it belongs to — the same caution
--      db/032 already applies to a session with no reference at all.
--
--    * Four read functions for a dashboard, each failing closed exactly like
--      gift_aid_to_claim() — empty rows for anybody who is not
--      verified_admin(), not an error, so a non-administrator sees nothing
--      rather than being told what is being hidden.
--
--  WHAT IT DELIBERATELY DOES NOT CLAIM
--  ------------------------------------
--  There is no "active subscriptions" count here, because knowing one is
--  active means knowing it has not been cancelled, and nothing in this
--  codebase listens for `customer.subscription.deleted` — so there is no way
--  to tell a subscription that is still running from one that ended last
--  month and simply has not reached its next charge date. The dashboard
--  reports donors who HAVE BEEN CHARGED inside the last 40 days instead
--  (comfortably past a four-week gap, short of two), and the screen says so
--  in those words. A number this database cannot stand behind does not
--  appear on it as if it could.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  The three new columns.
-- ---------------------------------------------------------------------------
alter table public.donations
  add column if not exists frequency text,
  add column if not exists stripe_subscription_id text,
  add column if not exists stripe_invoice_id text;

do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'donations_frequency_known') then
    alter table public.donations add constraint donations_frequency_known
      check (frequency is null or frequency in ('monthly','weekly'));
  end if;

  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'donations_stripe_invoice_id_key') then
    alter table public.donations add constraint donations_stripe_invoice_id_key
      unique (stripe_invoice_id);
  end if;
end $$;

comment on column public.donations.frequency is
  'NULL for a single gift. ''monthly'' or ''weekly'' for a charge that belongs '
  'to a Stripe subscription — set from the subscription''s own invoices, never '
  'guessed from the amount or the date.';
comment on column public.donations.stripe_subscription_id is
  'The Stripe subscription this charge belongs to. Shared by every charge in '
  'the same standing gift, including the first.';
comment on column public.donations.stripe_invoice_id is
  'Set only on a charge AFTER the first (see stripe_session_id for that one). '
  'Idempotency key for record_subscription_charge(), because a renewal has no '
  'Checkout Session to key off.';

create index if not exists donations_subscription_idx
  on public.donations (stripe_subscription_id)
  where stripe_subscription_id is not null;

-- ---------------------------------------------------------------------------
--  record_public_donation(p_masjid, ...) — one more trailing argument.
--  CREATE OR REPLACE with a new DEFAULTed parameter at the end is
--  backward-compatible: db/151's version of this call, and the webhook as it
--  stood before this file, still work unchanged.
-- ---------------------------------------------------------------------------
create or replace function public.record_public_donation(
  p_masjid          text,
  p_session_id      text,
  p_amount_p        integer,
  p_purpose         text,
  p_gift_aid        boolean,
  p_name            text,
  p_address         text,
  p_postcode        text,
  p_subscription_id text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
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
     donor_name, donor_address, donor_postcode, stripe_subscription_id)
  values
    (v_masjid, v_ref, p_amount_p, 'paid', p_session_id, now(), v_purpose, v_ga,
     case when v_ga then public.gift_aid_declaration_version() end,
     case when v_ga then now() end,
     case when v_ga then nullif(btrim(p_name), '') end,
     case when v_ga then nullif(btrim(p_address), '') end,
     case when v_ga then upper(nullif(btrim(p_postcode), '')) end,
     v_sub);

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

revoke all on function public.record_public_donation(text,text,integer,text,boolean,text,text,text,text) from public;
grant execute on function public.record_public_donation(text,text,integer,text,boolean,text,text,text,text) to service_role;

-- ---------------------------------------------------------------------------
--  record_subscription_frequency — patches the sign-up row once the first
--  invoice says what interval it actually is. Idempotent: the second call
--  (a Stripe retry, or the real second invoice re-stating subscription_create
--  by mistake) updates nothing, because it only ever touches a row whose
--  frequency is still null.
-- ---------------------------------------------------------------------------
create or replace function public.record_subscription_frequency(
  p_masjid          text,
  p_subscription_id text,
  p_frequency       text
) returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid; v_n int;
begin
  if p_frequency is not null and p_frequency not in ('monthly','weekly') then
    raise exception 'Unknown donation frequency: %', p_frequency using errcode = '22023';
  end if;
  v_masjid := public.masjid_id_for(p_masjid);

  update public.donations
     set frequency = p_frequency
   where masjid_id = v_masjid
     and stripe_subscription_id = p_subscription_id
     and frequency is null
     and p_frequency is not null;
  get diagnostics v_n = row_count;

  if v_n = 0 then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'subscription_signup_unmatched', jsonb_build_object(
              'subscription', p_subscription_id, 'frequency', p_frequency));
  end if;

  return v_n > 0;
end;
$fn$;

revoke all on function public.record_subscription_frequency(text,text,text) from public;
grant execute on function public.record_subscription_frequency(text,text,text) to service_role;

-- ---------------------------------------------------------------------------
--  record_subscription_charge — every charge after the first.
-- ---------------------------------------------------------------------------
create or replace function public.record_subscription_charge(
  p_masjid          text,
  p_subscription_id text,
  p_invoice_id      text,
  p_amount_p        integer,
  p_frequency       text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid;
  v_seed   record;
  v_ref    text;
begin
  if p_subscription_id is null or btrim(p_subscription_id) = '' then
    raise exception 'A recurring charge must carry the subscription it belongs to';
  end if;
  if p_invoice_id is null or btrim(p_invoice_id) = '' then
    raise exception 'A recurring charge must carry the Stripe invoice it came from';
  end if;
  v_masjid := public.masjid_id_for(p_masjid);

  if exists (select 1 from public.donations
              where stripe_invoice_id = p_invoice_id and masjid_id = v_masjid) then
    return jsonb_build_object('status', 'paid', 'already_recorded', true);
  end if;

  -- The sign-up row — the earliest charge on this subscription — is where
  -- purpose, Gift Aid and the donor's declaration live. A renewal invoice
  -- carries none of that; it is inherited, not re-asked.
  select purpose, gift_aid, declaration_version, declared_at, donor_name,
         donor_address, donor_postcode
    into v_seed
    from public.donations
   where masjid_id = v_masjid and stripe_subscription_id = p_subscription_id
   order by paid_at asc
   limit 1;

  if not found then
    -- Real money, on a subscription this database has no sign-up for. The
    -- Stripe account is shared with iBeams, and nothing says this is one of
    -- ours — so it is confessed, not claimed.
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'subscription_charge_unmatched', jsonb_build_object(
              'subscription', p_subscription_id, 'invoice', p_invoice_id,
              'amount_pence', p_amount_p));
    return jsonb_build_object('status', 'unmatched', 'already_recorded', false);
  end if;

  v_ref := 'DN-' || to_char(now(),'YY') || '-' ||
           lpad(nextval('public.donation_reference_seq')::text, 4, '0');

  insert into public.donations
    (masjid_id, reference, amount_p, status, paid_at, purpose,
     gift_aid, declaration_version, declared_at,
     donor_name, donor_address, donor_postcode,
     stripe_subscription_id, stripe_invoice_id, frequency)
  values
    (v_masjid, v_ref, p_amount_p, 'paid', now(), v_seed.purpose,
     v_seed.gift_aid, v_seed.declaration_version,
     v_seed.declared_at,
     v_seed.donor_name, v_seed.donor_address, v_seed.donor_postcode,
     p_subscription_id, p_invoice_id,
     coalesce(p_frequency, (select frequency from public.donations
                              where masjid_id = v_masjid
                                and stripe_subscription_id = p_subscription_id
                                and frequency is not null limit 1)));

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'donation_paid', jsonb_build_object(
            'reference', v_ref, 'amount_pence', p_amount_p,
            'purpose', v_seed.purpose, 'gift_aid', v_seed.gift_aid,
            'subscription', p_subscription_id, 'recurring_charge', true,
            'declaration_version', v_seed.declaration_version));

  return jsonb_build_object('reference', v_ref, 'status', 'paid',
                            'gift_aid', v_seed.gift_aid, 'already_recorded', false);
end;
$fn$;

revoke all on function public.record_subscription_charge(text,text,text,integer,text) from public;
grant execute on function public.record_subscription_charge(text,text,text,integer,text) to service_role;

-- ---------------------------------------------------------------------------
--  The dashboard. Four read functions, each failing closed on its own —
--  not one blob, so a page that only needs the daily chart does not pull the
--  whole thing, and a test can check one piece without faking the rest.
-- ---------------------------------------------------------------------------
create or replace function public.donations_summary()
returns table (
  total_collected_p bigint,
  donations_count   bigint,
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
  -- the most recent charge per subscription, so a standing gift is counted
  -- once by what it is currently worth, not once per charge it has ever made
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
    (select count(*) from latest l where l.frequency = 'monthly' and l.paid_at > now() - interval '40 days'),
    (select coalesce(sum(l.amount_p), 0) from latest l where l.frequency = 'monthly' and l.paid_at > now() - interval '40 days'),
    (select count(*) from latest l where l.frequency = 'weekly' and l.paid_at > now() - interval '40 days'),
    (select coalesce(sum(l.amount_p), 0) from latest l where l.frequency = 'weekly' and l.paid_at > now() - interval '40 days')
  from mine m
$fn$;

create or replace function public.donations_daily(p_days integer default 28)
returns table (day date, total_p bigint, donations_count bigint)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  -- generate_series first, so a day with nothing collected is a zero row
  -- rather than a gap a chart has to notice and fill in itself.
  select s.day, coalesce(sum(d.amount_p), 0), count(d.id)
    from generate_series(current_date - (greatest(coalesce(p_days,28),1) - 1),
                          current_date, interval '1 day') as s(day)
    left join public.donations d
           on d.paid_at::date = s.day
          and d.masjid_id = public.current_masjid()
          and d.status = 'paid'
          and public.verified_admin()
   group by s.day
   order by s.day
$fn$;

create or replace function public.donations_by_purpose()
returns table (purpose text, total_p bigint, donations_count bigint)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  select coalesce(d.purpose, 'unspecified'), sum(d.amount_p), count(*)
    from public.donations d
   where d.masjid_id = public.current_masjid()
     and d.status = 'paid'
     and public.verified_admin()
   group by coalesce(d.purpose, 'unspecified')
   order by sum(d.amount_p) desc
$fn$;

-- No donor name, address or postcode — this is the dashboard everybody with
-- the admin role sees, not the Gift Aid panel, which stays the one place
-- that shows who gave what.
create or replace function public.donations_recent(p_limit integer default 15)
returns table (reference text, paid_at timestamptz, purpose text,
               amount_p integer, gift_aid boolean, frequency text)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  select d.reference, d.paid_at, d.purpose, d.amount_p, d.gift_aid, d.frequency
    from public.donations d
   where d.masjid_id = public.current_masjid()
     and d.status = 'paid'
     and public.verified_admin()
   order by d.paid_at desc
   limit greatest(coalesce(p_limit, 15), 1)
$fn$;

-- A function created fresh has EXECUTE granted to PUBLIC by default, and
-- CREATE OR REPLACE does not revoke a grant that is already there — db/140
-- lost this exact fight twice. Revoke first, by name, then grant back only
-- to authenticated.
revoke all on function public.donations_summary()        from public;
revoke all on function public.donations_daily(integer)   from public;
revoke all on function public.donations_by_purpose()      from public;
revoke all on function public.donations_recent(integer)  from public;

grant execute on function public.donations_summary()            to authenticated;
grant execute on function public.donations_daily(integer)       to authenticated;
grant execute on function public.donations_by_purpose()         to authenticated;
grant execute on function public.donations_recent(integer)      to authenticated;

commit;
