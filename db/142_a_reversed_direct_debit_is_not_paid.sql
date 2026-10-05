-- ===========================================================================
--  142 — a reversed Direct Debit is not paid
--
--  MasjidOne · 5 October 2026
--
--  THE HOLE THIS CLOSES. Bacs can take money back AFTER it has arrived, and
--  there is no time limit on it: Stripe's own documentation says a payer can
--  dispute at any time, that you cannot submit evidence, and that the decision
--  is final and non-appealable. The money and the fee come straight back out
--  of the balance.
--
--  141 already handles an invoice moving off paid when STRIPE'S INVOICE says
--  so. A dispute is not that. It arrives as charge.dispute.created against the
--  charge, and Stripe does not necessarily move the invoice off paid — so
--  without this, the support console would show a masjid as having paid an
--  invoice whose money has been reclaimed. Somebody would then not chase it,
--  which is the precise opposite of what this whole system is for.
--
--  WHY A SEPARATE FUNCTION RATHER THAN A BRANCH IN invoice_from_stripe. That
--  function's contract is "tell me what Stripe says about this invoice and I
--  will record it". A dispute says something about a CHARGE. The two are
--  joined here by payment_intent, which 141 already stores in paid_reference
--  for exactly this kind of question, and keeping them separate means the
--  invoice mirror stays a pure mirror.
--
--  WHAT IT DOES NOT DO: close itself. There is no handler for
--  charge.dispute.closed, and that is deliberate rather than unfinished — a
--  Bacs dispute cannot be won, so a "closed" event carries no outcome worth
--  acting on. If Stripe ever returns the money, that is a credit somebody
--  raises by hand and thinks about, not an automatic reversal of a reversal.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. The fact of the dispute, kept on the invoice.
--
--  Not merely "this is unpaid again". An invoice that was paid and then
--  reclaimed is a different thing from one that was never paid, and the office
--  needs to be able to tell them apart — the first means ring the treasurer
--  about a Direct Debit their bank reversed, the second means send a reminder.
-- ---------------------------------------------------------------------------
alter table public.invoices
  add column if not exists disputed_at    timestamptz,
  add column if not exists dispute_id     text,
  add column if not exists dispute_reason text;

create unique index if not exists invoices_dispute_id
  on public.invoices (dispute_id) where dispute_id is not null;

comment on column public.invoices.disputed_at is
  'When a Bacs payer reclaimed this payment through their bank. Set by invoice_disputed. A Bacs dispute has no time limit and cannot be contested, so this is a record of money gone, not of an argument in progress.';

-- ---------------------------------------------------------------------------
--  2. Recording it.
--
--  Matched on the PaymentIntent, which is what 141 writes into paid_reference
--  when Stripe says an invoice is paid. An unmatched dispute raises, so the
--  webhook records it against the event rather than discarding it — a dispute
--  nobody can match to an invoice is still money that has left, and it is
--  exactly the kind of thing that went unnoticed for a fortnight last time.
-- ---------------------------------------------------------------------------
create or replace function public.invoice_disputed(p_reference text, payload jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_inv uuid; v_masjid uuid; v_slug text; v_number text; v_was text;
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Only MasjidOne may record a dispute.' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reference,'')),'') is null then
    raise exception 'A dispute has to name the payment it reverses.' using errcode = '22023';
  end if;

  select i.id, i.masjid_id, m.slug, i.number, i.status
    into v_inv, v_masjid, v_slug, v_number, v_was
    from public.invoices i join public.masjids m on m.id = i.masjid_id
   where i.paid_reference = p_reference and i.source = 'stripe';
  if v_inv is null then
    raise exception 'No invoice was paid by %, so this dispute matches nothing. The money has still gone.', p_reference
      using errcode = '22023';
  end if;

  /* BACK TO SENT, not void. The masjid still owes this period — the invoice
     is outstanding again, which is what 'sent' means. Voiding it would make
     the debt disappear along with the payment. */
  update public.invoices set
    status         = case when status = 'void' then 'void' else 'sent' end,
    paid_on        = null,
    paid_amount_p  = null,
    paid_method    = null,
    disputed_at    = now(),
    dispute_id     = coalesce(nullif(btrim(coalesce(payload->>'id','')),''), dispute_id),
    dispute_reason = nullif(btrim(coalesce(payload->>'reason','')),'')
  where id = v_inv;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'direct_debit_reversed',
          jsonb_build_object('invoice', v_number, 'was', v_was,
                             'dispute', payload->>'id',
                             'reason', payload->>'reason',
                             'amount_p', nullif(payload->>'amount','')::int,
                             'note', 'A Bacs dispute cannot be contested. This invoice is outstanding again.'));

  return jsonb_build_object('masjid', v_slug, 'number', v_number,
                            'was', v_was, 'now', 'sent',
                            'reason', payload->>'reason');
end $$;
revoke all on function public.invoice_disputed(text, jsonb) from public, anon, authenticated;
grant execute on function public.invoice_disputed(text, jsonb) to service_role;

commit;
