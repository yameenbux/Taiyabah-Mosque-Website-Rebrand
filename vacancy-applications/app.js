/* ===========================================================================
   Taiyabah Masjid — Vacancy applications
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   Migration 176 records who has applied through the Vacancies page before
   any role is actually open. Without this page the only way to read them
   back would be SQL in the Supabase editor — which nobody in the office is
   going to run, so the applications would pile up unread and the form would
   be a way of collecting people's details for nothing. That exact mistake
   has already been made twice on this site — see volunteers/app.js's header
   — and this is the third form it would have happened to.

   WHAT NEVER REACHES AN EMAIL. notify's vacancy_applied message deliberately
   leaves out whatever the applicant wrote about themselves — see messages.ts.
   This screen is the only place it is ever read.

   WHO CAN OPEN IT
   ---------------
   Administrators only, not hall office. db/176 is explicit that recruitment
   is the committee's own decision, unlike the Food Bank rota the hall office
   already runs day to day. The database says the same thing in the policies
   on vacancy_applications; this only decides what to draw.
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
     POSTED VACANCIES (db/177)

     What is actually live on the Vacancies page, not who has applied to it —
     that is the separate list just below. One form does both create and
     edit, the same shape as save_vacancy() itself: posting again with the
     same key updates it, and is_open is never touched by this form at all —
     only set_vacancy_open() changes that, so editing a closed role can never
     silently put it back on the site.
     ======================================================================= */
  var postings = (function () {
    var rows = [];
    var editingKey = null; // null while the form is closed or creating new
    var mounted = false;

    function canSee(identity) { return identity.roles.indexOf("admin") !== -1; }

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/[&<>"']/g, function (c) {
          return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;",
                    '"': "&quot;", "'": "&#39;" })[c];
        });
    }

    var CATEGORY = {
      administration: "Administration", education: "Education",
      community_outreach: "Community Outreach", event_management: "Event Management"
    };

    // One responsibility/requirement per line — matches check_vacancy_page()'s
    // own shape (an array of short strings), without asking the office to
    // build a list one row at a time.
    function linesToArray(text) {
      return (text || "").split("\n").map(function (s) { return s.trim(); })
                         .filter(function (s) { return s; });
    }
    function arrayToLines(arr) { return (arr || []).join("\n"); }

    function render() {
      var list = el("vac-list");
      if (!list) return;
      if (!rows.length) {
        list.innerHTML = '<div class="vol-empty">Nothing posted yet. ' +
          'Every area still shows "Coming soon" on the Vacancies page.</div>';
        return;
      }
      list.innerHTML = rows.map(function (v) {
        var page = v.page || {};
        return '<div class="vol-row" data-key="' + esc(v.key) + '">' +
          '<div class="vol-top"><span class="vol-name">' + esc(v.title) + "</span>" +
            '<span class="vol-ref">' + (v.is_open ? "Open" : "Closed") + "</span></div>" +
          '<div class="vol-facts">' +
            "<span>" + esc(CATEGORY[v.category] || v.category) + "</span>" +
            '<span class="' + (v.applicants ? "hi" : "") + '">' +
              (v.applicants || 0) + (v.applicants === 1 ? " applicant" : " applicants") +
            "</span>" +
          "</div>" +
          '<div class="vol-skills">' + esc(v.summary) + "</div>" +
          '<div class="vol-acts">' +
            '<button type="button" data-act="edit">Edit</button>' +
            '<button type="button" data-act="toggle">' + (v.is_open ? "Close" : "Reopen") + "</button>" +
          "</div>" +
        "</div>";
      }).join("");
    }

    function load() {
      setError("vac-error", "");
      return sb.rpc("vacancies_admin_list").then(function (res) {
        if (res.error) throw res.error;
        rows = res.data || [];
        render();
      }).catch(function (err) {
        setError("vac-error", "Couldn't load the posted vacancies. " + (err.message || ""));
      });
    }

    function openForm(v) {
      editingKey = v ? v.key : null;
      el("vac-f-key").value = v ? v.key : "";
      el("vac-f-title").value = v ? v.title : "";
      el("vac-f-category").value = v ? v.category : "administration";
      el("vac-f-summary").value = v ? v.summary : "";
      var page = (v && v.page) || {};
      el("vac-f-resp").value = arrayToLines(page.responsibilities);
      el("vac-f-reqs").value = arrayToLines(page.requirements);
      el("vac-f-commit").value = page.commitment || "";
      el("vac-f-closing").value = page.closing_date || "";
      setError("vac-f-error", "");
      el("vac-f-submit").textContent = v ? "Save changes" : "Post Vacancy";
      el("vac-form").hidden = false;
      el("vac-f-title").focus();
    }

    function closeForm() {
      editingKey = null;
      el("vac-form").hidden = true;
      el("vac-form").reset();
    }

    function wire() {
      if (mounted) return;
      mounted = true;

      el("vac-new").addEventListener("click", function () { openForm(null); });
      el("vac-f-cancel").addEventListener("click", closeForm);

      el("vac-list").addEventListener("click", function (e) {
        var btn = e.target.closest ? e.target.closest("button[data-act]") : null;
        if (!btn) return;
        var row = btn.closest(".vol-row");
        var key = row && row.getAttribute("data-key");
        var v = rows.filter(function (r) { return r.key === key; })[0];
        if (!v) return;

        if (btn.getAttribute("data-act") === "edit") { openForm(v); return; }

        // Reopening a role is reversible by design (set_vacancy_open(), not
        // a delete) — but a close takes an active posting off the live site,
        // so it gets the same "are you sure" every other one-way action on
        // this site asks for.
        if (!v.is_open || window.confirm(
              'Close "' + v.title + '"? It will come off the Vacancies page ' +
              "immediately. You can reopen it later.")) {
          Array.prototype.forEach.call(row.querySelectorAll("button"), function (b) {
            b.disabled = true;
          });
          sb.rpc("set_vacancy_open", { p_key: key, p_open: !v.is_open })
            .then(function (res) {
              if (res.error) throw res.error;
              return load();
            }).catch(function (err) {
              setError("vac-error", "Couldn't change that. " + (err.message || ""));
              Array.prototype.forEach.call(row.querySelectorAll("button"), function (b) {
                b.disabled = false;
              });
            });
        }
      });

      el("vac-form").addEventListener("submit", function (e) {
        e.preventDefault();
        setError("vac-f-error", "");

        var resp = linesToArray(el("vac-f-resp").value);
        if (!resp.length) {
          setError("vac-f-error", "List at least one responsibility.");
          return;
        }

        var payload = {
          key: editingKey || el("vac-f-title").value.trim().toLowerCase()
                 .replace(/[^a-z0-9]+/g, "_").replace(/^_+|_+$/g, "").slice(0, 40),
          category: el("vac-f-category").value,
          title: el("vac-f-title").value.trim(),
          summary: el("vac-f-summary").value.trim(),
          page: {
            responsibilities: resp,
            requirements: linesToArray(el("vac-f-reqs").value),
            commitment: el("vac-f-commit").value.trim() || null,
            closing_date: el("vac-f-closing").value || null
          }
        };

        var btn = el("vac-f-submit");
        busy(btn, true);
        sb.rpc("save_vacancy", { p: payload }).then(function (res) {
          if (res.error) throw res.error;
          closeForm();
          return load();
        }).catch(function (err) {
          setError("vac-f-error", err.message || "Couldn't save that.");
        }).finally(function () {
          busy(btn, false, editingKey ? "Save changes" : "Post Vacancy");
        });
      });
    }

    return {
      mount: function (identity) {
        var panel = el("vac-panel");
        if (!canSee(identity)) { if (panel) panel.hidden = true; return; }
        if (panel) panel.hidden = false;
        wire();
        load();
      }
    };
  })();

  /* =========================================================================
     THE APPLICATION LIST

     THE QUESTION THE COMMITTEE ACTUALLY ASKED is not "who has applied" but
     "which areas have interest ready to tap, once we decide to advertise
     one?" — so the per-area breakdown sits in the summary, above the list,
     rather than being something somebody has to count by hand.
     ======================================================================= */
  var vacancies = (function () {
    var rows = [];
    var summary = {};
    var filter = "all";
    var search = "";
    var mounted = false;

    // ADMIN ONLY. Not hall_office — see this file's header and db/176's own.
    function canSee(identity) {
      return identity.roles.indexOf("admin") !== -1;
    }

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/[&<>"']/g, function (c) {
          return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;",
                    '"': "&quot;", "'": "&#39;" })[c];
        });
    }

    function when(iso) {
      if (!iso) return "—";
      var d = new Date(iso);
      if (isNaN(d)) return "—";
      // Built from the parts rather than toLocaleDateString: the office reads
      // this in Bolton and the browser's locale is not a promise.
      var m = ["Jan","Feb","Mar","Apr","May","Jun",
               "Jul","Aug","Sep","Oct","Nov","Dec"];
      return d.getDate() + " " + m[d.getMonth()] + " " + d.getFullYear();
    }

    // Twelve months after they applied, to the day — db/176's own retention
    // period. The office should be able to see when somebody is about to
    // drop off the list rather than discover it afterwards.
    function goesOn(iso) {
      if (!iso) return "—";
      var d = new Date(iso);
      if (isNaN(d)) return "—";
      d.setFullYear(d.getFullYear() + 1);
      return when(d.toISOString());
    }

    //  THE FOUR VACANCIES TILES, db/176's own CHECK constraint spelled out as
    //  words a person reads. Matches messages.ts's CATEGORIES byte for byte.
    var CATEGORY = {
      administration: "Administration", education: "Education",
      community_outreach: "Community Outreach", event_management: "Event Management"
    };
    var STATE = { waiting: "Not contacted yet", contacted: "Contacted",
                  shortlisted: "Shortlisted", declined: "Declined" };

    function matches(r) {
      if (filter === "waiting"     && r.status !== "waiting") return false;
      if (filter === "contacted"   && r.status !== "contacted") return false;
      if (filter === "shortlisted" && r.status !== "shortlisted") return false;
      if (filter === "declined"    && r.status !== "declined") return false;
      if (!search) return true;
      var hay = [r.full_name, r.phone, r.email, r.message,
                 CATEGORY[r.category] || r.category, r.reference]
                  .join(" ").toLowerCase();
      return hay.indexOf(search) !== -1;
    }

    function counts() {
      function n(id, v) { var e = el(id); if (e) e.textContent = v; }
      n("va-n-all",         rows.length);
      n("va-n-waiting",     rows.filter(function (r) { return r.status === "waiting"; }).length);
      n("va-n-contacted",   rows.filter(function (r) { return r.status === "contacted"; }).length);
      n("va-n-shortlisted", rows.filter(function (r) { return r.status === "shortlisted"; }).length);
      n("va-n-declined",    rows.filter(function (r) { return r.status === "declined"; }).length);
    }

    function renderSummary() {
      var s = summary || {};
      var box = el("va-sum");
      if (box) box.innerHTML =
        '<div class="big"><span class="n">' + (s.total || 0) + '</span>' +
          '<span class="k">Applied so far</span></div>' +
        '<div><span class="n">' + (s.waiting || 0) + '</span>' +
          '<span class="k">Still to contact</span></div>' +
        '<div><span class="n">' + (s.shortlisted || 0) + '</span>' +
          '<span class="k">Shortlisted</span></div>' +
        '<div><span class="n">' + (s.declined || 0) + '</span>' +
          '<span class="k">Declined</span></div>';

      // Not counting anybody declined — the same reasoning as "Willing to
      // help" on the Food Bank screen: a figure that quietly includes people
      // who are out of the running is the kind of number a committee decides
      // on and then regrets.
      var cats = el("va-categories");
      if (cats) cats.textContent =
        "Interest ready to tap, once an area is advertised — Administration " +
        (s.administration || 0) + " · Education " + (s.education || 0) +
        " · Community Outreach " + (s.community_outreach || 0) +
        " · Event Management " + (s.event_management || 0) + ".";

      var ret = el("va-retain");
      if (ret) ret.textContent =
        "Applications are deleted twelve months after they arrive, automatically. " +
        "Each card below shows the date its application goes.";
    }

    function render() {
      counts();
      var list = el("va-list");
      if (!list) return;
      var shown = rows.filter(matches);

      if (!shown.length) {
        list.innerHTML = '<div class="vol-empty">' +
          (rows.length ? "Nobody matches that." :
           "Nobody has applied yet. The form is on the Vacancies page under Services.") +
          "</div>";
        return;
      }

      list.innerHTML = shown.map(function (r) {
        var reach = '<a href="tel:' + esc(String(r.phone).replace(/\s/g, "")) + '">' +
                    esc(r.phone) + "</a>" +
                    (r.email
                      ? ' &middot; <a href="mailto:' + esc(r.email) + '">' + esc(r.email) + "</a>"
                      : "");

        // db/177 — a FULL application against a posted role, not the 176
        // interest form. role_title is only ever set on that kind of row.
        var full = !!r.vacancy_id;
        var address = [r.address_line1, r.address_line2, r.town, r.postcode]
                        .filter(function (p) { return p; }).map(esc).join(", ");

        return '<div class="vol-row" data-ref="' + esc(r.reference) + '">' +
          '<div class="vol-top"><span class="vol-name">' + esc(r.full_name) + "</span>" +
            '<span class="vol-ref">' + esc(r.reference) + "</span></div>" +
          '<div class="vol-facts">' +
            '<span class="' + (r.status === "waiting" ? "hi" : "") + '">' +
              esc(STATE[r.status] || r.status) + "</span>" +
            "<span>" + esc(CATEGORY[r.category] || r.category) + "</span>" +
            (full ? '<span class="hi">Applied for ' + esc(r.role_title) + "</span>" : "") +
          "</div>" +
          '<div class="vol-contact">' + reach + "</div>" +
          (full ? '<div class="vol-skills">' + address +
              (r.date_of_birth ? " &middot; born " + esc(when(r.date_of_birth)) : "") +
            "</div>" : "") +
          // Whatever they wrote about themselves — the one thing this screen
          // holds that notify's office email never carries. See this file's
          // header and the comment on Event.category in messages.ts.
          (r.message ? '<div class="vol-skills">' + esc(r.message) + "</div>" : "") +
          (r.note ? '<div class="vol-note">' + esc(r.note) + "</div>" : "") +
          '<div class="vol-skills" style="margin-top:6px;">Applied ' + esc(when(r.created_at)) +
            " &middot; deleted " + esc(goesOn(r.created_at)) + "</div>" +
          '<div class="vol-acts">' +
            (full ? '<button type="button" data-act="cv">Download CV</button>' : "") +
            '<button type="button" data-act="contacted">Contacted</button>' +
            '<button type="button" data-act="shortlisted">Shortlist</button>' +
            '<button type="button" data-act="declined">Decline</button>' +
            '<button type="button" data-act="waiting">Back to waiting</button>' +
          "</div>" +
        "</div>";
      }).join("");
    }

    function csv() {
      //  No cv_path column — a Storage path means nothing outside Supabase
      //  and is private (RLS, see db/177); the Download CV button fetches a
      //  fresh signed link instead of handing one out in a batch export.
      var head = ["Reference", "Name", "Phone", "Email", "Area", "Role applied for",
                  "Address", "Date of birth", "Status", "What they wrote",
                  "Office note", "Applied", "Deleted on"];
      function cell(v) {
        var t = v === null || v === undefined ? "" : String(v);
        return /[",\n]/.test(t) ? '"' + t.replace(/"/g, '""') + '"' : t;
      }
      var body = rows.filter(matches).map(function (r) {
        var address = [r.address_line1, r.address_line2, r.town, r.postcode]
                        .filter(function (p) { return p; }).join(", ");
        return [r.reference, r.full_name, r.phone, r.email || "",
                CATEGORY[r.category] || r.category, r.role_title || "",
                address, r.date_of_birth ? when(r.date_of_birth) : "", r.status,
                r.message || "", r.note || "", when(r.created_at), goesOn(r.created_at)]
               .map(cell).join(",");
      });
      return head.join(",") + "\n" + body.join("\n") + "\n";
    }

    function load() {
      setError("va-error", "");
      return Promise.all([
        sb.from("vacancy_applications")
          .select("reference, full_name, phone, email, category, message, " +
                  "status, note, created_at, vacancy_id, role_title, " +
                  "address_line1, address_line2, town, postcode, " +
                  "date_of_birth, cv_path")
          .order("created_at", { ascending: false }),
        sb.rpc("vacancy_application_summary")
      ]).then(function (out) {
        if (out[0].error) throw out[0].error;
        rows = out[0].data || [];
        summary = (out[1] && out[1].data) || {};
        renderSummary();
        render();
      }).catch(function (err) {
        setError("va-error",
          "Couldn't load the application list. " + (err.message || ""));
      });
    }

    function wire() {
      if (mounted) return;
      mounted = true;

      var tabs = el("va-tabs");
      if (tabs) tabs.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest(".bk-tab") : null;
        if (!b) return;
        filter = b.getAttribute("data-filter");
        Array.prototype.forEach.call(tabs.querySelectorAll(".bk-tab"), function (t) {
          t.classList.toggle("on", t === b);
        });
        render();
      });

      var box = el("va-search");
      if (box) box.addEventListener("input", function () {
        search = (box.value || "").trim().toLowerCase();
        render();
      });

      var list = el("va-list");
      if (list) list.addEventListener("click", function (e) {
        var btn = e.target.closest ? e.target.closest("button[data-act]") : null;
        if (!btn) return;
        var row = btn.closest(".vol-row");
        if (!row) return;
        var ref = row.getAttribute("data-ref");
        var act = btn.getAttribute("data-act");

        // Not a status change — a signed, time-limited link to the one file
        // in this list, fetched fresh each click rather than once up front:
        // the same reasoning as collections/app.js's own BMCC certificate
        // link, and for the same reason the bucket is private at all.
        if (act === "cv") {
          var r = rows.filter(function (x) { return x.reference === ref; })[0];
          if (!r || !r.cv_path) return;
          btn.disabled = true;
          sb.storage.from("vacancy-cvs").createSignedUrl(r.cv_path, 300)
            .then(function (res) {
              if (res.error) throw res.error;
              window.open(res.data.signedUrl, "_blank", "noopener");
            }).catch(function (err) {
              setError("va-error", "Couldn't open the CV. " + (err.message || ""));
            }).finally(function () { btn.disabled = false; });
          return;
        }

        // A note is optional, and cancelling the prompt must not cancel the
        // status change — the office rang them either way.
        var note = null;
        if (act === "contacted" || act === "declined") {
          note = window.prompt(act === "declined"
            ? "Anything worth recording about why? (optional)"
            : "Anything worth recording from the call? (optional)", "");
        }

        Array.prototype.forEach.call(row.querySelectorAll("button"), function (b) {
          b.disabled = true;
        });

        sb.rpc("set_vacancy_application_status", {
          p_reference: ref, p_status: act, p_note: note || null
        }).then(function (res) {
          if (res.error) throw res.error;
          return load();
        }).catch(function (err) {
          setError("va-error", "Couldn't update that. " + (err.message || ""));
          Array.prototype.forEach.call(row.querySelectorAll("button"), function (b) {
            b.disabled = false;
          });
        });
      });

      var dl = el("va-csv");
      if (dl) dl.addEventListener("click", function () {
        // The file holds people's phone numbers and email addresses, so it is
        // a deliberate act with a dated filename rather than something that
        // happens on load.
        var blob = new Blob([csv()], { type: "text/csv;charset=utf-8" });
        var a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = "vacancy-applications-" +
                     new Date().toISOString().slice(0, 10) + ".csv";
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
        setTimeout(function () { URL.revokeObjectURL(a.href); }, 1000);
      });
    }

    return {
      mount: function (identity) {
        var panel = el("va-panel");
        var noaccess = el("app-noaccess");
        if (!canSee(identity)) {
          if (panel) panel.hidden = true;
          if (noaccess) noaccess.hidden = false;
          return;
        }
        if (noaccess) noaccess.hidden = true;
        if (panel) panel.hidden = false;
        wire();
        load();
      }
    };
  })();

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'vacancies',
        title:   'Vacancy applications',
        roles:   identity.roles || [],
        name:    (identity.profile && identity.profile.full_name) || "",
        email:   (identity.user && identity.user.email) || ""
      });
    }

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

    // A panel that fails to load must never take the sign-in shell with it,
    // or take the other panel with it either — two independent try blocks.
    try { postings.mount(identity); } catch (e) {
      if (window.console) console.warn("posted vacancies panel unavailable:", e);
    }
    try { vacancies.mount(identity); } catch (e) {
      if (window.console) console.warn("vacancy applications panel unavailable:", e);
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
