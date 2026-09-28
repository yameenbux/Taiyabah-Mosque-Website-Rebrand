--  =====================================================================
--  084 - THE REGISTER
--  27 September 2026
--  =====================================================================
--
--  ONE ROW PER CHILD PER EVENING. Not one row per class with a list inside
--  it: a child moves class mid-year, a child is marked late and then present,
--  and a parent will one day report an absence for a child whose class the
--  parent does not know. All three are awkward against a session blob and
--  trivial against a row with a pupil and a date on it.
--
--  WHERE THE MARK CAME FROM IS RECORDED, and that column is the reason this
--  table is shaped the way it is. Today every mark comes from a teacher with
--  the register open. The moment parents can say "he is unwell tonight",
--  those arrive BEFORE the register is taken and have to survive it being
--  taken - a teacher marking a whole class present must not silently
--  overwrite a mother who rang in an hour ago. `source` is how the marking
--  function tells the difference, and it exists now so the table does not
--  have to be migrated under a live register later.
--
--  PROVED IN PRODUCTION, in rolled-back transactions, before anything else
--  was built on it:
--
--    parent said excused, teacher marked absent  -> excused / parent / reason kept
--    then the teacher said present               -> present / register
--
--  The parent's reason survives a blanket "away" and is replaced only when
--  the teacher says the child turned up after all, which is new information
--  rather than a default.

create table if not exists public.madrasah_attendance (
  id          uuid primary key default gen_random_uuid(),
  masjid_id   uuid not null references public.masjids(id) on delete cascade,
  pupil_id    uuid not null references public.madrasah_pupils(id) on delete cascade,
  class_id    uuid references public.madrasah_classes(id) on delete set null,
  on_date     date not null,

  --  FOUR MARKS AND NO MORE.
  --    present   they came
  --    late      they came, after the register
  --    absent    they did not come and nobody said why
  --    excused   they did not come and somebody told us why
  --  "excused" is not a judgement about whether the reason was good enough.
  --  It means a reason is recorded. A madrasah that has to decide which
  --  reasons count is a madrasah keeping an opinion about a family, and that
  --  is not what this table is for.
  mark        text not null check (mark in ('present','late','absent','excused')),
  reason      text,

  --  register: a teacher with the class in front of them
  --  parent:   reported by a parent before the evening (not built yet)
  --  office:   corrected afterwards by the office, which is a different act
  source      text not null default 'register'
              check (source in ('register','parent','office')),

  marked_by   uuid references auth.users(id),
  marked_at   timestamptz not null default now(),

  --  ONE MARK PER CHILD PER EVENING. Taking the register twice corrects it;
  --  it does not produce two answers.
  unique (pupil_id, on_date)
);

comment on table public.madrasah_attendance is
  'One row per child per evening. Described in the madrasah privacy notice from v1.3; see madrasah_notice_matches_schema().';

create index if not exists madrasah_attendance_class_date_idx
  on public.madrasah_attendance (masjid_id, class_id, on_date);
create index if not exists madrasah_attendance_pupil_idx
  on public.madrasah_attendance (pupil_id, on_date desc);

alter table public.madrasah_attendance enable row level security;
revoke all on public.madrasah_attendance from anon, authenticated;

--  =====================================================================
--  THE PROMISE THE NOTICE MAKES, ENFORCED
--  =====================================================================
--
--  The published privacy notice says, in as many words:
--
--    "We are building an attendance register. When it starts being used we
--     will issue a new version of this notice and tell you before the first
--     mark is made, not afterwards."
--
--  That is a promise to several hundred parents, in a signed document, on a
--  public web page. This repository's recent history is claims that nothing
--  enforced: a retention policy that had never run, a "sent" that meant
--  nothing, three privacy notices made false by a later migration.
--
--  So the register will not open until the masjid has recorded that every
--  family with a child on the roll has been told. Not a flag somebody sets -
--  the same evidence table the privacy notice telling uses (082), under the
--  kind 'attendance_notice', written from the Notices screen.
--
--  It returns the number outstanding rather than just false, because
--  "refused" with no number is a wall and "42 families still to tell" is a job.

create or replace function public.attendance_permitted()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_families int;
  v_told int;
begin
  select count(*) into v_families
    from public.madrasah_households h
   where h.masjid_id = v_masjid
     and exists (select 1 from public.madrasah_pupils p
                  where p.household_id = h.id and p.left_on is null);

  select count(distinct n.household_id) into v_told
    from public.madrasah_parent_notices n
    join public.madrasah_households h on h.id = n.household_id
   where n.masjid_id = v_masjid
     and n.kind = 'attendance_notice'
     and exists (select 1 from public.madrasah_pupils p
                  where p.household_id = h.id and p.left_on is null);

  return jsonb_build_object(
    'permitted', (v_families > 0 and v_told >= v_families),
    'families', v_families,
    'told', v_told,
    'outstanding', greatest(v_families - v_told, 0),
    'why', case
      when v_families = 0 then 'There are no families with a child on the roll.'
      when v_told >= v_families then 'Every family has been told the register is being kept.'
      else 'The privacy notice promises parents they will be told before the '
           || 'first mark is made. ' || (v_families - v_told)
           || ' famil' || case when v_families - v_told = 1 then 'y has' else 'ies have' end
           || ' not been told yet.' end);
