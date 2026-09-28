/* ===========================================================================
   APPLICATIONS — what parents have sent through the form on the website.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   25 September 2026

   THE FORM HAS BEEN LIVE AND NOBODY COULD OPEN WHAT IT WROTE.

   008 built the whole admissions pipeline and stopped one function short of
   being usable: a parent could apply, the office was emailed that something
   had arrived, and the row was purged on schedule three years later. Between
   those two events there was no way for any human being to read it. The
   Applications row in the rail said SOON, and the tables were sealed.

   db/076 is the missing half and this is the screen on top of it.

   THE SIGN-IN, TWO-STEP AND RAIL BELOW THIS PANEL ARE NOT WRITTEN HERE.

   They are lifted verbatim from portal/classes/app.js by
   tools/build_admissions_screen.py — the same shell, the same enrolment flow,
   the same fallbacks. Eleven screens sharing one implementation is why the
   drawer, the escape key and the focus handling behave identically on all of
   them; a twelfth hand-typed copy would be a twelfth chance to get one wrong.
   Only the panel in the middle belongs to this screen.
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
        sb.from("profiles").select("full_name, email, must_change_password")
          .eq("id", user.id).maybeSingle(),
        sb.from("user_roles").select("role").eq("user_id", user.id)
      ]).then(function (out) {
        var errs = [];
        if (out[0].error) errs.push("profiles — " + out[0].error.message);
        if (out[1].error) errs.push("user_roles — " + out[1].error.message);
        return {
          user: user,
          profile: out[0].data || {},
          roles: (out[1].data || []).map(function (r) { return r.role; }),
          //  SET WHEN SOMEBODY ELSE CHOSE THIS ACCOUNT'S PASSWORD.
          //  Teacher logins are created with an initial password handed over
          //  on paper, which means it exists in a drawer and in whatever
          //  printed it. mustChange gates every screen until they have
          //  chosen their own - see mustChangeGate() and db/093.
          mustChange: !!(out[0].data && out[0].data.must_change_password),
          errors: errs
        };
      });
    });
  }


  /*  THE PASSWORD GATE.

      Deliberately plain and deliberately final: one field, one rule, and no
      way past it. There is no "remind me later", because later is the same
      drawer with the same slip in it.

      NO EMAIL RESET EXISTS for these accounts - not one member of staff has
      an email address, which is why the initial password was on paper in the
      first place - so the screen says who to ask rather than offering a link
      that goes nowhere.                                                     */
  /*  THE PASSWORD GATE IS AN OVERLAY, AND IT CARRIES ITS OWN STYLES.
   *
   *  The first version of this appended a styled <section> into the page and
   *  set `hidden` on everything else. On the generated screens that looked
   *  right, and on the one page a teacher actually lands on after signing in
   *  - portal/index.html - it produced a mess: the card spread the full width
   *  of the window with its left third underneath the rail, the portal drew
   *  itself underneath, and the rail sat there offering Admin Centre.
   *
   *  Three separate reasons, all the same shape:
   *
   *    1. .pw-gate's layout rules live in admin/screen.css. The portal landing
   *       page loads fonts.css and shell.css only, so the card had no width,
   *       no padding and no max-width.
   *    2. Hiding things with the `hidden` attribute depends on
   *       [hidden]{display:none !important}, which is declared in each
   *       SCREEN stylesheet. The landing page loads none of them.
   *    3. It hid .bk, .ashell and .ashell-bar. It never hid the rail on a
   *       page whose rail is .shell, and it never stopped a request already
   *       in flight from un-hiding a panel when it came back.
   *
   *  So this version assumes nothing about the page it is on. It injects the
   *  handful of rules it needs, and it covers the viewport rather than asking
   *  the rest of the document to please get out of the way. A gate that works
   *  only where the right stylesheet happens to be loaded is not a gate.
   */
  function mustChangeGate(identity) {
    //  OWN STYLES, INJECTED ONCE. Everything the overlay needs, so that it
    //  does not matter which stylesheets this particular page loaded.
    if (!document.getElementById("pw-gate-css")) {
      var st = document.createElement("style");
      st.id = "pw-gate-css";
      st.textContent =
        "#pw-shade{position:fixed;top:0;right:0;bottom:0;left:0;z-index:2147483000;"
        + "background:#f7f3ec;overflow:auto;-webkit-overflow-scrolling:touch;"
        + "display:block;padding:24px 16px 64px;}"
        + "#pw-shade *{box-sizing:border-box;}"
        + "#pw-gate{max-width:520px;margin:6vh auto 0;background:#fffdf8;"
        + "border:1px solid #e7ddcc;border-radius:14px;padding:28px 30px;"
        + "box-shadow:0 10px 30px rgba(60,35,20,.10);"
        + "font-family:ui-sans-serif,system-ui,-apple-system,'Segoe UI',sans-serif;"
        + "color:#2b2118;}"
        + "#pw-gate h2{margin:0 0 10px;font-size:1.5rem;line-height:1.25;"
        + "font-family:Georgia,'Times New Roman',serif;color:#5b1226;}"
        + "#pw-gate p{margin:0 0 16px;line-height:1.6;font-size:1rem;}"
        + "#pw-gate .pw-fld{display:block;margin:0 0 14px;}"
        + "#pw-gate .pw-fld span{display:block;margin-bottom:6px;font-size:.9rem;"
        + "font-weight:600;letter-spacing:.01em;}"
        + "#pw-gate .pw-fld input{display:block;width:100%;padding:11px 12px;"
        + "font-size:1rem;border:1px solid #cdbfa8;border-radius:8px;"
        + "background:#fff;color:inherit;}"
        + "#pw-gate .pw-fld input:focus{outline:3px solid #b9903f;outline-offset:1px;}"
        + "#pw-gate .pw-hint{font-size:.9rem;color:#6d6155;}"
        + "#pw-gate .pw-err{margin:0 0 14px;padding:10px 12px;border-radius:8px;"
        + "background:#fdecec;border:1px solid #e4b4b4;color:#8a1c1c;font-size:.95rem;}"
        + "#pw-gate button{display:block;width:100%;margin:4px 0 16px;padding:13px 16px;"
        + "font-size:1.02rem;font-weight:700;cursor:pointer;border:0;border-radius:9px;"
        + "background:#c8a34a;color:#2b2118;font-family:inherit;}"
        + "#pw-gate button:disabled{opacity:.6;cursor:default;}"
        //  Declared here too, because the page underneath may not declare it.
        + "#pw-shade [hidden]{display:none !important;}";
      document.head.appendChild(st);
    }

    var who = (identity.profile && identity.profile.full_name) || "";
    var shade = document.createElement("div");
    shade.id = "pw-shade";
    shade.setAttribute("role", "dialog");
    shade.setAttribute("aria-modal", "true");
    shade.setAttribute("aria-labelledby", "pw-gate-h");
    shade.innerHTML =
      '<section id="pw-gate">'
      + '<h2 id="pw-gate-h">Choose your own password</h2>'
      + "<p>Assalamu alaikum" + (who ? ", " + esc(who) : "")
      + ". The password you were given was written on a slip of paper, so it "
      + "is not private. Choose one only you know before going any further.</p>"
      + '<div class="pw-err" id="pw-err" hidden></div>'
      //  THE CURRENT PASSWORD, ASKED FOR ON PURPOSE.
      //
      //  Supabase is set to require it, and that setting is worth keeping.
      //  These screens get opened on a shared machine in the masjid office.
      //  Without it, anybody who finds a session somebody left signed in can
      //  change the password and own the account outright; with it they
      //  cannot, because the slip is in the teacher's pocket.
      //
      //  It is the password they typed a moment ago, so this is one line of
      //  friction, once, ever. Asking is also more robust than carrying what
      //  they typed on the sign-in screen: this gate has to work on a page
      //  opened fresh days later with the session still valid.
      + '<label class="pw-fld"><span>The password from your slip</span>'
      + '<input type="password" id="pw-now" autocomplete="current-password"></label>'
      + '<label class="pw-fld"><span>Your new password</span>'
      + '<input type="password" id="pw-one" autocomplete="new-password"></label>'
      + '<label class="pw-fld"><span>Type it again</span>'
      + '<input type="password" id="pw-two" autocomplete="new-password"></label>'
      + '<p class="pw-hint">At least ten characters. Something you can '
      + "remember and nobody could guess &mdash; three unrelated words is "
      + "better than one word with numbers after it.</p>"
      + '<button type="button" id="pw-go">Save it and carry on</button>'
      + '<p class="pw-hint">There is no email reset on a madrasah login, '
      + "because the madrasah does not hold your email address. If you forget "
      + "this one, the office has to set you a new one.</p>"
      + "</section>";

    //  LAST CHILD OF BODY, so it paints above anything that mounts later -
    //  the rail mounts itself into the document and would otherwise arrive
    //  after us.
    document.body.appendChild(shade);

    //  Belt and braces, not the mechanism. The overlay is what stops the page
    //  being READ; this stops it being TABBED INTO behind the overlay, which
    //  a sighted person never notices and a keyboard or screen-reader user
    //  hits immediately.
    //
    //  EVERY SIBLING, not a list of class names. The first version named
    //  ".bk, .ashell, .ashell-bar" and missed .md-lead and .tc-classes on the
    //  one page this actually runs on, because a list of selectors is a guess
    //  about a page you are not looking at. "Everything except me" needs no
    //  such guess and cannot go stale when a screen adds a container.
    var sib = document.body.children;
    for (var i = sib.length - 1; i >= 0; i--) {
      var n = sib[i];
      if (n === shade || n.tagName === "SCRIPT" || n.tagName === "STYLE") continue;
      n.setAttribute("hidden", "hidden");
      n.setAttribute("aria-hidden", "true");
      //  setProperty WITH "important", not style.display = "none".
      //  admin/shell.css carries  body.has-ashell .shell{display:block
      //  !important}  and an inline declaration without !important loses to
      //  an !important one in a stylesheet. The rail stayed on screen behind
      //  the gate until this line said important too. Same collision this
      //  project hit with the print stylesheets.
      n.style.setProperty("display", "none", "important");
    }
    //  And stop the document scrolling underneath on a phone.
    document.documentElement.style.overflow = "hidden";
    document.body.style.overflow = "hidden";

    var one = document.getElementById("pw-now");
    if (one && one.focus) { try { one.focus(); } catch (e) {} }

    function fail(m) {
      var e = document.getElementById("pw-err");
      if (e) { e.textContent = m; e.removeAttribute("hidden"); }
    }

    document.getElementById("pw-go").addEventListener("click", function () {
      var now = document.getElementById("pw-now").value;
      var a = document.getElementById("pw-one").value;
      var b = document.getElementById("pw-two").value;
      if (!now) { fail("Put in the password from your slip first."); return; }
      if (a.length < 10) { fail("That is too short. Ten characters or more."); return; }
      if (a !== b) { fail("The two do not match."); return; }
      if (a === now) { fail("That is the same password. Choose a different one."); return; }
      var go = document.getElementById("pw-go");
      go.disabled = true; go.textContent = "Saving…";
      //  currentPassword goes straight through to the API as the request
      //  body - updateUser does Object.assign({}, attributes) with no
      //  whitelist - so the vendored client sends it even though the
      //  minified bundle never names it. Harmless if the setting is ever
      //  turned off.
      sb.auth.updateUser({ password: a, currentPassword: now }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        return sb.rpc("clear_must_change_password");
      }).then(function () {
        //  Straight back in, rather than asking them to sign in again with
        //  the password they have just this second chosen.
        document.documentElement.style.overflow = "";
        document.body.style.overflow = "";
        window.location.reload();
      })["catch"](function (e) {
        go.disabled = false; go.textContent = "Save it and carry on";
        var m = (e && e.message) ? e.message : "";
        //  SAY THE USEFUL THING. The API's own wording for a wrong current
        //  password is about fields and parameters, which tells a teacher
        //  nothing about what to do next.
        if (/current password|invalid.*credential|not correct/i.test(m)) {
          fail("That is not the password on your slip. Check it and try again.");
        } else if (/weak|pwned|compromis|breach/i.test(m)) {
          fail("That password has appeared in a known data breach. Please "
               + "choose a different one.");
        } else {
          fail("That could not be saved. " + m);
        }
      });
    });
  }


  /* =========================================================================
     NOTICES TO PARENTS

     WHAT THIS SCREEN IS FOR, and why it opens on one job rather than on a
     blank message box.

     Publishing a privacy notice is half the duty. Articles 13 and 14 require
     the masjid to INFORM parents, and the regulator's position is that you
     have to take an ACTIVE STEP: a page on a website that nobody has been
     pointed at has informed nobody. The masjid's own notice says exactly
     that, and then commits to writing to parents once and recording the date.

     That record is the evidence the duty was discharged. Without it the
     masjid's position is "we think we told people", which is not a position.

     So this screen is, first, a job with a number attached: 330 families, so
     many told, so many not. It is finished when the second number is nought.

     AND IT BLOCKS SOMETHING, DELIBERATELY. Fee reminders will not go to a
     family that has not been told — enforced in the database, not here, so
     that nobody can get round it by using a different screen. Writing to
     somebody about money using contact details they were never told you held
     is the wrong order, and it is the kind of wrong order that generates a
     complaint rather than a payment.
     ======================================================================= */
  var notices = (function () {

    var ROWS = [];
    var ROLES = [];
    var NEED = "";            // "", "untold", "told", "noemail"
    var PAGE = 1;
    var PER = 50;
    var PICKED = {};          // household id -> true
    var busy = false;
    var VERSION = "1.2";

    function el(id) { return document.getElementById(id); }
    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }
    function fail(msg) {
      var n = el("nt-error");
      if (!n) return;
      n.textContent = msg; n.hidden = false;
    }
    function clearFail() { show("nt-error", false); }

    function pickedIds() {
      var out = [], k;
      for (k in PICKED) { if (PICKED.hasOwnProperty(k) && PICKED[k]) out.push(k); }
      return out;
    }

    // --- the job -----------------------------------------------------------
    function counts() {
      var c = { all: ROWS.length, told: 0, untold: 0, noemail: 0, untold_noemail: 0 };
      for (var i = 0; i < ROWS.length; i++) {
        var r = ROWS[i];
        if (r.told_on) { c.told++; } else { c.untold++; }
        if (!r.has_email) {
          c.noemail++;
          if (!r.told_on) c.untold_noemail++;
        }
      }
      return c;
    }

    function drawJob() {
      var host = el("nt-job");
      if (!host) return;
      var c = counts();
      var done = (c.all > 0 && c.untold === 0);
      var pct = c.all ? Math.round((c.told / c.all) * 100) : 0;

      //  SAID AS A JOB, NOT AS A DASHBOARD. "0 of 330" with what it is
      //  blocking underneath, because a percentage on its own does not tell
      //  anybody what to do next.
      host.className = "nt-job" + (done ? " is-done" : "");
      host.innerHTML =
        "<h3>" + (done
          ? "Every family has been told the privacy notice exists"
          : "Telling parents the privacy notice exists") + "</h3>"
        + '<div class="nt-bar"><span style="width:' + pct + '%"></span></div>'
        + '<p class="nt-bignum"><b>' + esc(c.told) + "</b> of "
        + esc(c.all) + (c.all === 1 ? " family" : " families")
        + " told</p>"
        + (done
            ? '<p class="nt-sub">Recorded against the person who did it and '
              + "the date. That record is what shows the duty was "
              + "discharged.</p>"
            : '<p class="nt-sub">The law asks the masjid to take an active '
              + "step, not to publish a page and wait to be found. Until a "
              + "family has been told, <strong>fee reminders will not go to "
              + "them</strong> — the system refuses, it is not a matter "
              + "of remembering.</p>"
              + (c.untold_noemail
                  ? '<p class="nt-sub"><strong>' + esc(c.untold_noemail)
                    + "</strong> of those still to be told have no email "
                    + "address, so they need a letter or a word at the door. "
                    + "Both count, and both are recorded.</p>"
                  : ""));
    }

    function drawFigures() {
      var host = el("nt-figs");
      if (!host) return;
      var c = counts();
      function fig(key, n, label, sub, tone) {
        var on = NEED === key;
        return '<button type="button" class="nt-fig' + (tone ? " " + tone : "")
             + (on ? " is-on" : "") + '" data-need="' + esc(key) + '"'
             + (n ? "" : " disabled") + '><b>' + esc(n) + "</b><span>"
             + esc(label) + "</span>"
             + (sub ? "<small>" + esc(sub) + "</small>" : "") + "</button>";
      }
      host.innerHTML =
          fig("", c.all, "Families", "on the register")
        + fig("untold", c.untold, "Still to tell",
              "fee reminders blocked", c.untold ? "bad" : "")
        + fig("told", c.told, "Told", "date recorded", "")
        + fig("noemail", c.noemail, "No email address",
              "letter or in person", c.noemail ? "warn" : "");
    }

    // --- the list ----------------------------------------------------------
    function matches(r) {
      var q = (el("nt-q") ? el("nt-q").value : "").trim().toLowerCase();
      if (NEED === "untold"  && r.told_on) return false;
      if (NEED === "told"    && !r.told_on) return false;
      if (NEED === "noemail" && r.has_email) return false;
      if (!q) return true;
      return (r.family + " " + (r.reference || "")).toLowerCase().indexOf(q) !== -1;
    }

    function filtered() {
      var out = [];
      for (var i = 0; i < ROWS.length; i++) {
        if (matches(ROWS[i])) out.push(ROWS[i]);
      }
      return out;
    }
    function resetPage() { PAGE = 1; }

    function said(r) {
      if (!r.told_on) return '<span class="nt-no">Not yet</span>';
      var how = r.told_how === "letter" ? "by letter"
              : r.told_how === "email" ? "by email" : "in person";
      return '<span class="nt-yes">' + esc(r.told_on) + "</span>"
           + '<span class="nt-q">' + esc(how) + "</span>";
    }

    function drawRows() {
      var body = el("nt-rows");
      if (!body) return;
      var rows = filtered();
      var pages = Math.max(1, Math.ceil(rows.length / PER));
      if (PAGE > pages) PAGE = pages;
      if (PAGE < 1) PAGE = 1;
      var from = (PAGE - 1) * PER;
      var page = rows.slice(from, from + PER);
      var out = [];
      for (var i = 0; i < page.length; i++) {
        var r = page[i];
        out.push('<tr class="nt-row" data-id="' + esc(r.id) + '">'
          + '<td class="nt-pick"><input type="checkbox" class="nt-cb"'
          + ' data-id="' + esc(r.id) + '"' + (PICKED[r.id] ? " checked" : "")
          + ' aria-label="Choose ' + esc(r.family) + '"></td>'
          + '<td class="nt-ref" data-label="Reference">'
          + esc(r.reference || "—") + "</td>"
          + '<td class="nt-who" data-label="Family">' + esc(r.family) + "</td>"
          + '<td data-label="Children">' + esc(r.children) + "</td>"
          + '<td data-label="How we can reach them">'
          + (r.has_email ? "Email"
             : (r.has_phone ? '<span class="nt-warn-t">Telephone only</span>'
                            : '<span class="nt-bad">Nobody to ring</span>'))
          + "</td>"
          + '<td data-label="Told">' + said(r) + "</td></tr>");
      }
      body.innerHTML = out.join("");

      var empty = el("nt-empty");
      if (empty) {
        empty.hidden = rows.length > 0;
        empty.textContent = ROWS.length
          ? "No family matches that."
          : "There are no families on the register yet.";
      }
      var c = el("nt-count");
      if (c) {
        c.textContent = rows.length === 0 ? "no families"
          : rows.length <= PER
            ? rows.length + (rows.length === 1 ? " family" : " families")
            : "Showing " + (from + 1) + "–"
              + Math.min(from + PER, rows.length) + " of " + rows.length;
      }
      drawPager(pages);
      drawChosen();
      var all = el("nt-all");
      if (all) {
        var n = 0;
        for (var j = 0; j < page.length; j++) { if (PICKED[page[j].id]) n++; }
        all.checked = (page.length > 0 && n === page.length);
        all.indeterminate = (n > 0 && n < page.length);
      }
    }

    function drawPager(pages) {
      var hosts = document.querySelectorAll(".nt-pager");
      if (!hosts.length) return;
      var h = "", p, i;
      if (pages > 1) {
        h += '<div class="nt-pages">'
           + '<button type="button" class="nt-page" data-page="' + (PAGE - 1)
           + '"' + (PAGE === 1 ? " disabled" : "") + ">Back</button>";
        var shown = [];
        for (p = 1; p <= pages; p++) {
          if (p === 1 || p === pages || Math.abs(p - PAGE) <= 1) shown.push(p);
        }
        var last = 0;
        for (i = 0; i < shown.length; i++) {
          p = shown[i];
          if (last && p - last > 1) h += '<span class="nt-gap">…</span>';
          h += '<button type="button" class="nt-page'
             + (p === PAGE ? " is-on" : "") + '" data-page="' + p + '"'
             + (p === PAGE ? ' aria-current="page"' : "")
             + ' aria-label="Page ' + p + '">' + p + "</button>";
          last = p;
        }
        h += '<button type="button" class="nt-page" data-page="' + (PAGE + 1)
           + '"' + (PAGE === pages ? " disabled" : "") + ">Next</button></div>";
      }
      hosts[0].innerHTML = h;
      for (i = 1; i < hosts.length; i++) hosts[i].innerHTML = hosts[0].innerHTML;
    }

    /* -----------------------------------------------------------------------
       WHAT HAPPENS TO THE FAMILIES YOU HAVE CHOSEN.

       The bar only appears when something is chosen, and it says the number
       every time. "Record 47 families as told" is a sentence somebody can
       check before they press it; "Mark as told" is not, and this writes a
       row against their name for each one.
       --------------------------------------------------------------------- */
    function drawChosen() {
      var bar = el("nt-chosen");
      if (!bar) return;
      var ids = pickedIds();
      if (!ids.length) { bar.hidden = true; bar.innerHTML = ""; return; }
      var isAdmin = ROLES.indexOf("admin") !== -1;
      bar.hidden = false;
      var n = ids.length;
      var word = n === 1 ? "family" : "families";
      bar.innerHTML =
        '<span class="nt-chosen-n"><strong>' + esc(n) + "</strong> " + word
        + " chosen</span>"
        + '<div class="nt-chosen-acts">'
        + '<button type="button" class="btn btn-ghost" data-do="print">'
        + "Print " + esc(n) + " letter" + (n === 1 ? "" : "s") + "</button>"
        + (isAdmin
            ? '<button type="button" class="btn btn-gold" data-do="told">'
              + "Record " + esc(n) + " as told…</button>"
            : '<span class="nt-q">Recording that a family has been told is '
              + "an administrator’s job.</span>")
        + '<button type="button" class="nt-linkish" data-do="none">Clear</button>'
        + "</div>";
    }

    //  ASKED BEFORE IT IS DONE, and asked in a way that requires reading.
    //  A row per family is written against the name of whoever pressed this,
    //  and it is the thing the masjid would produce if the regulator asked.
    function askTold() {
      var box = el("nt-confirm");
      if (!box) return;
      var n = pickedIds().length;
      box.hidden = false;
      box.innerHTML =
        "<h4>Record " + esc(n) + (n === 1 ? " family" : " families")
        + " as told?</h4>"
        + '<p class="nt-sub">This writes the date against your name for each '
        + "one, and it is the evidence the masjid has told them. It also lets "
        + "fee reminders go to them, which the system is currently refusing. "
        + "Only record families you have actually told.</p>"
        + '<div class="nt-how">'
        + '<button type="button" class="nt-ex-opt" data-told="letter">'
        + "<strong>By letter</strong><span>You printed the letters and they "
        + "have gone out with the children, or been posted.</span></button>"
        + '<button type="button" class="nt-ex-opt" data-told="in_person">'
        + "<strong>In person</strong><span>You handed them a printed copy or "
        + "told them at the door.</span></button>"
        + "</div>"
        //  'email' IS NOT OFFERED, because this screen cannot send one yet and
        //  offering it would invite somebody to record a send that never
        //  happened. The database accepts it for when the email goes in.
        + '<p class="nt-ex-note">Emailing parents from here is not built yet, '
        + "so there is no “by email” to choose. Recording one would "
        + "mean writing down something that did not happen.</p>"
        + '<button type="button" class="nt-linkish" data-told="cancel">'
        + "Cancel</button>";
    }

    function doTold(how) {
      var ids = pickedIds();
      if (!ids.length || busy) return;
      busy = true; clearFail();
      sb.rpc("record_parents_told",
             { p_households: ids, p_how: how, p_version: VERSION })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {};
          PICKED = {};
          show("nt-confirm", false);
          var ok = el("nt-ok");
          if (ok) {
            ok.hidden = false;
            ok.textContent = (d.recorded || 0)
              + ((d.recorded === 1) ? " family is" : " families are")
              + " recorded as told, dated today, against your name."
              + (d.skipped ? " " + d.skipped + " was not on the register and "
                             + "was left alone." : "");
          }
          return load();
        })["catch"](function (e) {
          fail("That could not be recorded. " + (e && e.message ? e.message : ""));
        })["finally"](function () { busy = false; });
    }

    /* -----------------------------------------------------------------------
       THE LETTERS.

       One per family, each on its own page, addressed to the family by name.
       Printed from the browser so the office needs no mail merge and no Word
       document that drifts from the notice.
       --------------------------------------------------------------------- */
    function printLetters() {
      var ids = pickedIds();
      if (!ids.length) return;
      var host = el("nt-print");
      if (!host) return;
      var by = {}, i;
      for (i = 0; i < ROWS.length; i++) by[ROWS[i].id] = ROWS[i];

      var when = new Date();
      var MM = ["January","February","March","April","May","June","July",
                "August","September","October","November","December"];
      var dated = when.getDate() + " " + MM[when.getMonth()] + " "
                + when.getFullYear();

      var out = [];
      for (i = 0; i < ids.length; i++) {
        var r = by[ids[i]];
        if (!r) continue;
        out.push('<section class="lt">'
          + '<div class="lt-head"><img class="lt-logo" src="../../img/masjid-logo.png" alt="">'
          + "<div><h1>Taiyabah Masjid</h1><p>Madrasah</p></div>"
          + '<div class="lt-from"><p>Bolton Central Islamic Society</p>'
          + "<p>Registered charity 1041569</p><p>01204 535 997</p></div></div>"
          + '<p class="lt-to">' + esc(r.family) + "</p>"
          + '<p class="lt-date">' + esc(dated) + "</p>"
          + '<p class="lt-re"><strong>About the information the madrasah '
          + "keeps about your child</strong></p>"
          + '<div class="lt-body">'
          + "<p>Assalamu alaikum,</p>"
          + "<p>We are writing to tell you that the madrasah has published a "
          + "privacy notice. It explains what we keep about your child and "
          + "about you, why we keep it, who can see it, how long we keep it, "
          + "and what you can ask us to do about it.</p>"
          + "<p>You can read it at "
          + "<strong>taiyabahmasjid.com/madrasah-privacy</strong>. If you "
          + "would rather have it on paper, ask at the office and we will "
          + "give you a printed copy — you should not need a computer to "
          + "find out what is held about your child.</p>"
          + "<p>Please do read it. It has changed: an earlier version said we "
          + "kept only your child’s name, class and dates. When the "
          + "madrasah’s records were moved into a new system in September "
          + "they brought across more than that — dates of birth, "
          + "addresses, contact numbers, and for some children medical or "
          + "additional-needs information that a parent had told us. The "
          + "notice now sets all of that out properly.</p>"
          + "<p>If anything in it concerns you, or you would like something "
          + "removed or corrected, please come and speak to us. We would "
          + "rather hear from you than not.</p>"
          + "<p>Jazakumullahu khairan,</p>"
          + "<p>Taiyabah Masjid Madrasah</p>"
          + "</div></section>");
      }
      host.innerHTML = out.join("");

      //  MOVED OUT TO body BEFORE PRINTING, and restored in finally.
      //  admin/shell.css carries `body.has-ashell .shell{display:block
      //  !important}` and when two !important declarations collide,
      //  SPECIFICITY decides - (0,2,0) beats `body > *` at (0,0,1). The rail
      //  wins from inside the shell, so the sheet has to leave it.
      var back = host.parentNode;
      document.body.appendChild(host);
      document.body.className += " printing-letters";
      try { window.print(); }
      finally {
        document.body.className =
          document.body.className.replace(/\s*printing-letters/, "");
        if (back) back.appendChild(host);
      }
    }

    // --- loading -----------------------------------------------------------
    function load() {
      return sb.rpc("madrasah_parent_notice_list",
                    { p_kind: "privacy_notice" }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        var d = res.data || {};
        if (d.allowed === false) {
          ROWS = [];
          fail("This area is for madrasah staff.");
          return;
        }
        ROWS = d.rows || [];
        drawJob(); drawFigures(); drawRows();
      })["catch"](function (e) {
        fail("The families would not load. " + (e && e.message ? e.message : ""));
      });
    }

    function wire() {
      var q = el("nt-q");
      if (q) q.addEventListener("input", function () { resetPage(); drawRows(); });

      var figs = el("nt-figs");
      if (figs) figs.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-need]") : null;
        if (!b) return;
        NEED = (NEED === b.getAttribute("data-need"))
          ? "" : b.getAttribute("data-need");
        resetPage(); drawFigures(); drawRows();
      });

      var pagers = document.querySelectorAll(".nt-pager");
      for (var pi = 0; pi < pagers.length; pi++) {
        pagers[pi].addEventListener("click", function (e) {
          var pb = e.target.closest ? e.target.closest(".nt-page") : null;
          if (pb && !pb.disabled) {
            PAGE = parseInt(pb.getAttribute("data-page"), 10) || 1;
            drawRows();
            var top = el("nt-list");
            if (top && top.scrollIntoView) top.scrollIntoView(true);
          }
        });
      }

      var body = el("nt-rows");
      if (body) body.addEventListener("change", function (e) {
        var cb = e.target;
        if (!cb || !cb.classList || !cb.classList.contains("nt-cb")) return;
        var id = cb.getAttribute("data-id");
        if (cb.checked) { PICKED[id] = true; } else { delete PICKED[id]; }
        drawChosen();
        var all = el("nt-all");
        if (all) {
          var page = filtered().slice((PAGE - 1) * PER, PAGE * PER), n = 0;
          for (var i = 0; i < page.length; i++) { if (PICKED[page[i].id]) n++; }
          all.checked = (page.length > 0 && n === page.length);
          all.indeterminate = (n > 0 && n < page.length);
        }
      });

      //  "CHOOSE ALL" MEANS ALL ON THIS PAGE, and the label says so.
      //  A tick box that silently chooses 330 families when fifty are on
      //  screen is how somebody records three hundred people as told by
      //  accident.
      var all = el("nt-all");
      if (all) all.addEventListener("change", function () {
        var page = filtered().slice((PAGE - 1) * PER, PAGE * PER);
        for (var i = 0; i < page.length; i++) {
          if (all.checked) { PICKED[page[i].id] = true; }
          else { delete PICKED[page[i].id]; }
        }
        drawRows();
      });

      var everyone = el("nt-everyone");
      if (everyone) everyone.addEventListener("click", function () {
        var rows = filtered();
        for (var i = 0; i < rows.length; i++) PICKED[rows[i].id] = true;
        drawRows();
      });

      var bar = el("nt-chosen");
      if (bar) bar.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-do]") : null;
        if (!b) return;
        var what = b.getAttribute("data-do");
        if (what === "none")       { PICKED = {}; show("nt-confirm", false); drawRows(); }
        else if (what === "print") { printLetters(); }
        else if (what === "told")  { askTold(); }
      });

      var conf = el("nt-confirm");
      if (conf) conf.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-told]") : null;
        if (!b) return;
        var how = b.getAttribute("data-told");
        if (how === "cancel") { show("nt-confirm", false); return; }
        doTold(how);
      });
    }

    function mount(identity) {
      var roles = (identity && identity.roles) || [];
      if (roles.indexOf("admin") === -1 && roles.indexOf("madrasah") === -1) {
        var na = el("app-noaccess");
        if (na) {
          na.textContent = "This area is for madrasah staff. If you should be "
            + "able to see this, ask the office to add you.";
          na.hidden = false;
        }
        return;
      }
      ROLES = roles;
      if (window.innerWidth && window.innerWidth < 720) PER = 25;
      show("nt-panel", true);
      wire();
      return load();
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

    /*  A PASSWORD SOMEBODY ELSE CHOSE IS A TICKET, NOT A PASSWORD.
        -------------------------------------------------------------------
        Teacher logins are created with an initial password printed on a slip
        and handed over. That slip lives in a drawer, in a message, and in
        whatever printed it. So the account owes us one of its own, and until
        it pays, NOTHING else on this page is drawn - not the rail, not the
        panel, not the data.

        Gated here rather than on each screen because there are six screens
        and there will be more, and a gate somebody has to remember to add is
        a gate that is missing from the seventh.                            */
    if (identity.mustChange) {
      mustChangeGate(identity);
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
        current:  'md-notices',
        title:    'Notices to parents',
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
    try { notices.mount(identity); } catch (e) {
      if (window.console) console.warn("notices panel unavailable:", e);
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
