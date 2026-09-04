-- ===========================================================================
--  013_course_admin.sql — giving somebody a place from the waiting list
--
--  Why this is needed
--  ------------------
--  009 got sign-up right and administration wrong.
--
--  `outcome` ('place' or 'waiting') is decided once, by register_for_course(),
--  at the moment somebody signs up. After that nothing can change it. The
--  column grant in 009 is deliberately narrow:
--
--      grant select, update (status, office_notes, reviewed_by, reviewed_at)
--        on public.course_registrations to authenticated;
--
--  `outcome` is not in that list, so no administrator can move anybody off the
--  waiting list. The first time a place came free the office would have found
--  that out the hard way, on the phone, with the person waiting.
--
--  Two ways to fix it
--  ------------------
--  The quick way is to add `outcome` to that grant. That is wrong: the whole
--  point of counting inside a lock in register_for_course() is that a room
--  holding fifteen never holds sixteen. Letting a browser write the column
--  directly hands the cap to whoever is clicking, silently.
--
--  So instead the change goes through a function that does what the sign-up
--  function does — take the lock, count, refuse if full — and leaves a line in
--  the audit log naming who did it.
--
--  It also handles the case that is easy to forget: two administrators, both
--  looking at the same last place, both pressing the button. The advisory lock
--  serialises them and the second one is told the session is full.
--
--  Prerequisites: 009 and 011. Idempotent — safe to run again.
--
--  *** STANDING RULE: re-run 011_require_two_step.sql after this. ***
--  This migration creates no policies, so 011 has nothing new to catch — but
--  the rule exists precisely so nobody has to work out whether an exception
--  applies. Re-run it.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
-- Refuse to run at all if 011 has not been applied.
--
-- Without this the function below would be created happily — plpgsql does not
-- resolve names in its body until it is called — and would then fail on the
-- first real use, in front of somebody on the phone. Fail here instead, where
-- it costs nothing.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regprocedure('public.verified_admin()') is null then
    raise exception
      'public.verified_admin() does not exist. Run 011_require_two_step.sql first.';
  end if;
  if to_regclass('public.course_registrations') is null then
    raise exception
      'public.course_registrations does not exist. Run 009_courses.sql first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- Give a waiting registration a place.
--
-- SECURITY DEFINER, so it can write a column the caller has no grant on. That
-- makes the permission check inside it the only thing standing between a
-- signed-in shop customer and the waiting list, which is why it is the first
-- statement in the body and why it uses verified_admin() rather than
-- is_admin(): a session that has not passed two-step verification is not an
-- administrator for this purpose, exactly as 011 decided for everything else.
-- ---------------------------------------------------------------------------
create or replace function public.promote_from_waiting(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  r       public.course_registrations%rowtype;
  c       public.courses%rowtype;
  v_taken int;
begin
  if not public.verified_admin() then
    raise exception 'Only a verified administrator may give out a place';
  end if;

  select * into r from public.course_registrations where id = p_id;
  if not found then
    raise exception 'That registration no longer exists';
  end if;

  -- Somebody who withdrew does not quietly reappear on the register because an
  -- administrator clicked the wrong row. Put them back on the list first, then
  -- give them a place — two decisions, two clicks, both audited.
  if r.status <> 'active' then
    raise exception 'That registration is %, so it cannot be given a place', r.status;
  end if;

  if r.outcome = 'place' then
    return jsonb_build_object('reference', r.reference, 'outcome', 'place',
                              'changed', false);
  end if;

  select * into c from public.courses where key = r.course_key;
  if not found then
    raise exception 'The course this registration belongs to no longer exists';
  end if;

  -- The same lock register_for_course() takes, on the same key. Two
  -- administrators giving away the same last place now happen one after the
  -- other, and the second is refused.
  perform pg_advisory_xact_lock(hashtext('course:' || r.course_key || ':' || r.cohort));

  select count(*) into v_taken
    from public.course_registrations
   where course_key = r.course_key and cohort = r.cohort
     and outcome = 'place' and status = 'active';

  if v_taken >= c.capacity then
    raise exception
      'That session is already full (% of %). Withdraw somebody before giving out another place.',
      v_taken, c.capacity;
  end if;

  update public.course_registrations
     set outcome     = 'place',
         reviewed_by = auth.uid(),
         reviewed_at = now()
   where id = p_id;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'course_place_given', jsonb_build_object(
            'reference', r.reference, 'course', r.course_key,
            'cohort', r.cohort, 'capacity', c.capacity, 'taken_before', v_taken));

  return jsonb_build_object('reference', r.reference, 'outcome', 'place',
                            'changed', true,
                            'places_left', greatest(c.capacity - v_taken - 1, 0));
end;
$$;

revoke all    on function public.promote_from_waiting(uuid) from public;
grant  execute on function public.promote_from_waiting(uuid) to authenticated;

comment on function public.promote_from_waiting(uuid) is
  'Moves an active waiting registration to a place, if the session has room. '
  'Administrators only, two-step required. Writes to admin_audit.';

commit;
