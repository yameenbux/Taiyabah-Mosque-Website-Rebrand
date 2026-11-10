/* ============================================================================
   Taiyabah Masjid — Terminal service
   ----------------------------------------------------------------------------
   /take-payment/ is served as a static page and can never hold the Stripe
   SECRET key — anyone viewing the page source would be able to create charges
   on the masjid's own account. This Worker is the one place that key exists.

   Routes (both require Authorization: Bearer <Supabase access token>,
   checked against verified_admin() — see README for why that function and
   not a second, Worker-only idea of "administrator"):

     POST /connection_token                    -> { secret }
     POST /create_payment_intent  { amount_p, purpose? } -> { id, client_secret }

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

function corsHeaders(env) {
  return {
    "Access-Control-Allow-Origin": env.ALLOWED_ORIGIN,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
  };
}

function json(env, data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders(env) },
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

export default {
  async fetch(req, env) {
    if (req.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders(env) });
    }
    if (req.method !== "POST") {
      return json(env, { error: "Method not allowed" }, 405);
    }

    const url = new URL(req.url);
    const token = bearerToken(req);

    if (!(await callerIsVerifiedAdmin(env, token))) {
      // Deliberately the same shape whether the token is missing, expired,
      // or belongs to somebody who simply isn't an administrator — telling
      // those apart helps nobody but an attacker probing the endpoint.
      return json(env, { error: "Not allowed" }, 403);
    }

    try {
      if (url.pathname === "/connection_token") {
        return json(env, await handleConnectionToken(env));
      }
      if (url.pathname === "/create_payment_intent") {
        let body = {};
        try { body = await req.json(); } catch { /* empty body -> validation below rejects it */ }
        return json(env, await handleCreatePaymentIntent(env, body));
      }
      return json(env, { error: "Not found" }, 404);
    } catch (err) {
      const status = err.status || 502;
      console.error(`terminal-worker: ${url.pathname} failed —`, err.message, err.stripe || "");
      return json(env, { error: err.message }, status);
    }
  },
};
