-- ===========================================================================
--  151 — donations belong to a masjid
--
--  Taiyabah Masjid · 8 November 2026
--
--  WHAT THIS FILE IS, AND WHY IT IS NOT A CHANGE
--  ---------------------------------------------
--  db/140 audited every function running with no CREATE statement in this
--  folder and found thirty-four. `donations` and the five functions that
--  touch it — record_public_donation() (both overloads),
--  record_donation_paid() (both overloads), gift_aid_to_claim(),
--  mark_gift_aid_claimed() and purge_old_donations() — were not among them,
--  because on 5 October 2026 they still matched db/022 and db/032 exactly:
--  one masjid, no masjid_id anywhere in the table or in any of the five.
--
--  Sometime after that they stopped matching. `donations` now carries a
--  `masjid_id uuid not null references masjids(id)`, and all five functions
--  were changed to scope by it — record_public_donation() and
--  record_donation_paid() each gained a whole second overload,
--  `(p_masjid text, ...)`, that the webhook now actually calls; the old
--  single-masjid ones are kept only for callers that still use them and
--  resolve the masjid through sole_masjid(), which raises the day a second
--  masjid exists. purge_old_donations() now loops masjids_to_purge() instead
--  of running unscoped. None of that went through this folder. It is exactly
--  the thing db/140 was written to stop happening again, happening again, in
--  the one table that is hardest to afford it in.
--
--  THIS FILE ITSELF WAS FIRST WRITTEN MISSING TWO OF THE FIVE —
--  record_donation_paid() and purge_old_donations() were only found on a
--  second, more thorough sweep (`pg_get_functiondef() ilike '%public.donations%'`
--  over every function, not a guess at which ones to check). Corrected before
--  this was ever pushed. The sweep that found them is worth repeating any
--  time this table grows another caller.
--
--  Read out of pg_get_functiondef() / pg_get_constraintdef() /
--  information_schema on 8 November 2026 and recorded verbatim below.
--  Applying this to production changes nothing — every statement is
--  CREATE OR REPLACE or IF NOT EXISTS over what is already there — and that
--  is the point: db/ can now rebuild this table and these five functions
--  without reading the live database first.
--
--  masjid_id_for(), current_masjid(), sole_masjid() and verified_admin() are
--  NOT reconstructed here. They are already in db/139 and db/140 and were
--  not part of the gap.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  The table: the one column db/022 could not have known about.
-- ---------------------------------------------------------------------------
alter table public.donations
  add column if not exists masjid_id uuid references public.masjids(id);

-- Backfilled once, by hand, the day this was retrofitted — every row that
-- existed before multi-tenancy had exactly one masjid to belong to. Nothing
-- here does that backfill; it only states, for a fresh database, that the
-- column may not be left null going forward.
do $$
begin
  if not exists (select 1 from pg_constraint
                  where conrelid = 'public.donations'::regclass
                    and conname  = 'donations_masjid_id_not_null') then
    alter table public.donations alter column masjid_id set not null;
  end if;
exception when others then
  -- A fresh table has no rows to violate this, so the only way this branch
  -- is reached is an existing deployment with an unbackfilled null still in
  -- it — and failing loudly here beats silently leaving the column nullable.
  raise exception 'donations.masjid_id has a null row — backfill it before re-running this file: %', sqlerrm;
end $$;

create index if not exists donations_masjid_id_idx on public.donations (masjid_id);

-- ---------------------------------------------------------------------------
--  record_public_donation — the single-masjid wrapper db/032 wrote.
--  Left exactly as it is live: it still resolves through sole_masjid() and
--  is not what the webhook calls, but it is somebody's call surface and this
--  file's job is to record what is there, not to decide it should change.
-- ---------------------------------------------------------------------------
create or replace function public.record_public_donation(
  p_session_id text,
  p_amount_p   integer,
  p_purpose    text,
  p_gift_aid   boolean,
  p_name       text,
  p_address    text,
  p_postcode   text
) returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $fn$
  select public.record_public_donation(
    (select slug from public.masjids where id = public.sole_masjid()),
    p_session_id, p_amount_p, p_purpose, p_gift_aid, p_name, p_address, p_postcode);
$fn$;

