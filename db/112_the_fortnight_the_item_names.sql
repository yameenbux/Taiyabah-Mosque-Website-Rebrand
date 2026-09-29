-- ===========================================================================
--  112 - THE FORTNIGHT THE ITEM NAMES, AND NO NAMES BUILT TO GET THERE
--  28 September 2026
-- ===========================================================================
--  Review of db/111 (Task 10). Two faults, both found in review, neither
--  touches db/111 itself - that file is applied, and db/104's own reminder
--  applies here too: correct it forward, do not edit it.
--
--  FAULT 1 - THE NUMBER CONTRADICTED ITS OWN SENTENCE, THE EXACT THING
--  RULING C EXISTED TO PREVENT.
--
--  db/111 called registers_missing() with NO ARGUMENTS, which takes THAT
--  FUNCTION'S OWN default window - p_from default (current_date - 14),
--  p_to default current_date (db/095/104) - a 15-day span that INCLUDES
--  TONIGHT. The item's own wording says "In the last fortnight". Proved
--  live, read-only, as the office (no INSERT/UPDATE/DELETE anywhere):
--
--      last 7 days,  excluding today   220   (db/108's digest window)
--      last 14 days, excluding today   440   ("in the last fortnight")
--      registers_missing() bare call   484   (what db/111 actually showed)
--
--  484 is forty-four more than 440 - exactly one extra due evening's worth
--  of classes, because the bare call also counted TONIGHT. Tonight's own
--  unmarked registers are ALREADY this function's 'registers' item (when
--  permitted) or already implied by 'attendance_gate' (when not) - a
--  fortnight that has not finished yet is not a fortnight, and counting it
--  twice under two different names on the same screen is its own version
--  of the fault ruling A already fixed once. The window below is explicit
--  - current_date - 14 to current_date - 1 - the same "N days before
--  today, today excluded" shape db/108's digest already uses for its own
--  7-day window (db/108: `(select d from today) - 7` to `... - 1`), so the
--  number on screen is now the number the sentence promises, checked
--  against the SAME live figures above: with this migration applied,
--  madrasah_today()'s registers_missed.count reads 440, not 484 or 220 -
--  see the report for the live query.
--
--  FAULT 2 - CLAUDE.md, ADDED 28 SEPTEMBER: "NEVER CALL A FUNCTION WHOSE
--  JOB IS TO RETURN PEOPLE IN ORDER TO CHECK A NUMBER."
--  registers_missing() exists to put a class, a date AND A TEACHER'S NAME
--  in front of the office (db/104) - it is one of the three functions
--  CLAUDE.md names outright. db/111 wrapped it correctly in the sense that
--  only ->>'count' was ever READ, but every call still made the function
--  BUILD the named rows internally (jsonb_agg of teacher, class, date)
--  before this migration's predecessor threw them away - on
--  madrasah_today(), the screen every office user loads first. Nothing
--  leaked to a transcript (this is not a disclosure), but the rule is
--  about which tool gets reached for, not only about what a transcript
--  shows, and a function that assembles people to produce an integer is
--  the wrong tool regardless of who is watching.
--
--  So this migration STOPS CALLING registers_missing() (and register_due())
--  ALTOGETHER and re-derives the count directly - the same technique
--  db/108 already uses for send_weekly_digest() under pg_cron, and the
--  same two independent halves db/104's own header names: the DATE half
--  (register_days is set, the date sits in the current academic year, the
--  day of week is a register day, no closure covers it - none of which
--  mention a class) computed ONCE for the window, and the CLASS half
--  (active, someone on roll - which mentions no date) computed ONCE,
--  crossed and filtered by "not submitted", exactly what
--  register_due()/registers_missing() already compute. v_masjid is used
--  DIRECTLY here, not db/108's "(select m from me)" indirection - that
--  indirection exists only because send_weekly_digest() runs under
--  pg_cron with auth.uid() null; madrasah_today() runs for a real
--  signed-in office user, so public.current_masjid() (already assigned to
--  v_masjid at the top of this function) resolves correctly on its own.
--  NOWHERE in the block below is a pupil, guardian or staff name read,
--  selected, or built into a row - only ids and dates, crossed and
--  counted.
--
--  Proved equal to the function it replaces, over the live data: the
--  hoisted query below, run stand-alone before this migration touched
--  anything, answered 440 - the same figure
--  registers_missing(current_date-14, current_date-1) answers when asked
--  the identical question with its own (unwanted, per Fault 2) machinery.
-- ===========================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'madrasah_today';

  if position('v_due_dates' in v_def) > 0 then
    raise notice '112: already there.';
    return;
  end if;

  --  Anchor: the single line db/111 added, refused if it has moved -
  --  db/111 is applied and not re-run, so this either finds exactly what
  --  it put there or refuses rather than guessing.
  v_new := replace(v_def,
$a$    n := coalesce((public.registers_missing() ->> 'count')::int, 0);$a$,
$b$    --  CORRECTED BY 112 - see this file's header. Neither
    --  registers_missing() nor register_due() is called: both exist to
    --  work with people (a teacher's name, a class list) and this needs
    --  only a count. The window is explicit and excludes tonight - "in
    --  the last fortnight" means the fourteen days before today, the same
    --  shape db/108's digest already uses for its own window, not
    --  registers_missing()'s own default (which would include tonight and
    --  read 484, not 440 - see this file's header for the live proof).
    select count(*) into n
      from (
        with v_reg_days as (
               select coalesce(
                        (select array(select jsonb_array_elements_text(value))
                           from public.madrasah_settings
                          where masjid_id = v_masjid and key = 'register_days'),
                        '{}'::text[]) as d),
             v_reg_year as (
               select y.starts_on, y.ends_on from public.madrasah_years y
                where y.masjid_id = v_masjid and y.is_current),
             v_due_dates as (
               select g::date as on_date
                 from generate_series(current_date - 14, current_date - 1,
                                       interval '1 day') g
                 cross join v_reg_days rd
                where lower(to_char(g, 'Dy')) = any (rd.d)
                  and exists (select 1 from v_reg_year y
                               where g::date between y.starts_on and y.ends_on)
                  and not exists (select 1 from public.madrasah_closures c
                                    where c.masjid_id = v_masjid
                                      and g::date between c.starts_on and c.ends_on)),
             v_due_classes as (
               select c.id from public.madrasah_classes c
                where c.masjid_id = v_masjid and c.is_active
                  and exists (select 1 from public.madrasah_pupil_classes pc
                                join public.madrasah_pupils p on p.id = pc.pupil_id
                               where pc.class_id = c.id and p.left_on is null
                                 and p.status = 'on_roll'))
        select cls.id, dd.on_date
          from v_due_classes cls cross join v_due_dates dd
         where not exists (select 1 from public.madrasah_registers rg
                            where rg.class_id = cls.id and rg.on_date = dd.on_date
                              and rg.state = 'submitted')
      ) x;$b$);

  if v_new = v_def then
    raise exception '112: could not find db/111''s registers_missing() line. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  Grants restated exactly as db/086 and db/111 established them.
revoke all on function public.madrasah_today() from public, anon;
grant execute on function public.madrasah_today() to authenticated;
