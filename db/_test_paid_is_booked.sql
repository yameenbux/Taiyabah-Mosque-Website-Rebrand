-- ===========================================================================
--  _test_paid_is_booked.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 017: paying confirms the booking, the rate card in the
--  database is the rate card on the masjid's sheet, and the one way to undo a
--  paid booking is deliberate, reasoned and audited.
--
--  Run against a FRESHLY BUILT database:
--      _test_supabase_stub.sql, 001 .. 006, a pre-014 booking, then 008 .. 017
--
--  The assertion that matters most is 03: paying sets status = 'confirmed'.
--  Without it a hirer pays £100 and then waits for a phone call to find out
--  whether they have booked anything.
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

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','admin@example.test'),
  ('33333333-3333-3333-3333-333333333333','customer@example.test')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email) values
  ('11111111-1111-1111-1111-111111111111','An Administrator','admin@example.test'),
  ('33333333-3333-3333-3333-333333333333','A Shop Customer','customer@example.test')
on conflict (id) do nothing;
insert into public.user_roles (user_id, role)
values ('11111111-1111-1111-1111-111111111111','admin')
on conflict do nothing;


-- ===========================================================================
--  00. Does this test mean anything at all?
-- ===========================================================================
select pg_temp.note('the anon role is subject to RLS',
  not rolsuper and not rolbypassrls,
  'super=' || rolsuper || ' bypassrls=' || rolbypassrls)
from pg_roles where rolname = 'anon';


-- ===========================================================================
--  01. The rate card, exactly as the masjid publishes it
--
--  Every figure below is read off the sheet dated 1 January 2024. If one of
--  these fails, the website is quoting a price the masjid does not charge.
-- ===========================================================================
select pg_temp.note('Mon-Thu, 1 hall is £350',
  public.hall_base_amount_p(date '2026-09-15','halls',1) = 35000);
select pg_temp.note('Mon-Thu, 2 halls is £500',
  public.hall_base_amount_p(date '2026-09-15','halls',2) = 50000);
select pg_temp.note('Mon-Thu, 3 halls is £600',
  public.hall_base_amount_p(date '2026-09-15','halls',3) = 60000);
select pg_temp.note('Fri-Sun, 2 halls is £600',
  public.hall_base_amount_p(date '2026-09-19','halls',2) = 60000);
select pg_temp.note('Fri-Sun, 3 halls is £700',
  public.hall_base_amount_p(date '2026-09-19','halls',3) = 70000);
select pg_temp.note('kitchen only is £125',
  public.hall_base_amount_p(date '2026-09-15','kitchen_only',null) = 12500);

-- The combination the masjid does not sell has no price, on every one of the
-- three days it does not sell it.
select pg_temp.note('one hall has no weekend rate at all',
  public.hall_base_amount_p(date '2026-09-18','halls',1) is null   -- Friday
  and public.hall_base_amount_p(date '2026-09-19','halls',1) is null -- Saturday
  and public.hall_base_amount_p(date '2026-09-20','halls',1) is null); -- Sunday

-- Every booking taken under the WHOLE-DAY model gets a rate.
select pg_temp.note('every whole-day booking has a rate',
  not exists (select 1 from public.hall_bookings
               where session_slot is null and base_amount_p is null),
  (select string_agg(reference, ', ') from public.hall_bookings
    where session_slot is null and base_amount_p is null));

-- Bookings taken under the OLD session rates may not. The fixture is one hall
-- on a Friday: a perfectly good booking at the time, and a combination the
-- price list no longer sells, so there is no current rate to backfill it with.
-- Inventing one would be worse than leaving it blank — the office knows what
-- was actually charged and the database does not.
--
-- The consequence the PORTAL has to honour: a null base must render as a dash,
-- never as £0.00 and never as NaN.
select pg_temp.note('a legacy booking the price list no longer covers has no rate',
  (select base_amount_p is null and session_slot is not null
     from public.hall_bookings where reference = 'HH-26-0001'));


