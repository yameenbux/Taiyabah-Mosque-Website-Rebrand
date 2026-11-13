/* ===========================================================================
   app.js — the Membership screen.

   ES5 ONLY. var and function, no arrow functions, no const or let, no
   template literals. Older phones in this community run browsers that do not
   parse the rest, and the failure is a blank screen rather than a warning.

   WHAT THIS SCREEN IS FOR. The masjid's register was an Excel sheet and "has
   he paid?" was answered by somebody who knew. That works at the counter and
   nowhere else — the nikāḥ fee already charges members £100 and non-members
   £200 on the honour system, because there was no register for it to ask.

   TWO VIEWS, ONE PAGE. The list says WHETHER and the record says WHAT: the
   list carries names and figures and no addresses at all, because a screen
   that sits open on a desk all evening should not hold five hundred homes.
   That is not politeness here — membership_owing_list() does not return
   addresses, so it is enforced in Postgres where the browser cannot reach.

   EVERY FIGURE COMES FROM POSTGRES. Nothing on this page adds up money. The
   balance, the arrears and the four figures at the top are all computed by
   membership_state() and membership_overview(), so this screen and the
   member's own screen in the app cannot disagree about what somebody owes.
   =========================================================================== */
(function () {
  "use strict";

  var el = function (id) { return document.getElementById(id); };
  var sbc = null;          // the signed-in Supabase client, handed in by the gate
  var pounds = null;       // gate.js's, so there is one £ formatter in the portal
  var pence = null;        // and one place a typed string becomes a number

  var state = {
    filter: "owing",
    search: "",
    year: null,
    rows: [],
    member: null           // the open record, or null for the list
  };

  function esc(s) {
    return String(s === null || s === undefined ? "" : s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function say(id, msg) {
    var n = el(id);
    if (!n) return;
    if (!msg) { n.hidden = true; n.textContent = ""; return; }
    n.textContent = msg;
    n.hidden = false;
  }

  function clearNotes() { say("fx-error", ""); say("fx-ok", ""); }

  /*  Every call goes through here so that a refusal from Postgres reaches the
      screen as the sentence Postgres wrote. Those functions speak to the
      office directly — "Set the fee for 2017 before importing its payments" —
      and replacing that with "Something went wrong" throws away the only
      thing that tells somebody what to do next. */
  function rpc(fn, args) {
    return sbc.rpc(fn, args || {}).then(function (res) {
      if (res.error) throw new Error(res.error.message || ("Could not " + fn));
      return res.data;
    });
  }

  /*  A date the office reads, not an ISO string. Null stays null rather than
      becoming "Invalid Date", which is what a bare new Date(null) gives. */
  function when(d) {
    if (!d) return "—";
    var parts = String(d).slice(0, 10).split("-");
    if (parts.length !== 3) return String(d);
    var MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return Number(parts[2]) + " " + MON[Number(parts[1]) - 1] + " " + parts[0];
  }

  var METHOD = {
    card: "Card", cash: "Cash", terminal: "Card terminal", bank: "Transfer",
    cheque: "Cheque", other: "Other",
    /*  'legacy' is what came out of the Excel sheet, where the method was
        never recorded. Saying "from the old register" is honest; showing
        "Cash" would be a guess dressed up as a fact. */
    legacy: "From the old register"
  };
  function method(m) { return m ? (METHOD[m] || m) : "—"; }

  /* ======================================================================
     THE LIST
     ====================================================================== */

  function loadList() {
    clearNotes();
    return Promise.all([
      rpc("membership_overview"),
      rpc("membership_owing_list", {
        p_filter: state.filter,
        p_search: state.search || null,
        p_limit: 500
      })
    ]).then(function (both) {
      drawFigures(both[0]);
      state.year = both[1].year;
      state.rows = both[1].rows || [];
      drawRows(both[1]);
    })["catch"](function (e) { say("fx-error", e.message); });
  }

  function drawFigures(o) {
    var y = o.year;
    /*  FIVE FIGURES, NOT THREE, AND THEY ADD UP. paid + owing + unraised is
        the register, every time. An earlier version of the function behind
        this dropped a member whose year had been set aside into neither
        bucket, and nothing on the screen would have shown that. */
    var bits = [
      ["", o.register, "On the register", "Members who have not left"],
      ["good", o.paid, "Paid for " + y, "Settled, or set aside"],
      ["owe", o.owing, "Still owing for " + y, "Somebody should speak to them"],
      ["owe", pounds(o.owing_p), "Owed for " + y, ""],
      ["owe", pounds(o.arrears_p), "Owed in total", "Every year, not just this one"]
    ];
    if (Number(o.unraised) > 0) {
      bits.push(["quiet", o.unraised, "Not yet charged for " + y,
                 "Raise this year's charges to include them"]);
    }
    el("mb-figs").innerHTML = bits.map(function (b) {
      return '<div class="fx-fig ' + b[0] + '">'
           +   '<span class="n">' + esc(b[1]) + '</span>'
           +   '<span class="k">' + esc(b[2]) + '</span>'
           +   (b[3] ? '<span class="s">' + esc(b[3]) + '</span>' : "")
           + '</div>';
    }).join("");
  }

  function thisYearCell(r) {
    if (r.waived) return '<span class="mb-aside">Set aside</span>';
    if (r.settled) return '<span class="cr">Paid</span> <span class="ref">'
                        + esc(method(r.method)) + '</span>';
    if (Number(r.paid_p) > 0)
      return '<span class="mb-part">' + esc(pounds(r.paid_p)) + ' of '
           + esc(pounds(r.net_p)) + '</span>';
    return '<span class="owe">' + esc(pounds(r.outstanding_p)) + ' owing</span>';
  }

  function drawRows(payload) {
    var head = el("mb-yearcol");
    if (head) head.textContent = String(payload.year);

    if (!state.rows.length) {
      el("mb-rows").innerHTML =
        '<tr><td colspan="6" class="fx-none">Nobody matches that.</td></tr>';
      el("mb-count").textContent = "";
      return;
    }

    el("mb-rows").innerHTML = state.rows.map(function (r) {
      return '<tr>'
        + '<td>' + esc(r.name) + '</td>'
        + '<td class="ref">' + esc(r.reference) + '</td>'
        + '<td>' + thisYearCell(r) + '</td>'
        + '<td class="num' + (Number(r.arrears_p) > 0 ? " owe" : "") + '">'
        +   esc(Number(r.arrears_p) > 0 ? pounds(r.arrears_p) : "—")
        +   (Number(r.years_owing) > 1
              ? ' <span class="fx-flag warn">' + esc(r.years_owing) + ' years</span>' : "")
        + '</td>'
        + '<td class="ref">' + esc(when(r.last_paid_on)) + '</td>'
        + '<td><button type="button" class="mb-open" data-id="' + esc(r.id) + '">Open</button></td>'
        + '</tr>';
    }).join("");

    /*  "Showing 6 of 294" — the denominator is the point. A rewrite of
        another screen in this portal dropped it once and nobody could tell
        whether they were looking at everything. */
    el("mb-count").textContent =
      "Showing " + payload.shown + " of " + payload.total
      + (state.filter === "owing" ? " still owing"
         : state.filter === "paid" ? " paid" : " on the register") + ".";
  }

  /* ======================================================================
     ONE MEMBER
     ====================================================================== */

  function openMember(id) {
    clearNotes();
    return rpc("membership_one", { p_member: id }).then(function (m) {
      state.member = m;
      drawMember(m);
      el("mb-list").hidden = true;
      el("mb-one").hidden = false;
      el("mb-title").textContent = "A member's record";
      el("mb-sub").textContent =
        "Everything the masjid holds about this member, and every year on it.";
      window.scrollTo(0, 0);
    })["catch"](function (e) { say("fx-error", e.message); });
  }

  function backToList() {
    state.member = null;
    el("mb-one").hidden = true;
    el("mb-list").hidden = false;
    el("mb-title").textContent = "The register";
    el("mb-sub").textContent =
      "Everyone on the membership register, and what each of them has paid.";
    loadList();
  }

  function drawMember(m) {
    el("mb-name").textContent = m.name;
    el("mb-ref").textContent = m.reference;
    el("mb-meta").textContent =
      (m.member_since ? "Member since " + when(m.member_since) : "Joined — date not recorded")
      + " · " + (Number(m.outstanding_p) > 0
                   ? pounds(m.outstanding_p) + " outstanding across " + m.years_owing
                     + (Number(m.years_owing) === 1 ? " year" : " years")
                   : "Nothing outstanding");

    var rows = [
      ["Address", esc(m.address_line || "—"), ""],
      ["Postcode", esc(m.postcode || "—"), ""],
      ["Telephone", esc(m.telephone || "—"), ""],
      /*  See members.css: a missing email is the reason the Ramadan reminder
          cannot reach most of the register, so it is said out loud. Paying
          online fills it in — Stripe collects one to send its own receipt
          and mark_membership_fee_paid() writes it back. */
      ["Email", esc(m.email || "None held"), m.email ? "" : " class=\"none\""]
    ];
    el("mb-details").innerHTML = rows.map(function (r) {
      return '<div><dt>' + esc(r[0]) + '</dt><dd' + r[2] + '>' + r[1] + '</dd></div>';
    }).join("");

    drawYears(m);
    fillYearPickers(m);
  }

  function drawYears(m) {
    var years = m.years || [];
    el("mb-yearrows").innerHTML = years.map(function (y) {
      var statusCell;
      if (Number(y.waived_p) > 0) statusCell = '<span class="mb-aside">Set aside</span>';
      else if (y.settled)         statusCell = '<span class="cr">' + esc(method(y.method)) + '</span>';
      else                        statusCell = '<span class="ref">—</span>';

      var canWaive = !y.settled && Number(y.paid_p) === 0;
      return '<tr>'
        + '<td class="num">' + esc(y.year) + '</td>'
        + '<td class="num">' + esc(pounds(y.fee_p)) + '</td>'
        + '<td class="num">' + esc(Number(y.paid_p) > 0 ? pounds(y.paid_p) : "—") + '</td>'
        + '<td class="num' + (Number(y.outstanding_p) > 0 ? " owe" : "") + '">'
        +   esc(Number(y.outstanding_p) > 0 ? pounds(y.outstanding_p) : "—") + '</td>'
        + '<td>' + statusCell + '</td>'
        + '<td>' + (canWaive
             ? '<button type="button" class="mb-rowact" data-waive="' + esc(y.year)
               + '">Set aside</button>' : "") + '</td>'
        + '</tr>';
    }).join("");
  }

  function fillYearPickers(m) {
    var years = m.years || [];
    /*  Only years that still owe something can be paid or set aside. A
        picker offering a settled year is an invitation to a mistake the
        database will then refuse, which wastes somebody's time twice. */
    var owing = years.filter(function (y) { return Number(y.outstanding_p) > 0; });
    var opts = owing.map(function (y) {
      return '<option value="' + esc(y.year) + '">' + esc(y.year) + " — "
           + esc(pounds(y.outstanding_p)) + " owing</option>";
    }).join("");
    var none = '<option value="">Nothing is owed</option>';
    el("mb-pay-year").innerHTML = opts || none;
    el("mb-waive-year").innerHTML =
      owing.filter(function (y) { return Number(y.paid_p) === 0; }).map(function (y) {
        return '<option value="' + esc(y.year) + '">' + esc(y.year) + "</option>";
      }).join("") || none;

    /*  Prefill the amount with what that year actually needs, because that is
        the figure in nine cases out of ten and retyping it is where a digit
        gets dropped. */
    var amt = el("mb-pay-amount");
    if (owing.length && amt) amt.value = (Number(owing[0].outstanding_p) / 100).toFixed(2);
  }

  /* ======================================================================
     WRITING
     ====================================================================== */

  function recordPayment(e) {
    e.preventDefault();
    clearNotes();
    var year = el("mb-pay-year").value;
    var amount = pence(el("mb-pay-amount").value);
    if (!year) { say("fx-error", "There is nothing owing to record a payment against."); return; }
    if (!amount || amount <= 0) { say("fx-error", "Type the amount that was handed over."); return; }

    var btn = el("mb-pay-go");
    btn.disabled = true;
    rpc("membership_record_payment", {
      p_member: state.member.id,
      p_year: Number(year),
      p_amount_p: amount,
      p_method: el("mb-pay-method").value,
      p_reference: el("mb-pay-ref").value || null,
      p_note: null
    }).then(function () {
      el("mb-pay-ref").value = "";
      say("fx-ok", pounds(amount) + " recorded against " + year + ".");
      return openMember(state.member.id);
    })["catch"](function (err) { say("fx-error", err.message); })
      .then(function () { btn.disabled = false; });
  }

  function waiveYear(e) {
    e.preventDefault();
    clearNotes();
    var year = el("mb-waive-year").value;
    var note = el("mb-waive-note").value;
    if (!year) { say("fx-error", "There is no year to set aside."); return; }
    /*  Checked here so the office gets the sentence before the round trip,
        and checked again in Postgres because a boundary that is only in the
        browser is a boundary that lasts until somebody calls the function
        directly. */
    if (!note || note.replace(/\s/g, "").length < 3) {
      say("fx-error", "Say why the year is being set aside. It is recorded against your name.");
      return;
    }
    var btn = el("mb-waive-go");
    btn.disabled = true;
    rpc("membership_waive_year", {
      p_member: state.member.id, p_year: Number(year), p_note: note
    }).then(function () {
      el("mb-waive-note").value = "";
      say("fx-ok", year + " has been set aside, with your name and the reason against it.");
      return openMember(state.member.id);
    })["catch"](function (err) { say("fx-error", err.message); })
      .then(function () { btn.disabled = false; });
  }

  /*  The office asked for Excel on every other money screen, so it is here
      too. Names and figures only — the same columns the table shows, and so
      the same absence of addresses. */
  function downloadCsv() {
    if (!state.rows.length) { say("fx-error", "There is nothing to download."); return; }
    var head = ["Member", "Reference", String(state.year), "All years owed",
                "Years owing", "Last paid"];
    var lines = [head];
    state.rows.forEach(function (r) {
      lines.push([
        r.name, r.reference,
        r.waived ? "Set aside" : r.settled ? "Paid" : (Number(r.outstanding_p) / 100).toFixed(2),
        (Number(r.arrears_p) / 100).toFixed(2),
        String(r.years_owing),
        r.last_paid_on || ""
      ]);
    });
    var csv = lines.map(function (row) {
      return row.map(function (c) {
        return '"' + String(c === null || c === undefined ? "" : c).replace(/"/g, '""') + '"';
      }).join(",");
    }).join("\r\n");
    var blob = new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8" });
    var a = document.createElement("a");
    a.href = URL.createObjectURL(blob);
    a.download = "membership-" + state.year + "-" + state.filter + ".csv";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(a.href);
  }

  /* ======================================================================
     WIRING
     ====================================================================== */

  function mount(identity, sb) {
    sbc = sb;
    pounds = window.PortalGate.pounds;
    pence = window.PortalGate.pence;

    el("mb-rows").addEventListener("click", function (e) {
      var b = e.target.closest ? e.target.closest("[data-id]") : null;
      if (b) openMember(b.getAttribute("data-id"));
    });

    el("mb-yearrows").addEventListener("click", function (e) {
      var b = e.target.closest ? e.target.closest("[data-waive]") : null;
      if (!b) return;
      el("mb-waive-year").value = b.getAttribute("data-waive");
      el("mb-waive-note").focus();
    });

    el("mb-back").addEventListener("click", backToList);
    el("mb-pay-form").addEventListener("submit", recordPayment);
    el("mb-waive-form").addEventListener("submit", waiveYear);
    el("mb-csv").addEventListener("click", downloadCsv);

    var tabs = document.querySelectorAll(".mb-tab");
    Array.prototype.forEach.call(tabs, function (t) {
      t.addEventListener("click", function () {
        Array.prototype.forEach.call(tabs, function (o) { o.classList.remove("is-on"); });
        t.classList.add("is-on");
        state.filter = t.getAttribute("data-filter");
        loadList();
      });
    });

    /*  Typing in a search box must not fire a query per keystroke against a
        function that scans the register. */
    var timer = null;
    el("mb-q").addEventListener("input", function () {
      var v = this.value;
      if (timer) clearTimeout(timer);
      timer = setTimeout(function () { state.search = v; loadList(); }, 250);
    });

    loadList();
  }

  window.PortalGate.start({
    key: "members",
    /*  THE SITE RAIL, not the madrasah's. This screen is in the Admin Centre
        beside Donations and Hall Hire; a rail offering Pupils and Registers
        would be telling somebody they are somewhere they are not. */
    rail: "site",
    area: "Admin Centre",
    depth: 1,
    title: "Membership",
    mount: mount
  });
})();
