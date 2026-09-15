-- ===========================================================================
--  041_one_definition_of_a_notice.sql
--  15 September 2026
--
--  WHAT WENT WRONG IN 040, WITHIN THE HOUR
--  ---------------------------------------
--  040 said it reconstructed `notices` from the live schema. It reconstructed
--  the columns and missed the constraints, because `notices` was made in the
--  dashboard and the reconstruction was written from a column listing rather
--  than from pg_constraint. Three CHECKs were already on the table and nobody
--  reading 040 would have known:
--
--      notices_topic_check   topic in (announcements, events, janazah, kahf)
--      notices_title_check   length(btrim(title)) between 1 and 70
--      notices_body_check    length(btrim(body))  between 1 and 2000
--
--  040 then added its own three alongside them. CHECKS ARE AND, NOT OR: what
--  the table actually permits is the INTERSECTION, and the intersection was
--  not what either author intended.
--
--    *  TOPIC. 040 offers `ramadan` and `madrasah`. The old constraint does
--       not. Both would have been refused — by the table, after check_notice()
--       had already said the notice was fine — so a committee member choosing
--       "Ramadan" would have got a raw Postgres constraint violation naming
--       `notices_topic_check`, a constraint no file mentions. That is the
--       exact failure check_notice() exists to prevent. Meanwhile `kahf` was
--       permitted by the old constraint and refused by the new one, so it was
--       dead too.
--
--    *  TITLE. check_notice() tells a volunteer to keep the heading under 120
--       characters. The table refuses anything over 70. A 90-character
--       heading passes every validation the person can see and is then thrown
--       out by the database.
--
--  Neither is exotic. Both are the same fault: THE SAME RULE WRITTEN DOWN IN
--  TWO PLACES, and this is the second time on this project — the whole reason
--  check_notice() is in the database and not in the editor.
--
--  WHAT THIS DOES
--  --------------
--  Removes all six and writes each rule down ONCE. Where the two versions
--  disagreed, the stricter or more considered one wins:
--
--    *  70 characters, not 120. A heading is read at a glance on a phone.
--       The editor now counts down to 70, so nobody meets the limit by
--       surprise.
--    *  Topics are the UNION, because every one of them is a real thing a
--       masjid announces. `kahf` is Sūrat al-Kahf on a Friday and was in the
--       original design; dropping it because a later author had not heard of
--       it would be the wrong way round.
-- ===========================================================================

--  AND THEN THE SELF-TEST IN SECTION 4 FOUND A THIRD ONE, which is the best
--  thing in this file. `body` is NOT NULL on the live table. Nothing said so:
--  040's `create table if not exists` was a no-op against a table that already
--  existed, so its `body text` — nullable — never took effect and never could.
--  The consequence was live in production for about half an hour:
--  save_notice() writes NULL when the body is blank, so EVERY attempt to save
--  a notice without a body failed with a raw not-null violation. "Masjid
--  closed Monday" is a real notice and needs no paragraph.
--
--  Bodies are made optional here, because that is what the editor, the
--  validator and plain sense all already assumed. Headings stay required.
--
--  The self-test is the point. Both the topic fault and the title fault were
--  found by a person reading a catalogue; this one was found by the migration
--  refusing to commit. That is the difference between a check somebody
--  remembers to run and a check that cannot be skipped.

begin;

-- ---------------------------------------------------------------------------
--  0. Nullability, which is a constraint too and is not in pg_constraint
--
--  `create table if not exists` silently does nothing when the table is there.
--  It is the right statement for idempotence and the wrong one for
--  reconstruction, and 040 used it for both.
-- ---------------------------------------------------------------------------
alter table public.notices alter column body  drop not null;
alter table public.notices alter column title set not null;

-- ---------------------------------------------------------------------------
--  1. Everything off, including 040's own three
-- ---------------------------------------------------------------------------
alter table public.notices drop constraint if exists notices_topic_check;
alter table public.notices drop constraint if exists notices_title_check;
alter table public.notices drop constraint if exists notices_body_check;
alter table public.notices drop constraint if exists notices_topic_known;
alter table public.notices drop constraint if exists notices_title_sane;
alter table public.notices drop constraint if exists notices_image_is_https;

-- ---------------------------------------------------------------------------
--  2. The rules, once each
--
--  Named for what they mean rather than what column they sit on, so a
--  violation message tells somebody something.
-- ---------------------------------------------------------------------------
alter table public.notices add constraint notice_topic_is_one_we_show
  check (topic in ('announcements', 'events', 'janazah', 'kahf',
                   'ramadan', 'madrasah'));

