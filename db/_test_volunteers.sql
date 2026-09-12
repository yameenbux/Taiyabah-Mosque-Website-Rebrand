-- ===========================================================================
--  _test_volunteers.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 023, food bank volunteer registrations.
--
--  Run against a FRESHLY BUILT database:  bash db/harness/build.sh t_23 full
--  (or db/harness/run-all.sh, which knows the profile)
--
--  THE THREE ASSERTIONS THAT MATTER:
--
--    02c  a fourteen-year-old cannot get into this table, by any route,
--         including straight at the API with the website bypassed entirely
--    03b  a row cannot exist without consent — the lawful basis is a
--         constraint, not a tick box somebody could forget to check
--    06a  a signed-out stranger reads nothing at all
--
--  Everything else is housekeeping around those three.
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

create or replace function pg_temp.eok(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,true,'');
exception when others then insert into r values (l,false,left(sqlerrm,110)); end; end $$;

create or replace function pg_temp.be_staff() returns void language plpgsql as $$
begin
  perform set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
  perform set_config('test.aal', 'aal2', false);
end $$;

\o /dev/null


-- ===========================================================================
--  01. SOMEBODY REGISTERS
-- ===========================================================================
select public.register_foodbank_volunteer($${
  "full_name":"Aisha Patel", "phone":"07700 900 101", "email":"Aisha@Example.Test",
  "gender":"female", "age":34, "preferred_contact":"text",
  "sunday_mornings":true, "frequency":"weekly",
  "skills":"Driver, food hygiene level 2", "consent":true }$$::jsonb);

select pg_temp.note('a registration is stored',
  (select count(*) from public.foodbank_volunteers) = 1);

select pg_temp.note('and carries a reference beginning FV-',
  (select reference like 'FV-%' from public.foodbank_volunteers limit 1),
  coalesce((select reference from public.foodbank_volunteers limit 1), 'none'));

select pg_temp.note('it starts as waiting to be contacted',
  (select status = 'waiting' and contacted_at is null
     from public.foodbank_volunteers limit 1));

select pg_temp.note('the email is stored folded to lower case',
  (select email = 'aisha@example.test' from public.foodbank_volunteers limit 1),
  coalesce((select email from public.foodbank_volunteers limit 1), 'null'));

select pg_temp.note('consent is stamped with a time',
  (select consent and consented_at is not null from public.foodbank_volunteers limit 1));


-- ===========================================================================
--  02. SIXTEEN IS THE FLOOR — AND IT IS THE DATABASE THAT SAYS SO
--
--  02c is the assertion this file exists for. A check that lives only in the
--  browser does not exist: the anon key is in the page source, the API is
--  public, and anybody can post whatever they like at it. If a child's name,
--  mobile and email can be made to land in this table, the masjid is holding
--  a child's contact details gathered with no parent anywhere near it — and
--  holding them for a year.
-- ===========================================================================
select pg_temp.efail('02a. a fifteen-year-old is refused',
  $$select public.register_foodbank_volunteer($x${
    "full_name":"Young Person","phone":"07700900102","gender":"male","age":15,
    "preferred_contact":"phone","sunday_mornings":true,"frequency":"weekly",
    "consent":true}$x$::jsonb)$$);

select pg_temp.efail('02b. and so is an age that is not a number',
  $$select public.register_foodbank_volunteer($x${
    "full_name":"Mistyped Age","phone":"07700900103","gender":"male","age":"sixteen",
    "preferred_contact":"phone","sunday_mornings":true,"frequency":"weekly",
    "consent":true}$x$::jsonb)$$);

select pg_temp.efail('02c. A CHILD CANNOT BE INSERTED DIRECTLY EITHER',
  $$insert into public.foodbank_volunteers
      (reference, full_name, phone, gender, age, preferred_contact,
       sunday_mornings, frequency, consent)
    values ('FV-T-0014','A Child','07700900104','male',14,'phone',true,'weekly',true)$$);

