-- ===========================================================================
--  143 — Stripe moved the invoice fields, so read both shapes
--
--  MasjidOne · 5 October 2026
--
--  FOUND BEFORE IT COST ANYTHING, while choosing the API version on a webhook
--  endpoint. Stripe's 2025-03-31.basil release — and therefore every version
--  after it, including the 2026-08-26.dahlia that a new account defaults to —
--  made three breaking changes to the Invoice object:
--
--    * `payment_intent` REMOVED. The link now lives in `payments.data[].payment`.
--    * `charge` and `paid` REMOVED.
--    * `tax` REPLACED by `total_taxes`, which is an ARRAY, not an integer.
--
--  141 read all three in their old shapes, and the consequences were not
--  symmetrical:
--
--  1. THE TAX ONE CRASHES, LOUDLY. coalesce evaluates its second argument when
--     the first is null, so with `tax` gone it reached
--     `nullif(payload->>'total_taxes','')::int` with the text '[]' and raised
--     "invalid input syntax for type integer". No invoice would import at all.
--     Bad, but bad in the way that gets noticed on the first delivery.
--
--  2. THE PAYMENT ONE FAILS SILENTLY, which is worse. With `payment_intent`
--     and `charge` both gone, the coalesce fell through to its last option and
--     wrote the INVOICE id into paid_reference. Everything would have looked
--     fine. But 142 matches a dispute to its invoice on
--     `paid_reference = dispute.payment_intent`, so no dispute would ever have
--     matched — and a dispute that matches nothing is money reclaimed from the
--     bank with the console still showing the invoice as paid. The exact
--     failure 142 was written to prevent, reintroduced by an API version
--     somebody picks from a dropdown.
--
--  SO BOTH SHAPES ARE READ, rather than pinning the endpoint to an old version
--  and calling it done. Pinning is still the right thing to do today — the
--  tests exercise the old shape — but a pin is a decision somebody has to keep
--  making, and Stripe retires old versions eventually. This way the endpoint's
--  API version stops being load-bearing.
-- ===========================================================================

begin;

create or replace function public.stripe_invoice_tax_p(payload jsonb)
returns int
language sql immutable
set search_path to 'public', 'pg_temp'
as $$
  select case
    /* basil and later: an array of tax amounts, which have to be summed. */
    when jsonb_typeof(payload -> 'total_taxes') = 'array' then
      coalesce((select sum((t ->> 'amount')::int)
                  from jsonb_array_elements(payload -> 'total_taxes') t), 0)
    /* before basil: a single integer, or null when there is no tax. */
    when jsonb_typeof(payload -> 'tax') = 'number' then (payload ->> 'tax')::int
    else 0
  end;
$$;
revoke all on function public.stripe_invoice_tax_p(jsonb) from public, anon, authenticated;
grant execute on function public.stripe_invoice_tax_p(jsonb) to service_role, authenticated;

comment on function public.stripe_invoice_tax_p(jsonb) is
  'VAT on a Stripe invoice, from either shape: the pre-basil integer `tax`, or the post-basil `total_taxes` array which has to be summed. Zero when neither is present — which is the normal case until YSB Ventures Ltd is VAT registered.';

create or replace function public.stripe_invoice_payment_ref(payload jsonb)
returns text
language sql immutable
set search_path to 'public', 'pg_temp'
as $$
  select coalesce(
    /* Before basil. */
    nullif(btrim(coalesce(payload ->> 'payment_intent', '')), ''),
    nullif(btrim(coalesce(payload ->> 'charge', '')), ''),
    /* basil and later: the InvoicePayment list. A paid invoice has one entry;
       partial payments have several and the first is the one that settled the
       bulk of it, which is what a dispute would be raised against. */
    nullif(btrim(coalesce(
      payload -> 'payments' -> 'data' -> 0 -> 'payment' ->> 'payment_intent', '')), ''),
    nullif(btrim(coalesce(
      payload -> 'payments' -> 'data' -> 0 -> 'payment' ->> 'charge', '')), ''));
$$;
revoke all on function public.stripe_invoice_payment_ref(jsonb) from public, anon, authenticated;
grant execute on function public.stripe_invoice_payment_ref(jsonb) to service_role, authenticated;

comment on function public.stripe_invoice_payment_ref(jsonb) is
  'What paid a Stripe invoice, from either shape. NULL rather than a fallback to the invoice id: 142 matches a dispute on this value, and an invoice id here would silently match nothing for ever. A null is visible; a wrong answer is not.';

