-- ===========================================================================
--  108 - THE MONDAY EMAIL COUNTS REGISTERS
--  28 September 2026
-- ===========================================================================
--  Task 7 of the register rebuild. registers_missing() and
--  my_registers_outstanding() (db/095, 103, 104) tell the office and the
--  teacher ON SCREEN. Nobody who does not open the right screen on the right
--  evening is told at all - a class could go three weeks unmarked in
--  silence. This is the other channel: the Monday email.
--
--  FOUR PIECES, NOT ONE. A 'registers_missed' key that outstanding_summary()
--  grows and nothing else reaches nobody:
--    1. outstanding_summary() gains the section, BY CLASS - a bare count
--       says something is wrong and not where to look. See the design spec
--       (2026-09-28-the-register-rebuilt-design.md): "registers due last
--       week and not submitted, by class".
--    2. send_weekly_digest()'s v_total must count it, or a week with forty
--       missed registers and nothing else outstanding sends NO EMAIL AT ALL
--       - exactly the silence this task exists to end. (v_total already
--       lives in send_weekly_digest(), not here; that function is edited
--       separately below, in the same migration.)
--    3. messages.ts must render it, or the key reaches nobody.
--    4. notify must be REDEPLOYED with that change, or none of the above
--       does anything until the next unrelated deploy.
--
--  ORDER MATTERS. messages.ts was deployed to notify (v14 -> v15) BEFORE
--  this file is applied - see this task's report for the deploy log. The
--  dangerous half-state is new database, old renderer: v_total counts the
--  missed registers so an email SENDS, and the old renderer draws it with no
--  registers row and the subject "this week at the masjid" - a FALSE
--  ALL-CLEAR, worse than the silence it replaces, because somebody read it
--  and was reassured. Deploying the renderer first means that state cannot
--  arise: a new renderer finding the field absent (it is optional in the
--  TypeScript) renders exactly as before - proved by messages_test.ts's
--  "registers_missed ABSENT renders nothing" test, green before this file
--  was ever applied.
--
--  WHY THIS DOES NOT CALL register_due() OR registers_missing() - THE
--  BRIEF'S OWN SQL WOULD HAVE BEEN SILENTLY WRONG UNDER THE EXACT PATH IT
--  HAD TO RUN UNDER.
--  register_due() computes v_masjid := public.current_masjid() ITSELF,
--  never from any parameter. current_masjid() reads auth.uid() and the JWT
--  claims. pg_cron holds neither - send_weekly_digest() runs with
--  auth.uid() NULL, which is exactly why outstanding_summary() takes
--  p_masjid and its `me` CTE falls back to it when auth.uid() is null.
--  Calling register_due() (or registers_missing(), which calls it) from
--  inside outstanding_summary() under cron would silently see v_masjid =
--  NULL throughout - no academic year, no register-days setting and no
--  closure ever matches a NULL masjid_id, so 'due' would read false for
--  every class on every date, and 'registers_missed' would read zero every
--  single Monday regardless of what was actually missed. Proved, not
--  assumed - see this task's report for register_due() called with
--  auth.uid() null (a simulated cron context) against a class and date
--  known to be due when read as the office, answering false.
--
--  So this migration re-derives "due and not submitted" directly, scoped by
--  (select m from me) instead of current_masjid() - the same duplication
--  db/019's own header already accepted for the rest of outstanding_summary
--  (nikah_requests, hall_bookings), now extended to registers. The two
--  copies are proved equal in this task's report: registers_missing() and
--  this key, over the same seven days, read as the office - same totals AND
--  same per-class breakdown.
--
--  THE SAME HOIST AS db/104, DONE AS A SINGLE SET-BASED QUERY INSTEAD OF
--  REPEATED FUNCTION CALLS. register_due()'s logic is two independent
--  halves, read straight off its source (db/095): four checks that mention
--  v_masjid and p_date and NEVER p_class (register_days is set, the date
--  sits in the current academic year, the day of week is a register day, no
--  closure covers it), then one final check that mentions p_class and NEVER
--  p_date (the class is active and has someone on its roll). db/104 hoisted
--  this for registers_missing() by calling register_due() once per date and
--  once per class instead of once per (date, class) cell. Re-deriving the
--  logic directly here achieves the same shape for free, without calling
--  register_due() at all: v_due_dates and v_due_classes below are each
--  computed once, independently, and crossed only at the end.
--
--  A CLASS NAME IS NOT A PERSON. The breakdown is by class, never by
--  teacher, never by pupil - CLAUDE.md's line, applied to the one new thing
--  this migration adds. messages.ts (deployed above) only ever reads
--  `.class` and `.missed` off each entry.
-- ===========================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'outstanding_summary';

  if position('registers_missed' in v_def) > 0 then
    raise notice '108: already there.';
    return;
  end if;

  --  Splice 1: the new CTEs, inserted right after the `me` CTE and before
  --  the main SELECT. Every one of them is scoped by (select m from me) -
  --  never current_masjid() directly - so this still answers correctly when
  --  auth.uid() is null under cron. See the header above for why that
  --  matters and db/104 for why the date half and the class half are kept
  --  apart until the very last CTE.
  v_new := replace(v_def,
$a$public.current_masjid() end as m)
  select jsonb_build_object($a$,
$b$public.current_masjid() end as m),
       --  ADDED BY 108. register_due()'s own two independent halves
       --  (db/104's comment explains why they are independent), re-derived
       --  here scoped by (select m from me) rather than by calling
       --  register_due() itself - which reads current_masjid(), not
       --  p_masjid, and would silently answer false-for-everything under
       --  cron. See this file's header and the Task 7 report.
       v_reg_days as (
         --  register_due()'s "nobody has said which evenings run yet"
         --  check. An empty array makes every date below fail the
         --  "= any(...)" test - same effect as register_due()'s early
         --  return, without needing a separate branch for it.
         select coalesce(
                  (select array(select jsonb_array_elements_text(value))
                     from public.madrasah_settings
                    where masjid_id = (select m from me)
                      and key = 'register_days'),
                  '{}'::text[]) as d),
       v_reg_year as (
         --  register_due()'s "that date is outside the academic year"
         --  check. Zero or one row; zero means nothing below can match.
         select y.starts_on, y.ends_on from public.madrasah_years y
          where y.masjid_id = (select m from me) and y.is_current),
       --  THE DATE HALF ONLY - never mentions a class. Last week: the seven
       --  days before today, the same window the design spec asks for.
       --  v_reg_days is CROSS JOINed (always exactly one row - coalesce()
       --  guarantees it) rather than read with `= any(select d from ...)`,
       --  because ANY(subquery) compares against each ROW the subquery
       --  returns, and a single row of type text[] is not the same thing as
       --  an array to test membership in - Postgres refuses "text = text[]"
       --  rather than guess. `= any(rd.d)` on the joined column is the
       --  ordinary array form, the same one register_due() itself uses.
       v_due_dates as (
         select g::date as on_date
           from generate_series((select d from today) - 7,
                                 (select d from today) - 1,
                                 interval '1 day') g
           cross join v_reg_days rd
          where lower(to_char(g, 'Dy')) = any (rd.d)
            and exists (select 1 from v_reg_year y
                         where g::date between y.starts_on and y.ends_on)
            and not exists (select 1 from public.madrasah_closures c
                              where c.masjid_id = (select m from me)
                                and g::date between c.starts_on and c.ends_on)),
       --  THE CLASS HALF ONLY - never mentions a date. register_due()'s
       --  final check, word for word: active, and somebody on its roll.
       v_due_classes as (
         select c.id, c.name from public.madrasah_classes c
          where c.masjid_id = (select m from me) and c.is_active
            and exists (select 1 from public.madrasah_pupil_classes pc
                          join public.madrasah_pupils p on p.id = pc.pupil_id
                         where pc.class_id = c.id and p.left_on is null
                           and p.status = 'on_roll')),
       --  Crossed exactly once - the same conjunction register_due() would
       --  compute per cell - filtered by "not already submitted", the same
       --  test registers_missing() applies.
       v_missed as (
         select cls.id as class_id, cls.name, dd.on_date
           from v_due_classes cls cross join v_due_dates dd
          where not exists (select 1 from public.madrasah_registers rg
                             where rg.class_id = cls.id and rg.on_date = dd.on_date
                               and rg.state = 'submitted')),
       v_missed_by_class as (
         select class_id, name, count(*) as missed
           from v_missed group by class_id, name)
  select jsonb_build_object($b$);

  if v_new = v_def then
    raise exception '108: could not find the CTE anchor. NOT changed.';
  end if;
  v_def := v_new;

  --  Splice 2: the key itself, ahead of the existing generated_at anchor -
  --  a SECTION (count and by-class), never a bare scalar. The office needs
  --  to know WHICH classes, not only that something is wrong.
  v_new := replace(v_def,
$a$    'generated_at', now()$a$,
$b$    --  ADDED BY 108. A register NOT taken was invisible to everybody: no
    --  trigger, nothing in the notify function, nothing here. A class
    --  could go three weeks unmarked in silence.
    'registers_missed',
      jsonb_build_object(
        'count', (select count(*) from v_missed),
        'by_class',
          coalesce((select jsonb_agg(
                             jsonb_build_object('class', x.name, 'missed', x.missed)
                             order by x.missed desc, x.name)
                      from v_missed_by_class x),
                    '[]'::jsonb)),
    'generated_at', now()$b$);

  if v_new = v_def then
    raise exception '108: could not find generated_at. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  Grants restated exactly as db/019 established them for this function.
--  CREATE OR REPLACE preserves them as-is, but db/104's own reminder
--  applies here too: a migration replayed standalone against a database
--  that never carried them forward should not leave this function wide
--  open to anon.
revoke all on function public.outstanding_summary(uuid) from public, anon;
grant execute on function public.outstanding_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------------
--  send_weekly_digest() MUST COUNT registers_missed IN v_total, or a week
--  with forty missed registers and nothing else outstanding sends NO EMAIL
--  AT ALL - exactly the silence this task exists to end. This is the second
--  of the four pieces the header above lists; see it for the other three.
-- ---------------------------------------------------------------------------
do $mig2$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_weekly_digest';

  if position('registers_missed' in v_def) > 0 then
    raise notice '108: send_weekly_digest already counts it.';
    return;
  end if;

  v_new := replace(v_def,
$a$v_total := (s->>'new_nikah')::int
             + (s->>'refunds_due')::int
             + (s->>'balances_due')::int;$a$,
$b$v_total := (s->>'new_nikah')::int
             + (s->>'refunds_due')::int
             + (s->>'balances_due')::int
             --  ADDED BY 108. Without this, a week where every class in the
             --  masjid went unmarked and nothing else was outstanding would
             --  compute v_total = 0 and send NOTHING - the exact silence
             --  Task 7 exists to end. coalesce(...,0): a digest read before
             --  outstanding_summary() carried this key (there is no such
             --  window in production, since this file's own splice above
             --  runs first in the same migration, but a defensive default
             --  costs nothing) must not raise on a missing key.
             + coalesce((s->'registers_missed'->>'count')::int, 0);$b$);

  if v_new = v_def then
    raise exception '108: could not find v_total in send_weekly_digest. NOT changed.';
  end if;

  execute v_new;
end $mig2$;

--  send_weekly_digest() stays owner-and-pg_cron only. CREATE OR REPLACE
--  preserves the revokes db/019 set, but they are restated here too, for
--  the same reason as above - and so nobody reading this file has to go
--  back to db/019 to know this function is not for authenticated at all.
revoke all on function public.send_weekly_digest(boolean) from public;
revoke all on function public.send_weekly_digest(boolean) from anon, authenticated;
