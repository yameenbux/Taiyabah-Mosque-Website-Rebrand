-- ===========================================================================
--  160 — membership: what the office writes, and bringing the sheet in
--
--  Taiyabah Masjid · 12 November 2026
--
--  EVERY FUNCTION HERE RECORDS WHO DID IT. 089 found seven actions a person
--  performs that did not record the person, and this file is written after
--  that rather than before it: `actor` is auth.uid() on every audit row, and
--  `recorded_by` is auth.uid() on every payment. A waiver with nobody
--  against it is the thing an audit cannot answer, and 157's
--  membership_year_waiver_is_attributed makes the database refuse one.
--
--  RAISING A YEAR IS SAFE TO PRESS TWICE. It is the Ramadan ritual — one
--  press makes a charge for every member at this year's rate — and the
--  unique index in 157 is what makes the second press a no-op rather than a
--  second bill for five hundred people.
--
--  THE IMPORT IS WHERE THE ARREARS COME FROM. The register arrives as an
--  Excel sheet and it is not a list of members: it is members AND every
--  payment they have made, at the fee that applied in each year. A register
--  that began in 2026 would tell a man who has paid for ten years that he
--  owes nothing and show him no history, and would tell the office nothing
--  about who is actually behind — which is the whole reason for building
--  this. membership_import_payment() therefore takes a year and a date in
--  the past, which no other write path here will accept.
--
--  Prerequisites: 157, 158, 159. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. What a year costs
-- ---------------------------------------------------------------------------
create or replace function public.membership_set_rate(
  p_year integer, p_fee_p integer, p_note text default null)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();

  insert into public.membership_rates (masjid_id, year, fee_p, note)
  values (v_masjid, p_year, p_fee_p, p_note)
  on conflict (masjid_id, year)
    do update set fee_p = excluded.fee_p, note = excluded.note, updated_at = now();

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'membership_rate_set',
          jsonb_build_object('year', p_year, 'fee_pence', p_fee_p));

  return jsonb_build_object('ok', true, 'year', p_year, 'fee_p', p_fee_p);
end;
$$;

revoke all on function public.membership_set_rate(integer, integer, text) from public, anon;
grant execute on function public.membership_set_rate(integer, integer, text) to authenticated;

-- ---------------------------------------------------------------------------
--  2. Raise this year's charges for everybody still on the register
-- ---------------------------------------------------------------------------
create or replace function public.membership_raise_year(p_year integer)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_fee integer; v_made integer;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();

  select fee_p into v_fee from public.membership_rates
  where masjid_id = v_masjid and year = p_year;

  if v_fee is null then
    raise exception 'Set the fee for % before raising its charges', p_year
      using errcode = 'P0002';
  end if;

  with made as (
    insert into public.membership_years
      (masjid_id, member_id, year, fee_p, created_by)
    select v_masjid, mm.id, p_year, v_fee, auth.uid()
    from public.masjid_members mm
    where mm.masjid_id = v_masjid and mm.left_on is null
    on conflict (member_id, year) do nothing
    returning 1
  )
  select count(*) into v_made from made;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'membership_year_raised',
          jsonb_build_object('year', p_year, 'fee_pence', v_fee, 'charges_made', v_made));

  return jsonb_build_object('ok', true, 'year', p_year, 'made', v_made);
end;
$$;

revoke all on function public.membership_raise_year(integer) from public, anon;
grant execute on function public.membership_raise_year(integer) to authenticated;

-- ---------------------------------------------------------------------------
--  3. Cash, the terminal, a transfer, a cheque
--
--  Two taps, because most of the fee still arrives this way across four
--  weeks of Ramadan and a form that takes six fields does not get used — the
--  sheet gets used instead, and then there are two registers.
-- ---------------------------------------------------------------------------
create or replace function public.membership_record_payment(
  p_member    uuid,
  p_year      integer,
  p_amount_p  integer,
  p_method    text,
  p_reference text default null,
  p_note      text default null
)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();

  if p_method not in ('cash', 'terminal', 'bank', 'cheque', 'other') then
    raise exception 'A payment taken by the office is cash, terminal, bank, cheque or other'
      using errcode = '22023';
  end if;

  if not exists (select 1 from public.masjid_members
                  where id = p_member and masjid_id = v_masjid) then
    raise exception 'No such member' using errcode = 'P0002';
  end if;

  --  A payment against a year nobody charged would sit in the table
  --  contributing to no balance — invisible money, which is worse than a
  --  refusal somebody has to read.
  if not exists (select 1 from public.membership_years
                  where member_id = p_member and year = p_year) then
    raise exception 'There is no % charge on this member''s record to pay', p_year
      using errcode = 'P0002';
  end if;

  insert into public.membership_payments
    (masjid_id, member_id, year, amount_p, method, bank_reference, note, recorded_by)
  values (v_masjid, p_member, p_year, p_amount_p, p_method,
          nullif(btrim(coalesce(p_reference, '')), ''),
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid());

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'membership_payment_recorded',
          jsonb_build_object('member', p_member, 'year', p_year,
                             'amount_pence', p_amount_p, 'method', p_method));

  return jsonb_build_object('ok', true) || public.membership_state(p_member);
