--  =====================================================================
--  132 - THE IMAM HAS HIS OWN INBOX
--  2 October 2026
--  =====================================================================
--
--  THE MASJID ASKED FOR: a form on the Imams' Advice screen of the app so
--  somebody can put a question to the imams, "private and confidential to
--  the imam", and the imam answers directly.
--
--  The first design was a mailbox, imam@... . It was dropped on purpose.
--  A shared mailbox is read by whoever holds the password, forwards by
--  accident, and leaves the masjid with no record that an answer was ever
--  given. So the question lands HERE, in the portal, behind a role.
--
--  DEPENDS ON db/131, which adds the `imam` label to app_role. Apply that
--  first; this file uses the label and Postgres will not allow both in one
--  transaction.
--
--  ---------------------------------------------------------------------
--  verified_imam() IS THE ONLY GATE IN THIS SYSTEM THAT EXCLUDES `admin`.
--  ---------------------------------------------------------------------
--  Every other gate here reads `is_aal2() and (is_admin() or has_role(...))`.
--  This one does not, and that is the whole point of the feature rather than
--  an oversight:
--
--      select public.is_aal2() and public.has_role(auth.uid(), 'imam')
--
--  "Confidential to the imam" has to mean something, and if the role that
--  means "everything" also means this, it means nothing. So an administrator
--  opening the portal sees no row for this inbox and every function below
--  refuses them.
--
--  WHAT THAT DOES AND DOES NOT BUY, said plainly so nobody oversells it to
--  a person in distress:
--    * It DOES keep these questions off the office's screens, out of the
--      administrators' reach, and out of every list the committee reads.
--    * An administrator CANNOT give themselves this role: set_person_roles()
--      refuses `p_user = auth.uid()`. Another administrator granting it to
--      them writes a `roles_changed` audit row naming both of them. That is
--      the control - accountability, not impossibility.
--    * It does NOT defend against whoever holds the database's secret key,
--      because nothing in Postgres can. The app's form therefore says "read
--      by the imam", which is true, and does not say "nobody else can ever
--      see this", which would not be.
--
--  ---------------------------------------------------------------------
--  TWO TABLES, REACHED ONLY THROUGH FUNCTIONS
--  ---------------------------------------------------------------------
--    advice_requests   one row per question. Holds the person's name, phone
--                      and email, because the masjid asked for all three and
--                      because the answer has to reach them somehow.
--    advice_answers    what the imam wrote back. ON DELETE CASCADE.
--
--  RLS is on, there is NO policy, and every grant is revoked, so neither
--  table is reachable through the API at all. Every function is SECURITY
--  DEFINER with search_path = public, pg_temp, and each revoke/grant is
--  restated per function on purpose - Supabase's default privileges grant
--  EXECUTE to anon directly, so "revoke from public" alone leaves the door
--  open. The proof at the foot of this file reads both tables as anon and as
--  authenticated and expects to be refused.
--
--  ---------------------------------------------------------------------
--  THERE ARE NO CHECK CONSTRAINTS ON THE FREE TEXT, AND THAT IS DELIBERATE
--  ---------------------------------------------------------------------
--  db/125 put a length CHECK on a message body as a backstop. This table
--  does not, because of what a failing CHECK does: Postgres prints the WHOLE
--  FAILING ROW into the error DETAIL, and with `log_min_error_statement =
--  error` that DETAIL reaches the Supabase-retained server log. This
--  repository has been burned by exactly that twice (see CLAUDE.md on
--  madrasah_pupils). A constraint on this table would mean a malformed
--  question ends up written in plaintext in a log the imam cannot delete -
--  which is the one thing this feature exists to prevent.
--
--  So the bounds live in request_imam_advice() and imam_advice_answer(),
--  which validate BEFORE the insert, and the backstop is that nothing else
--  can insert at all. That is only acceptable because the grants above make
--  it true, so the proof checks it rather than asserting it.
--
--  ---------------------------------------------------------------------
--  THE RULES THE FUNCTIONS ENFORCE
--  ---------------------------------------------------------------------
--    * NAME, PHONE AND EMAIL ARE ALL REQUIRED. The masjid asked for all
--      three. The email is how the answer arrives; the phone is so the imam
--      can ring somebody who sounds like they should be rung rather than
--      emailed.
--    * NOBODY HOLDING THE ROLE MEANS THE FORM IS SHUT. advice_is_open()
--      is false and request_imam_advice() refuses, in a sentence the person
--      can act on ("please ring the office"). A form that accepts a
--      confidence nobody will ever read is worse than no form, and this is
--      the only guard that prevents it.
--    * THE LIST DOES NOT NAME THE PERSON. imam_advice_list() returns the
--      reference, the subject and the state. The name, phone, email and the
--      question itself are on the record, behind imam_advice_read(). Same
--      rule as everywhere else here - the list says WHETHER, the record says
--      WHAT - and it matters more on this screen than on any other.
--    * EVERY READ OF A RECORD WRITES AN admin_audit ROW (db/089). The row
--      names the request id and nothing else: not the subject, not the
--      person, not a word of what they wrote.
--    * WAITING MEANS state = 'open'. Answered and closed are not waiting.
--      imam_advice_waiting_count() is the count-only function the portal's
--      front page uses, so the badge and the list cannot disagree.
--    * A REFUSAL IS {"allowed": false} AND NEVER AN EMPTY LIST, for the
--      reason db/104 established: an empty list says "that does not exist",
--      which is a more useful answer to somebody fishing.
--    * Bounds, so the form cannot be used to fill the database: subject
--      1-120 characters, question 1-4000, answer 1-4000, at most three
--      questions per phone or email per day (rate_limit_by_contact).
--
--  ---------------------------------------------------------------------
--  HOW ANYBODY FINDS OUT THERE IS A QUESTION WAITING
--  ---------------------------------------------------------------------
--  There is no imam@ mailbox, so something has to tell him. Two things do,
--  and NEITHER of them carries a word of the question:
--
--    1. ON ARRIVAL. notify_the_imam() posts {kind:'advice_requested'} - the
--       request's id and nothing else - and the notify function looks the
--       recipients up for itself with advice_alert_addresses(). The email
--       says a question is waiting and to sign in. It does not say who from
--       or what about, and the recipient is never supplied by the caller,
--       so notify keeps the fence its staff_invite branch describes.
--    2. IF IT IS LEFT. advice_chase() runs daily. If anything has been open
--       more than seven days it posts {kind:'advice_waiting', count:N} and
--       the OFFICE is told the NUMBER - not the names, not the subjects, not
--       the content. The office cannot read these questions and still cannot
--       after this email. All it learns is that somebody is waiting, which
--       is the one thing it has to know to go and ask the imam.
--
--  The second exists because of the obvious failure of the first: an imam
--  who does not check email, or whose role is removed, leaves somebody in
--  distress unanswered with nothing anywhere saying so.
--
--  ---------------------------------------------------------------------
--  ORDER OF DEPLOYMENT, AND WHY THIS FILE IS SAFE TO APPLY FIRST
--  ---------------------------------------------------------------------
--  db/108's rule is that the renderer goes out before the database, because a
--  new database with an old renderer sends the wrong email. Here the rule is
--  satisfied by the ROLE rather than by the clock, and that is worth reading
--  before anybody reorders it:
--
--    * NOTHING CAN FLOW THROUGH THIS FILE UNTIL A HUMAN GRANTS THE ROLE.
--      advice_is_open() is false while nobody holds `imam`, and
--      request_imam_advice() refuses while it is false. So between applying
--      this file and the first grant, not one row can exist and not one email
--      can be posted. The app asks advice_is_open() and does not even draw
--      the form.
--    * AND AN OLD RENDERER SENDS NOTHING RATHER THAN SOMETHING WRONG. Both
--      officeMessage() and publicMessage() fall through to `return null` on a
--      kind they do not know, so a notify that has not learned
--      `advice_requested` answers "nothing to send for this". That was read
--      in the deployed source, not assumed.
--
--  THE ORDER IS THEREFORE: apply db/131, apply this file, deploy notify, and
--  THEN grant somebody the imam role in access/. The grant is what opens the
--  form, so doing it last is what makes the order safe.
--
--  The one thing that must not be done out of order is granting the role
--  before notify is deployed: a question could arrive, be saved correctly,
--  and nobody be told it had. advice_chase() would notice within the week,
--  which is a backstop and not a plan.
--
--  RETENTION: purge_old_imam_advice(12) daily, by last activity. Twelve
--  months matches every other public form here. An unanswered question is
--  purged too: keeping it forever does not get it answered, and advice_chase
--  is what notices it long before a year is up.
--
--  NOTHING IN THE PROOF PRINTS A PERSON. Every check is a count, a boolean,
--  a sqlstate or a sentence written in this file. Every name is invented.
--
--  HOW IT WAS APPLIED, because the migration list does not read like this
--  file. Supabase's apply_migration kept timing out on bodies of a few
--  kilobytes, so this file went up in pieces and the recorded versions are
--  131, then 132a..132e, then the rest through the SQL path, which records no
--  version at all. THE FILE IS THE RECORD - that is already this repository's
--  rule - and the structural check at the foot is how to confirm a database
--  has all of it rather than counting rows in supabase_migrations.
--
--  TO REMOVE: drop table public.advice_answers, public.advice_requests;
--  drop the functions listed at the foot; unschedule 'purge-imam-advice'
--  and 'chase-imam-advice'; drop sequence public.advice_reference_seq.
--  =====================================================================

