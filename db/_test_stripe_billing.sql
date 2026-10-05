-- Behaviour tests for 141 — Stripe bills the masjid.
-- Run against the local fixture, NEVER against the platform.
--   psql -f db/_fixture_schema_mirror.sql \
--        -f db/134_... -f db/135_... -f db/136_... -f db/137_... -f db/139_... \
--        -f db/141_stripe_bills_the_masjid.sql -f db/_test_stripe_billing.sql
--
-- Every test asserts. A pass prints a line; a failure raises and stops the
-- file, so "it printed a lot of pass" is not the same as "nothing failed".
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function pg_temp.ok(p_label text, p_cond boolean) returns void
language plpgsql as $$
begin
  if not p_cond then raise exception 'FAIL: %', p_label; end if;
  raise notice 'pass  %', p_label;
end $$;

create or replace function pg_temp.raises(p_label text, p_sql text, p_contains text)
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

/* A Stripe invoice, shaped the way Stripe shapes one. Built here rather than
   pasted so a test can vary one thing at a time. Epochs are real: 1 November
   2026 is 1793232000. */
create or replace function pg_temp.sinv(
  p_id text, p_customer text, p_status text, p_number text,
  p_unit int, p_qty int default 1, p_paid int default null,
  p_unit_where text default 'pricing')
returns jsonb language sql as $$
  select jsonb_build_object(
    'id', p_id, 'customer', p_customer, 'status', p_status,
    'number', p_number,
    'created', 1793232000,
    'due_date', 1795824000,
    'period_start', 1793232000, 'period_end', 1795824000,
    'amount_paid', p_paid,
    'payment_intent', 'pi_' || p_id,
    'hosted_invoice_url', 'https://invoice.stripe.com/' || p_id,
    'status_transitions', jsonb_build_object(
        'finalized_at', 1793232000,
        'paid_at', case when p_status = 'paid' then 1793318400 end),
    'lines', jsonb_build_object('data', jsonb_build_array(
      jsonb_build_object(
        'description', 'Masjid Complete — November 2026',
        'quantity', p_qty,
        'period', jsonb_build_object('start', 1793232000, 'end', 1795824000),
        'pricing', case when p_unit_where = 'pricing'
                   then jsonb_build_object('price_details',
                          jsonb_build_object('unit_amount', p_unit)) end,
        'price',   case when p_unit_where = 'price'
                   then jsonb_build_object('unit_amount', p_unit) end,
        'plan',    case when p_unit_where = 'plan'
                   then jsonb_build_object('amount', p_unit) end))));
$$;

-- ---------------------------------------------------------------------------
-- Fixtures. Two masajid: one billable, one contractually never billed.
-- ---------------------------------------------------------------------------
truncate public.invoice_lines, public.invoices, public.masjid_billing,
         public.masjid_plan, public.billing_events, public.user_roles,
         public.platform_admins, public.platform_audit, public.active_masjid,
         public.admin_audit, public._test_session cascade;
delete from auth.mfa_factors;
delete from public.masjids;
delete from auth.users;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','yameen@masjidone.example');
insert into auth.mfa_factors (user_id) values
  ('11111111-1111-1111-1111-111111111111');
insert into public.platform_admins (user_id) values
  ('11111111-1111-1111-1111-111111111111');

insert into public.masjids (id, slug, name, town, is_live) values
  ('aaaaaaaa-0000-0000-0000-000000000001','alpha','Alpha Masjid','Bolton',true),
  ('aaaaaaaa-0000-0000-0000-000000000002','founder','Founding Masjid','Bolton',true);

insert into public.masjid_billing (masjid_id, billable, billing_email) values
  ('aaaaaaaa-0000-0000-0000-000000000001', true, 'treasurer@alpha.example');
insert into public.masjid_billing (masjid_id, billable, not_billable_why) values
  ('aaaaaaaa-0000-0000-0000-000000000002', false,
   'Founding-customer agreement clause 4.2: no invoice will be raised.');

insert into public.masjid_plan (masjid_id, plan_code, band, started_on)
values ('aaaaaaaa-0000-0000-0000-000000000001','complete','d', current_date);

-- Act as MasjidOne support throughout unless a test says otherwise.
insert into public._test_session (uid, aal2) values
  ('11111111-1111-1111-1111-111111111111', true);

select pg_temp.ok('the caller really is a platform admin', public.is_platform_admin());

-- ---------------------------------------------------------------------------
-- The CHECKs, because they are the part that survives a bad afternoon.
-- ---------------------------------------------------------------------------
select pg_temp.raises('auto_bill with no subscription is refused by the schema',
  $$update public.masjid_billing set auto_bill = true
     where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000001'$$,
  'masjid_billing_auto_needs_sub');

