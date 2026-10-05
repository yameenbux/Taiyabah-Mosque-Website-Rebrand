-- Behaviour tests for 139 — who runs MasjidOne.
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

truncate public.user_roles, public.platform_admins, public.platform_audit,
         public.active_masjid, public.admin_audit, public._test_session cascade;
delete from auth.mfa_factors;
delete from public.masjids;
delete from auth.users;

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111','founder@hotmail.example'),   -- today: both hats
  ('22222222-2222-2222-2222-222222222222','yameen@masjidone.example'),  -- the new MasjidOne account
  ('33333333-3333-3333-3333-333333333333','nofactor@masjidone.example'),-- no two-step
  ('44444444-4444-4444-4444-444444444444','trustee@taiyabah.example');  -- holds a masjid role
insert into auth.mfa_factors (user_id) values
  ('11111111-1111-1111-1111-111111111111'),
  ('22222222-2222-2222-2222-222222222222'),
  ('44444444-4444-4444-4444-444444444444');   -- deliberately none for 3333

insert into public.masjids (slug, name, town, is_live)
values ('taiyabah','Taiyabah Masjid','Bolton', true);

create or replace function pg_temp.become(p_uid uuid, p_aal2 boolean default true)
returns void language sql as $$
  delete from public._test_session;
  insert into public._test_session (uid, aal2) values (p_uid, p_aal2);
$$;

-- Today's state, set up behind the 137 trigger as if it predated it.
set session_replication_role = replica;
insert into public.platform_admins (user_id) values ('11111111-1111-1111-1111-111111111111');
insert into public.user_roles (user_id, masjid_id, role)
select '11111111-1111-1111-1111-111111111111', id, 'admin' from public.masjids;
insert into public.user_roles (user_id, masjid_id, role)
select '44444444-4444-4444-4444-444444444444', id, 'admin' from public.masjids;
set session_replication_role = origin;

-- ===========================================================================
-- ACCESS
-- ===========================================================================
select pg_temp.become('44444444-4444-4444-4444-444444444444');
select pg_temp.raises('a masjid administrator cannot add a platform administrator',
  $$select public.platform_admin_add('yameen@masjidone.example')$$, 'Only MasjidOne support');
select pg_temp.raises('nor read who runs MasjidOne',
  $$select public.platform_admins_list()$$, 'Only MasjidOne support');

select pg_temp.become('11111111-1111-1111-1111-111111111111', false);
select pg_temp.raises('nor can the founder without two-step completed this session',
  $$select public.platform_admin_add('yameen@masjidone.example')$$, 'Only MasjidOne support');

select pg_temp.become('11111111-1111-1111-1111-111111111111', true);

-- ===========================================================================
-- THE RAIL THAT MATTERS: an account that cannot pass aal2 is not a way back in
-- ===========================================================================
select pg_temp.raises('an account with no two-step is refused, with the reason',
  $$select public.platform_admin_add('nofactor@masjidone.example')$$,
  'Two-step is not set up');

select pg_temp.raises('an unknown address is refused',
  $$select public.platform_admin_add('nobody@example.test')$$, 'There is no account for');

select pg_temp.raises('an account holding a masjid role cannot run MasjidOne',
  $$select public.platform_admin_add('trustee@taiyabah.example')$$, 'holds a role at');

-- ===========================================================================
-- THE HANDOVER, in the order that cannot lock anybody out
-- ===========================================================================
select pg_temp.ok('the new MasjidOne account can be added',
  (public.platform_admin_add('yameen@masjidone.example') ->> 'added')::boolean);
select pg_temp.ok('there are now two, so there is no single point of lockout',
  (public.platform_admins_list() ->> 'able')::int = 2);
select pg_temp.raises('adding it twice is refused',
  $$select public.platform_admin_add('yameen@masjidone.example')$$, 'already a platform administrator');

-- The new account really works, which is the thing to confirm before letting go.
select pg_temp.become('22222222-2222-2222-2222-222222222222');
select pg_temp.ok('the new account can read who runs MasjidOne',
  (public.platform_admins_list() ->> 'able')::int = 2);
