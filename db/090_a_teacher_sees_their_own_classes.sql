--  =====================================================================
--  090 - A TEACHER SEES THEIR OWN CLASSES, AND NOTHING ELSE
--  27 September 2026
--  =====================================================================
--
--  THE ROLE THAT EXISTED WAS A TRAP. `teacher` has been in the app_role enum
--  since the beginning and granted NOTHING: verified_madrasah() is
--
--      is_aal2() and (is_admin() or has_role(uid, 'madrasah'))
--
--  so every madrasah function refused a teacher outright. The obvious way to
--  give a teacher the register - grant them 'madrasah' - hands them all 552
--  children, every family's address and telephone number, every medical mark,
--  the fees and the applications. THE ROLE THAT LOOKS LIKE THE ANSWER IS THE
--  BREACH.
--
--  So this is built rather than granted, and the scoping lives in the
--  DATABASE rather than in the screens. A teacher is refused by the function,
--  not by a page that declines to draw a button. That distinction is the
--  whole point: a scoped screen is a convention, and conventions get worked
--  around with a URL.
--
--  WHAT A TEACHER CAN SEE, decided by the masjid:
--    * the classes they teach, and nobody else's
--    * the children in those classes
--    * medical, allergy and SEND for those children - because that is WHY
--      the madrasah holds it. The notice tells parents it is kept "so that
--      staff can look after my child safely", and a teacher who does not know
--      about an epipen cannot act. Every opening is recorded against a name.
--    * one telephone number to ring for those children
--    * they may RAISE a safeguarding concern and never read one (see 091)
--
--  WHAT A TEACHER CANNOT SEE: any other class, the roll as a whole, families,
--  fees, applications, exports, staff records, the archive, the parent notice
--  list, or the admin Today screen. Proved, as a real teacher account, in
--  rolled-back transactions:
--
--      the whole roll (552 children) : false
--      every family                  : REFUSED
--      exporting the families        : REFUSED
--      exporting the roll            : REFUSED
--      the applications              : REFUSED
--      the OFFICE record of my pupil : REFUSED
--      the staff list                : REFUSED
--      reading safeguarding concerns : REFUSED
--      opening a child NOT in my class: REFUSED
--      marking ANOTHER class          : REFUSED
--
--  NO SECOND FACTOR, AND THAT IS A TRADE MADE ON PURPOSE. Forty teachers with
--  no email addresses cannot realistically each enrol an authenticator, and
--  the failure mode of trying is worse than the risk: teachers sharing one
--  colleague's login, which destroys the audit trail and the scoping at the
--  same time. The trade is weaker authentication for very much less data
--  behind it. Administrators keep two-step, and everything an administrator
--  can reach still demands it.

create or replace function public.is_teacher()
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select public.has_role(auth.uid(), 'teacher'::public.app_role);
$$;

revoke all on function public.is_teacher() from public, anon;
grant execute on function public.is_teacher() to authenticated;

--  The staff row behind the login. A teacher account with no staff row can
--  reach nothing at all, which is the correct answer: we do not know which
--  classes they teach, so the answer to "which are mine" is none.
create or replace function public.my_staff_id()
returns uuid language sql stable security definer
set search_path = public, pg_temp as $$
  select s.id from public.madrasah_staff s
   where s.user_id = auth.uid()
     and s.masjid_id = public.current_masjid()
     and s.left_on is null
   limit 1;
$$;

revoke all on function public.my_staff_id() from public, anon;
grant execute on function public.my_staff_id() to authenticated;