--  ---------------------------------------------------------------------
--  1. THE GATE
--  ---------------------------------------------------------------------
create or replace function public.verified_imam()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  --  NO is_admin(). See the long note at the head of this file: that
  --  omission is the feature. If you are here to "fix" it by adding the
  --  usual or-is-admin clause, read that note first.
  select public.is_aal2()
     and public.has_role(auth.uid(), 'imam'::public.app_role);
$$;
revoke all on function public.verified_imam() from public, anon, authenticated;
grant execute on function public.verified_imam() to authenticated;
comment on function public.verified_imam() is
  'True for a signed-in imam who has completed the second step. Deliberately NOT true for an administrator - this is the only gate in the schema that excludes admin, and that is what makes the advice inbox confidential.';

--  ---------------------------------------------------------------------
--  2. THE TABLES
--  ---------------------------------------------------------------------
create sequence if not exists public.advice_reference_seq;

create table if not exists public.advice_requests (
  id                uuid primary key default gen_random_uuid(),
  masjid_id         uuid not null references public.masjids(id) on delete cascade,
  reference         text not null,
  --  All three required. The masjid asked for all three.
  person_name       text not null,
  person_phone      text not null,
  person_email      text not null,
  subject           text not null,
  body              text not null,
  state             text not null default 'open',
  submitted_at      timestamptz not null default now(),
  last_activity_at  timestamptz not null default now(),
  unread_for_imam   boolean not null default true,
  --  When the imam first opened it. Not decoration: it is the only way to
  --  answer "how long did this person wait before anybody looked", which is
  --  the question the masjid will eventually ask about this feature.
  first_read_at     timestamptz,
  answered_at       timestamptz
  --  NO CHECK CONSTRAINTS. See the head of this file: a failing CHECK prints
  --  the whole row - the person's question - into the retained server log.
);

create table if not exists public.advice_answers (
  id          uuid primary key default gen_random_uuid(),
  request_id  uuid not null references public.advice_requests(id) on delete cascade,
  body        text not null,
  --  Who wrote it, as an id only, and no foreign key: removing a login must
  --  neither block nor rewrite what was said. Same decision as db/125.
  author_user uuid,
  --  clock_timestamp(), not now(): two answers written in one transaction
  --  would otherwise share a timestamp and read back in either order.
  created_at  timestamptz not null default clock_timestamp()
);

create unique index if not exists advice_requests_reference_idx
  on public.advice_requests (masjid_id, reference);
create index if not exists advice_requests_state_idx
  on public.advice_requests (masjid_id, state, last_activity_at);
create index if not exists advice_requests_contact_idx
  on public.advice_requests (masjid_id, submitted_at);
create index if not exists advice_answers_request_idx
  on public.advice_answers (request_id, created_at);

alter table public.advice_requests enable row level security;
alter table public.advice_answers  enable row level security;
revoke all on table public.advice_requests from public, anon, authenticated;
revoke all on table public.advice_answers  from public, anon, authenticated;
revoke all on sequence public.advice_reference_seq from public, anon, authenticated;

comment on table public.advice_requests is
  'A question put to the imams from the app, in confidence. RLS on, no policy, no grants: reached only through the functions in db/132, and only by verified_imam() - not by an administrator. No CHECK constraints on the free text on purpose, because a failing CHECK would print the question into the server log.';
comment on table public.advice_answers is
  'What the imam wrote back. Deleted with the request. Bodies are validated in imam_advice_answer() before the insert, for the same logging reason.';

--  ---------------------------------------------------------------------
--  3. IS THE FORM OPEN?
--     False when nobody holds the role, because then nobody would ever read
--     what was sent. The app asks this before it draws the form, and
--     request_imam_advice() asks it again - the screen deciding is a
--     courtesy, the function deciding is the rule.
--  ---------------------------------------------------------------------
create or replace function public.advice_is_open(p_masjid text default null)
returns boolean language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid;
begin
  v_masjid := public.masjid_or_sole(p_masjid);
  if v_masjid is null then return false; end if;
  return exists (
    select 1
      from public.user_roles r
      join public.profiles  p on p.id = r.user_id
     where r.masjid_id = v_masjid
       and r.role = 'imam'::public.app_role
       and p.is_active
       and coalesce(btrim(p.email), '') <> '');