end;
$$;

revoke all on function public.membership_record_payment(uuid, integer, integer, text, text, text)
  from public, anon;
grant execute on function public.membership_record_payment(uuid, integer, integer, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
--  4. Setting a year aside
--
--  The masjid is a charity and cannot compel anybody. This is the mechanism
--  that makes the member's screen honest when it says the office can set a
--  year aside — without it that sentence is decoration.
--
--  A NOTE IS REQUIRED. Not out of bureaucracy: a waived year with no reason
--  on it looks identical to a mistake, and in two years nobody will be able
--  to tell whether the trustees agreed it or somebody fat-fingered a screen.
-- ---------------------------------------------------------------------------
create or replace function public.membership_waive_year(
  p_member uuid, p_year integer, p_note text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_fee integer; v_paid integer;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();

  if length(btrim(coalesce(p_note, ''))) < 3 then
    raise exception 'Say why the year is being set aside' using errcode = '22023';
  end if;

  select my.fee_p into v_fee
  from public.membership_years my
  join public.masjid_members mm on mm.id = my.member_id
  where my.member_id = p_member and my.year = p_year and mm.masjid_id = v_masjid;

  if v_fee is null then
    raise exception 'There is no % charge on this member''s record', p_year
      using errcode = 'P0002';
  end if;

  select coalesce(sum(amount_p), 0) into v_paid
  from public.membership_payments
  where member_id = p_member and year = p_year;

  --  Waiving a year that is already paid would put the member in credit and
  --  drop them off the Still owing screen, which is how a mistake hides.
  if v_paid > 0 then
    raise exception 'Something has already been paid towards %. Refund it first, or add a note instead', p_year
      using errcode = '22023';
  end if;

  update public.membership_years
     set waived_p = v_fee, waiver_note = btrim(p_note),
         waived_by = auth.uid(), waived_at = now()
   where member_id = p_member and year = p_year;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'membership_year_waived',
          jsonb_build_object('member', p_member, 'year', p_year,
                             'amount_pence', v_fee, 'reason', btrim(p_note)));

  return jsonb_build_object('ok', true) || public.membership_state(p_member);
end;
$$;

revoke all on function public.membership_waive_year(uuid, integer, text) from public, anon;
grant execute on function public.membership_waive_year(uuid, integer, text) to authenticated;

-- ---------------------------------------------------------------------------
--  5. Bringing the sheet in
--
--  `p_ref_no` null means "give them the next one". Supplying it lets the
--  import keep the numbers the masjid already uses, if the sheet has any.
-- ---------------------------------------------------------------------------
create or replace function public.membership_upsert_member(
  p_full_name    text,
  p_house_no     text default null,
  p_address_line text default null,
  p_postcode     text default null,
  p_telephone    text default null,
  p_email        text default null,
  p_member_since date default null,
  p_ref_no       integer default null,
  p_note         text default null
)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_ref integer; v_id uuid; v_new boolean := false;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();

  --  Whitespace is collapsed HERE, on the way in, because the lookup
  --  compares lower(btrim(full_name)) against an index and a stored double
  --  space would make a member unfindable by the name they typed correctly.
  p_full_name := btrim(regexp_replace(coalesce(p_full_name, ''), '\s+', ' ', 'g'));

  v_ref := coalesce(p_ref_no,
    (select coalesce(max(ref_no), 0) + 1 from public.masjid_members
      where masjid_id = v_masjid));

  select id into v_id from public.masjid_members
  where masjid_id = v_masjid and ref_no = v_ref;

  --  WRAPPED SO ONLY THE SQLSTATE ESCAPES, for the reason CLAUDE.md gives
  --  about madrasah_pupils and which applies to this table just as much. A
  --  failed CHECK on masjid_members prints THE WHOLE ROW into Postgres's
  --  error DETAIL — name, address, postcode, telephone, email — and with
  --  log_min_error_statement = error that reaches the Supabase-retained
  --  server log, not just the caller. A rollback does not take it back.
  --  Proved by watching membership_year_waiver_within_fee do exactly this on
  --  the sister table, where the row happens to hold nothing personal.
  --
  --  sqlerrm is NOT safe here: for a constraint violation it carries the
  --  DETAIL. sqlstate only.
  begin
    if v_id is null then
      insert into public.masjid_members
        (masjid_id, ref_no, full_name, house_no, address_line, postcode,
         telephone, email, member_since, note, created_by)
      values (v_masjid, v_ref, p_full_name, p_house_no, p_address_line, p_postcode,
              p_telephone, p_email, p_member_since, p_note, auth.uid())
      returning id into v_id;
      v_new := true;
    else
      update public.masjid_members
         set full_name = p_full_name, house_no = p_house_no,
             address_line = p_address_line, postcode = p_postcode,
             telephone = p_telephone,
             email = coalesce(p_email, email),
             member_since = coalesce(p_member_since, member_since),
             note = p_note, updated_at = now()
       where id = v_id;
    end if;
  exception when others then
    raise exception 'That member record was refused (%). Check the name, postcode and telephone lengths.', sqlstate
      using errcode = '22023';
  end;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(),
          case when v_new then 'membership_member_added' else 'membership_member_edited' end,
          --  The reference, never the name. An audit log the whole committee
          --  can read should not be a second copy of the register.
          jsonb_build_object('ref_no', v_ref));

  return jsonb_build_object('ok', true, 'id', v_id, 'ref_no', v_ref, 'new', v_new);
