/* ===========================================================================
   Taiyabah Masjid — the in-mosque displays, edited by the masjid
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   The foyer TVs read their words from foyer-content.json in the
   taiyabah-mosque-interactive-screens repository — a separate repo from this
   website, built and deployed on its own. Before this screen existed, the
   only way to change that file was hand-editing JSON on GitHub: fine for
   whoever built the screens, not something to hand to the office.

   THIS SCREEN DOES NOT TALK TO GITHUB. A GitHub token that can write to that
   repository is not something a browser should ever hold, so it lives only
   inside the update-foyer-content Edge Function, which this screen calls the
   same way access/app.js calls invite-user: with the caller's own Supabase
   session token, never the GitHub token itself. The function checks the
   caller is an administrator before it ever touches the token.

   READING IS DIFFERENT FROM WRITING. foyer-content.json is already public —
   the TVs fetch it with no auth at all — so load() below reads it straight
   from its live URL rather than through Supabase or GitHub's API. That is
   also why this screen only ever shows what is CURRENTLY on the TVs: there
   is no draft copy sitting in a database to go stale.

   ONLY WHAT THE TVs ACTUALLY SHOW IS EDITED HERE. README.md and SETUP.md in
   that repo say plainly which fields render and which are kept but unused
   (the long heading and tagline, each timeline entry's own date and title
   text, the bank details) — "Nobody copies an account number off a TV." This
   form edits only the fields that render, and the Edge Function preserves
   everything else in the file untouched when it writes the update back.

   THE PROGRESS BAR'S DOT is not a date field. It sits at whichever stage in
   the timeline is marked "active", as a share of the way along it — see
   src/foyer/screen.js's drawProgress() in the screens repo. Rather than ask
   somebody to edit a status string correctly, this screen shows the stages
   as a single choice and recomputes every status from it: done before the
   choice, active at it, upcoming after.

   THE COMPLAINTS ARE THE SAME ONES THE SCREENS REPO ENFORCES. check() below
   mirrors check_donate_link() in that repo's build.py (the Stripe-link
   shape) and the fields SETUP.md lists as rendered. A validator here that
   disagrees with the one that actually builds the TVs' pages would let
   something through that then fails silently on the wall, not in front of
   whoever saved it.
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
     IN-MOSQUE DISPLAYS MODULE. Everything on this screen, kept in one place
     so that if it throws, the sign-in shell around it survives — see
     renderApp. */
  var screens = (function () {
    "use strict";

    var FOYER_URL = "https://taiyabahscreens.ysbdesigns.uk/foyer-content.json";
    var STRIPE_RE = /^https:\/\/(buy|donate)\.stripe\.com\/[A-Za-z0-9]+$/;   // build.py's DONATE_LINK, copied

    var OCC_KEYS = ["ramadan", "eidFitr", "eidAdha"];
    var SAVE_LABEL = "Submit changes";

    var doc     = null;   // what is being edited — see blank() for the shape
    var saved   = null;   // what came back from the live file, for Undo
    var meta    = null;   // when this screen last loaded the file
    var rawLive = null;   // the full foyer-content.json as last fetched, for the live preview
    var wired   = false;

    /* -------------------------------------------------------------- the
       LIVE PREVIEW. Four iframes, each the screens repo's own foyer.html /
       foyervertical.html / timetable.html / timetablevertical.html, loaded
       from the real site — not a redrawn copy of what they look like, which
       would drift the moment either repo changed. Each one recognises it is
       embedded (window !== window.top) and, instead of fetching the live
       file, listens for a draft posted from this origin — see
       src/shared/frame.js's wirePreview() in the screens repo. */
    var SCREENS_ORIGIN = "https://taiyabahscreens.ysbdesigns.uk";
    var PREVIEW_PAGES = {
      foyerLand: "foyer.html", foyerPort: "foyervertical.html",
      hallLand: "timetable.html", hallPort: "timetablevertical.html"
    };
    /* kind decides which fields the detail view shows. A hall screen runs
       the timetable program — prayer times, Jumuʿah, sunrise/sunset — none
       of which comes from this editor, and the Ramadan/Eid greeting is
       foyer-only, so a hall screen has nothing here to edit at all; its
       detail view is the live preview and a plain note saying so. name/sub
       are the tile's and the detail view's own words, written once here
       instead of twice in the HTML. */
    var SCREEN_DEF = {
      foyerLand: { kind: "foyer", name: "Foyer — landscape", sub: "2 TVs in the foyer." },
      foyerPort: { kind: "foyer", name: "Foyer — portrait", sub: "Same TV pair, portrait mount." },
      hallLand:  { kind: "hall",  name: "Prayer hall — landscape", sub: "Also shown downstairs — same page, same TVs." },
      hallPort:  { kind: "hall",  name: "Prayer hall — portrait", sub: "Also shown downstairs — same page, same TVs." }
    };
    var previewReady = {};
    var pushTimer = null;
    var currentScreen = null;   // null = picker grid; a SCREEN_DEF key = that screen's editor

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

    function blank() {
      return {
        eyebrow: "", phaseTag: "", phaseTitle: "", needs: [], donateUrl: "",
        progress: { done: "", now: "", next: "" },
        timeline: [], activeIndex: 0,
        appLabel: "",
        occasions: {
          ramadan:  { enabled: true, title: "", arabic: "", message: "" },
          eidFitr:  { enabled: true, title: "", arabic: "", message: "", durationDays: 3 },
          eidAdha:  { enabled: true, title: "", arabic: "", message: "", durationDays: 4 }
        }
      };
    }

    /* ---------------------------------------------------------------- from
       the LIVE FILE to the shape this form edits. Everything the file holds
       that this form does not expose — heading, tagline, phaseDescription,
       the timeline's own date/title text, give.bankHeading/bank/note,
       give.scanLabel, give.giftAidNote, _instructions — is read here only to
       be ignored; the Edge Function reads the file itself and keeps those
       untouched, so dropping them here loses nothing. */
    function extract(raw) {
      var nb  = (raw && raw.newBuild) || {};
      var give = nb.give || {};
      var prog = nb.progress || {};
      var tl   = Array.isArray(nb.timeline) ? nb.timeline : [];
      var occRaw = (raw && raw.occasions) || {};

      var active = 0;
      tl.forEach(function (t, i) { if (t && t.status === "active") active = i; });

      var occasions = {};
      OCC_KEYS.forEach(function (k) {
        var o = occRaw[k] || {};
        occasions[k] = {
          enabled: o.enabled !== false,
          title: trim(o.title), arabic: trim(o.arabic), message: trim(o.message),
          durationDays: typeof o.durationDays === "number" ? o.durationDays : (k === "eidFitr" ? 3 : 4)
        };
      });

      return {
        eyebrow: trim(nb.eyebrow), phaseTag: trim(nb.phaseTag), phaseTitle: trim(nb.phaseTitle),
        needs: Array.isArray(nb.needs) ? nb.needs.map(trim).filter(Boolean) : [],
        donateUrl: trim(give.otherAmountUrl),
        progress: { done: trim(prog.done), now: trim(prog.now), next: trim(prog.next) },
        timeline: tl.map(function (t) { return { date: (t && t.date) || "", title: (t && t.title) || "" }; }),
        activeIndex: active,
        appLabel: trim((raw && raw.app && raw.app.label) || ""),
        occasions: occasions
      };
    }

    /* =====================================================================
       check() — the screens repo's own rules, in the browser. Pure: no DOM,
       no network, no session. =========================================== */
    function check(o) {
      if (!o || typeof o !== "object") {
        return ["The foyer content did not arrive as expected. Reload the page and try again."];
      }
      var out = [];

      if (!trim(o.eyebrow)) out.push("The eyebrow line cannot be empty.");
      if (!trim(o.phaseTag)) out.push("The phase tag cannot be empty.");
      if (!trim(o.phaseTitle)) out.push("The phase title cannot be empty.");

      var needs = Array.isArray(o.needs) ? o.needs.map(trim).filter(Boolean) : [];
      if (needs.length === 0) out.push("List at least one thing the appeal still needs.");
      if (needs.length > 12) out.push("That's " + needs.length + " items under \"what it needs\" — keep it to 12 or fewer so it still fits on the TV.");
      needs.forEach(function (n) {
        if (n.length > 40) out.push('"' + n + '" is too long for one item under "what it needs" (40 characters).');
      });

      var url = trim(o.donateUrl);
      if (!url) out.push("The donate link cannot be empty — it draws the QR code on the TV.");
      else if (!STRIPE_RE.test(url)) out.push("The donate link must be a Stripe checkout link (https://buy.stripe.com/... or https://donate.stripe.com/...), not " + JSON.stringify(url) + ".");

      var p = o.progress || {};
      if (!trim(p.done)) out.push("The progress bar's left label cannot be empty.");
      if (!trim(p.now)) out.push("The progress bar's middle label cannot be empty.");
      if (!trim(p.next)) out.push("The progress bar's right label cannot be empty.");

      var tl = Array.isArray(o.timeline) ? o.timeline : [];
      if (tl.length === 0) {
        out.push("There is no timeline to choose a current stage from. Reload the page and try again.");
      } else if (!(typeof o.activeIndex === "number" && o.activeIndex >= 0 && o.activeIndex < tl.length)) {
        out.push("Choose which stage is current.");
      }

      if (!trim(o.appLabel)) out.push('The "download our app" label cannot be empty.');

      var occ = o.occasions || {};
      OCC_KEYS.forEach(function (k) {
        var occItem = occ[k] || {};
        if (!occItem.enabled) return;   // off entirely — nothing else about it matters
        var label = k === "ramadan" ? "Ramadan" : (k === "eidFitr" ? "Eid al-Fitr" : "Eid al-Adha");
        if (!trim(occItem.title)) out.push(label + " is switched on but has no title.");
        if (!trim(occItem.arabic)) out.push(label + " is switched on but has no Arabic text.");
        if (!trim(occItem.message)) out.push(label + " is switched on but has no message.");
        if (k !== "ramadan") {
          var d = occItem.durationDays;
          if (!(typeof d === "number" && isFinite(d) && d >= 1 && d <= 30 && Math.floor(d) === d)) {
            out.push(label + "'s \"shown for how many days\" must be a whole number from 1 to 30.");
          }
        }
      });

      return out;
    }

    // --- reading the boxes back ----------------------------------------------
    function harvest() {
      if (!doc) doc = blank();
      doc.eyebrow = el("sc-eyebrow").value;
      doc.phaseTag = el("sc-phasetag").value;
      doc.phaseTitle = el("sc-phasetitle").value;
      doc.needs = el("sc-needs").value.split("\n").map(trim).filter(Boolean);
      doc.donateUrl = el("sc-donate").value;
      doc.progress = {
        done: el("sc-prog-done").value, now: el("sc-prog-now").value, next: el("sc-prog-next").value
      };
      var chosen = document.querySelector('input[name="sc-active"]:checked');
      doc.activeIndex = chosen ? Number(chosen.value) : doc.activeIndex;
      doc.appLabel = el("sc-applabel").value;

      OCC_KEYS.forEach(function (k) {
        var o = doc.occasions[k];
        o.enabled = el("occ-" + k + "-enabled").checked;
        o.title = el("occ-" + k + "-title").value;
        o.arabic = el("occ-" + k + "-arabic").value;
        o.message = el("occ-" + k + "-message").value;
        if (k !== "ramadan") {
          var raw = el("occ-" + k + "-days").value;
          o.durationDays = raw === "" ? NaN : Number(raw);
        }
      });
      return doc;
    }

    function body() {
      var o = harvest();
      var out = {
        eyebrow: trim(o.eyebrow), phaseTag: trim(o.phaseTag), phaseTitle: trim(o.phaseTitle),
        needs: o.needs.map(trim).filter(Boolean),
        donateUrl: trim(o.donateUrl),
        progress: { done: trim(o.progress.done), now: trim(o.progress.now), next: trim(o.progress.next) },
        timeline: o.timeline, activeIndex: o.activeIndex,
        appLabel: trim(o.appLabel),
        occasions: {}
      };
      OCC_KEYS.forEach(function (k) {
        var oo = o.occasions[k];
        out.occasions[k] = {
          enabled: !!oo.enabled, title: trim(oo.title), arabic: trim(oo.arabic), message: trim(oo.message),
          durationDays: oo.durationDays
        };
      });
      return out;
    }

    // --- drawing the editor --------------------------------------------------
    function drawNeedsPreview(needs) {
      var host = el("sc-needs-preview");
      if (!host) return;
      host.innerHTML = needs.map(function (n) {
        return '<span class="sc-chip">' + esc(n) + "</span>";
      }).join("");
    }

    function drawTimelineRadios() {
      var host = el("sc-timeline");
      if (!host) return;
      host.innerHTML = doc.timeline.map(function (t, i) {
        var checked = i === doc.activeIndex ? " checked" : "";
        return '<label class="sc-radio">' +
          '<input type="radio" name="sc-active" value="' + i + '"' + checked + '>' +
          '<span><span class="t">' + esc(t.title || ("Stage " + (i + 1))) + '</span>' +
          (t.date ? '<span class="d">' + esc(t.date) + '</span>' : '') + '</span>' +
          '</label>';
      }).join("");
      Array.prototype.forEach.call(host.querySelectorAll('input[name="sc-active"]'), function (r) {
        r.addEventListener("change", revalidate);
      });
    }

    /* ---------------------------------------------------------- the preview
       Drawn to look like the progress bar on the foyer TV, same formula as
       drawProgress() in the screens repo: the dot sits at activeIndex as a
       share of the way from the first stage to the last. */
    function drawBarPreview(b) {
      var n = b.timeline.length;
      var at = n > 1 ? b.activeIndex / (n - 1) : 1;
      var pct = (at * 100).toFixed(2) + "%";
      var fill = el("sc-bar-fill"), dot = el("sc-bar-dot");
      if (fill) fill.style.width = pct;
      if (dot) dot.style.left = pct;
      el("sc-bar-left").textContent = b.progress.done || "—";
      el("sc-bar-mid").textContent = b.progress.now || "—";
      el("sc-bar-right").textContent = b.progress.next || "—";
    }

    function drawMeta() {
      var box = el("sc-meta");
      if (!box) return;
      if (!meta || !meta.read_at) {
        box.textContent = "Last read: not known — reload the page.";
        return;
      }
      box.textContent = "Read from the live screens just now" +
        (meta.commit_url ? " — last saved change: " + meta.commit_url : ".") ;
    }

    function revalidate() {
      var b = body();
      drawNeedsPreview(b.needs);
      drawBarPreview(b);

      var complaints = check(b);
      var box = el("sc-complaints");
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
      var save = el("sc-save");
      if (save) save.disabled = complaints.length > 0;
      pushPreview();
      return complaints;
    }

    function draw() {
      el("sc-eyebrow").value = doc.eyebrow;
      el("sc-phasetag").value = doc.phaseTag;
      el("sc-phasetitle").value = doc.phaseTitle;
      el("sc-needs").value = doc.needs.join("\n");
      el("sc-donate").value = doc.donateUrl;
      el("sc-prog-done").value = doc.progress.done;
      el("sc-prog-now").value = doc.progress.now;
      el("sc-prog-next").value = doc.progress.next;
      el("sc-applabel").value = doc.appLabel;

      OCC_KEYS.forEach(function (k) {
        var o = doc.occasions[k];
        el("occ-" + k + "-enabled").checked = !!o.enabled;
        el("occ-" + k + "-title").value = o.title;
        el("occ-" + k + "-arabic").value = o.arabic;
        el("occ-" + k + "-message").value = o.message;
        document.getElementById("occ-" + k).setAttribute("data-enabled", o.enabled ? "true" : "false");
        if (k !== "ramadan") el("occ-" + k + "-days").value = o.durationDays;
      });

      drawTimelineRadios();
      drawMeta();
      revalidate();
    }

    // --- loading and saving --------------------------------------------------
    function load() {
      note("sc-error", "");
      return fetch(FOYER_URL, { cache: "no-store" })
        .then(function (r) {
          if (!r.ok) throw new Error("the screens answered " + r.status);
          return r.json();
        })
        .then(function (raw) {
          rawLive = raw;
          doc = extract(raw);
          saved = JSON.stringify(doc);
          meta = { read_at: new Date().toISOString() };
          draw();
          pushPreview();
        })
        .catch(function (e) {
          note("sc-error", "Couldn't read what's currently on the foyer TVs: " +
            (e.message || e) + " — nothing has changed on them.");
          if (!doc) { doc = blank(); draw(); }
        });
    }

    /* The full foyer-content.json shape, as this screen's edits would leave
       it — everything this form does not show (the long heading and
       tagline, the bank details, _instructions) stays exactly as rawLive
       had it, same as the Edge Function's own merge at save time. Built
       fresh on every call rather than cached: the preview has to answer
       "what would saving right now produce", and the only safe way to know
       that is to redo the merge from the last fetched copy each time. */
    function buildPreviewContent() {
      if (!rawLive) return null;
      var b = body();
      var merged = JSON.parse(JSON.stringify(rawLive));
      var nb = merged.newBuild = merged.newBuild || {};
      nb.eyebrow = b.eyebrow; nb.phaseTag = b.phaseTag; nb.phaseTitle = b.phaseTitle; nb.needs = b.needs;
      nb.give = nb.give || {}; nb.give.otherAmountUrl = b.donateUrl;
      nb.progress = b.progress;
      var tl = Array.isArray(nb.timeline) ? nb.timeline : [];
      if (b.activeIndex >= 0 && b.activeIndex < tl.length) {
        tl.forEach(function (t, i) {
          t.status = i < b.activeIndex ? "done" : i === b.activeIndex ? "active" : "upcoming";
        });
      }
      nb.timeline = tl;
      merged.app = merged.app || {};
      merged.app.label = b.appLabel;
      merged.occasions = merged.occasions || {};
      OCC_KEYS.forEach(function (k) {
        var o = merged.occasions[k] = merged.occasions[k] || {};
        var bo = b.occasions[k];
        o.enabled = bo.enabled; o.title = bo.title; o.arabic = bo.arabic; o.message = bo.message;
        if (k !== "ramadan") o.durationDays = bo.durationDays;
      });
      return merged;
    }

    function frameFor(key) { return el("pv-" + key); }

    function wirePreviewFrames() {
      Object.keys(PREVIEW_PAGES).forEach(function (key) {
        var frame = frameFor(key);
        if (frame) frame.src = SCREENS_ORIGIN + "/" + PREVIEW_PAGES[key];
      });
      addEventListener("message", function (e) {
        if (e.origin !== SCREENS_ORIGIN) return;
        var msg = e.data;
        if (!msg || msg.type !== "taiyabah-preview-ready") return;
        var key = Object.keys(PREVIEW_PAGES).filter(function (k) {
          var frame = frameFor(k);
          return frame && frame.contentWindow === e.source;
        })[0];
        if (!key) return;
        previewReady[key] = true;
        drawLivePill();
        pushPreview();
      });
    }

    function drawLivePill() {
      var ready = Object.keys(PREVIEW_PAGES).filter(function (k) { return previewReady[k]; }).length;
      var all = Object.keys(PREVIEW_PAGES).length;
      ["sc-live-pill-grid", "sc-live-pill-detail"].forEach(function (id) {
        var pill = el(id);
        if (!pill) return;
        pill.classList.toggle("is-waiting", ready < all);
        pill.textContent = ready < all ? "Connecting…" : "Live as you type";
      });
    }

    /* -------------------------------------------------------------- the
       TWO VIEWS. One set of four iframes exists for the whole life of the
       page — showDetail() moves the one the admin picked into the big
       frame; showGrid() moves it back to its tile. Moving an iframe that is
       already in the document (appendChild, not cloneNode) does not reload
       it in any browser this needs to support, so the frame the admin was
       just looking at in the grid is exactly the frame they see enlarged —
       same postMessage channel, same "ready" state, nothing refetched. */
    function showGrid() {
      currentScreen = null;
      Object.keys(PREVIEW_PAGES).forEach(function (key) {
        var slot = el("pv-slot-" + key), frame = frameFor(key);
        if (slot && frame && frame.parentElement !== slot) slot.appendChild(frame);
      });
      el("sc-grid").hidden = false;
      el("sc-detail").hidden = true;
    }

    function showDetail(key) {
      currentScreen = key;
      var def = SCREEN_DEF[key];
      var frame = frameFor(key);
      var dest = el("sc-detail-frame-slot");
      if (frame && dest) {
        dest.className = "sc-tvframe " + (key.indexOf("Port") !== -1 ? "port" : "land");
        dest.appendChild(frame);
      }
      el("sc-detail-title").textContent = def.name;
      el("sc-detail-sub").textContent = def.kind === "foyer"
        ? "The appeal, the donate link, the progress bar, and the Ramadan/Eid greeting."
        : "The prayer-times screen — nothing here is editable yet.";
      el("sc-hall-note").hidden = def.kind !== "hall";
      el("sc-foyer-fields").hidden = def.kind !== "foyer";
      el("sc-foyer-fields-2").hidden = def.kind !== "foyer";
      el("sc-occ-fields").hidden = def.kind !== "foyer";
      el("sc-actions").hidden = def.kind !== "foyer";
      el("sc-grid").hidden = true;
      el("sc-detail").hidden = false;
    }

    /* Debounced: a keystroke posts a draft, not every keystroke its own
       postMessage — four iframes redrawing is real work for a TV's own
       layout code, and nobody is reading the preview mid-keystroke anyway. */
    function pushPreview() {
      clearTimeout(pushTimer);
      pushTimer = setTimeout(function () {
        var content = buildPreviewContent();
        if (!content) return;
        Object.keys(PREVIEW_PAGES).forEach(function (key) {
          if (!previewReady[key]) return;
          var frame = frameFor(key);
          if (frame && frame.contentWindow) {
            frame.contentWindow.postMessage({ type: "taiyabah-preview-content", content: content }, SCREENS_ORIGIN);
          }
        });
      }, 150);
    }

    function save() {
      if (revalidate().length) return;

      var out = body();
      var btn = el("sc-save");
      busy(btn, true, SAVE_LABEL);
      note("sc-error", ""); note("sc-ok", "");

      sb.auth.getSession().then(function (s) {
        var token = s.data && s.data.session && s.data.session.access_token;
        if (!token) throw new Error("Your session has expired. Sign in again.");
        return fetch(apiUrl + "/functions/v1/update-foyer-content", {
          method: "POST",
          headers: { "content-type": "application/json",
                     apikey: cfg.SUPABASE_ANON_KEY,
                     Authorization: "Bearer " + token },
          body: JSON.stringify(out)
        });
      }).then(function (r) {
        return r.text().then(function (t) {
          var body; try { body = JSON.parse(t); } catch (e) { body = { error: t }; }
          return { ok: r.ok, body: body };
        });
      }).then(function (res) {
        if (!res.ok) throw new Error(res.body.error || "That did not work.");
        note("sc-ok", "Saved. The foyer TVs pick this up within about twenty minutes — " +
                      "there is nothing else to press.");
        meta = { read_at: new Date().toISOString(), commit_url: res.body.commit_url || "" };
        saved = JSON.stringify(doc);
        drawMeta();
      }).catch(function (e) {
        note("sc-error", e.message || String(e));
      }).finally(function () {
        busy(btn, false, SAVE_LABEL);
        revalidate();
      });
    }

    /* -------------------------------------------------------------- THE
       TWO-STEP CONFIRM. Asked for by name: this goes out to a TV the moment
       it's confirmed, with no second look first, so one "are you sure"
       is not enough friction for that. Step 2 is a second, separately
       worded question — not the same dialog shown twice — so a reflexive
       double-click can't click through both. */
    function openConfirm() {
      var def = SCREEN_DEF[currentScreen] || { name: "this screen" };
      el("sc-modal-screen-name").textContent = def.name;
      el("sc-modal-step1").hidden = false;
      el("sc-modal-step2").hidden = true;
      el("sc-scrim").hidden = false;
    }
    function closeConfirm() { el("sc-scrim").hidden = true; }

    function wireConfirm() {
      el("sc-modal-cancel").addEventListener("click", closeConfirm);
      el("sc-modal-continue").addEventListener("click", function () {
        el("sc-modal-step1").hidden = true;
        el("sc-modal-step2").hidden = false;
      });
      el("sc-modal-back").addEventListener("click", function () {
        el("sc-modal-step2").hidden = true;
        el("sc-modal-step1").hidden = false;
      });
      el("sc-modal-confirm").addEventListener("click", function () {
        closeConfirm();
        save();
      });
      el("sc-scrim").addEventListener("click", function (e) {
        if (e.target === el("sc-scrim")) closeConfirm();
      });
    }

    // --- wiring --------------------------------------------------------------
    function wire() {
      if (wired) return true;
      wired = true;
      if (!doc) doc = blank();

      wirePreviewFrames();
      drawLivePill();
      wireConfirm();

      Object.keys(SCREEN_DEF).forEach(function (key) {
        var tile = el("sc-tile-" + key);
        if (!tile) return;
        tile.addEventListener("click", function () { showDetail(key); });
        // role="button" on a div earns nothing for free — Enter and Space
        // activate a real <button> on their own; here that has to be wired.
        tile.addEventListener("keydown", function (e) {
          if (e.key === "Enter" || e.key === " ") { e.preventDefault(); showDetail(key); }
        });
      });
      var back = el("sc-back");
      if (back) back.addEventListener("click", showGrid);
      showGrid();

      ["sc-eyebrow", "sc-phasetag", "sc-phasetitle", "sc-needs", "sc-donate",
       "sc-prog-done", "sc-prog-now", "sc-prog-next", "sc-applabel"].forEach(function (id) {
        var box = el(id);
        if (box) box.addEventListener("input", revalidate);
      });
      OCC_KEYS.forEach(function (k) {
        ["title", "arabic", "message"].forEach(function (suf) {
          var box = el("occ-" + k + "-" + suf);
          if (box) box.addEventListener("input", revalidate);
        });
        if (k !== "ramadan") {
          var days = el("occ-" + k + "-days");
          if (days) days.addEventListener("input", revalidate);
        }
        var toggle = el("occ-" + k + "-enabled");
        if (toggle) toggle.addEventListener("change", function () {
          document.getElementById("occ-" + k).setAttribute("data-enabled", toggle.checked ? "true" : "false");
          revalidate();
        });
      });

      var saveBtn = el("sc-save");
      if (saveBtn) saveBtn.addEventListener("click", function () {
        if (revalidate().length) return;
        openConfirm();
      });

      var revert = el("sc-revert");
      if (revert) revert.addEventListener("click", function () {
        if (!saved) {
          note("sc-error", "There is nothing to go back to — the foyer content has not been read yet.");
          return;
        }
        if (!window.confirm("Throw away the changes you have made on this screen?\n\n" +
              "The foyer TVs are unaffected either way — nothing has been saved.")) return;
        doc = JSON.parse(saved);
        draw();
        note("sc-error", "");
        note("sc-ok", "Back to what is currently on the TVs.");
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

  /*  EXPOSED FOR THE TESTS. Same reason as rates/app.js's window.__RATES_FORM
      — see the note there. check() is pure and has to agree with the
      screens repo's own build.py rules; wire() must be reachable without a
      real sign-in, because the rule "nothing is saveable until the form is
      valid" has to be provable from outside mount(). */
  window.__SCREENS_FORM = { check: screens._check, wire: screens._wire };

  function renderApp(identity) {
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'screens',
        title:   'In-mosque displays',
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

    try { screens.mount(identity); } catch (e) {
      if (window.console) console.warn("In-mosque displays editor unavailable:", e);
    }
  }

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
