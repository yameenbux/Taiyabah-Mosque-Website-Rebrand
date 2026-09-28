--  =====================================================================
--  081 - THE PRIVACY NOTICE IS CHECKED AGAINST THE SCHEMA
--  27 September 2026
--  =====================================================================
--
--  THREE TIMES a data protection document here has been made false by a later
--  migration, and every time it was found by a person happening to look.
--
--    v1.0 (19 Sept) said the masjid held no parent's name and no fee history.
--          The fees work, migrations 068-072, made both false the next day.
--    v1.1 (20 Sept) said "we keep your child's name, the class they are in,
--          and the dates they joined and left. Nothing else. We do not hold
--          their date of birth, your address, a telephone number, medical
--          information or a photograph."
--          The register import on 26 September brought in 552 dates of birth,
--          551 addresses, 416 telephone numbers, 38 medical notes, 24
--          allergies and 11 SEND records. The document did not change,
--          because documents do not.
--
--  The pattern is always the same: the notice describes the system as it was
--  on the day it was written, and nothing notices the system moving. A policy,
--  a retention period and a privacy notice are all CLAIMS, and a claim nothing
--  enforces is a sentence in a document.
--
--  So the notice's two lists are written down in the function below, and it
--  fails when the schema stops matching them:
--
--    described    - a column the notice tells parents about. Adding a column
--                   without adding it there fails the check.
--    housekeeping - ids, timestamps, foreign keys. Not personal information
--                   about a child, and not something a notice should list.
--    absent_*     - a table or column the notice says does not exist. If one
--                   ever appears with data in it, the notice has become a lie
--                   in the worst direction: it tells a parent not to worry
--                   about something they should be asking about.
--
--  IT CHECKS FOR DATA, NOT FOR THE COLUMN. A nullable column nobody has ever
--  written to is not something a parent needs to be told about, and failing on
--  one would train whoever runs this to add lines to shut it up. It fails when
--  there is something in it.
--
--  PROVED TO FAIL, BOTH WAYS, BEFORE IT WAS KEPT:
--
--    a column with a value in it that the notice does not mention ->
--      "THE NOTICE DOES NOT MENTION: madrasah_pupils.zz_guard_proof
--       (1 row(s) with something in it). Reissue it before anybody asks."
--    the same column with nothing in it -> passes, deliberately.
--    a table the notice denies, with one row ->
--      "THE NOTICE TELLS PARENTS THIS IS NOT HELD, AND IT IS:
--       madrasah_merits exists with 1 row(s)"
--
--  Both throwaways were dropped and the guard confirmed green again. Neither
--  was a real function or table - see 079, which learned the hard way that a
--  guard must never be tested by breaking the live thing it guards.
--
--  The wording of the notice itself lives in tools/build_privacy_page.py and
--  is published at /madrasah-privacy/. Change one and this fails until you
--  change the other, which is the entire point.
--  =====================================================================

create or replace function public.madrasah_notice_matches_schema()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  --  Every column the published notice describes. The wording lives in
  --  tools/build_privacy_page.py; this is the list of what it covers.
  described text[] := array[
    'madrasah_pupils.first_name', 'madrasah_pupils.last_name',
    'madrasah_pupils.date_of_birth', 'madrasah_pupils.gender',
    'madrasah_pupils.joined_on', 'madrasah_pupils.left_on',
    'madrasah_pupils.address', 'madrasah_pupils.postcode',
    'madrasah_pupils.school', 'madrasah_pupils.school_year',
    'madrasah_pupils.prev_madrasah',
    'madrasah_pupils.medical', 'madrasah_pupils.allergies',
    'madrasah_pupils.send_detail', 'madrasah_pupils.ehcp_detail',
    'madrasah_pupils.walk_home_consent', 'madrasah_pupils.notes',
    'madrasah_pupils.status', 'madrasah_pupils.legacy_ref',
    'madrasah_pupils.email',
    'madrasah_households.name', 'madrasah_households.note',
    'madrasah_households.reference',
    'madrasah_guardians.full_name', 'madrasah_guardians.email',
    'madrasah_guardians.phone', 'madrasah_guardians.is_primary'
  ];
  --  Not personal information about anybody; plumbing.
  housekeeping text[] := array[
    'id', 'masjid_id', 'household_id', 'fee_rate_id',
    'created_at', 'updated_at', 'import_key'
  ];
  --  Tables the notice says do not exist. Naming them here is how the claim
  --  gets tested; the day somebody adds an attendance table, this fails and
  --  the notice gets reissued BEFORE the first mark is made, which is exactly
  --  what the notice promises parents.
  absent_tables text[] := array[
    'madrasah_attendance', 'madrasah_pupil_attendance',
    'madrasah_behaviour', 'madrasah_merits', 'madrasah_concerns',
    'madrasah_exams', 'madrasah_exam_results', 'madrasah_assessments',
    'madrasah_reports', 'madrasah_progress'
  ];
  absent_cols text[] := array[
    'madrasah_pupils.photo', 'madrasah_pupils.photo_url',
    'madrasah_pupils.image', 'madrasah_pupils.nationality',
    'madrasah_pupils.ethnicity', 'madrasah_pupils.language'
  ];
  r record;
  full_name text;
  n bigint;
  undescribed text[] := '{}';
  appeared    text[] := '{}';
  checked int := 0;