end $$;
revoke all on function public.advice_is_open(text) from public, anon, authenticated;
grant execute on function public.advice_is_open(text) to anon, authenticated;
comment on function public.advice_is_open(text) is
  'Whether written questions to the imams are being taken - true only while somebody active holds the imam role. Reveals no names and no addresses, only the yes or no.';

--  ---------------------------------------------------------------------
--  4. SENDING ONE
--  ---------------------------------------------------------------------
create or replace function public.request_imam_advice(payload jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid  uuid;
  v_name    text := btrim(coalesce(payload ->> 'name', ''));
  v_phone   text := btrim(coalesce(payload ->> 'phone', ''));
  v_email   text := lower(btrim(coalesce(payload ->> 'email', '')));
  v_subject text := btrim(coalesce(payload ->> 'subject', ''));
  v_body    text := btrim(coalesce(payload ->> 'question', ''));
  v_ref     text;
  v_id      uuid;
begin
  v_masjid := public.masjid_or_sole(payload ->> 'masjid');

  --  THE SHUT CASE FIRST, before anything is validated, so that somebody
  --  filling this in for five minutes is not told their postcode is wrong
  --  about a form that was never going to accept it.
  if not public.advice_is_open(payload ->> 'masjid') then
    raise exception
      'The masjid cannot take written questions for the imams at the moment. '
      'Please ring the office on 01204 535 997 and somebody will arrange a time to speak.'
      using errcode = 'check_violation';
  end if;

  if v_name = ''  then raise exception 'Please give your name so the imam knows who he is answering'; end if;
  if v_phone = '' then raise exception 'Please give a phone number, in case the imam needs to ring you'; end if;
  if v_email = '' then raise exception 'Please give an email address - that is where the imam''s answer is sent'; end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$' then
    raise exception 'That does not look like an email address. Please check it - the answer is sent there';
  end if;
  if length(v_name)  > 120 then raise exception 'Please give a shorter name'; end if;
  if length(v_phone) > 40  then raise exception 'Please check that phone number'; end if;
  if length(v_email) > 254 then raise exception 'Please check that email address'; end if;
  if v_subject = '' then raise exception 'Please say in a few words what your question is about'; end if;
  if length(v_subject) > 120 then
    raise exception 'Please keep "what it is about" to a short line - the question itself goes in the box below';
  end if;
  if v_body = '' then raise exception 'Please write your question'; end if;
  if length(v_body) > 4000 then
    raise exception 'That is longer than this form can take. Please shorten it, or ring the office and ask to speak to an imam.';
  end if;

  v_ref := 'IA-' || to_char(now(), 'YY') || '-' ||
           lpad(nextval('public.advice_reference_seq')::text, 4, '0');

  insert into public.advice_requests
    (masjid_id, reference, person_name, person_phone, person_email, subject, body)
  values
    (v_masjid, v_ref, v_name, v_phone, v_email, v_subject, v_body)
  returning id into v_id;

  --  THE AUDIT ROW CARRIES THE REFERENCE AND NOTHING ELSE. Not the subject,
  --  not the name, not the address. admin_audit is read by administrators,
  --  who are the people this inbox is confidential from.
  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'imam_advice_received',
          jsonb_build_object('reference', v_ref));

  return jsonb_build_object('reference', v_ref);
end $$;
revoke all on function public.request_imam_advice(jsonb) from public, anon, authenticated;
grant execute on function public.request_imam_advice(jsonb) to anon, authenticated;
comment on function public.request_imam_advice(jsonb) is
  'The app''s Imams'' Advice form. Validates everything before the insert so that no CHECK can print a question into the server log, and refuses outright when nobody holds the imam role.';

--  ---------------------------------------------------------------------
--  5. TELLING SOMEBODY IT ARRIVED
--     The payload carries the id and NOTHING ELSE - no subject, no name, no
--     question. notify looks the recipients up for itself (section 6), so
--     the address is never supplied by whoever called this.
--  ---------------------------------------------------------------------
create or replace function public.notify_the_imam()
returns trigger language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_url text; v_key text; v_secret text;
begin
  select value into v_url    from public.app_settings
   where masjid_id = new.masjid_id and key = 'notify_url';
  select value into v_key    from public.app_settings
   where masjid_id = new.masjid_id and key = 'notify_key';
  select value into v_secret from public.app_settings
   where masjid_id = new.masjid_id and key = 'notify_secret';

  if v_url is null or v_key is null or v_secret is null then
    insert into public.admin_audit (masjid_id, action, detail)
    values (new.masjid_id, 'notify_not_configured',
            jsonb_build_object('table', TG_TABLE_NAME, 'missing',
              case when v_url is null then 'notify_url'
                   when v_key is null then 'notify_key'
                   else 'notify_secret' end));
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    body    := jsonb_build_object('kind', 'advice_requested',
                                  'request_id', new.id,
                                  'masjid_id', new.masjid_id),
    headers := jsonb_build_object(
                 'Content-type',    'application/json',
                 'Authorization',   'Bearer ' || v_key,
                 'x-notify-secret', v_secret));
  return new;
end $$;
comment on function public.notify_the_imam() is
  'Posts the id of a new advice request to the notify function. Deliberately NOT to_jsonb(new) like notify_the_office(): the row holds somebody''s confidential question and it has no business sitting in pg_net''s queue.';

drop trigger if exists advice_requests_rate_limit_trg on public.advice_requests;
create trigger advice_requests_rate_limit_trg
  before insert on public.advice_requests
  for each row execute function public.rate_limit_by_contact(
    'person_phone', 'person_email', 'submitted_at', '3');

drop trigger if exists notify_the_imam_trg on public.advice_requests;
create trigger notify_the_imam_trg
  after insert on public.advice_requests
  for each row execute function public.notify_the_imam();

--  ---------------------------------------------------------------------
--  6. WHAT notify IS ALLOWED TO ASK
--     service_role only. Both functions exist so that the RECIPIENT and the
--     CONTENT of every email come out of the database rather than out of the
--     request - the fence notify's staff_invite branch describes at length.
--  ---------------------------------------------------------------------
create or replace function public.advice_alert_addresses(p_masjid uuid)
returns text[] language sql stable security definer
set search_path = public, pg_temp as $$
  select coalesce(array_agg(distinct lower(btrim(p.email))), '{}'::text[])
    from public.user_roles r
    join public.profiles  p on p.id = r.user_id
   where r.masjid_id = p_masjid
     and r.role = 'imam'::public.app_role
     and p.is_active
     and coalesce(btrim(p.email), '') <> '';
