/* ---------------------------------------------------------------------------
   Taiyabah Masjid — take-a-payment connection settings

   BOTH SUPABASE VALUES BELOW ARE SAFE TO PUBLISH — see giftaid/config.js for
   why. TERMINAL_WORKER_URL is a URL, not a credential: the Worker it points
   at holds the one secret that actually matters (the Stripe key), and it is
   never shipped here. See terminal-worker/README.md.
--------------------------------------------------------------------------- */

window.TAIYABAH_CONFIG = {
  MASJID:            "taiyabah",
  SUPABASE_URL:      "https://phenbhmobxwyvdeshvqw.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_mOPuQKVP8WCTlBF2Qa1DVw_r_Tra5OO",

  /* Fill this in once terminal-worker is deployed (npx wrangler deploy
     prints it) — something like "https://taiyabah-terminal.<subdomain>.workers.dev". */
  TERMINAL_WORKER_URL: "PASTE_THE_DEPLOYED_WORKER_URL_HERE",

  /* The masjid's reader is a Stripe Reader S700 — confirmed 8 November 2026
     from a photo of its own screen (the stock "Total £X.XX / Tap, insert or
     swipe" checkout UI, which only an internet-connected smart reader
     shows). That screen is Stripe's own, drawn by the reader's firmware —
     not this page, and not brandable from here. See terminal-worker/README.md
     for what actually can be branded (this page, which staff look at).

     "internet" discovery needs the reader already REGISTERED to a Location
     on the masjid's own Stripe account (one-time step, Stripe Dashboard →
     Terminal → Locations/Readers — see docs/DO-THIS-card-machine.md). It is
     looked up by that Location, not by Bluetooth proximity, so
     TERMINAL_LOCATION_ID below must be filled in too. */
  READER_DISCOVERY_METHOD: "internet",
  TERMINAL_LOCATION_ID: "PASTE_THE_STRIPE_TERMINAL_LOCATION_ID_HERE"
};
