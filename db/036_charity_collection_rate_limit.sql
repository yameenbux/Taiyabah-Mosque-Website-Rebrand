-- ===========================================================================
--  036_charity_collection_rate_limit.sql — the collection form could be
--  flooded, and since 035 that also means flooding the masjid's mailbox
--
--  *** APPLIED TO PRODUCTION 15 September 2026. ***
--
--  Every other public form on this site limits how often one person may use
--  it. hall_bookings does it with a BEFORE INSERT trigger; the nikāḥ, course,
--  volunteer and admission functions each do it inside the function. The
--  charity collection form, added on 14 September, does it NOWHERE.
--
--  Measured, as anon, through the real public entry point:
--
--      8 of 8 accepted from one phone and one email address, in one go.
--
--  THIS GOT WORSE LAST NIGHT, AND I MADE IT WORSE.
--
--  Before 033 a flood was only rows in a table: ugly, easily deleted, and
--  nobody would have noticed for a week. 033 attached a database webhook to
--  this table, so every accepted row now sends TWO emails — one to the office
--  and one to the address on the form.
--
--  So the flood is now an email flood, and not through a service the masjid
--  can rate-limit or turn off independently. It goes through noreply@ on
--  one.com, which is the SAME MAILBOX that sends nikāḥ requests, hall booking
--  confirmations, Gift Aid-bearing donation receipts and staff invitations.
--  A few thousand submissions overnight and one.com throttles or suspends
--  that mailbox for outbound abuse. At that point EVERY transactional email
--  the masjid sends stops, and the failure would look like "the website has
--  stopped emailing us" with no obvious cause.
--
--  Adding a notification to a form without checking whether the form was rate
--  limited turned a tidiness problem into an outage waiting to happen. The
--  lesson is not "add rate limits"; it is that ATTACHING AN AMPLIFIER TO AN
--  INPUT MEANS RE-ASKING WHAT THAT INPUT ALLOWS.
--
--  WHAT THIS CHANGES
--  -----------------
--  A BEFORE INSERT trigger, deliberately in the same shape as
--  hall_bookings_rate_limit so there is one pattern on this database and not
--  two. Three in twenty-four hours, matched on the ORGANISATION'S PHONE OR
--  ITS EMAIL — either one, not both — because a script that varies one field
--  and not the other is the obvious next thing to try.
--
--  WHY THREE AND NOT FIVE. A hall is booked by ordinary people who might
--  genuinely try a few dates in an evening, so five is fair there. A charity
--  asking to collect submits once; the form asks for a trustee who has to be
--  rung, and nobody does that three times by accident. Three leaves room for
--  a mistyped date and a retry, and stops everything else.
--
--  It raises rather than silently dropping the row, because a charity whose
--  submission vanished would ring the office and be told there is no record
--  of it. The message names Rafik Patel, which is the number on the form and
--  on the acknowledgement email, so the three places agree.
--
--  WHAT IT DOES NOT DO. It does not stop a determined attacker with many
--  phone numbers and many email addresses; nothing at this layer can. It
--  stops the accidental double-submit, the bored person with a form, and the
--  naive script, which between them are every flood this masjid will
--  realistically see. If it is ever not enough, the answer is a CAPTCHA or
--  Cloudflare in front of the site, not a smaller number here.
-- ===========================================================================

begin;

create or replace function public.charity_collections_rate_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  recent int;
begin
  --  PHONE **OR** EMAIL. Matching on both together would mean changing one
  --  character of either defeats it entirely.
  select count(*) into recent
    from public.charity_collections
   where submitted_at > now() - interval '24 hours'
     and (btrim(org_phone) = btrim(new.org_phone)
       or lower(btrim(org_email)) = lower(btrim(new.org_email)));

  if recent >= 3 then
    raise exception
      'We already have a collection request from you today. Please ring '
      'Rafik Patel on 07951 795 465 rather than sending another.'
      using errcode = 'check_violation';
  end if;

  return new;
end $fn$;

drop trigger if exists charity_collections_rate_limit_trg on public.charity_collections;

--  BEFORE INSERT, so the row is never written and the notify webhook — which
--  is an AFTER INSERT trigger — never fires. Refusing after the fact would
--  still have sent the emails, which is the whole thing being prevented.
create trigger charity_collections_rate_limit_trg
  before insert on public.charity_collections
  for each row execute function public.charity_collections_rate_limit();

commit;

-- ---------------------------------------------------------------------------
--  PROVING IT
--
--  As anon, through the real public function, inside a transaction that rolls
--  itself back. Before this file: 8 of 8 accepted. After it: 3, then refused.
--
--  do $$
--  declare i int; okc int := 0; r jsonb;
--  begin
--    execute 'set local role anon';
--    for i in 1..8 loop
--      begin
--        select public.request_charity_collection(jsonb_build_object(
--          'requested_date', (current_date + 90 + i)::text,
--          'org_name','Flood Probe','org_address','1 Nowhere Street',
--          'org_phone','07000000000','org_email','flood@example.invalid',
--          'charity_number',null,'collector_name','Probe Collector',
--          'collector_role','volunteer','collector_paid',false,
--          'trustee_name','Trustee Probe','trustee_phone','07000000001',
--          'trustee_email','trustee@example.invalid',
--          'rules_version','2026-09-14','rules_accepted',true,
--          'privacy_accepted',true,'signed_name','Probe Collector')) into r;
--        okc := okc + 1;
--      exception when others then null;
--      end;
--    end loop;
--    execute 'reset role';
--    raise exception 'accepted % of 8', okc;
--  end $$;
--
--  Run 15 September 2026: accepted 3 of 8.
--
--  And the control that makes that number mean something: the same probe with
--  a DIFFERENT phone and email on every call must still accept all 8, or the
--  limit is blocking genuine charities rather than floods.
--  Run 15 September 2026: accepted 8 of 8.
-- ---------------------------------------------------------------------------
