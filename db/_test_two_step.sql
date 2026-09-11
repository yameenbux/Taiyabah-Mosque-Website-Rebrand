-- ===========================================================================
--  _test_two_step.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 011: a staff session that has not passed two-step
--  verification can read nothing, and one that has works exactly as before.
--
--  Run against a FRESHLY BUILT database:  bash db/harness/build.sh t_2s full
--  (or just db/harness/run-all.sh, which knows the profile)
--
--  It USED to say "008, 009, 010, 011" and that stopped being true at 016,
--  which made `reference` NOT NULL — so this file errored out on its own
--  fixture and proved nothing at all from 016 until 8 September 2026. This is
--  the file that guards two-step verification on seventeen policies; a test
--  suite that cannot start is worse than no test suite, because the folder
--  still looks covered.
--
--  Every assertion runs as the `authenticated` role, never as a superuser.
--  Test 00 proves that role really is subject to RLS — without it the whole
--  file could pass while proving nothing, which has happened before on this
--  project and is the reason the check is here.
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
exception when others then insert into r values (l,true,left(sqlerrm,60)); end; end $$;

create or replace function pg_temp.eok(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,true,'');
exception when others then insert into r values (l,false,left(sqlerrm,80)); end; end $$;

-- How many rows a statement actually changed. RLS does not raise on an update
-- it refuses — it simply matches nothing — so counting is the only way to tell
-- "refused" from "worked".
create or replace function pg_temp.changed(l text, s text, want int)
returns void language plpgsql as $$
declare n int;
begin
  execute s; get diagnostics n = row_count;
  insert into r values (l, n = want, 'changed ' || n || ', expected ' || want);
exception when others then
  insert into r values (l, false, left(sqlerrm, 60));
end $$;

-- Everything from here to the results is bookkeeping, not output.
\o /dev/null


-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'admin@example.test'),
  ('22222222-2222-2222-2222-222222222222', 'office@example.test'),
  ('33333333-3333-3333-3333-333333333333', 'customer@example.test')
on conflict (id) do nothing;

insert into public.profiles (id, full_name, email) values
  ('11111111-1111-1111-1111-111111111111', 'An Administrator', 'admin@example.test'),
  ('22222222-2222-2222-2222-222222222222', 'The Hall Office',  'office@example.test'),
  ('33333333-3333-3333-3333-333333333333', 'A Shop Customer',  'customer@example.test')
on conflict (id) do nothing;

insert into public.user_roles (user_id, role) values
  ('11111111-1111-1111-1111-111111111111', 'admin'),
  ('22222222-2222-2222-2222-222222222222', 'hall_office')
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- Something to read. Inserted as the owner, so RLS is not in the way here.
-- ---------------------------------------------------------------------------
-- Whole-day hire, by the number of halls (migration 014). The old
-- session/hall/kitchen shape is refused by halls_count_valid now, which is
-- how this fixture found out the model had changed.
-- `reference` became NOT NULL in 016, when paying started to hold the date.
insert into public.hall_bookings
  (booking_date, hire_type, halls_count, first_name, last_name, address, phone,
   reference)
values (current_date + 40, 'halls', 2, 'Imran', 'Ali', '4 Mill St', '07700900901',
        'HH-TEST-0001');

insert into public.nikah_requests
  (reference, preferred_date, slot, preferred_time, contact_name, contact_role,
   contact_phone, contact_email, privacy_accepted)
values ('NK-TEST-0001', current_date + 30, 'after_zuhr', '13:15', 'Maryam Khan',
        'bride', '07700900222', 'm@example.test', true);


-- ===========================================================================
--  00. Does this test mean anything at all?
-- ===========================================================================
select pg_temp.note('the test role is subject to RLS',
  not rolsuper and not rolbypassrls,
  'super=' || rolsuper || ' bypassrls=' || rolbypassrls)
from pg_roles where rolname = 'authenticated';

select pg_temp.note('is_aal2() fails closed when there is no claim',
  public.is_aal2() = false);


