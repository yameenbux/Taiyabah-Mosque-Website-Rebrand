/* ===========================================================================
   Taiyabah Masjid — Questions for the imams
   Bolton Central Islamic Society · Registered charity 1041569
   2 October 2026

   WHY THIS EXISTS
   ---------------
   The masjid asked for a form on the app's Imams' Advice screen so somebody
   can put a question to the imams in confidence, and the imam can answer it
   himself. db/132 stores the question. THIS PAGE IS THE OTHER HALF OF THAT
   JOB, and it is the half this repository has forgotten twice before — the
   course sign-ups in September and Gift Aid the same week, both of which
   collected people's details for weeks with no screen that could read them
   back. A form whose answers nobody can read is worse here than in either of
   those cases, because the person writing it has been told an imam will
   answer.

   WHO CAN OPEN IT
   ---------------
   An account holding the `imam` role, at aal2, AND NOBODY ELSE — not the
   office, not an administrator. verified_imam() in db/132 is the only gate in
   the whole schema that excludes `admin`, and that omission is the feature
   rather than an oversight. canSee() below tests the same one role, because a
   row that appears and then refuses you is worse than no row.

   This page only decides what to DRAW. Every function it calls checks again in
   Postgres and answers {allowed:false} to anybody else, so nothing here is a
   permission.

   THE LIST SAYS WHETHER, THE RECORD SAYS WHAT
   -------------------------------------------
   imam_advice_list() returns the reference, the subject and the state. It does
   NOT return the person's name, their number, their address or a word of what
   they wrote — those arrive only from imam_advice_read(), one request at a
   time, and that call writes an audit row saying somebody looked. So this
   screen can sit open on a desk without the congregation's private questions
   on it, which is the same rule the madrasah's list screens follow and matters
   more here than anywhere.

   NO SEARCH BOX AND NO TABS, deliberately. Both exist on the other staff
   screens because those lists run to hundreds of rows. A search box over
   people's private questions is a tool for finding one particular person's,
   and nobody opening this page has a reason to want that. There are never
   many; the oldest unanswered one is the only thing that matters, so it sorts
   to the top.

   "SENT" IS NOT SAID ANYWHERE
   ---------------------------
   imam_advice_answer() hands the reply to the notify function and returns
   `emailed: true` when it has done so. That means HANDED OVER, not delivered,
   and this screen says exactly that. Accepted is not delivered — telling an
   imam his answer has reached somebody when all that happened was a queued
   HTTP request is how a person in distress ends up never hearing back and
   nobody knowing.
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
     THE INBOX
     ======================================================================= */
  var advice = (function () {
    var rows = [];
    var open = null;          // the request being read, or null for the list
    var mounted = false;

    var MAX = 4000;           // imam_advice_answer() refuses more than this

    /*  ONE ROLE, AND NOT is_admin(). If you are about to add "admin" here
        because an administrator complained they could not see this screen,
        read the head of db/132 first: the database will refuse them anyway,
        so all you would achieve is a row that loads and then says no. */
    function canSee(identity) {
      return (identity.roles || []).indexOf("imam") !== -1;
    }

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/[&<>"']/g, function (c) {
          return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;",
                    '"': "&quot;", "'": "&#39;" })[c];
        });
    }

    var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

    /*  HOW LONG SOMEBODY HAS BEEN WAITING, in the words a person would use.
        "18 days ago" is the whole point of this column: a date tells you when
        it arrived, and only arithmetic tells you that somebody has been
        waiting almost three weeks. */
    function when(iso) {
      if (!iso) return "";
      var d = new Date(iso);
      if (isNaN(d)) return "";
      var days = Math.floor((Date.now() - d.getTime()) / 86400000);
      if (days <= 0) return "today";
      if (days === 1) return "yesterday";
      if (days < 31) return days + " days ago";
      return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear();
    }

    function fullWhen(iso) {
      if (!iso) return "";
      var d = new Date(iso);
      if (isNaN(d)) return "";
      return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear() + ", " +
             ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
    }

    function say(msg) {
      var box = el("adv-error");
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    /*  THE REFUSAL EVERY FUNCTION HERE CAN GIVE.

        {allowed:false} covers four different things on purpose (db/104): not
        an imam, not at aal2, somebody else's masjid, and a request that is not
        there. It is one answer so that it cannot be used to find out which.
        That makes it ambiguous for the person reading this screen too, so the
        sentence names the likely cause and the fix rather than repeating
        "not allowed". */
    function refused() {
      say("This account cannot open the imams' questions. If you have just been " +
          "given the role, sign out and back in — and the second step is required, " +
          "so finish that first. If it still refuses, ask the masjid administrator " +
          "to check your account.");
      el("adv-list").innerHTML = "";
      el("adv-one").hidden = true;
      el("adv-one").innerHTML = "";
    }

    // --- the list -----------------------------------------------------------
    function load() {
      say("");
      el("adv-list").innerHTML = '<p class="adv-empty">Loading…</p>';
      return sb.rpc("imam_advice_list").then(function (res) {
        if (res.error) throw res.error;
        var d = res.data || {};
        if (d.allowed === false) { refused(); return; }
        rows = d.requests || [];
        drawRetain();
        drawList();
      }).catch(function (err) {
        el("adv-list").innerHTML = "";
        say("Couldn't load the questions. " + (err.message || "Please try again."));
      });
    }

    function drawRetain() {
      var box = el("adv-retain");
      if (!box) return;
      box.innerHTML =
        "A question is deleted twelve months after the last thing happened on it, " +
        "and its answers go with it. <strong>If somebody needs to be able to come " +
        "back to this in a year, tell them to keep your reply</strong> — it will not " +
        "be here.";
    }

    function drawList() {
      el("adv-one").hidden = true;
      el("adv-one").innerHTML = "";
      var box = el("adv-list");
      box.hidden = false;

      if (!rows.length) {
        box.innerHTML = '<p class="adv-empty">Nothing is waiting. When somebody sends a ' +
                        'question from the app it appears here, and you are emailed to say so.</p>';
        return;
      }

      var waiting = 0;
      var i;
      for (i = 0; i < rows.length; i++) { if (rows[i].state === "open") waiting++; }

      var head = waiting
        ? "<p class=\"adv-lead\"><strong>" + waiting +
          (waiting === 1 ? " question is" : " questions are") +
          " waiting for an answer.</strong> The oldest is at the top.</p>"
        : "<p class=\"adv-lead\">Everything here has been answered.</p>";

      var html = head;
      for (i = 0; i < rows.length; i++) {
        var r = rows[i];
        var state = r.state === "open" ? "open" : (r.state === "answered" ? "answered" : "");
        html +=
          '<button type="button" class="adv-row' + (r.unread ? " unread" : "") +
            '" data-id="' + esc(r.id) + '">' +
            '<span class="adv-top">' +
              '<span class="adv-subj">' + esc(r.subject) + '</span>' +
              '<span class="adv-state ' + state + '">' +
                (r.state === "open" ? "waiting" : esc(r.state)) + '</span>' +
            '</span>' +
            '<span class="adv-top">' +
              '<span class="adv-ref">' + esc(r.reference) + '</span>' +
              '<span class="adv-when">came in ' + esc(when(r.submitted_at)) + '</span>' +
              (Number(r.answers) > 0
                ? '<span class="adv-when">' + Number(r.answers) +
                  (Number(r.answers) === 1 ? ' reply sent' : ' replies sent') + '</span>'
                : '') +
            '</span>' +
          '</button>';
      }
      box.innerHTML = html;

      /*  SORTING IS THE DATABASE'S, not this page's. imam_advice_list() orders
          open first then by last activity, and imam_advice_waiting_count()
          counts from the same definition of "open". Re-sorting here would give
          two places that can disagree about which is oldest. */
    }

    // --- one request --------------------------------------------------------
    function openOne(id) {
      say("");
      el("adv-list").hidden = true;
      var box = el("adv-one");
      box.hidden = false;
      box.innerHTML = '<p class="adv-empty">Opening…</p>';

      sb.rpc("imam_advice_read", { p_request: id }).then(function (res) {
        if (res.error) throw res.error;
        var d = res.data || {};
        if (d.allowed === false) { el("adv-list").hidden = false; refused(); return; }
        open = d;
        drawOne(d, null);
      }).catch(function (err) {
        box.hidden = true;
        el("adv-list").hidden = false;
        say("Couldn't open that question. " + (err.message || "Please try again."));
      });
    }

    function drawOne(d, note) {
      var box = el("adv-one");
      var tel = String(d.phone || "").replace(/\s/g, "");
      var html =
        '<button type="button" class="adv-back" id="adv-back">&larr; All questions</button>' +
        '<div class="adv-top">' +
          '<span class="adv-subj">' + esc(d.subject) + '</span>' +
          '<span class="adv-state ' + (d.state === "open" ? "open" : "answered") + '">' +
            (d.state === "open" ? "waiting" : esc(d.state)) + '</span>' +
        '</div>' +
        '<p class="adv-when">' + esc(d.reference) + ' &middot; came in ' +
          esc(fullWhen(d.submitted_at)) + ' (' + esc(when(d.submitted_at)) + ')</p>' +

        /*  THE PHONE NUMBER IS A LINK AND IT IS FIRST.
            The masjid required a number on the form for a reason: some of what
            arrives here should be answered by ringing somebody rather than by
            writing to them, and an imam who has to copy a number out by hand
            will write instead. */
        '<div class="adv-who">' +
          '<span>' + esc(d.name) + '</span>' +
          (tel ? '<a href="tel:' + esc(tel) + '">' + esc(d.phone) + '</a>' : '') +
          (d.email ? '<a href="mailto:' + esc(d.email) + '">' + esc(d.email) + '</a>' : '') +
        '</div>' +

        '<div class="adv-q">' + esc(d.question) + '</div>';

      var answers = d.answers || [];
      var i;
      for (i = 0; i < answers.length; i++) {
        html += '<div class="adv-ans"><em>You replied ' +
                esc(fullWhen(answers[i].created_at)) + '</em>' +
                esc(answers[i].body) + '</div>';
      }

      html +=
        '<div class="adv-write">' +
          '<label for="adv-body">' +
            (answers.length ? "Write again" : "Your answer") +
          '</label>' +
          '<textarea id="adv-body" maxlength="' + MAX + '" placeholder="Assalamu alaikum…"></textarea>' +
          '<p class="adv-count" id="adv-count"></p>' +
          '<div class="adv-acts">' +
            '<button type="button" class="btn btn-gold" id="adv-send">Send this answer</button>' +
            (d.state === "closed"
              ? ''
              : '<button type="button" class="btn btn-ghost" id="adv-close">Nothing more to say</button>') +
          '</div>' +
          /*  WHAT PRESSING THE BUTTON ACTUALLY DOES, before it is pressed.
              Including the one thing an imam would not guess: the reply goes
              out under the masjid's address and the person cannot write back
              to it. */
          '<p class="adv-lead" style="margin-top:11px">What you write is emailed to ' +
            esc(d.name) + ' at the address they gave, from the masjid&rsquo;s own address. ' +
            'They <strong>cannot reply to it</strong> &mdash; the email tells them to send ' +
            'another question from the app quoting ' + esc(d.reference) + ', or to ring the ' +
            'office. Your name is not in the email. It is saved here as well, so you can see ' +
            'what you said.</p>' +
        '</div>';

      if (note) html += '<div class="adv-sent">' + note + '</div>';

      box.innerHTML = html;

      el("adv-back").addEventListener("click", function () {
        open = null;
        el("adv-list").hidden = false;
        load();
      });

      var body  = el("adv-body");
      var count = el("adv-count");
      function tally() {
        var n = body.value.length;
        count.textContent = n + " of " + MAX + " characters";
        count.className = n >= MAX ? "adv-count over" : "adv-count";
      }
      body.addEventListener("input", tally);
      tally();

      el("adv-send").addEventListener("click", function () { send(d, this); });
      var closeBtn = el("adv-close");
      if (closeBtn) closeBtn.addEventListener("click", function () { shut(d, this); });
    }

    function send(d, btn) {
      var body = el("adv-body");
      var text = body.value.replace(/^\s+|\s+$/g, "");
      if (!text) {
        say("There is nothing to send — write your answer first.");
        body.focus();
        return;
      }
      say("");
      btn.disabled = true;
      btn.textContent = "Sending…";

      sb.rpc("imam_advice_answer", { p_request: d.id, p_body: text })
        .then(function (res) {
          if (res.error) throw res.error;
          var out = res.data || {};
          if (out.allowed === false) { refused(); return; }

          /*  "HANDED TO THE MAIL SERVER", NOT "SENT". `emailed` means the post
              to the notify function was queued; nothing here has seen a
              delivery. Saying "sent" would be the difference between an imam
              who follows up and an imam who thinks he already has. */
          var note = out.emailed
            ? "<strong>Saved, and handed to the mail server.</strong> It should reach " +
              esc(d.name) + " within a few minutes. Nothing here can confirm it arrived, " +
              "so if this was urgent, ring them as well."
            : "<strong>Saved, but it has not been emailed.</strong> " +
              esc(out.note || "Email is not set up on this site just now.") +
              " Please ring them.";

          //  Re-read rather than patch what is on screen, so the reply and the
          //  state shown are the database's answer and not this page's guess.
          sb.rpc("imam_advice_read", { p_request: d.id }).then(function (r2) {
            if (r2.error || !r2.data || r2.data.allowed === false) { load(); return; }
            open = r2.data;
            drawOne(r2.data, note);
          });
        })
        .catch(function (err) {
          btn.disabled = false;
          btn.textContent = "Send this answer";
          //  The database speaks to the imam directly about an answer that is
          //  empty or too long, so where it does, say what it said.
          var msg = err && err.message && /^[A-Z]/.test(err.message)
            ? err.message
            : "That didn't send. Please try again.";
          say(msg);
        });
    }

    function shut(d, btn) {
      /*  NO CONFIRMATION DIALOG, because this is not destructive and it is not
          final: answering again reopens the conversation as answered. The
          button says what it means — "nothing more to say" — rather than
          "close", which sounds like it throws something away. */
      say("");
      btn.disabled = true;
      btn.textContent = "Please wait…";
      sb.rpc("imam_advice_close", { p_request: d.id }).then(function (res) {
        if (res.error) throw res.error;
        if ((res.data || {}).allowed === false) { refused(); return; }
        open = null;
        el("adv-list").hidden = false;
        load();
      }).catch(function (err) {
        btn.disabled = false;
        btn.textContent = "Nothing more to say";
        say("Couldn't do that. " + (err.message || "Please try again."));
      });
    }

    function wire() {
      if (mounted) return;
      mounted = true;
      //  One listener on the container rather than one per row, because the
      //  rows are redrawn after every change and per-row listeners would
      //  either leak or quietly stop working.
      el("adv-list").addEventListener("click", function (e) {
        var row = e.target;
        while (row && row !== this && !(row.className && String(row.className).indexOf("adv-row") !== -1)) {
          row = row.parentNode;
        }
        if (!row || row === this) return;
        var id = row.getAttribute("data-id");
        if (id) openOne(id);
      });
    }

    return {
      mount: function (identity) {
        var panel    = el("adv-panel");
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
        current: 'advice',
        title:   'Questions for the imams',
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
    try { advice.mount(identity); } catch (e) {
      if (window.console) console.warn("advice panel unavailable:", e);
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
