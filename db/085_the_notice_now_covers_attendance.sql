--  =====================================================================
--  085 - THE NOTICE NOW COVERS ATTENDANCE
--  27 September 2026
--  =====================================================================
--
--  084 created madrasah_attendance. The published privacy notice, at v1.2,
--  listed attendance under "what we do not hold about your child" and promised:
--
--    "We are building an attendance register. When it starts being used we
--     will issue a new version of this notice and tell you before the first
--     mark is made, not afterwards."
--
--  THE GUARD WORKED, AND IT WORKED THE RIGHT WAY ROUND. 081's check fails on
--  DATA, not on the existence of a column or a table, so creating an empty
--  attendance table failed nothing - correctly, because an empty table holds
--  nothing about anybody and there is nothing to tell a parent yet. The first
--  mark would have failed it.
--
--  It also caught the update from the other side: tools/build_privacy_page.py
--  REFUSED to publish the v1.3 wording until this migration existed, because
--  the page and the guard no longer covered the same columns. Neither half
--  could move without the other, which is the entire point of building it
--  that way.
--
--  AND ONE MORE THING BROKE, USEFULLY. build_privacy_page.py read the
--  `described` list out of db/081 BY NAME. The moment this migration redefined
--  the guard, the page would have gone on being checked against a list three
--  migrations out of date - the same fault the whole mechanism exists to
--  prevent, one level further up, and completely invisible. It now reads the
--  LAST migration that defines the guard, because that is what Postgres does
--  with `create or replace`.
--
--  So: attendance leaves the "not held" list and joins the described one, and
--  the guard starts watching madrasah_attendance's own columns.

create or replace function public.madrasah_notice_matches_schema()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  --  Every column the published notice describes. The wording lives in
  --  tools/build_privacy_page.py, which refuses to publish unless it covers
  --  exactly this list.
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
    'madrasah_guardians.phone', 'madrasah_guardians.is_primary',
    --  New at v1.3.
    'madrasah_attendance.mark', 'madrasah_attendance.reason',
    'madrasah_attendance.on_date', 'madrasah_attendance.source',
    'madrasah_attendance.class_id'
  ];
  --  Not personal information about anybody; plumbing.
  housekeeping text[] := array[
    'id', 'masjid_id', 'household_id', 'fee_rate_id', 'pupil_id',
    'created_at', 'updated_at', 'import_key', 'marked_by', 'marked_at'
  ];
  --  Tables the notice says do not exist.
  --  madrasah_attendance HAS LEFT THIS LIST, because it now exists and is
  --  described. Nothing else has moved.
  absent_tables text[] := array[
    'madrasah_behaviour', 'madrasah_merits', 'madrasah_concerns',
    'madrasah_exams', 'madrasah_exam_results', 'madrasah_assessments',
    'madrasah_reports', 'madrasah_progress'
  ];
  absent_cols text[] := array[
    'madrasah_pupils.photo', 'madrasah_pupils.photo_url',
    'madrasah_pupils.image', 'madrasah_pupils.nationality',
    'madrasah_pupils.ethnicity', 'madrasah_pupils.language'
  ];
  --  The tables whose every column must be accounted for.
  watched text[] := array[
    'madrasah_pupils', 'madrasah_households', 'madrasah_guardians',
    'madrasah_attendance'
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
       and c.table_name = any(watched)
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
        else checked || ' columns across ' || array_length(watched, 1)
             || ' tables; everything held is described in the published '
             || 'notice and nothing it denies holding exists'
      end);
end $$;

revoke all on function public.madrasah_notice_matches_schema() from public, anon;
grant execute on function public.madrasah_notice_matches_schema() to authenticated;
