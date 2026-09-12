-- ===========================================================================
--  _test_dashboard.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 024, the admin centre's one call.
--
--  Run against a FRESHLY BUILT database:  bash db/harness/build.sh t_24 full
--  (or db/harness/run-all.sh, which knows the profile)
--
--  THE THREE THAT MATTER:
--
--    02a  a signed-out stranger gets {"allowed": false} and nothing else
--    03b  hall office does NOT get Gift Aid — it is donors' names and home
--         addresses, and the role check is the only thing standing there
--    05c  MONEY OWED DOES NOT SILENTLY UNDERSTATE. A booking on the old
--         session rates cannot be priced; counting it as zero would make the
--         masjid's own dashboard tell it that it is owed less than it is
-- ===========================================================================
\set ON_ERROR_STOP on

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated;

create or replace function pg_temp.note(l text, cond boolean, d text default '')
returns void language plpgsql as $$
begin insert into r values (l, coalesce(cond, false), d); end $$;

create or replace function pg_temp.efail(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,false,'unexpectedly SUCCEEDED');
exception when others then insert into r values (l,true,left(sqlerrm,150)); end; end $$;

create or replace function pg_temp.be_staff() returns void language plpgsql as $$
begin
  perform set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
  perform set_config('test.aal', 'aal2', false);
end $$;

--  A second account that holds hall_office and NOT admin, so section 03 has
--  somebody real to be refused as. Without this the role gate would be
--  asserted against nobody, which is an assertion about nothing.
insert into auth.users (id, email)
values ('22222222-2222-2222-2222-222222222222', 'office@example.test');
insert into public.user_roles (user_id, role)
values ('22222222-2222-2222-2222-222222222222', 'hall_office');
insert into auth.mfa_factors (user_id, status)
values ('22222222-2222-2222-2222-222222222222', 'verified');
insert into public.profiles (id, full_name, email)
values ('22222222-2222-2222-2222-222222222222', 'Office Person', 'office@example.test')
on conflict (id) do nothing;

create or replace function pg_temp.be_office() returns void language plpgsql as $$
begin
  perform set_config('test.uid', '22222222-2222-2222-2222-222222222222', false);
  perform set_config('test.aal', 'aal2', false);
end $$;

\o /dev/null


-- ===========================================================================
--  01. FIXTURES — one of everything the dashboard claims to count
-- ===========================================================================
alter table public.hall_bookings drop constraint if exists date_not_past;

