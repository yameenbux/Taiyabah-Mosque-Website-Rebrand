-- ===========================================================================
--  117 - THE REGISTER HAS AN OPENING DAY, AND NOTHING IS REPORTED BEFORE IT
--  29 September 2026
-- ===========================================================================
--  Final whole-branch review, finding C1 (Critical).
--
--  db/109, db/111/112 and the teacher gate each stopped a missed-register
--  surface from reporting while marking is forbidden - by testing the gate AS
--  IT IS NOW. None of them floored the WINDOW. The day the office finishes
--  telling the 330 families and attendance_permitted() flips true, every
--  surface reports the fortnight nobody was allowed to mark:
--    Today       "440 registers were not taken"
--    Monday mail "220 registers not submitted", all 44 classes
--    office panel 440 rows, each naming a class, a date and A TEACHER
--    each teacher "10 earlier registers are still to hand in" + a link
--  and save_register_draft() lets a teacher write back 14 days, so they can.
--
--  TWO HARMS. It accuses volunteers of failing to do what the office had
--  locked - the fault db/109's own header exists to prevent, displaced in
--  time rather than avoided. And it invites back-filling ~10 evenings x ~12
--  children per class FROM MEMORY: thousands of Article 9 records asserting
--  where a named child was on a named evening, in an append-only log a
--  safeguarding enquiry would later read as contemporaneous. Fabricated
--  attendance is worse than absent attendance.
--
--  THE FIX: THE WINDOW HAS A FLOOR, DERIVED, NEVER STORED.
--  register_opened_on(masjid) answers "the first day every family that then
--  had a child on the roll had been told the register is being kept" - the
--  day attendance_permitted() FIRST became true. It is read off
--  madrasah_parent_notices, so it cannot be forgotten, and it is applied as
--  greatest(window start, opened_on) in every place a missed register is
--  counted or listed:
--    registers_missing()          registers_missing_count()
--    my_registers_outstanding()   madrasah_today()'s fortnight item (112)
--    outstanding_summary()'s digest CTE (108)
--  and, because a floor on what is REPORTED that leaves what can be WRITTEN
--  untouched only stops the invitation and not the act, in
--    save_register_draft()        record_parent_absence()
--  which now refuse an evening before the register opened.
--
--  WHY NOT max(told_on), which was the brief's own first thought. For the
--  ordinary case - every family exists, every family is told once - the two
--  are identical. They part company the first time either of these happens,
--  and both will:
--    * A family is told AGAIN (a materially changed notice is "another row
--      with the same kind and a later date", db/082's own header). max(told_on)
--      moves to that day and every missed register before it vanishes.
--    * A family ENROLS after the register opened. attendance_permitted()
--      counts every household on the roll, so one untold newcomer shuts the
--      gate for everyone until they are told; max(told_on) then jumps to the
--      day they were, and three weeks of genuinely missed registers are
--      floored out of sight by one enrolment.
--  Both would make the floor SILENTLY HIDE REAL MISSES, which is the reverse
--  of the fault being fixed. So the day is derived as the earliest date D
--  such that every household that existed on D (created on or before D) and
--  has a child on the roll had its FIRST attendance notice on or before D.
--  A later enrolment cannot move it; a re-telling cannot move it.
--  Households with nobody on the roll are ignored, exactly as the gate
--  ignores them. Never told at all = NULL = "not opened yet".
--
--  WHEN THE FLOOR SWALLOWS THE WHOLE WINDOW IT SAYS SO IN WORDS. A bare zero
--  reads as "everything was taken". Each function now returns opened_on,
--  swallowed and note - "The register opened on 3 October; there is nothing
--  before it to report." - and when the floor only TRIMS the window, note says
--  "Counted from 3 October, when the register opened." so a smaller number is
--  not mistaken for better attendance. Today gets a quiet item; the panel, the
--  teacher's page and the Monday email render `note`. The wording lives in ONE
--  function (register_opened_note), so no two surfaces can phrase it apart.
--
--  DEPLOY ORDER. messages.ts (notify) reads the new digest fields and is
--  deployed BEFORE this file: a renderer that finds them absent renders
--  exactly as it did.
--
--  EVERY SPLICE below reads the live definition, REFUSES if an anchor has
--  moved or does not occur exactly as often as expected, and never changes
--  SECURITY DEFINER, owner or search_path. Grants are restated at the end.
--  Nothing in this file selects or builds a pupil, guardian or staff name.
-- ===========================================================================

--  ---------------------------------------------------------------------
--  THE THREE HELPERS. Definer-owned and NOT executable by anon or
--  authenticated: only other definer functions call them, and the masjid is
--  an argument (not current_masjid()) so that outstanding_summary() can ask
--  under pg_cron, where auth.uid() is null - db/108's whole lesson.
--  ---------------------------------------------------------------------
create or replace function public.register_opened_on(p_masjid uuid)
returns date language sql stable security definer
set search_path = public, pg_temp as $$
  with told as (
    select n.household_id, min(n.told_on) as first_told
      from public.madrasah_parent_notices n
      join public.madrasah_households h on h.id = n.household_id
     where n.masjid_id = p_masjid and h.masjid_id = p_masjid
       and n.kind = 'attendance_notice'
       and exists (select 1 from public.madrasah_pupils p
                    where p.household_id = h.id and p.left_on is null)
     group by n.household_id)
  select min(c.d)
    from (select distinct first_told as d from told) c
   where not exists (
     select 1 from public.madrasah_households h
      where h.masjid_id = p_masjid
        and exists (select 1 from public.madrasah_pupils p
                     where p.household_id = h.id and p.left_on is null)
        and h.created_at::date <= c.d
        and coalesce((select t.first_told from told t where t.household_id = h.id),
                     'infinity'::date) > c.d)
$$;

create or replace function public.register_opened_said(p_opened date)
returns text language sql stable
set search_path = public, pg_temp as $$
  select to_char(p_opened, 'FMDD FMMonth')
         || case when date_part('year', p_opened) <> date_part('year', current_date)
                 then ' ' || date_part('year', p_opened)::int else '' end
$$;

create or replace function public.register_opened_note(p_opened date, p_swallowed boolean)
returns text language sql stable
set search_path = public, pg_temp as $$
  select case
    when p_opened is null
      then 'The register has not opened yet, so there is nothing to report.'
    when p_swallowed
      then 'The register opened on ' || public.register_opened_said(p_opened)
           || '; there is nothing before it to report.'
    else 'Counted from ' || public.register_opened_said(p_opened)
         || ', when the register opened.' end
$$;

revoke all on function public.register_opened_on(uuid) from public, anon, authenticated;
revoke all on function public.register_opened_said(date) from public, anon, authenticated;
revoke all on function public.register_opened_note(date, boolean) from public, anon, authenticated;

--  ---------------------------------------------------------------------
--  A splice that refuses. pg_temp: gone when this migration's session ends.
--  Refuses unless the anchor occurs EXACTLY p_expect times - a moved anchor
--  and a duplicated one are both a reason to stop rather than guess.
--  ---------------------------------------------------------------------
create or replace function pg_temp.splice(p_def text, p_anchor text, p_repl text,
                                          p_expect int, p_what text)
returns text language plpgsql as $$
declare v_n int;
begin
  v_n := (length(p_def) - length(replace(p_def, p_anchor, ''))) / length(p_anchor);
  if v_n <> p_expect then
    raise exception '117: anchor "%" occurs % time(s), expected %. NOT changed.',
      p_what, v_n, p_expect;
  end if;
  return replace(p_def, p_anchor, p_repl);
end $$;

--  ---------------------------------------------------------------------
--  1. registers_missing(p_from, p_to) - the office's list.
--  ---------------------------------------------------------------------
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'registers_missing'
     and pg_get_function_identity_arguments(p.oid) = 'p_from date, p_to date';
  if v_def is null then raise exception '117: registers_missing() does not exist.'; end if;
  if position('register_opened_on' in v_def) > 0 then
    raise notice '117: registers_missing() already floored.'; return;
  end if;

  --  Every return that names the window now names the window ACTUALLY
  --  counted, plus what the floor did.
  v_def := pg_temp.splice(v_def,
$a$'from', p_from, 'to', p_to,$a$,
$b$'from', v_from, 'to', p_to,
                              'opened_on', v_opened, 'swallowed', false, 'note', v_note,$b$,
    3, 'registers_missing returns');
  v_def := pg_temp.splice(v_def,
$a$generate_series(p_from, p_to, interval '1 day')$a$,
$b$generate_series(v_from, p_to, interval '1 day')$b$,
    1, 'registers_missing series');
  v_def := pg_temp.splice(v_def,
$a$  v_rows jsonb;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;
$a$,
$b$  v_rows jsonb;
  v_opened date; v_from date; v_swallowed boolean; v_note text;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;

  --  ADDED BY 117 - see this file's header. The window starts no earlier
  --  than the day the register opened. If that swallows all of it, SAY SO
  --  rather than return a bare zero, which reads as "everything was taken".
  v_opened := public.register_opened_on(v_masjid);
  v_swallowed := (v_opened is null or v_opened > p_to);
  v_from := case when v_opened is null then p_from else greatest(p_from, v_opened) end;
  v_note := case when v_swallowed then public.register_opened_note(v_opened, true)
                 when v_opened > p_from then public.register_opened_note(v_opened, false)
            end;
  if v_swallowed then
    return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to,
                              'count', 0, 'rows', '[]'::jsonb,
                              'opened_on', v_opened, 'swallowed', true,
                              'note', v_note);
  end if;
$b$, 1, 'registers_missing begin');
  execute v_def;
