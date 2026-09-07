-- ===========================================================================
--  _test_whole_day_hire.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 014: the hall is let by the day, by the number of rooms,
--  and the rules on the masjid's price list are enforced by the database
--  rather than by the booking form.
--
--  Run against a FRESHLY BUILT database:
--      _test_supabase_stub.sql, 001 .. 006  (madrasah-db)
--      then at least one booking inserted under the OLD model
--      then 014                             (this folder)
--
--  Fresh matters. This file confirms a booking, and a confirmed booking closes
--  its date for good — so a second run against the same database would find
--  the calendar already closed and report a working migration as broken.
--  /tmp/build_hall.sh does the whole thing in one command.
--
--  Test 00 proves the role under test is actually subject to RLS and column
--  grants. Without it every "cannot" below would pass for the wrong reason.
-- ===========================================================================
\set ON_ERROR_STOP on

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated;

create or replace function pg_temp.note(l text, cond boolean, d text default '')
returns void language plpgsql as $$
begin insert into r values (l, cond, d); end $$;

create or replace function pg_temp.efail(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,false,'unexpectedly SUCCEEDED');
exception when others then insert into r values (l,true,left(sqlerrm,70)); end; end $$;

create or replace function pg_temp.eok(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,true,'');
exception when others then insert into r values (l,false,left(sqlerrm,90)); end; end $$;

\o /dev/null

-- Dates that are definitely the day of week we mean, and definitely bookable.
-- Sunday = 0 in Postgres, Saturday = 6.
create or replace function pg_temp.next_dow(want int) returns date language sql stable as $$
  select (current_date + ((want - extract(dow from current_date)::int + 7) % 7) + 14)::date
$$;

-- Flood control counts requests from one number in the last 24 hours. Running
-- this file twice in an afternoon would therefore fail on the SECOND run with
-- a perfectly working trigger, and the fault would look like the migration.
-- A number unique to this run measures the trigger from zero every time.
select set_config('t.phone',
  '077' || lpad(((random() * 99999999)::bigint)::text, 8, '0'), false);


-- ===========================================================================
--  00. Does this test mean anything at all?
-- ===========================================================================
select pg_temp.note('the anon role is subject to RLS',
  not rolsuper and not rolbypassrls,
  'super=' || rolsuper || ' bypassrls=' || rolbypassrls)
from pg_roles where rolname = 'anon';


-- ===========================================================================
--  01. History survived
--
--  The point of 014 is that it reinterprets the table without destroying what
--  is in it. A migration that quietly loses two bookings is worse than one
--  that fails.
-- ===========================================================================
select pg_temp.note('old bookings are still there',
  (select count(*) from public.hall_bookings) >= 1,
  (select count(*)::text from public.hall_bookings));

-- Scoped to rows that carry a session, because those are precisely the rows
-- taken under the old model. Asserting over the whole table would fail as soon
-- as this file's own kitchen-only booking existed.
select pg_temp.note('old bookings were backfilled as one-hall hires',
  not exists (select 1 from public.hall_bookings
               where session_slot is not null
                 and (hire_type is distinct from 'halls'
                      or halls_count is distinct from 1)));

select pg_temp.note('what the old hirers actually asked for is still recorded',
  exists (select 1 from public.hall_bookings where session_slot is not null));


-- ===========================================================================
--  02. What the public may send
-- ===========================================================================
set role anon;

select pg_temp.eok('a whole-day, two-hall booking is accepted',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', 2, 'Imran', 'Ali', '4 Mill Street, Bolton', '07700900301')$$,
    pg_temp.next_dow(2)));

select pg_temp.eok('kitchen-only hire is accepted',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'kitchen_only', null, 'Sara', 'Bi', '9 Green Street, Bolton', '07700900302')$$,
    pg_temp.next_dow(3)));


-- ===========================================================================
--  03. The rules on the price list
-- ===========================================================================

-- Friday, Saturday and Sunday have no one-hall rate. This is the assertion
-- that would have caught the form offering a booking the masjid does not sell.
select pg_temp.efail('one hall cannot be booked on a Saturday',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', 1, 'Weekend', 'Hirer', '1 Test Street, Bolton', '07700900303')$$,
    pg_temp.next_dow(6)));

select pg_temp.efail('one hall cannot be booked on a Sunday',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', 1, 'Weekend', 'Hirer', '1 Test Street, Bolton', '07700900304')$$,
    pg_temp.next_dow(0)));

select pg_temp.efail('one hall cannot be booked on a Friday',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', 1, 'Weekend', 'Hirer', '1 Test Street, Bolton', '07700900305')$$,
    pg_temp.next_dow(5)));

