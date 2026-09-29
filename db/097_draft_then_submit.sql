--  =====================================================================
--  097 - DRAFT, THEN SUBMIT
--  =====================================================================
--  A register is not taken until every child on the roll carries a mark.
--  But a teacher marking ten children on a phone gets interrupted, and
--  all-or-nothing would lose seven marks to answer a door. So: marks
--  save as they are made, and SUBMIT is the thing that demands a full
--  register.
--
--  Submit counts against the roll AS IT IS AT THAT MOMENT, never against
--  madrasah_registers.expected_count. A child can join the class between
--  the draft and the submit, and a stored number would call a register
--  complete that is missing the newest child on the roll.

create or replace function public.save_register_draft(
  p_class uuid, p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_gate jsonb; v_m jsonb; v_pupil uuid; v_mark text;
  v_n int := 0; v_kept int := 0; v_on_roll int; v_marked int;
begin
  if not public.may_take_register(p_class) then
    raise exception 'That is not one of your classes.' using errcode = '42501';
  end if;

  v_gate := public.attendance_permitted();
  if not (v_gate ->> 'permitted')::boolean then
    raise exception '%', v_gate ->> 'why' using errcode = '42501';
  end if;

  if p_date > current_date then
    raise exception 'A register cannot be taken for a day that has not happened.'
      using errcode = '22023';
  end if;
  if p_date < current_date - 14 and not public.verified_madrasah() then
    raise exception 'That evening is more than a fortnight ago. Ask the office '
                    'to correct it, so the record says it was corrected rather '
                    'than taken.' using errcode = '22023';
  end if;

  for v_m in select * from jsonb_array_elements(p_marks) loop
    v_pupil := (v_m ->> 'pupil_id')::uuid;
    v_mark  := v_m ->> 'mark';
    if v_pupil is null or v_mark is null then continue; end if;

    if not exists (select 1 from public.madrasah_pupil_classes pc
                    join public.madrasah_pupils p on p.id = pc.pupil_id
                   where pc.pupil_id = v_pupil and pc.class_id = p_class
                     and p.masjid_id = v_masjid) then
      continue;
    end if;

    --  A PARENT'S WORD IS NOT OVERWRITTEN BY A TICK. Unchanged from 084.
    if exists (select 1 from public.madrasah_attendance a
                where a.pupil_id = v_pupil and a.on_date = p_date
                  and a.source = 'parent')
       and v_mark not in ('present','late') then
      v_kept := v_kept + 1;
      continue;
    end if;

    insert into public.madrasah_attendance
      (masjid_id, pupil_id, class_id, on_date, mark, reason, source, marked_by)
    values (v_masjid, v_pupil, p_class, p_date, v_mark,
            nullif(btrim(v_m ->> 'reason'), ''),
            case when public.verified_madrasah() and not public.is_teacher()
                 then 'office' else 'register' end,
            auth.uid())
    on conflict (pupil_id, on_date) do update
      set mark = excluded.mark, reason = excluded.reason,
          class_id = excluded.class_id, source = excluded.source,
          marked_by = excluded.marked_by, marked_at = now();
    v_n := v_n + 1;
  end loop;

  select count(*) into v_on_roll
    from public.madrasah_pupil_classes pc
    join public.madrasah_pupils p on p.id = pc.pupil_id
   where pc.class_id = p_class and p.left_on is null and p.status = 'on_roll';
  select count(*) into v_marked
    from public.madrasah_attendance a
    join public.madrasah_pupil_classes pc on pc.pupil_id = a.pupil_id
    join public.madrasah_pupils p on p.id = a.pupil_id
   where pc.class_id = p_class and a.on_date = p_date
     and p.left_on is null and p.status = 'on_roll';

  insert into public.madrasah_registers
    (masjid_id, class_id, on_date, expected_count, marked_count)
  values (v_masjid, p_class, p_date, v_on_roll, v_marked)
  on conflict (class_id, on_date) do update
    set expected_count = excluded.expected_count,
        marked_count   = excluded.marked_count,
        updated_at     = now();

  return jsonb_build_object('marked', v_n, 'parent_reports_kept', v_kept,
                            'on_roll', v_on_roll, 'has_mark', v_marked,
                            'missing', greatest(v_on_roll - v_marked, 0));
end $$;

create or replace function public.submit_register(p_class uuid, p_date date)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_on_roll int; v_marked int; v_missing int;
begin
  if not public.may_take_register(p_class) then
    raise exception 'That is not one of your classes.' using errcode = '42501';
  end if;

  --  AGAINST THE ROLL AS IT IS NOW. Not expected_count.
  select count(*) into v_on_roll
    from public.madrasah_pupil_classes pc
    join public.madrasah_pupils p on p.id = pc.pupil_id
   where pc.class_id = p_class and p.left_on is null and p.status = 'on_roll';
  select count(*) into v_marked
    from public.madrasah_attendance a
    join public.madrasah_pupil_classes pc on pc.pupil_id = a.pupil_id
    join public.madrasah_pupils p on p.id = a.pupil_id
   where pc.class_id = p_class and a.on_date = p_date
     and p.left_on is null and p.status = 'on_roll';

  v_missing := greatest(v_on_roll - v_marked, 0);
  if v_on_roll = 0 then
    raise exception 'That class has nobody on its roll.' using errcode = '22023';
  end if;
  if v_missing > 0 then
    raise exception '% of % children have no mark yet. Every child needs one '
                    'before the register can be handed in.', v_missing, v_on_roll
      using errcode = '22023';
  end if;

  insert into public.madrasah_registers
    (masjid_id, class_id, on_date, state, expected_count, marked_count,
     submitted_by, submitted_at)
  values (v_masjid, p_class, p_date, 'submitted', v_on_roll, v_marked,
          auth.uid(), now())
  on conflict (class_id, on_date) do update
    set state = 'submitted', expected_count = excluded.expected_count,
        marked_count = excluded.marked_count,
        submitted_by = excluded.submitted_by,
        submitted_at = now(), updated_at = now();

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'register_submitted',
          jsonb_build_object('class', p_class, 'on_date', p_date,
                             'children', v_on_roll,
                             'by', case when public.verified_madrasah()
                                        then 'office' else 'teacher' end));

  return jsonb_build_object('submitted', true, 'children', v_on_roll);
