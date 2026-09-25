-- ===========================================================================
--  060 — the retention job takes the BMCC certificate with it
--
--  THE BUG. purge_old_charity_collections deletes the charity_collections
--  row twelve months after a request is completed, declined or withdrawn.
--  The row carries bmcc_certificate_path, and that column is the ONLY record
--  of where the uploaded certificate lives. Deleting the row therefore did
--  not delete the certificate — it made it unreachable. The file stayed in
--  the bmcc bucket for ever, holding an organisation's details and somebody's
--  signature, with nothing left in the database able to name it.
--
--  The privacy notice and the new delete-data page both tell people the
--  certificate goes with the request. Until this migration, that was not true.
--
--  WHY THIS IS NOT ONE LINE. Supabase's own documentation is explicit:
--
--      "Deleting objects should always be done via the Storage API and NOT
--       via a SQL query. Deleting objects via a SQL query will not remove the
--       object from the bucket and will result in the object being orphaned."
--
--  So `delete from storage.objects` would have looked like a fix, passed
--  every test that checks the metadata row is gone, and left the file exactly
--  where it was. The deletion has to be an HTTP call to the Storage API, and
--  net.http_delete is asynchronous: it queues a request and returns an id,
--  with the outcome landing in net._http_response later.
--
--  THE SHAPE, therefore, is a queue.
--
--    1. The nightly purge writes each expiring certificate's path into
--       bmcc_certificate_purge_queue and THEN deletes the row. The path is
--       preserved before the only other copy of it is destroyed, so a failure
--       anywhere after this point delays the deletion rather than losing the
--       file.
--    2. sweep_bmcc_certificates() sends the pending ones and records the
--       request id, then reads back the responses from earlier sends and
--       clears the ones that succeeded. It runs hourly, because pg_net keeps
--       a response for about six hours and a nightly reaper would find every
--       one of them already swept up.
--    3. Anything that fails stays queued and is tried again next hour.
--
--  A missing credential does not fail silently and does not lose data: the
--  sweep records notify-style evidence in admin_audit and leaves the queue
--  where it is.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  The queue.
--
--  Keyed by path because the same file must never be queued twice, and
--  because after step 1 the path is all we have — the row it belonged to is
--  gone by design.
-- ---------------------------------------------------------------------------
create table if not exists public.bmcc_certificate_purge_queue (
  path        text primary key,
  masjid_id   uuid        not null references public.masjids(id) on delete cascade,
  queued_at   timestamptz not null default now(),
  request_id  bigint,
  sent_at     timestamptz,
  attempts    integer     not null default 0,
  last_error  text
);

comment on table public.bmcc_certificate_purge_queue is
  'Certificates whose request has been deleted and whose file still has to be '
  'removed through the Storage API. A row here means a file is still in the '
  'bucket that should not be. An empty table is the healthy state.';

alter table public.bmcc_certificate_purge_queue enable row level security;
-- No policies, deliberately. Like app_settings, this is reachable only by the
-- SECURITY DEFINER functions below. Nothing in a browser has any business
-- reading a list of file paths that are pending deletion.

create index if not exists bmcc_purge_queue_pending
  on public.bmcc_certificate_purge_queue (queued_at)
  where request_id is null;

-- ---------------------------------------------------------------------------
--  purge_old_charity_collections — unchanged in what it deletes and when,
--  except that a certificate's path is now saved before its row is destroyed.
-- ---------------------------------------------------------------------------
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

  with expiring as materialized (
    select id, masjid_id, bmcc_certificate_path
      from public.charity_collections
     where status in ('declined','withdrawn','completed')
       and submitted_at < now() - make_interval(months => retain_months)
  ),
  -- FIRST. The path is written down while the row that holds it still
  -- exists. Reversing these two statements is the whole bug again.
  queued as (
    insert into public.bmcc_certificate_purge_queue (path, masjid_id)
    select bmcc_certificate_path, masjid_id
      from expiring
     where bmcc_certificate_path is not null
    on conflict (path) do nothing
    returning 1
  ),
  gone as (
    delete from public.charity_collections c
     using expiring e
     where c.id = e.id
    returning 1
  )
  select (select count(*) from gone) into v_deleted;

  insert into public.admin_audit (masjid_id, action, detail)
  select m.id, 'charity_collections_purged',
         jsonb_build_object('deleted', v_deleted, 'retain_months', retain_months)
    from public.masjids m
   order by m.created_at
   limit 1;

  return v_deleted;
