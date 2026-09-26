-- ===========================================================================
--  076_somebody_has_to_be_able_to_read_an_application.sql
--  25 September 2026
--
--  THE FORM HAS BEEN LIVE AND NOBODY AT THE MASJID COULD OPEN WHAT IT WROTE.
--
--  008 built the whole admissions pipeline and stopped one function short. It
--  has exactly two:
--
--      submit_admission_application(jsonb)   granted to anon
--      purge_old_admission_applications(int) scheduled, and running
--
--  A parent can apply. The office is emailed that an application arrived. The
--  row is purged on schedule three years later. Between those two events there
--  is no way for any human being to read it: no list, no record, no decision,
--  nothing. `admission_applications` is FORCE RLS with no policy and no grant,
--  which is the right shape and which means the table is completely sealed.
--
--  It has never shown up because no application has ever been submitted. The
--  moment one is, the masjid has a child's medical details in a table it
--  cannot open, an email telling it to "open the portal", and a portal with
--  the row greyed out and marked SOON.
--
--  This file is the missing half.
--
--  ---------------------------------------------------------------------------
--  WHAT IS IN AN APPLICATION, AND WHY THAT DECIDES THE SHAPE OF THIS FILE
--  ---------------------------------------------------------------------------
--
--  Per child: name, date of birth, gender, school, school year, previous
--  madrasah, whether they have SEND and the detail of it, whether they have an
--  EHA/EHCP and the detail of it, allergies and the detail of them, free-text
--  medical conditions, and free-text notes.
--
--  That is Article 9 special category data about a child who cannot consent to
--  any of it. It is the most sensitive thing this system holds - more so than
--  the madrasah roll, which is a name and two dates. The DPIA's rule for it is
--  already written and is quoted in notify's own source: none of it goes to a
--  mail provider or into a shared inbox; the office opens the portal.
--
--  So the split in this file is not stylistic:
--
--    madrasah_admission_list()  says WHETHER a child has a medical note.
--    madrasah_admission_one()   says WHAT IT IS, and writes down who asked.
--
--  065 established that for staff records, where the argument was that a list
--  is read far more often than a record is opened. Here it is stronger. This
--  list will sit open on an office screen while somebody works down it, and it
--  will be read by an administrator triaging forty applications who has no
--  business knowing which child is epileptic until they open that child.
--
--  ---------------------------------------------------------------------------
--  READING ONE IS AUDITED. WRITING IS NOT ENOUGH.
--  ---------------------------------------------------------------------------
--
--  Every other audited action in this system is a WRITE - a booking approved,
--  a fee waived, a pupil archived. madrasah_admission_one() audits a READ,
--  which is unusual here and deliberate.
--
--  "Who has looked at this child's medical record" is a question the masjid
--  may one day have to answer, to a parent or to the Information
--  Commissioner, and the only honest answers are "here is the list" or "we
--  have no idea". A subject access request about a child asks exactly this.
--
--  It logs the reference and the id. NOT the child's name, not the condition:
--  an audit row outlives the application it describes - the purge takes the
--  application at three years and admin_audit is kept for six - so copying the
--  detail into it would quietly defeat the retention period. Same reasoning
--  070 used for the fee reminder log.
--
--  ---------------------------------------------------------------------------
--  ANON IS SHUT OUT AT THE START, NOT AFTER AN ADVISOR NOTICES
--  ---------------------------------------------------------------------------
--
--  073 exists because 068-071 wrote `grant execute ... to authenticated` and
--  forgot that Postgres has already granted EXECUTE to PUBLIC, which anon
--  inherits. Twenty-six functions sat open for five days. Every function here
--  is revoked from public and anon on the line before it is granted, and
--  CHECK 4 fails if any of them is ever reachable by a signed-out stranger.
--
--  Prerequisites: 008 (the tables), 011 (verified_admin). Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. The landing counts
--
--  'new' IS THE NOTIFICATION, and nothing else is.
--
--  An application is 'new' until a person gives it a status. Opening one does
--  NOT change it: reading is not triaging, and a count that goes down because
--  somebody glanced at a row is a count that stops meaning anything. The
--  screen shows the number, the office presses a button, the number falls.
--
--  oldest_new_days is the figure that makes a shared office screen honest.
--  "3 waiting" is easy to assume somebody else has dealt with; "the oldest has
--  been waiting 11 days" is not. The weekly digest learned this in 051 and it
--  is the same problem: a queue nobody owns.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_admissions_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see admissions.'
      using errcode = '42501';
  end if;

  return jsonb_build_object(
    'as_at', now(),

    'new',        (select count(*) from public.admission_applications
                    where masjid_id = v_masjid and status = 'new'),
    'reviewing',  (select count(*) from public.admission_applications
                    where masjid_id = v_masjid and status = 'reviewing'),
    'offered',    (select count(*) from public.admission_applications
                    where masjid_id = v_masjid and status = 'offered'),
    'waitlisted', (select count(*) from public.admission_applications
                    where masjid_id = v_masjid and status = 'waitlisted'),
    'declined',   (select count(*) from public.admission_applications
                    where masjid_id = v_masjid and status = 'declined'),
    'withdrawn',  (select count(*) from public.admission_applications
                    where masjid_id = v_masjid and status = 'withdrawn'),
    'total',      (select count(*) from public.admission_applications
                    where masjid_id = v_masjid),

    --  Whole days, floored, so "0 days" means today rather than "a bit less
    --  than one". An office reading "waiting 0 days" and an office reading
    --  "came in today" should not be able to disagree.
    'oldest_new_days', (select floor(extract(epoch from now() - min(submitted_at)) / 86400)::int
                          from public.admission_applications
                         where masjid_id = v_masjid and status = 'new'),

    'children_waiting', (select count(*)
                           from public.admission_students s
                           join public.admission_applications a on a.id = s.application_id
                          where a.masjid_id = v_masjid and a.status in ('new', 'reviewing')),

    --  The years that actually have applications, newest first, so the filter
    --  offers what exists rather than a range somebody has to guess at.
    'years', coalesce((select jsonb_agg(y order by y desc)
                         from (select distinct academic_year as y
                                 from public.admission_applications
                                where masjid_id = v_masjid) s), '[]'::jsonb),

    --  The last five to arrive, for the strip that says the form is working.
    --  Reference and when. No name, because this is the part of the screen
    --  that is visible from across a room.
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', a.id, 'reference', a.reference,
               'submitted_at', a.submitted_at, 'status', a.status,
               'children', (select count(*) from public.admission_students s
                             where s.application_id = a.id))
             order by a.submitted_at desc)
        from (select * from public.admission_applications
               where masjid_id = v_masjid
               order by submitted_at desc limit 5) a), '[]'::jsonb)
  );
