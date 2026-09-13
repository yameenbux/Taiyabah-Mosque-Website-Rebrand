/* ===========================================================================
   Taiyabah Masjid — Madrasah, the administrators' view
   Bolton Central Islamic Society · Registered charity 1041569

   WHAT THIS REPLACED
   ------------------
   /portal/ was live and broken. Its index.html was the madrasah sign-in page;
   its app.js was a copy of the admin-centre signpost, which looks for elements
   called `no-signout` and `list-signout` that this page has never had. So it
   threw `Cannot read properties of null (reading 'addEventListener')` on every
   load and rendered nothing past the spinner. Nobody reported it, because
   nobody had a reason to open it yet.

   The sign-in, two-step and enrolment flow below is the one from /access/,
   unchanged — same shell, same views, same ids. That is deliberate: a second
   hand-written copy of an authentication flow is a second place for it to be
   wrong, and this project has already lost a portal to exactly that.

   WHAT THIS PAGE DOES NOT DO
   --------------------------
   It holds no pupil record and reads none. There is nothing to read: the
   database has no madrasah tables yet, and must not have until the work listed
   on the page itself is finished. A madrasah roll is Article 9 data.

   The teachers' and parents' views are not built. A teacher signing in here
   is told so rather than being shown an administrator's console.
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
     THE MADRASAH, AS AN ADMINISTRATOR SEES IT

     Modelled on the shape of the system the masjid uses today — four headline
     counts, then the areas — so that whoever has to switch recognises where
     they are. Not modelled on its contents: this database holds no pupil
     record, and will not until the work listed on the page is done.

     THE FOUR FIGURES ARE NOT THIS SYSTEM'S. They are what the current system
     holds, typed in below, and the page says so twice: once in the panel above
     them and once on every tile. That is not excessive. A number on the screen
     an administrator lands on becomes a number reported to the committee, and
     "539 pupils" would be true of the masjid and false of this database.

     NOTHING IS CLICKABLE, deliberately, and the tiles are DIVs rather than
     dead buttons. A control that looks pressable and does nothing teaches
     people the page is broken, and then they stop reporting when it really is.
     ======================================================================= */
  var madrasah = (function () {

    /* Typed in, in one place, with the date they were read. When the import
       happens this whole object goes and the counts come from the database —
       which is why every figure the page draws goes through here rather than
       being written into the HTML. */
    var CURRENT = {
      as_at: "13 September 2026",
      where: "the madrasah\u2019s current system",
      counts: [
        { n: 539, k: "Students",
          s: "Every child on the roll. The most sensitive thing the masjid holds." },
        { n: 39,  k: "Teachers",
          s: "Who teaches, and which classes they are responsible for." },
        { n: 43,  k: "Classes",
          s: "Groups, times and which teacher takes each one." },
        { n: 962, k: "Contacts",
          s: "Parents and guardians — who to ring, and who may collect." }
      ]
    };

    /* What each area is FOR, in the words somebody in the office would use.
       Written now rather than when it is built: the description is the brief,
       and a brief written after the screen is a description. */
    var AREAS = [
      { t: "Students",
        d: "The roll. Which class each child is in, who brings them, what the " +
           "masjid has been told about medical needs, and who may collect them." },
      { t: "Teachers",
        d: "Who teaches, what they take, and — the part the current system " +
           "tracks and this one does not yet — whether their DBS is in date." },
      { t: "Classes",
        d: "Groups and times, how full each one is, and which teacher is " +
           "responsible for it on any given day." },
      { t: "Contacts",
        d: "Parents and guardians, kept once and linked to their children, so " +
           "a changed phone number is changed in one place rather than four." }
    ];

    /* The gate, stated on the page it gates. The project's own record says the
       DPIA must be finished before the first real pupil record is entered, and
       that the first pupil record IS the next milestone. A list like this kept
       in a document gets read once. */
    var BEFORE = [
      { t: "Finish the DPIA",
        d: "A madrasah roll reveals religious belief. Article 9 data needs a " +
           "data protection impact assessment before it is processed, not after." },
      { t: "Register with the ICO",
        d: "Tier 1, about £52 a year. Processing this data without it is an " +
           "offence, and it is the cheapest item on this list by a long way." },
      { t: "Write down the lawful basis and the Article 9 condition",
        d: "Two separate things. Consent is rarely the right answer for a " +
           "school roll and is the hardest to withdraw cleanly." },
      { t: "Confirm the data can actually come out of the current system",
        d: "Nobody has yet confirmed the full dataset exports as CSV. If it " +
           "cannot, 539 records means re-keying by hand — and that is the " +
           "single biggest risk to this project, not the software." },
      { t: "Make two-step a database rule for pupil tables, not a page rule",
        d: "Today it is enforced in the browser. A determined person could " +
           "call the API without it. Pupil tables must require aal2 in their " +
           "own policies before they hold anything." },
      { t: "Agree a breach procedure with a 72-hour route to the ICO",
        d: "It needs to exist before it is needed, and somebody has to be " +
           "named in it." }
    ];

    /* Named so nothing is quietly forgotten at changeover. NOT a plan — some
       of this the masjid may not need, and copying the old system feature for
       feature is how you inherit somebody else's decisions. */
    var REST = [
      "Register", "Teacher logs", "Fees", "Events and trips", "Incidents",
      "Messages", "Newsletters and SMS", "Student diary", "Homework",
      "Exams and tests", "End-of-year reports", "Merits and achievements",
      "Products", "Settings"
    ];

    function canSee(identity) { return identity.roles.indexOf("admin") !== -1; }

    /* WHAT A TEACHER WILL BE ABLE TO DO.
       Written now, in the words somebody in a classroom would use, rather than
       when it is built — the list IS the brief, and a list written afterwards
       is a description. Anything the masjid needs that is missing here is
       cheaper to add today than after the screens exist. */
    var TEACHER = [
      { t: "Take the register",
        d: "Mark who is in, who is late and who is absent, from a phone, at the " +
           "start of the lesson rather than on paper to be typed up later." },
      { t: "Write up the lesson",
        d: "What was covered and how far the class got, so whoever takes them " +
           "next week is not starting from a guess." },
      { t: "Record how each child is getting on",
        d: "Sabaq, sabqi and manzil, merits and the things worth telling a " +
           "parent — kept against the child rather than in a notebook." },
      { t: "Set and see homework",
        d: "What was set, who has done it, and who needs chasing." },
      { t: "End-of-year reports",
        d: "Build the report from what is already recorded across the year " +
           "instead of writing it from memory in one weekend." },
      { t: "Message a parent",
        d: "Through the masjid, so the conversation is on the record and " +
           "nobody has to give out a personal number." },
      { t: "See your classes and times",
        d: "Who is in your group, when you are on, and who is covering." },
      { t: "Raise a concern",
        d: "An incident or a safeguarding worry, logged properly and sent " +
           "straight to the people who must see it." }
    ];

    /* WHAT A PARENT WILL BE ABLE TO DO. Deliberately starts with the two
       things families actually ring the office about — fees and absence —
       rather than with the reports, which is what a school system would put
       first. */
    var PARENT = [
      { t: "Pay the fees",
        d: "Online, at any hour, with a receipt — instead of finding cash and " +
           "catching somebody at the office between 5 and 7." },
      { t: "Tell the masjid your child is absent",
        d: "Before the lesson, in a few seconds, so the teacher is not ringing " +
           "round to find out." },
      { t: "See how your child is getting on",
        d: "What they are learning, how they are doing, and the end-of-year " +
           "report when it is ready." },
      { t: "Keep your details right",
        d: "A new phone number, a new address, a change of school — changed " +
           "once and right everywhere, rather than told to somebody and lost." },
      { t: "Say who may collect them",
        d: "Who is allowed to take your child home, and who is not. The masjid " +
           "keeps to what you put here." },
      { t: "Tell us about medical needs and allergies",
        d: "So the person in the room on the day knows, and it does not depend " +
           "on somebody remembering." },
      { t: "See homework and what was covered",
        d: "What was set and when it is due, so you can help." },
      { t: "Enrol another child",
        d: "Without filling the same form in again for a family the masjid " +
           "already knows." }
    ];

    function drawRoleList(id, items) {
      var box = el(id);
      if (!box) return;
      box.innerHTML = items.map(function (i) {
        return '<div class="rl-item">' +
          '<span class="rl-mark" aria-hidden="true">\u2713</span>' +
          "<span><b>" + esc(i.t) + "</b><span>" + esc(i.d) + "</span></span>" +
        "</div>";
      }).join("");
    }

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/[&<>"']/g, function (c) {
          return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;",
                    '"': "&quot;", "'": "&#39;" })[c];
        });
    }

    function draw() {
      var counts = el("md-counts");
      if (counts) {
        counts.innerHTML = CURRENT.counts.map(function (c) {
          return '<div class="md-count">' +
            '<span class="n">' + esc(c.n) + "</span>" +
            '<span class="k">' + esc(c.k) + "</span>" +
            //  On EVERY tile, not just in the panel above. Somebody screenshots
            //  one tile for a committee paper, and the caveat has to travel
            //  with the number.
            '<span class="s">' + esc(c.s) +
              "<br><b>In " + esc(CURRENT.where) + ", not imported.</b></span>" +
          "</div>";
        }).join("");
      }

      var areas = el("md-areas");
      if (areas) {
        areas.innerHTML = AREAS.map(function (a) {
          return '<div class="md-area">' +
            '<span class="t">' + esc(a.t) + "</span>" +
            '<span class="d">' + esc(a.d) + "</span>" +
            '<span class="w">Not open yet</span>' +
          "</div>";
        }).join("");
      }

      var before = el("md-before-list");
      if (before) {
        before.innerHTML = BEFORE.map(function (b) {
          return "<li><b>" + esc(b.t) + "</b><span>" + esc(b.d) + "</span></li>";
        }).join("");
      }

      var rest = el("md-rest");
      if (rest) {
        rest.innerHTML = REST.map(function (r) {
          return "<span>" + esc(r) + "</span>";
        }).join("");
      }

      var lead = el("md-lead");
      if (lead) {
        var when = document.createElement("div");
        when.style.cssText = "margin-top:8px;font-size:.79rem;color:var(--muted);";
        when.textContent = "Figures as at " + CURRENT.as_at + ".";
        lead.appendChild(when);
      }
    }

    return {
      mount: function (identity) {
        var panel = el("md-panel"), noaccess = el("app-noaccess");

        /* THREE PAGES BEHIND ONE DOOR. An administrator gets the console; a
           teacher and a parent each get a page about their own portal. Until
           today they got "your side has not been built" and a sign-out button,
           which is a true sentence and a useless screen.

           Admin is checked FIRST and on its own: somebody who is both an
           administrator and a teacher is here to administer. */
        var shown = null;
        if (canSee(identity)) {
          shown = panel;
        } else if (identity.roles.indexOf("teacher") !== -1) {
          shown = el("tc-panel");
          drawRoleList("tc-list", TEACHER);
        } else if (identity.roles.indexOf("parent") !== -1) {
          shown = el("pa-panel");
          drawRoleList("pa-list", PARENT);
        }

        if (!shown) {
          if (panel) panel.hidden = true;
          if (noaccess) noaccess.hidden = false;
          return;
        }
        if (noaccess) noaccess.hidden = true;
        shown.hidden = false;

        /* Full width, and the brand panel goes with it — the same rule as the
           staff screen. A form wants 420px; a dashboard does not. It happens
           here rather than in the markup so that somebody who never gets past
           the sign-in card keeps the two-column page. */
        var shell = document.querySelector(".shell");
        if (shell) shell.classList.add("wide-mode");

        var top = el("app-top");
        if (top) {
          top.hidden = false;
          el("app-top-email").textContent = identity.user.email;
          //  "Madrasah" is right for all three, but a teacher and a parent are
          //  looking at their own portal and should be told so.
          //  The admin centre refuses a teacher or a parent, so offering them
          //  a link to it is offering them a closed door. Theirs is a page
          //  with nowhere else to go, which is honest at this stage.
          var back = el("app-top-back");
          if (back) back.hidden = shown !== panel;

          var where = el("app-top-where");
          if (where) {
            where.textContent = shown === panel ? "Madrasah"
              : shown === el("tc-panel") ? "Madrasah \u2014 teachers"
              : "Madrasah \u2014 parents";
          }
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
              //  Back out of wide mode, or the sign-in card returns full width
              //  with no brand panel beside it and signing out visibly breaks
              //  the page you land on.
              var s = document.querySelector(".shell");
              if (s) s.classList.remove("wide-mode");
              el("signin-email").value = "";
              el("signin-password").value = "";
              setError("signin-error", "");
              show("view-signin");
            });
          });
        }

        //  Only the console has anything to draw; the two landing pages were
        //  filled in above, before the panel was shown.
        if (shown === panel) draw();
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
    try { madrasah.mount(identity); } catch (e) {
      if (window.console) console.warn("madrasah panel unavailable:", e);
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
