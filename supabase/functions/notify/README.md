# notify — the masjid's transactional email

Sends four things. Nothing else.

| Event | Goes to | Why it matters |
|---|---|---|
| **Deposit paid** | the office | £100 has arrived and a Saturday has been sold. Nobody agreed it — the payment did. This is the only thing that says so. |
| **Deposit paid** | the hirer | Their reference, and confirmation that the date is theirs. |
| **Refund due** | the office | The masjid is holding money it cannot keep. Until now this sat silently in the Refunds tab. |
| **Nikāḥ requested** | the office | Nothing else tells anyone. A family is waiting for a call. |
| **Nikāḥ requested** | the family | Their reference, and a clear "do not pay yet". |
| **Nikāḥ fee paid** | the office | Money arrived. It does **not** agree the date — the email says so. |

**A hall booking that has only been *requested* deliberately sends nothing.**
The date is held for thirty minutes and then lapses; most requests either turn
into a payment within minutes or disappear. Emailing every one would train the
office to ignore the emails, and the one that matters is the payment.

## It sends through one.com, not a third-party service

The masjid already pays for one.com and the sign-in emails already go through
it. Every extra account is another credential, another login and another
paragraph somebody has to keep alive after the person who built this steps
back. For an organisation with no technical staff, fewer moving parts beats
marginally better tooling.

**The cost of that choice, stated plainly:**

1. **This is the less-travelled path.** Supabase's own guide for sending mail
   from an Edge Function uses an HTTPS API, and their documentation says
   nothing either way about SMTP from a function. If it does not work, it will
   fail on the *first* deploy — which is what the selftest below is for.
2. **one.com gives no delivery reporting.** A message accepted by their server
   and then rejected by the recipient is invisible. So every failure this
   function *can* see is written to `admin_audit` as `notification_failed`.
   That is the only feedback there is, and it is why it is there.
3. **The credential is a mailbox password, not a send-only key.** It must be
   the `noreply@` mailbox and nothing else — that mailbox holds no mail, so a
   leak exposes nothing to read.

## What is never in any of these emails

**The hirer's home address.** It is the most sensitive thing on the form and
the least useful for ringing somebody back. Keeping it out means inboxes never
accumulate a store of addresses and a forwarded email cannot leak one. It lives
in the portal, which is where the outcome gets recorded anyway.

There is a test that fails if it ever appears.

---

## Setting it up

### 1. Deploy the function

Two files: `index.ts` and `messages.ts`. The second holds the wording of every
email, kept separate so it can be tested without sending anything.

With the CLI:

```
supabase functions deploy notify --no-verify-jwt
```

From the dashboard: Edge Functions → Deploy a new function → Via Editor. Name
it exactly `notify`, paste `index.ts`, add a second file `messages.ts`, paste
that.

*If the editor will not let you add a second file, say so — the two can be
merged. They are only separate so the wording is testable.*

### 2. Its secrets

Edge Functions → `notify` → Secrets:

| Name | Value |
|---|---|
| `NOTIFY_SECRET` | a long random string you invent — see below |
| `SMTP_HOST` | `send.one.com` |
| `SMTP_PORT` | `465` |
| `SMTP_USER` | `noreply@taiyabahmosque.co.uk` |
| `SMTP_PASS` | that mailbox's password |
| `MAIL_FROM` | `noreply@taiyabahmosque.co.uk` |
| `MAIL_TO` | `office@…, someone-else@…` — comma separated |
| `PORTAL_URL` | `https://www.taiyabahmasjid.com/venue/` |

**Put two people in `MAIL_TO`.** One person alone is a single point of failure
the first time they are on holiday.

For `NOTIFY_SECRET`, run this in the SQL editor and use what it prints:

```sql
select encode(gen_random_bytes(32), 'hex');
```

### 3. PROVE SMTP WORKS, before anything depends on it

This is the step that matters. From a terminal:

```
curl -X POST https://<project>.supabase.co/functions/v1/notify \
  -H "x-notify-secret: <the string from step 2>" \
  -H "content-type: application/json" \
  -d '{"kind":"selftest"}'
```

- `{"ok":true,"note":"sent to office@…"}` — SMTP works. Carry on.
- `{"ok":false,"note":"..."}` — the note is the real SMTP error. Read it.

| Note says | Meaning |
|---|---|
| `Invalid login` / `535` | `SMTP_USER` or `SMTP_PASS` wrong. The user is the **full** address. |
| `connection refused` / `timed out` | Try `SMTP_PORT` `587`. If that also fails, Edge Functions cannot open an SMTP connection — tell Yameen; it needs an HTTPS mail API instead. |
| `no recipient` | `MAIL_TO` is empty |

The selftest only ever sends to `MAIL_TO`, never to an address in the request,
and it needs the secret like everything else.

### 4. Let the Stripe webhook reach it

Edge Functions → `stripe-webhook` → Secrets:

| Name | Value |
|---|---|
| `NOTIFY_URL` | `https://<project>.supabase.co/functions/v1/notify` |
| `NOTIFY_SECRET` | **the same string** as step 2 |

Then redeploy `stripe-webhook` with the updated `index.ts`.

Until both are set the webhook does not call notify — no errors, no emails.
That is deliberate: a half-configured notifier must never stop a payment being
recorded.

### 5. The nikāḥ hook

Supabase → Integrations → **Database Webhooks** → Create a new hook.

- **Name:** `notify-nikah`
- **Table:** `public.nikah_requests`
- **Events:** tick **Insert** only — not update, not delete
- **Type:** HTTP Request → POST
- **URL:** `https://<project>.supabase.co/functions/v1/notify`
- **HTTP Headers:** `x-notify-secret` → the same string again

Insert only. Tick Update and the office gets an email every time somebody edits
a note, which is how people learn to ignore them.

---

## Checking the real thing

**Nikāḥ:** submit a request on the website. The office addresses and the
address on the form should both have an email within seconds.

**The payment ones:** they fire on a real Stripe payment, so they are proved by
the same test that proves the deposit flow — Stripe test mode, card
`4242 4242 4242 4242`, through the booking form so a reference is attached.
That one test covers the webhook, the database and both emails.

Edge Functions → `notify` → **Logs** writes a plain line every time:

| Log line | Meaning |
|---|---|
| `notify: rejected, bad or missing x-notify-secret` | header does not match `NOTIFY_SECRET` |
| `notify: not configured` | `SMTP_USER` or `SMTP_PASS` missing |
| `notify: FAILED deposit_paid HH-… to office — …` | it could not send; also in `admin_audit` |
| `notify: deposit_paid HH-26-0007 — office:sent hirer:sent` | it worked |

Because one.com reports nothing after accepting a message, check this
occasionally:

```sql
select detail, at from public.admin_audit
 where action = 'notification_failed' order by at desc limit 20;
```

Empty is good.

## The tests

```
deno test supabase/functions/notify/messages_test.ts
```

18 assertions, no network. They exist because the previous version of the
booking email went eleven days out of date without anybody noticing — it read
`session_slot`, `hall` and `kitchen`, all retired by migration 014, and would
have emailed the office "Slot: undefined" for every booking.

Negative-controlled: the pre-014 hall wording, the pre-017 "nothing is booked"
footer, the address leaking in, a nikāḥ request described as confirmed, and
dates parsed as UTC — all five reintroduced deliberately, all five caught.

**What the tests do NOT cover:** the SMTP sending itself. That needs a real
server, which is what step 3 is for.