end $fn$;

-- ---------------------------------------------------------------------------
--  2. The list
--
--  FLAGS, NOT DETAIL. has_send / has_ehcp / has_allergies / has_medical are
--  booleans computed here. The text behind them is in madrasah_admission_one()
--  and nowhere else.
--
--  The child's NAME is here, because an office working down a list has to be
--  able to find the family that just rang up, and a list of reference numbers
--  is not a list anybody can work. That is the line: who applied is
--  operational, what is wrong with them is not.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_admission_list(
  p_status text    default null,
  p_q      text    default null,
  p_year   text    default null,
  p_limit  integer default 200)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_q      text := nullif(btrim(coalesce(p_q, '')), '');
  v_like   text;
  v_n      integer := least(greatest(coalesce(p_limit, 200), 1), 500);
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see admissions.'
      using errcode = '42501';
  end if;

  --  ILIKE with the wildcards escaped, not a regex. 068's reasoning: a search
  --  box is typed into by the office, and a surname containing an underscore
  --  or a percent sign should find that family rather than everybody.
  v_like := case when v_q is null then null
                 else '%' || replace(replace(replace(v_q, '\', '\\'),
                                             '%', '\%'), '_', '\_') || '%' end;

  return coalesce((
    select jsonb_agg(x order by
             --  New first, always, whatever else is being filtered. The
             --  office's question is "what has come in", not "what is
             --  alphabetically first".
             case x->>'status' when 'new' then 0 when 'reviewing' then 1 else 2 end,
             x->>'submitted_at' desc)
      from (
        select jsonb_build_object(
                 'id',            a.id,
                 'reference',     a.reference,
                 'academic_year', a.academic_year,
                 'submitted_at',  a.submitted_at,
                 'status',        a.status,
                 'parent',        btrim(a.parent_first_name || ' ' || a.parent_surname),
                 'relationship',  coalesce(nullif(a.parent_relationship_other, ''),
                                           a.parent_relationship),
                 'mobile',        a.mobile,
                 'email',         a.email,
                 'town',          a.address_town,
                 'reviewed_at',   a.reviewed_at,
                 'reviewed_by',   (select pr.full_name from public.profiles pr
                                    where pr.id = a.reviewed_by),
                 'has_note',      (a.office_notes is not null
                                   and btrim(a.office_notes) <> ''),
                 'children',      (select count(*) from public.admission_students s
                                    where s.application_id = a.id),
                 --  The names, so the list is workable. Nothing else about them.
                 'child_names',   coalesce((
                    select string_agg(btrim(s.first_name || ' ' || s.surname), ', '
                                      order by s.position)
                      from public.admission_students s
                     where s.application_id = a.id), ''),
                 --  WHETHER, NEVER WHAT.
                 'has_send',      exists (select 1 from public.admission_students s
                                           where s.application_id = a.id and s.has_send),
                 'has_ehcp',      exists (select 1 from public.admission_students s
                                           where s.application_id = a.id and s.has_eha_ehcp),
                 'has_allergies', exists (select 1 from public.admission_students s
                                           where s.application_id = a.id and s.has_allergies),
                 'has_medical',   exists (select 1 from public.admission_students s
                                           where s.application_id = a.id
                                             and s.medical_conditions is not null
                                             and btrim(s.medical_conditions) <> '')
               ) as x
          from (select * from public.admission_applications
                 where masjid_id = v_masjid
                   and (p_status is null or status = p_status)
                   and (p_year is null or academic_year = p_year)
                 order by submitted_at desc
                 limit v_n) a
         where v_like is null
            or a.reference ilike v_like escape '\'
            or a.email ilike v_like escape '\'
            or a.mobile ilike v_like escape '\'
            or btrim(a.parent_first_name || ' ' || a.parent_surname) ilike v_like escape '\'
            or exists (select 1 from public.admission_students s
                        where s.application_id = a.id
                          and btrim(s.first_name || ' ' || s.surname) ilike v_like escape '\')
      ) s), '[]'::jsonb);
end $fn$;

-- ---------------------------------------------------------------------------
--  3. One application, in full
--
--  This is the only door to a child's medical detail, and it writes down that
--  it was opened. See the header.
--
--  NOT `stable`. It inserts an audit row, so it is volatile, and marking it
--  stable would be a lie Postgres is entitled to act on - it may cache or
--  elide a stable function's call within a statement, which would silently
--  drop the audit for exactly the second and third reads that matter most.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_admission_one(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_ref    text;
  v_out    jsonb;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may open an application.'
      using errcode = '42501';
  end if;

  select reference into v_ref from public.admission_applications
   where id = p_id and masjid_id = v_masjid;
  if v_ref is null then
    raise exception 'There is no such application at this masjid.'
      using errcode = 'no_data_found';
  end if;

  select jsonb_build_object(
           'id',            a.id,
           'reference',     a.reference,
           'academic_year', a.academic_year,
           'submitted_at',  a.submitted_at,
           'status',        a.status,
           'office_notes',  a.office_notes,
           'reviewed_at',   a.reviewed_at,
           'reviewed_by',   (select pr.full_name from public.profiles pr
                              where pr.id = a.reviewed_by),

           'parent', jsonb_build_object(
             'first_name',   a.parent_first_name,
             'surname',      a.parent_surname,
             'relationship', coalesce(nullif(a.parent_relationship_other, ''),
                                      a.parent_relationship),
             'email',        a.email,
             'telephone',    a.telephone,
             'mobile',       a.mobile,
             'address_line1', a.address_line1,
             'address_line2', a.address_line2,
             'town',         a.address_town,
             'postcode',     a.postcode),

           'declaration_accepted', a.declaration_accepted,
           'privacy_accepted',     a.privacy_accepted,

           'children', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', s.id, 'position', s.position,
                      'first_name', s.first_name, 'surname', s.surname,
                      'date_of_birth', s.date_of_birth,
                      --  Worked out here rather than in the browser. A screen
                      --  that computes an age from a date of birth is a second
                      --  definition of "how old is this child", and the DOB
                      --  windows on the form are the first.
                      'age_years', floor(extract(epoch from age(s.date_of_birth)) / 31557600)::int,
                      'gender', s.gender,
                      'school_name', s.school_name,
                      'school_year', s.school_year,
                      'previous_madrasah', s.previous_madrasah,
                      'has_send', s.has_send, 'send_detail', s.send_detail,
                      'has_eha_ehcp', s.has_eha_ehcp, 'eha_ehcp_detail', s.eha_ehcp_detail,
                      'has_allergies', s.has_allergies, 'allergy_detail', s.allergy_detail,
                      'medical_conditions', s.medical_conditions,
                      'general_notes', s.general_notes,
                      'choices', coalesce((
                        select jsonb_agg(jsonb_build_object(
                                 'class_key', c.class_key, 'preference', c.preference)
                               order by c.preference)
                          from public.admission_student_choices c
                         where c.student_id = s.id), '[]'::jsonb))
                    order by s.position)
               from public.admission_students s
              where s.application_id = a.id), '[]'::jsonb),

           'contacts', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'id', k.id, 'position', k.position,
                      'full_name', k.full_name, 'relationship', k.relationship,
                      'email', k.email, 'telephone', k.telephone,
                      'mobile', k.mobile, 'alt_mobile', k.alt_mobile,
                      'is_primary', k.is_primary)
                    order by k.is_primary desc, k.position)
               from public.admission_contacts k
              where k.application_id = a.id), '[]'::jsonb)
         )
    into v_out
    from public.admission_applications a
   where a.id = p_id and a.masjid_id = v_masjid;

  --  THE REFERENCE AND THE ID. Not the child, not the condition. See header.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'admission_application_opened',
          jsonb_build_object('id', p_id, 'reference', v_ref));

  return v_out;
