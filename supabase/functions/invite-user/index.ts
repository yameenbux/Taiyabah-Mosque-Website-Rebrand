/* ===========================================================================
   invite-user — create a staff account and get the sign-in link to them

   WHY THIS EXISTS AT ALL. Creating a user is an ADMIN operation on Supabase
   Auth: it needs the service role key, the credential that bypasses every RLS
   policy in the database. That key must never reach a browser. Put it in
   portals/config.js and anybody viewing source owns the hall bookings, the
   nikāḥ requests, the course sign-ups and the children's records.

   So the browser calls this, and this holds the key.

   IT VERIFIES THE CALLER ITSELF. It cannot trust the page saying "I am an
   administrator" — the page is the thing being protected from. It calls
   staff_list() with the CALLER'S OWN token and requires allowed:true, which
   runs verified_admin() in Postgres: admin role AND aal2. A function that
   skips that is a public endpoint for manufacturing administrators.

   ---------------------------------------------------------------------------
   WHAT CHANGED, AND WHY IT IS EMAIL AND NOT A TEXT MESSAGE

   The first version handed the link back to the administrator to forward by
   WhatsApp or read out in person, because Supabase's built-in sender only
   reaches the project team. The masjid now has its own mail path — the
   `notify` function, sending through one.com — so this can offer to send it.

   Sending it by SMS was considered and deliberately rejected:

     · A text from an unrecognised number containing a long link to a site you
       are asked to sign in to is indistinguishable from a phishing text. Using
       one teaches masjid staff that such a text is normal, which is precisely
       the habit that gets a charity's accounts taken over. Email at least
       carries SPF and DKIM that a recipient's provider can check.
     · It would mean a paid third-party account, a new credential and another
       paragraph in the handover — the same trade `notify` already refused when
       it chose one.com over a dedicated sending service.
     · UK carriers filter link-bearing SMS from unregistered senders, and there
       would be no way to know which ones never arrived.

   The phone number is still collected, and is now REQUIRED. It is there so
   somebody can be RUNG — when their account is stuck, when they have left, or
   at handover. It is not a delivery channel for a credential.

   THE LINK IS ALWAYS RETURNED, whether or not the email went. An invitation
   that silently fails to arrive is worse than one that was never offered, so
   the screen shows the link either way and says plainly what happened.

   ZERO IMPORTS, on purpose. This talks to the Auth admin API, PostgREST and
   notify over plain fetch. Nothing to resolve at deploy time, nothing to pin.
   =========================================================================== */

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const SERVICE  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON     = Deno.env.get("SUPABASE_ANON_KEY")!;

/* Shared with notify. Absent means "we cannot send email", which this reports
   honestly rather than pretending the invitation was delivered. */
const NOTIFY_SECRET = Deno.env.get("NOTIFY_SECRET") ?? "";

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

/** The same plain English the screen uses. Sent to the invited person so the
 *  email says what they are being given, not `hall_office`. */
const SAYS: Record<string, string> = {
  admin:       "everything",
  hall_office: "hall bookings and nikah",
  teacher:     "the madrasah",
};

/** The rule from hall_bookings.phone_shape and pending_access.phone_shape,
 *  written once more here so a bad number is refused before an auth account
 *  has been created rather than after. Deliberately the SAME rule: a number
 *  that passes on one screen and fails on another is worse than either. */