select pg_temp.efail('02d. nor a year of birth typed into the age box',
  $$insert into public.foodbank_volunteers
      (reference, full_name, phone, gender, age, preferred_contact,
       sunday_mornings, frequency, consent)
    values ('FV-T-2026','Year Of Birth','07700900105','male',1992,'phone',true,'weekly',true)$$);

select pg_temp.eok('02e. sixteen exactly is allowed',
  $$select public.register_foodbank_volunteer($x${
    "full_name":"Just Sixteen","phone":"07700900106","gender":"female","age":16,
    "preferred_contact":"phone","sunday_mornings":true,"frequency":"monthly",
    "consent":true}$x$::jsonb)$$);


-- ===========================================================================
--  03. CONSENT IS THE LAWFUL BASIS
-- ===========================================================================
select pg_temp.efail('03a. registering without agreeing is refused',
  $$select public.register_foodbank_volunteer($x${
    "full_name":"No Consent","phone":"07700900107","gender":"male","age":40,
    "preferred_contact":"phone","sunday_mornings":false,"frequency":"monthly",
    "consent":false}$x$::jsonb)$$);

select pg_temp.efail('03b. A ROW WITHOUT CONSENT CANNOT EXIST AT ALL',
  $$insert into public.foodbank_volunteers
      (reference, full_name, phone, gender, age, preferred_contact,
       sunday_mornings, frequency, consent)
    values ('FV-T-NOC','No Consent Direct','07700900108','male',40,'phone',
            false,'monthly',false)$$);


-- ===========================================================================
--  04. THE FIELDS THE ROTA IS BUILT FROM HAVE TO MEAN SOMETHING
-- ===========================================================================
select pg_temp.efail('04a. an unknown frequency is refused',
  $$insert into public.foodbank_volunteers
      (reference, full_name, phone, gender, age, preferred_contact,
       sunday_mornings, frequency, consent)
    values ('FV-T-FRQ','Odd Frequency','07700900109','male',40,'phone',
            true,'whenever',true)$$);

select pg_temp.efail('04b. an unknown contact method is refused',
  $$insert into public.foodbank_volunteers
      (reference, full_name, phone, gender, age, preferred_contact,
       sunday_mornings, frequency, consent)
    values ('FV-T-PRF','Odd Method','07700900110','male',40,'carrier pigeon',
            true,'weekly',true)$$);

--  Choosing email and giving no email address is a volunteer nobody can reach.
select pg_temp.efail('04c. email-preferred with no email address is refused',
  $$insert into public.foodbank_volunteers
      (reference, full_name, phone, gender, age, preferred_contact,
       sunday_mornings, frequency, consent)
    values ('FV-T-NOE','No Address','07700900111','male',40,'email',
            true,'weekly',true)$$);

select pg_temp.efail('04d. and the function refuses it too',
  $$select public.register_foodbank_volunteer($x${
    "full_name":"No Address Fn","phone":"07700900112","gender":"male","age":40,
    "preferred_contact":"email","sunday_mornings":true,"frequency":"weekly",
    "consent":true}$x$::jsonb)$$);

select pg_temp.efail('04e. a phone number too short to ring is refused',
  $$select public.register_foodbank_volunteer($x${
    "full_name":"Short Number","phone":"0770","gender":"male","age":40,
    "preferred_contact":"phone","sunday_mornings":true,"frequency":"weekly",
    "consent":true}$x$::jsonb)$$);


-- ===========================================================================
--  05. REGISTERING TWICE IS ONE VOLUNTEER
--
--  Somebody who fills the form in again a fortnight later must not appear in
--  the office's list twice. Two rows for one person is how a rota ends up
--  double-counting the willing.
-- ===========================================================================
select public.register_foodbank_volunteer($${
  "full_name":"Aisha Patel", "phone":"07700900101", "email":"aisha@example.test",
  "gender":"female", "age":35, "preferred_contact":"phone",
  "sunday_mornings":false, "frequency":"monthly", "consent":true }$$::jsonb);

