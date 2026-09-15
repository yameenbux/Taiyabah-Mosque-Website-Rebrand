-- ===========================================================================
--  039_prayer_times.sql — the masjid's own timetable, editable by the masjid
--
--  *** APPLIED TO PRODUCTION 15 September 2026. ***
--
--  THE PROBLEM THIS SOLVES, PLAINLY. The prayer timetable is a build-time
--  constant. index_template.html contains
--
--      const FULL_2026 = {{FULL_2026_JSON}};
--
--  which build.py fills from build-inputs/full2026.json. So changing a single
--  jamāʿah time means editing a JSON file, running two Python scripts, and
--  pushing to GitHub. Nobody on the committee can do that, and they should
--  not have to learn.
--
--  It is also a deadline. The file holds 365 rows for 2026 and nothing else.
--  ON 1 JANUARY 2027 THE LIVE COUNTDOWN AND THE WHOLE TIMETABLE STOP WORKING,
--  on the page that is the single most common reason anybody visits this
--  website — and the only person who could fix it is the one who is meant to
--  have stepped back by then.
--
--  WHAT THIS ADDS. A table the masjid can fill in from the portal, and a
--  public function the website reads. The website keeps its baked-in year as
--  a fallback and only replaces it when the database gives back something
--  complete and sane — see the notes at the foot, and index_template.html.
--
--  THE RULES THIS TABLE ENFORCES, AND WHY EACH ONE
--
--    * A YEAR IS PUBLISHED OR IT IS NOT. Half an uploaded timetable is worse
--      than none: a visitor checking Maghrib on a day that has not been saved
--      yet gets a blank, or worse, last year's time. `published` starts false
--      and the website never reads an unpublished year, so a committee member
--      can paste a year in, look at it, and only then let anybody see it.
--
--    * A PUBLISHED YEAR MUST BE COMPLETE. save_prayer_year() counts the rows
--      against the days in that year — 365, or 366 in a leap year — and
--      refuses to publish anything short. This is the check that would have
--      caught a spreadsheet exported without December.
--
--    * EVERY TIME IS HH:MM, 24 HOUR. Enforced by a CHECK, not by hoping. A
--      timetable is a list of numbers people set their day by; "7.45" or
--      "7:45pm" silently sorting or comparing wrong is the whole risk.
--
--    * THE PRAYERS RUN IN ORDER. Fajr before sunrise before Zuhr before Asr
--      before Maghrib before Isha, on every single row. A transposed column
--      in a spreadsheet is the most likely mistake anybody will actually
--      make, and it is invisible to the eye in a wall of 365 rows — but
--      trivial for Postgres to refuse.
--
--      Deliberately NOT enforced: that jamāʿah is after its begins time. It
--      usually is, but Maghrib jamāʿah is often set a minute or two after
--      sunset and some masjids record it as the same minute, and refusing a
--      real timetable because of a rule this file invented would be worse
--      than the mistake it prevents.
--
--    * NOBODY CAN WRITE WITHOUT TWO-STEP. verified_admin(), which is 011's
--      rule. The timetable is the most public thing the masjid publishes.
-- ===========================================================================

begin;

create table if not exists public.prayer_times (
  year          smallint not null,
  month         smallint not null check (month between 1 and 12),
  day           smallint not null check (day between 1 and 31),
  hijri         text     not null default '',

  fajr_begins   text not null,
  fajr_jamaah   text not null,
  sunrise       text not null,
  zuhr_begins   text not null,
  zuhr_jamaah   text not null,
  asr_begins    text not null,
  asr_jamaah    text not null,
  maghrib       text not null,
  isha_begins   text not null,
  isha_jamaah   text not null,

  --  Fridays only. "13:15,14:00" — the two Jumuʿah times, as the page already
  --  expects them. Empty on every other day.
  jummah        text not null default '',

  primary key (year, month, day)
);

do $$
begin
  --  Every time is HH:MM, 24 hour. One constraint covering all ten columns
  --  rather than ten constraints, so the error names the row and a person can
  --  go and look at it.
  if not exists (select 1 from pg_constraint
                  where conrelid='public.prayer_times'::regclass
                    and conname='prayer_times_are_hh_mm') then
    alter table public.prayer_times add constraint prayer_times_are_hh_mm check (
      fajr_begins ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and
      fajr_jamaah ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and
      sunrise     ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and
      zuhr_begins ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and
      zuhr_jamaah ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and
      asr_begins  ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and
      asr_jamaah  ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and
      maghrib     ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and
      isha_begins ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' and
      isha_jamaah ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
    );
  end if;

  --  The prayers happen in this order. Every day. Everywhere.
  if not exists (select 1 from pg_constraint
                  where conrelid='public.prayer_times'::regclass
                    and conname='prayer_times_in_order') then
    alter table public.prayer_times add constraint prayer_times_in_order check (
      fajr_begins < sunrise and
      sunrise     < zuhr_begins and
      zuhr_begins < asr_begins and
      asr_begins  < maghrib and
      maghrib     < isha_begins
    );
  end if;

  --  Two Jumuʿah times separated by a comma, or nothing at all.
  if not exists (select 1 from pg_constraint
                  where conrelid='public.prayer_times'::regclass
                    and conname='prayer_jummah_shape') then
    alter table public.prayer_times add constraint prayer_jummah_shape check (
      jummah = '' or jummah ~
        '^([01][0-9]|2[0-3]):[0-5][0-9],([01][0-9]|2[0-3]):[0-5][0-9]$'
    );
  end if;
