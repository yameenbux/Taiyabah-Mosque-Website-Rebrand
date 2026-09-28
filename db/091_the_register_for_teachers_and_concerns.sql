--  =====================================================================
--  091 - THE REGISTER FOR TEACHERS, AND A WAY TO RAISE A CONCERN
--  27 September 2026
--  =====================================================================
--
--  084 built the register for madrasah office staff, gated on
--  verified_madrasah(). A teacher is not that and was refused.
--
--  THE SCOPING GOES IN THE FUNCTIONS, NOT THE SCREENS. Every one of these
--  now asks may_take_register(p_class) - administrator, office, or the
--  teacher OF THAT CLASS - rather than "is this person madrasah staff". A
--  teacher who types another class's id into the address bar is refused by
--  Postgres, not by a page that chose not to draw a button.
--
--  Only the gate changed in the three register functions; the bodies are
--  084's. They are restated in full rather than patched, because a partial
--  migration of a function this central is harder to read than a whole one.

create or replace function public.madrasah_registers_list(
  p_date date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_office boolean := public.verified_madrasah();
  v_teacher boolean := public.is_teacher();
  v_staff uuid := public.my_staff_id();
  v_rows jsonb;
begin
  if not (v_office or v_teacher) then
    return jsonb_build_object('allowed', false);
  end if;

  --  A TEACHER WITH NO STAFF ROW OWNS NO CLASSES, and is told so rather than
  --  shown an empty screen they would read as the system losing them.
  if v_teacher and not v_office and v_staff is null then
    return jsonb_build_object('allowed', true, 'on_date', p_date,
      'mine_only', true, 'rows', '[]'::jsonb,
      'permitted', public.attendance_permitted(),
      'why', 'This login is not linked to a member of staff yet, so the '
          || 'madrasah does not know which classes are yours. Ask the office.');
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.name), '[]'::jsonb)
    into v_rows
  from (
    select c.id, c.name, c.section, c.sort_order,
           btrim(concat_ws(' ', st.honorific, st.first_name, st.last_name)) as teacher,
           (select count(*) from public.madrasah_pupil_classes pc
              join public.madrasah_pupils p on p.id = pc.pupil_id
             where pc.class_id = c.id and p.left_on is null
               and p.status = 'on_roll')                      as on_roll,
           (select count(*) from public.madrasah_attendance a
             where a.class_id = c.id and a.on_date = p_date)  as marked,
           (select count(*) from public.madrasah_attendance a
             where a.class_id = c.id and a.on_date = p_date
               and a.mark in ('absent','excused'))            as away
      from public.madrasah_classes c
      left join public.madrasah_staff st on st.id = c.main_teacher_id
     where c.masjid_id = v_masjid and c.is_active
       --  THE WHOLE DIFFERENCE, IN ONE CLAUSE. Office sees every class; a
       --  teacher sees the ones that are theirs.
       and (v_office
            or c.main_teacher_id = v_staff
            or exists (select 1 from public.madrasah_staff_classes sc
                        where sc.class_id = c.id and sc.staff_id = v_staff))
  ) x;

  return jsonb_build_object('allowed', true, 'on_date', p_date,
                            'mine_only', (v_teacher and not v_office),
                            'permitted', public.attendance_permitted(),
                            'rows', v_rows);
end $$;

revoke all on function public.madrasah_registers_list(date) from public, anon;
grant execute on function public.madrasah_registers_list(date) to authenticated;

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
           --  A MARK, NEVER THE NOTE - for everybody, teachers included.
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

create or replace function public.mark_register(
  p_class uuid, p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_gate jsonb; v_m jsonb; v_pupil uuid; v_mark text;
  v_n int := 0; v_kept int := 0;
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
  if p_date < current_date - 14 then
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
                             'marked', v_n, 'parent_reports_kept', v_kept,
                             'by', case when public.verified_madrasah()
                                        then 'office' else 'teacher' end));

  return jsonb_build_object('marked', v_n, 'parent_reports_kept', v_kept);
end $$;

revoke all on function public.mark_register(uuid, date, jsonb) from public, anon;
grant execute on function public.mark_register(uuid, date, jsonb) to authenticated;

--  =====================================================================
--  RAISING A SAFEGUARDING CONCERN
--  =====================================================================
--
--  WRITE ONLY, FOR EVERYBODY WHO IS NOT AN ADMINISTRATOR. A teacher may
--  raise a concern and can never read one back - not another teacher's, and
--  NOT THEIR OWN ONCE IT IS SENT.
--
--  That last part looks unhelpful and is deliberate. A concern is about a
--  child and may be about a colleague, and a screen that lets the person who
--  raised it watch what happened next turns a safeguarding report into a
--  conversation. It also means a teacher who is themselves the subject of a
--  concern cannot find it. The person who raised it gets a reference and is
--  told a designated person has it; everything after that is the safeguarding
--  lead's, not the system's.
--
--  NOT A REPLACEMENT FOR RINGING SOMEBODY. The form says so in terms, first
--  and largest: if a child is in danger now, this is the wrong tool.

