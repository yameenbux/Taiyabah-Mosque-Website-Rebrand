-- ===========================================================================
--  _test_courses.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--  Ownership moves to a NOSUPERUSER NOBYPASSRLS role first: a superuser
--  ignores RLS, so testing as one proves nothing about production.
-- ===========================================================================
\set ON_ERROR_STOP on

do $$ begin
  if not exists (select 1 from pg_roles where rolname='app_owner') then
    create role app_owner nosuperuser nobypassrls login; end if; end $$;
alter table public.courses               owner to app_owner;
alter table public.course_registrations  owner to app_owner;
alter sequence public.course_reference_seq owner to app_owner;
alter function public.register_for_course(jsonb)            owner to app_owner;
alter function public.purge_old_course_registrations(int)   owner to app_owner;
grant insert on public.admin_audit to app_owner;
grant usage, select on sequence public.admin_audit_id_seq to app_owner;
grant usage on schema public to anon, authenticated, app_owner;

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated, app_owner;

create or replace function pg_temp.efail(l text, s text) returns void language plpgsql as $$
begin begin execute s; set constraints all immediate;
  insert into r values (l,false,'unexpectedly SUCCEEDED');
exception when others then insert into r values (l,true,left(sqlerrm,58)); end; end $$;
create or replace function pg_temp.eok(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,true,'');
exception when others then insert into r values (l,false,left(sqlerrm,80)); end; end $$;
create or replace function pg_temp.signup(n int, k text, coh text) returns jsonb
language plpgsql as $$ begin
  return public.register_for_course(jsonb_build_object(
    'course_key',k,'cohort',coh,'first_name','Test','surname','P'||n,
    'email','p'||n||'.'||k||'.'||coh||'@example.com','mobile','07700900'||lpad(n::text,3,'0'),
    'experience','none','age_confirmed',true,'privacy_accepted',true)); end $$;

-- 1. anon may only call the function
set role anon;
select pg_temp.efail('anon cannot read courses','select * from public.courses');
select pg_temp.efail('anon cannot read registrations','select * from public.course_registrations');
select pg_temp.efail('anon cannot insert a registration',
  $q$insert into public.course_registrations(reference,course_key,cohort,first_name,surname,email,
     mobile,age_confirmed,privacy_accepted,outcome)
     values('X','arabic','mens','a','b','a@b.co','07',true,true,'place')$q$);
select pg_temp.efail('anon cannot change a course capacity',
  'update public.courses set capacity = 999');
reset role;

-- 2. the cap, per course AND per cohort
set role anon;
do $$ declare i int; res jsonb; begin
  for i in 1..15 loop res := pg_temp.signup(i,'arabic','mens'); end loop;
  insert into r select 'arabic mens: 15th still gets a place', res->>'outcome'='place', res->>'outcome';
  insert into r select 'arabic mens: places_left hits 0',(res->>'places_left')::int=0, res->>'places_left';
  res := pg_temp.signup(16,'arabic','mens');
  insert into r select 'arabic mens: 16th waits', res->>'outcome'='waiting', res->>'outcome';
  insert into r select 'arabic mens: waiting position 1',(res->>'waiting_position')::int=1, res->>'waiting_position';
  res := pg_temp.signup(1,'arabic','womens');
  insert into r select 'arabic womens counts separately', res->>'outcome'='place', res->>'outcome';
  res := pg_temp.signup(1,'ghusl','mens');
  insert into r select 'ghusl counts separately from arabic', res->>'outcome'='place', res->>'outcome';
  insert into r select 'response names the course', res->>'course'='Ghusl Workshop', res->>'course';
  insert into r select 'reference is prefixed per course', left(res->>'reference',3)='GH-', res->>'reference';
end $$;
reset role;

-- 3. bad input
set role anon;
select pg_temp.efail('unknown course is refused',
  $q$select pg_temp.signup(90,'basket_weaving','mens')$q$);
select pg_temp.efail('separate-cohort course demands a cohort',
  $q$select public.register_for_course('{"course_key":"arabic","first_name":"a","surname":"b",
     "email":"q@b.co","mobile":"07","age_confirmed":true,"privacy_accepted":true}'::jsonb)$q$);
select pg_temp.efail('age must be confirmed',
  $q$select public.register_for_course('{"course_key":"arabic","cohort":"mens","first_name":"a",
     "surname":"b","email":"w@b.co","mobile":"07","age_confirmed":false,"privacy_accepted":true}'::jsonb)$q$);
select pg_temp.efail('email must look like an email',
  $q$select public.register_for_course('{"course_key":"arabic","cohort":"mens","first_name":"a",
     "surname":"b","email":"nope","mobile":"07","age_confirmed":true,"privacy_accepted":true}'::jsonb)$q$);
select pg_temp.efail('same email twice on the same course',
  $q$select pg_temp.signup(1,'arabic','mens')$q$);
select pg_temp.eok('same email on a DIFFERENT course is fine',
  $q$select public.register_for_course('{"course_key":"ghusl","cohort":"womens","first_name":"a",
     "surname":"b","email":"p1.arabic.mens@example.com","mobile":"07",
     "age_confirmed":true,"privacy_accepted":true}'::jsonb)$q$);
reset role;

-- 4. the office can close a course without a code change
set role app_owner;
update public.courses set is_open = false where key = 'ghusl';
reset role;
set role anon;
select pg_temp.efail('a closed course refuses sign-ups',
  $q$select pg_temp.signup(50,'ghusl','mens')$q$);
reset role;
set role app_owner; update public.courses set is_open = true where key='ghusl'; reset role;

-- 5. withdrawal frees the seat
set role authenticated; set app.is_admin='on';
insert into r select 'admin can read the register', count(*) > 15, count(*)::text
  from public.course_registrations;
update public.course_registrations set status='withdrawn'
 where email='p1.arabic.mens@example.com' and course_key='arabic';
reset role;
set role anon;
select pg_temp.eok('re-registering after withdrawal is allowed',
  $q$select pg_temp.signup(1,'arabic','mens')$q$);
reset role;

-- 6. non-admins see nothing
set role authenticated; set app.is_admin='off';
insert into r select 'non-admin reads zero registrations', count(*)=0, count(*)::text
  from public.course_registrations;
insert into r select 'non-admin reads zero courses', count(*)=0, count(*)::text
  from public.courses;
select pg_temp.efail('non-admin cannot purge','select public.purge_old_course_registrations(12)');
reset role;

\echo ''
\echo '================= COURSE RESULTS ================='
select case when ok then 'PASS' else 'FAIL' end as res, name, detail from r order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from r;