$$;
revoke all on function public.advice_alert_addresses(uuid) from public, anon, authenticated;
grant execute on function public.advice_alert_addresses(uuid) to service_role;

create or replace function public.advice_for_notify(p_request uuid)
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object(
           'reference', r.reference,
           'masjid_id', r.masjid_id,
           'name',      r.person_name,
           'email',     r.person_email,
           'subject',   r.subject,
           --  The LATEST answer only. The email says what the imam has just
           --  written; the whole conversation is not re-sent.
           'answer',   (select a.body from public.advice_answers a
                         where a.request_id = r.id
                      order by a.created_at desc limit 1))
    from public.advice_requests r
   where r.id = p_request;
$$;
revoke all on function public.advice_for_notify(uuid) from public, anon, authenticated;
grant execute on function public.advice_for_notify(uuid) to service_role;
comment on function public.advice_for_notify(uuid) is
  'Everything the notify function needs to email the imam''s answer to the person who asked: the address and the words, both read from the database rather than taken from the request.';

--  ---------------------------------------------------------------------
--  7. THE IMAM'S FUNCTIONS
--  ---------------------------------------------------------------------

--  THE LIST SAYS WHETHER. No name, no phone, no email, no question - the
--  subject, the reference and the state. A screen that sits open on a desk
--  should not name the people who wrote in confidence.
create or replace function public.imam_advice_list()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid;
begin
  if not public.verified_imam() then
    return jsonb_build_object('allowed', false);
  end if;
  v_masjid := public.current_masjid();
  return jsonb_build_object(
    'allowed', true,
    'waiting', (select count(*) from public.advice_requests
                 where masjid_id = v_masjid and state = 'open'),
    'unread',  (select count(*) from public.advice_requests
                 where masjid_id = v_masjid and unread_for_imam),
    'requests', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'reference', r.reference, 'subject', r.subject,
               'state', r.state, 'submitted_at', r.submitted_at,
               'last_activity_at', r.last_activity_at,
               'unread', r.unread_for_imam,
               'answers', (select count(*) from public.advice_answers a
                            where a.request_id = r.id))
             order by (r.state = 'open') desc, r.last_activity_at desc, r.id)
        from public.advice_requests r
       where r.masjid_id = v_masjid), '[]'::jsonb));
end $$;
revoke all on function public.imam_advice_list() from public, anon, authenticated;
grant execute on function public.imam_advice_list() to authenticated;

--  THE COUNT-ONLY SIBLING (db/115's rule). Called by anything that wants a
--  badge, so a number on a dashboard can never be a reason to fetch a list.
create or replace function public.imam_advice_waiting_count()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
begin
  if not public.verified_imam() then
    return jsonb_build_object('allowed', false);
  end if;
  return jsonb_build_object('allowed', true,
    'waiting', (select count(*) from public.advice_requests
                 where masjid_id = public.current_masjid() and state = 'open'),
    'unread',  (select count(*) from public.advice_requests
                 where masjid_id = public.current_masjid() and unread_for_imam));
end $$;
revoke all on function public.imam_advice_waiting_count() from public, anon, authenticated;
grant execute on function public.imam_advice_waiting_count() to authenticated;

--  THE RECORD SAYS WHAT. Not stable: it marks the thing read and stamps the
--  first read, and it writes the audit row that says somebody looked.
create or replace function public.imam_advice_read(p_request uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid; v_r public.advice_requests%rowtype;
begin
  if not public.verified_imam() then
    return jsonb_build_object('allowed', false);
  end if;
  v_masjid := public.current_masjid();

  select * into v_r from public.advice_requests
   where id = p_request and masjid_id = v_masjid;
  if v_r.id is null then
    --  A request that is not there, one belonging to another masjid, and
    --  NULL all get this same answer. See db/104.
    return jsonb_build_object('allowed', false);
  end if;

  update public.advice_requests
     set unread_for_imam = false,
         first_read_at   = coalesce(first_read_at, now())
   where id = v_r.id;

  --  THE AUDIT ROW NAMES THE REQUEST AND NOTHING ELSE. admin_audit is an
  --  administrator's screen, and an administrator may not read this inbox.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'imam_advice_read',
          jsonb_build_object('request', v_r.id, 'reference', v_r.reference));

  return jsonb_build_object(
    'allowed', true,
    'id', v_r.id, 'reference', v_r.reference,
    'name', v_r.person_name, 'phone', v_r.person_phone, 'email', v_r.person_email,
    'subject', v_r.subject, 'question', v_r.body,
    'state', v_r.state, 'submitted_at', v_r.submitted_at,
    'answered_at', v_r.answered_at,
    'answers', coalesce((
      select jsonb_agg(jsonb_build_object('id', a.id, 'body', a.body,
                                          'created_at', a.created_at)
             order by a.created_at, a.id)
        from public.advice_answers a where a.request_id = v_r.id), '[]'::jsonb));
end $$;
revoke all on function public.imam_advice_read(uuid) from public, anon, authenticated;
grant execute on function public.imam_advice_read(uuid) to authenticated;

--  ANSWERING. The words are validated here, before the insert, for the
--  logging reason at the head of this file.
create or replace function public.imam_advice_answer(p_request uuid, p_body text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid; v_r public.advice_requests%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
  v_url text; v_key text; v_secret text;
begin
  if not public.verified_imam() then
    return jsonb_build_object('allowed', false);
  end if;
  v_masjid := public.current_masjid();

  select * into v_r from public.advice_requests
   where id = p_request and masjid_id = v_masjid;
  if v_r.id is null then
    return jsonb_build_object('allowed', false);
  end if;

  if v_body = '' then
    raise exception 'There is nothing to send - please write your answer first'
      using errcode = '22023';
  end if;
  if length(v_body) > 4000 then
    raise exception 'That answer is longer than an email should be. Please shorten it, or ring them on the number on this page.'
      using errcode = '22023';
  end if;

  insert into public.advice_answers (request_id, body, author_user)
  values (v_r.id, v_body, auth.uid());

  update public.advice_requests
     set state            = 'answered',
         answered_at      = coalesce(answered_at, now()),
         last_activity_at = now(),
         unread_for_imam  = false
   where id = v_r.id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'imam_advice_answered',
          jsonb_build_object('request', v_r.id, 'reference', v_r.reference));

  --  POST THE ID, NOT THE ANSWER. notify reads the words and the address
  --  back out of the database with advice_for_notify(), so neither travels
  --  through pg_net's queue.
  select value into v_url    from public.app_settings where masjid_id = v_masjid and key = 'notify_url';
  select value into v_key    from public.app_settings where masjid_id = v_masjid and key = 'notify_key';
  select value into v_secret from public.app_settings where masjid_id = v_masjid and key = 'notify_secret';

  if v_url is null or v_key is null or v_secret is null then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'notify_not_configured',
            jsonb_build_object('table', 'advice_answers', 'missing',
              case when v_url is null then 'notify_url'
                   when v_key is null then 'notify_key'
                   else 'notify_secret' end));
    --  The answer IS saved. Say so rather than pretending it was sent: the
    --  imam needs to know to ring them instead.
    return jsonb_build_object('allowed', true, 'saved', true, 'emailed', false,
      'note', 'Your answer is saved, but email is not set up, so it has not been sent. Please ring them.');
  end if;

  perform net.http_post(
    url     := v_url,
    body    := jsonb_build_object('kind', 'advice_answered',
                                  'request_id', v_r.id,
                                  'masjid_id', v_masjid),
    headers := jsonb_build_object(
                 'Content-type',    'application/json',
                 'Authorization',   'Bearer ' || v_key,
                 'x-notify-secret', v_secret));

  --  `emailed` means HANDED OVER, not delivered. The distinction is in
  --  CLAUDE.md and the screen repeats it in words.
  return jsonb_build_object('allowed', true, 'saved', true, 'emailed', true);
