--  =====================================================================
--  105 - THE GUARD FINDS ITS OWN TABLES
--  28 September 2026
--  =====================================================================
--
--  madrasah_notice_matches_schema() (081, widened by 085 and 092) checked
--  a hard-coded `watched` array of five table names:
--
--      madrasah_pupils, madrasah_households, madrasah_guardians,
--      madrasah_attendance, madrasah_concerns
--
--  The register rebuild (095-097, 102-104) added TWO new tables that hold
--  facts about a child - madrasah_attendance_log and madrasah_registers -
--  and neither was added to that list. A hard-coded list only ever grows
--  when a person remembers to grow it, and a table holding children's data
--  was invisible to this guard until somebody did. That is the exact
--  failure the guard exists to prevent, one level further up: 080 made
--  the minimisation guard (madrasah_list_minimisation) discover its own
--  list-returning functions from the catalogue rather than being told
--  them, for the same reason.
--
--  So `watched` stops being a list and becomes a query: anything that
--  carries a foreign key to madrasah_pupils is about a child, plus the
--  two family tables (households, guardians) which are about a child's
--  household and are not reachable from madrasah_pupils by a foreign key
--  in that direction.
--
--  THIS DOES NOT REACH EVERY TABLE ABOUT A CHILD. madrasah_registers has
--  no pupil_id - it is about a class on a day, not a named child - so the
--  foreign-key rule does not find it. It stays out of `watched` on purpose
--  (see 106): "any table with a foreign key to madrasah_pupils" is a rule
--  a volunteer can still explain in one sentence. "Any table that concerns
--  children" is not bounded at all, and widening the rule to chase it
--  would trade one hard-coded judgement call for another, harder to see.
--
--  WHAT THIS ACTUALLY FINDS, run against production on 28 September 2026:
--
--      madrasah_attendance, madrasah_attendance_log, madrasah_charges,
--      madrasah_concerns, madrasah_guardians, madrasah_households,
--      madrasah_pupil_classes, madrasah_pupils, madrasah_sibling_suggestions
--
--  Nine tables, not the seven a first guess at "five plus the two new
--  register tables" would suggest - the rule also reaches madrasah_charges
--  and madrasah_pupil_classes, both of which carry a foreign key to
--  madrasah_pupils and neither of which was ever added to the old
--  five-item list by hand.
--
--  AND BECAUSE THE GUARD CHECKS DATA, NOT COLUMNS (081), newly-watched
--  madrasah_attendance and madrasah_attendance_log flag NOTHING today -
--  both are empty; not one mark has been made and not one has been
--  corrected. What actually turns red is five columns nobody was
--  watching, all holding real facts about real children:
--
--      madrasah_pupil_classes.added_at        554 rows
--      madrasah_sibling_suggestions.pupil_a    56 rows
--      madrasah_sibling_suggestions.pupil_b    56 rows
--      madrasah_sibling_suggestions.why        56 rows
--      madrasah_sibling_suggestions.state      56 rows
--
--  THAT RED IS THIS MIGRATION'S DELIVERABLE, NOT A DEFECT IN IT. 106
--  describes those five columns (and the two new register-history tables,
--  ahead of their first row, the way 085 described attendance before the
--  first mark) and turns the guard green again.
--
--  ONE MORE TABLE THIS REACHES, NAMED AND DELIBERATELY LEFT ALONE:
--  madrasah_charges is empty today, so it flags nothing and 106 does not
--  touch it. The first fee charged will turn this guard red on
--  `kind, description, weeks, rate_p, gross_p, discount_p, discount_note,
--  waived_p, waiver_note, net_p, charged_on, created_by` - the guard finds
--  it whether or not anyone remembers, which is the entire point of this
--  migration. Describing fees in a legal notice is the fees spec's own
--  work, not something to guess at here where the fees screens cannot be
--  checked against the words. See docs/GO-LIVE.md section D: it is a
--  blocker for the fees go-live, not for this one.
--
--  Splice-and-refuse, the same technique 081 and 094 used to patch
--  health_check(): read the live definition, replace() the exact old
--  `watched` block, and raise an exception rather than proceed if that
--  exact text is not found - so a moved anchor can never leave the
--  function half-patched.
--  =====================================================================

do $mig$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'madrasah_notice_matches_schema';

  if v_def is null then
    raise exception '105: madrasah_notice_matches_schema() is not there to patch.';
  end if;

  if position('information_schema.key_column_usage' in v_def) > 0
     or position('con.contype = ''f''' in v_def) > 0 then
    raise notice '105: already discovering its tables, leaving it alone.';
    return;
  end if;

  v_new := replace(v_def,
$a$  watched text[] := array[
    'madrasah_pupils', 'madrasah_households', 'madrasah_guardians',
    'madrasah_attendance', 'madrasah_concerns'
  ];$a$,
$b$  --  DISCOVERED, NOT LISTED. See the header of db/105: a literal list
  --  of five tables meant a new table holding a child's data was invisible
  --  to this guard until a person remembered to add it by hand.
  --
  --  Anything that carries a foreign key to madrasah_pupils is about a
  --  child. The two family tables are added by name because they are
  --  about a child's household and are not reached by that foreign key in
  --  that direction. madrasah_registers is deliberately NOT reached here -
  --  it has no pupil_id - and stays out of `watched` on purpose; see 106.
  watched text[] := (
    select array_agg(distinct t) from (
      select 'madrasah_pupils'::text as t
      union select 'madrasah_households'
      union select 'madrasah_guardians'
      union select cl.relname::text
        from pg_constraint con
        join pg_class cl on cl.oid = con.conrelid
        join pg_class rf on rf.oid = con.confrelid
        join pg_namespace ns on ns.oid = cl.relnamespace
       where con.contype = 'f' and ns.nspname = 'public'
         and rf.relname = 'madrasah_pupils'
    ) z);$b$);

  if v_new = v_def then
    raise exception '105: the watched list did not match. NOT changed.';
  end if;

  execute v_new;
  raise notice '105: madrasah_notice_matches_schema now discovers its own tables.';
end $mig$;
