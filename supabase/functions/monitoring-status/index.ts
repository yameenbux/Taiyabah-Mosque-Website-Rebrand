/* ===========================================================================
   monitoring-status — what Sentry and UptimeRobot say right now

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   12 October 2026

   health_check() answers one question honestly and no other: what does the
   database think of itself. It cannot know a visitor's browser threw an
   error, or that the site is unreachable from outside this stack entirely —
   Sentry and UptimeRobot exist for exactly those two blind spots, and until
   now they lived in their own separate dashboards, nowhere near the System
   Health screen that already brought everything else together.

   BOTH API KEYS ARE READ-ONLY, ON PURPOSE. This endpoint cannot resolve a
   Sentry issue, pause a monitor, or change anything — it only reads. A
   browser-shipped key would have let anyone with the page open do the same;
   keeping the keys server-side and read-only means the worst this function
   can leak is "0 errors" when it should say "3", never a way to touch either
   service.

   SAME GATE AS EVERY OTHER ADMIN-ONLY FUNCTION HERE: staff_list() with the
   caller's own token, which runs verified_admin() in Postgres — admin role
   AND two-step completed. A function that trusted the page instead would be
   a public read of this masjid's error-tracking and uptime history.

   SECRETS (Supabase dashboard, never in a file):
       SENTRY_AUTH_TOKEN      personal token, scopes project:read + event:read
       UPTIMEROBOT_API_KEY    the Read-Only key, not the main account key
   =========================================================================== */

const URL_BASE = Deno.env.get("SUPABASE_URL")!;
const ANON     = Deno.env.get("SUPABASE_ANON_KEY")!;

const SENTRY_TOKEN = Deno.env.get("SENTRY_AUTH_TOKEN") ?? "";
const UPTIME_KEY   = Deno.env.get("UPTIMEROBOT_API_KEY") ?? "";

/* Not secrets — which Sentry project and which UptimeRobot monitor, same
   as a Stripe Payment Link is just pasted into the template. Change these
   two lines if either service's project/monitor is ever recreated. */
const SENTRY_REGION  = "https://de.sentry.io";
const SENTRY_ORG     = "ysb-ventures-ltd";
const SENTRY_PROJECT = "javascript";
const UPTIME_MONITOR_ID = "804225832";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type, apikey",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}

async function sentryStatus() {
  if (!SENTRY_TOKEN) return { ok: false, error: "not configured" };
  try {
    const url = `${SENTRY_REGION}/api/0/projects/${SENTRY_ORG}/${SENTRY_PROJECT}` +
                `/issues/?query=is:unresolved&statsPeriod=24h&limit=100`;
    const res = await fetch(url, {
      headers: { Authorization: `Bearer ${SENTRY_TOKEN}` },
    });
    if (!res.ok) return { ok: false, error: `Sentry said ${res.status}` };
    const issues = await res.json();
    const count = Array.isArray(issues) ? issues.length : 0;
    return { ok: true, unresolved_24h: count, capped: count === 100 };
  } catch {
    return { ok: false, error: "could not reach Sentry" };
  }
}

async function uptimeStatus() {
  if (!UPTIME_KEY) return { ok: false, error: "not configured" };
  try {
    const res = await fetch("https://api.uptimerobot.com/v2/getMonitors", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        api_key: UPTIME_KEY,
        monitors: UPTIME_MONITOR_ID,
        format: "json",
      }),
    });
    if (!res.ok) return { ok: false, error: `UptimeRobot said ${res.status}` };
    const data = await res.json();
    const m = data?.monitors?.[0];
    if (!m) return { ok: false, error: "monitor not found" };
    //  v2 status codes: 0 paused, 1 not checked yet, 2 up, 8 seems down, 9 down.
    const up = m.status === 2;
    const down = m.status === 8 || m.status === 9;
    return {
      ok: true,
      status: up ? "up" : down ? "down" : "unknown",
      last_check: m.response_times?.[0]?.datetime ?? null,
    };
  } catch {
    return { ok: false, error: "could not reach UptimeRobot" };
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });

  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) {
    return reply(401, { error: "Sign in first." });
  }

  /* IS THE CALLER REALLY AN ADMINISTRATOR? Asked of the database, with the
     caller's own token — never trust the page saying so. */
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
    return reply(403, { error: "Only an administrator who has completed two-step can see this." });
  }

  const [sentry, uptime] = await Promise.all([sentryStatus(), uptimeStatus()]);
  return reply(200, { sentry, uptime });
});
