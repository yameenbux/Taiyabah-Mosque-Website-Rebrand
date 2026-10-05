-- 136 — Billing a masjid
--
-- WHY. Nothing billed anybody. 134 recorded WHICH PLAN and WHICH BAND a masjid
-- is on, which is what you need to work out a price — but there was no invoice,
-- no record of payment, and no way to answer "who owes us money". A business
-- with three customers and no answer to that question is not a business yet.
--
-- WHAT THIS IS, AND WHAT IT DELIBERATELY IS NOT. It is an invoice ledger: raise,
-- send, record payment, void, and report what is outstanding. It is NOT a card
-- subscription. That is a decision, not an omission:
--
--   * A UK masjid pays from a charity bank account, by transfer or standing
--     order, with a trustee signing it off. Many have no card that can carry a
--     recurring debit at all.
--   * The setup fee is waived on twelve months prepaid. That is an invoice with
--     two lines, not a subscription.
--   * The product is not self-serve — nobody buys it without a meeting — so
--     there is no page on which a committee would ever enter card details.
--
-- Direct Debit (Bacs, through GoCardless or Stripe) is the right eventual
-- answer for recurring charity payments, and this is shaped to receive it:
-- invoice_mark_paid() already records a method and a reference, so a collection
-- becomes one more way an invoice gets paid rather than a second system.
--
-- ------------------------------------------------------------------------
-- WHERE THE MONEY LIVES, because this looks like it breaks a standing rule.
--
-- The rule is that prices live in PRICING_BANDS in the website's lib/site.ts
-- and nowhere else, so that a price cannot drift between two sources. This
-- migration keeps that rule, and the distinction is worth stating precisely:
--
--   * A PRICE LIST says what a band costs TODAY. That stays in lib/site.ts.
--     Nothing in this file maps a band to an amount, and nothing here would
--     need changing if every price changed tomorrow.
--   * AN INVOICE records what was actually charged ON A DATE. That is a
--     historical fact and a legal document. It must not change when the price
--     list does — last March's invoice has to keep saying what was billed last
--     March.
--
-- So amounts arrive as arguments. The CALLER computes them from PRICING_BANDS
-- and passes them in. The database never learns what a band costs, and an
-- invoice never recalculates itself.
--
-- That is also why there is no subtotal column: a stored total is a total that
-- can disagree with its own lines. Totals are summed from invoice_lines on
-- read, so they cannot drift.
--
-- ------------------------------------------------------------------------
-- VAT. YSB Ventures Ltd is not VAT registered, and the terms page already
-- promises every invoice will say so until it is. vat_p therefore exists and
-- is zero: the column is needed the day that changes, and zero is the truth
-- today. Do not print a VAT number this company does not have.
--
-- CURRENCY is pounds, held in pence as integers like every other amount in
-- this schema. There is no currency column because the product is sold to UK
-- masajid in sterling; adding one would imply a capability that does not exist.
--
-- ------------------------------------------------------------------------
-- THE FOUNDING CUSTOMER MUST NEVER BE INVOICED, and that is why `billable`
-- exists. The founding-customer agreement says, in clause 4.2, "No invoice will
-- be raised and no payment is due." Customer number one is therefore a masjid
-- that must never receive an invoice — not a customer who owes nothing, and
-- certainly not one who shows up overdue. Getting that wrong would breach a
-- signed agreement with the only masjid currently using the platform.
--
-- So not-billable is a first-class state with a mandatory reason, invoice_raise
-- refuses outright for such a masjid, and the overview reports them as not
-- billed rather than as owing zero.
--
-- ------------------------------------------------------------------------
-- APPLIED to production on 5 October 2026, statement group by statement group,
-- because the MCP tooling times out on a file this size. Verified afterwards:
-- three tables with RLS on and no policies, eight functions, nothing readable
-- or executable from a browser, PUBLIC holding EXECUTE on none of them, and
-- Taiyabah seeded billable=false quoting clause 4.2.
--
-- ONE HONEST DISCREPANCY, recorded rather than papered over. Applying by hand
-- meant retyping these bodies, and in five of the eight some of the long
-- comment blocks below were shortened on the way in. So `pg_get_functiondef`
-- in the SQL editor shows slightly terser comments than this file does.
--
-- The LOGIC is identical, and that was measured rather than hoped: comparing
-- md5 of each body with comments stripped and whitespace normalised gives the
-- same hash for all eight functions, and three match byte-for-byte. The five
-- that differ differ only in prose.
--
-- It was left that way deliberately. Retyping five large function bodies to
-- fix a comment-only difference would reintroduce exactly the transcription
-- risk that caused it, and this file — not the catalogue — is where this
-- repository keeps its record. If you re-run this file against production, the
-- comments come into line and nothing else changes.

