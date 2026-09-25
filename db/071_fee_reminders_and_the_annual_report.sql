-- ===========================================================================
--  071_fee_reminders_and_the_annual_report.sql
--  20 September 2026
--
--  THE EMAIL THE MASJID ASKED FOR, AND THE FIGURES THE TRUSTEES NEED.
--
--  ---------------------------------------------------------------------------
--  A FEE REMINDER IS THE FIRST EMAIL THIS SYSTEM SENDS TO SOMEBODY WHO DID
--  NOT JUST FILL A FORM IN
--  ---------------------------------------------------------------------------
--
--  Every other message the notify function sends is a receipt. Somebody
--  booked a hall or applied for a place, and a message comes back about the
--  thing they just did. 019's header leans on that: it is why there is no
--  unsubscribe link anywhere in this system, and the argument holds.
--
--  A fee reminder is different in kind. It is unsolicited, it is about money,
--  it goes to a list, and it is sent because somebody pressed a button. That
--  is close enough to bulk email to be worth being careful about, so:
--
--    * It is still not marketing, and no unsubscribe is offered. A bill is
--      not something a parent can opt out of receiving, and offering it would
--      be a promise the masjid cannot keep.
--    * ONE REMINDER PER FAMILY PER SEVEN DAYS, enforced here and not in the
--      screen. The failure this prevents is not annoyance, it is the office
--      pressing the button twice because the first press was slow.
--    * It goes ONLY to the one guardian marked primary. 068 made that exactly
--      one person per family for this reason.
--    * IT NEVER NAMES A CHILD. The email says what the family owes and quotes
--      the family reference. Email is not a secure channel, madrasah
--      attendance is Article 9 data about a child's religion, and a line like
--      "Yusuf — Autumn term" in a message forwarded round a family WhatsApp
--      is a disclosure the masjid did not have to make. The amount and the
--      reference are enough for the parent to act.
--    * Nothing is sent to a family who does not owe anything, even if the
--      screen asks. Checked here, at the moment of sending, against the
--      balance as it is then — not against what the screen was showing when
--      somebody ticked the box five minutes ago.
--
--  ---------------------------------------------------------------------------
--  WHAT IS LOGGED, AND WHAT IS DELIBERATELY NOT
--  ---------------------------------------------------------------------------
--
--  A reminder log records the family, the time, and the balance at the time.
--  It does NOT record the email address. The address is on the guardian
--  record, on the retention clock, and copying it into a log that outlives
--  that record would quietly defeat the retention period — which is the same
--  reasoning the notify function already applies when it writes "office" or
--  "hirer" into an audit row instead of the address.
--
--  Prerequisites: 068, 069, 070. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. The log lives in 070
--
--  It was created here, and madrasah_fee_balances() in 070 reads it — a
--  forward reference that plpgsql does not resolve until the function runs,
--  so 070 applied cleanly on its own and then failed at the first press of a
--  button with "relation madrasah_fee_reminders does not exist". The table
--  moved to the file that first needs it rather than being guarded, because a
--  guard would have been a second thing to keep right.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
--  2. Sending
--
--  Takes a list of families, returns what happened to each. Every outcome is
--  recorded, including the ones where nothing was sent, because "I ticked 40
--  and 31 went" needs an answer for the other nine and the office should not
--  have to work it out.
-- ---------------------------------------------------------------------------
create or replace function public.send_madrasah_fee_reminders(p_households uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid  uuid := public.current_masjid();
  v_url     text;
  v_secret  text;
  v_key     text;
  v_subject text;
  v_body    text;
  v_h       uuid;
  v_ref     text;
  v_name    text;
  v_email   text;
  v_bal     bigint;
  v_last    timestamptz;
  v_sent    int := 0;
  v_no      int := 0;
  v_soon    int := 0;
  v_clear   int := 0;
  v_out     jsonb := '[]'::jsonb;
  v_reason  text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may send reminders.'
      using errcode = '42501';
  end if;
  if p_households is null or array_length(p_households, 1) is null then
    return jsonb_build_object('sent', 0, 'results', '[]'::jsonb);
  end if;

  --  A CAP, BECAUSE THIS IS THE ONE BUTTON THAT CAN DO SOMETHING THE MASJID
  --  CANNOT TAKE BACK. Three hundred emails leave in a few seconds and there
  --  is no recalling one. If a genuine run is bigger than this, it goes in
  --  two presses and somebody sees the first result before the second.
  if array_length(p_households, 1) > 120 then
    raise exception 'That is % families in one go. Send at most 120 at a time — an email cannot be unsent.',
      array_length(p_households, 1) using errcode = 'check_violation';
  end if;

  select value into v_url from public.app_settings where key = 'notify_url';
  select value into v_secret from public.app_settings where key = 'notify_secret';
  select value into v_key from public.app_settings where key = 'notify_key';
  if v_url is null or v_secret is null then
    raise exception 'Email is not set up yet, so nothing was sent. Nobody has been contacted.'
      using errcode = 'check_violation';
  end if;

  select coalesce(value #>> '{}', '') into v_subject
    from public.madrasah_fee_settings where masjid_id = v_masjid and key = 'reminder_subject';
  select coalesce(value #>> '{}', '') into v_body
    from public.madrasah_fee_settings where masjid_id = v_masjid and key = 'reminder_body';

  foreach v_h in array p_households loop
    v_reason := null;

    select h.reference, h.name into v_ref, v_name
      from public.madrasah_households h
     where h.id = v_h and h.masjid_id = v_masjid;
    if v_ref is null then
      continue;                       -- not this masjid's family; say nothing
    end if;

    select coalesce((select sum(net_p) from public.madrasah_charges where household_id = v_h), 0)
         - coalesce((select sum(amount_p) from public.madrasah_payments where household_id = v_h), 0)
      into v_bal;

    select g.email into v_email
      from public.madrasah_guardians g
     where g.household_id = v_h and g.is_primary and g.email is not null;

    select max(sent_at) into v_last
      from public.madrasah_fee_reminders
     where household_id = v_h and outcome = 'sent';

    if v_bal <= 0 then
      v_reason := 'nothing_owed'; v_clear := v_clear + 1;
    elsif v_email is null then
      v_reason := 'no_contact';   v_no := v_no + 1;
    elsif v_last is not null and v_last > now() - interval '7 days' then
      v_reason := 'too_soon';     v_soon := v_soon + 1;
    end if;

    if v_reason is not null then
      insert into public.madrasah_fee_reminders (masjid_id, household_id, sent_by, balance_p, outcome)
      values (v_masjid, v_h, auth.uid(), least(greatest(v_bal, -2147483648), 2147483647), v_reason);
      v_out := v_out || jsonb_build_object('id', v_h, 'name', v_name, 'outcome', v_reason);
      continue;
    end if;

    --  THE MESSAGE CARRIES NO CHILD'S NAME. See the header.
    perform net.http_post(
      url     := v_url,
      body    := jsonb_build_object(
                   'kind',        'madrasah_fee_reminder',
                   --  'email', not 'to'. The notify function sends a public
                   --  message to event.email and nowhere else; inventing a
                   --  second field name here would have meant a POST that
                   --  succeeded, logged "sent", and wrote to nobody.
                   'email',       v_email,
                   'family',      v_name,
                   'reference',   v_ref,
                   'balance_p',   v_bal,
                   'subject',     nullif(v_subject, ''),
                   'body',        nullif(v_body, ''),
                   'card_link',   (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'card_link'),
                   'bank_name',   (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'bank_name'),
                   'bank_account_name',
                                  (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'bank_account_name'),
                   'bank_sort',   (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'bank_sort_code'),
                   'bank_number', (select value #>> '{}' from public.madrasah_fee_settings
                                    where masjid_id = v_masjid and key = 'bank_account_number')),
      headers := jsonb_build_object(
                   'content-type',    'application/json',
                   'authorization',   'Bearer ' || coalesce(v_key, ''),
                   'x-notify-secret', v_secret));

    --  'sent' HERE MEANS "HANDED TO THE MAIL SERVER", AND NOTHING STRONGER.
    --  net.http_post is fire-and-forget: it queues the request and returns an
    --  id, so this function cannot know whether the message was accepted, let
    --  alone delivered. one.com gives no bounce reporting either — the notify
    --  function's own header says so. The 'failed' outcome is in the
    --  constraint for a future in which something can write it; today nothing
    --  can, and pretending otherwise on the screen would be worse than
    --  saying so. The Outstanding screen reports it as "Handed to the mail
    --  server" for that reason.
    insert into public.madrasah_fee_reminders (masjid_id, household_id, sent_by, balance_p, outcome)
    values (v_masjid, v_h, auth.uid(), least(greatest(v_bal, -2147483648), 2147483647), 'sent');

    v_sent := v_sent + 1;
    v_out  := v_out || jsonb_build_object('id', v_h, 'name', v_name, 'outcome', 'sent');
  end loop;

  --  THE AUDIT COUNTS, IT DOES NOT LIST. Who pressed it, how many went, and
  --  how many did not — not three hundred family ids in a row that is kept
  --  longer than the families are.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_fee_reminders_sent',
          jsonb_build_object('sent', v_sent, 'no_contact', v_no,
                             'too_soon', v_soon, 'nothing_owed', v_clear));

  return jsonb_build_object('sent', v_sent, 'no_contact', v_no,
                            'too_soon', v_soon, 'nothing_owed', v_clear,
                            'results', v_out);
end $fn$;

-- ---------------------------------------------------------------------------
--  3. The landing screen
--
--  Counts only. 066's rule, which that file learned the hard way: a tile that
--  reads "0 unpaid" when nothing collects fees is not neutral, it is wrong.
--  So every figure here is computed from rows that exist, and the screen is
--  told what has NOT been set up yet so it can say so instead of showing a
--  confident zero.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_fees_overview()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_owed   bigint;
  v_credit bigint;
  v_fams   int;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the fees overview.'
      using errcode = '42501';
  end if;

  select coalesce(sum(case when bal > 0 then bal else 0 end), 0),
         coalesce(sum(case when bal < 0 then -bal else 0 end), 0),
         count(*) filter (where bal > 0)
    into v_owed, v_credit, v_fams
    from (
      select h.id,
             coalesce((select sum(net_p) from public.madrasah_charges c where c.household_id = h.id), 0)
           - coalesce((select sum(amount_p) from public.madrasah_payments y where y.household_id = h.id), 0)
             as bal
        from public.madrasah_households h
       where h.masjid_id = v_masjid) s;

  return jsonb_build_object(
    'as_at', now(),

    --  Money
    'outstanding_p',        v_owed,
    'in_credit_p',          v_credit,
    'families_owing',       v_fams,
    --  kind = 'payment' ONLY, so that this tile and the annual report's
    --  "Received" mean the same thing. They did not: this summed amount_p
    --  with no filter, so a refund netted off here and did not there, and the
    --  two screens disagreed the moment anybody was refunded. Refunds are
    --  reported on their own line below rather than hidden inside a total.
    'received_30_days_p',   coalesce((select sum(amount_p) from public.madrasah_payments
                                       where masjid_id = v_masjid and kind = 'payment'
                                         and received_on >= current_date - 30), 0),
    'received_7_days_p',    coalesce((select sum(amount_p) from public.madrasah_payments
                                       where masjid_id = v_masjid and kind = 'payment'
                                         and received_on >= current_date - 7), 0),
    'refunded_30_days_p',   coalesce((select -sum(amount_p) from public.madrasah_payments
                                       where masjid_id = v_masjid and kind = 'refund'
                                         and received_on >= current_date - 30), 0),
    'charged_total_p',      coalesce((select sum(net_p) from public.madrasah_charges
                                       where masjid_id = v_masjid), 0),
    'waived_total_p',       coalesce((select sum(waived_p) from public.madrasah_charges
                                       where masjid_id = v_masjid), 0),

    --  Families
    'families',             (select count(*) from public.madrasah_households where masjid_id = v_masjid),
    --  The PRIMARY contact's email, matching what the sender actually uses.
    'families_no_contact',  (select count(*) from public.madrasah_households h
                              where h.masjid_id = v_masjid
                                and not exists (select 1 from public.madrasah_guardians g
                                                 where g.household_id = h.id
                                                   and g.is_primary
                                                   and g.email is not null)),
    'pupils_no_family',     (select count(*) from public.madrasah_pupils
                              where masjid_id = v_masjid and left_on is null and household_id is null),
    'pupils',               (select count(*) from public.madrasah_pupils
                              where masjid_id = v_masjid and left_on is null),

    --  What has and has not been set up. The screen needs these to tell the
    --  difference between "nothing is owed" and "nothing has been charged".
    'has_default_rate',  exists (select 1 from public.madrasah_fee_rates
                                  where masjid_id = v_masjid and is_default and active),
    'rates_confirmed',   exists (select 1 from public.madrasah_fee_settings
                                  where masjid_id = v_masjid and key = 'rates_confirmed_on'),
    'has_bank_details',  exists (select 1 from public.madrasah_fee_settings
                                  where masjid_id = v_masjid and key = 'bank_account_number'
                                    and coalesce(value #>> '{}', '') <> ''),
    'has_card_link',     exists (select 1 from public.madrasah_fee_settings
                                  where masjid_id = v_masjid and key = 'card_link'
                                    and coalesce(value #>> '{}', '') <> ''),
    'open_period',       (select jsonb_build_object('id', t.id, 'name', t.name,
                                                    'status', t.status, 'weeks', t.weeks)
                            from public.madrasah_fee_periods t
                           where t.masjid_id = v_masjid and t.status <> 'closed'
                           order by t.starts_on desc limit 1),
    'periods',           (select count(*) from public.madrasah_fee_periods where masjid_id = v_masjid),

    --  The five most recent receipts, for the "money is arriving" strip.
    'recent', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', y.id, 'received_on', y.received_on, 'amount_p', y.amount_p,
               'method', y.method, 'kind', y.kind,
               'family', h.name, 'reference', h.reference)
             order by y.received_on desc, y.created_at desc)
        from (select * from public.madrasah_payments
               where masjid_id = v_masjid
               order by received_on desc, created_at desc limit 5) y
        join public.madrasah_households h on h.id = y.household_id), '[]'::jsonb)
  );
end $fn$;

-- ---------------------------------------------------------------------------
--  4. The annual report
--
--  What the trustees are asked at the AGM, and what feeds the charity's
--  annual return. Charged, collected, outstanding, discounted and written
--  off, broken down by term, over a date range the screen chooses.
--
--  CHARGED AND COLLECTED ARE COUNTED ON DIFFERENT DATES AND THE REPORT SAYS
--  SO. A charge belongs to the day it was raised; a payment to the day the
--  money arrived. They will not match, and a report that quietly implies they
--  should is one a treasurer will spend an evening trying to reconcile.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_fee_annual_report(
  p_from date default null, p_to date default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_from   date := coalesce(p_from, date_trunc('year', current_date)::date);
  v_to     date := coalesce(p_to, current_date);
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the annual report.'
      using errcode = '42501';
  end if;
  if v_to < v_from then
    raise exception 'The end of the period is before the start of it.' using errcode = 'check_violation';
  end if;

  return jsonb_build_object(
    'from', v_from, 'to', v_to, 'generated_at', now(),

    'gross_p',    coalesce((select sum(gross_p)    from public.madrasah_charges
                             where masjid_id = v_masjid and charged_on between v_from and v_to), 0),
    'discount_p', coalesce((select sum(discount_p) from public.madrasah_charges
                             where masjid_id = v_masjid and charged_on between v_from and v_to), 0),
    'waived_p',   coalesce((select sum(waived_p)   from public.madrasah_charges
                             where masjid_id = v_masjid and charged_on between v_from and v_to), 0),
    'charged_p',  coalesce((select sum(net_p)      from public.madrasah_charges
                             where masjid_id = v_masjid and charged_on between v_from and v_to), 0),

    'received_p', coalesce((select sum(amount_p) from public.madrasah_payments
                             where masjid_id = v_masjid and kind = 'payment'
                               and received_on between v_from and v_to), 0),
    'refunded_p', coalesce((select -sum(amount_p) from public.madrasah_payments
                             where masjid_id = v_masjid and kind = 'refund'
                               and received_on between v_from and v_to), 0),

    'by_method', coalesce((
      select jsonb_agg(jsonb_build_object('method', m.method, 'amount_p', m.total, 'count', m.n)
                       order by m.total desc)
        from (select method, sum(amount_p)::bigint as total, count(*) as n
                from public.madrasah_payments
               where masjid_id = v_masjid and received_on between v_from and v_to
               group by method) m), '[]'::jsonb),

    --  THE BREAKDOWN HAS TO ADD UP TO THE TOTAL PRINTED UNDER IT.
    --
    --  It did not. Each term summed ALL of its charges while the headline
    --  figures were filtered to the date range, and charges belonging to no
    --  term at all — every admission fee and every balance brought forward,
    --  because add_madrasah_charge() sets no period — appeared in the total
    --  and in no row. A trustee adding up a column and getting a different
    --  answer from the line beneath it is the fastest way to lose their
    --  confidence in the whole report.
    --
    --  So: every row is filtered by charged_on exactly as the headline is,
    --  and anything with no term gets a row of its own.
    'by_period', coalesce((
      select jsonb_agg(x order by x->>'starts_on' desc nulls last)
        from (
          select jsonb_build_object(
                   'id', t.id, 'name', t.name, 'starts_on', t.starts_on,
                   'status', t.status, 'weeks', t.weeks,
                   'pupils',    count(c.id),
                   'gross_p',   coalesce(sum(c.gross_p), 0),
                   'discount_p',coalesce(sum(c.discount_p), 0),
                   'waived_p',  coalesce(sum(c.waived_p), 0),
                   'charged_p', coalesce(sum(c.net_p), 0)) as x
            from public.madrasah_fee_periods t
            join public.madrasah_charges c
              on c.period_id = t.id and c.charged_on between v_from and v_to
           where t.masjid_id = v_masjid
           group by t.id, t.name, t.starts_on, t.status, t.weeks

          union all

          select jsonb_build_object(
                   'id', null, 'name', 'Not against a term', 'starts_on', null,
                   'status', null, 'weeks', null,
                   'pupils',    count(*),
                   'gross_p',   coalesce(sum(gross_p), 0),
                   'discount_p',coalesce(sum(discount_p), 0),
                   'waived_p',  coalesce(sum(waived_p), 0),
                   'charged_p', coalesce(sum(net_p), 0))
            from public.madrasah_charges
           where masjid_id = v_masjid and period_id is null
             and charged_on between v_from and v_to
          having count(*) > 0
        ) s), '[]'::jsonb),

    --  Outstanding is AS AT NOW, not as at the end of the range, and the
    --  screen says so. A historic balance would need a point-in-time
    --  reconstruction this system does not keep the data for, and a figure
    --  labelled as something it is not is worse than an absent one.
    'outstanding_now_p', coalesce((
      select sum(bal) from (
        select coalesce((select sum(net_p) from public.madrasah_charges c where c.household_id = h.id), 0)
             - coalesce((select sum(amount_p) from public.madrasah_payments y where y.household_id = h.id), 0) as bal
          from public.madrasah_households h where h.masjid_id = v_masjid) s
       where bal > 0), 0),

    'waivers', coalesce((
      select jsonb_agg(jsonb_build_object(
               'family', h.name, 'reference', h.reference,
               'waived_p', c.waived_p, 'why', c.waiver_note, 'charged_on', c.charged_on)
             order by c.waived_p desc)
        from public.madrasah_charges c
        join public.madrasah_households h on h.id = c.household_id
       where c.masjid_id = v_masjid and c.waived_p > 0
         and c.charged_on between v_from and v_to), '[]'::jsonb)
  );
end $fn$;


-- ---------------------------------------------------------------------------
--  5. Money recently recorded, and fees written off
--
--  Two lists that three screens need. They are here rather than being
--  assembled in the browser from madrasah_fee_balances(), because a screen
--  that builds its own version of a list is a screen that can disagree with
--  the report about what happened.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_recent_payments(
  p_limit integer default 50, p_kind text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_n      integer := least(greatest(coalesce(p_limit, 50), 1), 500);
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see what has been received.'
      using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', y.id, 'received_on', y.received_on, 'kind', y.kind,
             'method', y.method, 'amount_p', y.amount_p,
             'bank_reference', y.bank_reference, 'note', y.note,
             'family', h.name, 'reference', h.reference,
             'household_id', h.id)
           order by y.received_on desc, y.created_at desc)
      from (select * from public.madrasah_payments
             where masjid_id = v_masjid
               and (p_kind is null or kind = p_kind)
             order by received_on desc, created_at desc
             limit v_n) y
      join public.madrasah_households h on h.id = y.household_id), '[]'::jsonb);
