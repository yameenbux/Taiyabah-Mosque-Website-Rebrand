  /* =========================================================================
     MESSAGES

     A PARENT WRITES TO THE OFFICE, AND READS WHAT THE OFFICE WRITES BACK.
     Every conversation belongs to the family, so either parent sees a reply.
     The office's staff are never named to a family: a parent sees "You", "Your
     household" (the other parent) and "The office".

     THE NOTICE BESIDE THE BOX IS THE POINT OF THE SCREEN'S HONESTY. A message
     is not an emergency channel: it is read by a person on a working day, and
     one sent on a Friday evening can sit unread until Monday. A parent whose
     child is missing rings the masjid. The words are drawn directly above
     every place a parent types (a new message and a reply), not in a footer,
     because a footer is read by nobody who is about to press Send.

     THE SERVER SAYS NO, IN A PARENT'S WORDS. A missing title, a message that
     is too long, five conversations already open, a conversation the office has
     closed, too many messages in a day: the database refuses each in a
     sentence (22023) and this screen shows that sentence as written.

     READING IS NOT THE SAME AS BEING TOLD. Opening a conversation asks the
     server for it (which changes nothing) and then, separately, marks it read.
     ======================================================================= */
  var parentMessages = (function () {
    var C = parentCommon;
    var THREADS = [];
    var CUR = null;       //  the conversation being read: {thread, messages}
    var busy = false;
    var MONTHS = ["January", "February", "March", "April", "May", "June", "July",
                  "August", "September", "October", "November", "December"];

    function stamp(iso) {
      var d = new Date(iso);
      if (isNaN(d.getTime())) return "";
      var mins = d.getMinutes();
      return d.getDate() + " " + MONTHS[d.getMonth()] + ", "
           + d.getHours() + ":" + (mins < 10 ? "0" : "") + mins;
    }

    //  THE EMERGENCY WORDS. Plain, near the box, in the same place every time.
    function notice() {
      return '<div class="pm-notice" role="note"><p><b>This is not for emergencies.</b> '
           + "If your child is missing, or you are worried about their safety, please "
           + "ring the masjid straight away on <b>" + C.esc(C.OFFICE) + "</b>. "
           + "Do not use this page.</p>"
           + "<p>Messages are read by the office on working days. A message can sit "
           + "unread over a weekend, so for anything that cannot wait, ring.</p></div>";
    }

    function inline(id, msg) {
      var n = C.el(id);
      if (!n) return;
      n.textContent = msg || "";
      n.hidden = !msg;
    }

    function stateWord(t) {
      if (t.state === "closed") return "Closed by the office";
      if (t.state === "answered") return "The office has replied";
      return "Sent, waiting for the office";
    }

    function drawList() {
      var h = "", i, t;
      if (!THREADS.length) { C.show("pm-list-wrap", false); return; }
      for (i = 0; i < THREADS.length; i++) {
        t = THREADS[i];
        h += '<li><button type="button" class="pm-row' + (t.unread ? " pm-unread" : "")
           + (CUR && CUR.thread.id === t.id ? " open" : "")
           + '" data-id="' + C.esc(t.id) + '"><span class="pm-subj">' + C.esc(t.subject)
           + (t.unread ? ' <span class="pt-chip">new reply</span>' : "")
           + '</span><span class="pm-meta">' + C.esc(stateWord(t)) + " &middot; "
           + C.esc(stamp(t.last_message_at)) + "</span></button></li>";
      }
      C.el("pm-list").innerHTML = h;
      C.show("pm-list-wrap", true);
    }

    function composeHtml(prefill) {
      return '<h2 class="pt-h">Write to the office</h2>' + notice()
           + '<form id="pm-new" novalidate>'
           + '<div class="pt-field"><label for="pm-title">Title</label>'
           + '<input type="text" id="pm-title" maxlength="120" autocomplete="off" '
           + 'placeholder="A few words about it" value="'
           + C.esc(prefill || "") + '">'
           + '<span class="pt-fine">Please do not put a child&rsquo;s full name in the title.</span></div>'
           + '<div class="pt-field"><label for="pm-text">Your message</label>'
           + '<textarea id="pm-text" rows="6" maxlength="4000" '
           + 'placeholder="Write your message here"></textarea>'
           + '<span class="pt-fine">Up to 4,000 characters. Either parent on this family can read the reply.</span></div>'
           + '<p class="pt-error-inline" id="pm-inline" role="alert" hidden></p>'
           + '<p class="pt-acts"><button type="submit" class="btn btn-gold" id="pm-go">Send to the office</button></p>'
           + "</form>";
    }

    function drawThread() {
      var t, m, i, h, closed;
      if (!CUR) { C.show("pm-thread", false); return; }
      t = CUR.thread; m = CUR.messages || []; closed = t.state === "closed";
      h = '<p class="pt-acts pm-back"><button type="button" class="btn btn-ghost" id="pm-back">'
        + "&larr; All your conversations</button></p>"
        + '<h2 class="pt-h">' + C.esc(t.subject) + "</h2>"
        + '<p class="pt-fine pm-state">' + C.esc(stateWord(t)) + "</p>"
        + '<ol class="pm-msgs">';
      for (i = 0; i < m.length; i++) {
        h += '<li class="pm-msg ' + (m[i].who === "office" ? "pm-office" : "pm-mine") + '">'
           + '<p class="pm-who"><b>' + (m[i].who === "office" ? "The office" : m[i].who === "you" ? "You" : "Your household")
           + "</b> &middot; " + C.esc(stamp(m[i].created_at)) + "</p>"
           + '<p class="pm-body">' + C.esc(m[i].body) + "</p></li>";
      }
      h += "</ol>";
      if (closed) {
        h += '<p class="pt-empty" role="status">The office has closed this conversation. '
           + "If there is more to say, please write a new message below.</p>";
      } else {
        h += notice()
           + '<form id="pm-reply" novalidate><div class="pt-field"><label for="pm-rtext">Your reply</label>'
           + '<textarea id="pm-rtext" rows="4" maxlength="4000" placeholder="Write your reply here"></textarea></div>'
           + '<p class="pt-error-inline" id="pm-rinline" role="alert" hidden></p>'
           + '<p class="pt-acts"><button type="submit" class="btn btn-gold" id="pm-rgo">Send reply</button></p></form>';
      }
      C.el("pm-thread").innerHTML = h;
      C.show("pm-thread", true);
    }

    function loadList() {
      return C.call("parent_threads").then(function (d) {
        C.show("pm-loading", false);
        if (!d || d.allowed === false) {
          C.fail("pm-error", { code: "42501", message: "not yours" });
          return false;
        }
        THREADS = d.threads || [];
        drawList();
        return true;
      }, function (e) { C.show("pm-loading", false); C.fail("pm-error", e); return false; });
    }

    function openThread(id) {
      C.show("pm-error", false); C.show("pm-done", false);
      return C.call("parent_thread_read", { p_thread: id }).then(function (d) {
        if (!d || d.allowed === false) {
          C.fail("pm-error", { code: "22023", message: "That conversation could not be opened. Please go back and try again." });
          return;
        }
        CUR = d;
        drawThread(); drawList();
        //  While a conversation is open the new-message box is put away (its
        //  emergency words are already above the reply box); a CLOSED one says
        //  to write a new message, so there the box stays.
        C.show("pm-compose", d.thread.state === "closed");
        var box = C.el("pm-thread");
        if (box && box.scrollIntoView) box.scrollIntoView({ block: "start" });
        //  Separately from reading: now the family has seen it, say so.
        if (d.thread.unread) {
          return C.call("parent_thread_mark_read", { p_thread: id }).then(loadList, function () {});
        }
      }, function (e) { C.fail("pm-error", e); });
    }

    function sent(msg) {
      C.el("pm-done").innerHTML = "<h2>Thank you, the office has it.</h2><p>" + msg + "</p>"
        + "<p>The office reads messages on working days, so a reply can take a little while. "
        + "If it cannot wait, please ring <b>" + C.esc(C.OFFICE) + "</b>.</p>";
      C.show("pm-done", true);
    }

    function start(ev) {
      ev.preventDefault();
      if (busy) return;
      C.show("pm-error", false);
      var title = (C.el("pm-title").value || "").replace(/^\s+|\s+$/g, "");
      var text = (C.el("pm-text").value || "").replace(/^\s+|\s+$/g, "");
      if (!title) { inline("pm-inline", "Please give your message a short title, so the office can see what it is about."); return; }
      if (!text) { inline("pm-inline", "Please write your message."); return; }
      inline("pm-inline", "");
      busy = true;
      var btn = C.el("pm-go");
      btn.disabled = true; btn.textContent = "Please wait…";
      C.call("parent_thread_start", { p_subject: title, p_body: text }).then(function (d) {
        if (!d || d.allowed === false) { C.fail("pm-error", { code: "22023", message: "That could not be sent. Please ring the office on " + C.OFFICE + "." }); return; }
        CUR = null; C.show("pm-thread", false); C.show("pm-compose", true);
        C.el("pm-compose").innerHTML = composeHtml("");
        wireCompose();
        sent("Your message &ldquo;" + C.esc(title) + "&rdquo; has been sent.");
        return loadList();
      }, function (e) { C.fail("pm-error", e); })["finally"](function () {
        busy = false;
        var b = C.el("pm-go"); if (b) { b.disabled = false; b.textContent = "Send to the office"; }
      });
    }

    function reply(ev) {
      ev.preventDefault();
      if (busy || !CUR) return;
      C.show("pm-error", false);
      var text = (C.el("pm-rtext").value || "").replace(/^\s+|\s+$/g, "");
      if (!text) { inline("pm-rinline", "Please write your message."); return; }
      inline("pm-rinline", "");
      busy = true;
      var id = CUR.thread.id;
      C.el("pm-rgo").disabled = true;
      C.call("parent_thread_reply", { p_thread: id, p_body: text }).then(function (d) {
        if (!d || d.allowed === false) { C.fail("pm-error", { code: "22023", message: "That could not be sent. Please ring the office on " + C.OFFICE + "." }); return; }
        return loadList().then(function () { return openThread(id); }).then(function () {
          sent("Your reply has been sent.");
        });
      }, function (e) { C.fail("pm-error", e); })["finally"](function () {
        busy = false;
        var b = C.el("pm-rgo"); if (b) b.disabled = false;
      });
    }

    function wireCompose() {
      var f = C.el("pm-new");
      if (f) f.addEventListener("submit", start);
    }

    function mount() {
      var panel = C.el("pm-panel");
      if (!panel) return;
      panel.hidden = false;
      //  From My children ("tell us if this is wrong"): #details opens the box
      //  with a title already in it.
      var pre = /#details/.test(window.location.hash || "")
        ? "Something on my child's record is wrong" : "";
      C.el("pm-list").addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest("[data-id]") : null;
        if (b) openThread(b.getAttribute("data-id"));
      });
      C.el("pm-thread").addEventListener("submit", reply);
      C.el("pm-thread").addEventListener("click", function (e) {
        if (e.target && e.target.id === "pm-back") {
          CUR = null; C.show("pm-thread", false); C.show("pm-compose", true); drawList();
        }
      });
      return loadList().then(function (okay) {
        if (!okay) return;
        C.el("pm-compose").innerHTML = composeHtml(pre);
        C.show("pm-compose", true);
        wireCompose();
        if (!THREADS.length) {
          C.el("pm-compose").insertAdjacentHTML("afterbegin",
            '<p class="pt-sub">You have not written to the office yet.</p>');
        }
      });
    }

    return { mount: mount };
  })();
