-- =============================================================================
--  Taiyabah Masjid
--  Migration 011: make the database require two-step verification
--
--  WHY
--    The staff portals ask for an authenticator code. Until now that code was
--    checked in JavaScript and nowhere else. Anyone holding a staff email
--    address and password could skip the page entirely — curl, Postman, the
--    browser console — and read hall bookings, nikāḥ requests, admission
--    applications and course sign-ups straight from the API. The code prompt
--    was a locked front door on a building with the windows open.
--
--    This migration moves the check into Postgres, where it cannot be skipped.
--    A session that signed in with a password only (aal1) can no longer read
--    or change any of it. The same session after entering its authenticator
--    code (aal2) works exactly as before.
--
--  WHAT IT DELIBERATELY DOES NOT TOUCH
--    * `profiles: read own` and `user_roles: read own`. The account page and
--      /portals/ read these BEFORE the code is entered, to work out whether to
--      show an administrator their admin button. They return the signed-in
--      person's own two rows and nothing else, which is not worth protecting
--      at the cost of breaking the signpost.
--    * The public submission policies (`anyone may submit a request`, and every
--      `definer_*` policy). Members of the public are not signed in at all and
--      must stay able to submit a booking, an application or a nikāḥ request.
--
--  THE RULE FROM HERE ON
--    Any new policy that lets a signed-in member of staff read or change other
--    people's data must go through public.verified_admin() or
--    public.verified_office(), never is_admin() or can_see_bookings() directly.
--    `_test_two_step.sql` scans pg_policies and fails if that rule is broken,
--    so this is enforced rather than merely written down.
-- =============================================================================

-- NOTE: there is deliberately no `\set ON_ERROR_STOP on` here.
--
-- That is a psql command, not SQL, and the Supabase SQL editor is not psql —
-- it hands the text straight to Postgres, which has never heard of it. Pasting
-- it produced `syntax error at or near "on"` and stopped the migration dead.
--
-- Nothing is lost by removing it. The editor stops at the first error anyway,
-- and every statement below is idempotent: `create or replace`, `alter policy`,
-- `grant` and `revoke` can all be run again over the top of themselves. If this
-- ever stops half way through, the fix is to run the whole file again.
--
-- If you are running it through psql instead, pass the flag on the command
-- line: psql -v ON_ERROR_STOP=1 -f 011_require_two_step.sql


-- -----------------------------------------------------------------------------
-- 0. Safety check — is anyone about to be locked out?
--
--    A staff account with no verified authenticator can never reach aal2, and
--    after this migration it can never see anything either. That is not a
--    disaster if it is one teacher; it is a disaster if it is every
--    administrator, because nobody is left who can grant a role.
--
--    So: look first, and refuse to apply if it would lock somebody out. Read
--    the names it prints, get those people to sign in to a portal once (the
--    portal walks them through setting up the app), then run this again.
--
--    On a local test database auth.mfa_factors does not exist. The check says
--    so and carries on rather than failing, because there are no real people
--    on a local database to lock out.
-- -----------------------------------------------------------------------------
do $$
declare
  stranded text;
begin
  if to_regclass('auth.mfa_factors') is null then
    raise notice 'auth.mfa_factors not present — skipping the lockout check. '
                 'Expected on a local test database, NOT on Supabase.';
    return;
  end if;

  execute $q$
    select string_agg(distinct coalesce(u.email, ur.user_id::text), ', ')
      from public.user_roles ur
      join auth.users u on u.id = ur.user_id
     where ur.role in ('admin','hall_office','teacher')
       and not exists (
             select 1 from auth.mfa_factors f
              where f.user_id = ur.user_id
                and f.status  = 'verified')
  $q$ into stranded;

  if stranded is not null then
    raise exception
      E'These staff accounts have no verified authenticator and would be locked '
      'out by this migration:\n\n    %\n\n'
      'Ask each of them to sign in to their portal once — it walks them through '
      'setting up the app — then run this migration again. Do not work around '
      'this check.', stranded;
  end if;

  raise notice 'Lockout check passed: every staff account has a verified authenticator.';
