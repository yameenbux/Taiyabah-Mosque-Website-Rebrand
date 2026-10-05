// ===========================================================================
//  stripe-webhook — records a payment made to the masjid
//  Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
//
//  ONE ENDPOINT, THREE KINDS OF PAYMENT, decided by client_reference_id:
//      HH-26-0001   hall hire deposit -> mark_deposit_paid()
//      NK-26-0001   nikāḥ fee         -> mark_nikah_fee_paid()
//      DN-…         a donation with a reference already made
//      general|sadaqah|lillah|newbuild
//                   a donation from the DONATE PAGE -> record_public_donation()
//
//  THE LAST ONE IS WHY THE MASJID'S FIRST REAL PAYMENT WENT MISSING. The
//  donate page sends the PURPOSE as client_reference_id, because a Stripe
//  Payment Link cannot carry anything else in its URL. But this function was
//  already routing on the first three characters of that same field, so
//  "sadaqah" matched nothing and no donation was recorded. A purpose has no
//  prefix and never will, so it is checked BEFORE the prefix table. The
//  reference is minted by the DATABASE — donations.reference is UNIQUE, so a
//  fixed "DN-sadaqah" would collide on the second one. See db/032.
//
//  Rules that are easy to get wrong and expensive to get wrong:
//    1. VERIFY THE SIGNATURE FIRST. Without it, anybody who finds this URL
//       can mark any booking paid by posting some JSON. constructEventAsync,
//       because Deno has no synchronous crypto and the sync version silently
//       fails here.
//    2. ALWAYS RETURN 200 ONCE THE SIGNATURE IS GOOD. Stripe retries a non-2xx
//       for days; a retry storm buries the real problem.
//    3. AND THE AUDIT WRITE HAS TO ACTUALLY WORK. Until 032 service_role held
//       no INSERT on admin_audit and no USAGE on its sequence, so every "money
//       arrived that I cannot match" row was silently discarded.
//
//  RULE 3 BROKE A SECOND TIME, AND NOBODY FOUND OUT FOR A FORTNIGHT.
//  admin_audit gained masjid_id NOT NULL with no default. This function was
//  still inserting into that table directly, with no masjid_id, so every
//  safety-net row failed with 23502 from 17 September 2026 — and because the
//  result of that insert was never checked, the failure was thrown away and
//  Stripe was told 200. On 2 October alone, FORTY-TWO paid checkout sessions
//  arrived with no reference and left no trace in the masjid's systems.
//
//  Two things changed as a result, and both matter more than the fix itself:
//    * Audit rows are written through record_unmatched_payment(), a function
//      that owns the masjid_id question. A webhook that writes to a TABLE
//      inherits every future change to that table's shape; one that calls a
//      function does not.
//    * EVERY audit write is now checked and shouts if it fails. An unchecked
//      write is not a safety net. It is a safety net with a hole in it that
//      nobody can see, which is worse than none, because people trust it.
//
//  Deploy:  supabase functions deploy stripe-webhook --no-verify-jwt
//  --no-verify-jwt is REQUIRED: Stripe does not send a Supabase JWT.
//
//  Secrets — none is the Stripe API key:
//      STRIPE_WEBHOOK_SECRET / STRIPE_WEBHOOK_SECRET_TEST  whsec_…
//      SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (from the platform)
//  Verifying a signature is a local HMAC and never calls Stripe. Do not add
//  an sk_live_ "just in case": it can issue refunds and read every customer.
//
//  In Stripe, subscribe the endpoint to `checkout.session.completed` only.
// ===========================================================================

import { readGiftAid, donorDetails } from "./giftaid.ts";
import Stripe from "https://esm.sh/stripe@14.21.0?target=deno";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

// The empty key is not an oversight. This client is only ever used for
// constructEventAsync(), which verifies an HMAC locally and makes no request
// to Stripe — verified against stripe@14.21.0, where an empty key verifies a
// good signature and still rejects a forged one.
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

// The donate page's own vocabulary. Kept here rather than inferred, so that a
// stray client_reference_id cannot talk this function into creating donations
// out of somebody else's payment.
const PURPOSES = ["general", "sadaqah", "lillah", "newbuild"];

/* The safety net, and the only way money that cannot be matched is ever seen
   by a human. It goes through a function because admin_audit has a masjid_id
   this webhook has no way to know, and it is CHECKED because the previous
   version was not: an insert that fails silently reads exactly like one that
   worked, which is how forty-two payments went unrecorded for a fortnight
   while this endpoint answered 200 to every one of them. */
