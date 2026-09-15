-- ===========================================================================
--  050_the_app_can_publish_a_notice_again.sql
--  15 September 2026
--
--  A PRODUCTION OUTAGE THAT THIS PROJECT CAUSED, THIS MORNING.
--  ----------------------------------------------------------
--  The masjid runs two things against ONE Supabase project: this website, and
--  the phone app (github.com/yameenbux/Taiyabah-Mosque-App). They share the
--  public.notices table — the app's own db/001_notices.sql says so in as many
--  words, and names this project by id.
--
--  The app writes a notice through a Cloudflare Worker, which holds the
--  service key and calls ONE function:
--
--      POST /api/notice  ->  supaRpc(env, "publish_notice", { payload: {...} })
--                        ->  then, and only then, sends the push
--
--  040_notices_the_committee_can_change.sql dropped publish_notice(). It was
--  right to: that function had NO admin check in it at all and was safe only
--  because of its grant, which is one careless `grant execute ... to
--  authenticated` away from letting anybody with the app's publishable key
--  write the masjid's announcements board.
--
--  What 040 did not do is notice that something else was calling it.
--
--  So since this morning, pressing "Send notification" on the app's trustee
--  screen fails at the database step — and because the Worker sends the push
--  AFTER the row is written, NO NOTIFICATION GOES OUT EITHER. The trustee sees
--  "Could not save the notice: 404 ...". A janāzah announcement, which is the
--  single most time-critical thing this masjid sends, would not have left the
--  building.
--
--  THE LESSON, WHICH IS THE SAME ONE AS THIS MORNING'S OTHER BUG
--  ------------------------------------------------------------
--  A few hours ago the Admin Centre and the staff rail were found to be two
--  lists of the same thing, drifted. This is that shape again, one level up:
--  two repositories, one database, and a migration in one that deletes what
--  the other depends on. Neither repository's tests can see the other.
--
--  There is now a check in _test/app_bridge_test.py that reads the Worker's
--  source out of the app repository and fails if it calls a database function
--  this project does not define. It cannot run in CI without that checkout, so
--  it skips loudly rather than passing quietly.
--
--  WHAT THIS DOES
--  --------------
--  Recreates publish_notice(payload jsonb) with the SAME NAME, THE SAME
--  ARGUMENT AND THE SAME RETURN SHAPE the Worker already expects — the Worker
--  does `Array.isArray(parsed) ? parsed[0] : parsed`, so `returns table` is
--  what it wants — and fixes what was wrong with it:
--
--    *  IT VALIDATES. The old one inserted and let the table constraints
--       decide, so a trustee got a Postgres constraint name where a sentence
--       belonged. This one calls check_notice() — the SAME function the
--       website's own editor calls — so there is one definition of a valid
--       notice and two doors to it, rather than two definitions.
--
--    *  IT SAYS WHERE THE NOTICE CAME FROM. An audit row, with actor null,
--       because the service key is not a person. Null actor with
--       'notice_published_by_app' is the honest record: the masjid knows the
--       app sender did it and knows it cannot know which trustee, which is
--       exactly the gap the new /app/ screen closes for sends made from the
--       website. Not pretending to know is better than an invented actor.
--
--    *  IT IS STILL service_role ONLY. Postgres grants EXECUTE to PUBLIC on
--       every new function, so the revoke below is not tidying — it is the
--       whole of the protection, and it has to come before the grant.
--
--  Prerequisites: 040 and 041. Idempotent.
-- ===========================================================================

begin;

create or replace function public.publish_notice(payload jsonb)
returns table (
  id         uuid,
  created_at timestamptz,
  topic      text,
  title      text,
  body       text,
  image_url  text,
  image_w    int,
  image_h    int,
  event_at   timestamptz,
  expires_at timestamptz,
  published  boolean
)
language plpgsql
security definer
--  Pinned, so the function cannot be redirected through a schema somebody
--  else controls. A security definer function without this is the classic
--  hole, and it is why this line is repeated on every function in db/.
set search_path = public, pg_temp
as $fn$
declare
  v_why   text;
  v_topic text := coalesce(nullif(btrim(payload->>'topic'), ''), 'announcements');
  v_row   public.notices%rowtype;
begin
  --  ONE DEFINITION OF A VALID NOTICE, and this is not it — check_notice() is,
  --  and it lives in 041 where the website's editor also reads it. Calling it
  --  here is the point of this whole function: the app and the website cannot
  --  disagree about what may be published, because there is only one opinion.
  --
  --  check_notice() is revoked from public and anon and granted only to
  --  `authenticated`. That does not block this call: inside a SECURITY DEFINER
  --  function the privilege check runs as the OWNER, who can always execute
  --  their own function. The DO block at the foot of this file proves it
  --  rather than trusting the paragraph.
  v_why := public.check_notice(
             jsonb_set(coalesce(payload, '{}'::jsonb), '{topic}', to_jsonb(v_topic)));
  if v_why is not null then
    --  The Worker puts this straight in front of a trustee, so it has to be a
    --  sentence. RAISE takes a LITERAL format string — 'a' || 'b' here is a
    --  syntax error, which this project has already learned once.
    raise exception '%', v_why using errcode = 'check_violation';
  end if;

  insert into public.notices as n (
    topic, title, body, image_url, image_w, image_h, event_at, expires_at
  )
  values (
    v_topic,
    btrim(payload->>'title'),
    nullif(btrim(coalesce(payload->>'body', '')), ''),
    nullif(btrim(coalesce(payload->>'image_url', '')), ''),
    (payload->>'image_w')::int,
    (payload->>'image_h')::int,
    nullif(payload->>'event_at',   '')::timestamptz,
    nullif(payload->>'expires_at', '')::timestamptz
  )
  returning n.* into v_row;

  --  actor is null ON PURPOSE. See the header.
  insert into public.admin_audit (actor, action, detail)
  values (null, 'notice_published_by_app',
          jsonb_build_object('id', v_row.id, 'topic', v_row.topic,
                             'title', v_row.title,
                             'has_picture', v_row.image_url is not null));

  return query select v_row.id, v_row.created_at, v_row.topic, v_row.title,
                      v_row.body, v_row.image_url, v_row.image_w, v_row.image_h,
                      v_row.event_at, v_row.expires_at, v_row.published;
