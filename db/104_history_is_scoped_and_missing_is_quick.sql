--  =====================================================================
--  104 - HISTORY IS SCOPED, AND MISSING IS QUICK
--  28 September 2026
--  =====================================================================
--  Fix round 1 of 5 on db/103. That file is applied and is the record; it
--  is not edited. This is a correction on top of it, the same way db/094
--  corrected db/093 and db/102 corrected db/097.
--
--  One critical fix, one performance fix. register_due() ITSELF IS NOT
--  TOUCHED - Tasks 7 and 10 depend on its current behaviour, and it is
--  correct. Both fixes below change how the two report functions USE it,
--  never the function.

--  ---------------------------------------------------------------------
--  CRITICAL - register_history() HAD NO MASJID SCOPE ON p_class.
--  ---------------------------------------------------------------------
--  verified_madrasah() proves the caller is aal2 with an office role AT
--  THEIR OWN current_masjid(). It says nothing about which masjid p_class
--  belongs to. Both sibling functions in db/103 scope it -
--  registers_missing() joins madrasah_classes on c.masjid_id = v_masjid,
--  and register_due() (db/095) does the same - but register_history()
--  went straight to madrasah_attendance_log on class_id alone. It is the
--  one function of the three that returns children's names, marks,
--  reasons and who wrote them.
--
--  RLS does not save this: madrasah_attendance_log has
--  relforcerowsecurity = false and the function is SECURITY DEFINER
--  owned by postgres, so it runs as the table owner and table policies
--  never apply. The masjid check has to be IN the function.
--
--  Not exploitable today - one masjid, an empty log - proved that anyway,
--  not assumed: see this task's report for a throwaway second masjid and
--  a throwaway class, showing the LIVE (pre-fix) function answering
--  {"allowed": true} for a class in a masjid the caller does not belong
--  to, then {"allowed": false} for the same class once this file is
--  applied. Nothing about a real masjid, class or child was touched to
--  prove it, and the throwaway rows were rolled back, not deleted.
create or replace function public.register_history(p_class uuid, p_date date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid(); v_rows jsonb;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;

  if not exists (select 1 from public.madrasah_classes c
                  where c.id = p_class and c.masjid_id = v_masjid) then
    --  SAME ANSWER a non-office caller gets, and the same answer a class
    --  that simply does not exist gets. A refusal that read differently
    --  for "not your class" versus "no such class" would itself leak
    --  whether a class id belongs to some OTHER masjid.
    return jsonb_build_object('allowed', false);
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.written_at desc), '[]'::jsonb)
    into v_rows
  from (
    select btrim(p.first_name || ' ' || p.last_name) as child,
           l.mark, l.reason, l.source,
           l.was_mark, l.was_reason, l.was_source,
           l.written_at,
           coalesce(pr.full_name, '(system)') as written_by
      from public.madrasah_attendance_log l
      join public.madrasah_pupils p on p.id = l.pupil_id
      left join public.profiles pr on pr.id = l.written_by
     where l.class_id = p_class and l.on_date = p_date
  ) x;
  return jsonb_build_object('allowed', true, 'rows', v_rows);
end $$;

