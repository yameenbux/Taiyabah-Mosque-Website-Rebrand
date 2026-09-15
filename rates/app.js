/* ===========================================================================
   Taiyabah Masjid — the hall hire rate card, edited by the masjid
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   The rate card was hard-coded in index_template.html. Changing £350 to £375
   meant editing a template, running two Python scripts and pushing to GitHub —
   so in practice it meant ringing Yameen, and in the meantime the website
   quoted a price the office had stopped charging. A figure on screen that
   turns out to be wrong is worse than no figure, because somebody books on the
   strength of it and then argues about it. db/045 moved the card into
   site_content; this is the screen that writes it.

   THE SHAPE OF THIS SCREEN, AND WHY
   ---------------------------------
     * SAVING IS PUBLISHING. There is no draft. set_site_content() writes the
       one row the public page reads, and the hall hire page picks it up on the
       next load. Notices and the prayer timetable both have a draft state and
       somebody moving between the three screens will assume this one does
       too — so the lede says so, the Save button says so, and the preview is
       there to be read before it is pressed.

     * THE DEPOSIT IS NOT HERE, AND NOT BECAUSE IT WAS FORGOTTEN. The £100 is
       a Stripe Payment Link with the amount fixed at Stripe. Change the number
       on the website and the button underneath still takes £100 — the site
       would be lying about money. check_hallhire() REFUSES a body carrying a
       `deposit`, `deposit_p` or `bank` key rather than ignoring it, and check()
       below refuses it too, so the screen and the database say the same thing.
       The bank details are out for the same reason and a stronger one: a sort
       code on a public page is what a fraudster edits if they ever get in.

     * THE COMPLAINTS ARE THE DATABASE'S OWN. check() below is
       check_hallhire() from 045, rule for rule — 240 characters of intro, one
       to six bands, one to ten lines each, a price with a digit in it, a
       tel: number of 7 to 15 digits and no spaces, eight contacts, 8000
       characters all in. It is copied rather than invented because a validator
       and a constraint that disagree put a raw Postgres error in front of a
       volunteer; that has already happened once on this project, which is why
       041 and then 045 exist. A rule this screen claims that the database does
       NOT have is just as bad — it stops somebody doing something they are
       allowed to do, and nothing will ever contradict it.

     * SAVE IS DISABLED UNTIL THE FORM IS VALID, with the reasons listed above
       the button, and the ceilings are enforced by disabling "add" rather than
       by letting somebody meet a database error.

   None of this is a security control. It is JavaScript in a browser with the
   anon key beside it, and set_site_content() is refused by Postgres to anybody
   who is not a verified administrator with two-step. It is here so a committee
   member is told what is wrong in plain English.
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
     RATE CARD MODULE. Everything on this screen, kept in one place so that if
     it throws, the sign-in shell around it survives — see renderApp. */
  var rates = (function () {
    "use strict";

    /*  EVERY NUMBER HERE IS A NUMBER IN check_hallhire(). They are named
        rather than typed into the messages twice, because a limit quoted in
        one place and enforced in another is a limit that drifts. */
    var INTRO_MAX   = 240;   // length(v_intro) > 240
    var BANDS_MIN   = 1;
    var BANDS_MAX   = 6;     // 1..6 groups
    var WHEN_MAX    = 48;    // the group heading
    var NOTE_MAX    = 200;   // the note under a group
    var LINES_MIN   = 1;
    var LINES_MAX   = 10;    // 1..10 charges per group
    var N_MAX       = 70;    // the description of a charge
    var P_MAX       = 24;    // the price, as text
    var CONTACTS_MAX = 8;
    var CNAME_MAX   = 48;
    var SHOWN_MAX   = 24;
    var BODY_MAX    = 8000;  // length(p::text) > 8000

    /*  THE THREE KEYS THE DATABASE WILL NOT ACCEPT. Refused here rather than
        quietly stripped: silently dropping a field somebody deliberately sent
        is how you get a screen that appears to have saved something it threw
        away. 045 says the same, in the same words, in plpgsql. */
    var FORBIDDEN = ["deposit", "deposit_p", "bank"];

    var SAVE_LABEL = "Save — this goes live at once";

    var doc    = null;   // what is being edited
    var saved  = null;   // what came back from the database, for Undo
    var meta   = null;   // updated_at, for the "last changed" line
    var wired  = false;

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

    /* =====================================================================
       check() — check_hallhire() from 045, in the browser

       PURE. No DOM, no network, no session. It takes the plain object that
       would be sent as p_body and returns the list of things wrong with it,
       empty when there is nothing. Postgres returns only the first complaint
       because a plpgsql function returns once; a person filling a form would
       rather see all of them at once, so this collects them in the same
       order.

       Every message here has a counterpart in 045. If one is changed there,
       it is changed here — and if a rule is added there that is not added
       here, a volunteer meets it as a raw constraint violation, which is the
       fault 041 and 045 were written to end.
       =================================================================== */
    function check(o) {
      //  jsonb_typeof(p) <> 'object'. An array is an object to typeof, and
      //  Postgres would call it 'array', so it is ruled out by hand.
      if (!o || typeof o !== "object" || Array.isArray(o)) {
        return ["The rate card did not arrive as expected. Reload the page and try again."];
      }

      /*  THE DEPOSIT IS NOT NEGOTIABLE FROM HERE, and this is the one rule
          that returns on its own rather than joining a list. A body carrying
          a deposit is not a rate card with a mistake in it — it is the wrong
          shape of thing entirely, and the reason why is what the person needs
          to read, not a paragraph under five other complaints. */
      for (var k = 0; k < FORBIDDEN.length; k++) {
        if (has(o, FORBIDDEN[k])) {
          return ["The £100 deposit and the bank details cannot be changed from " +
                  "this screen. The deposit is a fixed Stripe payment link — " +
                  "changing the number here would leave the button underneath " +
                  "still taking £100."];
        }
      }

      var out = [];

      var intro = trim(o.intro);
      if (intro === "") {
        out.push("The line at the top of the rate card cannot be empty.");
      } else if (intro.length > INTRO_MAX) {
        //  The number is quoted back, because "too long" without a number
        //  means deleting words until it stops complaining.
        out.push("The line at the top is " + intro.length + " characters. The limit is " +
                 INTRO_MAX + ".");
      }

      var bands = o.bands;
      if (!Array.isArray(bands)) {
        out.push("The rate card needs at least one group of charges.");
      } else if (bands.length < BANDS_MIN || bands.length > BANDS_MAX) {
        out.push("There are " + bands.length + " groups of charges. There must be between " +
                 BANDS_MIN + " and " + BANDS_MAX + ".");
      } else {
        bands.forEach(function (b) {
          b = b || {};
          var when = trim(b.when);
          if (when === "") {
            out.push("Every group needs a heading, like “Monday – Thursday”.");
          } else if (when.length > WHEN_MAX) {
            out.push("The group heading “" + when.slice(0, 20) + "…” is too long. " +
                     "The limit is " + WHEN_MAX + " characters.");
          }
          var bnote = trim(b.note);
          if (bnote.length > NOTE_MAX) {
            out.push("The note under “" + (when || "that group") + "” is too long. " +
                     "The limit is " + NOTE_MAX + " characters.");
          }

          var named = when || "that group";
          var lines = b.lines;
          if (!Array.isArray(lines)) {
            out.push("The group “" + named + "” has no charges in it.");
            return;
          }
          if (lines.length < LINES_MIN || lines.length > LINES_MAX) {
            out.push("The group “" + named + "” has " + lines.length + " charges. " +
                     "There must be between " + LINES_MIN + " and " + LINES_MAX + ".");
            return;
          }
          lines.forEach(function (l) {
            l = l || {};
            var n = trim(l.n);
            var p = trim(l.p);
            if (n === "") {
              out.push("Every charge needs a description, like “1 hall”.");
            } else if (n.length > N_MAX) {
              out.push("The charge “" + n.slice(0, 24) + "…” is too long. " +
                       "The limit is " + N_MAX + " characters.");
            }
            var pnamed = n || "that charge";
            if (p === "") {
              out.push("The charge “" + pnamed + "” has no price against it.");
            } else if (p.length > P_MAX) {
              out.push("The price for “" + pnamed + "” is too long. The limit is " +
                       P_MAX + " characters.");
            } else if (!/[0-9]/.test(p)) {
              //  A price with no digit in it is not a price. "£350" passes,
              //  "45p per person" passes, "ask in the office" does not — and
              //  that last one is exactly what somebody types when they have
              //  not decided yet, which is the moment the website should not
              //  be quoting anything.
              out.push("The price for “" + pnamed + "” has no number in it. If the " +
                       "charge depends on the booking, take the line out rather than " +
                       "leaving it vague.");
            }
          });
        });
      }

      /*  Contacts are optional as a group — the office number is in the
          markup regardless — but each one has to be usable if it is there.
          `if p ? 'contacts'` in 045 is key-present, not truthiness, so an
          explicit null is checked the same way. */
      if (has(o, "contacts") && o.contacts !== null && o.contacts !== undefined) {
        if (!Array.isArray(o.contacts)) {
          out.push("The booking contacts did not arrive as expected.");
        } else if (o.contacts.length > CONTACTS_MAX) {
          out.push("There are more than " + CONTACTS_MAX + " booking contacts. " +
                   "Keep it to the people somebody should actually ring.");
        } else {
          o.contacts.forEach(function (c) {
            c = c || {};
            var n = trim(c.n);
            if (n === "") {
              out.push("Every booking contact needs a name.");
            } else if (n.length > CNAME_MAX) {
              out.push("The contact name “" + n.slice(0, 20) + "…” is too long. " +
                       "The limit is " + CNAME_MAX + " characters.");
            }
            var who = n || "that contact";
            //  Digits only, and no more than fifteen: that is E.164's ceiling,
            //  and it is what goes inside href="tel:". Spaces are for the
            //  version people read, which is a separate field.
            if (!/^[0-9]{7,15}$/.test(trim(c.tel))) {
              out.push("The number for " + who + " must be 7 to 15 digits with no " +
                       "spaces — that is the part the phone dials. Type the readable " +
                       "version in the box beside it.");
            }
            var shown = trim(c.shown);
            if (shown === "" || shown.length > SHOWN_MAX) {
              out.push("The number shown on the page for " + who + " must be between " +
                       "1 and " + SHOWN_MAX + " characters.");
            }
          });
        }
      }

      /*  A ceiling on the whole thing. Every limit above is per field, and
          six bands of ten lines each is a lot of small fields; this is the
          backstop that stops the rate card becoming a document. Postgres
          measures the jsonb text; JSON.stringify is the nearest thing a
          browser has, and it is close enough to warn before a round trip. */
      var size;
      try { size = JSON.stringify(o).length; } catch (e) { size = 0; }
      if (size > BODY_MAX) {
        out.push("The rate card is too big. Shorten the notes, or use fewer groups.");
      }

      return out;
    }

    /* ---------------------------------------------------------------- dates */
    function readable(iso) {
      if (!iso) return "";
      var d = new Date(iso);
      if (isNaN(d.getTime())) return "";
      try {
        return d.toLocaleString("en-GB", {
          weekday: "short", day: "numeric", month: "short", year: "numeric",
          hour: "2-digit", minute: "2-digit"
        });
      } catch (e) {
        return d.toISOString().slice(0, 16).replace("T", " ");
      }
    }

    /*  The shape the database will accept with the least in it. Used when
        nothing is seeded, when the read fails, and by wire() on a page nobody
        is signed in to — an empty <div> where the editor should be is
        indistinguishable from a broken screen. */
    function blank() {
      return {
        intro: "",
        bands: [{ when: "", note: "", lines: [{ n: "", p: "" }] }],
        contacts: []
      };
    }

    // --- reading the boxes back ----------------------------------------------
    /*  Read the DOM into `doc`. Called before every redraw, because a redraw
        replaces the inputs and whatever was typed since the last one would go
        with them. */
    function harvest() {
      if (!doc) doc = blank();
      if (!Array.isArray(doc.bands))    doc.bands = [];
      if (!Array.isArray(doc.contacts)) doc.contacts = [];

      var intro = el("hr-intro");
      if (intro) doc.intro = intro.value;

      var bandHost = el("hr-bands");
      if (bandHost) {
        Array.prototype.forEach.call(bandHost.querySelectorAll(".hr-band"), function (row) {
          var b = doc.bands[Number(row.getAttribute("data-i"))];
          if (!b) return;
          Array.prototype.forEach.call(row.querySelectorAll("[data-f]"), function (box) {
            b[box.getAttribute("data-f")] = box.value;
          });
          if (!Array.isArray(b.lines)) b.lines = [];
          Array.prototype.forEach.call(row.querySelectorAll(".hr-line"), function (lrow) {
            var l = b.lines[Number(lrow.getAttribute("data-j"))];
            if (!l) return;
            Array.prototype.forEach.call(lrow.querySelectorAll("[data-lf]"), function (box) {
              l[box.getAttribute("data-lf")] = box.value;
            });
          });
        });
      }

      var conHost = el("hr-cons");
      if (conHost) {
        Array.prototype.forEach.call(conHost.querySelectorAll(".hr-con"), function (row) {
          var c = doc.contacts[Number(row.getAttribute("data-i"))];
          if (!c) return;
          Array.prototype.forEach.call(row.querySelectorAll("[data-cf]"), function (box) {
            c[box.getAttribute("data-cf")] = box.value;
          });
        });
      }
      return doc;
    }

    /*  What would be sent. Trimmed, because check_hallhire() trims before it
        measures and a value that passes here and fails there is the whole
        problem this file is written to avoid. */
    function body() {
      var o = harvest();
      return {
        intro: trim(o.intro),
        bands: (o.bands || []).map(function (b) {
          b = b || {};
          return {
            when: trim(b.when),
            note: trim(b.note),
            lines: ((b.lines) || []).map(function (l) {
              l = l || {};
              return { n: trim(l.n), p: trim(l.p) };
            })
          };
        }),
        contacts: (o.contacts || []).map(function (c) {
          c = c || {};
          return { n: trim(c.n), tel: trim(c.tel), shown: trim(c.shown) };
        })
      };
    }

    // --- drawing the editor --------------------------------------------------
    function countdown(boxId, value, limit) {
      var box = el(boxId);
      if (!box) return;
      var left = limit - trim(value).length;
      box.textContent = left >= 0
        ? left + " characters left"
        : (-left) + " characters too many — the limit is " + limit;
      box.classList.toggle("is-over", left < 0);
    }

    function drawBands() {
      var host = el("hr-bands");
      if (!host) return;
      var list = (doc && doc.bands) || [];

      if (!list.length) {
        host.innerHTML = '<p class="hr-empty">There are no groups of charges. ' +
          "The website needs at least one, or the hall hire page has no prices " +
          "on it at all.</p>";
      } else {
        host.innerHTML = list.map(function (b, i) {
          var lines = (b && b.lines) || [];
          var atLineCeiling = lines.length >= LINES_MAX;
          return '<div class="hr-band" data-i="' + i + '">' +
            '<div class="hr-band-top">' +
              '<span class="hr-band-n">Group ' + (i + 1) + " of " + list.length + "</span>" +
              '<span class="hr-band-acts">' +
                '<button type="button" class="btn btn-ghost hr-mini" data-act="band-up"' +
                  (i === 0 ? " disabled" : "") + ">Up</button>" +
                '<button type="button" class="btn btn-ghost hr-mini" data-act="band-down"' +
                  (i === list.length - 1 ? " disabled" : "") + ">Down</button>" +
                '<button type="button" class="btn btn-ghost hr-mini hr-no" data-act="band-remove"' +
                  (list.length <= BANDS_MIN ? " disabled" : "") + ">Remove group</button>" +
              "</span>" +
            "</div>" +

            '<label class="fld"><span>Heading</span>' +
              '<input type="text" data-f="when" maxlength="90" value="' + esc(b && b.when) +
              '" placeholder="Monday – Thursday"></label>' +

            '<label class="fld"><span>Note under it (optional)</span>' +
              '<input type="text" data-f="note" maxlength="300" value="' + esc(b && b.note) +
              '" placeholder="There is no one-hall rate at the weekend."></label>' +

            '<div class="hr-lines">' + lines.map(function (l, j) {
              return '<div class="hr-line" data-j="' + j + '">' +
                '<input type="text" data-lf="n" maxlength="120" value="' + esc(l && l.n) +
                  '" placeholder="1 hall" aria-label="What the charge is for">' +
                '<input type="text" data-lf="p" maxlength="40" value="' + esc(l && l.p) +
                  '" placeholder="£350" aria-label="The price">' +
                '<button type="button" class="btn btn-ghost hr-mini hr-no" data-act="line-remove"' +
                  (lines.length <= LINES_MIN ? " disabled" : "") + ">Remove</button>" +
              "</div>";
            }).join("") + "</div>" +

            '<div class="row">' +
              '<button type="button" class="btn btn-ghost hr-mini" data-act="line-add"' +
                (atLineCeiling ? " disabled" : "") + ">Add a charge</button>" +
              (atLineCeiling
                ? '<span class="hr-hint">Ten charges is as many as one group can ' +
                  "hold. Start another group, or take a line out.</span>"
                : "") +
            "</div>" +
          "</div>";
        }).join("");
      }

      //  Disabled at the ceiling rather than left to fail. A button that calls
      //  the database and comes back with "There are 7 groups of charges" is a
      //  button that lied about what it would do.
      var add = el("hr-add-band");
      if (add) add.disabled = list.length >= BANDS_MAX;
      var ceiling = el("hr-band-ceiling");
      if (ceiling) ceiling.hidden = list.length < BANDS_MAX;
    }

    function drawCons() {
      var host = el("hr-cons");
      if (!host) return;
      var list = (doc && doc.contacts) || [];

      if (!list.length) {
        host.innerHTML = '<p class="hr-empty">Nobody listed. The office number is ' +
          "printed on the hall hire page by the website itself, so this can be " +
          "left empty — but a name and a number people can tap is what stops " +
          "them ringing the wrong person.</p>";
      } else {
        host.innerHTML = list.map(function (c, i) {
          return '<div class="hr-con" data-i="' + i + '">' +
            '<div class="hr-con-grid">' +
              '<label class="fld"><span>Name</span>' +
                '<input type="text" data-cf="n" maxlength="90" value="' + esc(c && c.n) +
                '" placeholder="Masjid office"></label>' +

              '<label class="fld"><span>Number to dial</span>' +
                '<input type="text" data-cf="tel" inputmode="numeric" maxlength="24" value="' +
                esc(c && c.tel) + '" placeholder="01204535997">' +
                //  Said beside the box it applies to, not once at the top. The
                //  two number fields look interchangeable and are not: this one
                //  goes inside href="tel:" and a space in it stops the phone
                //  dialling at all.
                '<span class="hr-hint">Digits only, no spaces or brackets — this is ' +
                "what the phone dials when somebody taps it.</span></label>" +

              '<label class="fld"><span>Number as shown</span>' +
                '<input type="text" data-cf="shown" maxlength="40" value="' + esc(c && c.shown) +
                '" placeholder="01204 535 997">' +
                '<span class="hr-hint">Spaces and all — this is what people read.</span></label>' +
            "</div>" +
            '<div class="row">' +
              '<button type="button" class="btn btn-ghost hr-mini hr-no" data-act="con-remove">' +
              "Remove this contact</button>" +
            "</div>" +
          "</div>";
        }).join("");
      }

      var add = el("hr-add-con");
      if (add) add.disabled = list.length >= CONTACTS_MAX;
      var ceiling = el("hr-con-ceiling");
      if (ceiling) ceiling.hidden = list.length < CONTACTS_MAX;
    }

    function drawMeta() {
      var box = el("hr-meta");
      if (!box) return;
      if (!meta || !meta.updated_at) {
        box.textContent = "Last changed: not known — this is still what the website " +
                          "was built with.";
        return;
      }
      box.textContent = "Last changed " + readable(meta.updated_at) + ".";
    }

    /* ---------------------------------------------------------- the preview
       Drawn to look like the real card on the hall hire page, because the
       whole job of this panel is to let somebody recognise what they are
       about to publish. Escaped on the way in: everything here is typed by a
       verified administrator, but this is the one screen where the text is a
       PRICE, and a price is the thing worth being careful with. */
    function drawPreview(b) {
      var host = el("hr-pv");
      if (!host) return;
      var bits = [];

      bits.push("<h4>Charges</h4>");
      bits.push('<p class="hr-pv-eff">' +
        (b.intro ? esc(b.intro) : "<em>The line at the top is empty.</em>") + "</p>");

      if (!b.bands.length) {
        bits.push('<p class="hr-pv-note">No charges at all — the website would have ' +
                  "an empty price list.</p>");
      }
      b.bands.forEach(function (bd) {
        bits.push('<div class="hr-pv-band">');
        bits.push('<span class="hr-pv-when">' +
          esc(bd.when || "(this group has no heading)") + "</span>");
        bd.lines.forEach(function (l) {
          bits.push('<div class="hr-pv-line">' +
            '<span class="hr-pv-nm">' + esc(l.n || "(no description)") + "</span>" +
            '<span class="hr-pv-pr">' + esc(l.p || "—") + "</span></div>");
        });
        if (bd.note) bits.push('<p class="hr-pv-note">' + esc(bd.note) + "</p>");
        bits.push("</div>");
      });

      /*  The two paragraphs this screen cannot touch, shown anyway. Leaving
          them out would make the preview look like the whole card, and
          somebody would reasonably conclude the deposit had disappeared off
          the website. */
      bits.push('<p class="hr-pv-fixed"><strong>£100 deposit, paid online when you ' +
        "book.</strong> That is what reserves the date. Printed by the website " +
        "itself and not editable here — it is a Stripe payment link.</p>");
      bits.push('<p class="hr-pv-fixed">The <strong>balance</strong> is due 30 days ' +
        "before and is paid at the office, with the masjid's bank details. Printed " +
        "by the website itself and not editable here.</p>");

      bits.push("<h4>Hall bookings</h4>");
      bits.push('<p class="hr-pv-eff">Ring the office, or any of the booking team ' +
                "directly.</p>");
      if (!b.contacts.length) {
        bits.push('<p class="hr-pv-note">Nobody listed, so the page shows only the ' +
                  "office number it prints itself.</p>");
      }
      b.contacts.forEach(function (c) {
        var dialable = /^[0-9]{7,15}$/.test(c.tel);
        bits.push('<div class="hr-pv-line">' +
          '<span class="hr-pv-nm">' + esc(c.n || "(no name)") + "</span>" +
          '<span class="hr-pv-pr">' +
            (dialable
              ? '<a href="tel:' + esc(c.tel) + '">' + esc(c.shown || c.tel) + "</a>"
              : esc(c.shown || "—") + ' <span class="hr-pv-bad">will not dial</span>') +
          "</span></div>");
      });

      host.innerHTML = bits.join("");
    }

    /*  Re-run after every keystroke. The Save button is the only way to reach
        set_site_content(), so this is where "save is impossible until the form
        is valid" actually lives — the `disabled` in the markup only covers the
        first paint. */
    function revalidate() {
      var b = body();
      countdown("hr-intro-count", b.intro, INTRO_MAX);
      drawPreview(b);

      var complaints = check(b);
      var box = el("hr-complaints");
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
      var save = el("hr-save");
      if (save) save.disabled = complaints.length > 0;
      return complaints;
    }

    function draw() {
      var intro = el("hr-intro");
      if (intro) intro.value = (doc && doc.intro) || "";
      drawBands();
      drawCons();
      drawMeta();
      revalidate();
    }

    function focusLast(selector) {
      var rows = document.querySelectorAll(selector);
      var last = rows[rows.length - 1];
      if (!last) return;
      last.scrollIntoView({ behavior: "smooth", block: "center" });
      var first = last.querySelector("input");
      if (first) first.focus();
    }

    // --- loading and saving --------------------------------------------------
    function load() {
      note("hr-error", "");
      return sb.from("site_content").select("body,updated_at")
               .eq("key", "hallhire").single()
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var row = res.data || {};
          doc = row.body ? JSON.parse(JSON.stringify(row.body)) : blank();
          if (!Array.isArray(doc.bands) || !doc.bands.length) doc.bands = blank().bands;
          if (!Array.isArray(doc.contacts)) doc.contacts = [];
          /*  A stored body cannot carry these — check_hallhire() has refused
              them since 045 — but if one ever did, sending it back untouched
              would fail the save with a message about a field nobody can see.
              Dropped on the way IN, where it is a repair; never on the way
              out, where it would be a lie. */
          FORBIDDEN.forEach(function (k) { delete doc[k]; });
          meta  = { updated_at: row.updated_at };
          saved = JSON.stringify(doc);
          draw();
        })
        .catch(function (e) {
          note("hr-error", "Couldn't read the rate card: " + (e.message || e) +
                           " — nothing on the website has changed.");
          if (!doc) { doc = blank(); draw(); }
        });
    }

    function save() {
      //  Belt and braces; the button is disabled too. Both, because the
      //  disabled attribute is one line away from being deleted by somebody
      //  tidying the markup, and this is the call that changes a price.
      if (revalidate().length) return;

      var out = body();
      var btn = el("hr-save");
      busy(btn, true, SAVE_LABEL);
      note("hr-error", ""); note("hr-ok", "");

      //  set_site_content(p_key text, p_body jsonb) — the argument names are
      //  the keys of this object. Anything else is "function does not exist".
      sb.rpc("set_site_content", { p_key: "hallhire", p_body: out })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          note("hr-ok", "Saved. This is on the hall hire page of the website now — " +
                        "there is nothing else to press. Anybody with the page already " +
                        "open sees it when they next load it.");
          return load();
        })
        .catch(function (e) {
          note("hr-error", e.message || String(e));
        })
        .finally(function () {
          busy(btn, false, SAVE_LABEL);
          revalidate();
        });
    }

    // --- the repeating editors -----------------------------------------------
    function onBandClick(ev) {
      var btn = ev.target.closest ? ev.target.closest("button[data-act]") : null;
      if (!btn || btn.disabled) return;
      var row = btn.closest(".hr-band");
      if (!row) return;
      var i   = Number(row.getAttribute("data-i"));
      var act = btn.getAttribute("data-act");

      //  Read the boxes back BEFORE anything is reordered or redrawn, or
      //  whatever has been typed since the last draw is thrown away.
      harvest();
      var b = doc.bands[i];
      if (!b) return;

      if (act === "line-add") {
        if (b.lines.length >= LINES_MAX) return;
        b.lines.push({ n: "", p: "" });
      } else if (act === "line-remove") {
        var lrow = btn.closest(".hr-line");
        if (!lrow || b.lines.length <= LINES_MIN) return;
        b.lines.splice(Number(lrow.getAttribute("data-j")), 1);
      } else if (act === "band-remove") {
        if (doc.bands.length <= BANDS_MIN) return;
        //  Named back, with the count, because this is the one action on the
        //  screen that takes several prices off the website at once.
        if (!window.confirm(
              "Remove the group “" + (trim(b.when) || "with no heading") + "” and the " +
              b.lines.length + " charge(s) in it?\n\n" +
              "It comes off the hall hire page as soon as you save.")) return;
        doc.bands.splice(i, 1);
      } else if (act === "band-up" && i > 0) {
        doc.bands.splice(i - 1, 0, doc.bands.splice(i, 1)[0]);
      } else if (act === "band-down" && i < doc.bands.length - 1) {
        doc.bands.splice(i + 1, 0, doc.bands.splice(i, 1)[0]);
      }
      draw();
    }

    function onConClick(ev) {
      var btn = ev.target.closest ? ev.target.closest("button[data-act]") : null;
      if (!btn || btn.disabled) return;
      var row = btn.closest(".hr-con");
      if (!row) return;
      harvest();
      var i = Number(row.getAttribute("data-i"));
      var c = doc.contacts[i];
      if (!c) return;
      if (btn.getAttribute("data-act") === "con-remove") {
        if (!window.confirm("Take " + (trim(c.n) || "this contact") + " off the hall " +
              "hire page?\n\nTheir number stops appearing as soon as you save.")) return;
        doc.contacts.splice(i, 1);
        draw();
      }
    }

    // --- wiring --------------------------------------------------------------
    /*  Attaches every listener and draws the editor once. It must work with no
        session and no network — see the note beside window.__RATES_FORM. */
    function wire() {
      if (wired) return true;
      wired = true;
      if (!doc) doc = blank();

      var intro = el("hr-intro");
      if (intro) intro.addEventListener("input", revalidate);

      var bandHost = el("hr-bands");
      var conHost  = el("hr-cons");

      /*  One listener on each container rather than one per box: the rows are
          redrawn whenever a group or a contact is added, removed or moved, so
          per-row listeners would be re-attached each time and the old ones
          left behind. */
      if (bandHost) {
        bandHost.addEventListener("input", revalidate);
        bandHost.addEventListener("click", onBandClick);
      }
      if (conHost) {
        conHost.addEventListener("input", revalidate);
        conHost.addEventListener("click", onConClick);
      }

      var addBand = el("hr-add-band");
      if (addBand) addBand.addEventListener("click", function () {
        harvest();
        if (doc.bands.length >= BANDS_MAX) return;
        doc.bands.push({ when: "", note: "", lines: [{ n: "", p: "" }] });
        draw();
        focusLast(".hr-band");
      });

      var addCon = el("hr-add-con");
      if (addCon) addCon.addEventListener("click", function () {
        harvest();
        if (doc.contacts.length >= CONTACTS_MAX) return;
        doc.contacts.push({ n: "", tel: "", shown: "" });
        draw();
        focusLast(".hr-con");
      });

      var saveBtn = el("hr-save");
      if (saveBtn) saveBtn.addEventListener("click", save);

      var revert = el("hr-revert");
      if (revert) revert.addEventListener("click", function () {
        if (!saved) {
          note("hr-error", "There is nothing to go back to — the rate card on the " +
                           "website has not been read yet.");
          return;
        }
        if (!window.confirm("Throw away the changes you have made on this screen?\n\n" +
              "The website is unaffected either way — nothing has been saved.")) return;
        doc = JSON.parse(saved);
        draw();
        note("hr-error", "");
        note("hr-ok", "Back to what is on the website.");
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
      this screen worth testing, because it has to agree with check_hallhire()
      in 045 exactly. Where the two disagree, a volunteer is told a rate card
      is fine and then gets a raw Postgres error; that has already happened
      once on this project, which is why 041 exists and why 045 was written
      the same way.

      wire() is not pure, and it is here for a reason learned the hard way on
      times/. The rule "nothing is saveable until the form is valid" lived
      inside mount(), which runs only after a real sign-in — so no test could
      ever reach it, and the Save button is disabled in the markup as well, so
      it read as disabled whether the rule was there or had been deleted. The
      check passed with the code removed. Calling wire() on a page nobody is
      signed in to wires a Save button whose click calls set_site_content(),
      which Postgres refuses to anybody who is not a verified administrator
      with two-step. The check is in the database, not in this file. */
  window.__RATES_FORM = { check: rates._check, wire: rates._wire };

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'rates',
        title:   'Hall hire charges',
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
    try { rates.mount(identity); } catch (e) {
      if (window.console) console.warn("rate card editor unavailable:", e);
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
