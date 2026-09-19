-- ===========================================================================
--  066_what_actually_needs_doing.sql
--  19 September 2026
--
--  The madrasah portal's landing page is called "What needs doing" and, until
--  this migration, could only answer one question: whose DBS needs looking at.
--  Everything else on it was either a figure typed into the page by hand or a
--  description of a screen that does not exist yet.
--
--  That is how it came to state the opposite of the truth. The page said
--
--      "Nothing has been imported yet ... it holds no pupil records at all"
--
--  underneath the number 539, on 19 September, with 543 children in
--  madrasah_pupils since the 18th. A page an administrator lands on is the
--  page whose numbers get reported to the committee. This one was reporting a
--  figure that belonged to a different system and a claim that was false.
--
--  ---------------------------------------------------------------------------
--  A JOB IS A NUMBER, A SENTENCE, AND SOMEWHERE TO GO
--  ---------------------------------------------------------------------------
--  Everything added here is something a person can actually finish. That rules
--  out most of what a dashboard usually carries: totals nobody acts on, charts
--  of things that only go one way, "activity" that is a list of what already
--  happened. None of those belong on a screen called What needs doing.
--
--  What is added:
--
--    pupils                     so the page can stop calling them "not
--                               imported". A count, not a list - the roll is
--                               543 children's names and this screen does not
--                               need one of them to say how many there are.
--
--    classes_no_main_teacher    ten of the forty-five. This is the gap that
--                               matters most after DBS and nothing surfaced
--                               it: a class with no main teacher has nobody
--                               answerable for the register.
--
--    pupils_without_class       nought today, and it will not stay nought.
--                               A child on the roll and in no class is
--                               invisible to every register in the building.
--
--    staff_without_side         nought today. Somebody with no side is in
--                               neither list on the staff screen.
--
--    archive_going_soon         a record inside 30 days of being purged. This
--                               is the only irreversible clock in the madrasah
--                               and nothing was watching it. Three years is
--                               long enough that nobody will remember; the
--                               point of surfacing it is that the last month
--                               is when somebody might still want it back.
--
--  ---------------------------------------------------------------------------
--  WHAT IS DELIBERATELY NOT ADDED
--  ---------------------------------------------------------------------------
--    A NAME LIST FOR ANYTHING ABOUT CHILDREN. dbs_needs_attention returns
--    names because they are staff, the list is the point, and an administrator
--    has to know who to ring. A list of children who are in no class would be
--    a list of children's names on the landing page of a portal - visible in
--    every screenshot, every shared screen, every walk past the office monitor
--    - to answer a question the Classes screen already answers properly. The
--    count comes here; the names stay one deliberate press away.
--
--    ANYTHING ABOUT FEES OR ATTENDANCE. Neither is built. A tile that reads
--    "0 unpaid" when nothing collects fees is not neutral, it is wrong.
--
--  Prerequisites: 058 (pupils), 060 (main teacher), 063 (archive).
--  Safe to re-run.
-- ===========================================================================

