--  =====================================================================
--  125 - A PARENT CAN WRITE TO THE OFFICE, AND THE OFFICE CAN WRITE BACK
--  29 September 2026
--  =====================================================================
--
--  Slice 4 of the parents' portal (docs/superpowers/specs/2026-09-29-the-
--  parents-portal-and-messages-design.md, section Messages). The piece the
--  masjid asked for by name.
--
--  TWO TABLES, AND THEY ARE REACHED ONLY THROUGH FUNCTIONS.
--    madrasah_threads   one row per conversation. It belongs to a HOUSEHOLD,
--                       not to a guardian: either parent reads the reply, and
--                       the conversation survives a login being removed.
--    madrasah_messages  the words. ON DELETE CASCADE from the thread.
--  RLS is on, there is NO policy, and every grant is revoked, so the API can
--  reach neither table. Every function is SECURITY DEFINER with search_path
--  = public, pg_temp, and anon has EXECUTE on none of them. Each revoke/grant
--  is restated per function on purpose (Supabase's default privileges grant
--  EXECUTE to anon directly; "revoke from public" alone leaves the door open).
--
--  RETENTION IS THE CASCADE, AND IT IS PROVED, NOT ASSERTED. household_id is
--  ON DELETE CASCADE, so a message is deleted with the family - by the
--  purge (purge_madrasah_households(), three years after the last child
--  goes), by delete_madrasah_household(), and by a merge. The proof at the
--  foot of this file does each of those against throwaway rows and counts.
--
--  A MERGE IS THE CASE THE CASCADE GETS WRONG, and it was found by reading
--  every place that deletes a household. settle_sibling_suggestion() joins
--  two families by moving the guardians and pupils onto one and DELETING the
--  other household. With this file's FK unpatched, every conversation the
--  deleted household had would be destroyed with it - a mother's message
--  gone because the office tidied two families into one. The function is
--  patched below (read-patch-refuse) to move the threads first, and the proof
--  runs the merge twice: against the OLD body, to watch the messages vanish
--  (so the test is known to be able to fail), then against the patched one.
--
--  THE RULES THE FUNCTIONS ENFORCE
--    * PARENT (is a parent, and only their own household's threads):
--        parent_thread_start, parent_thread_reply, parent_threads,
--        parent_thread_read, parent_thread_mark_read.
--    * OFFICE (verified_madrasah(), scoped to current_masjid()):
--        office_threads, office_thread_read, office_thread_reply,
--        office_thread_close, and the count-only office_threads_waiting_count.
--    * A REFUSAL IS {"allowed": false} AND NEVER AN EMPTY LIST. An empty list
--      says "that thread does not exist", which is a different and more
--      useful answer to somebody fishing (the shape db/104 closed on
--      register_history()). A foreign thread, a thread that does not exist,
--      a caller who is not a parent and a caller who is not the office all
--      get the SAME answer. A parent's own list is genuinely allowed and
--      genuinely may be empty: that is their household's answer, not a probe.
--    * EVERY OFFICE READ OF A THREAD WRITES AN admin_audit ROW (db/089). The
--      row names the thread and the household - two ids - and never the
--      subject, never a word of the message, never a child.
--    * WAITING MEANS state = 'open': the parent spoke last. Answered and
--      closed are not waiting. Today and the Monday digest both read that
--      one definition, so the two can never disagree about the number.
--    * A parent may not reply to a thread the office has closed - closing
--      is the office's decision and the parent is told to start a new one.
--      The office replying to a closed thread reopens it as 'answered': only
--      the office decides when a conversation ends.
--    * Bounds, so a form cannot be used to fill the database: subject 1-120
--      characters, body 1-4000, at most five threads open per household and
--      at most twenty parent messages per household per day. The refusals
--      are a parent's words (errcode 22023, shown as written).
--    * The body and subject are VALIDATED IN THE FUNCTION before the insert.
--      A CHECK constraint is there as a backstop, but a failed CHECK prints
--      the whole failing row into the server log, and a message body must
--      never reach a log.
--
--  ORDER OF DEPLOYMENT. messages.ts (supabase/functions/notify) learned to
--  draw `messages_waiting` and was DEPLOYED (notify v18) BEFORE this file
--  was applied, the ordering db/108 established: new database with an old
--  renderer would email the office because a parent is waiting and draw it as
--  "this week at the masjid", which is an all-clear.
--
--  send_weekly_digest() IS NOT CALLED ANYWHERE IN THIS FILE. It emails the
--  real office. The digest key is proved by calling outstanding_summary()
--  (which sends nothing) under a signed-in office session AND under the
--  no-session path pg_cron uses.
--
--  NOTHING IN THE PROOF PRINTS A PERSON. Every check is a count, a boolean,
--  a sqlstate, or a fixed sentence written in this file. Every name is
--  invented. No pupil is written except two throwaway children (invented,
--  wrapped so only the sqlstate can escape) for the merge test.
--
--  TO REMOVE: drop table public.madrasah_messages, public.madrasah_threads;
--  drop the functions listed at the foot; restore settle_sibling_suggestion()
--  from db/0xx (the patch is one added UPDATE line).
--  =====================================================================

--  ---------------------------------------------------------------------
--  1. THE TABLES
--  ---------------------------------------------------------------------
create table if not exists public.madrasah_threads (
  id                 uuid primary key default gen_random_uuid(),
  masjid_id          uuid not null references public.masjids(id) on delete cascade,
  --  THE RETENTION PROMISE. A household is removed when its last pupil has
  --  been purged; its conversations go with it, by this cascade and by no
  --  purge rule of their own.
  household_id       uuid not null references public.madrasah_households(id) on delete cascade,
  subject            text not null,
  state              text not null default 'open',
  --  Every thread is opened by a parent today (the office cannot start one:
  --  a teacher or office member messaging a family cold is a safeguarding
  --  question the masjid has not settled). The column is the spec's, kept so
  --  that decision can change without a schema change.
  opened_by_parent   boolean not null default true,
  created_at         timestamptz not null default now(),
  last_message_at    timestamptz not null default now(),
  unread_for_office  boolean not null default true,
  unread_for_parent  boolean not null default false,
  constraint madrasah_thread_state   check (state in ('open', 'answered', 'closed')),
  constraint madrasah_thread_subject check (length(btrim(subject)) between 1 and 120)
);

create table if not exists public.madrasah_messages (
  id           uuid primary key default gen_random_uuid(),
  thread_id    uuid not null references public.madrasah_threads(id) on delete cascade,
  body         text not null,
  from_parent  boolean not null,
  --  Who wrote it, as an id only. No foreign key on purpose: removing a login
  --  must neither block nor alter what was said.
  author_user  uuid,
  --  clock_timestamp(), not now(): two messages written in one transaction (a
  --  proof, an import) would otherwise share a timestamp and read back in any order.
  created_at   timestamptz not null default clock_timestamp(),
  constraint madrasah_message_body check (length(btrim(body)) between 1 and 4000)
);

create index if not exists madrasah_threads_household_idx on public.madrasah_threads (household_id);
create index if not exists madrasah_threads_state_idx     on public.madrasah_threads (masjid_id, state, last_message_at);
create index if not exists madrasah_messages_thread_idx   on public.madrasah_messages (thread_id, created_at);

alter table public.madrasah_threads  enable row level security;
alter table public.madrasah_messages enable row level security;
revoke all on table public.madrasah_threads  from public, anon, authenticated;
revoke all on table public.madrasah_messages from public, anon, authenticated;

comment on table public.madrasah_threads is
  'A conversation between one household and the madrasah office. Belongs to the household, so either parent reads the reply. No policy, no grants: reached only through functions. Deleted with the household (ON DELETE CASCADE) - that is the retention promise.';
comment on table public.madrasah_messages is
  'The words in a thread. Deleted with the thread. Bodies are validated in the function before insert so that a failed CHECK never prints one into the server log.';

--  ---------------------------------------------------------------------
--  2. THE ONE PLACE A PARENT'S HOUSEHOLD IS WORKED OUT
--     Callable by nobody but the owner (and so by the SECURITY DEFINER
--     functions below). NULL for anybody who is not a parent.
--  ---------------------------------------------------------------------
create or replace function public.my_household_id()
returns uuid language sql stable security definer
set search_path = public, pg_temp as $$
  select g.household_id
    from public.madrasah_parent_logins l
    join public.madrasah_guardians g
      on g.id = l.guardian_id and g.masjid_id = l.masjid_id
    join public.madrasah_households h
      on h.id = g.household_id and h.masjid_id = l.masjid_id
   where l.user_id = auth.uid();
$$;
revoke all on function public.my_household_id() from public, anon, authenticated;

--  ---------------------------------------------------------------------
--  3. THE PARENT'S FUNCTIONS
--  ---------------------------------------------------------------------
create or replace function public.parent_threads()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_hh uuid := public.my_household_id();
begin
  if v_hh is null then
    return jsonb_build_object('allowed', false);
  end if;
  return jsonb_build_object(
    'allowed', true,
    'unread', (select count(*) from public.madrasah_threads t
                where t.household_id = v_hh and t.unread_for_parent),
    'threads', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'subject', t.subject, 'state', t.state,
               'created_at', t.created_at, 'last_message_at', t.last_message_at,
               'unread', t.unread_for_parent)
             order by t.last_message_at desc, t.id)
        from public.madrasah_threads t
       where t.household_id = v_hh), '[]'::jsonb));
end $$;

