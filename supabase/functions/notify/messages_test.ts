/* ===========================================================================
   deno test supabase/functions/notify/messages_test.ts

   messages.ts is pure, so this runs with no network, no mail provider and no
   Edge Function. It exists because the last version of the booking email went
   eleven days out of date without anybody noticing: it read `session_slot`,
   `hall` and `kitchen`, which migration 014 retired, and would have emailed
   the office "Slot: undefined" for every booking. Nothing tested it.
   =========================================================================== */
// Three assertions, written here rather than imported. The standard library
// would be a network fetch every time somebody runs the tests, and a test
// suite that cannot run offline is a test suite that stops being run.
function assert(cond: unknown, msg = "assertion failed"): void {
  if (!cond) throw new Error(msg);
}
function assertEquals<T>(got: T, want: T, msg?: string): void {
  const a = JSON.stringify(got), b = JSON.stringify(want);
  if (a !== b) throw new Error(msg ?? `expected ${b}\n     got ${a}`);
}
function assertStringIncludes(got: string, want: string, msg?: string): void {
  if (!got.includes(want)) {
    throw new Error(msg ?? `expected to find ${JSON.stringify(want)}`);
  }
}

import {
  type Event, officeMessage, publicMessage,
  longDate, shortDate, money, whatWasHired, slotLabel, esc, ascii,
} from "./messages.ts";

const HALL: Event = {
  kind: "deposit_paid",
  reference: "HH-26-0007",
  booking_date: "2026-09-26",
  hire_type: "halls",
  halls_count: 2,
  name: "Imran Ali",
  phone: "07700 900111",
  email: "imran@example.test",
  amount_p: 10000,
  portal: "https://example.test/venue/",
};

const NIKAH: Event = {
  kind: "nikah_requested",
  reference: "NK-26-0004",
  booking_date: "2026-10-03",
  slot: "after_zuhr",
  name: "Yusuf Patel",
  phone: "07700 900555",
  email: "yusuf@example.test",
  portal: "https://example.test/venue/",
};

/* -------------------------------------------------------- formatting ---- */

Deno.test("a date renders as the day it actually is", () => {
  // Built from parts on purpose. new Date("2026-09-26") is parsed as UTC and
  // renders as the 25th anywhere west of Greenwich — which in Bolton means
  // every booking looks a day early through the winter.
  // The parts, not the punctuation. Whether the locale puts a comma after the
  // weekday varies between ICU versions, and pinning it makes the test fail on
  // a Deno upgrade rather than on a real fault. What matters is the DAY: the
  // 26th, not the 25th.
  const d = longDate("2026-09-26");
  assertStringIncludes(d, "Saturday");
  assertStringIncludes(d, "26 September 2026");
});

Deno.test("a missing or malformed date does not become 'Invalid Date'", () => {
  assertEquals(longDate(null), "(no date)");
  assertEquals(longDate("not a date"), "not a date");
});

Deno.test("money is money", () => {
  assertEquals(money(10000), "£100");
  assertEquals(money(15450), "£154.50");
  assertEquals(money(null), "");
});

Deno.test("what was hired matches the CURRENT model, not the retired one", () => {
  // If this ever mentions a session or a hall number, somebody has resurrected
  // the pre-014 model. Hire is by the day, priced by how many halls.
  assertEquals(whatWasHired({ kind: "deposit_paid", hire_type: "halls", halls_count: 2 }),
               "2 halls · kitchen and cleaning included · whole day");
  assertEquals(whatWasHired({ kind: "deposit_paid", hire_type: "halls", halls_count: 1 }),
               "1 hall · kitchen and cleaning included · whole day");
  assertEquals(whatWasHired({ kind: "deposit_paid", hire_type: "kitchen_only" }),
               "Kitchen only · whole day");
});

Deno.test("a prayer slot is named, not printed raw", () => {
  assertEquals(slotLabel("after_zuhr"), "After Zuhr");
  assertEquals(slotLabel("saturday_11"), "Saturday 11:00am");
  assertEquals(slotLabel(null), "");
});

Deno.test("names are escaped, so a quote mark cannot break the email", () => {
  const m = officeMessage({ ...HALL, name: 'Sara "B" <script>' })!;
  assert(!m.html.includes("<script>"), "an unescaped tag reached the HTML");
  assertStringIncludes(m.html, "&lt;script&gt;");
  assertEquals(esc('a & b'), "a &amp; b");
});

