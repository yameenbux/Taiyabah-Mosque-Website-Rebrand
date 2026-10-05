-- Behaviour tests for 142 — a reversed Direct Debit is not paid.
-- Run after the 141 suite's fixtures, against the local fixture only.
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function pg_temp.ok2(p_label text, p_cond boolean) returns void
language plpgsql as $$
begin
  if not p_cond then raise exception 'FAIL: %', p_label; end if;
  raise notice 'pass  %', p_label;
end $$;

create or replace function pg_temp.raises2(p_label text, p_sql text, p_contains text)
returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if position(lower(p_contains) in lower(SQLERRM)) = 0 then
      raise exception 'FAIL: % — raised, but said "%" rather than mentioning "%"',
        p_label, SQLERRM, p_contains;
    end if;
    raise notice 'pass  % (refused: %)', p_label, left(SQLERRM, 70);
    return;
  end;
  raise exception 'FAIL: % — it was allowed, and should not have been', p_label;
end $$;

delete from public._test_session;

-- A paid Stripe invoice to reverse. in_1 was left as 'sent' by the 141 suite's
-- reversal test, so pay it again first.
select public.invoice_from_stripe(
  pg_temp.sinv('in_1','cus_alpha','paid','IN-0001',26900,1,26900), 'bacs_debit');
select pg_temp.ok2('starting from a paid invoice',
  (select status = 'paid' from public.invoices where stripe_invoice_id = 'in_1'));

-- The dispute.
select public.invoice_disputed('pi_in_1', jsonb_build_object(
  'id','dp_1','reason','debit_not_authorized','amount',26900,'status','lost'));

select pg_temp.ok2('a disputed invoice stops reading as paid',
  (select status = 'sent' and paid_on is null and paid_amount_p is null
      and paid_method is null
     from public.invoices where stripe_invoice_id = 'in_1'));

select pg_temp.ok2('it is outstanding again, not voided — the masjid still owes the period',
  (select status = 'sent' from public.invoices where stripe_invoice_id = 'in_1'));

select pg_temp.ok2('the fact of the reversal is kept, so it reads differently from never paid',
  (select disputed_at is not null and dispute_id = 'dp_1'
      and dispute_reason = 'debit_not_authorized'
     from public.invoices where stripe_invoice_id = 'in_1'));

select pg_temp.ok2('the payment reference survives, so the charge can still be traced',
  (select paid_reference = 'pi_in_1' from public.invoices where stripe_invoice_id = 'in_1'));

select pg_temp.ok2('the masjid can see the reversal in its own audit trail',
  exists (select 1 from public.admin_audit
           where action = 'direct_debit_reversed'
             and detail->>'invoice' = 'IN-0001'));

select pg_temp.raises2('a dispute matching no invoice raises rather than vanishing',
  $$select public.invoice_disputed('pi_nothing', '{"id":"dp_x"}'::jsonb)$$,
  'matches nothing');

select pg_temp.raises2('a dispute with no payment reference is refused',
  $$select public.invoice_disputed('', '{"id":"dp_y"}'::jsonb)$$,
  'has to name the payment');

-- A later delivery of invoice.paid must not quietly undo the dispute by
-- itself: Stripe's invoice may well still say paid.
select public.invoice_from_stripe(
  pg_temp.sinv('in_1','cus_alpha','paid','IN-0001',26900,1,26900), 'bacs_debit');
select pg_temp.ok2('a repeat of Stripe''s paid event leaves the dispute recorded',
  (select disputed_at is not null and dispute_id = 'dp_1'
     from public.invoices where stripe_invoice_id = 'in_1'));

select pg_temp.ok2('one dispute id cannot be recorded against two invoices',
  (select count(*) from public.invoices where dispute_id = 'dp_1') = 1);

-- Who may do it.
--
-- A SIGNED-IN NON-ADMIN, which needs both halves set up: the platform_admins
-- row removed AND a session, because auth.uid() being null is the service
-- role the webhook uses and is deliberately allowed. The first version of this
-- test only did the second half, left the admin row in place from the 141
-- suite, and therefore asserted that a platform admin is refused — which they
-- are not, and should not be.
delete from public.platform_admins;
insert into public._test_session (uid, aal2) values
  ('11111111-1111-1111-1111-111111111111', true);
select pg_temp.ok2('the caller really is not a platform admin now',
  not public.is_platform_admin());
select pg_temp.raises2('somebody who is not MasjidOne may not record a dispute',
  $$select public.invoice_disputed('pi_in_1', '{"id":"dp_z"}'::jsonb)$$,
  'only masjidone');
delete from public._test_session;

select 'dispute assertions passed' as result;
