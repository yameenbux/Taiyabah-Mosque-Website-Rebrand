-- =============================================================================
--  Taiyabah Masjid — UNDO migration 011
--
--  Puts every policy back exactly as it was before two-step verification was
--  enforced in the database. Paste the whole file into the Supabase SQL editor
--  and press Run. It takes effect immediately — no restart, no redeploy.
--
--  WHEN TO USE IT
--    Only if applying 011 has locked staff out and you cannot see why. The
--    symptom would be: signed in, authenticator code accepted, and the portal
--    still shows an empty list.
--
--  WHAT IT COSTS
--    Reverting reopens the hole 011 closed: a staff email address and password
--    alone can then read every hall booking, nikāḥ request and — once 008 is
--    applied — every admission application, straight from the API. Treat this
--    as buying an hour to work out what went wrong, not as a fix.
--
--  A NOTE ON WHY THE SQL EDITOR ALWAYS WORKS
--    The editor runs as `postgres`, a superuser, and superusers ignore row
--    level security entirely. So no policy change can ever lock you out of the
--    editor itself. Whatever else happens, you can always get back in here and
--    paste this.
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
-- line: psql -v ON_ERROR_STOP=1 -f 011_ROLLBACK.sql

-- Walked rather than written out as statements, for the same reason as the
-- migration: 008, 009 and 010 are not applied yet, so their tables do not
-- exist, and a statement naming a missing table would stop the whole rollback
-- dead — at the exact moment you least want that.
do $$
declare
  p       record;
  done    int := 0;
  skipped int := 0;
begin
  for p in
    select * from (values
      ('hall_bookings',             'office reads every request',  'public.can_see_bookings()', null),
      ('hall_bookings',             'office updates requests',     'public.can_see_bookings()', 'public.can_see_bookings()'),

      ('nikah_requests',            'office_read_nikah',
         'public.is_admin() or public.has_role(auth.uid(), ''hall_office'')', null),
      ('nikah_requests',            'office_update_nikah',
         'public.is_admin() or public.has_role(auth.uid(), ''hall_office'')',
         'public.is_admin() or public.has_role(auth.uid(), ''hall_office'')'),

      ('admission_applications',    'admin_read_applications',     'public.is_admin()', null),
      ('admission_applications',    'admin_update_applications',   'public.is_admin()', 'public.is_admin()'),
      ('admission_students',        'admin_read_students',         'public.is_admin()', null),
      ('admission_contacts',        'admin_read_contacts',         'public.is_admin()', null),
      ('admission_student_choices', 'admin_read_choices',          'public.is_admin()', null),

      ('course_registrations',      'admin_read_registrations',    'public.is_admin()', null),
      ('course_registrations',      'admin_update_registrations',  'public.is_admin()', 'public.is_admin()'),
      ('courses',                   'admin_read_courses',          'public.is_admin()', null),

      ('profiles',                  'profiles: admins read all',   'public.is_admin()', null),
      ('profiles',                  'profiles: admins manage all', 'public.is_admin()', 'public.is_admin()'),
      ('user_roles',                'user_roles: admins read all', 'public.is_admin()', null),
      ('user_roles',                'user_roles: admins manage',   'public.is_admin()', 'public.is_admin()'),

      ('admin_audit',               'admin_audit: admins read',    'public.is_admin()', null)
    ) as t(tbl, pol, using_expr, check_expr)
  loop
    if to_regclass('public.' || quote_ident(p.tbl)) is null
       or not exists (select 1 from pg_policies
                       where schemaname = 'public'
                         and tablename  = p.tbl
                         and policyname = p.pol) then
      skipped := skipped + 1;
      continue;
    end if;

    execute format(
      'alter policy %I on public.%I using (%s)%s',
      p.pol, p.tbl, p.using_expr,
      case when p.check_expr is null then ''
           else ' with check (' || p.check_expr || ')' end);
    done := done + 1;
  end loop;

  raise notice 'Reverted % policies. % skipped because their tables do not exist here.',
    done, skipped;
end $$;


-- Confirm. Expect 0 — nothing left requiring two-step.
select count(*) as policies_still_requiring_two_step
from pg_policies
where schemaname = 'public'
  and coalesce(qual, '') ~ 'verified_(admin|office)';

-- The three helper functions are left in place deliberately. They are harmless
-- when no policy calls them, and leaving them means re-applying 011 later is
-- just 011 again rather than a hunt for what was removed.
