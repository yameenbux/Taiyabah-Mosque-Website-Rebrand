/* ===========================================================================
   Taiyabah Masjid — what each notification actually says
   Bolton Central Islamic Society · Registered charity 1041569

   Kept apart from index.ts on purpose: everything here is a pure function of
   its input, so it can be tested without a network, a mail provider or a
   running Edge Function. `deno test` covers this file; index.ts is the thin
   part that posts the result.

   WHAT IS DELIBERATELY NOT IN ANY EMAIL
     The hirer's home address. It is the most sensitive thing on the form and
     the least useful for ringing somebody back. Keeping it out means the mail
     provider never processes it, inboxes never accumulate it, and a forwarded
     email cannot leak one. It lives in the portal, which is where the outcome
     gets recorded anyway.
   =========================================================================== */

export type Kind =
  | "deposit_paid"
  | "refund_due"
  | "nikah_requested"
  | "nikah_fee_paid"
  | "digest";

export interface Event {
  kind: Kind;
  reference?: string | null;
  booking_date?: string | null;   // ISO yyyy-mm-dd
  hire_type?: string | null;      // 'halls' | 'kitchen_only'
  halls_count?: number | null;
  name?: string | null;
  phone?: string | null;
  email?: string | null;          // where a confirmation may be sent
  amount_p?: number | null;
  slot?: string | null;           // nikāḥ prayer slot
  reason?: string | null;         // why a refund is owed
  portal?: string | null;         // link to the right portal page

  // The Monday digest only. Counts, never people.
  new_nikah?: number;
  oldest_nikah_days?: number;
  refunds_due?: number;
  balances_due?: number;
  this_week?: number;
}

export interface Message {
  subject: string;
  text: string;
  html: string;
}

/* --------------------------------------------------------------------------
   Formatting
   -------------------------------------------------------------------------- */

export function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

export function longDate(iso?: string | null): string {
  if (!iso) return "(no date)";
  // Built from parts. new Date("2026-09-12") is parsed as UTC and renders as
  // the day before for anyone west of Greenwich — which for a masjid in Bolton
  // means every booking looks a day early through the winter.
  const parts = String(iso).split("-").map(Number);
  if (parts.length !== 3 || parts.some((n) => !isFinite(n))) return String(iso);
  const d = new Date(parts[0], parts[1] - 1, parts[2]);
  return d.toLocaleDateString("en-GB", {
    weekday: "long", day: "numeric", month: "long", year: "numeric",
  });
}

/* SUBJECT LINES ARE PURE ASCII. THIS IS NOT A STYLE CHOICE.

   The first live nikāḥ alert arrived with its subject shown as
       =?utf-8?Q?Nik=c4=81=e1=b8=a5 date requested =e2=80=94 Sunday 27 Sep...
   because it contained ā, ḥ and an em dash. Non-ASCII in a subject has to be
   MIME encoded, RFC 2047 caps a single encoded-word at 75 characters, and the
   result was 78 — so the client refused to decode it and printed the raw
   encoding instead.

   Rather than rely on every mail client folding long encoded-words correctly,
   subjects are written in plain ASCII and this strips anything that slips
   through. The email BODY is unaffected: it is HTML with a charset, so ā and
   ḥ render properly there and the masjid's own words are not flattened where
   it matters. */
export function ascii(v: string): string {
  return v
    .normalize("NFD").replace(/[\u0300-\u036f]/g, "")   // ā -> a, ḥ -> h
    .replace(/[\u2010-\u2015]/g, "-")                   // – — ‒ -> -
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/\u2026/g, "...")
    .replace(/[^\x20-\x7E]/g, "");                      // anything left
}

/* Short form for subject lines: "Sat 26 Sep 2026". The long form is fine in
   the body but eats the subject, and clients truncate what they show. */
export function shortDate(iso?: string | null): string {
  if (!iso) return "";
  const parts = String(iso).split("-").map(Number);
  if (parts.length !== 3 || parts.some((n) => !isFinite(n))) return String(iso);
  return new Date(parts[0], parts[1] - 1, parts[2]).toLocaleDateString("en-GB", {
    weekday: "short", day: "numeric", month: "short", year: "numeric",
  }).replace(/,/g, "");
}

