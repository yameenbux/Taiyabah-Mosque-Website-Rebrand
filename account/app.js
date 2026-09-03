/* ===========================================================================
   Taiyabah Masjid — shop accounts
   Bolton Central Islamic Society · Registered charity 1041569

   Register -> confirm your email -> sign in -> signed in.

   Notes for anyone maintaining this:

     - Shop customers are ordinary Supabase users with NO role. That is the
       whole definition. Row Level Security already gives a roleless user their
       own profile and nothing else — they cannot see another customer, a hall
       booking, or anything in the madrasah system. No migration was needed.

     - There is deliberately NO two-factor step here. Staff portals require it
       because they hold other people's data; making somebody set up an
       authenticator app to buy a jar of honey would simply lose the sale.

     - Only the anon key is used. RLS is the real boundary, not this file.
   =========================================================================== */
(function () {
  "use strict";

  var cfg = window.TAIYABAH_CONFIG || {};
  var el  = function (id) { return document.getElementById(id); };

  var VIEWS = ["view-loading", "view-register", "view-check", "view-signin", "view-done"];
  function show(view) {
    VIEWS.forEach(function (v) {
      var n = el(v);
      if (n) n.hidden = v !== view;
    });
  }

  function setError(id, message) {
    var box = el(id);
    if (!box) return;
    if (!message) { box.hidden = true; box.textContent = ""; return; }
    box.textContent = message;
    box.hidden = false;
  }

  function busy(button, isBusy, idleLabel) {
    if (!button) return;
    button.disabled = isBusy;
    button.textContent = isBusy ? "Please wait…" : idleLabel;
  }

  // --- config guard ---------------------------------------------------------
  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.indexOf("PASTE_") === 0) {
    show("view-register");
    setError("register-error",
      "Accounts aren't connected yet — config.js still has placeholder values in it.");
    return;
  }

  // The Supabase dashboard shows the URL with /rest/v1/ on the end. Pasting it
  // verbatim has broken this twice before, so normalise to the bare origin.
  var apiUrl = String(cfg.SUPABASE_URL || "").trim()
                 .replace(/\/+$/, "").replace(/\/rest\/v1$/, "");

  var sb = window.supabase.createClient(apiUrl, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true }
  });

  // --- what the signed-in screen shows --------------------------------------
  function renderDone(user) {
    var name = (user.user_metadata && user.user_metadata.full_name) || user.email;
    el("done-name").textContent  = name;
    el("done-email").textContent = user.email;
    show("view-done");
    offerAdminArea(user);
  }

  // Administrators use the same login here as they do for the shop, so this
  // page is where they arrive. Rather than expecting them to know a URL, show
  // a second button to /portals/ — but only if they really are one.
  //
  // Three things worth keeping straight if you change this:
  //
  //   1. The role comes from user_roles under RLS, never from anything the
  //      browser holds. A customer's own read returns no rows, so no button.
  //
  //   2. It fails closed. Any error — offline, a policy change, a typo in a
  //      column name — hides the button. A button that appears when we cannot
  //      confirm the role would be worse than no button, because it would
  //      teach an attacker which login is worth pursuing.
  //
  //   3. The button is a signpost, not a door. It grants nothing. The portals
  //      ask for the authenticator code, and since migration 011 the database
  //      refuses sensitive rows to a session that has not passed it.
  function offerAdminArea(user) {
    var btn = el("done-admin");
    if (!btn) return;
    btn.hidden = true;
    if (!user || !user.id) return;

    sb.from("user_roles").select("role").eq("user_id", user.id)
      .then(function (res) {
        if (res.error) return;                       // fail closed, say nothing
        var roles = (res.data || []).map(function (r) { return r.role; });
        btn.hidden = roles.indexOf("admin") === -1;
      })
      .catch(function () { /* fail closed */ });
  }

  // --- register -------------------------------------------------------------
  el("register-form").addEventListener("submit", function (e) {
    e.preventDefault();
    setError("register-error", "");

    var name     = el("reg-name").value.trim();
    var email    = el("reg-email").value.trim();
    var password = el("reg-password").value;

    if (name.length < 2)      { setError("register-error", "Please enter your full name."); return; }
    if (email.indexOf("@") < 1) { setError("register-error", "Please enter a valid email address."); return; }
    if (password.length < 8)  { setError("register-error", "Please choose a password of at least 8 characters."); return; }

    var btn = el("register-submit");
    busy(btn, true);

    // Where the confirmation link should bring them back to.
    //
    // Without this, Supabase sends them to the project's Site URL, which
    // defaults to http://localhost:3000 — a developer's machine that no
    // customer can reach. Deriving it from wherever this page is actually
    // being served means it keeps working on the staging address and after
    // the domain moves, with no code change.
    //
    // The address still has to be allow-listed under
    // Authentication -> URL Configuration -> Redirect URLs, or Supabase
    // silently falls back to the Site URL.
    var backHere = window.location.href.split("#")[0].split("?")[0];

    sb.auth.signUp({
      email: email,
      password: password,
      options: { data: { full_name: name }, emailRedirectTo: backHere }
    }).then(function (res) {
      busy(btn, false, "Create account");

      if (res.error) {
        var m = (res.error.message || "").toLowerCase();
        if (m.indexOf("already registered") !== -1 || m.indexOf("already been registered") !== -1) {
          setError("register-error",
            "An account already exists with this email address. Sign in instead, or use the forgotten-password link.");
        } else if (m.indexOf("signups not allowed") !== -1 || m.indexOf("signup is disabled") !== -1) {
          // A configuration problem at our end, not the customer's. Never show
          // them the raw wording — "not allowed for this instance" reads as if
          // they have been refused.
          setError("register-error",
            "New accounts aren't switched on yet. Please try again shortly, or call the masjid office on 01204 535 997.");
          if (window.console) console.error(
            "Sign-ups are disabled for this Supabase project. Turn on " +
            "'Allow new users to sign up' under Authentication -> Providers -> Email.");
        } else if (m.indexOf("password") !== -1 && m.indexOf("weak") !== -1) {
          setError("register-error", "Please choose a stronger password.");
        } else if (m.indexOf("rate limit") !== -1 || m.indexOf("too many") !== -1) {
          setError("register-error",
            "Too many attempts just now. Please wait a few minutes and try again.");
        } else {
          setError("register-error",
            "We couldn't create the account just now. Please try again, or call the masjid office on 01204 535 997.");
          if (window.console) console.warn("sign-up failed:", res.error.message);
        }
        return;
      }

      // Supabase returns a user with an empty identities array when the address
      // is already taken and confirmations are on — it will not say so outright,
      // to avoid revealing who has an account. We have chosen to say so.
      var u = res.data && res.data.user;
      if (u && u.identities && u.identities.length === 0) {
        setError("register-error",
          "An account already exists with this email address. Sign in instead, or use the forgotten-password link.");
        return;
      }

      // A session here means email confirmation is switched OFF in Supabase.
      if (res.data && res.data.session) { renderDone(res.data.session.user); return; }

      el("check-email").textContent = email;
      show("view-check");
    }).catch(function (err) {
      busy(btn, false, "Create account");
      setError("register-error", (err && err.message) || "Something went wrong. Please try again.");
    });
  });

  // --- sign in --------------------------------------------------------------
  el("signin-form").addEventListener("submit", function (e) {
    e.preventDefault();
    setError("signin-error", "");

    var email    = el("signin-email").value.trim();
    var password = el("signin-password").value;
    var btn      = el("signin-submit");
    busy(btn, true);

    sb.auth.signInWithPassword({ email: email, password: password })
      .then(function (res) {
        busy(btn, false, "Sign in");
        if (res.error) {
          var m = (res.error.message || "").toLowerCase();
          if (m.indexOf("email not confirmed") !== -1) {
            setError("signin-error",
              "This email address hasn't been confirmed yet. Open the link we sent you, then try again.");
          } else if (m.indexOf("invalid login") !== -1) {
            // Deliberately vague about WHICH half was wrong.
            setError("signin-error", "That email address and password don't match. Please try again.");
          } else {
            setError("signin-error", res.error.message || "Sign in failed. Please try again.");
          }
          return;
        }
        renderDone(res.data.user);
      }).catch(function (err) {
        busy(btn, false, "Sign in");
        setError("signin-error", (err && err.message) || "Sign in failed. Please try again.");
      });
  });

  // --- moving between the screens -------------------------------------------
  el("to-signin").addEventListener("click", function () {
    setError("register-error", ""); setError("signin-error", "");
    el("signin-email").value = el("reg-email").value.trim();
    show("view-signin");
    el("signin-password").focus();
  });
  el("check-to-signin").addEventListener("click", function () {
    setError("signin-error", "");
    el("signin-email").value = el("check-email").textContent;
    show("view-signin");
    el("signin-password").focus();
  });
  el("to-register").addEventListener("click", function () {
    setError("register-error", ""); setError("signin-error", "");
    show("view-register");
    el("reg-name").focus();
  });

  // --- sign out -------------------------------------------------------------
  el("done-signout").addEventListener("click", function () {
    sb.auth.signOut().then(function () {
      el("signin-email").value = "";
      el("signin-password").value = "";
      el("reg-name").value = "";
      el("reg-email").value = "";
      el("reg-password").value = "";
      setError("signin-error", "");
      show("view-signin");
    });
  });

  // --- what to show on arrival ----------------------------------------------
  // detectSessionInUrl handles somebody arriving from the confirmation email.
  // An expired or already-used confirmation link comes back as an error in the
  // URL fragment. Say so plainly instead of showing a blank register form.
  function linkError() {
    var frag = (window.location.hash || "").replace(/^#/, "");
    if (!frag) return null;
    var params = new URLSearchParams(frag);
    var code = params.get("error_code") || params.get("error");
    if (!code) return null;
    var desc = (params.get("error_description") || "").replace(/\+/g, " ");
    if (/expired/i.test(code) || /expired/i.test(desc)) {
      return "That confirmation link has expired. Create your account again and we will send a fresh one.";
    }
    return "That confirmation link didn't work. Create your account again and we will send a fresh one.";
  }

  sb.auth.getSession().then(function (res) {
    var session = res.data && res.data.session;
    if (session && session.user) { renderDone(session.user); return; }
    show("view-register");
    var problem = linkError();
    if (problem) setError("register-error", problem);
  }).catch(function () { show("view-register"); });

})();
