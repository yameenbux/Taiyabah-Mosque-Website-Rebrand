/* ============================================================================
   Taiyabah Masjid — Terminal service
   ----------------------------------------------------------------------------
   /take-payment/ is served as a static page and can never hold the Stripe
   SECRET key — anyone viewing the page source would be able to create charges
   on the masjid's own account. This Worker is the one place that key exists.

   Routes. The first two require Authorization: Bearer <Supabase access
   token>, checked against verified_admin() — see README for why that
   function and not a second, Worker-only idea of "administrator":

     POST /connection_token                    -> { secret }
     POST /create_payment_intent  { amount_p, purpose? } -> { id, client_secret }

   THE THIRD IS DELIBERATELY NOT BEHIND THAT GUARD:

     POST /membership_checkout    { token, scope } -> { url }

   A member paying their £100 is not an administrator and is not signed in at
   all. Asking five hundred men to hold an account to pay once a year is how
   the Excel sheet wins. What makes it safe is not a token but the SHAPE of
   the call: it carries no amount. It carries a claim token — proof that
   somebody just matched a name, a house number and a postcode against the
   register — and one of two words, "all" or "current". Postgres prices it
   (membership_quote) and this Worker passes that figure to Stripe. A caller
   who could name their own amount could settle £460 of arrears for a penny,
   and no checking in the app would stop them, because the app is not where
   the request would come from.

   Required secret (set with `wrangler secret put STRIPE_SECRET_KEY`):
     STRIPE_SECRET_KEY   the account's own secret key, Terminal-capable.
                         NEVER a Stripe Connect platform key — this account
                         takes its own money directly.
   ========================================================================= */

const PURPOSES = new Set(["general", "sadaqah", "lillah", "newbuild"]);
// A card-machine tap is a single donation at a till, not a transfer — this
// is a sanity ceiling against a fat-fingered extra zero, not a real limit on
// what the masjid can be given. £2,000.
const MAX_AMOUNT_P = 200000;

function corsHeaders(env, req) {
  /* THE MEMBERSHIP ROUTE HAS A WIDER DOOR, AND HAS TO.
   *
   * /take-payment/ is one page on one origin, so ALLOWED_ORIGIN is exact and
   * everything else gets no CORS headers back. The membership checkout is
   * called from the phone app as well, and a native app sends no Origin at
   * all — a fetch from React Native is not a browser request. Echoing back
   * only the configured origin would leave the app unable to read the reply
   * it just received.
   *
   * CORS IS NOT THE GUARD HERE AND NEVER WAS. It stops a page on somebody
   * else's domain reading a response in a browser; it stops nothing with a
   * command line. What protects this route is that it takes no amount. */
  const origin = req && req.headers.get("Origin");
  return {
    "Access-Control-Allow-Origin": origin === env.ALLOWED_ORIGIN ? origin : env.ALLOWED_ORIGIN,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
  };
}

function json(env, data, status = 200, req = null) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(env, req) },
  });
}

/* Asks Supabase, with the CALLER'S OWN token, to run verified_admin() — the
 * exact guard gift_aid_to_claim() and every other protected function in this
 * database already use. Nothing here decides who is an administrator; it
 * only relays the one place that already decides it. */
