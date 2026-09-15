[README.md](https://github.com/user-attachments/files/32258237/README.md)
# app-notify

Sends a notification to the masjid's phone app, on behalf of a committee
member who is signed in to the Admin Centre.

## Why it is not just a fetch from the browser

The app's sender is a Cloudflare Worker in a different repository
(`yameenbux/Taiyabah-Mosque-App`, `worker/worker.js`). It authenticates with
**one shared password** and issues a bearer token whose entire payload is
`{"exp": …}` — no subject, no name, no way to tell one holder from another.
Its own comment is candid: *"The password plus an 8-hour session is the real
control."*

That is a sensible design for one screen used by two trustees on a phone. It is
the wrong thing to paste into the Admin Centre, because it would mean asking
somebody who has already signed in with an account **and an authenticator** to
type a second shared password — and it would put that password in a second
place to be rotated and leaked from.

So the password is an Edge Function secret. Nobody on the committee sees it,
and the screen has no password box.

## What it guarantees

**The sender's name comes from the JWT, not from this function.** `app-notify`
calls `app_notification_start()` with the *caller's own token*. That runs
`verified_admin()` in Postgres — admin role **and** aal2 — and writes a row
whose `actor` is `auth.uid()`. This function is never told who the sender is
and cannot say. A bug here can fail to send; it cannot write the wrong person's
name against an announcement of a death.

**The record is written before the send, not after.** A record written
afterwards is missing exactly the sends somebody will later be trying to
reconstruct — the ones that timed out, the ones where the browser was closed
mid-request, the ones OneSignal refused. A row still saying `sending` an hour
later is itself the signal.

**`ok` means received, not saved.** The Worker's `/api/notice` returns HTTP 200
with `sent: {sent:false, error:…}` when the notice was stored but the push was
refused. This function reports `ok` from `sent.sent`, never from the HTTP
status, because a screen that says "sent" about something nobody received is
worse than one that says nothing.

## What it does NOT change

Nothing in Cloudflare, and nothing in the app repository.

This is server-to-server, so there is no `Origin` header and nothing for the
Worker's CORS to reject — the Worker only ever *omits* the allow-header for an
unknown origin, it never refuses the request. `ALLOWED_ORIGIN` does not need
the website added to it.

The app's own trustee screen (`admin.html`) keeps working exactly as it does.
That is deliberate: a janāzah notice usually needs sending from a phone, at the
masjid, in a hurry, which is the worst possible moment to be asked for a
desktop sign-in and a six-digit code. The phone screen is the fast path; this
one is the considered one, and it is the one that leaves a record.

## Secrets

Set in the Supabase dashboard, **never in a file**:
*Project settings → Edge Functions → Secrets.*

| Name | Value |
|---|---|
| `APP_SENDER_URL` | the Worker's address, e.g. `https://taiyabah-sender.<account>.workers.dev` |
| `APP_SENDER_PASSWORD` | the password the app's trustee screen asks for |

Until both are set the function answers **501** with a sentence saying so, and
the screen shows it. It does not record an attempt, because a log entry saying
somebody tried to send when the site was never configured to send is a
misleading entry in a log that has to be trustworthy.

**If the password is rotated in Cloudflare it must be changed here too.** It is
the one thing that ties the two systems together, and the failure looks like a
wrong password on the committee's screen — which is why the message the screen
shows in that case says explicitly that it is the masjid's stored password and
not theirs.

## The login cache is not an optimisation

The Worker rate-limits `/api/login` to **eight attempts per fifteen minutes per
IP address**, and every call from here arrives from Supabase's addresses. Without
the module-scope token cache, the ninth send in a quarter of an hour would be
refused and the screen would report it as a password problem. The token is
refreshed an hour before it expires, because a token that dies mid-send costs a
real notification and the login it saves is free.

## Deploying

    supabase functions deploy app-notify

`index.ts` here and the deployed copy are meant to be byte for byte identical.
The header is deliberately short so that they can be: the long reasoning lives
in this file instead. `invite-user` carries a note about a message that was
fixed in production on 13 September and never written back to this repository —
found only by diffing every deployed function against it. One file, one truth.

## Related

* `db/051_a_push_has_a_sender.sql` — the table and the three functions.
* `db/050_the_app_can_publish_a_notice_again.sql` — why the Worker's
  `publish_notice()` had to be restored.
* `_test/app_bridge_test.py` — fails if the two repositories' ideas of the
  notification topics, or of which database functions exist, drift apart.