end $fn$;

create or replace function public.madrasah_waivers()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see what has been written off.'
      using errcode = '42501';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'family', h.name, 'reference', h.reference,
             'household_id', h.id, 'description', c.description,
             'why', c.waiver_note, 'charged_on', c.charged_on,
             'gross_p', c.gross_p, 'waived_p', c.waived_p, 'net_p', c.net_p)
           order by c.charged_on desc, c.waived_p desc)
      from public.madrasah_charges c
      join public.madrasah_households h on h.id = c.household_id
     where c.masjid_id = v_masjid and c.waived_p > 0), '[]'::jsonb);
end $fn$;

grant execute on function public.send_madrasah_fee_reminders(uuid[])         to authenticated;
grant execute on function public.madrasah_recent_payments(integer, text)     to authenticated;
grant execute on function public.madrasah_waivers()                          to authenticated;
grant execute on function public.madrasah_fees_overview()                    to authenticated;
grant execute on function public.madrasah_fee_annual_report(date, date)      to authenticated;

commit;

-- ===========================================================================
--  CHECKS
-- ===========================================================================

--  #1  A reminder never carries a child's name.
--
--      This is the check worth having in this file. Email is not a secure
--      channel and a madrasah roll is Article 9 data about a child's
--      religion. The body this function posts is built from a fixed list of
--      keys; if anybody ever adds a pupil name, a class or a charge
--      description to it, this fails.
do $c1$
declare
  v_def  text;
  v_bad  text;
  v_word text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'send_madrasah_fee_reminders' limit 1;
  if v_def is null then
    raise exception 'CHECK 1 FAILED: send_madrasah_fee_reminders() does not exist.';
  end if;

  --  Only the part of the body that is actually posted, so that the header
  --  above is allowed to use the words it is warning about.
  v_def := substring(v_def from position('net.http_post' in v_def));
  v_def := substring(v_def for coalesce(nullif(position('insert into public.madrasah_fee_reminders' in v_def), 0),
                                        length(v_def)));

  foreach v_word in array array['first_name', 'last_name', 'madrasah_pupils',
                                'description', 'madrasah_charges', 'pupil'] loop
    if v_def ilike '%' || v_word || '%' then
      v_bad := coalesce(v_bad, '') || v_word || ' ';
    end if;
  end loop;

  if v_bad is not null then
    raise exception
      'CHECK 1 FAILED: the reminder body mentions % — a child''s name or class must never leave in an unsolicited email about money.', v_bad;
  end if;
  raise notice 'CHECK 1 passed: a fee reminder carries the family, the reference and the amount, and nothing about a child.';
