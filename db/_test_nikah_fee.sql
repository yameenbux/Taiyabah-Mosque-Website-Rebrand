-- ===========================================================================
--  _test_nikah_fee.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 018: a nikāḥ fee can be paid online, and paying it does
--  NOT agree the date.
--
--  Run against a FRESHLY BUILT database:  bash /tmp/build_nk.sh t_nk
--
--  The assertion that matters most is 03a: after the money arrives, `status`
--  is exactly what it was before. The masjid does not publish its nikāḥ
--  diary, so the website cannot know whether a date is free; a payment that
--  confirmed a request would be selling a date nobody has checked. Every
--  other assertion here is ordinary care. That one is the design.
-- ===========================================================================
\set ON_ERROR_STOP on

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated;

create or replace function pg_temp.note(l text, cond boolean, d text default '')
returns void language plpgsql as $$
begin
  -- coalesce: a NULL assertion (comparing against a column that turned out
  -- to be NULL) used to display as FAIL but was counted as neither passed
  -- nor failed, so the summary line could read "0 failed" over a broken
  -- suite. NULL is not a pass.
  insert into r values (l, coalesce(cond, false), d);
end $$;

create or replace function pg_temp.efail(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,false,'unexpectedly SUCCEEDED');
exception when others then insert into r values (l,true,left(sqlerrm,70)); end; end $$;

create or replace function pg_temp.eok(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,true,'');
exception when others then insert into r values (l,false,left(sqlerrm,90)); end; end $$;

\o /dev/null

-- A request in each state we care about. Inserted directly rather than through
-- request_nikah_date(), because that function enforces a fortnight's notice
-- and a per-email limit that have nothing to do with what is being tested.
insert into public.nikah_requests
  (reference, preferred_date, slot, contact_name, contact_role,
   contact_phone, contact_email, privacy_accepted, status)
values
  ('NK-26-9001', current_date + 40, 'after_zuhr', 'Test Family One', 'family',
   '07700900801', 'one@example.test', true, 'new'),
  ('NK-26-9002', current_date + 41, 'after_asr', 'Test Family Two', 'family',
   '07700900802', 'two@example.test', true, 'contacted'),
  ('NK-26-9003', current_date + 42, 'after_isha', 'Test Family Three', 'family',
   '07700900803', 'three@example.test', true, 'declined'),
  ('NK-26-9004', current_date + 43, 'after_zuhr', 'Test Family Four', 'family',
   '07700900804', 'four@example.test', true, 'new');


-- ===========================================================================
--  01. STRUCTURE
-- ===========================================================================
select pg_temp.note('a new request owes its fee',
  (select fee_status from public.nikah_requests where reference = 'NK-26-9001') = 'unpaid');

select pg_temp.note('nothing is recorded as paid before anybody pays',
  (select count(*) from public.nikah_requests
    where fee_paid_at is not null or stripe_session_id is not null) = 0);

select pg_temp.efail('a nonsense fee state is refused',
  $$update public.nikah_requests set fee_status = 'sort of paid' where reference = 'NK-26-9001'$$);

select pg_temp.note('the same Stripe session cannot be stored on two requests',
  exists (select 1 from pg_indexes
           where indexname = 'nikah_stripe_session_idx' and indexdef ilike '%unique%'));


-- ===========================================================================
--  02. THE ORDINARY CASE
-- ===========================================================================
select pg_temp.note('paying returns paid',
  (public.mark_nikah_fee_paid('NK-26-9001', 'cs_test_A', 10000) ->> 'fee_status') = 'paid');

select pg_temp.note('the amount that actually arrived is recorded',
  (select fee_amount_p from public.nikah_requests where reference = 'NK-26-9001') = 10000,
  (select fee_amount_p::text from public.nikah_requests where reference = 'NK-26-9001'));

select pg_temp.note('and when it arrived',
  (select fee_paid_at is not null from public.nikah_requests where reference = 'NK-26-9001'));

select pg_temp.note('the payment is written to the audit log',
  exists (select 1 from public.admin_audit
           where action = 'nikah_fee_paid' and detail ->> 'reference' = 'NK-26-9001'));


