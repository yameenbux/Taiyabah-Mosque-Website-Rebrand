/* ===========================================================================
   portal/fees/families/app.js — who pays.

   THE SCREEN THAT WAS NEARLY NOT BUILT, AND THE FAILURE IS WORTH RECORDING.

   Migration 068 created madrasah_households and madrasah_guardians and the
   functions to write them. Six screens were then built on top: every one has
   a family picker, every one searched that table, and every one was correct.
   Nothing could put a row into it. The whole section was unusable and the
   tests were green, because each screen was right about its own job and no
   test asked whether the sequence a person has to follow existed end to end.

   That is the shape to watch for. A missing screen does not throw; it makes
   a search box that always comes back empty, which reads as "no families yet"
   rather than as a hole.

   THE BULK JOB COMES FIRST. 543 children were imported from a class list with
   no family column in it, so on day one every one of them is unhoused. A
   search box alone would mean the office typing five hundred names. So the
   backlog is the first block on the screen, and putting a child in a family
   is two presses from it.
   =========================================================================== */
(function () {
  "use strict";

  FeesGate.start({
    key: "md-families",
    title: "Families",
    depth: 3,

    mount: function (identity, sb, h) {
      var el = h.el;
      var FAMILIES = [];
      var UNHOUSED = [];
      var open = null;          // the family being edited, as an object
      var moving = null;        // the pupil being placed
      var findTimer = null;

      function load() {
        return Promise.all([
          sb.rpc("madrasah_household_list", { p_q: null }),
          sb.rpc("madrasah_pupils_for_family",
                 { p_q: null, p_unhoused: true, p_limit: 500 })
        ]).then(function (out) {
          if (out[0].error) throw new Error(out[0].error.message);
          if (out[1].error) throw new Error(out[1].error.message);
          FAMILIES = h.list(out[0].data);
          UNHOUSED = h.list(out[1].data);
          figs();
          drawUnhoused();
          drawList();
        }).catch(function (e) {
          h.note("fx-error", "The families could not be read — "
                 + ((e && e.message) || String(e)));
        });
      }

      function figs() {
        var noContact = FAMILIES.filter(function (f) { return !f.has_email; }).length;
        var kids = FAMILIES.reduce(function (a, f) { return a + Number(f.pupils || 0); }, 0);
        el("fm-figs").innerHTML =
            '<div class="fx-fig"><span class="n">' + FAMILIES.length
          + '</span><span class="k">Families</span>'
          + '<span class="s">' + kids + ' children between them</span></div>'
          + '<div class="fx-fig ' + (UNHOUSED.length ? "owe" : "good") + '">'
          + '<span class="n">' + UNHOUSED.length
          + '</span><span class="k">Children with no family</span>'
          + '<span class="s">' + (UNHOUSED.length
              ? "nobody is billed for them" : "every child is billed for")
          + '</span></div>'
          + '<div class="fx-fig ' + (noContact ? "owe" : "quiet") + '">'
          + '<span class="n">' + noContact
          + '</span><span class="k">Families with no email</span>'
          + '<span class="s">' + (noContact
              ? "cannot be sent a reminder" : "everybody can be written to")
          + '</span></div>';
      }

      /* ------------------------------------------- children with none ---- */
      function drawUnhoused() {
        var q = el("fm-psearch").value.trim().toLowerCase();
        var rows = UNHOUSED.filter(function (p) {
          return !q || (p.name || "").toLowerCase().indexOf(q) !== -1;
        });

        el("fm-pcount").textContent = rows.length === UNHOUSED.length
          ? UNHOUSED.length + " child" + (UNHOUSED.length === 1 ? "" : "ren")
          : rows.length + " of " + UNHOUSED.length;

        if (!UNHOUSED.length) {
          el("fm-unhoused").innerHTML = '<div class="fx-empty">'
            + 'Every child at the madrasah is in a family.</div>';
          return;
        }
        if (!rows.length) {
          el("fm-unhoused").innerHTML = '<div class="fx-empty">Nothing matches that.</div>';
          return;
        }

        el("fm-unhoused").innerHTML =
            '<div class="fx-tw"><table class="fx-t"><thead><tr>'
          + '<th>Child</th><th>Class</th><th>Joined</th><th></th>'
          + '</tr></thead><tbody>'
          //  Capped at fifty on screen. Five hundred rows of nothing but
          //  "Put in a family" is a wall, not a worklist.
          + rows.slice(0, 50).map(function (p) {
              return '<tr><td><strong>' + h.esc(p.name) + '</strong></td>'
                //  THE CLASS IS HERE BECAUSE IT IS THE ONLY THING THAT TELLS
                //  TWO CHILDREN OF THE SAME NAME APART. 058 holds no date of
                //  birth, deliberately, and twelve names at this masjid are
                //  shared by two children each.
                + '<td class="ref">' + h.esc(p.classes || "no class") + '</td>'
                + '<td>' + h.esc(p.joined_on ? h.shortDate(p.joined_on) : "—") + '</td>'
                + '<td class="num"><button type="button" class="fx-mini" '
                + 'data-place="' + h.esc(p.id) + '">Put in a family</button></td></tr>'
                + (moving === p.id ? placeRow(p) : '');
            }).join("")
          + '</tbody></table></div>'
          + (rows.length > 50
              ? '<p class="fx-note">Showing the first 50 of ' + rows.length
                + '. Use the search box, or work down the list &mdash; it shrinks '
                + 'as you go.</p>'
              : '');

        Array.prototype.forEach.call(
          el("fm-unhoused").querySelectorAll("[data-place]"), function (b) {
            b.addEventListener("click", function () {
              moving = moving === b.getAttribute("data-place")
                ? null : b.getAttribute("data-place");
              drawUnhoused();
            });
          });
        wirePlace();
      }

      /*  PUTTING A CHILD SOMEWHERE OFFERS BOTH ANSWERS AT ONCE: an existing
          family, or a new one named after them. Making somebody go and create
          a family first, then come back and find the child again, is what
          turns a 543-row job into one nobody finishes. */
      function placeRow(p) {
        return '<tr><td colspan="4"><div class="fx-confirm" style="border-color:var(--line);background:rgba(94,24,68,.03)">'
          + '<p>Which family does <strong>' + h.esc(p.name) + '</strong> belong to?</p>'
          + '<div class="fx-form">'
          + '<label class="fx-fld wide fx-picker"><span>An existing family</span>'
          + '<input type="text" id="pl-fam" autocomplete="off" '
          + 'placeholder="Surname, or MF-0148">'
          + '<div class="fx-results" id="pl-results" hidden></div></label>'
          + '<label class="fx-fld wide"><span>Or start a new one</span>'
          + '<input type="text" id="pl-new" maxlength="120" placeholder="'
          + h.esc(surnameOf(p.name)) + ' &mdash; and the street, if you know it">'
          + '<span class="hint">The street is worth adding. Two families at '
          + 'this masjid will share a surname.</span></label>'
          + '</div>'
          + '<div class="fx-acts">'
          + '<button type="button" class="btn btn-gold" data-plsave="' + h.esc(p.id)
          + '">Put them in it</button>'
          + '<button type="button" class="btn btn-ghost" data-plno="1">Cancel</button>'
          + '</div></div></td></tr>';
      }

      function surnameOf(name) {
        var bits = String(name || "").trim().split(/\s+/);
        return bits.length > 1 ? bits[bits.length - 1] : "";
      }

      function wirePlace() {
        if (!el("pl-fam")) return;
        var chosen = null;

        el("pl-fam").addEventListener("input", function () {
          chosen = null;
          clearTimeout(findTimer);
          var q = el("pl-fam").value.trim();
          if (q.length < 2) { el("pl-results").hidden = true; return; }
          findTimer = setTimeout(function () {
            sb.rpc("madrasah_household_list", { p_q: q }).then(function (res) {
              if (res.error) throw new Error(res.error.message);
              var rows = h.list(res.data);
              el("pl-results").innerHTML = rows.length
                ? rows.slice(0, 12).map(function (r) {
                    return '<button type="button" class="fx-pick" data-id="'
                      + h.esc(r.id) + '"><span class="fx-pick-n">' + h.esc(r.name)
                      + '</span><span class="fx-pick-r">' + h.esc(r.reference)
                      + '</span></button>';
                  }).join("")
                : '<p class="fx-none">No family matches that. Start a new one below.</p>';
              el("pl-results").hidden = false;
              Array.prototype.forEach.call(
                el("pl-results").querySelectorAll(".fx-pick"), function (b) {
                  b.addEventListener("click", function () {
                    var r = rows.filter(function (x) {
                      return x.id === b.getAttribute("data-id"); })[0];
                    chosen = r || null;
                    el("pl-fam").value = r ? r.name + "  (" + r.reference + ")" : "";
                    el("pl-new").value = "";
                    el("pl-results").hidden = true;
                  });
                });
            }).catch(function () { el("pl-results").hidden = true; });
          }, 220);
        });

        var save = el("fm-unhoused").querySelector("[data-plsave]");
        save.addEventListener("click", function () {
          var pupil = save.getAttribute("data-plsave");
          var fresh = el("pl-new").value.trim();
          h.note("fx-error", ""); h.note("fx-ok", "");

          if (!chosen && !fresh) {
            h.note("fx-error", "Pick a family, or type a name for a new one.");
            return;
          }
          h.busy(save, true, "Put them in it");

          var got = chosen
            ? Promise.resolve({ id: chosen.id, name: chosen.name })
            : sb.rpc("save_madrasah_household", { p: { name: fresh } })
                .then(function (res) {
                  if (res.error) throw new Error(res.error.message);
                  return { id: res.data.id, name: fresh,
                           reference: res.data.reference };
                });

          got.then(function (fam) {
            return sb.rpc("set_pupil_household",
                          { p_pupil: pupil, p_household: fam.id })
              .then(function (res) {
                if (res.error) throw new Error(res.error.message);
                moving = null;
                h.note("fx-ok", "Added to " + fam.name
                     + (fam.reference ? " (" + fam.reference + ")" : "") + ".");
                return load();
              });
          }).catch(function (e) {
            h.note("fx-error", "Nothing was changed — "
                   + ((e && e.message) || String(e)));
            h.busy(save, false, "Put them in it");
          });
        });

        var no = el("fm-unhoused").querySelector("[data-plno]");
        if (no) no.addEventListener("click", function () { moving = null; drawUnhoused(); });
      }

      /* ------------------------------------------------- the families ---- */
      function drawList() {
        var q = el("fm-search").value.trim().toLowerCase();
        var rows = FAMILIES.filter(function (f) {
          return !q || (f.name || "").toLowerCase().indexOf(q) !== -1
                    || (f.reference || "").toLowerCase().indexOf(q) !== -1;
        });

        el("fm-count").textContent = rows.length === FAMILIES.length
          ? FAMILIES.length + " famil" + (FAMILIES.length === 1 ? "y" : "ies")
          : rows.length + " of " + FAMILIES.length;

        if (!FAMILIES.length) {
          el("fm-list").innerHTML = '<div class="fx-empty">No families yet. '
            + 'Start one from the list above, or press “Add a family”.</div>';
          return;
        }
        if (!rows.length) {
          el("fm-list").innerHTML = '<div class="fx-empty">Nothing matches that.</div>';
          return;
        }

        el("fm-list").innerHTML =
            '<div class="fx-tw"><table class="fx-t"><thead><tr>'
          + '<th>Family</th><th>Reference</th><th>Children</th>'
          + '<th>Who we contact</th><th></th></tr></thead><tbody>'
          + rows.map(function (f) {
              return '<tr><td><strong>' + h.esc(f.name) + '</strong>'
                + (f.former ? ' <span class="ref">+' + h.esc(f.former)
                              + ' who have left</span>' : '')
                + '</td>'
                + '<td class="ref">' + h.esc(f.reference) + '</td>'
                + '<td>' + h.esc(f.pupils) + '</td>'
                //  WHETHER, NOT WHO. 065's rule: a list is read far more often
                //  than a record is opened, so contact details stay in the
                //  record and out of every screenshot and browser cache.
                + '<td>' + (f.has_email
                    ? '<span class="fx-flag ok">email</span> '
                    : '<span class="fx-flag warn">no email</span> ')
                  + (f.has_phone ? '<span class="fx-flag ok">phone</span>' : '')
                + '</td>'
                + '<td class="num"><button type="button" class="fx-mini" '
                + 'data-fam="' + h.esc(f.id) + '">Open</button></td></tr>';
            }).join("")
          + '</tbody></table></div>';

        Array.prototype.forEach.call(
          el("fm-list").querySelectorAll("[data-fam]"), function (b) {
            b.addEventListener("click", function () {
              openFamily(b.getAttribute("data-fam"));
            });
          });
      }

      function openFamily(id) {
        h.note("fx-error", ""); h.note("fx-ok", "");
        if (!id) {
          open = { id: null, name: "", note: "", guardians: [], pupils: [] };
          drawEditor();
          return;
        }
        sb.rpc("madrasah_household_one", { p_id: id }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          open = res.data || null;
          drawEditor();
        }).catch(function (e) {
          h.note("fx-error", "That family could not be read — "
                 + ((e && e.message) || String(e)));
        });
      }

      function drawEditor() {
        var bk = el("fm-editor-bk");
        if (!open) { bk.hidden = true; return; }
        bk.hidden = false;
        el("fm-editor-t").textContent = open.id
          ? open.name + "  ·  " + open.reference
          : "A new family";

        var gs = h.list(open.guardians);
        if (!gs.length) gs = [{ full_name: "", email: "", phone: "", is_primary: true }];

        el("fm-editor").innerHTML =
            '<div class="fx-form">'
          + '<label class="fx-fld wide"><span>Family name</span>'
          + '<input type="text" id="fm-name" maxlength="120" value="'
          + h.esc(open.name || "") + '" placeholder="Khan — 14 Blackburn Road">'
          + '<span class="hint">Surname and street. Two families at this masjid '
          + 'will share a surname, and the reference is what the bank sees — '
          + 'this is what a person reads.</span></label>'
          + '<label class="fx-fld wide"><span>Note (optional)</span>'
          + '<input type="text" id="fm-note" maxlength="500" value="'
          + h.esc(open.note || "") + '"></label>'
          + '</div>'

          + '<h3 style="margin-top:22px">Who we contact</h3>'
          + '<p class="fx-sub">Reminders go to one person per family. If there '
          + 'are two parents, add both and mark the one who deals with fees.</p>'
          + '<div id="fm-gs">' + gs.map(guardianRow).join("") + '</div>'
          + '<div class="fx-acts">'
          + '<button type="button" class="btn btn-ghost" id="fm-gadd">Add another contact</button>'
          + '</div>'

          + (open.id ? childrenBlock() : '')

          + '<div class="fx-acts" style="margin-top:22px">'
          + '<button type="button" class="btn btn-gold" id="fm-save">Save</button>'
          + '<button type="button" class="btn btn-ghost" id="fm-close">Close</button>'
          + (open.id && !h.list(open.pupils).length
              ? '<button type="button" class="fx-mini danger" id="fm-del" '
                + 'style="margin-left:auto">Remove this family</button>' : '')
          + '</div>'
          + '<div id="fm-delconfirm"></div>';

        wireEditor();
        bk.scrollIntoView({ block: "nearest" });
      }

      function guardianRow(g, i) {
        return '<div class="fx-form" data-g="' + i + '" style="margin-bottom:12px">'
          + '<label class="fx-fld"><span>Name</span>'
          + '<input type="text" class="g-name" maxlength="120" value="'
          + h.esc(g.full_name || "") + '"></label>'
          + '<label class="fx-fld"><span>Email</span>'
          + '<input type="email" class="g-email" maxlength="160" value="'
          + h.esc(g.email || "") + '"></label>'
          + '<label class="fx-fld"><span>Telephone</span>'
          + '<input type="text" class="g-phone" maxlength="24" value="'
          + h.esc(g.phone || "") + '"></label>'
          + '<label class="fx-fld" style="flex-direction:row;align-items:center;gap:8px">'
          + '<input type="radio" name="g-primary" class="g-primary" '
          + 'style="width:18px;height:18px"' + (g.is_primary ? " checked" : "") + '>'
          + '<span style="text-transform:none;letter-spacing:0">Send reminders here</span>'
          + '</label>'
          + '<input type="hidden" class="g-id" value="' + h.esc(g.id || "") + '">'
          + '</div>';
      }

      function childrenBlock() {
        var kids = h.list(open.pupils);
        return '<h3 style="margin-top:22px">Children in this family</h3>'
          + (kids.length
              ? '<div class="fx-tw"><table class="fx-t"><tbody>'
                + kids.map(function (k) {
                    return '<tr><td><strong>' + h.esc(k.name) + '</strong>'
                      + (k.left_on ? ' <span class="fx-flag">left '
                          + h.esc(h.shortDate(k.left_on)) + '</span>' : '')
                      + '</td><td class="num">'
                      + '<button type="button" class="fx-mini danger" data-out="'
                      + h.esc(k.id) + '">Take out</button></td></tr>';
                  }).join("")
                + '</tbody></table></div>'
                //  A child who has left still counts for the six-year money
                //  record but not for the sibling discount. Saying so here
                //  saves the office an argument about a bill.
                + (kids.filter(function (k) { return k.left_on; }).length
                    ? '<p class="fx-note">A child who has left is not charged and '
                      + 'does not count towards the sibling discount, but stays '
                      + 'on the record so the family&rsquo;s history adds up.</p>'
                    : '')
              : '<div class="fx-empty">Nobody yet. Add them from the list of '
                + 'children with no family above.</div>');
      }

      function wireEditor() {
        el("fm-gadd").addEventListener("click", function () {
          var n = el("fm-gs").querySelectorAll("[data-g]").length;
          el("fm-gs").insertAdjacentHTML("beforeend",
            guardianRow({ full_name: "", email: "", phone: "",
                          is_primary: n === 0 }, n));
        });

        el("fm-close").addEventListener("click", function () {
          open = null; drawEditor();
        });

        el("fm-save").addEventListener("click", function () {
          var btn = el("fm-save");
          h.note("fx-error", ""); h.note("fx-ok", "");
          var name = el("fm-name").value.trim();
          if (!name) {
            h.note("fx-error", "A family needs a name — usually the surname "
                 + "and the street.");
            return;
          }

          var gs = [];
          Array.prototype.forEach.call(
            el("fm-gs").querySelectorAll("[data-g]"), function (box) {
              var nm = box.querySelector(".g-name").value.trim();
              if (!nm) return;                 // an empty row is not a person
              gs.push({
                id:         box.querySelector(".g-id").value || null,
                full_name:  nm,
                email:      box.querySelector(".g-email").value.trim() || null,
                phone:      box.querySelector(".g-phone").value.trim() || null,
                is_primary: box.querySelector(".g-primary").checked
              });
            });

          h.busy(btn, true, "Save");
          sb.rpc("save_madrasah_household", { p: {
            id: open.id, name: name,
            note: el("fm-note").value.trim() || null,
            guardians: gs
          }}).then(function (res) {
            if (res.error) throw new Error(res.error.message);
            var ref = res.data.reference;
            h.note("fx-ok", "Saved. This family quotes " + ref + " when they pay.");
            return load().then(function () { return openFamily(res.data.id); });
          }).catch(function (e) {
            h.note("fx-error", "Nothing was saved — " + ((e && e.message) || String(e)));
          }).finally(function () { h.busy(btn, false, "Save"); });
        });

        Array.prototype.forEach.call(
          el("fm-editor").querySelectorAll("[data-out]"), function (b) {
            b.addEventListener("click", function () {
              h.busy(b, true, "Take out");
              sb.rpc("set_pupil_household", {
                p_pupil: b.getAttribute("data-out"), p_household: null
              }).then(function (res) {
                if (res.error) throw new Error(res.error.message);
                h.note("fx-ok", "Taken out of this family. They are now in the "
                     + "list of children with no family, and nobody is billed "
                     + "for them.");
                return load().then(function () { return openFamily(open.id); });
              }).catch(function (e) {
                h.note("fx-error", "Nothing was changed — "
                       + ((e && e.message) || String(e)));
                h.busy(b, false, "Take out");
              });
            });
          });

        var del = el("fm-del");
        if (del) del.addEventListener("click", function () {
          el("fm-delconfirm").innerHTML =
              '<div class="fx-confirm"><p>Remove <strong>' + h.esc(open.name)
            + '</strong>? It has no children in it. If any money has ever been '
            + 'recorded against it, the database will refuse &mdash; a financial '
            + 'record is on the charity&rsquo;s six-year clock, not this one.</p>'
            + '<div class="fx-acts">'
            + '<button type="button" class="btn btn-gold" id="fm-delyes">Yes, remove it</button>'
            + '<button type="button" class="btn btn-ghost" id="fm-delno">No</button>'
            + '</div></div>';
          el("fm-delyes").addEventListener("click", function () {
            var y = el("fm-delyes");
            h.busy(y, true, "Yes, remove it");
            sb.rpc("delete_madrasah_household", { p_id: open.id })
              .then(function (res) {
                if (res.error) throw new Error(res.error.message);
                open = null;
                h.note("fx-ok", "That family has been removed.");
                drawEditor();
                return load();
              }).catch(function (e) {
                h.note("fx-error", "Nothing was removed — "
                       + ((e && e.message) || String(e)));
                h.busy(y, false, "Yes, remove it");
              });
          });
          el("fm-delno").addEventListener("click", function () {
            el("fm-delconfirm").innerHTML = "";
          });
        });
      }

      el("fm-new").addEventListener("click", function () { openFamily(null); });
      el("fm-search").addEventListener("input", drawList);
      el("fm-psearch").addEventListener("input", drawUnhoused);

      load();
    }
  });
})();
