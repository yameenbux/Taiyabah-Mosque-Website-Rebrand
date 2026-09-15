-- ===========================================================================
--  046_check_newbuild_is_not_public.sql
--  15 September 2026
--
--  `check_newbuild(jsonb)` was executable by `anon`. Every other validator on
--  this project — check_notice, check_course, check_hallhire — is executable
--  by nobody, because none of them is ever called from outside a SECURITY
--  DEFINER function, and those run as the owner regardless of who is calling.
--
--  This is not a hole. The function is IMMUTABLE, reads no table, writes
--  nothing, and returns an English sentence about a shape. Anybody who can
--  call it learns what a valid new-build page looks like, which is visible on
--  the new-build page. The real gate is set_site_content(), which is
--  `authenticated` behind verified_admin(), and that has always been right.
--
--  It is closed anyway, for one reason: an inconsistent grant is a question
--  somebody has to answer again every time they audit the function list, and
--  "it is fine because it is immutable" is a judgement that has to be
--  re-made each time and only has to be got wrong once. Three validators
--  granted to nobody and a fourth granted to anon reads as an oversight even
--  when it is harmless — and this time it WAS an oversight.
--
--  Found by a subagent reading the grant table after 045, not by a test.
-- ===========================================================================

begin;

revoke all on function public.check_newbuild(jsonb) from public, anon, authenticated;

commit;

-- ===========================================================================
--  AFTERWARDS — all four validators should show an empty role list:
--
--    select p.proname,
--           array(select r.rolname from pg_roles r
--                  where has_function_privilege(r.rolname, p.oid, 'execute')
--                    and r.rolname in ('anon','authenticated'))
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public' and p.proname like 'check\_%'
--     order by 1;
--
--  If any of them is executable by anon or authenticated, ask why before
--  assuming it is deliberate.
-- ===========================================================================