end $fn$;

comment on function public.publish_notice(jsonb) is
  'The app''s Cloudflare Worker writes a notice through this, with the service '
  'key, which holds no table privileges of its own. Validates through '
  'check_notice() so the app and the website agree on what a notice is. Not '
  'callable by anon or authenticated — the website''s own editor uses '
  'save_notice() instead, which names the administrator who wrote it.';

-- ---------------------------------------------------------------------------
--  The grant IS the protection. Take back what Postgres hands out first.
-- ---------------------------------------------------------------------------
revoke all     on function public.publish_notice(jsonb) from public, anon, authenticated;
grant  execute on function public.publish_notice(jsonb) to service_role;

-- ---------------------------------------------------------------------------
--  PROVE IT, AGAINST THE REAL TABLE, AND ROLL IT BACK
--
--  Three things, because each has failed somewhere on this project already:
--  that a good notice goes in, that a bad one is refused WITH A SENTENCE
--  rather than a constraint name, and that the grants are what they claim.
-- ---------------------------------------------------------------------------
do $check$
declare
  v_id    uuid;
  v_topic text;
  v_msg   text;
  v_anon  boolean;
  v_auth  boolean;
  v_svc   boolean;
begin
  --  1. A notice the app would send goes in, and comes back in the shape the
  --     Worker reads. `kahf` on purpose: it is the topic the app has that the
  --     website's own editor never offers, so it is the one most likely to be
  --     dropped by a website migration that was not thinking about the app.
  select p.id, p.topic into v_id, v_topic
    from public.publish_notice(jsonb_build_object(
      'title', 'Sūrat al-Kahf, Friday',
      'body',  'A test row written by 050 and removed in the same transaction.',
      'topic', 'kahf')) p;

  if v_id is null then
    raise exception 'publish_notice() returned no row';
  end if;
  if v_topic <> 'kahf' then
    raise exception 'publish_notice() stored topic %, expected kahf', v_topic;
  end if;

  delete from public.notices where id = v_id;
  delete from public.admin_audit
   where action = 'notice_published_by_app' and detail->>'id' = v_id::text;

  --  2. A notice that is too long is refused, and the refusal is the sentence
  --     check_notice() wrote — NOT "new row violates check constraint
  --     notice_has_a_short_heading", which is what the old function produced
  --     and what a volunteer would have had to read.
  begin
    perform public.publish_notice(jsonb_build_object(
      'title', repeat('x', 200), 'topic', 'announcements'));
    raise exception 'publish_notice() ACCEPTED a 200-character heading';
  exception
    when check_violation then
      get stacked diagnostics v_msg = message_text;
      if v_msg like '%constraint%' or v_msg not like '%limit is 70%' then
        raise exception 'publish_notice() refused it, but with %, not the '
                        'sentence check_notice() wrote', quote_literal(v_msg);
      end if;
  end;

  --  3. The grants. A function like this is safe ONLY because of these, so
  --     reading them back is not ceremony.
  select has_function_privilege('anon',          'public.publish_notice(jsonb)', 'execute'),
         has_function_privilege('authenticated', 'public.publish_notice(jsonb)', 'execute'),
         has_function_privilege('service_role',  'public.publish_notice(jsonb)', 'execute')
    into v_anon, v_auth, v_svc;

  if v_anon then
    raise exception 'anon can execute publish_notice() — the app ships the '
                    'publishable key in plain sight, so that is the whole '
                    'announcements board open to the internet';
  end if;
  if v_auth then
    raise exception 'authenticated can execute publish_notice() — any signed-in '
                    'account could write a notice without being an administrator';
  end if;
  if not v_svc then
    raise exception 'service_role CANNOT execute publish_notice(), so the app '
                    'sender is still broken';
  end if;

  raise notice 'publish_notice() is back: writes, validates through '
               'check_notice(), and is service_role only.';
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--  Nothing to deploy. The Cloudflare Worker is unchanged and already points
--  here; the next press of "Send notification" on the app's trustee screen
--  works. Worth sending one real notice to confirm, because the failure this
--  fixes was invisible from this repository.
--
--  As service_role:
--    select * from public.publish_notice('{"title":"Test","topic":"announcements"}');
--        -> one row
--
--  As anon or authenticated:
--        -> ERROR: permission denied for function publish_notice
-- ===========================================================================
