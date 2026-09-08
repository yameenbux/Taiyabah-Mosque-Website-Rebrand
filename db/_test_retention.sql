-- ===========================================================================
--  _test_retention.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 015: the purges delete what the privacy notice says they
--  delete, they cannot be triggered from a browser, and they leave a trail
--  even when they find nothing.
--
--  Run against a FRESHLY BUILT database:
--      _test_supabase_stub.sql, 001 .. 006  (madrasah-db)
--      008, 009, 010, 011, 013, 014, 015    (this folder)
--
--  Fresh matters: this file deletes rows.
--
--  The assertion that matters most is 04. Before 015, a CONFIRMED nikāḥ
--  request and an ATTENDED class sign-up were kept for ever while the website
--  told people they were deleted after twelve months. If 04 ever fails again,
--  the site is lying to the public.
-- ===========================================================================
\set ON_ERROR_STOP on

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated;

create or replace function pg_temp.note(l text, cond boolean, d text default '')
returns void language plpgsql as $$
begin
  -- coalesce: a NULL assertion (comparing against a column that turned out
  -- to be NULL) used to display as FAIL but was counted as neither passed
  -- nor failed, so the summary line could read "0 failed" over a broken
  -- suite. NULL is not a pass.
  insert into r values (l, coalesce(cond, false), d);
end $$;

create or replace function pg_temp.efail(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,false,'unexpectedly SUCCEEDED');
exception when others then insert into r values (l,true,left(sqlerrm,70)); end; end $$;

create or replace function pg_temp.eok(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,true,'');
exception when others then insert into r values (l,false,left(sqlerrm,90)); end; end $$;

\o /dev/null


-- ---------------------------------------------------------------------------
-- People and courses the fixtures need
-- ---------------------------------------------------------------------------
insert into auth.users (id, email)
values ('11111111-1111-1111-1111-111111111111', 'admin@example.test')
on conflict (id) do nothing;
insert into public.profiles (id, full_name, email)
values ('11111111-1111-1111-1111-111111111111', 'An Administrator', 'admin@example.test')
on conflict (id) do nothing;
insert into public.user_roles (user_id, role)
values ('11111111-1111-1111-1111-111111111111', 'admin')
on conflict do nothing;


-- ---------------------------------------------------------------------------
-- Fixtures.
--
-- Deliberately a mix of statuses. The old purges deleted only the ones nobody
-- wanted anyway, so a test that used only declined and withdrawn rows would
-- have passed against the broken code.
-- ---------------------------------------------------------------------------
insert into public.nikah_requests
  (reference, submitted_at, preferred_date, slot, preferred_time, contact_name,
   contact_role, contact_phone, contact_email, privacy_accepted, status)
values
  -- older than twelve months, and CONFIRMED — the one that used to survive
  ('NK-OLD-0001', now() - interval '14 months', current_date - 300, 'after_zuhr',
   '13:15', 'Old Confirmed', 'bride', '07700900201', 'a@example.test', true, 'confirmed'),
  -- older than twelve months, declined — the old code did delete this one
  ('NK-OLD-0002', now() - interval '14 months', current_date - 300, 'after_asr',
   '16:00', 'Old Declined', 'groom', '07700900202', 'b@example.test', true, 'declined'),
  -- just inside the window: eleven months
  ('NK-NEW-0003', now() - interval '11 months', current_date + 30, 'after_zuhr',
   '13:15', 'Recent Confirmed', 'family', '07700900203', 'c@example.test', true, 'confirmed'),
  -- last week
  ('NK-NEW-0004', now() - interval '7 days', current_date + 60, 'after_isha',
   '20:00', 'This Week', 'bride', '07700900204', 'd@example.test', true, 'new');

insert into public.course_registrations
  (reference, submitted_at, course_key, cohort, first_name, surname, email,
   mobile, age_confirmed, privacy_accepted, outcome, status)
