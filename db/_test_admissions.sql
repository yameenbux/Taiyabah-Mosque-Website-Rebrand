-- ===========================================================================
--  _test_admissions.sql — LOCAL ONLY. NEVER RUN THIS AGAINST SUPABASE.
--
--  Proves the security properties of 008_admissions.sql against a throwaway
--  local Postgres 16. Files beginning _test_ touch data and roles directly.
--
--    createdb taiyabah_test
--    psql -d taiyabah_test -f _test_stubs.sql
--    psql -d taiyabah_test -f 008_admissions.sql
--    psql -d taiyabah_test -f _test_admissions.sql
--
--  The migration's own tests once passed because the harness created the very
--  grants it was meant to be checking for. The trap here is different but the
--  same shape: locally the objects are owned by a SUPERUSER, and a superuser
--  ignores RLS entirely — so a broken policy set still passes. This file
--  therefore hands ownership to a NOSUPERUSER NOBYPASSRLS role first, which is
--  what Supabase actually looks like. Do not remove that step.
-- ===========================================================================

\set ON_ERROR_STOP on
\timing off

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'app_owner') then
    create role app_owner nosuperuser nobypassrls login;
  end if;
end $$;

alter table public.admission_applications    owner to app_owner;
alter table public.admission_students        owner to app_owner;
alter table public.admission_student_choices owner to app_owner;
alter table public.admission_contacts        owner to app_owner;
alter sequence public.admission_reference_seq owner to app_owner;
alter function public.submit_admission_application(jsonb)      owner to app_owner;
alter function public.purge_old_admission_applications(int)    owner to app_owner;
grant insert on public.admin_audit to app_owner;
grant usage, select on sequence public.admin_audit_id_seq to app_owner;
grant usage on schema public to anon, authenticated, app_owner;

create temporary table results(name text, ok boolean, detail text);
grant all on results to anon, authenticated, app_owner;

create or replace function pg_temp.expect_fail(label text, stmt text) returns void
language plpgsql as $$
begin
  begin
    execute stmt;
    -- one_class_per_preference is DEFERRABLE INITIALLY DEFERRED, so without
    -- this it would not fire until commit — long after this block decided the
    -- statement had succeeded.
    set constraints all immediate;
    insert into results values (label, false, 'statement unexpectedly SUCCEEDED');
  exception when others then
    insert into results values (label, true, left(sqlerrm, 60));
  end;
end $$;

create or replace function pg_temp.expect_ok(label text, stmt text) returns void
language plpgsql as $$
begin
  begin
    execute stmt;
    insert into results values (label, true, '');
  exception when others then
    insert into results values (label, false, left(sqlerrm, 90));
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 1. anon must not be able to touch any table directly
-- ---------------------------------------------------------------------------
set role anon;
select pg_temp.expect_fail('anon cannot SELECT applications', 'select * from public.admission_applications');
select pg_temp.expect_fail('anon cannot SELECT students',     'select * from public.admission_students');
select pg_temp.expect_fail('anon cannot SELECT choices',      'select * from public.admission_student_choices');
select pg_temp.expect_fail('anon cannot SELECT contacts',     'select * from public.admission_contacts');
select pg_temp.expect_fail('anon cannot INSERT directly',
  $q$insert into public.admission_applications(reference,academic_year,parent_first_name,parent_surname,
     parent_relationship,email,mobile,address_line1,address_town,postcode,declaration_accepted,privacy_accepted)
     values('X','2027/2028','a','b','father','a@b.co','07','1 St','Bolton','BL1',true,true)$q$);
select pg_temp.expect_fail('anon cannot UPDATE',  'update public.admission_applications set status = ''offered''');
select pg_temp.expect_fail('anon cannot DELETE',  'delete from public.admission_applications');
reset role;

-- ---------------------------------------------------------------------------
-- 2. anon CAN submit through the function, and gets only a reference back
-- ---------------------------------------------------------------------------
set role anon;
select pg_temp.expect_ok('anon can submit an application', $q$
  select public.submit_admission_application('{
    "academic_year":"2027/2028",
    "parent_first_name":"Aisha","parent_surname":"Patel","parent_relationship":"mother",
    "email":"  Aisha@Example.COM ","mobile":"07000000000",
    "address_line1":"1 Draycott Street","address_town":"Bolton","postcode":"bl1 8hd",
    "declaration_accepted":true,"privacy_accepted":true,
    "students":[{"first_name":"Yusuf","surname":"Patel","date_of_birth":"2021-03-01",
      "gender":"male","school_name":"Sunning Hill","school_year":"Year 1",
      "has_send":false,"has_eha_ehcp":false,"has_allergies":true,"allergy_detail":"Peanuts",
      "ethnicity":"", "choices":[{"class_key":"boys_year1","preference":1},
                                 {"class_key":"boys_nazra","preference":2}]}],
    "contacts":[{"full_name":"Bilal Patel","relationship":"father","mobile":"07111111111","is_primary":false}]
  }'::jsonb)
$q$);
reset role;

