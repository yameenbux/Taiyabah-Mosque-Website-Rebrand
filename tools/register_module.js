  /* =========================================================================
     THE REGISTER

     HOW A REGISTER IS ACTUALLY TAKEN. A teacher stands in front of a class
     with twenty children in it, most of whom are there. They are not going to
     tap twenty times. So the screen marks everyone present in one press and
     the teacher changes the three who are not — which is the same order of
     work as a paper register, and the reason paper registers have a column of
     ticks and a few crosses rather than twenty empty boxes.

     ONE CLASS AT A TIME, ON PURPOSE. A screen listing all 552 children with
     44 class headings is a screen nobody can hold their place in. The evening
     is a list of classes, and you go into one.

     WHAT THE SCREEN WILL NOT DO:

       * It will not open at all until every family has been told the register
         is being kept. The privacy notice promises parents exactly that, and
         the database refuses the marks, not just this page — so nobody can
         get round it from somewhere else.
       * It will not show a medical note. It shows a MARK that one exists, and
         the child's own record is one press away and writes down who opened
         it. A teacher about to take twenty children into a room should know
         that one of them has something recorded; they should not have it on
         a screen that sits open on a desk all evening.
       * It will not let a tick bury a parent. If a mother rang in an hour ago
         to say her son is unwell, marking the whole class away leaves her
         reason alone. Only "he turned up after all" replaces it, because that
         is new information rather than a default.
     ======================================================================= */
  var register = (function () {

    var DATE = "";            // yyyy-mm-dd, the evening being taken
    var CLASSES = [];         // every class, with its counts for DATE
    var GATE = null;          // attendance_permitted()
    var OPEN = null;          // the class being taken, or null
    var MARKS = {};           // pupil id -> {mark, reason}
    var DIRTY = false;
    var ROLES = [];
    var TEACHER_ONLY = false;   // a teacher, not office staff
    var CHILD = null;           // the child's card, open inline
    var CONCERN = false;        // is the concern form open
    var busy = false;

    function el(id) { return document.getElementById(id); }
    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }
    function fail(msg) {
      var n = el("rg-error");
      if (!n) return;
      n.textContent = msg; n.hidden = false;
    }
    function clearFail() { show("rg-error", false); }
    function say(msg) {
      var n = el("rg-ok");
      if (!n) return;
      n.textContent = msg; n.hidden = false;
      setTimeout(function () { if (n) n.hidden = true; }, 6000);
    }

    function today() {
      var d = new Date();
      function p(n) { return (n < 10 ? "0" : "") + n; }
      return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
    }

    function dateSaid(iso) {
      if (!iso) return "";
      var DAYS = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"];
      var MM = ["January","February","March","April","May","June","July",
                "August","September","October","November","December"];
      var p = iso.split("-");
      var d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
      var word = (iso === today()) ? "Today, " : "";
      return word + DAYS[d.getDay()] + " " + d.getDate() + " " + MM[d.getMonth()];
    }

    /* -----------------------------------------------------------------------
       THE GATE.

       Not a grey "coming soon" and not a silent empty screen. It says what is
       missing, how many, and where to go and do it. A refusal with no number
       is a wall; "42 families still to tell" is a job.
       --------------------------------------------------------------------- */
    function drawGate() {
      var host = el("rg-gate");
      if (!host) return;
      if (!GATE || GATE.permitted) { host.hidden = true; host.innerHTML = ""; return; }
      host.hidden = false;
      var out = GATE.outstanding || 0;
      var all = GATE.families || 0;
      host.innerHTML =
        "<h3>The register is not open yet</h3>"
        + '<p class="rg-sub">The madrasah’s privacy notice tells parents '
        + "they will be told before the first mark is made, not afterwards. "
        + "Until that is recorded, nothing here will save — and the "
        + "database refuses it too, so it cannot be got round from another "
        + "screen.</p>"
        + '<p class="rg-bignum"><b>' + esc(all - out) + "</b> of " + esc(all)
        + " families told</p>"
        + '<div class="rg-bar"><span style="width:'
        + (all ? Math.round(((all - out) / all) * 100) : 0) + '%"></span></div>'
        + "<p><strong>" + esc(out) + "</strong> still to tell.</p>"
        + '<a class="btn btn-gold" href="../notices/">Go and tell them</a>';
    }

    /* -----------------------------------------------------------------------
       THE EVENING: which classes have a register and which do not.
       --------------------------------------------------------------------- */
    function drawEvening() {
      var host = el("rg-classes");
      if (!host) return;
      if (OPEN) { host.hidden = true; return; }
      host.hidden = false;

      var done = 0, todo = 0, i;
      for (i = 0; i < CLASSES.length; i++) {
        if (CLASSES[i].marked >= CLASSES[i].on_roll && CLASSES[i].on_roll > 0) done++;
        else todo++;
      }

      var out = ['<div class="rg-evening">'
        + "<h3>" + esc(dateSaid(DATE)) + "</h3>"
        + '<p class="rg-sub">'
        + (CLASSES.length === 0
            ? "There are no classes set up yet."
            : (todo === 0
                ? "Every class has a register for this evening."
                : esc(todo) + (todo === 1 ? " class still needs" : " classes still need")
                  + " a register. Choose one."))
        + "</p></div>"];

      out.push('<div class="rg-grid">');
      for (i = 0; i < CLASSES.length; i++) {
        var c = CLASSES[i];
        var full = (c.on_roll > 0 && c.marked >= c.on_roll);
        var part = (c.marked > 0 && !full);
        out.push('<button type="button" class="rg-class'
          + (full ? " is-done" : (part ? " is-part" : "")) + '"'
          + ' data-class="' + esc(c.id) + '">'
          + "<strong>" + esc(c.name) + "</strong>"
          + (c.teacher ? '<span class="rg-q">' + esc(c.teacher) + "</span>"
                       : '<span class="rg-q rg-noteacher">no teacher set</span>')
          + '<span class="rg-state">'
          + (full
              ? "Taken · " + esc(c.away) + " away"
              : (part ? esc(c.marked) + " of " + esc(c.on_roll) + " marked"
                      : esc(c.on_roll) + " children"))
          + "</span></button>");
      }
      out.push("</div>");
      host.innerHTML = out.join("");
    }

    /* -----------------------------------------------------------------------
       ONE CLASS.
       --------------------------------------------------------------------- */
    var ROWS = [];

    function openClass(id) {
      if (busy) return;
      busy = true; clearFail();
      sb.rpc("madrasah_register_list", { p_class: id, p_date: DATE })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {};
          if (d.allowed === false) { fail("This area is for madrasah staff."); return; }
          OPEN = d["class"];
          ROWS = d.rows || [];
          GATE = d.permitted || GATE;
          MARKS = {};
          for (var i = 0; i < ROWS.length; i++) {
            if (ROWS[i].mark) {
              MARKS[ROWS[i].id] = { mark: ROWS[i].mark,
                                    reason: ROWS[i].reason || "",
                                    source: ROWS[i].source };
            }
          }
          DIRTY = false;
          drawClass(); drawEvening(); drawGate();
          window.scrollTo(0, 0);
        })["catch"](function (e) {
          fail("That class would not open. " + (e && e.message ? e.message : ""));
        })["finally"](function () { busy = false; });
    }

    function closeClass() {
      //  A HALF-TAKEN REGISTER IS NOT SAVED, so leaving says so. Losing
      //  twenty marks to a mis-tap is the kind of thing that makes somebody
      //  go back to paper and never come back.
      if (DIRTY && !window.confirm(
            "This register has not been saved. Leave it and lose the marks?")) {
        return;
      }
      OPEN = null; ROWS = []; MARKS = {}; DIRTY = false;
      drawClass(); drawEvening();
    }

    function counts() {
      var c = { present: 0, late: 0, absent: 0, excused: 0, unmarked: 0 };
      for (var i = 0; i < ROWS.length; i++) {
        var m = MARKS[ROWS[i].id];
        if (!m) { c.unmarked++; } else { c[m.mark] = (c[m.mark] || 0) + 1; }
      }
      return c;
    }

    var MARK_WORDS = { present: "Here", late: "Late",
                       absent: "Away", excused: "Away, reason given" };

    function drawClass() {
      var host = el("rg-taking");
      if (!host) return;
      if (!OPEN) { host.hidden = true; host.innerHTML = ""; return; }
      host.hidden = false;
      var c = counts();

      var head =
        '<button type="button" class="rg-back" id="rg-back">'
        + "← Back to the evening</button>"
        + '<div class="rg-taking-head"><div>'
        + "<h3>" + esc(OPEN.name) + "</h3>"
        + '<p class="rg-sub">' + esc(dateSaid(DATE))
        + (OPEN.teacher ? " · " + esc(OPEN.teacher) : "") + "</p></div>"
        + '<div class="rg-tally">'
        + '<span class="rg-t rg-t-present"><b>' + esc(c.present + c.late)
        + "</b> here</span>"
        + '<span class="rg-t rg-t-away"><b>' + esc(c.absent + c.excused)
        + "</b> away</span>"
        + (c.unmarked
            ? '<span class="rg-t rg-t-todo"><b>' + esc(c.unmarked)
              + "</b> not marked</span>"
            : "")
        + "</div></div>";

      //  EVERYONE HERE, THEN CHANGE THE FEW WHO ARE NOT. The order the job is
      //  actually done in.
      var quick = '<div class="rg-quick">'
        + '<button type="button" class="btn btn-ghost" data-all="present">'
        + "Everyone is here</button>"
        + '<button type="button" class="btn btn-ghost" data-all="clear">'
        + "Start again</button>"
        + '<button type="button" class="rg-linkish" data-do="print">'
        + "Print a paper register</button>"
        + "</div>";

      var out = [];
      for (var i = 0; i < ROWS.length; i++) {
        var r = ROWS[i];
        var m = MARKS[r.id] || {};
        var fromParent = (r.source === "parent" && (!m.mark || m.source === "parent"));
        out.push('<li class="rg-row' + (m.mark ? " is-marked" : "") + '"'
          + ' data-pupil="' + esc(r.id) + '">'
          + '<div class="rg-who"><strong>' + esc(r.name) + "</strong>"
          //  A MARK, NEVER THE NOTE.
          //  A MARK, NEVER THE NOTE - and where the mark LEADS depends on who
          //  is looking. ../pupil/ is the office's full record (address, date
          //  of birth, fees) and refuses a teacher outright, so sending them
          //  there would be a dead link dressed up as a safeguard. A teacher
          //  gets a card on this screen carrying what they need and nothing
          //  else. Either way, opening it is written down against a name.
          + (r.has_medical
              ? (TEACHER_ONLY
                  ? ' <button type="button" class="rg-med" data-child="'
                    + esc(r.id) + '">medical</button>'
                  : ' <a class="rg-med" href="../pupil/?id='
                    + encodeURIComponent(r.id)
                    + '" title="This child has something recorded. Opening '
                    + 'their record is written down.">medical</a>')
              : "")
          //  A teacher can open ANY child in their class, not only the ones
          //  with a mark - to ring home, or to raise a concern.
          + (TEACHER_ONLY
              ? ' <button type="button" class="rg-open" data-child="'
                + esc(r.id) + '">open</button>'
              : "")
          + (fromParent
              ? '<span class="rg-parent">A parent told us: '
                + esc(r.reason || "away") + "</span>"
              : "")
          + "</div>"
          + '<div class="rg-marks" role="group" aria-label="Mark ' + esc(r.name) + '">'
          + button(r.id, m.mark, "present", "Here")
          + button(r.id, m.mark, "late", "Late")
          + button(r.id, m.mark, "absent", "Away")
          + "</div>"
          + (m.mark === "absent" || m.mark === "excused"
              ? '<div class="rg-reason"><label class="sr-only" for="rs-'
                + esc(r.id) + '">Reason ' + esc(r.name) + " is away</label>"
                + '<input type="text" id="rs-' + esc(r.id) + '" class="rg-reason-i"'
                + ' data-pupil="' + esc(r.id) + '" value="' + esc(m.reason || "")
                + '" placeholder="Reason, if you know it — optional"></div>'
              : "")
          + "</li>");
      }

      var save = '<div class="rg-save">'
        + '<span class="rg-save-n">'
        + (c.unmarked
            ? esc(c.unmarked) + (c.unmarked === 1 ? " child is" : " children are")
              + " not marked yet"
            : "Every child is marked")
        + "</span>"
        + '<button type="button" class="btn btn-gold" id="rg-save"'
        + (c.unmarked === ROWS.length ? " disabled" : "") + ">Save the register</button>"
        + "</div>";

      host.innerHTML = head + quick
        + '<ul class="rg-list">' + out.join("") + "</ul>" + save;
    }

    function button(id, current, mark, label) {
      //  'excused' IS NOT A BUTTON. It is what 'absent' becomes when somebody
      //  types a reason, because a teacher should not have to decide which of
      //  two kinds of away this is — typing the reason IS the decision.
      var on = (current === mark) || (mark === "absent" && current === "excused");
      return '<button type="button" class="rg-mark rg-' + mark
           + (on ? " is-on" : "") + '" data-mark="' + mark + '"'
           + ' aria-pressed="' + (on ? "true" : "false") + '">'
           + esc(label) + "</button>";
    }

    function setMark(pupil, mark) {
      var was = MARKS[pupil] || {};
      if (was.mark === mark || (mark === "absent" && was.mark === "excused")) {
        delete MARKS[pupil];
      } else {
        MARKS[pupil] = { mark: mark, reason: was.reason || "" };
        if (mark === "absent" && MARKS[pupil].reason) MARKS[pupil].mark = "excused";
      }
      DIRTY = true;
      drawClass();
    }

    function save() {
      if (busy || !OPEN) return;
      var list = [], k;
      for (k in MARKS) {
        if (MARKS.hasOwnProperty(k)) {
          list.push({ pupil_id: k, mark: MARKS[k].mark,
                      reason: MARKS[k].reason || null });
        }
      }
      if (!list.length) return;
      busy = true; clearFail();
      sb.rpc("mark_register",
             { p_class: OPEN.id, p_date: DATE, p_marks: list })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {};
          DIRTY = false;
          say(d.marked + (d.marked === 1 ? " child" : " children") + " saved"
              + (d.parent_reports_kept
                  ? ", and " + d.parent_reports_kept + " parent’s message "
                    + "left as it was" : "") + ".");
          return load().then(function () {
            if (OPEN) openClass(OPEN.id);
          });
        })["catch"](function (e) {
          fail("The register would not save. "
               + (e && e.message ? e.message : "")
               + " Nothing has been lost — the marks are still on screen.");
        })["finally"](function () { busy = false; });
    }

    /* -----------------------------------------------------------------------
       ONE CHILD, FOR THE TEACHER WHO TEACHES THEM.

       Opened on this screen rather than by navigating away, because a teacher
       is standing up holding a tablet with a register half-taken on it, and
       losing that to follow a link is how a register does not get finished.

       WHAT IS ON IT is decided by the database, not by this card: medical,
       allergy and SEND, who to ring, and how often they have been away. No
       address, no date of birth, no fees, no other child. A teacher does not
       need to know where a child lives in order to teach them.
       --------------------------------------------------------------------- */
    function openChild(id) {
      if (busy) return;
      busy = true; clearFail();
      sb.rpc("madrasah_pupil_for_teacher", { p_id: id }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        CHILD = res.data; CONCERN = false;
        drawChild();
      })["catch"](function (e) {
        fail("That child would not open. " + (e && e.message ? e.message : ""));
      })["finally"](function () { busy = false; });
    }

    function closeChild() { CHILD = null; CONCERN = false; drawChild(); }

    function drawChild() {
      var host = el("rg-child");
      if (!host) return;
      if (!CHILD) { host.hidden = true; host.innerHTML = ""; return; }
      host.hidden = false;
      var c = CHILD;

      function block(title, body, tone) {
        if (!body) return "";
        return '<div class="rg-c-block' + (tone ? " " + tone : "") + '">'
             + "<h5>" + esc(title) + "</h5><p>" + esc(body) + "</p></div>";
      }

      var safety = block("Medical", c.medical, "bad")
                 + block("Allergies", c.allergies, "bad")
                 + block("Additional needs", c.send_detail, "")
                 + block("EHCP", c.ehcp_detail, "");

      host.innerHTML =
        '<div class="rg-c-head"><div><h4>' + esc(c.name) + "</h4>"
        + '<p class="rg-q">' + esc(c.class || "")
        + (c.school_year ? " \u00b7 " + esc(c.school_year) : "") + "</p></div>"
        + '<button type="button" class="rg-linkish" id="rg-child-close">'
        + "Close</button></div>"
        + (safety
            ? safety
            //  SAID IN WORDS. An empty space where the medical box would be
            //  reads as "not loaded yet" to somebody who has seen one before.
            : '<p class="rg-q">Nothing medical is recorded for this child.</p>')
        + '<div class="rg-c-ring"><h5>Who to ring</h5>'
        + (c.ring_phone
            ? "<p><strong>" + esc(c.ring_name || "their family") + "</strong> "
              + '<a href="tel:' + esc(c.ring_phone) + '">' + esc(c.ring_phone)
              + "</a></p>"
            : '<p class="rg-warn-t">No telephone number on file. Ask the '
              + "office.</p>")
        + "</div>"
        + (c.away_last_four_weeks
            ? '<p class="rg-q">Away ' + esc(c.away_last_four_weeks)
              + (c.away_last_four_weeks === 1 ? " time" : " times")
              + " in the last four weeks.</p>"
            : "")
        + (c.walk_home_consent === false
            ? '<p class="rg-warn-t">Not to walk home alone.</p>' : "")
        + '<div class="rg-c-acts">'
        + (CONCERN ? "" :
            '<button type="button" class="btn btn-ghost" id="rg-concern">'
            + "Raise a safeguarding concern</button>")
        + "</div>"
        + (CONCERN ? concernForm() : "");
    }

    /*  RAISING A CONCERN.

        THE FIRST THING IT SAYS IS THAT IT IS THE WRONG TOOL IN AN EMERGENCY.
        A form is not a person, and a teacher who thinks a child is in danger
        now should be finding an adult, not typing. Saying so at the top costs
        nothing and is the only part of this form that could save anybody.

        IT IS WRITE-ONLY. The teacher gets a reference and cannot look it up
        again - not their own, not anybody\u2019s. A concern may be about a
        colleague, and a screen that lets the person who raised it watch what
        happened next turns a safeguarding report into a conversation.       */
    function concernForm() {
      return '<div class="rg-concern" id="rg-concern-box">'
        + '<div class="rg-urgent"><strong>If a child is in danger right now, '
        + "this is the wrong tool.</strong> Find the safeguarding lead or "
        + "another adult, or ring 999. This form is for something you have "
        + "seen or been told that somebody needs to look into.</div>"
        + '<label class="rg-fld"><span>What happened?</span>'
        + '<textarea id="rg-c-what" rows="5" placeholder="What you saw or were '
        + 'told, in your own words. Write what happened rather than what you '
        + 'think it means."></textarea></label>'
        + '<label class="rg-fld"><span>When was this?</span>'
        + '<input type="text" id="rg-c-when" placeholder="This evening, '
        + 'during the second half…"></label>'
        + '<p class="rg-q">This goes to the safeguarding lead. You will get a '
        + "reference and will not be able to look it up here afterwards \u2014 "
        + "concerns are read by the designated person only.</p>"
        + '<div class="rg-c-acts">'
        + '<button type="button" class="btn btn-gold" id="rg-c-send">'
        + "Send this to the safeguarding lead</button>"
        + '<button type="button" class="rg-linkish" id="rg-c-cancel">'
        + "Cancel</button></div></div>";
    }

    function sendConcern() {
      var what = el("rg-c-what"), when = el("rg-c-when");
      if (!what || !what.value.trim()) {
        fail("Please say what happened before sending it.");
        return;
      }
      if (busy || !CHILD) return;
      busy = true; clearFail();
      sb.rpc("raise_concern", { p_pupil: CHILD.id, p_what: what.value,
                                p_when: when ? when.value : null })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {};
          CONCERN = false;
          closeChild();
          say("Concern " + (d.reference || "") + " has gone to the "
              + "safeguarding lead. Write the reference down \u2014 you "
              + "cannot look it up here.");
        })["catch"](function (e) {
          fail("That could not be sent. " + (e && e.message ? e.message : "")
               + " Nothing has been lost \u2014 what you typed is still here.");
        })["finally"](function () { busy = false; });
    }

    /* -----------------------------------------------------------------------
       A PAPER REGISTER.

       NOT A FALLBACK NOBODY ASKED FOR. A teacher with no tablet, a flat
       battery or a room with no signal still has to take a register, and the
       alternative to paper is a register that does not get taken. Names and
       a column of boxes, nothing else — this sheet is carried between rooms
       and left on desks, so it carries no medical mark either.
       --------------------------------------------------------------------- */
    function printPaper() {
      var host = el("rg-print");
      if (!host || !OPEN) return;
      var rows = [];
      for (var i = 0; i < ROWS.length; i++) {
        rows.push("<tr><td>" + esc(i + 1) + "</td><td>" + esc(ROWS[i].name)
                + "</td><td></td><td></td><td></td></tr>");
      }
      host.innerHTML =
        '<div class="pr-head"><img class="pr-logo" src="../../img/masjid-logo.png" alt="">'
        + "<div><h1>Taiyabah Masjid Madrasah</h1>"
        + "<p>" + esc(OPEN.name)
        + (OPEN.teacher ? " · " + esc(OPEN.teacher) : "") + "</p></div>"
        + '<div class="pr-date"><p>' + esc(dateSaid(DATE)) + "</p></div></div>"
        + '<table class="pr-table"><thead><tr><th>#</th><th>Name</th>'
        + "<th>Here</th><th>Late</th><th>Away &mdash; reason</th></tr></thead>"
        + "<tbody>" + rows.join("") + "</tbody></table>"
        + '<p class="pr-foot">Please give this sheet to the office so the '
        + "marks can be entered. It carries no medical or contact "
        + "information.</p>";

      var back = host.parentNode;
      document.body.appendChild(host);
      document.body.className += " printing-register";
      try { window.print(); }
      finally {
        document.body.className =
          document.body.className.replace(/\s*printing-register/, "");
        if (back) back.appendChild(host);
      }
    }

    // --- loading -----------------------------------------------------------
    function load() {
      return sb.rpc("madrasah_registers_list", { p_date: DATE })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {};
          if (d.allowed === false) { fail("This area is for madrasah staff."); return; }
          CLASSES = d.rows || [];
          GATE = d.permitted || null;
          drawGate(); drawEvening();
        })["catch"](function (e) {
          fail("The classes would not load. " + (e && e.message ? e.message : ""));
        });
    }

    function wire() {
      var when = el("rg-date");
      if (when) when.addEventListener("change", function () {
        if (DIRTY && !window.confirm(
              "This register has not been saved. Change the day and lose the marks?")) {
          when.value = DATE; return;
        }
        DATE = when.value || today();
        OPEN = null; MARKS = {}; DIRTY = false;
        drawClass();
        load();
      });

      var host = el("rg-classes");
      if (host) host.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-class]") : null;
        if (b) openClass(b.getAttribute("data-class"));
      });

      var kid = el("rg-child");
      if (kid) kid.addEventListener("click", function (e) {
        var t = e.target;
        if (t.id === "rg-child-close") { closeChild(); return; }
        if (t.id === "rg-concern")     { CONCERN = true; drawChild(); return; }
        if (t.id === "rg-c-cancel")    { CONCERN = false; drawChild(); return; }
        if (t.id === "rg-c-send")      { sendConcern(); return; }
      });

      var cls = el("rg-taking");
      if (cls) {
        cls.addEventListener("click", function (e) {
          var t = e.target;
          if (t.id === "rg-back") { closeClass(); return; }
          if (t.id === "rg-save") { save(); return; }
          var all = t.closest ? t.closest("[data-all]") : null;
          if (all) {
            var what = all.getAttribute("data-all");
            if (what === "clear") { MARKS = {}; }
            else {
              for (var i = 0; i < ROWS.length; i++) {
                //  A PARENT'S MESSAGE IS NOT SWEPT AWAY BY "EVERYONE IS HERE".
                //
                //  The database refuses it too, but a screen that appears to
                //  do it and is then silently corrected is worse than one that
                //  never appeared to: the teacher watches the mother's reason
                //  vanish, presses save, and is told something different
                //  happened.
                //
                //  THE FIRST VERSION OF THIS LINE READ
                //      if (ROWS[i].source === "parent" && !MARKS[...]) continue;
                //  and never once skipped anybody, because openClass() fills
                //  MARKS from the marks already on the register - including
                //  the parent's. The guard tested a condition that is false by
                //  construction. It read correctly and did nothing, which is
                //  the worst kind of guard.
                //
                //  A teacher who knows the child turned up after all can still
                //  tap Here on that one row. This is a bulk default, and a
                //  default does not get to overrule somebody who rang in.
                if (ROWS[i].source === "parent") continue;
                MARKS[ROWS[i].id] = { mark: "present", reason: "" };
              }
            }
            DIRTY = true; drawClass(); return;
          }
          var m = t.closest ? t.closest("[data-mark]") : null;
          if (m) {
            var row = m.closest("[data-pupil]");
            if (row) setMark(row.getAttribute("data-pupil"), m.getAttribute("data-mark"));
            return;
          }
          var pr = t.closest ? t.closest('[data-do="print"]') : null;
          if (pr) { printPaper(); return; }
          //  The medical mark and the open button both lead to the same card.
          var ch = t.closest ? t.closest("[data-child]") : null;
          if (ch) openChild(ch.getAttribute("data-child"));
        });

        //  TYPING A REASON IS WHAT TURNS "away" INTO "away, reason given".
        cls.addEventListener("input", function (e) {
          var i = e.target;
          if (!i.classList || !i.classList.contains("rg-reason-i")) return;
          var id = i.getAttribute("data-pupil");
          if (!MARKS[id]) return;
          MARKS[id].reason = i.value;
          MARKS[id].mark = i.value.trim() ? "excused" : "absent";
          DIRTY = true;
        });
      }
    }

    //  LEAVING THE PAGE WITH A HALF-TAKEN REGISTER.
    function wireLeaving() {
      window.addEventListener("beforeunload", function (e) {
        if (!DIRTY) return;
        e.preventDefault();
        e.returnValue = "";
        return "";
      });
    }

    function mount(identity) {
      var roles = (identity && identity.roles) || [];
      //  TEACHERS TOO, AND THIS IS THE ONLY SCREEN THEY GET.
      //  madrasah_registers_list() returns only their own classes, so the
      //  same screen shows one teacher three classes and the office all
      //  forty-four. The scoping is in the database; this line only decides
      //  who gets shown a screen at all.
      if (roles.indexOf("admin") === -1 && roles.indexOf("madrasah") === -1
          && roles.indexOf("teacher") === -1) {
        var na = el("app-noaccess");
        if (na) {
          na.textContent = "This area is for madrasah staff. If you should be "
            + "able to take a register, ask the office to add you.";
          na.hidden = false;
        }
        return;
      }
      ROLES = roles;
      TEACHER_ONLY = (roles.indexOf("admin") === -1
                      && roles.indexOf("madrasah") === -1);
      DATE = today();
      var when = el("rg-date");
      if (when) { when.value = DATE; when.max = DATE; }
      show("rg-panel", true);
      wire(); wireLeaving();
      return load();
    }

    return { mount: mount };
  })();
