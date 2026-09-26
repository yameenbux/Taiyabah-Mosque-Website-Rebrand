--  077  THE REGISTER: 552 PUPILS
--  Bolton Central Islamic Society · Registered charity 1041569
--  26 September 2026
--
--  HOW THIS FILE DIFFERS FROM THE OTHERS IN THIS FOLDER, AND WHY
--
--  Migrations 001-076 were written here and then applied. This work was
--  applied directly to Supabase in six migrations, because it was built while
--  552 children's data was being prepared and the shape kept changing as the
--  exports were understood. Supabase holds the authoritative bodies under
--  these names:
--
--      20260926135748  a_pupil_record_with_the_pupil_in_it
--      20260926135947  a_landing_area_for_the_register
--      20260926140141  turn_the_landed_register_into_pupils
--      20260926140307  somebody_has_to_be_able_to_open_a_pupil
--      20260926140545  the_roll_says_whether_not_what
--      20260926145624  the_import_refuses_rather_than_doubles
--
--  This file is the record: the schema they created, and the one function
--  worth reviewing on its own. It is NOT re-runnable as a whole and is not
--  meant to be - `supabase migration list` is the source of truth for what
--  has run.
--
--  ==========================================================================
--  WHAT WAS ADDED
--
--  madrasah_pupils gained fifteen columns. It had held a first name, a last
--  name, two dates, a family and a fee rate, so there was nowhere for a date
--  of birth, an address, a school, a medical note or an allergy - which is
--  most of what the register holds.
--
--      legacy_ref  date_of_birth  gender  email  address  postcode
--      school  school_year  prev_madrasah  medical  allergies
--      send_detail  ehcp_detail  walk_home_consent  notes
--
--  with a unique index on (masjid_id, legacy_ref), which is what makes the
--  import repeatable; a check that no text column may hold an empty string,
--  so "has a medical note" is one test and not two; and a check that gender
--  is 'male', 'female' or nothing.
--
--  ETHNICITY IS DELIBERATELY ABSENT. The register has a column for it, empty
--  for all 552 in the sound export and unreadable in the damaged one. It is
--  Article 9 data; a column sitting empty is an invitation to fill it, and
--  "the old system had a field" is not a lawful basis.
--
--  New tables:
--      madrasah_sibling_suggestions   pairs a human has to settle
--      import_pupils / import_guardians / import_classes / import_siblings
--                                     landing tables for the CSV upload,
--                                     dropped once the load is verified
--
--  New functions:
--      madrasah_roll()                 the list: marks, never detail
--      madrasah_pupil_one(uuid)        one record, and writes down who read it
--      save_madrasah_pupil_details()   amending, with what changed in the audit
--      madrasah_roll_health()          the gaps in the register, counted
--      madrasah_sibling_suggestions_list() / settle_sibling_suggestion()
--      clear_unreferenced_pupils()     see below
--      import_the_register()           the load
--      register_import_problem()       the guard, reproduced in full below
--
--  ==========================================================================
--  THE GUARD, AND THE MISTAKE THAT SHAPED IT
--
--  An earlier load on 18 September put 543 pupils in with names and class
--  places and no pupil number. The import keys on that number, so it would
--  have matched none of them and every child would have appeared twice.
--
--  Clearing those rows first is half the answer. The other half is that the
--  import checks its own result and raises - rolling itself back - if the
--  numbers are wrong, because a check that prints a warning afterwards is one
--  somebody can miss, and what it would be missing is 552 children twice.
--
--  THE FIRST VERSION OF THIS GUARD WAS USELESS AND ITS OWN CHECK CAUGHT IT.
--  It compared the file against the madrasah AFTER clearing. That comparison
--  can never fail: the clear empties the table, so whatever the file holds is
--  what the madrasah ends up with. A file truncated to one pupil would have
--  wiped the register and passed. The guard is now asked BEFORE the clear as
--  well as after, against the count as it stood - the only number that knows
--  something is missing.
--
--  The arithmetic lives in a pure function so it can be tested with made-up
--  numbers. Testing it by running the real import would mean deleting 543
--  real rows to find out whether the safety net works.

create or replace function public.register_import_problem(
  p_before int, p_want int, p_got int, p_dupes int,
  p_no_ref int, p_places_want int, p_places_got int)
returns text
language sql
immutable
set search_path to 'pg_temp'
as $$
  select case
    --  The register does not shrink by a tenth overnight. If it appears to,
    --  the upload is short - a file that stopped early, or one table of four.
    when p_before > 0 and p_want < (p_before * 9) / 10 then
      'REFUSING: the madrasah had ' || p_before || ' pupils and this file holds only '
      || p_want || '. That looks like a part-finished upload, not a smaller madrasah.'
    when p_got <> p_want then
      'REFUSING: the file holds ' || p_want || ' pupils and the madrasah now has '
      || p_got || '.'
    when p_dupes > 0 then
      'REFUSING: ' || p_dupes || ' children share a name and a date of birth, '
      || 'which means the same child is in twice.'
    when p_no_ref > 0 then
      'REFUSING: ' || p_no_ref || ' pupils have no reference number, so a later '
      || 'import would not match them and would enter them again.'
    when p_places_got <> p_places_want then
      'REFUSING: the file places pupils in ' || p_places_want
      || ' classes and the madrasah now shows ' || p_places_got || '.'
    else null end;
$$;

--  CHECK. Six ways wrong refused, the right one allowed. Numbers only; no row
--  is touched. These ran when the migration was applied and passed.
do $$
declare msg text;
begin
  --  what the 18 September rows would have produced
  if public.register_import_problem(543, 552, 1095, 0, 543, 555, 1098) is null then
    raise exception 'CHECK FAILED: doubling the register was allowed'; end if;
  if public.register_import_problem(552, 1, 1, 0, 0, 1, 1) is null then
    raise exception 'CHECK FAILED: a one-row file replaced the register'; end if;
  if public.register_import_problem(0, 552, 551, 0, 0, 555, 555) is null then
    raise exception 'CHECK FAILED: a missing pupil passed'; end if;
  if public.register_import_problem(0, 552, 552, 2, 0, 555, 555) is null then
    raise exception 'CHECK FAILED: the same child twice passed'; end if;
  if public.register_import_problem(0, 552, 552, 0, 3, 555, 555) is null then
    raise exception 'CHECK FAILED: pupils with no reference passed'; end if;
  if public.register_import_problem(0, 552, 552, 0, 0, 555, 540) is null then
    raise exception 'CHECK FAILED: missing class places passed'; end if;
  msg := public.register_import_problem(543, 552, 552, 0, 0, 555, 555);
  if msg is not null then
    raise exception 'CHECK FAILED: a correct import was refused (%)', msg; end if;
  raise notice 'CHECK passed: six ways wrong refused, the right one allowed';
end $$;

--  ==========================================================================
--  THE DATA ITSELF NEVER PASSES THROUGH THE ASSISTANT.
--
--  552 children's names, addresses, dates of birth and medical notes go from
--  the file, to the browser, to the database, through the Supabase dashboard's
--  own CSV upload. The landing tables above exist so that the step which does
--  touch the data contains no personal data at all, and so that a bad date or
--  an unknown class is found by a query naming the row rather than by a failed
--  upload naming a byte offset.
--
--  The extraction that produced the four CSVs is NOT in this repository and
--  must never be: this repository is public and GitHub Pages serves its root.