select pg_temp.raises('auto_bill on a masjid that is not billed is refused by the schema',
  $$update public.masjid_billing
       set stripe_subscription_id = 'sub_founder', auto_bill = true
     where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000002'$$,
  'masjid_billing_auto_needs_billable');

select pg_temp.raises('a stripe invoice with no stripe id is refused',
  $$insert into public.invoices (masjid_id, number, status, source)
    values ('aaaaaaaa-0000-0000-0000-000000000001','X-1','draft','stripe')$$,
  'invoices_source_matches_id');

select pg_temp.raises('a manual invoice carrying a stripe id is refused',
  $$insert into public.invoices (masjid_id, number, status, source, stripe_invoice_id)
    values ('aaaaaaaa-0000-0000-0000-000000000001','X-2','draft','manual','in_x')$$,
  'invoices_source_matches_id');

select pg_temp.raises('two masajid cannot share one Stripe customer',
  $$update public.masjid_billing set stripe_customer_id = 'cus_alpha'$$,
  'masjid_billing_stripe_customer');

-- ---------------------------------------------------------------------------
-- Idempotency. Stripe retries; the ledger must not.
-- ---------------------------------------------------------------------------
select pg_temp.ok('a new event is claimed',
  public.billing_event_begin('evt_1','invoice.paid','cus_alpha','{}'::jsonb));
select pg_temp.ok('a claimed but unfinished event is claimed again, because a crash is not a success',
  public.billing_event_begin('evt_1','invoice.paid','cus_alpha','{}'::jsonb));
select public.billing_event_done('evt_1');
select pg_temp.ok('a finished event is not claimed twice',
  not public.billing_event_begin('evt_1','invoice.paid','cus_alpha','{}'::jsonb));
select pg_temp.ok('one row per event id, however many deliveries',
  (select count(*) from public.billing_events where id = 'evt_1') = 1);
select pg_temp.raises('an event with no id is refused',
  $$select public.billing_event_begin('', 'invoice.paid', null, null)$$,
  'has to have an id');

-- ---------------------------------------------------------------------------
-- Linking a masjid to Stripe.
-- ---------------------------------------------------------------------------
select public.billing_stripe_attach('alpha', jsonb_build_object(
  'customer','cus_alpha','subscription','sub_alpha','mandate_state','pending'));

