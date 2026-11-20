-- 164 — two office actions the register needs: a full export for backup, and a
-- true delete for a mistaken entry (distinct from "mark as left", which keeps
-- a real member's payment history). Both verified_admin-gated, both audited.

-- A backup of the whole register. Office-only; returns names and addresses
-- because that is what a backup is, and only a signed-in admin can call it.
create or replace function public.membership_export()
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_year integer; v_rows jsonb;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();
  v_year   := public.membership_current_year(v_masjid);

  select coalesce(jsonb_agg(r order by (r->>'ref_no')::integer), '[]'::jsonb) into v_rows
  from (
    select jsonb_build_object(
      'ref_no',          mm.ref_no,
      'reference',       public.membership_reference(v_year, mm.ref_no),
      'name',            mm.full_name,
      'house_no',        mm.house_no,
      'address_line',    mm.address_line,
      'postcode',        mm.postcode,
      'telephone',       mm.telephone,
      'email',           mm.email,
      'member_since',    mm.member_since,
      'left_on',         mm.left_on,
      'status',          case when mm.left_on is not null then 'left' else 'active' end,
      'this_year_fee_p', coalesce(my.net_p, 0),
      'this_year_paid_p', coalesce((select sum(mp.amount_p) from public.membership_payments mp
                                     where mp.member_id = mm.id and mp.year = v_year), 0),
      'arrears_p',       (public.membership_state(mm.id)->>'outstanding_p')::integer,
      'years_owing',     (public.membership_state(mm.id)->>'years_owing')::integer,
      'note',            mm.note
    ) as r
    from public.masjid_members mm
    left join public.membership_years my on my.member_id = mm.id and my.year = v_year
    where mm.masjid_id = v_masjid
  ) s;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'membership_exported',
          jsonb_build_object('rows', jsonb_array_length(v_rows)));

  return jsonb_build_object('year', v_year,
                            'count', jsonb_array_length(v_rows),
                            'rows', v_rows);
end;
$$;
revoke all on function public.membership_export() from public, anon;
grant execute on function public.membership_export() to authenticated;

-- A true delete, for a member added by mistake. REFUSES the moment any payment
-- exists against them — those are the charity's accounting records and a real
-- member is removed with membership_mark_left, which keeps them. So this only
-- ever removes an entry that never had a life: no payments. Its membership_years
-- (unpaid charges) and claims cascade away with it.
create or replace function public.membership_delete_member(p_member uuid)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_masjid uuid; v_ref integer; v_pays integer;
begin
  if not public.verified_admin() then
    raise exception 'Not allowed' using errcode = '42501';
  end if;
  v_masjid := public.current_masjid();

  select ref_no into v_ref from public.masjid_members
  where id = p_member and masjid_id = v_masjid;
  if v_ref is null then
    raise exception 'No such member' using errcode = 'P0002';
  end if;

  select count(*) into v_pays from public.membership_payments where member_id = p_member;
  if v_pays > 0 then
    raise exception 'This member has % payment(s) on record — those are the charity''s accounts. Use "mark as left" to remove them from the register while keeping the history.', v_pays
      using errcode = '2BP01';
  end if;

  delete from public.masjid_members where id = p_member and masjid_id = v_masjid;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'membership_member_deleted',
          jsonb_build_object('ref_no', v_ref));

  return jsonb_build_object('ok', true, 'ref_no', v_ref);
end;
$$;
revoke all on function public.membership_delete_member(uuid) from public, anon;
grant execute on function public.membership_delete_member(uuid) to authenticated;
