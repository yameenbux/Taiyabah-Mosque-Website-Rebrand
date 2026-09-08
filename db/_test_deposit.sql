-- ===========================================================================
--  _test_deposit.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 016: paying the deposit is what holds a date, two people
--  cannot pay for the same day, and the record of a payment cannot be edited
--  by the office.
--
--  Run against a FRESHLY BUILT database:
--      _test_supabase_stub.sql, 001 .. 006  (madrasah-db)
--      then a pre-014 booking, then 008 .. 016
--
--  The assertion that matters most is 03: the second person to ask for a date
--  somebody is already paying for is REFUSED. Without it, two people pay £100
--  for one Saturday and the masjid refunds a deposit its own terms call
--  non-refundable.
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

create or replace function pg_temp.next_dow(want int) returns date language sql stable as $$
  select (current_date + ((want - extract(dow from current_date)::int + 7) % 7) + 21)::date
$$;

create or replace function pg_temp.ask(d date, halls int, phone text)
returns jsonb language sql as $$
  select public.request_hall_booking(jsonb_build_object(
    'booking_date', d::text, 'hire_type', 'halls', 'halls_count', halls,
    'first_name','Imran','last_name','Ali',
    'address','12 Astley Street, Bolton BL1 8EH','phone', phone));
$$;

insert into auth.users (id, email)
values ('11111111-1111-1111-1111-111111111111', 'admin@example.test')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email)
values ('11111111-1111-1111-1111-111111111111', 'An Administrator', 'admin@example.test')
on conflict (id) do nothing;
insert into public.user_roles (user_id, role)
values ('11111111-1111-1111-1111-111111111111', 'admin')
on conflict do nothing;


-- ===========================================================================
--  00. Does this test mean anything at all?
-- ===========================================================================
select pg_temp.note('the anon role is subject to RLS',
  not rolsuper and not rolbypassrls,
  'super=' || rolsuper || ' bypassrls=' || rolbypassrls)
from pg_roles where rolname = 'anon';


-- ===========================================================================
--  01. Bookings taken before any of this still work
-- ===========================================================================
select pg_temp.note('every old booking was given a reference',
  not exists (select 1 from public.hall_bookings where reference is null));
select pg_temp.note('old bookings are not marked as having paid online',
  not exists (select 1 from public.hall_bookings
               where session_slot is not null and deposit_status <> 'unpaid'));


-- ===========================================================================
--  02. Asking for a date holds it
-- ===========================================================================
set role anon;
select set_config('t.ref', (pg_temp.ask(pg_temp.next_dow(2), 2, '07700900401') ->> 'reference'), false);
reset role;

select pg_temp.note('a request returns a reference',
  current_setting('t.ref') like 'HH-%',
  current_setting('t.ref'));

select pg_temp.note('the request is on the table, awaiting payment',
  (select deposit_status from public.hall_bookings
    where reference = current_setting('t.ref')) = 'awaiting');

select pg_temp.note('and the date is held for half an hour',
  (select hold_expires_at > now() + interval '25 minutes'
     from public.hall_bookings where reference = current_setting('t.ref')));

select pg_temp.note('the calendar shows the date as taken straight away',
  exists (select 1 from public.hall_availability
           where booking_date = pg_temp.next_dow(2)));


-- ===========================================================================
--  03. THE POINT — nobody else can pay for that date
--
--  This is the whole reason the hold exists. Before 016 both requests
--  succeeded, both people were sent to Stripe, and both paid.
-- ===========================================================================
set role anon;
select pg_temp.efail('a second person cannot request a date being paid for',
  format($$select pg_temp.ask(%L::date, 3, '07700900402')$$, pg_temp.next_dow(2)));
reset role;

select pg_temp.note('and no second row was created for that date',
  (select count(*) from public.hall_bookings
    where booking_date = pg_temp.next_dow(2)) = 1);


-- ===========================================================================
--  04. A hold that is not paid releases itself
--
--  Somebody who opens the form, gets a hold and wanders off must not close a
--  Saturday for ever. There is no cleanup job — the view only counts live
--  holds — so this proves the expiry rather than a tidy-up.
-- ===========================================================================
update public.hall_bookings
   set hold_expires_at = now() - interval '1 minute'
 where reference = current_setting('t.ref');

