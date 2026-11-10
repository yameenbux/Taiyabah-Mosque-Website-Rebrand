# Taking the card machine off MasjidBox

8 November 2026. The masjid's Stripe Terminal card reader has been running
MasjidBox's software — not this masjid's own Stripe account, and not
branded as Taiyabah Masjid to the donor standing at the till. This is what
is left to actually switch it over.

**The database side is already done.** Migrations `151`, `152` and `153`
were applied directly to the live `MasjidOne` Supabase project in this
session — not left for you to run in the SQL editor, which is how this
file would normally read. The copies in `db/` are the record, not a queue;
there is nothing to paste anywhere for those three.

Two `donations_summary()`/`donations_recent()` functions from `152` are
left running, superseded by `donations_summary_v2()`/`donations_recent_v2()`
from `153`, because `DROP FUNCTION` could not be applied in this session —
the confirmation it asked for never reached anyone able to answer it, three
times. If you can click through that confirmation directly in the Supabase
SQL editor, this is safe to run and tidies that up:

```sql
drop function if exists public.donations_summary();
drop function if exists public.donations_recent(integer);
```

Nothing calls them any more once `/giftaid/`'s `app.js` is on the `_v2`
names, which it already is.

---

## Step 1 — enable Terminal on the masjid's own Stripe account

Stripe Dashboard → **Taiyabahmasjid** account → Available Stripe products →
**Terminal** → **Enable**. As of 8 November 2026 this still showed
"Enable", not "Connected" — the clearest sign the reader has been running
under something else's Stripe setup, not this one.

Then Terminal → **Locations** → create one for the masjid.

## Step 2 — register the reader to the masjid's own Location

**Confirmed 8 November 2026, from a photo of the device's own screen: the
masjid's reader is a Stripe Reader S700** — a Wi‑Fi–connected smart reader
with its own screen, found by the Stripe **Location** it is registered to,
not by Bluetooth proximity. `take-payment/config.js` is already set up for
this (`READER_DISCOVERY_METHOD: "internet"`).

1. Copy the Location's id from Step 1 — looks like `tml_…` — into
   `take-payment/config.js` as `TERMINAL_LOCATION_ID`.
2. On the S700 itself: **Settings → About** shows a short registration
   code that refreshes every few minutes.
3. In the Stripe Dashboard: **Terminal → Readers → Register reader** →
   enter that code → pick the Location from Step 1.
4. An S700 is normally registered to one Stripe account at a time, so if
   it is still registered under MasjidBox's account, that registration has
   to be released first. The masjid owns the hardware outright, so this is
   a conversation with MasjidBox about releasing it, not a purchase or a
   lease to end.

If MasjidBox cannot or will not release it, **a new reader is always
available as a fallback** — a Bluetooth model (Stripe Reader M2, BBPOS
WisePad 3), cheaper and with no account-level lock to release, but a
different discovery method: `take-payment/config.js`'s
`READER_DISCOVERY_METHOD` would need changing back to `"bluetoothScan"`,
and `TERMINAL_LOCATION_ID` would no longer apply.

## Step 3 — add one more Stripe webhook event

Stripe Dashboard → Developers → Webhooks → the `stripe-webhook` endpoint →
**Add events** → add **`payment_intent.succeeded`**, alongside
`checkout.session.completed` and `invoice.paid` (the second of those is
`docs/DO-THIS-recurring-donations.md`'s own step — do both if neither is
done yet).

## Step 4 — deploy the updated webhook

```
supabase functions deploy stripe-webhook --no-verify-jwt
```

`supabase/functions/stripe-webhook/index.ts` now also handles
`payment_intent.succeeded`, filtered to `card_present` so a web Checkout
payment's own underlying PaymentIntent is never recorded twice. Read the
file's own header comment before touching it again.

## Step 5 — deploy terminal-worker

```bash
cd terminal-worker
npm install
npx wrangler login
npx wrangler secret put STRIPE_SECRET_KEY   # the account's OWN secret key —
                                             # never a Connect platform key
npm run deploy
```

Wrangler prints the Worker's URL when it deploys. Paste it into
`take-payment/config.js` as `TERMINAL_WORKER_URL`, alongside the
`TERMINAL_LOCATION_ID` from Step 2.

## Step 6 — the first real test

**Nobody has tested any of this against the actual hardware.** Before
trusting it with a donor's money:

1. Sign in to `/take-payment/` as an administrator, on the device that will
   sit at the till.
2. Press **Connect the card reader**. With `"internet"` discovery there is
   no Bluetooth permission prompt — the page finds the S700 by its
   Location instead. If it says no reader was found, check the reader is
   switched on, online, and actually registered to that Location (Step 2).
3. Take one real £1 payment on your own card.
4. Check it landed: Stripe Dashboard shows the charge, and
   `/giftaid/`'s Donations dashboard shows a new "In person" donation
   within a few seconds — not instantly, because the webhook recording it
   is asynchronous (see `take-payment/app.js`'s own header comment for why
   that is deliberate).

If step 4 does not happen, check (in this order): the webhook event was
actually added in Step 3; the deploy in Step 4 succeeded, with no type
errors — this session had no way to type-check `stripe-webhook/index.ts`
itself, so the deploy command's own output is the first real check it has
had; and `admin_audit` for a `subscription_charge_unmatched`-style entry
that would say the payment arrived but could not be matched to anything.

## What this deliberately does not do yet

No fund breakdown prompt beyond the optional dropdown already on
`/take-payment/`, no receipt printed or emailed to the donor, no refund
button anywhere in this flow. All three are real gaps, not forgotten —
just not what was asked for on 8 November 2026.
