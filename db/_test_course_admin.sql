-- ===========================================================================
--  _test_course_admin.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 013: promote_from_waiting() gives out a place without ever
--  letting anybody put more people in a room than it holds, and the column it
--  writes stays out of reach of the browser.
--
--  Run against a database built from, in order:
--      _test_supabase_stub.sql (madrasah-db)
--      001 .. 006  (madrasah-db)      -- 007 needs pg_cron, which isn't local
--      008, 009, 010, 011, 013        (this folder)
--
--  Every assertion runs as `authenticated` or `anon`, never as a superuser.
--  Test 00 proves that role really is subject to RLS; without it this file
--  could pass while proving nothing, which has happened on this project before.
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


-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@example.test'),
  ('33333333-3333-3333-3333-333333333333', 'customer@example.test')
on conflict (id) do nothing;

insert into public.profiles (id, full_name, email) values
  ('11111111-1111-1111-1111-111111111111', 'An Administrator', 'admin@example.test'),
  ('33333333-3333-3333-3333-333333333333', 'A Shop Customer',  'customer@example.test')
on conflict (id) do nothing;

insert into public.user_roles (user_id, role)
values ('11111111-1111-1111-1111-111111111111', 'admin')
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- A course that holds exactly one person.
--
-- Capacity 1 is not a shortcut. Every interesting case in this file is about
-- the boundary — the last seat, the seat that just came free — and a course
-- with fifteen seats needs fifteen fixtures to reach it.
-- ---------------------------------------------------------------------------
insert into public.courses (key, name, cohort_mode, capacity, is_open, sort_order)
values ('tiny', 'A Very Small Class', 'separate', 1, true, 99)
on conflict (key) do update set capacity = 1, is_open = true;

-- Signed up the way the public actually signs up, through the function, as
-- anon. Inserting rows by hand here would skip the very logic under test.
set role anon;
select set_config('test.uid', '', false);
select set_config('test.aal', '', false);

select public.register_for_course(jsonb_build_object(
  'course_key','tiny','cohort','mens','first_name','Imran','surname','Ali',
  'email','imran@example.test','mobile','07700900111',
  'age_confirmed', true, 'privacy_accepted', true));

select public.register_for_course(jsonb_build_object(
  'course_key','tiny','cohort','mens','first_name','Bilal','surname','Khan',
  'email','bilal@example.test','mobile','07700900222',
  'age_confirmed', true, 'privacy_accepted', true));
reset role;

select pg_temp.note('the first person got the only place',
  (select outcome from public.course_registrations
    where course_key='tiny' and email='imran@example.test') = 'place');
select pg_temp.note('the second person went on the waiting list',
  (select outcome from public.course_registrations
    where course_key='tiny' and email='bilal@example.test') = 'waiting');


-- ===========================================================================
--  00. Does this test mean anything at all?
-- ===========================================================================
select pg_temp.note('the test role is subject to RLS',
  not rolsuper and not rolbypassrls,
  'super=' || rolsuper || ' bypassrls=' || rolbypassrls)
from pg_roles where rolname = 'authenticated';


-- ===========================================================================
--  01. Who may give out a place
-- ===========================================================================
set role authenticated;

-- A shop customer who has set up an authenticator is still a shop customer.
select set_config('test.uid', '33333333-3333-3333-3333-333333333333', false);
select set_config('test.aal', 'aal2', false);
select pg_temp.efail('a verified customer cannot give out a place',
  $$select public.promote_from_waiting(
      (select id from public.course_registrations where email='bilal@example.test'))$$);

-- An administrator who has not entered a code is not an administrator for
-- this purpose. Same rule 011 applied to everything else.
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal1', false);
select pg_temp.efail('an admin at aal1 cannot give out a place',
  $$select public.promote_from_waiting(
      (select id from public.course_registrations where email='bilal@example.test'))$$);
reset role;


-- ===========================================================================
--  02. The cap holds
--
--  This is the reason 013 exists as a function rather than a wider column
--  grant. The room holds one. Somebody is already in it. The waiting person
--  must be refused, even though an administrator asked nicely.
-- ===========================================================================
set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal2', false);

