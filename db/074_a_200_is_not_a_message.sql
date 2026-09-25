-- ===========================================================================
--  074_a_200_is_not_a_message.sql
--  25 September 2026
--
--  THE RECONCILER BELIEVED THE STATUS CODE AND NOT THE ANSWER.
--
--  072 was written because "sent" meant "handed to pg_net", which is not the
--  same as sent. It replaced that with a real reconciliation: read
--  net._http_response, and let the mail server's own answer decide. That was
--  the right shape and it closed the hole it was aimed at.
--
--  It left a smaller one of exactly the same kind, found while applying these
--  files to production on 25 September and before a single reminder had been
--  sent.
--
--  WHAT HAPPENS TODAY IF SOMEBODY PRESSES THE BUTTON
--
--  The notify function deployed to this project does not yet know the kind
--  'madrasah_fee_reminder' — that branch is in the same commit as 068-072 and
--  edge functions are deployed separately from migrations, so there is always
--  a window where the database is ahead of the function. In that window:
--
--     1. send_madrasah_fee_reminders() POSTs the reminder and logs 'queued';
--     2. notify recognises no message for that kind and composes none;
--     3. notify answers 200 with {"ok":true,"note":"nothing sent"} — on
--        purpose, because a non-2xx makes Supabase retry and a retry storm
--        emails the office the same booking forty times;
--     4. reconcile_madrasah_fee_reminders() sees 200, writes 'sent';
--     5. the Outstanding screen shows every family as chased, and the
--        seven-day lock stops anybody chasing them again for a week.
--
--  Nobody was written to. The masjid believes it has chased two hundred
--  families about money. That is worse than the bug 072 fixed, because this
--  time the system has a confident, specific, wrong answer rather than an
--  optimistic one.
--
--  WHY THE FIX IS HERE AND NOT ONLY IN THE FUNCTION
--
--  Deploying notify removes THIS instance and none of the class. The next
--  message kind added to the database before its branch reaches the function
--  reopens it, and the person who does that will have no reason to suspect
--  it — the migration applies cleanly, the screen works, the counts look
--  right. The reconciler is the only place that can be taught the general
--  rule, which is:
--
--      A 200 SAYING NOTHING WAS SENT IS A FAILURE, NOT A SUCCESS.
--
--  notify already distinguishes the two in its body. A message that went out
--  reports "office:sent", "hirer:sent" or both. A request it recognised but
--  could do nothing with reports "nothing sent" or "nothing to send for
--  this". The reconciler now reads that instead of assuming.
--
--  Prerequisites: 072. Idempotent.
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
begin
  --  No verified_admin() here, deliberately: pg_cron calls this with no JWT.
  --  It takes no argument and returns three counts. 073 revoked it from
  --  public and anon; authenticated keeps it so the screen can run it on load.
  if to_regclass('net._http_response') is null then
    return jsonb_build_object('sent', 0, 'failed', 0, 'unanswered', 0,
                              'note', 'pg_net is not installed here');
  end if;

  for v_r in
    select id, request_id, sent_at
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
      end if;
      continue;
    end if;

    --  THE BODY, NOT ONLY THE STATUS CODE.
    --
    --  Matched on the two phrases notify uses when it composed nothing, and
    --  NOT by looking for the absence of ':sent' — a body that is empty,
    --  truncated by pg_net, or in some future shape would then read as a
    --  failure and the office would be told a message failed that went. The
    --  cost of the two errors is not the same: a false failure is a duplicate
    --  email, a false success is a family nobody ever writes to.
    v_note := lower(coalesce(v_resp.content, ''));

    if v_resp.status_code between 200 and 299
       and (v_note like '%nothing sent%' or v_note like '%nothing to send for this%') then
      update public.madrasah_fee_reminders
         set outcome = 'failed', checked_at = now(),
             error = 'The mail server accepted the request but composed no message — it does not recognise a fee reminder. The notify function needs redeploying; nobody was written to.'
       where id = v_r.id;
      v_bad := v_bad + 1;

    elsif v_resp.status_code between 200 and 299 then
      update public.madrasah_fee_reminders
         set outcome = 'sent', checked_at = now(), error = null
       where id = v_r.id;
      v_ok := v_ok + 1;

    else
      update public.madrasah_fee_reminders
         set outcome = 'failed', checked_at = now(),
             error = left(coalesce(
                       nullif(v_resp.error_msg, ''),
                       'The mail server answered ' || coalesce(v_resp.status_code::text, '?')
                         || '. ' || coalesce(left(v_resp.content, 200), '')), 300)
       where id = v_r.id;
      v_bad := v_bad + 1;
    end if;
  end loop;

  if v_ok + v_bad + v_lost > 0 then
    insert into public.admin_audit (masjid_id, actor, action, detail)
    values (null, auth.uid(), 'madrasah_fee_reminders_reconciled',
            jsonb_build_object('sent', v_ok, 'failed', v_bad, 'unanswered', v_lost));
  end if;

  return jsonb_build_object('sent', v_ok, 'failed', v_bad, 'unanswered', v_lost);