end $fn$;

-- ---------------------------------------------------------------------------
--  4. The decision
--
--  DECLINING REQUIRES A REASON, and offering does not.
--
--  Not symmetry for its own sake. An offer explains itself; a refusal is the
--  one a parent rings up about, sometimes months later, and "I think we were
--  full" reconstructed from memory is not an answer the masjid can stand
--  behind. It is the same rule 070 applies to waiving a fee, arrived at from
--  the same direction: the decision that costs somebody something is the one
--  that has to say why.
--
--  The note is stored on the application and is NOT sent anywhere. Telling
--  the family is a phone call.
-- ---------------------------------------------------------------------------
create or replace function public.set_admission_status(
  p_id uuid, p_status text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_was    text;
  v_ref    text;
  v_status text := btrim(coalesce(p_status, ''));
  v_note   text := nullif(btrim(coalesce(p_note, '')), '');
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may decide an application.'
      using errcode = '42501';
  end if;

  if not (v_status = any(array['new','reviewing','offered','waitlisted','declined','withdrawn'])) then
    raise exception '"%" is not a status an application can have.', v_status
      using errcode = 'check_violation';
  end if;

  select status, reference into v_was, v_ref
    from public.admission_applications
   where id = p_id and masjid_id = v_masjid;
  if v_ref is null then
    raise exception 'There is no such application at this masjid.'
      using errcode = 'no_data_found';
  end if;

  if v_status = 'declined' and v_note is null then
    raise exception 'Say why this application is being declined. A family may ring about it months later.'
      using errcode = 'check_violation';
  end if;

  --  AN ABSENT NOTE LEAVES THE EXISTING ONE ALONE. 070 learned this the hard
  --  way: the Discounts screen sent only its own fields and wiped a note it
  --  had never been shown. Moving an application from reviewing to offered
  --  must not erase what somebody wrote while reviewing it.
  update public.admission_applications
     set status      = v_status,
         office_notes = coalesce(v_note, office_notes),
         reviewed_by = auth.uid(),
         reviewed_at = now()
   where id = p_id and masjid_id = v_masjid;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'admission_status_changed',
          jsonb_build_object('id', p_id, 'reference', v_ref,
                             'was', v_was, 'now', v_status));

  return jsonb_build_object('ok', true, 'status', v_status, 'reference', v_ref);