-- HOUSE PATTERN throughout: RLS on, no policies, no grants, reached only
-- through SECURITY DEFINER functions gated on is_platform_admin(). Because the
-- tables are unreachable directly, the rules about what may change after an
-- invoice is sent are enforced in those functions rather than in triggers.
-- Every grant sits beside the thing it protects — see 133 for why.

-- ---------------------------------------------------------------------------
-- How a masjid is billed.
-- ---------------------------------------------------------------------------
create table public.masjid_billing (
  masjid_id        uuid primary key references public.masjids(id) on delete cascade,

  /* false means never invoice this masjid. The founding customer is the reason
     this column exists. */
  billable         boolean not null default true,
  not_billable_why text,

  /* Who the invoice goes to. Deliberately separate from the masjid's public
     contact: the treasurer is rarely the person answering the website. */
  billing_email    text,
  billing_contact  text,
  billing_phone    text,

  cycle            text not null default 'monthly',
  /* Days from issue to due. 30 is the usual courtesy for a committee that
     meets monthly. */
  terms_days       int  not null default 30,

  /* What the next invoice should cover from. Advanced by invoice_raise. */
  next_invoice_on  date,

  /* The one-off fee, and whether it still stands. Waived on twelve months
     prepaid — which is the ONLY discount this business gives, because the
     monthly is never discounted. */
  setup_fee_state  text not null default 'due',
  po_reference     text,
  note             text,
  updated_at       timestamptz not null default now(),
  updated_by       uuid,

  constraint masjid_billing_cycle check (cycle in ('monthly','yearly')),
  constraint masjid_billing_terms check (terms_days between 0 and 120),
  constraint masjid_billing_setup check (setup_fee_state in ('due','waived','paid')),
  /* A masjid taken off billing without a reason is one nobody dares start
     billing again. Same rule as masjid_feature. */
  constraint masjid_billing_reason check (
    billable or nullif(btrim(coalesce(not_billable_why,'')),'') is not null)
);
alter table public.masjid_billing enable row level security;
revoke all on public.masjid_billing from public, anon, authenticated;
comment on table public.masjid_billing is
  'How each masjid is billed. billable=false means never invoice them, and needs a reason — the founding customer is contractually never invoiced.';

-- ---------------------------------------------------------------------------
-- The invoices.
-- ---------------------------------------------------------------------------
create sequence public.invoice_number_seq;