end $$;
revoke all on function public.imam_advice_answer(uuid, text) from public, anon, authenticated;
grant execute on function public.imam_advice_answer(uuid, text) to authenticated;

--  CLOSING. The imam's decision, and it is reversible only by answering
--  again - which reopens it as answered.
create or replace function public.imam_advice_close(p_request uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid; v_r public.advice_requests%rowtype;
begin
  if not public.verified_imam() then
    return jsonb_build_object('allowed', false);
  end if;
  v_masjid := public.current_masjid();
  select * into v_r from public.advice_requests
   where id = p_request and masjid_id = v_masjid;
  if v_r.id is null then
    return jsonb_build_object('allowed', false);
  end if;

  update public.advice_requests
     set state = 'closed', last_activity_at = now(), unread_for_imam = false
   where id = v_r.id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'imam_advice_closed',
          jsonb_build_object('request', v_r.id, 'reference', v_r.reference));
  return jsonb_build_object('allowed', true, 'state', 'closed');
end $$;
revoke all on function public.imam_advice_close(uuid) from public, anon, authenticated;
grant execute on function public.imam_advice_close(uuid) to authenticated;

--  ---------------------------------------------------------------------
--  8. NOTICING THAT NOBODY ANSWERED
--     A COUNT TO THE OFFICE, AND NOTHING ELSE. The office may not read
--     these questions and still may not after this email. All it is told is
--     that N have been waiting more than seven days, which is the one thing
--     it needs in order to go and ask the imam.
--  ---------------------------------------------------------------------
create or replace function public.advice_chase(p_days integer default 7)
returns integer language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_m uuid; v_n int; v_total int := 0;
  v_url text; v_key text; v_secret text;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may run this.'
      using errcode = '42501';
  end if;

  for v_m in select * from public.masjids_to_purge() loop
    select count(*) into v_n from public.advice_requests
     where masjid_id = v_m and state = 'open'
       and submitted_at < now() - make_interval(days => p_days);
    if v_n = 0 then continue; end if;
    v_total := v_total + v_n;

    select value into v_url    from public.app_settings where masjid_id = v_m and key = 'notify_url';
    select value into v_key    from public.app_settings where masjid_id = v_m and key = 'notify_key';
    select value into v_secret from public.app_settings where masjid_id = v_m and key = 'notify_secret';
    if v_url is null or v_key is null or v_secret is null then
      insert into public.admin_audit (masjid_id, action, detail)
      values (v_m, 'advice_waiting_unsent',
              jsonb_build_object('count', v_n, 'days', p_days));
      continue;
    end if;

    perform net.http_post(
      url     := v_url,
      body    := jsonb_build_object('kind', 'advice_waiting',
                                    'waiting_count', v_n,
                                    'waiting_days', p_days,
                                    'masjid_id', v_m),
      headers := jsonb_build_object(
                   'Content-type',    'application/json',
                   'Authorization',   'Bearer ' || v_key,
                   'x-notify-secret', v_secret));

    insert into public.admin_audit (masjid_id, action, detail)
    values (v_m, 'advice_waiting_chased',
            jsonb_build_object('count', v_n, 'days', p_days));
  end loop;
  return v_total;
end $$;
revoke all on function public.advice_chase(integer) from public, anon, authenticated;
comment on function public.advice_chase(integer) is
  'Daily. Emails the office the NUMBER of advice requests left open more than p_days - never a name, a subject or a word of the question. Exists because a confidential inbox nobody is told about leaves somebody unanswered with nothing anywhere saying so.';

--  ---------------------------------------------------------------------
--  9. RETENTION
--  ---------------------------------------------------------------------
create or replace function public.purge_old_imam_advice(
  retain_months integer, dry_run boolean default false)
returns integer language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_m uuid; v_cutoff timestamptz; v_n int; v_total int := 0;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may purge the advice inbox.'
      using errcode = '42501';
  end if;
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be a positive number of months';
  end if;

  v_cutoff := now() - make_interval(months => retain_months);

  for v_m in select * from public.masjids_to_purge() loop
    if dry_run then
      select count(*) into v_n from public.advice_requests
       where masjid_id = v_m and last_activity_at < v_cutoff;
      v_total := v_total + v_n;
      continue;
    end if;

    --  The answers go with the request, by the cascade. Proved below.
    with gone as (
      delete from public.advice_requests
       where masjid_id = v_m and last_activity_at < v_cutoff
      returning 1
    )
    select count(*) into v_n from gone;

    insert into public.admin_audit (masjid_id, action, detail)
    values (v_m, 'imam_advice_purged',
            jsonb_build_object('deleted', v_n, 'retain_months', retain_months,
                               'cutoff', v_cutoff));
    v_total := v_total + v_n;
  end loop;
  return v_total;
end $$;
revoke all on function public.purge_old_imam_advice(integer, boolean) from public, anon, authenticated;

select cron.unschedule('purge-imam-advice')
 where exists (select 1 from cron.job where jobname = 'purge-imam-advice');
select cron.schedule('purge-imam-advice', '0 4 * * *',
                     'select public.purge_old_imam_advice(12)');

select cron.unschedule('chase-imam-advice')
 where exists (select 1 from cron.job where jobname = 'chase-imam-advice');
select cron.schedule('chase-imam-advice', '10 8 * * *',
                     'select public.advice_chase(7)');

