-- ===========================================================================
--  015_retention.sql — make the purges keep the promise the website makes
--
--  The privacy notice says, and has said since the day nikāḥ requests and
--  class sign-ups went live:
--
--      "Nikāḥ date requests and class sign-ups are deleted twelve months
--       after you send them."
--
--  Neither purge did that. Both removed only the rows that had been closed
--  off — declined or withdrawn for nikāḥ, withdrawn or no-show for courses —
--  so a confirmed nikāḥ request or an attended class was kept indefinitely.
--  Under Article 5(1)(e) the published period is the promise, and the code has
--  to meet it. The committee confirmed on 7 September 2026 that it should:
--  everything goes at twelve months.
--
--  Neither was scheduled either. Only hall bookings were (migration 007). A
--  retention promise that depends on somebody remembering is a promise that
--  will eventually be broken, so all three are on a timer here.
--
--  Three things change in each function:
--
--    1. It deletes EVERYTHING past the retention period, not just the rows
--       nobody wanted anyway.
--    2. The is_admin() check comes out. Not carelessly — see section 1.
--    3. A dry_run argument, because these are now irreversible.
--
--  Prerequisites: 009 and 010. Idempotent.
--
--  *** STANDING RULE: re-run 011_require_two_step.sql after this. ***
-- ===========================================================================

begin;

do $$
begin
  if to_regclass('public.nikah_requests') is null then
    raise exception 'public.nikah_requests does not exist. Run 010_nikah_requests.sql first.';
  end if;
  if to_regclass('public.course_registrations') is null then
    raise exception 'public.course_registrations does not exist. Run 009_courses.sql first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. Why the is_admin() check has to go
--
-- Both purges began with:
--
--     if not public.is_admin() then
--       raise exception 'Only an administrator may purge ...';
--     end if;
--
-- is_admin() answers by looking up auth.uid() in user_roles. A pg_cron job has
-- no JWT, so auth.uid() is null, so is_admin() is false, so the scheduled job
-- would have raised an exception every Monday at 03:40 and deleted nothing —
-- silently, because a failed cron job does not ring anybody's phone.
--
-- That is precisely the shape of bug that makes a retention promise a lie: the
-- code exists, it looks right, and it has never once run.
--
-- purge_old_hall_bookings() has no such check and works, and the reason is the
-- right one: EXECUTE is revoked from anon and authenticated, so the only
-- callers are the table owner and pg_cron. Access control by grant, not by a
-- check inside a SECURITY DEFINER function that the scheduler can never pass.
-- Both functions below follow it.
--
-- The practical effect: an administrator can no longer trigger a purge from a
-- browser. Deleting every record older than a year is not an errand somebody
-- should be able to run by clicking; it is a scheduled job, and it can still
-- be run by hand from the Supabase SQL editor, which runs as the owner.
-- ---------------------------------------------------------------------------

-- Dropped rather than replaced. Adding a defaulted argument creates a SECOND
-- function rather than replacing the first, and `purge_old_nikah_requests(12)`
-- would then be ambiguous — or worse, would quietly keep calling the old one.
drop function if exists public.purge_old_nikah_requests(int);
drop function if exists public.purge_old_course_registrations(int);


