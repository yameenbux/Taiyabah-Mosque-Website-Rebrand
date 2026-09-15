-- ===========================================================================
--  047_what_the_website_says_about_a_class.sql
--  15 September 2026
--
--  043 let the committee open, close, rename and re-size a class. It could not
--  let them ADD one, and the screen said so in those words: the website holds
--  more about a course than the table does — which sessions it runs, what the
--  experience question asks, the wording shown when sign-ups are shut — and
--  none of that was anywhere but a hard-coded object in index_template.html.
--  save_course() would create the row; a row with no section on the website is
--  invisible.
--
--  This puts that content in the database, so a class can be described as well
--  as counted.
--
--  THE ONE THING THE COMMITTEE STILL CANNOT INVENT, and it is not an oversight
--  ----------------------------------------------------------------------
--  course_registrations has this, and has had it since 004:
--
--      check (cohort = any (array['mens', 'womens', 'all']))
--
--  So a class may run men's and women's sessions, or one session for
--  everybody, and that is the whole vocabulary. A screen that let somebody
--  type a fourth — "children", "over 60s" — would save happily and then refuse
--  every single sign-up against it with a raw constraint error, which is
--  exactly the fault 041 exists to stop. The LABELS are theirs to write
--  ("Men's class", "Brothers", "Men's session"); the three keys underneath
--  are not.
--
--  Widening that vocabulary is a real option and a bigger change than it
--  looks: cohort is what venue/ and courses/ group by, what the confirmation
--  email says, and what the waiting list is counted within. It wants doing on
--  purpose rather than as a side effect of this.
--
--  WHY THE EXISTING TWO PAGES ARE NOT REGENERATED FROM THIS
--  -------------------------------------------------------
--  The tempting design is one path: every course page drawn from the database,
--  the two that exist seeded so nothing changes. It was not taken, and the
--  reason is that the two pages ARE NOT THE SAME SHAPE. Arabic's fact strip is
--  Time and Places; the Ghusl workshop's is Format and Places, with different
--  markup around the value. One template cannot reproduce both without
--  flattening prose that somebody wrote carefully.
--
--  So: the copy below is editable and is applied to those pages IN PLACE, and
--  a class with no page in the markup gets a generated one. Two paths, chosen
--  deliberately — the risk of quietly degrading the two best-written pages on
--  the site outweighs the tidiness of having one.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. The column
-- ---------------------------------------------------------------------------
alter table public.courses
  add column if not exists page jsonb not null default '{}'::jsonb;

comment on column public.courses.page is
  'What the website says about this class: tagline, intro, fact strip, the '
  'rules list, the cohort labels, the experience question and its options, '
  'and the wording shown when sign-ups are open or shut.';