end $$;

revoke all on function public.attendance_permitted() from public, anon;
grant execute on function public.attendance_permitted() to authenticated;

--  =====================================================================
--  READING ONE CLASS'S REGISTER
--  =====================================================================
--
--  A LIST, so it says WHETHER and not WHAT. It carries the marks, which are
--  the point of the screen, and no medical note, no allergy, no address and
--  no telephone number. 080's guard checks this function by name because it
--  ends in _list.
--
--  IT DOES CARRY has_medical, as a mark and never a value. A teacher about to
--  take twenty children into a room should be able to see that one of them
--  has something recorded, and open that child to read it - which is a
--  deliberate act and is written down.

create or replace function public.madrasah_register_list(
  p_class uuid, p_date date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_rows jsonb;
  v_class jsonb;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;
  if p_date > current_date then
    raise exception 'A register cannot be taken for a day that has not happened.'
      using errcode = '22023';
  end if;

  select to_jsonb(x) into v_class from (
    select c.id, c.name, c.section,
           btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name)) as teacher
      from public.madrasah_classes c
      left join public.madrasah_staff st on st.id = c.main_teacher_id
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
           --  A MARK, NEVER THE NOTE.
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

--  =====================================================================
--  TAKING THE REGISTER
--  =====================================================================

create or replace function public.mark_register(
  p_class uuid, p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_gate jsonb; v_m jsonb; v_pupil uuid; v_mark text;
  v_n int := 0; v_kept int := 0;
begin
  if not public.verified_madrasah() then
    raise exception 'Only madrasah staff may take a register.' using errcode = '42501';
  end if;

  v_gate := public.attendance_permitted();
  if not (v_gate ->> 'permitted')::boolean then
    raise exception '%', v_gate ->> 'why' using errcode = '42501';
  end if;

  if p_date > current_date then
    raise exception 'A register cannot be taken for a day that has not happened.'
      using errcode = '22023';
  end if;
  --  A register taken weeks later is somebody remembering rather than
  --  recording. Correcting one is the office's job and goes in with
  --  source = 'office', which says on the row that it was not taken live.
  if p_date < current_date - 14 then
    raise exception 'That evening is more than a fortnight ago. Ask the office '
                    'to correct it, so the record says it was corrected rather '
                    'than taken.' using errcode = '22023';
  end if;

  for v_m in select * from jsonb_array_elements(p_marks) loop
    v_pupil := (v_m ->> 'pupil_id')::uuid;
    v_mark  := v_m ->> 'mark';
    if v_pupil is null or v_mark is null then continue; end if;

    --  THE CHILD MUST BE IN THIS CLASS. Otherwise a stale screen, or a
    --  hand-made call, marks a child somebody else is responsible for.
    if not exists (select 1 from public.madrasah_pupil_classes pc
                    join public.madrasah_pupils p on p.id = pc.pupil_id
                   where pc.pupil_id = v_pupil and pc.class_id = p_class
                     and p.masjid_id = v_masjid) then
      continue;
    end if;

    --  A PARENT'S WORD IS NOT OVERWRITTEN BY A TICK.
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
            nullif(btrim(v_m ->> 'reason'), ''), 'register', auth.uid())
    on conflict (pupil_id, on_date) do update
      set mark = excluded.mark, reason = excluded.reason,
          class_id = excluded.class_id, source = 'register',
          marked_by = excluded.marked_by, marked_at = now();
    v_n := v_n + 1;
  end loop;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'register_taken',
          jsonb_build_object('class', p_class, 'on_date', p_date,
                             'marked', v_n, 'parent_reports_kept', v_kept));

  return jsonb_build_object('marked', v_n, 'parent_reports_kept', v_kept);
end $$;

revoke all on function public.mark_register(uuid, date, jsonb) from public, anon;
grant execute on function public.mark_register(uuid, date, jsonb) to authenticated;

--  =====================================================================
--  WHICH CLASSES STILL HAVE NO REGISTER TONIGHT
--  =====================================================================

create or replace function public.madrasah_registers_list(
  p_date date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_rows jsonb;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.name), '[]'::jsonb)
    into v_rows
  from (
    select c.id, c.name, c.section, c.sort_order,
           btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name)) as teacher,
           (select count(*) from public.madrasah_pupil_classes pc
              join public.madrasah_pupils p on p.id = pc.pupil_id
             where pc.class_id = c.id and p.left_on is null
               and p.status = 'on_roll')                       as on_roll,
           (select count(*) from public.madrasah_attendance a
             where a.class_id = c.id and a.on_date = p_date)   as marked,
           (select count(*) from public.madrasah_attendance a
             where a.class_id = c.id and a.on_date = p_date
               and a.mark in ('absent','excused'))             as away
      from public.madrasah_classes c
      left join public.madrasah_staff st on st.id = c.main_teacher_id
     where c.masjid_id = v_masjid and c.is_active
  ) x;

  return jsonb_build_object('allowed', true, 'on_date', p_date,
                            'permitted', public.attendance_permitted(),
                            'rows', v_rows);
end $$;

revoke all on function public.madrasah_registers_list(date) from public, anon;
grant execute on function public.madrasah_registers_list(date) to authenticated;
