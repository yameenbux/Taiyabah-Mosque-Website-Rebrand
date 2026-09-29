--  =====================================================================
--  120 - THE TEST FAMILY
--  29 September 2026
--  =====================================================================
--
--  One invented household, one invented child on an existing active class,
--  one guardian with a login - so that the parents' portal can be built and
--  looked at from a parent's side of the glass.
--
--  IT IS IN ITS OWN FILE SO IT CAN BE REMOVED ON ITS OWN. The removal
--  statement is at the bottom of this file. Nothing in db/119 depends on it.
--
--  NAMES ARE INVENTED and were checked against the live database first (a
--  count, nothing else) before being chosen: no pupil, guardian, household or
--  member of staff matched. The household reference is MF-999999 - the
--  reference shape allows six digits and the real ones stop at MF-0330, so it
--  cannot be mistaken for, or collide with, a family. The login sits on
--  example.test, a domain that cannot receive mail.
--
--  THE PASSWORD IS NOT IN THIS FILE, AND IS NOT IN THE MIGRATION HISTORY.
--  This file creates the login with a random password nobody has seen. The
--  password the developer signs in with is set by a separate statement run
--  outside the migration (the statement is at the bottom), so it exists
--  only in the return message that went to the person who asked for it.
--
--  WHAT THIS DOES TO THE LIVE FIGURES - all three are real and are counted
--  like any other, because hiding them would make the figures lie the other
--  way:
--    * the roll                          552 -> 553
--    * families with a child on the roll 330 -> 331
--    * attendance_permitted() outstanding 330 -> 331 (nobody has been told
--      about the register, and the test family has not been told either)
--    * the test child sits on one real class's roll. That class's teacher
--      will see one extra child, named Testchild, on their register. That is
--      the price of "an existing active class". The class chosen is the one
--      with the FEWEST children on the roll, so the effect is smallest.
--
--  ONE THING THAT WILL BITE LATER, and is here so it is read: the register
--  cannot open until attendance_permitted() is true, which needs EVERY family
--  with a child on the roll to have been told. The test family counts. When
--  the masjid has told all 330 real families the gate will still read
--  "1 family has not been told" until this family is removed (or told).
--  Remove it BEFORE the notice goes out, or the register will not open and
--  nothing on the screen will explain why.
--
--  The test guardian has NO email address on the guardian row, so nothing
--  that mails guardians (fee reminders, the register notice) will try to send
--  to it. The login's own address lives on the auth account only.
do $mig$
declare
  v_admin uuid; v_masjid uuid; v_class uuid; v_hh uuid; v_g uuid; v_p uuid;
  v_uid uuid; v_n int;
