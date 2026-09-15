-- ===========================================================================
--  037_rate_limit_every_public_form.sql — four more forms anybody could flood
--
--  *** APPLIED TO PRODUCTION 15 September 2026. ***
--
--  036 rate limited the charity collection form after finding it accepted
--  eight submissions from one phone and one email in a single go. The obvious
--  next question — WHICH OTHER FORMS ARE LIKE THAT? — turned out to have an
--  embarrassing answer, and the first attempt to answer it was wrong.
--
--  A quick search of each function for the words "rate", "throttle" or
--  "limit" said four of the six were protected. They were not. The word that
--  matched was "limit", in unrelated SQL. Searching the source for a
--  reassuring word is not a test, and it returned exactly the answer that
--  meant no more work needed doing.
--
--  Looking for `now() - interval`, which is what a time window actually looks
--  like, gave the real picture:
--
--      request_hall_booking          trigger, 5 per phone per 24h    PROTECTED
--      request_charity_collection    trigger, 3 per contact per 24h  036
--      request_nikah_date            nothing                         OPEN
--      submit_admission_application  nothing at all                  OPEN
--      register_for_course           duplicate guard only            OPEN
--      register_foodbank_volunteer   upsert on identity only         OPEN
--
--  The duplicate guards are real and worth having, but they are not rate
--  limits. register_for_course refuses the SAME email on the SAME course;
--  it has nothing to say about the same person registering for a different
--  course, or about a hundred different addresses. register_foodbank_volunteer
--  updates the existing row when it recognises somebody, which at least means
--  a repeat does not fire the INSERT webhook — but a varied identity still
--  inserts every time.
--
--  WHY THIS MATTERS MORE TODAY THAN IT DID YESTERDAY
--  -------------------------------------------------
--  Yesterday a flood was rows in a table. Today, because 035 attached
--  database webhooks to three of these four, every accepted row sends TWO
--  emails through noreply@ on one.com — the SAME MAILBOX that carries nikāḥ
--  requests, hall confirmations, donation receipts and staff invitations.
--  Enough submissions and one.com throttles or suspends it for outbound
--  abuse, and then EVERY transactional email the masjid sends stops at once.
--  It would present as "the website has stopped emailing us" with no obvious
--  cause and no error anywhere.
--
--  Three of these four were opened up by 035, last night, by me. Attaching a
--  notification to a form without asking what that form allows is how a
--  tidiness problem becomes an outage.
--
--  ONE FUNCTION, NOT FOUR
--  ----------------------
--  036 wrote a bespoke limiter, copying the shape of the hall one. Doing that
--  twice more would leave four near-identical functions to keep in step, so
--  this is the generic version: the column names and the ceiling are passed
--  as trigger arguments.
--
--      create trigger ... execute function
--        public.rate_limit_by_contact('<phone col>', '<email col>',
--                                     '<timestamp col>', '<max per 24h>');
--
--  BEFORE INSERT, always. The notify webhooks are AFTER INSERT triggers, so
--  refusing beforehand means the row is never written and the emails are
--  never sent. Refusing afterwards would send them anyway, which is the
--  entire thing being prevented.
--
--  The identifier arguments are passed through quote_ident and the values
--  through USING, so a column name cannot carry SQL into the query.
--
--  hall_bookings and charity_collections keep their own limiters for now.
--  Both work, both are tested, and one of them sits in the middle of a
--  payment flow — swapping them at one in the morning for tidiness would be
--  trading real risk for neatness. They should be migrated onto this function
--  by a human in daylight; nothing breaks if they never are.
--
--  WHAT THIS HONESTLY DOES NOT DO
--  ------------------------------
--  It keys on a phone number and an email address, so it does not stop
--  somebody who varies both. NOTHING AT THIS LAYER CAN — Postgres cannot see
--  an IP address. What it stops is the accidental double submit, the bored
--  person with a form, and the naive script, which between them are every
--  flood this masjid will realistically meet.
--
--  If it is ever not enough the answer is a CAPTCHA or Cloudflare in front of
--  the site, not a smaller number here. Making the ceiling lower would start
--  turning away real families before it inconvenienced anybody determined.
-- ===========================================================================

begin;

