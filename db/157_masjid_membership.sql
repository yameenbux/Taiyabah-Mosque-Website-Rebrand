-- ===========================================================================
--  157 — masjid membership: the register, the years, and what came in
--
--  Taiyabah Masjid · 12 November 2026
--
--  WHAT THIS REPLACES. Nothing in software. The membership register is an
--  Excel sheet held at the masjid, and "has he paid?" is answered by someone
--  who knows. That works at the counter and nowhere else: the nikāḥ fee
--  already charges members £100 and non-members £200 on the honour system,
--  because there is no register for it to ask.
--
--  THE SHAPE IS THE MADRASAH FEE SHAPE, and deliberately so. 069/070 settled
--  this: a RATE that says what a year costs, a CHARGE per person per period,
--  PAYMENTS against it, and the balance COMPUTED rather than stored. Every
--  part of that was argued once already and does not need arguing again.
--
--  THERE IS NO `status` COLUMN ON A YEAR. A year is paid when the payments
--  against it reach what is owed, and that is a sum, not a flag. A flag is a
--  second copy of an answer the payments already give, and 070 says what
--  happens to second copies: one of them gets fixed and the other does not.
--  Waiving is the one thing that is not a payment, so it is `waived_p`, and
--  `net_p` is generated from the two.
--
--  FIVE YEARS BEHIND IS THE NORMAL CASE, not an exception. The trustees have
--  confirmed members who have not paid since 2021. So:
--
--    * a year carries the fee THAT APPLIED THEN. The fee was £80 before 2024
--      and is £100 now; charging 2022 at today's rate would overcharge by £20
--      a year, in the masjid's favour, which is the worst direction for a
--      charity to be wrong in.
--    * the import carries HISTORY, not current state. A register that begins
--      in 2026 would tell a man who has paid for ten years that he owes
--      nothing and show him no record of it, and would tell the office
--      nothing about who is actually behind.
--
--  THE MASJID ASKS AND CANNOT COMPEL. It is a charity. `waived_p` is what
--  makes that true in the database rather than only in the wording: any year
--  can be set aside by a named administrator, and the balance follows. The
--  member-facing functions never speak of debt.
--
--  THE LOOKUP REVEALS A COUNT BEFORE IT REVEALS A PERSON. There is no
--  membership number, because older members will not have one and the ones
--  who do will not remember it — the counter asks a name. So the first step
--  takes a name and answers with HOW MANY records match, never whose. The
--  second step takes the house number and postcode and either matches
--  exactly or does not. `membership_claim()` returns the SAME refusal
--  whichever field was wrong, so the function cannot be used to confirm that
--  a name is on the register by watching which answer changes.
--
--  WHAT A SUCCESSFUL LOOKUP DISCLOSES is what somebody already standing at
--  the counter would be told: whether that person is behind, and by how much.
--  It needs a name AND a house number AND a postcode to say it. That is a
--  real disclosure and worth naming: anyone who knows all three of those
--  about a neighbour can learn whether the neighbour owes the masjid money.
--  THE BRAKE ON THAT IS CRUDE, AND SAYING SO IS THE POINT. Postgres cannot
--  see a request IP, and the app calls these functions directly rather than
--  through the Worker, so there is nowhere here to throttle one caller.
--  membership_claim() in 158 instead counts FAILED address attempts across
--  the whole masjid in the last ten minutes and refuses past a ceiling set
--  well above ordinary use. Somebody working through a list of names meets
--  it; a congregation paying their fees does not.
--
--  Its weakness is stated rather than hidden: being masjid-wide, an attacker
--  willing to keep failing can hold it on and stop real members looking
--  themselves up. That is a nuisance rather than a disclosure, and it is the
--  better way round. Its refusal is a DIFFERENT shape from a mismatch, so a
--  member who meets it is told to try again shortly rather than told their
--  details are wrong — and so the brake cannot itself become the oracle the
--  single refusal shape exists to prevent.
--
--  `membership_lookup_log` below records that attempts happened, with nothing
--  identifying in it — the time, the step, and whether it matched — so the
--  office can see hammering without the log becoming a record of who asked
--  about whom.
--
--  Prerequisites: masjids, current_masjid(), verified_admin(). Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. What a year costs
--
--  One row per year, for the whole masjid. Not per member: the fee is the fee.
--  History lives here, which is why a 2022 row is never edited to today's
--  figure — editing it would silently restate five hundred balances.
-- ---------------------------------------------------------------------------
create table if not exists public.membership_rates (
  id          uuid primary key default gen_random_uuid(),
  masjid_id   uuid not null references public.masjids(id) on delete cascade,
  year        integer not null,
  fee_p       integer not null,
  note        text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  --  The register goes back as far as the masjid's own records and no
  --  further. A year outside this is a typo, not a fee.
  constraint membership_rate_year_is_sane check (year between 1990 and 2100),
  --  £1 to £1,000. The ceiling is a guard against a stray zero turning £100
  --  into £1,000 across the whole register, not an opinion about the fee.
  constraint membership_rate_fee_is_sane check (fee_p between 100 and 100000),
  constraint membership_rate_note_is_short check (note is null or length(note) <= 300)
);