values
  -- older than twelve months, and ATTENDED — the one that used to survive
  ('AR-OLD-0001', now() - interval '14 months', 'arabic', 'mens', 'Old', 'Attended',
   'e@example.test', '07700900211', true, true, 'place', 'attended'),
  ('AR-OLD-0002', now() - interval '14 months', 'arabic', 'mens', 'Old', 'Withdrawn',
   'f@example.test', '07700900212', true, true, 'place', 'withdrawn'),
  ('AR-NEW-0003', now() - interval '11 months', 'arabic', 'womens', 'Recent', 'Active',
   'g@example.test', '07700900213', true, true, 'place', 'active'),
  ('AR-NEW-0004', now() - interval '3 days', 'ghusl', 'mens', 'This', 'Week',
   'h@example.test', '07700900214', true, true, 'place', 'active');


-- ===========================================================================
--  00. Does this test mean anything at all?
-- ===========================================================================
select pg_temp.note('the anon role is subject to RLS',
  not rolsuper and not rolbypassrls,
  'super=' || rolsuper || ' bypassrls=' || rolbypassrls)
from pg_roles where rolname = 'anon';


-- ===========================================================================
--  01. The old single-argument functions are gone
--
--  Adding a defaulted argument creates a SECOND function rather than replacing
--  the first. If both existed, purge_old_nikah_requests(12) would be ambiguous
--  — or would quietly keep calling the old, broken one.
-- ===========================================================================
select pg_temp.note('only one purge_old_nikah_requests exists',
  (select count(*) from pg_proc where proname = 'purge_old_nikah_requests') = 1,
  (select string_agg(pg_get_function_identity_arguments(oid), ' | ')
     from pg_proc where proname = 'purge_old_nikah_requests'));

select pg_temp.note('only one purge_old_course_registrations exists',
  (select count(*) from pg_proc where proname = 'purge_old_course_registrations') = 1,
  (select string_agg(pg_get_function_identity_arguments(oid), ' | ')
     from pg_proc where proname = 'purge_old_course_registrations'));


-- ===========================================================================
--  02. A dry run changes nothing
-- ===========================================================================
select pg_temp.note('dry run counts the nikah requests that would go',
  public.purge_old_nikah_requests(12, true) = 2,
  public.purge_old_nikah_requests(12, true)::text);
select pg_temp.note('dry run counts the sign-ups that would go',
  public.purge_old_course_registrations(12, true) = 2,
  public.purge_old_course_registrations(12, true)::text);

select pg_temp.note('a dry run really did not delete anything',
  (select count(*) from public.nikah_requests) = 4
  and (select count(*) from public.course_registrations) = 4);

select pg_temp.note('a dry run writes no audit line',
  not exists (select 1 from public.admin_audit
               where action in ('nikah_requests_purged','course_registrations_purged')));


-- ===========================================================================
--  03. Nonsense is refused
-- ===========================================================================
select pg_temp.efail('a retention of zero months is refused',
  $$select public.purge_old_nikah_requests(0)$$);
select pg_temp.efail('a null retention is refused',
  $$select public.purge_old_course_registrations(null)$$);
select pg_temp.efail('a negative retention is refused',
  $$select public.purge_old_nikah_requests(-6)$$);

select pg_temp.note('and none of those deleted anything',
  (select count(*) from public.nikah_requests) = 4
  and (select count(*) from public.course_registrations) = 4);


-- ===========================================================================
--  04. THE FIX — confirmed and attended records are deleted too
--
--  This is what the privacy notice has been promising since September 2026
--  and what the code did not do.
-- ===========================================================================
select pg_temp.note('two nikah requests were deleted, not one',
  public.purge_old_nikah_requests(12) = 2);

select pg_temp.note('a CONFIRMED request older than twelve months is gone',
  not exists (select 1 from public.nikah_requests where reference = 'NK-OLD-0001'));
select pg_temp.note('a declined request older than twelve months is gone',
  not exists (select 1 from public.nikah_requests where reference = 'NK-OLD-0002'));
select pg_temp.note('an eleven-month-old confirmed request survives',
  exists (select 1 from public.nikah_requests where reference = 'NK-NEW-0003'));
select pg_temp.note('this week''s request survives',
  exists (select 1 from public.nikah_requests where reference = 'NK-NEW-0004'));

select pg_temp.note('two sign-ups were deleted, not one',
  public.purge_old_course_registrations(12) = 2);

select pg_temp.note('an ATTENDED sign-up older than twelve months is gone',
  not exists (select 1 from public.course_registrations where reference = 'AR-OLD-0001'));
