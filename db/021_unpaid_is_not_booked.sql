-- ===========================================================================
--  021_unpaid_is_not_booked.sql — the other half of 017
--
--  Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
--  11 September 2026
--
--  WHAT WENT WRONG
--  ---------------
--  Yameen made a test booking, did not pay the deposit, and the portal showed
--  it as CONFIRMED. The row said it all:
--
--      reference        HH-26-0009
--      status           confirmed          <- sold
--      deposit_status   awaiting           <- still in Stripe's checkout
--      deposit_paid_at  null               <- no money has arrived
--      created_at       22:17:17
--      handled_at       22:17:47           <- thirty seconds later
--
--  Nobody paid. The office pressed Confirm.
--
--  Migration 017 said "a paid deposit IS the confirmation" and removed the
--  office's need to confirm. It did not remove their ABILITY to, and nothing
--  in the database stopped them. So a date could still be sold with no money
--  behind it — the same double-booking failure 017 was written to prevent,
--  arriving from the other direction.
--
--  This project already has a rule for exactly this, written after the two-step
--  code was checked in the browser and nowhere else:
--
--      A CHECK THAT ONLY EXISTS IN JAVASCRIPT DOES NOT EXIST.
--
--  Hiding the Confirm button is not enough and is not what this file does.
--
--  THE SECOND FAULT
--  ----------------
--  Nothing ever cleared a lapsed hold. A hirer who opened the checkout and
--  walked away left a row at status='new', deposit_status='awaiting' for ever.
--  The date released itself — hall_availability only counts live holds — but
--  the record sat in the office's list looking like somebody waiting for a
--  phone call. Four of them are in the table today.
--
--  WHAT THIS FILE DOES
--  -------------------
--  1. A trigger that REFUSES to confirm a booking with no deposit recorded.
--  2. record_cash_deposit() — the honest way to book a date for somebody who
--     pays at the counter, which is the legitimate need the Confirm button was
--     being used for.
--  3. purge_expired_holds() — deletes an untouched, unpaid, lapsed hold
--     outright, every ten minutes.
--  4. Repairs any booking already confirmed while the hirer was mid-checkout.
--
--  Prerequisites: 016, 017. Idempotent.
--
--  AFTER APPLYING THIS, RE-RUN 011_require_two_step.sql.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. Repair first, before the rule exists to refuse it
--
--  'awaiting' means one thing: the hirer is in Stripe's checkout right now.
--  A CONFIRMED booking in that state is not a real state — it is a date sold
--  against a payment that never arrived. Put it back to a request and release
--  the hold so the purge below can take it.
--
--  Deliberately narrow. A booking confirmed against deposit_status 'unpaid' is
--  left exactly as it is: that is most likely a genuine booking somebody paid
--  for at the counter before this file existed, and inventing a decision about
--  it would be worse than leaving it. The trigger below only governs NEW
--  transitions, so nothing already in the table breaks.
-- ---------------------------------------------------------------------------
do $$
declare v_n int;
begin
  with fixed as (
    update public.hall_bookings
       set status          = 'new',
           handled_at      = null,
           deposit_status  = 'unpaid',
           hold_expires_at = null
     where status = 'confirmed'
       and deposit_status = 'awaiting'
       and deposit_paid_at is null
    returning reference, booking_date
  )
  select count(*) into v_n from fixed;

  if v_n > 0 then
    insert into public.admin_audit (action, detail)
    values ('hall_confirmed_without_payment_repaired',
            jsonb_build_object('count', v_n, 'by', 'migration 021'));
    raise notice '021: % booking(s) were confirmed with no deposit — put back to new', v_n;
  end if;
end $$;


-- ---------------------------------------------------------------------------
--  2. The rule itself
--
--  A BEFORE UPDATE trigger, not a CHECK constraint. This project learned that
--  the hard way in 014: Postgres re-evaluates every CHECK on every UPDATE, so
--  a constraint describing what somebody is ALLOWED TO DO freezes every row
--  that stops satisfying it. This is a rule about a transition, and rules
--  about transitions belong in triggers.
--
--  It fires only when a booking BECOMES confirmed. Rows already confirmed are
--  never re-examined, so no existing booking is made uneditable.
-- ---------------------------------------------------------------------------
create or replace function public.hall_confirm_needs_deposit()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'confirmed'
     and old.status is distinct from 'confirmed'
     and new.deposit_status <> 'paid' then
    raise exception
      'This booking has no deposit. Paying the £100 confirms it automatically — '
      'if the hirer paid at the office, use "deposit taken in cash" instead, '
      'which records the money and books the date together.'
      using errcode = 'check_violation';
  end if;
  return new;
end $$;

drop trigger if exists hall_confirm_needs_deposit on public.hall_bookings;
create trigger hall_confirm_needs_deposit
  before update on public.hall_bookings
  for each row execute function public.hall_confirm_needs_deposit();

comment on function public.hall_confirm_needs_deposit() is
  'Refuses to move a hall booking to confirmed unless a deposit has been recorded. 017 made paying the confirmation; this is what stops a date being sold without one. Fires only on the transition, so existing rows stay editable.';


