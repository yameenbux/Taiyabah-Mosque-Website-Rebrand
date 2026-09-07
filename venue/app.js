/* ===========================================================================
   Taiyabah Masjid — Hall Hire & Nikāḥ
   Bolton Central Islamic Society · Registered charity 1041569

   Handles: sign in -> MFA (enrol or verify) -> signed-in shell -> sign out.

   Security notes for anyone maintaining this:
     - Only the anon key is used. RLS in Postgres is the real access control;
       nothing here is trusted to protect data.
     - The role is read from user_roles via RLS, never from anything the
       browser could tamper with.
     - MFA is enforced client-side for UX, but the database is what must
       ultimately gate sensitive tables (see aal2 note in the roadmap).
   =========================================================================== */
(function () {
  "use strict";

  var cfg = window.TAIYABAH_CONFIG || {};
  var el = function (id) { return document.getElementById(id); };

  // --- view switching -------------------------------------------------------
  var VIEWS = ["view-loading", "view-signin", "view-mfa", "view-enrol", "view-app"];
  function show(view) {
    VIEWS.forEach(function (v) {
      var node = el(v);
      if (node) node.hidden = v !== view;
    });
  }

  function setError(id, message) {
    var box = el(id);
    if (!box) return;
    if (!message) { box.hidden = true; box.textContent = ""; return; }
    box.textContent = message;
    box.hidden = false;
  }

  function busy(button, isBusy, idleLabel) {
    if (!button) return;
    button.disabled = isBusy;
    button.textContent = isBusy ? "Please wait…" : idleLabel;
  }

  // --- config guard ---------------------------------------------------------
  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.indexOf("PASTE_") === 0) {
    show("view-signin");
    setError("signin-error",
      "This portal isn't connected yet — config.js still has placeholder values in it.");
    var f = el("signin-form");
    if (f) Array.prototype.forEach.call(f.elements, function (i) { i.disabled = true; });
    return;
  }

  // The Supabase dashboard shows the project URL with /rest/v1/ on the end.
  // Pasting it verbatim has broken this twice, and the resulting error
  // ("Invalid path specified in request URL") gives no clue why. Normalise to
  // the bare origin so either form works.
  var apiUrl = String(cfg.SUPABASE_URL || "")
                 .trim()
                 .replace(/\/+$/, "")
                 .replace(/\/rest\/v1$/, "");

  var sb = window.supabase.createClient(apiUrl, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
  });

  // --- helpers --------------------------------------------------------------

  // Reads the signed-in person's profile and role. Both queries are governed
  // by RLS, so a parent asking for someone else's row simply gets nothing.
  function loadIdentity() {
    return sb.auth.getUser().then(function (res) {
      var user = res.data && res.data.user;
      if (!user) throw new Error("No active session.");
      return Promise.all([
        sb.from("profiles").select("full_name, email").eq("id", user.id).maybeSingle(),
        sb.from("user_roles").select("role").eq("user_id", user.id)
      ]).then(function (out) {
        // Surface failures. Previously a blocked or errored query looked
        // identical to an empty result, which reported "no role assigned"
        // when the real problem was something else entirely.
        var errs = [];
        if (out[0].error) errs.push("profiles — " + out[0].error.message);
        if (out[1].error) errs.push("user_roles — " + out[1].error.message);
        var profile = out[0].data || {};
        var roles = (out[1].data || []).map(function (r) { return r.role; });
        return { user: user, profile: profile, roles: roles, errors: errs };
      });
    });
  }

  /* =========================================================================
     REQUESTS — HALL BOOKINGS AND NIKĀḤ DATES, IN ONE LIST

     Two different things arrive from the public website and both need the same
     treatment: ring the person, agree it, record the outcome. Keeping them in
     separate panels would mean the office checking two places and, sooner or
     later, missing one. So they are loaded from their two tables, normalised
     into one shape, and shown together with a badge saying which is which.

     They keep their own tables because they hold genuinely different things —
     a hall booking has a number of rooms, a nikāḥ has a prayer slot and a
     second choice of date — and forcing them into one table would mean a row
     full of columns that never apply.

     Requests submitted through the public website land in `hall_bookings`.
     This panel is where the office works through them: ring the enquirer,
     agree the date and the fee, then record the outcome.

     What the database will and will not allow (migration 004):
       - only `hall_office` and `admin` can read a booking at all
       - the office may change status, notes and handled_at, and NOTHING else.
         It cannot quietly edit somebody's name, address or requested date. If
         those are wrong the booking is declined and re-entered, so the record
         always shows what the person actually asked for.
       - nobody can delete. A request is closed by moving its status, which
         leaves a trail.

     The panel is hidden from people without the role, but that is a courtesy,
     not a control — RLS is what actually stops a parent reading these.
     ======================================================================= */
  var bookings = (function () {
    // Hire is by the day now (migration 014). These labels are kept only to
    // describe bookings taken BEFORE that change — the office still has to be
    // able to read what those hirers were promised.
    var LEGACY_SLOTS = { morning: "Morning · 9:00am – 4:00pm", evening: "Evening · 5:00pm – 11:00pm" };
    var rows = [];
    var filter = "new";
    var query = "";
    var mounted = false;

    function canSee(identity) {
      return identity.roles.indexOf("hall_office") !== -1 ||
             identity.roles.indexOf("admin") !== -1;
    }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function todayISO() {
      var d = new Date();
      return d.getFullYear() + "-" +
             String(d.getMonth() + 1).padStart(2, "0") + "-" +
             String(d.getDate()).padStart(2, "0");
    }

    function longDate(iso) {
      // Parse as parts, not Date(string) — that treats a bare date as UTC and
      // can show the wrong day to anyone west of Greenwich.
      var p = String(iso).split("-");
      var d = new Date(+p[0], +p[1] - 1, +p[2]);
      return d.toLocaleDateString("en-GB",
        { weekday: "long", day: "numeric", month: "long", year: "numeric" });
    }

    function ago(ts) {
      var mins = Math.floor((Date.now() - new Date(ts).getTime()) / 60000);
      if (mins < 2) return "just now";
      if (mins < 60) return mins + " minutes ago";
      var hrs = Math.floor(mins / 60);
      if (hrs < 24) return hrs === 1 ? "an hour ago" : hrs + " hours ago";
      var days = Math.floor(hrs / 24);
      return days === 1 ? "yesterday" : days + " days ago";
    }

    function setError(msg) {
      var box = el("bk-error");
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    var SLOT_LABELS = {
      after_fajr: "After Fajr", after_zuhr: "After Zuhr", after_asr: "After Asr",
      after_maghrib: "After Maghrib", after_isha: "After Isha",
      saturday_11: "Saturday 11:00am", flexible: "Flexible — masjid to suggest"
    };

    // One shape for both kinds, so render() and apply() do not have to care.
    // What was hired. New bookings say how many halls, or kitchen-only, and
    // run for the whole day. Old ones named a room and a session, and are
    // rendered as they were taken rather than translated into a shape they
    // never had — a booking record that quietly changes meaning is worse than
    // one that looks dated.
    function whatWasHired(r) {
      if (r.session_slot) {
        return (LEGACY_SLOTS[r.session_slot] || r.session_slot) +
               " \u00B7 Hall " + r.hall +
               (r.kitchen ? " \u00B7 with kitchen" : " \u00B7 no kitchen") +
               " \u00B7 booked under the old session rates";
      }
      if (r.hire_type === "kitchen_only") return "Kitchen only \u00B7 whole day";
      var n = r.halls_count;
      return (n === 1 ? "1 hall" : n + " halls") +
             " \u00B7 kitchen and cleaning included \u00B7 whole day";
    }

    // The deposit is what reserves a date now (migration 016), so the office
    // has to be able to see it at a glance. 'refund_due' especially: it means
    // Stripe has somebody's £100 for a date they cannot have, and until a
    // human sends it back nothing else will.
    var DEPOSIT_WORDS = {
      unpaid:     "no deposit",
      awaiting:   "sent to pay",
      paid:       "deposit paid",
      refund_due: "REFUND DUE",
      refunded:   "refunded"
    };

    // Money, in pence, because £600.00 does not exist exactly in binary and a
    // rounding error in somebody's hall bill is not a thing anybody wants to
    // explain. The base rate is whatever was STORED against the booking, not
    // whatever today's price list says — a booking taken in March keeps
    // March's price after the trustees change it.
    function money(p) {
      if (p === null || p === undefined) return null;
      return "\u00A3" + (p / 100).toFixed(2).replace(/\.00$/, "");
    }

    function fromHall(r) {
      var base = r.base_amount_p, extras = r.extras_p || 0;
      // A legacy booking taken under the old session rates has no base: the
      // combination it used is not on the current price list, and inventing a
      // figure would be worse than a dash. The office knows what was charged.
      var total = base === null || base === undefined ? null : base + extras;
      return {
        kind: "hall", table: "hall_bookings", handledCol: "handled_at",
        id: r.id, created_at: r.created_at, date: r.booking_date,
        reference: r.reference, deposit: r.deposit_status,
        base: base, extras: extras, total: total,
        balance: r.balance_status,
        // What is still owed: the total less the £100 deposit, but only if one
        // was actually paid online. A booking settled in cash owes the lot.
        owed: total === null ? null
              : Math.max(total - (r.deposit_status === "paid" ? 10000 : 0), 0),
        detail: whatWasHired(r),
        who: (r.first_name || "") + " " + (r.last_name || ""),
        phone: r.phone, email: null, sub: r.address,
        status: r.status, notes: r.office_notes, handled_at: r.handled_at
      };
    }

    function fromNikah(r) {
      var when = SLOT_LABELS[r.slot] || r.slot || "";
      if (r.preferred_time && r.slot !== "flexible") when += " \u00B7 " + r.preferred_time;
      if (r.alternative_date) when += " \u00B7 2nd choice " + longDate(r.alternative_date);
      if (r.guests_estimate) when += " \u00B7 ~" + r.guests_estimate + " guests";
      return {
        kind: "nikah", table: "nikah_requests", handledCol: "reviewed_at",
        id: r.id, created_at: r.submitted_at, date: r.preferred_date,
        detail: when,
        reference: r.reference, deposit: null,
        base: null, extras: 0, total: null, balance: null, owed: null,
        who: r.contact_name,
        phone: r.contact_phone, email: r.contact_email,
        sub: "Contact is the " + (r.contact_role === "family" ? "family" : r.contact_role) +
             (r.notes ? " \u00B7 " + r.notes : ""),
        status: r.status, notes: r.office_notes, handled_at: r.reviewed_at
      };
    }

    function load() {
      // Fetched together. If one table fails the other still shows, with the
      // failure named — a half-empty list that says nothing is how a request
      // gets missed.
      return Promise.all([
        sb.from("hall_bookings")
          .select("id,created_at,booking_date,reference,hire_type,halls_count,session_slot,hall,kitchen,deposit_status,base_amount_p,extras_p,balance_status,balance_paid_at,first_name,last_name,address,phone,status,office_notes,handled_at")
          .order("booking_date", { ascending: true }),
        sb.from("nikah_requests")
          .select("id,submitted_at,reference,preferred_date,alternative_date,slot,preferred_time,guests_estimate,contact_name,contact_role,contact_phone,contact_email,notes,status,office_notes,reviewed_at")
          .order("preferred_date", { ascending: true })
      ]).then(function (res) {
        var problems = [];
        var out = [];
        if (res[0].error) problems.push("hall bookings (" + res[0].error.message + ")");
        else out = out.concat((res[0].data || []).map(fromHall));
        if (res[1].error) {
          // Until 010_nikah_requests.sql is applied this table does not exist,
          // which is expected rather than broken. Say so plainly instead of
          // showing the office a database error they cannot act on.
          var missing = /does not exist|schema cache|relation/i.test(res[1].error.message || "");
          if (!missing) problems.push("nikāḥ requests (" + res[1].error.message + ")");
        } else {
          out = out.concat((res[1].data || []).map(fromNikah));
        }
        setError(problems.length
          ? "Couldn't load " + problems.join(" or ") + ". The rest of the list is still correct."
          : null);
        rows = out;
      });
    }

    function visible() {
      var today = todayISO();
      var out = rows.filter(function (r) {
        if (filter === "new")      return r.status === "new";
        if (filter === "upcoming") return r.status === "confirmed" && r.date >= today;
        if (filter === "halls")    return r.kind === "hall";
        if (filter === "nikah")    return r.kind === "nikah";
        if (filter === "refunds")  return r.deposit === "refund_due";
        if (filter === "balance") {
          if (r.kind !== "hall" || r.status !== "confirmed") return false;
          if (r.balance === "paid" || r.balance === "waived") return false;
          // Due 30 days before the event. Anything inside that window and
          // unpaid is what the office needs to be chasing this week.
          var days = (new Date(r.date) - Date.now()) / 86400000;
          return days <= 30;
        }
        return true;
      });
      if (query) {
        var q = query.toLowerCase();
        var digits = q.replace(/\D/g, "");
        out = out.filter(function (r) {
          var name = String(r.who || "").toLowerCase();
          var mail = String(r.email || "").toLowerCase();
          var phone = String(r.phone).replace(/\D/g, "");
          return name.indexOf(q) !== -1 || mail.indexOf(q) !== -1 ||
                 (digits.length >= 3 && phone.indexOf(digits) !== -1);
        });
      }
      // Newest requests first when triaging; soonest first when looking ahead.
      if (filter === "new") {
        out.sort(function (a, b) { return new Date(b.created_at) - new Date(a.created_at); });
      } else {
        out.sort(function (a, b) { return a.date < b.date ? -1 : a.date > b.date ? 1 : 0; });
      }
      return out;
    }

    function counts() {
      var today = todayISO();
      el("bk-n-new").textContent = rows.filter(function (r) { return r.status === "new"; }).length;
      el("bk-n-up").textContent  = rows.filter(function (r) {
        return r.status === "confirmed" && r.date >= today;
      }).length;
      var nk = el("bk-n-nk");
      if (nk) nk.textContent = rows.filter(function (r) { return r.kind === "nikah"; }).length;
      // Shown only when there is one. A tab that is always zero teaches the
      // office to stop looking at it.
      var rf = el("bk-tab-refunds");
      var due = rows.filter(function (r) { return r.deposit === "refund_due"; }).length;
      if (rf) {
        rf.hidden = due === 0;
        var n = el("bk-n-rf");
        if (n) n.textContent = due;
      }
      var bt = el("bk-tab-balance");
      var owing = rows.filter(function (r) {
        if (r.kind !== "hall" || r.status !== "confirmed") return false;
        if (r.balance === "paid" || r.balance === "waived") return false;
        return (new Date(r.date) - Date.now()) / 86400000 <= 30;
      }).length;
      if (bt) {
        bt.hidden = owing === 0;
        var bn = el("bk-n-bal");
        if (bn) bn.textContent = owing;
      }
    }

    function emptyLine() {
      if (query) return "Nothing matches “" + esc(query) + "”.";
      if (filter === "new")      return "No new requests. Anything that comes in from the website — a hall booking or a nikāḥ date — appears here.";
      if (filter === "upcoming") return "Nothing confirmed coming up.";
      if (filter === "halls")    return "No hall bookings yet.";
      if (filter === "nikah")    return "No nikāḥ requests yet.";
      if (filter === "refunds")  return "Nothing waiting for a refund.";
      if (filter === "balance")  return "Nobody owes a balance inside the next thirty days.";
      return "Nothing yet.";
    }

    // What is owed, in one line the office can read without arithmetic.
    // Extras are typed here because nothing can know them in advance: £100 if
    // the utensils were used, 45p a head if the hirer cooked.
    function moneyLine(r) {
      if (r.base === null || r.base === undefined) {
        return '<div class="bk-money"><span class="bm-none">No rate on file — ' +
               'taken under the old session charges. Ask the office what was ' +
               'agreed.</span></div>';
      }
      var bits =
        '<span class="bm-b">' + esc(money(r.base)) + '</span>' +
        '<span class="bm-k">base</span>';
      if (r.extras > 0) {
        bits += '<span class="bm-plus">+</span>' +
                '<span class="bm-b">' + esc(money(r.extras)) + '</span>' +
                '<span class="bm-k">extras</span>';
      }
      if (r.deposit === "paid") {
        bits += '<span class="bm-plus">&minus;</span>' +
                '<span class="bm-b">\u00A3100</span><span class="bm-k">deposit</span>';
      }
      var owedWord = r.balance === "paid" ? "settled"
                   : r.balance === "waived" ? "waived"
                   : "outstanding";
      bits += '<span class="bm-owed bo-' + esc(r.balance || "unpaid") + '">' +
              (r.balance === "paid" || r.balance === "waived"
                ? esc(owedWord)
                : esc(money(r.owed)) + ' ' + owedWord) + '</span>';

      return '<div class="bk-money">' + bits +
             '<label class="bm-extras">extras &pound;' +
             '<input type="number" step="0.01" min="0" data-extras value="' +
             (r.extras ? (r.extras / 100).toFixed(2) : '') +
             '" placeholder="0.00"></label>' +
             '</div>';
    }

    function render() {
      counts();
      var list = el("bk-list");
      var items = visible();
      if (!items.length) {
        list.innerHTML = '<div class="bk-empty">' + emptyLine() + "</div>";
        return;
      }
      list.innerHTML = items.map(function (r) {
        var isOpen = r.status === "new";
        // A nikāḥ is a REQUEST — the office agrees it on the phone, and the
        // wording here says so, so nobody reads "Agree date" as "already
        // booked".
        var go = r.kind === "nikah" ? "Agree date" : "Confirm";

        // A hall booking whose deposit has been paid is BOOKED. It was
        // confirmed by the payment (migration 017), not by anybody here, and
        // there is deliberately no Decline: somebody has given the masjid £100
        // and the terms now promise them the date. Undoing it is a separate,
        // reasoned act — see the Cancel & refund button below — because it
        // always means sending money back.
        var paidUp = r.kind === "hall" && r.deposit === "paid";
        return '' +
          '<article class="bk-item s-' + esc(r.status) + ' k-' + esc(r.kind) +
            '" data-id="' + esc(r.id) + '" data-kind="' + esc(r.kind) + '">' +
            '<div class="bk-when">' +
              '<span class="d">' + esc(longDate(r.date)) + '</span>' +
              '<span class="s">' + esc(r.detail) + '</span>' +
              '<span class="bk-kind t-' + esc(r.kind) + '">' +
                (r.kind === "nikah" ? "Nik\u0101\u1E25" : "Hall") + '</span>' +
              (r.deposit
                ? '<span class="bk-dep d-' + esc(r.deposit) + '">' +
                  esc(DEPOSIT_WORDS[r.deposit] || r.deposit) + '</span>'
                : '') +
              '<span class="bk-pill p-' + esc(r.status) + '">' + esc(r.status) + '</span>' +
            '</div>' +
            '<div class="bk-who">' +
              (r.reference ? '<span class="bk-ref">' + esc(r.reference) + '</span>' : '') +
              '<span class="nm">' + esc(r.who) + '</span>' +
              '<a href="tel:' + esc(String(r.phone).replace(/\s/g, "")) + '">' + esc(r.phone) + '</a>' +
              (r.email ? ' <a href="mailto:' + esc(r.email) + '">' + esc(r.email) + '</a>' : '') +
            '</div>' +
            '<div class="bk-addr">' + esc(r.sub) + '</div>' +
            (r.kind === "hall" ? moneyLine(r) : '') +
            '<div class="bk-meta">Requested ' + esc(ago(r.created_at)) +
              (r.handled_at ? ' · decided ' + esc(ago(r.handled_at)) : '') + '</div>' +
            '<textarea class="bk-notes" data-notes rows="1" placeholder="Notes — what was agreed, fee quoted, who called">' +
              esc(r.notes || "") + '</textarea>' +
            '<div class="bk-acts">' +
              (paidUp
                ? '<button type="button" class="bk-btn" data-act="save">Save notes</button>' +
                  (r.balance === "paid"
                    ? '<button type="button" class="bk-btn" data-act="balance_unpaid">Balance not paid after all</button>'
                    : '<button type="button" class="bk-btn go" data-act="balance_paid">Balance received</button>') +
                  '<button type="button" class="bk-btn no" data-act="cancel_refund">Cancel &amp; refund</button>'
                : isOpen
                  ? '<button type="button" class="bk-btn go" data-act="confirmed">' + go + '</button>' +
                    '<button type="button" class="bk-btn no" data-act="declined">Decline</button>'
                  : '<button type="button" class="bk-btn" data-act="save">Save notes</button>' +
                    (r.status === "confirmed"
                      ? '<button type="button" class="bk-btn no" data-act="cancelled">Cancel</button>'
                      : '<button type="button" class="bk-btn" data-act="new">Reopen</button>')) +
              '<span class="bk-said" data-said></span>' +
            '</div>' +
          '</article>';
      }).join("");
    }

    // Writes only the columns the office is granted (migration 017): status,
    // office_notes, handled_at, deposit_status, extras_p, balance_status and
    // balance_paid_at. Not the reference, not the Stripe session, not the base
    // rate, and nothing the hirer typed.
    function apply(id, item, act) {
      var row = rows.filter(function (r) { return String(r.id) === String(id); })[0];
      if (!row) { setError("That request is no longer in the list — reloading."); return load().then(render); }
      var notes = item.querySelector("[data-notes]").value.trim();
      var said  = item.querySelector("[data-said]");
      var btns  = item.querySelectorAll(".bk-btn");
      Array.prototype.forEach.call(btns, function (b) { b.disabled = true; });
      said.textContent = "Saving…";

      // The two tables name their "when was this dealt with" column
      // differently, and RLS only permits the office to write these few
      // columns on either. Nothing else is ever sent.
      var patch = { office_notes: notes || null };

      // The extras box is saved on every click, so a figure typed and then
      // left is not silently lost when the office presses something else.
      var xEl = item.querySelector("[data-extras]");
      if (xEl) {
        var pounds = parseFloat(xEl.value);
        patch.extras_p = isNaN(pounds) ? 0 : Math.round(pounds * 100);
      }

      if (act === "balance_paid") {
        patch.balance_status = "paid";
        patch.balance_paid_at = new Date().toISOString();
      } else if (act === "balance_unpaid") {
        patch.balance_status = "unpaid";
        patch.balance_paid_at = null;
      } else if (act === "cancel_refund") {
        // Not an UPDATE. Undoing a paid booking always means money going back,
        // so it goes through cancel_paid_booking(), which insists on a written
        // reason and writes to the audit log.
        var why = window.prompt(
          "Why is the masjid cancelling this booking?\n\n" +
          "This refunds the \u00A3100 deposit in full. The reason is recorded " +
          "in the audit log.\n\nAt least ten characters:");
        if (!why || why.trim().length < 10) {
          said.textContent = "";
          Array.prototype.forEach.call(btns, function (b) { b.disabled = false; });
          return;
        }
        return sb.rpc("cancel_paid_booking",
                      { p_reference: row.reference, p_reason: why.trim() })
          .then(function (out) {
            if (out.error) throw new Error(out.error.message);
            setError(null);
            return load().then(render);
          })
          .catch(function (e) {
            said.textContent = "";
            setError("Couldn't cancel that — " + (e && e.message) + ". Nothing was changed.");
            Array.prototype.forEach.call(btns, function (b) { b.disabled = false; });
          });
      } else if (act !== "save") {
        patch.status = act;
        patch[row.handledCol] = act === "new" ? null : new Date().toISOString();
      }
      // hall_bookings has no 'cancelled' -> nikah calls it 'withdrawn'
      if (row.kind === "nikah" && act === "cancelled") patch.status = "withdrawn";

      return sb.from(row.table).update(patch).eq("id", id)
        .then(function (res) {
          if (res.error) {
            said.textContent = "";
            setError("Couldn't save that — " + res.error.message + ". Nothing was changed.");
            Array.prototype.forEach.call(btns, function (b) { b.disabled = false; });
            return;
          }
          setError(null);
          return load().then(render);
        })
        .catch(function (e) {
          said.textContent = "";
          setError("Couldn't reach the database — " + (e && e.message) + ". Nothing was changed.");
          Array.prototype.forEach.call(btns, function (b) { b.disabled = false; });
        });
    }

    function wire() {
      el("bk-tabs").addEventListener("click", function (e) {
        var tab = e.target.closest(".bk-tab");
        if (!tab) return;
        filter = tab.dataset.filter;
        Array.prototype.forEach.call(this.querySelectorAll(".bk-tab"), function (t) {
          t.classList.toggle("on", t === tab);
        });
        render();
      });

      var search = el("bk-search");
      var t;
      search.addEventListener("input", function () {
        clearTimeout(t);
        var v = this.value.trim();
        t = setTimeout(function () { query = v; render(); }, 150);
      });

      el("bk-list").addEventListener("click", function (e) {
        var btn = e.target.closest(".bk-btn");
        if (!btn) return;
        var item = btn.closest(".bk-item");
        apply(item.dataset.id, item, btn.dataset.act);
      });
    }

    function mount(identity) {
      var panel = el("bk-panel");
      var card  = el("view-app");
      var noAcc = el("app-noaccess");

      // Somebody who signed in but holds no venue role must be told why the
      // page is empty. An empty page reads as broken.
      if (!canSee(identity)) {
        if (panel) panel.hidden = true;
        if (noAcc) noAcc.hidden = false;
        return;
      }
      if (noAcc) noAcc.hidden = true;
      if (!panel) return;
      panel.hidden = false;
      if (card) card.classList.add("is-wide");
      if (!mounted) { wire(); mounted = true; }
      load().then(render);
    }

    return { mount: mount };
  })();

  function renderApp(identity) {
    var name = identity.profile.full_name || identity.user.email;
    var roles = identity.roles.length ? identity.roles : ["no role assigned"];

    // The page points at the admin centre, because every member of staff who
    // uses it is an administrator — the masjid decided in September 2026 to
    // stop granting single-area roles and give staff admin instead.
    //
    // This puts the link back if that ever changes. /portals/ refuses anyone
    // without the admin role, so a hall_office volunteer following it would
    // land on "you have no access" — a dead end on the page they use most.
    // Four lines to make sure that day is a non-event.
    var back = el("brand-back");
    if (back && identity.roles.indexOf("admin") === -1) {
      back.setAttribute("href", "../index.html#svc-hallhire");
      back.textContent = "\u2190 Back to hall hire";
    }

    el("app-name").textContent = name;
    el("app-email").textContent = identity.user.email;

    var wrap = el("app-roles");
    wrap.innerHTML = "";
    roles.forEach(function (r) {
      var chip = document.createElement("span");
      chip.className = "role-chip role-" + r;
      chip.textContent = r;
      wrap.appendChild(chip);
    });

    var failed = identity.errors && identity.errors.length > 0;
    if (failed) {
      var box = el("app-error");
      box.textContent = "Couldn't read your account details. " + identity.errors.join(" · ");
      box.hidden = false;
    } else {
      el("app-error").hidden = true;
    }

    // Someone authenticated but with no role should be told plainly, not
    // shown an empty dashboard they'll assume is broken. Don't claim "no role"
    // when the truth is that the lookup failed.
    var norole = el("app-norole");
    if (norole) norole.hidden = true;   // this portal explains access in mount()
    show("view-app");

    // A panel that fails to load must never take the sign-in shell with it.
    try { bookings.mount(identity); } catch (e) {
      if (window.console) console.warn("bookings panel unavailable:", e);
    }
  }

  // Decides where to send someone once their password has been accepted.
  function routeAfterPassword() {
    return sb.auth.mfa.getAuthenticatorAssuranceLevel().then(function (res) {
      if (res.error) throw new Error("Couldn't check two-step status: " + res.error.message);
      var data = res.data || {};
      if (data.nextLevel === "aal2" && data.nextLevel !== data.currentLevel) {
        return startChallenge();           // factor exists, needs verifying
      }
      return sb.auth.mfa.listFactors().then(function (list) {
        if (list.error) throw new Error("Couldn't list authenticators: " + list.error.message);
        var verified = ((list.data || {}).totp) || [];
        if (verified.length === 0) return startEnrolment();  // no factor yet
        return loadIdentity().then(renderApp);
      });
    });
  }

  // --- MFA: verifying an existing factor ------------------------------------
  var pending = { factorId: null, challengeId: null };

  function startChallenge() {
    return sb.auth.mfa.listFactors().then(function (res) {
      var totp = ((res.data || {}).totp) || [];
      if (!totp.length) return startEnrolment();
      pending.factorId = totp[0].id;
      return sb.auth.mfa.challenge({ factorId: pending.factorId }).then(function (c) {
        if (c.error) throw c.error;
        pending.challengeId = c.data.id;
        setError("mfa-error", "");
        el("mfa-code").value = "";
        show("view-mfa");
        el("mfa-code").focus();
      });
    });
  }

  // --- MFA: first-time enrolment --------------------------------------------
  function startEnrolment() {
    return sb.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: "Authenticator " + new Date().toISOString().slice(0, 10)
    }).then(function (res) {
      if (res.error) throw res.error;
      pending.factorId = res.data.id;
      // Supabase returns the QR as an SVG data URI — no QR library needed.
      el("enrol-qr").src = res.data.totp.qr_code;
      el("enrol-secret").textContent = res.data.totp.secret;
      setError("enrol-error", "");
      el("enrol-code").value = "";
      show("view-enrol");
      el("enrol-code").focus();
    });
  }

  // --- sign in --------------------------------------------------------------
  el("signin-form").addEventListener("submit", function (e) {
    e.preventDefault();
    var btn = el("signin-submit");
    setError("signin-error", "");
    busy(btn, true);

    sb.auth.signInWithPassword({
      email: el("signin-email").value.trim(),
      password: el("signin-password").value
    }).then(function (res) {
      if (res.error) throw res.error;
      return routeAfterPassword();
    }).catch(function (err) {
      // Deliberately vague: confirming which half was wrong helps an attacker
      // enumerate valid masjid email addresses.
      var msg = /invalid login/i.test(err.message || "")
        ? "That email address and password don't match. Please try again."
        : (err.message || "Sign in failed. Please try again.");
      setError("signin-error", msg);
    }).finally(function () {
      busy(btn, false, "Sign in");
      el("signin-password").value = "";
    });
  });

  // --- verify existing factor -----------------------------------------------
  el("mfa-form").addEventListener("submit", function (e) {
    e.preventDefault();
    var btn = el("mfa-submit");
    setError("mfa-error", "");
    busy(btn, true);

    sb.auth.mfa.verify({
      factorId: pending.factorId,
      challengeId: pending.challengeId,
      code: el("mfa-code").value.trim()
    }).then(function (res) {
      if (res.error) throw res.error;
      return loadIdentity().then(renderApp);
    }).catch(function (err) {
      setError("mfa-error", err.message || "That code wasn't accepted. Codes expire after 30 seconds.");
      // A failed verify burns the challenge, so issue a fresh one.
      sb.auth.mfa.challenge({ factorId: pending.factorId }).then(function (c) {
        if (c.data) pending.challengeId = c.data.id;
      });
    }).finally(function () {
      busy(btn, false, "Verify");
      el("mfa-code").value = "";
    });
  });

  // --- confirm enrolment ----------------------------------------------------
  el("enrol-form").addEventListener("submit", function (e) {
    e.preventDefault();
    var btn = el("enrol-submit");
    setError("enrol-error", "");
    busy(btn, true);

    sb.auth.mfa.challenge({ factorId: pending.factorId }).then(function (c) {
      if (c.error) throw c.error;
      return sb.auth.mfa.verify({
        factorId: pending.factorId,
        challengeId: c.data.id,
        code: el("enrol-code").value.trim()
      });
    }).then(function (res) {
      if (res.error) throw res.error;
      return loadIdentity().then(renderApp);
    }).catch(function (err) {
      setError("enrol-error", err.message || "That code wasn't accepted. Please try the next one.");
    }).finally(function () {
      busy(btn, false, "Confirm and finish setup");
      el("enrol-code").value = "";
    });
  });

  // --- sign out -------------------------------------------------------------
  el("app-signout").addEventListener("click", function () {
    sb.auth.signOut().then(function () {
      el("signin-email").value = "";
      el("signin-password").value = "";
      setError("signin-error", "");
      show("view-signin");
    });
  });

  // --- restore an existing session on load ----------------------------------
  sb.auth.getSession().then(function (res) {
    if (res.data && res.data.session) {
      return routeAfterPassword().catch(function () { show("view-signin"); });
    }
    show("view-signin");
  }).catch(function () { show("view-signin"); });

  // Numeric-only, 6-digit convenience on both code fields.
  ["mfa-code", "enrol-code"].forEach(function (id) {
    el(id).addEventListener("input", function (e) {
      e.target.value = e.target.value.replace(/\D/g, "").slice(0, 6);
    });
  });
})();
