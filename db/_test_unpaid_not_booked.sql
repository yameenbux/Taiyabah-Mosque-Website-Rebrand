-- ===========================================================================
--  _test_unpaid_not_booked.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 021.
--
--  Run against a FRESHLY BUILT database:  bash db/harness/build.sh t_21 full
--  (or just db/harness/run-all.sh, which knows the profile)
--
--  THE ASSERTION THAT MATTERS IS 02a: THE OFFICE CANNOT CONFIRM A BOOKING
--  NOBODY HAS PAID FOR. On 11 September 2026 they could, and did — HH-26-0009
--  showed as CONFIRMED thirty seconds after it was requested, with
--  deposit_status 'awaiting' and deposit_paid_at null. A date sold with no
--  money behind it is the same double-booking failure 017 was written to
--  prevent, arriving from the other side.
--
--  Hiding the Confirm button does not count. A check that only exists in
--  JavaScript does not exist.
-- ===========================================================================
\set ON_ERROR_STOP on

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated;

create or replace function pg_temp.note(l text, cond boolean, d text default '')
returns void language plpgsql as $$
begin
  insert into r values (l, coalesce(cond, false), d);
end $$;

-- 200, not the 70 the other suites use: one assertion below checks that the
-- refusal TELLS THE OFFICE WHAT TO DO INSTEAD, and at 70 characters the part
-- that says it was being cut off — so the test was reading a truncated copy
-- and failing against a message that was in fact correct.
create or replace function pg_temp.efail(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,false,'unexpectedly SUCCEEDED');
exception when others then insert into r values (l,true,left(sqlerrm,200)); end; end $$;

create or replace function pg_temp.eok(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,true,'');
exception when others then insert into r values (l,false,left(sqlerrm,90)); end; end $$;

\o /dev/null

-- A staff session that has passed two-step. Without BOTH of these the
-- policies match zero rows and every write below "succeeds" by changing
-- nothing — the vacuous pass this project has been bitten by three times.
create or replace function pg_temp.be_staff() returns void language plpgsql as $$
begin
  perform set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
  perform set_config('test.aal', 'aal2', false);
end $$;

select pg_temp.be_staff();


-- Fixtures, inserted as the owner so RLS is not in the way of the setup.
insert into public.hall_bookings
  (reference, booking_date, hire_type, halls_count, first_name, last_name,
   address, phone, status, deposit_status, deposit_paid_at, hold_expires_at,
   base_amount_p)
values
  -- In checkout right now. Eighteen minutes left.
  ('HH-T-0001', current_date + 40, 'halls', 2, 'Still', 'Paying',
   '1 Live Street, Bolton', '07700900801', 'new', 'awaiting', null,
   now() + interval '18 minutes', 50000),
  -- Walked away. The thirty minutes are up and nobody touched it.
  ('HH-T-0002', current_date + 41, 'halls', 2, 'Walked', 'Away',
   '2 Gone Street, Bolton', '07700900802', 'new', 'awaiting', null,
   now() - interval '40 minutes', 50000),
  -- Walked away, but the OFFICE DECLINED it. That is a decision somebody
  -- made; the record of it has value and must survive the purge.
  ('HH-T-0003', current_date + 42, 'halls', 2, 'Was', 'Declined',
   '3 Kept Street, Bolton', '07700900803', 'declined', 'awaiting', null,
   now() - interval '90 minutes', 50000),
  -- Lapsed hold, but the money DID arrive. Never deletable.
  ('HH-T-0004', current_date + 43, 'halls', 2, 'Did', 'Pay',
   '4 Paid Street, Bolton', '07700900804', 'confirmed', 'paid',
   now() - interval '2 hours', now() - interval '3 hours', 50000),
  -- Never sent to Stripe at all — the office is handling this one by phone.
  ('HH-T-0005', current_date + 44, 'halls', 2, 'By', 'Phone',
   '5 Office Street, Bolton', '07700900805', 'new', 'unpaid', null,
   null, 50000),
  -- For the cash path.
  ('HH-T-0006', current_date + 45, 'halls', 2, 'Paid', 'Cash',
   '6 Counter Street, Bolton', '07700900806', 'new', 'unpaid', null,
   null, 50000),
  -- Went to checkout, then RANG THE OFFICE and said they would pay by bank
  -- transfer instead. The office moved the deposit back to 'unpaid', which is
  -- in their grant and is the honest record: this one is being handled by a
  -- person now. The hold has long since lapsed. It must NOT be deleted — the
  -- office is in the middle of it, and the purge is for rows nobody is
  -- dealing with. This fixture is why the 'awaiting' clause exists rather
  -- than being redundant decoration.
  ('HH-T-0008', current_date + 46, 'halls', 2, 'Paying', 'Differently',
   '8 Transfer Street, Bolton', '07700900808', 'new', 'unpaid', null,
   now() - interval '2 hours', 50000);


