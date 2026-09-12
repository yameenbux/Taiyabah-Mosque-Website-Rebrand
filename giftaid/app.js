/* ===========================================================================
   Taiyabah Masjid — Gift Aid: getting a claim out of the database
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   Migration 022 records every Gift Aid declaration properly. Until this page
   there was exactly one way to get a claim out of it: run SQL in the Supabase
   editor. That is not something a masjid treasurer should have to do, and not
   something they would do — so the claim would not get made, and the whole
   point of recording the declarations would be lost.

   The same lesson as the course sign-ups in September: turning a form on and
   giving somebody a way to read the data back are two jobs, and only the first
   one feels finished.

   WHAT IT DOES NOT DO, ON PURPOSE
   -------------------------------
   It does not produce HMRC's .ods file. HMRC's schedule has a worksheet that
   must be named exactly R68GAD_V1_00_0_EN, and they warn in writing that
   converting between Excel and LibreOffice formats breaks the attachment. A
   file this page generated would look right and be rejected, and the office
   would have no way to tell which. So it produces the ROWS, in HMRC's column
   order, to paste into HMRC's own spreadsheet.

   THE AWKWARD PART, STATED RATHER THAN HIDDEN
   -------------------------------------------
   Stripe gives one "name" field and one address. HMRC wants a first name, a
   last name, and the HOUSE NUMBER OR NAME on its own. Splitting those is
   guesswork, and guesswork on a tax claim is how a claim gets disallowed. So
   every row is split automatically AND every row that the split is unsure
   about is listed at the top for a human to check before anything is filed.
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
  var giftaid = (function () {
    var rows = [];
    var mounted = false;

    // HMRC's Gift Aid schedule, in their order. Names and formats from
    // gov.uk "schedule spreadsheet to claim back tax on Gift Aid donations".
    var COLUMNS = ["Title", "First name", "Last name", "House name or number",
                   "Postcode", "Aggregated donations", "Sponsored event",
                   "Donation date", "Amount"];

    function canSee(identity) {
      return identity.roles.indexOf("admin") !== -1;
    }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function money(p) {
      return (Number(p || 0) / 100).toFixed(2);
    }

    // HMRC want DD/MM/YY. Built from the parts rather than from toLocaleString,
    // because a browser set to a US locale would silently produce MM/DD/YY and
    // a claim full of donations made on the 13th month.
    function hmrcDate(iso) {
      if (!iso) return "";
      var d = new Date(iso + "T00:00:00");
      if (isNaN(d.getTime())) return "";
      var p = function (n) { return (n < 10 ? "0" : "") + n; };
      return p(d.getDate()) + "/" + p(d.getMonth() + 1) + "/" +
             String(d.getFullYear()).slice(2);
    }

    // Titles Stripe sometimes carries into the name field. Stripped into the
    // Title column where HMRC want it, rather than left to look like a first
    // name — "Mr" is not a first name and HMRC's field is four characters.
    var TITLES = ["mr", "mrs", "miss", "ms", "dr", "sir", "imam", "hafiz",
                  "mufti", "shaykh", "sheikh", "maulana", "prof"];

    // Splitting one name into two is guesswork. It is done, and then it is
    // FLAGGED, because a name that cannot be split is a claim HMRC will reject
    // and it is far cheaper to see that here than in a rejection letter.
    function splitName(full) {
      var parts = String(full || "").trim().split(/\s+/).filter(Boolean);
      var title = "";
      if (parts.length && TITLES.indexOf(parts[0].toLowerCase().replace(/\.$/, "")) !== -1) {
        title = parts.shift().replace(/\.$/, "");
      }
      if (parts.length === 0) return { title: title, first: "", last: "", sure: false };
      if (parts.length === 1) return { title: title, first: "", last: parts[0], sure: false };
      return {
        title: title,
        first: parts.slice(0, -1).join(" "),
        last: parts[parts.length - 1],
        sure: true
      };
    }

    // HMRC want the house number or name ON ITS OWN, not the whole address.
    // "12 Astley Street, Bolton" -> "12". A house called "Rose Cottage" has no
    // number and cannot be taken automatically, so it is flagged instead of
    // guessed at.
    function houseOf(address) {
      var first = String(address || "").split(",")[0].trim();
      var m = first.match(/^(\d+[A-Za-z]?(?:\s*[-\/]\s*\d+[A-Za-z]?)?)\b/);
      if (m) return { house: m[1], sure: true };
      if (!first) return { house: "", sure: false };
      return { house: first, sure: false };
    }

    function toClaim(r) {
      var n = splitName(r.donor_name);
      var h = houseOf(r.donor_address);
      var postcode = String(r.donor_postcode || "").trim().toUpperCase();
      var problems = [];
      if (!n.last) problems.push("no name");
      else if (!n.sure) problems.push("only one name — HMRC need a first name and a surname");
      if (!postcode) problems.push("NO POSTCODE — this one cannot be claimed at all");
      if (!h.sure) problems.push("house number could not be read from the address");
      return {
        reference: r.reference,
        title: n.title, first: n.first, last: n.last,
        house: h.house, postcode: postcode,
        date: hmrcDate(r.donated_on),
        amount: money(r.amount_p),
        amount_p: r.amount_p,
        address: r.donor_address || "",
        problems: problems
      };
    }

    // One row per donation, in HMRC's column order. Tab separated, because
    // that is what pastes straight into a spreadsheet — a comma-separated
    // paste lands in one column and somebody spends an evening on Text to
    // Columns.
    function tsv(list) {
      return list.map(function (c) {
        return [c.title, c.first, c.last, c.house, c.postcode,
                "", "", c.date, c.amount].join("\t");
      }).join("\n");
    }

    function csv(list) {
      var q = function (v) { return '"' + String(v == null ? "" : v).replace(/"/g, '""') + '"'; };
      return [COLUMNS.map(q).join(",")].concat(list.map(function (c) {
        return [c.title, c.first, c.last, c.house, c.postcode,
                "", "", c.date, c.amount].map(q).join(",");
      })).join("\r\n");
    }

    function render() {
      var claims = rows.map(toClaim);
      var bad = claims.filter(function (c) { return c.problems.length; });
      var total = claims.reduce(function (a, c) { return a + Number(c.amount_p || 0); }, 0);

      el("ga-sum").innerHTML =
        '<div><span class="k">Donations to claim</span><span class="n">' + claims.length + '</span></div>' +
        '<div><span class="k">Total given</span><span class="n">&pound;' + money(total) + '</span></div>' +
        '<div class="big"><span class="k">Gift Aid worth</span><span class="n">&pound;' +
          money(Math.round(total * 0.25)) + '</span></div>';

      var warn = el("ga-warn");
      if (bad.length) {
        warn.innerHTML =
          '<b>' + bad.length + ' of these need checking before you file.</b> ' +
          'HMRC match a claim on the surname, the house number and the postcode. ' +
          'Fix them in the spreadsheet after pasting, or leave those rows out and ' +
          'ring the donor.<ul>' +
          bad.map(function (c) {
            return '<li><b>' + esc(c.reference) + '</b> — ' + esc(c.problems.join("; ")) + '</li>';
          }).join("") + '</ul>';
        warn.hidden = false;
      } else {
        warn.hidden = true;
      }

      if (!claims.length) {
        el("ga-list").innerHTML =
          '<p class="ga-empty">Nothing waiting to be claimed. Donations appear here ' +
          'when somebody chooses Gift Aid on the payment page.</p>';
        return;
      }

      el("ga-list").innerHTML =
        '<table class="ga-table"><thead><tr>' +
        ["Reference"].concat(COLUMNS).map(function (h) { return "<th>" + esc(h) + "</th>"; }).join("") +
        '</tr></thead><tbody>' +
        claims.map(function (c) {
          var blank = function (v, why) {
            return v ? esc(v) : '<span class="miss">' + esc(why) + '</span>';
          };
          return '<tr class="' + (c.problems.length ? "bad" : "") + '">' +
            "<td>" + esc(c.reference) + "</td>" +
            "<td>" + esc(c.title) + "</td>" +
            "<td>" + esc(c.first) + "</td>" +
            "<td>" + blank(c.last, "missing") + "</td>" +
            "<td>" + blank(c.house, "check") + "</td>" +
            "<td>" + blank(c.postcode, "MISSING") + "</td>" +
            "<td></td><td></td>" +
            "<td>" + esc(c.date) + "</td>" +
            "<td>&pound;" + esc(c.amount) + "</td>" +
            "</tr>";
        }).join("") +
        "</tbody></table>";
    }

    function load() {
      return sb.rpc("gift_aid_to_claim").then(function (out) {
        if (out.error) throw new Error(out.error.message);
        rows = out.data || [];
      });
    }

    function say(msg, isError) {
      var box = el("ga-error");
      if (!msg) { box.hidden = true; return; }
      box.textContent = msg;
      box.hidden = false;
      box.style.borderColor = isError ? "" : "var(--success)";
    }

    function copyOut() {
      var text = tsv(rows.map(toClaim));
      if (!text) { say("There is nothing to copy."); return; }
      var done = function () {
        say("Copied " + rows.length + " donation" + (rows.length === 1 ? "" : "s") +
            ". Click the first empty donor row in HMRC's spreadsheet and paste.");
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { fallback(text, done); });
      } else {
        fallback(text, done);
      }
    }

    // Older browsers, and any page not served over https, have no clipboard
    // API. The office should not have to know that.
    function fallback(text, done) {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.top = "-1000px";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); done(); }
      catch (e) { say("Couldn't copy automatically — use Download as CSV instead.", true); }
      document.body.removeChild(ta);
    }

    function download() {
      var text = csv(rows.map(toClaim));
      var blob = new Blob(["﻿" + text], { type: "text/csv;charset=utf-8;" });
      var a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "gift-aid-claim-" + new Date().toISOString().slice(0, 10) + ".csv";
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      setTimeout(function () { URL.revokeObjectURL(a.href); }, 2000);
      say("Downloaded " + rows.length + " donation" + (rows.length === 1 ? "" : "s") + ".");
    }

    function markClaimed() {
      if (!rows.length) { say("There is nothing to mark."); return; }
      // Confirmed, because it cannot be undone from this page: once a donation
      // is marked claimed it leaves this list for good, and a claim that was
      // never actually filed would be silently lost.
      if (!window.confirm(
            "Mark all " + rows.length + " of these as claimed?\n\n" +
            "Only do this AFTER the claim has been submitted to HMRC. They will " +
            "disappear from this list and cannot be brought back from here.")) return;

      var refs = rows.map(function (r) { return r.reference; });
      sb.rpc("mark_gift_aid_claimed", { p_references: refs })
        .then(function (out) {
          if (out.error) throw new Error(out.error.message);
          say("Marked " + out.data + " as claimed.");
          return load().then(render);
        })
        .catch(function (e) {
          say("Couldn't mark those as claimed — " + e.message + ". Nothing was changed.", true);
        });
    }

    function mount(identity) {
      if (mounted) return;
      mounted = true;

      if (!canSee(identity)) {
        el("app-noaccess").hidden = false;
        return;
      }
      el("ga-panel").hidden = false;

      el("ga-copy").addEventListener("click", copyOut);
      el("ga-csv").addEventListener("click", download);
      el("ga-claimed").addEventListener("click", markClaimed);

      load().then(render).catch(function (e) {
        say("Couldn't read the Gift Aid records — " + e.message, true);
      });
    }

    return { mount: mount, _split: splitName, _house: houseOf,
             _date: hmrcDate, _tsv: tsv, _csv: csv, _toClaim: toClaim };
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
    try { giftaid.mount(identity); } catch (e) {
      if (window.console) console.warn("gift aid panel unavailable:", e);
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
