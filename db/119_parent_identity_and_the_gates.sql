--  =====================================================================
--  119 - PARENT IDENTITY AND THE GATES
--  29 September 2026
--  =====================================================================
--
--  Slice 1 of the parents' portal (docs/superpowers/specs/2026-09-29-the-
--  parents-portal-and-messages-design.md). This file gives a parent an
--  identity and three gates. It builds no screen and shows no child.
--
--  THE GATES ARE THE WHOLE JOB. A parent who can reach another family's
--  child makes everything built on top of this worthless, so this file is
--  organised around one rule: EVERY parent-facing function in every later
--  slice takes its pupil set from my_parent_children(), and asks "is this
--  pupil mine" through is_my_child() / require_my_child(), which are built
--  on that same function. One place to be wrong.
--
--  WHAT A PARENT IS.
--    A guardian row on a household, plus one row in madrasah_parent_logins.
--    The children a parent may see are DERIVED - guardian -> household ->
--    pupils on that household - never stored, so a child who moves household
--    moves with it on the next call.
--
--  WHAT A PARENT IS NOT.
--    A parent has NO user_roles row. Not 'parent' (that enum value exists
--    and nothing grants on it), not anything else. Two consequences, both
--    deliberate:
--      * verified_madrasah() and verified_admin() are false for them
--        whatever their session says, because both need a role;
--      * current_masjid() is NULL for them, so every existing function that
--        scopes by it and forgets to gate sees an empty masjid. That is the
--        second wall behind the first. It also means parent-facing functions
--        cannot use current_masjid() - they take the masjid from the login
--        row, which is what my_parent_children() does.
--    Two-step is not required of a parent (spec, Identity): 552 children's
--    records are behind staff accounts that must enrol an authenticator; a
--    parent account opens one household. The compensating control is that it
--    reaches exactly one.
--
--  THE BUG THIS FILE MUST NOT REPEAT. db/093 wrote auth.users rows that left
--  four token columns NULL, and all 39 teacher logins were dead on arrival
--  with "Database error querying schema" while every database-side check
--  passed. db/094 explains it. create_parent_login() below writes all eight
--  columns as '' AND READS THE ROW BACK and refuses if any is NULL, so a
--  regression fails at the moment somebody creates the account, and this
--  migration creates one (inside a transaction it then rolls back) to prove
--  the function refuses to leave a broken row behind.
--
--  WHAT COULD NOT BE PROVED FROM HERE, and 094 says why it matters: nobody
--  has signed in over HTTP. The read-back proves the row is one the auth
--  service CAN scan. It does not prove a password works through the real
--  page. THE FIRST THING TO DO WITH THE TEST PARENT (db/120) IS TO SIGN IN AS
--  THEM ON THE LIVE SITE.
--
--  RLS is on for the new table with NO policy and every grant revoked: the
--  table is reached only through functions (docs/GO-LIVE.md section E).
--  Every function is SECURITY DEFINER, owned by postgres, with
--  search_path = public, pg_temp, and anon has EXECUTE on none of them.
--  Each revoke/grant pair is restated per function on purpose: Supabase's
--  default privileges grant EXECUTE to anon directly, so "revoke from public"
--  alone would leave the door open.

--  ---------------------------------------------------------------------
--  1. THE TABLE
--  ---------------------------------------------------------------------
create table if not exists public.madrasah_parent_logins (
  id            uuid primary key default gen_random_uuid(),
  masjid_id     uuid not null references public.masjids(id) on delete cascade,
  guardian_id   uuid not null references public.madrasah_guardians(id) on delete cascade,
  --  CASCADE so that removing an auth user in the dashboard removes the login
  --  row with it rather than being blocked by it. The health check still
  --  looks for a login whose user is gone or soft-deleted, because
  --  auth.users.deleted_at is a state this constraint does not see.
  user_id       uuid not null references auth.users(id) on delete cascade,
  created_at    timestamptz not null default now(),
  created_by    uuid,
  last_seen_at  timestamptz,
  constraint madrasah_parent_login_one_per_guardian unique (guardian_id),
  constraint madrasah_parent_login_one_per_user     unique (user_id)
);