select pg_temp.ok('and entering a masjid from it IS support access',
  (public.set_current_masjid('taiyabah') ->> 'support_access')::boolean);
select pg_temp.ok('which lands in the masjid''s audit trail',
  (select count(*) from public.admin_audit
    where action='masjidone_support_access'
      and actor='22222222-2222-2222-2222-222222222222') = 1);

-- Only now the old one goes — and ONLY its MasjidOne hat.
select pg_temp.ok('the old account can be retired from MasjidOne',
  (public.platform_admin_remove('founder@hotmail.example') ->> 'removed')::boolean);

/* Retired, not deleted: the row survives so the history of who held the keys
   can still be answered. */
select pg_temp.ok('its row is kept, marked retired rather than deleted',
  (select revoked_at is not null from public.platform_admins
    where user_id='11111111-1111-1111-1111-111111111111'));
select pg_temp.ok('and it appears under former administrators',
  (public.platform_admins_list() #>> '{former,0,email}') = 'founder@hotmail.example');
/* become() and the check are SEPARATE statements. is_platform_admin() is
   STABLE, so calling it in the same statement that changes the session reads
   the snapshot from before the change — the same trap 134 documents for
   masjid_has_for. */
select pg_temp.become('11111111-1111-1111-1111-111111111111');
select pg_temp.ok('a retired row grants nothing — is_platform_admin() says no',
  not public.is_platform_admin());

/* And it is a person at a masjid again, so the masjid can give it a role. */
select pg_temp.become('22222222-2222-2222-2222-222222222222');
insert into public.user_roles (user_id, masjid_id, role)
select '11111111-1111-1111-1111-111111111111', id, 'hall_office' from public.masjids;
select pg_temp.ok('a RETIRED administrator can be given a new role at a masjid',
  (select count(*) from public.user_roles
    where user_id='11111111-1111-1111-1111-111111111111') = 2);

select pg_temp.ok('ITS TAIYABAH ROLES ARE UNTOUCHED',
  (select count(*) from public.user_roles
    where user_id='11111111-1111-1111-1111-111111111111') = 2);
select pg_temp.ok('and it no longer counts as a platform administrator',
  (select count(*) from public.platform_admins
    where user_id='11111111-1111-1111-1111-111111111111' and revoked_at is null) = 0);

-- ===========================================================================
-- YOU CANNOT LOCK THE COMPANY OUT OF ITSELF
-- ===========================================================================
select pg_temp.raises('the last able platform administrator cannot remove themselves',
  $$select public.platform_admin_remove('yameen@masjidone.example')$$,
  'leave nobody able to run MasjidOne');

/* And a row without two-step does not count as a way back in. Added behind the
   trigger, because platform_admin_add() rightly refuses it. */
set session_replication_role = replica;
insert into public.platform_admins (user_id) values ('33333333-3333-3333-3333-333333333333');
set session_replication_role = origin;
select pg_temp.ok('a platform admin without two-step is listed but not counted as able',
  (public.platform_admins_list() ->> 'able')::int = 1);
select pg_temp.raises('so it still cannot be the one left behind',
  $$select public.platform_admin_remove('yameen@masjidone.example')$$,
  'leave nobody able to run MasjidOne');

-- ===========================================================================
-- THE SEPARATION IS NOW REAL
-- ===========================================================================
select pg_temp.ok('nobody is wearing two hats any more',
  (public.access_separation_report() ->> 'wearing_two_hats')::int = 0);

-- ===========================================================================
-- MASJIDONE'S OWN EVENTS STAY OUT OF THE MASJID'S RECORD
-- ===========================================================================
select pg_temp.ok('both acts were written to platform_audit',
  (select count(*) from public.platform_audit
    where action in ('platform_admin_added','platform_admin_removed')) = 2);
select pg_temp.ok('and NOT into any masjid''s audit trail',
  (select count(*) from public.admin_audit
    where action like 'platform_admin%') = 0);

\echo ''
\echo 'ALL WHO-RUNS-MASJIDONE TESTS PASSED'
