-- ===========================================================================
--  060_a_class_has_one_main_teacher.sql
--  18 September 2026
--
--  Reported from the screen: "why does it show multiple teachers per class?
--  thats wrong."
--
--  It was. The class list PDF names the whole Apa team against the girls'
--  progression classes — Girls OOLA carries six — and 052's import wrote every
--  one of them into madrasah_staff_classes. The card then printed all six,
--  which answers nothing: a card answers "whose class is this".
--
--  The system being replaced gets this right and this project missed it. Its
--  class record has a single MAIN TEACHER field, with the rest of the staff
--  attached to the timetable underneath.
--
--  So main_teacher_id is its own column, separate from madrasah_staff_classes,
--  which goes on recording everybody who teaches the class.
--
--  35 OF 45 SET AUTOMATICALLY AND 10 LEFT BLANK. Where exactly one member of
--  staff is assigned there is nothing to decide. Where six are, picking one
--  here would be inventing an answer the masjid has not given — so the card
--  says "Main teacher not chosen" and an administrator picks.
--
--  Prerequisites: 052, 058. Idempotent.
-- ===========================================================================
alter table public.madrasah_classes
  add column if not exists main_teacher_id uuid references public.madrasah_staff(id) on delete set null;

comment on column public.madrasah_classes.main_teacher_id is
  'The one person answerable for this class. Separate from madrasah_staff_classes, which records everybody who teaches it. NULL means nobody has said, which the screen shows as "Main teacher not chosen" rather than guessing.';

--  min() has no uuid form, hence max(staff_id::text)::uuid; with n = 1 there is
--  exactly one row, so which aggregate is used is immaterial.
update public.madrasah_classes c
   set main_teacher_id = sc.staff_id
  from (select class_id, max(staff_id::text)::uuid as staff_id, count(*) as n
          from public.madrasah_staff_classes group by class_id) sc
 where sc.class_id = c.id and sc.n = 1 and c.main_teacher_id is null;

-- ---------------------------------------------------------------------------
--  THE FUNCTIONS, IN FULL.
--
--  Written out rather than summarised. 053 wrote "(Function bodies as applied
--  — see the migration history for the full text)" and that is exactly how a
--  masjid_id went missing from an insert with nobody able to read the diff.
--  This text was pulled back out of the live database with pg_get_functiondef,
--  so it is what is actually running and not what was meant to be.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_class_list()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid();
begin
  if not public.verified_madrasah() then
    raise exception 'Only madrasah staff who have completed two-step may see the classes.'
      using errcode = '42501';
  end if;
  return jsonb_build_object(
    'may_amend', public.verified_admin(),
    'classes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'name', c.name, 'section', c.section,
               'year_label', c.year_label, 'is_active', c.is_active, 'sort_order', c.sort_order,
               'pupils', (select count(*) from public.madrasah_pupil_classes pc
                           where pc.class_id = c.id and pc.masjid_id = v_masjid),
               'main_teacher_id', c.main_teacher_id,
               'main_teacher', (select btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name))
                                  from public.madrasah_staff s where s.id = c.main_teacher_id),
               --  Everybody who teaches it, for the class's own page. The CARD
               --  shows the main teacher only.
               'teachers', coalesce((
                 select jsonb_agg(jsonb_build_object('id', s.id,
                          'name', btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)))
                        order by s.last_name, s.first_name)
                   from public.madrasah_staff_classes sc
                   join public.madrasah_staff s on s.id = sc.staff_id
                  where sc.class_id = c.id and sc.masjid_id = v_masjid), '[]'::jsonb))
             order by c.section, c.sort_order, c.name)
        from public.madrasah_classes c
       where c.masjid_id = v_masjid
         and c.id in (select * from public.madrasah_classes_i_may_see())), '[]'::jsonb));
end $fn$;

create or replace function public.save_madrasah_class(p jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id uuid := nullif(p->>'id','')::uuid;
  v_name text := btrim(coalesce(p->>'name',''));
  v_row public.madrasah_classes%rowtype;
  v_masjid uuid := public.current_masjid();
  v_main uuid := nullif(p->>'main_teacher_id','')::uuid;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the madrasah classes.' using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected, so there is nowhere to put this class.' using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'A class needs a name.' using errcode = 'check_violation';
  end if;

  --  A main teacher from another masjid, or an id that is not staff at all, is
  --  refused rather than quietly stored and rendered as a blank name.
  if v_main is not null and not exists (
       select 1 from public.madrasah_staff s
        where s.id = v_main and s.masjid_id = v_masjid) then
    raise exception 'That person is not on this madrasah''s staff list.' using errcode = 'no_data_found';
  end if;

  insert into public.madrasah_classes as c
    (masjid_id, id, name, section, year_label, is_active, sort_order, main_teacher_id)
  values (v_masjid, coalesce(v_id, gen_random_uuid()), v_name,
          coalesce(nullif(p->>'section',''),'girls'),
          nullif(btrim(coalesce(p->>'year_label','')),''),
          coalesce((p->>'is_active')::boolean,true),
          coalesce((p->>'sort_order')::int,100),
          v_main)
  on conflict (id) do update set
    name = excluded.name, section = excluded.section, year_label = excluded.year_label,
    is_active = excluded.is_active, sort_order = excluded.sort_order,
    --  Absent means leave it alone; present means set it, including to null.
    main_teacher_id = case when p ? 'main_teacher_id' then excluded.main_teacher_id
                           else c.main_teacher_id end
  where c.masjid_id = v_masjid
  returning * into v_row;

  if v_row.id is null then
    raise exception 'There is no such class at this masjid.' using errcode = 'no_data_found';
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_class_saved',
          jsonb_build_object('id', v_row.id, 'name', v_row.name));
  return jsonb_build_object('id', v_row.id);
end $fn$;

--  NAMES AND SIDES ONLY. Choosing a main teacher needs a name; it does not
--  need DBS positions or telephone numbers, and madrasah_staff_list() carries
--  both. A narrower reason gets a narrower function.
create or replace function public.madrasah_staff_names()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the staff list.'
      using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'side', s.side,
             'name', btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)))
           order by s.last_name, s.first_name)
      from public.madrasah_staff s
     where s.masjid_id = v_masjid
       and coalesce(s.employment,'') <> 'left'), '[]'::jsonb);
end $fn$;

revoke all on function public.madrasah_staff_names() from public, anon;
grant execute on function public.madrasah_staff_names() to authenticated;
