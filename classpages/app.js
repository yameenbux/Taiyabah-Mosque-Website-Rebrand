/* ===========================================================================
   Taiyabah Masjid — what the website says about a class
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   db/043 let the committee open, close, rename and re-size a class. It could
   not let them ADD one, and the screen said so in those words: the website
   held more about a course than the table did — which sessions it runs, what
   the experience question asks, the wording shown when sign-ups are shut —
   and none of that was anywhere but a hard-coded object in
   index_template.html. save_course() would create the row, and a row with no
   section on the website is invisible.

   db/047 moved that content into courses.page. This is the screen that writes
   it. Adding the class itself is still the Adult classes screen's job; this
   one writes the words for a class that already exists.

   THE SHAPE OF THIS SCREEN, AND WHY
   ---------------------------------
     * SAVING IS PUBLISHING. There is no draft. save_course_page() writes the
       row the public page reads, and the class page picks it up on the next
       load. Notices and the prayer timetable both have a draft state and
       somebody moving between the three screens will assume this one does
       too — so the lede says so, the Save button says so, and the preview is
       there to be read before it is pressed.

     * A CLASS IS ONLY ON THE WEBSITE ONCE ITS PAGE IS FINISHED. The public
       page refuses to draw a half-written class — a masthead over an empty
       body looks entirely normal and is wrong — and skips it silently. From
       the committee's side that is indistinguishable from the website being
       broken, so whole() below is the SAME test the website applies, and the
       list says "Not on the website yet" in those words rather than leaving
       somebody to wonder why their new class never appeared.

     * THE COHORT KEYS ARE NOT THEIRS TO INVENT, and this is the single most
       important rule on the screen. course_registrations has carried
       `check (cohort = any (array['mens','womens','all']))` since db/004. A
       screen that let somebody type a fourth — "children", "over 60s" —
       would save happily and then refuse every single sign-up against it
       with a raw constraint error. So the session boxes are drawn from the
       class's own cohort_mode, there is no "add a session" button, and the
       keys never appear as an editable field. The LABELS are theirs
       ("Men's class", "Brothers", "Men's session"); the keys underneath are
       the database's.

     * THE COMPLAINTS ARE THE DATABASE'S OWN. check() below is
       check_course_page() from 047, rule for rule. It is copied rather than
       invented because a validator and a constraint that disagree put a raw
       Postgres error in front of a volunteer; that has already happened once
       on this project, which is why 041 and then 045 and 047 exist. A rule
       this screen claims that the database does NOT have is just as bad — it
       stops somebody doing something they are allowed to do, and nothing
       will ever contradict it.

     * SAVE IS DISABLED UNTIL THE PAGE IS VALID, with the reasons listed above
       the button, and the ceilings are enforced by disabling "add" rather
       than by letting somebody meet a database error.

   None of this is a security control. It is JavaScript in a browser with the
   anon key beside it, and save_course_page() is refused by Postgres to
   anybody who is not a verified administrator with two-step. It is here so a
   committee member is told what is wrong in plain English.
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

  /* ------------------------------------------------------------------ the
     CLASS PAGE MODULE. Everything on this screen, kept in one place so that
     if it throws, the sign-in shell around it survives — see renderApp. */
  var classpage = (function () {
    "use strict";

    /*  EVERY NUMBER HERE IS A NUMBER IN check_course_page(). They are named
        rather than typed into the messages twice, because a limit quoted in
        one place and enforced in another is a limit that drifts. */
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

    var SAVE_LABEL = "Save — this goes live at once";

    var rows    = [];     // every class: the counts joined to the page copy
    var current = null;   // the class being edited, from `rows`
    var doc     = null;   // its page object, as it is being edited
    var saved   = null;   // what came back from the database, for Undo
    var wired   = false;

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function trim(v) { return String(v == null ? "" : v).trim(); }

    function note(id, msg) {
      var n = el(id); if (!n) return;
      if (!msg) { n.hidden = true; n.textContent = ""; return; }
      n.textContent = msg; n.hidden = false;
    }

    function has(o, k) { return Object.prototype.hasOwnProperty.call(o, k); }

    /*  Which keys a class's sessions must carry, from its cohort_mode. The
        default is `separate`, because that is what check_course_page() does
        with anything that is not the word "single" — the two have to agree or
        the screen would demand two rows where the database wanted one. */
    function wantedKeys(mode) {
      return String(mode == null ? "" : mode).trim().toLowerCase() === "single"
        ? SINGLE_KEYS.slice() : SEPARATE_KEYS.slice();
    }

    /* =====================================================================
       check() — check_course_page() from 047, in the browser

       PURE. No DOM, no network, no session. It takes the page object that
       would be sent as p_page, plus the class's cohort_mode — which the
       database passes in for the same reason, because it is the whole reason
       the cohort keys can be validated at all — and returns the list of
       things wrong with it, empty when there is nothing.

       Postgres returns only the first complaint because a plpgsql function
       returns once; a person filling a form would rather see all of them at
       once, so this collects them in the same order.

       Every message here has a counterpart in 047. If one is changed there,
       it is changed here — and if a rule is added there that is not added
       here, a volunteer meets it as a raw constraint violation, which is the
       fault 041 and 045 were written to end.
       =================================================================== */
    function check(o, mode) {
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
        //  The number is quoted back, because "too long" without a number
        //  means deleting words until it stops complaining.
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

    /*  The shape the database will accept with the least in it. Used for a
        class whose page has never been written, and by wire() on a page
        nobody is signed in to — an empty <div> where the editor should be is
        indistinguishable from a broken screen. */
    function blank(name, mode) {
      return {
        name: name || "",
        tagline: "",
        intro: "",
        facts: [],
        rules: [{ k: "", v: "" }],
        cohorts: wantedKeys(mode).map(function (k) { return { key: k, label: "" }; }),
        exp_label: "",
        exp: [{ key: "", label: "" }, { key: "", label: "" }],
        open: "",
        closed: "",
        tile: { tag: "", p: "", meta: "" }
      };
    }

    /*  What came out of the database, made safe to put in boxes.

        THE SESSIONS ARE FORCED TO THE RIGHT KEYS HERE, not left as they were
        found. A class switched from separate to single on the Adult classes
        screen still has its men's and women's rows stored; drawing those two
        boxes and then refusing the save would be telling somebody off for
        something the screen itself put in front of them.

        A LABEL IS CARRIED OVER ONLY WHERE ITS KEY SURVIVES, and otherwise the
        box is left empty. Reusing the old wording would save a typing job and
        cost far more than it saved: a class switched to one session for
        everybody would be published calling it "Men's class", which reads
        perfectly well and turns women away from a class that is for them. An
        empty box cannot do that — check() refuses to let the page be saved
        until somebody writes the label, and the paragraph above the boxes
        says why they are being asked. */
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

      var had = Array.isArray(out.cohorts) ? out.cohorts : [];
      out.cohorts = wantedKeys(mode).map(function (k) {
        var kept = "";
        had.forEach(function (c) {
          if (c && trim(c.key) === k && !kept) kept = String(c.label == null ? "" : c.label);
        });
        return { key: k, label: kept };
      });

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

    // --- reading the boxes back ----------------------------------------------
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
        with them. */
    function harvest() {
      if (!doc) return null;
      [["cp-name", "name"], ["cp-tagline", "tagline"], ["cp-intro", "intro"],
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

    /*  What would be sent. Trimmed, because check_course_page() trims before
        it measures and a value that passes here and fails there is the whole
        problem this file is written to avoid.

        The cohort KEYS are written from the class's cohort_mode rather than
        read out of any box, because there is no box: the only thing on screen
        is the label. */
    function body() {
      var o = harvest();
      if (!o) return blank("", current && current.cohort_mode);
      var keys = wantedKeys(current && current.cohort_mode);
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

    // --- drawing -------------------------------------------------------------
    function countdown(boxId, value, limit) {
      var box = el(boxId);
      if (!box) return;
      var left = limit - trim(value).length;
      box.textContent = left >= 0
        ? left + " characters left"
        : (-left) + " characters too many — the limit is " + limit;
      box.classList.toggle("is-over", left < 0);
    }

    function sessionsIn(mode) {
      return wantedKeys(mode).length === 1
        ? "one session for everyone"
        : "separate men’s and women’s sessions";
    }

    /*  THE LIST. Whether sign-ups are open comes from courses_admin_list();
        whether the page copy is FINISHED comes from whole(), and it is the
        one that decides whether the class is on the website at all. Both are
        said in words rather than left to a colour, because a colour is not a
        sentence anybody can act on. */
    function drawList() {
      var host = el("cp-list");
      if (!host) return;

      if (!rows.length) {
        host.innerHTML = '<p class="cp-empty">No classes yet. A class is started ' +
          "on the Adult classes screen — give it a name, a website key and a " +
          "number of places there, then come back here and write its page.</p>";
        return;
      }

      host.innerHTML = rows.map(function (c) {
        var done = whole(c.page);
        var on   = current && current.key === c.key;
        return '<button type="button" class="cp-row ' + (done ? "is-live" : "is-gap") +
            (on ? " is-on" : "") + '" data-key="' + esc(c.key) + '">' +
          '<span class="cp-row-top">' +
            '<span class="cp-row-nm">' + esc(c.name || c.key) + "</span>" +
            '<span class="cp-key">' + esc(c.key) + "</span>" +
            '<span class="cp-pill ' + (c.is_open ? "cp-pill-open" : "cp-pill-shut") + '">' +
              (c.is_open ? "Sign-ups open" : "Sign-ups shut") + "</span>" +
          "</span>" +
          '<span class="cp-state ' + (done ? "cp-state-live" : "cp-state-gap") + '">' +
            (done ? "On the website" : "Not on the website yet") + "</span>" +
          (done ? "" :
            '<span class="cp-why">A class is only published once its page here is ' +
            "finished. Until then the website leaves it out altogether — there is " +
            "no card for it on the Education page and no page to reach.</span>") +
          '<span class="cp-row-meta">' + esc(sessionsIn(c.cohort_mode)) +
            " · " + esc(String(c.capacity)) + " places · " +
            esc(String(c.taken || 0)) + " taken · " +
            esc(String(c.waiting || 0)) + " waiting</span>" +
        "</button>";
      }).join("");
    }

    /*  One repeating editor, drawn four times over. `fields` is what each row
        holds; `acts` is what can be done to it. The sessions pass neither an
        add button nor a remove one, which is the whole point of them. */
    function drawRows(hostId, list, opts) {
      var host = el(hostId);
      if (!host) return;

      if (!list.length) {
        host.innerHTML = '<p class="cp-empty">' + opts.empty + "</p>";
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

    /*  THE SESSIONS. A fixed number of label boxes, drawn from the class's
        cohort_mode, with no add and no remove — see the note at the top of
        this file and the paragraph the screen prints above them. */
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
            '<p class="cp-hint">Filed under <span class="cp-key">' + esc(item.key) +
              "</span>. Every sign-up carries that word, so it cannot change — the " +
              "wording above it can say anything you like.</p>"
          ];
        }
      });

      var why = el("cp-cohort-why");
      if (!why) return;
      var single = wantedKeys(current && current.cohort_mode).length === 1;
      why.innerHTML = "This class is set to <strong>" +
        (single ? "one session for everyone" : "separate men’s and women’s sessions") +
        "</strong> on the Adult classes screen, so it has " +
        (single ? "one box" : "two boxes") + " here and there is <strong>no way to add " +
        "another</strong>. Every sign-up is filed under " +
        (single ? "the word “all”" : "the words “mens” and “womens”") +
        ", and the database will only accept those two and “all”. A session invented " +
        "here would save perfectly well and then <strong>refuse every single sign-up " +
        "against it</strong> with an error nobody could read. Changing whether the " +
        "class runs one session or two is done on the Adult classes screen.";

      /*  A box that has gone empty on a class that WAS written means somebody
          has switched it between one session and two since. The old wording is
          not carried across on purpose — "Men's class" over a session for
          everybody reads perfectly well and turns half the masjid away — so
          this says what happened rather than leaving it looking like the
          screen lost their work. */
      var lost = list.some(function (c) { return !trim(c.label); }) &&
                 trim(doc && doc.tagline) !== "";
      if (lost) {
        why.innerHTML += " <strong>One of these boxes is empty because this class " +
          "has been switched between one session and two since its page was " +
          "written.</strong> The old wording is not moved across — it would end up " +
          "on a session it was never written for — so please write it again.";
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

    function drawMeta() {
      var box = el("cp-meta");
      if (!box) return;
      if (!current) { box.textContent = ""; return; }
      var done = whole(body());
      box.textContent = done
        ? "As it stands, this page is complete and the class is on the website."
        : "As it stands, this page is NOT complete, so the website leaves this " +
          "class out altogether.";
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
      var isOpen = !!(current && current.is_open);

      bits.push('<div class="cp-pv-mast">' +
        '<span class="cp-pv-eyebrow">Education</span>' +
        "<h4>" + esc(b.name || (current && current.name) || "(no name)") + "</h4>" +
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
        '<span class="cp-pv-th">' + esc(b.name || (current && current.name) || "(no name)") +
          "</span>" +
        '<span class="cp-pv-tp">' + esc(b.tile.p || b.tagline || "") + "</span>" +
        '<span class="cp-pv-tm">' + esc(b.tile.meta || "") + "</span>" +
        "</div>");

      host.innerHTML = bits.join("");
    }

    /*  Re-run after every keystroke. The Save button is the only way to reach
        save_course_page(), so this is where "save is impossible until the page
        is valid" actually lives — the `disabled` in the markup only covers the
        first paint. */
    function revalidate() {
      var save = el("cp-save");

      if (!doc || !current) {
        //  Nothing is open, so there is nothing that could be saved. Said in
        //  the button rather than left to the markup, because the markup is
        //  one tidy-up away from losing the attribute.
        if (save) save.disabled = true;
        note("cp-complaints", "");
        return ["No class is open."];
      }

      var b = body();
      countdown("cp-tagline-count",   b.tagline,   TAGLINE_MAX);
      countdown("cp-intro-count",     b.intro,     INTRO_MAX);
      countdown("cp-exp-label-count", b.exp_label, EXPQ_MAX);
      countdown("cp-open-count",      b.open,      BLURB_MAX);
      countdown("cp-closed-count",    b.closed,    BLURB_MAX);
      drawPreview(b);
      drawMeta();

      var complaints = check(b, current.cohort_mode);
      var box = el("cp-complaints");
      if (box) {
        if (complaints.length) {
          box.innerHTML = "<ul>" + complaints.map(function (c) {
            return "<li>" + esc(c) + "</li>";
          }).join("") + "</ul>";
          box.hidden = false;
        } else {
          box.hidden = true;
          box.innerHTML = "";
        }
      }
      if (save) save.disabled = complaints.length > 0;
      return complaints;
    }

    function draw() {
      drawList();

      var editor = el("cp-editor");
      if (!current || !doc) {
        if (editor) editor.hidden = true;
        revalidate();
        return;
      }
      if (editor) editor.hidden = false;

      var head = el("cp-editing");
      if (head) head.textContent = current.name || current.key;
      var key = el("cp-editing-key");
      if (key) key.textContent = current.key;

      [["cp-name", doc.name], ["cp-tagline", doc.tagline], ["cp-intro", doc.intro],
       ["cp-exp-label", doc.exp_label], ["cp-open", doc.open], ["cp-closed", doc.closed],
       ["cp-tile-tag", doc.tile.tag], ["cp-tile-p", doc.tile.p],
       ["cp-tile-meta", doc.tile.meta]
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

    // --- opening and closing a class ----------------------------------------
    function openClass(key) {
      var found = null;
      rows.forEach(function (c) { if (c.key === key) found = c; });
      if (!found) return;
      current = found;
      doc = normalise(found.page, found.name, found.cohort_mode);
      saved = JSON.stringify(doc);
      note("cp-ok", ""); note("cp-error", "");
      draw();
      var editor = el("cp-editor");
      if (editor) editor.scrollIntoView({ behavior: "smooth", block: "start" });
    }

    function closeClass() {
      current = null;
      doc = null;
      saved = null;
      draw();
      var list = el("cp-list");
      if (list) list.scrollIntoView({ behavior: "smooth", block: "start" });
    }

    // --- loading and saving --------------------------------------------------
    /*  TWO CALLS, JOINED IN THE BROWSER, and neither is optional.

        courses_admin_list() has the counts — how many places are taken, how
        many are waiting — and does NOT return the page copy. courses_public()
        has the page copy and is the same content the website itself reads,
        which is exactly what this screen is for; `courses` denies a direct
        SELECT, so there is no third option. They are joined on `key`. */
    function load() {
      note("cp-error", "");
      return Promise.all([
        sb.rpc("courses_admin_list"),
        sb.rpc("courses_public")
      ]).then(function (out) {
        if (out[0].error) throw new Error(out[0].error.message);
        if (out[1].error) throw new Error(out[1].error.message);

        var pages = {};
        (Array.isArray(out[1].data) ? out[1].data : []).forEach(function (c) {
          if (c && c.key) pages[c.key] = c.page || {};
        });

        rows = (Array.isArray(out[0].data) ? out[0].data : []).map(function (c) {
          c = c || {};
          return {
            key: c.key,
            name: c.name,
            cohort_mode: c.cohort_mode,
            capacity: c.capacity,
            is_open: c.is_open,
            sort_order: c.sort_order,
            taken: c.taken,
            waiting: c.waiting,
            page: pages[c.key] || {}
          };
        });

        //  Whichever class was open stays open, with whatever came back.
        if (current) {
          var still = null;
          rows.forEach(function (c) { if (c.key === current.key) still = c; });
          if (still) {
            current = still;
            doc = normalise(still.page, still.name, still.cohort_mode);
            saved = JSON.stringify(doc);
          } else {
            current = null; doc = null; saved = null;
          }
        }
        draw();
      }).catch(function (e) {
        note("cp-error", "Couldn't read the classes: " + (e.message || e) +
                         " — nothing on the website has changed.");
        draw();
      });
    }

    function save() {
      //  Belt and braces; the button is disabled too. Both, because the
      //  disabled attribute is one line away from being deleted by somebody
      //  tidying the markup, and this is the call that changes a public page.
      if (!current || revalidate().length) return;

      var out = body();
      var btn = el("cp-save");
      var wasWhole = whole(current.page);
      busy(btn, true, SAVE_LABEL);
      note("cp-error", ""); note("cp-ok", "");

      //  save_course_page(p_key text, p_page jsonb) — the argument names are
      //  the keys of this object. Anything else is "function does not exist".
      sb.rpc("save_course_page", { p_key: current.key, p_page: out })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          note("cp-ok", "Saved. This is the " + (current.name || current.key) +
                        " page on the website now — there is nothing else to press." +
                        (wasWhole ? "" :
                          " The class is published for the first time, so it now has " +
                          "a card on the Education page as well."));
          return load();
        })
        .catch(function (e) {
          note("cp-error", e.message || String(e));
        })
        .finally(function () {
          busy(btn, false, SAVE_LABEL);
          revalidate();
        });
    }

    // --- the repeating editors -----------------------------------------------
    /*  One handler for all four lists. `list` is the array behind the host,
        and a list with no add button (the sessions) never reaches here
        because it draws no buttons at all. */
    function onRowClick(hostId, listName, minimum) {
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

    // --- wiring --------------------------------------------------------------
    /*  Attaches every listener and draws the screen once. It must work with no
        session and no network — see the note beside window.__CLASSPAGE_FORM. */
    function wire() {
      if (wired) return true;
      wired = true;

      ["cp-name", "cp-tagline", "cp-intro", "cp-exp-label", "cp-open", "cp-closed",
       "cp-tile-tag", "cp-tile-p", "cp-tile-meta"].forEach(function (id) {
        var box = el(id);
        if (box) box.addEventListener("input", revalidate);
      });

      /*  One listener on each container rather than one per box: the rows are
          redrawn whenever anything is added, removed or moved, so per-row
          listeners would be re-attached each time and the old ones left
          behind. */
      var hosts = [
        ["cp-facts",   "facts",   0],
        ["cp-rules",   "rules",   RULES_MIN],
        ["cp-cohorts", "cohorts", 99],
        ["cp-exps",    "exp",     EXP_MIN]
      ];
      hosts.forEach(function (h) {
        var host = el(h[0]);
        if (!host) return;
        host.addEventListener("input", revalidate);
        host.addEventListener("click", onRowClick(h[0], h[1], h[2]));
      });

      var list = el("cp-list");
      if (list) list.addEventListener("click", function (ev) {
        var btn = ev.target.closest ? ev.target.closest(".cp-row") : null;
        if (!btn) return;
        openClass(btn.getAttribute("data-key"));
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

      var saveBtn = el("cp-save");
      if (saveBtn) saveBtn.addEventListener("click", save);

      var closeBtn = el("cp-close");
      if (closeBtn) closeBtn.addEventListener("click", closeClass);

      var revert = el("cp-revert");
      if (revert) revert.addEventListener("click", function () {
        if (!saved) {
          note("cp-error", "There is nothing to go back to — this class's page has " +
                           "not been read from the website yet.");
          return;
        }
        if (!window.confirm("Throw away the changes you have made on this screen?\n\n" +
              "The website is unaffected either way — nothing has been saved.")) return;
        doc = JSON.parse(saved);
        draw();
        note("cp-error", "");
        note("cp-ok", "Back to what is on the website.");
      });

      draw();
      return true;
    }

    function mount(identity) {
      wire();
      return load();
    }

    return { mount: mount, _check: check, _wire: wire };
  })();

  /*  EXPOSED FOR THE TESTS.

      check() is pure — no DOM, no network, no state — and it is the half of
      this screen worth testing, because it has to agree with
      check_course_page() in 047 exactly, cohort keys and all. Where the two
      disagree, a volunteer is told a class page is fine and then gets a raw
      Postgres error; that has already happened once on this project, which is
      why 041 exists and why 045 and 047 were written the same way.

      wire() is not pure, and it is here for a reason learned the hard way on
      times/. The rule "nothing is saveable until the page is valid" lived
      inside mount(), which runs only after a real sign-in — so no test could
      ever reach it, and the Save button is disabled in the markup as well, so
      it read as disabled whether the rule was there or had been deleted. The
      check passed with the code removed. Calling wire() on a page nobody is
      signed in to wires a Save button whose click calls save_course_page(),
      which Postgres refuses to anybody who is not a verified administrator
      with two-step. The check is in the database, not in this file. */
  window.__CLASSPAGE_FORM = { check: classpage._check, wire: classpage._wire };

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'classpages',
        title:   'What a class says',
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

    // A panel that fails to load must never take the sign-in shell with it.
    try { classpage.mount(identity); } catch (e) {
      if (window.console) console.warn("class page editor unavailable:", e);
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