end;
$fn$;

-- ---------------------------------------------------------------------------
--  queue_orphaned_bmcc_certificates — the files already stranded.
--
--  Everything in the bucket that no live request names. Two of these exist by
--  construction: certificates whose rows were purged before this migration,
--  and uploads whose request never completed, because the app uploads the
--  file and only then calls request_charity_collection.
--
--  THE GRACE PERIOD IS NOT OPTIONAL. Between those two steps a file is,
--  briefly, exactly what an orphan looks like. Sweeping without a window
--  would delete certificates out from under people in the act of submitting.
--  A day is far longer than that gap and far shorter than the retention.
-- ---------------------------------------------------------------------------
create or replace function public.queue_orphaned_bmcc_certificates(grace_hours integer default 24)
returns integer
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare v_queued int;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may sweep certificates'
      using errcode = '42501';
  end if;

  with orphans as (
    select o.name as path
      from storage.objects o
     where o.bucket_id = 'bmcc'
       and o.created_at < now() - make_interval(hours => greatest(grace_hours, 1))
       and not exists (select 1 from public.charity_collections c
                        where c.bmcc_certificate_path = o.name)
  ),
  queued as (
    insert into public.bmcc_certificate_purge_queue (path, masjid_id)
    select o.path, (select id from public.masjids order by created_at limit 1)
      from orphans o
    on conflict (path) do nothing
    returning 1
  )
  select count(*) into v_queued from queued;

  if v_queued > 0 then
    insert into public.admin_audit (masjid_id, action, detail)
    select m.id, 'bmcc_orphans_queued', jsonb_build_object('queued', v_queued)
      from public.masjids m order by m.created_at limit 1;
  end if;

  return v_queued;
end;
$fn$;

-- ---------------------------------------------------------------------------
--  sweep_bmcc_certificates — send, then read back what came of earlier sends.
--
--  Reaping first and sending second is deliberate: a request sent in this run
--  cannot possibly have a response yet, and reaping it would only waste a
--  lookup.
-- ---------------------------------------------------------------------------
create or replace function public.sweep_bmcc_certificates()
returns integer
language plpgsql security definer set search_path = public, pg_temp, extensions
as $fn$
declare
  v_url    text;
  v_key    text;
  v_done   int := 0;
  v_masjid uuid;
  r        record;
  v_id     bigint;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may sweep certificates'
      using errcode = '42501';
  end if;

  select id into v_masjid from public.masjids order by created_at limit 1;

  select value into v_url from public.app_settings
   where masjid_id = v_masjid and key = 'storage_url';
  select value into v_key from public.app_settings
   where masjid_id = v_masjid and key = 'storage_key';

  --  Nothing is deleted from the queue when we cannot reach storage. The
  --  files stay, the queue stays, and the audit log says why — which is the
  --  failure everybody wants, rather than an empty queue and a full bucket.
  if v_url is null or v_key is null then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'bmcc_sweep_not_configured',
            jsonb_build_object('missing', case when v_url is null then 'storage_url'
                                               else 'storage_key' end,
                               'waiting',
                               (select count(*) from public.bmcc_certificate_purge_queue)));
    return 0;
  end if;

  -- REAP. 200 and 204 are success. So is 404: the file is not there, which is
  -- the state we were trying to reach, and leaving the row would retry for ever.
  for r in
    select q.path, q.request_id, resp.status_code, resp.error_msg
      from public.bmcc_certificate_purge_queue q
      join net._http_response resp on resp.id = q.request_id
     where q.request_id is not null
  loop
    if r.status_code in (200, 204, 404) then
      delete from public.bmcc_certificate_purge_queue where path = r.path;
      v_done := v_done + 1;
    else
      update public.bmcc_certificate_purge_queue
         set request_id = null,
             last_error = coalesce(r.error_msg, 'HTTP ' || coalesce(r.status_code::text, '?'))
       where path = r.path;
    end if;
  end loop;

  -- SEND. Anything never sent, or sent and found to have failed above.
  -- attempts is capped so a permanently undeletable path cannot spin nightly
  -- for ever unnoticed; it stays in the queue, which is the visible symptom.
  for r in
    select path from public.bmcc_certificate_purge_queue
     where request_id is null and attempts < 10
     order by queued_at
     limit 100
  loop
    select net.http_delete(
             url     := rtrim(v_url, '/') || '/object/bmcc/' || r.path,
             headers := jsonb_build_object(
                          'Authorization', 'Bearer ' || v_key))
      into v_id;

    update public.bmcc_certificate_purge_queue
       set request_id = v_id, sent_at = now(), attempts = attempts + 1
     where path = r.path;
  end loop;

  if v_done > 0 then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'bmcc_certificates_deleted',
            jsonb_build_object('deleted', v_done,
                               'still_queued',
                               (select count(*) from public.bmcc_certificate_purge_queue)));
  end if;

  return v_done;
