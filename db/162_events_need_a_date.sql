-- 162 — an event post has to say when the event is.
--
-- WHY. The app's Notices tab becomes an Events page: a month calendar on top
-- with a dot on every day that has something on, and the posters underneath
-- in date order. All of that is keyed on notices.event_at.
--
-- The column has existed since the table was made by hand, and admin.html has
-- always had a field for it. Nobody has ever filled it in: at the time of
-- writing all four notices have event_at null, including the three tagged
-- 'events' that carry posters. A calendar built on that renders empty, and —
-- worse — a post the office believed it had advertised would simply not be
-- on it, with nothing anywhere to say so.
--
-- So the rule goes where it can fail. Prose in a composer is a request; a
-- CHECK is a promise.
--
-- NOT VALID, DELIBERATELY. The three existing event posters have no date and
-- the masjid may not remember them. NOT VALID grandfathers exactly those rows
-- and still checks every INSERT, and every UPDATE that touches them — so the
-- moment somebody edits one of those posters they will be asked for the date,
-- which is the right time to ask. Run
--
--     alter table public.notices validate constraint event_posts_need_a_date;
--
-- once the office has dated the backlog. Until then the Events screen groups
-- undated posters under "Date to be confirmed" rather than hiding them.
--
-- WHAT IS STILL UNDATED, as applied on 13 November 2026. Three rows carry
-- topic='events' with no event_at, and none of them is published, so none
-- reaches a phone:
--   * two test posts, titled "... - TEST" and "Test";
--   * "Nurturing Our Hearts and Homes", a ladies' programme EVERY THURSDAY.
-- The last one is the interesting case and the reason VALIDATE is not run
-- here: a weekly programme has no single event_at, and giving it one would
-- put it on the calendar once and be wrong every other week. A recurring
-- event needs a shape this table does not have. Dating it to silence the
-- constraint would be the wrong fix.
--
-- The one published event, the Marriage Masterclass, was dated from its own
-- body and poster — both say "Sunday, 22 November 2026, 11:00 AM".
--
-- The topic vocabulary is the one the masjid already uses and the one the
-- notification switches already name: jamaah, janazah, announcements, events,
-- kahf. Only 'events' reaches the calendar, so only 'events' is constrained.
--
-- APPLIED to production on 13 November 2026.

begin;

alter table public.notices
  drop constraint if exists event_posts_need_a_date;

alter table public.notices
  add constraint event_posts_need_a_date
  check (topic <> 'events' or event_at is not null)
  not valid;

comment on column public.notices.event_at is
  'When the event happens. Required for topic=''events'' (constraint '
  'event_posts_need_a_date, NOT VALID so pre-2026-11 posters are '
  'grandfathered). It is what the Events calendar plots and what the poster '
  'list sorts by; null on a notice that is not an event.';

commit;
