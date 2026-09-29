-- ===========================================================================
--  111 - TODAY COUNTS REGISTERS, ONLY WHEN THE OFFICE IS FREE TO
--  28 September 2026
-- ===========================================================================
--  Task 10 of the register rebuild. registers_missing() (db/095, hoisted by
--  db/104) can already answer "which registers were never taken", but only
--  somebody who opens /register/ and picks a class and a date ever asks it.
--  Today is the screen every office user opens first; this puts the answer
--  there, as a new 'registers_missed' item.
--
--  THE BRIEF NAMED THIS db/101. 102-110 are already applied to production;
--  this is 111.
--
--  RULING, 28 SEPTEMBER, OVERRIDING THE BRIEF'S OWN WORDING: THIS ITEM MUST
--  NOT APPEAR WHILE MARKING IS FORBIDDEN.
--
--  attendance_permitted() (db/084) reads false live, right now: 330
--  families, 0 told. mark_register() (084) refuses EVERY mark until every
--  family on the roll has been told - the privacy notice promises it - so
--  NOTHING IN madrasah_attendance HAS EVER BEEN WRITTEN, because nothing
--  could be. Today already carries that fact, at the very top of this same
--  function, as the 'attendance_gate' item db/086 added: "The register is
--  not open yet ... 330 families have not been told yet."
--
--  Proved, not assumed, before this file touched anything: with the gate
--  read the way it is applied below, madrasah_today() run live as the
--  office (impersonated by setting request.jwt.claims to a real
--  administrator's own id for one session, aal2, no INSERT/UPDATE/DELETE
--  anywhere) returns permitted:false, families:330, told:0, and eight items
--  with no 'registers_missed' key among them - proof this file's own
--  ADDED-BY comment describes a real, current state rather than a
--  hypothetical one. And the guard is not vacuous: registers_missing()
--  itself, called the same way, answers count 484 (the same figure db/104's
--  own header cites for this exact function). A migration that gated an
--  item nobody would otherwise see would prove nothing; this one gates an
--  item that would otherwise say "484 registers were not taken" - a real,
--  large, wrong number, for registers no teacher was ever permitted to
--  take.
--
--  A 'registers_missed' item drawn BESIDE 'attendance_gate' in that state
--  would report a CONSEQUENCE of the lock as though it were a second,
--  separate problem, and would read as 44 teachers failing at their jobs
--  for evenings on which the system itself refused them. So this item is
--  gated on THE SAME v_gate the function already computed for
--  'attendance_gate' - reused, not recomputed a second time, so the two can
--  never disagree about whether marking is permitted - and when permitted
--  is false, THE ITEM IS NOT EMITTED AT ALL. The families item is the
--  action; this would only be a second way of saying the same thing.
--
--  db/109 FIXED THE SAME FAULT IN THE MONDAY DIGEST, and this item's
--  wording agrees with it rather than inventing a second way of saying the
--  same thing: db/109's registers_missed carries `open:false` and reports
--  nothing about missed registers while the register is locked, for
--  exactly this reason - "a register not taken because the office is doing
--  its job is not a fact about the 44 teachers who could not have taken
--  it." The shapes differ because the two screens differ (Today's items are
--  each pushed only when non-empty; the digest's key is always present so
--  messages.ts has something to read) but the RULE is the same one, applied
--  twice: say nothing rather than double-count a fact already on screen.
--
--  THE WINDOW IS NAMED IN WORDS - "in the last fortnight" - because
--  db/108's Monday digest counts the last SEVEN days and this counts the
--  last FOURTEEN (registers_missing()'s own default window, db/095/104).
--  Both are defensible read alone; an office reading "practical this week's
--  digest said one number and Today says a different one" without a reason
--  would conclude the system is broken. Naming the window is the fix -
--  the two are visibly answers to different questions, not disagreeing
--  answers to the same one.
--
--  THE HOISTED SHAPE, FOLLOWED RATHER THAN RE-DERIVED. db/104's own header
--  measured registers_missing()'s pre-fix cost at ~920-990ms (register_due()
--  called once per (date, class) cell - up to 660 times) and hoisted it to
--  one call per date plus one call per class (~15 + ~44). db/108 had to
--  RE-DERIVE that same hoist inline, in SQL, because send_weekly_digest()
--  runs under pg_cron with auth.uid() null, and registers_missing() (like
--  attendance_permitted()) reads current_masjid() itself, which is null
--  under cron. madrasah_today() is NOT in that position - it runs for a
--  signed-in office user with a real auth.uid(), the same as every other
--  call registers_missing() already answers correctly from (the register
--  screen itself, and my_registers_outstanding() for a teacher). So this
--  migration calls registers_missing() DIRECTLY, with its own default
--  14-day window (p_from default current_date - 14), rather than
--  re-deriving its logic a second time the way db/108 had to. That is the
--  hoisted shape db/104 and db/108 establish, applied at the one call site
--  that is actually allowed to use it: reuse the fast function, do not
--  loop, and do not duplicate its logic where duplication is not required.
--
--  ONLY registers_missing()'S OWN 'count' FIELD IS EVER READ. That
--  function's job is to put classes, dates and a teacher's name in front of
--  the office (CLAUDE.md's rule about register_history() and
--  registers_missing() themselves) - its 'rows' are never touched here,
--  only the bare integer its own header already names as the point of
--  wrapping a function like this.
-- ===========================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'madrasah_today';

  if position('registers_missed' in v_def) > 0 then
    raise notice '111: already there.';
    return;
  end if;

  --  Anchor: immediately after the DBS block, before "APPLICATIONS
  --  WAITING" - exactly where the brief asked for it. pg_get_functiondef()
  --  strips this function's own inline comments (true of the live
  --  definition already, before this migration ever ran - checked, not
  --  assumed), so the anchor below is the bare code, not the commented
  --  source in db/086.
  v_new := replace(v_def,
$a$  if v_admin then
    v_dbs := public.madrasah_today_dbs(v_masjid);
    if v_dbs is not null then v_items := v_items || v_dbs; end if;
  end if;

  if v_admin then
    select count(*) into n from public.admission_applications$a$,
$b$  if v_admin then
    v_dbs := public.madrasah_today_dbs(v_masjid);
    if v_dbs is not null then v_items := v_items || v_dbs; end if;
  end if;

  --  ADDED BY 111. Registers never taken, in the last fortnight - gated on
  --  the SAME v_gate this function already computed above for the
  --  attendance_gate item, reused rather than recomputed, so the two can
  --  never disagree about whether marking is permitted. WHILE MARKING IS
  --  NOT PERMITTED THIS ITEM IS NOT EMITTED AT ALL - see this file's
  --  header for why, and for the live proof that the count it would
  --  otherwise show (484, right now) is real rather than vacuous.
  if v_admin and (v_gate ->> 'permitted')::boolean then
    n := coalesce((public.registers_missing() ->> 'count')::int, 0);
    if n > 0 then
      v_items := v_items || jsonb_build_object(
        'key','registers_missed','count',n,'tone','bad',
        'title', n || ' register' || case when n = 1 then ' was' else 's were' end
                 || ' not taken',
        'said','In the last fortnight: a register not taken is not a register '
               || 'taken late. Nobody was recorded as being in that room.',
        'href','register/','action','Open the registers');
    end if;
  end if;

  if v_admin then
    select count(*) into n from public.admission_applications$b$);

  if v_new = v_def then
    raise exception '111: could not find the DBS-block anchor. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  Grants restated exactly as db/086 established them. CREATE OR REPLACE
--  preserves existing grants, but db/104's I4 is the standing reminder of
--  what happens when a migration is replayed standalone against a database
--  that never carried them forward - so they are restated here too.
revoke all on function public.madrasah_today() from public, anon;
grant execute on function public.madrasah_today() to authenticated;
