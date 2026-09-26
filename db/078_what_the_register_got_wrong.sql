--  078  WHAT THE REGISTER GOT WRONG
--
--  077 put 552 children into the madrasah and checked that the numbers
--  reconciled. They did. This file is what three sanity checks found AFTER
--  the numbers reconciled, which is the more interesting question: a register
--  can be arithmetically perfect and still be wrong about a child.
--
--  Applied to the live project as two migrations:
--    two_spaces_made_a_second_class
--    dates_of_birth_that_want_a_second_look
--
--  Both are reproduced here in full. This file is the repository's record of
--  them; it is not re-run against a database that already has them.
--
--  ======================================================================
--  ONE. TWO SPACES MADE A SECOND CLASS
--  ======================================================================
--
--  The register spells three class names with a double space - "Boys Hafiz
--  Class - C", "Play and Pray 1  - 26/27", "Play and Pray 2  - 26/27" - where
--  the September load of the same three used one. The import matches classes
--  on the name, did not recognise them, and made a second copy of each. The
--  roll went to the new copy and the old one sat beside it holding nobody.
--
--  No child was lost and no child was misplaced: the counts in 077 were right
--  because all the pupils went to the same three new classes. But a staff list
--  showing "Boys Hafiz Class - C" twice, one of them empty, is how somebody
--  marks a register against the wrong one on a wet Tuesday.
--
--  The merge keeps whichever copy holds the pupils and moves everything that
--  points at the other. The classes the register does not mention at all -
--  Boys Year 10, Girls Further Education, Ladies Aalimah Class, and the
--  "Unlisted" bucket from the 18 September load, all of them empty - are made
--  INACTIVE rather than deleted, because an archive row may still name them.

do $$
declare v_m uuid; r record; keep uuid; drop_id uuid; moved int := 0; merged int := 0;
begin
  select id into v_m from public.masjids order by created_at limit 1;

  for r in
    select regexp_replace(btrim(name), '\s+', ' ', 'g') as tidy,
           array_agg(id order by (select count(*) from public.madrasah_pupil_classes pc
                                   where pc.class_id = c.id) desc, c.created_at) as ids
    from public.madrasah_classes c
    where c.masjid_id = v_m
    group by 1 having count(*) > 1
  loop
    keep := r.ids[1];
    foreach drop_id in array r.ids[2:array_length(r.ids,1)]
    loop
      update public.madrasah_pupil_classes pc set class_id = keep
       where pc.class_id = drop_id
         and not exists (select 1 from public.madrasah_pupil_classes x
                          where x.pupil_id = pc.pupil_id and x.class_id = keep);
      get diagnostics moved = row_count;
      delete from public.madrasah_pupil_classes where class_id = drop_id;
      delete from public.madrasah_staff_classes  where class_id = drop_id;
      update public.madrasah_classes set main_teacher_id = coalesce(main_teacher_id,
             (select main_teacher_id from public.madrasah_classes where id = drop_id))
       where id = keep;
      delete from public.madrasah_classes where id = drop_id;
      merged := merged + 1;
    end loop;
    update public.madrasah_classes set name = r.tidy where id = keep;
  end loop;

  update public.madrasah_classes
     set name = regexp_replace(btrim(name), '\s+', ' ', 'g')
   where masjid_id = v_m and name <> regexp_replace(btrim(name), '\s+', ' ', 'g');

  update public.madrasah_classes c
     set is_active = false
   where c.masjid_id = v_m
     and c.is_active
     and not exists (select 1 from public.madrasah_pupil_classes pc where pc.class_id = c.id)
     and not exists (select 1 from public.import_classes ic
                      where regexp_replace(btrim(ic.class_name), '\s+', ' ', 'g')
                          = regexp_replace(btrim(c.name), '\s+', ' ', 'g'));

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_m, 'classes_tidied',
          jsonb_build_object('merged_duplicates', merged,
                             'why', 'the register spells three class names with a '
                                 || 'double space; the September load used one'));
end $$;

--  CHECK 1. No two classes differ only by whitespace.
do $$
declare n int;
begin
  select count(*) into n from (
    select regexp_replace(btrim(name), '\s+', ' ', 'g') t
    from public.madrasah_classes group by 1 having count(*) > 1) q;
  if n > 0 then
    raise exception 'CHECK 1 FAILED: % class names still collide once spacing is ignored', n;
  end if;