-- ===========================================================================
--  03. THE ONE THAT MATTERS — PAYING DOES NOT AGREE THE DATE
--
--  If this ever fails, the website is selling nikāḥ dates the imam may not be
--  free for. Do not "fix" it by changing the assertion.
-- ===========================================================================
select pg_temp.note('a new request is STILL new after the fee is paid',
  (select status from public.nikah_requests where reference = 'NK-26-9001') = 'new',
  (select status from public.nikah_requests where reference = 'NK-26-9001'));

select pg_temp.note('a contacted request is still only contacted after paying',
  (select status from public.nikah_requests where reference = 'NK-26-9002') = 'contacted');

select pg_temp.note('paying does not fill in an agreed date',
  (select agreed_date is null from public.nikah_requests where reference = 'NK-26-9001'));

select pg_temp.note('paying does not stamp it as reviewed by anybody',
  (select reviewed_at is null and reviewed_by is null
     from public.nikah_requests where reference = 'NK-26-9001'));


-- ===========================================================================
--  04. STRIPE RETRIES
-- ===========================================================================
select pg_temp.note('the same session arriving twice says so',
  (public.mark_nikah_fee_paid('NK-26-9001', 'cs_test_A', 10000) ->> 'already_recorded') = 'true');

select pg_temp.note('and does not double the amount',
  (select fee_amount_p from public.nikah_requests where reference = 'NK-26-9001') = 10000);

select pg_temp.note('a retry writes no second audit line',
  (select count(*) from public.admin_audit
    where action = 'nikah_fee_paid' and detail ->> 'reference' = 'NK-26-9001') = 1);


-- ===========================================================================
--  05. A SECOND, DIFFERENT PAYMENT
--
--  Two family members both paying, or somebody paying the member rate and
--  then being told they are not a member. Real money twice over; the first
--  record must survive it.
-- ===========================================================================
select pg_temp.note('a second payment is flagged as a duplicate',
  (public.mark_nikah_fee_paid('NK-26-9001', 'cs_test_B', 20000) ->> 'duplicate_payment') = 'true');

select pg_temp.note('the first payment is NOT overwritten',
  (select stripe_session_id from public.nikah_requests where reference = 'NK-26-9001') = 'cs_test_A',
  (select stripe_session_id from public.nikah_requests where reference = 'NK-26-9001'));

select pg_temp.note('and neither is the amount already on file',
  (select fee_amount_p from public.nikah_requests where reference = 'NK-26-9001') = 10000);

select pg_temp.note('the extra payment is audited so somebody refunds it',
  exists (select 1 from public.admin_audit
           where action = 'nikah_fee_paid_twice'
             and detail ->> 'reference' = 'NK-26-9001'
             and detail ->> 'extra_session' = 'cs_test_B'));

select pg_temp.note('the audit names both payments, not just the new one',
  (select detail ->> 'kept_session' from public.admin_audit
    where action = 'nikah_fee_paid_twice'
      and detail ->> 'reference' = 'NK-26-9001') = 'cs_test_A');


-- ===========================================================================
--  06. PAID FOR A DATE THAT WAS REFUSED
-- ===========================================================================
select pg_temp.note('paying against a declined request is marked for refund',
  (public.mark_nikah_fee_paid('NK-26-9003', 'cs_test_C', 20000) ->> 'fee_status') = 'refund_due');

select pg_temp.note('the office sees refund due on the row itself',
  (select fee_status from public.nikah_requests where reference = 'NK-26-9003') = 'refund_due');

select pg_temp.note('paying a declined request does not un-decline it',
  (select status from public.nikah_requests where reference = 'NK-26-9003') = 'declined');

select pg_temp.note('the refund is audited',
  exists (select 1 from public.admin_audit
           where action = 'nikah_fee_needs_refund' and detail ->> 'reference' = 'NK-26-9003'));


-- ===========================================================================
--  07. MONEY FOR A REFERENCE THAT DOES NOT EXIST
-- ===========================================================================
select pg_temp.note('an unknown reference comes back unmatched',
  (public.mark_nikah_fee_paid('NK-26-0000', 'cs_test_D', 10000) ->> 'fee_status') = 'unmatched');

select pg_temp.note('it does NOT raise — a raise would roll back the audit line',
  true);

