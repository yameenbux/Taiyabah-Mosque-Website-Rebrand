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
     PROGRESS NOTES - A TEACHER RECORDS HOW A CHILD IS GETTING ON

     NOT EVERYTHING A TEACHER WRITES IS FOR A FAMILY. Each entry has two notes
     and a choice, and this screen keeps them apart in words as well as in the
     data:
       note for the parent   read by the family - but ONLY if the entry is shared
       your own note         staff only; never shown to a family, whatever is chosen
       share                 an explicit choice, two radio buttons that each say
                             what they do. It starts on "not shared" for a new
                             entry and on whatever the entry already is when
                             one is amended, so publishing is never a default.

     THE DATABASE DECIDES WHO MAY DO ANY OF THIS. Nothing here is a permission:
     progress_my_classes() returns the classes this person may write for and no
     others, and every later call re-checks the pupil AND the class. A refusal is
     {allowed:false}, which this screen turns into a sentence and never into an
     empty list. A teacher who guesses another child's id is refused by
     Postgres, not by this page choosing not to draw a link.

     A LIST SAYS WHETHER, THE CHILD SAYS WHAT. The class list shows how many
     entries there are and how many are shared; what they say is on the child.

     THE REFUSALS THE DATABASE WORDS (22023) ARE SHOWN AS WRITTEN: a date not yet
     come, a field too long, an entry with nothing in it, an attempt to share an
     entry that has nothing for a family to read.
     ======================================================================= */
  var teacherProgress = (function () {
    var CLASSES = [];
    var CLASS = null;         //  {id, name}
    var KIDS = [];
    var CHILD = null;         //  {pupil_id, first_name, last_name}
    var ENTRIES = [];
    var EDIT = null;          //  the entry being amended, or null for a new one
    var busy = false;
    var MONTHS = ["January", "February", "March", "April", "May", "June", "July",
                  "August", "September", "October", "November", "December"];

    function el(id) { return document.getElementById(id); }
    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }
    function fail(msg) {
      var n = el("tp-error");
      if (!n) return;
      n.textContent = msg; n.hidden = false; show("tp-ok", false);
    }
    function clearFail() { show("tp-error", false); }
    function ok(msg) {
      var n = el("tp-ok");
      if (!n) return;
      n.textContent = msg; n.hidden = false;
      if (n.scrollIntoView) n.scrollIntoView({ block: "nearest" });
    }
    function say(e) {
      if (e && e.code === "22023" && e.message) return e.message;
      return "That did not work" + (e && e.message ? ": " + e.message : ".");
    }
    function noAccess() {
      return "This screen is for the teacher of a class, or the madrasah office "
           + "signed in with two-step. If you should be able to see it, ask the office.";
    }
    function refused() {
      return "You cannot record progress for that child. Children are shown only "
           + "from the classes you teach.";
    }

    //  yyyy-mm-dd -> "28 September 2026", built from the parts and never from
    //  new Date("2026-09-28"), which is midnight UTC and reads as the previous
    //  day on a phone set west of Greenwich.
    function fullDate(iso) {
      var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ""));
      return m ? (+m[3]) + " " + MONTHS[+m[2] - 1] + " " + m[1] : "";
    }
    function todayIso() {
      var d = new Date(), mo = d.getMonth() + 1, da = d.getDate();
      return d.getFullYear() + "-" + (mo < 10 ? "0" : "") + mo + "-" + (da < 10 ? "0" : "") + da;
    }
    function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }

    function call(name, args) {
      return sb.rpc(name, args || {}).then(function (res) {
        if (res.error) throw res.error;
        return res.data;
      });
    }

    /* ---- the class ---- */
    function drawClasses() {
      var h = "", i, c;
      for (i = 0; i < CLASSES.length; i++) {
        c = CLASSES[i];
        h += '<button type="button" class="tp-pill' + (CLASS && CLASS.id === c.id ? " on" : "")
           + '" data-class="' + esc(c.id) + '" aria-pressed="' + (CLASS && CLASS.id === c.id ? "true" : "false") + '">'
           + esc(c.name) + ' <span class="tp-n">' + plural(+c.children, "child", "children") + "</span></button>";
      }
      el("tp-classes").innerHTML = h;
      show("tp-classes-wrap", CLASSES.length > 0);
    }

    function drawKids() {
      var h = "", i, k, bits;
      el("tp-kids-h").textContent = CLASS ? "Children in " + CLASS.name : "Children";
      if (!KIDS.length) {
        el("tp-kids").innerHTML = '<li class="tp-none">There are no children on this class’s roll.</li>';
        show("tp-kids-wrap", true);
        return;
      }
      for (i = 0; i < KIDS.length; i++) {
        k = KIDS[i];
        bits = [];
        if (+k.entries === 0) bits.push("nothing recorded yet");
        else {
          bits.push(plural(+k.entries, "entry", "entries"));
          bits.push(+k.shared === 0 ? "none shared" : (+k.shared) + " shared");
          if (k.last_on) bits.push("last " + fullDate(k.last_on));
        }
        h += '<li><button type="button" class="tp-row' + (CHILD && CHILD.pupil_id === k.pupil_id ? " open" : "")
           + '" data-pupil="' + esc(k.pupil_id) + '"><span class="tp-name">'
           + esc(k.first_name) + " " + esc(k.last_name) + '</span><span class="tp-meta">'
           + esc(bits.join(" · ")) + "</span></button></li>";
      }
      el("tp-kids").innerHTML = h;
      show("tp-kids-wrap", true);
    }

    /* ---- one child: the form ---- */
    function formHtml() {
      var e = EDIT || {};
      var shared = !!e.shared;
      return '<form id="tp-f" novalidate>'
        + '<h3 class="tp-h3">' + (EDIT ? "Change this entry" : "New entry") + "</h3>"
        + '<div class="tp-field tp-date"><label for="tp-on">Date</label>'
        + '<input type="date" id="tp-on" value="' + esc(e.on_date || todayIso()) + '" max="' + esc(todayIso()) + '"></div>'
        + '<div class="tp-three">'
        + '<div class="tp-field"><label for="tp-sabaq">Sabaq <span class="tp-opt">(new lesson)</span></label>'
        + '<input type="text" id="tp-sabaq" maxlength="200" autocomplete="off" value="' + esc(e.sabaq) + '"></div>'
        + '<div class="tp-field"><label for="tp-sabqi">Sabqi <span class="tp-opt">(recent revision)</span></label>'
        + '<input type="text" id="tp-sabqi" maxlength="200" autocomplete="off" value="' + esc(e.sabqi) + '"></div>'
        + '<div class="tp-field"><label for="tp-manzil">Manzil <span class="tp-opt">(older revision)</span></label>'
        + '<input type="text" id="tp-manzil" maxlength="200" autocomplete="off" value="' + esc(e.manzil) + '"></div>'
        + "</div>"
        + '<div class="tp-field tp-forparent"><label for="tp-forp">Note for the parent</label>'
        + '<textarea id="tp-forp" rows="3" maxlength="2000">' + esc(e.note_for_parent) + "</textarea>"
        + '<span class="tp-fine">The family reads this, but only if you share the entry below.</span></div>'
        + '<div class="tp-field tp-mine"><label for="tp-mine">Your own note <span class="tp-staff">staff only</span></label>'
        + '<textarea id="tp-mine" rows="3" maxlength="2000">' + esc(e.note_internal) + "</textarea>"
        + '<span class="tp-fine">Never shown to a family, whether or not the entry is shared.</span></div>'
        + '<fieldset class="tp-share"><legend>Who can read this entry?</legend>'
        + '<label class="tp-opt-row"><input type="radio" name="tp-share" value="no"' + (shared ? "" : " checked") + '>'
        + "<span><b>Only staff</b><i>Keep it to yourself for now. The family sees nothing of it.</i></span></label>"
        + '<label class="tp-opt-row"><input type="radio" name="tp-share" value="yes"' + (shared ? " checked" : "") + '>'
        + "<span><b>Share with the family</b><i>They will read the date, sabaq, sabqi, manzil and the note for the parent, with your name. Not your own note.</i></span></label>"
        + "</fieldset>"
        + '<p class="tp-inline" id="tp-inline" role="alert" hidden></p>'
        + '<div class="tp-acts"><button type="submit" class="btn btn-gold" id="tp-save">'
        + (EDIT ? "Save changes" : "Save entry") + "</button>"
        + (EDIT ? '<button type="button" class="btn btn-ghost" id="tp-cancel">Cancel</button>' : "")
        + "</div></form>";
    }

    /* ---- one child: what has been written ---- */
    function entryHtml(e, i) {
      var h = '<li class="tp-entry' + (e.shared ? " tp-shared" : "") + '">'
            + '<div class="tp-e-head"><b>' + esc(fullDate(e.on_date)) + "</b>"
            + '<span class="tp-badge ' + (e.shared ? "tp-b-shared" : "tp-b-private") + '">'
            + (e.shared ? "Shared with the family" : "Not shared") + "</span></div>";
      if (e.sabaq || e.sabqi || e.manzil) {
        h += '<dl class="tp-dl">'
           + (e.sabaq ? "<div><dt>Sabaq</dt><dd>" + esc(e.sabaq) + "</dd></div>" : "")
           + (e.sabqi ? "<div><dt>Sabqi</dt><dd>" + esc(e.sabqi) + "</dd></div>" : "")
           + (e.manzil ? "<div><dt>Manzil</dt><dd>" + esc(e.manzil) + "</dd></div>" : "")
           + "</dl>";
      }
      if (e.note_for_parent) {
        h += '<p class="tp-note tp-note-parent"><span class="tp-tag">For the parent</span>' + esc(e.note_for_parent) + "</p>";
      }
      if (e.note_internal) {
        h += '<p class="tp-note tp-note-mine"><span class="tp-tag tp-tag-staff">Your own note - staff only</span>' + esc(e.note_internal) + "</p>";
      }
      h += '<p class="tp-e-foot">' + (e.written_by_name ? "Written by " + esc(e.written_by_name) : "Written by the office")
         + '<button type="button" class="tp-link" data-edit="' + i + '">Change</button></p></li>';
      return h;
    }

    function drawChild() {
      var h, i;
      if (!CHILD) { show("tp-child", false); return; }
      h = '<div class="tp-c-head"><h2 class="tp-h">' + esc(CHILD.first_name) + " " + esc(CHILD.last_name)
        + '</h2><p class="tp-meta">' + esc(CLASS ? CLASS.name : "") + "</p></div>"
        + formHtml()
        + '<h3 class="tp-h3">Entries so far</h3>';
      if (!ENTRIES.length) {
        h += '<p class="tp-none" id="tp-noentries">Nothing has been recorded for ' + esc(CHILD.first_name) + " yet.</p>";
      } else {
        h += '<ul class="tp-entries">';
        for (i = 0; i < ENTRIES.length; i++) h += entryHtml(ENTRIES[i], i);
        h += "</ul>";
      }
      el("tp-child").innerHTML = h;
      show("tp-child", true);
    }

    /* ---- loading ---- */
    function loadClasses() {
      return call("progress_my_classes").then(function (d) {
        show("tp-loading", false);
        if (!d || d.allowed === false) { fail(noAccess()); return; }
        CLASSES = d.classes || [];
        if (!CLASSES.length) {
          el("tp-empty").innerHTML = "<p>" + esc(d.why || "You are not listed against any class, so there is nobody to record progress for. If that is wrong, ask the office.") + "</p>";
          show("tp-empty", true);
          return;
        }
        drawClasses();
        if (CLASSES.length === 1) return openClass(CLASSES[0].id);
      }, function (e) {
        show("tp-loading", false);
        fail("Your classes would not load. " + (e && e.message ? e.message : ""));
      });
    }

    function findClass(id) {
      var i;
      for (i = 0; i < CLASSES.length; i++) if (CLASSES[i].id === id) return CLASSES[i];
      return null;
    }

    function openClass(id) {
      var c = findClass(id);
      if (!c) return;
      clearFail(); show("tp-ok", false);
      CLASS = { id: c.id, name: c.name };
      CHILD = null; ENTRIES = []; EDIT = null; show("tp-child", false);
      drawClasses();
      return call("progress_class_children", { p_class: id }).then(function (d) {
        if (!d || d.allowed === false) { fail(refused()); show("tp-kids-wrap", false); return; }
        KIDS = d.children || [];
        drawKids();
      }, function (e) { fail(say(e)); });
    }

    function loadChild(pupilId, keepMessage) {
      if (!keepMessage) { clearFail(); show("tp-ok", false); }
      return call("progress_child", { p_pupil: pupilId, p_class: CLASS.id }).then(function (d) {
        if (!d || d.allowed === false) { fail(refused()); CHILD = null; show("tp-child", false); return; }
        CHILD = { pupil_id: pupilId, first_name: d.child.first_name, last_name: d.child.last_name };
        ENTRIES = d.entries || [];
        EDIT = null;
        drawChild(); drawKids();
        var box = el("tp-child");
        if (box && box.scrollIntoView) box.scrollIntoView({ block: "nearest" });
      }, function (e) { fail(say(e)); });
    }

    function refreshKids() {
      return call("progress_class_children", { p_class: CLASS.id }).then(function (d) {
        if (d && d.allowed !== false) { KIDS = d.children || []; drawKids(); }
      }, function () {});
    }

    /* ---- saving ---- */
    function val(id) { var n = el(id); return n ? (n.value || "").replace(/^\s+|\s+$/g, "") : ""; }
    function chosenShare() {
      var r = document.querySelectorAll('input[name="tp-share"]'), i;
      for (i = 0; i < r.length; i++) if (r[i].checked) return r[i].value === "yes";
      return false;
    }

    function save(ev) {
      ev.preventDefault();
      if (busy || !CHILD) return;
      clearFail();
      var inl = el("tp-inline");
      var shared = chosenShare();
      var sabaq = val("tp-sabaq"), sabqi = val("tp-sabqi"), manzil = val("tp-manzil");
      var forp = val("tp-forp"), mine = val("tp-mine");
      //  The same two refusals the database makes, said before a round trip.
      if (!sabaq && !sabqi && !manzil && !forp && !mine) {
        inl.textContent = "Write something first: where the child is up to, or a note.";
        inl.hidden = false; return;
      }
      if (shared && !sabaq && !sabqi && !manzil && !forp) {
        inl.textContent = "There is nothing to share with the family yet. Add where the child is up to, or a note for the parent, or choose “Only staff”.";
        inl.hidden = false; return;
      }
      inl.hidden = true;
      busy = true; el("tp-save").disabled = true;
      var wasEdit = !!EDIT;
      call("progress_save", {
        p_pupil: CHILD.pupil_id, p_class: CLASS.id, p_on: val("tp-on") || null,
        p_sabaq: sabaq, p_sabqi: sabqi, p_manzil: manzil,
        p_note_for_parent: forp, p_note_internal: mine,
        p_shared: shared, p_id: EDIT ? EDIT.id : null
      }).then(function (d) {
        if (!d || d.allowed === false) { fail(refused()); return; }
        return loadChild(CHILD.pupil_id, true).then(function () {
          refreshKids();
          ok((wasEdit ? "Changes saved. " : "Saved. ")
             + (shared ? "This entry is shared: the family can read it."
                       : "This entry is not shared: only staff can see it."));
        });
      }, function (e) {
        var n = el("tp-inline");
        if (n && e && e.code === "22023") { n.textContent = say(e); n.hidden = false; }
        else fail(say(e));
      })["finally"](function () {
        busy = false; var b = el("tp-save"); if (b) b.disabled = false;
      });
    }

    function wire() {
      el("tp-classes").addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-class]") : null;
        if (b) openClass(b.getAttribute("data-class"));
      });
      el("tp-kids").addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-pupil]") : null;
        if (b) loadChild(b.getAttribute("data-pupil"));
      });
      el("tp-child").addEventListener("submit", save);
      el("tp-child").addEventListener("click", function (e) {
        var t = e.target, b;
        if (!t) return;
        if (t.id === "tp-cancel") { EDIT = null; clearFail(); drawChild(); return; }
        b = t.closest ? t.closest("[data-edit]") : null;
        if (b) {
          EDIT = ENTRIES[+b.getAttribute("data-edit")] || null;
          clearFail(); show("tp-ok", false); drawChild();
          var f = el("tp-f");
          if (f && f.scrollIntoView) f.scrollIntoView({ block: "nearest" });
        }
      });
    }

    function mount(identity) {
      var roles = (identity && identity.roles) || [];
      //  TEACHERS TOO. progress_my_classes() returns only their own classes, so
      //  the same screen shows one teacher two classes and the office all of
      //  them. The scoping is in the database; this line only decides who is
      //  shown a screen at all.
      if (roles.indexOf("admin") === -1 && roles.indexOf("madrasah") === -1
          && roles.indexOf("teacher") === -1) {
        var na = el("app-noaccess");
        if (na) { na.textContent = noAccess(); na.hidden = false; }
        return;
      }
      show("tp-panel", true);
      wire();
      return loadClasses();
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
        current:  'md-progress',
        title:    'Progress notes',
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
    try { teacherProgress.mount(identity); } catch (e) {
      if (window.console) console.warn("progress panel unavailable:", e);
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
