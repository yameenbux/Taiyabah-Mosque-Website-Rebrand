-- ===========================================================================
--  113 - THE HISTORY IS AUDITED, THE GRID SAYS WHO IS DONE, AND SUNDAY IS
--  SPELLED RIGHT
--  28 September 2026
-- ===========================================================================
--  Task 11 of the register rebuild - the office's own view of what was never
--  taken and what a mark used to say. Three fixes, none of them to
--  registers_missing() or register_due()'s own DUE logic, which Tasks 4, 7
--  and 10 already depend on and which stays correct.
--
--  A - register_history() WROTE NO AUDIT ROW.
--  ---------------------------------------------------------------------
--  db/089 gave seven people-driven functions an actor on their admin_audit
--  row, madrasah_pupil_one() foremost among them - "the audit of somebody
--  opening a child's record... the one action in this system that most
--  needs a name against it." register_history() (db/103, scoped by db/104)
--  is the same shape of thing and was never in that list, because it did
--  not exist yet when db/089 was written: it hands back a whole class's
--  marks, reasons, sources and children's NAMES for one evening, and wrote
--  nothing down about who asked for it.
--
--  Checked before this file touched anything - zero rows in production:
--
--      select count(*) from admin_audit where action = 'register_history_read';
--      -> 0
--
--  THE AUDIT ROW NAMES THE CLASS AND THE DATE, NEVER A CHILD. CLAUDE.md's
--  rule for the SCREEN - "the list says whether, the record says what" -
--  applies to the audit trail behind it too: an audit log a curious admin
--  can browse is itself a list, and a list of children's names sitting in
--  admin_audit alongside cron rows and webhook callbacks is the same
--  overexposure db/089 fixed once already, just one table over. detail
--  carries jsonb_build_object('class', p_class, 'on_date', p_date) and
--  nothing else - no pupil id, no name, no mark.
--
--  WRITTEN ONLY ON A REAL READ. The insert sits after BOTH guards -
--  verified_madrasah() and the masjid-scope check db/104 added - so a
--  teacher's refusal and a request for another masjid's class write
--  nothing, the same way madrasah_pupil_one() (db/089) only audits an
--  actual open, not a refused attempt. Proved below and in this task's
--  report: a teacher's own call to register_history() leaves admin_audit
--  untouched, and the office's real read of it writes exactly one row.
--
--  B - THE EVENING GRID COULD NOT SAY WHICH REGISTERS WERE HANDED IN.
--  ---------------------------------------------------------------------
--  db/110 gave madrasah_register_list() - ONE class, opened - its own
--  state and submitted_at, left-joined off madrasah_registers, because a
--  teacher reopening a submitted register saw the identical screen a
--  fully-marked draft would show. madrasah_registers_list() - the WHOLE
--  EVENING'S grid, the screen before that, is the same gap one level up:
--  it can already tell a class is "Taken" by comparing marked to on_roll,
--  but marked-equals-on_roll is not the same fact as submitted. A register
--  corrected back to draft by db/102's demotion rule after a full count
--  still reads "Taken" on the grid while the single-class view underneath
--  it (db/110) correctly shows Hand-in waiting to be pressed again.
--
--  THE SAME ADDITIVE SHAPE AS db/110, ONE LEVEL UP. A left join, not an
--  inner one - a class with nothing saved yet tonight has no row in
--  madrasah_registers for (id, p_date), and both new columns come back
--  null, exactly what db/110 already established for the single-class
--  read. Two more named keys on an existing row object are additive for
--  every caller that reads named keys off it, which is what JSON is
--  always read as in this codebase (db/110's own words, extended one
--  level).
--
--  C - db/095's WEEKDAY MESSAGE READ "...ON A SUNDAY   ." WITH TWO SPACES
--      BEFORE THE FULL STOP.
--  ---------------------------------------------------------------------
--  to_char(p_date, 'Day') right-pads every weekday name to nine
--  characters - "Sunday   ", not "Sunday" - a defect carried since db/095
--  and never fixed. 'FMDay' (fill mode) suppresses the padding; nothing
--  else about register_due() changes; Tasks 7 and 10 depend on its DUE
--  logic, untouched here, exactly as db/104's own header insisted when it
--  touched this function's callers rather than register_due() itself.
--
--  Proved before and after, read-only, with a JWT context set first - see
--  this task's report for why that matters (current_masjid() is NULL
--  without one, and register_due() answers "Nobody has said which
--  evenings the madrasah runs yet" instead of ever reaching the weekday
--  branch):
--
--      before: 'The madrasah does not run on a Sunday   .'   (11 chars
--               after "a ", not 6 - two trailing spaces before the stop)
--      after:  'The madrasah does not run on a Sunday.'
--
--  READ-PATCH-REFUSE THROUGHOUT. Each of the three functions below is read
--  live with pg_get_functiondef(), patched with replace() on an anchor
--  taken from that same live text, and the migration refuses rather than
--  silently doing nothing if the anchor has moved.
-- ===========================================================================