create or replace function public.parent_thread_read(p_thread uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_hh uuid := public.my_household_id(); v_t public.madrasah_threads%rowtype;
begin
  if v_hh is null then
    return jsonb_build_object('allowed', false);
  end if;
  select * into v_t from public.madrasah_threads t
   where t.id = p_thread and t.household_id = v_hh;
  if v_t.id is null then
    --  Another family's thread, a thread that is not there, and NULL: one answer.
    return jsonb_build_object('allowed', false);
  end if;
  return jsonb_build_object(
    'allowed', true,
    'thread', jsonb_build_object(
      'id', v_t.id, 'subject', v_t.subject, 'state', v_t.state,
      'created_at', v_t.created_at, 'last_message_at', v_t.last_message_at,
      'unread', v_t.unread_for_parent),
    --  `who` and nothing that identifies a person: the office's staff are
    --  never named to a family, and a parent sees "you" or "your household".
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
               'from_parent', m.from_parent,
               'who', case when not m.from_parent then 'office'
                           when m.author_user = auth.uid() then 'you'
                           else 'household' end,
               'body', m.body, 'created_at', m.created_at)
             order by m.created_at, m.id)
        from public.madrasah_messages m where m.thread_id = v_t.id), '[]'::jsonb));
end $$;

create or replace function public.parent_thread_start(p_subject text, p_body text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_hh uuid := public.my_household_id();
  v_masjid uuid;
  v_subject text := btrim(coalesce(p_subject, ''));
  v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
begin
  if v_hh is null then
    return jsonb_build_object('allowed', false);
  end if;
  if v_subject = '' then
    raise exception 'Please give your message a short title, so the office can see what it is about.'
      using errcode = '22023';
  end if;
  if length(v_subject) > 120 then
    raise exception 'Please keep the title to 120 characters or fewer.' using errcode = '22023';
  end if;
  if v_body = '' then
    raise exception 'Please write your message.' using errcode = '22023';
  end if;
  if length(v_body) > 4000 then
    raise exception 'That message is too long to send in one go. Please shorten it, or send it as two messages.'
      using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('madrasah_msg:' || v_hh::text, 0));
  if (select count(*) from public.madrasah_messages m
        join public.madrasah_threads t on t.id = m.thread_id
       where t.household_id = v_hh and m.from_parent
         and m.created_at > now() - interval '24 hours') >= 20 then
    raise exception 'You have sent a lot of messages today. Please wait for the office to reply, or ring the office on 01204 535 997.'
      using errcode = '22023';
  end if;
  if (select count(*) from public.madrasah_threads t
       where t.household_id = v_hh and t.state <> 'closed') >= 5 then
    raise exception 'You already have five conversations open with the office. Please add to one of those, or wait for a reply before starting another.'
      using errcode = '22023';
  end if;

  select h.masjid_id into v_masjid from public.madrasah_households h where h.id = v_hh;
  insert into public.madrasah_threads (masjid_id, household_id, subject)
    values (v_masjid, v_hh, v_subject) returning id into v_id;
  insert into public.madrasah_messages (thread_id, body, from_parent, author_user)
    values (v_id, v_body, true, auth.uid());
  return jsonb_build_object('allowed', true, 'id', v_id);
end $$;

create or replace function public.parent_thread_reply(p_thread uuid, p_body text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_hh uuid := public.my_household_id();
  v_t public.madrasah_threads%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
begin
  if v_hh is null then
    return jsonb_build_object('allowed', false);
  end if;
  --  THE SCOPE COMES FIRST, before the body is even looked at, so a foreign
  --  thread is refused identically whatever was sent.
  select * into v_t from public.madrasah_threads t
   where t.id = p_thread and t.household_id = v_hh for update;
  if v_t.id is null then
    return jsonb_build_object('allowed', false);
  end if;
  if v_body = '' then
    raise exception 'Please write your message.' using errcode = '22023';
  end if;
  if length(v_body) > 4000 then
    raise exception 'That message is too long to send in one go. Please shorten it, or send it as two messages.'
      using errcode = '22023';
  end if;
  if v_t.state = 'closed' then
    raise exception 'The office has closed this conversation. If there is more to say, please start a new message.'
      using errcode = '22023';
  end if;
  if (select count(*) from public.madrasah_messages m
        join public.madrasah_threads t on t.id = m.thread_id
       where t.household_id = v_hh and m.from_parent
         and m.created_at > now() - interval '24 hours') >= 20 then
    raise exception 'You have sent a lot of messages today. Please wait for the office to reply, or ring the office on 01204 535 997.'
      using errcode = '22023';
  end if;

  insert into public.madrasah_messages (thread_id, body, from_parent, author_user)
    values (v_t.id, v_body, true, auth.uid());
  update public.madrasah_threads
     set state = 'open', unread_for_office = true, unread_for_parent = false,
         last_message_at = now()
   where id = v_t.id;
  return jsonb_build_object('allowed', true, 'state', 'open');
end $$;

create or replace function public.parent_thread_mark_read(p_thread uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_hh uuid := public.my_household_id(); v_n int;
begin
  if v_hh is null then
    return jsonb_build_object('allowed', false);
  end if;
  update public.madrasah_threads
     set unread_for_parent = false
   where id = p_thread and household_id = v_hh;
  get diagnostics v_n = row_count;
  if v_n = 0 then
    return jsonb_build_object('allowed', false);
  end if;
  return jsonb_build_object('allowed', true);
end $$;

--  ---------------------------------------------------------------------
--  4. THE OFFICE'S FUNCTIONS
--     verified_madrasah() = two-step AND an admin or madrasah role. A
--     teacher, an administrator without two-step, a parent and a stranger
--     all fail it. Scoped to current_masjid() on the THREAD's own masjid, so
--     a thread in another masjid answers exactly as one that is not there.
--  ---------------------------------------------------------------------
create or replace function public.office_threads(p_which text default 'waiting')
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_which text := case when p_which in ('waiting', 'answered', 'closed', 'all')
                       then p_which else 'waiting' end;
  v_today date := (now() at time zone 'Europe/London')::date;
begin
  if not public.verified_madrasah() or v_masjid is null then
    return jsonb_build_object('allowed', false);
  end if;
  return jsonb_build_object(
    'allowed', true,
    'which', v_which,
    'counts', jsonb_build_object(
      'waiting',  (select count(*) from public.madrasah_threads t where t.masjid_id = v_masjid and t.state = 'open'),
      'answered', (select count(*) from public.madrasah_threads t where t.masjid_id = v_masjid and t.state = 'answered'),
      'closed',   (select count(*) from public.madrasah_threads t where t.masjid_id = v_masjid and t.state = 'closed')),
    --  A LIST SAYS WHETHER; THE THREAD SAYS WHAT. No family name here, and no
    --  word of any message: the subject is the parent's own title and the
    --  reference is how the office finds the family. The name appears only
    --  when a thread is opened, and that is audited.
    'threads', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id, 'subject', x.subject, 'state', x.state,
               'created_at', x.created_at, 'last_message_at', x.last_message_at,
               'unread', x.unread_for_office, 'reference', x.reference,
               'messages', x.n,
               'days', greatest(v_today - (x.last_message_at at time zone 'Europe/London')::date, 0))
             --  WAITING: the one that has waited longest first. Anything else:
             --  the most recent first.
             order by (case when v_which = 'waiting' then x.last_message_at end),
                      x.last_message_at desc, x.id)
        from (select t.*, h.reference,
                     (select count(*) from public.madrasah_messages m where m.thread_id = t.id) as n
                from public.madrasah_threads t
                join public.madrasah_households h on h.id = t.household_id and h.masjid_id = t.masjid_id
               where t.masjid_id = v_masjid
                 and (v_which = 'all'
                      or (v_which = 'waiting'  and t.state = 'open')
                      or (v_which = 'answered' and t.state = 'answered')
                      or (v_which = 'closed'   and t.state = 'closed'))
               order by t.last_message_at desc
               limit 500) x), '[]'::jsonb));
end $$;

create or replace function public.office_threads_waiting_count()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid();
begin
  if not public.verified_madrasah() or v_masjid is null then
    return jsonb_build_object('allowed', false);
  end if;
  return jsonb_build_object(
    'allowed', true,
    'count', (select count(*) from public.madrasah_threads t
               where t.masjid_id = v_masjid and t.state = 'open'),
    'oldest_days', coalesce((select greatest((now() at time zone 'Europe/London')::date
                                     - (min(t.last_message_at) at time zone 'Europe/London')::date, 0)
                               from public.madrasah_threads t
                              where t.masjid_id = v_masjid and t.state = 'open'), 0));
end $$;

--  VOLATILE ON PURPOSE: it writes the audit row (and db/114 is the reminder
--  of what happens when an audit insert sits in a STABLE function).
create or replace function public.office_thread_read(p_thread uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_t public.madrasah_threads%rowtype;
  v_ref text; v_family text;
begin
  if not public.verified_madrasah() or v_masjid is null then
    return jsonb_build_object('allowed', false);
  end if;
  select * into v_t from public.madrasah_threads t
   where t.id = p_thread and t.masjid_id = v_masjid;
  if v_t.id is null then
    return jsonb_build_object('allowed', false);
  end if;
  select h.reference, h.name into v_ref, v_family
    from public.madrasah_households h
   where h.id = v_t.household_id and h.masjid_id = v_masjid;

  --  THE AUDIT ROW NAMES THE THREAD AND THE HOUSEHOLD. Not the subject, not a
  --  word of the message, not a child.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'message_thread_opened',
          jsonb_build_object('thread', v_t.id, 'household', v_t.household_id));

  update public.madrasah_threads set unread_for_office = false
   where id = v_t.id and unread_for_office;

  return jsonb_build_object(
    'allowed', true,
    'thread', jsonb_build_object(
      'id', v_t.id, 'subject', v_t.subject, 'state', v_t.state,
      'created_at', v_t.created_at, 'last_message_at', v_t.last_message_at,
      'unread', false, 'reference', v_ref, 'family', v_family),
    'messages', coalesce((
      select jsonb_agg(jsonb_build_object(
               'from_parent', m.from_parent,
               'who', case when m.from_parent
                        then coalesce((select g.full_name
                                         from public.madrasah_parent_logins l
                                         join public.madrasah_guardians g on g.id = l.guardian_id
                                        where l.user_id = m.author_user),
                                      'A parent in this family')
                        else coalesce((select nullif(btrim(p.full_name), '')
                                         from public.profiles p where p.id = m.author_user),
                                      'The office') end,
               'body', m.body, 'created_at', m.created_at)
             order by m.created_at, m.id)
        from public.madrasah_messages m where m.thread_id = v_t.id), '[]'::jsonb));
