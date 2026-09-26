--  079  STATUS, AN AUDITED EXPORT, AND A GUARD THAT ACTUALLY RUNS
--
--  Applied to the live project as four migrations:
--    a_pupil_is_on_roll_or_on_hold_or_gone
--    an_export_that_writes_down_who_took_it
--    the_guard_that_ran_once_now_runs_every_time
--    never_test_a_guard_by_breaking_the_real_thing
--  plus two in-place splices into health_check().
--
--  This file is the repository's record of them. It is not re-run against a
--  database that already has them.
--
--  ======================================================================
--  ONE. A PUPIL IS ON ROLL, ON HOLD, SUSPENDED, OR GONE
--  ======================================================================
--
--  The madrasah could record two states: left_on is set, or it is not. A
--  child who had stopped attending for a term, or who was suspended, had
--  nowhere to be except "on roll" - which makes the roll a lie.
--
--  THE OLD SYSTEM'S ELEVEN STATUSES ARE NOT COPIED. Waiting List, Accepted,
--  On Hold at application time and Rejected are APPLICATION states, and this
--  system has an Admissions section that owns them; the old one needs them on
--  the student table only because it keeps applicants and pupils together.
--  Nine of the eleven would sit permanently at zero here, and a filter that
--  is always empty teaches people to stop reading the filters.
--
--  The backfill is DERIVED, not defaulted. Defaulting every row to 'on_roll'
--  would have been right today by luck - nobody has left - and silently wrong
--  the first time this ran somewhere a child had.

alter table public.madrasah_pupils
  add column if not exists status text not null default 'on_roll';

update public.madrasah_pupils
   set status = case when left_on is not null then 'left' else 'on_roll' end;

--  STATUS AND left_on CANNOT DISAGREE. Two fields that each claim to say
--  whether a child has gone is how a register ends up with somebody on it who
--  left in March.
alter table public.madrasah_pupils
  drop constraint if exists madrasah_pupils_status_shape;
alter table public.madrasah_pupils
  add constraint madrasah_pupils_status_shape check (
    status in ('on_roll', 'on_hold', 'suspended', 'left')
    and (status = 'left') = (left_on is not null));

create index if not exists madrasah_pupils_status_idx
  on public.madrasah_pupils (masjid_id, status);

--  CHECK. THE CONSTRAINT ACTUALLY REFUSES. A constraint nobody has tried is
--  a comment. Three ways wrong, then the right ones.
do $$
declare v_id uuid;
begin
  select id into v_id from public.madrasah_pupils limit 1;
  begin
    update public.madrasah_pupils set status = 'expelled' where id = v_id;
    raise exception 'CHECK FAILED: a status outside the four was allowed';
  exception when check_violation then null; end;
  begin
    update public.madrasah_pupils set status = 'left' where id = v_id;
    raise exception 'CHECK FAILED: left with no leaving date was allowed';
  exception when check_violation then null; end;
  begin
    update public.madrasah_pupils set left_on = current_date where id = v_id;
    raise exception 'CHECK FAILED: a leaving date with status on_roll was allowed';
  exception when check_violation then null; end;
  update public.madrasah_pupils set status='left', left_on=current_date where id=v_id;
  update public.madrasah_pupils set status='on_roll', left_on=null where id=v_id;
  raise notice 'CHECK passed: three wrong states refused, the right ones allowed';
end $$;

--  madrasah_roll() gains 'status' and now returns EVERY pupil rather than
--  only those on roll - the screen filters by status and defaults to on roll,
--  and a list that silently drops a suspended child is how somebody is
--  forgotten rather than dealt with. Its full definition lives with 077.

