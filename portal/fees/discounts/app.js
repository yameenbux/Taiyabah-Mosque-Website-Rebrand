/* ===========================================================================
   portal/fees/discounts/app.js — the sibling rule, and fees written off.

   A DISCOUNT AND A WAIVER ARE DIFFERENT THINGS AND THIS SCREEN KEEPS THEM
   APART. A discount is the published rule applied — the second child pays
   less because that is the policy. A waiver is a decision about one family,
   usually hardship, taken by somebody who should be accountable for it.

   Both reduce the bill. Only one of them is a judgement, and "adjustment" is
   accountancy for both, which is why nav.js renamed this screen. Keeping the
   two in separate columns is what lets the annual report tell the trustees
   "£1,240 of discount and £680 written off" — a sentence they can act on —
   instead of one number nobody can question.
   =========================================================================== */
(function () {
  "use strict";

  FeesGate.start({
    key: "md-discounts",
    title: "Discounts & waivers",
    depth: 3,

    mount: function (identity, sb, h) {
      var el = h.el;
      var RULE = [];
      var picker = null;
      var openCharge = null;

      //  What goes in the box: pounds for a pence rule, the bare number for a
      //  percentage.
      function shown(r) {
        if (r.value === null || r.value === undefined || r.value === "") return "";
        if (r.kind !== "pence") return r.value;
        //  Already a pounds string the person is mid-way through typing.
        if (typeof r.value === "string" && /[.£]/.test(r.value)) return r.value;
        return FeesGate.pounds(r.value, { plain: true });
      }

      var KINDS = [
        { k: "percent", n: "% off" },
        { k: "pence",   n: "£ off" },
        { k: "free",    n: "free" }
      ];

      function load() {
        return Promise.all([
          sb.rpc("madrasah_fee_structure"),
          sb.rpc("madrasah_waivers")
        ]).then(function (out) {
          if (out[0].error) throw new Error(out[0].error.message);
          var d = out[0].data || {};
          var r = ((d.settings || {}).sibling_rule);
          RULE = Array.isArray(r) ? r : [];
          drawRule();
          //  The waiver list is not essential to the rule editor, so a
          //  failure there degrades rather than blanking the screen.
          if (out[1].error) {
            el("wv-list").innerHTML = '<div class="fx-empty">The list of '
              + 'write-offs could not be read.</div>';
          } else {
            drawWaivers(h.list(out[1].data));
          }
        }).catch(function (e) {
          h.note("fx-error", "This screen could not be read — "
                 + ((e && e.message) || String(e)));
        });
      }

      /* ------------------------------------------------ the rule -------- */
      function drawRule() {
        el("sd-rules").innerHTML = RULE.length
          ? '<div class="fx-tw"><table class="fx-t"><thead><tr>'
            + '<th>From this child onwards</th><th>They get</th>'
            + '<th class="num">How much</th><th></th></tr></thead><tbody>'
            + RULE.map(function (r, i) {
                return '<tr><td>'
                  + '<input type="number" min="2" max="12" value="' + h.esc(r.from || 2)
                  + '" data-from="' + i + '" style="width:80px;padding:8px;'
                  + 'border:1px solid var(--line);border-radius:8px;font:inherit"></td>'
                  + '<td><select data-kind="' + i + '" style="padding:8px;'
                  + 'border:1px solid var(--line);border-radius:8px;font:inherit">'
                  + KINDS.map(function (k) {
                      return '<option value="' + k.k + '"'
                           + (r.kind === k.k ? " selected" : "") + '>' + k.n + '</option>';
                    }).join("")
                  + '</select></td>'
                  + '<td class="num">'
                  + (r.kind === "free" ? '<span class="ref">the whole bill</span>'
                      //  A PENCE RULE IS STORED IN PENCE AND TYPED IN POUNDS,
                      //  so it has to be converted on the way IN as well as on
                      //  the way out. It was not: "2.50" saved as 250, came
                      //  back into a pounds-shaped box reading "250", and the
                      //  next save read that as £250 and stored 25000. One
                      //  more save and the clamp in madrasah_sibling_discount_p
                      //  made every sibling from position 2 free, silently, on
                      //  the next "Raise charges". A percentage round-trips
                      //  unharmed, which is why it went unnoticed.
                      : '<input type="text" value="' + h.esc(shown(r))
                        + '" data-value="' + i + '" inputmode="decimal" style="width:100px;'
                        + 'padding:8px;border:1px solid var(--line);border-radius:8px;'
                        + 'font:inherit;text-align:right">')
                  + '</td>'
                  + '<td class="num"><button type="button" class="fx-mini danger" '
                  + 'data-drop="' + i + '">Remove</button></td></tr>';
              }).join("")
            + '</tbody></table></div>'
          : '<div class="fx-empty">There is no sibling discount. Every child in '
            + 'a family pays the full rate.</div>';

        var host = el("sd-rules");
        Array.prototype.forEach.call(host.querySelectorAll("[data-from]"), function (n) {
          n.addEventListener("input", function () {
            RULE[+n.getAttribute("data-from")].from = parseInt(n.value, 10) || 2;
            example();
          });
        });
        Array.prototype.forEach.call(host.querySelectorAll("[data-kind]"), function (n) {
          n.addEventListener("change", function () {
            var i = +n.getAttribute("data-kind");
            //  25 means 25% under one kind and 25p under the other. Carrying
            //  the number across is the same £/pence confusion from the other
            //  direction, so the value is cleared with the scale.
            if (RULE[i].kind !== n.value) RULE[i].value = "";
            RULE[i].kind = n.value;
            drawRule();
          });
        });
        Array.prototype.forEach.call(host.querySelectorAll("[data-value]"), function (n) {
          n.addEventListener("input", function () {
            RULE[+n.getAttribute("data-value")].value = n.value;
            example();
          });
        });
        Array.prototype.forEach.call(host.querySelectorAll("[data-drop]"), function (b) {
          b.addEventListener("click", function () {
            RULE.splice(+b.getAttribute("data-drop"), 1);
            drawRule();
          });
        });
        example();
      }

      /*  WORKED THROUGH, IN POUNDS, ON A FAMILY OF FOUR.
          A rule expressed as "from 2, percent, 25" is not something anybody
          can check by reading. The same rule shown as four amounts is. */
      /*  ONE PLACE THAT APPLIES THE RULE, USED BY BOTH THE LINES AND THE
          TOTAL. They were two copies of the same fifteen lines, which is how
          a screen comes to show a per-child figure that does not sum to its
          own total. */
      function afterRule(base, rank) {
        var off = 0;
        var sorted = RULE.slice().sort(function (a, b) {
          return (parseInt(a.from, 10) || 999) - (parseInt(b.from, 10) || 999);
        });
        sorted.forEach(function (r) {
          if ((parseInt(r.from, 10) || 999) > rank) return;
          if (r.kind === "free") { off = base; return; }
          if (r.kind === "percent") {
            var pc = Math.min(Math.max(parseFloat(r.value) || 0, 0), 100);
            off = Math.round(base * pc / 100);
            return;
          }
          off = Math.min(Math.max(FeesGate.pence(shown(r)) || 0, 0), base);
        });
        return base - off;
      }

      /*  WORKED THROUGH, IN POUNDS, ON A FAMILY OF FOUR.
          A rule written as "from 2, percent, 25" is not something anybody can
          check by reading. The same rule shown as four amounts is. */
      function example() {
        var base = 13000;                       // 13 weeks at £10
        var lines = [], total = 0;
        [1, 2, 3, 4].forEach(function (rank) {
          var due = afterRule(base, rank);
          total += due;
          lines.push("child " + rank + " " + h.pounds(due));
        });
        el("sd-example").textContent =
          "A family of four, on a 13-week term at £10 a week, would pay: "
          + lines.join(", ") + " — " + h.pounds(total) + " in total "
          + "(" + h.pounds(base * 4) + " without the discount).";
      }

      el("sd-add").addEventListener("click", function () {
        var next = RULE.length
          ? Math.max.apply(null, RULE.map(function (r) {
              return parseInt(r.from, 10) || 2; })) + 1
          : 2;
        RULE.push({ from: Math.min(next, 12), kind: "percent", value: 25 });
        drawRule();
      });

      el("sd-save").addEventListener("click", function () {
        var btn = el("sd-save");
        h.note("fx-error", ""); h.note("fx-ok", "");

        //  Normalised here so the database never has to guess what a screen
        //  meant. percent is a number 0-100, pence is whole pence, free
        //  carries no value at all.
        var clean = [];
        for (var i = 0; i < RULE.length; i++) {
          var r = RULE[i];
          var from = parseInt(r.from, 10);
          if (!from || from < 2 || from > 12) {
            h.note("fx-error", "A position has to be a child number between 2 and 12. "
                 + "The first child always pays in full.");
            return;
          }
          if (r.kind === "free") { clean.push({ from: from, kind: "free" }); continue; }
          if (r.kind === "percent") {
            var pc = parseFloat(r.value);
            if (!isFinite(pc) || pc < 0 || pc > 100) {
              h.note("fx-error", "A percentage has to be between 0 and 100."); return;
            }
            clean.push({ from: from, kind: "percent", value: pc }); continue;
          }
          var p = FeesGate.pence(shown(r));
          if (p === null || p < 0) {
            h.note("fx-error", "Type an amount off, like 2.50."); return;
          }
          clean.push({ from: from, kind: "pence", value: p });
        }

        //  Sorted by position before it is stored. madrasah_sibling_discount_p
        //  applies the highest `from` that still matches, and sorting here
        //  means the list the office reads back is in the order it is applied.
        clean.sort(function (a, b) { return a.from - b.from; });

        h.busy(btn, true, "Save the rule");
        sb.rpc("save_madrasah_fee_setting", {
          p_key: "sibling_rule", p_value: clean
        }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          h.note("fx-ok", clean.length
            ? "Saved. It applies the next time charges are raised — bills "
              + "already sent out do not change."
            : "The sibling discount is off. Every child pays the full rate "
              + "from the next time charges are raised.");
          return load();
        }).catch(function (e) {
          h.note("fx-error", "Nothing was saved — " + ((e && e.message) || String(e)));
        }).finally(function () { h.busy(btn, false, "Save the rule"); });
      });

      /* ---------------------------------------------- waive a fee -------- */
      picker = h.familyPicker({
        input: "wv-family", results: "wv-results",
        onPick: function (fam) {
          openCharge = null;
          if (!fam) { el("wv-charges").innerHTML = ""; return; }
          el("wv-charges").innerHTML = '<p class="fx-none">Reading…</p>';
          sb.rpc("madrasah_household_statement", { p_household: fam.id })
            .then(function (res) {
              if (res.error) throw new Error(res.error.message);
              drawCharges(res.data || {});
            }).catch(function (e) {
              el("wv-charges").innerHTML = '<div class="fx-empty">That family&rsquo;s '
                + 'charges could not be read — ' + h.esc((e && e.message) || String(e))
                + '</div>';
            });
        }
      });

      function drawCharges(d) {
        var rows = h.list(d.charges);
        if (!rows.length) {
          el("wv-charges").innerHTML = '<div class="fx-empty">'
            + 'This family has no charges against them yet.</div>';
          return;
        }
        el("wv-charges").innerHTML =
            '<div class="fx-tw"><table class="fx-t"><thead><tr>'
          + '<th>Charge</th><th>Raised</th><th class="num">Bill</th>'
          + '<th class="num">Discount</th><th class="num">Written off</th>'
          + '<th class="num">Still due</th><th></th></tr></thead><tbody>'
          + rows.map(function (c) {
              return '<tr><td>' + h.esc(c.description) + '</td>'
                + '<td>' + h.esc(h.shortDate(c.charged_on)) + '</td>'
                + '<td class="num">' + h.esc(h.pounds(c.gross_p)) + '</td>'
                + '<td class="num">' + h.esc(c.discount_p ? h.pounds(c.discount_p) : "—") + '</td>'
                + '<td class="num">' + h.esc(c.waived_p ? h.pounds(c.waived_p) : "—") + '</td>'
                + '<td class="num"><strong>' + h.esc(h.pounds(c.net_p)) + '</strong></td>'
                + '<td class="num"><button type="button" class="fx-mini" data-wv="'
                + h.esc(c.id) + '">Waive</button></td></tr>'
                + (openCharge === c.id ? waiveForm(c) : '');
            }).join("")
          + '</tbody></table></div>';

        Array.prototype.forEach.call(
          el("wv-charges").querySelectorAll("[data-wv]"), function (b) {
            b.addEventListener("click", function () {
              openCharge = openCharge === b.getAttribute("data-wv")
                ? null : b.getAttribute("data-wv");
              drawCharges(d);
            });
          });

        var save = el("wv-charges").querySelector("[data-wvsave]");
        if (save) save.addEventListener("click", function () {
          var id = save.getAttribute("data-wvsave");
          var c = rows.filter(function (x) { return x.id === id; })[0];
          var amt = FeesGate.pence(el("wv-amount").value);
          var why = el("wv-why").value.trim();
          h.note("fx-error", ""); h.note("fx-ok", "");

          if (amt === null || amt < 0) {
            h.note("fx-error", "Type how much is being written off."); return;
          }
          if (amt > 0 && !why) {
            h.note("fx-error", "Say why. It goes to the trustees in the annual "
                 + "report, and an unexplained line there is one somebody has "
                 + "to reconstruct from memory a year later.");
            return;
          }
          if (amt + Number(c.discount_p || 0) > Number(c.gross_p)) {
            h.note("fx-error", "That is more than the bill. " + h.pounds(c.gross_p)
                 + " was charged and " + h.pounds(c.discount_p) + " is already "
                 + "discounted, so at most " + h.pounds(c.gross_p - c.discount_p)
                 + " can be written off.");
            return;
          }

          h.busy(save, true, "Write it off");
          //  Only the waiver fields are sent. The discount and its note are
          //  left out on purpose, and 070 treats an absent key as "leave it
          //  alone" — it did not, and every write-off wiped "Sibling discount"
          //  off the charge, leaving an unexplained discount in the report.
          sb.rpc("adjust_madrasah_charge", { p: {
            id: id, waived_p: amt, waiver_note: why || null
          }}).then(function (res) {
            if (res.error) throw new Error(res.error.message);
            openCharge = null;
            h.note("fx-ok", amt
              ? h.pounds(amt) + " written off. It is itemised in the annual report."
              : "The write-off has been removed and the full bill is due again.");
            var fam = picker.chosen();
            return load().then(function () {
              if (fam) return sb.rpc("madrasah_household_statement",
                                     { p_household: fam.id })
                .then(function (r2) { if (!r2.error) drawCharges(r2.data || {}); });
            });
          }).catch(function (e) {
            h.note("fx-error", "Nothing was changed — " + ((e && e.message) || String(e)));
            h.busy(save, false, "Write it off");
          });
        });
        var cancel = el("wv-charges").querySelector("[data-wvcancel]");
        if (cancel) cancel.addEventListener("click", function () {
          openCharge = null; drawCharges(d);
        });
      }

      function waiveForm(c) {
        return '<tr><td colspan="7"><div class="fx-confirm">'
          + '<p>Writing off part of <strong>' + h.esc(c.description) + '</strong>. '
          + 'The bill is ' + h.esc(h.pounds(c.gross_p))
          + (c.discount_p ? ', with ' + h.esc(h.pounds(c.discount_p))
                            + ' already discounted' : '')
          + '.</p>'
          + '<div class="fx-form">'
          + '<label class="fx-fld"><span>Amount to write off</span>'
          + '<input type="text" id="wv-amount" inputmode="decimal" value="'
          + h.esc(c.waived_p ? h.pounds(c.waived_p, { plain: true }) : "")
          + '" placeholder="0.00">'
          + '<span class="hint">Set it to 0 to put the full bill back.</span></label>'
          + '<label class="fx-fld wide"><span>Why</span>'
          + '<input type="text" id="wv-why" maxlength="300" value="'
          + h.esc(c.waiver_note || "")
          + '" placeholder="Hardship — agreed by trustees 12 September"></label>'
          + '</div>'
          + '<div class="fx-acts">'
          + '<button type="button" class="btn btn-gold" data-wvsave="' + h.esc(c.id)
          + '">Write it off</button>'
          + '<button type="button" class="btn btn-ghost" data-wvcancel="1">Cancel</button>'
          + '</div></div></td></tr>';
      }

      function drawWaivers(rows) {
        var total = rows.reduce(function (a, r) { return a + Number(r.waived_p || 0); }, 0);
        el("wv-list").innerHTML = rows.length
          ? '<div class="fx-tw"><table class="fx-t"><thead><tr>'
            + '<th>Family</th><th>Charge</th><th>Why</th><th>Raised</th>'
            + '<th class="num">Written off</th></tr></thead><tbody>'
            + rows.map(function (r) {
                return '<tr><td>' + h.esc(r.family)
                  + ' <span class="ref">' + h.esc(r.reference) + '</span></td>'
                  + '<td>' + h.esc(r.description) + '</td>'
                  + '<td>' + h.esc(r.why || "—") + '</td>'
                  + '<td>' + h.esc(h.shortDate(r.charged_on)) + '</td>'
                  + '<td class="num">' + h.esc(h.pounds(r.waived_p)) + '</td></tr>';
              }).join("")
            + '</tbody><tfoot><tr><td colspan="4">Total written off</td>'
            + '<td class="num">' + h.esc(h.pounds(total)) + '</td></tr></tfoot>'
            + '</table></div>'
          : '<div class="fx-empty">Nothing has been written off.</div>';
      }

      load();
    }
  });
})();