-- ---------------------------------------------------------------------------
--  2. What that content is allowed to be
--
--  p_mode is the course's cohort_mode, passed in rather than looked up, so
--  this stays IMMUTABLE and can be used in a CHECK later if it ever needs to
--  be. It is the whole reason the cohort keys can be validated at all.
-- ---------------------------------------------------------------------------
create or replace function public.check_course_page(p jsonb, p_mode text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $fn$
declare
  v_item jsonb;
  v_keys text[];
  v_want text[];
  v_n    int;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return 'The class page did not arrive as expected. Reload and try again.';
  end if;

  if btrim(coalesce(p->>'tagline', '')) = '' then
    return 'The class needs a one-line description for the top of its page.';
  end if;
  if length(btrim(p->>'tagline')) > 180 then
    return 'The one-line description is ' || length(btrim(p->>'tagline'))
        || ' characters. The limit is 180.';
  end if;
  if btrim(coalesce(p->>'intro', '')) = '' then
    return 'The class needs an opening paragraph.';
  end if;
  if length(btrim(p->>'intro')) > 1200 then
    return 'The opening paragraph is ' || length(btrim(p->>'intro'))
        || ' characters. The limit is 1200.';
  end if;

  --  The fact strip beside the form. Optional as a whole, capped at four
  --  because it is one row on a phone and a fifth wraps into a mess.
  if p ? 'facts' then
    if jsonb_typeof(p->'facts') <> 'array' then
      return 'The fact strip did not arrive as expected.'; end if;
    if jsonb_array_length(p->'facts') > 4 then
      return 'There are more than four facts beside the form. Four is the most '
          || 'that fits on a phone.'; end if;
    for v_item in select * from jsonb_array_elements(p->'facts') loop
      if btrim(coalesce(v_item->>'k','')) = '' or btrim(coalesce(v_item->>'v','')) = '' then
        return 'Every fact needs both a label and a value.'; end if;
      if length(btrim(v_item->>'k')) > 24 or length(btrim(v_item->>'v')) > 24 then
        return 'A fact label and its value must each be 24 characters or fewer — '
            || 'they sit in a narrow box.'; end if;
    end loop;
  end if;

  --  The what-you-need-to-know list.
  if jsonb_typeof(p->'rules') <> 'array' then
    return 'The class needs at least one "what to know" row.'; end if;
  v_n := jsonb_array_length(p->'rules');
  if v_n < 1 or v_n > 8 then
    return 'There are ' || v_n || ' "what to know" rows. There must be between 1 and 8.';
  end if;
  for v_item in select * from jsonb_array_elements(p->'rules') loop
    if btrim(coalesce(v_item->>'k','')) = '' then
      return 'Every "what to know" row needs a label, like "When".'; end if;
    if length(btrim(v_item->>'k')) > 28 then
      return 'The row label "' || left(btrim(v_item->>'k'), 18)
          || '…" is too long. The limit is 28 characters.'; end if;
    if btrim(coalesce(v_item->>'v','')) = '' then
      return 'The row "' || btrim(v_item->>'k') || '" has nothing against it.'; end if;
    if length(btrim(v_item->>'v')) > 400 then
      return 'The row "' || btrim(v_item->>'k') || '" is too long. The limit is 400.'; end if;
  end loop;

  --  THE COHORTS. The labels are theirs; the keys are the database's.
  if jsonb_typeof(p->'cohorts') <> 'array' then
    return 'The class needs its sessions listed.'; end if;
  select array_agg(x->>'key' order by x->>'key')
    into v_keys from jsonb_array_elements(p->'cohorts') x;
  v_want := case when lower(btrim(coalesce(p_mode,''))) = 'single'
                 then array['all'] else array['mens','womens'] end;
  if v_keys is distinct from v_want then
    return 'This class is set to '
        || case when lower(btrim(coalesce(p_mode,''))) = 'single'
                then 'one session for everyone, so it needs exactly one session row, keyed "all".'
                else 'separate men''s and women''s sessions, so it needs exactly two session rows, keyed "mens" and "womens".'
           end
        || ' Those three keys are the only ones sign-ups can be recorded '
        || 'against — you can write any label you like against them.';
  end if;
  for v_item in select * from jsonb_array_elements(p->'cohorts') loop
    if btrim(coalesce(v_item->>'label','')) = '' then
      return 'Every session needs a label people will read, like "Men''s class".'; end if;
    if length(btrim(v_item->>'label')) > 48 then
      return 'A session label is too long. The limit is 48 characters.'; end if;
  end loop;

  --  The experience question. `experience` on course_registrations is free
  --  text with no constraint, so these keys ARE the committee's to invent.
  if btrim(coalesce(p->>'exp_label','')) = '' then
    return 'The class needs a question to ask people about their experience.'; end if;
  if length(btrim(p->>'exp_label')) > 120 then
    return 'The experience question is too long. The limit is 120 characters.'; end if;
  if jsonb_typeof(p->'exp') <> 'array' then
    return 'The experience question needs some answers to choose from.'; end if;
  v_n := jsonb_array_length(p->'exp');
  if v_n < 2 or v_n > 6 then
    return 'There are ' || v_n || ' answers to the experience question. There '
        || 'must be between 2 and 6 — one answer is not a question.'; end if;
  for v_item in select * from jsonb_array_elements(p->'exp') loop
    if btrim(coalesce(v_item->>'key','')) !~ '^[a-z0-9_]{2,24}$' then
      return 'Each answer needs a short filing name: lower case letters, '
          || 'numbers and underscores, 2 to 24 characters. It is what gets '
          || 'recorded against the sign-up.'; end if;
    if btrim(coalesce(v_item->>'label','')) = '' then
      return 'Every answer needs wording people will read.'; end if;
    if length(btrim(v_item->>'label')) > 90 then
      return 'An answer is too long. The limit is 90 characters.'; end if;
  end loop;
  if (select count(distinct x->>'key') from jsonb_array_elements(p->'exp') x) <> v_n then
    return 'Two of the experience answers have the same filing name.'; end if;

  --  The two blurbs. Both required: the closed one is what somebody reads for
  --  most of the year, and an empty one leaves a bare heading.
  if btrim(coalesce(p->>'open','')) = '' then
    return 'The class needs wording for when sign-ups are open.'; end if;
  if btrim(coalesce(p->>'closed','')) = '' then
    return 'The class needs wording for when sign-ups are shut — that is what '
        || 'most people will read, most of the year.'; end if;
  if length(btrim(p->>'open')) > 400 or length(btrim(p->>'closed')) > 400 then
    return 'The sign-up wording is too long. The limit is 400 characters each.'; end if;

  if length(p::text) > 12000 then
    return 'There is too much here. Shorten the opening paragraph or use fewer rows.';
  end if;
  return null;
end $fn$;

-- ---------------------------------------------------------------------------
--  3. Writing it
-- ---------------------------------------------------------------------------
create or replace function public.save_course_page(p_key text, p_page jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key  text := lower(btrim(p_key));
  v_mode text;
  v_why  text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change what the website says about a class.'
      using errcode = '42501';
  end if;

  select cohort_mode into v_mode from public.courses where key = v_key;
  if not found then
    raise exception 'There is no class with that website name. Create the class first, then write its page.'
      using errcode = 'no_data_found';
  end if;

  v_why := public.check_course_page(p_page, v_mode);
  if v_why is not null then
    raise exception '%', v_why using errcode = 'check_violation';
  end if;

  update public.courses set page = p_page where key = v_key;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'course_page_changed',
          jsonb_build_object('key', v_key,
                             'tagline', left(btrim(p_page->>'tagline'), 80)));

  return jsonb_build_object('key', v_key);
end $fn$;

-- ---------------------------------------------------------------------------
--  4. The website gets the copy too
--
--  Replaced whole so the page content rides along with what was already
--  public. Still anonymous, still nothing anybody typed into a form.
-- ---------------------------------------------------------------------------
create or replace function public.courses_public()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.key), '[]'::jsonb)
    from (
      select c.key, c.name, c.is_open, c.capacity, c.sort_order, c.cohort_mode, c.page,
             greatest(c.capacity - (
               select count(*) from public.course_registrations r
                where r.course_key = c.key
                  and r.outcome = 'place' and r.status = 'active'), 0) as places_left
        from public.courses c
    ) x;