end $fn$;

--  A note on its own, without touching the status. The office reads an
--  application on Tuesday, writes down what it wants to ask the family, and
--  decides on Thursday.
create or replace function public.save_admission_note(p_id uuid, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_ref    text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may write on an application.'
      using errcode = '42501';
  end if;

  select reference into v_ref from public.admission_applications
   where id = p_id and masjid_id = v_masjid;
  if v_ref is null then
    raise exception 'There is no such application at this masjid.'
      using errcode = 'no_data_found';
  end if;

  update public.admission_applications
     set office_notes = nullif(btrim(coalesce(p_note, '')), '')
   where id = p_id and masjid_id = v_masjid;

  --  The act, not the words. An office note about a child outlives the
  --  application under the six-year audit clock; the application itself goes
  --  at three.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'admission_note_saved',
          jsonb_build_object('id', p_id, 'reference', v_ref));

  return jsonb_build_object('ok', true);
end $fn$;

-- ---------------------------------------------------------------------------
--  5. Privileges. 073's lesson, applied before an advisor has to say it.
-- ---------------------------------------------------------------------------
-- ---------------------------------------------------------------------------
--  5a. THE FUNCTIONS BECOME THE ONLY DOOR.
--
--  008 granted SELECT on all four tables to `authenticated`, behind a policy
--  requiring verified_admin(). No data was ever exposed by that: a teaching
--  account fails the policy and reads nothing.
--
--  What it did mean is that an administrator could pull every application
--  straight off the table through PostgREST and never call
--  madrasah_admission_one() - the function that writes down who opened a
--  child's medical record. The audit could be walked around, quietly, by
--  anybody who knew the API. An audit trail with a documented bypass is worse
--  than no audit trail, because somebody will rely on it in front of a parent.
--
--  Nothing reads these tables directly today: the admissions screen did not
--  exist until this commit, and the public form only ever writes. So this
--  takes away a capability nobody is using, and turns the audit from a
--  convention into a fact.
--
--  The SELECT POLICIES ARE LEFT IN PLACE deliberately. They are the belt to
--  this revoke's braces, and if anybody ever re-grants SELECT - which is a
--  one-line mistake - verified_admin() is still standing behind it.
-- ---------------------------------------------------------------------------
revoke select on public.admission_applications     from authenticated;
revoke select on public.admission_students         from authenticated;
revoke select on public.admission_student_choices  from authenticated;
revoke select on public.admission_contacts         from authenticated;