function phoneLooksReal(v: string): boolean {
  return /^[0-9]{10,13}$/.test(v.replace(/[^0-9]/g, ""));
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")    return reply(405, { error: "POST only" });

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) {
    return reply(401, { error: "Sign in first." });
  }

  let body: {
    email?: string; full_name?: string; phone?: string;
    roles?: string[]; note?: string; send_email?: boolean;
  };
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "Could not read the request." });
  }

  const email = String(body.email || "").trim().toLowerCase();
  const name  = String(body.full_name || "").trim();
  const phone = String(body.phone || "").trim();
  const roles = Array.isArray(body.roles) ? body.roles : [];
  const note  = typeof body.note === "string" ? body.note.slice(0, 300) : null;
  const wantsEmail = body.send_email !== false;   // default to sending

  if (!/^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email)) {
    return reply(400, { error: "That does not look like an email address." });
  }
  if (name.length < 2) {
    return reply(400, {
      error: "Put their full name in. An account nobody can put a name to is " +
             "no use at handover.",
    });
  }
  if (!phoneLooksReal(phone)) {
    return reply(400, {
      error: "That does not look like a phone number. Somebody has to be able " +
             "to ring them.",
    });
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

  /* The invitation email says who sent it, by name. That is the one detail an
     attacker who does not already hold the database cannot supply, and it is
     what makes the email distinguishable from a phishing attempt. Taken from
     staff_list()'s own answer, never from the request body. */
  const meRow = (who.people || []).find((p: { is_me?: boolean }) => p.is_me);
  const invitedBy = (meRow && meRow.name) || "An administrator";

  /* ---- 2. CREATE THE ACCOUNT AND GET A LINK ------------------------------
     generate_link creates the user if there is none and returns the link
     WITHOUT sending anything. If the address already has an account we send a
     recovery link instead, so an existing volunteer can be given access
     without a second account being made for them — which is how this masjid
     ended up with two admin accounts one letter apart.

     `data` seeds raw_user_meta_data, which the handle_new_user trigger reads
     into profiles.full_name. Without it the trigger falls back to the email
     address, and the account is called "someone@gmail.com" forever. */
  let kind = "invite";

  const make = async (type: string) => {
    const res = await fetch(`${URL_BASE}/auth/v1/admin/generate_link`, {
      method: "POST",
      headers: { "content-type": "application/json", apikey: SERVICE,
                 Authorization: `Bearer ${SERVICE}` },
      body: JSON.stringify({ type, email, data: { full_name: name } }),
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
  const link = made.body.action_link || made.body.properties?.action_link || "";
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
     authenticator.

     BEFORE the email, deliberately. If recording fails there is no record of
     who was given what, and an email has already gone out saying otherwise. */
  const rec = await fetch(`${URL_BASE}/rest/v1/rpc/record_invite`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: ANON, Authorization: auth },
    body: JSON.stringify({
      p_email: email, p_full_name: name, p_phone: phone,
      p_roles: roles, p_note: note,
    }),
  });
  if (!rec.ok) {
    return reply(502, {
      error: "The account was created but the invitation was not recorded. " +
             "Tell whoever looks after the website.",
      detail: await rec.text(),
    });
  }

  /* ---- 4. SEND IT, IF ASKED AND IF WE CAN -------------------------------
     notify holds the mail credential; this does not. It answers with an
     explicit `sent`, which is the only thing reported back to the screen.
     "ok" from notify means "the request was understood", not "it arrived" —
     the two were conflated once and the screen said "emailed" when the SMTP
     settings were not even filled in. */
  let emailed = false;
  let why = "";

  if (!wantsEmail) {
    why = "not asked for";
  } else if (!NOTIFY_SECRET) {
    why = "email is not set up on this site yet";
  } else {
    try {
      const res = await fetch(`${URL_BASE}/functions/v1/notify`, {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-notify-secret": NOTIFY_SECRET,
          Authorization: `Bearer ${SERVICE}`,
        },
        body: JSON.stringify({
          kind: "staff_invite",
          email, name, link,
          invited_by: invitedBy,
          says: roles.map((r) => SAYS[r] || r),
          existing: kind === "existing",
        }),
      });
      const out = await res.json().catch(() => ({}));
      emailed = out.sent === true;
      if (!emailed) why = String(out.note || `the mail step answered ${res.status}`);
    } catch (err) {
      why = (err as Error).message.slice(0, 200);
    }
  }

  return reply(200, {
    ok: true,
    email,
    name,
    roles,
    kind,               // "invite" = new account, "existing" = they already had one
    link,               // ALWAYS returned, emailed or not
    emailed,
    email_note: why,
    expires_note: "This link can be used once, and stops working after 24 hours.",
  });
});