/* ------------------------------------------------- the office's emails --- */

Deno.test("deposit paid: says the date is SOLD, not that it needs agreeing", () => {
  const m = officeMessage(HALL)!;
  assertStringIncludes(m.subject, "HH-26-0007");
  assertStringIncludes(m.html, "confirmed");
  assertStringIncludes(m.html, "26 September 2026");
  assertStringIncludes(m.html, "2 halls");
  assertStringIncludes(m.html, "07700 900111");
  // The old email said "nothing is booked until somebody confirms it". After
  // migration 017 that is false, and telling the office it is false is how a
  // date gets sold twice.
  assert(!/nothing is booked/i.test(m.html), "the pre-017 wording is back");
  assert(!/not held/i.test(m.html), "says the date is not held, which it is");
});

Deno.test("refund due: shouts, because it is the one nobody must skim past", () => {
  const m = officeMessage({
    ...HALL, kind: "refund_due", amount_p: 10000,
    reason: "Paid twice — the first payment is the one on file",
  })!;
  assertStringIncludes(m.subject, "ATTENTION REQUIRED");
  assertStringIncludes(m.subject, "HH-26-0007");
  assertStringIncludes(m.html, "£100");
  assertStringIncludes(m.html, "Paid twice");
  assertStringIncludes(m.text, "NOTHING");   // nothing happens until a human acts
});

Deno.test("nikāḥ requested: calls it a request, never a booking", () => {
  const m = officeMessage(NIKAH)!;
  assertStringIncludes(m.subject, "NK-26-0004");
  assertStringIncludes(m.html, "After Zuhr");
  assertStringIncludes(m.html, "request");
  assert(!/is booked|confirmed/i.test(m.html),
         "a nikāḥ request is described as booked or confirmed");
});

Deno.test("nikāḥ fee paid: says plainly that money does NOT agree a date", () => {
  const m = officeMessage({ ...NIKAH, kind: "nikah_fee_paid", amount_p: 20000 })!;
  assertStringIncludes(m.html, "does not agree the date");
  assertStringIncludes(m.html, "£200");
});

Deno.test("NO EMAIL EVER CONTAINS THE HIRER'S ADDRESS", () => {
  // The single rule this whole file exists to keep. The address is the most
  // sensitive thing on the form and useless for ringing somebody back; it
  // lives in the portal and nowhere else.
  const withAddress = { ...HALL } as Event & { address: string };
  withAddress.address = "12 Astley Street, Bolton";
  for (const kind of ["deposit_paid", "refund_due", "nikah_requested", "nikah_fee_paid"] as const) {
    const o = officeMessage({ ...withAddress, kind });
    const p = publicMessage({ ...withAddress, kind });
    for (const m of [o, p]) {
      if (!m) continue;
      assert(!m.html.includes("Astley Street"), `${kind}: address leaked into the HTML`);
      assert(!m.text.includes("Astley Street"), `${kind}: address leaked into the text`);
    }
  }
});

/* -------------------------------------------------- the public's email --- */

Deno.test("the hirer is told the date is theirs, and to keep the reference", () => {
  const m = publicMessage(HALL)!;
  assertStringIncludes(m.subject, "confirmed");
  assertStringIncludes(m.html, "HH-26-0007");
  assertStringIncludes(m.html, "the date is yours");
  assertStringIncludes(m.html, "Keep this email");
  assertStringIncludes(m.html, "30 days");
});

Deno.test("the nikāḥ family is told NOT to pay until a date is agreed", () => {
  const m = publicMessage(NIKAH)!;
  assertStringIncludes(m.html, "not a booking yet");
  assertStringIncludes(m.html, "do not pay anything until");
  assertStringIncludes(m.html, "NK-26-0004");
});

Deno.test("nothing is sent to somebody who gave no address", () => {
  assertEquals(publicMessage({ ...HALL, email: null }), null);
  assertEquals(publicMessage({ ...NIKAH, email: undefined }), null);
});

Deno.test("nothing is sent without a reference to quote", () => {
  assertEquals(publicMessage({ ...HALL, reference: null }), null);
});

Deno.test("a refund is a conversation, so no template is sent to the payer", () => {
  assertEquals(publicMessage({ ...HALL, kind: "refund_due" }), null);
});

/* ---------------------------------------------------- subject lines ----- */

