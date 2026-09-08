/* ===========================================================================
   Taiyabah Masjid — notify
   Bolton Central Islamic Society · Registered charity 1041569

   One place that sends the masjid's transactional email. Called by:

     - stripe-webhook, server to server, when a deposit or a nikāḥ fee is
       recorded — including when the money has to go back
     - a Supabase database webhook on INSERT into nikah_requests

   WHY one.com AND NOT A THIRD-PARTY EMAIL SERVICE
   -----------------------------------------------
   Because the masjid already pays for one.com, the sign-in emails already go
   through it, and every extra account is another credential, another login and
   another paragraph in the handover document that somebody has to keep alive
   after Yameen steps back. Fewer moving parts beats marginally better tooling
   for an organisation with no technical staff.

   The cost of that choice, stated plainly so nobody is surprised:

     1. Supabase's own guide for sending mail from an Edge Function uses an
        HTTPS API, not SMTP, and their docs say nothing either way about raw
        TCP from a function. This is therefore the less-travelled path. If it
        does not work it will not work on the FIRST deploy — see /selftest
        below, which exists precisely so that is found in a minute rather than
        discovered when a booking is missed.
     2. one.com gives no bounce or delivery reporting. A message accepted by
        their server and then rejected by the recipient is invisible. So every
        failure THIS function can see is written to admin_audit — that is the
        only feedback the masjid gets, and it is why it is there.
     3. The credential is a mailbox password, not a send-only key. It must be
        the noreply@ mailbox and nothing else: that mailbox holds no mail, so
        a leak exposes nothing to read.

   WHAT IS DELIBERATELY NOT SENT
   -----------------------------
   The hirer's home address, in any email, to anybody. See messages.ts.

   SECURITY
   --------
   This is a public URL. It does nothing at all without the shared secret, and
   the public-facing address it sends to is only ever one the person gave for
   their own booking — never a list, never a bcc.

   Secrets (Edge Functions -> notify -> Secrets):
       NOTIFY_SECRET   a long random string, also given to whoever calls this
       SMTP_HOST       send.one.com
       SMTP_PORT       465          (implicit TLS; 587 also works)
       SMTP_USER       noreply@taiyabahmosque.co.uk
       SMTP_PASS       that mailbox's password
       MAIL_FROM       noreply@taiyabahmosque.co.uk
       MAIL_TO         office@… , someone-else@…    (comma separated)
       PORTAL_URL      https://…/venue/

   Deploy:
       supabase functions deploy notify --no-verify-jwt
   =========================================================================== */

import { SMTPClient } from "https://deno.land/x/denomailer@1.6.0/mod.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { type Event, officeMessage, publicMessage } from "./messages.ts";

const SECRET     = Deno.env.get("NOTIFY_SECRET") ?? "";
const SMTP_HOST  = Deno.env.get("SMTP_HOST")     ?? "send.one.com";
const SMTP_PORT  = Number(Deno.env.get("SMTP_PORT") ?? "465");
const SMTP_USER  = Deno.env.get("SMTP_USER")     ?? "";
const SMTP_PASS  = Deno.env.get("SMTP_PASS")     ?? "";
const MAIL_FROM  = Deno.env.get("MAIL_FROM")     ?? SMTP_USER;
const MAIL_TO    = Deno.env.get("MAIL_TO")       ?? "";
const PORTAL_URL = Deno.env.get("PORTAL_URL")    ?? "";

// Used only to record a send that failed. Provided by the platform.
const db = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false } },
);

const officeList = () =>
  MAIL_TO.split(",").map((s) => s.trim()).filter(Boolean);

/* ---------------------------------------------------------------------------
   Sending

   A fresh connection per message. Reusing one across invocations sounds
   thriftier but an Edge Function may be frozen between calls, and a half-open
   SMTP socket fails in ways that are very hard to read in a log. At a handful
   of emails a week this costs nothing.

   Implicit TLS on 465 by default rather than STARTTLS on 587: it is one fewer
   negotiation to go wrong, and one.com supports both.
   --------------------------------------------------------------------------- */
async function send(to: string[], subject: string, html: string, text: string) {
  if (!to.length) return { ok: false, why: "no recipient" };

  const client = new SMTPClient({
    connection: {
      hostname: SMTP_HOST,
      port: SMTP_PORT,
      tls: SMTP_PORT === 465,
      auth: { username: SMTP_USER, password: SMTP_PASS },
    },
  });

  try {
    // One message per recipient. The office must never appear in a header the
    // hirer can read, and one hirer must never see another's address.
    for (const address of to) {
      await client.send({
        from: MAIL_FROM.includes("<") ? MAIL_FROM : `Taiyabah Masjid <${MAIL_FROM}>`,
        to: address,
        subject,
        content: text,
        html,
      });
    }
    return { ok: true, why: "" };
  } catch (err) {
    return { ok: false, why: (err as Error).message.slice(0, 200) };
  } finally {
    try { await client.close(); } catch { /* already gone */ }
  }
}