-- ---------------------------------------------------------------------------
-- 2. Nikāḥ date requests
--
-- Twelve months from when the request was SENT, which is what the notice
-- says — not from the date asked for. Somebody who asks in January for a
-- wedding the following December is deleted the January after they asked.
--
-- This deletes confirmed requests too. That is the decision, and it is the
-- right one for this table: it holds a REQUEST for a date, not a record of a
-- nikāḥ that took place. The masjid's own record of the marriage lives
-- elsewhere and is not touched by anything here.
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_nikah_requests(
  retain_months int,
  dry_run       boolean default false
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cutoff  timestamptz;
  v_deleted int;
begin
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be a positive number of months';
  end if;

  v_cutoff := now() - make_interval(months => retain_months);

  if dry_run then
    select count(*) into v_deleted
      from public.nikah_requests where submitted_at < v_cutoff;
    return v_deleted;
  end if;

  with gone as (
    delete from public.nikah_requests
     where submitted_at < v_cutoff
    returning 1
  ) select count(*) into v_deleted from gone;

  -- Written every time, including when nothing was deleted. "The job ran and
  -- found nothing" and "the job has not run since March" look identical
  -- without it, and only one of them is fine.
  insert into public.admin_audit (action, detail)
  values ('nikah_requests_purged',
          jsonb_build_object('deleted', v_deleted,
                             'retain_months', retain_months,
                             'cutoff', v_cutoff));
  return v_deleted;
end;
$$;

comment on function public.purge_old_nikah_requests(int, boolean) is
  'Deletes every nikāḥ date request older than retain_months, whatever its status — the privacy notice promises twelve months and does not carve out confirmed ones. Pass dry_run => true to count without deleting. Owner and pg_cron only: no is_admin() check, because a cron job has no JWT and would fail one every week in silence.';


-- ---------------------------------------------------------------------------
-- 3. Adult class sign-ups
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_course_registrations(
  retain_months int,
  dry_run       boolean default false
)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_cutoff  timestamptz;
  v_deleted int;
begin
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be a positive number of months';
  end if;

  v_cutoff := now() - make_interval(months => retain_months);

  if dry_run then
    select count(*) into v_deleted
      from public.course_registrations where submitted_at < v_cutoff;
    return v_deleted;
  end if;

  with gone as (
    delete from public.course_registrations
     where submitted_at < v_cutoff
    returning 1
  ) select count(*) into v_deleted from gone;

  insert into public.admin_audit (action, detail)
  values ('course_registrations_purged',
          jsonb_build_object('deleted', v_deleted,
                             'retain_months', retain_months,
                             'cutoff', v_cutoff));
  return v_deleted;
end;
$$;

comment on function public.purge_old_course_registrations(int, boolean) is
  'Deletes every class sign-up older than retain_months, whatever its status. Pass dry_run => true to count without deleting. Owner and pg_cron only.';


-- ---------------------------------------------------------------------------
-- 4. Who may run them
--
-- Nobody with a browser. See section 1.
-- ---------------------------------------------------------------------------
revoke all on function public.purge_old_nikah_requests(int, boolean)
  from public, anon, authenticated;
revoke all on function public.purge_old_course_registrations(int, boolean)
  from public, anon, authenticated;

-- The hall purge, for the same reason and to keep the three consistent.
revoke all on function public.purge_old_hall_bookings()
  from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- 5. NOT changed here: madrasah admissions
--
-- purge_old_admission_applications() has both the same faults — it deletes
-- only declined and withdrawn applications, and it has the is_admin() check
-- that no scheduler can pass. It is deliberately left alone:
--
--   * the form cannot send anything yet (PREVIEW_ONLY), so the table is empty;
--   * the retention period for a child's application is a DPIA question, not
--     a copy of the twelve months agreed for adults' contact details.
--
-- Fix it in the same piece of work that signs off the DPIA and turns the form
-- on. Do not turn that form on before this is done.
-- ---------------------------------------------------------------------------


commit;


-- ===========================================================================
--  6. The schedule
--
--  Outside the transaction above: cron.schedule() commits its own work, and a
--  project without pg_cron enabled should still get the function fixes rather
--  than losing the whole migration.
--
--  If this section fails with 'extension "pg_cron" is not available', enable
--  it in the Supabase dashboard (Database -> Extensions -> pg_cron) and run
--  this file again. The function changes above will already be in place.
--
--  TWELVE is written into each job below. If the trustees ever change the
--  retention period, the privacy notice AND these three lines must change
--  together — there is no single place that holds the number, and pretending
--  otherwise would be worse than saying so here.
-- ===========================================================================

create extension if not exists pg_cron with schema extensions;

-- Unschedule first so this migration can be re-run without stacking up jobs.
do $$
declare j text;
begin
  foreach j in array array['purge-nikah-requests','purge-course-registrations']
  loop
    begin
      perform cron.unschedule(j);
    exception when others then
      null;   -- no such job yet, which is the normal case the first time
    end;
  end loop;
end$$;

-- Staggered through a quiet hour on a Monday, after the hall booking purge at
-- 03:30. Weekly is ample for a twelve-month window.
select cron.schedule('purge-nikah-requests',       '40 3 * * 1',
                     $$ select public.purge_old_nikah_requests(12); $$);
select cron.schedule('purge-course-registrations', '50 3 * * 1',
                     $$ select public.purge_old_course_registrations(12); $$);


-- ---------------------------------------------------------------------------
-- 7. Check it worked
--
-- Expect three rows, all active: hall bookings, nikāḥ requests, class
-- sign-ups. If hall bookings is missing, migration 007 never ran.
-- ---------------------------------------------------------------------------
select jobname, schedule, active, command
  from cron.job
 where jobname in ('purge-hall-bookings',
                   'purge-nikah-requests',
                   'purge-course-registrations')
 order by jobname;