Deno.test("EVERY SUBJECT IS PURE ASCII", () => {
  // The first live alert arrived showing
  //   =?utf-8?Q?Nik=c4=81=e1=b8=a5 date requested =e2=80=94 Sunday 27 Sep...
  // because the subject held ā, ḥ and an em dash. Non-ASCII must be MIME
  // encoded, RFC 2047 caps one encoded-word at 75 characters, the result was
  // 78, and the client gave up and printed the raw encoding.
  //
  // Body text is not affected and is not checked here — it is HTML with a
  // charset, so the masjid's own words render properly there.
  const events: Event[] = [
    HALL, { ...HALL, kind: "refund_due" }, NIKAH,
    { ...NIKAH, kind: "nikah_fee_paid", amount_p: 10000 },
  ];
  for (const e of events) {
    for (const m of [officeMessage(e), publicMessage(e)]) {
      if (!m) continue;
      const bad = [...m.subject].filter((c) => c.charCodeAt(0) > 126);
      assert(bad.length === 0,
        `non-ASCII in subject ${JSON.stringify(m.subject)}: ` +
        bad.map((c) => `U+${c.charCodeAt(0).toString(16)}`).join(" "));
    }
  }
});

Deno.test("no subject is long enough to be truncated", () => {
  // Most clients show around 70 characters. Past that the reference — the one
  // thing the office needs to quote — falls off the end.
  const events: Event[] = [
    HALL, { ...HALL, kind: "refund_due" }, NIKAH,
    { ...NIKAH, kind: "nikah_fee_paid", amount_p: 10000 },
  ];
  for (const e of events) {
    for (const m of [officeMessage(e), publicMessage(e)]) {
      if (!m) continue;
      assert(m.subject.length <= 72,
        `subject is ${m.subject.length} chars: ${m.subject}`);
    }
  }
});

Deno.test("ATTENTION REQUIRED means a human must act, and only then", () => {
  // If everything shouts, nothing does. Only the two that need somebody to
  // pick up a phone or issue a refund carry it.
  const shouts = (e: Event) => (officeMessage(e)?.subject ?? "").includes("ATTENTION REQUIRED");
  assert(shouts(NIKAH), "a nikah request does not flag that somebody must ring");
  assert(shouts({ ...HALL, kind: "refund_due" }), "a refund owed does not flag for attention");
  assert(!shouts(HALL), "a paid deposit shouts, but nobody has to do anything");
  assert(!shouts({ ...NIKAH, kind: "nikah_fee_paid" }), "a paid fee shouts unnecessarily");
});

Deno.test("a nikah request subject says REQUEST, never booking", () => {
  // The office reads the subject and acts on it. Calling a request a booking
  // in the subject undoes what the whole email exists to say.
  const sub = officeMessage(NIKAH)!.subject.toLowerCase();
  assertStringIncludes(sub, "request");
  assert(!sub.includes("booking"), `subject calls it a booking: ${sub}`);
});

Deno.test("the reference is in every subject that has one", () => {
  assertStringIncludes(officeMessage(HALL)!.subject, "HH-26-0007");
  assertStringIncludes(officeMessage(NIKAH)!.subject, "NK-26-0004");
  assertStringIncludes(publicMessage(HALL)!.subject, "HH-26-0007");
  assertStringIncludes(publicMessage(NIKAH)!.subject, "NK-26-0004");
});

Deno.test("ascii() flattens what a subject cannot carry", () => {
  assertEquals(ascii("Nikāḥ — 'quoted' “curly”"), "Nikah - 'quoted' \"curly\"");
  assertEquals(ascii("plain text"), "plain text");
});

Deno.test("the short date is short, and still the right day", () => {
  // Not the exact month spelling — en-GB gives "Sep" on some ICU versions and
  // "Sept" on others, and pinning it makes this fail on a Deno upgrade rather
  // than on a real fault. What matters is the DAY and that it stays short.
  const d = shortDate("2026-09-26");
  assertStringIncludes(d, "26");
  assertStringIncludes(d, "2026");
  assert(/^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)/.test(d), `no weekday: ${d}`);
  assert(d.length <= 18, `short date is ${d.length} chars: ${d}`);
  // And it must be the 26th, not the 25th — the UTC off-by-one again.
  assert(!d.includes("25"), `off by one: ${d}`);
});

/* ------------------------------------------------------ the digest ----- */

const DIGEST: Event = {
  kind: "digest",
  new_nikah: 2, oldest_nikah_days: 9,
  refunds_due: 1, balances_due: 3, this_week: 2,
  portal: "https://example.test/venue/",
};

