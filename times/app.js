/* ===========================================================================
   Taiyabah Masjid — the prayer timetable, edited by the masjid
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   Until 15 September 2026 the timetable was 365 rows compiled into the
   website. Changing one jamāʿah time meant editing a JSON file, running two
   Python scripts and pushing to GitHub. Nobody on the committee can do that,
   and none of them should have to learn.

   It was also a deadline. The page held 2026 and nothing else, so on 1
   January 2027 the live countdown and the whole timetable would have stopped,
   on the page that is the most common reason anybody opens this website — at
   exactly the point Yameen is meant to have stepped back.

   THE SHAPE OF THIS SCREEN, AND WHY
   ---------------------------------
   Paste, CHECK, save as a draft, then publish. Four steps where one would do,
   on purpose, because the thing being edited is what tells several hundred
   people when to pray.

     * CHECK BEFORE SAVE. The button that writes to the database is disabled
       until the paste has been read and found sound. Everything that can be
       wrong is listed, by row number, in the words a person would use.

     * A DRAFT IS INVISIBLE. Saving does not publish. The website never reads
       an unpublished year, so somebody can paste 2027 in during Ramadan, look
       at it, come back a week later and publish it.

     * PUBLISHING IS ITS OWN DECISION, one button, and the database refuses it
       unless the year is complete — every day of that year, leap years
       included. Half a timetable is worse than none.

   The same rules are enforced again in Postgres, in db/039_prayer_times.sql.
   Nothing here is a security control: it is JavaScript in a browser and can
   be edited by anybody who opens the developer tools. It is here so that a
   committee member gets told what is wrong in plain English instead of a
   constraint violation.

   WHAT THE SPREADSHEET HAS TO LOOK LIKE
   -------------------------------------
   One row a day, thirteen columns, in the order the masjid's own printed
   timetable already uses. Dates in either British or ISO order — 01/02/2027
   is read as 1 February, because this is a masjid in Bolton and that is what
   its spreadsheet will say.
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
  /* ------------------------------------------------------------------ the
     TIMETABLE MODULE. Everything on this screen, kept in one place so that if
     it throws, the sign-in shell around it survives — see renderApp. */
  var timetable = (function () {
    "use strict";

    var HHMM = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
    var parsed = null;          // the rows the Save button will send

    function txt(id, v) { var n = el(id); if (n) n.textContent = v; }
    function note(id, msg) {
      var n = el(id); if (!n) return;
      if (!msg) { n.hidden = true; n.textContent = ""; return; }
      n.textContent = msg; n.hidden = false;
    }

    /*  A DATE, THE WAY A SPREADSHEET WILL ACTUALLY WRITE IT.

        Accepts 2027-01-31 and 31/01/2027 and 31-01-2027. DAY FIRST when it is
        ambiguous, because this is a masjid in Bolton and 01/02/2027 means the
        first of February here. Getting that backwards would shift the entire
        timetable by up to eleven months and every individual row would still
        look perfectly valid, which is why it is stated rather than assumed. */
    function readDate(v) {
      v = String(v || "").trim();
      var m = /^(\d{4})[-\/](\d{1,2})[-\/](\d{1,2})$/.exec(v);
      if (m) return { y: +m[1], m: +m[2], d: +m[3] };
      m = /^(\d{1,2})[-\/](\d{1,2})[-\/](\d{4})$/.exec(v);
      if (m) return { y: +m[3], m: +m[2], d: +m[1] };
      return null;
    }

    /*  CSV, but the kind a spreadsheet exports: quoted fields, commas inside
        them. The Jumuʿah column is "13:15,14:00" — a comma INSIDE a value —
        so a naive split(",") gets every Friday wrong and only on Fridays,
        which is the sort of bug that reaches production. */
    function splitCsvLine(line) {
      var out = [], cur = "", q = false, i;
      for (i = 0; i < line.length; i++) {
        var c = line[i];
        if (q) {
          if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; }
          else if (c === '"') q = false;
          else cur += c;
        } else if (c === '"') q = true;
        else if (c === ",") { out.push(cur); cur = ""; }
        else cur += c;
      }
      out.push(cur);
      return out.map(function (x) { return x.trim(); });
    }

    function daysIn(year) {
      return (new Date(year, 1, 29).getMonth() === 1) ? 366 : 365;
    }

    /*  Reads the paste and says everything that is wrong with it. Returns
        { rows, year, problems } — never throws, because a person pasting a
        spreadsheet should get a list, not a stack trace. */
    function read(text, wantYear) {
      var problems = [], rows = [], seen = {}, years = {};
      var lines = String(text || "").split(/\r?\n/)
                    .filter(function (l) { return l.trim() !== ""; });

      if (!lines.length) return { rows: [], year: wantYear, problems: ["There is nothing pasted in."] };

      //  A heading row, if there is one. Detected by it not starting with
      //  something that reads as a date.
      if (!readDate(splitCsvLine(lines[0])[0])) lines.shift();

      lines.forEach(function (line, n) {
        var where = "Row " + (n + 1);
        var f = splitCsvLine(line);
        if (f.length < 12) {
          problems.push(where + " has " + f.length + " columns; it needs at least 12.");
          return;
        }
        var d = readDate(f[0]);
        if (!d) { problems.push(where + ": “" + f[0] + "” is not a date."); return; }
        years[d.y] = (years[d.y] || 0) + 1;

        var times = f.slice(2, 12);
        var badTime = null;
        times.forEach(function (t, k) { if (!HHMM.test(t) && badTime === null) badTime = [t, k]; });
        if (badTime) {
          problems.push(where + " (" + f[0] + "): “" + badTime[0] +
            "” is not a 24-hour time. It should look like 06:35.");
          return;
        }
        //  The order the prayers actually happen in. A transposed column in a
        //  spreadsheet is the mistake somebody will really make, and it is
        //  invisible to the eye in a wall of 365 rows.
        if (!(times[0] < times[2] && times[2] < times[3] &&
              times[3] < times[5] && times[5] < times[7] && times[7] < times[8])) {
          problems.push(where + " (" + f[0] + "): the times are out of order — " +
            "Fajr, sunrise, Zuhr, Asr, Maghrib then Isha. Two columns may be swapped.");
          return;
        }
        /*  THE JUMUʿAH COLUMN IS TWO TIMES WITH A COMMA BETWEEN THEM, which
            means the value itself contains the delimiter. A spreadsheet
            exports that quoted — "13:15,14:00" — and splitCsvLine handles it.
            A person pasting by hand will not quote it, and it arrives as two
            separate fields instead.

            Both are accepted, by joining everything from column 13 onward
            back together. Refusing the unquoted form would reject EVERY
            FRIDAY and nothing else, which is exactly the sort of fault that
            gets diagnosed as "the upload is broken" a month later. */
        var jum = f.slice(12).join(",").trim().replace(/,+$/, "");
        if (jum && !/^([01][0-9]|2[0-3]):[0-5][0-9],([01][0-9]|2[0-3]):[0-5][0-9]$/.test(jum)) {
          problems.push(where + " (" + f[0] + "): the Jumuʿah column should be two " +
            "times separated by a comma, like 13:15,14:00.");
          return;
        }
        //  Keyed on the YEAR as well. Without it, 1 Jan 2027 and 1 Jan 2028
        //  in one paste are reported as the same day listed twice, which
        //  sends somebody looking for a duplicate that is not there. The real
        //  problem — two years at once — is reported separately below.
        var key = d.y + "-" + d.m + "-" + d.d;
        if (seen[key]) { problems.push(where + ": " + f[0] + " is listed twice."); return; }
        seen[key] = true;

        rows.push([d.m, d.d, (f[1] || "").trim(),
                   times[0], times[1], times[2], times[3], times[4],
                   times[5], times[6], times[7], times[8], times[9], jum]);
      });

      var found = Object.keys(years).map(Number);
      if (found.length > 1) {
        problems.push("The paste covers more than one year (" + found.join(", ") +
          "). Upload one year at a time.");
      }
      var year = wantYear || found[0];
      return { rows: rows, year: year, problems: problems };
    }

    function reportHtml(res) {
      var need = res.year ? daysIn(res.year) : null;
      var bits = [];
      bits.push("<strong>" + res.rows.length + "</strong> day" +
                (res.rows.length === 1 ? "" : "s") + " read" +
                (res.year ? " for <strong>" + res.year + "</strong>" : "") + ".");
      if (need && res.rows.length !== need && !res.problems.length) {
        bits.push(" That year has <strong>" + need + "</strong> days, so this " +
          "can be saved as a draft but not published yet.");
      }
      if (res.problems.length) {
        bits.push("<ul>" + res.problems.slice(0, 12).map(function (p) {
          return "<li>" + esc(p) + "</li>";
        }).join("") + "</ul>");
        if (res.problems.length > 12) {
          bits.push("<p>&hellip;and " + (res.problems.length - 12) + " more.</p>");
        }
      }
      return bits.join("");
    }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function drawYears(list) {
      var box = el("tt-years");
      if (!box) return;
      if (!list.length) {
        box.innerHTML = "<p class=\"lede\">No timetable has been uploaded yet. " +
          "The website is showing the year built into the page.</p>";
        return;
      }
      box.innerHTML = list.map(function (y) {
        var need = daysIn(y.year);
        var whole = y.days === need;
        return '<div class="tt-year">' +
          '<span class="yr">' + esc(y.year) + "</span>" +
          '<span class="tt-pill ' + (y.published ? "tt-live" : "tt-draft") + '">' +
          (y.published ? "On the website" : "Draft") + "</span>" +
          '<span class="meta">' + y.days + " of " + need + " days" +
          (whole ? "" : " — not complete") + "</span>" +
          '<span class="spacer"></span>' +
          '<button type="button" class="btn btn-ghost tt-toggle" data-year="' +
          esc(y.year) + '" data-to="' + (y.published ? "0" : "1") + '"' +
          (!y.published && !whole ? " disabled" : "") + ">" +
          (y.published ? "Take off the website" : "Publish") + "</button>" +
          "</div>";
      }).join("");
    }

    function loadYears() {
      return sb.rpc("prayer_years_list").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        drawYears(res.data || []);
      });
    }

    /*  THE EDITOR'S OWN WIRING, separated from mount() deliberately.

        This is the paste box, the Check button and the Save button — the
        part with the rule that matters: NOTHING IS SAVEABLE UNTIL IT HAS
        BEEN CHECKED. mount() used to contain all of it, and mount() runs
        only after a real sign-in, so a test could never reach the rule. It
        looked tested and was not: the Save button is disabled in the markup
        as well, so a test that merely loads the page and reads the button
        sees "disabled" whether the logic is there or has been deleted. That
        is worse than no test, because it reports a pass either way.

        Splitting it out costs nothing at runtime — mount() calls it — and
        makes the rule reachable. It attaches listeners and reads the DOM;
        it opens no session and fetches nothing, and Save still goes through
        save_prayer_year, which the database refuses to anyone who is not a
        verified admin. */
    function wireEditor() {
      var yearBox = el("tt-year");
      if (yearBox && !yearBox.value) yearBox.value = new Date().getFullYear() + 1;

      el("tt-check").addEventListener("click", function () {
        note("tt-error", ""); note("tt-ok", "");
        var res = read(el("tt-paste").value, Number(el("tt-year").value) || null);
        parsed = res.problems.length ? null : res;
        var box = el("tt-report");
        box.innerHTML = reportHtml(res);
        box.hidden = false;
        box.classList.toggle("tt-bad", res.problems.length > 0);
        el("tt-save").disabled = !parsed || !parsed.rows.length;
        if (parsed && res.year) el("tt-year").value = res.year;
      });

      el("tt-paste").addEventListener("input", function () {
        //  Editing the paste invalidates the check. Without this, somebody
        //  checks a good year, pastes a bad one over it and the Save button
        //  is still enabled from the previous check.
        parsed = null;
        el("tt-save").disabled = true;
        el("tt-report").hidden = true;
      });

      el("tt-save").addEventListener("click", function () {
        if (!parsed) return;
        var btn = el("tt-save");
        busy(btn, true, "Save as a draft");
        note("tt-error", ""); note("tt-ok", "");
        sb.rpc("save_prayer_year", {
          p_year: parsed.year, p_rows: parsed.rows,
          p_publish: false, p_note: ""
        }).then(function (res) {
          busy(btn, false, "Save as a draft");
          if (res.error) { note("tt-error", res.error.message); return; }
          var d = res.data || {};
          note("tt-ok", "Saved " + d.days + " days for " + d.year +
            " as a draft. Nobody can see it yet — press Publish below when " +
            "you are happy with it.");
          el("tt-save").disabled = true;
          return loadYears();
        }).catch(function (e) {
          busy(btn, false, "Save as a draft");
          note("tt-error", e.message || String(e));
        });
      });

      return true;
    }

    function mount(identity) {
      wireEditor();

      el("tt-years").addEventListener("click", function (ev) {
        var btn = ev.target.closest(".tt-toggle");
        if (!btn) return;
        var year = Number(btn.getAttribute("data-year"));
        var to = btn.getAttribute("data-to") === "1";
        if (!to && !window.confirm(
              "Take the " + year + " timetable off the website?\n\n" +
              "Visitors will fall back to the year built into the page.")) return;
        btn.disabled = true;
        note("tt-error", ""); note("tt-ok", "");
        sb.rpc("set_prayer_year_published", { p_year: year, p_published: to })
          .then(function (res) {
            if (res.error) { note("tt-error", res.error.message); return loadYears(); }
            note("tt-ok", to
              ? year + " is now the timetable on the website."
              : year + " has been taken off the website.");
            return loadYears();
          })
          .catch(function (e) { note("tt-error", e.message || String(e)); });
      });

      return loadYears().catch(function (e) {
        note("tt-error", "Couldn't read the years: " + (e.message || e));
      });
    }

    //  Exported for the tests: the parser is the part worth testing and it
    //  needs no browser, no database and nobody signed in.
    return { mount: mount, _wire: wireEditor, _read: read, _readDate: readDate,
             _splitCsvLine: splitCsvLine, _daysIn: daysIn };
  })();

  /*  THE PARSER, REACHABLE FROM A TEST.

      Everything on this page lives inside one closure, which is right — but
      it also means the one piece genuinely worth testing cannot be reached.
      The parser decides what reaches the database, so it is tested against
      every wrong spreadsheet anybody is likely to paste: a time written
      "6.36", two columns swapped, a day listed twice, two years at once.

      Four of the five exposed are PURE FUNCTIONS — no session, no data, no
      network, nothing that writes. Reading them tells an attacker what a CSV
      looks like, which is also written on the screen above in plain English.

      The fifth, wire(), attaches the editor's own listeners so a test can
      exercise the check-before-save rule. It is not pure and it is worth
      being plain about: calling it on a page where nobody is signed in wires
      up a Save button whose click calls save_prayer_year — which the database
      refuses to anybody who is not a verified admin with two-step. It hands
      out no access that a signed-in admin does not already have, and none at
      all to anybody else. The check is in the database, not in this file. */
  window.__TIMETABLE_PARSER = {
    read: timetable._read,
    wire: timetable._wire,
    readDate: timetable._readDate,
    splitCsvLine: timetable._splitCsvLine,
    daysIn: timetable._daysIn
  };

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'times',
        title:   'Prayer timetable',
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
    try { timetable.mount(identity); } catch (e) {
      if (window.console) console.warn("timetable panel unavailable:", e);
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
