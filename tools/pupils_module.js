  /* =========================================================================
     PUPILS

     THE ROLL IS THE WHOLE MADRASAH. 552 children, 44 classes, 37 teachers,
     330 families. It is the biggest thing in this system and the one a
     teacher opens most, so the list has to stay fast and quiet and the
     record has to hold everything.

     THE SAME SPLIT AS APPLICATIONS, FOR THE SAME REASON. A pupil carries a
     medical note, an allergy, a SEND note. The list shows small marks and no
     detail. The detail arrives only when somebody opens ONE pupil, and
     madrasah_pupil_one() writes down that they did. A list sits open on an
     office screen all morning; opening a record is a deliberate act.

     WHAT IS MISSING IS SHOWN, NOT HIDDEN. Loading a register from a
     spreadsheet leaves gaps: children with no contact details, no class, no
     date of birth. A screen that renders a gap as blank space hides it, and
     the gap that matters is the child nobody can telephone. The figures at
     the top count them and each one filters the list to exactly those
     children, so a gap is a job of work rather than a discovery.
     ======================================================================= */
  var pupils = (function () {

    var ROWS = [];            // the roll, as last loaded
    var OPEN = null;          // the pupil on screen, or null
    var EDIT = false;         // is the record in edit mode
    var HEALTH = null;        // the counts behind the figures
    var SUGG = [];            // sibling pairs waiting to be settled
    var DOBQ = {};            // pupil id -> why the date of birth looks wrong
    var DOBN = 0;             // how many there are
    var NEED = "";            // which "needs attention" filter is on
    var PAGE = 1;             // which page of the filtered roll is shown
    var PER  = 50;            // how many rows a page holds
    var busy = false;

    function el(id) { return document.getElementById(id); }
    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }
    function fail(msg) {
      var n = el("pu-error");
      if (!n) return;
      n.textContent = msg;
      n.hidden = false;
    }
    function clearFail() { show("pu-error", false); }

    //  A date the office would write, not an ISO one.
    function longDate(iso) {
      if (!iso) return "";
      var d = new Date(String(iso) + "T00:00:00");
      if (isNaN(d)) return String(iso);
      var M = ["January","February","March","April","May","June","July",
               "August","September","October","November","December"];
      return d.getDate() + " " + M[d.getMonth()] + " " + d.getFullYear();
    }
    function age(iso) {
      if (!iso) return null;
      var d = new Date(String(iso) + "T00:00:00");
      if (isNaN(d)) return null;
      var t = new Date(), a = t.getFullYear() - d.getFullYear();
      var m = t.getMonth() - d.getMonth();
      if (m < 0 || (m === 0 && t.getDate() < d.getDate())) a--;
      return a;
    }

    // --- the figures --------------------------------------------------------
    function drawHealth() {
      var host = el("pu-figs");
      if (!host || !HEALTH) return;
      function fig(key, n, label, sub, tone) {
        var on = NEED === key;
        return '<button type="button" class="pu-fig' + (tone ? " " + tone : "")
             + (on ? " is-on" : "") + '" data-need="' + esc(key) + '"'
             + (n ? "" : " disabled")
             + '><b>' + esc(n) + "</b><span>" + esc(label) + "</span>"
             + (sub ? "<small>" + esc(sub) + "</small>" : "") + "</button>";
      }
      host.innerHTML =
          fig("", HEALTH.on_roll, "On roll", "children attending")
        + fig("no_contact", HEALTH.no_contact, "No way to ring",
              "nobody to telephone", HEALTH.no_contact ? "bad" : "")
        + fig("no_class", HEALTH.no_class, "In no class", "not placed",
              HEALTH.no_class ? "warn" : "")
        + fig("no_teacher", HEALTH.no_teacher, "No teacher", "class has none",
              HEALTH.no_teacher ? "warn" : "")
        + fig("no_dob", HEALTH.no_dob, "No date of birth", "age unknown",
              HEALTH.no_dob ? "warn" : "")
        //  NOT "no date of birth" but "a date of birth that cannot be right":
        //  a 51 year old in Year 6, a three year old in a ladies class. The
        //  register holds nine of them and only a parent can settle one, so
        //  the screen finds them rather than correcting them.
        + fig("dob_to_check", DOBN, "Date looks wrong", "check with the parent",
              DOBN ? "warn" : "")
        + fig("no_fee_rate", HEALTH.no_fee_rate, "No fee rate",
              "cannot be charged", "");
    }

    // --- the sibling pairs --------------------------------------------------
    function drawSuggestions() {
      var host = el("pu-sugg");
      if (!host) return;
      if (!SUGG.length) { host.hidden = true; host.innerHTML = ""; return; }
      host.hidden = false;
      var h = '<h3>' + (SUGG.length === 1
              ? "One pair of children might be siblings"
              : SUGG.length + " pairs of children might be siblings") + "</h3>"
        + '<p class="pu-sub">They share a surname and an address, but no parent’s '
        + "telephone number or email address is on both records, so they have not "
        + "been put in one family. Somebody who knows them should say.</p>"
        + '<div class="pu-sugg-rows">';
      for (var i = 0; i < SUGG.length; i++) {
        var s = SUGG[i];
        h += '<div class="pu-sugg-row" data-sugg="' + esc(s.id) + '">'
           + "<div><strong>" + esc(s.a.name) + "</strong> <span class=\"pu-q\">"
           + esc(s.a.family || "no family") + "</span></div>"
           + '<div class="pu-amp">and</div>'
           + "<div><strong>" + esc(s.b.name) + "</strong> <span class=\"pu-q\">"
           + esc(s.b.family || "no family") + "</span></div>"
           + '<div class="pu-sugg-acts">'
           + '<button type="button" class="btn btn-ghost" data-join="1">One family</button>'
           + '<button type="button" class="btn btn-ghost" data-join="0">Not related</button>'
           + "</div></div>";
      }
      host.innerHTML = h + "</div>";
    }

    // --- the roll -----------------------------------------------------------
    function matches(r) {
      var q = (el("pu-q") ? el("pu-q").value : "").trim().toLowerCase();
      var cls = el("pu-class") ? el("pu-class").value : "";
      if (cls && (r.class_ids || []).indexOf(cls) === -1) return false;
      if (NEED === "no_contact" && r.has_contact)  return false;
      if (NEED === "no_class"   && (r.classes || []).length) return false;
      if (NEED === "no_teacher" && r.has_teacher)  return false;
      if (NEED === "no_dob"     && r.date_of_birth) return false;
      if (NEED === "dob_to_check" && !DOBQ[r.id])   return false;
      if (NEED === "no_fee_rate" && r.has_fee_rate) return false;
      if (!q) return true;
      return (r.name + " " + (r.legacy_ref || "") + " " + (r.postcode || "")
            + " " + (r.family || "") + " " + (r.classes || []).join(" "))
             .toLowerCase().indexOf(q) !== -1;
    }

    //  THE FILTERED ROLL.
    //
    //  Pagination applies to what the filters LEAVE, not to the data. One
    //  call to madrasah_roll() brings all 552 children as marks, and the
    //  search and every filter see all of them; only the drawing is paged.
    //
    //  The system this replaces paginates server-side, so finding a child on
    //  page 4 costs a round trip. Here it costs nothing, and the count line
    //  can honestly say "Showing 1-50 of 137" because both numbers are known
    //  at the same moment.
    function filtered() {
      var out = [];
      for (var i = 0; i < ROWS.length; i++) {
        if (matches(ROWS[i])) out.push(ROWS[i]);
      }
      return out;
    }

    //  ANY NARROWING GOES BACK TO PAGE ONE.
    //  Filter to twelve results while sitting on page 4 and the slice starts
    //  past the end of the result: the table draws nothing and the screen
    //  says "No pupil matches that" while twelve of them do.
    function resetPage() { PAGE = 1; }

    function drawRows() {
      var body = el("pu-rows");
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
        var a = age(r.date_of_birth);
        var flags = "";
        //  MARKS, NEVER DETAIL. What the note says is in the record, which
        //  writes down who opened it. See db/076 and the migration that
        //  added madrasah_pupil_one.
        if (r.has_allergy) flags += '<span class="pu-flag">Allergy</span>';
        if (r.has_medical) flags += '<span class="pu-flag">Medical</span>';
        if (r.has_send)    flags += '<span class="pu-flag is-soft">SEND</span>';
        out.push('<tr class="pu-row" tabindex="0" data-id="' + esc(r.id) + '">'
          + '<td class="pu-ref">' + esc(r.legacy_ref || "—") + "</td>"
          + '<td class="pu-who">' + esc(r.name)
          + (r.gender ? '<span class="pu-g">' + esc(r.gender === "male" ? "boy" : "girl")
             + "</span>" : "") + "</td>"
          //  A questionable age carries its reason in the title, so hovering
          //  or a screen reader says why without the list growing a column
          //  that is blank for 543 children out of 552.
          + "<td>" + (a === null ? '<span class="pu-q">not known</span>'
              : (DOBQ[r.id]
                 ? '<span class="pu-age-q" title="' + esc(DOBQ[r.id]) + '">' + esc(a)
                   + '<b aria-hidden="true">?</b><span class="sr-only">'
                   + esc(DOBQ[r.id]) + "</span></span>"
                 : esc(a))) + "</td>"
          + '<td class="pu-cls">' + (( r.classes || []).length
              ? esc(r.classes.join(", "))
              : '<span class="pu-q">no class</span>') + "</td>"
          + '<td class="pu-cls">' + (r.teacher ? esc(r.teacher)
              : '<span class="pu-q">none</span>') + "</td>"
          + '<td class="pu-cls">' + (r.family ? esc(r.family)
              : '<span class="pu-q">no family</span>') + "</td>"
          + '<td><div class="pu-flags">' + flags + "</div></td></tr>");
      }
      body.innerHTML = out.join("");
      var empty = el("pu-empty");
      if (empty) {
        //  The emptiness of the RESULT, not of the page. A page can be empty
        //  while the result is not, and saying so would be a lie.
        empty.hidden = rows.length > 0;
        empty.textContent = ROWS.length
          ? "No pupil matches that."
          : "There are no pupils on the roll yet.";
      }
      var c = el("pu-count");
      if (c) {
        //  SAY WHICH OF HOW MANY. "137 pupils" while fifty are on screen is
        //  a sum somebody has to do in their head to trust the page.
        c.textContent = rows.length === 0 ? "no pupils"
          : rows.length <= PER
            ? (rows.length === 1 ? "1 pupil" : rows.length + " pupils"
               + (rows.length === ROWS.length ? "" : " of " + ROWS.length))
            : "Showing " + (from + 1) + "–" + Math.min(from + PER, rows.length)
              + " of " + rows.length
              + (rows.length === ROWS.length ? "" : " matching");
      }
      drawPager(pages);
    }

    //  THE PAGER, ABOVE AND BELOW THE TABLE.
    //  Somebody who has read to the bottom of fifty rows should not scroll
    //  back to the top to ask for the next fifty. First and last are always
    //  reachable and the middle elides, so 552 pupils is never twelve
    //  buttons.
    function drawPager(pages) {
      var hosts = document.querySelectorAll(".pu-pager");
      if (!hosts.length) return;
      var h = "", p, i;
      if (pages > 1) {
        h += '<div class="pu-pages">'
           + '<button type="button" class="pu-page" data-page="' + (PAGE - 1)
           + '"' + (PAGE === 1 ? " disabled" : "") + ">Back</button>";
        var shown = [];
        for (p = 1; p <= pages; p++) {
          if (p === 1 || p === pages || Math.abs(p - PAGE) <= 1) shown.push(p);
        }
        var last = 0;
        for (i = 0; i < shown.length; i++) {
          p = shown[i];
          if (last && p - last > 1) h += '<span class="pu-gap">…</span>';
          h += '<button type="button" class="pu-page'
             + (p === PAGE ? " is-on" : "") + '" data-page="' + p + '"'
             + (p === PAGE ? ' aria-current="page"' : "")
             + ' aria-label="Page ' + p + '">' + p + "</button>";
          last = p;
        }
        h += '<button type="button" class="pu-page" data-page="' + (PAGE + 1)
           + '"' + (PAGE === pages ? " disabled" : "") + ">Next</button></div>";
      }
      h += '<div class="pu-pers"><span>Per page</span>';
      var opts = [25, 50, 100];
      for (i = 0; i < opts.length; i++) {
        h += '<button type="button" class="pu-per'
           + (PER === opts[i] ? " is-on" : "") + '" data-per="' + opts[i]
           + '">' + opts[i] + "</button>";
      }
      hosts[0].innerHTML = h + "</div>";
      for (i = 1; i < hosts.length; i++) hosts[i].innerHTML = hosts[0].innerHTML;
    }

    // --- one pupil ----------------------------------------------------------
    function row(label, value, quiet) {
      if (value === null || value === undefined || value === "") {
        if (!quiet) return "";
        value = "—";
      }
      return "<dt>" + esc(label) + "</dt><dd>" + esc(value) + "</dd>";
    }

    function drawRecord(p) {
      var host = el("pu-record");
      if (!host) return;
      OPEN = p;
      host.hidden = false;

      var sensitive = "";
      if (p.allergies || p.medical || p.send_detail || p.ehcp_detail) {
        sensitive = '<div class="pu-med"><h5>Read before this child is left with anybody</h5>'
          + (p.allergies   ? "<p><b>Allergies.</b> " + esc(p.allergies) + "</p>" : "")
          + (p.medical     ? "<p><b>Medical.</b> " + esc(p.medical) + "</p>" : "")
          + (p.send_detail ? "<p><b>SEND.</b> " + esc(p.send_detail) + "</p>" : "")
          + (p.ehcp_detail ? "<p><b>EHA or EHCP.</b> " + esc(p.ehcp_detail) + "</p>" : "")
          + "</div>";
      }

      var cls = (p.classes || []).map(function (c) {
        return "<li>" + esc(c.name) + (c.teacher ? " · " + esc(c.teacher) : "") + "</li>";
      }).join("");

      var hh = p.household;
      var guardians = hh && hh.guardians && hh.guardians.length
        ? hh.guardians.map(function (g) {
            return '<div class="pu-guardian"><strong>' + esc(g.name) + "</strong>"
              + (g.is_primary ? ' <span class="pu-pill">first call</span>' : "")
              + '<div class="pu-q">'
              + (g.phone ? '<a href="tel:' + esc(g.phone) + '">' + esc(g.phone) + "</a>" : "")
              + (g.phone && g.email ? " · " : "")
              + (g.email ? '<a href="mailto:' + esc(g.email) + '">' + esc(g.email) + "</a>" : "")
              + (!g.phone && !g.email ? "no telephone and no email address" : "")
              + "</div></div>";
          }).join("")
        : '<p class="pu-warn">Nobody is recorded for this child. If something '
          + "happened this afternoon there is no one to ring.</p>";

      var sibs = hh && hh.siblings && hh.siblings.length
        ? hh.siblings.map(function (s) {
            return '<button type="button" class="pu-mini" data-go="' + esc(s.id) + '">'
                 + esc(s.name) + "</button>";
          }).join(" ")
        : "";

      host.innerHTML =
        '<div class="pu-rec-head"><div>'
        + "<h3>" + esc(p.name) + "</h3>"
        + '<p class="pu-sub">' + esc(p.legacy_ref || "no reference")
        + (p.age !== null && p.age !== undefined ? " · " + esc(p.age) + " years old" : "")
        + (p.gender ? " · " + esc(p.gender === "male" ? "boy" : "girl") : "")
        + "</p></div>"
        + '<div class="pu-rec-acts">'
        + '<button class="btn btn-ghost" id="pu-edit" type="button">Amend these details</button>'
        + '<button class="btn btn-ghost" id="pu-close" type="button">Close</button>'
        + "</div></div>"
        + sensitive
        + '<div class="pu-two">'
        +   "<div><h4>The child</h4><dl class=\"pu-grid\">"
        +     row("Date of birth", longDate(p.date_of_birth), true)
        +     row("School", p.school)
        +     row("School year", p.school_year)
        +     row("Previous madrasah", p.prev_madrasah)
        +     row("Address", [p.address, p.postcode].filter(Boolean).join(", "))
        +     row("Joined", longDate(p.joined_on))
        +     row("Left", longDate(p.left_on))
        +     row("Walks home alone", p.walk_home_consent === true ? "Yes, consented"
                  : p.walk_home_consent === false ? "No" : "")
        +     row("Fee rate", p.fee_rate ? p.fee_rate.name : "None set — cannot be charged")
        +   "</dl>"
        +   (p.notes ? "<h4>Office note</h4><p>" + esc(p.notes) + "</p>" : "")
        +   "</div>"
        +   "<div><h4>Classes</h4>"
        +     (cls ? "<ul class=\"pu-list\">" + cls + "</ul>"
                  : '<p class="pu-warn">This child is in no class.</p>')
        +     "<h4>" + (hh ? esc(hh.name) : "Family") + "</h4>"
        +     guardians
        +     (sibs ? "<h5>Brothers and sisters</h5><div>" + sibs + "</div>" : "")
        +   "</div>"
        + "</div>"
        + '<div class="pu-form" id="pu-editor" hidden></div>';

      host.scrollIntoView({ behavior: "smooth", block: "start" });
    }

    //  THE AMEND FORM. Every field the record shows, and nothing it does not.
    var FIELDS = [
      ["first_name", "First name", "text"], ["last_name", "Last name", "text"],
      ["date_of_birth", "Date of birth", "date"], ["gender", "Boy or girl", "gender"],
      ["school", "School", "text"], ["school_year", "School year", "text"],
      ["prev_madrasah", "Previous madrasah", "text"],
      ["address", "Address", "text"], ["postcode", "Postcode", "text"],
      ["email", "Email address", "email"],
      ["joined_on", "Joined on", "date"], ["left_on", "Left on", "date"],
      ["allergies", "Allergies", "area"], ["medical", "Medical", "area"],
      ["send_detail", "SEND", "area"], ["ehcp_detail", "EHA or EHCP", "area"],
      ["notes", "Office note", "area"]
    ];

    function openEditor() {
      var host = el("pu-editor");
      if (!host || !OPEN) return;
      var h = "<h4>Amend these details</h4>"
        + '<p class="pu-sub">Everything you change is written down against your '
        + "name. Clearing a box removes what was there.</p>";
      for (var i = 0; i < FIELDS.length; i++) {
        var f = FIELDS[i], v = OPEN[f[0]];
        v = (v === null || v === undefined) ? "" : String(v);
        h += '<div class="pu-fld"><label for="pf-' + f[0] + '">' + esc(f[1]) + "</label>";
        if (f[2] === "area") {
          h += '<textarea id="pf-' + f[0] + '" maxlength="600">' + esc(v) + "</textarea>";
        } else if (f[2] === "gender") {
          h += '<select id="pf-' + f[0] + '">'
            + '<option value="">Not recorded</option>'
            + '<option value="male"' + (v === "male" ? " selected" : "") + ">Boy</option>"
            + '<option value="female"' + (v === "female" ? " selected" : "") + ">Girl</option>"
            + "</select>";
        } else {
          h += '<input id="pf-' + f[0] + '" type="' + f[2] + '" value="' + esc(v) + '">';
        }
        h += "</div>";
      }
      h += '<div class="pu-acts">'
        + '<button class="btn btn-gold" id="pu-save" type="button">Save these changes</button>'
        + '<button class="btn btn-ghost" id="pu-cancel" type="button">Cancel</button></div>';
      host.innerHTML = h;
      host.hidden = false;
      EDIT = true;
      var first = host.querySelector("input, textarea, select");
      if (first) first.focus();
    }

    function save() {
      if (busy || !OPEN) return;
      busy = true;
      clearFail();
      var payload = { id: OPEN.id };
      for (var i = 0; i < FIELDS.length; i++) {
        var n = el("pf-" + FIELDS[i][0]);
        if (n) payload[FIELDS[i][0]] = n.value;
      }
      var btn = el("pu-save");
      if (btn) { btn.disabled = true; btn.textContent = "Saving…"; }
      sb.rpc("save_madrasah_pupil_details", { p: payload }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        EDIT = false;
        drawRecord(res.data);
        return load();
      })["catch"](function (e) {
        fail("That did not save. " + (e && e.message ? e.message : ""));
      })["finally"](function () {
        busy = false;
        var b = el("pu-save");
        if (b) { b.disabled = false; b.textContent = "Save these changes"; }
      });
    }

    function open(id) {
      clearFail();
      return sb.rpc("madrasah_pupil_one", { p_id: id }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        EDIT = false;
        drawRecord(res.data);
      })["catch"](function (e) {
        fail("That pupil would not open. " + (e && e.message ? e.message : ""));
      });
    }

    function closeRecord() {
      OPEN = null; EDIT = false;
      var n = el("pu-record");
      if (n) { n.hidden = true; n.innerHTML = ""; }
    }

    // --- loading ------------------------------------------------------------
    function load() {
      return Promise.all([
        sb.rpc("madrasah_roll_health"),
        sb.rpc("madrasah_roll"),
        sb.rpc("madrasah_sibling_suggestions_list"),
        sb.rpc("madrasah_classes_list"),
        sb.rpc("madrasah_dob_to_check")
      ]).then(function (res) {
        if (res[0].error) throw new Error(res[0].error.message);
        HEALTH = res[0].data && res[0].data.allowed ? res[0].data : null;
        ROWS = (res[1].data && res[1].data.rows) || [];
        if (!(ROWS instanceof Array)) ROWS = [];
        SUGG = (res[2].data && res[2].data.rows) || [];
        //  The questionable dates arrive as a list and are turned into a
        //  lookup, so a row can say WHY without the list carrying a reason
        //  for all 552 children.
        DOBQ = {}; DOBN = 0;
        var dq = (res[4] && res[4].data && res[4].data.rows) || [];
        for (var d = 0; d < dq.length; d++) {
          DOBQ[dq[d].id] = dq[d].why; DOBN++;
        }
        var classes = (res[3].data && (res[3].data.rows || res[3].data)) || [];
        var sel = el("pu-class");
        if (sel && classes instanceof Array && sel.options.length <= 1) {
          for (var i = 0; i < classes.length; i++) {
            var o = document.createElement("option");
            o.value = classes[i].id; o.textContent = classes[i].name;
            sel.appendChild(o);
          }
        }
        drawHealth(); drawSuggestions(); drawRows();
      })["catch"](function (e) {
        fail("The roll would not load. " + (e && e.message ? e.message : ""));
      });
    }

    function wire() {
      var q = el("pu-q"), c = el("pu-class");
      //  A filter change closes an open record. Leaving one open under a list
      //  it is no longer part of is how somebody reads the wrong child's
      //  medical note.
      //  Every narrowing goes back to page one. See resetPage().
      function refilter() { closeRecord(); resetPage(); drawRows(); }
      if (q) q.addEventListener("input", refilter);
      if (c) c.addEventListener("change", refilter);

      var figs = el("pu-figs");
      if (figs) figs.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-need]") : null;
        if (!b) return;
        NEED = (NEED === b.getAttribute("data-need")) ? "" : b.getAttribute("data-need");
        closeRecord(); resetPage(); drawHealth(); drawRows();
      });

      //  One delegate for both pagers, since they carry identical markup.
      var pagers = document.querySelectorAll(".pu-pager");
      for (var pi = 0; pi < pagers.length; pi++) {
        pagers[pi].addEventListener("click", function (e) {
          var pb = e.target.closest ? e.target.closest(".pu-page") : null;
          var pr = e.target.closest ? e.target.closest(".pu-per") : null;
          if (pb && !pb.disabled) {
            PAGE = parseInt(pb.getAttribute("data-page"), 10) || 1;
            closeRecord(); drawRows();
            //  Going to page 2 from the bottom pager should not leave you
            //  looking at the bottom of page 2.
            var top = el("pu-roll");
            if (top && top.scrollIntoView) top.scrollIntoView(true);
          } else if (pr) {
            PER = parseInt(pr.getAttribute("data-per"), 10) || 50;
            resetPage(); closeRecord(); drawRows();
          }
        });
      }

      var body = el("pu-rows");
      if (body) {
        body.addEventListener("click", function (e) {
          var tr = e.target.closest ? e.target.closest("tr.pu-row") : null;
          if (tr) open(tr.getAttribute("data-id"));
        });
        body.addEventListener("keydown", function (e) {
          if (e.key !== "Enter" && e.key !== " ") return;
          var tr = e.target.closest ? e.target.closest("tr.pu-row") : null;
          if (tr) { e.preventDefault(); open(tr.getAttribute("data-id")); }
        });
      }

      var rec = el("pu-record");
      if (rec) rec.addEventListener("click", function (e) {
        var t = e.target;
        if (t.id === "pu-close")  { closeRecord(); return; }
        if (t.id === "pu-edit")   { openEditor(); return; }
        if (t.id === "pu-save")   { save(); return; }
        if (t.id === "pu-cancel") { EDIT = false; show("pu-editor", false); return; }
        var go = t.getAttribute && t.getAttribute("data-go");
        if (go) open(go);
      });

      var sg = el("pu-sugg");
      if (sg) sg.addEventListener("click", function (e) {
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
          fail("That did not save. " + (err && err.message ? err.message : ""));
        })["finally"](function () { busy = false; });
      });
    }

    function mount(identity) {
      var roles = (identity && identity.roles) || [];
      //  Teachers as well as administrators. A teacher needs the roll to know
      //  who is in front of them and who to ring; what a teacher cannot do is
      //  join two families, which settle_sibling_suggestion refuses in
      //  Postgres, not here.
      if (roles.indexOf("admin") === -1 && roles.indexOf("madrasah") === -1) {
        //  THE SHELL'S OWN STRIP, not one inside the panel. The first version
        //  of this put the refusal inside #pu-panel - the very thing being
        //  withheld - so it could never be seen, and a teacher without the
        //  role got a blank screen and no explanation. Caught by the suite.
        var na = el("app-noaccess");
        if (na) {
          na.textContent = "This area is for madrasah staff. If you should be "
            + "able to see the roll, ask the office to add you.";
          na.hidden = false;
        }
        return;
      }
      show("pu-panel", true);
      wire();
      return load();
    }

    return { mount: mount };
  })();
