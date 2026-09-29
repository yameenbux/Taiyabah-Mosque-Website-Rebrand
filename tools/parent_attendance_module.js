  /* =========================================================================
     ATTENDANCE

     THE HARD CASE IS THE EMPTY ONE, AND IT IS THE ONE EVERY PARENT SEES FIRST.
     The madrasah has not opened its register yet. An empty table under the
     heading "Attendance" reads as "no absences", which reads as "perfect", and
     a parent who is told that about a child who has in fact missed six
     evenings has been told something false by a page that only said nothing.
     So when the register is not being kept (attendance_permitted() is false
     and there is nothing to show) the screen says, in a sentence, that
     NOTHING HAS BEEN MARKED and that this is not a record of attendance. The
     table is not drawn at all.

     WHO RECORDED IT is the third column because it is the question a parent
     asks when a mark surprises them: was that the madrasah, or was it me?
     "You" is a report made from this login; "Your household" is a report from
     another guardian's login or one the office took down when somebody rang;
     "The madrasah" is anything the register or the office wrote.
     ======================================================================= */
  var parentAtt = (function () {
    var C = parentCommon;

    function byWhom(m) {
      if (m.source === "parent") return m.by_me ? "You" : "Your household";
      return "The madrasah";
    }

    function tally(marks) {
      var t = { present: 0, late: 0, away: 0 }, i;
      for (i = 0; i < marks.length; i++) {
        if (marks[i].mark === "present") t.present++;
        else if (marks[i].mark === "late") t.late++;
        else t.away++;
      }
      return t;
    }

    function nothingMarked(kid, att) {
      return '<div class="pt-empty" role="status"><p><b>Nothing has been marked for '
           + C.esc(att.first_name) + " yet.</b></p>"
           + "<p>The madrasah is not keeping the register at the moment, so there "
           + "is no attendance to show. That is not the same as a clean record: "
           + "it means nobody has been marked present or absent.</p>"
           + "<p>You will see each evening here once the register is being kept.</p></div>";
    }

    function noneSince(att) {
      return '<div class="pt-empty" role="status"><p><b>No evenings marked yet.</b></p>'
           + "<p>The register opened on " + C.esc(C.fullDate(att.opened_on))
           + ", and no evening since then has been marked for " + C.esc(att.first_name)
           + ". This page fills in as each register is taken.</p></div>";
    }

    function table(att) {
      var marks = att.marks, i, m, t = tally(marks);
      var h = '<p class="pt-tally"><b>' + t.present + "</b> present &middot; <b>"
            + t.late + "</b> late &middot; <b>" + t.away + "</b> absent</p>"
            + '<div class="pt-tablewrap"><table class="pt-table"><thead><tr>'
            + "<th scope=\"col\">Evening</th><th scope=\"col\">Mark</th>"
            + "<th scope=\"col\">Reason</th><th scope=\"col\">Recorded by</th>"
            + "</tr></thead><tbody>";
      for (i = 0; i < marks.length; i++) {
        m = marks[i];
        h += '<tr class="pt-m-' + C.esc(m.mark) + '">'
           + '<th scope="row" data-label="Evening">' + C.esc(C.longDate(m.on_date))
           + (m["class"] ? '<span class="pt-q">' + C.esc(m["class"]) + "</span>" : "") + "</th>"
           + '<td data-label="Mark"><span class="pt-mark">' + C.esc(C.markWord(m.mark)) + "</span></td>"
           + '<td data-label="Reason">' + (m.reason ? C.esc(m.reason) : '<span class="pt-none">&mdash;</span>') + "</td>"
           + '<td data-label="Recorded by">' + C.esc(byWhom(m)) + "</td></tr>";
      }
      return h + "</tbody></table></div>";
    }

    function section(kid, att, n) {
      var h = '<section class="pt-card" aria-labelledby="pa-h-' + n + '">'
            + '<h2 id="pa-h-' + n + '">' + C.esc(att.first_name) + "</h2>";
      if (!att.marks.length) {
        h += att.permitted && att.opened_on ? noneSince(att) : nothingMarked(kid, att);
      } else {
        if (!att.permitted) {
          h += '<p class="pt-note" role="status">The register is not being kept at the '
             + "moment. What is below was recorded before that.</p>";
        }
        h += table(att);
      }
      return h + "</section>";
    }

    function mount() {
      var panel = C.el("pa-panel");
      if (!panel) return;
      panel.hidden = false;
      C.family().then(function (fam) {
        var kids = (fam && fam.children) || [];
        if (!kids.length) {
          C.show("pa-loading", false);
          C.fail("pa-error", { code: "42501", message: "There are no children on this login at the moment. Please ring the office on " + C.OFFICE + "." });
          return;
        }
        return Promise.all(kids.map(function (k) {
          return C.call("parent_attendance", { p_pupil: k.pupil_id });
        })).then(function (all) {
          var h = "", i;
          for (i = 0; i < kids.length; i++) h += section(kids[i], all[i], i);
          C.el("pa-kids").innerHTML = h;
          C.show("pa-loading", false);
          C.show("pa-kids", true);
          //  The footnote is about marks; with none on the page it is noise.
          var any = false, j;
          for (j = 0; j < all.length; j++) if (all[j].marks.length) any = true;
          C.show("pa-fine", any);
        });
      }).then(null, function (e) {
        C.show("pa-loading", false);
        C.fail("pa-error", e);
      });
    }

    return { mount: mount };
  })();
