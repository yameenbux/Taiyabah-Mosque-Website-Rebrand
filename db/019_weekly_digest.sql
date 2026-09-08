-- ===========================================================================
--  019_weekly_digest.sql — the Monday morning summary
--
--  Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
--  8 September 2026
--
--  WHY THIS EXISTS
--  ---------------
--  The office alerts go to a shared mailbox that several people can open.
--  That solves availability — somebody is always able to look — but it
--  creates the classic shared-inbox problem: three people each assume one of
--  the others has dealt with it, and once anybody opens a message it shows as
--  read for everyone, so "unread" stops working as a list of things to do.
--
--  The portal is the real record: a nikāḥ request sits in New, a refund sits
--  in Refunds, a balance sits in Balance due, until somebody actually acts.
--  Nothing is lost if an email is missed. But NOTHING CHASES — a refund owed
--  will sit in that tab indefinitely if nobody opens the portal, and that is
--  the one where the masjid is holding somebody else's money.
--
--  So: one email a week, listing only what is still outstanding.
--
--  IT SENDS NOTHING WHEN THERE IS NOTHING.
--  That is the whole design. A weekly email that always arrives becomes
--  furniture within a month and stops being read. One that only arrives when
--  something needs doing is still being read a year later.
--
--  Prerequisites: 010, 016, 017, 018, and the pg_net extension (which the
--  nikāḥ database webhook already needed). Idempotent.
--
--  AFTER APPLYING THIS, RE-RUN 011_require_two_step.sql.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. Somewhere to keep the notify address and secret
--
--  pg_cron runs SQL, so the URL and the shared secret have to be reachable
--  from SQL. RLS is enabled with NO policies and every privilege is revoked,
--  so anon and authenticated cannot read this table at all — not one row, not
--  one column. Only the table owner can, which is who pg_cron runs as.
--
--  This is the same reasoning as 015: access to scheduled machinery is by
--  GRANT, not by an in-function is_admin() check that a cron job could never
--  satisfy because it holds no JWT.
-- ---------------------------------------------------------------------------
create table if not exists public.app_settings (
  key   text primary key,
  value text not null
);

alter table public.app_settings enable row level security;
revoke all on public.app_settings from public, anon, authenticated;

comment on table public.app_settings is
  'Values the scheduled jobs need. NOT readable by anon or authenticated — no RLS policy exists, and privileges are revoked. Holds the notify endpoint and its shared secret.';

-- ---------------------------------------------------------------------------
--  2. What is still outstanding
--
--  A plain function of the tables, so it can be tested without sending
--  anything and read by a human wondering what the email would say.
-- ---------------------------------------------------------------------------
create or replace function public.outstanding_summary()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with today as (select (now() at time zone 'Europe/London')::date as d)
  select jsonb_build_object(

    -- Nikāḥ requests nobody has answered. The family is waiting for a call.
    'new_nikah',
      (select count(*) from public.nikah_requests where status = 'new'),

    -- How long the oldest of them has been waiting. This is the number that
    -- makes a shared inbox honest: "3 requests" is easy to assume somebody
    -- else has handled; "the oldest has been waiting 9 days" is not.
    'oldest_nikah_days',
      coalesce((select max((select d from today) - r.submitted_at::date)
                  from public.nikah_requests r where r.status = 'new'), 0),

    -- Money the masjid is holding and cannot keep. The most important line.
    'refunds_due',
      (select count(*) from public.hall_bookings where deposit_status = 'refund_due')
      + (select count(*) from public.nikah_requests where fee_status = 'refund_due'),

    -- Balances due within 30 days, per the masjid's own terms.
    'balances_due',
      (select count(*) from public.hall_bookings b
        where b.status = 'confirmed'
          and coalesce(b.balance_status, 'unpaid') not in ('paid','waived')
          and b.booking_date >= (select d from today)
          and b.booking_date <= (select d from today) + 30),

    -- What is actually on this week, so the email is useful and not only a
    -- list of chores.
    'this_week',
      (select count(*) from public.hall_bookings b
        where b.status = 'confirmed'
          and b.booking_date >= (select d from today)
          and b.booking_date <= (select d from today) + 7),

    'generated_at', now()
  )
$$;

comment on function public.outstanding_summary() is
  'What still needs a human: unanswered nikāḥ requests, refunds owed, balances due inside 30 days, and what is booked this week. Read-only.';

revoke all on function public.outstanding_summary() from public, anon;
grant execute on function public.outstanding_summary() to authenticated;

-- ---------------------------------------------------------------------------
--  3. Sending it
--
--  No is_admin() check inside. pg_cron holds no JWT, so auth.uid() is null and
--  such a check would fail silently every Monday — exactly the fault 015 was
--  written to avoid. Access is controlled by the REVOKE below instead.
-- ---------------------------------------------------------------------------
create or replace function public.send_weekly_digest(force boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  s        jsonb;
  v_url    text;
  v_secret text;
  v_total  int;
begin
  s := public.outstanding_summary();

  v_total := (s->>'new_nikah')::int
           + (s->>'refunds_due')::int
           + (s->>'balances_due')::int;

  -- Silence when there is nothing. `force` exists only so this can be tested
  -- and demonstrated on a quiet week; the schedule never passes it.
  if v_total = 0 and not force then
    return jsonb_build_object('sent', false, 'why', 'nothing outstanding',
                              'summary', s);
  end if;

  select value into v_url    from public.app_settings where key = 'notify_url';
  select value into v_secret from public.app_settings where key = 'notify_secret';

  if v_url is null or v_secret is null then
    -- Not configured is not an error worth raising every week. Say so and
    -- stop; the row this returns is what somebody will look at.
    return jsonb_build_object('sent', false,
                              'why', 'notify_url or notify_secret missing from app_settings',
                              'summary', s);
  end if;

  perform net.http_post(
    url     := v_url,
    body    := s || jsonb_build_object('kind', 'digest'),
    headers := jsonb_build_object('content-type', 'application/json',
                                  'x-notify-secret', v_secret)
  );

  return jsonb_build_object('sent', true, 'summary', s);
end$$;

comment on function public.send_weekly_digest(boolean) is
  'Posts the outstanding summary to the notify function. Sends NOTHING when nothing is outstanding — a weekly email that always arrives stops being read. Owner and pg_cron only.';

commit;

-- ---------------------------------------------------------------------------
--  4. Who may call it, and when
--
--  Outside the transaction so a missing pg_cron cannot roll back the function
--  above — the same reason 015 schedules after its commit.
-- ---------------------------------------------------------------------------
revoke all on function public.send_weekly_digest(boolean) from public;
revoke all on function public.send_weekly_digest(boolean) from anon, authenticated;

-- Monday 08:00 UTC. That is 9am through British Summer Time and 8am through
-- the winter; cron has no notion of local time and an hour either way does not
-- matter for a weekly summary. Deliberately not left to drift unexplained.
select cron.schedule('weekly-digest', '0 8 * * 1',
                     $$select public.send_weekly_digest()$$);

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
--
--  Then put the two settings in, replacing the placeholders:
--
--    insert into public.app_settings (key, value) values
--      ('notify_url',    'https://<project>.supabase.co/functions/v1/notify'),
--      ('notify_secret', '<the same string the webhooks use>')
--    on conflict (key) do update set value = excluded.value;
--
--  And prove it, without waiting until Monday:
--
--    select public.send_weekly_digest(force => true);
-- ===========================================================================
