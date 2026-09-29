--  =====================================================================
--  124 - A PARENT READS THEIR OWN CHILDREN, AND REPORTS AN ABSENCE
--  29 September 2026
--  =====================================================================
--
--  Slice 2 of the parents' portal. Three new read functions for the parent's
--  own screens, and ONE widened caller gate on record_parent_absence().
--
--  EVERY PARENT-FACING FUNCTION HERE TAKES ITS PUPIL SET FROM
--  my_parent_children() AND FROM NOTHING ELSE - directly, or through
--  require_my_child() / is_my_child(), which are built on it. None reads
--  current_masjid(), because it is NULL for a parent by design (db/119); the
--  masjid comes off the parent's own login. A foreign pupil id, a pupil id
--  that does not exist and a caller who is not a parent are all refused with
--  ONE message, 'not yours' / 42501, so the refusal cannot be used to probe
--  which children exist.
--
--  ---------------------------------------------------------------------
--  THE FUNCTIONS
--  ---------------------------------------------------------------------
--  parent_my_children()          each child on this household: name, class,
--                                teacher, and what the madrasah holds - date
--                                of birth, school, medical, allergies, SEND,
--                                EHCP, walk-home consent, address, postcode,
--                                email - and the household's guardians with
--                                the phone and email held for them.
--                                WHAT IT DELIBERATELY DOES NOT RETURN:
--                                madrasah_pupils.notes and the household note
--                                (the office's own working notes; a parent
--                                who wants everything asks for it as a
--                                subject access request), legacy_ref, the fee
--                                rate, any id but the pupil's own.
--  parent_attendance(pupil)      that child's marks, newest first: date, mark,
--                                reason, and whether it came from the
--                                madrasah or from a parent (and whether it was
--                                this parent). Also whether the register is
--                                being kept and when it opened, so the screen
--                                can say "not started" instead of drawing an
--                                empty table that reads as perfect attendance.
--  parent_absence_options(pupil) the evenings a report can still be made for
--                                (register due, since the register opened,
--                                inside the fortnight) and what is already
--                                recorded for each, with whether it may still
--                                be changed. The form offers these and nothing
--                                else; the database still decides.
--
--  ---------------------------------------------------------------------
--  THE WIDENED GATE - record_parent_absence()
--  ---------------------------------------------------------------------
--  Before: verified_madrasah() or refused.
--  After : verified_madrasah() (unchanged, and first), OR is_parent() for a
--          child in my_parent_children() (require_my_child()); anybody else
--          gets the SAME sentence and errcode they got before.
--
--  KEPT, ALL OF IT (db/097, 116, 117, 118): not before the child is on a
--  roll, the attendance gate (attendance_permitted), not the future, not more
--  than fourteen days back, register_due() (not outside the year, a closure or
--  a day the madrasah does not run), the opening-day floor, a mark of absent /
--  excused / late and never present, and a teacher who marks present or late
--  still wins - save_register_draft() is untouched and its rule is proved
--  below from the parent's side.
--
--  ADDED, PARENT CALLERS ONLY (the office's behaviour does not move):
--    * a parent may not overwrite a mark that did not come from a parent.
--      The function's ON CONFLICT replaces whatever is there; for the office
--      that is right (they are recording a phone call), for a parent it would
--      let a mother turn a teacher's "absent" into "excused with a reason", or
--      a "present" into "absent", by post. The register is the madrasah's
--      record of what it observed. A parent may correct THEIR OWN report.
--    * a parent may not change anything once that class's register for that
--      evening has been handed in.
--    * the reason is at most 500 characters.
--    * the refusal words for a parent are a parent's words: no "families have
--      not been told" count, no "correct it on the register".
--  And for EVERY caller, a null date or null mark is refused with a sentence
--  instead of failing on a NOT NULL constraint, whose error DETAIL prints the
--  whole failing row (child id and reason) into the server log.
--
--  attendance_permitted() / register_due() read current_masjid(), which is
--  NULL for a parent - see db/123, which moved their bodies to <name>_for(
--  masjid, ...) unchanged. This function calls the _for versions with the
--  masjid taken from the parent's own login.
--
--  read-patch-refuse: each anchor must occur EXACTLY ONCE in the live
--  definition or nothing changes.
--  =====================================================================

create or replace function public.parent_my_children()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_me uuid; v_masjid uuid; v_hh uuid;
begin
  if not public.is_parent() then
    raise exception 'not yours' using errcode = '42501';
  end if;
  select l.guardian_id, l.masjid_id, g.household_id into v_me, v_masjid, v_hh
    from public.madrasah_parent_logins l
    join public.madrasah_guardians g on g.id = l.guardian_id and g.masjid_id = l.masjid_id
   where l.user_id = auth.uid();

  return jsonb_build_object(
    'family_reference', (select h.reference from public.madrasah_households h
                          where h.id = v_hh and h.masjid_id = v_masjid),
    'children', coalesce((
      select jsonb_agg(jsonb_build_object(
          'pupil_id',          p.id,
          'first_name',        p.first_name,
          'last_name',         p.last_name,
          'status',            p.status,
          'joined_on',         p.joined_on,
          'date_of_birth',     p.date_of_birth,
          'gender',            p.gender,
          'school',            p.school,
          'school_year',       p.school_year,
          'previous_madrasah', p.prev_madrasah,
          'medical',           p.medical,
          'allergies',         p.allergies,
          'send_detail',       p.send_detail,
          'ehcp_detail',       p.ehcp_detail,
          'walk_home_consent', p.walk_home_consent,
          'address',           p.address,
          'postcode',          p.postcode,
          'email',             p.email,
          'classes', coalesce((
            select jsonb_agg(jsonb_build_object(
                     'name', c.name, 'section', c.section, 'active', c.is_active,
                     'teacher', nullif(btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)), ''))
                   order by c.is_active desc, pc.added_at desc, c.id)
              from public.madrasah_pupil_classes pc
              join public.madrasah_classes c
                on c.id = pc.class_id and c.masjid_id = p.masjid_id
              left join public.madrasah_staff s
                on s.id = c.main_teacher_id and s.masjid_id = p.masjid_id
             where pc.pupil_id = p.id and pc.masjid_id = p.masjid_id), '[]'::jsonb))
        order by p.first_name, p.id)
        from public.my_parent_children() mc
        join public.madrasah_pupils p on p.id = mc.pupil_id and p.masjid_id = mc.masjid_id
       where p.status <> 'left'), '[]'::jsonb),
    'guardians', coalesce((
      select jsonb_agg(jsonb_build_object(
               'full_name', g.full_name, 'phone', g.phone, 'email', g.email,
               'is_primary', g.is_primary, 'is_me', g.id = v_me)
             order by g.is_primary desc, g.full_name, g.id)
        from public.madrasah_guardians g
       where g.household_id = v_hh and g.masjid_id = v_masjid), '[]'::jsonb));