$fn$;

revoke all on function public.check_course_page(jsonb, text)  from public, anon, authenticated;
revoke all on function public.save_course_page(text, jsonb)   from public, anon;
revoke all on function public.courses_public()                from public;

grant execute on function public.save_course_page(text, jsonb) to authenticated;
grant execute on function public.courses_public()              to anon, authenticated;

-- ---------------------------------------------------------------------------
--  5. The seed — what the two pages say TODAY
--
--  Extracted from the built page rather than retyped, so the editor opens
--  showing exactly what is live. The first attempt at that extraction had a
--  boundary bug and pulled in a thousand words of the charity collection form
--  as a "rule" of the Ghusl workshop; it was caught by printing the result
--  and reading it, which is the only reason this seed is right.
-- ---------------------------------------------------------------------------
insert into public.courses (key, name, cohort_mode, capacity, sort_order, page)
select v.key, c.name, c.cohort_mode, c.capacity, c.sort_order, v.page
  from (values
  ('arabic', '{"name": "Arabic Classes", "tagline": "Evening Arabic for adults, taught at the masjid — from the alphabet upward.", "facts": [{"k": "Time", "v": "7–8pm"}, {"k": "Places", "v": "15"}], "intro": "The aim is to get you reading and understanding the language of the Qur''an, not only reciting it. Classes start from the alphabet, so no previous study is assumed — and they run after the madrasah finishes, when the building is already open.", "rules": [{"k": "When", "v": "One evening a week, 7:00–8:00pm."}, {"k": "Who for", "v": "Adults aged 16 and over. Men''s and women''s classes are taught separately."}, {"k": "Places", "v": "Fifteen per class. Small on purpose — a language class stops working much beyond that."}, {"k": "Level", "v": "Complete beginners are welcome. Say roughly where you are when you register and you''ll be placed accordingly."}, {"k": "Signing up", "v": "Required — you cannot simply turn up. Places go in the order they are taken; after fifteen, the rest join a waiting list."}], "tile": {"tag": "Weekly · Adults 16+", "p": "Read and understand the language of the Qur''an, starting from the alphabet. No previous study assumed.", "meta": "One evening a week · 7–8pm · 15 places"}, "cohorts": [{"key": "mens", "label": "Men''s class"}, {"key": "womens", "label": "Women''s class"}], "exp_label": "How much Arabic do you have already?", "exp": [{"key": "none", "label": "None at all — starting from the alphabet"}, {"key": "some", "label": "I can read some, but don''t understand much"}, {"key": "confident", "label": "I read confidently and want to build on it"}], "open": "Fill in the form below. Places go in the order they are taken and you are told straight away whether you have one.", "closed": "Places are limited to fifteen per class and go in the order people sign up. Ring the office to put your name down in the meantime."}'::jsonb),
  ('ghusl', '{"name": "Ghusl Workshop", "tagline": "How to wash and prepare a body for burial — a duty that falls on the community, and one most people have never been shown.", "facts": [{"k": "Format", "v": "One session"}, {"k": "Places", "v": "15"}], "intro": "Washing the body of someone who has died is a fard kifayah — an obligation on the community as a whole rather than on any one person. As long as enough people can do it, the duty is discharged for everyone. Where nobody can, it falls on everyone.", "rules": [{"k": "Who for", "v": "Adults aged 16 and over. Men''s and women''s sessions are run separately, because men wash men and women wash women."}, {"k": "When", "v": "A one-off session, run periodically rather than to a fixed timetable. Register and the office will tell you when the next one is."}, {"k": "Places", "v": "Fifteen per session. After that, names go on the list for the session after."}, {"k": "Experience", "v": "None expected. Most people who come have never done it. Those who have are welcome too — the masjid needs more of you."}], "tile": {"tag": "Workshop · Adults 16+", "p": "How to wash and prepare a body for burial — taught properly, by people who do it.", "meta": "One-off session · run periodically · 15 places"}, "cohorts": [{"key": "mens", "label": "Men''s session"}, {"key": "womens", "label": "Women''s session"}], "exp_label": "Have you done this before?", "exp": [{"key": "none", "label": "No — I have never done it"}, {"key": "some", "label": "I have helped once or twice"}, {"key": "confident", "label": "I have done it a number of times"}], "open": "Register below and the office will contact you with the date of the next session.", "closed": "Sessions are announced when they are scheduled. Ring the office to be told about the next one."}'::jsonb)
       ) as v(key, page)
  join public.courses c on c.key = v.key