create unique index if not exists membership_rate_one_per_year_idx
  on public.membership_rates (masjid_id, year);

alter table public.membership_rates enable row level security;
alter table public.membership_rates force row level security;
revoke all on public.membership_rates from anon, authenticated;

-- ---------------------------------------------------------------------------
--  2. The register
--
--  `ref_no` IS FOR LIFE AND IS NOT THE REFERENCE. The payment reference is
--  MF-26-0042: the prefix the webhook routes on, the year being paid, and
--  this number. A member keeps 0042 forever; only the year moves. A literal
--  "Member Fee - 2026" would be the same string for five hundred people and
--  could not be matched to one of them.
--
--  `house_no` IS SEPARATE FROM `address_line` because it is half of the
--  lookup. Asking for the whole address back would fail on "31a Draycott St"
--  against "31A Draycott Street" and send a member who typed it correctly to
--  the office. Number and postcode are the two things a person says at a
--  counter and the two that normalise cleanly.
-- ---------------------------------------------------------------------------
create table if not exists public.masjid_members (
  id            uuid primary key default gen_random_uuid(),
  masjid_id     uuid not null references public.masjids(id) on delete cascade,
  ref_no        integer not null,
  full_name     text not null,
  house_no      text,
  address_line  text,
  postcode      text,
  telephone     text,
  --  Mostly null, and that is the problem this system quietly solves. The
  --  register has almost no email addresses, so the Ramadan reminder cannot
  --  reach anybody. Stripe collects an address at checkout in order to send
  --  its own receipt, and mark_membership_fee_paid() writes it back here.
  --  Paying online fills the register in.
  email         text,
  member_since  date,
  left_on       date,
  note          text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid,
  constraint membership_member_has_a_name
    check (length(btrim(full_name)) between 2 and 120),
  constraint membership_member_ref_is_sane check (ref_no between 1 and 9999),
  constraint membership_member_fields_are_short
    check ((house_no     is null or length(house_no)     <= 24)
       and (address_line is null or length(address_line) <= 200)
       and (postcode     is null or length(postcode)     <= 12)
       and (telephone    is null or length(telephone)    <= 32)
       and (email        is null or length(email)        <= 160)
       and (note         is null or length(note)         <= 500)),
  --  Somebody cannot have left before they joined.
  constraint membership_member_left_after_joining
    check (left_on is null or member_since is null or left_on >= member_since)
);

create unique index if not exists membership_member_ref_idx
  on public.masjid_members (masjid_id, ref_no);

--  The name step searches this.
create index if not exists membership_member_name_idx
  on public.masjid_members (masjid_id, lower(btrim(full_name)));

--  The address step searches this: both halves normalised the same way the
--  lookup normalises what was typed, so the comparison is index-usable and
--  "bl1 8hd" finds "BL1 8HD".
create index if not exists membership_member_address_idx
  on public.masjid_members (
    masjid_id,
    upper(replace(coalesce(postcode, ''), ' ', '')),
    lower(replace(coalesce(house_no, ''), ' ', ''))
  );

alter table public.masjid_members enable row level security;
alter table public.masjid_members force row level security;
revoke all on public.masjid_members from anon, authenticated;

-- ---------------------------------------------------------------------------
--  3. A member's year — the charge
--
--  `fee_p` is COPIED from the rate rather than read through it, exactly as
--  madrasah_charges copies rate_p. The rate table is history and should not
--  change, but a balance that depends on another table still being right is
--  a balance that can be restated by an edit nobody connected to it.
-- ---------------------------------------------------------------------------
create table if not exists public.membership_years (
  id          uuid primary key default gen_random_uuid(),
  masjid_id   uuid not null references public.masjids(id) on delete cascade,
  member_id   uuid not null references public.masjid_members(id) on delete cascade,
  year        integer not null,
  fee_p       integer not null,
  waived_p    integer not null default 0,
  waiver_note text,
  waived_by   uuid,
  waived_at   timestamptz,
  net_p       integer generated always as (fee_p - waived_p) stored,
  created_at  timestamptz not null default now(),
  created_by  uuid,
  constraint membership_year_is_sane check (year between 1990 and 2100),
  constraint membership_year_fee_is_sane check (fee_p between 0 and 100000),
  --  A WAIVER CANNOT EXCEED THE FEE. Without this a mistyped waiver turns the
  --  year negative, the member goes into credit, and they drop off the Still
  --  owing screen — the mistake hides itself. 070 learnt this one.
  constraint membership_year_waiver_within_fee
    check (waived_p >= 0 and waived_p <= fee_p),
  --  A waiver is somebody's decision, so it carries who and when. A waived
  --  year with nobody against it is the thing an audit cannot answer.
  constraint membership_year_waiver_is_attributed
    check (waived_p = 0 or (waived_by is not null and waived_at is not null)),
  constraint membership_year_note_is_short
    check (waiver_note is null or length(waiver_note) <= 300)
);

