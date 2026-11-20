-- The email-OTP login matches a member by the email on their record. Add a
-- normalised, indexed email so the match is exact (not a LIKE that treats "_"
-- in an address as a wildcard) and case/space insensitive.
alter table public.masjid_members
  add column if not exists email_norm text
  generated always as (nullif(lower(btrim(email)), '')) stored;
create index if not exists masjid_members_email_norm_idx
  on public.masjid_members (masjid_id, email_norm);

-- The login edge function (service_role) computes a member's balance through the
-- one calculator, membership_state. It was revoked from the API roles; grant it
-- (and current_year) to service_role only — server-side, never the browser key.
grant execute on function public.membership_state(uuid) to service_role;
grant execute on function public.membership_current_year(uuid) to service_role;