--  =====================================================================
--  THE PROOF
--  =====================================================================
--  RUN AGAINST PRODUCTION ON 2 OCTOBER 2026, AND IT LEFT NOTHING BEHIND.
--
--  Each block below ends in `raise exception`, which ABORTS the whole block
--  and so rolls back everything it did - two throwaway accounts, the
--  questions, the answers, the audit rows and the pg_net queue entries - while
--  still printing its results, because they travel in the error message. That
--  is the only safe way to prove a confidential inbox on a live database: the
--  alternative is leaving test rows in it, and this one holds real people's
--  private questions.
--
--  Nothing here is a real person. Zahra Example and Bilal Example are invented
--  and so are both throwaway accounts. The question text is the literal string
--  'SECRETWORD ...' precisely so that the leak checks have something
--  unmistakable to look for.
--
--  ONE RESIDUE, AND IT IS HARMLESS: a sequence does not roll back, so
--  advice_reference_seq stands at 11 after this. The first real question will
--  be IA-26-0012. If somebody later wonders where IA-26-0001..0011 went, this
--  is where.
--
--  THE ONE CHECK THAT MAKES THE REST MEAN ANYTHING is 4a. Every other line in
--  block 1 says "the administrator was refused" - which would also be true if
--  the session were broken, or signed in as nobody, or missing its second
--  step. 4a asserts verified_admin() is TRUE for that same session. So it is a
--  real, two-step administrator of this masjid, and it is still refused.
--
--  RESULTS, as printed:
--
--    BLOCK 1 - the form is shut, somebody writes in, an administrator is refused
--      1a advice_is_open with no imam                        false   want f
--      1b refused, in words the person can act on            true    want t
--      2a advice_is_open once somebody holds it              true    want t
--      3a reference shaped IA-YY-NNNN                        true    want t
--      3b one row, open, unread                              true    want t
--      3c arrival audit row carries ONLY the reference       true    want t
--      4a the session really IS a verified admin             true    want t
--      4b verified_imam for that admin                       false   want f
--      4c imam_advice_list refused                           true    want t
--      4d imam_advice_read refused                           true    want t
--      4e imam_advice_answer refused                         true    want t
--      4f and it wrote nothing                               true    want t
--
--    BLOCK 2 - the imam reads and answers
--      5a the imam at aal1 is refused                        true    want t
--      6a allowed, 1 waiting, 1 unread                       true    want t
--      6b the list names NOBODY and quotes NOTHING           true    want t
--      6c the subject IS there, which is the point           true    want t
--      6d the count-only sibling agrees                      true    want t
--      7a the record carries all of it                       true    want t
--      7b no longer unread, first_read_at stamped            true    want t
--      7c the read audit row names nothing but the request   true    want t
--      8a a request that does not exist                      true    want t
--      9a an empty answer is refused (22023)                 true    want t
--      9b saved and handed to the mail path                  true    want t
--      9c one answer row, state answered                     true    want t
--      9d no longer waiting                                  true    want t
--      9e the answered audit row names nothing but the req   true    want t
--
--    BLOCK 3 - what leaves the database, and what is kept
--      10a notify gets the address, the words, the reference true    want t
--      10b notify is never handed the question               true    want t
--      10c the imam's own address is found                   true    want t
--      10d a suspended imam is not alerted, and shuts form   true    want t
--      11a two posts queued, arrival and answer              true    want t
--      11b nothing queued carries the question or person     true    want t
--      11c what IS queued, in full:
--            {"kind":"advice_requested","masjid_id":"<id>","request_id":"<id>"}
--            {"kind":"advice_answered", "masjid_id":"<id>","request_id":"<id>"}
--      12a the answer went with the request (cascade)        true    want t
--      13a the fourth question in a day is refused (23514)   true    want t
--      13b a different contact is not caught by it           true    want t
--      14a dry-run purge finds nothing a year old (0)        true    want t
--      14b the chase finds nothing a week old (0)            true    want t
--
--  A BUG THIS PROOF FOUND IN ITSELF, worth keeping because the next person
--  will write the same line: check 11b was first written as
--  `body::text not like '%SECRETWORD%'`. net.http_request_queue.body is
--  BYTEA, so `::text` renders it as a hex string - \x7b226b696e64... - and the
--  check passed on every input, including a body that did contain the
--  question. It is `convert_from(body,'utf8')` above, and 11c prints the
--  decoded JSON so that a future reader can see the check is reading words
--  rather than hex. A check that cannot fail is not a check.
--
--  WHAT THIS PROOF DOES NOT COVER, said plainly:
--    * It sets request.jwt.claims directly rather than signing in, so it
--      exercises the FUNCTION gates and not PostgREST or RLS. The grants are
--      checked separately and structurally: anon, authenticated and PUBLIC
--      hold zero privileges on either table, RLS is on, and there are no
--      policies - so there is no path to the rows except these functions.
--    * No email was sent. 9b asserts the post was HANDED to pg_net, which
--      11a and 11c confirm by reading the queue. Accepted is not delivered;
--      the notify function's own suite (messages_test.ts, 108 cases, 12 of
--      them added for this feature) covers what the three emails say.
--  =====================================================================

/*  BLOCK 1 - the form is shut, somebody writes in, an administrator is refused.
    Paste and run. It rolls itself back. */
do $$
declare
  IMAM  uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  ADMIN uuid := 'aaaaaaaa-0000-4000-8000-000000000002';
  v_m uuid; r jsonb; v_id uuid; v_ref text; out text := E'\n';
