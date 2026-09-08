-- ===========================================================================
--  018_nikah_fee_online.sql — paying the nikāḥ fee online
--
--  Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
--  7 September 2026
--
--  WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT
--  ---------------------------------------------
--  Migration 017 made paying the hall deposit BOOK the date. This migration
--  does NOT do the same thing for a nikāḥ, and the difference is the whole
--  point of the file.
--
--  The hall works that way because the site knows what is free: hall_bookings
--  is the diary, and hall_availability computes it. The masjid does not
--  publish its nikāḥ diary. Every day on that calendar looks identical because
--  as far as the website is concerned it IS identical — 010 has a test that
--  fails if any availability colouring ever appears there.
--
--  So a nikāḥ payment cannot buy a date. Nobody can promise a date the site
--  cannot see. What this adds is the ability to pay the fee ONLINE INSTEAD OF
--  IN CASH, once the office has rung, agreed the date, and told the family
--  what to pay. The sequence is unchanged; only the method of payment is new.
--
--  Concretely: mark_nikah_fee_paid() records money. It does not touch
--  `status`. A request that was 'new' when the fee arrived is still 'new'
--  afterwards, and the office still has to agree it.
--
--  IF YOU ARE READING THIS BECAUSE YOU WANT TO "MAKE IT CONSISTENT WITH THE
--  HALL", STOP. Making payment confirm a nikāḥ means selling dates the imam
--  may not be free for. If the masjid wants that behaviour it needs to keep
--  its nikāḥ diary in the portal first, so the site has something true to
--  publish. That is a different and much larger piece of work.
--
--  The fee is £100 for members and £200 for non-members. The website does not
--  decide which: the family picks, and the office checks on the call. The
--  amount that actually arrived is recorded, so a family who picked the wrong
--  one is visible rather than silently short.
--
--  Prerequisites: 010, 011. Idempotent.
--
--  AFTER APPLYING THIS, RE-RUN 011_require_two_step.sql.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. Columns
-- ---------------------------------------------------------------------------
alter table public.nikah_requests
  add column if not exists fee_status        text not null default 'unpaid',
  add column if not exists fee_amount_p      int,
  add column if not exists fee_paid_at       timestamptz,
  add column if not exists stripe_session_id text;

-- Added separately so re-running the file does not fall over on an existing
-- constraint, and named so it can be found.
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'nikah_fee_status_valid') then
    alter table public.nikah_requests
      add constraint nikah_fee_status_valid check (
        fee_status in ('unpaid','paid','refund_due','refunded','waived'));
  end if;
end$$;

-- The same Stripe session must never be recorded twice. This index is what
-- makes mark_nikah_fee_paid() genuinely idempotent rather than idempotent
-- as long as two retries do not arrive at once — Stripe retries in parallel
-- more often than anybody expects.
create unique index if not exists nikah_stripe_session_idx
  on public.nikah_requests(stripe_session_id)
  where stripe_session_id is not null;

comment on column public.nikah_requests.fee_status is
  'unpaid | paid | refund_due | refunded | waived. Paying does NOT confirm the request — see the header of 018.';
comment on column public.nikah_requests.fee_amount_p is
  'What actually arrived, in pence. 10000 = member rate, 20000 = non-member. Recorded rather than enforced: the family picks and the office checks.';