--  THE ONE PREDICATE EVERYTHING ELSE HANGS OFF.
--  A class is mine if I am its main teacher OR I am listed against it in
--  madrasah_staff_classes. Both, because the madrasah uses both: 45 classes
--  have a main teacher and there are 72 rows in staff_classes, so a teacher
--  who assists in a class they do not lead is a real case.
create or replace function public.teaches_class(p_class uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select exists (
    select 1
      from public.madrasah_classes c
     where c.id = p_class
       and c.masjid_id = public.current_masjid()
       and (
         c.main_teacher_id = public.my_staff_id()
         or exists (select 1 from public.madrasah_staff_classes sc
                     where sc.class_id = c.id
                       and sc.staff_id = public.my_staff_id())
       )
  ) and public.my_staff_id() is not null;
$$;

revoke all on function public.teaches_class(uuid) from public, anon;
grant execute on function public.teaches_class(uuid) to authenticated;

--  May this caller work with this class at all - as an administrator, as
--  office madrasah staff, or as the teacher of it?
create or replace function public.may_take_register(p_class uuid)
returns boolean language sql stable security definer
set search_path = public, pg_temp as $$
  select public.verified_madrasah()
      or (public.is_teacher() and public.teaches_class(p_class));
$$;

revoke all on function public.may_take_register(uuid) from public, anon;
grant execute on function public.may_take_register(uuid) to authenticated;

--  MY CLASSES. The teacher's whole world.
create or replace function public.madrasah_my_classes(
  p_date date default current_date)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_staff uuid := public.my_staff_id();
  v_rows jsonb;
begin
  if not (public.is_teacher() or public.verified_madrasah()) then
    return jsonb_build_object('allowed', false);
  end if;
  if v_staff is null then
    --  SAID IN WORDS RATHER THAN RETURNED EMPTY. A teacher whose login is not
    --  joined to a staff row would otherwise see a working screen with no
    --  classes on it and conclude the system had lost them.
    return jsonb_build_object('allowed', true, 'rows', '[]'::jsonb,
      'why', 'This login is not linked to a member of staff yet, so the '
          || 'madrasah does not know which classes are yours. Ask the office.');
  end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order, x.name), '[]'::jsonb)
    into v_rows
  from (
    select c.id, c.name, c.section, c.sort_order,
           (c.main_teacher_id = v_staff) as i_am_the_main_teacher,
           (select count(*) from public.madrasah_pupil_classes pc
              join public.madrasah_pupils p on p.id = pc.pupil_id
             where pc.class_id = c.id and p.left_on is null
               and p.status = 'on_roll')                      as on_roll,
           (select count(*) from public.madrasah_attendance a
             where a.class_id = c.id and a.on_date = p_date)  as marked,
           (select count(*) from public.madrasah_attendance a
             where a.class_id = c.id and a.on_date = p_date
               and a.mark in ('absent','excused'))            as away
      from public.madrasah_classes c
     where c.masjid_id = v_masjid and c.is_active
       and (c.main_teacher_id = v_staff
            or exists (select 1 from public.madrasah_staff_classes sc
                        where sc.class_id = c.id and sc.staff_id = v_staff))
  ) x;

  return jsonb_build_object('allowed', true, 'on_date', p_date,
                            'permitted', public.attendance_permitted(),
                            'rows', v_rows);
end $$;

revoke all on function public.madrasah_my_classes(date) from public, anon;
grant execute on function public.madrasah_my_classes(date) to authenticated;

--  ---------------------------------------------------------------------
--  ONE CHILD, FOR THE TEACHER WHO TEACHES THEM
--  ---------------------------------------------------------------------
--
--  A SEPARATE FUNCTION FROM madrasah_pupil_one(), deliberately. That one is
--  the office's full record - date of birth, address, fees, the lot - and
--  adding a "but not if you are a teacher" branch to it would put the scoping
--  inside a function whose job is to return everything. Two functions that
--  return different things are easier to keep honest than one function with
--  a mode.
--
--  WHAT IT LEAVES OUT: address, postcode, date of birth, fee rate, the
--  family's other children, and any note about money. A teacher does not need
--  where a child lives in order to teach them.
--
--  WHAT IT CARRIES: medical, allergy and SEND, because that is the entire
--  reason the madrasah holds it, and one number to ring.
create or replace function public.madrasah_pupil_for_teacher(p_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_row jsonb;
  v_class uuid;
begin
  if not public.is_teacher() then
    raise exception 'This is for madrasah teachers.' using errcode = '42501';
  end if;

  select pc.class_id into v_class
    from public.madrasah_pupil_classes pc
    join public.madrasah_pupils p on p.id = pc.pupil_id
   where pc.pupil_id = p_id
     and p.masjid_id = v_masjid
     and public.teaches_class(pc.class_id)
   limit 1;

  if v_class is null then
    --  THE REFUSAL SAYS NOTHING ABOUT WHETHER THE CHILD EXISTS. "No such
    --  child" and "not your child" must read the same, or the refusal itself
    --  becomes a way to ask whether a name is on the roll.
    raise exception 'That child is not in one of your classes.'
      using errcode = '42501';
  end if;

  select to_jsonb(x) into v_row from (
    select p.id,
           btrim(concat_ws(' ', p.first_name, p.last_name)) as name,
           p.legacy_ref as reference,
           p.status,
           p.school_year,
           (select c.name from public.madrasah_classes c where c.id = v_class) as class,
           p.medical, p.allergies, p.send_detail, p.ehcp_detail,
           p.walk_home_consent,
           (select g.full_name from public.madrasah_guardians g
             where g.household_id = p.household_id
             order by g.is_primary desc nulls last limit 1) as ring_name,
           (select g.phone from public.madrasah_guardians g
             where g.household_id = p.household_id
               and nullif(btrim(g.phone), '') is not null
             order by g.is_primary desc nulls last limit 1) as ring_phone,
           (select count(*) from public.madrasah_attendance a
             where a.pupil_id = p.id
               and a.on_date > current_date - 28
               and a.mark in ('absent','excused'))           as away_last_four_weeks
      from public.madrasah_pupils p
     where p.id = p_id and p.masjid_id = v_masjid
  ) x;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'pupil_opened_by_teacher',
          jsonb_build_object('pupil', p_id, 'class', v_class,
                             'sensitive', (v_row->>'medical') is not null
                                       or (v_row->>'allergies') is not null
                                       or (v_row->>'send_detail') is not null));

  return v_row;
end $$;

revoke all on function public.madrasah_pupil_for_teacher(uuid) from public, anon;
grant execute on function public.madrasah_pupil_for_teacher(uuid) to authenticated;