create table public.invoices (
  id            uuid primary key default gen_random_uuid(),
  masjid_id     uuid not null references public.masjids(id) on delete restrict,

  /* Human-readable, unique and sequential, because that is what an accountant
     and HMRC expect. A rolled-back transaction can leave a gap in the
     sequence; a gap is explainable, a duplicate is not. */
  number        text not null unique,

  status        text not null default 'draft',

  /* What period the charge covers. Null for a one-off such as a setup fee. */
  period_start  date,
  period_end    date,

  /* Recorded on the invoice, not looked up later: an invoice has to keep
     saying what it was raised against even after the masjid changes plan. */
  plan_code     text,
  band          text,

  issued_on     date,
  due_on        date,

  /* Zero until YSB Ventures Ltd is VAT registered. See the header. */
  vat_p         int not null default 0,

  paid_on        date,
  paid_amount_p  int,
  paid_method    text,
  paid_reference text,
  void_why       text,

  created_at    timestamptz not null default now(),
  created_by    uuid,

  constraint invoices_status check (status in ('draft','sent','paid','void')),
  constraint invoices_period check (period_end is null or period_start is null
                                 or period_end >= period_start),
  constraint invoices_vat check (vat_p >= 0),
  /* A sent or paid invoice has dates. A DRAFT need not — and nor need a VOID,
     because the commonest void of all is a draft raised by mistake that was
     never sent and therefore never had an issue date.

     The first version of this constraint read `status = 'draft' or ...`, which
     made voiding a draft impossible: invoice_void moved it to 'void' while the
     dates were still null and the check rejected the update. Caught by a test
     that voided a draft, which is the ordinary case rather than an edge one. */
  constraint invoices_sent_has_dates check (
    status in ('draft','void') or (issued_on is not null and due_on is not null)),
  constraint invoices_due_after_issue check (
    due_on is null or issued_on is null or due_on >= issued_on),
  /* Paid means we know when, how much and how. Without those three it is not
     a record of payment, it is a hope. */
  constraint invoices_paid_is_recorded check (
    status <> 'paid' or (paid_on is not null and paid_amount_p is not null
                         and nullif(btrim(coalesce(paid_method,'')),'') is not null)),
  constraint invoices_void_has_reason check (
    status <> 'void' or nullif(btrim(coalesce(void_why,'')),'') is not null)
);
alter table public.invoices enable row level security;
revoke all on public.invoices from public, anon, authenticated;
create index invoices_masjid on public.invoices (masjid_id, issued_on desc);
create index invoices_open on public.invoices (due_on) where status = 'sent';
comment on table public.invoices is
  'One row per invoice. No stored total: totals are summed from invoice_lines so they cannot disagree with the lines. Amounts are supplied by the caller from PRICING_BANDS, never computed here.';

create table public.invoice_lines (
  id            uuid primary key default gen_random_uuid(),
  invoice_id    uuid not null references public.invoices(id) on delete cascade,
  description   text not null,
  qty           int  not null default 1,
  unit_amount_p int  not null,
  /* Generated, so a line can never claim a total its own parts do not make. */
  amount_p      int generated always as (qty * unit_amount_p) stored,
  sort          int not null default 100,
  constraint invoice_lines_qty check (qty > 0),
  constraint invoice_lines_desc check (btrim(description) <> '')
);
alter table public.invoice_lines enable row level security;
revoke all on public.invoice_lines from public, anon, authenticated;
create index invoice_lines_invoice on public.invoice_lines (invoice_id, sort);
comment on table public.invoice_lines is
  'What an invoice is for. amount_p is generated from qty x unit_amount_p. A negative unit amount is allowed so a credit can be put on an invoice.';

-- ---------------------------------------------------------------------------
-- The only way in.
-- ---------------------------------------------------------------------------

/* Defined FIRST because the readers below are LANGUAGE sql in places and
   Postgres resolves those at CREATE time — the same ordering trap 134
   documents for masjid_has. */
create or replace function public.invoice_total_p(p_invoice uuid)
returns int
language sql stable security definer
set search_path to 'public', 'pg_temp'
as $$
  select coalesce((select sum(l.amount_p) from public.invoice_lines l
                    where l.invoice_id = p_invoice), 0)
       + coalesce((select i.vat_p from public.invoices i where i.id = p_invoice), 0);
$$;
revoke all on function public.invoice_total_p(uuid) from public, anon, authenticated;
grant execute on function public.invoice_total_p(uuid) to authenticated;

-- ---------------------------------------------------------------------------
/* How a masjid is billed. Creates the row if it is not there, so there is no
   separate "start billing this masjid" step to forget. */