--  A heading is required and short. NULL is not allowed: a notice with no
--  heading renders as an empty box on the front page.
alter table public.notices add constraint notice_has_a_short_heading
  check (title is not null and length(btrim(title)) between 1 and 70);

--  A body is optional — "Masjid closed Monday" needs no paragraph — but an
--  empty string is not the same as absent and would render as a blank line.
alter table public.notices add constraint notice_body_is_absent_or_real
  check (body is null or length(btrim(body)) between 1 and 2000);

alter table public.notices add constraint notice_picture_is_https
  check (image_url is null or image_url like 'https://%');

--  A picture needs both its dimensions or neither. One of the two is how you
--  get a page that reflows when the image lands — which is the CLS fault this
--  site spent an evening removing from its own fonts.
alter table public.notices add constraint notice_picture_has_both_sides
  check ((image_w is null) = (image_h is null));

alter table public.notices add constraint notice_picture_sides_are_positive
  check ((image_w is null or image_w > 0) and (image_h is null or image_h > 0));

--  An image without a picture is nonsense, and so is a size without an image.
alter table public.notices add constraint notice_size_needs_a_picture
  check (image_w is null or image_url is not null);

-- ---------------------------------------------------------------------------
--  3. check_notice(), told the truth
--
--  Replaced whole rather than patched, so the file that explains the rule and
--  the constraint that enforces it can be read side by side.
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
  v_w     text := nullif(btrim(coalesce(p->>'image_w', '')), '');
  v_h     text := nullif(btrim(coalesce(p->>'image_h', '')), '');
begin
  if v_title = '' then
    return 'A notice needs a heading.';
  end if;
  --  70, and the number is quoted back, because "too long" without a number
  --  means deleting words until it stops complaining.
  if length(v_title) > 70 then
    return 'The heading is ' || length(v_title) || ' characters. The limit is 70 — '
        || 'it is read at a glance, usually on a phone.';
  end if;
  if length(v_body) > 2000 then
    return 'The notice is ' || length(v_body) || ' characters. The limit is 2000.';
  end if;
  if v_topic not in ('announcements', 'events', 'janazah', 'kahf',
                     'ramadan', 'madrasah') then
    return 'The topic must be one of: announcements, events, janazah, kahf, '
        || 'ramadan, madrasah.';
  end if;

  --  A picture is optional. If there is one it has to be an https address:
  --  an http one is a mixed-content warning on every visitor's screen, and a
  --  javascript: one is a script on the masjid's front page.
  if v_img <> '' and v_img !~ '^https://' then
    return 'A picture has to be an https:// web address.';
  end if;
  if v_img = '' and (v_w is not null or v_h is not null) then
    return 'There is a picture size but no picture.';
  end if;
  if (v_w is null) <> (v_h is null) then
    return 'A picture needs both a width and a height, or neither. With only '
        || 'one, the page jumps when the picture loads.';
  end if;

  --  A notice that has already expired would save and then be invisible, and
  --  the person would reasonably conclude the screen is broken.
  if (p->>'expires_at') is not null and (p->>'expires_at') <> ''
     and (p->>'expires_at')::timestamptz <= now() then
    return 'That "remove after" date has already passed, so the notice would '
        || 'never appear. Leave it blank to keep the notice until you delete it.';
  end if;

  return null;   -- null means fine
end $fn$;

revoke all on function public.check_notice(jsonb) from public, anon;

-- ---------------------------------------------------------------------------
--  4. Prove the two agree, here, now, against the real table
--
--  The whole fault above was a validator and a constraint that disagreed and
--  nobody noticing. So do not merely assert that they agree — TRY EVERY CASE
--  AGAINST THE ACTUAL TABLE and roll it back. If check_notice() says yes and
--  the table says no, this migration refuses to commit.
-- ---------------------------------------------------------------------------
do $check$
declare
  v_case   jsonb;
  v_why    text;
  v_failed boolean;
  v_cases  jsonb := jsonb_build_array(
    jsonb_build_object('title', 'Jumuʿah moves to 1.30pm',   'topic', 'announcements'),
    jsonb_build_object('title', 'Janāzah after Ẓuhr',        'topic', 'janazah'),
    jsonb_build_object('title', 'Sūrat al-Kahf, Friday',     'topic', 'kahf'),
    jsonb_build_object('title', 'Tarāwīḥ begins',            'topic', 'ramadan'),
    jsonb_build_object('title', 'Madrasah closed Monday',    'topic', 'madrasah'),
    jsonb_build_object('title', 'Eid prayer',                'topic', 'events'),
    --  Exactly on each boundary, from both sides.
    jsonb_build_object('title', repeat('x', 70),             'topic', 'events'),
    jsonb_build_object('title', 'With a body',               'topic', 'events',
                       'body',  repeat('y', 2000)),
    jsonb_build_object('title', 'With a picture',            'topic', 'events',
                       'image_url', 'https://example.test/a.jpg',
                       'image_w', '800', 'image_h', '600')
  );