--  ---------------------------------------------------------------------
--  IMPORTANT - registers_missing() AND my_registers_outstanding() CALLED
--  register_due() ONCE PER (date, class) CELL OF A CROSS JOIN.
--  ---------------------------------------------------------------------
--  Measured on production before this fix: registers_missing()'s default
--  14-day window over 44 active classes took ~920-990ms across repeated
--  runs, EXPLAIN (ANALYZE, BUFFERS) showing ~20,370 shared buffer hits for
--  register_due() called up to 660 times (15 dates x 44 classes). Cheap on
--  its own, ruinous 660 times over, and Task 10 was about to copy this
--  exact shape onto more screens.
--
--  register_due()'s own logic (db/095) is a conjunction of two
--  INDEPENDENT halves, read straight off its source: four early checks -
--  register_days() is set, the date sits in the current academic year,
--  the day of week is a register day, no closure covers it - which
--  mention v_masjid and p_date and NEVER p_class; then one final check -
--  the class is active and has someone on its roll - which mentions
--  p_class and NEVER p_date. Calling it once per (date, class) cell
--  re-derives the date half up to 44 times over and the class half up to
--  15 times over, for a window this size.
--
--  THE HOIST, done with register_due() itself rather than by duplicating
--  its logic here (so there is exactly one place, db/095, that says what
--  "due" means):
--
--    Step 1 - pick ONE class already known to pass the CLASS half on its
--    own (active, someone on roll). Calling register_due() with it for
--    every date in the window then reduces to exactly the DATE half,
--    because that is the only half left that can still say no. One call
--    per date (~15), not one per cell.
--
--    Step 2 - the reverse trick. Take any ONE date step 1 already proved
--    passes the DATE half. Calling register_due() with it for every class
--    then reduces to exactly the CLASS half. One call per class (~44),
--    not one per cell.
--
--    Step 3 - cross-join the two small survivor sets, filtered by "not
--    already submitted", same as before. Zero further calls to
--    register_due(): it has now run ~15 + ~44 times, not ~660.
--
--  This is sound because closures and register_days are masjid-wide, not
--  per-class (madrasah_closures carries no class_id), and the roster
--  check reads the CURRENT state of madrasah_pupil_classes/madrasah_pupils,
--  not a date-scoped attendance table - so neither half can vary along the
--  axis the other half is being tested across. If that ever stops being
--  true - a per-class register calendar, say - this hoist stops being
--  valid and must be revisited alongside register_due() itself.
--
--  BEHAVIOUR MUST BE IDENTICAL, and is proved to be in this task's report:
--  the exact set of (class_id, on_date) pairs both functions return,
--  hashed rather than pasted (registers_missing() carries a teacher's
--  name per row), matches before and after, for both the office and the
--  test teacher. The admin's count (484) does not move.
create or replace function public.registers_missing(
  p_from date default (current_date - 14), p_to date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_probe_class uuid;
  v_due_dates date[];
  v_sample_date date;
  v_due_classes uuid[];
  v_rows jsonb;
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
    --  No class in this masjid can ever pass the class half - nothing can
    --  be due regardless of date, so there is nothing to report.
    return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to,
                              'count', 0, 'rows', '[]'::jsonb);
  end if;

  select array_agg(d::date) into v_due_dates
    from generate_series(p_from, p_to, interval '1 day') d
   where (public.register_due(v_probe_class, d::date) ->> 'due')::boolean;

  if v_due_dates is null or array_length(v_due_dates, 1) is null then
    return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to,
                              'count', 0, 'rows', '[]'::jsonb);
  end if;

  v_sample_date := v_due_dates[1];
  select array_agg(c.id) into v_due_classes
    from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active
     and (public.register_due(c.id, v_sample_date) ->> 'due')::boolean;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.on_date desc, x.name), '[]'::jsonb)
    into v_rows
  from (
    select cls.class_id, cls.name, cls.teacher, dd.on_date
      from (
        select c.id as class_id, c.name,
               btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name)) as teacher
          from public.madrasah_classes c
          left join public.madrasah_staff st on st.id = c.main_teacher_id
         where c.id = any(v_due_classes)
      ) cls
      cross join unnest(v_due_dates) as dd(on_date)
     where not exists (select 1 from public.madrasah_registers rg
                        where rg.class_id = cls.class_id and rg.on_date = dd.on_date
                          and rg.state = 'submitted')
  ) x;
  return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to,
                            'count', jsonb_array_length(v_rows), 'rows', v_rows);
end $$;

