// ===========================================================================
//  stripe-webhook — records a payment made to the masjid
//
//  Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
//
//  THIS FILE MATCHES WHAT IS DEPLOYED (version 16, 14 September 2026).
//  If you change it, deploy it. If you change it in the dashboard, write it
//  back here the same day. This repository has been caught three times
//  holding a copy that did not match production.
//
//  ONE ENDPOINT, THREE KINDS OF PAYMENT
//  ------------------------------------
//  Decided by what the payment carries in client_reference_id:
//
//      HH-26-0001                 a hall hire deposit -> mark_deposit_paid()
//      NK-26-0001                 a nikāḥ fee         -> mark_nikah_fee_paid()
//      DN-…                       a donation with a reference already made
//      general|sadaqah|lillah|newbuild
//                                 a donation from the DONATE PAGE
//                                                     -> record_public_donation()
//
//  THE LAST ONE IS NEW, AND IT IS WHY THE MASJID'S FIRST REAL PAYMENT WENT
//  MISSING. The donate page sends the PURPOSE as client_reference_id, because
//  a Stripe Payment Link cannot carry an amount or anything else in its URL
//  and that is the only field available. But this function was already
//  routing on the first three characters of that same field, so "sadaqah"
//  matched nothing, was logged as an unrecognised reference, and no donation
//  was recorded. Reading Stripe's documentation on client_reference_id was
//  not enough: the code already listening on the other end had its own
//  meaning for it.
//
//  A purpose has no prefix and never will, so it is checked BEFORE the prefix
//  table rather than bolted into it. The reference for such a donation is
//  minted by the DATABASE — donations.reference is UNIQUE, so a fixed string
//  like "DN-sadaqah" would collide on the second sadaqah donation. See db/032.
//
//  One endpoint rather than several because Stripe signs every delivery with
//  the same endpoint secret; another function would need its own secret, its
//  own deployment and its own chance to be forgotten.
//
//  The kinds are NOT the same transaction, and the difference is deliberate:
//
//    - Paying a hall deposit CONFIRMS the booking. The site knows what is
//      free, so it can sell a date outright (migration 017).
//    - Paying a nikāḥ fee confirms NOTHING. The masjid does not publish its
//      nikāḥ diary, so the site cannot know whether a date is available. The
//      office agrees the date on the phone; this is only a way to pay without
//      coming in with cash (migration 018).
//    - A donation confirms nothing and nobody has to act on it.
//
//  If you are tempted to unify them, read the header of 018 first.
//
//  Stripe tells us a deposit has been paid. This is the ONLY thing that may
//  say so: a browser claiming "I have paid" is not evidence of anything,
//  which is why mark_deposit_paid() has EXECUTE revoked from anon and
//  authenticated and is reached here with the service role key.
//
//  Two rules that are easy to get wrong and expensive to get wrong:
//
//    1. VERIFY THE SIGNATURE FIRST. Anything else — reading the body, looking
//       up the reference, being helpful — happens after. Without it, anybody
//       who finds this URL can mark any booking paid by posting some JSON.
//       Checked with constructEventAsync, because Deno has no synchronous
//       crypto and the sync version silently fails here.
//
//    2. ALWAYS RETURN 200 ONCE THE SIGNATURE IS GOOD. Stripe retries a
//       non-2xx for days. Retrying cannot fix an unknown reference, and a
//       retry storm buries the real problem. Those cases are recorded in
//       admin_audit and answered 200.
//
//       AND THE AUDIT WRITE HAS TO ACTUALLY WORK. Until 14 September 2026 it
//       did not: service_role held no INSERT on admin_audit and no USAGE on
//       its sequence, so every "money arrived that I cannot match" row was
//       silently discarded — the one mechanism meant to make the bug above
//       visible was itself mute. Migration 032 grants both. GRANT and RLS are
//       different things and you need both.
//
//  Deploy:
//      supabase functions deploy stripe-webhook --no-verify-jwt
//
//  --no-verify-jwt is REQUIRED. Stripe does not send a Supabase JWT, so with
//  verification on, every delivery is rejected before this file ever runs.
//
//  Secrets — and none of them is the Stripe API key:
//      STRIPE_WEBHOOK_SECRET       whsec_… — the LIVE endpoint in Stripe
//      STRIPE_WEBHOOK_SECRET_TEST  whsec_… — optional, a test-mode endpoint
//      SUPABASE_URL               provided by the platform
//      SUPABASE_SERVICE_ROLE_KEY  provided by the platform
//
//  There is deliberately no STRIPE_SECRET_KEY here. Verifying a webhook
//  signature is a local HMAC of the raw body against the WEBHOOK secret; it
//  makes no call to Stripe. A leaked whsec_ lets somebody forge events into
//  this one function; a leaked sk_live_ can issue refunds and read every
//  customer. Do not add one "just in case".
//
//  In Stripe, add an endpoint pointing at this function and subscribe it to
//  `checkout.session.completed` and nothing else.
// ===========================================================================

