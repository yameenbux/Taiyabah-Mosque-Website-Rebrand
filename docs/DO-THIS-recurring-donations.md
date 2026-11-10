# Fixing recurring donations, and the new Donations dashboard

8 November 2026. One Stripe Dashboard setting, one edge function deploy, two
migrations already applied.

**The bug this fixes:** "Monthly" and "Friday Pay" on the donate page are
Stripe subscriptions. Stripe only ever told this website about the *first*
charge on one — every renewal after that left no row in `donations` and no
row in `admin_audit`, because nothing was listening for the event Stripe
sends for a renewal. The masjid has been collecting standing gifts that this
database never saw past their first month.

---

## Step 1 — the database

**Already done in this session**, against the live `MasjidOne` Supabase
project:

- `db/151_donations_belong_to_a_masjid.sql` — a no-op reconciliation. The
  `donations` table and its three functions had drifted from what's in this
  folder (masjid_id was added live, never committed — see the file's own
  header). Nothing changes; it only lets this folder rebuild them.
- `db/152_recurring_donations_and_a_dashboard.sql` — the real change.
  `frequency`, `stripe_subscription_id` and `stripe_invoice_id` columns,
  `record_subscription_frequency()`, `record_subscription_charge()`, and the
  four dashboard functions (`donations_summary`, `donations_daily`,
  `donations_by_purpose`, `donations_recent`).

If you are reading this because you are setting up a **fresh** copy of this
database, run both files, in that order, in the Supabase SQL editor, same as
every other migration here.

## Step 2 — one Stripe Dashboard setting

Stripe → Developers → Webhooks → the `stripe-webhook` endpoint → **Add
events** → add **`invoice.paid`** alongside the `checkout.session.completed`
it already sends.

Nothing else changes about the endpoint — same URL, same signing secret.

## Step 3 — deploy the updated webhook

```
supabase functions deploy stripe-webhook --no-verify-jwt
```

`supabase/functions/stripe-webhook/index.ts` now handles `invoice.paid` as
well as `checkout.session.completed`. Read the comment at the top of that
file before touching it again — it explains why the second event exists and
what each of the two `billing_reason`s on it means.

**This session could not type-check the file before handing it to you.**
There is no `deno` binary and no network access to fetch the Stripe/Supabase
types from `esm.sh` in this sandbox. The deploy command above will type-check
it for real — read its output before trusting the deploy succeeded, and if
it fails, that is this file's bug to fix, not a reason to deploy with
`--no-verify-jwt` and hope.

## Step 4 — watch it work

The next time somebody's standing gift renews (or sign up a test subscription
on a low amount and wait for the second charge, if you want to see it sooner
than a month), check:

- Stripe → that subscription → it should show a second paid invoice.
- Supabase → `donations` table → a new row with `stripe_invoice_id` set,
  `stripe_subscription_id` matching the first row's, and the same `purpose`
  and `gift_aid` as the first row (inherited, not re-asked).
- `/giftaid/` on the website, signed in as an administrator → the new
  **Donations** dashboard at the top of the page should count it.

If a renewal invoice arrives for a subscription this database has no sign-up
row for, it is **not** silently recorded as a donation — it is written to
`admin_audit` as `subscription_charge_unmatched` instead, because the
masjid's Stripe account is shared with iBeams and nothing proves a stray
subscription is one of ours. Check `admin_audit` if a number on the dashboard
ever looks short of what Stripe shows.

## What the dashboard deliberately does not claim

There is no "active subscriptions" count, because knowing a subscription is
*active* means knowing it has not been cancelled, and this webhook is not
subscribed to `customer.subscription.deleted`. The dashboard instead reports
donors charged in the last 40 days — read as "recently giving", not
"currently committed". If the masjid wants a true active/cancelled count
later, that is a third Stripe event to add, and a genuinely separate piece of
work from this one.
