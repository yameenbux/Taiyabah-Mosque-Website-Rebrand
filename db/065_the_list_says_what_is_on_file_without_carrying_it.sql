-- ===========================================================================
--  065_the_list_says_what_is_on_file_without_carrying_it.sql
--  18 September 2026
--
--  Asked for: "you can showcase little icons on the teachers each specific
--  section to show what the teacher has available of them. Then whoever wants
--  to can click on a teacher record and view their info in more details."
--
--  The obvious way to build that is to return the address, the date of birth
--  and the working hours on every row and let the browser decide whether to
--  draw a tick. That is the wrong way round, and it is worth being exact about
--  why rather than filing it under good practice.
--
--  THE ROW NEEDS A YES OR A NO. IT DOES NOT NEED THE ANSWER.
--
--  A 24-pixel square with the letter A in it carries one bit. Sending forty
--  home addresses and forty dates of birth to draw forty of those bits means
--  every one of those addresses has left the database, crossed the network and
--  is sitting in the browser's memory on whatever machine the office is using,
--  in the page source, in the browser's cache, and in any screenshot anybody
--  takes of the list. None of it is displayed. The screen is no better for it
--  and the exposure is total.
--
--  So this migration adds six computed columns to madrasah_staff_list() and no
--  values at all:
--
--      has_address   has_dob   has_phone   has_email   has_hours   days_a_week
--
--  days_a_week is a count of the keys in work_times, not the times: it lets a
--  row say "5 days a week" without carrying 17:00-19:30 five times over.
--
--  The values continue to come from madrasah_staff_one(p_id) in 062, which is
--  called when somebody opens ONE person, returns ONE record, and is the only
--  path by which an address reaches a screen. That split is the whole reason
--  the icons are icons.
--
--  ---------------------------------------------------------------------------
--  WHY THE WHOLE FUNCTION IS PRINTED BELOW
--  ---------------------------------------------------------------------------
--  053 rebuilt this function and wrote "see the migration history for the full
--  text" instead of the text. What it actually did was drop masjid_id out of
--  the insert, and because there was no function body in the file there was no
--  diff for anybody to read. Every save on the staff screen failed for a day.
--  A migration that rebuilds a function PRINTS the function. This one is
--  therefore 052 + 053 + 054's list function with six lines added, in full,
--  pulled back out of the database with pg_get_functiondef after it was
--  applied so that what is in this file is what is actually running.
--
--  Safe to re-run.
-- ===========================================================================

create or replace function public.madrasah_staff_list()
returns jsonb language plpgsql stable security definer
set search_path = public, pg_temp
as $fn$
declare
  v_masjid uuid := public.current_masjid();
begin
  if not public.verified_admin() then
    raise exception 'Only an administrator who has completed two-step may see the madrasah staff.'
      using errcode = '42501';
  end if;

  if v_masjid is null then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.sort_last, x.sort_first)
      from (
        select s.id, s.honorific, s.first_name, s.last_name, s.side,
               btrim(concat_ws(' ', s.honorific, s.first_name, s.last_name)) as display_name,
               s.employment, s.started_on, s.left_on, s.work_days,
               s.dbs_issued, s.dbs_update_service, s.dbs_last_checked,
               s.dbs_not_required,
               public.dbs_state(s.dbs_issued, s.dbs_update_service,
                                s.dbs_last_checked, s.dbs_not_required) as dbs,
               s.prior_dbs,
               --  email and phone ARE values and they are here on purpose: the
               --  editor opens from this list and has to put what is already
               --  held back in its boxes. They are also the two fields whose
               --  whole reason for being recorded is that somebody rings or
               --  writes to this person. An address and a date of birth are
               --  not that, which is why they are not here.
               s.email, s.phone, s.note,

               --  WHAT IS ON FILE, AS FLAGS AND NOT AS VALUES.
               --
               --  The masjid asked for "little icons on the teachers to show
               --  what the teacher has available of them". The list needs to
               --  know whether there IS an address; it does not need forty
               --  people's addresses to draw forty ticks.
               --
               --  That is the whole of data minimisation in one decision: the
               --  screen that shows a list gets booleans, and the screen that
               --  shows ONE PERSON gets the values, through
               --  madrasah_staff_one(). A list that carries what it does not
               --  display is a list that leaks what it does not display.
               (coalesce(btrim(s.address), '') <> '')            as has_address,
               (s.date_of_birth is not null)                     as has_dob,
               (coalesce(btrim(s.phone), '') <> ''
                or coalesce(btrim(s.phone_alt), '') <> '')       as has_phone,
               (coalesce(btrim(s.email), '') <> '')              as has_email,
               (s.work_times is not null
                and s.work_times <> '{}'::jsonb)                 as has_hours,
               --  How many days a week, so the row can say "5 days" without
               --  carrying the times themselves.
               (select count(*) from jsonb_object_keys(
                  coalesce(s.work_times, '{}'::jsonb)))          as days_a_week,

               coalesce((
                 select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name)
                                  order by c.sort_order, c.name)
                   from public.madrasah_staff_classes sc
                   join public.madrasah_classes c
                     on c.id = sc.class_id and c.masjid_id = v_masjid
                  where sc.staff_id = s.id
                    and sc.masjid_id = v_masjid), '[]'::jsonb) as classes,

               lower(coalesce(nullif(btrim(s.last_name), ''), s.first_name)) as sort_last,
               lower(s.first_name) as sort_first
          from public.madrasah_staff s
         where s.masjid_id = v_masjid
      ) x
  ), '[]'::jsonb);
