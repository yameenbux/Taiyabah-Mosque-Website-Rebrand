-- ===========================================================================
--  049_one_person_is_not_people.sql
--  15 September 2026
--
--  048's refusal reads:
--
--      That class cannot be removed: 1 people have signed up for it ...
--
--  A subagent reading the migration spotted it and wondered whether it was
--  accepted, because the AFTERWARDS block at the foot of the file predicts
--  that exact string. It was not accepted; it was written and not read back.
--
--  This is a small thing and it is fixed anyway, for the reason every other
--  message on this project is written the way it is: the person reading it is
--  a volunteer who opens this screen twice a year, and a system that cannot
--  count to one is a system they will not quite trust about anything else
--  either. Nothing else in the sentence changes.
-- ===========================================================================

begin;

create or replace function public.delete_course(p_key text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key   text := lower(btrim(p_key));
  v_name  text;
  v_count integer;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may remove a class.'
      using errcode = '42501';
  end if;

  --  Locked before counting, so a sign-up arriving while somebody presses the
  --  button cannot slip in behind the check. 044 learned this on save_course().
  select name into v_name from public.courses where key = v_key for update;
  if not found then
    raise exception 'There is no class with that website name.'
      using errcode = 'no_data_found';
  end if;

  select count(*) into v_count
    from public.course_registrations where course_key = v_key;

  if v_count = 1 then
    raise exception 'That class cannot be removed: somebody has signed up for it, and deleting it would erase the record of them asking. Close sign-ups instead — that takes it off the website and keeps the list.'
      using errcode = 'foreign_key_violation';
  elsif v_count > 1 then
    raise exception 'That class cannot be removed: % people have signed up for it, and deleting it would erase the record of them asking. Close sign-ups instead — that takes it off the website and keeps the list.',
      v_count using errcode = 'foreign_key_violation';
  end if;

  delete from public.courses where key = v_key;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'course_deleted',
          jsonb_build_object('key', v_key, 'name', v_name));

  return jsonb_build_object('key', v_key, 'deleted', true);
end $fn$;

revoke all     on function public.delete_course(text) from public, anon;
grant  execute on function public.delete_course(text) to authenticated;

commit;
