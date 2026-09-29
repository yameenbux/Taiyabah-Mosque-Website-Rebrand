--  =====================================================================
--  123 - THE REGISTER'S THREE RULES CAN BE ASKED ABOUT A MASJID
--  29 September 2026
--  =====================================================================
--
--  WHY. A parent's login has no user_roles row, by design (db/119): that is
--  what makes current_masjid() NULL for a parent, and that NULL is one of the
--  things that keeps a parent out of every staff function. Three functions the
--  register's rules are built from take the masjid ONLY from current_masjid():
--
--      attendance_permitted()   - has every family been told?
--      register_days()          - which evenings does the madrasah run?
--      register_due(class,date) - is that evening one a register is due?
--
--  record_parent_absence() calls all three. Called from a parent, each would
--  see a NULL masjid and answer "no families", "no evenings" and "outside the
--  academic year" - a refusal every time, for the wrong reason, on a screen
--  that says the madrasah is closed when it is not. The two ways round it are
--  both bad: widen current_masjid() (which would let a parent satisfy every
--  staff function's scoping - the one thing slice 1 was careful to prevent),
--  or copy the three rules into a parent-only version (which is how two
--  copies of a rule drift apart).
--
--  SO EACH RULE IS MOVED, NOT COPIED. The body of each becomes
--  <name>_for(p_masjid, ...) with the masjid as an ARGUMENT, and the original
--  name becomes a one-line wrapper that passes current_masjid(). The bodies
--  are DERIVED FROM THE LIVE DEFINITIONS by text replacement inside this
--  migration (read-patch-refuse: each must contain current_masjid() exactly
--  once, or nothing changes), so the moved logic is byte-for-byte what was
--  running, not what somebody remembers it saying.
--
--  THE _for FUNCTIONS TAKE ANY MASJID, so they are executable by nobody but
--  the database's owner. A signed-in account could otherwise ask, for any
--  tenant, how many families it has and how many have been told. The three
--  wrappers - and record_parent_absence(), which is SECURITY DEFINER and owned
--  by the same role - are the only way in.
--
--  PROOF THE MOVE CHANGED NOTHING, in this migration, before it can commit.
--  For four different callers (an administrator, the test teacher, the test
--  parent, and no session) a digest is taken of:
--      attendance_permitted(), register_days(), and register_due() for every
--      class on each of 46 days (5 back to 40 forward) - about 2,250 answers
--  before the change and again after. If the two digests differ for any
--  caller the migration aborts and nothing is applied. Digests, not answers:
--  nothing printed.
--  =====================================================================
do $mig$
declare
  v_days_def text; v_due_def text; v_perm_def text;
  v_admin uuid; v_teacher constant uuid := '42a0f447-f2b6-4a31-86c3-8bc2bddaad1b';
  v_parent uuid;
  v_who text; v_claims text; v_d text; v_pass int;
  v_before jsonb := '{}'; v_after jsonb := '{}';
  v_n int; v_key text;
begin
  if to_regprocedure('public.register_due_for(uuid, uuid, date)') is not null then
    raise notice '123: the _for functions are already there. Nothing done.';
    return;
  end if;

  select pg_get_functiondef('public.register_days()'::regprocedure) into v_days_def;
  select pg_get_functiondef('public.register_due(uuid, date)'::regprocedure) into v_due_def;
  select pg_get_functiondef('public.attendance_permitted()'::regprocedure) into v_perm_def;

  --  Read-patch-refuse: each body must mention current_masjid() exactly once.
  foreach v_key in array array['days', 'due', 'perm'] loop
    v_n := case v_key
      when 'days' then (length(v_days_def) - length(replace(v_days_def, 'public.current_masjid()', ''))) / length('public.current_masjid()')
      when 'due'  then (length(v_due_def)  - length(replace(v_due_def,  'public.current_masjid()', ''))) / length('public.current_masjid()')
      else             (length(v_perm_def) - length(replace(v_perm_def, 'public.current_masjid()', ''))) / length('public.current_masjid()') end;
    if v_n <> 1 then
      raise exception '123: % names current_masjid() % times, expected 1. NOTHING changed.', v_key, v_n;
    end if;
  end loop;
  if position('public.register_days()' in v_due_def) = 0 then
    raise exception '123: register_due() no longer calls register_days(). NOTHING changed.';
  end if;

  select r.user_id into v_admin from public.user_roles r
   where r.role = 'admin' order by r.user_id limit 1;
  select l.user_id into v_parent from public.madrasah_parent_logins l order by l.created_at limit 1;

  for v_pass in 1..2 loop
    if v_pass = 2 then
      --  ---- THE MOVE ------------------------------------------------------
      execute replace(replace(v_days_def,
        'FUNCTION public.register_days()',
        'FUNCTION public.register_days_for(p_masjid uuid)'),
        'public.current_masjid()', 'p_masjid');

      execute replace(replace(replace(v_due_def,
        'FUNCTION public.register_due(p_class uuid, p_date date)',
        'FUNCTION public.register_due_for(p_masjid uuid, p_class uuid, p_date date)'),
        'public.current_masjid()', 'p_masjid'),
        'public.register_days()', 'public.register_days_for(p_masjid)');

      execute replace(replace(v_perm_def,
        'FUNCTION public.attendance_permitted()',
        'FUNCTION public.attendance_permitted_for(p_masjid uuid)'),
        'public.current_masjid()', 'p_masjid');

      --  ---- THE ORIGINAL NAMES BECOME ONE-LINE WRAPPERS -------------------
      execute $w$
        create or replace function public.register_days()
        returns text[] language sql stable security definer
        set search_path = public, pg_temp as
        $b$ select public.register_days_for(public.current_masjid()); $b$ $w$;
      execute $w$
        create or replace function public.register_due(p_class uuid, p_date date)
        returns jsonb language sql stable security definer
        set search_path = public, pg_temp as
        $b$ select public.register_due_for(public.current_masjid(), p_class, p_date); $b$ $w$;
      execute $w$
        create or replace function public.attendance_permitted()
        returns jsonb language sql stable security definer
        set search_path = public, pg_temp as
        $b$ select public.attendance_permitted_for(public.current_masjid()); $b$ $w$;
    end if;

    --  ---- THE DIGESTS, for four callers -----------------------------------
    foreach v_who in array array['admin', 'teacher', 'parent', 'nobody'] loop
      v_claims := case v_who
        when 'admin'   then case when v_admin is null then null else jsonb_build_object(
                              'sub', v_admin, 'role', 'authenticated', 'aal', 'aal2')::text end
        when 'teacher' then jsonb_build_object(
                              'sub', v_teacher, 'role', 'authenticated', 'aal', 'aal1')::text
        when 'parent'  then case when v_parent is null then null else jsonb_build_object(
                              'sub', v_parent, 'role', 'authenticated', 'aal', 'aal1')::text end
        else '{}' end;   --  '{}', not '': current_masjid() casts the claims to jsonb
      continue when v_claims is null;
      perform set_config('request.jwt.claims', v_claims, true);
      select md5(
               public.attendance_permitted()::text || '#'
            || coalesce(array_to_string(public.register_days(), ','), '-') || '#'
            || coalesce((select string_agg(public.register_due(c.id, current_date - 5 + g.i)::text,
                                           '|' order by c.id, g.i)
                           from public.madrasah_classes c
                          cross join generate_series(0, 45) g(i)
                        ), '-'))
        into v_d;
      if v_pass = 1 then v_before := v_before || jsonb_build_object(v_who, v_d);
      else               v_after  := v_after  || jsonb_build_object(v_who, v_d); end if;
    end loop;
    perform set_config('request.jwt.claims', '{}', true);
  end loop;

  if v_before is distinct from v_after then
    raise exception '123: the move changed an answer. before=% after=%. NOTHING applied.',
      v_before, v_after;
  end if;
  if (select count(*) from jsonb_object_keys(v_after)) < 3 then
    raise exception '123: fewer than three callers were compared (%). NOTHING applied.', v_after;
  end if;
end $mig$;

--  The _for functions: the database's owner only.
revoke all on function public.register_days_for(uuid) from public, anon, authenticated;
revoke all on function public.register_due_for(uuid, uuid, date) from public, anon, authenticated;
revoke all on function public.attendance_permitted_for(uuid) from public, anon, authenticated;

--  The wrappers keep exactly the grants the originals had (create or replace
--  does not change them); restated so this file states them.
revoke all on function public.register_days() from public, anon;
revoke all on function public.register_due(uuid, date) from public, anon;
revoke all on function public.attendance_permitted() from public, anon;
grant execute on function public.register_days() to authenticated;
grant execute on function public.register_due(uuid, date) to authenticated;
grant execute on function public.attendance_permitted() to authenticated;
