-- ===========================================================================
--  003_admissions.sql — madrasah admission applications
--
--  *** THIS MIGRATION HAS NOT BEEN APPLIED, AND MUST NOT BE APPLIED YET. ***
--
--  Running it creates the only place a child's medical, SEND, EHCP and
--  ethnicity data could land. Until that data has somewhere lawful to go,
--  it should have nowhere at all to go — so the tables do not exist. That is
--  a deliberate safety property, not an oversight.
--
--  Before anyone runs this, all of the following must be done:
--    1. DPIA completed and signed off.
--    2. ICO registration in place (Tier 1, ~£52/yr).
--    3. Lawful basis under Art. 6 documented, plus an Art. 9 condition for the
--       health, SEND and ethnicity fields.
--    4. Appropriate Policy Document written (required for the Art. 9 condition
--       most likely to apply here).
--    5. Breach procedure written, with a 72-hour route to the ICO.
--    6. A retention period agreed for unsuccessful applications, and set in
--       the purge function at the bottom of this file.
--    7. A SECOND administrator exists. See the cascade note in
--       claude/madrasah-portal-decisions.md — deleting the only admin
--       destroys its roles and profile with no recovery.
--
--  Prerequisites: 001_foundation.sql and 002_grants.sql already applied.
--  Depends on public.is_admin(), created in 001.
--
--  Validate against a local Postgres 16 first. Never run _test_ files against
--  Supabase.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

create sequence if not exists public.admission_reference_seq;

