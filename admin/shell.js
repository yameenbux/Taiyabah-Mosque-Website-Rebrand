/* ===========================================================================
   THE ADMIN SHELL — the rail that appears on every staff screen.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   15 September 2026

   USED LIKE THIS, once a page knows who is signed in:

       AdminShell.mount({
         current: "volunteers",          // which row to mark as "you are here"
         roles:   identity.roles,        // from user_roles, as every page has
         name:    identity.profile.full_name,
         email:   identity.user.email
       });

   AFTER SIGN-IN, NEVER BEFORE. The rail is a list of places this person can
   go, so drawing it for somebody who has not signed in would be both useless
   and a small disclosure — it would tell an unauthenticated visitor which
   areas exist and, worse, a stranger at a shared office computer which ones
   the last person could reach. Every page calls this from the same place it
   already decides what to render, so the rail cannot appear earlier.

   WHAT IT DOES NOT DO
   -------------------
   It does not check permissions. It CANNOT: it is JavaScript in the visitor's
   own browser, and anything it decides can be decided differently by anybody
   with the developer tools open. Hiding a row hides a row, nothing more.
   Every area behind these links asks for the authenticator again, and every
   table behind THOSE is guarded by row-level security that runs in Postgres
   where the browser cannot reach it. This list is a convenience, and the
   footer says so in as many words so that nobody mistakes it for a lock.

   THE ROLE RULES ARE COPIED FROM portals/app.js drawAreas() ON PURPOSE. Two
   copies of a rule is one too many, and the honest fix is for the Admin
   Centre to use this file too — which is the next thing to do here. Until
   then, AREAS below is the single list and portals/ should be pointed at it
   rather than a third copy being written.
   =========================================================================== */
