-- ===========================================================================
--  156 — the daily log says WHAT changed, not just that something did
--
--  Taiyabah Masjid · 12 November 2026
--
--  WHAT WENT WRONG. "Site Content Changed," "Course Page Changed," "Course
--  Edited," "Notice Unpublished" — every one of these already carries the
--  specific thing that changed in admin_audit.detail: set_site_content()
--  (db/150) writes 'key' naming which page; save_course_page() (db/047)
--  writes the course's 'key'; save_course() (db/044) writes the course's
--  real 'name'; set_notice_published() (db/040) and publish_notice()
--  (db/050) both write the notice's 'title'. None of it reaches the
--  screen: audit_sentence(action, detail) (db/031) takes detail as an
--  argument and then, for every action without its own named case,
--  throws it away — `replace(initcap(replace(p_action,'_',' ')),...)`
--  reads p_action alone. The office could see THAT the website changed,
--  never WHAT.
--
--  THE FIX IS THE FALLBACK ITSELF, NOT ONE CASE PER ACTION. Naming every
--  action that might someday carry a title/name/key would drift the
--  moment a new one is added and nobody remembers to list it here — the
--  exact failure this file is fixing. The fallback now looks at
--  p_detail for 'title', then 'name', then 'key' (the order a human
--  reads as most specific) and appends whichever is there, so a FUTURE
--  action that writes any of those three needs no change here at all.
--
--  SITE_CONTENT_CHANGED GETS ITS OWN LINE ANYWAY, because its 'key' is a
--  database slug (newbuild/hallhire/ramadan) and "Site Content Changed -
--  ramadan" reads worse than naming the page in English. Every other
--  touched action already writes a human-readable name or slug and needs
--  no translation.
-- ===========================================================================

begin;

create or replace function public.audit_sentence(p_action text, p_detail jsonb)
returns text
language sql
immutable
as $$
  select case p_action
    when 'hall_booking_requested'  then 'Hall booking came in'
    when 'nikah_request'           then 'Nikah date requested'
    when 'charity_collection_request'
                                   then 'Charity collection requested'
    when 'charity_collection_status'
                                   then 'Collection marked ' ||
                                        coalesce(p_detail->>'status', 'updated')
    when 'charity_collections_purged'
                                   then 'Old collection requests deleted'
    when 'course_registration'     then 'Someone signed up for a class'
    when 'donation_paid'           then 'Donation received'
    when 'volunteer_status'        then 'Volunteer marked ' ||
                                        coalesce(p_detail->>'status', 'updated')
    when 'gift_aid_claimed'        then 'Gift Aid claim marked filed' ||
                                        coalesce(' - ' || (p_detail->>'count') || ' donations', '')
    when 'cash_deposit_recorded'   then 'Deposit taken in cash'
    when 'booking_cancelled'       then 'Booking cancelled and refunded'
    when 'hall_holds_purged'       then 'Expired holds cleared'
    when 'donations_purged'        then 'Old donation records deleted'
    when 'volunteers_purged'       then 'Old volunteer records deleted'
    when 'hall_confirmed_without_payment_repaired'
                                   then 'A booking with no deposit was put back'
    --  SITE_CONTENT_CHANGED: 'key' is a slug, not a title — name the page.
    when 'site_content_changed'    then 'Site content changed - ' ||
                                        case p_detail->>'key'
                                          when 'newbuild' then 'the new building appeal page'
                                          when 'hallhire' then 'the hall hire rates page'
                                          when 'ramadan'  then 'the Ramadan countdown page'
                                          else coalesce(p_detail->>'key', 'a page')
                                        end
    --  EVERYTHING ELSE: title-case the action, then say what it was about
    --  if detail says — 'title' (a notice), 'name' (a course), 'key'
    --  (anything else that names itself), in that order. Nothing to add
    --  falls back to exactly the old bare sentence.
    else replace(initcap(replace(p_action, '_', ' ')), ' Id', ' ID') ||
         coalesce(' - ' || nullif(btrim(coalesce(
                     p_detail->>'title', p_detail->>'name', p_detail->>'key', '')), ''),
                   '')
  end
$$;

commit;