end $$;

create or replace function public.parent_attendance(p_pupil uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare v_masjid uuid; v_perm jsonb; v_opened date;
begin
  perform public.require_my_child(p_pupil);
  select c.masjid_id into v_masjid from public.my_parent_children() c
   where c.pupil_id = p_pupil;
  v_perm   := public.attendance_permitted_for(v_masjid);
  v_opened := public.register_opened_on(v_masjid);

  return jsonb_build_object(
    'first_name', (select p.first_name from public.madrasah_pupils p
                    where p.id = p_pupil and p.masjid_id = v_masjid),
    'permitted',  coalesce((v_perm ->> 'permitted')::boolean, false),
    'opened_on',  v_opened,
    'today',      current_date,
    'marks', coalesce((
      select jsonb_agg(jsonb_build_object(
               'on_date', a.on_date, 'mark', a.mark, 'reason', a.reason,
               'source',  case when a.source = 'parent' then 'parent' else 'madrasah' end,
               'by_me',   (a.source = 'parent' and a.marked_by = auth.uid()),
               'class',   c.name)
             order by a.on_date desc)
        from (select x.* from public.madrasah_attendance x
               where x.pupil_id = p_pupil and x.masjid_id = v_masjid
               order by x.on_date desc limit 400) a
        left join public.madrasah_classes c
          on c.id = a.class_id and c.masjid_id = v_masjid), '[]'::jsonb));
end $$;

create or replace function public.parent_absence_options(p_pupil uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid; v_class uuid; v_perm boolean; v_opened date;
  v_out jsonb := '[]'::jsonb; v_why text := null; i int; d date; r record;
  v_can boolean;
begin
  perform public.require_my_child(p_pupil);
  select c.masjid_id into v_masjid from public.my_parent_children() c
   where c.pupil_id = p_pupil;
  v_perm   := coalesce((public.attendance_permitted_for(v_masjid) ->> 'permitted')::boolean, false);
  v_opened := public.register_opened_on(v_masjid);

  --  The class record_parent_absence() will use: on the roll, active first,
  --  latest roll next, id last.
  select pc.class_id into v_class
    from public.madrasah_pupils p
    join public.madrasah_pupil_classes pc on pc.pupil_id = p.id
    join public.madrasah_classes c on c.id = pc.class_id
   where p.id = p_pupil and p.masjid_id = v_masjid and c.masjid_id = v_masjid
     and p.left_on is null and p.status = 'on_roll'
   order by c.is_active desc, pc.added_at desc, c.id
   limit 1;

  if v_class is null then
    v_why := 'not_on_roll';
  elsif not v_perm or v_opened is null then
    v_why := 'not_started';
  else
    for i in 0..14 loop
      d := current_date - i;
      continue when d < v_opened;
      continue when not coalesce((public.register_due_for(v_masjid, v_class, d) ->> 'due')::boolean, false);
      select a.mark, a.reason, a.source, a.marked_by into r
        from public.madrasah_attendance a
       where a.pupil_id = p_pupil and a.on_date = d and a.masjid_id = v_masjid;
      v_can := (r.source is null or r.source = 'parent')
               and not exists (select 1 from public.madrasah_registers g
                                where g.class_id = v_class and g.on_date = d
                                  and g.masjid_id = v_masjid and g.state = 'submitted');
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'on_date', d,
        'existing_mark',   r.mark,
        'existing_reason', r.reason,
        'existing_source', case when r.source is null then null
                                when r.source = 'parent' then 'parent' else 'madrasah' end,
        'existing_by_me',  (r.source = 'parent' and r.marked_by = auth.uid()),
        'can_change',      v_can));
    end loop;
    if jsonb_array_length(v_out) = 0 then v_why := 'no_evenings'; end if;
  end if;

  return jsonb_build_object(
    'first_name', (select p.first_name from public.madrasah_pupils p
                    where p.id = p_pupil and p.masjid_id = v_masjid),
    'permitted', v_perm, 'opened_on', v_opened, 'today', current_date,
    'evenings', v_out, 'why', v_why);
end $$;

