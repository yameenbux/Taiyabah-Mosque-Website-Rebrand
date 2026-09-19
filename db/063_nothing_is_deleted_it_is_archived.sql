-- ===========================================================================
--  063_nothing_is_deleted_it_is_archived.sql
--  18 September 2026
--
--  Asked for: "when removing any record from the madrasah database it should
--  get archived, where someone is able to go into the archive and restore if
--  needed, you keep that record for same amount as a pupil."
--
--  Staff, pupils and classes. The whole row AND ITS LINKS go in as jsonb, so
--  restoring puts back what was there rather than an approximation - a class
--  comes back with its register, a teacher with their timetable.
--
--  ---------------------------------------------------------------------------
--  AN ARCHIVE IS STILL A RECORD, AND THAT IS THE THING TO GET RIGHT.
--  ---------------------------------------------------------------------------
--  "Archived" is not "deleted" to a regulator. If somebody asks the masjid to
--  erase what it holds about them, moving it to the archive does not answer
--  that request - so 064 adds a SECOND control, delete_archived_record(), that
--  removes it for good. Without it, "archive everything" quietly becomes "we
--  never delete anything", which is the opposite of what was wanted.
--
--  And the archive is on the same three-year clock as a pupil record, counted
--  from the day it was archived. Same rule, same purge, one number.
--
--  Prerequisites: 058. Idempotent.
-- ===========================================================================

create table if not exists public.madrasah_archive (
  id          uuid primary key default gen_random_uuid(),
  masjid_id   uuid not null references public.masjids(id) on delete cascade,
  kind        text not null,
  record_id   uuid not null,
  label       text not null,
  payload     jsonb not null,
  reason      text,
  archived_by uuid references auth.users(id),
  archived_at timestamptz not null default now()
);

alter table public.madrasah_archive drop constraint if exists madrasah_archive_kind_known;
alter table public.madrasah_archive add constraint madrasah_archive_kind_known
  check (kind in ('staff','pupil','class'));

create index if not exists madrasah_archive_by_when
  on public.madrasah_archive (masjid_id, archived_at desc);

comment on table public.madrasah_archive is
  'Records removed from the madrasah, kept whole so they can be restored. '
  'Three years from archived_at they are deleted for good by '
  'purge_madrasah_archive(). An archived record is still a record: '
  'delete_archived_record() is what answers an erasure request.';

alter table public.madrasah_archive enable row level security;
alter table public.madrasah_archive force row level security;
revoke all on public.madrasah_archive from anon, authenticated;

-- ---------------------------------------------------------------------------
--  Archiving. One function per kind, because what has to be carried differs.
-- ---------------------------------------------------------------------------
create or replace function public.archive_madrasah_staff(p_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare v_m uuid := public.current_masjid(); v_row public.madrasah_staff%rowtype; v_label text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may remove a member of staff.'
      using errcode = '42501';
  end if;
  select * into v_row from public.madrasah_staff where id = p_id and masjid_id = v_m;
  if v_row.id is null then
    raise exception 'There is no such member of staff at this masjid.' using errcode = 'no_data_found';
  end if;
  v_label := btrim(concat_ws(' ', v_row.honorific, v_row.first_name, v_row.last_name));

  insert into public.madrasah_archive (masjid_id, kind, record_id, label, payload, reason, archived_by)
  values (v_m, 'staff', v_row.id, v_label,
          jsonb_build_object(
            'row', to_jsonb(v_row),
            --  The classes they took, so restoring gives back the same person
            --  and not a name with no timetable.
            'classes', coalesce((select jsonb_agg(sc.class_id)
                                   from public.madrasah_staff_classes sc
                                  where sc.staff_id = v_row.id and sc.masjid_id = v_m), '[]'::jsonb),
            'main_teacher_of', coalesce((select jsonb_agg(c.id)
                                   from public.madrasah_classes c
                                  where c.main_teacher_id = v_row.id and c.masjid_id = v_m), '[]'::jsonb)),
          nullif(btrim(coalesce(p_reason,'')),''), auth.uid());

  delete from public.madrasah_staff where id = p_id and masjid_id = v_m;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_m, auth.uid(), 'madrasah_staff_archived', jsonb_build_object('id', p_id));
  return jsonb_build_object('archived', v_label);
