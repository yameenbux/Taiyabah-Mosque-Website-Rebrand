/* ===========================================================================
   portal/fees/app.js — the Fees landing screen.

   ONE RULE SHAPES THIS SCREEN, AND IT CAME FROM MIGRATION 066:

       "A tile that reads '0 unpaid' when nothing collects fees is not
        neutral, it is wrong."

   On the day this ships, the madrasah has 543 children, no families, no
   terms and no charges. Every figure here would be zero, and a row of
   confident zeros tells the office that everybody has paid. So the screen
   asks the database what has and has not been set up, and until fees can
   actually be collected it leads with a list of what is missing instead of
   a row of noughts.
   =========================================================================== */
(function () {
  "use strict";

  FeesGate.start({
    key: "md-fees",
    title: "Fees",
    depth: 2,

    mount: function (identity, sb, h) {
      var el = h.el;

      function load() {
        return sb.rpc("madrasah_fees_overview").then(function (res) {
          if (res.error) throw new Error(res.error.message);
          draw(res.data || {});
        }).catch(function (e) {
          h.note("fx-error", "The fees overview could not be read — "
                 + ((e && e.message) || String(e)));
        });
      }

      /*  WHAT IS MISSING, IN THE ORDER IT HAS TO BE DONE.

          Each step links to the screen that does it. A list of problems with
          nowhere to go is a list somebody reads twice and then ignores. */
      function setup(d) {
        var steps = [
          { done: d.has_default_rate,
            what: 'Set what a week costs',
            why:  'Nothing can be charged until there is a default rate.',
            href: 'structure/' },
          { done: d.rates_confirmed,
            what: 'Confirm the figures are right',
            why:  'The rates came from the website and the office has never '
                 + 'confirmed them. Until somebody does, every screen that '
                 + 'uses them says so.',
            href: 'structure/' },
          { done: (d.families || 0) > 0,
            what: 'Put the children into families',
            why:  (d.pupils_no_family || 0) + ' of ' + (d.pupils || 0)
                 + ' children are not in a family yet, so they cannot be '
                 + 'billed and will be skipped when charges are raised.',
            href: 'families/' },
          { done: (d.periods || 0) > 0,
            what: 'Add a term and raise the charges',
            why:  'A term is a name, two dates and the number of weeks that '
                 + 'are actually charged.',
            href: 'structure/' },
          { done: d.has_bank_details,
            what: 'Say where parents send the money',
            why:  'It goes in every reminder. Without it a reminder tells a '
                 + 'parent they owe money and not how to pay it.',
            href: 'structure/' }
        ];

        var left = steps.filter(function (s) { return !s.done; });
        var box  = el("fx-setup");
        if (!left.length) { box.hidden = true; return false; }

        //  THE COUNT AND THE NUMBERING HAVE TO AGREE. It said "4 things are
        //  still to do" above a list numbered 1 to 5 with the first struck
        //  through — both true, and read together they look like an off-by-one
        //  on the screen that is supposed to be telling somebody what to do.
        //  The list stays numbered because the order is the point.
        el("fx-setup-lead").textContent =
          (left.length === 1 ? "One of these " : left.length + " of these ")
          + steps.length + " steps "
          + (left.length === 1 ? "is" : "are") + " still to do.";

        el("fx-setup-list").innerHTML = steps.map(function (s) {
          return '<li class="' + (s.done ? "done" : "") + '">'
               + (s.done ? h.esc(s.what)
                         : '<a href="' + s.href + '">' + h.esc(s.what) + '</a>')
               + (s.done ? "" : ' — ' + h.esc(s.why))
               + '</li>';
        }).join("");
        box.hidden = false;
        return true;
      }

      function fig(cls, n, k, s) {
        return '<div class="fx-fig ' + cls + '">'
             + '<span class="n">' + h.esc(n) + '</span>'
             + '<span class="k">' + h.esc(k) + '</span>'
             + (s ? '<span class="s">' + h.esc(s) + '</span>' : '')
             + '</div>';
      }

      function draw(d) {
        var incomplete = setup(d);
        var charged = Number(d.charged_total_p || 0);

        /*  IF NOTHING HAS BEEN CHARGED, SAY SO RATHER THAN SHOWING £0.00
            OUTSTANDING. The two look identical on a tile and mean opposite
            things — one is "everybody has paid", the other is "we have not
            asked anybody for anything". */
        if (charged === 0) {
          el("fx-figs").innerHTML =
              fig("quiet", (d.pupils || 0), "Children at the madrasah",
                  (d.pupils_no_family || 0) + " are not in a family yet")
            + fig("quiet", (d.families || 0), "Families on file",
                  (d.families_no_contact || 0) + " have no email address")
            + fig("quiet", "—", "Outstanding",
                  "Nothing has been charged yet, so nothing is owed")
            + fig("quiet", "—", "Received", "No money has been recorded");
        } else {
          el("fx-figs").innerHTML =
              fig(Number(d.outstanding_p) > 0 ? "owe" : "good",
                  h.pounds(d.outstanding_p), "Outstanding",
                  (d.families_owing || 0) + " famil"
                  + ((d.families_owing === 1) ? "y" : "ies"))
            + fig("good", h.pounds(d.received_30_days_p), "Received, last 30 days",
                  h.pounds(d.received_7_days_p) + " of it in the last week"
                  + (Number(d.refunded_30_days_p)
                      ? ", " + h.pounds(d.refunded_30_days_p) + " refunded out"
                      : ""))
            //  "of it" WAS WRONG. charged_total_p is sum(net_p), which has
            //  already had the write-offs taken out of it, so the waived
            //  figure is not part of the number above it. The annual report
            //  says "after …" and this said "of it"; two screens describing
            //  the same two figures in contradictory ways.
            + fig("", h.pounds(charged), "Charged in total",
                  "after " + h.pounds(d.waived_total_p) + " written off")
            + fig(Number(d.in_credit_p) > 0 ? "" : "quiet",
                  h.pounds(d.in_credit_p), "In credit",
                  Number(d.in_credit_p) > 0
                    ? "Families who have overpaid — see Refunds"
                    : "Nobody has overpaid");
        }

        /*  MONEY ARRIVING. Proof the section is working, on the screen
            somebody opens first. */
        var recent = h.list(d.recent);
        el("fx-recent").innerHTML = recent.length
          ? '<div class="fx-tw"><table class="fx-t">'
            + '<thead><tr><th>Date</th><th>Family</th><th>How</th>'
            + '<th class="num">Amount</th></tr></thead><tbody>'
            + recent.map(function (r) {
                return '<tr><td>' + h.esc(h.shortDate(r.received_on)) + '</td>'
                     + '<td>' + h.esc(r.family)
                     + ' <span class="ref">' + h.esc(r.reference) + '</span></td>'
                     + '<td>' + h.esc(method(r.method))
                     + (r.kind === "refund" ? ' <span class="fx-flag warn">refund</span>' : '')
                     + '</td>'
                     + '<td class="num ' + (Number(r.amount_p) < 0 ? "owe" : "") + '">'
                     + h.esc(h.pounds(r.amount_p)) + '</td></tr>';
              }).join("")
            + '</tbody></table></div>'
          : '<div class="fx-empty">Nothing has been recorded yet. '
            + 'Money goes in on <a href="transfers/">Bank transfers</a>.</div>';

        attention(d, incomplete);
      }

      function method(m) {
        return { bank: "Bank transfer", card: "Card", cash: "Cash",
                 other: "Other" }[m] || m;
      }

      /*  THINGS THAT COST MONEY IF NOBODY ACTS.
          Only shown when they are true, and each one links to the fix. An
          empty list is a good day, and says so. */
      function attention(d, incomplete) {
        var items = [];

        if (Number(d.pupils_no_family) > 0) {
          items.push({
            n: d.pupils_no_family,
            t: "children are not in a family",
            w: "They are skipped when charges are raised, so nobody is billed "
             + "for them. This is the one that costs the madrasah real money.",
            href: "families/", go: "Put them in families" });
        }
        if (Number(d.families_no_contact) > 0) {
          items.push({
            n: d.families_no_contact,
            t: "families have no email address",
            w: "They cannot be sent a reminder and have to be chased by "
             + "telephone or in person.",
            href: "owing/", go: "See who" });
        }
        if (Number(d.families_owing) > 0) {
          items.push({
            n: d.families_owing,
            t: "families owe money",
            w: h.pounds(d.outstanding_p) + " in total.",
            href: "owing/", go: "Chase it" });
        }
        if (d.open_period && d.open_period.status === "draft") {
          items.push({
            n: "",
            t: '"' + d.open_period.name + '" has not been charged yet',
            w: "The term exists but no bills have been raised against it.",
            href: "structure/", go: "Raise the charges" });
        }

        el("fx-attention").innerHTML = items.length
          ? '<div class="fx-tw"><table class="fx-t"><tbody>'
            + items.map(function (i) {
                return '<tr><td class="num" style="width:70px">'
                     + '<strong>' + h.esc(i.n) + '</strong></td>'
                     + '<td><strong>' + h.esc(i.t) + '</strong><br>'
                     + '<span class="ref">' + h.esc(i.w) + '</span></td>'
                     + '<td class="num"><a class="fx-mini" href="' + i.href + '">'
                     + h.esc(i.go) + '</a></td></tr>';
              }).join("")
            + '</tbody></table></div>'
          : (incomplete
              ? '<div class="fx-empty">Nothing to chase yet — finish the '
                + 'setting up above first.</div>'
              : '<div class="fx-empty">Nothing needs attention. Every child is '
                + 'in a family, every family has a contact, and nobody owes '
                + 'anything.</div>');
      }

      load();
    }
  });
})();
