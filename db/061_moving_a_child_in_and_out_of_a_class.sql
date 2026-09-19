-- ===========================================================================
--  061_moving_a_child_in_and_out_of_a_class.sql
--  18 September 2026
--
--  Asked for: "when users click amend this class, it should also have the
--  option to add student and remove student."
--
--  It lives inside "Amend this class" rather than on the class page, because
--  taking a child off a register is a change to what the madrasah holds and
--  belongs behind the same door as renaming the class — not one press away
--  from simply reading it.
--
--  THREE THINGS WORTH THE COMMENTS THEY CARRY:
--
--  An empty search returns nothing, not everybody. Typing one letter and
--  getting five hundred children is not a search result, it is the register
--  printed at somebody who asked a question.
--
--  Each result shows the classes that child is already in. Two children at a
--  madrasah share a name far more often than anybody expects — twelve pairs in
--  this import alone — and the class is what tells them apart before somebody
--  adds the wrong one.
--
--  Removing returns how many classes the child has LEFT. A record in no class
--  is reachable from no register, which is how a child goes quietly missing,
--  and the screen says so in words when it was their last one.
--
--  Administrators only. A teacher may read their own register; moving children
--  between classes is an office job.
--
--  Prerequisites: 058. Idempotent.
-- ===========================================================================

create or replace function public.madrasah_pupil_search(p_q text, p_not_in_class uuid default null)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_q text := btrim(coalesce(p_q, ''));
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may search the children.'
      using errcode = '42501';
  end if;

  --  AN EMPTY SEARCH RETURNS NOTHING, not everybody.
  if length(v_q) < 2 then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(x order by x->>'name')
      from (
        select jsonb_build_object(
                 'id', p.id,
                 'name', btrim(concat_ws(' ', p.first_name, p.last_name)),
                 --  The classes they are already in. Twelve pairs of children in
                 --  this madrasah share a name; the class is what tells them
                 --  apart before somebody adds the wrong one.
                 'classes', coalesce((
                   select string_agg(c.name, ', ' order by c.name)
                     from public.madrasah_pupil_classes pc
                     join public.madrasah_classes c on c.id = pc.class_id
                    where pc.pupil_id = p.id), 'no class')) as x
          from public.madrasah_pupils p
         where p.masjid_id = v_masjid
           and btrim(concat_ws(' ', p.first_name, p.last_name)) ilike '%' || v_q || '%'
           and (p_not_in_class is null
                or not exists (select 1 from public.madrasah_pupil_classes pc
                                where pc.pupil_id = p.id and pc.class_id = p_not_in_class))
         limit 25
      ) q), '[]'::jsonb);
end $fn$;

create or replace function public.add_pupil_to_class(p_pupil uuid, p_class uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid(); v_name text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may move a child between classes.'
      using errcode = '42501';
  end if;
  select btrim(concat_ws(' ', p.first_name, p.last_name)) into v_name
    from public.madrasah_pupils p where p.id = p_pupil and p.masjid_id = v_masjid;
  if v_name is null then
    raise exception 'There is no such child at this madrasah.' using errcode = 'no_data_found';
  end if;
  if not exists (select 1 from public.madrasah_classes c
                  where c.id = p_class and c.masjid_id = v_masjid) then
    raise exception 'There is no such class at this madrasah.' using errcode = 'no_data_found';
  end if;
  insert into public.madrasah_pupil_classes (masjid_id, pupil_id, class_id)
  values (v_masjid, p_pupil, p_class) on conflict do nothing;
  --  THE AUDIT CARRIES THE ID AND NOT THE NAME.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_pupil_added_to_class',
          jsonb_build_object('pupil', p_pupil, 'class', p_class));
  return jsonb_build_object('added', v_name);
end $fn$;

create or replace function public.remove_pupil_from_class(p_pupil uuid, p_class uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare v_masjid uuid := public.current_masjid(); v_name text; v_left integer;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may move a child between classes.'
      using errcode = '42501';
  end if;
  select btrim(concat_ws(' ', p.first_name, p.last_name)) into v_name
    from public.madrasah_pupils p where p.id = p_pupil and p.masjid_id = v_masjid;
  if v_name is null then
    raise exception 'There is no such child at this madrasah.' using errcode = 'no_data_found';
  end if;
  delete from public.madrasah_pupil_classes
   where pupil_id = p_pupil and class_id = p_class and masjid_id = v_masjid;
  --  HOW MANY CLASSES THEY HAVE LEFT. A record in no class is reachable from
  --  no register, which is how a child goes quietly missing, so the screen can
  --  say so when it was their last one.
  select count(*) into v_left from public.madrasah_pupil_classes
   where pupil_id = p_pupil and masjid_id = v_masjid;
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_pupil_removed_from_class',
          jsonb_build_object('pupil', p_pupil, 'class', p_class, 'classes_left', v_left));
  return jsonb_build_object('removed', v_name, 'classes_left', v_left);
end $fn$;

revoke all on function public.madrasah_pupil_search(text, uuid)   from public, anon;
revoke all on function public.add_pupil_to_class(uuid, uuid)      from public, anon;
revoke all on function public.remove_pupil_from_class(uuid, uuid) from public, anon;
grant execute on function public.madrasah_pupil_search(text, uuid)   to authenticated;
grant execute on function public.add_pupil_to_class(uuid, uuid)      to authenticated;
grant execute on function public.remove_pupil_from_class(uuid, uuid) to authenticated;
