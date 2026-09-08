/* ===========================================================================
   Taiyabah Masjid — /auth/
   Bolton Central Islamic Society · Registered charity 1041569

   Completes every email link the masjid sends: invitations, password resets,
   email confirmations and email-address changes.

   WHY IT IS NOT SUPABASE'S OWN LINK
   ---------------------------------
   Supabase's default templates link to <project>.supabase.co. A brand-new
   sending domain pointing at an unrelated third-party domain looks like
   phishing to a spam filter, and the first live test landed in Outlook's junk
   folder. It also looks wrong to anybody who reads a link before clicking it.

   So the templates build the link out of {{ .TokenHash }} and point here.
   The token is identical and still single-use; only the domain changes.

   Security notes:
     - Only the anon key is used. The token in the URL is what authenticates,
       and Supabase is what checks it.
     - `next` is checked against an allowlist. A page that redirects wherever
       it is told, immediately after signing somebody in, is an open redirect
       worth having.
     - The token is stripped out of the address bar as soon as it has been
       used, so it is not left sitting in browser history or copied into a
       message by somebody sharing "the link that worked".
   =========================================================================== */
(function () {
  "use strict";

  var cfg = window.TAIYABAH_CONFIG || {};
  var el  = function (id) { return document.getElementById(id); };

  function show(which) {
    ["working", "password", "done", "error"].forEach(function (v) {
      var node = el("v-" + v);
      if (node) node.hidden = v !== which;
    });
  }

  // What went wrong, in words somebody can act on. A verification failure is
  // nearly always one of three ordinary things, and saying "otp_expired" to a
  // parent trying to confirm their email helps nobody.
  function fail(title, sub, what) {
    el("err-title").textContent = title;
    el("err-sub").textContent   = sub;
    el("err-what").textContent  = what || "";
    show("error");
  }

  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.indexOf("PASTE_") === 0) {
    return fail("This page isn't connected yet",
                "The website's settings have not been filled in.",
                "Please ring the office on 01204 535 997.");
  }

  var apiUrl = String(cfg.SUPABASE_URL || "").trim()
                 .replace(/\/+$/, "").replace(/\/rest\/v1$/, "");

  var sb = window.supabase.createClient(apiUrl, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
  });

  // --- what the link said -----------------------------------------------
  var q = new URLSearchParams(window.location.search);

  // Supabase can also report a failure back in the URL fragment rather than
  // calling the endpoint at all — an expired invite, typically. Read it, so
  // the visitor gets the real reason instead of a generic one.
  var frag = new URLSearchParams((window.location.hash || "").replace(/^#/, ""));

  var tokenHash = q.get("token_hash");
  var type      = q.get("type");
  var next      = q.get("next");

  // Where somebody may be sent afterwards. Anything not on this list falls
  // back to the site itself. Relative paths only — an absolute URL here would
  // be the open redirect this list exists to prevent.
  var ALLOWED_NEXT = {
    "/portals/": "the admin area",
    "/venue/":   "hall hire and nikāḥ",
    "/account/": "your account",
    "/":         "the website"
  };

  function destination() {
    if (next && Object.prototype.hasOwnProperty.call(ALLOWED_NEXT, next)) return next;
    return "/";
  }
  function destinationName() {
    return ALLOWED_NEXT[destination()] || "the website";
  }

  // Types that mean "this person has proved they own this address, now let
  // them set a password". The others are simply confirmations.
  var NEEDS_PASSWORD = { invite: true, recovery: true };

  var TITLES = {
    invite:       "Choose a password",
    recovery:     "Choose a new password",
    signup:       "Email confirmed",
    email:        "Email confirmed",
    email_change: "Email address changed",
    magiclink:    "You are signed in"
  };

  // --- take the token out of the address bar ------------------------------
  // Once used it is spent, but a URL containing a one-time credential should
  // not sit in browser history, get bookmarked, or be pasted into a WhatsApp
  // message by somebody explaining how they signed in.
  function scrubUrl() {
    try {
      window.history.replaceState({}, document.title,
        window.location.pathname);
    } catch (e) { /* nothing depends on this working */ }
  }

  // --- the error the fragment may be carrying -----------------------------
  function fragmentError() {
    var code = frag.get("error_code") || frag.get("error");
    if (!code) return null;
    var desc = (frag.get("error_description") || "").replace(/\+/g, " ");
    return { code: code, desc: desc };
  }

  function explain(message) {
    var m = String(message || "").toLowerCase();
    if (/expired/.test(m)) {
      return ["This link has expired",
              "Links in emails from the masjid are only good for a short while.",
              "Use “forgotten password” on the sign-in page to get a fresh one, " +
              "or ring the office on 01204 535 997."];
    }
    if (/already|used|not found|invalid/.test(m)) {
      return ["This link has already been used",
              "Each link works once. If you have already set your password, you can just sign in.",
              "If you have not, ring the office on 01204 535 997 and ask for a fresh link."];
    }
    return ["This link cannot be used",
            "Something about it was not accepted.",
            "Ask the office to send you another one, or ring 01204 535 997."];
  }

  // Who the token turned out to belong to. Needed to write their profile row,
  // and to prefill the name if whoever invited them already supplied one.
  var who = null;

  // --- setting a password -------------------------------------------------
  function askForPassword() {
    el("pw-title").textContent = TITLES[type] || "Choose a password";
    el("pw-sub").textContent = type === "recovery"
      ? "Your old password no longer works. Pick a new one."
      : "This is the password you will use to sign in from now on.";

    show("password");

    // Only asked on an invitation. Somebody resetting a password already has
    // a name on file and should not be made to retype it.
    var wrap = el("pw-name-wrap");
    if (type === "invite") {
      wrap.hidden = false;
      // If the invitation carried a name, use it — the person can correct it.
      // Supabase's own dashboard invite carries none, so this is usually
      // empty today and will fill itself in once invitations are sent from
      // the portal instead.
      var given = (who && who.user_metadata && who.user_metadata.full_name) || "";
      if (given && given !== (who && who.email)) el("pw-name").value = given;
      el("pw-name").focus();
    } else {
      wrap.hidden = true;
      el("pw1").focus();
    }
  }

  el("pw-form").addEventListener("submit", function (e) {
    e.preventDefault();
    var err = el("pw-err");
    var btn = el("pw-submit");
    var a = el("pw1").value, b = el("pw2").value;

    function problem(msg) {
      err.textContent = msg; err.hidden = false; el("pw1").focus();
    }
    err.hidden = true;

    var wantName = type === "invite";
    var name = wantName ? el("pw-name").value.trim().replace(/\s+/g, " ") : null;

    if (wantName) {
      // Without this the portal lists staff by email address, which is how
      // "who agreed this booking?" becomes unanswerable a year later.
      if (name.length < 2 || !/[A-Za-z\u00C0-\u024F]/.test(name)) {
        return problem("Please enter your name, so the masjid knows who you are.");
      }
      if (name.length > 80) return problem("That name is too long.");
    }

    if (a.length < 10) return problem("Please use at least 10 characters.");
    if (a !== b)       return problem("The two passwords are not the same.");

    btn.disabled = true; btn.textContent = "Saving…";

    // The password and the name go together. `data` sets the account's own
    // metadata; the profiles row is written separately because the trigger
    // that copies one into the other only runs when the account is created,
    // and by now it has been.
    var patch = wantName ? { password: a, data: { full_name: name } }
                         : { password: a };

    sb.auth.updateUser(patch).then(function (res) {
      if (res.error) throw new Error(res.error.message);
      if (!wantName || !who || !who.id) return null;
      return sb.from("profiles").update({ full_name: name }).eq("id", who.id);
    }).then(function (prof) {
      // A profile that would not save is worth knowing about but is not worth
      // stopping for: the password is already set and the person can get on.
      // The name shows as their email until somebody fixes it.
      if (prof && prof.error && window.console) {
        console.warn("profile name not saved:", prof.error.message);
      }
      finish();
    }).catch(function (e2) {
      btn.disabled = false; btn.textContent = "Save my password";
      problem("That could not be saved — " + (e2 && e2.message) +
              ". Please try again, or ring the office on 01204 535 997.");
    });
  });

  // --- the end ------------------------------------------------------------
  function finish() {
    el("done-title").textContent = TITLES[type] || "All set";
    el("done-sub").textContent = NEEDS_PASSWORD[type]
      ? "Your password is saved. You can sign in with it from now on."
      : "Thank you — your email address is confirmed.";
    var go = el("done-go");
    go.setAttribute("href", ".." + destination());
    go.textContent = "Continue to " + destinationName();
    show("done");
  }

  // --- start --------------------------------------------------------------
  show("working");

  var fe = fragmentError();
  if (fe) {
    scrubUrl();
    var e1 = explain(fe.desc || fe.code);
    return fail(e1[0], e1[1], e1[2]);
  }

  if (!tokenHash || !type) {
    // Somebody has typed the address in, or followed a link that lost its
    // query string. Not an error on their part; say what the page is for.
    return fail("There is nothing to confirm here",
                "This page finishes off links sent in emails from the masjid.",
                "Open the link in the email itself. If it will not work, ring the office on 01204 535 997.");
  }

  sb.auth.verifyOtp({ token_hash: tokenHash, type: type })
    .then(function (res) {
      scrubUrl();
      if (res.error) throw new Error(res.error.message);
      who = (res.data && res.data.user) || null;
      if (NEEDS_PASSWORD[type]) return askForPassword();
      finish();
    })
    .catch(function (e3) {
      scrubUrl();
      var parts = explain(e3 && e3.message);
      fail(parts[0], parts[1], parts[2]);
    });
})();
