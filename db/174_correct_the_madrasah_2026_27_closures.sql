-- ---------------------------------------------------------------------------
--  174. Correct three 2026/27 madrasah closures to the official Key Dates sheet
--
--  The madrasah's printed "Key Dates 2026/27" sheet is the authority, and three
--  of the closures seeded in db/056 no longer match it. The office reads these
--  through portal/calendar (the madrasah_calendar RPC), so a stale row there is
--  a date a teacher plans around that the sheet on the wall contradicts.
--
--    - Ramadhan Holidays now end 14 Mar 2027, not 12 Mar.
--    - End of Year now ends 6 Sep 2027, not 3 Sep (the new year opens Tue 7 Sep).
--    - A Staff Training day is added, Mon 4 Jan 2027 — teachers in, no students,
--      the same shape as the Insert Day already in the list.
--
--  The same three corrections were made to the public holiday-planner arrays in
--  index_template.html in the same change; this keeps the office's own copy in
--  step with them. Scoped to the one masjid by slug, not by a hardcoded id, and
--  idempotent so re-running it changes nothing a second time.
-- ---------------------------------------------------------------------------
do $$
declare mid uuid;
begin
  select id into mid from public.masjids where slug = 'taiyabah';
  if mid is null then
    raise notice 'taiyabah masjid not found — nothing changed';
    return;
  end if;

  update public.madrasah_closures
     set ends_on = date '2027-03-14', updated_at = now()
   where masjid_id = mid and name = 'Ramadhan Holidays'
     and starts_on = date '2027-02-08' and ends_on = date '2027-03-12';

  update public.madrasah_closures
     set ends_on = date '2027-09-06', updated_at = now()
   where masjid_id = mid and name = 'End of Year'
     and starts_on = date '2027-07-26' and ends_on = date '2027-09-03';

  insert into public.madrasah_closures (masjid_id, name, note, starts_on, ends_on)
  select mid, 'Staff Training', 'Teachers in — no students',
         date '2027-01-04', date '2027-01-04'
  where not exists (
    select 1 from public.madrasah_closures
     where masjid_id = mid and name = 'Staff Training'
       and starts_on = date '2027-01-04'
  );
end $$;
