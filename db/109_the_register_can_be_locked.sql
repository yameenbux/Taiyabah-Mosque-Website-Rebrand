-- ===========================================================================
--  109 - THE DIGEST STOPS BLAMING TEACHERS FOR A LOCK THE OFFICE HOLDS
--  28 September 2026
-- ===========================================================================
--  Review of db/108 (Task 7). Spec approved, no Critical, no Important -
--  three fixes, and this is the one that matters.
--
--  attendance_permitted() (db/084) returns permitted:false right now, live:
--  330 families, 0 told. mark_register() (084) refuses EVERY mark until
--  every family on the roll has been told the register is starting - the
--  privacy notice promises it, and nothing has been marked because nobody
--  can mark anything yet. madrasah_attendance is empty.
--
--  db/108's registers_missed key does not know that. It re-derives
--  register_due() and asks whether each cell was submitted - and every one
--  of them was not, because none of them COULD have been, so next Monday it
--  would have emailed the office "220 registers missed, by class" for
--  registers no teacher was ever permitted to take. That reads as forty-four
--  teachers failing at their job. The actual outstanding action is the
--  office's: tell the 330 families. A report that says the wrong thing
--  confidently is the same fault CLAUDE.md already names for a safeguarding
--  screen nobody reads - the machinery being wrong is worse than saying
--  nothing.
--
--  THIS DOES NOT CALL attendance_permitted() - same reason db/108 does not
--  call register_due() or registers_missing(): attendance_permitted() reads
--  current_masjid() itself, which is NULL under cron because auth.uid() is
--  NULL. It re-derives attendance_permitted()'s exact two counts, scoped by
--  (select m from me), READ STRAIGHT OFF ITS SOURCE (084) rather than from
--  memory, so the two can never disagree about what "told" means:
--    v_families - masjid_id = this masjid, a pupil on the roll (left_on is
--      null) somewhere in the household.
--    v_told - distinct households with an attendance_notice sent, same
--      "somebody on the roll" filter.
--    not permitted <=> not (v_families > 0 and v_told >= v_families) -
--      the exact boolean 084 computes, only negated, word for word.
--
--  THE SHAPE CHANGES, NOT JUST THE NUMBER. registers_missed now carries
--  `open` - false means the register is locked and count/by_class are
--  deliberately 0/[] (nothing behind them could ever have been marked, so
--  nothing is reported); true means read count/by_class exactly as db/108
--  already did. messages.ts (deployed below, BEFORE this file, same
--  ordering db/108 established) treats `open` missing as true, so the
--  half-state between deploying this file's renderer and applying this
--  migration renders exactly as it already does - the same safety property
--  db/108's header proved, extended one step.
--
--  v_total (send_weekly_digest) STILL SENDS, ARITHMETIC CHOSEN ON PURPOSE.
--  When the register is locked, 'count' is 0, so db/108's own splice alone
--  would compute v_total = 0 and send NOTHING even with 330 families
--  untold - the exact silence Task 7 exists to end, now for the item at the
--  top of docs/GO-LIVE.md's legal section instead of a missed mark. This
--  file adds exactly ONE when the register is locked, not 330: adding the
--  families-untold count to a handful of outstanding items would produce a
--  headline nobody believes (a masjid with one refund due does not have
--  "331 things outstanding").
-- ===========================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'outstanding_summary';

  if position('families_untold' in v_def) > 0 then
    raise notice '109: already there.';
    return;
  end if;

  --  Splice 1: v_families and v_told, read straight off attendance_permitted()
  --  (084) and scoped by (select m from me) instead of current_masjid() -
  --  see this file's header for why that substitution is required under
  --  cron and why the two counts must not be reimplemented from memory.
  v_new := replace(v_def,
$a$public.current_masjid() end as m),
       --  ADDED BY 108.$a$,
