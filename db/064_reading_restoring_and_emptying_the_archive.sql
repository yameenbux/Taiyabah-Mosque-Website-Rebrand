-- ===========================================================================
--  064_reading_restoring_and_emptying_the_archive.sql
--  18 September 2026
--
--  The Archive screen's three verbs: look, put back, and delete for good.
--
--  RESTORE ONLY RE-LINKS WHAT STILL EXISTS. A class archived after the teacher
--  who taught it would fail the foreign key and take the whole restore down
--  with it, so every link is checked before it is re-made. A teacher comes
--  back with the classes that are still there, and not with a broken timetable.
--
--  DELETE FOR GOOD IS THE ONE THAT ANSWERS AN ERASURE REQUEST, and its audit
--  row carries the KIND and the date and NOT the name - recording the name
--  there would leave behind the very thing somebody asked to have erased.
--
--  Prerequisites: 063. Idempotent.
-- ===========================================================================

create or replace function public.madrasah_archive_list()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp
as $fn$
declare v_m uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may open the archive.'
      using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', a.id, 'kind', a.kind, 'label', a.label, 'reason', a.reason,
             'archived_at', a.archived_at,
             'by', (select coalesce(p.full_name, p.email) from public.profiles p
                     where p.id = a.archived_by),
             --  HOW LONG IS LEFT, worked out here so the screen cannot drift
             --  from the purge. Three years from the day it was archived.
             'purges_on', (a.archived_at + interval '3 years')::date,
             'days_left', greatest(0, ((a.archived_at + interval '3 years')::date - current_date)),
             --  CAN IT GO BACK? Saying so on the row beats a failure after
             --  somebody has pressed Restore.
             'can_restore', case a.kind
               when 'staff' then not exists (select 1 from public.madrasah_staff s where s.id = a.record_id)
               when 'pupil' then not exists (select 1 from public.madrasah_pupils p where p.id = a.record_id)
               when 'class' then not exists (select 1 from public.madrasah_classes c where c.id = a.record_id)
               else false end)
           order by a.archived_at desc)
      from public.madrasah_archive a
     where a.masjid_id = v_m), '[]'::jsonb);
end $fn$;

create or replace function public.restore_madrasah_record(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare
  v_m uuid := public.current_masjid();
  a public.madrasah_archive%rowtype;
  v_row jsonb;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may restore a record.'
      using errcode = '42501';
  end if;
  select * into a from public.madrasah_archive where id = p_id and masjid_id = v_m;
  if a.id is null then
    raise exception 'There is nothing in the archive with that reference.' using errcode = 'no_data_found';
  end if;
  v_row := a.payload->'row';

  if a.kind = 'staff' then
    if exists (select 1 from public.madrasah_staff s where s.id = a.record_id) then
      raise exception 'That member of staff is already back on the list.' using errcode = 'unique_violation';
    end if;
    insert into public.madrasah_staff
    select * from jsonb_populate_record(null::public.madrasah_staff, v_row);
    --  ONLY CLASSES THAT STILL EXIST. A class archived after this teacher was
    --  would otherwise fail the foreign key and take the whole restore with it.
    insert into public.madrasah_staff_classes (masjid_id, staff_id, class_id)
    select v_m, a.record_id, (j)::uuid
      from jsonb_array_elements_text(coalesce(a.payload->'classes','[]'::jsonb)) j
     where exists (select 1 from public.madrasah_classes c
                    where c.id = (j)::uuid and c.masjid_id = v_m)
    on conflict do nothing;
    --  Main teacher only where nobody has been put in their place since.
    update public.madrasah_classes set main_teacher_id = a.record_id
     where masjid_id = v_m and main_teacher_id is null
       and id in (select (j)::uuid from jsonb_array_elements_text(
                    coalesce(a.payload->'main_teacher_of','[]'::jsonb)) j);

  elsif a.kind = 'pupil' then
    if exists (select 1 from public.madrasah_pupils p where p.id = a.record_id) then
      raise exception 'That child is already back on the register.' using errcode = 'unique_violation';
    end if;
    insert into public.madrasah_pupils
    select * from jsonb_populate_record(null::public.madrasah_pupils, v_row);
    insert into public.madrasah_pupil_classes (masjid_id, pupil_id, class_id)
    select v_m, a.record_id, (j)::uuid
      from jsonb_array_elements_text(coalesce(a.payload->'classes','[]'::jsonb)) j
     where exists (select 1 from public.madrasah_classes c
                    where c.id = (j)::uuid and c.masjid_id = v_m)
    on conflict do nothing;

  elsif a.kind = 'class' then
    if exists (select 1 from public.madrasah_classes c where c.id = a.record_id) then
      raise exception 'That class is already back on the list.' using errcode = 'unique_violation';
    end if;
    insert into public.madrasah_classes
    select * from jsonb_populate_record(null::public.madrasah_classes, v_row);
    insert into public.madrasah_pupil_classes (masjid_id, pupil_id, class_id)
    select v_m, (j)::uuid, a.record_id
      from jsonb_array_elements_text(coalesce(a.payload->'pupils','[]'::jsonb)) j
     where exists (select 1 from public.madrasah_pupils p
                    where p.id = (j)::uuid and p.masjid_id = v_m)
    on conflict do nothing;
    insert into public.madrasah_staff_classes (masjid_id, staff_id, class_id)
    select v_m, (j)::uuid, a.record_id
      from jsonb_array_elements_text(coalesce(a.payload->'staff','[]'::jsonb)) j
     where exists (select 1 from public.madrasah_staff s
                    where s.id = (j)::uuid and s.masjid_id = v_m)
    on conflict do nothing;
  else
    raise exception 'That is not a kind of record this archive knows how to restore.'
      using errcode = 'check_violation';
  end if;

  delete from public.madrasah_archive where id = p_id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_m, auth.uid(), 'madrasah_record_restored',
          jsonb_build_object('kind', a.kind, 'id', a.record_id));
  return jsonb_build_object('restored', a.label, 'kind', a.kind);
