-- ===========================================================================
--  072_a_reminder_is_sent_or_it_is_not.sql
--  20 September 2026
--
--  "SENT" MEANT "PUT IN AN ENVELOPE AND NOT POSTED".
--
--  071 queued each reminder with net.http_post and wrote 'sent' on the next
--  line. net.http_post is fire-and-forget: it returns an id for a request
--  that has not been made yet, and returns it immediately. Nothing read the
--  answer. one.com reports no bounces either, so the masjid had two layers of
--  not-knowing stacked on each other and a screen that said "Sent" through
--  both of them.
--
--  The consequence is not academic, because 'sent' is also what starts the
--  seven-day lock. A family whose message failed at the mail server was
--  recorded as chased, could not be chased again for a week, and had never
--  been written to. The office would find out when the parent said so.
--
--  071's own footer admitted the shape of this — "the office sees 'sent'
--  against families who were never written to" — and left it. A known defect
--  written down in a comment is still a defect; it is just one somebody chose.
--
--  ---------------------------------------------------------------------------
--  WHAT CHANGES
--  ---------------------------------------------------------------------------
--
--    * A reminder is recorded 'queued', with the id of the outbound request.
--    * reconcile_madrasah_fee_reminders() reads pg_net's response table and
--      moves each one to 'sent' or 'failed', with the reason.
--    * It runs every five minutes on pg_cron, AND the Outstanding screen
--      calls it when it loads — so the office sees the truth on the screen it
--      is already looking at rather than having to wait for a timer.
--    * The seven-day lock counts 'queued' and 'sent'. It does NOT count
--      'failed': a batch that did not leave can be sent again immediately,
--      which is the whole point of knowing.
--
--  ---------------------------------------------------------------------------
--  PG_NET DISCARDS ITS RESPONSES, AND THAT IS THE ONE REAL CONSTRAINT
--  ---------------------------------------------------------------------------
--
--  net._http_response is swept by pg_net's own worker — a few hours at most,
--  and shorter under load. A reminder that is never reconciled inside that
--  window can never be resolved, because the evidence is gone.
--
--  So anything still 'queued' after six hours is marked 'failed' with "no
--  answer was ever read", and the screen says exactly that. It is the honest
--  reading: the masjid does not know it arrived, and for a system that chases
--  people for money, not knowing has to look like failure rather than like
--  success. The cost of being wrong that way is one duplicate email; the cost
--  of the other way is a family chased for something they paid, or not chased
--  at all.
--
--  Prerequisites: 068-071. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. What the log has to carry to answer the question
-- ---------------------------------------------------------------------------
alter table public.madrasah_fee_reminders
  add column if not exists request_id bigint,
  add column if not exists checked_at timestamptz,
  add column if not exists error      text;

--  'queued' joins the list. The constraint is rebuilt rather than added to,
--  because a CHECK cannot be altered in place and a second one with a
--  different name is how a table ends up with two rules that disagree.
alter table public.madrasah_fee_reminders
  drop constraint if exists madrasah_reminder_outcome_valid;
alter table public.madrasah_fee_reminders
  add constraint madrasah_reminder_outcome_valid
  check (outcome in ('queued', 'sent', 'failed',
                     'no_contact', 'too_soon', 'nothing_owed'));

--  Only rows that are waiting for an answer. A partial index, because after
--  the first week almost every row is resolved and the reconciler should not
--  be reading them.
create index if not exists madrasah_reminder_unresolved_idx
  on public.madrasah_fee_reminders (sent_at)
  where outcome = 'queued';

