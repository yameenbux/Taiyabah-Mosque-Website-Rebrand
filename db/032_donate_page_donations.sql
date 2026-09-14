-- ===========================================================================
--  032_donate_page_donations.sql — make the donate page's payments land
--
--  *** APPLIED TO PRODUCTION 14 September 2026. ***
--
--  Written after the masjid's FIRST EVER real card payment — £5, Sadaqah,
--  21:35 — did not appear anywhere in the masjid's systems. The money reached
--  Stripe. Nothing reached the database. The Gift Aid screen was empty
--  because the donations table was empty: not one row had ever been written.
--
--  TWO BUGS, AND THE SECOND ONE HID THE FIRST.
--
--  1.  THE DONATE PAGE SENDS THE PURPOSE AS client_reference_id.
--      "general", "sadaqah", "lillah". That was chosen because a Stripe
--      Payment Link cannot carry an amount or anything else in its URL, and
--      client_reference_id is the only field available.
--
--      But that field was ALREADY LOAD-BEARING. stripe-webhook decides what
--      kind of payment it is from the first three characters — HH- for a hall
--      deposit, NK- for a nikāḥ fee, DN- for a donation. "sadaqah" matches
--      none of them, so every donation was logged as an unrecognised
--      reference and recorded nowhere.
--
--      Reading Stripe's documentation on client_reference_id was not enough.
--      The code already listening on the other end had its own meaning for
--      the same field, and nobody checked.
--
--  2.  THE SAFETY NET COULD NOT WRITE EITHER.
--      The webhook is careful: money it cannot match is written to
--      admin_audit as 'payment_without_reference' or
--      'payment_with_unknown_reference_kind', so a human finds it and
--      refunds it. Not one of those rows exists, because service_role held
--      `Dxtm` on admin_audit — TRUNCATE, REFERENCES, TRIGGER, MAINTAIN — and
--      no INSERT. And once INSERT was granted it still failed, because the
--      id column defaults to nextval() and INSERT on a table is not USAGE on
--      its sequence.
--
--      So the one mechanism designed to make bug 1 visible was itself mute,
--      and eight payments left no trace at all. GRANT and RLS are different
--      things and you need both — this repository's README has said so since
--      migration 002, and it has now cost it twice.
--
--  WHAT THIS CHANGES
--
--    * donations gains `purpose`. The page has offered general / sadaqah /
--      lillah since 14 September and the table had nowhere to put the answer.
--      A masjid that cannot say what a gift was given for cannot honour the
--      intention behind it.
--
--    * record_public_donation() mints its own DN- reference from a sequence.
--      donations.reference is UNIQUE, so the page cannot simply send a fixed
--      "DN-sadaqah" — the second sadaqah donation would collide and be
--      refused. The reference has to be minted where the sequence lives.
--      record_donation_paid() is deliberately left exactly as it was.
--
--    * service_role may finally INSERT into admin_audit, sequence included.
--
--  WHAT IT DOES NOT CHANGE. service_role still cannot read donations or the
--  audit log directly. It calls functions; it is not a back door.
--
--  Prerequisites: 022 (donations, gift_aid_declaration_version). Note that
--  022 IS STILL MISSING FROM THIS REPOSITORY — the table is live and its
--  migration file has never been committed. That remains the worst thing
--  about this db/ folder.
--
--  *** AFTER RUNNING THIS, RE-RUN 011_require_two_step.sql. ***
-- ===========================================================================

begin;

alter table public.donations
  add column if not exists purpose text
    check (purpose is null or purpose in ('general','sadaqah','lillah','newbuild'));

comment on column public.donations.purpose is
  'What the donor chose on the donate page. Null for anything recorded before 14 September 2026.';

create sequence if not exists public.donation_reference_seq;

-- The safety net, ungagged. BOTH of these are needed: INSERT on the table is
-- not USAGE on the sequence its id column defaults from, and granting one
-- without the other leaves the webhook exactly as silent as it was.
grant insert on public.admin_audit to service_role;
grant usage, select on sequence public.admin_audit_id_seq to service_role;