end;
$fn$;

revoke all on function public.sweep_bmcc_certificates() from public, anon, authenticated;
revoke all on function public.queue_orphaned_bmcc_certificates(integer) from public, anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
--  Schedules. 03:55 is unchanged; the orphan sweep runs just after it so a
--  row deleted by hand during the day is also caught, and the sender runs
--  hourly to stay inside pg_net's response retention.
-- ---------------------------------------------------------------------------
select cron.unschedule('purge-charity-collections')
 where exists (select 1 from cron.job where jobname = 'purge-charity-collections');
select cron.schedule('purge-charity-collections', '55 3 * * *',
                     $$select public.purge_old_charity_collections(12)$$);

select cron.unschedule('queue-orphaned-bmcc')
 where exists (select 1 from cron.job where jobname = 'queue-orphaned-bmcc');
select cron.schedule('queue-orphaned-bmcc', '5 4 * * *',
                     $$select public.queue_orphaned_bmcc_certificates(24)$$);

select cron.unschedule('sweep-bmcc-certificates')
 where exists (select 1 from cron.job where jobname = 'sweep-bmcc-certificates');
select cron.schedule('sweep-bmcc-certificates', '20 * * * *',
                     $$select public.sweep_bmcc_certificates()$$);

-- ---------------------------------------------------------------------------
--  BEFORE THIS DOES ANYTHING, two settings have to exist. storage_url is not
--  secret and is set by this migration. storage_key is the service_role key
--  and is NOT in this file, is not in the repository, and must never be: set
--  it by hand in the SQL editor, once.
--
--    insert into public.app_settings (masjid_id, key, value)
--    select id, 'storage_key', 'PASTE_THE_SERVICE_ROLE_KEY_HERE'
--      from public.masjids order by created_at limit 1
--    on conflict (masjid_id, key) do update set value = excluded.value;
--
--  app_settings has row level security on and no policies at all, so nothing
--  holding an anon key can read it. Until the key is set, sweep_bmcc_
--  certificates writes bmcc_sweep_not_configured to admin_audit every hour
--  and deletes nothing.
-- ---------------------------------------------------------------------------
insert into public.app_settings (masjid_id, key, value)
select id, 'storage_url', 'https://phenbhmobxwyvdeshvqw.supabase.co/storage/v1'
  from public.masjids order by created_at limit 1
on conflict (masjid_id, key) do nothing;
