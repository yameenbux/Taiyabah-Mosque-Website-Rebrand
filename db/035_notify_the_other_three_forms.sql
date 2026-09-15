-- ===========================================================================
--  035_notify_the_other_three_forms.sql — madrasah admissions, course
--  registrations and foodbank volunteers had no notification either
--
--  *** APPLIED TO PRODUCTION 15 September 2026. ***
--
--  033 fixed the charity collection form, which wrote a row and told nobody.
--  This file exists because the obvious next question was not asked in 033:
--  HOW MANY OTHER FORMS DO THAT?
--
--  The answer was three.
--
--      submit_admission_application  -> admission_applications  -> nobody
--      register_for_course           -> course_registrations    -> nobody
--      register_foodbank_volunteer   -> foodbank_volunteers     -> nobody
--
--  All three are callable by anon, all three are live on the website, and all
--  three collect an email address they never used. A parent could apply for a
--  madrasah place and hear nothing, from anybody, ever. The office would not
--  know an application existed unless somebody happened to open the portal.
--
--  The query that found it, worth keeping, because the next form added to
--  this site will have the same gap unless somebody runs it again:
--
--      select p.proname, <the table it writes>,
--             coalesce((select string_agg(t.tgname,', ') from pg_trigger t
--                        where t.tgrelid = <that table>::regclass
--                          and not t.tgisinternal
--                          and t.tgname ilike 'notify%'), 'NOBODY IS TOLD')
--        from pg_proc p ... where <p is granted to anon>;
--
--  WHAT THIS CHANGES
--  -----------------
--  Three more database webhooks, each created the same way as 033: by copying
--  the notify-nikah trigger inside the database and substituting the name and
--  the table, so the service_role JWT and the NOTIFY_SECRET inside its header
--  argument are never written to a file or shown to anybody.
--
--  And one grant. notify turns a course KEY into the course's NAME, because
--  "Your place is booked - arabic" is not something to send to a person.
--  service_role bypasses RLS but had no SELECT on public.courses, and
--
--      GRANT AND RLS ARE DIFFERENT THINGS AND YOU NEED BOTH.
--
--  That sentence has been in this repository since 002 and this is the THIRD
--  time it has cost something: 032 for admin_audit and its sequence, and now
--  this. The lookup is written to fall back to the raw key if it fails, so
--  the email goes either way — but it would have gone out ugly and nobody
--  would have known why.
--
--  WHAT THE EMAILS DELIBERATELY DO NOT CONTAIN
--  -------------------------------------------
--  MADRASAH: anything at all about a child. The application carries every
--  child's name, date of birth, gender, school, SEND status, EHCP, allergies
--  and medical conditions. Most of that is special category data under
--  Article 9 of the UK GDPR and the rest belongs to a child who has consented
--  to nothing. None of it goes to a mail provider, into a shared inbox, or
--  into a forwarded email. The office email says an application arrived, who
--  the parent is and how to ring them. The children are in the portal.
--  The home address is out too, for the same reason it is out of a hall
--  booking.
--
--  COURSES: whatever the learner typed into `experience` and `notes`. It is
--  free text and can contain anything a person decides to disclose.
--
--  VOLUNTEERS: age, gender and `skills`. The rota is planned in the portal.
--
--  THE ONE THING THAT MUST NOT GO WRONG
--  ------------------------------------
--  course_registrations.outcome is 'place' or 'waiting', decided by the
--  database against the course's capacity. The confirmation email says which,
--  in the subject line and again in the body, and the two versions share as
--  little wording as possible. Somebody told nothing — or told the wrong
--  thing — turns up on the first night to a full room and is sent home in
--  front of everybody.
--
--  PREREQUISITE: the notify-nikah trigger, and a deployed notify that knows
--  the three new kinds. DEPLOY THE FUNCTION FIRST. A trigger firing at a
--  function that does not recognise the table is harmless — it answers
--  "nothing to send for this" — but it is a silent nothing, which is the
--  failure this whole file is about.
-- ===========================================================================

begin;

-- notify reads this to turn 'arabic' into 'Arabic Classes'.
-- service_role bypasses RLS; that is not a grant. Both are needed.
grant select on public.courses to service_role;

do $$
declare
  def  text;
  tbl  text;
  tabs text[] := array['admission_applications',
                       'course_registrations',
                       'foodbank_volunteers'];
  nm   text;
begin
  select pg_get_triggerdef(oid) into def
    from pg_trigger
   where tgname  = 'notify-nikah'
     and tgrelid = 'public.nikah_requests'::regclass;

  if def is null then
    raise exception
      'notify-nikah does not exist on nikah_requests, so there is nothing to '
      'copy. Create the nikah database webhook first.';
  end if;

  foreach tbl in array tabs loop
    nm := 'notify-' || replace(tbl, '_', '-');

    -- Idempotent. Re-running this file after a secret rotation should copy
    -- the new header across, not fail half way and leave two of three done.
    execute format('drop trigger if exists %I on public.%I', nm, tbl);

    execute replace(
              replace(def, 'notify-nikah', nm),
              'public.nikah_requests', 'public.' || tbl);
  end loop;
end $$;

commit;

-- ---------------------------------------------------------------------------
--  PROVING IT, WITHOUT EMAILING ANYBODY
--
--  Same rolled-back probe as 033, once per table: insert a row, count what
--  pg_net queued, then raise so the whole transaction is undone. No row, no
--  reference consumed, no email. Expected delta is 1 for each.
--
--  Run 15 September 2026:
--      admission_applications  delta=1
--      course_registrations    delta=1
--      foodbank_volunteers     delta=1
--
--  And the negative control that makes those numbers mean something: the same
--  probe against a table with no notify trigger (site_content) gives delta=0.
-- ---------------------------------------------------------------------------
