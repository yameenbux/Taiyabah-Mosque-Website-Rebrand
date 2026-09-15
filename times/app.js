/* ===========================================================================
   Taiyabah Masjid — the prayer timetable, edited by the masjid
   Bolton Central Islamic Society · Registered charity 1041569

   WHY THIS EXISTS
   ---------------
   Until 15 September 2026 the timetable was 365 rows compiled into the
   website. Changing one jamāʿah time meant editing a JSON file, running two
   Python scripts and pushing to GitHub. Nobody on the committee can do that,
   and none of them should have to learn.

   It was also a deadline. The page held 2026 and nothing else, so on 1
   January 2027 the live countdown and the whole timetable would have stopped,
   on the page that is the most common reason anybody opens this website — at
   exactly the point Yameen is meant to have stepped back.

   THE SHAPE OF THIS SCREEN, AND WHY
   ---------------------------------
   Paste, CHECK, save as a draft, then publish. Four steps where one would do,
   on purpose, because the thing being edited is what tells several hundred
   people when to pray.

     * CHECK BEFORE SAVE. The button that writes to the database is disabled
       until the paste has been read and found sound. Everything that can be
       wrong is listed, by row number, in the words a person would use.

     * A DRAFT IS INVISIBLE. Saving does not publish. The website never reads
       an unpublished year, so somebody can paste 2027 in during Ramadan, look
       at it, come back a week later and publish it.

     * PUBLISHING IS ITS OWN DECISION, one button, and the database refuses it
       unless the year is complete — every day of that year, leap years
       included. Half a timetable is worse than none.

   The same rules are enforced again in Postgres, in db/039_prayer_times.sql.
   Nothing here is a security control: it is JavaScript in a browser and can
   be edited by anybody who opens the developer tools. It is here so that a
   committee member gets told what is wrong in plain English instead of a
   constraint violation.

   WHAT THE SPREADSHEET HAS TO LOOK LIKE
   -------------------------------------
   One row a day, thirteen columns, in the order the masjid's own printed
   timetable already uses. Dates in either British or ISO order — 01/02/2027
   is read as 1 February, because this is a masjid in Bolton and that is what
   its spreadsheet will say.
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
     THE CLAIM
     ======================================================================= */
  /* ------------------------------------------------------------------ the
     TIMETABLE MODULE. Everything on this screen, kept in one place so that if
     it throws, the sign-in shell around it survives — see renderApp. */
  var timetable = (function () {
    "use strict";

    var HHMM = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
    var parsed = null;          // the rows the Save button will send

    function txt(id, v) { var n = el(id); if (n) n.textContent = v; }
    function note(id, msg) {
      var n = el(id); if (!n) return;
      if (!msg) { n.hidden = true; n.textContent = ""; return; }
      n.textContent = msg; n.hidden = false;
    }

    /*  A DATE, THE WAY A SPREADSHEET WILL ACTUALLY WRITE IT.

        Accepts 2027-01-31 and 31/01/2027 and 31-01-2027. DAY FIRST when it is
        ambiguous, because this is a masjid in Bolton and 01/02/2027 means the
        first of February here. Getting that backwards would shift the entire
        timetable by up to eleven months and every individual row would still
        look perfectly valid, which is why it is stated rather than assumed. */
    function readDate(v) {
      v = String(v || "").trim();
      var m = /^(\d{4})[-\/](\d{1,2})[-\/](\d{1,2})$/.exec(v);
      if (m) return { y: +m[1], m: +m[2], d: +m[3] };
      m = /^(\d{1,2})[-\/](\d{1,2})[-\/](\d{4})$/.exec(v);
      if (m) return { y: +m[3], m: +m[2], d: +m[1] };
      return null;
    }

    /*  CSV, but the kind a spreadsheet exports: quoted fields, commas inside
        them. The Jumuʿah column is "13:15,14:00" — a comma INSIDE a value —
        so a naive split(",") gets every Friday wrong and only on Fridays,
        which is the sort of bug that reaches production. */
    function splitCsvLine(line) {
      var out = [], cur = "", q = false, i;
      for (i = 0; i < line.length; i++) {
        var c = line[i];
        if (q) {
          if (c === '"' && line[i + 1] === '"') { cur += '"'; i++; }
          else if (c === '"') q = false;
          else cur += c;
        } else if (c === '"') q = true;
        else if (c === ",") { out.push(cur); cur = ""; }
        else cur += c;
      }
      out.push(cur);
      return out.map(function (x) { return x.trim(); });
    }

    function daysIn(year) {
      return (new Date(year, 1, 29).getMonth() === 1) ? 366 : 365;
    }

    /*  Reads the paste and says everything that is wrong with it. Returns
        { rows, year, problems } — never throws, because a person pasting a
        spreadsheet should get a list, not a stack trace. */
    function read(text, wantYear) {
      var problems = [], rows = [], seen = {}, years = {};
      var lines = String(text || "").split(/\r?\n/)
                    .filter(function (l) { return l.trim() !== ""; });

      if (!lines.length) return { rows: [], year: wantYear, problems: ["There is nothing pasted in."] };

      //  A heading row, if there is one. Detected by it not starting with
      //  something that reads as a date.
      if (!readDate(splitCsvLine(lines[0])[0])) lines.shift();

      lines.forEach(function (line, n) {
        var where = "Row " + (n + 1);
        var f = splitCsvLine(line);
        if (f.length < 12) {
          problems.push(where + " has " + f.length + " columns; it needs at least 12.");
          return;
        }
        var d = readDate(f[0]);
        if (!d) { problems.push(where + ": “" + f[0] + "” is not a date."); return; }
        years[d.y] = (years[d.y] || 0) + 1;

        var times = f.slice(2, 12);
        var badTime = null;
        times.forEach(function (t, k) { if (!HHMM.test(t) && badTime === null) badTime = [t, k]; });
        if (badTime) {
          problems.push(where + " (" + f[0] + "): “" + badTime[0] +
            "” is not a 24-hour time. It should look like 06:35.");
          return;
        }
        //  The order the prayers actually happen in. A transposed column in a
        //  spreadsheet is the mistake somebody will really make, and it is
        //  invisible to the eye in a wall of 365 rows.
        if (!(times[0] < times[2] && times[2] < times[3] &&
              times[3] < times[5] && times[5] < times[7] && times[7] < times[8])) {
          problems.push(where + " (" + f[0] + "): the times are out of order — " +
            "Fajr, sunrise, Zuhr, Asr, Maghrib then Isha. Two columns may be swapped.");
          return;
        }
        /*  THE JUMUʿAH COLUMN IS TWO TIMES WITH A COMMA BETWEEN THEM, which
            means the value itself contains the delimiter. A spreadsheet
            exports that quoted — "13:15,14:00" — and splitCsvLine handles it.
            A person pasting by hand will not quote it, and it arrives as two
            separate fields instead.

            Both are accepted, by joining everything from column 13 onward
            back together. Refusing the unquoted form would reject EVERY
            FRIDAY and nothing else, which is exactly the sort of fault that
            gets diagnosed as "the upload is broken" a month later. */
        var jum = f.slice(12).join(",").trim().replace(/,+$/, "");
        if (jum && !/^([01][0-9]|2[0-3]):[0-5][0-9],([01][0-9]|2[0-3]):[0-5][0-9]$/.test(jum)) {
          problems.push(where + " (" + f[0] + "): the Jumuʿah column should be two " +
            "times separated by a comma, like 13:15,14:00.");
          return;
        }
        //  Keyed on the YEAR as well. Without it, 1 Jan 2027 and 1 Jan 2028
        //  in one paste are reported as the same day listed twice, which
        //  sends somebody looking for a duplicate that is not there. The real
        //  problem — two years at once — is reported separately below.
        var key = d.y + "-" + d.m + "-" + d.d;
        if (seen[key]) { problems.push(where + ": " + f[0] + " is listed twice."); return; }
        seen[key] = true;

        rows.push([d.m, d.d, (f[1] || "").trim(),
                   times[0], times[1], times[2], times[3], times[4],
                   times[5], times[6], times[7], times[8], times[9], jum]);
      });

      var found = Object.keys(years).map(Number);
      if (found.length > 1) {
        problems.push("The paste covers more than one year (" + found.join(", ") +
          "). Upload one year at a time.");
      }
      /*  THE DATES DECIDE THE YEAR, NOT THE BOX.
          This was `wantYear || found[0]`, so the number in the Year box won
          outright. Paste or upload the 2026 timetable while the box still
          says 2027 — and it defaults to next year, so it usually does — and
          365 days of 2026 times were saved as 2027, silently. Every row
          looked right, the day count was right, the report said 2027 and
          meant it. The rows carry a month and a day and no year at all, so
          nothing downstream could have caught it either.

          The file is the truth now, and a box that disagrees is a complaint
          rather than an override. */
      var year = found.length === 1 ? found[0] : (wantYear || found[0]);
      if (wantYear && found.length === 1 && wantYear !== found[0]) {
        problems.push("The Year box says " + wantYear + " but every date in " +
          "this timetable is " + found[0] + ". Change the box to " + found[0] +
          ", or check you have the right file.");
      }
      return { rows: rows, year: year, problems: problems };
    }

    function reportHtml(res) {
      var need = res.year ? daysIn(res.year) : null;
      var bits = [];
      bits.push("<strong>" + res.rows.length + "</strong> day" +
                (res.rows.length === 1 ? "" : "s") + " read" +
                (res.year ? " for <strong>" + res.year + "</strong>" : "") + ".");
      if (need && res.rows.length !== need && !res.problems.length) {
        bits.push(" That year has <strong>" + need + "</strong> days, so this " +
          "can be saved as a draft but not published yet.");
      }
      if (res.problems.length) {
        bits.push("<ul>" + res.problems.slice(0, 12).map(function (p) {
          return "<li>" + esc(p) + "</li>";
        }).join("") + "</ul>");
        if (res.problems.length > 12) {
          bits.push("<p>&hellip;and " + (res.problems.length - 12) + " more.</p>");
        }
      }
      return bits.join("");
    }

    function esc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;")
        .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    function drawYears(list) {
      var box = el("tt-years");
      if (!box) return;
      if (!list.length) {
        box.innerHTML = "<p class=\"lede\">No timetable has been uploaded yet. " +
          "The website is showing the year built into the page.</p>";
        return;
      }
      box.innerHTML = list.map(function (y) {
        var need = daysIn(y.year);
        var whole = y.days === need;
        return '<div class="tt-year">' +
          '<span class="yr">' + esc(y.year) + "</span>" +
          '<span class="tt-pill ' + (y.published ? "tt-live" : "tt-draft") + '">' +
          (y.published ? "On the website" : "Draft") + "</span>" +
          '<span class="meta">' + y.days + " of " + need + " days" +
          (whole ? "" : " — not complete") + "</span>" +
          '<span class="spacer"></span>' +
          '<button type="button" class="btn btn-ghost tt-toggle" data-year="' +
          esc(y.year) + '" data-to="' + (y.published ? "0" : "1") + '"' +
          (!y.published && !whole ? " disabled" : "") + ">" +
          (y.published ? "Take off the website" : "Publish") + "</button>" +
          "</div>";
      }).join("");
    }

    function loadYears() {
      return sb.rpc("prayer_years_list").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        drawYears(res.data || []);
      });
    }

    /*  THE EDITOR'S OWN WIRING, separated from mount() deliberately.

        This is the paste box, the Check button and the Save button — the
        part with the rule that matters: NOTHING IS SAVEABLE UNTIL IT HAS
        BEEN CHECKED. mount() used to contain all of it, and mount() runs
        only after a real sign-in, so a test could never reach the rule. It
        looked tested and was not: the Save button is disabled in the markup
        as well, so a test that merely loads the page and reads the button
        sees "disabled" whether the logic is there or has been deleted. That
        is worse than no test, because it reports a pass either way.

        Splitting it out costs nothing at runtime — mount() calls it — and
        makes the rule reachable. It attaches listeners and reads the DOM;
        it opens no session and fetches nothing, and Save still goes through
        save_prayer_year, which the database refuses to anyone who is not a
        verified admin. */
    /* =====================================================================
       READING AN EXCEL FILE

       The office keeps the year in a spreadsheet. Asking somebody to open it,
       Save As, pick CSV, find the file again and paste it in is five chances
       to do the wrong thing with the one document several hundred people set
       their day by — so the file goes straight in.

       NO LIBRARY, AND THAT IS DELIBERATE. SheetJS is about 900 KB to read a
       file this screen opens a few times a year, and this project vendors
       rather than reaching for a CDN on principle: no third party gets to see
       what the masjid's office is doing. An .xlsx is a ZIP of XML files, and
       the browser will inflate a stream on its own, so the whole reader is
       the code below.

       WHAT PROTECTS THE PRAYER TIMES. This converts a spreadsheet into
       exactly the CSV somebody would otherwise have pasted, drops it in the
       paste box, and stops. EVERY check still runs: the HH:MM test, the
       prayer-order test that catches two transposed columns, the duplicate-day
       test, the day count, the year check. Nothing here can put a time on the
       website that the paste route could not, and a misread cell fails loudly
       rather than quietly.
    ===================================================================== */

    /*  Just enough ZIP to get four files out of an .xlsx.

        Entries are found through the central directory at the end of the
        file, NOT by scanning for local headers: a local header records a
        length of zero when the writer streamed the file, and half the
        spreadsheet software in the world streams. */
    function unzip(buf) {
      var v = new DataView(buf), u = new Uint8Array(buf), i;

      //  End of central directory. Scanned backwards because a ZIP comment
      //  can follow it, and 22 is its length with no comment.
      var eocd = -1;
      for (i = u.length - 22; i >= 0 && i > u.length - 66000; i--) {
        if (v.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
      }
      if (eocd < 0) throw new Error("not-a-zip");

      var count = v.getUint16(eocd + 10, true);
      var at = v.getUint32(eocd + 16, true);
      var out = {};

      for (i = 0; i < count; i++) {
        if (v.getUint32(at, true) !== 0x02014b50) throw new Error("not-a-zip");
        var method = v.getUint16(at + 10, true);
        var csize  = v.getUint32(at + 20, true);
        var nlen   = v.getUint16(at + 28, true);
        var mlen   = v.getUint16(at + 30, true);
        var klen   = v.getUint16(at + 32, true);
        var lho    = v.getUint32(at + 42, true);
        var name   = new TextDecoder().decode(u.subarray(at + 46, at + 46 + nlen));

        //  The local header repeats the name and extra field, and its extra
        //  field is NOT always the same length as the central one.
        var lnlen = v.getUint16(lho + 26, true);
        var lxlen = v.getUint16(lho + 28, true);
        var start = lho + 30 + lnlen + lxlen;

        out[name] = { method: method, bytes: u.subarray(start, start + csize) };
        at += 46 + nlen + mlen + klen;
      }
      return out;
    }

    /*  Stored (0) or deflated (8) — the only two methods anything writes.
        DecompressionStream does the inflating, so there is no inflate
        implementation in this file to get wrong. */
    function inflate(entry) {
      if (!entry) return Promise.resolve("");
      if (entry.method === 0) {
        return Promise.resolve(new TextDecoder().decode(entry.bytes));
      }
      if (entry.method !== 8) return Promise.reject(new Error("zip-method"));
      if (typeof DecompressionStream === "undefined") {
        return Promise.reject(new Error("no-decompressor"));
      }
      //  A copy, because the view is onto the whole file's buffer and
      //  Response would otherwise read past the end of this entry.
      var copy = entry.bytes.slice();
      var ds = new DecompressionStream("deflate-raw");
      return new Response(new Blob([copy]).stream().pipeThrough(ds)).text();
    }

    function xml(text) {
      //  Parsed as XML, not HTML: an XML document runs no script and has no
      //  innerHTML. The only things read out of it are text nodes.
      var d = new DOMParser().parseFromString(text, "application/xml");
      if (d.getElementsByTagName("parsererror").length) throw new Error("bad-xml");
      return d;
    }

    //  "BC12" -> 54. Needed because a row omits empty cells entirely, so the
    //  only way to know which column a value is in is its reference.
    function colOf(ref) {
      var n = 0;
      for (var i = 0; i < ref.length; i++) {
        var c = ref.charCodeAt(i);
        if (c < 65 || c > 90) break;
        n = n * 26 + (c - 64);
      }
      return n - 1;
    }

    /*  Excel keeps a time as a fraction of a day and a date as a count of
        days from 1899-12-30. Neither looks like anything until it is
        converted, and getting it wrong is the one failure that would put a
        plausible-looking wrong time on the website — which is why the result
        goes back through the same checker as a paste.

        The split is by magnitude and it is safe: a time is under 1, and a
        date from 2020 onwards is over 43000. Nothing in a prayer timetable
        lands between. */
    function fromSerial(n) {
      if (n > 0 && n < 1) {
        var mins = Math.round(n * 1440) % 1440;
        return ("0" + Math.floor(mins / 60)).slice(-2) + ":" +
               ("0" + (mins % 60)).slice(-2);
      }
      if (n >= 20000 && n < 80000) {
        var d = new Date(Math.round(n) * 86400000 + Date.UTC(1899, 11, 30));
        return d.getUTCFullYear() + "-" +
               ("0" + (d.getUTCMonth() + 1)).slice(-2) + "-" +
               ("0" + d.getUTCDate()).slice(-2);
      }
      //  A whole number of minutes past midnight written as a plain number,
      //  and anything else, is handed back as it was for the checker to
      //  reject rather than guessed at.
      return String(n);
    }

    /*  The sheet, as a grid of strings. Returns { rows } or throws a short
        code that readFile() turns into a sentence. */
    function sheetToRows(sheetXml, shared) {
      var doc = xml(sheetXml);
      var rowEls = doc.getElementsByTagName("row");
      var rows = [];

      for (var r = 0; r < rowEls.length; r++) {
        var cells = rowEls[r].getElementsByTagName("c");
        var line = [];
        for (var c = 0; c < cells.length; c++) {
          var cell = cells[c];
          var at = colOf(cell.getAttribute("r") || "");
          var t = cell.getAttribute("t");
          var val = "";

          if (t === "s") {
            var vs = cell.getElementsByTagName("v")[0];
            var idx = vs ? parseInt(vs.textContent, 10) : -1;
            val = (idx >= 0 && shared[idx] != null) ? shared[idx] : "";
          } else if (t === "inlineStr") {
            var ts = cell.getElementsByTagName("t");
            for (var k = 0; k < ts.length; k++) val += ts[k].textContent;
          } else {
            var v2 = cell.getElementsByTagName("v")[0];
            var raw = v2 ? v2.textContent : "";
            if (raw !== "" && t !== "str" && !isNaN(Number(raw))) {
              val = fromSerial(Number(raw));
            } else {
              val = raw;
            }
          }
          if (at >= 0) line[at] = String(val).trim();
        }
        //  Holes become empty strings so the columns line up.
        for (var f = 0; f < line.length; f++) if (line[f] == null) line[f] = "";
        rows.push(line);
      }
      return rows;
    }

    /*  Rows to the CSV the paste box expects. A field containing a comma is
        quoted — the Jumuʿah column is two times with a comma between them,
        and this is the same shape a spreadsheet exports. */
    function rowsToCsv(rows) {
      return rows.map(function (line) {
        return line.map(function (f) {
          f = f == null ? "" : String(f);
          return /[",\n]/.test(f) ? '"' + f.replace(/"/g, '""') + '"' : f;
        }).join(",");
      }).join("\n");
    }

    var FILE_TROUBLE = {
      "not-a-zip":
        "That does not look like an Excel file. If it is an older .xls, open " +
        "it and use File → Save As to make it .xlsx, or save it as CSV and " +
        "paste it in below.",
      "zip-method":
        "That spreadsheet is compressed in a way this page cannot open. Open " +
        "it and save it again as .xlsx.",
      "no-decompressor":
        "This browser cannot open a spreadsheet. Save the timetable as CSV and " +
        "paste it into the box below instead.",
      "bad-xml":
        "That spreadsheet could not be read. Open it, save it again as .xlsx, " +
        "and try once more.",
      "no-sheet":
        "There is no worksheet in that file.",
      "no-dates":
        "No column in that spreadsheet looks like a date. The timetable needs " +
        "one row a day with the date in the first column — check you have " +
        "opened the right sheet, and that there are no merged cells across " +
        "the top.",
      "too-few":
        "That sheet has fewer than twenty rows of times in it. A year needs " +
        "one row a day."
    };

    /*  The whole job: bytes in, CSV out. Refuses rather than half-reads —
        anything it cannot make sense of is handed back as a sentence, and
        nothing reaches the paste box. A part-read timetable that looks
        complete is how a wrong prayer time gets published. */
    function readWorkbook(buf) {
      var files;
      try { files = unzip(buf); }
      catch (e) { return Promise.reject(e); }

      var sheetNames = Object.keys(files).filter(function (n) {
        return /^xl\/worksheets\/sheet\d+\.xml$/.test(n);
      }).sort();
      if (!sheetNames.length) return Promise.reject(new Error("no-sheet"));

      return inflate(files["xl/sharedStrings.xml"]).then(function (ssText) {
        var shared = [];
        if (ssText) {
          var si = xml(ssText).getElementsByTagName("si");
          for (var i = 0; i < si.length; i++) {
            //  A string can be split across several <t> runs when part of it
            //  is formatted differently. Joined, or "13:15,14:00" arrives as
            //  "13:15".
            var ts = si[i].getElementsByTagName("t"), str = "";
            for (var k = 0; k < ts.length; k++) str += ts[k].textContent;
            shared.push(str);
          }
        }

        /*  EVERY SHEET IS TRIED, not just the first. A workbook often opens
            on a summary tab with the year on another, and "sheet1.xml" is
            the first sheet as written rather than the one anybody looks at.
            The one with the most rows the checker recognises wins. */
        return sheetNames.reduce(function (chain, name) {
          return chain.then(function (best) {
            return inflate(files[name]).then(function (text) {
              var rows;
              try { rows = sheetToRows(text, shared); }
              catch (e) { return best; }
              var dated = rows.filter(function (line) {
                return line.length >= 12 && readDate(line[0]);
              }).length;
              return (!best || dated > best.dated)
                ? { rows: rows, dated: dated, name: name } : best;
            });
          });
        }, Promise.resolve(null));
      }).then(function (best) {
        if (!best || !best.dated) throw new Error("no-dates");
        if (best.dated < 20) throw new Error("too-few");
        return { csv: rowsToCsv(best.rows), days: best.dated };
      });
    }

    function wireEditor() {
      var yearBox = el("tt-year");
      if (yearBox && !yearBox.value) yearBox.value = new Date().getFullYear() + 1;

      /*  The spreadsheet, read here and checked below. It fills the paste box
          and then presses Check for the person, so what they see next is the
          same report a paste produces — same rules, same wording, same Save
          button that stays disabled until it is clean.

          On any trouble the paste box is left ALONE. Half a timetable in the
          box, looking finished, is the one outcome worth engineering against:
          the checker would pass it, the day count would be short, and short
          is exactly what somebody clicks past at the end of a long evening. */
      var fileBox = el("tt-file");
      if (fileBox) fileBox.addEventListener("change", function () {
        var f = this.files && this.files[0];
        note("tt-error", ""); note("tt-ok", "");
        el("tt-file-name").textContent = "";
        if (!f) return;

        if (!/\.xlsx$/i.test(f.name)) {
          note("tt-error", FILE_TROUBLE["not-a-zip"]);
          this.value = "";
          return;
        }
        //  A year of prayer times is a few tens of kilobytes. Anything of a
        //  size that could lock the browser up is refused before it is read.
        if (f.size > 8 * 1024 * 1024) {
          note("tt-error", "That file is " + Math.round(f.size / 1048576) +
               " MB, which is far larger than a timetable. Check it is the " +
               "right file.");
          this.value = "";
          return;
        }

        var input = this;
        el("tt-file-name").textContent = "Reading " + f.name + "\u2026";

        f.arrayBuffer().then(readWorkbook).then(function (out) {
          el("tt-paste").value = out.csv;

          /*  The Year box is set FROM THE FILE, and the year is said out loud
              on screen. The box defaults to next year, so leaving it alone
              would mean every upload of the current year's timetable is met
              with a complaint about a mismatch the person did not make — and
              a complaint somebody sees on every single upload is one they
              stop reading. Saying "365 days read for 2026" is the honest
              version: they can see which year went in. */
          var peek = read(out.csv, null);
          if (peek.year) el("tt-year").value = peek.year;

          el("tt-file-name").textContent = f.name + " \u2014 " + out.days +
            " day" + (out.days === 1 ? "" : "s") + " read" +
            (peek.year ? " for " + peek.year : "");
          //  Straight into the ordinary check, so the person never has to
          //  know the file took a different road in.
          el("tt-check").click();
        }).catch(function (e) {
          var why = FILE_TROUBLE[e && e.message];
          note("tt-error", why ||
               "That spreadsheet could not be read. Save it as CSV and paste " +
               "it into the box below instead.");
          el("tt-file-name").textContent = "";
          //  Cleared so choosing the SAME file again still fires a change
          //  event — otherwise a second attempt after fixing the file does
          //  nothing at all and looks like the page has frozen.
          input.value = "";
        });
      });

      el("tt-check").addEventListener("click", function () {
        note("tt-error", ""); note("tt-ok", "");
        var res = read(el("tt-paste").value, Number(el("tt-year").value) || null);
        parsed = res.problems.length ? null : res;
        var box = el("tt-report");
        box.innerHTML = reportHtml(res);
        box.hidden = false;
        box.classList.toggle("tt-bad", res.problems.length > 0);
        el("tt-save").disabled = !parsed || !parsed.rows.length;
        if (parsed && res.year) el("tt-year").value = res.year;
      });

      el("tt-paste").addEventListener("input", function () {
        //  Editing the paste invalidates the check. Without this, somebody
        //  checks a good year, pastes a bad one over it and the Save button
        //  is still enabled from the previous check.
        parsed = null;
        el("tt-save").disabled = true;
        el("tt-report").hidden = true;
      });

      el("tt-save").addEventListener("click", function () {
        if (!parsed) return;
        var btn = el("tt-save");
        busy(btn, true, "Save as a draft");
        note("tt-error", ""); note("tt-ok", "");
        sb.rpc("save_prayer_year", {
          p_year: parsed.year, p_rows: parsed.rows,
          p_publish: false, p_note: ""
        }).then(function (res) {
          busy(btn, false, "Save as a draft");
          if (res.error) { note("tt-error", res.error.message); return; }
          var d = res.data || {};
          note("tt-ok", "Saved " + d.days + " days for " + d.year +
            " as a draft. Nobody can see it yet — press Publish below when " +
            "you are happy with it.");
          el("tt-save").disabled = true;
          return loadYears();
        }).catch(function (e) {
          busy(btn, false, "Save as a draft");
          note("tt-error", e.message || String(e));
        });
      });

      return true;
    }

    function mount(identity) {
      wireEditor();

      el("tt-years").addEventListener("click", function (ev) {
        var btn = ev.target.closest(".tt-toggle");
        if (!btn) return;
        var year = Number(btn.getAttribute("data-year"));
        var to = btn.getAttribute("data-to") === "1";
        if (!to && !window.confirm(
              "Take the " + year + " timetable off the website?\n\n" +
              "Visitors will fall back to the year built into the page.")) return;
        btn.disabled = true;
        note("tt-error", ""); note("tt-ok", "");
        sb.rpc("set_prayer_year_published", { p_year: year, p_published: to })
          .then(function (res) {
            if (res.error) { note("tt-error", res.error.message); return loadYears(); }
            note("tt-ok", to
              ? year + " is now the timetable on the website."
              : year + " has been taken off the website.");
            return loadYears();
          })
          .catch(function (e) { note("tt-error", e.message || String(e)); });
      });

      return loadYears().catch(function (e) {
        note("tt-error", "Couldn't read the years: " + (e.message || e));
      });
    }

    //  Exported for the tests: the parser is the part worth testing and it
    //  needs no browser, no database and nobody signed in.
    return { mount: mount, _wire: wireEditor, _read: read, _readDate: readDate,
             _readWorkbook: readWorkbook, _rowsToCsv: rowsToCsv,
             _fromSerial: fromSerial, _colOf: colOf,
             _splitCsvLine: splitCsvLine, _daysIn: daysIn };
  })();

  /*  THE PARSER, REACHABLE FROM A TEST.

      Everything on this page lives inside one closure, which is right — but
      it also means the one piece genuinely worth testing cannot be reached.
      The parser decides what reaches the database, so it is tested against
      every wrong spreadsheet anybody is likely to paste: a time written
      "6.36", two columns swapped, a day listed twice, two years at once.

      Four of the five exposed are PURE FUNCTIONS — no session, no data, no
      network, nothing that writes. Reading them tells an attacker what a CSV
      looks like, which is also written on the screen above in plain English.

      The fifth, wire(), attaches the editor's own listeners so a test can
      exercise the check-before-save rule. It is not pure and it is worth
      being plain about: calling it on a page where nobody is signed in wires
      up a Save button whose click calls save_prayer_year — which the database
      refuses to anybody who is not a verified admin with two-step. It hands
      out no access that a signed-in admin does not already have, and none at
      all to anybody else. The check is in the database, not in this file. */
  window.__TIMETABLE_PARSER = {
    readWorkbook: timetable._readWorkbook,
    rowsToCsv:    timetable._rowsToCsv,
    fromSerial:   timetable._fromSerial,
    colOf:        timetable._colOf,
    read: timetable._read,
    wire: timetable._wire,
    readDate: timetable._readDate,
    splitCsvLine: timetable._splitCsvLine,
    daysIn: timetable._daysIn
  };

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.
    if (window.AdminShell) {
      AdminShell.mount({
        current: 'times',
        title:   'Prayer timetable',
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
    try { timetable.mount(identity); } catch (e) {
      if (window.console) console.warn("timetable panel unavailable:", e);
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
