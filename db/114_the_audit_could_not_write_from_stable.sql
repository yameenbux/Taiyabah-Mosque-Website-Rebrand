-- ===========================================================================
--  114 - THE AUDIT INSERT COULD NOT RUN FROM A STABLE FUNCTION
--  28 September 2026
-- ===========================================================================
--  Review of db/113 (Task 11), found immediately, by actually calling the
--  function rather than only reading the diff. db/113 spliced an INSERT
--  into register_history() and left it declared STABLE - carried forward,
--  unexamined, from db/103/104, both of which had no reason to touch it
--  because neither of them wrote anything.
--
--  Postgres refuses this outright, not silently:
--
--      ERROR: 0A000: INSERT is not allowed in a non-volatile function
--
--  Proved reachable, before this file touched anything, in a rolled-back
--  transaction as the office (a real admin id, aal2, no INSERT/UPDATE/DELETE
--  of my own anywhere - the error came from calling the function itself):
--  register_history() on a real class and today's date raised exactly that
--  error rather than returning rows. Every "office reads a class's history"
--  call was broken from the moment db/113 was applied until this file.
--
--  db/113 is applied and is the record; it is not edited - the same rule
--  db/094 set correcting db/093, and db/104 set correcting db/103. This
--  corrects it forward.
--
--  THE FIX IS THE DECLARATION, NOTHING ELSE. STABLE means "reads the
--  database, never writes it, and can be assumed to answer identically
--  within one statement" - which stopped being true for this function the
--  moment db/113 gave it an admin_audit row to write. madrasah_pupil_one()
--  and submit_register(), db/113's own precedent for what an audited,
--  people-driven function looks like, are both declared VOLATILE
--  (checked directly against pg_proc.provolatile, not assumed) - this
--  function now belongs in the same category. The body is untouched:
--  same guards, same masjid scope, same audit row, same rows returned.
-- ===========================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'register_history';

  if v_def is null then
    raise exception '114: public.register_history() does not exist. Nothing changed.';
  end if;

  if position(chr(10) || ' STABLE SECURITY DEFINER' in v_def) = 0 then
    raise notice '114: register_history() is not declared STABLE any more; nothing to fix.';
  else
    v_new := replace(v_def,
      chr(10) || ' STABLE SECURITY DEFINER',
      chr(10) || ' SECURITY DEFINER');

    if v_new = v_def then
      raise exception '114: could not find the STABLE anchor in '
                      'register_history(). NOT changed.';
    end if;
    if position('insert into public.admin_audit' in v_new) = 0 then
      raise exception '114: db/113''s audit insert is not present in the '
                      'definition being replaced. Refusing to drop it.';
    end if;
    execute v_new;
    raise notice '114: register_history() is now VOLATILE and can write its audit row.';
  end if;
end $mig$;

--  Grants restated exactly as db/103/104/113 established them.
revoke all on function public.register_history(uuid, date) from public, anon;
grant execute on function public.register_history(uuid, date) to authenticated;