revoke all on function public.madrasah_admissions_overview()                   from public, anon;
revoke all on function public.madrasah_admission_list(text, text, text, integer) from public, anon;
revoke all on function public.madrasah_admission_one(uuid)                     from public, anon;
revoke all on function public.set_admission_status(uuid, text, text)           from public, anon;
revoke all on function public.save_admission_note(uuid, text)                  from public, anon;

grant execute on function public.madrasah_admissions_overview()                   to authenticated;
grant execute on function public.madrasah_admission_list(text, text, text, integer) to authenticated;
grant execute on function public.madrasah_admission_one(uuid)                     to authenticated;
grant execute on function public.set_admission_status(uuid, text, text)           to authenticated;
grant execute on function public.save_admission_note(uuid, text)                  to authenticated;

commit;

-- ===========================================================================
--  CHECKS. Every one proved by deliberately breaking what it guards.
-- ===========================================================================

--  #1  THE LIST DOES NOT CARRY A CHILD'S MEDICAL DETAIL.
--
--      The check this file exists for. It reads the body of the list function
--      and fails if any of the four detail columns appears in it. Broken
--      deliberately by adding send_detail to the list; this failed.
--
--      Asserted against the FUNCTION BODY rather than by calling it, because
--      calling it with no applications in the table returns [] and proves
--      nothing at all - the emptiest possible pass.
do $c1$
declare v_def text; v_bad text := '';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'madrasah_admission_list' limit 1;
  if v_def is null then
    raise exception 'CHECK 1 FAILED: madrasah_admission_list() does not exist.';
  end if;

  --  Only the part that builds the returned object, so the header above is
  --  allowed to name the columns it is warning about.
  v_def := substring(v_def from position('jsonb_build_object' in v_def));

  if v_def like '%send_detail%'        then v_bad := v_bad || 'send_detail '; end if;
  if v_def like '%eha_ehcp_detail%'    then v_bad := v_bad || 'eha_ehcp_detail '; end if;
  if v_def like '%allergy_detail%'     then v_bad := v_bad || 'allergy_detail '; end if;
  if v_def like '%medical_conditions%' and v_def not like '%medical_conditions is not null%'
    then v_bad := v_bad || 'medical_conditions '; end if;
  if v_def like '%general_notes%'      then v_bad := v_bad || 'general_notes '; end if;

  if v_bad <> '' then
    raise exception
      'CHECK 1 FAILED: the admissions LIST carries % - a child''s medical detail belongs in the record, which is opened one at a time and audited, not in a list that sits open on an office screen.', v_bad;
  end if;
  raise notice 'CHECK 1 passed: the list says whether, and the record says what.';
