-- ===========================================================================
--  051_a_push_has_a_sender.sql
--  15 September 2026
--
--  WHAT IS WRONG TODAY
--  -------------------
--  The app's notification sender has no idea who anybody is. The Cloudflare
--  Worker authenticates with ONE shared password and hands back a bearer token
--  whose entire payload is {"exp": ...} — no subject, no name, nothing. Read
--  its own comment: "The password plus an 8-hour session is the real control."
--
--  Two consequences the masjid is living with:
--
--    *  NOTHING RECORDS WHO SENT A NOTIFICATION. /api/send writes no log, no
--       KV entry and no row. A push to every phone in the congregation cannot
--       be recalled, and it is the only action in this entire system with no
--       record of who took it. Every hall booking, every Gift Aid claim, every
--       role change leaves an admin_audit row naming a person. The one thing
--       that reaches people in their pockets at 6am leaves nothing.
--
--    *  THE HISTORY IS IN ONE BROWSER. admin.html keeps "Recently sent" in
--       localStorage. If one trustee sends a janāzah notice at 11pm and
--       another opens the screen five minutes later, the second sees "Nothing
--       sent yet" — and sends it again. That is not hypothetical; it is the
--       obvious failure of a per-browser list shared between volunteers.
--
--  WHAT THIS DOES
--  --------------
--  A table, and TWO functions rather than one, because the two halves of a
--  send have genuinely different trust:
--
--    app_notification_start(p)   authenticated + verified_admin().
--                                Writes the row BEFORE anything is sent, with
--                                actor = auth.uid(). Returns the row id.
--
--    app_notification_finish(..) service_role only. Fills in what happened.
--
--  THE ACTOR COMES FROM THE JWT, NOT FROM AN ARGUMENT. This is the whole
--  reason for the split. The Edge Function that does the sending holds the
--  service key, and if it passed `actor` as a parameter then the record would
--  only be as trustworthy as the Edge Function — a bug there would write the
--  wrong name into the masjid's record of who announced a death. Starting the
--  row under the caller's own JWT means auth.uid() decides, and nothing
--  downstream can change it.
--
--  WRITTEN BEFORE THE SEND, NOT AFTER. A record written afterwards is missing
--  exactly the sends that went wrong — the Worker timing out, the browser
--  closing mid-request, OneSignal refusing. Those are the ones somebody will
--  be trying to reconstruct. So the row exists in 'sending' from the moment
--  somebody commits to it, and a row still saying 'sending' an hour later is
--  itself the useful signal.
--
--  Prerequisites: 040, 041, verified_admin() from 011. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. The table
--
--  `create table if not exists` is a SILENT NO-OP on a table that already
--  exists with different columns — this project has been bitten by that — so
--  every column below is also asserted with `add column if not exists`, and
--  the DO block at the foot reads the shape back out of information_schema
--  rather than trusting that this ran.
-- ---------------------------------------------------------------------------
create table if not exists public.app_notifications (
  id          uuid primary key default gen_random_uuid(),
  at          timestamptz not null default now(),

  --  WHO. Not null: a row that cannot name a sender is the thing this table
  --  exists to abolish. on delete set null is NOT used — see the fk below.
  actor       uuid not null references auth.users(id) on delete restrict,

  --  WHAT WENT OUT. Kept here in full rather than joined to notices, because
  --  a notice can be edited or deleted afterwards and this is a record of what
  --  people's phones actually showed at the time.
  topic       text not null,
  title       text not null,
  body        text,
  image_url   text,

  --  The notice row this push accompanied, when there was one. Nullable: a
  --  reminder does not have to leave a notice behind.
  notice_id   uuid references public.notices(id) on delete set null,

  --  WHAT HAPPENED. 'sending' until the Edge Function says otherwise.
  status      text not null default 'sending',
  onesignal_id text,
  recipients  integer,
  error       text
);

alter table public.app_notifications add column if not exists onesignal_id text;
alter table public.app_notifications add column if not exists recipients   integer;
alter table public.app_notifications add column if not exists error        text;
alter table public.app_notifications add column if not exists notice_id    uuid;

--  on delete RESTRICT on the actor, deliberately. Deleting a staff account
--  must not quietly erase who sent what — /access/ suspends accounts rather
--  than deleting them for the same reason. If a delete is ever genuinely
--  needed, somebody has to deal with this table on purpose.

alter table public.app_notifications drop constraint if exists app_notification_status_known;
alter table public.app_notifications add constraint app_notification_status_known
  check (status in ('sending', 'sent', 'failed'));

--  The five the Worker will accept. NOT the notices vocabulary, and the
--  difference is real: `jamaah` is a push audience with no notice behind it,
--  and `ramadan`/`madrasah` are notice topics the app has no switch for yet.
--  Two overlapping lists, written down as two, because pretending they are one
--  is how a notice gets filed under a topic nobody subscribed to.
alter table public.app_notifications drop constraint if exists app_notification_topic_known;
alter table public.app_notifications add constraint app_notification_topic_known
  check (topic in ('janazah', 'jamaah', 'announcements', 'events', 'kahf'));

