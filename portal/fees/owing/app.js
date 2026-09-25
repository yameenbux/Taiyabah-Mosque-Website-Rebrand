/* ===========================================================================
   portal/fees/owing/app.js — outstanding, and the reminder button.

   THE ONE BUTTON ON THIS SITE THAT DOES SOMETHING THAT CANNOT BE TAKEN BACK.

   Three hundred emails leave in a few seconds and there is no recalling one.
   So this screen:

     * never sends on a single press — it says how many, to whom, and asks;
     * shows the list it is about to write to before it does it;
     * reports back what happened to every family, INCLUDING the ones it did
       not write to, because "I ticked 40 and 31 went" needs an answer for
       the other nine and the office should not have to work it out;
     * ticks nothing by default. A "select all" that is on when the screen
       loads is how somebody emails the whole madrasah by pressing the wrong
       thing first.

   The database enforces the rest — one reminder per family per seven days,
   nothing to a family that owes nothing, at most 120 at a time. Those live
   in Postgres and not here, because a rule that is only in the screen lasts
   until somebody calls the function directly.
   =========================================================================== */
(function () {
  "use strict";

  FeesGate.start({
    key: "md-outstanding",
    title: "Outstanding & reminders",
    depth: 3,

    mount: function (identity, sb, h) {
      var el = h.el;
      var ROWS = [];
      var picked = {};

      function load() {
        /*  RECONCILE FIRST, THEN READ.

            pg_cron runs the same function every five minutes, so this is not
            what makes it happen — it is what makes it happen BEFORE the
            office looks. Somebody who sends a batch and then watches this
            screen would otherwise see "waiting" for up to five minutes and
            conclude it was stuck.

            It degrades silently on purpose. If reconciling fails, the list is
            still worth showing; the outcomes will simply be a few minutes
            behind, which is what they were before this call existed. */
        return sb.rpc("reconcile_madrasah_fee_reminders")
          .catch(function () { /* the list is still worth drawing */ })
          .then(function () {
            return sb.rpc("madrasah_fee_balances", { p_only_owing: true, p_q: null });
          })
          .then(function (res) {
            if (res.error) throw new Error(res.error.message);
            ROWS = h.list(res.data);
            //  Anything ticked that is no longer owing is unticked, so a
            //  stale selection cannot survive a reload and send to somebody
            //  who paid in the meantime.
            var live = {};
            ROWS.forEach(function (r) { if (picked[r.id]) live[r.id] = true; });
            picked = live;
            draw();
          }).catch(function (e) {
            h.note("fx-error", "The outstanding list could not be read — "
                   + ((e && e.message) || String(e)));
          });
      }

      function visible() {
        var q = el("ow-search").value.trim().toLowerCase();
        var onlyEmail = el("ow-onlyemail").checked;
        return ROWS.filter(function (r) {
          if (onlyEmail && !r.can_email) return false;
          if (!q) return true;
          return (r.name || "").toLowerCase().indexOf(q) !== -1
              || (r.reference || "").toLowerCase().indexOf(q) !== -1;
        });
      }

      function figs() {
        var total = ROWS.reduce(function (a, r) { return a + Number(r.balance_p || 0); }, 0);
        var noMail = ROWS.filter(function (r) { return !r.can_email; }).length;
        //  A family whose last message FAILED counts as available, because
        //  the seven-day lock in the database does not count a failure. The
        //  tile and the button have to agree about who can be written to.
        var stale = ROWS.filter(function (r) {
          var d = h.daysAgo(r.last_reminded_at);
          return d === null || d >= 7;
        }).length;
        var broke = ROWS.filter(function (r) {
          return r.last_reminder && r.last_reminder.outcome === "failed";
        }).length;
        //  The control appears only when it has something to do. A button
        //  that is always there and usually does nothing is a button people
        //  stop reading.
        var againBtn = el("ow-again");
        if (againBtn) againBtn.hidden = broke === 0;

        el("ow-figs").innerHTML =
            '<div class="fx-fig owe"><span class="n">' + h.esc(h.pounds(total))
          + '</span><span class="k">Outstanding</span>'
          + '<span class="s">across ' + ROWS.length + ' famil'
          + (ROWS.length === 1 ? "y" : "ies") + '</span></div>'
          + '<div class="fx-fig"><span class="n">' + stale
          + '</span><span class="k">Can be reminded now</span>'
          + '<span class="s">not written to in the last week</span></div>'
          + '<div class="fx-fig ' + (noMail ? "owe" : "quiet") + '">'
          + '<span class="n">' + noMail
          + '</span><span class="k">No email address</span>'
          + '<span class="s">' + (noMail
              ? "have to be chased by telephone" : "everybody can be written to")
          + '</span></div>'
          + (broke
              ? '<div class="fx-fig owe"><span class="n">' + broke
                + '</span><span class="k">Last one did not go</span>'
                + '<span class="s">these can be sent again now</span></div>'
              : '');
      }

      function draw() {
        figs();
        var rows = visible();
        el("ow-count").textContent = rows.length === ROWS.length
          ? ROWS.length + " famil" + (ROWS.length === 1 ? "y" : "ies")
          : rows.length + " of " + ROWS.length;

        if (!ROWS.length) {
          el("ow-list").innerHTML = '<div class="fx-empty">'
            + 'Nobody owes anything. Either everybody has paid, or nothing has '
            + 'been charged yet &mdash; <a href="../structure/">check the terms</a> '
            + 'if that seems unlikely.</div>';
          el("ow-bar").hidden = true;
          return;
        }
        if (!rows.length) {
          el("ow-list").innerHTML = '<div class="fx-empty">Nothing matches that.</div>';
          //  bar() BEFORE THE RETURN. Without it the send bar kept whatever it
          //  last said, so a filter that matched nothing left "10 families
          //  selected" and a live Send button above the words "Nothing
          //  matches that".
          bar();
          return;
        }

        el("ow-list").innerHTML =
            '<div class="fx-tw"><table class="fx-t"><thead><tr>'
          + '<th class="fx-tickcell"><input type="checkbox" id="ow-all" '
          + 'aria-label="Select every family shown"></th>'
          + '<th>Family</th><th>Children</th><th>Last paid</th>'
          + '<th>Last reminded</th><th class="num">Charged</th>'
          + '<th class="num">Paid</th><th class="num">Owes</th>'
          + '</tr></thead><tbody>'
          + rows.map(row).join("")
          + '</tbody><tfoot><tr><td colspan="7">Total shown</td>'
          + '<td class="num owe">' + h.esc(h.pounds(rows.reduce(function (a, r) {
              return a + Number(r.balance_p || 0); }, 0))) + '</td>'
          + '</tr></tfoot></table></div>';

        Array.prototype.forEach.call(
          el("ow-list").querySelectorAll("[data-tick]"), function (b) {
            b.addEventListener("change", function () {
              var id = b.getAttribute("data-tick");
              if (b.checked) picked[id] = true; else delete picked[id];
              bar();
            });
          });

        //  The header tick is REBUILT by draw(), so its state has to be
        //  restored from the selection rather than left to the browser —
        //  otherwise pressing it ticks every row and then shows itself as
        //  unticked, which reads as "that did not work" and invites a second
        //  press.
        var tickable = visible().filter(function (r) { return r.can_email; });
        el("ow-all").checked = tickable.length > 0 && tickable.every(function (r) {
          return picked[r.id];
        });

        el("ow-all").addEventListener("change", function () {
          var on = el("ow-all").checked;
          //  Only what is on screen. A "select all" that silently includes
          //  rows a filter is hiding is how somebody emails a family they
          //  had deliberately filtered out.
          visible().forEach(function (r) {
            if (on && r.can_email) picked[r.id] = true; else delete picked[r.id];
          });
          draw();
        });

        bar();
      }

      function row(r) {
        var days = h.daysAgo(r.last_reminded_at);
        var soon = days !== null && days < 7;
        var last = r.last_reminder || null;
        return '<tr>'
          + '<td class="fx-tickcell">'
          + (r.can_email
              ? '<input type="checkbox" data-tick="' + h.esc(r.id) + '"'
                + (picked[r.id] ? " checked" : "")
                + ' aria-label="Remind ' + h.esc(r.name) + '">'
              : '')
          + '</td>'
          + '<td><strong>' + h.esc(r.name) + '</strong> '
          + '<span class="ref">' + h.esc(r.reference) + '</span>'
          + (r.can_email ? '' : ' <span class="fx-flag warn">no email</span>')
          + (soon ? ' <span class="fx-flag">reminded ' + days + 'd ago</span>' : '')
          //  A FAMILY WHOSE LAST REMINDER DID NOT GO IS FLAGGED ON THE ROW.
          //  Before 072 there was no such state to show: everything said
          //  sent. Now it is the one thing on this screen somebody should act
          //  on, so it carries the reason and it is red.
          + (last && last.outcome === "failed"
              ? ' <span class="fx-flag warn" title="' + h.esc(last.error || "")
                + '">last one did not go</span>' : '')
          + (last && last.outcome === "queued"
              ? ' <span class="fx-flag">waiting for the mail server</span>' : '')
          + '</td>'
          + '<td>' + h.esc(r.pupils) + '</td>'
          + '<td>' + h.esc(r.last_paid_on ? h.shortDate(r.last_paid_on) : "never") + '</td>'
          + '<td>' + h.esc(r.last_reminded_at ? h.shortDate(r.last_reminded_at) : "never") + '</td>'
          + '<td class="num">' + h.esc(h.pounds(r.charged_p)) + '</td>'
          + '<td class="num">' + h.esc(h.pounds(r.paid_p)) + '</td>'
          + '<td class="num owe">' + h.esc(h.pounds(r.balance_p)) + '</td>'
          + '</tr>';
      }

      /*  WHAT WILL ACTUALLY BE EMAILED — AND IT IS THE VISIBLE ROWS, NOT
          EVERY TICKED ONE.

          This read ROWS rather than visible(), so ticking ten families and
          then typing a search term left the nine hidden ones selected and
          sent to them. The comment on the select-all toggle already said
          exactly why that is wrong — "a select all that silently includes
          rows a filter is hiding is how somebody emails a family they had
          deliberately filtered out" — and the guard had been put on the
          toggle and not on the send, which is the half that matters.

          `can_email` is filtered here too, so what the confirmation counts
          and what the database will do cannot drift apart. */
      function chosen() {
        return visible().filter(function (r) {
          return picked[r.id] && r.can_email;
        });
      }

      function bar() {
        var n = chosen().length;
        el("ow-bar").hidden = n === 0;
        el("ow-picked").textContent = n
          ? n + " famil" + (n === 1 ? "y" : "ies") + " selected, "
            + h.pounds(chosen().reduce(function (a, r) {
                return a + Number(r.balance_p || 0); }, 0)) + " between them"
          : "";
      }

      /*  ASK, WITH THE NUMBER IN IT. */
      function ask() {
        var list = chosen();
        if (!list.length) return;
        h.note("fx-error", ""); h.note("fx-ok", "");

        if (list.length > 120) {
          h.note("fx-error", "That is " + list.length + " families in one go. "
               + "The most that can be sent at once is 120 — an email cannot "
               + "be unsent, so a run this size goes in two presses with the "
               + "first result read before the second.");
          return;
        }

        var recent = list.filter(function (r) {
          var d = h.daysAgo(r.last_reminded_at);
          return d !== null && d < 7;
        }).length;

        el("ow-confirm-t").innerHTML =
            'Email <strong>' + list.length + ' famil'
          + (list.length === 1 ? "y" : "ies") + '</strong> about '
          + '<strong>' + h.esc(h.pounds(list.reduce(function (a, r) {
              return a + Number(r.balance_p || 0); }, 0))) + '</strong> between them?'
          + (recent ? ' <br>' + recent + ' of them '
              + (recent === 1 ? "was" : "were")
              + ' written to in the last seven days and will be skipped.' : '')
          + '<br><span class="ref">The message says what the family owes, the '
          + 'reference to quote and how to pay. It never names a child.</span>';
        el("ow-confirm").hidden = false;
      }

      function send() {
        var list = chosen();
        var btn = el("ow-yes");
        h.busy(btn, true, "Yes, send them");

        sb.rpc("send_madrasah_fee_reminders", {
          p_households: list.map(function (r) { return r.id; })
        }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var d = res.data || {};
          el("ow-confirm").hidden = true;
          picked = {};
          report(d);
          h.note("fx-ok", (d.sent || 0) + " reminder"
               + ((d.sent === 1) ? "" : "s") + " sent. Delivery is not "
               + "reported back, so this means they left the masjid — not "
               + "that they arrived.");
          return load();
        }).catch(function (e) {
          el("ow-confirm").hidden = true;
          h.note("fx-error", "Nothing was sent — " + ((e && e.message) || String(e)));
        }).finally(function () { h.busy(btn, false, "Yes, send them"); });
      }

      /*  THREE WORDS FOR THREE DIFFERENT THINGS, BECAUSE THEY ARE DIFFERENT.

          Handed over  — the message has left this system and the mail server
                         has not answered yet. Usually seconds.
          Accepted     — the mail server took it. This is as far as certainty
                         goes: one.com reports no bounces at all, so nothing
                         here can say a message was READ, or even delivered.
          Did not go   — the mail server refused it, or never answered. The
                         family has not been written to and can be written to
                         again immediately.

          Before migration 072 all three said "Sent". */
      var WHY = {
        queued:       "Handed to the mail server",
        sent:         "Accepted by the mail server",
        no_contact:   "No email address on file",
        too_soon:     "Written to in the last seven days",
        nothing_owed: "Owes nothing now",
        failed:       "Did NOT go — see why"
      };

      function report(d) {
        var rows = h.list(d.results);
        el("ow-result-bk").hidden = false;
        el("ow-result").innerHTML =
            '<div class="fx-tw"><table class="fx-t"><thead><tr>'
          + '<th>Family</th><th>What happened</th></tr></thead><tbody>'
          + rows.map(function (r) {
              return '<tr><td>' + h.esc(r.name) + '</td><td>'
                   + '<span class="fx-flag ' + (r.outcome === "sent" ? "ok" : "") + '">'
                   + h.esc(WHY[r.outcome] || r.outcome) + '</span></td></tr>';
            }).join("")
          + '</tbody></table></div>';
      }

      /*  THE DOWNLOAD SAYS WHAT IT CONTAINS, NOT "EXPORT".
          It carries families' names and what they owe, so it is a file
          somebody has to look after — the same reasoning as the collections
          screen, and the label is the only warning a person gets. */
      function csv() {
        var rows = visible();
        if (!rows.length) {
          h.note("fx-error", "There is nothing to download.");
          return;
        }
        h.downloadCsv(
          "taiyabah-madrasah-outstanding-" + h.stamp() + ".csv",
          ["Reference", "Family", "Children", "Charged (£)", "Paid (£)",
           "Owes (£)", "Last paid", "Last reminded", "Can be emailed"],
          rows.map(function (r) {
            return [r.reference, r.name, r.pupils,
                    h.pounds(r.charged_p, { plain: true }),
                    h.pounds(r.paid_p, { plain: true }),
                    h.pounds(r.balance_p, { plain: true }),
                    r.last_paid_on || "", r.last_reminded_at || "",
                    r.can_email ? "yes" : "no"];
          }));
        h.note("fx-ok", "Downloaded " + rows.length + " famil"
             + (rows.length === 1 ? "y" : "ies")
             + ". It has names and amounts in it — keep it somewhere sensible "
             + "and delete it when you are done.");
      }

      el("ow-send").addEventListener("click", ask);
      el("ow-yes").addEventListener("click", send);
      el("ow-no").addEventListener("click", function () {
        el("ow-confirm").hidden = true;
      });
      el("ow-none").addEventListener("click", function () { picked = {}; draw(); });

      /*  ONE PRESS TO PICK UP EVERY FAMILY WHOSE LAST MESSAGE DID NOT GO.
          Selects them; it does not send. The confirmation still has to be
          read, because a retry is as unrecallable as a first attempt. */
      var again = el("ow-again");
      if (again) again.addEventListener("click", function () {
        picked = {};
        ROWS.forEach(function (r) {
          if (r.can_email && r.last_reminder && r.last_reminder.outcome === "failed") {
            picked[r.id] = true;
          }
        });
        draw();
        h.note("fx-ok", Object.keys(picked).length
          ? "Picked the families whose last reminder did not go. Press Send "
            + "reminders when you have looked at them."
          : "Every reminder that was sent went. Nothing to try again.");
      });
      el("ow-search").addEventListener("input", draw);
      el("ow-onlyemail").addEventListener("change", draw);
      el("ow-csv").addEventListener("click", csv);

      load();
    }
  });
})();
