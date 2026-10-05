-- ===========================================================================
--  141 — Stripe bills the masjid
--
--  MasjidOne · 5 October 2026
--
--  WHAT THIS IS FOR, IN ONE LINE: so that nobody has to be chased every month.
--
--  WHO DOES WHAT, AND WHY IT IS THIS WAY ROUND
--  -------------------------------------------
--  Stripe owns the schedule. It holds the subscription, charges on the date,
--  retries a failure, and sends the dunning emails. This database does NOT
--  drive the charge: 136's invoice_raise is still there for one-off and manual
--  invoices, but a recurring charge is Stripe's job, because the alternative
--  is writing retry-and-chase logic that Stripe already has and has tested
--  against every bank in the country.
--
--  So the ledger here becomes a MIRROR for anything Stripe raised. The masjid
--  holds Stripe's invoice — Stripe emails it and hosts the PDF — so this
--  table records STRIPE'S invoice number, not one of ours. A treasurer who
--  rings about invoice IN-1A2B3C4D-0001 must find that number in the support
--  console, and they would not if we had quietly renumbered it MO-00004.
--  invoices.source says which kind a row is, and the two can never be
--  confused: a stripe row must carry a stripe_invoice_id and a manual one
--  must not.
--
--  DIRECT DEBIT, NOT CARD, AND THAT IS THE POINT
--  ---------------------------------------------
--  The thing that stops the chasing is the MANDATE, not the code. A card on
--  file still has somebody chasing when it expires or the treasurer changes.
--  A Bacs mandate signed once keeps pulling until it is cancelled. It is also
--  what a charity bank account can actually do — a mosque treasurer often has
--  no corporate card at all — and it is cheaper: 1% capped at £2, against
--  roughly 1.5% + 20p for a UK card, which on £269 is £2 against £4.24.
--
--  THE COST OF BACS IS TIME, AND IT IS WRITTEN INTO THE SCHEMA. A mandate is
--  not usable the moment it is signed; Stripe confirms it over several working
--  days, and the first collection takes a few more. mandate_state exists so
--  the console can say "pending" rather than implying money is coming on
--  Friday. A Bacs payment can also be reversed AFTER it has succeeded, so
--  invoice_from_stripe takes Stripe's status every time it is called and will
--  move an invoice from paid back to sent. Nothing here assumes paid is final.
--
--  AMOUNTS STILL DO NOT LIVE IN POSTGRES. 136's rule holds and this file does
--  not weaken it: no price appears below. The figures come from PRICING_BANDS
--  in the website's lib/pricing-bands.ts, which the edge function imports
--  directly for exactly this reason, and Stripe is told the amount at the
--  point the subscription is created. This file only records what Stripe says
--  was charged.
--
--  WHAT IT CANNOT DO, AND SHOULD NOT PRETEND TO: the founding masjid is
--  billable = false under clause 4.2 of its agreement, so auto_bill is
--  refused for it by a CHECK rather than by remembering. On the day this is
--  applied the platform therefore has nobody to auto-bill. That is correct —
--  it is built so it is ready when the second masjid signs, not because there
--  is revenue to collect today.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. What Stripe knows about a masjid.
-- ---------------------------------------------------------------------------
alter table public.masjid_billing
  add column if not exists stripe_customer_id     text,
  add column if not exists stripe_subscription_id text,
  /* Bacs takes days to confirm, so a mandate has a state and not a boolean.
     'none'      nothing collected yet
     'pending'   the masjid signed; Stripe has not confirmed with the bank
     'active'    confirmed, collections will run
     'failed'    the bank refused it — somebody has to be told
     'cancelled' the masjid cancelled it at their bank, which they may do at
                 any time and without telling us, which is precisely why this
                 is kept rather than inferred */
  add column if not exists mandate_state          text not null default 'none',
  add column if not exists mandate_at             timestamptz,
  /* The switch. Off by default: turning a masjid's Direct Debit on is a
     decision, not a side effect of filling in a form. */
  add column if not exists auto_bill              boolean not null default false;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'masjid_billing_mandate') then
    alter table public.masjid_billing add constraint masjid_billing_mandate
      check (mandate_state in ('none','pending','active','failed','cancelled'));
  end if;
  /* auto_bill with no subscription is a promise nothing keeps. */
  if not exists (select 1 from pg_constraint where conname = 'masjid_billing_auto_needs_sub') then
    alter table public.masjid_billing add constraint masjid_billing_auto_needs_sub
      check (not auto_bill or stripe_subscription_id is not null);
  end if;
  /* THE FOUNDING CUSTOMER GUARD. billable = false means never invoice them,
     and a Direct Debit is an invoice that collects itself. Enforced here so
     that it survives somebody clicking the wrong switch at midnight. */
  if not exists (select 1 from pg_constraint where conname = 'masjid_billing_auto_needs_billable') then
    alter table public.masjid_billing add constraint masjid_billing_auto_needs_billable
      check (not auto_bill or billable);
  end if;
end $$;

/* One Stripe customer is one masjid, and one subscription is one masjid.
   Partial, because most rows have neither. Without these, a copy-pasted
   customer id would silently point two masajid at one bank mandate. */