--  A DIFFERENT SHAPE FROM registers_missing(), on purpose.
--  registers_missing()'s per-class filter (c.masjid_id = v_masjid) is a
--  plain column comparison - free to evaluate twice. teaches_class() is
--  not: it calls my_staff_id() and current_masjid() internally and, when
--  filtered on directly, Postgres already pushes it down to run once per
--  CLASS rather than once per (date, class) cell - it does not depend on
--  the date loop, so the planner hoists it on its own. Measured calling
--  it that way, once per active class (~44), alone: ~238ms. Calling it a
--  SECOND time - once to pick a probe class, again to filter the due set,
--  the same two-step shape as registers_missing() - measured at ~459ms,
--  slower than the ~278ms this function ran at before this migration.
--  The fix here was never register_due() (a teacher's own class list is
--  short, so it was already cheap); it is finding this teacher's classes
--  exactly ONCE and reusing that small list for both steps below. Calling
--  teaches_class() exactly once per active class measures at ~299ms,
--  statistically the same function this replaced (~278ms) rather than an
--  improvement on it - correctly, since register_due()'s call count was
--  never this function's problem. registers_missing() is the one with the
--  ~10x win, because its per-class filter really was cheap and its
--  register_due() call count really was the cost.
create or replace function public.my_registers_outstanding()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_staff uuid := public.my_staff_id();
  v_taught uuid[];
  v_probe_class uuid;
  v_due_dates date[];
  v_sample_date date;
  v_due_classes uuid[];
  v_rows jsonb;
begin
  if v_staff is null then
    return jsonb_build_object('allowed', true, 'count', 0, 'rows', '[]'::jsonb);
  end if;

  --  teaches_class() called exactly once per active class - not once per
  --  active class per step, and never once per (date, class) cell.
  select array_agg(c.id) into v_taught
    from public.madrasah_classes c
   where c.is_active and public.teaches_class(c.id);

  if v_taught is null or array_length(v_taught, 1) is null then
    return jsonb_build_object('allowed', true, 'count', 0, 'rows', '[]'::jsonb);
  end if;

  select c.id into v_probe_class
    from public.madrasah_classes c
   where c.id = any(v_taught)
     and exists (select 1 from public.madrasah_pupil_classes pc
                   join public.madrasah_pupils p on p.id = pc.pupil_id
                  where pc.class_id = c.id and p.left_on is null
                    and p.status = 'on_roll')
   limit 1;

  if v_probe_class is null then
    return jsonb_build_object('allowed', true, 'count', 0, 'rows', '[]'::jsonb);
  end if;

  select array_agg(d::date) into v_due_dates
    from generate_series(current_date - 14, current_date, interval '1 day') d
   where (public.register_due(v_probe_class, d::date) ->> 'due')::boolean;

  if v_due_dates is null or array_length(v_due_dates, 1) is null then
    return jsonb_build_object('allowed', true, 'count', 0, 'rows', '[]'::jsonb);
  end if;

  v_sample_date := v_due_dates[1];
  select array_agg(c.id) into v_due_classes
    from public.madrasah_classes c
   where c.id = any(v_taught)
     and (public.register_due(c.id, v_sample_date) ->> 'due')::boolean;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.on_date desc, x.name), '[]'::jsonb)
    into v_rows
  from (
    select cls.class_id, cls.name, dd.on_date
      from (
        select c.id as class_id, c.name
          from public.madrasah_classes c
         where c.id = any(v_due_classes)
      ) cls
      cross join unnest(v_due_dates) as dd(on_date)
     where not exists (select 1 from public.madrasah_registers rg
                        where rg.class_id = cls.class_id and rg.on_date = dd.on_date
                          and rg.state = 'submitted')
  ) x;
  return jsonb_build_object('allowed', true,
                            'count', jsonb_array_length(v_rows), 'rows', v_rows);
end $$;

--  ---------------------------------------------------------------------
--  GRANTS, restated exactly as db/103 established them. CREATE OR REPLACE
--  preserves existing grants, but db/102's I4 is the reminder of what
--  happens when a migration is replayed standalone against a database
--  that never carried them forward - so they are restated here too.
--  ---------------------------------------------------------------------
revoke all on function public.registers_missing(date, date) from public, anon;
revoke all on function public.my_registers_outstanding() from public, anon;
revoke all on function public.register_history(uuid, date) from public, anon;
grant execute on function public.registers_missing(date, date) to authenticated;
grant execute on function public.my_registers_outstanding() to authenticated;
grant execute on function public.register_history(uuid, date) to authenticated;
