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
  type Event, officeMessage, publicMessage, staffInviteMessage,
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
  for (const kind of ["deposit_paid", "refund_due", "nikah_requested",
                      "nikah_fee_paid", "charity_requested"] as const) {
    const o = officeMessage({ ...withAddress, kind });
    const p = publicMessage({ ...withAddress, kind });
    for (const m of [o, p]) {
      if (!m) continue;
      assert(!m.html.includes("Astley Street"), `${kind}: address leaked into the HTML`);
      assert(!m.text.includes("Astley Street"), `${kind}: address leaked into the text`);
    }
  }
});

/* ------------------------------------------------ charity collections --- */

const CHANDA: Event = {
  kind: "charity_requested",
  reference: "CC-26-0042",
  booking_date: "2026-10-30",
  org_name: "Testville Relief Trust",
  name: "A Collector",
  phone: "07000 000000",
  email: "office@example.test",
  charity_number: "1041569",
  collector_paid: false,
  portal: "https://example.test/collections/",
};

Deno.test("the office is told it is a REQUEST and who to ring", () => {
  const m = officeMessage(CHANDA)!;
  // "booking" in the subject and the office starts treating it as one. The
  // masjid allows one collection a day and the website is never told which
  // days are taken, so nothing here has reserved anything.
  assertStringIncludes(m.subject, "request");
  assert(!/booking/i.test(m.subject), "the subject calls a request a booking");
  assertStringIncludes(m.html, "Testville Relief Trust");
  assertStringIncludes(m.html, "CC-26-0042");
  // The masjid rings the TRUSTEE, not the collector. That is the whole point
  // of asking for a trustee, and the email has to say so.
  assertStringIncludes(m.html, "trustee");
  assertStringIncludes(m.text, "TRUSTEE");
});

Deno.test("A PAID COLLECTOR IS IN THE SUBJECT LINE", () => {
  // On the paper form this is a tick in a box on page one that nobody reads
  // twice. Somebody opening this on a phone should see it before they open it.
  const m = officeMessage({ ...CHANDA, collector_paid: true })!;
  assertStringIncludes(m.subject, "PAID COLLECTOR");
  assertStringIncludes(m.html, "YES");
  assertStringIncludes(m.text, "PAID");

  const no = officeMessage(CHANDA)!;
  assert(!/PAID COLLECTOR/.test(no.subject),
    "an unpaid collector is being announced as paid");
});

Deno.test("NO EMAIL CARRIES THE TRUSTEE'S DETAILS", () => {
  // The trustee did not fill this form in and has not agreed to anything.
  // They are rung from the portal, where the outcome is recorded anyway — so
  // a forwarded email must not carry their number. Same rule as the hirer's
  // address. The Event type has no trustee field at all; this proves that
  // stays true if somebody adds one.
  const leaky = { ...CHANDA } as Event & Record<string, unknown>;
  leaky.trustee_name = "A Trustee";
  leaky.trustee_phone = "07999 999999";
  leaky.trustee_email = "trustee@example.test";
  const m = officeMessage(leaky)!;
  for (const secret of ["A Trustee", "07999 999999", "trustee@example.test"]) {
    assert(!m.html.includes(secret), `the trustee's ${secret} leaked into the HTML`);
    assert(!m.text.includes(secret), `the trustee's ${secret} leaked into the text`);
  }
});

Deno.test("a missing charity number says so rather than showing a blank", () => {
  const m = officeMessage({ ...CHANDA, charity_number: null })!;
  assertStringIncludes(m.html, "not given");
});

/*  The collector's own acknowledgement.

    This branch was LIVE AND UNTESTED for a day: it existed in the deployed
    function and not in this repository, so nothing here covered it and a
    redeploy from the repo would have deleted it silently. These four tests
    are what stop that happening a second time. */

Deno.test("the collector is told this is NOT a booking", () => {
  const m = publicMessage(CHANDA)!;
  assertStringIncludes(m.html, "not a booking yet");
  assertStringIncludes(m.text, "NOT A BOOKING YET");
  assert(!/^.*\bbooked\b/i.test(m.subject), "the subject says booked");
  assertStringIncludes(m.html, "CC-26-0042");
});