select pg_temp.note('and the audit line survives, so somebody can refund it',
  exists (select 1 from public.admin_audit
           where action = 'nikah_fee_for_unknown_request'
             and detail ->> 'reference' = 'NK-26-0000'
             and detail ->> 'session' = 'cs_test_D'));

select pg_temp.efail('a missing session id is refused outright',
  $$select public.mark_nikah_fee_paid('NK-26-9004', null, 10000)$$);


-- ===========================================================================
--  08. WHO MAY CALL IT
--
--  The webhook holds the service role key. Nobody else may say money arrived.
-- ===========================================================================
set role anon;
select pg_temp.note('the anon role is subject to RLS',
  not (select rolsuper or rolbypassrls from pg_roles where rolname = current_user),
  'super=' || (select rolsuper from pg_roles where rolname = current_user)::text ||
  ' bypassrls=' || (select rolbypassrls from pg_roles where rolname = current_user)::text);

select pg_temp.efail('the public cannot declare a fee paid',
  $$select public.mark_nikah_fee_paid('NK-26-9004', 'cs_forged', 10000)$$);
reset role;

set role authenticated;
select pg_temp.efail('nor can a signed-in member of staff',
  $$select public.mark_nikah_fee_paid('NK-26-9004', 'cs_forged2', 10000)$$);
reset role;


-- ===========================================================================
--  09. WHAT THE OFFICE MAY AND MAY NOT WRITE
--
--  Most fees will still arrive as cash across the office counter, so the
--  office has to be able to record one. It must not be able to rewrite which
--  Stripe payment a row belongs to, or anything the family typed.
-- ===========================================================================
-- The uid and aal are what the stub's is_aal2()/verified_admin() read. Without
-- them the UPDATE below is not refused — it matches NO ROWS, silently, and an
-- eok() assertion passes for the wrong reason. That is exactly how this suite
-- first reported 39/41 with two follow-up assertions catching what four
-- "successful" updates had missed.
set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal2', false);

select pg_temp.eok('the office can record a fee paid in cash',
  $$update public.nikah_requests
       set fee_status = 'paid', fee_amount_p = 20000, fee_paid_at = now()
     where reference = 'NK-26-9004'$$);

select pg_temp.efail('the office cannot rewrite the Stripe session',
  $$update public.nikah_requests set stripe_session_id = 'cs_mine'
     where reference = 'NK-26-9001'$$);

select pg_temp.efail('the office still cannot move the family''s date',
  $$update public.nikah_requests set preferred_date = current_date + 90
     where reference = 'NK-26-9001'$$);

select pg_temp.efail('nor edit who asked',
  $$update public.nikah_requests set contact_name = 'Somebody Else'
     where reference = 'NK-26-9001'$$);

select pg_temp.efail('nor the reference a payment is matched by',
  $$update public.nikah_requests set reference = 'NK-26-7777'
     where reference = 'NK-26-9001'$$);

select pg_temp.eok('the office can still agree a date, as before',
  $$update public.nikah_requests
       set status = 'confirmed', agreed_date = current_date + 40, reviewed_at = now()
     where reference = 'NK-26-9002'$$);

reset role;

-- The office's cash entry above must have actually landed.
select pg_temp.note('the cash fee the office recorded is on the row',
  (select fee_status = 'paid' and fee_amount_p = 20000
     from public.nikah_requests where reference = 'NK-26-9004'));

-- ...and agreeing a date is still the office's act, not a payment's.
select pg_temp.note('the office agreeing a date is what confirms it',
  (select status from public.nikah_requests where reference = 'NK-26-9002') = 'confirmed');


-- ===========================================================================
--  10. NOTHING FROM 016/017 WAS DISTURBED
-- ===========================================================================
select pg_temp.note('hall bookings still have their own deposit machinery',
  exists (select 1 from pg_proc where proname = 'mark_deposit_paid'));

select pg_temp.note('and the two are separate functions',
  (select count(*) from pg_proc
    where proname in ('mark_deposit_paid','mark_nikah_fee_paid')) = 2);


\o
select name, case when ok then 'PASS' else '**FAIL**' end as result, detail
  from r order by ok, name;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
  from r;
