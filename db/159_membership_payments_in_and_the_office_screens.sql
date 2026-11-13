-- ===========================================================================
--  159 — membership: money in, and the screens the office works from
--
--  Taiyabah Masjid · 12 November 2026
--
--  WHAT ARRIVES AND FROM WHERE. Three ways, one table:
--
--    the webhook    mark_membership_fee_paid() — a card payment Stripe has
--                   already taken. Nobody performed it, so recorded_by stays
--                   null (089: an honest null beats a pretend actor).
--    the office     membership_record_payment() — cash, the card terminal, a
--                   transfer, a cheque. Most of the fee still arrives this
--                   way, across four weeks of Ramadan, so it is two taps.
--    the import     membership_import_payment() — the years already paid,
--                   out of the Excel sheet, method 'legacy' because the sheet
--                   does not say how they were paid and guessing 'cash' would
--                   make the figure look researched.
--
--  THE WEBHOOK ALLOCATES BY THE YEARS IN THE SESSION, NOT BY A RULE. The
--  Worker put the years it quoted into the Checkout Session's metadata, so
--  the webhook marks exactly those. It does not divide the amount by the fee
--  and guess, and it does not apply oldest-first as a policy — the member
--  chose between two buttons and the metadata records which.
--
--  BUT IT STILL COPES WITH THE WORLD MOVING UNDER IT. Somebody can pay 2024
--  at the counter in the minute between the quote and the card going
--  through. So the allocation walks the named years oldest-first, puts
--  against each year only what that year still needs, and if anything is
--  left over it goes on the current year as an overpayment with a note. The
--  one thing it will not do is lose the difference: money that arrived and
--  is not written down anywhere is the failure this whole function exists to
--  prevent.
--
--  AND IT WRITES THE EMAIL BACK. Stripe collects an address at checkout to
--  send its own receipt. The register has almost none, which is why the
--  Ramadan reminder cannot reach anybody today. Every online payment fills
--  one in. It only ever fills a BLANK — it never overwrites an address the
--  office has, because the office's copy was given deliberately.
--
--  Prerequisites: 157, 158. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. A card payment Stripe has taken
-- ---------------------------------------------------------------------------
create or replace function public.mark_membership_fee_paid(
  p_masjid     uuid,
  p_reference  text,
  p_session_id text,
  p_amount_p   integer,
  p_years      text,     --  comma-separated, from the session metadata
  p_email      text
)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare
  v_ref_no  integer;
  v_member  uuid;
  v_year    integer;
  v_left    integer := p_amount_p;
  v_take    integer;
  v_years   integer[];
  v_done    integer[] := array[]::integer[];
  v_current integer;
  v_rec     record;
begin
  --  MF-26-0042 -> 42. The year in the reference says which year's reference
  --  it is, not which years are being paid; the metadata says that.
  v_ref_no := nullif(regexp_replace(coalesce(p_reference, ''), '^MF-\d{2}-0*', ''), '')::integer;

  if v_ref_no is null then
    return jsonb_build_object('ok', false, 'reason', 'unreadable_reference');
  end if;

  select m.id into v_member
  from public.masjid_members m
  where m.masjid_id = p_masjid and m.ref_no = v_ref_no;

  if v_member is null then
    --  The caller audits this. Returning rather than raising, because a
    --  raise makes Stripe retry and a retry will not conjure the member.
    return jsonb_build_object('ok', false, 'reason', 'no_such_member',
                              'ref_no', v_ref_no);
  end if;

  --  Already recorded? Stripe retries anything it did not hear back from,
  --  and the retry must not take the money twice on paper.
  if exists (select 1 from public.membership_payments
              where stripe_session_id = p_session_id) then
    return jsonb_build_object('ok', true, 'already', true,
                              'reference', p_reference);
  end if;

  v_current := public.membership_current_year(p_masjid);

  select coalesce(array_agg(y order by y), array[]::integer[]) into v_years
  from (
    select nullif(btrim(t), '')::integer as y
    from unnest(string_to_array(coalesce(p_years, ''), ',')) t
    where nullif(btrim(t), '') is not null
  ) s;

  --  No metadata at all — fall back to the year in the reference. Should not
  --  happen; a payment with nowhere to go is worse than a guess that is
  --  recorded as one.
  if array_length(v_years, 1) is null then
    v_years := array[v_current];
  end if;

  foreach v_year in array v_years loop
    exit when v_left <= 0;

    select my.net_p
         - coalesce((select sum(mp.amount_p) from public.membership_payments mp
                      where mp.member_id = v_member and mp.year = my.year), 0)
      into v_take
    from public.membership_years my
    where my.member_id = v_member and my.year = v_year;

    --  A year nobody raised a charge for, or one already settled at the
    --  counter a moment ago. Skip it; the remainder lands below.
    if v_take is null or v_take <= 0 then
      continue;
    end if;

    v_take := least(v_take, v_left);

    insert into public.membership_payments
      (masjid_id, member_id, year, amount_p, method, stripe_session_id)
    values (p_masjid, v_member, v_year, v_take, 'card', p_session_id)
    on conflict do nothing;

    v_left := v_left - v_take;
    v_done := v_done || v_year;
  end loop;

  --  Anything left goes on the current year, named as what it is. The
  --  office can move it; what it must not do is vanish.
  if v_left > 0 then
    insert into public.membership_payments
      (masjid_id, member_id, year, amount_p, method, stripe_session_id, note)
    values (p_masjid, v_member, v_current, v_left, 'card', p_session_id,
            'Paid more than the years quoted came to — the office should check this')
    on conflict do nothing;

    insert into public.admin_audit (masjid_id, action, detail)
    values (p_masjid, 'membership_overpayment', jsonb_build_object(
              'reference', p_reference, 'session', p_session_id,
              'amount_pence', p_amount_p, 'unallocated_pence', v_left));
  end if;

  --  Fill a blank, never overwrite a considered answer.
  if nullif(btrim(coalesce(p_email, '')), '') is not null then
    update public.masjid_members
       set email = btrim(p_email), updated_at = now()
     where id = v_member and email is null;
  end if;

  insert into public.admin_audit (masjid_id, action, detail)
  values (p_masjid, 'membership_fee_paid', jsonb_build_object(
            'reference',    p_reference,
            'session',      p_session_id,
            'amount_pence', p_amount_p,
            'years',        to_jsonb(v_done),
            --  Whether an address was captured, not the address itself.
            'email_given',  nullif(btrim(coalesce(p_email, '')), '') is not null));

  select m.full_name into v_rec from public.masjid_members m where m.id = v_member;

  return jsonb_build_object('ok', true, 'reference', p_reference,
                            'years', to_jsonb(v_done))
      || public.membership_state(v_member);
