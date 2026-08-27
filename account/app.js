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

    sb.auth.signUp({
      email: email,
      password: password,
      options: { data: { full_name: name } }
    }).then(function (res) {
      busy(btn, false, "Create account");

      if (res.error) {
        var m = (res.error.message || "").toLowerCase();
        if (m.indexOf("already registered") !== -1 || m.indexOf("already been registered") !== -1) {
          setError("register-error",
            "An account already exists with this email address. Sign in instead, or use the forgotten-password link.");
        } else {
          setError("register-error", res.error.message || "We couldn't create the account. Please try again.");
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
  sb.auth.getSession().then(function (res) {
    var session = res.data && res.data.session;
    if (session && session.user) { renderDone(session.user); return; }
    show("view-register");
  }).catch(function () { show("view-register"); });

})();
