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

    //  WHAT WAS NEVER TAKEN. Office only — registers_missing()'s own
    //  result for the last fortnight, cached per load() rather than
    //  refetched on every class open/close.
    var MISSING = null;
    //  Set only on a GENUINE fetch failure (network/database error) — never
    //  on a legitimate 'allowed:false' or an honestly empty list. See
    //  fetchMissing() for why the three have to read differently on screen.
    var MISSING_ERROR = null;
    //  WHAT A MARK USED TO SAY. Office only, and NEVER fetched until the
    //  office presses for it — see the section below headed "THE HISTORY".
    var HISTORY_OPEN = false;
    var HISTORY = null;         // register_history()'s rows, or null while loading

    function el(id) { return document.getElementById(id); }
    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }
    //  ONE MESSAGE AT A TIME. #rg-ok and #rg-error are two independent
    //  slots, and independent slots drift apart: before the busy-guard fix
    //  elsewhere in this file, a write's own reload could never actually
    //  run, so fail() firing after say() was unreachable in practice. It
    //  is reachable now (a reload can fail after a successful save or
    //  submit), so each function now clears the OTHER slot itself, here,
    //  once — not at each call site, so no future call site can forget
    //  it and let the two say something different at the same time.
    function fail(msg) {
      var ok = el("rg-ok");
      if (ok) ok.hidden = true;
      var n = el("rg-error");
      if (!n) return;
      n.textContent = msg; n.hidden = false;
    }
    function clearFail() { show("rg-error", false); }
    function say(msg) {
      var err = el("rg-error");
      if (err) err.hidden = true;
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

    //  n DAYS EITHER SIDE OF an iso date — used to name the missed-registers
    //  window explicitly (ruling C), rather than taking registers_missing()'s
    //  own default, which includes tonight and reads a different number from
    //  the fortnight the panel names.
    function addDays(iso, n) {
      var p = iso.split("-");
      var d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]));
      d.setDate(d.getDate() + n);
      function p2(x) { return (x < 10 ? "0" : "") + x; }
      return d.getFullYear() + "-" + p2(d.getMonth() + 1) + "-" + p2(d.getDate());
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

    //  THE TIME A REGISTER WAS HANDED IN. A clock time, not a date — the
    //  evening it covers is already on screen; what a teacher wants to know
    //  when they see "Handed in" is roughly when, today.
    function timeSaid(ts) {
      if (!ts) return "";
      var d = new Date(ts);
      if (isNaN(d.getTime())) return "";
      function p(n) { return (n < 10 ? "0" : "") + n; }
      var h = d.getHours(), ap = (h >= 12 ? "pm" : "am"), h12 = h % 12;
      if (h12 === 0) h12 = 12;
      return h12 + ":" + p(d.getMinutes()) + ap;
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

      //  "DONE" IS state === 'submitted', HERE AND ONLY HERE. The cards
      //  below have always read it; the sentence above them used to test
      //  "every child has a mark" instead, so with every class fully marked
      //  and none handed in it said "Every class has a register for this
      //  evening" over forty-four cards each saying it was NOT handed in.
      //  One test, one answer.
      //
      //  A class with nobody on its roll is not DUE: register_due() says so
      //  and submit_register() refuses it. It used to fall into `todo`, so
      //  the screen asked for a register the database would not accept. It
      //  is counted in neither.
      var done = 0, todo = 0, i;
      for (i = 0; i < CLASSES.length; i++) {
        if (!(CLASSES[i].on_roll > 0)) continue;
        if (CLASSES[i].state === "submitted") done++;
        else todo++;
      }

      var out = ['<div class="rg-evening">'
        + "<h3>" + esc(dateSaid(DATE)) + "</h3>"
        + '<p class="rg-sub">'
        + (CLASSES.length === 0
            ? "There are no classes set up yet."
            : (done + todo === 0
                ? "No class has anybody on its roll yet, so no register is due."
                : (todo === 0
                    ? "Every register is handed in for this evening."
                    : esc(todo) + (todo === 1 ? " class still needs" : " classes still need")
                      + " a register. Choose one.")))
        + "</p></div>"];

      out.push('<div class="rg-grid">');
      for (i = 0; i < CLASSES.length; i++) {
        var c = CLASSES[i];
        //  allMarked is a smaller fact than "done" - every child has a mark
        //  - and exists for one purpose: the card's own "Fully marked - not
        //  handed in" label. It is never used to count anything.
        var allMarked = (c.on_roll > 0 && c.marked >= c.on_roll);
        //  HANDED IN, NOT MERELY FULLY MARKED (ruling E / db/110's own
        //  reasoning, one level up). madrasah_registers_list() now carries
        //  each class's own register state alongside its counts — added
        //  here for exactly the gap db/110 closed on the single-class
        //  view: a register corrected back to draft after the roll grew
        //  past what is marked (db/102's demotion rule) still counted as
        //  "Taken" on this grid when the only thing checked was
        //  whether every child had a mark, while the class screen underneath it
        //  correctly showed Hand-in waiting to be pressed again.
        var handedIn = (c.state === "submitted");
        var part = (c.marked > 0 && !allMarked);
        out.push('<button type="button" class="rg-class'
          + (handedIn ? " is-done" : (allMarked || part ? " is-part" : "")) + '"'
          + ' data-class="' + esc(c.id) + '">'
          + "<strong>" + esc(c.name) + "</strong>"
          + (c.teacher ? '<span class="rg-q">' + esc(c.teacher) + "</span>"
                       : '<span class="rg-q rg-noteacher">no teacher set</span>')
          + '<span class="rg-state">'
          + (handedIn
              ? "Handed in · " + esc(c.away) + " away"
              : (allMarked
                  ? "Fully marked · not handed in"
                  : (part ? esc(c.marked) + " of " + esc(c.on_roll) + " marked"
                          : (c.on_roll > 0 ? esc(c.on_roll) + " children"
                                           : "Nobody on the roll"))))
          + "</span></button>");
      }
      out.push("</div>");
      host.innerHTML = out.join("");
    }

    /* -----------------------------------------------------------------------
       WHAT WAS NEVER TAKEN.

       OFFICE ONLY. A teacher already has their own prompt on their own
       landing page; the whole madrasah's misses is a list they can do
       nothing about, and CLAUDE.md's rule about the register screens is
       that they must not hand a teacher another teacher's outstanding
       register.

       registers_missing() itself is one of the functions CLAUDE.md names
       outright as returning people — here it returns a class, a date and a
       TEACHER'S name, not a child, so (unlike the history below) it is
       fine to draw the moment the evening loads. What is not fine is
       letting it contradict the rest of this screen — see fetchMissing().
       --------------------------------------------------------------------- */
    function fetchMissing() {
      if (TEACHER_ONLY) { MISSING = null; MISSING_ERROR = null; drawMissing(); return; }
      //  RULING D. attendance_permitted() being false means NOTHING behind
      //  this list could ever have been marked — mark_register() refuses
      //  every mark until every family has been told, and #rg-gate above
      //  already says so, with the true family count. A second panel
      //  saying "440 registers never taken" while every teacher in the
      //  madrasah was refused every one of them reads as an accusation
      //  against 44 people for a lock the office holds. Same technique
      //  db/111 and db/112 use for the identical fact on Today: reuse the
      //  SAME gate the screen already shows, and when it is shut, do not
      //  draw a second, differently-worded version of the same thing —
      //  hide this panel outright rather than invent a third wording. This
      //  is a REFUSAL, never a failure — silent is correct here.
      if (!GATE || !GATE.permitted) { MISSING = null; MISSING_ERROR = null; drawMissing(); return; }
      //  THE WINDOW IS EXPLICIT, AND EXCLUDES TONIGHT (ruling C).
      //  registers_missing()'s own default (current_date - 14 to
      //  current_date) includes this evening — on this masjid, right now,
      //  that reads 484. "The last fortnight" excluding tonight — the same
      //  "N days before today, today excluded" shape db/108's digest and
      //  db/112's Today item both already use — reads 440. Passing the
      //  window explicitly keeps the number on screen the same claim as
      //  the sentence above it, instead of the two silently disagreeing.
      var from = addDays(today(), -14), to = addDays(today(), -1);
      sb.rpc("registers_missing", { p_from: from, p_to: to }).then(function (res) {
        //  A GENUINE FAILURE MUST NOT LOOK LIKE "NOTHING IS MISSING".
        //  This panel's whole job is to surface an absence — going quiet on
        //  a network glitch the same way it goes quiet on an honestly empty
        //  list hands the office the one reassurance a failed check must
        //  never give: that there is nothing to chase. 'allowed:false' is a
        //  legitimate refusal (not permitted, or no longer office) and
        //  stays silent, same as an empty list — only res.error, an actual
        //  answer that did not arrive, gets a line on screen.
        if (res.error) {
          MISSING = null;
          MISSING_ERROR = "Registers never taken could not be checked. "
            + (res.error.message ? res.error.message + " " : "")
            + "Reload the page to try again.";
          drawMissing();
          return;
        }
        var d = res.data || {};
        MISSING_ERROR = null;
        MISSING = (d.allowed === false) ? null : d;
        drawMissing();
      })["catch"](function (e) {
        MISSING = null;
        MISSING_ERROR = "Registers never taken could not be checked. "
          + (e && e.message ? e.message + " " : "")
          + "Reload the page to try again.";
        drawMissing();
      });
    }

    function drawMissing() {
      var host = el("rg-missing");
      if (!host) return;
      //  Part of the EVENING view, same as #rg-classes — put away the
      //  moment a class is open, and back the moment it is closed. This
      //  includes a standing error: it is not lost, only put away with
      //  everything else in this view, and comes back the moment the
      //  office returns to the evening.
      if (OPEN) { host.hidden = true; host.innerHTML = ""; return; }
      if (MISSING_ERROR) {
        //  DISTINGUISHABLE FROM "ALL CLEAR", NOT ALARMING. A short line
        //  where the panel would be, not the whole gate treatment — this is
        //  "I could not look", not "the register is locked".
        host.innerHTML = '<p class="rg-warn-t">' + esc(MISSING_ERROR) + "</p>";
        host.hidden = false;
        return;
      }
      //  THE FLOOR SWALLOWED THE WHOLE WINDOW (db/117). The register opened
      //  on a day inside - or after - the fortnight, so there is nothing
      //  before it to report. Said in the database's own words rather than
      //  drawn as nothing, because a hidden panel reads as "every register
      //  was taken", and on the opening evening that would be a false
      //  reassurance about evenings nobody was allowed to mark.
      if (MISSING && MISSING.swallowed === true) {
        host.innerHTML = "<h3>Registers never taken</h3>"
          + '<p class="rg-sub">' + esc(MISSING.note || "") + "</p>";
        host.hidden = false;
        return;
      }
      if (!MISSING || !(MISSING.rows || []).length) {
        host.hidden = true; host.innerHTML = "";
        return;
      }
      var i, rows = MISSING.rows;
      var out = ["<h3>Registers never taken</h3>"
        + '<p class="rg-sub">The last fortnight, not counting tonight. '
        //  When the register opened part-way through the fortnight the
        //  database says where the count starts, so a short list is not
        //  taken for a short memory.
        + (MISSING.note ? esc(MISSING.note) + " " : "")
        + "A register not taken is not a register taken late — nobody "
        + "was recorded as being in that room.</p>"
        + '<ul class="rg-missing-l">'];
      for (i = 0; i < rows.length; i++) {
        out.push("<li><strong>" + esc(rows[i].name) + "</strong> "
          + '<span class="rg-q">' + esc(dateSaid(rows[i].on_date))
          + (rows[i].teacher ? " · " + esc(rows[i].teacher) : "")
          + "</span></li>");
      }
      out.push("</ul>");
      host.innerHTML = out.join("");
      host.hidden = false;
    }

    /* -----------------------------------------------------------------------
       ONE CLASS.
       --------------------------------------------------------------------- */
    var ROWS = [];

    //  THE FETCH ITSELF, WITHOUT THE busy GUARD. openClass() (below) is the
    //  public, click-triggered entry point and owns busy for the length of
    //  its own fetch. save() and submitRegister() need the exact same
    //  fetch-and-redraw afterwards, from INSIDE their own busy-guarded
    //  span — calling openClass() there would trip its own `if (busy)
    //  return;` on the busy flag they are still holding, and silently do
    //  nothing. (It did: this is how a corrected, still-fully-marked
    //  register failed to notice a register had fallen back to draft after
    //  a child joined the roll — save() reported success, but the screen
    //  underneath never actually re-fetched.) fetchClass() is the shared
    //  worker; only openClass() touches busy.
    //
    //  writeOkMsg: passed only when this fetch is the RELOAD AFTER A
    //  SUCCESSFUL WRITE (save or submit). The write already happened — a
    //  failure here is the SCREEN not catching up, not the write failing —
    //  so the ordinary "That class would not open" would put doubt on
    //  something that is not in doubt. See refreshAfterWrite().
    function fetchClass(id, writeOkMsg) {
      return sb.rpc("madrasah_register_list", { p_class: id, p_date: DATE })
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
          //  A FRESH CLASS, OR A RELOAD AFTER A WRITE — either way, any
          //  history panel left open belonged to what was on screen a
          //  moment ago and may now be stale. Closed, not refetched: the
          //  office presses again if they want it, same as opening it the
          //  first time (ruling A).
          HISTORY_OPEN = false; HISTORY = null;
          drawClass(); drawEvening(); drawGate(); drawMissing();
          window.scrollTo(0, 0);
        })["catch"](function (e) {
          fail(writeOkMsg
            ? writeOkMsg + " The screen did not refresh. Reopen the class "
              + "to see it." + (e && e.message ? " (" + e.message + ")" : "")
            : "That class would not open. " + (e && e.message ? e.message : ""));
        });
    }

    function openClass(id) {
      if (busy) return;
      busy = true; clearFail();
      fetchClass(id)["finally"](function () { busy = false; });
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
      HISTORY_OPEN = false; HISTORY = null;
      drawClass(); drawEvening(); drawMissing();
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
      //  SUBMITTED, ACCORDING TO THE DATABASE — not "every row on screen
      //  happens to carry a mark right now". A register can look fully
      //  marked without ever having been handed in, and (after a
      //  correction drops it below the roll, db/102) it can have been
      //  submitted once and no longer be. OPEN.state is whatever the last
      //  load of this class said; every save/submit reloads it.
      var handedIn = (OPEN.state === "submitted");

      var head =
        '<button type="button" class="rg-back" id="rg-back">'
        + "← Back to the evening</button>"
        + '<div class="rg-taking-head"><div>'
        + "<h3>" + esc(OPEN.name) + "</h3>"
        + '<p class="rg-sub">' + esc(dateSaid(DATE))
        + (OPEN.teacher ? " · " + esc(OPEN.teacher) : "") + "</p>"
        //  SAYS SO, IN WORDS A TEACHER WOULD USE, WITH THE TIME — right
        //  under the class name, the first thing seen on opening it again,
        //  not buried at the bottom where the button used to be.
        + (handedIn
            ? '<p class="rg-handed">Handed in'
              + (OPEN.submitted_at
                  ? " · " + esc(timeSaid(OPEN.submitted_at)) : "") + "</p>"
            : "")
        + "</div>"
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
        + '<div class="rg-save-btns">'
        + '<button type="button" class="btn" id="rg-save"'
        + (c.unmarked === ROWS.length ? " disabled" : "") + ">Save</button>"
        //  THE GATE. Save always works so an interrupted teacher loses
        //  nothing; handing in is the thing that demands a full register.
        //  Re-rendered on every mark (drawClass runs after each tap), so
        //  marking the last child flips this without a reload.
        //
        //  NOT A LOCK. Once handed in, the button that invited the press is
        //  simply gone — Save stays exactly as it was, so a 14-day
        //  correction still works, and a correction that leaves every
        //  child marked keeps the register submitted (db/102 only ever
        //  demotes). If a later correction drops the marked count below
        //  the roll, the next reload brings OPEN.state back from the
        //  server as no-longer-submitted, and this button reappears on its
        //  own — nothing here remembers "was submitted", it only ever asks
        //  what the last load said.
        + (handedIn ? "" :
            '<button type="button" class="btn btn-gold" id="rg-submit"'
            + (c.unmarked > 0 ? " disabled" : "") + ">Hand the register in</button>")
        + "</div></div>";

      host.innerHTML = head + quick
        + '<ul class="rg-list">' + out.join("") + "</ul>" + save + historyPanel();
    }

    /* -----------------------------------------------------------------------
       THE HISTORY. Office only, and NOT drawn the moment a class opens.

       register_history() names every child in the class against every
       change made to their mark this evening — source and who-wrote-it
       included. CLAUDE.md's rule is "the list says whether, the record
       says what", and a screen sitting open on a desk all evening should
       not have children's records on it. So this is a collapsed control
       the office has to press — "What this register has said" — and
       register_history() is fetched only on that press, never on opening
       the class. Closing it again costs no network call; opening it again
       does, on purpose, so a class corrected after the panel was last
       looked at is never shown as stale.
       --------------------------------------------------------------------- */
    function historyPanel() {
      if (TEACHER_ONLY) return "";
      return '<div class="rg-hist-wrap">'
        + '<button type="button" class="rg-linkish" id="rg-history-toggle"'
        + ' aria-expanded="' + (HISTORY_OPEN ? "true" : "false") + '"'
        + ' aria-controls="rg-history">'
        + (HISTORY_OPEN ? "Hide the history" : "What this register has said")
        + "</button>"
        + '<section class="rg-history" id="rg-history"'
        + (HISTORY_OPEN ? "" : " hidden") + ">"
        + (HISTORY_OPEN ? historyBody() : "") + "</section>"
        + "</div>";
    }

    function historyBody() {
      if (HISTORY === null) return '<p class="rg-q">Loading the history…</p>';
      if (!HISTORY.length) {
        return '<p class="rg-q">Nothing has been changed on this evening’s '
          + "register yet.</p>";
      }
      var i, h, out = ['<ul class="rg-hist-l">'];
      for (i = 0; i < HISTORY.length; i++) {
        h = HISTORY[i];
        out.push("<li><strong>" + esc(h.child) + "</strong> "
          + esc(MARK_WORDS[h.mark] || h.mark)
          + (h.was_mark
              ? ' <span class="rg-q">was ' + esc(MARK_WORDS[h.was_mark] || h.was_mark)
                + "</span>"
              : ' <span class="rg-q">first mark</span>')
          + ' <span class="rg-q">' + esc(h.written_by) + "</span></li>");
      }
      out.push("</ul>");
      return out.join("");
    }

    function toggleHistory() {
      if (!OPEN) return;
      //  CLOSING NEVER TOUCHES THE NETWORK.
      if (HISTORY_OPEN) { HISTORY_OPEN = false; HISTORY = null; drawClass(); return; }
      if (busy) return;
      busy = true;
      HISTORY_OPEN = true; HISTORY = null;
      drawClass();   // shows the panel open, with "Loading the history…"
      sb.rpc("register_history", { p_class: OPEN.id, p_date: DATE })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {};
          if (d.allowed === false) {
            HISTORY_OPEN = false; HISTORY = null;
            fail("This area is for madrasah staff.");
            return;
          }
          HISTORY = d.rows || [];
        })["catch"](function (e) {
          HISTORY_OPEN = false; HISTORY = null;
          fail("The history would not open. " + (e && e.message ? e.message : ""));
        })["finally"](function () { busy = false; drawClass(); });
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

    function buildMarksList() {
      var list = [], k;
      for (k in MARKS) {
        if (MARKS.hasOwnProperty(k)) {
          list.push({ pupil_id: k, mark: MARKS[k].mark,
                      reason: MARKS[k].reason || null });
        }
      }
      return list;
    }

    function save() {
      if (busy || !OPEN) return;
      var list = buildMarksList();
      if (!list.length) return;
      busy = true; clearFail();
      sb.rpc("save_register_draft",
             { p_class: OPEN.id, p_date: DATE, p_marks: list })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {};
          DIRTY = false;
          say(d.marked + (d.marked === 1 ? " child" : " children") + " saved"
              + (d.parent_reports_kept
                  ? ", and " + d.parent_reports_kept + " parent’s message "
                    + "left as it was" : "") + ".");
          return refreshAfterWrite("Your marks are saved.");
        })["catch"](function (e) {
          fail("The register would not save. "
               + (e && e.message ? e.message : "")
               + " Nothing has been lost — the marks are still on screen.");
        })["finally"](function () { busy = false; });
    }

    /* -----------------------------------------------------------------------
       HANDING IN.

       submit_register() checks what is already written to the database, not
       what is still sitting in this tab — so a teacher who marks the last
       child and presses "Hand the register in" without ever pressing Save
       would be refused for a register they can see, on screen, is complete.
       Save first, then submit, so the button doing what it visibly can do
       does not depend on whether Save happened to be pressed first. Save
       always works, so this costs nothing when there is nothing new to
       write.
       --------------------------------------------------------------------- */
    function submitRegister() {
      if (busy || !OPEN) return;
      busy = true; clearFail();
      var list = buildMarksList();
      var saved = !list.length;   // nothing new to write counts as saved
      var persist = list.length
        ? sb.rpc("save_register_draft",
                 { p_class: OPEN.id, p_date: DATE, p_marks: list })
            .then(function (res) {
              if (res.error) throw new Error(res.error.message);
              saved = true;
              DIRTY = false;
            })
        : Promise.resolve();
      persist
        .then(function () {
          return sb.rpc("submit_register", { p_class: OPEN.id, p_date: DATE });
        })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          say("Register handed in. Thank you.");
          return refreshAfterWrite("The register is handed in.");
        })["catch"](function (e) {
          fail("The register was not handed in. "
               + (e && e.message ? e.message : "") + " "
               + (saved
                   ? "Your marks are saved."
                   : "Your marks were NOT saved — press Save, then try "
                     + "Hand in again."));
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
    //  writeOkMsg: see fetchClass() — same reasoning, same reload.
    function load(writeOkMsg) {
      return sb.rpc("madrasah_registers_list", { p_date: DATE })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {};
          if (d.allowed === false) { fail("This area is for madrasah staff."); return; }
          CLASSES = d.rows || [];
          GATE = d.permitted || null;
          drawGate(); drawEvening(); fetchMissing();
        })["catch"](function (e) {
          fail(writeOkMsg
            ? writeOkMsg + " The screen did not refresh. Reopen the class "
              + "to see it." + (e && e.message ? " (" + e.message + ")" : "")
            : "The classes would not load. " + (e && e.message ? e.message : ""));
        });
    }

    //  THE RELOAD AFTER A SUCCESSFUL WRITE. save() and submitRegister() both
    //  end with "refresh what's on screen from the database" — two calls,
    //  either of which can fail independently of the write that already
    //  succeeded. Both get the SAME write-succeeded wording on failure, so
    //  the teacher is never shown a message that puts the write itself in
    //  doubt for a problem that is only the screen not catching up.
    function refreshAfterWrite(writeOkMsg) {
      return load(writeOkMsg).then(function () {
        if (OPEN) return fetchClass(OPEN.id, writeOkMsg);
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
          if (t.id === "rg-submit") { submitRegister(); return; }
          if (t.id === "rg-history-toggle") { toggleHistory(); return; }
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