select pg_temp.note('05a. registering again does not add a second row',
  (select count(*) from public.foodbank_volunteers
    where regexp_replace(phone,'\D','','g') = '07700900101') = 1,
  'rows: ' || (select count(*)::text from public.foodbank_volunteers
                where regexp_replace(phone,'\D','','g') = '07700900101'));

--  Spaces in the first number and none in the second: the match is on digits,
--  not on the string, because nobody types a phone number the same way twice.
select pg_temp.note('05b. it updates what they told us the second time',
  (select age = 35 and frequency = 'monthly' and not sunday_mornings
     from public.foodbank_volunteers
    where regexp_replace(phone,'\D','','g') = '07700900101'));

select pg_temp.note('05c. and hands back the reference they already had',
  (select (public.register_foodbank_volunteer($${
     "full_name":"Aisha Patel","phone":"07700900101","gender":"female","age":35,
     "preferred_contact":"phone","sunday_mornings":false,"frequency":"monthly",
     "consent":true}$$::jsonb)->>'already')::boolean));


-- ===========================================================================
--  06. WHO CAN SEE ANY OF THIS
-- ===========================================================================
--  Stronger than "RLS filters the rows out": the anon role has no SELECT on
--  this table at all, so the attempt is refused before any policy is
--  consulted. Written as efail rather than a row count for exactly that
--  reason — a count would abort the suite on "permission denied", which is
--  the right answer arriving in the wrong shape.
set role anon;
select pg_temp.efail('06a. A SIGNED-OUT STRANGER CANNOT READ THE TABLE AT ALL',
  $$select count(*) from public.foodbank_volunteers$$);

select pg_temp.efail('06b. and cannot write to the table directly',
  $$insert into public.foodbank_volunteers
      (reference, full_name, phone, gender, age, preferred_contact,
       sunday_mornings, frequency, consent)
    values ('FV-T-ANON','Sneaky','07700900113','male',40,'phone',true,'weekly',true)$$);

select pg_temp.efail('06c. nor read the office summary',
  $$select public.foodbank_volunteer_summary()$$);
reset role;

--  Supabase grants ALL on a new public table to anon AND authenticated by
--  default, so the migration's "grant select, update" added to a full set
--  rather than describing it. RLS was still blocking the writes, because
--  there is no INSERT or DELETE policy — but a table protected only by the
--  absence of a policy is one careless "for all" away from being writable by
--  any signed-in user. Found by reading the grants back off production, which
--  is the only way anybody finds it.
select pg_temp.note('06f. authenticated holds no INSERT on the table',
  (select count(*) from information_schema.role_table_grants
    where table_name = 'foodbank_volunteers' and grantee = 'authenticated'
      and privilege_type = 'INSERT') = 0);

select pg_temp.note('06g. nor DELETE',
  (select count(*) from information_schema.role_table_grants
    where table_name = 'foodbank_volunteers' and grantee = 'authenticated'
      and privilege_type = 'DELETE') = 0);

select pg_temp.note('06h. and anon holds nothing at all',
  (select count(*) from information_schema.role_table_grants
    where table_name = 'foodbank_volunteers' and grantee = 'anon') = 0);

--  Signed in but never completed two-step. 011's whole point.
set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal1', false);
select pg_temp.note('06d. an admin who has not done two-step sees nothing',
  (select count(*) from public.foodbank_volunteers) = 0);
reset role;

set role authenticated;
select pg_temp.be_staff();
select pg_temp.note('06e. a verified administrator sees the list',
  (select count(*) from public.foodbank_volunteers) > 0);
reset role;


-- ===========================================================================
--  07. WHAT THE OFFICE ACTUALLY WANTED: HOW MANY, AND WHO TO RING
-- ===========================================================================
set role authenticated;
select pg_temp.be_staff();

select pg_temp.note('07a. the summary counts everybody',
  (public.foodbank_volunteer_summary()->>'total')::int
    = (select count(*) from public.foodbank_volunteers));

select pg_temp.note('07b. and counts Sunday mornings separately',
  (public.foodbank_volunteer_summary()->>'sundays')::int
    = (select count(*) from public.foodbank_volunteers
        where sunday_mornings and status <> 'withdrawn'));

