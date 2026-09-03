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

\set ON_ERROR_STOP on


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
as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;

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
--    `alter policy` rather than drop-and-create, so there is never a moment
--    where a table is readable with no policy at all.
-- -----------------------------------------------------------------------------

-- Hall bookings -------------------------------------------------------------
alter policy "office reads every request"  on public.hall_bookings
  using (public.verified_office());
alter policy "office updates requests"     on public.hall_bookings
  using (public.verified_office())
  with check (public.verified_office());

-- Nikāḥ requests ------------------------------------------------------------
alter policy office_read_nikah   on public.nikah_requests
  using (public.verified_office());
alter policy office_update_nikah on public.nikah_requests
  using (public.verified_office())
  with check (public.verified_office());

-- Admissions — the most sensitive data on the site --------------------------
alter policy admin_read_applications   on public.admission_applications
  using (public.verified_admin());
alter policy admin_update_applications on public.admission_applications
  using (public.verified_admin())
  with check (public.verified_admin());
alter policy admin_read_students on public.admission_students
  using (public.verified_admin());
alter policy admin_read_contacts on public.admission_contacts
  using (public.verified_admin());
alter policy admin_read_choices  on public.admission_student_choices
  using (public.verified_admin());

-- Course sign-ups -----------------------------------------------------------
alter policy admin_read_registrations   on public.course_registrations
  using (public.verified_admin());
alter policy admin_update_registrations on public.course_registrations
  using (public.verified_admin())
  with check (public.verified_admin());
alter policy admin_read_courses on public.courses
  using (public.verified_admin());

-- Profiles and roles --------------------------------------------------------
--   "read own" and "update own" are left alone on purpose — see the header.
--   Everything that reaches ACROSS accounts now needs the code, and that
--   includes granting roles, which is the single most dangerous thing an
--   administrator can do.
alter policy "profiles: admins read all" on public.profiles
  using (public.verified_admin());
alter policy "profiles: admins manage all" on public.profiles
  using (public.verified_admin())
  with check (public.verified_admin());
alter policy "user_roles: admins read all" on public.user_roles
  using (public.verified_admin());
alter policy "user_roles: admins manage" on public.user_roles
  using (public.verified_admin())
  with check (public.verified_admin());

-- The audit trail -----------------------------------------------------------
--   Reading it needs the code. Writing to it does not: the insert policy is
--   `auth.uid() is not null`, and SECURITY DEFINER functions write here as
--   part of ordinary work. An audit trail that can fail to record is worse
--   than one that can be read by the wrong person.
alter policy "admin_audit: admins read" on public.admin_audit
  using (public.verified_admin());


-- =============================================================================
--  IF THIS LOCKS SOMEBODY OUT
--
--  It should not — section 0 refuses to apply while any staff account lacks a
--  verified authenticator. But if you need the old behaviour back in a hurry,
--  this puts every policy exactly as it was. Run it from the Supabase SQL
--  editor, which is not subject to RLS:
--
--    alter policy "office reads every request" on public.hall_bookings
--      using (public.can_see_bookings());
--    alter policy "office updates requests" on public.hall_bookings
--      using (public.can_see_bookings()) with check (public.can_see_bookings());
--    alter policy office_read_nikah on public.nikah_requests
--      using (public.is_admin() or public.has_role(auth.uid(),'hall_office'));
--    alter policy office_update_nikah on public.nikah_requests
--      using (public.is_admin() or public.has_role(auth.uid(),'hall_office'))
--      with check (public.is_admin() or public.has_role(auth.uid(),'hall_office'));
--    alter policy admin_read_applications   on public.admission_applications using (public.is_admin());
--    alter policy admin_update_applications on public.admission_applications using (public.is_admin()) with check (public.is_admin());
--    alter policy admin_read_students on public.admission_students using (public.is_admin());
--    alter policy admin_read_contacts on public.admission_contacts using (public.is_admin());
--    alter policy admin_read_choices  on public.admission_student_choices using (public.is_admin());
--    alter policy admin_read_registrations   on public.course_registrations using (public.is_admin());
--    alter policy admin_update_registrations on public.course_registrations using (public.is_admin()) with check (public.is_admin());
--    alter policy admin_read_courses on public.courses using (public.is_admin());
--    alter policy "profiles: admins read all"   on public.profiles using (public.is_admin());
--    alter policy "profiles: admins manage all" on public.profiles using (public.is_admin()) with check (public.is_admin());
--    alter policy "user_roles: admins read all" on public.user_roles using (public.is_admin());
--    alter policy "user_roles: admins manage"   on public.user_roles using (public.is_admin()) with check (public.is_admin());
--    alter policy "admin_audit: admins read"    on public.admin_audit using (public.is_admin());
--
--  Reverting reopens the hole. Treat it as buying an hour, not as a fix.
--
--
--  ONE THING THIS DOES NOT SOLVE
--
--  A person who is signed in at aal2 in a real browser session is trusted for
--  as long as that session lasts. Two-step verification stops a stolen
--  password; it does not stop a borrowed, unlocked laptop. The office still
--  needs to lock its screens.
-- =============================================================================
