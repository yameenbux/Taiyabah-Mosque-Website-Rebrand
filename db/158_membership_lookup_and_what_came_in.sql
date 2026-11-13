-- ===========================================================================
--  158 — membership: the lookup, the checkout quote, and the office's screens
--
--  Taiyabah Masjid · 12 November 2026
--
--  157 made the tables. This is everything that reads and writes them.
--
--  THREE AUDIENCES, THREE GUARDS, and they are not the same guard:
--
--    anon           membership_name_matches(), membership_claim(),
--                   membership_state_for_claim(), membership_quote()
--                   — a member paying is not logged in and never will be.
--                     Asking five hundred men to hold an account to pay £100
--                     once a year is how the Excel sheet wins.
--    service_role   mark_membership_fee_paid() — the webhook only.
--    verified_admin everything whose name begins membership_owing_,
--                   membership_one(), and every function that writes.
--
--  THE AMOUNT IS NEVER SENT BY THE CLIENT. membership_quote() takes a claim
--  token and a scope ('all' or 'current') and computes the figure here. The
--  Worker passes that figure to Stripe. A client that could name its own
--  amount could settle £460 of arrears for a penny, and no amount of
--  checking in the app would stop it, because the app is not where the
--  request comes from.
--
--  THE REFUSAL IS THE SAME SHAPE WHATEVER WAS WRONG. membership_claim()
--  returns {"matched": false} for a name that is not on the register, a
--  postcode that does not go with the name, a member who has left, and two
--  members who cannot be told apart. If it distinguished them it would be an
--  oracle: type a name, watch which refusal comes back, and learn whether
--  that person is a member of this masjid. Religious affiliation is special
--  category data and the nikāḥ form already refuses to ask about it (see the
--  comment above NIKAH_LINKS in index_template.html).
--
--  TWO MEMBERS WITH THE SAME NAME AT THE SAME ADDRESS cannot pay online. A
--  father and son of the same name is a real case in this community. The
--  function will not guess which one is paying, because guessing wrong puts
--  the money on the wrong record and the wrong man stays in arrears. They
--  ring the office, which is what they do now.
--
--  THE CURRENT YEAR IS NOT DERIVED FROM TODAY'S DATE. It is the latest year
--  an administrator has set a rate for. Ramadan 1452 begins in late December
--  2030 and Ramadan 1451 began that January — two Ramadans inside one
--  Gregorian year — so a system that reads the clock to decide which year is
--  being collected gets 2030 wrong and nobody notices until the following
--  Ramadan.
--
--  WHY membership_owing_count() EXISTS. The repository rule: a function whose
--  job is to return people must have a count-only sibling, so that verifying
--  a figure never puts names in a transcript. db/115 did this for the four
--  madrasah screen functions after it happened twice. membership_owing_list()
--  returns names because that is the office's screen; the count is a separate
--  function with no names in its body at all.
--
--  Prerequisites: 157. Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. Normalising, and the reference
--
--  The expressions here must stay identical to the ones in 157's indexes or
--  the lookup stops using them. They are plain inline SQL in the queries for
--  that reason, and these helpers exist for the reference only.
-- ---------------------------------------------------------------------------

--  MF-26-0042 — the prefix the stripe-webhook routes on, the year being paid,
--  and the member's permanent number.
create or replace function public.membership_reference(p_year integer, p_ref_no integer)
returns text language sql immutable as $$
  select 'MF-' || to_char(p_year % 100, 'FM00') || '-' || to_char(p_ref_no, 'FM0000')
$$;

--  The latest year somebody has set a fee for. See the header.
create or replace function public.membership_current_year(p_masjid uuid)
returns integer language sql stable security definer
set search_path to 'public', 'pg_temp' as $$
  select max(year) from public.membership_rates where masjid_id = p_masjid
$$;

