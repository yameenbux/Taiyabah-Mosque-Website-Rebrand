// ===========================================================================
//  giftaid.ts — reading the donor's Gift Aid answer off a Stripe checkout
//
//  Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
//  12 September 2026
//
//  WHY THIS IS ITS OWN FILE
//  ------------------------
//  It decides whether the masjid claims 25p on a pound, and whether a donor's
//  name and home address are stored at all. Both are worth testing without a
//  Stripe account, a webhook delivery or a card, so it is pure and separate.
//
//  WHY IT DOES NOT MATCH ON A KEY ALONE
//  ------------------------------------
//  The first version required the custom field's key to be exactly
//  "gift_aid". THE STRIPE DASHBOARD DOES NOT LET YOU SET A KEY — it generates
//  one from the label and never shows it. That instruction could not be
//  followed, and a field whose key did not match would have recorded every
//  donation as "no Gift Aid" in perfect silence: no error, no failed payment,
//  just 25p in every pound quietly not claimed.
//
//  So: the key is preferred where it exists, and the LABEL is the fallback.
//  Matching on a label is normally a bad idea because labels get reworded by
//  whoever is tidying up — which is why anything that does not clearly say
//  Gift Aid is treated as no field at all, and said so out loud.
//
//  ANYTHING OTHER THAN AN EXPLICIT YES IS A NO.
//  Field missing, renamed, unanswered, a third option added later — all of
//  them mean no claim. The failure mode is a claim not made, never a claim
//  wrongly made, because the second one is the expensive one: HMRC disallows
//  it years later and the money has been spent.
//
//  AND "EXPLICIT YES" MEANS STARTS WITH YES, NOT EQUALS YES.
//  ---------------------------------------------------------
//  14 September 2026. The first real Gift Aid donation was recorded as NO
//  even though the donor said yes. STRIPE DERIVES A DROPDOWN OPTION'S VALUE
//  FROM ITS LABEL — it strips the label to lowercase alphanumerics and never
//  shows you the result. The masjid was told to use the option
//
//      "Yes, claim Gift Aid on my donation"
//
//  which Stripe turned into the value
//
//      yesclaimgiftaidonmydonation
//
//  and this file tested `answer.toLowerCase() === "yes"`. Exact equality. So
//  the instruction given to the masjid and the code meant to read it could
//  not both be right, and the one that lost was 25p in every pound.
//
//  Same family of mistake as the key-versus-label one above: an assumption
//  about a string Stripe generates and does not show you. Neither was caught
//  because nobody ran this file against a real answer until money moved.
//
//  THE ONE WAY THE NEW RULE COULD GO WRONG: an option worded "Yes, but I am
//  not a UK taxpayer". The dropdown must have exactly two options, and only
//  the affirmative one may begin with Yes.
// ===========================================================================

export type DropdownField = {
  key?: string;
  label?: { custom?: string | null; type?: string } | null;
  dropdown?: { value?: string | null } | null;
};

export type GiftAidReading = {
  giftAid: boolean;
  /** How the field was found, for the log. */
  matchedBy: "key" | "label" | "none";
  /** The raw answer, so an unexpected option can be seen rather than guessed at. */
  answer: string;
  /** True when no field on the checkout looked like a Gift Aid question at all. */
  fieldMissing: boolean;
};

const GIFT_AID = /gift\s*[-_]?\s*aid/i;

function labelOf(f: DropdownField): string {
  return (f.label?.custom ?? "").toString();
}

export function readGiftAid(fields: DropdownField[] | null | undefined): GiftAidReading {
  const list = Array.isArray(fields) ? fields : [];

  // Preferred: the key, when somebody made the link through the API and could
  // choose one.
  let match = list.find((f) => (f.key ?? "").toLowerCase() === "gift_aid");
  let matchedBy: GiftAidReading["matchedBy"] = match ? "key" : "none";

  // Fallback: the key or the label mentions Gift Aid. This is what a link made
  // in the Dashboard will hit.
  if (!match) {
    match = list.find((f) => GIFT_AID.test(f.key ?? "") || GIFT_AID.test(labelOf(f)));
    if (match) matchedBy = "label";
  }

  if (!match) {
    return { giftAid: false, matchedBy: "none", answer: "", fieldMissing: true };
  }

  const answer = (match.dropdown?.value ?? "").toString().trim();

  // Normalised the way Stripe normalises a label into a value: lowercase,
  // alphanumerics only. Then STARTS WITH, not EQUALS — see the header.
  const normalised = answer.toLowerCase().replace(/[^a-z0-9]/g, "");

  return {
    giftAid: normalised.startsWith("yes"),
    matchedBy,
    answer,
    fieldMissing: false,
  };
}

// ---------------------------------------------------------------------------
//  The donor's details, and the rule about when they may be kept.
//
//  Stripe collects a name and address on every checkout it is asked to. The
//  masjid's promise — and migration 022's CHECK constraint — is that a donor
//  who did not claim Gift Aid is anonymous. This is where that becomes true;
//  the constraint is only the backstop.
// ---------------------------------------------------------------------------
export type Address = {
  line1?: string | null; line2?: string | null;
  city?: string | null; state?: string | null; postal_code?: string | null;
} | null | undefined;

export function donorDetails(
  giftAid: boolean,
  name: string | null | undefined,
  address: Address,
) {
  if (!giftAid) return { name: null, address: null, postcode: null };

  // One line, in the order an envelope would be written. HMRC matches on the
  // house number and postcode; the office may need to write to somebody.
  const parts = [address?.line1, address?.line2, address?.city, address?.state]
    .map((x) => (x ?? "").toString().trim())
    .filter((x) => x.length > 0);

  return {
    name: (name ?? "").trim() || null,
    address: parts.join(", ") || null,
    postcode: (address?.postal_code ?? "").trim().toUpperCase() || null,
  };
}