alter table public.madrasah_parent_logins enable row level security;
revoke all on table public.madrasah_parent_logins from public, anon, authenticated;

comment on table public.madrasah_parent_logins is
  'One row per guardian who has a login. No policy, no grants: reached only through functions. The children a parent may see are derived through my_parent_children(), never stored.';

--  ---------------------------------------------------------------------
--  2. THE GATES
--  ---------------------------------------------------------------------
create or replace function public.is_parent()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (select 1 from public.madrasah_parent_logins l
                  where l.user_id = auth.uid());
$$;

revoke all on function public.is_parent() from public, anon;
grant execute on function public.is_parent() to authenticated;

--  THE ONE PLACE TO BE WRONG. Guardian -> household -> pupils on it, and
--  nothing else. Every hop is held to the LOGIN'S masjid, so a guardian row,
--  household or pupil that somehow belonged to another masjid could not
--  come through (the shape of the hole db/116 closed on record_parent_absence).
--
--  It returns ids and the facts a caller needs to decide what to do with
--  each child (status), not names: a later function joins madrasah_pupils
--  itself for the columns it is entitled to show, and that join is written
--  in the open there, in the function that shows them.
--
--  Every status is returned, `left` included: this says which children are on
--  the household, not which are currently on the roll. A caller that only
--  wants children on the roll filters on status.
create or replace function public.my_parent_children()
returns table (pupil_id uuid, household_id uuid, masjid_id uuid, status text)
language sql stable security definer
set search_path = public, pg_temp as $$
  select p.id, p.household_id, p.masjid_id, p.status
    from public.madrasah_parent_logins l
    join public.madrasah_guardians g
      on g.id = l.guardian_id and g.masjid_id = l.masjid_id
    join public.madrasah_households h
      on h.id = g.household_id and h.masjid_id = l.masjid_id
    join public.madrasah_pupils p
      on p.household_id = h.id and p.masjid_id = l.masjid_id
   where l.user_id = auth.uid();
$$;

revoke all on function public.my_parent_children() from public, anon;
grant execute on function public.my_parent_children() to authenticated;