end $c1$;

--  #2  One reminder per family per week, and only to a family that owes.
--      Tested through the real function against a real family, because the
--      rule lives in control flow rather than in a constraint and a schema
--      test could not see it. Uses the test switches when they exist; skips
--      cleanly in production, where there is no way to become an admin from
--      inside a migration.
do $c2$
declare
  v_m uuid; v_h uuid; v_g uuid; v_r jsonb; v_n int;
begin
  if to_regclass('public._test_who') is null then
    raise notice 'CHECK 2 skipped: no test switches here. This runs in the local harness (db/_test_fees.sql).';
    return;
  end if;

  --  slug and town are written out for the reason given at length in 070's
  --  CHECK 2: production's `masjids` has three not-null columns with no
  --  default, and the local harness's has one. This block only ever runs in
  --  the harness, so the omission was harmless here — which is exactly why it
  --  would have sat unnoticed until somebody moved the check.
  insert into public.masjids (slug, name, town)
  values ('check2-' || replace(gen_random_uuid()::text, '-', ''),
          'CHECK-2 reminders', 'Nowhere')
  returning id into v_m;
  update public._test_who set v = v_m::text where k = 'masjid';
  update public._test_who set v = 'admin'   where k = 'role';

  insert into public.madrasah_households (masjid_id, reference, name)
  values (v_m, 'MF-9998', 'Reminder check') returning id into v_h;
  insert into public.madrasah_guardians (masjid_id, household_id, full_name, email, is_primary)
  values (v_m, v_h, 'A Parent', 'parent@example.test', true) returning id into v_g;

  insert into public.app_settings (key, value) values ('notify_url', 'http://localhost/notify')
    on conflict (key) do nothing;
  insert into public.app_settings (key, value) values ('notify_secret', 'x')
    on conflict (key) do nothing;

  --  Owes nothing yet.
  v_r := public.send_madrasah_fee_reminders(array[v_h]);
  if (v_r->>'sent')::int <> 0 or (v_r->>'nothing_owed')::int <> 1 then
    raise exception 'CHECK 2 FAILED: a family owing nothing was sent a reminder. Got %', v_r;
  end if;

  --  Now it owes.
  insert into public.madrasah_charges (masjid_id, household_id, description, gross_p)
  values (v_m, v_h, 'Check', 5000);

  v_r := public.send_madrasah_fee_reminders(array[v_h]);
  if (v_r->>'sent')::int <> 1 then
    raise exception 'CHECK 2 FAILED: a family that owes £50 was not sent a reminder. Got %', v_r;
  end if;

  --  Pressed twice.
  v_r := public.send_madrasah_fee_reminders(array[v_h]);
  if (v_r->>'sent')::int <> 0 or (v_r->>'too_soon')::int <> 1 then
    raise exception 'CHECK 2 FAILED: the same family was emailed twice in one day. Got %', v_r;
  end if;

  delete from public.madrasah_charges where masjid_id = v_m;
  delete from public.madrasah_fee_reminders where masjid_id = v_m;
  delete from public.madrasah_guardians where masjid_id = v_m;
  delete from public.madrasah_households where masjid_id = v_m;
  delete from public.masjids where id = v_m;
  update public._test_who set v = null    where k = 'masjid';
  update public._test_who set v = 'none'  where k = 'role';

  raise notice 'CHECK 2 passed: nothing owed means no email, owing means one, and twice in a day means one.';