select pg_temp.eok('two halls on a Saturday is fine',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', 2, 'Weekend', 'Hirer', '1 Test Street, Bolton', '07700900306')$$,
    pg_temp.next_dow(6)));

select pg_temp.eok('one hall midweek is fine',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', 1, 'Midweek', 'Hirer', '1 Test Street, Bolton', '07700900307')$$,
    pg_temp.next_dow(1)));

-- Nonsense combinations
select pg_temp.efail('four halls is refused',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', 4, 'Too', 'Many', '1 Test Street, Bolton', '07700900308')$$,
    pg_temp.next_dow(2)));

select pg_temp.efail('a hall booking with no room count is refused',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', null, 'No', 'Count', '1 Test Street, Bolton', '07700900309')$$,
    pg_temp.next_dow(2)));

select pg_temp.efail('kitchen-only with a room count is refused',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'kitchen_only', 2, 'Kitchen', 'Count', '1 Test St, Bolton', '07700900310')$$,
    pg_temp.next_dow(2)));

select pg_temp.efail('an invented hire type is refused',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'whole_building', 3, 'Made', 'Up', '1 Test Street, Bolton', '07700900311')$$,
    pg_temp.next_dow(2)));


-- ===========================================================================
--  04. The retired columns are out of the browser's reach
--
--  Column-level INSERT grants, not policies. If these ever start succeeding,
--  a form could set a session on a booking that has no sessions, or set its
--  own status.
-- ===========================================================================
select pg_temp.efail('the public cannot set a session slot',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, session_slot, first_name, last_name, address, phone)
    values (%L, 'halls', 2, 'morning', 'Old', 'Model', '1 Test Street, Bolton', '07700900312')$$,
    pg_temp.next_dow(2)));

select pg_temp.efail('the public cannot set the kitchen flag',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, kitchen, first_name, last_name, address, phone)
    values (%L, 'halls', 2, true, 'Old', 'Model', '1 Test Street, Bolton', '07700900313')$$,
    pg_temp.next_dow(2)));

select pg_temp.efail('the public cannot pick a specific hall',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, hall, first_name, last_name, address, phone)
    values (%L, 'halls', 2, '3', 'Old', 'Model', '1 Test Street, Bolton', '07700900314')$$,
    pg_temp.next_dow(2)));

select pg_temp.efail('the public cannot confirm its own booking',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, status, first_name, last_name, address, phone)
    values (%L, 'halls', 2, 'confirmed', 'Self', 'Confirmed', '1 Test St, Bolton', '07700900315')$$,
    pg_temp.next_dow(2)));

select pg_temp.efail('the public still cannot read a booking back',
  $$select count(*) from public.hall_bookings$$);
reset role;


-- ===========================================================================
--  05. Flood control still works
--
--  014 rewrote the grants, and a rewritten grant is exactly the sort of change
--  that silently detaches a trigger from the path it was guarding.
-- ===========================================================================
set role anon;
select pg_temp.eok('same number, request ' || i,
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', 2, 'Flood', 'Test', '1 Test Street, Bolton', %L)$$,
    pg_temp.next_dow(2) + i, current_setting('t.phone')))
from generate_series(1, 5) as i;

select pg_temp.efail('the sixth request from one number is refused',
  format($$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone)
    values (%L, 'halls', 2, 'Flood', 'Test', '1 Test Street, Bolton', %L)$$,
    pg_temp.next_dow(2) + 9, current_setting('t.phone')));
reset role;


-- ===========================================================================
--  06. The public calendar
-- ===========================================================================

-- Nothing is confirmed yet, so it must be empty. A calendar that shows
-- pending requests lets a stranger close every Saturday with a form.
-- About THIS run's booking, not the whole table: a date confirmed by an
-- earlier run would otherwise make a working calendar look broken.
select pg_temp.note('a pending request does not close its date',
  (select count(*) from public.hall_availability
    where booking_date = pg_temp.next_dow(2)) = 0);

update public.hall_bookings set status = 'confirmed'
 where phone = '07700900301';

select pg_temp.note('a confirmed booking closes its date',
  (select count(*) from public.hall_availability
    where booking_date = pg_temp.next_dow(2)) = 1);

-- The view must give away a date and nothing else. Anything more is a
-- world-readable leak, because anon can read this.
select pg_temp.note('the calendar publishes the date and nothing else',
  (select array_agg(attname::text order by attname)
     from pg_attribute
    where attrelid = 'public.hall_availability'::regclass and attnum > 0)
  = array['booking_date'],
  (select string_agg(attname, ', ') from pg_attribute
    where attrelid = 'public.hall_availability'::regclass and attnum > 0));

set role anon;
select pg_temp.eok('the public can read the calendar',
  $$select count(*) from public.hall_availability$$);
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