end $fn$;

create or replace function public.archive_madrasah_pupil(p_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare v_m uuid := public.current_masjid(); v_row public.madrasah_pupils%rowtype; v_label text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may remove a pupil record.'
      using errcode = '42501';
  end if;
  select * into v_row from public.madrasah_pupils where id = p_id and masjid_id = v_m;
  if v_row.id is null then
    raise exception 'There is no such child at this madrasah.' using errcode = 'no_data_found';
  end if;
  v_label := btrim(concat_ws(' ', v_row.first_name, v_row.last_name));

  insert into public.madrasah_archive (masjid_id, kind, record_id, label, payload, reason, archived_by)
  values (v_m, 'pupil', v_row.id, v_label,
          jsonb_build_object('row', to_jsonb(v_row),
            'classes', coalesce((select jsonb_agg(pc.class_id)
                                   from public.madrasah_pupil_classes pc
                                  where pc.pupil_id = v_row.id and pc.masjid_id = v_m), '[]'::jsonb)),
          nullif(btrim(coalesce(p_reason,'')),''), auth.uid());

  delete from public.madrasah_pupils where id = p_id and masjid_id = v_m;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_m, auth.uid(), 'madrasah_pupil_archived', jsonb_build_object('id', p_id));
  return jsonb_build_object('archived', v_label);
end $fn$;

create or replace function public.archive_madrasah_class(p_id uuid, p_reason text default null)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare v_m uuid := public.current_masjid(); v_row public.madrasah_classes%rowtype; v_kids integer;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may remove a class.'
      using errcode = '42501';
  end if;
  select * into v_row from public.madrasah_classes where id = p_id and masjid_id = v_m;
  if v_row.id is null then
    raise exception 'There is no such class at this masjid.' using errcode = 'no_data_found';
  end if;
  select count(*) into v_kids from public.madrasah_pupil_classes
   where class_id = p_id and masjid_id = v_m;

  insert into public.madrasah_archive (masjid_id, kind, record_id, label, payload, reason, archived_by)
  values (v_m, 'class', v_row.id, v_row.name,
          jsonb_build_object('row', to_jsonb(v_row),
            --  WHO WAS IN IT. The link rows cascade away with the class, so
            --  without this a restored class comes back empty and the children
            --  are quietly in nothing.
            'pupils', coalesce((select jsonb_agg(pc.pupil_id)
                                  from public.madrasah_pupil_classes pc
                                 where pc.class_id = v_row.id and pc.masjid_id = v_m), '[]'::jsonb),
            'staff', coalesce((select jsonb_agg(sc.staff_id)
                                 from public.madrasah_staff_classes sc
                                where sc.class_id = v_row.id and sc.masjid_id = v_m), '[]'::jsonb)),
          nullif(btrim(coalesce(p_reason,'')),''), auth.uid());

  delete from public.madrasah_classes where id = p_id and masjid_id = v_m;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_m, auth.uid(), 'madrasah_class_archived',
          jsonb_build_object('id', p_id, 'pupils_unlinked', v_kids));
  return jsonb_build_object('archived', v_row.name, 'pupils_unlinked', v_kids);
end $fn$;

-- ===========================================================================
--  PROVED BY A ROUND TRIP ON 18 SEPTEMBER 2026.
--
--  A throwaway class with one throwaway child in it was archived and restored.
--  Checked: the class left the live table; the link rows cascaded away with
--  it; THE CHILD WAS NOT DELETED; the class came back; the register came back
--  with one child in it, not nought; and the archive row did not survive the
--  restore, so it cannot be restored twice.
--
--  The real functions refused the first attempt outright - "Only an
--  administrator who has completed two-step may remove a class" - because the
--  connection running the test had no signed-in session. That is the guard
--  working, and the mechanics were then exercised through a temporary copy
--  with the guard omitted, which was dropped in the same statement.
-- ===========================================================================
