-- 133 — the payment safety net knows which masjid
--
-- WHY. record_unmatched_payment() is the only way money that cannot be matched
-- to a booking, a nikāḥ or a donation is ever seen by a human. It resolves the
-- masjid with sole_masjid(), which RAISES as soon as a second masjid exists:
--
--     'This system now runs more than one masjid, so this call has to say
--      which. Update the caller to pass a masjid slug.'
--
-- That is the correct behaviour for sole_masjid() — it fails closed rather than
-- attributing one masjid's money to another. But it means that on the day of
-- the second onboarding, this function starts raising for every unmatched
-- payment at EVERY masjid, including Taiyabah. The webhook catches the error,
-- logs it and still answers Stripe 200, because it must. So the net would
-- break silently, in production, triggered by an unrelated act.
--
-- THIS IS THE THIRD TIME THIS EXACT NET HAS BROKEN. First service_role held no
-- INSERT on admin_audit (db/032). Then admin_audit gained masjid_id NOT NULL
-- and the webhook's unchecked insert failed for a fortnight, losing all trace
-- of forty-two paid checkout sessions on 2 October alone. Both times the
-- failure was invisible because money still looked like it had been taken —
-- it had — and Stripe was still told everything was fine.
--
-- So this is fixed BEFORE the second masjid exists, not after.
--
-- THE SHAPE OF THE FIX. The webhook now derives the masjid from the Stripe
-- signing secret that verified the delivery. Each masjid has its own Stripe
-- account and therefore its own secret, so the secret that validates the HMAC
-- IS the identity of the sender. The masjid never comes from the request body,
-- which means a forged delivery cannot attribute itself to another masjid even
-- if the attacker knows every slug.

-- ---------------------------------------------------------------------------
-- The new overload. Named p_masjid first, matching mark_deposit_paid,
-- record_donation_paid and the rest, so PostgREST selects it on the supplied
-- argument names.
create or replace function public.record_unmatched_payment(
  p_masjid text,
  p_action text,
  p_detail jsonb
)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_masjid uuid;
  v_id     bigint;
begin
  if p_masjid is null or btrim(p_masjid) = '' then
    raise exception 'record_unmatched_payment: a masjid is required — this records real money arriving'
      using errcode = '22023';
  end if;

  if p_action not in ('payment_without_reference',
                      'payment_with_unknown_reference_kind',
                      'gift_aid_field_missing') then
    raise exception 'record_unmatched_payment: % is not one of the payment audit actions', p_action
      using errcode = '22023';
  end if;

  /* Raises on an unknown slug, which is what should happen: money has arrived
     that cannot be attributed, and inventing an attribution is worse than
     shouting. Note masjid_id_for() also requires is_live — a masjid still
     being set up cannot audit a payment, and should not be taking any. */
  v_masjid := public.masjid_id_for(btrim(p_masjid));

  insert into public.admin_audit(action, detail, masjid_id)
  values (p_action, coalesce(p_detail, '{}'::jsonb), v_masjid)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'masjid', btrim(p_masjid));
end;
$$;

/* THE GRANTS GO HERE, NOT AT THE END OF THE FILE, and that is the whole point
   of this placement. A new function is created with EXECUTE granted to PUBLIC
   by default, and the files in this folder are applied BY HAND, one statement
   at a time, in the SQL editor. With the revoke at the bottom, every statement
   between the create and the revoke is a window in which anon can call it.

   This was not hypothetical. Applying this very migration on 5 October left
   record_unmatched_payment(text,text,jsonb) executable by anon and
   authenticated — an anonymous visitor could have written rows into any live
   masjid's audit log — because the MCP tooling timed out before reaching the
   bottom of the file. Caught by checking has_function_privilege afterwards
   rather than assuming the file had run to the end.

   Mirrors the existing two-argument form: service_role only. Nothing in a
   browser has any business writing a payment audit row, and the webhook is
   the only caller. */
revoke all on function public.record_unmatched_payment(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.record_unmatched_payment(text, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- The old two-argument form STAYS, and is now a shim over the one above.
--
-- It stays because the currently deployed webhook still calls it, and dropping
-- it would break the net the moment this migration ran — the precise failure
-- this file exists to prevent. It becomes a shim so that the action whitelist
-- and the insert live in exactly one place; two copies of a safety net is how
-- one of them gets fixed and the other does not.
--
-- It keeps sole_masjid()'s behaviour, so it still fails closed at masjid #2.
-- That is deliberate: it is a deprecation with a deadline attached to it. Once
-- the webhook carrying p_masjid is deployed, this can be dropped. Until then
-- it is what keeps Taiyabah's net working.
create or replace function public.record_unmatched_payment(
  p_action text,
  p_detail jsonb
)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_slug text;
begin
  select slug into v_slug from public.masjids where id = public.sole_masjid();
  if v_slug is null then
    raise exception 'record_unmatched_payment: no masjid to attribute this payment to'
      using errcode = 'P0002';
  end if;
  return public.record_unmatched_payment(v_slug, p_action, p_detail);
end;
$$;

comment on function public.record_unmatched_payment(text, jsonb) is
  'DEPRECATED. Calls sole_masjid() and so raises once a second masjid exists. '
  'Kept only until the stripe-webhook that passes p_masjid is deployed; drop it then.';


-- ---------------------------------------------------------------------------
-- TO REVERSE. The three-argument form is additive, so reversing is a drop:
--
--     drop function public.record_unmatched_payment(text, text, jsonb);
--
-- and then restore the two-argument body from 032 if the shim is unwanted.
-- Reversing is only safe while no deployed webhook passes p_masjid; after that
-- deploy, dropping this is what breaks the net.
--
-- Note that `create or replace function` PRESERVES the existing grants — checked
-- rather than assumed, because if it reset them the two-argument form would
-- have silently become executable by anon, and an anonymous visitor could then
-- write rows into the masjid's audit log. A NEW function is the opposite case:
-- it starts PUBLIC, which is why its revoke sits next to its create above.
--
-- APPLIED to production on 5 October 2026, statement by statement because the
-- MCP tooling timed out on the file as a whole. Verified afterwards: two forms,
-- one taking p_masjid, nothing reachable from a browser, all three refusal
-- paths correct, and the write path exercised inside a subtransaction that
-- rolled itself back so no test row reached the audit log.
--
-- ONE STATEMENT DID NOT APPLY: the `comment on function` for the two-argument
-- form times out repeatedly while every other statement goes through — the
-- same symptom this repo already records for
-- `drop function public.masjid_theme(text)`. It is documentation only; the
-- deprecation and its deadline are stated in this file, which is the record
-- that matters. Re-run it from the Supabase SQL editor when convenient.

-- ---------------------------------------------------------------------------
-- Verification, in the house style: both forms present, and nothing public.
select
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'record_unmatched_payment') as forms,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'record_unmatched_payment'
      and pg_get_function_arguments(p.oid) like 'p\_masjid%') as masjid_forms,
  (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'record_unmatched_payment'
      and (has_function_privilege('anon', p.oid, 'EXECUTE')
        or has_function_privilege('authenticated', p.oid, 'EXECUTE'))) as reachable_from_a_browser;
