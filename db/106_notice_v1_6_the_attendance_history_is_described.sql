--  =====================================================================
--  106 - NOTICE v1.6: THE ATTENDANCE HISTORY IS DESCRIBED
--  28 September 2026
--  =====================================================================
--
--  105 made madrasah_notice_matches_schema() discover its own `watched`
--  tables instead of being told them, and the correct, deliberate result
--  was red: five columns nobody had ever added to the notice, holding real
--  facts about real children -
--
--      madrasah_pupil_classes.added_at        554 rows
--      madrasah_sibling_suggestions.pupil_a    56 rows
--      madrasah_sibling_suggestions.pupil_b    56 rows
--      madrasah_sibling_suggestions.why        56 rows
--      madrasah_sibling_suggestions.state      56 rows
--
--  This migration adds those five to `described`, plus the two new
--  register-history tables AHEAD OF their first row - madrasah_attendance
--  and madrasah_attendance_log are both empty, so neither flags yet, but
--  085 already established the pattern of describing a table before its
--  first use rather than waiting to be caught. tools/build_privacy_page.py
--  is changed in the same commit to say the same words about the same
--  columns; the two cannot move apart without both this file and the page
--  refusing to build.
--
--  madrasah_registers.* IS ADDED TOO, EVEN THOUGH 105 DELIBERATELY LEFT
--  madrasah_registers OUT OF `watched` (it has no pupil_id, so the foreign
--  key rule does not reach it, and widening that rule to "anything that
--  concerns a child" would be a rule nobody could explain). A notice
--  describing more than the guard enforces is honest and costs nothing -
--  and it is required here regardless, because
--  tools/build_privacy_page.py's own build-time check compares the words
--  on the page against this array and refuses to publish if they differ.
--  If that ever reads as dead weight: it is not unchecked, it is checked
--  by a different, cheaper mechanism (text equality against this file)
--  than the runtime one (data in a watched table).
--
--  written_by/written_at on madrasah_attendance_log join `housekeeping`
--  for the same reason marked_by/marked_at already did for
--  madrasah_attendance in 085: who wrote a row and when is plumbing, not
--  something told to a parent about their child.
--
--  madrasah_charges IS NOT TOUCHED HERE. See 105's header: it is empty, it
--  flags nothing today, and describing fees is the fees spec's own work.
--
--  Splice-and-refuse, the same technique 081, 094 and 105 use: read the
--  live definition, replace() the exact old text, and raise an exception
--  rather than proceed if that exact text is not found.
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
    raise exception '106: madrasah_notice_matches_schema() is not there to patch.';
  end if;

  if position('madrasah_pupil_classes.added_at' in v_def) > 0 then
    raise notice '106: already describing the attendance history, leaving it alone.';
    return;
  end if;

  --  ONE. Extend `described`.
  v_new := replace(v_def,
$a$    'madrasah_concerns.raised_by_name', 'madrasah_concerns.outcome_note',
    'madrasah_concerns.raised_at', 'madrasah_concerns.seen_at'
  ];$a$,
$b$    'madrasah_concerns.raised_by_name', 'madrasah_concerns.outcome_note',
    'madrasah_concerns.raised_at', 'madrasah_concerns.seen_at',
    --  New at v1.6.
    'madrasah_pupil_classes.added_at',
    'madrasah_sibling_suggestions.pupil_a', 'madrasah_sibling_suggestions.pupil_b',
    'madrasah_sibling_suggestions.why', 'madrasah_sibling_suggestions.state',
    'madrasah_attendance_log.mark', 'madrasah_attendance_log.reason',
    'madrasah_attendance_log.source', 'madrasah_attendance_log.on_date',
    'madrasah_attendance_log.was_mark', 'madrasah_attendance_log.was_reason',
    'madrasah_attendance_log.was_source',
    --  madrasah_registers is NOT in `watched` (105) - it has no pupil_id -
    --  so these four are described but not enforced by the loop below.
    --  Kept here so the wording on the page and this array stay in the
    --  one-to-one correspondence tools/build_privacy_page.py checks for.
    'madrasah_registers.state', 'madrasah_registers.on_date',
    'madrasah_registers.expected_count', 'madrasah_registers.marked_count'
  ];$b$);

  if v_new = v_def then
    raise exception '106: the `described` anchor did not match. NOT changed.';
  end if;
  v_def := v_new;

  --  TWO. madrasah_attendance_log's own audit columns are plumbing, the
  --  same way madrasah_attendance's marked_by/marked_at already are.
  v_new := replace(v_def,
$c$  housekeeping text[] := array[
    'id', 'masjid_id', 'household_id', 'fee_rate_id', 'pupil_id', 'class_id',
    'created_at', 'updated_at', 'import_key', 'marked_by', 'marked_at',
    'raised_by', 'seen_by'
  ];$c$,
$d$  housekeeping text[] := array[
    'id', 'masjid_id', 'household_id', 'fee_rate_id', 'pupil_id', 'class_id',
    'created_at', 'updated_at', 'import_key', 'marked_by', 'marked_at',
    'raised_by', 'seen_by',
    --  New at v1.6, madrasah_attendance_log: who wrote a log row and when,
    --  not what it says.
    'written_by', 'written_at'
  ];$d$);

  if v_new = v_def then
    raise exception '106: the `housekeeping` anchor did not match. Nothing '
                    'was executed - both patches are applied together or '
                    'not at all.';
  end if;

  execute v_new;
  raise notice '106: madrasah_notice_matches_schema now describes the '
              'attendance history and the sibling-suggestion guess.';
