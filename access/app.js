/* ===========================================================================
   Taiyabah Masjid — Who can get in
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   Until this screen, adding a volunteer or making somebody an administrator
   meant opening the Supabase SQL editor. That is not a handover; it is a
   dependency on one person being reachable. Planned 8 September, built on the
   12th because the new admin dashboard put "1 without 2FA" on the front page
   and there was nowhere to go and fix it.

   THE RULE THAT SHAPES ALL OF IT
   ------------------------------
   An invite records the role that is INTENDED. The role is not granted until
   the person has signed in and set up an authenticator.

   That is not caution for its own sake. 011_require_two_step.sql refuses to
   run while any role-holder lacks an authenticator, and the standing rule is
   to re-run 011 after every migration — so granting a role to somebody who
   then takes a fortnight to enrol would block all database work for that
   fortnight. Writing the intention down instead means an invite nobody
   accepts never creates a privileged account at all.

   WHAT THIS PAGE DOES NOT DECIDE
   ------------------------------
   Whether you may see the list, whether a role change is allowed, whether the
   last two administrators can be removed. All of that is in Postgres:
   staff_list(), set_person_roles(), and the keep_two_admins trigger. This
   page draws the answer and shows the refusal.
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
     WHO CAN GET IN

     Everything on this screen used to need somebody opening the Supabase SQL
     editor. That is not a handover — it is a dependency on one person.

     WHAT THE PAGE DOES NOT DECIDE. Whether you may see this list, whether a
     role change is allowed, whether an administrator can be removed: all of
     that is settled in Postgres by staff_list(), set_person_roles() and the
     keep_two_admins trigger. The buttons below are refused by the database
     when they should be, and the page shows what it said. A guard that lives
     only here is not a guard.
     ======================================================================= */
  var access = (function () {
    var data = { people: [], invites: [], admins: 0, me: null };
    var mounted = false;

    function canSee(identity) { return identity.roles.indexOf("admin") !== -1; }

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/[&<>"']/g, function (c) {
          return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;",
                    '"': "&quot;", "'": "&#39;" })[c];
        });
    }

    // Roles in plain English. Nobody in a masjid office should have to know
    // what "hall_office" means to work out who can do what.
    var SAYS = {
      admin:       "Everything",
      hall_office: "Hall bookings and nikāḥ",
      teacher:     "Madrasah",
      parent:      "Parent"
    };

    var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    function when(iso) {
      if (!iso) return "never";
      var d = new Date(iso);
      if (isNaN(d)) return "never";
      var days = Math.floor((Date.now() - d) / 86400000);
      if (days <= 0) return "today";
      if (days === 1) return "yesterday";
      if (days < 30) return days + " days ago";
      return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear();
    }

    function say(id, msg, isError) {
      var box = el(id);
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
      box.scrollIntoView({ behavior: "smooth", block: "center" });
    }

    function renderSummary() {
      var box = el("acc-sum");
      if (!box) return;
      var staff = data.people.filter(function (p) {
        return (p.roles || []).some(function (r) { return r !== "parent"; });
      });
      var no2fa = staff.filter(function (p) { return !p.two_step; }).length;
      box.innerHTML =
        '<div><span class="n">' + staff.length + '</span><span class="k">Staff accounts</span></div>' +
        '<div><span class="n">' + data.admins + '</span><span class="k">Administrators</span></div>' +
        '<div class="' + (no2fa ? "" : "big") + '"><span class="n" style="' +
          (no2fa ? "color:var(--danger);" : "") + '">' + no2fa +
          '</span><span class="k">Without two-step</span></div>';
    }

    function renderPending() {
      var lab = el("acc-pending-lab"), box = el("acc-pending");
      if (!box) return;
      if (!data.invites.length) { box.innerHTML = ""; if (lab) lab.hidden = true; return; }
      if (lab) lab.hidden = false;
      box.innerHTML = data.invites.map(function (i) {
        return '<div class="acc-row" data-email="' + esc(i.email) + '">' +
          '<div class="acc-top"><span class="acc-name">' + esc(i.email) + "</span>" +
            '<span class="acc-meta">' + (i.expired ? "expired" : "invited " + esc(when(i.invited_at))) + "</span></div>" +
          '<div class="acc-chips">' +
            (i.roles || []).map(function (r) {
              return '<span class="can">' + esc(SAYS[r] || r) + "</span>"; }).join("") +
            '<span>' + (i.expired ? "Link no longer works" : "Not accepted yet") + "</span></div>" +
          '<div class="acc-meta">Nothing is granted until they sign in and set up an authenticator.</div>' +
          '<div class="acc-acts"><button type="button" data-act="cancel">Cancel this invitation</button></div>' +
        "</div>";
      }).join("");
    }

    function renderPeople() {
      var box = el("acc-list");
      if (!box) return;
      var staff = data.people.filter(function (p) {
        return (p.roles || []).some(function (r) { return r !== "parent"; });
      });
      if (!staff.length) {
        box.innerHTML = '<div class="acc-empty">No staff accounts yet.</div>';
        return;
      }

      box.innerHTML = staff.map(function (p) {
        var roles = (p.roles || []).filter(function (r) { return r !== "parent"; });
        var isAdmin = roles.indexOf("admin") !== -1;

        // The last two administrators cannot have the role taken away. Said on
        // the card, rather than letting somebody press it and read an error:
        // the database refuses it either way, but being told first is better
        // than being told after.
        var lastTwo = isAdmin && data.admins <= 2;

        return '<div class="acc-row' + (p.is_me ? " me" : "") + (p.active === false ? " off" : "") +
               '" data-id="' + esc(p.id) + '">' +
          '<div class="acc-top">' +
            '<span class="acc-name">' + esc(p.name || "(no name yet)") +
              (p.is_me ? ' <span style="font-size:.72rem;color:var(--muted);font-family:inherit;font-weight:400;">— you</span>' : "") +
            "</span>" +
            '<span class="acc-mail">' + esc(p.email) + "</span>" +
          "</div>" +
          '<div class="acc-chips">' +
            (roles.length
              ? roles.map(function (r) { return '<span class="can">' + esc(SAYS[r] || r) + "</span>"; }).join("")
              : '<span>No access</span>') +
            (p.two_step
              ? '<span class="ok2fa">Two-step on</span>'
              : '<span class="no2fa">No authenticator</span>') +
            (p.active === false ? '<span>Suspended</span>' : "") +
          "</div>" +
          '<div class="acc-meta">Last signed in ' + esc(when(p.last_in)) +
            (p.two_step ? "" :
              ' &middot; <b style="color:#8f3f22;">blocks the next database change</b>') +
          "</div>" +
          '<div class="acc-acts">' +
            (p.is_me
              ? '<span class="acc-meta">You cannot change your own access &mdash; ask another administrator.</span>'
              : '<button type="button" data-act="roles">Change what they can do</button>' +
                (p.active === false
                  ? '<button type="button" data-act="restore">Restore access</button>'
                  : '<button type="button" data-act="suspend"' + (lastTwo ? " disabled" : "") + '>Suspend</button>') +
                (lastTwo ? '<span class="acc-meta">One of the last two administrators.</span>' : "")) +
          "</div>" +
        "</div>";
      }).join("");
    }

    function render() { renderSummary(); renderPending(); renderPeople(); }

    function load() {
      say("acc-error", "");
      return sb.rpc("staff_list").then(function (res) {
        if (res.error) throw res.error;
        var d = res.data || {};
        if (d.allowed === false) throw new Error("Not allowed.");
        data = { people: d.people || [], invites: d.invites || [],
                 admins: Number(d.admins || 0), me: d.me };
        render();
      }).catch(function (err) {
        say("acc-error", "Couldn't load the accounts. " + (err.message || ""), true);
      });
    }

    function chosenRoles() {
      return Array.prototype.slice.call(document.querySelectorAll(".inv-r"))
        .filter(function (c) { return c.checked; })
        .map(function (c) { return c.value; });
    }

    // admin reaches every payment and record; teacher reaches children's data.
    // Both make the confirm box appear.
    function loud(roles) {
      return roles.indexOf("admin") !== -1 || roles.indexOf("teacher") !== -1;
    }

    function refreshConfirm() {
      var roles = chosenRoles();
      var wrap = el("inv-confirm-wrap");
      if (!wrap) return;
      wrap.hidden = !loud(roles);
      var what = el("inv-confirm-what");
      if (what) {
        what.textContent = roles.indexOf("admin") !== -1
          ? "everything, including the power to change what other people can do"
          : "the madrasah portal, which holds children's records";
      }
    }

    function wire() {
      if (mounted) return;
      mounted = true;

      el("acc-invite-open").addEventListener("click", function () {
        el("acc-invite").hidden = false;
        el("inv-result").hidden = true;
        say("acc-ok", "");
        el("inv-email").focus();
      });
      el("inv-cancel").addEventListener("click", function () {
        el("acc-invite").hidden = true;
      });
      Array.prototype.forEach.call(document.querySelectorAll(".inv-r"), function (c) {
        c.addEventListener("change", refreshConfirm);
      });

      el("inv-send").addEventListener("click", function () {
        var email = (el("inv-email").value || "").trim().toLowerCase();
        var roles = chosenRoles();
        say("acc-error", "");

        if (!/^[^@\s]+@[^@\s]+\.[^@\s]{2,}$/.test(email)) {
          say("acc-error", "That does not look like an email address.", true); return;
        }
        if (!roles.length) {
          say("acc-error", "Choose what they will be able to do.", true); return;
        }
        if (loud(roles)) {
          var typed = (el("inv-confirm").value || "").trim().toLowerCase();
          if (typed !== email) {
            say("acc-error", "Type their email address again in the confirm box. " +
                "This one gives far-reaching access, so it asks twice.", true);
            return;
          }
        }

        var btn = el("inv-send");
        btn.disabled = true; btn.textContent = "Creating…";

        sb.auth.getSession().then(function (s) {
          var token = s.data && s.data.session && s.data.session.access_token;
          if (!token) throw new Error("Your session has expired. Sign in again.");
          return fetch(apiUrl + "/functions/v1/invite-user", {
            method: "POST",
            headers: { "content-type": "application/json",
                       apikey: cfg.SUPABASE_ANON_KEY,
                       Authorization: "Bearer " + token },
            body: JSON.stringify({ email: email, roles: roles,
                                   note: (el("inv-note").value || "").trim() })
          });
        }).then(function (r) {
          return r.text().then(function (t) {
            var body; try { body = JSON.parse(t); } catch (e) { body = { error: t }; }
            return { ok: r.ok, body: body };
          });
        }).then(function (res) {
          if (!res.ok) throw new Error(res.body.error || "That did not work.");
          el("inv-url").textContent = res.body.link;
          el("inv-result").hidden = false;
          say("acc-ok", res.body.kind === "existing"
            ? "That address already had an account, so this is a link for them to " +
              "set a new password rather than a new account. What they can do has been recorded."
            : "Invitation created. Send them the link below.");
          el("inv-email").value = ""; el("inv-note").value = "";
          el("inv-confirm").value = "";
          Array.prototype.forEach.call(document.querySelectorAll(".inv-r"),
            function (c) { c.checked = false; });
          refreshConfirm();
          return load();
        }).catch(function (err) {
          say("acc-error", err.message || "That did not work.", true);
        }).finally(function () {
          btn.disabled = false; btn.textContent = "Create the invitation";
        });
      });

      el("inv-copy").addEventListener("click", function () {
        var text = el("inv-url").textContent;
        var done = function () {
          el("inv-copy").textContent = "Copied";
          setTimeout(function () { el("inv-copy").textContent = "Copy the link"; }, 2000);
        };
        // navigator.clipboard needs a secure context and permission; the
        // fallback is what actually runs in some browsers, so it is not
        // decoration.
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(text).then(done, function () { pick(text, done); });
        } else { pick(text, done); }
      });

      el("inv-done").addEventListener("click", function () {
        el("acc-invite").hidden = true;
        el("inv-result").hidden = true;
      });

      el("acc-pending").addEventListener("click", function (e) {
        var btn = e.target.closest ? e.target.closest("button[data-act]") : null;
        if (!btn) return;
        var row = btn.closest(".acc-row");
        var email = row && row.getAttribute("data-email");
        if (!email) return;
        if (!window.confirm("Cancel the invitation for " + email + "?")) return;
        sb.rpc("cancel_invite", { p_email: email }).then(function (res) {
          if (res.error) throw res.error;
          say("acc-ok", "Invitation cancelled.");
          return load();
        }).catch(function (err) {
          say("acc-error", "Couldn't cancel that. " + (err.message || ""), true);
        });
      });

      el("acc-list").addEventListener("click", function (e) {
        var btn = e.target.closest ? e.target.closest("button[data-act]") : null;
        if (!btn) return;
        var row = btn.closest(".acc-row");
        var id = row && row.getAttribute("data-id");
        if (!id) return;
        var person = data.people.filter(function (p) { return p.id === id; })[0];
        if (!person) return;
        var act = btn.getAttribute("data-act");

        if (act === "suspend" || act === "restore") {
          var on = act === "restore";
          if (!window.confirm(on
                ? "Give " + person.email + " their access back?"
                : "Suspend " + person.email + "? Their access stops immediately. " +
                  "The account and the record of what they did are kept.")) return;
          Array.prototype.forEach.call(row.querySelectorAll("button"), function (b) { b.disabled = true; });
          sb.rpc("set_person_active", { p_user: id, p_active: on }).then(function (res) {
            if (res.error) throw res.error;
            say("acc-ok", on ? "Access restored." : "Access suspended.");
            return load();
          }).catch(function (err) {
            say("acc-error", err.message || "That did not work.", true);
            return load();
          });
          return;
        }

        if (act === "roles") {
          var current = (person.roles || []).filter(function (r) { return r !== "parent"; });
          var answer = window.prompt(
            "What should " + (person.name || person.email) + " be able to do?\n\n" +
            "Type any of these, separated by commas:\n" +
            "  hall      — hall bookings and nikah\n" +
            "  madrasah  — the madrasah portal\n" +
            "  everything — full administrator\n\n" +
            "Leave it empty to take all access away.",
            current.map(function (r) {
              return r === "hall_office" ? "hall" : r === "teacher" ? "madrasah" : "everything";
            }).join(", "));
          if (answer === null) return;

          var want = [];
          answer.toLowerCase().split(",").forEach(function (w) {
            w = w.trim();
            if (w === "hall" || w === "hall_office") want.push("hall_office");
            else if (w === "madrasah" || w === "teacher") want.push("teacher");
            else if (w === "everything" || w === "admin") want.push("admin");
            else if (w) want.push(w);   // let the database refuse it by name
          });

          if (want.indexOf("admin") !== -1 && current.indexOf("admin") === -1) {
            if (!window.confirm(
                  "Make " + person.email + " a full administrator?\n\n" +
                  "They will see every payment and every record, and be able to " +
                  "change what anybody else can do.")) return;
          }

          Array.prototype.forEach.call(row.querySelectorAll("button"), function (b) { b.disabled = true; });
          sb.rpc("set_person_roles", { p_user: id, p_roles: want }).then(function (res) {
            if (res.error) throw res.error;
            say("acc-ok", "Updated what " + person.email + " can do.");
            return load();
          }).catch(function (err) {
            say("acc-error", err.message || "That did not work.", true);
            return load();
          });
        }
      });
    }

    // Older browsers, and any page where the clipboard API is refused.
    function pick(text, done) {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed"; ta.style.left = "-9999px";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); done(); } catch (e) { /* leave it on screen */ }
      document.body.removeChild(ta);
    }

    return {
      mount: function (identity) {
        var panel = el("acc-panel"), noaccess = el("app-noaccess");
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
    try { access.mount(identity); } catch (e) {
      if (window.console) console.warn("access panel unavailable:", e);
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
