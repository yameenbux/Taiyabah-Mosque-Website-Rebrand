/* ===========================================================================
   gate.js — the sign-in shell, the rail, and the money helpers, shared by all
   seven Fees screens.

   WHY THIS FILE EXISTS WHEN NO OTHER SCREEN HAS ONE
   -------------------------------------------------
   Every other portal screen carries its own copy of the sign-in, two-step and
   identity flow — about five hundred lines, repeated. That was fine at two
   screens. At nine it is not, and the Fees section alone would have added
   seven more copies of a flow that decides who may see what a family owes.

   Seven copies of an auth flow is seven places to fix a bug in it, and the
   day one of them is missed is the day one screen lets somebody in with aal1.
   So the seven Fees screens share this file, and their own app.js holds only
   what that screen actually does.

   It changes nothing about the security model. The database refuses every
   fees function to anybody who is not a verified administrator; this file,
   like the rail, is a convenience that keeps people out of screens that would
   only show them error messages.

   MONEY IS HANDLED IN PENCE, EVERYWHERE, AND CONVERTED ONLY TO DISPLAY IT.
   pounds() is the only place a number becomes a string with a £ on it, and
   pence() is the only place a typed string becomes a number. Two conversions
   in one codebase is how a screen comes to disagree with a report.
   =========================================================================== */