$b$public.current_masjid() end as m),
       --  ADDED BY 109. attendance_permitted()'s own two counts (084),
       --  scoped by (select m from me) instead of current_masjid() for the
       --  same cron-NULL reason as 108's CTEs below - see this file's
       --  header and the Task 7 report addendum.
       v_families as (
         select count(*) as n from public.madrasah_households h
          where h.masjid_id = (select m from me)
            and exists (select 1 from public.madrasah_pupils p
                         where p.household_id = h.id and p.left_on is null)),
       v_told as (
         select count(distinct n.household_id) as n
           from public.madrasah_parent_notices n
           join public.madrasah_households h on h.id = n.household_id
          where n.masjid_id = (select m from me)
            and n.kind = 'attendance_notice'
            and exists (select 1 from public.madrasah_pupils p
                         where p.household_id = h.id and p.left_on is null)),
       --  ADDED BY 108.$b$);

  if v_new = v_def then
    raise exception '109: could not find the me/108 anchor. NOT changed.';
  end if;
  v_def := v_new;

  --  Splice 2: the key itself becomes conditional. Not permitted (the exact
  --  negation of 084's own formula) reports the lock and how many families
  --  are untold, and reports NOTHING about missed registers - nothing
  --  behind v_missed could have been taken while the lock is on. Permitted
  --  reports exactly what 108 already computed.
  v_new := replace(v_def,
$a$    'registers_missed',
      jsonb_build_object(
        'count', (select count(*) from v_missed),
        'by_class',
          coalesce((select jsonb_agg(
                             jsonb_build_object('class', x.name, 'missed', x.missed)
                             order by x.missed desc, x.name)
                      from v_missed_by_class x),
                    '[]'::jsonb)),$a$,
$b$    --  ADDED BY 109. Locked means nothing behind v_missed could ever have
    --  been marked - mark_register() (084) refuses every mark until every
    --  family has been told. Reporting a missed-register figure in that
    --  state blames a teacher for a lock the office holds; see this file's
    --  header.
    'registers_missed',
      case when not ((select n from v_families) > 0
                      and (select n from v_told) >= (select n from v_families))
        then jsonb_build_object(
               'open', false,
               'families_untold',
                 greatest((select n from v_families) - (select n from v_told), 0),
               'count', 0,
               'by_class', '[]'::jsonb)
        else jsonb_build_object(
               'open', true,
               'families_untold', 0,
               'count', (select count(*) from v_missed),
               'by_class',
                 coalesce((select jsonb_agg(
                                    jsonb_build_object('class', x.name, 'missed', x.missed)
                                    order by x.missed desc, x.name)
                             from v_missed_by_class x),
                           '[]'::jsonb))
      end,$b$);

  if v_new = v_def then
    raise exception '109: could not find the registers_missed value. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  Grants restated exactly as 108 restated them, for the same reason: a
--  migration replayed standalone against a database that never carried them
--  forward should not leave this function wide open to anon.
revoke all on function public.outstanding_summary(uuid) from public, anon;
grant execute on function public.outstanding_summary(uuid) to authenticated;

-- ---------------------------------------------------------------------------
--  send_weekly_digest() must still send when the register is locked, or 330
--  untold families sits silent the same way 220 missed registers would have
--  before 108 - see this file's header for why the arithmetic adds ONE, not
--  the families-untold count.
-- ---------------------------------------------------------------------------
do $mig2$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_weekly_digest';

  if position('ADDED BY 109' in v_def) > 0 then
    raise notice '109: send_weekly_digest already counts it.';
    return;
  end if;

  v_new := replace(v_def,
$a$             + coalesce((s->'registers_missed'->>'count')::int, 0);$a$,
$b$             + coalesce((s->'registers_missed'->>'count')::int, 0)
             --  ADDED BY 109. When the register is locked, 'count' above is
             --  deliberately 0 (see 109's header), so this alone would send
             --  NOTHING even with 330 families untold - the same silence
             --  108 exists to end, now for B3. Adding ONE, not the
             --  families-untold figure, keeps the subject line sensible -
             --  see 109's header. coalesce(..., true): a digest read before
             --  this key carries 'open' at all defaults to "open", i.e.
             --  adds nothing, matching how it already behaved.
             + case when coalesce((s->'registers_missed'->>'open')::boolean, true)
                    then 0 else 1 end;$b$);

  if v_new = v_def then
    raise exception '109: could not find v_total''s registers_missed term. NOT changed.';
  end if;

  execute v_new;
end $mig2$;

--  send_weekly_digest() stays owner-and-pg_cron only, restated for the same
--  reason as above.
revoke all on function public.send_weekly_digest(boolean) from public;
revoke all on function public.send_weekly_digest(boolean) from anon, authenticated;