Deno.test("the collector is given Rafik Patel's number and nobody else's", () => {
  // The masjid asked for exactly one number on this form. The office landline
  // is answered by whoever is in; a charity ringing from abroad about a
  // collection needs the person who actually deals with them.
  //
  // The landline still appears in the address block at the foot of every
  // email — that is the masjid's address, not an instruction. What must not
  // happen is being TOLD to ring it, the way the nikāḥ and hall emails do.
  const m = publicMessage(CHANDA)!;
  assertStringIncludes(m.html, "Rafik Patel");
  assertStringIncludes(m.html, "07951");
  assertStringIncludes(m.text, "07951 795 465");
  assert(!/ring[^.]*01204/i.test(m.html) && !/ring[^.]*01204/i.test(m.text),
    "the collector is being told to ring the office landline");
  assert(!/questions:\s*01204/i.test(m.text),
    "the collector is being pointed at the office landline for questions");

  // CONTROL — the nikāḥ acknowledgement really does point at the landline,
  // so the two assertions above are capable of failing.
  const nk = publicMessage(NIKAH)!;
  assert(/ring[^.]*01204/i.test(nk.html),
    "this test cannot bite: nothing points at the landline anywhere");
});

Deno.test("the collector's email does not carry the trustee either", () => {
  const leaky = { ...CHANDA } as Event & Record<string, unknown>;
  leaky.trustee_name = "A Trustee";
  leaky.trustee_phone = "07999 999999";
  leaky.trustee_email = "trustee@example.test";
  const m = publicMessage(leaky)!;
  for (const secret of ["A Trustee", "07999 999999", "trustee@example.test"]) {
    assert(!m.html.includes(secret), `the trustee's ${secret} leaked to the collector`);
    assert(!m.text.includes(secret), `the trustee's ${secret} leaked to the collector`);
  }
  // It must still TELL them a trustee will be rung — that is the one thing
  // that stops them being surprised by the call.
  assertStringIncludes(m.html, "trustee");
});