(function () {
  "use strict";

  var el = function (id) { return document.getElementById(id); };

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

  /*  A LIST, OR AN EMPTY ONE — AND `|| []` IS NOT THAT CHECK.
      `{}` is truthy, so an answer of the wrong shape sails through `||` and
      throws on the next `.map()`. Copied from classes/app.js, where it was
      learned. */
  function list(v) { return Array.isArray(v) ? v : []; }

  /*  MONEY. Integer pence in, string out. Negative numbers are shown with the
      sign in front of the pound, not after it, because "-£12.50" reads as a
      debt and "£-12.50" reads as a typing mistake. */
  function pounds(p, opts) {
    var n = Number(p);
    if (!isFinite(n)) return "—";
    var neg = n < 0;
    var s = (Math.abs(n) / 100).toFixed(2);
    s = s.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    if (opts && opts.plain) return (neg ? "-" : "") + s;
    return (neg ? "-£" : "£") + s;
  }

  /*  £12.50, 12.50, 12, "£1,250.00" -> pence. Returns null for anything that
      is not a number, so a caller can tell "nothing typed" from "zero". */
  function pence(text) {
    var t = String(text == null ? "" : text).replace(/[£,\s]/g, "");
    if (t === "" || !/^-?\d+(\.\d{1,2})?$/.test(t)) return null;
    return Math.round(parseFloat(t) * 100);
  }

  function esc(s) {
    return String(s == null ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }

  function shortDate(d) {
    if (!d) return "—";
    var x = new Date(d);
    if (isNaN(x)) return String(d);
    return x.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
  }

  function daysAgo(d) {
    if (!d) return null;
    var x = new Date(d);
    if (isNaN(x)) return null;
    return Math.floor((Date.now() - x.getTime()) / 86400000);
  }

  function note(id, msg) {
    var box = el(id);
    if (!box) return;
    if (!msg) { box.hidden = true; box.textContent = ""; return; }
    box.textContent = msg;
    box.hidden = false;
  }

  /*  ONE CSV WRITER FOR THE WHOLE SECTION.

      There were already two in this repository — giftaid/app.js and
      collections/app.js — and they disagreed about the byte-order mark, which
      is the difference between a spreadsheet that opens with pound signs in
      it and one that opens with "Â£". This is the third place that needed
      one, so it is written once here.

      The BOM is not optional. Excel on Windows reads a CSV as the system
      codepage unless the file starts with one, and every family name in this
      masjid's list that carries an accent comes out wrong without it.

      The button that calls this says what it downloads rather than "Export",
      because these files carry families' names and what they owe, and that is
      a file somebody has to look after. */
  /*  A FAMILY NAME IS FREE TEXT, AND EXCEL RUNS IT.

      A cell beginning =, +, - or @ is a formula to a spreadsheet, so a family
      recorded as "=cmd|' /c calc'!A1" — or, far more likely, a name somebody
      typed a stray "=" in front of — executes when the office opens the
      download. It is the one way a file this screen produces can do something
      to the person who opens it, and these files are full of names by design.

      A leading apostrophe is the fix every spreadsheet understands: it forces
      the cell to text and is not displayed. The quoting below still applies. */
  function csvCell(v) {
    var t = String(v === null || v === undefined ? "" : v);
    if (/^[=+\-@\t\r]/.test(t)) t = "'" + t;
    return /[",\n\r]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t;
  }

  function downloadCsv(filename, head, rows) {
    var text = head.map(csvCell).join(",") + "\r\n"
             + rows.map(function (r) { return r.map(csvCell).join(","); }).join("\r\n");
    var blob = new Blob(["﻿" + text], { type: "text/csv;charset=utf-8;" });
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
  }

  /* =========================================================================
     THE GATE
     ======================================================================= */
  function start(screen) {
    var cfg = window.TAIYABAH_CONFIG || {};

    if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.indexOf("PASTE_") === 0) {
      show("view-signin");
      setError("signin-error",
        "This area isn't connected yet — config.js still has placeholder values in it.");
      var f0 = el("signin-form");
      if (f0) Array.prototype.forEach.call(f0.elements, function (i) { i.disabled = true; });
      return;
    }

    // The Supabase dashboard shows the project URL with /rest/v1/ on the end.
    // Pasting it verbatim has broken this twice, so normalise to the origin.
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
            roles: list(out[1].data).map(function (r) { return r.role; }),
            errors: errs
          };
        });
      });
    }

    function renderApp(identity) {
      //  Wait for the two deferred scripts, but only while the page is still
      //  being read. If Supabase ever answered faster than shell.js and
      //  nav.js, MadrasahNav would be missing and the rail would quietly fall
      //  back to the SITE list — Gift Aid and Hall Hire in a madrasah screen,
      //  with no error anywhere. A missing rail is obvious; a wrong one is not.
      if (document.readyState === "loading" &&
          !(window.AdminShell && window.MadrasahNav)) {
        document.addEventListener("DOMContentLoaded", function () {
          renderApp(identity);
        }, { once: true });
        return;
      }

      if (window.AdminShell) {
        AdminShell.mount({
          depth:    screen.depth,
          current:  screen.key,
          title:    screen.title,
          area:     'Madrasah',
          sections: (window.MadrasahNav || {}).SECTIONS,
          roles:    identity.roles || [],
          name:     (identity.profile && identity.profile.full_name) || "",
          email:    (identity.user && identity.user.email) || ""
        });
      }

      var who = el("app-name");
      if (who) who.textContent = (identity.profile && identity.profile.full_name) || "Signed in";
      var mail = el("app-email");
      if (mail) mail.textContent = (identity.user && identity.user.email) || "";

      var roles = el("app-roles");
      if (roles) {
        roles.innerHTML = list(identity.roles).map(function (r) {
          return '<span class="role-chip role-' + esc(r) + '">' + esc(r) + '</span>';
        }).join("");
      }

      //  loadIdentity() collects a per-table failure instead of throwing, so
      //  that one bad read does not blank the screen. Nothing showed them,
      //  which meant a failed user_roles read produced an empty role list and
      //  the refusal panel — telling an administrator they have no access
      //  when what actually happened is that a query failed.
      if (identity.errors && identity.errors.length) {
        note("app-error", "Some of your account could not be read — "
             + identity.errors.join("; ")
             + ". If this screen says you have no access, that is why.");
      }

      show("view-app");

      //  EVERY FEES SCREEN IS ADMINISTRATORS ONLY.
      //  The rail marks these rows ADMIN and the database refuses them to
      //  anybody else, but there is no reason to show a teacher a panel full
      //  of error messages and let them think it is broken. `needs: ADMIN` in
      //  nav.js and this test have to agree — admin_shell_test.py fails if
      //  they ever stop agreeing.
      var panel = el("fx-panel");
      var noacc = el("app-noaccess");
      if (list(identity.roles).indexOf("admin") === -1) {
        if (panel) panel.hidden = true;
        if (noacc) noacc.hidden = false;
        return;
      }
      if (noacc) noacc.hidden = true;
      if (panel) panel.hidden = false;

      //  A panel that fails to load must never take the sign-in shell with it.
      try {
        screen.mount(identity, sb, API);
      } catch (e) {
        if (window.console) console.warn(screen.key + " panel unavailable:", e);
        note("fx-error", "This screen could not start — " + ((e && e.message) || String(e)));
      }
    }

    function routeAfterPassword() {
      return sb.auth.mfa.getAuthenticatorAssuranceLevel().then(function (res) {
        if (res.error) throw new Error("Couldn't check two-step status: " + res.error.message);
        var data = res.data || {};
        if (data.nextLevel === "aal2" && data.nextLevel !== data.currentLevel) {
          return startChallenge();
        }
        return sb.auth.mfa.listFactors().then(function (l) {
          if (l.error) throw new Error("Couldn't list authenticators: " + l.error.message);
          var verified = ((l.data || {}).totp) || [];
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
        // Deliberately vague: confirming which half was wrong helps an
        // attacker enumerate valid masjid email addresses.
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
        setError("mfa-error", err.message ||
          "That code wasn't accepted. Codes expire after 30 seconds.");
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
          factorId: pending.factorId, challengeId: c.data.id,
          code: el("enrol-code").value.trim()
        });
      }).then(function (res) {
        if (res.error) throw res.error;
        return loadIdentity().then(renderApp);
      }).catch(function (err) {
        setError("enrol-error", err.message ||
          "That code wasn't accepted. Please try the next one.");
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

    sb.auth.getSession().then(function (res) {
      if (res.data && res.data.session) {
        return routeAfterPassword().catch(function () { show("view-signin"); });
      }
      show("view-signin");
    }).catch(function () { show("view-signin"); });

    ["mfa-code", "enrol-code"].forEach(function (id) {
      var n = el(id);
      if (n) n.addEventListener("input", function (e) {
        e.target.value = e.target.value.replace(/\D/g, "").slice(0, 6);
      });
    });

    /*  A FAMILY PICKER, SHARED, BECAUSE FIVE OF THE SEVEN SCREENS NEED ONE.

        It searches on reference OR name, because the office will have one or
        the other in front of them: a bank statement gives the reference, a
        parent on the telephone gives their surname. It shows the reference
        beside every name, because twelve children at this masjid share a name
        with another child and their families will too. */
    function familyPicker(opts) {
      var input   = el(opts.input);
      var results = el(opts.results);
      var chosen  = null;
      var timer   = null;

      function draw(rows) {
        if (!rows.length) {
          results.innerHTML = '<p class="fx-none">No family matches that. '
            + 'Check the spelling, or add the family on the Families screen.</p>';
          results.hidden = false;
          return;
        }
        results.innerHTML = rows.slice(0, 12).map(function (r) {
          return '<button type="button" class="fx-pick" data-id="' + esc(r.id) + '">'
               + '<span class="fx-pick-n">' + esc(r.name) + '</span>'
               + '<span class="fx-pick-r">' + esc(r.reference) + '</span>'
               + '</button>';
        }).join("");
        results.hidden = false;
        Array.prototype.forEach.call(results.querySelectorAll(".fx-pick"), function (b) {
          b.addEventListener("click", function () {
            var row = rows.filter(function (x) { return x.id === b.getAttribute("data-id"); })[0];
            chosen = row || null;
            input.value = row ? (row.name + "  (" + row.reference + ")") : "";
            results.hidden = true;
            if (opts.onPick) opts.onPick(chosen);
          });
        });
      }

      input.addEventListener("input", function () {
        chosen = null;
        if (opts.onPick) opts.onPick(null);
        clearTimeout(timer);
        var q = input.value.trim();
        if (q.length < 2) { results.hidden = true; return; }
        timer = setTimeout(function () {
          sb.rpc("madrasah_household_list", { p_q: q }).then(function (res) {
            if (res.error) throw new Error(res.error.message);
            draw(list(res.data));
          }).catch(function (e) {
            results.innerHTML = '<p class="fx-none">Families could not be searched — '
              + esc((e && e.message) || String(e)) + '</p>';
            results.hidden = false;
          });
        }, 220);
      });

      return {
        chosen: function () { return chosen; },
        clear:  function () { chosen = null; input.value = ""; results.hidden = true; }
      };
    }

    var API = {
      el: el, esc: esc, list: list, note: note, busy: busy,
      pounds: pounds, pence: pence, shortDate: shortDate, daysAgo: daysAgo,
      downloadCsv: downloadCsv, familyPicker: familyPicker,
      today: function () { return new Date().toISOString().slice(0, 10); },
      stamp: function () { return new Date().toISOString().slice(0, 10); }
    };
  }

  window.FeesGate = { start: start, pounds: pounds, pence: pence };
})();
