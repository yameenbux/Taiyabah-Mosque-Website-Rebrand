--  =====================================================================
--  089 - WHO LOOKED AT WHAT
--  27 September 2026
--  =====================================================================
--
--  The published privacy notice tells parents, under "How we keep it safe":
--
--      "Who looked at what, and when, is recorded."
--
--  It was two thirds true. Seven functions that a PERSON has to be signed in
--  to call wrote their audit row as
--
--      insert into public.admin_audit (masjid_id, action, detail)
--
--  with no actor, and no name in the detail either. The worst of them is
--  madrasah_pupil_one(), the audit of somebody opening a child's record - the
--  one action in this system that most needs a name against it. It recorded
--  that a record containing a medical note had been opened, and could not say
--  by whom.
--
--  HOW IT WAS MISSED. A count said 2468 of 2485 audit rows had no actor, and
--  that figure was carried for days as an outstanding worry. It is not a
--  fault: 2288 of them are hall holds purged by a cron job at ten past three
--  in the morning, and most of the rest are anonymous form submissions and
--  webhook callbacks. NOBODY DID THOSE, so there is nobody to record.
--
--  The right question was never "how many rows have no actor" but "is there
--  an action a PERSON performs that does not record them" - and asked that
--  way the answer was seven, hidden because none of them was inconsistent:
--  they had never recorded an actor at all, so no action in the table was
--  ever mixed.
--
--  A figure that lumps the cron job in with the person opening a medical note
--  hides the only case that matters. The alarming part of that number was its
--  denominator.
--
--  PROVED AFTERWARDS against a child who really does have a medical note, in
--  a rolled-back transaction:
--
--      action=pupil_opened  records who=t  right person=t  sensitive=true
--
--  SPLICED, NOT REWRITTEN. Seven functions restated in full here would be
--  seven copies that silently revert whatever else has changed in them. Each
--  is read, patched and re-executed, and a patch that changes nothing raises
--  rather than reporting success.

do $fix$
declare
  fn text;
  src text;
  patched text;
  n_changed int := 0;
  --  Every function a person must be signed in to call that wrote an audit
  --  row with no actor. Purges and webhooks are deliberately NOT here: a row
  --  with no actor is the correct record of something nobody did.
  people_driven text[] := array[
    'madrasah_pupil_one',          -- opening a child's record. The important one.
    'save_madrasah_pupil_details', -- amending one
    'settle_sibling_suggestion',   -- joining two families
    'clear_unreferenced_pupils',
    'mark_gift_aid_claimed',
    'record_cash_deposit',         -- the one path where a PERSON asserts money exists
    'set_volunteer_status'
  ];
begin
  foreach fn in array people_driven loop
    select pg_get_functiondef(p.oid) into src
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = fn
     limit 1;
    if src is null then
      raise exception 'public.%() does not exist. Nothing changed.', fn;
    end if;

    if src ~ 'admin_audit\s*\(\s*masjid_id\s*,\s*actor' then
      raise notice '%() already records who; left alone.', fn;
      continue;
    end if;

    --  The column list gains `actor`...
    patched := regexp_replace(
      src,
      '(insert into public\.admin_audit\s*\(\s*masjid_id\s*),',
      '\1, actor,', 'g');
    --  ...and the value list gains auth.uid() in the same position, whether
    --  the row is written with VALUES or with SELECT.
    patched := regexp_replace(
      patched,
      '(insert into public\.admin_audit\s*\(\s*masjid_id, actor,[^)]*\)\s*)values\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,',
      '\1values (\2, auth.uid(),', 'g');
    patched := regexp_replace(
      patched,
      '(insert into public\.admin_audit\s*\(\s*masjid_id, actor,[^)]*\)\s*)select\s+([A-Za-z_][A-Za-z0-9_]*)\s*,',
      '\1select \2, auth.uid(),', 'g');

    if patched = src then
      raise exception 'The audit row in public.%() is not the shape this '
                      'migration expects. NOTHING was changed, so no function '
                      'is rewritten wrongly.', fn;
    end if;
    if patched !~ 'auth\.uid\(\)' then
      raise exception 'public.%() was changed but auth.uid() did not go in. '
                      'Refusing.', fn;
    end if;

    execute patched;
    n_changed := n_changed + 1;
  end loop;

  raise notice '% function(s) now record who did it.', n_changed;
end $fix$;
