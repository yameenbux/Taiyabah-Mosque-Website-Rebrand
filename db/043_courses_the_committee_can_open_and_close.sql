-- ===========================================================================
--  043_courses_the_committee_can_open_and_close.sql
--  15 September 2026
--
--  `courses` holds the name, the capacity and the is_open switch for each
--  class, and register_for_course() reads all three. NOTHING COULD WRITE TO
--  IT. There is no function, no policy and no screen: the two rows in it were
--  put there by 004 and have never changed. So the masjid cannot close a class
--  that is full, cannot raise a capacity, and cannot rename one.
--
--  THE TRAP THIS HAD TO AVOID
--  --------------------------
--  Adding an open/close switch to the portal WITHOUT changing the public page
--  would have been worse than leaving it alone. register_for_course() raises
--  when a course is closed:
--
--      raise exception 'Sign-ups for % are closed at the moment', v_course.name;
--
--  and the website's course list is a hard-coded `COURSES` object with its own
--  idea of what is open. A committee member closing the Arabic class in the
--  portal would have changed nothing a visitor could see — they would have
--  filled in the whole form, pressed the button and been handed a raw 400.
--  The website reads courses_public() now, and the two halves went in
--  together. This is the third time on this project that half a feature was
--  the whole bug; the other two are written up in the README.
--
--  WHAT IS DELIBERATELY NOT HERE
--  -----------------------------
--  There is no delete. course_registrations has a foreign key to this table,
--  so deleting a class somebody signed up for would either fail with a
--  constraint error or, with a cascade, silently erase the record of people
--  who registered. Closing a class is the reversible thing and is what
--  somebody actually means.
--
--  There is no "add a wholly new kind of class" either, and that is a real
--  boundary rather than an oversight. The website holds more about a course
--  than this table does — which cohorts it runs, what the experience question
--  asks, the copy shown when it is closed — and none of that is in the
--  database. save_course() can create a row, but a row with no section on the
--  website is invisible. The screen says so in those words.
--
--  THE CONSTRAINTS ALREADY ON THIS TABLE, read from pg_constraint rather than
--  from a column listing, because 040 did the latter and got it wrong within
--  the hour:
--
--      courses_key_check           key ~ '^[a-z0-9_]{2,40}$'
--      courses_capacity_check      capacity between 1 and 500
--      courses_cohort_mode_check   cohort_mode in ('separate', 'single')
--      every column NOT NULL
--
--  check_course() below says the same things in English. Where the two
--  disagree a volunteer is told a class is fine and then handed a raw
--  constraint name, which is exactly what 041 exists to stop.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. What the website is allowed to know
--
--  Anonymous. It returns the name, whether sign-ups are open, the capacity and
--  how many places are left — no registration, no person, nothing anybody
--  typed. A visitor is already told the places left the moment they register;
--  telling them beforehand is strictly more honest.
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
      select c.key, c.name, c.is_open, c.capacity, c.sort_order,
             greatest(c.capacity - (
               select count(*) from public.course_registrations r
                where r.course_key = c.key
                  and r.outcome = 'place' and r.status = 'active'), 0) as places_left
        from public.courses c
    ) x;
$fn$;

-- ---------------------------------------------------------------------------
--  2. What the portal sees
-- ---------------------------------------------------------------------------
create or replace function public.courses_admin_list()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may manage the classes.'
      using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.sort_order, x.key)
      from (
        select c.key, c.name, c.cohort_mode, c.capacity, c.is_open, c.sort_order,
               (select count(*) from public.course_registrations r
                 where r.course_key = c.key
                   and r.outcome = 'place' and r.status = 'active') as taken,
               (select count(*) from public.course_registrations r
                 where r.course_key = c.key
                   and r.outcome = 'waiting' and r.status = 'active') as waiting
          from public.courses c
      ) x
  ), '[]'::jsonb);
end $fn$;

