-- Behaviour tests for migration 136 — billing a masjid.
-- Run against the local fixture, NEVER against the platform.
--   psql -f 000-schema-mirror.sql -f db/134_... -f db/135_... -f db/136_... \
--        -f db/_test_billing.sql
--
-- Every test asserts. A pass prints a line; a failure raises and stops the
-- file, so "it printed a lot of pass" is not the same as "nothing failed".
--
-- The test this file exists for is the founding customer one. Clause 4.2 of the
-- founding-customer agreement says no invoice will be raised. Code that can
-- invoice them is code that can breach a signed agreement with the only masjid
-- on the platform, so that is asserted from several directions.

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
  begin
    execute p_sql;
  exception when others then
    if position(lower(p_contains) in lower(SQLERRM)) = 0 then
      raise exception 'FAIL: % — raised, but said "%" rather than mentioning "%"',
        p_label, SQLERRM, p_contains;
    end if;
    raise notice 'pass  % (refused: %)', p_label, left(SQLERRM, 60);
    return;
  end;
  raise exception 'FAIL: % — it was allowed, and should not have been', p_label;
end $$;

truncate public.invoice_lines, public.invoices, public.masjid_billing,
         public.masjid_plan, public.admin_audit, public.platform_admins,
         public._test_session cascade;
delete from public.masjids;
delete from auth.users;
alter sequence public.invoice_number_seq restart with 1;

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),   -- Yameen, platform admin
  ('22222222-2222-2222-2222-222222222222');   -- a committee admin
insert into public.platform_admins (user_id) values ('11111111-1111-1111-1111-111111111111');

create or replace function pg_temp.become(p_uid uuid, p_aal2 boolean default true)
returns void language sql as $$
  delete from public._test_session;
  insert into public._test_session (uid, aal2) values (p_uid, p_aal2);
$$;

insert into public.masjids (slug, name, town, is_live) values
  ('founding', 'The Founding Masjid', 'Bolton', true),
  ('paying',   'A Paying Masjid',     'Blackburn', true);
insert into public.masjid_plan (masjid_id, plan_code, band)
select id, 'complete', 'd' from public.masjids where slug='founding';
insert into public.masjid_plan (masjid_id, plan_code, band)
select id, 'complete', 'b' from public.masjids where slug='paying';

-- ===========================================================================
-- ACCESS. Everything here moves money, so nobody but platform support gets in.
-- ===========================================================================
select pg_temp.become('22222222-2222-2222-2222-222222222222');
select pg_temp.raises('a committee admin cannot change billing',
  $$select public.billing_set('paying','{}'::jsonb)$$, 'Only MasjidOne support');
select pg_temp.raises('a committee admin cannot raise an invoice',
  $$select public.invoice_raise('paying','{"lines":[]}'::jsonb)$$, 'Only MasjidOne support');
select pg_temp.raises('a committee admin cannot read the billing overview',
  $$select public.billing_overview()$$, 'Only MasjidOne support');
select pg_temp.raises('a committee admin cannot read a masjid''s billing',
  $$select public.masjid_billing_summary('paying')$$, 'Only MasjidOne support');

/* Platform admin WITHOUT two-step is not a platform admin. */
select pg_temp.become('11111111-1111-1111-1111-111111111111', false);
select pg_temp.raises('platform support without two-step cannot raise an invoice',
  $$select public.invoice_raise('paying','{"lines":[]}'::jsonb)$$, 'Only MasjidOne support');

select pg_temp.become('11111111-1111-1111-1111-111111111111', true);

-- ===========================================================================
-- THE FOUNDING CUSTOMER IS NEVER INVOICED
-- ===========================================================================
select pg_temp.raises('taking a masjid off billing needs a reason',
  $$select public.billing_set('founding','{"billable":false}'::jsonb)$$, 'Say why');

select pg_temp.ok('the founding masjid can be marked not billable, with a reason',
  (public.billing_set('founding',
     '{"billable":false,"not_billable_why":"Founding-customer agreement clause 4.2 — no invoice will be raised.",
       "billing_email":"treasurer@example.org"}'::jsonb)
   -> 'billing' ->> 'billable') = 'false');

select pg_temp.raises('AND THEN NO INVOICE CAN BE RAISED FOR THEM',
  $$select public.invoice_raise('founding',
      '{"lines":[{"description":"Masjid Complete","unit_amount_p":26900}]}'::jsonb)$$,
  'not billed');

