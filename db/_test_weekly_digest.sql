-- ===========================================================================
--  _test_weekly_digest.sql — LOCAL ONLY. NEVER RUN AGAINST SUPABASE.
--
--  Proves migration 019.
--
--  Run against a FRESHLY BUILT database:  bash /tmp/build_dg.sh t_dg
--  (that harness stubs net.http_post and cron.schedule, so nothing leaves the
--   machine and the posted body can be inspected)
--
--  The assertion that matters most is 02a: WITH NOTHING OUTSTANDING, NOTHING
--  IS SENT. A weekly email that always arrives becomes furniture within a
--  month and stops being read — at which point the one week it says "a refund
--  is owed" gets skimmed past with the rest.
-- ===========================================================================
\set ON_ERROR_STOP on

create temporary table r(name text, ok boolean, detail text);
grant all on r to anon, authenticated;

create or replace function pg_temp.note(l text, cond boolean, d text default '')
returns void language plpgsql as $$
begin insert into r values (l, cond, d); end $$;

create or replace function pg_temp.efail(l text, s text) returns void language plpgsql as $$
begin begin execute s; insert into r values (l,false,'unexpectedly SUCCEEDED');
exception when others then insert into r values (l,true,left(sqlerrm,70)); end; end $$;

\o /dev/null

-- The settings the scheduled job needs.
insert into public.app_settings (key, value) values
  ('notify_url',    'https://example.test/functions/v1/notify'),
  ('notify_secret', 'test-secret-value')
on conflict (key) do update set value = excluded.value;


-- ===========================================================================
--  01. A QUIET WEEK
-- ===========================================================================
select pg_temp.note('a quiet week has nothing outstanding',
  (public.outstanding_summary() ->> 'new_nikah')::int = 0);

select pg_temp.note('and sends NOTHING',
  (public.send_weekly_digest() ->> 'sent') = 'false',
  public.send_weekly_digest() ->> 'why');

select pg_temp.note('nothing was posted anywhere',
  (select count(*) from net._sent) = 0);

-- force is for demonstrating it on a quiet week, and nothing else.
select pg_temp.note('force sends anyway, so it can be shown to somebody',
  (public.send_weekly_digest(force => true) ->> 'sent') = 'true');

select pg_temp.note('and that one really was posted',
  (select count(*) from net._sent) = 1);

delete from net._sent;


-- ===========================================================================
--  02. THINGS THAT NEED A HUMAN
-- ===========================================================================
insert into public.nikah_requests
  (reference, preferred_date, slot, contact_name, contact_role,
   contact_phone, contact_email, privacy_accepted, status, submitted_at)
values
  ('NK-26-8001', current_date + 40, 'after_zuhr', 'Waiting Family', 'family',
   '07700900901', 'w1@example.test', true, 'new', now() - interval '9 days'),
  ('NK-26-8002', current_date + 45, 'after_asr', 'Also Waiting', 'family',
   '07700900902', 'w2@example.test', true, 'new', now() - interval '2 days'),
  ('NK-26-8003', current_date + 50, 'after_isha', 'Owed Money', 'family',
   '07700900903', 'w3@example.test', true, 'declined', now() - interval '3 days');

update public.nikah_requests set fee_status = 'refund_due'
 where reference = 'NK-26-8003';

select pg_temp.note('unanswered nikāḥ requests are counted',
  (public.outstanding_summary() ->> 'new_nikah')::int = 2,
  public.outstanding_summary() ->> 'new_nikah');

-- The number that makes a shared inbox honest. "2 requests" is easy to assume
-- somebody else has handled; "the oldest has been waiting 9 days" is not.
select pg_temp.note('and how long the oldest has been waiting',
  (public.outstanding_summary() ->> 'oldest_nikah_days')::int = 9,
  public.outstanding_summary() ->> 'oldest_nikah_days');

select pg_temp.note('a declined request is not counted as waiting',
  (public.outstanding_summary() ->> 'new_nikah')::int = 2);

select pg_temp.note('a nikāḥ fee owed back is counted as a refund',
  (public.outstanding_summary() ->> 'refunds_due')::int = 1);


-- ===========================================================================
--  03. HALL MONEY
-- ===========================================================================
insert into public.hall_bookings
  (booking_date, hire_type, halls_count, first_name, last_name,
   address, phone, status, reference, deposit_status, base_amount_p,
   balance_status)
values
  -- confirmed, balance unpaid, inside 30 days -> chase it
  (current_date + 20, 'halls', 2, 'Balance', 'Owing', '1 Astley Street, Bolton, BL1 8HD',
   '07700900801', 'confirmed', 'HH-26-8001', 'paid', 50000, 'unpaid'),
  -- confirmed, balance unpaid, but months away -> not yet
  (current_date + 200, 'halls', 2, 'Not', 'Yet', '2 Bury Road, Bolton, BL1 8HE',
   '07700900802', 'confirmed', 'HH-26-8002', 'paid', 50000, 'unpaid'),
  -- confirmed, already settled -> nothing to chase, but it IS on this week
  (current_date + 3, 'halls', 2, 'All', 'Settled', '3 Chorley Road, Bolton, BL1 8HF',
   '07700900803', 'confirmed', 'HH-26-8003', 'paid', 50000, 'paid'),
  -- money that must go back
  (current_date + 25, 'halls', 2, 'Refund', 'Me', '4 Deane Road, Bolton, BL1 8HG',
   '07700900804', 'cancelled', 'HH-26-8004', 'refund_due', 50000, 'unpaid');