end $$;

--  CHECK 2. NOT ONE CHILD LOST A CLASS PLACE.
--  This is the check that matters. Merging classes MOVES rows, and a move that
--  silently drops one leaves a child in no class at all - which looks like
--  nothing on screen. Counting the places and counting the classless children
--  are two different questions and both are asked.
do $$
declare places int; want int; classless int;
begin
  select count(*) into places from public.madrasah_pupil_classes;
  select count(*) into want from (
    select distinct btrim(legacy_id) a,
           regexp_replace(lower(btrim(class_name)), '\s+', ' ', 'g') b
    from public.import_pupils where coalesce(btrim(class_name),'') <> '') q;
  if places <> want then
    raise exception 'CHECK 2 FAILED: % class places, the register asks for %', places, want;
  end if;
  select count(*) into classless from public.madrasah_pupils p
   where p.left_on is null
     and not exists (select 1 from public.madrasah_pupil_classes pc where pc.pupil_id = p.id);
  if classless <> 1 then
    raise exception 'CHECK 2 FAILED: % pupils are in no class; the register has exactly 1', classless;
  end if;
end $$;

--  CHECK 3. Every class the register names is present and active.
do $$
declare missing text;
begin
  select string_agg(ic.class_name, ', ') into missing
  from public.import_classes ic
  where not exists (
    select 1 from public.madrasah_classes c
     where regexp_replace(btrim(c.name), '\s+', ' ', 'g')
         = regexp_replace(btrim(ic.class_name), '\s+', ' ', 'g')
       and c.is_active);
  if missing is not null then
    raise exception 'CHECK 3 FAILED: the register names classes that are not here: %', missing;
  end if;
end $$;


--  ======================================================================
--  TWO. DATES OF BIRTH THAT WANT A SECOND LOOK
--  ======================================================================
--
--  The register carries nine dates of birth that cannot be right: a 51 year
--  old in Boys Year 6, three 3 year olds in Ladies Naazirah, a four year old
--  in Boys Year 8, a four year old in Girls Further Education A, a nine year
--  old in a hafiz class, a 28 year old in Girls THAANIYAH, and one date
--  entered as 1 January. They are almost certainly mistyped years. Only a
--  parent can settle one, so nothing here changes a date. It makes them
--  findable.
--
--  HOW THE RULE WAS ARRIVED AT, because the obvious rules are all wrong and
--  each of them looked right until it was run:
--
--    "flag an age far from the class median" fires 41 times, and 37 of those
--    are Ladies classes where a 21-to-64 spread is exactly what an adult class
--    looks like. A flag that is wrong nine times in ten is a flag the
--    committee learns to ignore, which is worse than having no flag at all.
--
--    "flag anyone under five" fires 55 times, 53 of them on Play and Pray and
--    Reception, which EXIST for three and four year olds.
--
--    "flag anyone outside their own class's range" cannot catch the three
--    3 year olds in Ladies Naazirah, because three of them together widen the
--    very range being measured against.
--
--  So no single test does it, and the temptation is to reach for a cleverer
--  statistic. Three plain tests do it instead, each working in one direction,
--  plus the placeholder date. Together they fire nine times and not once on a
--  correct enrolment.
--
--  ALSO FIXED HERE: a pupil's own e-mail address now counts as a contact.
--  Three adult students in the Ladies classes have no guardian - they ARE the
--  adult - and the roll was calling them unreachable while holding their
--  e-mail address. "No way to ring" fell from 10 to 3.