--  ---------------------------------------------------------------------
--  THE WIDENED GATE. read-patch-refuse against the live definition.
--  ---------------------------------------------------------------------
do $mig$
declare
  v_def text; v_new text; v_n int; i int;
  v_old text[] := array[]::text[]; v_rep text[] := array[]::text[];
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'record_parent_absence'
     and pg_get_function_identity_arguments(p.oid)
         = 'p_pupil uuid, p_date date, p_mark text, p_reason text';
  if v_def is null then
    raise exception '124: record_parent_absence() does not exist. Nothing changed.';
  end if;
  if position('is_parent()' in v_def) > 0 then
    raise notice '124: record_parent_absence() already admits a parent. Nothing changed.';
    return;
  end if;

  --  1. the variables: v_masjid is no longer taken from current_masjid() at
  --     declaration (it is NULL for a parent); it is set below, per caller.
  v_old := array_append(v_old, $a$declare v_masjid uuid := public.current_masjid(); v_class uuid;$a$);
  v_rep := array_append(v_rep, $b$declare v_masjid uuid; v_class uuid; v_parent boolean := false;$b$);

  --  2. THE CALLER GATE.
  v_old := array_append(v_old, $a$  if not public.verified_madrasah() then
    raise exception 'Only the madrasah office may record what a parent has said.'
      using errcode = '42501';
  end if;$a$);
  v_rep := array_append(v_rep, $b$  if public.verified_madrasah() then
    v_masjid := public.current_masjid();
  elsif public.is_parent() then
    --  A PARENT. The pupil set is my_parent_children() and nothing else;
    --  a foreign, unknown or left-household id is refused BEFORE any other
    --  argument is looked at, with the one sentence require_my_child() uses.
    perform public.require_my_child(p_pupil);
    select c.masjid_id into v_masjid from public.my_parent_children() c
     where c.pupil_id = p_pupil;
    if v_masjid is null then
      raise exception 'not yours' using errcode = '42501';
    end if;
    v_parent := true;
  else
    raise exception 'Only the madrasah office may record what a parent has said.'
      using errcode = '42501';
  end if;
  if p_date is null or p_mark is null then
    raise exception 'Choose an evening, and say whether the child is away or late.'
      using errcode = '22023';
  end if;
  if v_parent and length(coalesce(p_reason, '')) > 500 then
    raise exception 'Please keep the reason to 500 characters or fewer.'
      using errcode = '22023';
  end if;$b$);

  --  3. the roll refusal, in a parent's words for a parent.
  v_old := array_append(v_old, $a$  if v_class is null then
    raise exception 'That child is not on the roll of one of your classes.'
      using errcode = '42501';
  end if;$a$);
  v_rep := array_append(v_rep, $b$  if v_class is null then
    raise exception '%', case when v_parent
        then 'That child is not on the roll of a class at the moment, so nothing '
             || 'can be reported for them. Please ring the office.'
        else 'That child is not on the roll of one of your classes.' end
      using errcode = '42501';
  end if;$b$);

  --  4. the attendance gate, asked of THIS masjid, and worded for a parent.
  v_old := array_append(v_old, $a$  v_gate := public.attendance_permitted();
  if not (v_gate ->> 'permitted')::boolean then
    raise exception '%', v_gate ->> 'why' using errcode = '42501';
  end if;$a$);
  v_rep := array_append(v_rep, $b$  v_gate := public.attendance_permitted_for(v_masjid);
  if not (v_gate ->> 'permitted')::boolean then
    raise exception '%', case when v_parent
        then 'The register is not being kept at the moment, so a report of an '
             || 'absence cannot be taken here. Please ring the office.'
        else v_gate ->> 'why' end
      using errcode = '42501';
  end if;$b$);

  --  5. the two date limits, then register_due() for THIS masjid.
  v_old := array_append(v_old, $a$  if p_date > current_date then
    raise exception 'A parent cannot be recorded as having said a child was '
                    'away on a day that has not happened.'
      using errcode = '22023';
  end if;
  if p_date < current_date - 14 then
    raise exception 'That evening is more than a fortnight ago. Correct it on '
                    'the register instead, so the record says it was corrected '
                    'rather than reported by a parent at the time.'
      using errcode = '22023';
  end if;
  v_due := public.register_due(v_class, p_date);$a$);
  v_rep := array_append(v_rep, $b$  if p_date > current_date then
    raise exception '%', case when v_parent
        then 'You can tell us about tonight, or an evening in the last fortnight - '
             || 'not one that has not happened yet. To let us know about a later '
             || 'evening, please ring the office.'
        else 'A parent cannot be recorded as having said a child was away on a '
             || 'day that has not happened.' end
      using errcode = '22023';
  end if;
  if p_date < current_date - 14 then
    raise exception '%', case when v_parent
        then 'That evening is more than a fortnight ago. Please ring the office.'
        else 'That evening is more than a fortnight ago. Correct it on the '
             || 'register instead, so the record says it was corrected rather '
             || 'than reported by a parent at the time.' end
      using errcode = '22023';
  end if;
  v_due := public.register_due_for(v_masjid, v_class, p_date);$b$);

  --  6. BEFORE THE WRITE: a parent never overwrites the madrasah's own mark,
  --     and never touches a register that has been handed in.
  v_old := array_append(v_old, $a$  insert into public.madrasah_attendance
    (masjid_id, pupil_id, class_id, on_date, mark, reason, source, marked_by)$a$);
  v_rep := array_append(v_rep, $b$  if v_parent then
    if exists (select 1 from public.madrasah_attendance a
                where a.pupil_id = p_pupil and a.on_date = p_date
                  and a.masjid_id = v_masjid and a.source <> 'parent') then
      raise exception 'The madrasah has already recorded that evening. If that is '
                      'not right, please ring the office.'
        using errcode = '22023';
    end if;
    if exists (select 1 from public.madrasah_registers g
                where g.class_id = v_class and g.on_date = p_date
                  and g.masjid_id = v_masjid and g.state = 'submitted') then
      raise exception 'That evening''s register has been handed in. If something '
                      'needs changing, please ring the office.'
        using errcode = '22023';
    end if;
  end if;

  insert into public.madrasah_attendance
    (masjid_id, pupil_id, class_id, on_date, mark, reason, source, marked_by)$b$);

  v_new := v_def;
  for i in 1..array_length(v_old, 1) loop
    v_n := (length(v_new) - length(replace(v_new, v_old[i], ''))) / length(v_old[i]);
    if v_n <> 1 then
      raise exception '124: anchor % occurs % times in the live definition, expected 1. NOT changed.', i, v_n;
    end if;
    v_new := replace(v_new, v_old[i], v_rep[i]);
  end loop;
  execute v_new;