-- ===========================================================================
--  01. The hall office
-- ===========================================================================
set role authenticated;
select set_config('test.uid', '22222222-2222-2222-2222-222222222222', false);

select set_config('test.aal', 'aal1', false);
select pg_temp.note('office at aal1 reads no hall bookings',
  (select count(*) from public.hall_bookings) = 0,
  (select count(*)::text from public.hall_bookings));
select pg_temp.note('office at aal1 reads no nikah requests',
  (select count(*) from public.nikah_requests) = 0);

select set_config('test.aal', 'aal2', false);
select pg_temp.note('office at aal2 reads hall bookings',
  (select count(*) from public.hall_bookings where phone = '07700900901') = 1,
  (select count(*)::text from public.hall_bookings));
select pg_temp.note('office at aal2 reads nikah requests',
  (select count(*) from public.nikah_requests) = 1);

-- Writing is gated the same way as reading.
select set_config('test.aal', 'aal1', false);
select pg_temp.changed('office at aal1 changes nothing',
  $$update public.hall_bookings set status = 'confirmed'
     where phone = '07700900901'$$, 0);
select set_config('test.aal', 'aal2', false);
-- Declining, not confirming. Migration 021 refuses to move a booking to
-- confirmed unless a deposit has been recorded — paying is what confirms a
-- booking now — so confirming an unpaid fixture stopped being a legal write
-- and this assertion started failing for the right reason. Declining is the
-- same policy, the same columns and the same proof.
select pg_temp.changed('office at aal2 can record an outcome',
  $$update public.hall_bookings set status = 'declined'
     where phone = '07700900901'$$, 1);
reset role;


-- ===========================================================================
--  02. The administrator
-- ===========================================================================
set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);

select set_config('test.aal', 'aal1', false);
select pg_temp.note('admin at aal1 reads no admission applications',
  (select count(*) from public.admission_applications) = 0);
select pg_temp.note('admin at aal1 reads no course registrations',
  (select count(*) from public.course_registrations) = 0);
select pg_temp.note('admin at aal1 reads no other profiles',
  (select count(*) from public.profiles) = 1,          -- its own row only
  (select count(*)::text from public.profiles));
select pg_temp.note('admin at aal1 reads no other roles',
  (select count(*) from public.user_roles) = 1,        -- its own row only
  (select count(*)::text from public.user_roles));

-- The single most dangerous thing an administrator can do.
select pg_temp.efail('admin at aal1 cannot grant a role',
  $$insert into public.user_roles (user_id, role)
    values ('33333333-3333-3333-3333-333333333333', 'admin')$$);

select set_config('test.aal', 'aal2', false);
select pg_temp.note('admin at aal2 reads every profile',
  (select count(*) from public.profiles) = 3);
select pg_temp.eok('admin at aal2 can grant a role',
  $$insert into public.user_roles (user_id, role)
    values ('33333333-3333-3333-3333-333333333333', 'teacher')$$);
reset role;
delete from public.user_roles
 where user_id = '33333333-3333-3333-3333-333333333333';


-- ===========================================================================
--  03. The signpost must keep working
--
--  /account/ and /portals/ read the signed-in person's own profile and roles
--  BEFORE the authenticator code is entered, to decide whether to show the
--  admin button. If 011 broke that, the button would never appear.
-- ===========================================================================
set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal1', false);

select pg_temp.note('an admin at aal1 can still see its own role',
  exists (select 1 from public.user_roles
           where user_id = '11111111-1111-1111-1111-111111111111'
             and role = 'admin'));
select pg_temp.note('an admin at aal1 can still see its own profile',
  exists (select 1 from public.profiles
           where id = '11111111-1111-1111-1111-111111111111'));
reset role;


-- ===========================================================================
--  04. Two-step is not authorisation
--
--  A shop customer who has set up an authenticator is still a shop customer.
-- ===========================================================================
set role authenticated;
select set_config('test.uid', '33333333-3333-3333-3333-333333333333', false);
select set_config('test.aal', 'aal2', false);

select pg_temp.note('a verified customer still reads no hall bookings',
  (select count(*) from public.hall_bookings) = 0);
