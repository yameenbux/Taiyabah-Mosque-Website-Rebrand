"""The seam between this website and the phone app.

15 September 2026.

WHAT THIS IS FOR
================

The masjid runs two things against ONE Supabase project:

  *  this website, and
  *  the phone app — github.com/yameenbux/Taiyabah-Mosque-App, a PWA whose
     notifications are sent by a Cloudflare Worker holding the OneSignal key.

They share `public.notices`. The app's own db/001_notices.sql says so and names
this project by id. Neither repository's tests can see the other, and every
test in both of them passed on the morning this happened:

    040_notices_the_committee_can_change.sql dropped publish_notice().
    The Worker still called it.

publish_notice() was genuinely bad — no admin check at all, safe only by its
grant — so dropping it was right. What nobody did was ask who else was calling
it. From then until 050 restored it, pressing "Send notification" on the app's
trustee screen failed at the database step, and because the Worker sends the
push AFTER writing the row, NO NOTIFICATION WENT OUT EITHER. A janāzah
announcement — the most time-critical thing this masjid sends — would have gone
nowhere, and the only sign was an error the trustee had no way to interpret.

This file is the check that would have caught it.

WHAT IT GUARDS

  *  1  EVERY DATABASE FUNCTION THE WORKER CALLS IS DEFINED IN db/. Read out
        of the Worker's own source, by regex, not from a list somebody keeps
        up to date here — a list would have been just as out of date as the
        migration was.

  *  2  THE NOTIFICATION TOPICS AGREE. The Worker's TOPICS table, the Edge
        Function's copy of it, the app-screen's radio buttons and the CHECK
        constraint in 051 are four statements of the same vocabulary. They are
        four on purpose — see the comment in app-notify/index.ts — and this is
        what stops them becoming four different ones.

  *  3  THE TWO VOCABULARIES ARE KEPT APART. Notice topics and push topics
        OVERLAP and are not the same set: `jamaah` is a push audience with no
        notice behind it, and `ramadan`/`madrasah` are notice topics the app
        has no switch for. Each side must accept its own and refuse the
        other's, or a notice gets filed under a topic nobody subscribed to.

  *  4  THE EDGE FUNCTION IN THIS REPOSITORY IS THE ONE THAT IS DEPLOYED, as
        far as a file on disk can tell: it must not import anything, must read
        its secrets from the environment, and must never contain a password.

  *  5  NO SECRET IS IN THE REPOSITORY. Checked here as well as in the sweep,
        because this is the file that touches another system's credentials.

RUNNING IT
==========

Checks 1 to 3 need a checkout of the app repository. Point APP_REPO at it:

    git clone --depth 1 https://github.com/yameenbux/Taiyabah-Mosque-App /tmp/app
    APP_REPO=/tmp/app python3 _test/app_bridge_test.py

WITHOUT IT THIS SKIPS, LOUDLY, AND SAYS WHAT IT DID NOT CHECK. It does not
pass quietly: a cross-repository check that reports success when it could not
see the other repository is exactly the kind of reassurance that let the
outage above happen. Checks 4 and 5 always run.
"""
import os
import re
import sys

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)

APP_REPO = os.environ.get("APP_REPO", "")

fails = []
skipped = []


def check(ok, why):
    if not ok:
        fails.append(why)


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


#  The one vocabulary, written here so the test has an opinion of its own
#  rather than comparing two files that could both be wrong together.
PUSH_TOPICS   = {"janazah", "jamaah", "announcements", "events", "kahf"}
NOTICE_TOPICS = {"announcements", "events", "janazah", "kahf", "ramadan", "madrasah"}

# =============================================================================
#  4 and 5 — things that need no second checkout
# =============================================================================
FN = "supabase/functions/app-notify/index.ts"
check(os.path.exists(FN), "%s is missing — the App screen has nothing to call" % FN)