(function (w, d) {
  "use strict";

  /*  The icons, byte-for-byte the ones the Admin Centre already used, so a
      row means the same thing wherever a person sees it. */
  var ICON = {
    hall:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 21h18M5 21V8l7-4 7 4v13"/><path d="M10 21v-5h4v5"/></svg>',
    tin:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 10h17v9a2 2 0 01-2 2h-13a2 2 0 01-2-2v-9Z"/><path d="M2.5 6.5h19V10h-19z"/><path d="M12 6.5V21"/><path d="M12 6.5S10.6 3.2 8.6 3.2a2.1 2.1 0 000 4.2"/><path d="M12 6.5s1.4-3.3 3.4-3.3a2.1 2.1 0 010 4.2"/></svg>',
    book:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 19.5A2.5 2.5 0 016.5 17H20"/><path d="M6.5 2H20v20H6.5A2.5 2.5 0 014 19.5v-15A2.5 2.5 0 016.5 2z"/></svg>',
    basket: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M3.2 9h17.6l-1.9 10.2a2 2 0 01-2 1.8H7.1a2 2 0 01-2-1.8L3.2 9z"/><path d="M8.4 9l2.9-5.2M15.6 9l-2.9-5.2"/></svg>',
    heart:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 21s-7-4.35-10-9.3C.5 8.1 2.1 4.5 5.6 4c2-.3 3.7.6 4.9 2.3.4.5 1.1 2.1 1.5 2.1s1.1-1.6 1.5-2.1C14.7 4.6 16.4 3.7 18.4 4c3.5.5 5.1 4.1 3.6 7.7C19 16.65 12 21 12 21z"/></svg>',
    people: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="9" cy="8" r="3.2"/><path d="M2.5 20c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6"/><circle cx="17.5" cy="9" r="2.4"/><path d="M15.7 14.3c2.7.3 4.8 2.3 4.8 5.2"/></svg>',
    crane:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M4 21V5l9-2v4"/><path d="M4 9h9"/><path d="M13 7h7l-2.5 4H13z"/><path d="M17 11v4"/><path d="M15 15h4l-1 3h-2z"/></svg>',
    lock:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="10" rx="2"/><path d="M7 11V7a5 5 0 0110 0v4"/></svg>',
    notice: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3 10.5v3a1.5 1.5 0 001.5 1.5H7l5.5 4V6.5L7 10.5H4.5A1.5 1.5 0 003 12z"/><path d="M17 9.2a4 4 0 010 5.6"/><path d="M19.6 6.6a7.6 7.6 0 010 10.8"/></svg>',
    tag:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20.6 13.4 12 22l-9-9V3h10l7.6 7.6a2 2 0 010 2.8z"/><circle cx="8" cy="8" r="1.4"/></svg>',
    pen:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4z"/></svg>',
    grid:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>',
    clock:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 12V7M12 12l3.5 2.2"/></svg>',
    menu:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg>'
  };

  /*  EVERY DESTINATION, IN ONE PLACE, IN THE ORDER PEOPLE READ THEM.

      `needs` is the role test. It is the same test the Admin Centre applies,
      written once here instead of twice.

      Grouped, because eleven undifferentiated rows is just a longer list. A
      group whose rows are all hidden is not drawn at all, so an office
      account gets a shorter rail rather than empty headings — which reads as
      a working screen rather than a broken one. */
  var GROUPS = [
    { label: "What people have asked for", areas: [
      { key: "venue",       href: "venue/",       icon: "hall",   name: "Hall Hire & Nikāḥ",
        needs: ["admin", "hall_office"] },
      { key: "collections", href: "collections/", icon: "tin",    name: "Charity collections",
        needs: ["admin", "hall_office"] },
      { key: "courses",     href: "courses/",     icon: "book",   name: "Adult classes",
        needs: ["admin"] },
      { key: "classpages",  href: "classpages/",  icon: "pen",    name: "What a class says",
        needs: ["admin"] },
      { key: "volunteers",  href: "volunteers/",  icon: "basket", name: "Food Bank volunteers",
        needs: ["admin"] }
    ]},
    { label: "Money", areas: [
      { key: "giftaid",     href: "giftaid/",     icon: "heart",  name: "Gift Aid",
        needs: ["admin"] }
    ]},
    { label: "The masjid's own pages", areas: [
      { key: "notices",     href: "notices/",     icon: "notice", name: "Notices",
        needs: ["admin"] },
      { key: "rates",       href: "rates/",       icon: "tag",    name: "Hall hire charges",
        needs: ["admin"] },
      { key: "times",       href: "times/",       icon: "clock",  name: "Prayer timetable",
        needs: ["admin"] },
      { key: "madrasah",    href: "portal/",      icon: "people", name: "Madrasah portal",
        needs: ["admin", "teacher"] },
      { key: "newbuild",    href: "newbuild/",    icon: "crane",  name: "The new build page",
        needs: ["admin"] },
      { key: "access",      href: "access/",      icon: "lock",   name: "User access",
        needs: ["admin"] }
    ]}
  ];

  var HOME = { key: "home", href: "portals/", icon: "grid", name: "Admin Centre" };

  function esc(v) {
    return String(v == null ? "" : v)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;")
      .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  /*  Pages sit one folder below the web root — /venue/, /giftaid/ — so every
      link and image is "../something". Kept in one function so that if a
      screen is ever moved deeper, there is exactly one place to change. */
  function up(p) { return "../" + p; }

  function row(a, current) {
    var here = a.key === current;
    return '<a class="area" href="' + esc(up(a.href)) + '"' +
           (here ? ' aria-current="page"' : "") + ">" +
           '<span class="ic" aria-hidden="true">' + ICON[a.icon] + "</span>" +
           '<span class="bd"><span class="n">' + esc(a.name) + "</span></span></a>";
  }

  function railHtml(opts) {
    var roles = opts.roles || [];
    var has = function (list) {
      for (var i = 0; i < list.length; i++) {
        if (roles.indexOf(list[i]) !== -1) return true;
      }
      return false;
    };

    var out = [];

    out.push('<div class="ashell-top"><a href="' + esc(up(HOME.href)) +
             '" title="Back to the Admin Centre">' +
             '<img src="' + esc(up("img/masjid-logo.png")) +
             '" alt="Taiyabah Masjid" width="220" height="62">' +
             "<strong>Admin Centre</strong></a></div>");

    out.push('<nav aria-label="Everywhere you can go">');

    //  The Admin Centre itself is always first and always present. It is the
    //  one destination that needs no role, and it is where somebody goes when
    //  they do not know where to go.
    out.push('<div class="ashell-group">' + row(HOME, opts.current) + "</div>");

    GROUPS.forEach(function (g) {
      var rows = g.areas
        .filter(function (a) { return has(a.needs); })
        .map(function (a) { return row(a, opts.current); });
      if (!rows.length) return;
      out.push('<div class="ashell-lab">' + esc(g.label) + "</div>" +
               '<div class="ashell-group">' + rows.join("") + "</div>");
    });

    out.push("</nav>");

    //  WHO YOU ARE SIGNED IN AS. Masjid computers are shared; the single most
    //  useful thing this rail can tell somebody who has just sat down is
    //  whose session they are looking at.
    /*  Name AND email, not one or the other. These screens are opened on a
        shared machine in the masjid office, and "Signed in as Rafiq" is not
        enough to tell you whether it is your Rafiq or the account somebody
        left open an hour ago. The email is the part that settles it. */
    var who = opts.name || opts.email || "";
    var alsoEmail = (opts.email && opts.name && opts.email !== opts.name)
                    ? opts.email : "";
    out.push('<div class="ashell-foot">' +
             (who ? '<span class="ashell-who">Signed in as ' + esc(who) +
                    (alsoEmail ? '<i>' + esc(alsoEmail) + "</i>" : "") + "</span>" : "") +
             "Every area asks for your authenticator code when you open it, " +
             "whatever this list says.<br>" +
             '<a href="' + esc(up("index.html")) + '">Back to the website</a>' +
             '<button type="button" class="ashell-out" hidden>Sign out</button>' +
             "</div>");

    return out.join("");
  }

  function mount(opts) {
    opts = opts || {};
    if (d.querySelector(".ashell")) return;   // never twice

    var rail = d.createElement("aside");
    rail.className = "ashell";
    rail.id = "admin-rail";
    rail.innerHTML = railHtml(opts);

    var bar = d.createElement("div");
    bar.className = "ashell-bar";
    bar.innerHTML =
      '<button class="ashell-burger" type="button" aria-expanded="false" ' +
      'aria-controls="admin-rail" aria-label="Show the menu">' + ICON.menu + "</button>" +
      '<img src="' + esc(up("img/masjid-logo.png")) + '" alt="" width="110" height="30">' +
      '<span class="t">' + esc(opts.title || "Admin Centre") + "</span>";

    var scrim = d.createElement("div");
    scrim.className = "ashell-scrim";
    scrim.hidden = false;

    d.body.insertBefore(scrim, d.body.firstChild);
    d.body.insertBefore(rail, d.body.firstChild);
    d.body.insertBefore(bar, d.body.firstChild);
    d.body.classList.add("has-ashell");

    /*  THE PAGE'S OWN NAME, at the top of the desk.
        The plum brand panel used to carry it and shell.css now removes that
        panel after sign-in, because on a 1440px screen it was forty-two per
        cent of the width repeating what the rail already says. Something
        still has to name the screen though: a rail with one row highlighted
        is a poor answer on its own, since that row is the one you are least
        likely to be looking at — you have just clicked it and moved your eyes
        to the right-hand side of the screen.

        Inserted rather than written into fourteen pages, for the same reason
        the rail is: fourteen copies of a heading is fourteen chances for one
        of them to say "Gift Aid" on the prayer timetable, which is a mistake
        this project has already made twice. */
    var panel = d.querySelector(".panel");
    if (panel && opts.title && !d.querySelector(".ashell-head")) {
      var head = d.createElement("header");
      head.className = "ashell-head";
      head.innerHTML = '<span class="eyebrow">Admin Centre</span>' +
                       "<h1>" + esc(opts.title) + "</h1>";
      panel.insertBefore(head, panel.firstChild);
    }

    /*  SIGN OUT, ONCE. The page's own button is hidden by shell.css because
        it sat at the bottom of the working area looking like a primary
        action. This one does not reimplement signing out — it CLICKS the
        page's button, so whatever that page does on the way out (revoking a
        session, clearing a cache, warning about unsaved work) still happens.
        Reimplementing it here would be a second sign-out to keep in step with
        fourteen first ones.

        Shown only if there is something to click. A page with no sign-out
        button of its own gets no sign-out row, rather than a button that
        silently does nothing. */
    var pageOut = d.getElementById("app-signout");
    var railOut = rail.querySelector(".ashell-out");
    if (pageOut && railOut) {
      railOut.hidden = false;
      railOut.addEventListener("click", function () { pageOut.click(); });
    }

    var burger = bar.querySelector(".ashell-burger");

    function setOpen(open) {
      d.body.classList.toggle("ashell-open", open);
      burger.setAttribute("aria-expanded", open ? "true" : "false");
      burger.setAttribute("aria-label", open ? "Hide the menu" : "Show the menu");
      if (open) {
        var first = rail.querySelector("a");
        if (first) first.focus();
      }
    }

    burger.addEventListener("click", function () {
      setOpen(!d.body.classList.contains("ashell-open"));
    });
    scrim.addEventListener("click", function () { setOpen(false); });

    //  Escape closes it, and focus goes back to the button that opened it —
    //  otherwise a keyboard user is left focused on something that is no
    //  longer on screen.
    d.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && d.body.classList.contains("ashell-open")) {
        setOpen(false);
        burger.focus();
      }
    });

    //  Following a link inside the drawer navigates away, but if anything is
    //  ever added that does not, leaving the drawer open over the page it
    //  just changed would be wrong.
    rail.addEventListener("click", function (e) {
      if (e.target.closest("a")) setOpen(false);
    });
  }

  w.AdminShell = { mount: mount, GROUPS: GROUPS, ICON: ICON };
})(window, document);
