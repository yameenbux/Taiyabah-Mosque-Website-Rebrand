-- =============================================================================
--  Taiyabah Masjid
--  Migration 012: remove ethnicity from madrasah admissions
--
--  WHY
--    The admissions form asked for each child's ethnic group, carried across
--    from the third-party system being replaced. Ethnic origin is special
--    category data under Article 9 of the UK GDPR.
--
--    Writing the DPIA forced the question that had been open for weeks: what
--    does the masjid actually do with it? Nobody could answer. Special
--    category data collected with no stated purpose cannot be defended to a
--    regulator, and "the old form had it" is not a purpose. So the trustees
--    decided on 4 September 2026 to remove the field rather than invent a
--    justification for it after the fact.
--
--    Removing it takes a whole row off the DPIA's risk register rather than
--    mitigating it, which is always the better trade when it is available.
--
--  SAFE TO RUN
--    No admission application has ever been submitted — the form is published
--    as a preview and is structurally unable to send. So this drops a column
--    that has only ever been empty. It checks that before doing anything, and
--    refuses if any row holds a value, because on any other database that
--    would be destroying data.
--
--  IF ETHNICITY IS EVER WANTED AGAIN
--    Update the DPIA first: record the purpose, who reviews it, how often, and
--    what decisions it informs. Then add the column back, then the field.
--    Document first, field second — that is the order this migration exists to
--    establish.
-- =============================================================================

-- NOTE: no `\set ON_ERROR_STOP on` — that is a psql command and the Supabase
-- SQL editor is not psql. Every statement here is idempotent; if it stops part
-- way through, run the whole file again.


-- -----------------------------------------------------------------------------
-- 1. Refuse if there is anything to lose
-- -----------------------------------------------------------------------------
do $$
declare
  n int;
begin
  if to_regclass('public.admission_students') is null then
    raise notice 'admission_students does not exist — nothing to do.';
    return;
  end if;

  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public'
                    and table_name   = 'admission_students'
                    and column_name  = 'ethnicity') then
    raise notice 'ethnicity has already been removed — nothing to do.';
    return;
  end if;

  execute 'select count(*) from public.admission_students where ethnicity is not null'
    into n;

  if n > 0 then
    raise exception
      E'% row(s) hold an ethnicity value. This migration will not destroy real '
      'data.\n\nIf those rows should genuinely lose it, export them first, then '
      'clear the column by hand and run this again.', n;
  end if;

  raise notice 'No ethnicity values stored. Safe to proceed.';
end $$;


-- -----------------------------------------------------------------------------
-- 2. Rewrite the submission function without it
--
--    Order matters: the function references the column, so it has to stop
--    doing that before the column can be dropped.
-- -----------------------------------------------------------------------------
create or replace function public.submit_admission_application(payload jsonb)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_app_id    uuid;
  v_reference text;
  v_student   jsonb;
  v_contact   jsonb;
  v_choice    jsonb;
  v_student_id uuid;
  v_pos       int := 0;
  v_students  jsonb := coalesce(payload -> 'students', '[]'::jsonb);
