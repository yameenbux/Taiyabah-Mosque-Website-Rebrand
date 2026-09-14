/* Run with:  node supabase/functions/stripe-webhook/giftaid_test.mjs
   No Stripe account, no webhook delivery, no card. That was always the point
   of keeping giftaid.ts pure — and nobody did it until money had moved.

   The Gift Aid answer matcher, tested as a pure function — which is what
   giftaid.ts's own header says it exists to allow, and what nobody did.

   THE BUG. Stripe derives a dropdown OPTION'S VALUE from its LABEL: it strips
   the label to lowercase alphanumerics and never shows you the result. The
   masjid was told (by me) to use the option "Yes, claim Gift Aid on my
   donation", which Stripe turned into the value

       yesclaimgiftaidonmydonation

   and the matcher tested `answer.toLowerCase() === "yes"`. Exact equality.
   So a donor who said YES was recorded as no Gift Aid, silently, and 25p in
   the pound went unclaimed. I wrote the instruction and the code that could
   not read it.
*/
const GIFT_AID = /gift\s*[-_]?\s*aid/i;
const norm = (s) => String(s ?? "").toLowerCase().replace(/[^a-z0-9]/g, "");

function labelOf(f) { return (f.label?.custom ?? "").toString(); }

export function readGiftAid(fields) {
  const list = Array.isArray(fields) ? fields : [];
  let match = list.find((f) => (f.key ?? "").toLowerCase() === "gift_aid");
  let matchedBy = match ? "key" : "none";
  if (!match) {
    match = list.find((f) => GIFT_AID.test(f.key ?? "") || GIFT_AID.test(labelOf(f)));
    if (match) matchedBy = "label";
  }
  if (!match) return { giftAid: false, matchedBy: "none", answer: "", fieldMissing: true };

  const raw = (match.dropdown?.value ?? "").toString().trim();
  //  STARTS WITH yes, not EQUALS yes. Stripe's generated value carries the
  //  whole label, so "Yes, claim Gift Aid on my donation" arrives as
  //  "yesclaimgiftaidonmydonation". Anything that does not begin with yes is
  //  still a no: the failure mode must stay "a claim not made", never "a
  //  claim wrongly made", because HMRC disallows the second one years later
  //  when the money has been spent.
  //
  //  THE ONE WAY THIS COULD GO WRONG: an option worded "Yes, but I am not a
  //  UK taxpayer". The dropdown must have exactly two options and only the
  //  affirmative one may begin with Yes.
  const n = norm(raw);
  return { giftAid: n.startsWith("yes"), matchedBy, answer: raw, fieldMissing: false };
}

const F = (label, value) => [{ label: { custom: label }, dropdown: { value } }];
let fails = 0;
const t = (why, got, want) => {
  const ok = got === want;
  if (!ok) fails++;
  console.log((ok ? "  ok   " : "  FAIL ") + why + (ok ? "" : `  (got ${got}, wanted ${want})`));
};

console.log("THE ANSWER THE MASJID'S REAL LINK ACTUALLY SENT");
t('"yesclaimgiftaidonmydonation" is a YES',
  readGiftAid(F("Gift Aid — are you a UK taxpayer?", "yesclaimgiftaidonmydonation")).giftAid, true);

console.log("\nSTILL A YES");
t('a link made through the API sends a bare "yes"',
  readGiftAid(F("Gift Aid", "yes")).giftAid, true);
t('"Yes" with a capital',
  readGiftAid(F("Gift Aid", "Yes")).giftAid, true);
t('"Yes please"',
  readGiftAid(F("Gift Aid", "Yes please")).giftAid, true);

console.log("\nMUST STAY A NO — the expensive direction");
t('"no"',              readGiftAid(F("Gift Aid", "no")).giftAid, false);
t('"nothanks"',        readGiftAid(F("Gift Aid", "No thanks")).giftAid, false);
t('"noiamnotataxpayer"', readGiftAid(F("Gift Aid", "No, I am not a taxpayer")).giftAid, false);
t('an unanswered dropdown', readGiftAid(F("Gift Aid", "")).giftAid, false);
t('a third option added later',
  readGiftAid(F("Gift Aid", "I am not sure")).giftAid, false);
t('the field renamed so it no longer says Gift Aid',
  readGiftAid(F("Tax relief", "yes")).fieldMissing, true);
t('no custom fields at all', readGiftAid(null).fieldMissing, true);
t('and that case is not a claim', readGiftAid(null).giftAid, false);

console.log("\nTHE OLD CODE, for the record");
const old = (v) => String(v).toLowerCase() === "yes";
t('exact equality read the real answer as NO',
  old("yesclaimgiftaidonmydonation"), false);

console.log("\n" + (fails ? fails + " FAILURES" : "ALL PASS"));
process.exit(fails ? 1 : 0);
