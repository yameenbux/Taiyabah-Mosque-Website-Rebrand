-- ===========================================================================
--  017_paid_is_booked.sql — paying confirms the booking, and the money adds up
--
--  Two decisions, 7 September 2026.
--
--  1. PAYING THE DEPOSIT CONFIRMS THE BOOKING.
--
--     Until now a paid deposit held the date and the office then had to press
--     Confirm. That left a hirer who had paid £100 waiting for a phone call to
--     find out whether they had actually booked anything, which is no way to
--     treat somebody who has just given the masjid money. mark_deposit_paid()
--     now sets status = 'confirmed' as well.
--
--     The office no longer confirms, and there is no Decline on a paid
--     booking. What remains is cancel-and-refund: deliberate, audited, and it
--     always returns the money. That is not a softening of the decision — it
--     is required by two things the masjid cannot design away:
--
--       * two people CAN pay for the same day (the hold is thirty minutes and
--         a slow checkout can outlast it), and there is only one hall;
--       * the terms of hire require use of the venue in accordance with
--         Islamic rulings, and a masjid that cannot refuse a booking has sold
--         its building to whoever pays first.
--
--     A request that is never paid is untouched: it stays 'new', its hold
--     lapses, the date reopens, and the office rings whoever asked.
--
--  2. THE PORTAL SHOWS WHAT IS OWED.
--
--     The base rate is fully determined by the booking — how many halls, and
--     which day of the week — so it is worked out here and STORED, not
--     recomputed on screen. Stored, because a booking taken today should still
--     show today's rate after the trustees change the price list. A figure
--     that silently changes under an old booking is worse than no figure.
--
--     What cannot be worked out is the extras: £100 for utensils if they were
--     used, 45p a head if the hirer cooked. Those depend on the day itself, so
--     the office types them, and the balance follows.
--
--  Prerequisites: 014, 016. Idempotent.
--
--  *** STANDING RULE: re-run 011_require_two_step.sql after this. ***
-- ===========================================================================

begin;

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='hall_bookings'
                    and column_name='deposit_status') then
    raise exception 'hall_bookings has no deposit_status. Run 016 first.';
  end if;
end $$;


-- ---------------------------------------------------------------------------
-- 1. Money, in pence
--
-- Pence, integer, never a float. £600.00 does not exist exactly in binary and
-- a rounding error in somebody's hall hire bill is not a bug anybody wants to
-- explain.
-- ---------------------------------------------------------------------------
alter table public.hall_bookings
  add column if not exists base_amount_p  int,
  add column if not exists extras_p       int not null default 0,
  add column if not exists balance_status text not null default 'unpaid',
  add column if not exists balance_paid_at timestamptz;

alter table public.hall_bookings drop constraint if exists balance_status_valid;
alter table public.hall_bookings
  add constraint balance_status_valid
  check (balance_status in ('unpaid','paid','waived'));

alter table public.hall_bookings drop constraint if exists extras_sane;
alter table public.hall_bookings
  add constraint extras_sane check (extras_p >= 0 and extras_p <= 500000);

comment on column public.hall_bookings.base_amount_p is
  'The published hall rate in PENCE at the time of booking, worked out from halls_count and the day of the week. Stored rather than recomputed: a booking taken under this year''s prices must keep showing this year''s prices.';
comment on column public.hall_bookings.extras_p is
  'Utensils and the utility charge, in pence, typed by the office after the event. Not computable in advance — they depend on whether the utensils were used and how many people ate.';