end $c1$;

--  #2  OPENING A RECORD IS WRITTEN DOWN.
--
--      Two halves, because either alone passes for the wrong reason: the
--      function must insert into admin_audit, AND it must not be marked
--      stable - a stable function's call may be elided within a statement,
--      which would drop the audit precisely when a row is read repeatedly.
do $c2$
declare v_def text; v_volatile "char";
begin
  select pg_get_functiondef(p.oid), p.provolatile into v_def, v_volatile
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'madrasah_admission_one' limit 1;
  if v_def is null then
    raise exception 'CHECK 2 FAILED: madrasah_admission_one() does not exist.';
  end if;
  if v_def not like '%admission_application_opened%' then
    raise exception 'CHECK 2 FAILED: opening a child''s record writes no audit row. "Who has read this" would be unanswerable.';
  end if;
  if v_volatile <> 'v' then
    raise exception 'CHECK 2 FAILED: madrasah_admission_one() is marked % rather than volatile. Postgres may elide the call, and the audit row with it.',
      case v_volatile when 's' then 'STABLE' when 'i' then 'IMMUTABLE' else v_volatile::text end;
  end if;
  raise notice 'CHECK 2 passed: opening an application is audited, and the audit cannot be optimised away.';
end $c2$;

--  #3  A REFUSAL HAS TO SAY WHY, AND AN OFFER DOES NOT.
--      Run against the real function, so it exercises the control flow rather
--      than a substring. Needs a row, so it builds one and removes it.
do $c3$
declare
  v_m uuid; v_a uuid; v_bad boolean;
