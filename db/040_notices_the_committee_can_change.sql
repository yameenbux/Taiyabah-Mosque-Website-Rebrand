-- ===========================================================================
--  040_notices_the_committee_can_change.sql
--  15 September 2026
--
--  WHAT WAS WRONG
--  --------------
--  `notices` held one row. Nothing on the website read it, and nobody could
--  write to it. It was a table with no way in and no way out.
--
--  The way in was `publish_notice(jsonb)` — SECURITY DEFINER, granted to
--  `service_role` and to nobody else, and WITH NO PERMISSION CHECK INSIDE IT
--  AT ALL. It was safe only because of the grant, which is one careless
--  `grant execute ... to authenticated` away from being a function any
--  signed-in account can put anything on the masjid's front page through.
--  Nothing in this repository or in any Edge Function calls it. It is dropped
--  here rather than guarded, because the honest fix for an unused function
--  with a hole in it is to remove it.
--
--  The way out did not exist: the public page never fetched `notices_live`.
--  This migration is therefore only half the job, and the other half is in
--  index_template.html. A table the committee can write to and no visitor can
--  read is exactly as useless as the reverse, which this project has already
--  done once — course sign-ups landed correctly in a table no administrator
--  could see.
--
--  AND `notices` STILL HAD NO MIGRATION FILE. It was created in the dashboard
--  and existed only in the database, which is how the grants on `notices_live`
--  went unreviewed for months: there was no file for anybody to read. Its
--  definition is reconstructed here from the live schema, so from now on there
--  is one.
--
--  WHAT THIS ADDS
--  --------------
--  Four functions, every one of them `verified_admin()`:
--
--    notices_list()                 everything, drafts included
--    save_notice(jsonb)             create or amend; NEW ONES ARE DRAFTS
--    set_notice_published(id, bool) the separate, deliberate act
--    delete_notice(id)
--
--  SAVING AND PUBLISHING ARE TWO ACTS, and that is the whole design. The
--  column defaults to `published = true`, which is the wrong default for a
--  screen a committee uses: somebody half-types a janāzah notice, the phone
--  rings, and a half-written death notice is on the front page of the masjid's
--  website. save_notice() writes drafts. Publishing is a button somebody
--  presses on purpose.
--
--  Validation lives HERE and not in the editor, for the same reason it does in
--  028: the editor is the thing being protected, so it cannot be the thing
--  doing the protecting. The anon key is in the page source.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. The table, written down at last
--
--  Reconstructed from the live schema. `create table if not exists` so this is
--  safe against the copy that already exists, and safe to run twice.
-- ---------------------------------------------------------------------------
create table if not exists public.notices (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  topic      text        not null default 'announcements',
  title      text,
  body       text,
  image_url  text,
  image_w    integer,
  image_h    integer,
  event_at   timestamptz,
  expires_at timestamptz,
  published  boolean     not null default true
);

comment on table public.notices is
  'Announcements shown on the public website. Edited from notices/ in the '
  'portal. Rows are drafts until somebody presses Publish.';

alter table public.notices enable row level security;

--  RLS ENABLED WITH ZERO POLICIES is the strongest setting there is: it denies
--  everything to everybody except the owner and SECURITY DEFINER functions.
--  The four functions below are the only way in, and notices_live is the only
--  way out.
drop policy if exists notices_read on public.notices;

revoke all on public.notices from anon, authenticated;

-- ---------------------------------------------------------------------------
--  2. The view the website reads
--
--  Recreated exactly as it was, so this migration cannot quietly change what
--  the public sees. It runs as its OWNER, deliberately — see 034. The owner is
--  how `notices` gets read at all, given the table denies everyone.
--
--  A view that runs as its owner is a hole in RLS unless you say otherwise, so
--  say it: what leaks through this one is title, body, topic, a picture and a
--  date, for rows somebody deliberately published. There is nothing here that
--  is not already meant to be on a public web page. `published` and
--  `expires_at` are NOT in the view — a draft must not be readable by guessing
--  a column name.
-- ---------------------------------------------------------------------------
create or replace view public.notices_live as
  select id, created_at, topic, title, body,
         image_url, image_w, image_h, event_at
    from public.notices
   where published and (expires_at is null or expires_at > now())
   order by coalesce(event_at, created_at) desc;

