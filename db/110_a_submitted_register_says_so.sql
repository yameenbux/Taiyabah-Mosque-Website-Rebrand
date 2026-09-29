-- ===========================================================================
--  110 - A SUBMITTED REGISTER SAYS SO
--  28 September 2026
-- ===========================================================================
--  Review of Task 8. db/097 gave the register two states, draft and
--  submitted, and db/102 gave submitted a demotion rule. Nothing gave the
--  TEACHER either one. madrasah_register_list(p_class, p_date) - the only
--  call the Register screen makes when it opens a class - returns the class
--  and its rows, and nothing about the register itself. A teacher who hands
--  a register in, and comes back to it later, sees the identical screen a
--  fully-marked draft would show: same enabled gold button, no
--  acknowledgement, no time. They cannot tell it went in, so they press it
--  again, or ring the office, or go back to paper - the exact failure mode
--  CLAUDE.md already names for a report nobody can see was received.
--
--  THE FIX IS ADDITIVE. v_class already carries id, name, section, teacher -
--  a small object built once, close to the class row. This adds `state` and
--  `submitted_at` from madrasah_registers, left-joined on (class_id,
--  on_date) so a class with no register yet this evening (nobody has saved
--  a single mark) returns both as null, same as any other date with no row -
--  not a special case, just what a left join already does.
--
--  ANCHOR CONFIRMED LIVE before splicing, same v_class subquery
--  db/084/091 left it:
--    select c.id, c.name, c.section,
--           btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name)) as teacher
--      from public.madrasah_classes c
--      left join public.madrasah_staff st on st.id = c.main_teacher_id
--     where c.id = p_class and c.masjid_id = v_masjid
--
--  NOTHING ELSE IN THIS FUNCTION CHANGES. Two new keys on an existing
--  object are additive for every caller that reads named keys off it
--  (which is what JSON in this codebase is always read as - nowhere does
--  the Register screen, or anything else found calling this function,
--  iterate `class`'s own keys rather than naming them). The one caller is
--  tools/register_module.js's openClass(), which reads d["class"] into
--  OPEN and then reads OPEN.id, OPEN.name, OPEN.section, OPEN.teacher by
--  name - two more named properties on that object are invisible to it
--  until Task 8's screen is changed to read them, which is the other half
--  of this review.
-- ===========================================================================

create or replace function public.madrasah_register_list(
  p_class uuid, p_date date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_rows jsonb;
  v_class jsonb;
begin
  --  NOT "is this person staff" but "may this person take THIS register".
  if not public.may_take_register(p_class) then
    return jsonb_build_object('allowed', false);
  end if;
  if p_date > current_date then
    raise exception 'A register cannot be taken for a day that has not happened.'
      using errcode = '22023';
  end if;

  select to_jsonb(x) into v_class from (
    select c.id, c.name, c.section,
           btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name)) as teacher,
           --  THE STATE OF THIS EVENING'S REGISTER, NOT JUST THE CLASS. A
           --  left join, not an inner one: a class with nothing saved yet
           --  tonight has no row in madrasah_registers for (id, p_date),
           --  and state/submitted_at both come back null - draft in
           --  everything but name, which is exactly what it is.
           r.state, r.submitted_at
      from public.madrasah_classes c
      left join public.madrasah_staff st on st.id = c.main_teacher_id
      left join public.madrasah_registers r
             on r.class_id = c.id and r.on_date = p_date
     where c.id = p_class and c.masjid_id = v_masjid) x;
  if v_class is null then
    return jsonb_build_object('allowed', true, 'class', null, 'rows', '[]'::jsonb);
  end if;

  select coalesce(jsonb_agg(to_jsonb(y) order by y.name), '[]'::jsonb) into v_rows
  from (
    select p.id,
           btrim(concat_ws(' ', p.first_name, p.last_name)) as name,
           p.legacy_ref as reference,
           p.status,
           --  A MARK, NEVER THE NOTE - for everybody, teachers included. The
           --  note is on the child's record, which is a deliberate act and is
           --  written down against a name.
           (p.medical is not null or p.allergies is not null) as has_medical,
           a.mark, a.reason, a.source, a.marked_at
      from public.madrasah_pupils p
      join public.madrasah_pupil_classes pc on pc.pupil_id = p.id
      left join public.madrasah_attendance a
             on a.pupil_id = p.id and a.on_date = p_date
     where pc.class_id = p_class
       and p.masjid_id = v_masjid
       and p.left_on is null
       and p.status = 'on_roll'
  ) y;

  return jsonb_build_object(
    'allowed', true, 'class', v_class, 'on_date', p_date,
    'permitted', public.attendance_permitted(), 'rows', v_rows);
end $$;

revoke all on function public.madrasah_register_list(uuid, date) from public, anon;
grant execute on function public.madrasah_register_list(uuid, date) to authenticated;
