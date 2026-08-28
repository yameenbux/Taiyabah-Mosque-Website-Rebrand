# Brand files for third-party services

Artwork the masjid uploads **into other people's systems** — Stripe today,
probably something else later. It is not part of the website and must never be
uploaded to the web server.

Everything here is generated from the two master logos in `assets/`. If you need
a different size or a different service's requirements, edit the script rather
than hand-editing a PNG, so the next person can see how it was made.

```
python3 brand/make-stripe-assets.py
```

## What's here

| File | Where it goes | Size |
|---|---|---|
| `taiyabah-stripe-logo-on-dark.png` | Stripe → Branding → **Logo** — **this is the one in use** | 1000×198, cream ink, transparent |
| `taiyabah-stripe-logo-on-light.png` | spare, only if the background is changed to cream or white | 1000×198, plum ink, transparent |
| `taiyabah-stripe-icon.png` | Stripe → Branding → **Icon** | 512×512, square |
| `make-stripe-assets.py` | regenerates all three from `assets/` | — |

**The logo files are named for the background they sit on, not for their own
colour.** The checkout background is plum `#3C0B2A`, so the `-on-dark` file is
correct. Uploading the plum one to a plum background makes it invisible — which
is exactly what happened the first time.

Upload to **both** slots. Stripe uses them in different places: the Logo appears
on Checkout, Payment Links and invoice PDFs; the Icon appears on Checkout *and*
on emails, receipts, the customer portal and invoices. If only the Icon is set,
Checkout falls back to it and shows a small square tile where the logo should be.

## Why these are shaped the way they are

**The logo is a horizontal lockup, not the stacked master.** Stripe's checkout
header is a short, wide slot and scales the logo to fit its *height*. Feed it the
tall stacked version and the wordmark shrinks to nothing. About 5:1 fills the
space it is actually given.

**Both are transparent, so the ink has to contrast with whatever is behind it.**
Transparent artwork has no ground of its own: cream ink disappears on cream,
plum ink disappears on plum. Check the current Checkout background colour before
uploading, and pick the file named for it.

**The icon is the calligraphy only.** The full lockup squeezed into a square turns
to mush below about 96px, and the icon becomes the favicon and appears on every
receipt and email. The calligraphy alone still reads at 32px.

**The icon keeps its own plum tile** rather than being transparent, precisely so
it cannot disappear. Once the Logo is set, Stripe shows the Logo on Checkout and
uses the Icon only as the favicon — plus emails, receipts, the customer portal
and invoices, which are all light. A solid tile is right for all of those.

## Stripe's requirements, for whoever comes next

PNG or JPG · under 512 KB · at least 128×128 · Icon square, Logo non-square.
The script checks all four and exits non-zero if either file fails.

## Related settings

Checkout background `#3C0B2A` (plum), button `#C6A24C` (gold) — measured on the
live page: the amount reads at 16.5:1 and the gold Pay button's label at 7.9:1,
both comfortably past WCAG. Font: Fraunces
and Hanken Grotesk are not on Stripe's list and Stripe applies one font to the
whole page, so a neutral humanist sans (Source Sans Pro or Open Sans) is the
closest match — carry the identity through colour and logo instead.

See `DONATIONS.md` for the payment side.

## Source files — do not delete

`assets/logo-dark.png` (plum on transparent) and `assets/logo-cream.png` (cream on
transparent), both 780×552. Everything in this folder is derived from them.
