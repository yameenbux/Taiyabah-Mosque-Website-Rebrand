-- 171 — sole_masjid() counts only LIVE masjids.
--
-- WHY. The multi-masjid migration made sole_masjid() refuse when the masjids
-- table holds more than one row, so that a caller which does not name its masjid
-- fails loudly rather than guessing. Correct in principle — but the table also
-- holds two dormant audit/test rows (slugs audit-tmp-a, audit-tmp-b, is_live =
-- false, no data of their own). Those two rows pushed the count past one, so
-- EVERY caller that does not pass a slug hit:
--
--   "This system now runs more than one masjid, so this call has to say which."
--
-- That is the whole of masjid_or_sole(null): request_hall_booking,
-- request_nikah_date, request_imam_advice, request_charity_collection and
-- request_itikaf_place all go through it, and every older app build in a
-- congregant's hands predates the change that made the app name its masjid
-- (native commit 992aafd). So on those builds every one of those forms failed
-- with a bare "That didn't send", and had done since the autumn — the hall
-- bookings table took its last row on 7 September.
--
-- The fix is not to weaken the guard but to point it at what actually matters:
-- there is exactly one LIVE masjid (taiyabah), and the dormant test rows are not
-- it. Counting only is_live rows makes a missing slug resolve to the single live
-- masjid, and still refuses the moment a SECOND live masjid is added — which is
-- the real condition the guard exists for. Deleting the test rows was the
-- alternative and was rejected: they own ~8,930 admin_audit rows and a
-- madrasah_staff row, so removing them would cascade into audit history and a
-- staff record.
--
-- Applied to production directly on 2026-11-20 (Supabase migration
-- sole_masjid_counts_only_live); this file is the record.

create or replace function public.sole_masjid()
 returns uuid
 language plpgsql
 stable security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare v_id uuid; v_n int;
begin
  select count(*) into v_n from public.masjids where is_live;
  if v_n = 0 then
    raise exception 'No live masjid has been set up yet.' using errcode = '22023';
  end if;
  if v_n > 1 then
    raise exception 'This system now runs more than one masjid, so this call has to say which. Update the caller to pass a masjid slug.'
      using errcode = '22023';
  end if;
  select id into v_id from public.masjids where is_live;
  return v_id;
end $function$;