end $c2$;

--  #3  Administrators only. Line-based — 065.
do $c3$
declare v_fn text; v_def text; v_line text; v_found boolean;
begin
  foreach v_fn in array array['send_madrasah_fee_reminders', 'madrasah_fees_overview',
                              'madrasah_fee_annual_report', 'madrasah_recent_payments',
                              'madrasah_waivers'] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn limit 1;
    if v_def is null then
      raise exception 'CHECK 3 FAILED: public.%() does not exist.', v_fn;
    end if;
    v_found := false;
    foreach v_line in array string_to_array(v_def, E'\n') loop
      if btrim(v_line) not like '--%' and v_line like '%public.verified_admin()%' then
        v_found := true; exit;
      end if;
    end loop;
    if not v_found then
      raise exception 'CHECK 3 FAILED: public.%() never calls public.verified_admin() in live code.', v_fn;
    end if;
  end loop;
  raise notice 'CHECK 3 passed: reminders and reports are administrators only.';
end $c3$;

-- ===========================================================================
--  AFTER APPLYING THIS FILE
--
--  1. Re-run db/011_require_two_step.sql.
--  2. Deploy the notify function. It needs the madrasah_fee_reminder branch
--     added in this same commit (supabase/functions/notify/messages.ts).
--     Without it the POST arrives, matches nothing, and the office sees
--     "sent" against families who were never written to.
-- ===========================================================================