end $fn$;

revoke all on function public.madrasah_staff_list() from public, anon;
grant execute on function public.madrasah_staff_list() to authenticated;


-- ===========================================================================
--  CHECKS
--
--  Each one was proved by deliberately breaking the thing it guards and
--  watching it fail. A check that cannot fail is worse than no check, because
--  it is read as evidence.
-- ===========================================================================
do $check$
declare
  v_def text := pg_get_functiondef('public.madrasah_staff_list()'::regprocedure);
  v_sel text;
  v_bad text;
begin
  --  1. The six flags are returned. Broken by deleting the has_address line:
  --     fails with the name of the flag that went.
  foreach v_bad in array array['has_address','has_dob','has_phone','has_email',
                               'has_hours','days_a_week']
  loop
    if position(v_bad in v_def) = 0 then
      raise exception '065: madrasah_staff_list() does not return %, so the marks on the staff rows have nothing to read.', v_bad;
    end if;
  end loop;

  --  2. AND THE VALUES BEHIND THEM ARE NOT RETURNED.
  --
  --     The naive form of this check is `position('s.address' in v_def) = 0`,
  --     which is a check that CANNOT FAIL: the flag is built out of the column,
  --     so that text is in the function whatever it returns. What separates a
  --     returned column from a column merely being read is that the returned
  --     one stands alone on its line of the select list. Broken by adding
  --     `s.address,` to the select: fails naming it. Left as it is: passes.
  v_sel := substring(v_def from 'select s\.id,(.*?)from public\.madrasah_staff s');
  select string_agg(ln, ', ') into v_bad
    from (select btrim(l) as ln from regexp_split_to_table(coalesce(v_sel,''), E'\n') l) t
   where ln ~ '^s\.(address|date_of_birth|work_times|phone_alt)\s*(,|$)';
  if v_bad is not null then
    raise exception '065: madrasah_staff_list() returns % as a column. Forty rows would carry it to the browser to draw a 24-pixel square; the flags exist so that an address leaves the database only when one person is opened.', v_bad;
  end if;

  --  3. Still scoped to one masjid. This is what 053 lost.
  if position('s.masjid_id = v_masjid' in v_def) = 0
     or position('current_masjid()' in v_def) = 0 then
    raise exception '065: madrasah_staff_list() is no longer scoped to a masjid.';
  end if;

  --  4. And madrasah_staff_one() is still the one that holds the values, so
  --     that the split this migration depends on is not quietly undone at the
  --     other end. Broken by dropping the function: fails.
  if to_regprocedure('public.madrasah_staff_one(uuid)') is null then
    raise exception '065: madrasah_staff_one() is missing, so nothing returns the values the marks point at.';
  end if;

  raise notice '065 ok: the staff list returns six flags and no address.';
end $check$;