-- ===========================================================================
--  02. The rate is stored when the booking is taken
--
--  Stored, not recomputed. A booking taken under this year's prices has to
--  keep showing this year's prices after the trustees change them.
-- ===========================================================================
set role anon;
select set_config('t.ref',
  (pg_temp.ask(pg_temp.next_dow(2), 2, '07700900601') ->> 'reference'), false);
reset role;

select pg_temp.note('a midweek two-hall booking stored £500',
  (select base_amount_p from public.hall_bookings
    where reference = current_setting('t.ref')) = 50000,
  (select (base_amount_p/100.0)::text from public.hall_bookings
    where reference = current_setting('t.ref')));

select pg_temp.note('and it starts with no extras and nothing paid',
  (select extras_p = 0 and balance_status = 'unpaid'
     from public.hall_bookings where reference = current_setting('t.ref')));


-- ===========================================================================
--  03. THE POINT — paying confirms the booking
-- ===========================================================================
select pg_temp.note('the request is not confirmed before payment',
  (select status::text from public.hall_bookings
    where reference = current_setting('t.ref')) = 'new');

select pg_temp.note('paying returns a confirmed booking',
  (public.mark_deposit_paid(current_setting('t.ref'), 'cs_017_001', 10000)
     ->> 'status') = 'confirmed');

select pg_temp.note('and the row really is confirmed, and timed',
  (select status::text = 'confirmed' and deposit_status = 'paid'
          and handled_at is not null
     from public.hall_bookings where reference = current_setting('t.ref')));

select pg_temp.note('the audit line says it was confirmed',
  exists (select 1 from public.admin_audit
           where action = 'hall_deposit_paid'
             and detail ->> 'reference' = current_setting('t.ref')
             and (detail ->> 'confirmed') = 'true'));

-- Stripe retries; the second delivery must not confirm anything twice.
select pg_temp.note('a repeated delivery still changes nothing',
  (public.mark_deposit_paid(current_setting('t.ref'), 'cs_017_001', 10000)
     ->> 'already_recorded') = 'true');


-- ===========================================================================
--  04. Two payments for one day are NOT both confirmed
--
--  This is the case that makes cancel-and-refund necessary. If it ever starts
--  confirming both, the masjid has sold one hall twice.
-- ===========================================================================
set role anon;
select set_config('t.ref2',
  (pg_temp.ask(pg_temp.next_dow(3), 2, '07700900602') ->> 'reference'), false);
reset role;

update public.hall_bookings set hold_expires_at = now() - interval '1 minute'
 where reference = current_setting('t.ref2');
insert into public.hall_bookings
  (reference, booking_date, hire_type, halls_count, first_name, last_name,
   address, phone, deposit_status, deposit_paid_at, status, base_amount_p)
values ('HH-26-9100', pg_temp.next_dow(3), 'halls', 2, 'Faster', 'Payer',
        '1 Quick Street, Bolton', '07700900603', 'paid', now(), 'confirmed', 50000);

select pg_temp.note('the second payer is marked for refund, not confirmed',
  (public.mark_deposit_paid(current_setting('t.ref2'), 'cs_017_002', 10000)
     ->> 'deposit_status') = 'refund_due');

select pg_temp.note('and their booking was NOT confirmed',
  (select status::text from public.hall_bookings
    where reference = current_setting('t.ref2')) <> 'confirmed');


-- ===========================================================================
--  05. Undoing a paid booking
-- ===========================================================================
set role authenticated;
select set_config('test.uid','33333333-3333-3333-3333-333333333333', false);
select set_config('test.aal','aal2', false);
select pg_temp.efail('a shop customer cannot cancel a paid booking',
  format($$select public.cancel_paid_booking(%L,'They asked us to, honestly')$$,
         current_setting('t.ref')));

