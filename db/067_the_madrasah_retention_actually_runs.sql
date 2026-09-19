-- ===========================================================================
--  067_the_madrasah_retention_actually_runs.sql
--  19 September 2026
--
--  THE RETENTION POLICY FOR 543 CHILDREN'S RECORDS WAS WRITTEN AND NEVER RAN.
--
--  purge_madrasah_pupils() was written in 058 and purge_madrasah_archive() in
--  064. Both carry the three-year interval the masjid agreed. Both were
--  tested. Neither was ever put in cron.job.
--
--      select count(*) from cron.job where jobname like '%madrasah%';  -->  0
--
--  Twelve purges ran nightly - donations, bookings, volunteers, invites,
--  notices, admissions - and not one of them touched a child's record. The
--  two most sensitive tables in this database were the two with no scheduled
--  deletion at all.
--
--  THIS HAS HAPPENED BEFORE, IN THIS REPOSITORY, AND IT IS WRITTEN DOWN.
--  038_retention_actually_runs.sql opens with the sentence "The two most
--  sensitive tables were the two nothing ever purged." The lesson was
--  recorded and then not applied to the tables added afterwards, which is
--  the more interesting failure: writing the purge FEELS like finishing the
--  job, the tests pass because they test the function and not the schedule,
--  and nothing anywhere says the function is never called.
--
--  Found while gathering facts for the masjid's DPIA - because a DPIA has to
--  state how long records are kept and by what mechanism, and the honest
--  answer this morning was "three years, enforced by nothing".
--
--  ---------------------------------------------------------------------------
--  IT IS A NO-OP TODAY, AND THAT WAS CHECKED BEFORE SCHEDULING IT
--  ---------------------------------------------------------------------------
--  Switching on a deletion job against a table nobody has been purging is the
--  kind of change that quietly removes live data on the first Monday. So the
--  counts were taken first:
--
--      pupils with left_on older than 3 years  ->  0
--      archive rows older than 3 years         ->  0
--      pupils with left_on set at all          ->  0
--
--  Nothing is due. The job will do nothing until a child has been off the
--  roll for three years, which is exactly the intent.
--
--  03:20 and 03:25 on a Monday, after the weekly jobs at 03:30 and 03:40 and
--  clear of the nightly run. Weekly and not daily on purpose: this deletes
--  records permanently, and a weekly job that is watched beats a nightly one
--  that is not.
--
--  Prerequisites: 058, 064. Safe to re-run - cron.schedule() replaces a job
--  of the same name rather than adding a second one.
-- ===========================================================================

select cron.schedule('purge-madrasah-pupils', '20 3 * * 1',
                     $$select public.purge_madrasah_pupils()$$);

select cron.schedule('purge-madrasah-archive', '25 3 * * 1',
                     $$select public.purge_madrasah_archive()$$);


-- ===========================================================================
--  CHECKS
-- ===========================================================================
do $check$
declare
  v_n int;
  v_name text;
begin
  --  1. BOTH ARE SCHEDULED. Broken by scheduling only one: fails naming the
  --     count. This is the check whose absence caused the fault - there was
  --     no assertion anywhere that a purge function is ever CALLED.
  select count(*) into v_n from cron.job
   where jobname in ('purge-madrasah-pupils','purge-madrasah-archive');
  if v_n <> 2 then
    raise exception '067: expected both madrasah purges to be scheduled, found %. A purge function that is not in cron.job is a retention policy that does not exist.', v_n;
  end if;

  --  2. AND ACTIVE. A job can be scheduled and switched off, which looks
  --     identical to a scheduled one in every listing that does not ask.
  select count(*) into v_n from cron.job
   where jobname in ('purge-madrasah-pupils','purge-madrasah-archive')
     and active;
  if v_n <> 2 then
    raise exception '067: a madrasah purge is scheduled but not active.';
  end if;

  --  3. EVERY PURGE FUNCTION IN THIS SCHEMA HAS A JOB.
  --
  --     The general form of the fault, rather than the two instances of it.
  --     058 and 064 each wrote a purge and neither was scheduled; this fails
  --     the day somebody writes a third and forgets, instead of it being
  --     found months later by somebody writing a compliance document.
  select p.proname into v_name
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname like 'purge%'
     and p.pronargs = 0
     and not exists (select 1 from cron.job j where j.command like '%' || p.proname || '%')
   limit 1;
  if v_name is not null then
    raise exception '067: public.%() deletes records and is in no scheduled job. A retention policy that nothing calls is not a retention policy - see the header of this file, and 038 before it.', v_name;
  end if;

  raise notice '067 ok: the madrasah retention policy now runs, and every purge in this schema is scheduled.';
end $check$;
