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
  | "nikah_fee_paid";

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
      subject: `Astley Hall booked — ${longDate(e.booking_date)} (${ref})`,
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
      // Said plainly in the subject line, because this is the one that must
      // not be skimmed past. The masjid is holding money it cannot keep.
      subject: `ACTION NEEDED — refund owed, ${ref}`,
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
      subject: `Nikāḥ date requested — ${longDate(e.booking_date)} (${ref})`,
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
      subject: `Nikāḥ fee paid — ${ref}`,
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
      subject: `Your booking is confirmed — ${longDate(e.booking_date)} (${ref})`,
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
      subject: `We have your nikāḥ request — ${ref}`,
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