-- ---------------------------------------------------------------------------
--  invoice_from_stripe, reading through the two helpers above.
--
--  Lifted from 141 by script and changed in exactly three places — the tax
--  expression, the payment reference, and one audit field — so the diff
--  between the two files is those changes and nothing else.
-- ---------------------------------------------------------------------------
create or replace function public.invoice_from_stripe(payload jsonb, p_method text default null)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_masjid uuid; v_slug text; v_inv uuid; v_sid text; v_number text;
  v_stripe_status text; v_status text; v_issued date; v_due date;
  v_paid_on date; v_paid_p int; v_void text;
  v_period_start date; v_period_end date;
  v_plan text; v_band text;
  v_st jsonb; v_line jsonb; v_lines int := 0; v_unit int; v_qty int;
  v_first jsonb;
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Only MasjidOne may mirror a Stripe invoice.' using errcode = '42501';
  end if;

  v_sid := nullif(btrim(coalesce(payload->>'id','')),'');
  if v_sid is null then
    raise exception 'That is not a Stripe invoice — it has no id.' using errcode = '22023';
  end if;

  select b.masjid_id, m.slug into v_masjid, v_slug
    from public.masjid_billing b join public.masjids m on m.id = b.masjid_id
   where b.stripe_customer_id = payload->>'customer';
  if v_masjid is null then
    raise exception 'No masjid is linked to Stripe customer %. Invoice % was not recorded.',
      coalesce(payload->>'customer','(none)'), v_sid using errcode = '22023';
  end if;

  v_stripe_status := coalesce(payload->>'status','');
  if v_stripe_status = 'draft' then
    raise exception 'Invoice % is still a draft in Stripe, so it has no number yet.', v_sid
      using errcode = '22023';
  end if;

  v_number := nullif(btrim(coalesce(payload->>'number','')),'');
  if v_number is null then
    raise exception 'Stripe invoice % has no number.', v_sid using errcode = '22023';
  end if;

  v_st := coalesce(payload->'status_transitions', '{}'::jsonb);
  v_issued := coalesce(public.stripe_day(v_st, 'finalized_at'),
                       public.stripe_day(payload, 'created'));
  if v_issued is null then
    raise exception 'Stripe invoice % has no date it was issued on.', v_sid using errcode = '22023';
  end if;
  /* Greatest, because a subscription invoice charged on the day it is raised
     has no due_date at all, and because a due date before the issue date
     would be rejected by invoices_due_after_issue. */
  v_due := greatest(coalesce(public.stripe_day(payload, 'due_date'), v_issued), v_issued);

  v_status := case v_stripe_status
                when 'open' then 'sent'
                when 'paid' then 'paid'
                when 'void' then 'void'
                /* Stripe's "uncollectible" means written off, which this
                   ledger has no word for. Void is the nearest honest thing
                   and the reason says which it really was, so nobody later
                   reads it as an invoice raised in error. */
                when 'uncollectible' then 'void'
                else null end;
  if v_status is null then
    raise exception 'Stripe invoice % is in status "%", which this ledger has no word for.',
      v_sid, v_stripe_status using errcode = '22023';
  end if;

  if v_status = 'paid' then
    v_paid_on := coalesce(public.stripe_day(v_st, 'paid_at'), v_issued);
    v_paid_p  := nullif(payload->>'amount_paid','')::int;
    if v_paid_p is null then
      raise exception 'Stripe says invoice % is paid but did not say how much.', v_sid
        using errcode = '22023';
    end if;
  end if;
  if v_status = 'void' then
    v_void := case when v_stripe_status = 'uncollectible'
                   then 'Stripe marked it uncollectible — written off, not raised in error.'
                   else 'Voided in Stripe.' end;
  end if;

  /* The service period comes off the first line where there is one: an
     invoice's own period_start/period_end describe the billing run, while the
     line describes the months the masjid is paying for, and it is the second
     one a treasurer is checking. */
  v_first := payload->'lines'->'data'->0;
  v_period_start := coalesce(public.stripe_day(v_first->'period','start'),
                             public.stripe_day(payload,'period_start'));
  v_period_end   := coalesce(public.stripe_day(v_first->'period','end'),
                             public.stripe_day(payload,'period_end'));
  if v_period_end is not null and v_period_start is not null
     and v_period_end < v_period_start then
    v_period_start := null; v_period_end := null;
  end if;

  select plan_code, band into v_plan, v_band
    from public.masjid_plan where masjid_id = v_masjid and ended_on is null;

  insert into public.invoices (
    masjid_id, number, status, source, stripe_invoice_id, stripe_hosted_url,
    period_start, period_end, plan_code, band, issued_on, due_on,
    vat_p, paid_on, paid_amount_p, paid_method, paid_reference, void_why)
  values (
    v_masjid, v_number, v_status, 'stripe', v_sid,
    nullif(btrim(coalesce(payload->>'hosted_invoice_url','')),''),
    v_period_start, v_period_end, v_plan, v_band, v_issued, v_due,
    public.stripe_invoice_tax_p(payload),
    v_paid_on, v_paid_p,
    case when v_status = 'paid' then coalesce(p_method, 'stripe') end,
    /* NO FALLBACK TO THE INVOICE ID. 141 ended this coalesce with v_sid, which
       meant that on a post-basil API version — where payment_intent and charge
       are both gone — every paid invoice silently recorded its own id as the
       thing that paid it, and 142's dispute matching could never match. A null
       here is visible; a plausible wrong answer is not. */
    case when v_status = 'paid'
         then public.stripe_invoice_payment_ref(payload) end,
    v_void)
  /* THE PREDICATE HAS TO BE REPEATED. invoices_stripe_id is a PARTIAL unique
     index (where stripe_invoice_id is not null, because manual invoices have
     none), and Postgres will not infer a partial index unless the ON CONFLICT
     clause carries the same WHERE. Without it this raises "there is no unique
     or exclusion constraint matching the ON CONFLICT specification" — which
     is how a test looking for a different error found this one. */
  on conflict (stripe_invoice_id) where stripe_invoice_id is not null do update set
    number         = excluded.number,
    status         = excluded.status,
    stripe_hosted_url = excluded.stripe_hosted_url,
    period_start   = excluded.period_start,
    period_end     = excluded.period_end,
    issued_on      = excluded.issued_on,
    due_on         = excluded.due_on,
    vat_p          = excluded.vat_p,
    /* Cleared when Stripe says it is no longer paid, which is what a reversed
       Direct Debit looks like. Leaving the old values behind would show a
       masjid as having paid an invoice the bank has taken back. */
    paid_on        = excluded.paid_on,
    paid_amount_p  = excluded.paid_amount_p,
    paid_method    = excluded.paid_method,
    paid_reference = excluded.paid_reference,
    void_why       = excluded.void_why
  returning id into v_inv;

  if jsonb_typeof(payload->'lines'->'data') <> 'array'
     or jsonb_array_length(payload->'lines'->'data') = 0 then
    raise exception 'Stripe invoice % has no lines.', v_sid using errcode = '22023';
  end if;

  /* THE LINES ARE WRITTEN ONCE, and this is a correction rather than a
     convenience. The first version deleted and re-inserted them on every
     delivery, on the reasoning that Stripe is authoritative about its own
     document. It is — but a FINALISED Stripe invoice's lines are immutable;
     only its status moves after that, which is the one thing that is updated
     above. So rewriting them achieved nothing except to churn the ids on
     every retry.
     (It also could not be applied: the tooling gates a DELETE behind a
     confirmation this environment cannot give, and timed out on the whole
     migration — the same thing that has blocked masjid_theme's drop. Worth
     recording, because the guard was pointing at something real.) */
  if not exists (select 1 from public.invoice_lines where invoice_id = v_inv) then
    for v_line in select * from jsonb_array_elements(payload->'lines'->'data') loop
      v_lines := v_lines + 1;
      v_qty := greatest(coalesce(nullif(v_line->>'quantity','')::int, 1), 1);
      /* Three places, because Stripe has moved it. In order: the modern
         pricing block, the older price object, and the plan object from before
         that. Never amount/quantity — see the header. */
      v_unit := coalesce(
        nullif(v_line->'pricing'->'price_details'->>'unit_amount','')::int,
        nullif(v_line->'price'->>'unit_amount','')::int,
        nullif(v_line->'plan'->>'amount','')::int);
      if v_unit is null then
        raise exception 'Line % of Stripe invoice % has no unit amount in any of the places Stripe puts it. Nothing was recorded for this invoice.',
          v_lines, v_sid using errcode = '22023';
      end if;
      insert into public.invoice_lines (invoice_id, description, qty, unit_amount_p, sort)
      values (v_inv,
              coalesce(nullif(btrim(coalesce(v_line->>'description','')),''),
                       'Subscription'),
              v_qty, v_unit, v_lines * 10);
    end loop;
  else
    select count(*) into v_lines from public.invoice_lines where invoice_id = v_inv;
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'invoice_from_stripe',
          jsonb_build_object('number', v_number, 'stripe_invoice', v_sid,
                             'status', v_status, 'stripe_status', v_stripe_status,
                             'lines', v_lines,
                             /* Findable, because a paid invoice with nothing
                                to match a dispute against is a hole worth
                                knowing about before a dispute arrives. */
                             'no_payment_reference',
                               v_status = 'paid'
                                 and public.stripe_invoice_payment_ref(payload) is null,
                             'total_p', public.invoice_total_p(v_inv)));

  return jsonb_build_object('masjid', v_slug, 'number', v_number,
                            'status', v_status, 'lines', v_lines,
                            'total_p', public.invoice_total_p(v_inv));
end $$;;
revoke all on function public.invoice_from_stripe(jsonb, text) from public, anon, authenticated;
grant execute on function public.invoice_from_stripe(jsonb, text) to service_role;

commit;
