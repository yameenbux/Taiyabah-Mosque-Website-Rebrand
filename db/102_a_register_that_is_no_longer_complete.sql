--  =====================================================================
--  102 - A REGISTER THAT IS NO LONGER COMPLETE
--  =====================================================================
--  Fix round 1 of 5 on db/097. That file is applied and is the record;
--  it is not edited. This is a correction on top of it, the same way
--  db/094 corrected db/093 in place rather than rewriting it.
--
--  Four fixes, and one new guard the reviewer asked for instead of a fix.

--  ---------------------------------------------------------------------
--  C1 (Critical) - A SUBMITTED REGISTER CAN SILENTLY BECOME INCOMPLETE.
--  ---------------------------------------------------------------------
--  save_register_draft's upsert never touched `state`. A teacher marks all
--  sixteen and hands in at 18:10; the office adds a seventeenth child to
--  the class at 18:20. `state` stayed 'submitted' while marked_count fell
--  below expected_count. Task 4's registers_missing() and
--  my_registers_outstanding() filter on state = 'submitted' and nothing
--  else, so that register drops off both the office's missed list and the
--  teacher's outstanding list. The child has no mark and no screen will
--  ever say so.
--
--  Proved reachable before this fix, in a rolled-back transaction against
--  the real functions (not just the ON CONFLICT clause in isolation): see
--  db/102's companion report for the pasted output. A register was
--  submitted, its class's roll grown by one, and save_register_draft
--  called again without covering the new child - state stayed 'submitted'.
--
--  The fix only ever moves 'submitted' back to 'draft', never the other
--  way. Nothing here promotes a register - that stays submit_register's
--  job alone, which is why an admin_audit row and a submitted_by are only
--  ever written there.
create or replace function public.save_register_draft(
  p_class uuid, p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_gate jsonb; v_due jsonb; v_m jsonb; v_pupil uuid; v_mark text;
  v_n int := 0; v_kept int := 0; v_on_roll int; v_marked int;
begin
  if not public.may_take_register(p_class) then
    raise exception 'That is not one of your classes.' using errcode = '42501';
  end if;

  --  I2 (Important) - REGISTER_DUE() WAS NEVER CALLED IN THE WRITE PATH.
  --  The brief's Interfaces line said this task consumes register_due();
  --  its Step 2 SQL never did. Without this, a register could be drafted
  --  and submitted for a Sunday, inside a declared closure, or outside the
  --  academic year. Checked here, before the date-shape checks below and
  --  before attendance_permitted(), so nothing can be marked for an
  --  evening the madrasah does not run on - submit_register inherits the
  --  same protection for free, because nothing reaches it to submit.
  v_due := public.register_due(p_class, p_date);
  if not (v_due ->> 'due')::boolean then
    raise exception '%', v_due ->> 'why' using errcode = '22023';
  end if;

  v_gate := public.attendance_permitted();
  if not (v_gate ->> 'permitted')::boolean then
    raise exception '%', v_gate ->> 'why' using errcode = '42501';
  end if;

  if p_date > current_date then
    raise exception 'A register cannot be taken for a day that has not happened.'
      using errcode = '22023';
  end if;
  if p_date < current_date - 14 and not public.verified_madrasah() then
    raise exception 'That evening is more than a fortnight ago. Ask the office '
                    'to correct it, so the record says it was corrected rather '
                    'than taken.' using errcode = '22023';
  end if;

  for v_m in select * from jsonb_array_elements(p_marks) loop
    v_pupil := (v_m ->> 'pupil_id')::uuid;
    v_mark  := v_m ->> 'mark';
    if v_pupil is null or v_mark is null then continue; end if;

    if not exists (select 1 from public.madrasah_pupil_classes pc
                    join public.madrasah_pupils p on p.id = pc.pupil_id
                   where pc.pupil_id = v_pupil and pc.class_id = p_class
                     and p.masjid_id = v_masjid) then
      continue;
    end if;

    --  A PARENT'S WORD IS NOT OVERWRITTEN BY A TICK. Unchanged from 084.
    if exists (select 1 from public.madrasah_attendance a
                where a.pupil_id = v_pupil and a.on_date = p_date
                  and a.source = 'parent')
       and v_mark not in ('present','late') then
      v_kept := v_kept + 1;
      continue;
    end if;

    insert into public.madrasah_attendance
      (masjid_id, pupil_id, class_id, on_date, mark, reason, source, marked_by)
    values (v_masjid, v_pupil, p_class, p_date, v_mark,
            nullif(btrim(v_m ->> 'reason'), ''),
            case when public.verified_madrasah() and not public.is_teacher()
                 then 'office' else 'register' end,
            auth.uid())
    on conflict (pupil_id, on_date) do update
      set mark = excluded.mark, reason = excluded.reason,
          class_id = excluded.class_id, source = excluded.source,
          marked_by = excluded.marked_by, marked_at = now();
    v_n := v_n + 1;
  end loop;

  select count(*) into v_on_roll
    from public.madrasah_pupil_classes pc
    join public.madrasah_pupils p on p.id = pc.pupil_id
   where pc.class_id = p_class and p.left_on is null and p.status = 'on_roll';
  select count(*) into v_marked
    from public.madrasah_attendance a
    join public.madrasah_pupil_classes pc on pc.pupil_id = a.pupil_id
    join public.madrasah_pupils p on p.id = a.pupil_id
   where pc.class_id = p_class and a.on_date = p_date
     and p.left_on is null and p.status = 'on_roll';

  insert into public.madrasah_registers
    (masjid_id, class_id, on_date, expected_count, marked_count)
  values (v_masjid, p_class, p_date, v_on_roll, v_marked)
  on conflict (class_id, on_date) do update
    set expected_count = excluded.expected_count,
        marked_count   = excluded.marked_count,
        --  C1: DEMOTE, NEVER PROMOTE. A register that reads complete now
        --  and then loses a mark - because the roll grew - is no longer
        --  the thing it was submitted as. Only submit_register writes
        --  'submitted'; this can only take it away.
        state = case when excluded.marked_count < excluded.expected_count
                      then 'draft' else public.madrasah_registers.state end,
        updated_at     = now();

  return jsonb_build_object('marked', v_n, 'parent_reports_kept', v_kept,
                            'on_roll', v_on_roll, 'has_mark', v_marked,
                            'missing', greatest(v_on_roll - v_marked, 0));
end $$;

--  ---------------------------------------------------------------------
--  I3 (Important) - MARK_REGISTER'S AUTO-SUBMIT ATTRIBUTED A HAND-IN TO A
--  TEACHER WHO NEVER CHOSE IT.
--  ---------------------------------------------------------------------
--  The live Register screen's "Save the register" button calls
--  mark_register. Once the roll happened to be complete it auto-submitted,
--  writing submitted_by = auth.uid(), submitted_at, and an admin_audit
--  register_submitted row - for an act the teacher was never offered and
--  the screen's own success message ("N children saved") never mentioned.
--  These migrations are live now; the screen that would explain a submit
--  ships later, in Task 8.
--
--  Proved reachable before this fix: mark_register on a fully-markable
--  class returned submitted=true, left the register 'submitted', and wrote
--  one register_submitted admin_audit row, with nobody having asked for a
--  submission - see db/102's companion report.
--
--  So: mark_register now saves ONLY. It never calls submit_register. The
--  return shape keeps 'submitted' in it, always false, so nothing reading
--  the response for that key finds it missing - Task 8 adds the explicit
--  Hand-in button that calls submit_register() for real, on a teacher's
--  actual press.
create or replace function public.mark_register(
  p_class uuid, p_date date, p_marks jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_saved jsonb;
begin
  v_saved := public.save_register_draft(p_class, p_date, p_marks);
  return v_saved || jsonb_build_object('submitted', false);
end $$;

--  ---------------------------------------------------------------------
--  I4 (Important) - db/097 OMITTED THE REVOKE/GRANT PAIR FOR
--  MARK_REGISTER.
--  ---------------------------------------------------------------------
--  The live ACL has been correct only because CREATE OR REPLACE preserves
--  whatever grant a function already had, and db/091 had granted it to
--  authenticated. Replayed standalone against a database that never ran
--  091, db/097 would leave mark_register executable by anon. It is
--  restated here explicitly, same as the other three functions in 097.
revoke all on function public.mark_register(uuid, date, jsonb) from public, anon;
grant execute on function public.mark_register(uuid, date, jsonb) to authenticated;

--  ---------------------------------------------------------------------
--  NOT FIXED, ON PURPOSE - A NEW GUARD INSTEAD.
--  ---------------------------------------------------------------------
--  The reviewer found that submit_register counts marks without binding
--  a.class_id, so for the 3 children who already sit on two active class
--  rolls (the girls' side progression described in db/058 - OOLA,
--  THAANIYAH and so on, which a child may sit in more than one of), a
--  class can read complete on another class's marking.
--
--  Binding class_id would be wrong. madrasah_attendance is
--  UNIQUE (pupil_id, on_date) across the whole masjid, not per class,
--  because one child can only truthfully have been in one place on one
--  evening. Bind the count to class_id and a shared child's single mark
--  would count for neither class - both registers permanently unable to
--  complete - or, if one teacher marks after the other, would silently
--  overwrite the first teacher's mark under the second teacher's name.
--  Both are worse than what exists now.
--
--  So the counts stay exactly as they are. What is added is a health check
--  that says the true thing: THREE CHILDREN, RIGHT NOW, CAN HAVE THEIR
--  MARK STAND IN FOR TWO REGISTERS. Not a bug the code introduced today -
--  a fact about the roll that the code cannot itself resolve, that
--  whoever reads health_check should know.
create or replace function public.pupils_on_two_active_rolls()
returns jsonb language sql stable security definer
set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'check', 'pupils_on_two_active_rolls',
    'ok',    count(*) = 0,
    'detail', case when count(*) = 0
      then 'No child sits on more than one active class roll.'
      else count(*) || ' child' || case when count(*) = 1 then '' else 'ren' end
           || ' sit' || case when count(*) = 1 then 's' else '' end
           || ' on more than one active class roll. madrasah_attendance is '
           || 'UNIQUE (pupil_id, on_date), so a shared child can hold only '
           || 'one mark per evening - one class''s register can read '
           || 'complete on the other class''s marking, and neither '
           || 'teacher can see that from their own screen.' end)
  from (
    select pc.pupil_id
      from public.madrasah_pupil_classes pc
      join public.madrasah_classes c on c.id = pc.class_id and c.is_active
      join public.madrasah_pupils p on p.id = pc.pupil_id
                                    and p.left_on is null and p.status = 'on_roll'
     group by pc.pupil_id
    having count(*) > 1
  ) x;
$$;

revoke all on function public.pupils_on_two_active_rolls() from public, anon;

--  Splice into health_check(), db/094's pattern exactly: read the live
--  definition, anchor on the end of the block 094 itself added, refuse if
--  that anchor is not found rather than silently doing nothing.
do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'health_check';

  if v_def is null then
    raise exception '102: health_check() is not there to patch.';
  end if;

  if position('pupils_on_two_active_rolls' in v_def) > 0 then
    raise notice '102: health_check already has the shared-roll check.';
    return;
  end if;

  v_new := replace(v_def,
$e$  v_checks := v_checks || jsonb_build_object('check','auth_rows_readable',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'auth_rows_readable'); end if;$e$,
$f$  v_checks := v_checks || jsonb_build_object('check','auth_rows_readable',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'auth_rows_readable'); end if;

  --  A CHILD ON TWO ACTIVE ROLLS CAN HOLD ONLY ONE MARK. Added by 102,
  --  after the reviewer found submit_register can read complete on
  --  another class's marking for exactly these children. See the long
  --  comment above pupils_on_two_active_rolls() in db/102.
  begin
    v_jrow := public.pupils_on_two_active_rolls();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the shared-roll check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','pupils_on_two_active_rolls',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'pupils_on_two_active_rolls'); end if;$f$);

  if v_new = v_def then
    raise exception '102: the anchor at the end of the auth_rows_readable block '
                    'was not found. health_check was NOT changed.';
  end if;

  execute v_new;
  raise notice '102: health_check now includes pupils_on_two_active_rolls.';
end $mig$;
