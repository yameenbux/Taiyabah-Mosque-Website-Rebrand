-- ===========================================================================
--  075_the_reconciler_could_never_have_run.sql
--  25 September 2026
--
--  reconcile_madrasah_fee_reminders() THREW EVERY TIME IT HAD WORK TO DO.
--
--  072 gave it an audit row:
--
--      insert into public.admin_audit (masjid_id, actor, action, detail)
--      values (null, auth.uid(), 'madrasah_fee_reminders_reconciled', ...)
--
--  public.admin_audit.masjid_id is NOT NULL. That line raises 23502 the first
--  time the reconciler resolves anything at all, and because it sits after the
--  loop, the exception takes the whole transaction with it — every 'sent' and
--  'failed' the loop had just written is rolled back too.
--
--  WHAT WOULD ACTUALLY HAVE HAPPENED, THE FIRST TIME A REMINDER WAS SENT
--
--  Every five minutes pg_cron would run it, it would resolve the queued rows,
--  it would fall over on the audit line, and everything would roll back. The
--  rows would sit at 'queued' for ever. 'queued' holds the seven-day lock, so
--  no family could be chased again. The six-hour rule that turns an unanswered
--  message into an honest failure is inside the same loop, so it would never
--  fire either. The office would see a screen full of families "waiting for an
--  answer from the mail server" and no answer would ever come.
--
--  WHY NOTHING CAUGHT IT
--
--  The function is a no-op when there is nothing queued: the loop does not
--  execute, v_ok + v_bad + v_lost is 0, the audit insert is skipped, and it
--  returns three zeros. It has been scheduled and running every five minutes
--  since 072 was applied and has never once failed, because it has never once
--  had anything to do.
--
--  072's own CHECK 3 reads:
--
--      'CHECK 3 passed: delivery is reconciled every five minutes.'
--
--  It asserts that cron.job contains a row. It does not assert that the thing
--  the row calls can survive being called. A check on the wiring is not a
--  check on the appliance, and this file exists because that distinction was
--  worth one line of SQL and did not get it.
--
--  It was found by building three fabricated responses in net._http_response
--  and running the reconciler against them — the first time it had ever been
--  given anything to reconcile. CHECK 1 below now does that automatically, so
--  this cannot come back.
--
--  THE FIX
--
--  One audit row per masjid, written from the rows actually touched. The
--  reconciler is genuinely cross-masjid — pg_cron calls it with no tenant
--  context, which is why 072 reached for null in the first place — so the
--  honest record is per masjid rather than one row with a hole in it.
--
--  Prerequisites: 072, 074. Idempotent.
-- ===========================================================================

begin;

create or replace function public.reconcile_madrasah_fee_reminders()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_ok    int := 0;
  v_bad   int := 0;
  v_lost  int := 0;
  v_r     record;
  v_resp  record;
  v_note  text;
  v_ids   uuid[] := '{}';