comment on column public.hall_bookings.balance_status is
  '''unpaid'', ''paid'' (cash or bank transfer at the office) or ''waived''. The balance is not taken online: it is not a fixed amount.';


-- ---------------------------------------------------------------------------
-- 2. The rate card, as a function
--
-- The one place the price list lives in the database. If the trustees change
-- the charges, this is what changes — and every booking already taken keeps
-- the figure stored against it.
--
--     Mon–Thu   1 hall £350   2 halls £500   3 halls £600
--     Fri–Sun                 2 halls £600   3 halls £700
--     Kitchen only £125
-- ---------------------------------------------------------------------------
create or replace function public.hall_base_amount_p(
  p_date date, p_hire_type text, p_halls int
)
returns int
language sql
immutable
as $$
  select case
    when p_hire_type = 'kitchen_only' then 12500
    when extract(dow from p_date) in (0, 5, 6) then
      case p_halls when 2 then 60000 when 3 then 70000 else null end
    else
      case p_halls when 1 then 35000 when 2 then 50000 when 3 then 60000 else null end
  end
$$;

comment on function public.hall_base_amount_p(date, text, int) is
  'The published Astley Hall rate in pence. Null for a combination the masjid does not sell — one hall at the weekend. Immutable, so it can be used in an index or a generated column later.';

-- Backfill. Bookings taken before this had no figure against them at all.
update public.hall_bookings
   set base_amount_p = public.hall_base_amount_p(booking_date, hire_type, halls_count)
 where base_amount_p is null;


-- ---------------------------------------------------------------------------
-- 3. Set the rate when the booking is taken
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
  v_base   int;
begin
  if v_date is null then
    raise exception 'A date is required';
  end if;

  perform pg_advisory_xact_lock(hashtext('hall:' || v_date::text));

  if exists (select 1 from public.hall_availability where booking_date = v_date) then
    raise exception 'That date is no longer available. Someone is booking it, or it is already taken.'
      using errcode = 'check_violation';
  end if;

  v_base := public.hall_base_amount_p(v_date, v_type, v_count);

  v_ref := 'HH-' || to_char(now(), 'YY') || '-' ||
           lpad(nextval('public.hall_reference_seq')::text, 4, '0');

  insert into public.hall_bookings
    (reference, booking_date, hire_type, halls_count,
     first_name, last_name, address, phone,
     deposit_status, hold_expires_at, base_amount_p)
  values
    (v_ref, v_date, v_type, v_count,
     payload ->> 'first_name', payload ->> 'last_name',
     payload ->> 'address',    payload ->> 'phone',
     'awaiting', now() + interval '30 minutes', v_base);

  insert into public.admin_audit (action, detail)
  values ('hall_booking_requested', jsonb_build_object(
            'reference', v_ref, 'date', v_date,
            'hire_type', v_type, 'halls_count', v_count,
            'base_amount_p', v_base));

  return jsonb_build_object('reference', v_ref,
                            'held_until', now() + interval '30 minutes');
end;
$$;

revoke all     on function public.request_hall_booking(jsonb) from public;
grant  execute on function public.request_hall_booking(jsonb) to anon, authenticated;


-- ---------------------------------------------------------------------------
-- 4. Paying confirms it
--
-- The only change from 016 is `status = 'confirmed'` and `handled_at`. The
-- clash path is untouched and still marks the loser refund_due — that case is
-- exactly why cancel-and-refund has to keep existing.
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

  select * into b from public.hall_bookings where stripe_session_id = p_session_id;
  if found then
    return jsonb_build_object('reference', b.reference,
                              'deposit_status', b.deposit_status,
                              'status', b.status,
                              'already_recorded', true);
  end if;

  select * into b from public.hall_bookings where reference = p_reference;
  if not found then
    insert into public.admin_audit (action, detail)
    values ('deposit_for_unknown_booking',
            jsonb_build_object('reference', p_reference, 'session', p_session_id,
                               'amount_pence', p_amount_p));
    return jsonb_build_object('reference', p_reference,
                              'deposit_status', 'unmatched',
                              'already_recorded', false);
  end if;

  perform pg_advisory_xact_lock(hashtext('hall:' || b.booking_date::text));

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
                              'status', b.status,
                              'already_recorded', false);
  end if;

  -- Paid is booked. No office step, nothing for the hirer to wait for.
  update public.hall_bookings
     set deposit_status    = 'paid',
         deposit_paid_at   = now(),
         stripe_session_id = p_session_id,
         hold_expires_at   = null,
         status            = 'confirmed',
         handled_at        = now()
   where id = b.id;

  insert into public.admin_audit (action, detail)
  values ('hall_deposit_paid', jsonb_build_object(
            'reference', b.reference, 'date', b.booking_date,
            'session', p_session_id, 'amount_pence', p_amount_p,
            'confirmed', true));

  return jsonb_build_object('reference', b.reference,
                            'deposit_status', 'paid',
                            'status', 'confirmed',
                            'already_recorded', false);
end;
$$;

revoke all on function public.mark_deposit_paid(text, text, int)
  from public, anon, authenticated;

comment on function public.mark_deposit_paid(text, text, int) is
  'Records a paid deposit AND confirms the booking. Called only by the Stripe webhook, using the service role. Idempotent on the session id. A payment for a date somebody else already holds is marked refund_due instead, and audited — the money is gone and somebody has to send it back.';


-- ---------------------------------------------------------------------------
-- 5. Cancelling a booking that has been paid for
--
-- Not a Decline button. A deliberate, audited act that always returns the
-- money, for the two cases the masjid cannot design away: a second payment for
-- a date already taken, and a booking the masjid cannot in conscience host.
--
-- It does not move money — refunds are issued by a person in Stripe, where
-- the audit trail belongs. It records that one is owed, so it cannot be
-- forgotten.
-- ---------------------------------------------------------------------------
create or replace function public.cancel_paid_booking(
  p_reference text,
  p_reason    text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare b public.hall_bookings%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only a verified administrator may cancel a paid booking';
  end if;
  if p_reason is null or length(trim(p_reason)) < 10 then
    raise exception 'Give a reason of at least ten characters. It goes in the audit log and somebody will ask.';
  end if;

  select * into b from public.hall_bookings where reference = p_reference;
  if not found then
    raise exception 'No booking with reference %', p_reference;
  end if;
  if b.deposit_status not in ('paid','refund_due') then
    raise exception 'That booking has no deposit to refund — cancel it the ordinary way';
  end if;

  update public.hall_bookings
     set status         = 'cancelled',
         deposit_status = 'refund_due',
         office_notes   = coalesce(office_notes || E'\n', '') ||
                          'Cancelled by the masjid: ' || p_reason,
         handled_at     = now()
   where id = b.id;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'hall_booking_cancelled_by_masjid', jsonb_build_object(
            'reference', b.reference, 'date', b.booking_date,
            'reason', p_reason, 'refund_due_pence', 10000));

  return jsonb_build_object('reference', b.reference, 'status', 'cancelled',
                            'refund_due', true);
end;
$$;

revoke all     on function public.cancel_paid_booking(text, text) from public, anon;
grant  execute on function public.cancel_paid_booking(text, text) to authenticated;

comment on function public.cancel_paid_booking(text, text) is
  'The only way to undo a paid booking. Requires a verified administrator and a written reason, marks the deposit as owed back, and writes to admin_audit. Refunds themselves are issued by a person in Stripe.';


-- ---------------------------------------------------------------------------
-- 6. What the office may write
--
-- Gains the two balance columns and the extras. Still cannot touch the
-- reference, the Stripe session, the base rate or anything the hirer typed.
-- ---------------------------------------------------------------------------
revoke update on public.hall_bookings from authenticated;
grant  update (status, office_notes, handled_at, deposit_status,
               extras_p, balance_status, balance_paid_at)
  on public.hall_bookings to authenticated;

commit;
