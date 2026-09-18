-- ===========================================================================
--  056_the_madrasah_year_the_calendar_and_the_masjids_own_brand.sql
--  18 September 2026
--
--  Four things the masjid asked for, and one of them fixes something that has
--  been quietly wrong since the website was built.
--
--  ---------------------------------------------------------------------------
--  THE CALENDAR IS THE IMPORTANT ONE, AND NOT FOR THE REASON IT LOOKS LIKE
--  ---------------------------------------------------------------------------
--
--  The public Holiday Planner already lists every one of these dates. It lists
--  them because they are TYPED INTO index_template.html, in a JavaScript array,
--  with a comment above it reading:
--
--      "Both lists are edited here, once a year, and nothing else needs
--       touching."
--
--  Edited by whom. Not by the committee — that line means a developer opens a
--  6,600-line template, edits an array, runs the build and pushes. Once a year,
--  every year, forever. The stated goal of this whole project is:
--
--      "it will be the Committee that deal with the website day to day, not
--       me... I want it to be self sufficient where they don't need me as much"
--
--  A hard-coded holiday list is the exact opposite of that. So the dates move
--  into the database, the madrasah amends them from a calendar screen, and the
--  PUBLIC PAGE READS THEM FROM HERE. That is why madrasah_calendar() is the one
--  function in this file that anon may execute.
--
--  NOTHING IS INVENTED. Every closure and every Islamic date below is copied
--  exactly from the array now on the live site — same names, same notes, same
--  dates. If a date here differs from the website today, that is a bug in this
--  file, not a correction.
--
--  ---------------------------------------------------------------------------
--  TWO KINDS OF DATE, AND THEY ARE NOT EQUALLY CERTAIN
--  ---------------------------------------------------------------------------
--
--  CLOSURES are the madrasah's own decisions. They are fixed and they are what
--  a parent books a holiday around.
--
--  ISLAMIC DATES are calculated (Umm al-Qura) and settled by moon sighting, so
--  the real day can land either side. The live page already says so and it is
--  right to. `is_estimated` carries that into the database rather than leaving
--  it as a sentence on one page that a second screen would forget to repeat.
--  A calculated Eid presented as a fact is how a family turns up on the wrong
--  day.
--
--  ---------------------------------------------------------------------------
--  THE BRAND IMAGES, AND WHY THE BUCKET IS PUBLIC
--  ---------------------------------------------------------------------------
--
--  An email banner must be fetchable by the recipient's mail client, which is
--  not signed in to anything and never will be. A private bucket cannot serve
--  one. So `brand` is public to READ and admin-only to WRITE, exactly as the
--  `notices` bucket already is, and nothing goes in it that is not meant to be
--  seen by whoever opens a letter from the masjid.
--
--  Prerequisites: 055 (the enum value, which cannot be added in this
--  transaction). Idempotent.
-- ===========================================================================

begin;

-- ---------------------------------------------------------------------------
--  1. Who may reach the teaching side
--
--     verified_admin() is unchanged and every existing function still asks it.
--     This is an ADDITIONAL, WIDER door for the teaching screens only, and the
--     two-step requirement is the same: a role is not a reason to skip it.
-- ---------------------------------------------------------------------------
create or replace function public.verified_madrasah()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $fn$
  select public.is_aal2()
     and (public.is_admin()
          or public.has_role(auth.uid(), 'madrasah'::public.app_role));
$fn$;

comment on function public.verified_madrasah() is
  'True for an administrator, or for somebody holding the madrasah role, once '
  'two-step is complete. It is the TEACHING side only. Staff records, DBS, '
  'fees and admissions ask verified_admin() and must go on asking it - the '
  'shorter menu a madrasah account sees is a courtesy, not the boundary.';

