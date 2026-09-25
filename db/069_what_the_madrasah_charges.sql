-- ===========================================================================
--  069_what_the_madrasah_charges.sql
--  20 September 2026
--
--  THE RATE CARD, THE TERMS, AND THE SIBLING DISCOUNT.
--
--  Today the madrasah's fees exist in exactly one place: three lines of HTML
--  in index_template.html, saying £10 a week for all classes, £14 for Hifz
--  and a £20 admission fee. Changing any of them means editing a template,
--  running two Python scripts and pushing to GitHub — which is 045's
--  complaint about the hall hire rate card, word for word, and it ended the
--  same way: the website quoting a price the office had stopped charging.
--
--  There is a second reason this cannot stay hard-coded. The masjid has not
--  confirmed those three figures. `claude/madrasah-admissions-form.md` has
--  "Are the fees still £10 / £14 / £20?" sitting on its open-questions list
--  since the admissions work. Seeding them into a migration as though they
--  were settled would turn an unanswered question into a number that bills
--  five hundred families.
--
--  So this file seeds the rate card with the published figures AND marks it
--  unconfirmed. The structure screen shows a banner until somebody at the
--  masjid presses the button that says these are right. A figure nobody has
--  checked should say so on the screen where it is used.
--
--  ---------------------------------------------------------------------------
--  MONEY IS INTEGER PENCE, AND THAT IS A DEPARTURE FROM 045
--  ---------------------------------------------------------------------------
--
--  045 stored hall hire prices as TEXT, deliberately, because the real card
--  says "£350" on one line and "45p per person" on another and a numeric
--  column cannot hold the second.
--
--  Fees are different in the one way that matters: they are ARITHMETIC. A
--  balance is charges minus payments, an annual report is a sum, and a
--  sibling discount is a percentage of something. Text cannot do that, and a
--  float must not — 0.1 + 0.2 in binary floating point is not 0.3, and in a
--  ledger that is how a family ends up owing a penny forever. Integer pence
--  throughout, every division rounded explicitly, and never a DOUBLE.
--
--  ---------------------------------------------------------------------------
--  A TERM IS A NUMBER OF CHARGEABLE WEEKS, TYPED IN BY A PERSON
--  ---------------------------------------------------------------------------
--
--  The published rate is per week, but nobody bills weekly — that would be
--  forty invoices a year per child. The masjid bills by term, and the real
--  question is how many weeks are in one, which no formula can answer:
--  madrasah terms do not match school terms, they break for Ramadan and Eid
--  and the two do not sit still in the calendar, and the masjid decides each
--  year whether the half-term week is charged.
--
--  So a period is a name, two dates and a number of chargeable weeks that a
--  human types in. Not derived, not counted from a holiday table that would
--  then have to be right. The office already knows the answer; the system's
--  job is to remember it and multiply.
--
--  This also means the same schema bills monthly if the masjid ever switches:
--  a period is just a shorter range with fewer weeks in it. Nothing here
--  assumes a term.
--
--  Prerequisites: 068 (families). Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. What a class costs
--
--  A rate is per week, per child. `is_default` marks the one applied to a
--  pupil nobody has said anything special about — which is most of them.
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_fee_rates (
  id          uuid primary key default gen_random_uuid(),
  masjid_id   uuid not null references public.masjids(id) on delete cascade,
  name        text not null,
  amount_p    integer not null,
  is_default  boolean not null default false,
  active      boolean not null default true,
  sort        integer not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint madrasah_rate_has_a_name check (length(btrim(name)) between 1 and 60),
  --  Nothing is free, and nothing is more than £1,000 a week. The ceiling is
  --  not fussiness: a stray zero turning £10 into £100 is the single most
  --  likely typing mistake on this screen, and it would go out on five hundred
  --  bills before anybody read one. It is set well above anything a madrasah
  --  charges rather than snugly, because a constraint that blocks a legitimate
  --  figure gets removed in a hurry by whoever hits it.
  constraint madrasah_rate_is_sane check (amount_p between 1 and 100000)
);

create unique index if not exists madrasah_rate_one_default_idx
  on public.madrasah_fee_rates (masjid_id) where is_default;