--  ======================================================================
--  TWO. AN EXPORT THAT WRITES DOWN WHO TOOK IT
--  ======================================================================
--
--  The highest-risk thing in the portal. Everything else keeps children's
--  details inside a screen that needs two-step and records who opened ONE
--  child. An export puts 552 of them in a file that leaves the system, lands
--  in a Downloads folder and gets attached to an email.
--
--    register  any signed-in madrasah staff   reference, name, class, teacher
--    full      administrators only            + date of birth, gender,
--                                               address, postcode, family,
--                                               guardian, telephone, email
--
--  NEITHER CARRIES medical, allergies, SEND or EHCP. Including them was
--  offered and declined; if it is ever wanted the DPIA needs updating first.
--
--  IT WRITES AN AUDIT ROW EVERY TIME, naming who, when, which columns, how
--  many rows and the filter in force - so "exported the whole roll" and
--  "exported one class of twelve" are different entries rather than both
--  reading "exported". The system already records who opened one child's
--  record; a file with 552 in it should be at least as traceable.
--
--  NOT `stable`, for the same reason as madrasah_pupil_one(): the planner may
--  elide a stable call and take the audit row with it.
--
--  THE FILTER IS A FIXED SHAPE - {class_id, teacher, status, gender}, each
--  optional, anything else ignored. A function that applies arbitrary filter
--  structure from a browser is a way of asking the database questions it was
--  not built to answer.
--
--  THE DETAILED COLUMNS ARE `case when p_detail then ... end`, not selected
--  and then dropped. A column that is fetched and discarded is one edit away
--  from being sent.
--
--  The full definition is in the applied migration
--  `an_export_that_writes_down_who_took_it`; it is long and is not repeated
--  here. What must not be lost is the pair of checks that guard it:
--
--    CHECK 1  reads the function's own source from the catalogue and fails if
--             any of p.medical, p.allergies, p.send_detail, p.ehcp_detail is
--             selected. Read from the catalogue, not from memory of what was
--             written: a check that encodes what you remember tests your
--             memory.
--    CHECK 2  CALLS it with no session, at both levels, and requires a
--             refusal. Reading the grants proves who MAY call it; calling it
--             proves what happens when they do.
--
--  Proved end to end against the live register, in a transaction that was
--  rolled back: 552 rows and five columns for the register list, 552 rows and
--  thirteen for the full one, 16 for a single class, three audit rows each
--  naming its own row count and filter, and no special-category value
--  anywhere in either file.