-- ===========================================================================
--  01. NOTHING WAS ALREADY BROKEN
-- ===========================================================================
select pg_temp.note('no booking is confirmed while the hirer is mid-checkout',
  not exists (select 1 from public.hall_bookings
               where status = 'confirmed' and deposit_status = 'awaiting'
                 and deposit_paid_at is null));


-- ===========================================================================
--  02. THE OFFICE CANNOT SELL A DATE NOBODY PAID FOR
-- ===========================================================================
set role authenticated;
select pg_temp.be_staff();

-- 02a. THE ONE. This exact UPDATE is what the Confirm button sent.
select pg_temp.efail('THE OFFICE CANNOT CONFIRM A BOOKING WITH NO DEPOSIT',
  $$update public.hall_bookings set status = 'confirmed', handled_at = now()
     where reference = 'HH-T-0005'$$);

select pg_temp.efail('nor one whose hirer is still in the checkout',
  $$update public.hall_bookings set status = 'confirmed', handled_at = now()
     where reference = 'HH-T-0001'$$);

-- The refusal has to tell the office what to do instead, or they will simply
-- try again and then ring somebody.
select pg_temp.note('and the refusal says what to do instead',
  (select detail from r where name = 'THE OFFICE CANNOT CONFIRM A BOOKING WITH NO DEPOSIT')
    ilike '%cash%',
  (select detail from r where name = 'THE OFFICE CANNOT CONFIRM A BOOKING WITH NO DEPOSIT'));

-- Everything else the office does must still work. A rule that blocks the
-- day's work gets worked around.
select pg_temp.eok('the office can still decline an unpaid request',
  $$update public.hall_bookings set status = 'declined', handled_at = now()
     where reference = 'HH-T-0005'$$);

select pg_temp.eok('and still write notes on a paid booking',
  $$update public.hall_bookings set office_notes = 'Rang them'
     where reference = 'HH-T-0004'$$);

select pg_temp.eok('and still record a balance received',
  $$update public.hall_bookings set balance_status = 'paid', balance_paid_at = now()
     where reference = 'HH-T-0004'$$);

reset role;

-- Read the row back. An eok() on an UPDATE proves only that nothing was
-- raised — under RLS it can match zero rows and still "pass".
select pg_temp.note('the decline really was written',
  (select status::text from public.hall_bookings where reference = 'HH-T-0005') = 'declined',
  (select status::text from public.hall_bookings where reference = 'HH-T-0005'));

select pg_temp.note('and the unpaid booking is still NOT confirmed',
  (select status::text from public.hall_bookings where reference = 'HH-T-0001') = 'new');


-- ===========================================================================
--  03. PAYING STILL CONFIRMS IT
--
--  The trigger must not break the one path that is supposed to work. It sets
--  deposit_status and status in the SAME update, so the trigger sees the new
--  deposit_status — but that is a detail of trigger semantics, not something
--  to take on trust.
-- ===========================================================================
select public.mark_deposit_paid('HH-T-0001', 'cs_test_live_hold', 10000);

select pg_temp.note('a paid deposit still confirms the booking',
  (select status::text from public.hall_bookings where reference = 'HH-T-0001') = 'confirmed',
  (select status::text from public.hall_bookings where reference = 'HH-T-0001'));

select pg_temp.note('and records when the money arrived',
  (select deposit_paid_at is not null from public.hall_bookings
    where reference = 'HH-T-0001'));


-- ===========================================================================
--  04. A DEPOSIT TAKEN AT THE COUNTER
--
--  The legitimate need the Confirm button was carrying. If this does not work
--  the office loses the ability to book anyone who walks in with cash, and the
--  rule above becomes something to route around.
-- ===========================================================================
set role authenticated;
select pg_temp.be_staff();

select pg_temp.eok('staff can record a deposit taken in cash',
  $$select public.record_cash_deposit('HH-T-0006', 10000)$$);
reset role;

select pg_temp.note('and that books the date',
  (select status::text from public.hall_bookings where reference = 'HH-T-0006') = 'confirmed',
  (select status::text from public.hall_bookings where reference = 'HH-T-0006'));

select pg_temp.note('with the deposit recorded as paid',
  (select deposit_status from public.hall_bookings where reference = 'HH-T-0006') = 'paid');

select pg_temp.note('and the hold released',
  (select hold_expires_at is null from public.hall_bookings where reference = 'HH-T-0006'));

-- Who said the money exists. This is the one path where a person, not Stripe,
-- asserts a payment — so it is the one that has to name them.
select pg_temp.note('AND WHO RECORDED IT IS AUDITED',
  exists (select 1 from public.admin_audit
           where action = 'hall_deposit_cash'
             and detail ->> 'reference' = 'HH-T-0006'
             and detail ->> 'recorded_by' is not null));

-- Twice is not two deposits.
set role authenticated;
select pg_temp.be_staff();
select pg_temp.note('recording it twice changes nothing',
  (public.record_cash_deposit('HH-T-0006', 10000) ->> 'already_recorded') = 'true');
reset role;

