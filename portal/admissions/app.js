/* ===========================================================================
   APPLICATIONS — what parents have sent through the form on the website.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   25 September 2026

   THE FORM HAS BEEN LIVE AND NOBODY COULD OPEN WHAT IT WROTE.

   008 built the whole admissions pipeline and stopped one function short of
   being usable: a parent could apply, the office was emailed that something
   had arrived, and the row was purged on schedule three years later. Between
   those two events there was no way for any human being to read it. The
   Applications row in the rail said SOON, and the tables were sealed.

   db/076 is the missing half and this is the screen on top of it.

   THE SIGN-IN, TWO-STEP AND RAIL BELOW THIS PANEL ARE NOT WRITTEN HERE.

   They are lifted verbatim from portal/classes/app.js by
   tools/build_admissions_screen.py — the same shell, the same enrolment flow,
   the same fallbacks. Eleven screens sharing one implementation is why the
   drawer, the escape key and the focus handling behave identically on all of
   them; a twelfth hand-typed copy would be a twelfth chance to get one wrong.
   Only the panel in the middle belongs to this screen.
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
     APPLICATIONS

     THE LIST SAYS WHETHER. THE RECORD SAYS WHAT.

     An application carries, per child: date of birth, gender, school, whether
     they have SEND and what it is, whether they have an EHA/EHCP and what it
     is, allergies and what they are, and free-text medical conditions. That is
     Article 9 data about a child who cannot consent to any of it, and it is
     the most sensitive thing this system holds.

     So the list shows small marks - SEND, EHCP, ALLERGY, MEDICAL - and no
     detail whatsoever. The detail arrives only when somebody opens ONE
     application, and madrasah_admission_one() writes down that they did. The
     split is enforced in Postgres, not here: db/076 has a check that fails if
     the list function ever learns a detail column. This screen could not show
     it if it wanted to.

     Which is the point. A list sits open on an office screen while somebody
     works down it. A record is a deliberate act.
     ======================================================================= */
  var admissions = (function () {

    var ROWS = [];
    var OPEN = null;          // the application currently on screen, or null
    var saving = false;       // re-entry guard; see save()

    var STATUS = {
      "new":        "New",
      "reviewing":  "Reviewing",
      "offered":    "Offered",
      "waitlisted": "Waiting list",
      "declined":   "Declined",
      "withdrawn":  "Withdrawn"
    };

    /*  The class keys the public form writes. Kept here rather than fetched
        because apply/config.js is the only place they are defined and this
        screen must not import a public page's configuration - if a key ever
        appears that is not in this map it is SHOWN AS ITSELF rather than
        hidden, so a new class on the form reads as an unfamiliar label and
        not as a missing choice. */
    var CLASSES = {
      pray_and_play:  "Pray and Play",
      boys_reception: "Boys Reception",
      girls_reception:"Girls Reception",
      boys_year1:     "Boys Year 1",
      girls_year1:    "Girls Year 1",
      hifz_boys:      "Hifz — Boys",
      hifz_girls:     "Hifz — Girls",
      boys_alimiyyah: "Boys Alimiyyah",
      girls_alimah:   "Girls Alimah",
      boys_nazra:     "Boys Nazra",
      girls_nazra:    "Girls Nazra"
    };

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function note(id, message) {
      var box = el(id);
      if (!box) return;
      if (!message) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = message;
      box.hidden = false;
    }

    /*  Built from parts, never new Date("2026-09-12"). That string is parsed
        as UTC and renders as the day before for anyone west of Greenwich,
        which through a British winter means every date of birth on this screen
        would read one day early. messages.ts hit exactly this and says so. */
    function theDate(iso) {
      if (!iso) return "—";
      var p = String(iso).slice(0, 10).split("-");
      if (p.length !== 3) return String(iso);
      var d = new Date(+p[0], +p[1] - 1, +p[2]);
      if (isNaN(d.getTime())) return String(iso);
      return d.toLocaleDateString("en-GB",
        { day: "numeric", month: "short", year: "numeric" });
    }

    function theDay(iso) {
      if (!iso) return "—";
      var d = new Date(iso);
      if (isNaN(d.getTime())) return String(iso);
      var now = new Date();
      var days = Math.floor((now - d) / 86400000);
      var when = d.toLocaleDateString("en-GB",
        { day: "numeric", month: "short", year: "numeric" });
      if (days <= 0) return "Today";
      if (days === 1) return "Yesterday";
      if (days < 14) return days + " days ago";
      return when;
    }

    function pill(status) {
      return '<span class="ad-pill s-' + esc(status) + '">'
           + esc(STATUS[status] || status) + "</span>";
    }

    function flags(r) {
      var out = [];
      if (r.has_allergies) out.push('<span class="ad-flag">Allergy</span>');
      if (r.has_medical)   out.push('<span class="ad-flag">Medical</span>');
      if (r.has_ehcp)      out.push('<span class="ad-flag is-soft">EHCP</span>');
      if (r.has_send)      out.push('<span class="ad-flag is-soft">SEND</span>');
      if (r.has_note)      out.push('<span class="ad-flag is-soft">Note</span>');
      return out.length ? '<div class="ad-flags">' + out.join("") + "</div>"
                        : '<span class="ad-kids">—</span>';
    }

    // --- the notice ---------------------------------------------------------
    /*  THE ONE THING THIS SCREEN IS OPENED TO SEE.

        Three states, and they look different on purpose. A band that reads the
        same whether nothing or eleven things are waiting is a band people stop
        looking at, and then the fortnight-old application is skimmed past with
        the rest. 051 learned this with the weekly digest: the number that
        makes a shared inbox honest is not "how many" but "how long". */
    function drawNotice(o) {
      var box   = el("ad-notice");
      var count = el("ad-notice-count");
      var head  = el("ad-notice-h");
      var body  = el("ad-notice-p");
      var go    = el("ad-notice-go");
      if (!box) return;

      var n    = +o["new"] || 0;
      var days = o.oldest_new_days;
      box.hidden = false;
      box.className = "ad-notice " + (n === 0 ? "is-clear"
                                    : (days !== null && days !== undefined && days >= 7)
                                      ? "is-late" : "is-waiting");
      count.textContent = String(n);
      if (go) go.hidden = n === 0;

      if (n === 0) {
        head.textContent = "Nothing waiting";
        body.textContent = o.total
          ? "Every application that has come in has been looked at. "
            + o.total + (o.total === 1 ? " has" : " have") + " been received in total."
          : "No applications have been submitted yet. The form is live on the "
            + "website and this screen will show them the moment one arrives.";
        return;
      }

      head.textContent = n === 1
        ? "One application nobody has looked at"
        : n + " applications nobody has looked at";

      var kids = +o.children_waiting || 0;
      var parts = [];
      if (kids) {
        parts.push(kids === 1 ? "One child is waiting on a decision."
                              : kids + " children are waiting on a decision.");
      }
      if (days !== null && days !== undefined) {
        //  "Waiting 0 days" and "came in today" should not be able to
        //  disagree, so the zero case is written out rather than counted.
        parts.push(days === 0 ? "The oldest came in today."
                 : days === 1 ? "The oldest has been waiting a day."
                 : "The oldest has been waiting " + days + " days.");
      }
      //  Why this sentence is here at all: the count does not go down when
      //  you read something, and the first person it surprises will assume
      //  the screen is broken. It is kept short because it is on screen
      //  every day, and a paragraph nobody finishes reading is a paragraph
      //  that stops the two sentences above it being read either.
      parts.push("Opening one does not clear it — give it a status.");
      body.textContent = parts.join(" ");
    }

    function drawFigures(o) {
      var host = el("ad-figs");
      if (!host) return;
      function fig(n, label, sub) {
        return '<div class="ad-fig"><b>' + esc(n) + "</b><span>" + esc(label)
             + "</span>" + (sub ? "<small>" + esc(sub) + "</small>" : "") + "</div>";
      }
      host.innerHTML =
          fig(o["new"], "New", "not looked at yet")
        + fig(o.reviewing, "Reviewing", "opened, not decided")
        + fig(o.offered, "Offered", "a place has been given")
        + fig(o.waitlisted, "Waiting list", "no place yet")
        + fig(o.total, "Received in total", "all years");
    }

    function fillYears(years) {
      var sel = el("ad-year");
      if (!sel) return;
      var keep = sel.value;
      var html = '<option value="">Any year</option>';
      (years || []).forEach(function (y) {
        html += '<option value="' + esc(y) + '">' + esc(y) + "</option>";
      });
      sel.innerHTML = html;
      if (keep) sel.value = keep;
    }

    // --- the list -----------------------------------------------------------
    function drawList() {
      var body  = el("ad-rows");
      var empty = el("ad-empty");
      if (!body) return;

      if (!ROWS.length) {
        body.innerHTML = "";
        if (empty) {
          empty.hidden = false;
          empty.textContent = (el("ad-q").value || el("ad-status").value || el("ad-year").value)
            ? "Nothing matches that."
            : "No applications yet.";
        }
        return;
      }
      if (empty) empty.hidden = true;

      body.innerHTML = ROWS.map(function (r) {
        return '<tr class="ad-row" tabindex="0" data-id="' + esc(r.id) + '">'
          + '<td class="ad-ref">' + esc(r.reference) + "</td>"
          + '<td><span class="ad-who">' + esc(r.parent) + "</span>"
            + '<div class="ad-kids">' + esc(r.relationship || "") + "</div></td>"
          + "<td>" + esc(r.children)
            + '<div class="ad-kids">' + esc(r.child_names || "") + "</div></td>"
          + "<td>" + flags(r) + "</td>"
          + "<td>" + pill(r.status) + "</td>"
          + '<td class="ad-kids">' + esc(theDay(r.submitted_at)) + "</td>"
          + "</tr>";
      }).join("");
    }

    // --- one application ----------------------------------------------------
    function child(c) {
      var med = [];
      if (c.has_allergies) {
        med.push("<p><b>Allergies.</b> "
               + esc(c.allergy_detail || "Said yes, no detail given.") + "</p>");
      }
      if (c.medical_conditions && String(c.medical_conditions).trim()) {
        med.push("<p><b>Medical.</b> " + esc(c.medical_conditions) + "</p>");
      }
      if (c.has_send) {
        med.push("<p><b>SEND.</b> "
               + esc(c.send_detail || "Said yes, no detail given.") + "</p>");
      }
      if (c.has_eha_ehcp) {
        med.push("<p><b>EHA / EHCP.</b> "
               + esc(c.eha_ehcp_detail || "Said yes, no detail given.") + "</p>");
      }

      var choices = (c.choices || []).map(function (ch) {
        return "<li>" + esc(CLASSES[ch.class_key] || ch.class_key) + "</li>";
      }).join("");

      return '<div class="ad-child">'
        + "<h4>" + esc(c.first_name + " " + c.surname) + "</h4>"
        + '<p class="ad-sub">' + esc(theDate(c.date_of_birth))
          + " · " + esc(c.age_years) + " years old · " + esc(c.gender) + "</p>"
        + '<dl class="ad-grid">'
          + "<dt>School</dt><dd>" + esc(c.school_name || "—")
            + (c.school_year ? " (" + esc(c.school_year) + ")" : "") + "</dd>"
          + "<dt>Previous madrasah</dt><dd>" + esc(c.previous_madrasah || "None given") + "</dd>"
        + "</dl>"
        + (choices
            ? '<div class="ad-choices">Classes asked for, in order:<ol>' + choices + "</ol></div>"
            : "")
        + (med.length
            ? '<div class="ad-med"><h5>Read before a place is offered</h5>' + med.join("") + "</div>"
            : "")
        + (c.general_notes && String(c.general_notes).trim()
            ? '<div class="ad-choices">Anything else the parent said:<br>'
              + esc(c.general_notes) + "</div>"
            : "")
        + "</div>";
    }

    function drawRecord(a) {
      var host = el("ad-record");
      if (!host) return;
      OPEN = a;

      var p = a.parent || {};
      var addr = [p.address_line1, p.address_line2, p.town, p.postcode]
                   .filter(function (x) { return x && String(x).trim(); }).join(", ");

      var contacts = (a.contacts || []).map(function (k) {
        var bits = [k.mobile, k.telephone, k.alt_mobile, k.email]
                     .filter(function (x) { return x && String(x).trim(); });
        return "<dt>" + esc(k.full_name)
             + (k.is_primary ? " (first call)" : "") + "</dt><dd>"
             + esc(k.relationship || "") + (bits.length ? " · " + esc(bits.join(" · ")) : "")
             + "</dd>";
      }).join("");

      host.innerHTML =
          '<div class="ad-rec-head">'
        +   "<div><h3>" + esc(p.first_name + " " + p.surname) + "</h3>"
        +   '<p class="ad-sub">' + esc(a.reference) + " · " + esc(a.academic_year)
        +     " · came in " + esc(theDay(a.submitted_at))
        +     " · " + pill(a.status) + "</p></div>"
        +   '<button class="btn btn-ghost" id="ad-close" type="button">Close</button>'
        + "</div>"

        + '<dl class="ad-grid">'
        +   "<dt>Relationship</dt><dd>" + esc(p.relationship || "—") + "</dd>"
        +   "<dt>Mobile</dt><dd>" + (p.mobile
              ? '<a href="tel:' + esc(String(p.mobile).replace(/\s/g, "")) + '">'
                + esc(p.mobile) + "</a>" : "—") + "</dd>"
        +   (p.telephone ? "<dt>Telephone</dt><dd>" + esc(p.telephone) + "</dd>" : "")
        +   "<dt>Email</dt><dd>" + (p.email
              ? '<a href="mailto:' + esc(p.email) + '">' + esc(p.email) + "</a>" : "—") + "</dd>"
        +   "<dt>Address</dt><dd>" + esc(addr || "—") + "</dd>"
        +   (a.reviewed_by
              ? "<dt>Last decided by</dt><dd>" + esc(a.reviewed_by)
                + " · " + esc(theDay(a.reviewed_at)) + "</dd>" : "")
        + "</dl>"

        + "<h4 style=\"margin:22px 0 0\">"
        + esc((a.children || []).length) + ((a.children || []).length === 1
            ? " child" : " children") + "</h4>"
        + (a.children || []).map(child).join("")

        + (contacts
            ? "<h4 style=\"margin:22px 0 0\">Who to ring</h4>"
              + '<dl class="ad-grid">' + contacts + "</dl>"
            : "")

        + '<div class="ad-decide">'
        +   "<h4 style=\"margin:0 0 2px\">Decision</h4>"
        +   '<p class="ad-sub">Telling the family is a phone call. Nothing here '
        +     "sends them anything.</p>"
        +   '<div class="err" id="ad-rec-error" hidden></div>'
        +   '<div class="ad-acts">'
        //  ALL FIVE LOOK THE SAME ON PURPOSE.
        //  "Offer a place" was the gold button, which is how every other
        //  screen marks the thing you came to do. On a screen about money
        //  that is helpful. On a screen that decides whether a child is
        //  given a place it is a thumb on the scale: the office should not
        //  open a record and find one answer already lit up. These are five
        //  equals, and the screen has no opinion about which is right.
        +     '<button class="btn btn-ghost" type="button" data-to="reviewing">Reviewing</button>'
        +     '<button class="btn btn-ghost" type="button" data-to="offered">Offer a place</button>'
        +     '<button class="btn btn-ghost" type="button" data-to="waitlisted">Waiting list</button>'
        +     '<button class="btn btn-ghost" type="button" data-to="declined">Decline</button>'
        +     '<button class="btn btn-ghost" type="button" data-to="withdrawn">Withdrawn</button>'
        +   "</div>"
        +   '<div class="ad-why" id="ad-why" hidden>'
        +     '<label for="ad-why-text">Why is this being declined? A family may '
        +       "ring about it months later, and this is the only record.</label>"
        +     '<textarea id="ad-why-text" maxlength="600"></textarea>'
        +     '<div class="ad-acts">'
        +       '<button class="btn btn-gold" id="ad-why-go" type="button">Decline this application</button>'
        +       '<button class="btn btn-ghost" id="ad-why-no" type="button">Cancel</button>'
        +     "</div>"
        +   "</div>"
        +   '<div class="ad-why">'
        +     '<label for="ad-note">Office note</label>'
        +     '<p class="ad-hint">Kept on the application. It is not sent to '
        +       "anybody and the family never sees it.</p>"
        +     '<textarea id="ad-note" maxlength="600">' + esc(a.office_notes || "") + "</textarea>"
        +     '<div class="ad-acts">'
        +       '<button class="btn btn-ghost" id="ad-note-save" type="button">Save the note</button>'
        +     "</div>"
        +   "</div>"
        + "</div>";

      host.hidden = false;
      wireRecord();
      host.scrollIntoView({ behavior: "smooth", block: "start" });
    }

    function closeRecord() {
      var host = el("ad-record");
      if (host) { host.hidden = true; host.innerHTML = ""; }
      OPEN = null;
    }

    // --- talking to Postgres ------------------------------------------------
    function load() {
      return Promise.all([
        sb.rpc("madrasah_admissions_overview"),
        sb.rpc("madrasah_admission_list", {
          p_status: el("ad-status").value || null,
          p_q:      el("ad-q").value.trim() || null,
          p_year:   el("ad-year").value || null
        })
      ]).then(function (out) {
        if (out[0].error) throw out[0].error;
        if (out[1].error) throw out[1].error;
        var o = out[0].data || {};
        ROWS = out[1].data || [];
        drawNotice(o);
        drawFigures(o);
        fillYears(o.years);
        drawList();
        note("ad-error", "");
      });
    }

    function open(id) {
      return sb.rpc("madrasah_admission_one", { p_id: id }).then(function (res) {
        if (res.error) throw res.error;
        drawRecord(res.data);
      }).catch(function (e) {
        note("ad-error", "That application could not be opened — "
                       + ((e && e.message) || String(e)));
      });
    }

    /*  ONE GUARD, AND IT IS NOT THE DISABLED ATTRIBUTE.

        The fees section had a form that could be submitted twice by holding
        Enter, because the button was disabled a moment after the second press
        had already gone. A boolean checked on the way in cannot be beaten that
        way. The button is disabled as well, for what it tells the person. */
    function save(to, why) {
      if (saving) return;
      var id = OPEN && OPEN.id;
      if (!id) return;
      saving = true;

      note("ad-rec-error", "");
      sb.rpc("set_admission_status",
             { p_id: id, p_status: to, p_note: why || null })
        .then(function (res) {
          if (res.error) throw res.error;
          //  Re-read rather than patching the row in place. The list is
          //  ordered by status, so a decision moves the row - and a screen
          //  that repaints one cell and leaves it where it was is a screen
          //  telling a small lie about what just happened.
          return load().then(function () { return open(id); });
        })
        .catch(function (e) {
          note("ad-rec-error", (e && e.message) || String(e));
        })
        .finally(function () { saving = false; });
    }

    function saveNote() {
      var id = OPEN && OPEN.id;
      var box = el("ad-note");
      if (!id || !box || saving) return;
      saving = true;
      var btn = el("ad-note-save");
      if (btn) { btn.disabled = true; btn.textContent = "Saving…"; }
      note("ad-rec-error", "");
      sb.rpc("save_admission_note", { p_id: id, p_note: box.value })
        .then(function (res) {
          if (res.error) throw res.error;
          if (btn) btn.textContent = "Saved";
          return load();
        })
        .catch(function (e) { note("ad-rec-error", (e && e.message) || String(e)); })
        .finally(function () {
          saving = false;
          if (btn) {
            btn.disabled = false;
            setTimeout(function () { btn.textContent = "Save the note"; }, 1200);
          }
        });
    }

    // --- wiring -------------------------------------------------------------
    function wireRecord() {
      var host = el("ad-record");
      if (!host) return;

      var close = el("ad-close");
      if (close) close.addEventListener("click", closeRecord);

      Array.prototype.forEach.call(
        host.querySelectorAll(".ad-acts .btn[data-to]"), function (b) {
          b.addEventListener("click", function () {
            var to = b.getAttribute("data-to");
            if (to === "declined") {
              //  A refusal asks for a reason first. The database refuses one
              //  without it either way - this is so the person finds out
              //  before they press, not after.
              var why = el("ad-why");
              if (why) { why.hidden = false; el("ad-why-text").focus(); }
              return;
            }
            save(to, null);
          });
        });

      var go = el("ad-why-go");
      if (go) go.addEventListener("click", function () {
        var t = el("ad-why-text");
        var why = t ? t.value.trim() : "";
        if (!why) {
          note("ad-rec-error", "Say why before declining. It is the only record "
                             + "of the reason.");
          if (t) t.focus();
          return;
        }
        save("declined", why);
      });

      var no = el("ad-why-no");
      if (no) no.addEventListener("click", function () {
        var why = el("ad-why");
        if (why) why.hidden = true;
        note("ad-rec-error", "");
      });

      var ns = el("ad-note-save");
      if (ns) ns.addEventListener("click", saveNote);
    }

    var timer = null;
    function wire() {
      var q = el("ad-q");
      if (q) {
        q.addEventListener("input", function () {
          //  Debounced. Typing a surname should not be eight round trips.
          if (timer) clearTimeout(timer);
          timer = setTimeout(function () { refresh(); }, 250);
        });
      }
      ["ad-status", "ad-year"].forEach(function (id) {
        var s = el(id);
        if (s) s.addEventListener("change", refresh);
      });

      var go = el("ad-notice-go");
      if (go) go.addEventListener("click", function () {
        var s = el("ad-status");
        if (s) { s.value = "new"; }
        refresh();
        var bk = el("ad-list-bk");
        if (bk) bk.scrollIntoView({ behavior: "smooth", block: "start" });
      });

      var body = el("ad-rows");
      if (body) {
        body.addEventListener("click", function (e) {
          var tr = e.target.closest ? e.target.closest("tr.ad-row") : null;
          if (tr) open(tr.getAttribute("data-id"));
        });
        //  Openable from the keyboard. A row that is only a click target is a
        //  row somebody using a screen reader cannot reach.
        body.addEventListener("keydown", function (e) {
          if (e.key !== "Enter" && e.key !== " ") return;
          var tr = e.target.closest ? e.target.closest("tr.ad-row") : null;
          if (tr) { e.preventDefault(); open(tr.getAttribute("data-id")); }
        });
      }
    }

    function refresh() {
      //  A filter change while a record is open would leave that record on
      //  screen beside a list it is no longer in. Close it first.
      closeRecord();
      return load().catch(function (e) {
        note("ad-error", "The applications could not be read — "
                       + ((e && e.message) || String(e)));
      });
    }

    function mount(identity) {
      var panel = el("ad-panel");
      var noaccess = el("app-noaccess");
      if (!panel) return;

      /*  ADMINISTRATORS ONLY, and not the madrasah teaching role.

          A teacher may open the classes screen and see their own register.
          This screen carries every applicant child's medical detail and every
          parent's address and telephone number, which is a different question
          entirely. Postgres refuses a teacher anyway - every function in
          db/076 tests verified_admin() - so this is the screen being honest
          about it rather than showing an empty page and an error. */
      var roles = identity.roles || [];
      if (roles.indexOf("admin") === -1) {
        panel.hidden = true;
        if (noaccess) noaccess.hidden = false;
        return;
      }
      if (noaccess) noaccess.hidden = true;
      panel.hidden = false;
      wire();
      load().catch(function (e) {
        note("ad-error", "The applications could not be read — "
                       + ((e && e.message) || String(e)));
      });
    }

    return { mount: mount };
  })();

  function renderApp(identity) {
    //  Wait for the two deferred scripts, but only while the page is still
    //  being read. See the long note below the mount.
    if (document.readyState === "loading" &&
        !(window.AdminShell && window.MadrasahNav)) {
      document.addEventListener("DOMContentLoaded", function () {
        renderApp(identity);
      }, { once: true });
      return;
    }

    //  THE RAIL. Mounted here and nowhere else: this function runs only once
    //  the page knows who is signed in, so the list of areas can never be
    //  drawn for somebody who is not. It is a convenience, not a permission —
    //  see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        //  Two folders below the web root, so the rail's links and the logo
        //  need '../../'. shell.js does the arithmetic; this is the only
        //  thing the page has to say about it.
        depth:    2,
        current:  'md-admissions',
        title:    'Applications',
        area:     'Madrasah',
        sections: (window.MadrasahNav || {}).SECTIONS,
        roles:    identity.roles || [],
        name:     (identity.profile && identity.profile.full_name) || "",
        email:    (identity.user && identity.user.email) || ""
      });
    }

    /*  WHY THE WAIT AT THE TOP OF THIS FUNCTION.

        `sections` is what swaps the site-wide rail for the madrasah's own list
        with a way back out at the top. It is the SAME rail, not a second one:
        two left-hand columns is unusable, and a second implementation is a
        second place for the drawer, the escape key and the focus handling to
        be wrong.

        Both shell.js and nav.js are deferred, so they run after the page has
        been read — which is normally long before this function, because this
        function waits on a round trip to Supabase first. Normally. If the
        answer ever came back faster than the two files (a warm cache, a local
        run, a test with the network stubbed out), MadrasahNav would not exist
        yet and shell.js would quietly fall back to the SITE list — putting
        Gift Aid and Hall Hire in the rail of a madrasah screen, with no error
        anywhere. A missing rail is obvious; the wrong rail is not, so this
        waits for both files rather than risking it.

        Only while the document is still loading, though. If either file is
        genuinely missing, DOMContentLoaded has already gone and waiting for it
        again would hang the whole screen on a navigation problem. */

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
    try { admissions.mount(identity); } catch (e) {
      if (window.console) console.warn("applications panel unavailable:", e);
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