end $$;

create or replace function public.office_thread_reply(p_thread uuid, p_body text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_t public.madrasah_threads%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
begin
  if not public.verified_madrasah() or v_masjid is null then
    return jsonb_build_object('allowed', false);
  end if;
  select * into v_t from public.madrasah_threads t
   where t.id = p_thread and t.masjid_id = v_masjid for update;
  if v_t.id is null then
    return jsonb_build_object('allowed', false);
  end if;
  if v_body = '' then
    raise exception 'Write the reply first.' using errcode = '22023';
  end if;
  if length(v_body) > 4000 then
    raise exception 'That reply is longer than 4,000 characters. Please shorten it or send it as two.'
      using errcode = '22023';
  end if;

  insert into public.madrasah_messages (thread_id, body, from_parent, author_user)
    values (v_t.id, v_body, false, auth.uid());
  --  An office reply to a CLOSED thread reopens it as answered: only the
  --  office decides when a conversation ends, and a family that is written to
  --  must be able to answer.
  update public.madrasah_threads
     set state = 'answered', unread_for_parent = true, unread_for_office = false,
         last_message_at = now()
   where id = v_t.id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'message_thread_replied',
          jsonb_build_object('thread', v_t.id, 'household', v_t.household_id,
                             'reopened', v_t.state = 'closed'));
  return jsonb_build_object('allowed', true, 'state', 'answered');
end $$;

create or replace function public.office_thread_close(p_thread uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_t public.madrasah_threads%rowtype;
  v_replied boolean;
begin
  if not public.verified_madrasah() or v_masjid is null then
    return jsonb_build_object('allowed', false);
  end if;
  select * into v_t from public.madrasah_threads t
   where t.id = p_thread and t.masjid_id = v_masjid for update;
  if v_t.id is null then
    return jsonb_build_object('allowed', false);
  end if;
  if v_t.state = 'closed' then
    return jsonb_build_object('allowed', true, 'state', 'closed');   -- nothing to do, nothing to audit
  end if;
  v_replied := exists (select 1 from public.madrasah_messages m
                        where m.thread_id = v_t.id and not m.from_parent);
  update public.madrasah_threads
     set state = 'closed', unread_for_office = false
   where id = v_t.id;
  --  `without_reply` is the fact the office would want later: a conversation
  --  that ended with the parent never being answered.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'message_thread_closed',
          jsonb_build_object('thread', v_t.id, 'household', v_t.household_id,
                             'without_reply', not v_replied));
  return jsonb_build_object('allowed', true, 'state', 'closed');
end $$;

--  ---------------------------------------------------------------------
--  5. GRANTS - restated per function
--  ---------------------------------------------------------------------
revoke all on function public.parent_threads()                       from public, anon;
revoke all on function public.parent_thread_read(uuid)               from public, anon;
revoke all on function public.parent_thread_start(text, text)        from public, anon;
revoke all on function public.parent_thread_reply(uuid, text)        from public, anon;
revoke all on function public.parent_thread_mark_read(uuid)          from public, anon;
revoke all on function public.office_threads(text)                   from public, anon;
revoke all on function public.office_threads_waiting_count()         from public, anon;
revoke all on function public.office_thread_read(uuid)               from public, anon;
revoke all on function public.office_thread_reply(uuid, text)        from public, anon;
revoke all on function public.office_thread_close(uuid)              from public, anon;
grant execute on function public.parent_threads()                    to authenticated;
grant execute on function public.parent_thread_read(uuid)            to authenticated;
grant execute on function public.parent_thread_start(text, text)     to authenticated;
grant execute on function public.parent_thread_reply(uuid, text)     to authenticated;
grant execute on function public.parent_thread_mark_read(uuid)       to authenticated;
grant execute on function public.office_threads(text)                to authenticated;
grant execute on function public.office_threads_waiting_count()      to authenticated;
grant execute on function public.office_thread_read(uuid)            to authenticated;
grant execute on function public.office_thread_reply(uuid, text)     to authenticated;
grant execute on function public.office_thread_close(uuid)           to authenticated;

--  ---------------------------------------------------------------------
--  6. A MERGE MUST NOT DESTROY A CONVERSATION
--     settle_sibling_suggestion(): move the threads onto the household that
--     is kept BEFORE the other is deleted. read-patch-refuse.
--  ---------------------------------------------------------------------
do $mig$
declare v_def text; v_new text; v_anchor text; v_n int;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'settle_sibling_suggestion';
  if v_def is null then
    raise exception '125: settle_sibling_suggestion() is not there to patch. NOT changed.';
  end if;
  if position('madrasah_threads' in v_def) > 0 then
    raise notice '125: settle_sibling_suggestion() already moves threads.';
    return;
  end if;
  v_anchor := 'update public.madrasah_guardians set household_id = v_keep where household_id = v_move;';
  v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_n <> 1 then
    raise exception '125: expected the guardians UPDATE once in settle_sibling_suggestion(), found %. NOT changed.', v_n;
  end if;
  v_new := replace(v_def, v_anchor,
    v_anchor || E'\n      --  ADDED BY 125. The household deleted below takes its conversations with it\n'
             || E'      --  (ON DELETE CASCADE) unless they are moved first.\n'
             || E'      update public.madrasah_threads set household_id = v_keep where household_id = v_move;');
  if v_new = v_def then
    raise exception '125: the patch changed nothing. NOT changed.';
  end if;
  execute v_new;
end $mig$;
revoke all on function public.settle_sibling_suggestion(uuid, boolean) from public, anon;
grant execute on function public.settle_sibling_suggestion(uuid, boolean) to authenticated;

--  ---------------------------------------------------------------------
--  7. THE OFFICE IS TOLD: TODAY, AND THE MONDAY DIGEST
--     One definition of waiting (state = 'open'), read in both places.
--     A count and an age, never a name. read-patch-refuse throughout.
--  ---------------------------------------------------------------------
do $mig$
declare v_def text; v_new text; v_anchor text; v_n int;
begin
  --  ---- Today ------------------------------------------------------------
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'madrasah_today';
  if v_def is null then
    raise exception '125: madrasah_today() is not there to patch. NOT changed.';
  end if;
  if position('ADDED BY 125' in v_def) = 0 then
    v_anchor := E'  if v_admin then\n    select count(*) into n from public.admission_applications\n';
    v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    if v_n <> 1 then
      raise exception '125: expected the applications block once in madrasah_today(), found %. NOT changed.', v_n;
    end if;
    v_new := replace(v_def, v_anchor,
$b$  --  ADDED BY 125. Messages from parents waiting for a reply: state = 'open',
  --  the parent spoke last. For everybody who can open this screen (the
  --  messages screen is for the office, not only administrators). A COUNT,
  --  never a name - the subject is a parent's own words and can hold a
  --  child's. The same rows the Monday digest counts (outstanding_summary()),
  --  so the two cannot disagree. Two days is the line between "now" and
  --  "bad": a message that sits over a weekend must not go unnoticed.
  select count(*),
         coalesce(max(greatest((now() at time zone 'Europe/London')::date
                               - (t.last_message_at at time zone 'Europe/London')::date, 0)), 0)
    into n, m
    from public.madrasah_threads t
   where t.masjid_id = v_masjid and t.state = 'open';
  if n > 0 then
    v_items := v_items || jsonb_build_object(
      'key','messages','count',n,
      'tone', case when m >= 2 then 'bad' else 'now' end,
      'title', n || case when n = 1 then ' message from a parent is waiting for a reply'
                         else ' messages from parents are waiting for a reply' end,
      'said', case when m >= 2
              then 'The oldest has been waiting ' || m || ' days. A family that writes and hears nothing rings, or stops asking.'
              else 'A parent has written and is waiting to hear back.' end,
      'href','messages/','action','Open the messages');
  end if;

$b$ || v_anchor);
    if v_new = v_def then
      raise exception '125: the madrasah_today() patch changed nothing. NOT changed.';
    end if;
    execute v_new;
  else
    raise notice '125: madrasah_today() already has the messages item.';
  end if;

  --  ---- the Monday digest's summary ---------------------------------------
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'outstanding_summary';
  if v_def is null then
    raise exception '125: outstanding_summary() is not there to patch. NOT changed.';
  end if;
  if position('messages_waiting' in v_def) = 0 then
    v_anchor := $a$    'generated_at', now()$a$;
    v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    if v_n <> 1 then
      raise exception '125: expected generated_at once in outstanding_summary(), found %. NOT changed.', v_n;
    end if;
    v_new := replace(v_def, v_anchor,
$b$    --  ADDED BY 125. Parents' messages waiting for a reply, and how long the
    --  oldest has waited. A count and an age; no family, no subject. Scoped by
    --  (select m from me) for the cron-NULL reason db/108 gives, and counting
    --  exactly what madrasah_today() counts: state = 'open', London calendar
    --  days.
    'messages_waiting',
      jsonb_build_object(
        'count', (select count(*) from public.madrasah_threads t
                   where t.masjid_id = (select m from me) and t.state = 'open'),
        'oldest_days', coalesce((select greatest((select d from today)
                                          - (min(t.last_message_at) at time zone 'Europe/London')::date, 0)
                                   from public.madrasah_threads t
                                  where t.masjid_id = (select m from me) and t.state = 'open'), 0)),
$b$ || v_anchor);
    if v_new = v_def then
      raise exception '125: the outstanding_summary() patch changed nothing. NOT changed.';
    end if;
    execute v_new;
  else
    raise notice '125: outstanding_summary() already has messages_waiting.';
  end if;

  --  ---- send_weekly_digest(): the email must SEND when only a parent waits -
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_weekly_digest';
  if v_def is null then
    raise exception '125: send_weekly_digest() is not there to patch. NOT changed.';
  end if;
  if position('messages_waiting' in v_def) = 0 then
    v_anchor := 'then 0 else 1 end;';
    v_n := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
    if v_n <> 1 then
      raise exception '125: expected the v_total tail once in send_weekly_digest(), found %. NOT changed.', v_n;
    end if;
    v_new := replace(v_def, v_anchor,
$b$then 0 else 1 end
             --  ADDED BY 125. Without this a week whose only outstanding item is
             --  a parent waiting for a reply would compute v_total = 0 and send
             --  NOTHING - the silence this whole file exists to end.
             + coalesce((s->'messages_waiting'->>'count')::int, 0);$b$);
    if v_new = v_def then
      raise exception '125: the send_weekly_digest() patch changed nothing. NOT changed.';
    end if;
    execute v_new;
  else
    raise notice '125: send_weekly_digest() already counts messages_waiting.';
  end if;