Deno.test("the digest leads with refunds — somebody else's money", () => {
  const m = officeMessage(DIGEST)!;
  assertStringIncludes(m.subject, "refund");
  assertStringIncludes(m.subject, "ATTENTION REQUIRED");
  assertStringIncludes(m.html, "cannot keep");
});

Deno.test("it says how long the oldest request has waited", () => {
  // "2 requests" is easy to assume somebody else has handled. "waiting 9 days"
  // is not. This is the whole answer to a shared inbox.
  const m = officeMessage(DIGEST)!;
  assertStringIncludes(m.html, "9 days");
});

Deno.test("it counts one day as a day, not 1 days", () => {
  const m = officeMessage({ ...DIGEST, refunds_due: 0, new_nikah: 1,
                            oldest_nikah_days: 1 })!;
  assertStringIncludes(m.html, "1 day");
  assert(!m.html.includes("1 days"), "said '1 days'");
  assertStringIncludes(m.subject, "1 nikah request waiting");
});

Deno.test("a quiet-ish week does not shout", () => {
  // Balances are a chore, not an emergency. Nobody has to act today.
  const m = officeMessage({ kind: "digest", new_nikah: 0, refunds_due: 0,
                            balances_due: 2, this_week: 1 })!;
  assert(!m.subject.includes("ATTENTION REQUIRED"),
         `balances alone should not shout: ${m.subject}`);
  assertStringIncludes(m.subject, "2 balances due");
});

Deno.test("what is not outstanding is not listed at all", () => {
  // An email full of zeroes teaches people it says nothing.
  const m = officeMessage({ kind: "digest", new_nikah: 0, refunds_due: 0,
                            balances_due: 2, this_week: 1 })!;
  assert(!/refunds owed/i.test(m.html), "listed refunds when there are none");
  assert(!/unanswered/i.test(m.html), "listed nikah requests when there are none");
});

Deno.test("THE DIGEST CARRIES NO PERSONAL DATA", () => {
  // It is counts and nothing else. Names, phones and references live in the
  // portal; an email that travels through a mail server should not carry them
  // when a number will do.
  const m = officeMessage({ ...DIGEST,
    // deliberately smuggled in — they must be ignored
    name: "Yusuf Patel", phone: "07700 900555",
    reference: "NK-26-0004", email: "yusuf@example.test" } as Event)!;
  for (const leak of ["Yusuf", "07700", "NK-26-0004", "yusuf@"]) {
    assert(!m.html.includes(leak), `digest leaked ${leak}`);
    assert(!m.text.includes(leak), `digest leaked ${leak} into the text`);
    assert(!m.subject.includes(leak), `digest leaked ${leak} into the subject`);
  }
});

Deno.test("the digest subject is ASCII and short like the others", () => {
  for (const e of [DIGEST, { kind: "digest", balances_due: 2 } as Event]) {
    const m = officeMessage(e)!;
    assert([...m.subject].every((c) => c.charCodeAt(0) <= 126),
           `non-ASCII: ${m.subject}`);
    assert(m.subject.length <= 72, `${m.subject.length} chars: ${m.subject}`);
  }
});

Deno.test("nothing is sent to the public in a digest", () => {
  assertEquals(publicMessage(DIGEST), null);
});

/* ------------------------------------------------------------ shape ----- */

Deno.test("every message has all three parts, and the text one is readable", () => {
  const events: Event[] = [
    HALL,
    { ...HALL, kind: "refund_due" },
    NIKAH,
    { ...NIKAH, kind: "nikah_fee_paid", amount_p: 10000 },
  ];
  for (const e of events) {
    for (const m of [officeMessage(e), publicMessage(e)]) {
      if (!m) continue;
      assert(m.subject.length > 5, "subject too short");
      assert(m.html.includes("Taiyabah Masjid"), "no masjid name in the HTML");
      assert(m.text.includes("01204 535 997"), "no phone number in the plain text");
      // A plain-text part with HTML in it is worse than no plain-text part.
      assert(!/<[a-z][^>]*>/i.test(m.text), `HTML leaked into the text of: ${m.subject}`);
    }
  }
});

Deno.test("an unknown kind sends nothing rather than an empty email", () => {
  // deno-lint-ignore no-explicit-any
  assertEquals(officeMessage({ kind: "something_else" as any }), null);
});
