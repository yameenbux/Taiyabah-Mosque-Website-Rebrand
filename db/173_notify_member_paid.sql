-- 173 — email the member a receipt when a membership payment is recorded.
--
-- WHY. A member paid their fee — by card in the app, or at the counter where the
-- office enters it — and was told nothing by email. The hall deposit and the
-- nikah fee both send a receipt through notify(); membership was the one payment
-- that did not, because the Stripe webhook deliberately skips it (its shape did
-- not fit notify's booking-centric events). This closes that gap for ALL payment
-- methods by hanging a trigger on membership_payments itself, not on Stripe.
--
-- WHAT IT SENDS. A membership_paid event to the office-notify webhook, which the
-- notify function renders as the member's own receipt: their name, the year, the
-- amount of this payment, whether the year is now paid in full, and the MF
-- reference — everything they need to keep for their record. No office copy: the
-- office already sees every payment in the members screen.
--
-- WHAT IT DOES NOT. Legacy backfill rows (method = 'legacy') never email — they
-- are history, not a payment taken today. A member with no email on record gets
-- no email, and the office still sees the payment in the portal.
--
-- Applied to production directly on 2026-11-20 (Supabase migration
-- notify_member_paid); this file is the record. The notify edge function must be
-- redeployed with the matching messages.ts membership_paid template.

create or replace function public.notify_member_paid()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public', 'pg_temp'
as $function$
declare
  v_name text; v_email text; v_ref int;
  v_url text; v_key text; v_secret text;
  v_charge int; v_paid int; v_outstanding int; v_reference text;
begin
  if NEW.method = 'legacy' then
    return NEW;   -- a backfill of history, not a payment taken today
  end if;

  select full_name, email_norm, ref_no
    into v_name, v_email, v_ref
    from public.masjid_members where id = NEW.member_id;

  if coalesce(btrim(v_email), '') = '' then
    return NEW;   -- no email to send to; the office sees it in the portal
  end if;

  select value into v_url    from public.app_settings where masjid_id = NEW.masjid_id and key = 'notify_url';
  select value into v_key    from public.app_settings where masjid_id = NEW.masjid_id and key = 'notify_key';
  select value into v_secret from public.app_settings where masjid_id = NEW.masjid_id and key = 'notify_secret';

  if v_url is null or v_key is null or v_secret is null then
    insert into public.admin_audit (masjid_id, action, detail)
    values (NEW.masjid_id, 'notify_not_configured',
            jsonb_build_object('table', 'membership_payments'));
    return NEW;
  end if;

  select coalesce(net_p, 0) into v_charge
    from public.membership_years where member_id = NEW.member_id and year = NEW.year;
  select coalesce(sum(amount_p), 0) into v_paid
    from public.membership_payments where member_id = NEW.member_id and year = NEW.year;
  v_outstanding := greatest(0, coalesce(v_charge, 0) - coalesce(v_paid, 0));

  v_reference := 'MF-' || lpad((NEW.year % 100)::text, 2, '0') || '-' || lpad(coalesce(v_ref, 0)::text, 4, '0');

  perform net.http_post(
    url := v_url,
    body := jsonb_build_object(
      'kind',          'membership_paid',
      'reference',     v_reference,
      'name',          v_name,
      'email',         v_email,
      'year',          NEW.year,
      'amount_p',      NEW.amount_p,
      'paid_in_full',  (v_outstanding = 0),
      'outstanding_p', v_outstanding),
    headers := jsonb_build_object(
      'Content-type',    'application/json',
      'Authorization',   'Bearer ' || v_key,
      'x-notify-secret', v_secret));

  return NEW;
end $function$;

drop trigger if exists notify_member_paid_trg on public.membership_payments;
create trigger notify_member_paid_trg
  after insert on public.membership_payments
  for each row execute function public.notify_member_paid();