revoke all    on public.notices_live from anon, authenticated;
grant  select on public.notices_live to anon, authenticated;

-- ---------------------------------------------------------------------------
--  3. What a notice is allowed to be
--
--  A separate function rather than CHECK constraints alone, because a CHECK
--  can only say no — it cannot say WHY, and the person reading the answer is a
--  volunteer, not a developer. The constraints are added too: the function is
--  the explanation, the constraint is the guarantee.
-- ---------------------------------------------------------------------------
create or replace function public.check_notice(p jsonb)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $fn$
declare
  v_title text := btrim(coalesce(p->>'title', ''));
  v_body  text := btrim(coalesce(p->>'body',  ''));
  v_topic text := lower(btrim(coalesce(p->>'topic', '')));
  v_img   text := btrim(coalesce(p->>'image_url', ''));
begin
  if v_title = '' then
    return 'A notice needs a heading.';
  end if;
  if length(v_title) > 120 then
    return 'The heading is ' || length(v_title) || ' characters. Keep it under 120 — '
        || 'it is read at a glance, often on a phone.';
  end if;
  if length(v_body) > 2000 then
    return 'The notice is ' || length(v_body) || ' characters. Keep it under 2000.';
  end if;
  if v_topic not in ('announcements', 'events', 'janazah', 'ramadan', 'madrasah') then
    return 'The topic must be one of: announcements, events, janazah, ramadan, madrasah.';
  end if;

  --  A picture is optional. If there is one it has to be an https address,
  --  because an http one is a mixed-content warning on every visitor's screen
  --  and a javascript: one is a script on the masjid's front page.
  if v_img <> '' and v_img !~ '^https://' then
    return 'A picture has to be an https:// web address.';
  end if;

  --  A notice that has already expired would be saved and then be invisible,
  --  and the person would reasonably conclude the screen is broken.
  if (p->>'expires_at') is not null and (p->>'expires_at') <> ''
     and (p->>'expires_at')::timestamptz <= now() then
    return 'That "remove after" date has already passed, so the notice would '
        || 'never appear. Leave it blank to keep the notice until you delete it.';
  end if;

  return null;   -- null means fine
end $fn$;

--  The guarantee, as opposed to the explanation.
alter table public.notices drop constraint if exists notices_topic_known;
alter table public.notices add constraint notices_topic_known
  check (topic in ('announcements', 'events', 'janazah', 'ramadan', 'madrasah'));

alter table public.notices drop constraint if exists notices_title_sane;
alter table public.notices add constraint notices_title_sane
  check (title is null or length(title) <= 120);

alter table public.notices drop constraint if exists notices_image_is_https;
alter table public.notices add constraint notices_image_is_https
  check (image_url is null or image_url = '' or image_url like 'https://%');

-- ---------------------------------------------------------------------------
--  4. Reading them, in the portal
--
--  Drafts included, which is the difference between this and notices_live.
-- ---------------------------------------------------------------------------
create or replace function public.notices_list()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may read the notices.'
      using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.sort_at desc)
      from (
        select n.id, n.topic, n.title, n.body, n.image_url,
               n.event_at, n.expires_at, n.published, n.created_at,
               (n.published and (n.expires_at is null or n.expires_at > now())) as on_the_website,
               coalesce(n.event_at, n.created_at) as sort_at
          from public.notices n
      ) x
  ), '[]'::jsonb);
end $fn$;