-- ---------------------------------------------------------------------------
--  2. Sending — queue it, and remember which request it was
-- ---------------------------------------------------------------------------
create or replace function public.send_madrasah_fee_reminders(p_households uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid  uuid := public.current_masjid();
  v_url     text;
  v_secret  text;
  v_key     text;
  v_subject text;
  v_body    text;
  v_h       uuid;
  v_ref     text;
  v_name    text;
  v_email   text;
  v_bal     bigint;
  v_last    timestamptz;
  v_req     bigint;
  v_sent    int := 0;
  v_no      int := 0;
  v_soon    int := 0;
  v_clear   int := 0;
  v_out     jsonb := '[]'::jsonb;
  v_reason  text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may send reminders.'
      using errcode = '42501';
  end if;
  if p_households is null or array_length(p_households, 1) is null then
    return jsonb_build_object('sent', 0, 'results', '[]'::jsonb);
  end if;

  --  A CAP, BECAUSE THIS IS THE ONE BUTTON THAT CANNOT BE TAKEN BACK.
  if array_length(p_households, 1) > 120 then
    raise exception 'That is % families in one go. Send at most 120 at a time — an email cannot be unsent.',
      array_length(p_households, 1) using errcode = 'check_violation';
  end if;

  select value into v_url    from public.app_settings where key = 'notify_url';
  select value into v_secret from public.app_settings where key = 'notify_secret';
  select value into v_key    from public.app_settings where key = 'notify_key';
  if v_url is null or v_secret is null then
    raise exception 'Email is not set up yet, so nothing was sent. Nobody has been contacted.'
      using errcode = 'check_violation';
  end if;

  select coalesce(value #>> '{}', '') into v_subject
    from public.madrasah_fee_settings where masjid_id = v_masjid and key = 'reminder_subject';
  select coalesce(value #>> '{}', '') into v_body
    from public.madrasah_fee_settings where masjid_id = v_masjid and key = 'reminder_body';

  foreach v_h in array p_households loop
    v_reason := null;

    select h.reference, h.name into v_ref, v_name
      from public.madrasah_households h
     where h.id = v_h and h.masjid_id = v_masjid;
    if v_ref is null then
      continue;                       -- not this masjid's family; say nothing
    end if;

    select coalesce((select sum(net_p) from public.madrasah_charges where household_id = v_h), 0)
         - coalesce((select sum(amount_p) from public.madrasah_payments where household_id = v_h), 0)
      into v_bal;

    select g.email into v_email
      from public.madrasah_guardians g
     where g.household_id = v_h and g.is_primary and g.email is not null;

    --  'queued' COUNTS TOWARDS THE SEVEN DAYS AND 'failed' DOES NOT.
    --  A message still waiting for an answer was an attempt and must not be
    --  repeated; a message the mail server refused was not, and repeating it
    --  is exactly what the office needs to be able to do.
    select max(sent_at) into v_last
      from public.madrasah_fee_reminders
     where household_id = v_h and outcome in ('sent', 'queued');

    if v_bal <= 0 then
      v_reason := 'nothing_owed'; v_clear := v_clear + 1;
    elsif v_email is null then
      v_reason := 'no_contact';   v_no := v_no + 1;
    elsif v_last is not null and v_last > now() - interval '7 days' then
      v_reason := 'too_soon';     v_soon := v_soon + 1;
    end if;

    if v_reason is not null then
      insert into public.madrasah_fee_reminders
        (masjid_id, household_id, sent_by, balance_p, outcome, checked_at)
      values (v_masjid, v_h, auth.uid(),
              least(greatest(v_bal, -2147483648), 2147483647), v_reason, now());
      v_out := v_out || jsonb_build_object('id', v_h, 'name', v_name, 'outcome', v_reason);
      continue;
    end if;

    --  THE MESSAGE CARRIES NO CHILD'S NAME. See 071's header and its CHECK 1.
    v_req := net.http_post(
      url     := v_url,
      body    := jsonb_build_object(
                   'kind',        'madrasah_fee_reminder',
                   'email',       v_email,
                   'family',      v_name,
                   'reference',   v_ref,
                   'balance_p',   v_bal,
                   'subject',     nullif(v_subject, ''),
                   'body',        nullif(v_body, ''),
                   'card_link',   (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'card_link'),
                   'bank_name',   (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'bank_name'),
                   'bank_account_name',
                                  (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'bank_account_name'),
                   'bank_sort',   (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'bank_sort_code'),
                   'bank_number', (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'bank_account_number')),
      headers := jsonb_build_object(
                   'content-type',    'application/json',
                   'authorization',   'Bearer ' || coalesce(v_key, ''),
                   'x-notify-secret', v_secret));

    insert into public.madrasah_fee_reminders
      (masjid_id, household_id, sent_by, balance_p, outcome, request_id)
    values (v_masjid, v_h, auth.uid(),
            least(greatest(v_bal, -2147483648), 2147483647), 'queued', v_req);

    v_sent := v_sent + 1;
    v_out  := v_out || jsonb_build_object('id', v_h, 'name', v_name, 'outcome', 'queued');
  end loop;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_fee_reminders_sent',
          jsonb_build_object('queued', v_sent, 'no_contact', v_no,
                             'too_soon', v_soon, 'nothing_owed', v_clear));

  --  `sent` is kept as the key name so the screens and the tests that read it
  --  do not have to change meaning in the same commit as the mechanism. It
  --  counts what was handed over; `results` carries the honest per-family word.
  return jsonb_build_object('sent', v_sent, 'no_contact', v_no,
                            'too_soon', v_soon, 'nothing_owed', v_clear,
                            'results', v_out);
end $fn$;

-- ---------------------------------------------------------------------------
--  3. Reading the answer
--
--  Callable by an administrator (the screen runs it on load) and by pg_cron.
--  Idempotent and cheap: the partial index means it touches only rows that
--  are still waiting.
-- ---------------------------------------------------------------------------
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
begin
  --  No verified_admin() here, and that is deliberate: pg_cron calls this with
  --  no JWT at all. It reads and writes nothing a caller can choose — there is
  --  no argument — and it returns three counts. It is still revoked from anon
  --  and from authenticated below, and re-granted only to authenticated for
  --  the screen. A stranger cannot reach it.
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
      --  THE EVIDENCE IS GONE, OR HAS NOT ARRIVED YET.
      --  pg_net sweeps its own response table after a few hours, so a row
      --  that is still waiting after six is one whose answer can never be
      --  read. Calling that 'failed' rather than leaving it queued forever is
      --  the honest reading: the masjid does not know it arrived, and for a
      --  system that chases people for money, not knowing has to look like
      --  failure. The cost of being wrong this way is one duplicate email.
      if v_r.sent_at < now() - interval '6 hours' then
        update public.madrasah_fee_reminders
           set outcome = 'failed', checked_at = now(),
               error = 'No answer was ever read from the mail server. It may have gone; there is no way to tell.'
         where id = v_r.id;
        v_lost := v_lost + 1;
      end if;
      continue;
    end if;

    if v_resp.status_code between 200 and 299 then
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

  --  Counted, not listed. An audit row is read by more people and kept longer
  --  than the reminders it describes.
  if v_ok + v_bad + v_lost > 0 then
    insert into public.admin_audit (masjid_id, actor, action, detail)
    values (null, auth.uid(), 'madrasah_fee_reminders_reconciled',
            jsonb_build_object('sent', v_ok, 'failed', v_bad, 'unanswered', v_lost));
  end if;

  return jsonb_build_object('sent', v_ok, 'failed', v_bad, 'unanswered', v_lost);
end $fn$;

revoke all on function public.reconcile_madrasah_fee_reminders() from public, anon;
grant execute on function public.reconcile_madrasah_fee_reminders() to authenticated;
grant execute on function public.send_madrasah_fee_reminders(uuid[])  to authenticated;

-- ---------------------------------------------------------------------------
--  4. And it runs on its own as well
--
--  067's rule generalised: a function that only runs when somebody happens to
--  open the right screen is a function that does not run. Five minutes,
--  because pg_net's responses do not last.
-- ---------------------------------------------------------------------------
do $sched$
begin
  if to_regclass('cron.job') is not null then
    perform cron.unschedule('reconcile-madrasah-fee-reminders')
      where exists (select 1 from cron.job
                     where jobname = 'reconcile-madrasah-fee-reminders');
    perform cron.schedule('reconcile-madrasah-fee-reminders', '*/5 * * * *',
                          $$select public.reconcile_madrasah_fee_reminders()$$);
  end if;
end $sched$;

commit;

-- ===========================================================================
--  CHECKS
-- ===========================================================================

--  #1  Nothing is recorded as sent at the moment of queuing.
--
--      This is the whole file. The window scanned is from the POST to the
--      counter that follows the log row — the few lines that decide what is
--      written down — and not the whole function.
--
--      The first version scanned everything after the POST and failed on the
--      RETURN, which carries a key literally named 'sent' because the screens
--      read it. A check that fires on the right word in the wrong place is a
--      check somebody widens until it stops firing at all, and then it is
--      decoration. Narrow, and with the accept case asserted first so it
--      cannot pass by matching nothing.
do $c1$
declare v_def text; v_win text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_madrasah_fee_reminders' limit 1;
  if v_def is null then
    raise exception 'CHECK 1 FAILED: send_madrasah_fee_reminders() does not exist.';
  end if;

  v_win := substring(v_def from position('net.http_post' in v_def));
  v_win := substring(v_win for position('v_sent := v_sent + 1' in v_win));
  if length(v_win) < 50 then
    raise exception 'CHECK 1 FAILED: the function no longer has the shape this check reads. It is not checking anything — fix the check before trusting it.';
  end if;

  if v_win not like '%''queued''%' then
    raise exception 'CHECK 1 FAILED: the log row written after posting is not ''queued''.';
  end if;
  if v_win like '%''sent''%' then
    raise exception
      'CHECK 1 FAILED: the sender writes ''sent'' on the row it has just queued. It cannot know that — net.http_post returns before the request is made. reconcile_madrasah_fee_reminders() decides.';
  end if;
  raise notice 'CHECK 1 passed: a reminder is queued, never assumed sent.';
end $c1$;

--  #2  A failed reminder can be re-sent at once; a queued one cannot.
--      The reason for the whole change: if "failed" did not release the lock,
--      knowing about the failure would be useless.
do $c2$
declare v_def text; v_line text; v_found boolean := false;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_madrasah_fee_reminders' limit 1;

  foreach v_line in array string_to_array(v_def, E'\n') loop
    if btrim(v_line) not like '--%'
       and v_line like '%outcome in (''sent'', ''queued'')%' then
      v_found := true; exit;
    end if;
  end loop;

  if not v_found then
    raise exception 'CHECK 2 FAILED: the seven-day lock does not count queued and sent only. Either a failed message cannot be re-sent, or a queued one can be sent twice.';
  end if;
  raise notice 'CHECK 2 passed: failed releases the lock, queued holds it.';
end $c2$;

--  #3  The reconciler is scheduled. 067's rule.
do $c3$
declare v_n int;
begin
  if to_regclass('cron.job') is null then
    raise notice 'CHECK 3 skipped: pg_cron is not installed here. It IS in production — re-run this file there.';
    return;
  end if;
  select count(*) into v_n from cron.job
   where jobname = 'reconcile-madrasah-fee-reminders';
  if v_n = 0 then
    raise exception 'CHECK 3 FAILED: nothing calls reconcile_madrasah_fee_reminders(). Every reminder would sit at "queued" for six hours and then be written off.';
  end if;
  raise notice 'CHECK 3 passed: delivery is reconciled every five minutes.';
end $c3$;

--  #4  A stranger cannot run the reconciler.
--      It is the one function in this section without verified_admin(),
--      because pg_cron has no JWT — so the privilege grant is the only gate
--      and it is worth asserting rather than assuming.
do $c4$
declare v_bad text;
begin
  select string_agg(grantee, ', ') into v_bad
    from information_schema.role_routine_grants
   where routine_schema = 'public'
     and routine_name = 'reconcile_madrasah_fee_reminders'
     and grantee in ('anon', 'PUBLIC');
  if v_bad is not null then
    raise exception 'CHECK 4 FAILED: % may run the reconciler.', v_bad;
  end if;
  raise notice 'CHECK 4 passed: the reconciler is not reachable by anon.';
end $c4$;

-- ===========================================================================
--  AFTER APPLYING THIS FILE
--
--  1. Re-run db/011_require_two_step.sql.
--  2. Deploy the notify function. Until it is deployed every reminder will
--     reconcile to FAILED — which is the correct answer, and is the first
--     time this system has been able to give it.
-- ===========================================================================
