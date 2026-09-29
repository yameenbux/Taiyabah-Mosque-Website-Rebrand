--  =====================================================================
--  122 - health_check(), madrasah_notice_matches_schema() and
--        madrasah_list_minimisation() HAVE A GATE INSIDE THEM
--  29 September 2026
--  =====================================================================
--
--  Found by the parents' portal, slice 1: all three were executable by ANY
--  signed-in account and checked nothing themselves. With parent logins that
--  is 330 households who could read the madrasah's internal health - cron
--  state, what tables exist, which column names the privacy notice does and
--  does not describe. No people, no counts of people, but not a parent's
--  business, and "nobody has a reason to" is the weakest control there is.
--
--  PROVED REACHABLE FIRST, on production, before this file was written: as the
--  test parent (aal1, no role of any kind) health_check() returned all 16
--  checks, and the other two returned their objects. (Recorded as a count and
--  a type only - nothing was printed.)
--
--  THE RULE, IN THE ORDER THE TEST RUNS
--    a caller with NO SESSION at all (auth.uid() is null) is allowed. That is
--    pg_cron running health_watch() every fifteen minutes, the SQL editor and
--    a migration - all of them the database's own owner, none of them a
--    person signed in over the API. anon cannot reach these functions at all
--    (no EXECUTE), so "no session" cannot be an anonymous visitor.
--    a caller WITH a session must be verified_admin(). Anybody else - a
--    parent, a teacher, the madrasah office, the hall office - is refused
--    with 42501 and one sentence.
--
--  EVERY CALLER WAS CHECKED BEFORE ANYTHING WAS CHANGED:
--    * pg_cron job 13 "health-watch" runs `select public.health_watch()`.
--      health_watch() is SECURITY DEFINER, owner postgres, EXECUTE for
--      postgres only, and is the ONLY function in the database whose body
--      names health_check(). No session, so it passes.
--    * health_check() itself calls madrasah_notice_matches_schema() and
--      madrasah_list_minimisation() - the same caller, the same session.
--    * No JavaScript, no edge function and no test in this repository calls
--      any of the three (searched; the only hits are documentation and the
--      privacy-page generator, which reads a migration FILE, not the
--      database).
--  NOTHING'S SIGNATURE CHANGES. Each is spliced in place, read-patch-refuse
--  from the live definition, so this file is correct only against what is
--  installed and says so when it is not.
--
--  THE GATE COULD BE BYPASSED THROUGH A DEFINER CHAIN, AND IS NOT: a parent
--  who reaches any of these through another SECURITY DEFINER function still
--  carries their own auth.uid(), which is what the gate reads.
--
--  ONE DELIBERATE NARROWING beyond "refuse a parent": a teacher, the
--  madrasah office and the hall office could also call these and no longer
--  can. Nothing they use calls them, and none of them has any business with
--  what they return.
--  =====================================================================
do $mig$
declare
  v_fn text; v_def text; v_new text; v_n int;
  v_gate constant text :=
$g$
  --  db/122: internal. The scheduler and the database's owner have no
  --  session; anybody with one must be a verified administrator.
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'That is for the masjid''s administrators.'
      using errcode = '42501';
  end if;
$g$;
begin
  foreach v_fn in array array['health_check', 'madrasah_notice_matches_schema',
                              'madrasah_list_minimisation'] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn;
    if v_def is null then
      raise exception '122: % does not exist. Nothing changed.', v_fn;
    end if;

    if position('db/122: internal' in v_def) > 0 then
      raise notice '122: % is already gated.', v_fn;
      continue;
    end if;

    --  The anchor: the outermost BEGIN, alone on a line at column 0. All three
    --  have exactly one (inner blocks are indented). Refuse on anything else.
    v_n := (length(v_def) - length(replace(v_def, E'\nbegin\n', ''))) / length(E'\nbegin\n');
    if v_n <> 1 then
      raise exception '122: % has % outermost BEGIN lines, expected exactly 1. NOT changed.',
        v_fn, v_n;
    end if;

    v_new := replace(v_def, E'\nbegin\n', E'\nbegin' || v_gate);
    if v_new = v_def then
      raise exception '122: could not place the gate in %. NOT changed.', v_fn;
    end if;
    execute v_new;
  end loop;
end $mig$;

--  Grants restated as they were: signed-in accounts may CALL it (and are
--  refused inside); anon and PUBLIC may not.
revoke all on function public.health_check() from public, anon;
grant execute on function public.health_check() to authenticated;
revoke all on function public.madrasah_notice_matches_schema() from public, anon;
grant execute on function public.madrasah_notice_matches_schema() to authenticated;
revoke all on function public.madrasah_list_minimisation(text[]) from public, anon;
grant execute on function public.madrasah_list_minimisation(text[]) to authenticated;

--  ---------------------------------------------------------------------
--  PROOF, inside the migration (any failure aborts it). Counts and types
--  only. The test parent may not exist on a fresh database, so the parent
--  half is skipped there rather than failing.
--  ---------------------------------------------------------------------
do $mig$
declare
  v_parent uuid; v_admin uuid; v_state text; v_n int; v_fn text;
begin
  --  No session: allowed, and returns a real answer.
  perform set_config('request.jwt.claims', '', true);
  select jsonb_array_length(public.health_check() -> 'checks') into v_n;
  if v_n is null or v_n < 1 then
    raise exception '122: with no session health_check() no longer answers.';
  end if;
  if jsonb_typeof(public.madrasah_notice_matches_schema()) <> 'object'
     or jsonb_typeof(public.madrasah_list_minimisation()) <> 'object' then
    raise exception '122: with no session the other two no longer answer.';
  end if;

  --  A verified administrator: allowed.
  select r.user_id into v_admin from public.user_roles r
   where r.role = 'admin' order by r.user_id limit 1;
  if v_admin is not null then
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', v_admin, 'role', 'authenticated', 'aal', 'aal2')::text, true);
    begin
      perform public.health_check();
      perform public.madrasah_notice_matches_schema();
      perform public.madrasah_list_minimisation();
    exception when others then
      raise exception '122: a verified administrator was refused (%).', sqlstate;
    end;
    --  The same administrator WITHOUT two-step is not verified: refused.
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', v_admin, 'role', 'authenticated', 'aal', 'aal1')::text, true);
    foreach v_fn in array array['health_check', 'madrasah_notice_matches_schema',
                                'madrasah_list_minimisation'] loop
      v_state := 'answered';
      begin
        execute format('select public.%I()', v_fn);
      exception when others then v_state := sqlstate;
      end;
      if v_state <> '42501' then
        raise exception '122: % answered an administrator with no two-step (%).', v_fn, v_state;
      end if;
    end loop;
  end if;

  --  A parent: refused, all three.
  select l.user_id into v_parent from public.madrasah_parent_logins l limit 1;
  if v_parent is not null then
    perform set_config('request.jwt.claims', jsonb_build_object(
      'sub', v_parent, 'role', 'authenticated', 'aal', 'aal1')::text, true);
    foreach v_fn in array array['health_check', 'madrasah_notice_matches_schema',
                                'madrasah_list_minimisation'] loop
      v_state := 'answered';
      begin
        execute format('select public.%I()', v_fn);
      exception when others then v_state := sqlstate;
      end;
      if v_state <> '42501' then
        raise exception '122: % answered a parent (%).', v_fn, v_state;
      end if;
    end loop;
  end if;

  perform set_config('request.jwt.claims', '', true);
end $mig$;
