# Terminal service

The Cloudflare Worker that `/take-payment/` talks to. It is the only place
the Stripe **secret** key for Terminal exists — never shipped to the browser,
never added to Supabase (see `CLAUDE.md`: "the Stripe secret key stays local
and must not be added to Supabase" — Supabase already holds the webhook's
*signing* secret, which can only verify, not spend; this key can create
charges, so it gets a separate home with nothing else in it).

```
terminal-worker/
├── src/index.js     /connection_token and /create_payment_intent
├── wrangler.toml     Worker config (no secrets in here)
└── package.json
```

## Why this exists, and why it is small on purpose

Taking a payment on a Stripe Terminal card reader needs two things only a
server can do, because both need the secret key:

1. **Issue a connection token** — the one-time credential the reader SDK
   uses to connect to a physical reader. Minted fresh per connection.
2. **Create the PaymentIntent** — `amount`, `currency: "gbp"`,
   `payment_method_types: ["card_present"]`. The browser never sees the
   secret key; it only ever gets back the PaymentIntent's `client_secret`,
   which can start a payment but cannot read or create anything else.

Everything else — discovering the reader over Bluetooth, collecting the
payment method, showing the masjid's own branding while it happens — runs
entirely in `/take-payment/`'s own JavaScript, using Stripe's Terminal JS
SDK. This Worker never sees a card number, a reader's Bluetooth traffic, or
anything about the donor.

## Who may call it

Neither endpoint is public. Every request must carry
`Authorization: Bearer <the caller's Supabase access token>` — the same
token `/take-payment/`'s own sign-in already holds once somebody is signed
in there. This Worker does not keep its own idea of who is an administrator：
it asks Supabase, with that same token, to run `verified_admin()` — the
**exact function** every other admin screen in this repository already
depends on (two-step completed, `admin` role). One rule, one place, same as
`admin/shell.js` is the one place the staff rail is defined. A second,
Worker-only copy of "who counts as an administrator" is exactly the kind of
drift `CLAUDE.md` describes happening to `donations` three times over.

`SUPABASE_URL` and `SUPABASE_ANON_KEY` are **not secrets** — they are the
same two values already shipped to every browser in `admin/supabase.js`, so
they are plain `[vars]` in `wrangler.toml`, not `wrangler secret`.

## Deploy

Requires a [Cloudflare account](https://dash.cloudflare.com/sign-up) (the
free tier is enough) and a Stripe **secret** key with Terminal access —
Stripe Dashboard → Developers → API keys. **Use the account's own secret
key, never a Connect platform key, and never the test key for the live
reader.**

```bash
cd terminal-worker
npm install
npx wrangler login

npx wrangler secret put STRIPE_SECRET_KEY
```

Then deploy:

```bash
npm run deploy
```

## Before the masjid's own reader works

**The reader is a Stripe Reader S700** — confirmed 8 November 2026 from a
photo of its own screen showing Stripe's stock checkout UI, which only an
internet-connected smart reader displays. It is Wi‑Fi connected and found
by the Stripe **Location** it is registered to, not by Bluetooth proximity
— and that screen (the amount, the tap icon) is Stripe's own firmware
drawing it; nothing this Worker or `/take-payment/` does can rebrand it.
`/take-payment/` is the thing that IS branded — the staff-facing screen
that tells the reader what to charge.

1. Stripe Dashboard → that account → **enable Terminal** (Available
   products → Terminal → Enable). It showed as not-yet-enabled on
   Taiyabahmasjid's own account on 8 November 2026 — the reader has been
   running under something else's Stripe setup, not this one.
2. Create a **Location** for the masjid (Stripe Dashboard → Terminal →
   Locations) and copy its id (`tml_…`) into `/take-payment/`'s
   `config.js` as `TERMINAL_LOCATION_ID`.
3. **Register the reader to that Location.** On the S700 itself: Settings →
   About → the registration code (a short word pair, refreshes every few
   minutes). In the Stripe Dashboard: Terminal → Readers → **Register
   reader** → enter that code and pick the Location from step 2. An S700
   is normally registered to one Stripe account at a time, so if it is
   still registered under MasjidBox's account, that registration has to be
   released first — the masjid owns the hardware outright, so this is a
   conversation with MasjidBox about releasing it, not a purchase or a
   lease to end.
4. `/take-payment/` needs `TERMINAL_WORKER_URL` in its own `config.js`
   pointed at this Worker's deployed URL, alongside the Location id from
   step 2.

**Nobody in this project has tested this against the real reader yet.** The
code here follows Stripe's own documented Terminal integration precisely,
but "follows the docs" is not "known to work" — run a real £1 test payment
on the actual hardware before trusting it with a donor's.

## What this deliberately does not do

No refund endpoint, no capture-later flow (`capture_method` is `automatic`
— a card-present tap is a single, completed action, the same way the
donate page's own Checkout Sessions are). A fund, if the till screen offers
one, rides on the PaymentIntent's `metadata.purpose` exactly the way the
online donate page rides it on `client_reference_id` — read back by
stripe-webhook, never guessed at by this Worker.