create table if not exists public.madrasah_concerns (
  id           uuid primary key default gen_random_uuid(),
  masjid_id    uuid not null references public.masjids(id) on delete cascade,
  reference    text not null,
  pupil_id     uuid references public.madrasah_pupils(id) on delete set null,
  class_id     uuid references public.madrasah_classes(id) on delete set null,
  --  What happened, in the words of the person who saw it. Not a form with
  --  categories: a category is an interpretation, and the first record of a
  --  concern should be observation.
  what_happened text not null,
  when_it_happened text,
  raised_by    uuid references auth.users(id),
  raised_by_name text,
  raised_at    timestamptz not null default now(),
  status       text not null default 'new'
               check (status in ('new','acknowledged','actioned','closed')),
  seen_by      uuid references auth.users(id),
  seen_at      timestamptz,
  outcome_note text,
  unique (masjid_id, reference)
);

comment on table public.madrasah_concerns is
  'Safeguarding concerns. Write-only for teachers; readable only by verified administrators.';

alter table public.madrasah_concerns enable row level security;
revoke all on public.madrasah_concerns from anon, authenticated;

create or replace function public.raise_concern(
  p_pupil uuid, p_what text, p_when text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_class uuid;
  v_ref text;
  v_name text;
begin
  if not (public.is_teacher() or public.verified_madrasah()) then
    raise exception 'This is for madrasah staff.' using errcode = '42501';
  end if;
  if nullif(btrim(p_what), '') is null then
    raise exception 'Please say what happened. A concern with nothing in it '
                    'cannot be looked into.' using errcode = '22023';
  end if;

  --  A concern may be about a child the person teaches, or about no child at
  --  all - some are about an adult, or about a thing seen in a corridor.
  if p_pupil is not null then
    select pc.class_id into v_class
      from public.madrasah_pupil_classes pc
     where pc.pupil_id = p_pupil
       and (public.verified_madrasah() or public.teaches_class(pc.class_id))
     limit 1;
    if v_class is null and not public.verified_madrasah() then
      raise exception 'That child is not in one of your classes.'
        using errcode = '42501';
    end if;
  end if;

  select 'SC-' || to_char(now(), 'YY') || '-' ||
         lpad((coalesce(max(substring(reference from 8)::int), 0) + 1)::text, 4, '0')
    into v_ref
    from public.madrasah_concerns
   where masjid_id = v_masjid
     and reference like 'SC-' || to_char(now(), 'YY') || '-%';

  select coalesce(nullif(btrim(pr.full_name), ''), 'a member of staff')
    into v_name from public.profiles pr where pr.id = auth.uid();

  insert into public.madrasah_concerns
    (masjid_id, reference, pupil_id, class_id, what_happened,
     when_it_happened, raised_by, raised_by_name)
  values (v_masjid, v_ref, p_pupil, v_class, btrim(p_what),
          nullif(btrim(p_when), ''), auth.uid(), v_name);

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'concern_raised',
          jsonb_build_object('reference', v_ref, 'about_a_child', p_pupil is not null));

  --  The reference and nothing else. Not the row back: see the note above.
  return jsonb_build_object('reference', v_ref,
    'said', 'This has gone to the safeguarding lead. Keep the reference. '
         || 'You will not be able to look it up here - concerns are read by '
         || 'the designated person only.');
end $$;

revoke all on function public.raise_concern(uuid, text, text) from public, anon;
grant execute on function public.raise_concern(uuid, text, text) to authenticated;

--  READING THEM IS ADMINISTRATORS ONLY, AND AT TWO-STEP.
create or replace function public.madrasah_concerns_list(
  p_status text default null)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid := public.current_masjid(); v_rows jsonb;
begin
  if not public.verified_admin() then
    raise exception 'Safeguarding concerns are for administrators who have '
                    'completed two-step.' using errcode = '42501';
  end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.raised_at desc), '[]'::jsonb)
    into v_rows
  from (
    select c.id, c.reference, c.status, c.raised_at, c.raised_by_name,
           c.what_happened, c.when_it_happened, c.outcome_note,
           btrim(concat_ws(' ', p.first_name, p.last_name)) as child,
           cl.name as class
      from public.madrasah_concerns c
      left join public.madrasah_pupils p on p.id = c.pupil_id
      left join public.madrasah_classes cl on cl.id = c.class_id
     where c.masjid_id = v_masjid
       and (p_status is null or c.status = p_status)
  ) x;
  return jsonb_build_object('allowed', true, 'rows', v_rows);
end $$;

revoke all on function public.madrasah_concerns_list(text) from public, anon;
grant execute on function public.madrasah_concerns_list(text) to authenticated;