--  ---------------------------------------------------------------------
--  A - register_history() NOW WRITES WHO READ IT.
--  ---------------------------------------------------------------------
do $mig_a$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'register_history';

  if v_def is null then
    raise exception '113: public.register_history() does not exist. Nothing changed.';
  end if;

  if position('register_history_read' in v_def) > 0 then
    raise notice '113: register_history() already audits its reads.';
  else
    --  Anchor: the start of the row-building select, reached ONLY after
    --  both the verified_madrasah() guard and db/104's masjid-scope guard
    --  have already returned 'allowed:false' for anyone who fails either -
    --  so the insert below runs on a genuine read, never a refusal.
    v_new := replace(v_def,
$a$  select coalesce(jsonb_agg(to_jsonb(x) order by x.written_at desc), '[]'::jsonb)
    into v_rows
  from (
    select btrim(p.first_name || ' ' || p.last_name) as child,$a$,
$b$  --  ADDED BY 113 (ruling B / db/089's rule extended). CLASS AND DATE
  --  ONLY - never a child. This function's whole job is to name children;
  --  the audit of reading it must not repeat that naming into a table a
  --  wider admin audience can browse.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'register_history_read',
          jsonb_build_object('class', p_class, 'on_date', p_date));

  select coalesce(jsonb_agg(to_jsonb(x) order by x.written_at desc), '[]'::jsonb)
    into v_rows
  from (
    select btrim(p.first_name || ' ' || p.last_name) as child,$b$);

    if v_new = v_def then
      raise exception '113: could not find the row-building anchor in '
                      'register_history(). NOT changed.';
    end if;
    execute v_new;
    raise notice '113: register_history() now audits who read it.';
  end if;
end $mig_a$;

--  ---------------------------------------------------------------------
--  B - THE EVENING GRID NOW CARRIES EACH CLASS'S REGISTER STATE.
--  ---------------------------------------------------------------------
do $mig_b$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'madrasah_registers_list';

  if v_def is null then
    raise exception '113: public.madrasah_registers_list() does not exist. Nothing changed.';
  end if;

  if position('r.state, r.submitted_at' in v_def) > 0 then
    raise notice '113: madrasah_registers_list() already carries register state.';
  else
    v_new := replace(v_def,
$a$           (select count(*) from public.madrasah_attendance a
             where a.class_id = c.id and a.on_date = p_date
               and a.mark in ('absent','excused'))            as away
      from public.madrasah_classes c
      left join public.madrasah_staff st on st.id = c.main_teacher_id
     where c.masjid_id = v_masjid and c.is_active$a$,
$b$           (select count(*) from public.madrasah_attendance a
             where a.class_id = c.id and a.on_date = p_date
               and a.mark in ('absent','excused'))            as away,
           --  ADDED BY 113 (ruling B). THE SAME ADDITIVE SHAPE db/110 gave
           --  madrasah_register_list()'s single class, one level up. A
           --  left join, not an inner one: a class with nothing saved yet
           --  tonight has no row in madrasah_registers for (id, p_date),
           --  and both come back null - draft in everything but name.
           r.state, r.submitted_at
      from public.madrasah_classes c
      left join public.madrasah_staff st on st.id = c.main_teacher_id
      left join public.madrasah_registers r
             on r.class_id = c.id and r.on_date = p_date
     where c.masjid_id = v_masjid and c.is_active$b$);

    if v_new = v_def then
      raise exception '113: could not find the away-count anchor in '
                      'madrasah_registers_list(). NOT changed.';
    end if;
    execute v_new;
    raise notice '113: madrasah_registers_list() now carries register state per class.';
  end if;
end $mig_b$;

--  ---------------------------------------------------------------------
--  C - THE WEEKDAY MESSAGE IS SPELLED RIGHT.
--  ---------------------------------------------------------------------
do $mig_c$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'register_due';

  if v_def is null then
    raise exception '113: public.register_due() does not exist. Nothing changed.';
  end if;

  if position('FMDay' in v_def) > 0 then
    raise notice '113: register_due() already spells the weekday right.';
  else
    v_new := replace(v_def,
$a$      'why', 'The madrasah does not run on a ' || to_char(p_date, 'Day') || '.');$a$,
$b$      --  FIXED BY 113 (ruling C). to_char(p_date,'Day') right-pads to nine
      --  characters, so this read "...on a Sunday   ." with two spaces
      --  before the full stop. 'FMDay' (fill mode) suppresses the
      --  padding. Nothing else about register_due() changes.
      'why', 'The madrasah does not run on a ' || to_char(p_date, 'FMDay') || '.');$b$);

    if v_new = v_def then
      raise exception '113: could not find the weekday-message anchor in '
                      'register_due(). NOT changed.';
    end if;
    execute v_new;
    raise notice '113: register_due() no longer pads the weekday name.';
  end if;
end $mig_c$;

--  ---------------------------------------------------------------------
--  GRANTS, restated exactly as db/095/103/104/090/091 established them.
--  CREATE OR REPLACE preserves existing grants, but db/104's own reminder
--  applies here too: a migration replayed standalone against a database
--  that never carried them forward should not leave any of these three
--  wide open to anon.
--  ---------------------------------------------------------------------
revoke all on function public.register_history(uuid, date) from public, anon;
revoke all on function public.madrasah_registers_list(date) from public, anon;
revoke all on function public.register_due(uuid, date) from public, anon;
grant execute on function public.register_history(uuid, date) to authenticated;
grant execute on function public.madrasah_registers_list(date) to authenticated;
grant execute on function public.register_due(uuid, date) to authenticated;