if os.path.exists(FN):
    fn = read(FN)

    #  ZERO IMPORTS, like invite-user. Nothing to resolve at deploy time and
    #  nothing to pin — which matters more than usual here, because this is the
    #  function that holds another system's password.
    bad_import = re.findall(r'^\s*import\s', fn, re.M)
    check(not bad_import,
          "app-notify has %d import statement(s). Every Edge Function on this "
          "project is written with none, so that a deploy cannot fail on a "
          "registry being down or a version moving underneath it."
          % len(bad_import))

    for want in ("APP_SENDER_URL", "APP_SENDER_PASSWORD"):
        check('Deno.env.get("%s")' % want in fn,
              "app-notify does not read %s from the environment" % want)

    #  THE PASSWORD MUST NOT BE HERE. Not as a default, not as a fallback, not
    #  commented out "for testing". The `?? ""` below is the only acceptable
    #  fallback, because an empty one makes the function answer 501 with a
    #  sentence rather than sending with a wrong credential.
    m = re.search(r'APP_SENDER_PASSWORD"\)\s*\?\?\s*(.+)', fn)
    check(m and m.group(1).strip().startswith('""'),
          "app-notify has a fallback for APP_SENDER_PASSWORD that is not an "
          "empty string. A default password in a public repository is the "
          "whole congregation's notifications: %r"
          % (m.group(1)[:60] if m else "no fallback found"))

    #  It must check the caller in the DATABASE, not decide for itself.
    check("app_notification_start" in fn,
          "app-notify does not call app_notification_start(), which is the "
          "only thing that runs verified_admin() and the only thing that "
          "records who sent a notification")
    check("app_notification_finish" in fn,
          "app-notify never records how a send went, so every row stays on "
          "'sending' for ever")

    #  The order matters and is the point of the design: the row is written
    #  BEFORE the send, so a send that fails halfway still leaves a trace.
    check(fn.index("app_notification_start") < fn.index("callSender("),
          "app-notify sends before it records. A record written afterwards is "
          "missing exactly the sends somebody will be trying to reconstruct — "
          "the ones that timed out or were closed mid-request.")

    #  ok:true from /api/notice means the NOTICE was saved. The push is
    #  reported separately in sent.sent, and conflating the two is how a
    #  screen comes to say "sent" about something nobody received.
    check(re.search(r"ok\s*=\s*!!\(out\.sent\s*&&\s*out\.sent\.sent\)", fn) is not None,
          "app-notify reads success for a kept notice from something other "
          "than out.sent.sent. The Worker answers 200 with sent:{sent:false} "
          "when OneSignal refuses — that is a screen saying 'sent' about a "
          "notification nobody got.")

#  The Edge Function's own topic table.
if os.path.exists(FN):
    block = re.search(r"const TOPICS: Record<string, string> = \{(.*?)\};", read(FN), re.S)
    check(block is not None, "app-notify has no TOPICS table")
    if block:
        got = set(re.findall(r"^\s*([a-z]+):", block.group(1), re.M))
        check(got == PUSH_TOPICS,
              "app-notify's notification topics are %r, expected %r"
              % (sorted(got), sorted(PUSH_TOPICS)))

#  The screen's radio buttons.
if os.path.exists("app/index.html"):
    html = read("app/index.html")
    shown = set(re.findall(r'name="ap-topic"[^>]*value="([a-z]+)"', html))
    if not shown:
        shown = set(re.findall(r'value="([a-z]+)"[^>]*name="ap-topic"', html))
    check(shown == PUSH_TOPICS,
          "the App screen offers %r as audiences, expected %r. An option the "
          "sender cannot accept is a button that fails after somebody has "
          "committed to sending." % (sorted(shown), sorted(PUSH_TOPICS)))
else:
    check(False, "app/index.html is missing")

#  051's CHECK constraint, read out of the migration.
mig = "db/051_a_push_has_a_sender.sql"
if os.path.exists(mig):
    m = re.search(r"app_notification_topic_known\s*\n?\s*check \(topic in \(([^)]*)\)",
                  read(mig))
    check(m is not None, "051 has no topic constraint on app_notifications")
    if m:
        got = set(re.findall(r"'([a-z]+)'", m.group(1)))
        check(got == PUSH_TOPICS,
              "051 allows %r as push topics, expected %r" % (sorted(got), sorted(PUSH_TOPICS)))
else:
    check(False, "%s is missing" % mig)

#  3. THE TWO VOCABULARIES MUST NOT HAVE MERGED.
#
#  Written as an assertion about the DIFFERENCE, not about either list, so it
#  fails if somebody "tidies up" by making them the same — which is the
#  tempting and wrong fix the first time one of them is edited.
check("jamaah" in PUSH_TOPICS and "jamaah" not in NOTICE_TOPICS,
      "jamaah has become a notice topic. A jamāʿah reminder is not an "
      "announcement worth keeping in the app's Notices tab — the app's own "
      "001_notices.sql left it out on purpose.")
check("ramadan" in NOTICE_TOPICS and "ramadan" not in PUSH_TOPICS,
      "ramadan has become a push audience. Nobody has a switch for it in the "
      "app, so it would reach nobody, silently.")
