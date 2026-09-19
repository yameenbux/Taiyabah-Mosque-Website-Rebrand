/* ===========================================================================
   THE ARCHIVE.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   18 September 2026

   WHAT THE MASJID ASKED FOR:

       "when removing any record from the madrasah database it should get
        archived, where someone is able to go into the archive and restore if
        needed, you keep that record for same amount as a pupil."

   NOTHING ON THE MADRASAH SIDE IS DELETED BY A BUTTON. Remove a teacher, a
   child or a class and the whole record - the row itself, plus the classes
   they were linked to - is copied into madrasah_archive and taken off the
   list. This screen is the other half of that: it is where a record that was
   removed in error is found and put back.

   WHY AN ARCHIVE AND NOT A "DELETED" TICK BOX.

   The obvious alternative is a flag on the row - is_deleted, or left_on with
   a special meaning - and it is worse in two ways that matter here. Every
   query in the system then has to remember to exclude the flagged rows, and
   the day one of them forgets, a child somebody removed is back on a register
   with no warning. And the retention clock has nowhere to live: a row that
   stays in madrasah_pupils forever is a row nobody ever purges. Moving the
   record OUT means the ordinary queries cannot see it by accident and the
   purge has one table to look at.

   THREE YEARS, WHICH IS WHAT A PUPIL RECORD GETS. Asked for in those words,
   and it is the right answer: an archived pupil record IS a pupil record, and
   giving it a different clock because of which table it sits in would be a
   retention policy decided by a database detail. purge_madrasah_archive() in
   db/064 does the deleting; this screen only ever reports what that function
   will do, using the same arithmetic, so the two cannot drift apart.

   THE ONE IRREVERSIBLE CONTROL IN THE MADRASAH IS ON THIS SCREEN.
   "Delete for good" is how an erasure request is answered, and it does what
   it says. See the note above ask() for why it is not a Yes button like every
   other question in this portal.
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
     THE ARCHIVE
     ======================================================================= */
  var archive = (function () {

    var ROWS  = [];
    var query = "", kind = "all";
    var wired = false;
    var want  = null;    // { row: <the archived record>, verb: "restore" | "delete" }

    var KIND = {
      staff: { word: "Member of staff", where: "the staff list" },
      pupil: { word: "Child",           where: "the register" },
      class: { word: "Class",           where: "the class list" }
    };

    function list(v) { return Array.isArray(v) ? v : []; }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function trim(v) { return String(v == null ? "" : v).trim(); }

    function note(id, msg) {
      var box = el(id);
      if (!box) return;
      box.textContent = msg || "";
      box.hidden = !msg;
    }

    /*  A DATE SOMEBODY CAN READ, and the time with it.

        The time matters here in a way it does not on a pupil record: two
        things archived four minutes apart on the same afternoon are almost
        always the same mistake, and a list that shows both as "18 September
        2026" hides the one fact that says so. */
    var MON = ["January","February","March","April","May","June","July",
               "August","September","October","November","December"];

    function fmtDate(iso) {
      if (!iso) return "";
      var p = String(iso).slice(0, 10).split("-");
      if (p.length !== 3) return String(iso);
      return Number(p[2]) + " " + MON[Number(p[1]) - 1] + " " + p[0];
    }

    function fmtWhen(iso) {
      if (!iso) return "";
      var d = new Date(iso);
      if (isNaN(d.getTime())) return fmtDate(iso);
      var hh = String(d.getHours()).padStart(2, "0");
      var mm = String(d.getMinutes()).padStart(2, "0");
      return d.getDate() + " " + MON[d.getMonth()] + " " + d.getFullYear() +
             ", " + hh + ":" + mm;
    }

    /*  HOW LONG IS LEFT, IN THE UNIT SOMEBODY THINKS IN.

        days_left comes from the database — the same arithmetic the purge
        itself uses, so the screen cannot drift from what actually happens.
        1,094 days is a true number and an unreadable one; "just under 3 years"
        is what a person needs in order to decide whether to hurry. Under a
        month it goes back to days, because that is the point at which the
        exact number starts to matter. */
    function timeLeft(days) {
      var n = Number(days);
      if (!isFinite(n) || n <= 0) return { word: "Due to be deleted", soon: true };
      if (n <= 31) {
        return { word: n === 1 ? "1 day left" : n + " days left", soon: true };
      }
      if (n < 365) {
        var m = Math.round(n / 30.4);
        return { word: (m === 1 ? "about 1 month" : "about " + m + " months") + " left",
                 soon: n <= 90 };
      }
      var y = n / 365.25;
      return { word: "about " + (y >= 2.9 ? "3 years"
                                : y >= 1.9 ? "2 years"
                                : y >= 1.4 ? "18 months" : "1 year") + " left",
               soon: false };
    }

    function load() {
      return sb.rpc("madrasah_archive_list").then(function (res) {
        if (res.error) {
          if (/does not exist|schema cache|function/i.test(res.error.message || "")) {
            throw new Error("The archive needs 063 and 064, which haven't been run yet.");
          }
          throw new Error(res.error.message);
        }
        ROWS = list(res.data);
        draw();
      });
    }

    function visible() {
      var q = query.toLowerCase();
      return ROWS.filter(function (r) {
        if (kind !== "all" && trim(r.kind) !== kind) return false;
        if (!q) return true;
        return (trim(r.label) + " " + trim(r.reason) + " " + trim(r.by))
                 .toLowerCase().indexOf(q) !== -1;
      });
    }

    /*  ONE ROW.

        The kind is a word and not a colour, because "Child" and "Class" are
        four letters apart and a tinted edge is the wrong way to tell a person
        from a timetable.

        THE ROW IS NOT A BUTTON. Every other list in this portal opens
        something when you press it; this one has two verbs and one of them
        cannot be undone, so there is nothing to press by accident. The verbs
        are buttons and the row is not. */
    function rowHtml(r) {
      var k    = KIND[trim(r.kind)] || { word: trim(r.kind) || "Record", where: "the madrasah" };
      var left = timeLeft(r.days_left);
      var can  = r.can_restore !== false;

      return '<div class="ar-row" data-id="' + esc(r.id) + '">' +
        '<div class="ar-what">' +
          '<span class="ar-kind k-' + esc(trim(r.kind)) + '">' + esc(k.word) + "</span>" +
          '<span class="ar-label">' + esc(r.label || "(no name recorded)") + "</span>" +
        "</div>" +

        '<div class="ar-facts">' +
          "<span>Archived " + esc(fmtWhen(r.archived_at)) +
            (trim(r.by) ? " by " + esc(r.by) : "") + "</span>" +
          (trim(r.reason) ? '<span class="ar-why">&ldquo;' + esc(r.reason) + "&rdquo;</span>" : "") +
          '<span class="ar-left' + (left.soon ? " soon" : "") + '">' +
            esc(left.word) + " &middot; deleted on " + esc(fmtDate(r.purges_on)) +
          "</span>" +
        "</div>" +

        '<div class="ar-acts">' +
          (can
            ? '<button type="button" class="btn btn-gold ar-mini" data-do="restore" ' +
              'data-id="' + esc(r.id) + '">Put back</button>'
            : '<span class="ar-cannot">Already back on ' + esc(k.where) + "</span>") +
          '<button type="button" class="btn btn-ghost ar-mini ar-danger" data-do="delete" ' +
          'data-id="' + esc(r.id) + '">Delete for good</button>' +
        "</div>" +
      "</div>";
    }

    function draw() {
      var host = el("ar-list");
      if (!host) return;
      var rows = visible();

      var sum = el("ar-sum");
      if (sum) {
        var n = ROWS.length;
        sum.textContent = n === 0
          ? "Nothing has been archived."
          : (rows.length === n
              ? (n === 1 ? "One record in the archive."
                         : n + " records in the archive.")
              : rows.length + " of " + n + " records.");
      }

      if (!ROWS.length) {
        host.innerHTML = '<div class="ar-empty">' +
          "<p><strong>The archive is empty.</strong></p>" +
          "<p>Nothing has been removed from the madrasah. When somebody does " +
          "remove a member of staff, a child or a class, the record comes here " +
          "rather than being deleted, and can be put back from this screen.</p>" +
          "</div>";
        return;
      }
      if (!rows.length) {
        host.innerHTML = '<div class="ar-empty"><p>Nothing in the archive matches that.</p></div>';
        return;
      }
      host.innerHTML = rows.map(rowHtml).join("");
    }

    function byId(id) {
      for (var i = 0; i < ROWS.length; i++) {
        if (String(ROWS[i].id) === String(id)) return ROWS[i];
      }
      return null;
    }

    // ---- the question --------------------------------------------------
    function hideConfirm() {
      want = null;
      var box = el("ar-confirm");
      if (box) box.hidden = true;
      var tick = el("ar-understand");
      if (tick) tick.checked = false;
      var yes = el("ar-yes");
      if (yes) yes.disabled = false;
    }

    /*  TWO VERBS, TWO QUESTIONS, AND THEY DO NOT LOOK THE SAME.

        Putting a record back is reversible: archive it again and you are where
        you started. Deleting for good is not, and it is the button that
        answers an erasure request, so it is the one thing on this whole system
        that genuinely destroys a record.

        A confirm strip with a Yes button is the right weight for the first and
        the wrong weight for the second — a person who has pressed Yes on six
        restores does not read the seventh. So the delete question carries a
        tick box that has to be ticked before Yes will work at all. That is not
        friction for its own sake: it is one deliberate act that cannot be
        performed by muscle memory, on the only control here that cannot be
        undone. */
    function ask(verb, r) {
      want = { row: r, verb: verb };
      var k = KIND[trim(r.kind)] || { word: "record", where: "the madrasah" };
      var q = el("ar-confirm-q");
      var box = el("ar-confirm");
      var tickWrap = el("ar-understand-wrap");
      var yes = el("ar-yes");

      if (verb === "restore") {
        q.textContent = "Put " + (r.label || "this record") + " back on " + k.where +
          "? Anything that still exists is re-linked — a teacher comes back with " +
          "the classes that are still there. This can be undone by removing them " +
          "again.";
        if (tickWrap) tickWrap.hidden = true;
        if (yes) { yes.textContent = "Yes, put them back"; yes.disabled = false; }
        box.className = "ar-confirm";
      } else {
        q.textContent = "Delete " + (r.label || "this record") + " for good? " +
          "This is the one thing on this system that cannot be undone. The record " +
          "is destroyed, not hidden, and it cannot be put back afterwards. It " +
          "would be deleted on its own on " + fmtDate(r.purges_on) + " in any case.";
        if (tickWrap) tickWrap.hidden = false;
        if (yes) { yes.textContent = "Delete for good"; yes.disabled = true; }
        box.className = "ar-confirm ar-confirm-hard";
      }
      box.hidden = false;
      box.scrollIntoView({ block: "nearest" });
    }

    function act() {
      if (!want) return;
      var r = want.row, verb = want.verb;
      var btn = el("ar-yes");
      var label = btn ? btn.textContent : "";

      //  The tick is checked HERE as well as by disabling the button. A
      //  disabled button is a courtesy; it is one line of script away from not
      //  being disabled, and this is the irreversible one.
      if (verb === "delete") {
        var tick = el("ar-understand");
        if (!tick || !tick.checked) return;
      }

      busy(btn, true, label);
      note("ar-error", ""); note("ar-ok", "");

      var who = r.label || "That record";
      sb.rpc(verb === "restore" ? "restore_madrasah_record" : "delete_archived_record",
             { p_id: r.id })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          hideConfirm();
          return load().then(function () {
            note("ar-ok", verb === "restore"
              ? who + " is back on " +
                ((KIND[trim(r.kind)] || {}).where || "the madrasah") + "."
              : who + " has been deleted. There is nothing left to put back.");
          });
        })
        .catch(function (e) {
          note("ar-error", (verb === "restore"
            ? "Nothing was put back — "
            : "Nothing was deleted — ") + ((e && e.message) || String(e)));
        })
        .finally(function () { busy(btn, false, label); });
    }

    function wire() {
      if (wired) return;
      wired = true;

      var find = el("ar-find");
      if (find) find.addEventListener("input", function () {
        query = this.value || "";
        hideConfirm();
        draw();
      });

      var pick = el("ar-kind");
      if (pick) pick.addEventListener("change", function () {
        kind = this.value || "all";
        hideConfirm();
        draw();
      });

      /*  ONE LISTENER ON THE HOST. The rows are redrawn every time anything is
          typed, so per-row listeners would be re-attached on each keystroke
          and the old ones left behind. */
      var host = el("ar-list");
      if (host) host.addEventListener("click", function (ev) {
        var btn = ev.target.closest ? ev.target.closest("button[data-do]") : null;
        if (!btn) return;
        var r = byId(btn.getAttribute("data-id"));
        if (!r) return;
        note("ar-error", ""); note("ar-ok", "");
        ask(btn.getAttribute("data-do"), r);
      });

      var tick = el("ar-understand");
      if (tick) tick.addEventListener("change", function () {
        var yes = el("ar-yes");
        if (yes && want && want.verb === "delete") yes.disabled = !this.checked;
      });

      var yes = el("ar-yes");
      if (yes) yes.addEventListener("click", act);
      var no = el("ar-no");
      if (no) no.addEventListener("click", hideConfirm);
    }

    function mount(identity) {
      var panel = el("ar-panel");
      var noaccess = el("app-noaccess");
      if (!panel) return;

      /*  ADMINISTRATORS ONLY, AND NOT EVERY MADRASAH ACCOUNT.
          Every function behind this screen calls verified_admin() and refuses
          anybody else, so this is a courtesy rather than the control. But it
          is the right courtesy: the archive holds children's names alongside a
          button that destroys records, and a teacher has no business on it. */
      var roles = identity.roles || [];
      if (roles.indexOf("admin") === -1) {
        panel.hidden = true;
        if (noaccess) noaccess.hidden = false;
        return;
      }
      if (noaccess) noaccess.hidden = true;
      panel.hidden = false;
      hideConfirm();
      wire();
      load().catch(function (e) {
        note("ar-error", "The archive could not be read — " + ((e && e.message) || String(e)));
        var host = el("ar-list");
        if (host) host.textContent = "";
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
        current:  'md-archive',
        title:    'Archive',
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
    try { archive.mount(identity); } catch (e) {
      if (window.console) console.warn("archive panel unavailable:", e);
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