begin
  if jsonb_array_length(v_students) < 1 then
    raise exception 'An application must include at least one child';
  end if;
  if jsonb_array_length(v_students) > 6 then
    raise exception 'An application may include at most six children';
  end if;

  v_reference := 'TM-' || to_char(now(), 'YY') || '-' ||
                 lpad(nextval('public.admission_reference_seq')::text, 5, '0');

  -- The ids are generated here rather than read back with RETURNING.
  -- INSERT ... RETURNING is evaluated against the SELECT policies, and there
  -- deliberately is no SELECT policy for the function's owner — so RETURNING
  -- fails with a misleading "new row violates row-level security policy".
  -- Generating the uuid up front keeps the read gate completely shut.
  v_app_id := gen_random_uuid();

  insert into public.admission_applications (
    id, reference, academic_year,
    parent_first_name, parent_surname, parent_relationship, parent_relationship_other,
    email, telephone, mobile,
    address_line1, address_line2, address_town, postcode,
    declaration_accepted, privacy_accepted
  ) values (
    v_app_id,
    v_reference,
    payload ->> 'academic_year',
    payload ->> 'parent_first_name',
    payload ->> 'parent_surname',
    payload ->> 'parent_relationship',
    nullif(payload ->> 'parent_relationship_other', ''),
    lower(trim(payload ->> 'email')),
    nullif(payload ->> 'telephone', ''),
    payload ->> 'mobile',
    payload ->> 'address_line1',
    nullif(payload ->> 'address_line2', ''),
    payload ->> 'address_town',
    upper(trim(payload ->> 'postcode')),
    (payload ->> 'declaration_accepted')::boolean,
    (payload ->> 'privacy_accepted')::boolean
  );

  for v_student in select * from jsonb_array_elements(v_students) loop
    v_pos := v_pos + 1;
    v_student_id := gen_random_uuid();
    insert into public.admission_students (
      id, application_id, position, first_name, surname, date_of_birth, gender,
      school_name, school_year, previous_madrasah,
      has_send, send_detail, has_eha_ehcp, eha_ehcp_detail,
      has_allergies, allergy_detail, medical_conditions, general_notes
    ) values (
      v_student_id, v_app_id, v_pos,
      v_student ->> 'first_name',
      v_student ->> 'surname',
      (v_student ->> 'date_of_birth')::date,
      v_student ->> 'gender',
      v_student ->> 'school_name',
      v_student ->> 'school_year',
      nullif(v_student ->> 'previous_madrasah', ''),
      (v_student ->> 'has_send')::boolean,
      nullif(v_student ->> 'send_detail', ''),
      (v_student ->> 'has_eha_ehcp')::boolean,
      nullif(v_student ->> 'eha_ehcp_detail', ''),
      (v_student ->> 'has_allergies')::boolean,
      nullif(v_student ->> 'allergy_detail', ''),
      nullif(v_student ->> 'medical_conditions', ''),
      nullif(v_student ->> 'general_notes', '')
    );

    for v_choice in select * from jsonb_array_elements(coalesce(v_student -> 'choices', '[]'::jsonb)) loop
      insert into public.admission_student_choices (student_id, class_key, preference)
      values (v_student_id, v_choice ->> 'class_key', (v_choice ->> 'preference')::int);
    end loop;
  end loop;

  v_pos := 0;
  for v_contact in select * from jsonb_array_elements(coalesce(payload -> 'contacts', '[]'::jsonb)) loop
    v_pos := v_pos + 1;
    insert into public.admission_contacts (
      application_id, position, full_name, relationship,
      email, telephone, mobile, alt_mobile, is_primary
    ) values (
      v_app_id, v_pos,
      v_contact ->> 'full_name',
      v_contact ->> 'relationship',
      nullif(lower(trim(coalesce(v_contact ->> 'email',''))), ''),
      nullif(v_contact ->> 'telephone', ''),
      nullif(v_contact ->> 'mobile', ''),
      nullif(v_contact ->> 'alt_mobile', ''),
      coalesce((v_contact ->> 'is_primary')::boolean, false)
    );
  end loop;

  insert into public.admin_audit (action, detail)
  values ('admission_application_submitted', jsonb_build_object('reference', v_reference));

  return v_reference;
end;
$$;


-- -----------------------------------------------------------------------------
-- 3. Drop the column
-- -----------------------------------------------------------------------------
alter table public.admission_students drop column if exists ethnicity;


-- -----------------------------------------------------------------------------
-- 4. Confirm. Expect no rows.
-- -----------------------------------------------------------------------------
select column_name
from information_schema.columns
where table_schema = 'public'
  and table_name   = 'admission_students'
  and column_name  = 'ethnicity';