create or replace function public.record_public_donation(
  p_session_id text,
  p_amount_p   integer,
  p_purpose    text,
  p_gift_aid   boolean,
  p_name       text,
  p_address    text,
  p_postcode   text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_ga      boolean := coalesce(p_gift_aid, false);
  v_purpose text := lower(nullif(btrim(coalesce(p_purpose, '')), ''));
  v_ref     text;
  v_id      uuid;
begin
  if p_session_id is null or btrim(p_session_id) = '' then
    raise exception 'A donation must carry the Stripe session it came from';
  end if;

  -- Idempotent on the Stripe session, exactly like record_donation_paid.
  -- Stripe retries a delivery for days, and a retry must never become a
  -- second donation.
  select id, reference into v_id, v_ref
    from public.donations where stripe_session_id = p_session_id;
  if found then
    return jsonb_build_object('reference', v_ref, 'status', 'paid',
                              'gift_aid', v_ga, 'already_recorded', true);
  end if;

  -- An unknown purpose is recorded as null rather than refused. The money has
  -- already been taken; losing the record because somebody renamed a button
  -- is the worse of the two outcomes by a long way.
  if v_purpose is not null and v_purpose not in ('general','sadaqah','lillah','newbuild') then
    insert into public.admin_audit (action, detail)
    values ('donation_unknown_purpose',
            jsonb_build_object('session', p_session_id, 'purpose', p_purpose));
    v_purpose := null;
  end if;

  v_ref := 'DN-' || to_char(now(),'YY') || '-' ||
           lpad(nextval('public.donation_reference_seq')::text, 4, '0');

  insert into public.donations
    (reference, amount_p, status, stripe_session_id, paid_at, purpose,
     gift_aid, declaration_version, declared_at,
     donor_name, donor_address, donor_postcode)
  values
    (v_ref, p_amount_p, 'paid', p_session_id, now(), v_purpose,
     v_ga,
     case when v_ga then public.gift_aid_declaration_version() end,
     case when v_ga then now() end,
     case when v_ga then nullif(btrim(p_name), '') end,
     case when v_ga then nullif(btrim(p_address), '') end,
     case when v_ga then upper(nullif(btrim(p_postcode), '')) end);

  insert into public.admin_audit (action, detail)
  values ('donation_paid', jsonb_build_object(
            'reference', v_ref, 'amount_pence', p_amount_p,
            'purpose', v_purpose, 'gift_aid', v_ga,
            'declaration_version',
              case when v_ga then public.gift_aid_declaration_version() end));

  -- Gift Aid claimed with no name or no postcode cannot actually be claimed:
  -- HMRC matches on the house number and the postcode. Better the office
  -- knows now than when the claim is disallowed.
  if v_ga and (nullif(btrim(coalesce(p_postcode,'')), '') is null
            or nullif(btrim(coalesce(p_name,'')), '') is null) then
    insert into public.admin_audit (action, detail)
    values ('gift_aid_incomplete', jsonb_build_object(
              'reference', v_ref,
              'has_name', nullif(btrim(coalesce(p_name,'')), '') is not null,
              'has_postcode', nullif(btrim(coalesce(p_postcode,'')), '') is not null));
  end if;

  return jsonb_build_object('reference', v_ref, 'status', 'paid',
                            'gift_aid', v_ga, 'purpose', v_purpose,
                            'already_recorded', false);
end;
$fn$;

-- Nobody but the webhook. anon and authenticated must never be able to say
-- "a payment happened" — a browser claiming that is not evidence of anything.
revoke all on function public.record_public_donation(text,integer,text,boolean,text,text,text) from public;
grant execute on function public.record_public_donation(text,integer,text,boolean,text,text,text) to service_role;

commit;

-- ---------------------------------------------------------------------------
--  RECOVERING THE PAYMENTS THAT WERE LOST
--
--  Nothing here can do it: the money is in Stripe and this database has no
--  Stripe API key, deliberately. In the Stripe Dashboard, under Developers ->
--  Webhooks -> the endpoint -> Events, each failed delivery has a "Resend"
--  button. Resending a checkout.session.completed replays it through the
--  fixed function, and record_public_donation() is idempotent on the Stripe
--  session id, so resending twice cannot create two donations.
--
--  The ones that carried no client_reference_id at all — links opened
--  directly while the sixteen were being checked — will land in admin_audit
--  as 'payment_without_reference' rather than as donations. That is correct:
--  the masjid genuinely does not know what they were for.
-- ---------------------------------------------------------------------------