-- ---------------------------------------------------------------------------
--  3. The rules, in English
-- ---------------------------------------------------------------------------
create or replace function public.check_course(p jsonb)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $fn$
declare
  v_key  text := lower(btrim(coalesce(p->>'key', '')));
  v_name text := btrim(coalesce(p->>'name', ''));
  v_mode text := lower(btrim(coalesce(p->>'cohort_mode', '')));
  v_cap  text := nullif(btrim(coalesce(p->>'capacity', '')), '');
  v_sort text := nullif(btrim(coalesce(p->>'sort_order', '')), '');
begin
  if v_key = '' then
    return 'A class needs a short name for the website to use, like arabic.';
  end if;
  if v_key !~ '^[a-z0-9_]{2,40}$' then
    return 'The website name must be 2 to 40 characters, lower case letters, '
        || 'numbers and underscores only — like arabic or ghusl. No spaces.';
  end if;
  if v_name = '' then
    return 'A class needs a name people will read, like Arabic Classes.';
  end if;
  if length(v_name) > 80 then
    return 'That name is ' || length(v_name) || ' characters. The limit is 80.';
  end if;
  if v_mode not in ('separate', 'single') then
    return 'Choose whether the class runs separate sessions for men and women, '
        || 'or a single session.';
  end if;
  if v_cap is null or v_cap !~ '^[0-9]+$' then
    return 'How many places are there? It has to be a whole number.';
  end if;
  if v_cap::int < 1 or v_cap::int > 500 then
    return 'Places must be between 1 and 500. It is ' || v_cap || '.';
  end if;
  if v_sort is not null and v_sort !~ '^[0-9]{1,4}$' then
    return 'The order has to be a whole number.';
  end if;
  return null;
end $fn$;

-- ---------------------------------------------------------------------------
--  4. Writing one
--
--  LOWERING A CAPACITY BELOW WHAT IS ALREADY TAKEN IS REFUSED, and this is the
--  only interesting thing in here. Postgres would accept it happily — the
--  CHECK only says 1 to 500 — and register_for_course() compares the count
--  against the capacity, so the class would simply behave as full. But the
--  people over the new line have already been told they have a place. The
--  masjid would be quietly holding sixteen names for fifteen seats and nobody
--  would know until the evening itself.
-- ---------------------------------------------------------------------------
create or replace function public.save_course(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key   text := lower(btrim(coalesce(p->>'key', '')));
  v_why   text;
  v_new   boolean;
  v_taken integer;
  v_cap   integer;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the classes.'
      using errcode = '42501';
  end if;

  v_why := public.check_course(p);
  if v_why is not null then
    raise exception '%', v_why using errcode = 'check_violation';
  end if;

  v_cap := (p->>'capacity')::int;
  v_new := not exists (select 1 from public.courses where key = v_key);

  select count(*) into v_taken
    from public.course_registrations
   where course_key = v_key and outcome = 'place' and status = 'active';

  if v_cap < v_taken then
    raise exception 'There are already % people holding a place on that class, so it cannot be set to % places. Move somebody to the waiting list first.',
      v_taken, v_cap using errcode = 'check_violation';
  end if;

  insert into public.courses (key, name, cohort_mode, capacity, sort_order)
  values (v_key, btrim(p->>'name'), lower(btrim(p->>'cohort_mode')), v_cap,
          coalesce(nullif(btrim(coalesce(p->>'sort_order', '')), '')::int, 0))
  on conflict (key) do update
    set name        = excluded.name,
        cohort_mode = excluded.cohort_mode,
        capacity    = excluded.capacity,
        sort_order  = excluded.sort_order;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), case when v_new then 'course_created' else 'course_edited' end,
          jsonb_build_object('key', v_key, 'name', btrim(p->>'name'),
                             'capacity', v_cap));

  return jsonb_build_object('key', v_key, 'is_new', v_new, 'taken', v_taken);
end $fn$;

-- ---------------------------------------------------------------------------
--  5. Opening and closing sign-ups
-- ---------------------------------------------------------------------------
create or replace function public.set_course_open(p_key text, p_open boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_name text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may open or close sign-ups.'
      using errcode = '42501';
  end if;

  update public.courses set is_open = p_open
   where key = lower(btrim(p_key))
  returning name into v_name;

  if not found then
    raise exception 'There is no class with that name on the website.'
      using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), case when p_open then 'course_opened' else 'course_closed' end,
          jsonb_build_object('key', lower(btrim(p_key)), 'name', v_name));

  return jsonb_build_object('key', lower(btrim(p_key)), 'is_open', p_open);