-- ---------------------------------------------------------------------------
--  record_public_donation — the one the webhook actually calls.
--  Identical to db/032's version with one change throughout: every lookup
--  and insert is scoped to masjid_id_for(p_masjid) instead of running
--  unscoped.
-- ---------------------------------------------------------------------------
create or replace function public.record_public_donation(
  p_masjid     text,
  p_session_id text,
  p_amount_p   integer,
  p_purpose    text,
  p_gift_aid   boolean,
  p_name       text,
  p_address    text,
  p_postcode   text
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid  uuid;
  v_ga      boolean := coalesce(p_gift_aid, false);
  v_purpose text := lower(nullif(btrim(coalesce(p_purpose, '')), ''));
  v_ref     text;
  v_id      uuid;
begin
  if p_session_id is null or btrim(p_session_id) = '' then
    raise exception 'A donation must carry the Stripe session it came from';
  end if;
  v_masjid := public.masjid_id_for(p_masjid);

  select id, reference into v_id, v_ref
    from public.donations
   where stripe_session_id = p_session_id and masjid_id = v_masjid;
  if found then
    return jsonb_build_object('reference', v_ref, 'status', 'paid',
                              'gift_aid', v_ga, 'already_recorded', true);
  end if;

  if v_purpose is not null and v_purpose not in ('general','sadaqah','lillah','newbuild') then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'donation_unknown_purpose',
            jsonb_build_object('session', p_session_id, 'purpose', p_purpose));
    v_purpose := null;
  end if;

  v_ref := 'DN-' || to_char(now(),'YY') || '-' ||
           lpad(nextval('public.donation_reference_seq')::text, 4, '0');

  insert into public.donations
    (masjid_id, reference, amount_p, status, stripe_session_id, paid_at, purpose,
     gift_aid, declaration_version, declared_at,
     donor_name, donor_address, donor_postcode)
  values
    (v_masjid, v_ref, p_amount_p, 'paid', p_session_id, now(), v_purpose, v_ga,
     case when v_ga then public.gift_aid_declaration_version() end,
     case when v_ga then now() end,
     case when v_ga then nullif(btrim(p_name), '') end,
     case when v_ga then nullif(btrim(p_address), '') end,
     case when v_ga then upper(nullif(btrim(p_postcode), '')) end);

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'donation_paid', jsonb_build_object(
            'reference', v_ref, 'amount_pence', p_amount_p,
            'purpose', v_purpose, 'gift_aid', v_ga,
            'declaration_version',
              case when v_ga then public.gift_aid_declaration_version() end));

  if v_ga and (nullif(btrim(coalesce(p_postcode,'')), '') is null
            or nullif(btrim(coalesce(p_name,'')), '') is null) then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'gift_aid_incomplete', jsonb_build_object(
              'reference', v_ref,
              'has_name', nullif(btrim(coalesce(p_name,'')), '') is not null,
              'has_postcode', nullif(btrim(coalesce(p_postcode,'')), '') is not null));
  end if;

  return jsonb_build_object('reference', v_ref, 'status', 'paid',
                            'gift_aid', v_ga, 'purpose', v_purpose,
                            'already_recorded', false);
end;
$fn$;

-- ---------------------------------------------------------------------------
--  What the Gift Aid screen reads — scoped to the signed-in administrator's
--  own masjid instead of the whole table.
-- ---------------------------------------------------------------------------
create or replace function public.gift_aid_to_claim()
returns table (reference text, donated_on date, donor_name text,
               donor_address text, donor_postcode text, amount_p integer,
               declaration_version text)
language sql stable security definer set search_path = public, pg_temp
as $fn$
  select d.reference, d.paid_at::date, d.donor_name, d.donor_address,
         d.donor_postcode, d.amount_p, d.declaration_version
    from public.donations d
   where d.masjid_id = public.current_masjid()
     and d.gift_aid
     and d.status = 'paid'
     and d.claimed_at is null
     and public.verified_admin()
   order by d.paid_at
$fn$;

-- ---------------------------------------------------------------------------
--  Marking a batch as claimed — scoped the same way, and recording who.
-- ---------------------------------------------------------------------------
create or replace function public.mark_gift_aid_claimed(p_references text[])
returns integer
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare v_n int; v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  update public.donations
     set claimed_at = now()
   where masjid_id = v_masjid and reference = any(p_references)
     and gift_aid and status = 'paid' and claimed_at is null;
  get diagnostics v_n = row_count;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'gift_aid_claimed', jsonb_build_object(
            'count', v_n, 'references', to_jsonb(p_references), 'by', auth.uid()));

  return v_n;
end $fn$;

-- ---------------------------------------------------------------------------
--  record_donation_paid — the single-masjid wrapper, same shape as
--  record_public_donation's: kept for whatever still calls it, resolving
--  through sole_masjid().
-- ---------------------------------------------------------------------------
create or replace function public.record_donation_paid(
  p_reference  text,
  p_session_id text,
  p_amount_p   integer default null,
  p_gift_aid   boolean default false,
  p_name       text default null,
  p_address    text default null,
  p_postcode   text default null
) returns jsonb
language sql
security definer
set search_path = public, pg_temp
as $fn$
  select public.record_donation_paid(
    (select slug from public.masjids where id = public.sole_masjid()),
    p_reference, p_session_id, p_amount_p, p_gift_aid, p_name, p_address, p_postcode);