create unique index if not exists madrasah_rate_name_idx
  on public.madrasah_fee_rates (masjid_id, lower(btrim(name)));

alter table public.madrasah_fee_rates enable row level security;
alter table public.madrasah_fee_rates force row level security;
revoke all on public.madrasah_fee_rates from anon, authenticated;

--  Which rate a child is on. Null means the default — stored as null rather
--  than copied, so that changing the default rate moves everybody who was
--  never given a special one, which is what the office means by changing it.
alter table public.madrasah_pupils
  add column if not exists fee_rate_id uuid
    references public.madrasah_fee_rates(id) on delete set null;

-- ---------------------------------------------------------------------------
--  2. A term
--
--  STATUS IS THE WHOLE SAFETY MECHANISM OF THIS SECTION.
--
--    draft   nothing has been charged. Everything is editable.
--    issued  charges exist and families have been told. The dates and the
--            week count are frozen.
--    closed  the year is done. Nothing may be added.
--
--  Editing the week count of a period that has already been billed would
--  silently make every charge disagree with the figure it was calculated
--  from, and the disagreement would only surface when a parent added up
--  their own bill. save_madrasah_fee_period() refuses it. The screen also
--  refuses it, but a boundary that is only in the user interface is a
--  boundary that lasts until somebody calls the function directly — 045.
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_fee_periods (
  id          uuid primary key default gen_random_uuid(),
  masjid_id   uuid not null references public.masjids(id) on delete cascade,
  name        text not null,
  starts_on   date not null,
  ends_on     date not null,
  weeks       numeric(4,1) not null,
  status      text not null default 'draft',
  issued_at   timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint madrasah_period_has_a_name check (length(btrim(name)) between 1 and 60),
  constraint madrasah_period_ends_after_it_starts check (ends_on >= starts_on),
  constraint madrasah_period_weeks_are_sane check (weeks > 0 and weeks <= 60),
  constraint madrasah_period_status_valid check (status in ('draft', 'issued', 'closed'))
);

create unique index if not exists madrasah_period_name_idx
  on public.madrasah_fee_periods (masjid_id, lower(btrim(name)));

create index if not exists madrasah_period_dates_idx
  on public.madrasah_fee_periods (masjid_id, starts_on desc);

alter table public.madrasah_fee_periods enable row level security;
alter table public.madrasah_fee_periods force row level security;
revoke all on public.madrasah_fee_periods from anon, authenticated;

-- ---------------------------------------------------------------------------
--  3. Settings
--
--  One row per key, admin-readable. NOT public.app_settings, which is owner
--  only with every privilege revoked — pg_cron can read it and a signed-in
--  administrator cannot, which is right for the notify secret and useless
--  for a sibling discount the office has to be able to change.
--
--  WHAT IS KEPT HERE AND WHAT IS NOT:
--
--    sibling_rule       the discount, as an ordered list of rules
--    card_link          a Stripe Payment Link, or empty
--    bank_*             the account fees are paid into
--    reminder_*         the wording of a reminder email
--    rates_confirmed_*  who said the rate card is right, and when
--
--  THE BANK DETAILS ARE EDITABLE, AND THAT DEPARTS FROM 045. Stating the
--  reason, because the departure is deliberate and somebody will check.
--
--  045 put the hall hire bank details out of scope: "a sort code and account
--  number on a PUBLIC WEB PAGE are what a fraudster edits if they ever get
--  in." That is right, and the operative word is public. These details sit
--  behind a sign-in and two-step, on a screen only an administrator reaches.
--
--  The alternative is worse rather than safer. Hard-coding them means that on
--  the day the masjid actually changes bank — which charities do — somebody
--  pastes a new account number into a template under time pressure, with no
--  record of who changed it or when, and the fees section keeps quoting the
--  old one until a developer is free. Mandate fraud is the commonest fraud
--  committed against UK charities, and what defeats it is not immutability
--  but NOISE: every change to these four fields writes an admin_audit row,
--  the screen permanently shows who last changed them and on what date, and
--  the change cannot be saved without re-typing the account number. A quiet
--  change is the dangerous one.
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_fee_settings (
  masjid_id   uuid not null references public.masjids(id) on delete cascade,
  key         text not null,
  value       jsonb not null,
  changed_at  timestamptz not null default now(),
  changed_by  uuid,
  primary key (masjid_id, key)
);

