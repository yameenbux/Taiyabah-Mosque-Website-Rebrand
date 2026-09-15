/* ===========================================================================
   Taiyabah Masjid — sending a notification to the masjid's phone app
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   The app already has a screen that sends notifications. It is a single page
   behind ONE SHARED PASSWORD, and the token it hands back has nothing in it
   but an expiry — no name, no account, nothing that says who pressed the
   button. Two things follow from that, and both of them are why this file was
   written:

     * NOTHING RECORDED WHO SENT WHAT. A push to every phone in the
       congregation cannot be recalled, and it was the only action on this
       whole system with no record of who took it. A hall booking, a Gift Aid
       claim, a role change — every one of those writes a row naming a person.
       The thing that reaches people in their pockets at six in the morning
       left nothing at all.

     * THE HISTORY LIVED IN ONE BROWSER. "Recently sent" was kept in that one
       browser's own storage, on that one computer. A trustee sends a janāzah
       notice at eleven at night; another opens the screen five minutes later,
       is told "nothing sent yet", and sends it again. Two notifications, one
       death, at midnight. That is not a hypothetical — it is what a
       per-browser list shared between volunteers does.

   So 051 gave the masjid a table with the sender's own identity on every row,
   and supabase/functions/app-notify holds the app's password as a secret
   nobody on the committee ever sees. THIS SCREEN IS THE OTHER HALF: a
   committee member signs in with their own account and their own
   authenticator, and what goes out is recorded against their name.

   THE SHAPE OF THIS SCREEN, AND WHY
   ---------------------------------
     * EVERY SEND IS CONFIRMED, NOT JUST A JANĀZAH. There is nothing else in
       this portal that cannot be undone. A booking can be re-confirmed, a
       notice can be taken down, a role can be given back. A notification is
       on a thousand phones a second after the button is pressed and there is
       no way to reach it. So the confirmation shows the audience, the heading
       and the message back, and the wording is heavier for a janāzah because
       the consequence is.

     * THE CONFIRMATION IS A PANEL ON THE PAGE, not one of the browser's own
       dialogs. A browser dialog cannot show the message back, cannot say
       which audience this is, and on a phone it is a grey box people dismiss
       without reading. Those dialogs are not used anywhere in this portal.

     * "SENT" MEANS SOMEBODY RECEIVED IT. The Worker answers 200 with
       sent:{sent:false} when the notice was saved but OneSignal refused it,
       and app-notify passes that through as ok:false. A screen that reported
       that as "sent" would be lying about the one thing it exists to be
       trusted about. Read what happens to `ok` below: a saved notice that
       nobody received is an ERROR here, in red, saying so.

     * THE LIST IS THE POINT. It is read from the database, so every trustee
       sees every send, whichever computer they are on.

   None of this is a security control. It is JavaScript in a browser with the
   publishable key beside it. app_notification_start() runs verified_admin()
   in Postgres, and refuses anybody who is not an administrator who has
   completed two-step — and it runs BEFORE anything is sent. What is here is
   so that a committee member is told, in plain English, what is about to
   happen and what did.
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
     SENDING MODULE. Everything on this screen, kept in one place so that if
     it throws, the sign-in shell around it survives — see renderApp. */
  var sending = (function () {
    "use strict";

    /*  THE FIVE AUDIENCES ARE THE FIVE THE APP HAS SWITCHES FOR.

        Not six, and not four. These are TOPICS in
        supabase/functions/app-notify/index.ts, which are in turn the Worker's
        own list, and they are also the five in the check constraint added by
        051. A sixth offered here is refused by Postgres before anything is
        sent, and one missing here is a switch people have turned on in the app
        that nobody at the masjid can reach.

        THEY ARE NOT THE NOTICES TOPICS, and the difference is real:
        `jamaah` is a push audience with no notice behind it, and `ramadan`
        and `madrasah` are notice topics the app has no switch for. Two
        overlapping lists, written down as two, because pretending they are
        one is how something gets filed under a heading nobody subscribed to. */
    var TOPICS = ["janazah", "jamaah", "announcements", "events", "kahf"];
    var TOPIC_LABEL = {
      janazah:       "Janāzah",
      jamaah:        "Jamāʿah reminders",
      announcements: "Announcements",
      events:        "Events & talks",
      kahf:          "Sūrah al-Kahf"
    };

    var TITLE_MAX = 70;     // app_notification_has_a_heading, and the Worker
    var BODY_MAX  = 2000;   // what /api/notice will take
    var PUSH_MAX  = 220;    // what /api/send will take, with nothing kept

    /*  Five megabytes, checked here as well as at the far end, because a
        person who has just waited ninety seconds for a twelve-megabyte
        photograph to be read off their phone and refused has been failed by
        this screen and not by the app. */
    var MAX_BYTES  = 5 * 1024 * 1024;
    var FILE_KINDS = { "image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WebP" };

    //  The chosen poster, as a data URL with its real pixel size beside it.
    //  Held here rather than in a hidden input: a 4 MB data URL in the DOM is
    //  a 4 MB string the browser re-reads on every keystroke.
    var poster = null;      // { data, w, h, bytes }
    var rows   = [];        // the last list read
    var wired  = false;     // wire() is safe to call twice; binding twice is not

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

    /*  Complaints and confirmations appear above a form that can be two
        screens long, so on a phone they are announced somewhere nobody is
        looking. Bring whichever one has just been written into view. */
    function bringIntoView(id) {
      var n = el(id);
      if (n && !n.hidden && n.scrollIntoView) {
        n.scrollIntoView({ block: "nearest" });
      }
    }

    /* ---------------------------------------------------------------- dates
       A datetime-local box hands back "2026-12-01T18:00" with no timezone on
       it. Sent verbatim, Postgres casts it using the SERVER's timezone, which
       is UTC — so an event set for 6pm in December is an hour out in summer
       and nobody would ever work out why. It goes through the browser's own
       clock instead. */
    function toStamp(v) {
      v = trim(v);
      if (!v) return "";
      var d = new Date(v);
      return isNaN(d.getTime()) ? "" : d.toISOString();
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

    /*  Kilobytes below a megabyte, because "0.0 MB" beside a poster somebody
        has just chosen reads as "nothing was picked up". */
    function fileSize(bytes) {
      return bytes < 1048576
        ? Math.max(1, Math.round(bytes / 1024)) + " KB"
        : (bytes / 1048576).toFixed(1) + " MB";
    }

    /*  A sentence, from whatever came back. The far end's reasons are written
        as fragments — "the notice was saved but the notification did not go
        out" — so they need a stop after them or they run into the next
        sentence and neither can be read. */
    function asSentence(v) {
      var s = trim(v);
      if (!s) return "";
      return /[.!?]$/.test(s) ? s : s + ".";
    }

    // --- reading the form -----------------------------------------------------
    function chosenTopic() {
      var picked = document.querySelector('input[name="ap-topic"]:checked');
      var value  = picked ? picked.value : "";
      return TOPICS.indexOf(value) === -1 ? "announcements" : value;
    }

    function keepOn() {
      var box = el("ap-keep");
      return !!(box && box.checked);
    }

    /*  THE MESSAGE LIMIT DEPENDS ON THE TICK-BOX, and this is the one thing on
        this screen a person would never guess.

        A kept notice goes to /api/notice, which writes a row the app's Notices
        tab can show and takes two thousand characters. An unkept one goes to
        /api/send, which leaves nothing behind and takes two hundred and
        twenty. Both limits are the far end's, not ours — a message over the
        limit is refused there, after the person has pressed a button that
        cannot be taken back if it had worked. So it is counted down here,
        with the reason on the counter rather than in a comment. */
    function bodyLimit() { return keepOn() ? BODY_MAX : PUSH_MAX; }

    function countdown(boxId, value, limit) {
      var box = el(boxId);
      if (!box) return;
      var left = limit - trim(value).length;
      box.textContent = left >= 0
        ? left + " characters left."
        : (-left) + " characters too many — the limit is " + limit + ".";
      box.classList.toggle("is-over", left < 0);
    }

    /*  The message counts down to a number that MOVES, so it has to say which
        number it is counting to and why. "30 characters too many" against a
        limit somebody has never been told about is a screen arguing with
        them. */
    function messageCount() {
      var box   = el("ap-body-count");
      if (!box) return;
      var value = trim(el("ap-body").value);
      var limit = bodyLimit();
      var left  = limit - value.length;
      var kept  = keepOn();

      if (left >= 0) {
        box.textContent = left + " characters left." +
          (kept ? "" : " Nothing is being kept, so the limit is " + PUSH_MAX + ".");
      } else {
        box.textContent = (-left) + " characters too many — the limit is " +
          limit + "." +
          (kept ? ""
                : " Tick “keep this on the app's Notices tab” above and you have " +
                  BODY_MAX + ".");
      }
      box.classList.toggle("is-over", left < 0);
    }

    function drawLock() {
      var title = trim(el("ap-title").value);
      var body  = trim(el("ap-body").value);
      el("ap-lock-title").textContent = title || "Your heading goes here";
      el("ap-lock-body").textContent  = body  || "And the first lines of your message.";
    }

    /*  Re-run after every keystroke and every tick. The Send button is the only
        way to reach the confirmation, and the confirmation is the only way to
        reach the app, so this is where "you cannot send an empty notification"
        actually lives — the `disabled` in the markup only covers the first
        paint. */
    function refresh() {
      var title = trim(el("ap-title").value);
      var body  = trim(el("ap-body").value);

      countdown("ap-title-count", title, TITLE_MAX);
      messageCount();
      drawLock();

      //  A heading with no message is a notification that says nothing when
      //  somebody opens it, and a message with no heading has nothing to show
      //  on a locked phone. The far end refuses both.
      el("ap-send").disabled = !(title && body);
    }

    // --- the poster -----------------------------------------------------------
    function showPoster() {
      var wrap = el("ap-pic-preview");
      var keep = el("ap-keep");
      if (!poster) {
        wrap.hidden = true;
        el("ap-thumb").removeAttribute("src");
        el("ap-size").textContent = "";
        el("ap-pic-forced").hidden = true;
        keep.disabled = false;
        return;
      }
      el("ap-thumb").src = poster.data;
      el("ap-size").textContent =
        poster.w + " × " + poster.h + " pixels · " + fileSize(poster.bytes);
      wrap.hidden = false;

      /*  A POSTER FORCES "KEEP AS A NOTICE" ON, and it is said out loud rather
          than done quietly. /api/send has nowhere to put a picture; only a
          notice has. Silently ticking a box somebody had deliberately unticked
          is how a screen loses somebody's trust — so it is ticked, held, and
          the reason is printed underneath. */
      keep.checked  = true;
      keep.disabled = true;
      el("ap-pic-forced").hidden = false;
    }

    function clearPoster() {
      poster = null;
      el("ap-file").value = "";
      showPoster();
      refresh();
    }

    function choosePoster(file) {
      note("ap-error", ""); note("ap-ok", "");

      if (!FILE_KINDS[file.type]) {
        note("ap-error", "That file is " + (file.type || "of a kind this page does " +
          "not recognise") + ". A poster has to be a JPEG, a PNG or a WebP. " +
          "If it is a PDF, open it and export one page as a picture.");
        el("ap-file").value = "";
        return;
      }
      if (file.size > MAX_BYTES) {
        note("ap-error", "That poster is " + fileSize(file.size) + ". The limit " +
          "is 5 MB — a poster photographed on a phone is usually well under it " +
          "once it is exported rather than sent at full size. Choose a smaller " +
          "one, or send the notification without a picture.");
        el("ap-file").value = "";
        return;
      }

      /*  Read as a data URL, because that is what app-notify passes on: the
          picture travels inside the message rather than being uploaded
          somewhere first, so there is no half-state where a file is public on
          the internet and the notification never went. */
      var reader = new FileReader();
      reader.onerror = function () {
        note("ap-error", "That file could not be read off this computer. " +
          "If it is on a memory stick or a network drive, copy it onto the " +
          "desktop first and try again.");
        clearPoster();
      };
      reader.onload = function () {
        var data = String(reader.result || "");
        /*  The real pixel size is measured, not guessed. The app needs both
            sides to leave room for the picture before it has loaded; with
            only one, the notice jumps as it appears. */
        var img = new Image();
        img.onload = function () {
          if (!img.naturalWidth || !img.naturalHeight) {
            note("ap-error", "That file doesn't open as a picture.");
            clearPoster();
            return;
          }
          poster = { data: data, w: img.naturalWidth, h: img.naturalHeight,
                     bytes: file.size };
          showPoster();
          refresh();
          closeConfirm(true);
        };
        img.onerror = function () {
          note("ap-error", "That file doesn't open as a picture. It may be " +
            "damaged, or renamed from something that was never an image.");
          clearPoster();
        };
        img.src = data;
      };
      reader.readAsDataURL(file);
    }

    // --- the confirmation -----------------------------------------------------
    /*  The heavier wording for a janāzah is not decoration. It is the only
        audience that reaches nearly every phone whatever the hour, it is the
        one people trust without reading twice, and a mistake in it — the wrong
        name, the wrong time, the wrong masjid — cannot be corrected by
        anything except a second notification saying so. */
    var WORDS = {
      normal: "This is about to go to every phone that has this kind of alert " +
              "switched on. It cannot be called back, edited or deleted once " +
              "it has gone, and this is the last point at which nothing has " +
              "happened.",
      janazah: "This is a janāzah announcement. It will reach nearly every " +
               "phone with the app, at whatever hour it is now, and people act " +
               "on it — they will set off for the masjid. Read the name, the " +
               "time and the place once more. Nothing can call it back, and a " +
               "correction is a second notification to everybody who had the " +
               "first."
    };

    function openConfirm() {
      var topic = chosenTopic();
      var title = trim(el("ap-title").value);
      var body  = trim(el("ap-body").value);

      if (!title || !body) return;            // belt and braces; Send is disabled too

      //  Refused here rather than at the far end, where the person has already
      //  committed to something irreversible and is then told it did not work.
      if (body.length > bodyLimit()) {
        note("ap-error", "That message is " + body.length + " characters, and " +
          (keepOn()
            ? "the limit is " + BODY_MAX + "."
            : "without keeping it on the Notices tab the limit is " + PUSH_MAX +
              ". Either shorten it, or tick “keep this on the app's Notices " +
              "tab” — a kept notice can be up to " + BODY_MAX + "."));
        bringIntoView("ap-error");
        return;
      }

      note("ap-error", ""); note("ap-ok", "");
      el("ap-changed").hidden = true;

      var panel = el("ap-confirm");
      panel.classList.toggle("is-grave", topic === "janazah");
      el("ap-confirm-h").textContent = topic === "janazah"
        ? "Send this janāzah announcement now?"
        : "Send this now?";
      el("ap-confirm-p").textContent = topic === "janazah" ? WORDS.janazah : WORDS.normal;

      el("ap-confirm-aud").textContent   = TOPIC_LABEL[topic] || topic;
      el("ap-confirm-title").textContent = title;
      el("ap-confirm-body").textContent  = body;
      el("ap-confirm-keep").textContent  = keepOn()
        ? "It stays on the app's Notices tab after the notification is swiped away."
        : "Nothing is kept. Once somebody swipes the notification away, it is gone.";

      panel.hidden = false;
      panel.scrollIntoView({ block: "nearest" });

      /*  Focus goes to "Go back", not to "Send it". Somebody who reached this
          panel with the keyboard should not be one press of Enter away from a
          thousand phones. */
      el("ap-back").focus();
    }

    /*  `quietly` is for the case where the person edited the form while the
        panel was open. The panel showed one message and the boxes now hold
        another, so it must close — but closing something a person did not
        close, without a word, reads as the screen breaking. */
    function closeConfirm(quietly) {
      var panel = el("ap-confirm");
      if (panel.hidden) return;
      panel.hidden = true;
      el("ap-changed").hidden = !quietly;
    }

    // --- sending --------------------------------------------------------------
    function clearAfterSend() {
      /*  The heading and the message go, because leaving them there is how the
          same notification gets sent twice by somebody who came back to the
          screen and could not tell whether it had worked.

          The poster and the date go WITH them. A poster still attached is the
          most dangerous thing that could be left on this form: the next
          notification, about something else entirely, would carry a picture
          nobody chose for it. The audience is left alone — it is a deliberate
          choice, it is shown again in the confirmation, and there is no harm
          in it being remembered. */
      el("ap-title").value    = "";
      el("ap-body").value     = "";
      el("ap-event-at").value = "";
      clearPoster();
      refresh();
    }

    function send() {
      var topic = chosenTopic();
      var title = trim(el("ap-title").value);
      var body  = trim(el("ap-body").value);
      var btn   = el("ap-go");

      busy(btn, true, "Send it");
      note("ap-error", ""); note("ap-ok", "");

      /*  The caller's own token, deliberately. app-notify writes the record
          with it BEFORE it sends anything, so the row names the person who
          pressed the button and nothing downstream can change that. It is also
          the permission check — a caller who is not a two-step administrator
          is refused there and nothing goes out. */
      return sb.auth.getSession().then(function (s) {
        var token = s.data && s.data.session && s.data.session.access_token;
        if (!token) throw new Error("Your session has expired, so nothing was " +
                                    "sent. Sign in again and write it once more.");
        return fetch(apiUrl + "/functions/v1/app-notify", {
          method: "POST",
          headers: { "content-type": "application/json",
                     apikey: cfg.SUPABASE_ANON_KEY,
                     Authorization: "Bearer " + token },
          body: JSON.stringify({
            topic:          topic,
            title:          title,
            body:           body,
            keep_as_notice: keepOn(),
            image:          poster ? poster.data : null,
            image_w:        poster ? poster.w : null,
            image_h:        poster ? poster.h : null,
            event_at:       toStamp(el("ap-event-at").value) || null
          })
        });
      }).then(function (r) {
        return r.text().then(function (t) {
          var out;
          try { out = JSON.parse(t); } catch (e) { out = { error: t.slice(0, 300) }; }
          return { status: r.status, out: out || {} };
        });
      }).then(function (res) {
        var out = res.out;

        /*  ok:false IS NOT A SENT NOTIFICATION, whatever else came back with
            it. The Worker answers 200 with sent:{sent:false} when the notice
            was saved and OneSignal refused it, and app-notify reports that
            faithfully as ok:false. Saying "sent" here about a saved notice
            nobody received would be the exact failure this screen exists to
            end — and the person would find out a day later, from somebody
            asking why they were not told. */
        if (out.ok !== true) {
          note("ap-error",
            "Nothing was sent. Nobody's phone has received anything. The reason " +
            "given was: " +
            (asSentence(out.error) || "none, which usually means the app sender " +
                                      "could not be reached at all.") +
            (out.id ? " There is a row in the list below showing the attempt." : "") +
            " Read that list before you try again, in case an earlier attempt " +
            "did go out.");
          bringIntoView("ap-error");
          //  The list is reloaded even on a failure: app_notification_start()
          //  writes its row before anything is sent, so the attempt is there.
          return loadList();
        }

        var reached = typeof out.recipients === "number"
          ? "It reached " + out.recipients + " phone" + (out.recipients === 1 ? "" : "s") + "."
          : "The app did not say how many phones it reached.";
        var kept = out.kept_as_notice
          ? " It is on the app's Notices tab as well, so somebody who swipes it away can still find it."
          : " Nothing was kept — once it is swiped away it is gone.";
        /*  `recorded` false means the send HAPPENED and the record of it did
            not. Said plainly, because the list below is the thing everybody is
            about to trust, and a send missing from it is how the same
            notification goes out twice. */
        var missing = out.recorded === false
          ? " It went out, but it could not be written into the list below — so " +
            "the list is not complete, and somebody should be told before " +
            "anything else is sent."
          : "";

        note("ap-ok", "Sent to " + (out.topic_label || TOPIC_LABEL[topic] || topic) +
                      ". " + reached + kept + missing);
        bringIntoView("ap-ok");
        clearAfterSend();
        return loadList();
      }).catch(function (e) {
        /*  A network failure here is genuinely ambiguous: the request may have
            arrived and the answer may have been lost on the way back. Telling
            somebody "it failed" would invite them to send a janāzah notice to
            a congregation that already has it, so this says what is actually
            known. */
        note("ap-error", "The answer never came back, so this screen cannot tell " +
          "you whether it was sent. " + asSentence(e.message || String(e)) +
          " Look at the list below before you try again — if it is there, it has gone.");
        bringIntoView("ap-error");
        return loadList().catch(function () { /* already complaining */ });
      }).finally(function () {
        busy(btn, false, "Send it");
        closeConfirm();
      });
    }

    // --- what has been sent ---------------------------------------------------
    function stateOf(n) {
      if (n.status === "sent") {
        return { klass: "is-sent", pill: "ap-sent", word: "Sent" };
      }
      if (n.status === "failed") {
        return { klass: "is-failed", pill: "ap-failed", word: "Did not send" };
      }
      /*  'sending' IS A REAL STATE AND NOT A SPINNER. The row is written
          before anything is sent, and it is only moved off 'sending' when the
          far end says how it went. A row still saying this an hour later means
          the send never finished — the browser closed, the Worker timed out,
          the recording call failed. That is precisely the row somebody will be
          trying to reconstruct later, so it says so in words. */
      return { klass: "is-sending", pill: "ap-sending",
               word: "Still sending, or it did not finish" };
    }

    function whoText(n) {
      var by = trim(n.sent_by) || "an administrator whose name is not on file";
      return "Sent by " + by;
    }

    function draw(list) {
      var box = el("ap-list");
      if (!box) return;
      if (!list.length) {
        box.innerHTML = "<p class=\"ap-empty\">Nothing has been sent yet.</p>";
        return;
      }
      box.innerHTML = list.map(function (n) {
        var s = stateOf(n);
        var reach = "";
        if (n.status === "sent") {
          reach = typeof n.recipients === "number"
            ? "Reached " + n.recipients + " phone" + (n.recipients === 1 ? "" : "s")
            : "The app did not say how many phones it reached";
        }
        return '<div class="ap-item ' + s.klass + '">' +
          '<div class="ap-top">' +
            '<span class="ap-chip">' + esc(TOPIC_LABEL[n.topic] || n.topic) + "</span>" +
            '<span class="ap-head">' + esc(n.title || "(no heading)") + "</span>" +
            '<span class="ap-state ' + s.pill + '">' + esc(s.word) + "</span>" +
          "</div>" +
          '<div class="ap-when">' + esc(readable(n.at)) + " · " + esc(whoText(n)) +
            (n.sent_by_you ? ' <span class="ap-you">that was you</span>' : "") +
          "</div>" +
          (reach ? '<div class="ap-when">' + esc(reach) + "</div>" : "") +
          (n.error ? '<div class="ap-why">' + esc(asSentence(n.error)) + "</div>" : "") +
        "</div>";
      }).join("");
    }

    function loadList() {
      return sb.rpc("app_notifications_list").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        //  The function returns a jsonb array, which arrives already parsed.
        rows = Array.isArray(res.data) ? res.data : [];
        draw(rows);
      }).catch(function (e) {
        var box = el("ap-list");
        if (box) box.innerHTML = "<p class=\"ap-empty\">This list could not be " +
          "read, so it is not safe to assume nothing has been sent.</p>";
        note("ap-error", "Couldn't read what has been sent: " + (e.message || e));
        throw e;
      });
    }

    // --- wiring ---------------------------------------------------------------
    function wireForm() {
      if (wired) { refresh(); return true; }
      wired = true;

      ["ap-title", "ap-body", "ap-event-at"].forEach(function (id) {
        var node = el(id);
        if (!node) return;
        node.addEventListener("input", function () { refresh(); closeConfirm(true); });
        node.addEventListener("change", function () { refresh(); closeConfirm(true); });
      });

      Array.prototype.forEach.call(
        document.querySelectorAll('input[name="ap-topic"]'),
        function (radio) {
          radio.addEventListener("change", function () { refresh(); closeConfirm(true); });
        });

      el("ap-keep").addEventListener("change", function () {
        //  The message limit changes with this tick-box, so the counter has to
        //  be recomputed the moment it moves — not when the next key is
        //  pressed, by which time somebody has already been told the wrong
        //  number.
        refresh();
        closeConfirm(true);
      });

      el("ap-file").addEventListener("change", function () {
        var file = this.files && this.files[0];
        if (file) choosePoster(file);
      });
      el("ap-pic-clear").addEventListener("click", function () {
        clearPoster();
        closeConfirm(true);
        note("ap-ok", "The poster has been taken off. Nothing was sent, and " +
                      "nothing was uploaded anywhere.");
      });

      el("ap-send").addEventListener("click", openConfirm);
      el("ap-back").addEventListener("click", function () {
        closeConfirm();
        el("ap-send").focus();
      });
      el("ap-go").addEventListener("click", send);

      refresh();
      return true;
    }

    function mount(identity) {
      wireForm();
      return loadList().catch(function () {
        //  loadList has already put the reason on the screen.
      });
    }

    return { mount: mount, _wire: wireForm, _labels: TOPIC_LABEL, _topics: TOPICS };
  })();

  /*  EXPOSED FOR THE TESTS.

      wire() is not pure, and it is here for a reason learned the hard way on
      times/. The rules that matter on this screen — "you cannot send an empty
      notification", "the message limit halves when nothing is kept", "a
      poster forces the notice on" — all live inside mount(), which runs only
      after a real sign-in with two-step. No test could ever reach them, and
      the Send button is disabled in the markup as well, so it reads as
      disabled whether the rule is there or has been deleted. A check like
      that passes with the code removed.

      Calling wire() on a page nobody is signed in to wires a Send button
      whose confirmation calls app-notify, which records through
      app_notification_start() — and Postgres refuses that to anybody who is
      not an administrator who has completed two-step. The check is in the
      database, not in this file.

      The labels are exposed with it so a test can hold them against TOPICS in
      supabase/functions/app-notify/index.ts. Those two disagreeing means an
      audience nobody can reach, or one the database throws out after the
      person has pressed the button. */
  window.__APP_SEND = { wire: sending._wire, labels: sending._labels,
                        topics: sending._topics };

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'appsend',
        title:   'Send to the app',
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
    try { sending.mount(identity); } catch (e) {
      if (window.console) console.warn("send-to-the-app panel unavailable:", e);
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