on conflict (key) do update set page = excluded.page
 where public.courses.page = '{}'::jsonb;

-- ---------------------------------------------------------------------------
--  6. Prove it, against the real table
-- ---------------------------------------------------------------------------
do $check$
declare
  r      record;
  v_why  text;
begin
  for r in select key, cohort_mode, page from public.courses loop
    if r.page = '{}'::jsonb then
      raise exception 'course % has no page content after the seed', r.key;
    end if;
    v_why := public.check_course_page(r.page, r.cohort_mode);
    if v_why is not null then
      raise exception 'the seed for % does not pass its own validator: %', r.key, v_why;
    end if;
  end loop;

  --  A fourth cohort is the mistake this whole migration is built around.
  if public.check_course_page(
       (select page from public.courses where key='arabic')
       || jsonb_build_object('cohorts', jsonb_build_array(
            jsonb_build_object('key','mens','label','Men'),
            jsonb_build_object('key','womens','label','Women'),
            jsonb_build_object('key','children','label','Children'))),
       'separate') is null then
    raise exception 'a made-up cohort was accepted — every sign-up against it '
                    'would be refused by course_registrations_cohort_check';
  end if;
  if public.check_course_page(
       (select page from public.courses where key='arabic'), 'single') is null then
    raise exception 'two cohorts were accepted for a single-session class';
  end if;
  if public.check_course_page(
       (select page from public.courses where key='arabic')
       || jsonb_build_object('closed', ''), 'separate') is null then
    raise exception 'empty closed wording was accepted'; end if;
  if public.check_course_page(
       (select page from public.courses where key='arabic')
       || jsonb_build_object('exp', jsonb_build_array(
            jsonb_build_object('key','a','label','x'))), 'separate') is null then
    raise exception 'a one-answer experience question was accepted'; end if;

  raise notice 'every seeded class passes its own validator, and four bad bodies are refused.';
end $check$;

commit;
