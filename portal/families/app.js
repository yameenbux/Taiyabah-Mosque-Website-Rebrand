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

    var one = document.getElementById("pw-one");
    if (one && one.focus) { try { one.focus(); } catch (e) {} }

    function fail(m) {
      var e = document.getElementById("pw-err");
      if (e) { e.textContent = m; e.removeAttribute("hidden"); }
    }

    document.getElementById("pw-go").addEventListener("click", function () {
      var a = document.getElementById("pw-one").value;
      var b = document.getElementById("pw-two").value;
      if (a.length < 10) { fail("That is too short. Ten characters or more."); return; }
      if (a !== b) { fail("The two do not match."); return; }
      var go = document.getElementById("pw-go");
      go.disabled = true; go.textContent = "Saving…";
      sb.auth.updateUser({ password: a }).then(function (res) {
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
        fail("That could not be saved. " + (e && e.message ? e.message : ""));
      });
    });
  }


  /* =========================================================================
     FAMILIES

     330 households, 422 guardians, 552 children. This is the screen the
     Pupils roll has been pointing at since the register was imported, and
     the one the 56 sibling pairs have been waiting for.

     WHY A FAMILY AND NOT A PUPIL. A bill goes to a household, not to a
     child; a message about a closure goes to a parent, not to each of their
     four children separately; and "who may collect this child" is a question
     about a family. The madrasah's own language is families, so the screen is
     too.

     THE SAME SPLIT AS EVERY OTHER LIST HERE. The list says how many children
     a family has and whether there is a way to reach them. It does not carry
     telephone numbers or addresses. Those arrive when somebody opens ONE
     family, which is a deliberate act.

     WHAT THIS SCREEN IS FOR, in the order the office needs it:

       1. Find a family.
       2. See who is in it and who to ring.
       3. Fix the ones that are wrong - a child in the wrong family, a family
          with nobody to ring, two families that should be one.
       4. Take a list away, or write to them.
     ======================================================================= */
  var families = (function () {

    var ROWS  = [];           // every household, as last loaded
    var SUGG  = [];           // sibling pairs still to settle
    var OPEN  = null;         // the family on screen, or null
    var NEED  = "";           // which "needs attention" filter is on
    var PAGE  = 1;
    var PER   = 50;
    var SORT  = "";
    var SORTDIR = 1;
    var MOVING = null;        // the pupil being moved to another family
    var OPENEX = false;       // is the export panel open
    var ROLES = [];
    var busy = false;

    function el(id) { return document.getElementById(id); }
    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }
    function fail(msg) {
      var n = el("fa-error");
      if (!n) return;
      n.textContent = msg; n.hidden = false;
    }
    function clearFail() { show("fa-error", false); }

    // --- the figures --------------------------------------------------------
    function counts() {
      var c = { all: ROWS.length, noone: 0, nophone: 0, single: 0, nobody: 0 };
      for (var i = 0; i < ROWS.length; i++) {
        var r = ROWS[i];
        if (!r.has_phone && !r.has_email) c.noone++;
        else if (!r.has_phone) c.nophone++;
        if (r.pupils === 1) c.single++;
        //  NOT A TILE OF ITS OWN. On the real register 9 of the 10 families
        //  with no way to be reached have no parent recorded AT ALL, so a
        //  fifth counter would have shown almost the same families twice and
        //  invited somebody to work through both lists. It is a sub-line on
        //  the tile it belongs to.
        if (!r.guardians) c.nobody++;
      }
      return c;
    }

    function drawFigures() {
      var host = el("fa-figs");
      if (!host) return;
      var c = counts();
      function fig(key, n, label, sub, tone) {
        var on = NEED === key;
        return '<button type="button" class="fa-fig' + (tone ? " " + tone : "")
             + (on ? " is-on" : "") + '" data-need="' + esc(key) + '"'
             + (n ? "" : " disabled") + '><b>' + esc(n) + "</b><span>"
             + esc(label) + "</span>"
             + (sub ? "<small>" + esc(sub) + "</small>" : "") + "</button>";
      }
      //  FOUR TILES, NOT FIVE.
      //
      //  The fifth was "Four or more children" — 18 families on the real
      //  register, and nothing anybody does about it. It also made the row
      //  wrap 4 + 1, leaving one tile stranded on a line of its own. A
      //  counter with no action behind it is decoration, and decoration is
      //  what pushed the first family below the fold on a phone.
      host.innerHTML =
          fig("", c.all, "Families", "on the register")
        //  NOBODY TO RING IS THE ONE THAT MATTERS. A family with no
        //  telephone and no email cannot be told their child is unwell.
        + fig("noone", c.noone, "No way to reach them",
              c.nobody ? (c.nobody === c.noone
                            ? "no parent recorded at all"
                            : c.nobody + " have no parent recorded at all")
                       : "no phone, no email",
              c.noone ? "bad" : "")
        + fig("nophone", c.nophone, "Email only",
              "slower to reach", c.nophone ? "warn" : "")
        + fig("single", c.single, "One child", "no brothers or sisters here", "");
    }

    // --- the sibling pairs --------------------------------------------------
    var SUGGOPEN = false;

    function drawSuggestions() {
      var host = el("fa-sugg");
      if (!host) return;
      if (!SUGG.length) { host.hidden = true; host.innerHTML = ""; return; }
      host.hidden = false;
      //  THESE ARRIVED WITH THE REGISTER AND THIS IS THEIR HOME.
      //  The Pupils roll shows a one-line pointer here; this is the screen
      //  that can actually do something about them, because joining two
      //  families is family work.
      var h = '<div class="fa-sugg-top"><h3>'
        + (SUGG.length === 1 ? "One pair of children might be siblings"
                             : SUGG.length + " pairs of children might be siblings")
        + "</h3>"
        + '<button type="button" class="fa-linkish" id="fa-sugg-toggle">'
        + (SUGGOPEN ? "Hide these" : "Settle these") + "</button></div>";
      if (!SUGGOPEN) { host.innerHTML = h; return; }
      //  ONLY AN ADMINISTRATOR CAN SETTLE ONE, so only an administrator is
      //  shown the buttons.
      //
      //  settle_sibling_suggestion() raises 42501 — "Only an administrator who
      //  has completed two-step may join two families" — and the first version
      //  of this card showed both buttons to every member of madrasah staff.
      //  A teacher would have pressed "One family", waited, and been handed a
      //  database permission error. Offering somebody a button that cannot work
      //  for them is worse than not offering it: they reasonably conclude the
      //  system is broken rather than that the job is not theirs.
      var mayJoin = ROLES.indexOf("admin") !== -1;
      h += '<p class="fa-sub">They share a surname and an address, but no '
        + "parent’s telephone number or email address appears on both records, "
        + "so they have not been put in one family. Somebody who knows them "
        + "should say."
        + (mayJoin
            ? " Whichever you choose is written down against your name.</p>"
            : " Joining two families is an administrator’s job, so these are "
              + "here to be read rather than settled — tell the office "
              + "which of them are brothers and sisters.</p>")
        + '<div class="fa-sugg-rows">';
      for (var i = 0; i < SUGG.length; i++) {
        var s = SUGG[i];
        h += '<div class="fa-sugg-row" data-sugg="' + esc(s.id) + '">'
           + "<div><strong>" + esc(s.a.name) + "</strong><span class=\"fa-q\">"
           + esc(s.a.family || "no family") + "</span></div>"
           + '<div class="fa-amp">and</div>'
           + "<div><strong>" + esc(s.b.name) + "</strong><span class=\"fa-q\">"
           + esc(s.b.family || "no family") + "</span></div>"
           + '<div class="fa-sugg-acts">'
           + (mayJoin
               ? '<button type="button" class="btn btn-ghost" data-join="1">One family</button>'
                 + '<button type="button" class="btn btn-ghost" data-join="0">Not related</button>'
               : '<span class="fa-q">' + esc(s.why || "same surname and address")
                 + "</span>")
           + "</div></div>";
      }
      host.innerHTML = h + "</div>";
    }

    // --- the list -----------------------------------------------------------
    function matches(r) {
      var q = (el("fa-q") ? el("fa-q").value : "").trim().toLowerCase();
      if (NEED === "noone"   && (r.has_phone || r.has_email)) return false;
      if (NEED === "nophone" && (r.has_phone || !r.has_email)) return false;
      if (NEED === "single"  && r.pupils !== 1) return false;
      if (!q) return true;
      return (r.name + " " + (r.reference || "") + " " + (r.note || ""))
             .toLowerCase().indexOf(q) !== -1;
    }

    function cmp(a, b) {
      var x, y;
      if (SORT === "children")   { x = a.pupils; y = b.pupils; }
      else if (SORT === "ref")   { x = a.reference; y = b.reference; }
      else                       { x = a.name; y = b.name; }
      var xm = (x === null || x === undefined || x === "");
      var ym = (y === null || y === undefined || y === "");
      if (xm && ym) return 0;
      if (xm) return 1;            // missing last, both ways. See pupils.
      if (ym) return -1;
      if (typeof x === "string") return x.localeCompare(y) * SORTDIR;
      return (x < y ? -1 : x > y ? 1 : 0) * SORTDIR;
    }

    function filtered() {
      var out = [];
      for (var i = 0; i < ROWS.length; i++) {
        if (matches(ROWS[i])) out.push(ROWS[i]);
      }
      if (SORT) out.sort(cmp);
      return out;
    }
    function resetPage() { PAGE = 1; }

    function drawRows() {
      var body = el("fa-rows");
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
        //  WHETHER, NOT WHAT. Whether somebody can be reached, not the
        //  number. The number is on the family's own record, which is a
        //  deliberate thing to open.
        var reach = (!r.has_phone && !r.has_email)
          ? '<span class="fa-bad">Nobody to ring</span>'
          : (!r.has_phone ? '<span class="fa-warn-t">Email only</span>'
                          : '<span class="fa-ok">Phone</span>');
        //  EVERY CELL CARRIES ITS OWN COLUMN NAME.
        //  On a phone the table becomes a stack of cards and the header row is
        //  gone, so "2" and "1" sitting next to each other mean nothing
        //  without them. The CSS prints these; a screen reader gets them for
        //  free either way.
        out.push('<tr class="fa-row" tabindex="0" data-id="' + esc(r.id) + '">'
          + '<td class="fa-ref" data-label="Reference">'
          + esc(r.reference || "—") + "</td>"
          + '<td class="fa-who" data-label="Family">' + esc(r.name)
          + (r.note ? '<span class="fa-q">' + esc(r.note) + "</span>" : "") + "</td>"
          + '<td data-label="Children">' + esc(r.pupils)
          + (r.former ? '<span class="fa-q">+' + esc(r.former) + " left</span>" : "")
          + "</td>"
          + '<td data-label="Guardians">' + esc(r.guardians) + "</td>"
          + '<td data-label="Who to ring">' + reach + "</td>"
          + '<td class="fa-acts"><div class="fa-acts-wrap">'
          + '<button type="button" class="fa-open" aria-label="Open '
          + esc(r.name) + '">Open</button></div></td></tr>');
      }
      body.innerHTML = out.join("");
      var empty = el("fa-empty");
      if (empty) {
        empty.hidden = rows.length > 0;
        empty.textContent = ROWS.length
          ? "No family matches that."
          : "There are no families on the register yet.";
      }
      var c = el("fa-count");
      if (c) {
        var all = (rows.length === ROWS.length);
        c.textContent = rows.length === 0 ? "no families"
          : rows.length <= PER
            ? (rows.length === 1 ? "1 family" : rows.length + " families")
              + (all ? "" : " of " + ROWS.length)
            : "Showing " + (from + 1) + "–"
              + Math.min(from + PER, rows.length) + " of " + rows.length
              + (all ? "" : " matching");
      }
      drawPager(pages);
      drawExport();
      drawSummary();
    }

    function drawPager(pages) {
      var hosts = document.querySelectorAll(".fa-pager");
      if (!hosts.length) return;
      var h = "", p, i;
      if (pages > 1) {
        h += '<div class="fa-pages">'
           + '<button type="button" class="fa-page" data-page="' + (PAGE - 1)
           + '"' + (PAGE === 1 ? " disabled" : "") + ">Back</button>";
        var shown = [];
        for (p = 1; p <= pages; p++) {
          if (p === 1 || p === pages || Math.abs(p - PAGE) <= 1) shown.push(p);
        }
        var last = 0;
        for (i = 0; i < shown.length; i++) {
          p = shown[i];
          if (last && p - last > 1) h += '<span class="fa-gap">…</span>';
          h += '<button type="button" class="fa-page'
             + (p === PAGE ? " is-on" : "") + '" data-page="' + p + '"'
             + (p === PAGE ? ' aria-current="page"' : "")
             + ' aria-label="Page ' + p + '">' + p + "</button>";
          last = p;
        }
        h += '<button type="button" class="fa-page" data-page="' + (PAGE + 1)
           + '"' + (PAGE === pages ? " disabled" : "") + ">Next</button></div>";
      }
      h += '<div class="fa-pers"><span>Per page</span>';
      var opts = [25, 50, 100];
      for (i = 0; i < opts.length; i++) {
        h += '<button type="button" class="fa-per'
           + (PER === opts[i] ? " is-on" : "") + '" data-per="' + opts[i]
           + '">' + opts[i] + "</button>";
      }
      hosts[0].innerHTML = h + "</div>";
      for (i = 1; i < hosts.length; i++) hosts[i].innerHTML = hosts[0].innerHTML;
    }

    function activeFilters() {
      var n = 0;
      var q = el("fa-q");
      if (q && q.value.trim()) n++;
      if (NEED) n++;
      return n;
    }

    function drawSummary() {
      var n = activeFilters(), b = el("fa-clearall");
      if (b) {
        b.hidden = (n === 0);
        b.textContent = n === 1 ? "Clear 1 filter" : "Clear " + n + " filters";
      }
      var x = el("fa-clearq"), q = el("fa-q");
      if (x && q) x.hidden = !q.value;
    }

    function clearAll() {
      var q = el("fa-q");
      if (q) q.value = "";
      NEED = ""; SORT = ""; SORTDIR = 1;
      resetPage(); closeRecord(); drawFigures(); drawRows(); markSort();
    }

    function markSort() {
      var bs = document.querySelectorAll(".fa-sortable");
      for (var i = 0; i < bs.length; i++) {
        var on = bs[i].getAttribute("data-sort") === SORT;
        bs[i].setAttribute("aria-sort",
          on ? (SORTDIR === 1 ? "ascending" : "descending") : "none");
        bs[i].className = "fa-sortable" + (on ? " is-on" : "");
      }
    }

    // --- taking a list away -------------------------------------------------
    function exportFilter() {
      var f = {};
      if (NEED) f.need = NEED;
      return f;
    }

    function csv(rows, head) {
      if (!rows.length) return "";
      var cols = [], k;
      for (k in rows[0]) { if (rows[0].hasOwnProperty(k)) cols.push(k); }
      function cell(v) {
        if (v === null || v === undefined) return "";
        v = String(v);
        return /[",\n\r]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
      }
      var out = [];
      if (head) {
        out.push(cell(head.masjid)); out.push(cell(head.what));
        out.push(cell(head.taken));  out.push(cell(head.filter));
        out.push(cell(head.count));  out.push(cell(head.note));
        out.push("");
      }
      out.push(cols.join(","));
      for (var i = 0; i < rows.length; i++) {
        var line = [];
        for (var j = 0; j < cols.length; j++) line.push(cell(rows[i][cols[j]]));
        out.push(line.join(","));
      }
      return "﻿" + out.join("\r\n");
    }

    function takeFile(detail) {
      if (busy) return;
      busy = true; clearFail();
      sb.rpc("madrasah_family_export",
             { p_detail: !!detail, p_filter: exportFilter() })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var rows = (res.data && res.data.rows) || [];
          var blob = new Blob([csv(rows, res.data && res.data.heading)],
                              { type: "text/csv;charset=utf-8" });
          var a = document.createElement("a");
          a.href = URL.createObjectURL(blob);
          a.download = "Taiyabah-Masjid-"
                     + (detail ? "families-contacts-" : "families-")
                     + new Date().toISOString().slice(0, 10) + ".csv";
          document.body.appendChild(a); a.click(); document.body.removeChild(a);
          setTimeout(function () { URL.revokeObjectURL(a.href); }, 4000);
          OPENEX = false; drawExport();
        })["catch"](function (e) {
          fail("That file could not be made. " + (e && e.message ? e.message : ""));
        })["finally"](function () { busy = false; });
    }

    function drawExport() {
      var host = el("fa-export");
      if (!host) return;
      var isAdmin = ROLES.indexOf("admin") !== -1;
      host.innerHTML = '<button type="button" class="btn btn-ghost"'
        + ' data-take="open" aria-expanded="' + (OPENEX ? "true" : "false")
        + '">Export…</button>';
      var panel = el("fa-expanel");
      if (!panel) return;
      if (!OPENEX) { panel.hidden = true; panel.innerHTML = ""; return; }
      panel.hidden = false;
      var n = filtered().length;
      var h = '<p class="fa-ex-lead">Two ways to take the ' + esc(n)
            + (n === 1 ? " family" : " families") + " currently listed out of "
            + "the system.</p><div class=\"fa-ex-opts\">"
        + '<button type="button" class="fa-ex-opt" data-take="plain">'
        + "<strong>Family list</strong><span>Reference, family name, how many "
        + "children, how many guardians. No contact details. Anyone on the "
        + "madrasah staff may take this.</span></button>";
      if (isAdmin) {
        h += '<button type="button" class="fa-ex-opt is-guarded" data-take="ask">'
          + "<strong>With contact details</strong><span>Adds the first "
          + "guardian’s name, telephone number, email address and the "
          + "family’s address. Administrators only, and your name is "
          + "recorded against the file.</span></button>";
      } else {
        h += '<p class="fa-ex-note">A list including telephone numbers and '
          + "addresses is available to administrators only.</p>";
      }
      panel.innerHTML = h + "</div>";
    }

    // --- one family ---------------------------------------------------------
    /* -----------------------------------------------------------------------
       ONE THING ON SCREEN AT A TIME.

       The first build put the family's record after the table, which meant
       clicking a family scrolled you fifty rows down to a card you could not
       see arrive. Worse, it left a mother's mobile number and her home
       address sitting on the same screen as a list of two hundred other
       families — the thing this screen's whole list/record split exists to
       avoid.

       So opening a family puts the list away. The office deals with one
       family, then comes back. For somebody who is not confident with a
       computer that is the difference between a screen and a filing cabinet.

       AND IT GETS A URL. ?id= is pushed into the address bar, so a family can
       be bookmarked, refreshed without losing your place, and sent to the
       other administrator in a message. It costs fifteen lines here and saves
       building a second screen for it.
       --------------------------------------------------------------------- */
    function listOnScreen(on) {
      show("fa-list-bk", on);
      show("fa-figs", on);
      //  The sibling card only comes back if there was one to begin with.
      show("fa-sugg", on && SUGG.length > 0);
      //  The row of links to Pupils and to Families & fees STAYS. It is
      //  navigation, not list furniture, and somebody looking at a family is
      //  as likely to want the child's record next as anything else.
      //
      //  (It also has no id — it is `.fa-head`, a class — so an earlier
      //  show("fa-head", on) here did nothing at all and looked like it did.
      //  A line that silently no-ops is worse than no line: the next person
      //  reads it as a guarantee.)
    }

    function closeRecord(keepUrl) {
      OPEN = null; MOVING = null;
      var n = el("fa-record");
      if (n) { n.hidden = true; n.innerHTML = ""; }
      listOnScreen(true);
      if (!keepUrl && window.history && history.pushState
          && window.location.search) {
        history.pushState({}, "", window.location.pathname);
      }
    }

    function openFamily(id, replace) {
      if (!id || busy) return;
      busy = true; clearFail();
      sb.rpc("madrasah_household_one", { p_id: id }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        if (!res.data) throw new Error("There is no family with that reference.");
        drawRecord(res.data);
        if (window.history && history.pushState) {
          var url = window.location.pathname + "?id=" + encodeURIComponent(id);
          if (replace) { history.replaceState({ id: id }, "", url); }
          else if (window.location.search !== "?id=" + encodeURIComponent(id)) {
            history.pushState({ id: id }, "", url);
          }
        }
      })["catch"](function (e) {
        //  A FAMILY THAT WILL NOT OPEN MUST NOT LEAVE A BLANK SCREEN. If the
        //  id in the address bar is stale — a family joined into another one
        //  since the link was sent — the list comes back rather than nothing.
        listOnScreen(true);
        fail("That family would not open. " + (e && e.message ? e.message : ""));
      })["finally"](function () { busy = false; });
    }

    function wantedId() {
      var m = /[?&]id=([^&]+)/.exec(window.location.search || "");
      return m ? decodeURIComponent(m[1]) : "";
    }

    function drawRecord(f) {
      var host = el("fa-record");
      if (!host || !f) return;
      OPEN = f;
      host.hidden = false;
      listOnScreen(false);

      var pupils = (f.pupils || []);
      var kids = pupils.length
        ? pupils.map(function (p) {
            return '<li><a class="fa-kid" href="../pupil/?id='
              + encodeURIComponent(p.id) + '">' + esc(p.name) + "</a>"
              + (p.left_on ? '<span class="fa-q">left ' + esc(p.left_on) + "</span>"
                           : "")
              + '<button type="button" class="fa-linkish fa-move" data-move="'
              + esc(p.id) + '">Move to another family</button></li>';
          }).join("")
        : '<li class="fa-q">No children are in this family.</li>';

      var gs = (f.guardians || []);
      var guardians = gs.length
        ? gs.map(function (g) {
            return '<div class="fa-guardian"><strong>' + esc(g.full_name) + "</strong>"
              + (g.is_primary ? ' <span class="fa-pill">first call</span>' : "")
              + '<div class="fa-q">'
              + (g.phone ? '<a href="tel:' + esc(g.phone) + '">' + esc(g.phone) + "</a>" : "")
              + (g.phone && g.email ? " · " : "")
              + (g.email ? '<a href="mailto:' + esc(g.email) + '">' + esc(g.email) + "</a>" : "")
              + (!g.phone && !g.email ? "no telephone and no email address" : "")
              + "</div></div>";
          }).join("")
        //  SAID IN WORDS, not left as an empty space somebody has to notice.
        : '<p class="fa-warn">Nobody is recorded for this family. If something '
          + "happened this afternoon there is no one to ring.</p>";

      host.innerHTML =
        '<button type="button" class="fa-back" id="fa-back">'
        + "\u2190 Back to the families</button>"
        + '<div class="fa-rec-head"><div><h3>' + esc(f.name) + "</h3>"
        + '<p class="fa-sub">' + esc(f.reference || "no reference")
        + (f.note ? " · " + esc(f.note) : "") + "</p></div>"
        + '<div class="fa-rec-acts">'
        + '<button class="btn btn-ghost" id="fa-letter" type="button">Write to them</button>'
        + "</div></div>"
        + '<div class="fa-two">'
        +   "<div><h4>Children</h4><ul class=\"fa-list\">" + kids + "</ul></div>"
        +   "<div><h4>Who to ring</h4>" + guardians + "</div>"
        + "</div>"
        + '<div class="fa-move-box" id="fa-move-box" hidden></div>'
        + '<div class="fa-letter-box" id="fa-letter-box" hidden></div>';
      //  STRAIGHT TO THE TOP. scrollIntoView on the card left the masthead
      //  above it off screen, so the page looked like it had jumped rather
      //  than changed.
      window.scrollTo(0, 0);
    }

    // --- moving a child between families ------------------------------------
    function drawMove() {
      var box = el("fa-move-box");
      if (!box) return;
      if (!MOVING) { box.hidden = true; box.innerHTML = ""; return; }
      box.hidden = false;
      var name = "";
      for (var i = 0; i < (OPEN.pupils || []).length; i++) {
        if (OPEN.pupils[i].id === MOVING) name = OPEN.pupils[i].name;
      }
      //  MOVING A CHILD IS A REAL CHANGE. It moves who gets their bill, who
      //  is telephoned about them, and which siblings they are counted with.
      //  So it says what it will do and asks for the family by name.
      var h = "<h4>Move " + esc(name) + " to another family</h4>"
        + '<p class="fa-sub">This changes who is billed for this child, who is '
        + "telephoned about them, and which brothers and sisters they are "
        + "counted with. It is written down against your name.</p>"
        + '<label class="fa-fld"><span>Which family?</span>'
        + '<select id="fa-move-to"><option value="">Choose a family…</option>';
      var list = ROWS.slice(0).sort(function (a, b) {
        return String(a.name).localeCompare(String(b.name)); });
      for (var j = 0; j < list.length; j++) {
        if (list[j].id === OPEN.id) continue;
        h += '<option value="' + esc(list[j].id) + '">' + esc(list[j].name)
          + " (" + esc(list[j].reference) + ")</option>";
      }
      h += "</select></label>"
        + '<div class="fa-move-acts">'
        + '<button type="button" class="btn btn-gold" id="fa-move-go">Move this child</button>'
        + '<button type="button" class="btn btn-ghost" id="fa-move-no">Cancel</button>'
        + "</div>";
      box.innerHTML = h;
    }

    function doMove() {
      var sel = el("fa-move-to");
      if (!sel || !sel.value || busy) return;
      //  THE FAMILY TO COME BACK TO IS CAPTURED NOW, and reopened only once
      //  `busy` is down again.
      //
      //  The first version reopened it inside the .then, which reads correctly
      //  and does nothing at all: openFamily() begins `if (!id || busy) return`
      //  and busy is still true until .finally runs, so the move succeeded, the
      //  list reloaded, and the record on screen kept showing the child in the
      //  family they had just been moved out of. Nothing errored. The only
      //  symptom was a screen that looked like the button had not worked.
      var back = OPEN ? OPEN.id : null;
      busy = true;
      sb.rpc("set_pupil_household", { p_pupil: MOVING, p_household: sel.value })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          MOVING = null;
          return load();
        })["catch"](function (e) {
          fail("That child could not be moved. " + (e && e.message ? e.message : ""));
        })["finally"](function () {
          busy = false;
          if (back) openFamily(back);
        });
    }

    // --- writing to a family ------------------------------------------------
    function drawLetter() {
      var box = el("fa-letter-box");
      if (!box || !OPEN) return;
      box.hidden = false;
      var gs = (OPEN.guardians || []);
      var to = [];
      for (var i = 0; i < gs.length; i++) {
        if (gs[i].email) to.push(gs[i].email);
      }
      //  A LETTER, NOT A MAIL MERGE. One family, on headed paper, for the
      //  things that are not an email: a fees reminder that has gone too far,
      //  a meeting with the parents, a formal notice. The madrasah's address
      //  and the date come from the system so nobody retypes them.
      var when = new Date();
      var MM = ["January","February","March","April","May","June","July",
                "August","September","October","November","December"];
      var dateSaid = when.getDate() + " " + MM[when.getMonth()] + " "
                   + when.getFullYear();
      var kids = (OPEN.pupils || []).map(function (p) { return p.name; }).join(", ");
      box.innerHTML = "<h4>Write to this family</h4>"
        + '<div class="fa-letter-pick">'
        + '<button type="button" class="fa-ex-opt" data-letter="general">'
        + "<strong>A letter on headed paper</strong><span>Opens a printable "
        + "letter addressed to this family, with the madrasah’s details "
        + "and today’s date already on it. Type what you need and "
        + "print.</span></button>"
        + (to.length
            ? '<button type="button" class="fa-ex-opt" data-letter="email">'
              + "<strong>An email</strong><span>Opens your mail program with "
              + esc(to.join(", ")) + " already in the To line.</span></button>"
            : '<p class="fa-ex-note">This family has no email address on file, '
              + "so only a letter is possible.</p>")
        + "</div>"
        + '<div class="fa-print" id="fa-print" aria-hidden="true"></div>';
      box.setAttribute("data-to", to.join(","));
      box.setAttribute("data-kids", kids);
      box.setAttribute("data-date", dateSaid);
    }

    function printLetter() {
      var box = el("fa-letter-box"), host = el("fa-print");
      if (!box || !host || !OPEN) return;
      var addr = (OPEN.note || "").split(",").map(function (s) {
        return esc(s.trim()); }).filter(Boolean).join("<br>");
      var gs = (OPEN.guardians || []);
      var to = gs.length ? esc(gs[0].full_name) : esc(OPEN.name);
      host.innerHTML =
        '<div class="lt-head"><img class="lt-logo" src="../../img/masjid-logo.png" alt="">'
        + "<div><h1>Taiyabah Masjid</h1><p>Madrasah</p></div>"
        + '<div class="lt-from"><p>Bolton Central Islamic Society</p>'
        + "<p>Registered charity 1041569</p>"
        + "<p>01204 535 997</p></div></div>"
        + '<p class="lt-to">' + to + (addr ? "<br>" + addr : "") + "</p>"
        + '<p class="lt-date">' + esc(box.getAttribute("data-date")) + "</p>"
        + '<p class="lt-re"><strong>Re: '
        + esc(box.getAttribute("data-kids") || OPEN.name) + "</strong></p>"
        + '<div class="lt-body" contenteditable="true">'
        + "<p>Assalamu alaikum,</p><p>&nbsp;</p><p>&nbsp;</p><p>&nbsp;</p>"
        + "<p>Jazakumullahu khairan,</p><p>&nbsp;</p>"
        + "<p>Taiyabah Masjid Madrasah</p></div>";
      document.body.appendChild(host);
      document.body.className += " printing-letter";
      try { window.print(); }
      finally {
        document.body.className =
          document.body.className.replace(/\s*printing-letter/, "");
        box.appendChild(host);
      }
    }

    // --- loading ------------------------------------------------------------
    function load() {
      return Promise.all([
        sb.rpc("madrasah_household_list", { p_q: null }),
        sb.rpc("madrasah_sibling_suggestions_list")
      ]).then(function (res) {
        if (res[0].error) throw new Error(res[0].error.message);
        var d = res[0].data;
        ROWS = (d && d.rows) || (d instanceof Array ? d : []);
        if (!(ROWS instanceof Array)) ROWS = [];
        SUGG = (res[1].data && res[1].data.rows) || [];
        drawFigures(); drawSuggestions(); drawRows();
      })["catch"](function (e) {
        fail("The families would not load. " + (e && e.message ? e.message : ""));
      });
    }

    function wire() {
      var q = el("fa-q");
      function refilter() { closeRecord(); resetPage(); drawRows(); }
      if (q) q.addEventListener("input", refilter);

      var cq = el("fa-clearq");
      if (cq) cq.addEventListener("click", function () {
        var n = el("fa-q");
        if (n) { n.value = ""; n.focus(); }
        refilter();
      });
      var ca = el("fa-clearall");
      if (ca) ca.addEventListener("click", clearAll);

      var figs = el("fa-figs");
      if (figs) figs.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-need]") : null;
        if (!b) return;
        NEED = (NEED === b.getAttribute("data-need")) ? "" : b.getAttribute("data-need");
        closeRecord(); resetPage(); drawFigures(); drawRows();
      });

      var head = document.querySelector("#fa-table thead");
      if (head) head.addEventListener("click", function (e) {
        var s = e.target.closest ? e.target.closest(".fa-sortable") : null;
        if (!s) return;
        var k = s.getAttribute("data-sort");
        if (SORT === k) { SORTDIR = -SORTDIR; } else { SORT = k; SORTDIR = 1; }
        resetPage(); closeRecord(); drawRows(); markSort();
      });

      var pagers = document.querySelectorAll(".fa-pager");
      for (var pi = 0; pi < pagers.length; pi++) {
        pagers[pi].addEventListener("click", function (e) {
          var pb = e.target.closest ? e.target.closest(".fa-page") : null;
          var pr = e.target.closest ? e.target.closest(".fa-per") : null;
          if (pb && !pb.disabled) {
            PAGE = parseInt(pb.getAttribute("data-page"), 10) || 1;
            closeRecord(); drawRows();
            var top = el("fa-roll");
            if (top && top.scrollIntoView) top.scrollIntoView(true);
          } else if (pr) {
            PER = parseInt(pr.getAttribute("data-per"), 10) || 50;
            resetPage(); closeRecord(); drawRows();
          }
        });
      }

      //  TWO ELEMENTS, ONE HANDLER.
      //
      //  The Export button and the panel of choices used to be nested
      //  together, so one delegated listener on the outer block caught both.
      //  The panel moved out when the button joined the count's row, and the
      //  listener silently stopped catching the choices: pressing "Family
      //  list" did nothing whatsoever. Nothing errored, and the only reason it
      //  was caught was that the suite waits for a download that never
      //  arrived. Both are wired now, by name.
      function takeClick(e) {
        var b = e.target.closest ? e.target.closest("[data-take]") : null;
        if (!b) return;
        var what = b.getAttribute("data-take");
        if (what === "open")       { OPENEX = !OPENEX; drawExport(); }
        else if (what === "plain") { takeFile(false); }
        else if (what === "ask")   { takeFile(true); }
      }
      var ex = el("fa-export-bk");
      if (ex) ex.addEventListener("click", takeClick);
      var exp = el("fa-expanel");
      if (exp) exp.addEventListener("click", takeClick);

      var body = el("fa-rows");
      if (body) {
        body.addEventListener("click", function (e) {
          var tr = e.target.closest ? e.target.closest("tr.fa-row") : null;
          if (tr) openFamily(tr.getAttribute("data-id"));
        });
        body.addEventListener("keydown", function (e) {
          if (e.key !== "Enter" && e.key !== " ") return;
          var tr = e.target.closest ? e.target.closest("tr.fa-row") : null;
          if (tr) { e.preventDefault(); openFamily(tr.getAttribute("data-id")); }
        });
      }

      var rec = el("fa-record");
      if (rec) rec.addEventListener("click", function (e) {
        var t = e.target;
        if (t.id === "fa-back")    { closeRecord(); return; }
        if (t.id === "fa-letter")  { drawLetter(); return; }
        if (t.id === "fa-move-go") { doMove(); return; }
        if (t.id === "fa-move-no") { MOVING = null; drawMove(); return; }
        var mv = t.closest ? t.closest(".fa-move") : null;
        if (mv) { MOVING = mv.getAttribute("data-move"); drawMove(); return; }
        var lt = t.closest ? t.closest("[data-letter]") : null;
        if (lt) {
          if (lt.getAttribute("data-letter") === "general") { printLetter(); }
          else {
            var box = el("fa-letter-box");
            window.location.href = "mailto:"
              + encodeURIComponent(box.getAttribute("data-to") || "");
          }
        }
      });

      wireHistory();

      var sg = el("fa-sugg");
      if (sg) sg.addEventListener("click", function (e) {
        if (e.target.id === "fa-sugg-toggle") {
          SUGGOPEN = !SUGGOPEN; drawSuggestions(); return;
        }
        var b = e.target.closest ? e.target.closest("[data-join]") : null;
        if (!b || busy) return;
        var rowEl = b.closest("[data-sugg]");
        if (!rowEl) return;
        busy = true;
        sb.rpc("settle_sibling_suggestion", {
          p_id: rowEl.getAttribute("data-sugg"),
          p_join: b.getAttribute("data-join") === "1"
        }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          return load();
        })["catch"](function (err) {
          fail("That could not be settled. " + (err && err.message ? err.message : ""));
        })["finally"](function () { busy = false; });
      });
    }

    function wireHistory() {
      if (!window.history || !history.pushState) return;
      window.addEventListener("popstate", function (e) {
        var id = (e.state && e.state.id) || wantedId();
        //  keepUrl: the browser has already changed the address bar, and
        //  pushing another entry here would make Back need two presses.
        if (id) { openFamily(id, true); } else { closeRecord(true); }
      });
    }

    function mount(identity) {
      var roles = (identity && identity.roles) || [];
      if (roles.indexOf("admin") === -1 && roles.indexOf("madrasah") === -1) {
        var na = el("app-noaccess");
        if (na) {
          na.textContent = "This area is for madrasah staff. If you should be "
            + "able to see the families, ask the office to add you.";
          na.hidden = false;
        }
        return;
      }
      ROLES = roles;
      //  TWENTY-FIVE TO A PAGE ON A PHONE.
      //  Fifty families as cards is 13.5 screens of thumb; fifty as table rows
      //  on a desk is four. Same number, different amount of scrolling, so it
      //  is not the same default. Whoever wants fifty can still ask for it.
      if (window.innerWidth && window.innerWidth < 720) PER = 25;
      show("fa-panel", true);
      wire();
      return load().then(function () {
        var want = wantedId();
        if (want) openFamily(want, true);
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
        current:  'md-families',
        title:    'Families',
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
    try { families.mount(identity); } catch (e) {
      if (window.console) console.warn("families panel unavailable:", e);
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