begin
  insert into public.masjids (slug, name, town)
  values ('check076-' || replace(gen_random_uuid()::text, '-', ''),
          'CHECK-076 throwaway', 'Nowhere')
  returning id into v_m;

  insert into public.admission_applications
    (masjid_id, reference, academic_year, parent_first_name, parent_surname,
     parent_relationship, email, mobile, address_line1, address_town, postcode,
     declaration_accepted, privacy_accepted, status)
  values (v_m, 'AD-CHECK076', '2026/27', 'A', 'Parent', 'mother',
          'p@example.test', '07000000000', '1 Nowhere', 'Bolton', 'BL1 1AA',
          true, true, 'new')
  returning id into v_a;

  --  CLEANED UP IN THE RIGHT ORDER, which the first version got wrong.
  --
  --  Inserting the application fires an audit trigger, so admin_audit holds a
  --  row pointing at the throwaway masjid. Deleting the masjid first fails on
  --  admin_audit_masjid_id_fkey and takes the whole migration down with it -
  --  which is exactly what happened, and it rolled back a file that was
  --  otherwise correct. A fixture has to be removed in the reverse of the
  --  order the database created it, including the rows it created for itself.
  v_bad := false;
  begin
    perform public.set_admission_status(v_a, 'declined', null);
    v_bad := true;
  exception
    when sqlstate '42501' then
      --  verified_admin() refused first, so this check never reached the rule
      --  it is meant to test. Say so rather than passing.
      delete from public.admission_applications where masjid_id = v_m;
      delete from public.admin_audit where masjid_id = v_m;
      delete from public.masjids where id = v_m;
      raise notice 'CHECK 3 skipped: no administrator session here, so the decline rule was not exercised. It is covered by _test/admissions_test.py in the browser.';
      return;
    when check_violation then null;
  end;
  if v_bad then
    delete from public.admission_applications where masjid_id = v_m;
    delete from public.admin_audit where masjid_id = v_m;
    delete from public.masjids where id = v_m;
    raise exception 'CHECK 3 FAILED: an application was declined with no reason recorded.';
  end if;

  delete from public.admission_applications where masjid_id = v_m;
  delete from public.admin_audit where masjid_id = v_m;
  delete from public.masjids where id = v_m;
  raise notice 'CHECK 3 passed: a refusal records why.';
end $c3$;

--  #4  NO ADMISSIONS FUNCTION IS REACHABLE BY A SIGNED-OUT STRANGER.
--
--      073 had to be written after the fact for the fees section. This is the
--      same check, applied to this file on the day it was written, and it
--      names has_function_privilege() rather than inferring from an exception
--      - verified_admin() also raises 42501, and a test that cannot tell the
--      lock from the doorman is the mistake 073 documents.
--
--      submit_admission_application IS excluded, deliberately and by name:
--      it is the public form's one door and anon is supposed to reach it.
do $c4$
declare v_bad text;
begin
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_bad
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and (p.proname like '%admission%' or p.proname = 'save_admission_note')
     and p.proname <> 'submit_admission_application'
     and has_function_privilege('anon', p.oid, 'EXECUTE');
  if v_bad is not null then
    raise exception
      'CHECK 4 FAILED: a signed-out stranger may call %. Postgres grants EXECUTE to PUBLIC by default and anon inherits it - revoke before you grant.', v_bad;
  end if;
  raise notice 'CHECK 4 passed: only the public form''s own function is reachable by anon.';
end $c4$;

--  #5  THE HONEST HALF OF CHECK 4. A revoke one role too wide would shut the
--      screen for the people who are supposed to use it, and CHECK 4 would
--      pass perfectly well in that state.
do $c5$
declare v_shut text;
begin
  select string_agg(p.oid::regprocedure::text, ', ' order by p.proname) into v_shut
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in ('madrasah_admissions_overview', 'madrasah_admission_list',
                       'madrasah_admission_one', 'set_admission_status',
                       'save_admission_note')
     and not has_function_privilege('authenticated', p.oid, 'EXECUTE');
  if v_shut is not null then
    raise exception
      'CHECK 5 FAILED: % cannot be called by a signed-in administrator either. The screen would report that it cannot reach the database, and it would look like an outage.', v_shut;
  end if;
  raise notice 'CHECK 5 passed: all five are still callable by a signed-in administrator.';
end $c5$;

