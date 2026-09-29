--  =====================================================================
--  103 - WHAT WAS MISSED, AND WHAT IT SAID
--  28 September 2026
--  =====================================================================
--  A register TAKEN has always been visible: madrasah_my_classes() shows a
--  teacher their own marked/on_roll counts, and the office can open any
--  class and see it. A register NOT taken has not been visible anywhere -
--  which is the half that matters, because a class could go three weeks
--  unmarked and the only way to find out was to open the right screen on
--  the right evening and notice the absence of something.
--
--  Three functions, one question each:
--    registers_missing()         - the office's whole-masjid missed list
--    my_registers_outstanding()  - a teacher's own missed list, unprompted
--    register_history()          - what a register used to say, for one
--                                   class on one evening (office only - it
--                                   names children, see below)
--
--  All three ask register_due() per (class, date) rather than re-deriving
--  "was this evening one the class runs on" - that logic already exists in
--  db/095 and belongs in exactly one place. The cost is a generate_series
--  cross join calling register_due() once per (day, class): measured on
--  production at ~985ms for registers_missing()'s default 14 days x 44
--  active classes, ~280ms for my_registers_outstanding() scoped to one
--  class. Noticeable, not a hang, at today's 44 classes - see this task's
--  report for the number to watch as the masjid's class count grows
--  towards the ~70 this was sized against.

create or replace function public.registers_missing(
  p_from date default (current_date - 14), p_to date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid(); v_rows jsonb;
begin
  --  OFFICE ONLY. This spans every class in the masjid; a teacher must not
  --  learn from it that another teacher's register is outstanding.
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.on_date desc, x.name), '[]'::jsonb)
    into v_rows
  from (
    select c.id as class_id, c.name, d::date as on_date,
           btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name)) as teacher
      from generate_series(p_from, p_to, interval '1 day') d
      cross join public.madrasah_classes c
      left join public.madrasah_staff st on st.id = c.main_teacher_id
     where c.masjid_id = v_masjid and c.is_active
       and (public.register_due(c.id, d::date) ->> 'due')::boolean
       and not exists (select 1 from public.madrasah_registers rg
                        where rg.class_id = c.id and rg.on_date = d::date
                          and rg.state = 'submitted')
  ) x;
  return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to,
                            'count', jsonb_array_length(v_rows), 'rows', v_rows);
end $$;

--  THE TEACHER'S OWN. Their only channel is this portal - a teacher login
--  holds no email address (db/090), so it has to be on the page they land
--  on, not a report someone else has to remember to send them.
--
--  Scoped by teaches_class(), the same predicate every other teacher-facing
--  function in this system is built on (db/090's "one predicate everything
--  else hangs off"). A teacher never sees another teacher's missed evening
--  through this function, because the WHERE clause below can only ever
--  widen to classes teaches_class() already says are theirs.
create or replace function public.my_registers_outstanding()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_staff uuid := public.my_staff_id(); v_rows jsonb;
begin
  --  A LOGIN WITH NO STAFF ROW GETS AN EMPTY LIST, NOT AN ERROR. Same shape
  --  as madrasah_my_classes() in db/090: 'allowed' stays true (a teacher IS
  --  allowed to ask this) and the list is simply empty, because the system
  --  does not know which classes are theirs. An exception here would read,
  --  to a volunteer teacher on a phone, as the register system being down.
  if v_staff is null then
    return jsonb_build_object('allowed', true, 'count', 0, 'rows', '[]'::jsonb);
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.on_date desc, x.name), '[]'::jsonb)
    into v_rows
  from (
    select c.id as class_id, c.name, d::date as on_date
      from generate_series(current_date - 14, current_date, interval '1 day') d
      cross join public.madrasah_classes c
     where c.is_active and public.teaches_class(c.id)
       and (public.register_due(c.id, d::date) ->> 'due')::boolean
       and not exists (select 1 from public.madrasah_registers rg
                        where rg.class_id = c.id and rg.on_date = d::date
                          and rg.state = 'submitted')
  ) x;
  return jsonb_build_object('allowed', true,
                            'count', jsonb_array_length(v_rows), 'rows', v_rows);
end $$;

--  WHAT IT USED TO SAY. Office only, and NOT for a working screen left open
--  on a desk: this returns a child's name against every change made to
--  their mark on one evening, source and who-wrote-it included. A list
--  screen says WHETHER a register was taken; a history like this says WHAT
--  it said, which is a record about named children, not a working list -
--  see CLAUDE.md, "the list says whether, the record says what".
create or replace function public.register_history(p_class uuid, p_date date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_rows jsonb;
begin
  if not public.verified_madrasah() then
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

revoke all on function public.registers_missing(date, date) from public, anon;
revoke all on function public.my_registers_outstanding() from public, anon;
revoke all on function public.register_history(uuid, date) from public, anon;
grant execute on function public.registers_missing(date, date) to authenticated;
grant execute on function public.my_registers_outstanding() to authenticated;
grant execute on function public.register_history(uuid, date) to authenticated;

--  ---------------------------------------------------------------------
--  PROVED, not assumed, against production (masjid f1a55e9e-...). Full
--  numbers are in this task's report, db/103's companion. Summarised here
--  because register_history() names children by design and that output
--  must never sit in this file or in a chat transcript (CLAUDE.md). No
--  real pupil, parent or staff data was pasted anywhere to check this -
--  every proof below is a boolean, a count, or a set of ids re-checked in
--  SQL, never read by eye.
--
--    * AS THE TEST TEACHER (42a0f447-..., aal1 - teachers keep no
--      two-step, db/090's trade): registers_missing() -> {"allowed":
--      false}. register_history() -> {"allowed": false}. Neither the
--      cross join nor the child-naming query inside them ran - proved by
--      running the SAME call as the test admin at aal2 immediately after
--      and getting {"allowed": true, ...} back from both, so the guard
--      demonstrably has two live branches, not one that merely never gets
--      exercised.
--
--    * my_registers_outstanding() AS THE SAME TEACHER: reported count 11,
--      11 rows actually returned, and re-checking every row's class_id
--      through teaches_class() IN THE SAME QUERY (not by eye) found 0 that
--      teaches_class() did not confirm - and only one distinct class_id
--      came back at all, which is correct: this teacher teaches exactly
--      one class.
--
--    * A LOGIN WITH NO STAFF ROW (a subject claim that matches no row in
--      madrasah_staff - nothing was inserted or deleted to test this) got
--      {"allowed": true, "count": 0, "rows": []} from
--      my_registers_outstanding() - not an error.
--
--    * AS THE OFFICE (test admin, aal2): registers_missing() returned
--      {"allowed": true, "count": 484} over the default 14-day window
--      across 44 active classes, register_days() being {mon,tue,wed,thu,
--      fri} for this masjid right now. That is a real, large number
--      because register-taking has not operationally started yet - it is
--      exactly the fact this migration exists to surface, not a bug in
--      the count.
--  ---------------------------------------------------------------------
