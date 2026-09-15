/* ===========================================================================
   app-notify — send a notification to the phone app, as yourself

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   15 September 2026

   The repository copy, with the full reasoning, is
   supabase/functions/app-notify/index.ts. Keep them identical.

   The app's notifications are sent by a Cloudflare Worker which authenticates
   with ONE SHARED PASSWORD and issues a token whose entire payload is
   {"exp": ...} — no subject, no name. That is fine for one screen used by two
   trustees on a phone, and wrong to paste into the Admin Centre, where a
   committee member has already signed in with an account and an authenticator.

   So the password lives HERE, as a secret nobody on the committee ever sees.

   ORDER: record first, send second.
     1. app_notification_start() with the CALLER'S OWN TOKEN — runs
        verified_admin() in Postgres and writes a row whose actor is
        auth.uid(). This function never says who the sender is; it cannot.
     2. Send.
     3. app_notification_finish() with the service key, saying how it went.

   Nothing in Cloudflare or the app repository changes: this is server to
   server, so there is no Origin header and no CORS involved.

   SECRETS (Supabase dashboard, never in a file):
       APP_SENDER_URL       the Worker's address
       APP_SENDER_PASSWORD  the app trustee-screen password
   =========================================================================== */

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const SERVICE  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON     = Deno.env.get("SUPABASE_ANON_KEY")!;

const SENDER_URL = (Deno.env.get("APP_SENDER_URL") ?? "").trim().replace(/\/+$/, "");
const SENDER_PW  = Deno.env.get("APP_SENDER_PASSWORD") ?? "";

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

/*  Copied from TOPICS in worker/worker.js ON PURPOSE rather than fetched: a
    screen that silently grew a sixth option because somebody edited a
    different repository would be worse than one a fortnight out of date.
    _test/app_bridge_test.py fails if the two lists disagree. */
const TOPICS: Record<string, string> = {
  janazah:       "Janāzah",
  jamaah:        "Jamāʿah reminders",
  announcements: "Announcements",
  events:        "Events & talks",
  kahf:          "Sūrah al-Kahf",
};

/*  THE WORKER SESSION, CACHED AT MODULE SCOPE.
    Not an optimisation: the Worker rate-limits /api/login to EIGHT attempts
    per fifteen minutes per IP, and every call from here arrives from
    Supabase's addresses. Refreshed an hour early because a token that dies
    mid-send costs a real notification. */
let cachedToken = "";
let cachedUntil = 0;

async function senderToken(): Promise<string> {
  if (cachedToken && Date.now() < cachedUntil) return cachedToken;

  const res = await fetch(`${SENDER_URL}/api/login`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ password: SENDER_PW }),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok || !out.token) {
    //  Deliberately does NOT echo the Worker's "Incorrect password", which on
    //  the committee's screen would read as "your password is wrong" — it is
    //  not theirs, it is the masjid's stored one. Say whose problem it is.
    throw new Error(
      res.status === 401
        ? "The website's stored password for the app sender is not being accepted. " +
          "It needs setting again — nothing you have done is wrong."
        : `The app sender would not sign us in (${res.status}).`,
    );
  }
  cachedToken = String(out.token);
  cachedUntil = Date.now() + 7 * 3600e3;
  return cachedToken;
}

/*  One retry, only on 401, only once. A stale token looks identical to a
    redeploy or a rotated SESSION_SECRET from here. Retrying anything else
    would risk sending the same notification to the congregation twice. */