begin
  v_m := public.sole_masjid();

  out := out || '1a advice_is_open with no imam = ' || public.advice_is_open(null) || '  want f' || E'\n';
  begin
    perform public.request_imam_advice(jsonb_build_object(
      'name','Zahra Example','phone','07700 900333','email','zahra@example.test',
      'subject','A question about a will','question','SECRETWORD keep this private'));
    out := out || '1b FAIL - took a question nobody would read' || E'\n';
  exception when others then
    out := out || '1b refused, in words the person can act on = ' ||
      (position('cannot take written questions' in sqlerrm) > 0) || '  want t' || E'\n';
  end;

  insert into auth.users (id, email) values
    (IMAM,'imam.throwaway@example.test'), (ADMIN,'admin.throwaway@example.test');
  insert into public.profiles (id, full_name, email, is_active) values
    (IMAM,'Throwaway Imam','imam.throwaway@example.test',true),
    (ADMIN,'Throwaway Admin','admin.throwaway@example.test',true)
  on conflict (id) do update set is_active=true, email=excluded.email;
  insert into public.user_roles (user_id, masjid_id, role) values
    (IMAM,v_m,'imam'), (ADMIN,v_m,'admin');
  out := out || '2a advice_is_open once somebody holds it = ' || public.advice_is_open(null) || '  want t' || E'\n';

  perform set_config('request.jwt.claims','',true);
  r := public.request_imam_advice(jsonb_build_object(
         'name','Zahra Example','phone','07700 900333','email','zahra@example.test',
         'subject','A question about a will','question','SECRETWORD keep this private'));
  v_ref := r ->> 'reference';
  select id into v_id from public.advice_requests where reference = v_ref;
  out := out || '3a reference shaped IA-YY-NNNN = ' || (v_ref ~ '^IA-[0-9]{2}-[0-9]{4}$') || '  want t' || E'\n';
  out := out || '3b one row, open, unread = ' ||
    (select count(*)=1 from public.advice_requests
      where id=v_id and state='open' and unread_for_imam) || '  want t' || E'\n';
  out := out || '3c arrival audit row carries ONLY the reference = ' ||
    (select detail = jsonb_build_object('reference', v_ref) from public.admin_audit
      where action='imam_advice_received' and detail->>'reference'=v_ref) || '  want t' || E'\n';

  perform set_config('request.jwt.claims',
    json_build_object('sub',ADMIN,'aal','aal2',
      'app_metadata',json_build_object('masjid_id',v_m))::text, true);
  --  4a IS THE CONTROL. Without it the four refusals below prove nothing.
  out := out || '4a the session really IS a verified admin = ' || public.verified_admin() ||
                '  want t, or 4b-4e prove nothing' || E'\n';
  out := out || '4b verified_imam for that admin = ' || public.verified_imam() || '  want f' || E'\n';
  out := out || '4c imam_advice_list refused = ' ||
    ((public.imam_advice_list() ->> 'allowed')='false') || '  want t' || E'\n';
  out := out || '4d imam_advice_read refused = ' ||
    ((public.imam_advice_read(v_id) ->> 'allowed')='false') || '  want t' || E'\n';
  out := out || '4e imam_advice_answer refused = ' ||
    ((public.imam_advice_answer(v_id,'I should not be able to do this') ->> 'allowed')='false') || '  want t' || E'\n';
  out := out || '4f and it wrote nothing = ' ||
    (select count(*)=0 from public.advice_answers where request_id=v_id) || '  want t' || E'\n';

  raise exception 'PROOF 1 %', out;
end $$;

/*  BLOCK 2 - the imam reads and answers. */
do $$
declare
  IMAM uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  v_m uuid; r jsonb; v_id uuid; v_ref text; out text := E'\n';
begin
  v_m := public.sole_masjid();
  insert into auth.users (id,email) values (IMAM,'imam.throwaway@example.test');
  insert into public.profiles (id,full_name,email,is_active)
    values (IMAM,'Throwaway Imam','imam.throwaway@example.test',true)
    on conflict (id) do update set is_active=true;
  insert into public.user_roles (user_id,masjid_id,role) values (IMAM,v_m,'imam');

  perform set_config('request.jwt.claims','',true);
  r := public.request_imam_advice(jsonb_build_object(
         'name','Zahra Example','phone','07700 900333','email','zahra@example.test',
         'subject','A question about a will','question','SECRETWORD keep this private'));
  v_ref := r ->> 'reference';
  select id into v_id from public.advice_requests where reference=v_ref;

  perform set_config('request.jwt.claims',
    json_build_object('sub',IMAM,'aal','aal1',
      'app_metadata',json_build_object('masjid_id',v_m))::text, true);
  out := out || '5a the imam at aal1 is refused = ' ||
    ((public.imam_advice_list() ->> 'allowed')='false') || '  want t' || E'\n';

  perform set_config('request.jwt.claims',
    json_build_object('sub',IMAM,'aal','aal2',
      'app_metadata',json_build_object('masjid_id',v_m))::text, true);
  r := public.imam_advice_list();
  out := out || '6a allowed, 1 waiting, 1 unread = ' ||
    ((r->>'allowed')='true' and (r->>'waiting')='1' and (r->>'unread')='1') || '  want t' || E'\n';
  out := out || '6b the list names NOBODY and quotes NOTHING = ' ||
    (r::text not like '%Zahra%' and r::text not like '%900333%'
     and r::text not like '%zahra@example.test%' and r::text not like '%SECRETWORD%') || '  want t' || E'\n';
  out := out || '6c the subject IS there, which is the point = ' ||
    (r::text like '%A question about a will%') || '  want t' || E'\n';
  out := out || '6d the count-only sibling agrees = ' ||
    ((public.imam_advice_waiting_count() ->> 'waiting') = (r->>'waiting')) || '  want t' || E'\n';

  r := public.imam_advice_read(v_id);
  out := out || '7a the record carries all of it = ' ||
    ((r->>'allowed')='true' and r->>'name'='Zahra Example' and r->>'phone'='07700 900333'
     and r->>'email'='zahra@example.test' and r->>'question' like '%SECRETWORD%') || '  want t' || E'\n';
  out := out || '7b no longer unread, first_read_at stamped = ' ||
    (select not unread_for_imam and first_read_at is not null
       from public.advice_requests where id=v_id) || '  want t' || E'\n';
  out := out || '7c the read audit row names nothing but the request = ' ||
    (select count(*)=1 from public.admin_audit where action='imam_advice_read'
      and detail->>'request'=v_id::text and detail - 'request' - 'reference' = '{}'::jsonb) || '  want t' || E'\n';

  out := out || '8a a request that does not exist = ' ||
    ((public.imam_advice_read('bbbbbbbb-0000-4000-8000-00000000ffff') ->> 'allowed')='false') || '  want t' || E'\n';

  begin
    perform public.imam_advice_answer(v_id,'   ');
    out := out || '9a an empty answer: FAIL - it was accepted' || E'\n';
  exception when others then
    out := out || '9a an empty answer is refused = ' || (sqlstate='22023') || '  want t' || E'\n';
  end;
  r := public.imam_advice_answer(v_id, E'Walaikum assalam.\n\nPlease ring the office and ask for me.');
  out := out || '9b saved and handed to the mail path = ' ||
    ((r->>'saved')='true' and (r->>'emailed')='true') || '  want t' || E'\n';
  out := out || '9c one answer row, state answered = ' ||
    ((select count(*)=1 from public.advice_answers where request_id=v_id) and
     (select state='answered' and answered_at is not null from public.advice_requests where id=v_id)) || '  want t' || E'\n';
  out := out || '9d no longer waiting = ' ||
    ((public.imam_advice_waiting_count() ->> 'waiting')='0') || '  want t' || E'\n';
  out := out || '9e the answered audit row names nothing but the request = ' ||
    (select count(*)=1 from public.admin_audit where action='imam_advice_answered'
      and detail->>'request'=v_id::text and detail - 'request' - 'reference' = '{}'::jsonb) || '  want t' || E'\n';

  raise exception 'PROOF 2 %', out;
