  /* =========================================================================
     ONE PUPIL

     A PAGE, NOT A PANEL. The roll used to open a child in a drawer below the
     list. The masjid asked for the thing their old system does: clicking a
     child opens that child's page. So this is a real screen at
     portal/pupil/?id=<uuid> — the back button works, a refresh keeps you on
     the child, and two members of staff who are both signed in can pass the
     address between them.

     THE URL IS NOT THE ACCESS CONTROL. The id in the query string is an
     opaque UUID, but that is not why this is safe. madrasah_pupil_one() is:
     it requires verified_madrasah(), it requires two-step, and it writes an
     audit row. Paste the address without a session and you get the sign-in
     panel and nothing else. Worth saying plainly, because the temptation
     with a deep link is to treat a hard-to-guess id as the protection.

     THE PAGE TITLE CARRIES NO NAME. Browser history on a shared office
     computer is a real and cheap leak, and a list of visited pages reading
     "Aaliyah Patel — Pupil" is a list of who was looked at. The name is in
     the <h1>, which history does not keep.

     ONE AUDIT ROW PER PUPIL OPENED, written on load — not one per tab. The
     auditable act is opening the child; the tabs are a way of arranging what
     was already fetched. madrasah_pupil_one() is deliberately NOT `stable`,
     because the planner may elide a stable call and take the audit row with
     it.

     THE MEDICAL BOX IS NOT BEHIND A TAB. An allergy and a medical note are
     safety information, and a teacher needs them the moment the page opens,
     not two clicks in. They sit above the tabs and stay there whichever tab
     is chosen. The old system puts Medical in a red box near the top and it
     is right to.
     ======================================================================= */
  var pupil = (function () {

    var P = null;             // the pupil, as loaded
    var TAB = "details";      // which tab is showing
    var EDIT = false;         // is the amend form open
    var busy = false;

    function el(id) { return document.getElementById(id); }
    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }
    function fail(msg) {
      var n = el("pp-error");
      if (!n) return;
      n.textContent = msg;
      n.hidden = false;
    }

    //  A date the office would write, not an ISO one.
    function longDate(iso) {
      if (!iso) return "";
      var d = new Date(String(iso) + "T00:00:00");
      if (isNaN(d)) return String(iso);
      var M = ["January","February","March","April","May","June","July",
               "August","September","October","November","December"];
      return d.getDate() + " " + M[d.getMonth()] + " " + d.getFullYear();
    }
    function years(iso) {
      if (!iso) return null;
      var d = new Date(String(iso) + "T00:00:00");
      if (isNaN(d)) return null;
      var t = new Date(), a = t.getFullYear() - d.getFullYear();
      var m = t.getMonth() - d.getMonth();
      if (m < 0 || (m === 0 && t.getDate() < d.getDate())) a--;
      return a;
    }

    //  WHICH CHILD. Read once, and never trusted as anything but a string
    //  handed straight to the function that checks it.
    function wantedId() {
      var q = String(window.location.search || "");
      var m = q.match(/[?&]id=([^&]+)/);
      return m ? decodeURIComponent(m[1]) : "";
    }

    function row(label, value, quiet) {
      if (value === null || value === undefined || value === "") {
        if (!quiet) return "";
        value = "not recorded";
      }
      return "<dt>" + esc(label) + "</dt><dd>" + esc(value) + "</dd>";
    }

    // --- the tabs -----------------------------------------------------------
    var TABS = [
      ["details",  "Details"],
      ["family",   "Contacts &amp; family"],
      ["classes",  "Classes"],
      ["fees",     "Fees"],
      ["notes",    "Notes"]
    ];

    function drawTabs() {
      var host = el("pp-tabs");
      if (!host) return;
      var h = "";
      for (var i = 0; i < TABS.length; i++) {
        var on = TAB === TABS[i][0];
        h += '<button type="button" class="pp-tab' + (on ? " is-on" : "") + '"'
           + ' role="tab" aria-selected="' + (on ? "true" : "false") + '"'
           + ' data-tab="' + TABS[i][0] + '">' + TABS[i][1] + "</button>";
      }
      host.innerHTML = h;
    }

    function tabDetails(p) {
      var a = p.age !== null && p.age !== undefined ? p.age : years(p.date_of_birth);
      return "<dl class=\"pp-grid\">"
        + row("Reference", p.legacy_ref, true)
        + row("Date of birth", longDate(p.date_of_birth), true)
        + row("Age", a === null ? "" : a + " years old", true)
        + row("Boy or girl", p.gender === "male" ? "Boy"
              : p.gender === "female" ? "Girl" : "", true)
        + row("School", p.school)
        + row("School year", p.school_year)
        + row("Previous madrasah", p.prev_madrasah)
        + row("Address", [p.address, p.postcode].filter(Boolean).join(", "))
        + row("Email address", p.email)
        + row("Joined", longDate(p.joined_on))
        + row("Left", longDate(p.left_on))
        + row("Walks home alone", p.walk_home_consent === true ? "Yes, consented"
              : p.walk_home_consent === false ? "No" : "")
        + "</dl>";
    }

    function tabFamily(p) {
      var hh = p.household;
      if (!hh) {
        return '<p class="pp-warn">This child is in no family, so there is '
             + "nobody recorded to ring. If something happened this afternoon "
             + "there is no one to call.</p>";
      }
      var g = hh.guardians && hh.guardians.length
        ? hh.guardians.map(function (x) {
            return '<div class="pp-guardian"><strong>' + esc(x.name) + "</strong>"
              + (x.is_primary ? ' <span class="pp-pill">first call</span>' : "")
              + '<div class="pp-q">'
              + (x.phone ? '<a href="tel:' + esc(x.phone) + '">' + esc(x.phone) + "</a>" : "")
              + (x.phone && x.email ? " · " : "")
              + (x.email ? '<a href="mailto:' + esc(x.email) + '">' + esc(x.email) + "</a>" : "")
              + (!x.phone && !x.email ? "no telephone and no email address" : "")
              + "</div></div>";
          }).join("")
        : '<p class="pp-warn">Nobody is recorded for this child. If something '
          + "happened this afternoon there is no one to ring.</p>";

      var sibs = hh.siblings && hh.siblings.length
        ? hh.siblings.map(function (s) {
            //  A LINK, NOT A BUTTON. A brother or sister is another page, and
            //  a middle-click or a long press should open it in a tab like
            //  any other link on the internet.
            return '<a class="pp-mini" href="?id=' + encodeURIComponent(s.id) + '">'
                 + esc(s.name) + "</a>";
          }).join(" ")
        : "<p class=\"pp-q\">No brothers or sisters are recorded here.</p>";

      return "<h4>" + esc(hh.name || "Family") + "</h4>"
        + '<p class="pp-q">' + esc(hh.reference || "") + "</p>"
        + g
        + "<h4>Brothers and sisters</h4>" + sibs;
    }

    function tabClasses(p) {
      var cls = (p.classes || []);
      if (!cls.length) {
        return '<p class="pp-warn">This child is in no class.</p>';
      }
      return "<ul class=\"pp-list\">" + cls.map(function (c) {
        return "<li><strong>" + esc(c.name) + "</strong>"
          + (c.teacher ? '<span class="pp-q"> · ' + esc(c.teacher) + "</span>"
                       : '<span class="pp-warn"> · no teacher</span>')
          + "</li>";
      }).join("") + "</ul>";
    }

    function tabFees(p) {
      return "<dl class=\"pp-grid\">"
        + row("Fee rate", p.fee_rate ? p.fee_rate.name
              : "None set — this child cannot be charged", true)
        + "</dl>"
        + '<p class="pp-q">Charges, payments and what a family owes are kept '
        + "with the family rather than the child, because a bill goes to a "
        + "household.</p>"
        + '<a class="btn btn-ghost" href="../fees/families/">Families &amp; fees</a>';
    }

    function tabNotes(p) {
      return p.notes
        ? "<p>" + esc(p.notes) + "</p>"
        : '<p class="pp-q">No office note has been written for this child.</p>';
    }

    function drawPanel() {
      var host = el("pp-panel");
      if (!host || !P) return;
      var h = TAB === "family"  ? tabFamily(P)
            : TAB === "classes" ? tabClasses(P)
            : TAB === "fees"    ? tabFees(P)
            : TAB === "notes"   ? tabNotes(P)
            :                     tabDetails(P);
      host.innerHTML = h;
    }

    // --- the whole page -----------------------------------------------------
    function draw() {
      var p = P;
      if (!p) return;
      var a = p.age !== null && p.age !== undefined ? p.age : years(p.date_of_birth);

      var head = el("pp-head");
      if (head) {
        head.innerHTML =
          "<h2>" + esc(p.name) + "</h2>"
          + '<p class="pp-sub">' + esc(p.legacy_ref || "no reference")
          + (a === null ? "" : " · " + esc(a) + " years old")
          + (p.gender ? " · " + esc(p.gender === "male" ? "boy" : "girl") : "")
          + ((p.classes || []).length
              ? " · " + esc(p.classes[0].name) : "")
          + "</p>";
      }

      //  ABOVE THE TABS AND OUTSIDE THEM. See the note at the top of this
      //  file: safety information is not something to put two clicks away.
      var med = el("pp-med");
      if (med) {
        if (p.allergies || p.medical || p.send_detail || p.ehcp_detail) {
          med.hidden = false;
          med.innerHTML = "<h5>Read before this child is left with anybody</h5>"
            + (p.allergies   ? "<p><b>Allergies.</b> " + esc(p.allergies) + "</p>" : "")
            + (p.medical     ? "<p><b>Medical.</b> " + esc(p.medical) + "</p>" : "")
            + (p.send_detail ? "<p><b>SEND.</b> " + esc(p.send_detail) + "</p>" : "")
            + (p.ehcp_detail ? "<p><b>EHA or EHCP.</b> " + esc(p.ehcp_detail) + "</p>" : "");
        } else {
          med.hidden = true;
          med.innerHTML = "";
        }
      }

      drawTabs();
      drawPanel();
      show("pp-body", true);
    }

    // --- amending -----------------------------------------------------------
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
      var host = el("pp-editor");
      if (!host || !P) return;
      var h = "<h4>Amend these details</h4>"
        + '<p class="pp-sub">Everything you change is written down against your '
        + "name. Clearing a box removes what was there.</p>";
      for (var i = 0; i < FIELDS.length; i++) {
        var f = FIELDS[i], v = P[f[0]];
        v = (v === null || v === undefined) ? "" : String(v);
        h += '<div class="pp-fld"><label for="pf-' + f[0] + '">' + esc(f[1]) + "</label>";
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
      h += '<div class="pp-form-acts">'
        + '<button class="btn btn-gold" id="pp-save" type="button">Save these changes</button>'
        + '<button class="btn btn-ghost" id="pp-cancel" type="button">Cancel</button></div>';
      host.innerHTML = h;
      host.hidden = false;
      EDIT = true;
      var first = host.querySelector("input, textarea, select");
      if (first) first.focus();
    }

    function save() {
      if (busy || !P) return;
      busy = true;
      var patch = {};
      for (var i = 0; i < FIELDS.length; i++) {
        var k = FIELDS[i][0], n = el("pf-" + k);
        if (!n) continue;
        var v = n.value;
        //  AN EMPTY BOX MEANS "REMOVE THIS", not "leave it alone". Saying so
        //  on the form matters: a blank medical note that quietly kept the
        //  old one would be the worst possible failure here.
        patch[k] = (v === "" ? null : v);
      }
      sb.rpc("save_madrasah_pupil_details", { p_id: P.id, p_patch: patch })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          P = res.data;
          EDIT = false;
          show("pp-editor", false);
          draw();
        })["catch"](function (e) {
          fail("That did not save. " + (e && e.message ? e.message : ""));
        })["finally"](function () { busy = false; });
    }

    // --- loading ------------------------------------------------------------
    function load() {
      var id = wantedId();
      if (!id) {
        fail("No pupil was named in the address. Go back to the roll and "
           + "choose a child.");
        return Promise.resolve();
      }
      //  ONE CALL, ONE AUDIT ROW. Everything the tabs show comes from here.
      return sb.rpc("madrasah_pupil_one", { p_id: id }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        if (!res.data) {
          fail("That pupil could not be found. They may have been archived.");
          return;
        }
        P = res.data;
        draw();
      })["catch"](function (e) {
        fail("That pupil would not open. " + (e && e.message ? e.message : ""));
      });
    }

    function wire() {
      var tabs = el("pp-tabs");
      if (tabs) tabs.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest(".pp-tab") : null;
        if (!b) return;
        TAB = b.getAttribute("data-tab");
        drawTabs(); drawPanel();
      });

      var acts = el("pp-acts");
      if (acts) acts.addEventListener("click", function (e) {
        if (e.target.id === "pp-edit") openEditor();
      });

      var ed = el("pp-editor");
      if (ed) ed.addEventListener("click", function (e) {
        if (e.target.id === "pp-save") save();
        if (e.target.id === "pp-cancel") {
          EDIT = false; show("pp-editor", false);
        }
      });
    }

    function mount(identity) {
      var roles = (identity && identity.roles) || [];
      //  Teachers as well as administrators, the same as the roll: a teacher
      //  needs to know who is in front of them and who to ring. The refusal
      //  goes in the SHELL's strip, not inside the panel being withheld —
      //  putting it inside the panel means it can never be seen, which the
      //  roll's suite caught the first time that was tried.
      if (roles.indexOf("admin") === -1 && roles.indexOf("madrasah") === -1) {
        var na = el("app-noaccess");
        if (na) {
          na.textContent = "This area is for madrasah staff. If you should be "
            + "able to see a pupil's record, ask the office to add you.";
          na.hidden = false;
        }
        return;
      }
      show("pp-panel-bk", true);
      wire();
      return load();
    }

    return { mount: mount };
  })();
