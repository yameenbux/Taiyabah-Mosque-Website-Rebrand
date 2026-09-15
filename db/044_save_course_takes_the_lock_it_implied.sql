-- ===========================================================================
--  044_save_course_takes_the_lock_it_implied.sql
--  15 September 2026
--
--  043 refuses a capacity below the number of people already holding a place,
--  and the comment above it explains why at some length: otherwise the masjid
--  is quietly holding sixteen names for fifteen seats and nobody finds out
--  until the evening itself.
--
--  It read that count with a plain SELECT, outside any lock. Two administrators
--  saving at the same moment both read fifteen, both pass the check, and the
--  second one's capacity wins. The window is small and a masjid with
--  fifteen-place classes will probably never open it — but A COMMENT THAT
--  CLAIMS MORE THAN THE CODE DELIVERS is the thing this project keeps being
--  bitten by, and the honest repair is to make the code match the comment
--  rather than to soften the comment.
--
--  `for update` on the course row serialises the two administrators. The
--  re-count after the upsert catches a registration that committed in between.
--
--  WHAT IS STILL OPEN, SAID PLAINLY RATHER THAN LEFT TO BE DISCOVERED
--  -----------------------------------------------------------------
--  This closes administrator-against-administrator. It does NOT close
--  administrator-against-visitor: register_for_course() reads the course row
--  without locking it, so a registration that begins before this transaction
--  commits still compares itself against the OLD capacity and may be granted a
--  place this function has just decided there is no room for.
--
--  Closing that properly means making register_for_course() take the same lock,
--  which would serialise every sign-up on a course behind every other one. For
--  two classes of fifteen at a masjid in Bolton that is a great deal of
--  machinery to buy a fault nobody will ever hit, and the failure mode if it
--  ever does happen is one extra name on a list that a human is reading
--  anyway. It is written down here instead of being defended against, so that
--  whoever does hit it finds this paragraph rather than a mystery.
-- ===========================================================================

begin;

create or replace function public.save_course(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_key   text := lower(btrim(coalesce(p->>'key', '')));
  v_why   text;
  v_new   boolean;
  v_taken integer;
  v_cap   integer;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the classes.'
      using errcode = '42501';
  end if;

  v_why := public.check_course(p);
  if v_why is not null then
    raise exception '%', v_why using errcode = 'check_violation';
  end if;

  v_cap := (p->>'capacity')::int;

  --  Hold the row for the rest of this transaction. A second administrator
  --  saving the same class waits here rather than reading a count that is
  --  about to stop being true. A brand new class has no row to lock and needs
  --  none: nobody can be registered on a class that does not exist yet.
  perform 1 from public.courses where key = v_key for update;
  v_new := not found;

  select count(*) into v_taken
    from public.course_registrations
   where course_key = v_key and outcome = 'place' and status = 'active';

  if v_cap < v_taken then
    raise exception 'There are already % people holding a place on that class, so it cannot be set to % places. Move somebody to the waiting list first.',
      v_taken, v_cap using errcode = 'check_violation';
  end if;

  insert into public.courses (key, name, cohort_mode, capacity, sort_order)
  values (v_key, btrim(p->>'name'), lower(btrim(p->>'cohort_mode')), v_cap,
          coalesce(nullif(btrim(coalesce(p->>'sort_order', '')), '')::int, 0))
  on conflict (key) do update
    set name        = excluded.name,
        cohort_mode = excluded.cohort_mode,
        capacity    = excluded.capacity,
        sort_order  = excluded.sort_order;

  --  Read it again. A registration that committed between the first count and
  --  this point is visible now, and the whole transaction goes back.
  select count(*) into v_taken
    from public.course_registrations
   where course_key = v_key and outcome = 'place' and status = 'active';

  if v_cap < v_taken then
    raise exception 'Somebody took a place on that class while this was being saved — there are now % holding one, so it cannot be set to % places. Nothing has been changed.',
      v_taken, v_cap using errcode = 'check_violation';
  end if;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), case when v_new then 'course_created' else 'course_edited' end,
          jsonb_build_object('key', v_key, 'name', btrim(p->>'name'),
                             'capacity', v_cap));

  return jsonb_build_object('key', v_key, 'is_new', v_new, 'taken', v_taken);
end $fn$;

revoke all     on function public.save_course(jsonb) from public, anon;
grant  execute on function public.save_course(jsonb) to authenticated;

commit;
