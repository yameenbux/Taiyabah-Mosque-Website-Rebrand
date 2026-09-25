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

     The same rule now covers a charity collection's TRUSTEE. They did not
     fill the form in and have not agreed to anything; the office rings them
     from the portal.
   =========================================================================== */

export type Kind =
  | "deposit_paid"
  | "refund_due"
  | "nikah_requested"
  | "nikah_fee_paid"
  | "charity_requested"
  | "admission_requested"
  | "course_registered"
  | "volunteer_registered"
  | "madrasah_fee_reminder"
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

  // A charity collection (chanda). The trustee's name and number are NOT
  // here, and there is deliberately no field for them: the office rings the
  // trustee from the portal, where the outcome gets recorded anyway, and a
  // forwarded email should not carry the details of somebody who did not fill
  // the form in. Same rule as the hirer's address.
  org_name?: string | null;
  collector_paid?: boolean | null;
  charity_number?: string | null;

  // A MADRASAH FEE REMINDER.
  //
  // THERE IS NO FIELD HERE FOR A CHILD, AND THAT IS THE POINT — the same
  // rule as the admission application below, for the same reason. A madrasah
  // roll reveals a child's religion, which is Article 9 data, and this is the
  // one message in this system that is UNSOLICITED: the family did not just
  // fill a form in, somebody in the office pressed a button. A line like
  // "Yusuf — Autumn term" in an email forwarded round a family group is a
  // disclosure the masjid never had to make.
  //
  // The family name, the reference and the amount are enough for a parent to
  // act, and migration 071 has a CHECK that fails if a pupil name, a class or
  // a charge description is ever added to what it posts here.
  family?: string | null;        // the family, not the child
  balance_p?: number | null;     // what is owed, in pence
  subject?: string | null;       // the office's own wording, if it set any
  body?: string | null;
  card_link?: string | null;     // a Stripe payment link, or nothing
  bank_name?: string | null;
  bank_sort?: string | null;
  bank_number?: string | null;
  bank_account_name?: string | null;

  // A madrasah admission application.
  //
  // THERE IS NO FIELD HERE FOR A CHILD, AND THAT IS THE POINT. The
  // application carries every child's name, date of birth, gender, school,
  // SEND status, EHCP, allergies and medical conditions. Most of that is
  // special category data under Article 9 and the rest belongs to a child who
  // cannot consent to anything. None of it may be handed to a mail provider,
  // sit in a shared inbox, or be forwarded by somebody being helpful. The
  // office opens the portal; the email only says an application arrived.
  //
  // The home address is out for the same reason it is out of a hall booking.
  academic_year?: string | null;

  // A course registration. `outcome` is 'place' or 'waiting' and MUST reach
  // the person: telling somebody they are registered when they are on the
  // waiting list is the kind of wrong that is only discovered on the night.
  course_name?: string | null;
  cohort?: string | null;
  outcome?: string | null;

  // A foodbank volunteer. Their age and gender are on the form and are NOT
  // here: the rota is planned in the portal, and an email is a bell, not a
  // record. `preferred_contact` is carried because it changes what the office
  // should do next.
  preferred_contact?: string | null;
  frequency?: string | null;
  sunday_mornings?: boolean | null;

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

/* The database stores these as short keys. An email is read by a person, so
   it says the words. Each falls back to the raw key rather than to an empty
   string: an unexpected value should look wrong in the email, not vanish and
   leave a blank row that reads as "none". */
const COHORTS: Record<string, string> = {
  mens: "Men's", womens: "Women's", all: "Open to all",
};
export function cohortLabel(c?: string | null): string {
  if (!c) return "";
  return COHORTS[c] ?? c;
}

const CONTACT: Record<string, string> = {
  phone: "a phone call", text: "a text message", email: "email",
};
export function contactLabel(c?: string | null): string {
  if (!c) return "(not said)";
  return CONTACT[c] ?? c;
}