--  "IS THIS PUPIL MINE", answered from my_parent_children() and nowhere
--  else. A NULL, an unknown id, another family's child and a caller who is
--  not a parent at all all give false.
create or replace function public.is_my_child(p_pupil uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (select 1 from public.my_parent_children() c
                  where c.pupil_id = p_pupil);
$$;

revoke all on function public.is_my_child(uuid) from public, anon;
grant execute on function public.is_my_child(uuid) to authenticated;

--  THE REFUSING FORM, for a function that must stop rather than answer. One
--  message and one errcode for "does not exist", "belongs to another family"
--  and "you are not a parent", so the refusal cannot be used to probe which
--  ids are real children (the same rule db/116 applied to may_take_register).
create or replace function public.require_my_child(p_pupil uuid)
returns void language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.is_my_child(p_pupil) then
    raise exception 'not yours' using errcode = '42501';
  end if;
end $$;

revoke all on function public.require_my_child(uuid) from public, anon;
grant execute on function public.require_my_child(uuid) to authenticated;

--  ---------------------------------------------------------------------
--  3. CREATING A LOGIN
--     Modelled on create_teacher_login() AS PATCHED BY db/094, not as
--     db/093 first wrote it.
--  ---------------------------------------------------------------------
create or replace function public.create_parent_login(
  p_guardian uuid, p_email text, p_password text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp, extensions as $$
declare
  v_masjid uuid := public.current_masjid();
  v_uid uuid := gen_random_uuid();
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_name text;
  v_household uuid;
  v_children int;
  v_readable boolean;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may '
                    'create a login.' using errcode = '42501';
  end if;
  if length(coalesce(p_password, '')) < 12 then
    raise exception 'An initial password must be at least 12 characters.'
      using errcode = '22023';
  end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
     or length(v_email) > 160 then
    raise exception 'That is not an email address.' using errcode = '22023';
  end if;

  --  The guardian must be on THIS masjid's books. One message for "no such
  --  guardian" and "somebody else's", so it cannot be used to probe.
  select g.household_id, g.full_name into v_household, v_name
    from public.madrasah_guardians g
   where g.id = p_guardian and g.masjid_id = v_masjid;
  if v_household is null then
    raise exception 'No guardian with that id is on the books.'
      using errcode = '22023';
  end if;

  if exists (select 1 from public.madrasah_parent_logins l
              where l.guardian_id = p_guardian) then
    raise exception 'That guardian already has a login.' using errcode = '23505';
  end if;

  --  A login that reaches no child teaches a family that the system is
  --  broken. Refused the way create_teacher_login refuses a teacher with no
  --  class, and the health check keeps watching for it afterwards.
  select count(*) into v_children
    from public.madrasah_pupils p
   where p.household_id = v_household and p.masjid_id = v_masjid
     and p.left_on is null;
  if v_children = 0 then
    raise exception 'That household has no child on the roll, so a login would '
                    'show a parent an empty screen.' using errcode = '22023';
  end if;

  if exists (select 1 from auth.users u where lower(u.email) = v_email) then
    raise exception 'That email address already has an account.'
      using errcode = '23505';
  end if;

  --  All eight token columns are written as '' - see db/094. NULL in any of
  --  them makes the auth service fail before it checks the password.
  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token)
  values (
    v_uid, '00000000-0000-0000-0000-000000000000', 'authenticated',
    'authenticated', v_email,
    extensions.crypt(p_password, extensions.gen_salt('bf')),
    now(),
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('full_name', v_name),
    now(), now(),
    '', '', '', '', '', '', '', '');

  insert into auth.identities (
    id, user_id, provider_id, provider, identity_data,
    last_sign_in_at, created_at, updated_at)
  values (
    gen_random_uuid(), v_uid, v_uid::text, 'email',
    jsonb_build_object('sub', v_uid::text, 'email', v_email,
                       'email_verified', true, 'phone_verified', false,
                       'full_name', v_name),
    null, now(), now());

  --  THE READ-BACK. Not the insert above, the ROW - as the auth service will
  --  scan it. `is distinct from false` also catches "no row at all". This is
  --  the check that would have caught db/093 on the day it was written.
  select not (u.confirmation_token is null
           or u.recovery_token is null
           or u.email_change is null
           or u.email_change_token_new is null
           or u.email_change_token_current is null
           or u.phone_change is null
           or u.phone_change_token is null
           or u.reauthentication_token is null)
    into v_readable
    from auth.users u where u.id = v_uid;
  if v_readable is distinct from true then
    raise exception 'The account was written with a NULL token column and '
                    'would fail to sign in with "Database error querying '
                    'schema" (db/094). Nothing was kept.'
      using errcode = 'XX000';
  end if;

  --  The profile row exists already (handle_new_user). The initial password
  --  is a ticket handed over by somebody else, so it is single-use: the
  --  portal must not show a parent anything until they have chosen their own
  --  (must_change_password() / clear_must_change_password(), db/093, work
  --  for any account).
  insert into public.profiles (id, full_name, email, must_change_password)
  values (v_uid, v_name, v_email, true)
  on conflict (id) do update
    set full_name = excluded.full_name, must_change_password = true;

  --  NO user_roles row. See the header.

  insert into public.madrasah_parent_logins
    (masjid_id, guardian_id, user_id, created_by)
  values (v_masjid, p_guardian, v_uid, auth.uid());

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'parent_login_created',
          jsonb_build_object('guardian', p_guardian, 'household', v_household,
                             'children', v_children));

  --  The password is neither returned nor stored anywhere in plain text.
  return jsonb_build_object('guardian', p_guardian, 'username', v_email,
                            'children', v_children);