end $$;

/*  BLOCK 3 - what leaves the database, and what is kept.

    Note convert_from(body,'utf8') rather than body::text. See the note above
    about the bug this check had when it was first written. */
do $$
declare
  IMAM uuid := 'aaaaaaaa-0000-4000-8000-000000000001';
  v_m uuid; r jsonb; v_id uuid; v_ref text; n int; out text := E'\n';
  q0 bigint; body_text text;
begin
  perform set_config('lock_timeout','4s',true);
  v_m := public.sole_masjid();
  select coalesce(max(id),0) into q0 from net.http_request_queue;

  insert into auth.users (id,email) values (IMAM,'imam.throwaway@example.test');
  insert into public.profiles (id,full_name,email,is_active)
    values (IMAM,'Throwaway Imam','imam.throwaway@example.test',true)
    on conflict (id) do update set is_active=true;
  insert into public.user_roles (user_id,masjid_id,role) values (IMAM,v_m,'imam');

  perform set_config('request.jwt.claims','',true);
  r := public.request_imam_advice(jsonb_build_object(
    'name','Zahra Example','phone','07700 900333','email','zahra@example.test',
    'subject','A question about a will','question','SECRETWORD keep this private'));
  v_ref := r->>'reference';
  select id into v_id from public.advice_requests where reference=v_ref;
  perform set_config('request.jwt.claims',
    json_build_object('sub',IMAM,'aal','aal2',
      'app_metadata',json_build_object('masjid_id',v_m))::text, true);
  perform public.imam_advice_answer(v_id, E'Walaikum assalam.\n\nPlease ring the office and ask for me.');
  perform set_config('request.jwt.claims','',true);

  r := public.advice_for_notify(v_id);
  out := out || '10a notify gets the address, the words and the reference = ' ||
    (r->>'email'='zahra@example.test' and r->>'answer' like '%ask for me%' and r->>'reference'=v_ref)
    || '  want t' || E'\n';
  out := out || '10b notify is never handed the question = ' ||
    (r::text not like '%SECRETWORD%') || '  want t' || E'\n';
  out := out || '10c the imam''s own address is found = ' ||
    ('imam.throwaway@example.test' = any(public.advice_alert_addresses(v_m))) || '  want t' || E'\n';
  update public.profiles set is_active=false where id=IMAM;
  out := out || '10d a suspended imam is not alerted, and shuts the form = ' ||
    (cardinality(public.advice_alert_addresses(v_m))=0 and not public.advice_is_open(null))
    || '  want t' || E'\n';
  update public.profiles set is_active=true where id=IMAM;

  select count(*) into n from net.http_request_queue where id > q0;
  select string_agg(convert_from(body,'utf8'), ' | ' order by id) into body_text
    from net.http_request_queue where id > q0;
  out := out || '11a two posts queued, arrival and answer = ' || (n=2) || '  want t' || E'\n';
  out := out || '11b nothing queued carries the question or the person = ' ||
    (body_text not like '%SECRETWORD%' and body_text not like '%Zahra%'
     and body_text not like '%zahra@example.test%' and body_text not like '%900333%'
     and body_text not like '%question about a will%') || '  want t' || E'\n';
  out := out || '11c what IS queued, in full: ' || body_text || E'\n';

  insert into public.advice_answers (request_id, body) values (v_id, 'a second throwaway answer');
  delete from public.advice_requests where id=v_id;
  out := out || '12a both answers went with the request = ' ||
    ((select count(*)=0 from public.advice_answers where request_id=v_id)
     and (select count(*)=0 from public.advice_requests where id=v_id)) || '  want t' || E'\n';

  for n in 1..3 loop
    perform public.request_imam_advice(jsonb_build_object(
      'name','Zahra Example','phone','07700 900333','email','zahra@example.test',
      'subject','Again '||n,'question','SECRETWORD again'));
  end loop;
  begin
    perform public.request_imam_advice(jsonb_build_object(
      'name','Zahra Example','phone','07700 900333','email','zahra@example.test',
      'subject','Again 4','question','SECRETWORD again'));
    out := out || '13a the fourth in a day: FAIL - it was accepted' || E'\n';
  exception when others then
    out := out || '13a the fourth in a day is refused = ' || (sqlstate='23514') || '  want t' || E'\n';
  end;
  begin
    perform public.request_imam_advice(jsonb_build_object(
      'name','Bilal Example','phone','07700 900444','email','bilal@example.test',
      'subject','A different question','question','SECRETWORD other'));
    out := out || '13b a different contact is not caught by it = true  want t' || E'\n';
  exception when others then
    out := out || '13b a different contact is not caught by it = false  want t' || E'\n';
  end;

  out := out || '14a dry-run purge finds nothing a year old = ' ||
    (public.purge_old_imam_advice(12,true)=0) || '  want t' || E'\n';
  out := out || '14b the chase finds nothing a week old = ' ||
    (public.advice_chase(7)=0) || '  want t' || E'\n';

  raise exception 'PROOF 3 %', out;
end $$;

--  ---------------------------------------------------------------------
--  AND THE STRUCTURAL CHECKS, which are what cover the path this proof
--  cannot reach. Run as one query; every number is as printed.
--  ---------------------------------------------------------------------
--    tables 2 | fns_of_13 13 | trgs 2 | jobs 2 | rls_on 2 | policies 0
--    public_grants 0
select
  (select count(*) from pg_class where relnamespace='public'::regnamespace
     and relname in ('advice_requests','advice_answers')) as tables,
  (select count(*) from pg_proc where pronamespace='public'::regnamespace
     and proname in ('verified_imam','advice_is_open','request_imam_advice',
       'notify_the_imam','advice_alert_addresses','advice_for_notify',
       'imam_advice_list','imam_advice_waiting_count','imam_advice_read',
       'imam_advice_answer','imam_advice_close','advice_chase',
       'purge_old_imam_advice')) as fns_of_13,
  (select count(*) from pg_trigger t join pg_class c on c.oid=t.tgrelid
     where c.relname='advice_requests' and not t.tgisinternal) as trgs,
  (select count(*) from cron.job where jobname like '%imam-advice%') as jobs,
  (select count(*) from pg_class where relnamespace='public'::regnamespace
     and relname in ('advice_requests','advice_answers') and relrowsecurity) as rls_on,
  (select count(*) from pg_policies where schemaname='public'
     and tablename in ('advice_requests','advice_answers')) as policies,
  (select count(*) from information_schema.role_table_grants
     where table_schema='public' and table_name in ('advice_requests','advice_answers')
       and grantee in ('anon','authenticated','public')) as public_grants;