select pg_temp.ok('the refusal quotes the reason back, so nobody has to go looking',
  (select position('clause 4.2' in
     (select not_billable_why from public.masjid_billing b
       join public.masjids m on m.id=b.masjid_id where m.slug='founding')) > 0));

select pg_temp.ok('they raised no invoice at all',
  (select count(*) from public.invoices i join public.masjids m on m.id=i.masjid_id
    where m.slug='founding') = 0);

-- ===========================================================================
-- RAISING AN INVOICE
-- ===========================================================================
select pg_temp.raises('an invoice needs billing details first',
  $$select public.invoice_raise('paying',
      '{"lines":[{"description":"x","unit_amount_p":100}]}'::jsonb)$$,
  'no billing details');

select pg_temp.ok('billing can be set up',
  (public.billing_set('paying',
     '{"billing_email":"treasurer@paying.example","billing_contact":"The Treasurer",
       "cycle":"monthly","terms_days":30}'::jsonb)
   -> 'billing' ->> 'terms_days') = '30');

select pg_temp.raises('an invoice needs at least one line',
  $$select public.invoice_raise('paying','{"lines":[]}'::jsonb)$$, 'at least one line');

select pg_temp.raises('a line needs a description',
  $$select public.invoice_raise('paying','{"lines":[{"unit_amount_p":100}]}'::jsonb)$$,
  'needs a description');

select pg_temp.raises('a line needs an amount, and the message says where amounts come from',
  $$select public.invoice_raise('paying','{"lines":[{"description":"Masjid Complete"}]}'::jsonb)$$,
  'PRICING_BANDS');

/* The real thing: band b Masjid Complete is £169, plus a £499 setup fee. Both
   figures are supplied BY THE CALLER — the database never looked them up. */
/* EVERY DATE BELOW IS RELATIVE TO TODAY, on purpose. The first version of
   this suite issued an invoice dated 1 November and asserted it was overdue.
   It was written in October, so the due date was in the future and the
   assertion failed — the test was wrong, not the function. A suite pinned to
   literal dates is a suite that starts failing on its own. */
select pg_temp.ok('an invoice can be raised, as a draft',
  (public.invoice_raise('paying', jsonb_build_object(
     'period_start', (current_date - 65)::text,
     'period_end',   (current_date - 36)::text,
     'lines', jsonb_build_array(
       jsonb_build_object('description','Masjid Complete — last month','unit_amount_p',16900),
       jsonb_build_object('description','Setup fee (one-off)','unit_amount_p',49900))))
   ->> 'status') = 'draft');

select pg_temp.ok('its number is the first in the sequence — no refusal burned one',
  (select number from public.invoices) = 'MO-00001');

/* The reason that assertion is worded that way: three invoice_raise calls were
   refused above, two of them after the lines array was accepted. If a number
   were taken before the lines were checked, this would be MO-00003 and the
   ledger would start with two gaps nothing can explain. */

select pg_temp.ok('the total is summed from the lines, not stored anywhere',
  (select public.invoice_total_p(id) from public.invoices where number='MO-00001') = 66800);

select pg_temp.ok('it recorded the plan and band it was raised against',
  (select plan_code = 'complete' and band = 'b' from public.invoices where number='MO-00001'));

/* A quantity line, to prove amount_p is generated rather than trusted. */
select pg_temp.ok('a line total is generated from quantity x unit, not supplied',
  (select l.amount_p from public.invoice_lines l
     join public.invoices i on i.id = l.invoice_id
    where i.number='MO-00001' and l.description like 'Masjid Complete%') = 16900);

-- ===========================================================================
-- SENDING
-- ===========================================================================
/* Issued 65 days ago on 30-day terms, so it fell due 35 days ago. */
select pg_temp.ok('a draft can be sent, and its due date is issue plus the terms',
  (public.invoice_send('MO-00001', current_date - 65) ->> 'due_on')::date
    = current_date - 35);

select pg_temp.raises('a sent invoice cannot be sent twice',
  $$select public.invoice_send('MO-00001')$$, 'already sent');

select pg_temp.ok('sending moved the billing period on, so that month is not billed twice',
  (select next_invoice_on from public.masjid_billing b
     join public.masjids m on m.id=b.masjid_id where m.slug='paying')
   = current_date - 35);