end $mig$;

--  Grants. The three new functions refuse a non-parent inside; anon gets
--  nothing. record_parent_absence() restated exactly as db/097 had it.
revoke all on function public.parent_my_children() from public, anon;
revoke all on function public.parent_attendance(uuid) from public, anon;
revoke all on function public.parent_absence_options(uuid) from public, anon;
grant execute on function public.parent_my_children() to authenticated;
grant execute on function public.parent_attendance(uuid) to authenticated;
grant execute on function public.parent_absence_options(uuid) to authenticated;
revoke all on function public.record_parent_absence(uuid, date, text, text) from public, anon;
grant execute on function public.record_parent_absence(uuid, date, text, text) to authenticated;

--  =====================================================================
--  THE PROOF. Runs inside a subtransaction that ends by raising a sentinel,
--  so NOTHING it writes survives (checked at the end: no notice, no mark,
--  no household, no auth user left behind). Any assertion that fails raises
--  a different error and aborts the WHOLE MIGRATION, so this file cannot
--  apply against a database where the gate does not do what it says.
--
--  NOTHING IN HERE PRINTS A PERSON. Every check is a count, a boolean, a
--  sqlstate or a fixed sentence written in this file. The only real child
--  touched is one id, picked from a DIFFERENT household as the "foreign"
--  pupil, and it is never selected for its contents.
--
--  What the register needs to be open is created INSIDE the subtransaction:
--  a notice for every household (so attendance_permitted() is true). On
--  production the gate is shut, which is correct, and stays shut.
--  =====================================================================
create or replace function pg_temp.px_as(p_uid uuid, p_aal text)
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', case when p_uid is null then '{}'
    else jsonb_build_object('sub', p_uid, 'role', 'authenticated', 'aal', p_aal)::text end, true);
end $$;

--  Run a statement; require an exact sqlstate, and (optionally) that the
--  error's own sentence contains / does not contain a fragment. The sentence
--  is one of OUR fixed ones - none of these functions puts data in a message.
create or replace function pg_temp.px_expect(p_sql text, p_state text, p_has text, p_hasnt text, p_label text)
returns void language plpgsql as $$
declare v_state text := 'none'; v_msg text := '';
begin
  begin execute p_sql;
  exception when others then v_state := sqlstate; v_msg := sqlerrm;
  end;
  if v_state <> p_state then
    raise exception 'PROOF FAILED: % (wanted %, got %)', p_label, p_state, v_state;
  end if;
  if p_has is not null and position(p_has in v_msg) = 0 then
    raise exception 'PROOF FAILED: % (the refusal does not say "%")', p_label, p_has;
  end if;
  if p_hasnt is not null and position(p_hasnt in v_msg) > 0 then
    raise exception 'PROOF FAILED: % (the refusal says "%", which it must not)', p_label, p_hasnt;
  end if;
end $$;

do $proof$
declare
  v_teacher constant uuid := '42a0f447-f2b6-4a31-86c3-8bc2bddaad1b';
  v_masjid uuid; v_hh uuid; v_child uuid; v_parent uuid; v_class uuid; v_admin uuid;
  v_other uuid;                                   -- a REAL pupil of another household
  v_hh2 uuid; v_g2 uuid; v_child2 uuid; v_parent2 uuid;
  v_today date := current_date;
  v_d1 date; v_d2 date; v_d3 date; v_sun date; d date; k int;
  v_n int; v_n2 int; v_j jsonb; v_row record;
  v_all_att_before int; v_all_att_after int;