create or replace function public.rate_limit_by_contact()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  phone_col text := TG_ARGV[0];
  email_col text := TG_ARGV[1];
  time_col  text := TG_ARGV[2];
  ceiling   int  := TG_ARGV[3]::int;
  v_phone   text;
  v_email   text;
  recent    int;
begin
  --  Read this row's contact details by the column names the trigger was
  --  given. to_jsonb(new) rather than dynamic SQL against NEW, which is not
  --  addressable by a variable name in plpgsql.
  v_phone := btrim(coalesce(to_jsonb(new) ->> phone_col, ''));
  v_email := lower(btrim(coalesce(to_jsonb(new) ->> email_col, '')));

  --  Somebody who gave neither is not rate limited by this, because there is
  --  nothing to key on. Every one of these forms requires at least one of
  --  them, so in practice this cannot happen — but silently counting all the
  --  blanks together would eventually refuse a genuine person for a reason
  --  nobody could work out.
  if v_phone = '' and v_email = '' then
    return new;
  end if;

  execute format(
    'select count(*) from public.%I
      where %I > now() - interval ''24 hours''
        and ( ($1 <> '''' and btrim(%I) = $1)
           or ($2 <> '''' and lower(btrim(%I)) = $2) )',
    TG_TABLE_NAME, time_col, phone_col, email_col)
  into recent
  using v_phone, v_email;

  if recent >= ceiling then
    raise exception
      'We already have enough from you today. If you need to send another, '
      'please ring the masjid on 01204 535 997 and somebody will help.'
      using errcode = 'check_violation';
  end if;

  return new;
end $fn$;

--  The ceilings differ because the forms differ.
--
--  NIKĀḤ, 5. A family may genuinely try two or three dates in an evening
--  before one suits, and being refused while arranging a wedding is the worst
--  possible moment to meet a rate limit. Same number as hall hire.
--
--  ADMISSIONS, 3. A parent applies once, for all their children at once —
--  the form takes several. Three covers a mistyped date of birth and a retry.
--
--  COURSES, 5. There are two courses with two cohorts between them, so a
--  genuine person has at most a handful of legitimate registrations.
--
--  VOLUNTEERS, 3. Offering to help is a thing people do once.

drop trigger if exists nikah_requests_rate_limit_trg on public.nikah_requests;
create trigger nikah_requests_rate_limit_trg
  before insert on public.nikah_requests for each row
  execute function public.rate_limit_by_contact(
    'contact_phone', 'contact_email', 'submitted_at', '5');

drop trigger if exists admission_applications_rate_limit_trg on public.admission_applications;
create trigger admission_applications_rate_limit_trg
  before insert on public.admission_applications for each row
  execute function public.rate_limit_by_contact(
    'mobile', 'email', 'submitted_at', '3');

drop trigger if exists course_registrations_rate_limit_trg on public.course_registrations;
create trigger course_registrations_rate_limit_trg
  before insert on public.course_registrations for each row
  execute function public.rate_limit_by_contact(
    'mobile', 'email', 'submitted_at', '5');

drop trigger if exists foodbank_volunteers_rate_limit_trg on public.foodbank_volunteers;
create trigger foodbank_volunteers_rate_limit_trg
  before insert on public.foodbank_volunteers for each row
  execute function public.rate_limit_by_contact(
    'phone', 'email', 'created_at', '3');

commit;

-- ---------------------------------------------------------------------------
--  PROVING IT, AND THE CONTROL THAT MAKES IT MEAN SOMETHING
--
--  For each table, inside a transaction that rolls itself back: insert ten
--  rows with the SAME contact details and count how many are accepted, then
--  ten with DIFFERENT details and count again. The first number must be the
--  ceiling. THE SECOND MUST BE TEN — a limiter that also refuses genuine,
--  unrelated people is worse than no limiter, because it turns families away
--  silently and nobody finds out.
--
--  Run 15 September 2026:
--      nikah_requests          same 5/10   different 10/10
--      admission_applications  same 3/10   different 10/10
--      course_registrations    same 5/10   different 10/10
--      foodbank_volunteers     same 3/10   different 10/10
--
--  Sequences do not roll back, so every probe burns reference numbers. Reset
--  them afterwards, or the masjid's next genuine request is numbered 0031.
-- ---------------------------------------------------------------------------