async function auditPayment(action: string, detail: Record<string, unknown>) {
  const { error } = await db.rpc("record_unmatched_payment", {
    p_action: action,
    p_detail: detail,
  });
  if (error) {
    // Nothing else can be done from here — Stripe must still get its 200 or
    // it will retry for days — but this must never be silent again.
    console.error(
      `stripe-webhook: COULD NOT AUDIT "${action}" — money has arrived that ` +
      `nothing has recorded. ${error.message}`,
    );
    return false;
  }
  return true;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const signature = req.headers.get("stripe-signature");
  if (!signature || SECRETS.length === 0) {
    console.error("stripe-webhook: no signature, or no webhook secret is set");
    return new Response("Bad request", { status: 400 });
  }

  // The RAW body. Reading it as JSON first and re-serialising changes the
  // bytes and the signature will not match.
  const raw = await req.text();

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
    console.log(`stripe-webhook: ${sessionId} completed but payment_status=${session.payment_status}`);
    return new Response(JSON.stringify({ ok: true, note: "not paid" }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  if (!reference) {
    // Somebody paid a link without going through the form that sets the
    // reference — typically by opening a Payment Link URL directly. Real
    // money, so it is logged rather than shrugged off.
    console.error(`stripe-webhook: ${sessionId} arrived with no client_reference_id`);
    const audited = await auditPayment("payment_without_reference", {
      session: sessionId,
      amount_pence: amount,
      payment_link: (session.payment_link as string) ?? null,
      email: session.customer_details?.email ?? null,
    });
    return new Response(JSON.stringify({ ok: true, note: "no reference", audited }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  // ---------------------------------------------------------------------
  //  A DONATION FROM THE DONATE PAGE. Checked before the prefix table
  //  because a purpose has no prefix.
  // ---------------------------------------------------------------------
  const purpose = reference.trim().toLowerCase();
  if (PURPOSES.includes(purpose)) {
    const ga = readGiftAid(session.custom_fields as never);
    const who = donorDetails(ga.giftAid, session.customer_details?.name,
                             session.customer_details?.address);

    console.log(`stripe-webhook: donation (${purpose}) gift aid = ${ga.giftAid} ` +
                `(matched by ${ga.matchedBy}, answer "${ga.answer}")`);

    // A donation link with no Gift Aid question on it records every donation
    // as "no" with no error anywhere — 25p in every eligible pound quietly
    // not claimed. The only way anybody finds out is if something says so.
    if (ga.fieldMissing) {
      console.error(`stripe-webhook: a ${purpose} donation had NO Gift Aid field on the checkout`);
      await auditPayment("gift_aid_field_missing", {
        session: sessionId,
        purpose,
        payment_link: (session.payment_link as string) ?? null,
      });
    }

    const { data, error } = await db.rpc("record_public_donation", {
      p_session_id: sessionId,
      p_amount_p: amount,
      p_purpose: purpose,
      p_gift_aid: ga.giftAid,
      p_name: who.name,
      p_address: who.address,
      p_postcode: who.postcode,
    });

    if (error) {
      // 500 so Stripe retries: unlike an unknown reference, this one might
      // genuinely be transient.
      console.error(`stripe-webhook: record_public_donation failed for ${purpose} —`, error.message);
      return new Response("Could not record the donation", { status: 500 });
    }

    console.log(`stripe-webhook: donation ${data?.reference} (${purpose}) recorded` +
                (data?.already_recorded ? " (already recorded)" : ""));

    // Deliberately no email. Nobody has to act when a donation arrives, and
    // one message per donation would bury the two that DO need a human.
    return new Response(JSON.stringify({ ok: true, result: data }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  // Which kind of payment is this? Decided by the prefix and nothing else —
  // not by the amount (a hall deposit and a member's nikāḥ fee are both £100),
  // and not by which payment link was used.
  const KINDS: Record<string, { rpc: string; state: string; what: string }> = {
    "HH-": { rpc: "mark_deposit_paid",     state: "deposit_status", what: "hall deposit" },
    "NK-": { rpc: "mark_nikah_fee_paid",   state: "fee_status",     what: "nikāḥ fee" },
    "DN-": { rpc: "record_donation_paid",  state: "status",         what: "donation" },
  };
  const kind = KINDS[reference.slice(0, 3).toUpperCase()];

  if (!kind) {
    // Money has still been taken, so this is audited rather than ignored — but
    // not retried, because retrying will not teach this function a new prefix.
    console.error(`stripe-webhook: ${sessionId} has an unrecognised reference "${reference}"`);
    const audited = await auditPayment("payment_with_unknown_reference_kind", {
      session: sessionId,
      reference,
      amount_pence: amount,
      payment_link: (session.payment_link as string) ?? null,
      email: session.customer_details?.email ?? null,
    });
    return new Response(JSON.stringify({ ok: true, note: "unknown reference kind", audited }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  let args: Record<string, unknown> = {
    p_reference: reference,
    p_session_id: sessionId,
    p_amount_p: amount,
  };

  if (kind.rpc === "record_donation_paid") {
    const ga = readGiftAid(session.custom_fields as never);
    const who = donorDetails(ga.giftAid, session.customer_details?.name,
                             session.customer_details?.address);

    console.log(`stripe-webhook: gift aid = ${ga.giftAid} ` +
                `(matched by ${ga.matchedBy}, answer "${ga.answer}")`);

    if (ga.fieldMissing) {
      console.error(`stripe-webhook: ${reference} had NO Gift Aid field on the checkout`);
      await auditPayment("gift_aid_field_missing", {
        reference,
        session: sessionId,
        payment_link: (session.payment_link as string) ?? null,
      });
    }

    args = {
      ...args,
      p_gift_aid: ga.giftAid,
      p_name: who.name,
      p_address: who.address,
      p_postcode: who.postcode,
    };
  }

  const { data, error } = await db.rpc(kind.rpc, args);

  if (error) {
    console.error(`stripe-webhook: ${kind.rpc} failed for ${reference} —`, error.message);
    return new Response("Could not record the payment", { status: 500 });
  }

  console.log(`stripe-webhook: ${kind.what} ${reference} -> ${data?.[kind.state]}` +
              (data?.already_recorded ? " (already recorded)" : "") +
              (data?.duplicate_payment ? " (DUPLICATE — needs refunding)" : ""));

  if (!data?.already_recorded && kind.rpc !== "record_donation_paid") {
    await notify(reference, kind, data, session);
  }

  return new Response(JSON.stringify({ ok: true, result: data }), {
    status: 200, headers: { "content-type": "application/json" },
  });
});

/* Handing off to the notify function. Deliberately best-effort: the payment is
   already recorded by the time this runs, and that is the part that matters.
   Throwing here would make Stripe retry a payment recorded perfectly well. */
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

  let payload: Record<string, unknown> | null = null;

  if (state === "paid") {
    payload = {
      kind: hall ? "deposit_paid" : "nikah_fee_paid",
      reference,
      amount_p: session.amount_total ?? null,
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