begin
  begin   --  <<< the subtransaction the sentinel rolls back

  select h.id, h.masjid_id into v_hh, v_masjid from public.madrasah_households h
   where h.reference = 'MF-999999' and h.name = 'Zzzfamily test household';
  if v_hh is null then
    raise notice '124 proof: no test family here - the proof is skipped.';
    raise exception 'SENTINEL' using errcode = 'P0999';
  end if;
  select p.id into v_child from public.madrasah_pupils p where p.household_id = v_hh limit 1;
  select l.user_id into v_parent from public.madrasah_parent_logins l
    join public.madrasah_guardians g on g.id = l.guardian_id where g.household_id = v_hh;
  select c.id into v_class from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.name = 'ZZ TEST CLASS - not a real class';
  select r.user_id into v_admin from public.user_roles r where r.role = 'admin' order by r.user_id limit 1;
  select p.id into v_other from public.madrasah_pupils p
   where p.masjid_id = v_masjid and p.household_id <> v_hh and p.status = 'on_roll' limit 1;
  if v_child is null or v_parent is null or v_class is null or v_admin is null or v_other is null then
    raise exception '124 proof: the fixtures are missing (child %, parent %, class %, admin %, other %)',
      v_child is null, v_parent is null, v_class is null, v_admin is null, v_other is null;
  end if;
  select count(*) into v_all_att_before from public.madrasah_attendance;

  --  ---- 0. WHAT A NON-PARENT GETS FROM THE THREE NEW READS -------------
  perform pg_temp.px_as(v_admin, 'aal2');
  perform pg_temp.px_expect('select public.parent_my_children()', '42501', 'not yours', null, 'an administrator is not a parent (children)');
  perform pg_temp.px_expect(format('select public.parent_attendance(%L)', v_child), '42501', 'not yours', null, 'an administrator is not a parent (attendance)');
  perform pg_temp.px_expect(format('select public.parent_absence_options(%L)', v_child), '42501', 'not yours', null, 'an administrator is not a parent (options)');
  perform pg_temp.px_as(v_teacher, 'aal1');
  perform pg_temp.px_expect('select public.parent_my_children()', '42501', 'not yours', null, 'a teacher is not a parent (children)');
  perform pg_temp.px_expect(format('select public.parent_attendance(%L)', v_child), '42501', 'not yours', null, 'a teacher is not a parent (attendance)');
  perform pg_temp.px_as(null, null);
  perform pg_temp.px_expect('select public.parent_my_children()', '42501', 'not yours', null, 'no session (children)');
  perform pg_temp.px_expect(format('select public.parent_attendance(%L)', v_child), '42501', 'not yours', null, 'no session (attendance)');

  --  ---- 1. THE GATE IS SHUT (as production is): a parent is refused, and
  --          told so in a parent's words with no count of families. --------
  perform pg_temp.px_as(v_parent, 'aal1');
  perform pg_temp.px_expect(
    format('select public.record_parent_absence(%L, %L, ''absent'', ''unwell'')', v_child, v_today),
    '42501', 'not being kept at the moment', 'famil', 'the gate is shut, parent refused in a parent''s words');
  v_j := public.parent_attendance(v_child);
  if (v_j ->> 'permitted')::boolean is not false or v_j -> 'opened_on' <> 'null'::jsonb
     or jsonb_array_length(v_j -> 'marks') <> 0 then
    raise exception 'PROOF FAILED: with the gate shut parent_attendance() must say not permitted, no opening date, no marks';
  end if;
  v_j := public.parent_absence_options(v_child);
  if v_j ->> 'why' <> 'not_started' or jsonb_array_length(v_j -> 'evenings') <> 0 then
    raise exception 'PROOF FAILED: with the gate shut parent_absence_options() must say not_started and offer nothing';
  end if;

  --  ---- 2. OPEN THE REGISTER (inside this subtransaction only) ----------
  perform pg_temp.px_as(null, null);
  insert into public.madrasah_parent_notices
    (masjid_id, household_id, kind, how, notice_version, told_on)
  select h.masjid_id, h.id, 'attendance_notice', 'letter', 'v1.6', v_today - 10
    from public.madrasah_households h
   where h.masjid_id = v_masjid
     and exists (select 1 from public.madrasah_pupils p
                  where p.household_id = h.id and p.left_on is null);
  if not (public.attendance_permitted_for(v_masjid) ->> 'permitted')::boolean
     or public.register_opened_on(v_masjid) is distinct from v_today - 10 then
    raise exception 'PROOF FAILED: could not open the register for the proof';
  end if;

  --  three evenings the madrasah runs, inside the window, most recent first;
  --  and one it does not.
  k := 0;
  for i in 0..9 loop
    d := v_today - i;
    if (public.register_due_for(v_masjid, v_class, d) ->> 'due')::boolean then
      k := k + 1;
      if k = 1 then v_d1 := d; elsif k = 2 then v_d2 := d; elsif k = 3 then v_d3 := d; end if;
    elsif v_sun is null then
      v_sun := d;
    end if;
  end loop;
  if v_d3 is null or v_sun is null then
    raise exception 'PROOF FAILED: could not find three due evenings and one closed one in the last ten days';
  end if;

  --  ---- 3. A PARENT, FOR THEIR OWN CHILD -------------------------------
  perform pg_temp.px_as(v_parent, 'aal1');

  v_j := public.parent_absence_options(v_child);
  if v_j ->> 'why' is not null or (v_j ->> 'permitted')::boolean is not true then
    raise exception 'PROOF FAILED: with the register open the options must be offered';
  end if;
  --  every offered evening is one register_due says is due, none before the opening
  select count(*) into v_n from jsonb_array_elements(v_j -> 'evenings') e
   where not (public.register_due_for(v_masjid, v_class, (e ->> 'on_date')::date) ->> 'due')::boolean
      or (e ->> 'on_date')::date < v_today - 10 or (e ->> 'on_date')::date > v_today;
  if v_n <> 0 or jsonb_array_length(v_j -> 'evenings') < 3 then
    raise exception 'PROOF FAILED: the offered evenings are not exactly the due ones inside the window (%)', v_n;
  end if;

  --  the report itself
  perform public.record_parent_absence(v_child, v_d1, 'absent', 'unwell');
  select a.mark, a.source, a.reason, a.marked_by, a.class_id into v_row
    from public.madrasah_attendance a where a.pupil_id = v_child and a.on_date = v_d1;
  if v_row.mark <> 'absent' or v_row.source <> 'parent' or v_row.reason <> 'unwell'
     or v_row.marked_by <> v_parent or v_row.class_id <> v_class then
    raise exception 'PROOF FAILED: the parent''s report was not stored as source=parent by this parent on the test class';
  end if;
  select count(*) into v_n from public.madrasah_attendance_log l
   where l.pupil_id = v_child and l.on_date = v_d1 and l.source = 'parent' and l.written_by = v_parent;
  if v_n <> 1 then raise exception 'PROOF FAILED: the append-only log has % rows for the report, expected 1', v_n; end if;
  --  a parent may correct THEIR OWN report
  perform public.record_parent_absence(v_child, v_d1, 'late', 'bus');
  select count(*) into v_n from public.madrasah_attendance a
   where a.pupil_id = v_child and a.on_date = v_d1 and a.mark = 'late' and a.reason = 'bus' and a.source = 'parent';
  if v_n <> 1 then raise exception 'PROOF FAILED: a parent could not correct their own report'; end if;
  --  and reads it back, saying it was theirs
  v_j := public.parent_attendance(v_child);
  select count(*) into v_n from jsonb_array_elements(v_j -> 'marks') m
   where (m ->> 'on_date')::date = v_d1 and m ->> 'source' = 'parent'
     and (m ->> 'by_me')::boolean and m ->> 'mark' = 'late' and m ->> 'reason' = 'bus';
  if v_n <> 1 or (v_j ->> 'permitted')::boolean is not true then
    raise exception 'PROOF FAILED: parent_attendance() does not show the parent''s own report as theirs';
  end if;

  --  ---- 4. THE RULES THAT WERE THERE BEFORE, STILL THERE ----------------
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''present'', null)', v_child, v_d2),
    '22023', 'away or late, not present', null, 'a parent cannot say present');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''sick'', null)', v_child, v_d2),
    '22023', null, null, 'an unknown mark');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, null, ''absent'', null)', v_child),
    '22023', 'Choose an evening', null, 'no date');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, null, null)', v_child, v_d2),
    '22023', 'Choose an evening', null, 'no mark');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', %L)', v_child, v_d2, repeat('x', 501)),
    '22023', '500 characters', null, 'a reason that is too long');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_today + 1),
    '22023', 'not one that has not happened yet', 'correct it on', 'the future');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_today - 15),
    '22023', 'more than a fortnight ago', 'register instead', 'more than a fortnight back');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_today - 11),
    '22023', 'register opened on', null, 'before the register opened');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_sun),
    '22023', null, null, 'an evening the madrasah does not run');
  perform pg_temp.px_as(null, null);
  insert into public.madrasah_closures (masjid_id, name, starts_on, ends_on)
    values (v_masjid, 'PROOF closure', v_d3, v_d3);
  perform pg_temp.px_as(v_parent, 'aal1');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_d3),
    '22023', 'PROOF closure', null, 'inside a closure');
  perform pg_temp.px_as(null, null);
  delete from public.madrasah_closures where name = 'PROOF closure';
  perform pg_temp.px_as(v_parent, 'aal1');

  --  ---- 5. THE SINGLE RISKIEST LINE: ANOTHER HOUSEHOLD'S CHILD ----------
  select count(*) into v_n from public.madrasah_attendance where pupil_id = v_other;
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_other, v_d1),
    '42501', 'not yours', null, 'a real child of another household');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', gen_random_uuid(), v_d1),
    '42501', 'not yours', null, 'a pupil id that does not exist');
  --  ...refused BEFORE the arguments are looked at: same answer for a bad date and a bad mark
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, null, null, null)', v_other),
    '42501', 'not yours', null, 'a foreign child, with bad arguments, is still just "not yours"');
  select count(*) into v_n2 from public.madrasah_attendance where pupil_id = v_other;
  if v_n <> v_n2 then
    raise exception 'PROOF FAILED: a mark was written for the foreign child (% before, % after)', v_n, v_n2;
  end if;
  perform pg_temp.px_expect(format('select public.parent_attendance(%L)', v_other), '42501', 'not yours', null, 'reading a foreign child''s attendance');
  perform pg_temp.px_expect(format('select public.parent_absence_options(%L)', v_other), '42501', 'not yours', null, 'reading a foreign child''s options');

  --  A SECOND, GENUINELY SEPARATE HOUSEHOLD WITH ITS OWN LOGIN: each parent is
  --  refused the other's child, in both directions. (Invented names.)
  perform pg_temp.px_as(v_admin, 'aal2');
  insert into public.madrasah_households (masjid_id, reference, name)
    values (v_masjid, 'MF-999998', 'Zzzfamilytwo proof household') returning id into v_hh2;
  insert into public.madrasah_guardians (masjid_id, household_id, full_name, is_primary)
    values (v_masjid, v_hh2, 'Proofparent Zzzfamilytwo', true) returning id into v_g2;
  begin
    insert into public.madrasah_pupils (masjid_id, household_id, first_name, last_name, joined_on)
      values (v_masjid, v_hh2, 'Proofchild', 'Zzzfamilytwo', current_date - 30) returning id into v_child2;
    insert into public.madrasah_pupil_classes (masjid_id, pupil_id, class_id)
      values (v_masjid, v_child2, v_class);
  exception when others then
    raise exception 'refused: %', sqlstate;
  end;
  --  A family added after the register opened closes the gate for EVERYBODY
  --  until it is told (attendance_permitted() is masjid-wide). Tell it.
  insert into public.madrasah_parent_notices
    (masjid_id, household_id, kind, how, notice_version, told_on)
  values (v_masjid, v_hh2, 'attendance_notice', 'letter', 'v1.6', v_today - 10);
  perform public.create_parent_login(v_g2, 'proof.parent.two@example.test',
    replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));
  select l.user_id into v_parent2 from public.madrasah_parent_logins l where l.guardian_id = v_g2;

  perform pg_temp.px_as(v_parent2, 'aal1');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_d1),
    '42501', 'not yours', null, 'household B reporting for household A''s child');
  perform pg_temp.px_expect(format('select public.parent_attendance(%L)', v_child), '42501', 'not yours', null, 'household B reading A''s attendance');
  perform public.record_parent_absence(v_child2, v_d1, 'absent', 'proof');   -- and can for its own
  if (select count(*) from public.my_parent_children()) <> 1 then
    raise exception 'PROOF FAILED: household B sees other than its own one child';
  end if;
  perform pg_temp.px_as(v_parent, 'aal1');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child2, v_d1),
    '42501', 'not yours', null, 'household A reporting for household B''s child');
  --  household A's report on d1 is untouched by household B's activity
  select count(*) into v_n from public.madrasah_attendance a
   where a.pupil_id = v_child and a.on_date = v_d1 and a.mark = 'late' and a.marked_by = v_parent;
  if v_n <> 1 then raise exception 'PROOF FAILED: household A''s mark changed'; end if;

  --  ---- 6. WHO ELSE MAY CALL record_parent_absence -----------------------
  perform pg_temp.px_as(v_teacher, 'aal1');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_d2),
    '42501', 'Only the madrasah office', null, 'a teacher');
  perform pg_temp.px_as(v_admin, 'aal1');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_d2),
    '42501', 'Only the madrasah office', null, 'an administrator without two-step');
  perform pg_temp.px_as(gen_random_uuid(), 'aal2');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_d2),
    '42501', 'Only the madrasah office', null, 'a signed-in stranger');
  perform pg_temp.px_as(null, null);
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', null)', v_child, v_d2),
    '42501', 'Only the madrasah office', null, 'no session');
  if has_function_privilege('anon', 'public.record_parent_absence(uuid,date,text,text)', 'execute')
     or has_function_privilege('anon', 'public.parent_my_children()', 'execute')
     or has_function_privilege('anon', 'public.parent_attendance(uuid)', 'execute')
     or has_function_privilege('anon', 'public.parent_absence_options(uuid)', 'execute')
     or has_function_privilege('anon', 'public.register_due_for(uuid,uuid,date)', 'execute')
     or has_function_privilege('authenticated', 'public.register_due_for(uuid,uuid,date)', 'execute')
     or has_function_privilege('authenticated', 'public.attendance_permitted_for(uuid)', 'execute') then
    raise exception 'PROOF FAILED: anon can execute a parent function, or a _for function is open';
  end if;

  --  ---- 7. THE OFFICE IS UNCHANGED ---------------------------------------
  perform pg_temp.px_as(v_admin, 'aal2');
  perform public.record_parent_absence(v_child, v_d2, 'excused', 'phoned in');
  select count(*) into v_n from public.madrasah_attendance a
   where a.pupil_id = v_child and a.on_date = v_d2 and a.source = 'parent'
     and a.mark = 'excused' and a.marked_by = v_admin;
  if v_n <> 1 then raise exception 'PROOF FAILED: the office can no longer record a phone call'; end if;

  --  ---- 8. A TEACHER STILL WINS, AND A PARENT CANNOT UNDO THE TEACHER ----
  --  d2 holds the office's parent-source mark. The teacher marks ABSENT: the
  --  parent's word is kept. The teacher marks PRESENT: it replaces it.
  perform pg_temp.px_as(v_teacher, 'aal1');
  v_j := public.save_register_draft(v_class, v_d2,
           jsonb_build_array(jsonb_build_object('pupil_id', v_child, 'mark', 'absent')));
  if (v_j ->> 'parent_reports_kept')::int <> 1 then
    raise exception 'PROOF FAILED: a teacher''s blanket "absent" overwrote a parent''s word';
  end if;
  v_j := public.save_register_draft(v_class, v_d2,
           jsonb_build_array(jsonb_build_object('pupil_id', v_child, 'mark', 'present')));
  select count(*) into v_n from public.madrasah_attendance a
   where a.pupil_id = v_child and a.on_date = v_d2 and a.mark = 'present' and a.source <> 'parent';
  if v_n <> 1 then raise exception 'PROOF FAILED: a teacher marking present did not win'; end if;
  perform pg_temp.px_as(v_parent, 'aal1');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''absent'', ''actually away'')', v_child, v_d2),
    '22023', 'already recorded', null, 'a parent cannot overwrite the teacher''s present');
  select count(*) into v_n from public.madrasah_attendance a
   where a.pupil_id = v_child and a.on_date = v_d2 and a.mark = 'present' and a.source <> 'parent';
  if v_n <> 1 then raise exception 'PROOF FAILED: the teacher''s mark was changed by a parent'; end if;
  v_j := public.parent_absence_options(v_child);
  select count(*) into v_n from jsonb_array_elements(v_j -> 'evenings') e
   where (e ->> 'on_date')::date = v_d2 and not (e ->> 'can_change')::boolean
     and e ->> 'existing_source' = 'madrasah' and e ->> 'existing_mark' = 'present';
  if v_n <> 1 then raise exception 'PROOF FAILED: options do not show d2 as recorded by the madrasah and closed to change'; end if;

  --  ---- 9. A HANDED-IN REGISTER IS CLOSED TO A PARENT --------------------
  perform public.record_parent_absence(v_child, v_d3, 'absent', 'unwell');
  --  submit_register() wants EVERY child on the roll marked, and the proof's
  --  second household's child is on this class too.
  perform pg_temp.px_as(null, null);
  insert into public.madrasah_attendance (masjid_id, pupil_id, class_id, on_date, mark, source, marked_by)
    values (v_masjid, v_child2, v_class, v_d3, 'present', 'register', v_teacher);
  perform pg_temp.px_as(v_teacher, 'aal1');
  perform public.submit_register(v_class, v_d3);
  perform pg_temp.px_as(v_parent, 'aal1');
  perform pg_temp.px_expect(format('select public.record_parent_absence(%L, %L, ''late'', null)', v_child, v_d3),
    '22023', 'handed in', null, 'a handed-in register');
  select count(*) into v_n from public.madrasah_attendance a
   where a.pupil_id = v_child and a.on_date = v_d3 and a.mark = 'absent' and a.reason = 'unwell';
  if v_n <> 1 then raise exception 'PROOF FAILED: a handed-in register was changed'; end if;

  --  ---- 10. WHAT parent_my_children() RETURNS, AND WHAT IT NEVER DOES ----
  perform pg_temp.px_as(null, null);
  begin
    update public.madrasah_pupils
       set medical = 'ZZ-MED-PROOF', allergies = 'ZZ-ALLERGY-PROOF', notes = 'ZZ-INTERNAL-NOTE-PROOF',
           address = 'ZZ-ADDRESS-PROOF', postcode = 'ZZ1 1ZZ', school = 'ZZ-SCHOOL-PROOF',
           legacy_ref = 'ZZ-LEGACY-PROOF'
     where id = v_child;
  exception when others then
    raise exception 'refused: %', sqlstate;   --  sqlstate only, never sqlerrm (CLAUDE.md)
  end;
  update public.madrasah_households set note = 'ZZ-HOUSEHOLD-NOTE-PROOF' where id = v_hh;
  perform pg_temp.px_as(v_parent, 'aal1');
  v_j := public.parent_my_children();
  if jsonb_array_length(v_j -> 'children') <> 1
     or (v_j -> 'children' -> 0 ->> 'pupil_id')::uuid <> v_child then
    raise exception 'PROOF FAILED: a parent does not see exactly their own child';
  end if;
  if v_j -> 'children' -> 0 ->> 'medical' <> 'ZZ-MED-PROOF'
     or v_j -> 'children' -> 0 ->> 'allergies' <> 'ZZ-ALLERGY-PROOF'
     or v_j -> 'children' -> 0 ->> 'address' <> 'ZZ-ADDRESS-PROOF'
     or v_j -> 'children' -> 0 ->> 'school' <> 'ZZ-SCHOOL-PROOF' then
    raise exception 'PROOF FAILED: the details the madrasah holds are not shown to the parent';
  end if;
  if position('ZZ-INTERNAL-NOTE-PROOF' in v_j::text) > 0
     or position('ZZ-HOUSEHOLD-NOTE-PROOF' in v_j::text) > 0
     or position('ZZ-LEGACY-PROOF' in v_j::text) > 0
     or v_j::text like '%fee_rate%' or v_j::text like '%masjid_id%' or v_j::text like '%household_id%' then
    raise exception 'PROOF FAILED: an internal note, legacy ref or internal id reached a parent';
  end if;
  if jsonb_array_length(v_j -> 'guardians') <> 1 then
    raise exception 'PROOF FAILED: the household''s guardians are not exactly its own';
  end if;
  if (v_j -> 'children' -> 0 -> 'classes' -> 0 ->> 'name') <> 'ZZ TEST CLASS - not a real class'
     or (v_j -> 'children' -> 0 -> 'classes' -> 0 ->> 'teacher') is null then
    raise exception 'PROOF FAILED: the child''s class and teacher are not shown';
  end if;

  --  ---- the sentinel: roll it all back ------------------------------------
  perform pg_temp.px_as(null, null);
  raise exception 'SENTINEL' using errcode = 'P0999';
  exception when sqlstate 'P0999' then
    perform set_config('request.jwt.claims', '{}', true);
  end;

  --  ---- NOTHING SURVIVED ---------------------------------------------------
  select count(*) into v_all_att_after from public.madrasah_attendance;
  if not exists (select 1 from public.madrasah_households where reference = 'MF-999999') then
    return;
  end if;
  select h.id into v_hh from public.madrasah_households h where h.reference = 'MF-999999';
  if (select count(*) from public.madrasah_parent_notices) <> 0
     or (select count(*) from public.madrasah_attendance a join public.madrasah_pupils p on p.id = a.pupil_id where p.household_id = v_hh) <> 0
     or exists (select 1 from public.madrasah_households where reference = 'MF-999998')
     or exists (select 1 from auth.users where email = 'proof.parent.two@example.test')
     or (select count(*) from public.madrasah_closures where name = 'PROOF closure') <> 0
     or (select count(*) from public.madrasah_pupils where medical = 'ZZ-MED-PROOF') <> 0
     or (select count(*) from public.madrasah_registers r where r.class_id in
           (select id from public.madrasah_classes where name = 'ZZ TEST CLASS - not a real class')) <> 0 then
    raise exception 'PROOF FAILED: something the proof wrote survived it';
  end if;
end $proof$;
