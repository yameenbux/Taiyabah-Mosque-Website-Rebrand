// ===========================================================================
//  stripe-webhook — records a payment made to the masjid
//
//  Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
//
//  ONE ENDPOINT, TWO KINDS OF PAYMENT
//  ----------------------------------
//  Which one is decided by the reference prefix the payment carries:
//
//      HH-26-0001  a hall hire deposit    -> mark_deposit_paid()
//      NK-26-0001  a nikāḥ fee            -> mark_nikah_fee_paid()
//
//  One endpoint rather than two because Stripe signs every delivery with the
//  same endpoint secret; a second function would need its own secret, its own
//  deployment and its own chance to be forgotten when something changes here.
//  The prefix comes from the database's own reference sequences, so it cannot
//  drift out of step with the tables.
//
//  The two are NOT the same transaction, and the difference is deliberate:
//
//    - Paying a hall deposit CONFIRMS the booking. The site knows what is
//      free, so it can sell a date outright (migration 017).
//    - Paying a nikāḥ fee confirms NOTHING. The masjid does not publish its
//      nikāḥ diary, so the site cannot know whether a date is available. The
//      office agrees the date on the phone; this is only a way to pay the fee
//      without coming in with cash (migration 018).
//
//  If you are tempted to unify them, read the header of 018 first.
//
//  Stripe tells us a deposit has been paid. This is the ONLY thing that may
//  say so: a browser claiming "I have paid" is not evidence of anything, which
//  is why mark_deposit_paid() has EXECUTE revoked from anon and authenticated
//  and is reached here with the service role key.
//
//  Two rules that are easy to get wrong and expensive to get wrong:
//
//    1. VERIFY THE SIGNATURE FIRST. Anything else — reading the body, looking
//       up the reference, being helpful — happens after. Without it, anybody
//       who finds this URL can mark any booking paid by posting some JSON.
//       The signature is checked with constructEventAsync, because Deno has no
//       synchronous crypto and the sync version silently fails here.
//
//    2. ALWAYS RETURN 200 ONCE THE SIGNATURE IS GOOD. Stripe retries a
//       non-2xx for days. Retrying cannot fix an unknown reference or a date
//       somebody else has taken, and a retry storm buries the real problem.
//       Those cases are recorded in admin_audit and answered 200.
//
//  Deploy:
//      supabase functions deploy stripe-webhook --no-verify-jwt
//
//  --no-verify-jwt is REQUIRED. Stripe does not send a Supabase JWT, so with
//  verification on every delivery is rejected before this file ever runs. The
//  Stripe signature is what authenticates the caller here.
//
//  Secrets — and none of them is the Stripe API key:
//      STRIPE_WEBHOOK_SECRET       whsec_… — the LIVE endpoint in Stripe
//      STRIPE_WEBHOOK_SECRET_TEST  whsec_… — optional, a test-mode endpoint
//
//  Two, because test mode and live mode sign with different secrets and a
//  function that only knows one of them cannot be tested without breaking the
//  other. Each delivery is checked against whichever secrets are set. The test
//  one can be removed once you have finished testing; nothing depends on it.
//      SUPABASE_URL               provided by the platform
//      SUPABASE_SERVICE_ROLE_KEY  provided by the platform
//
//  There is deliberately no STRIPE_SECRET_KEY here. Verifying a webhook
//  signature is a local HMAC of the raw body against the WEBHOOK secret; it
//  makes no call to Stripe and never touches an API key. Storing sk_live_
//  anyway would put the masjid's most dangerous credential — one that can
//  issue refunds, read every customer and create charges — into a system that
//  has no use for it. A leaked whsec_ lets somebody forge events into this
//  one function, which is bad; a leaked sk_live_ is a different order of
//  problem. Do not add one "just in case".
//
//  In Stripe, add an endpoint pointing at this function and subscribe it to
//  `checkout.session.completed` and nothing else.
// ===========================================================================