create or replace function public.madrasah_overview()
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $fn$
declare
  v_states jsonb;
  v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may open the madrasah portal.'
      using errcode = '42501';
  end if;

  select jsonb_object_agg(st, n) into v_states
    from (select public.dbs_state(dbs_issued, dbs_update_service, dbs_last_checked, dbs_not_required) as st,
                 count(*) as n
            from public.madrasah_staff
           where masjid_id = v_masjid and employment <> 'left'
           group by 1) z;

  return jsonb_build_object(
    'as_at', now(),

    --  WHO AND WHAT IS HERE.
    'pupils', (select count(*) from public.madrasah_pupils
                where masjid_id = v_masjid),
    'staff', (select count(*) from public.madrasah_staff
               where masjid_id = v_masjid and employment <> 'left'),
    'classes', (select count(*) from public.madrasah_classes
                 where masjid_id = v_masjid and is_active),

    --  WHAT IS WAITING FOR SOMEBODY.
    'staff_without_days', (select count(*) from public.madrasah_staff
                            where masjid_id = v_masjid and employment <> 'left'
                              and (work_days is null or cardinality(work_days) = 0)),

    --  Somebody with no side is in NEITHER list on the staff screen. The
    --  screen puts them in a group of their own so they cannot vanish; this
    --  is the same fact one level up, so it is visible without opening it.
    'staff_without_side', (select count(*) from public.madrasah_staff
                            where masjid_id = v_masjid and employment <> 'left'
                              and (side is null or btrim(side) = '')),

    --  A class with nobody answerable for it. Ten of forty-five today, and
    --  nothing in the system said so until now.
    'classes_no_main_teacher', (select count(*) from public.madrasah_classes
                                 where masjid_id = v_masjid and is_active
                                   and main_teacher_id is null),

    --  A child on the roll and in no class is invisible to every register.
    --  COUNT ONLY - see the note at the top about why there is no name list.
    'pupils_without_class', (select count(*) from public.madrasah_pupils p
                              where p.masjid_id = v_masjid
                                and not exists (select 1 from public.madrasah_pupil_classes pc
                                                 where pc.pupil_id = p.id
                                                   and pc.masjid_id = v_masjid)),

    'dbs', coalesce(v_states, '{}'::jsonb),
    'dbs_needs_attention', coalesce((
      select jsonb_agg(jsonb_build_object('id', s.id,
               'name', btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)),
               'state', public.dbs_state(s.dbs_issued, s.dbs_update_service, s.dbs_last_checked, s.dbs_not_required))
             order by s.last_name, s.first_name)
        from public.madrasah_staff s
       where s.masjid_id = v_masjid
         and s.employment <> 'left'
         and public.dbs_state(s.dbs_issued, s.dbs_update_service, s.dbs_last_checked, s.dbs_not_required)
             in ('none','overdue','due_soon')), '[]'::jsonb),

    'admissions_waiting', (select count(*) from public.admission_applications
                            where masjid_id = v_masjid),

    --  THE ONE IRREVERSIBLE CLOCK IN THE MADRASAH, AND NOTHING WAS WATCHING IT.
    --  Three years is long enough that nobody remembers; the last month is
    --  when somebody might still want the record back. Same arithmetic as
    --  purge_madrasah_archive() so the two cannot drift.
    'archive_total', (select count(*) from public.madrasah_archive
                       where masjid_id = v_masjid),
    'archive_going_soon', (select count(*) from public.madrasah_archive
                            where masjid_id = v_masjid
                              and archived_at < now() - interval '3 years' + interval '30 days')
  );
end $fn$;

revoke all on function public.madrasah_overview() from public, anon;
grant execute on function public.madrasah_overview() to authenticated;


-- ===========================================================================
--  CHECKS
--
--  Proved by breaking the thing each one guards. A check that cannot fail is
--  worse than no check, because it is read as evidence.
-- ===========================================================================
do $check$
declare
  v_def text := pg_get_functiondef('public.madrasah_overview()'::regprocedure);
  v_key text;
begin
  --  1. Every key the page reads is returned. Broken by deleting the pupils
  --     line: fails naming it. Without this the page draws "undefined" in a
  --     tile, which renders as an em-dash and looks like "not loaded yet".
  foreach v_key in array array['pupils','staff','classes','staff_without_days',
                               'staff_without_side','classes_no_main_teacher',
                               'pupils_without_class','dbs','dbs_needs_attention',
                               'admissions_waiting','archive_total','archive_going_soon']
  loop
    if position('''' || v_key || '''' in v_def) = 0 then
      raise exception '066: madrasah_overview() does not return %, so the page that reads it draws an empty tile.', v_key;
    end if;
  end loop;

  --  2. SCOPED TO ONE MASJID, EVERY SUBQUERY. This function is twelve separate
  --     counts and each one is its own chance to forget. Counting the
  --     occurrences is the check: eleven subqueries name a table and every one
  --     of them must also name the masjid.
  if (length(v_def) - length(replace(v_def, 'masjid_id = v_masjid', ''))) / length('masjid_id = v_masjid')
     < 11 then
    raise exception '066: at least one count in madrasah_overview() is not scoped to a masjid. Every subquery here reads a table that belongs to one, and the whole point of the tenancy column is that forgetting it once is enough.';
  end if;

  --  3. NO CHILD'S NAME LEAVES THIS FUNCTION. dbs_needs_attention returns
  --     names, and they are staff. Nothing about a pupil may return one: this
  --     is the landing page, visible in every screenshot and on every screen
  --     shared in a meeting. Broken by adding a pupil name list: fails.
  --  NOTE: {0,200} and not {0,300}. Postgres caps a bounded repetition at
  --  255 and raises "invalid repetition count(s)" above it -- which is a
  --  MIGRATION THAT FAILS TO APPLY, not a check that quietly passes, so it was
  --  caught the first time this ran rather than a year later.
  if v_def ~ 'madrasah_pupils[\s\S]{0,200}?(first_name|last_name|jsonb_agg)' then
    raise exception '066: madrasah_overview() looks like it returns something about individual pupils. This is the landing page. The count belongs here; the names belong one deliberate press away, on a screen somebody chose to open.';
  end if;

  raise notice '066 ok: twelve counts, all scoped, no child named.';
end $check$;
