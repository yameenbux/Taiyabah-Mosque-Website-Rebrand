/* ===========================================================================
   THE SCHOOL PROFILE — who the masjid is, and the images it signs its post with.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   18 September 2026

   TWO JOBS ON ONE SCREEN, AND THEY BELONG TOGETHER.

   The masjid's address, telephone number and charity number are hard-coded in
   TEN separate pages of this website today. Change the office number and
   somebody has to find all ten, and the one they miss is on the page a parent
   is reading. This screen is where those details will come from.

   The second job is the one that was asked for: "users should get the ability
   to add images like this does for emails etc." A masjid sends letters,
   receipts, booking confirmations and Gift Aid declarations, and every one of
   them should carry the same banner — one the masjid can change itself, not
   one baked into a template by whoever wrote it.

   THE UPLOAD IS TWO STEPS AND THE ORDER MATTERS. Bytes to Storage first, then
   record_masjid_image() writes the row. A row written first would point at a
   file that might never arrive, and a broken image in a letter that has
   already gone out cannot be recalled; an orphaned file in a bucket is just a
   file nobody references.

   ONE IMAGE OF EACH KIND IS CURRENT, AND POSTGRES ENFORCES IT rather than this
   screen. There is a partial unique index in 056 and the writer stands the old
   one down in the same transaction. "Set to current" has to mean one thing.

   ADMINISTRATORS ONLY, and it is the database that says so — every function
   this screen calls asks verified_admin(). Hiding the panel from a madrasah
   account is a courtesy so they do not meet a wall of refusals.
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
     THE PROFILE, AND THE IMAGES
     ======================================================================= */
  var profile = (function () {

    /*  THE THREE KINDS, AND WHAT EACH IS ACTUALLY FOR.

        Named here rather than left as bare strings so that the words on the
        screen and the values in the database cannot drift apart — the check
        constraint in 056 allows exactly these three and nothing else. */
    var KINDS = [
      { k: "email_banner", name: "Email banner",
        why: "Goes across the top of every email the masjid sends — booking " +
             "confirmations, receipts, Gift Aid declarations. Wide and short. " +
             "About 1200 pixels across works everywhere; it is shown at half " +
             "that, which is what keeps it sharp on a phone.",
        alt: "Taiyabah Masjid" },
      { k: "letterhead", name: "Letterhead",
        why: "The top of a printed letter. Usually the same artwork as the " +
             "banner with the address underneath.",
        alt: "Taiyabah Masjid letterhead" },
      { k: "logo", name: "Logo",
        why: "The mark on its own, with nothing beside it. Used small — on a " +
             "receipt, a ticket, or beside the masjid's name.",
        alt: "Taiyabah Masjid" }
    ];

    /*  WHAT WILL ACTUALLY BE ACCEPTED, and it is checked twice on purpose.

        Here, so somebody dragging in a 40MB camera JPEG is told before they
        wait for an upload that will fail. And in Postgres and Storage, because
        a check in a browser is a courtesy to the person using it and not a
        control over what arrives.

        SVG IS DELIBERATELY NOT ON THIS LIST. An SVG is a document that can
        carry script, and this bucket is public and served from the same
        origin family as the site. A masjid logo is not worth that. */
    var OK_TYPES = ["image/png", "image/jpeg", "image/webp", "image/gif"];
    var MAX_BYTES = 3 * 1024 * 1024;

    var DATA = null;
    var chosen = {};        // kind -> File
    var wired = false;
    var want = null;        // what the confirm strip is asking

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function trim(v) { return String(v == null ? "" : v).trim(); }

    function note(id, msg) {
      var box = el(id);
      if (!box) return;
      if (!msg) { box.hidden = true; box.textContent = ""; return; }
      box.textContent = msg;
      box.hidden = false;
    }

    function publicUrl(path) {
      //  The bucket is public because a mail client fetching a banner is
      //  signed in to nothing. This is the same URL the email will use, which
      //  is the point of previewing it here rather than from a blob.
      return apiUrl + "/storage/v1/object/public/brand/" + path;
    }

    function when(iso) {
      if (!iso) return "";
      var d = new Date(iso);
      return d.toLocaleDateString("en-GB",
        { day: "numeric", month: "short", year: "numeric" });
    }

    // ---- drawing ------------------------------------------------------------
    function imagesOf(kind) {
      return ((DATA && DATA.images) || []).filter(function (i) { return i.kind === kind; });
    }

    function kindHtml(def) {
      var all = imagesOf(def.k);
      var now = all.filter(function (i) { return i.is_current; })[0] || null;
      var old = all.filter(function (i) { return !i.is_current; });

      return '<section class="pf-kind">' +
        "<h4>" + esc(def.name) +
          (now ? '<span class="pf-now">in use</span>' : "") + "</h4>" +
        "<p>" + esc(def.why) + "</p>" +

        (now
          ? '<div class="pf-shot"><img src="' + esc(publicUrl(now.path)) +
            '" alt="' + esc(now.alt_text || def.alt) + '"></div>'
          : '<div class="pf-shot empty">Nothing here yet. Whatever is uploaded and ' +
            'set as current is what the masjid&rsquo;s post will carry.</div>') +

        '<div class="pf-pick">' +
          '<input type="file" class="pf-file" id="pf-file-' + esc(def.k) + '"' +
            ' accept="image/png,image/jpeg,image/webp,image/gif" data-kind="' + esc(def.k) + '">' +
          '<label class="pf-asbtn" for="pf-file-' + esc(def.k) + '">Choose a picture</label>' +
          '<button type="button" class="btn btn-gold pf-up" data-kind="' + esc(def.k) +
            '" disabled>Upload and use this</button>' +
          '<span class="pf-chosen" id="pf-chosen-' + esc(def.k) + '">No file chosen.</span>' +
        "</div>" +

        (old.length
          ? '<div class="pf-old">' + old.map(function (i) {
              return '<div class="pf-old-one">' +
                '<img src="' + esc(publicUrl(i.path)) + '" alt="">' +
                '<span class="pf-old-when">Added ' + esc(when(i.uploaded_at)) + "</span>" +
                '<span class="pf-old-acts">' +
                  '<button type="button" class="btn btn-ghost pf-use" data-id="' + esc(i.id) +
                    '">Use this</button>' +
                  '<button type="button" class="btn btn-ghost pf-del" data-id="' + esc(i.id) +
                    '">Remove</button>' +
                "</span></div>";
            }).join("") + "</div>"
          : "") +
      "</section>";
    }

    function draw() {
      var set = function (id, v) { var n = el(id); if (n) n.value = v == null ? "" : v; };
      set("pf-legal",    DATA && DATA.legal_name);
      set("pf-short",    DATA && DATA.short_name);
      set("pf-charity",  DATA && DATA.charity_no);
      set("pf-address",  DATA && DATA.address);
      set("pf-postcode", DATA && DATA.postcode);
      set("pf-phone",    DATA && DATA.phone);
      set("pf-email",    DATA && DATA.email);
      set("pf-website",  DATA && DATA.website);

      var host = el("pf-kinds");
      if (host) host.innerHTML = KINDS.map(kindHtml).join("");
    }

    // ---- reading ------------------------------------------------------------
    function load() {
      return sb.rpc("masjid_profile_get").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        DATA = res.data || {};
        draw();
      });
    }

    // ---- the details --------------------------------------------------------
    function readForm() {
      var v = function (id) { var n = el(id); return n ? trim(n.value) : ""; };
      return {
        legal_name: v("pf-legal"), short_name: v("pf-short"),
        charity_no: v("pf-charity"), address: v("pf-address"),
        postcode: v("pf-postcode"), phone: v("pf-phone"),
        email: v("pf-email"), website: v("pf-website")
      };
    }

    function hideConfirm() {
      var b = el("pf-confirm");
      if (b) { b.hidden = true; b.classList.remove("is-danger"); }
      want = null;
    }

    function askSave() {
      want = { what: "profile", p: readForm() };
      el("pf-confirm-q").textContent =
        "Save these details? They are what the masjid's letters and emails will print.";
      el("pf-confirm").hidden = false;
      el("pf-confirm-yes").focus();
    }

    function saveProfile(p) {
      var btn = el("pf-save");
      busy(btn, true, "Save these details");
      note("pf-error", ""); note("pf-ok", "");
      hideConfirm();
      sb.rpc("save_masjid_profile", { p: p }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        return load();
      }).then(function () {
        note("pf-ok", "Saved.");
      }).catch(function (e) {
        note("pf-error", "Nothing was saved — " + ((e && e.message) || String(e)));
      }).finally(function () { busy(btn, false, "Save these details"); });
    }

    // ---- the images ---------------------------------------------------------
    /*  THE UPLOAD IS TWO STEPS AND THEY ARE NOT INTERCHANGEABLE.

        The bytes go to Storage first, then record_masjid_image() writes the
        row. IN THAT ORDER, because a row written first would point at a file
        that may never arrive — and a broken picture in a letter that has
        already gone out is not recoverable, while an orphaned file in a
        bucket is just a file nobody references.

        The path carries a timestamp rather than replacing a fixed name. Mail
        clients and CDNs cache aggressively by URL; overwriting brand/banner.png
        would leave the old artwork showing in half the world's inboxes with
        nothing to clear it.                                                  */
    function upload(kind, file) {
      var def = null;
      KINDS.forEach(function (d) { if (d.k === kind) def = d; });

      if (OK_TYPES.indexOf(file.type) === -1) {
        note("pf-error", "That is a " + (file.type || "kind of file") +
          ". It needs to be a PNG, JPEG, WebP or GIF.");
        return;
      }
      if (file.size > MAX_BYTES) {
        note("pf-error", "That picture is " + Math.round(file.size / 1024 / 1024 * 10) / 10 +
          "MB, and the limit is 3MB. A banner should be well under that — if it is " +
          "a photograph straight off a camera, it is far larger than it needs to be.");
        return;
      }

      var ext = (file.name.split(".").pop() || "png").toLowerCase().replace(/[^a-z0-9]/g, "");
      var path = kind + "/" + Date.now() + "." + (ext || "png");

      note("pf-error", ""); note("pf-ok", "");
      var btn = document.querySelector('.pf-up[data-kind="' + kind + '"]');
      busy(btn, true, "Upload and use this");

      sb.storage.from("brand").upload(path, file, {
        contentType: file.type, upsert: false
      }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        return sb.rpc("record_masjid_image", { p: {
          kind: kind, storage_path: path, bytes: file.size,
          content_type: file.type, alt_text: def ? def.alt : "",
          is_current: true
        }});
      }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        delete chosen[kind];
        return load();
      }).then(function () {
        note("pf-ok", "That is now the masjid's " + (def ? def.name.toLowerCase() : kind) + ".");
      }).catch(function (e) {
        note("pf-error", "The picture was not saved — " + ((e && e.message) || String(e)));
      }).finally(function () { busy(btn, false, "Upload and use this"); });
    }

    function useThis(id) {
      note("pf-error", ""); note("pf-ok", "");
      sb.rpc("set_current_masjid_image", { p_id: id }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        return load();
      }).then(function () {
        note("pf-ok", "Changed. The masjid's post will use that one from now on.");
      }).catch(function (e) {
        note("pf-error", "Nothing changed — " + ((e && e.message) || String(e)));
      });
    }

    function removeImage(id) {
      note("pf-error", ""); note("pf-ok", "");
      hideConfirm();
      sb.rpc("delete_masjid_image", { p_id: id }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        return load();
      }).then(function () {
        note("pf-ok", "Removed.");
      }).catch(function (e) {
        note("pf-error", "Nothing was removed — " + ((e && e.message) || String(e)));
      });
    }

    // ---- wiring -------------------------------------------------------------
    function wire() {
      if (wired) return;
      wired = true;

      //  One listener over the whole block. Every control inside it is redrawn
      //  on each load, so per-element listeners would not survive the first
      //  upload.
      var host = el("pf-kinds");
      if (host) {
        host.addEventListener("change", function (ev) {
          var inp = ev.target;
          if (!inp || !inp.classList || !inp.classList.contains("pf-file")) return;
          var kind = inp.getAttribute("data-kind");
          var f = inp.files && inp.files[0];
          chosen[kind] = f || null;
          var say = el("pf-chosen-" + kind);
          if (say) {
            say.textContent = f
              ? f.name + " — " + Math.max(1, Math.round(f.size / 1024)) + "KB"
              : "No file chosen.";
          }
          var btn = host.querySelector('.pf-up[data-kind="' + kind + '"]');
          if (btn) btn.disabled = !f;
        });

        host.addEventListener("click", function (ev) {
          var b = ev.target.closest && ev.target.closest("button");
          if (!b) return;
          if (b.classList.contains("pf-up")) {
            var kind = b.getAttribute("data-kind");
            if (chosen[kind]) upload(kind, chosen[kind]);
            return;
          }
          if (b.classList.contains("pf-use")) { useThis(b.getAttribute("data-id")); return; }
          if (b.classList.contains("pf-del")) {
            want = { what: "delete", id: b.getAttribute("data-id") };
            var box = el("pf-confirm");
            el("pf-confirm-q").textContent =
              "Remove this picture for good? Anything already sent that points at it " +
              "will show a broken image.";
            box.classList.add("is-danger");
            box.hidden = false;
            box.scrollIntoView({ block: "nearest" });
            el("pf-confirm-yes").focus();
          }
        });
      }

      var save = el("pf-save");
      if (save) save.addEventListener("click", askSave);

      var yes = el("pf-confirm-yes");
      if (yes) yes.addEventListener("click", function () {
        var w = want;
        if (!w) return;
        if (w.what === "profile") saveProfile(w.p); else removeImage(w.id);
      });
      var no = el("pf-confirm-no");
      if (no) no.addEventListener("click", hideConfirm);
    }

    function mount(identity) {
      var panel = el("pf-panel");
      var noaccess = el("app-noaccess");
      if (!panel) return;
      if ((identity.roles || []).indexOf("admin") === -1) {
        panel.hidden = true;
        if (noaccess) noaccess.hidden = false;
        return;
      }
      if (noaccess) noaccess.hidden = true;
      panel.hidden = false;
      wire();
      load().catch(function (e) {
        note("pf-error", "The profile could not be read — " + ((e && e.message) || String(e)));
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
        current:  'md-profile',
        title:    'School profile',
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
    try { profile.mount(identity); } catch (e) {
      if (window.console) console.warn("profile unavailable:", e);
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