select pg_temp.note('a withdrawn sign-up older than twelve months is gone',
  not exists (select 1 from public.course_registrations where reference = 'AR-OLD-0002'));
select pg_temp.note('an eleven-month-old active sign-up survives',
  exists (select 1 from public.course_registrations where reference = 'AR-NEW-0003'));
select pg_temp.note('this week''s sign-up survives',
  exists (select 1 from public.course_registrations where reference = 'AR-NEW-0004'));


-- ===========================================================================
--  05. The trail
--
--  Including the run that finds nothing. "The job ran and there was nothing to
--  do" and "the job has not run since March" look identical without a line,
--  and only one of them is fine.
-- ===========================================================================
select pg_temp.note('the deletion was recorded',
  exists (select 1 from public.admin_audit
           where action = 'nikah_requests_purged'
             and (detail ->> 'deleted')::int = 2
             and (detail ->> 'retain_months')::int = 12));

-- Three statements, not one clever one. Inside a single statement the audit
-- row the function inserts is not visible to a count in the same statement —
-- same snapshot — so the first version of this assertion failed against
-- perfectly correct code. A test that is wrong in an interesting way is worse
-- than no test.
select set_config('t.audit_before',
  (select count(*)::text from public.admin_audit
    where action = 'course_registrations_purged'), false);

select set_config('t.purged_again',
  public.purge_old_course_registrations(12)::text, false);

select pg_temp.note('a second run finds nothing to delete',
  current_setting('t.purged_again')::int = 0,
  current_setting('t.purged_again'));

select pg_temp.note('and it still leaves an audit line',
  (select count(*) from public.admin_audit where action = 'course_registrations_purged')
    = current_setting('t.audit_before')::int + 1,
  (select count(*)::text from public.admin_audit
    where action = 'course_registrations_purged'));


-- ===========================================================================
--  06. Nobody with a browser can run these
--
--  Before 015 both functions guarded themselves with is_admin(), which a
--  pg_cron job can never satisfy — it holds no JWT — so the scheduled purge
--  would have failed silently every week. The guard is now the EXECUTE grant.
-- ===========================================================================
set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal2', false);

select pg_temp.efail('a verified administrator cannot purge nikah requests',
  $$select public.purge_old_nikah_requests(12)$$);
select pg_temp.efail('a verified administrator cannot purge sign-ups',
  $$select public.purge_old_course_registrations(12)$$);
select pg_temp.efail('a verified administrator cannot purge hall bookings',
  $$select public.purge_old_hall_bookings()$$);
select pg_temp.efail('not even a dry run',
  $$select public.purge_old_nikah_requests(12, true)$$);
reset role;

set role anon;
select set_config('test.uid', '', false);
select set_config('test.aal', '', false);
select pg_temp.efail('the public cannot purge nikah requests',
  $$select public.purge_old_nikah_requests(12)$$);
select pg_temp.efail('the public cannot purge sign-ups',
  $$select public.purge_old_course_registrations(12)$$);
reset role;


-- ===========================================================================
--  07. The public can still use the site
--
--  A retention change that quietly broke sign-up would be a poor trade.
-- ===========================================================================
set role anon;
select pg_temp.eok('the public can still sign up for a class',
  $$select public.register_for_course(jsonb_build_object(
      'course_key','arabic','cohort','womens','first_name','Maryam','surname','Begum',
      'email','maryam@example.test','mobile','07700900333',
      'age_confirmed', true, 'privacy_accepted', true))$$);

select pg_temp.eok('the public can still request a nikah date',
  $$select public.request_nikah_date(jsonb_build_object(
      'preferred_date', (current_date + 45)::text,
      'slot','after_asr','preferred_time','16:00',
      'contact_name','A Person','contact_role','groom',
      'contact_phone','07700900123','contact_email','p@example.test',
      'privacy_accepted', true))$$);
reset role;


-- ===========================================================================
--  Results
-- ===========================================================================
\o
select case when ok then 'PASS' else 'FAIL' end as result, name, detail
  from r order by ok, name;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
  from r;

do $$
declare n int;
begin
  select count(*) into n from r where not ok;
  if n > 0 then raise exception '% assertion(s) failed', n; end if;
end $$;