-- ---------------------------------------------------------------------------
--  2. What one member's years look like
--
--  The one place a balance is worked out. Every screen, the quote, the
--  receipt and the office's list all come through here, so there is one
--  answer rather than four that agree until one of them is edited.
-- ---------------------------------------------------------------------------
create or replace function public.membership_state(p_member uuid)
returns jsonb language sql stable security definer
set search_path to 'public', 'pg_temp' as $$
  with y as (
    select
      my.year, my.fee_p, my.waived_p, my.net_p,
      coalesce(p.paid_p, 0)  as paid_p,
      p.last_paid_on,
      p.method
    from public.membership_years my
    left join lateral (
      select sum(mp.amount_p)                      as paid_p,
             max(mp.received_on)                   as last_paid_on,
             (array_agg(mp.method order by mp.received_on desc, mp.created_at desc))[1] as method
      from public.membership_payments mp
      where mp.member_id = my.member_id and mp.year = my.year
    ) p on true
    where my.member_id = p_member
  )
  select jsonb_build_object(
    'years', coalesce((
      select jsonb_agg(jsonb_build_object(
          'year',          year,
          'fee_p',         fee_p,
          'waived_p',      waived_p,
          'net_p',         net_p,
          'paid_p',        paid_p,
          'outstanding_p', greatest(net_p - paid_p, 0),
          --  settled covers both ways a year can be done with: paid, or set
          --  aside. A screen that only knew about payment would show a
          --  waived year as still owing.
          'settled',       (paid_p >= net_p),
          'waived',        (waived_p > 0),
          'last_paid_on',  last_paid_on,
          'method',        method
        ) order by year desc) from y), '[]'::jsonb),
    'outstanding_p', coalesce((select sum(greatest(net_p - paid_p, 0)) from y), 0),
    'years_owing',   coalesce((select count(*) from y where paid_p < net_p), 0),
    'last_paid_on',  (select max(last_paid_on) from y)
  )
$$;