const FREQUENCY: Record<string, string> = {
  weekly: "Weekly", fortnightly: "Fortnightly", monthly: "Monthly",
};
export function frequencyLabel(f?: string | null): string {
  if (!f) return "";
  return FREQUENCY[f] ?? f;
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

  //  THE OFFICE IS NOT COPIED ON FEE REMINDERS. Every other message here is
  //  news — somebody booked something, somebody applied. A reminder is not:
  //  the office sent it, from a screen that already shows exactly who it went
  //  to and what happened to each one. Copying them would put three hundred
  //  identical emails in an inbox that people would then start ignoring, and
  //  the week a refund is genuinely owed it would be skimmed past with the
  //  rest. Returning null here is what stops that.
  if (e.kind === "madrasah_fee_reminder") return null;

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

  if (e.kind === "charity_requested") {
    // THE PAID ANSWER IS IN THE SUBJECT LINE, NOT BURIED IN A TABLE.
    // On the paper form it is a tick in a box on page one that nobody reads
    // twice. A collector who takes a wage or commission is a different
    // proposition, and whoever opens this on a phone should see it before
    // they open it.
    const paid = e.collector_paid === true;
    const rows: [string, string][] = [
      ["Charity", `<strong>${esc(e.org_name ?? "")}</strong>`],
      ["Date asked for", `<strong>${esc(longDate(e.booking_date))}</strong>`],
      ["Collecting", esc(e.name ?? "")],
      ["Phone", phoneCell],
      ["Charity number", esc(e.charity_number || "not given")],
      ["Paid collector", paid ? "<strong>YES — they take a wage or commission</strong>" : "No"],
      ["Reference", esc(ref)],
    ];
    return {
      // REQUEST, not booking — same reasoning as the nikāḥ subject above. The
      // masjid allows one collection a day and the website is never told
      // which days are taken, so nothing here has reserved anything.
      subject: ascii(
        `Charity collection request${paid ? " - PAID COLLECTOR" : ""} - ` +
        `${shortDate(e.booking_date)} (${ref})`),
      html: shell(
        "A charity has asked to collect at the masjid",
        "This is a <strong>request</strong>, not a booking. Nothing has been " +
        "reserved. The masjid rings the <strong>trustee</strong> named on the " +
        "form — not the collector — to confirm the collection is genuine, then " +
        "approves or declines it in the portal." +
        (paid
          ? " <strong>This collector says they are paid for doing it.</strong> " +
            "That is allowed, and the committee should know before they stand " +
            "in the masjid asking people for money."
          : ""),
        rows,
        "The trustee's details, the address and the rest of the form are in the " +
        "portal. They are deliberately not in this email.",
        e.portal ? { href: e.portal, label: "Open the portal" } : undefined),
      text: plain(
        "A charity has asked to collect at the masjid",
        "This is a REQUEST, not a booking. Ring the TRUSTEE named on the form " +
        "to confirm it is genuine, then approve or decline in the portal." +
        (paid ? " THIS COLLECTOR IS PAID FOR DOING IT." : ""),
        rows,
        "The trustee's details and the rest of the form are in the portal.",
        e.portal ?? undefined),
    };
  }

  if (e.kind === "admission_requested") {
    // Deliberately four rows. Everything that would make this email useful to
    // read instead of opening the portal is exactly the data that must not be
    // in it — see the Event type above.
    const rows: [string, string][] = [
      ["Parent", `<strong>${esc(e.name ?? "")}</strong>`],
      ["Phone", phoneCell],
      ["Academic year", esc(e.academic_year ?? "")],
      ["Reference", esc(ref)],
    ];
    return {
      subject: ascii(`Madrasah application - ${ref}`),
      html: shell(
        "A madrasah application has been submitted",
        "A parent has applied for a place. <strong>The children's details are " +
        "not in this email and will not be.</strong> They include dates of " +
        "birth, schools, allergies and medical needs, which belong in the " +
        "portal and nowhere else.",
        rows,
        "Open the portal to see the children, the second contact and the rest " +
        "of the form.",
        e.portal ? { href: e.portal, label: "Open the portal" } : undefined),
      text: plain(
        "A madrasah application has been submitted",
        "A parent has applied for a place. THE CHILDREN'S DETAILS ARE NOT IN " +
        "THIS EMAIL and will not be — they are in the portal.",
        rows, "Open the portal to see the rest of the form.",
        e.portal ?? undefined),
    };
  }

  if (e.kind === "course_registered") {
    const waiting = e.outcome === "waiting";
    const rows: [string, string][] = [
      ["Course", `<strong>${esc(e.course_name ?? "")}</strong>`],
      ["Group", esc(cohortLabel(e.cohort))],
      ["Name", `<strong>${esc(e.name ?? "")}</strong>`],
      ["Phone", phoneCell],
      ["Outcome", waiting
        ? "<strong>WAITING LIST &mdash; the course is full</strong>"
        : "Has a place"],
      ["Reference", esc(ref)],
    ];
    return {
      // The full/not-full answer is in the subject for the same reason the
      // paid collector is: it changes what the office does, and it should not
      // need the email opening to be seen.
      subject: ascii(`Course registration${waiting ? " - WAITING LIST" : ""} - ` +
                     `${e.course_name ?? ""} (${ref})`),
      html: shell(
        waiting ? "Somebody has joined the waiting list" : "Somebody has registered for a course",
        waiting
          ? "This course is <strong>full</strong>, so they have been put on the " +
            "waiting list and told so plainly. They move up automatically when " +
            "somebody withdraws."
          : "They have a place. Nothing needs doing &mdash; the registration " +
            "took the place itself.",
        rows,
        "Anything they wrote about their experience is in the portal, not here.",
        e.portal ? { href: e.portal, label: "Open the portal" } : undefined),
      text: plain(
        waiting ? "Somebody has joined the waiting list" : "Somebody has registered for a course",
        waiting
          ? "This course is FULL. They are on the waiting list and have been told so."
          : "They have a place. Nothing needs doing.",
        rows, "What they wrote about their experience is in the portal.",
        e.portal ?? undefined),
    };
  }

  if (e.kind === "volunteer_registered") {
    const rows: [string, string][] = [
      ["Name", `<strong>${esc(e.name ?? "")}</strong>`],
      ["Phone", phoneCell],
      ["Prefers", `<strong>${esc(contactLabel(e.preferred_contact))}</strong>`],
      ["Sunday mornings", e.sunday_mornings === true ? "Yes" : "No"],
      ["How often", esc(frequencyLabel(e.frequency))],
      ["Reference", esc(ref)],
    ];
    return {
      subject: ascii(`Foodbank volunteer - ${e.name ?? ""} (${ref})`),
      html: shell(
        "Somebody has offered to help at the foodbank",
        "They are waiting to hear from the masjid. <strong>Contact them the " +
        "way they asked to be contacted</strong> &mdash; it is the first thing " +
        "the masjid does with them and the first chance to get it wrong.",
        rows,
        "Their age, what they can do and anything else they wrote are in the " +
        "portal. Mark them contacted there so nobody rings them twice.",
        e.portal ? { href: e.portal, label: "Open the portal" } : undefined),
      text: plain(
        "Somebody has offered to help at the foodbank",
        "They are waiting to hear from the masjid. CONTACT THEM THE WAY THEY " +
        "ASKED TO BE CONTACTED.",
        rows,
        "The rest is in the portal. Mark them contacted so nobody rings twice.",
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

  /* A FEE REMINDER.

     The only unsolicited message this system sends. It says what the family
     owes, the reference to quote, and how to pay — and nothing else. No
     child, no class, no breakdown of which term.

     No unsubscribe link, deliberately, and 019's argument is not quite the
     one that applies here. This is not marketing and it is not a newsletter;
     it is a bill. Offering a parent the chance to opt out of being told what
     they owe would be a promise the masjid cannot keep. What it does offer is
     a telephone number, because somebody who cannot pay needs a person and
     not a link — and the madrasah waives fees in hardship, which is a
     conversation, not a form. */
  if (e.kind === "madrasah_fee_reminder") {
    const owed = money(e.balance_p) || "the amount on your account";
    const rows: [string, string][] = [
      ["Amount outstanding", `<strong>${esc(owed)}</strong>`],
      ["Your reference", `<strong>${esc(ref)}</strong>`],
    ];
    if (e.bank_sort && e.bank_number) {
      rows.push(["Bank", esc(e.bank_name ?? "")]);
      rows.push(["Account name", esc(e.bank_account_name ?? e.bank_name ?? "")]);
      rows.push(["Sort code", esc(e.bank_sort)]);
      rows.push(["Account number", esc(e.bank_number)]);
    }

    const lead = e.body
      ? esc(e.body)
      : "Assalamu alaikum. This is a reminder about the madrasah fees for " +
        `<strong>${esc(e.family ?? "your family")}</strong>.`;

    const pay = e.bank_sort && e.bank_number
      ? "Please quote the reference above on the transfer — it is how the " +
        "office knows the money is yours. "
      : "Please ring the office to arrange payment. ";

    const card = e.card_link
      ? `You can also <a href="${esc(e.card_link)}">pay by card</a>, quoting ` +
        "the same reference. "
      : "";

    return {
      subject: ascii(e.subject || `Madrasah fees - ${ref}`),
      html: shell(
        "Madrasah fees",
        lead,
        rows,
        pay + card +
        "Fees can also be paid at the office. If this has crossed with a " +
        "payment you have already made, please ignore it. " +
        "<strong>If money is difficult at the moment, ring the office on " +
        "01204&nbsp;535&nbsp;997 and ask</strong> — the madrasah would rather " +
        "talk to you than have a child stop coming."),
      text: plain(
        "Madrasah fees",
        e.body || `This is a reminder about the madrasah fees for ${e.family ?? "your family"}.`,
        rows,
        "Please quote your reference. Fees can also be paid at the office. " +
        "If this has crossed with a payment you have already made, please " +
        "ignore it. If money is difficult at the moment, ring 01204 535 997 " +
        "and ask - the madrasah would rather talk to you than have a child " +
        "stop coming."),
    };
  }

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

  if (e.kind === "charity_requested") {
    const rows: [string, string][] = [
      ["Date you asked for", `<strong>${esc(longDate(e.booking_date))}</strong>`],
      ["Charity", esc(e.org_name ?? "")],
      ["Reference", `<strong>${esc(ref)}</strong>`],
    ];
    return {
      subject: ascii(`We have your collection request - ${ref}`),
      html: shell(
        "We have your request",
        "Thank you. <strong>This is not a booking yet.</strong> The masjid allows " +
        "one collection a day and will contact the <strong>trustee</strong> you " +
        "named to confirm whether this date can be given.",
        rows,
        "Keep this email — the office will ask for the reference above. Please " +
        "tell your trustee to expect a call. If you need to reach us first, ring " +
        "Rafik Patel on 07951&nbsp;795&nbsp;465."),
      text: plain(
        "We have your request",
        "Thank you. THIS IS NOT A BOOKING YET. The masjid will contact the TRUSTEE " +
        "you named to confirm whether this date can be given.",
        rows,
        "Keep this email — the office will ask for the reference. Please tell your " +
        "trustee to expect a call. Rafik Patel: 07951 795 465."),
    };
  }

  if (e.kind === "admission_requested") {
    const rows: [string, string][] = [
      ["Academic year", `<strong>${esc(e.academic_year ?? "")}</strong>`],
      ["Reference", `<strong>${esc(ref)}</strong>`],
    ];
    return {
      subject: ascii(`We have your madrasah application - ${ref}`),
      html: shell(
        "We have your application",
        "Thank you. <strong>This is not a place yet.</strong> The madrasah " +
        "reviews every application and will contact you about each child you " +
        "applied for.",
        rows,
        "Keep this email &mdash; the office will ask for the reference above. " +
        "If anything you told us changes, particularly anything medical, ring " +
        "the masjid on 01204&nbsp;535&nbsp;997 rather than sending it by email."),
      text: plain(
        "We have your application",
        "Thank you. THIS IS NOT A PLACE YET. The madrasah reviews every " +
        "application and will contact you about each child.",
        rows,
        "Keep this email — the office will ask for the reference. If anything " +
        "changes, particularly anything medical, ring 01204 535 997."),
    };
  }

  if (e.kind === "course_registered") {
    //  THE WAITING LIST IS THE WHOLE REASON THIS EMAIL EXISTS.
    //  A person who has been told nothing assumes they have a place, turns up
    //  on the first night, and is turned away in front of everybody. That is
    //  the failure this prevents, so the two versions of this message say
    //  opposite things and share as little wording as possible.
    const waiting = e.outcome === "waiting";
    const rows: [string, string][] = [
      ["Course", `<strong>${esc(e.course_name ?? "")}</strong>`],
      ["Group", esc(cohortLabel(e.cohort))],
      ["Reference", `<strong>${esc(ref)}</strong>`],
    ];
    return {
      subject: ascii(waiting
        ? `You are on the waiting list - ${e.course_name ?? ""} (${ref})`
        : `Your place is booked - ${e.course_name ?? ""} (${ref})`),
      html: shell(
        waiting ? "You are on the waiting list" : "Your place is booked",
        waiting
          ? "Thank you for registering. <strong>This course is currently full, " +
            "so you do not have a place yet</strong> and should not come to the " +
            "first session unless we contact you. If somebody withdraws we will " +
            "get in touch, and you do not need to do anything in the meantime."
          : "Thank you for registering. <strong>You have a place.</strong> " +
            "There is nothing else to do &mdash; we will be in touch before it starts.",
        rows,
        "Keep this email &mdash; the reference above is how the office finds " +
        "your registration. If you can no longer come, please ring " +
        "01204&nbsp;535&nbsp;997 so somebody else can have the place."),
      text: plain(
        waiting ? "You are on the waiting list" : "Your place is booked",
        waiting
          ? "Thank you for registering. THIS COURSE IS FULL, SO YOU DO NOT HAVE " +
            "A PLACE YET. Please do not come to the first session unless we " +
            "contact you. We will get in touch if somebody withdraws."
          : "Thank you for registering. YOU HAVE A PLACE. We will be in touch " +
            "before it starts.",
        rows,
        "Keep this email — the reference is how the office finds you. If you " +
        "can no longer come, ring 01204 535 997 so somebody else can have the place."),
    };
  }

  if (e.kind === "volunteer_registered") {
    const rows: [string, string][] = [
      ["You can help", esc(frequencyLabel(e.frequency))],
      ["Reference", `<strong>${esc(ref)}</strong>`],
    ];
    return {
      subject: ascii(`Thank you for offering to help - ${ref}`),
      html: shell(
        "Thank you for offering to help",
        "The masjid has your details and somebody will be in touch " +
        `<strong>by ${esc(contactLabel(e.preferred_contact))}</strong>, which is ` +
        "what you asked for. <strong>You are not on the rota yet</strong> " +
        "&mdash; please do not come along until somebody has spoken to you.",
        rows,
        "Keep this email &mdash; the office will ask for the reference above. " +
        "If you change your mind, ring 01204&nbsp;535&nbsp;997 and we will take " +
        "you off the list; there is no obligation at all."),
      text: plain(
        "Thank you for offering to help",
        "The masjid has your details and somebody will be in touch by " +
        contactLabel(e.preferred_contact) + ", which is what you asked for. " +
        "YOU ARE NOT ON THE ROTA YET — please do not come along until somebody " +
        "has spoken to you.",
        rows,
        "Keep this email — the office will ask for the reference. If you change " +
        "your mind, ring 01204 535 997. There is no obligation at all."),
    };
  }

  // A refund is a conversation, not a template. The office rings.
  return null;
}

/* --------------------------------------------------------------------------
   THE STAFF INVITATION

   Kept apart from Event and from officeMessage/publicMessage on purpose. Every
   other message here describes something that already happened and is safe to
   read. This one CARRIES A CREDENTIAL — a link that signs somebody in — and
   that difference should be visible in the code, not buried in a union.

   Two things this email must do that the others need not:

     1. Say who sent it and why, by name. A bare "you have been invited, click
        here" is the exact shape of a phishing email, and telling masjid
        volunteers to click those is how a charity loses its accounts. The name
        of the administrator who did it is the one thing an attacker who does
        not already have the database cannot supply.

     2. Tell them what to do if they were NOT expecting it. That sentence costs
        one line and is the only thing standing between a mis-typed address and
        somebody quietly accepting an administrator account.

   There is deliberately no plain "reply to confirm" instruction: noreply@ is
   an unread mailbox. It points at the masjid's phone number instead.
   -------------------------------------------------------------------------- */

export interface Invite {
  name: string;          // who the invitation is for
  link: string;          // the one-time sign-in link
  invitedBy: string;     // the administrator who created it, by name
  says: string[];        // what they will be able to do, in plain English
  existing: boolean;     // true when the address already had an account
  reset?: boolean;       // true when this is ONLY a password reset
}

/* A RESET IS NOT AN INVITATION, and saying so matters. The recovery link
   Supabase hands back is identical either way, so it would have been easy to
   reuse the invitation wording — but that email says somebody "has given your
   existing account access", which for a plain reset is simply untrue. Being
   told you have been given access you already had is the sort of small wrong
   thing that makes a person distrust the whole message, which is exactly the
   instinct this email needs them to keep. */

export function staffInviteMessage(i: Invite): Message {
  const rows: [string, string][] = i.reset
    ? [["For", `<strong>${esc(i.name)}</strong>`],
       ["Sent by", esc(i.invitedBy)]]
    : [["For", `<strong>${esc(i.name)}</strong>`],
       ["Given by", esc(i.invitedBy)],
       ["You will be able to see", esc(i.says.join(", "))]];

  const lead = i.reset
    ? `<strong>${esc(i.invitedBy)}</strong> at Taiyabah Masjid has sent you a ` +
      "link to set a new password for the masjid&rsquo;s portal. Nobody at the " +
      "masjid can see your password, and nobody has changed it &mdash; this only " +
      "lets you choose a new one."
    : i.existing
    ? `<strong>${esc(i.invitedBy)}</strong> at Taiyabah Masjid has given your ` +
      "existing account access to the masjid&rsquo;s portal. Use the button below " +
      "to set a new password and sign in."
    : `<strong>${esc(i.invitedBy)}</strong> at Taiyabah Masjid has set up an ` +
      "account for you on the masjid&rsquo;s portal. Use the button below to " +
      "choose a password and sign in.";

  const footer =
    "This link works <strong>once</strong> and stops working after 24 hours. " +
    "You will be asked to set up an authenticator app the first time you sign " +
    "in &mdash; you get nothing until you do, and that is deliberate.<br><br>" +
    "<strong>If you were not expecting this, do not use the link.</strong> " +
    "Ring the masjid on 01204&nbsp;535&nbsp;997 and say you received it.";

  const heading = i.reset
    ? "Set a new password"
    : i.existing ? "Access to the masjid portal" : "An account has been set up for you";

  return {
    subject: i.reset
      ? "Set a new Taiyabah Masjid password"
      : "Your Taiyabah Masjid portal account",
    html: shell(heading, lead, rows, footer,
      { href: i.link,
        label: i.reset || i.existing ? "Set a new password" : "Set your password" }),
    text: plain(heading,
      (i.reset
        ? `${i.invitedBy} at Taiyabah Masjid has sent you a link to set a new password. Nobody has changed it and nobody can see it.`
        : i.existing
          ? `${i.invitedBy} at Taiyabah Masjid has given your existing account access to the masjid portal.`
          : `${i.invitedBy} at Taiyabah Masjid has set up an account for you on the masjid portal.`) +
      " Open the link below to set a password and sign in.",
      rows, footer.replace(/<br><br>/g, "\n\n"), i.link),
  };
}
