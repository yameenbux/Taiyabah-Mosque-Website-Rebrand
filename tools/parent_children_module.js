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
