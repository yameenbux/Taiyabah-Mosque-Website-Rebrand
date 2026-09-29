--  =====================================================================
--  115 - COUNT-ONLY COMPANIONS FOR THE FUNCTIONS THAT RETURN PEOPLE
--  28 September 2026
--  =====================================================================
--  CLAUDE.md's rule ("select named scalar fields, never whole rows",
--  strengthened after db/108 to name the specific functions) has now been
--  broken twice in one day AFTER being written down and quoted in the
--  dispatch brief: 44 teachers' names during Task 7's verification, then
--  3 more during Task 11's, each time a bare call to a function whose job
--  is to return names, made only to read a count off it.
--
--  Telling people to be careful is the weakest control there is, and it
--  has now visibly failed twice. The structural fix is not a third
--  warning - it is removing the reason anyone reaches for the naming
--  function at all. These four functions are, today, the ONLY way to ask
--  "how many" about a register, a history, a class list, or a roll. This
--  migration adds a same-gated, same-scoped sibling to each that answers
--  the number and assembles nobody - no name, no jsonb_agg of rows, no
--  join to madrasah_staff or madrasah_pupils' name columns anywhere in
--  the body.
--
--  Every companion below:
--    * takes the same arguments as its parent, with the same defaults;
--    * runs the same verified_madrasah()/is_teacher() gate, refusing the
--      same people the parent refuses, in the same words
--      ({'allowed': false});
--    * carries the SAME current_masjid() scoping - a foreign class still
--      reads {'allowed': false}, never a count for a class that is not
--      this masjid's. A count that leaked across masjids would be a
--      smaller copy of the IDOR db/104 closed, and this migration is not
--      the place to reopen it a fifth of the way.
--    * is SECURITY DEFINER, owned by postgres, same search_path, and gets
--      the exact same grants as its parent (authenticated only - never
--      anon, never public).
--
--  ONE DELIBERATE DIFFERENCE: register_history() writes an admin_audit row
--  on every real read, because reading it discloses a child's marks and
--  who corrected them. register_history_count() discloses nothing about
--  any child - it returns a number - so it does not audit and stays
--  STABLE rather than VOLATILE. Auditing a function that names no one
--  would be ceremony, and db/114 is the standing reminder of what a wrong
--  volatility declaration costs when nobody calls the function to check.

--  ---------------------------------------------------------------------
--  registers_missing_count() - same two-step date/class derivation as
--  registers_missing() (db/104), same probe-class trick, but the final
--  step is a bare count(*) over class ids and dates - it never joins
--  madrasah_staff or selects a class name, so there is nothing in the
--  body capable of returning a person.
--  ---------------------------------------------------------------------
create or replace function public.registers_missing_count(
  p_from date default (current_date - 14), p_to date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_probe_class uuid;
  v_due_dates date[];
  v_sample_date date;
  v_due_classes uuid[];
  v_count integer;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;

  select c.id into v_probe_class
    from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active
     and exists (select 1 from public.madrasah_pupil_classes pc
                   join public.madrasah_pupils p on p.id = pc.pupil_id
                  where pc.class_id = c.id and p.left_on is null
                    and p.status = 'on_roll')
   limit 1;

  if v_probe_class is null then
    return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to, 'count', 0);
  end if;

  select array_agg(d::date) into v_due_dates
    from generate_series(p_from, p_to, interval '1 day') d
   where (public.register_due(v_probe_class, d::date) ->> 'due')::boolean;

  if v_due_dates is null or array_length(v_due_dates, 1) is null then
    return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to, 'count', 0);
  end if;

  v_sample_date := v_due_dates[1];
  select array_agg(c.id) into v_due_classes
    from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active
     and (public.register_due(c.id, v_sample_date) ->> 'due')::boolean;

  select count(*) into v_count
    from unnest(v_due_classes) as cls(class_id)
    cross join unnest(v_due_dates) as dd(on_date)
   where not exists (select 1 from public.madrasah_registers rg
                      where rg.class_id = cls.class_id and rg.on_date = dd.on_date
                        and rg.state = 'submitted');

  return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to,
                            'count', coalesce(v_count, 0));