select pg_temp.note('an expired hold frees the date again',
  not exists (select 1 from public.hall_availability
               where booking_date = pg_temp.next_dow(2)));

set role anon;
select pg_temp.eok('and somebody else can now ask for it',
  format($$select pg_temp.ask(%L::date, 3, '07700900403')$$, pg_temp.next_dow(2)));
reset role;

-- Put it back so the rest of the file works from a known place.
delete from public.hall_bookings where phone = '07700900403';
update public.hall_bookings set hold_expires_at = now() + interval '30 minutes'
 where reference = current_setting('t.ref');


-- ===========================================================================
--  05. Paying
-- ===========================================================================
select pg_temp.note('a payment is recorded',
  (public.mark_deposit_paid(current_setting('t.ref'), 'cs_test_001', 10000)
     ->> 'deposit_status') = 'paid');

select pg_temp.note('the deposit is marked paid and timed',
  (select deposit_status = 'paid' and deposit_paid_at is not null
          and hold_expires_at is null
     from public.hall_bookings where reference = current_setting('t.ref')));

select pg_temp.note('the date stays closed once paid, hold or no hold',
  exists (select 1 from public.hall_availability
           where booking_date = pg_temp.next_dow(2)));

select pg_temp.note('the payment is in the audit log',
  exists (select 1 from public.admin_audit
           where action = 'hall_deposit_paid'
             and detail ->> 'reference' = current_setting('t.ref')));

-- Stripe retries. It must be able to deliver the same event twice.
select pg_temp.note('a repeated webhook delivery changes nothing',
  (public.mark_deposit_paid(current_setting('t.ref'), 'cs_test_001', 10000)
     ->> 'already_recorded') = 'true');

select pg_temp.note('and did not write a second audit line',
  (select count(*) from public.admin_audit
    where action = 'hall_deposit_paid'
      and detail ->> 'reference' = current_setting('t.ref')) = 1);


-- ===========================================================================
--  06. Money for a booking that is not there
--
--  Somebody edits the payment link, or a reference is mistyped. The money is
--  real either way, so this must be loud rather than quietly successful.
-- ===========================================================================
-- It must NOT raise. An exception would roll back the audit line, and would
-- make Stripe retry a delivery that can never succeed.
select pg_temp.note('a payment for an unknown reference is reported, not raised',
  (public.mark_deposit_paid('HH-99-9999', 'cs_test_bogus', 10000)
     ->> 'deposit_status') = 'unmatched');

select pg_temp.note('and somebody is told about it',
  exists (select 1 from public.admin_audit
           where action = 'deposit_for_unknown_booking'
             and detail ->> 'reference' = 'HH-99-9999'));


-- ===========================================================================
--  07. Two payments for one date
--
--  The hold is thirty minutes; a slow checkout can outlast it. Stripe has the
--  money by then, so the only honest thing is to record that it must go back.
-- ===========================================================================
set role anon;
select set_config('t.ref2',
  (pg_temp.ask(pg_temp.next_dow(3), 2, '07700900404') ->> 'reference'), false);
reset role;

-- Simulate the second hirer's hold running out and somebody else paying for
-- the same day underneath them.
update public.hall_bookings set hold_expires_at = now() - interval '1 minute'
 where reference = current_setting('t.ref2');
insert into public.hall_bookings
  (reference, booking_date, hire_type, halls_count, first_name, last_name,
   address, phone, deposit_status, deposit_paid_at, status)
values ('HH-26-9001', pg_temp.next_dow(3), 'halls', 2, 'Faster', 'Payer',
        '1 Quick Street, Bolton', '07700900405', 'paid', now(), 'new');

select pg_temp.note('a payment for a date already taken is flagged for refund',
  (public.mark_deposit_paid(current_setting('t.ref2'), 'cs_test_002', 10000)
     ->> 'deposit_status') = 'refund_due');

select pg_temp.note('and the office is told to send it back',
  exists (select 1 from public.admin_audit
           where action = 'deposit_needs_refund'
             and detail ->> 'reference' = current_setting('t.ref2')));

