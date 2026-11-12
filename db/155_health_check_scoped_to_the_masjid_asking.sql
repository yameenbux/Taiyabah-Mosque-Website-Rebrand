-- ===========================================================================
--  155 — health_check() answers for the masjid that asked, not the platform
--
--  Taiyabah Masjid · 12 November 2026
--
--  WHAT WENT WRONG. health/app.js is explicit about who reads this screen:
--  "Taiyabah Masjid — system health, read by a person on demand." The
--  function behind it was never that. notify_configured, two_admins_each,
--  prayer_times_published, public_surface and compatibility_shims all loop
--  over every row in public.masjids and report an aggregate count — "2
--  masjid(s) with fewer than two administrators," "3 masjids" — regardless
--  of which masjid's own admin pressed "Check now." Taiyabah's office saw
--  tiles turn red over two rows nobody at Taiyabah had ever heard of:
--  audit-tmp-a and audit-tmp-b, two empty, non-live fixtures left behind by
--  an audit three weeks ago and never dropped.
--
--  THOSE TWO ROWS ARE NOT DELETED HERE. masjids_to_purge() (db/140) hands
--  every masjid, live or not, to every nightly retention job with no
--  is_live filter, so three weeks of "0 purged" runs against two empty
--  fixtures have left thousands of real, if pointless, admin_audit rows
--  foreign-keyed to them — deleting the masjids outright means deleting
--  that history too, which is a separate decision from today's complaint
--  and is being left for the office to make deliberately, not as a side
--  effect of a wording fix.
--
--  Once a real second masjid exists on this platform, the same wording would
--  surface that masjid's own admin-count and notify-settings problems on
--  Taiyabah's screen, and vice versa — a minor cross-tenant leak that every
--  other function in this codebase was already careful to avoid.
--
--  THE FIX LEANS ON current_masjid(), NOT A NEW CONCEPT. Every other
--  masjid-scoped function already asks current_masjid() who it is being
--  asked by (db/140). health_check() is also called with no session at all
--  — health_watch() (db/149), the cron job with nobody signed in, runs it
--  every fifteen minutes to watch the whole platform. current_masjid()
--  already returns null for that caller, so v_scope is null there and these
--  checks fall back to exactly the platform-wide behaviour this file
--  replaces — the cron watch is unaffected. It is only a signed-in masjid
--  admin, for whom current_masjid() resolves to one row, who now gets
--  numbers about that one masjid.
--
--  COMPATIBILITY_SHIMS DOESN'T SCOPE — IT'S DROPPED INSTEAD, FOR A SCOPED
--  CALLER. "How many masjids now exist" has no honest per-masjid phrasing;
--  it is a question about this codebase's own assumptions, not about
--  Taiyabah's data, and its own status banner already says "Needs a
--  developer, not the office" the moment anything fails. A masjid's own
--  admin gets a screen that never mentions it. The platform-wide caller
--  (v_scope is null — the cron watch, or platform support with no masjid
--  selected) still sees it exactly as before.
-- ===========================================================================

begin;

create or replace function public.health_check()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_checks  jsonb := '[]'::jsonb;
  v_failing text[] := '{}';
  v_ok      boolean;
  v_detail  text;
  v_n       int;
  v_row     record;
  v_jrow    jsonb;
  v_scope   uuid := public.current_masjid();
  v_slug    text;
