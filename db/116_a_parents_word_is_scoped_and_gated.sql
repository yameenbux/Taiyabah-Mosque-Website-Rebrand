-- ===========================================================================
--  116 - A PARENT'S WORD IS SCOPED, GATED AND DATED LIKE EVERY OTHER MARK
--  29 September 2026
-- ===========================================================================
--  Final whole-branch review, finding C2 (Critical). record_parent_absence()
--  (db/097, live definition unchanged by 102-115) had three holes. Each was
--  PROVED REACHABLE on production before this file was written, in a block
--  that ended in `raise exception` so nothing it wrote survived (the
--  attendance table, the append-only log, masjids, pupils and classes were
--  counted before and after: all unchanged). Called as the office, with the
--  attendance gate SHUT (330 families untold):
--
--    HOLE 2 - THE GATE. A real child of this masjid, a real due evening:
--             {"recorded": true}. attendance_permitted() was false. The
--             privacy notice promises parents "we will tell you before the
--             first mark is made", and docs/GO-LIVE.md says nothing about the
--             register works for anyone. BOTH WERE FALSE FOR THIS ONE PATH.
--             save_register_draft() has called the gate since 097; this
--             function never did. This is the most urgent thing in the
--             dispatch, so it is applied before anything else.
--
--    HOLE 1 - THE TENANT. A pupil belonging to a DIFFERENT masjid, passed as
--             p_pupil: {"recorded": true}. The attendance row came out with
--             masjid_id = the CALLER'S, pupil_id = the FOREIGN child and
--             class_id = the FOREIGN class; db/096's trigger copied it into
--             the append-only log (one row, masjid = the caller's). The same
--             bug db/104 closed on register_history() - except this one
--             WRITES, corrupts another tenant's record, and the log is
--             designed never to be cleaned up.
--
--    HOLE 3 - THE DATE. A date 30 days in the FUTURE, a date 60 days in the
--             PAST, and an evening the madrasah does not run on (register_due()
--             false): all {"recorded": true}. And the class was
--             `select ... limit 1` with no ORDER BY, so a child on two rolls
--             got whichever row the planner met first.
--
--  WHAT CHANGES, in the order the checks run:
--    1. the child must be a child OF THIS MASJID, on the roll, in a class of
--       this masjid - refused exactly as a foreign class is refused by
--       may_take_register(): 'not yours', errcode 42501, the same message for
--       "does not exist", "belongs to somebody else" and "has left", so the
--       refusal cannot be used to probe another tenant's children;
--    2. the class is chosen DETERMINISTICALLY: active first, then the roll
--       joined most recently, then the id as the last word;
--    3. attendance_permitted() is called and its own `why` is the refusal;
--    4. no future date;
--    5. no date more than 14 days back. save_register_draft() exempts the
--       office from this, because the office CORRECTS old registers and the
--       log records the correction as an office mark. This function is
--       different in kind: it writes source = 'parent', a claim that a parent
--       said this, and an office user typing a parent's message in three
--       weeks late is exactly the contemporaneity claim the log must not
--       make. So the limit applies to EVERYONE here, and the way to record an
--       old absence is the register, where the source honestly says 'office'.
--       (Spec 2's parent login will be another caller of this same function
--       and would not have been exempt either way.)
--    6. register_due() for the class it chose - not a Sunday, not inside a
--       closure, not outside the academic year, class running.
--    The opening-day floor (db/117) is added to this function there, by a
--    splice that anchors on the text this file writes.
--
--  NOT CHANGED: SECURITY DEFINER, owner, search_path, the source = 'parent'
--  insert, and its ON CONFLICT clause. Grants are restated below.
--
--  The read-patch-refuse below refuses on a moved anchor: this file is
--  correct only against the db/097 definition it was written against.
-- ===========================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_parent_absence'
     and pg_get_function_identity_arguments(p.oid)
         = 'p_pupil uuid, p_date date, p_mark text, p_reason text';

  if v_def is null then
    raise exception '116: record_parent_absence(uuid, date, text, text) does not exist. Nothing changed.';
  end if;
  if position('attendance_permitted' in v_def) > 0 then
    raise notice '116: record_parent_absence() already calls the gate.';
    return;
  end if;

  --  Splice 1: the two variables the new checks need.
  v_new := replace(v_def,
$a$declare v_masjid uuid := public.current_masjid(); v_class uuid;$a$,
$b$declare v_masjid uuid := public.current_masjid(); v_class uuid;
  v_gate jsonb; v_due jsonb;$b$);
  if v_new = v_def then
    raise exception '116: could not find the declare line. NOT changed.';
  end if;
  v_def := v_new;

  --  Splice 2: the unscoped, unordered class lookup, replaced by the scoped,
  --  ordered one and the checks that follow it.
  v_new := replace(v_def,
$a$  select pc.class_id into v_class from public.madrasah_pupil_classes pc
   where pc.pupil_id = p_pupil limit 1;
$a$,
$b$  --  HOLE 1 CLOSED. The child is looked up THROUGH madrasah_pupils on
  --  current_masjid(), and the class must be this masjid's too. One
  --  message for every way of not qualifying - see this file's header.
  --  HOLE 3 (class) CLOSED. active first, latest roll next, id last.
  select pc.class_id into v_class
    from public.madrasah_pupils p
    join public.madrasah_pupil_classes pc on pc.pupil_id = p.id
    join public.madrasah_classes c on c.id = pc.class_id
   where p.id = p_pupil and p.masjid_id = v_masjid
     and c.masjid_id = v_masjid
     and p.left_on is null and p.status = 'on_roll'
   order by c.is_active desc, pc.added_at desc, c.id
   limit 1;
  if v_class is null then
    raise exception 'That child is not on the roll of one of your classes.'
      using errcode = '42501';
  end if;

  --  HOLE 2 CLOSED. The same gate save_register_draft() has always asked,
  --  and its own words as the refusal.
  v_gate := public.attendance_permitted();
  if not (v_gate ->> 'permitted')::boolean then
    raise exception '%', v_gate ->> 'why' using errcode = '42501';
  end if;

  --  HOLE 3 CLOSED (date).
  if p_date > current_date then
    raise exception 'A parent cannot be recorded as having said a child was '
                    'away on a day that has not happened.'
      using errcode = '22023';
  end if;
  if p_date < current_date - 14 then
    raise exception 'That evening is more than a fortnight ago. Correct it on '
                    'the register instead, so the record says it was corrected '
                    'rather than reported by a parent at the time.'
      using errcode = '22023';
  end if;
  v_due := public.register_due(v_class, p_date);
  if not (v_due ->> 'due')::boolean then
    raise exception '%', v_due ->> 'why' using errcode = '22023';
  end if;
$b$);
  if v_new = v_def then
    raise exception '116: could not find the unscoped class lookup. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  Grants restated exactly as db/097 established them.
revoke all on function public.record_parent_absence(uuid, date, text, text) from public, anon;
grant execute on function public.record_parent_absence(uuid, date, text, text) to authenticated;
