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
