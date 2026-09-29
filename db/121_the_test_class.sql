--  =====================================================================
--  121 - THE TEST CHILD GETS A CLASS OF ITS OWN
--  29 September 2026
--  =====================================================================
--
--  db/120 put the invented test child on "the active class with the fewest
--  children", which was a real class with a real main teacher. That teacher's
--  register therefore listed a child nobody had ever enrolled. It was written
--  down as a price ("the price of an existing active class") and it was the
--  wrong price: an invented child should never be on a real teacher's list.
--
--  WHAT THIS DOES
--    1. Creates one active class, "ZZ TEST CLASS - not a real class", mixed,
--       sorted to the bottom of every list, and makes the existing test
--       teacher its main teacher. The test teacher is the account
--       42a0f447-f2b6-4a31-86c3-8bc2bddaad1b, used for testing throughout
--       this project; its staff record is named as a test.
--    2. Moves the test child onto it (a change to madrasah_pupil_classes,
--       which is not madrasah_pupils, so a failed CHECK cannot print a
--       child's row).
--
--  WHAT IT GIVES BACK
--    A complete test loop for every later slice: the test TEACHER signs in and
--    marks the test child; the test PARENT signs in and reads the mark.
--
--  WHAT IT CHANGES ON THE LIVE FIGURES
--    * the real class the child was on goes back to the roll it had before
--      db/120 (asserted below, as a count, in the migration itself);
--    * classes 48 -> 49;
--    * registers_missing_count() will include this class on any evening a
--      register is due, until it is taken. The test teacher is the only person
--      who can take it. Ignore that item, or take the register as the test
--      teacher - or remove the whole test family (below).
--
--  ASSERTED BY COUNT, NEVER BY NAME. The assertions at the bottom select
--  count(*) and booleans only. Nothing here prints a child, a class or a
--  member of staff.
--
--  REMOVING THE TEST FAMILY NOW MEANS REMOVING THIS CLASS TOO. Run the
--  statement at the bottom of db/120 first (it removes the child and the
--  household), then this one. It is keyed on the exact name AND requires the
--  class to have no roll, so it cannot remove a real class.
--
--    delete from public.madrasah_classes
--     where name = 'ZZ TEST CLASS - not a real class'
--       and not exists (select 1 from public.madrasah_pupil_classes pc
--                        where pc.class_id = madrasah_classes.id);
--
--  It leaves the test teacher's own staff record and login alone: those
--  pre-date this file and are used by other work.
--  =====================================================================
do $mig$
declare
  v_masjid uuid; v_hh uuid; v_child uuid; v_old uuid; v_new uuid; v_staff uuid;
  v_old_before int; v_old_after int; v_n int;
  c_name constant text := 'ZZ TEST CLASS - not a real class';
begin
  select h.id, h.masjid_id into v_hh, v_masjid
    from public.madrasah_households h
   where h.reference = 'MF-999999' and h.name = 'Zzzfamily test household';
  if v_hh is null then
    raise exception '121: the test family is not there. Nothing done.';
  end if;

  if exists (select 1 from public.madrasah_classes c
              where c.masjid_id = v_masjid and c.name = c_name) then
    raise notice '121: the test class is already there. Nothing done.';
    return;
  end if;

  select p.id into v_child from public.madrasah_pupils p
   where p.household_id = v_hh
   order by p.created_at, p.id limit 1;
  if v_child is null then
    raise exception '121: the test household has no child. Nothing done.';
  end if;

  select s.id into v_staff from public.madrasah_staff s
   where s.user_id = '42a0f447-f2b6-4a31-86c3-8bc2bddaad1b'
     and s.masjid_id = v_masjid and s.left_on is null;
  if v_staff is null then
    raise exception '121: the test teacher has no active staff record. Nothing done.';
  end if;

  select pc.class_id into v_old from public.madrasah_pupil_classes pc
   where pc.pupil_id = v_child order by pc.added_at limit 1;
  select count(*) into v_old_before from public.madrasah_pupil_classes pc
   where pc.class_id = v_old;

  insert into public.madrasah_classes
    (masjid_id, name, section, is_active, sort_order, main_teacher_id)
  values (v_masjid, c_name, 'mixed', true, 9999, v_staff)
  returning id into v_new;

  update public.madrasah_pupil_classes
     set class_id = v_new
   where pupil_id = v_child and masjid_id = v_masjid;

  --  -------------------------------------------------------------------
  --  ASSERTIONS. Counts and booleans; any failure aborts the migration.
  --  -------------------------------------------------------------------
  select count(*) into v_old_after from public.madrasah_pupil_classes pc
   where pc.class_id = v_old;
  if v_old_after <> v_old_before - 1 then
    raise exception '121: the real class did not go back to its earlier roll (% -> %).',
      v_old_before, v_old_after;
  end if;

  --  The test child is on exactly one class, and it is the test class.
  select count(*) into v_n from public.madrasah_pupil_classes pc
   where pc.pupil_id = v_child;
  if v_n <> 1 then raise exception '121: the test child is on % classes, not 1.', v_n; end if;
  if not exists (select 1 from public.madrasah_pupil_classes pc
                  where pc.pupil_id = v_child and pc.class_id = v_new) then
    raise exception '121: the test child is not on the test class.';
  end if;

  --  No class list that any REAL teacher reads mentions the test child: a
  --  class the child is on, whose main teacher is somebody else, or which
  --  has any other member of staff linked to it.
  select count(*) into v_n
    from public.madrasah_pupil_classes pc
    join public.madrasah_classes c on c.id = pc.class_id
   where pc.pupil_id = v_child
     and (c.main_teacher_id is distinct from v_staff
          or exists (select 1 from public.madrasah_staff_classes sc
                      where sc.class_id = c.id and sc.staff_id <> v_staff));
  if v_n <> 0 then
    raise exception '121: % class(es) a real teacher reads still list the test child.', v_n;
  end if;

  --  ...and the test class has nobody on it but the test child.
  select count(*) into v_n from public.madrasah_pupil_classes pc
   where pc.class_id = v_new;
  if v_n <> 1 then raise exception '121: the test class has % children, not 1.', v_n; end if;
end $mig$;