alter table public.app_notifications drop constraint if exists app_notification_has_a_heading;
alter table public.app_notifications add constraint app_notification_has_a_heading
  check (length(btrim(title)) between 1 and 70);

create index if not exists app_notifications_recent on public.app_notifications (at desc);

-- ---------------------------------------------------------------------------
--  2. Nobody reaches this table directly
--
--  GRANT AND RLS ARE DIFFERENT THINGS AND YOU NEED BOTH. RLS with a grant
--  still in place is a policy guarding a door somebody already has a key to;
--  a revoke without RLS is one `grant` away from open.
-- ---------------------------------------------------------------------------
alter table public.app_notifications enable row level security;
alter table public.app_notifications force row level security;
revoke all on public.app_notifications from anon, authenticated;

--  No policies at all. Every read and write below is a security definer
--  function, so there is nothing for a policy to permit. An empty policy list
--  under FORCE RLS denies everything, including to the owner — which is what
--  is wanted here.

-- ---------------------------------------------------------------------------
--  3. Starting a send — the caller's own identity, before anything goes out
-- ---------------------------------------------------------------------------
create or replace function public.app_notification_start(p jsonb)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id    uuid;
  v_topic text := lower(btrim(coalesce(p->>'topic', '')));
  v_title text := btrim(coalesce(p->>'title', ''));
  v_body  text := btrim(coalesce(p->>'body',  ''));
  v_recent integer;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may send a notification to the app.'
      using errcode = '42501';
  end if;

  if v_topic not in ('janazah', 'jamaah', 'announcements', 'events', 'kahf') then
    raise exception 'That is not one of the app''s notification topics.'
      using errcode = 'check_violation';
  end if;
  if v_title = '' or length(v_title) > 70 then
    raise exception 'The heading has to be between 1 and 70 characters — it is read on a locked phone.'
      using errcode = 'check_violation';
  end if;

  --  A BRAKE, NOT A LOCK. Four pushes in ten minutes is somebody pressing a
  --  button that appears not to have worked, and the congregation is the one
  --  that pays for it. The Worker's own rate limit is per-IP and in-memory
  --  across short-lived isolates — its comment says so — which means it does
  --  not survive the masjid office and a trustee's phone being different
  --  addresses. This one is in the database, where there is one of it.
  select count(*) into v_recent
    from public.app_notifications
   where at > now() - interval '10 minutes'
     and status <> 'failed';
  if v_recent >= 4 then
    raise exception 'Four notifications have already gone out in the last ten minutes. Wait a moment — if the last one looked like it failed, check the list before sending again.'
      using errcode = 'too_many_rows';
  end if;

  insert into public.app_notifications (actor, topic, title, body, image_url, notice_id)
  values (auth.uid(), v_topic, v_title, nullif(v_body, ''),
          nullif(btrim(coalesce(p->>'image_url', '')), ''),
          nullif(p->>'notice_id', '')::uuid)
  returning id into v_id;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'app_notification_started',
          jsonb_build_object('id', v_id, 'topic', v_topic, 'title', v_title));

  return v_id;
end $fn$;

-- ---------------------------------------------------------------------------
--  4. Finishing it — the only part the Edge Function's key may do
--
--  It cannot change who sent it, what was said, or when. Only how it went.
-- ---------------------------------------------------------------------------
create or replace function public.app_notification_finish(
  p_id uuid, p jsonb)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_ok boolean := coalesce((p->>'ok')::boolean, false);
begin
  update public.app_notifications
     set status       = case when v_ok then 'sent' else 'failed' end,
         onesignal_id = nullif(btrim(coalesce(p->>'onesignal_id', '')), ''),
         recipients   = nullif(p->>'recipients', '')::integer,
         error        = nullif(btrim(coalesce(p->>'error', '')), ''),
         notice_id    = coalesce(nullif(p->>'notice_id', '')::uuid, notice_id)
   where id = p_id
     --  Only out of 'sending'. A second call cannot flip a failure into a
     --  success, and a retry cannot rewrite the first attempt's record.
     and status = 'sending';
end $fn$;

-- ---------------------------------------------------------------------------
--  5. Reading the list — the thing localStorage could never be
-- ---------------------------------------------------------------------------
create or replace function public.app_notifications_list()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may read what has been sent.'
      using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.at desc)
      from (
        select n.id, n.at, n.topic, n.title, n.body, n.image_url,
               n.status, n.recipients, n.error, n.notice_id,
               --  The name, not the uuid. "Sent by 8f3a-…" is a row nobody
               --  can act on. Falls back to the email, then to a sentence,
               --  because a profile row can be missing and "sent by null" is
               --  worse than saying so.
               coalesce(nullif(btrim(pr.full_name), ''),
                        nullif(btrim(pr.email), ''),
                        'an administrator whose name is not on file') as sent_by,
               (n.actor = auth.uid()) as sent_by_you
          from public.app_notifications n
          left join public.profiles pr on pr.id = n.actor
         where n.at > now() - interval '24 months'
         order by n.at desc
         limit 100
      ) x
  ), '[]'::jsonb);
