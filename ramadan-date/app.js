/* ===========================================================================
   Taiyabah Masjid — the Ramadan countdown date, edited by the masjid
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   Ramadan's start is subject to moon sighting — the date moves by a day most
   years, and the one year it genuinely matters that the website agree with
   the masjid is the one year the committee corrects it. db/150 moved it into
   site_content, the same way db/028 and db/045 did for the new build appeal
   and the hall hire rate card; this is the screen that writes it.

   THE SHAPE OF THIS SCREEN, AND WHY
   ---------------------------------
     * SAVING IS PUBLISHING. There is no draft. set_site_content() writes the
       one row the Ramadan page reads, and it picks the new date up on its
       next load — see rates/app.js for the fuller version of this note; it
       applies here unchanged.

     * THE COMPLAINTS ARE THE DATABASE'S OWN. check() below is
       check_ramadan() from db/150, rule for rule — a real calendar date in
       the form YYYY-MM-DD, a note of at most 200 characters. Copied rather
       than invented for the same reason rates/app.js copies check_hallhire():
       a validator here that disagrees with the one in Postgres puts a raw
       constraint error in front of a volunteer.

   None of this is a security control. It is JavaScript in a browser with the
   anon key beside it, and set_site_content() is refused by Postgres to
   anybody who is not a verified administrator with two-step. It is here so a
   committee member is told what is wrong in plain English.
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
     RAMADAN DATE MODULE. Everything on this screen, kept in one place so
     that if it throws, the sign-in shell around it survives — see
     renderApp. */
  var ramadan = (function () {
    "use strict";

    var NOTE_MAX = 200;   // length(v_note) > 200 — check_ramadan(), db/150
    var ISO_RE   = /^\d{4}-\d{2}-\d{2}$/;

    var SAVE_LABEL = "Save — this goes live at once";

    var doc   = null;   // what is being edited: {starts_on, note}
    var saved = null;   // what came back from the database, for Undo
    var meta  = null;   // updated_at, for the "last changed" line
    var wired = false;

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function trim(v) { return String(v == null ? "" : v).trim(); }

    function note(id, msg) {
      var n = el(id); if (!n) return;
      if (!msg) { n.hidden = true; n.textContent = ""; return; }
      n.textContent = msg; n.hidden = false;
    }

    /* =====================================================================
       check() — check_ramadan() from db/150, in the browser. Pure: no DOM,
       no network, no session. Mirrors rates/app.js's check() in shape, with
       one difference check_hallhire() does not have to make: a date has to
       be told apart from a string that merely looks like one, which is what
       the Date parse below is for. =================================== */
    function check(o) {
      if (!o || typeof o !== "object" || Array.isArray(o)) {
        return ["The countdown did not arrive as expected. Reload the page and try again."];
      }

      var out = [];
      var raw = trim(o.starts_on);

      if (raw === "") {
        out.push("The date Ramadan is expected to start cannot be empty.");
      } else if (!ISO_RE.test(raw)) {
        out.push("The date must be in the form YYYY-MM-DD, like 2027-02-08.");
      } else {
        //  A string of the right SHAPE is not a real date — "2027-02-30"
        //  matches the regex and still is not the 30th of February.
        var d = new Date(raw + "T00:00:00Z");
        var stamp = isNaN(d.getTime()) ? "" : d.toISOString().slice(0, 10);
        if (stamp !== raw) {
          out.push('"' + raw + '" is not a real date.');
        }
      }

      var noteVal = trim(o.note);
      if (noteVal.length > NOTE_MAX) {
        out.push("The note is " + noteVal.length + " characters. The limit is " + NOTE_MAX + ".");
      }

      return out;
    }

    function blank() {
      return { starts_on: "", note: "" };
    }

    function readable(iso) {
      if (!iso) return "";
      var d = new Date(iso);
      if (isNaN(d.getTime())) return "";
      try {
        return d.toLocaleString("en-GB", {
          weekday: "short", day: "numeric", month: "short", year: "numeric",
          hour: "2-digit", minute: "2-digit"
        });
      } catch (e) {
        return d.toISOString().slice(0, 16).replace("T", " ");
      }
    }

    // --- reading the boxes back ----------------------------------------------
    function harvest() {
      if (!doc) doc = blank();
      var dateBox = el("rd-date");
      var noteBox = el("rd-note");
      if (dateBox) doc.starts_on = dateBox.value;
      if (noteBox) doc.note = noteBox.value;
      return doc;
    }

    function body() {
      var o = harvest();
      return { starts_on: trim(o.starts_on), note: trim(o.note) };
    }

    // --- drawing the editor --------------------------------------------------
    function countdown(boxId, value, limit) {
      var box = el(boxId);
      if (!box) return;
      var left = limit - trim(value).length;
      box.textContent = left >= 0
        ? left + " characters left"
        : (-left) + " characters too many — the limit is " + limit;
      box.classList.toggle("is-over", left < 0);
    }

    /* ---------------------------------------------------------- the preview
       Drawn to look like the countdown card on the public Ramadan page, for
       the same reason rates/app.js's preview is drawn to look like the rate
       card: recognising what you are about to publish is the whole point of
       a preview. Days-to-go is computed the same way the public page's
       rmLoad() computes it — UK midnight on both sides, so the two never
       disagree by a day because one used the visitor's local clock time. */
    function drawPreview(b) {
      var host = el("rd-pv");
      if (!host) return;

      if (!b.starts_on || !ISO_RE.test(b.starts_on)) {
        host.innerHTML = '<div class="lk">Ramadan is expected to begin</div>' +
          '<div class="rd-pv-days">—</div>' +
          '<div class="rd-pv-note rd-pv-bad">No valid date yet — the public page would show a dash instead of a countdown.</div>';
        return;
      }

      var target = new Date(b.starts_on + "T00:00:00Z");
      var now = new Date();
      var todayUK = new Date(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()));
      var days = Math.floor((target - todayUK) / 86400000);

      var daysText, labelText;
      if (days > 0) {
        daysText = String(days);
        labelText = days === 1 ? "day to go" : "days to go";
      } else if (days === 0) {
        daysText = "Today";
        labelText = "Ramadan Mubārak.";
      } else {
        daysText = "Mubārak";
        labelText = "Ramadan is underway.";
      }

      var dateReadable = target.toLocaleDateString("en-GB",
        { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });

      host.innerHTML =
        '<div class="lk">Ramadan is expected to begin</div>' +
        '<div class="rd-pv-days">' + esc(daysText) + '</div>' +
        '<div class="rd-pv-label">' + esc(labelText) + '</div>' +
        '<div class="rd-pv-date">' + esc(dateReadable) + '</div>' +
        (b.note ? '<div class="rd-pv-note">' + esc(b.note) + '</div>' : '');
    }

    function drawMeta() {
      var box = el("rd-meta");
      if (!box) return;
      if (!meta || !meta.updated_at) {
        box.textContent = "Last changed: not known — this is still what the website " +
                          "was built with.";
        return;
      }
      box.textContent = "Last changed " + readable(meta.updated_at) + ".";
    }

    function revalidate() {
      var b = body();
      countdown("rd-note-count", b.note, NOTE_MAX);
      drawPreview(b);

      var complaints = check(b);
      var box = el("rd-complaints");
      if (box) {
        if (complaints.length) {
          box.innerHTML = "<ul>" + complaints.map(function (c) {
            return "<li>" + esc(c) + "</li>";
          }).join("") + "</ul>";
          box.hidden = false;
        } else {
          box.hidden = true;
          box.innerHTML = "";
        }
      }
      var save = el("rd-save");
      if (save) save.disabled = complaints.length > 0;
      return complaints;
    }

    function draw() {
      var dateBox = el("rd-date");
      if (dateBox) dateBox.value = (doc && doc.starts_on) || "";
      var noteBox = el("rd-note");
      if (noteBox) noteBox.value = (doc && doc.note) || "";
      drawMeta();
      revalidate();
    }

    // --- loading and saving --------------------------------------------------
    function load() {
      note("rd-error", "");
      return sb.from("site_content").select("body,updated_at")
               .eq("key", "ramadan").single()
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var row = res.data || {};
          doc = row.body ? JSON.parse(JSON.stringify(row.body)) : blank();
          if (typeof doc.starts_on !== "string") doc.starts_on = "";
          if (typeof doc.note !== "string") doc.note = "";
          meta  = { updated_at: row.updated_at };
          saved = JSON.stringify(doc);
          draw();
        })
        .catch(function (e) {
          note("rd-error", "Couldn't read the Ramadan date: " + (e.message || e) +
                           " — nothing on the website has changed.");
          if (!doc) { doc = blank(); draw(); }
        });
    }

    function save() {
      if (revalidate().length) return;

      var out = body();
      var btn = el("rd-save");
      busy(btn, true, SAVE_LABEL);
      note("rd-error", ""); note("rd-ok", "");

      sb.rpc("set_site_content", { p_key: "ramadan", p_body: out })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          note("rd-ok", "Saved. This is on the Ramadan page of the website now — " +
                        "there is nothing else to press. Anybody with the page already " +
                        "open sees it when they next load it.");
          return load();
        })
        .catch(function (e) {
          note("rd-error", e.message || String(e));
        })
        .finally(function () {
          busy(btn, false, SAVE_LABEL);
          revalidate();
        });
    }

    // --- wiring --------------------------------------------------------------
    function wire() {
      if (wired) return true;
      wired = true;
      if (!doc) doc = blank();

      var dateBox = el("rd-date");
      if (dateBox) dateBox.addEventListener("input", revalidate);
      var noteBox = el("rd-note");
      if (noteBox) noteBox.addEventListener("input", revalidate);

      var saveBtn = el("rd-save");
      if (saveBtn) saveBtn.addEventListener("click", save);

      var revert = el("rd-revert");
      if (revert) revert.addEventListener("click", function () {
        if (!saved) {
          note("rd-error", "There is nothing to go back to — the Ramadan date on the " +
                           "website has not been read yet.");
          return;
        }
        if (!window.confirm("Throw away the changes you have made on this screen?\n\n" +
              "The website is unaffected either way — nothing has been saved.")) return;
        doc = JSON.parse(saved);
        draw();
        note("rd-error", "");
        note("rd-ok", "Back to what is on the website.");
      });

      draw();
      return true;
    }

    function mount(identity) {
      wire();
      return load();
    }

    return { mount: mount, _check: check, _wire: wire };
  })();

  /*  EXPOSED FOR THE TESTS. Same reason as rates/app.js's window.__RATES_FORM
      — see the note there. check() is pure and has to agree with
      check_ramadan() in db/150 exactly; wire() must be reachable without a
      real sign-in, because the rule "nothing is saveable until the form is
      valid" has to be provable from outside mount(). */
  window.__RAMADAN_FORM = { check: ramadan._check, wire: ramadan._wire };

  function renderApp(identity) {
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'ramadan',
        title:   'Ramadan date',
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

    try { ramadan.mount(identity); } catch (e) {
      if (window.console) console.warn("Ramadan date editor unavailable:", e);
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
