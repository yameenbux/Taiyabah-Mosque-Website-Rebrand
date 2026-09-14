-- ===========================================================================
--  031_dashboard_charity.sql — the charity collection reaches the dashboard
--
--  14 September 2026. 030 created the table; this is what puts it in front of
--  anybody. Without it the requests arrive and sit there, and the Admin
--  Centre carries on saying nothing is waiting — which is worse than not
--  having built the form, because somebody has travelled to Bolton on the
--  strength of it.
--
--  These three functions are 024's, verbatim, with four additions:
--
--    *  audit_kind knows a collection request came from the public, not the
--       office, so the log attributes it to "from the website".
--    *  audit_sentence says "Charity collection requested" rather than
--       falling through to the generic title-case fallback.
--    *  NEEDS YOU gains a row per unanswered request, carrying the org name,
--       the date, and — in capitals — whether the collector is PAID.
--    *  AREAS gains a collections tile: new, approved and upcoming, and a
--       separate count of paid collectors still open.
--
--  Run AFTER 030. Re-run 011_require_two_step.sql afterwards.
-- ===========================================================================

begin;

create or replace function public.audit_kind(p_action text)
returns text
language sql
immutable
as $$
  select case
    when p_action like '%_purged'
      or p_action like 'digest%'
      or p_action like '%_repaired'      then 'auto'
    when p_action in ('hall_booking_requested', 'nikah_request',
                      'charity_collection_request',
                      'course_registration', 'donation_paid',
                      'admission_application', 'gift_aid_incomplete',
                      'gift_aid_field_missing')                then 'public'
    else 'staff'
  end
$$;


create or replace function public.audit_sentence(p_action text, p_detail jsonb)
returns text
language sql
immutable
as $$
  select case p_action
    when 'hall_booking_requested'  then 'Hall booking came in'
    when 'nikah_request'           then 'Nikah date requested'
    when 'charity_collection_request'
                                   then 'Charity collection requested'
    when 'charity_collection_status'
                                   then 'Collection marked ' ||
                                        coalesce(p_detail->>'status', 'updated')
    when 'charity_collections_purged'
                                   then 'Old collection requests deleted'
    when 'course_registration'     then 'Someone signed up for a class'
    when 'donation_paid'           then 'Donation received'
    when 'volunteer_status'        then 'Volunteer marked ' ||
                                        coalesce(p_detail->>'status', 'updated')
    when 'gift_aid_claimed'        then 'Gift Aid claim marked filed' ||
                                        coalesce(' - ' || (p_detail->>'count') || ' donations', '')
    when 'cash_deposit_recorded'   then 'Deposit taken in cash'
    when 'booking_cancelled'       then 'Booking cancelled and refunded'
    when 'hall_holds_purged'       then 'Expired holds cleared'
    when 'donations_purged'        then 'Old donation records deleted'
    when 'volunteers_purged'       then 'Old volunteer records deleted'
    when 'hall_confirmed_without_payment_repaired'
                                   then 'A booking with no deposit was put back'
    else replace(initcap(replace(p_action, '_', ' ')), ' Id', ' ID')
  end
$$;


create or replace function public.admin_dashboard()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin  boolean := public.verified_admin();
  v_office boolean := public.verified_office();
  v_out    jsonb;
  v_needs  jsonb := '[]'::jsonb;
  v_owed_p bigint;
  v_owed_n int;
  v_owed_unknown int;