--  #6  THE AUDIT IS THE ONLY DOOR, WHICH IT WAS NOT.
--
--      The first version of this check asserted the fees pattern - forced RLS
--      with ZERO policies - and failed, because 008 did something different
--      and better suited to these tables:
--
--        SELECT  to authenticated  using (verified_admin() and masjid_id = current_masjid())
--        INSERT  to public         with check (true)      <- for the definer
--        DELETE  to public         using (true)           <- for the purge
--
--      The permissive insert and delete policies look alarming and are not:
--      no role holds INSERT or DELETE on these tables, so nothing can reach
--      them except the table owner, which is what SECURITY DEFINER runs as.
--      That absent grant is the load-bearing fact and it is asserted below,
--      because a policy saying `true` is only safe while nothing can use it.
--
--      The check was wrong, not the database. But finding out why turned up
--      something that was:
--
--      `authenticated` HELD SELECT DIRECTLY ON ALL FOUR TABLES. The policy
--      required verified_admin(), so no teacher could read a child's medical
--      record - the data was never exposed. What it meant is that an
--      administrator could read every application straight off the table
--      through PostgREST and never touch madrasah_admission_one(), which is
--      the function that writes down who looked. The audit this file exists
--      for could be walked around by anybody who knew the API, and the
--      masjid would have had no idea.
--
--      An audit trail with a documented bypass is worse than none, because
--      somebody will rely on it. SELECT is revoked below and the functions
--      become the only door - which is what the fees pattern is for, arrived
--      at here from the opposite direction.
do $c6$
declare v_t text; v_forced boolean; v_priv text; v_pol text; v_bad text := '';
begin
  foreach v_t in array array['admission_applications', 'admission_students',
                             'admission_student_choices', 'admission_contacts'] loop

    select relforcerowsecurity into v_forced
      from pg_class where oid = ('public.' || v_t)::regclass;
    if not v_forced then
      v_bad := v_bad || v_t || ' has FORCE ROW LEVEL SECURITY off. ';
    end if;

    --  anon holds nothing at all. The public form reaches these tables only
    --  through submit_admission_application(), which runs as the owner.
    select string_agg(privilege_type, ',') into v_priv
      from information_schema.role_table_grants
     where table_schema = 'public' and table_name = v_t and grantee = 'anon';
    if v_priv is not null then
      v_bad := v_bad || 'anon holds ' || v_priv || ' on ' || v_t || '. ';
    end if;

    --  And neither does authenticated, now. See above.
    select string_agg(privilege_type, ',') into v_priv
      from information_schema.role_table_grants
     where table_schema = 'public' and table_name = v_t and grantee = 'authenticated';
    if v_priv is not null then
      v_bad := v_bad || 'authenticated holds ' || v_priv || ' on ' || v_t
            || ' - a child''s record could be read without madrasah_admission_one() '
            || 'writing down who read it. ';
    end if;

    --  Any SELECT policy that survives must still demand verified_admin().
    --  If one is ever added without it, a signed-in teaching account reaches
    --  every allergy and every EHCP in the building.
    select string_agg(policyname, ', ') into v_pol
      from pg_policies
     where schemaname = 'public' and tablename = v_t and cmd = 'SELECT'
       and coalesce(qual, '') not like '%verified_admin()%';
    if v_pol is not null then
      v_bad := v_bad || 'SELECT policy ' || v_pol || ' on ' || v_t
            || ' does not require verified_admin(). ';
    end if;
  end loop;

  if v_bad <> '' then
    raise exception 'CHECK 6 FAILED: %', v_bad;
  end if;
  raise notice 'CHECK 6 passed: anon and authenticated hold nothing on the four tables, so the audited functions are the only way in.';
end $c6$;

-- ===========================================================================
--  AFTER APPLYING THIS FILE
--
--  Nothing. No table changes, no cron, no edge function. The purge that was
--  already scheduled in 008 is untouched and still runs.
--
--  The Applications row in the madrasah rail can come off `soon` once
--  portal/admissions/ is pushed.
-- ===========================================================================