end;
$$;

revoke all on function public.mark_membership_fee_paid(uuid, text, text, integer, text, text)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
--  2. The four figures at the top of the office's screen
-- ---------------------------------------------------------------------------
create or replace function public.membership_overview()
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_year integer; v_out jsonb;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  v_masjid := public.current_masjid();
  v_year   := public.membership_current_year(v_masjid);

  --  THE BUCKETS ADD UP TO THE REGISTER, and that is a requirement rather
  --  than a nicety. The first version of this function counted `paid` as
  --  "settled AND the fee was more than nothing", which quietly dropped a
  --  member whose year had been WAIVED into neither bucket: paid + owing came
  --  to one less than the register and nothing said which row was missing.
  --  Caught by membership_owing_count() disagreeing with it.
  --
  --    paid      the year is settled — by payment, or by being set aside
  --    owing     a charge exists and is not settled
  --    unraised  no charge for this year yet, i.e. nobody has pressed Raise
  --              this year's charges. Worth its own figure in Ramadan, when
  --              "nobody owes anything" and "nobody has been charged" look
  --              identical on a screen that only has two buckets.
  with m as (
    select mm.id,
           my.id is not null     as charged,
           coalesce(my.net_p, 0) as net_p,
           coalesce(my.waived_p, 0) as waived_p,
           coalesce((select sum(mp.amount_p) from public.membership_payments mp
                      where mp.member_id = mm.id and mp.year = v_year), 0) as paid_p
    from public.masjid_members mm
    left join public.membership_years my
           on my.member_id = mm.id and my.year = v_year
    where mm.masjid_id = v_masjid and mm.left_on is null
  )
  select jsonb_build_object(
    'year',          v_year,
    'register',      count(*),
    'paid',          count(*) filter (where charged and paid_p >= net_p),
    'owing',         count(*) filter (where charged and paid_p <  net_p),
    'unraised',      count(*) filter (where not charged),
    --  A subset of `paid`, not a fourth bucket. The office wants to know how
    --  many years it has set aside without that reading as income.
    'waived',        count(*) filter (where charged and waived_p > 0),
    'owing_p',       coalesce(sum(greatest(net_p - paid_p, 0)), 0),
    --  Everything still owing across every year, not only this one. The
    --  arrears are the reason this system exists; a screen showing only the
    --  current year would hide them.
    'arrears_p',     coalesce((
                       select sum(greatest(y.net_p - coalesce((
                                select sum(mp.amount_p) from public.membership_payments mp
                                 where mp.member_id = y.member_id and mp.year = y.year), 0), 0))
                       from public.membership_years y
                       join public.masjid_members mm2 on mm2.id = y.member_id
                       where y.masjid_id = v_masjid and mm2.left_on is null), 0)
  ) into v_out from m;

  return v_out;
end;
$$;

revoke all on function public.membership_overview() from public, anon;
grant execute on function public.membership_overview() to authenticated;

-- ---------------------------------------------------------------------------
--  3. Who is behind — the count, with no names in the body
--
--  db/115's rule. When you want the figure, call this one.
-- ---------------------------------------------------------------------------
create or replace function public.membership_owing_count(p_filter text default 'owing')
returns integer language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_over jsonb;
begin
  --  READS membership_overview() RATHER THAN COUNTING AGAIN. The first
  --  version of this file had the two functions counting independently, with
  --  predicates that were meant to be the same and were not — a waived year
  --  was `paid` here and neither bucket there. One source, so they cannot
  --  disagree. There are still no names in this body.
  v_over := public.membership_overview();   --  carries the verified_admin() guard

  return case coalesce(p_filter, 'owing')
           when 'owing' then (v_over->>'owing')::integer
           when 'paid'  then (v_over->>'paid')::integer
           else              (v_over->>'register')::integer
         end;