create unique index if not exists masjid_billing_stripe_customer
  on public.masjid_billing (stripe_customer_id) where stripe_customer_id is not null;
create unique index if not exists masjid_billing_stripe_subscription
  on public.masjid_billing (stripe_subscription_id) where stripe_subscription_id is not null;

comment on column public.masjid_billing.mandate_state is
  'Where the Bacs Direct Debit mandate has got to. Bacs confirms over several working days, and a masjid can cancel at their bank without telling us, so this is recorded from Stripe rather than inferred.';
comment on column public.masjid_billing.auto_bill is
  'Whether Stripe is collecting this masjid monthly. Requires a subscription and requires billable = true, both by CHECK.';

-- ---------------------------------------------------------------------------
--  2. Which invoices are ours and which are Stripe's.
-- ---------------------------------------------------------------------------
alter table public.invoices
  add column if not exists source            text not null default 'manual',
  add column if not exists stripe_invoice_id text,
  /* Stripe's hosted copy. Given to the masjid and kept here so support can
     open the same document the treasurer is looking at. */
  add column if not exists stripe_hosted_url text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'invoices_source') then
    alter table public.invoices add constraint invoices_source
      check (source in ('manual','stripe'));
  end if;
  /* The two kinds cannot be confused, in either direction. A stripe row
     without an id could not be matched on the next webhook and would
     duplicate; a manual row WITH one would be overwritten by Stripe. */
  if not exists (select 1 from pg_constraint where conname = 'invoices_source_matches_id') then
    alter table public.invoices add constraint invoices_source_matches_id
      check ((source = 'stripe') = (stripe_invoice_id is not null));
  end if;
end $$;

create unique index if not exists invoices_stripe_id
  on public.invoices (stripe_invoice_id) where stripe_invoice_id is not null;

comment on column public.invoices.number is
  'For a manual invoice, MO-00001 from invoice_number_seq. For a Stripe one, STRIPE''S number — the masjid holds Stripe''s document and must be able to find that number in the console.';
comment on column public.invoices.source is
  'manual = raised here by invoice_raise. stripe = mirrored from a Stripe invoice by invoice_from_stripe, which may update it again whenever Stripe changes it.';

-- ---------------------------------------------------------------------------
--  3. Which tables are allowed not to belong to a masjid.
--
--  health_check() has asserted since the tenancy work that every table in
--  public carries a masjid_id, against a list of exceptions written as a
--  string literal in its body. THAT CHECK IS CURRENTLY FAILING, and has been
--  since 136: invoice_lines and platform_audit were both added without being
--  added to the literal. Two migrations, two chances to notice, neither taken.
--
--  A literal nobody updates is not a guard, it is a tripwire pointing at the
--  floor. So the exceptions become rows, each with a reason somebody has to
--  type, and adding a table is now an INSERT rather than an edit to a
--  two-hundred-line function that nobody wants to touch.
--
--  The table exempts itself, which is not a trick — it is a list of MasjidOne's
--  own bookkeeping, and it is one of those things.
-- ---------------------------------------------------------------------------
create table if not exists public.tenancy_exempt (
  table_name text primary key,
  why        text not null,
  added_at   timestamptz not null default now(),
  constraint tenancy_exempt_why check (btrim(why) <> '')
);
alter table public.tenancy_exempt enable row level security;
revoke all on public.tenancy_exempt from public, anon, authenticated;
comment on table public.tenancy_exempt is
  'Tables in public that legitimately do not carry a masjid_id, with the reason for each. Read by health_check. If you are adding a row, the question to answer first is whether the table really is not a masjid''s.';

insert into public.tenancy_exempt (table_name, why) values
  ('tenancy_exempt',   'This list itself. It is MasjidOne''s bookkeeping about the schema, not any masjid''s record.'),
  ('masjids',          'The register of masajid. It cannot belong to one of its own rows.'),
  ('platform_admins',  'Who may run MasjidOne. A supplier''s staff list, not a customer''s.'),
  ('platform_audit',   'MasjidOne''s own log of who was given and refused platform access. Added by 139 and missed off the literal.'),
  ('health_state',     'One row, the whole platform''s last known health. Deliberately not per-masjid.'),
  ('profiles',         'One row per auth user. A person may hold roles at more than one masjid, so the person is not the masjid''s.'),
  ('active_masjid',    'Which masjid a signed-in person is currently acting for. The answer is the column; it cannot also be the scope.'),
  ('invoice_lines',    'Belongs to its invoice, and the invoice carries the masjid. Added by 136 and missed off the literal.'),
  ('billing_events',   'Messages from Stripe to MasjidOne. Most name a masjid, some name none at all, and keeping the ones that match nothing is the entire point of the table.'),
  ('import_pupils',    'Register landing table. Temporary by design and due to be dropped.'),
  ('import_guardians', 'Register landing table. Temporary by design and due to be dropped.'),
  ('import_classes',   'Register landing table. Temporary by design and due to be dropped.'),
  ('import_siblings',  'Register landing table. Temporary by design and due to be dropped.')