end $$;

--  ---------------------------------------------------------------------
--  register_history_count() - same class-exists-and-is-ours check as
--  register_history() (db/104), a bare count(*) on madrasah_attendance_log
--  in place of the jsonb_agg of children/marks/reasons/writers, and no
--  admin_audit insert (see the note above).
--  ---------------------------------------------------------------------
create or replace function public.register_history_count(p_class uuid, p_date date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid(); v_count integer;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;

  if not exists (select 1 from public.madrasah_classes c
                  where c.id = p_class and c.masjid_id = v_masjid) then
    return jsonb_build_object('allowed', false);
  end if;

  select count(*) into v_count
    from public.madrasah_attendance_log l
   where l.class_id = p_class and l.on_date = p_date;

  return jsonb_build_object('allowed', true, 'count', coalesce(v_count, 0));
end $$;

--  ---------------------------------------------------------------------
--  madrasah_registers_list_count() - same office/teacher/mine-only branch
--  as madrasah_registers_list() (db/113), same masjid scope and same
--  teacher-owns-this-class exists() clause, but counts classes instead of
--  building a row per class with its teacher's name, roll and marks.
--  ---------------------------------------------------------------------
create or replace function public.madrasah_registers_list_count(p_date date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_office boolean := public.verified_madrasah();
  v_teacher boolean := public.is_teacher();
  v_staff uuid := public.my_staff_id();
  v_count integer;
begin
  if not (v_office or v_teacher) then
    return jsonb_build_object('allowed', false);
  end if;

  if v_teacher and not v_office and v_staff is null then
    return jsonb_build_object('allowed', true, 'on_date', p_date,
      'mine_only', true, 'permitted', public.attendance_permitted(), 'count', 0);
  end if;

  select count(*) into v_count
    from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active
     and (v_office
          or c.main_teacher_id = v_staff
          or exists (select 1 from public.madrasah_staff_classes sc
                      where sc.class_id = c.id and sc.staff_id = v_staff));

  return jsonb_build_object('allowed', true, 'on_date', p_date,
                            'mine_only', (v_teacher and not v_office),
                            'permitted', public.attendance_permitted(),
                            'count', coalesce(v_count, 0));
end $$;

--  ---------------------------------------------------------------------
--  madrasah_roll_count() - same verified_madrasah() gate and
--  current_masjid() scope as madrasah_roll(), a bare count(*) on
--  madrasah_pupils in place of the per-pupil name/DOB/medical/contact
--  object. This is the one to reach for when the question is "how many
--  pupils" (552, or whatever it is today) rather than who they are.
--  ---------------------------------------------------------------------
create or replace function public.madrasah_roll_count()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select case when not public.verified_madrasah() then jsonb_build_object('allowed', false)
  else jsonb_build_object('allowed', true, 'count', (
    select count(*) from public.madrasah_pupils p
     where p.masjid_id = public.current_masjid())) end;
$$;

--  ---------------------------------------------------------------------
--  GRANTS - same discipline as db/104's restatement: authenticated only,
--  never anon, never public. Written out here rather than left to
--  whatever a bare CREATE would default to, so a standalone replay of
--  this file cannot expose a count function to anon the way db/102's I4
--  found could happen to a names function.
--  ---------------------------------------------------------------------
revoke all on function public.registers_missing_count(date, date) from public, anon;
revoke all on function public.register_history_count(uuid, date) from public, anon;
revoke all on function public.madrasah_registers_list_count(date) from public, anon;
revoke all on function public.madrasah_roll_count() from public, anon;
grant execute on function public.registers_missing_count(date, date) to authenticated;
grant execute on function public.register_history_count(uuid, date) to authenticated;
grant execute on function public.madrasah_registers_list_count(date) to authenticated;
grant execute on function public.madrasah_roll_count() to authenticated;
