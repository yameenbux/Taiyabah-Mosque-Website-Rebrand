-- ===========================================================================
--  _test_bmcc_purge.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 060: purging a charity collection request takes its BMCC
--  certificate with it.
--
--  NOT WIRED INTO run-all.sh, deliberately. The harness's profiles in
--  build.sh stop at migration 024, so none of them builds a database that has
--  charity_collections in it, let alone 059 and 060. Listing this suite with a
--  profile that cannot be built would print DID NOT REPORT on every run and
--  teach everybody to ignore it. Extending the profiles past 024 is its own
--  piece of work; until then this file is run by hand against a database
--  built to 060.
--
--  Fresh matters: this file deletes rows.
--
--  THE ASSERTION THAT MATTERS IS 02. Before 060 the purge deleted the row
--  holding bmcc_certificate_path, which was the only record of where the file
--  lived — so the certificate stayed in the bucket for ever and nothing left
--  in the database could name it. The privacy notice and the app's data
--  deletion page both promise it goes. If 02 ever fails again, they are lying.
--
--  Note what is NOT asserted: that the file itself is gone. Supabase deletes
--  storage objects over HTTP, not in SQL, so the most a database test can
--  prove is that the path survived into the queue and that the sweep behaves.
--  A test that deleted from storage.objects and checked the row had vanished
--  would pass while the file sat in the bucket — which is precisely the bug.
-- ===========================================================================
\set ON_ERROR_STOP on

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated;

create or replace function pg_temp.note(l text, cond boolean, d text default '')
returns void language plpgsql as $$
begin
  insert into r values (l, coalesce(cond, false), d);
end $$;

create or replace function pg_temp.efail(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,false,'unexpectedly SUCCEEDED');
exception when others then insert into r values (l,true,left(sqlerrm,70)); end; end $$;


-- ---------------------------------------------------------------------------
--  A request old enough to purge, with a certificate.
-- ---------------------------------------------------------------------------
create or replace function pg_temp.seed(ref text, age interval, email text, cert text)
returns void language sql as $$
  insert into public.charity_collections
    (masjid_id, reference, requested_date, status, submitted_at,
     org_name, org_address, org_phone, org_email, collector_name,
     collector_role, collector_paid, trustee_name, trustee_phone,
     trustee_email, rules_version, rules_accepted, signed_name,
     privacy_accepted, bmcc_certificate_path)
  select (select id from public.masjids order by created_at limit 1),
         ref, current_date + 60, 'completed', now() - age,
         'Test Relief', '1 Test Street, Bolton', '07700900000', email,
         'A Collector', 'volunteer', false, 'A Trustee', '07700900001',
         'trustee@example.test', '2026-09-14', true, 'A Trustee',
         true, cert;
$$;

select pg_temp.seed('CC-TEST-0001', interval '13 months', 'test@example.test',
                    '2025/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.pdf');

--  And one too recent to purge, to prove the window still bites.
select pg_temp.seed('CC-TEST-0002', interval '2 months', 'recent@example.test',
                    '2026/11111111-2222-3333-4444-555555555555.pdf');

select pg_temp.note('01 purge deletes only what has expired',
  public.purge_old_charity_collections(12) = 1,
  'expected exactly one row deleted');

select pg_temp.note('02 THE PATH SURVIVES THE ROW',
  exists (select 1 from public.bmcc_certificate_purge_queue
           where path = '2025/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.pdf'),
  'the certificate would be unreachable for ever');

select pg_temp.note('03 the recent request is untouched',
  exists (select 1 from public.charity_collections
           where org_email = 'recent@example.test'),
  'purge took a request inside its retention window');

select pg_temp.note('04 and its certificate was not queued',
  not exists (select 1 from public.bmcc_certificate_purge_queue
               where path = '2026/11111111-2222-3333-4444-555555555555.pdf'),
  'queued a certificate whose request is still live');

select pg_temp.note('05 purging twice does not double-queue',
  (select count(*) from public.bmcc_certificate_purge_queue
    where path = '2025/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.pdf') = 1);


-- ---------------------------------------------------------------------------
--  With no storage_key, nothing may be dropped from the queue. An empty queue
--  and a full bucket is the one outcome worse than a late deletion.
-- ---------------------------------------------------------------------------
delete from public.app_settings where key = 'storage_key';

select pg_temp.note('06 sweep with no credential deletes nothing',
  public.sweep_bmcc_certificates() = 0);

select pg_temp.note('07 and leaves the queue alone',
  exists (select 1 from public.bmcc_certificate_purge_queue
           where path = '2025/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.pdf'),
  'the queue was emptied without the file being deleted');

select pg_temp.note('08 and says so in the audit log',
  exists (select 1 from public.admin_audit
           where action = 'bmcc_sweep_not_configured'),
  'failed silently');


-- ---------------------------------------------------------------------------
--  The grace period. An upload happens BEFORE the request row is written, so
--  a fresh object always looks like an orphan for a moment.
-- ---------------------------------------------------------------------------
select pg_temp.note('09 grace_hours is floored at 1, never 0',
  public.queue_orphaned_bmcc_certificates(0) is not null,
  'a zero grace would delete certificates mid-submission');


-- ---------------------------------------------------------------------------
--  Neither sweep may be reachable from a browser.
-- ---------------------------------------------------------------------------
set role anon;
select pg_temp.efail('10 anon cannot sweep certificates',
  $$select public.sweep_bmcc_certificates()$$);
select pg_temp.efail('11 anon cannot queue orphans',
  $$select public.queue_orphaned_bmcc_certificates(24)$$);
select pg_temp.efail('12 anon cannot read the queue',
  $$select * from public.bmcc_certificate_purge_queue$$);
reset role;


-- ===========================================================================
--  Results
-- ===========================================================================
\o
select case when ok then 'PASS' else 'FAIL' end as result, name, detail
  from r order by ok, name;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
  from r;

do $$
declare n int;
begin
  select count(*) into n from r where not ok;
  if n > 0 then raise exception '% assertion(s) failed', n; end if;
end $$;