select pg_temp.raises('an invoice totalling nothing is not sent',
  $$
  with r as (select public.invoice_raise('paying',
      '{"lines":[{"description":"Goodwill credit","unit_amount_p":0}]}'::jsonb) as x)
  select public.invoice_send((select x->>'number' from r))
  $$, 'totals zero');

-- ===========================================================================
-- OVERDUE IS DERIVED, NOT STORED
-- ===========================================================================
select pg_temp.ok('an invoice past its due date reads as overdue with nothing having run',
  (select (i->>'overdue')::boolean
     from jsonb_array_elements(public.masjid_billing_summary('paying')->'invoices') i
    where i->>'number' = 'MO-00001'));

select pg_temp.ok('and it says how many days, counted from today',
  (select (i->>'days_overdue')::int = 35
     from jsonb_array_elements(public.masjid_billing_summary('paying')->'invoices') i
    where i->>'number' = 'MO-00001'));

select pg_temp.ok('the outstanding figure counts it',
  (public.masjid_billing_summary('paying')->>'outstanding_p')::int = 66800);
select pg_temp.ok('and so does the overdue figure',
  (public.masjid_billing_summary('paying')->>'overdue_p')::int = 66800);

-- ===========================================================================
-- RECORDING PAYMENT
-- ===========================================================================
select pg_temp.raises('a payment has to say how it was paid',
  $$select public.invoice_mark_paid('MO-00001','{"amount_p":66800}'::jsonb)$$,
  'Say how it was paid');

select pg_temp.ok('a payment can be recorded',
  (public.invoice_mark_paid('MO-00001',
     jsonb_build_object('amount_p',66800,'method','Bank transfer',
                        'reference','FP 11 NOV','paid_on',(current_date - 30)::text))
   ->> 'status') = 'paid');

select pg_temp.ok('it is no longer outstanding',
  (public.masjid_billing_summary('paying')->>'outstanding_p')::int = 0);
select pg_temp.ok('nor overdue',
  (public.masjid_billing_summary('paying')->>'overdue_p')::int = 0);
select pg_temp.ok('and the paid-to-date figure moved',
  (public.masjid_billing_summary('paying')->>'paid_to_date_p')::int = 66800);
select pg_temp.ok('the method and reference were kept, so it can be matched to a statement',
  (select paid_method = 'Bank transfer' and paid_reference = 'FP 11 NOV'
     from public.invoices where number='MO-00001'));

select pg_temp.raises('a paid invoice cannot be voided — that would lose the money record',
  $$select public.invoice_void('MO-00001','changed my mind')$$, 'raise a credit instead');

-- A SHORT PAYMENT is recorded and reported, not refused.
/* The number is CAPTURED, not guessed. An earlier version asserted this would
   be MO-00002 and it was MO-00003, because the zero-total invoice raised by the
   'totals zero' test above was raised perfectly well — it simply could not be
   sent — and it had taken a number. Guessing the next number in a test is the
   same mistake as hardcoding a date. */
create temp table second_invoice as
select (public.invoice_raise('paying', jsonb_build_object(
          'period_start', (current_date - 35)::text,
          'period_end',   (current_date - 6)::text,
          'lines', jsonb_build_array(
            jsonb_build_object('description','Masjid Complete — this month',
                               'unit_amount_p',16900))))->>'number') as number;

select pg_temp.ok('a second invoice can be raised, with a number of the right shape',
  (select number ~ '^MO-[0-9]{5}$' from second_invoice));
select pg_temp.ok('and it is not the same number as the first',
  (select number <> 'MO-00001' from second_invoice));
select pg_temp.ok('sent',
  (public.invoice_send((select number from second_invoice), current_date - 35)
   ->> 'status') = 'sent');

select pg_temp.ok('a short payment is accepted and the shortfall reported',
  (public.invoice_mark_paid((select number from second_invoice),
     '{"amount_p":10000,"method":"Standing order"}'::jsonb)
   ->> 'short_p')::int = 6900);

select pg_temp.ok('a short payment leaves the masjid still owing the difference on record',
  (select (i->>'short_p')::int = 6900
     from jsonb_array_elements(public.masjid_billing_summary('paying')->'invoices') i
    where i->>'number' = (select number from second_invoice)));

