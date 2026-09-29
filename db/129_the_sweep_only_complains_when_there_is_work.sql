--  =====================================================================
--  129 — THE CERTIFICATE SWEEP ONLY COMPLAINS WHEN IT HAS WORK IT CANNOT DO
--  29 September 2026
--  =====================================================================
--
--  sweep_bmcc_certificates() runs hourly. When storage_key is not set it
--  writes bmcc_sweep_not_configured to admin_audit and returns. That was
--  deliberate and 060's header says why: nothing is deleted from the queue
--  when storage cannot be reached, the files stay, the queue stays, and the
--  log says why — "which is the failure everybody wants, rather than an
--  empty queue and a full bucket."
--
--  That reasoning is right and this migration does not touch it. What it
--  missed is the case where there is NOTHING IN THE QUEUE.
--
--  Measured on 29 September: storage_key has never been set, the queue holds
--  ZERO rows, and the sweep had written 91 rows since 25 September — one an
--  hour, every hour, announcing that it could not do work that did not
--  exist. Yameen found it by looking at the Daily Log, which is the screen
--  whose entire job is showing what PEOPLE did. Ninety-one machine rows in
--  four days is how a log stops being read, and a log nobody reads is worse
--  than no log, because everyone believes somebody is watching it.
--
--  This is the same lesson as the two deliberate reds in health_check():
--  a warning that is always on is not a warning. The system already knows
--  this about itself in three other places; it did not know it here.
--
--  So: no queue, no complaint. A certificate queued while the key is still
--  missing starts the hourly row again on the very next run, which is the
--  moment it begins to matter and not before. Nothing is swept, nothing is
--  deleted, and the setting is still missing either way — the only thing
--  that changes is whether the madrasah is told about it while it is
--  harmless.
--
--  SETTING THE KEY IS STILL A JOB FOR A PERSON. storage_key is the
--  service_role key. It is not in this file, is not in the repository, and
--  must never be. See 060's header for the one statement that sets it.
--  =====================================================================

do $mig$
declare v_def text; v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'sweep_bmcc_certificates';

  if v_def is null then
    raise exception '129: sweep_bmcc_certificates() is not there to patch.';
  end if;

  if position('129' in v_def) > 0 then
    raise notice '129: already quiet on an empty queue.';
    return;
  end if;

  --  READ-PATCH-REFUSE. The anchor is 060's whole not-configured block. If
  --  it has moved, this refuses rather than writing half a function.
  v_new := replace(v_def,
$a$  if v_url is null or v_key is null then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'bmcc_sweep_not_configured',$a$,
$b$  if v_url is null or v_key is null then
    --  129: SILENT WHEN THERE IS NOTHING TO SWEEP. Not configured AND an
    --  empty queue is not a fault anybody can act on, and saying so every
    --  hour buried the Daily Log under 91 rows in four days. The moment a
    --  certificate is queued this speaks again, on the next run.
    if not exists (select 1 from public.bmcc_certificate_purge_queue) then
      return 0;
    end if;
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'bmcc_sweep_not_configured',$b$);

  if v_new = v_def then
    raise exception '129: the not-configured block did not match. NOT changed.';
  end if;

  execute v_new;
end $mig$;

--  The grant pair, restated. 102's ruling I4: a migration that omits it is
--  the defect, because replayed standalone it would leave the function on
--  whatever ACL happened to be there.
revoke all on function public.sweep_bmcc_certificates() from public, anon;
grant execute on function public.sweep_bmcc_certificates() to postgres;

--  =====================================================================
--  PROOF, exactly as it last ran. The queue is empty, so the first call
--  must write nothing; a throwaway row must make it speak again; and
--  removing that row must return it to silence. Rolled back either way.
--  =====================================================================
--
--    do $$
--    declare a int; b int; c int; m uuid;
--    begin
--      select count(*) into a from admin_audit where action='bmcc_sweep_not_configured';
--      perform public.sweep_bmcc_certificates();
--      select count(*) into b from admin_audit where action='bmcc_sweep_not_configured';
--      select id into m from public.masjids order by created_at limit 1;
--      insert into public.bmcc_certificate_purge_queue (path, masjid_id)
--           values ('zz/throwaway.pdf', m);   --  masjid_id is NOT NULL; the
--                                            --  first attempt without it failed
--      perform public.sweep_bmcc_certificates();
--      select count(*) into c from admin_audit where action='bmcc_sweep_not_configured';
--      raise exception 'empty queue added % row(s); with one queued added % row(s)',
--                      b - a, c - b;
--    end $$;
--
--    Expected, and what it printed:
--      empty queue added 0 row(s); with one queued added 1 row(s)
--  =====================================================================