select pg_temp.eok('07c. the office can mark somebody contacted',
  $$select public.set_volunteer_status(
      (select reference from public.foodbank_volunteers order by created_at limit 1),
      'contacted', 'Rang, happy to help Sundays')$$);

select pg_temp.note('07d. which stamps who did it and when',
  (select contacted_at is not null and contacted_by is not null
     from public.foodbank_volunteers order by created_at limit 1));

select pg_temp.note('07e. and is written to the audit trail',
  (select count(*) from public.admin_audit where action = 'volunteer_status') > 0);

select pg_temp.efail('07f. an unknown status is refused',
  $$select public.set_volunteer_status(
      (select reference from public.foodbank_volunteers order by created_at limit 1),
      'maybe')$$);

--  A withdrawn volunteer drops out of the counts the rota is built from, but
--  the row stays until the purge — the masjid needs to know not to ring them.
select public.set_volunteer_status(
  (select reference from public.foodbank_volunteers order by created_at desc limit 1),
  'withdrawn');
select pg_temp.note('07g. somebody who withdraws leaves the rota counts',
  (public.foodbank_volunteer_summary()->>'sundays')::int
    < (select count(*) from public.foodbank_volunteers where sunday_mornings));
reset role;


-- ===========================================================================
--  08. TWELVE MONTHS, AND THE PURGE THAT KEEPS THE PROMISE
--
--  The website tells people twelve months. 015 is the record of what happens
--  when a retention promise depends on somebody remembering: three of them
--  had quietly not been kept for months.
-- ===========================================================================
insert into public.foodbank_volunteers
  (reference, full_name, phone, gender, age, preferred_contact,
   sunday_mornings, frequency, consent, created_at)
values ('FV-T-OLD','Long Ago','07700900199','male',50,'phone',true,'monthly',true,
        now() - interval '13 months'),
       ('FV-T-NEW','Last Month','07700900198','female',50,'phone',true,'monthly',true,
        now() - interval '11 months');

select pg_temp.note('08a. a dry run deletes nothing',
  (public.purge_old_volunteers(true)->>'would_delete')::int = 1
  and (select count(*) from public.foodbank_volunteers where reference = 'FV-T-OLD') = 1);

select public.purge_old_volunteers();

select pg_temp.note('08b. THIRTEEN MONTHS OLD IS GONE',
  (select count(*) from public.foodbank_volunteers where reference = 'FV-T-OLD') = 0);

select pg_temp.note('08c. eleven months old is kept',
  (select count(*) from public.foodbank_volunteers where reference = 'FV-T-NEW') = 1);

select pg_temp.note('08d. and the purge is recorded',
  (select count(*) from public.admin_audit where action = 'volunteers_purged') > 0);

--  Nobody with a browser runs this, by GRANT rather than by an is_admin()
--  check — pg_cron holds no JWT, so a purge that asked "are you an admin?"
--  would raise every night and delete nothing. See 015 section 1.
set role anon;
select pg_temp.efail('08e. the public cannot run the purge',
  $$select public.purge_old_volunteers()$$);
reset role;
set role authenticated;
select pg_temp.be_staff();
select pg_temp.efail('08f. nor can an administrator from the browser',
  $$select public.purge_old_volunteers()$$);
reset role;


-- ===========================================================================
--  09. NOTHING ELSE WAS DISTURBED
-- ===========================================================================
select pg_temp.note('09a. 022 and the payment functions are still there',
  (select count(*) from pg_proc
    where proname in ('record_donation_paid','mark_deposit_paid',
                      'mark_nikah_fee_paid','purge_expired_holds')) = 4);

select pg_temp.note('09b. the donations privacy constraint still stands',
  (select count(*) from pg_constraint
    where conname = 'no_donor_data_without_gift_aid') = 1);


\o
select case when ok then 'PASS' else '**FAIL**' end as result, name, detail
  from r order by ok, name;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
  from r;
