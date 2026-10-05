-- Behaviour tests for migrations 001 and 002.
-- Run against the local fixture, never against the platform.
--   psql -f 000-schema-mirror.sql \
--        -f 001-...up.sql -f 002-...up.sql -f test.sql
--
-- Every test asserts. A pass prints a line; a failure raises and stops the
-- file, so "it printed a lot of PASS" is not the same as "nothing failed".

\set ON_ERROR_STOP on
set client_min_messages to notice;  -- the pass lines ARE the output; warning hides them

create or replace function pg_temp.ok(p_label text, p_cond boolean) returns void
language plpgsql as $$
begin
  if not p_cond then raise exception 'FAIL: %', p_label; end if;
  raise notice 'pass  %', p_label;
end $$;

/* Expects a call to raise, and that the message mentions p_contains. A test
   that only checks "it failed" passes for the wrong reason sooner or later. */
create or replace function pg_temp.raises(p_label text, p_sql text, p_contains text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(lower(p_contains) in lower(SQLERRM)) = 0 then
      raise exception 'FAIL: % — raised, but said "%" rather than mentioning "%"',
        p_label, SQLERRM, p_contains;
    end if;
    raise notice 'pass  % (refused: %)', p_label, left(SQLERRM, 60);
    return;
  end;
  raise exception 'FAIL: % — it was allowed, and should not have been', p_label;
end $$;

-- ---------------------------------------------------------------------------
-- Cast of characters
--
-- Reset first, so the suite can be run repeatedly against one database without
-- tripping over its own leftovers. Found by doing exactly that.
-- ---------------------------------------------------------------------------
truncate public.masjid_feature, public.masjid_plan, public.admin_audit,
         public.pending_access, public.user_roles, public.active_masjid,
         public.masjid_profile, public.prayer_years, public.madrasah_settings,
         public.madrasah_years, public.madrasah_fee_settings, public.app_settings,
         public.platform_admins, public._test_session cascade;
delete from public.masjids;
delete from auth.users;

insert into auth.users (id) values
  ('11111111-1111-1111-1111-111111111111'),  -- Yameen, platform admin
  ('22222222-2222-2222-2222-222222222222'),  -- a committee admin at masjid A
  ('33333333-3333-3333-3333-333333333333');  -- a teacher at masjid B
insert into public.platform_admins (user_id) values ('11111111-1111-1111-1111-111111111111');

create or replace function pg_temp.become(p_uid uuid, p_aal2 boolean default true)
returns void language sql as $$
  delete from public._test_session;
  insert into public._test_session (uid, aal2) values (p_uid, p_aal2);
$$;

-- ===========================================================================
-- ACCESS: who may create a masjid
-- ===========================================================================
select pg_temp.become('22222222-2222-2222-2222-222222222222');
select pg_temp.raises('a committee member cannot create a masjid',
  $$select public.create_masjid('{"slug":"sneaky","name":"Sneaky","town":"Nowhere"}'::jsonb)$$,
  'Only MasjidOne support');

select pg_temp.become('11111111-1111-1111-1111-111111111111', false);  -- no MFA
select pg_temp.raises('platform admin WITHOUT two-step cannot create a masjid',
  $$select public.create_masjid('{"slug":"nomfa","name":"No MFA","town":"Nowhere"}'::jsonb)$$,
  'Only MasjidOne support');

select pg_temp.become('11111111-1111-1111-1111-111111111111', true);   -- with MFA

-- ===========================================================================
-- VALIDATION
-- ===========================================================================
select pg_temp.raises('a slug with capitals and spaces is refused',
  $$select public.create_masjid('{"slug":"Not A Slug","name":"X"}'::jsonb)$$, 'slug must be');
select pg_temp.raises('a two-character slug is refused',
  $$select public.create_masjid('{"slug":"ab","name":"X"}'::jsonb)$$, 'slug must be');
select pg_temp.raises('a slug starting with a digit is refused',
  $$select public.create_masjid('{"slug":"1masjid","name":"X"}'::jsonb)$$, 'slug must be');
select pg_temp.raises('a masjid with no name is refused',
  $$select public.create_masjid('{"slug":"noname","name":"  "}'::jsonb)$$, 'needs a name');
select pg_temp.raises('an unknown plan is refused',
  $$select public.create_masjid('{"slug":"okslug","name":"X","town":"Bolton","plan":"platinum"}'::jsonb)$$,
  'no plan called');
select pg_temp.raises('a masjid with no town is refused, because the column is NOT NULL',
  $$select public.create_masjid('{"slug":"notown","name":"No Town"}'::jsonb)$$, 'needs a town');
select pg_temp.raises('a malformed admin email is refused',
  $$select public.create_masjid('{"slug":"okslug","name":"X","town":"Bolton","admin_email":"not-an-email"}'::jsonb)$$,
  'does not look like an email');

-- ===========================================================================
-- CREATING MASJID A  (stands in for the founding masjid)
-- ===========================================================================
select pg_temp.ok('masjid A is created',
  (public.create_masjid('{"slug":"alpha","name":"Alpha Masjid","town":"Bolton",
     "plan":"complete","band":"c","admin_email":"office@alpha.example",
     "admin_name":"A Trustee"}'::jsonb) ->> 'slug') = 'alpha');

select pg_temp.ok('it is created NOT LIVE',
  (select not is_live from public.masjids where slug='alpha'));
select pg_temp.ok('a ref_prefix is derived from the slug when not given',
  (select ref_prefix from public.masjids where slug='alpha') = 'ALP');
select pg_temp.ok('the plan is recorded and open',
  (select count(*) from public.masjid_plan mp join public.masjids m on m.id=mp.masjid_id
    where m.slug='alpha' and mp.plan_code='complete' and mp.band='c' and mp.ended_on is null) = 1);
select pg_temp.ok('the first administrator is invited, not created',
  (select count(*) from public.pending_access pa join public.masjids m on m.id=pa.masjid_id
    where m.slug='alpha' and pa.claimed_at is null) = 1);
select pg_temp.ok('creation is audited against that masjid',
  (select count(*) from public.admin_audit a join public.masjids m on m.id=a.masjid_id
    where m.slug='alpha' and a.action='masjid_created') = 1);

select pg_temp.raises('the same slug cannot be used twice',
  $$select public.create_masjid('{"slug":"alpha","name":"Another","town":"Bolton"}'::jsonb)$$,
  'already a masjid');

-- A not-live masjid is invisible to every public read, because masjid_id_for
-- only resolves live ones. This is the property that makes it safe to onboard
-- a customer slowly while another is serving Fajr.
select pg_temp.raises('a not-live masjid cannot be resolved by public reads',
  $$select public.masjid_id_for('alpha')$$, 'no masjid called');

-- ===========================================================================
-- GOING LIVE is gated on the checklist
-- ===========================================================================
select pg_temp.ok('the checklist reports six missing items',
  (public.masjid_setup_checklist('alpha') ->> 'missing')::int = 6);
select pg_temp.ok('and says it is not ready',
  (public.masjid_setup_checklist('alpha') ->> 'ready')::boolean = false);

select pg_temp.raises('go-live is refused while setup is incomplete',
  $$select public.masjid_go_live('alpha')$$, 'Not ready');

-- Fill the setup in, with the REAL columns. Writing these out is itself
-- informative: this is the work create_masjid() does not do, and the reason
-- the checklist exists rather than a cheerful "onboarded" message.
insert into public.masjid_profile (masjid_id, legal_name)
  select id, 'Alpha Masjid Trust' from public.masjids where slug='alpha';
insert into public.prayer_years (masjid_id, year, published)
  select id, 2027, true from public.masjids where slug='alpha';
insert into public.madrasah_settings (masjid_id, key, value)
  select id, 'register_days', '["mon","tue","wed","thu"]'::jsonb from public.masjids where slug='alpha';
insert into public.madrasah_years (masjid_id, label, starts_on, ends_on, is_current)
  select id, '2026/27', '2026-09-01', '2027-07-20', true from public.masjids where slug='alpha';
insert into public.madrasah_fee_settings (masjid_id, key, value)
  select id, 'currency', '"GBP"'::jsonb from public.masjids where slug='alpha';
insert into public.app_settings (masjid_id, key, value)
  select id, k, 'set' from public.masjids, unnest(array['notify_url','notify_key','notify_secret']) k
   where slug='alpha';

/* A prayer year that exists but is not published shows nothing on a screen,
   so the checklist must not accept it. */
update public.prayer_years set published = false
 where masjid_id = (select id from public.masjids where slug='alpha');
select pg_temp.ok('an UNPUBLISHED prayer timetable does not count as done',
  (public.masjid_setup_checklist('alpha') ->> 'missing')::int = 1);
update public.prayer_years set published = true
 where masjid_id = (select id from public.masjids where slug='alpha');

select pg_temp.ok('the checklist now reports nothing missing',
  (public.masjid_setup_checklist('alpha') ->> 'missing')::int = 0);

select pg_temp.raises('go-live is still refused while nobody can sign in',
  $$select public.masjid_go_live('alpha')$$, 'Nobody at this masjid can sign in');

-- The invited administrator claims their place
insert into public.user_roles (user_id, masjid_id, role)
select '22222222-2222-2222-2222-222222222222', id, 'admin' from public.masjids where slug='alpha';

select pg_temp.ok('with setup done and an admin in place, it goes live',
  (public.masjid_go_live('alpha') ->> 'is_live')::boolean);
select pg_temp.ok('and public reads can now resolve it',
  public.masjid_id_for('alpha') is not null);

-- ===========================================================================
-- MASJID B — the moment this whole exercise is about
-- ===========================================================================
select pg_temp.ok('masjid B is created alongside A',
  (public.create_masjid('{"slug":"beta","name":"Beta Masjid","town":"Blackburn","plan":"madrasah","band":"a"}'::jsonb)
    ->> 'slug') = 'beta');

-- THE headline finding from the audit, now demonstrated rather than asserted.
select pg_temp.raises('sole_masjid() refuses once a second masjid exists',
  $$select public.sole_masjid()$$, 'more than one masjid');

-- ...and the slug-taking path is unaffected. This is why the fix is in the
-- callers, not the database.
select pg_temp.ok('the slug-taking path still works with two masajid',
  public.masjid_id_for('alpha') <> (select id from public.masjids where slug='beta'));

-- ===========================================================================
-- ENTITLEMENTS
-- ===========================================================================
select pg_temp.ok('Masjid Complete grants the congregation app',
  public.masjid_has_for((select id from public.masjids where slug='alpha'), 'app'));
select pg_temp.ok('Madrasah does NOT grant the congregation app',
  not public.masjid_has_for((select id from public.masjids where slug='beta'), 'app'));
select pg_temp.ok('Madrasah does grant parent access',
  public.masjid_has_for((select id from public.masjids where slug='beta'), 'parent_access'));
select pg_temp.ok('nobody has Martyn''s Law, because nothing is built',
  not public.masjid_has_for((select id from public.masjids where slug='alpha'), 'martyns_law'));
select pg_temp.ok('an unknown feature is false, not an error',
  not public.masjid_has_for((select id from public.masjids where slug='alpha'), 'teleportation'));

select pg_temp.raises('an override with no reason is refused',
  $$select public.set_masjid_feature('beta','app',true,'  ')$$, 'Say why');

/* The write and the read are SEPARATE statements on purpose. masjid_has_for
   is STABLE, so reading it back inside the same statement as the write returns
   the pre-write snapshot — correct Postgres behaviour, and the reason the
   first version of this test failed. A real frontend makes two round trips. */
select public.set_masjid_feature('beta','app',true,'Pilot, agreed with the committee 5 Oct');
select pg_temp.ok('an override can grant something the plan does not',
  public.masjid_has_for((select id from public.masjids where slug='beta'), 'app'));

select public.set_masjid_feature('alpha','donations',false,'Their own provider stays until renewal');
select pg_temp.ok('an override can also REMOVE something the plan grants',
  not public.masjid_has_for((select id from public.masjids where slug='alpha'), 'donations'));

-- ===========================================================================
-- PLAN CHANGES keep history and never leave two open
-- ===========================================================================
select pg_temp.ok('a plan change is recorded',
  (public.set_masjid_plan('beta','complete','b','Upgraded 5 Oct') ->> 'previous') = 'madrasah');
select pg_temp.ok('exactly one plan row is open afterwards',
  (select count(*) from public.masjid_plan mp join public.masjids m on m.id=mp.masjid_id
    where m.slug='beta' and mp.ended_on is null) = 1);
select pg_temp.ok('and the old one is closed, not deleted — history survives',
  (select count(*) from public.masjid_plan mp join public.masjids m on m.id=mp.masjid_id
    where m.slug='beta' and mp.plan_code='madrasah' and mp.ended_on is not null) = 1);

-- ===========================================================================
-- TENANT ISOLATION
-- ===========================================================================
select pg_temp.become('22222222-2222-2222-2222-222222222222');  -- admin at Alpha only
select pg_temp.ok('a committee admin sees their own entitlements',
  (public.masjid_entitlements() ->> 'masjid') = 'alpha');
select pg_temp.raises('a committee admin cannot read another masjid''s entitlements',
  $$select public.masjid_entitlements((select id from public.masjids where slug='beta'))$$,
  'Not your masjid');
select pg_temp.ok('and masjid_has_for about someone else answers no rather than leaking',
  not public.masjid_has_for((select id from public.masjids where slug='beta'), 'madrasah'));
select pg_temp.raises('a committee admin cannot change their own plan',
  $$select public.set_masjid_plan('alpha','complete','d','nice try')$$,
  'Only MasjidOne support');
select pg_temp.raises('a committee admin cannot read a setup checklist',
  $$select public.masjid_setup_checklist('alpha')$$, 'Only MasjidOne support');

-- ===========================================================================
-- TAKING A MASJID OFFLINE is reversible and audited
-- ===========================================================================
select pg_temp.become('11111111-1111-1111-1111-111111111111', true);
select pg_temp.raises('taking a masjid offline needs a reason',
  $$select public.masjid_take_offline('alpha','')$$, 'Say why');
select pg_temp.ok('a masjid can be taken offline',
  (public.masjid_take_offline('alpha','Testing') ->> 'is_live')::boolean = false);
select pg_temp.ok('its data is untouched — the plan row is still there',
  (select count(*) from public.masjid_plan mp join public.masjids m on m.id=mp.masjid_id
    where m.slug='alpha' and mp.ended_on is null) = 1);
select pg_temp.ok('and it can be brought back',
  (public.masjid_go_live('alpha') ->> 'is_live')::boolean);

select pg_temp.ok('every support action landed in the right masjid''s audit',
  (select count(distinct action) from public.admin_audit a
     join public.masjids m on m.id = a.masjid_id where m.slug='alpha') >= 4);

-- ===========================================================================
-- NOTHING IS REACHABLE FROM A BROWSER THAT SHOULD NOT BE
--
-- These assertions exist because the suite passed 49 times while every revoke
-- in 001 did nothing at all. `revoke ... from anon` removes the named grant
-- but leaves the implicit grant to PUBLIC, so anon kept EXECUTE and the tests
-- never looked. Testing behaviour is not testing access: a function can
-- compute the right answer for exactly the wrong caller.
--
-- has_function_privilege/has_table_privilege are the right instruments because
-- they resolve PUBLIC, role inheritance and named grants together — which is
-- precisely what reading the revoke statement by eye does not.
-- ===========================================================================
select pg_temp.ok('the three new tables have RLS on',
  (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname in ('plans','masjid_plan','masjid_feature')
      and c.relrowsecurity) = 3);

select pg_temp.ok('and no policies, so RLS denies everything',
  (select count(*) from pg_policies
    where schemaname='public' and tablename in ('plans','masjid_plan','masjid_feature')) = 0);

select pg_temp.ok('no new table is readable by anon or authenticated',
  (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname in ('plans','masjid_plan','masjid_feature')
      and (has_table_privilege('anon', c.oid, 'SELECT')
        or has_table_privilege('authenticated', c.oid, 'SELECT'))) = 0);

select pg_temp.ok('anon cannot execute any function 001 or 002 created',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('masjid_has','masjid_has_for','masjid_entitlements',
                        'set_masjid_plan','set_masjid_feature','create_masjid',
                        'masjid_setup_checklist','masjid_go_live','masjid_take_offline')
      and has_function_privilege('anon', p.oid, 'EXECUTE')) = 0);

select pg_temp.ok('and PUBLIC holds EXECUTE on none of them either',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('masjid_has','masjid_has_for','masjid_entitlements',
                        'set_masjid_plan','set_masjid_feature','create_masjid',
                        'masjid_setup_checklist','masjid_go_live','masjid_take_offline')
      and array_to_string(p.proacl, ',') ~ '(^|[,|])=X/') = 0);

select pg_temp.ok('a signed-in user can still reach the ones meant for them',
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public'
      and p.proname in ('masjid_has','masjid_entitlements','create_masjid','masjid_go_live')
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')) = 4);

\echo ''
\echo 'ALL TESTS PASSED'