import { readGiftAid, donorDetails } from "./giftaid.ts";
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

// The donate page's own vocabulary. Kept here rather than inferred, so that a
// stray client_reference_id cannot talk this function into creating donations
// out of somebody else's payment.
const PURPOSES = ["general", "sadaqah", "lillah", "newbuild"];

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
    // Somebody paid a link without going through the form that sets the
    // reference — typically by opening a Payment Link URL directly. Real
    // money, so it is logged rather than shrugged off: the office has to find
    // them, work out what it was for, and refund it if it cannot be placed.
    console.error(`stripe-webhook: ${sessionId} arrived with no client_reference_id`);
    await db.from("admin_audit").insert({
      action: "payment_without_reference",
      detail: { session: sessionId, amount_pence: amount,
                payment_link: (session.payment_link as string) ?? null,
                email: session.customer_details?.email ?? null },
    });
    return new Response(JSON.stringify({ ok: true, note: "no reference" }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  // -----------------------------------------------------------------------
  //  A DONATION FROM THE DONATE PAGE.
  //
  //  Checked before the prefix table because a purpose has no prefix. See the
  //  header: this is the case that was missing, and the case that made the
  //  masjid's first real donation vanish.
  // -----------------------------------------------------------------------
  const purpose = reference.trim().toLowerCase();
  if (PURPOSES.includes(purpose)) {
    const ga = readGiftAid(session.custom_fields as never);
    const who = donorDetails(ga.giftAid, session.customer_details?.name,
                             session.customer_details?.address);

    console.log(`stripe-webhook: donation (${purpose}) gift aid = ${ga.giftAid} ` +
                `(matched by ${ga.matchedBy}, answer "${ga.answer}")`);

    // A donation link with no Gift Aid question on it. Every donation through
    // it records as "no", no error is raised, no payment fails — and 25p in
    // every eligible pound is quietly not claimed. The only way anybody finds
    // out is if something says so here.
    if (ga.fieldMissing) {
      console.error(`stripe-webhook: a ${purpose} donation had NO Gift Aid field on the checkout`);
      await db.from("admin_audit").insert({
        action: "gift_aid_field_missing",
        detail: { session: sessionId, purpose,
                  payment_link: (session.payment_link as string) ?? null },
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
    // one message per donation would bury the two that DO need a human — a
    // nikāḥ request waiting for a call, and a refund the masjid owes somebody.
    return new Response(JSON.stringify({ ok: true, result: data }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  // Which kind of payment is this? Decided by the prefix and nothing else —
  // not by the amount (a hall deposit and a member's nikāḥ fee are both £100),
  // and not by which payment link was used (the masjid can add links without
  // this file knowing).
  const KINDS: Record<string, { rpc: string; state: string; what: string }> = {
    "HH-": { rpc: "mark_deposit_paid",     state: "deposit_status", what: "hall deposit" },
    "NK-": { rpc: "mark_nikah_fee_paid",   state: "fee_status",     what: "nikāḥ fee" },
    "DN-": { rpc: "record_donation_paid",  state: "status",         what: "donation" },
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
                payment_link: (session.payment_link as string) ?? null,
                email: session.customer_details?.email ?? null },
    });
    return new Response(JSON.stringify({ ok: true, note: "unknown reference kind" }), {
      status: 200, headers: { "content-type": "application/json" },
    });
  }

  // A donation carries two things the other two do not: the donor's answer to
  // the Gift Aid dropdown, and — only if they said yes — the name and address
  // HMRC needs. Both come from Stripe rather than from anything the masjid's
  // website could have made up.
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
      await db.from("admin_audit").insert({
        action: "gift_aid_field_missing",
        detail: { reference, session: sessionId,
                  payment_link: (session.payment_link as string) ?? null },
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
  if (!data?.already_recorded && kind.rpc !== "record_donation_paid") {
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