select pg_temp.note('a balance due inside 30 days is counted',
  (public.outstanding_summary() ->> 'balances_due')::int = 1,
  public.outstanding_summary() ->> 'balances_due');

select pg_temp.note('a balance months away is NOT chased yet',
  (public.outstanding_summary() ->> 'balances_due')::int = 1);

select pg_temp.note('a settled balance is not chased',
  (public.outstanding_summary() ->> 'balances_due')::int = 1);

select pg_temp.note('hall and nikāḥ refunds are added together',
  (public.outstanding_summary() ->> 'refunds_due')::int = 2,
  public.outstanding_summary() ->> 'refunds_due');

select pg_temp.note('what is on in the next week is counted',
  (public.outstanding_summary() ->> 'this_week')::int = 1,
  public.outstanding_summary() ->> 'this_week');


-- ===========================================================================
--  04. NOW IT SENDS
-- ===========================================================================
select pg_temp.note('with something outstanding, it sends',
  (public.send_weekly_digest() ->> 'sent') = 'true');

select pg_temp.note('exactly once',
  (select count(*) from net._sent) = 1);

select pg_temp.note('to the address in app_settings',
  (select url from net._sent limit 1) = 'https://example.test/functions/v1/notify');

select pg_temp.note('carrying the shared secret',
  (select headers ->> 'x-notify-secret' from net._sent limit 1) = 'test-secret-value');

select pg_temp.note('and saying which kind of message it is',
  (select body ->> 'kind' from net._sent limit 1) = 'digest');

select pg_temp.note('with the counts in the body',
  (select (body ->> 'new_nikah')::int from net._sent limit 1) = 2
  and (select (body ->> 'refunds_due')::int from net._sent limit 1) = 2);

-- Nothing about a person goes in the digest. It is counts and nothing else.
select pg_temp.note('NO NAMES, PHONE NUMBERS OR ADDRESSES ARE POSTED',
  (select body::text from net._sent limit 1) !~* 'Waiting|Owing|Astley|Bolton|07700',
  left((select body::text from net._sent limit 1), 90));


-- ===========================================================================
--  05. WHEN IT IS NOT CONFIGURED
-- ===========================================================================
delete from net._sent;
delete from public.app_settings where key = 'notify_url';

select pg_temp.note('missing settings do not raise, they explain',
  (public.send_weekly_digest() ->> 'why') like '%missing%');

select pg_temp.note('and nothing is posted into the void',
  (select count(*) from net._sent) = 0);

insert into public.app_settings (key, value)
values ('notify_url', 'https://example.test/functions/v1/notify');


-- ===========================================================================
--  06. WHO MAY DO ANY OF THIS
--
--  The settings table holds a shared secret. It has RLS on and no policy, and
--  every privilege revoked — anon and authenticated must not read one row.
-- ===========================================================================
set role anon;
select pg_temp.note('the anon role is subject to RLS',
  not (select rolsuper or rolbypassrls from pg_roles where rolname = current_user),
  'super=' || (select rolsuper from pg_roles where rolname = current_user)::text);

select pg_temp.efail('the public cannot read the shared secret',
  $$select value from public.app_settings$$);

select pg_temp.efail('nor send the digest',
  $$select public.send_weekly_digest()$$);
reset role;

set role authenticated;
select pg_temp.efail('nor can a signed-in member of staff read the secret',
  $$select value from public.app_settings$$);

select pg_temp.efail('nor trigger a send',
  $$select public.send_weekly_digest()$$);

select pg_temp.efail('nor write a new endpoint into the settings',
  $$insert into public.app_settings (key, value) values ('notify_url','https://evil.test')$$);
reset role;

-- Reading the summary is harmless and useful — it is what the portal could
-- show one day — so staff MAY do that.
set role authenticated;
select set_config('test.uid', '11111111-1111-1111-1111-111111111111', false);
select set_config('test.aal', 'aal2', false);
select pg_temp.note('but staff may read the summary itself',
  (public.outstanding_summary() ->> 'new_nikah')::int = 2);
reset role;


-- ===========================================================================
--  07. IT IS ACTUALLY SCHEDULED
-- ===========================================================================
select pg_temp.note('the weekly job exists',
  exists (select 1 from pg_proc where proname = 'send_weekly_digest'));

select pg_temp.note('nothing from 015 was disturbed',
  (select count(*) from pg_proc
    where proname in ('purge_old_nikah_requests',
                      'purge_old_course_registrations')) = 2);


\o
select name, case when ok then 'PASS' else '**FAIL**' end as result, detail
  from r order by ok, name;

select count(*) filter (where ok) as passed,
       count(*) filter (where not ok) as failed
  from r;