-- ---------------------------------------------------------------------------
--  2. The academic year
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_years (
  id         uuid primary key default gen_random_uuid(),
  masjid_id  uuid not null references public.masjids(id) on delete cascade,
  label      text not null,
  starts_on  date not null,
  ends_on    date not null,
  is_current boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.madrasah_years drop constraint if exists madrasah_year_runs_forwards;
alter table public.madrasah_years add constraint madrasah_year_runs_forwards
  check (ends_on >= starts_on);

--  ONE CURRENT YEAR, ENFORCED BY THE DATABASE.
--  A screen that says "this year" while two rows claim to be this year is a
--  screen that shows whichever the planner happened to return first.
create unique index if not exists madrasah_one_current_year
  on public.madrasah_years (masjid_id) where is_current;

-- ---------------------------------------------------------------------------
--  3. Closures — the madrasah's own decisions
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_closures (
  id         uuid primary key default gen_random_uuid(),
  masjid_id  uuid not null references public.masjids(id) on delete cascade,
  name       text not null,
  note       text,
  starts_on  date not null,
  ends_on    date not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.madrasah_closures drop constraint if exists madrasah_closure_runs_forwards;
alter table public.madrasah_closures add constraint madrasah_closure_runs_forwards
  check (ends_on >= starts_on);

alter table public.madrasah_closures drop constraint if exists madrasah_closure_has_a_name;
alter table public.madrasah_closures add constraint madrasah_closure_has_a_name
  check (length(btrim(name)) between 1 and 80);

--  A CLOSURE THAT RUNS FOR A DECADE IS A TYPO, NOT A HOLIDAY.
--  The longest real one is the summer break at about six weeks. Anything past
--  a year is somebody keying 2037 for 2027, and it would paint every day of
--  the calendar shut without a word of complaint.
alter table public.madrasah_closures drop constraint if exists madrasah_closure_is_not_a_decade;
alter table public.madrasah_closures add constraint madrasah_closure_is_not_a_decade
  check (ends_on - starts_on <= 366);

-- ---------------------------------------------------------------------------
--  4. Islamic dates — calculated, not decided
-- ---------------------------------------------------------------------------
create table if not exists public.madrasah_events (
  id           uuid primary key default gen_random_uuid(),
  masjid_id    uuid not null references public.masjids(id) on delete cascade,
  name         text not null,
  hijri_label  text,
  on_date      date not null,
  --  DEFAULT TRUE, DELIBERATELY. A date in this table is calculated until
  --  somebody at the masjid says otherwise, because that is the safe way round:
  --  wrongly labelling a confirmed date an estimate costs nothing, and quietly
  --  presenting a calculation as settled is how a family turns up for Eid on
  --  the wrong morning.
  is_estimated boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

alter table public.madrasah_events drop constraint if exists madrasah_event_has_a_name;
alter table public.madrasah_events add constraint madrasah_event_has_a_name
  check (length(btrim(name)) between 1 and 80);

-- ---------------------------------------------------------------------------
--  5. The masjid's own particulars, and its own images
-- ---------------------------------------------------------------------------
create table if not exists public.masjid_profile (
  masjid_id   uuid primary key references public.masjids(id) on delete cascade,
  legal_name  text,
  short_name  text,
  address     text,
  postcode    text,
  phone       text,
  email       text,
  website     text,
  charity_no  text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references auth.users(id)
);

create table if not exists public.masjid_images (
  id           uuid primary key default gen_random_uuid(),
  masjid_id    uuid not null references public.masjids(id) on delete cascade,
  kind         text not null,
  storage_path text not null,
  alt_text     text,
  bytes        integer,
  content_type text,
  is_current   boolean not null default false,
  uploaded_by  uuid references auth.users(id),
  uploaded_at  timestamptz not null default now()
);

alter table public.masjid_images drop constraint if exists masjid_image_kind_known;
alter table public.masjid_images add constraint masjid_image_kind_known
  check (kind in ('logo', 'email_banner', 'letterhead'));

--  ONE CURRENT IMAGE PER KIND. "Set to current" has to mean something, and a
--  second row claiming it turns every letterhead into a coin toss.
create unique index if not exists masjid_one_current_image_per_kind
  on public.masjid_images (masjid_id, kind) where is_current;

-- ---------------------------------------------------------------------------
--  6. Row Level Security. Forced, no policies, reached only through the
--     functions below — the house pattern. GRANT and RLS are different things
--     and both are needed.
-- ---------------------------------------------------------------------------
alter table public.madrasah_years    enable row level security;
alter table public.madrasah_closures enable row level security;
alter table public.madrasah_events   enable row level security;
alter table public.masjid_profile    enable row level security;
alter table public.masjid_images     enable row level security;

alter table public.madrasah_years    force row level security;
alter table public.madrasah_closures force row level security;
alter table public.madrasah_events   force row level security;
alter table public.masjid_profile    force row level security;
alter table public.masjid_images     force row level security;

revoke all on public.madrasah_years    from anon, authenticated;
revoke all on public.madrasah_closures from anon, authenticated;
revoke all on public.madrasah_events   from anon, authenticated;
revoke all on public.masjid_profile    from anon, authenticated;
revoke all on public.masjid_images     from anon, authenticated;

-- ---------------------------------------------------------------------------
--  7. The seed. COPIED, NOT COMPOSED.
--
--     Every row below is the live site's array, transcribed. The `where not
--     exists` on each is what makes running this twice harmless and what stops
--     it quietly reinstating a date the madrasah has since deleted.
-- ---------------------------------------------------------------------------
insert into public.madrasah_years (masjid_id, label, starts_on, ends_on, is_current)
select m.id, '2026/27', date '2026-09-01', date '2027-08-31', true
  from public.masjids m
 where not exists (select 1 from public.madrasah_years y
                    where y.masjid_id = m.id and y.label = '2026/27');

insert into public.madrasah_closures (masjid_id, name, note, starts_on, ends_on)
select m.id, v.name, nullif(v.note, ''), v.from_on, v.to_on
  from public.masjids m
  cross join (values
    ('Insert Day',        'Teachers in — no students', date '2026-09-01', date '2026-09-01'),
    ('Half Term Break',   '',                          date '2026-10-26', date '2026-10-30'),
    ('End of Term Break', 'Christmas and New Year',    date '2026-12-21', date '2027-01-01'),
    ('Ramadhan Holidays', 'Ramadhan and Eid al-Fitr',  date '2027-02-08', date '2027-03-12'),
    ('End of Term Break', '',                          date '2027-03-26', date '2027-04-02'),
    ('Eid al-Adha',       'Eid holidays',              date '2027-05-17', date '2027-05-18'),
    ('Summer Half Term',  '',                          date '2027-05-31', date '2027-06-04'),
    ('End of Year',       'Summer holidays',           date '2027-07-26', date '2027-09-03')
  ) as v(name, note, from_on, to_on)
 where not exists (select 1 from public.madrasah_closures c
                    where c.masjid_id = m.id and c.name = v.name
                      and c.starts_on = v.from_on);

insert into public.madrasah_events (masjid_id, name, hijri_label, on_date, is_estimated)
select m.id, v.name, v.hijri, v.on_date, true
  from public.masjids m
  cross join (values
    ('Mawlid an-Nabi ص',       '12 Rabiʻ al-Awwal', date '2026-08-25'),
    ('Laylat al-Miʻraj',       '27 Rajab',          date '2027-01-05'),
    ('Laylat al-Baraʼah',      '15 Shaʼban',        date '2027-01-23'),
    ('Ramadhan begins',        '1 Ramadhan',        date '2027-02-08'),
    ('Last ten nights begin',  '21 Ramadhan',       date '2027-02-28'),
    ('Eid al-Fitr',            '1 Shawwal',         date '2027-03-09'),
    ('Day of Arafah',          '9 Dhul Hijjah',     date '2027-05-15'),
    ('Eid al-Adha',            '10 Dhul Hijjah',    date '2027-05-16'),
    ('Islamic New Year',       '1 Muharram 1449',   date '2027-06-06'),
    ('Day of ʿAshura',         '10 Muharram',       date '2027-06-15')
  ) as v(name, hijri, on_date)
 where not exists (select 1 from public.madrasah_events e
                    where e.masjid_id = m.id and e.name = v.name
                      and e.on_date = v.on_date);

commit;
