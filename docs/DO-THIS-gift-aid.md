# Switching Gift Aid on

12 September 2026. Twenty minutes in Stripe, one SQL file, one line in the
template.

**Nothing is live yet.** The Gift Aid section on the website is switched off, so
uploading today changes nothing a donor sees.

This replaces the earlier version of this file, which asked you to create five
extra Payment Links. You were right that it was clunky — **your existing five
links stay, and gain a dropdown**, exactly like the Zakariyya Masjid page you
showed me.

---

## First: two things for the committee

**1. Is the masjid registered with HMRC for Gift Aid?** Separate from the
Charity Commission, with its own reference number. Without it nothing can be
claimed, however good the website is.

**2. Minute the Zakat position.** You've said Zakat is kept separate, and the
site already matches that — Zakat appears only as an explanation of the Five
Pillars, never as a way to pay, and the donation card now says so in writing.
Worth a minute anyway: *"do you claim Gift Aid on Zakat?"* is the first question
an HMRC inspector asks a mosque.

---

## Step 1 — the database

Supabase → SQL Editor → paste **`022_donations_and_gift_aid.sql`** → Run.
Then re-run **`011_require_two_step.sql`**, as after every migration.

That creates the `donations` table. **It refuses to store a name, address or
postcode against a donation where Gift Aid was not claimed** — not as a policy,
as a constraint. A donor who answers No is anonymous to the masjid.

## Step 2 — deploy the webhook

Supabase → Edge Functions → `stripe-webhook` → paste the updated `index.ts`
→ Deploy. It now recognises a third kind of payment (`DN-`) alongside hall
deposits and nikāḥ fees.

## Step 3 — the five Payment Links

For **each** of your existing five donation links — Bronze, Silver, Gold,
Platinum and donor-chooses — open it in the Stripe Dashboard, click **⋯ → Edit**,
and change three things.

**a) Add the dropdown.** Advanced options → **Add custom fields** → **Dropdown**.

| | |
|---|---|
| Label | `Gift Aid — add 25% at no cost to you` |
| Options | `Yes` and `No` |
| Set a default value | **leave unticked** |
| Mark as optional | **leave unticked** |

**There is no key to set.** Stripe generates one from the label and does not
show it — an earlier version of this file told you to set it to `gift_aid`,
which was an instruction nobody could follow. The webhook finds the field by
its label instead, matching anything containing "Gift Aid" however it is
spaced or punctuated. **Keep those two words in the label** and it will be
found.

**Leave "Set a default value" unticked.** A dropdown that starts on Yes is a
declaration nobody made. Leaving it blank and required forces a decision, which
is what a declaration is.

Anything other than a literal `Yes` — No, unanswered, or some option added
later — is treated as no claim.

**b) Put the declaration in the product description.** This is the panel beside
the form — the one showing "Jazakallah for choosing to donate…" on the page you
showed me. Paste:

> Gift Aid: I want Taiyabah Masjid (Bolton Central Islamic Society, registered
> charity 1041569) to claim Gift Aid on this donation. I am a UK taxpayer and
> understand that if I pay less Income Tax and/or Capital Gains Tax in the
> current tax year than the amount of Gift Aid claimed on all my donations it is
> my responsibility to pay any difference. (Declaration wording version
> 2026-09-12.)

**This is the step the other masjid is missing.** Their page has the dropdown
and no wording. A Yes with nothing behind it is a preference, not a declaration,
and HMRC can disallow the claim years later. It costs nothing to do properly.

**c) Collect name and address.** Options → **Collect customer names** →
individual, required. **Collect customer addresses** → **Billing addresses
only**. HMRC needs a name and at least a house number and postcode; without them
the claim cannot be made at all and you won't find out until you try to file it.

## Step 4 — switch it on

In `index_template.html`, find `GIFT_AID_OPEN` and change `false` to `true`.
Then:

```bash
python3 verify_structure.py && python3 build.py
python3 _test/giftaid_test.py
python3 _test/giftaid_portal_test.py
python3 _test/claims_test.py
deno test supabase/functions/stripe-webhook/giftaid_test.ts
```

Both must say ALL PASS. Upload as usual.

---

## What happens then

A donor clicks a giving button. The website adds a reference (`DN-…`) so the
payment can be recognised, and Stripe takes it from there: amount, Gift Aid
dropdown, name, address, card. The webhook writes the donation into the masjid's
own database — with the declaration, its wording version, and the donor details
**only if they answered Yes**.

**Filing the claim.** Sign in at **/portals/** and open **Gift Aid**. No SQL,
no spreadsheets to build by hand.

The screen shows every donation you can still claim for, what it is worth
(25% of the total, in pounds, at the top), and anything HMRC would reject.
Then:

1. Download HMRC's own schedule spreadsheet from **gov.uk** — search for
   *"schedule spreadsheet to claim back tax on Gift Aid donations"*. **Use
   theirs, not a copy**: the worksheet has to be named exactly right or
   Charities Online refuses the attachment.
2. Press **Copy for HMRC**, click the first empty donor row in their
   spreadsheet, and paste. The columns line up.
3. Save as **.ods** and attach it to the claim. **Do not convert between Excel
   and LibreOffice formats** — HMRC warn in writing that this breaks the
   attachment.
4. Come back and press **Mark all as claimed**, so nothing is ever claimed
   twice.

**Read the red box before you paste.** Stripe gives one name and one address;
HMRC wants a first name, a surname and the house number on its own. The screen
splits them automatically and then lists every row it is not sure about — a
one-word name, a house called something rather than numbered, a missing
postcode. Fix those in the spreadsheet after pasting, or leave them out and ring
the donor. **A guess on a tax claim is how a claim gets disallowed**, so the
guessing is confessed rather than hidden.

HMRC take a maximum of **1,000 donations per spreadsheet**. Beyond that, claim
in batches: copy, file, mark claimed, repeat.

## Step 5 — prove it works, once

Make one small real donation through the site (£1 on the donor-chooses link),
answer **Yes**, then:

```sql
select reference, amount_p, gift_aid, donor_name, donor_postcode, declaration_version
  from public.donations order by created_at desc limit 1;
```

`gift_aid` must be **true** and the name and postcode must be there. If
`gift_aid` comes back false, the dropdown was not found on that link — check
the label still contains the words "Gift Aid", and check this:

```sql
select detail, at from public.admin_audit
 where action = 'gift_aid_field_missing' order by at desc limit 5;
```

**That is the check that matters.** A donation link without the dropdown takes
money perfectly happily and records every donation as no-Gift-Aid. Nothing
fails, nothing errors — 25p in every eligible pound is simply not claimed, and
the only way anybody finds out is by looking. Do this once per link.

**Worth checking monthly:**

```sql
select detail, at from public.admin_audit
 where action in ('gift_aid_incomplete','gift_aid_field_missing')
 order by at desc limit 20;
```

`gift_aid_incomplete` is a donor who answered Yes but whose name or postcode did
not come through — you cannot claim on those, and it is far easier to sort out
in the same month than a year later.

## Retention

Gift Aided donations are kept **six years** and deleted at seven, automatically.
That is longer than anything else on the site and it is not a choice — HMRC can
inspect that far back, and a claim you cannot evidence has to be repaid.
Donations without Gift Aid hold nothing about anybody, so there is nothing to
delete.

## What this deliberately does not do

**No email per donation.** Nobody has to act when money arrives, and an alert
for every one would bury the two that do need a human: a nikāḥ request waiting
for a call, and a refund the masjid owes somebody. If everything shouts, nothing
does.