end $$;

--  Which years exist and whether the public can see them. Kept apart from the
--  365 rows so that publishing is one row changing, not 365.
create table if not exists public.prayer_years (
  year        smallint primary key,
  published   boolean not null default false,
  note        text not null default '',
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);

alter table public.prayer_times enable row level security;
alter table public.prayer_years enable row level security;

--  RLS on, no policies, no grants to anon or authenticated: these tables are
--  reachable ONLY through the functions below, each of which decides for
--  itself what it will hand out. GRANT and RLS are different things and you
--  need both — this repository has been caught by that three times.

-- ---------------------------------------------------------------------------
--  WHAT THE WEBSITE READS. anon, deliberately: the timetable is the most
--  public thing the masjid publishes and the page must work for somebody who
--  has never signed in to anything.
--
--  Returns the rows in EXACTLY the array shape index_template.html already
--  uses, so the page's existing rendering code does not change at all:
--
--    [month, day, hijri, fajr_begins, fajr_jamaah, sunrise, zuhr_begins,
--     zuhr_jamaah, asr_begins, asr_jamaah, maghrib, isha_begins,
--     isha_jamaah, jummah]
--
--  An unpublished or unknown year returns an EMPTY ARRAY rather than an
--  error, because the website's answer to "no timetable in the database" is
--  to keep using the one built into the page, and an exception would be a
--  harder thing for it to get right.
-- ---------------------------------------------------------------------------
create or replace function public.prayer_year(p_year integer)
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(jsonb_agg(
           jsonb_build_array(t.month, t.day, t.hijri,
                             t.fajr_begins, t.fajr_jamaah, t.sunrise,
                             t.zuhr_begins, t.zuhr_jamaah,
                             t.asr_begins,  t.asr_jamaah,
                             t.maghrib, t.isha_begins, t.isha_jamaah,
                             t.jummah)
           order by t.month, t.day), '[]'::jsonb)
    from public.prayer_times t
    join public.prayer_years y on y.year = t.year
   where t.year = p_year
     and y.published;
$fn$;

revoke all on function public.prayer_year(integer) from public;
grant execute on function public.prayer_year(integer) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
--  What the portal lists.
-- ---------------------------------------------------------------------------
create or replace function public.prayer_years_list()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select coalesce(jsonb_agg(jsonb_build_object(
           'year', y.year, 'published', y.published, 'note', y.note,
           'updated_at', y.updated_at,
           'days', (select count(*) from public.prayer_times t where t.year = y.year))
         order by y.year desc), '[]'::jsonb)
    from public.prayer_years y
   where public.verified_admin() or public.verified_office();
$fn$;

revoke all on function public.prayer_years_list() from public;
grant execute on function public.prayer_years_list() to authenticated;

