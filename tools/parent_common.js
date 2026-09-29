  /* =========================================================================
     WHAT ALL THREE PARENT SCREENS SHARE.

     Prepended to each screen's module by tools/build_parent_screens.py, so the
     three generated files each carry one copy and none of them needs the
     others to be loaded. Browser JavaScript here is ES5 - var and function -
     because the phones some parents use do not parse anything newer, and the
     failure is a blank screen.

     THE REFUSALS A PARENT READS ARE THE DATABASE'S OWN WORDS. db/124 worded
     every refusal that can reach a parent ("You can tell us about tonight...",
     "The madrasah has already recorded that evening..."), so this file shows
     the message it is given for the two codes a deliberate refusal uses, and
     says something plain for anything else. It never shows a technical error:
     a parent who reads "42883 function does not exist" rings the office and
     cannot say what it said.
     ======================================================================= */
  var parentCommon = (function () {
    var OFFICE = "01204 535 997";
    var DAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                "Friday", "Saturday"];
    var MONTHS = ["January", "February", "March", "April", "May", "June",
                  "July", "August", "September", "October", "November",
                  "December"];

    function esc(s) {
      return String(s === null || s === undefined ? "" : s)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;");
    }
    function el(id) { return document.getElementById(id); }
    function show(id, on) { var n = el(id); if (n) n.hidden = !on; }

    //  yyyy-mm-dd -> {y, m, d, dow}. Built from the parts, never from
    //  new Date("2026-09-29"), which is midnight UTC and reads as the
    //  previous evening on a phone set to a timezone west of Greenwich.
    function parts(iso) {
      var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(iso || ""));
      if (!m) return null;
      var y = +m[1], mo = +m[2], d = +m[3];
      return { y: y, m: mo, d: d, dow: new Date(Date.UTC(y, mo - 1, d)).getUTCDay() };
    }
    function longDate(iso) {
      var p = parts(iso);
      return p ? DAYS[p.dow] + " " + p.d + " " + MONTHS[p.m - 1] : "";
    }
    function fullDate(iso) {
      var p = parts(iso);
      return p ? p.d + " " + MONTHS[p.m - 1] + " " + p.y : "";
    }

    //  What the register's four marks are called to a parent. "Excused" is
    //  what the register calls absent-with-a-reason; a parent has no use for
    //  the distinction, only for whether a reason was given.
    function markWord(mark) {
      if (mark === "present") return "Present";
      if (mark === "late") return "Late";
      if (mark === "absent") return "Absent";
      if (mark === "excused") return "Absent, with a reason";
      return "";
    }

    //  Turn whatever a call threw into a sentence a parent can act on.
    function sayError(e) {
      var code = e && e.code;
      var msg = (e && e.message) || "";
      if ((code === "42501" || code === "22023") && msg) return msg;
      if (!code) {
        return "We could not reach the madrasah just now. Please check your "
             + "connection and try again.";
      }
      return "Something went wrong on our side. Please try again in a moment, "
           + "or ring the office on " + OFFICE + ".";
    }
    //  This login is not a parent's (a member of staff who followed the wrong
    //  link, most likely). The database says "not yours" and nothing else.
    function isNotParent(e) {
      return !!e && e.code === "42501" && /not yours/i.test(e.message || "");
    }
    var NOT_PARENT =
      "This login is not set up as a parent's, so there is nothing to show "
      + "here. If you are a member of staff, sign in at the madrasah portal "
      + "instead. If you are a parent, please ring the office on " + OFFICE + ".";

    function call(name, args) {
      return sb.rpc(name, args || {}).then(function (res) {
        if (res.error) throw res.error;
        return res.data;
      });
    }

    //  The one thing every screen asks first: which children are mine.
    function family() { return call("parent_my_children"); }

    function fail(id, e) {
      var box = el(id);
      if (!box) return;
      box.textContent = isNotParent(e) ? NOT_PARENT : sayError(e);
      box.hidden = false;
    }

    return {
      OFFICE: OFFICE, esc: esc, el: el, show: show, longDate: longDate,
      fullDate: fullDate, markWord: markWord, sayError: sayError,
      isNotParent: isNotParent, NOT_PARENT: NOT_PARENT, call: call,
      family: family, fail: fail
    };
  })();