-- ---------------------------------------------------------------------------
--  5. Writing one
--
--  One function for create and amend, because two functions that differ by an
--  id are two sets of validation to keep in step. Absent id means new.
-- ---------------------------------------------------------------------------
create or replace function public.save_notice(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id    uuid;
  v_why   text;
  v_new   boolean;
  v_topic text := lower(btrim(coalesce(p->>'topic', 'announcements')));
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the notices.'
      using errcode = '42501';
  end if;

  v_why := public.check_notice(p);
  if v_why is not null then
    raise exception '%', v_why using errcode = 'check_violation';
  end if;

  v_id  := nullif(btrim(coalesce(p->>'id', '')), '')::uuid;
  v_new := v_id is null;

  if v_new then
    --  NEW NOTICES ARE DRAFTS. The column defaults to published = true and
    --  that default is not changed, because the prayer-hall screens and
    --  anything else writing directly still rely on it. It is overridden
    --  HERE, where a human is typing.
    insert into public.notices (topic, title, body, image_url, image_w, image_h,
                                event_at, expires_at, published)
    values (v_topic,
            btrim(p->>'title'),
            nullif(btrim(coalesce(p->>'body', '')), ''),
            nullif(btrim(coalesce(p->>'image_url', '')), ''),
            nullif(p->>'image_w', '')::int,
            nullif(p->>'image_h', '')::int,
            nullif(p->>'event_at',   '')::timestamptz,
            nullif(p->>'expires_at', '')::timestamptz,
            false)
    returning id into v_id;
  else
    --  Amending does NOT change whether it is published. Editing the wording
    --  of a live notice should not take it off the website, and editing a
    --  draft should not put it on.
    update public.notices set
      topic      = v_topic,
      title      = btrim(p->>'title'),
      body       = nullif(btrim(coalesce(p->>'body', '')), ''),
      image_url  = nullif(btrim(coalesce(p->>'image_url', '')), ''),
      image_w    = nullif(p->>'image_w', '')::int,
      image_h    = nullif(p->>'image_h', '')::int,
      event_at   = nullif(p->>'event_at',   '')::timestamptz,
      expires_at = nullif(p->>'expires_at', '')::timestamptz
    where id = v_id;

    if not found then
      raise exception 'That notice no longer exists. Somebody may have deleted it.'
        using errcode = 'no_data_found';
    end if;
  end if;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(),
          case when v_new then 'notice_created' else 'notice_edited' end,
          jsonb_build_object('id', v_id, 'topic', v_topic,
                             'title', left(btrim(p->>'title'), 80)));

  return jsonb_build_object('id', v_id, 'is_new', v_new);
end $fn$;

-- ---------------------------------------------------------------------------
--  6. Putting it on the website, and taking it off
-- ---------------------------------------------------------------------------
create or replace function public.set_notice_published(p_id uuid, p_published boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_title text; v_expires timestamptz;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may publish a notice.'
      using errcode = '42501';
  end if;

  select title, expires_at into v_title, v_expires
    from public.notices where id = p_id;
  if not found then
    raise exception 'That notice no longer exists.' using errcode = 'no_data_found';
  end if;

  --  Publishing something already expired puts it nowhere, and the person
  --  would reasonably think the button is broken. Say so instead.
  if p_published and v_expires is not null and v_expires <= now() then
    --  RAISE takes a LITERAL format string, not an expression: 'a' || 'b'
    --  here is a syntax error, and it is one you only find by running it.
    --  check_notice() above concatenates freely because those are RETURNs.
    raise exception 'That notice has a "remove after" date in the past, so publishing it would show nothing. Clear the date first.'
      using errcode = 'check_violation';
  end if;

  update public.notices set published = p_published where id = p_id;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(),
          case when p_published then 'notice_published' else 'notice_unpublished' end,
          jsonb_build_object('id', p_id, 'title', left(coalesce(v_title, ''), 80)));

  return jsonb_build_object('id', p_id, 'published', p_published);
end $fn$;