on conflict (table_name) do nothing;

-- ---------------------------------------------------------------------------
--  4. Every message Stripe sends, exactly once.
--
--  STRIPE RETRIES, AND THAT IS A FEATURE UNTIL IT IS A SECOND INVOICE. A
--  webhook that answers slowly, or that answers 200 after the connection has
--  dropped, gets the same event again — for days, with backoff. Without this
--  table the second delivery of invoice.paid is a second payment in the
--  ledger, and the first anybody hears of it is a treasurer asking why they
--  have been charged twice.
--
--  THE ROW IS CLAIMED BEFORE THE WORK, NOT AFTER. billing_event_begin inserts
--  and returns whether this caller got the row; billing_event_done marks it
--  finished. An event claimed but never finished is retried, because a crash
--  halfway through must not be mistaken for success — which is why the guard
--  is `handled`, and not merely the row existing.
--
--  There is deliberately no masjid_id column, only matched_masjid, which may
--  be null: an event about a Stripe customer we do not recognise is the one
--  this table exists to keep.
-- ---------------------------------------------------------------------------
create table if not exists public.billing_events (
  id                 text primary key,
  type               text not null,
  stripe_customer_id text,
  matched_masjid     uuid references public.masjids(id) on delete set null,
  handled            boolean not null default false,
  received_at        timestamptz not null default now(),
  handled_at         timestamptz,
  detail             jsonb
);
alter table public.billing_events enable row level security;
revoke all on public.billing_events from public, anon, authenticated;
create index if not exists billing_events_unhandled
  on public.billing_events (received_at) where not handled;
create index if not exists billing_events_masjid
  on public.billing_events (matched_masjid, received_at desc);
comment on table public.billing_events is
  'One row per Stripe event id, so a retried delivery cannot write a second payment. Claimed before the work and marked handled after it, so a crash mid-way is retried rather than taken for success.';

create or replace function public.billing_event_begin(
  p_event text, p_type text, p_customer text default null, p_detail jsonb default null)
returns boolean
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_handled boolean; v_masjid uuid;
begin
  /* Internal only. auth.uid() is null for the service role the webhook uses;
     a signed-in person has no business claiming a Stripe event. Same shape as
     health_check() and purge_old_hall_bookings(). */
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Only MasjidOne may record a Stripe event.' using errcode = '42501';
  end if;
  if nullif(btrim(coalesce(p_event,'')),'') is null then
    raise exception 'A Stripe event has to have an id.' using errcode = '22023';
  end if;

  select masjid_id into v_masjid from public.masjid_billing
   where stripe_customer_id = p_customer;

  insert into public.billing_events (id, type, stripe_customer_id, matched_masjid, detail)
  values (p_event, p_type, p_customer, v_masjid, p_detail)
  on conflict (id) do nothing;

  select handled into v_handled from public.billing_events where id = p_event;
  /* True means "you have the job". A row that exists but is not handled is a
     previous attempt that died, so this caller gets it too. */
  return not coalesce(v_handled, false);
