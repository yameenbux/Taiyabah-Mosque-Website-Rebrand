-- Behaviour tests for 137 — one hat each.
\set ON_ERROR_STOP on
set client_min_messages to notice;

create or replace function pg_temp.ok(p_label text, p_cond boolean) returns void
language plpgsql as $$
begin
  if not p_cond then raise exception 'FAIL: %', p_label; end if;
  raise notice 'pass  %', p_label;
end $$;

create or replace function pg_temp.raises(p_label text, p_sql text, p_contains text)
returns void language plpgsql as $$
begin
  begin execute p_sql;
  exception when others then
    if position(lower(p_contains) in lower(SQLERRM)) = 0 then
      raise exception 'FAIL: % — raised, but said "%" rather than mentioning "%"',
        p_label, SQLERRM, p_contains;
    end if;
    raise notice 'pass  % (refused: %)', p_label, left(SQLERRM, 70);
    return;
  end;
  raise exception 'FAIL: % — it was allowed, and should not have been', p_label;
end $$;

truncate public.user_roles, public.platform_admins, public.active_masjid,
         public.admin_audit, public._test_session cascade;
delete from public.masjids;
delete from auth.users;

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),   -- the founder, both hats today
  ('22222222-2222-2222-2222-222222222222'),   -- a clean MasjidOne account
  ('33333333-3333-3333-3333-333333333333');   -- a clean masjid administrator
insert into public.masjids (slug, name, town, is_live)
values ('taiyabah','Taiyabah Masjid','Bolton', true);

create or replace function pg_temp.become(p_uid uuid, p_aal2 boolean default true)
returns void language sql as $$
  delete from public._test_session;
  insert into public._test_session (uid, aal2) values (p_uid, p_aal2);
$$;

-- ===========================================================================
-- THE EXISTING OVERLAP IS NOT BROKEN BY APPLYING THIS
-- A trigger fires on what happens next. Rows already there stay, so applying
-- 137 cannot lock anybody out of anything on the day it lands.
-- ===========================================================================
set session_replication_role = replica;   -- as if these rows predate the trigger
insert into public.platform_admins (user_id) values ('11111111-1111-1111-1111-111111111111');
insert into public.user_roles (user_id, masjid_id, role)
select '11111111-1111-1111-1111-111111111111', id, 'admin' from public.masjids;
set session_replication_role = origin;

select pg_temp.ok('an account that already wears both hats is left alone',
  (select count(*) from public.platform_admins p
     join public.user_roles r on r.user_id = p.user_id) = 1);

-- ===========================================================================
-- BUT IT CANNOT HAPPEN AGAIN, FROM EITHER DIRECTION
-- ===========================================================================
select pg_temp.raises('a platform admin cannot be given a role at a masjid',
  $$insert into public.user_roles (user_id, masjid_id, role)
    select '11111111-1111-1111-1111-111111111111', id, 'teacher' from public.masjids$$,
  'platform administrator');

/* The insert is its own statement: a data-modifying CTE cannot sit inside a
   function argument, and wrapping it in one made the suite fail on its own
   syntax rather than on the behaviour under test. */
insert into public.user_roles (user_id, masjid_id, role)
select '33333333-3333-3333-3333-333333333333', id, 'admin' from public.masjids;
select pg_temp.ok('a clean masjid administrator can be given a role',
  (select count(*) from public.user_roles
    where user_id = '33333333-3333-3333-3333-333333333333') = 1);

select pg_temp.raises('and then cannot be made a platform administrator',
  $$insert into public.platform_admins (user_id)
    values ('33333333-3333-3333-3333-333333333333')$$,
  'holds a role at');

insert into public.platform_admins (user_id)
values ('22222222-2222-2222-2222-222222222222');
select pg_temp.ok('a clean MasjidOne account CAN be made a platform administrator',
  (select count(*) from public.platform_admins
    where user_id = '22222222-2222-2222-2222-222222222222') = 1);

select pg_temp.raises('and then cannot pick up a role at a masjid',
  $$insert into public.user_roles (user_id, masjid_id, role)
    select '22222222-2222-2222-2222-222222222222', id, 'admin' from public.masjids$$,
  'platform administrator');

-- The error has to tell you what to do instead, not just say no.
select pg_temp.raises('the refusal explains that support access already reaches the masjid',
  $$insert into public.user_roles (user_id, masjid_id, role)
    select '22222222-2222-2222-2222-222222222222', id, 'admin' from public.masjids$$,
  'without a role');

-- ===========================================================================
-- THE WHOLE POINT: SUPPORT ACCESS IS AUDITED ONCE THE HATS ARE APART
-- ===========================================================================
select pg_temp.become('22222222-2222-2222-2222-222222222222');   -- MasjidOne only
select pg_temp.ok('a separated MasjidOne account enters as SUPPORT access',
  (public.set_current_masjid('taiyabah') ->> 'support_access')::boolean);
select pg_temp.ok('and it is written to the masjid''s audit trail',
  (select count(*) from public.admin_audit
    where action = 'masjidone_support_access'
      and actor = '22222222-2222-2222-2222-222222222222') = 1);

select pg_temp.become('11111111-1111-1111-1111-111111111111');   -- still both hats
select pg_temp.ok('an account wearing both hats still enters invisibly — which is the problem',
  (public.set_current_masjid('taiyabah') ->> 'support_access')::boolean = false);
select pg_temp.ok('leaving nothing in the audit trail for that visit',
  (select count(*) from public.admin_audit
    where action = 'masjidone_support_access'
      and actor = '11111111-1111-1111-1111-111111111111') = 0);

-- ===========================================================================
-- THE REPORT NAMES IT
-- ===========================================================================
select pg_temp.ok('the report finds exactly the one account wearing two hats',
  (public.access_separation_report() ->> 'wearing_two_hats')::int = 1);
select pg_temp.ok('and says which masjid and which role',
  (public.access_separation_report() #>> '{detail,0,roles,0,masjid}') = 'taiyabah');

select pg_temp.become('33333333-3333-3333-3333-333333333333');
select pg_temp.raises('a masjid administrator cannot read the report',
  $$select public.access_separation_report()$$, 'Only MasjidOne support');

\echo ''
\echo 'ALL ONE-HAT TESTS PASSED'