end $$;


-- -----------------------------------------------------------------------------
-- 1. What "verified" means
--
--    Supabase puts an `aal` claim in the JWT: aal1 for password only, aal2
--    once an authenticator code has been accepted this session. auth.jwt()
--    reads it out of the request.
--
--    Note what is NOT done here: is_admin() and can_see_bookings() are left
--    telling the truth. A function called is_admin() that returns false for an
--    actual administrator is the sort of thing that costs somebody an evening.
--    The verification is a separate, visibly-named condition instead, so that
--    reading pg_policies tells you the rule.
-- -----------------------------------------------------------------------------
create or replace function public.is_aal2()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;
-- SECURITY DEFINER on purpose, and it grants nothing.
--
-- auth.jwt() reads a session setting that PostgREST puts there for the current
-- request, so who executes it makes no difference to the answer. What it does
-- change is the failure mode: if `authenticated` ever lost EXECUTE on
-- auth.jwt(), a plain function would raise inside every policy on every table
-- at once, and the whole staff side would go down with an error nobody could
-- read. Running as the owner removes that possibility.
--
-- search_path is empty and every name below is schema-qualified, which is what
-- stops a SECURITY DEFINER function being hijacked by a shadowing object.

comment on function public.is_aal2() is
  'True only when this session has passed two-step verification (JWT aal claim = aal2).';

create or replace function public.verified_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_aal2() and public.is_admin();
$$;

comment on function public.verified_admin() is
  'An administrator who has entered their authenticator code this session.';

create or replace function public.verified_office()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_aal2() and public.can_see_bookings();
$$;

comment on function public.verified_office() is
  'Hall office or administrator, who has entered their authenticator code this session.';

grant execute on function public.is_aal2()        to authenticated;
grant execute on function public.verified_admin() to authenticated;
grant execute on function public.verified_office() to authenticated;

-- anon has no business calling these, and giving it nothing is cheaper than
-- reasoning about what it could do with them.
revoke all on function public.is_aal2()         from anon;
revoke all on function public.verified_admin()  from anon;
revoke all on function public.verified_office() from anon;


-- -----------------------------------------------------------------------------
-- 2. Point every staff-facing policy at the verified versions
--
--    Only the ones that exist. Migrations 008, 009 and 010 are not applied yet
--    on the masjid's project, so their tables are not there — and an
--    `alter policy` naming a missing table stops the whole migration dead. It
--    did exactly that the first time this was run, because it had only ever
--    been tested against a database where every later migration was present.
--
--    So the list is walked rather than written out as statements. Anything not
--    yet created is skipped and named in a notice, and re-running this file
--    after applying 008, 009 or 010 picks up the new policies.
--
--    >>> RE-RUN THIS FILE AFTER APPLYING 008, 009 OR 010. <<<
--    011_PRECHECK.sql tells you at any time whether anything has been missed.
--
--    `alter policy` rather than drop-and-create, so there is never a moment
--    where a table is readable with no policy at all.
-- -----------------------------------------------------------------------------
do $$
declare
  p        record;
  done     int := 0;
  skipped  text[] := '{}';
