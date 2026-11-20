-- 168 — the old accounts, kept as history, never as membership fees.
--
-- The masjid's QuickBooks ledger (every invoice and payment of every kind:
-- membership, donations, hire, ...) is imported here as a READ-ONLY historical
-- record, so the office can see a member's past transactions on their record
-- WITHOUT it being mistaken for membership fees owed. Membership balances stay
-- computed by membership_state() from membership_years/payments; this table is
-- never read by that calculation. It is reference only.
create table if not exists public.membership_legacy_ledger (
  id         uuid primary key default gen_random_uuid(),
  masjid_id  uuid not null references public.masjids(id) on delete cascade,
  member_id  uuid references public.masjid_members(id) on delete cascade,
  name_key   text not null,
  txn_date   date,
  txn_type   text,
  memo       text,
  reference  text,
  amount_p   integer,
  created_at timestamptz not null default now()
);
create index if not exists membership_legacy_ledger_member_idx
  on public.membership_legacy_ledger (member_id, txn_date);

alter table public.membership_legacy_ledger enable row level security;
alter table public.membership_legacy_ledger force row level security;
-- no policies: deny-all to the API roles; only SECURITY DEFINER functions and
-- the service_role importer reach it.
grant select, insert, delete on public.membership_legacy_ledger to service_role;

-- The office reader: a member's past transactions, newest first, with the two
-- old-account totals. verified_admin()-gated like the rest of the office screen.
create or replace function public.membership_legacy(p_member uuid)
returns jsonb language plpgsql security definer
set search_path to 'public','pg_temp' as $$
declare v_masjid uuid; v_rows jsonb;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();
  if not exists (select 1 from public.masjid_members where id = p_member and masjid_id = v_masjid) then
    raise exception 'No such member' using errcode = 'P0002';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', txn_date, 'type', txn_type, 'memo', memo,
           'reference', reference, 'amount_p', amount_p)
         order by txn_date desc nulls last, id), '[]'::jsonb)
    into v_rows
    from public.membership_legacy_ledger
   where member_id = p_member and masjid_id = v_masjid;
  return jsonb_build_object(
    'rows', v_rows,
    'count', jsonb_array_length(v_rows),
    'invoiced_p', coalesce((select sum(amount_p) from public.membership_legacy_ledger
                             where member_id = p_member and lower(coalesce(txn_type,'')) like 'invoice%'), 0),
    'paid_p',     coalesce((select sum(amount_p) from public.membership_legacy_ledger
                             where member_id = p_member and lower(coalesce(txn_type,'')) like 'payment%'), 0));
end $$;
revoke all on function public.membership_legacy(uuid) from public, anon;
grant execute on function public.membership_legacy(uuid) to authenticated;

-- The one-off importer that populated this table from the QuickBooks export on
-- 2026-11-20 (name-matched to the register) was a transient SECURITY DEFINER
-- helper, granted only to service_role and dropped immediately after the run.
-- It is not part of the schema; re-importing is a fresh, audited load.