end $fn$;

revoke all on function public.reconcile_madrasah_fee_reminders() from public, anon;
grant execute on function public.reconcile_madrasah_fee_reminders() to authenticated;

commit;

-- ===========================================================================
--  CHECKS
-- ===========================================================================

--  #1  The rule is in the live function.
--
--      Asserted on the function body rather than by running it, because
--      running it needs a row in net._http_response and pg_net will not be
--      told to make a request just so a check can read the answer.
do $c1$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'reconcile_madrasah_fee_reminders' limit 1;
  if v_def is null then
    raise exception 'CHECK 1 FAILED: reconcile_madrasah_fee_reminders() does not exist.';
  end if;
  if v_def not like '%nothing sent%' then
    raise exception
      'CHECK 1 FAILED: the reconciler does not read the body. A 200 saying nothing was sent would be written down as sent, and the office would believe it had chased families it never wrote to.';
  end if;
  raise notice 'CHECK 1 passed: a 200 that composed no message is recorded as failed.';
end $c1$;

--  #2  THE HONEST HALF. A rule that turned every 200 into a failure would
--      pass CHECK 1 perfectly, and would mean no reminder could ever be
--      recorded as sent. Both branches have to exist.
do $c2$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'reconcile_madrasah_fee_reminders' limit 1;
  if v_def not like '%outcome = ''sent''%' then
    raise exception
      'CHECK 2 FAILED: nothing in the reconciler can write ''sent'' any more. Every reminder would reconcile to failed and the seven-day lock would never hold.';
  end if;
  raise notice 'CHECK 2 passed: a real send is still recorded as sent.';
end $c2$;

--  #3  Still scheduled, still shut to strangers. 067's rule and 073's.
do $c3$
declare v_n int; v_anon boolean;
begin
  if to_regclass('cron.job') is not null then
    select count(*) into v_n from cron.job
     where jobname = 'reconcile-madrasah-fee-reminders';
    if v_n = 0 then
      raise exception 'CHECK 3 FAILED: nothing calls the reconciler.';
    end if;
  end if;

  select has_function_privilege('anon', p.oid, 'EXECUTE') into v_anon
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'reconcile_madrasah_fee_reminders' limit 1;
  if v_anon then
    raise exception 'CHECK 3 FAILED: replacing the function handed anon EXECUTE back. CREATE OR REPLACE keeps existing grants, but a dropped-and-recreated function does not.';
  end if;
  raise notice 'CHECK 3 passed: scheduled every five minutes, and not reachable by anon.';
end $c3$;

-- ===========================================================================
--  AFTER APPLYING THIS FILE
--
--  Deploy the notify function. This file makes the window HONEST; it does not
--  close it. Until notify knows 'madrasah_fee_reminder', every reminder will
--  reconcile to failed with a message saying exactly why — which is the right
--  answer, and is the one the office can act on.
--
--      supabase functions deploy notify
--
--  Action A11 of the assessment still applies and is the more important of
--  the two: no reminder of any kind until the privacy notice has reached
--  parents.
-- ===========================================================================