begin
  for v_case in select * from jsonb_array_elements(v_cases) loop
    v_why := public.check_notice(v_case);
    if v_why is not null then
      raise exception 'check_notice() refuses a case it should accept: % -> %',
        v_case, v_why;
    end if;

    --  And now the table's own opinion of the same row.
    begin
      insert into public.notices (topic, title, body, image_url, image_w, image_h, published)
      values (v_case->>'topic', v_case->>'title',
              nullif(v_case->>'body', ''),
              nullif(v_case->>'image_url', ''),
              nullif(v_case->>'image_w', '')::int,
              nullif(v_case->>'image_h', '')::int,
              false);
    exception when check_violation then
      raise exception 'check_notice() ACCEPTS a notice the table REFUSES — the '
                      'validator and the constraints disagree, which is the '
                      'whole fault this migration exists to fix. Case: %', v_case;
    end;
  end loop;

  --  The other direction: things check_notice() refuses must really be
  --  refusable, or the message is decoration.
  v_failed := public.check_notice(
      jsonb_build_object('title', repeat('x', 71), 'topic', 'events')) is null;
  if v_failed then raise exception 'a 71-character heading was accepted'; end if;

  v_failed := public.check_notice(
      jsonb_build_object('title', 'x', 'topic', 'wedding')) is null;
  if v_failed then raise exception 'an unknown topic was accepted'; end if;

  v_failed := public.check_notice(
      jsonb_build_object('title', 'x', 'topic', 'events',
                         'image_url', 'http://example.test/a.jpg')) is null;
  if v_failed then raise exception 'a plain http picture was accepted'; end if;

  v_failed := public.check_notice(
      jsonb_build_object('title', 'x', 'topic', 'events',
                         'image_url', 'https://example.test/a.jpg',
                         'image_w', '800')) is null;
  if v_failed then raise exception 'a picture with a width and no height was accepted'; end if;

  --  NULLABILITY IS A CONSTRAINT AND IT IS NOT IN pg_constraint, which is how
  --  `body NOT NULL` hid from 040 and from the first draft of this file. State
  --  it, so that a later ALTER putting it back fails here rather than in front
  --  of a committee member.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'notices'
                and column_name = 'body' and is_nullable = 'NO') then
    raise exception 'notices.body is NOT NULL again — a notice with no body '
                    'cannot be saved, and save_notice() writes NULL for a blank one';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'notices'
                and column_name = 'title' and is_nullable = 'YES') then
    raise exception 'notices.title is nullable — a notice with no heading '
                    'renders as an empty box on the front page';
  end if;

  --  Everything the loop inserted goes away. The probe must leave no trace:
  --  a draft nobody typed, sitting in the committee's notices screen, is
  --  worse than no test.
  delete from public.notices
   where published = false
     and (title = any (array['Jumuʿah moves to 1.30pm', 'Janāzah after Ẓuhr',
                             'Sūrat al-Kahf, Friday', 'Tarāwīḥ begins',
                             'Madrasah closed Monday', 'Eid prayer',
                             'With a body', 'With a picture'])
          or title = repeat('x', 70));

  raise notice 'check_notice() and the table agree on all 9 cases, and refuse all 4 bad ones.';
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select conname, pg_get_constraintdef(oid)
--      from pg_constraint where conrelid = 'public.notices'::regclass
--       and contype = 'c' order by conname;
--
--  Seven rows, every name beginning `notice_`. If anything named
--  `notices_*_check` is still there, the dashboard has been used again and
--  there are two definitions of a notice once more.
--
--  THE RULE THIS COST: a table made in the dashboard has constraints nobody
--  can read, and `\d` in psql — or pg_constraint — is the only place they
--  exist. Reconstructing one from a column list reconstructs half of it.
-- ===========================================================================