select pg_temp.efail('a verified admin cannot overfill the session',
  $$select public.promote_from_waiting(
      (select id from public.course_registrations where email='bilal@example.test'))$$);

select pg_temp.note('the refusal changed nothing',
  (select outcome from public.course_registrations
    where email='bilal@example.test') = 'waiting');


-- ===========================================================================
--  03. A seat comes free
-- ===========================================================================
update public.course_registrations
   set status = 'withdrawn', reviewed_at = now()
 where email = 'imran@example.test' and course_key = 'tiny';

select pg_temp.note('withdrawing freed the seat',
  (select count(*) from public.course_registrations
    where course_key='tiny' and cohort='mens'
      and outcome='place' and status='active') = 0);

select pg_temp.eok('now the waiting person can be given the place',
  $$select public.promote_from_waiting(
      (select id from public.course_registrations where email='bilal@example.test'))$$);

select pg_temp.note('and they actually hold it',
  (select outcome from public.course_registrations
    where email='bilal@example.test') = 'place');

select pg_temp.note('who did it was recorded',
  (select reviewed_by from public.course_registrations
    where email='bilal@example.test') = '11111111-1111-1111-1111-111111111111');

-- Pressing the button twice must not be an error, and must not take a second
-- seat. An office that has to be careful with a button will one day not be.
select pg_temp.note('giving the same place again is a no-op',
  (public.promote_from_waiting(
     (select id from public.course_registrations where email='bilal@example.test'))
   ->> 'changed') = 'false');


-- ===========================================================================
--  04. Somebody who withdrew does not quietly come back
-- ===========================================================================
update public.course_registrations
   set status = 'withdrawn'
 where email = 'bilal@example.test' and course_key = 'tiny';

select pg_temp.efail('a withdrawn registration cannot be given a place',
  $$select public.promote_from_waiting(
      (select id from public.course_registrations where email='bilal@example.test'))$$);


-- ===========================================================================
--  05. The column stays out of the browser's reach
--
--  013 must not have quietly widened the grant. If this ever passes as a
--  SUCCESS, the capacity cap has become advisory.
-- ===========================================================================
select pg_temp.efail('an admin still cannot write outcome directly',
  $$update public.course_registrations set outcome = 'place'
     where email = 'bilal@example.test'$$);

select pg_temp.efail('an admin still cannot edit somebody''s name',
  $$update public.course_registrations set first_name = 'Someone Else'
     where email = 'bilal@example.test'$$);

select pg_temp.efail('an admin still cannot delete a registration',
  $$delete from public.course_registrations where email = 'bilal@example.test'$$);
reset role;


-- ===========================================================================
--  06. The trail
-- ===========================================================================
select pg_temp.note('giving out a place is in the audit log',
  exists (select 1 from public.admin_audit
           where action = 'course_place_given'
             and detail ->> 'course' = 'tiny'
             and actor = '11111111-1111-1111-1111-111111111111'));


-- ===========================================================================
--  07. The public is untouched
-- ===========================================================================
-- The id is captured BEFORE dropping to anon. Looking it up as anon fails on
-- the SELECT, not on the function — which would have made this assertion pass
-- without ever calling the thing it claims to test.
select set_config('app.tiny_id',
  (select id::text from public.course_registrations where email = 'bilal@example.test'),
  false);

set role anon;
select set_config('test.uid', '', false);
select set_config('test.aal', '', false);

select pg_temp.efail('the public cannot give out a place',
  $$select public.promote_from_waiting(current_setting('app.tiny_id')::uuid)$$);

select pg_temp.eok('the public can still sign up for a class',
  $$select public.register_for_course(jsonb_build_object(
      'course_key','arabic','cohort','womens','first_name','Maryam','surname','Begum',
      'email','maryam@example.test','mobile','07700900333',
      'age_confirmed', true, 'privacy_accepted', true))$$);
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
