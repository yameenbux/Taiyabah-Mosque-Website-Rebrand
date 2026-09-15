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

    // Every group heading here quotes a capacity. The panel above can change
    // one, so without this the register goes on quoting the old number until
    // somebody thinks to reload the page — and a stale "12 of 15" is exactly
    // the sort of thing an office acts on.
    function refresh() {
      if (!mounted) return Promise.resolve();
      return load().then(render);
    }

    return { mount: mount, refresh: refresh };
  })();

  /* =========================================================================
     THE CLASSES THEMSELVES

     `courses` holds the name, the number of places and the is_open switch that
     register_for_course() reads, and until 043 nothing could write to it. The
     two rows were put there by 004 and had never changed: the masjid could not
     close a class that was full, could not raise a capacity and could not
     rename one. 043 gave the table three guarded functions and 044 gave the
     writer the lock its own comment implied. This is the screen that calls
     them.

     WHAT THIS SCREEN CANNOT DO, AND WHY IT SAYS SO ON THE PAGE
     ----------------------------------------------------------
     save_course() will create a row. It will not create a class. The website
     holds more about a class than this table does — which sessions it runs,
     what the experience question asks, the wording shown when sign-ups are
     closed — and none of that is in the database, so a brand new row with no
     section on the website is invisible to every visitor. Somebody who adds
     one here and waits for it to appear will wait forever, so the panel says
     that in those words rather than leaving it to be discovered.

     THERE IS NO DELETE, and that is deliberate in 043 rather than missing
     here. course_registrations has a foreign key to this table: deleting a
     class somebody signed up for either fails with a constraint error or, with
     a cascade, silently erases the record of people who registered. Closing is
     the reversible thing, and it is what somebody actually means.

     THE COMPLAINTS ARE THE DATABASE'S OWN. check() below is check_course()
     from 043, rule for rule. A rule here that Postgres does not have stops a
     volunteer doing something they are perfectly entitled to do, and nothing
     will ever contradict it; a rule Postgres has that is not here is a raw
     constraint name in front of that same volunteer. Both have happened on
     this project, which is why 041 and 043 both carry a validator.
     ======================================================================= */
  var classes = (function () {
    var rows      = [];      // courses_admin_list()
    var editing   = null;    // the class being amended, or null when adding
    var saveLabel = "Add the class";
    var wired     = false;

    var KEY_RE   = /^[a-z0-9_]{2,40}$/;
    var NAME_MAX = 80;

    // The two values courses_cohort_mode_check allows, and what a person
    // calls them. Anything else in this object would be refused by the table.
    var MODES = {
      separate: "Men’s and women’s sessions",
      single:   "One session for everyone"
    };

    function canSee(identity) {
      return identity.roles.indexOf("admin") !== -1;
    }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function trim(v) { return String(v == null ? "" : v).trim(); }

    function note(id, msg) {
      var n = el(id); if (!n) return;
      if (!msg) { n.hidden = true; n.textContent = ""; return; }
      n.textContent = msg; n.hidden = false;
    }

    /* =====================================================================
       check() — check_course() from 043, in the browser

       PURE. No DOM, no network, no session. It takes the plain object the
       form makes and returns everything wrong with it, empty when there is
       nothing. Postgres returns only the first complaint because a plpgsql
       function returns once; somebody filling a form would rather see all of
       them at once, so this collects them in the same order.

       The capacity-against-taken rule at the end is save_course()'s rather
       than check_course()'s, and it is here for the same reason as the rest:
       lowering the places below the number of people already told they have a
       seat is refused by the database, and meeting that refusal after pressing
       Save teaches nobody anything. It only fires when `taken` is known, so a
       brand new class is never blocked by it.
       =================================================================== */
    function check(o) {
      o = o || {};
      var out   = [];
      var key   = trim(o.key).toLowerCase();
      var name  = trim(o.name);
      var mode  = trim(o.cohort_mode).toLowerCase();
      var cap   = trim(o.capacity);
      var sort  = trim(o.sort_order);
      var taken = trim(o.taken);

      if (key === "") {
        out.push("A class needs a short name for the website to use, like arabic.");
      } else if (!KEY_RE.test(key)) {
        out.push("The website name must be 2 to 40 characters, lower case letters, " +
                 "numbers and underscores only — like arabic or ghusl. No spaces.");
      }

      if (name === "") {
        out.push("A class needs a name people will read, like Arabic Classes.");
      } else if (name.length > NAME_MAX) {
        //  The number is quoted back, because "too long" without a number
        //  means deleting words until it stops complaining.
        out.push("That name is " + name.length + " characters. The limit is " +
                 NAME_MAX + ".");
      }

      if (mode !== "separate" && mode !== "single") {
        out.push("Choose whether the class runs separate sessions for men and women, " +
                 "or a single session.");
      }

      if (cap === "" || !/^[0-9]+$/.test(cap)) {
        out.push("How many places are there? It has to be a whole number.");
      } else if (Number(cap) < 1 || Number(cap) > 500) {
        out.push("Places must be between 1 and 500. It is " + cap + ".");
      } else if (/^[0-9]+$/.test(taken) && Number(cap) < Number(taken)) {
        out.push("There are already " + taken + " people holding a place on that " +
                 "class, so it cannot be set to " + cap + " places. Move somebody to " +
                 "the waiting list first.");
      }

      if (sort !== "" && !/^[0-9]{1,4}$/.test(sort)) {
        out.push("The order has to be a whole number.");
      }

      return out;
    }

    // ---- the form ----------------------------------------------------------
    function readForm() {
      return {
        key:         el("cc-key").value,
        name:        el("cc-name").value,
        cohort_mode: el("cc-mode").value,
        capacity:    el("cc-capacity").value,
        sort_order:  el("cc-order").value,
        // Only a class that already exists has anybody on it.
        taken:       editing ? editing.taken : ""
      };
    }

    /*  Re-run after every keystroke. The Save button is the only way to reach
        save_course(), so this is where "nothing is saveable until the form is
        valid" actually lives — the `disabled` in the markup only covers the
        first paint. */
    function revalidate() {
      var f = readForm();

      var left  = NAME_MAX - trim(f.name).length;
      var count = el("cc-name-count");
      if (count) {
        count.textContent = left >= 0
          ? left + " characters left"
          : (-left) + " characters too many — the limit is " + NAME_MAX;
        count.classList.toggle("cc-over", left < 0);
      }

      var complaints = check(f);
      var box = el("cc-complaints");
      if (complaints.length) {
        box.innerHTML = "<ul>" + complaints.map(function (c) {
          return "<li>" + esc(c) + "</li>";
        }).join("") + "</ul>";
        box.hidden = false;
      } else {
        box.hidden = true;
        box.innerHTML = "";
      }
      el("cc-save").disabled = complaints.length > 0;
      return complaints;
    }

    function resetForm() {
      editing = null;
      el("cc-key").value       = "";
      el("cc-key").disabled    = false;
      el("cc-name").value      = "";
      el("cc-mode").value      = "separate";
      el("cc-capacity").value  = "15";
      el("cc-order").value     = "0";
      el("cc-key-hint").hidden   = false;
      el("cc-key-locked").hidden = true;
      el("cc-form-head").textContent = "Add a class";
      el("cc-form-lede").textContent =
        "This adds a row to the database and nothing else. Read the note above " +
        "first — a class the website has no section for cannot be reached by anybody.";
      el("cc-places-note").textContent =
        "Anything from 1 to 500 places. The order decides which class comes first " +
        "on the website; the smaller number goes first.";
      el("cc-cancel").hidden = true;
      saveLabel = "Add the class";
      el("cc-save").textContent = saveLabel;
      revalidate();
    }

    function fillForm(c) {
      editing = c;
      el("cc-key").value      = c.key || "";
      //  THE WEBSITE NAME IS THE FOREIGN KEY. Every registration ever taken is
      //  filed under it, so letting somebody retype it here would leave those
      //  people attached to a class that no longer exists — and save_course()
      //  would not complain, because a new key is simply a new row. Disabled,
      //  with the reason printed beside it.
      el("cc-key").disabled   = true;
      el("cc-name").value     = c.name || "";
      el("cc-mode").value     = c.cohort_mode === "single" ? "single" : "separate";
      el("cc-capacity").value = c.capacity == null ? "" : c.capacity;
      el("cc-order").value    = c.sort_order == null ? "0" : c.sort_order;
      el("cc-key-hint").hidden   = true;
      el("cc-key-locked").hidden = false;
      el("cc-form-head").textContent = "Amend " + (c.name || c.key);
      el("cc-form-lede").textContent =
        "Changes here are on the website as soon as you save them. This does not " +
        "open or close sign-ups — that is the button on the class above.";

      var taken = Number(c.taken || 0);
      el("cc-places-note").textContent = taken > 0
        ? (taken === 1
            ? "One person already holds a place on this class"
            : taken + " people already hold a place on this class") +
          ", so the places cannot be set below " + taken + ". The database refuses " +
          "it: those people have already been told they have a seat. Move somebody " +
          "to the waiting list first."
        : "Nobody holds a place on this class yet, so anything from 1 to 500 is fine.";

      el("cc-cancel").hidden = false;
      saveLabel = "Save changes";
      el("cc-save").textContent = saveLabel;
      revalidate();
      el("cc-form-head").scrollIntoView({ block: "start" });
      el("cc-name").focus();
    }

    // ---- the list ----------------------------------------------------------
    function byKey(key) {
      for (var i = 0; i < rows.length; i++) if (rows[i].key === key) return rows[i];
      return null;
    }

    function draw() {
      var box = el("cc-list");
      if (!box) return;
      if (!rows.length) {
        box.innerHTML = '<div class="cc-empty">No classes are set up yet.</div>';
        return;
      }
      box.innerHTML = rows.map(function (c) {
        var open    = c.is_open !== false;
        var taken   = Number(c.taken || 0);
        var waiting = Number(c.waiting || 0);
        var facts   = (MODES[c.cohort_mode] || c.cohort_mode) + " · " +
                      taken + " of " + c.capacity + " places taken" +
                      (waiting ? " · " + waiting + " waiting" : "");

        return '<div class="cc-item ' + (open ? "cc-live" : "cc-dark") + '">' +
          '<div class="cc-top">' +
            '<span class="cc-nm">' + esc(c.name) + "</span>" +
            '<span class="cc-key">' + esc(c.key) + "</span>" +
            '<span class="cc-state ' + (open ? "cc-on" : "cc-off") + '">' +
              (open ? "Sign-ups open" : "Sign-ups closed") + "</span>" +
          "</div>" +
          '<div class="cc-facts">' + esc(facts) + "</div>" +
          '<div class="cc-acts">' +
            '<button type="button" class="btn btn-ghost cc-edit" data-key="' +
              esc(c.key) + '">Edit</button>' +
            '<button type="button" class="btn btn-ghost' + (open ? " cc-shut" : "") +
              '" data-key="' + esc(c.key) + '" data-open="' + (open ? "0" : "1") + '">' +
              (open ? "Close sign-ups" : "Open sign-ups") + "</button>" +
          "</div>" +
        "</div>";
      }).join("");
    }

    function load() {
      return sb.rpc("courses_admin_list").then(function (res) {
        if (res.error) {
          // Until 043 is applied none of these functions exist. That is "not
          // set up yet", not "broken", and saying so saves somebody hunting a
          // fault that isn't there.
          if (/does not exist|schema cache|function/i.test(res.error.message || "")) {
            throw new Error("Managing the classes needs " +
                            "043_courses_the_committee_can_open_and_close.sql, " +
                            "which hasn't been run yet.");
          }
          throw new Error(res.error.message);
        }
        rows = (Array.isArray(res.data) ? res.data : []).slice().sort(function (a, b) {
          return (a.sort_order || 0) - (b.sort_order || 0) ||
                 String(a.key).localeCompare(String(b.key));
        });
        draw();
      });
    }

    // The register below shows the same classes, so both are re-read together.
    function refresh() {
      return load().then(function () {
        try { register.refresh(); } catch (e) {
          if (window.console) console.warn("register wouldn't reload:", e);
        }
      });
    }

    // ---- writing -----------------------------------------------------------
    function save() {
      if (revalidate().length) return;   // belt and braces; the button is disabled too

      var f   = readForm();
      var btn = el("cc-save");
      var p   = {
        key:         trim(f.key).toLowerCase(),
        name:        trim(f.name),
        cohort_mode: trim(f.cohort_mode).toLowerCase(),
        capacity:    trim(f.capacity),
        sort_order:  trim(f.sort_order) === "" ? "0" : trim(f.sort_order)
      };

      busy(btn, true, saveLabel);
      note("cc-error", ""); note("cc-ok", "");

      //  The argument is named `p` — save_course(p jsonb). Supabase sends the
      //  keys of this object as the function's named arguments, so a wrapper
      //  key of any other name is a "function does not exist" error.
      sb.rpc("save_course", { p: p }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        var d = res.data || {};
        note("cc-ok", d.is_new
          // is_open defaults to false (004), so a new class is not quietly
          // taking sign-ups the moment it is added.
          ? "Added, with sign-ups closed. Open them on the class above when you are " +
            "ready — and remember the website needs a section for it before anybody " +
            "can reach the form."
          : "Saved. Whether sign-ups are open is unchanged.");
        resetForm();
        return refresh();
      }).catch(function (e) {
        note("cc-error", e.message || String(e));
      }).finally(function () {
        busy(btn, false, saveLabel);
        revalidate();
      });
    }

    function setOpen(key, open, name) {
      //  Closing is what a visitor sees immediately: the sign-up form stops
      //  taking people the moment this returns. Opening only ever gives
      //  somebody a way in, so it does not ask.
      if (!open && !window.confirm(
            "Close sign-ups for “" + (name || key) + "”?\n\n" +
            "The website stops taking sign-ups for it straight away. Everybody " +
            "already on the list keeps their place, and you can open it again " +
            "whenever you like.")) return null;

      note("cc-error", ""); note("cc-ok", "");
      return sb.rpc("set_course_open", { p_key: key, p_open: open })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          note("cc-ok", open
            ? "Sign-ups for “" + (name || key) + "” are open. The website is taking " +
              "them now."
            : "Sign-ups for “" + (name || key) + "” are closed. Nobody new can sign " +
              "up; everybody already on the list keeps their place.");
          return refresh();
        })
        .catch(function (e) { note("cc-error", e.message || String(e)); });
    }

    // ---- wiring ------------------------------------------------------------
    function wire() {
      if (wired) { resetForm(); return true; }

      ["cc-key", "cc-name", "cc-mode", "cc-capacity", "cc-order"].forEach(function (id) {
        var node = el(id);
        if (!node) return;
        node.addEventListener("input", revalidate);
        node.addEventListener("change", revalidate);
      });

      el("cc-save").addEventListener("click", save);
      el("cc-cancel").addEventListener("click", function () {
        resetForm();
        note("cc-error", ""); note("cc-ok", "");
      });

      el("cc-list").addEventListener("click", function (ev) {
        var btn = ev.target.closest("button[data-key]");
        if (!btn || btn.disabled) return;
        var key = btn.getAttribute("data-key");
        var c   = byKey(key);

        if (btn.classList.contains("cc-edit")) {
          if (c) fillForm(c);
          return;
        }
        btn.disabled = true;
        //  A cancelled confirm does nothing at all, so the button has to come
        //  back — otherwise the row is dead until the list is next drawn.
        if (!setOpen(key, btn.getAttribute("data-open") === "1", c && c.name)) {
          btn.disabled = false;
        }
      });

      wired = true;
      resetForm();
      return true;
    }

    function mount(identity) {
      var panel = el("cc-panel");
      var card  = el("view-app");
      if (!panel) return;

      // Same rule as the register: the database refuses every one of these
      // calls to anybody who is not a verified administrator, but there is no
      // reason to show somebody a panel they cannot use.
      if (!canSee(identity)) { panel.hidden = true; return; }
      panel.hidden = false;
      if (card) card.classList.add("is-wide");
      wire();

      return load().catch(function (e) {
        var box = el("cc-list");
        if (box) box.innerHTML = '<div class="cc-empty">The class list couldn’t ' +
                                 'be read — the message above says why.</div>';
        note("cc-error", "Couldn't read the classes: " + (e.message || e));
      });
    }

    return { mount: mount, _check: check, _wire: wire };
  })();

  /*  EXPOSED FOR THE TESTS, on the same reasoning as __NOTICE_FORM in notices/.

      check() is pure — no DOM, no network, no state — and it is the half of
      this panel worth testing, because it has to agree with check_course() in
      043 exactly. Where the two disagree a volunteer is told a class is fine
      and then handed a raw Postgres constraint name, which is the fault 041
      and 043 both carry a validator to prevent.

      wire() is not pure, and it is here because of a trap this project has
      already fallen into twice. The rule "nothing is saveable until the form
      is valid" would otherwise live only inside mount(), which runs after a
      real sign-in — so no test could reach it, and the Save button is disabled
      in the markup as well, so it would read as disabled whether the rule was
      there or had been deleted. Wiring the form on a page nobody is signed in
      to gives a Save button whose click calls save_course(), which Postgres
      refuses to anybody who is not a verified admin with two-step. The
      permission is in the database, not in this file. */
  window.__COURSE_FORM = { check: classes._check, wire: classes._wire };

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'courses',
        title:   'Adult classes',
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
    // and the two panels must not take each other down either — a fault in
    // the class editor would otherwise hide the register, which is the part
    // the office needs every week.
    try { register.mount(identity); } catch (e) {
      if (window.console) console.warn("register panel unavailable:", e);
    }
    try { classes.mount(identity); } catch (e) {
      if (window.console) console.warn("class editor unavailable:", e);
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
