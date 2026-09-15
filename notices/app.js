/* ===========================================================================
   Taiyabah Masjid — the notices on the front page, edited by the masjid
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   `notices` was a table with no way in and no way out: one row in it, nothing
   on the website reading it, and the only writer a SECURITY DEFINER function
   granted to service_role with no permission check inside it. 040 and 041 gave
   it four guarded functions and one definition of what a notice is. This is
   the screen that calls them, and without it the committee is still ringing
   somebody to change a janāzah time.

   THE SHAPE OF THIS SCREEN, AND WHY
   ---------------------------------
     * SAVING IS NOT PUBLISHING. save_notice() writes drafts, always, and the
       website never reads an unpublished row. Somebody can half-type a death
       notice, the phone rings, and nothing is on the front page. Publishing is
       a separate button pressed on purpose.

     * THE COMPLAINTS ARE THE DATABASE'S OWN. check() below is check_notice()
       from 041, rule for rule — seventy characters, six topics, https only, a
       picture with both sides or neither, a "remove after" date in the future.
       The reason it is copied rather than invented is 041 itself: a validator
       and a constraint that disagreed put a raw `notices_topic_check`
       violation in front of a volunteer. A rule this screen claims that the
       database does not have is just as bad — it stops somebody doing
       something they are allowed to do, and nothing in the database will ever
       contradict it.

     * SAVE IS DISABLED UNTIL THE FORM IS VALID, with the reasons listed. The
       limits are shown before they are met: the heading counts down to 70.

   None of this is a security control. It is JavaScript in a browser with the
   anon key beside it, and every one of these RPCs is refused by Postgres to
   anybody who is not a verified administrator with two-step. It is here so a
   committee member is told what is wrong in plain English.

   THE PICTURE, AND WHAT THE BUCKET MEANS
   --------------------------------------
   `notices` is a PUBLIC bucket (042). Anything uploaded is on the internet at
   once, to anybody with the address, whether or not the notice is ever
   published — there is no draft state for a file. The screen says so beside
   the button rather than in a comment nobody reads.
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
     NOTICES MODULE. Everything on this screen, kept in one place so that if
     it throws, the sign-in shell around it survives — see renderApp. */
  var notices = (function () {
    "use strict";

    /*  THE SIX TOPICS ARE THE SIX IN notice_topic_is_one_we_show.

        Not five, and not seven. 040 offered `ramadan` and `madrasah` while
        the live constraint still only allowed `kahf`, so both choices were
        refused by the table after the validator had said they were fine. A
        topic the database allows but this dropdown cannot reach is the same
        fault wearing the other hat: it is dead, and nobody would ever find
        out why. The labels are what a person calls them; the values are what
        Postgres checks. */
    var TOPICS = ["announcements", "events", "janazah", "kahf", "ramadan", "madrasah"];
    var TOPIC_LABEL = {
      announcements: "Announcements",
      events:        "Events",
      janazah:       "Janāẓah",
      kahf:          "Sūrat al-Kahf",
      ramadan:       "Ramadan",
      madrasah:      "Madrasah"
    };

    var TITLE_MAX = 70;     // notice_has_a_short_heading
    var BODY_MAX  = 2000;   // notice_body_is_absent_or_real

    //  042: the bucket is public, capped at 5 MB, and accepts these three.
    var BUCKET     = "notices";
    var MAX_BYTES  = 5 * 1024 * 1024;
    var FILE_KINDS = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

    var rows      = [];     // the last list read, so Edit can fill from it
    var saveLabel = "Save as a draft";

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function note(id, msg) {
      var n = el(id); if (!n) return;
      if (!msg) { n.hidden = true; n.textContent = ""; return; }
      n.textContent = msg; n.hidden = false;
    }

    function trim(v) { return String(v == null ? "" : v).trim(); }

    /* =====================================================================
       check() — check_notice() from 041, in the browser

       PURE. No DOM, no network, no session. It takes the plain object the
       form makes and returns the list of things wrong with it, empty when
       there is nothing. Postgres returns only the first complaint because a
       plpgsql function returns once; a person filling a form would rather
       see all of them at once, so this collects them in the same order.

       Every message here has a counterpart in 041. If one is changed there,
       it is changed here — and if a rule is added there that is not added
       here, a volunteer meets it as a raw constraint violation, which is the
       fault 041 was written to end.
       =================================================================== */
    function check(o) {
      o = o || {};
      var out   = [];
      var title = trim(o.title);
      var body  = trim(o.body);
      var topic = trim(o.topic).toLowerCase();
      var img   = trim(o.image_url);
      var w     = trim(o.image_w) === "" ? null : trim(o.image_w);
      var h     = trim(o.image_h) === "" ? null : trim(o.image_h);

      if (title === "") {
        out.push("A notice needs a heading.");
      } else if (title.length > TITLE_MAX) {
        //  The number is quoted back, because "too long" without a number
        //  means deleting words until it stops complaining.
        out.push("The heading is " + title.length + " characters. The limit is " +
                 TITLE_MAX + " — it is read at a glance, usually on a phone.");
      }

      if (body.length > BODY_MAX) {
        out.push("The notice is " + body.length + " characters. The limit is " + BODY_MAX + ".");
      }

      if (TOPICS.indexOf(topic) === -1) {
        out.push("The topic must be one of: " + TOPICS.join(", ") + ".");
      }

      /*  Case-sensitive on purpose. The constraint is `image_url like
          'https://%'` and check_notice() uses `!~ '^https://'`, so HTTPS:// in
          capitals is refused by the database. Accepting it here would let
          somebody save a notice the table then throws out. */
      if (img !== "" && img.indexOf("https://") !== 0) {
        out.push("A picture has to be an https:// web address.");
      }
      if (img === "" && (w !== null || h !== null)) {
        out.push("There is a picture size but no picture.");
      }
      if ((w === null) !== (h === null)) {
        out.push("A picture needs both a width and a height, or neither. With only " +
                 "one, the page jumps when the picture loads.");
      }

      //  A notice that has already expired would save and then be invisible,
      //  and the person would reasonably conclude the screen is broken.
      var expires = trim(o.expires_at);
      if (expires !== "") {
        var when = new Date(expires).getTime();
        if (isNaN(when)) {
          out.push("That “remove after” date isn't one the website can read. " +
                   "Pick it from the calendar, or leave it blank.");
        } else if (when <= Date.now()) {
          out.push("That “remove after” date has already passed, so the notice " +
                   "would never appear. Leave it blank to keep the notice until you delete it.");
        }
      }

      return out;
    }

    /* ---------------------------------------------------------------- dates
       A datetime-local box hands back "2026-12-01T18:00" with no timezone on
       it. Sent verbatim, Postgres casts it using the SERVER's timezone, which
       is UTC — so a notice set to come off at 6pm in December is an hour out
       in summer and nobody would ever work out why. Both directions go
       through the browser's own clock instead. */
    function toStamp(v) {
      v = trim(v);
      if (!v) return "";
      var d = new Date(v);
      return isNaN(d.getTime()) ? "" : d.toISOString();
    }

    function toLocalBox(iso) {
      if (!iso) return "";
      var d = new Date(iso);
      if (isNaN(d.getTime())) return "";
      var p = function (n) { return (n < 10 ? "0" : "") + n; };
      return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate()) +
             "T" + p(d.getHours()) + ":" + p(d.getMinutes());
    }

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

    // --- the form ------------------------------------------------------------
    function readForm() {
      return {
        id:         el("nt-id").value,
        title:      el("nt-title").value,
        body:       el("nt-body").value,
        topic:      el("nt-topic").value,
        image_url:  el("nt-image-url").value,
        image_w:    el("nt-image-w").value,
        image_h:    el("nt-image-h").value,
        event_at:   el("nt-event-at").value,
        expires_at: el("nt-expires-at").value
      };
    }

    function countdown(boxId, value, limit, word) {
      var box  = el(boxId);
      if (!box) return;
      var left = limit - trim(value).length;
      box.textContent = left >= 0
        ? left + " " + word + " left"
        : (-left) + " " + word + " too many — the limit is " + limit;
      box.classList.toggle("is-over", left < 0);
    }

    function drawPreview() {
      var url  = trim(el("nt-image-url").value);
      var w    = trim(el("nt-image-w").value);
      var h    = trim(el("nt-image-h").value);
      var wrap = el("nt-preview");
      if (!url) { wrap.hidden = true; el("nt-thumb").removeAttribute("src"); return; }
      el("nt-thumb").src = url;
      el("nt-size").textContent = (w && h) ? w + " × " + h + " pixels"
                                           : "Size unknown — the page may jump when it loads.";
      wrap.hidden = false;
    }

    /*  Re-run after every keystroke. The Save button is the only way to reach
        save_notice(), so this is where "save is impossible until it is valid"
        actually lives — the `disabled` in the markup only covers the first
        paint. */
    function revalidate() {
      var f = readForm();
      countdown("nt-title-count", f.title, TITLE_MAX, "characters");
      countdown("nt-body-count",  f.body,  BODY_MAX,  "characters");

      var complaints = check(f);
      var box = el("nt-complaints");
      if (complaints.length) {
        box.innerHTML = "<ul>" + complaints.map(function (c) {
          return "<li>" + esc(c) + "</li>";
        }).join("") + "</ul>";
        box.hidden = false;
      } else {
        box.hidden = true;
        box.innerHTML = "";
      }
      el("nt-save").disabled = complaints.length > 0;
      return complaints;
    }

    function resetForm() {
      el("nt-id").value         = "";
      el("nt-title").value      = "";
      el("nt-body").value       = "";
      el("nt-topic").value      = "announcements";
      el("nt-image-url").value  = "";
      el("nt-image-w").value    = "";
      el("nt-image-h").value    = "";
      el("nt-event-at").value   = "";
      el("nt-expires-at").value = "";
      el("nt-file").value       = "";
      el("nt-form-head").textContent = "Add a notice";
      el("nt-form-lede").textContent =
        "A new notice is saved as a draft. Nobody sees it until you publish it.";
      el("nt-cancel").hidden = true;
      saveLabel = "Save as a draft";
      el("nt-save").textContent = saveLabel;
      drawPreview();
      revalidate();
    }

    function fillForm(n) {
      el("nt-id").value         = n.id || "";
      el("nt-title").value      = n.title || "";
      el("nt-body").value       = n.body || "";
      el("nt-topic").value      = TOPICS.indexOf(n.topic) === -1 ? "announcements" : n.topic;
      el("nt-image-url").value  = n.image_url || "";
      el("nt-image-w").value    = n.image_w == null ? "" : n.image_w;
      el("nt-image-h").value    = n.image_h == null ? "" : n.image_h;
      el("nt-event-at").value   = toLocalBox(n.event_at);
      el("nt-expires-at").value = toLocalBox(n.expires_at);
      el("nt-file").value       = "";
      el("nt-form-head").textContent = "Edit this notice";
      //  Editing a live notice does NOT take it off the website, and editing a
      //  draft does not put it on — save_notice() leaves `published` alone. Say
      //  which one they are looking at, so neither is a surprise.
      el("nt-form-lede").textContent = n.published
        ? "This one is published. Saving your changes updates it on the website; it does not take it down."
        : "This one is a draft. Saving your changes leaves it a draft.";
      el("nt-cancel").hidden = false;
      saveLabel = "Save changes";
      el("nt-save").textContent = saveLabel;
      drawPreview();
      revalidate();
      el("nt-form-head").scrollIntoView({ block: "start" });
      el("nt-title").focus();
    }

    // --- the list ------------------------------------------------------------
    function stateOf(n) {
      if (!n.published) return { klass: "is-draft", pill: "nt-draft", word: "Draft" };
      if (n.on_the_website) return { klass: "is-live", pill: "nt-live", word: "On the website" };
      return { klass: "is-gone", pill: "nt-gone", word: "Expired" };
    }

    function whenText(n) {
      var bits = [];
      if (n.event_at)   bits.push(readable(n.event_at));
      if (n.expires_at) bits.push("comes off " + readable(n.expires_at));
      if (!bits.length) bits.push("Added " + readable(n.created_at));
      return bits.join(" · ");
    }

    function draw(list) {
      var box = el("nt-list");
      if (!box) return;
      if (!list.length) {
        box.innerHTML = "<p class=\"nt-empty\">No notices yet. Write the first one below.</p>";
        return;
      }
      var now = Date.now();
      box.innerHTML = list.map(function (n) {
        var s = stateOf(n);
        //  set_notice_published() refuses to publish something whose "remove
        //  after" date has already passed — it would put the notice nowhere.
        //  Disabled rather than left to fail, so the button never lies.
        var stale = !n.published && n.expires_at && new Date(n.expires_at).getTime() <= now;
        return '<div class="nt-item ' + s.klass + '">' +
          '<div class="nt-top">' +
            '<span class="nt-chip">' + esc(TOPIC_LABEL[n.topic] || n.topic) + "</span>" +
            '<span class="nt-head">' + esc(n.title || "(no heading)") + "</span>" +
            '<span class="nt-state ' + s.pill + '">' + s.word + "</span>" +
          "</div>" +
          '<div class="nt-when">' + esc(whenText(n)) + "</div>" +
          '<div class="nt-acts">' +
            '<button type="button" class="btn btn-ghost nt-edit" data-id="' + esc(n.id) + '">Edit</button>' +
            '<button type="button" class="btn btn-ghost nt-pub" data-id="' + esc(n.id) + '"' +
              ' data-to="' + (n.published ? "0" : "1") + '"' + (stale ? " disabled" : "") + ">" +
              (n.published ? "Take off the website" : "Publish") + "</button>" +
            '<button type="button" class="btn btn-ghost nt-del" data-id="' + esc(n.id) + '">Delete</button>' +
            (stale ? '<span class="nt-when">Clear the &ldquo;remove after&rdquo; date before publishing.</span>' : "") +
          "</div>" +
        "</div>";
      }).join("");
    }

    function loadList() {
      return sb.rpc("notices_list").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        rows = res.data || [];
        draw(rows);
      });
    }

    function byId(id) {
      for (var i = 0; i < rows.length; i++) if (rows[i].id === id) return rows[i];
      return null;
    }

    // --- the picture ---------------------------------------------------------
    /*  Both sides or neither is a CHECK constraint, so the width and height
        are read here rather than hoped for. An image whose size the browser
        cannot work out is rejected before anything is uploaded — saving the
        address without the size would pass validation and then reflow the
        front page every time the poster loads. */
    function measure(file) {
      return new Promise(function (resolve, reject) {
        var url = URL.createObjectURL(file);
        var img = new Image();
        img.onload = function () {
          var size = { w: img.naturalWidth, h: img.naturalHeight };
          URL.revokeObjectURL(url);
          if (!size.w || !size.h) reject(new Error("That file doesn't open as a picture."));
          else resolve(size);
        };
        img.onerror = function () {
          URL.revokeObjectURL(url);
          reject(new Error("That file doesn't open as a picture. It may be damaged, " +
                           "or renamed from something that was never an image."));
        };
        img.src = url;
      });
    }

    function upload(file) {
      note("nt-error", ""); note("nt-ok", "");

      var ext = FILE_KINDS[file.type];
      if (!ext) {
        note("nt-error", "That file is " + (file.type || "of a kind the masjid's store " +
          "doesn't recognise") + ". Pictures have to be a JPEG, a PNG or a WebP.");
        el("nt-file").value = "";
        return;
      }
      if (file.size > MAX_BYTES) {
        note("nt-error", "That picture is " + (file.size / 1048576).toFixed(1) +
          " MB. The limit is 5 MB — a poster photographed on a phone is usually " +
          "well under it once it is exported rather than sent full size.");
        el("nt-file").value = "";
        return;
      }

      var input = el("nt-file");
      input.disabled = true;
      //  A name of its own, not the file's. Two people uploading eid.jpg a
      //  week apart would otherwise overwrite one another's poster, and the
      //  first notice would silently start showing the second one's picture.
      var name = String(Date.now()) + "-" +
                 Math.random().toString(36).slice(2, 8) + "." + ext;

      measure(file).then(function (size) {
        return sb.storage.from(BUCKET).upload(name, file, {
          contentType: file.type, upsert: false
        }).then(function (res) {
          if (res.error) throw new Error(res.error.message);
          var pub = sb.storage.from(BUCKET).getPublicUrl(name);
          var url = pub && pub.data && pub.data.publicUrl;
          if (!url) throw new Error("The picture uploaded but the masjid's store " +
                                    "gave no web address for it.");
          el("nt-image-url").value = url;
          el("nt-image-w").value   = size.w;
          el("nt-image-h").value   = size.h;
          drawPreview();
          revalidate();
          note("nt-ok", "Picture uploaded. It is on the internet now, at the address " +
                        "in the box below, whether or not you publish the notice.");
        });
      }).catch(function (e) {
        note("nt-error", e.message || String(e));
      }).finally(function () {
        input.disabled = false;
        input.value = "";
      });
    }

    // --- saving --------------------------------------------------------------
    function save() {
      if (revalidate().length) return;   // belt and braces; the button is disabled too

      var f   = readForm();
      var btn = el("nt-save");
      var p   = {
        title:      trim(f.title),
        body:       trim(f.body),
        topic:      f.topic,
        image_url:  trim(f.image_url),
        image_w:    trim(f.image_w),
        image_h:    trim(f.image_h),
        event_at:   toStamp(f.event_at),
        expires_at: toStamp(f.expires_at)
      };
      if (trim(f.id)) p.id = trim(f.id);

      busy(btn, true, saveLabel);
      note("nt-error", ""); note("nt-ok", "");

      //  The argument is named `p` — save_notice(p jsonb). Supabase sends the
      //  keys of this object as the function's named arguments, so a wrapper
      //  key of any other name is a "function does not exist" error.
      sb.rpc("save_notice", { p: p }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        var d = res.data || {};
        note("nt-ok", d.is_new
          ? "Saved as a draft. Nobody can see it yet — press Publish in the list above " +
            "when you are happy with it."
          : "Saved. The notice is unchanged in every other way, including whether it " +
            "is on the website.");
        resetForm();
        return loadList();
      }).catch(function (e) {
        note("nt-error", e.message || String(e));
      }).finally(function () {
        busy(btn, false, saveLabel);
        revalidate();
      });
    }

    // --- wiring --------------------------------------------------------------
    function wireEditor() {
      ["nt-title", "nt-body", "nt-topic", "nt-image-url",
       "nt-event-at", "nt-expires-at"].forEach(function (id) {
        var node = el(id);
        if (!node) return;
        node.addEventListener("input", revalidate);
        node.addEventListener("change", revalidate);
      });

      /*  A typed-in address and the size measured from an upload are not
          about the same picture. Leaving the old width and height behind
          would put a poster on the page in the shape of the one before it. */
      el("nt-image-url").addEventListener("input", function () {
        el("nt-image-w").value = "";
        el("nt-image-h").value = "";
        drawPreview();
      });

      el("nt-image-clear").addEventListener("click", function () {
        el("nt-image-url").value = "";
        el("nt-image-w").value   = "";
        el("nt-image-h").value   = "";
        el("nt-file").value      = "";
        drawPreview();
        revalidate();
        //  The file itself stays in the bucket. Said out loud because
        //  "removed" sounds like "deleted" and it is not the same thing.
        note("nt-ok", "Taken off this notice. The file itself is still in the " +
                      "masjid's store at the address it had.");
      });

      el("nt-file").addEventListener("change", function () {
        var file = this.files && this.files[0];
        if (file) upload(file);
      });

      el("nt-save").addEventListener("click", save);
      el("nt-cancel").addEventListener("click", function () {
        resetForm();
        note("nt-error", ""); note("nt-ok", "");
      });

      resetForm();
      return true;
    }

    function publish(id, to) {
      note("nt-error", ""); note("nt-ok", "");
      return sb.rpc("set_notice_published", { p_id: id, p_published: to })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          note("nt-ok", to
            ? "That notice is on the website now."
            : "That notice has been taken off the website. It is still here as a draft.");
          return loadList();
        })
        .catch(function (e) { note("nt-error", e.message || String(e)); });
    }

    function remove(id, title) {
      //  Deleting is the one thing on this screen nothing undoes, so it names
      //  the notice back. Taking it off the website is what somebody usually
      //  means and is offered on the same row.
      if (!window.confirm(
            "Delete “" + (title || "this notice") + "”?\n\n" +
            "This cannot be undone. If you only want it off the website, " +
            "use “Take off the website” instead.")) return;
      note("nt-error", ""); note("nt-ok", "");
      return sb.rpc("delete_notice", { p_id: id })
        .then(function (res) {
          if (res.error) throw new Error(res.error.message);
          //  If the deleted one was open in the form, the form is now editing
          //  a row that no longer exists and Save would fail with
          //  no_data_found. Put it back to "Add a notice".
          if (trim(el("nt-id").value) === id) resetForm();
          note("nt-ok", "Deleted.");
          return loadList();
        })
        .catch(function (e) { note("nt-error", e.message || String(e)); });
    }

    function mount(identity) {
      wireEditor();

      el("nt-list").addEventListener("click", function (ev) {
        var btn = ev.target.closest("button[data-id]");
        if (!btn || btn.disabled) return;
        var id = btn.getAttribute("data-id");
        var n  = byId(id);

        if (btn.classList.contains("nt-edit")) {
          if (n) fillForm(n);
          return;
        }
        if (btn.classList.contains("nt-pub")) {
          var to = btn.getAttribute("data-to") === "1";
          if (!to && !window.confirm(
                "Take “" + ((n && n.title) || "this notice") + "” off the website?\n\n" +
                "Visitors stop seeing it straight away. It stays here as a draft.")) return;
          btn.disabled = true;
          publish(id, to);
          return;
        }
        if (btn.classList.contains("nt-del")) {
          remove(id, n && n.title);
        }
      });

      return loadList().catch(function (e) {
        note("nt-error", "Couldn't read the notices: " + (e.message || e));
      });
    }

    return { mount: mount, _check: check, _wire: wireEditor };
  })();

  /*  THE VALIDATOR, REACHABLE FROM A TEST.

      Everything on this page lives inside one closure, which is right — but it
      also means the one piece genuinely worth testing cannot be reached. This
      is a PURE FUNCTION: no session, no data, no network, nothing that writes.
      What it discloses is the list of rules already printed on the screen
      above in plain English, and the real enforcement is check_notice() and
      seven CHECK constraints in Postgres, which this cannot reach or relax.

      It is exposed so a test can hold it against 041 rule by rule. That
      comparison is the whole point: the two disagreeing is the fault 041 was
      written to fix, and a test is the only thing that will notice it
      happening again. */
  /*  EXPOSED FOR THE TESTS.

      check() is pure — no DOM, no network, no state — and it is the half of
      this screen worth testing, because it has to agree with check_notice()
      in 041 exactly. Where the two disagree, a volunteer gets told a notice
      is fine and then gets a raw Postgres constraint name; that has already
      happened once on this project, which is why 041 exists.

      wire() is not pure, and it is here for a reason learned the hard way on
      times/. The rule "nothing is saveable until the form is valid" lived
      inside mount(), which runs only after a real sign-in — so no test could
      ever reach it, and the Save button is disabled in the markup as well, so
      it read as disabled whether the rule was there or had been deleted. The
      check passed with the code removed. Calling wire() on a page nobody is
      signed in to wires a Save button whose click calls save_notice(), which
      the database refuses to anybody who is not a verified admin with
      two-step. The check is in the database, not in this file. */
  window.__NOTICE_FORM = { check: notices._check, wire: notices._wire };

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'notices',
        title:   'Notices',
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
    try { notices.mount(identity); } catch (e) {
      if (window.console) console.warn("notices panel unavailable:", e);
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
