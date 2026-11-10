/* ===========================================================================
   Taiyabah Masjid — Take a payment
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   The masjid's card reader was running MasjidBox's software, on MasjidBox's
   own Stripe setup — not this masjid's own account, and not branded as
   Taiyabah Masjid to the donor standing at the till. This page, and the
   Worker behind it (terminal-worker/), replace that: the masjid's own
   account, the masjid's own branding, and a tap that lands in the Donations
   dashboard (/giftaid/) like every other gift.

   WHAT THIS PAGE DOES NOT DO
   ---------------------------
   It never sees the Stripe secret key — terminal-worker holds that, and
   this page only ever gets back a connection token or a PaymentIntent's
   client_secret, each good for exactly one thing. It does not record the
   donation into `donations` either: Stripe confirming the charge is what
   triggers that, via stripe-webhook's payment_intent.succeeded handler (see
   db/153) — the same "the webhook is the one who recorded it, not the
   browser's say-so" rule every other payment on this site already follows.
   A receipt shown here is Stripe confirming the charge, not this page
   confirming the bookkeeping.

   NOBODY HAS TESTED THIS AGAINST THE REAL READER YET. Read
   terminal-worker/README.md before relying on it for an actual donation.
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
      "This page isn't connected yet — config.js still has placeholder values in it.");
    var f = el("signin-form");
    if (f) Array.prototype.forEach.call(f.elements, function (i) { i.disabled = true; });
    return;
  }

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

  /* =========================================================================
     TAKE A PAYMENT
     ======================================================================= */
  var takePayment = (function () {
    var mounted = false;
    var terminal = null;
    var connectedReader = null;

    function canSee(identity) {
      return identity.roles.indexOf("admin") !== -1;
    }

    function money(p) {
      return (Number(p || 0) / 100).toFixed(2);
    }

    function setStatus(text, state) {
      el("tp-status").className = "tp-status" + (state ? " " + state : "");
      el("tp-status-text").textContent = text;
    }

    function say(msg) {
      var box = el("tp-error");
      if (!msg) { box.hidden = true; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    // The caller's own Supabase access token — terminal-worker checks it
    // against verified_admin() itself; this page does not decide who may
    // charge a card, it only carries the proof of who is asking.
    function workerToken() {
      return sb.auth.getSession().then(function (res) {
        var session = res.data && res.data.session;
        if (!session) throw new Error("Not signed in.");
        return session.access_token;
      });
    }

    function workerFetch(path, body) {
      return workerToken().then(function (token) {
        return fetch(cfg.TERMINAL_WORKER_URL + path, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Authorization": "Bearer " + token },
          body: JSON.stringify(body || {})
        }).then(function (res) {
          return res.json().then(function (data) {
            if (!res.ok) throw new Error((data && data.error) || "The terminal service refused that.");
            return data;
          });
        });
      });
    }

    function fetchConnectionToken() {
      return workerFetch("/connection_token").then(function (data) { return data.secret; });
    }

    function connectReader() {
      if (!window.StripeTerminal) {
        setStatus("The Stripe Terminal library did not load. Check the connection and reload.", "bad");
        return;
      }
      if (!terminal) {
        terminal = window.StripeTerminal.create({
          onFetchConnectionToken: fetchConnectionToken,
          onUnexpectedReaderDisconnect: function () {
            connectedReader = null;
            setStatus("The reader disconnected. Reload this page to reconnect.", "bad");
            el("tp-form").hidden = true;
            el("tp-connect").hidden = false;
          }
        });
      }

      el("tp-connect").disabled = true;
      setStatus("Looking for the card reader…");

      var method = cfg.READER_DISCOVERY_METHOD || "internet";
      var discoverOpts = { discoveryMethod: method };
      if (method === "internet") {
        // An internet-connected reader (the masjid's S700) is found by the
        // Location it is registered to, not by scanning nearby — there is
        // no "nearby" for a Wi‑Fi reader the way there is for Bluetooth.
        if (!cfg.TERMINAL_LOCATION_ID || cfg.TERMINAL_LOCATION_ID.indexOf("PASTE_") === 0) {
          setStatus("config.js has no TERMINAL_LOCATION_ID yet — see docs/DO-THIS-card-machine.md.", "bad");
          el("tp-connect").disabled = false;
          return;
        }
        discoverOpts.location = cfg.TERMINAL_LOCATION_ID;
      }

      terminal.discoverReaders(discoverOpts)
        .then(function (result) {
          if (result.error) throw new Error(result.error.message);
          if (!result.discoveredReaders.length) {
            throw new Error(method === "internet"
              ? "No reader found at that Location. Check it is registered and switched on."
              : "No reader found. Make sure it is switched on and nearby.");
          }
          return terminal.connectReader(result.discoveredReaders[0]);
        })
        .then(function (connectResult) {
          if (connectResult.error) throw new Error(connectResult.error.message);
          connectedReader = connectResult.reader;
          setStatus("Reader connected: " + (connectedReader.label || connectedReader.id), "ok");
          el("tp-connect").hidden = true;
          el("tp-form").hidden = false;
        })
        .catch(function (e) {
          setStatus("Couldn't connect — " + e.message, "bad");
          el("tp-connect").disabled = false;
        });
    }

    function showReceipt(amountP, paymentIntentId) {
      el("tp-receipt-amount").textContent = "£" + money(amountP);
      el("tp-receipt-ref").textContent = paymentIntentId;
      el("tp-receipt").hidden = false;
      el("tp-form").hidden = true;
    }

    function charge(amountP, purpose) {
      say("");
      var btn = el("tp-charge");
      busy(btn, true, "Charge the card");

      return workerFetch("/create_payment_intent", { amount_p: amountP, purpose: purpose })
        .then(function (data) {
          btn.textContent = "Tap, insert or swipe the card…";
          return terminal.collectPaymentMethod(data.client_secret);
        })
        .then(function (result) {
          if (result.error) throw new Error(result.error.message);
          btn.textContent = "Processing…";
          return terminal.processPayment(result.paymentIntent);
        })
        .then(function (result) {
          if (result.error) throw new Error(result.error.message);
          showReceipt(amountP, result.paymentIntent.id);
        })
        .catch(function (e) {
          say("That didn't go through — " + e.message + ". Nothing has been taken; try again.");
        })
        .finally(function () {
          busy(btn, false, "Charge the card");
        });
    }

    function mount(identity) {
      if (mounted) return;
      mounted = true;

      if (!canSee(identity)) {
        el("app-noaccess").hidden = false;
        return;
      }
      el("tp-panel").hidden = false;

      if (!cfg.TERMINAL_WORKER_URL || cfg.TERMINAL_WORKER_URL.indexOf("PASTE_") === 0) {
        setStatus("This page isn't connected to the terminal service yet — config.js still has a placeholder URL in it.", "bad");
        el("tp-connect").disabled = true;
        return;
      }

      el("tp-connect").addEventListener("click", connectReader);

      el("tp-form").addEventListener("submit", function (e) {
        e.preventDefault();
        if (!connectedReader) { say("Connect the reader before charging a card."); return; }
        var pounds = parseFloat(el("tp-amount").value);
        if (!(pounds > 0)) { say("Enter an amount greater than zero."); return; }
        charge(Math.round(pounds * 100), el("tp-purpose").value);
      });

      el("tp-again").addEventListener("click", function () {
        el("tp-receipt").hidden = true;
        el("tp-form").hidden = false;
        el("tp-form").reset();
        say("");
      });
    }

    return { mount: mount };
  })();

  function renderApp(identity) {
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'takepayment',
        title:   'Take a payment',
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

    try { takePayment.mount(identity); } catch (e) {
      if (window.console) console.warn("take-payment panel unavailable:", e);
    }
  }

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
