/* ===========================================================================
   invite-user — create a staff account and hand back a one-time link

   WHY THIS EXISTS AT ALL. Creating a user is an ADMIN operation on Supabase
   Auth: it needs the service role key, the credential that bypasses every RLS
   policy in the database. That key must never reach a browser. Put it in
   portals/config.js and anybody viewing source owns the hall bookings, the
   nikah requests, the course sign-ups and the children's records.

   So the browser calls this, and this holds the key.

   IT VERIFIES THE CALLER ITSELF. It cannot trust the page saying "I am an
   administrator" — the page is the thing being protected from. It calls
   staff_list() with the CALLER'S OWN token and requires allowed:true, which
   runs verified_admin() in Postgres: admin role AND aal2. A function that
   skips that is a public endpoint for manufacturing administrators.

   NO EMAIL IS SENT, DELIBERATELY. Supabase's built-in sender only delivers to
   the project team, twice an hour — an invite to a masjid volunteer would
   simply never arrive, and the screen would look like it worked. So this
   generates the link and hands it back for the administrator to send by
   WhatsApp, text, or in person. It is one fewer moving part, and the admin
   can SEE it worked. When custom SMTP is set up, sending it automatically is
   an addition, not a rewrite.

   ZERO IMPORTS, on purpose. This talks to the Auth admin API and PostgREST
   over plain fetch. Nothing to resolve at deploy time, nothing to pin, and it
   is the same shape whether or not a CDN is reachable.
   =========================================================================== */

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const SERVICE  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON     = Deno.env.get("SUPABASE_ANON_KEY")!;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}

/** Roles this endpoint will ever write down. `parent` is granted by the
 *  madrasah portal when a family is enrolled — two routes to the same thing
 *  means one of them has weaker checks, and it would be this one. */
const GRANTABLE = ["admin", "hall_office", "teacher"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")    return reply(405, { error: "POST only" });

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) {
    return reply(401, { error: "Sign in first." });
  }

  let body: { email?: string; roles?: string[]; note?: string };
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "Could not read the request." });
  }

  const email = String(body.email || "").trim().toLowerCase();
  const roles = Array.isArray(body.roles) ? body.roles : [];
  const note  = typeof body.note === "string" ? body.note.slice(0, 300) : null;

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email)) {
    return reply(400, { error: "That does not look like an email address." });
  }
  if (roles.length === 0) {
    return reply(400, { error: "Choose what they will be able to do." });
  }
  for (const r of roles) {
    if (!GRANTABLE.includes(r)) {
      return reply(400, { error: `${r} cannot be granted from this screen.` });
    }
  }

  /* ---- 1. IS THE CALLER REALLY AN ADMINISTRATOR? -------------------------
     Asked of the database, with the caller's own token, so the answer comes
     from verified_admin() and not from anything the browser said. */
  const gate = await fetch(`${URL_BASE}/rest/v1/rpc/staff_list`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: ANON, Authorization: auth },
    body: "{}",
  });
  if (!gate.ok) {
    return reply(403, { error: "Could not check your access. Sign out and back in." });
  }
  const who = await gate.json();
  if (!who || who.allowed !== true) {
    return reply(403, {
      error: "Only an administrator who has completed two-step can invite somebody.",
    });
  }

  /* ---- 2. CREATE THE ACCOUNT AND GET A LINK ------------------------------
     generate_link creates the user if there is none and returns the link
     WITHOUT sending anything. If the address already has an account we send a
     recovery link instead, so an existing volunteer can be given access
     without a second account being made for them — which is how this masjid
     ended up with two admin accounts one letter apart. */
  let kind = "invite";
  let link = "";

  const make = async (type: string) => {
    const res = await fetch(`${URL_BASE}/auth/v1/admin/generate_link`, {
      method: "POST",
      headers: { "content-type": "application/json", apikey: SERVICE,
                 Authorization: `Bearer ${SERVICE}` },
      body: JSON.stringify({ type, email }),
    });
    return { ok: res.ok, body: await res.json().catch(() => ({})) };
  };

  let made = await make("invite");
  if (!made.ok) {
    const msg = JSON.stringify(made.body).toLowerCase();
    if (msg.includes("already been registered") || msg.includes("already exists") ||
        msg.includes("email_exists")) {
      kind = "existing";
      made = await make("recovery");
    }
    if (!made.ok) {
      return reply(502, {
        error: "Supabase would not create the invitation.",
        detail: made.body,
      });
    }
  }
  link = made.body.action_link || made.body.properties?.action_link || "";
  if (!link) {
    return reply(502, { error: "No link came back from Supabase." });
  }

  /* ---- 3. WRITE DOWN THE INTENTION --------------------------------------
     As the CALLER, not as the service role, so the audit line carries the
     name of the administrator who did it rather than "the system".

     The roles go into pending_access and NOT into user_roles. They are only
     granted once the person signs in and completes two-step — which is what
     stops one un-enrolled volunteer blocking every future migration, because
     011_require_two_step.sql refuses to run while a role-holder has no
     authenticator. */
  const rec = await fetch(`${URL_BASE}/rest/v1/rpc/record_invite`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: ANON, Authorization: auth },
    body: JSON.stringify({ p_email: email, p_roles: roles, p_note: note }),
  });
  if (!rec.ok) {
    return reply(502, {
      error: "The account was created but the invitation was not recorded. " +
             "Tell whoever looks after the website.",
      detail: await rec.text(),
    });
  }

  return reply(200, {
    ok: true,
    email,
    roles,
    kind,               // "invite" = new account, "existing" = they already had one
    link,
    expires_note: "This link can be used once, and stops working after 24 hours.",
  });
});