begin
  for p in
    select * from (values
      -- table                        policy                          using                      with check
      ('hall_bookings',              'office reads every request',    'public.verified_office()', null),
      ('hall_bookings',              'office updates requests',       'public.verified_office()', 'public.verified_office()'),

      ('nikah_requests',             'office_read_nikah',             'public.verified_office()', null),
      ('nikah_requests',             'office_update_nikah',           'public.verified_office()', 'public.verified_office()'),

      -- Admissions: the most sensitive data on the site.
      ('admission_applications',     'admin_read_applications',       'public.verified_admin()',  null),
      ('admission_applications',     'admin_update_applications',     'public.verified_admin()',  'public.verified_admin()'),
      ('admission_students',         'admin_read_students',           'public.verified_admin()',  null),
      ('admission_contacts',         'admin_read_contacts',           'public.verified_admin()',  null),
      ('admission_student_choices',  'admin_read_choices',            'public.verified_admin()',  null),

      ('course_registrations',       'admin_read_registrations',      'public.verified_admin()',  null),
      ('course_registrations',       'admin_update_registrations',    'public.verified_admin()',  'public.verified_admin()'),
      ('courses',                    'admin_read_courses',            'public.verified_admin()',  null),

      -- Profiles and roles. "read own" and "update own" are left alone on
      -- purpose — see the header. Everything that reaches ACROSS accounts now
      -- needs the code, and that includes granting roles, which is the single
      -- most dangerous thing an administrator can do.
      ('profiles',                   'profiles: admins read all',     'public.verified_admin()',  null),
      ('profiles',                   'profiles: admins manage all',   'public.verified_admin()',  'public.verified_admin()'),
      ('user_roles',                 'user_roles: admins read all',   'public.verified_admin()',  null),
      ('user_roles',                 'user_roles: admins manage',     'public.verified_admin()',  'public.verified_admin()'),

      -- The audit trail. Reading it needs the code. Writing to it does not:
      -- the insert policy is `auth.uid() is not null`, and SECURITY DEFINER
      -- functions write here as part of ordinary work. An audit trail that can
      -- fail to record is worse than one read by the wrong person.
      ('admin_audit',                'admin_audit: admins read',      'public.verified_admin()',  null)
    ) as t(tbl, pol, using_expr, check_expr)
  loop
    if to_regclass('public.' || quote_ident(p.tbl)) is null then
      -- name each missing table once, not once per policy on it
      if not (p.tbl = any (skipped)) then
        skipped := skipped || p.tbl;
      end if;
      continue;
    end if;

    if not exists (select 1 from pg_policies
                    where schemaname = 'public'
                      and tablename  = p.tbl
                      and policyname = p.pol) then
      skipped := skipped || (p.tbl || '.' || p.pol || ' (policy not found)');
      continue;
    end if;

    execute format(
      'alter policy %I on public.%I using (%s)%s',
      p.pol, p.tbl, p.using_expr,
      case when p.check_expr is null then ''
           else ' with check (' || p.check_expr || ')' end);
    done := done + 1;
  end loop;

  raise notice '% policies now require two-step verification.', done;

  if array_length(skipped, 1) > 0 then
    raise notice 'SKIPPED, because these do not exist here yet: %',
      array_to_string(skipped, ', ');
    raise notice 'That is expected while 008, 009 and 010 are unapplied. '
                 'RUN THIS FILE AGAIN after applying any of them, or those '
                 'tables will be readable with a password alone.';
  end if;
end $$;


-- =============================================================================
--  IF THIS LOCKS SOMEBODY OUT
--
--  It should not — section 0 refuses to apply while any staff account lacks a
--  verified authenticator. If it happens anyway, run `011_ROLLBACK.sql` in the
--  SQL editor. It puts every policy back exactly as it was, immediately, and
--  skips anything not yet created in the same way this file does.
--
--  Do not paste the old policy definitions out of a comment block by hand.
--  That is how the first attempt at this migration failed: statements naming
--  tables that do not exist on this project stop everything dead.
--
--  Reverting reopens the hole. Treat it as buying an hour, not as a fix.
--
--  The SQL editor runs as `postgres`, a superuser, and superusers ignore row
--  level security entirely — so no policy change here can ever lock you out of
--  the editor itself. Whatever else happens, you can always get back in and
--  paste the rollback.
--
--
--  ONE THING THIS DOES NOT SOLVE
--
--  A person signed in at aal2 in a real browser session is trusted for as long
--  as that session lasts. Two-step verification stops a stolen password; it
--  does not stop a borrowed, unlocked laptop. The office still needs to lock
--  its screens.
-- =============================================================================