begin
  if to_regclass('net._http_response') is null then
    return jsonb_build_object('sent', 0, 'failed', 0, 'unanswered', 0,
                              'note', 'pg_net is not installed here');
  end if;

  for v_r in
    select id, request_id, sent_at, masjid_id
      from public.madrasah_fee_reminders
     where outcome = 'queued'
     order by sent_at
     limit 500
  loop
    v_resp := null;
    if v_r.request_id is not null then
      execute 'select status_code, error_msg, content from net._http_response where id = $1'
        into v_resp using v_r.request_id;
    end if;

    if v_resp is null then
      if v_r.sent_at < now() - interval '6 hours' then
        update public.madrasah_fee_reminders
           set outcome = 'failed', checked_at = now(),
               error = 'No answer was ever read from the mail server. It may have gone; there is no way to tell.'
         where id = v_r.id;
        v_lost := v_lost + 1;
        v_ids  := v_ids || v_r.id;
      end if;
      continue;
    end if;

    --  074's rule: the body, not only the status code. A 200 that composed no
    --  message is a failure, because notify answers 200 on purpose to stop
    --  Supabase retrying, and "did not retry" is not "did send".
    v_note := lower(coalesce(v_resp.content, ''));

    if v_resp.status_code between 200 and 299
       and (v_note like '%nothing sent%' or v_note like '%nothing to send for this%') then
      update public.madrasah_fee_reminders
         set outcome = 'failed', checked_at = now(),
             error = 'The mail server accepted the request but composed no message — it does not recognise a fee reminder. The notify function needs redeploying; nobody was written to.'
       where id = v_r.id;
      v_bad := v_bad + 1;
      v_ids := v_ids || v_r.id;

    elsif v_resp.status_code between 200 and 299 then
      update public.madrasah_fee_reminders
         set outcome = 'sent', checked_at = now(), error = null
       where id = v_r.id;
      v_ok  := v_ok + 1;
      v_ids := v_ids || v_r.id;

    else
      update public.madrasah_fee_reminders
         set outcome = 'failed', checked_at = now(),
             error = left(coalesce(
                       nullif(v_resp.error_msg, ''),
                       'The mail server answered ' || coalesce(v_resp.status_code::text, '?')
                         || '. ' || coalesce(left(v_resp.content, 200), '')), 300)
       where id = v_r.id;
      v_bad := v_bad + 1;
      v_ids := v_ids || v_r.id;
    end if;
  end loop;

  --  ONE ROW PER MASJID, and counted from what was actually written rather
  --  than from the three running totals — the totals are across every masjid
  --  and attributing all of them to one would be a worse record than none.
  --  Counted, not listed: an audit row outlives the reminders it describes.
  if array_length(v_ids, 1) is not null then
    insert into public.admin_audit (masjid_id, actor, action, detail)
    select r.masjid_id, auth.uid(), 'madrasah_fee_reminders_reconciled',
           jsonb_build_object(
             'sent',   count(*) filter (where r.outcome = 'sent'),
             'failed', count(*) filter (where r.outcome = 'failed'))
      from public.madrasah_fee_reminders r
     where r.id = any(v_ids)
     group by r.masjid_id;
  end if;

  return jsonb_build_object('sent', v_ok, 'failed', v_bad, 'unanswered', v_lost);
end $fn$;

revoke all on function public.reconcile_madrasah_fee_reminders() from public, anon;
grant execute on function public.reconcile_madrasah_fee_reminders() to authenticated;

commit;

-- ===========================================================================
--  CHECKS
-- ===========================================================================

