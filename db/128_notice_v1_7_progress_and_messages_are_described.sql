--  =====================================================================
--  128 - NOTICE v1.7: THE PROGRESS RECORD AND THE MESSAGES ARE DESCRIBED
--  29 September 2026
--  =====================================================================
--
--  db/127 built madrasah_progress and db/125 built madrasah_threads and
--  madrasah_messages, and both were applied to production empty. Until this
--  file a teacher saving the first progress entry would have made the
--  published notice false in two ways at once, and the guard would have said
--  so in two ways:
--
--    1. madrasah_progress is in `absent_tables` - the notice told parents
--       "anything about your child's progress or ability" is NOT held. The
--       first row makes that a lie: "THE NOTICE TELLS PARENTS THIS IS NOT
--       HELD, AND IT IS". (Proved on 29 September against a rolled-back row,
--       before this file: ok = false, exactly that sentence.)
--    2. madrasah_progress carries a foreign key to madrasah_pupils, so 105's
--       discovery puts it in `watched`, and seven of its columns are held and
--       undescribed.
--
--  THE SECOND HALF OF THAT IS NOT THE ONE YOU WOULD THINK OF FIRST. Adding
--  the columns to `described` silences (2) and leaves (1) exactly as loud as
--  before: the guard would stay red forever on a table the notice now says it
--  holds, and whoever met it would learn the only way to make it green is to
--  delete the check. So this file does BOTH, and refuses unless both anchors
--  are found:
--
--      described      +  madrasah_progress.on_date, .sabaq, .sabqi, .manzil,
--                        .note_for_parent, .note_internal, .shared
--      absent_tables  -  madrasah_progress
--
--  written_by / written_at / updated_at / class_id / pupil_id / masjid_id / id
--  are already housekeeping (who wrote it and when is plumbing, not something
--  told to a parent about their child), so nothing is added there.
--
--  MESSAGES ARE DESCRIBED FOR THE SAME REASON MADRASAH_REGISTERS WAS IN 106,
--  AND ARE NOT ENFORCED FOR THE SAME REASON. madrasah_threads hangs off
--  household_id and madrasah_messages off thread_id; neither has a pupil_id, so
--  105's discovery does not reach them and this file deliberately does not
--  widen it (a change to what the guard watches is its own decision, and is
--  named in the report rather than smuggled in here). They are a record about
--  a family, kept, and the notice says so. That is what makes the four columns
--  below true rather than checked:
--
--      madrasah_threads.subject, madrasah_threads.state,
--      madrasah_messages.body,   madrasah_messages.from_parent
--
--  The page and this array must still be the same set - tools/
--  build_privacy_page.py compares them and refuses to write otherwise - so
--  describing them costs nothing and the words on the page cannot drift from
--  them. The plumbing columns (last_message_at, unread_for_office,
--  unread_for_parent, opened_by_parent, author_user, created_at) are not added
--  to housekeeping either, because nothing enforces them: if these two tables
--  are ever brought into `watched`, that is the moment to classify them, with
--  the data in front of whoever does it.
--
--  Splice-and-refuse, the same technique 081, 094, 105 and 106 use: read the
--  live definition, replace() the exact old text, and raise an exception
--  rather than proceed if that exact text is not found. Both patches are
--  applied together or not at all.
--
--  THE -- NOT EXECUTED TRANSCRIPT AT THE FOOT IS REQUIRED, NOT DECORATION.
--  See guard_columns() in tools/build_privacy_page.py: it scrapes the last
--  db/*.sql that carries a literal array block, and a splice-and-refuse file
--  contains none as executable SQL. Without the transcript that function
--  would quietly go on reading db/106's array.
--
--  TO REMOVE: put 'madrasah_progress' back into absent_tables and take the
--  eleven names above out of `described`, by the same technique.
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
    raise exception '128: madrasah_notice_matches_schema() is not there to patch.';
  end if;

  if position('madrasah_progress.note_internal' in v_def) > 0 then
    raise notice '128: already describing the progress record, leaving it alone.';
    return;
  end if;

  --  ONE. Extend `described`.
  v_new := replace(v_def,
$a$    'madrasah_registers.state', 'madrasah_registers.on_date',
    'madrasah_registers.expected_count', 'madrasah_registers.marked_count'
  ];$a$,
$b$    'madrasah_registers.state', 'madrasah_registers.on_date',
    'madrasah_registers.expected_count', 'madrasah_registers.marked_count',
    --  New at v1.7. madrasah_progress IS in `watched` (it has a pupil_id), so
    --  these seven are enforced by the loop below.
    'madrasah_progress.on_date', 'madrasah_progress.sabaq',
    'madrasah_progress.sabqi', 'madrasah_progress.manzil',
    'madrasah_progress.note_for_parent', 'madrasah_progress.note_internal',
    'madrasah_progress.shared',
    --  Also v1.7. Threads and messages are NOT in `watched` (no pupil_id), so
    --  these four are described but not enforced - the madrasah_registers
    --  precedent above. Kept so the page and this array stay one-to-one.
    'madrasah_threads.subject', 'madrasah_threads.state',
    'madrasah_messages.body', 'madrasah_messages.from_parent'
  ];$b$);

  if v_new = v_def then
    raise exception '128: the `described` anchor did not match. NOT changed.';
  end if;
  v_def := v_new;

  --  TWO. madrasah_progress is no longer a thing the notice says is absent.
  v_new := replace(v_def,
$c$    'madrasah_reports', 'madrasah_progress'
  ];$c$,
$d$    'madrasah_reports'
  ];$d$);

  if v_new = v_def then
    raise exception '128: the `absent_tables` anchor did not match. Nothing '
                    'was executed - both patches are applied together or '
                    'not at all.';
  end if;

  execute v_new;
  raise notice '128: madrasah_notice_matches_schema now describes the '
              'progress record and the messages, and no longer denies holding progress.';
end $mig$;

--  =====================================================================
--  NOT EXECUTED. A record of what `described` now reads, for
--  tools/build_privacy_page.py's OWN cross-check. See db/106's foot for why
--  this exists; the reason has not changed.
--
--  Transcribed from pg_get_functiondef() after the patch above was applied
--  on 29 September 2026. A transcript of the live definition, read after the
--  fact - not a second definition to drift from the first.
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
--    'madrasah_registers.expected_count', 'madrasah_registers.marked_count',
--    'madrasah_progress.on_date', 'madrasah_progress.sabaq',
--    'madrasah_progress.sabqi', 'madrasah_progress.manzil',
--    'madrasah_progress.note_for_parent', 'madrasah_progress.note_internal',
--    'madrasah_progress.shared',
--    'madrasah_threads.subject', 'madrasah_threads.state',
--    'madrasah_messages.body', 'madrasah_messages.from_parent'
--  ];