select set_config('test.uid','11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal','aal1', false);
select pg_temp.efail('an admin who has not entered a code cannot either',
  format($$select public.cancel_paid_booking(%L,'A perfectly good reason here')$$,
         current_setting('t.ref')));

select set_config('test.aal','aal2', false);
select pg_temp.efail('a cancellation needs a real reason',
  format($$select public.cancel_paid_booking(%L,'nope')$$, current_setting('t.ref')));

select pg_temp.eok('a verified admin can cancel with a reason',
  format($$select public.cancel_paid_booking(%L,'Double booking — the other party paid first')$$,
         current_setting('t.ref')));
reset role;

select pg_temp.note('the booking is cancelled and the money marked owed back',
  (select status::text = 'cancelled' and deposit_status = 'refund_due'
     from public.hall_bookings where reference = current_setting('t.ref')));

select pg_temp.note('the reason is on the booking where the office will see it',
  (select office_notes like '%Double booking%'
     from public.hall_bookings where reference = current_setting('t.ref')));

select pg_temp.note('and in the audit log, with who did it',
  exists (select 1 from public.admin_audit
           where action = 'hall_booking_cancelled_by_masjid'
             and detail ->> 'reference' = current_setting('t.ref')
             and actor = '11111111-1111-1111-1111-111111111111'));

select pg_temp.note('cancelling freed the date',
  not exists (select 1 from public.hall_availability
               where booking_date = pg_temp.next_dow(2)));

-- A request nobody paid for is cancelled the ordinary way, not through this.
set role anon;
select set_config('t.ref3',
  (pg_temp.ask(pg_temp.next_dow(4), 2, '07700900604') ->> 'reference'), false);
reset role;
set role authenticated;
select set_config('test.uid','11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal','aal2', false);
select pg_temp.efail('an unpaid booking is not cancelled through this route',
  format($$select public.cancel_paid_booking(%L,'Nothing was ever paid for this')$$,
         current_setting('t.ref3')));
reset role;

set role anon;
select pg_temp.efail('the public cannot cancel anybody''s booking',
  $$select public.cancel_paid_booking('HH-26-9100','Because I felt like it today')$$);
reset role;


-- ===========================================================================
--  06. The balance
-- ===========================================================================
set role authenticated;
select set_config('test.uid','11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal','aal2', false);

select pg_temp.eok('the office can record the extras',
  $$update public.hall_bookings set extras_p = 15400
     where reference = 'HH-26-9100'$$);

select pg_temp.eok('and mark the balance as paid',
  $$update public.hall_bookings
       set balance_status = 'paid', balance_paid_at = now()
     where reference = 'HH-26-9100'$$);

-- The stored rate is the masjid's record of what it charged. The office does
-- not get to move it after the fact.
select pg_temp.efail('the office cannot change the base rate',
  $$update public.hall_bookings set base_amount_p = 1
     where reference = 'HH-26-9100'$$);
select pg_temp.efail('the office still cannot rewrite the Stripe session',
  $$update public.hall_bookings set stripe_session_id = 'cs_made_up'
     where reference = 'HH-26-9100'$$);
select pg_temp.efail('the office still cannot move somebody''s date',
  $$update public.hall_bookings set booking_date = current_date + 300
     where reference = 'HH-26-9100'$$);

select pg_temp.efail('a negative extras figure is refused',
  $$update public.hall_bookings set extras_p = -500
     where reference = 'HH-26-9100'$$);
select pg_temp.efail('an invented balance state is refused',
  $$update public.hall_bookings set balance_status = 'maybe'
     where reference = 'HH-26-9100'$$);
reset role;

select pg_temp.note('the sums add up',
  (select base_amount_p + extras_p = 65400
     from public.hall_bookings where reference = 'HH-26-9100'),
  (select ((base_amount_p + extras_p)/100.0)::text
     from public.hall_bookings where reference = 'HH-26-9100'));


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