end;
$$;

revoke all on function public.membership_upsert_member(text,text,text,text,text,text,date,integer,text)
  from public, anon;
grant execute on function public.membership_upsert_member(text,text,text,text,text,text,date,integer,text)
  to authenticated;

-- ---------------------------------------------------------------------------
--  6. A year the sheet says was already paid
--
--  Creates the charge as well as the payment, at the fee that applied then,
--  because a payment against a year nobody charged contributes to no
--  balance. Method is 'legacy': the sheet does not record how it was paid
--  and 'cash' would be a guess dressed up as a fact.
-- ---------------------------------------------------------------------------
create or replace function public.membership_import_payment(
  p_member      uuid,
  p_year        integer,
  p_amount_p    integer default null,   --  null = the year's full fee
  p_received_on date    default null,
  p_note        text    default null
)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_fee integer;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();

  if not exists (select 1 from public.masjid_members
                  where id = p_member and masjid_id = v_masjid) then
    raise exception 'No such member' using errcode = 'P0002';
  end if;

  select fee_p into v_fee from public.membership_rates
  where masjid_id = v_masjid and year = p_year;

  if v_fee is null then
    raise exception 'Set the fee for % before importing its payments — importing at today''s rate would overcharge the earlier years', p_year
      using errcode = 'P0002';
  end if;

  insert into public.membership_years (masjid_id, member_id, year, fee_p, created_by)
  values (v_masjid, p_member, p_year, v_fee, auth.uid())
  on conflict (member_id, year) do nothing;

  insert into public.membership_payments
    (masjid_id, member_id, year, amount_p, method, received_on, note, recorded_by)
  values (v_masjid, p_member, p_year, coalesce(p_amount_p, v_fee), 'legacy',
          coalesce(p_received_on, make_date(p_year, 6, 30)),
          nullif(btrim(coalesce(p_note, '')), ''), auth.uid());

  return jsonb_build_object('ok', true) || public.membership_state(p_member);
end;
$$;

revoke all on function public.membership_import_payment(uuid, integer, integer, date, text)
  from public, anon;
grant execute on function public.membership_import_payment(uuid, integer, integer, date, text)
  to authenticated;

-- ---------------------------------------------------------------------------
--  7. Somebody has left
--
--  Not a delete. The payments they made are the charity's own accounting
--  record and outlive their membership.
-- ---------------------------------------------------------------------------
create or replace function public.membership_mark_left(
  p_member uuid, p_on date default null, p_note text default null)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_ref integer;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();

  update public.masjid_members
     set left_on = coalesce(p_on, current_date),
         note = coalesce(nullif(btrim(coalesce(p_note, '')), ''), note),
         updated_at = now()
   where id = p_member and masjid_id = v_masjid
   returning ref_no into v_ref;

  if v_ref is null then
    raise exception 'No such member' using errcode = 'P0002';
  end if;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'membership_member_left',
          jsonb_build_object('ref_no', v_ref, 'on', coalesce(p_on, current_date)));

  return jsonb_build_object('ok', true, 'ref_no', v_ref);
end;
$$;

revoke all on function public.membership_mark_left(uuid, date, text) from public, anon;
grant execute on function public.membership_mark_left(uuid, date, text) to authenticated;

commit;
