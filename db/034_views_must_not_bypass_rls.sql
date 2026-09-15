-- ===========================================================================
--  034_views_must_not_bypass_rls.sql — take the write privileges off the two
--  public views
--
--  *** APPLIED TO PRODUCTION 15 September 2026. ***
--
--  Found by signing in as a user with NO ROLES AT ALL and trying to break
--  things. Every table refused, exactly as intended — and then:
--
--      delete from public.notices_live;   ->  1 row removed
--
--  ANY SIGNED-IN ACCOUNT COULD DELETE THE MASJID'S NOTICES. The ones on the
--  screens in the prayer hall. At the time this was found there were seven
--  accounts and only three of them had a role, so four people could have
--  wiped the screens by accident or otherwise.
--
--  WHY, PRECISELY — AND IT IS NOT WHAT IT LOOKS LIKE
--  -------------------------------------------------
--  `notices` is a table with RLS ENABLED and ZERO POLICIES. That is the
--  strongest setting there is: no policy means no row passes, so nothing
--  reaches anybody except the table owner and SECURITY DEFINER functions.
--  That part was right.
--
--  `notices_live` is a VIEW on top of it, and a view in PostgreSQL runs with
--  the privileges of ITS OWNER unless `security_invoker = on` is set. The
--  owner is postgres. So the view does not merely select from the table —
--  IT SELECTS AS POSTGRES, AND RLS ON THE TABLE DOES NOT APPLY AT ALL.
--
--  That is deliberate and correct for reading: it is exactly how a locked
--  table gets one small public window (published, unexpired, nine columns,
--  no author, no draft). The website and the prayer-hall screens read through
--  it with the anon key and should.
--
--  The mistake was the GRANT. Both views were given away with what was
--  plainly `grant all` — anon and authenticated each hold SELECT, INSERT,
--  UPDATE, DELETE, TRUNCATE, REFERENCES and TRIGGER. TRUNCATE on a view does
--  nothing and neither does TRIGGER, which is the tell: nobody chose these
--  one at a time.
--
--  And a simple view — no aggregate, no DISTINCT, no GROUP BY — IS
--  AUTOMATICALLY UPDATABLE. So INSERT, UPDATE and DELETE pass straight
--  through to `notices`, still as postgres, still with RLS not applying.
--
--  THE LESSON, AND IT IS A NEW ONE FOR THIS REPOSITORY
--  ---------------------------------------------------
--  This folder has said since 002 that GRANT and RLS are different things and
--  you need both. That is still true, but it is not the whole rule, because
--  here RLS was on, the policies were right, and the data was still reachable:
--
--      A VIEW IS A HOLE IN RLS UNLESS YOU SAY OTHERWISE. Putting a view in
--      front of a protected table turns the protection off for everybody who
--      can reach the view. The view's GRANTS become the only thing left.
--
--  So a view over an RLS table needs a deliberate answer to two questions,
--  written down: does it run as the owner or the caller, and exactly which
--  privileges does each role get. Never `grant all` on a view. Never.
--
--  WHAT THIS CHANGES
--  -----------------
--  The write privileges come off both views. SELECT stays exactly as it is,
--  so the website, the screens and the hall calendar carry on unchanged.
--
--  `hall_availability` was not actually exploitable — it has a GROUP BY, so
--  it is not auto-updatable and the DELETE failed with 55000 rather than
--  doing anything. Its grants are cleaned up anyway, because the next person
--  to edit that view might remove the GROUP BY and would have no way of
--  knowing they had just opened a door. It leaks nothing by reading: one
--  column, `booking_date`, which is the whole point — the public needs to
--  know which days are taken and nothing else about who took them.
--
--  WHAT THIS DELIBERATELY DOES NOT DO
--  ----------------------------------
--  It does not set `security_invoker = on`. That would make both views run as
--  the caller, and since `notices` has no policies and no grants to anon, the
--  website's notices and the prayer-hall screens would go blank. Running as
--  the owner is the correct design here; the grants were the bug.
--
--  It does not touch service_role or postgres. publish_notice() writes to
--  `notices` directly, not through the view, so nothing that legitimately
--  writes a notice is affected.
--
--  NOTE. `notices` and `notices_live` STILL HAVE NO MIGRATION FILE. They were
--  created in the dashboard and exist only in the database, which is why this
--  went unreviewed — there was no file for anybody to read. This one fixes
--  the grants, not that.
-- ===========================================================================

begin;

-- The demonstrated hole. Everything except SELECT comes off.
revoke insert, update, delete, truncate, references, trigger
  on public.notices_live from anon, authenticated;

-- Not exploitable today, cleaned up so it cannot become so quietly.
revoke insert, update, delete, truncate, references, trigger
  on public.hall_availability from anon, authenticated;

-- Said explicitly rather than relied upon, so that reading this file tells
-- you what these roles are supposed to have, and so a future `revoke all`
-- followed by this block leaves the site working.
grant select on public.notices_live      to anon, authenticated;
grant select on public.hall_availability to anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
--  PROVING IT
--
--  Become a signed-in user with no roles and try. Before this file the DELETE
--  removed a row; after it, it must be refused. Rolls itself back either way.
--
--  do $$
--  declare k int;
--  begin
--    execute format('set local request.jwt.claims = %L',
--      json_build_object('sub','11111111-2222-3333-4444-555555555555',
--                        'role','authenticated','aal','aal2')::text);
--    execute 'set local role authenticated';
--    begin
--      execute 'delete from public.notices_live';
--      get diagnostics k = row_count;
--      raise exception 'STILL OPEN: deleted % notice row(s)', k;
--    exception when insufficient_privilege then
--      execute 'reset role';
--      raise exception 'CLOSED: the delete was refused, which is correct';
--    end;
--  end $$;
--
--  Run 15 September 2026: CLOSED.
-- ---------------------------------------------------------------------------