end $$;
revoke all on function public.billing_event_begin(text, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.billing_event_begin(text, text, text, jsonb) to service_role;

/* A failure that retrying cannot fix: an unknown customer, a draft, a status
   this ledger has no word for. Closed so Stripe stops, but with the reason
   kept against the event, because "Stripe sent something we could not use" is
   a sentence somebody has to be able to read later. The 42 donations were lost
   precisely because this row did not exist. */
create or replace function public.billing_event_failed(p_event text, p_why text)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Only MasjidOne may close a Stripe event.' using errcode = '42501';
  end if;
  update public.billing_events
     set handled = true, handled_at = now(),
         detail = coalesce(detail, '{}'::jsonb)
                  || jsonb_build_object('not_processed', p_why)
   where id = p_event;
  if not found then
    raise exception 'There is no Stripe event % to record a failure against.', p_event
      using errcode = '22023';
  end if;
end $$;
revoke all on function public.billing_event_failed(text, text) from public, anon, authenticated;
grant execute on function public.billing_event_failed(text, text) to service_role;

create or replace function public.billing_event_done(p_event text)
returns void
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Only MasjidOne may close a Stripe event.' using errcode = '42501';
  end if;
  update public.billing_events
     set handled = true, handled_at = now()
   where id = p_event;
end $$;
revoke all on function public.billing_event_done(text) from public, anon, authenticated;
grant execute on function public.billing_event_done(text) to service_role;

-- ---------------------------------------------------------------------------
--  5. A Stripe epoch, as a date.
--
--  Stripe sends every timestamp as seconds since 1970. Six places below need
--  one as a date and getting the null handling wrong in any of them writes a
--  1970 into an invoice, so it is written once.
-- ---------------------------------------------------------------------------
create or replace function public.stripe_day(payload jsonb, p_key text)
returns date
language sql immutable
set search_path to 'public', 'pg_temp'
as $$
  select case
    when payload is null then null
    when jsonb_typeof(payload -> p_key) is distinct from 'number' then null
    else (to_timestamp((payload ->> p_key)::bigint) at time zone 'Europe/London')::date
  end;
$$;
revoke all on function public.stripe_day(jsonb, text) from public, anon, authenticated;
grant execute on function public.stripe_day(jsonb, text) to service_role, authenticated;

-- ---------------------------------------------------------------------------
--  6. Pointing a masjid at its Stripe customer and subscription.
--
--  Called by the webhook when the masjid finishes signing the mandate, and by
--  the console if ever a link has to be repaired by hand. It does NOT turn
--  auto_bill on — that is a separate, deliberate act, because attaching a
--  subscription and deciding to start collecting are two different decisions
--  and conflating them is how somebody gets charged before they expected to.
-- ---------------------------------------------------------------------------
create or replace function public.billing_stripe_attach(p_masjid text, payload jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_state text;
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may link a masjid to Stripe.'
      using errcode = '42501';
  end if;

  select id into v_id from public.masjids where slug = p_masjid;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_masjid using errcode = '22023';
  end if;
  if not exists (select 1 from public.masjid_billing where masjid_id = v_id) then
    raise exception 'There are no billing details for % yet. Call billing_set first.', p_masjid
      using errcode = '22023';
  end if;

  v_state := coalesce(nullif(btrim(coalesce(payload->>'mandate_state','')),''), 'pending');
  if v_state not in ('none','pending','active','failed','cancelled') then
    raise exception 'A mandate cannot be in state "%".', v_state using errcode = '22023';
  end if;

  update public.masjid_billing set
    stripe_customer_id     = coalesce(nullif(btrim(coalesce(payload->>'customer','')),''),
                                      stripe_customer_id),
    stripe_subscription_id = coalesce(nullif(btrim(coalesce(payload->>'subscription','')),''),
                                      stripe_subscription_id),
    mandate_state          = v_state,
    mandate_at             = now(),
    updated_at             = now(),
    updated_by             = auth.uid()
  where masjid_id = v_id;

  /* The masjid's own audit trail, not MasjidOne's: a Direct Debit against
     their bank account is their business and they are entitled to see when it
     was set up and by whom. */
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'direct_debit_linked',
          jsonb_build_object('mandate_state', v_state,
                             'has_subscription',
                             nullif(btrim(coalesce(payload->>'subscription','')),'') is not null));

  return jsonb_build_object('masjid', p_masjid, 'mandate_state', v_state);
end $$;
revoke all on function public.billing_stripe_attach(text, jsonb) from public, anon, authenticated;
grant execute on function public.billing_stripe_attach(text, jsonb) to service_role, authenticated;

-- ---------------------------------------------------------------------------
--  7. The mandate moved.
--
--  Keyed on the Stripe customer rather than the slug, because that is all a
--  mandate event carries. An event for a customer we do not know raises, so
--  the webhook can log it as unmatched rather than silently doing nothing —
--  the lesson from the 42 donations that went unrecorded while every call
--  returned 200.
-- ---------------------------------------------------------------------------
create or replace function public.billing_mandate_set(
  p_customer text, p_state text, p_detail jsonb default null)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_slug text; v_was text;
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Only MasjidOne may change a mandate state.' using errcode = '42501';
  end if;
  if p_state not in ('none','pending','active','failed','cancelled') then
    raise exception 'A mandate cannot be in state "%".', p_state using errcode = '22023';
  end if;

  select b.masjid_id, m.slug, b.mandate_state into v_id, v_slug, v_was
    from public.masjid_billing b join public.masjids m on m.id = b.masjid_id
   where b.stripe_customer_id = p_customer;
  if v_id is null then
    raise exception 'No masjid is linked to Stripe customer %.', p_customer
      using errcode = '22023';
  end if;

  update public.masjid_billing
     set mandate_state = p_state, mandate_at = now(), updated_at = now()
   where masjid_id = v_id;

  /* A mandate that fails or is cancelled stops the money, so auto_bill comes
     off with it. Leaving it on would have the console claiming a masjid is
     being collected from when nothing can be collected. */
  if p_state in ('failed','cancelled') then
    update public.masjid_billing set auto_bill = false where masjid_id = v_id;
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'direct_debit_' || p_state,
          coalesce(p_detail, '{}'::jsonb) || jsonb_build_object('was', v_was));

  return jsonb_build_object('masjid', v_slug, 'mandate_state', p_state,
                            'auto_bill_stopped', p_state in ('failed','cancelled'));
