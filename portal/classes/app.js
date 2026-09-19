/* ===========================================================================
   THE CLASSES, AND ONE CLASS.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   18 September 2026

   WHAT THE MASJID ASKED FOR AND WHY IT IS RIGHT:

       "each class should be laid out neatly and easily navigable... would like
        this to be available when someone clicks INTO the class rather than
        what ibeams has, as what ibeams has looks unclean and too messy."

   The old system puts Edit, Manage Students, Download PDF and Delete on every
   row. Across forty-five classes that is a hundred and eighty controls on one
   screen, of which a hundred and seventy-six are wrong for whatever you came
   to do, and two are destructive. A list is for FINDING; the moment every row
   carries its own verbs it stops being scannable.

   So the list holds the three things you would sort by — name, teacher,
   headcount — and everything you can DO is one press deeper, on a screen about
   exactly one class.

   THE REGISTER IS NOT FETCHED UNTIL SOMEBODY ASKS FOR IT. Headcounts come with
   the class list, so this screen is useful without a single child's name
   leaving the database. "Who is in it" is the one control that changes that,
   and it stays a deliberate act rather than a side effect of opening a page.

   WHO SEES WHAT IS DECIDED IN POSTGRES. madrasah_class_list() returns every
   class to an administrator and only their own to a teacher;
   madrasah_pupils_in_class() refuses a class that is not theirs outright
   rather than answering with an empty list — an empty list is a different and
   false statement, and it is what would let somebody map the madrasah by
   trying class ids one at a time. See db/058.
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
     THE CLASSES
     ======================================================================= */
  var classes = (function () {

    var ROWS = [];
    var STAFF = [];           // names only, for the main-teacher picker
    var EDIT_ROLL = [];       // who is in the class while the editor is open
    var findTimer = null;
    var mayAmend = false;
    var open = null;          // the class whose page is showing
    var roll = null;          // its pupils, once fetched
    var query = "", side = "all", showOff = false;
    var wired = false;
    var want = null;          // what the confirm strip is asking about

    var SIDES = [
      { k: "girls", name: "Girls" },
      { k: "boys",  name: "Boys" },
      { k: "mixed", name: "Mixed" }
    ];

    /*  A LIST, OR AN EMPTY ONE — AND `|| []` IS NOT THAT CHECK.

        This was `STAFF = r2.data || []`, which looks like a guard and is not:
        `{}` is truthy, so an answer of the wrong SHAPE sails through and the
        next `.map()` throws. It happened here — the staff-names call returned
        an object, the picker threw inside the click handler, and the whole
        "Amend this class" editor silently failed to open. Nothing on screen
        said why, because the exception was in the listener and the page
        carried on looking perfectly well.

        Falsiness is not the failure mode worth guarding. Wrong type is.     */
    function list(v) { return Array.isArray(v) ? v : []; }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function trim(v) { return String(v == null ? "" : v).trim(); }

    function note(id, msg) {
      var box = el(id);
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    function teachersOf(c) {
      return list(c.teachers).map(function (t) { return trim(t.name); })
               .filter(Boolean);
    }

    // ---- reading ------------------------------------------------------------
    function load() {
      return sb.rpc("madrasah_class_list").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        var d = res.data || {};
        mayAmend = !!d.may_amend;
        ROWS = list(d.classes);
        drawList();
        /*  The staff names, for the main-teacher picker, and only for an
            administrator — it is the only account that can amend a class.
            Its own function rather than madrasah_staff_list(), which carries
            DBS positions and telephone numbers: choosing a teacher needs a
            name, and a narrower reason gets a narrower function.

            Deliberately not awaited. A failure here costs the picker, not the
            page, and the classes are what somebody came for. */
        if (mayAmend && !STAFF.length) {
          sb.rpc("madrasah_staff_names").then(function (r2) {
            if (!r2.error) STAFF = list(r2.data);
          }).catch(function () { /* the picker degrades to "Not chosen" */ });
        }
      });
    }

    // ---- the list -----------------------------------------------------------
    function visible() {
      var q = query.toLowerCase();
      return ROWS.filter(function (c) {
        if (!showOff && c.is_active === false) return false;
        if (side !== "all" && trim(c.section) !== side) return false;
        if (!q) return true;
        return (c.name || "").toLowerCase().indexOf(q) !== -1
            || teachersOf(c).join(" ").toLowerCase().indexOf(q) !== -1;
      });
    }

    function cardHtml(c) {
      var n = c.pupils || 0;
      var main = trim(c.main_teacher);
      return '<button type="button" class="cl-card' +
               (c.is_active === false ? " off" : "") + '" data-id="' + esc(c.id) + '">' +
        '<span class="cl-top">' +
          '<span class="cl-nm">' + esc(c.name) + "</span>" +
          /*  ONE NAME. The card printed every member of staff assigned to the
              class, which on Girls OOLA is six Apas — and the masjid was right
              that it is wrong: a card answers "whose class is this", and six
              names answer nothing. Everybody who teaches it is still on the
              class's own page. See migration 060. */
          (main
            ? '<span class="cl-who">' + esc(main) + "</span>"
            : '<span class="cl-who none">Main teacher not chosen</span>') +
        "</span>" +
        '<span class="cl-count' + (n === 0 ? " empty" : "") + '"><b>' + n + "</b> " +
          (n === 1 ? "child" : "children") + "</span>" +
        (c.is_active === false ? '<span class="cl-tag">no longer running</span>' : "") +
      "</button>";
    }

    function drawList() {
      var host = el("cl-sections");
      if (!host) return;

      var shown = visible();
      var html = "";

      /*  GIRLS AND BOYS BESIDE EACH OTHER, mixed spanning underneath.

          Stacked, the boys' classes began below the fold of the girls' and
          half the madrasah was a scroll away from the other half. The two
          sides are peers and the layout should say so — the same arrangement
          the Staff screen uses, for the same reason.

          `span` is set on the group rather than the side, so a fourth kind of
          section — or the "side not recognised" group below — lands full
          width without a second rule. */
      function secHtml(s, mine, span) {
        var kids = mine.reduce(function (a, c) { return a + (c.pupils || 0); }, 0);
        return '<section class="cl-sec ' + s.k + (span ? " cl-span" : "") + '">' +
          '<h3 class="cl-sec-h">' + esc(s.name) +
            ' <span class="cl-sec-n">' + mine.length +
            (mine.length === 1 ? " class" : " classes") + "</span>" +
            ' <span class="cl-sec-n">' + kids + " children</span></h3>" +
          '<div class="cl-grid">' + mine.map(cardHtml).join("") + "</div>" +
        "</section>";
      }

      var sides = "";
      SIDES.forEach(function (s) {
        var mine = shown.filter(function (c) { return trim(c.section) === s.k; });
        if (!mine.length) return;
        sides += secHtml(s, mine, s.k === "mixed");
      });
      if (sides) html += '<div class="cl-sides">' + sides + "</div>";

      /*  ANYTHING WITH A SIDE THIS SCREEN DOES NOT KNOW ABOUT STILL APPEARS.
          The database allows girls, boys and mixed today; if a fourth is ever
          added, those classes must not silently vanish from a list that
          otherwise looks complete. This is the same failure the Staff screen's
          "side not set" group exists to prevent. */
      var known = SIDES.map(function (s) { return s.k; });
      var odd = shown.filter(function (c) { return known.indexOf(trim(c.section)) === -1; });
      if (odd.length) {
        html += '<div class="cl-sides"><section class="cl-sec mixed cl-span">' +
          '<h3 class="cl-sec-h">Side not recognised ' +
          '<span class="cl-sec-n">' + odd.length + "</span></h3>" +
          '<div class="cl-grid">' + odd.map(cardHtml).join("") + "</div></section></div>";
      }

      if (!html) {
        html = '<div class="cl-empty">' +
          (ROWS.length
            ? "No class matches what you have typed."
            : "There are no classes to show. If you are signed in as a teacher, this " +
              "list holds only the classes you are assigned to.") + "</div>";
      }
      host.innerHTML = html;

      var kids = ROWS.reduce(function (a, c) { return a + (c.pupils || 0); }, 0);
      var running = ROWS.filter(function (c) { return c.is_active !== false; }).length;
      var empty = ROWS.filter(function (c) {
        return c.is_active !== false && (c.pupils || 0) === 0;
      }).length;
      el("cl-sum").innerHTML =
        '<div class="cl-fig"><span class="n">' + running + '</span>' +
          '<span class="k">Classes running</span></div>' +
        '<div class="cl-fig"><span class="n">' + kids + '</span>' +
          '<span class="k">Children</span></div>' +
        '<div class="cl-fig"><span class="n">' + empty + '</span>' +
          '<span class="k">With nobody in them</span></div>';
    }

    // ---- one class ----------------------------------------------------------
    function byId(id) {
      for (var i = 0; i < ROWS.length; i++) {
        if (String(ROWS[i].id) === String(id)) return ROWS[i];
      }
      return null;
    }

    function show(which) {
      el("cl-list-view").hidden = which !== "list";
      el("cl-detail").hidden    = which !== "one";
    }

    function openClass(c) {
      open = c;
      roll = null;
      shutEditor();
      note("cl-error", ""); note("cl-ok", "");
      refreshFacts();
      el("cl-d-acts").hidden = !mayAmend;
      el("cl-d-acts-read").hidden = mayAmend;
      el("cl-roll").hidden = true;
      show("one");
      window.scrollTo({ top: 0 });
    }

    /*  The headline facts, on their own, so that adding or removing a child
        can put the new count on screen without closing and reopening the
        class — which would shut the editor they are standing in. */
    function refreshFacts() {
      var c = open;
      if (!c) return;
      el("cl-d-name").textContent = c.name;

      var t = teachersOf(c);
      var n = c.pupils || 0;
      var main = trim(c.main_teacher);

      /*  THIS LINE PRINTED ITS OWN MARKUP AT THE MASJID.

          It was esc(t.join("</b>, <b>")) — the tags were inside the string
          being escaped, so the page showed

              Taught by Apa Somayya I Omarji</b>, <b>Apa Aqsa Patel

          Escaping is not a step you do to a finished string; it is what you do
          to each VALUE as it goes in. Every name is escaped on its own here
          and the markup is added afterwards, which is the only ordering that
          is ever right.                                                      */
      var others = t.filter(function (x) { return x !== main; });
      el("cl-d-facts").innerHTML =
        '<span class="cl-fact"><b>' + n + "</b> " + (n === 1 ? "child" : "children") + "</span>" +
        '<span class="cl-fact">' +
          (main ? "Taught by <b>" + esc(main) + "</b>"
                : "<b>Main teacher not chosen</b>") + "</span>" +
        (others.length
          ? '<span class="cl-fact">Also teaching: ' +
            others.map(function (x) { return "<b>" + esc(x) + "</b>"; }).join(", ") + "</span>"
          : "") +
        '<span class="cl-fact">' + esc(sideName(c.section)) + " side</span>" +
        (trim(c.year_label) ? '<span class="cl-fact">' + esc(c.year_label) + "</span>" : "") +
        (c.is_active === false ? '<span class="cl-fact"><b>No longer running</b></span>' : "");
    }

    function sideName(s) {
      for (var i = 0; i < SIDES.length; i++) {
        if (SIDES[i].k === trim(s)) return SIDES[i].name;
      }
      return trim(s) || "Unrecorded";
    }

    /*  THE ROLL IS FETCHED ONLY WHEN SOMEBODY ASKS FOR IT.

        Every class carries its headcount already, so the list and this page
        are useful without ever reading a child's name. Pressing "Who is in it"
        is a deliberate act, and it is the only thing on this screen that
        causes named children to leave the database. That is worth keeping as
        a decision somebody takes rather than a side effect of opening a page.  */
    function showRoll() {
      if (!open) return;
      var box = el("cl-roll");
      box.hidden = false;
      el("cl-roll-list").innerHTML = "";
      el("cl-roll-why").textContent = "Reading the register…";
      box.scrollIntoView({ block: "nearest" });

      sb.rpc("madrasah_pupils_in_class", { p_class: open.id }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        roll = list(res.data);
        el("cl-roll-h").textContent = "Who is in it";
        el("cl-roll-why").textContent = roll.length
          ? roll.length + (roll.length === 1 ? " child" : " children") +
            ", by surname. This is the register the madrasah holds."
          : "Nobody is recorded in this class yet.";
        el("cl-roll-list").innerHTML = roll.map(function (p) {
          return '<div class="cl-pupil"><span>' + esc(p.name) + "</span></div>";
        }).join("");
      }).catch(function (e) {
        var msg = (e && e.message) || String(e);
        el("cl-roll-why").textContent = "The register could not be read — " + msg;
      });
    }

    /*  PRINTING IS THE BROWSER'S OWN "Save as PDF", and that is a decision.

        A PDF library off a CDN would be a new external dependency on a site
        that self-hosts its fonts and inlines its scripts on purpose, bought to
        reproduce a document every browser already makes. The stylesheet has a
        @media print block that strips the rail, the buttons and the filters
        and leaves the masjid's mark, the class, the teacher and a numbered
        roll - which is the document the madrasah already hands out.

        The register is fetched first, because printing a page whose roll has
        not been opened would hand somebody a class list with no class list on
        it and nothing saying why. */
    function printClass() {
      if (!open) return;
      if (roll === null) {
        showRoll();
        window.setTimeout(function () {
          if (roll !== null) window.print();
          else note("cl-error", "The register has not loaded yet, so there is nothing " +
                                "to print. Try again in a moment.");
        }, 900);
        return;
      }
      el("cl-roll").hidden = false;
      window.print();
    }

    // ---- amending -----------------------------------------------------------
    function hideConfirm() {
      var b = el("cl-confirm");
      if (b) { b.hidden = true; b.classList.remove("is-danger"); }
      want = null;
    }

    function fillTeacherPicker(chosen) {
      var sel = el("cl-main");
      if (!sel) return;
      sel.innerHTML = '<option value="">Not chosen</option>' +
        STAFF.map(function (p) {
          return '<option value="' + esc(p.id) + '"' +
                 (String(p.id) === String(chosen) ? " selected" : "") + ">" +
                 esc(p.name) + "</option>";
        }).join("");
      //  A main teacher who has since left the staff list would otherwise
      //  vanish from the picker and silently clear itself on the next save.
      if (chosen && !STAFF.some(function (p) { return String(p.id) === String(chosen); })) {
        sel.insertAdjacentHTML("beforeend",
          '<option value="' + esc(chosen) + '" selected>' +
          esc(trim(open && open.main_teacher) || "Somebody no longer on the staff list") +
          "</option>");
      }
    }

    function openEditor() {
      if (!open || !mayAmend) return;
      el("cl-name").value    = open.name || "";
      el("cl-section").value = trim(open.section) || "girls";
      el("cl-year").value    = open.year_label || "";
      el("cl-active").checked = open.is_active !== false;
      fillTeacherPicker(open.main_teacher_id);

      el("cl-add-find").value = "";
      el("cl-add-hits").innerHTML = "";
      drawEditRoll();

      note("cl-complaints", "");
      hideConfirm();
      el("cl-editor").hidden = false;
      el("cl-name").focus();
      el("cl-editor").scrollIntoView({ block: "nearest" });
    }

    // ---- who is in the class, while the editor is open ----------------------
    function drawEditRoll() {
      var host = el("cl-roster-list");
      if (!host || !open) return;
      host.textContent = "Reading the register\u2026";
      sb.rpc("madrasah_pupils_in_class", { p_class: open.id }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        EDIT_ROLL = list(res.data);
        host.innerHTML = EDIT_ROLL.length
          ? EDIT_ROLL.map(function (p) {
              return '<span class="cl-chip"><span>' + esc(p.name) + "</span>" +
                '<button type="button" class="cl-x" data-off="' + esc(p.id) +
                '" title="Take ' + esc(p.name) + ' out of this class"' +
                ' aria-label="Take ' + esc(p.name) + ' out of this class">\u00d7</button></span>';
            }).join("")
          : '<span class="cl-hit-none">Nobody is in this class yet.</span>';
      }).catch(function (e) {
        host.textContent = "The register could not be read \u2014 " +
                           ((e && e.message) || String(e));
      });
    }

    /*  THE SEARCH WAITS FOR THE TYPING TO STOP.

        Not for the network's sake — this is a masjid office and the table has
        543 rows. It is so that a half-typed name is not sent, matched loosely
        and shown as a list of other people's children while somebody is still
        reaching for the next letter. Two characters is the floor and the
        database enforces it as well; an empty search returns nothing rather
        than everybody. */
    function findPupils() {
      var q = trim(el("cl-add-find").value);
      var host = el("cl-add-hits");
      if (findTimer) window.clearTimeout(findTimer);
      if (q.length < 2) { host.innerHTML = ""; return; }
      findTimer = window.setTimeout(function () {
        sb.rpc("madrasah_pupil_search", { p_q: q, p_not_in_class: open.id })
          .then(function (res) {
            if (res.error) throw new Error(res.error.message);
            var hits = list(res.data);
            host.innerHTML = hits.length
              ? hits.map(function (p) {
                  return '<div class="cl-hit"><span><b>' + esc(p.name) + "</b><br>" +
                    "<i>" + esc(p.classes || "no class") + "</i></span>" +
                    '<button type="button" class="btn btn-ghost" data-on="' + esc(p.id) +
                    '">Add to this class</button></div>';
                }).join("")
              : '<div class="cl-hit-none">Nobody matching that name who is not ' +
                "already in this class.</div>";
          }).catch(function (e) {
            host.innerHTML = '<div class="cl-hit-none">' +
              esc("The search failed \u2014 " + ((e && e.message) || String(e))) + "</div>";
          });
      }, 260);
    }

    function movePupil(fn, pupil, after) {
      note("cl-error", ""); note("cl-ok", "");
      sb.rpc(fn, { p_pupil: pupil, p_class: open.id }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        after(res.data || {});
        return load();
      }).then(function () {
        var again = byId(open.id);
        if (again) { open = again; refreshFacts(); }
        drawEditRoll();
        if (roll !== null) showRoll();
      }).catch(function (e) {
        note("cl-error", ((e && e.message) || String(e)));
      });
    }

    function shutEditor() {
      hideConfirm();
      note("cl-complaints", "");
      var b = el("cl-editor");
      if (b) b.hidden = true;
    }

    function readForm() {
      return {
        id: open ? open.id : "",
        name: trim(el("cl-name").value),
        section: el("cl-section").value,
        year_label: trim(el("cl-year").value),
        is_active: el("cl-active").checked,
        //  Always sent, including as "" for Not chosen. save_madrasah_class()
        //  treats an ABSENT key as "leave it alone" and a present one as an
        //  instruction, so omitting it would make clearing a main teacher
        //  impossible from this screen.
        main_teacher_id: el("cl-main") ? el("cl-main").value : ""
      };
    }

    function askSave() {
      var f = readForm();
      if (!f.name) {
        note("cl-complaints", "Not saved — a class needs a name.");
        return;
      }
      note("cl-complaints", "");
      want = { what: "save", f: f };
      el("cl-confirm-q").textContent =
        "Save these changes to “" + f.name + "”?";
      el("cl-confirm").hidden = false;
      el("cl-confirm-yes").focus();
    }

    function save(f) {
      var btn = el("cl-save");
      busy(btn, true, "Save");
      note("cl-error", ""); note("cl-ok", "");
      hideConfirm();
      sb.rpc("save_madrasah_class", { p: f }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        return load();
      }).then(function () {
        shutEditor();
        var again = byId(f.id);
        if (again) openClass(again); else show("list");
        note("cl-ok", "“" + f.name + "” is saved.");
      }).catch(function (e) {
        note("cl-error", "Nothing was saved — " + ((e && e.message) || String(e)));
      }).finally(function () { busy(btn, false, "Save"); });
    }

    function askRemove() {
      if (!open) return;
      var n = open.pupils || 0;
      want = { what: "remove", c: open };
      var b = el("cl-confirm");
      /*  THE QUESTION NAMES THE CHILDREN. Removing a class that has thirty
          children in it is not the same act as removing an empty one, and a
          confirm that says the same thing either way is a confirm that teaches
          people to press Yes. */
      /*  AND IT NO LONGER SAYS "THIS CANNOT BE UNDONE", BECAUSE IT CAN.
          Removing a class archives it — the class, its register and the staff
          who took it go into madrasah_archive and can be put back from
          Administration → Archive for three years. Leaving the old wording in
          place would have been the worse of the two mistakes a confirm can
          make: it frightens somebody out of an action that is in fact
          reversible, and it teaches them that the warnings on this system
          overstate things. */
      el("cl-confirm-q").textContent = n
        ? "Remove “" + open.name + "”? " + n + " " +
          (n === 1 ? "child is" : "children are") + " in it, and they will be left " +
          "in no class at all — the children themselves are not removed. If the " +
          "class has simply finished for the year, cancel and untick “still " +
          "running” instead, which keeps everybody where they are. Nothing is " +
          "deleted: the class goes to the archive and can be put back."
        : "Remove “" + open.name + "”? Nobody is in it. Nothing is deleted — the " +
          "class goes to the archive and can be put back.";
      b.classList.add("is-danger");
      b.hidden = false;
      el("cl-editor").hidden = false;
      b.scrollIntoView({ block: "nearest" });
      el("cl-confirm-yes").focus();
    }

    /*  ARCHIVE, NOT DELETE.

        This used to call delete_madrasah_class(), which did what its name
        says. The masjid asked that "any record removed from the madrasah
        database should get archived, where someone is able to go into the
        archive and restore if needed" — and a class is the one of the three
        kinds where a mistake is least visible afterwards. A teacher removed in
        error is noticed by the teacher. A class removed in error leaves thirty
        children in no class at all, and the register that said which thirty is
        gone with it.

        archive_madrasah_class() in db/063 copies the class row, the list of
        children who were in it and the staff who took it into
        madrasah_archive, then removes it. THE CHILDREN THEMSELVES ARE NOT
        TOUCHED — only their link to this class — which is why the question
        above now says so. */
    function remove(c) {
      note("cl-error", ""); note("cl-ok", "");
      hideConfirm();
      sb.rpc("archive_madrasah_class", { p_id: c.id, p_reason: null }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        return load();
      }).then(function () {
        shutEditor();
        show("list");
        note("cl-ok", "“" + c.name + "” is in the archive. Nothing has been " +
                      "deleted — Administration → Archive can put it back.");
      }).catch(function (e) {
        note("cl-error", "Nothing was removed — " + ((e && e.message) || String(e)));
      });
    }

    // ---- wiring -------------------------------------------------------------
    function wire() {
      if (wired) return;
      wired = true;

      var host = el("cl-sections");
      if (host) host.addEventListener("click", function (ev) {
        var b = ev.target.closest && ev.target.closest("button.cl-card");
        if (!b) return;
        var c = byId(b.getAttribute("data-id"));
        if (c) openClass(c);
      });

      var find = el("cl-find");
      if (find) find.addEventListener("input", function () {
        query = trim(this.value); drawList();
      });
      var pick = el("cl-side");
      if (pick) pick.addEventListener("change", function () {
        side = this.value; drawList();
      });
      var off = el("cl-show-off");
      if (off) off.addEventListener("change", function () {
        showOff = this.checked; drawList();
      });

      var back = el("cl-back");
      if (back) back.addEventListener("click", function () {
        open = null; roll = null; shutEditor(); show("list");
        window.scrollTo({ top: 0 });
      });

      ["cl-roll-btn", "cl-roll-btn-read"].forEach(function (id) {
        var b = el(id);
        if (b) b.addEventListener("click", showRoll);
      });
      ["cl-print", "cl-print-read"].forEach(function (id) {
        var b = el(id);
        if (b) b.addEventListener("click", printClass);
      });

      var edit = el("cl-edit");
      if (edit) edit.addEventListener("click", openEditor);
      var rm = el("cl-remove");
      if (rm) rm.addEventListener("click", askRemove);
      var sv = el("cl-save");
      if (sv) sv.addEventListener("click", askSave);
      var cancel = el("cl-cancel");
      if (cancel) cancel.addEventListener("click", shutEditor);

      var yes = el("cl-confirm-yes");
      if (yes) yes.addEventListener("click", function () {
        var w = want;
        if (!w) return;
        if (w.what === "save") save(w.f); else remove(w.c);
      });
      var no = el("cl-confirm-no");
      if (no) no.addEventListener("click", hideConfirm);

      var find = el("cl-add-find");
      if (find) find.addEventListener("input", findPupils);

      //  One listener over the whole roster block: both the chips and the
      //  search results are redrawn after every change, so per-button
      //  listeners would not survive the first one.
      var roster = el("cl-roster");
      if (roster) roster.addEventListener("click", function (ev) {
        var b = ev.target.closest && ev.target.closest("button[data-off], button[data-on]");
        if (!b) return;
        if (b.hasAttribute("data-on")) {
          movePupil("add_pupil_to_class", b.getAttribute("data-on"), function (d) {
            el("cl-add-find").value = "";
            el("cl-add-hits").innerHTML = "";
            note("cl-ok", (d.added || "That child") + " is now in this class.");
          });
          return;
        }
        movePupil("remove_pupil_from_class", b.getAttribute("data-off"), function (d) {
          /*  SAY WHICH OF THE TWO THINGS JUST HAPPENED, EVERY TIME.
              Taking a child out of a class and deleting a child are one press
              apart in somebody's mind and unrecoverably different in the
              database. And when it was their LAST class, say that too: a
              record in no class is reachable from no register, which is how a
              child goes quietly missing. */
          note("cl-ok", (d.removed || "That child") + " is out of this class. " +
            (Number(d.classes_left) === 0
              ? "That was their only class, so they are now in none at all — their " +
                "record is still here, but no register will show them."
              : "Their record and their other classes are untouched."));
        });
      });

      var ed = el("cl-editor");
      if (ed) {
        ed.addEventListener("input", hideConfirm);
        ed.addEventListener("change", hideConfirm);
      }
    }

    function mount(identity) {
      var panel = el("cl-panel");
      var noaccess = el("app-noaccess");
      if (!panel) return;

      /*  Anybody in the madrasah portal may open this. What they GET differs:
          madrasah_class_list() returns every class to an administrator and only
          the caller's own classes to a teacher, and madrasah_pupils_in_class()
          refuses a class that is not theirs. Both are decided in Postgres. */
      var roles = identity.roles || [];
      if (roles.indexOf("admin") === -1 && roles.indexOf("madrasah") === -1) {
        panel.hidden = true;
        if (noaccess) noaccess.hidden = false;
        return;
      }
      if (noaccess) noaccess.hidden = true;
      panel.hidden = false;
      show("list");
      wire();
      load().catch(function (e) {
        note("cl-error", "The classes could not be read — " + ((e && e.message) || String(e)));
        var host = el("cl-sections");
        if (host) host.textContent = "";
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
        current:  'md-classes',
        title:    'Classes',
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
    try { classes.mount(identity); } catch (e) {
      if (window.console) console.warn("classes panel unavailable:", e);
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
