-- ===========================================================================
--  030_charity_collections.sql — the Chanda / charity collection booking
--
--  14 September 2026. Replaces a paper "CHARITY DATA FORM" that an external
--  fundraiser fills in by hand at the masjid, and a poster telling them to
--  ring two committee members. People come from all over the world to collect
--  here; the paper version means nothing is searchable, nothing is checked
--  against the Charity Commission, and two collectors can be booked for the
--  same Friday by two different committee members who never spoke.
--
--  A REQUEST, NOT A BOOKING. Same rule as nikāḥ and hall hire: submitting
--  this reserves nothing. The office reads it, rings the trustee, and
--  approves or declines. The public form deliberately shows no availability —
--  the masjid does not publish its diary, and a calendar painting days green
--  would be inventing information. The CLASH is shown to the office only,
--  when they open a request (see charity_collection_clash below).
--
--  WHAT IS DIFFERENT FROM THE PAPER FORM, AND WHY
--
--  1. The wet signature becomes a typed name plus a timestamp. A typed name
--     is not weaker than a scrawl nobody compares to anything; what makes it
--     evidence is that it is stored with WHEN, and with WHICH VERSION OF THE
--     RULES was on screen at the time (rules_version). If the masjid changes
--     the collection rules, every earlier row still says what that person
--     actually agreed to. The paper form cannot do that.
--
--  2. "Do you receive any wage or commission?" is stored as a boolean and
--     surfaced hard in the office screen. On paper it is a tick in a box on
--     page one that nobody reads twice. It is a safeguarding and fraud
--     control: a paid collector is a different proposition and the committee
--     should see it at a glance, not find it later.
--
--  THIRD-PARTY PERSONAL DATA, SAID PLAINLY.
--  This table holds the name, phone and email of a TRUSTEE who is not the
--  person filling the form in and has not consented to anything. That is the
--  same objection raised against 029's witnesses and the masjid's answer was
--  the same then: the masjid needs to reach someone other than the collector
--  to verify the collector. What makes it survivable is the same set of
--  mitigations: no read access for anon at all, a thin audit row, no uploads,
--  and a purge function. Still outstanding for BOTH tables: the DPIA, the ICO
--  entry, the lawful-basis note, and a privacy-notice line naming trustees.
--
--  Prerequisites: 001, 002, 024 (admin_dashboard), 025 (verified_admin /
--  verified_office). Depends on public.is_admin() and public.has_role().
--
--  *** AFTER RUNNING THIS, RE-RUN 011_require_two_step.sql. ***
-- ===========================================================================

begin;