export function money(p?: number | null): string {
  if (p === null || p === undefined || !isFinite(p)) return "";
  return "£" + (p / 100).toFixed(2).replace(/\.00$/, "");
}

export function whatWasHired(e: Event): string {
  if (e.hire_type === "kitchen_only") return "Kitchen only · whole day";
  const n = e.halls_count;
  if (!n) return "Whole day";
  return (n === 1 ? "1 hall" : `${n} halls`) +
         " · kitchen and cleaning included · whole day";
}

const SLOTS: Record<string, string> = {
  after_fajr: "After Fajr", after_zuhr: "After Zuhr", after_asr: "After Asr",
  after_maghrib: "After Maghrib", after_isha: "After Isha",
  saturday_11: "Saturday 11:00am", flexible: "Flexible — masjid to suggest",
};
export function slotLabel(s?: string | null): string {
  if (!s) return "";
  return SLOTS[s] ?? s;
}

/* --------------------------------------------------------------------------
   The shell every email shares
   -------------------------------------------------------------------------- */

function shell(heading: string, lead: string, rows: [string, string][],
               footer: string, action?: { href: string; label: string }): string {
  const cells = rows.map(([k, v]) =>
    `<tr><td style="padding:6px 20px 6px 0;color:#6E616A;font-size:14px;white-space:nowrap;">${esc(k)}</td>` +
    `<td style="padding:6px 0;font-size:14px;color:#2B2430;">${v}</td></tr>`).join("");

  return `<table width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F3EFE3;padding:28px 12px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
<tr><td align="center">
<table width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:520px;background:#ffffff;border:1px solid #E4DDCB;border-radius:10px;">
<tr><td style="padding:26px 30px 6px;border-bottom:1px solid #EFEAE0;">
<div style="font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#8A6D1F;">Taiyabah Masjid</div>
<div style="font-size:13px;color:#6E616A;padding-top:3px;">Bolton Central Islamic Society</div>
</td></tr>
<tr><td style="padding:24px 30px 4px;">
<h1 style="margin:0 0 12px;font-size:20px;line-height:1.3;color:#3B1E38;font-weight:600;">${esc(heading)}</h1>
<p style="margin:0 0 16px;font-size:15px;line-height:1.65;color:#2B2430;">${lead}</p>
<table cellpadding="0" cellspacing="0" border="0" style="margin:0 0 18px;">${cells}</table>
${action ? `<table cellpadding="0" cellspacing="0" border="0"><tr><td style="background:#C6A24C;border-radius:8px;">
<a href="${esc(action.href)}" style="display:inline-block;padding:13px 26px;font-size:15px;font-weight:700;color:#3B1E38;text-decoration:none;">${esc(action.label)}</a>
</td></tr></table>` : ""}
</td></tr>
<tr><td style="padding:18px 30px 24px;border-top:1px solid #EFEAE0;">
<p style="margin:0 0 8px;font-size:12px;line-height:1.7;color:#6E616A;">${footer}</p>
<p style="margin:0;font-size:12px;line-height:1.7;color:#8A8189;">
<strong style="color:#6E616A;">Taiyabah Masjid</strong><br>
31a Draycott Street, Bolton BL1 8HD<br>01204 535 997<br>
Bolton Central Islamic Society &middot; Registered charity 1041569</p>
</td></tr></table></td></tr></table>`;
}

function plain(heading: string, lead: string, rows: [string, string][],
               footer: string, link?: string): string {
  const w = Math.max(...rows.map(([k]) => k.length), 0);
  return [
    heading.toUpperCase(), "",
    lead, "",
    ...rows.map(([k, v]) => `  ${k.padEnd(w)}  ${v.replace(/<[^>]+>/g, "")}`),
    "",
    link ? link + "\n" : "",
    footer.replace(/<[^>]+>/g, ""), "",
    "Taiyabah Masjid, 31a Draycott Street, Bolton BL1 8HD · 01204 535 997",
    "Bolton Central Islamic Society · Registered charity 1041569",
  ].filter((l) => l !== "").join("\n");
}

