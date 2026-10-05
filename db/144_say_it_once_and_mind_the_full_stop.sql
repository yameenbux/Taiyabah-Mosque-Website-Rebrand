-- ===========================================================================
--  144 — say it once, and mind the full stop
--
--  MasjidOne · 5 October 2026
--
--  Two small things, both found by looking at the screen rather than at the
--  code, and both of the kind that quietly cost credibility on a console the
--  supplier shows to nobody but itself — which is exactly where sloppiness
--  survives longest.
--
--  1. A DOUBLE FULL STOP. billing_direct_debit built its sentence as
--     'Not billed: ' || not_billable_why || '.', and the founding masjid's
--     reason already ends in one. The screen read "...changing that
--     agreement..". Fixed by trimming before appending rather than by
--     assuming the stored text has no punctuation — the next reason somebody
--     types will have whatever punctuation they felt like.
--
--  2. THE REASON WAS PRINTED TWICE, once by the billing panel and again by the
--     Direct Debit panel inside it, in full, three lines apart. That half is
--     fixed in components/admin-direct-debit.tsx; this file only stops the
--     database handing out the long version for the second one.
-- ===========================================================================

begin;

create or replace function public.billing_direct_debit(p_masjid text)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_b public.masjid_billing%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may read billing.'
      using errcode = '42501';
  end if;
  select id into v_id from public.masjids where slug = p_masjid;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_masjid using errcode = '22023';
  end if;
  select * into v_b from public.masjid_billing where masjid_id = v_id;
  if not found then
    return jsonb_build_object('set_up', false,
      'why', 'No billing details yet. Fill those in first.');
  end if;

  return jsonb_build_object(
    'set_up',          v_b.stripe_customer_id is not null,
    /* THE ID ITSELF, and not merely whether there is one. /start reuses the
       customer when there already is one; without this it would create a
       second Stripe customer on a second attempt, and a masjid with two
       customers can end up with two mandates against one bank account. Only a
       two-step platform admin can reach this function at all. */
    'stripe_customer_id', v_b.stripe_customer_id,
    'billable',        v_b.billable,
    'not_billable_why',v_b.not_billable_why,
    'auto_bill',       v_b.auto_bill,
    'mandate_state',   v_b.mandate_state,
    'mandate_at',      v_b.mandate_at,
    'has_subscription',v_b.stripe_subscription_id is not null,
    'next_charge_on',  v_b.stripe_next_charge_on,
    'cycle',           v_b.cycle,
    'billing_email',   v_b.billing_email,
    'setup_fee_state', v_b.setup_fee_state,
    /* The plan and band in force. The edge function needs them to work out
       the amount from PRICING_BANDS, and it must not be told the amount by a
       browser — so it asks for the band and does the arithmetic itself. */
    'plan_code',       (select plan_code from public.masjid_plan
                         where masjid_id = v_id and ended_on is null),
    'band',            (select band from public.masjid_plan
                         where masjid_id = v_id and ended_on is null),
    /* Said in a sentence, because "pending" on its own reads like a delay
       somebody caused rather than how Bacs works.

       NOT BILLED IS THE SHORT VERSION. The panel above this one already
       prints the agreement clause in full; repeating it here put the same
       paragraph on the screen twice, three lines apart. */
    'where_it_stands', case
      when not v_b.billable then
        'A Direct Debit is an invoice that collects itself, so it is refused for the same reason an invoice is.'
      when v_b.stripe_customer_id is null then 'Nothing set up. Send them the Direct Debit link to start.'
      when v_b.mandate_state = 'pending' then 'They have signed. Bacs is confirming it with their bank, which takes a few working days — nothing can be collected until it does.'
      when v_b.mandate_state = 'failed' then 'The bank refused the mandate. Somebody has to ring them; the Direct Debit has been switched off.'
      when v_b.mandate_state = 'cancelled' then 'They cancelled it at their bank. The Direct Debit has been switched off.'
      when v_b.mandate_state = 'active' and v_b.auto_bill then 'Collecting monthly by Direct Debit. Stripe raises the invoice, chases a failure and emails them.'
      when v_b.mandate_state = 'active' then 'The mandate is live but collection has not been switched on yet.'
      else 'Nothing set up yet.' end,
    /* For anywhere that DOES want the reason in a sentence of its own, with
       whatever punctuation the person typed tidied off the end rather than
       doubled. */
    'not_billed_sentence', case when v_b.billable then null else
      'Not billed: ' || rtrim(coalesce(v_b.not_billable_why, 'no reason recorded'), ' .') || '.' end);
end $$;
revoke all on function public.billing_direct_debit(text) from public, anon, authenticated;
grant execute on function public.billing_direct_debit(text) to authenticated;

commit;
