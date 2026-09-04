/* ===========================================================================
   Taiyabah Masjid — Adult classes: who has signed up
   Bolton Central Islamic Society · Registered charity 1041569

   Why this is its own area rather than a third tab in /venue/
   -----------------------------------------------------------
   The venue portal is a triage queue. Every row in it is a date somebody has
   asked for, sorted by that date, waiting for the office to ring back and
   agree it. "New requests", "Upcoming", "Confirm", "Decline" — the whole page
   is built around a date and a decision.

   A class sign-up has neither. There is no date to sort by, and there is
   nothing for the office to agree: register_for_course() has already decided,
   inside a lock, whether the person got a place or went on the waiting list.
   What the office needs here is a register — who is on the Wednesday women's
   Arabic class, how many seats are left, who to ring when one comes free.

   Forcing that into the venue portal would have meant showing a sign-up under
   a meaningless headline date, next to four buttons that do not apply to it.
   So: a separate area, listed alongside the others in the admin centre.

   Security notes for anyone maintaining this
   ------------------------------------------
     - Only the anon key is used. RLS is the access control; nothing here is
       trusted to protect anything.
     - The office may write exactly four columns — status, office_notes,
       reviewed_by, reviewed_at (grant in 009). It cannot edit a name, an
       email or the course somebody signed up for. If those are wrong the
       registration is withdrawn and re-entered, so the record always shows
       what the person actually sent.
     - `outcome` is NOT one of those four. Giving somebody a place goes through
       promote_from_waiting() (migration 013), which retakes the capacity lock
       and refuses if the session is full. That is deliberate: a browser must
       never be able to put a sixteenth person in a room that holds fifteen.
     - Nobody can delete. Retention is handled by a scheduled purge.
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
     THE REGISTER
     ======================================================================= */
  var register = (function () {
    var courses = [];      // rows from public.courses
    var rows = [];         // rows from public.course_registrations
    var filter = "all";    // 'all' or a course key
    var query = "";
    var showClosed = false;
    var mounted = false;
    var me = null;

    var COHORTS = { mens: "Men’s", womens: "Women’s", all: "Everyone" };
    var STATUS_WORDS = {
      active: "on the list", withdrawn: "withdrawn",
      attended: "attended", no_show: "did not attend"
    };

    function canSee(identity) {
      return identity.roles.indexOf("admin") !== -1;
    }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function ago(ts) {
      var mins = Math.floor((Date.now() - new Date(ts).getTime()) / 60000);
      if (mins < 2) return "just now";
      if (mins < 60) return mins + " minutes ago";
      var hrs = Math.floor(mins / 60);
      if (hrs < 24) return hrs === 1 ? "an hour ago" : hrs + " hours ago";
      var days = Math.floor(hrs / 24);
      if (days === 1) return "yesterday";
      if (days < 31) return days + " days ago";
      var months = Math.round(days / 30);
      return months === 1 ? "a month ago" : months + " months ago";
    }

    function panelError(msg) {
      var box = el("cr-error");
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    // ---- loading -----------------------------------------------------------
    //
    // Both tables are fetched together. If the course list fails but the
    // registrations arrive, the register is still shown — with the course key
    // standing in for its name and the capacity unknown — because a list of
    // people who have signed up is worth having even when the capacity is not.
    function load() {
      return Promise.all([
        sb.from("courses")
          .select("key,name,cohort_mode,capacity,is_open,sort_order")
          .order("sort_order", { ascending: true }),
        sb.from("course_registrations")
          .select("id,reference,submitted_at,course_key,cohort,first_name,surname," +
                  "email,mobile,experience,notes,outcome,status,office_notes,reviewed_at")
          .order("submitted_at", { ascending: true })
      ]).then(function (res) {
        var problems = [];

        if (res[1].error) {
          // Until 009_courses.sql is applied this table does not exist. That is
          // "not set up yet", not "broken", and saying so saves somebody
          // hunting a fault that isn't there.
          if (/does not exist|schema cache|relation/i.test(res[1].error.message || "")) {
            rows = []; courses = [];
            panelError("Class sign-ups aren't set up in the database yet " +
                       "(009_courses.sql hasn't been run).");
            return;
          }
          rows = [];
          problems.push("the sign-ups (" + res[1].error.message + ")");
        } else {
          rows = res[1].data || [];
        }

        if (res[0].error) {
          courses = [];
          problems.push("the class list (" + res[0].error.message + ")");
        } else {
          courses = res[0].data || [];
        }

        // Any course that has sign-ups but is missing from `courses` still gets
        // a heading, so nobody is invisible because a row was tidied away.
        var known = {};
        courses.forEach(function (c) { known[c.key] = true; });
        rows.forEach(function (r) {
          if (!known[r.course_key]) {
            known[r.course_key] = true;
            courses.push({ key: r.course_key, name: r.course_key,
                           cohort_mode: "separate", capacity: null,
                           is_open: null, sort_order: 999 });
          }
        });

        panelError(problems.length
          ? "Couldn't load " + problems.join(" or ") +
            ". Everything else below is still correct."
          : null);
      });
    }

    // ---- shaping -----------------------------------------------------------

    // Waiting positions are worked out here rather than stored, because the
    // stored answer goes stale the moment anyone withdraws. Position is the
    // place in the queue among people still actively waiting for the same
    // session, oldest first — the same rule register_for_course() counted by.
    function positions() {
      var seen = {};
      var out = {};
      rows.slice()
        .sort(function (a, b) { return new Date(a.submitted_at) - new Date(b.submitted_at); })
        .forEach(function (r) {
          if (r.outcome !== "waiting" || r.status !== "active") return;
          var k = r.course_key + "|" + r.cohort;
          seen[k] = (seen[k] || 0) + 1;
          out[r.id] = seen[k];
        });
      return out;
    }

    function matches(r) {
      if (filter !== "all" && r.course_key !== filter) return false;
      if (!showClosed && r.status !== "active") return false;
      if (query) {
        var q = query.toLowerCase();
        var digits = q.replace(/\D/g, "");
        var name = ((r.first_name || "") + " " + (r.surname || "")).toLowerCase();
        var mail = String(r.email || "").toLowerCase();
        var ref  = String(r.reference || "").toLowerCase();
        var mob  = String(r.mobile || "").replace(/\D/g, "");
        if (name.indexOf(q) === -1 && mail.indexOf(q) === -1 &&
            ref.indexOf(q) === -1 &&
            !(digits.length >= 3 && mob.indexOf(digits) !== -1)) return false;
      }
      return true;
    }

    // One group per course and cohort. Empty groups are kept, because "nobody
    // has signed up for the women's session" is information the office wants —
    // an absent heading just looks like the page forgot.
    function groups() {
      var out = [];
      courses.slice()
        .sort(function (a, b) { return (a.sort_order || 0) - (b.sort_order || 0); })
        .forEach(function (c) {
          if (filter !== "all" && c.key !== filter) return;
          var cohorts = c.cohort_mode === "single" ? ["all"] : ["mens", "womens"];
          // A cohort that only exists in the data (a course switched from
          // separate to single, say) still gets a heading.
          rows.forEach(function (r) {
            if (r.course_key === c.key && cohorts.indexOf(r.cohort) === -1) {
              cohorts.push(r.cohort);
            }
          });
          cohorts.forEach(function (co) {
            var mine = rows.filter(function (r) {
              return r.course_key === c.key && r.cohort === co;
            });
            out.push({
              course: c, cohort: co,
              taken: mine.filter(function (r) {
                return r.outcome === "place" && r.status === "active"; }).length,
              waiting: mine.filter(function (r) {
                return r.outcome === "waiting" && r.status === "active"; }).length,
              // Places first, then the waiting list, each oldest first — the
              // order the office reads them out in.
              items: mine.filter(matches).sort(function (a, b) {
                if (a.status !== b.status) return a.status === "active" ? -1 : 1;
                if (a.outcome !== b.outcome) return a.outcome === "place" ? -1 : 1;
                return new Date(a.submitted_at) - new Date(b.submitted_at);
              })
            });
          });
        });
      return out;
    }

    // ---- rendering ---------------------------------------------------------
    function tabs() {
      var wrap = el("cr-tabs");
      var live = rows.filter(function (r) { return r.status === "active"; });
      var html = '<button type="button" class="bk-tab' + (filter === "all" ? " on" : "") +
                 '" data-filter="all">All classes <span class="n">' +
                 live.length + "</span></button>";
      courses.slice()
        .sort(function (a, b) { return (a.sort_order || 0) - (b.sort_order || 0); })
        .forEach(function (c) {
          var n = live.filter(function (r) { return r.course_key === c.key; }).length;
          html += '<button type="button" class="bk-tab' + (filter === c.key ? " on" : "") +
                  '" data-filter="' + esc(c.key) + '">' + esc(c.name) +
                  ' <span class="n">' + n + "</span></button>";
        });
      wrap.innerHTML = html;
    }

    function bar(taken, capacity) {
      if (capacity == null) return "";
      var pct = Math.min(100, Math.round((taken / capacity) * 100));
      return '<span class="cr-bar" role="img" aria-label="' + taken + ' of ' +
             capacity + ' places taken"><i style="width:' + pct + '%"></i></span>';
    }

    function card(r, pos) {
      var isActive = r.status === "active";
      var waiting  = r.outcome === "waiting";
      var extras = [];
      if (r.experience) extras.push("Experience: " + r.experience);
      if (r.notes)      extras.push("They said: " + r.notes);

      var acts;
      if (isActive && waiting) {
        acts = '<button type="button" class="bk-btn go" data-act="promote">Give a place</button>' +
               '<button type="button" class="bk-btn no" data-act="withdrawn">Withdraw</button>' +
               '<button type="button" class="bk-btn" data-act="save">Save notes</button>';
      } else if (isActive) {
        acts = '<button type="button" class="bk-btn go" data-act="attended">Attended</button>' +
               '<button type="button" class="bk-btn" data-act="no_show">Didn’t attend</button>' +
               '<button type="button" class="bk-btn no" data-act="withdrawn">Withdraw</button>' +
               '<button type="button" class="bk-btn" data-act="save">Save notes</button>';
      } else {
        acts = '<button type="button" class="bk-btn" data-act="active">Put back on the list</button>' +
               '<button type="button" class="bk-btn" data-act="save">Save notes</button>';
      }

      return '' +
        '<article class="bk-item cr-item s-' + esc(r.status) + ' o-' + esc(r.outcome) +
          '" data-id="' + esc(r.id) + '">' +
          '<div class="bk-when">' +
            '<span class="d">' + esc((r.first_name || "") + " " + (r.surname || "")) + '</span>' +
            '<span class="bk-kind t-' + (waiting ? "wait" : "place") + '">' +
              (waiting ? "Waiting" + (pos ? " · no. " + pos : "") : "Has a place") + '</span>' +
            '<span class="bk-pill p-' + esc(r.status) + '">' +
              esc(STATUS_WORDS[r.status] || r.status) + '</span>' +
          '</div>' +
          '<div class="bk-who">' +
            '<span class="cr-ref">' + esc(r.reference) + '</span>' +
            '<a href="tel:' + esc(String(r.mobile || "").replace(/\s/g, "")) + '">' +
              esc(r.mobile) + '</a>' +
            (r.email ? ' <a href="mailto:' + esc(r.email) + '">' + esc(r.email) + '</a>' : '') +
          '</div>' +
          (extras.length ? '<div class="bk-addr">' + esc(extras.join(" · ")) + '</div>' : '') +
          '<div class="bk-meta">Signed up ' + esc(ago(r.submitted_at)) +
            (r.reviewed_at ? ' · last changed ' + esc(ago(r.reviewed_at)) : '') + '</div>' +
          '<textarea class="bk-notes" data-notes rows="1" ' +
            'placeholder="Notes — who rang, what was said, fee paid">' +
            esc(r.office_notes || "") + '</textarea>' +
          '<div class="bk-acts">' + acts +
            '<span class="bk-said" data-said></span>' +
          '</div>' +
        '</article>';
    }

    function render() {
      tabs();
      var pos = positions();
      var list = el("cr-list");
      var gs = groups();

      if (!gs.length) {
        list.innerHTML = '<div class="bk-empty">No classes are set up yet.</div>';
        return;
      }

      list.innerHTML = gs.map(function (g) {
        var cap = g.course.capacity;
        var head = esc(g.course.name) + " · " + (COHORTS[g.cohort] || g.cohort);
        var sub  = cap == null
          ? g.taken + " signed up"
          : g.taken + " of " + cap + " places taken" +
            (g.waiting ? " · " + g.waiting + " waiting" : "");
        if (g.course.is_open === false) sub += " · closed to new sign-ups";

        var body;
        if (!g.items.length) {
          body = '<div class="bk-empty">' +
                 (query ? "Nobody here matches “" + esc(query) + "”."
                        : g.taken || g.waiting
                          ? "Nothing to show — try “Show withdrawn and past”."
                          : "Nobody has signed up for this session yet.") +
                 '</div>';
        } else {
          body = g.items.map(function (r) { return card(r, pos[r.id]); }).join("");
        }

        return '<section class="cr-group">' +
                 '<div class="cr-ghead">' +
                   '<h3>' + head + '</h3>' +
                   '<span class="cr-gsub">' + esc(sub) + '</span>' +
                   bar(g.taken, cap) +
                 '</div>' + body +
               '</section>';
      }).join("");
    }

    // ---- writing -----------------------------------------------------------
    //
    // Two different paths, and the difference matters. Status and notes are a
    // plain UPDATE of columns the office is granted. Giving a place is not —
    // `outcome` has no grant at all, so it goes through the function that
    // retakes the capacity lock. If that function is missing the office is
    // told which migration to run, rather than shown a Postgres error.
    function apply(id, item, act) {
      var row = rows.filter(function (r) { return String(r.id) === String(id); })[0];
      if (!row) {
        panelError("That sign-up is no longer in the list — reloading.");
        return load().then(render);
      }
      var notes = item.querySelector("[data-notes]").value.trim();
      var said  = item.querySelector("[data-said]");
      var btns  = item.querySelectorAll(".bk-btn");
      Array.prototype.forEach.call(btns, function (b) { b.disabled = true; });
      said.textContent = "Saving…";

      function failed(msg) {
        said.textContent = "";
        panelError(msg);
        Array.prototype.forEach.call(btns, function (b) { b.disabled = false; });
      }

      // Notes are saved on the same click, so a place is never given away with
      // the reason for it still sitting unsaved in the box.
      var patch = { office_notes: notes || null };
      if (act !== "save" && act !== "promote") {
        patch.status      = act;
        patch.reviewed_by = me;
        patch.reviewed_at = new Date().toISOString();
      }

      return sb.from("course_registrations").update(patch).eq("id", id)
        .then(function (res) {
          if (res.error) {
            // The one_live_registration constraint: the same email cannot hold
            // two live registrations on one session. Reinstating somebody who
            // has since signed up again trips it, and the raw message does not
            // explain that.
            if (/one_live_registration|exclusion|conflicting key/i.test(res.error.message || "")) {
              throw new Error("They already have another live registration on this " +
                              "session, so this one can't be put back. Withdraw the " +
                              "other one first. Nothing was changed.");
            }
            throw new Error(res.error.message + ". Nothing was changed.");
          }
          if (act !== "promote") return null;
          return sb.rpc("promote_from_waiting", { p_id: id }).then(function (out) {
            if (!out.error) return out.data;
            // Everything below this point has already saved the notes, so the
            // message must not claim that nothing changed.
            if (/does not exist|schema cache|function/i.test(out.error.message || "")) {
              throw new Error("giving out a place needs 013_course_admin.sql, which " +
                              "hasn't been run yet. The notes were saved.");
            }
            throw new Error(out.error.message + " The notes were saved.");
          });
        })
        .catch(function (e) {
          // Rethrown as a marker so the reload below is not mistaken for the
          // failure itself.
          failed("Couldn't save that — " + (e && e.message));
          throw { handled: true };
        })
        .then(function () {
          panelError(null);
          return load().then(render);
        })
        .catch(function (e) {
          if (e && e.handled) return;
          failed("Saved, but the list couldn't be reloaded — " + (e && e.message) +
                 ". Refresh the page to see where things stand.");
        });
    }

    function wire() {
      el("cr-tabs").addEventListener("click", function (e) {
        var tab = e.target.closest(".bk-tab");
        if (!tab) return;
        filter = tab.dataset.filter;
        render();
      });

      var search = el("cr-search");
      var t;
      search.addEventListener("input", function () {
        clearTimeout(t);
        var v = this.value.trim();
        t = setTimeout(function () { query = v; render(); }, 150);
      });

      el("cr-closed").addEventListener("change", function () {
        showClosed = this.checked;
        render();
      });

      el("cr-list").addEventListener("click", function (e) {
        var btn = e.target.closest(".bk-btn");
        if (!btn) return;
        var item = btn.closest(".bk-item");
        apply(item.dataset.id, item, btn.dataset.act);
      });
    }

    function mount(identity) {
      var panel = el("cr-panel");
      var card  = el("view-app");
      var noAcc = el("app-noaccess");
      me = identity.user.id;

      // Somebody signed in without the role must be told why the page is
      // empty. An empty page reads as broken.
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
      return load().then(render);
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
    try { register.mount(identity); } catch (e) {
      if (window.console) console.warn("register panel unavailable:", e);
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