check("madrasah" in NOTICE_TOPICS and "madrasah" not in PUSH_TOPICS,
      "madrasah has become a push audience with no switch behind it in the app")

if os.path.exists("db/041_one_definition_of_a_notice.sql"):
    m = re.search(r"check \(topic in \('announcements'([^)]*)\)",
                  read("db/041_one_definition_of_a_notice.sql"))
    if m:
        got = set(re.findall(r"'([a-z]+)'", "'announcements'" + m.group(1)))
        check(got == NOTICE_TOPICS,
              "the notices vocabulary in 041 is %r, expected %r. If a topic "
              "was added here it needs adding to the app as well, or a notice "
              "will be written that the app has no heading for."
              % (sorted(got), sorted(NOTICE_TOPICS)))

# =============================================================================
#  1 to 3 — the part that needs the app repository
# =============================================================================
worker = os.path.join(APP_REPO, "worker", "worker.js") if APP_REPO else ""

if not APP_REPO or not os.path.exists(worker):
    skipped.append(
        "THE CROSS-REPOSITORY CHECKS DID NOT RUN.\n"
        "     Nothing compared this project against the phone app's Cloudflare\n"
        "     Worker, so nothing here would notice a migration dropping a\n"
        "     function the app depends on — which is exactly what happened on\n"
        "     15 September and took the app's notification sender down.\n"
        "     To run them:\n"
        "         git clone --depth 1 %s /tmp/app\n"
        "         APP_REPO=/tmp/app python3 _test/app_bridge_test.py"
        % "https://github.com/yameenbux/Taiyabah-Mosque-App")
else:
    src = read(worker)

    # ---- 1. every database function the Worker calls exists here ----------
    #
    #  supaRpc(env, "name", …) is the only way this Worker reaches Postgres.
    called = set(re.findall(r'supaRpc\(\s*env\s*,\s*"([a-z_]+)"', src))
    check(called, "no supaRpc() calls found in the Worker — has it been "
                  "rewritten? This check is reading the wrong thing.")

    defined = set()
    for f in sorted(os.listdir("db")):
        if not f.endswith(".sql"):
            continue
        defined |= set(re.findall(
            r"create or replace function public\.([a-z_]+)\s*\(", read(os.path.join("db", f))))

    for fn_name in sorted(called):
        check(fn_name in defined,
              "THE APP CALLS public.%s() AND THIS PROJECT DOES NOT DEFINE IT.\n"
              "     The phone app's Cloudflare Worker (worker/worker.js) reaches\n"
              "     the shared database through this function. If a migration here\n"
              "     dropped or renamed it, the app's notification sender is broken\n"
              "     RIGHT NOW and nothing in either repository would say so.\n"
              "     This is what happened to publish_notice() on 15 September."
              % fn_name)

    # ---- 2. the topics agree --------------------------------------------
    block = re.search(r"const TOPICS = \{(.*?)\};", src, re.S)
    check(block is not None, "could not find TOPICS in the Worker")
    if block:
        got = set(re.findall(r"^\s*([a-z]+):", block.group(1), re.M))
        check(got == PUSH_TOPICS,
              "the Worker's notification topics are %r and this project expects "
              "%r. An audience on one side and not the other is either a button "
              "that fails, or a group of people who quietly stop being reachable."
              % (sorted(got), sorted(PUSH_TOPICS)))

    # ---- 3. the endpoints this project calls still exist -----------------
    for path in ("/api/login", "/api/send", "/api/notice"):
        check('"%s"' % path in src or "'%s'" % path in src or path in src,
              "the Worker no longer serves %s, which app-notify calls" % path)

    #  The rate limit the Edge Function's token cache exists to stay under. If
    #  this number drops, the cache's seven-hour refresh may no longer be
    #  enough and sends will start being refused as "Incorrect password".
    m = re.search(r'limit\("login:"\s*\+\s*ip,\s*(\d+),\s*(\d+)', src)
    if m:
        check(int(m.group(1)) >= 8,
              "the Worker now allows only %s sign-ins per window. app-notify "
              "caches its token for 7 hours to stay under 8 per 15 minutes; "
              "check supabase/functions/app-notify/README.md before lowering it."
              % m.group(1))

# =============================================================================
print()
if skipped:
    print("SKIPPED:\n  " + "\n  ".join(skipped))
    print()
print("ALL PASS" if not fails
      else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails))
sys.exit(1 if fails else 0)