/* --------------------------------------------------------------------------
   THE OFFICE'S EMAILS
   -------------------------------------------------------------------------- */

export function officeMessage(e: Event): Message | null {
  if (e.kind === "digest") return digestMessage(e);

  const ref = e.reference ?? "(no reference)";
  const tel = String(e.phone ?? "").replace(/\s/g, "");
  const phoneCell = e.phone
    ? `<a href="tel:${esc(tel)}" style="color:#8A6D1F;font-weight:600;">${esc(e.phone)}</a>`
    : "(none given)";

  if (e.kind === "deposit_paid") {
    const rows: [string, string][] = [
      ["Date", `<strong>${esc(longDate(e.booking_date))}</strong>`],
      ["Hiring", esc(whatWasHired(e))],
      ["Name", `<strong>${esc(e.name ?? "")}</strong>`],
      ["Phone", phoneCell],
      ["Reference", esc(ref)],
      ["Deposit", esc(money(e.amount_p) || "£100")],
    ];
    return {
      // Informational. A human does not have to DO anything — the payment
      // already did it. Reserving the loud words for the two that need
      // acting on is what keeps them meaning something.
      subject: ascii(`Hall booked and paid - ${shortDate(e.booking_date)} (${ref})`),
      html: shell(
        "A date has been booked and paid for",
        "The deposit has gone through, so this booking is <strong>confirmed</strong>. " +
        "Nobody needs to agree it — the payment did that. The date is no longer available to anybody else.",
        rows,
        "The balance is due 30 days before. The hirer's address and the rest of " +
        "the details are in the venue portal, which is also where the balance is recorded.",
        e.portal ? { href: e.portal, label: "Open the venue portal" } : undefined),
      text: plain(
        "A date has been booked and paid for",
        "The deposit has gone through, so this booking is CONFIRMED. Nobody needs " +
        "to agree it — the payment did that. The date is no longer available.",
        rows, "The balance is due 30 days before. Details are in the venue portal.",
        e.portal ?? undefined),
    };
  }

  if (e.kind === "refund_due") {
    const rows: [string, string][] = [
      ["Reference", `<strong>${esc(ref)}</strong>`],
      ["Date", esc(longDate(e.booking_date))],
      ["Name", esc(e.name ?? "")],
      ["Phone", phoneCell],
      ["Amount", `<strong>${esc(money(e.amount_p) || "unknown")}</strong>`],
      ["Why", esc(e.reason ?? "see the portal")],
    ];
    return {
      // Somebody must act, and until they do the masjid is holding money it
      // cannot keep.
      subject: ascii(`Refund owed - ATTENTION REQUIRED - ${ref}`),
      html: shell(
        "Money needs refunding",
        "Somebody has paid the masjid for something it cannot give them. " +
        "<strong>Nothing happens until a person refunds it in Stripe.</strong> " +
        "It will sit in the Refunds tab of the portal until then.",
        rows,
        "Refund it in Stripe, then mark it refunded in the portal so the tab clears.",
        e.portal ? { href: e.portal, label: "Open the portal" } : undefined),
      text: plain(
        "Money needs refunding",
        "Somebody has paid for something the masjid cannot give them. NOTHING " +
        "HAPPENS until a person refunds it in Stripe.",
        rows, "Refund in Stripe, then mark it refunded in the portal.",
        e.portal ?? undefined),
    };
  }

  if (e.kind === "nikah_requested") {
    const rows: [string, string][] = [
      ["Date asked for", `<strong>${esc(longDate(e.booking_date))}</strong>`],
      ["Time", esc(slotLabel(e.slot))],
      ["Contact", `<strong>${esc(e.name ?? "")}</strong>`],
      ["Phone", phoneCell],
      ["Reference", esc(ref)],
    ];
    return {
      // Somebody must ring the family. Nothing else in the system will.
      //
      // It says REQUEST, not booking, on purpose. A nikāḥ request is not a
      // booking — the masjid does not publish its diary and the website
      // cannot know whether the date is free. If the subject line says
      // "booking" the office starts treating it as one, which is the exact
      // confusion the body of the email exists to prevent.
      subject: ascii(`Nikah request - ATTENTION REQUIRED - ${shortDate(e.booking_date)} (${ref})`),
      html: shell(
        "Somebody has asked for a nikāḥ date",
        "This is a <strong>request</strong>, not a booking. The masjid does not " +
        "publish its nikāḥ diary, so the website could not tell them whether the " +
        "date is free. They are waiting for a call.",
        rows,
        "Ring them, agree what the masjid can do, then record it in the portal. " +
        "The fee can be paid at the office, by transfer, or online.",
        e.portal ? { href: e.portal, label: "Open the portal" } : undefined),
      text: plain(
        "Somebody has asked for a nikāḥ date",
        "This is a REQUEST, not a booking. They are waiting for a call.",
        rows, "Ring them, agree the date, then record it in the portal.",
        e.portal ?? undefined),
    };
  }

  if (e.kind === "nikah_fee_paid") {
    const rows: [string, string][] = [
      ["Reference", `<strong>${esc(ref)}</strong>`],
      ["Date asked for", esc(longDate(e.booking_date))],
      ["Contact", esc(e.name ?? "")],
      ["Paid", `<strong>${esc(money(e.amount_p))}</strong>`],
    ];
    return {
      subject: ascii(`Nikah fee paid - ${ref}`),
      html: shell(
        "A nikāḥ fee has been paid online",
        "The money has arrived. <strong>This does not agree the date</strong> — " +
        "the masjid still decides that, exactly as before. Check the amount " +
        "matches the rate that applies to them.",
        rows,
        "£100 is the member rate, £200 otherwise. If the wrong one was paid, " +
        "sort it out when you ring them.",
        e.portal ? { href: e.portal, label: "Open the portal" } : undefined),
      text: plain(
        "A nikāḥ fee has been paid online",
        "The money has arrived. THIS DOES NOT AGREE THE DATE — the masjid still " +
        "decides that. Check the amount matches their rate.",
        rows, "£100 member, £200 otherwise.", e.portal ?? undefined),
    };
  }

  return null;
}

