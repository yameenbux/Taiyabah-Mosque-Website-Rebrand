--  =====================================================================
--  107 - THE SIBLING DECISION IS HOUSEKEEPING
--  28 September 2026
--  =====================================================================
--
--  madrasah_sibling_suggestions.decided_by and .decided_at are null on all
--  56 rows today, so 105's discovery and 106's description of `why`,
--  `state`, `pupil_a` and `pupil_b` left the guard green. That was a
--  landmine, not a clean state: docs/GO-LIVE.md section D tells the office
--  to go to the Families screen and "Settle these" - and the FIRST time
--  anybody does, settle_sibling_suggestion() sets decided_by and
--  decided_at, and notice_matches_the_schema() goes red for an ordinary
--  act the checklist itself asked the office to perform.
--
--  THIS IS NOT SOMETHING TO DESCRIBE IN THE NOTICE. It is not a new fact
--  about a child - it is who on the staff pressed the button and when,
--  exactly the same shape as raised_by/seen_by (092, safeguarding
--  concerns), marked_by/marked_at (085, attendance) and written_by/
--  written_at (106, the attendance-mark history). All four of those are
--  already in `housekeeping`; decided_by/decided_at join them on the same
--  reasoning, not a new one.
--
--  Splice-and-refuse, the same technique 081, 094, 105 and 106 use: read
--  the live definition, replace() the exact old `housekeeping` block, and
--  raise an exception rather than proceed if that exact text is not found.
--  =====================================================================

do $mig$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'madrasah_notice_matches_schema';

  if v_def is null then
    raise exception '107: madrasah_notice_matches_schema() is not there to patch.';
  end if;

  if position('''decided_by'', ''decided_at''' in v_def) > 0 then
    raise notice '107: already treating the sibling decision as housekeeping, leaving it alone.';
    return;
  end if;

  v_new := replace(v_def,
$a$    --  New at v1.6, madrasah_attendance_log: who wrote a log row and when,
    --  not what it says.
    'written_by', 'written_at'
  ];$a$,
$b$    --  New at v1.6, madrasah_attendance_log: who wrote a log row and when,
    --  not what it says.
    'written_by', 'written_at',
    --  New at 107, madrasah_sibling_suggestions: who confirmed or rejected
    --  a sibling guess, and when - not what the guess says. See this
    --  file's header: both are null today and will not stay that way.
    'decided_by', 'decided_at'
  ];$b$);

  if v_new = v_def then
    raise exception '107: the `housekeeping` anchor did not match. NOT changed.';
  end if;

  execute v_new;
  raise notice '107: madrasah_notice_matches_schema now treats the sibling '
              'decision as housekeeping.';
end $mig$;