-- ---------------------------------------------------------------------------
--  7. Deleting one
--
--  Kept separate from unpublishing, and the editor asks first. Taking a notice
--  off the website is the reversible thing and is what somebody usually means.
-- ---------------------------------------------------------------------------
create or replace function public.delete_notice(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_title text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may delete a notice.'
      using errcode = '42501';
  end if;

  delete from public.notices where id = p_id returning title into v_title;
  if not found then
    raise exception 'That notice no longer exists.' using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'notice_deleted',
          jsonb_build_object('id', p_id, 'title', left(coalesce(v_title, ''), 80)));

  return jsonb_build_object('id', p_id, 'deleted', true);
end $fn$;

-- ---------------------------------------------------------------------------
--  8. The old way in, removed
--
--  SECURITY DEFINER with no permission check inside it. Nothing calls it.
-- ---------------------------------------------------------------------------
drop function if exists public.publish_notice(jsonb);

-- ---------------------------------------------------------------------------
--  9. Grants
--
--  GRANT AND RLS ARE DIFFERENT THINGS AND YOU NEED BOTH — but for functions
--  the grant is the whole of it, so these are the only lines that decide who
--  may call them. `authenticated`, narrowed to a verified administrator by the
--  check inside each one. Never `public`, never `anon`.
-- ---------------------------------------------------------------------------
revoke all on function public.notices_list()                       from public, anon;
revoke all on function public.save_notice(jsonb)                   from public, anon;
revoke all on function public.set_notice_published(uuid, boolean)  from public, anon;
revoke all on function public.delete_notice(uuid)                  from public, anon;
revoke all on function public.check_notice(jsonb)                  from public, anon;

grant execute on function public.notices_list()                      to authenticated;
grant execute on function public.save_notice(jsonb)                  to authenticated;
grant execute on function public.set_notice_published(uuid, boolean) to authenticated;
grant execute on function public.delete_notice(uuid)                 to authenticated;

-- ---------------------------------------------------------------------------
--  10. Housekeeping
--
--  Notices are not personal data, so there is no retention duty here — this is
--  about a table that otherwise grows for ever. A notice that expired a year
--  ago is not history anybody consults.
--
--  auth.uid() IS NULL means pg_cron or psql, not a browser. A signed-in caller
--  must be a verified administrator. anon has no grant, so "no JWT" cannot be
--  reached from the public API. Written this way because a function guarded by
--  verified_admin() alone CAN NEVER BE SCHEDULED: pg_cron carries no JWT, so
--  auth.uid() is null and the guard refuses its own cron job — which is
--  exactly how 037's purges sat there for weeks never once running.
-- ---------------------------------------------------------------------------
create or replace function public.purge_expired_notices(retain_months integer)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_deleted int;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may purge notices.'
      using errcode = '42501';
  end if;
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be at least 1' using errcode = 'check_violation';
  end if;

  delete from public.notices
   where expires_at is not null
     and expires_at < now() - make_interval(months => retain_months)
  returning 1 into v_deleted;

  get diagnostics v_deleted = row_count;
  return v_deleted;
end $fn$;

revoke all     on function public.purge_expired_notices(integer) from public, anon;
grant  execute on function public.purge_expired_notices(integer) to authenticated;

select cron.unschedule('purge-expired-notices')
 where exists (select 1 from cron.job where jobname = 'purge-expired-notices');

select cron.schedule('purge-expired-notices', '35 3 * * *',
                     $$select public.purge_expired_notices(12)$$);

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select public.notices_list();          -- as a verified admin: the lot
--    select * from public.notices_live;     -- as anon: published, unexpired
--
--  And the check that matters, run as anon:
--
--    select public.save_notice('{"title":"x"}'::jsonb);
--        -> ERROR: permission denied for function save_notice
--
--  If that succeeds, the grants in section 9 are wrong and anybody holding the
--  anon key — which is in the page source of every page on this website — can
--  write to the masjid's front page.
-- ===========================================================================
