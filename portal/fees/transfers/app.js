/* ===========================================================================
   portal/fees/transfers/app.js — where money is recorded.

   THE REAL DAILY JOB OF THIS SECTION. A bank statement arrives with thirty
   lines on it and somebody has to turn them into rows against families.

   Two decisions worth knowing before changing anything here:

   1. CARD PAYMENTS ARE ENTERED HERE TOO, by hand. Migration 070's header has
      the argument in full: a madrasah fee reference is typed by a parent from
      memory, monthly, for a year, and it WILL be typed wrong. Auto-posting a
      Stripe payment on a mistyped reference credits the wrong family, and the
      family who actually paid keeps getting reminders while somebody else's
      balance quietly clears. Nothing on any screen would say so.

   2. THE BALANCE IS SHOWN BEFORE THE AMOUNT IS TYPED. The commonest error on
      a screen like this is the right money against the wrong family, and the
      thing that catches it is seeing "owes £227.50" under a name that should
      be owing about that.
   =========================================================================== */
(function () {
  "use strict";

  FeesGate.start({
    key: "md-transfers",
    title: "Bank transfers",
    depth: 3,

    mount: function (identity, sb, h) {
      var el = h.el;
      var ROWS = [];
      var picker = null;
      var removing = null;
      var saving = false;

      el("tr-date").value = h.today();

      var offered = null;      // the reference this screen last filled in

      picker = h.familyPicker({
        input: "tr-family", results: "tr-results",
        onPick: function (fam) {
          var line = el("tr-balance");
          if (!fam) { line.innerHTML = "&nbsp;"; return; }
          line.textContent = "Checking…";
          sb.rpc("madrasah_household_statement", { p_household: fam.id })
            .then(function (res) {
              if (res.error) throw new Error(res.error.message);
              var d = res.data || {};
              var bal = Number(d.charged_p || 0) - Number(d.paid_p || 0);
              line.textContent = bal > 0
                ? "This family owes " + h.pounds(bal) + "."
                : (bal < 0
                    ? "This family is " + h.pounds(-bal) + " in credit."
                    : "This family owes nothing.");
              //  Offer the family's own reference, which is what is on the
              //  statement nine times in ten. Offered, not forced: what the
              //  bank actually said is the thing that has to be recorded.
              //
              //  It is replaced when it still holds ANOTHER family's offered
              //  reference. Picking MF-0001, changing your mind and picking
              //  MF-0042 used to record the payment against MF-0042 carrying
              //  bank_reference 'MF-0001' — and that string is the one thing
              //  the ledger relies on to tie a row back to the statement.
              //  Anything typed by hand is left exactly as typed.
              var ref = el("tr-ref");
              if (!ref.value.trim() || ref.value.trim() === offered) {
                ref.value = fam.reference;
              }
              offered = fam.reference;
            }).catch(function () {
              line.textContent = "That family's balance could not be read.";
            });
        }
      });

      function clear() {
        offered = null;
        picker.clear();
        ["tr-amount", "tr-ref", "tr-note"].forEach(function (id) { el(id).value = ""; });
        el("tr-date").value = h.today();
        el("tr-method").value = "bank";
        el("tr-balance").innerHTML = "&nbsp;";
        h.note("fx-error", "");
      }

      function save() {
        var btn = el("tr-save");
        //  A RE-ENTRY GUARD, NOT JUST A DISABLED BUTTON.
        //  Enter in the amount box also calls this, and disabling the button
        //  does nothing about a second Enter — or about key auto-repeat —
        //  while the round trip is in flight. Two identical madrasah_payments
        //  rows is the result, and nothing in the database refuses them,
        //  because two genuine £40 transfers on one day from one family is a
        //  real thing. 070's own header names money entered twice as the
        //  commonest mistake on this screen; this is where it would happen.
        if (saving) return;
        h.note("fx-error", ""); h.note("fx-ok", "");

        var fam = picker.chosen();
        if (!fam) {
          h.note("fx-error", "Pick the family this money belongs to first. "
               + "Nothing is recorded until it has somewhere to go.");
          return;
        }
        var amt = h.pence(el("tr-amount").value);
        if (amt === null || amt <= 0) {
          h.note("fx-error", "Type the amount that arrived, like 40 or 37.50.");
          return;
        }

        saving = true;
        h.busy(btn, true, "Record it");
        sb.rpc("record_madrasah_payment", {
          p: {
            household_id:   fam.id,
            amount_p:       amt,
            kind:           "payment",
            method:         el("tr-method").value,
            received_on:    el("tr-date").value || null,
            bank_reference: el("tr-ref").value.trim() || null,
            note:           el("tr-note").value.trim() || null
          }
        }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var was = fam.name;
          clear();
          h.note("fx-ok", h.pounds(amt) + " recorded against " + was + ".");
          return load();
        }).catch(function (e) {
          //  The error says what did NOT happen, first. House rule from
          //  classes/app.js: "Nothing was saved — ".
          h.note("fx-error", "Nothing was recorded — "
                 + ((e && e.message) || String(e)));
        }).finally(function () {
          saving = false;
          h.busy(btn, false, "Record it");
        });
      }

      function load() {
        return sb.rpc("madrasah_recent_payments", { p_limit: 50, p_kind: null })
          .then(function (res) {
            if (res.error) throw new Error(res.error.message);
            ROWS = h.list(res.data);
            drawList();
          })
          .catch(function (e) {
            h.note("fx-error", "The recent receipts could not be read — "
                   + ((e && e.message) || String(e)));
          });
      }

      function method(m) {
        return { bank: "Bank transfer", card: "Card", cash: "Cash",
                 other: "Other" }[m] || m;
      }

      function drawList() {
        var q = el("tr-search").value.trim().toLowerCase();
        var rows = ROWS.filter(function (r) {
          if (!q) return true;
          return (r.family || "").toLowerCase().indexOf(q) !== -1
              || (r.reference || "").toLowerCase().indexOf(q) !== -1
              || (r.bank_reference || "").toLowerCase().indexOf(q) !== -1;
        });

        el("tr-count").textContent = rows.length === ROWS.length
          ? ROWS.length + " receipt" + (ROWS.length === 1 ? "" : "s")
          : rows.length + " of " + ROWS.length;

        if (!rows.length) {
          el("tr-list").innerHTML = '<div class="fx-empty">'
            + (ROWS.length ? "Nothing matches that."
                           : "No money has been recorded yet.") + '</div>';
          return;
        }

        el("tr-list").innerHTML =
            '<div class="fx-tw"><table class="fx-t"><thead><tr>'
          + '<th>Received</th><th>Family</th><th>How</th>'
          + '<th>Reference on the statement</th>'
          + '<th class="num">Amount</th><th></th></tr></thead><tbody>'
          + rows.map(function (r) {
              return '<tr><td>' + h.esc(h.shortDate(r.received_on)) + '</td>'
                   + '<td>' + h.esc(r.family)
                   + ' <span class="ref">' + h.esc(r.reference) + '</span></td>'
                   + '<td>' + h.esc(method(r.method))
                   + (r.kind === "refund"
                       ? ' <span class="fx-flag warn">refund</span>' : '')
                   + '</td>'
                   + '<td class="ref">' + h.esc(r.bank_reference || "—") + '</td>'
                   + '<td class="num ' + (Number(r.amount_p) < 0 ? "owe" : "") + '">'
                   + h.esc(h.pounds(r.amount_p)) + '</td>'
                   + '<td class="num"><button type="button" class="fx-mini danger" '
                   + 'data-rm="' + h.esc(r.id) + '">Remove</button></td></tr>'
                   + confirmRow(r);
            }).join("")
          + '</tbody></table></div>';

        Array.prototype.forEach.call(
          el("tr-list").querySelectorAll("[data-rm]"), function (b) {
            b.addEventListener("click", function () {
              removing = (removing === b.getAttribute("data-rm"))
                ? null : b.getAttribute("data-rm");
              drawList();
            });
          });

        var yes = el("tr-list").querySelector("[data-rmyes]");
        if (yes) {
          yes.addEventListener("click", function () {
            var id = yes.getAttribute("data-rmyes");
            var why = (el("tr-why") && el("tr-why").value.trim()) || null;
            h.busy(yes, true, "Yes, remove it");
            sb.rpc("delete_madrasah_payment", { p_id: id, p_why: why })
              .then(function (res) {
                if (res.error) throw new Error(res.error.message);
                removing = null;
                h.note("fx-ok", "That receipt has been removed. The removal is "
                     + "in the audit with the amount against it.");
                return load();
              }).catch(function (e) {
                h.note("fx-error", "Nothing was removed — "
                       + ((e && e.message) || String(e)));
                h.busy(yes, false, "Yes, remove it");
              });
          });
        }
        var no = el("tr-list").querySelector("[data-rmno]");
        if (no) no.addEventListener("click", function () { removing = null; drawList(); });
      }

      /*  REMOVING MONEY ASKS WHY, AND THE ANSWER GOES IN THE AUDIT.
          Not to make it difficult: a receipt that disappears from a charity's
          records with no reason recorded is the thing an auditor asks about,
          and "I think it was a duplicate" a year later is not an answer. */
      function confirmRow(r) {
        if (removing !== r.id) return "";
        return '<tr><td colspan="6"><div class="fx-confirm">'
             + '<p>Remove <strong>' + h.esc(h.pounds(r.amount_p)) + '</strong> received from '
             + h.esc(r.family) + ' on ' + h.esc(h.shortDate(r.received_on)) + '? '
             + 'Their balance goes back up by that amount.</p>'
             + '<label class="fx-fld"><span>Why (goes in the audit)</span>'
             + '<input type="text" id="tr-why" maxlength="300" '
             + 'placeholder="Entered twice"></label>'
             + '<div class="fx-acts">'
             + '<button type="button" class="btn btn-gold" data-rmyes="'
             + h.esc(r.id) + '">Yes, remove it</button>'
             + '<button type="button" class="btn btn-ghost" data-rmno="1">No</button>'
             + '</div></div></td></tr>';
      }

      el("tr-save").addEventListener("click", save);
      el("tr-clear").addEventListener("click", clear);
      el("tr-search").addEventListener("input", drawList);
      el("tr-amount").addEventListener("keydown", function (e) {
        if (e.key === "Enter") save();
      });

      load();
    }
  });
})();
