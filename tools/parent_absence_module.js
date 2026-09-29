  /* =========================================================================
     REPORT AN ABSENCE

     THE FORM OFFERS ONLY WHAT THE DATABASE WILL TAKE. The list of evenings
     comes from parent_absence_options(): the evenings the madrasah ran, since
     the register opened, inside the last fortnight, never the future. A parent
     is not shown a date picker and left to find out which dates work; every
     evening on the screen is one the server has already said it will take, and
     the ones it will not (the madrasah has recorded them, or the register has
     been handed in) are drawn locked with the reason beside them.

     THE SERVER STILL DECIDES. Everything above is a courtesy. The button calls
     record_parent_absence(), which re-checks every rule and refuses in a
     parent's own words (db/124); this screen shows whatever it says. It does
     not translate a refusal or soften it, because the refusal is the true
     account of why nothing was written.

     WHAT TELLING US DOES. A report is a parent's word, kept as such: it never
     replaces the register. If the child turns up after all the teacher marks
     them present, and that wins. The page says so, because otherwise a parent
     who reported "away" and then brought the child in would wonder which one
     the madrasah believes.

     FUTURE EVENINGS ARE NOT ON THIS FORM, and the page says who to ring. A
     report of a day that has not happened is refused by the rule from spec 1
     (not the future); widening that belongs to a decision about how far ahead
     the office wants to be told, not to a form.
     ======================================================================= */
  var parentAbsence = (function () {
    var C = parentCommon;
    var KIDS = [];      //  parent_my_children().children
    var CUR = null;     //  the child being reported for
    var OPTS = null;    //  parent_absence_options() for CUR
    var busy = false;

    function existing(ev) {
      var m = ev.existing_mark;
      if (!m) return "";
      var word = C.markWord(m);
      if (ev.existing_source === "madrasah") {
        return "The madrasah has recorded this evening as " + word.toLowerCase() + ".";
      }
      return (ev.existing_by_me ? "You told us: " : "Already reported: ") + word
           + (ev.existing_reason ? " (" + ev.existing_reason + ")" : "") + ".";
    }

    function evening(ev, first, today, n) {
      var d = C.longDate(ev.on_date);
      var tag = ev.on_date === today ? ' <span class="pt-chip">tonight</span>' : "";
      var said = existing(ev);
      if (!ev.can_change) {
        return '<li class="pt-ev pt-locked"><span class="pt-ev-d"><b>' + C.esc(d)
             + "</b>" + tag + '</span><span class="pt-ev-s">'
             + (said ? C.esc(said) + " " : "")
             + (ev.existing_source === "madrasah"
                  ? "If that is not right, please ring the office."
                  : "That evening's register has been handed in, so only the office can change it. Please ring the office.")
             + "</span></li>";
      }
      return '<li class="pt-ev"><label for="pb-ev-' + n + '">'
           + '<input type="radio" name="pb-ev" id="pb-ev-' + n + '" value="' + C.esc(ev.on_date) + '">'
           + '<span class="pt-ev-d"><b>' + C.esc(d) + "</b>" + tag + "</span>"
           + '<span class="pt-ev-s">' + (said ? C.esc(said) + " You can change it." : "Nothing recorded yet.")
           + "</span></label></li>";
    }

    function explain(why, first) {
      if (why === "not_on_roll") {
        return C.esc(first) + " is not on the roll of a class at the moment, so an absence "
             + "cannot be reported here. Please ring the office on " + C.esc(C.OFFICE) + ".";
      }
      if (why === "not_started") {
        return "The register is not being kept at the moment, so we cannot take a report of "
             + "an absence here. Please ring the office on " + C.esc(C.OFFICE) + ".";
      }
      return "There have been no madrasah evenings in the last fortnight to report on.";
    }

    function formHtml() {
      var first = OPTS.first_name, h = "", i, evs = OPTS.evenings || [];
      h += '<h2 class="pt-h">' + C.esc(first) + "</h2>";
      if (OPTS.why) {
        return h + '<p class="pt-empty" role="status">' + explain(OPTS.why, first) + "</p>";
      }
      h += '<form id="pb-f" novalidate>'
         + '<fieldset class="pt-fs"><legend>Which evening?</legend><ul class="pt-evs">';
      for (i = 0; i < evs.length; i++) h += evening(evs[i], first, OPTS.today, i);
      h += "</ul></fieldset>"
         + '<fieldset class="pt-fs"><legend>What happened?</legend><div class="pt-seg">'
         + '<label for="pb-t-away"><input type="radio" name="pb-t" id="pb-t-away" value="away">'
         + "<span><b>Away</b><i>will not be there</i></span></label>"
         + '<label for="pb-t-late"><input type="radio" name="pb-t" id="pb-t-late" value="late">'
         + "<span><b>Late</b><i>will arrive after the start</i></span></label></div></fieldset>"
         + '<div class="pt-field"><label for="pb-why">Reason <span class="pt-opt">(optional)</span></label>'
         + '<textarea id="pb-why" rows="3" maxlength="500" placeholder="A few words is plenty, for example unwell or family event"></textarea>'
         + '<span class="pt-fine">Up to 500 characters.</span></div>'
         + '<p class="pt-error-inline" id="pb-inline" role="alert" hidden></p>'
         + '<p class="pt-acts"><button type="submit" class="btn btn-gold" id="pb-go">Tell the madrasah</button></p>'
         + "</form>"
         + '<p class="pt-note">If ' + C.esc(first) + " turns up after all, the teacher marks them "
         + "present and that is what counts. Your report is kept as what you told us, "
         + "and never replaces the register.</p>"
         + '<p class="pt-note">This form is for tonight and the last fortnight. To let us know '
         + "about a later evening, please ring the office on <b>" + C.esc(C.OFFICE) + "</b>.</p>";
      return h;
    }

    function pickHtml() {
      var h = '<fieldset class="pt-fs"><legend>Which child?</legend><div class="pt-seg pt-kids">', i;
      for (i = 0; i < KIDS.length; i++) {
        h += '<label for="pb-k-' + i + '"><input type="radio" name="pb-k" id="pb-k-' + i
           + '" value="' + C.esc(KIDS[i].pupil_id) + '"><span><b>' + C.esc(KIDS[i].first_name)
           + "</b></span></label>";
      }
      return h + "</div></fieldset>";
    }

    function loadOptions(kid) {
      CUR = kid;
      C.el("pb-form").innerHTML = '<p class="pt-loading">Loading&hellip;</p>';
      C.show("pb-form", true);
      C.show("pb-done", false);
      return C.call("parent_absence_options", { p_pupil: kid.pupil_id }).then(function (o) {
        OPTS = o;
        C.el("pb-form").innerHTML = formHtml();
        wireForm();
      }, function (e) {
        C.el("pb-form").innerHTML = "";
        C.fail("pb-error", e);
      });
    }

    function inline(msg) {
      var n = C.el("pb-inline");
      if (!n) return;
      n.textContent = msg || "";
      n.hidden = !msg;
    }

    function checked(name) {
      var nodes = document.getElementsByName(name), i;
      for (i = 0; i < nodes.length; i++) if (nodes[i].checked) return nodes[i].value;
      return "";
    }

    function submit(e) {
      e.preventDefault();
      if (busy) return;
      C.show("pb-error", false);
      var date = checked("pb-ev"), kind = checked("pb-t");
      var why = (C.el("pb-why").value || "").replace(/^\s+|\s+$/g, "");
      if (!date) { inline("Please choose which evening."); return; }
      if (!kind) { inline("Please say whether " + OPTS.first_name + " will be away or late."); return; }
      inline("");
      //  Away with a reason is what the register calls "excused"; away with
      //  none is "absent". A parent is never asked to know the difference.
      var mark = kind === "late" ? "late" : (why ? "excused" : "absent");
      busy = true;
      var btn = C.el("pb-go");
      btn.disabled = true; btn.textContent = "Please wait…";
      C.call("record_parent_absence", {
        p_pupil: CUR.pupil_id, p_date: date, p_mark: mark, p_reason: why || null
      }).then(function () {
        C.el("pb-done").innerHTML =
          "<h2>Thank you, we have it.</h2><p>We have recorded that <b>"
          + C.esc(CUR.first_name) + "</b> will be " + (kind === "late" ? "late" : "away")
          + " on <b>" + C.esc(C.longDate(date)) + "</b>."
          + (why ? " You said: &ldquo;" + C.esc(why) + "&rdquo;." : "")
          + '</p><p class="pt-acts"><button type="button" class="btn btn-ghost" id="pb-again">'
          + 'Report another evening</button> <a class="btn btn-ghost" href="../attendance/">See attendance</a></p>';
        C.show("pb-form", false);
        C.show("pb-done", true);
        C.el("pb-again").addEventListener("click", function () { loadOptions(CUR); });
      }, function (err) {
        C.fail("pb-error", err);
        btn.disabled = false; btn.textContent = "Tell the madrasah";
      })["finally"](function () { busy = false; });
    }

    function wireForm() {
      var f = C.el("pb-f");
      if (f) f.addEventListener("submit", submit);
    }

    function choose(id) {
      var i;
      for (i = 0; i < KIDS.length; i++) if (KIDS[i].pupil_id === id) return loadOptions(KIDS[i]);
    }

    function mount() {
      var panel = C.el("pb-panel");
      if (!panel) return;
      panel.hidden = false;
      C.family().then(function (fam) {
        KIDS = (fam && fam.children) || [];
        C.show("pb-loading", false);
        if (!KIDS.length) {
          C.fail("pb-error", { code: "42501", message: "There are no children on this login at the moment. Please ring the office on " + C.OFFICE + "." });
          return;
        }
        if (KIDS.length === 1) return loadOptions(KIDS[0]);
        C.el("pb-pick").innerHTML = pickHtml();
        C.show("pb-pick", true);
        C.el("pb-pick").addEventListener("change", function (ev) {
          if (ev.target && ev.target.name === "pb-k") { C.show("pb-error", false); choose(ev.target.value); }
        });
      }).then(null, function (e) {
        C.show("pb-loading", false);
        C.fail("pb-error", e);
      });
    }

    return { mount: mount };
  })();