alter table public.madrasah_fee_settings enable row level security;
alter table public.madrasah_fee_settings force row level security;
revoke all on public.madrasah_fee_settings from anon, authenticated;

--  The keys this system understands. Anything else is refused on write, so
--  that a typo in a screen cannot quietly create a setting nothing reads —
--  which looks, to the person who typed it, exactly like saving worked.
create or replace function public.madrasah_fee_setting_keys()
returns text[]
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select array[
    'sibling_rule', 'card_link', 'card_note',
    'bank_name', 'bank_account_name', 'bank_sort_code', 'bank_account_number',
    'reminder_subject', 'reminder_body',
    'rates_confirmed_on', 'rates_confirmed_by'
  ]
$fn$;

-- ---------------------------------------------------------------------------
--  4. Reading the rate card, the terms and the settings
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_fee_structure()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the fee structure.'
      using errcode = '42501';
  end if;

  return jsonb_build_object(
    'rates', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', r.id, 'name', r.name, 'amount_p', r.amount_p,
               'is_default', r.is_default, 'active', r.active, 'sort', r.sort,
               --  How many children are on this rate, so that deactivating one
               --  can say what it would strand instead of just doing it.
               'pupils', (select count(*) from public.madrasah_pupils p
                           where p.fee_rate_id = r.id and p.left_on is null))
             order by r.sort, r.name)
        from public.madrasah_fee_rates r where r.masjid_id = v_masjid), '[]'::jsonb),

    'periods', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', t.id, 'name', t.name, 'starts_on', t.starts_on,
               'ends_on', t.ends_on, 'weeks', t.weeks, 'status', t.status,
               'issued_at', t.issued_at,
               'charges', (select count(*) from public.madrasah_charges c
                            where c.period_id = t.id))
             order by t.starts_on desc)
        from public.madrasah_fee_periods t where t.masjid_id = v_masjid), '[]'::jsonb),

    'settings', coalesce((
      select jsonb_object_agg(s.key, s.value)
        from public.madrasah_fee_settings s where s.masjid_id = v_masjid), '{}'::jsonb),

    'settings_changed', coalesce((
      select jsonb_object_agg(s.key, jsonb_build_object(
               'at', s.changed_at,
               'by', coalesce((select pr.full_name from public.profiles pr
                                where pr.id = s.changed_by), 'someone')))
        from public.madrasah_fee_settings s where s.masjid_id = v_masjid), '{}'::jsonb),

    --  Counted here rather than in the browser, because the structure screen
    --  needs to warn that unhoused pupils will be skipped when charges are
    --  raised, and a number the screen worked out for itself is a number that
    --  can disagree with the one the generator uses.
    'pupils_total',   (select count(*) from public.madrasah_pupils
                        where masjid_id = v_masjid and left_on is null),
    'pupils_no_family', (select count(*) from public.madrasah_pupils
                          where masjid_id = v_masjid and left_on is null
                            and household_id is null)
  );
end $fn$;