end $$;

--  KEPT, AND NOT A THIN WRAPPER. The current Register screen calls this
--  and makes partial saves; if it started refusing them the screen would
--  break the moment this lands. So it saves, then TRIES to submit, and
--  says which happened.
create or replace function public.mark_register(
  p_class uuid, p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_saved jsonb; v_sub jsonb := null;
begin
  v_saved := public.save_register_draft(p_class, p_date, p_marks);
  if (v_saved ->> 'missing')::int = 0 then
    begin
      v_sub := public.submit_register(p_class, p_date);
    exception when others then v_sub := null;
    end;
  end if;
  return v_saved || jsonb_build_object('submitted', v_sub is not null);
end $$;

--  THE OFFICE TAKES A PHONE CALL. Spec 2's parent login calls this same
--  function; it adds a front door, not a second mechanism.
create or replace function public.record_parent_absence(
  p_pupil uuid, p_date date, p_mark text, p_reason text)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid(); v_class uuid;
begin
  if not public.verified_madrasah() then
    raise exception 'Only the madrasah office may record what a parent has said.'
      using errcode = '42501';
  end if;
  if p_mark not in ('absent','excused','late') then
    raise exception 'A parent can report a child away or late, not present.'
      using errcode = '22023';
  end if;
  select pc.class_id into v_class from public.madrasah_pupil_classes pc
   where pc.pupil_id = p_pupil limit 1;

  insert into public.madrasah_attendance
    (masjid_id, pupil_id, class_id, on_date, mark, reason, source, marked_by)
  values (v_masjid, p_pupil, v_class, p_date, p_mark,
          nullif(btrim(p_reason), ''), 'parent', auth.uid())
  on conflict (pupil_id, on_date) do update
    set mark = excluded.mark, reason = excluded.reason,
        source = 'parent', marked_by = excluded.marked_by, marked_at = now();

  return jsonb_build_object('recorded', true);
end $$;

revoke all on function public.save_register_draft(uuid, date, jsonb) from public, anon;
revoke all on function public.submit_register(uuid, date) from public, anon;
revoke all on function public.record_parent_absence(uuid, date, text, text) from public, anon;
grant execute on function public.save_register_draft(uuid, date, jsonb) to authenticated;
grant execute on function public.submit_register(uuid, date) to authenticated;
grant execute on function public.record_parent_absence(uuid, date, text, text) to authenticated;