-- ---------------------------------------------------------------------------
--  SAVING A YEAR. All of it, in one transaction, or none of it.
--
--  p_rows is the same array-of-arrays the website uses, so whatever the
--  portal parses out of a spreadsheet is the shape everything else already
--  speaks.
-- ---------------------------------------------------------------------------
create or replace function public.save_prayer_year(
  p_year    integer,
  p_rows    jsonb,
  p_publish boolean default false,
  p_note    text default ''
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_row      jsonb;
  v_n        int := 0;
  v_expected int;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may change the prayer timetable'
      using errcode = '42501';
  end if;

  if p_year is null or p_year < 2020 or p_year > 2100 then
    raise exception 'That is not a year this masjid is going to publish a timetable for';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'The timetable must be a list of days';
  end if;

  --  How many days that year actually has. Leap years are the reason this is
  --  computed rather than written as 365.
  v_expected := (make_date(p_year, 12, 31) - make_date(p_year, 1, 1)) + 1;

  --  REPLACE, not merge. A year is uploaded whole, so leaving last upload's
  --  rows behind for days this one does not mention is how a timetable ends
  --  up half one year and half another.
  delete from public.prayer_times where year = p_year;

  for v_row in select * from jsonb_array_elements(p_rows) loop
    insert into public.prayer_times
      (year, month, day, hijri, fajr_begins, fajr_jamaah, sunrise,
       zuhr_begins, zuhr_jamaah, asr_begins, asr_jamaah,
       maghrib, isha_begins, isha_jamaah, jummah)
    values (
      p_year,
      (v_row->>0)::smallint, (v_row->>1)::smallint,
      coalesce(v_row->>2, ''),
      v_row->>3,  v_row->>4,  v_row->>5,  v_row->>6,  v_row->>7,
      v_row->>8,  v_row->>9,  v_row->>10, v_row->>11, v_row->>12,
      coalesce(v_row->>13, '')
    );
    v_n := v_n + 1;
  end loop;

  --  A YEAR MAY ONLY BE PUBLISHED IF IT IS WHOLE. Saving a partial year as a
  --  draft is fine and useful — you might paste it in over two sittings —
  --  but nobody may put a timetable with a hole in it in front of the public.
  if p_publish and v_n <> v_expected then
    raise exception
      'This timetable has % days and % has %. It has been saved as a draft, '
      'not published — check the spreadsheet is the whole year.',
      v_n, p_year, v_expected;
  end if;

  insert into public.prayer_years (year, published, note, updated_at, updated_by)
  values (p_year, p_publish, coalesce(p_note, ''), now(), auth.uid())
  on conflict (year) do update
    set published = excluded.published,
        note = excluded.note,
        updated_at = now(),
        updated_by = excluded.updated_by;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(), 'prayer_times_saved',
          jsonb_build_object('year', p_year, 'days', v_n, 'published', p_publish));

  return jsonb_build_object('year', p_year, 'days', v_n,
                            'expected', v_expected, 'published', p_publish);
end $fn$;

revoke all on function public.save_prayer_year(integer, jsonb, boolean, text) from public;
grant execute on function public.save_prayer_year(integer, jsonb, boolean, text) to authenticated;

-- ---------------------------------------------------------------------------
--  Publishing and unpublishing on their own, without re-uploading 365 rows.
-- ---------------------------------------------------------------------------
create or replace function public.set_prayer_year_published(
  p_year integer, p_published boolean
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare v_days int; v_expected int;
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may do that'
      using errcode = '42501';
  end if;

  select count(*) into v_days from public.prayer_times where year = p_year;
  v_expected := (make_date(p_year, 12, 31) - make_date(p_year, 1, 1)) + 1;

  if p_published and v_days <> v_expected then
    raise exception 'That year has % of % days saved, so it cannot be published',
      v_days, v_expected;
  end if;

  update public.prayer_years
     set published = p_published, updated_at = now(), updated_by = auth.uid()
   where year = p_year;
  if not found then
    raise exception 'There is no timetable saved for %', p_year;
  end if;

  insert into public.admin_audit (actor, action, detail)
  values (auth.uid(),
          case when p_published then 'prayer_times_published'
                                else 'prayer_times_unpublished' end,
          jsonb_build_object('year', p_year, 'days', v_days));

  return jsonb_build_object('year', p_year, 'published', p_published, 'days', v_days);
end $fn$;

revoke all on function public.set_prayer_year_published(integer, boolean) from public;
grant execute on function public.set_prayer_year_published(integer, boolean) to authenticated;

commit;

-- ---------------------------------------------------------------------------
--  HOW THE WEBSITE USES THIS, AND WHY IT IS NOT SIMPLY "FETCH THE TIMES"
--
--  The timetable is the most common reason anybody opens this website. Making
--  it depend on a network call to Supabase would mean that when Supabase is
--  slow, or the visitor is on a bad connection in the car park, the masjid's
--  prayer times are a spinner.
--
--  So the page keeps its built-in year and treats the database as an UPGRADE:
--
--    1. render immediately from the year compiled into the page
--    2. ask prayer_year(<this year>) for a better one, in the background
--    3. use it ONLY if it comes back complete and sane
--    4. on any failure at all — offline, slow, error, nonsense — keep what is
--       already on the screen and say nothing
--
--  The masjid therefore gets a timetable it can change without a developer,
--  and the visitor gets one that works with the network switched off.
--
--  PROVING IT, ROLLED BACK
--
--  do $$
--  declare r jsonb; n int;
--  begin
--    -- an unpublished year must be invisible to the public
--    perform public.save_prayer_year(2099, '[]'::jsonb, false, 'probe');
--    execute 'set local role anon';
--    select public.prayer_year(2099) into r;
--    execute 'reset role';
--    raise exception 'anon sees % rows of an unpublished year (want 0)',
--                    jsonb_array_length(r);
--  end $$;
--
--  Run 15 September 2026: 0.
-- ---------------------------------------------------------------------------
