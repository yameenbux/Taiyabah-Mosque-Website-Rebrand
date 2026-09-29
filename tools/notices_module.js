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
    var VERSION = "1.7";

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
            var top = el("nt-roll");
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