/* one.com tells us nothing after a message is accepted, so a failure this
   function CAN see is the only feedback there is. It goes where the office
   already looks for things that need a human. */
async function recordFailure(kind: string, reference: string | null,
                             who: string, why: string) {
  console.error(`notify: FAILED ${kind} ${reference ?? ""} to ${who} — ${why}`);
  try {
    await db.from("admin_audit").insert({
      action: "notification_failed",
      detail: { kind, reference, recipient: who, error: why },
    });
  } catch (err) {
    // Nothing left to try. The log line above is the last record.
    console.error("notify: could not even record the failure —", (err as Error).message);
  }
}

/* Turn whatever called us into the one shape messages.ts understands.
   A database webhook posts {type, table, record}; stripe-webhook posts an
   event directly. Both end up here. */
export function toEvent(body: Record<string, unknown>): Event | null {
  if (body.type === "INSERT" && body.table === "nikah_requests") {
    const r = (body.record ?? {}) as Record<string, unknown>;
    return {
      kind: "nikah_requested",
      reference: r.reference as string,
      booking_date: r.preferred_date as string,
      slot: r.slot as string,
      name: r.contact_name as string,
      phone: r.contact_phone as string,
      email: r.contact_email as string,
    };
  }
  if (body.type && body.table) return null;   // some other table — not ours

  const kind = body.kind as Event["kind"];
  if (!kind) return null;
  return body as unknown as Event;
}

Deno.serve(async (req) => {
  // Always 200 once we recognise the caller. A non-2xx makes Supabase retry,
  // and a retry storm means the office gets the same booking emailed to them
  // over and over — which is how people learn to ignore these.
  const ok = (note: string) =>
    new Response(JSON.stringify({ ok: true, note }), {
      status: 200, headers: { "content-type": "application/json" },
    });

  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });

  if (!SECRET || req.headers.get("x-notify-secret") !== SECRET) {
    console.warn("notify: rejected, bad or missing x-notify-secret");
    return new Response("Unauthorized", { status: 401 });
  }

  if (!SMTP_USER || !SMTP_PASS) {
    console.error("notify: not configured — set SMTP_USER and SMTP_PASS");
    return ok("not configured");
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return ok("unreadable body");
  }

  /* --- the selftest ------------------------------------------------------
     Sending mail over SMTP from an Edge Function is the less-travelled path,
     so this exists to answer "does it work at all?" in one minute rather than
     by waiting for a booking that never gets emailed. It reports the real
     error back to the caller instead of only logging it.

     It still needs the secret, and it only ever sends to MAIL_TO — never to
     an address supplied in the request. */
  if (body.kind === "selftest") {
    const r = await send(officeList(),
      "Test — Taiyabah Masjid website",
      "<p>This is a test from the masjid website. If you are reading it, " +
      "booking alerts will work.</p>",
      "This is a test from the masjid website. If you are reading it, " +
      "booking alerts will work.");
    console.log(`notify: selftest -> ${r.ok ? "sent" : r.why}`);
    return new Response(JSON.stringify({
      ok: r.ok,
      note: r.ok ? `sent to ${officeList().join(", ")}` : r.why,
      host: `${SMTP_HOST}:${SMTP_PORT}`,
    }), { status: 200, headers: { "content-type": "application/json" } });
  }

  const event = toEvent(body);
  if (!event) return ok("nothing to send for this");

  event.portal = event.portal ?? PORTAL_URL;

  const results: string[] = [];

  const office = officeMessage(event);
  if (office) {
    const r = await send(officeList(), office.subject, office.html, office.text);
    results.push(`office:${r.ok ? "sent" : r.why}`);
    if (!r.ok) {
      await recordFailure(event.kind, event.reference ?? null, "office", r.why);
    }
  }

  // Only ever to the address this person gave, about their own booking.
  const theirs = publicMessage(event);
  if (theirs && event.email) {
    const r = await send([event.email], theirs.subject, theirs.html, theirs.text);
    results.push(`hirer:${r.ok ? "sent" : r.why}`);
    if (!r.ok) {
      // Deliberately not logging which address. The failure needs recording;
      // the person's email does not need to sit in an audit table for it.
      await recordFailure(event.kind, event.reference ?? null, "hirer", r.why);
    }
  }

  console.log(`notify: ${event.kind} ${event.reference ?? ""} — ${results.join(" ") || "nothing sent"}`);
  return ok(results.join(" ") || "nothing sent");
});
