-- Behaviour tests for 143 — both shapes of Stripe's Invoice object.
-- Runs after the 141 and 142 suites, which leave the fixtures in place.
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function pg_temp.ok3(p_label text, p_cond boolean) returns void
language plpgsql as $$
begin
  if not p_cond then raise exception 'FAIL: %', p_label; end if;
  raise notice 'pass  %', p_label;
end $$;

/* A Stripe invoice as 2026-08-26.dahlia sends one: no payment_intent, no
   charge, no paid; the payment link lives in payments.data[], and tax is an
   ARRAY called total_taxes. This is the shape a new Stripe account has no
   choice about — its webhook endpoint offers dahlia or dahlia.preview and
   nothing older. */
create or replace function pg_temp.sinv_dahlia(
  p_id text, p_customer text, p_status text, p_number text,
  p_unit int, p_pi text default null, p_tax int default null)
returns jsonb language sql as $$
  select jsonb_build_object(
    'id', p_id, 'customer', p_customer, 'status', p_status, 'number', p_number,
    'created', 1793232000, 'due_date', 1795824000,
    'period_start', 1793232000, 'period_end', 1795824000,
    'amount_paid', case when p_status = 'paid' then p_unit end,
    'hosted_invoice_url', 'https://invoice.stripe.com/' || p_id,
    'status_transitions', jsonb_build_object(
      'finalized_at', 1793232000,
      'paid_at', case when p_status = 'paid' then 1793318400 end),
    'total_taxes', case when p_tax is null then '[]'::jsonb
                   else jsonb_build_array(jsonb_build_object('amount', p_tax)) end,
    'payments', jsonb_build_object('data',
      case when p_pi is null then '[]'::jsonb
      else jsonb_build_array(jsonb_build_object(
             'payment', jsonb_build_object('type','payment_intent',
                                           'payment_intent', p_pi))) end),
    'lines', jsonb_build_object('data', jsonb_build_array(
      jsonb_build_object(
        'description', 'Masjid Complete — December 2026',
        'quantity', 1,
        'period', jsonb_build_object('start', 1793232000, 'end', 1795824000),
        'pricing', jsonb_build_object('price_details',
                     jsonb_build_object('unit_amount', p_unit))))));
$$;

delete from public._test_session;

-- --------------------------------------------------------------------------
-- The crash that 141 would have had on every single delivery.
-- --------------------------------------------------------------------------
select public.invoice_from_stripe(
  pg_temp.sinv_dahlia('in_d1','cus_alpha','open','IN-D001',26900));
select pg_temp.ok3('a dahlia invoice imports at all — total_taxes as an array no longer breaks the cast',
  (select status = 'sent' from public.invoices where stripe_invoice_id = 'in_d1'));
select pg_temp.ok3('no tax means zero, not a crash',
  (select vat_p = 0 from public.invoices where stripe_invoice_id = 'in_d1'));

select public.invoice_from_stripe(
  pg_temp.sinv_dahlia('in_d2','cus_alpha','open','IN-D002',26900, null, 5380));
select pg_temp.ok3('a total_taxes array is summed rather than cast',
  (select vat_p = 5380 from public.invoices where stripe_invoice_id = 'in_d2'));

select pg_temp.ok3('the pre-basil integer tax still works, so the old shape is not broken',
  public.stripe_invoice_tax_p('{"tax": 1234}'::jsonb) = 1234);
select pg_temp.ok3('several tax lines add up',
  public.stripe_invoice_tax_p(
    '{"total_taxes":[{"amount":100},{"amount":250}]}'::jsonb) = 350);

-- --------------------------------------------------------------------------
-- The silent one: what paid it.
-- --------------------------------------------------------------------------
select public.invoice_from_stripe(
  pg_temp.sinv_dahlia('in_d3','cus_alpha','paid','IN-D003',26900,'pi_dahlia_3'), 'bacs_debit');
select pg_temp.ok3('the PaymentIntent is found in payments.data, where basil moved it',
  (select paid_reference = 'pi_dahlia_3'
     from public.invoices where stripe_invoice_id = 'in_d3'));
select pg_temp.ok3('and NOT the invoice id, which is what 141 would have written',
  (select paid_reference <> 'in_d3' from public.invoices where stripe_invoice_id = 'in_d3'));

-- The whole point: a dispute has to find it.
select public.invoice_disputed('pi_dahlia_3', jsonb_build_object(
  'id','dp_dahlia','reason','debit_not_authorized','amount',26900));
select pg_temp.ok3('a dispute on a dahlia invoice matches and reverses it',
  (select status = 'sent' and disputed_at is not null and dispute_id = 'dp_dahlia'
     from public.invoices where stripe_invoice_id = 'in_d3'));

-- --------------------------------------------------------------------------
-- A paid invoice Stripe tells us nothing about. Null, and said out loud.
-- --------------------------------------------------------------------------
select public.invoice_from_stripe(
  pg_temp.sinv_dahlia('in_d4','cus_alpha','paid','IN-D004',26900, null), 'bacs_debit');
select pg_temp.ok3('no payment reference anywhere gives null, not the invoice id',
  (select paid_reference is null from public.invoices where stripe_invoice_id = 'in_d4'));
select pg_temp.ok3('and the audit trail says so, so the hole is findable',
  exists (select 1 from public.admin_audit
           where action = 'invoice_from_stripe'
             and detail->>'number' = 'IN-D004'
             and (detail->>'no_payment_reference')::boolean));
select pg_temp.ok3('a helper given nothing returns null rather than inventing something',
  public.stripe_invoice_payment_ref('{}'::jsonb) is null);

-- --------------------------------------------------------------------------
-- And the old shape still works, because 141's suite is not being replaced.
-- --------------------------------------------------------------------------
select public.invoice_from_stripe(
  pg_temp.sinv('in_old','cus_alpha','paid','IN-OLD1',16900,1,16900), 'bacs_debit');
select pg_temp.ok3('a pre-basil invoice still records its PaymentIntent',
  (select paid_reference = 'pi_in_old'
     from public.invoices where stripe_invoice_id = 'in_old'));

select 'api version assertions passed' as result;