create or replace function public.madrasah_dob_to_check()
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select case when not public.verified_madrasah() then jsonb_build_object('allowed', false)
  else jsonb_build_object('allowed', true, 'rows', coalesce((
    with a as (
      select p.id, p.legacy_ref, p.first_name, p.last_name, p.date_of_birth,
             c.id as cid, c.name as class,
             date_part('year', age(current_date, p.date_of_birth))::int as age
        from public.madrasah_pupils p
        join public.madrasah_pupil_classes pc on pc.pupil_id = p.id
        join public.madrasah_classes c on c.id = pc.class_id
       where p.masjid_id = public.current_masjid()
         and p.left_on is null and p.date_of_birth is not null),
    m as (select cid, percentile_cont(0.5) within group (order by age) as med
            from a group by cid)
    select jsonb_agg(jsonb_build_object(
             'id',    a.id,
             'legacy_ref', a.legacy_ref,
             'name',  btrim(concat_ws(' ', a.first_name, a.last_name)),
             'class', a.class,
             'date_of_birth', a.date_of_birth,
             'age',   a.age,
             'class_normally', round(m.med),
             'why',   case
                        when a.age > 25 and m.med < 18
                          then 'An adult in a children''s class.'
                        when a.age < 11 and m.med > 25
                          then 'A young child in an adult class.'
                        when m.med < 18 and a.age < m.med - 6
                          then 'Much younger than the rest of the class.'
                        else 'The date is 1 January, which is usually a placeholder.'
                      end)
           order by a.class)
      from a join m on m.cid = a.cid
     where (a.age > 25 and m.med < 18)
        or (a.age < 11 and m.med > 25)
        or (m.med < 18 and a.age < m.med - 6)
        or to_char(a.date_of_birth, 'MM-DD') = '01-01'), '[]'::jsonb)) end;
$$;

revoke all on function public.madrasah_dob_to_check() from public, anon;
grant execute on function public.madrasah_dob_to_check() to authenticated;

--  madrasah_roll() and madrasah_roll_health() are replaced in the applied
--  migration to carry 'age', the corrected 'has_contact'/'no_contact' and the
--  'dob_to_check' count. Their full definitions live with 077, which is where
--  the WHETHER-not-WHAT rule that governs them is written down; only the two
--  changed expressions are noted here:
--
--    has_contact:  coalesce(btrim(p.email),'') <> '' OR <a guardian has one>
--    no_contact:   coalesce(btrim(p.email),'') =  '' AND <no guardian has one>
--    dob_to_check: jsonb_array_length(madrasah_dob_to_check() -> 'rows')

--  CHECK 4. The rule fires on the nine and on nothing else. A detector that
--  is never tested against a correct enrolment is a detector nobody has
--  checked the false positives of.
do $$
declare n int; on_play int;
begin
  select coalesce(jsonb_array_length(
    (select jsonb_agg(x) from (
      with a as (
        select p.id, p.date_of_birth, c.id cid, c.name class,
               date_part('year', age(current_date, p.date_of_birth))::int age
          from public.madrasah_pupils p
          join public.madrasah_pupil_classes pc on pc.pupil_id = p.id
          join public.madrasah_classes c on c.id = pc.class_id
         where p.left_on is null and p.date_of_birth is not null),
      m as (select cid, percentile_cont(0.5) within group (order by age) med
              from a group by cid)
      select a.id from a join m on m.cid = a.cid
       where (a.age > 25 and m.med < 18) or (a.age < 11 and m.med > 25)
          or (m.med < 18 and a.age < m.med - 6)
          or to_char(a.date_of_birth,'MM-DD') = '01-01') x)), 0) into n;

  --  The false-positive half: Play and Pray and Reception are FOR three and
  --  four year olds and must never appear.
  select count(*) into on_play from (
    with a as (
      select p.id, p.date_of_birth, c.id cid, c.name class,
             date_part('year', age(current_date, p.date_of_birth))::int age
        from public.madrasah_pupils p
        join public.madrasah_pupil_classes pc on pc.pupil_id = p.id
        join public.madrasah_classes c on c.id = pc.class_id
       where p.left_on is null and p.date_of_birth is not null),
    m as (select cid, percentile_cont(0.5) within group (order by age) med
            from a group by cid)
    select a.id from a join m on m.cid = a.cid
     where a.class ~* '(Play and Pray|Reception)'
       and ((a.age > 25 and m.med < 18) or (a.age < 11 and m.med > 25)
         or (m.med < 18 and a.age < m.med - 6))) q;

  if on_play > 0 then
    raise exception 'CHECK 4 FAILED: the rule flags % correct Play and Pray or Reception enrolments', on_play;
  end if;
  raise notice 'CHECK 4 passed: % dates to check, 0 of them a correct infant enrolment', n;
end $$;
