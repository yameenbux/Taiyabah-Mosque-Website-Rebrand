# Setting up email — step by step

**What you are doing:** letting the website send emails from a masjid address
instead of not being able to send them at all.

**How long:** about 45 minutes, plus up to a few hours' waiting if you have to
add DNS records.

**Why it matters:** three things are switched off right now waiting on this —
staff invitations, the booking alerts to the office, and confirmation emails to
people who book the hall or request a nikāḥ date.

You will need to be logged into **one.com** and **Supabase**.

Using `taiyabahmosque.co.uk` for now, since that is the one you have access to.

---

## Step 1 — Make a new mailbox just for sending

**Why:** Supabase needs a mailbox address and its password. That password can
*read* mail as well as send it. So we do not give it the office inbox — we make
an empty one that only ever sends. If the password ever leaks, there is nothing
in there to steal.

1. Log into **one.com** and open the control panel for `taiyabahmosque.co.uk`.
2. Go to **Mail** → **Email accounts** (it may say "Manage email accounts").
3. Click to create a new account.
4. Name it: **`noreply@taiyabahmosque.co.uk`**
5. Give it a long password. **Write it down somewhere safe** — you will need it
   in Step 4, and you will not be shown it again.
6. Save.

**You will know it worked when:** `noreply@taiyabahmosque.co.uk` appears in
your list of email accounts.

**Do not** set up this mailbox on your phone or read mail into it. It exists
only to send.

---

## Step 2 — Check the DNS records that are probably already there

**Why:** these three records are how Gmail and Outlook decide your email is
genuine and not somebody pretending to be the masjid. Without them your
emails go to spam.

In plain English:

- **SPF** — a list of who is allowed to send email as this domain
- **DKIM** — a signature proving the email really came from there
- **DMARC** — what receivers should do if the first two fail

1. In the one.com control panel, go to **DNS** → **DNS settings** for
   `taiyabahmosque.co.uk`.
2. Look down the list for a record of type **TXT** whose value starts with
   `v=spf1`.
3. Look for another entry mentioning **DKIM** or `_domainkey`.

**If both are there — good, one.com has already done it.** Go to Step 3.

**If they are missing**, search one.com's help centre for "SPF" and add the
record exactly as they publish it. Do not copy an SPF record from anywhere
else — it has to name one.com's own mail servers.

---

## Step 3 — Add the DMARC record

Almost nobody has this one already, and it is the difference between landing in
the inbox and landing in spam.

Still in **DNS settings**, add a new record:

| Field | What to put |
|---|---|
| Type | `TXT` |
| Name / Host | `_dmarc` |
| Value | `v=DMARC1; p=none; rua=mailto:admin@taiyabahmosque.co.uk` |
| TTL | leave as the default |

Change `admin@` to whichever masjid address should receive the reports.

**What `p=none` means:** "tell me about problems but do not block anything
yet." That is what you want while testing. It can be tightened later once you
know everything is passing.

**You will know it worked when:** the record appears in the list. It can take
anywhere from a few minutes to a few hours to take effect.

---

## Step 4 — Put the settings into Supabase

1. Open the **Supabase** dashboard and choose the masjid's project.
2. In the left sidebar: **Authentication**.
3. Find **SMTP Settings** (it may sit under "Emails").
4. Turn on **Enable Custom SMTP**.
5. Fill in exactly this:

| Field | Value |
|---|---|
| Sender email | `noreply@taiyabahmosque.co.uk` |
| Sender name | `Taiyabah Masjid` |
| Host | `send.one.com` |
| Port | `587` |
| Username | `noreply@taiyabahmosque.co.uk` |
| Password | the password from Step 1 |

6. Save.

**The single most common mistake:** the **Sender email** and the **Username**
must be the *same address*. one.com will refuse to send if you authenticate as
one mailbox and try to send as another.

**Note:** the username is the **full email address**, not just `noreply`.

---

## Step 5 — Raise the sending limit

**Do not skip this one.** Supabase caps email at **2 per hour** by default, and
setting up SMTP does not lift the cap on its own. Two an hour is not enough to
even test properly.

1. Still in **Authentication**, go to **Rate Limits**.
2. Find the limit for **sending emails**.
3. Raise it. Something like **30 per hour** is plenty — the masjid will never
   approach one.com's own ceiling of 250 an hour.
4. Save.

---

## Step 6 — Test it

1. In Supabase: **Authentication** → **Users**.
2. Click **Invite user** (or **Add user** → invite by email).
3. Put in **your own personal email address** — a Gmail or Hotmail one, not a
   masjid one.
4. Send it.

**You will know it worked when:** the email arrives, and it is *from*
`noreply@taiyabahmosque.co.uk`.

This test proves something specific and important. Before custom SMTP,
Supabase would only send to people on the Supabase project team — so an
invitation to a new masjid volunteer would simply never have arrived. If your
personal address receives it, the whole path is working.

**Then delete that test user** in Supabase → Authentication → Users, so a
stray account is not left behind.

---

## Step 7 — Check it is not heading for spam

1. Open the test email **in Gmail**.
2. Click the **three dots** at the top right of the message → **Show original**.
3. At the top you will see a small table.

**You want to see `PASS` next to SPF and next to DKIM.**

If either says FAIL or SOFTFAIL, go back to Step 2 — a record is missing or
wrong. If DMARC says PASS as well, you are fully set up.

---

## If something goes wrong

**"535 Authentication failed" or similar**
The password is wrong, or the username is not the full email address. It must
be `noreply@taiyabahmosque.co.uk`, not `noreply`.

**Nothing arrives at all**
Check your spam folder first. Then check that Sender email and Username are the
same address — see the warning in Step 4.

**It arrives but goes to spam**
Do Step 7 and see which check is failing. Usually SPF or DKIM is missing.
Newly-configured domains also look slightly suspicious to Gmail for the first
few days; this settles down.

**"Rate limit exceeded"**
Step 5 was skipped, or you have sent several test emails in quick succession.
Wait an hour or raise the limit further.

**Still stuck**
Supabase → **Logs** → **Auth Logs** shows the actual error the mail server
returned, which is usually much more specific than what the screen says.

---

## What this switches on

Once the test email arrives, three things that have been waiting can be turned
on:

1. **Staff invitations** — so the masjid can add and remove its own people
   without going into Supabase, and without ringing anyone.
2. **Booking alerts to the office** — built and switched off since August.
   Right now a hall booking sits in the portal until somebody thinks to look.
3. **Confirmations to the public** — so a family who books the hall gets an
   email with their reference on it, rather than only seeing it once on screen.

---

## For the record

- Mailbox used for sending: `noreply@taiyabahmosque.co.uk` — sends only, never
  read
- Mail server: `send.one.com`, port 587
- one.com's limits: 250 emails an hour, 25 every five minutes
- The password for that mailbox is a credential. It belongs wherever the
  masjid keeps its other passwords, known to **two** people, not one.

**One thing still to settle:** the website is `taiyabahmasjid.com` and the
email is `taiyabahmosque.co.uk`. Mail from one about the other works, but some
recipients will read the mismatch as phishing. Worth deciding which name the
masjid is actually using and making both match it.