import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// The empty key is not an oversight. This client is only ever used for
// stripe.webhooks.constructEventAsync(), which verifies an HMAC locally and
// makes no request to Stripe — verified against stripe@14.21.0, where an
// empty key verifies a good signature and still rejects a forged one.
const stripe = new Stripe("", {
  apiVersion: "2024-06-20",
  httpClient: Stripe.createFetchHttpClient(),
});

const SECRETS = [
  Deno.env.get("STRIPE_WEBHOOK_SECRET"),
  Deno.env.get("STRIPE_WEBHOOK_SECRET_TEST"),
].filter((s): s is string => !!s && s.length > 0);

const db = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false } },
);

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const signature = req.headers.get("stripe-signature");
  if (!signature || SECRETS.length === 0) {
    // 400, not 200: this genuinely is a bad request, and Stripe should be
    // told rather than have us pretend we handled it.
    console.error("stripe-webhook: no signature, or no webhook secret is set");
    return new Response("Bad request", { status: 400 });
  }

  // The RAW body. Reading it as JSON first and re-serialising changes the
  // bytes and the signature will not match — a mistake that produces a
  // baffling "no signatures found" and hours of looking in the wrong place.
  const raw = await req.text();

  // Tried against each secret in turn. A delivery signed by EITHER the live or
  // the test endpoint is genuine; one signed by neither is not.
  let event: Stripe.Event | null = null;
  let lastError = "";
  for (const secret of SECRETS) {
    try {
      event = await stripe.webhooks.constructEventAsync(raw, signature, secret);
      break;
    } catch (err) {
      lastError = (err as Error).message;
    }
  }
  if (!event) {
    console.error("stripe-webhook: signature rejected —", lastError);
    return new Response("Bad signature", { status: 400 });
  }

  // Signed and genuine from here on. Everything below answers 200.
  if (event.type !== "checkout.session.completed") {
    return new Response(JSON.stringify({ ignored: event.type }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  const session = event.data.object as Stripe.Checkout.Session;
  const reference = session.client_reference_id;
  const sessionId = session.id;
  const amount = session.amount_total ?? null;

  if (session.payment_status !== "paid") {
    // A completed session that is not paid — a delayed method, say. Not an
    // error, and not a deposit either.
    console.log(`stripe-webhook: ${sessionId} completed but payment_status=${session.payment_status}`);
    return new Response(JSON.stringify({ ok: true, note: "not paid" }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  if (!reference) {
    // Somebody paid the link without going through the booking form, so there
    // is no booking to attach it to. Real money, so it is logged rather than
    // shrugged off — the office has to find them and refund it.
    console.error(`stripe-webhook: ${sessionId} arrived with no client_reference_id`);
    await db.from("admin_audit").insert({
      action: "payment_without_reference",
      detail: { session: sessionId, amount_pence: amount,
                email: session.customer_details?.email ?? null },
    });
    return new Response(JSON.stringify({ ok: true, note: "no reference" }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  // Which kind of payment is this? Decided by the prefix and nothing else —
  // not by the amount (a hall deposit and a member's nikāḥ fee are both £100),
  // and not by which payment link was used (the masjid can add links without
  // this file knowing).
  const KINDS: Record<string, { rpc: string; state: string; what: string }> = {
    "HH-": { rpc: "mark_deposit_paid",   state: "deposit_status", what: "hall deposit" },
    "NK-": { rpc: "mark_nikah_fee_paid", state: "fee_status",     what: "nikāḥ fee" },
  };
  const kind = KINDS[reference.slice(0, 3).toUpperCase()];

  if (!kind) {
    // A reference in a shape nothing here recognises. Money has still been
    // taken, so this is audited rather than ignored — but it is not retried,
    // because retrying will not teach this function a new prefix.
    console.error(`stripe-webhook: ${sessionId} has an unrecognised reference "${reference}"`);
    await db.from("admin_audit").insert({
      action: "payment_with_unknown_reference_kind",
      detail: { session: sessionId, reference, amount_pence: amount,
                email: session.customer_details?.email ?? null },
    });
    return new Response(JSON.stringify({ ok: true, note: "unknown reference kind" }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  const { data, error } = await db.rpc(kind.rpc, {
    p_reference: reference,
    p_session_id: sessionId,
    p_amount_p: amount,
  });

  if (error) {
    // The database refused. 500 so Stripe retries, because unlike an unknown
    // reference this one might genuinely be transient.
    console.error(`stripe-webhook: ${kind.rpc} failed for ${reference} —`, error.message);
    return new Response("Could not record the payment", { status: 500 });
  }

  console.log(`stripe-webhook: ${kind.what} ${reference} -> ${data?.[kind.state]}` +
              (data?.already_recorded ? " (already recorded)" : "") +
              (data?.duplicate_payment ? " (DUPLICATE — needs refunding)" : ""));

  // Tell somebody. Until now a paid deposit sold a Saturday and nothing said
  // so until a human opened the portal; a refund owed sat in a tab nobody was
  // watching. This is the only moment either of those is known.
  //
  // A retry that recorded nothing sends nothing, or the office gets the same
  // booking emailed to them every time Stripe retries.
  if (!data?.already_recorded) {
    await notify(reference, kind, data, session);
  }

  return new Response(JSON.stringify({ ok: true, result: data }), {
    status: 200, headers: { "content-type": "application/json" },
  });
});

/* ---------------------------------------------------------------------------
   Handing off to the notify function.

   Deliberately best-effort. The payment is already recorded in the database by
   the time this runs, and that is the part that matters — if the email fails,
   the booking is still correct and the portal still shows it. Throwing here
   would make Stripe retry a payment that was recorded perfectly well.
   --------------------------------------------------------------------------- */
async function notify(
  reference: string,
  kind: { rpc: string; state: string; what: string },
  data: Record<string, unknown> | null,
  session: Stripe.Checkout.Session,
) {
  const url    = Deno.env.get("NOTIFY_URL") ?? "";
  const secret = Deno.env.get("NOTIFY_SECRET") ?? "";
  if (!url || !secret) return;                      // not wired up yet

  const state = String(data?.[kind.state] ?? "");
  const hall  = kind.rpc === "mark_deposit_paid";

  // What actually happened decides what gets sent. 'refund_due' and a
  // duplicate payment both mean the masjid is holding money it cannot keep.
  let payload: Record<string, unknown> | null = null;

  if (state === "paid") {
    payload = {
      kind: hall ? "deposit_paid" : "nikah_fee_paid",
      reference,
      amount_p: session.amount_total ?? null,
      // Stripe collected this at checkout. The hall booking form does not ask
      // for an email, so this is the only address the masjid has for a hirer —
      // and it belongs to the person who just paid. It is passed straight
      // through to send one confirmation and is not stored anywhere.
      email: hall ? (session.customer_details?.email ?? null) : null,
      name: session.customer_details?.name ?? null,
    };
  } else if (state === "refund_due" || data?.duplicate_payment) {
    payload = {
      kind: "refund_due",
      reference,
      amount_p: session.amount_total ?? null,
      reason: data?.duplicate_payment
        ? "Paid twice — the first payment is the one on file"
        : "Paid for a date the masjid cannot give them",
    };
  } else if (state === "unmatched") {
    payload = {
      kind: "refund_due",
      reference,
      amount_p: session.amount_total ?? null,
      reason: "Paid against a reference that does not exist",
    };
  }

  if (!payload) return;

  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "content-type": "application/json", "x-notify-secret": secret },
      body: JSON.stringify(payload),
    });
    if (!res.ok) console.error(`notify returned ${res.status} for ${reference}`);
  } catch (err) {
    console.error(`notify unreachable for ${reference} —`, (err as Error).message);
  }
}
