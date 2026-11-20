-- 169 — in-app card payment for membership: the amount is priced server-side.
--
-- The app has no way to name a safe amount: a client that could send its own
-- figure would settle a £100 membership for a penny, and no amount of checking
-- in the app would stop it. So the Worker (which holds the Stripe key) asks this
-- function what the member owes, from the member's own session token. The app
-- sends only the token and which member; it never sees or sets a number.
--
-- The payment is RECORDED by the existing stripe-webhook path: this returns an
-- MF-YY-NNNN reference (which the webhook parses back to the member's ref_no via
-- mark_membership_fee_paid) and the years the amount is allocated across. Nothing
-- new is needed on the webhook. The Worker computes sha256(session token) and
-- passes the HASH, so the raw token never travels in a database call.
create or replace function public.membership_quote(p_token_hash text, p_member uuid, p_scope text default 'current')
returns jsonb language plpgsql security definer set search_path to 'public','pg_temp' as $$
declare v_email text; v_masjid uuid; v_name text; v_ref int; v_year int; v_fee int;
        v_state jsonb; v_cur_out int; v_charged boolean; v_amount int; v_years int[]; v_ref_str text;
begin
  select email_norm into v_email from public.member_session
   where token_hash = p_token_hash and expires_at > now() limit 1;
  if v_email is null then return jsonb_build_object('ok', false, 'reason', 'session'); end if;

  select masjid_id, full_name, ref_no into v_masjid, v_name, v_ref from public.masjid_members
   where id = p_member and email_norm = v_email and left_on is null;
  if v_masjid is null then return jsonb_build_object('ok', false, 'reason', 'member'); end if;

  v_year := public.membership_current_year(v_masjid);
  select fee_p into v_fee from public.membership_rates where masjid_id = v_masjid and year = v_year;
  v_state := public.membership_state(p_member);

  select (y->>'outstanding_p')::int into v_cur_out
    from jsonb_array_elements(coalesce(v_state->'years','[]'::jsonb)) y
   where (y->>'year')::int = v_year;
  v_charged := v_cur_out is not null;

  if lower(coalesce(p_scope,'current')) = 'all' then
    select coalesce(array_agg(yr order by yr), array[]::int[]) into v_years from (
      select (y->>'year')::int as yr
      from jsonb_array_elements(coalesce(v_state->'years','[]'::jsonb)) y
      where coalesce((y->>'outstanding_p')::int,0) > 0
      union
      select v_year where not v_charged
    ) s;
    v_amount := coalesce((v_state->>'outstanding_p')::int, 0)
              + case when v_charged then 0 else coalesce(v_fee, 0) end;
  else
    v_years := array[v_year];
    v_amount := coalesce(v_cur_out, v_fee, 0);
  end if;

  if coalesce(v_amount,0) <= 0 then
    return jsonb_build_object('ok', true, 'amount_p', 0, 'year', v_year, 'name', v_name, 'nothing_due', true);
  end if;

  v_ref_str := 'MF-' || lpad((v_year % 100)::text, 2, '0') || '-' || lpad(v_ref::text, 4, '0');
  return jsonb_build_object('ok', true, 'amount_p', v_amount, 'year', v_year, 'name', v_name,
                            'reference', v_ref_str,
                            'years', array_to_string(coalesce(v_years, array[v_year]), ','));
end $$;
revoke all on function public.membership_quote(text, uuid, text) from public, anon, authenticated;
grant execute on function public.membership_quote(text, uuid, text) to service_role;