--  One charge per member per year. This is what makes "raise this year's
--  charges" safe to press twice, which somebody will.
create unique index if not exists membership_year_one_per_member_idx
  on public.membership_years (member_id, year);

create index if not exists membership_year_year_idx
  on public.membership_years (masjid_id, year);

alter table public.membership_years enable row level security;
alter table public.membership_years force row level security;
revoke all on public.membership_years from anon, authenticated;

-- ---------------------------------------------------------------------------
--  4. What came in
--
--  A payment names the YEAR it pays. It is not allocated by a rule, because
--  the two buttons on the member's screen mean different things and a rule
--  would have to guess which: "Pay £100 — 2026 only" pays THIS year, not the
--  oldest one, because what the member came for is to be a member now.
--  Paying the oldest year instead would take their money and leave them
--  still not a member. The checkout session carries the years it covers and
--  the webhook writes one row per year.
--
--  `stripe_session_id` IS THE IDEMPOTENCY KEY. Stripe retries a webhook it
--  did not hear back from, and a retry must not take the money twice on
--  paper. Unique per session per year.
--
--  `bank_reference` is what was ACTUALLY on the statement, not what it should
--  have said — 070's reasoning, unchanged: in six months the only way back to
--  the bank is the string the bank has.
-- ---------------------------------------------------------------------------
create table if not exists public.membership_payments (
  id                uuid primary key default gen_random_uuid(),
  masjid_id         uuid not null references public.masjids(id) on delete cascade,
  member_id         uuid not null references public.masjid_members(id) on delete restrict,
  year              integer not null,
  amount_p          integer not null,
  method            text not null,
  received_on       date not null default current_date,
  stripe_session_id text,
  bank_reference    text,
  note              text,
  --  Null for a card payment the webhook recorded — nobody did that, and 089
  --  settled that pretending otherwise is worse than an honest null.
  recorded_by       uuid,
  created_at        timestamptz not null default now(),
  constraint membership_payment_year_is_sane check (year between 1990 and 2100),
  constraint membership_payment_is_positive check (amount_p between 1 and 1000000),
  --  'legacy' is for the years that come in from the Excel sheet, where the
  --  method was not recorded. It is honest about not knowing instead of
  --  guessing 'cash' and making the figure look researched.
  constraint membership_payment_method_valid
    check (method in ('card', 'cash', 'terminal', 'bank', 'cheque', 'legacy', 'other')),
  constraint membership_payment_fields_are_short
    check ((stripe_session_id is null or length(stripe_session_id) <= 120)
       and (bank_reference    is null or length(bank_reference)    <= 60)
       and (note              is null or length(note)              <= 300))
);

create unique index if not exists membership_payment_session_idx
  on public.membership_payments (stripe_session_id, year)
  where stripe_session_id is not null;

create index if not exists membership_payment_member_idx
  on public.membership_payments (member_id, year);

create index if not exists membership_payment_received_idx
  on public.membership_payments (masjid_id, received_on desc);

alter table public.membership_payments enable row level security;
alter table public.membership_payments force row level security;
revoke all on public.membership_payments from anon, authenticated;

-- ---------------------------------------------------------------------------
--  5. The lookup's short-lived ticket
--
--  Once a member has matched, the screens that follow must not keep passing
--  the name and address back and forth, and the AMOUNT must never come from
--  the client. The claim is the server's own handle on "this browser proved
--  it is member 0042 a moment ago", and the amount is computed from it. A
--  client that could send an amount could pay £1 and clear £460.
-- ---------------------------------------------------------------------------
create table if not exists public.membership_claims (
  token      uuid primary key default gen_random_uuid(),
  masjid_id  uuid not null references public.masjids(id) on delete cascade,
  member_id  uuid not null references public.masjid_members(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 minutes'
);

create index if not exists membership_claim_expiry_idx
  on public.membership_claims (expires_at);

alter table public.membership_claims enable row level security;
alter table public.membership_claims force row level security;
revoke all on public.membership_claims from anon, authenticated;

-- ---------------------------------------------------------------------------
--  6. That attempts happened, and nothing about who made them
--
--  No name, no address, no postcode, no IP. Only the time and whether it
--  matched. Enough for the office to see somebody working through a list;
--  not a log of who asked about whom. The same reasoning
--  madrasah_fee_reminders applies to email addresses.
-- ---------------------------------------------------------------------------
create table if not exists public.membership_lookup_log (
  id        bigserial primary key,
  masjid_id uuid not null references public.masjids(id) on delete cascade,
  step      text not null,
  matched   boolean not null,
  at        timestamptz not null default now(),
  constraint membership_lookup_step_valid check (step in ('name', 'address'))
);

create index if not exists membership_lookup_log_at_idx
  on public.membership_lookup_log (masjid_id, at desc);

alter table public.membership_lookup_log enable row level security;
alter table public.membership_lookup_log force row level security;
revoke all on public.membership_lookup_log from anon, authenticated;

commit;
