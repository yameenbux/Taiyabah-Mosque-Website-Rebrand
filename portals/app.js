/* ===========================================================================
   Taiyabah Masjid — masjid administration
   Bolton Central Islamic Society · Registered charity 1041569

   A signpost, and nothing more.

   What this page does: reads who is signed in, reads their roles from
   user_roles, and — if they hold `admin` — lists the areas they can open.

   What this page deliberately does NOT do:

     - It holds no data. It reads no booking, no application, no child's
       record. If someone got past every check here, they would see a list of
       links and nothing else.

     - It does not ask for an authenticator code. The account area has no
       two-step step, on purpose: making somebody set up an authenticator to
       buy a jar of honey loses the sale. Each portal asks for the code when
       it is opened, and — from migration 011 — the database refuses to hand
       over anything sensitive to a session that has not passed it. That is
       where the real boundary lives, not here.

     - It does not decide anything from what the browser says. The role comes
       from user_roles under RLS. A customer asking that table gets nothing
       back, because the "read own" policy returns their own rows and they
       have none.

   Fails closed. If the role lookup errors — the network, a policy change,
   anything — this page shows the "no access" card rather than guessing. A
   signpost that guesses is worse than no signpost.
   =========================================================================== */
(function () {
  "use strict";

  var cfg = window.TAIYABAH_CONFIG || {};
  var el  = function (id) { return document.getElementById(id); };

  var VIEWS = ["view-loading", "view-signedout", "view-noaccess", "view-list"];
  function setError(id, message) {
    var box = el(id);
    if (!box) return;
    if (!message) { box.hidden = true; box.textContent = ""; return; }
    box.textContent = message;
    box.hidden = false;
  }

  function show(view) {
    VIEWS.forEach(function (v) {
      var n = el(v);
      if (n) n.hidden = v !== view;
    });
  }

  // The list of areas used to live here as a hard-coded array. It does not
  // any more: drawAreas() builds each card from what admin_dashboard()
  // returned, so an area appears because the DATABASE said this account can
  // see it, not because the browser held a list saying so. Dead code kept
  // around as "documentation" is how a file rots, so it is gone rather than
  // commented out — the shape it had is in git.


  // --- config guard ---------------------------------------------------------
  if (!cfg.SUPABASE_URL || cfg.SUPABASE_URL.indexOf("PASTE_") === 0) {
    show("view-signedout");
    if (window.console) console.error(
      "portals/config.js still has placeholder values in it.");
    return;
  }

  // The Supabase dashboard shows the URL with /rest/v1/ on the end. Pasting it
  // verbatim has broken this twice before, so normalise to the bare origin.
  var apiUrl = String(cfg.SUPABASE_URL || "").trim()
                 .replace(/\/+$/, "").replace(/\/rest\/v1$/, "");

  var sb = window.supabase.createClient(apiUrl, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
  });

  function signOutTo(where) {
    return function () {
      sb.auth.signOut().then(function () { window.location.href = where; })
                       .catch(function () { window.location.href = where; });
    };
  }
  el("no-signout").addEventListener("click", signOutTo("../account/"));
  el("list-signout").addEventListener("click", signOutTo("../account/"));

  // --- who is this? ---------------------------------------------------------
  function loadIdentity() {
    return sb.auth.getUser().then(function (res) {
      var user = res.data && res.data.user;
      if (!user) throw new Error("No active session.");
      return Promise.all([
        sb.from("profiles").select("full_name, email").eq("id", user.id).maybeSingle(),
        sb.from("user_roles").select("role").eq("user_id", user.id)
      ]).then(function (out) {
        // A failed role query must NOT look like "no roles". Treat it as a
        // refusal, because that is the safe reading of "I don't know".
        if (out[1].error) throw new Error("user_roles — " + out[1].error.message);
        return {
          user:    user,
          profile: out[0].data || {},
          roles:   (out[1].data || []).map(function (r) { return r.role; })
        };
      });
    });
  }

  function nameOf(identity) {
    return identity.profile.full_name ||
           (identity.user.user_metadata && identity.user.user_metadata.full_name) ||
           identity.user.email;
  }

  function noAccess(identity, why) {
    if (identity) {
      el("no-name").textContent  = nameOf(identity);
      el("no-email").textContent = identity.user.email;
    }
    if (why) el("no-why").textContent = why;
    show("view-noaccess");
  }

  /* =========================================================================
     THE DASHBOARD

     Everything below draws what admin_dashboard() returned. It decides
     NOTHING: which areas appear, which counts are filled in and whether Gift
     Aid or the staff figures come back at all is settled in the database by
     the role check at the top of that function. The browser asking for less
     would be the browser deciding what it is allowed to see.

     One call, not eight. A page that shows five panels and one silent blank
     is worse than a page that says it could not load — so there is one
     request and one error path, and the error replaces the dashboard rather
     than sitting quietly above a half-drawn one.
     ===================================================================== */

  function esc(v) {
    return String(v === null || v === undefined ? "" : v)
      .replace(/[&<>"']/g, function (c) {
        return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;",
                  '"': "&quot;", "'": "&#39;" })[c];
      });
  }

  function money(p) {
    if (p === null || p === undefined) return "—";
    var pounds = p / 100;
    return "£" + (pounds % 1 === 0
      ? pounds.toLocaleString("en-GB")
      : pounds.toLocaleString("en-GB", { minimumFractionDigits: 2 }));
  }

  var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  var DAYS   = ["Sunday","Monday","Tuesday","Wednesday","Thursday","Friday","Saturday"];

  // Built from the parts rather than toLocaleString: the office reads this in
  // Bolton and the browser's locale is not a promise.
  function shortDate(iso) {
    if (!iso) return "—";
    var d = new Date(iso);
    if (isNaN(d)) return "—";
    return d.getDate() + " " + MONTHS[d.getMonth()];
  }

  function clock(d) {
    return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2);
  }

  // "Today 14:20" / "Fri 16:48" / "3 Sep 09:12" — the office is scanning for
  // when, and a full timestamp on every row is harder to scan, not easier.
  function logWhen(iso) {
    if (!iso) return "—";
    var d = new Date(iso);
    if (isNaN(d)) return "—";
    var now = new Date();
    var sameDay = d.toDateString() === now.toDateString();
    if (sameDay) return "Today " + clock(d);
    var days = Math.round((now - d) / 86400000);
    if (days <= 6) return DAYS[d.getDay()].slice(0, 3) + " " + clock(d);
    return shortDate(iso) + " " + clock(d);
  }

  // How long is left on a hold, in words. The number that matters is minutes:
  // once it is gone the date has released itself and the hirer starts again.
  function leftOn(iso) {
    if (!iso) return "";
    var mins = Math.floor((new Date(iso) - Date.now()) / 60000);
    if (isNaN(mins)) return "";
    if (mins <= 0) return "expired";
    if (mins === 1) return "expires in 1 minute";
    return "expires in " + mins + " minutes";
  }

  function sinceWhen(iso) {
    if (!iso) return "";
    var days = Math.floor((Date.now() - new Date(iso)) / 86400000);
    if (isNaN(days)) return "";
    if (days <= 0) return "came in today";
    if (days === 1) return "waiting 1 day";
    return "waiting " + days + " days";
  }

  var ICON = {
    clock:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 12V7M12 12l3.5 2.2"/></svg>',
    phone:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 16.9v3a2 2 0 01-2.2 2 19.8 19.8 0 01-8.6-3.1 19.5 19.5 0 01-6-6A19.8 19.8 0 012.1 4.2 2 2 0 014.1 2h3a2 2 0 012 1.7c.1.9.3 1.8.6 2.7a2 2 0 01-.5 2.1L8 9.7a16 16 0 006 6l1.2-1.2a2 2 0 012.1-.5c.9.3 1.8.5 2.7.6a2 2 0 011.7 2z"/></svg>',
    basket: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3.2 9h17.6l-1.9 10.2a2 2 0 01-2 1.8H7.1a2 2 0 01-2-1.8L3.2 9z"/><path d="M8.4 9l2.9-5.2M15.6 9l-2.9-5.2"/></svg>',
    heart:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21s-7-4.35-10-9.3C.5 8.1 2.1 4.5 5.6 4c2-.3 3.7.6 4.9 2.3.4.5 1.1 2.1 1.5 2.1s1.1-1.6 1.5-2.1C14.7 4.6 16.4 3.7 18.4 4c3.5.5 5.1 4.1 3.6 7.7C19 16.65 12 21 12 21z"/></svg>',
    hall:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 21h18M5 21V8l7-4 7 4v13"/><path d="M10 21v-5h4v5"/></svg>',
    book:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 19.5A2.5 2.5 0 016.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 014 19.5v-15A2.5 2.5 0 016.5 2z"/></svg>',
    people: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="8" r="3.2"/><path d="M2.5 20c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6"/><circle cx="17.5" cy="9" r="2.4"/><path d="M15.7 14.3c2.7.3 4.8 2.3 4.8 5.2"/></svg>',
    lock:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="10" rx="2"/><path d="M7 11V7a5 5 0 0110 0v4"/></svg>',
    tick:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>',
    crane:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 21V5l9-2v4"/><path d="M4 9h9"/><path d="M13 7h7l-2.5 4H13z"/><path d="M17 11v4"/><path d="M15 15h4l-1 3h-2z"/></svg>'
  };

  var WHERE = { venue: "../venue/", volunteers: "../volunteers/",
                giftaid: "../giftaid/", courses: "../courses/" };

  function drawNeeds(needs) {
    var box = el("dash-needs");
    if (!box) return;

    // THE CALM STATE IS A SENTENCE, NOT A GRID OF NOUGHTS. Most days there is
    // nothing waiting — on the day this was built every queue was empty — and
    // a wall of zeros teaches people to stop looking, which is exactly when
    // the one thing that does matter gets missed.
    if (!needs || !needs.length) {
      box.className = "";
      box.innerHTML = '<div class="all-clear">' + ICON.tick +
        "<span>Nothing is waiting for you. Anything that arrives will show up here.</span></div>";
      return;
    }

    box.className = "needs";
    box.innerHTML = needs.map(function (n) {
      var urgent = n.urgency === "now";
      var flag = urgent
        ? ICON.clock + "<span>" + esc(leftOn(n.expires_at)) + "</span>"
        : ICON.phone + "<span>" + esc(n.since ? sinceWhen(n.since) : (n.urgency === "later" ? "when you have a minute" : "waiting")) + "</span>";
      var href = WHERE[n.where] || "#";
      return '<a class="need' + (urgent ? " now" : "") + '" href="' + esc(href) + '">' +
        '<span class="flag">' + flag + "</span>" +
        '<span class="t">' + esc(n.title) + "</span>" +
        '<span class="d">' + esc(n.detail || "") +
          (n.ref ? " · " + esc(n.ref) : "") + "</span>" +
        '<span class="go">Open &rarr;</span></a>';
    }).join("");
  }

  function drawTiles(e) {
    var box = el("dash-tiles");
    if (!box || !e) return;

    // What is owed, and what CANNOT BE WORKED OUT. A booking taken on the old
    // session rates has no price on file; the venue portal already refuses to
    // invent one for it, and rolling it into the total here would quietly tell
    // the masjid it is owed less than it is.
    var owedSub = e.owed_count + " booking" + (e.owed_count === 1 ? "" : "s");
    if (e.owed_unknown > 0) {
      owedSub += " · " + e.owed_unknown + " on an old rate, not priced";
    }

    box.innerHTML =
      tile("Bookings ahead", e.bookings_ahead,
           e.next_booking ? "next is " + shortDate(e.next_booking) : "nothing in the diary") +
      tile("Money owed to the masjid", money(e.owed_p), owedSub) +
      tile("Willing to help", e.volunteers,
           e.volunteers_sun + " free Sunday mornings") +
      tile("On adult classes", e.class_places,
           e.class_waiting > 0 ? e.class_waiting + " on the waiting list" : "nobody waiting");
  }

  function tile(k, v, s) {
    return '<div class="tile"><div class="k">' + esc(k) + "</div>" +
           '<div class="v">' + esc(v) + "</div>" +
           '<div class="s">' + esc(s) + "</div></div>";
  }

  // Each card says what you can DO there, not only what is in it. That is the
  // difference between a dashboard and a list of links.
  function drawAreas(areas, roles, house) {
    var box = el("dash-areas");
    if (!box) return;
    var out = [];
    var has = function (r) { return roles.indexOf(r) !== -1; };

    if (areas.venue) {
      var v = areas.venue;
      out.push(area("../venue/", ICON.hall, "Hall Hire & Nikāḥ",
        v.new > 0 ? chip(v.new + " new", "hot") : "",
        [["upcoming", v.upcoming], ["holding", v.holding], ["balance due", v.balance]],
        "Confirm, decline, take a cash deposit, cancel and refund"));
    }
    if (areas.courses) {
      var c = areas.courses;
      out.push(area("../courses/", ICON.book, "Adult classes",
        c.waiting > 0 ? chip(c.waiting + " waiting") : "",
        [["open", c.open], ["signed up", c.signed], ["waiting", c.waiting]],
        "Offer a place from the waiting list, record who came"));
    }
    if (areas.giftaid) {
      var g = areas.giftaid;
      out.push(area("../giftaid/", ICON.heart, "Gift Aid",
        g.to_claim > 0 ? chip(money(g.worth_p) + " to claim", "good") : "",
        [["declarations", g.to_claim], ["incomplete", g.incomplete]],
        "Copy the rows for HMRC, then mark them claimed"));
    }
    if (areas.volunteers) {
      var f = areas.volunteers;
      out.push(area("../volunteers/", ICON.basket, "Food Bank volunteers",
        f.to_ring > 0 ? chip(f.to_ring + " to ring") : "",
        [["willing", f.willing], ["free Sundays", f.sundays]],
        "Mark rung, helping or withdrawn; download the list"));
    }
    if (has("admin") || has("teacher")) {
      out.push(area("../portal/", ICON.people, "Madrasah portal", "", [],
        "Pupils, classes and staff — the most tightly held area on the site"));
    }
    // Added once /access/ existed. It deliberately had no card before that:
    // a card that goes nowhere reads as a broken site.
    // The one page on this website that goes out of date on its own. Added
    // with migration 028, which moved the appeal figure out of the template
    // and into something a person can edit.
    if (has("admin")) {
      out.push(area("../newbuild/", ICON.crane, "The new build page", "", [],
        "Change the appeal figure, what it pays for, and the timeline of phases"));
    }
    if (has("admin") && house) {
      out.push(area("../access/", ICON.lock, "Who can get in",
        house.no_2fa > 0 ? chip(house.no_2fa + " without 2FA", "hot") : "",
        [["accounts", house.accounts], ["administrators", house.admins]],
        "Invite somebody, change what they can do, suspend an account"));
    }
    box.innerHTML = out.join("");
  }

  function chip(text, cls) {
    return '<span class="chip ' + (cls || "") + '">' + esc(text) + "</span>";
  }

  function area(href, icon, name, chipHtml, nums, can) {
    var numHtml = nums.filter(function (n) {
      return n[1] !== null && n[1] !== undefined;
    }).map(function (n) {
      return "<span><b>" + esc(n[1]) + "</b> " + esc(n[0]) + "</span>";
    }).join("");
    return '<a class="area" href="' + esc(href) + '">' +
      '<span class="h">' + icon + '<span class="n">' + esc(name) + "</span>" + chipHtml + "</span>" +
      (numHtml ? '<span class="nums">' + numHtml + "</span>" : "") +
      '<span class="can">' + esc(can) + "</span></a>";
  }

  function drawLog(log, autoCount) {
    var box = el("dash-log");
    if (!box) return;
    if (!log || !log.length) {
      box.innerHTML = '<p class="dash-skel">Nobody has needed to do anything this week.</p>';
    } else {
      box.innerHTML = log.map(function (l) {
        return '<div class="logrow">' +
          '<span class="at">' + esc(logWhen(l.at)) + "</span>" +
          '<span class="wt">' + esc(l.what) +
            (l.ref ? " — <b>" + esc(l.ref) + "</b>" : "") + "</span>" +
          '<span class="wh">' + esc(l.who || "") + "</span></div>";
      }).join("");
    }

    // The machine's work is COUNTED, not listed. On the real database 120 of
    // 130 audit rows were one job clearing expired holds; a feed showing them
    // all is 92% noise, and a log that wastes attention once is never opened
    // again. Phrased as what the masjid did NOT have to do, because that is
    // what it is.
    var foot = el("dash-auto");
    if (foot) {
      if (autoCount > 0) {
        el("dash-auto-t").innerHTML = "Plus <b>" + esc(autoCount) +
          " automatic clean-up" + (autoCount === 1 ? "" : "s") +
          "</b> the masjid did not have to do";
        foot.hidden = false;
      } else {
        foot.hidden = true;
      }
    }
  }

  function drawHousekeeping(h) {
    var pane = el("dash-house-pane");
    var box  = el("dash-house");
    if (!box) return;

    // Only administrators get this back from the database. Hiding the whole
    // pane rather than drawing an empty one: an office account should not see
    // a box that says nothing, and wonder what is in it.
    if (!h) { if (pane) pane.hidden = true; return; }
    if (pane) pane.hidden = false;

    var rows = [];

    // THE WARNING THAT HAS BEEN INVISIBLE. While any account with a role has
    // no authenticator, 011_require_two_step.sql cannot be re-run, and that
    // blocks every future migration. Nothing on this site said so until now.
    if (h.no_2fa > 0) {
      rows.push(row(true, "<b>" + h.no_2fa + " staff account" +
        (h.no_2fa === 1 ? " has" : "s have") + " no authenticator.</b> " +
        "Two-step cannot be re-enforced until that is sorted. " +
        '<a href="../access/">See who</a>'));
    } else {
      rows.push(row(false, "Every staff account has an authenticator"));
    }
    rows.push(row(false, h.accounts + " account" + (h.accounts === 1 ? "" : "s") +
                         " · " + h.admins + " administrator" + (h.admins === 1 ? "" : "s")));
    if (h.last_holds) rows.push(row(false, "Expired holds cleared — " + logWhen(h.last_holds)));
    if (h.last_purge) rows.push(row(false, "Old records deleted — " + logWhen(h.last_purge)));

    box.innerHTML = rows.join("");
  }

  function row(bad, html) {
    return '<div class="hkrow"><span class="hkdot' + (bad ? " bad" : "") +
           '"></span><span>' + html + "</span></div>";
  }

  function drawDashboard(identity, d) {
    var when = el("dash-when");
    if (when && d.as_at) {
      var t = new Date(d.as_at);
      when.textContent = DAYS[t.getDay()] + " " + t.getDate() + " " +
                         MONTHS[t.getMonth()] + ", " + clock(t);
    }
    drawNeeds(d.needs);
    drawTiles(d.estate);
    drawAreas(d.areas || {}, identity.roles, d.housekeeping);
    drawLog(d.log, Number(d.auto_count || 0));
    drawHousekeeping(d.housekeeping);
  }

  function renderList(identity) {
    el("list-name").textContent  = nameOf(identity);
    el("list-email").textContent = identity.user.email;

    var chips = el("list-roles");
    chips.innerHTML = "";
    identity.roles.forEach(function (r) {
      var chip = document.createElement("span");
      chip.className = "dash-role role-" + r;
      chip.textContent = r.replace(/_/g, " ");
      chips.appendChild(chip);
    });

    // The shell drops to one column and the brand panel goes: a form wants
    // 420px, a dashboard does not.
    var shell = document.querySelector(".shell");
    if (shell) shell.classList.add("dash-mode");

    show("view-list");

    // ONE call. If it fails the dashboard is replaced by the reason, not
    // left half-drawn above a quiet error — a page showing five panels and
    // one silent blank is worse than a page that says it could not load.
    // If somebody was invited and has just completed two-step, this is where
    // the roles they were promised actually arrive. Deliberately fired and
    // forgotten: a failure here must not stop the dashboard drawing.
    sb.rpc("claim_pending_access").then(function (res) {
      if (res && res.data && res.data.claimed) {
        // They now hold roles they did not hold a second ago, so the identity
        // in hand is stale and the dashboard would draw the wrong areas.
        window.location.reload();
      }
    }).catch(function () { /* nothing waiting, or not at aal2 yet */ });

    sb.rpc("admin_dashboard").then(function (res) {
      if (res.error) throw res.error;
      var d = res.data || {};
      if (d.allowed === false) {
        throw new Error("This account is not allowed to see the admin centre. " +
                        "If you have just set up two-step, sign out and back in.");
      }
      setError("dash-error", "");
      drawDashboard(identity, d);
    }).catch(function (err) {
      setError("dash-error",
        "Couldn't load the admin centre. " + (err.message || "") +
        " The areas below still work — open one directly.");
      // Draw what can be drawn without the call, so somebody can still get
      // where they were going.
      drawNeeds([]);
      el("dash-tiles").innerHTML = "";
      drawAreas({ venue: {}, volunteers: {} }, identity.roles, null);
      el("dash-log").innerHTML = '<p class="dash-skel">Not available just now.</p>';
      drawHousekeeping(null);
    });
  }

  // --- on arrival -----------------------------------------------------------
  sb.auth.getSession().then(function (res) {
    var session = res.data && res.data.session;
    if (!session || !session.user) { show("view-signedout"); return; }

    return loadIdentity().then(function (identity) {
      // Administrators AND hall office. This used to be admin only, which
      // made sense when the page was a list of areas that only admins could
      // open — but the office has had its own portal since September, and
      // admin_dashboard() already decides per role what comes back. Keeping
      // the gate at admin-only would mean the office signing in, being told
      // it has no access, and then reaching /venue/ perfectly well by typing
      // the address.
      //
      // This is not a widening of what anybody can SEE: every area still
      // checks again, at aal2, on the way in, and the database withholds
      // Gift Aid and the staff figures from an office session regardless of
      // what this page asks for.
      var mayEnter = identity.roles.indexOf("admin") !== -1 ||
                     identity.roles.indexOf("hall_office") !== -1;
      if (!mayEnter) { noAccess(identity); return; }
      renderList(identity);
    });
  }).catch(function (err) {
    if (window.console) console.warn("portals:", err && err.message);
    noAccess(null,
      "We couldn't check what this account has access to just now. " +
      "Please try again in a moment.");
  });

})();
