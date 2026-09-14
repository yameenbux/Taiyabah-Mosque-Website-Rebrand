/* ===========================================================================
   Taiyabah Masjid — Charity collections (chanda)
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   Migration 030 stores requests from charities and institutes asking to
   collect at the masjid — the online replacement for a paper CHARITY DATA
   FORM and a poster carrying two committee members' mobile numbers. Without
   this page the only way to read a request back would be SQL in the Supabase
   editor, which nobody in the office is going to run.

   The sign-in shell below is /volunteers/'s, unchanged. What replaces its
   panel is the collections module: the same auth, a different list.

   WHO CAN OPEN IT
   ---------------
   Administrators and hall office staff, both at aal2 — the database says the
   same thing in the policies on charity_collections, and this file only
   decides what to draw. The list carries charities' and trustees' contact
   details.
   =========================================================================== */
(function () {
  "use strict";

  var cfg = window.TAIYABAH_CONFIG || {};
  var el  = function (id) { return document.getElementById(id); };

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
      "This area isn't connected yet — config.js still has placeholder values in it.");
    var f = el("signin-form");
    if (f) Array.prototype.forEach.call(f.elements, function (i) { i.disabled = true; });
    return;
  }

  // The Supabase dashboard shows the project URL with /rest/v1/ on the end.
  // Pasting it verbatim has broken this twice, so normalise to the bare origin.
  var apiUrl = String(cfg.SUPABASE_URL || "")
                 .trim().replace(/\/+$/, "").replace(/\/rest\/v1$/, "");

  var sb = window.supabase.createClient(apiUrl, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
  });

  function loadIdentity() {
    return sb.auth.getUser().then(function (res) {
      var user = res.data && res.data.user;
      if (!user) throw new Error("No active session.");
      return Promise.all([
        sb.from("profiles").select("full_name, email").eq("id", user.id).maybeSingle(),
        sb.from("user_roles").select("role").eq("user_id", user.id)
      ]).then(function (out) {
        var errs = [];
        if (out[0].error) errs.push("profiles — " + out[0].error.message);
        if (out[1].error) errs.push("user_roles — " + out[1].error.message);
        return {
          user: user,
          profile: out[0].data || {},
          roles: (out[1].data || []).map(function (r) { return r.role; }),
          errors: errs
        };
      });
    });
  }

  /* =========================================================================
     THE CLAIM
     ======================================================================= */
  /* =========================================================================
     THE VOLUNTEER LIST

     WHAT THIS PAGE IS FOR. Migration 023 stores registrations. Until this
     page existed there was exactly one way to read them back: SQL in the
     Supabase editor — which nobody in the office is going to run, so the
     registrations would pile up unread and the form would have been a way of
     collecting people's mobile numbers for nothing.

     That mistake has now been made twice on this site: the course sign-ups in
     September, and Gift Aid the same week. Turning a form on and giving a
     human a way to read it back are two jobs, and only the first one feels
     finished.

     THE QUESTION THE COMMITTEE ACTUALLY ASKED is not "who registered" but
     "have we got enough people to open?" — so the counts are at the top and
     the list is underneath, rather than the other way round.
     ======================================================================= */
  /* =========================================================================
     CHARITY COLLECTIONS (CHANDA)

     WHAT THIS PAGE IS FOR. Migration 030 stores requests from charities and
     institutes asking to collect at the masjid. Without this screen the only
     way to read them back would be SQL in the Supabase editor, which nobody
     in the office is going to run — so the requests would pile up unread and
     the form would be a way of collecting trustees' phone numbers for
     nothing. That mistake has been made twice on this site already.

     TWO THINGS ARE NOT ADMINISTRATION AND ARE NOT DRAWN LIKE IT:

       *  A COLLECTOR WHO IS PAID. On the paper form this is a tick in a box
          on page one. It is a safeguarding and fraud control, so here it is a
          red badge on the row and a tab of its own.

       *  TWO CHARITIES ON ONE DAY. The masjid allows one collection a day.
          The public form is not told which days are taken — publishing that
          is publishing the masjid's diary — so the clash is worked out here,
          from the rows the office already holds, and shown on the row.

     WHAT THE OFFICE MAY CHANGE. Status, the agreed date and notes. NOT what
     the charity declared. That is not enforced by this file — it is enforced
     by the column list in the GRANT in 030, because a restriction that lives
     only in a screen is not a restriction.
     ======================================================================= */
  var collections = (function () {
    var rows = [];
    var filter = "open";
    var query = "";
    var mounted = false;

    function canSee(identity) {
      var r = identity.roles || [];
      return r.indexOf("admin") !== -1 || r.indexOf("hall_office") !== -1;
    }

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/[&<>"']/g, function (c) {
          return { "&": "&amp;", "<": "&lt;", ">": "&gt;",
                   '"': "&quot;", "'": "&#39;" }[c];
        });
    }

    function day(iso) {
      if (!iso) return "—";
      var d = new Date(iso + "T00:00:00");
      if (isNaN(d)) return esc(iso);
      return d.toLocaleDateString("en-GB",
        { weekday: "short", day: "numeric", month: "short", year: "numeric" });
    }

    function ago(iso) {
      if (!iso) return "";
      var mins = Math.round((Date.now() - new Date(iso).getTime()) / 60000);
      if (mins < 60) return mins + " minutes ago";
      var hrs = Math.round(mins / 60);
      if (hrs < 36) return hrs + " hours ago";
      var days = Math.round(hrs / 24);
      return days + " day" + (days === 1 ? "" : "s") + " ago";
    }

    function onDay(r) { return r.agreed_date || r.requested_date; }

    /* A clash is ANOTHER request, not withdrawn or declined, wanting the same
       day. Computed over every row the office holds rather than the filtered
       view — a clash you cannot see because of the tab you are on is worse
       than no clash detection at all. */
    function clashesFor(r) {
      return rows.filter(function (o) {
        return o.id !== r.id &&
               onDay(o) === onDay(r) &&
               ["new", "contacted", "approved"].indexOf(o.status) !== -1;
      });
    }

    function isPast(r) {
      var d = onDay(r);
      return !!d && d < new Date().toISOString().slice(0, 10);
    }

    function inFilter(r) {
      switch (filter) {
        case "open":     return ["new", "contacted"].indexOf(r.status) !== -1;
        case "approved": return r.status === "approved" && !isPast(r);
        case "paid":     return r.collector_paid &&
                                ["new", "contacted", "approved"].indexOf(r.status) !== -1;
        case "clash":    return clashesFor(r).length > 0 &&
                                ["new", "contacted", "approved"].indexOf(r.status) !== -1;
        case "past":     return isPast(r);
        default:         return true;
      }
    }

    function matches(r) {
      if (!query) return true;
      var hay = [r.reference, r.org_name, r.collector_name, r.collector_role,
                 r.org_phone, r.org_email, r.trustee_name, r.trustee_phone,
                 r.charity_number].join(" ").toLowerCase();
      return hay.indexOf(query) !== -1;
    }

    function counts() {
      function n(id, v) { var e = el(id); if (e) e.textContent = v; }
      var was = filter;
      ["open", "approved", "paid", "clash", "past", "all"].forEach(function (f) {
        filter = f;
        n("cc-n-" + f, rows.filter(inFilter).length);
      });
      filter = was;
    }

    function renderSummary() {
      var open = rows.filter(function (r) {
        return ["new", "contacted"].indexOf(r.status) !== -1; }).length;
      var paid = rows.filter(function (r) {
        return r.collector_paid &&
               ["new", "contacted", "approved"].indexOf(r.status) !== -1; }).length;
      var clash = rows.filter(function (r) {
        return clashesFor(r).length > 0 &&
               ["new", "contacted", "approved"].indexOf(r.status) !== -1; }).length;
      var next = rows.filter(function (r) {
        return r.status === "approved" && !isPast(r); })
        .map(onDay).sort()[0];

      //  .ga-sum's own markup — <span class="n"> then <span class="k"> — not
      //  a shape invented here. A summary that looks like a different
      //  website's is how /volunteers/ and this screen drift apart.
      el("cc-sum").innerHTML =
        '<div class="big"><span class="n">' + open + '</span>' +
          '<span class="k">To answer</span></div>' +
        '<div><span class="n">' + (next ? day(next) : "—") + '</span>' +
          '<span class="k">Next approved</span></div>' +
        '<div><span class="n">' + paid + '</span>' +
          '<span class="k">Paid collectors</span></div>' +
        '<div><span class="n">' + clash + '</span>' +
          '<span class="k">Same-day clashes</span></div>';

      el("cc-retain").textContent =
        "Requests are deleted twelve months after they are declined, withdrawn or " +
        "finished with. " + rows.length + " held now.";
    }

    var STATUS_LABEL = {
      "new": "New", "contacted": "Rung", "approved": "Approved",
      "declined": "Declined", "withdrawn": "Withdrawn", "completed": "Done"
    };

    /* A UK charity number is digits, sometimes with a -N suffix. Only then is
       it worth linking: an overseas cause typing its own registration number
       would otherwise get a link to a Charity Commission page that does not
       exist, which looks like the masjid checked and found nothing. */
    function charityNumberHtml(num) {
      if (!num) return '<span style="color:var(--muted);">not given</span>';
      var clean = String(num).replace(/\s/g, "");
      if (/^[0-9]{6,7}(-[0-9]{1,2})?$/.test(clean)) {
        return esc(num) + ' &middot; <a target="_blank" rel="noopener" href="' +
          'https://register-of-charities.charitycommission.gov.uk/en/charity-search/-/results/page/1/delta/20?p_p_id=uk_gov_ccew_onereg_charitydetails_web_portlet_CharityDetailsPortlet&keywords=' +
          encodeURIComponent(clean) + '">check the register</a>';
      }
      return esc(num) +
        ' <span style="color:var(--muted);">(not a UK charity number &mdash; check by hand)</span>';
    }

    function render() {
      counts();
      renderSummary();

      var shown = rows.filter(inFilter).filter(matches).sort(function (a, b) {
        return String(onDay(a)).localeCompare(String(onDay(b)));
      });

      var list = el("cc-list");
      if (!shown.length) {
        list.innerHTML = '<div class="vol-empty">Nothing here.</div>';
        return;
      }

      list.innerHTML = shown.map(function (r) {
        var clash = clashesFor(r);
        return '' +
        '<div class="vol-row" data-id="' + esc(r.id) + '">' +
          '<div class="vol-top">' +
            '<span class="vol-name">' + esc(r.org_name) + '</span>' +
            '<span class="vol-ref">' + esc(r.reference) + '</span>' +
          '</div>' +
          '<div class="vol-facts">' +
            '<span class="hi">' + day(onDay(r)) + '</span>' +
            '<span class="cc-status s-' + esc(r.status) + '">' +
              esc(STATUS_LABEL[r.status] || r.status) + '</span>' +
            (r.collector_paid
              ? '<span class="cc-paid">&#9888; Collector is paid</span>' : '') +
            '<span>Came in ' + esc(ago(r.submitted_at)) + '</span>' +
          '</div>' +

          (clash.length
            ? '<div class="cc-clash"><span aria-hidden="true">&#9888;</span><span>' +
                'Another request already wants ' + day(onDay(r)) + ': ' +
                clash.map(function (o) {
                  return esc(o.org_name) + ' (' + esc(o.reference) + ', ' +
                         esc(STATUS_LABEL[o.status] || o.status) + ')';
                }).join("; ") +
                '. The masjid allows one collection a day.</span></div>'
            : '') +

          '<div class="vol-contact">' +
            esc(r.collector_name) + ' &middot; ' + esc(r.collector_role) +
            ' &mdash; <a href="tel:' + esc(r.org_phone) + '">' + esc(r.org_phone) + '</a>' +
            ' &middot; <a href="mailto:' + esc(r.org_email) + '">' + esc(r.org_email) + '</a>' +
          '</div>' +

          '<details class="cc-more"><summary>The rest of the form</summary>' +
            '<dl class="cc-dl">' +
              '<dt>Address</dt><dd>' + esc(r.org_address) + '</dd>' +
              '<dt>Charity number</dt><dd>' + charityNumberHtml(r.charity_number) + '</dd>' +
              '<dt>Trustee</dt><dd>' + esc(r.trustee_name) +
                ' &mdash; <a href="tel:' + esc(r.trustee_phone) + '">' +
                esc(r.trustee_phone) + '</a> &middot; <a href="mailto:' +
                esc(r.trustee_email) + '">' + esc(r.trustee_email) + '</a></dd>' +
              '<dt>Wage or commission</dt><dd>' +
                (r.collector_paid ? '<b>Yes &mdash; they are paid for this</b>' : 'No') +
                '</dd>' +
              '<dt>Signed</dt><dd>' + esc(r.signed_name) +
                ' &middot; rules version ' + esc(r.rules_version) + '</dd>' +
              '<dt>Requested</dt><dd>' + day(r.requested_date) +
                (r.agreed_date && r.agreed_date !== r.requested_date
                  ? ' &middot; agreed for ' + day(r.agreed_date) : '') + '</dd>' +
            '</dl>' +
            '<textarea class="cc-notes" data-notes="' + esc(r.id) +
              '" placeholder="Office notes — what was said when you rang">' +
              esc(r.office_notes || "") + '</textarea>' +
          '</details>' +

          '<div class="vol-acts">' +
            '<button type="button" data-act="contacted" data-id="' + esc(r.id) + '">Rung them</button>' +
            '<button type="button" data-act="approved"  data-id="' + esc(r.id) + '">Approve</button>' +
            '<button type="button" data-act="declined"  data-id="' + esc(r.id) + '">Decline</button>' +
            '<button type="button" data-act="completed" data-id="' + esc(r.id) + '">Collection done</button>' +
            '<button type="button" data-act="notes"     data-id="' + esc(r.id) + '">Save notes</button>' +
          '</div>' +
        '</div>';
      }).join("");
    }

    function csv() {
      /* The office asked for this so a committee meeting can see a year of
         collections on one sheet. It carries trustees' phone numbers, so it
         is a file somebody has to look after — which is why the button says
         what it downloads rather than just "Export". */
      function cell(v) {
        var t = String(v === null || v === undefined ? "" : v);
        return /[",\n]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t;
      }
      var head = ["Reference", "Requested", "Agreed", "Status", "Charity",
                  "Charity number", "Address", "Phone", "Email",
                  "Collector", "Role", "Paid?", "Trustee", "Trustee phone",
                  "Trustee email", "Signed", "Rules version", "Notes"];
      var body = rows.map(function (r) {
        return [r.reference, r.requested_date, r.agreed_date || "", r.status,
                r.org_name, r.charity_number || "", r.org_address, r.org_phone,
                r.org_email, r.collector_name, r.collector_role,
                r.collector_paid ? "YES" : "no", r.trustee_name, r.trustee_phone,
                r.trustee_email, r.signed_name, r.rules_version,
                r.office_notes || ""].map(cell).join(",");
      });
      var blob = new Blob([head.join(",") + "\n" + body.join("\n")],
                          { type: "text/csv;charset=utf-8" });
      var a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "taiyabah-collections-" +
                   new Date().toISOString().slice(0, 10) + ".csv";
      document.body.appendChild(a); a.click();
      setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 0);
    }

    function load() {
      return sb.from("charity_collections")
        .select("id,reference,submitted_at,requested_date,agreed_date,status," +
                "org_name,org_address,org_phone,org_email,charity_number," +
                "collector_name,collector_role,collector_paid," +
                "trustee_name,trustee_phone,trustee_email," +
                "rules_version,signed_name,office_notes")
        .order("requested_date", { ascending: true })
        .then(function (res) {
          if (res.error) throw res.error;
          rows = res.data || [];
          render();
        });
    }

    function act(id, action, btn) {
      var patch;
      if (action === "notes") {
        var box = document.querySelector('[data-notes="' + id + '"]');
        patch = { office_notes: box ? box.value : "" };
      } else {
        patch = { status: action };
        /* Approving is the moment the date becomes the masjid's answer, so
           that is when the requested date is copied into agreed_date. Leaving
           it null and reading requested_date everywhere would mean the office
           could never record "yes, but the week after". */
        var row = rows.filter(function (r) { return r.id === id; })[0];
        if (action === "approved" && row && !row.agreed_date) {
          patch.agreed_date = row.requested_date;
        }
      }
      patch.reviewed_at = new Date().toISOString();

      if (btn) { btn.disabled = true; }
      return sb.from("charity_collections").update(patch).eq("id", id)
        .then(function (res) {
          if (res.error) throw res.error;
          setError("cc-error", "");
          return load();
        })
        .catch(function (e) {
          setError("cc-error",
            "That did not save — " + (e.message || e) +
            ". Nothing has been changed.");
        })
        .then(function () { if (btn) btn.disabled = false; });
    }

    function mount(identity) {
      if (!canSee(identity)) return;
      el("cc-panel").hidden = false;
      if (mounted) { load(); return; }
      mounted = true;

      el("cc-tabs").addEventListener("click", function (e) {
        var b = e.target.closest(".bk-tab");
        if (!b) return;
        filter = b.dataset.filter;
        Array.prototype.forEach.call(el("cc-tabs").children, function (t) {
          t.classList.toggle("on", t === b);
        });
        render();
      });

      el("cc-search").addEventListener("input", function (e) {
        query = (e.target.value || "").trim().toLowerCase();
        render();
      });

      el("cc-csv").addEventListener("click", csv);

      el("cc-list").addEventListener("click", function (e) {
        var b = e.target.closest("button[data-act]");
        if (!b) return;
        act(b.dataset.id, b.dataset.act, b);
      });

      load().catch(function (e) {
        setError("cc-error",
          "The collection requests could not be loaded — " + (e.message || e));
      });
    }

    return { mount: mount };
  })();

  function renderApp(identity) {
    el("app-name").textContent  = identity.profile.full_name || identity.user.email;
    el("app-email").textContent = identity.user.email;

    var roles = identity.roles.length ? identity.roles : ["no role assigned"];
    var wrap = el("app-roles");
    wrap.innerHTML = "";
    roles.forEach(function (r) {
      var chip = document.createElement("span");
      chip.className = "role-chip role-" + r;
      chip.textContent = r.replace(/_/g, " ");
      wrap.appendChild(chip);
    });

    if (identity.errors && identity.errors.length) {
      var box = el("app-error");
      box.textContent = "Couldn't read your account details. " + identity.errors.join(" · ");
      box.hidden = false;
    } else {
      el("app-error").hidden = true;
    }

    show("view-app");

    // A panel that fails to load must never take the sign-in shell with it.
    try { collections.mount(identity); } catch (e) {
      if (window.console) console.warn("collections panel unavailable:", e);
    }
  }

  // Decides where to send someone once their password has been accepted.
  function routeAfterPassword() {
    return sb.auth.mfa.getAuthenticatorAssuranceLevel().then(function (res) {
      if (res.error) throw new Error("Couldn't check two-step status: " + res.error.message);
      var data = res.data || {};
      if (data.nextLevel === "aal2" && data.nextLevel !== data.currentLevel) {
        return startChallenge();
      }
      return sb.auth.mfa.listFactors().then(function (list) {
        if (list.error) throw new Error("Couldn't list authenticators: " + list.error.message);
        var verified = ((list.data || {}).totp) || [];
        if (verified.length === 0) return startEnrolment();
        return loadIdentity().then(renderApp);
      });
    });
  }

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

  function startEnrolment() {
    return sb.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: "Authenticator " + new Date().toISOString().slice(0, 10)
    }).then(function (res) {
      if (res.error) throw res.error;
      pending.factorId = res.data.id;
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
      sb.auth.mfa.challenge({ factorId: pending.factorId }).then(function (c) {
        if (c.data) pending.challengeId = c.data.id;
      });
    }).finally(function () {
      busy(btn, false, "Verify");
      el("mfa-code").value = "";
    });
  });

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

  ["mfa-code", "enrol-code"].forEach(function (id) {
    el(id).addEventListener("input", function (e) {
      e.target.value = e.target.value.replace(/\D/g, "").slice(0, 6);
    });
  });
})();