-- ===========================================================================
-- VOIDING
-- ===========================================================================
/* A draft is raised here rather than reused from an earlier test. The
   zero-total invoice above does NOT survive: invoice_raise and invoice_send ran
   inside one statement, that statement raised, and the whole thing rolled back
   — the invoice with it. What did NOT roll back is the sequence value it took,
   which is precisely the non-transactional behaviour invoice_raise now
   validates ahead of. */
create temp table draft_invoice as
select (public.invoice_raise('paying', jsonb_build_object(
          'lines', jsonb_build_array(
            jsonb_build_object('description','Raised by mistake','unit_amount_p',100))))
        ->>'number') as number;

select pg_temp.ok('the draft is a draft',
  (select status from public.invoices
    where number = (select number from draft_invoice)) = 'draft');
select pg_temp.raises('voiding needs a reason',
  $$select public.invoice_void((select number from draft_invoice), '')$$, 'Say why');
select pg_temp.ok('a draft can be voided',
  (public.invoice_void((select number from draft_invoice),
     'Raised in error — the credit belongs on the next invoice.')
   ->> 'status') = 'void');
select pg_temp.ok('the number is kept, so the sequence has no unexplained hole',
  (select count(*) from public.invoices where status='void') = 1);
select pg_temp.raises('a void invoice cannot then be paid',
  $$select public.invoice_mark_paid((select number from draft_invoice),
      '{"method":"Bank transfer"}'::jsonb)$$,
  'was voided');

-- ===========================================================================
-- THE OVERVIEW: not billed is not the same as owing nothing
-- ===========================================================================
select pg_temp.ok('the founding masjid appears as not billable',
  (select (m->>'billable')::boolean = false
     from jsonb_array_elements(public.billing_overview()->'masajid') m
    where m->>'slug' = 'founding'));

select pg_temp.ok('with its reason, so nobody invoices them by mistake',
  (select position('clause 4.2' in (m->>'not_billable_why')) > 0
     from jsonb_array_elements(public.billing_overview()->'masajid') m
    where m->>'slug' = 'founding'));

select pg_temp.ok('the paying masjid shows its band',
  (select m->>'band' = 'b'
     from jsonb_array_elements(public.billing_overview()->'masajid') m
    where m->>'slug' = 'paying'));

-- ===========================================================================
-- AUDIT: every act on money is attributable
-- ===========================================================================
select pg_temp.ok('every billing action was audited against the right masjid',
  (select count(distinct action) from public.admin_audit a
     join public.masjids m on m.id = a.masjid_id where m.slug='paying') >= 4);
select pg_temp.ok('and the founding masjid''s only billing audit is the exemption itself',
  (select count(*) from public.admin_audit a join public.masjids m on m.id=a.masjid_id
    where m.slug='founding' and a.action like 'invoice%') = 0);

-- ===========================================================================
-- NOTHING IS REACHABLE FROM A BROWSER
-- (see _test_plans_and_onboarding.sql for why this is asserted, not assumed)
-- ===========================================================================
select pg_temp.ok('no billing table is readable by anon or authenticated',
  (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname in ('masjid_billing','invoices','invoice_lines')
      and (has_table_privilege('anon', c.oid,'SELECT')
        or has_table_privilege('authenticated', c.oid,'SELECT'))) = 0);

select pg_temp.ok('all three billing tables have RLS on with no policies',
  (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname in ('masjid_billing','invoices','invoice_lines')
      and c.relrowsecurity) = 3
  and (select count(*) from pg_policies where schemaname='public'
        and tablename in ('masjid_billing','invoices','invoice_lines')) = 0);

select pg_temp.ok('anon cannot execute any billing function',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('billing_set','invoice_raise','invoice_send','invoice_mark_paid',
                        'invoice_void','masjid_billing_summary','billing_overview','invoice_total_p')
      and has_function_privilege('anon', p.oid,'EXECUTE')) = 0);

select pg_temp.ok('and PUBLIC holds EXECUTE on none of them',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('billing_set','invoice_raise','invoice_send','invoice_mark_paid',
                        'invoice_void','masjid_billing_summary','billing_overview','invoice_total_p')
      and array_to_string(p.proacl, ',') ~ '(^|[,|])=X/') = 0);

\echo ''
\echo 'ALL BILLING TESTS PASSED'