create or replace function public.billing_set(p_masjid text, payload jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_billable boolean; v_why text;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may change billing.'
      using errcode = '42501';
  end if;
  select id into v_id from public.masjids where slug = p_masjid;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_masjid using errcode = '22023';
  end if;

  v_billable := coalesce((payload->>'billable')::boolean, true);
  v_why      := nullif(btrim(coalesce(payload->>'not_billable_why','')),'');
  if not v_billable and v_why is null then
    raise exception 'Say why this masjid is not billed. An exemption with no reason is one nobody dares end.'
      using errcode = '22023';
  end if;

  insert into public.masjid_billing as b (
    masjid_id, billable, not_billable_why, billing_email, billing_contact,
    billing_phone, cycle, terms_days, next_invoice_on, setup_fee_state,
    po_reference, note, updated_by)
  values (
    v_id, v_billable, v_why,
    nullif(btrim(coalesce(payload->>'billing_email','')),''),
    nullif(btrim(coalesce(payload->>'billing_contact','')),''),
    nullif(btrim(coalesce(payload->>'billing_phone','')),''),
    coalesce(nullif(btrim(coalesce(payload->>'cycle','')),''), 'monthly'),
    coalesce((payload->>'terms_days')::int, 30),
    nullif(payload->>'next_invoice_on','')::date,
    coalesce(nullif(btrim(coalesce(payload->>'setup_fee_state','')),''), 'due'),
    nullif(btrim(coalesce(payload->>'po_reference','')),''),
    nullif(btrim(coalesce(payload->>'note','')),''),
    auth.uid())
  on conflict (masjid_id) do update set
    billable         = v_billable,
    not_billable_why = v_why,
    /* Each field keeps its current value when the payload does not mention it,
       so a screen that edits one thing cannot blank the rest. */
    billing_email    = coalesce(nullif(btrim(coalesce(payload->>'billing_email','')),''),   b.billing_email),
    billing_contact  = coalesce(nullif(btrim(coalesce(payload->>'billing_contact','')),''), b.billing_contact),
    billing_phone    = coalesce(nullif(btrim(coalesce(payload->>'billing_phone','')),''),   b.billing_phone),
    cycle            = coalesce(nullif(btrim(coalesce(payload->>'cycle','')),''),           b.cycle),
    terms_days       = coalesce((payload->>'terms_days')::int,                              b.terms_days),
    next_invoice_on  = coalesce(nullif(payload->>'next_invoice_on','')::date,               b.next_invoice_on),
    setup_fee_state  = coalesce(nullif(btrim(coalesce(payload->>'setup_fee_state','')),''), b.setup_fee_state),
    po_reference     = coalesce(nullif(btrim(coalesce(payload->>'po_reference','')),''),    b.po_reference),
    note             = coalesce(nullif(btrim(coalesce(payload->>'note','')),''),            b.note),
    updated_at       = now(),
    updated_by       = auth.uid();

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'billing_changed', payload);

  return public.masjid_billing_summary(p_masjid);