end $mig$;

--  =====================================================================
--  NOT EXECUTED. A record of what `described` now reads, for
--  tools/build_privacy_page.py's OWN cross-check.
--
--  guard_columns() in that script does not query the live database - it
--  reads the `described text[] := array[...]` block out of the LAST
--  db/*.sql file (sorted by name) that contains one, because that is what
--  "the notice, checked against the schema" means as a STATIC claim: the
--  wording on the page and the array in the migration that is meant to
--  match it must be the same text, committed together, not merely the
--  same text as whatever happens to be live right now.
--
--  The do $mig$ block above patches the array with a targeted replace(),
--  the same read-and-refuse technique 105 uses for `watched` - it does
--  not restate the array in full as executable SQL, so on its own this
--  file would leave guard_columns() reading db/092's array forever, three
--  migrations out of date, which is the exact fault 085's header warned
--  about when it made the script stop reading db/081 by name.
--
--  So the resulting array is written out here in full, verified against
--  pg_get_functiondef() on 28 September 2026 after the patch above was
--  applied. It is not a second definition to drift from the first - it is
--  a transcript of it, read after the fact, and it is what
--  tools/build_privacy_page.py will find and check WHAT_WE_HOLD against.
--
--  described text[] := array[
--    'madrasah_pupils.first_name', 'madrasah_pupils.last_name',
--    'madrasah_pupils.date_of_birth', 'madrasah_pupils.gender',
--    'madrasah_pupils.joined_on', 'madrasah_pupils.left_on',
--    'madrasah_pupils.address', 'madrasah_pupils.postcode',
--    'madrasah_pupils.school', 'madrasah_pupils.school_year',
--    'madrasah_pupils.prev_madrasah',
--    'madrasah_pupils.medical', 'madrasah_pupils.allergies',
--    'madrasah_pupils.send_detail', 'madrasah_pupils.ehcp_detail',
--    'madrasah_pupils.walk_home_consent', 'madrasah_pupils.notes',
--    'madrasah_pupils.status', 'madrasah_pupils.legacy_ref',
--    'madrasah_pupils.email',
--    'madrasah_households.name', 'madrasah_households.note',
--    'madrasah_households.reference',
--    'madrasah_guardians.full_name', 'madrasah_guardians.email',
--    'madrasah_guardians.phone', 'madrasah_guardians.is_primary',
--    'madrasah_attendance.mark', 'madrasah_attendance.reason',
--    'madrasah_attendance.on_date', 'madrasah_attendance.source',
--    'madrasah_attendance.class_id',
--    'madrasah_concerns.what_happened', 'madrasah_concerns.when_it_happened',
--    'madrasah_concerns.reference', 'madrasah_concerns.status',
--    'madrasah_concerns.raised_by_name', 'madrasah_concerns.outcome_note',
--    'madrasah_concerns.raised_at', 'madrasah_concerns.seen_at',
--    'madrasah_pupil_classes.added_at',
--    'madrasah_sibling_suggestions.pupil_a', 'madrasah_sibling_suggestions.pupil_b',
--    'madrasah_sibling_suggestions.why', 'madrasah_sibling_suggestions.state',
--    'madrasah_attendance_log.mark', 'madrasah_attendance_log.reason',
--    'madrasah_attendance_log.source', 'madrasah_attendance_log.on_date',
--    'madrasah_attendance_log.was_mark', 'madrasah_attendance_log.was_reason',
--    'madrasah_attendance_log.was_source',
--    'madrasah_registers.state', 'madrasah_registers.on_date',
--    'madrasah_registers.expected_count', 'madrasah_registers.marked_count'
--  ];
