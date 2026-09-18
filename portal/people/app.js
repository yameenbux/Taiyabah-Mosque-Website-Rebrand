/* ===========================================================================
   WHO CAN OPEN THE MADRASAH PORTAL.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   18 September 2026

   THIS SCREEN SHOWS AND DOES NOT GRANT.

   Asked for as "Admin staff", and to include the masjid's own administrators
   as well as the madrasah's. It does. What it deliberately does NOT do is let
   anybody be invited or removed from here. Access is granted on one screen —
   the Admin Centre's — because two screens that both grant it is how somebody
   is taken off one and quietly left on the other, and the one that gets
   forgotten is always the one nobody opens daily.

   So this answers a question instead of offering a control: who can get in,
   what does that reach, is their two-step on, and when were they last here.
   Changing any of it is one link away, and that link is at the bottom.

   THE TWO-STEP FIGURE IS WHY THIS IS WORTH A SCREEN. This portal will hold
   children's records. An account with no authenticator is one leaked password
   away from all of it, and nobody thinks to ask how many of those there are
   unless something asks it for them.

   madrasah_people() is READ ONLY and there is deliberately no matching writer
   anywhere in db/057 — see its header.
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

  /* =========================================================================
     WHO CAN OPEN THE MADRASAH
     ======================================================================= */
  var people = (function () {

    var ROWS = [];

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function note(id, msg) {
      var box = el(id);
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    /*  "Never" is a real answer and it is the interesting one.

        An account that has been granted access and never used it is either
        somebody who does not know they have it, or somebody who has left. Both
        are worth seeing, and both disappear if this column quietly renders an
        empty string. */
    function lastIn(iso) {
      if (!iso) return { text: "Never signed in", cls: "bad" };
      var then = new Date(iso), now = new Date();
      var days = Math.floor((now - then) / 86400000);
      var when = then.toLocaleDateString("en-GB",
        { day: "numeric", month: "short", year: "numeric" });
      if (days <= 0) return { text: "Today", cls: "" };
      if (days === 1) return { text: "Yesterday", cls: "" };
      if (days < 60) return { text: days + " days ago", cls: "" };
      return { text: when, cls: "" };
    }

    function oneHtml(p) {
      var all = p.reach === "everything";
      var seen = lastIn(p.last_in);
      return '<div class="pp-one ' + (all ? "all" : "md") + '">' +
        "<span>" +
          '<span class="pp-nm">' + esc(p.name || p.email || "Somebody") +
            (p.is_me ? '<span class="pp-me">you</span>' : "") + "</span>" +
          '<span class="pp-em">' + esc(p.email || "") + "</span>" +
          (p.active === false
            ? '<span class="pp-w">This account has been switched off.</span>' : "") +
        "</span>" +

        "<span>" +
          '<span class="pp-h">What they reach</span>' +
          '<span class="pp-v">' +
            (all ? "Everything the masjid does" : "The teaching side only") + "</span>" +
          '<span class="pp-w">' +
            (all
              ? "Including staff records, DBS, fees and admissions."
              : "Classes, the register, homework and pupils. Not staff records, " +
                "DBS, fees or admissions.") +
          "</span>" +
        "</span>" +

        "<span>" +
          '<span class="pp-h">Two-step</span>' +
          '<span class="pp-v ' + (p.two_step ? "good" : "bad") + '">' +
            (p.two_step ? "On" : "Not set up") + "</span>" +
          '<span class="pp-w">Last signed in: ' + esc(seen.text) + "</span>" +
        "</span>" +
      "</div>";
    }

    function draw() {
      var list = el("pp-list");
      if (!list) return;

      if (!ROWS.length) {
        list.innerHTML = '<div class="pp-empty">Nobody can open the madrasah portal ' +
          'yet, which cannot be right if you are reading this. Reload the page.</div>';
        return;
      }
      list.innerHTML = ROWS.map(oneHtml).join("");

      var all = ROWS.filter(function (p) { return p.reach === "everything"; }).length;
      var md  = ROWS.length - all;
      var no2 = ROWS.filter(function (p) { return !p.two_step; }).length;

      /*  THE TWO-STEP FIGURE IS THE ONE WORTH SHOWING.

          The madrasah portal will hold children's records. An account without
          an authenticator is one leaked password away from all of it, and
          "how many of us have not turned it on" is a question nobody thinks
          to ask unless a screen asks it for them. It is red when it is not
          nought and quiet when it is. */
      el("pp-sum").innerHTML =
        '<div class="pp-fig"><span class="n">' + ROWS.length + "</span>" +
          '<span class="k">Can get in</span>' +
          '<span class="w">People who can open the madrasah portal.</span></div>' +
        '<div class="pp-fig"><span class="n">' + all + "</span>" +
          '<span class="k">Reach everything</span>' +
          '<span class="w">Masjid administrators. The madrasah comes with the rest.</span></div>' +
        '<div class="pp-fig"><span class="n">' + md + "</span>" +
          '<span class="k">Teaching side only</span>' +
          '<span class="w">The madrasah role. No staff records, DBS, fees or admissions.</span></div>' +
        '<div class="pp-fig' + (no2 ? " warn" : "") + '"><span class="n">' + no2 + "</span>" +
          '<span class="k">No two-step</span>' +
          '<span class="w">' + (no2
            ? "An account without an authenticator is one leaked password away " +
              "from everything behind it."
            : "Everybody who can get in has an authenticator.") + "</span></div>";
    }

    function mount(identity) {
      var panel = el("pp-panel");
      var noaccess = el("app-noaccess");
      if (!panel) return;
      if ((identity.roles || []).indexOf("admin") === -1) {
        panel.hidden = true;
        if (noaccess) noaccess.hidden = false;
        return;
      }
      if (noaccess) noaccess.hidden = true;
      panel.hidden = false;

      sb.rpc("madrasah_people").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        ROWS = (res.data && res.data.people) || [];
        draw();
      }).catch(function (e) {
        note("pp-error", "The list could not be read — " + ((e && e.message) || String(e)));
        var list = el("pp-list");
        if (list) list.textContent = "";
      });
    }

    return { mount: mount };
  })();

  function renderApp(identity) {
    //  Wait for the two deferred scripts, but only while the page is still
    //  being read. See the long note below the mount.
    if (document.readyState === "loading" &&
        !(window.AdminShell && window.MadrasahNav)) {
      document.addEventListener("DOMContentLoaded", function () {
        renderApp(identity);
      }, { once: true });
      return;
    }

    //  THE RAIL. Mounted here and nowhere else: this function runs only once
    //  the page knows who is signed in, so the list of areas can never be
    //  drawn for somebody who is not. It is a convenience, not a permission —
    //  see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        //  Two folders below the web root, so the rail's links and the logo
        //  need '../../'. shell.js does the arithmetic; this is the only
        //  thing the page has to say about it.
        depth:    2,
        current:  'md-people',
        title:    'Admin staff',
        area:     'Madrasah',
        sections: (window.MadrasahNav || {}).SECTIONS,
        roles:    identity.roles || [],
        name:     (identity.profile && identity.profile.full_name) || "",
        email:    (identity.user && identity.user.email) || ""
      });
    }

    /*  WHY THE WAIT AT THE TOP OF THIS FUNCTION.

        `sections` is what swaps the site-wide rail for the madrasah's own list
        with a way back out at the top. It is the SAME rail, not a second one:
        two left-hand columns is unusable, and a second implementation is a
        second place for the drawer, the escape key and the focus handling to
        be wrong.

        Both shell.js and nav.js are deferred, so they run after the page has
        been read — which is normally long before this function, because this
        function waits on a round trip to Supabase first. Normally. If the
        answer ever came back faster than the two files (a warm cache, a local
        run, a test with the network stubbed out), MadrasahNav would not exist
        yet and shell.js would quietly fall back to the SITE list — putting
        Gift Aid and Hall Hire in the rail of a madrasah screen, with no error
        anywhere. A missing rail is obvious; the wrong rail is not, so this
        waits for both files rather than risking it.

        Only while the document is still loading, though. If either file is
        genuinely missing, DOMContentLoaded has already gone and waiting for it
        again would hang the whole screen on a navigation problem. */

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
    try { people.mount(identity); } catch (e) {
      if (window.console) console.warn("people panel unavailable:", e);
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
