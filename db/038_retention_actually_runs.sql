-- ===========================================================================
--  038_retention_actually_runs.sql — the two most sensitive tables were the
--  two nothing ever purged
--
--  *** APPLIED TO PRODUCTION 15 September 2026. ***
--
--  015 set this masjid's retention policy and the purge functions were
--  written. Eight cron jobs run them. Listing what is actually scheduled
--  against what actually exists gives this:
--
--      purge_old_hall_bookings           scheduled, Mondays
--      purge_old_nikah_requests          scheduled, Mondays
--      purge_old_course_registrations    scheduled, Mondays
--      purge_old_donations               scheduled, nightly
--      purge_old_volunteers              scheduled, nightly
--      purge_expired_holds               scheduled, every 10 minutes
--      purge_expired_invites             scheduled, nightly
--      purge_old_admission_applications  NEVER SCHEDULED
--      purge_old_charity_collections     NEVER SCHEDULED
--
--  The two that were never scheduled hold, between them:
--
--    * every child on a madrasah application — name, date of birth, gender,
--      school, SEND status, EHCP, ALLERGIES and MEDICAL CONDITIONS. Most of
--      that is special category data under Article 9 of the UK GDPR and it
--      belongs to children.
--    * every charity collection trustee — somebody who never filled a form
--      in, never visited the site, and gave nothing to the masjid directly.
--
--  So the masjid's retention policy was being honoured everywhere except on
--  the two datasets where failing to honour it matters most. Not by anybody's
--  decision — the functions exist and read correctly — simply because nobody
--  wrote the two `cron.schedule` lines.
--
--  WHY THEY COULD NOT HAVE BEEN SCHEDULED ANYWAY
--  ---------------------------------------------
--  This is the part that made it invisible. Both functions open with
--
--      if not public.is_admin() then raise exception ...
--
--  which is right for a button in the portal and FATAL for a cron job.
--  pg_cron runs with no JWT, so auth.uid() is null, so is_admin() is false,
--  so the function raises. Adding the schedule alone would have produced two
--  jobs that failed silently every night — arguably worse than no jobs at
--  all, because the dashboard would show them scheduled.
--
--  Every other purge function has no such guard: they are granted to postgres
--  and nobody else, and the ACL is the protection. These two also carry an
--  `authenticated` grant so an administrator can purge on demand, which is
--  why they need a guard the others do not.
--
--  WHAT THIS CHANGES
--
--    1. The guard becomes "if somebody is signed in, they must be a VERIFIED
--       admin". No JWT at all means an internal caller — cron — and is
--       allowed. anon cannot reach either function (no EXECUTE grant), so
--       this does not open a door.
--
--    2. is_admin() becomes verified_admin(), which is 011's rule and was
--       simply missed here. It matters concretely: the README records that
--       one of the three administrators has no authenticator, so under the
--       old guard that person could delete children's records with a
--       password alone.
--
--    3. Both get a nightly schedule, twelve months, matching 015.
--
--  WHAT IT DELIBERATELY DOES NOT CHANGE. Neither function's delete clause is
--  touched. Both only remove rows in a terminal state — 'declined' and
--  'withdrawn' for applications, plus 'completed' for collections — and only
--  once they are past the window. A live application is never purged by
--  either, and a child who was OFFERED a place keeps their record, because
--  they became a pupil and the madrasah portal is the system of record from
--  that point.
-- ===========================================================================

begin;

create or replace function public.purge_old_admission_applications(retain_months integer)
returns integer
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare v_deleted int;
begin
  --  auth.uid() IS NULL means no JWT at all, which means this is pg_cron or
  --  a psql session, not a browser. A signed-in caller must be a verified
  --  administrator. anon has no EXECUTE grant here, so "no JWT" cannot be
  --  reached from the public API.
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may purge applications'
      using errcode = '42501';
  end if;
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be a positive number of months';
  end if;

  with gone as (
    delete from public.admission_applications
     where status in ('declined','withdrawn')
       and submitted_at < now() - make_interval(months => retain_months)
    returning 1
  )
  select count(*) into v_deleted from gone;

  insert into public.admin_audit (action, detail)
  values ('admission_applications_purged',
          jsonb_build_object('deleted', v_deleted, 'retain_months', retain_months));

  return v_deleted;
end;
$fn$;

create or replace function public.purge_old_charity_collections(retain_months integer)
returns integer
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare v_deleted int;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may purge collection requests'
      using errcode = '42501';
  end if;
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be a positive number of months';
  end if;

  with gone as (
    delete from public.charity_collections
     where status in ('declined','withdrawn','completed')
       and submitted_at < now() - make_interval(months => retain_months)
    returning 1
  )
  select count(*) into v_deleted from gone;

  insert into public.admin_audit (action, detail)
  values ('charity_collections_purged',
          jsonb_build_object('deleted', v_deleted, 'retain_months', retain_months));

  return v_deleted;
end;
$fn$;

commit;

-- ---------------------------------------------------------------------------
--  The schedules. Nightly, in the same quiet hour as the others, in gaps
--  between the existing jobs so two purges never start together.
--
--      03:15  donations        03:25  volunteers      03:35  invites
--      03:45  ADMISSIONS       03:55  COLLECTIONS
-- ---------------------------------------------------------------------------
select cron.schedule('purge-admission-applications', '45 3 * * *',
                     $$select public.purge_old_admission_applications(12)$$);

select cron.schedule('purge-charity-collections', '55 3 * * *',
                     $$select public.purge_old_charity_collections(12)$$);

-- ---------------------------------------------------------------------------
--  PROVING IT, ROLLED BACK
--
--  The only thing worth testing here is that it deletes the right rows and
--  no others, so the probe plants four rows and checks which survive:
--
--      old + declined      -> must GO
--      old + new           -> must STAY (live application)
--      recent + declined   -> must STAY (inside the window)
--      old + offered       -> must STAY (they got a place)
--
--  Run 15 September 2026: deleted 1, and the right one.
--
--  And the guard, as a signed-in user with no roles: refused, 42501.
--  As cron, meaning no JWT at all: allowed.
-- ---------------------------------------------------------------------------