begin
  if not (v_admin or v_office) then
    return jsonb_build_object('allowed', false);
  end if;

  -- -----------------------------------------------------------------------
  --  NEEDS YOU. Only things a person has to act on, newest problem first.
  --  Deliberately NOT "everything that is not finished" — a dashboard that
  --  lists work nobody has to do today is a dashboard people stop reading.
  -- -----------------------------------------------------------------------

  --  A hall held with no deposit and minutes left on the clock. First
  --  because it expires: after the hold runs out the date is released and
  --  the hirer has to start again.
  select coalesce(jsonb_agg(x order by x->>'sort'), '[]'::jsonb) into v_needs
  from (
    select jsonb_build_object(
             'kind',    'hall_hold',
             'urgency', 'now',
             'ref',     reference,
             'title',   'Hall held, deposit not paid',
             'detail',  btrim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')) ||
                        ' - ' || to_char(booking_date, 'Dy DD Mon'),
             'expires_at', hold_expires_at,
             'where',   'venue',
             'sort',    '1' || to_char(hold_expires_at, 'YYYYMMDDHH24MISS')) as x
      from public.hall_bookings
     where deposit_status = 'awaiting'
       and hold_expires_at > now()
       and status = 'new'

    union all

    --  A booking the public sent in that nobody has answered.
    select jsonb_build_object(
             'kind',    'hall_new',
             'urgency', 'soon',
             'ref',     reference,
             'title',   'Hall request waiting for an answer',
             'detail',  btrim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')) ||
                        ' - ' || to_char(booking_date, 'Dy DD Mon') ||
                        ' - ' || coalesce(phone, 'no number'),
             'since',   created_at,
             'where',   'venue',
             'sort',    '2' || to_char(created_at, 'YYYYMMDDHH24MISS'))
      from public.hall_bookings
     where status = 'new'
       and deposit_status <> 'awaiting'

    union all

    select jsonb_build_object(
             'kind',    'nikah_new',
             'urgency', 'soon',
             'ref',     reference,
             'title',   'Nikah date needs a call',
             'detail',  coalesce(contact_name, 'no name') ||
                        ' - ' || coalesce(contact_phone, 'no number'),
             'since',   submitted_at,
             'where',   'venue',
             'sort',    '3' || to_char(submitted_at, 'YYYYMMDDHH24MISS'))
      from public.nikah_requests
     where status = 'new'

    union all

    --  A charity collection nobody has answered. Sorted after nikah and
    --  before volunteers: somebody has usually travelled a long way and is
    --  waiting to be told yes or no, but nothing expires if it waits a day.
    select jsonb_build_object(
             'kind',    'charity_new',
             'urgency', 'soon',
             'ref',     reference,
             'title',   'Charity collection waiting for an answer',
             'detail',  org_name || ' - ' || to_char(requested_date, 'Dy DD Mon') ||
                        case when collector_paid then ' - COLLECTOR IS PAID' else '' end,
             'since',   submitted_at,
             'where',   'collections',
             'sort',    '35' || to_char(submitted_at, 'YYYYMMDDHH24MISS'))
      from public.charity_collections
     where status = 'new'

    union all

    --  Volunteers are ONE row however many are waiting: six people to ring is
    --  one job, and six identical cards would push everything else off the
    --  screen.
    select jsonb_build_object(
             'kind',    'volunteers',
             'urgency', 'soon',
             'ref',     null,
             'title',   count(*) || ' food bank volunteer' ||
                        case when count(*) = 1 then '' else 's' end || ' not yet rung',
             'detail',  count(*) filter (where sunday_mornings) || ' free Sunday mornings',
             'where',   'volunteers',
             'sort',    '4')
      from public.foodbank_volunteers
     where status = 'waiting'
    having count(*) > 0

    union all

    --  Admin only: Gift Aid is a list of donors' names and home addresses.
    select jsonb_build_object(
             'kind',    'giftaid',
             'urgency', 'later',
             'ref',     null,
             'title',   'Gift Aid ready to claim',
             'detail',  count(*) || ' donations - about ' ||
                        to_char(round(sum(amount_p) * 0.25 / 100.0), 'FM999,999') || ' pounds',
             'where',   'giftaid',
             'sort',    '5')
      from public.donations
     where v_admin
       and gift_aid and status = 'paid' and claimed_at is null
    having count(*) > 0
  ) q;

  -- -----------------------------------------------------------------------
  --  MONEY OWED — and the bookings it cannot be worked out for
  --
  --  A booking taken under the old session rates has no base_amount_p. The
  --  venue portal already refuses to invent a figure for one. Summing it as
  --  zero here would quietly UNDERSTATE what the masjid is owed on its own
  --  dashboard, so the ones that cannot be priced are counted separately and
  --  shown separately.
  -- -----------------------------------------------------------------------
  select coalesce(sum(
           greatest((base_amount_p + coalesce(extras_p, 0))
                    - case when deposit_status = 'paid' then 10000 else 0 end, 0)), 0),
         count(*)
    into v_owed_p, v_owed_n
    from public.hall_bookings
   where status = 'confirmed'
     and coalesce(balance_status, 'unpaid') not in ('paid', 'waived')
     and booking_date >= current_date
     and base_amount_p is not null;

  select count(*) into v_owed_unknown
    from public.hall_bookings
   where status = 'confirmed'
     and coalesce(balance_status, 'unpaid') not in ('paid', 'waived')
     and booking_date >= current_date
     and base_amount_p is null;

  v_out := jsonb_build_object(
    'allowed', true,
    'as_at',   now(),
    'is_admin', v_admin,
    'needs',   v_needs,

    'estate', jsonb_build_object(
      'bookings_ahead', (select count(*) from public.hall_bookings
                          where status = 'confirmed' and booking_date >= current_date),
      'next_booking',   (select min(booking_date) from public.hall_bookings
                          where status = 'confirmed' and booking_date >= current_date),
      'owed_p',         v_owed_p,
      'owed_count',     v_owed_n,
      'owed_unknown',   v_owed_unknown,
      'volunteers',     (select count(*) from public.foodbank_volunteers
                          where status <> 'withdrawn'),
      'volunteers_sun', (select count(*) from public.foodbank_volunteers
                          where status <> 'withdrawn' and sunday_mornings),
      'class_places',   (select count(*) from public.course_registrations
                          where status not in ('withdrawn', 'no_show')),
      'class_waiting',  (select count(*) from public.course_registrations
                          where status = 'waiting')),

    'areas', jsonb_build_object(
      'venue', jsonb_build_object(
        'new',      (select count(*) from public.hall_bookings where status = 'new')
                  + (select count(*) from public.nikah_requests where status = 'new'),
        'upcoming', (select count(*) from public.hall_bookings
                      where status = 'confirmed' and booking_date >= current_date),
        'holding',  (select count(*) from public.hall_bookings
                      where deposit_status = 'awaiting' and hold_expires_at > now()),
        'balance',  v_owed_n + v_owed_unknown),
      'courses', case when v_admin then jsonb_build_object(
        'open',     (select count(*) from public.courses where is_open),
        'signed',   (select count(*) from public.course_registrations
                      where status not in ('withdrawn', 'no_show')),
        'waiting',  (select count(*) from public.course_registrations
                      where status = 'waiting')) else null end,
      'giftaid', case when v_admin then jsonb_build_object(
        'to_claim', (select count(*) from public.donations
                      where gift_aid and status = 'paid' and claimed_at is null),
        'worth_p',  (select coalesce(round(sum(amount_p) * 0.25), 0) from public.donations
                      where gift_aid and status = 'paid' and claimed_at is null),
        'incomplete', (select count(*) from public.admin_audit
                        where action = 'gift_aid_incomplete'
                          and at > now() - interval '90 days')) else null end,
      'collections', jsonb_build_object(
        'new',      (select count(*) from public.charity_collections
                      where status = 'new'),
        'upcoming', (select count(*) from public.charity_collections
                      where status = 'approved'
                        and coalesce(agreed_date, requested_date) >= current_date),
        --  Paid collectors still open. Counted separately because it is the
        --  one figure on this screen somebody may need to act on for a
        --  reason that is not administrative.
        'paid',     (select count(*) from public.charity_collections
                      where collector_paid
                        and status in ('new','contacted','approved'))),
      'volunteers', jsonb_build_object(
        'willing',  (select count(*) from public.foodbank_volunteers
                      where status <> 'withdrawn'),
        'sundays',  (select count(*) from public.foodbank_volunteers
                      where status <> 'withdrawn' and sunday_mornings),
        'to_ring',  (select count(*) from public.foodbank_volunteers
                      where status = 'waiting'))),

    -- ---------------------------------------------------------------------
    --  THE LOG. People and the public only; the machine's work is counted,
    --  not listed. See section 1.
    -- ---------------------------------------------------------------------
    'log', (select coalesce(jsonb_agg(r order by r_at desc), '[]'::jsonb)
              from (select jsonb_build_object(
                             'at',   a.at,
                             'kind', public.audit_kind(a.action),
                             'what', public.audit_sentence(a.action, a.detail),
                             'ref',  coalesce(a.detail->>'reference', a.detail->>'ref'),
                             'who',  case when public.audit_kind(a.action) = 'public'
                                          then 'from the website'
                                          else coalesce(p.full_name, 'the office') end) as r,
                           a.at as r_at
                      from public.admin_audit a
                      left join public.profiles p on p.id = a.actor
                     where a.at > now() - interval '7 days'
                       and public.audit_kind(a.action) <> 'auto'
                     order by a.at desc
                     limit 12) s),

    'auto_count', (select count(*) from public.admin_audit
                    where at > now() - interval '7 days'
                      and public.audit_kind(action) = 'auto'),

    -- ---------------------------------------------------------------------
    --  HOUSEKEEPING. The one standing warning on this site is a staff account
    --  with no authenticator: while one exists, 011 cannot be re-run, which
    --  blocks every future migration. It has been invisible until now.
    -- ---------------------------------------------------------------------
    'housekeeping', case when v_admin then jsonb_build_object(
      'accounts',   (select count(*) from public.profiles),
      'admins',     (select count(*) from public.user_roles where role = 'admin'),
      'no_2fa',     (select count(distinct ur.user_id) from public.user_roles ur
                      where not exists (select 1 from auth.mfa_factors f
                                         where f.user_id = ur.user_id
                                           and f.status = 'verified')),
      'last_holds', (select max(at) from public.admin_audit where action = 'hall_holds_purged'),
      'last_purge', (select max(at) from public.admin_audit where action like '%_purged'
                      and action <> 'hall_holds_purged')) else null end
  );

  return v_out;
end $$;

commit;