select pg_temp.note('the person who paid first keeps the date',
  (select deposit_status from public.hall_bookings where reference = 'HH-26-9001') = 'paid');


-- ===========================================================================
--  08. Only the webhook may say that money arrived
-- ===========================================================================
set role anon;
select pg_temp.efail('the public cannot mark a deposit paid',
  $$select public.mark_deposit_paid('HH-26-9001', 'cs_forged', 10000)$$);
select pg_temp.efail('the public can no longer insert a booking directly',
  $$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (current_date + 90, 'halls', 2, 'Direct', 'Insert', '1 Test St, Bolton', '07700900406')$$);
reset role;

set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal2', false);
select pg_temp.efail('not even a verified administrator can',
  $$select public.mark_deposit_paid('HH-26-9001', 'cs_forged2', 10000)$$);
reset role;


-- ===========================================================================
--  09. What the office may write
--
--  Migration 003 granted UPDATE on the whole table. The README and
--  venue/app.js both said the office could only change status, notes and
--  handled_at; neither the grant nor anything else enforced it. 016 makes the
--  documentation true.
-- ===========================================================================
set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal2', false);

select pg_temp.eok('the office can still record an outcome',
  $$update public.hall_bookings set status = 'confirmed', office_notes = 'Rang them',
      handled_at = now() where reference = 'HH-26-9001'$$);

select pg_temp.eok('the office can mark a refund as sent',
  $$update public.hall_bookings set deposit_status = 'refunded'
     where deposit_status = 'refund_due'$$);

select pg_temp.efail('the office cannot rewrite the Stripe session',
  $$update public.hall_bookings set stripe_session_id = 'cs_made_up'
     where reference = 'HH-26-9001'$$);
select pg_temp.efail('the office cannot change when a deposit was paid',
  $$update public.hall_bookings set deposit_paid_at = now() - interval '1 year'
     where reference = 'HH-26-9001'$$);
select pg_temp.efail('the office cannot change a booking reference',
  $$update public.hall_bookings set reference = 'HH-26-0000'
     where reference = 'HH-26-9001'$$);
select pg_temp.efail('the office cannot move somebody''s date',
  $$update public.hall_bookings set booking_date = current_date + 200
     where reference = 'HH-26-9001'$$);
select pg_temp.efail('the office cannot edit somebody''s name',
  $$update public.hall_bookings set first_name = 'Someone Else'
     where reference = 'HH-26-9001'$$);
select pg_temp.efail('the office cannot delete a booking',
  $$delete from public.hall_bookings where reference = 'HH-26-9001'$$);
reset role;


-- ===========================================================================
--  10. Everything 014 established still holds through the new front door
--
--  request_hall_booking() is a SECURITY DEFINER function, which is exactly the
--  sort of thing that quietly bypasses the rules the direct insert obeyed.
-- ===========================================================================
set role anon;

select pg_temp.efail('one hall on a Saturday is still refused',
  format($$select pg_temp.ask(%L::date, 1, '07700900407')$$, pg_temp.next_dow(6)));

select pg_temp.efail('a date in the past is still refused',
  $$select pg_temp.ask(current_date - 1, 2, '07700900408')$$);

select pg_temp.efail('a date beyond twelve months is still refused',
  $$select pg_temp.ask(current_date + 400, 2, '07700900409')$$);

-- Flood control: five from one number, then no more.
select pg_temp.eok('same number, request ' || i,
  format($$select pg_temp.ask(%L::date, 2, '07700900500')$$,
         pg_temp.next_dow(1) + (i * 7)))
from generate_series(1, 5) as i;

select pg_temp.efail('flood control still fires on the sixth',
  format($$select pg_temp.ask(%L::date, 2, '07700900500')$$, pg_temp.next_dow(1) + 70));
reset role;


-- ===========================================================================
--  Results
-- ===========================================================================
\o
select case when ok then 'PASS' else 'FAIL' end as result, name, detail
  from r order by ok, name;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
  from r;

do $$
declare n int;
begin
  select count(*) into n from r where not ok;
  if n > 0 then raise exception '% assertion(s) failed', n; end if;
end $$;