end $mig$;

--  Grants restated exactly as db/086, db/108 and db/019 established them.
revoke all on function public.madrasah_today() from public, anon;
grant execute on function public.madrasah_today() to authenticated;
revoke all on function public.outstanding_summary(uuid) from public, anon;
grant execute on function public.outstanding_summary(uuid) to authenticated;
revoke all on function public.send_weekly_digest(boolean) from public;
revoke all on function public.send_weekly_digest(boolean) from anon, authenticated;

--  =====================================================================
--  THE PROOF. Runs inside a subtransaction that ends by raising a sentinel,
--  so NOTHING it writes survives (checked at the end). Any assertion that
--  fails raises a different error and aborts the WHOLE MIGRATION, so this
--  file cannot apply against a database where the messages do not do what
--  they say.
--
--  It runs AS THE REAL ACCOUNTS - the test parent, the test teacher and an
--  administrator, by setting the same request.jwt.claims the API would - and
--  as the two database roles (authenticated, anon) for the table grants.
--  =====================================================================
create or replace function pg_temp.px_as(p_uid uuid, p_aal text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', case when p_uid is null then '{}'
    else jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal)::text end, true);
end $$;

create or replace function pg_temp.px_ok(p_cond boolean, p_label text)
returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'PROOF FAILED: %', p_label; end if;
end $$;

--  Run a statement that returns jsonb.
create or replace function pg_temp.px_j(p_sql text)
returns jsonb language plpgsql as $$
declare r jsonb;
begin execute p_sql into r; return r; end $$;

--  Run a statement; require an exact sqlstate and (optionally) a fragment of
--  the refusal's own sentence. Every sentence is one of OURS.
create or replace function pg_temp.px_expect(p_sql text, p_state text, p_has text, p_label text)
returns void language plpgsql as $$
declare v_state text := 'none'; v_msg text := '';
begin
  begin execute p_sql;
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;
  if v_state <> p_state then
    raise exception 'PROOF FAILED: % (wanted %, got %)', p_label, p_state, v_state;
  end if;
  if p_has is not null and position(p_has in v_msg) = 0 then
    raise exception 'PROOF FAILED: % (the refusal does not say "%")', p_label, p_has;
  end if;
end $$;

--  The sorted key set of a jsonb object, for "and nothing else came back".
create or replace function pg_temp.px_keys(p_j jsonb)
returns text language sql as $$
  select coalesce(string_agg(k, ',' order by k collate "C"), '') from jsonb_object_keys(p_j) k;
$$;

do $proof$
declare
  v_teacher constant uuid := '42a0f447-f2b6-4a31-86c3-8bc2bddaad1b';
  v_masjid uuid; v_hh uuid; v_parent uuid; v_admin uuid;
  v_hh2 uuid; v_g2a uuid; v_g2b uuid; v_p2a uuid; v_p2b uuid;
  v_t uuid; v_t2 uuid; v_tx uuid; v_m2 uuid; v_hhx uuid; v_stranger uuid := gen_random_uuid();
  v_j jsonb; v_k jsonb; v_n int; v_n2 int; v_state text; v_msg text;
  v_audit_before int; v_audit_after int;
  v_ha uuid; v_hb uuid; v_pa uuid; v_pb uuid; v_ta uuid; v_tb uuid; v_sug uuid; v_lo uuid; v_hi uuid;
  v_orig text; v_patched text; k int; v_skip boolean := false;