begin
  --  ONE. Anything with data in it that the notice does not mention.
  for r in
    select c.table_name, c.column_name
      from information_schema.columns c
     where c.table_schema = 'public'
       and c.table_name in ('madrasah_pupils','madrasah_households',
                            'madrasah_guardians')
     order by c.table_name, c.ordinal_position
  loop
    full_name := r.table_name || '.' || r.column_name;
    if full_name = any(described) or r.column_name = any(housekeeping) then
      checked := checked + 1;
      continue;
    end if;
    execute format(
      'select count(*) from public.%I where %I is not null',
      r.table_name, r.column_name) into n;
    checked := checked + 1;
    if n > 0 then
      undescribed := undescribed
        || (full_name || ' (' || n || ' row(s) with something in it)');
    end if;
  end loop;

  --  TWO. Anything the notice says does not exist.
  foreach full_name in array absent_tables loop
    if exists (select 1 from pg_class c
                where c.relnamespace = 'public'::regnamespace
                  and c.relkind in ('r','p','v','m')
                  and c.relname = full_name) then
      execute format('select count(*) from public.%I', full_name) into n;
      if n > 0 then
        appeared := appeared || (full_name || ' exists with ' || n || ' row(s)');
      end if;
    end if;
  end loop;
  foreach full_name in array absent_cols loop
    if exists (select 1 from information_schema.columns c
                where c.table_schema = 'public'
                  and c.table_name = split_part(full_name, '.', 1)
                  and c.column_name = split_part(full_name, '.', 2)) then
      execute format('select count(*) from public.%I where %I is not null',
                     split_part(full_name, '.', 1),
                     split_part(full_name, '.', 2)) into n;
      if n > 0 then
        appeared := appeared || (full_name || ' has ' || n || ' row(s) in it');
      end if;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', array_length(undescribed, 1) is null
          and array_length(appeared, 1) is null,
    'columns_checked', checked,
    'detail',
      case
        when array_length(appeared, 1) is not null then
          'THE NOTICE TELLS PARENTS THIS IS NOT HELD, AND IT IS: '
          || array_to_string(appeared, '; ')
        when array_length(undescribed, 1) is not null then
          'THE NOTICE DOES NOT MENTION: ' || array_to_string(undescribed, '; ')
          || '. Reissue it before anybody asks.'
        else checked || ' columns; everything held is described in the '
             || 'published notice and nothing it denies holding exists'
      end);
end $$;

revoke all on function public.madrasah_notice_matches_schema() from public, anon;
grant execute on function public.madrasah_notice_matches_schema() to authenticated;

--  =====================================================================
--  SPLICED INTO health_check(), WHICH IS THE ONLY THING THAT MAKES IT REAL
--  =====================================================================
--
--  077 asserted the list/record split in a DO block that ran once at migration
--  time and is long gone, and 079 said so in as many words while adding a
--  check that runs whenever health is read. The same applies here: a guard
--  called by nobody is a guard that does not exist.
--
--  health_check() is eight thousand characters and this migration does not
--  contain a copy of it. Pasting one in would create a second definition that
--  silently reverts whatever else has changed since. Instead the live
--  definition is read, the new block is spliced in after the minimisation
--  check, and the result is executed - and if the anchor is not found, NOTHING
--  is changed and the migration fails loudly.

do $splice$
declare
  src text;
  patched text;
  anchor text := '  if not v_ok then v_failing := array_append(v_failing, ''lists_carry_marks_not_detail''); end if;';
  addition text;
begin
  select pg_get_functiondef(p.oid) into src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'health_check';
  if src is null then
    raise exception 'health_check() does not exist. Nothing changed.';
  end if;

  if position('notice_matches_the_schema' in src) > 0 then
    raise notice 'health_check() already carries the notice check; left alone.';
    return;
  end if;

  addition :=
    E'\n\n  --  THE PUBLISHED PRIVACY NOTICE, CHECKED AGAINST THE SCHEMA.\n'
    '  --  Added by 081. Three versions of that notice have been made false by\n'
    '  --  a later migration and every one was found by a person happening to\n'
    '  --  look. This runs whenever health is read.\n'
    '  begin\n'
    '    v_jrow := public.madrasah_notice_matches_schema();\n'
    '    v_ok := (v_jrow ->> ''ok'')::boolean;\n'
    '    v_detail := v_jrow ->> ''detail'';\n'
    '  exception when others then\n'
    '    v_ok := false;\n'
    '    v_detail := ''the notice check itself failed: '' || sqlerrm;\n'
    '  end;\n'
    '  v_checks := v_checks || jsonb_build_object(''check'',''notice_matches_the_schema'',\n'
    '                                             ''ok'',v_ok,''detail'',v_detail);\n'
    '  if not v_ok then v_failing := array_append(v_failing, ''notice_matches_the_schema''); end if;';

  patched := replace(src, anchor, anchor || addition);
  if patched = src then
    raise exception 'The anchor in health_check() has moved. NOTHING was '
                    'changed, so that health_check is not rewritten wrongly.';
  end if;
  execute patched;
end $splice$;