end $$;

revoke all on function public.create_parent_login(uuid, text, text) from public, anon;
grant execute on function public.create_parent_login(uuid, text, text) to authenticated;

--  ---------------------------------------------------------------------
--  4. THE HEALTH CHECK
--     A parent login that reaches nothing is how a family gets told to
--     sign in to an empty screen. Three more ways it can be wrong are
--     checked with it, because each one is the same failure or worse:
--       a) the household has no pupils              (reaches nothing)
--       b) the auth user is gone or soft-deleted    (cannot sign in)
--       c) the user also holds a staff-side grant   (reaches too much: a
--          madrasah/admin/teacher role, a staff record, platform admin)
--     'parent' rows in user_roles are ignored, as staff_list() ignores them.
--     Each branch is proved to fire in the self-test below.
--  ---------------------------------------------------------------------
create or replace function public.parent_logins_reach_something()
returns jsonb language sql stable security definer
set search_path = public, pg_temp, auth as $$
  with l as (
    select pl.id, pl.guardian_id, pl.user_id,
      not exists (select 1
                    from public.madrasah_guardians g
                    join public.madrasah_pupils p on p.household_id = g.household_id
                   where g.id = pl.guardian_id)                    as reaches_nothing,
      not exists (select 1 from auth.users u
                   where u.id = pl.user_id and u.deleted_at is null) as no_user,
      (exists (select 1 from public.user_roles r
                where r.user_id = pl.user_id and r.role <> 'parent')
       or exists (select 1 from public.madrasah_staff s where s.user_id = pl.user_id)
       or exists (select 1 from public.platform_admins a where a.user_id = pl.user_id))
                                                                   as too_much
      from public.madrasah_parent_logins pl)
  select jsonb_build_object(
    'check', 'parent_logins_reach_something',
    'ok', count(*) filter (where reaches_nothing or no_user or too_much) = 0,
    'detail', case when count(*) filter (where reaches_nothing or no_user or too_much) = 0
      then case when count(*) = 0 then 'No parent logins yet.'
           else count(*) || ' parent login' || case when count(*) = 1 then '' else 's' end
                || ', every one reaches a household with children and only that.' end
      else concat_ws('; ',
        nullif(count(*) filter (where reaches_nothing), 0)
          || ' parent login(s) point at a household with no pupils - the family would sign in to an empty screen',
        nullif(count(*) filter (where no_user), 0)
          || ' parent login(s) point at an auth user that is gone or deleted',
        nullif(count(*) filter (where too_much), 0)
          || ' parent login(s) belong to an account that ALSO holds a staff role, staff record or platform-admin grant - a parent must reach one household and nothing else')
      end)
    from l;
$$;

revoke all on function public.parent_logins_reach_something() from public, anon;

