# The donate page's Stripe links — what I need, and how to make each one

**For Yameen. 14 September 2026.**

The donate page is finished and tested. It is waiting on **18 Stripe Payment
Link URLs**. Until they arrive, every amount is unpressable and the button
reads *"Not available yet"*.

There is nothing to build after they arrive. They go into one object in
`index_template.html`, the site is rebuilt, and card giving is live.

---

## 1. What I need back from you

Paste this table back filled in. A blank is fine — a blank greys that one
button out and the rest still work. **Do not send me any Stripe key**, secret
or publishable. Payment Link URLs are public by design; keys are not, and none
is needed here.

```
ONE-OFF          £5    https://buy.stripe.com/...
                 £10   https://buy.stripe.com/...
                 £25   https://buy.stripe.com/...
                 £50   https://buy.stripe.com/...
                 £100  https://buy.stripe.com/...
                 Other https://buy.stripe.com/...

MONTHLY          £5    https://buy.stripe.com/...
                 £10   https://buy.stripe.com/...
                 £25   https://buy.stripe.com/...
                 £50   https://buy.stripe.com/...
                 £100  https://buy.stripe.com/...
                 Other https://buy.stripe.com/...

FRIDAY PAY       £5    https://buy.stripe.com/...
(weekly)         £10   https://buy.stripe.com/...
                 £25   https://buy.stripe.com/...
                 £50   https://buy.stripe.com/...
                 £100  https://buy.stripe.com/...
                 Other https://buy.stripe.com/...
```

Plus three answers:

1. **Which bank account do general donations go to?** The page currently shows
   the new build's HSBC 40-04-15 / 02320258, but hall hire uses BCIS 30-99-50 /
   59286668. One of those two is wrong for general giving and I can't tell
   which from here. This is the bank-transfer panel, not Stripe — but it is on
   the same page and it is the more likely of the two to be noticed.
2. **Is Gift Aid switched on in the Stripe account**, and have you added the
   Gift Aid question to these links? The page tells donors to tick Yes on the
   payment page. If it isn't there, that sentence is a lie and I should remove
   it — say the word and I will.
3. **Has the masjid approved the Sadaqah and Lillah wording**, the "Zakāt is
   not taken here" line, and the Arabic صَدَقَة in the hero? Those are the
   masjid's words, not mine, and I would rather someone signs them off.

---

## 2. Why 18 links and not 3

Because **a Stripe Payment Link cannot take an amount from the URL.** There is
no `?amount=25`. The amount is fixed in the Price the link points at, so one
link is one amount at one frequency. Checked against Stripe's own docs on URL
parameters — the only things a link accepts are UTM codes and
`client_reference_id`.

6 amounts × 3 frequencies = 18.

**What does NOT multiply is the purpose.** The masjid / Sadaqah / Lillah choice
travels as `client_reference_id` on whichever link is used, so it shows against
the payment in Stripe without needing its own link. Otherwise this would be 54.

So: when a Sadaqah payment comes in, the Stripe payment will show
`client_reference_id: sadaqah`. That is how the office tells them apart.

---

## 3. Making the links — the short version

In Stripe you build this in two layers: a **Product** (what it is), one or more
**Prices** under it (how much and how often), and a **Payment Link** per price.

Create **three products**, then six prices under each, then a link per price.

| Product name | Prices under it |
|---|---|
| Donation — one-off | £5, £10, £25, £50, £100, customer chooses |
| Donation — monthly | same six, billed monthly |
| Donation — Friday Pay | same six, billed weekly |

---

## 4. Making the links — click by click

Do the whole thing in **test mode first** (the toggle at the top right of the
Stripe dashboard). Nothing below costs anything in test mode, and you can copy
a finished product to live mode with one button.

### 4a. Create the product

1. Stripe dashboard → **More** → **Product catalog** → **+ Add product**
2. **Name**: `Donation — one-off`
   This name is shown to the donor on the payment page, so write it for them,
   not for you.
3. **Description**: optional, also shown to the donor. Something like
   *"A gift to Taiyabah Masjid, Bolton. Registered charity 1041569."*
4. Leave the image, tax code and statement descriptor alone for now — except
   see §6 on the statement descriptor, which is worth setting.

### 4b. The five fixed prices

Still in the product editor, under **Pricing model** choose **Flat rate**.

- **Amount**: `5.00`, **Currency**: GBP
- **One time**
- Click **Add product**.

Then open the product again and use **+ Add another price** for £10, £25, £50
and £100. Five prices under one product — do not make five products.

### 4c. The "Other" price — donor chooses the amount

Add one more price, and for **Pricing model** choose **Customer chooses price**.

- **Minimum**: `1.00` — stops a 1p test payment costing the masjid more in
  Stripe fees than it receives.
- **Maximum**: leave empty, or set something high like `5000`.
- **Preset / suggested**: `20.00` is a reasonable default to show.

### 4d. Repeat for monthly

Same thing with **Name**: `Donation — monthly`, but on each price choose
**Recurring** and set the **Billing period** to **Monthly**.

### 4e. Repeat for Friday Pay

**Name**: `Donation — Friday Pay`. Each price **Recurring**, and the billing
period set to **Weekly**. If "Weekly" is not in the drop-down, use **Add a
custom period** and set it to every 1 week.