end $$;
revoke all on function public.billing_mandate_set(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.billing_mandate_set(text, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
--  8. Mirroring one of Stripe's invoices into the ledger.
--
--  THIS IS THE ONE THAT HAS TO BE RIGHT, so what it refuses is as important
--  as what it writes:
--
--  * A DRAFT IS REFUSED. Stripe assigns an invoice number on finalisation, and
--    a row here without a number is a row an accountant cannot reconcile.
--  * AN UNKNOWN CUSTOMER IS REFUSED, loudly, rather than ignored. The webhook
--    turns that into an unmatched-payment record. 42 donations once went
--    unrecorded while every call returned 200, and the only reason it was ever
--    found was somebody counting.
--  * A LINE WHOSE UNIT AMOUNT CANNOT BE DETERMINED IS REFUSED. Stripe has
--    moved where the unit amount sits more than once across API versions, so
--    three places are tried; if none of them has it, this raises rather than
--    guessing from amount/quantity and writing a figure nobody chose.
--
--  AND IT IS CALLED AGAIN AND AGAIN FOR THE SAME INVOICE, on purpose. Stripe
--  sends finalised, then paid, and with Bacs it can send payment_failed days
--  AFTER a success because a Direct Debit can be reversed. So status is taken
--  from Stripe every time and an invoice may move from paid back to sent.
--  Nothing here treats paid as final, and the lines are rewritten each time
--  because Stripe is authoritative about its own document.
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
    coalesce(nullif(payload->>'tax','')::int,
             nullif(payload->>'total_taxes','')::int, 0),
    v_paid_on, v_paid_p,
    case when v_status = 'paid' then coalesce(p_method, 'stripe') end,
    case when v_status = 'paid'
         then coalesce(nullif(btrim(coalesce(payload->>'payment_intent','')),''),
                       nullif(btrim(coalesce(payload->>'charge','')),''), v_sid) end,
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

  delete from public.invoice_lines where invoice_id = v_inv;
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

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'invoice_from_stripe',
          jsonb_build_object('number', v_number, 'stripe_invoice', v_sid,
                             'status', v_status, 'stripe_status', v_stripe_status,
                             'lines', v_lines,
                             'total_p', public.invoice_total_p(v_inv)));

  return jsonb_build_object('masjid', v_slug, 'number', v_number,
                            'status', v_status, 'lines', v_lines,
                            'total_p', public.invoice_total_p(v_inv));
end $$;
revoke all on function public.invoice_from_stripe(jsonb, text) from public, anon, authenticated;
grant execute on function public.invoice_from_stripe(jsonb, text) to service_role;

-- ---------------------------------------------------------------------------
--  9. When Stripe will next collect.
--
--  masjid_billing.next_invoice_on is 136's column and it belongs to the MANUAL
--  path — invoice_raise advances it. Once Stripe owns the schedule that column
--  stops being the answer, and overloading it would leave nobody able to tell
--  which of the two was driving. So Stripe's date is its own column, and the
--  console shows whichever one applies.
-- ---------------------------------------------------------------------------
alter table public.masjid_billing
  add column if not exists stripe_next_charge_on date;

comment on column public.masjid_billing.stripe_next_charge_on is
  'When Stripe says the subscription next renews. Mirrored from the subscription, never computed here. next_invoice_on is the manual path''s equivalent and the two are deliberately separate.';

create or replace function public.billing_subscription_set(p_customer text, payload jsonb)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_slug text; v_status text; v_gone boolean;
begin
  if auth.uid() is not null and not public.is_platform_admin() then
    raise exception 'Only MasjidOne may change a subscription.' using errcode = '42501';
  end if;

  select b.masjid_id, m.slug into v_id, v_slug
    from public.masjid_billing b join public.masjids m on m.id = b.masjid_id
   where b.stripe_customer_id = p_customer;
  if v_id is null then
    raise exception 'No masjid is linked to Stripe customer %.', p_customer
      using errcode = '22023';
  end if;

  v_status := coalesce(payload->>'status','');
  /* Stripe's own words for "this is not collecting any more". canceled is
     spelled with one l by Stripe; ours is spelled properly in mandate_state,
     and the two are not the same field. */
  v_gone := v_status in ('canceled','incomplete_expired','unpaid');

  update public.masjid_billing set
    stripe_next_charge_on = public.stripe_day(payload, 'current_period_end'),
    /* auto_bill comes off with the subscription. The CHECK would refuse to
       leave it on with no subscription anyway, so this is the honest order
       rather than a second opinion. */
    auto_bill = case when v_gone then false else auto_bill end,
    stripe_subscription_id = case when v_gone then null else
      coalesce(nullif(btrim(coalesce(payload->>'id','')),''), stripe_subscription_id) end,
    updated_at = now()
  where masjid_id = v_id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(), 'subscription_' || coalesce(nullif(v_status,''),'updated'),
          jsonb_build_object('stopped', v_gone,
                             'next_charge_on', public.stripe_day(payload,'current_period_end')));

  return jsonb_build_object('masjid', v_slug, 'status', v_status, 'stopped', v_gone);
