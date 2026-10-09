/* ===========================================================================
   Taiyabah Masjid — system health, read by a person on demand
   Bolton Central Islamic Society · Registered charity 1041569
   9 October 2026

   WHY THIS EXISTS
   ---------------
   health_check() (db/122, db/140) already runs fourteen checks — the
   scheduler itself, whether every masjid's forms can still reach somebody,
   a handful of data-integrity rules specific to the madrasah — and
   health_watch() (db/130, db/149) already runs it every fifteen minutes and
   emails the office the moment the result CHANGES. Until today there was no
   screen anywhere that showed the result at all: the only way to see it was
   to wait for an email, which only ever arrives on a change, or to read
   admin_audit directly. This is that screen.

   THIS PAGE DOES NOT WRITE ANYTHING. health_check() is a plain read — no
   row is inserted, no email is sent, nothing is marked alerted. Pressing
   "Check now" costs nothing and can be pressed as often as somebody likes;
   it is health_watch(), the cron job, that owns the email, and this page
   never calls it.

   THE SHAPE OF THIS SCREEN IS COPIED FROM rates/, giftaid/ and the others —
   the sign-in, the two-step verification, the rail — because that is this
   portal's own shell and a screen that reimplements it is a second place
   for the same bug to live. Everything from the "signed in" card down is
   new; everything above it is deliberately identical to every other screen
   here.
   =========================================================================== */