/* --------------------------------------------------------------------------
   THE MONDAY DIGEST

   Counts, and nothing else. No names, no phone numbers, no references — the
   portal holds all of that and this only has to get somebody to open it.

   The database decides whether to send at all: send_weekly_digest() returns
   without posting when nothing is outstanding. A weekly email that always
   arrives becomes furniture within a month, and then the week it says a
   refund is owed gets skimmed past with the rest.
   -------------------------------------------------------------------------- */

function digestMessage(e: Event): Message {
  const nikah    = e.new_nikah ?? 0;
  const refunds  = e.refunds_due ?? 0;
  const balances = e.balances_due ?? 0;
  const week     = e.this_week ?? 0;
  const oldest   = e.oldest_nikah_days ?? 0;

  const rows: [string, string][] = [];

  if (refunds > 0) {
    rows.push(["Refunds owed",
      `<strong style="color:#8B2E2E;">${refunds}</strong> ` +
      `&mdash; the masjid is holding money it cannot keep`]);
  }
  if (nikah > 0) {
    // The number that makes a shared inbox honest. "2 requests" is easy to
    // assume somebody else has handled; "waiting 9 days" is not.
    rows.push(["Nikah requests unanswered",
      `<strong>${nikah}</strong>` +
      (oldest > 0
        ? ` &mdash; the oldest has been waiting <strong>${oldest} day${oldest === 1 ? "" : "s"}</strong>`
        : "")]);
  }
  if (balances > 0) {
    rows.push(["Balances due within 30 days", `<strong>${balances}</strong>`]);
  }
  rows.push(["Booked this week", String(week)]);

  // The subject carries the headline so it can be judged without opening it.
  const headline = refunds > 0
    ? `${refunds} refund${refunds === 1 ? "" : "s"} owed`
    : nikah > 0
      ? `${nikah} nikah request${nikah === 1 ? "" : "s"} waiting`
      : balances > 0
        ? `${balances} balance${balances === 1 ? "" : "s"} due`
        : "this week at the masjid";

  const needsAction = refunds > 0 || nikah > 0;

  return {
    subject: ascii(`Masjid weekly - ${headline}` +
                   (needsAction ? " - ATTENTION REQUIRED" : "")),
    html: shell(
      "Still waiting for somebody",
      "This only arrives when something needs doing. Everything below is in " +
      "the portal now and will stay there until somebody deals with it.",
      rows,
      "If nobody has time this week, the refunds are the ones that matter — " +
      "that is somebody else's money.",
      e.portal ? { href: e.portal, label: "Open the portal" } : undefined),
    text: plain(
      "Still waiting for somebody",
      "This only arrives when something needs doing.",
      rows,
      "If nobody has time this week, the refunds matter most — that is " +
      "somebody else's money.",
      e.portal ?? undefined),
  };
}

