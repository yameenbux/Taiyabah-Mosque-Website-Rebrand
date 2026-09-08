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
  longDate, money, whatWasHired, slotLabel, esc,
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
  assertStringIncludes(m.subject, "ACTION NEEDED");
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
