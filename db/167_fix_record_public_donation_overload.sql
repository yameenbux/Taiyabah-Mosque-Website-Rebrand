-- 167 — unbreak online donations.
--
-- record_public_donation had three overloads: a 7-arg convenience wrapper, an
-- 8-arg implementation, and a 9-arg superset that adds stripe_subscription_id
-- and source='online' (p_subscription_id defaults NULL). The Stripe webhook
-- calls it BY NAME with 8 arguments; PostgREST then saw BOTH the 8-arg and the
-- 9-arg as candidates and refused to choose (PGRST203 "Could not choose the
-- best candidate function"), so the webhook returned HTTP 500 and the donation
-- was never recorded — even though Stripe had already taken the money. This had
-- broken every online donation since the 9-arg overload was added (the last one
-- that recorded was 8 Nov 2026).
--
-- Drop the superseded 8-arg implementation. The 9-arg version serves a one-off
-- donation identically (subscription NULL, source 'online'), and the 7-arg
-- wrapper's internal 8-argument call now resolves to it unambiguously.
drop function if exists public.record_public_donation(
  p_masjid text, p_session_id text, p_amount_p integer, p_purpose text,
  p_gift_aid boolean, p_name text, p_address text, p_postcode text);