end $mig$;

--  ---------------------------------------------------------------------
--  2. registers_missing_count(p_from, p_to) - db/115's names-free sibling.
--  ---------------------------------------------------------------------
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'registers_missing_count'
     and pg_get_function_identity_arguments(p.oid) = 'p_from date, p_to date';
  if v_def is null then raise exception '117: registers_missing_count() does not exist.'; end if;
  if position('register_opened_on' in v_def) > 0 then
    raise notice '117: registers_missing_count() already floored.'; return;
  end if;

  v_def := pg_temp.splice(v_def,
$a$'from', p_from, 'to', p_to,$a$,
$b$'from', v_from, 'to', p_to,
                              'opened_on', v_opened, 'swallowed', false, 'note', v_note,$b$,
    3, 'registers_missing_count returns');
  v_def := pg_temp.splice(v_def,
$a$generate_series(p_from, p_to, interval '1 day')$a$,
$b$generate_series(v_from, p_to, interval '1 day')$b$,
    1, 'registers_missing_count series');
  v_def := pg_temp.splice(v_def,
$a$  v_count integer;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;
$a$,
$b$  v_count integer;
  v_opened date; v_from date; v_swallowed boolean; v_note text;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;

  --  ADDED BY 117 - the same floor, computed the same way, as its parent.
  v_opened := public.register_opened_on(v_masjid);
  v_swallowed := (v_opened is null or v_opened > p_to);
  v_from := case when v_opened is null then p_from else greatest(p_from, v_opened) end;
  v_note := case when v_swallowed then public.register_opened_note(v_opened, true)
                 when v_opened > p_from then public.register_opened_note(v_opened, false)
            end;
  if v_swallowed then
    return jsonb_build_object('allowed', true, 'from', p_from, 'to', p_to,
                              'count', 0, 'opened_on', v_opened,
                              'swallowed', true, 'note', v_note);
  end if;
$b$, 1, 'registers_missing_count begin');
  execute v_def;
