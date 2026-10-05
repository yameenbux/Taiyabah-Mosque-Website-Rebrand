-- 002 down. Functions only — 002 creates no tables and alters no data.
-- Masajid created while it was applied are left exactly as they are: this
-- removes the tooling, never a customer.
drop function if exists public.masjid_take_offline(text, text);
drop function if exists public.masjid_go_live(text, boolean);
drop function if exists public.masjid_setup_checklist(text);
drop function if exists public.create_masjid(jsonb);