async function callSender(path: string, payload: unknown) {
  const go = async (token: string) =>
    await fetch(`${SENDER_URL}${path}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(payload),
    });

  let res = await go(await senderToken());
  if (res.status === 401) {
    cachedToken = "";
    cachedUntil = 0;
    res = await go(await senderToken());
  }
  return { status: res.status, body: await res.json().catch(() => ({})) };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST")    return reply(405, { error: "POST only" });

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return reply(401, { error: "Sign in first." });

  /*  Checked BEFORE anything is recorded. A row saying somebody tried to send,
      when the site was never configured to send, is a misleading entry in a
      log that has to be trustworthy. */
  if (!SENDER_URL || !SENDER_PW) {
    return reply(501, {
      error: "Sending to the app is not set up on this site yet. Whoever looks " +
             "after the website needs to add APP_SENDER_URL and " +
             "APP_SENDER_PASSWORD to the Edge Function secrets.",
    });
  }

  let body: {
    topic?: string; title?: string; body?: string;
    image?: string; image_w?: number; image_h?: number;
    event_at?: string; keep_as_notice?: boolean;
  };
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "Could not read the request." });
  }

  const topic = String(body.topic || "").trim().toLowerCase();
  const title = String(body.title || "").trim();
  const text  = String(body.body  || "").trim();

  if (!TOPICS[topic]) return reply(400, { error: "Choose who this is going to." });
  if (!title || title.length > 70) {
    return reply(400, {
      error: "The heading has to be between 1 and 70 characters — it is read " +
             "on a locked phone.",
    });
  }
  if (!text) return reply(400, { error: "Write the message." });

  /*  A picture, or a message worth keeping, means /api/notice — which writes a
      row the app's Notices tab can show afterwards and takes 2000 characters.
      Otherwise /api/send, 220 characters, leaving nothing behind. The sender
      chooses, because a push is gone the moment somebody swipes it away. */
  const keep = body.keep_as_notice !== false;
  const hasPicture = typeof body.image === "string" && body.image.startsWith("data:");
  const asNotice = keep || hasPicture;

  if (!asNotice && text.length > 220) {
    return reply(400, {
      error: `That message is ${text.length} characters. Either shorten it to ` +
             "220, or tick “keep this on the app's Notices tab” — a kept " +
             "notice can be up to 2000.",
    });
  }
  if (text.length > 2000) {
    return reply(400, { error: `That message is ${text.length} characters. The limit is 2000.` });
  }

  /* ---- 1. RECORD THE INTENTION, AS THE CALLER ----------------------------
     This is also the permission check: app_notification_start() runs
     verified_admin(), so a caller who is not a two-step administrator is
     refused here and nothing is sent. There is no second check, because a
     second check is a second thing to get wrong. */
  const started = await fetch(`${URL_BASE}/rest/v1/rpc/app_notification_start`, {
    method: "POST",
    headers: { "content-type": "application/json", apikey: ANON, Authorization: auth },
    body: JSON.stringify({ p: { topic, title, body: text } }),
  });
  if (!started.ok) {
    const raw = await started.text();
    let msg = "";
    try { msg = JSON.parse(raw).message || ""; } catch { /* keep raw below */ }
    return reply(started.status === 403 || /two-step/i.test(msg) ? 403 : 400, {
      error: msg || "Could not record the notification, so nothing was sent. " +
                    raw.slice(0, 200),
    });
  }
  const id = String(await started.json());

  /* ---- 2. SEND IT -------------------------------------------------------- */
  let ok = false;
  let onesignalId = "";
  let recipients: number | null = null;
  let noticeId = "";
  let error = "";

  try {
    if (asNotice) {
      const { status, body: out } = await callSender("/api/notice", {
        topic, title, body: text,
        image: hasPicture ? body.image : undefined,
        image_w: hasPicture ? body.image_w : undefined,
        image_h: hasPicture ? body.image_h : undefined,
        event_at: body.event_at || undefined,
      });
      if (status >= 400) {
        error = String(out.error || `the app sender answered ${status}`);
      } else {
        noticeId = String((out.notice && out.notice.id) || "");
        /*  ok:true from /api/notice means THE NOTICE WAS SAVED, not that the
            push went out — the Worker returns 200 with sent:{sent:false} when
            OneSignal refuses. Conflating the two is how a screen comes to say
            "sent" about something nobody received. */
        ok = !!(out.sent && out.sent.sent);
        onesignalId = String((out.sent && out.sent.id) || "");
        recipients = (out.sent && typeof out.sent.recipients === "number")
          ? out.sent.recipients : null;
        if (!ok) {
          error = String((out.sent && out.sent.error) ||
                         "the notice was saved but the notification did not go out");
        }
      }
    } else {
      const { status, body: out } = await callSender("/api/send", {
        topic, title, body: text,
      });
      if (status >= 400) {
        error = String(out.error || `the app sender answered ${status}`);
      } else {
        ok = out.ok === true;
        onesignalId = String(out.id || "");
        recipients = typeof out.recipients === "number" ? out.recipients : null;
        if (!ok) error = "the app sender did not confirm it was sent";
      }
    }
  } catch (err) {
    error = (err as Error).message.slice(0, 300);
  }

  /* ---- 3. SAY HOW IT WENT ------------------------------------------------
     With the SERVICE key, because a signed-in account that could mark its own
     failed send as 'sent' would make the list worthless.

     Its failure does not fail the request: the notification has already gone
     out, and telling somebody it failed would invite them to send it again to
     a congregation that already has it. The row stays on 'sending', which is
     the honest state and is visible in the list. */
  let recorded = true;
  try {
    const fin = await fetch(`${URL_BASE}/rest/v1/rpc/app_notification_finish`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        apikey: SERVICE,
        Authorization: `Bearer ${SERVICE}`,
      },
      body: JSON.stringify({
        p_id: id,
        p: { ok, onesignal_id: onesignalId, recipients, error, notice_id: noticeId },
      }),
    });
    recorded = fin.ok;
  } catch {
    recorded = false;
  }

  return reply(ok ? 200 : 502, {
    ok,
    id,
    topic,
    topic_label: TOPICS[topic],
    kept_as_notice: asNotice,
    notice_id: noticeId || null,
    recipients,
    recorded,
    error: ok ? null : (error || "It did not send, and no reason came back."),
  });
});
