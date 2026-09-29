  /* =========================================================================
     MESSAGES FROM PARENTS

     WHAT THIS SCREEN IS FOR. A parent can write to the office; this is where
     the office reads it and writes back. Every conversation belongs to a
     household, not to one parent, so whichever parent opens the reply sees it.

     A LIST SAYS WHETHER, THE CONVERSATION SAYS WHAT. The list shows the
     family's reference, the title the parent gave, how long it has waited and
     how many messages are in it - never a family name and never a word of a
     message. Opening a conversation shows the family and the words, and that
     is recorded in the audit log (who opened which conversation, never what
     was in it).

     WAITING MEANS THE PARENT SPOKE LAST. A conversation stays in "Waiting"
     when you have read it; only a reply (or closing it) takes it out. That is
     the same rule Today and the Monday digest use, so the three cannot
     disagree about the number.

     THE DATABASE DECIDES. Nothing here is a permission: every call is
     refused by the server unless the caller is the office with two-step
     sign-in, and a refusal is {allowed:false}, which this screen turns into
     a sentence and never into an empty list.
     ======================================================================= */
  var messages = (function () {
    var TAB = "waiting";
    var COUNTS = { waiting: 0, answered: 0, closed: 0 };
    var ROWS = [];
    var OPEN = null;        //  the conversation being read: {thread, messages}
    var busy = false;
    var TABS = [
      { key: "waiting",  label: "Waiting for a reply" },
      { key: "answered", label: "Answered" },
      { key: "closed",   label: "Closed" },
      { key: "all",      label: "All" }
    ];
    var MONTHS = ["January", "February", "March", "April", "May", "June", "July",
                  "August", "September", "October", "November", "December"];

    function el(id) { return document.getElementById(id); }
    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }
    function fail(msg) {
      var n = el("ms-error");
      if (!n) return;
      n.textContent = msg; n.hidden = false; show("ms-ok", false);
    }
    function clearFail() { show("ms-error", false); }
    function ok(msg) {
      var n = el("ms-ok");
      if (!n) return;
      n.textContent = msg; n.hidden = false;
    }
    //  The database words its own refusals (22023); anything else is plain.
    function say(e) {
      if (e && e.code === "22023" && e.message) return e.message;
      return "That did not work" + (e && e.message ? ": " + e.message : ".");
    }
    function noAccess() {
      return "This area is for the madrasah office, signed in with two-step. "
           + "If you should be able to see it, ask an administrator.";
    }
    function stamp(iso) {
      var d = new Date(iso);
      if (isNaN(d.getTime())) return "";
      var mins = d.getMinutes();
      return d.getDate() + " " + MONTHS[d.getMonth()] + ", "
           + d.getHours() + ":" + (mins < 10 ? "0" : "") + mins;
    }
    function waited(days) {
      if (days <= 0) return "today";
      if (days === 1) return "1 day";
      return days + " days";
    }

    function call(name, args) {
      return sb.rpc(name, args || {}).then(function (res) {
        if (res.error) throw res.error;
        return res.data;
      });
    }

    function drawTabs() {
      var h = "", i, t, n;
      for (i = 0; i < TABS.length; i++) {
        t = TABS[i];
        n = t.key === "all" ? COUNTS.waiting + COUNTS.answered + COUNTS.closed : COUNTS[t.key];
        h += '<button type="button" role="tab" class="ms-tab' + (t.key === TAB ? " on" : "")
           + (t.key === "waiting" && n > 0 ? " ms-tab-alert" : "")
           + '" data-tab="' + t.key + '" aria-selected="' + (t.key === TAB ? "true" : "false") + '">'
           + esc(t.label) + ' <span class="ms-n">' + n + "</span></button>";
      }
      el("ms-tabs").innerHTML = h;
    }

    function emptyWords() {
      if (TAB === "waiting") {
        return "Nothing is waiting for a reply. Every parent who has written has been answered.";
      }
      if (TAB === "answered") return "No conversations are sitting answered.";
      if (TAB === "closed") return "No conversations have been closed.";
      return "No parent has written to the madrasah yet.";
    }

    function drawList() {
      var h = "", i, r, state;
      show("ms-loading", false);
      if (!ROWS.length) {
        el("ms-list").innerHTML = "";
        show("ms-list", false);
        el("ms-empty").innerHTML = "<p>" + esc(emptyWords()) + "</p>";
        show("ms-empty", true);
        return;
      }
      show("ms-empty", false);
      for (i = 0; i < ROWS.length; i++) {
        r = ROWS[i];
        state = r.state === "open" ? "Waiting for a reply"
              : r.state === "answered" ? "Answered" : "Closed";
        h += '<li><button type="button" class="ms-row ms-s-' + esc(r.state)
           + (OPEN && OPEN.thread && OPEN.thread.id === r.id ? " open" : "")
           + '" data-id="' + esc(r.id) + '">'
           + '<span class="ms-subj">' + esc(r.subject) + (r.unread ? ' <span class="ms-new">new</span>' : "") + "</span>"
           + '<span class="ms-meta">Family ' + esc(r.reference) + " &middot; "
           + r.messages + (r.messages === 1 ? " message" : " messages") + " &middot; "
           + (r.state === "open" ? "waiting " + esc(waited(r.days)) : esc(state).toLowerCase())
           + "</span></button></li>";
      }
      el("ms-list").innerHTML = h;
      show("ms-list", true);
    }

    function drawThread() {
      var t, m, i, h;
      if (!OPEN) { show("ms-thread", false); return; }
      t = OPEN.thread; m = OPEN.messages || [];
      h = '<div class="ms-th-head"><h2>' + esc(t.subject) + "</h2>"
        + '<p class="ms-th-fam">' + esc(t.family) + " &middot; family " + esc(t.reference)
        + " &middot; " + (t.state === "closed" ? "closed" : t.state === "answered" ? "answered" : "waiting for a reply")
        + "</p></div>";
      h += '<ol class="ms-msgs">';
      for (i = 0; i < m.length; i++) {
        h += '<li class="ms-msg ' + (m[i].from_parent ? "ms-from-parent" : "ms-from-office") + '">'
           + '<p class="ms-who"><b>' + esc(m[i].who) + "</b> &middot; " + esc(stamp(m[i].created_at)) + "</p>"
           + '<p class="ms-body">' + esc(m[i].body) + "</p></li>";
      }
      h += "</ol>";
      h += '<form id="ms-f" novalidate><label for="ms-reply">Your reply</label>'
         + '<textarea id="ms-reply" rows="5" maxlength="4000" placeholder="Write your reply here"></textarea>'
         + '<span class="ms-fine">The family sees this as a message from the office, not from you by name. Up to 4,000 characters.</span>'
         + '<p class="ms-inline" id="ms-inline" role="alert" hidden></p>'
         + '<div class="ms-acts"><button type="submit" class="btn btn-gold" id="ms-send">Send reply</button>'
         + (t.state === "closed"
              ? '<span class="ms-fine">This conversation is closed. Replying reopens it.</span>'
              : '<button type="button" class="btn btn-ghost" id="ms-close">Close without replying</button>')
         + '<button type="button" class="btn btn-ghost" id="ms-back">Back to the list</button></div></form>';
      el("ms-thread").innerHTML = h;
      show("ms-thread", true);
    }

    function loadList() {
      return call("office_threads", { p_which: TAB }).then(function (d) {
        if (!d || d.allowed === false) { fail(noAccess()); show("ms-loading", false); return; }
        COUNTS = d.counts || COUNTS;
        ROWS = d.threads || [];
        drawTabs(); drawList();
      }, function (e) {
        show("ms-loading", false);
        fail("The messages would not load. " + (e && e.message ? e.message : ""));
      });
    }

    function openThread(id) {
      clearFail(); show("ms-ok", false);
      return call("office_thread_read", { p_thread: id }).then(function (d) {
        if (!d || d.allowed === false) { fail("That conversation could not be opened."); return; }
        OPEN = d;
        drawThread(); drawList();
        var box = el("ms-thread");
        if (box && box.scrollIntoView) box.scrollIntoView({ block: "nearest" });
      }, function (e) { fail(say(e)); });
    }

    function afterChange(msg) {
      OPEN = null;
      show("ms-thread", false);
      return loadList().then(function () { ok(msg); });
    }

    function send(ev) {
      ev.preventDefault();
      if (busy || !OPEN) return;
      clearFail();
      var box = el("ms-reply");
      var body = (box.value || "").replace(/^\s+|\s+$/g, "");
      var inl = el("ms-inline");
      if (!body) { inl.textContent = "Write the reply first."; inl.hidden = false; return; }
      inl.hidden = true;
      busy = true; el("ms-send").disabled = true;
      call("office_thread_reply", { p_thread: OPEN.thread.id, p_body: body }).then(function (d) {
        if (!d || d.allowed === false) { fail("That conversation could not be found."); return; }
        return afterChange("Reply sent. The family will see it the next time they open their messages.");
      }, function (e) { fail(say(e)); })["finally"](function () {
        busy = false; var b = el("ms-send"); if (b) b.disabled = false;
      });
    }

    function closeThread() {
      if (busy || !OPEN) return;
      clearFail();
      busy = true;
      call("office_thread_close", { p_thread: OPEN.thread.id }).then(function (d) {
        if (!d || d.allowed === false) { fail("That conversation could not be found."); return; }
        return afterChange("Conversation closed.");
      }, function (e) { fail(say(e)); })["finally"](function () { busy = false; });
    }

    function wire() {
      el("ms-tabs").addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-tab]") : null;
        if (!b) return;
        TAB = b.getAttribute("data-tab");
        OPEN = null; show("ms-thread", false); show("ms-ok", false); clearFail();
        drawTabs();
        loadList();
      });
      el("ms-list").addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-id]") : null;
        if (b) openThread(b.getAttribute("data-id"));
      });
      el("ms-thread").addEventListener("submit", send);
      el("ms-thread").addEventListener("click", function (e) {
        var t = e.target;
        if (!t || !t.id) return;
        if (t.id === "ms-close") closeThread();
        if (t.id === "ms-back") { OPEN = null; show("ms-thread", false); drawList(); }
      });
    }

    function mount(identity) {
      var roles = (identity && identity.roles) || [];
      if (roles.indexOf("admin") === -1 && roles.indexOf("madrasah") === -1) {
        var na = el("app-noaccess");
        if (na) { na.textContent = noAccess(); na.hidden = false; }
        return;
      }
      show("ms-panel", true);
      wire();
      return loadList().then(function () {
        //  A link to one conversation, from a note: messages/#t=<id>.
        var m = /[#&]t=([0-9a-f-]{36})/.exec(window.location.hash || "");
        if (m) return openThread(m[1]);
      });
    }

    return { mount: mount };
  })();
