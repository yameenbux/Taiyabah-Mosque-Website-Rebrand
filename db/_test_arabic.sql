-- ===========================================================================
--  _test_arabic.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves 004_arabic_classes.sql. As in _test_admissions.sql, ownership is
--  moved to a NOSUPERUSER NOBYPASSRLS role first — a superuser ignores RLS,
--  so testing as one proves nothing about production.
--
--  The interesting assertion is the cap: fifteen get a place, the sixteenth
--  gets a waiting-list position, and the two classes count separately.
-- ===========================================================================
\set ON_ERROR_STOP on

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'app_owner') then
    create role app_owner nosuperuser nobypassrls login;
  end if;
end $$;
alter table public.arabic_class_registrations owner to app_owner;
alter sequence public.arabic_reference_seq owner to app_owner;
alter function public.register_for_arabic_class(jsonb)      owner to app_owner;
alter function public.purge_old_arabic_registrations(int)   owner to app_owner;
grant insert on public.admin_audit to app_owner;
grant usage, select on sequence public.admin_audit_id_seq to app_owner;
grant usage on schema public to anon, authenticated, app_owner;

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated, app_owner;

create or replace function pg_temp.efail(label text, stmt text) returns void
language plpgsql as $$ begin
  begin execute stmt; set constraints all immediate;
    insert into r values (label, false, 'unexpectedly SUCCEEDED');
  exception when others then insert into r values (label, true, left(sqlerrm,58)); end;
end $$;

create or replace function pg_temp.eok(label text, stmt text) returns void
language plpgsql as $$ begin
  begin execute stmt; insert into r values (label, true, '');
  exception when others then insert into r values (label, false, left(sqlerrm,80)); end;
end $$;

create or replace function pg_temp.signup(n int, coh text) returns jsonb
language plpgsql as $$ begin
  return public.register_for_arabic_class(jsonb_build_object(
    'cohort', coh, 'first_name', 'Test', 'surname', 'Person' || n,
    'email', 'p' || n || '.' || coh || '@example.com', 'mobile', '07700900' || lpad(n::text,3,'0'),
    'experience','none','age_confirmed',true,'privacy_accepted',true));
end $$;

-- 1. anon cannot touch the table, only call the function
set role anon;
select pg_temp.efail('anon cannot SELECT registrations','select * from public.arabic_class_registrations');
select pg_temp.efail('anon cannot INSERT directly',
  $q$insert into public.arabic_class_registrations(reference,cohort,first_name,surname,email,mobile,
     experience,age_confirmed,privacy_accepted,outcome)
     values('X','mens','a','b','a@b.co','07','none',true,true,'place')$q$);
select pg_temp.efail('anon cannot UPDATE','update public.arabic_class_registrations set outcome=''place''');
select pg_temp.efail('anon cannot DELETE','delete from public.arabic_class_registrations');
reset role;

-- 2. fill the men's class: 15 places then overflow
set role anon;
do $$ declare i int; res jsonb; begin
  for i in 1..15 loop res := pg_temp.signup(i,'mens'); end loop;
  insert into r select 'fifteenth sign-up still gets a place', res->>'outcome' = 'place', res->>'outcome';
  insert into r select 'places_left reaches zero at fifteen', (res->>'places_left')::int = 0, res->>'places_left';
  res := pg_temp.signup(16,'mens');
  insert into r select 'sixteenth goes on the waiting list', res->>'outcome' = 'waiting', res->>'outcome';
  insert into r select 'waiting position is 1', (res->>'waiting_position')::int = 1, res->>'waiting_position';
  res := pg_temp.signup(17,'mens');
  insert into r select 'seventeenth is waiting position 2', (res->>'waiting_position')::int = 2, res->>'waiting_position';
  -- the women's class counts separately
  res := pg_temp.signup(1,'womens');
  insert into r select 'womens class has its own fifteen', res->>'outcome' = 'place', res->>'outcome';
end $$;

-- 3. duplicates and bad input
select pg_temp.efail('same email cannot join the same class twice',
  $q$select pg_temp.signup(1,'mens')$q$);
select pg_temp.efail('cohort must be mens or womens',
  $q$select public.register_for_arabic_class('{"cohort":"everyone","first_name":"a","surname":"b",
     "email":"z@b.co","mobile":"07","experience":"none","age_confirmed":true,"privacy_accepted":true}'::jsonb)$q$);
select pg_temp.efail('age must be confirmed',
  $q$select public.register_for_arabic_class('{"cohort":"mens","first_name":"a","surname":"b",
     "email":"y@b.co","mobile":"07","experience":"none","age_confirmed":false,"privacy_accepted":true}'::jsonb)$q$);
select pg_temp.efail('email must look like an email',
  $q$select public.register_for_arabic_class('{"cohort":"mens","first_name":"a","surname":"b",
     "email":"not-an-email","mobile":"07","experience":"none","age_confirmed":true,"privacy_accepted":true}'::jsonb)$q$);
reset role;

-- 4. a withdrawn registration frees the seat, and the same person may re-register
set role authenticated; set app.is_admin = 'on';
insert into r select 'admin can read the register', count(*) = 18, count(*)::text
  from public.arabic_class_registrations;
update public.arabic_class_registrations set status = 'withdrawn'
 where email = 'p1.mens@example.com';
reset role;
set role anon;
select pg_temp.eok('re-registering after withdrawal is allowed',
  $q$select pg_temp.signup(1,'mens')$q$);
reset role;

-- 5. a signed-in non-admin sees nothing
set role authenticated; set app.is_admin = 'off';
insert into r select 'non-admin reads zero rows', count(*) = 0, count(*)::text
  from public.arabic_class_registrations;
select pg_temp.efail('non-admin cannot purge','select public.purge_old_arabic_registrations(12)');
reset role;

\echo ''
\echo '=============== ARABIC CLASS RESULTS ==============='
select case when ok then 'PASS' else 'FAIL' end as res, name, detail from r order by ok, name;
select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from r;