begin
  --  db/122: internal. The scheduler and the database's owner have no
  --  session; anybody with one must be a verified administrator.
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'That is for the masjid''s administrators.'
      using errcode = '42501';
  end if;

  if v_scope is not null then
    select slug into v_slug from public.masjids where id = v_scope;
  end if;

  begin
    select count(*) into v_n from cron.job_run_details
     where start_time > now() - interval '24 hours' and status <> 'succeeded';
    v_ok := (v_n = 0);
    v_detail := v_n || ' failed scheduled run(s) in the last 24 hours';
  exception when others then
    v_ok := false; v_detail := 'could not read cron history: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','scheduled_jobs_succeeding','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'scheduled_jobs_succeeding'); end if;

  begin
    select count(*) into v_n from cron.job where not active;
    v_ok := (v_n = 0);
    v_detail := v_n || ' scheduled job(s) disabled';
  exception when others then
    v_ok := false; v_detail := 'could not read cron jobs: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','scheduled_jobs_enabled','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'scheduled_jobs_enabled'); end if;

  begin
    select count(*) into v_n from cron.job_run_details d join cron.job j on j.jobid=d.jobid
     where j.command like '%purge_expired_holds%' and d.start_time > now() - interval '35 minutes';
    v_ok := (v_n > 0);
    v_detail := case when v_ok then 'the ten-minute job ran within the last 35 minutes'
                     else 'the ten-minute job has not run for over 35 minutes - the scheduler may be stalled' end;
  exception when others then
    v_ok := false; v_detail := 'could not read cron history: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','scheduler_alive','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'scheduler_alive'); end if;

  --  NOTIFY_CONFIGURED, TWO_ADMINS_EACH, PRAYER_TIMES_PUBLISHED: scoped to
  --  v_scope when a specific masjid is asking, otherwise every masjid - see
  --  header. mj.id = v_scope is a no-op filter when v_scope is null because
  --  the OR short-circuits it to true for every row.
  select count(*) into v_n from public.masjids mj
   where (v_scope is null or mj.id = v_scope)
     and mj.is_live and (select count(*) from public.app_settings s
                          where s.masjid_id = mj.id
                            and s.key in ('notify_url','notify_key','notify_secret')) < 3;
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','notify_configured','ok',v_ok,
    'detail', case when v_scope is not null
      then (case when v_ok then 'notify settings are complete' else 'notify settings are missing - forms would reach nobody' end)
      else v_n || ' live masjid(s) missing notify settings - their forms would reach nobody' end);
  if not v_ok then v_failing := array_append(v_failing, 'notify_configured'); end if;

  select count(*) into v_n from public.masjids mj
   where (v_scope is null or mj.id = v_scope)
     and (select count(*) from public.user_roles r
           where r.masjid_id = mj.id and r.role = 'admin') < 2;
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','two_admins_each','ok',v_ok,
    'detail', case when v_scope is not null
      then (case when v_ok then 'two or more administrators' else 'fewer than two administrators' end)
      else v_n || ' masjid(s) with fewer than two administrators' end);
  if not v_ok then v_failing := array_append(v_failing, 'two_admins_each'); end if;

  select count(*) into v_n from public.masjids mj
   where (v_scope is null or mj.id = v_scope)
     and mj.is_live and not exists (
     select 1 from public.prayer_years y
      where y.masjid_id = mj.id
        and y.year = extract(year from (now() at time zone 'Europe/London'))::int
        and y.published);
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','prayer_times_published','ok',v_ok,
    'detail', case when v_scope is not null
      then (case when v_ok then 'this year''s timetable is published' else 'no published timetable for this year' end)
      else v_n || ' live masjid(s) with no published timetable for this year' end);
  if not v_ok then v_failing := array_append(v_failing, 'prayer_times_published'); end if;

  v_ok := true;
  v_detail := case when v_scope is not null
    then coalesce(v_slug, 'this masjid') || ' answers on all four public calls'
    else 'every live masjid answers on all four public calls' end;
  for v_row in select slug from public.masjids
                where is_live and (v_scope is null or id = v_scope) loop
    begin
      perform public.courses_public(v_row.slug);
      perform public.notices_live(v_row.slug);
      perform (select count(*) from public.hall_availability(v_row.slug));
      perform public.prayer_year(v_row.slug, extract(year from now())::int);
    exception when others then
      v_ok := false;
      v_detail := v_row.slug || ' fails a public call: ' || sqlerrm;
    end;
  end loop;
  v_checks := v_checks || jsonb_build_object('check','public_surface','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'public_surface'); end if;

  select count(*) into v_n from information_schema.columns
   where table_schema='public' and column_name='masjid_id' and is_nullable='YES';
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','tenancy_enforced','ok',v_ok,
    'detail', v_n || ' table(s) allow a row with no masjid');
  if not v_ok then v_failing := array_append(v_failing, 'tenancy_enforced'); end if;

  --  COMPATIBILITY_SHIMS: see header. No honest per-masjid phrasing exists
  --  for "how many masjids are on this platform," so a scoped caller (an
  --  ordinary masjid's own admin) simply never sees this check at all.
  if v_scope is null then
    select count(*) into v_n from public.masjids;
    v_ok := (v_n <= 1);
    v_checks := v_checks || jsonb_build_object('check','compatibility_shims','ok',v_ok,
      'detail', case when v_n <= 1
        then 'one masjid, so the old single-masjid calls still resolve'
        else v_n || ' masjids - every caller must now pass a slug, and any that does not is failing' end);
    if not v_ok then v_failing := array_append(v_failing, 'compatibility_shims'); end if;
  end if;

  select count(*) into v_n from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relkind = 'r'
     and c.relname not in (select e.table_name from public.tenancy_exempt e)
     and not exists (select 1 from pg_attribute a
                      where a.attrelid = c.oid and a.attname = 'masjid_id'
                        and not a.attisdropped);
  v_ok := (v_n = 0);
  select coalesce(string_agg(c.relname, ', ' order by c.relname), '') into v_detail
    from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relkind = 'r'
     and c.relname not in (select e.table_name from public.tenancy_exempt e)
     and not exists (select 1 from pg_attribute a
                      where a.attrelid = c.oid and a.attname = 'masjid_id'
                        and not a.attisdropped);
  v_checks := v_checks || jsonb_build_object('check','every_table_has_a_masjid','ok',v_ok,
    'detail', case when v_ok
      then 'every table in public belongs to a masjid, or has a row in tenancy_exempt saying why not'
      else 'table(s) with no masjid_id and no row in tenancy_exempt: ' || v_detail
           || '. Either give it a masjid_id or add it to tenancy_exempt with a reason.' end);
  if not v_ok then v_failing := array_append(v_failing, 'every_table_has_a_masjid'); end if;

  begin
    v_jrow := public.madrasah_list_minimisation();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false; v_detail := 'the minimisation guard itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','lists_carry_marks_not_detail',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'lists_carry_marks_not_detail'); end if;

  begin
    v_jrow := public.madrasah_notice_matches_schema();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the notice check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','notice_matches_the_schema',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'notice_matches_the_schema'); end if;

  begin
    v_jrow := public.auth_rows_readable();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the auth row check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','auth_rows_readable',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'auth_rows_readable'); end if;

  begin
    v_jrow := public.parent_logins_reach_something();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the parent login check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','parent_logins_reach_something',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'parent_logins_reach_something'); end if;

  begin
    v_jrow := public.pupils_on_two_active_rolls();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the shared-roll check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','pupils_on_two_active_rolls',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'pupils_on_two_active_rolls'); end if;

  select count(*) into v_n from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and c.relname in ('import_pupils','import_guardians','import_classes','import_siblings');
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','register_landing_tables_dropped',
    'ok', v_ok, 'detail', case when v_ok
      then 'the register landing tables are gone, as they should be'
      else v_n || ' landing tables still hold a second copy of the register, '
           || 'medical notes included. Sealed, but keep them only while the '
           || 'questionable dates and sibling pairs are still being settled.' end);
  if not v_ok then v_failing := array_append(v_failing, 'register_landing_tables_dropped'); end if;

  return jsonb_build_object(
    'status', case when array_length(v_failing,1) is null then 'ok' else 'fail' end,
    'failing', to_jsonb(v_failing),
    'checked_at', now(),
    'checks', v_checks);
end $function$;

revoke all on function public.health_check() from public, anon;
grant execute on function public.health_check() to authenticated;

commit;