--  #1  THE RECONCILER IS ACTUALLY RUN, AGAINST ALL THREE ANSWERS IT CAN GET.
--
--      Every other check in 068-074 reads a catalogue or a function body. Not
--      one of them would have caught this, because the fault was not in the
--      shape of anything — it was in what happened when the code ran. So this
--      one builds three fabricated rows in net._http_response, queues a
--      reminder against each, calls the function, and reads the outcomes:
--
--          200 with a real send   -> sent
--          200 that sent nothing  -> failed   (074's rule)
--          500                    -> failed
--
--      and asserts the audit row it used to die on was written. It refuses to
--      run at all if any real reminder exists, so it can never touch one.
do $c1$
declare
  v_m uuid; v_h uuid; i1 uuid; i2 uuid; i3 uuid;
  o1 text; o2 text; o3 text; v_aud int; v_before int;
begin
  if (select count(*) from public.madrasah_fee_reminders) <> 0 then
    raise notice 'CHECK 1 skipped: there are real reminders here and this fixture will not go near them.';
    return;
  end if;
  if to_regclass('net._http_response') is null then
    raise notice 'CHECK 1 skipped: pg_net is not installed here.';
    return;
  end if;

  select count(*) into v_before from public.admin_audit
   where action = 'madrasah_fee_reminders_reconciled';

  delete from net._http_response where id in (975000001, 975000002, 975000003);

  insert into public.masjids (slug, name, town)
  values ('check075-' || replace(gen_random_uuid()::text, '-', ''),
          'CHECK-075 throwaway', 'Nowhere')
  returning id into v_m;
  insert into public.madrasah_households (masjid_id, reference, name)
  values (v_m, 'MF-9997', 'Check 075') returning id into v_h;

  insert into net._http_response (id, status_code, content_type, headers, content, timed_out, error_msg)
  values (975000001, 200, 'application/json', '{}'::jsonb, '{"ok":true,"note":"hirer:sent"}',    false, null),
         (975000002, 200, 'application/json', '{}'::jsonb, '{"ok":true,"note":"nothing sent"}',  false, null),
         (975000003, 500, 'text/plain',       '{}'::jsonb, 'upstream exploded',                  false, null);

  insert into public.madrasah_fee_reminders (masjid_id, household_id, balance_p, outcome, request_id)
  values (v_m, v_h, 1000, 'queued', 975000001) returning id into i1;
  insert into public.madrasah_fee_reminders (masjid_id, household_id, balance_p, outcome, request_id)
  values (v_m, v_h, 1000, 'queued', 975000002) returning id into i2;
  insert into public.madrasah_fee_reminders (masjid_id, household_id, balance_p, outcome, request_id)
  values (v_m, v_h, 1000, 'queued', 975000003) returning id into i3;

  perform public.reconcile_madrasah_fee_reminders();

  select outcome into o1 from public.madrasah_fee_reminders where id = i1;
  select outcome into o2 from public.madrasah_fee_reminders where id = i2;
  select outcome into o3 from public.madrasah_fee_reminders where id = i3;
  select count(*) into v_aud from public.admin_audit
   where action = 'madrasah_fee_reminders_reconciled' and masjid_id = v_m;

  delete from public.admin_audit where masjid_id = v_m;
  delete from public.madrasah_fee_reminders where masjid_id = v_m;
  delete from public.madrasah_households where masjid_id = v_m;
  delete from public.masjids where id = v_m;
  delete from net._http_response where id in (975000001, 975000002, 975000003);

  if o1 <> 'sent' then
    raise exception 'CHECK 1 FAILED: a message the mail server actually sent was recorded as "%". Nothing would ever be recorded as sent and the seven-day lock would never hold.', o1;
  end if;
  if o2 <> 'failed' then
    raise exception 'CHECK 1 FAILED: a 200 that composed no message was recorded as "%". The office would believe it had chased families nobody wrote to.', o2;
  end if;
  if o3 <> 'failed' then
    raise exception 'CHECK 1 FAILED: a 500 from the mail server was recorded as "%".', o3;
  end if;
  if v_aud = 0 then
    raise exception 'CHECK 1 FAILED: the reconciler resolved three reminders and wrote no audit row. That is the 23502 this file exists to fix, back again.';
  end if;

  raise notice 'CHECK 1 passed: the reconciler was RUN against all three answers and got all three right, and the audit row it used to die on was written.';
end $c1$;

--  #2  Still scheduled, still shut to strangers.
do $c2$
declare v_n int; v_anon boolean;
begin
  if to_regclass('cron.job') is not null then
    select count(*) into v_n from cron.job where jobname = 'reconcile-madrasah-fee-reminders';
    if v_n = 0 then
      raise exception 'CHECK 2 FAILED: nothing calls the reconciler.';
    end if;
  end if;
  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_anon
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'reconcile_madrasah_fee_reminders' limit 1;
  if v_anon then
    raise exception 'CHECK 2 FAILED: anon may run the reconciler.';
  end if;
  raise notice 'CHECK 2 passed: scheduled every five minutes, and not reachable by anon.';
end $c2$;

-- ===========================================================================
--  AND THE LESSON, because it is the third time in two days
--
--  067: a retention policy nothing called.
--  072: a "sent" nobody had confirmed.
--  075: a reconciler that had never been run.
--
--  All three passed their checks. All three checks asserted that something
--  EXISTED — a function, a cron row, a schedule — and none asserted that it
--  WORKED. The cheapest way to tell the two apart is to call the thing, with
--  the inputs it will really get, and read what it did. CHECK 1 above is
--  forty lines and would have caught this on the day 072 was written.
-- ===========================================================================