end;
$$;

revoke all on function public.membership_owing_count(text) from public, anon;
grant execute on function public.membership_owing_count(text) to authenticated;

-- ---------------------------------------------------------------------------
--  4. The office's list — names, because that is its job
--
--  Addresses are NOT here. "The list says WHETHER, the record says WHAT": a
--  screen that sits open on a desk all evening should not carry five hundred
--  home addresses. The member's own record has them, one at a time, for
--  whoever opened it.
-- ---------------------------------------------------------------------------
create or replace function public.membership_owing_list(
  p_filter text    default 'owing',
  p_search text    default null,
  p_limit  integer default 100
)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_year integer; v_rows jsonb; v_q text;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  v_masjid := public.current_masjid();
  v_year   := public.membership_current_year(v_masjid);
  v_q      := lower(btrim(coalesce(p_search, '')));

  select coalesce(jsonb_agg(r order by r->>'name'), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
             'id',            mm.id,
             'name',          mm.full_name,
             'reference',     public.membership_reference(v_year, mm.ref_no),
             'fee_p',         coalesce(my.fee_p, 0),
             'waived_p',      coalesce(my.waived_p, 0),
             'net_p',         coalesce(my.net_p, 0),
             'paid_p',        paid.paid_p,
             'outstanding_p', greatest(coalesce(my.net_p, 0) - paid.paid_p, 0),
             'settled',       paid.paid_p >= coalesce(my.net_p, 0),
             'waived',        coalesce(my.waived_p, 0) > 0,
             'method',        paid.method,
             'last_paid_on',  last_any.last_paid_on,
             --  How far back this member goes, which is the figure the
             --  office actually wants when deciding who to go and see.
             'arrears_p',     (public.membership_state(mm.id)->>'outstanding_p')::integer,
             'years_owing',   (public.membership_state(mm.id)->>'years_owing')::integer
           ) as r
    from public.masjid_members mm
    left join public.membership_years my
           on my.member_id = mm.id and my.year = v_year
    cross join lateral (
      select coalesce(sum(mp.amount_p), 0) as paid_p,
             (array_agg(mp.method order by mp.received_on desc, mp.created_at desc))[1] as method
      from public.membership_payments mp
      where mp.member_id = mm.id and mp.year = v_year
    ) paid
    cross join lateral (
      select max(mp.received_on) as last_paid_on
      from public.membership_payments mp where mp.member_id = mm.id
    ) last_any
    where mm.masjid_id = v_masjid and mm.left_on is null
      and (v_q = '' or lower(mm.full_name) like '%' || v_q || '%')
      and case coalesce(p_filter, 'owing')
            when 'owing' then paid.paid_p <  coalesce(my.net_p, 0)
            when 'paid'  then paid.paid_p >= coalesce(my.net_p, 0)
            else true
          end
    limit greatest(least(coalesce(p_limit, 100), 500), 1)
  ) s;

  return jsonb_build_object('year', v_year, 'rows', v_rows,
                            'shown', jsonb_array_length(v_rows),
                            'total', public.membership_owing_count(p_filter));
end;
$$;

revoke all on function public.membership_owing_list(text, text, integer) from public, anon;
grant execute on function public.membership_owing_list(text, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
--  5. One member's record — the screen that may show an address
-- ---------------------------------------------------------------------------
create or replace function public.membership_one(p_member uuid)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_year integer; v_m record;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;

  v_masjid := public.current_masjid();
  v_year   := public.membership_current_year(v_masjid);

  select * into v_m from public.masjid_members
  where id = p_member and masjid_id = v_masjid;

  if v_m.id is null then
    raise exception 'No such member' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
      'id',           v_m.id,
      'name',         v_m.full_name,
      'reference',    public.membership_reference(v_year, v_m.ref_no),
      'ref_no',       v_m.ref_no,
      'house_no',     v_m.house_no,
      'address_line', v_m.address_line,
      'postcode',     v_m.postcode,
      'telephone',    v_m.telephone,
      'email',        v_m.email,
      'member_since', v_m.member_since,
      'left_on',      v_m.left_on,
      'note',         v_m.note,
      'current_year', v_year)
    || public.membership_state(p_member)
    || jsonb_build_object('payments', coalesce((
         select jsonb_agg(jsonb_build_object(
                  'year',        mp.year,
                  'amount_p',    mp.amount_p,
                  'method',      mp.method,
                  'received_on', mp.received_on,
                  'reference',   mp.bank_reference,
                  'note',        mp.note,
                  'by_a_person', mp.recorded_by is not null
                ) order by mp.received_on desc, mp.year desc)
         from public.membership_payments mp where mp.member_id = p_member), '[]'::jsonb));
end;
$$;

revoke all on function public.membership_one(uuid) from public, anon;
grant execute on function public.membership_one(uuid) to authenticated;

commit;
