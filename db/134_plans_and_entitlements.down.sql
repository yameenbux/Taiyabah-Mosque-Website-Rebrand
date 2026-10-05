-- 001 down. Migration 001 is additive, so this restores the database exactly.
-- Order matters: functions first, then the tables they read.
drop function if exists public.set_masjid_feature(text, text, boolean, text);
drop function if exists public.set_masjid_plan(text, text, text, text);
drop function if exists public.masjid_entitlements(uuid);
drop function if exists public.masjid_has(text);
drop function if exists public.masjid_has_for(uuid, text);
drop table if exists public.masjid_feature;
drop table if exists public.masjid_plan;
drop table if exists public.plans;