end $fn$;

-- ---------------------------------------------------------------------------
--  6. The grants. As always, the revoke first.
-- ---------------------------------------------------------------------------
revoke all on function public.app_notification_start(jsonb)        from public, anon;
revoke all on function public.app_notification_finish(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.app_notifications_list()             from public, anon;

grant execute on function public.app_notification_start(jsonb)        to authenticated;
grant execute on function public.app_notification_finish(uuid, jsonb) to service_role;
grant execute on function public.app_notifications_list()             to authenticated;

-- ---------------------------------------------------------------------------
--  PROVE IT
--
--  Four things, each of which is a way this could be quietly useless:
--  that the table really has the columns above, that RLS actually denies,
--  that an unauthenticated session is refused rather than writing a row with
--  a null actor, and that the grants are what they say.
-- ---------------------------------------------------------------------------
do $check$
declare
  v_missing text;
  v_rls     boolean;
  v_force   boolean;
  v_pol     integer;
  v_wrote   boolean := false;
begin
  --  1. The shape, read back out of the catalogue. `create table if not
  --     exists` would have silently skipped all of it.
  select string_agg(c, ', ') into v_missing
    from unnest(array['id','at','actor','topic','title','body','image_url',
                      'notice_id','status','onesignal_id','recipients','error']) c
   where c not in (select column_name from information_schema.columns
                    where table_schema='public' and table_name='app_notifications');
  if v_missing is not null then
    raise exception 'app_notifications is missing column(s): %', v_missing;
  end if;

  --  2. RLS on AND forced AND no policies. Any one of the three missing and
  --     the table is reachable by anybody the grants later let in.
  select relrowsecurity, relforcerowsecurity into v_rls, v_force
    from pg_class where oid = 'public.app_notifications'::regclass;
  select count(*) into v_pol from pg_policies
   where schemaname='public' and tablename='app_notifications';
  if not v_rls  then raise exception 'row level security is off on app_notifications'; end if;
  if not v_force then raise exception 'row level security is not FORCED on app_notifications'; end if;
  if v_pol <> 0 then
    raise exception 'app_notifications has % policy(ies). It is meant to have none — every '
                    'read and write goes through a function.', v_pol;
  end if;

  --  3. THE NEGATIVE CONTROL THAT MATTERS. This session has no JWT, so
  --     auth.uid() is null and verified_admin() is false. If start() ever
  --     stopped checking, it would insert a row with a null actor — which the
  --     NOT NULL would catch, but with a constraint error rather than the
  --     refusal. Both are failures; only one of them is this function doing
  --     its job. So the error code is checked, not merely that it threw.
  begin
    perform public.app_notification_start(
      '{"topic":"announcements","title":"negative control"}'::jsonb);
    v_wrote := true;
  exception
    when insufficient_privilege then
      null;                                  -- correct
    when others then
      raise exception 'app_notification_start() failed for a session with no JWT, '
                      'but with SQLSTATE % — it should be refused by '
                      'verified_admin(), not by a constraint', sqlstate;
  end;
  if v_wrote then
    raise exception 'app_notification_start() WROTE A ROW for a session with no '
                    'JWT at all. The whole point of this table is that every '
                    'row names a person.';
  end if;

  --  4. The grants.
  if has_function_privilege('anon', 'public.app_notification_start(jsonb)', 'execute') then
    raise exception 'anon can start a send';
  end if;
  if has_function_privilege('authenticated',
       'public.app_notification_finish(uuid, jsonb)', 'execute') then
    raise exception 'a signed-in account can rewrite how a send went';
  end if;
  if not has_function_privilege('service_role',
       'public.app_notification_finish(uuid, jsonb)', 'execute') then
    raise exception 'the Edge Function cannot record the outcome of a send';
  end if;
  if not has_function_privilege('authenticated',
       'public.app_notifications_list()', 'execute') then
    raise exception 'no administrator can read what has been sent';
  end if;

  raise notice 'app_notifications is in place: RLS forced, no policies, the '
               'actor comes from the JWT, and only service_role may say how a '
               'send went.';
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select public.app_notification_start('{"topic":"events","title":"x"}');
--        -> as anon:          ERROR: permission denied for function
--        -> signed in, no 2FA: ERROR: Only an administrator who has completed…
--        -> signed in with 2FA: a uuid
--
--  RETENTION. 24 months, applied on read rather than by deleting: the rows are
--  small, and a record of who announced a death is not something to throw away
--  on a schedule without the committee deciding to. If that changes, it
--  belongs in the same nightly purge as the rest, not in a one-off job.
-- ===========================================================================