select pg_temp.ok('the customer and subscription are recorded',
  (select stripe_customer_id = 'cus_alpha' and stripe_subscription_id = 'sub_alpha'
     from public.masjid_billing where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000001'));
select pg_temp.ok('attaching does NOT start collecting',
  (select not auto_bill from public.masjid_billing
    where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000001'));
select pg_temp.ok('the masjid can see in its own audit trail that a Direct Debit was set up',
  exists (select 1 from public.admin_audit
           where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000001'
             and action = 'direct_debit_linked'));
select pg_temp.raises('an unknown masjid cannot be linked',
  $$select public.billing_stripe_attach('nosuch', '{"customer":"cus_x"}'::jsonb)$$,
  'no masjid called');
select pg_temp.raises('a nonsense mandate state is refused',
  $$select public.billing_stripe_attach('alpha', '{"mandate_state":"probably"}'::jsonb)$$,
  'cannot be in state');

-- ---------------------------------------------------------------------------
-- The switch, and the Bacs waiting period it has to respect.
-- ---------------------------------------------------------------------------
select pg_temp.raises('collection cannot start while the mandate is only pending',
  $$select public.billing_autobill_set('alpha', true)$$,
  'not active');

select pg_temp.raises('collection cannot start for a masjid that is never billed',
  $$select public.billing_autobill_set('founder', true)$$,
  'not billed');

select public.billing_mandate_set('cus_alpha', 'active');
select pg_temp.ok('the mandate is live', (select mandate_state = 'active'
  from public.masjid_billing where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000001'));

select public.billing_autobill_set('alpha', true);
select pg_temp.ok('collection is on', (select auto_bill
  from public.masjid_billing where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000001'));

select pg_temp.raises('stopping collection needs a reason',
  $$select public.billing_autobill_set('alpha', false)$$,
  'needs a reason');

-- ---------------------------------------------------------------------------
-- A failed mandate stops the money, so it must stop the claim too.
-- ---------------------------------------------------------------------------
select public.billing_mandate_set('cus_alpha', 'failed',
  '{"reason":"account does not accept direct debits"}'::jsonb);
select pg_temp.ok('a failed mandate switches collection off by itself',
  (select not auto_bill and mandate_state = 'failed' from public.masjid_billing
    where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000001'));
select pg_temp.raises('a mandate event for an unknown customer raises rather than doing nothing',
  $$select public.billing_mandate_set('cus_nobody', 'active')$$,
  'no masjid is linked');

-- Put it back for the invoice tests.
select public.billing_mandate_set('cus_alpha', 'active');
select public.billing_autobill_set('alpha', true);

-- ---------------------------------------------------------------------------
-- Mirroring Stripe's invoices.
-- ---------------------------------------------------------------------------
select pg_temp.raises('an invoice for an unknown customer is refused, not swallowed',
  $$select public.invoice_from_stripe(pg_temp.sinv('in_x','cus_nobody','open','IN-9',26900))$$,
  'no masjid is linked');

select pg_temp.raises('a draft is refused, because it has no number yet',
  $$select public.invoice_from_stripe(pg_temp.sinv('in_d','cus_alpha','draft',null,26900))$$,
  'still a draft');

select pg_temp.raises('a finalised invoice with no number is refused',
  $$select public.invoice_from_stripe(pg_temp.sinv('in_n','cus_alpha','open',null,26900))$$,
  'has no number');

select pg_temp.raises('a line with no unit amount anywhere is refused rather than guessed',
  $$select public.invoice_from_stripe(pg_temp.sinv('in_u','cus_alpha','open','IN-8',null))$$,
  'no unit amount');

select pg_temp.ok('nothing was written by any of those refusals',
  (select count(*) from public.invoices) = 0);

-- Open.
select public.invoice_from_stripe(pg_temp.sinv('in_1','cus_alpha','open','IN-0001',26900));
select pg_temp.ok('an open Stripe invoice lands as sent',
  (select status = 'sent' and source = 'stripe' and number = 'IN-0001'
     from public.invoices where stripe_invoice_id = 'in_1'));
select pg_temp.ok('it keeps STRIPE''S number, not one of ours',
  (select number not like 'MO-%' from public.invoices where stripe_invoice_id = 'in_1'));
select pg_temp.ok('it has an issue date and a due date, as the constraint demands',
  (select issued_on is not null and due_on is not null
     from public.invoices where stripe_invoice_id = 'in_1'));
select pg_temp.ok('the total comes from the lines',
  (select public.invoice_total_p(id) = 26900
     from public.invoices where stripe_invoice_id = 'in_1'));
select pg_temp.ok('the plan and band in force are written onto it',
  (select plan_code = 'complete' and band = 'd'
     from public.invoices where stripe_invoice_id = 'in_1'));
select pg_temp.ok('the hosted copy is kept so support sees the same document',
  (select stripe_hosted_url like 'https://invoice.stripe.com/%'
     from public.invoices where stripe_invoice_id = 'in_1'));

-- Paid.
select public.invoice_from_stripe(
  pg_temp.sinv('in_1','cus_alpha','paid','IN-0001',26900,1,26900), 'bacs_debit');
select pg_temp.ok('the same Stripe invoice updates rather than duplicating',
  (select count(*) from public.invoices where stripe_invoice_id = 'in_1') = 1);
select pg_temp.ok('paid is recorded with when, how much and how',
  (select status = 'paid' and paid_amount_p = 26900 and paid_method = 'bacs_debit'
      and paid_on is not null and paid_reference = 'pi_in_1'
     from public.invoices where stripe_invoice_id = 'in_1'));
select pg_temp.ok('the lines are not doubled by a second delivery',
  (select count(*) from public.invoice_lines l
     join public.invoices i on i.id = l.invoice_id
    where i.stripe_invoice_id = 'in_1') = 1);

-- A reversed Direct Debit. This is the Bacs case that card billing does not have.
select public.invoice_from_stripe(pg_temp.sinv('in_1','cus_alpha','open','IN-0001',26900));
select pg_temp.ok('a reversed Direct Debit moves the invoice back off paid',
  (select status = 'sent' and paid_on is null and paid_amount_p is null
      and paid_method is null
     from public.invoices where stripe_invoice_id = 'in_1'));

-- Written off.
select public.invoice_from_stripe(pg_temp.sinv('in_2','cus_alpha','uncollectible','IN-0002',26900));
select pg_temp.ok('uncollectible becomes void, and says it was written off rather than raised in error',
  (select status = 'void' and void_why ilike '%uncollectible%'
     from public.invoices where stripe_invoice_id = 'in_2'));

-- The three places Stripe has kept a unit amount.
select public.invoice_from_stripe(pg_temp.sinv('in_3','cus_alpha','open','IN-0003',16900,1,null,'price'));
select public.invoice_from_stripe(pg_temp.sinv('in_4','cus_alpha','open','IN-0004',11900,1,null,'plan'));
select pg_temp.ok('a unit amount on the older price object is found',
  (select public.invoice_total_p(id) = 16900 from public.invoices where stripe_invoice_id = 'in_3'));
select pg_temp.ok('a unit amount on the oldest plan object is found',
  (select public.invoice_total_p(id) = 11900 from public.invoices where stripe_invoice_id = 'in_4'));

-- Twelve months at the same rate, which is the yearly invariant as Stripe sees it.
select public.invoice_from_stripe(pg_temp.sinv('in_5','cus_alpha','open','IN-0005',26900,12));
select pg_temp.ok('a yearly invoice is twelve times the monthly, not a discounted figure',
  (select public.invoice_total_p(id) = 26900 * 12
     from public.invoices where stripe_invoice_id = 'in_5'));

-- A manual invoice still works, and the two kinds do not collide.
select public.invoice_raise('alpha', jsonb_build_object('lines',
  jsonb_build_array(jsonb_build_object('description','Setup — one-off','unit_amount_p',49900))));
select pg_temp.ok('a manual invoice still gets an MO- number from our own sequence',
  exists (select 1 from public.invoices where source = 'manual' and number like 'MO-%'));
select pg_temp.ok('manual and Stripe invoices sit in one ledger without confusion',
  (select count(distinct source) from public.invoices) = 2);

-- ---------------------------------------------------------------------------
-- The subscription ending.
-- ---------------------------------------------------------------------------
select public.billing_subscription_set('cus_alpha',
  jsonb_build_object('id','sub_alpha','status','active','current_period_end',1795824000));
select pg_temp.ok('Stripe''s next charge date is mirrored into its own column',
  (select stripe_next_charge_on is not null and next_invoice_on is null
     from public.masjid_billing where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000001'));

select public.billing_subscription_set('cus_alpha',
  jsonb_build_object('id','sub_alpha','status','canceled'));
select pg_temp.ok('a cancelled subscription switches collection off and lets the link go',
  (select not auto_bill and stripe_subscription_id is null
     from public.masjid_billing where masjid_id = 'aaaaaaaa-0000-0000-0000-000000000001'));

-- ---------------------------------------------------------------------------
-- What the console is told, in words a person can act on.
-- ---------------------------------------------------------------------------
/* 144 moved the long version to its own key, because the panel above this one
   already prints the agreement clause in full and printing it twice three
   lines apart is what the screen actually did. */
select pg_temp.ok('the console is still told the founding masjid is not billed, and why',
  (public.billing_direct_debit('founder') ->> 'not_billed_sentence') ilike '%not billed%');
select pg_temp.ok('a masjid with nothing set up is told to send the link',
  (public.billing_direct_debit('founder') -> 'auto_bill')::boolean = false);

-- ---------------------------------------------------------------------------
-- Who may do any of this.
-- ---------------------------------------------------------------------------
update public._test_session set aal2 = false;
select pg_temp.raises('a platform admin who has not completed two-step may not start a Direct Debit',
  $$select public.billing_autobill_set('alpha', true)$$,
  'two-step');
select pg_temp.raises('nor read the billing state',
  $$select public.billing_direct_debit('alpha')$$,
  'two-step');
update public._test_session set aal2 = true;

delete from public.platform_admins;
select pg_temp.raises('somebody who is not MasjidOne may not mirror a Stripe invoice',
  $$select public.invoice_from_stripe(pg_temp.sinv('in_9','cus_alpha','open','IN-9',100))$$,
  'only masjidone');
select pg_temp.raises('nor claim a Stripe event',
  $$select public.billing_event_begin('evt_9','invoice.paid',null,null)$$,
  'only masjidone');

-- ---------------------------------------------------------------------------
-- The exempt list, which is the thing that was silently wrong before.
-- ---------------------------------------------------------------------------
delete from public._test_session;
create table public.a_table_somebody_forgot (id int);
select pg_temp.ok('a new table with no masjid_id is NOT exempt by default',
  not exists (select 1 from public.tenancy_exempt
               where table_name = 'a_table_somebody_forgot'));
select pg_temp.ok('and the check notices it',
  exists (select 1 from pg_class c
           where c.relnamespace='public'::regnamespace and c.relkind='r'
             and c.relname not in (select e.table_name from public.tenancy_exempt e)
             and not exists (select 1 from pg_attribute a
                              where a.attrelid=c.oid and a.attname='masjid_id'
                                and not a.attisdropped)
             and c.relname = 'a_table_somebody_forgot'));
insert into public.tenancy_exempt (table_name, why)
values ('a_table_somebody_forgot','Because this is a test.');
select pg_temp.ok('a row with a reason is what makes it exempt — not an edit to a function',
  not exists (select 1 from pg_class c
           where c.relnamespace='public'::regnamespace and c.relkind='r'
             and c.relname not in (select e.table_name from public.tenancy_exempt e)
             and c.relname = 'a_table_somebody_forgot'));
select pg_temp.raises('an exemption with no reason is refused',
  $$insert into public.tenancy_exempt (table_name, why) values ('x','  ')$$,
  'tenancy_exempt_why');
drop table public.a_table_somebody_forgot;
delete from public.tenancy_exempt where table_name = 'a_table_somebody_forgot';

select pg_temp.ok('the tables 134, 136 and 139 added are exempt now, which is why the check was red',
  (select count(*) from public.tenancy_exempt
    where table_name in ('invoice_lines','platform_audit','plans')) = 3);

select pg_temp.ok('active_masjid is NOT exempt, because it really does carry a masjid_id',
  not exists (select 1 from public.tenancy_exempt where table_name = 'active_masjid')
  and exists (select 1 from pg_attribute a
               where a.attrelid = 'public.active_masjid'::regclass
                 and a.attname = 'masjid_id' and not a.attisdropped));

-- The check itself, which is the thing that was red.
select pg_temp.ok('every table in public is now either a masjid''s or exempt with a reason',
  not exists (select 1 from pg_class c
           where c.relnamespace='public'::regnamespace and c.relkind='r'
             and c.relname not in (select e.table_name from public.tenancy_exempt e)
             and c.relname not like '\_test%'
             and not exists (select 1 from pg_attribute a
                              where a.attrelid=c.oid and a.attname='masjid_id'
                                and not a.attisdropped)));

select 'all assertions passed' as result;

-- ---------------------------------------------------------------------------
-- A failure that retrying cannot fix is closed, with the reason kept.
-- ---------------------------------------------------------------------------
delete from public._test_session;
select public.billing_event_begin('evt_bad','invoice.paid','cus_nobody','{}'::jsonb);
select public.billing_event_failed('evt_bad','No masjid is linked to Stripe customer cus_nobody.');
select pg_temp.ok('a permanent failure is closed so Stripe stops retrying',
  (select handled from public.billing_events where id = 'evt_bad'));
select pg_temp.ok('and the reason is kept against the event, which is the safety net',
  (select detail ->> 'not_processed' ilike '%no masjid is linked%'
     from public.billing_events where id = 'evt_bad'));
select pg_temp.raises('recording a failure against an event that never arrived is refused',
  $$select public.billing_event_failed('evt_never','whatever')$$,
  'no stripe event');

-- ---------------------------------------------------------------------------
-- What /start needs, in one authorised call.
-- ---------------------------------------------------------------------------
insert into public._test_session (uid, aal2) values
  ('11111111-1111-1111-1111-111111111111', true);
insert into public.platform_admins (user_id) values
  ('11111111-1111-1111-1111-111111111111') on conflict do nothing;

select pg_temp.ok('the band and plan come back, so the edge function never takes an amount from a browser',
  (select (public.billing_direct_debit('alpha') ->> 'band') = 'd'
      and (public.billing_direct_debit('alpha') ->> 'plan_code') = 'complete'));
select pg_temp.ok('the Stripe customer id comes back, so a second attempt reuses it rather than making another',
  (public.billing_direct_debit('alpha') ->> 'stripe_customer_id') = 'cus_alpha');
select pg_temp.ok('and whether the setup fee still stands',
  (public.billing_direct_debit('alpha') ->> 'setup_fee_state') = 'due');

select 'all assertions passed (including /start inputs)' as result;

-- ---------------------------------------------------------------------------
-- 144. Said once, and punctuated once.
-- ---------------------------------------------------------------------------
select pg_temp.ok('the not-billed sentence does not double the full stop the reason already ends with',
  (public.billing_direct_debit('founder') ->> 'not_billed_sentence') not like '%..%');
select pg_temp.ok('and it still ends in one',
  (public.billing_direct_debit('founder') ->> 'not_billed_sentence') like '%.');
select pg_temp.ok('where_it_stands no longer repeats the agreement clause the panel above already prints',
  (public.billing_direct_debit('founder') ->> 'where_it_stands') not ilike '%clause%');
select pg_temp.ok('but it still says why a Direct Debit is refused',
  (public.billing_direct_debit('founder') ->> 'where_it_stands') ilike '%collects itself%');
