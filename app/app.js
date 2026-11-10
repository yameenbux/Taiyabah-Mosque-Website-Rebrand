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

    /*  SEVEN TOPICS, EACH NAMING WHICH OF THE TWO DESTINATIONS IT HAS.

        This screen used to offer only the five the app's own push switches
        cover — janazah, jamaah, announcements, events, kahf, the check
        constraint in 051 and the Worker's own TOPICS list in
        supabase/functions/app-notify/index.ts. notices/ separately offered
        six — the same four plus ramadan and madrasah, never jamaah — because
        a website notice and a push notification are different systems with
        different audiences: nobody's phone has a switch for "ramadan" or
        "madrasah" yet, and a reminder before Jamaa'ah has no website notice
        to go with it.

        Two screens asking the same question with different answers is how
        the committee ended up filling in the same message twice. So there is
        one list now, and each topic says which of "push" and "notice" it
        actually reaches — `push` must still agree with
        supabase/functions/app-notify/index.ts's TOPICS and 051's check
        constraint; `notice` must still agree with
        notice_topic_is_one_we_show. A topic offered here that either refuses
        is dead the moment somebody picks it; one of theirs missing here is a
        destination nobody at the masjid can reach. */
    var TOPICS = [
      { key: "announcements", label: "Announcements",     push: true,  notice: true },
      { key: "events",        label: "Events & talks",    push: true,  notice: true },
      { key: "janazah",       label: "Janāzah",           push: true,  notice: true },
      { key: "kahf",          label: "Sūrah al-Kahf",     push: true,  notice: true },
      { key: "jamaah",        label: "Jamāʿah reminders", push: true,  notice: false },
      { key: "ramadan",       label: "Ramadan",           push: false, notice: true },
      { key: "madrasah",      label: "Madrasah",          push: false, notice: true }
    ];
    var TOPIC_LABEL = {};
    var TOPIC_BY_KEY = {};
    TOPICS.forEach(function (t) { TOPIC_LABEL[t.key] = t.label; TOPIC_BY_KEY[t.key] = t; });

    var TITLE_MAX = 70;     // app_notification_has_a_heading, the Worker, and notice_has_a_short_heading
    var BODY_MAX  = 2000;   // what /api/notice and save_notice() will both take
    var PUSH_MAX  = 220;    // what /api/send will take, with nothing kept

    //  042: the website's picture bucket is public, capped at 5 MB, and
    //  accepts the same three kinds the push poster does.
    var BUCKET = "notices";

    /*  Five megabytes, checked here as well as at the far end, because a
        person who has just waited ninety seconds for a twelve-megabyte
        photograph to be read off their phone and refused has been failed by
        this screen and not by the app. */
    var MAX_BYTES  = 5 * 1024 * 1024;
    var FILE_KINDS = { "image/jpeg": "JPEG", "image/png": "PNG", "image/webp": "WebP" };

    //  The chosen poster, as a data URL with its real pixel size beside it,
    //  AND the original File — the data URL goes to the app exactly as
    //  before; the File is what gets uploaded to the website's own picture
    //  bucket if this is published there too. Held here rather than in a
    //  hidden input: a 4 MB data URL in the DOM is a 4 MB string the browser
    //  re-reads on every keystroke.
    var poster = null;      // { data, w, h, bytes, file }
    var rows   = [];        // the last list of pushes read
    var webRows = [];       // the last list of website notices read
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
    function currentTopic() {
      var picked = document.querySelector('input[name="ap-topic"]:checked');
      var t = picked ? TOPIC_BY_KEY[picked.value] : null;
      return t || TOPIC_BY_KEY.announcements;
    }

    function keepOn() {
      var box = el("ap-keep");
      return !!(box && box.checked);
    }

    //  `.disabled` is read as well as `.checked`: syncDestinations() disables
    //  and unchecks whichever switch the current topic has no channel for,
    //  but a box a test flips by hand without going through that function
    //  should not be trusted either — a topic with no push channel must never
    //  be read as "pushing" just because something left the box ticked.
    function pushOn()    { var b = el("ap-push");    return !!(b && b.checked && !b.disabled); }
    function publishOn() { var b = el("ap-publish"); return !!(b && b.checked && !b.disabled); }

    /*  WHETHER THE WEBSITE GETS A NOTICE REGARDLESS OF WHAT THE PUBLISH
        SWITCH SAYS.

        A kept push does not only keep a copy in the app's own history — it
        calls publish_notice() (the Worker's /api/notice, wired up long
        before this screen existed) which writes straight into the SAME
        public.notices table this screen's own "publish" switch also
        writes to, immediately live. Treating "publish" as a second,
        independent switch produced two rows for one notice the moment
        both were ticked, which is the DEFAULT state for every topic that
        offers both — discovered from a real duplicate on the live site.
        There is no way to keep a push without it reaching the website; the
        only honest thing the publish switch can do once that is true is
        say so, not offer a choice that was already made upstream. */
    function pushAlreadyPublishes() { return pushOn() && keepOn(); }

    //  What actually ends up on the website, whether that is because the
    //  publish switch is genuinely on or because pushAlreadyPublishes()
    //  made it happen regardless. publishOn() alone reads false once the
    //  switch is disabled-and-forced, which would make this screen report
    //  "not published" about something that, in fact, was.
    function effectivePublish() { return publishOn() || pushAlreadyPublishes(); }

    /*  THE MESSAGE LIMIT IS THE STRICTEST OF WHEREVER IT IS ACTUALLY GOING.

        A kept push, or anything published on the website, goes through
        save_notice() or /api/notice — both take two thousand characters. An
        unkept push with nowhere else to go takes two hundred and twenty,
        /api/send's own limit. Sending to more than one destination at once
        means the smallest limit among them applies to all of them, or a
        message could pass validation for one and be refused by the other
        after the person has already pressed a button that cannot be taken
        back if the push half had worked. So the limit is computed from
        whichever switches are actually on, not guessed at once and reused. */
    function activeLimit() {
      var limit = BODY_MAX;
      if (pushOn() && !keepOn()) limit = Math.min(limit, PUSH_MAX);
      return limit;
    }

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
      var limit = activeLimit();
      var left  = limit - value.length;
      var tight = limit === PUSH_MAX;

      if (left >= 0) {
        box.textContent = left + " characters left." +
          (tight ? " Nothing is being kept and this isn't going on the website, so the limit is " + PUSH_MAX + "." : "");
      } else {
        box.textContent = (-left) + " characters too many — the limit is " +
          limit + "." +
          (tight ? " Tick “also keep this on the app's Notices tab” above, " +
                   "or publish it on the website, and you have " + BODY_MAX + "."
                 : "");
      }
      box.classList.toggle("is-over", left < 0);
    }

    /*  WHICH OF THE TWO SWITCHES A TOPIC ACTUALLY OFFERS.

        Run whenever the topic changes — never on every keystroke, or
        somebody unticking a switch by hand while writing the message would
        have it silently reset under them. Disabling rather than hiding: a
        switch that is simply not there for some topics is a shape that
        changes as you click through them, which reads as a misclick. */
    function syncDestinations() {
      var t = currentTopic();
      var push = el("ap-push");
      push.disabled = !t.push;
      el("ap-push-row").classList.toggle("is-off", !t.push);
      el("ap-push-why").textContent = t.push
        ? "A notification on the phone of everybody who has that topic switched on."
        : "There is no push channel for this topic yet, so this is website-only.";
      syncPublishSwitch();
    }

    /*  THE PUBLISH SWITCH'S STATE HAS THREE CAUSES, not one: the topic may
        offer no website channel at all (disabled, same as syncDestinations()
        handles "push" above); the push side may already be forcing it
        (disabled the other way — see pushAlreadyPublishes()); or it may
        genuinely be the person's own choice. Separated from
        syncDestinations() so it can also be re-run on every keystroke, from
        refresh() — pushAlreadyPublishes() depends on the "keep" tick-box,
        which changes without the topic ever changing. */
    function syncPublishSwitch() {
      var pub = el("ap-publish");
      if (pushAlreadyPublishes()) {
        pub.checked  = true;
        pub.disabled = true;
        el("ap-publish-row").classList.remove("is-off");
        el("ap-publish-why").textContent = "A kept push is always put on the " +
          "website too — that happens whether or not this is ticked, so " +
          "there is nothing left here to switch off.";
        return;
      }
      var t = currentTopic();
      pub.disabled = !t.notice;
      el("ap-publish-row").classList.toggle("is-off", !t.notice);
      el("ap-publish-why").textContent = t.notice
        ? "A notice on the front page, live the moment you confirm — editable or removable afterwards from Notices."
        : "There is no website-notice equivalent for this topic, so this is push-only.";
    }

    //  Switching topic resets both switches to "on if this topic reaches
    //  it" — a bigger decision than a keystroke, and the one moment a reset
    //  reads as help rather than the screen fighting a choice just made.
    function onTopicChange() {
      var t = currentTopic();
      el("ap-push").checked    = t.push;
      el("ap-publish").checked = t.notice;
      syncDestinations();
      refresh();
      closeConfirm(true);
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

      showPoster();         // may force "keep" on, which can change the next line
      syncPublishSwitch();  // re-checks whether "keep" now forces "publish" too

      var push = pushOn();
      var auto = pushAlreadyPublishes();
      var pub  = publishOn() || auto;

      countdown("ap-title-count", title, TITLE_MAX);
      messageCount();
      drawLock();

      //  "Also keep this on the Notices tab" only means anything once there
      //  is a push to keep a copy of. With push off it is a tick-box about a
      //  destination that isn't happening, so it is taken off the page rather
      //  than left there disabled and unexplained.
      el("ap-keep-row").hidden = !push;

      //  The expiry field is THIS SCREEN'S OWN publish call's setting, and
      //  that call never runs when the push side is already publishing (see
      //  send()) — publish_notice() picks its own expiry instead, from the
      //  event date. Showing a field that would silently be ignored is worse
      //  than not showing it.
      el("ap-expires-row").hidden  = !pub || auto;
      el("ap-expires-hint").hidden = !pub || auto;

      //  A heading with no message is a notification that says nothing when
      //  somebody opens it, and a message with no heading has nothing to show
      //  on a locked phone — the far end refuses both. And with BOTH
      //  destinations off, pressing send would do nothing at all, which is a
      //  different failure from an empty message and needs its own check.
      el("ap-send").disabled = !(title && body) || !(push || pub);
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

      /*  A POSTER FORCES "KEEP AS A NOTICE" ON, BUT ONLY WHEN PUSH IS ACTUALLY
          ON. /api/send has nowhere to put a picture; only a kept push notice
          has. That reason has nothing to do with the website side — save_notice()
          always has a place for a picture — so forcing this when push is off
          would be enforcing a rule for a destination that isn't even in play.
          Said out loud rather than done quietly either way: silently ticking a
          box somebody had deliberately unticked is how a screen loses somebody's
          trust. */
      if (pushOn()) {
        keep.checked  = true;
        keep.disabled = true;
        el("ap-pic-forced").hidden = false;
      } else {
        keep.disabled = false;
        el("ap-pic-forced").hidden = true;
      }
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
                     bytes: file.size, file: file };
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
               "first.",
      //  Publish-only has none of the above: nothing reaches a phone, and
      //  anything wrong with it is one more RPC call away from being fixed.
      //  Saying so is not a technicality — it is the whole reason this screen
      //  can afford to ask "send this now?" in a calmer voice than the push
      //  wording above.
      publishOnly: "This goes on the website's front page the moment you " +
                   "confirm it. Nothing is sent to anybody's phone. You can " +
                   "edit the wording, take it down, or delete it afterwards " +
                   "from Notices — none of that is true of the push half " +
                   "above, so read it carefully anyway, but a mistake here is " +
                   "not the same kind of mistake."
    };

    //  Three shapes, because "both", "push only" and "publish only" are each
    //  a different sentence rather than the same one with words removed.
    function destinationSummary(push, pub) {
      if (push && pub)  return "Pushed to the app, and published on the website.";
      if (push)         return "Pushed to the app. Not published on the website.";
      if (pub)          return "Published on the website. Not pushed to the app.";
      return "Nowhere — tick at least one of the two switches above.";
    }

    function openConfirm() {
      var t     = currentTopic();
      var title = trim(el("ap-title").value);
      var body  = trim(el("ap-body").value);
      var push  = pushOn();
      var pub   = effectivePublish();

      if (!title || !body || !(push || pub)) return;  // belt and braces; Send is disabled too

      //  Refused here rather than at the far end, where the person has already
      //  committed to something irreversible and is then told it did not work.
      var limit = activeLimit();
      if (body.length > limit) {
        note("ap-error", "That message is " + body.length + " characters, and " +
          (limit === BODY_MAX
            ? "the limit is " + BODY_MAX + "."
            : "without keeping it on the Notices tab, or publishing it on the " +
              "website, the limit is " + PUSH_MAX + ". Either shorten it, tick " +
              "“also keep this on the app's Notices tab”, or publish it on the " +
              "website — either way you have " + BODY_MAX + "."));
        bringIntoView("ap-error");
        return;
      }

      note("ap-error", ""); note("ap-ok", "");
      el("ap-changed").hidden = true;

      var panel = el("ap-confirm");
      var grave = push && t.key === "janazah";
      panel.classList.toggle("is-grave", grave);
      el("ap-confirm-h").textContent = grave
        ? "Send this janāzah announcement now?"
        : "Send this now?";
      el("ap-confirm-p").textContent = grave ? WORDS.janazah
        : (push ? WORDS.normal : WORDS.publishOnly);

      el("ap-confirm-dest").textContent = destinationSummary(push, pub);

      //  The push-specific rows mean nothing once push is off, so they leave
      //  the panel entirely rather than show "—" beside a question nobody
      //  asked.
      el("ap-confirm-aud-row").hidden  = !push;
      el("ap-confirm-keep-row").hidden = !push;
      if (push) {
        el("ap-confirm-aud").textContent  = t.label;
        el("ap-confirm-keep").textContent = keepOn()
          ? "It stays on the app's Notices tab after the notification is swiped away, " +
            "and is published on the website at the same time — that part is not optional."
          : "Nothing is kept. Once somebody swipes the notification away, it is gone.";
      }
      el("ap-confirm-title").textContent = title;
      el("ap-confirm-body").textContent  = body;

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
      el("ap-title").value      = "";
      el("ap-body").value       = "";
      el("ap-event-at").value   = "";
      el("ap-expires-at").value = "";
      clearPoster();
      refresh();
    }

    /*  THE PUSH HALF — unchanged in shape and semantics from before this
        screen could also publish; only lifted out of send() so the two
        destinations can run side by side and be reported on separately. */
    function doPush(t, title, body) {
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
            topic:          t.key,
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
        return r.text().then(function (txt) {
          var out;
          try { out = JSON.parse(txt); } catch (e) { out = { error: txt.slice(0, 300) }; }
          return out || {};
        });
      });
    }

    //  The extension matters only for the filename the bucket stores it
    //  under — getPublicUrl() hands back whatever that name is, and the
    //  browser never looks at it to decide how to decode the picture.
    var UPLOAD_EXT = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

    /*  THE WEBSITE HALF. A poster, if there is one, is uploaded to the same
        public bucket notices/ uses — not reconstructed from the data URL
        app-notify gets, the original File that choosePoster() stashed on
        `poster.file` for exactly this. save_notice() always writes a row;
        set_notice_published() is what actually puts it in front of a
        visitor, called straight after because the committee asked for ONE
        button, not a draft somebody has to remember to go and publish. */
    function doPublish(t, title, body) {
      var upload = Promise.resolve(null);

      if (poster && poster.file) {
        var ext  = UPLOAD_EXT[poster.file.type] || "jpg";
        var name = String(Date.now()) + "-" +
                   Math.random().toString(36).slice(2, 8) + "." + ext;
        upload = sb.storage.from(BUCKET).upload(name, poster.file, {
          contentType: poster.file.type, upsert: false
        }).then(function (res) {
          if (res.error) throw new Error("The poster could not be uploaded: " +
                                         res.error.message);
          var pub = sb.storage.from(BUCKET).getPublicUrl(name);
          var url = pub && pub.data && pub.data.publicUrl;
          if (!url) throw new Error("The poster uploaded but the masjid's store " +
                                    "gave no web address for it.");
          return url;
        });
      }

      return upload.then(function (imageUrl) {
        var p = {
          topic:      t.key,
          title:      title,
          body:       body,
          image_url:  imageUrl || "",
          image_w:    imageUrl ? poster.w : null,
          image_h:    imageUrl ? poster.h : null,
          event_at:   toStamp(el("ap-event-at").value),
          expires_at: toStamp(el("ap-expires-at").value)
        };
        return sb.rpc("save_notice", { p: p });
      }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        var id = (res.data || {}).id;
        if (!id) throw new Error("The notice saved but did not say which one it was, " +
                                 "so it could not be published automatically.");
        return sb.rpc("set_notice_published", { p_id: id, p_published: true })
          .then(function (pubRes) {
            if (pubRes.error) throw new Error("It saved, but could not be published: " +
                                              pubRes.error.message +
                                              " It is sitting as a draft in Notices.");
            return { ok: true };
          });
      }).catch(function (e) {
        return { ok: false, error: e.message || String(e) };
      });
    }

    function send() {
      var t     = currentTopic();
      var title = trim(el("ap-title").value);
      var body  = trim(el("ap-body").value);
      var push  = pushOn();
      var auto  = pushAlreadyPublishes();
      var pub   = publishOn() || auto;
      var btn   = el("ap-go");

      busy(btn, true, "Send it");
      note("ap-error", ""); note("ap-ok", "");

      var jobs = {};
      /*  The caller's own token, deliberately. app-notify writes the record
          with it BEFORE it sends anything, so the row names the person who
          pressed the button and nothing downstream can change that. It is
          also the permission check — a caller who is not a two-step
          administrator is refused there and nothing goes out. save_notice()
          and set_notice_published() carry the same check inside Postgres, so
          neither half needs its own guard here.

          doPublish() DOES NOT RUN WHEN `auto` IS TRUE. A kept push already
          calls publish_notice() through the SAME code path the push itself
          uses — see pushAlreadyPublishes() — and calling save_notice() as
          well would write the same notice twice. This is the fix for a real
          duplicate found on the live site: two rows, a fraction of a second
          apart, one from each call. */
      if (push) jobs.push    = doPush(t, title, body);
      if (pub && !auto) jobs.publish = doPublish(t, title, body);

      return Promise.all([
        jobs.push    || Promise.resolve(null),
        jobs.publish || Promise.resolve(null)
      ]).then(function (res) {
        var pushOut = res[0];
        var pubOut  = res[1];
        var lines   = [];
        var anyFailed = false;

        if (push) {
          /*  ok:false IS NOT A SENT NOTIFICATION, whatever else came back
              with it. The Worker answers 200 with sent:{sent:false} when the
              notice was saved and OneSignal refused it, and app-notify
              reports that faithfully as ok:false. Saying "sent" here about a
              saved notice nobody received would be the exact failure this
              screen exists to end. */
          if (!pushOut || pushOut.ok !== true) {
            anyFailed = true;
            lines.push("NOT pushed to the app. Nobody's phone has received " +
              "anything. The reason given was: " +
              (asSentence(pushOut && pushOut.error) ||
               "none, which usually means the app sender could not be reached at all.") +
              ((pushOut && pushOut.id) ? " There is a row in the push list below showing the attempt." : ""));
          } else {
            var reached = typeof pushOut.recipients === "number"
              ? "reached " + pushOut.recipients + " phone" + (pushOut.recipients === 1 ? "" : "s")
              : "the app did not say how many phones it reached";
            var kept = pushOut.kept_as_notice
              ? " It is on the app's Notices tab as well."
              : " Nothing was kept — once it is swiped away it is gone.";
            var missing = pushOut.recorded === false
              ? " It went out, but could not be written into the push list below — " +
                "so that list is not complete, and somebody should be told before " +
                "anything else is sent."
              : "";
            lines.push("Pushed to " + (pushOut.topic_label || t.label) + ". It " +
                       reached + "." + kept + missing);
          }
        }

        if (pub) {
          if (auto) {
            /*  There was no separate doPublish() call to read a result from
                — the website row comes from the SAME /api/notice call the
                push used. pushOut.notice_id says whether THAT call actually
                saved a row, which is a different question from pushOut.ok
                (whether OneSignal delivered it): the Worker writes the
                notice before it ever attempts the send, so a 0-phones push
                can still have published successfully, and a push that never
                reached the Worker at all cannot have. */
            if (pushOut && pushOut.notice_id) {
              lines.push("Published on the website — live on the front page " +
                "now, as part of the kept push above.");
            } else {
              anyFailed = true;
              lines.push("NOT published on the website: the push above never " +
                "got as far as saving a notice, so there was nothing to put on " +
                "the website either.");
            }
          } else if (!pubOut || pubOut.ok !== true) {
            anyFailed = true;
            lines.push("NOT published on the website: " +
              (asSentence(pubOut && pubOut.error) || "an unknown error."));
          } else {
            lines.push("Published on the website — live on the front page now.");
          }
        }

        var message = lines.join(" ");
        if (anyFailed) {
          note("ap-error", message);
          bringIntoView("ap-error");
        } else {
          note("ap-ok", message);
          bringIntoView("ap-ok");
          clearAfterSend();
        }

        //  Reloaded regardless of outcome: app_notification_start() writes its
        //  row before anything is sent, so a failed push still has a row to
        //  show, and a half-success on the website side still belongs in
        //  that list.
        return Promise.all([
          push ? loadList() : Promise.resolve(),
          pub  ? loadWebsiteList() : Promise.resolve()
        ]);
      }).catch(function (e) {
        /*  Reaching here means something outside doPush/doPublish's own
            catches broke — both of those already turn their failures into
            {ok:false}, so this is a genuine surprise, not an expected
            rejection. */
        note("ap-error", "Something went wrong that this screen did not expect. " +
          asSentence(e.message || String(e)) +
          " Look at the lists below before you try again — if something is " +
          "there, it has gone.");
        bringIntoView("ap-error");
        return Promise.all([loadList(), loadWebsiteList()])
          .catch(function () { /* already complaining */ });
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

    // --- what's on the website now ---------------------------------------
    /*  Read-only, deliberately. Editing, taking down or deleting a notice is
        Notices' own job, with its own undo-nothing warnings about public
        buckets and its own tests — re-implementing any of that here, for a
        screen whose point is sending something new, is exactly the kind of
        duplicated logic that got the two screens out of step in the first
        place. This reuses notices_list() and the same .ap-item markup the
        push history already draws with. */
    function drawWebsite(list) {
      var box = el("ap-website-list");
      if (!box) return;
      var live = list.filter(function (n) { return n.on_the_website; });
      if (!live.length) {
        box.innerHTML = "<p class=\"ap-empty\">Nothing is currently published " +
          "on the website.</p>";
        return;
      }
      box.innerHTML = live.map(function (n) {
        return '<div class="ap-item is-sent">' +
          '<div class="ap-top">' +
            '<span class="ap-chip">' + esc(TOPIC_LABEL[n.topic] || n.topic) + "</span>" +
            '<span class="ap-head">' + esc(n.title || "(no heading)") + "</span>" +
          "</div>" +
          '<div class="ap-when">' +
            (n.event_at ? esc(readable(n.event_at))
                        : "Added " + esc(readable(n.created_at))) +
            (n.expires_at ? " · comes off " + esc(readable(n.expires_at)) : "") +
          "</div>" +
        "</div>";
      }).join("");
    }

    function loadWebsiteList() {
      return sb.rpc("notices_list").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        webRows = Array.isArray(res.data) ? res.data : [];
        drawWebsite(webRows);
      }).catch(function (e) {
        var box = el("ap-website-list");
        if (box) box.innerHTML = "<p class=\"ap-empty\">This list could not be " +
          "read.</p>";
        //  Deliberately not bringIntoView'd and not an ap-error: this list
        //  failing to load says nothing about whether a send just worked, and
        //  stealing the error box from that message would be the wrong thing
        //  to be alarmed about.
      });
    }

    // --- wiring ---------------------------------------------------------------
    function wireForm() {
      if (wired) { syncDestinations(); refresh(); return true; }
      wired = true;

      ["ap-title", "ap-body", "ap-event-at", "ap-expires-at"].forEach(function (id) {
        var node = el(id);
        if (!node) return;
        node.addEventListener("input", function () { refresh(); closeConfirm(true); });
        node.addEventListener("change", function () { refresh(); closeConfirm(true); });
      });

      Array.prototype.forEach.call(
        document.querySelectorAll('input[name="ap-topic"]'),
        function (radio) {
          radio.addEventListener("change", onTopicChange);
        });

      ["ap-keep", "ap-push", "ap-publish"].forEach(function (id) {
        el(id).addEventListener("change", function () {
          //  The message limit, which destinations' rows show, and whether a
          //  poster is forced to be kept all change with these tick-boxes, so
          //  all of it has to be recomputed the moment one moves — not when
          //  the next key is pressed, by which time somebody has already been
          //  told the wrong thing.
          refresh();
          closeConfirm(true);
        });
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

      syncDestinations();
      refresh();
      return true;
    }

    function mount(identity) {
      wireForm();
      return Promise.all([
        loadList().catch(function () {
          //  loadList has already put the reason on the screen.
        }),
        loadWebsiteList()
      ]);
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
        title:   'Notifications & notices',
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