async function callerIsVerifiedAdmin(env, token) {
  if (!token) return false;
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/verified_admin`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": env.SUPABASE_ANON_KEY,
      "Authorization": `Bearer ${token}`,
    },
    body: "{}",
  });
  if (!res.ok) return false;
  const result = await res.json();
  return result === true;
}

function bearerToken(req) {
  const h = req.headers.get("Authorization") || "";
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return m ? m[1] : null;
}

async function stripeApi(env, path, params) {
  const body = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (Array.isArray(v)) v.forEach((item) => body.append(`${k}[]`, item));
    else if (v !== undefined && v !== null) body.append(k, String(v));
  }
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${env.STRIPE_SECRET_KEY}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: body.toString(),
  });
  const data = await res.json();
  if (!res.ok) {
    const err = new Error(data?.error?.message || "Stripe request failed");
    err.stripe = data?.error;
    throw err;
  }
  return data;
}

async function handleConnectionToken(env) {
  const token = await stripeApi(env, "terminal/connection_tokens", {});
  return { secret: token.secret };
}

async function handleCreatePaymentIntent(env, body) {
  const amount = Number(body?.amount_p);
  if (!Number.isInteger(amount) || amount <= 0 || amount > MAX_AMOUNT_P) {
    throw Object.assign(new Error(
      `amount_p must be a whole number of pence between 1 and ${MAX_AMOUNT_P}`), { status: 400 });
  }
  const purpose = typeof body?.purpose === "string" ? body.purpose.trim().toLowerCase() : "";
  const metadata = purpose && PURPOSES.has(purpose) ? { purpose } : {};

  const pi = await stripeApi(env, "payment_intents", {
    amount,
    currency: "gbp",
    "payment_method_types": ["card_present"],
    "capture_method": "automatic",
    ...Object.fromEntries(Object.entries(metadata).map(([k, v]) => [`metadata[${k}]`, v])),
  });
  return { id: pi.id, client_secret: pi.client_secret };
}

/* Asks Postgres what this claim is worth. The anon key is enough: the
 * function is granted to anon on purpose (a member is not signed in) and it
 * only ever answers about the member whose details were just matched. */
async function quoteFromSupabase(env, token, scope) {
  const res = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/membership_quote`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "apikey": env.SUPABASE_ANON_KEY,
      "Authorization": `Bearer ${env.SUPABASE_ANON_KEY}`,
    },
    body: JSON.stringify({ p_token: token, p_scope: scope }),
  });
  if (!res.ok) throw Object.assign(new Error("Could not read the membership record"),
                                   { status: 502 });
  return res.json();
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function handleMembershipCheckout(env, body) {
  const token = typeof body?.token === "string" ? body.token.trim() : "";
  const scope = body?.scope === "current" ? "current" : "all";

  /* Shape-checked here only so an obvious typo does not become a round trip.
     The claim itself is what decides anything, and it decides it in Postgres. */
  if (!UUID.test(token)) {
    throw Object.assign(new Error("That membership lookup has expired. Please look yourself up again."),
                        { status: 400 });
  }

  const quote = await quoteFromSupabase(env, token, scope);

  if (!quote || quote.ok !== true) {
    const why = quote && quote.reason;
    throw Object.assign(new Error(
      why === "nothing_due"
        ? "There is nothing outstanding on that record."
        : "That membership lookup has expired. Please look yourself up again."),
      { status: 409 });
  }

  /* A sanity ceiling, not an opinion about the fee. The figure came from
     Postgres, so this only fires if something is badly wrong — and a member
     being shown a four-figure total is worth stopping before Stripe sees it. */
  if (!Number.isInteger(quote.amount_p) || quote.amount_p <= 0 || quote.amount_p > MAX_AMOUNT_P) {
    throw Object.assign(new Error("That amount does not look right. Please ring the office."),
                        { status: 409 });
  }

  const session = await stripeApi(env, "checkout/sessions", {
    mode: "payment",
    /* THE ONLY FIELD THAT TIES THE MONEY TO A PERSON. Without it Stripe takes
       the fee and nobody knows whose it was. The webhook routes on its first
       three characters and on nothing else — never on the amount, because a
       hall deposit and a membership fee are both £100. */
    client_reference_id: quote.reference,
    /* AND THE ONLY FIELD THAT SAYS WHICH YEARS. The two buttons mean
       different things and the amount cannot tell them apart: £100 is this
       year for one member and a single year of arrears for another. The
       webhook marks exactly the years named here rather than guessing an
       allocation rule. */
    "metadata[years]": (quote.years || []).join(","),
    "metadata[kind]": "membership",
    /* Stripe collects an email in order to send its own receipt. That is how
       the member gets one without asking, and how the register — which holds
       almost no addresses — finally acquires one. mark_membership_fee_paid()
       writes it back, and only where the field is blank. */
    "customer_creation": "always",
    "line_items[0][quantity]": 1,
    "line_items[0][price_data][currency]": "gbp",
    "line_items[0][price_data][unit_amount]": quote.amount_p,
    /* NOT A DONATION. A membership fee is not a gift: running it through a
       donation product misstates it in the charity's accounts and risks a
       Gift Aid problem. Same reasoning as the nikāḥ links on the website. */
    "line_items[0][price_data][product_data][name]": quote.label,
    "line_items[0][price_data][product_data][description]":
      `Taiyabah Masjid membership · ${quote.reference}`,
    success_url: `${env.ALLOWED_ORIGIN}/members-paid/?ref=${encodeURIComponent(quote.reference)}`,
    cancel_url: `${env.ALLOWED_ORIGIN}/`,
  });

  return { url: session.url };
}

export default {
  async fetch(req, env) {
    if (req.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders(env, req) });
    }
    if (req.method !== "POST") {
      return json(env, { error: "Method not allowed" }, 405, req);
    }

    const url = new URL(req.url);
    const token = bearerToken(req);

    /* THE MEMBERSHIP CHECKOUT IS ROUTED BEFORE THE ADMINISTRATOR GUARD, and
       that placement is the whole decision — see the header. It is the one
       route a member of the congregation calls, and they are not signed in.
       It is kept to the top so that nobody later reads the guard below and
       assumes it covers everything underneath it. */
    if (url.pathname === "/membership_checkout") {
      try {
        let body = {};
        try { body = await req.json(); } catch { /* validated below */ }
        return json(env, await handleMembershipCheckout(env, body), 200, req);
      } catch (err) {
        const status = err.status || 502;
        console.error("terminal-worker: /membership_checkout failed —",
                      err.message, err.stripe || "");
        return json(env, { error: err.message }, status, req);
      }
    }

    if (!(await callerIsVerifiedAdmin(env, token))) {
      // Deliberately the same shape whether the token is missing, expired,
      // or belongs to somebody who simply isn't an administrator — telling
      // those apart helps nobody but an attacker probing the endpoint.
      return json(env, { error: "Not allowed" }, 403, req);
    }

    try {
      if (url.pathname === "/connection_token") {
        return json(env, await handleConnectionToken(env), 200, req);
      }
      if (url.pathname === "/create_payment_intent") {
        let body = {};
        try { body = await req.json(); } catch { /* empty body -> validation below rejects it */ }
        return json(env, await handleCreatePaymentIntent(env, body), 200, req);
      }
      return json(env, { error: "Not found" }, 404, req);
    } catch (err) {
      const status = err.status || 502;
      console.error(`terminal-worker: ${url.pathname} failed —`, err.message, err.stripe || "");
      return json(env, { error: err.message }, status, req);
    }
  },
};
