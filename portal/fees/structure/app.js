/* ===========================================================================
   portal/fees/structure/app.js — what things cost.

   THE SCREEN THAT MAKES THE OTHERS UNNECESSARY TO A DEVELOPER.

   Every figure in this section comes from here, and every one of them used
   to live somewhere only a developer could reach: £10 a week was three lines
   of HTML in index_template.html, and changing it meant editing a template,
   running two Python scripts and pushing to GitHub. Migration 045 made the
   same complaint about hall hire and the ending was the same — the website
   quoting a price the office had stopped charging.

   THE BANK DETAILS ARE EDITABLE HERE AND THAT DEPARTS FROM 045, WHICH PUT
   THEM OUT OF SCOPE. The reason is in migration 069's header and the short
   version is: 045 was protecting a PUBLIC page, this one is behind sign-in
   and two-step, and hard-coding them means that on the day the masjid
   changes bank somebody pastes an account number into a template under time
   pressure with no record of who did it. What defeats mandate fraud is not
   immutability but noise — so changing them is audited, the screen
   permanently shows who last did it, and the account number has to be typed
   twice.
   =========================================================================== */
(function () {
  "use strict";

  FeesGate.start({
    key: "md-structure",
    title: "What things cost",
    depth: 3,

    mount: function (identity, sb, h) {
      var el = h.el;
      var D = {};
      var editingRate = null;
      var editingPeriod = null;
      var raising = null;

      function load() {
        return sb.rpc("madrasah_fee_structure").then(function (res) {
          if (res.error) throw new Error(res.error.message);
          D = res.data || {};
          draw();
        }).catch(function (e) {
          h.note("fx-error", "The fee structure could not be read — "
                 + ((e && e.message) || String(e)));
        });
      }

      function s(key) {
        var v = (D.settings || {})[key];
        return (v === null || v === undefined) ? "" : String(v);
      }

      function draw() {
        el("st-unconfirmed").hidden = !!s("rates_confirmed_on");
        drawRates();
        drawPeriods();
        drawBank();
        el("st-card").value    = s("card_link");
        el("st-rem-sub").value = s("reminder_subject");
        el("st-rem-body").value = s("reminder_body");
      }

      /*  WHAT A TERM IS, FOR THE "over a term" COLUMN.
          It was hard-coded to 13, which is a lie on a masjid that charges 11.
          Taken from the most recent term the madrasah has actually set up,
          and only 13 when there is nothing to go on. */
      function termWeeks() {
        var ps = h.list(D.periods);
        for (var i = 0; i < ps.length; i++) {
          var w = parseFloat(ps[i].weeks);
          if (isFinite(w) && w > 0) return w;
        }
        return 13;
      }

      /* ------------------------------------------------------- rates ---- */
      function drawRates() {
        var rates = h.list(D.rates);
        var host = el("st-rates");

        if (!rates.length) {
          host.innerHTML = '<div class="fx-empty">No rates yet. Nothing can be '
            + 'charged until there is at least one, marked as the default.</div>';
        } else {
          host.innerHTML =
              '<div class="fx-tw"><table class="fx-t"><thead><tr>'
            + '<th>Rate</th><th class="num">A week</th><th class="num">A '
            + h.esc(termWeeks()) + '-week term</th>'
            + '<th>Children on it</th><th></th></tr></thead><tbody>'
            + rates.map(function (r) {
                return '<tr><td><strong>' + h.esc(r.name) + '</strong>'
                     + (r.is_default ? ' <span class="fx-flag ok">default</span>' : '')
                     + (r.active ? '' : ' <span class="fx-flag">not in use</span>')
                     + '</td>'
                     + '<td class="num">' + h.esc(h.pounds(r.amount_p)) + '</td>'
                     //  Shown because nobody bills weekly and £10 a week does
                     //  not read as £130 until somebody multiplies it.
                     + '<td class="num ref">'
                     + h.esc(h.pounds(Math.round(r.amount_p * termWeeks()))) + '</td>'
                     + '<td>' + h.esc(r.pupils) + '</td>'
                     + '<td class="num"><button type="button" class="fx-mini" '
                     + 'data-rate="' + h.esc(r.id) + '">Change</button></td></tr>'
                     + (editingRate === r.id ? rateForm(r) : '');
              }).join("")
            + '</tbody></table></div>'
            + (editingRate === "new" ? '<div class="fx-bk">' + rateForm(null) + '</div>' : '');
        }
        if (!rates.length && editingRate === "new") {
          host.innerHTML += '<div class="fx-bk">' + rateForm(null) + '</div>';
        }
        wireRates();
      }

      function rateForm(r) {
        var pre = r ? "" : '<h3>A new rate</h3>';
        var body =
            '<div class="fx-form">'
          + '<label class="fx-fld"><span>What it covers</span>'
          + '<input type="text" id="rt-name" maxlength="60" value="'
          + h.esc(r ? r.name : "") + '" placeholder="Hifz"></label>'
          + '<label class="fx-fld"><span>A week</span>'
          + '<input type="text" id="rt-amt" inputmode="decimal" value="'
          + h.esc(r ? h.pounds(r.amount_p, { plain: true }) : "") + '" placeholder="10.00"></label>'
          + '<label class="fx-fld" style="flex-direction:row;align-items:center;gap:8px">'
          + '<input type="checkbox" id="rt-def" style="width:18px;height:18px"'
          + (r && r.is_default ? " checked" : "") + '>'
          + '<span style="text-transform:none;letter-spacing:0">Charge this '
          + 'unless a child is on something else</span></label>'
          + '<label class="fx-fld" style="flex-direction:row;align-items:center;gap:8px">'
          + '<input type="checkbox" id="rt-act" style="width:18px;height:18px"'
          + (!r || r.active ? " checked" : "") + '>'
          + '<span style="text-transform:none;letter-spacing:0">In use</span></label>'
          + '</div>'
          + '<div class="fx-acts">'
          + '<button type="button" class="btn btn-gold" data-ratesave="'
          + h.esc(r ? r.id : "") + '">Save</button>'
          + '<button type="button" class="btn btn-ghost" data-ratecancel="1">Cancel</button>'
          + '</div>';
        return r ? '<tr><td colspan="5">' + body + '</td></tr>' : pre + body;
      }

      function wireRates() {
        Array.prototype.forEach.call(el("st-rates").querySelectorAll("[data-rate]"),
          function (b) {
            b.addEventListener("click", function () {
              editingRate = editingRate === b.getAttribute("data-rate")
                ? null : b.getAttribute("data-rate");
              drawRates();
            });
          });
        var save = el("st-rates").querySelector("[data-ratesave]");
        if (save) save.addEventListener("click", function () {
          var amt = h.pence(el("rt-amt").value);
          h.note("fx-error", ""); h.note("fx-ok", "");
          if (!el("rt-name").value.trim()) {
            h.note("fx-error", "A rate needs a name — what it covers."); return;
          }
          if (amt === null || amt < 1) {
            h.note("fx-error", "Type what a week costs, like 10 or 14.50."); return;
          }
          h.busy(save, true, "Save");
          sb.rpc("save_madrasah_fee_rate", { p: {
            id: save.getAttribute("data-ratesave") || null,
            name: el("rt-name").value.trim(),
            amount_p: amt,
            is_default: el("rt-def").checked,
            active: el("rt-act").checked
          }}).then(function (res) {
            if (res.error) throw new Error(res.error.message);
            editingRate = null;
            h.note("fx-ok", "Saved. It applies the next time charges are raised — "
                 + "bills already sent out do not change.");
            return load();
          }).catch(function (e) {
            h.note("fx-error", "Nothing was saved — " + ((e && e.message) || String(e)));
            h.busy(save, false, "Save");
          });
        });
        var cancel = el("st-rates").querySelector("[data-ratecancel]");
        if (cancel) cancel.addEventListener("click", function () {
          editingRate = null; drawRates();
        });
      }

      /* ----------------------------------------------------- periods ---- */
      function drawPeriods() {
        var ps = h.list(D.periods);
        var host = el("st-periods");
        var STATUS = { draft: "Not charged yet", issued: "Charged", closed: "Closed" };

        host.innerHTML = (ps.length
          ? '<div class="fx-tw"><table class="fx-t"><thead><tr>'
            + '<th>Term</th><th>From</th><th>To</th><th class="num">Weeks charged</th>'
            + '<th>State</th><th class="num">Bills raised</th><th></th>'
            + '</tr></thead><tbody>'
            + ps.map(function (p) {
                return '<tr><td><strong>' + h.esc(p.name) + '</strong></td>'
                     + '<td>' + h.esc(h.shortDate(p.starts_on)) + '</td>'
                     + '<td>' + h.esc(h.shortDate(p.ends_on)) + '</td>'
                     + '<td class="num">' + h.esc(p.weeks) + '</td>'
                     + '<td><span class="fx-flag ' + (p.status === "issued" ? "ok" : "") + '">'
                     + h.esc(STATUS[p.status] || p.status) + '</span></td>'
                     + '<td class="num">' + h.esc(p.charges) + '</td>'
                     + '<td class="num"><div class="fx-rowacts">'
                     + (p.status !== "closed"
                         ? '<button type="button" class="fx-mini" data-raise="'
                           + h.esc(p.id) + '">Raise charges</button>' : '')
                     + '<button type="button" class="fx-mini" data-period="'
                     + h.esc(p.id) + '">Change</button>'
                     + '</div></td></tr>'
                     + (raising === p.id ? raiseRow(p) : '')
                     + (editingPeriod === p.id ? periodForm(p) : '');
              }).join("")
            + '</tbody></table></div>'
          : '<div class="fx-empty">No terms yet. A bill is a number of weeks '
            + 'times a rate, so nothing can be charged until there is one.</div>')
          + (editingPeriod === "new" ? '<div class="fx-bk">' + periodForm(null) + '</div>' : '');
        wirePeriods();
      }

      /*  RAISING CHARGES SAYS WHAT IT IS ABOUT TO DO, WITH THE NUMBER OF
          CHILDREN IT WILL SKIP. On the day this ships that number is 543,
          and a person who presses the button without being told would raise
          nothing and conclude the screen is broken. */
      function raiseRow(p) {
        var skip = Number(D.pupils_no_family || 0);
        return '<tr><td colspan="7"><div class="fx-confirm">'
          + '<p>Raise a bill for every child in a family, for '
          + '<strong>' + h.esc(p.name) + '</strong> — '
          + h.esc(p.weeks) + ' weeks at each child&rsquo;s rate, with the sibling '
          + 'discount applied.'
          + (skip ? '<br><strong>' + skip + ' child' + (skip === 1 ? "" : "ren")
                    + ' will be skipped</strong> because they are not in a family '
                    + 'yet. Nobody will be billed for them.' : '')
          + '<br><span class="ref">Safe to press twice — a child who already has '
          + 'a bill for this term does not get a second one.</span></p>'
          + '<div class="fx-acts">'
          + '<button type="button" class="btn btn-gold" data-raiseyes="' + h.esc(p.id)
          + '">Raise the charges</button>'
          + '<button type="button" class="btn btn-ghost" data-raiseno="1">No</button>'
          + '</div></div></td></tr>';
      }

      function periodForm(p) {
        var frozen = p && Number(p.charges) > 0;
        var body =
            (p ? '' : '<h3>A new term</h3>')
          + (frozen ? '<p class="fx-note"><strong>' + p.charges + ' bills have '
              + 'already been raised against this term</strong>, so its dates and '
              + 'week count are fixed. Changing them would leave every one of '
              + 'those bills disagreeing with the term it was worked out from, '
              + 'and the first person to notice would be a parent checking their '
              + 'own arithmetic. The name can still change.</p>' : '')
          + '<div class="fx-form">'
          + '<label class="fx-fld wide"><span>Name</span>'
          + '<input type="text" id="pd-name" maxlength="60" value="'
          + h.esc(p ? p.name : "") + '" placeholder="Autumn term 2026"></label>'
          + '<label class="fx-fld"><span>From</span>'
          + '<input type="date" id="pd-from" value="' + h.esc(p ? p.starts_on : "")
          + '"' + (frozen ? " disabled" : "") + '></label>'
          + '<label class="fx-fld"><span>To</span>'
          + '<input type="date" id="pd-to" value="' + h.esc(p ? p.ends_on : "")
          + '"' + (frozen ? " disabled" : "") + '></label>'
          + '<label class="fx-fld"><span>Weeks actually charged</span>'
          + '<input type="text" id="pd-weeks" inputmode="decimal" value="'
          + h.esc(p ? p.weeks : "") + '"' + (frozen ? " disabled" : "") + '>'
          + '<span class="hint">Not the number of weeks between the dates — the '
          + 'number the madrasah charges for, after the holidays it does not.</span>'
          + '</label>'
          + '<label class="fx-fld"><span>State</span>'
          + '<select id="pd-status">'
          + '<option value="draft"' + (p && p.status === "draft" ? " selected" : "")
          + '>Not charged yet</option>'
          + '<option value="issued"' + (p && p.status === "issued" ? " selected" : "")
          + '>Charged</option>'
          + '<option value="closed"' + (p && p.status === "closed" ? " selected" : "")
          + '>Closed — nothing more can be added</option>'
          + '</select></label>'
          + '</div>'
          + '<div class="fx-acts">'
          + '<button type="button" class="btn btn-gold" data-pdsave="'
          + h.esc(p ? p.id : "") + '">Save</button>'
          + '<button type="button" class="btn btn-ghost" data-pdcancel="1">Cancel</button>'
          + '</div>';
        return p ? '<tr><td colspan="7">' + body + '</td></tr>' : body;
      }

      function wirePeriods() {
        var host = el("st-periods");
        Array.prototype.forEach.call(host.querySelectorAll("[data-period]"), function (b) {
          b.addEventListener("click", function () {
            editingPeriod = editingPeriod === b.getAttribute("data-period")
              ? null : b.getAttribute("data-period");
            raising = null;
            drawPeriods();
          });
        });
        Array.prototype.forEach.call(host.querySelectorAll("[data-raise]"), function (b) {
          b.addEventListener("click", function () {
            raising = raising === b.getAttribute("data-raise")
              ? null : b.getAttribute("data-raise");
            editingPeriod = null;
            drawPeriods();
          });
        });

        var yes = host.querySelector("[data-raiseyes]");
        if (yes) yes.addEventListener("click", function () {
          h.note("fx-error", ""); h.note("fx-ok", "");
          h.busy(yes, true, "Raise the charges");
          sb.rpc("raise_madrasah_charges", { p_period: yes.getAttribute("data-raiseyes") })
            .then(function (res) {
              if (res.error) throw new Error(res.error.message);
              var d = res.data || {};
              raising = null;
              h.note("fx-ok",
                (d.raised || 0) + " bill" + (d.raised === 1 ? "" : "s") + " raised"
                + (Number(d.total_p) ? ", " + h.pounds(d.total_p) + " in total" : "")
                + (Number(d.skipped_no_family)
                    ? ". " + d.skipped_no_family + " child"
                      + (d.skipped_no_family === 1 ? "" : "ren")
                      + " skipped — they are not in a family yet." : "")
                + (Number(d.already_there) && !Number(d.raised)
                    ? " Everything for this term had already been charged." : ""));
              return load();
            }).catch(function (e) {
              h.note("fx-error", "Nothing was charged — " + ((e && e.message) || String(e)));
              h.busy(yes, false, "Raise the charges");
            });
        });
        var no = host.querySelector("[data-raiseno]");
        if (no) no.addEventListener("click", function () { raising = null; drawPeriods(); });

        var save = host.querySelector("[data-pdsave]");
        if (save) save.addEventListener("click", function () {
          h.note("fx-error", ""); h.note("fx-ok", "");
          var id = save.getAttribute("data-pdsave") || null;
          var p = { id: id, name: el("pd-name").value.trim(), status: el("pd-status").value };
          if (!el("pd-from").disabled) {
            p.starts_on = el("pd-from").value;
            p.ends_on   = el("pd-to").value;
            p.weeks     = el("pd-weeks").value;
            if (!p.name || !p.starts_on || !p.ends_on || !p.weeks) {
              h.note("fx-error", "A term needs a name, two dates and a number of weeks.");
              return;
            }
          }
          h.busy(save, true, "Save");
          sb.rpc("save_madrasah_fee_period", { p: p }).then(function (res) {
            if (res.error) throw new Error(res.error.message);
            editingPeriod = null;
            h.note("fx-ok", "Saved.");
            return load();
          }).catch(function (e) {
            h.note("fx-error", "Nothing was saved — " + ((e && e.message) || String(e)));
            h.busy(save, false, "Save");
          });
        });
        var cancel = host.querySelector("[data-pdcancel]");
        if (cancel) cancel.addEventListener("click", function () {
          editingPeriod = null; drawPeriods();
        });
      }

      /* -------------------------------------------------------- bank ---- */
      function drawBank() {
        el("st-bank-name").value   = s("bank_name");
        el("st-bank-acname").value = s("bank_account_name");
        el("st-bank-sort").value   = s("bank_sort_code");
        el("st-bank-no").value     = s("bank_account_number");

        var when = (D.settings_changed || {})["bank_account_number"];
        el("st-bank-when").textContent = when
          ? "Last changed " + h.shortDate(when.at) + " by " + when.by + "."
          : "These have never been set.";
      }

      function saveSetting(key, value, btn, idle, ok) {
        h.note("fx-error", ""); h.note("fx-ok", "");
        h.busy(btn, true, idle);
        return sb.rpc("save_madrasah_fee_setting", { p_key: key, p_value: value })
          .then(function (res) {
            if (res.error) throw new Error(res.error.message);
            if (ok) h.note("fx-ok", ok);
            return load();
          }).catch(function (e) {
            h.note("fx-error", "Nothing was saved — " + ((e && e.message) || String(e)));
            throw e;
          }).finally(function () { h.busy(btn, false, idle); });
      }

      /*  THE ACCOUNT NUMBER IS TYPED TWICE, AND ONLY WHEN IT IS CHANGING.
          Friction where it is warranted and nowhere else: making somebody
          re-type an account number they did not touch is the kind of thing
          that teaches people to click through confirmations. */
      el("st-bank-no").addEventListener("input", function () {
        var changed = el("st-bank-no").value.trim() !== s("bank_account_number");
        el("st-bank-again-w").hidden = !changed;
        if (!changed) el("st-bank-again").value = "";
      });

      el("st-bank-save").addEventListener("click", function () {
        var btn = el("st-bank-save");
        var no  = el("st-bank-no").value.trim();
        h.note("fx-error", ""); h.note("fx-ok", "");

        if (no !== s("bank_account_number") && el("st-bank-again").value.trim() !== no) {
          h.note("fx-error", "The two account numbers do not match. Nothing has "
               + "been changed. This is the account every parent is told to pay "
               + "into, so it is worth being sure.");
          return;
        }

        var fields = [
          ["bank_name",           el("st-bank-name").value.trim()],
          ["bank_account_name",   el("st-bank-acname").value.trim()],
          ["bank_sort_code",      el("st-bank-sort").value.trim()],
          ["bank_account_number", no]
        ];
        h.busy(btn, true, "Save bank details");
        //  One after another rather than at once: if the sort code is the
        //  wrong shape, the office should see that message rather than four.
        //  EVERY FIELD IS CHECKED BEFORE ANY OF THEM IS WRITTEN.
        //
        //  These are four separate settings rows and there is no transaction
        //  across four RPCs, so a sort code that failed its shape check used
        //  to leave the bank NAME already committed beside the OLD sort code
        //  and the OLD account number — a half-changed set of bank details
        //  that reads as legitimate on screen — while the message said
        //  "Nothing was saved". Validating first makes a mid-chain failure a
        //  network fault rather than a predictable one.
        var bad = null;
        if (el("st-bank-sort").value.trim()
            && !/^[0-9]{2}-[0-9]{2}-[0-9]{2}$/.test(el("st-bank-sort").value.trim())) {
          bad = "A sort code is six digits, written 00-00-00.";
        } else if (no && !/^[0-9]{8}$/.test(no)) {
          bad = "An account number is eight digits.";
        }
        if (bad) {
          h.note("fx-error", bad + " Nothing has been changed.");
          h.busy(btn, false, "Save bank details");
          return;
        }

        fields.reduce(function (chain, f) {
          return chain.then(function () {
            return sb.rpc("save_madrasah_fee_setting", { p_key: f[0], p_value: f[1] })
              .then(function (res) {
                if (res.error) throw new Error(res.error.message);
              });
          });
        }, Promise.resolve()).then(function () {
          el("st-bank-again").value = "";
          el("st-bank-again-w").hidden = true;
          h.note("fx-ok", "Bank details saved. The change is in the audit with "
               + "your name against it.");
          return load();
        }).catch(function (e) {
          h.note("fx-error", "Nothing was saved — " + ((e && e.message) || String(e)));
        }).finally(function () { h.busy(btn, false, "Save bank details"); });
      });

      el("st-card-save").addEventListener("click", function () {
        saveSetting("card_link", el("st-card").value.trim(), el("st-card-save"),
                    "Save the link",
                    el("st-card").value.trim()
                      ? "Saved. Reminders will offer paying by card."
                      : "Cleared. Reminders will not mention paying by card.")
          .catch(function () {});
      });

      el("st-rem-save").addEventListener("click", function () {
        var btn = el("st-rem-save");
        h.busy(btn, true, "Save the wording");
        sb.rpc("save_madrasah_fee_setting", {
          p_key: "reminder_subject", p_value: el("st-rem-sub").value.trim()
        }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          return sb.rpc("save_madrasah_fee_setting", {
            p_key: "reminder_body", p_value: el("st-rem-body").value.trim() });
        }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          h.note("fx-ok", "Saved.");
          return load();
        }).catch(function (e) {
          h.note("fx-error", "Nothing was saved — " + ((e && e.message) || String(e)));
        }).finally(function () { h.busy(btn, false, "Save the wording"); });
      });

      /*  CONFIRMING THE RATES RECORDS WHO DID IT. "The office confirmed it"
          with no name attached is not a confirmation anybody can rely on six
          months later. */
      el("st-confirm").addEventListener("click", function () {
        var btn = el("st-confirm");
        var who = (identity.profile && identity.profile.full_name)
               || (identity.user && identity.user.email) || "an administrator";
        h.busy(btn, true, "These are the right figures");
        //  THE DATE GOES FIRST. It is the one the banner reads, so if the
        //  second call fails the screen is honest: no date means still
        //  unconfirmed. Writing the name first and failing on the date left a
        //  name recorded against a confirmation that had not happened.
        sb.rpc("save_madrasah_fee_setting", {
          p_key: "rates_confirmed_by", p_value: who
        }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          return sb.rpc("save_madrasah_fee_setting", {
            p_key: "rates_confirmed_on", p_value: h.today() });
        }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          h.note("fx-ok", "Recorded against your name. The unconfirmed banner "
               + "is gone from every screen that uses these figures.");
          return load();
        }).catch(function (e) {
          h.note("fx-error", "Nothing was recorded — " + ((e && e.message) || String(e)));
        }).finally(function () { h.busy(btn, false, "These are the right figures"); });
      });

      el("st-rate-add").addEventListener("click", function () {
        editingRate = editingRate === "new" ? null : "new"; drawRates();
      });
      el("st-period-add").addEventListener("click", function () {
        editingPeriod = editingPeriod === "new" ? null : "new"; drawPeriods();
      });

      load();
    }
  });
})();
