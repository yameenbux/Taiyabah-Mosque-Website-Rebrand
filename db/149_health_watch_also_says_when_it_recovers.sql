--  =====================================================================
--  149 — HEALTH_WATCH() ALSO SAYS WHEN IT RECOVERS
--  9 October 2026
--  =====================================================================
--
--  Companion to the fix on the notify side (same date): health_watch() has
--  run every 15 minutes and posted a change in health_check()'s result to
--  notify since before notify's own code ever read `kind: "health_alert"`.
--  That half is fixed separately. This is the other half, found while
--  reading health_watch() to fix the first one: the http_post it sends was
--  only ever wrapped in `if v_res->>'status' = 'fail'`. A transition INTO
--  failure posts; a transition OUT of it writes admin_audit and nothing
--  else. The only way to learn something had been fixed was to remember it
--  had broken and go and look.
--
--  v_changed, computed above this block, is already the real gate — it is
--  true exactly when the status or the set of failing checks differs from
--  last time, in either direction. The `if status = 'fail'` inside it was
--  narrowing an already-correct gate for no reason this migration's author
--  could find in the commit that added it. Removed; the http_post now
--  fires on every change v_changed catches, not only the bad ones.
--  =====================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'health_watch';

  if v_def is null then
    raise exception '149: health_watch() is not there to patch.';
  end if;

  if position('on a recovery too' in v_def) > 0 then
    raise notice '149: already alerts on recovery.';
    return;
  end if;

  --  READ-PATCH-REFUSE. Refuses rather than half-patching if the shape moved.
  v_new := replace(v_def,
$a$  if v_res->>'status' = 'fail' then
    select value into v_url    from public.app_settings where key='notify_url'    order by masjid_id limit 1;
    select value into v_key    from public.app_settings where key='notify_key'    order by masjid_id limit 1;
    select value into v_secret from public.app_settings where key='notify_secret' order by masjid_id limit 1;
    if v_url is not null and v_key is not null and v_secret is not null then
      perform net.http_post(
        url     := v_url,
        body    := v_res || jsonb_build_object('kind','health_alert'),
        headers := jsonb_build_object('Content-type','application/json',
                     'Authorization','Bearer ' || v_key, 'x-notify-secret', v_secret));
    end if;
  end if;$a$,
$b$  --  149: on a recovery too, not only a failure. v_changed above is
  --  already the real gate -- true on either direction of transition --
  --  so this used to silently narrow it back down to one direction.
  select value into v_url    from public.app_settings where key='notify_url'    order by masjid_id limit 1;
  select value into v_key    from public.app_settings where key='notify_key'    order by masjid_id limit 1;
  select value into v_secret from public.app_settings where key='notify_secret' order by masjid_id limit 1;
  if v_url is not null and v_key is not null and v_secret is not null then
    perform net.http_post(
      url     := v_url,
      body    := v_res || jsonb_build_object('kind','health_alert'),
      headers := jsonb_build_object('Content-type','application/json',
                   'Authorization','Bearer ' || v_key, 'x-notify-secret', v_secret));
  end if;$b$);

  if v_new = v_def then
    raise exception '149: the status=fail guard did not match. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  =====================================================================
--  PROOF. health_watch() reads live state (cron history, this masjid's own
--  settings), so there is no pure before/after call to show here the way
--  audit_kind()'s proof block can. Confirmed instead by reading the
--  function back and checking the guard is gone and the http_post is
--  unconditional on v_url/v_key/v_secret alone.
--  =====================================================================
