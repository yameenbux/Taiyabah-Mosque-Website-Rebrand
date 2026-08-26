/* ===========================================================================
   Taiyabah Madrasah Portal — authentication
   Bolton Central Islamic Society · Registered charity 1041569

   Handles: sign in -> MFA (enrol or verify) -> signed-in shell -> sign out.

   Security notes for anyone maintaining this:
     - Only the anon key is used. RLS in Postgres is the real access control;
       nothing here is trusted to protect data.
     - The role is read from user_roles via RLS, never from anything the
       browser could tamper with.
     - MFA is enforced client-side for UX, but the database is what must
       ultimately gate sensitive tables (see aal2 note in the roadmap).
   =========================================================================== */
(function () {
  "use strict";

  var cfg = window.TAIYABAH_CONFIG || {};
  var el = function (id) { return document.getElementById(id); };

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
      "This portal isn't connected yet — config.js still has placeholder values in it.");
    var f = el("signin-form");
    if (f) Array.prototype.forEach.call(f.elements, function (i) { i.disabled = true; });
    return;
  }

  var sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
  });

  // --- helpers --------------------------------------------------------------

  // Reads the signed-in person's profile and role. Both queries are governed
  // by RLS, so a parent asking for someone else's row simply gets nothing.
  function loadIdentity() {
    return sb.auth.getUser().then(function (res) {
      var user = res.data && res.data.user;
      if (!user) throw new Error("No active session.");
      return Promise.all([
        sb.from("profiles").select("full_name, email").eq("id", user.id).maybeSingle(),
        sb.from("user_roles").select("role").eq("user_id", user.id)
      ]).then(function (out) {
        // Surface failures. Previously a blocked or errored query looked
        // identical to an empty result, which reported "no role assigned"
        // when the real problem was something else entirely.
        var errs = [];
        if (out[0].error) errs.push("profiles — " + out[0].error.message);
        if (out[1].error) errs.push("user_roles — " + out[1].error.message);
        var profile = out[0].data || {};
        var roles = (out[1].data || []).map(function (r) { return r.role; });
        return { user: user, profile: profile, roles: roles, errors: errs };
      });
    });
  }

  /* =========================================================================
     HALL BOOKINGS

     Requests submitted through the public website land in `hall_bookings`.
     This panel is where the office works through them: ring the enquirer,
     agree the date and the fee, then record the outcome.

     What the database will and will not allow (migration 004):
       - only `hall_office` and `admin` can read a booking at all
       - the office may change status, notes and handled_at, and NOTHING else.
         It cannot quietly edit somebody's name, address or requested date. If
         those are wrong the booking is declined and re-entered, so the record
         always shows what the person actually asked for.
       - nobody can delete. A request is closed by moving its status, which
         leaves a trail.

     The panel is hidden from people without the role, but that is a courtesy,
     not a control — RLS is what actually stops a parent reading these.
     ======================================================================= */
  var bookings = (function () {
    var SLOTS = { morning: "Morning · 9:00am – 4:00pm", evening: "Evening · 5:00pm – 11:00pm" };
    var rows = [];
    var filter = "new";
    var query = "";
    var mounted = false;

    function canSee(identity) {
      return identity.roles.indexOf("hall_office") !== -1 ||
             identity.roles.indexOf("admin") !== -1;
    }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function todayISO() {
      var d = new Date();
      return d.getFullYear() + "-" +
             String(d.getMonth() + 1).padStart(2, "0") + "-" +
             String(d.getDate()).padStart(2, "0");
    }

    function longDate(iso) {
      // Parse as parts, not Date(string) — that treats a bare date as UTC and
      // can show the wrong day to anyone west of Greenwich.
      var p = String(iso).split("-");
      var d = new Date(+p[0], +p[1] - 1, +p[2]);
      return d.toLocaleDateString("en-GB",
        { weekday: "long", day: "numeric", month: "long", year: "numeric" });
    }

    function ago(ts) {
      var mins = Math.floor((Date.now() - new Date(ts).getTime()) / 60000);
      if (mins < 2) return "just now";
      if (mins < 60) return mins + " minutes ago";
      var hrs = Math.floor(mins / 60);
      if (hrs < 24) return hrs === 1 ? "an hour ago" : hrs + " hours ago";
      var days = Math.floor(hrs / 24);
      return days === 1 ? "yesterday" : days + " days ago";
    }

    function setError(msg) {
      var box = el("bk-error");
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    function load() {
      return sb.from("hall_bookings")
        .select("id,created_at,booking_date,session_slot,hall,first_name,last_name,address,phone,status,office_notes,handled_at")
        .order("booking_date", { ascending: true })
        .then(function (res) {
          if (res.error) {
            // Say what actually went wrong. A silent empty list reads as
            // "no bookings" and the office stops checking.
            setError("Couldn't load bookings — " + res.error.message);
            rows = [];
            return;
          }
          setError(null);
          rows = res.data || [];
        });
    }

    function visible() {
      var today = todayISO();
      var out = rows.filter(function (r) {
        if (filter === "new")      return r.status === "new";
        if (filter === "upcoming") return r.status === "confirmed" && r.booking_date >= today;
        return true;
      });
      if (query) {
        var q = query.toLowerCase();
        var digits = q.replace(/\D/g, "");
        out = out.filter(function (r) {
          var name = (r.first_name + " " + r.last_name).toLowerCase();
          var phone = String(r.phone).replace(/\D/g, "");
          return name.indexOf(q) !== -1 || (digits.length >= 3 && phone.indexOf(digits) !== -1);
        });
      }
      // Newest requests first when triaging; soonest first when looking ahead.
      if (filter === "new") {
        out.sort(function (a, b) { return new Date(b.created_at) - new Date(a.created_at); });
      }
      return out;
    }

    function counts() {
      var today = todayISO();
      el("bk-n-new").textContent = rows.filter(function (r) { return r.status === "new"; }).length;
      el("bk-n-up").textContent  = rows.filter(function (r) {
        return r.status === "confirmed" && r.booking_date >= today;
      }).length;
    }

    function emptyLine() {
      if (query) return "Nothing matches “" + esc(query) + "”.";
      if (filter === "new")      return "No new requests. Anything that comes in from the website will appear here.";
      if (filter === "upcoming") return "No confirmed bookings coming up.";
      return "No bookings yet.";
    }

    function render() {
      counts();
      var list = el("bk-list");
      var items = visible();
      if (!items.length) {
        list.innerHTML = '<div class="bk-empty">' + emptyLine() + "</div>";
        return;
      }
      list.innerHTML = items.map(function (r) {
        var isOpen = r.status === "new";
        var hall = r.hall === "any" ? "Any available hall" : "Hall " + esc(r.hall);
        return '' +
          '<article class="bk-item s-' + esc(r.status) + '" data-id="' + esc(r.id) + '">' +
            '<div class="bk-when">' +
              '<span class="d">' + esc(longDate(r.booking_date)) + '</span>' +
              '<span class="s">' + esc(SLOTS[r.session_slot] || r.session_slot) + ' · ' + hall + '</span>' +
              '<span class="bk-pill p-' + esc(r.status) + '">' + esc(r.status) + '</span>' +
            '</div>' +
            '<div class="bk-who">' +
              '<span class="nm">' + esc(r.first_name) + " " + esc(r.last_name) + '</span>' +
              '<a href="tel:' + esc(String(r.phone).replace(/\s/g, "")) + '">' + esc(r.phone) + '</a>' +
            '</div>' +
            '<div class="bk-addr">' + esc(r.address) + '</div>' +
            '<div class="bk-meta">Requested ' + esc(ago(r.created_at)) +
              (r.handled_at ? ' · decided ' + esc(ago(r.handled_at)) : '') + '</div>' +
            '<textarea class="bk-notes" data-notes rows="1" placeholder="Notes — what was agreed, fee quoted, who called">' +
              esc(r.office_notes || "") + '</textarea>' +
            '<div class="bk-acts">' +
              (isOpen
                ? '<button type="button" class="bk-btn go" data-act="confirmed">Confirm</button>' +
                  '<button type="button" class="bk-btn no" data-act="declined">Decline</button>'
                : '<button type="button" class="bk-btn" data-act="save">Save notes</button>' +
                  (r.status === "confirmed"
                    ? '<button type="button" class="bk-btn no" data-act="cancelled">Cancel booking</button>'
                    : '<button type="button" class="bk-btn" data-act="new">Reopen</button>')) +
              '<span class="bk-said" data-said></span>' +
            '</div>' +
          '</article>';
      }).join("");
    }

    // Writes only the three columns the office is allowed to touch.
    function apply(id, item, act) {
      var notes = item.querySelector("[data-notes]").value.trim();
      var said  = item.querySelector("[data-said]");
      var btns  = item.querySelectorAll(".bk-btn");
      Array.prototype.forEach.call(btns, function (b) { b.disabled = true; });
      said.textContent = "Saving…";

      var patch = { office_notes: notes || null };
      if (act !== "save") {
        patch.status = act;
        patch.handled_at = act === "new" ? null : new Date().toISOString();
      }

      return sb.from("hall_bookings").update(patch).eq("id", id)
        .then(function (res) {
          if (res.error) {
            said.textContent = "";
            setError("Couldn't save that — " + res.error.message + ". Nothing was changed.");
            Array.prototype.forEach.call(btns, function (b) { b.disabled = false; });
            return;
          }
          setError(null);
          return load().then(render);
        })
        .catch(function (e) {
          said.textContent = "";
          setError("Couldn't reach the database — " + (e && e.message) + ". Nothing was changed.");
          Array.prototype.forEach.call(btns, function (b) { b.disabled = false; });
        });
    }

    function wire() {
      el("bk-tabs").addEventListener("click", function (e) {
        var tab = e.target.closest(".bk-tab");
        if (!tab) return;
        filter = tab.dataset.filter;
        Array.prototype.forEach.call(this.querySelectorAll(".bk-tab"), function (t) {
          t.classList.toggle("on", t === tab);
        });
        render();
      });

      var search = el("bk-search");
      var t;
      search.addEventListener("input", function () {
        clearTimeout(t);
        var v = this.value.trim();
        t = setTimeout(function () { query = v; render(); }, 150);
      });

      el("bk-list").addEventListener("click", function (e) {
        var btn = e.target.closest(".bk-btn");
        if (!btn) return;
        var item = btn.closest(".bk-item");
        apply(item.dataset.id, item, btn.dataset.act);
      });
    }

    function mount(identity) {
      if (!canSee(identity)) return;
      var panel = el("bk-panel");
      if (!panel) return;
      panel.hidden = false;
      var card = el("view-app");
      if (card) card.classList.add("is-wide");
      el("app-status").innerHTML =
        "<b>You're signed in.</b> Hall hire requests from the website are below. " +
        "The madrasah features — registers, pupil records and reports — are still " +
        "being built, and no pupil data is held in this system yet.";
      if (!mounted) { wire(); mounted = true; }
      load().then(render);
    }

    return { mount: mount };
  })();

  function renderApp(identity) {
    var name = identity.profile.full_name || identity.user.email;
    var roles = identity.roles.length ? identity.roles : ["no role assigned"];

    el("app-name").textContent = name;
    el("app-email").textContent = identity.user.email;

    var wrap = el("app-roles");
    wrap.innerHTML = "";
    roles.forEach(function (r) {
      var chip = document.createElement("span");
      chip.className = "role-chip role-" + r;
      chip.textContent = r;
      wrap.appendChild(chip);
    });

    var failed = identity.errors && identity.errors.length > 0;
    if (failed) {
      var box = el("app-error");
      box.textContent = "Couldn't read your account details. " + identity.errors.join(" · ");
      box.hidden = false;
    } else {
      el("app-error").hidden = true;
    }

    // Someone authenticated but with no role should be told plainly, not
    // shown an empty dashboard they'll assume is broken. Don't claim "no role"
    // when the truth is that the lookup failed.
    el("app-norole").hidden = identity.roles.length > 0 || failed;
    show("view-app");

    // A panel that fails to load must never take the sign-in shell with it.
    try { bookings.mount(identity); } catch (e) {
      if (window.console) console.warn("bookings panel unavailable:", e);
    }
  }

  // Decides where to send someone once their password has been accepted.
  function routeAfterPassword() {
    return sb.auth.mfa.getAuthenticatorAssuranceLevel().then(function (res) {
      if (res.error) throw new Error("Couldn't check two-step status: " + res.error.message);
      var data = res.data || {};
      if (data.nextLevel === "aal2" && data.nextLevel !== data.currentLevel) {
        return startChallenge();           // factor exists, needs verifying
      }
      return sb.auth.mfa.listFactors().then(function (list) {
        if (list.error) throw new Error("Couldn't list authenticators: " + list.error.message);
        var verified = ((list.data || {}).totp) || [];
        if (verified.length === 0) return startEnrolment();  // no factor yet
        return loadIdentity().then(renderApp);
      });
    });
  }

  // --- MFA: verifying an existing factor ------------------------------------
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

  // --- MFA: first-time enrolment --------------------------------------------
  function startEnrolment() {
    return sb.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: "Authenticator " + new Date().toISOString().slice(0, 10)
    }).then(function (res) {
      if (res.error) throw res.error;
      pending.factorId = res.data.id;
      // Supabase returns the QR as an SVG data URI — no QR library needed.
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
      // enumerate valid madrasah email addresses.
      var msg = /invalid login/i.test(err.message || "")
        ? "That email address and password don't match. Please try again."
        : (err.message || "Sign in failed. Please try again.");
      setError("signin-error", msg);
    }).finally(function () {
      busy(btn, false, "Sign in");
      el("signin-password").value = "";
    });
  });

  // --- verify existing factor -----------------------------------------------
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
      // A failed verify burns the challenge, so issue a fresh one.
      sb.auth.mfa.challenge({ factorId: pending.factorId }).then(function (c) {
        if (c.data) pending.challengeId = c.data.id;
      });
    }).finally(function () {
      busy(btn, false, "Verify");
      el("mfa-code").value = "";
    });
  });

  // --- confirm enrolment ----------------------------------------------------
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

  // --- sign out -------------------------------------------------------------
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

  // Numeric-only, 6-digit convenience on both code fields.
  ["mfa-code", "enrol-code"].forEach(function (id) {
    el(id).addEventListener("input", function (e) {
      e.target.value = e.target.value.replace(/\D/g, "").slice(0, 6);
    });
  });
})();