--  Splice into health_check() as its own block after the auth check, the way
--  094 did it: read the live definition, find the anchor, REFUSE if it is
--  not there exactly once. The block wraps itself so a break in it shows up
--  as a failing line and not a silent pass (the lesson of 094's first try).
do $mig$
declare v_def text; v_new text; v_anchor text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'health_check';
  if v_def is null then
    raise exception '119: health_check() is not there to patch.';
  end if;
  if position('parent_logins_reach_something' in v_def) > 0 then
    raise notice '119: health_check already has the parent login check.';
    return;
  end if;

  v_anchor :=
$e$  if not v_ok then v_failing := array_append(v_failing, 'auth_rows_readable'); end if;$e$;
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception '119: the auth_rows_readable anchor was not found exactly '
                    'once in health_check. health_check was NOT changed.';
  end if;

  v_new := replace(v_def, v_anchor, v_anchor || $f$

  --  CAN EVERY PARENT LOGIN REACH ITS FAMILY, AND ONLY ITS FAMILY? Added by
  --  119. A login that reaches nothing is how a family gets told to sign in
  --  to an empty screen; a login that also holds a staff grant reaches too
  --  much.
  begin
    v_jrow := public.parent_logins_reach_something();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the parent login check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','parent_logins_reach_something',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'parent_logins_reach_something'); end if;$f$);

  if v_new = v_def then
    raise exception '119: the splice changed nothing. health_check was NOT changed.';
  end if;
  execute v_new;
  raise notice '119: health_check now includes parent_logins_reach_something.';
end $mig$;

--  ---------------------------------------------------------------------
--  5. THE PROOF, INSIDE THE MIGRATION
--     Everything below runs in a subtransaction that ends by raising a
--     sentinel and is caught, so nothing it writes survives - including the
--     auth.users rows. Anything else that goes wrong is NOT caught and
--     fails the migration.
--
--     It is written against invented rows only. The two `insert into
--     madrasah_pupils` are wrapped so that if a CHECK ever refuses one, only
--     the sqlstate escapes: CLAUDE.md, "Never run ad hoc DML against
--     madrasah_pupils bare".
--
--     A fresh database with no administrator and no class cannot run it. The
--     file says so out loud rather than pretending to have passed.
--
--     WHAT WAS SEEN TO FAIL, before this file was kept: the boundary
--     assertions were run against a deliberately leaky stand-in for
--     my_parent_children() (every pupil in the masjid), against a copy of
--     create_parent_login() that wrote NULL tokens, and against a parent who
--     was given a staff role. Each made the corresponding assertion fail.
--     Results are in .superpowers/sdd/2026-09-29-parents-portal/slice-1-report.md.
--  ---------------------------------------------------------------------
create or replace function pg_temp.as_user(p_uid uuid, p_aal text, p_masjid uuid default null)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    jsonb_strip_nulls(jsonb_build_object(
      'sub', p_uid, 'role', 'authenticated', 'aal', p_aal,
      'app_metadata', case when p_masjid is null then null
                           else jsonb_build_object('masjid_id', p_masjid) end))::text,
    true);
end $$;

do $mig$
declare
  v_admin uuid; v_masjid uuid; v_class uuid;
  v_hhA uuid; v_hhB uuid; v_gA1 uuid; v_gA2 uuid; v_gB uuid;
  v_pA1 uuid; v_pA2 uuid; v_pB1 uuid; v_real_other uuid;
  v_uA1 uuid; v_uA2 uuid; v_uB uuid;
  v_ids uuid[]; v_r text; v_n int;
begin
  select r.user_id, r.masjid_id into v_admin, v_masjid
    from public.user_roles r where r.role = 'admin' order by r.user_id limit 1;
  select c.id into v_class from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active order by c.sort_order, c.id limit 1;
  if v_admin is null or v_class is null then
    raise notice '119: SELF-TEST SKIPPED - no administrator or no active class in this database. The gates were created but NOT exercised.';
    return;
  end if;

  begin  -- rolled back by the sentinel at the bottom
    perform pg_temp.as_user(v_admin, 'aal2', v_masjid);

    --  Two invented households: A with two children and two guardians, B
    --  with one child and one guardian.
    insert into public.madrasah_households (masjid_id, reference, name)
    values (v_masjid, 'MF-999997', 'Selftest household A') returning id into v_hhA;
    insert into public.madrasah_households (masjid_id, reference, name)
    values (v_masjid, 'MF-999998', 'Selftest household B') returning id into v_hhB;
    insert into public.madrasah_guardians (masjid_id, household_id, full_name, is_primary)
    values (v_masjid, v_hhA, 'Selftest guardian A1', true) returning id into v_gA1;
    insert into public.madrasah_guardians (masjid_id, household_id, full_name)
    values (v_masjid, v_hhA, 'Selftest guardian A2') returning id into v_gA2;
    insert into public.madrasah_guardians (masjid_id, household_id, full_name, is_primary)
    values (v_masjid, v_hhB, 'Selftest guardian B', true) returning id into v_gB;
    begin
      insert into public.madrasah_pupils (masjid_id, household_id, first_name, joined_on)
      values (v_masjid, v_hhA, 'Selftestpupil', current_date) returning id into v_pA1;
      insert into public.madrasah_pupils (masjid_id, household_id, first_name, joined_on)
      values (v_masjid, v_hhA, 'Selftestpupil', current_date) returning id into v_pA2;
      insert into public.madrasah_pupils (masjid_id, household_id, first_name, joined_on)
      values (v_masjid, v_hhB, 'Selftestpupil', current_date) returning id into v_pB1;
    exception when others then
      raise exception 'refused: %', sqlstate;
    end;

    --  A child of a real household, for the "someone else's child" refusal.
    select p.id into v_real_other from public.madrasah_pupils p
     where p.masjid_id = v_masjid and p.household_id is not null
       and p.household_id not in (v_hhA, v_hhB) limit 1;

    --  create_parent_login refuses what it must - a non-admin, a short
    --  password, a household with no children on the roll.
    perform pg_temp.as_user(gen_random_uuid(), 'aal2', v_masjid);
    begin
      perform public.create_parent_login(v_gA1, 'x-selftest-a1@example.test', gen_random_uuid()::text);
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: create_parent_login accepted a caller with no role';
    exception when sqlstate '42501' then null; end;
    perform pg_temp.as_user(v_admin, 'aal1', v_masjid);
    begin
      perform public.create_parent_login(v_gA1, 'x-selftest-a1@example.test', gen_random_uuid()::text);
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: create_parent_login accepted an administrator without two-step';
    exception when sqlstate '42501' then null; end;
    perform pg_temp.as_user(v_admin, 'aal2', v_masjid);
    begin
      perform public.create_parent_login(v_gA1, 'x-selftest-a1@example.test', 'short');
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: create_parent_login accepted a short password';
    exception when sqlstate '22023' then null; end;

    --  THE REAL CALLS. The read-back inside create_parent_login has already
    --  refused if a token column were NULL; asserted again here from outside,
    --  on the rows, so the proof does not rest on the function grading itself.
    perform public.create_parent_login(v_gA1, 'x-selftest-a1@example.test', gen_random_uuid()::text);
    perform public.create_parent_login(v_gA2, 'x-selftest-a2@example.test', gen_random_uuid()::text);
    perform public.create_parent_login(v_gB,  'x-selftest-b@example.test',  gen_random_uuid()::text);
    select u.id into v_uA1 from auth.users u where u.email = 'x-selftest-a1@example.test';
    select u.id into v_uA2 from auth.users u where u.email = 'x-selftest-a2@example.test';
    select u.id into v_uB  from auth.users u where u.email = 'x-selftest-b@example.test';

    select count(*) into v_n from auth.users u
     where u.id in (v_uA1, v_uA2, v_uB)
       and (u.confirmation_token is null or u.recovery_token is null
         or u.email_change is null or u.email_change_token_new is null
         or u.email_change_token_current is null or u.phone_change is null
         or u.phone_change_token is null or u.reauthentication_token is null);
    if v_n <> 0 then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: a parent login was created with a NULL token column';
    end if;
    if (select count(*) from auth.identities i where i.user_id in (v_uA1, v_uA2, v_uB)) <> 3 then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: a parent login has no identity row';
    end if;
    if exists (select 1 from public.user_roles r where r.user_id in (v_uA1, v_uA2, v_uB)) then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: a parent login was given a role';
    end if;
    begin
      perform public.create_parent_login(v_gA1, 'x-selftest-dup@example.test', gen_random_uuid()::text);
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: a guardian was given two logins';
    exception when sqlstate '23505' then null; end;

    --  THE BOUNDARY, IN BOTH DIRECTIONS, AS EACH PARENT, AT BOTH aal LEVELS.
    --  Counts and ids only.
    for v_r in select unnest(array['aal1','aal2']) loop
      -- parent A1 and A2: exactly household A's two children
      perform pg_temp.as_user(v_uA1, v_r);
      select array_agg(c.pupil_id order by c.pupil_id) into v_ids from public.my_parent_children() c;
      if v_ids is distinct from (select array_agg(x order by x) from unnest(array[v_pA1, v_pA2]) x) then
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: parent A1 does not see exactly household A''s children (' || v_r || ')';
      end if;
      perform pg_temp.as_user(v_uA2, v_r);
      select array_agg(c.pupil_id order by c.pupil_id) into v_ids from public.my_parent_children() c;
      if v_ids is distinct from (select array_agg(x order by x) from unnest(array[v_pA1, v_pA2]) x) then
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: parent A2 does not see exactly household A''s children (' || v_r || ')';
      end if;
      -- parent B: exactly one, and it is not A's
      perform pg_temp.as_user(v_uB, v_r);
      select array_agg(c.pupil_id order by c.pupil_id) into v_ids from public.my_parent_children() c;
      if v_ids is distinct from array[v_pB1] then
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: parent B does not see exactly household B''s child (' || v_r || ')';
      end if;

      -- as parent A1: own children mine, another household's are not
      perform pg_temp.as_user(v_uA1, v_r);
      if not (public.is_parent() and public.is_my_child(v_pA1) and public.is_my_child(v_pA2)) then
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: a parent cannot reach their own child (' || v_r || ')';
      end if;
      if public.is_my_child(v_pB1) or public.is_my_child(v_real_other)
         or public.is_my_child(gen_random_uuid()) or public.is_my_child(null) then
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: is_my_child said yes to a child that is not theirs (' || v_r || ')';
      end if;
      perform public.require_my_child(v_pA1);
      begin
        perform public.require_my_child(v_pB1);
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: require_my_child accepted another household''s pupil (' || v_r || ')';
      exception when sqlstate '42501' then null; end;
      begin
        perform public.require_my_child(v_real_other);
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: require_my_child accepted a real family''s pupil (' || v_r || ')';
      exception when sqlstate '42501' then null; end;

      -- a parent is NOT staff: representative staff functions refuse them,
      -- and so do the two predicates. Booleans and sqlstates only.
      if public.verified_madrasah() or public.verified_admin() then
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: a parent satisfied verified_madrasah() or verified_admin() (' || v_r || ')';
      end if;
      if (public.madrasah_roll_count() ->> 'allowed') is distinct from 'false' then
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: madrasah_roll_count() answered a parent (' || v_r || ')';
      end if;
      if (public.registers_missing_count() ->> 'allowed') is distinct from 'false' then
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: registers_missing_count() answered a parent (' || v_r || ')';
      end if;
      begin
        perform public.madrasah_pupil_one(v_pA1);
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: madrasah_pupil_one() opened a record for a parent (' || v_r || ')';
      exception when sqlstate '42501' then null; end;
      begin
        perform public.create_parent_login(v_gA2, 'x-selftest-x@example.test', gen_random_uuid()::text);
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: a parent created a login (' || v_r || ')';
      exception when sqlstate '42501' then null; end;
    end loop;

    --  Staff, and a stranger, reach no children through this door.
    perform pg_temp.as_user(v_admin, 'aal2', v_masjid);
    if public.is_parent() or exists (select 1 from public.my_parent_children()) then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: an administrator is treated as a parent';
    end if;
    perform pg_temp.as_user(gen_random_uuid(), 'aal1');
    if public.is_parent() or exists (select 1 from public.my_parent_children()) then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: a stranger reaches children';
    end if;
    perform set_config('request.jwt.claims', '', true);
    if public.is_parent() or exists (select 1 from public.my_parent_children()) then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: no session at all reaches children';
    end if;

    --  THE HEALTH CHECK: healthy first, then each fault, each one undone.
    if (public.parent_logins_reach_something() ->> 'ok') is distinct from 'true' then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: the parent login check fails on healthy logins';
    end if;

    begin  -- (a) a household that ends up with no pupils
      begin
        delete from public.madrasah_pupils where household_id = v_hhB;
      exception when others then raise exception 'refused: %', sqlstate; end;
      v_r := public.parent_logins_reach_something() ->> 'ok';
      raise exception using errcode = 'P0999', message = 'rollback';
    exception when sqlstate 'P0999' then null; end;
    if v_r is distinct from 'false' then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: the health check did not fire for a household with no pupils';
    end if;

    begin  -- (b) a soft-deleted auth user
      update auth.users set deleted_at = now() where id = v_uB;
      v_r := public.parent_logins_reach_something() ->> 'ok';
      raise exception using errcode = 'P0999', message = 'rollback';
    exception when sqlstate 'P0999' then null; end;
    if v_r is distinct from 'false' then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: the health check did not fire for a deleted auth user';
    end if;

    begin  -- (c1) a parent handed a staff role - and the gate test can fail:
           --      with the role, and two-step, this parent DOES satisfy
           --      verified_madrasah(), which is exactly why (c) exists.
      insert into public.user_roles (user_id, role, masjid_id) values (v_uB, 'madrasah', v_masjid);
      v_r := public.parent_logins_reach_something() ->> 'ok';
      perform pg_temp.as_user(v_uB, 'aal2');
      if not public.verified_madrasah() then
        raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: the staff-gate control did not fire - a parent with a madrasah role and two-step should satisfy verified_madrasah()';
      end if;
      raise exception using errcode = 'P0999', message = 'rollback';
    exception when sqlstate 'P0999' then null; end;
    if v_r is distinct from 'false' then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: the health check did not fire for a parent holding a staff role';
    end if;

    begin  -- (c2) a parent who is also a member of staff
      insert into public.madrasah_staff (masjid_id, first_name, user_id)
      values (v_masjid, 'Selftest', v_uB);
      v_r := public.parent_logins_reach_something() ->> 'ok';
      raise exception using errcode = 'P0999', message = 'rollback';
    exception when sqlstate 'P0999' then null; end;
    if v_r is distinct from 'false' then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: the health check did not fire for a parent with a staff record';
    end if;

    begin  -- (c3) a parent who is a platform administrator
      insert into public.platform_admins (user_id) values (v_uB);
      v_r := public.parent_logins_reach_something() ->> 'ok';
      raise exception using errcode = 'P0999', message = 'rollback';
    exception when sqlstate 'P0999' then null; end;
    if v_r is distinct from 'false' then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: the health check did not fire for a parent with platform-admin';
    end if;

    --  And health_check() itself carries the line and reports it.
    perform pg_temp.as_user(v_admin, 'aal2', v_masjid);
    if not exists (select 1 from jsonb_array_elements(public.health_check() -> 'checks') c
                    where c ->> 'check' = 'parent_logins_reach_something'
                      and (c ->> 'ok')::boolean) then
      raise exception using errcode = 'P0998', message = 'SELFTEST FAILED: health_check() does not carry a passing parent login line';
    end if;

    raise exception using errcode = 'P0999', message = 'rollback';
  exception when sqlstate 'P0999' then null;
  end;

  perform set_config('request.jwt.claims', '', true);

  --  Nothing may have survived the rollback.
  if exists (select 1 from auth.users where email like 'x-selftest-%@example.test')
     or exists (select 1 from public.madrasah_households where reference in ('MF-999997','MF-999998')) then
    raise exception '119: the self-test left rows behind.';
  end if;
  raise notice '119: self-test passed and was rolled back.';
end $mig$;

--  ---------------------------------------------------------------------
--  Restated, because it is the whole security posture of this file: the
--  table has RLS on, no policy and no grant; the six functions below are
--  SECURITY DEFINER owned by postgres with search_path = public, pg_temp;
--  anon has EXECUTE on NONE of them.
--    is_parent, my_parent_children, is_my_child, require_my_child,
--    create_parent_login            -> authenticated only
--    parent_logins_reach_something  -> nobody but health_check()
--  ---------------------------------------------------------------------
