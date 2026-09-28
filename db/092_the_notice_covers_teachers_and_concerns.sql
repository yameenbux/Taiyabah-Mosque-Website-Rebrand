--  =====================================================================
--  092 - THE NOTICE COVERS TEACHER ACCOUNTS AND SAFEGUARDING CONCERNS
--  27 September 2026
--  =====================================================================
--
--  091 created madrasah_concerns. The published notice listed it under "what
--  we do not hold about your child", inside the line about behaviour and
--  merits - and the guard REFUSED to let the v1.4 page be published until
--  this migration existed. Second time in one day that the two halves have
--  stopped each other moving alone, which is the whole reason they were built
--  that way.
--
--  Behaviour and merit marks stay on the "not held" list, because they
--  genuinely are not held. Only the concern record has moved.
--
--  THE CONCERNS TABLE IS NOW WATCHED, so a column added to it later fails the
--  check until the notice says so. That matters more here than anywhere else
--  in the schema: a safeguarding record is the one thing a parent may be
--  refused sight of, and a notice that is silent about a record it may refuse
--  to show is the worst combination available.
--
--  THE NOTICE ALSO NOW SAYS TEACHERS HAVE ACCOUNTS. v1.2 promised: "No
--  teacher has an account... if it changes, a teacher will only ever see the
--  children in their own classes, and we will issue a new version of this
--  notice before it happens." v1.4 is that new version, and it went up before
--  the first teacher login existed.

create or replace function public.madrasah_notice_matches_schema()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
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
    'madrasah_attendance.mark', 'madrasah_attendance.reason',
    'madrasah_attendance.on_date', 'madrasah_attendance.source',
    'madrasah_attendance.class_id',
    --  New at v1.4.
    'madrasah_concerns.what_happened', 'madrasah_concerns.when_it_happened',
    'madrasah_concerns.reference', 'madrasah_concerns.status',
    'madrasah_concerns.raised_by_name', 'madrasah_concerns.outcome_note',
    'madrasah_concerns.raised_at', 'madrasah_concerns.seen_at'
  ];
  housekeeping text[] := array[
    'id', 'masjid_id', 'household_id', 'fee_rate_id', 'pupil_id', 'class_id',
    'created_at', 'updated_at', 'import_key', 'marked_by', 'marked_at',
    'raised_by', 'seen_by'
  ];
  --  madrasah_concerns HAS LEFT THIS LIST. Behaviour and merits have not:
  --  they genuinely are not held, and the notice still says so.
  absent_tables text[] := array[
    'madrasah_behaviour', 'madrasah_merits',
    'madrasah_exams', 'madrasah_exam_results', 'madrasah_assessments',
    'madrasah_reports', 'madrasah_progress'
  ];
  absent_cols text[] := array[
    'madrasah_pupils.photo', 'madrasah_pupils.photo_url',
    'madrasah_pupils.image', 'madrasah_pupils.nationality',
    'madrasah_pupils.ethnicity', 'madrasah_pupils.language'
  ];
  watched text[] := array[
    'madrasah_pupils', 'madrasah_households', 'madrasah_guardians',
    'madrasah_attendance', 'madrasah_concerns'
  ];
  r record;
  full_name text;
  n bigint;
  undescribed text[] := '{}';
  appeared    text[] := '{}';
  checked int := 0;
begin
  for r in
    select c.table_name, c.column_name
      from information_schema.columns c
     where c.table_schema = 'public' and c.table_name = any(watched)
     order by c.table_name, c.ordinal_position
  loop
    full_name := r.table_name || '.' || r.column_name;
    if full_name = any(described) or r.column_name = any(housekeeping) then
      checked := checked + 1;
      continue;
    end if;
    execute format('select count(*) from public.%I where %I is not null',
                   r.table_name, r.column_name) into n;
    checked := checked + 1;
    if n > 0 then
      undescribed := undescribed
        || (full_name || ' (' || n || ' row(s) with something in it)');
    end if;
  end loop;

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
