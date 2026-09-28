--  =====================================================================
--  086 - WHAT NEEDS DOING TODAY
--  27 September 2026
--  =====================================================================
--
--  Applied to production in three passes on the same evening (086, 087, 088).
--  This file is the end state, and the header records what the three passes
--  were, because two of them are worth remembering:
--
--    086  built madrasah_today() as if the madrasah portal had no landing
--         page. It has one - portal/index.html - and that page already drew
--         three jobs of its own from madrasah_overview(): DBS, classes with
--         no main teacher, and children in no class. A second landing screen
--         beside it would have been two pages answering the same question and
--         disagreeing within a fortnight. The duplicate screen was deleted.
--
--    087  took those three jobs over, so one function decides what is waiting
--         and one page shows it.
--
--    088  put back something the rewrite had quietly dropped. The old page's
--         DBS line read "21 OF 40 members of staff", not "21 members of
--         staff". The denominator is not decoration: 21 is a number somebody
--         files away, 21 of 40 is half the people who teach here and reads
--         that way at a glance. The portal suite caught it because it
--         asserted the WORDING and not just the count, which is the only
--         reason a check on wording is ever worth having.
--
--         When a rewrite replaces something that works, the test that fails is
--         usually telling you what the old version knew.
--
--  THE LANDING PAGE HAS TO EARN ITS PLACE. A screen that lists the other
--  screens is a menu, and the rail already is one. Somebody opening the
--  portal at five o'clock wants to know what is waiting, not where things
--  live. So every line is a NUMBER, a SENTENCE and a PLACE TO GO, and a line
--  only exists when its number is not nought. An empty list is the correct
--  list on a good evening.
--
--  ORDERED BY WHEN IT MATTERS, NOT BY HOW BIG THE NUMBER IS. Tonight's
--  registers first, because they are the only thing here with a deadline of
--  this evening. Fifty-six sibling pairs is a bigger number than one waiting
--  application and belongs at the bottom: nothing happens if it waits another
--  week, and a family with no answer assumes the answer is no.
--
--  ONE CALL. Eight round trips on a page somebody opens forty times a week is
--  a page that feels broken on the masjid's wifi.
--
--  IT SAYS WHETHER, NOT WHAT. Not one child is named. "Nine children have no
--  date of birth" is a job; their names on the landing page is a screen that
--  sits open on a desk all evening with children's records on it.
--
--  WHAT EACH PERSON SEES DEPENDS ON WHO THEY ARE. A teacher gets the
--  registers, the classes with no main teacher and the children in no class.
--  An administrator gets those and the things only they can act on. Telling a
--  teacher there are four applications waiting is an itch they cannot
--  scratch: they cannot open one.

--  ---------------------------------------------------------------------
--  DBS lives in its own function so the wording lives in ONE place. See 088.
--  ---------------------------------------------------------------------
create or replace function public.madrasah_today_dbs(p_masjid uuid)
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare n int; m int; total int;
begin
  select count(*) filter (where s.dbs_issued is null),
         count(*) filter (where s.dbs_issued is not null
                            and s.dbs_issued < current_date - interval '3 years'),
         count(*)
    into n, m, total
    from public.madrasah_staff s
   where s.masjid_id = p_masjid and s.left_on is null
     and not coalesce(s.dbs_not_required, false);

  if n + m = 0 then return null; end if;

  return jsonb_build_object(
    'key','dbs','count', n + m, 'tone','bad',
    'title', (n + m) || ' of ' || total
             || case when n + m = 1 then ' member of staff needs'
                     else ' members of staff need' end
             || ' a DBS check looked at',
    --  The two cases are said separately: "no check recorded" and "the check
    --  has lapsed" are different conversations with different people, and a
    --  single number hides which one you are having.
    'said', case
      when n > 0 and m > 0 then
        n || ' with no check recorded and ' || m || ' whose check has lapsed.'
      when n > 0 then
        n || case when n = 1 then ' has' else ' have' end
          || ' no check recorded at all. They are working with children and '
          || 'the madrasah cannot show a check was done.'
      else m || case when m = 1 then ' check has' else ' checks have' end
          || ' lapsed. Somebody looked once and has stopped.' end,
    'href','staff/','action','Open the staff list');