end $mig$;

--  ---------------------------------------------------------------------
--  3. my_registers_outstanding() - the teacher's own backlog.
--  ---------------------------------------------------------------------
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'my_registers_outstanding';
  if v_def is null then raise exception '117: my_registers_outstanding() does not exist.'; end if;
  if position('register_opened_on' in v_def) > 0 then
    raise notice '117: my_registers_outstanding() already floored.'; return;
  end if;

  v_def := pg_temp.splice(v_def,
$a$  v_rows jsonb;
begin
  if v_staff is null then$a$,
$b$  v_rows jsonb;
  v_opened date; v_from date; v_note text;
begin
  if v_staff is null then$b$, 1, 'my_registers_outstanding declare');
  v_def := pg_temp.splice(v_def,
$a$  select array_agg(d::date) into v_due_dates
    from generate_series(current_date - 14, current_date, interval '1 day') d$a$,
$b$  --  ADDED BY 117 - see this file's header. A teacher is never told a
  --  register is "still to hand in" for an evening before it opened.
  v_opened := public.register_opened_on(public.current_masjid());
  if v_opened is null or v_opened > current_date then
    return jsonb_build_object('allowed', true, 'count', 0, 'rows', '[]'::jsonb,
                              'opened_on', v_opened, 'swallowed', true,
                              'note', public.register_opened_note(v_opened, true));
  end if;
  v_from := greatest(current_date - 14, v_opened);
  v_note := case when v_opened > current_date - 14
                 then public.register_opened_note(v_opened, false) end;

  select array_agg(d::date) into v_due_dates
    from generate_series(v_from, current_date, interval '1 day') d$b$,
    1, 'my_registers_outstanding series');
  v_def := pg_temp.splice(v_def,
$a$  return jsonb_build_object('allowed', true,
                            'count', jsonb_array_length(v_rows), 'rows', v_rows);$a$,
$b$  return jsonb_build_object('allowed', true,
                            'count', jsonb_array_length(v_rows), 'rows', v_rows,
                            'opened_on', v_opened, 'swallowed', false,
                            'note', v_note);$b$,
    1, 'my_registers_outstanding return');
  execute v_def;
