/* ===========================================================================
   Taiyabah Masjid — Madrasah: the staff, the classes they take, and their DBS
   Bolton Central Islamic Society · Registered charity 1041569

   WHAT THIS SCREEN IS FOR
   -----------------------
   Migration 052 created the first three madrasah tables and imported forty
   members of staff out of the old system. Until this file existed there was
   exactly one way to read them back: SQL in the Supabase editor, which nobody
   in the masjid office is going to run. That mistake has now been made three
   times on this site — the course sign-ups in September, Gift Aid the same
   week, and the volunteer registrations — so it is worth saying plainly:
   putting data in a table and giving a human a way to work with it are two
   jobs, and only the first one feels finished.

   THE ONE FACT THIS SCREEN CARRIES
   --------------------------------
   Eighteen of the forty people on this list have NO DBS certificate date on
   file. Not "a check that has lapsed" — nothing at all. Everything about the
   layout follows from that: the DBS figures are the biggest thing on the page,
   "nothing on file" is coloured as the failure it is, and every row says in
   words what needs doing rather than showing a tick.

   TWO LISTS, BECAUSE THE MADRASAH IS TWO THINGS
   ---------------------------------------------
   Migration 053 added `side` — sisters or brothers — and the screen shows them
   as two columns rather than one list with a tag on every row. The madrasah
   teaches them separately and the lists are read separately: whoever is
   looking for a sisters' teacher is not scanning past sixteen brothers to find
   her.

   The import worked the side out from the honorific, so anybody with no
   honorific has none — one person today. A list split in two is the easiest
   place in the world to lose somebody: two columns showing 39 of 40 look
   completely normal, and the fortieth is not missing from anything you can
   see. So they are collected into their own labelled group ABOVE the columns,
   with their own count, and that group ignores the search and the pickers on
   purpose. It is not drawn at all when it is empty.

   WHY THERE IS NO GREEN TICK ANYWHERE
   -----------------------------------
   The system this replaces shows a green "DBS Valid" badge on a staff row.
   Three things are wrong with that and 052 fixed all three; this file must not
   quietly undo them.

     · The badge was a stored field, so it was wrong from the morning after the
       check lapsed and went on being wrong, in green, until somebody edited
       the record. Here the state is DERIVED — madrasah_staff_list() works it
       out on every read — so it cannot go stale.
     · A tick is not a sentence. "Checked" and the date it falls due tells
       somebody what to do; a tick tells them to stop looking.
     · Colour alone fails roughly one man in twelve. Every state here has a
       word, and the colour is on top of the word rather than instead of it.

   WHAT IS DELIBERATELY NOT HERE
   -----------------------------
     · NO DELETE BUTTON ON A ROW. Written down on /portal/ already, about the
       system this replaces: deleting a person's record is not a thing that
       should be one press away on a list. Somebody who has gone gets their
       employment set to "Left" and a leaving date, and the madrasah keeps
       what it held about who taught what and when.
     · NO PASSWORD FIELD. Also written down on /portal/. An administrator must
       never be able to set somebody else's password; that is the entire
       reason the invite link in /access/ exists. A staff record here is an
       employment record, not an account.
     · NO CERTIFICATE NUMBER. 052 does not store one, by decision, and this
       screen does not ask for one.

   Security notes for anyone maintaining this
   ------------------------------------------
     - Only the anon key is used. Every call below is refused by Postgres to
       anybody who is not an administrator who has completed two-step —
       verified_admin() runs inside each function. Hiding the panel from a
       teacher is a courtesy so they are not shown a screen full of refusals;
       it is not the access control and must never be mistaken for it.
     - The three madrasah tables have row level security enabled AND forced
       with no policies at all, so there is no direct read or write to find.
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
     THE STAFF
     ======================================================================= */
  var staff = (function () {

    var rows        = [];      // from madrasah_staff_list()
    var classRows   = [];      // from madrasah_classes_list()
    var query       = "";
    var dbsFilter   = "all";
    var classFilter = "all";
    var showLeft    = false;
    var editing     = null;    // the row being amended, or null for a new one
    var opened      = false;   // is the editor on screen at all
    var saveLabel   = "Add this person";
    var saved       = null;    // JSON of the boxes as they were when opened
    var wired       = false;

    /*  THE SEVEN DAYS, in the order a week runs, with the three-letter code
        the database keeps. The check constraint in 052 admits these seven and
        nothing else — a typo'd 'Thurs' sorting into a rota is a teacher who is
        not expected on the day they turn up. The tick boxes are built from
        this list, so a typo is not reachable from this screen at all. */
    var DAYS = [
      { k: "mon", short: "Mon", long: "Monday" },
      { k: "tue", short: "Tue", long: "Tuesday" },
      { k: "wed", short: "Wed", long: "Wednesday" },
      { k: "thu", short: "Thu", long: "Thursday" },
      { k: "fri", short: "Fri", long: "Friday" },
      { k: "sat", short: "Sat", long: "Saturday" },
      { k: "sun", short: "Sun", long: "Sunday" }
    ];

    var EMPLOYMENT = {
      employed:  "Employed",
      volunteer: "Volunteer",
      on_leave:  "On leave",
      left:      "Left"
    };

    var SECTIONS = { girls: "Girls", boys: "Boys", mixed: "Mixed" };

    var MONTHS = ["January", "February", "March", "April", "May", "June",
                  "July", "August", "September", "October", "November", "December"];

    /*  THE TWO NUMBERS, REPEATED HERE, AND WHY THAT IS NOT A MISTAKE.

        dbs_state() in 052 holds the masjid's renewal period (36 months) and
        the re-look on the Update Service (12 months), and it is the only thing
        allowed to decide whether a check has fallen due — that decision comes
        back in `row.dbs` and this file never second-guesses it.

        What the database does NOT send back is the DATE it falls due, and a
        row that says "Checked" without saying when it stops being true is half
        a sentence. So the date is worked out here from the same two numbers.

        If either number ever changes it changes in 052 with a migration, and
        it has to change here in the same afternoon. That is written on the
        migration too. The alternative was another round trip per row, or a
        column that goes stale, which is the exact fault 052 was built to
        avoid. */
    var RENEWAL_MONTHS = 36;
    var UPDATE_SERVICE_MONTHS = 12;
    var WARNING_DAYS = 90;

    function canSee(identity) {
      return identity.roles.indexOf("admin") !== -1;
    }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function trim(v) { return String(v == null ? "" : v).trim(); }

    function note(id, msg) {
      var box = el(id);
      if (!box) return;
      if (!msg) { box.hidden = true; box.innerHTML = ""; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    // ---- dates ---------------------------------------------------------------
    /*  A date column comes back as "YYYY-MM-DD". Parsed by hand rather than
        handed to new Date(string), because that is read as UTC midnight and
        anybody west of Greenwich then sees every date a day early. */
    function parseDate(iso) {
      var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(trim(iso));
      if (!m) return null;
      var d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
      return isNaN(d.getTime()) ? null : d;
    }

    /*  Postgres CLAMPS when it adds months: 31 January plus one month is 28
        February, not 3 March. JavaScript's setMonth rolls over instead. The
        difference only ever shows on a month end — which is exactly where a
        certificate date often sits — so this clamps, to agree with the
        database rather than to be a day or three out from it. */
    function addMonths(d, months) {
      var day = d.getDate();
      var out = new Date(d.getFullYear(), d.getMonth() + months, 1);
      var lastDay = new Date(out.getFullYear(), out.getMonth() + 1, 0).getDate();
      out.setDate(Math.min(day, lastDay));
      return out;
    }

    function today() {
      var n = new Date();
      return new Date(n.getFullYear(), n.getMonth(), n.getDate());
    }

    function humanDate(d) {
      if (!d) return "";
      return d.getDate() + " " + MONTHS[d.getMonth()] + " " + d.getFullYear();
    }

    function daysBetween(a, b) {
      return Math.round((b.getTime() - a.getTime()) / 86400000);
    }

    /*  WHEN THIS PERSON'S CHECK FALLS DUE, or null when the question does not
        arise — nothing on file, or not required for the role. The same two
        branches as dbs_state(): on the Update Service it is the last LOOK that
        starts the clock, because a check can be revoked the week after it is
        issued; otherwise it is the certificate itself. */
    function dueOn(r) {
      if (r.dbs_not_required) return null;
      var issued = parseDate(r.dbs_issued);
      if (!issued) return null;
      if (r.dbs_update_service) {
        return addMonths(parseDate(r.dbs_last_checked) || issued, UPDATE_SERVICE_MONTHS);
      }
      return addMonths(issued, RENEWAL_MONTHS);
    }

    /*  THE STATE, WORKED OUT IN THE BROWSER — for the editor only.

        Everywhere a saved record is shown, the state comes from the database
        (`row.dbs`), because the database is the one that is right. This mirror
        exists for one job: the line under the DBS boxes that says what the
        dates somebody has just typed will mean, BEFORE they press save. There
        is no saved row to ask about yet.

        It is the same ladder as dbs_state() in 052, in the same order. If that
        function changes, this changes with it. */
    function stateFrom(issued, updateService, lastChecked, notRequired) {
      if (notRequired) return "not_required";
      var d = parseDate(issued);
      if (!d) return "none";
      var due = updateService
        ? addMonths(parseDate(lastChecked) || d, UPDATE_SERVICE_MONTHS)
        : addMonths(d, RENEWAL_MONTHS);
      var now = today();
      if (due < now) return "overdue";
      //  90 days of warning — enough to book an appointment and have the
      //  certificate come back. The same number as v_warn in dbs_state().
      var warn = new Date(now.getFullYear(), now.getMonth(), now.getDate() + WARNING_DAYS);
      if (due < warn) return "due_soon";
      return "valid";
    }

    /*  THE WORDS ON A ROW. The state, spelled out, and — for anything that is
        not simply in date — what the person reading this is meant to do about
        it. Never a bare tick, never a bare colour. */
    function dbsWords(r) {
      var state = trim(r.dbs) || "none";
      var due   = dueOn(r);

      if (state === "not_required") {
        return { word: "Not required for this role", todo: "" };
      }
      if (state === "none") {
        return {
          word: "Nothing on file",
          todo: "Key in the date on their certificate. If the masjid has never " +
                "seen one, one is needed before they are on their own with children."
        };
      }
      if (state === "overdue") {
        return {
          word: "Overdue — needs re-checking",
          todo: due ? "It fell due on " + humanDate(due) + ". Arrange the re-check."
                    : "Arrange the re-check."
        };
      }
      if (state === "due_soon") {
        var n = due ? daysBetween(today(), due) : null;
        var word = n === null ? "Due soon"
                 : n <= 0     ? "Due today"
                 : n === 1    ? "Due in 1 day"
                 : "Due in " + n + " days";
        return {
          word: word,
          todo: due ? "Book it in now — it falls due on " + humanDate(due) + "."
                    : "Book it in now."
        };
      }
      return {
        word: "Checked",
        todo: due ? "Falls due " + humanDate(due) +
                    (r.dbs_update_service
                       ? " — on the Update Service, so it is a re-look rather than a new certificate."
                       : ".")
                  : ""
      };
    }

    // ---- small readers -------------------------------------------------------
    function nameOf(r) {
      return trim(r.display_name) ||
             trim([r.honorific, r.first_name, r.last_name].filter(Boolean).join(" ")) ||
             "(no name)";
    }

    function daysOf(r) {
      var set = Array.isArray(r.work_days) ? r.work_days : [];
      var out = DAYS.filter(function (d) { return set.indexOf(d.k) !== -1; })
                    .map(function (d) { return d.short; });
      return out;
    }

    function classesOf(r) {
      return Array.isArray(r.classes) ? r.classes : [];
    }

    function classLabel(c) {
      return trim(c.name) + (trim(c.year_label) ? " (" + trim(c.year_label) + ")" : "");
    }

    function byId(id) {
      for (var i = 0; i < rows.length; i++) {
        if (rows[i].id === id) return rows[i];
      }
      return null;
    }

    /*  WHO IS COUNTED. Somebody who has left is not part of the madrasah's DBS
        position — they are not in the building. madrasah_overview() takes the
        same view (employment <> 'left'), and two figures for the same question
        that disagree is how a committee paper ends up wrong. */
    function current() {
      return rows.filter(function (r) { return trim(r.employment) !== "left"; });
    }

    // ---- the figures at the top ----------------------------------------------
    function drawSummary() {
      var here = current();
      var gone = rows.length - here.length;

      var tot = el("st-tot");
      if (tot) {
        tot.innerHTML =
          '<span class="n">' + here.length + "</span>" +
          '<span class="k">On the staff list</span>' +
          '<span class="s">' +
            (here.length === 1 ? "One person who teaches or helps at the madrasah."
                               : "People who teach or help at the madrasah.") +
            (gone ? " " + (gone === 1
                             ? "One more has left and is kept on the record"
                             : gone + " more have left and are kept on the record") +
                    "; use the tick box below the search to see them."
                  : "") +
          "</span>";
      }

      var n = { valid: 0, due_soon: 0, overdue: 0, none: 0, not_required: 0 };
      here.forEach(function (r) {
        var s = trim(r.dbs) || "none";
        if (n[s] === undefined) n[s] = 0;
        n[s] += 1;
      });

      /*  The order is the order somebody reads them in, and it is the order
          the brief asked for: what is in hand first, then the three kinds of
          trouble, worst last so it is what the eye stops on. */
      var figs = [
        { k: "valid",    cls: "f-valid", label: "Checked",
          s: "In date. Each one still has a day it falls due." },
        { k: "due_soon", cls: "f-due",   label: "Due soon",
          s: "Falls due within 90 days. Time to book it." },
        { k: "overdue",  cls: "f-over",  label: "Overdue",
          s: "Past the masjid's renewal period. Needs re-checking now." },
        { k: "none",     cls: "f-none",  label: "Nothing on file",
          s: "No certificate date has ever been keyed in." }
      ];
      /*  Not required is a real answer and a quiet one — it is not a gap. It
          only appears once somebody has actually said it of somebody, so the
          strip does not carry a permanent nought. */
      if (n.not_required) {
        figs.push({ k: "not_required", cls: "f-nr", label: "Not required",
                    s: "Somebody has recorded that this role does not need one." });
      }

      var host = el("st-figs");
      if (host) {
        host.innerHTML = figs.map(function (f) {
          return '<div class="st-fig ' + f.cls + '">' +
            '<span class="n">' + (n[f.k] || 0) + "</span>" +
            '<span class="k">' + esc(f.label) + "</span>" +
            '<span class="s">' + esc(f.s) + "</span>" +
          "</div>";
        }).join("");
      }

      /*  A row of numbers still needs somebody to say out loud what it means.
          This is the sentence a trustee would say in a meeting, and it is why
          the figures are at the top of the screen rather than the bottom. */
      var alarm = el("st-alarm");
      if (alarm) {
        var gaps = (n.none || 0) + (n.overdue || 0);
        if (!here.length || !gaps) {
          alarm.hidden = true;
          alarm.textContent = "";
        } else {
          var bits = [];
          if (n.none) {
            bits.push(n.none === 1 ? "one has nothing on file at all"
                                   : n.none + " have nothing on file at all");
          }
          if (n.overdue) {
            bits.push(n.overdue === 1 ? "one is overdue" : n.overdue + " are overdue");
          }
          alarm.textContent = "Of the " + here.length + " people on this list, " +
            bits.join(" and ") + ". That is " + gaps + " of " + here.length +
            " the madrasah cannot answer a safeguarding question about today.";
          alarm.hidden = false;
        }
      }
    }

    // ---- the filter row ------------------------------------------------------
    function drawClassFilter() {
      var pick = el("st-class-filter");
      if (!pick) return;
      pick.innerHTML = '<option value="all">Any class</option>' +
        classRows.map(function (c) {
          return '<option value="' + esc(c.id) + '">' +
                 esc(classLabel(c)) + (c.is_active === false ? " — no longer running" : "") +
                 "</option>";
        }).join("");

      //  Keep whatever was chosen, if that class is still there. A reload that
      //  silently resets the filter reads as the filter not working; a filter
      //  left pointing at a class that has gone would show an empty list with
      //  no explanation, so that one falls back to "Any class".
      var stillThere = classFilter === "all" || classRows.some(function (c) {
        return c.id === classFilter;
      });
      if (!stillThere) classFilter = "all";
      pick.value = classFilter;
    }

    // ---- the list ------------------------------------------------------------
    function visible() {
      var q = query.toLowerCase();
      return rows.filter(function (r) {
        if (!showLeft && trim(r.employment) === "left") return false;
        if (dbsFilter !== "all" && (trim(r.dbs) || "none") !== dbsFilter) return false;
        if (classFilter !== "all") {
          var on = classesOf(r).some(function (c) { return c.id === classFilter; });
          if (!on) return false;
        }
        if (q && nameOf(r).toLowerCase().indexOf(q) === -1) return false;
        return true;
      });
    }

    /*  ONE ROW, WRITTEN ONCE, DRAWN IN THREE PLACES — the sisters' column, the
        brothers' column, and the group of people who have no side yet. They
        show exactly the same things, because they are the same rows; only
        which list they land in differs. */
    function rowHtml(r) {
      var dbs   = dbsWords(r);
      var state = trim(r.dbs) || "none";
      var emp   = trim(r.employment) || "employed";
      var cls   = classesOf(r);
      var days  = daysOf(r);
      var hasDays = Array.isArray(r.work_days) && r.work_days.length > 0;

      return '<button type="button" class="st-row d-' + esc(state) +
               (emp === "left" ? " e-left" : "") + '" data-id="' + esc(r.id) + '">' +

        //  WHO THEY ARE: name, what they are, what they take, when they are in.
        //  All four are answers to the same question, so they travel together
        //  and stay together however narrow the row gets.
        '<span class="st-who">' +
          "<span>" +
            '<span class="st-nm">' + esc(nameOf(r)) + "</span>" +
            //  Employed is the ordinary case and says nothing; the other three
            //  are worth a word on the row.
            (emp === "employed" ? "" :
              '<span class="st-emp' + (emp === "left" ? " e-left-tag" : "") + '">' +
              esc(EMPLOYMENT[emp] || emp) + "</span>") +
          "</span>" +

          '<span class="st-tags">' +
            (cls.length
              ? cls.map(function (c) {
                  return '<span class="st-tag">' + esc(c.name) + "</span>";
                }).join("")
              : '<span class="st-quiet">No class recorded</span>') +
          "</span>" +

          '<span class="st-days">' +
            (hasDays ? esc(days.join(" · "))
                     : '<span class="st-quiet">Days not set</span>') +
          "</span>" +
        "</span>" +

        //  WHERE THEIR DBS STANDS: a different question, so its own half.
        "<span>" +
          '<span class="st-state s-' + esc(state) + '">' + esc(dbs.word) + "</span>" +
          (dbs.todo ? '<span class="st-todo">' + esc(dbs.todo) + "</span>" : "") +
        "</span>" +

        //  TWO DIFFERENT SENTENCES THAT USED TO BE ONE.
        //
        //  Until 054 both of these lived in `note`, as a paragraph naming the
        //  system the madrasah used before. The masjid asked for that name to
        //  come off the records, and it had no business in that field anyway:
        //  `note` belongs to whoever is using this system, and the first
        //  person to type a real note into it would have destroyed the only
        //  record of what the previous system said about that person's DBS.
        //
        //  So they are separate now and they are shown separately, because
        //  they carry different weight. priorLine() is hearsay about a
        //  question this system cannot yet answer. A note is the masjid's own
        //  words. Running them together made the second look like the first.
        priorLine(r) +
        (trim(r.note) ? '<span class="st-note">' + esc(r.note) + "</span>" : "") +

      "</button>";
    }

    /*  THE ORDER IS THE DATABASE'S ORDER, AND IT IS BY SURNAME.

        madrasah_staff_list() sorts by last_name then first_name, which is the
        whole reason 052 pulled the honorific out into its own column — in the
        old system "Apa" was part of the name, so an A to Z list put nineteen
        people under A and sorted them by their first names. Re-sorting here by
        display_name would put every one of them back under A and throw that
        away. Splitting the list in two does not disturb it: filter keeps the
        order it was given, so each column is still by surname. */
    function fillList(hostId, list, empty) {
      var box = el(hostId);
      if (!box) return;
      box.innerHTML = list.length
        ? list.map(rowHtml).join("")
        : '<div class="st-empty">' + esc(empty) + "</div>";
    }

    /*  The number beside a column heading. When nothing is being filtered it is
        simply how many people are on that side. When something IS, it says both
        — "5 of 23" — because a bare 5 under a heading that said 23 a moment ago
        reads as eighteen people having gone missing. */
    function countLabel(showing, total) {
      return showing === total ? String(total) : showing + " of " + total;
    }

    function setCount(id, showing, total) {
      var n = el(id);
      if (n) n.textContent = countLabel(showing, total);
    }

    function sideOf(r) {
      var s = trim(r.side).toLowerCase();
      return (s === "sisters" || s === "brothers") ? s : "";
    }

    /*  WHAT THE PREVIOUS SYSTEM SAID, WHICH IS NOT THE SAME AS WHAT IS KNOWN.

        Every one of the forty people brought over shows "Nothing on file",
        and that is honest: no certificate date came across, and none was
        invented. But it flattens a real difference. Twenty-two of them were
        recorded elsewhere as holding a valid DBS and are waiting on somebody
        to key in a date. Sixteen were recorded as having none — and those
        sixteen are the actual safeguarding question, not a typing job.

        A screen that cannot tell those two apart sends whoever is working
        through the list at forty names in the order they happen to appear,
        instead of at the sixteen that matter.

        THIS IS NOT A DBS STATE AND IS NOT COLOURED LIKE ONE. dbs_state()
        ignores prior_dbs entirely, so the row's edge and its state word still
        report only what this system can stand behind. This sentence sits
        underneath in the muted note style, worded as a report of somebody
        else's records — because that is all it is, and a screen that treats
        hearsay as a check is worse than one that says nothing. It disappears
        the moment a real date is entered, because the database clears the
        column at that point. */
    function priorLine(r) {
      var was = trim(r.prior_dbs).toLowerCase();
      if (!was) return "";
      var said =
        was === "valid"   ? "recorded a valid DBS for this person, without a certificate date"
      : was === "expired" ? "recorded an expired DBS for this person"
      : was === "none"    ? "recorded no DBS for this person"
      : "";
      if (!said) return "";
      return '<span class="st-note">The madrasah’s previous records ' + said +
             ". Nothing has been entered here from that and nothing has been " +
             "invented — it has to come off the certificate.</span>";
    }

    function drawList() {
      var shown = visible();
      var pool  = rows.filter(function (r) {
        return showLeft || trim(r.employment) !== "left";
      });

      var nothingAtAll = !rows.length;
      var nothingShown = !shown.length;

      ["sisters", "brothers"].forEach(function (side) {
        var mine  = shown.filter(function (r) { return sideOf(r) === side; });
        var all   = pool.filter(function (r) { return sideOf(r) === side; });
        var label = side === "sisters" ? "sisters’" : "brothers’";
        fillList("st-list-" + side, mine,
          nothingAtAll
            ? "Nobody is on the staff list yet. Press “Add somebody” to put the " +
              "first person on it."
            : nothingShown
              ? "Nobody matches what you have asked for. Clear the search or set " +
                "the pickers back to “Any”."
              : "Nobody on the " + label + " side matches what you have asked for.");
        setCount("st-n-" + side, mine.length, all.length);
      });

      /*  NOBODY IS QUIETLY DROPPED BETWEEN THE TWO COLUMNS.

          Everybody with no side is shown here, with their own count, above the
          two lists. The group is not drawn at all when it is empty — a
          permanent "Side not set: 0" is a box that teaches people to stop
          reading it, and this one has to be read on the day it is not nought.

          It ignores the search and the two pickers ON PURPOSE. A person with no
          side is a job to be done rather than a search result, and filtering
          them out of view is precisely the disappearing act this group exists
          to prevent. It does respect the left tick box, because somebody who
          left two years ago does not need a side choosing. */
      var unset = pool.filter(function (r) { return sideOf(r) === ""; });
      var box   = el("st-unset");
      if (box) box.hidden = unset.length === 0;
      if (unset.length) {
        fillList("st-list-unset", unset, "");
        setCount("st-n-unset", unset.length, unset.length);
        var why = el("st-unset-why");
        if (why) {
          why.textContent = (unset.length === 1
            ? "One person has no side recorded, so they are in neither list below."
            : unset.length + " people have no side recorded, so they are in " +
              "neither list below.") +
            " They are up here rather than quietly missing from both. Press a row " +
            "and choose a side. The import worked it out from the title, so these " +
            "are the ones with no title at all.";
        }
      }
    }

    // ---- the editor ----------------------------------------------------------
    function drawDayTicks(chosen) {
      var host = el("st-day-ticks");
      if (!host) return;
      host.innerHTML = DAYS.map(function (d) {
        return '<label class="st-tick">' +
          '<input type="checkbox" data-day="' + d.k + '"' +
          (chosen.indexOf(d.k) !== -1 ? " checked" : "") + ">" +
          "<span>" + esc(d.long) + "</span></label>";
      }).join("");
    }

    /*  THE CLASSES, AS TICK BOXES RATHER THAN A MULTI-SELECT LIST.

        A <select multiple> needs a control key to pick a second option, holds
        four rows on a phone, and gives no hint that more than one is allowed.
        These are opened in a corridor by somebody who is not sitting down, so
        each class is its own 44-pixel row that can be tapped.

        A class that is no longer running is offered ONLY if this person is
        already on it. Otherwise the list grows for ever and somebody puts a
        new teacher on a class that finished two years ago; but silently
        dropping one they are already on would quietly take it off them the
        next time anybody saved the record. */
    function drawClassTicks(chosen) {
      var host = el("st-classes");
      if (!host) return;

      var offer = classRows.filter(function (c) {
        return c.is_active !== false || chosen.indexOf(c.id) !== -1;
      });

      if (!offer.length) {
        host.innerHTML = '<div class="st-empty">No classes are set up yet. ' +
          'Somebody has to add the madrasah’s classes before a teacher ' +
          'can be put on one.</div>';
        return;
      }

      /*  Grouped by section, and the groups are walked in a fixed order rather
          than taken from the order the rows arrive in. madrasah_classes_list()
          does sort by section, but a heading that appears twice because one
          row came back out of order is the sort of thing nobody notices until
          a volunteer ticks the wrong "Girls". */
      var html = "";
      Object.keys(SECTIONS).forEach(function (s) {
        var mine = offer.filter(function (c) {
          return (trim(c.section) || "girls") === s;
        });
        if (!mine.length) return;
        html += '<span class="st-cls-lab">' + esc(SECTIONS[s]) + "</span>";
        html += mine.map(function (c) {
          return '<label class="st-tick"><input type="checkbox" data-class="' +
            esc(c.id) + '"' + (chosen.indexOf(c.id) !== -1 ? " checked" : "") + ">" +
            "<span" + (c.is_active === false ? ' class="st-gone"' : "") + ">" +
            esc(classLabel(c)) +
            (c.is_active === false ? " — no longer running" : "") +
            "</span></label>";
        }).join("");
      });
      host.innerHTML = html;
    }

    function openEditor(r) {
      editing = r || null;
      opened  = true;

      var set = function (id, v) { var n = el(id); if (n) n.value = v == null ? "" : v; };
      var tick = function (id, v) { var n = el(id); if (n) n.checked = !!v; };

      set("st-honorific",  r && r.honorific);
      set("st-first",      r && r.first_name);
      set("st-last",       r && r.last_name);
      //  A side that is neither of the two known words — including null, which
      //  is what the import left behind for anybody with no title — lands on
      //  "Not set", which is the truth rather than a guess at one of the two.
      set("st-side", r ? sideOf(r) : "");
      set("st-employment", (r && trim(r.employment)) || "employed");
      set("st-started",    r && r.started_on);
      set("st-left",       r && r.left_on);
      set("st-email",      r && r.email);
      set("st-phone",      r && r.phone);
      set("st-note",       r && r.note);
      set("st-dbs-issued", r && r.dbs_issued);
      set("st-dbs-checked", r && r.dbs_last_checked);
      tick("st-dbs-update", r && r.dbs_update_service);
      tick("st-dbs-nr",     r && r.dbs_not_required);

      drawDayTicks(r && Array.isArray(r.work_days) ? r.work_days : []);
      drawClassTicks(r ? classesOf(r).map(function (c) { return c.id; }) : []);

      saveLabel = r ? "Save this record" : "Add this person";
      if (el("st-save")) el("st-save").textContent = saveLabel;

      if (el("st-form-head")) {
        el("st-form-head").textContent = r ? nameOf(r) : "Add somebody";
      }
      if (el("st-form-lede")) {
        el("st-form-lede").textContent = r
          ? "Everything the madrasah holds about this person. Whatever you save " +
            "here is what it holds from the moment you press the button; nothing " +
            "is a draft."
          : "A new member of staff. At least a first name is needed — everything " +
            "else can be filled in later, and the list will say plainly what is " +
            "still missing.";
      }
      if (el("st-meta")) {
        el("st-meta").textContent = r
          ? "You are amending a record that already exists. Saving replaces what " +
            "the madrasah holds, including the classes ticked above."
          : "Nothing is saved until you press the button above.";
      }
      if (el("st-classes-hint")) {
        el("st-classes-hint").textContent = classRows.length
          ? "Tick as many as apply. Untick them all and this person is recorded as " +
            "taking no class, which is a real answer for somebody who helps rather " +
            "than teaches."
          : "Tick as many as apply.";
      }

      saved = JSON.stringify(readForm());
      note("st-complaints", "");
      hideConfirm();   // a question left up from the last record is not this one's
      revalidate();

      var box = el("st-editor");
      if (box) {
        box.hidden = false;
        box.scrollIntoView({ block: "start" });
      }
      if (el("st-first")) el("st-first").focus();
    }

    function shutEditor() {
      /*  Only scroll if something was actually open. mount() calls this to put
          the list first, and scrolling then would push the DBS figures off the
          top of the screen on arrival — which are the whole reason the figures
          are at the top. Closing an editor the person opened is different:
          they are two screens down the page and need putting back. */
      var wasOpen = opened;
      editing = null;
      opened  = false;
      saved   = null;
      var box = el("st-editor");
      if (box) box.hidden = true;
      note("st-complaints", "");
      hideConfirm();
      if (!wasOpen) return;
      /*  Back to the top of the lists. The "side not set" group when there is
          one, because that is where the person most likely came from and it
          sits above the two columns anyway, so landing there shows both. */
      var unset = el("st-unset");
      var back  = (unset && !unset.hidden) ? unset : el("st-cols");
      if (back) back.scrollIntoView({ block: "start" });
    }

    /*  WHAT IS IN THE BOXES, as plain values. No trimming decisions and no
        cleverness — save_madrasah_staff() trims and nulls empty strings itself,
        and doing it twice in two places is how the two come to disagree. */
    function readForm() {
      var v = function (id) { var n = el(id); return n ? n.value : ""; };
      var c = function (id) { var n = el(id); return !!(n && n.checked); };

      var days = [];
      var daysHost = el("st-day-ticks");
      if (daysHost) {
        Array.prototype.forEach.call(
          daysHost.querySelectorAll("input[data-day]"), function (box) {
            if (box.checked) days.push(box.getAttribute("data-day"));
          });
      }

      var classIds = [];
      var clsHost = el("st-classes");
      if (clsHost) {
        Array.prototype.forEach.call(
          clsHost.querySelectorAll("input[data-class]"), function (box) {
            if (box.checked) classIds.push(box.getAttribute("data-class"));
          });
      }

      return {
        honorific:  v("st-honorific"),
        first_name: v("st-first"),
        last_name:  v("st-last"),
        side:       v("st-side"),
        employment: v("st-employment"),
        started_on: v("st-started"),
        left_on:    v("st-left"),
        work_days:  days,
        dbs_issued:         v("st-dbs-issued"),
        dbs_update_service: c("st-dbs-update"),
        dbs_last_checked:   v("st-dbs-checked"),
        dbs_not_required:   c("st-dbs-nr"),
        email:      v("st-email"),
        phone:      v("st-phone"),
        note:       v("st-note"),
        class_ids:  classIds
      };
    }

    /*  WHAT THE DATABASE WILL REFUSE, SAID FIRST AND IN ENGLISH.

        These are the rules in 052 and NOT ONE MORE. Every rule this checks
        that Postgres does not have is a rule a volunteer cannot get past and
        cannot find written down anywhere; every rule Postgres has that this
        does not check is somebody being told they are fine and then handed a
        raw constraint name. So the list below is short on purpose:

          madrasah_staff_has_a_name        first name, 1 to 60 characters
          madrasah_staff_employment_known  one of the four
          madrasah_staff_left_makes_sense  (employment = 'left') = (left_on is not null)

        `side` is not checked here and does not need to be: it comes from a
        dropdown offering exactly the two words the database accepts and an
        empty one, so there is no third value for a person to produce. Having
        no side is a real answer and must stay one — the whole point of the
        "Side not set" group is that guessing is worse than not knowing.

        Pure — no DOM, no network, no state — so a test can call it. */
    function check(f) {
      f = f || {};
      var out = [];

      var first = trim(f.first_name);
      if (!first) {
        out.push("Put in at least a first name. A record with no name on it is " +
                 "not a record anybody can use.");
      } else if (first.length > 60) {
        out.push("The first name is " + first.length + " characters long. The " +
                 "database holds 60 at most.");
      }

      var emp = trim(f.employment);
      if (!EMPLOYMENT.hasOwnProperty(emp)) {
        out.push("Pick one of the four kinds of employment.");
      }

      var left = trim(f.left_on);
      if (emp === "left" && !left) {
        out.push("Put in the date they left. The database keeps “Left” and a " +
                 "leaving date together — one without the other is refused, " +
                 "because a record marked left with no date is a record nobody " +
                 "can check.");
      }
      if (emp && emp !== "left" && left) {
        out.push("There is a leaving date here, but their employment says “" +
                 (EMPLOYMENT[emp] || emp) + "”. Either set it to “Left”, or clear " +
                 "the date.");
      }

      return out;
    }

    function revalidate() {
      if (!opened) return [];
      var f = readForm();
      var problems = check(f);

      var box = el("st-complaints");
      if (box) {
        if (problems.length) {
          box.innerHTML = "<ul>" + problems.map(function (p) {
            return "<li>" + esc(p) + "</li>";
          }).join("") + "</ul>";
          box.hidden = false;
        } else {
          box.hidden = true;
          box.innerHTML = "";
        }
      }

      var btn = el("st-save");
      if (btn) btn.disabled = problems.length > 0;

      //  What the dates in the boxes will mean once they are saved. Worked out
      //  here because there is no saved row to ask the database about yet —
      //  see stateFrom().
      var now = el("st-dbs-now");
      if (now) {
        var state = stateFrom(f.dbs_issued, f.dbs_update_service,
                              f.dbs_last_checked, f.dbs_not_required);
        var words = dbsWords({
          dbs: state,
          dbs_issued: f.dbs_issued,
          dbs_update_service: f.dbs_update_service,
          dbs_last_checked: f.dbs_last_checked,
          dbs_not_required: f.dbs_not_required
        });
        now.textContent = "As the boxes stand, the list will show: " + words.word +
                          (words.todo ? ". " + words.todo : ".");
      }

      return problems;
    }

    // ---- reading -------------------------------------------------------------
    /*  TWO CALLS, AND BOTH ARE NEEDED. madrasah_staff_list() has the people and
        the classes each of them takes, by name. madrasah_classes_list() has
        every class there is, which is what the class picker in the editor and
        the class filter above the list are built from — a staff list alone
        cannot offer a class nobody teaches yet. */
    function load() {
      return Promise.all([
        sb.rpc("madrasah_staff_list"),
        sb.rpc("madrasah_classes_list")
      ]).then(function (out) {
        if (out[0].error) {
          //  Until 052 is applied none of these functions exist. That is "not
          //  set up yet", not "broken", and saying so saves somebody hunting a
          //  fault that is not there.
          if (/does not exist|schema cache|function/i.test(out[0].error.message || "")) {
            throw new Error("The staff list needs " +
                            "052_the_madrasah_knows_its_staff.sql, which hasn't " +
                            "been run yet.");
          }
          throw new Error(out[0].error.message);
        }
        if (out[1].error) throw new Error(out[1].error.message);

        rows      = Array.isArray(out[0].data) ? out[0].data : [];
        classRows = Array.isArray(out[1].data) ? out[1].data : [];

        //  Whoever was open stays open, with whatever has been typed into the
        //  boxes left exactly where it is.
        if (editing) {
          var still = byId(editing.id);
          if (still) editing = still;
        }

        drawSummary();
        drawClassFilter();
        drawList();
      });
    }

    // ---- writing -------------------------------------------------------------
    /*  ONE CALL. save_madrasah_staff() creates and amends in the same function
        — an id means amend and no id means create — so there is one set of
        rules rather than two that drift apart.

        class_ids is ALWAYS sent. Leaving it out means "leave their classes
        alone", which is right for a program doing a partial update and wrong
        for a screen whose tick boxes are all sitting there in front of
        somebody: if they untick every class and press save, they mean none,
        and an empty array is how that is said. */
    /*  ASKING FIRST, AND ONLY WHEN THERE IS SOMETHING TO ASK ABOUT.

        Amending an existing record overwrites what the madrasah holds about a
        real person, from a list of forty rows that look alike. Opening the
        wrong one and saving over it leaves nothing behind that anybody would
        notice. So it asks, by name — the name is the whole point of the
        question, because it is what tells you whether the record in front of
        you is the one you meant to open.

        ADDING SOMEBODY NEW DOES NOT ASK. It overwrites nothing, an unwanted
        row is visible on the list the moment it appears, and a confirm on
        every single save is how a confirm stops being read. */
    function hideConfirm() {
      var box = el("st-confirm");
      if (box) box.hidden = true;
    }

    function askToSave() {
      if (!opened) return;
      var f = readForm();
      if (check(f).length) { revalidate(); return; }   // the button is disabled too

      //  A record with no id has never been written, so there is nothing to
      //  overwrite and nothing to be sure about.
      if (!(editing && editing.id)) { save(); return; }

      var who = trim(f.first_name) + (trim(f.last_name) ? " " + trim(f.last_name) : "");
      var q   = el("st-confirm-q");
      if (q) {
        q.textContent = "Save these changes to " + (who || "this record") + "? " +
          "This replaces what the madrasah currently holds about them.";
      }
      var box = el("st-confirm");
      if (box) {
        box.hidden = false;
        box.scrollIntoView({ block: "nearest" });
      }
      var yes = el("st-confirm-yes");
      if (yes) yes.focus();
    }

    function save() {
      if (!opened) return;
      hideConfirm();
      var f = readForm();
      if (check(f).length) { revalidate(); return; }   // the button is disabled too

      var p = {
        honorific:  f.honorific,
        first_name: f.first_name,
        last_name:  f.last_name,
        //  Empty means "nobody has said", and it is sent as an empty string
        //  exactly like the dates are: save_madrasah_staff() is what turns an
        //  empty string into a null, in one place, for every field.
        side:       f.side,
        employment: f.employment,
        started_on: f.started_on,
        left_on:    f.left_on,
        work_days:  f.work_days,
        dbs_issued:         f.dbs_issued,
        dbs_update_service: f.dbs_update_service,
        dbs_last_checked:   f.dbs_last_checked,
        dbs_not_required:   f.dbs_not_required,
        email: f.email,
        phone: f.phone,
        note:  f.note,
        class_ids: f.class_ids
      };
      if (editing && editing.id) p.id = editing.id;

      var who     = trim(f.first_name) + (trim(f.last_name) ? " " + trim(f.last_name) : "");
      var wasNew  = !p.id;
      var btn     = el("st-save");
      var written = false;

      busy(btn, true, saveLabel);
      note("st-error", ""); note("st-ok", "");

      //  The argument is named `p` — save_madrasah_staff(p jsonb). Supabase
      //  sends the keys of this object as the function's named arguments, so a
      //  wrapper key of any other name is "function does not exist".
      sb.rpc("save_madrasah_staff", { p: p }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        written = true;
        shutEditor();
        return load();
      }).then(function () {
        note("st-ok", wasNew
          ? who + " is on the staff list."
          : "Saved. The list below shows what the madrasah now holds about " + who + ".");
      }).catch(function (e) {
        var msg = (e && e.message) || String(e);
        if (written) {
          //  A reload that fails AFTER a good save must not be reported as a
          //  failed save — that is the sort of lie that has somebody typing
          //  the same record in twice.
          note("st-error", "Saved. The list on this screen couldn't be re-read " +
                           "afterwards — " + msg + " Refresh the page to see where " +
                           "things stand; nothing is waiting to be saved.");
          return;
        }
        note("st-error", "Nothing was saved — " + msg);
      }).finally(function () {
        busy(btn, false, saveLabel);
        revalidate();
      });
    }

    // ---- wiring --------------------------------------------------------------
    function wire() {
      if (wired) return true;
      wired = true;

      var find = el("st-find");
      if (find) find.addEventListener("input", function () {
        query = trim(this.value);
        drawList();
      });

      var dbsPick = el("st-dbs-filter");
      if (dbsPick) dbsPick.addEventListener("change", function () {
        dbsFilter = this.value;
        drawList();
      });

      var clsPick = el("st-class-filter");
      if (clsPick) clsPick.addEventListener("change", function () {
        classFilter = this.value;
        drawList();
      });

      var left = el("st-show-left");
      if (left) left.addEventListener("change", function () {
        showLeft = this.checked;
        drawList();
      });

      /*  ONE LISTENER FOR ALL THREE LISTS, not one per list and certainly not
          one per row. The rows are redrawn every time anything is typed into
          the search box, so per-row listeners would be re-attached on each
          keystroke and the old ones left behind; and there are three hosts now
          rather than one, so listening on the panel above them means a fourth
          list added later is wired the day it is drawn.

          `button.st-row` and not `button[data-id]`: the panel also holds Add,
          Save and Back to the list, and a row is the only thing here that
          should open somebody's record. */
      var lists = el("st-panel");
      if (lists) lists.addEventListener("click", function (ev) {
        var btn = ev.target.closest ? ev.target.closest("button.st-row") : null;
        if (!btn) return;
        var r = byId(btn.getAttribute("data-id"));
        if (!r) return;
        note("st-error", ""); note("st-ok", "");
        openEditor(r);
      });

      var add = el("st-add");
      if (add) add.addEventListener("click", function () {
        note("st-error", ""); note("st-ok", "");
        openEditor(null);
      });

      var cancel = el("st-cancel");
      if (cancel) cancel.addEventListener("click", function () {
        shutEditor();
        note("st-error", ""); note("st-ok", "");
      });

      var saveBtn = el("st-save");
      if (saveBtn) saveBtn.addEventListener("click", askToSave);

      var yes = el("st-confirm-yes");
      if (yes) yes.addEventListener("click", save);

      /*  "No" puts them back in the form with everything still in it. It is
          not an undo — nothing has been sent — and saying so is what stops it
          being read as one. */
      var no = el("st-confirm-no");
      if (no) no.addEventListener("click", function () {
        hideConfirm();
        if (el("st-save")) el("st-save").focus();
      });

      /*  UNDO, WITHOUT ASKING FIRST. Nothing has been sent anywhere, so there
          is nothing to warn about — and there is no browser dialog anywhere on
          this screen, because a browser dialog is the one thing on a page that
          a person cannot read at their own pace, cannot zoom, and cannot get
          back once it has gone. The button says what it does, and the sentence
          afterwards says what happened. */
      var revert = el("st-revert");
      if (revert) revert.addEventListener("click", function () {
        if (!opened || !saved) {
          note("st-error", "There is nothing to go back to — no record is open.");
          return;
        }
        var was = JSON.parse(saved);
        var set = function (id, v) { var n = el(id); if (n) n.value = v == null ? "" : v; };
        var tick = function (id, v) { var n = el(id); if (n) n.checked = !!v; };
        set("st-honorific", was.honorific);
        set("st-first", was.first_name);
        set("st-last", was.last_name);
        set("st-side", was.side);
        set("st-employment", was.employment);
        set("st-started", was.started_on);
        set("st-left", was.left_on);
        set("st-email", was.email);
        set("st-phone", was.phone);
        set("st-note", was.note);
        set("st-dbs-issued", was.dbs_issued);
        set("st-dbs-checked", was.dbs_last_checked);
        tick("st-dbs-update", was.dbs_update_service);
        tick("st-dbs-nr", was.dbs_not_required);
        drawDayTicks(was.work_days || []);
        drawClassTicks(was.class_ids || []);
        //  Undo puts values back without typing, so no input event fires and
        //  the confirm strip would sit there naming a save of the old boxes.
        hideConfirm();
        revalidate();
        note("st-error", "");
        note("st-ok", "Back to how the record was when you opened it. Nothing had " +
                      "been saved either way.");
      });

      /*  Everything in the editor revalidates on the way past. One listener on
          the editor rather than twenty on the boxes, for the same reason as the
          list: the day and class ticks are redrawn and per-box listeners would
          not survive it. */
      var editor = el("st-editor");
      if (editor) {
        editor.addEventListener("input", revalidate);
        editor.addEventListener("change", revalidate);

        /*  CHANGE ANYTHING AND THE QUESTION IS WITHDRAWN.

            The confirm names the person and says it replaces their record.
            If somebody puts it up, then edits a box behind it, that sentence
            is describing a save that is no longer the one that would happen.
            Answering a stale question is worse than being asked twice, so it
            closes and has to be raised again against what is now in the form.
            The typing itself is untouched — only the question goes.          */
        editor.addEventListener("input", hideConfirm);
        editor.addEventListener("change", hideConfirm);
      }

      return true;
    }

    function mount(identity) {
      var panel = el("st-panel");
      var card  = el("view-app");
      var noaccess = el("app-noaccess");
      if (!panel) return;

      /*  The database refuses every call on this screen to anybody who is not
          an administrator who has completed two-step. Hiding the panel from a
          teacher is a courtesy — a screen full of refusals reads as broken —
          and not the access control. See the header. */
      if (!canSee(identity)) {
        panel.hidden = true;
        if (noaccess) noaccess.hidden = false;
        return;
      }
      if (noaccess) noaccess.hidden = true;
      panel.hidden = false;
      if (card) card.classList.add("is-wide");
      wire();
      shutEditor();   // the list first; a record is opened by pressing its row

      return load().catch(function (e) {
        //  Both columns say so, rather than one saying nothing and reading as
        //  a side with nobody on it.
        ["st-list-sisters", "st-list-brothers"].forEach(function (id) {
          var box = el(id);
          if (box) box.innerHTML = '<div class="st-empty">The staff list couldn’t ' +
                                   'be read — the message above says why.</div>';
        });
        var unset = el("st-unset");
        if (unset) unset.hidden = true;
        note("st-error", "Couldn't read the staff: " + ((e && e.message) || e));
      });
    }

    return { mount: mount, _check: check, _wire: wire, _state: stateFrom };
  })();

  /*  EXPOSED FOR THE TESTS, on the same reasoning as __COURSE_FORM in
      courses/ and __NOTICE_FORM in notices/.

      check() is the browser's copy of the three constraints in 052. Where it
      disagrees with Postgres a volunteer is told something is fine and is then
      handed a raw constraint name, which is the fault every validator on this
      site exists to prevent — so it has to be reachable without a sign-in.

      wire() is not pure, and it is here because of a trap this project has
      fallen into twice. "Nothing is saveable until the record is valid" would
      otherwise live only inside mount(), which runs after a real sign-in, so no
      test could reach it — and the Save button would read as disabled whether
      the rule was there or had been deleted. Wiring the form on a page nobody
      is signed in to gives a Save button whose click calls
      save_madrasah_staff(), which Postgres refuses to anybody who is not a
      verified administrator with two-step. The permission is in the database,
      not in this file. */
  window.__STAFF_FORM = { check: staff._check, wire: staff._wire, state: staff._state };

  /*  The rail is two folders up from here, and shell.js is told so with
      `depth: 2` in the mount below. An earlier version of this screen walked
      the mounted rail rewriting every href instead — it worked, and it was the
      start of a habit: the next nested screen copies it, the one after copies
      it slightly wrong, and then three files know how deep a page is. The
      shell owns that arithmetic now. */

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
        current:  'md-staff',
        title:    'Staff',
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
    try { staff.mount(identity); } catch (e) {
      if (window.console) console.warn("staff panel unavailable:", e);
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
