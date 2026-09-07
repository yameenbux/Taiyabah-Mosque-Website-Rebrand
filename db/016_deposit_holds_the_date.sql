-- ===========================================================================
--  016_deposit_holds_the_date.sql — paying the deposit is what reserves a date
--
--  The decision (committee, 7 September 2026): a hirer pays the £100 deposit
--  online at the moment they book, and that payment is what holds the date.
--
--  This is what the terms of hire have always said —
--
--      "Dates are not held or reserved before the deposit is received."
--
--  — and it is not what the system did. The calendar closed a date when the
--  OFFICE marked a booking confirmed, which is a different moment entirely.
--  Nothing depended on the difference while no money changed hands. Taking
--  payment makes it matter, because two people can otherwise both see the same
--  Saturday free, both pay £100, and only one can have it.
--
--  What this migration puts in place
--  ---------------------------------
--    1. A reference on every hall booking (HH-26-0001), so a payment can be
--       matched back to the booking it belongs to.
--    2. Deposit state, and the Stripe session that produced it.
--    3. A THIRTY-MINUTE HOLD taken when the form is submitted, so that the
--       few minutes somebody spends in Stripe's checkout are not a window in
--       which somebody else can pay for the same date.
--    4. An availability view that closes a date on a live hold or a paid
--       deposit, not only on the office's confirmation.
--    5. A submit function that refuses a date already held — replacing the
--       direct INSERT, which had no way to tell the second person anything.
--    6. mark_deposit_paid(), which only the webhook can call.
--
--  What it deliberately does NOT do
--  --------------------------------
--  It does not make payment the only way to book. A request with no payment is
--  still a request: somebody may prefer to ring, or pay by bank transfer, and
--  the office still sees their row. It simply does not hold the date for them.
--
--  Prerequisites: 003, 006, 014. Idempotent.
--
--  *** STANDING RULE: re-run 011_require_two_step.sql after this. ***
-- ===========================================================================

begin;

do $$
begin
  if to_regclass('public.hall_bookings') is null then
    raise exception 'public.hall_bookings does not exist. Run 003_hall_bookings.sql first.';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'hall_bookings'
                    and column_name = 'hire_type') then
    raise exception 'hall_bookings has no hire_type. Run 014_whole_day_hire.sql first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. Reference, deposit state, and the hold
-- ---------------------------------------------------------------------------
create sequence if not exists public.hall_reference_seq;

alter table public.hall_bookings
  add column if not exists reference         text,
  add column if not exists deposit_status    text not null default 'unpaid',
  add column if not exists deposit_paid_at   timestamptz,
  add column if not exists hold_expires_at   timestamptz,
  add column if not exists stripe_session_id text;

-- Existing bookings predate all of this. They get a reference so the office
-- can quote one, and are left as 'unpaid' — which is true: their deposits were
-- taken in cash or by transfer, not through this.
update public.hall_bookings
   set reference = 'HH-' || to_char(created_at, 'YY') || '-' ||
                   lpad(nextval('public.hall_reference_seq')::text, 4, '0')
 where reference is null;

alter table public.hall_bookings
  alter column reference set not null;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'hall_bookings_reference_key') then
    alter table public.hall_bookings add constraint hall_bookings_reference_key unique (reference);
  end if;
  -- One Stripe checkout can only ever pay for one booking. This is what makes
  -- the webhook safe to retry, which Stripe will do.
  if not exists (select 1 from pg_constraint where conname = 'hall_bookings_session_key') then
    alter table public.hall_bookings add constraint hall_bookings_session_key unique (stripe_session_id);
  end if;
end $$;

alter table public.hall_bookings drop constraint if exists deposit_status_valid;
alter table public.hall_bookings
  add constraint deposit_status_valid check (
    deposit_status in ('unpaid','awaiting','paid','refund_due','refunded')
  );

comment on column public.hall_bookings.reference is
  'HH-YY-NNNN. Quoted to the hirer, and the value passed to Stripe as client_reference_id so a payment can be matched back to its booking.';
