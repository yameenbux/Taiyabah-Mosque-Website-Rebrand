--  =====================================================================
--  130 — THE DAILY LOG KNOWS A MACHINE WHEN IT SEES ONE
--  29 September 2026
--  =====================================================================
--
--  The Daily Log says, in its own subtitle: "What people did, and what the
--  public sent in. Automatic jobs are counted at the bottom rather than
--  listed." portals/app.js says why, and it is right:
--
--      "On the real database 120 of 130 audit rows were one job clearing
--       expired holds; a feed showing them all is 92% noise, and a log that
--       wastes attention once is never opened again."
--
--  The sorting is done by audit_kind(), which calls a row 'auto' when its
--  action ends in _purged or _repaired, or begins with digest. Every other
--  machine action falls through to 'staff' — and 'staff' is the bucket the
--  log LISTS, with "the office" printed beside it as though a person had
--  done it.
--
--  So bmcc_sweep_not_configured, written hourly by pg_cron, and health_fail,
--  written by the nightly check, were both being shown to the committee as
--  things somebody did. On 29 September the top of the Daily Log was eleven
--  consecutive machine rows and one real one — a cancelled invitation, the
--  only human act on the screen, sitting alone above ten hours of cron.
--
--  129 stopped the sweep writing when it has nothing to do. This is the
--  other half: even when a machine SHOULD write a row, that row is not
--  something a person did, and the log should count it rather than list it.
--
--  CLAUDE.md already records this exact lesson, learned the hard way:
--  "2,468 of 2,485 audit rows have no actor" was carried as a security
--  worry for days before anybody asked the right question. 2,288 were a
--  cron job purging hall holds. NOBODY DID THOSE. The right question was
--  whether there is an action a PERSON performs that does not record them.
--
--  =====================================================================
--  AND A HAND-KEPT LIST IS WHY THIS DRIFTED — worth saying out loud
--  =====================================================================
--
--  audit_kind() is a list of patterns somebody has to remember to extend,
--  and it is now the third guard on this project to fail that way: the
--  privacy notice guard watched five hard-coded tables until db/105 taught
--  it to discover its own, and the notices screen carried a hand-copied
--  version number that was wrong for four releases until verify_structure's
--  check 9. Every new machine action since this function was written has
--  quietly been filed as human.
--
--  THE DURABLE FIX IS NOT THIS ONE. A machine row is identifiable without
--  any list at all: admin_audit.actor is NULL, because nobody was signed in.
--  Classifying on that would need no maintenance and could not drift.
--  It is not done here because audit_kind(text) is IMMUTABLE and takes only
--  the action — it cannot see the actor — so the change belongs in
--  admin_dashboard(), which is the live Admin Centre, and that deserves its
--  own migration and its own review rather than riding along in a bundle
--  that was assembled to fix a noisy log. Named in docs/GO-LIVE.md so it is
--  somebody's job rather than a good intention in a comment.
--  =====================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'audit_kind';

  if v_def is null then
    raise exception '130: audit_kind() is not there to patch.';
  end if;

  if position('bmcc_sweep' in v_def) > 0 then
    raise notice '130: already knows the sweep and the health check.';
    return;
  end if;

  --  READ-PATCH-REFUSE. Refuses rather than half-patching if the shape moved.
  v_new := replace(v_def,
$a$      or p_action like '%_repaired'      then 'auto'$a$,
$b$      or p_action like '%_repaired'
      --  ADDED BY 130. Written by pg_cron, with no actor. Neither is a
      --  thing a person did, and both were being listed as though the
      --  office had done them — hourly, in the case of the sweep.
      or p_action like 'bmcc_sweep%'
      or p_action like 'health_%'         then 'auto'$b$);

  if v_new = v_def then
    raise exception '130: the auto branch did not match. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  audit_kind() is IMMUTABLE and reads nothing; it is safe for anybody who
--  can already see the dashboard. Grants restated per 102's ruling I4.
revoke all on function public.audit_kind(text) from public, anon;
grant execute on function public.audit_kind(text) to authenticated, postgres;

--  =====================================================================
--  PROOF, exactly as it ran. Before: 91 sweep rows and 10 health_fail rows
--  were classed 'staff' and listed. After: both are 'auto' and counted.
--
--    select public.audit_kind('bmcc_sweep_not_configured') as sweep,
--           public.audit_kind('health_fail')               as health,
--           public.audit_kind('register_taken')            as a_person,
--           public.audit_kind('hall_holds_purged')         as still_auto,
--           public.audit_kind('nikah_request')             as still_public;
--
--    Expected, and what it printed:
--      sweep=auto  health=auto  a_person=staff  still_auto=auto
--      still_public=public
--
--  The last three matter as much as the first two: a migration that made
--  the log quieter by filing a teacher's register under 'auto' would have
--  been worse than the noise it removed.
--  =====================================================================