create table if not exists public.charity_collections (
  id              uuid        primary key default gen_random_uuid(),
  reference       text        not null unique,
  submitted_at    timestamptz not null default now(),

  -- ---- when they would like to collect --------------------------------
  requested_date  date        not null,

  -- ---- the charity or institute (idara) -------------------------------
  org_name        text        not null check (length(btrim(org_name)) >= 2),
  org_address     text        not null check (length(btrim(org_address)) >= 5),
  org_phone       text        not null check (length(btrim(org_phone)) >= 6),
  org_email       text        not null
                    check (org_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),
  -- "If applicable" on the paper form, and it means it: an overseas cause or
  -- an unregistered institute has no UK number. Stored as typed, not
  -- validated into a shape only English charities have.
  charity_number  text        check (charity_number is null
                                     or length(btrim(charity_number)) between 3 and 30),

  -- ---- the person who will actually stand in the masjid ----------------
  collector_name  text        not null check (length(btrim(collector_name)) >= 2),
  collector_role  text        not null check (length(btrim(collector_role)) >= 2),
  -- The question the paper form asks. Not nullable: "they left it blank" and
  -- "they said no" must never be the same row.
  collector_paid  boolean     not null,

  -- ---- somebody other than the collector, to verify the collector ------
  trustee_name    text        not null check (length(btrim(trustee_name)) >= 2),
  trustee_phone   text        not null check (length(btrim(trustee_phone)) >= 6),
  trustee_email   text        not null
                    check (trustee_email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'),

  -- ---- what replaces the signature -------------------------------------
  rules_version   text        not null,
  rules_accepted  boolean     not null check (rules_accepted),
  signed_name     text        not null check (length(btrim(signed_name)) >= 2),
  privacy_accepted boolean    not null check (privacy_accepted),

  -- ---- office workflow -------------------------------------------------
  status          text        not null default 'new'
                    check (status in ('new','contacted','approved',
                                      'declined','withdrawn','completed')),
  agreed_date     date,
  office_notes    text        check (length(coalesce(office_notes,'')) <= 2000),
  reviewed_by     uuid        references auth.users(id) on delete set null,
  reviewed_at     timestamptz
);

comment on table public.charity_collections is
  'Requests from external charities to collect (chanda) at the masjid. A request only — approval is the office''s, in person.';
comment on column public.charity_collections.collector_paid is
  'Does this person take a wage or commission for collecting? Surfaced hard in the office screen — it is a safeguarding control, not a detail.';
comment on column public.charity_collections.rules_version is
  'Which version of the collection rules was on screen when they agreed. Changing the rules must not rewrite what past applicants signed.';

create sequence if not exists public.charity_reference_seq;
create index if not exists charity_status_idx
  on public.charity_collections(status, requested_date);
create index if not exists charity_date_idx
  on public.charity_collections(requested_date);

-- ---------------------------------------------------------------------------
--  Privileges — anon holds NOTHING on this table.
--
--  Supabase grants ALL on a new table in `public` to anon and authenticated
--  by default. Without this revoke, the anon key in the page source would
--  read every trustee's phone number on the site.
-- ---------------------------------------------------------------------------
revoke all on public.charity_collections from anon, authenticated;
grant select,
      update (status, agreed_date, office_notes, reviewed_by, reviewed_at)
  on public.charity_collections to authenticated;

-- The column list above is the control. The office may move a request along
-- and write notes on it; the office may NOT edit what the charity actually
-- declared. A comment claiming that would be worth nothing — 016 is in this
-- repository precisely because a README said it for months and no grant
-- enforced it.

alter table public.charity_collections enable row level security;

-- Not FORCE: the function below reads the table to spot a duplicate, and
-- FORCE applies RLS to the owner too, which would silently return nothing.
-- Same reasoning as 009 and 010.

--  verified_*, NEVER is_admin() or has_role() directly.
--
--  This file was first written from 010's, which PREDATES 011. Its policies
--  read is_admin() / has_role(), which check the role and not the
--  AUTHENTICATOR LEVEL — so a staff email and password alone, with no code,
--  would have read every trustee's phone number straight from the API. That
--  is exactly the hole 011 exists to close, and 011's header states the rule.
--  Caught on 14 September 2026 by comparing the live policies on this table
--  against the live policies on nikah_requests, which 011 had rewritten.
--  _test_two_step.sql scans pg_policies and fails if this is ever undone.
create policy office_read_charity on public.charity_collections
  for select to authenticated
  using (public.verified_admin() or public.verified_office());
create policy office_update_charity on public.charity_collections
  for update to authenticated
  using (public.verified_admin() or public.verified_office())
  with check (public.verified_admin() or public.verified_office());
create policy definer_insert_charity on public.charity_collections
  for insert with check (true);
create policy definer_delete_charity on public.charity_collections
  for delete using (true);

-- ---------------------------------------------------------------------------
--  Submitting a request
-- ---------------------------------------------------------------------------
create or replace function public.request_charity_collection(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  --  THE MASJID CAN CHANGE THESE TWO NUMBERS. Fourteen days matches the
  --  notice the masjid already asks for on a nikāḥ; nobody has said whether a
  --  collection needs as long. If it does not, lower it here AND in the
  --  collection page's MIN_NOTICE_DAYS, which is what the date field enforces
  --  in the browser.
  NOTICE_DAYS  constant int := 14;
  HORIZON_DAYS constant int := 365;

  v_date    date    := (payload ->> 'requested_date')::date;
  v_email   text    := lower(btrim(payload ->> 'org_email'));
  v_paid    boolean := (payload ->> 'collector_paid')::boolean;
  v_rules_v text    := nullif(btrim(payload ->> 'rules_version'), '');
  v_ref     text;
begin
  if v_date is null then
    raise exception 'Please choose a date for the collection';
  end if;
  if v_date < current_date then
    raise exception 'That date has already passed';
  end if;
  --  Enforced HERE as well as in the page. The page will not offer a date
  --  inside the notice period, but a form can be driven from outside a
  --  browser and the office should never be handed a date it cannot honour.
  if v_date < current_date + NOTICE_DAYS then
    raise exception 'The masjid needs at least % days'' notice — the earliest date we can take is %',
      NOTICE_DAYS, to_char(current_date + NOTICE_DAYS, 'DD Mon YYYY');
  end if;
  if v_date > current_date + HORIZON_DAYS then
    raise exception 'Collections can only be requested up to a year ahead';
  end if;

  --  "They did not answer" and "they answered no" are different facts, and a
  --  null here would quietly become the second one.
  if v_paid is null then
    raise exception 'Please answer whether the collector receives a wage or commission';
  end if;
  if v_rules_v is null then
    raise exception 'The collection rules were not recorded — please reload the page and try again';
  end if;
  if not coalesce((payload ->> 'rules_accepted')::boolean, false) then
    raise exception 'The collection rules have to be accepted';
  end if;
  if not coalesce((payload ->> 'privacy_accepted')::boolean, false) then
    raise exception 'Please accept how the masjid handles this information';
  end if;

  --  Someone pressing the button twice, or filling it in again next week
  --  because nobody rang back, must not become two requests the office has to
  --  work out are the same. An amendment is a phone call, not a second form.
  if exists (select 1 from public.charity_collections
              where lower(org_email) = v_email
                and requested_date = v_date
                and status in ('new','contacted','approved')) then
    raise exception 'The masjid already has a request from this email address for that date. The office will be in touch.';
  end if;

  v_ref := 'CC-' || to_char(now(), 'YY') || '-' ||
           lpad(nextval('public.charity_reference_seq')::text, 4, '0');

  insert into public.charity_collections (
    reference, requested_date,
    org_name, org_address, org_phone, org_email, charity_number,
    collector_name, collector_role, collector_paid,
    trustee_name, trustee_phone, trustee_email,
    rules_version, rules_accepted, signed_name, privacy_accepted
  ) values (
    v_ref, v_date,
    btrim(payload ->> 'org_name'), btrim(payload ->> 'org_address'),
    btrim(payload ->> 'org_phone'), v_email,
    nullif(btrim(payload ->> 'charity_number'), ''),
    btrim(payload ->> 'collector_name'), btrim(payload ->> 'collector_role'), v_paid,
    btrim(payload ->> 'trustee_name'), btrim(payload ->> 'trustee_phone'),
    lower(btrim(payload ->> 'trustee_email')),
    v_rules_v, true, btrim(payload ->> 'signed_name'), true
  );

  --  THE AUDIT ROW STAYS THIN. admin_audit is read on a dashboard by anybody
  --  with an office login; it records that a request arrived and its
  --  reference, never the trustee's details.
  insert into public.admin_audit (action, detail)
  values ('charity_collection_request',
          jsonb_build_object('reference', v_ref, 'date', v_date));

  return jsonb_build_object('reference', v_ref, 'requested_date', v_date);
end;
$$;

revoke all on function public.request_charity_collection(jsonb) from public;
grant execute on function public.request_charity_collection(jsonb) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  The clash, for the office only
--
--  The masjid allows one collection a day. The public form is not told which
--  days are taken — publishing that is publishing the masjid's diary, and the
--  same argument was settled that way for nikāḥ. Instead the office is told,
--  at the moment it matters, which is when they open a request.
--
--  A function rather than a view so that a caller cannot select columns it
--  should not see: this returns references and dates, never a trustee.
-- ---------------------------------------------------------------------------
create or replace function public.charity_collection_clash(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v_rows jsonb;
begin
  if not (public.verified_admin() or public.verified_office()) then
    raise exception 'Not allowed';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
           'reference', reference, 'org_name', org_name, 'status', status)
           order by reference), '[]'::jsonb)
    into v_rows
    from public.charity_collections
   where coalesce(agreed_date, requested_date) = p_date
     and status in ('approved','contacted');
  return v_rows;
end;
$$;

revoke all on function public.charity_collection_clash(date) from public;
grant execute on function public.charity_collection_clash(date) to authenticated;

-- ---------------------------------------------------------------------------
--  Retention — same shape and the same 12 months as everything else here
-- ---------------------------------------------------------------------------
create or replace function public.purge_old_charity_collections(retain_months int)
returns int
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_deleted int;
begin
  if not public.is_admin() then
    raise exception 'Only an administrator may purge collection requests';
  end if;
  if retain_months is null or retain_months < 1 then
    raise exception 'retain_months must be a positive number of months';
  end if;
  with gone as (
    delete from public.charity_collections
     where status in ('declined','withdrawn','completed')
       and submitted_at < now() - make_interval(months => retain_months)
    returning 1
  ) select count(*) into v_deleted from gone;
  insert into public.admin_audit (action, detail)
  values ('charity_collections_purged',
          jsonb_build_object('deleted', v_deleted, 'retain_months', retain_months));
  return v_deleted;
end;
$$;

revoke all on function public.purge_old_charity_collections(int) from public;
grant execute on function public.purge_old_charity_collections(int) to authenticated;

commit;