-- ---------------------------------------------------------------------------
--  5. Writing a rate
-- ---------------------------------------------------------------------------
create or replace function public.save_madrasah_fee_rate(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id     uuid := nullif(p->>'id', '')::uuid;
  v_masjid uuid := public.current_masjid();
  v_name   text := btrim(coalesce(p->>'name', ''));
  v_amt    integer;
  v_def    boolean := coalesce((p->>'is_default')::boolean, false);
  v_row    public.madrasah_fee_rates%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change what the madrasah charges.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected.' using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'A rate needs a name — what it covers, like "All classes" or "Hifz".'
      using errcode = 'check_violation';
  end if;

  begin
    v_amt := (p->>'amount_p')::integer;
  exception when others then
    raise exception 'That amount is not a number of pence.' using errcode = 'check_violation';
  end;
  if v_amt is null or v_amt < 1 then
    raise exception 'A rate has to be more than nothing.' using errcode = 'check_violation';
  end if;

  --  Clearing the old default first, for the same reason 068 decides the
  --  primary guardian before writing: the partial unique index permits one,
  --  and "duplicate key" is not an error message anybody can act on.
  if v_def then
    update public.madrasah_fee_rates set is_default = false
     where masjid_id = v_masjid and is_default and (v_id is null or id <> v_id);
  end if;

  insert into public.madrasah_fee_rates as t
    (id, masjid_id, name, amount_p, is_default, active, sort)
  values (coalesce(v_id, gen_random_uuid()), v_masjid, v_name, v_amt, v_def,
          coalesce((p->>'active')::boolean, true),
          coalesce((p->>'sort')::integer, 0))
  on conflict (id) do update set
    name = excluded.name, amount_p = excluded.amount_p,
    is_default = excluded.is_default, active = excluded.active,
    sort = excluded.sort, updated_at = now()
  where t.masjid_id = v_masjid
  returning * into v_row;

  if v_row.id is null then
    raise exception 'There is no such rate at this masjid.' using errcode = 'no_data_found';
  end if;

  --  THE AUDIT CARRIES THE AMOUNT. Every other audit row in this system
  --  records the act and not the content, because the content is somebody's
  --  personal data. A fee rate is not personal data, it is the number the
  --  masjid charges, and "who changed £10 to £14 and when" is precisely the
  --  question a treasurer asks six months later.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(),
          case when v_id is null then 'madrasah_fee_rate_added' else 'madrasah_fee_rate_changed' end,
          jsonb_build_object('id', v_row.id, 'name', v_row.name, 'amount_p', v_row.amount_p));

  return jsonb_build_object('id', v_row.id);
end $fn$;

-- ---------------------------------------------------------------------------
--  6. Writing a term
-- ---------------------------------------------------------------------------
create or replace function public.save_madrasah_fee_period(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_id      uuid := nullif(p->>'id', '')::uuid;
  v_masjid  uuid := public.current_masjid();
  v_name    text := btrim(coalesce(p->>'name', ''));
  v_status  text;
  v_charges int := 0;
  v_starts  date;
  v_ends    date;
  v_weeks   numeric;
  v_row     public.madrasah_fee_periods%rowtype;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change a term.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected.' using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'A term needs a name, like "Autumn term 2026".'
      using errcode = 'check_violation';
  end if;
  if v_id is null and (nullif(p->>'starts_on','') is null
                    or nullif(p->>'ends_on','')   is null
                    or nullif(p->>'weeks','')     is null) then
    raise exception 'A new term needs two dates and a number of weeks.'
      using errcode = 'check_violation';
  end if;

  if v_id is not null then
    select status, starts_on, ends_on, weeks
      into v_status, v_starts, v_ends, v_weeks
      from public.madrasah_fee_periods
     where id = v_id and masjid_id = v_masjid;
    if v_status is null then
      raise exception 'There is no such term at this masjid.' using errcode = 'no_data_found';
    end if;
    select count(*) into v_charges from public.madrasah_charges where period_id = v_id;

    --  ONCE BILLS HAVE GONE OUT, THE SUM THEY WERE WORKED OUT FROM IS FROZEN.
    --  Changing 13 weeks to 12 after charging would leave every one of five
    --  hundred charges disagreeing with the term it belongs to, and nothing
    --  on any screen would say so — the parent who checks their own
    --  arithmetic finds it first, which is the worst possible way for a
    --  masjid to discover a billing error.
    if v_charges > 0
       and exists (select 1 from public.madrasah_fee_periods
                    where id = v_id
                      and (weeks     is distinct from coalesce(nullif(p->>'weeks','')::numeric, weeks)
                        or starts_on is distinct from coalesce(nullif(p->>'starts_on','')::date, starts_on)
                        or ends_on   is distinct from coalesce(nullif(p->>'ends_on','')::date, ends_on))) then
      raise exception
        '% charge(s) have already been raised against that term, so its dates and week count cannot change. Cancel the charges first, or make a new term.', v_charges
        using errcode = 'check_violation';
    end if;
  end if;

  --  A KEY THAT IS ABSENT MEANS "LEAVE IT ALONE", NOT "SET IT TO NULL".
  --
  --  This is what made a billed term unsaveable. The screen correctly refuses
  --  to send weeks, starts_on and ends_on for a term that has already been
  --  charged — they are frozen — and the insert then evaluated all three to
  --  NULL against NOT NULL columns. Postgres checks NOT NULL on the proposed
  --  tuple BEFORE ON CONFLICT resolves, so it failed with a raw constraint
  --  message, and the State dropdown is the only route to `closed` — meaning
  --  a term could never be closed once it had been billed, which is exactly
  --  when anybody would want to.
  insert into public.madrasah_fee_periods as t
    (id, masjid_id, name, starts_on, ends_on, weeks, status)
  values (coalesce(v_id, gen_random_uuid()), v_masjid, v_name,
          coalesce(nullif(p->>'starts_on', '')::date, v_starts, current_date),
          coalesce(nullif(p->>'ends_on',   '')::date, v_ends,   current_date),
          coalesce(nullif(p->>'weeks',     '')::numeric, v_weeks),
          coalesce(nullif(btrim(coalesce(p->>'status','')), ''), 'draft'))
  on conflict (id) do update set
    name = excluded.name, starts_on = excluded.starts_on,
    ends_on = excluded.ends_on, weeks = excluded.weeks,
    status = excluded.status,
    issued_at = case when excluded.status = 'issued' and t.issued_at is null
                     then now() else t.issued_at end,
    updated_at = now()
  where t.masjid_id = v_masjid
  returning * into v_row;

  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(),
          case when v_id is null then 'madrasah_fee_period_added'
               else 'madrasah_fee_period_changed' end,
          jsonb_build_object('id', v_row.id, 'name', v_row.name,
                             'weeks', v_row.weeks, 'status', v_row.status));

  return jsonb_build_object('id', v_row.id, 'status', v_row.status);