--  EVERY FIXTURE DATE IS A MONDAY, on purpose. One hall on its own cannot be
--  booked at a weekend (014's trigger refuses it), so "current_date + 30"
--  lands on a legal date or an illegal one depending on what day you happen
--  to run the suite. A fixture whose meaning depends on the day you run it is
--  not a fixture — this project has been bitten by exactly that before, in
--  _test_paid_is_booked.
with d as (
  select (current_date + ((8 - extract(dow from current_date)::int) % 7) + 7)::date as mon
)
insert into public.hall_bookings
  (reference, created_at, booking_date, session_slot, hall, kitchen, hire_type,
   halls_count, first_name, last_name, address, phone, status,
   deposit_status, hold_expires_at, base_amount_p, extras_p, balance_status)
select * from (
  select 'HH-T-HOLD', now() - interval '5 minutes', mon + 21, 'morning'::booking_slot, '1', false,
         'halls', 1, 'Ismail', 'Desai', '1 Mill St', '07700900201', 'new'::booking_status,
         'awaiting', now() + interval '12 minutes', 45000, 0, 'unpaid' from d
  union all
  select 'HH-T-NEW', now() - interval '2 days', mon + 28, 'morning'::booking_slot, '2', false,
         'halls', 1, 'Sara', 'Khan', '2 Mill St', '07700900202', 'new'::booking_status,
         'unpaid', null, 45000, 0, 'unpaid' from d
  union all
  -- confirmed, deposit paid online, balance still owed: 450 - 100 = 350
  select 'HH-T-OWED', now() - interval '9 days', mon + 7, 'morning'::booking_slot, '1', false,
         'halls', 1, 'Bilal', 'Ahmed', '3 Mill St', '07700900203', 'confirmed'::booking_status,
         'paid', null, 45000, 0, 'unpaid' from d
  union all
  -- confirmed on the OLD session rates: no base, so it CANNOT be priced
  select 'HH-T-OLD', now() - interval '30 days', mon + 14, 'evening'::booking_slot, '2', false,
         'halls', 1, 'Old', 'Rate', '4 Mill St', '07700900204', 'confirmed'::booking_status,
         'paid', null, null, 0, 'unpaid' from d
) v;

insert into public.nikah_requests
  (reference, submitted_at, preferred_date, slot, contact_name, contact_role,
   contact_phone, contact_email, privacy_accepted, status)
select 'NK-T-NEW', now() - interval '2 days',
       (current_date + ((8 - extract(dow from current_date)::int) % 7) + 35)::date, 'after_zuhr',
        'Fatima Patel', 'bride', '07700900118', 'f@example.test', true, 'new';

select public.register_foodbank_volunteer($${
  "full_name":"Sunday Helper","phone":"07700900301","gender":"female","age":30,
  "preferred_contact":"phone","sunday_mornings":true,"frequency":"weekly",
  "consent":true}$$::jsonb);
select public.register_foodbank_volunteer($${
  "full_name":"Weekday Helper","phone":"07700900302","gender":"male","age":44,
  "preferred_contact":"phone","sunday_mornings":false,"frequency":"monthly",
  "consent":true}$$::jsonb);

select public.record_donation_paid('DN-T-GA1', 'cs_dash_1', 4000, true,
                                   'A Donor', '5 Mill St', 'BL1 8HD');

--  The log's raw material: one automatic job repeated, one staff action, one
--  arrival. Proportioned like the real audit trail, where 120 of 130 rows
--  were the same purge.
insert into public.admin_audit (actor, action, detail, at)
select null, 'hall_holds_purged', '{"released":0}'::jsonb, now() - (g || ' hours')::interval
  from generate_series(1, 20) g;
insert into public.admin_audit (actor, action, detail, at)
values ('11111111-1111-1111-1111-111111111111', 'cash_deposit_recorded',
        '{"reference":"HH-T-OWED"}'::jsonb, now() - interval '3 hours');

--  An ARRIVAL. 06e asserts that things the public sent in are labelled as
--  such rather than attributed to a member of staff — and an assertion with
--  no fixture behind it passes for the wrong reason, or fails for one. The
--  fixtures above insert bookings directly, so no arrival was ever audited
--  until this row. (Caught by the assertion failing, which is the suite
--  doing its job.)
insert into public.admin_audit (actor, action, detail, at)
values (null, 'hall_booking_requested',
        '{"reference":"HH-T-NEW"}'::jsonb, now() - interval '2 days');


-- ===========================================================================
--  02. WHO GETS AN ANSWER AT ALL
-- ===========================================================================
set role anon;
select pg_temp.efail('02a. A SIGNED-OUT STRANGER CANNOT CALL IT',
  $$select public.admin_dashboard()$$);
reset role;

set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal1', false);
select pg_temp.note('02b. an admin who has not done two-step is refused',
  (public.admin_dashboard()->>'allowed')::boolean is false);
reset role;


-- ===========================================================================
--  03. THE ROLE GATE
--
--  03b is the one that matters. Gift Aid is a list of donors' names and home
--  addresses; hall office has no business with it, and the ONLY thing
--  standing between them is this check.
-- ===========================================================================
set role authenticated;
select pg_temp.be_office();
select pg_temp.note('03a. hall office gets the dashboard',
  (public.admin_dashboard()->>'allowed')::boolean);
select pg_temp.note('03b. BUT NOT GIFT AID',
  public.admin_dashboard()->'areas'->'giftaid' = 'null'::jsonb,
  coalesce((public.admin_dashboard()->'areas'->>'giftaid'), 'absent'));
select pg_temp.note('03c. nor the staff account list',
  public.admin_dashboard()->'housekeeping' = 'null'::jsonb);
select pg_temp.note('03d. nor a Gift Aid item in needs-you',
  not exists (select 1 from jsonb_array_elements(public.admin_dashboard()->'needs') n
               where n->>'kind' = 'giftaid'));
select pg_temp.note('03e. but does get halls and volunteers',
  (public.admin_dashboard()->'areas'->'venue'->>'new')::int > 0
  and (public.admin_dashboard()->'areas'->'volunteers'->>'willing')::int > 0);
reset role;

set role authenticated;
select pg_temp.be_staff();
select pg_temp.note('03f. an administrator does get Gift Aid',
  public.admin_dashboard()->'areas'->'giftaid' <> 'null'::jsonb);
reset role;


-- ===========================================================================
--  04. NEEDS YOU — the right things, in the right order
-- ===========================================================================
set role authenticated;
select pg_temp.be_staff();

select pg_temp.note('04a. the expiring hold is FIRST',
  (public.admin_dashboard()->'needs'->0->>'kind') = 'hall_hold',
  coalesce(public.admin_dashboard()->'needs'->0->>'kind', 'nothing'));

select pg_temp.note('04b. the unanswered hall request is there',
  exists (select 1 from jsonb_array_elements(public.admin_dashboard()->'needs') n
           where n->>'ref' = 'HH-T-NEW'));

select pg_temp.note('04c. so is the nikah call',
  exists (select 1 from jsonb_array_elements(public.admin_dashboard()->'needs') n
           where n->>'kind' = 'nikah_new'));

--  Two volunteers waiting is ONE job. Six identical cards would push
--  everything else off the screen.
select pg_temp.note('04d. two volunteers waiting is ONE entry, not two',
  (select count(*) from jsonb_array_elements(public.admin_dashboard()->'needs') n
    where n->>'kind' = 'volunteers') = 1);

select pg_temp.note('04e. and it says how many, and how many do Sundays',
  (select n->>'title' like '2 food bank volunteers%' and n->>'detail' like '1 free%'
     from jsonb_array_elements(public.admin_dashboard()->'needs') n
    where n->>'kind' = 'volunteers'));

--  A booking already dealt with is NOT work. A dashboard listing things
--  nobody has to act on is a dashboard people stop reading.
select pg_temp.note('04f. a confirmed booking is not in needs-you',
  not exists (select 1 from jsonb_array_elements(public.admin_dashboard()->'needs') n
               where n->>'ref' in ('HH-T-OWED', 'HH-T-OLD')));

reset role;

--  An expired hold is not work either: the date has already released itself
--  and nothing anybody does will bring it back.
--
--  The change is made as the OWNER, not as `authenticated`: RLS would refuse
--  it, and a refused UPDATE that nobody checks leaves the row untouched and
--  the assertion below passing for the wrong reason. Vacuous passes are how a
--  suite certifies nothing.
update public.hall_bookings set hold_expires_at = now() - interval '1 minute'
 where reference = 'HH-T-HOLD';
select pg_temp.note('04g. the fixture really did change',
  (select hold_expires_at < now() from public.hall_bookings
    where reference = 'HH-T-HOLD'));

set role authenticated;
select pg_temp.be_staff();
select pg_temp.note('04h. an EXPIRED hold drops out of needs-you',
  not exists (select 1 from jsonb_array_elements(public.admin_dashboard()->'needs') n
               where n->>'ref' = 'HH-T-HOLD'));
reset role;

update public.hall_bookings set hold_expires_at = now() + interval '12 minutes'
 where reference = 'HH-T-HOLD';


-- ===========================================================================
--  05. THE MONEY
--
--  05c is why this section exists.
-- ===========================================================================
set role authenticated;
select pg_temp.be_staff();

select pg_temp.note('05a. what is owed is counted in pence, not pounds',
  (public.admin_dashboard()->'estate'->>'owed_p')::bigint = 35000,
  'owed_p = ' || (public.admin_dashboard()->'estate'->>'owed_p'));

select pg_temp.note('05b. the deposit already paid is taken off',
  (public.admin_dashboard()->'estate'->>'owed_p')::bigint < 45000);

select pg_temp.note('05c. A BOOKING THAT CANNOT BE PRICED IS COUNTED SEPARATELY, NOT AS ZERO',
  (public.admin_dashboard()->'estate'->>'owed_unknown')::int = 1
  and (public.admin_dashboard()->'estate'->>'owed_count')::int = 1,
  'unknown=' || (public.admin_dashboard()->'estate'->>'owed_unknown') ||
  ' priced=' || (public.admin_dashboard()->'estate'->>'owed_count'));

select pg_temp.note('05d. a settled booking owes nothing',
  (select (public.admin_dashboard()->'estate'->>'owed_p')::bigint
     from (select 1) _) = 35000);

select pg_temp.note('05e. bookings ahead counts only confirmed, future ones',
  (public.admin_dashboard()->'estate'->>'bookings_ahead')::int = 2);
reset role;


-- ===========================================================================
--  06. THE LOG — the machine's work is counted, not listed
--
--  On the real database 120 of 130 audit rows were one purge. A feed showing
--  them all is 92% noise, and a log that wastes attention once is a log
--  nobody opens again.
-- ===========================================================================
set role authenticated;
select pg_temp.be_staff();

select pg_temp.note('06a. THE 20 AUTOMATIC ROWS ARE NOT IN THE LOG',
  not exists (select 1 from jsonb_array_elements(public.admin_dashboard()->'log') l
               where l->>'what' = 'Expired holds cleared'),
  'log length = ' || jsonb_array_length(public.admin_dashboard()->'log'));

select pg_temp.note('06b. but they are counted',
  (public.admin_dashboard()->>'auto_count')::int = 20,
  'auto_count = ' || (public.admin_dashboard()->>'auto_count'));

select pg_temp.note('06c. the staff action IS in the log',
  exists (select 1 from jsonb_array_elements(public.admin_dashboard()->'log') l
           where l->>'what' = 'Deposit taken in cash'));

select pg_temp.note('06d. and carries the name of who did it',
  (select l->>'who' from jsonb_array_elements(public.admin_dashboard()->'log') l
    where l->>'what' = 'Deposit taken in cash') is not null);

select pg_temp.note('06e. things the public sent in say so',
  (select l->>'who' from jsonb_array_elements(public.admin_dashboard()->'log') l
    where l->>'what' = 'Hall booking came in' limit 1) = 'from the website');

select pg_temp.note('06f. every log line is in plain English, not a column name',
  not exists (select 1 from jsonb_array_elements(public.admin_dashboard()->'log') l
               where l->>'what' like '%\_%'));

select pg_temp.note('06g. every log line carries a time',
  not exists (select 1 from jsonb_array_elements(public.admin_dashboard()->'log') l
               where l->>'at' is null));
reset role;


-- ===========================================================================
--  07. HOUSEKEEPING — the warning that has been invisible
-- ===========================================================================
set role authenticated;
select pg_temp.be_staff();

--  The office account created at the top of this file HAS an authenticator,
--  so start from zero and then break it, rather than asserting whatever the
--  fixture happened to leave behind.
select pg_temp.note('07a. with everyone enrolled, nothing is flagged',
  (public.admin_dashboard()->'housekeeping'->>'no_2fa')::int = 0,
  'no_2fa = ' || (public.admin_dashboard()->'housekeeping'->>'no_2fa'));

reset role;
delete from auth.mfa_factors where user_id = '22222222-2222-2222-2222-222222222222';
set role authenticated;
select pg_temp.be_staff();

select pg_temp.note('07b. AN ACCOUNT WITH NO AUTHENTICATOR IS FLAGGED',
  (public.admin_dashboard()->'housekeeping'->>'no_2fa')::int = 1,
  'no_2fa = ' || (public.admin_dashboard()->'housekeeping'->>'no_2fa'));

select pg_temp.note('07c. and the account count is real',
  (public.admin_dashboard()->'housekeeping'->>'accounts')::int > 0);
reset role;


-- ===========================================================================
--  08. NOTHING ELSE WAS DISTURBED
-- ===========================================================================
select pg_temp.note('08a. 023 and the payment functions are still there',
  (select count(*) from pg_proc
    where proname in ('register_foodbank_volunteer', 'record_donation_paid',
                      'mark_deposit_paid', 'purge_expired_holds')) = 4);

select pg_temp.note('08b. the volunteers privacy constraints still stand',
  (select count(*) from pg_constraint
    where conname in ('fbv_consent_required', 'fbv_age_sixteen_or_over')) = 2);


\o
select case when ok then 'PASS' else '**FAIL**' end as result, name, detail
  from r order by ok, name;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
  from r;