(function () {
  "use strict";

  var cfg = window.TAIYABAH_CONFIG || {};
  var el  = function (id) { return document.getElementById(id); };

  // --- view switching -------------------------------------------------------
  var VIEWS = ["view-loading", "view-signin", "view-mfa", "view-enrol", "view-app"];
  function show(view) {
    VIEWS.forEach(function (v) {
      var node = el(v);
      if (node) node.hidden = v !== view;
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
    show("view-signin");
    setError("signin-error",
      "This area isn't connected yet — config.js still has placeholder values in it.");
    var f = el("signin-form");
    if (f) Array.prototype.forEach.call(f.elements, function (i) { i.disabled = true; });
    return;
  }

  // The Supabase dashboard shows the project URL with /rest/v1/ on the end.
  // Pasting it verbatim has broken this twice, so normalise to the bare origin.
  var apiUrl = String(cfg.SUPABASE_URL || "")
                 .trim().replace(/\/+$/, "").replace(/\/rest\/v1$/, "");

  var sb = window.supabase.createClient(apiUrl, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
  });

  function loadIdentity() {
    return sb.auth.getUser().then(function (res) {
      var user = res.data && res.data.user;
      if (!user) throw new Error("No active session.");
      return Promise.all([
        sb.from("profiles").select("full_name, email").eq("id", user.id).maybeSingle(),
        sb.from("user_roles").select("role").eq("user_id", user.id)
      ]).then(function (out) {
        var errs = [];
        if (out[0].error) errs.push("profiles — " + out[0].error.message);
        if (out[1].error) errs.push("user_roles — " + out[1].error.message);
        return {
          user: user,
          profile: out[0].data || {},
          roles: (out[1].data || []).map(function (r) { return r.role; }),
          errors: errs
        };
      });
    });
  }

  /* ------------------------------------------------------------------ the
     HEALTH MODULE. Everything on this screen, kept in one place so that if
     it throws, the sign-in shell around it survives — see renderApp. */
  var health = (function () {
    "use strict";

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    /*  WORDING FOR A CHECK'S NAME. health_check() names each one after the
        thing it guards, in the plpgsql function's own words — readable
        already, this just turns the underscore_case into a sentence rather
        than inventing a second set of labels that could drift from the
        database's. */
    function label(key) {
      return String(key || "").replace(/_/g, " ").replace(/^./, function (c) {
        return c.toUpperCase();
      });
    }

    function formatWhen(iso) {
      if (!iso) return "";
      var d = new Date(iso);
      if (isNaN(d.getTime())) return "";
      return d.toLocaleString("en-GB", {
        day: "numeric", month: "short", hour: "2-digit", minute: "2-digit"
      });
    }

    function renderResult(result) {
      var status  = result && result.status;
      var checks  = (result && result.checks) || [];
      var failing = (result && result.failing) || [];

      var banner = el("hh-status");
      var h      = el("hh-status-h");
      var p      = el("hh-status-p");
      banner.hidden = false;
      banner.className = "hh-status " + (status === "fail" ? "is-fail" : "is-ok");
      if (status === "fail") {
        h.textContent = failing.length + " check" + (failing.length === 1 ? "" : "s") + " failing";
        p.textContent = "Needs a developer, not the office.";
      } else {
        h.textContent = "Everything is passing";
        p.textContent = "All fourteen checks are clean.";
      }

      var list = el("hh-list");
      list.innerHTML = "";
      if (!checks.length) {
        var empty = document.createElement("div");
        empty.className = "hh-empty";
        empty.textContent = "health_check() returned no checks at all. That is itself worth telling a developer about.";
        list.appendChild(empty);
      }
      checks.forEach(function (c) {
        var row = document.createElement("div");
        row.className = "hh-row" + (c.ok ? "" : " is-fail");
        row.innerHTML =
          '<span class="hh-mk" aria-hidden="true">' + (c.ok ? "✓" : "!") + '</span>' +
          '<span class="hh-body">' +
            '<span class="hh-name">' + esc(label(c.check)) + '</span>' +
            '<span class="hh-detail">' + esc(c.detail || "") + '</span>' +
          '</span>';
        list.appendChild(row);
      });

      el("hh-checked").textContent = result && result.checked_at
        ? "Checked " + formatWhen(result.checked_at)
        : "";
    }

    function run() {
      var btn = el("hh-recheck");
      setError("hh-error", "");
      busy(btn, true, "Check now");

      return sb.rpc("health_check").then(function (res) {
        if (res.error) throw res.error;
        renderResult(res.data);
      }).catch(function (err) {
        // health_check() itself raises 42501 for a signed-in non-admin —
        // see db/122. Everybody who reaches this screen at all holds
        // "admin" (see shell.js's GROUPS entry for "health"), so seeing
        // this message at all means the two have drifted apart.
        setError("hh-error", err && err.message ||
          "Couldn't run the health check. Try again, or ring a developer if it keeps failing.");
      }).finally(function () {
        busy(btn, false, "Check now");
      });
    }

    var wired = false;
    function mount() {
      if (!wired) {
        el("hh-recheck").addEventListener("click", run);
        wired = true;
      }
      return run();
    }

    return { mount: mount };
  })();

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'health',
        title:   'System health',
        roles:   identity.roles || [],
        name:    (identity.profile && identity.profile.full_name) || "",
        email:   (identity.user && identity.user.email) || ""
      });
    }

    el("app-name").textContent  = identity.profile.full_name || identity.user.email;
    el("app-email").textContent = identity.user.email;

    var roles = identity.roles.length ? identity.roles : ["no role assigned"];
    var wrap = el("app-roles");
    wrap.innerHTML = "";
    roles.forEach(function (r) {
      var chip = document.createElement("span");
      chip.className = "role-chip role-" + r;
      chip.textContent = r.replace(/_/g, " ");
      wrap.appendChild(chip);
    });

    if (identity.errors && identity.errors.length) {
      var box = el("app-error");
      box.textContent = "Couldn't read your account details. " + identity.errors.join(" · ");
      box.hidden = false;
    } else {
      el("app-error").hidden = true;
    }

    show("view-app");

    // A panel that fails to load must never take the sign-in shell with it.
    try { health.mount(); } catch (e) {
      if (window.console) console.warn("system health panel unavailable:", e);
    }
  }

  // Decides where to send someone once their password has been accepted.
  function routeAfterPassword() {
    return sb.auth.mfa.getAuthenticatorAssuranceLevel().then(function (res) {
      if (res.error) throw new Error("Couldn't check two-step status: " + res.error.message);
      var data = res.data || {};
      if (data.nextLevel === "aal2" && data.nextLevel !== data.currentLevel) {
        return startChallenge();
      }
      return sb.auth.mfa.listFactors().then(function (list) {
        if (list.error) throw new Error("Couldn't list authenticators: " + list.error.message);
        var verified = ((list.data || {}).totp) || [];
        if (verified.length === 0) return startEnrolment();
        return loadIdentity().then(renderApp);
      });
    });
  }

  var pending = { factorId: null, challengeId: null };

  function startChallenge() {
    return sb.auth.mfa.listFactors().then(function (res) {
      var totp = ((res.data || {}).totp) || [];
      if (!totp.length) return startEnrolment();
      pending.factorId = totp[0].id;
      return sb.auth.mfa.challenge({ factorId: pending.factorId }).then(function (c) {
        if (c.error) throw c.error;
        pending.challengeId = c.data.id;
        setError("mfa-error", "");
        el("mfa-code").value = "";
        show("view-mfa");
        el("mfa-code").focus();
      });
    });
  }

  function startEnrolment() {
    return sb.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: "Authenticator " + new Date().toISOString().slice(0, 10)
    }).then(function (res) {
      if (res.error) throw res.error;
      pending.factorId = res.data.id;
      el("enrol-qr").src = res.data.totp.qr_code;
      el("enrol-secret").textContent = res.data.totp.secret;
      setError("enrol-error", "");
      el("enrol-code").value = "";
      show("view-enrol");
      el("enrol-code").focus();
    });
  }

  // --- sign in --------------------------------------------------------------
  el("signin-form").addEventListener("submit", function (e) {
    e.preventDefault();
    var btn = el("signin-submit");
    setError("signin-error", "");
    busy(btn, true);

    sb.auth.signInWithPassword({
      email: el("signin-email").value.trim(),
      password: el("signin-password").value
    }).then(function (res) {
      if (res.error) throw res.error;
      return routeAfterPassword();
    }).catch(function (err) {
      // Deliberately vague: confirming which half was wrong helps an attacker
      // enumerate valid masjid email addresses.
      var msg = /invalid login/i.test(err.message || "")
        ? "That email address and password don't match. Please try again."
        : (err.message || "Sign in failed. Please try again.");
      setError("signin-error", msg);
    }).finally(function () {
      busy(btn, false, "Sign in");
      el("signin-password").value = "";
    });
  });

  el("mfa-form").addEventListener("submit", function (e) {
    e.preventDefault();
    var btn = el("mfa-submit");
    setError("mfa-error", "");
    busy(btn, true);

    sb.auth.mfa.verify({
      factorId: pending.factorId,
      challengeId: pending.challengeId,
      code: el("mfa-code").value.trim()
    }).then(function (res) {
      if (res.error) throw res.error;
      return loadIdentity().then(renderApp);
    }).catch(function (err) {
      setError("mfa-error", err.message || "That code wasn't accepted. Codes expire after 30 seconds.");
      sb.auth.mfa.challenge({ factorId: pending.factorId }).then(function (c) {
        if (c.data) pending.challengeId = c.data.id;
      });
    }).finally(function () {
      busy(btn, false, "Verify");
      el("mfa-code").value = "";
    });
  });

  el("enrol-form").addEventListener("submit", function (e) {
    e.preventDefault();
    var btn = el("enrol-submit");
    setError("enrol-error", "");
    busy(btn, true);

    sb.auth.mfa.challenge({ factorId: pending.factorId }).then(function (c) {
      if (c.error) throw c.error;
      return sb.auth.mfa.verify({
        factorId: pending.factorId,
        challengeId: c.data.id,
        code: el("enrol-code").value.trim()
      });
    }).then(function (res) {
      if (res.error) throw res.error;
      return loadIdentity().then(renderApp);
    }).catch(function (err) {
      setError("enrol-error", err.message || "That code wasn't accepted. Please try the next one.");
    }).finally(function () {
      busy(btn, false, "Confirm and finish setup");
      el("enrol-code").value = "";
    });
  });

  el("app-signout").addEventListener("click", function () {
    sb.auth.signOut().then(function () {
      el("signin-email").value = "";
      el("signin-password").value = "";
      setError("signin-error", "");
      show("view-signin");
    });
  });

  // --- restore an existing session on load ----------------------------------
  sb.auth.getSession().then(function (res) {
    if (res.data && res.data.session) {
      return routeAfterPassword().catch(function () { show("view-signin"); });
    }
    show("view-signin");
  }).catch(function () { show("view-signin"); });

  ["mfa-code", "enrol-code"].forEach(function (id) {
    el(id).addEventListener("input", function (e) {
      e.target.value = e.target.value.replace(/\D/g, "").slice(0, 6);
    });
  });
})();