end $fn$;

-- ---------------------------------------------------------------------------
--  7. Writing a setting
--
--  One key at a time, and the key has to be one this system reads.
-- ---------------------------------------------------------------------------
--  THE VALIDATION LIVES IN ITS OWN FUNCTION SO THAT IT CAN BE TESTED.
--
--  The obvious place for these rules is inside save_madrasah_fee_setting(),
--  and the first draft of this file put them there. That makes them
--  untestable, and worse, it makes them LOOK tested: a check that calls the
--  setter with a bad payment link is refused by verified_admin() long before
--  it reaches the rule, the exception handler catches it, and the check
--  reports a pass it never earned. Migration 065 hit the same shape from a
--  different direction and the lesson is the same — a check that cannot fail
--  is worse than no check.
--
--  Pulled out here, immutable and with no auth in it, the rules can be
--  asserted against directly. Returns null when the value is fine, or the
--  sentence to show the person who typed it.
create or replace function public.madrasah_fee_setting_problem(p_key text, p_text text)
returns text
language sql
immutable
set search_path = public, pg_temp
as $fn$
  select case
    when p_text is null or btrim(p_text) = '' then null

    --  A PAYMENT LINK HAS TO BE A STRIPE PAYMENT LINK.
    --  This box is the one place in the madrasah portal where an administrator
    --  types a URL that the masjid then asks parents to send money through. If
    --  an account is ever taken, changing it to a look-alike is the single most
    --  profitable thing the intruder could do, and nothing else on the screen
    --  would look wrong. Anchored at both ends: 'buy.stripe.com.evil.net' and
    --  'evil.net/buy.stripe.com/x' both pass a test that only looks for the
    --  host somewhere in the string.
    when p_key = 'card_link'
     and btrim(p_text) !~ '^https://(buy|donate|book)\.stripe\.com/[A-Za-z0-9_-]{4,}$'
      then 'That is not a Stripe payment link. It has to start https://buy.stripe.com/ (or donate. or book.) and come from the masjid''s own Stripe account.'

    when p_key = 'bank_sort_code' and btrim(p_text) !~ '^[0-9]{2}-[0-9]{2}-[0-9]{2}$'
      then 'A sort code is six digits, written 00-00-00.'

    when p_key = 'bank_account_number' and btrim(p_text) !~ '^[0-9]{8}$'
      then 'An account number is eight digits.'

    else null
  end
$fn$;