create table public.admission_applications (
  id                     uuid primary key default gen_random_uuid(),
  reference              text        not null unique,
  academic_year          text        not null,          -- e.g. '2027/2028'
  submitted_at           timestamptz not null default now(),

  -- Parent / guardian making the application
  parent_first_name      text        not null check (length(trim(parent_first_name)) > 0),
  parent_surname         text        not null check (length(trim(parent_surname))  > 0),
  parent_relationship    text        not null,
  parent_relationship_other text,                        -- only when relationship = 'other'
  email                  text        not null check (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  telephone              text,
  mobile                 text        not null,
  address_line1          text        not null,
  address_line2          text,
  address_town           text        not null,
  postcode               text        not null,

  -- What the applicant agreed to, and when
  declaration_accepted   boolean     not null check (declaration_accepted),
  privacy_accepted       boolean     not null check (privacy_accepted),

  -- Office workflow
  status                 text        not null default 'new'
                           check (status in ('new','reviewing','offered','waitlisted','declined','withdrawn')),
  office_notes           text,
  reviewed_by            uuid references auth.users(id) on delete set null,
  reviewed_at            timestamptz,

  constraint relationship_other_required
    check (parent_relationship <> 'other' or length(coalesce(parent_relationship_other,'')) > 0)
);

comment on table public.admission_applications is
  'One submitted madrasah application. Contains personal data about adults and, via admission_students, special category data about children.';

create table public.admission_students (
  id                  uuid primary key default gen_random_uuid(),
  application_id      uuid    not null references public.admission_applications(id) on delete cascade,
  position            int     not null default 1,

  first_name          text    not null check (length(trim(first_name)) > 0),
  surname             text    not null check (length(trim(surname))    > 0),
  date_of_birth       date    not null check (date_of_birth > date '1990-01-01' and date_of_birth < current_date),
  gender              text    not null check (gender in ('male','female')),

  school_name         text    not null,
  school_year         text    not null,
  previous_madrasah   text,                              -- null means none

  -- Article 9 fields. Every one of these is optional to answer except the
  -- yes/no flags, and ethnicity is nullable so "prefer not to say" is storable
  -- as an absence rather than as a made-up value.
  has_send            boolean not null,
  send_detail         text,
  has_eha_ehcp        boolean not null,
  eha_ehcp_detail     text,
  has_allergies       boolean not null,
  allergy_detail      text,
  medical_conditions  text,
  ethnicity           text,
  general_notes       text    check (length(coalesce(general_notes,'')) <= 500),

  constraint allergy_detail_required
    check (not has_allergies or length(coalesce(allergy_detail,'')) > 0),
  unique (application_id, position)
);

comment on column public.admission_students.ethnicity is
  'Nullable by design: null means the applicant chose not to say. Do not add a NOT NULL constraint without a documented purpose for collecting it.';

create table public.admission_student_choices (
  id          uuid primary key default gen_random_uuid(),
  student_id  uuid not null references public.admission_students(id) on delete cascade,
  class_key   text not null,
  preference  int  not null check (preference between 1 and 11),
  unique (student_id, class_key),
  constraint one_class_per_preference unique (student_id, preference) deferrable initially deferred
);

create table public.admission_contacts (
  id             uuid    primary key default gen_random_uuid(),
  application_id uuid    not null references public.admission_applications(id) on delete cascade,
  position       int     not null default 1,
  full_name      text    not null check (length(trim(full_name)) > 0),
  relationship   text    not null,
  email          text,
  telephone      text,
  mobile         text,
  alt_mobile     text,
  is_primary     boolean not null default false,
  unique (application_id, position)
);

create index admission_students_application_idx on public.admission_students(application_id);
create index admission_choices_student_idx      on public.admission_student_choices(student_id);
create index admission_contacts_application_idx on public.admission_contacts(application_id);
create index admission_applications_status_idx  on public.admission_applications(status, submitted_at desc);

-- ---------------------------------------------------------------------------
-- Privileges
--
-- GRANT and RLS are two separate gates and both are required — 001 shipped
-- without the grants and every query failed before a policy ever ran. Here the
-- point is the opposite: anon gets NO table privileges at all, so the public
-- form cannot read, update or delete anything even if a policy were wrong.
-- Submission goes through one SECURITY DEFINER function instead.
-- ---------------------------------------------------------------------------

revoke all on public.admission_applications,
              public.admission_students,
              public.admission_student_choices,
              public.admission_contacts
  from anon, authenticated;

grant select, update (status, office_notes, reviewed_by, reviewed_at)
  on public.admission_applications to authenticated;
grant select on public.admission_students,
                public.admission_student_choices,
                public.admission_contacts to authenticated;

-- ---------------------------------------------------------------------------
-- Row level security — only an administrator may read an application back
-- ---------------------------------------------------------------------------

alter table public.admission_applications    enable row level security;
alter table public.admission_students        enable row level security;
alter table public.admission_student_choices enable row level security;
alter table public.admission_contacts        enable row level security;

alter table public.admission_applications    force row level security;
alter table public.admission_students        force row level security;
alter table public.admission_student_choices force row level security;
alter table public.admission_contacts        force row level security;

create policy admin_read_applications on public.admission_applications
  for select to authenticated using (public.is_admin());
create policy admin_update_applications on public.admission_applications
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

create policy admin_read_students on public.admission_students
  for select to authenticated using (public.is_admin());
create policy admin_read_choices on public.admission_student_choices
  for select to authenticated using (public.is_admin());
create policy admin_read_contacts on public.admission_contacts
  for select to authenticated using (public.is_admin());

-- FORCE ROW LEVEL SECURITY applies to the table owner too, so the SECURITY
-- DEFINER function below cannot rely on being the owner to get its inserts in.
-- Locally that appears to work, because a superuser bypasses RLS outright —
-- which is exactly how a migration passes its tests and then fails in
-- production. So the insert path is opened explicitly at the policy level, and
-- kept shut at the privilege level: anon and authenticated hold no INSERT
-- grant on any of these tables, so an open policy grants them nothing. Only
-- the function's owner can act on it.

create policy definer_insert_applications on public.admission_applications
  for insert with check (true);
create policy definer_insert_students on public.admission_students
  for insert with check (true);
create policy definer_insert_choices on public.admission_student_choices
  for insert with check (true);
create policy definer_insert_contacts on public.admission_contacts
  for insert with check (true);

-- Deletion happens only through the retention purge at the bottom of this
-- file, which checks is_admin() itself before touching anything.
create policy definer_delete_applications on public.admission_applications
  for delete using (true);

-- Deliberately absent: any policy granting anon anything at all.

-- ---------------------------------------------------------------------------
-- Submission — the only way data gets in
--
-- Returns the reference number and nothing else. The caller never receives a
-- row id and can never read the record back.
-- ---------------------------------------------------------------------------

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
      has_allergies, allergy_detail, medical_conditions, ethnicity, general_notes
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
      nullif(v_student ->> 'ethnicity', ''),      -- '' or absent = prefer not to say
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

revoke all on function public.submit_admission_application(jsonb) from public;
grant execute on function public.submit_admission_application(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Retention
--
-- Personal data may not be kept longer than necessary. Set the retention
-- period once the office has agreed one, then schedule this — do not leave it
-- as a manual job somebody remembers.
-- ---------------------------------------------------------------------------

create or replace function public.purge_old_admission_applications(retain_months int)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_deleted int;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator may purge applications';
  end if;
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be a positive number of months';
  end if;

  with gone as (
    delete from public.admission_applications
     where status in ('declined','withdrawn')
       and submitted_at < now() - make_interval(months => retain_months)
    returning 1
  )
  select count(*) into v_deleted from gone;

  insert into public.admin_audit (action, detail)
  values ('admission_applications_purged',
          jsonb_build_object('deleted', v_deleted, 'retain_months', retain_months));

  return v_deleted;
end;
$$;

revoke all on function public.purge_old_admission_applications(int) from public;
grant execute on function public.purge_old_admission_applications(int) to authenticated;

commit;