select pg_temp.note('and does not write a second audit line',
  (select count(*) from public.admin_audit
    where action = 'hall_deposit_cash'
      and detail ->> 'reference' = 'HH-T-0006') = 1);

-- Somebody at the desk cannot see the diary the calendar sees.
insert into public.hall_bookings
  (reference, booking_date, hire_type, halls_count, first_name, last_name,
   address, phone, status, deposit_status, base_amount_p)
values ('HH-T-0007', (select booking_date from public.hall_bookings where reference = 'HH-T-0006'),
        'halls', 2, 'Too', 'Late', '7 Clash Street, Bolton', '07700900807',
        'new', 'unpaid', 50000);

set role authenticated;
select pg_temp.be_staff();
select pg_temp.efail('CASH IS REFUSED FOR A DATE ALREADY TAKEN',
  $$select public.record_cash_deposit('HH-T-0007', 10000)$$);
reset role;

select pg_temp.note('and that date is still the first booking''s',
  (select status::text from public.hall_bookings where reference = 'HH-T-0007') = 'new');


-- ===========================================================================
--  05. WHO MAY RECORD CASH
-- ===========================================================================
set role anon;
select pg_temp.efail('the public cannot record a cash deposit',
  $$select public.record_cash_deposit('HH-T-0002', 10000)$$);
reset role;

set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal1', false);
select pg_temp.efail('nor staff who have not passed two-step',
  $$select public.record_cash_deposit('HH-T-0002', 10000)$$);
reset role;
select pg_temp.be_staff();


-- ===========================================================================
--  06. DELETING A HOLD NOBODY PAID FOR
--
--  Asked for plainly: once the thirty minutes are up and no deposit arrived,
--  the booking should be removed altogether.
-- ===========================================================================
select pg_temp.note('a lapsed unpaid hold is deleted',
  public.purge_expired_holds() = 1,
  (select count(*)::text from public.hall_bookings where reference = 'HH-T-0002'));

select pg_temp.note('and it really is gone',
  not exists (select 1 from public.hall_bookings where reference = 'HH-T-0002'));

-- The four things it must never touch.
select pg_temp.note('a LIVE hold survives',
  exists (select 1 from public.hall_bookings where reference = 'HH-T-0001'));

select pg_temp.note('A BOOKING SOMEBODY PAID FOR IS NEVER DELETED',
  exists (select 1 from public.hall_bookings where reference = 'HH-T-0004'));

select pg_temp.note('a request the office DECLINED survives — that was a decision',
  exists (select 1 from public.hall_bookings where reference = 'HH-T-0003'));

select pg_temp.note('a booking never sent to Stripe survives',
  exists (select 1 from public.hall_bookings where reference = 'HH-T-0007'));

-- The office took this one off Stripe and is handling it themselves. A lapsed
-- hold on a row somebody is actively dealing with is not abandonment.
select pg_temp.note('A BOOKING THE OFFICE TOOK OVER SURVIVES ITS LAPSED HOLD',
  exists (select 1 from public.hall_bookings where reference = 'HH-T-0008'));

select pg_temp.note('the deletion is audited by reference',
  (select detail -> 'references' from public.admin_audit
    where action = 'hall_holds_purged' order by at desc limit 1)::text like '%HH-T-0002%',
  (select detail::text from public.admin_audit
    where action = 'hall_holds_purged' order by at desc limit 1));

-- A job that is silent on a quiet run is indistinguishable from a job that has
-- stopped running.
select pg_temp.note('a run that finds nothing still says so',
  public.purge_expired_holds() = 0);

select pg_temp.note('and leaves a line saying it looked',
  (select count(*) from public.admin_audit where action = 'hall_holds_purged') = 2);


-- ===========================================================================
--  07. WHO MAY PURGE
--
--  By GRANT, not by an is_admin() check. pg_cron holds no JWT, so auth.uid()
--  is null inside a scheduled run and such a check would fail silently every
--  ten minutes — 015's lesson.
-- ===========================================================================
set role anon;
select pg_temp.efail('the public cannot purge',
  $$select public.purge_expired_holds()$$);
reset role;

set role authenticated;
select pg_temp.be_staff();
select pg_temp.efail('nor can a verified administrator from the browser',
  $$select public.purge_expired_holds()$$);
reset role;


-- ===========================================================================
--  08. NOTHING ELSE WAS DISTURBED
-- ===========================================================================
select pg_temp.note('017 and 018 are still there',
  (select count(*) from pg_proc
    where proname in ('mark_deposit_paid','mark_nikah_fee_paid',
                      'cancel_paid_booking','hall_base_amount_p')) = 4);

select pg_temp.note('and 015 and 019 are still there',
  (select count(*) from pg_proc
    where proname in ('purge_old_nikah_requests','purge_old_course_registrations',
                      'send_weekly_digest')) = 3);


\o
select case when ok then 'PASS' else '**FAIL**' end as result, name, detail
  from r order by ok, name;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
  from r;