end $$;
revoke all on function public.billing_subscription_set(text, jsonb) from public, anon, authenticated;
grant execute on function public.billing_subscription_set(text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 10. The switch, and what the console shows.
--
--  billing_autobill_set is the only place auto_bill is turned on by a person,
--  and it refuses three things rather than letting a CHECK do it with an error
--  nobody can read: a masjid that is not billable, one with no subscription,
--  and one whose mandate is not active yet. The third is the Bacs one — a
--  mandate signed this morning cannot collect this month, and switching it on
--  would have the console promising money that is days away at best.
-- ---------------------------------------------------------------------------
create or replace function public.billing_autobill_set(
  p_masjid text, p_on boolean, p_why text default null)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_b public.masjid_billing%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may start or stop a Direct Debit.'
      using errcode = '42501';
  end if;

  select id into v_id from public.masjids where slug = p_masjid;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_masjid using errcode = '22023';
  end if;
  select * into v_b from public.masjid_billing where masjid_id = v_id;
  if not found then
    raise exception 'There are no billing details for % yet.', p_masjid using errcode = '22023';
  end if;

  if p_on then
    if not v_b.billable then
      raise exception 'This masjid is not billed: %. A Direct Debit is an invoice that collects itself, so this is refused for the same reason an invoice is.',
        v_b.not_billable_why using errcode = '42501';
    end if;
    if v_b.stripe_subscription_id is null then
      raise exception 'There is no Stripe subscription for % yet. The masjid has to sign the mandate first — send them the Direct Debit link from this screen.',
        p_masjid using errcode = '22023';
    end if;
    if v_b.mandate_state <> 'active' then
      raise exception 'The mandate for % is "%", not active. Bacs takes a few working days to confirm with the bank; nothing can be collected until it does.',
        p_masjid, v_b.mandate_state using errcode = '22023';
    end if;
  else
    if nullif(btrim(coalesce(p_why,'')),'') is null then
      raise exception 'Stopping a Direct Debit needs a reason, so that the next person knows whether to start it again.'
        using errcode = '22023';
    end if;
  end if;

  update public.masjid_billing
     set auto_bill = p_on,
         note = case when p_on then note
                     else btrim(coalesce(note || E'\n', '') || 'Direct Debit stopped: ' || p_why) end,
         updated_at = now(), updated_by = auth.uid()
   where masjid_id = v_id;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_id, auth.uid(),
          case when p_on then 'direct_debit_started' else 'direct_debit_stopped' end,
          jsonb_build_object('why', p_why));

  return jsonb_build_object('masjid', p_masjid, 'auto_bill', p_on);
end $$;
revoke all on function public.billing_autobill_set(text, boolean, text) from public, anon, authenticated;
grant execute on function public.billing_autobill_set(text, boolean, text) to authenticated;

create or replace function public.billing_direct_debit(p_masjid text)
returns jsonb
language plpgsql security definer
set search_path to 'public', 'pg_temp'
as $$
declare v_id uuid; v_b public.masjid_billing%rowtype;
begin
  if not public.is_platform_admin() then
    raise exception 'Only MasjidOne support, with two-step completed, may read billing.'
      using errcode = '42501';
  end if;
  select id into v_id from public.masjids where slug = p_masjid;
  if v_id is null then
    raise exception 'There is no masjid called %.', p_masjid using errcode = '22023';
  end if;
  select * into v_b from public.masjid_billing where masjid_id = v_id;
  if not found then
    return jsonb_build_object('set_up', false,
      'why', 'No billing details yet. Fill those in first.');
  end if;

  return jsonb_build_object(
    'set_up',          v_b.stripe_customer_id is not null,
    /* THE ID ITSELF, and not merely whether there is one. /start reuses the
       customer when there already is one; without this it would create a
       second Stripe customer on a second attempt, and a masjid with two
       customers can end up with two mandates against one bank account. Only a
       two-step platform admin can reach this function at all. */
    'stripe_customer_id', v_b.stripe_customer_id,
    'billable',        v_b.billable,
    'not_billable_why',v_b.not_billable_why,
    'auto_bill',       v_b.auto_bill,
    'mandate_state',   v_b.mandate_state,
    'mandate_at',      v_b.mandate_at,
    'has_subscription',v_b.stripe_subscription_id is not null,
    'next_charge_on',  v_b.stripe_next_charge_on,
    'cycle',           v_b.cycle,
    'billing_email',   v_b.billing_email,
    'setup_fee_state', v_b.setup_fee_state,
    /* The plan and band in force. The edge function needs them to work out
       the amount from PRICING_BANDS, and it must not be told the amount by a
       browser — so it asks for the band and does the arithmetic itself. */
    'plan_code',       (select plan_code from public.masjid_plan
                         where masjid_id = v_id and ended_on is null),
    'band',            (select band from public.masjid_plan
                         where masjid_id = v_id and ended_on is null),
    /* Said in a sentence, because "pending" on its own reads like a delay
       somebody caused rather than how Bacs works. */
    'where_it_stands', case
      when not v_b.billable then 'Not billed: ' || coalesce(v_b.not_billable_why,'no reason recorded') || '.'
      when v_b.stripe_customer_id is null then 'Nothing set up. Send them the Direct Debit link to start.'
      when v_b.mandate_state = 'pending' then 'They have signed. Bacs is confirming it with their bank, which takes a few working days — nothing can be collected until it does.'
      when v_b.mandate_state = 'failed' then 'The bank refused the mandate. Somebody has to ring them; the Direct Debit has been switched off.'
      when v_b.mandate_state = 'cancelled' then 'They cancelled it at their bank. The Direct Debit has been switched off.'
      when v_b.mandate_state = 'active' and v_b.auto_bill then 'Collecting monthly by Direct Debit. Stripe raises the invoice, chases a failure and emails them.'
      when v_b.mandate_state = 'active' then 'The mandate is live but collection has not been switched on yet.'
      else 'Nothing set up yet.' end);
