-- ===========================================================================
--  CHECK_course_registrations.sql — read only. Safe to run in Supabase.
--
--  Why this exists
--  ---------------
--  On 4 September 2026 a test sign-up for the Arabic class appeared to work —
--  the website showed a reference number — but no administrator could find it
--  anywhere. Two quite different things could cause that:
--
--    (a) the sign-up never reached the database, or
--    (b) it did, and nothing in the admin area was reading the table.
--
--  Building a viewer before knowing which would have meant debugging both at
--  once. This file answers the question on its own. It reads; it changes
--  nothing; it can be run as often as you like.
--
--  Run the WHOLE file in the Supabase SQL editor. It contains no psql
--  meta-commands, so it behaves the same there as it does locally.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Does the table exist, and is anything in it?
-- ---------------------------------------------------------------------------
select
  to_regclass('public.course_registrations') is not null   as table_exists,
  (select count(*) from public.course_registrations)       as rows_total,
  (select count(*) from public.course_registrations
    where submitted_at > now() - interval '24 hours')      as rows_today;

-- ---------------------------------------------------------------------------
-- 2. Everything signed up, newest first.
--
--  No email addresses, phone numbers or surnames are selected. The question is
--  "did the row land", not "who is on the list", and a query pasted into a
--  chat window should not carry personal data it does not need.
-- ---------------------------------------------------------------------------
select reference,
       course_key,
       cohort,
       outcome,                                    -- 'place' or 'waiting'
       status,                                     -- active / withdrawn / attended / no_show
       left(first_name, 1) || '.' as who,
       submitted_at
  from public.course_registrations
 order by submitted_at desc
 limit 25;

-- ---------------------------------------------------------------------------
-- 3. The roster, the way the office thinks about it.
--
--  If row 2 shows the sign-up but this shows a course you did not expect, the
--  course_key sent by the website does not match the key in public.courses.
-- ---------------------------------------------------------------------------
select c.name,
       c.capacity,
       c.is_open,
       r.cohort,
       count(*) filter (where r.outcome = 'place'   and r.status = 'active') as places_taken,
       count(*) filter (where r.outcome = 'waiting' and r.status = 'active') as waiting
  from public.courses c
  left join public.course_registrations r on r.course_key = c.key
 group by c.name, c.capacity, c.is_open, r.cohort, c.sort_order
 order by c.sort_order, r.cohort;

-- ---------------------------------------------------------------------------
-- 4. The audit trail.
--
--  register_for_course() writes a line here on every successful sign-up. If
--  section 2 is empty but this is not, a row was inserted and later removed.
--  If both are empty, the sign-up never arrived.
-- ---------------------------------------------------------------------------
select action, detail, at
  from public.admin_audit
 where action in ('course_registration', 'course_place_given',
                  'course_registrations_purged')
 order by at desc
 limit 15;

-- ---------------------------------------------------------------------------
-- 5. Can an administrator read the table at all?
--
--  Migration 011 put every staff policy behind verified_admin(), which needs
--  a session that has passed two-step verification. The SQL editor is not such
--  a session — it runs as the owner and bypasses RLS — so this section reports
--  what the POLICIES say rather than what this connection can see.
--
--  Expect two rows, both mentioning verified_admin().
-- ---------------------------------------------------------------------------
select policyname, cmd, qual
  from pg_policies
 where schemaname = 'public'
   and tablename  = 'course_registrations'
   and policyname like 'admin_%'
 order by policyname;
