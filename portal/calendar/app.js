/* ===========================================================================
   THE MADRASAH CALENDAR — twelve months on one page.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   18 September 2026

   WHAT THIS SCREEN IS FOR, AND WHY IT IS A YEAR RATHER THAN A MONTH.

   The question it answers is "when is the madrasah shut". That question is
   asked by a parent booking flights in March for August, and by a teacher
   working out which Saturdays are teaching Saturdays. Both need the shape of
   the whole year at once, which is why every calendar control's instinct —
   show one month, make them click for the rest — is wrong here.

   THE DATES USED TO LIVE IN THE WEBSITE'S SOURCE CODE.

   The public Holiday Planner read a JavaScript array typed into
   index_template.html, under a comment saying the list is "edited here, once
   a year". Edited by a developer, opening a 6,600-line file, rebuilding and
   pushing. Migrations 056 and 057 moved those dates into the database exactly
   as they stood; this screen is how the madrasah amends them, and the public
   page reads the same function. One list, changed by the people whose dates
   they are.

   TWO KINDS OF DATE AND THEY ARE NOT EQUALLY CERTAIN. A closure is the
   madrasah's own decision and is a fact. An Islamic date is calculated and
   settled by moon sighting, so it can land a day either side — and every one
   of them stays marked "estimated" until somebody at the masjid says
   otherwise. A calculated Eid presented as settled is how a family turns up
   on the wrong morning.

   WHO MAY DO WHAT. Anybody who can open the portal may READ this, because the
   public website shows the same dates to anybody at all. Only an
   administrator may amend, and that is enforced by Postgres — every writer in
   057 asks verified_admin(). The controls here are drawn or not drawn to
   match, which is a courtesy and not the boundary.
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
     THE YEAR

     One read (madrasah_calendar) fills the whole screen. It is the same
     function the public Holiday Planner calls, which is the point: there is
     one list of holidays, not one here and one typed into the website.
     ======================================================================= */
  var calendar = (function () {

    var MON = ["January","February","March","April","May","June",
               "July","August","September","October","November","December"];
    var DOW = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"];
    var LONG_DOW = ["Monday","Tuesday","Wednesday","Thursday","Friday",
                    "Saturday","Sunday"];

    var YEAR = null;          // { label, starts_on, ends_on }
    var CLOSURES = [];
    var EVENTS = [];
    var SHUT = {};            // iso -> [closure, ...]
    var ONDAY = {};           // iso -> [event, ...]
    var picked = null;        // the iso day whose card is open
    var editing = null;       // { kind:'closure'|'event', row:{} | null }
    var mayAmend = false;
    var wired = false;
    var saveWanted = null;    // what the confirm strip is asking about

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function trim(v) { return String(v == null ? "" : v).trim(); }

    /*  DATES ARE HANDLED AS PLAIN STRINGS AND LOCAL Date OBJECTS, NEVER UTC.

        new Date("2027-03-09") is parsed as MIDNIGHT UTC, and in Bolton between
        late March and late October that is the previous day at 23:00 or 01:00
        local. Build a calendar that way and every date in British Summer Time
        lands in the wrong cell — Eid al-Fitr would appear on the 8th. So iso
        strings are split by hand and fed to the three-argument Date, which is
        local, and turned back by hand rather than through toISOString().      */
    function parse(iso) {
      var p = String(iso).split("-");
      return new Date(+p[0], +p[1] - 1, +p[2]);
    }
    function iso(d) {
      return d.getFullYear() + "-" +
             String(d.getMonth() + 1).padStart(2, "0") + "-" +
             String(d.getDate()).padStart(2, "0");
    }
    function pretty(isoStr) {
      var d = parse(isoStr);
      return d.getDate() + " " + MON[d.getMonth()] + " " + d.getFullYear();
    }
    //  Monday-first. A madrasah week is not a Sunday-first week and the public
    //  planner already runs Monday to Sunday; two calendars of the same year
    //  with the columns shifted is worse than either on its own.
    function dowIndex(d) { return (d.getDay() + 6) % 7; }

    function note(id, msg) {
      var box = el(id);
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    // ---- reading ------------------------------------------------------------
    function load() {
      return sb.rpc("madrasah_calendar").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        var d = res.data || {};
        YEAR     = d.year || null;
        CLOSURES = d.closures || [];
        EVENTS   = d.events || [];
        index();
        drawYear();
        if (picked) drawDay(picked);
      });
    }

    /*  ONE LOOKUP PER DAY, BUILT ONCE.

        The alternative is asking "is this day inside any closure" for each of
        365 cells against every closure, which is 365 x n comparisons every
        time anything is redrawn. Walking each closure once and writing its
        days into a map is the same answer for a fraction of the work, and it
        is what the public planner already does. */
    function index() {
      SHUT = {}; ONDAY = {};
      CLOSURES.forEach(function (c) {
        var d = parse(c.starts_on), end = parse(c.ends_on);
        //  A guard, not decoration. The database refuses a closure longer than
        //  366 days, but a loop that trusts its input is one bad row away from
        //  hanging the browser with nothing on screen to say why.
        var guard = 0;
        while (d <= end && guard++ < 400) {
          var k = iso(d);
          (SHUT[k] = SHUT[k] || []).push(c);
          d.setDate(d.getDate() + 1);
        }
      });
      EVENTS.forEach(function (e) {
        (ONDAY[e.on_date] = ONDAY[e.on_date] || []).push(e);
      });
    }

    // ---- the twelve months --------------------------------------------------
    function months() {
      //  The academic year, not the calendar year. September to August is how
      //  a madrasah thinks and how the closures are written; starting at
      //  January would split the summer holiday across two ends of the page.
      var out = [];
      if (!YEAR) return out;
      var d = parse(YEAR.starts_on);
      var last = parse(YEAR.ends_on);
      d = new Date(d.getFullYear(), d.getMonth(), 1);
      var guard = 0;
      while ((d.getFullYear() < last.getFullYear() ||
             (d.getFullYear() === last.getFullYear() && d.getMonth() <= last.getMonth()))
             && guard++ < 36) {
        out.push(new Date(d.getFullYear(), d.getMonth(), 1));
        d.setMonth(d.getMonth() + 1);
      }
      return out;
    }

    function dayTitle(k) {
      var bits = [];
      (SHUT[k] || []).forEach(function (c) { bits.push("Shut — " + c.name); });
      (ONDAY[k] || []).forEach(function (e) {
        bits.push(e.name + (e.is_estimated ? " (estimated)" : ""));
      });
      return bits.join(" · ");
    }

    function monthHtml(first) {
      var y = first.getFullYear(), m = first.getMonth();
      var days = new Date(y, m + 1, 0).getDate();
      var pad = dowIndex(new Date(y, m, 1));
      var today = iso(new Date());

      var cells = DOW.map(function (n) {
        return '<div class="cal-dow" aria-hidden="true">' + n.charAt(0) + "</div>";
      }).join("");

      var i;
      for (i = 0; i < pad; i++) {
        cells += '<button type="button" class="cal-d pad" tabindex="-1" aria-hidden="true"></button>';
      }
      for (i = 1; i <= days; i++) {
        var d = new Date(y, m, i);
        var k = iso(d);
        var cls = ["cal-d"];
        if (SHUT[k]) cls.push("shut");
        if (ONDAY[k]) cls.push("evt");
        if (k === today) cls.push("today");
        if (k === picked) cls.push("sel");
        if (dowIndex(d) >= 5) cls.push("wknd");
        var what = dayTitle(k);
        /*  THE ACCESSIBLE NAME CARRIES THE WHOLE ANSWER, not just the number.
            A screen reader in a grid of 365 buttons reading "1, 2, 3" tells
            somebody nothing; "9 March 2027, Eid al-Fitr, estimated" is the
            calendar. The colour is the shortcut for people who can see it. */
        cells += '<button type="button" class="' + cls.join(" ") + '" data-d="' + k + '"' +
                 (what ? ' title="' + esc(what) + '"' : "") +
                 ' aria-label="' + esc(pretty(k) + (what ? ". " + what : "")) + '">' +
                 i + "</button>";
      }

      return '<section class="cal-mon"><h3>' + MON[m] +
             " <span>" + y + "</span></h3>" +
             '<div class="cal-grid" role="grid" aria-label="' + esc(MON[m] + " " + y) + '">' +
             cells + "</div></section>";
    }

    function drawYear() {
      var host = el("cal-year");
      if (!host) return;
      var list = months();
      if (!YEAR || !list.length) {
        host.innerHTML = '<p class="cal-none">No academic year has been set, so there ' +
          'is nothing to draw. Set one under Administration → Academic year and the ' +
          'calendar follows it.</p>';
        return;
      }
      host.innerHTML = list.map(monthHtml).join("");

      var lab = el("cal-year-label");
      if (lab) {
        lab.innerHTML = esc(YEAR.label) + '<small>' +
          esc(pretty(YEAR.starts_on) + " to " + pretty(YEAR.ends_on)) + " · " +
          CLOSURES.length + (CLOSURES.length === 1 ? " closure" : " closures") + " · " +
          EVENTS.length + (EVENTS.length === 1 ? " Islamic date" : " Islamic dates") +
          "</small>";
      }
    }

    // ---- one day ------------------------------------------------------------
    function itemHtml(kind, row) {
      var isShut = kind === "closure";
      var when = isShut
        ? (row.starts_on === row.ends_on
             ? pretty(row.starts_on)
             : pretty(row.starts_on) + " to " + pretty(row.ends_on))
        : pretty(row.on_date);
      var extra = isShut ? trim(row.note) : trim(row.hijri_label);
      return '<div class="cal-item ' + (isShut ? "is-shut" : "is-evt") + '">' +
        '<span class="cal-item-b">' +
          '<span class="cal-item-n">' + esc(row.name) +
            (!isShut && row.is_estimated ? '<span class="cal-est">estimated</span>' : "") +
          "</span>" +
          '<span class="cal-item-w">' + esc(when) +
            (extra ? " · " + esc(extra) : "") + "</span>" +
        "</span>" +
        (mayAmend
          ? '<span class="cal-item-acts">' +
              '<button type="button" class="btn btn-ghost" data-edit="' + kind +
                '" data-id="' + esc(row.id) + '">Change</button>' +
              '<button type="button" class="btn btn-ghost" data-del="' + kind +
                '" data-id="' + esc(row.id) + '">Remove</button>' +
            "</span>"
          : "") +
      "</div>";
    }

    function drawDay(k) {
      picked = k;
      var box = el("cal-day");
      if (!box) return;
      box.hidden = false;

      var d = parse(k);
      el("cal-day-h").textContent = LONG_DOW[dowIndex(d)] + " " + pretty(k);

      var shut = SHUT[k] || [], evts = ONDAY[k] || [];
      el("cal-day-sub").textContent = shut.length
        ? "The madrasah is shut."
        : "The madrasah is open.";

      var items = el("cal-day-items");
      items.innerHTML = shut.map(function (c) { return itemHtml("closure", c); })
              .concat(evts.map(function (e) { return itemHtml("event", e); })).join("");

      var none = el("cal-day-none");
      if (!shut.length && !evts.length) {
        none.hidden = false;
        none.textContent = mayAmend
          ? "Nothing is recorded on this day."
          : "Nothing is recorded on this day. Only an administrator can add one.";
      } else { none.hidden = true; }

      var acts = el("cal-day-acts");
      if (acts) acts.hidden = !mayAmend;

      //  Re-drawn tiles mean the selected day has moved, so the year is redrawn
      //  to move the ring with it. Cheap: 365 buttons is nothing to innerHTML.
      drawYear();
      box.scrollIntoView({ block: "nearest" });
    }

    // ---- the editor ---------------------------------------------------------
    function hideConfirm() {
      var b = el("cal-confirm");
      if (b) { b.hidden = true; b.classList.remove("is-danger"); }
      saveWanted = null;
    }

    function openEditor(kind, row) {
      editing = { kind: kind, row: row || null };
      var isShut = kind === "closure";

      el("cal-form-head").textContent = row
        ? "Change " + row.name
        : (isShut ? "Close the madrasah" : "Add an Islamic date");

      el("cal-form-lede").textContent = isShut
        ? "Every day from the first to the last counts as shut, and all of them show on the website."
        : "A date the madrasah marks. It shows on the website with the Islamic day beside it.";

      el("cal-from-label").textContent = isShut ? "First day" : "The day";
      el("cal-to-wrap").hidden    = !isShut;
      el("cal-to-hint").hidden    = !isShut;
      el("cal-note-wrap").hidden  = !isShut;
      el("cal-hijri-wrap").hidden = isShut;
      el("cal-est-wrap").hidden   = isShut;

      el("cal-name").value  = row ? row.name : "";
      el("cal-from").value  = row ? (isShut ? row.starts_on : row.on_date) : (picked || "");
      el("cal-to").value    = row && isShut ? row.ends_on : "";
      el("cal-note").value  = row && isShut ? (row.note || "") : "";
      el("cal-hijri").value = row && !isShut ? (row.hijri_label || "") : "";
      el("cal-est").checked = row && !isShut ? !!row.is_estimated : true;

      el("cal-name").placeholder = isShut ? "Half Term Break" : "Eid al-Fitr";

      note("cal-complaints", "");
      hideConfirm();
      el("cal-editor").hidden = false;
      el("cal-name").focus();
    }

    function shutEditor() {
      editing = null;
      hideConfirm();
      note("cal-complaints", "");
      var b = el("cal-editor");
      if (b) b.hidden = true;
    }

    function readForm() {
      var isShut = editing && editing.kind === "closure";
      return {
        id:        editing && editing.row ? editing.row.id : "",
        name:      trim(el("cal-name").value),
        from:      el("cal-from").value,
        to:        isShut ? el("cal-to").value : "",
        note:      isShut ? trim(el("cal-note").value) : "",
        hijri:     isShut ? "" : trim(el("cal-hijri").value),
        estimated: !isShut && el("cal-est").checked
      };
    }

    /*  WHAT IS WRONG WITH IT, IN WORDS, BEFORE ANYTHING IS SENT.

        The database refuses all of these too and that is the real guard. This
        is here so that somebody gets "a closure needs a name" while looking at
        the empty box, rather than a round trip and a red bar at the top of the
        page after they have stopped looking at it. */
    function complaints(f) {
      var out = [];
      if (!f.name) out.push("it needs a name");
      if (!f.from) out.push("it needs a day");
      if (f.to && f.from && f.to < f.from) out.push("the last day is before the first");
      return out;
    }

    function askToSave() {
      var f = readForm();
      var bad = complaints(f);
      if (bad.length) {
        note("cal-complaints", "Not saved yet — " + bad.join(", ") + ".");
        return;
      }
      note("cal-complaints", "");

      //  A NEW ENTRY DOES NOT ASK; CHANGING ONE DOES. Adding a closure
      //  overwrites nothing and is visible on the calendar the moment it
      //  lands. Amending one replaces a date families may already have
      //  planned around, which is worth a question. Same rule as the staff
      //  screen, so the portal behaves one way throughout.
      if (!f.id) { save(f); return; }
      saveWanted = { what: "save", f: f };
      el("cal-confirm-q").textContent =
        "Change “" + f.name + "”? The website shows these dates to parents, so it " +
        "changes there too.";
      el("cal-confirm").hidden = false;
      el("cal-confirm-yes").focus();
    }

    function askToDelete(kind, row) {
      saveWanted = { what: "delete", kind: kind, row: row };
      var b = el("cal-confirm");
      el("cal-confirm-q").textContent =
        "Remove “" + row.name + "” altogether? It disappears from the website as " +
        "well, and this cannot be undone.";
      b.classList.add("is-danger");
      b.hidden = false;
      el("cal-editor").hidden = false;
      b.scrollIntoView({ block: "nearest" });
      el("cal-confirm-yes").focus();
    }

    function save(f) {
      var isShut = editing.kind === "closure";
      var p = isShut
        ? { id: f.id, name: f.name, note: f.note, starts_on: f.from, ends_on: f.to }
        : { id: f.id, name: f.name, hijri_label: f.hijri, on_date: f.from,
            is_estimated: f.estimated };

      var btn = el("cal-save");
      busy(btn, true, "Save");
      note("cal-error", ""); note("cal-ok", "");
      hideConfirm();

      sb.rpc(isShut ? "save_madrasah_closure" : "save_madrasah_event", { p: p })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          shutEditor();
          return load();
        })
        .then(function () {
          note("cal-ok", "“" + f.name + "” is saved. The website shows it now.");
        })
        .catch(function (e) {
          note("cal-error", "Nothing was saved — " + ((e && e.message) || String(e)));
        })
        .finally(function () { busy(btn, false, "Save"); });
    }

    function remove(kind, row) {
      note("cal-error", ""); note("cal-ok", "");
      hideConfirm();
      sb.rpc(kind === "closure" ? "delete_madrasah_closure" : "delete_madrasah_event",
             { p_id: row.id })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          shutEditor();
          return load();
        })
        .then(function () { note("cal-ok", "“" + row.name + "” has been removed."); })
        .catch(function (e) {
          note("cal-error", "Nothing was removed — " + ((e && e.message) || String(e)));
        });
    }

    function byId(kind, id) {
      var list = kind === "closure" ? CLOSURES : EVENTS;
      for (var i = 0; i < list.length; i++) {
        if (String(list[i].id) === String(id)) return list[i];
      }
      return null;
    }

    // ---- wiring -------------------------------------------------------------
    function wire() {
      if (wired) return;
      wired = true;

      //  One listener on the year rather than 365. The grid is redrawn
      //  constantly and per-button listeners would not survive it.
      var year = el("cal-year");
      if (year) year.addEventListener("click", function (ev) {
        var b = ev.target.closest && ev.target.closest("button.cal-d");
        if (!b || b.classList.contains("pad")) return;
        shutEditor();
        drawDay(b.getAttribute("data-d"));
      });

      var items = el("cal-day-items");
      if (items) items.addEventListener("click", function (ev) {
        var b = ev.target.closest && ev.target.closest("button[data-edit], button[data-del]");
        if (!b) return;
        var kind = b.getAttribute("data-edit") || b.getAttribute("data-del");
        var row  = byId(kind, b.getAttribute("data-id"));
        if (!row) return;
        note("cal-error", ""); note("cal-ok", "");
        if (b.hasAttribute("data-edit")) { editing = { kind: kind, row: row }; openEditor(kind, row); }
        else { editing = { kind: kind, row: row }; askToDelete(kind, row); }
      });

      var addC = el("cal-add-closure");
      if (addC) addC.addEventListener("click", function () { openEditor("closure", null); openDayIfNone(); });
      var addE = el("cal-add-event");
      if (addE) addE.addEventListener("click", function () { openEditor("event", null); openDayIfNone(); });
      var dayC = el("cal-day-closure");
      if (dayC) dayC.addEventListener("click", function () { openEditor("closure", null); });
      var dayE = el("cal-day-event");
      if (dayE) dayE.addEventListener("click", function () { openEditor("event", null); });

      var pr = el("cal-print");
      if (pr) pr.addEventListener("click", function () { window.print(); });

      var save = el("cal-save");
      if (save) save.addEventListener("click", askToSave);
      var cancel = el("cal-cancel");
      if (cancel) cancel.addEventListener("click", shutEditor);

      var yes = el("cal-confirm-yes");
      if (yes) yes.addEventListener("click", function () {
        var w = saveWanted;
        if (!w) return;
        if (w.what === "save") save2(w.f); else remove(w.kind, w.row);
      });
      var no = el("cal-confirm-no");
      if (no) no.addEventListener("click", function () {
        hideConfirm();
        if (el("cal-save")) el("cal-save").focus();
      });

      //  Editing anything withdraws a question that was asked about the old
      //  values. Same reasoning as the staff screen.
      var ed = el("cal-editor");
      if (ed) {
        ed.addEventListener("input", hideConfirm);
        ed.addEventListener("change", hideConfirm);
      }
    }

    //  `save` is the name of both the button variable and the writer inside
    //  wire(), so the confirm calls through this rather than shadowing it.
    function save2(f) { save(f); }

    /*  The editor lives inside the day card, so adding something from the top
        bar with no day chosen would open a form nobody can see. Opening
        today's card first puts it on screen — and today is a better guess
        than nothing, because most entries are made about the near future. */
    function openDayIfNone() {
      if (!picked) drawDay(iso(new Date()));
      el("cal-editor").hidden = false;
      el("cal-editor").scrollIntoView({ block: "nearest" });
    }

    function mount(identity) {
      var panel = el("cal-panel");
      if (!panel) return;

      /*  ANYBODY IN THE PORTAL MAY READ THIS CALENDAR — the same function
          answers the public website, so there is nothing here to keep back.
          Only an administrator may change it, and the database is what
          enforces that. The controls are drawn or not drawn rather than shown
          and refused, because a button that always fails is a button that
          teaches people the screen is broken. */
      mayAmend = (identity.roles || []).indexOf("admin") !== -1;
      panel.hidden = false;
      var acts = el("cal-acts");
      if (acts) acts.hidden = !mayAmend;
      if (!mayAmend) {
        var scope = el("cal-scope");
        if (scope) {
          scope.innerHTML = "These are the dates the <strong>public Holiday Planner</strong> " +
            "prints. Only a masjid administrator can amend them.";
        }
      }

      wire();
      load().catch(function (e) {
        note("cal-error", "The calendar could not be read — " + ((e && e.message) || String(e)));
        var host = el("cal-year");
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
        current:  'md-calendar',
        title:    'Calendar & holidays',
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
    try { calendar.mount(identity); } catch (e) {
      if (window.console) console.warn("calendar unavailable:", e);
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
