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
        Promise.resolve({ data: [{ role: "parent" }], error: null })
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
    /*  ITS OWN ESCAPE, AND THE REASON IT NEEDS ONE.
        This overlay is deliberately self-contained — its own styles, its own
        markup, nothing borrowed from the page it lands on — because it has to
        work on whichever screen a person happens to open first. The greeting
        was the one line that broke that rule: it called the module's esc(),
        which is a LOCAL of another function in every one of these files, so
        it threw "esc is not defined" the moment it tried to greet anybody by
        name. Every teacher login carries a name, and every one of them is
        created with must_change_password set, so this was the first thing
        all 39 would have met. The second time this project has had a fault
        that made every teacher login unusable; the first was four NULL
        columns in auth.users (db/094). Found 29 September by the parent
        portal's own test suite, which met it because a parent meets this
        screen before any other. */
    function pwEsc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
    }

    var shade = document.createElement("div");
    shade.id = "pw-shade";
    shade.setAttribute("role", "dialog");
    shade.setAttribute("aria-modal", "true");
    shade.setAttribute("aria-labelledby", "pw-gate-h");
    shade.innerHTML =
      '<section id="pw-gate">'
      + '<h2 id="pw-gate-h">Choose your own password</h2>'
      + "<p>Assalamu alaikum" + (who ? ", " + pwEsc(who) : "")
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
      + '<p class="pw-hint">There is no email reset on this login. If you '
      + "forget the new password, ring the madrasah office on 01204 535 997 "
      + "and they will set you a new one.</p>"
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
      //  current_password, IN SNAKE CASE, AND THE CASE IS THE WHOLE POINT.
      //
      //  The API is Go, and its struct field is
      //      CurrentPassword *string `json:"current_password,omitempty"`
      //  so current_password is the only spelling it reads.
      //
      //  One Supabase docs page shows updateUser({ currentPassword }) in
      //  JavaScript, and a newer client maps that to the snake_case field
      //  before sending. THE VENDORED CLIENT DOES NO SUCH MAPPING - its
      //  updateUser builds the body as Object.assign({}, attributes) with no
      //  whitelist and no transform. So camelCase went out as camelCase, the
      //  server saw no current_password at all, and said so.
      //
      //  Sending the snake_case name works either way: a client that maps
      //  camelCase still passes an unrecognised key straight through, and Go
      //  ignores JSON fields it does not know.
      sb.auth.updateUser({ password: a, current_password: now }).then(function (res) {
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
        //  DO NOT CLAIM TO KNOW WHICH. The API returns the SAME words when
        //  the current password is missing as when it is wrong, so "that is
        //  not the password on your slip" was a guess dressed as a fact - and
        //  it was the wrong guess: the password was right and the field name
        //  was not. Say what to check, not what went wrong.
        if (/current password|invalid.*credential|not correct/i.test(m)) {
          fail("That was not accepted. Check the password from your slip is "
               + "exactly as printed, capital letters and dashes included. If "
               + "it still will not take it, the office can set you a new one.");
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
     WHAT ALL THREE PARENT SCREENS SHARE.

     Prepended to each screen's module by tools/build_parent_screens.py, so the
     three generated files each carry one copy and none of them needs the
     others to be loaded. Browser JavaScript here is ES5 - var and function -
     because the phones some parents use do not parse anything newer, and the
     failure is a blank screen.

     THE REFUSALS A PARENT READS ARE THE DATABASE'S OWN WORDS. db/124 worded
     every refusal that can reach a parent ("You can tell us about tonight...",
     "The madrasah has already recorded that evening..."), so this file shows
     the message it is given for the two codes a deliberate refusal uses, and
     says something plain for anything else. It never shows a technical error:
     a parent who reads "42883 function does not exist" rings the office and
     cannot say what it said.
     ======================================================================= */
  var parentCommon = (function () {
    var OFFICE = "01204 535 997";
    var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                "Friday", "Saturday"];
    var MONTHS = ["January", "February", "March", "April", "May", "June",
                  "July", "August", "September", "October", "November",
                  "December"];

    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function el(id) { return document.getElementById(id); }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }

    //  yyyy-mm-dd -> {y, m, d, dow}. Built from the parts, never from
    //  new Date("2026-09-29"), which is midnight UTC and reads as the
    //  previous evening on a phone set to a timezone west of Greenwich.
    function parts(iso) {
      var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ""));
      if (!m) return null;
      var y = +m[1], mo = +m[2], d = +m[3];
      return { y: y, m: mo, d: d, dow: new Date(Date.UTC(y, mo - 1, d)).getUTCDay() };
    }
    function longDate(iso) {
      var p = parts(iso);
      return p ? DAYS[p.dow] + " " + p.d + " " + MONTHS[p.m - 1] : "";
    }
    function fullDate(iso) {
      var p = parts(iso);
      return p ? p.d + " " + MONTHS[p.m - 1] + " " + p.y : "";
    }

    //  What the register's four marks are called to a parent. "Excused" is
    //  what the register calls absent-with-a-reason; a parent has no use for
    //  the distinction, only for whether a reason was given.
    function markWord(mark) {
      if (mark === "present") return "Present";
      if (mark === "late") return "Late";
      if (mark === "absent") return "Absent";
      if (mark === "excused") return "Absent, with a reason";
      return "";
    }

    //  Turn whatever a call threw into a sentence a parent can act on.
    function sayError(e) {
      var code = e && e.code;
      var msg = (e && e.message) || "";
      if ((code === "42501" || code === "22023") && msg) return msg;
      if (!code) {
        return "We could not reach the madrasah just now. Please check your "
             + "connection and try again.";
      }
      return "Something went wrong on our side. Please try again in a moment, "
           + "or ring the office on " + OFFICE + ".";
    }
    //  This login is not a parent's (a member of staff who followed the wrong
    //  link, most likely). The database says "not yours" and nothing else.
    function isNotParent(e) {
      return !!e && e.code === "42501" && /not yours/i.test(e.message || "");
    }
    var NOT_PARENT =
      "This login is not set up as a parent's, so there is nothing to show "
      + "here. If you are a member of staff, sign in at the madrasah portal "
      + "instead. If you are a parent, please ring the office on " + OFFICE + ".";

    function call(name, args) {
      return sb.rpc(name, args || {}).then(function (res) {
        if (res.error) throw res.error;
        return res.data;
      });
    }

    //  The one thing every screen asks first: which children are mine.
    function family() { return call("parent_my_children"); }

    function fail(id, e) {
      var box = el(id);
      if (!box) return;
      box.textContent = isNotParent(e) ? NOT_PARENT : sayError(e);
      box.hidden = false;
    }

    return {
      OFFICE: OFFICE, esc: esc, el: el, show: show, longDate: longDate,
      fullDate: fullDate, markWord: markWord, sayError: sayError,
      isNotParent: isNotParent, NOT_PARENT: NOT_PARENT, call: call,
      family: family, fail: fail
    };
  })();

  /* =========================================================================
     MY CHILDREN

     WHAT A PARENT IS SHOWN, AND WHY THE LIST IS THIS LONG. The privacy notice
     and the whole point of the screen agree: a notice that says "tell us if
     this is wrong" is worthless if the parent cannot see what it says. So the
     medical and allergy details, the address and the phone numbers are all
     here, in words, next to the child's name.

     WHAT IS NOT SHOWN. The office's own notes on a child and on a household,
     the old system's reference, the fee rate and every internal id are not in
     what parent_my_children() returns (db/124 proves it), so this screen
     could not show them if it wanted to. The page says that some notes are
     kept back and how to ask for them, because leaving that out would make
     "everything the madrasah holds" a claim that is not quite true.

     "NOTHING RECORDED" IS SAID OUT LOUD for medical and allergies, because a
     blank cell could be a record that says none or a record nobody has ever
     filled in, and a parent is the only person who can tell which. SEND and
     EHCP detail are shown only where something is recorded: for most
     children there is nothing to say, and a row saying so on every card is
     noise that trains a parent to stop reading.

     CORRECTION IS A MESSAGE, NOT A FORM. Nothing on this screen edits the
     record. A parent's word is taken and written down by the office, so the
     record says who changed what. MESSAGES_HREF is where "tell us" goes: the
     messages screen (slice 4), which opens with a title already in the box.
     If it is ever emptied the page falls back to the telephone number, rather
     than linking to a page that is not there.
     ======================================================================= */
  var parentKids = (function () {
    var C = parentCommon;
    var MESSAGES_HREF = "messages/#details";   //  this screen is portal/parent/, the messages are one folder down

    function row(label, valueHtml, cls) {
      return '<div class="pt-row' + (cls ? " " + cls : "") + '"><dt>'
           + C.esc(label) + "</dt><dd>" + valueHtml + "</dd></div>";
    }
    function text(v) { return C.esc(v); }
    function recorded(v, none) {
      var s = v === null || v === undefined ? "" : String(v).replace(/^\s+|\s+$/g, "");
      return s ? C.esc(s) : '<span class="pt-none">' + C.esc(none) + "</span>";
    }
    function whereLine(kid) {
      var live = [], i, c, s;
      var cl = kid.classes || [];
      for (i = 0; i < cl.length; i++) if (cl[i].active) live.push(cl[i]);
      if (!live.length) {
        return "Not in a class at the moment. If that is not right, please ring the office.";
      }
      s = [];
      for (i = 0; i < live.length; i++) {
        c = live[i];
        s.push("<b>" + C.esc(c.name) + "</b>"
             + (c.teacher ? ", taught by " + C.esc(c.teacher) : ""));
      }
      return "In " + s.join(" and ");
    }
    function walkHome(v) {
      if (v === true) return "Yes, may walk home on their own";
      if (v === false) return "No, must be collected";
      return '<span class="pt-none">Not recorded</span>';
    }

    function card(kid, n) {
      var h = '<article class="pt-card" aria-labelledby="pk-h-' + n + '">'
            + '<h2 id="pk-h-' + n + '">' + C.esc(kid.first_name) + " "
            + C.esc(kid.last_name) + "</h2>"
            + '<p class="pt-where">' + whereLine(kid) + "</p><dl class=\"pt-dl\">";
      h += row("Date of birth", kid.date_of_birth ? C.esc(C.fullDate(kid.date_of_birth))
                                                   : '<span class="pt-none">Not recorded</span>');
      if (kid.gender) h += row("Gender", C.esc(kid.gender.charAt(0).toUpperCase() + kid.gender.slice(1)));
      h += row("Started at the madrasah", kid.joined_on ? C.esc(C.fullDate(kid.joined_on))
                                                        : '<span class="pt-none">Not recorded</span>');
      h += row("Day school", kid.school
                 ? C.esc(kid.school) + (kid.school_year ? ", " + C.esc(kid.school_year) : "")
                 : '<span class="pt-none">Not recorded</span>');
      if (kid.previous_madrasah) h += row("Previous madrasah", text(kid.previous_madrasah));
      h += row("Medical", recorded(kid.medical, "Nothing recorded"), "pt-key");
      h += row("Allergies", recorded(kid.allergies, "Nothing recorded"), "pt-key");
      if (kid.send_detail) h += row("Special educational needs", text(kid.send_detail));
      if (kid.ehcp_detail) h += row("Education, health and care plan", text(kid.ehcp_detail));
      h += row("Walking home", walkHome(kid.walk_home_consent));
      var addr = [];
      if (kid.address) addr.push(C.esc(kid.address));
      if (kid.postcode) addr.push(C.esc(kid.postcode));
      h += row("Address", addr.length ? addr.join("<br>") : '<span class="pt-none">Not recorded</span>');
      if (kid.email) h += row("Email for this child", text(kid.email));
      h += "</dl></article>";
      return h;
    }

    function people(gs) {
      var h = '<h2 class="pt-h">The people we would ring</h2>'
            + '<p class="pt-sub">Everyone the madrasah holds a contact for in your family. '
            + "If a number has changed, that is the first thing to tell us.</p>"
            + '<ul class="pt-people">';
      var i, g;
      for (i = 0; i < gs.length; i++) {
        g = gs[i];
        h += "<li><b>" + C.esc(g.full_name) + "</b>"
           + (g.is_me ? ' <span class="pt-chip">you</span>' : "")
           + (g.is_primary ? ' <span class="pt-chip pt-chip-quiet">main contact</span>' : "")
           + '<span class="pt-line">' + (g.phone ? C.esc(g.phone)
                : '<span class="pt-none">No phone number</span>') + "</span>"
           + (g.email ? '<span class="pt-line">' + C.esc(g.email) + "</span>" : "")
           + "</li>";
      }
      return h + "</ul>";
    }

    function help() {
      var h = '<h2 class="pt-h">Something wrong or out of date?</h2>'
            + "<p>Tell us and we will correct it. This page cannot be edited "
            + "directly, on purpose: when the office makes the change the record "
            + "keeps who changed it and when, and that protects your child's "
            + "details as well as ours.</p>";
      if (MESSAGES_HREF) {
        h += '<p class="pt-acts"><a class="btn btn-gold" href="'
           + C.esc(MESSAGES_HREF) + '">Message the office about this</a></p>';
      } else {
        h += '<p class="pt-soon"><b>Messaging the office from here is not available at the moment.</b> '
           + "Until then, please ring the office on <b>" + C.esc(C.OFFICE)
           + "</b>, or tell your child's teacher and they will pass it on.</p>";
      }
      h += '<p class="pt-fine">Some of the madrasah\'s own notes are not shown on '
         + "this page. You are entitled to ask for a full copy of what is held "
         + "about your family; ask the office and they will arrange it.</p>";
      return h;
    }

    function render(data) {
      var kids = (data && data.children) || [];
      var i, h = "";
      if (!kids.length) {
        C.show("pk-loading", false);
        C.fail("pk-error", { code: "42501", message: "There are no children on this login at the moment. Please ring the office on " + C.OFFICE + "." });
        return;
      }
      if (data.family_reference) {
        h += '<p class="pt-ref">Family reference <b>' + C.esc(data.family_reference) + "</b></p>";
      }
      for (i = 0; i < kids.length; i++) h += card(kids[i], i);
      C.el("pk-kids").innerHTML = h;
      C.el("pk-help").innerHTML = help();
      C.el("pk-people").innerHTML = people(data.guardians || []);
      C.show("pk-loading", false);
      C.show("pk-kids", true);
      C.show("pk-help", true);
      C.show("pk-people", true);
    }

    function mount() {
      var panel = C.el("pk-panel");
      if (!panel) return;
      panel.hidden = false;
      C.family().then(render, function (e) {
        C.show("pk-loading", false);
        C.fail("pk-error", e);
      });
    }

    return { mount: mount };
  })();

  function renderApp(identity) {
    //  Wait for the two deferred scripts, but only while the page is still
    //  being read. See the long note below the mount.
    if (document.readyState === "loading" &&
        !(window.AdminShell && window.ParentNav)) {
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
        current:  'pt-children',
        title:    'My children',
        area:     'Parents',
        sections: (window.ParentNav || {}).SECTIONS,
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
        run, a test with the network stubbed out), ParentNav would not exist
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
    try { parentKids.mount(identity); } catch (e) {
      if (window.console) console.warn("parent panel unavailable:", e);
    }
  }

  // Decides where to send someone once their password has been accepted.
  //  A parent has no second factor (see tools/screen_builder.py).
  function routeAfterPassword() {
    return loadIdentity().then(renderApp);
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