-- ---------------------------------------------------------------------------
--  3. A deposit taken at the counter
--
--  The legitimate need the Confirm button was carrying. Somebody walks in with
--  £100 in cash or hands over a card at the office; the masjid has the money,
--  the date is theirs, and nothing about that should be harder than it was.
--
--  It is a separate, audited act rather than a status change, because "the
--  money arrived" and "the date is sold" are one event and must not be able to
--  drift apart. Auditing WHO recorded it matters: this is the one path where a
--  member of staff, not Stripe, asserts that money exists.
-- ---------------------------------------------------------------------------
create or replace function public.record_cash_deposit(
  p_reference text,
  p_amount_p  int default 10000
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
  if not (public.verified_admin() or public.verified_office()) then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  select * into b from public.hall_bookings where reference = p_reference;
  if not found then
    raise exception 'No booking with reference %', p_reference;
  end if;

  if b.deposit_status = 'paid' then
    -- Already settled. Say so rather than recording a second £100 against a
    -- booking that has one, which is how a refund gets owed by accident.
    return jsonb_build_object('reference', b.reference,
                              'deposit_status', 'paid',
                              'already_recorded', true);
  end if;

  -- The same clash check the webhook does. Somebody paying at the counter for
  -- a date that is already sold is exactly as possible as somebody paying for
  -- one online, and rather more likely — the person at the desk cannot see the
  -- diary the calendar sees.
  select exists (
    select 1 from public.hall_bookings o
     where o.booking_date = b.booking_date
       and o.id <> b.id
       and o.status not in ('declined','cancelled')
       and (o.status = 'confirmed' or o.deposit_status = 'paid')
  ) into v_clash;

  if v_clash then
    raise exception
      'That date is already taken by another booking. Do not accept the money.'
      using errcode = 'check_violation';
  end if;

  update public.hall_bookings
     set deposit_status  = 'paid',
         deposit_paid_at = now(),
         hold_expires_at = null,
         status          = 'confirmed',
         handled_at      = now()
   where id = b.id;

  insert into public.admin_audit (action, detail)
  values ('hall_deposit_cash', jsonb_build_object(
            'reference', b.reference, 'date', b.booking_date,
            'amount_pence', p_amount_p,
            'recorded_by', auth.uid()));

  return jsonb_build_object('reference', b.reference,
                            'deposit_status', 'paid',
                            'status', 'confirmed',
                            'already_recorded', false);
end $$;

revoke all     on function public.record_cash_deposit(text, int) from public, anon;
grant  execute on function public.record_cash_deposit(text, int) to authenticated;

comment on function public.record_cash_deposit(text, int) is
  'Records a £100 deposit taken at the office and books the date, in one audited act. The honest replacement for pressing Confirm on an unpaid booking. Refuses a date already taken. Verified staff only.';


-- ---------------------------------------------------------------------------
--  4. Deleting a hold nobody paid for
--
--  Requested plainly: "once the timer is up for 30 mins holding of booking,
--  the booking should be removed altogether if the deposit has not been paid."
--
--  Four conditions, and every one of them is load-bearing:
--
--    deposit_status = 'awaiting'   it went to checkout and never came back.
--                                  A booking at 'unpaid' was never sent to
--                                  Stripe at all — the office is handling it.
--    deposit_paid_at is null       belt and braces. Money is never deleted.
--    hold_expires_at < now()       the thirty minutes are up.
--    status = 'new'                NOBODY HAS TOUCHED IT. If the office
--                                  declined or cancelled it, that is a
--                                  decision somebody made and the record of it
--                                  has value. Deleting those would erase the
--                                  work, not the junk.
--
--  No dry_run here, unlike 015. The rows this deletes contain a name, an
--  address and a phone number for a booking that does not exist, and keeping
--  them around to be inspected is the thing being complained about. It audits
--  the count and the references, so the fact of the deletion survives.
-- ---------------------------------------------------------------------------
create or replace function public.purge_expired_holds()
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_refs text[];
  v_n    int;
begin
  with gone as (
    delete from public.hall_bookings
     where deposit_status  = 'awaiting'
       and deposit_paid_at is null
       and hold_expires_at is not null
       and hold_expires_at < now()
       and status = 'new'
    returning reference
  )
  select coalesce(array_agg(reference), '{}'), count(*) into v_refs, v_n from gone;

  -- Written even when it finds nothing. A job that is silent on a quiet run is
  -- indistinguishable from a job that has stopped running — 015's reasoning,
  -- and the reason anybody can answer "is this actually working?" in one query.
  insert into public.admin_audit (action, detail)
  values ('hall_holds_purged', jsonb_build_object(
            'count', v_n, 'references', to_jsonb(v_refs)));

  return v_n;
end $$;

revoke all on function public.purge_expired_holds() from public, anon, authenticated;

comment on function public.purge_expired_holds() is
  'Deletes hall bookings whose thirty-minute checkout hold lapsed with no payment and which nobody in the office has touched. Never deletes anything with a payment against it, and never deletes a booking somebody decided on. Runs every ten minutes; access is by GRANT, because pg_cron holds no JWT.';

commit;

-- ---------------------------------------------------------------------------
--  5. The schedule
--
--  Outside the transaction, so a missing pg_cron cannot roll back everything
--  above — the same reason 015 and 019 schedule after their commit.
--
--  Ten minutes. The hold is thirty, so a dead booking is visible for at most
--  forty and usually far less. Running it every minute would be tidier and
--  would also mean 1,440 audit rows a day saying "deleted nothing".
-- ---------------------------------------------------------------------------
select cron.schedule('purge-expired-holds', '*/10 * * * *',
                     $$select public.purge_expired_holds()$$);

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
--
--  Then check what it did on its first pass:
--
--    select public.purge_expired_holds();
--    select detail, at from public.admin_audit
--     where action in ('hall_holds_purged',
--                      'hall_confirmed_without_payment_repaired')
--     order by at desc limit 5;
--
--  And prove the rule is real — this MUST fail:
--
--    update public.hall_bookings set status = 'confirmed'
--     where deposit_status <> 'paid' and status = 'new';
-- ===========================================================================