end $fn$;

create or replace function public.delete_archived_record(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare v_m uuid := public.current_masjid(); a public.madrasah_archive%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may delete an archived record.'
      using errcode = '42501';
  end if;
  select * into a from public.madrasah_archive where id = p_id and masjid_id = v_m;
  if a.id is null then
    raise exception 'There is nothing in the archive with that reference.' using errcode = 'no_data_found';
  end if;
  delete from public.madrasah_archive where id = p_id;
  --  THE KIND AND THE FACT, AND NOT THE NAME. This is the function an erasure
  --  request is answered with; recording the name here would leave behind the
  --  very thing that was asked to be erased.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_m, auth.uid(), 'madrasah_archive_deleted',
          jsonb_build_object('kind', a.kind, 'archived_at', a.archived_at));
  return jsonb_build_object('deleted', a.label);
end $fn$;

create or replace function public.purge_madrasah_archive()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare v_m uuid; v_n int; v_total int := 0;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may purge the archive.'
      using errcode = '42501';
  end if;
  for v_m in select * from public.masjids_to_purge() loop
    delete from public.madrasah_archive
     where masjid_id = v_m and archived_at < now() - interval '3 years';
    get diagnostics v_n = row_count;
    if v_n > 0 then
      insert into public.admin_audit (masjid_id, action, detail)
      values (v_m, 'madrasah_archive_purged', jsonb_build_object('removed', v_n));
    end if;
    v_total := v_total + v_n;
  end loop;
  return jsonb_build_object('removed', v_total, 'after', '3 years');
end $fn$;

revoke all on function public.archive_madrasah_staff(uuid, text)  from public, anon;
revoke all on function public.archive_madrasah_pupil(uuid, text)  from public, anon;
revoke all on function public.archive_madrasah_class(uuid, text)  from public, anon;
revoke all on function public.madrasah_archive_list()             from public, anon;
revoke all on function public.restore_madrasah_record(uuid)       from public, anon;
revoke all on function public.delete_archived_record(uuid)        from public, anon;
revoke all on function public.purge_madrasah_archive()            from public, anon;
grant execute on function public.archive_madrasah_staff(uuid, text) to authenticated;
grant execute on function public.archive_madrasah_pupil(uuid, text) to authenticated;
grant execute on function public.archive_madrasah_class(uuid, text) to authenticated;
grant execute on function public.madrasah_archive_list()            to authenticated;
grant execute on function public.restore_madrasah_record(uuid)      to authenticated;
grant execute on function public.delete_archived_record(uuid)       to authenticated;
grant execute on function public.purge_madrasah_archive()           to authenticated;
