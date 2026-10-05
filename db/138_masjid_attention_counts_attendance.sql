-- 138 — masjid_attention() counts attendance without a column that is not there
--
-- THE BUG. The support console's "what needs attention" panel showed only
--
--     Could not read what needs attention: column a.register_id does not exist
--
-- and none of its twenty figures. The attendance count joined
-- madrasah_attendance to madrasah_registers on a.register_id. That column has
-- never existed: madrasah_attendance carries masjid_id itself, so the join was
-- both wrong and unnecessary. A join that is not needed is a join that can be
-- wrong.
--
-- WHY THIS FILE EXISTS AT ALL, which is the more useful part.
-- masjid_attention() had NO DEFINITION ANYWHERE IN db/. It was created straight
-- against the live database and never written down, so the bug could not be
-- found by reading this repository, only by clicking the console.
--
-- It is not alone. Checked on 5 October 2026, these functions run in production
-- and are defined in no file here:
--
--     sole_masjid            masjid_id_for        masjid_or_sole
--     is_platform_admin      my_masjids           set_current_masjid
--     notices_live           hall_availability    masjid_attention
--
-- That is the whole multi-tenancy and support-console layer — the functions
-- that decide which masjid a caller may see and whether a visit is recorded as
-- supplier access. The same failure as the stripe-webhook that ran three days
-- ahead of git, and with higher stakes: nobody can review what nobody can read.
--
-- This file brings one of the nine under version control. The other eight
-- should follow, captured from pg_get_functiondef() and committed as they are
-- rather than rewritten from memory.

create or replace function public.masjid_attention(p_masjid text)
returns jsonb
language plpgsql stable security definer
set search_path to 'public', 'pg_temp'
as $$
declare
  v_masjid uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'Not a platform administrator.' using errcode = '42501';
  end if;

  v_masjid := public.masjid_id_for(p_masjid);

  return jsonb_build_object(
    'slug', p_masjid,
    'as_of', now(),

    -- The madrasah: what is on the roll, and whether any of it has been used.
    'pupils',        (select count(*) from madrasah_pupils      where masjid_id = v_masjid),
    'classes',       (select count(*) from madrasah_classes     where masjid_id = v_masjid),
    'staff',         (select count(*) from madrasah_staff       where masjid_id = v_masjid),
    'households',    (select count(*) from madrasah_households  where masjid_id = v_masjid),
    'registers',     (select count(*) from madrasah_registers   where masjid_id = v_masjid),
    /* madrasah_attendance carries masjid_id itself — see the header. */
    'attendance',    (select count(*) from madrasah_attendance  where masjid_id = v_masjid),
    'charges',       (select count(*) from madrasah_charges     where masjid_id = v_masjid),
    'payments',      (select count(*) from madrasah_payments    where masjid_id = v_masjid),
    'progress',      (select count(*) from madrasah_progress    where masjid_id = v_masjid),
    'concerns',      (select count(*) from madrasah_concerns    where masjid_id = v_masjid),
    'parent_logins', (select count(*) from madrasah_parent_logins where masjid_id = v_masjid),

    -- The congregation: what the public actually sees.
    'notices_written',   (select count(*) from notices where masjid_id = v_masjid),
    'notices_published', (select count(*) from notices where masjid_id = v_masjid and published),
    'prayer_years_published',
      (select count(*) from prayer_years where masjid_id = v_masjid and published),
    'prayer_days_this_year',
      (select count(*) from prayer_times
        where masjid_id = v_masjid and year = extract(year from current_date)::int),
    'courses',        (select count(*) from courses where masjid_id = v_masjid),
    'course_signups', (select count(*) from course_registrations where masjid_id = v_masjid),
    'admissions_waiting',
      (select count(*) from admission_applications
        where masjid_id = v_masjid and coalesce(status,'') not in ('placed','declined','withdrawn')),
    'brand_images',   (select count(*) from masjid_images where masjid_id = v_masjid and is_current),

    -- Composed by a person, NOT the automated prayer pushes.
    'admin_pushes',   (select count(*) from app_notifications where masjid_id = v_masjid)
  );
end $$;

-- APPLIED to production 5 October 2026. Verified by running the formerly
-- failing subquery: Taiyabah reads 553 pupils, 0 registers, 0 attendance.