end $$;
revoke all on function public.billing_direct_debit(text) from public, anon, authenticated;
grant execute on function public.billing_direct_debit(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. health_check(), with the exempt list read from a table.
--
--  THE ONLY CHANGE IS THE EXEMPT LIST. Everything else is byte-for-byte what
--  140 captured, lifted from that file by script rather than retyped, so the
--  diff between the two is the four lines that matter and nothing else.
--
--  Why it had to change: the check has been FAILING since 136. invoice_lines
--  and platform_audit were added without being added to the string literal in
--  its body, so the platform's own health has read "fail" on
--  every_table_has_a_masjid for a month and nobody was told, because nothing
--  reads health_watch's state unless it changes and it had already changed.
--  Adding billing_events and tenancy_exempt here would have been the third
--  and fourth time. The list is rows now.
-- ---------------------------------------------------------------------------
create or replace function public.health_check()
 returns jsonb
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_checks  jsonb := '[]'::jsonb;
  v_failing text[] := '{}';
  v_ok      boolean;
  v_detail  text;
  v_n       int;
  v_row     record;
  v_jrow    jsonb;
begin
  --  db/122: internal. The scheduler and the database's owner have no
  --  session; anybody with one must be a verified administrator.
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'That is for the masjid''s administrators.'
      using errcode = '42501';
  end if;
  begin
    select count(*) into v_n from cron.job_run_details
     where start_time > now() - interval '24 hours' and status <> 'succeeded';
    v_ok := (v_n = 0);
    v_detail := v_n || ' failed scheduled run(s) in the last 24 hours';
  exception when others then
    v_ok := false; v_detail := 'could not read cron history: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','scheduled_jobs_succeeding','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'scheduled_jobs_succeeding'); end if;

  begin
    select count(*) into v_n from cron.job where not active;
    v_ok := (v_n = 0);
    v_detail := v_n || ' scheduled job(s) disabled';
  exception when others then
    v_ok := false; v_detail := 'could not read cron jobs: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','scheduled_jobs_enabled','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'scheduled_jobs_enabled'); end if;

  begin
    select count(*) into v_n from cron.job_run_details d join cron.job j on j.jobid=d.jobid
     where j.command like '%purge_expired_holds%' and d.start_time > now() - interval '35 minutes';
    v_ok := (v_n > 0);
    v_detail := case when v_ok then 'the ten-minute job ran within the last 35 minutes'
                     else 'the ten-minute job has not run for over 35 minutes - the scheduler may be stalled' end;
  exception when others then
    v_ok := false; v_detail := 'could not read cron history: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','scheduler_alive','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'scheduler_alive'); end if;

  select count(*) into v_n from public.masjids mj
   where mj.is_live and (select count(*) from public.app_settings s
                          where s.masjid_id = mj.id
                            and s.key in ('notify_url','notify_key','notify_secret')) < 3;
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','notify_configured','ok',v_ok,
    'detail', v_n || ' live masjid(s) missing notify settings - their forms would reach nobody');
  if not v_ok then v_failing := array_append(v_failing, 'notify_configured'); end if;

  select count(*) into v_n from public.masjids mj
   where (select count(*) from public.user_roles r
           where r.masjid_id = mj.id and r.role = 'admin') < 2;
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','two_admins_each','ok',v_ok,
    'detail', v_n || ' masjid(s) with fewer than two administrators');
  if not v_ok then v_failing := array_append(v_failing, 'two_admins_each'); end if;

  select count(*) into v_n from public.masjids mj
   where mj.is_live and not exists (
     select 1 from public.prayer_years y
      where y.masjid_id = mj.id
        and y.year = extract(year from (now() at time zone 'Europe/London'))::int
        and y.published);
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','prayer_times_published','ok',v_ok,
    'detail', v_n || ' live masjid(s) with no published timetable for this year');
  if not v_ok then v_failing := array_append(v_failing, 'prayer_times_published'); end if;

  v_ok := true; v_detail := 'every live masjid answers on all four public calls';
  for v_row in select slug from public.masjids where is_live loop
    begin
      perform public.courses_public(v_row.slug);
      perform public.notices_live(v_row.slug);
      perform (select count(*) from public.hall_availability(v_row.slug));
      perform public.prayer_year(v_row.slug, extract(year from now())::int);
    exception when others then
      v_ok := false;
      v_detail := v_row.slug || ' fails a public call: ' || sqlerrm;
    end;
  end loop;
  v_checks := v_checks || jsonb_build_object('check','public_surface','ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'public_surface'); end if;

  select count(*) into v_n from information_schema.columns
   where table_schema='public' and column_name='masjid_id' and is_nullable='YES';
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','tenancy_enforced','ok',v_ok,
    'detail', v_n || ' table(s) allow a row with no masjid');
  if not v_ok then v_failing := array_append(v_failing, 'tenancy_enforced'); end if;

  select count(*) into v_n from public.masjids;
  v_ok := (v_n <= 1);
  v_checks := v_checks || jsonb_build_object('check','compatibility_shims','ok',v_ok,
    'detail', case when v_n <= 1
      then 'one masjid, so the old single-masjid calls still resolve'
      else v_n || ' masjids - every caller must now pass a slug, and any that does not is failing' end);
  if not v_ok then v_failing := array_append(v_failing, 'compatibility_shims'); end if;

  select coalesce(string_agg(c.relname, ', ' order by c.relname), '') into v_detail
    from pg_class c
   where c.relnamespace = 'public'::regnamespace
     and c.relkind = 'r'
     and c.relname not in (select e.table_name from public.tenancy_exempt e)
     and not exists (select 1 from pg_attribute a
                      where a.attrelid = c.oid and a.attname = 'masjid_id'
                        and not a.attisdropped);
  v_ok := (v_detail = '');
  v_checks := v_checks || jsonb_build_object('check','every_table_has_a_masjid','ok',v_ok,
    'detail', case when v_ok
      then 'every table in public belongs to a masjid, or has a row in tenancy_exempt saying why not'
      else 'table(s) with no masjid_id and no row in tenancy_exempt: ' || v_detail
           || '. Either give it a masjid_id or add it to tenancy_exempt with a reason.' end);
  if not v_ok then v_failing := array_append(v_failing, 'every_table_has_a_masjid'); end if;


  --  THE LIST/RECORD SPLIT, CHECKED RATHER THAN ASSERTED ONCE.
  --  077 asserted this in a DO block that ran once at migration time and is
  --  long gone. Nothing re-ran it, so nothing would have stopped a detail
  --  column being added to madrasah_roll() afterwards. This runs whenever
  --  health is read.
  begin
    v_jrow := public.madrasah_list_minimisation();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false; v_detail := 'the minimisation guard itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','lists_carry_marks_not_detail',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'lists_carry_marks_not_detail'); end if;

  --  THE PUBLISHED PRIVACY NOTICE, CHECKED AGAINST THE SCHEMA.
  --  Added by 081. Three versions of that notice have been made false by
  --  a later migration and every one was found by a person happening to
  --  look. This runs whenever health is read.
  begin
    v_jrow := public.madrasah_notice_matches_schema();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the notice check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','notice_matches_the_schema',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'notice_matches_the_schema'); end if;

  --  CAN THESE ACCOUNTS ACTUALLY BE SIGNED IN TO? Added by 094, after all
  --  thirty-nine teacher logins turned out to be unusable while every
  --  database-side check on them passed.
  begin
    v_jrow := public.auth_rows_readable();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the auth row check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','auth_rows_readable',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'auth_rows_readable'); end if;

  --  CAN EVERY PARENT LOGIN REACH ITS FAMILY, AND ONLY ITS FAMILY? Added by
  --  119. A login that reaches nothing is how a family gets told to sign in
  --  to an empty screen; a login that also holds a staff grant reaches too
  --  much.
  begin
    v_jrow := public.parent_logins_reach_something();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the parent login check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','parent_logins_reach_something',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'parent_logins_reach_something'); end if;

  --  A CHILD ON TWO ACTIVE ROLLS CAN HOLD ONLY ONE MARK. Added by 102,
  --  after the reviewer found submit_register can read complete on
  --  another class's marking for exactly these children. See the long
  --  comment above pupils_on_two_active_rolls() in db/102.
  begin
    v_jrow := public.pupils_on_two_active_rolls();
    v_ok := (v_jrow ->> 'ok')::boolean;
    v_detail := v_jrow ->> 'detail';
  exception when others then
    v_ok := false;
    v_detail := 'the shared-roll check itself failed: ' || sqlerrm;
  end;
  v_checks := v_checks || jsonb_build_object('check','pupils_on_two_active_rolls',
                                             'ok',v_ok,'detail',v_detail);
  if not v_ok then v_failing := array_append(v_failing, 'pupils_on_two_active_rolls'); end if;


  select count(*) into v_n from pg_class c
   where c.relnamespace = 'public'::regnamespace and c.relkind = 'r'
     and c.relname in ('import_pupils','import_guardians','import_classes','import_siblings');
  v_ok := (v_n = 0);
  v_checks := v_checks || jsonb_build_object('check','register_landing_tables_dropped',
    'ok', v_ok, 'detail', case when v_ok
      then 'the register landing tables are gone, as they should be'
      else v_n || ' landing tables still hold a second copy of the register, '
           || 'medical notes included. Sealed, but keep them only while the '
           || 'questionable dates and sibling pairs are still being settled.' end);
  if not v_ok then v_failing := array_append(v_failing, 'register_landing_tables_dropped'); end if;

  return jsonb_build_object(
    'status', case when array_length(v_failing,1) is null then 'ok' else 'fail' end,
    'failing', to_jsonb(v_failing),
    'checked_at', now(),
    'checks', v_checks);
end $function$;

revoke all on function public.health_check() from public, anon;
grant execute on function public.health_check() to authenticated;

commit;
