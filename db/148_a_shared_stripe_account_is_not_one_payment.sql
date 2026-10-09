--  =====================================================================
--  148 — A SHARED STRIPE ACCOUNT IS NOT ONE PAYMENT SYSTEM
--  9 October 2026
--  =====================================================================
--
--  Confirmed with the masjid: the madrasah still runs its fees through
--  iBeams, which bills by creating a Stripe Checkout Session directly
--  through the API — a different amount every time, because it is
--  charging each family's actual balance, not a fixed price. iBeams and
--  this codebase happen to share one Stripe account, and Stripe webhooks
--  are account-wide, not scoped to who created the session. So every
--  iBeams fee payment also arrives at stripe-webhook, which has never
--  heard of iBeams and correctly cannot match it to anything — and,
--  before this migration, logged it as 'payment_without_reference', the
--  same category as somebody actually misusing one of THIS codebase's
--  own links. 90 of those by 9 October, growing daily, read as the
--  masjid's money going missing. It never was. iBeams has its own record
--  of every one of these.
--
--  THE SIGNAL THAT TELLS THEM APART: payment_link. Every payment flow this
--  codebase owns — the donate matrix, New Build, nikāḥ fees, the hall
--  deposit — is a Stripe Payment Link, because a Payment Link is the only
--  way to fix a price without a server round-trip. A session with NO
--  client_reference_id and NO payment_link was not created by a Payment
--  Link at all, so it cannot be one of ours paid the wrong way — it is
--  something else's session on the same account. stripe-webhook now splits
--  on this (deployed separately, see its own history) and sends that case
--  here as 'external_payment_received' instead of 'payment_without_reference'.
--  The case that keeps the old name — a Payment Link opened directly,
--  bypassing the reference step — genuinely is this codebase's problem,
--  and still gets logged and listed exactly as before.
--
--  THIS MIGRATION makes the Daily Log agree: 'external_payment_received'
--  joins the 'auto' bucket audit_kind() already uses for a cron sweep or a
--  health check (db/130) — real, but not a thing a person did, and not
--  something the committee needs to be shown one row at a time. It is
--  still counted via auto_count, so the money is not hidden, only no
--  longer raised as an alarm about this codebase's own payment links.
--  =====================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'audit_kind';

  if v_def is null then
    raise exception '148: audit_kind() is not there to patch.';
  end if;

  if position('external_payment_received' in v_def) > 0 then
    raise notice '148: already knows about an external payment.';
    return;
  end if;

  --  READ-PATCH-REFUSE. Refuses rather than half-patching if the shape moved.
  v_new := replace(v_def,
$a$      or p_action like 'health_%'         then 'auto'$a$,
$b$      or p_action like 'health_%'
      --  ADDED BY 148. A payment on the masjid's Stripe account that this
      --  codebase did not create and cannot match to anything of its own —
      --  iBeams billing a madrasah fee, confirmed 9 October. Nobody here
      --  did it and nobody here needs to read about it one row at a time.
      or p_action = 'external_payment_received' then 'auto'$b$);

  if v_new = v_def then
    raise exception '148: the auto branch did not match. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  record_unmatched_payment(p_masjid, p_action, p_detail) is the function
--  that actually writes the admin_audit row, and it CHECKS p_action against
--  a fixed list before it will insert anything — the same safety that stops
--  a typo from silently landing as a new, unaudited action also stops a
--  genuinely new one. Without this, stripe-webhook's new category would
--  raise 22023 on every call, auditPayment() would log "COULD NOT AUDIT",
--  and every iBeams payment would go from "logged but misclassified" to
--  "not recorded at all" — worse than what this migration set out to fix.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_unmatched_payment'
     and p.pronargs = 3;

  if v_def is null then
    raise exception '148: record_unmatched_payment(p_masjid, p_action, p_detail) is not there to patch.';
  end if;

  if position('external_payment_received' in v_def) > 0 then
    raise notice '148: record_unmatched_payment already allows an external payment.';
    return;
  end if;

  v_new := replace(v_def,
$a$  if p_action not in ('payment_without_reference',
                      'payment_with_unknown_reference_kind',
                      'gift_aid_field_missing') then$a$,
$b$  if p_action not in ('payment_without_reference',
                      'payment_with_unknown_reference_kind',
                      'gift_aid_field_missing',
                      'external_payment_received') then$b$);

  if v_new = v_def then
    raise exception '148: record_unmatched_payment check list did not match. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  audit_sentence() falls through to a readable default for any action it
--  does not name explicitly, so this is not load-bearing — added anyway,
--  on the chance something other than the Daily Log ever lists an 'auto'
--  row by its sentence rather than just counting it.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'audit_sentence';

  if v_def is null then
    raise exception '148: audit_sentence() is not there to patch.';
  end if;

  if position('external_payment_received' in v_def) > 0 then
    raise notice '148: audit_sentence already knows about an external payment.';
    return;
  end if;

  v_new := replace(v_def,
$a$    when 'donation_paid'           then 'Donation received'$a$,
$b$    when 'donation_paid'           then 'Donation received'
    when 'external_payment_received' then 'Payment received by another system on this Stripe account'$b$);

  if v_new = v_def then
    raise exception '148: audit_sentence anchor did not match. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  audit_kind() is IMMUTABLE and reads nothing; restated per 130's own
--  precedent rather than assumed to survive CREATE OR REPLACE untouched.
revoke all on function public.audit_kind(text) from public, anon;
grant execute on function public.audit_kind(text) to authenticated, postgres;

--  =====================================================================
--  PROOF, exactly as it ran.
--
--    select public.audit_kind('external_payment_received') as other_system,
--           public.audit_kind('payment_without_reference')  as still_ours,
--           public.audit_kind('bmcc_sweep_not_configured')   as still_auto,
--           public.audit_kind('donation_paid')               as still_public;
--
--    Expected, and what it printed:
--      other_system=auto  still_ours=staff  still_auto=auto  still_public=public
--
--  The middle two matter as much as the first: this migration must not
--  touch what 'payment_without_reference' means, and must not make a cron
--  job's own classification collateral damage.
--  =====================================================================
