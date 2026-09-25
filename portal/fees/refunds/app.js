/* ===========================================================================
   portal/fees/refunds/app.js — money going back to a family.

   A REFUND IS A PAYMENT WITH A MINUS SIGN. Migration 070 settled that: one
   table, one subtraction, one answer. A separate refunds table would mean
   every balance in the system is charges minus payments plus refunds, and
   the day somebody writes a report that forgets the third term is the day
   the trustees are handed a figure that is wrong in the masjid's favour.

   THIS SCREEN DOES NOT MOVE ANY MONEY. It records that the masjid has. The
   transfer or the Stripe refund happens first, in the bank or in Stripe, and
   this is where it is written down. Saying so on the screen matters: a
   button labelled "Refund £130" that only writes a row is a button somebody
   will press expecting a parent to be paid.
   =========================================================================== */
(function () {
  "use strict";

  FeesGate.start({
    key: "md-refunds",
    title: "Refunds",
    depth: 3,

    mount: function (identity, sb, h) {
      var el = h.el;
      var picker = null;
      var pendingRefund = null;

      el("rf-date").value = h.today();

      function load() {
        return Promise.all([
          sb.rpc("madrasah_fee_balances", { p_only_owing: false, p_q: null }),
          sb.rpc("madrasah_recent_payments", { p_limit: 50, p_kind: "refund" })
        ]).then(function (out) {
          if (out[0].error) throw new Error(out[0].error.message);
          drawCredit(h.list(out[0].data).filter(function (r) {
            return Number(r.balance_p) < 0;
          }));
          if (out[1].error) {
            el("rf-list").innerHTML = '<div class="fx-empty">The list of refunds '
              + 'could not be read.</div>';
          } else {
            drawList(h.list(out[1].data));
          }
        }).catch(function (e) {
          h.note("fx-error", "This screen could not be read — "
                 + ((e && e.message) || String(e)));
        });
      }

      function drawCredit(rows) {
        el("rf-credit").innerHTML = rows.length
          ? '<div class="fx-tw"><table class="fx-t"><thead><tr>'
            + '<th>Family</th><th>Children</th><th class="num">Charged</th>'
            + '<th class="num">Paid</th><th class="num">In credit</th><th></th>'
            + '</tr></thead><tbody>'
            + rows.map(function (r) {
                return '<tr><td><strong>' + h.esc(r.name) + '</strong> '
                  + '<span class="ref">' + h.esc(r.reference) + '</span></td>'
                  + '<td>' + h.esc(r.pupils) + '</td>'
                  + '<td class="num">' + h.esc(h.pounds(r.charged_p)) + '</td>'
                  + '<td class="num">' + h.esc(h.pounds(r.paid_p)) + '</td>'
                  + '<td class="num cr">' + h.esc(h.pounds(-r.balance_p)) + '</td>'
                  + '<td class="num"><button type="button" class="fx-mini" '
                  + 'data-ref="' + h.esc(r.id) + '" data-amt="' + h.esc(-r.balance_p)
                  + '" data-nm="' + h.esc(r.name) + '" data-rf="'
                  + h.esc(r.reference) + '">Refund this</button></td></tr>';
              }).join("")
            + '</tbody></table></div>'
          : '<div class="fx-empty">No family is in credit. Nobody has paid more '
            + 'than they have been charged.</div>';

        Array.prototype.forEach.call(
          el("rf-credit").querySelectorAll("[data-ref]"), function (b) {
            b.addEventListener("click", function () {
              //  ANY CHANGE OF FAMILY TEARS DOWN THE CONFIRMATION.
              //  Without this, an open "£130 has gone back to Khan" dialog
              //  survived a press on the Patel row: the dialog still named
              //  Khan, `picked` had become Patel, and "Yes, record it" posted
              //  Khan's amount against Patel's account. A confirmation that
              //  outlives the thing it is confirming is worse than none.
              el("rf-confirm").hidden = true;
              pendingRefund = null;
              h.note("fx-error", ""); h.note("fx-ok", "");
              //  Fill the form rather than refunding on the spot. The amount
              //  is a suggestion — a family leaving in November is often
              //  refunded part of what they are in credit for, not all.
              el("rf-family").value = b.getAttribute("data-nm")
                                    + "  (" + b.getAttribute("data-rf") + ")";
              el("rf-amount").value = h.pounds(b.getAttribute("data-amt"),
                                               { plain: true });
              el("rf-balance").textContent = "This family is "
                + h.pounds(b.getAttribute("data-amt")) + " in credit.";
              picked = { id: b.getAttribute("data-ref"),
                         name: b.getAttribute("data-nm"),
                         reference: b.getAttribute("data-rf") };
              el("rf-results").hidden = true;
              el("rf-amount").focus();
            });
          });
      }

      //  Either the picker chose it, or a "Refund this" button did.
      var picked = null;

      picker = h.familyPicker({
        input: "rf-family", results: "rf-results",
        onPick: function (fam) {
          picked = fam;
          pendingRefund = null;
          el("rf-confirm").hidden = true;
          var line = el("rf-balance");
          if (!fam) { line.innerHTML = "&nbsp;"; return; }
          line.textContent = "Checking…";
          sb.rpc("madrasah_household_statement", { p_household: fam.id })
            .then(function (res) {
              if (res.error) throw new Error(res.error.message);
              var d = res.data || {};
              var bal = Number(d.charged_p || 0) - Number(d.paid_p || 0);
              line.textContent = bal < 0
                ? "This family is " + h.pounds(-bal) + " in credit."
                : (bal > 0
                    ? "This family still OWES " + h.pounds(bal)
                      + ". Refunding them will increase what they owe."
                    : "This family owes nothing and is not in credit.");
            }).catch(function () {
              line.textContent = "That family's balance could not be read.";
            });
        }
      });

      function ask() {
        h.note("fx-error", ""); h.note("fx-ok", "");
        if (!picked) {
          h.note("fx-error", "Pick the family the money is going back to.");
          return;
        }
        var amt = h.pence(el("rf-amount").value);
        if (amt === null || amt <= 0) {
          h.note("fx-error", "Type how much is going back, like 130 or 97.50.");
          return;
        }
        if (!el("rf-note").value.trim()) {
          h.note("fx-error", "Say why the money is going back. A refund with no "
               + "reason recorded is the one an auditor asks about.");
          return;
        }
        pendingRefund = amt;
        //  Not blocked — a masjid does occasionally refund a family who still
        //  owes for a later term — but said plainly, because a mistyped
        //  £1,300 against a £13 credit puts a family £1,287 into debt and
        //  straight onto the Outstanding list.
        var credit = /is (£[\d,.]+) in credit/.exec(el("rf-balance").textContent);
        var over = credit && h.pence(credit[1]) !== null && amt > h.pence(credit[1]);

        /*  STATED AS A SENTENCE, NOT A FIGURE IN A BOX. Money leaving the
            masjid is the one thing on this site worth reading twice. */
        el("rf-confirm-t").innerHTML =
            'Record that <span class="fx-big">' + h.esc(h.pounds(amt))
          + '</span> has gone back to <strong>' + h.esc(picked.name) + '</strong>?'
          + (over
              ? '<br><strong>That is more than this family is in credit for.</strong> '
                + 'They will be shown as owing the difference.'
              : '')
          + '<br><span class="ref">This writes it down. It does not move the '
          + 'money — make the transfer, or refund it in Stripe, first.</span>';
        el("rf-confirm").hidden = false;
      }

      function save() {
        var btn = el("rf-yes");
        //  The confirmation was built from these two. If either has moved on
        //  since, nothing is posted — the screen has already been re-drawn
        //  under the person's hand and they are not agreeing to what they
        //  are looking at.
        if (!picked || !pendingRefund) {
          el("rf-confirm").hidden = true;
          h.note("fx-error", "That went stale — check the family and the "
               + "amount, then try again. Nothing was recorded.");
          return;
        }
        h.busy(btn, true, "Yes, record it");
        sb.rpc("record_madrasah_payment", { p: {
          household_id: picked.id,
          amount_p:     pendingRefund,
          kind:         "refund",
          method:       el("rf-method").value,
          received_on:  el("rf-date").value || null,
          note:         el("rf-note").value.trim()
        }}).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var was = picked.name, amt = pendingRefund;
          clear();
          h.note("fx-ok", h.pounds(amt) + " recorded as refunded to " + was + ".");
          return load();
        }).catch(function (e) {
          el("rf-confirm").hidden = true;
          h.note("fx-error", "Nothing was recorded — " + ((e && e.message) || String(e)));
        }).finally(function () { h.busy(btn, false, "Yes, record it"); });
      }

      function clear() {
        picker.clear();
        picked = null;
        pendingRefund = null;
        ["rf-amount", "rf-note"].forEach(function (id) { el(id).value = ""; });
        el("rf-date").value = h.today();
        el("rf-method").value = "bank";
        el("rf-balance").innerHTML = "&nbsp;";
        el("rf-confirm").hidden = true;
      }

      function method(m) {
        return { bank: "Bank transfer", card: "Card", cash: "Cash",
                 other: "Other" }[m] || m;
      }

      function drawList(rows) {
        var total = rows.reduce(function (a, r) {
          return a + Math.abs(Number(r.amount_p || 0)); }, 0);
        el("rf-list").innerHTML = rows.length
          ? '<div class="fx-tw"><table class="fx-t"><thead><tr>'
            + '<th>Date</th><th>Family</th><th>How</th><th>Why</th>'
            + '<th class="num">Amount</th></tr></thead><tbody>'
            + rows.map(function (r) {
                return '<tr><td>' + h.esc(h.shortDate(r.received_on)) + '</td>'
                  + '<td>' + h.esc(r.family) + ' <span class="ref">'
                  + h.esc(r.reference) + '</span></td>'
                  + '<td>' + h.esc(method(r.method)) + '</td>'
                  + '<td>' + h.esc(r.note || "—") + '</td>'
                  + '<td class="num">' + h.esc(h.pounds(Math.abs(r.amount_p))) + '</td></tr>';
              }).join("")
            + '</tbody><tfoot><tr><td colspan="4">Refunded in total</td>'
            + '<td class="num">' + h.esc(h.pounds(total)) + '</td></tr></tfoot>'
            + '</table></div>'
          : '<div class="fx-empty">Nothing has been refunded.</div>';
      }

      el("rf-save").addEventListener("click", ask);
      el("rf-yes").addEventListener("click", save);
      el("rf-no").addEventListener("click", function () {
        el("rf-confirm").hidden = true; pendingRefund = null;
      });
      el("rf-clear").addEventListener("click", clear);

      load();
    }
  });
})();