--  ======================================================================
--  THREE. THE GUARD THAT RAN ONCE NOW RUNS EVERY TIME
--  ======================================================================
--
--  077 asserted that madrasah_roll() does not name a detail column, and the
--  note written afterwards said the split "cannot be undone by somebody
--  adding just one field". That was wrong. The assertion ran ONCE, at
--  migration time, inside a DO block that has long since finished. It is not
--  a database object. Nothing re-runs it.
--
--  A check that ran once during a migration reads, in prose, exactly like a
--  check that runs. That is the whole problem with it, and it was found only
--  by querying the catalogue instead of believing the note.
--
--  The browser suites cannot close this: _test/*.py run against a local
--  server with stubs and never touch Supabase, deliberately. So it lives in
--  health_check(), which already runs named checks and reports which fail.
--
--  THE FIRST VERSION OF THE GUARD FAILED CORRECT CODE. It looked for any
--  mention of `p.medical` and found four in madrasah_roll() - which is
--  exactly the design:
--
--      'has_medical', p.medical is not null
--
--  The column is TESTED to make a mark; the value never leaves. A guard that
--  cannot tell a test from a value would have forced the next person to
--  either delete the marks or switch the guard off, and switching a guard off
--  to get work done is how guards die. So the rule is not "never name the
--  column" but: every mention must be immediately followed by IS NULL or IS
--  NOT NULL. Test it as much as you like; return it and this fails.

create or replace function public.madrasah_list_minimisation(
  p_lists text[] default array['madrasah_roll', 'madrasah_roll_export'])
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  detail text[] := array['medical', 'allergies', 'send_detail', 'ehcp_detail'];
  fn text; col text; src text; bad text[] := '{}'; seen int := 0;
  hits int; tested int;
begin
  foreach fn in array p_lists loop
    select pg_get_functiondef(p.oid) into src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = fn limit 1;
    if src is null then continue; end if;
    seen := seen + 1;
    --  A function may SAY "no medical column is ever included"; it may not
    --  select one. So the commentary is stripped before looking.
    src := regexp_replace(src, '--[^\n]*', '', 'g');
    foreach col in array detail loop
      select count(*) into hits from regexp_matches(
        src, '\m[a-z_]+\.' || col || '\M', 'gi') m;
      select count(*) into tested from regexp_matches(
        src, '\m[a-z_]+\.' || col || '\M\s+is\s+(not\s+)?null', 'gi') m;
      if hits > tested then
        bad := bad || (fn || ' returns ' || col || ' ('
                    || (hits - tested) || ' mention(s) that are not a null test)');
      end if;
    end loop;
  end loop;
  return jsonb_build_object(
    'ok', array_length(bad, 1) is null,
    'checked', seen,
    'detail', case when array_length(bad, 1) is null
      then seen || ' list function(s) test detail columns but never return them'
      else 'A LIST HAS LEARNED A DETAIL COLUMN: ' || array_to_string(bad, '; ') end);
end $$;

revoke all on function public.madrasah_list_minimisation(text[]) from public, anon;
grant execute on function public.madrasah_list_minimisation(text[]) to authenticated;

--  ======================================================================
--  FOUR. NEVER TEST A GUARD BY BREAKING THE REAL THING
--  ======================================================================
--
--  The check that first proved the guard works did this:
--
--      create or replace function public.madrasah_roll_export(...)
--        ... returns everyone's medical notes ...
--      -- run the guard, expect a refusal
--      raise exception 'rolling back'
--
--  It worked. A PL/pgSQL block with an EXCEPTION clause runs in a
--  subtransaction, so catching the exception undid the replacement, and the
--  real export survived - verified afterwards, still gating on
--  verified_admin(), still writing its audit row.
--
--  IT SHOULD NOT HAVE BEEN WRITTEN THAT WAY. For the length of that block the
--  madrasah's export was a three-line stub returning every child's medical
--  note to anyone who called it, and the only thing between that and
--  production was getting the exception handling right first time. A typo in
--  the handler and the stub simply stays.
--
--  Hence the p_lists parameter above: the real list is the default, so every
--  caller gets the real behaviour, and the test points the guard at its own
--  throwaway function instead.

--  CHECK. The value refused, the mark allowed, nothing live touched.
do $$
declare refused_value boolean; allowed_mark boolean;
begin
  create or replace function public.zz_guard_fixture()
  returns jsonb language sql stable as $inner$
    select jsonb_agg(jsonb_build_object('medical', p.medical))
      from public.madrasah_pupils p;
  $inner$;
  refused_value := not (public.madrasah_list_minimisation(
                          array['zz_guard_fixture']) ->> 'ok')::boolean;

  create or replace function public.zz_guard_fixture()
  returns jsonb language sql stable as $inner$
    select jsonb_agg(jsonb_build_object('has_medical', p.medical is not null))
      from public.madrasah_pupils p;
  $inner$;
  allowed_mark := (public.madrasah_list_minimisation(
                     array['zz_guard_fixture']) ->> 'ok')::boolean;

  drop function if exists public.zz_guard_fixture();

  if not refused_value then
    raise exception 'CHECK FAILED: a list RETURNING p.medical passed the guard';
  end if;
  if not allowed_mark then
    raise exception 'CHECK FAILED: a list merely TESTING p.medical was refused, '
                    'which would force somebody to switch the guard off';
  end if;
  raise notice 'CHECK passed: the value refused, the mark allowed';
end $$;

--  ======================================================================
--  FIVE. TWO THINGS SPLICED INTO health_check()
--  ======================================================================
--
--  (a) The minimisation guard above, as the check
--      `lists_carry_marks_not_detail`.
--
--  (b) THE LANDING TABLES, WHICH HAD BEEN FAILING HEALTH ALL DAY.
--      Adding the guard and then reading health_check for the first time
--      showed it returning "fail" - not on the new check, but on
--      `every_table_has_a_masjid`, because the four import_ tables created
--      for the register import this morning have no masjid_id. They had been
--      failing since the moment they were created and nobody had looked.
--
--      Exempting them quietly would have been the easy fix and the wrong
--      one. They are not tenanted data - they are a staging area for one
--      import - so they are exempt from THAT check, and a check of their own
--      says out loud that they are still there:
--
--          register_landing_tables_dropped
--
--      They hold a second copy of 552 children's details, medical notes
--      included. They are sealed: forced row-level security, no policies, no
--      grants to any signed-in role. They are what makes the reconciliation
--      re-runnable while the nine questionable dates and 56 sibling pairs are
--      still open. Once those are settled they should be dropped, because
--      keeping a duplicate of children's data with no remaining purpose is
--      what a retention policy exists to prevent.
--
--      An exemption with no alarm attached is how "temporary" becomes
--      "permanent". health_check will report fail until they are gone, and
--      that is the point.