comment on column public.hall_bookings.deposit_status is
  '''unpaid'' (rang or paid another way), ''awaiting'' (sent to checkout), ''paid'', ''refund_due'' (paid for a date somebody else had already taken), ''refunded''.';
comment on column public.hall_bookings.hold_expires_at is
  'A date is held for thirty minutes from submission so the hirer can get through Stripe''s checkout without somebody else paying for the same day underneath them. An expired hold releases itself — there is nothing to clean up, because the availability view only counts holds that are still live.';

create index if not exists hall_bookings_hold_idx
  on public.hall_bookings (booking_date) where hold_expires_at is not null;


-- ---------------------------------------------------------------------------
-- 2. What "taken" now means
--
-- Three ways a date is closed, and they are genuinely different:
--
--   * the office confirmed it        — a real booking, however it was paid
--   * the deposit was paid online    — the terms say that reserves it
--   * a live hold                    — somebody is in checkout right now
--
-- Pending requests that never paid are still excluded, for the reason they
-- always were: otherwise a stranger closes every Saturday with a form. A hold
-- is different because it lasts half an hour and flood control caps five
-- submissions a day from one number.
-- ---------------------------------------------------------------------------
drop view if exists public.hall_availability;

create view public.hall_availability
with (security_invoker = off) as
  select booking_date
    from public.hall_bookings
   where booking_date >= (now() at time zone 'Europe/London')::date
     and status <> 'declined'
     and status <> 'cancelled'
     and (
           status = 'confirmed'
        or deposit_status = 'paid'
        or (hold_expires_at is not null and hold_expires_at > now())
     )
   group by booking_date;

comment on view public.hall_availability is
  'Dates that are not available: confirmed, deposit paid, or held for the next half hour while somebody is in checkout. World-readable — the public calendar reads it — so nothing personal may ever be added.';

grant select on public.hall_availability to anon, authenticated;


-- ---------------------------------------------------------------------------
-- 3. Requesting a date
--
-- Replaces the direct INSERT. The insert could not tell the second person
-- anything: two requests for the same Saturday both succeeded and both looked
-- fine. Now the second is refused while the first is in checkout, which is the
-- whole point of taking the hold.
--
-- Returns the reference so the browser can hand it to Stripe.
-- ---------------------------------------------------------------------------
create or replace function public.request_hall_booking(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_date   date := (payload ->> 'booking_date')::date;
  v_type   text := payload ->> 'hire_type';
  v_count  int  := nullif(payload ->> 'halls_count', '')::int;
  v_ref    text;
  v_id     uuid;
begin
  if v_date is null then
    raise exception 'A date is required';
  end if;

  -- Serialise everyone competing for the same day. Without this two requests
  -- can both read "free" and both take a hold.
  perform pg_advisory_xact_lock(hashtext('hall:' || v_date::text));

  if exists (select 1 from public.hall_availability where booking_date = v_date) then
    raise exception 'That date is no longer available. Someone is booking it, or it is already taken.'
      using errcode = 'check_violation';
  end if;

  v_ref := 'HH-' || to_char(now(), 'YY') || '-' ||
           lpad(nextval('public.hall_reference_seq')::text, 4, '0');

  insert into public.hall_bookings
    (reference, booking_date, hire_type, halls_count,
     first_name, last_name, address, phone,
     deposit_status, hold_expires_at)
  values
    (v_ref, v_date, v_type, v_count,
     payload ->> 'first_name', payload ->> 'last_name',
     payload ->> 'address',    payload ->> 'phone',
     'awaiting', now() + interval '30 minutes')
  returning id into v_id;

  insert into public.admin_audit (action, detail)
  values ('hall_booking_requested', jsonb_build_object(
            'reference', v_ref, 'date', v_date,
            'hire_type', v_type, 'halls_count', v_count));

  return jsonb_build_object('reference', v_ref,
                            'held_until', now() + interval '30 minutes');
end;
$$;

revoke all     on function public.request_hall_booking(jsonb) from public;
grant  execute on function public.request_hall_booking(jsonb) to anon, authenticated;

comment on function public.request_hall_booking(jsonb) is
  'Takes a hall hire request, holds the date for thirty minutes and returns the reference to hand to Stripe. Refuses a date already confirmed, paid for, or held by somebody in checkout.';

-- The browser no longer inserts. Everything goes through the function above,
-- which is the only thing that can take the lock and the hold.
revoke insert on public.hall_bookings from anon;


-- ---------------------------------------------------------------------------
-- 4. Recording a payment
--
-- Called by the Stripe webhook and nothing else. Not by a browser: a request
-- that says "I have paid" is not evidence of payment, and the only thing that
-- is, is a signed event from Stripe verified server-side.
--
-- Idempotent, because Stripe retries. A second delivery of the same session
-- returns the same answer and changes nothing.
-- ---------------------------------------------------------------------------
create or replace function public.mark_deposit_paid(
  p_reference  text,
  p_session_id text,
  p_amount_p   int default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  b public.hall_bookings%rowtype;
  v_clash boolean;
begin
  if p_reference is null or p_session_id is null then
    raise exception 'reference and session id are both required';
  end if;

  -- Stripe retries. Answer the retry the same way and touch nothing.
  select * into b from public.hall_bookings where stripe_session_id = p_session_id;
  if found then
    return jsonb_build_object('reference', b.reference,
                              'deposit_status', b.deposit_status,
                              'already_recorded', true);
  end if;

  select * into b from public.hall_bookings where reference = p_reference;
  if not found then
    -- Money has been taken for a booking that does not exist — a mistyped
    -- reference, or somebody editing the payment link. Somebody has to refund
    -- it, so this has to be recorded.
    --
    -- It does NOT raise, and that is deliberate on two counts. An exception
    -- would roll back the audit line written immediately above it, leaving the
    -- one case that most needs a record with none — which is exactly what the
    -- first version of this function did, and what _test_deposit.sql caught.
    -- And a raise makes Stripe retry the delivery for hours, when retrying
    -- cannot help: the booking will not appear.
    insert into public.admin_audit (action, detail)
    values ('deposit_for_unknown_booking',
            jsonb_build_object('reference', p_reference, 'session', p_session_id,
                               'amount_pence', p_amount_p));
    return jsonb_build_object('reference', p_reference,
                              'deposit_status', 'unmatched',
                              'already_recorded', false);
  end if;

  perform pg_advisory_xact_lock(hashtext('hall:' || b.booking_date::text));

  -- Did somebody else get there first? The hold is thirty minutes; a slow
  -- checkout can outlast it. Stripe has the money either way, so the only
  -- honest thing is to record that it must go back.
  select exists (
    select 1 from public.hall_bookings o
     where o.booking_date = b.booking_date
       and o.id <> b.id
       and o.status not in ('declined','cancelled')
       and (o.status = 'confirmed' or o.deposit_status = 'paid')
  ) into v_clash;

  if v_clash then
    update public.hall_bookings
       set deposit_status    = 'refund_due',
           stripe_session_id = p_session_id,
           deposit_paid_at   = now(),
           hold_expires_at   = null
     where id = b.id;

    insert into public.admin_audit (action, detail)
    values ('deposit_needs_refund', jsonb_build_object(
              'reference', b.reference, 'date', b.booking_date,
              'session', p_session_id, 'amount_pence', p_amount_p));

    return jsonb_build_object('reference', b.reference,
                              'deposit_status', 'refund_due',
                              'already_recorded', false);
  end if;

  update public.hall_bookings
     set deposit_status    = 'paid',
         deposit_paid_at   = now(),
         stripe_session_id = p_session_id,
         hold_expires_at   = null      -- payment holds it now, not the clock
   where id = b.id;

  insert into public.admin_audit (action, detail)
  values ('hall_deposit_paid', jsonb_build_object(
            'reference', b.reference, 'date', b.booking_date,
            'session', p_session_id, 'amount_pence', p_amount_p));

  return jsonb_build_object('reference', b.reference,
                            'deposit_status', 'paid',
                            'already_recorded', false);
end;
$$;

-- The webhook calls this with the service role key, which bypasses these
-- grants. Nobody else gets to say that money arrived.
revoke all on function public.mark_deposit_paid(text, text, int)
  from public, anon, authenticated;

comment on function public.mark_deposit_paid(text, text, int) is
  'Records a paid deposit. Called only by the Stripe webhook, using the service role. Idempotent on the Stripe session id, because Stripe retries. If the date was taken by somebody else while this hirer was in checkout, the booking is marked refund_due and a line is written to admin_audit — the money is already gone and somebody has to send it back.';


-- ---------------------------------------------------------------------------
-- 5. What the office may change
--
-- A restriction that was documented but never actually granted.
--
-- Migration 003 ended with:
--
--     grant select, update on public.hall_bookings to authenticated;
--
-- That is UPDATE on the whole table. The README has said since it was written
-- that the office "may only change status, office_notes and handled_at —
-- never the applicant's name, address or requested date", and `venue/app.js`
-- carries the same claim in a comment. Neither was true. Nothing had gone
-- wrong, because the portal only ever writes those three columns — but the
-- database was not the thing stopping it, and a control that lives only in a
-- web page is not a control. RLS decided WHO could write; nothing decided
-- WHAT.
--
-- It matters more now. `reference`, `stripe_session_id` and `deposit_paid_at`
-- are Stripe's account of what happened and the trail a refund would be
-- argued from. The office must not be able to edit any of them, by accident
-- or otherwise.
--
-- `deposit_status` IS writable, so a refund can be marked as done.
-- ---------------------------------------------------------------------------
revoke update on public.hall_bookings from authenticated;
grant  update (status, office_notes, handled_at, deposit_status)
  on public.hall_bookings to authenticated;

commit;