/* --------------------------------------------------------------------------
   THE PUBLIC'S EMAILS

   Only ever sent to an address the person themselves supplied, and only about
   their own booking. Never bcc'd, never grouped.
   -------------------------------------------------------------------------- */

export function publicMessage(e: Event): Message | null {
  const ref = e.reference ?? "";
  if (!e.email || !ref) return null;

  if (e.kind === "deposit_paid") {
    const rows: [string, string][] = [
      ["Your date", `<strong>${esc(longDate(e.booking_date))}</strong>`],
      ["Booked", esc(whatWasHired(e))],
      ["Reference", `<strong>${esc(ref)}</strong>`],
      ["Deposit paid", esc(money(e.amount_p) || "£100")],
    ];
    return {
      subject: ascii(`Your booking is confirmed - ${shortDate(e.booking_date)} (${ref})`),
      html: shell(
        "Your booking is confirmed",
        "Thank you — your deposit has gone through and <strong>the date is yours</strong>. " +
        "Nobody else can book it.",
        rows,
        "Keep this email: the reference above is how the office finds your booking. " +
        "The balance is due 30 days before your date and is paid at the office, in " +
        "cash or by bank transfer — the office will confirm the exact figure. " +
        "Any questions, ring 01204&nbsp;535&nbsp;997."),
      text: plain(
        "Your booking is confirmed",
        "Thank you — your deposit has gone through and the date is yours.",
        rows,
        "Keep this email; the reference is how the office finds your booking. " +
        "The balance is due 30 days before. Questions: 01204 535 997."),
    };
  }

  if (e.kind === "nikah_requested") {
    const rows: [string, string][] = [
      ["Date you asked for", `<strong>${esc(longDate(e.booking_date))}</strong>`],
      ["Time", esc(slotLabel(e.slot))],
      ["Reference", `<strong>${esc(ref)}</strong>`],
    ];
    return {
      subject: ascii(`We have your nikah request - ${ref}`),
      html: shell(
        "We have your request",
        "Thank you. <strong>This is not a booking yet.</strong> The masjid will " +
        "ring you to confirm whether the date can be done and go through the details.",
        rows,
        "Keep this email — the reference above is what a payment is matched by, " +
        "and the office will ask for it. Please do not pay anything until the " +
        "masjid has agreed a date with you. If you need to reach us first, ring " +
        "01204&nbsp;535&nbsp;997."),
      text: plain(
        "We have your request",
        "Thank you. THIS IS NOT A BOOKING YET. The masjid will ring you to confirm " +
        "whether the date can be done.",
        rows,
        "Keep this email — the reference is what a payment is matched by. Please " +
        "do not pay anything until a date has been agreed. 01204 535 997."),
    };
  }

  // A refund is a conversation, not a template. The office rings.
  return null;
}