end $mig$;

--  ---------------------------------------------------------------------
--  4. madrasah_today() - db/112's fortnight item.
--  ---------------------------------------------------------------------
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'madrasah_today';
  if v_def is null then raise exception '117: madrasah_today() does not exist.'; end if;
  if position('register_opened_on' in v_def) > 0 then
    raise notice '117: madrasah_today() already floored.'; return;
  end if;

  v_def := pg_temp.splice(v_def,
$a$  v_gate jsonb;
begin
$a$,
$b$  v_gate jsonb;
  v_opened date;
begin
$b$, 1, 'madrasah_today declare');
  --  NULL cannot occur here (this block only runs when marking is
  --  permitted, which needs every family told) but if it ever did, today is
  --  the floor: an EMPTY window, never an unfloored one.
  v_def := pg_temp.splice(v_def,
$a$    select count(*) into n
      from (
        with v_reg_days as ($a$,
$b$    v_opened := coalesce(public.register_opened_on(v_masjid), current_date);
    select count(*) into n
      from (
        with v_reg_days as ($b$, 1, 'madrasah_today count');
  v_def := pg_temp.splice(v_def,
$a$generate_series(current_date - 14, current_date - 1,$a$,
$b$generate_series(greatest(current_date - 14, v_opened), current_date - 1,$b$,
    1, 'madrasah_today series');
  --  Unchanged wording when the fortnight is whole; says where it starts
  --  when it is not.
  v_def := pg_temp.splice(v_def,
$a$'said','In the last fortnight: a register not taken is not a register '
               || 'taken late. Nobody was recorded as being in that room.',$a$,
$b$'said', case when v_opened > current_date - 14
                        then public.register_opened_note(v_opened, false)
                             || ' A register '
                        else 'In the last fortnight: a register ' end
               || 'not taken is not a register '
               || 'taken late. Nobody was recorded as being in that room.',$b$,
    1, 'madrasah_today said');
  --  Nothing to count from a floored fortnight is SAID, never left as an
  --  absent item that reads as "every register was taken".
  v_def := pg_temp.splice(v_def,
$a$        'href','register/','action','Open the registers');
    end if;
  end if;
$a$,
$b$        'href','register/','action','Open the registers');
    end if;
    if n = 0 and v_opened > current_date - 14 then
      v_items := v_items || jsonb_build_object(
        'key','registers_opened','count',0,'tone','quiet',
        'title','Nothing to count before the register opened',
        'said', public.register_opened_note(v_opened, true),
        'href','register/','action','Open the registers');
    end if;
  end if;
$b$, 1, 'madrasah_today item end');
  execute v_def;
end $mig$;

--  ---------------------------------------------------------------------
--  5. outstanding_summary() - the Monday email's numbers (db/108/109).
--  ---------------------------------------------------------------------
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'outstanding_summary'
     and pg_get_function_identity_arguments(p.oid) = 'p_masjid uuid';
  if v_def is null then raise exception '117: outstanding_summary() does not exist.'; end if;
  if position('register_opened_on' in v_def) > 0 then
    raise notice '117: outstanding_summary() already floored.'; return;
  end if;

  --  v_opened is scoped by (select m from me), never current_masjid():
  --  under pg_cron auth.uid() is null and current_masjid() with it.
  v_def := pg_temp.splice(v_def,
$a$       v_due_dates as (
         select g::date as on_date
           from generate_series((select d from today) - 7,
                                 (select d from today) - 1,
                                 interval '1 day') g$a$,
$b$       --  ADDED BY 117. The day the register opened; NULL (never) floors the
       --  window to empty, not to nothing.
       v_opened as (
         select public.register_opened_on((select m from me)) as d),
       v_due_dates as (
         select g::date as on_date
           from generate_series(greatest((select d from today) - 7,
                                          coalesce((select d from v_opened),
                                                   (select d from today))),
                                 (select d from today) - 1,
                                 interval '1 day') g$b$,
    1, 'outstanding_summary due dates');
  v_def := pg_temp.splice(v_def,
$a$               'open', true,
               'families_untold', 0,
$a$,
$b$               'open', true,
               'families_untold', 0,
               --  ADDED BY 117 - see this file's header. `swallowed` means
               --  the floor took the whole week; `note` says so in words, or
               --  says where the count starts when it only trimmed it.
               'opened_on', (select d from v_opened),
               'swallowed', ((select d from v_opened) is null
                             or (select d from v_opened) > (select d from today) - 1),
               'note',
                 case when (select d from v_opened) is null
                           or (select d from v_opened) > (select d from today) - 1
                      then public.register_opened_note((select d from v_opened), true)
                      when (select d from v_opened) > (select d from today) - 7
                      then public.register_opened_note((select d from v_opened), false)
                 end,
$b$, 1, 'outstanding_summary open branch');
  execute v_def;
end $mig$;

--  ---------------------------------------------------------------------
--  6. save_register_draft() - the write path stops inviting the back-fill.
--  ---------------------------------------------------------------------
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'save_register_draft';
  if v_def is null then raise exception '117: save_register_draft() does not exist.'; end if;
  if position('register_opened_on' in v_def) > 0 then
    raise notice '117: save_register_draft() already floored.'; return;
  end if;

  v_def := pg_temp.splice(v_def,
$a$  v_n int := 0; v_kept int := 0; v_on_roll int; v_marked int;
begin$a$,
$b$  v_n int := 0; v_kept int := 0; v_on_roll int; v_marked int;
  v_opened date;
begin$b$, 1, 'save_register_draft declare');
  v_def := pg_temp.splice(v_def,
$a$
  for v_m in select * from jsonb_array_elements(p_marks) loop$a$,
$b$
  --  ADDED BY 117. No mark for an evening before the register opened: it
  --  was not permitted then, and a mark written now would assert, in an
  --  append-only log, where a named child was on an evening nobody was
  --  allowed to record it - from memory. Applies to the office as well.
  v_opened := public.register_opened_on(v_masjid);
  if v_opened is null or p_date < v_opened then
    raise exception '%', case when v_opened is null
        then 'The register has not opened yet.'
        else 'The register opened on ' || public.register_opened_said(v_opened)
             || '. It cannot be taken for an evening before that.' end
      using errcode = '22023';
  end if;

  for v_m in select * from jsonb_array_elements(p_marks) loop$b$,
    1, 'save_register_draft loop');
  execute v_def;
end $mig$;

--  ---------------------------------------------------------------------
--  7. record_parent_absence() - db/116's function, same floor.
--  ---------------------------------------------------------------------
do $mig$
declare v_def text;
begin
  select pg_get_functiondef(p.oid) into v_def from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'record_parent_absence'
     and pg_get_function_identity_arguments(p.oid)
         = 'p_pupil uuid, p_date date, p_mark text, p_reason text';
  if v_def is null then raise exception '117: record_parent_absence() does not exist.'; end if;
  if position('register_opened_on' in v_def) > 0 then
    raise notice '117: record_parent_absence() already floored.'; return;
  end if;

  v_def := pg_temp.splice(v_def,
$a$  v_gate jsonb; v_due jsonb;$a$,
$b$  v_gate jsonb; v_due jsonb; v_opened date;$b$, 1, 'record_parent_absence declare');
  v_def := pg_temp.splice(v_def,
$a$    raise exception '%', v_due ->> 'why' using errcode = '22023';
  end if;
$a$,
$b$    raise exception '%', v_due ->> 'why' using errcode = '22023';
  end if;
  --  ADDED BY 117 - see save_register_draft() and this file's header.
  v_opened := public.register_opened_on(v_masjid);
  if v_opened is null or p_date < v_opened then
    raise exception '%', case when v_opened is null
        then 'The register has not opened yet.'
        else 'The register opened on ' || public.register_opened_said(v_opened)
             || '. A parent cannot be recorded as having said anything about an '
             || 'evening before that.' end
      using errcode = '22023';
  end if;
$b$, 1, 'record_parent_absence end of due check');
  execute v_def;
end $mig$;

--  Grants restated exactly as db/086, 097, 104, 108 and 115 established
--  them: authenticated only, nothing for anon or the public.
revoke all on function public.registers_missing(date, date) from public, anon;
revoke all on function public.registers_missing_count(date, date) from public, anon;
revoke all on function public.my_registers_outstanding() from public, anon;
revoke all on function public.madrasah_today() from public, anon;
revoke all on function public.outstanding_summary(uuid) from public, anon;
revoke all on function public.save_register_draft(uuid, date, jsonb) from public, anon;
revoke all on function public.record_parent_absence(uuid, date, text, text) from public, anon;
grant execute on function public.registers_missing(date, date) to authenticated;
grant execute on function public.registers_missing_count(date, date) to authenticated;
grant execute on function public.my_registers_outstanding() to authenticated;
grant execute on function public.madrasah_today() to authenticated;
grant execute on function public.outstanding_summary(uuid) to authenticated;
grant execute on function public.save_register_draft(uuid, date, jsonb) to authenticated;
grant execute on function public.record_parent_absence(uuid, date, text, text) to authenticated;