end $$;
revoke all on function public.billing_set(text, jsonb) from public, anon, authenticated;
grant execute on function public.billing_set(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
/* Raise a DRAFT invoice. Draft on purpose: an invoice should be looked at
   before it goes, and a mistake in a draft costs nothing.

   AMOUNTS COME FROM THE CALLER. The admin screen reads PRICING_BANDS, works
   out the figure for this masjid's plan and band, and passes it. This function
   never multiplies a band by anything, which is what keeps one price list. */
create or replace function public.invoice_raise(p_masjid text, payload jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_id uuid; v_inv uuid; v_number text; v_b public.masjid_billing%rowtype;
  v_plan text; v_band text; v_line jsonb; v_lines int := 0;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may raise an invoice.'
      using errcode = '42501';
  end if;
  select id into v_id from public.masjids where slug = p_masjid;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_masjid using errcode = '22023';
  end if;

  select * into v_b from public.masjid_billing where masjid_id = v_id;
  if not found then
    raise exception 'There are no billing details for % yet. Call billing_set first — an invoice with nowhere to go is not an invoice.', p_masjid
      using errcode = '22023';
  end if;

  /* The founding customer. Clause 4.2 of the founding-customer agreement says
     no invoice will be raised, so this refuses rather than asking twice. */
  if not v_b.billable then
    raise exception 'This masjid is not billed: %. Change that with billing_set before invoicing them.', v_b.not_billable_why
      using errcode = '42501';
  end if;

  if jsonb_typeof(payload->'lines') <> 'array'
     or jsonb_array_length(payload->'lines') = 0 then
    raise exception 'An invoice needs at least one line.' using errcode = '22023';
  end if;

  /* EVERY LINE IS CHECKED BEFORE A NUMBER IS TAKEN, and the order is the whole
     point. nextval() is not rolled back when a transaction fails — sequences
     are deliberately non-transactional so that concurrent writers never block
     each other. So validating lines AFTER taking the number means a typo in a
     description permanently burns an invoice number, and the ledger grows gaps
     that have no invoice to explain them. Gaps are the first thing an
     accountant asks about.

     Found by a test that expected the first invoice to be MO-00001 and got
     MO-00003, because two earlier validation failures had each eaten one. */
  declare v_check jsonb;
  begin
    for v_check in select * from jsonb_array_elements(payload->'lines') loop
      if nullif(btrim(coalesce(v_check->>'description','')),'') is null then
        raise exception 'Every invoice line needs a description.' using errcode = '22023';
      end if;
      if v_check->>'unit_amount_p' is null then
        raise exception 'Line "%" has no amount. Amounts come from PRICING_BANDS in the website, not from this function.', v_check->>'description'
          using errcode = '22023';
      end if;
      if (v_check->>'unit_amount_p') !~ '^-?[0-9]+$' then
        raise exception 'Line "%" has an amount that is not a whole number of pence: %.', v_check->>'description', v_check->>'unit_amount_p'
          using errcode = '22023';
      end if;
    end loop;
  end;

  select plan_code, band into v_plan, v_band
    from public.masjid_plan where masjid_id = v_id and ended_on is null;

  /* Only now, with nothing left that can refuse, is a number taken. */
  v_number := 'MO-' || lpad(nextval('public.invoice_number_seq')::text, 5, '0');

  insert into public.invoices (
    masjid_id, number, status, period_start, period_end, plan_code, band,
    vat_p, created_by)
  values (
    v_id, v_number, 'draft',
    nullif(payload->>'period_start','')::date,
    nullif(payload->>'period_end','')::date,
    coalesce(nullif(btrim(coalesce(payload->>'plan_code','')),''), v_plan),
    coalesce(nullif(btrim(coalesce(payload->>'band','')),''), v_band),
    coalesce((payload->>'vat_p')::int, 0),
    auth.uid())
  returning id into v_inv;

  for v_line in select * from jsonb_array_elements(payload->'lines') loop
    v_lines := v_lines + 1;
    insert into public.invoice_lines (invoice_id, description, qty, unit_amount_p, sort)
    values (v_inv, btrim(v_line->>'description'),
            coalesce((v_line->>'qty')::int, 1),
            (v_line->>'unit_amount_p')::int,
            coalesce((v_line->>'sort')::int, v_lines * 10));
  end loop;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'invoice_raised',
          jsonb_build_object('number', v_number, 'lines', v_lines,
                             'total_p', public.invoice_total_p(v_inv)));

  return jsonb_build_object('number', v_number, 'masjid', p_masjid,
                            'status', 'draft', 'lines', v_lines,
                            'total_p', public.invoice_total_p(v_inv));
end $$;
revoke all on function public.invoice_raise(text, jsonb) from public, anon, authenticated;
grant execute on function public.invoice_raise(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
/* Send it. This is the moment the invoice becomes a document: it gets its
   dates, and nothing about it may change afterwards. */
create or replace function public.invoice_send(p_number text, p_issued_on date default null)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_i public.invoices%rowtype; v_terms int; v_issued date;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may send an invoice.'
      using errcode = '42501';
  end if;
  select * into v_i from public.invoices where number = p_number;
  if not found then
    raise exception 'There is no invoice %.', p_number using errcode = '22023';
  end if;
  if v_i.status <> 'draft' then
    raise exception 'Invoice % is already %. Only a draft can be sent.', p_number, v_i.status
      using errcode = '22023';
  end if;
  if public.invoice_total_p(v_i.id) = 0 then
    raise exception 'Invoice % totals zero. Send nothing, or void it.', p_number
      using errcode = '22023';
  end if;

  select terms_days into v_terms from public.masjid_billing where masjid_id = v_i.masjid_id;
  v_issued := coalesce(p_issued_on, current_date);

  update public.invoices
     set status = 'sent', issued_on = v_issued,
         due_on = v_issued + coalesce(v_terms, 30)
   where id = v_i.id;

  /* Move the billing period on, so the next invoice does not re-bill the same
     month. Only when this invoice covered a period. */
  if v_i.period_end is not null then
    update public.masjid_billing
       set next_invoice_on = v_i.period_end + 1, updated_at = now()
     where masjid_id = v_i.masjid_id;
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_i.masjid_id, auth.uid(), 'invoice_sent',
          jsonb_build_object('number', p_number, 'issued_on', v_issued,
                             'total_p', public.invoice_total_p(v_i.id)));

  return jsonb_build_object('number', p_number, 'status', 'sent',
                            'issued_on', v_issued,
                            'due_on', v_issued + coalesce(v_terms, 30),
                            'total_p', public.invoice_total_p(v_i.id));
end $$;
revoke all on function public.invoice_send(text, date) from public, anon, authenticated;
grant execute on function public.invoice_send(text, date) to authenticated;

-- ---------------------------------------------------------------------------
/* The money landed. Records WHEN, HOW MUCH and HOW — all three required by the
   table, because a payment you cannot reconcile against a bank statement is
   not a record of payment.

   A short payment is allowed and reported rather than refused: part-payments
   happen, and the summary shows the shortfall instead of pretending the
   invoice is settled. */
create or replace function public.invoice_mark_paid(p_number text, payload jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_i public.invoices%rowtype; v_amount int; v_total int; v_method text;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may record a payment.'
      using errcode = '42501';
  end if;
  select * into v_i from public.invoices where number = p_number;
  if not found then
    raise exception 'There is no invoice %.', p_number using errcode = '22023';
  end if;
  if v_i.status = 'void' then
    raise exception 'Invoice % was voided. Raise a new one rather than paying a void invoice.', p_number
      using errcode = '22023';
  end if;
  if v_i.status = 'draft' then
    raise exception 'Invoice % has not been sent yet.', p_number using errcode = '22023';
  end if;

  v_method := nullif(btrim(coalesce(payload->>'method','')),'');
  if v_method is null then
    raise exception 'Say how it was paid — bank transfer, standing order, card. It is what lets somebody match this to a bank statement.'
      using errcode = '22023';
  end if;

  v_total  := public.invoice_total_p(v_i.id);
  v_amount := coalesce((payload->>'amount_p')::int, v_total);
  if v_amount <= 0 then
    raise exception 'A payment has to be more than nothing.' using errcode = '22023';
  end if;

  update public.invoices
     set status = 'paid',
         paid_on = coalesce(nullif(payload->>'paid_on','')::date, current_date),
         paid_amount_p = v_amount,
         paid_method = v_method,
         paid_reference = nullif(btrim(coalesce(payload->>'reference','')),'')
   where id = v_i.id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_i.masjid_id, auth.uid(), 'invoice_paid',
          jsonb_build_object('number', p_number, 'amount_p', v_amount,
                             'total_p', v_total, 'method', v_method,
                             'short_p', greatest(v_total - v_amount, 0)));

  return jsonb_build_object('number', p_number, 'status', 'paid',
                            'amount_p', v_amount, 'total_p', v_total,
                            'short_p', greatest(v_total - v_amount, 0),
                            'overpaid_p', greatest(v_amount - v_total, 0));
end $$;
revoke all on function public.invoice_mark_paid(text, jsonb) from public, anon, authenticated;
grant execute on function public.invoice_mark_paid(text, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
/* Void it, with a reason. Never delete: an invoice number that has been issued
   must stay accounted for, and "where did MO-00007 go" is a question an
   accountant will eventually ask. */
create or replace function public.invoice_void(p_number text, p_reason text)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_i public.invoices%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may void an invoice.'
      using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception 'Say why it is being voided.' using errcode = '22023';
  end if;
  select * into v_i from public.invoices where number = p_number;
  if not found then
    raise exception 'There is no invoice %.', p_number using errcode = '22023';
  end if;
  if v_i.status = 'paid' then
    raise exception 'Invoice % is paid. Voiding it would lose the record of money received — raise a credit instead.', p_number
      using errcode = '22023';
  end if;

  update public.invoices set status = 'void', void_why = btrim(p_reason)
   where id = v_i.id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_i.masjid_id, auth.uid(), 'invoice_voided',
          jsonb_build_object('number', p_number, 'reason', btrim(p_reason)));

  return jsonb_build_object('number', p_number, 'status', 'void', 'reason', btrim(p_reason));
end $$;
revoke all on function public.invoice_void(text, text) from public, anon, authenticated;
grant execute on function public.invoice_void(text, text) to authenticated;

-- ---------------------------------------------------------------------------
/* Everything one masjid's billing panel needs, in one call.
 *
 * OVERDUE IS DERIVED, NEVER STORED. A stored 'overdue' would be wrong every
 * night at midnight until something ran to fix it, and the thing that runs is
 * the thing that fails quietly. An invoice is overdue if it is sent and its due
 * date has passed. That is always true at the moment it is read.
 *
 * billing_set() above calls this to return its result. It is defined after
 * that function on purpose and works because billing_set is plpgsql, which
 * resolves names at run time — the opposite of the LANGUAGE sql trap at the
 * top of this file. */
create or replace function public.masjid_billing_summary(p_masjid text)
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_b public.masjid_billing%rowtype; v_out jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support may read a masjid''s billing.'
      using errcode = '42501';
  end if;
  select id into v_id from public.masjids where slug = p_masjid;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_masjid using errcode = '22023';
  end if;
  select * into v_b from public.masjid_billing where masjid_id = v_id;

  select jsonb_build_object(
    'masjid', p_masjid,
    'name',   (select name from public.masjids where id = v_id),

    /* Null when billing has never been set up, which the screen should show as
       "not set up" rather than inventing defaults that look deliberate. */
    'billing', case when v_b.masjid_id is null then null else jsonb_build_object(
        'billable',        v_b.billable,
        'not_billable_why',v_b.not_billable_why,
        'email',           v_b.billing_email,
        'contact',         v_b.billing_contact,
        'phone',           v_b.billing_phone,
        'cycle',           v_b.cycle,
        'terms_days',      v_b.terms_days,
        'next_invoice_on', v_b.next_invoice_on,
        'setup_fee_state', v_b.setup_fee_state,
        'po_reference',    v_b.po_reference,
        'note',            v_b.note) end,

    'plan', (select jsonb_build_object('code', mp.plan_code, 'band', mp.band,
                                       'since', mp.started_on)
               from public.masjid_plan mp
              where mp.masjid_id = v_id and mp.ended_on is null),

    /* The amounts the screen leads with. All derived, so none can go stale. */
    'outstanding_p', coalesce((select sum(public.invoice_total_p(i.id))
                                 from public.invoices i
                                where i.masjid_id = v_id and i.status = 'sent'), 0),
    'overdue_p',     coalesce((select sum(public.invoice_total_p(i.id))
                                 from public.invoices i
                                where i.masjid_id = v_id and i.status = 'sent'
                                  and i.due_on < current_date), 0),
    'paid_to_date_p',coalesce((select sum(i.paid_amount_p)
                                 from public.invoices i
                                where i.masjid_id = v_id and i.status = 'paid'), 0),
    'last_paid_on',  (select max(i.paid_on) from public.invoices i
                       where i.masjid_id = v_id and i.status = 'paid'),

    'invoices', coalesce((
      select jsonb_agg(jsonb_build_object(
               'number',      i.number,
               'status',      i.status,
               'overdue',     i.status = 'sent' and i.due_on < current_date,
               'days_overdue',case when i.status = 'sent' and i.due_on < current_date
                                   then current_date - i.due_on else 0 end,
               'period_start',i.period_start,
               'period_end',  i.period_end,
               'issued_on',   i.issued_on,
               'due_on',      i.due_on,
               'total_p',     public.invoice_total_p(i.id),
               'vat_p',       i.vat_p,
               'paid_on',     i.paid_on,
               'paid_amount_p', i.paid_amount_p,
               'paid_method', i.paid_method,
               'paid_reference', i.paid_reference,
               'short_p',     case when i.status = 'paid'
                                   then greatest(public.invoice_total_p(i.id)
                                                 - coalesce(i.paid_amount_p,0), 0)
                                   else 0 end,
               'void_why',    i.void_why,
               'lines', coalesce((select jsonb_agg(jsonb_build_object(
                                    'description', l.description, 'qty', l.qty,
                                    'unit_amount_p', l.unit_amount_p,
                                    'amount_p', l.amount_p) order by l.sort)
                                   from public.invoice_lines l
                                  where l.invoice_id = i.id), '[]'::jsonb))
             order by coalesce(i.issued_on, i.created_at::date) desc, i.number desc)
        from public.invoices i where i.masjid_id = v_id), '[]'::jsonb),

    /* Stated here so a screen cannot forget it. The terms page promises every
       invoice will say this until the company is registered. */
    'vat_note', 'YSB Ventures Ltd is not VAT registered. No VAT is charged.'
  ) into v_out;

  return v_out;
end $$;
revoke all on function public.masjid_billing_summary(text) from public, anon, authenticated;
grant execute on function public.masjid_billing_summary(text) to authenticated;

-- ---------------------------------------------------------------------------
/* Who owes us money — across every masjid, for the top of the support console.
 *
 * A masjid who is not billed appears with billable=false and nulls, NOT as
 * someone owing zero. The difference matters: zero owed invites an invoice;
 * not billed is a contract. */
create or replace function public.billing_overview()
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_rows jsonb;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support may read the billing overview.'
      using errcode = '42501';
  end if;

  select coalesce(jsonb_agg(r order by r->>'slug'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'slug', m.slug,
      'name', m.name,
      'is_live', m.is_live,
      'billable', coalesce(b.billable, null),
      'not_billable_why', b.not_billable_why,
      'billing_set_up', b.masjid_id is not null,
      'plan', mp.plan_code,
      'band', mp.band,
      'cycle', b.cycle,
      'next_invoice_on', b.next_invoice_on,
      'setup_fee_state', b.setup_fee_state,
      'outstanding_p', coalesce((select sum(public.invoice_total_p(i.id))
                                   from public.invoices i
                                  where i.masjid_id = m.id and i.status = 'sent'), 0),
      'overdue_p',     coalesce((select sum(public.invoice_total_p(i.id))
                                   from public.invoices i
                                  where i.masjid_id = m.id and i.status = 'sent'
                                    and i.due_on < current_date), 0),
      'oldest_overdue_days', coalesce((select max(current_date - i.due_on)
                                   from public.invoices i
                                  where i.masjid_id = m.id and i.status = 'sent'
                                    and i.due_on < current_date), 0),
      'drafts', (select count(*) from public.invoices i
                  where i.masjid_id = m.id and i.status = 'draft')
    ) as r
    from public.masjids m
    left join public.masjid_billing b on b.masjid_id = m.id
    left join public.masjid_plan mp on mp.masjid_id = m.id and mp.ended_on is null
  ) x;

  return jsonb_build_object(
    'as_of', now(),
    'masajid', v_rows,
    'total_outstanding_p', coalesce((select sum(public.invoice_total_p(i.id))
                                       from public.invoices i where i.status = 'sent'), 0),
    'total_overdue_p',     coalesce((select sum(public.invoice_total_p(i.id))
                                       from public.invoices i
                                      where i.status = 'sent' and i.due_on < current_date), 0),
    /* The dunning list: what to chase, oldest first. Reported, not sent —
       there is no billing mailbox wired up, and a chaser that silently fails
       to send is worse than a list somebody reads. */
    'to_chase', coalesce((
      select jsonb_agg(jsonb_build_object(
               'masjid', m.slug, 'number', i.number,
               'due_on', i.due_on, 'days_overdue', current_date - i.due_on,
               'total_p', public.invoice_total_p(i.id),
               'email', b.billing_email, 'contact', b.billing_contact)
             order by i.due_on)
        from public.invoices i
        join public.masjids m on m.id = i.masjid_id
        left join public.masjid_billing b on b.masjid_id = i.masjid_id
       where i.status = 'sent' and i.due_on < current_date), '[]'::jsonb));
end $$;
revoke all on function public.billing_overview() from public, anon, authenticated;
grant execute on function public.billing_overview() to authenticated;