begin
  begin   --  <<< the subtransaction the sentinel rolls back

  select h.id, h.masjid_id into v_hh, v_masjid from public.madrasah_households h
   where h.reference = 'MF-999999' and h.name = 'Zzzfamily test household';
  if v_hh is null then
    raise notice '125 proof: no test family here - the proof is skipped.';
    v_skip := true;
    raise exception 'SENTINEL' using errcode = 'P0999';
  end if;
  select l.user_id into v_parent from public.madrasah_parent_logins l
    join public.madrasah_guardians g on g.id = l.guardian_id where g.household_id = v_hh;
  select r.user_id into v_admin from public.user_roles r where r.role = 'admin' order by r.user_id limit 1;
  if v_parent is null or v_admin is null then
    raise exception '125 proof: the fixtures are missing (parent %, admin %)', v_parent is null, v_admin is null;
  end if;
  if (select count(*) from public.madrasah_threads) <> 0 then
    --  A replay after real conversations exist: the proof would count them.
    --  Skipped, not failed - the DDL above is idempotent and this is a record.
    raise notice '125 proof: there are real conversations here - the proof is skipped.';
    v_skip := true;
    raise exception 'SENTINEL' using errcode = 'P0999';
  end if;

  --  ==== 0. THE TABLES ARE NOT REACHABLE, AND EVERY ROLE IS TRIED =========
  perform pg_temp.px_ok((select relrowsecurity from pg_class where oid = 'public.madrasah_threads'::regclass), 'RLS is on for threads');
  perform pg_temp.px_ok((select relrowsecurity from pg_class where oid = 'public.madrasah_messages'::regclass), 'RLS is on for messages');
  perform pg_temp.px_ok((select count(*) from pg_policies where tablename in ('madrasah_threads','madrasah_messages')) = 0, 'no policy on either table');
  perform pg_temp.px_ok(not (has_table_privilege('anon', 'public.madrasah_threads', 'select,insert,update,delete')
                          or has_table_privilege('authenticated', 'public.madrasah_threads', 'select,insert,update,delete')
                          or has_table_privilege('anon', 'public.madrasah_messages', 'select,insert,update,delete')
                          or has_table_privilege('authenticated', 'public.madrasah_messages', 'select,insert,update,delete')),
                        'a table grant survived');
  --  the FOREIGN KEYS ARE CASCADES (catalogue), before anything is exercised
  perform pg_temp.px_ok((select confdeltype from pg_constraint where conrelid = 'public.madrasah_threads'::regclass
                            and confrelid = 'public.madrasah_households'::regclass) = 'c', 'threads -> household is not ON DELETE CASCADE');
  perform pg_temp.px_ok((select confdeltype from pg_constraint where conrelid = 'public.madrasah_messages'::regclass
                            and confrelid = 'public.madrasah_threads'::regclass) = 'c', 'messages -> thread is not ON DELETE CASCADE');
  --  and the roles themselves are refused, not just the catalogue
  foreach v_state in array array['authenticated', 'anon'] loop
    begin
      execute format('set local role %I', v_state);
      perform 1 from public.madrasah_threads limit 1;
      reset role; raise exception 'PROOF FAILED: role % read the threads table', v_state;
    exception when others then
      reset role;
      if sqlstate <> '42501' then raise exception 'PROOF FAILED: role % on the threads table got % (wanted 42501)', v_state, sqlstate; end if;
    end;
    begin
      execute format('set local role %I', v_state);
      insert into public.madrasah_messages (thread_id, body, from_parent) values (gen_random_uuid(), 'x', true);
      reset role; raise exception 'PROOF FAILED: role % wrote a message', v_state;
    exception when others then
      reset role;
      if sqlstate <> '42501' then raise exception 'PROOF FAILED: role % writing a message got % (wanted 42501)', v_state, sqlstate; end if;
    end;
  end loop;
  --  anon has EXECUTE on none of the new functions; a signed-in user has it
  --  on exactly the ten meant for them, and on NOT the helper.
  perform pg_temp.px_ok(not (
       has_function_privilege('anon', 'public.parent_threads()', 'execute')
    or has_function_privilege('anon', 'public.parent_thread_read(uuid)', 'execute')
    or has_function_privilege('anon', 'public.parent_thread_start(text,text)', 'execute')
    or has_function_privilege('anon', 'public.parent_thread_reply(uuid,text)', 'execute')
    or has_function_privilege('anon', 'public.parent_thread_mark_read(uuid)', 'execute')
    or has_function_privilege('anon', 'public.office_threads(text)', 'execute')
    or has_function_privilege('anon', 'public.office_threads_waiting_count()', 'execute')
    or has_function_privilege('anon', 'public.office_thread_read(uuid)', 'execute')
    or has_function_privilege('anon', 'public.office_thread_reply(uuid,text)', 'execute')
    or has_function_privilege('anon', 'public.office_thread_close(uuid)', 'execute')
    or has_function_privilege('anon', 'public.my_household_id()', 'execute')
    or has_function_privilege('authenticated', 'public.my_household_id()', 'execute')), 'anon can execute a messages function, or the helper is open');
  perform pg_temp.px_ok(
       has_function_privilege('authenticated', 'public.parent_threads()', 'execute')
   and has_function_privilege('authenticated', 'public.office_thread_read(uuid)', 'execute'),
   'CONTROL: a signed-in user has no execute at all (so the anon check above proves nothing)');

  --  ==== 1. A PARENT WRITES ================================================
  perform pg_temp.px_as(v_parent, 'aal1');
  v_j := public.parent_threads();
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and jsonb_array_length(v_j -> 'threads') = 0 and (v_j ->> 'unread')::int = 0,
                        'a parent with no conversations is allowed and sees none');
  perform pg_temp.px_expect($q$select public.parent_thread_start('   ', 'body')$q$, '22023', 'short title', 'a blank title');
  perform pg_temp.px_expect($q$select public.parent_thread_start('subject', '   ')$q$, '22023', 'write your message', 'a blank message');
  perform pg_temp.px_expect(format('select public.parent_thread_start(%L, ''body'')', repeat('s', 121)), '22023', '120 characters', 'a title of 121');
  perform pg_temp.px_expect(format('select public.parent_thread_start(''subject'', %L)', repeat('b', 4001)), '22023', 'too long', 'a message of 4001');
  perform pg_temp.px_ok((select count(*) from public.madrasah_threads) = 0, 'a refused start wrote something');

  v_j := public.parent_thread_start('ZZ-SUBJECT-A  ', '  ZZ-BODY-A  ');
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and (v_j ->> 'id') is not null, 'the parent could not start a thread');
  v_t := (v_j ->> 'id')::uuid;
  perform pg_temp.px_ok((select subject = 'ZZ-SUBJECT-A' and state = 'open' and unread_for_office and not unread_for_parent
                                and opened_by_parent and household_id = v_hh and masjid_id = v_masjid
                           from public.madrasah_threads where id = v_t),
                        'the new thread is not open, unread for the office, on the parent''s own household');
  perform pg_temp.px_ok((select count(*) from public.madrasah_messages where thread_id = v_t and body = 'ZZ-BODY-A'
                            and from_parent and author_user = v_parent) = 1, 'the first message is not the trimmed body by this parent');

  --  ==== 2. THE OFFICE SEES IT WAITING, EVERYWHERE, AND THE NUMBERS AGREE ==
  --  A DECOY that must NOT be counted: an open thread in another masjid.
  insert into public.masjids (slug, name, town) values ('zz-proof-masjid', 'ZZ Proof Masjid', 'Nowhere') returning id into v_m2;
  insert into public.madrasah_households (masjid_id, reference, name) values (v_m2, 'MF-999995', 'Zzzfamilyother proof household') returning id into v_hhx;
  insert into public.madrasah_threads (masjid_id, household_id, subject) values (v_m2, v_hhx, 'ZZ-OTHER-MASJID') returning id into v_tx;
  insert into public.madrasah_messages (thread_id, body, from_parent) values (v_tx, 'ZZ-OTHER-BODY', true);

  perform pg_temp.px_as(v_admin, 'aal2');
  v_j := public.office_threads('waiting');
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and jsonb_array_length(v_j -> 'threads') = 1
                        and (v_j -> 'counts' ->> 'waiting')::int = 1, 'the office does not see exactly one waiting thread (and none from another masjid)');
  perform pg_temp.px_ok(pg_temp.px_keys(v_j -> 'threads' -> 0) = 'created_at,days,id,last_message_at,messages,reference,state,subject,unread',
                        'the office list carries something other than its named keys (a family name, a body?)');
  perform pg_temp.px_ok(v_j::text not like '%ZZ-BODY%' and v_j::text not like '%Zzzfamily%' and v_j::text not like '%Testchild%',
                        'the office LIST carries a message body or a family name');
  perform pg_temp.px_ok((v_j -> 'threads' -> 0 ->> 'unread')::boolean, 'a new thread is not unread for the office');
  v_j := public.office_threads_waiting_count();
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and (v_j ->> 'count')::int = 1 and (v_j ->> 'oldest_days')::int = 0, 'the count sibling does not say one, today');
  --  TODAY: one item, a count, a link, no name and no word of the message
  v_j := public.madrasah_today();
  perform pg_temp.px_ok(v_j ->> 'allowed' = 'true', 'Today did not answer for the office');
  select count(*) into v_n from jsonb_array_elements(v_j -> 'items') i where i ->> 'key' = 'messages';
  perform pg_temp.px_ok(v_n = 1, 'Today does not carry exactly one messages item');
  select i into v_k from jsonb_array_elements(v_j -> 'items') i where i ->> 'key' = 'messages';
  perform pg_temp.px_ok((v_k ->> 'count')::int = 1 and v_k ->> 'href' = 'messages/' and v_k ->> 'tone' = 'now'
                        and v_k ->> 'title' = '1 message from a parent is waiting for a reply', 'Today''s item is not a count, a link and a plain title');
  perform pg_temp.px_ok(v_k::text not like '%ZZ-%' and v_k::text not like '%Zzzfamily%' and v_k::text not like '%MF-9%',
                        'Today''s item names a family, a reference or a word of the message');
  --  THE DIGEST'S SUMMARY, signed in, and then under the no-session path cron uses
  v_j := public.outstanding_summary(v_masjid);
  perform pg_temp.px_ok((v_j -> 'messages_waiting' ->> 'count')::int = 1 and (v_j -> 'messages_waiting' ->> 'oldest_days')::int = 0
                        and pg_temp.px_keys(v_j -> 'messages_waiting') = 'count,oldest_days',
                        'the digest summary (signed in) does not say one, today, and nothing else');
  perform pg_temp.px_as(null, null);
  v_j := public.outstanding_summary(v_masjid);
  perform pg_temp.px_ok((v_j -> 'messages_waiting' ->> 'count')::int = 1, 'the digest summary under the cron path (no session) does not say one');
  v_j := public.outstanding_summary(v_m2);
  perform pg_temp.px_ok((v_j -> 'messages_waiting' ->> 'count')::int = 1, 'the digest summary does not scope by the masjid it is asked about');
  perform pg_temp.px_ok(v_j::text not like '%ZZ-%' and v_j::text not like '%Zzzfamily%', 'the digest summary carries a subject, a body or a family name');
  --  THE AGE: an old waiting thread makes it 'bad' on Today and shows in the digest
  perform pg_temp.px_as(null, null);
  update public.madrasah_threads set last_message_at = now() - interval '4 days' where id = v_t;
  perform pg_temp.px_as(v_admin, 'aal2');
  v_j := public.madrasah_today();
  select i into v_k from jsonb_array_elements(v_j -> 'items') i where i ->> 'key' = 'messages';
  perform pg_temp.px_ok(v_k ->> 'tone' = 'bad' and (v_k ->> 'said') like 'The oldest has been waiting 4 days.%', 'a message that has waited four days is not marked bad and dated');
  perform pg_temp.px_ok((public.outstanding_summary(v_masjid) -> 'messages_waiting' ->> 'oldest_days')::int = 4
                        and (public.office_threads_waiting_count() ->> 'oldest_days')::int = 4
                        and (public.office_threads('waiting') -> 'threads' -> 0 ->> 'days')::int = 4,
                        'Today, the digest, the count and the list disagree about how long it has waited');
  perform pg_temp.px_as(null, null);
  update public.madrasah_threads set last_message_at = now() where id = v_t;
  perform pg_temp.px_as(v_admin, 'aal2');
  --  AGREEMENT: the four surfaces give one number
  perform pg_temp.px_ok(
       (public.office_threads_waiting_count() ->> 'count')::int
     = (public.office_threads('waiting') -> 'counts' ->> 'waiting')::int
     and (public.office_threads_waiting_count() ->> 'count')::int
     = (select (i ->> 'count')::int from jsonb_array_elements(public.madrasah_today() -> 'items') i where i ->> 'key' = 'messages')
     and (public.office_threads_waiting_count() ->> 'count')::int
     = (public.outstanding_summary(v_masjid) -> 'messages_waiting' ->> 'count')::int,
     'Today, the digest, the list and the count disagree about the number of waiting messages');

  --  ==== 3. THE OFFICE READS: AUDITED, NAMING THE THREAD AND THE HOUSEHOLD =
  --  the detector is not vacuous: a call that does not audit reads zero
  select count(*) into v_audit_before from public.admin_audit where action = 'message_thread_opened';
  perform public.office_threads('all');
  perform public.office_threads_waiting_count();
  select count(*) into v_audit_after from public.admin_audit where action = 'message_thread_opened';
  perform pg_temp.px_ok(v_audit_after = v_audit_before, 'CONTROL: listing the threads wrote an "opened" audit row (so the audit check proves nothing)');

  v_j := public.office_thread_read(v_t);
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and jsonb_array_length(v_j -> 'messages') = 1
                        and v_j -> 'messages' -> 0 ->> 'body' = 'ZZ-BODY-A'
                        and v_j -> 'thread' ->> 'subject' = 'ZZ-SUBJECT-A', 'the office could not read the thread');
  perform pg_temp.px_ok(pg_temp.px_keys(v_j -> 'thread') = 'created_at,family,id,last_message_at,reference,state,subject,unread'
                        and pg_temp.px_keys(v_j -> 'messages' -> 0) = 'body,created_at,from_parent,who',
                        'the office read carries something other than its named keys');
  perform pg_temp.px_ok(v_j -> 'thread' ->> 'family' = 'Zzzfamily test household' and v_j -> 'thread' ->> 'reference' = 'MF-999999',
                        'the opened thread does not name the family');
  perform pg_temp.px_ok(v_j -> 'messages' -> 0 ->> 'who' <> 'A parent in this family', 'the message is not attributed to the guardian who wrote it');
  select count(*) into v_audit_after from public.admin_audit where action = 'message_thread_opened';
  perform pg_temp.px_ok(v_audit_after = v_audit_before + 1, 'opening a thread did not write exactly one audit row');
  perform pg_temp.px_ok((select pg_temp.px_keys(detail) = 'household,thread' and (detail ->> 'thread')::uuid = v_t
                                and (detail ->> 'household')::uuid = v_hh and actor = v_admin and masjid_id = v_masjid
                                and detail::text not like '%ZZ-%' and detail::text not like '%Zzzfamily%'
                           from public.admin_audit where action = 'message_thread_opened' order by id desc limit 1),
                        'the audit row is not exactly {thread, household}, by this administrator, with no subject, body or name');
  perform pg_temp.px_ok((select not unread_for_office from public.madrasah_threads where id = v_t) and (select state from public.madrasah_threads where id = v_t) = 'open',
                        'reading marks it read for the office but must leave it WAITING until somebody replies');
  perform pg_temp.px_ok((public.office_threads_waiting_count() ->> 'count')::int = 1, 'reading a thread took it off the waiting count');

  --  ==== 4. THE OFFICE REPLIES; THE PARENT READS IT ========================
  perform pg_temp.px_expect(format('select public.office_thread_reply(%L, ''   '')', v_t), '22023', 'Write the reply first', 'a blank reply');
  v_j := public.office_thread_reply(v_t, ' ZZ-REPLY-A ');
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and v_j ->> 'state' = 'answered', 'the office reply did not answer the thread');
  perform pg_temp.px_ok((select state = 'answered' and unread_for_parent and not unread_for_office from public.madrasah_threads where id = v_t), 'answered thread flags are wrong');
  perform pg_temp.px_ok((public.office_threads_waiting_count() ->> 'count')::int = 0, 'an answered thread still counts as waiting');
  perform pg_temp.px_ok(not exists (select 1 from jsonb_array_elements(public.madrasah_today() -> 'items') i where i ->> 'key' = 'messages'),
                        'Today still shows a messages item once every message is answered');
  perform pg_temp.px_ok((public.outstanding_summary(v_masjid) -> 'messages_waiting' ->> 'count')::int = 0 and (public.outstanding_summary(v_masjid) -> 'messages_waiting' ->> 'oldest_days')::int = 0,
                        'the digest still counts an answered thread');
  perform pg_temp.px_ok((select count(*) from public.admin_audit where action = 'message_thread_replied' and (detail ->> 'thread')::uuid = v_t) = 1
                        and (select pg_temp.px_keys(detail) = 'household,reopened,thread' and detail::text not like '%ZZ-%'
                               from public.admin_audit where action = 'message_thread_replied' order by id desc limit 1),
                        'the reply was not audited as {thread, household, reopened} with no words');

  perform pg_temp.px_as(v_parent, 'aal1');
  v_j := public.parent_threads();
  perform pg_temp.px_ok((v_j ->> 'unread')::int = 1 and (v_j -> 'threads' -> 0 ->> 'unread')::boolean and v_j -> 'threads' -> 0 ->> 'state' = 'answered',
                        'the parent is not told there is a reply');
  perform pg_temp.px_ok(pg_temp.px_keys(v_j -> 'threads' -> 0) = 'created_at,id,last_message_at,state,subject,unread', 'the parent list carries something other than its named keys');
  v_j := public.parent_thread_read(v_t);
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and jsonb_array_length(v_j -> 'messages') = 2
                        and v_j -> 'messages' -> 0 ->> 'who' = 'you' and v_j -> 'messages' -> 0 ->> 'body' = 'ZZ-BODY-A'
                        and v_j -> 'messages' -> 1 ->> 'who' = 'office' and v_j -> 'messages' -> 1 ->> 'body' = 'ZZ-REPLY-A',
                        'the parent does not read their message and the office''s reply, in order, as you / the office');
  perform pg_temp.px_ok(pg_temp.px_keys(v_j -> 'messages' -> 1) = 'body,created_at,from_parent,who'
                        and pg_temp.px_keys(v_j -> 'thread') = 'created_at,id,last_message_at,state,subject,unread'
                        and v_j::text not like '%' || v_admin::text || '%' and v_j::text not like '%' || v_parent::text || '%'
                        and v_j::text not like '%' || v_hh::text || '%' and v_j::text not like '%' || v_masjid::text || '%',
                        'the parent read carries an account id, the household id, the masjid id or an unnamed key');
  perform pg_temp.px_ok(v_j -> 'thread' ->> 'unread' = 'true', 'reading is a pure read: it must not mark itself read');
  v_j := public.parent_thread_mark_read(v_t);
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and (public.parent_threads() ->> 'unread')::int = 0, 'mark read did not clear the unread flag');

  --  ==== 5. THE PARENT REPLIES; THE OFFICE CLOSES ==========================
  v_j := public.parent_thread_reply(v_t, 'ZZ-BODY-A2');
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and v_j ->> 'state' = 'open', 'the parent could not reply');
  perform pg_temp.px_ok((select state = 'open' and unread_for_office and not unread_for_parent from public.madrasah_threads where id = v_t), 'a parent reply does not put the thread back to waiting');
  perform pg_temp.px_as(v_admin, 'aal2');
  perform pg_temp.px_ok((public.office_threads_waiting_count() ->> 'count')::int = 1, 'the parent''s second message is not waiting');
  --  closing WITHOUT a reply to the second message is audited as such only when NO reply was ever sent: here one was
  v_j := public.office_thread_close(v_t);
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and v_j ->> 'state' = 'closed', 'the office could not close the thread');
  perform pg_temp.px_ok((select (detail ->> 'without_reply')::boolean = false and pg_temp.px_keys(detail) = 'household,thread,without_reply'
                           from public.admin_audit where action = 'message_thread_closed' order by id desc limit 1), 'the close audit is wrong');
  select count(*) into v_n from public.admin_audit where action = 'message_thread_closed';
  perform public.office_thread_close(v_t);
  perform pg_temp.px_ok((select count(*) from public.admin_audit where action = 'message_thread_closed') = v_n, 'closing a closed thread audited again');
  perform pg_temp.px_ok((public.office_threads_waiting_count() ->> 'count')::int = 0, 'a closed thread still counts as waiting');
  perform pg_temp.px_ok((public.office_threads('closed') -> 'counts' ->> 'closed')::int = 1 and jsonb_array_length(public.office_threads('closed') -> 'threads') = 1
                        and jsonb_array_length(public.office_threads('waiting') -> 'threads') = 0, 'the tabs do not sort the thread as closed');
  perform pg_temp.px_as(v_parent, 'aal1');
  perform pg_temp.px_expect(format('select public.parent_thread_reply(%L, ''too late'')', v_t), '22023', 'closed this conversation', 'a parent replying to a closed thread');
  perform pg_temp.px_ok(public.parent_thread_read(v_t) -> 'thread' ->> 'state' = 'closed', 'the parent is not shown that it is closed');
  --  the office replying to a closed thread reopens it as answered
  perform pg_temp.px_as(v_admin, 'aal2');
  v_j := public.office_thread_reply(v_t, 'ZZ-REPLY-B');
  perform pg_temp.px_ok(v_j ->> 'state' = 'answered' and (select (detail ->> 'reopened')::boolean from public.admin_audit where action = 'message_thread_replied' order by id desc limit 1),
                        'an office reply to a closed thread did not reopen it as answered, audited as reopened');
  --  closing a thread nobody ever answered is audited as without_reply
  perform pg_temp.px_as(v_parent, 'aal1');
  v_t2 := (public.parent_thread_start('ZZ-SUBJECT-B', 'ZZ-BODY-B') ->> 'id')::uuid;
  perform pg_temp.px_as(v_admin, 'aal2');
  perform public.office_thread_close(v_t2);
  perform pg_temp.px_ok((select (detail ->> 'without_reply')::boolean from public.admin_audit where action = 'message_thread_closed' order by id desc limit 1),
                        'closing an unanswered thread was not audited as without_reply');

  --  ==== 6. THE REFUSALS ====================================================
  --  A SECOND HOUSEHOLD, with two guardians who each have a login, built
  --  without touching a pupil (the login row is inserted directly).
  perform pg_temp.px_as(v_admin, 'aal2');
  insert into public.madrasah_households (masjid_id, reference, name) values (v_masjid, 'MF-999998', 'Zzzfamilytwo proof household') returning id into v_hh2;
  insert into public.madrasah_guardians (masjid_id, household_id, full_name, is_primary) values (v_masjid, v_hh2, 'Proofparent Alpha', true) returning id into v_g2a;
  insert into public.madrasah_guardians (masjid_id, household_id, full_name, is_primary) values (v_masjid, v_hh2, 'Proofparent Beta', false) returning id into v_g2b;
  v_p2a := gen_random_uuid(); v_p2b := gen_random_uuid();
  insert into auth.users (id, instance_id, aud, role, email) values
    (v_p2a, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'proof.parent.alpha@example.test'),
    (v_p2b, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'proof.parent.beta@example.test');
  insert into public.madrasah_parent_logins (masjid_id, guardian_id, user_id) values (v_masjid, v_g2a, v_p2a), (v_masjid, v_g2b, v_p2b);

  --  --- 6a. A PARENT REACHING ANOTHER HOUSEHOLD'S THREAD -------------------
  select count(*) into v_n from public.madrasah_messages;
  perform pg_temp.px_as(v_p2a, 'aal1');
  v_j := public.parent_threads();
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and jsonb_array_length(v_j -> 'threads') = 0 and v_j::text not like '%ZZ-%',
                        'CONTROL: another household''s list must be allowed, and must not contain the first household''s thread');
  v_j := public.parent_thread_read(v_t);
  perform pg_temp.px_ok(v_j = '{"allowed": false}'::jsonb, 'household B reading household A''s thread did not get exactly {allowed:false}');
  perform pg_temp.px_ok(public.parent_thread_read(gen_random_uuid()) = v_j and public.parent_thread_read(null) = v_j,
                        'a thread that does not exist answers differently from a thread that is not yours (a probe)');
  perform pg_temp.px_ok(public.parent_thread_reply(v_t, 'ZZ-INTRUDER') = v_j and public.parent_thread_reply(v_t, '') = v_j
                        and public.parent_thread_reply(v_t, repeat('x', 5000)) = v_j,
                        'household B replying to household A''s thread was not refused identically whatever it sent');
  perform pg_temp.px_ok(public.parent_thread_mark_read(v_t) = v_j and public.parent_thread_reply(gen_random_uuid(), 'x') = v_j,
                        'household B marking A''s thread read was not refused');
  perform pg_temp.px_ok((select count(*) from public.madrasah_messages) = v_n and (select unread_for_parent from public.madrasah_threads where id = v_t) is true,
                        'a refused parent changed the thread or wrote a message (the thread was left unread for household A)');
  --  and the same parent CAN do it to their own (the refusal is scoped, not blanket)
  v_j := public.parent_thread_start('ZZ-SUBJECT-C', 'ZZ-BODY-C');
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean, 'CONTROL: household B could not write to the office');
  v_t2 := (v_j ->> 'id')::uuid;
  perform pg_temp.px_as(v_parent, 'aal1');
  perform pg_temp.px_ok(public.parent_thread_read(v_t2) = '{"allowed": false}'::jsonb and public.parent_thread_reply(v_t2, 'x') = '{"allowed": false}'::jsonb,
                        'household A reading or answering household B''s thread was not refused');
  perform pg_temp.px_ok(v_t2 not in (select (e ->> 'id')::uuid from jsonb_array_elements(public.parent_threads() -> 'threads') e), 'household A''s list contains household B''s thread');

  --  --- 6b. EITHER GUARDIAN OF A HOUSEHOLD, AND A LOGIN BEING REMOVED ------
  perform pg_temp.px_as(v_p2b, 'aal1');
  v_j := public.parent_thread_read(v_t2);
  perform pg_temp.px_ok((v_j ->> 'allowed')::boolean and v_j -> 'messages' -> 0 ->> 'who' = 'household' and v_j -> 'messages' -> 0 ->> 'body' = 'ZZ-BODY-C',
                        'the other guardian cannot read a thread their partner started, or it is not labelled as the household''s');
  perform pg_temp.px_as(v_admin, 'aal2');
  v_j := public.office_thread_read(v_t2);
  perform pg_temp.px_ok(v_j -> 'messages' -> 0 ->> 'who' = 'Proofparent Alpha', 'the office is not told which guardian wrote it');
  perform public.office_thread_reply(v_t2, 'ZZ-REPLY-C');
  perform pg_temp.px_as(null, null);
  delete from public.madrasah_parent_logins where user_id = v_p2a;
  perform pg_temp.px_ok((select count(*) from public.madrasah_threads where id = v_t2) = 1 and (select count(*) from public.madrasah_messages where thread_id = v_t2) = 2,
                        'removing a login removed a conversation');
  perform pg_temp.px_as(v_p2b, 'aal1');
  perform pg_temp.px_ok(jsonb_array_length(public.parent_thread_read(v_t2) -> 'messages') = 2, 'the remaining guardian cannot read the thread after the other login was removed');
  perform pg_temp.px_as(v_p2a, 'aal1');
  perform pg_temp.px_ok(public.parent_threads() = '{"allowed": false}'::jsonb and public.parent_thread_read(v_t2) = '{"allowed": false}'::jsonb,
                        'a removed login still reaches the household''s threads');
  perform pg_temp.px_as(v_admin, 'aal2');
  v_j := public.office_thread_read(v_t2);
  perform pg_temp.px_ok(v_j -> 'messages' -> 0 ->> 'who' = 'A parent in this family', 'a removed login''s message is not attributed generically');

  --  --- 6c. WHO ELSE IS REFUSED THE OFFICE SCREEN -------------------------
  select count(*) into v_audit_before from public.admin_audit where action like 'message_thread_%';
  select count(*) into v_n from public.madrasah_messages;
  select count(*) into v_n2 from public.madrasah_threads;
  foreach v_state in array array['teacher/aal1', 'teacher/aal2', 'admin/aal1', 'stranger/aal2', 'parent/aal1', 'nobody/none'] loop
    if v_state = 'teacher/aal1' then perform pg_temp.px_as(v_teacher, 'aal1');
    elsif v_state = 'teacher/aal2' then perform pg_temp.px_as(v_teacher, 'aal2');
    elsif v_state = 'admin/aal1' then perform pg_temp.px_as(v_admin, 'aal1');
    elsif v_state = 'stranger/aal2' then perform pg_temp.px_as(v_stranger, 'aal2');
    elsif v_state = 'parent/aal1' then perform pg_temp.px_as(v_parent, 'aal1');
    else perform pg_temp.px_as(null, null); end if;
    perform pg_temp.px_ok(public.office_threads('waiting') = '{"allowed": false}'::jsonb
                      and public.office_threads('all') = '{"allowed": false}'::jsonb
                      and public.office_threads_waiting_count() = '{"allowed": false}'::jsonb
                      and public.office_thread_read(v_t) = '{"allowed": false}'::jsonb
                      and public.office_thread_read(gen_random_uuid()) = '{"allowed": false}'::jsonb
                      and public.office_thread_reply(v_t, 'ZZ-INTRUDER') = '{"allowed": false}'::jsonb
                      and public.office_thread_close(v_t) = '{"allowed": false}'::jsonb,
                      format('the office screen answered for %s (it must be exactly {allowed:false}, list included)', v_state));
  end loop;
  perform pg_temp.px_ok((select count(*) from public.madrasah_messages) = v_n
                        and (select count(*) from public.admin_audit where action like 'message_thread_%') = v_audit_before
                        and (select state from public.madrasah_threads where id = v_t) = 'answered',
                        'a refused office caller wrote a message, an audit row, or changed a thread');
  --  a teacher, an unfamiliar account, the office and nobody are not parents either
  foreach v_state in array array['teacher/aal1', 'admin/aal2', 'stranger/aal2', 'nobody/none'] loop
    if v_state = 'teacher/aal1' then perform pg_temp.px_as(v_teacher, 'aal1');
    elsif v_state = 'admin/aal2' then perform pg_temp.px_as(v_admin, 'aal2');
    elsif v_state = 'stranger/aal2' then perform pg_temp.px_as(v_stranger, 'aal2');
    else perform pg_temp.px_as(null, null); end if;
    perform pg_temp.px_ok(public.parent_threads() = '{"allowed": false}'::jsonb
                      and public.parent_thread_read(v_t) = '{"allowed": false}'::jsonb
                      and public.parent_thread_start('ZZ', 'ZZ') = '{"allowed": false}'::jsonb
                      and public.parent_thread_reply(v_t, 'ZZ') = '{"allowed": false}'::jsonb
                      and public.parent_thread_mark_read(v_t) = '{"allowed": false}'::jsonb,
                      format('a non-parent (%s) was let into the parent functions', v_state));
  end loop;
  perform pg_temp.px_ok((select count(*) from public.madrasah_threads) = v_n2, 'a non-parent started a thread');
  --  the same real account, in the right role, IS let in (the refusals above are not blanket)
  perform pg_temp.px_as(v_admin, 'aal2');
  perform pg_temp.px_ok((public.office_threads('all') ->> 'allowed')::boolean, 'CONTROL: the administrator with two-step is refused');

  --  --- 6d. ANOTHER MASJID'S THREAD, AS THE OFFICE -------------------------
  perform pg_temp.px_ok(public.office_thread_read(v_tx) = '{"allowed": false}'::jsonb
                    and public.office_thread_reply(v_tx, 'ZZ-INTRUDER') = '{"allowed": false}'::jsonb
                    and public.office_thread_close(v_tx) = '{"allowed": false}'::jsonb
                    and public.office_thread_read(v_tx) = public.office_thread_read(gen_random_uuid()),
                    'the office of one masjid reached another masjid''s thread, or it answers differently from a thread that is not there');
  perform pg_temp.px_ok((select state = 'open' and count(*) over () = 1 from public.madrasah_threads where id = v_tx), 'the other masjid''s thread was changed');
  perform pg_temp.px_ok(v_tx not in (select (e ->> 'id')::uuid from jsonb_array_elements(public.office_threads('all') -> 'threads') e), 'the other masjid''s thread is in this office''s list');

  --  --- 6e. THE BOUNDS -----------------------------------------------------
  perform pg_temp.px_as(v_p2b, 'aal1');
  for k in 1..4 loop perform public.parent_thread_start('ZZ-CAP-' || k, 'ZZ-CAP'); end loop;    -- with v_t2 = five open
  perform pg_temp.px_expect($q$select public.parent_thread_start('ZZ-CAP-6', 'ZZ-CAP')$q$, '22023', 'five conversations open', 'a sixth open thread');
  perform pg_temp.px_as(v_admin, 'aal2');
  perform public.office_thread_close((select id from public.madrasah_threads where household_id = v_hh2 and subject = 'ZZ-CAP-1'));
  perform pg_temp.px_as(v_p2b, 'aal1');
  perform pg_temp.px_ok((public.parent_thread_start('ZZ-CAP-7', 'ZZ-CAP') ->> 'allowed')::boolean, 'closing a thread did not free a slot');
  --  twenty parent messages in a day
  perform pg_temp.px_as(null, null);
  insert into public.madrasah_messages (thread_id, body, from_parent, author_user)
    select v_t2, 'ZZ-FLOOD', true, v_p2b from generate_series(1, 20);
  perform pg_temp.px_as(v_p2b, 'aal1');
  perform pg_temp.px_expect(format('select public.parent_thread_reply(%L, ''one more'')', v_t2), '22023', 'lot of messages today', 'a twenty-first message in a day');
  perform pg_temp.px_expect($q$select public.parent_thread_start('ZZ-CAP-8', 'x')$q$, '22023', 'lot of messages today', 'a new thread past the daily cap');

  --  ==== 7. THE RETENTION: THE CASCADE, AGAINST THE REAL PATHS =============
  --  7a. the raw DELETE of a household
  perform pg_temp.px_as(null, null);
  declare v_hd uuid; v_td uuid; begin
    insert into public.madrasah_households (masjid_id, reference, name) values (v_masjid, 'MF-999997', 'Zzzfamilythree proof household') returning id into v_hd;
    insert into public.madrasah_threads (masjid_id, household_id, subject) values (v_masjid, v_hd, 'ZZ-CASCADE') returning id into v_td;
    insert into public.madrasah_messages (thread_id, body, from_parent) values (v_td, 'ZZ-C1', true), (v_td, 'ZZ-C2', false);
    perform pg_temp.px_ok((select count(*) from public.madrasah_messages where thread_id = v_td) = 2, 'CONTROL: the cascade fixture has no messages');
    delete from public.madrasah_households where id = v_hd;
    perform pg_temp.px_ok((select count(*) from public.madrasah_threads where id = v_td) = 0
                      and (select count(*) from public.madrasah_messages where thread_id = v_td) = 0,
                      'deleting a household did NOT delete its threads and messages');
  end;
  --  7b. the administrator's delete_madrasah_household() (a household with no pupil)
  declare v_hd uuid; v_td uuid; begin
    insert into public.madrasah_households (masjid_id, reference, name) values (v_masjid, 'MF-999996', 'Zzzfamilyfour proof household') returning id into v_hd;
    insert into public.madrasah_threads (masjid_id, household_id, subject) values (v_masjid, v_hd, 'ZZ-CASCADE') returning id into v_td;
    insert into public.madrasah_messages (thread_id, body, from_parent) values (v_td, 'ZZ-C1', true);
    perform pg_temp.px_as(v_admin, 'aal2');
    perform public.delete_madrasah_household(v_hd);
    perform pg_temp.px_ok((select count(*) from public.madrasah_threads where id = v_td) = 0
                      and (select count(*) from public.madrasah_messages where thread_id = v_td) = 0,
                      'delete_madrasah_household() left a thread or a message behind');
  end;
  --  7c. THE PURGE, three years on: an old household with no pupil goes with
  --  its conversations; a recent one, with the same, stays.
  perform pg_temp.px_as(null, null);
  declare v_old uuid; v_new uuid; v_to uuid; v_tn uuid; begin
    insert into public.madrasah_households (masjid_id, reference, name, updated_at) values (v_masjid, 'MF-999994', 'Zzzfamilyold proof household', now() - interval '4 years') returning id into v_old;
    insert into public.madrasah_households (masjid_id, reference, name) values (v_masjid, 'MF-999993', 'Zzzfamilynew proof household') returning id into v_new;
    insert into public.madrasah_threads (masjid_id, household_id, subject) values (v_masjid, v_old, 'ZZ-OLD') returning id into v_to;
    insert into public.madrasah_threads (masjid_id, household_id, subject) values (v_masjid, v_new, 'ZZ-NEW') returning id into v_tn;
    insert into public.madrasah_messages (thread_id, body, from_parent) values (v_to, 'ZZ-OLD', true), (v_tn, 'ZZ-NEW', true);
    perform pg_temp.px_ok((select updated_at < now() - interval '3 years' from public.madrasah_households where id = v_old),
                          'CONTROL: the old household was not made old (so the purge test proves nothing)');
    perform public.purge_madrasah_households();
    perform pg_temp.px_ok((select count(*) from public.madrasah_households where id = v_old) = 0
                      and (select count(*) from public.madrasah_threads where id = v_to) = 0
                      and (select count(*) from public.madrasah_messages where thread_id = v_to) = 0,
                      'the three-year purge removed an old household but left its conversation behind');
    perform pg_temp.px_ok((select count(*) from public.madrasah_households where id = v_new) = 1
                      and (select count(*) from public.madrasah_threads where id = v_tn) = 1
                      and (select count(*) from public.madrasah_messages where thread_id = v_tn) = 1,
                      'the purge removed a recent household''s conversation');
  end;

  --  7d. A MERGE. Two throwaway families with a throwaway child each (invented,
  --  wrapped so only a sqlstate can escape). First against the function AS IT
  --  WAS - the messages must VANISH, proving this test can fail - then against
  --  the patched one, where they must survive.
  select pg_get_functiondef(p.oid) into v_patched
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'settle_sibling_suggestion';
  perform pg_temp.px_ok(position('update public.madrasah_threads set household_id = v_keep' in v_patched) > 0, 'the merge function does not move threads');
  v_orig := replace(v_patched,
    E'\n      --  ADDED BY 125. The household deleted below takes its conversations with it\n      --  (ON DELETE CASCADE) unless they are moved first.\n      update public.madrasah_threads set household_id = v_keep where household_id = v_move;', '');
  perform pg_temp.px_ok(v_orig <> v_patched and position('madrasah_threads' in v_orig) = 0, 'CONTROL: could not reconstruct the unpatched merge function');

  for k in 1..2 loop
    if k = 1 then execute v_orig; else execute v_patched; end if;
    perform pg_temp.px_as(v_admin, 'aal2');
    insert into public.madrasah_households (masjid_id, reference, name) values (v_masjid, 'MF-99990' || k, 'Zzzmergea proof household') returning id into v_ha;
    insert into public.madrasah_households (masjid_id, reference, name) values (v_masjid, 'MF-99991' || k, 'Zzzmergeb proof household') returning id into v_hb;
    begin
      insert into public.madrasah_pupils (masjid_id, household_id, first_name, last_name, joined_on) values (v_masjid, v_ha, 'Mergechilda', 'Zzzmerge', current_date - 30) returning id into v_pa;
      insert into public.madrasah_pupils (masjid_id, household_id, first_name, last_name, joined_on) values (v_masjid, v_hb, 'Mergechildb', 'Zzzmerge', current_date - 30) returning id into v_pb;
      insert into public.madrasah_pupils (masjid_id, household_id, first_name, last_name, joined_on) values (v_masjid, v_hb, 'Mergechildc', 'Zzzmerge', current_date - 30);
    exception when others then
      raise exception 'refused: %', sqlstate;
    end;
    --  household A has ONE child, B has TWO: B keeps its reference, A is the one deleted
    insert into public.madrasah_threads (masjid_id, household_id, subject) values (v_masjid, v_ha, 'ZZ-MERGE-A') returning id into v_ta;
    insert into public.madrasah_threads (masjid_id, household_id, subject) values (v_masjid, v_hb, 'ZZ-MERGE-B') returning id into v_tb;
    insert into public.madrasah_messages (thread_id, body, from_parent) values (v_ta, 'ZZ-MA', true), (v_tb, 'ZZ-MB', true);
    v_lo := least(v_pa, v_pb); v_hi := greatest(v_pa, v_pb);
    insert into public.madrasah_sibling_suggestions (masjid_id, pupil_a, pupil_b, why) values (v_masjid, v_lo, v_hi, 'proof') returning id into v_sug;
    perform public.settle_sibling_suggestion(v_sug, true);
    perform pg_temp.px_ok((select count(*) from public.madrasah_households where id in (v_ha, v_hb)) = 1, 'the merge did not leave exactly one household');
    select count(*) into v_n from public.madrasah_messages where thread_id in (v_ta, v_tb) and body in ('ZZ-MA', 'ZZ-MB');
    if k = 1 then
      perform pg_temp.px_ok(v_n = 1, 'CONTROL FAILED: with the unpatched merge function the deleted household''s message should have been destroyed - so this test cannot fail');
    else
      perform pg_temp.px_ok(v_n = 2 and (select count(*) from public.madrasah_threads where id in (v_ta, v_tb)
                                             and household_id = (select id from public.madrasah_households where id in (v_ha, v_hb))) = 2,
                            'the patched merge did not carry both conversations onto the household that was kept');
    end if;
  end loop;

  --  ==== 8. THE OTHER FUNCTIONS THIS FILE TOUCHED STILL DO THEIR JOB ========
  perform pg_temp.px_as(v_admin, 'aal2');
  perform pg_temp.px_ok(public.madrasah_today() ->> 'allowed' = 'true' and jsonb_typeof(public.madrasah_today() -> 'items') = 'array'
                        and jsonb_typeof(public.outstanding_summary(v_masjid) -> 'registers_missed') = 'object'
                        and (public.outstanding_summary(v_masjid) ->> 'new_nikah') is not null, 'Today or the digest summary lost what they already said');
  perform pg_temp.px_as(v_teacher, 'aal1');
  perform pg_temp.px_ok(public.madrasah_today() = '{"allowed": false}'::jsonb, 'a teacher can now open Today');
  perform pg_temp.px_ok(has_function_privilege('anon', 'public.madrasah_today()', 'execute') is false
                    and has_function_privilege('anon', 'public.outstanding_summary(uuid)', 'execute') is false
                    and has_function_privilege('anon', 'public.settle_sibling_suggestion(uuid,boolean)', 'execute') is false
                    and has_function_privilege('authenticated', 'public.send_weekly_digest(boolean)', 'execute') is false
                    and has_function_privilege('anon', 'public.send_weekly_digest(boolean)', 'execute') is false,
                    'a function this file patched has the wrong grants');

  --  ---- the sentinel: roll it all back ------------------------------------
  perform pg_temp.px_as(null, null);
  raise exception 'SENTINEL' using errcode = 'P0999';
  exception when sqlstate 'P0999' then
    perform set_config('request.jwt.claims', '{}', true);
    reset role;
  end;

  --  ---- NOTHING SURVIVED ----------------------------------------------------
  if v_skip then return; end if;
  if (select count(*) from public.madrasah_threads) <> 0
     or (select count(*) from public.madrasah_messages) <> 0
     or (select count(*) from public.admin_audit where action like 'message_thread_%') <> 0
     or exists (select 1 from public.masjids where slug = 'zz-proof-masjid')
     or exists (select 1 from public.madrasah_households where reference in
                ('MF-999998','MF-999997','MF-999996','MF-999995','MF-999994','MF-999993',
                 'MF-999901','MF-999902','MF-999911','MF-999912'))
     or exists (select 1 from auth.users where email like 'proof.parent.%@example.test')
     or exists (select 1 from public.madrasah_pupils where last_name = 'Zzzmerge')
     or exists (select 1 from public.madrasah_sibling_suggestions where why = 'proof')
     or exists (select 1 from public.madrasah_parent_logins l
                 join public.madrasah_guardians g on g.id = l.guardian_id where g.full_name like 'Proofparent%') then
    raise exception 'PROOF FAILED: something the proof wrote survived it';
  end if;
  if position('madrasah_threads' in (select pg_get_functiondef(p.oid) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                                      where n.nspname = 'public' and p.proname = 'settle_sibling_suggestion')) = 0 then
    raise exception 'PROOF FAILED: the proof left the UNPATCHED merge function in place (the DDL was not rolled back)';
  end if;
end $proof$;