end $$;

revoke all on function public.madrasah_today_dbs(uuid) from public, anon;

--  ---------------------------------------------------------------------
create or replace function public.madrasah_today()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp as $$
declare
  v_masjid uuid := public.current_masjid();
  v_admin boolean := public.verified_admin();
  v_items jsonb := '[]'::jsonb;
  v_dbs jsonb;
  n int; m int;
  v_gate jsonb;
begin
  if not public.verified_madrasah() then
    return jsonb_build_object('allowed', false);
  end if;

  --  TONIGHT'S REGISTERS.
  v_gate := public.attendance_permitted();
  if (v_gate ->> 'permitted')::boolean then
    select count(*) into n
      from public.madrasah_classes c
     where c.masjid_id = v_masjid and c.is_active
       and (select count(*) from public.madrasah_pupil_classes pc
              join public.madrasah_pupils p on p.id = pc.pupil_id
             where pc.class_id = c.id and p.left_on is null
               and p.status = 'on_roll') > 0
       and not exists (select 1 from public.madrasah_attendance a
                        where a.class_id = c.id and a.on_date = current_date);
    if n > 0 then
      v_items := v_items || jsonb_build_object(
        'key','registers','count',n,'tone','now',
        'title', n || case when n = 1 then ' class has no register yet'
                           else ' classes have no register yet' end,
        'said','Tonight. A register taken tomorrow is somebody remembering.',
        'href','register/','action','Take the register');
    end if;
  else
    v_items := v_items || jsonb_build_object(
      'key','attendance_gate','count',(v_gate ->> 'outstanding')::int,'tone','bad',
      'title','The register is not open yet',
      'said', v_gate ->> 'why',
      'href','notices/','action','Tell the parents');
  end if;

  --  DBS. A safeguarding matter, and the only thing here that stays on the
  --  list even when nobody has looked at it for a year.
  if v_admin then
    v_dbs := public.madrasah_today_dbs(v_masjid);
    if v_dbs is not null then v_items := v_items || v_dbs; end if;
  end if;

  --  APPLICATIONS WAITING.
  if v_admin then
    select count(*) into n from public.admission_applications
     where masjid_id = v_masjid and status = 'new';
    if n > 0 then
      select count(*) into m from public.admission_applications
       where masjid_id = v_masjid and status = 'new'
         and submitted_at < now() - interval '7 days';
      v_items := v_items || jsonb_build_object(
        'key','applications','count',n,
        'tone', case when m > 0 then 'bad' else 'now' end,
        'title', n || case when n = 1 then ' application is waiting'
                           else ' applications are waiting' end,
        'said', case when m > 0
                then m || case when m = 1 then ' has' else ' have' end
                     || ' been waiting more than a week. A family with no '
                     || 'answer assumes the answer is no.'
                else 'Somebody has applied and is waiting to hear.' end,
        'href','admissions/','action','Open the applications');
    end if;
  end if;

  --  PARENTS WHO HAVE NOT BEEN TOLD. A legal duty with nothing else chasing it.
  if v_admin then
    select count(*) into n
      from public.madrasah_households h
     where h.masjid_id = v_masjid
       and exists (select 1 from public.madrasah_pupils p
                    where p.household_id = h.id and p.left_on is null)
       and not exists (select 1 from public.madrasah_parent_notices pn
                        where pn.household_id = h.id and pn.kind = 'privacy_notice');
    if n > 0 then
      v_items := v_items || jsonb_build_object(
        'key','privacy_notice','count',n,'tone','bad',
        'title', n || case when n = 1 then ' family has not been told'
                           else ' families have not been told' end
                 || ' what the madrasah keeps about their child',
        'said','Articles 13 and 14. Fee reminders will not go to them until '
               || 'they have been told, and the system refuses it rather than '
               || 'relying on anybody remembering.',
        'href','notices/','action','Tell them');
    end if;
  end if;

  --  FAMILIES NOBODY CAN REACH.
  if v_admin then
    select count(*) into n
      from public.madrasah_households h
     where h.masjid_id = v_masjid
       and exists (select 1 from public.madrasah_pupils p
                    where p.household_id = h.id and p.left_on is null)
       and not exists (select 1 from public.madrasah_guardians g
                        where g.household_id = h.id
                          and (nullif(btrim(g.phone), '') is not null
                            or nullif(btrim(g.email), '') is not null));
    if n > 0 then
      v_items := v_items || jsonb_build_object(
        'key','unreachable','count',n,'tone','bad',
        'title', n || case when n = 1 then ' family has' else ' families have' end
                 || ' no way to be reached',
        'said','No telephone number and no email address. If one of their '
               || 'children were unwell this evening there is nobody to ring.',
        'href','families/','action','Open the families');
    end if;
  end if;

  --  A CLASS WITH NO MAIN TEACHER. Taken over from the landing page's own
  --  jobs list; it answers "who was responsible for that room".
  select count(*) into n from public.madrasah_classes c
   where c.masjid_id = v_masjid and c.is_active and c.main_teacher_id is null;
  if n > 0 then
    v_items := v_items || jsonb_build_object(
      'key','main_teacher','count',n,'tone','now',
      'title', n || case when n = 1 then ' class has' else ' classes have' end
               || ' no main teacher',
      'said','The register names the class and the teacher, and that is the '
             || 'record that answers who was where and who was responsible.',
      'href','classes/','action','Open the classes');
  end if;

  --  A CHILD IN NO CLASS. On the roll and on nobody's register.
  select count(*) into n from public.madrasah_pupils p
   where p.masjid_id = v_masjid and p.left_on is null and p.status = 'on_roll'
     and not exists (select 1 from public.madrasah_pupil_classes pc
                      where pc.pupil_id = p.id);
  if n > 0 then
    v_items := v_items || jsonb_build_object(
      'key','no_class','count',n,'tone','now',
      'title', n || case when n = 1 then ' child is' else ' children are' end
               || ' in no class',
      'said','They are on the roll and will not appear on anybody''s register, '
             || 'so nobody would notice if they stopped coming.',
      'href','pupils/','action','Open the roll');
  end if;

  --  SIBLING PAIRS. A quiet afternoon's job, so it is toned quiet and last.
  if v_admin then
    select count(*) into n from public.madrasah_sibling_suggestions
     where masjid_id = v_masjid and state = 'open';
    if n > 0 then
      v_items := v_items || jsonb_build_object(
        'key','siblings','count',n,'tone','quiet',
        'title', n || ' pair' || case when n = 1 then '' else 's' end
                 || ' of children might be brothers and sisters',
        'said','They share a surname and an address. Somebody who knows them '
               || 'should say, and it is not urgent.',
        'href','families/','action','Settle them');
    end if;
  end if;

  --  THE EVENING'S FIGURES. Not a job, so not in the list - a line under it.
  --  A number with nothing to do about it must never sit among the numbers
  --  that have.
  return jsonb_build_object(
    'allowed', true, 'admin', v_admin, 'on_date', current_date,
    'items', v_items,
    'roll', jsonb_build_object(
      'children', (select count(*) from public.madrasah_pupils
                    where masjid_id = v_masjid and left_on is null and status='on_roll'),
      'families', (select count(*) from public.madrasah_households h
                    where h.masjid_id = v_masjid
                      and exists (select 1 from public.madrasah_pupils p
                                   where p.household_id = h.id and p.left_on is null)),
      'classes',  (select count(*) from public.madrasah_classes
                    where masjid_id = v_masjid and is_active),
      'here_tonight', (select count(*) from public.madrasah_attendance a
                        where a.masjid_id = v_masjid and a.on_date = current_date
                          and a.mark in ('present','late')),
      'away_tonight', (select count(*) from public.madrasah_attendance a
                        where a.masjid_id = v_masjid and a.on_date = current_date
                          and a.mark in ('absent','excused'))));
end $$;

revoke all on function public.madrasah_today() from public, anon;
grant execute on function public.madrasah_today() to authenticated;
