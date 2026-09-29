  /* =========================================================================
     PROGRESS

     WHAT A TEACHER HAS CHOSEN TO SHARE ABOUT YOUR CHILD, AND NOTHING ELSE.
     Not everything a teacher writes is for a family: they keep working notes
     of their own, and those never reach this page. parent_progress() returns
     only entries the teacher explicitly shared, and its body does not contain
     the name of the staff-only column at all (db/127 proves that by reading the
     installed definition). This screen therefore has nothing to hide: it draws
     what it is given, and it is given only what was shared.

     THE HARD CASE IS THE EMPTY ONE, AND IT IS THE ONE EVERY PARENT SEES FIRST.
     An empty page under the heading "Progress" reads as "there is nothing to
     say about my child", which reads as a verdict. So when nothing has been
     shared the screen says, in a sentence, that NOTHING HAS BEEN SHARED YET -
     that a teacher shares an entry when they choose to, and that this is not a
     judgement of the child.

     NEWEST FIRST, WITH THE DATE AND THE TEACHER'S NAME. Sabaq, sabqi and manzil
     are named in words a parent can follow (new lesson, recent revision, older
     revision), and the Arabic terms are kept because that is what the teacher
     said to them at the door.
     ======================================================================= */
  var parentProgress = (function () {
    var C = parentCommon;

    function line(label, what, value) {
      if (!value) return "";
      return "<div><dt>" + C.esc(label) + ' <span class="pp-what">' + C.esc(what)
           + "</span></dt><dd>" + C.esc(value) + "</dd></div>";
    }

    function entry(e) {
      var h = '<li class="pp-entry"><h3 class="pp-date">' + C.esc(C.fullDate(e.on_date)) + "</h3>";
      if (e.sabaq || e.sabqi || e.manzil) {
        h += '<dl class="pp-dl">'
           + line("Sabaq", "new lesson", e.sabaq)
           + line("Sabqi", "recent revision", e.sabqi)
           + line("Manzil", "older revision", e.manzil)
           + "</dl>";
      }
      if (e.note) {
        h += '<p class="pp-note"><span class="pp-tag">A note for you</span>' + C.esc(e.note) + "</p>";
      }
      h += '<p class="pp-by">' + (e.teacher ? "From " + C.esc(e.teacher) : "From your child’s teacher")
         + (e["class"] ? " &middot; " + C.esc(e["class"]) : "") + "</p></li>";
      return h;
    }

    function nothingShared(name) {
      return '<div class="pt-empty" role="status"><p><b>Nothing has been shared about '
           + C.esc(name) + " yet.</b></p>"
           + "<p>A teacher shares an entry here when they choose to. That is not a "
           + "judgement of " + C.esc(name) + ": it only means nothing has been shared so far.</p>"
           + "<p>Entries will appear here, newest first, as they are shared.</p></div>";
    }

    function section(p, n) {
      var h = '<section class="pt-card" aria-labelledby="pp-h-' + n + '">'
            + '<h2 id="pp-h-' + n + '">' + C.esc(p.first_name) + "</h2>", i;
      if (!p.entries.length) return h + nothingShared(p.first_name) + "</section>";
      h += '<ul class="pp-entries">';
      for (i = 0; i < p.entries.length; i++) h += entry(p.entries[i]);
      return h + "</ul></section>";
    }

    function mount() {
      var panel = C.el("pp-panel");
      if (!panel) return;
      panel.hidden = false;
      C.family().then(function (fam) {
        var kids = (fam && fam.children) || [];
        if (!kids.length) {
          C.show("pp-loading", false);
          C.fail("pp-error", { code: "42501", message: "There are no children on this login at the moment. Please ring the office on " + C.OFFICE + "." });
          return;
        }
        return Promise.all(kids.map(function (k) {
          return C.call("parent_progress", { p_pupil: k.pupil_id });
        })).then(function (all) {
          var h = "", i, any = false;
          for (i = 0; i < kids.length; i++) {
            h += section(all[i], i);
            if (all[i].entries.length) any = true;
          }
          C.el("pp-kids").innerHTML = h;
          C.show("pp-loading", false);
          C.show("pp-kids", true);
          C.show("pp-fine", any);
        });
      }).then(null, function (e) {
        C.show("pp-loading", false);
        C.fail("pp-error", e);
      });
    }

    return { mount: mount };
  })();