Deno.test("no acknowledgement is sent when there is no address or reference", () => {
  // publicMessage is the only thing standing between a blank org_email and an
  // attempt to send mail to "".
  assertEquals(publicMessage({ ...CHANDA, email: null }), null);
  assertEquals(publicMessage({ ...CHANDA, reference: null }), null);
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

/* ===========================================================================
   THE STAFF INVITATION

   This is the only email the masjid sends that carries a credential, so what
   is tested here is not "does it render" but "does it contain the things that
   stop it working as a phishing email".
   =========================================================================== */
const INV = {
  name: "Abu Bakr Siddique",
  link: "https://phenbhmobxwyvdeshvqw.supabase.co/auth/v1/verify?token=abc&type=invite",
  invitedBy: "Yameen Bux",
  says: ["Hall bookings and nikah"],
  existing: false,
};

Deno.test("the invitation names the administrator who sent it", () => {
  const m = staffInviteMessage(INV);
  assertStringIncludes(m.html, "Yameen Bux");
  assertStringIncludes(m.text, "Yameen Bux");
});

Deno.test("it tells somebody who was NOT expecting it what to do", () => {
  const m = staffInviteMessage(INV);
  // Both parts, because a recipient reading the plain-text alternative is
  // exactly the sort of person whose client strips HTML — and they need this
  // sentence more than anyone.
  assertStringIncludes(m.html.toLowerCase(), "if you were not expecting this");
  assertStringIncludes(m.text.toLowerCase(), "if you were not expecting this");
  assertStringIncludes(m.html, "01204");
  assertStringIncludes(m.text, "01204");
});

Deno.test("the link is in both the HTML and the plain text", () => {
  const m = staffInviteMessage(INV);
  // ESCAPED in the HTML. The link carries a query string, so the ampersand
  // before `type=invite` becomes `&amp;` in the href — which is correct, and
  // which the first version of this test got wrong by looking for the raw
  // string and failing. Worth keeping the note: a test that looks for the
  // unescaped form would have to be "fixed" by removing the escaping.
  assertStringIncludes(m.html, esc(INV.link));
  assert(!m.html.includes("token=abc&type"), "the href is not HTML-escaped");
  // RAW in the plain text, where there is nothing to escape and a mangled
  // ampersand would give somebody a link that does not work.
  assertStringIncludes(m.text, INV.link);
});

Deno.test("it says the link is single use and expires", () => {
  const m = staffInviteMessage(INV);
  assertStringIncludes(m.html.toLowerCase(), "24 hours");
  assertStringIncludes(m.html.toLowerCase(), "once");
});

Deno.test("an existing account is told to set a NEW password, not that one was created", () => {
  const fresh = staffInviteMessage(INV);
  const again = staffInviteMessage({ ...INV, existing: true });
  assertStringIncludes(again.html.toLowerCase(), "existing account");
  assertStringIncludes(again.html.toLowerCase(), "new password");
  // Telling somebody who already has an account that one "has been set up for
  // you" reads as a second account and gets ignored. The two must differ.
  assert(fresh.html !== again.html, "the two versions are identical");
  assert(!again.html.includes("has set up an account for you"),
    "an existing account is being told a new one was created");
});

Deno.test("a name with HTML in it cannot break out of the email", () => {
  const m = staffInviteMessage({ ...INV, name: '<script>x</script>' });
  assert(!m.html.includes("<script>"), "unescaped markup reached the HTML body");
  assertStringIncludes(m.html, "&lt;script&gt;");
});

Deno.test("the subject is ASCII and short, like every other one", () => {
  const s = staffInviteMessage(INV).subject;
  // deno-lint-ignore no-control-regex
  assert(/^[\x20-\x7E]*$/.test(s), `not ASCII: ${s}`);
  assert(s.length <= 78, `too long: ${s.length}`);
});

Deno.test("CONTROL — these assertions bite", () => {
  // An unchecked control certifies nothing. Each of these proves that the
  // matching test above would actually fail if the message lost the thing it
  // is checking for, rather than passing because the string happened to be
  // somewhere else in a 3kB template.
  const m = staffInviteMessage(INV);
  const withoutWarning = m.html.replace(/If you were not expecting this/i, "Enjoy");
  assert(withoutWarning !== m.html, "the control did not change the HTML");
  assert(!withoutWarning.toLowerCase().includes("if you were not expecting this"),
    "the warning appears more than once, so the test would pass without it");

  const withoutName = m.html.split("Yameen Bux").join("somebody");
  assert(withoutName !== m.html, "the control did not change the HTML");
  assert(!withoutName.includes("Yameen Bux"));

  const withoutLink = m.html.split(esc(INV.link)).join("#");
  assert(withoutLink !== m.html, "the control did not change the HTML");
  assert(!withoutLink.includes(esc(INV.link)));

  const textWithoutLink = m.text.split(INV.link).join("#");
  assert(textWithoutLink !== m.text, "the control did not change the plain text");
});

/* ===========================================================================
   A RESET IS NOT AN INVITATION
   =========================================================================== */
Deno.test("a reset does not claim somebody has been given access", () => {
  const m = staffInviteMessage({ ...INV, existing: true, reset: true });
  assert(!m.html.includes("has given your existing account access"),
    "a plain password reset tells the person they have been given access they already had");
  assert(!m.text.includes("has given your existing account access"));
  assertStringIncludes(m.html.toLowerCase(), "set a new password");
  assertStringIncludes(m.subject.toLowerCase(), "password");
});

Deno.test("a reset says nobody at the masjid can see the password", () => {
  const m = staffInviteMessage({ ...INV, existing: true, reset: true });
  // The sentence that stops somebody ringing the office to ask what their
  // password is, and stops an administrator feeling able to answer.
  assertStringIncludes(m.html.toLowerCase(), "nobody at the masjid can see your password");
  assertStringIncludes(m.text.toLowerCase(), "nobody can see it");
});

Deno.test("a reset does not list what they can do", () => {
  // A reset is about one thing. Listing somebody's roles in it invites the
  // reading that their access has changed, which it has not.
  const m = staffInviteMessage({ ...INV, existing: true, reset: true });
  assert(!m.html.includes("You will be able to see"),
    "the reset email lists roles, implying access has changed");
});

Deno.test("CONTROL — the reset wording really is different", () => {
  const invite = staffInviteMessage({ ...INV, existing: true, reset: false });
  const reset  = staffInviteMessage({ ...INV, existing: true, reset: true });
  assert(invite.html !== reset.html, "reset and invitation render identically");
  assert(invite.subject !== reset.subject, "reset and invitation share a subject line");
  // And the invitation still says the thing the reset must not.
  assertStringIncludes(invite.html, "has given your existing account access");
});

/* ===========================================================================
   THE THREE FORMS THAT TOLD NOBODY

   15 September 2026. Found by asking, of every anon-callable function that
   writes a row, "and then who is told?" — the question that was not asked
   before the charity collection form went live.

   The answer for madrasah admissions, course registrations and foodbank
   volunteers was nobody. Not the office, not the person who filled it in.
   Three forms, live, writing rows into tables that only get looked at if
   somebody thinks to look.

   These tests are mostly about what must NOT be in an email. The madrasah
   application is the sharp one: it carries children's dates of birth,
   schools, SEND status, EHCP, allergies and medical conditions, and none of
   that may be handed to a mail provider or sit in a shared inbox.
   =========================================================================== */

const ADMISSION: Event = {
  kind: "admission_requested",
  reference: "AD-26-0003",
  academic_year: "2026/27",
  name: "Parent Name",
  phone: "07000 000000",
  email: "parent@example.test",
  portal: "https://example.test/apply/",
};

Deno.test("NO CHILD'S DETAILS ARE IN EITHER ADMISSION EMAIL", () => {
  // The Event type has no field for a child at all. This proves that stays
  // true if somebody adds one and starts filling it in.
  const leaky = { ...ADMISSION } as Event & Record<string, unknown>;
  leaky.child_name = "A Child";
  leaky.date_of_birth = "2018-04-02";
  leaky.school_name = "Somewhere Primary";
  leaky.has_send = true;
  leaky.allergy_detail = "peanuts";
  leaky.medical_conditions = "asthma";
  leaky.address_line1 = "12 Astley Street";
  //  NOT the masjid's own postcode. The first version of this test used
  //  BL1 8HD and failed, because every email's footer carries the masjid's
  //  address — the test was wrong, not the code. A fake secret has to be one
  //  that cannot appear legitimately.
  leaky.postcode = "ZZ99 9ZZ";

  const secrets = ["A Child", "2018-04-02", "Somewhere Primary",
                   "peanuts", "asthma", "Astley Street", "ZZ99 9ZZ"];

  for (const m of [officeMessage(leaky)!, publicMessage(leaky)!]) {
    for (const secret of secrets) {
      assert(!m.html.includes(secret), `"${secret}" leaked into an admission email`);
      assert(!m.text.includes(secret), `"${secret}" leaked into an admission email`);
    }
  }

  //  CONTROL — the search itself works. If `includes` were somehow always
  //  false the loop above would pass on an email that printed everything.
  const proof = officeMessage(ADMISSION)!;
  assert(proof.html.includes("Parent Name"),
    "this test cannot bite: the search finds nothing even when it is there");
});

Deno.test("the office admission email says the children are NOT in it", () => {
  // Not decoration. Somebody who expects the details in the email and cannot
  // find them will forward it asking for them, which is the thing this avoids.
  const m = officeMessage(ADMISSION)!;
  assertStringIncludes(m.html, "not in this email");
  assertStringIncludes(m.text, "NOT IN");
  assertStringIncludes(m.html, "AD-26-0003");
  assertStringIncludes(m.html, "2026/27");
});

Deno.test("the parent is told this is NOT a place yet", () => {
  const m = publicMessage(ADMISSION)!;
  assertStringIncludes(m.html, "not a place yet");
  assertStringIncludes(m.text, "NOT A PLACE YET");
  assert(!/\boffered?\b|\baccepted\b/i.test(m.html),
    "the acknowledgement implies a place has been given");
});

const COURSE: Event = {
  kind: "course_registered",
  reference: "CR-26-0011",
  course_name: "Arabic Classes",
  cohort: "womens",
  outcome: "place",
  name: "A Learner",
  phone: "07000 000000",
  email: "learner@example.test",
  portal: "https://example.test/courses/",
};
const WAITING: Event = { ...COURSE, outcome: "waiting" };

Deno.test("A WAITING-LIST REGISTRATION NEVER SAYS A PLACE IS BOOKED", () => {
  // The failure this prevents: somebody told nothing, or told the wrong
  // thing, turns up on the first night and is sent home in front of the room.
  const m = publicMessage(WAITING)!;
  assertStringIncludes(m.subject, "waiting list");
  assert(!/place is booked|you have a place/i.test(m.subject + m.html + m.text),
    "a waiting-list registration claims a place");
  assertStringIncludes(m.html, "do not have a place yet");
  assertStringIncludes(m.html, "should not come to the first session");

  // CONTROL — a real place really does say so, so the assertion can fail.
  const ok = publicMessage(COURSE)!;
  assertStringIncludes(ok.subject, "Your place is booked");
  assertStringIncludes(ok.html, "You have a place");
  assert(!/waiting list/i.test(ok.subject), "a confirmed place says waiting list");
});

Deno.test("the office sees WAITING LIST in the subject, not buried", () => {
  assertStringIncludes(officeMessage(WAITING)!.subject, "WAITING LIST");
  assert(!/WAITING LIST/.test(officeMessage(COURSE)!.subject),
    "a confirmed place is announced as a waiting-list entry");
});

Deno.test("the course cohort is words, not a database key", () => {
  assertStringIncludes(officeMessage(COURSE)!.html, "Women's");
  assert(!officeMessage(COURSE)!.html.includes(">womens<"),
    "the raw cohort key is being shown to a person");
  // An unknown key falls back to itself rather than vanishing — a blank row
  // reads as "none", which is worse than something that looks wrong.
  assertStringIncludes(officeMessage({ ...COURSE, cohort: "elders" })!.html, "elders");
});

Deno.test("free text the learner typed stays out of the email", () => {
  const leaky = { ...COURSE } as Event & Record<string, unknown>;
  leaky.experience = "I have a criminal record I want to mention";
  leaky.notes = "please do not seat me near my brother";
  for (const m of [officeMessage(leaky)!, publicMessage(leaky)!]) {
    assert(!m.html.includes("criminal record") && !m.text.includes("criminal record"),
      "free text leaked into a course email");
    assert(!m.html.includes("near my brother") && !m.text.includes("near my brother"),
      "free text leaked into a course email");
  }
});

const VOLUNTEER: Event = {
  kind: "volunteer_registered",
  reference: "FB-26-0007",
  name: "A Volunteer",
  phone: "07000 000000",
  email: "vol@example.test",
  preferred_contact: "phone",
  frequency: "fortnightly",
  sunday_mornings: true,
  portal: "https://example.test/volunteers/",
};

Deno.test("the office is told HOW the volunteer asked to be contacted", () => {
  // The first thing the masjid does with a volunteer, and the first chance to
  // get it wrong. Somebody who asked for a phone call and gets an email has
  // already been told their preference did not matter.
  const m = officeMessage(VOLUNTEER)!;
  assertStringIncludes(m.html, "a phone call");
  assertStringIncludes(m.html, "the way they asked");
  assertStringIncludes(m.html, "FB-26-0007");
});

Deno.test("the volunteer is told they are NOT on the rota yet", () => {
  // Somebody who thinks they are expected will turn up to a foodbank that is
  // not expecting them.
  const m = publicMessage(VOLUNTEER)!;
  assertStringIncludes(m.html, "not on the rota yet");
  assertStringIncludes(m.text, "NOT ON THE ROTA YET");
  assertStringIncludes(m.html, "a phone call");
});

Deno.test("a volunteer who gave no email gets no email", () => {
  // foodbank_volunteers.email is nullable — it is only required when they
  // asked to be contacted by email. Building a message for "" would mean
  // trying to send one.
  assertEquals(publicMessage({ ...VOLUNTEER, email: null }), null);
  // The office is still told, which is the whole point.
  assert(officeMessage({ ...VOLUNTEER, email: null }) !== null,
    "a volunteer with no email tells nobody at all");
});

Deno.test("a volunteer's age and gender never reach an email", () => {
  const leaky = { ...VOLUNTEER } as Event & Record<string, unknown>;
  leaky.age = 34;
  leaky.gender = "female";
  leaky.skills = "first aid";
  for (const m of [officeMessage(leaky)!, publicMessage(leaky)!]) {
    assert(!/\bfemale\b/i.test(m.html + m.text), "gender leaked into a volunteer email");
    assert(!/first aid/i.test(m.html + m.text), "skills leaked into a volunteer email");
  }
});

Deno.test("all three new subjects are ASCII and say what they are", () => {
  for (const e of [ADMISSION, COURSE, WAITING, VOLUNTEER]) {
    for (const m of [officeMessage(e), publicMessage(e)]) {
      if (!m) continue;
      assertEquals(m.subject, ascii(m.subject), `non-ASCII subject for ${e.kind}`);
      assert(m.subject.length <= 75, `subject too long for ${e.kind}: ${m.subject.length}`);
      assertStringIncludes(m.subject, e.reference!);
    }
  }
});

Deno.test("every new kind produces an office email — none is silently dropped", () => {
  // The bug this whole section exists for. A kind that falls through every
  // branch returns null, and null means nobody is told.
  for (const kind of ["admission_requested", "course_registered",
                      "volunteer_registered"] as const) {
    const e = { ...ADMISSION, kind } as Event;
    assert(officeMessage(e) !== null, `${kind} tells nobody`);
  }
});

/* ===========================================================================
   THE MADRASAH FEE REMINDER

   The only unsolicited message this system sends, and the only one that goes
   to a list. Two things about it are worth testing and one of them is the
   whole reason the tests exist:

   A madrasah roll reveals a child's religion, which is Article 9 data. An
   email is not a secure channel and a fee reminder gets forwarded round a
   family group. So the message carries the FAMILY, the reference and the
   amount, and nothing about a child.

   Migration 071 has a CHECK that fails if a pupil name ever reaches the
   payload. This is the other end of the same guard: even if one were passed
   in, the template must not print it.
   =========================================================================== */

const REMINDER: Event = {
  kind: "madrasah_fee_reminder",
  reference: "MF-0148",
  email: "parent@example.test",
  family: "Khan — 14 Blackburn Road",
  balance_p: 22750,
  bank_name: "HSBC",
  bank_account_name: "Bolton Central Islamic Society",
  bank_sort: "30-99-50",
  bank_number: "59286668",
};

Deno.test("a fee reminder says what is owed and the reference to quote", () => {
  const m = publicMessage(REMINDER)!;
  assert(m !== null, "no reminder was produced at all");
  assertStringIncludes(m.html, "£227.50");
  assertStringIncludes(m.html, "MF-0148");
  assertStringIncludes(m.text, "MF-0148");
});

Deno.test("NO CHILD REACHES A FEE REMINDER, even if one is passed in", () => {
  // Fields a careless change might start forwarding. None of them is on the
  // Event interface for this kind; the point is that adding one would not
  // silently start printing it.
  const leaky = {
    ...REMINDER,
    name: "Yusuf Khan",
    // deno-lint-ignore no-explicit-any
  } as any;
  const m = publicMessage(leaky)!;
  for (const forbidden of ["Yusuf", "Hifz", "Autumn term"]) {
    assert(!m.html.includes(forbidden),
      `a fee reminder printed "${forbidden}" — that is a child's details in an ` +
      `unsolicited email about money`);
    assert(!m.text.includes(forbidden), `the plain-text reminder printed "${forbidden}"`);
  }
});

Deno.test("CONTROL — that last test can fail", () => {
  // Without this, "no child's name appears" passes on a template that prints
  // nothing at all, or on a publicMessage that returns null. Migration 065's
  // lesson, applied to an email: a check that cannot fail is worse than none.
  const m = publicMessage(REMINDER)!;
  assertStringIncludes(m.html, "Khan — 14 Blackburn Road");
  assert(m.html.length > 400, "the reminder is suspiciously short");
});

Deno.test("the bank details go in, so a parent can act on it", () => {
  const m = publicMessage(REMINDER)!;
  assertStringIncludes(m.html, "30-99-50");
  assertStringIncludes(m.html, "59286668");
  assertStringIncludes(m.html, "Bolton Central Islamic Society");
});

Deno.test("with no bank details it tells them to ring rather than saying nothing", () => {
  const m = publicMessage({ ...REMINDER, bank_sort: null, bank_number: null })!;
  assert(!m.html.includes("Sort code"), "an empty sort code row was printed");
  assertStringIncludes(m.html, "ring the office");
});

Deno.test("a card link is offered only when there is one", () => {
  const without = publicMessage(REMINDER)!;
  assert(!without.html.includes("pay by card"),
    "a card link was offered when the masjid has not set one up");

  const with_ = publicMessage({
    ...REMINDER, card_link: "https://buy.stripe.com/5kQ6oHfU02LC0p05p4f3a07" })!;
  assertStringIncludes(with_.html, "pay by card");
  assertStringIncludes(with_.html, "buy.stripe.com");
});

Deno.test("the office is NOT copied on a fee reminder", () => {
  // Three hundred identical emails is how an inbox learns to ignore this
  // sender, and then the week a refund is genuinely owed gets skimmed past.
  assertEquals(officeMessage(REMINDER), null);
});

Deno.test("a family in hardship is pointed at a person, not a form", () => {
  const m = publicMessage(REMINDER)!;
  assertStringIncludes(m.html, "01204");
  assert(/difficult/i.test(m.html),
    "the reminder does not tell a family who cannot pay that they can ask");
});

Deno.test("the office's own wording is used when it has set any", () => {
  const m = publicMessage({
    ...REMINDER,
    subject: "Madrasah fees for the autumn term",
    body: "Assalamu alaikum, a short note about fees." })!;
  assertEquals(m.subject, "Madrasah fees for the autumn term");
  assertStringIncludes(m.html, "a short note about fees");
});

Deno.test("a reminder with no email address produces nothing", () => {
  assertEquals(publicMessage({ ...REMINDER, email: null }), null);
});
