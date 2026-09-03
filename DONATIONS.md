# Moving donations off the old site — Stripe Payment Links

**Decisions taken 27 August 2026**

- Donations move to **Stripe Payment Links**.
- **No Gift Aid at checkout.** Stripe cannot produce or store a valid HMRC
  declaration, so the promise came off the page rather than being made and not
  kept.
- **The "100% Donation Policy" claim came off too.** Card payments carry a
  processing fee, so it was not true.

Taking those two claims off makes the build much simpler. Everything below is
done by clicking in the Stripe Dashboard — no API calls, no custom fields, no
address collection. Budget about twenty minutes.

---

## Why this has to happen before the domain moves

Five links on the New Build page point at WooCommerce pages on the **old**
WordPress site:

```
/product/bronze-donor/    £250
/product/silver-donor/    £500
/product/gold-donor/      £1,000
/product/platinum-donor/  £5,000
/product/dome-donation/   any amount
```

The day `taiyabahmasjid.com` points at the new site, all five 404. The bank
transfer details directly below them keep working, so giving does not stop dead
— but card giving does.

`verify_structure.py` prints a loud warning on every build while those links are
still there. It will not stop you building; it will stop you forgetting.

---

## Step 1 — account settings, once

In the Stripe Dashboard:

- **Settings → Business → Public details** — charity name, support email, and
  URLs for your terms and privacy policy. Checkout links to these.
- **Settings → Branding** — the masjid logo, plum `#3C0B2A` as the brand colour,
  gold `#C6A24C` for the button. Without this the payment page looks like it
  belongs to someone else, which costs you donations from cautious givers.
- **Settings → Custom domains** — optional, worth it. Links can be served from
  `donate.taiyabahmasjid.com` rather than `buy.stripe.com`. That matters when an
  older donor is deciding whether a payment page is really the masjid's.

## Step 2 — five links

Four fixed prices and one where the donor chooses:

| Link | Price | Notes |
|---|---|---|
| Bronze | £250 | fixed |
| Silver | £500 | fixed |
| Gold | £1,000 | fixed |
| Platinum | £5,000 | fixed |
| Any amount | customer chooses | set a £1 minimum and a £50 preset |

On each one, in **Options**:

- **Submit type → Donate**, so the button reads "Donate" rather than "Pay".
- Leave name, address and phone collection **off**. With no Gift Aid claim to
  support there is no reason to ask, and every extra field costs completions.
  Stripe still gets what it needs for the card itself.

That is the whole configuration. Apple Pay and Google Pay come on automatically.

## Step 3 — done, 28 August 2026

The five links are live on the site:

| Tier | Amount | Link |
|---|---|---|
| Bronze | £250 | `buy.stripe.com/eVqaEX0Z63PGb3E2cSf3a01` |
| Silver | £500 | `buy.stripe.com/3cI7sLgY4fyo2x8eZEf3a02` |
| Gold | £1,000 | `buy.stripe.com/fZubJ123a4TK5Jk18Of3a03` |
| Platinum | £5,000 | `buy.stripe.com/28EbJ1cHOcmc5Jk04Kf3a04` |
| Donor chooses | any | `buy.stripe.com/6oU3cvbDK1Hy2x8g3If3a05` |

Nothing on the site points at the old WordPress shop any more. `verify_structure.py`
now warns on **two** things instead of one: a link back to the old site, and a
Stripe link containing `test_` — a test-mode link is a complete, convincing
checkout that takes no money at all, and nothing on screen would tell you.

**If a link ever needs changing**, edit `index_template.html` — the five live in
the `.nb-give-card` block on the New Build page — then rebuild:

```
python3 verify_structure.py && python3 build.py
```

---

## Gift Aid is off the page, not off the table

Worth being precise about what was given up. Stripe cannot hold a declaration, so
the masjid cannot honestly promise Gift Aid **at checkout**. It can still claim
Gift Aid on **bank transfers, standing orders and cash** — those need a separate
declaration held by the office, on paper or a form, and a claim filed through
HMRC Charities Online.

On an appeal this size that is 25p in every eligible £1. If the trustees are not
already collecting declarations at the masjid, that is the largest single sum
available to them and it has nothing to do with the website.

If it later becomes worth doing properly online, the route is a Supabase Edge
Function — the project already has one for booking alerts — creating the Stripe
Checkout Session server-side, with a webhook writing each donation and its
declaration into the masjid's own database. Then the claim spreadsheet is
generated rather than assembled by hand and the six-year record lives somewhere
the masjid controls. Roughly a day's work, and nothing about the Payment Links
setup above has to be undone first.

## PayPal

You have PayPal admin access. A hosted Donate button is one more link, and a lot
of older donors trust PayPal over typing a card number. **PayPal Giving Fund UK**
is a registered charity in its own right and changes the fee position on
donations that come through the PayPal family of channels — worth checking with
them directly rather than taking a blog's word for it.

If you want it added, send the button URL and it goes beside the Stripe links.