$fn$;

-- ---------------------------------------------------------------------------
--  record_donation_paid — the one the webhook actually calls, for a
--  donation whose reference already exists (the "DN-" prefix in
--  stripe-webhook's KINDS map).
-- ---------------------------------------------------------------------------
create or replace function public.record_donation_paid(
  p_masjid     text,
  p_reference  text,
  p_session_id text,
  p_amount_p   integer default null,
  p_gift_aid   boolean default false,
  p_name       text default null,
  p_address    text default null,
  p_postcode   text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_ga boolean := coalesce(p_gift_aid, false); v_id uuid; v_masjid uuid;
begin
  if p_masjid is null then
    raise exception 'Which masjid is this donation for?' using errcode = '22023';
  end if;
  v_masjid := public.masjid_id_for(p_masjid);

  select id into v_id from public.donations
   where stripe_session_id = p_session_id and masjid_id = v_masjid;
  if found then
    return jsonb_build_object('reference', p_reference, 'status', 'paid',
                              'gift_aid', v_ga, 'already_recorded', true);
  end if;

  insert into public.donations
    (masjid_id, reference, amount_p, status, stripe_session_id, paid_at,
     gift_aid, declaration_version, declared_at, donor_name, donor_address, donor_postcode)
  values
    (v_masjid, p_reference, p_amount_p, 'paid', p_session_id, now(), v_ga,
     case when v_ga then public.gift_aid_declaration_version() end,
     case when v_ga then now() end,
     case when v_ga then nullif(trim(p_name), '') end,
     case when v_ga then nullif(trim(p_address), '') end,
     case when v_ga then upper(nullif(trim(p_postcode), '')) end);

  insert into public.admin_audit (masjid_id, action, detail)
  values (v_masjid, 'donation_paid', jsonb_build_object(
            'reference', p_reference, 'amount_pence', p_amount_p, 'gift_aid', v_ga,
            'declaration_version',
              case when v_ga then public.gift_aid_declaration_version() end));

  if v_ga and (nullif(trim(coalesce(p_postcode, '')), '') is null
            or nullif(trim(coalesce(p_name, '')), '') is null) then
    insert into public.admin_audit (masjid_id, action, detail)
    values (v_masjid, 'gift_aid_incomplete', jsonb_build_object(
              'reference', p_reference,
              'has_name', nullif(trim(coalesce(p_name, '')), '') is not null,
              'has_postcode', nullif(trim(coalesce(p_postcode, '')), '') is not null));
  end if;

  return jsonb_build_object('reference', p_reference, 'status', 'paid',
                            'gift_aid', v_ga, 'already_recorded', false);
end $fn$;

-- ---------------------------------------------------------------------------
--  purge_old_donations — Gift Aid retention, seven years, now across every
--  masjid this platform holds rather than just one.
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_donations()
returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $fn$
declare v_m uuid; v_n int; v_total int := 0;
begin
  if auth.uid() is not null and not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may purge donations.'
      using errcode = '42501';
  end if;

  for v_m in select * from public.masjids_to_purge() loop
    delete from public.donations
     where masjid_id = v_m
       and gift_aid and status = 'paid'
       and paid_at < now() - interval '7 years';
    get diagnostics v_n = row_count;

    insert into public.admin_audit (masjid_id, action, detail)
    values (v_m, 'donations_purged', jsonb_build_object('gift_aid_expired', v_n));

    v_total := v_total + v_n;
  end loop;

  return jsonb_build_object('gift_aid_expired', v_total);
end $fn$;

-- ---------------------------------------------------------------------------
--  Grants. Unchanged from db/022/db/032 — recorded so a rebuild does not
--  depend on remembering they were already right.
-- ---------------------------------------------------------------------------
revoke all on function public.record_public_donation(text,integer,text,boolean,text,text,text) from public;
grant execute on function public.record_public_donation(text,integer,text,boolean,text,text,text) to service_role;

revoke all on function public.record_public_donation(text,text,integer,text,boolean,text,text,text) from public;
grant execute on function public.record_public_donation(text,text,integer,text,boolean,text,text,text) to service_role;

revoke all on function public.record_donation_paid(text,text,integer,boolean,text,text,text) from public;
grant execute on function public.record_donation_paid(text,text,integer,boolean,text,text,text) to service_role;

revoke all on function public.record_donation_paid(text,text,text,integer,boolean,text,text,text) from public;
grant execute on function public.record_donation_paid(text,text,text,integer,boolean,text,text,text) to service_role;

grant execute on function public.gift_aid_to_claim()           to authenticated;
grant execute on function public.mark_gift_aid_claimed(text[]) to authenticated;

-- purge_old_donations() carries no grant beyond the owner (postgres) live —
-- it runs from a scheduled job, not an RPC call — so none is added here.

commit;
