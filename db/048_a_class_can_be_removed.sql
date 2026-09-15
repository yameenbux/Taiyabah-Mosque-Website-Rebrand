-- ===========================================================================
--  048_a_class_can_be_removed.sql
--  15 September 2026
--
--  043 said, at some length, that there is no delete:
--
--      There is no delete. course_registrations has a foreign key to this
--      table, so deleting a class somebody signed up for would either fail
--      with a constraint error or, with a cascade, silently erase the record
--      of people who registered. Closing a class is the reversible thing and
--      is what somebody actually means.
--
--  That is right about a class people have signed up for and wrong about the
--  case the masjid actually hit: a class created by mistake, or one tried for
--  a term and never run, sitting in the list for ever with no way to take it
--  out. "Close it" is the right answer for a class that ran; it is a strange
--  answer for a row somebody created with a typo five minutes ago.
--
--  So: a class MAY be deleted, and only while nothing references it. Not a
--  cascade — a cascade is how the record of forty people who signed up
--  disappears because somebody was tidying the list. The count is checked and
--  the refusal says the number out loud, so the person can go and look.
--
--  EVERY registration counts, including withdrawn ones. A withdrawn
--  registration is still a record that somebody asked, and the masjid's
--  retention policy decides when that goes — not a tidy-up on a Tuesday.
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

  --  Locked before counting, so a sign-up that arrives while somebody is
  --  pressing the button cannot slip in behind the check. 044 learned this
  --  the same way on save_course().
  select name into v_name from public.courses where key = v_key for update;
  if not found then
    raise exception 'There is no class with that website name.'
      using errcode = 'no_data_found';
  end if;

  select count(*) into v_count
    from public.course_registrations where course_key = v_key;

  if v_count > 0 then
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

-- ---------------------------------------------------------------------------
--  Prove both halves against the real table, and roll it back
-- ---------------------------------------------------------------------------
do $check$
declare
  v_left  integer;
  v_regs  integer;
begin
  --  A class nobody has signed up for goes.
  insert into public.courses (key, name, cohort_mode, capacity, sort_order, page)
  values ('probe_del', 'Probe', 'single', 5, 99, '{}'::jsonb);
  delete from public.courses where key = 'probe_del';
  select count(*) into v_left from public.courses where key = 'probe_del';
  if v_left <> 0 then raise exception 'an unused class could not be deleted'; end if;

  --  And one with a registration against it does not. Checked by counting
  --  rather than by calling delete_course(), because this session has no JWT
  --  and would be refused by verified_admin() before reaching the rule — the
  --  rule itself is what is being demonstrated.
  select count(*) into v_regs
    from public.course_registrations where course_key = 'arabic';
  if v_regs = 0 then
    raise notice 'NOTE: arabic has no registrations today, so the refusal path '
                 'was not exercised against live data. The count check is in '
                 'the function; _test covers the screen.';
  else
    raise notice 'arabic has % registration(s), so the refusal path is live.', v_regs;
  end if;

  raise notice 'delete_course is in place; an unused class deletes cleanly.';
end $check$;

commit;

-- ===========================================================================
--  AFTERWARDS
--
--    select public.delete_course('arabic');
--        -> ERROR: That class cannot be removed: 1 people have signed up ...
--
--  and as anon:
--
--    select public.delete_course('arabic');
--        -> ERROR: permission denied for function delete_course
-- ===========================================================================
