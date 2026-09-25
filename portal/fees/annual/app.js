/* ===========================================================================
   portal/fees/annual/app.js — the report the trustees are shown.

   TWO HONESTIES ARE BUILT INTO THIS SCREEN AND BOTH MATTER MORE THAN THEY
   LOOK.

   1. CHARGED AND RECEIVED ARE COUNTED ON DIFFERENT DATES. A charge belongs
      to the day it was raised; a payment to the day the money arrived. The
      two will not match and the screen says so in as many words, because a
      report that quietly implies they should is one a treasurer spends an
      evening trying to reconcile before ringing somebody.

   2. OUTSTANDING IS AS AT TODAY, NOT AS AT THE END OF THE RANGE. This system
      does not keep the history a point-in-time balance would need, and a
      figure labelled as something it is not is worse than an absent one. The
      tile says "today" on it rather than taking the date range's word.

   It also prints. A fee report is taken to a trustees' meeting on paper, and
   fees.css hides the rail and every button when it goes.
   =========================================================================== */
(function () {
  "use strict";

  FeesGate.start({
    key: "md-fees-year",
    title: "Annual report",
    depth: 3,

    mount: function (identity, sb, h) {
      var el = h.el;
      var D = null;

      /*  DEFAULTS TO THE CHARITY YEAR, NOT THE CALENDAR ONE... except that
          nobody has told this system when the masjid's financial year ends,
          so it defaults to the academic year instead — 1 September to today —
          which is the one the madrasah actually runs on. Changeable in two
          clicks, and stated on screen so nobody assumes it is the other. */
      var now = new Date();
      var startYear = now.getMonth() >= 8 ? now.getFullYear() : now.getFullYear() - 1;
      el("an-from").value = startYear + "-09-01";
      el("an-to").value   = h.today();

      function load() {
        h.note("fx-error", "");
        var from = el("an-from").value || null;
        var to   = el("an-to").value || null;
        if (from && to && to < from) {
          h.note("fx-error", "The end of the period is before the start of it.");
          return Promise.resolve();
        }
        return sb.rpc("madrasah_fee_annual_report", { p_from: from, p_to: to })
          .then(function (res) {
            if (res.error) throw new Error(res.error.message);
            D = res.data || {};
            draw();
          }).catch(function (e) {
            h.note("fx-error", "The report could not be read — "
                   + ((e && e.message) || String(e)));
          });
      }

      function fig(cls, n, k, s) {
        return '<div class="fx-fig ' + cls + '">'
             + '<span class="n">' + h.esc(n) + '</span>'
             + '<span class="k">' + h.esc(k) + '</span>'
             + (s ? '<span class="s">' + h.esc(s) + '</span>' : '')
             + '</div>';
      }

      function draw() {
        el("an-when").textContent =
          h.shortDate(D.from) + " to " + h.shortDate(D.to);

        var gross = Number(D.gross_p || 0);
        var given = Number(D.discount_p || 0) + Number(D.waived_p || 0);

        el("an-figs").innerHTML =
            fig("", h.pounds(D.charged_p), "Charged",
                "after " + h.pounds(given) + " of discount and write-off")
          + fig("good", h.pounds(D.received_p), "Received",
                Number(D.refunded_p)
                  ? h.pounds(D.refunded_p) + " refunded out again"
                  : "nothing refunded")
          + fig(Number(D.outstanding_now_p) > 0 ? "owe" : "good",
                h.pounds(D.outstanding_now_p), "Outstanding today",
                "not as at " + h.shortDate(D.to) + " — see the note below")
          + fig(Number(D.waived_p) ? "" : "quiet", h.pounds(D.waived_p),
                "Written off",
                gross ? Math.round(Number(D.waived_p) / gross * 100) + "% of what was charged"
                      : "nothing was charged");

        periods();
        methods();
        waivers();
      }

      function periods() {
        var rows = h.list(D.by_period);
        el("an-periods").innerHTML = rows.length
          ? '<div class="fx-tw"><table class="fx-t"><thead><tr>'
            + '<th>Term</th><th>From</th><th class="num">Weeks</th>'
            + '<th class="num">Bills</th><th class="num">Full price</th>'
            + '<th class="num">Discount</th><th class="num">Written off</th>'
            + '<th class="num">Charged</th></tr></thead><tbody>'
            + rows.map(function (p) {
                return '<tr><td><strong>' + h.esc(p.name) + '</strong></td>'
                  + '<td>' + h.esc(h.shortDate(p.starts_on)) + '</td>'
                  + '<td class="num">' + h.esc(p.weeks) + '</td>'
                  + '<td class="num">' + h.esc(p.pupils) + '</td>'
                  + '<td class="num">' + h.esc(h.pounds(p.gross_p)) + '</td>'
                  + '<td class="num">' + h.esc(p.discount_p ? h.pounds(p.discount_p) : "—") + '</td>'
                  + '<td class="num">' + h.esc(p.waived_p ? h.pounds(p.waived_p) : "—") + '</td>'
                  + '<td class="num"><strong>' + h.esc(h.pounds(p.charged_p)) + '</strong></td>'
                  + '</tr>';
              }).join("")
            + '</tbody><tfoot><tr><td colspan="4">Total</td>'
            + '<td class="num">' + h.esc(h.pounds(D.gross_p)) + '</td>'
            + '<td class="num">' + h.esc(h.pounds(D.discount_p)) + '</td>'
            + '<td class="num">' + h.esc(h.pounds(D.waived_p)) + '</td>'
            + '<td class="num">' + h.esc(h.pounds(D.charged_p)) + '</td>'
            + '</tr></tfoot></table></div>'
          : '<div class="fx-empty">No term overlaps this period.</div>';
      }

      function methods() {
        var rows = h.list(D.by_method);
        var NAME = { bank: "Bank transfer", card: "Card (Stripe)",
                     cash: "Cash in the office", other: "Something else" };
        var total = rows.reduce(function (a, r) { return a + Number(r.amount_p || 0); }, 0);

        el("an-methods").innerHTML = rows.length
          ? '<div class="fx-tw"><table class="fx-t"><thead><tr>'
            + '<th>How</th><th class="num">Receipts</th><th class="num">Amount</th>'
            + '<th class="num">Share</th></tr></thead><tbody>'
            + rows.map(function (r) {
                return '<tr><td>' + h.esc(NAME[r.method] || r.method) + '</td>'
                  + '<td class="num">' + h.esc(r.count) + '</td>'
                  + '<td class="num">' + h.esc(h.pounds(r.amount_p)) + '</td>'
                  + '<td class="num ref">'
                  + (total ? Math.round(Number(r.amount_p) / total * 100) + "%" : "—")
                  + '</td></tr>';
              }).join("")
            + '</tbody></table></div>'
            //  Refunds are in this table as negatives, because they are
            //  payments with a minus sign. Saying so stops somebody reading
            //  the total as gross income.
            + '<p class="fx-note">Refunds appear here as negative amounts '
            + 'against the way the money went back, so this total is net.</p>'
          : '<div class="fx-empty">No money was received in this period.</div>';
      }

      function waivers() {
        var rows = h.list(D.waivers);
        el("an-waivers").innerHTML = rows.length
          ? '<div class="fx-tw"><table class="fx-t"><thead><tr>'
            + '<th>Family</th><th>Why</th><th>Raised</th>'
            + '<th class="num">Written off</th></tr></thead><tbody>'
            + rows.map(function (r) {
                return '<tr><td>' + h.esc(r.family) + ' <span class="ref">'
                  + h.esc(r.reference) + '</span></td>'
                  + '<td>' + h.esc(r.why || "—") + '</td>'
                  + '<td>' + h.esc(h.shortDate(r.charged_on)) + '</td>'
                  + '<td class="num">' + h.esc(h.pounds(r.waived_p)) + '</td></tr>';
              }).join("")
            + '</tbody><tfoot><tr><td colspan="3">Total written off</td>'
            + '<td class="num">' + h.esc(h.pounds(D.waived_p)) + '</td>'
            + '</tr></tfoot></table></div>'
          : '<div class="fx-empty">Nothing was written off in this period.</div>';
      }

      function csv() {
        if (!D) return;
        var rows = [];
        rows.push(["Taiyabah Masjid — madrasah fees",
                   h.shortDate(D.from) + " to " + h.shortDate(D.to)]);
        rows.push([]);
        rows.push(["Summary", "£"]);
        rows.push(["Charged at full price", h.pounds(D.gross_p, { plain: true })]);
        rows.push(["Sibling and other discount", h.pounds(D.discount_p, { plain: true })]);
        rows.push(["Written off", h.pounds(D.waived_p, { plain: true })]);
        rows.push(["Charged, net", h.pounds(D.charged_p, { plain: true })]);
        rows.push(["Received", h.pounds(D.received_p, { plain: true })]);
        rows.push(["Refunded", h.pounds(D.refunded_p, { plain: true })]);
        rows.push(["Outstanding today (not as at the end date)",
                   h.pounds(D.outstanding_now_p, { plain: true })]);
        rows.push([]);
        rows.push(["By term", "From", "Weeks", "Bills", "Full price",
                   "Discount", "Written off", "Charged"]);
        h.list(D.by_period).forEach(function (p) {
          rows.push([p.name, p.starts_on, p.weeks, p.pupils,
                     h.pounds(p.gross_p, { plain: true }),
                     h.pounds(p.discount_p, { plain: true }),
                     h.pounds(p.waived_p, { plain: true }),
                     h.pounds(p.charged_p, { plain: true })]);
        });
        rows.push([]);
        rows.push(["How the money came in", "Receipts", "Amount"]);
        h.list(D.by_method).forEach(function (m) {
          rows.push([m.method, m.count, h.pounds(m.amount_p, { plain: true })]);
        });
        rows.push([]);
        rows.push(["Fees written off", "Reference", "Why", "Raised", "Amount"]);
        h.list(D.waivers).forEach(function (w) {
          rows.push([w.family, w.reference, w.why || "", w.charged_on,
                     h.pounds(w.waived_p, { plain: true })]);
        });

        h.downloadCsv("taiyabah-madrasah-fees-" + D.from + "-to-" + D.to + ".csv",
                      ["Taiyabah Masjid"], rows);
      }

      el("an-go").addEventListener("click", load);
      el("an-csv").addEventListener("click", csv);
      el("an-print").addEventListener("click", function () { window.print(); });
      ["an-from", "an-to"].forEach(function (id) {
        el(id).addEventListener("change", load);
      });

      load();
    }
  });
})();
