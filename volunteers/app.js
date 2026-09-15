/* ===========================================================================
   Taiyabah Masjid — Food Bank volunteers
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   Migration 023 records who has offered to help at the food bank before it
   opens. Without this page the only way to read them back would be SQL in the
   Supabase editor — which nobody in the office is going to run, so the
   registrations would pile up unread and the form would be a way of
   collecting people's mobile numbers for nothing.

   That mistake has been made twice on this site already: the course sign-ups
   in September, and Gift Aid the same week. Turning a form on and giving a
   human a way to read it back are two separate jobs, and only the first one
   feels finished.

   WHAT THE COMMITTEE ACTUALLY ASKED
   ---------------------------------
   Not "who registered" but "have we got enough people to open?". So the
   counts are at the top and the list underneath, and the headline number
   excludes anybody who has since withdrawn — a count that quietly includes
   people who said no is the kind of number a committee decides on and then
   regrets.

   WHO CAN OPEN IT
   ---------------
   Administrators and hall office staff, both at aal2. The database says the
   same thing in the policies on foodbank_volunteers; this only decides what
   to draw. The list is people's names, ages and mobile numbers.
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
     THE CLAIM
     ======================================================================= */
  /* =========================================================================
     THE VOLUNTEER LIST

     WHAT THIS PAGE IS FOR. Migration 023 stores registrations. Until this
     page existed there was exactly one way to read them back: SQL in the
     Supabase editor — which nobody in the office is going to run, so the
     registrations would pile up unread and the form would have been a way of
     collecting people's mobile numbers for nothing.

     That mistake has now been made twice on this site: the course sign-ups in
     September, and Gift Aid the same week. Turning a form on and giving a
     human a way to read it back are two jobs, and only the first one feels
     finished.

     THE QUESTION THE COMMITTEE ACTUALLY ASKED is not "who registered" but
     "have we got enough people to open?" — so the counts are at the top and
     the list is underneath, rather than the other way round.
     ======================================================================= */
  var volunteers = (function () {
    var rows = [];
    var summary = {};
    var filter = "all";
    var search = "";
    var mounted = false;

    function canSee(identity) {
      return identity.roles.indexOf("admin") !== -1 ||
             identity.roles.indexOf("hall_office") !== -1;
    }

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/[&<>"']/g, function (c) {
          return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;",
                    '"': "&quot;", "'": "&#39;" })[c];
        });
    }

    function when(iso) {
      if (!iso) return "—";
      var d = new Date(iso);
      if (isNaN(d)) return "—";
      // Built from the parts rather than toLocaleDateString: the office reads
      // this in Bolton and the browser's locale is not a promise.
      var m = ["Jan","Feb","Mar","Apr","May","Jun",
               "Jul","Aug","Sep","Oct","Nov","Dec"];
      return d.getDate() + " " + m[d.getMonth()] + " " + d.getFullYear();
    }

    // Twelve months after they registered, to the day. The office should be
    // able to see when somebody is about to drop off the list rather than
    // discover it afterwards.
    function goesOn(iso) {
      if (!iso) return "—";
      var d = new Date(iso);
      if (isNaN(d)) return "—";
      d.setFullYear(d.getFullYear() + 1);
      return when(d.toISOString());
    }

    var HOW = { phone: "Prefers a call", text: "Prefers a text", email: "Prefers email" };
    var FREQ = { weekly: "Weekly", fortnightly: "Fortnightly", monthly: "Monthly" };
    var STATE = { waiting: "Not rung yet", contacted: "Contacted",
                  helping: "Helping", withdrawn: "Withdrawn" };

    function matches(r) {
      if (filter === "waiting"   && r.status !== "waiting") return false;
      if (filter === "helping"   && r.status !== "helping") return false;
      if (filter === "withdrawn" && r.status !== "withdrawn") return false;
      if (filter === "sundays"   && !(r.sunday_mornings && r.status !== "withdrawn")) return false;
      if (filter === "weekly"    && !(r.frequency === "weekly" && r.status !== "withdrawn")) return false;
      if (filter !== "withdrawn" && filter !== "all" && r.status === "withdrawn") return false;
      if (!search) return true;
      var hay = [r.full_name, r.phone, r.email, r.skills, r.reference]
                  .join(" ").toLowerCase();
      return hay.indexOf(search) !== -1;
    }

    function counts() {
      function n(id, v) { var e = el(id); if (e) e.textContent = v; }
      n("vol-n-all",      rows.length);
      n("vol-n-waiting",  rows.filter(function (r) { return r.status === "waiting"; }).length);
      n("vol-n-sundays",  rows.filter(function (r) { return r.sunday_mornings && r.status !== "withdrawn"; }).length);
      n("vol-n-weekly",   rows.filter(function (r) { return r.frequency === "weekly" && r.status !== "withdrawn"; }).length);
      n("vol-n-helping",  rows.filter(function (r) { return r.status === "helping"; }).length);
      n("vol-n-withdrawn",rows.filter(function (r) { return r.status === "withdrawn"; }).length);
    }

    function renderSummary() {
      var s = summary || {};
      var box = el("vol-sum");
      if (!box) return;
      // "Willing to help" excludes anybody who has withdrawn. A headline
      // count that quietly includes people who have said no is the kind of
      // number a committee makes a decision on and then regrets.
      var willing = (s.total || 0) - (s.withdrawn || 0);
      box.innerHTML =
        '<div class="big"><span class="n">' + willing + '</span>' +
          '<span class="k">Willing to help</span></div>' +
        '<div><span class="n">' + (s.sundays || 0) + '</span>' +
          '<span class="k">Free Sunday mornings</span></div>' +
        '<div><span class="n">' + (s.waiting || 0) + '</span>' +
          '<span class="k">Still to ring</span></div>' +
        '<div><span class="n">' + (s.male || 0) + ' / ' + (s.female || 0) + '</span>' +
          '<span class="k">Male / female</span></div>';

      var ret = el("vol-retain");
      if (ret) ret.textContent =
        "Registrations are deleted twelve months after they arrive, automatically. " +
        "Each card below shows the date its registration goes.";
    }

    function render() {
      counts();
      var list = el("vol-list");
      if (!list) return;
      var shown = rows.filter(matches);

      if (!shown.length) {
        list.innerHTML = '<div class="vol-empty">' +
          (rows.length ? "Nobody matches that." :
           "Nobody has registered yet. The link is on the Food Bank card on the home page.") +
          "</div>";
        return;
      }

      list.innerHTML = shown.map(function (r) {
        var reach = r.preferred_contact === "email" && r.email
          ? '<a href="mailto:' + esc(r.email) + '">' + esc(r.email) + "</a>"
          : '<a href="tel:' + esc(String(r.phone).replace(/\s/g, "")) + '">' + esc(r.phone) + "</a>";

        return '<div class="vol-row" data-ref="' + esc(r.reference) + '">' +
          '<div class="vol-top"><span class="vol-name">' + esc(r.full_name) + "</span>" +
            '<span class="vol-ref">' + esc(r.reference) + "</span></div>" +
          '<div class="vol-facts">' +
            '<span class="' + (r.status === "waiting" ? "hi" : "") + '">' +
              esc(STATE[r.status] || r.status) + "</span>" +
            "<span>" + esc(r.gender === "female" ? "Female" : "Male") + ", " + esc(r.age) + "</span>" +
            '<span class="' + (r.sunday_mornings ? "hi" : "") + '">' +
              (r.sunday_mornings ? "Free Sundays" : "Not Sundays") + "</span>" +
            "<span>" + esc(FREQ[r.frequency] || r.frequency) + "</span>" +
            "<span>" + esc(HOW[r.preferred_contact] || r.preferred_contact) + "</span>" +
          "</div>" +
          '<div class="vol-contact">' + reach +
            (r.email && r.preferred_contact !== "email"
              ? ' &middot; <a href="mailto:' + esc(r.email) + '">' + esc(r.email) + "</a>" : "") +
          "</div>" +
          (r.skills ? '<div class="vol-skills">' + esc(r.skills) + "</div>" : "") +
          (r.note ? '<div class="vol-note">' + esc(r.note) + "</div>" : "") +
          '<div class="vol-skills" style="margin-top:6px;">Registered ' + esc(when(r.created_at)) +
            " &middot; deleted " + esc(goesOn(r.created_at)) + "</div>" +
          '<div class="vol-acts">' +
            '<button type="button" data-act="contacted">Rung them</button>' +
            '<button type="button" data-act="helping">Helping</button>' +
            '<button type="button" data-act="withdrawn">Withdrawn</button>' +
            '<button type="button" data-act="waiting">Back to the list</button>' +
          "</div>" +
        "</div>";
      }).join("");
    }

    function csv() {
      var head = ["Reference", "Name", "Phone", "Email", "Gender", "Age",
                  "Prefers", "Sunday mornings", "How often", "Skills",
                  "Status", "Registered", "Deleted on"];
      function cell(v) {
        var t = v === null || v === undefined ? "" : String(v);
        return /[",\n]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t;
      }
      var body = rows.filter(matches).map(function (r) {
        return [r.reference, r.full_name, r.phone, r.email || "",
                r.gender, r.age, r.preferred_contact,
                r.sunday_mornings ? "Yes" : "No", r.frequency,
                r.skills || "", r.status, when(r.created_at), goesOn(r.created_at)]
               .map(cell).join(",");
      });
      return head.join(",") + "\n" + body.join("\n") + "\n";
    }

    function load() {
      setError("vol-error", "");
      return Promise.all([
        sb.from("foodbank_volunteers")
          .select("reference, full_name, phone, email, gender, age, " +
                  "preferred_contact, sunday_mornings, frequency, skills, " +
                  "status, note, created_at")
          .order("created_at", { ascending: false }),
        sb.rpc("foodbank_volunteer_summary")
      ]).then(function (out) {
        if (out[0].error) throw out[0].error;
        rows = out[0].data || [];
        summary = (out[1] && out[1].data) || {};
        renderSummary();
        render();
      }).catch(function (err) {
        setError("vol-error",
          "Couldn't load the volunteer list. " + (err.message || ""));
      });
    }

    function wire() {
      if (mounted) return;
      mounted = true;

      var tabs = el("vol-tabs");
      if (tabs) tabs.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest(".bk-tab") : null;
        if (!b) return;
        filter = b.getAttribute("data-filter");
        Array.prototype.forEach.call(tabs.querySelectorAll(".bk-tab"), function (t) {
          t.classList.toggle("on", t === b);
        });
        render();
      });

      var box = el("vol-search");
      if (box) box.addEventListener("input", function () {
        search = (box.value || "").trim().toLowerCase();
        render();
      });

      var list = el("vol-list");
      if (list) list.addEventListener("click", function (e) {
        var btn = e.target.closest ? e.target.closest("button[data-act]") : null;
        if (!btn) return;
        var row = btn.closest(".vol-row");
        if (!row) return;
        var ref = row.getAttribute("data-ref");
        var act = btn.getAttribute("data-act");

        // A note is optional, and cancelling the prompt must not cancel the
        // status change — the office rang them either way.
        var note = null;
        if (act === "contacted" || act === "withdrawn") {
          note = window.prompt(act === "withdrawn"
            ? "Anything worth recording about why? (optional)"
            : "Anything worth recording from the call? (optional)", "");
        }

        Array.prototype.forEach.call(row.querySelectorAll("button"), function (b) {
          b.disabled = true;
        });

        sb.rpc("set_volunteer_status", {
          p_reference: ref, p_status: act, p_note: note || null
        }).then(function (res) {
          if (res.error) throw res.error;
          return load();
        }).catch(function (err) {
          setError("vol-error", "Couldn't update that. " + (err.message || ""));
          Array.prototype.forEach.call(row.querySelectorAll("button"), function (b) {
            b.disabled = false;
          });
        });
      });

      var dl = el("vol-csv");
      if (dl) dl.addEventListener("click", function () {
        // The file holds people's mobile numbers, so it is a deliberate act
        // with a dated filename rather than something that happens on load.
        var blob = new Blob([csv()], { type: "text/csv;charset=utf-8" });
        var a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = "foodbank-volunteers-" +
                     new Date().toISOString().slice(0, 10) + ".csv";
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
      });
    }

    return {
      mount: function (identity) {
        var panel = el("vol-panel");
        var noaccess = el("app-noaccess");
        if (!canSee(identity)) {
          if (panel) panel.hidden = true;
          if (noaccess) noaccess.hidden = false;
          return;
        }
        if (noaccess) noaccess.hidden = true;
        if (panel) panel.hidden = false;
        wire();
        load();
      }
    };
  })();

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'volunteers',
        title:   'Food Bank volunteers',
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
    try { volunteers.mount(identity); } catch (e) {
      if (window.console) console.warn("volunteer panel unavailable:", e);
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
