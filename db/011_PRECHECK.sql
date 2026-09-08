-- =============================================================================
--  Taiyabah Masjid — RUN THIS FIRST, BEFORE 011
--
--  Read-only. It changes nothing and is safe to run as many times as you like.
--
--  Migration 011 makes the database refuse staff data to anyone who has not
--  entered their authenticator code. A staff account with no authenticator set
--  up can never do that, so after 011 it would see nothing at all. 011 refuses
--  to apply in that situation — but it is better to know before you try than
--  to read it in an error message.
--
--  Paste the whole file into the Supabase SQL editor and press Run.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Who holds a staff role, and can they reach two-step?
--
--    Every row must say READY. Anyone showing NO AUTHENTICATOR needs to sign
--    in to their portal once first — it walks them through setting up the app.
-- -----------------------------------------------------------------------------
select
  coalesce(u.email, ur.user_id::text)                as account,
  string_agg(distinct ur.role::text, ', ' order by ur.role::text) as roles,
  case when count(f.id) filter (where f.status = 'verified') > 0
       then 'READY'
       else 'NO AUTHENTICATOR — fix before running 011'
  end                                                as two_step
from public.user_roles ur
join auth.users u        on u.id = ur.user_id
left join auth.mfa_factors f on f.user_id = ur.user_id
where ur.role in ('admin', 'hall_office', 'teacher')
group by 1
order by 3 desc, 1;


-- -----------------------------------------------------------------------------
-- 2. Are there at least two administrators?
--
--    Not something 011 changes, but this is the moment you will notice.
--    Deleting the only admin account destroys its roles and profile by cascade,
--    and nobody is then left who can grant the role back. Two is the minimum
--    that survives one person losing their phone.
-- -----------------------------------------------------------------------------
select count(*) as administrators,
       case when count(*) >= 2 then 'fine'
            when count(*) = 1  then 'ONLY ONE ADMIN — create a second before going much further'
            else 'NO ADMINISTRATORS AT ALL — stop and work out why before running anything'
       end as verdict
from public.user_roles
where role = 'admin';


-- -----------------------------------------------------------------------------
-- 3. Has 011 been applied, and is anything still unprotected?
--
--    Two numbers. The first is how many staff policies now require the
--    authenticator code. The second is how many still do not — and that one
--    must be zero.
--
--    It will not be zero if you have applied 008, 009 or 010 since the last
--    time you ran 011. Those migrations create their own policies, and they
--    create them WITHOUT the check. The fix is simply to run
--    011_require_two_step.sql again; it is safe to run as many times as you
--    like.
-- -----------------------------------------------------------------------------
select
  count(*) filter (where qual ~ 'verified_(admin|office)')  as protected,
  count(*) filter (where qual !~ 'verified_(admin|office)') as still_open,
  case when count(*) filter (where qual !~ 'verified_(admin|office)') = 0
       then 'nothing outstanding'
       else 'RUN 011_require_two_step.sql AGAIN'
  end as verdict
from pg_policies
where schemaname = 'public'
  and coalesce(qual, '') <> ''
  and qual <> 'true'                    -- the definer-only policies
  -- The only policies that are SUPPOSED to have no check, named explicitly.
  -- An earlier version excluded anything whose rule mentioned auth.uid(), which
  -- silently swallowed the nikāḥ policies — their rule is
  -- "is_admin() or has_role(auth.uid(), 'hall_office')" — and reported all
  -- clear while that table was wide open. Naming the three exceptions is the
  -- only version of this that cannot lie.
  and (tablename, policyname) not in (
        ('profiles',   'profiles: read own'),
        ('profiles',   'profiles: update own'),
        ('user_roles', 'user_roles: read own'))
  and tablename in ('hall_bookings','nikah_requests','profiles','user_roles',
                    'admin_audit','courses','course_registrations',
                    'admission_applications','admission_students',
                    'admission_contacts','admission_student_choices');


-- -----------------------------------------------------------------------------
-- 4. Name them, if there are any.
--
--    Empty is the answer you want. Any row here is a table a member of staff
--    can read with a password alone.
-- -----------------------------------------------------------------------------
select tablename, policyname, qual as current_rule
from pg_policies
where schemaname = 'public'
  and coalesce(qual, '') <> ''
  and qual <> 'true'
  and qual !~ 'verified_(admin|office)'
  -- The only policies that are SUPPOSED to have no check, named explicitly.
  -- An earlier version excluded anything whose rule mentioned auth.uid(), which
  -- silently swallowed the nikāḥ policies — their rule is
  -- "is_admin() or has_role(auth.uid(), 'hall_office')" — and reported all
  -- clear while that table was wide open. Naming the three exceptions is the
  -- only version of this that cannot lie.
  and (tablename, policyname) not in (
        ('profiles',   'profiles: read own'),
        ('profiles',   'profiles: update own'),
        ('user_roles', 'user_roles: read own'))
  and tablename in ('hall_bookings','nikah_requests','profiles','user_roles',
                    'admin_audit','courses','course_registrations',
                    'admission_applications','admission_students',
                    'admission_contacts','admission_student_choices')
order by tablename, policyname;
