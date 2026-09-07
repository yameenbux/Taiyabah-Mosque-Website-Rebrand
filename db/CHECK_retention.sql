-- ===========================================================================
--  CHECK_retention.sql — read only. Safe to run in Supabase, any time.
--
--  Answers three questions the office and the trustees will actually ask:
--
--    1. What is about to be deleted, and when?
--    2. Are the deletion jobs scheduled, and have they been running?
--    3. Does what the database does still match what the website promises?
--
--  It deletes nothing. Section 2 uses the purges' dry_run mode, which counts
--  and returns without touching a row.
--
--  Run the WHOLE file. No psql meta-commands, so it behaves the same in the
--  Supabase editor as it does locally.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. What the website promises
--
--    Hall hire       6 months after the event date; 3 months if declined
--    Nikāḥ requests  12 months after the request was sent
--    Class sign-ups  12 months after the sign-up was sent
--    Shop accounts   until the person closes the account
--
--    If you change any of these, the privacy notice on the website has to
--    change in the same piece of work. The number is written in three places:
--    the notice, the purge functions, and the cron jobs below.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 2. What would go if the jobs ran right now
--
--    Nothing is deleted by this. Each figure is what the next run would remove.
-- ---------------------------------------------------------------------------
select 'nikah_requests' as table_name,
       (select count(*) from public.nikah_requests)          as rows_now,
       public.purge_old_nikah_requests(12, true)              as would_be_deleted,
       (select min(submitted_at) from public.nikah_requests)  as oldest
union all
select 'course_registrations',
       (select count(*) from public.course_registrations),
       public.purge_old_course_registrations(12, true),
       (select min(submitted_at) from public.course_registrations);

-- Hall bookings have no dry run — the function predates the idea — so the
-- same sum is written out here rather than guessed at.
select 'hall_bookings' as table_name,
       count(*) as rows_now,
       count(*) filter (
         where booking_date < (now() at time zone 'Europe/London')::date - interval '6 months'
            or (status in ('declined','cancelled') and created_at < now() - interval '3 months')
       ) as would_be_deleted,
       min(created_at) as oldest
  from public.hall_bookings;

-- ---------------------------------------------------------------------------
-- 3. Are the jobs actually scheduled?
--
--    Expect three rows, all active. A missing row means that table's records
--    are being kept for ever, whatever the privacy notice says.
-- ---------------------------------------------------------------------------
select jobname, schedule, active
  from cron.job
 where jobname in ('purge-hall-bookings',
                   'purge-nikah-requests',
                   'purge-course-registrations')
 order by jobname;

-- ---------------------------------------------------------------------------
-- 4. Have they run, and did they work?
--
--    pg_cron records every firing. A job that has been failing every week
--    looks exactly like a job that is working, unless somebody looks here.
-- ---------------------------------------------------------------------------
select j.jobname, d.status, d.start_time, d.return_message
  from cron.job_run_details d
  join cron.job j on j.jobid = d.jobid
 where j.jobname like 'purge-%'
 order by d.start_time desc
 limit 20;

-- ---------------------------------------------------------------------------
-- 5. The masjid's own record that a deletion happened
--
--    Written on every run, including the ones that find nothing — so a gap in
--    this list means the job stopped running, not that there was nothing to do.
-- ---------------------------------------------------------------------------
select action, detail, at
  from public.admin_audit
 where action in ('nikah_requests_purged',
                  'course_registrations_purged',
                  'admission_applications_purged')
 order by at desc
 limit 20;