end $fn$;

-- ---------------------------------------------------------------------------
--  6. Grants
--
--  courses_public() is the ONLY one anon may call, and it is the only one that
--  returns nothing anybody typed into a form.
-- ---------------------------------------------------------------------------
revoke all on function public.courses_public()                  from public;
revoke all on function public.courses_admin_list()              from public, anon;
revoke all on function public.check_course(jsonb)               from public, anon;
revoke all on function public.save_course(jsonb)                from public, anon;
revoke all on function public.set_course_open(text, boolean)    from public, anon;

grant execute on function public.courses_public()               to anon, authenticated;
grant execute on function public.courses_admin_list()           to authenticated;
grant execute on function public.save_course(jsonb)             to authenticated;
grant execute on function public.set_course_open(text, boolean) to authenticated;

-- ---------------------------------------------------------------------------
--  7. Prove the validator and the table agree, against the real table
--
--  The same DO block 041 uses, for the same reason. Every case is rolled back.
-- ---------------------------------------------------------------------------
do $check$
declare
  v_case  jsonb;
  v_why   text;
  v_cases jsonb := jsonb_build_array(
    jsonb_build_object('key','probe_a','name','A class','cohort_mode','separate',
                       'capacity','15','sort_order','3'),
    jsonb_build_object('key','probe_b','name','Another','cohort_mode','single',
                       'capacity','1','sort_order','0'),
    jsonb_build_object('key','probe_c','name','At the ceiling','cohort_mode','single',
                       'capacity','500','sort_order','9999'),
    jsonb_build_object('key','ab','name','Shortest key allowed','cohort_mode','single',
                       'capacity','10')
  );
begin
  for v_case in select * from jsonb_array_elements(v_cases) loop
    v_why := public.check_course(v_case);
    if v_why is not null then
      raise exception 'check_course() refuses a case it should accept: % -> %', v_case, v_why;
    end if;
    begin
      insert into public.courses (key, name, cohort_mode, capacity, sort_order)
      values (v_case->>'key', v_case->>'name', v_case->>'cohort_mode',
              (v_case->>'capacity')::int,
              coalesce((v_case->>'sort_order')::int, 0));
    exception when check_violation then
      raise exception 'check_course() ACCEPTS a class the table REFUSES: %', v_case;
    end;
  end loop;

  --  And the refusals have to be real.
  if public.check_course(jsonb_build_object('key','Arabic Class','name','x',
       'cohort_mode','single','capacity','10')) is null then
    raise exception 'a key with a capital and a space was accepted'; end if;
  if public.check_course(jsonb_build_object('key','ok','name','x',
       'cohort_mode','mixed','capacity','10')) is null then
    raise exception 'an unknown cohort mode was accepted'; end if;
  if public.check_course(jsonb_build_object('key','ok','name','x',
       'cohort_mode','single','capacity','501')) is null then
    raise exception 'a capacity of 501 was accepted'; end if;
  if public.check_course(jsonb_build_object('key','ok','name','x',
       'cohort_mode','single','capacity','0')) is null then
    raise exception 'a capacity of 0 was accepted'; end if;
  if public.check_course(jsonb_build_object('key','a','name','x',
       'cohort_mode','single','capacity','10')) is null then
    raise exception 'a one-character key was accepted'; end if;

  --  Leave nothing behind. A class nobody created, sitting in the committee's
  --  list, is worse than no test.
  delete from public.courses where key in ('probe_a','probe_b','probe_c','ab');

  raise notice 'check_course() and the table agree on 4 cases and refuse 5.';
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select public.courses_public();        -- as anon: two rows, no people
--    select public.courses_admin_list();    -- as a verified admin: plus counts
--
--  And the one that matters, as anon:
--
--    select public.save_course('{}'::jsonb);
--        -> ERROR: permission denied for function save_course
--
--  If that succeeds, anybody holding the anon key — which is in the page
--  source of every page on this site — can open a class, set its capacity to
--  500 and rename it.
-- ===========================================================================