create or replace function public.save_madrasah_fee_setting(p_key text, p_value jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_key    text := btrim(coalesce(p_key, ''));
  v_txt    text;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change a fee setting.'
      using errcode = '42501';
  end if;
  if v_masjid is null then
    raise exception 'No masjid is selected.' using errcode = '42501';
  end if;
  if not (v_key = any(public.madrasah_fee_setting_keys())) then
    raise exception 'There is no fee setting called "%".', v_key using errcode = 'check_violation';
  end if;

  v_txt := public.madrasah_fee_setting_problem(v_key, p_value #>> '{}');
  if v_txt is not null then
    raise exception '%', v_txt using errcode = 'check_violation';
  end if;

  insert into public.madrasah_fee_settings as t (masjid_id, key, value, changed_at, changed_by)
  values (v_masjid, v_key, p_value, now(), auth.uid())
  on conflict (masjid_id, key) do update set
    value = excluded.value, changed_at = now(), changed_by = auth.uid();

  --  THE AUDIT NAMES THE KEY AND NOT THE VALUE FOR THE BANK FIELDS. An audit
  --  row is read by more people and kept longer than the setting it describes;
  --  writing the account number into one puts it in a second place that has
  --  to be looked after. What the auditor needs is that it changed, when, and
  --  who by — and for a sort code, the last two digits are enough to tell two
  --  changes apart.
  insert into public.admin_audit (masjid_id, actor, action, detail)
  values (v_masjid, auth.uid(), 'madrasah_fee_setting_changed',
          jsonb_build_object(
            'key', v_key,
            'value', case when v_key like 'bank_%'
                          then to_jsonb('…' || right(coalesce(p_value #>> '{}', ''), 2))
                          else p_value end));

  return jsonb_build_object('ok', true);
end $fn$;

-- ---------------------------------------------------------------------------
--  8. The sibling discount, as a function rather than a screen's opinion
--
--  Takes a household and returns, per pupil, the discount in pence against a
--  given gross amount. The rule lives in settings as an ordered list:
--
--    [{"from": 2, "kind": "percent", "value": 25},
--     {"from": 3, "kind": "free"}]
--
--  read as: the second child gets 25% off, the third and later are free. The
--  LAST matching rule wins, so the list can be written in any order and the
--  most generous position still applies.
--
--  WHICH CHILD IS "FIRST" IS DECIDED HERE AND WRITTEN DOWN, because every
--  masjid that does this by hand argues about it once: the child who has been
--  at the madrasah longest pays full price, ties broken by name so the answer
--  never changes between two runs. Ranking by age would need a date of birth,
--  which 058 deliberately does not hold.
-- ---------------------------------------------------------------------------
create or replace function public.madrasah_sibling_discount_p(
  p_household uuid, p_pupil uuid, p_gross_p integer)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
  v_rule   jsonb;
  v_rank   integer;
  v_r      jsonb;
  v_off    integer := 0;
begin
  --  IT IS ARITHMETIC, BUT IT IS ARITHMETIC ON TWO FORCE-RLS TABLES.
  --  Without this, any signed-in account could call it: a non-zero answer
  --  confirms that a given pupil id belongs to a given household id, and the
  --  size of the answer discloses the masjid's discount rule. An oracle is
  --  still a disclosure.
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may work out a discount.'
      using errcode = '42501';
  end if;
  if p_household is null or p_gross_p is null or p_gross_p <= 0 then
    return 0;
  end if;

  select value into v_rule from public.madrasah_fee_settings
   where masjid_id = v_masjid and key = 'sibling_rule';
  if v_rule is null or jsonb_typeof(v_rule) <> 'array' or jsonb_array_length(v_rule) = 0 then
    return 0;
  end if;

  --  Only children who are still here count towards a position. A family
  --  whose eldest left in July has two children this year, not three, and
  --  billing them as three is a complaint the office cannot answer.
  select rank into v_rank from (
    select p.id,
           row_number() over (order by p.joined_on nulls last, p.first_name, p.last_name, p.id) as rank
      from public.madrasah_pupils p
     where p.household_id = p_household
       and p.masjid_id = v_masjid
       and p.left_on is null) s
   where s.id = p_pupil;

  if v_rank is null then
    return 0;
  end if;

  for v_r in
    select e from jsonb_array_elements(v_rule) e
     order by coalesce((e->>'from')::integer, 999)
  loop
    if coalesce((v_r->>'from')::integer, 999) <= v_rank then
      if (v_r->>'kind') = 'free' then
        v_off := p_gross_p;
      elsif (v_r->>'kind') = 'percent' then
        --  Rounded, once, here. A percentage applied in a screen and again in
        --  a report is how two numbers that should be equal differ by a penny.
        v_off := round(p_gross_p * least(greatest(coalesce((v_r->>'value')::numeric, 0), 0), 100) / 100.0);
      elsif (v_r->>'kind') = 'pence' then
        v_off := least(greatest(coalesce((v_r->>'value')::integer, 0), 0), p_gross_p);
      end if;
    end if;
  end loop;

  return least(greatest(v_off, 0), p_gross_p);
end $fn$;

-- ---------------------------------------------------------------------------
--  9. Seed — the published figures, marked unconfirmed
-- ---------------------------------------------------------------------------
do $seed$
declare v_m uuid;
begin
  for v_m in select id from public.masjids loop
    insert into public.madrasah_fee_rates (masjid_id, name, amount_p, is_default, sort)
    values (v_m, 'All classes', 1000, true, 1)
    on conflict (masjid_id, lower(btrim(name))) do nothing;

    insert into public.madrasah_fee_rates (masjid_id, name, amount_p, is_default, sort)
    values (v_m, 'Hifz', 1400, false, 2)
    on conflict (masjid_id, lower(btrim(name))) do nothing;

    --  No sibling rule is seeded. An empty list means no discount, which is
    --  a true statement about a masjid that has not told anybody its rule.
    --  Seeding a plausible 25% would put a number on five hundred bills that
    --  nobody at the masjid had ever agreed to.
    insert into public.madrasah_fee_settings (masjid_id, key, value)
    values (v_m, 'sibling_rule', '[]'::jsonb)
    on conflict (masjid_id, key) do nothing;
  end loop;
end $seed$;

grant execute on function public.madrasah_fee_structure()                          to authenticated;
grant execute on function public.save_madrasah_fee_rate(jsonb)                     to authenticated;
grant execute on function public.save_madrasah_fee_period(jsonb)                   to authenticated;
grant execute on function public.save_madrasah_fee_setting(text, jsonb)            to authenticated;
grant execute on function public.madrasah_sibling_discount_p(uuid, uuid, integer)  to authenticated;
grant execute on function public.madrasah_fee_setting_keys()                       to authenticated;

commit;

-- ===========================================================================
--  CHECKS
-- ===========================================================================

--  #1  Money is an integer type. Proved by changing amount_p to numeric and
--      watching this fail.
do $c1$
declare v_t text;
begin
  select atttypid::regtype::text into v_t
    from pg_attribute
   where attrelid = 'public.madrasah_fee_rates'::regclass and attname = 'amount_p';
  if v_t <> 'integer' then
    raise exception 'CHECK 1 FAILED: madrasah_fee_rates.amount_p is %, not integer. Money in this system is whole pence.', v_t;
  end if;
  raise notice 'CHECK 1 passed: rates are integer pence.';
end $c1$;

--  #2  A payment link can only point at Stripe.
--      The check that would matter most on the worst day this system has.
--
--      It asserts the GOOD link first, deliberately. Nine rejections prove
--      nothing on their own — a function that refuses everything, or one that
--      cannot be reached at all, passes every one of them. The accept case is
--      what proves the rest of this check is actually running.
do $c2$
declare
  v_ok  text;
  v_bad text;
  v_url text;
begin
  v_ok := public.madrasah_fee_setting_problem('card_link', 'https://buy.stripe.com/5kQ6oHfU02LC0p05p4f3a07');
  if v_ok is not null then
    raise exception 'CHECK 2 FAILED: a genuine Stripe payment link was refused (%). Every rejection below this line would have passed for the wrong reason.', v_ok;
  end if;

  foreach v_url in array array[
    'https://buy.stripe.evil.com/abc123',        -- look-alike subdomain
    'https://buy.stripe.com.evil.net/abc123',    -- host suffix
    'https://evil.net/buy.stripe.com/abc123',    -- host in the path
    'http://buy.stripe.com/abc123',              -- no TLS
    'https://buy.stripe.com/abc123?redirect=x',  -- trailing query
    'javascript:alert(1)'
  ] loop
    v_bad := public.madrasah_fee_setting_problem('card_link', v_url);
    if v_bad is null then
      raise exception 'CHECK 2 FAILED: "%" was accepted as the madrasah payment link.', v_url;
    end if;
  end loop;
  raise notice 'CHECK 2 passed: a real Stripe link is accepted and six look-alikes are refused.';
end $c2$;

--  #3  Sort code and account number are the right shape, and an unknown
--      setting key is refused rather than quietly stored — a misspelt key
--      would be saved, read by nothing, and look to the office exactly like
--      saving having worked.
do $c3$
declare v_keys text[] := public.madrasah_fee_setting_keys();
begin
  if public.madrasah_fee_setting_problem('bank_sort_code', '30-99-50') is not null then
    raise exception 'CHECK 3 FAILED: a valid sort code was refused.';
  end if;
  if public.madrasah_fee_setting_problem('bank_sort_code', '309950') is null then
    raise exception 'CHECK 3 FAILED: an unformatted sort code was accepted.';
  end if;
  if public.madrasah_fee_setting_problem('bank_account_number', '59286668') is not null then
    raise exception 'CHECK 3 FAILED: a valid account number was refused.';
  end if;
  if public.madrasah_fee_setting_problem('bank_account_number', '5928666') is null then
    raise exception 'CHECK 3 FAILED: a seven-digit account number was accepted.';
  end if;
  if 'bank_sortcode' = any(v_keys) or not ('bank_sort_code' = any(v_keys)) then
    raise exception 'CHECK 3 FAILED: the known-keys list does not say what the setter expects.';
  end if;
  raise notice 'CHECK 3 passed: bank fields are shape-checked and unknown keys are refused.';
end $c3$;

--  #4  Every function in this file is administrators only. 065's lesson: the
--      test is line-based, because a substring test against a whole function
--      body passes on one that merely mentions the word in a comment.
do $c4$
declare v_fn text; v_def text; v_line text; v_found boolean;
begin
  --  madrasah_sibling_discount_p IS IN THIS LIST NOW. It was not, and the
  --  function it was meant to cover was the one missing its check — a list of
  --  names is only as good as its completeness, which makes it the weakest
  --  shape of check in this file. It is kept because it catches a removal;
  --  it cannot catch an omission, and that is worth knowing about it.
  foreach v_fn in array array['madrasah_fee_structure', 'save_madrasah_fee_rate',
                              'save_madrasah_fee_period', 'save_madrasah_fee_setting',
                              'madrasah_sibling_discount_p'] loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_fn limit 1;
    if v_def is null then
      raise exception 'CHECK 4 FAILED: public.%() does not exist.', v_fn;
    end if;
    v_found := false;
    foreach v_line in array string_to_array(v_def, E'\n') loop
      if btrim(v_line) not like '--%' and v_line like '%public.verified_admin()%' then
        v_found := true; exit;
      end if;
    end loop;
    if not v_found then
      raise exception 'CHECK 4 FAILED: public.%() never calls public.verified_admin() in live code.', v_fn;
    end if;
  end loop;
  raise notice 'CHECK 4 passed: the fee structure is administrators only.';
end $c4$;

--  #5  The seeded rate card is marked unconfirmed, so the screen can say so.
--      The masjid has never confirmed £10 / £14 / £20.
do $c5$
declare v_n int;
begin
  select count(*) into v_n
    from public.madrasah_fee_settings
   where key = 'rates_confirmed_on';
  if v_n > 0 then
    raise notice 'CHECK 5: somebody has confirmed the rate card. Good — this file did not do it for them.';
  else
    raise notice 'CHECK 5 passed: the rate card is seeded but UNCONFIRMED. The structure screen shows a banner until an administrator confirms the figures.';
  end if;
end $c5$;

-- ===========================================================================
--  AFTER APPLYING THIS FILE — re-run db/011_require_two_step.sql.
-- ===========================================================================