select pg_temp.note('a verified customer still reads no nikah requests',
  (select count(*) from public.nikah_requests) = 0);
select pg_temp.note('a verified customer still reads only its own profile',
  (select count(*) from public.profiles) = 1);
reset role;


-- ===========================================================================
--  05. The public is untouched
--
--  Members of the public are not signed in at all. If 011 caught them, the
--  website would stop taking bookings — a far worse fault than the one it
--  fixes.
-- ===========================================================================
set role anon;
select set_config('test.uid', '', false);
select set_config('test.aal', '', false);

select pg_temp.eok('the public can still request a nikah date',
  $$select public.request_nikah_date(jsonb_build_object(
      'preferred_date', (current_date + 45)::text,
      'slot','after_asr','preferred_time','16:00',
      'contact_name','A Person','contact_role','groom',
      'contact_phone','07700900123','contact_email','p@example.test',
      'privacy_accepted', true))$$);

-- 016 took the INSERT grant away from anon and put the booking behind
-- request_hall_booking(), which is the only thing that can take the advisory
-- lock and the thirty-minute hold. A browser that could still insert directly
-- would be a way to book a date without ever holding it — so the old
-- assertion here (a bare INSERT succeeding) is now exactly backwards.
select pg_temp.efail('the public can no longer insert a booking directly',
  $$insert into public.hall_bookings
      (booking_date, hire_type, halls_count, first_name, last_name, address, phone,
       reference)
    values (current_date + 60, 'halls', 2, 'Sara', 'Bi', '9 Green Street, Bolton',
            '07700900444', 'HH-TEST-0009')$$);

select pg_temp.eok('but can still request one through the front door',
  $$select public.request_hall_booking(jsonb_build_object(
      'booking_date', (current_date + 60)::text,
      'hire_type', 'halls', 'halls_count', 2,
      'first_name', 'Sara', 'last_name', 'Bi',
      'address', '9 Green Street, Bolton', 'phone', '07700900444'))$$);

-- anon holds no SELECT grant at all, so this is refused before RLS is even
-- consulted. Two locks on the same door, which is the intended shape.
select pg_temp.efail('the public still cannot read a booking back',
  $$select count(*) from public.hall_bookings$$);
reset role;


-- ===========================================================================
--  06. The rule, enforced rather than written down
--
--  Every policy that lets a signed-in member of staff reach across accounts
--  must go through verified_admin() or verified_office(). This catches the
--  policy somebody adds in six months having forgotten this file exists.
--
--  The two "read own" policies are the deliberate exceptions named in 011.
-- ===========================================================================
select pg_temp.note(
  'no staff policy skips the two-step check',
  not exists (
    select 1 from pg_policies
     where schemaname = 'public'
       and tablename in ('hall_bookings','nikah_requests','profiles','user_roles',
                         'admin_audit','courses','course_registrations',
                         'admission_applications','admission_students',
                         'admission_contacts','admission_student_choices')
       and coalesce(qual, '') !~ 'verified_(admin|office)'
       and coalesce(qual, '') not in ('', 'true')          -- definer-only policies
       -- the three deliberate exceptions, named rather than matched by shape
       and (tablename, policyname) not in (
             ('profiles',   'profiles: read own'),
             ('profiles',   'profiles: update own'),
             ('user_roles', 'user_roles: read own'))
  ),
  coalesce((select string_agg(tablename || '.' || policyname, ', ')
              from pg_policies
             where schemaname = 'public'
               and tablename in ('hall_bookings','nikah_requests','profiles','user_roles',
                                 'admin_audit','courses','course_registrations',
                                 'admission_applications','admission_students',
                                 'admission_contacts','admission_student_choices')
               and coalesce(qual, '') !~ 'verified_(admin|office)'
               and coalesce(qual, '') not in ('', 'true')
               and (tablename, policyname) not in (
                     ('profiles',   'profiles: read own'),
                     ('profiles',   'profiles: update own'),
                     ('user_roles', 'user_roles: read own'))), 'none'));


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
