/* ===========================================================================
   Taiyabah Masjid — Adult classes: the classes, their pages, and who signed up
   Bolton Central Islamic Society · Registered charity 1041569

   This screen used to be two
   --------------------------
   "Adult classes" kept the row in `courses`; "What a class says" kept
   `courses.page`. Two tabs for one thing, and the split cost more than it
   saved — a class added on one screen was invisible until somebody found the
   other, and neither screen could finish the job alone. They are one screen
   now: one list, one editor holding both halves, one Save that writes both.
   /classpages/ is gone.

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
     THE CLASSES THEMSELVES — AND EVERY WORD THEIR PAGES SAY

     WHY THIS IS ONE MODULE AND NOT TWO SCREENS
     ------------------------------------------
     It was two. "Adult classes" owned the row in `courses` — the name, the
     capacity, the is_open switch register_for_course() reads. "What a class
     says" owned `courses.page` — the tagline, the opening paragraph, the
     what-to-know list, the session labels, the experience question and the
     two sign-up blurbs. Both were correct and the split was wrong: a class is
     ONE thing to the volunteer who runs it, and the two screens meant adding a
     class in one place, being told to go somewhere else, and in between having
     a class that existed and was invisible with nothing on either screen able
     to fix it alone.

     So: one list, one editor, one Save. The editor keeps the two halves
     visibly apart — "The class" and "Its page on the website" — because they
     fail differently and are refused by two different database functions.

     THE ORDER OF THE TWO WRITES IS NOT A PREFERENCE. save_course_page()
     starts with `select cohort_mode from courses where key = ...` and raises
     "There is no class with that website name" when it finds nothing. A brand
     new class therefore has to exist before its page can be written, so
     save_course() goes first, always.

     AND THE HALF-DONE CASE IS SAID OUT LOUD. If save_course() succeeds and
     save_course_page() then fails, the class is real and its page is not.
     Reporting that as a clean failure would send somebody back to press Add
     again, and the second press would be an edit of a class they did not know
     they had made.

     THE COMPLAINTS ARE THE DATABASE'S OWN. checkCourse() is check_course()
     from 043, rule for rule; checkPage() is check_course_page() from 047, rule
     for rule. A rule here that Postgres does not have stops a volunteer doing
     something they are perfectly entitled to do, and nothing will ever
     contradict it; a rule Postgres has that is not here is a raw constraint
     name in front of that same volunteer. Both have happened on this project,
     which is why 041, 043, 045 and 047 all carry a validator.

     REMOVING IS 048, CORRECTED BY 049. delete_course() refuses while anybody
     has signed up and says so in a sentence written for the person reading it.
     That sentence is shown exactly as it arrives — a friendlier rewording here
     would be a second copy of a message that is already right, and would drift.
     ======================================================================= */
  var classes = (function () {
    // ---- the class row: every number below is a number in 043 --------------
    var KEY_RE   = /^[a-z0-9_]{2,40}$/;
    var NAME_MAX = 80;

    // The two values courses_cohort_mode_check allows, and what a person
    // calls them. Anything else in this object would be refused by the table.
    var MODES = {
      separate: "Men’s and women’s sessions",
      single:   "One session for everyone"
    };

    /*  ---- its page: every number below is a number in check_course_page().
        They are named rather than typed into the messages twice, because a
        limit quoted in one place and enforced in another is a limit that
        drifts. */
    var TAGLINE_MAX = 180;   // length(btrim(p->>'tagline')) > 180
    var INTRO_MAX   = 1200;  // length(btrim(p->>'intro'))   > 1200
    var FACTS_MAX   = 4;     // jsonb_array_length(p->'facts') > 4
    var FACT_MAX    = 24;    // both halves of a fact
    var RULES_MIN   = 1;
    var RULES_MAX   = 8;     // 1..8 "what to know" rows
    var RULE_K_MAX  = 28;
    var RULE_V_MAX  = 400;
    var COHORT_MAX  = 48;    // the session label
    var EXPQ_MAX    = 120;   // the experience question
    var EXP_MIN     = 2;
    var EXP_MAX     = 6;     // 2..6 answers
    var EXP_L_MAX   = 90;    // an answer's wording
    var BLURB_MAX   = 400;   // open and closed, each
    var BODY_MAX    = 12000; // length(p::text) > 12000

    /*  ^[a-z0-9_]{2,24}$ — the filing name on an experience answer.
        `experience` on course_registrations is free text with no constraint,
        so unlike the cohort keys these ARE the committee's to invent. */
    var EXP_KEY = /^[a-z0-9_]{2,24}$/;

    /*  THE ONLY THREE COHORT KEYS THERE ARE. course_registrations has carried
        `check (cohort = any (array['mens','womens','all']))` since db/004,
        and a made-up fourth would save fine and then refuse every sign-up
        against it with a raw constraint error. */
    var SEPARATE_KEYS = ["mens", "womens"];
    var SINGLE_KEYS   = ["all"];

    var rows      = [];      // courses_admin_list() joined to courses_public()
    var editing   = null;    // the class being amended, or null when adding
    var doc       = null;    // its page, as it is being edited; null = shut
    var saved     = null;    // what came back from the database, for Undo
    var saveLabel = "Add the class";
    var wired     = false;

    function canSee(identity) {
      return identity.roles.indexOf("admin") !== -1;
    }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }

    function trim(v) { return String(v == null ? "" : v).trim(); }
    function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

    function note(id, msg) {
      var n = el(id); if (!n) return;
      if (!msg) { n.hidden = true; n.textContent = ""; return; }
      n.textContent = msg; n.hidden = false;
    }

    /*  Which keys a class's sessions must carry, from its cohort_mode. The
        default is `separate`, because that is what check_course_page() does
        with anything that is not the word "single" — the two have to agree or
        the screen would demand two rows where the database wanted one. */
    function wantedKeys(mode) {
      return String(mode == null ? "" : mode).trim().toLowerCase() === "single"
        ? SINGLE_KEYS.slice() : SEPARATE_KEYS.slice();
    }

    /* =====================================================================
       checkCourse() — check_course() from 043, in the browser

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
    function checkCourse(o) {
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

    /* =====================================================================
       checkPage() — check_course_page() from 047, in the browser

       PURE. No DOM, no network, no session. It takes the page object that
       would be sent as p_page, plus the class's cohort_mode — which the
       database passes in for the same reason, because it is the whole reason
       the cohort keys can be validated at all — and returns the list of
       things wrong with it, empty when there is nothing.

       Every message here has a counterpart in 047. If one is changed there,
       it is changed here — and if a rule is added there that is not added
       here, a volunteer meets it as a raw constraint violation, which is the
       fault 041 and 045 were written to end.
       =================================================================== */
    function checkPage(o, mode) {
      //  jsonb_typeof(p) <> 'object'. An array is an object to typeof, and
      //  Postgres would call it 'array', so it is ruled out by hand.
      if (!o || typeof o !== "object" || Array.isArray(o)) {
        return ["The class page did not arrive as expected. Reload and try again."];
      }

      var out = [];

      var tagline = trim(o.tagline);
      if (tagline === "") {
        out.push("The class needs a one-line description for the top of its page.");
      } else if (tagline.length > TAGLINE_MAX) {
        out.push("The one-line description is " + tagline.length +
                 " characters. The limit is " + TAGLINE_MAX + ".");
      }

      var intro = trim(o.intro);
      if (intro === "") {
        out.push("The class needs an opening paragraph.");
      } else if (intro.length > INTRO_MAX) {
        out.push("The opening paragraph is " + intro.length +
                 " characters. The limit is " + INTRO_MAX + ".");
      }

      /*  The fact strip beside the form. Optional AS A WHOLE — `if p ?
          'facts'` in 047 is key-present, not truthiness — but capped at four,
          because it is one row on a phone and a fifth wraps into a mess. */
      if (has(o, "facts") && o.facts !== null && o.facts !== undefined) {
        if (!Array.isArray(o.facts)) {
          out.push("The fact strip did not arrive as expected.");
        } else if (o.facts.length > FACTS_MAX) {
          out.push("There are more than four facts beside the form. Four is the " +
                   "most that fits on a phone.");
        } else {
          o.facts.forEach(function (fct) {
            fct = fct || {};
            if (trim(fct.k) === "" || trim(fct.v) === "") {
              out.push("Every fact needs both a label and a value.");
            } else if (trim(fct.k).length > FACT_MAX || trim(fct.v).length > FACT_MAX) {
              out.push("A fact label and its value must each be " + FACT_MAX +
                       " characters or fewer — they sit in a narrow box.");
            }
          });
        }
      }

      /*  The what-you-need-to-know list.

          047 reaches this through jsonb_typeof(), which returns SQL NULL for
          a key that is not there — so a page object with no `rules` at all
          slips past the database untouched. It is refused here anyway: the
          website will not publish a class with no what-to-know rows, so a
          page saved without them could never appear, and saying nothing
          would leave somebody waiting for a class that is never coming. Being
          stricter than the database only ever stops something that could not
          work; being looser is what hands a volunteer a raw Postgres error. */
      if (!Array.isArray(o.rules)) {
        out.push("The class needs at least one “what to know” row.");
      } else if (o.rules.length < RULES_MIN || o.rules.length > RULES_MAX) {
        out.push("There are " + o.rules.length + " “what to know” rows. There must " +
                 "be between " + RULES_MIN + " and " + RULES_MAX + ".");
      } else {
        o.rules.forEach(function (r) {
          r = r || {};
          var k = trim(r.k);
          var v = trim(r.v);
          if (k === "") {
            out.push("Every “what to know” row needs a label, like “When”.");
          } else if (k.length > RULE_K_MAX) {
            out.push("The row label “" + k.slice(0, 18) + "…” is too long. " +
                     "The limit is " + RULE_K_MAX + " characters.");
          }
          var named = k || "that row";
          if (v === "") {
            out.push("The row “" + named + "” has nothing against it.");
          } else if (v.length > RULE_V_MAX) {
            out.push("The row “" + named + "” is too long. The limit is " +
                     RULE_V_MAX + ".");
          }
        });
      }

      /*  THE COHORTS. The labels are theirs; the keys are the database's.

          047 sorts the keys it was given and compares them to the pair the
          cohort_mode calls for. The same comparison here, and for the same
          reason: course_registrations will take 'mens', 'womens' or 'all' and
          nothing else, so a class carrying any other session would save and
          then refuse every sign-up made against it. */
      var want = wantedKeys(mode);
      if (!Array.isArray(o.cohorts)) {
        out.push("The class needs its sessions listed.");
      } else {
        var got = o.cohorts.map(function (c) { return trim((c || {}).key); }).sort();
        if (got.length !== want.length ||
            got.some(function (k, i) { return k !== want[i]; })) {
          out.push("This class is set to " +
            (want.length === 1
              ? "one session for everyone, so it needs exactly one session row, keyed “all”."
              : "separate men’s and women’s sessions, so it needs exactly two session " +
                "rows, keyed “mens” and “womens”.") +
            " Those three keys are the only ones sign-ups can be recorded against — " +
            "you can write any label you like against them.");
        }
        o.cohorts.forEach(function (c) {
          c = c || {};
          var label = trim(c.label);
          if (label === "") {
            out.push("Every session needs a label people will read, like “Men’s class”.");
          } else if (label.length > COHORT_MAX) {
            out.push("A session label is too long. The limit is " + COHORT_MAX +
                     " characters.");
          }
        });
      }

      //  The experience question.
      var expLabel = trim(o.exp_label);
      if (expLabel === "") {
        out.push("The class needs a question to ask people about their experience.");
      } else if (expLabel.length > EXPQ_MAX) {
        out.push("The experience question is too long. The limit is " + EXPQ_MAX +
                 " characters.");
      }

      //  Same null-propagation note as `rules` above: 047 lets a missing
      //  `exp` through, the website will not publish without two answers, so
      //  it is refused here.
      if (!Array.isArray(o.exp)) {
        out.push("The experience question needs some answers to choose from.");
      } else {
        if (o.exp.length < EXP_MIN || o.exp.length > EXP_MAX) {
          out.push("There are " + o.exp.length + " answers to the experience " +
                   "question. There must be between " + EXP_MIN + " and " + EXP_MAX +
                   " — one answer is not a question.");
        }
        var keys = {};
        var clash = false;
        o.exp.forEach(function (a) {
          a = a || {};
          var k = trim(a.key);
          var label = trim(a.label);
          if (!EXP_KEY.test(k)) {
            out.push("Each answer needs a short filing name: lower case letters, " +
                     "numbers and underscores, 2 to 24 characters. It is what gets " +
                     "recorded against the sign-up.");
          }
          if (label === "") {
            out.push("Every answer needs wording people will read.");
          } else if (label.length > EXP_L_MAX) {
            out.push("An answer is too long. The limit is " + EXP_L_MAX + " characters.");
          }
          if (has(keys, k)) clash = true;
          keys[k] = true;
        });
        if (clash) {
          out.push("Two of the experience answers have the same filing name.");
        }
      }

      /*  The two blurbs. Both required: the closed one is what somebody reads
          for most of the year, and an empty one leaves a bare heading. */
      var openWords   = trim(o.open);
      var closedWords = trim(o.closed);
      if (openWords === "") {
        out.push("The class needs wording for when sign-ups are open.");
      }
      if (closedWords === "") {
        out.push("The class needs wording for when sign-ups are shut — that is what " +
                 "most people will read, most of the year.");
      }
      if (openWords.length > BLURB_MAX || closedWords.length > BLURB_MAX) {
        out.push("The sign-up wording is too long. The limit is " + BLURB_MAX +
                 " characters each.");
      }

      /*  A ceiling on the whole thing. Every limit above is per field, and
          eight rows of four hundred characters is a lot of small fields; this
          is the backstop that stops a class page becoming a document.
          Postgres measures the jsonb text; JSON.stringify is the nearest
          thing a browser has, and it is close enough to warn before a round
          trip. */
      var size;
      try { size = JSON.stringify(o).length; } catch (e) { size = 0; }
      if (size > BODY_MAX) {
        out.push("There is too much here. Shorten the opening paragraph or use " +
                 "fewer rows.");
      }

      return out;
    }

    /* =====================================================================
       whole() — THE WEBSITE'S OWN TEST, not this screen's

       index_template.html replaces the compiled-in copy with the committee's
       ONLY if this passes, and builds a page and a tile for a class it has
       never heard of ONLY if this passes. A class that fails it is skipped in
       silence, which from here looks exactly like the website being broken.
       So the list says "Not on the website yet" in those words, and this is
       the same expression, in the same order, as the one in the page.
       =================================================================== */
    function whole(page) {
      page = page || {};
      return !!(page.tagline && page.intro &&
                Array.isArray(page.rules) && page.rules.length &&
                Array.isArray(page.cohorts) && page.cohorts.length &&
                page.exp_label && Array.isArray(page.exp) && page.exp.length >= 2 &&
                page.open && page.closed);
    }

    /*  NOTHING WRITTEN AT ALL is a state of its own, and not the same thing
        as a page with a gap in it.

        A class whose page has never been started is perfectly legal: `courses`
        defaults `page` to '{}', save_course() writes a row without touching
        it, and the website simply leaves the class out. Demanding a finished
        page before the class could be created would mean a volunteer who
        wants to open sign-ups this evening has to write the whole public page
        first — which is exactly the trap the two-screen version set, only with
        the Save button holding the door shut instead of a link to another tab.

        So: a page with nothing in it is allowed while it is still nothing, and
        the moment one word is typed the whole thing must be right. Erasing a
        page that HAS been written is not "nothing" — see writtenAlready(). */
    function nothingWritten(b) {
      function pair(x) { return trim(x.k) !== "" || trim(x.v) !== ""; }
      function ans(x)  { return trim(x.key) !== "" || trim(x.label) !== ""; }
      return !trim(b.tagline) && !trim(b.intro) && !trim(b.exp_label) &&
             !trim(b.open) && !trim(b.closed) &&
             !(b.facts || []).some(pair) && !(b.rules || []).some(pair) &&
             !(b.cohorts || []).some(function (c) { return trim(c.label) !== ""; }) &&
             !(b.exp || []).some(ans) &&
             !trim(b.tile.tag) && !trim(b.tile.p) && !trim(b.tile.meta);
    }

    //  Whether the class ALREADY has words on the website. A class that is
    //  published and then emptied must be complained about, not quietly left
    //  as it was: somebody clearing these boxes means to take it down, and
    //  "close sign-ups" or "remove" is how that is done.
    function writtenAlready() {
      if (!editing) return false;
      var p = editing.page || {};
      return !!(trim(p.tagline) || trim(p.intro) || trim(p.exp_label) ||
                trim(p.open) || trim(p.closed) ||
                (Array.isArray(p.rules) && p.rules.some(function (r) {
                  return r && (trim(r.k) || trim(r.v)); })) ||
                (Array.isArray(p.exp) && p.exp.some(function (a) {
                  return a && (trim(a.key) || trim(a.label)); })));
    }

    /*  What came out of the database, made safe to put in boxes.

        THE SESSIONS ARE FORCED TO THE RIGHT KEYS HERE, not left as they were
        found. A class switched from separate to single still has its men's and
        women's rows stored; drawing those two boxes and then refusing the save
        would be telling somebody off for something the screen itself put in
        front of them.

        A LABEL IS CARRIED OVER ONLY WHERE ITS KEY SURVIVES, and otherwise the
        box is left empty. Reusing the old wording would save a typing job and
        cost far more than it saved: a class switched to one session for
        everybody would be published calling it "Men's class", which reads
        perfectly well and turns women away from a class that is for them. An
        empty box cannot do that — checkPage() refuses to let the page be saved
        until somebody writes the label, and the paragraph above the boxes says
        why they are being asked. */
    function normalise(page, name, mode) {
      var out = JSON.parse(JSON.stringify(page && typeof page === "object" ? page : {}));
      if (typeof out.name !== "string" || !trim(out.name)) out.name = name || "";
      if (typeof out.tagline !== "string") out.tagline = "";
      if (typeof out.intro !== "string") out.intro = "";
      if (typeof out.exp_label !== "string") out.exp_label = "";
      if (typeof out.open !== "string") out.open = "";
      if (typeof out.closed !== "string") out.closed = "";

      if (!Array.isArray(out.facts)) out.facts = [];
      out.facts = out.facts.slice(0, FACTS_MAX).map(function (fct) {
        fct = fct || {};
        return { k: String(fct.k == null ? "" : fct.k), v: String(fct.v == null ? "" : fct.v) };
      });

      if (!Array.isArray(out.rules) || !out.rules.length) out.rules = [{ k: "", v: "" }];
      out.rules = out.rules.map(function (r) {
        r = r || {};
        return { k: String(r.k == null ? "" : r.k), v: String(r.v == null ? "" : r.v) };
      });

      out.cohorts = carry(Array.isArray(out.cohorts) ? out.cohorts : [], mode);

      if (!Array.isArray(out.exp) || out.exp.length < EXP_MIN) {
        out.exp = (Array.isArray(out.exp) ? out.exp : []).slice();
        while (out.exp.length < EXP_MIN) out.exp.push({ key: "", label: "" });
      }
      out.exp = out.exp.map(function (a) {
        a = a || {};
        return {
          key: String(a.key == null ? "" : a.key),
          label: String(a.label == null ? "" : a.label)
        };
      });

      var tile = (out.tile && typeof out.tile === "object") ? out.tile : {};
      out.tile = {
        tag:  String(tile.tag  == null ? "" : tile.tag),
        p:    String(tile.p    == null ? "" : tile.p),
        meta: String(tile.meta == null ? "" : tile.meta)
      };
      return out;
    }

    /*  The sessions a mode calls for, keeping a label ONLY where its key
        survives the change. Used both when a class is opened and — now that
        the Sessions dropdown and the session labels are on one screen — the
        moment somebody switches between one session and two.

        DO NOT be tempted to move the label across. "Men's class" over a
        session for everybody reads perfectly well and turns half the masjid
        away, and nothing downstream would ever catch it. An empty box cannot
        do that, and the screen says why it is empty. */
    function carry(had, mode) {
      return wantedKeys(mode).map(function (k) {
        var kept = "";
        had.forEach(function (c) {
          if (c && trim(c.key) === k && !kept) kept = String(c.label == null ? "" : c.label);
        });
        return { key: k, label: kept };
      });
    }

    // ---- reading the boxes back ---------------------------------------------
    function readCourseForm() {
      return {
        key:         (el("cc-key") || {}).value,
        name:        (el("cc-name") || {}).value,
        cohort_mode: (el("cc-mode") || {}).value,
        capacity:    (el("cc-capacity") || {}).value,
        sort_order:  (el("cc-order") || {}).value,
        // Only a class that already exists has anybody on it.
        taken:       editing ? editing.taken : ""
      };
    }

    /*  Every repeating editor is drawn the same way — .cp-item rows carrying
        data-i, boxes carrying data-f — so one harvester covers the facts, the
        rules, the sessions and the answers. */
    function harvestList(hostId, list) {
      var host = el(hostId);
      if (!host || !Array.isArray(list)) return;
      Array.prototype.forEach.call(host.querySelectorAll(".cp-item"), function (row) {
        var item = list[Number(row.getAttribute("data-i"))];
        if (!item) return;
        Array.prototype.forEach.call(row.querySelectorAll("[data-f]"), function (box) {
          item[box.getAttribute("data-f")] = box.value;
        });
      });
    }

    /*  Read the DOM into `doc`. Called before every redraw, because a redraw
        replaces the inputs and whatever was typed since the last one would go
        with them. The class's NAME is read from the one name box there is —
        the page used to carry a second copy of it on the other screen, and two
        boxes for one name is how they came to disagree. */
    function harvest() {
      if (!doc) return null;
      [["cc-name", "name"], ["cp-tagline", "tagline"], ["cp-intro", "intro"],
       ["cp-exp-label", "exp_label"], ["cp-open", "open"], ["cp-closed", "closed"]
      ].forEach(function (pair) {
        var box = el(pair[0]);
        if (box) doc[pair[1]] = box.value;
      });

      if (!doc.tile || typeof doc.tile !== "object") doc.tile = { tag: "", p: "", meta: "" };
      [["cp-tile-tag", "tag"], ["cp-tile-p", "p"], ["cp-tile-meta", "meta"]
      ].forEach(function (pair) {
        var box = el(pair[0]);
        if (box) doc.tile[pair[1]] = box.value;
      });

      harvestList("cp-facts", doc.facts);
      harvestList("cp-rules", doc.rules);
      harvestList("cp-cohorts", doc.cohorts);
      harvestList("cp-exps", doc.exp);
      return doc;
    }

    /*  What would be sent as p_page. Trimmed, because check_course_page()
        trims before it measures and a value that passes here and fails there
        is the whole problem this file is written to avoid.

        The cohort KEYS are written from the Sessions dropdown rather than read
        out of any box, because there is no box: the only thing on screen is
        the label. */
    function pageOut() {
      var o = harvest();
      var mode = (el("cc-mode") || {}).value;
      if (!o) return normalise({}, "", mode);
      var keys = wantedKeys(mode);
      return {
        name: trim(o.name),
        tagline: trim(o.tagline),
        intro: trim(o.intro),
        facts: (o.facts || []).map(function (fct) {
          fct = fct || {};
          return { k: trim(fct.k), v: trim(fct.v) };
        }),
        rules: (o.rules || []).map(function (r) {
          r = r || {};
          return { k: trim(r.k), v: trim(r.v) };
        }),
        cohorts: (o.cohorts || []).map(function (c, i) {
          c = c || {};
          return { key: keys[i] || trim(c.key), label: trim(c.label) };
        }),
        exp_label: trim(o.exp_label),
        exp: (o.exp || []).map(function (a) {
          a = a || {};
          return { key: trim(a.key), label: trim(a.label) };
        }),
        open: trim(o.open),
        closed: trim(o.closed),
        tile: {
          tag:  trim(o.tile && o.tile.tag),
          p:    trim(o.tile && o.tile.p),
          meta: trim(o.tile && o.tile.meta)
        }
      };
    }

    // ---- drawing -------------------------------------------------------------
    function countdown(boxId, value, limit) {
      var box = el(boxId);
      if (!box) return;
      var left = limit - trim(value).length;
      box.textContent = left >= 0
        ? left + " characters left"
        : (-left) + " characters too many — the limit is " + limit;
      box.classList.toggle("is-over", left < 0);
    }

    function complaintsInto(boxId, list) {
      var box = el(boxId);
      if (!box) return;
      if (!list.length) { box.hidden = true; box.innerHTML = ""; return; }
      box.innerHTML = "<ul>" + list.map(function (c) {
        return "<li>" + esc(c) + "</li>";
      }).join("") + "</ul>";
      box.hidden = false;
    }

    function sessionsIn(mode) {
      return wantedKeys(mode).length === 1
        ? "one session for everyone"
        : "separate men’s and women’s sessions";
    }

    function byKey(key) {
      for (var i = 0; i < rows.length; i++) if (rows[i].key === key) return rows[i];
      return null;
    }

    /*  THE LIST. Three facts about each class, and they are three different
        things: whether sign-ups are open (the switch register_for_course()
        reads), how full it is, and whether its page is finished — which is the
        one that decides whether the class is on the website AT ALL. Said in
        words rather than left to a colour, because a colour is not a sentence
        anybody can act on. */
    function drawList() {
      var box = el("cc-list");
      if (!box) return;
      if (!rows.length) {
        box.innerHTML = '<div class="cc-empty">No classes are set up yet. ' +
          'Press “Add a class” to make one.</div>';
        return;
      }
      box.innerHTML = rows.map(function (c) {
        var open    = c.is_open !== false;
        var done    = whole(c.page);
        var taken   = Number(c.taken || 0);
        var waiting = Number(c.waiting || 0);
        var facts   = sessionsIn(c.cohort_mode) + " · " +
                      taken + " of " + c.capacity + " places taken" +
                      (waiting ? " · " + waiting + " waiting" : "");

        return '<div class="cc-item ' + (done ? (open ? "cc-live" : "cc-dark") : "cc-gap") + '">' +
          '<div class="cc-top">' +
            '<span class="cc-nm">' + esc(c.name || c.key) + "</span>" +
            '<span class="cc-key">' + esc(c.key) + "</span>" +
            '<span class="cc-state ' + (open ? "cc-on" : "cc-off") + '">' +
              (open ? "Sign-ups open" : "Sign-ups closed") + "</span>" +
          "</div>" +
          '<div class="cc-facts">' + esc(facts) + "</div>" +
          '<div class="cc-web ' + (done ? "cc-web-on" : "cc-web-off") + '">' +
            (done ? "On the website" : "Not on the website yet") + "</div>" +
          (done ? "" :
            '<div class="cc-why">A class is only published once its page is ' +
            "finished. Until then the website leaves it out altogether — there is " +
            "no card for it on the Education page and no page to reach. Press Edit " +
            "and fill in “Its page on the website”.</div>") +
          '<div class="cc-acts">' +
            '<button type="button" class="btn btn-ghost" data-act="edit" data-key="' +
              esc(c.key) + '">Edit</button>' +
            '<button type="button" class="btn btn-ghost' + (open ? " cc-shut" : "") +
              '" data-act="' + (open ? "shut" : "open") + '" data-key="' + esc(c.key) + '">' +
              (open ? "Close sign-ups" : "Open sign-ups") + "</button>" +
            '<button type="button" class="btn btn-ghost cp-no" data-act="remove" ' +
              'data-key="' + esc(c.key) + '">Remove</button>' +
          "</div>" +
        "</div>";
      }).join("");
    }

    /*  One repeating editor, drawn four times over. `fields` is what each row
        holds; `acts` is what can be done to it. The sessions pass neither an
        add button nor a remove one, which is the whole point of them. */
    function drawRows(hostId, list, opts) {
      var host = el(hostId);
      if (!host) return;

      if (!list.length) {
        host.innerHTML = '<div class="cc-empty">' + opts.empty + "</div>";
      } else {
        host.innerHTML = list.map(function (item, i) {
          var acts = "";
          if (opts.move) {
            acts += '<button type="button" class="btn btn-ghost cp-mini" data-act="up"' +
              (i === 0 ? " disabled" : "") + ">Up</button>" +
              '<button type="button" class="btn btn-ghost cp-mini" data-act="down"' +
              (i === list.length - 1 ? " disabled" : "") + ">Down</button>";
          }
          if (opts.min !== undefined) {
            acts += '<button type="button" class="btn btn-ghost cp-mini cp-no" ' +
              'data-act="remove"' + (list.length <= opts.min ? " disabled" : "") +
              ">Remove</button>";
          }
          return '<div class="cp-item" data-i="' + i + '">' +
            '<div class="cp-item-top">' +
              '<span class="cp-item-n">' + esc(opts.label(item, i, list.length)) + "</span>" +
              (acts ? '<span class="cp-acts">' + acts + "</span>" : "") +
            "</div>" +
            '<div class="' + opts.grid + '">' +
              opts.fields(item, i).join("") +
            "</div>" +
          "</div>";
        }).join("");
      }

      if (opts.addId) {
        var add = el(opts.addId);
        if (add) add.disabled = list.length >= opts.max;
        var ceiling = el(opts.ceilingId);
        if (ceiling) ceiling.hidden = list.length < opts.max;
      }
    }

    function textField(label, f, value, maxlen, placeholder, hint) {
      return '<label class="fld"><span>' + esc(label) + "</span>" +
        '<input type="text" data-f="' + f + '" maxlength="' + maxlen +
        '" value="' + esc(value) + '" placeholder="' + esc(placeholder) + '">' +
        (hint ? '<span class="cp-hint">' + hint + "</span>" : "") +
        "</label>";
    }

    function areaField(label, f, value, maxlen, placeholder) {
      return '<label class="fld"><span>' + esc(label) + "</span>" +
        '<textarea data-f="' + f + '" rows="3" maxlength="' + maxlen +
        '" placeholder="' + esc(placeholder) + '">' + esc(value) + "</textarea></label>";
    }

    function drawFacts() {
      drawRows("cp-facts", (doc && doc.facts) || [], {
        empty: "No facts. The strip beside the form is left off altogether, " +
               "which is fine — it is the class page's headline numbers, not " +
               "its content.",
        grid: "cp-pair",
        min: 0,
        max: FACTS_MAX,
        addId: "cp-add-fact",
        ceilingId: "cp-fact-ceiling",
        label: function (item, i, n) { return "Fact " + (i + 1) + " of " + n; },
        fields: function (item) {
          return [
            textField("Label", "k", item.k, 40, "Time"),
            textField("Value", "v", item.v, 40, "7–8pm")
          ];
        }
      });
    }

    function drawRules() {
      drawRows("cp-rules", (doc && doc.rules) || [], {
        empty: "No rows. The website will not publish a class with none.",
        grid: "cp-grid2",
        move: true,
        min: RULES_MIN,
        max: RULES_MAX,
        addId: "cp-add-rule",
        ceilingId: "cp-rule-ceiling",
        label: function (item, i, n) { return "Row " + (i + 1) + " of " + n; },
        fields: function (item) {
          return [
            textField("Label", "k", item.k, 44, "When"),
            areaField("What it says", "v", item.v, 500,
                      "One evening a week, 7:00–8:00pm.")
          ];
        }
      });
    }

    /*  THE SESSIONS. A fixed number of label boxes, drawn from the Sessions
        dropdown a few inches above them, with no add and no remove — see the
        note at the top of this module and the paragraph the screen prints. */
    function drawCohorts() {
      var list = (doc && doc.cohorts) || [];
      drawRows("cp-cohorts", list, {
        empty: "No sessions. This cannot happen from this screen; reload it.",
        grid: "cp-grid2",
        label: function (item) {
          return item.key === "all" ? "Everybody" :
                 item.key === "mens" ? "Men’s session" : "Women’s session";
        },
        fields: function (item) {
          return [
            textField("What people will see it called", "label", item.label, 90,
                      item.key === "all" ? "Class" :
                      item.key === "mens" ? "Men’s class" : "Women’s class"),
            '<p class="cp-hint">Filed under <span class="cc-key">' + esc(item.key) +
              "</span>. Every sign-up carries that word, so it cannot change — the " +
              "wording above it can say anything you like.</p>"
          ];
        }
      });

      var why = el("cp-cohort-why");
      if (!why) return;
      var single = wantedKeys((el("cc-mode") || {}).value).length === 1;
      why.innerHTML = "This class is set to <strong>" +
        (single ? "one session for everyone" : "separate men’s and women’s sessions") +
        "</strong> under <strong>Sessions</strong> above, so it has " +
        (single ? "one box" : "two boxes") + " here and there is <strong>no way to add " +
        "another</strong>. Every sign-up is filed under " +
        (single ? "the word “all”" : "the words “mens” and “womens”") +
        ", and the database will only accept those two and “all”. A session invented " +
        "here would save perfectly well and then <strong>refuse every single sign-up " +
        "against it</strong> with an error nobody could read.";

      /*  A box that has gone empty on a class that WAS written means the
          Sessions dropdown has been changed. The old wording is not carried
          across on purpose — "Men's class" over a session for everybody reads
          perfectly well and turns half the masjid away — so this says what
          happened rather than leaving it looking like the screen lost their
          work. */
      var lost = list.some(function (c) { return !trim(c.label); }) &&
                 trim(doc && doc.tagline) !== "";
      if (lost) {
        why.innerHTML += " <strong>One of these boxes is empty because the class " +
          "has been switched between one session and two.</strong> The old wording " +
          "is not moved across — it would end up on a session it was never written " +
          "for — so please write it again.";
      }
    }

    function drawExps() {
      drawRows("cp-exps", (doc && doc.exp) || [], {
        empty: "No answers. The website will not publish a class with fewer than two.",
        grid: "cp-grid2",
        min: EXP_MIN,
        max: EXP_MAX,
        addId: "cp-add-exp",
        ceilingId: "cp-exp-ceiling",
        label: function (item, i, n) { return "Answer " + (i + 1) + " of " + n; },
        fields: function (item) {
          return [
            textField("Filing name", "key", item.key, 24, "none",
              "Lower case letters, numbers and underscores. Nobody sees it."),
            textField("What people will read", "label", item.label, 140,
                      "None at all — starting from the alphabet")
          ];
        }
      });
    }

    function drawMeta(b) {
      var box = el("cp-meta");
      if (!box) return;
      if (!doc) { box.textContent = ""; return; }
      box.textContent = whole(b)
        ? "As it stands, this page is complete and the class is on the website."
        : "As it stands, this page is NOT complete, so the website leaves this " +
          "class out altogether. The class itself still exists and the register " +
          "below still works.";
    }

    /* ---------------------------------------------------------- the preview
       Drawn to look like the real class page — the plum masthead, the fact
       strip in the rail, the what-to-know list, the sign-up block with the
       session buttons and the experience question in it — because the whole
       job of this panel is to let somebody recognise what they are about to
       publish. Escaped on the way in: this is written by a verified
       administrator, but it is also the only content on the site that a
       non-developer types straight onto a public page. */
    function drawPreview(b) {
      var host = el("cp-pv");
      if (!host) return;
      var bits = [];
      var isOpen = !!(editing && editing.is_open);

      bits.push('<div class="cp-pv-mast">' +
        '<span class="cp-pv-eyebrow">Education</span>' +
        "<h4>" + esc(b.name || "(no name)") + "</h4>" +
        '<p class="cp-pv-tag">' +
          (b.tagline ? esc(b.tagline) : "<em>The one-line description is empty.</em>") +
        "</p></div>");

      bits.push('<div class="cp-pv-body">');

      // --- the rail: the fact strip and the sign-up block
      bits.push("<div>");
      if (b.facts.length) {
        bits.push('<div class="cp-pv-facts">' + b.facts.map(function (fct) {
          return '<div class="cp-pv-fact"><span class="cp-pv-k">' +
            esc(fct.k || "(no label)") + '</span><span class="cp-pv-v">' +
            esc(fct.v || "—") + "</span></div>";
        }).join("") + "</div>");
      }

      bits.push('<div class="cp-pv-form">');
      bits.push('<span class="cp-pv-when">' +
        (isOpen ? "Shown now — sign-ups are open" : "Shown if sign-ups are opened") +
        "</span>");
      bits.push('<p class="cp-pv-lead">' +
        (b.open ? esc(b.open) : '<span class="cp-pv-bad">no open wording</span>') + "</p>");

      bits.push('<span class="cp-pv-q">Which session?</span>');
      bits.push('<span class="cp-pv-opts">' + b.cohorts.map(function (c) {
        return '<span class="cp-pv-opt">' +
          (c.label ? esc(c.label)
                   : '<span class="cp-pv-bad">this session has no label</span>') +
          "</span>";
      }).join("") + "</span>");

      bits.push('<span class="cp-pv-q">' +
        (b.exp_label ? esc(b.exp_label)
                     : '<span class="cp-pv-bad">no experience question</span>') +
        "</span>");
      bits.push('<span class="cp-pv-opts">' + b.exp.map(function (a) {
        return '<span class="cp-pv-opt">' +
          (a.label ? esc(a.label) : '<span class="cp-pv-bad">no wording</span>') +
          "</span>";
      }).join("") + "</span>");
      bits.push("</div>");

      bits.push('<p class="cp-pv-shut"><strong>' +
        (isOpen ? "Shown instead once sign-ups are shut: " : "Shown now — sign-ups are shut: ") +
        "</strong>" +
        (b.closed ? esc(b.closed)
                  : '<span class="cp-pv-bad">no shut wording</span>') + "</p>");
      bits.push("</div>");

      // --- the body: the opening paragraph and the what-to-know list
      bits.push("<div>");
      bits.push('<p class="cp-pv-intro">' +
        (b.intro ? esc(b.intro) : "<em>The opening paragraph is empty.</em>") + "</p>");
      if (b.rules.length) {
        bits.push('<dl class="cp-pv-rules">' + b.rules.map(function (r) {
          return "<dt>" + esc(r.k || "(no label)") + "</dt><dd>" +
            (r.v ? esc(r.v) : '<span class="cp-pv-bad">nothing against it</span>') +
            "</dd>";
        }).join("") + "</dl>");
      }
      bits.push("</div>");
      bits.push("</div>");

      // --- and the card somebody clicks to get here
      bits.push('<div class="cp-pv-tile">' +
        '<span class="cp-pv-tag2">' + esc(b.tile.tag || "Adults 16+") + "</span>" +
        '<span class="cp-pv-th">' + esc(b.name || "(no name)") + "</span>" +
        '<span class="cp-pv-tp">' + esc(b.tile.p || b.tagline || "") + "</span>" +
        '<span class="cp-pv-tm">' + esc(b.tile.meta || "") + "</span>" +
        "</div>");

      host.innerHTML = bits.join("");
    }

    /*  Re-run after every keystroke. The Save button is the only way to reach
        save_course() and save_course_page(), so this is where "nothing is
        saveable until BOTH halves are right" actually lives — the `disabled`
        in the markup only covers the first paint. */
    function revalidate() {
      var btn = el("cc-save");

      if (!doc) {
        //  Nothing is open, so there is nothing that could be saved. Said in
        //  the button rather than left to the markup, because the markup is
        //  one tidy-up away from losing the attribute.
        if (btn) btn.disabled = true;
        complaintsInto("cc-complaints", []);
        complaintsInto("cp-complaints", []);
        drawMeta(null);
        return ["No class is open."];
      }

      var f = readCourseForm();
      countdown("cc-name-count", f.name, NAME_MAX);
      var classBad = checkCourse(f);
      complaintsInto("cc-complaints", classBad);

      var b = pageOut();
      countdown("cp-tagline-count",   b.tagline,   TAGLINE_MAX);
      countdown("cp-intro-count",     b.intro,     INTRO_MAX);
      countdown("cp-exp-label-count", b.exp_label, EXPQ_MAX);
      countdown("cp-open-count",      b.open,      BLURB_MAX);
      countdown("cp-closed-count",    b.closed,    BLURB_MAX);
      drawPreview(b);
      drawMeta(b);

      //  See nothingWritten(): a page nobody has started is a legal state and
      //  is not complained about. One word in any box and the whole page has
      //  to be right, because that is what save_course_page() will insist on.
      var pageBad = (nothingWritten(b) && !writtenAlready())
        ? [] : checkPage(b, f.cohort_mode);
      complaintsInto("cp-complaints", pageBad);

      if (btn) btn.disabled = (classBad.length + pageBad.length) > 0;
      return classBad.concat(pageBad);
    }

    function draw() {
      drawList();

      var ed = el("cc-editor");
      if (!doc) {
        if (ed) ed.hidden = true;
        revalidate();
        return;
      }
      if (ed) ed.hidden = false;

      //  The class's own boxes are NOT rewritten here. They are set once when
      //  the editor opens and are read, never written, afterwards — a redraw
      //  fires on every added row, and putting a value back into a box
      //  somebody is typing in moves their cursor to the end of it.
      [["cp-tagline", doc.tagline], ["cp-intro", doc.intro],
       ["cp-exp-label", doc.exp_label], ["cp-open", doc.open],
       ["cp-closed", doc.closed], ["cp-tile-tag", doc.tile.tag],
       ["cp-tile-p", doc.tile.p], ["cp-tile-meta", doc.tile.meta]
      ].forEach(function (pair) {
        var box = el(pair[0]);
        if (box) box.value = pair[1] || "";
      });

      drawFacts();
      drawRules();
      drawCohorts();
      drawExps();
      revalidate();
    }

    function focusLast(hostId) {
      var host = el(hostId);
      if (!host) return;
      var items = host.querySelectorAll(".cp-item");
      var last = items[items.length - 1];
      if (!last) return;
      last.scrollIntoView({ behavior: "smooth", block: "center" });
      var first = last.querySelector("input");
      if (first) first.focus();
    }

    // ---- opening and shutting the editor -------------------------------------
    function openEditor(c, quiet) {
      editing = c || null;
      var mode = c && c.cohort_mode === "single" ? "single" : "separate";

      var key = el("cc-key");
      if (key) {
        key.value = c ? (c.key || "") : "";
        //  THE WEBSITE NAME IS THE FOREIGN KEY. Every registration ever taken
        //  is filed under it, so letting somebody retype it here would leave
        //  those people attached to a class that no longer exists — and
        //  save_course() would not complain, because a new key is simply a new
        //  row. Disabled, with the reason printed beside it.
        key.disabled = !!c;
      }
      if (el("cc-name"))     el("cc-name").value     = c ? (c.name || "") : "";
      if (el("cc-mode"))     el("cc-mode").value     = mode;
      if (el("cc-capacity")) el("cc-capacity").value = c ? (c.capacity == null ? "" : c.capacity) : "15";
      if (el("cc-order"))    el("cc-order").value    = c ? (c.sort_order == null ? "0" : c.sort_order) : "0";
      if (el("cc-key-hint"))   el("cc-key-hint").hidden   = !!c;
      if (el("cc-key-locked")) el("cc-key-locked").hidden = !c;

      var fk = el("cc-form-key");
      if (fk) { fk.textContent = c ? c.key : ""; fk.hidden = !c; }
      if (el("cc-form-head")) {
        el("cc-form-head").textContent = c ? ("Edit " + (c.name || c.key)) : "Add a class";
      }
      if (el("cc-form-lede")) {
        el("cc-form-lede").textContent = c
          ? "Everything about this class is here — what it is called and how many " +
            "places it has, and every word its page on the website shows. Saving " +
            "puts all of it on the website at once; there is no draft."
          : "A new class and its page are saved together. Nothing here is a draft: " +
            "whatever you save is what the website shows, so read the preview at " +
            "the bottom first. You can leave the page empty for now and write it " +
            "later — the class simply stays off the website until you do.";
      }

      var taken = Number((c && c.taken) || 0);
      if (el("cc-places-note")) {
        el("cc-places-note").textContent = taken > 0
          ? (taken === 1
              ? "One person already holds a place on this class"
              : taken + " people already hold a place on this class") +
            ", so the places cannot be set below " + taken + ". The database refuses " +
            "it: those people have already been told they have a seat. Move somebody " +
            "to the waiting list first."
          : "Anything from 1 to 500 places. The order decides which class comes " +
            "first on the website; the smaller number goes first.";
      }

      saveLabel = c ? "Save this class and its page" : "Add the class";
      if (el("cc-save")) el("cc-save").textContent = saveLabel;

      doc   = normalise(c ? c.page : {}, c ? c.name : "", mode);
      saved = JSON.stringify(doc);
      draw();
      //  wire() opens a blank one purely so the editor is not an empty div on
      //  a page nobody has signed in to. Scrolling and grabbing the keyboard
      //  for that would be a page jumping about on its own.
      if (quiet) return;
      if (el("cc-editor")) el("cc-editor").scrollIntoView({ block: "start" });
      if (el("cc-name")) el("cc-name").focus();
    }

    function shutEditor() {
      editing = null;
      doc = null;
      saved = null;
      draw();
      var list = el("cc-list");
      if (list) list.scrollIntoView({ block: "start" });
    }

    // ---- reading ------------------------------------------------------------
    /*  TWO CALLS, JOINED IN THE BROWSER, and neither is optional.

        courses_admin_list() has the counts — how many places are taken, how
        many are waiting — and does NOT return the page copy. courses_public()
        has the page copy and is the same content the website itself reads,
        which is exactly what the list has to judge "on the website" by;
        `courses` denies a direct SELECT, so there is no third option. They are
        joined on `key`. */
    function load(keepDoc) {
      return Promise.all([
        sb.rpc("courses_admin_list"),
        sb.rpc("courses_public")
      ]).then(function (out) {
        if (out[0].error) {
          // Until 043 is applied none of these functions exist. That is "not
          // set up yet", not "broken", and saying so saves somebody hunting a
          // fault that isn't there.
          if (/does not exist|schema cache|function/i.test(out[0].error.message || "")) {
            throw new Error("Managing the classes needs " +
                            "043_courses_the_committee_can_open_and_close.sql, " +
                            "which hasn't been run yet.");
          }
          throw new Error(out[0].error.message);
        }
        if (out[1].error) throw new Error(out[1].error.message);

        var pages = {};
        (Array.isArray(out[1].data) ? out[1].data : []).forEach(function (c) {
          if (c && c.key) pages[c.key] = c.page || {};
        });

        rows = (Array.isArray(out[0].data) ? out[0].data : []).map(function (c) {
          c = c || {};
          return {
            key: c.key, name: c.name, cohort_mode: c.cohort_mode,
            capacity: c.capacity, is_open: c.is_open, sort_order: c.sort_order,
            taken: c.taken, waiting: c.waiting,
            page: pages[c.key] || {}
          };
        }).sort(function (a, b) {
          return (a.sort_order || 0) - (b.sort_order || 0) ||
                 String(a.key).localeCompare(String(b.key));
        });

        //  Whichever class was open stays open. keepDoc is for the one case
        //  that matters: a save that half worked. Re-reading the boxes from
        //  the database there would throw away the very words that failed to
        //  save, and they are the only copy left of them.
        if (editing) {
          var still = byKey(editing.key);
          if (still) {
            editing = still;
            if (!keepDoc) {
              doc = normalise(still.page, still.name, still.cohort_mode);
              saved = JSON.stringify(doc);
            }
          } else if (!keepDoc) {
            editing = null; doc = null; saved = null;
          }
        }
        draw();
      });
    }

    // The register below shows the same classes, so both are re-read together.
    function refresh(keepDoc) {
      return load(keepDoc).then(function () {
        try { register.refresh(); } catch (e) {
          if (window.console) console.warn("register wouldn't reload:", e);
        }
      });
    }

    // ---- writing -------------------------------------------------------------
    /*  ONE SAVE, TWO CALLS, IN THIS ORDER AND NO OTHER.

        save_course() first: save_course_page() begins by looking the key up in
        `courses` and raises "There is no class with that website name" when it
        is not there, so a brand new class cannot have its page written until
        the class exists.

        If the first works and the second does not, the class is real and its
        page is not. That is said in those words. Reporting it as a plain
        failure would send somebody back to press Add again, and the second
        press would silently be an edit of a class they did not know they had
        made. */
    function save() {
      if (!doc) return;
      if (revalidate().length) return;   // belt and braces; the button is disabled too

      var f    = readCourseForm();
      var page = pageOut();
      var p = {
        key:         trim(f.key).toLowerCase(),
        name:        trim(f.name),
        cohort_mode: trim(f.cohort_mode).toLowerCase(),
        capacity:    trim(f.capacity),
        sort_order:  trim(f.sort_order) === "" ? "0" : trim(f.sort_order)
      };
      //  A page nobody has started is left alone rather than sent: the
      //  database would refuse '{}' with "the class needs a one-line
      //  description", and the class itself saved perfectly well.
      var writePage = !(nothingWritten(page) && !writtenAlready());
      var wasWhole  = whole(editing && editing.page);
      var btn        = el("cc-save");
      var classSaved = false;
      //  Set the instant BOTH writes are through. Without it, a reload that
      //  fails after a perfectly good save lands in the same catch below and
      //  gets reported as "the page did not save" — which would be a lie, and
      //  the sort of lie that has somebody retyping a page that is already up.
      var allSaved   = false;

      busy(btn, true, saveLabel);
      note("cc-error", ""); note("cc-ok", "");

      //  The argument is named `p` — save_course(p jsonb). Supabase sends the
      //  keys of this object as the function's named arguments, so a wrapper
      //  key of any other name is a "function does not exist" error.
      sb.rpc("save_course", { p: p }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        classSaved = true;
        var isNew = !!(res.data || {}).is_new;

        if (!writePage) {
          note("cc-ok", (isNew
            // is_open defaults to false (004), so a new class is not quietly
            // taking sign-ups the moment it is added.
            ? "Added, with sign-ups closed. "
            : "Saved. Whether sign-ups are open is unchanged. ") +
            "Its page has not been written, so the website leaves this class out " +
            "altogether. Press Edit when you are ready to write it.");
          return null;
        }

        //  save_course_page(p_key text, p_page jsonb) — the argument names are
        //  the keys of this object. Anything else is "function does not exist".
        return sb.rpc("save_course_page", { p_key: p.key, p_page: page })
          .then(function (res2) {
            if (res2.error) throw new Error(res2.error.message);
            note("cc-ok", (isNew
              ? "Added, with sign-ups closed — open them on the class above when " +
                "you are ready. "
              : "Saved. Whether sign-ups are open is unchanged. ") +
              "Its page is on the website now" +
              (wasWhole ? "." : ", and the class has a card on the Education page " +
                               "for the first time."));
          });
      }).then(function () {
        allSaved = true;
        shutEditor();
        return refresh();
      }).catch(function (e) {
        var msg = (e && e.message) || String(e);
        if (allSaved) {
          note("cc-error", "Everything saved. The list on this screen couldn't be " +
                           "re-read afterwards — " + msg + " Refresh the page to see " +
                           "where things stand; nothing is waiting to be saved.");
          return;
        }
        note("cc-error", classSaved
          ? "The class itself was saved, but its page was NOT: " + msg +
            " The class exists — it is in the list above — and the website will " +
            "leave it out until the page saves. Fix what the message says and press " +
            "Save again; do not press Add a class a second time."
          : "Nothing was saved — " + msg);
        //  The list is re-read either way, so a class that WAS created shows
        //  up; the boxes are left exactly as they are, because on the half-done
        //  path they hold the only copy of the words that did not save.
        return refresh(true).catch(function () {});
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

    /*  REMOVING. delete_course() (048, and 049 for the wording) refuses while
        anybody has signed up, and refuses in a sentence written to be read by
        the person who pressed the button. That sentence is shown exactly as it
        arrives: rewording it here would be a second copy of a message that is
        already right, and the two would drift apart the first time either
        changed. */
    function remove(key, name) {
      if (!window.confirm(
            "Remove “" + (name || key) + "” altogether?\n\n" +
            "This deletes the class and every word its page on the website says. " +
            "It is permanent — there is no undo, and nothing keeps a copy.\n\n" +
            "If anybody has signed up, the database will refuse and tell you so; " +
            "close sign-ups instead, which takes it off the website and keeps the " +
            "list.")) return null;

      note("cc-error", ""); note("cc-ok", "");
      return sb.rpc("delete_course", { p_key: key })
        .then(function (res) {
          if (res.error) {
            if (/does not exist|schema cache|function/i.test(res.error.message || "")) {
              throw new Error("Removing a class needs 048_a_class_can_be_removed.sql " +
                              "and 049_one_person_is_not_people.sql, which haven't " +
                              "been run yet. Nothing was changed.");
            }
            throw new Error(res.error.message);
          }
          note("cc-ok", "“" + (name || key) + "” has been removed. It is off the " +
                        "website and out of the list.");
          if (editing && editing.key === key) shutEditor();
          return refresh();
        })
        .catch(function (e) { note("cc-error", e.message || String(e)); });
    }

    // ---- the repeating editors -----------------------------------------------
    /*  One handler for all four lists. `listName` is the array behind the host,
        and a list with no add button (the sessions) never reaches here because
        it draws no buttons at all. */
    function onRowClick(listName, minimum) {
      return function (ev) {
        var btn = ev.target.closest ? ev.target.closest("button[data-act]") : null;
        if (!btn || btn.disabled) return;
        var row = btn.closest(".cp-item");
        if (!row || !doc) return;

        //  Read the boxes back BEFORE anything is reordered or redrawn, or
        //  whatever has been typed since the last draw is thrown away.
        harvest();
        var list = doc[listName];
        if (!Array.isArray(list)) return;
        var i = Number(row.getAttribute("data-i"));
        if (!list[i]) return;
        var act = btn.getAttribute("data-act");

        if (act === "remove") {
          if (list.length <= minimum) return;
          list.splice(i, 1);
        } else if (act === "up" && i > 0) {
          list.splice(i - 1, 0, list.splice(i, 1)[0]);
        } else if (act === "down" && i < list.length - 1) {
          list.splice(i + 1, 0, list.splice(i, 1)[0]);
        }
        draw();
      };
    }

    function adder(listName, max, blankRow, hostId) {
      return function () {
        if (!doc) return;
        harvest();
        if (!Array.isArray(doc[listName])) doc[listName] = [];
        if (doc[listName].length >= max) return;
        doc[listName].push(blankRow());
        draw();
        focusLast(hostId);
      };
    }

    // ---- wiring --------------------------------------------------------------
    /*  Attaches every listener and leaves a usable, empty editor behind. It
        must work with no session and no network — see the note beside
        window.__COURSE_FORM. */
    function wire() {
      if (wired) return true;
      wired = true;

      ["cc-key", "cc-name", "cc-capacity", "cc-order"].forEach(function (id) {
        var node = el(id);
        if (!node) return;
        node.addEventListener("input", revalidate);
        node.addEventListener("change", revalidate);
      });

      /*  THE SESSIONS DROPDOWN IS NOT AN ORDINARY FIELD. It decides which
          session rows the page must carry, and those rows are now on the same
          screen — so changing it rewrites them there and then, keeping a label
          only where its key survives. See carry(). */
      var mode = el("cc-mode");
      if (mode) mode.addEventListener("change", function () {
        if (doc) {
          harvest();
          doc.cohorts = carry(doc.cohorts || [], this.value);
        }
        draw();
      });

      ["cp-tagline", "cp-intro", "cp-exp-label", "cp-open", "cp-closed",
       "cp-tile-tag", "cp-tile-p", "cp-tile-meta"].forEach(function (id) {
        var box = el(id);
        if (box) box.addEventListener("input", revalidate);
      });

      /*  One listener on each container rather than one per box: the rows are
          redrawn whenever anything is added, removed or moved, so per-row
          listeners would be re-attached each time and the old ones left
          behind. */
      [["cp-facts", "facts", 0], ["cp-rules", "rules", RULES_MIN],
       ["cp-cohorts", "cohorts", 99], ["cp-exps", "exp", EXP_MIN]
      ].forEach(function (h) {
        var host = el(h[0]);
        if (!host) return;
        host.addEventListener("input", revalidate);
        host.addEventListener("click", onRowClick(h[1], h[2]));
      });

      var addFact = el("cp-add-fact");
      if (addFact) addFact.addEventListener("click",
        adder("facts", FACTS_MAX, function () { return { k: "", v: "" }; }, "cp-facts"));

      var addRule = el("cp-add-rule");
      if (addRule) addRule.addEventListener("click",
        adder("rules", RULES_MAX, function () { return { k: "", v: "" }; }, "cp-rules"));

      var addExp = el("cp-add-exp");
      if (addExp) addExp.addEventListener("click",
        adder("exp", EXP_MAX, function () { return { key: "", label: "" }; }, "cp-exps"));

      var saveBtn = el("cc-save");
      if (saveBtn) saveBtn.addEventListener("click", save);

      var addBtn = el("cc-add");
      if (addBtn) addBtn.addEventListener("click", function () {
        note("cc-error", ""); note("cc-ok", "");
        openEditor(null);
      });

      var cancel = el("cc-cancel");
      if (cancel) cancel.addEventListener("click", function () {
        shutEditor();
        note("cc-error", ""); note("cc-ok", "");
      });

      var revert = el("cp-revert");
      if (revert) revert.addEventListener("click", function () {
        if (!saved || !doc) {
          note("cc-error", "There is nothing to go back to — no class is open.");
          return;
        }
        if (!window.confirm("Throw away the changes you have made on this screen?\n\n" +
              "The website is unaffected either way — nothing has been saved.")) return;
        doc = JSON.parse(saved);
        if (el("cc-name")) el("cc-name").value = doc.name || "";
        draw();
        note("cc-error", "");
        note("cc-ok", "Back to what is on the website.");
      });

      var list = el("cc-list");
      if (list) list.addEventListener("click", function (ev) {
        var btn = ev.target.closest ? ev.target.closest("button[data-act]") : null;
        if (!btn || btn.disabled) return;
        var key = btn.getAttribute("data-key");
        var c   = byKey(key);
        var act = btn.getAttribute("data-act");

        if (act === "edit") {
          note("cc-error", ""); note("cc-ok", "");
          if (c) openEditor(c);
          return;
        }
        if (act === "remove") {
          btn.disabled = true;
          if (!remove(key, c && c.name)) btn.disabled = false;
          return;
        }
        btn.disabled = true;
        //  A cancelled confirm does nothing at all, so the button has to come
        //  back — otherwise the row is dead until the list is next drawn.
        if (!setOpen(key, act === "open", c && c.name)) btn.disabled = false;
      });

      //  An empty <div> where the editor should be is indistinguishable from a
      //  broken screen, so wiring alone leaves a blank "Add a class" open.
      openEditor(null, true);
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
      shutEditor();   // the list first; the editor is opened by Edit or Add

      return load().catch(function (e) {
        var box = el("cc-list");
        if (box) box.innerHTML = '<div class="cc-empty">The class list couldn’t ' +
                                 'be read — the message above says why.</div>';
        note("cc-error", "Couldn't read the classes: " + (e.message || e));
      });
    }

    return { mount: mount, _checkCourse: checkCourse, _checkPage: checkPage,
             _wire: wire };
  })();

  /*  EXPOSED FOR THE TESTS, on the same reasoning as __NOTICE_FORM in notices/.

      There are two validators because there are two database functions, and
      each has to agree with its own one exactly. checkCourse() is
      check_course() from 043; checkPage() is check_course_page() from 047.
      Both are pure — no DOM, no network, no state. Where either disagrees with
      Postgres a volunteer is told something is fine and then handed a raw
      constraint name, which is the fault 041, 043, 045 and 047 all carry a
      validator to prevent.

      The two names are kept even though the screens behind them were merged.
      They are what the existing suites call, and a rename would have bought a
      tidier pair of globals at the cost of two test files that no longer test
      anything.

      wire() is not pure, and it is here because of a trap this project has
      already fallen into twice. The rule "nothing is saveable until the form
      is valid" would otherwise live only inside mount(), which runs after a
      real sign-in — so no test could reach it, and the Save button is disabled
      in the markup as well, so it would read as disabled whether the rule was
      there or had been deleted. The check passed with the code removed.
      Wiring the form on a page nobody is signed in to gives a Save button
      whose click calls save_course() and save_course_page(), both of which
      Postgres refuses to anybody who is not a verified admin with two-step.
      The permission is in the database, not in this file. */
  window.__COURSE_FORM    = { check: classes._checkCourse, wire: classes._wire };
  window.__CLASSPAGE_FORM = { check: classes._checkPage,   wire: classes._wire };

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
