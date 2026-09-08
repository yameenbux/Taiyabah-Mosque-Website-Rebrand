-- ===========================================================================
--  020_digest_auth_header.sql — the digest never reached the function
--
--  Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
--  8 September 2026
--
--  WHAT WENT WRONG
--  ---------------
--  `select public.send_weekly_digest(force => true)` returned {"sent": true}
--  and no email arrived. It said "sent" because pg_net is asynchronous —
--  net.http_post queues the request and returns immediately, so the function
--  cannot know what happened. The real answer landed later in
--  net._http_response:
--
--      401  {"code":"UNAUTHORIZED_NO_AUTH_HEADER",
--            "message":"Missing authorization header"}
--
--  That JSON is SUPABASE'S API GATEWAY talking, not our notify function. Our
--  function rejects with the plain string "Unauthorized"; anything with a
--  "code" field never reached it. The gateway sits in front of every Edge
--  Function and requires an Authorization header before it will pass a
--  request through. 019 sent content-type and x-notify-secret and nothing
--  else, so the gateway turned it away at the door and the function was never
--  woken up.
--
--  The stripe webhook and the nikāḥ database webhook worked all along (rows
--  1 and 2 in net._http_response, both 200) because both of those send an
--  Authorization header of their own. Only the SQL path was missing it.
--
--  THE FIX
--  -------
--  Send Authorization: Bearer <anon key> as well. The anon key is the public,
--  publishable one — the same string already sitting in config.js and served
--  to every visitor's browser. It is not a secret and it grants nothing on its
--  own; it is only the gateway's ticket. The real gate on notify stays what it
--  always was: x-notify-secret, which the function checks itself.
--
--  DELIBERATELY NOT the service_role key. That key bypasses RLS entirely and
--  must never be stored where a future compromise of one table would hand it
--  over. app_settings is well protected, but the anon key is sufficient, so
--  the stronger key has no business being there.
--
--  The alternative was to turn off "Verify JWT" on the notify function, which
--  would drop the gateway check for every caller. Adding one header to one
--  caller is narrower, so that is what this does.
--
--  Prerequisite: 019. Idempotent — safe to run twice.
--
--  AFTER APPLYING THIS, RE-RUN 011_require_two_step.sql.
-- ===========================================================================

begin;

create or replace function public.send_weekly_digest(force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  s        jsonb;
  v_url    text;
  v_secret text;
  v_key    text;
  v_total  int;
begin
  s := public.outstanding_summary();

  v_total := (s->>'new_nikah')::int
           + (s->>'refunds_due')::int
           + (s->>'balances_due')::int;

  -- Silence when there is nothing. `force` exists only so this can be tested
  -- and demonstrated on a quiet week; the schedule never passes it.
  if v_total = 0 and not force then
    return jsonb_build_object('sent', false, 'why', 'nothing outstanding',
                              'summary', s);
  end if;

  select value into v_url    from public.app_settings where key = 'notify_url';
  select value into v_secret from public.app_settings where key = 'notify_secret';
  select value into v_key    from public.app_settings where key = 'notify_key';

  -- Missing configuration is not an error worth raising every Monday. Say
  -- exactly which one is missing and stop; this returned row is what somebody
  -- will actually look at. Naming the specific key is the whole point — "not
  -- configured" would have been as useless as {"sent": true} was.
  if v_url is null then
    return jsonb_build_object('sent', false,
                              'why', 'notify_url missing from app_settings',
                              'summary', s);
  end if;

  if v_secret is null then
    return jsonb_build_object('sent', false,
                              'why', 'notify_secret missing from app_settings',
                              'summary', s);
  end if;

  if v_key is null then
    return jsonb_build_object('sent', false,
                              'why', 'notify_key missing from app_settings — '
                                  || 'without it the Supabase gateway returns '
                                  || '401 UNAUTHORIZED_NO_AUTH_HEADER and the '
                                  || 'function is never reached',
                              'summary', s);
  end if;

  perform net.http_post(
    url     := v_url,
    body    := s || jsonb_build_object('kind', 'digest'),
    headers := jsonb_build_object(
                 'content-type',    'application/json',
                 -- The gateway's ticket. Public key, no privileges of its own.
                 'authorization',   'Bearer ' || v_key,
                 -- The actual gate, checked by the function itself.
                 'x-notify-secret', v_secret)
  );

  return jsonb_build_object('sent', true, 'summary', s);
end$$;

comment on function public.send_weekly_digest(boolean) is
  'Posts the outstanding summary to the notify function. Sends NOTHING when nothing is outstanding. Needs notify_url, notify_secret AND notify_key (the anon key, for the Supabase gateway) in app_settings. Owner and pg_cron only.';

commit;

-- The revokes from 019 survive create-or-replace, but state them again so this
-- file is self-contained and cannot leave the function callable by mistake.
revoke all on function public.send_weekly_digest(boolean) from public;
revoke all on function public.send_weekly_digest(boolean) from anon, authenticated;

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
--
--  Then add the third setting — the anon / publishable key, the one that is
--  already in config.js and starts sb_publishable_ (or, on older projects, is
--  the long eyJ… "anon public" key):
--
--    insert into public.app_settings (key, value) values
--      ('notify_key', '<the anon key from Settings → API Keys>')
--    on conflict (key) do update set value = excluded.value;
--
--  Then prove it:
--
--    select public.send_weekly_digest(force => true);
--
--  And, thirty seconds later, check what the gateway actually said — because
--  {"sent": true} only means "queued", and that is what misled us once:
--
--    select id, status_code, left(content, 120) as body, created
--      from net._http_response order by created desc limit 3;
--
--  200 with {"ok":true,...} is the finish line. Not the {"sent": true}.
-- ===========================================================================