-- ---------------------------------------------------------------------------
--  2. Recording a payment
--
--  Reached only by the webhook, with the service role key. A browser saying
--  "I have paid" is not evidence of anything, so EXECUTE is revoked from anon
--  and authenticated at the bottom of this file.
-- ---------------------------------------------------------------------------
create or replace function public.mark_nikah_fee_paid(
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
  r public.nikah_requests%rowtype;
begin
  if p_reference is null or p_session_id is null then
    raise exception 'reference and session id are both required';
  end if;

  -- Stripe retries. Answer the retry the same way and touch nothing.
  select * into r from public.nikah_requests where stripe_session_id = p_session_id;
  if found then
    return jsonb_build_object('reference', r.reference,
                              'fee_status', r.fee_status,
                              'already_recorded', true);
  end if;

  select * into r from public.nikah_requests where reference = p_reference;
  if not found then
    -- Money taken against a reference that does not exist — a typo, or
    -- somebody who found the payment link without ever sending a request.
    --
    -- It does NOT raise. An exception would roll back the audit line written
    -- immediately below, leaving the one case that most needs a record with
    -- none; that exact bug was in the first version of mark_deposit_paid()
    -- and _test_deposit.sql caught it. A raise would also make Stripe retry
    -- for hours, and no amount of retrying will make the request appear.
    insert into public.admin_audit (action, detail)
    values ('nikah_fee_for_unknown_request',
            jsonb_build_object('reference', p_reference, 'session', p_session_id,
                               'amount_pence', p_amount_p));
    return jsonb_build_object('reference', p_reference,
                              'fee_status', 'unmatched',
                              'already_recorded', false);
  end if;

  -- A SECOND, DIFFERENT payment against the same reference. Two family
  -- members both paying is entirely ordinary, and so is somebody paying the
  -- member rate, being told they are not a member, and paying again.
  --
  -- The first version of this function overwrote stripe_session_id, which
  -- meant the earlier payment vanished from the record while Stripe still had
  -- the money. Nothing is overwritten now: the second payment is audited and
  -- the office refunds one of them. The unique index only stops the SAME
  -- session being recorded twice; it cannot see this case at all.
  if r.stripe_session_id is not null and r.stripe_session_id <> p_session_id then
    insert into public.admin_audit (action, detail)
    values ('nikah_fee_paid_twice',
            jsonb_build_object('reference', r.reference,
                               'kept_session', r.stripe_session_id,
                               'extra_session', p_session_id,
                               'extra_amount_pence', p_amount_p,
                               'already_paid_pence', r.fee_amount_p));
    return jsonb_build_object('reference', r.reference,
                              'fee_status', r.fee_status,
                              'already_recorded', false,
                              'duplicate_payment', true);
  end if;

  -- Paid for a date the masjid has already said no to. Stripe has the money
  -- either way, so the only honest thing is to record that it must go back.
  -- The office sees 'refund due' in the portal until a human sends it.
  if r.status in ('declined','withdrawn') then
    update public.nikah_requests
       set fee_status        = 'refund_due',
           fee_amount_p      = coalesce(p_amount_p, fee_amount_p),
           fee_paid_at       = now(),
           stripe_session_id = p_session_id
     where id = r.id;

    insert into public.admin_audit (action, detail)
    values ('nikah_fee_needs_refund',
            jsonb_build_object('reference', r.reference, 'session', p_session_id,
                               'amount_pence', p_amount_p, 'status', r.status));

    return jsonb_build_object('reference', r.reference,
                              'fee_status', 'refund_due',
                              'already_recorded', false);
  end if;

  -- The ordinary case. Note what is NOT in this UPDATE: `status`. The office
  -- agrees a nikāḥ date; a payment does not. See the file header.
  update public.nikah_requests
     set fee_status        = 'paid',
         fee_amount_p      = coalesce(p_amount_p, fee_amount_p),
         fee_paid_at       = now(),
         stripe_session_id = p_session_id
   where id = r.id;

  insert into public.admin_audit (action, detail)
  values ('nikah_fee_paid',
          jsonb_build_object('reference', r.reference, 'session', p_session_id,
                             'amount_pence', p_amount_p, 'status', r.status));

  return jsonb_build_object('reference', r.reference,
                            'fee_status', 'paid',
                            'already_recorded', false);
end$$;

comment on function public.mark_nikah_fee_paid(text, text, int) is
  'Records a nikāḥ fee paid through Stripe. Idempotent on the session id. Deliberately does NOT change status — paying does not agree a date. Webhook only: EXECUTE is revoked from anon and authenticated.';

-- ---------------------------------------------------------------------------
--  3. What the office may write
--
--  010 granted six columns. The office now also needs to record a fee — not
--  only one paid through Stripe, but one handed over in cash or sent by bank
--  transfer, which is still how most of them will arrive.
--
--  Re-granted from scratch rather than added to, because `grant update (a, b)`
--  is additive and there is no way to read back "the set of columns that are
--  granted" at a glance. Revoking first makes this file the single statement
--  of what the office may change.
-- ---------------------------------------------------------------------------
revoke update on public.nikah_requests from authenticated;
grant  update (status, agreed_date, agreed_time, office_notes,
               reviewed_by, reviewed_at,
               fee_status, fee_amount_p, fee_paid_at)
  on public.nikah_requests to authenticated;

-- Not stripe_session_id. That is the webhook's record of which payment this
-- was, and the office being able to edit it would break the idempotency the
-- unique index above provides.

commit;

-- ---------------------------------------------------------------------------
--  4. Who may call the function
--
--  Outside the transaction so that a failure here cannot roll back the fix
--  above — the same reason 015 schedules its cron jobs after its commit.
-- ---------------------------------------------------------------------------
revoke all on function public.mark_nikah_fee_paid(text, text, int) from public;
revoke all on function public.mark_nikah_fee_paid(text, text, int) from anon, authenticated;

-- ===========================================================================
--  REMINDER: re-run 011_require_two_step.sql now.
-- ===========================================================================
