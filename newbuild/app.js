/* ===========================================================================
   Taiyabah Masjid — the new build page, edited by the masjid
   Bolton Central Islamic Society · Registered charity 1041569

   The appeal figure on the new build page used to live in
   index_template.html. Moving it meant editing that file, running build.py and
   pushing — so the headline number on a charity's fundraising page depended on
   one person being reachable. This screen is what deletes that sentence, and
   it is the last big one on this project.

   The sign-in, two-step and enrolment flow below is the one from /access/,
   unchanged — same shell, same views, same ids. A second hand-written copy of
   an authentication flow is a second place for it to be wrong.

   WHAT IT DOES NOT DECIDE. Whether the content is valid: check_newbuild() in
   Postgres settles that. The checks in the editor exist to tell somebody
   before a round trip, not instead of one — the anon key is in the page source
   and anybody can POST straight at PostgREST.
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
  /* =========================================================================
     THE NEW BUILD PAGE, EDITED BY THE MASJID

     WHAT THIS DELETES. Until now the appeal figure lived in
     index_template.html. Moving it meant editing that file, running build.py
     and pushing — so the headline number on a charity's fundraising page
     depended on one person being reachable. Everything else on this project
     has been about removing that sentence; this is the last big one.

     THE PERCENTAGE IS NOT A FIELD. It is worked out from raised and target,
     here for the preview and again on the public page. The template used to
     carry it three times over with a comment warning the copies "must not
     drift", which is a rule kept by hope. A number that can only be derived
     cannot disagree with itself.

     WHAT THIS SCREEN DOES NOT DECIDE. Whether the content is valid.
     check_newbuild() in Postgres does that — a target of zero, a missing
     heading, two phases both claiming to be the current appeal. The checks
     below exist to tell somebody BEFORE a round trip, not instead of it: the
     anon key is in the page source and anybody can POST straight at
     PostgREST, so a rule that lives only here does not exist.
     ======================================================================= */
  var newbuild = (function () {
    var mounted = false;
    var doc     = null;   // what is being edited
    var saved   = null;   // what came back from the database, for Undo
    var meta    = null;

    function canSee(identity) { return identity.roles.indexOf("admin") !== -1; }

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/[&<>"']/g, function (c) {
          return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;",
                    '"': "&quot;", "'": "&#39;" })[c];
        });
    }

    function say(id, msg, isError) {
      var box = el(id);
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
      box.scrollIntoView({ behavior: "smooth", block: "center" });
    }

    /* Pounds in, pence out. "£2,500,000", "2500000" and "2,500,000" are all
       the same thing to somebody typing quickly at a committee meeting, and
       refusing two of the three would be pedantry. A number with pence in it
       is rounded rather than refused — nobody raises £350,000.50. */
    function toPence(v) {
      var n = Number(String(v == null ? "" : v).replace(/[^0-9.]/g, ""));
      if (!isFinite(n)) return NaN;
      return Math.round(n * 100);
    }
    function toPounds(p) {
      return (Math.round(Number(p) / 100)).toLocaleString("en-GB");
    }
    function money(p) {
      return "£" + toPounds(p);
    }

    var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    function when(iso) {
      if (!iso) return "";
      var d = new Date(iso);
      if (isNaN(d)) return "";
      return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear();
    }

    /* ---- drawing ---------------------------------------------------------- */

    function drawAppeal() {
      var a = doc.appeal || {};
      el("nbf-tag").value     = a.tag || "";
      el("nbf-heading").value = a.heading || "";
      el("nbf-body").value    = a.body || "";
      el("nbf-raised").value  = a.raised_p ? toPounds(a.raised_p) : "";
      el("nbf-target").value  = a.target_p ? toPounds(a.target_p) : "";
      el("nbf-needs").value   = (a.needs || []).join(", ");
      drawPreview();
    }

    function drawPreview() {
      var raised = toPence(el("nbf-raised").value);
      var target = toPence(el("nbf-target").value);
      var box = el("nb-preview");

      //  A target of zero or nonsense is the one input that breaks the public
      //  page rather than merely looking wrong on it, so the preview says so
      //  instead of drawing something meaningless.
      if (!isFinite(target) || target <= 0) {
        box.classList.add("nb-pv-bad");
        el("nb-pv-raised").textContent = "—";
        el("nb-pv-pct").textContent = "no target";
        el("nb-pv-fill").style.width = "0";
        el("nb-pv-left").textContent =
          "Put a target in. Without one the bar on the public page cannot be drawn.";
        return;
      }
      if (!isFinite(raised) || raised < 0) raised = 0;

      var pct  = Math.round((raised / target) * 100);
      var left = Math.max(0, target - raised);
      box.classList.remove("nb-pv-bad");
      el("nb-pv-raised").textContent = money(raised) + " of " + money(target);
      el("nb-pv-pct").textContent = pct + "% funded";
      //  Capped, exactly as the public page caps it. A 140% bar overflowing its
      //  track is the sort of thing that only shows up on the live site.
      el("nb-pv-fill").style.width = Math.max(0, Math.min(100, pct)) + "%";
      el("nb-pv-left").textContent = left > 0
        ? money(left) + " still to raise."
        : "Fully funded — the public page will say so rather than showing a target.";
    }

    var STATUS = [
      { v: "done",     t: "Finished" },
      { v: "active",   t: "Now — the current appeal" },
      { v: "upcoming", t: "Still to come" }
    ];

    function drawItems() {
      var wrap = el("nb-items");
      var list = doc.timeline || [];
      if (!list.length) {
        wrap.innerHTML = '<div class="nb-empty">No phases yet. The public page ' +
          "needs at least one, and one of them has to be the current appeal.</div>";
        return;
      }
      wrap.innerHTML = list.map(function (it, i) {
        return '<div class="nb-item' + (it.status === "active" ? " is-now" : "") +
                 '" data-i="' + i + '">' +
          '<div class="nb-item-top">' +
            '<span class="nb-item-n">Phase ' + (i + 1) + " of " + list.length + "</span>" +
            '<span class="nb-item-acts">' +
              '<button type="button" data-act="up"' + (i === 0 ? " disabled" : "") + ">Up</button>" +
              '<button type="button" data-act="down"' + (i === list.length - 1 ? " disabled" : "") + ">Down</button>" +
              '<button type="button" class="no" data-act="remove">Remove</button>' +
            "</span>" +
          "</div>" +
          '<div class="nb-two">' +
            '<div class="cf-row"><label>When</label>' +
              '<input type="text" data-f="date" maxlength="80" value="' + esc(it.date) + '"></div>' +
            '<div class="cf-row"><label>What it is called</label>' +
              '<input type="text" data-f="title" maxlength="120" value="' + esc(it.title) + '"></div>' +
          "</div>" +
          '<div class="nb-two" style="margin-top:11px;">' +
            '<div class="cf-row"><label>Where it stands</label>' +
              '<select data-f="status">' +
                STATUS.map(function (s) {
                  return '<option value="' + s.v + '"' +
                    (it.status === s.v ? " selected" : "") + ">" + esc(s.t) + "</option>";
                }).join("") +
              "</select></div>" +
            '<div class="cf-row"><label>Wording on the badge</label>' +
              '<input type="text" data-f="label" maxlength="40" value="' + esc(it.label) + '"></div>' +
          "</div>" +
          '<div class="cf-row" style="margin-top:11px;"><label>What happened, or will</label>' +
            '<textarea data-f="body" rows="3" maxlength="900">' + esc(it.body) + "</textarea></div>" +
        "</div>";
      }).join("");
    }

    function drawMeta() {
      var box = el("nb-meta");
      if (!box) return;
      if (!meta || !meta.updated_at) {
        box.textContent = "This has not been changed since the website was built.";
        return;
      }
      box.textContent = "Last changed " + when(meta.updated_at) +
        (meta.by ? " by " + meta.by : "") + ".";
    }

    function draw() { drawAppeal(); drawItems(); drawMeta(); }

    /* ---- reading the form back ------------------------------------------- */

    function harvest() {
      doc.appeal = {
        tag:      (el("nbf-tag").value || "").trim(),
        heading:  (el("nbf-heading").value || "").trim(),
        body:     (el("nbf-body").value || "").trim(),
        raised_p: toPence(el("nbf-raised").value),
        target_p: toPence(el("nbf-target").value),
        needs:    (el("nbf-needs").value || "").split(",")
                    .map(function (s) { return s.trim(); })
                    .filter(function (s) { return s.length; })
      };
      Array.prototype.forEach.call(el("nb-items").querySelectorAll(".nb-item"),
        function (row) {
          var i = Number(row.getAttribute("data-i"));
          var it = doc.timeline[i];
          if (!it) return;
          Array.prototype.forEach.call(row.querySelectorAll("[data-f]"), function (f) {
            it[f.getAttribute("data-f")] = f.value;
          });
        });
      return doc;
    }

    /* ---- loading and saving ---------------------------------------------- */

    function load() {
      say("nb-error", "");
      return sb.from("site_content").select("body, updated_at, updated_by")
               .eq("key", "newbuild").maybeSingle()
        .then(function (res) {
          if (res.error) throw res.error;
          var row = res.data;
          if (!row || !row.body) {
            //  Nothing seeded. Rather than an empty form with no hint of what
            //  goes in it, start from a shape the database will accept.
            doc = { appeal: { tag: "", heading: "", body: "", raised_p: 0,
                              target_p: 0, needs: [] },
                    timeline: [] };
            meta = null;
          } else {
            doc  = JSON.parse(JSON.stringify(row.body));
            meta = { updated_at: row.updated_at };
          }
          saved = JSON.stringify(doc);
          draw();
        }).catch(function (err) {
          say("nb-error", "Couldn't read the page content. " + (err.message || ""), true);
        });
    }

    function save() {
      say("nb-error", ""); say("nb-ok", "");
      var out = harvest();

      //  Told here so somebody is not made to wait for a round trip to hear
      //  something obvious. The database checks all of it again.
      if (!isFinite(out.appeal.target_p) || out.appeal.target_p <= 0) {
        say("nb-error", "Put a target in. Without one the bar cannot be drawn.", true);
        return;
      }
      if (!out.appeal.heading) {
        say("nb-error", "The appeal needs a heading.", true); return;
      }
      var now = (out.timeline || []).filter(function (i) { return i.status === "active"; });
      if (now.length !== 1) {
        say("nb-error", now.length === 0
          ? "One phase has to be marked as the current appeal, or the page will " +
            "not be asking for anything."
          : "Two phases are both marked as the current appeal. The page can only " +
            "ask for one thing at a time.", true);
        return;
      }

      var btn = el("nb-save");
      btn.disabled = true; btn.textContent = "Saving…";
      sb.rpc("set_site_content", { p_key: "newbuild", p_body: out })
        .then(function (res) {
          if (res.error) throw res.error;
          saved = JSON.stringify(doc);
          say("nb-ok", "Saved. The website is showing this now.");
          return load();
        }).catch(function (err) {
          say("nb-error", err.message || "That did not work.", true);
        }).finally(function () {
          btn.disabled = false; btn.textContent = "Save and publish";
        });
    }

    function wire() {
      if (mounted) return;
      mounted = true;

      ["nbf-raised", "nbf-target"].forEach(function (id) {
        el(id).addEventListener("input", drawPreview);
      });

      el("nb-add").addEventListener("click", function () {
        harvest();
        doc.timeline.push({ date: "", title: "", status: "upcoming",
                            label: "Planned", body: "" });
        drawItems();
        var rows = el("nb-items").querySelectorAll(".nb-item");
        var last = rows[rows.length - 1];
        if (last) {
          last.scrollIntoView({ behavior: "smooth", block: "center" });
          var first = last.querySelector("input");
          if (first) first.focus();
        }
      });

      /* One listener on the container rather than one per button: the rows are
         redrawn on every change, so per-row listeners would be re-attached
         each time and the old ones left behind. */
      el("nb-items").addEventListener("click", function (e) {
        var btn = e.target.closest ? e.target.closest("button[data-act]") : null;
        if (!btn) return;
        var row = btn.closest(".nb-item");
        var i = Number(row.getAttribute("data-i"));
        var act = btn.getAttribute("data-act");

        //  Read the boxes back BEFORE reordering, or whatever somebody has
        //  typed since the last draw is thrown away by the redraw.
        harvest();

        if (act === "remove") {
          var it = doc.timeline[i];
          if (!window.confirm("Remove “" + (it.title || "this phase") +
                "” from the timeline?\n\nIt disappears from the public page " +
                "as soon as you save.")) return;
          doc.timeline.splice(i, 1);
        } else if (act === "up" && i > 0) {
          doc.timeline.splice(i - 1, 0, doc.timeline.splice(i, 1)[0]);
        } else if (act === "down" && i < doc.timeline.length - 1) {
          doc.timeline.splice(i + 1, 0, doc.timeline.splice(i, 1)[0]);
        }
        drawItems();
      });

      //  Redraw when the status changes so the "current appeal" highlight
      //  follows it. Delegated for the same reason as the buttons.
      el("nb-items").addEventListener("change", function (e) {
        if (!e.target.matches || !e.target.matches('select[data-f="status"]')) return;
        harvest();
        drawItems();
      });

      el("nb-save").addEventListener("click", save);

      el("nb-revert").addEventListener("click", function () {
        if (!saved) return;
        if (!window.confirm("Throw away the changes you have made on this screen?\n\n" +
              "The website is unaffected either way — nothing has been published.")) return;
        doc = JSON.parse(saved);
        draw();
        say("nb-ok", "Back to what is on the website.");
      });
    }

    return {
      mount: function (identity) {
        var panel = el("nb-panel"), noaccess = el("app-noaccess");
        if (!canSee(identity)) {
          if (panel) panel.hidden = true;
          if (noaccess) noaccess.hidden = false;
          return;
        }
        if (noaccess) noaccess.hidden = true;
        if (panel) panel.hidden = false;

        var shell = document.querySelector(".shell");
        if (shell) shell.classList.add("wide-mode");

        var top = el("app-top");
        if (top) {
          top.hidden = false;
          el("app-top-email").textContent = identity.user.email;
        }
        ["app-who", "app-roles", "app-signout"].forEach(function (id) {
          var n = el(id);
          if (n) n.hidden = true;
        });

        var out = el("app-signout-top");
        if (out && !out.wired) {
          out.wired = true;
          out.addEventListener("click", function () {
            sb.auth.signOut().then(function () {
              var s = document.querySelector(".shell");
              if (s) s.classList.remove("wide-mode");
              el("signin-email").value = "";
              el("signin-password").value = "";
              setError("signin-error", "");
              show("view-signin");
            });
          });
        }

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
        current: 'newbuild',
        title:   'The new build page',
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
    try { newbuild.mount(identity); } catch (e) {
      if (window.console) console.warn("new build editor unavailable:", e);
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
