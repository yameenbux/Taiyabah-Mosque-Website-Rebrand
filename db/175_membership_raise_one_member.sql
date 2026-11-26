-- ===========================================================================
--  175 — raise a single member's charge, not the whole register
--
--  Taiyabah Masjid · 26 November 2026
--
--  WHY. "Raise the year's charge" is the Ramadan ritual: one press charges
--  every member who is not already charged for the year. Somebody who walks
--  into the office in July wanting to pay this year's fee needed exactly
--  that whole-register press run just for them — membership_record_payment()
--  refuses a payment against a year nobody has charged, and raising one
--  member's charge had no door of its own. That is a lot of blast radius for
--  one member, and an admin reading "every member not yet charged" has to
--  trust nothing else on the register is caught by it by accident.
--
--  membership_raise_year() now takes an optional p_member. Left null, it is
--  exactly what it always was. Given a member, it inserts a charge for that
--  one person alone, at the same rate membership_set_rate() already holds
--  for the year — or refuses, the same way, if nobody has set one yet. One
--  function, one rule, two doors into it: the office's own flow for a
--  backdated or late-joining member stays the same function too.
--
--  THE POSTGREST OVERLOAD TRAP. 167 already paid for this lesson on
--  record_public_donation(): adding a parameter to an existing function does
--  not replace it, it creates a SECOND function alongside the first, and
--  PostgREST then refuses a call that matches both ("Could not choose the
--  best candidate function"). The one-argument version is dropped here, not
--  left beside the new one.
--
--  Prerequisites: 157, 160. Idempotent.
-- ===========================================================================

begin;

drop function if exists public.membership_raise_year(integer);

create or replace function public.membership_raise_year(
  p_year integer, p_member uuid default null)
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

  --  Given a member, it must be one of ours, and not somebody who has left —
  --  the same two things every other per-member write here checks before
  --  touching a row.
  if p_member is not null then
    if not exists (select 1 from public.masjid_members
                    where id = p_member and masjid_id = v_masjid) then
      raise exception 'No such member' using errcode = 'P0002';
    end if;
    if exists (select 1 from public.masjid_members
                where id = p_member and left_on is not null) then
      raise exception 'This member has left and cannot be charged'
        using errcode = '22023';
    end if;
  end if;

  with made as (
    insert into public.membership_years
      (masjid_id, member_id, year, fee_p, created_by)
    select v_masjid, mm.id, p_year, v_fee, auth.uid()
    from public.masjid_members mm
    where mm.masjid_id = v_masjid and mm.left_on is null
      and (p_member is null or mm.id = p_member)
    on conflict (member_id, year) do nothing
    returning 1
  )
  select count(*) into v_made from made;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(),
          case when p_member is null then 'membership_year_raised'
               else 'membership_year_raised_for_member' end,
          jsonb_build_object('year', p_year, 'fee_pence', v_fee, 'charges_made', v_made)
            || case when p_member is null then '{}'::jsonb
                     else jsonb_build_object('member', p_member) end);

  return jsonb_build_object('ok', true, 'year', p_year, 'made', v_made);
end;
$$;

revoke all on function public.membership_raise_year(integer, uuid) from public, anon;
grant execute on function public.membership_raise_year(integer, uuid) to authenticated;

commit;