> **If Stripe will not let you combine "Customer chooses price" with a
> recurring price** — I could not confirm from the docs either way, and it may
> well refuse — just skip the "Other" price for monthly and Friday Pay and
> leave those two blank in the table. The page handles it: that button greys
> out and everything else carries on. It does not break and it does not need a
> code change.

### 4f. One Payment Link per price

For each of the 18 prices:

1. **Payment links** → **+ New**
2. **Select a product** → pick the product, then the specific price.
3. Set the options in §5 below.
4. **Create link**, then copy the URL.

Name each link so you can find it again — Stripe lets you rename them, and in
six months `Donation — Friday Pay — £25` is worth a lot more than a random ID.

---

## 5. The settings that matter on every link

These are easy to miss and annoying to fix afterwards.

| Setting | Set it to | Why |
|---|---|---|
| **Call to action / Submit type** | **Donate** | The button then says "Donate", not "Pay". It is a donation. |
| **Quantity — let customers adjust** | **OFF** | Otherwise someone can set quantity 3 on the £25 link and the page's own wording ("Donate £25") is wrong. |
| **Promotion codes** | OFF | Nothing to discount. |
| **Collect billing address** | **Required** | Needed for Gift Aid anyway, and helps with card fraud checks. |
| **Collect phone number** | Off | Not needed, and it is one more field between the donor and giving. |
| **Gift Aid field** | See §7 | 25p in every pound. |
| **After payment** | **Show confirmation page**, or redirect to `https://taiyabahmasjid.com/#donate` | Either is fine. A confirmation page is simpler and can carry a thank-you message. |

Set these the same way on all 18. It is tedious. It is also twenty minutes,
once.

---

## 6. Two things worth doing while you are in there

**Statement descriptor.** Set it on the products (or account-wide in Stripe
settings) to something like `TAIYABAH MASJID`. This is the text on the donor's
bank statement. If it says something they do not recognise, some of them will
ring the bank and call it fraud, and a chargeback costs the masjid the donation
plus a fee.

**Email receipts.** Stripe → Settings → Customer emails → turn on **Successful
payments**. Donors expect a receipt, and for a recurring gift the receipt is
also how they cancel — which is what the page tells them.

---

## 7. Gift Aid

The donate page currently says:

> *if you are a UK taxpayer, tick **Yes** on the payment page and the masjid
> reclaims **25p for every £1** at no cost to you.*

For that to be true, each link needs a **custom field** asking the Gift Aid
question, set up the same way as the new-build appeal links already are. On the
Payment Link editor it is under **Options** → **Custom fields** → **+ Add custom
field**:

- **Type**: Dropdown
- **Label**: `Gift Aid — are you a UK taxpayer?`
- **Options**: `Yes, claim Gift Aid on my donation` / `No`
- **Required**: yes

HMRC needs a declaration, not just a tick, so the label or the product
description has to carry the wording the masjid already uses on the paper
forms — I have not seen it, so send it to me and I will check the page matches.

**If Gift Aid is not going to be on these links, tell me and I will take that
paragraph off the page.** A page promising 25p in the pound that nobody can
actually claim is worse than a page that says nothing.

---

## 8. Friday Pay — the honest bit

Stripe bills a weekly subscription **every seven days from the day it starts**.
There is no way to anchor it to a Friday from a Payment Link.
`billing_cycle_anchor` exists only on the API, which Payment Links do not use.

So somebody who sets up Friday Pay on a Tuesday is charged every Tuesday.

The gift is the same size and arrives every week either way, so the feature is
sound. What is not sound is the masjid promising a day it cannot deliver. The
page therefore says, under the Friday Pay button:

> *A weekly gift for Jumu'ah. Stripe takes it every seven days from the day you
> start, so set it up on a Friday if you would like it to land on one. You can
> stop it any time.*

There is a test that fails if that sentence is ever removed. If the masjid wants
a real Friday anchor, that needs a small server-side function instead of a
Payment Link, and it is a separate job — tell me if it matters and I will cost it.

---

## 9. What happens when you send me the links

1. They go into one object in `index_template.html`:

   ```js
   var DONATE_LINKS = {
     once:    { '5':'…', '10':'…', '25':'…', '50':'…', '100':'…', other:'…' },
     monthly: { '5':'…', '10':'…', '25':'…', '50':'…', '100':'…', other:'…' },
     jummah:  { '5':'…', '10':'…', '25':'…', '50':'…', '100':'…', other:'…' }
   };
   ```

2. Rebuild, run the tests, hand you the two files to upload.
3. **Then you make one real £1 donation with a real card, in live mode, and we
   watch it land.** Refund it afterwards from the Stripe dashboard.

Step 3 is the one that matters. Right now no real payment has ever gone through
this masjid's Stripe account, and until one has, the donation system is a demo.
Test mode proves the wiring; it does not prove the account can actually receive
money, that the payout bank details are right, or that the money reaches BCIS.

---

## 10. Test mode links will not work on the live site

Test links look like `https://buy.stripe.com/test_…`. Live ones have no `test_`.

Build and check everything in test mode, then **copy the products to live mode**
(product page → **Copy to live mode**), create the Payment Links again in live
mode, and send me *those* URLs. The links themselves do not copy across — only
the products and prices do.

If a `test_` URL ever reaches the live site, donors get a page that takes fake
card numbers and no real money arrives. Worth checking twice.