revoke all on function public.membership_state(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
--  3. Step one: how many, never who
-- ---------------------------------------------------------------------------
create or replace function public.membership_name_matches(p_masjid text, p_name text)
returns integer language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare
  --  THE SLUG, not a uuid. Every other function the app and the website call
  --  takes 'taiyabah' and resolves it the same way; a pair that took a uuid
  --  would be the only two the app could not call, because the app has never
  --  been told the uuid and should not be.
  v_masjid uuid := public.masjid_or_sole(p_masjid);
  v_name text := lower(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')));
  v_n    integer;
begin
  --  Two letters is not a search, it is a sweep of the register.
  if length(v_name) < 3 then
    return 0;
  end if;

  select count(*) into v_n
  from public.masjid_members m
  where m.masjid_id = v_masjid
    and m.left_on is null
    and lower(btrim(m.full_name)) = v_name;

  insert into public.membership_lookup_log (masjid_id, step, matched)
  values (v_masjid, 'name', v_n > 0);

  return v_n;
end;
$$;

revoke all on function public.membership_name_matches(text, text) from public;
grant execute on function public.membership_name_matches(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  4. Step two: match exactly, or do not
-- ---------------------------------------------------------------------------
create or replace function public.membership_claim(
  p_masjid   text,
  p_name     text,
  p_house    text,
  p_postcode text
)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare
  --  Well above ordinary use: the register is about 400 people and a real
  --  member gets it right first or second go. Sixty FAILURES in ten
  --  minutes, across the whole masjid, is somebody working through a list.
  c_fail_ceiling constant integer := 60;
  v_masjid uuid := public.masjid_or_sole(p_masjid);
  v_recent integer;
  v_name   text := lower(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')));
  v_house  text := lower(replace(coalesce(p_house, ''), ' ', ''));
  v_post   text := upper(replace(coalesce(p_postcode, ''), ' ', ''));
  v_id     uuid;
  v_n      integer;
  v_token  uuid;
  v_member record;
begin
  --  array_agg()[1] rather than min(): there is no min(uuid) in Postgres, and
  --  the only id wanted is the one from the single-row case anyway.
  select count(*) into v_recent
  from public.membership_lookup_log
  where masjid_id = v_masjid and step = 'address' and not matched
    and at > now() - interval '10 minutes';

  if v_recent >= c_fail_ceiling then
    --  Logged too, so the office sees the brake engage rather than first
    --  hearing about it from a member who could not get in.
    insert into public.membership_lookup_log (masjid_id, step, matched)
    values (v_masjid, 'address', false);
    --  A DIFFERENT SHAPE from a mismatch. See 157's header: a member meeting
    --  the brake must be told to come back shortly, not told their details
    --  are wrong, and the brake must say nothing about any person.
    return jsonb_build_object('matched', false, 'busy', true);
  end if;

  select count(*), (array_agg(m.id))[1] into v_n, v_id
  from public.masjid_members m
  where m.masjid_id = v_masjid
    and m.left_on is null
    and lower(btrim(m.full_name)) = v_name
    and lower(replace(coalesce(m.house_no, ''), ' ', '')) = v_house
    and upper(replace(coalesce(m.postcode, ''), ' ', '')) = v_post
    and v_name <> '' and v_house <> '' and v_post <> '';

  insert into public.membership_lookup_log (masjid_id, step, matched)
  values (v_masjid, 'address', v_n = 1);

  --  Not one, not many — see the header on why these are the same answer.
  if v_n <> 1 then
    return jsonb_build_object('matched', false);
  end if;

  --  Old claims for this member are spent the moment a new one is made, so a
  --  token read off somebody's screen an hour ago is not still live.
  delete from public.membership_claims where member_id = v_id;
  insert into public.membership_claims (masjid_id, member_id)
  values (v_masjid, v_id)
  returning token into v_token;

  --  Housekeeping, here rather than in a cron: expired tokens are useless and
  --  this is the only place that makes new ones.
  delete from public.membership_claims where expires_at < now();

  select m.ref_no, m.full_name, m.email into v_member
  from public.masjid_members m where m.id = v_id;

  return jsonb_build_object('matched', true, 'token', v_token)
      || public.membership_state(v_id)
      || jsonb_build_object(
           'reference',    public.membership_reference(
                             public.membership_current_year(v_masjid), v_member.ref_no),
           'current_year', public.membership_current_year(v_masjid),
           --  Shown back so the member can see the masjid has the right
           --  person. They typed the name themselves, so this reveals
           --  nothing they did not already supply.
           'name',         v_member.full_name,
           'has_email',    v_member.email is not null);
end;
$$;

revoke all on function public.membership_claim(text, text, text, text) from public;
grant execute on function public.membership_claim(text, text, text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  5. Reading the same state back from a token
--
--  So the screens after the match do not have to hold the name and address.
-- ---------------------------------------------------------------------------
create or replace function public.membership_state_for_claim(p_token uuid)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare v_member uuid; v_masjid uuid; v_ref integer; v_name text;
begin
  select c.member_id, c.masjid_id into v_member, v_masjid
  from public.membership_claims c
  where c.token = p_token and c.expires_at > now();

  if v_member is null then
    return jsonb_build_object('matched', false);
  end if;

  select m.ref_no, m.full_name into v_ref, v_name
  from public.masjid_members m where m.id = v_member;

  return jsonb_build_object('matched', true)
      || public.membership_state(v_member)
      || jsonb_build_object(
           'reference',    public.membership_reference(
                             public.membership_current_year(v_masjid), v_ref),
           'current_year', public.membership_current_year(v_masjid),
           'name',         v_name);
end;
$$;

revoke all on function public.membership_state_for_claim(uuid) from public;
grant execute on function public.membership_state_for_claim(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  6. The quote the Worker hands to Stripe
--
--  'all'     every year still owing
--  'current' this year alone — NOT the oldest. The member came to be a
--            member now; paying the oldest year instead would take the money
--            and leave them still not a member.
-- ---------------------------------------------------------------------------
create or replace function public.membership_quote(p_token uuid, p_scope text)
returns jsonb language plpgsql security definer
set search_path to 'public', 'pg_temp' as $$
declare
  v_member uuid; v_masjid uuid; v_ref integer;
  v_year integer; v_amount integer; v_years integer[]; v_label text;
begin
  if coalesce(p_scope, '') not in ('all', 'current') then
    raise exception 'membership_quote: scope must be all or current'
      using errcode = '22023';
  end if;

  select c.member_id, c.masjid_id into v_member, v_masjid
  from public.membership_claims c
  where c.token = p_token and c.expires_at > now();

  if v_member is null then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  select m.ref_no into v_ref from public.masjid_members m where m.id = v_member;
  v_year := public.membership_current_year(v_masjid);

  select coalesce(sum(y.amount), 0),
         coalesce(array_agg(y.year order by y.year), array[]::integer[])
    into v_amount, v_years
  from (
    select (e->>'year')::integer as year, (e->>'outstanding_p')::integer as amount
    from jsonb_array_elements(public.membership_state(v_member)->'years') e
    where (e->>'outstanding_p')::integer > 0
      and (p_scope = 'all' or (e->>'year')::integer = v_year)
  ) y;

  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_due');
  end if;

  v_label := case
    when array_length(v_years, 1) = 1
      then 'Masjid membership ' || v_years[1]
    else 'Masjid membership ' || v_years[1] || '–' || v_years[array_length(v_years, 1)]
  end;

  return jsonb_build_object(
    'ok',        true,
    'amount_p',  v_amount,
    'years',     v_years,
    'reference', public.membership_reference(v_year, v_ref),
    'label',     v_label);
end;
$$;

revoke all on function public.membership_quote(uuid, text) from public;
grant execute on function public.membership_quote(uuid, text) to anon, authenticated;

commit;