-- normalisation and "prefer not to say" survived the round trip
insert into results
select 'email lower-cased and trimmed', email = 'aisha@example.com', email
  from public.admission_applications limit 1;
insert into results
select 'postcode upper-cased', postcode = 'BL1 8HD', postcode
  from public.admission_applications limit 1;
insert into results
select 'blank ethnicity stored as NULL', ethnicity is null, coalesce(ethnicity,'<null>')
  from public.admission_students limit 1;
insert into results
select 'submission written to admin_audit', count(*) = 1, count(*)::text
  from public.admin_audit where action = 'admission_application_submitted';

-- ---------------------------------------------------------------------------
-- 3. a signed-in NON-admin sees nothing — RLS, not an error
-- ---------------------------------------------------------------------------
set role authenticated;
set app.is_admin = 'off';
insert into results
select 'non-admin reads zero applications', count(*) = 0, count(*)::text
  from public.admission_applications;
insert into results
select 'non-admin reads zero students', count(*) = 0, count(*)::text
  from public.admission_students;
reset role;

-- ---------------------------------------------------------------------------
-- 4. an admin can read, and can only update the workflow columns
-- ---------------------------------------------------------------------------
set role authenticated;
set app.is_admin = 'on';
insert into results
select 'admin reads the application', count(*) = 1, count(*)::text
  from public.admission_applications;
select pg_temp.expect_ok('admin can set status',
  'update public.admission_applications set status = ''reviewing''');
select pg_temp.expect_fail('admin cannot rewrite a child''s medical notes',
  'update public.admission_students set medical_conditions = ''tampered''');
select pg_temp.expect_fail('admin cannot delete an application directly',
  'delete from public.admission_applications');
reset role;

-- ---------------------------------------------------------------------------
-- 5. the constraints that protect data quality
--
-- Run as the superuser on purpose: these assert CHECK constraints, which apply
-- to every role, and the statements need to SELECT an existing application id
-- that RLS would otherwise hide.
-- ---------------------------------------------------------------------------
reset role;
select pg_temp.expect_fail('allergies=true demands detail', $q$
  insert into public.admission_students(application_id,position,first_name,surname,date_of_birth,
    gender,school_name,school_year,has_send,has_eha_ehcp,has_allergies)
  select id,9,'A','B',date '2021-01-01','female','S','Y1',false,false,true
    from public.admission_applications limit 1$q$);
select pg_temp.expect_fail('two classes cannot share one preference', $q$
  insert into public.admission_student_choices(student_id,class_key,preference)
  select id,'girls_year1',1 from public.admission_students limit 1$q$);
select pg_temp.expect_fail('relationship=other demands free text', $q$
  insert into public.admission_applications(reference,academic_year,parent_first_name,parent_surname,
    parent_relationship,email,mobile,address_line1,address_town,postcode,declaration_accepted,privacy_accepted)
  values('TM-99-99999','2027/2028','a','b','other','a@b.co','07','1 St','Bolton','BL1',true,true)$q$);
select pg_temp.expect_fail('declaration must be accepted', $q$
  insert into public.admission_applications(reference,academic_year,parent_first_name,parent_surname,
    parent_relationship,email,mobile,address_line1,address_town,postcode,declaration_accepted,privacy_accepted)
  values('TM-99-99998','2027/2028','a','b','father','a@b.co','07','1 St','Bolton','BL1',false,true)$q$);
reset role;

select pg_temp.expect_fail('an application must name a child', $q$
  select public.submit_admission_application('{"academic_year":"2027/2028",
    "parent_first_name":"A","parent_surname":"B","parent_relationship":"father",
    "email":"a@b.co","mobile":"07","address_line1":"1","address_town":"Bolton",
    "postcode":"BL1","declaration_accepted":true,"privacy_accepted":true,"students":[]}'::jsonb)$q$);

-- ---------------------------------------------------------------------------
-- 6. retention purge is admin-only
-- ---------------------------------------------------------------------------
set role authenticated;
set app.is_admin = 'off';
select pg_temp.expect_fail('non-admin cannot purge',
  'select public.purge_old_admission_applications(24)');
reset role;

-- ---------------------------------------------------------------------------
\echo ''
\echo '=================== RESULTS ==================='
select case when ok then 'PASS' else 'FAIL' end as r, name, detail
  from results order by ok, name;
\echo ''
select count(*) filter (where ok)     as passed,
       count(*) filter (where not ok) as failed
  from results;