begin
  if exists (select 1 from public.madrasah_households h where h.reference = 'MF-999999') then
    raise notice '120: the test family is already there. Nothing done.';
    return;
  end if;

  select r.user_id, r.masjid_id into v_admin, v_masjid
    from public.user_roles r where r.role = 'admin' order by r.user_id limit 1;
  if v_admin is null then
    raise exception '120: there is no administrator to create the login as.';
  end if;

  select c.id into v_class from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active
   order by (select count(*) from public.madrasah_pupil_classes pc where pc.class_id = c.id),
            c.sort_order, c.id
   limit 1;
  if v_class is null then
    raise exception '120: there is no active class to put the test child on.';
  end if;

  --  create_parent_login() checks verified_admin(), which needs a session. A
  --  migration has none, so it borrows an administrator's for this
  --  transaction only, exactly as db/093 had to.
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_admin, 'role', 'authenticated', 'aal', 'aal2',
    'app_metadata', jsonb_build_object('masjid_id', v_masjid))::text, true);

  insert into public.madrasah_households (masjid_id, reference, name, note)
  values (v_masjid, 'MF-999999', 'Zzzfamily test household',
          'INVENTED TEST FAMILY for the parents'' portal (db/120). Not a real family. Remove it: see the end of db/120_the_test_family.sql.')
  returning id into v_hh;

  insert into public.madrasah_guardians (masjid_id, household_id, full_name, is_primary)
  values (v_masjid, v_hh, 'Testparent Zzzfamily', true)
  returning id into v_g;

  --  madrasah_pupils: wrapped so a CHECK that refuses this row can only
  --  ever let the sqlstate out (CLAUDE.md).
  begin
    insert into public.madrasah_pupils
      (masjid_id, household_id, first_name, last_name, joined_on)
    values (v_masjid, v_hh, 'Testchild', 'Zzzfamily', current_date)
    returning id into v_p;
    insert into public.madrasah_pupil_classes (masjid_id, pupil_id, class_id)
    values (v_masjid, v_p, v_class);
  exception when others then
    raise exception 'refused: %', sqlstate;
  end;

  --  A random password nobody has seen. See the header.
  perform public.create_parent_login(
    v_g, 'test.parent@example.test',
    replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));

  perform set_config('request.jwt.claims', '', true);

  --  The read-back, again, from outside the function that wrote it: a
  --  login that cannot be scanned by the auth service is the db/093 bug.
  select u.id into v_uid from auth.users u where u.email = 'test.parent@example.test';
  select count(*) into v_n from auth.users u
   where u.id = v_uid
     and (u.confirmation_token is null or u.recovery_token is null
       or u.email_change is null or u.email_change_token_new is null
       or u.email_change_token_current is null or u.phone_change is null
       or u.phone_change_token is null or u.reauthentication_token is null);
  if v_uid is null or v_n <> 0 then
    raise exception '120: the test parent''s account is missing or has a NULL token column.';
  end if;

  --  ...and that it reaches its own child and nothing else.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_uid, 'role', 'authenticated', 'aal', 'aal1')::text, true);
  if (select count(*) from public.my_parent_children()) <> 1
     or not public.is_my_child(v_p)
     or public.verified_madrasah() or public.verified_admin() then
    raise exception '120: the test parent does not reach exactly the test child, or reaches staff.';
  end if;
  perform set_config('request.jwt.claims', '', true);
end $mig$;

--  ---------------------------------------------------------------------
--  1. THE PASSWORD. Run once, OUTSIDE the migration, by whoever is handing
--     the account over (this is a statement, not a migration, so the value
--     never lands in supabase_migrations). Replace <new password>; 12
--     characters or more.
--
--       update auth.users
--          set encrypted_password = extensions.crypt('<new password>', extensions.gen_salt('bf')),
--              updated_at = now()
--        where email = 'test.parent@example.test';
--
--  2. REMOVING THE WHOLE TEST FAMILY. One statement; run it as postgres. It
--     deletes, in order: the child (which takes the class link, any
--     attendance marks and their history rows with it), the household
--     (which takes the guardian, the login row, any parent notices and fee
--     reminders), and the auth account (which takes its identity, profile
--     and sessions). It is keyed on the reference AND the name, so it
--     cannot touch a real family. It leaves the admin_audit rows that record
--     the login being created: an audit trail is not tidied away.
--
--       do $$
--       declare v_hh uuid; v_users uuid[];
--       begin
--         select h.id into v_hh from public.madrasah_households h
--          where h.reference = 'MF-999999' and h.name = 'Zzzfamily test household';
--         if v_hh is null then raise notice 'no test family'; return; end if;
--         select array_agg(l.user_id) into v_users
--           from public.madrasah_parent_logins l
--           join public.madrasah_guardians g on g.id = l.guardian_id
--          where g.household_id = v_hh;
--         begin
--           delete from public.madrasah_pupils where household_id = v_hh;
--         exception when others then raise exception 'refused: %', sqlstate; end;
--         delete from public.madrasah_households where id = v_hh;
--         delete from auth.users where id = any(coalesce(v_users, '{}'));
--       end $$;
--
--     It will FAIL, and change nothing, if the test family has been given a
--     fee charge or payment (madrasah_charges / madrasah_payments restrict
--     the household), or if the test parent has caused a row that restricts
--     the auth account (app_notifications.actor). Delete those rows first.
--     After it runs the roll reads 552, families 330 and outstanding 330.
--  ---------------------------------------------------------------------
