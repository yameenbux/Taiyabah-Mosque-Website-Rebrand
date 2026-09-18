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

   THIS IS NOW THE ONLY LIST, AND THAT WAS NOT FREE.
   -------------------------------------------------
   The note that used to sit here said the role rules were copied from
   portals/app.js drawAreas() "on purpose", that two copies of a rule is one
   too many, and that pointing the Admin Centre at this file was the next
   thing to do. It was not done, and here is the bill for that:

     * The Admin Centre home listed EIGHT areas. This rail listed ELEVEN.
       Notices, Hall hire charges and Prayer timetable were added here and
       never added there, so clicking any tile on the home page made three
       rows appear that had not been on the page you came from. Somebody
       using the site reported that as "when i click on one, more tabs
       appear ... not straight forward and a tad confusing". They were not
       describing a layout problem. They were describing two menus.

     * volunteers said needs:["admin"] here while volunteers/app.js admits
       admin OR hall_office and the home page showed it to both. The hall
       office could open Food Bank volunteers from one menu and not see it
       in the other. Fixed below — the screen decides, and the rail agrees
       with the screen.

   So portals/index.html now loads this file and portals/app.js reads GROUPS
   from it. There is one list. _test/admin_shell_test.py fails if a second
   one is ever written, and fails if a row's `needs` disagrees with the roles
   its own screen actually admits.
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
    menu:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M4 12h16M4 17h16"/></svg>',
    /*  A bell, not a phone. The row is "send a notification"; a phone outline
        would read as "the app", which is a place, and this row is an action. */
    bell:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M18 8.5a6 6 0 10-12 0c0 5.2-2 6.5-2 6.5h16s-2-1.3-2-6.5"/><path d="M10.4 20.5a1.9 1.9 0 003.2 0"/></svg>',

    /*  THE MADRASAH'S OWN SECTIONS. Drawn in the same hand as the ten above —
        1.8 stroke, round caps, 24-box — so a rail that swaps its contents
        does not also swap its handwriting. */
    sun:    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2.5M12 19.5V22M2 12h2.5M19.5 12H22M4.9 4.9l1.8 1.8M17.3 17.3l1.8 1.8M19.1 4.9l-1.8 1.8M6.7 17.3l-1.8 1.8"/></svg>',
    child:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="6.5" r="3"/><path d="M6.5 21v-4.5a5.5 5.5 0 0111 0V21"/><path d="M9.5 21v-3M14.5 21v-3"/></svg>',
    home:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 10.5 12 3.5l8.5 7"/><path d="M5.5 9.7V20h13V9.7"/><path d="M10 20v-5h4v5"/></svg>',
    tick:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="3.5" width="15" height="17" rx="2"/><path d="M8.5 11.5l2.4 2.4 4.6-4.9"/></svg>',
    shield: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2.8 4.8 5.6v6c0 4.6 3 8.1 7.2 9.6 4.2-1.5 7.2-5 7.2-9.6v-6z"/><path d="M9.2 12.1l1.9 1.9 3.7-3.9"/></svg>',
    pound:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M14.8 6.3a3.4 3.4 0 00-5.9 2.3v4.1c0 1.3-.5 2.4-1.4 3.2"/><path d="M7.5 12.6h5.6"/><path d="M6.8 19h10"/></svg>',
    star:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m12 3.6 2.6 5.3 5.9.9-4.2 4.1 1 5.8-5.3-2.8-5.3 2.8 1-5.8L3.5 9.8l5.9-.9z"/></svg>',
    chat:   '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M20.5 12.6c0 3.9-3.8 7-8.5 7-1.1 0-2.2-.2-3.2-.5L3.5 21l1.6-4a6.6 6.6 0 01-1.6-4.4c0-3.9 3.8-7 8.5-7s8.5 3.1 8.5 7z"/></svg>',
    inbox:  '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 13.5h4l1.6 2.6h5.8l1.6-2.6h4"/><path d="M5.6 4.6h12.8l2.1 8.9v4a2 2 0 01-2 2H5.5a2 2 0 01-2-2v-4z"/></svg>'
  };

  /*  EVERY DESTINATION, IN ONE PLACE, IN THE ORDER PEOPLE READ THEM.

      `needs` is the role test, and it must match the roles the screen behind
      it actually admits — a row that appears and then refuses you is worse
      than no row. A test checks this pair by pair.

      `what` is the sentence describing what you can do there. It is written
      here, once, and used in three places: as the row's title attribute, in
      "What each area is for" at the foot of the Admin Centre home, and by
      nothing else. It used to live in portals/app.js, which is how the two
      menus came to disagree in the first place.

      THE HEADINGS ARE NOT DECORATION — they are what lets somebody skip four
      rows without reading them, so each one has to be true.

        "What people have asked for" — things that ARRIVED. A booking, a
        chanda request, a sign-up, an offer to help. Most weeks this is the
        only group anybody opens, so it stays at the top and stays biggest.

        "Money" — one row, and it earns its heading, because somebody hunting
        for Gift Aid looks for the money before they look for the name.

        "The madrasah" — its own heading, because a teacher account sees this
        row and NOTHING ELSE. Filed under a general heading it read as an
        odd single entry under a label that did not describe it.

        "Change what the website says" — NOT "Settings". Settings means
        configuration: who may sign in, where mail goes. These are pages you
        edit, and somebody wanting to change the hall hire prices will look
        for the word website, not the word settings. The previous label,
        "The masjid's own pages", was vague in the same way and is why User
        access and the Madrasah portal ended up filed in with the editors.

        "Settings" — the genuinely administrative thing, at the bottom,
        where the twice-a-year jobs belong.

      A group whose rows are all hidden is not drawn at all, so an office
      account gets a shorter rail rather than empty headings — which reads as
      a working screen rather than a broken one. */
  var GROUPS = [
    { label: "What people have asked for", areas: [
      { key: "venue",       href: "venue/",       icon: "hall",   name: "Hall Hire & Nikāḥ",
        needs: ["admin", "hall_office"],
        what: "Confirm, decline, take a cash deposit, cancel and refund" },
      { key: "collections", href: "collections/", icon: "tin",    name: "Charity collections",
        needs: ["admin", "hall_office"],
        what: "Chanda requests from outside charities — ring the trustee, then approve or decline" },
      /*  ONE ROW FOR CLASSES, NOT TWO. There was a second, "What a class
          says", pointing at a screen that held the website copy while this
          one held the settings. A class is one thing to a volunteer and the
          split was mine, not theirs — everything about a class is behind
          this row now, which is also why it stays in this group rather than
          moving down with the page editors. */
      { key: "courses",     href: "courses/",     icon: "book",   name: "Adult classes",
        needs: ["admin"],
        what: "Offer a place from the waiting list, record who came, and change what the website says about a class" },
      /*  admin OR hall_office, because volunteers/app.js admits both and has
          since it was written. This said ["admin"] for a fortnight, so the
          hall office saw Food Bank volunteers on the Admin Centre home and
          not in the rail. */
      { key: "volunteers",  href: "volunteers/",  icon: "basket", name: "Food Bank volunteers",
        needs: ["admin", "hall_office"],
        what: "Mark rung, helping or withdrawn; download the list" }
    ]},
    { label: "Money", areas: [
      { key: "giftaid",     href: "giftaid/",     icon: "heart",  name: "Gift Aid",
        needs: ["admin"],
        what: "Copy the rows for HMRC, then mark them claimed" }
    ]},
    { label: "The madrasah", areas: [
      { key: "madrasah",    href: "portal/",      icon: "people", name: "Madrasah portal",
        needs: ["admin", "teacher"],
        what: "Pupils, classes and staff — the most tightly held area on the site" }
    ]},
    /*  THE APP IS A DIFFERENT PLACE, not a page of this website, and it gets
        its own heading for the same reason the madrasah does: what is behind
        it belongs to something else.

        It sits ABOVE the website-content group on purpose. Sending a
        notification is not editing a page — it is the one irreversible thing
        in this whole portal. It reaches every phone in the congregation, at
        whatever hour it is sent, and it cannot be recalled. Filing it in with
        "change the hall hire prices" would be filing it by subject when the
        thing that matters about it is the consequence. */
    { label: "The app", areas: [
      { key: "appsend",     href: "app/",         icon: "bell",   name: "Send a notification",
        needs: ["admin"],
        what: "Send an alert to everybody's phone, and see what has already gone out" }
    ]},
    { label: "Change what the website says", areas: [
      { key: "notices",     href: "notices/",     icon: "notice", name: "Notices",
        needs: ["admin"],
        what: "Write a notice, change one, or take it down" },
      { key: "rates",       href: "rates/",       icon: "tag",    name: "Hall hire charges",
        needs: ["admin"],
        what: "Change what the hall costs. The deposit is fixed and is not set here" },
      { key: "times",       href: "times/",       icon: "clock",  name: "Prayer timetable",
        needs: ["admin"],
        what: "Upload next year's timetable, or correct a single day" },
      { key: "newbuild",    href: "newbuild/",    icon: "crane",  name: "The new build page",
        needs: ["admin"],
        what: "Change the appeal figure, what it pays for, and the timeline of phases" }
    ]},
    { label: "Settings", areas: [
      { key: "access",      href: "access/",      icon: "lock",   name: "User access",
        needs: ["admin"],
        what: "Invite somebody, change what they can do, suspend an account" }
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
  /*  HOW FAR UP THE WEB ROOT IS.

      Every staff screen sat one folder below the root — /venue/, /giftaid/ —
      so this was "../" and nothing else. The Madrasah Portal broke that
      assumption the day it grew /portal/staff/, which is two deep: every rail
      link and the logo would have pointed at /portal/portals/, /portal/venue/,
      /portal/img/masjid-logo.png. All dead, silently, with the rail looking
      perfect.

      The first fix for that lived in the screen: mount the rail, then walk the
      DOM rewriting every href. It worked, and it was the beginning of a habit
      — the second nested screen copies it, the third copies it slightly wrong,
      and now there are three places that know how deep a page is. That is the
      shape of every bug this project has spent a fortnight removing.

      So the page says how deep it is, once, and this does the arithmetic. */
  var depth = 1;
  function up(p) {
    return new Array(depth + 1).join("../") + p;
  }

  /*  THE ROWS THIS ACCOUNT MAY SEE, GROUPED, EMPTY GROUPS DROPPED.

      Both menus call this. It is the whole point of the file: the Admin
      Centre home and the rail inside every screen get the same answer from
      the same code, so they cannot list different things again.

      It returns groups rather than a flat list because the grouping is part
      of the answer — the home page needs the same headings in the same
      order, or clicking in still changes the shape of the menu. */
  function visible(roles) {
    var r = roles || [];
    var has = function (list) {
      for (var i = 0; i < list.length; i++) {
        if (r.indexOf(list[i]) !== -1) return true;
      }
      return false;
    };
    var out = [];
    GROUPS.forEach(function (g) {
      var areas = g.areas.filter(function (a) { return has(a.needs); });
      if (areas.length) out.push({ label: g.label, areas: areas });
    });
    return out;
  }

  /*  Over this many rows a rail stops being a list and becomes a wall. Six
      groups and a dozen rows is the Admin Centre and reads fine whole; the
      madrasah past forty does not. One number, named, in one place. */
  var LONG_RAIL = 18;

  var CARET = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" ' +
              'stroke="currentColor" stroke-width="2.2" stroke-linecap="round" ' +
              'stroke-linejoin="round"><polyline points="6 9 12 15 18 9"/></svg>';

  /*  WHAT THIS PERSON LAST DID WITH THIS GROUP, or null if they never have.

      Deliberately three-valued. `false` means "they closed it" and has to beat
      the open-by-default rule; a plain truthiness check would treat a closed
      group as no preference and helpfully re-open it every single time, which
      is the sort of thing that makes people stop touching a control.

      Wrapped in try/catch because localStorage throws rather than returning
      null in a locked-down browser or a private window, and a rail that cannot
      be drawn is worse than a rail that forgets. */
  function remembered(key) {
    try {
      var v = w.localStorage.getItem("taiyabah.rail." + key);
      return v === null ? null : v === "1";
    } catch (e) { return null; }
  }

  function remember(key, open) {
    try { w.localStorage.setItem("taiyabah.rail." + key, open ? "1" : "0"); }
    catch (e) { /* nothing to do, and nothing worth saying about it */ }
  }

  /*  The same filter as visible(), applied to sections a caller supplied.

      An area with NO `needs` is shown to everybody who got this far, which
      keeps every existing section working untouched and makes the property
      mean "this row is restricted" rather than "somebody remembered to fill
      it in". Empty groups drop out, so a teaching account does not see the
      heading "Keeping children safe" with nothing under it. */
  function forRoles(groups, roles) {
    var r = roles || [];
    var out = [];
    groups.forEach(function (g) {
      var areas = g.areas.filter(function (a) {
        if (!a.needs || !a.needs.length) return true;
        for (var i = 0; i < a.needs.length; i++) {
          if (r.indexOf(a.needs[i]) !== -1) return true;
        }
        return false;
      });
      if (areas.length) out.push({ label: g.label, areas: areas });
    });
    return out;
  }

  function row(a, current) {
    var here = a.key === current;
    var body = '<span class="ic" aria-hidden="true">' + ICON[a.icon] + "</span>" +
               '<span class="bd"><span class="n">' + esc(a.name) + "</span></span>";

    /*  A SECTION THAT IS NOT BUILT YET IS NOT A LINK.

        The madrasah rail shows its whole shape from the first day, because a
        three-row rail tells a volunteer nothing about where this is going.
        But a row that looks pressable and does nothing teaches people the
        screen is broken, and then they stop reporting it when it really is —
        which is written down on /portal/ already, about the tiles there.

        So an unbuilt section is a <span>: muted, not focusable, not clickable,
        and it says so on hover and to a screen reader. The shape is visible;
        nothing lies about being ready. */
    if (a.soon) {
      return '<span class="area soon" title="Not built yet">' + body +
             '<span class="soon-tag">soon</span></span>';
    }

    return '<a class="area" href="' + esc(up(a.href)) + '"' +
           (a.what ? ' title="' + esc(a.what) + '"' : "") +
           (here ? ' aria-current="page"' : "") + ">" + body + "</a>";
  }

  function railHtml(opts) {
    var out = [];

    /*  AN AREA CAN BRING ITS OWN SECTIONS.

        The Madrasah Portal is a place inside a place: it has a dozen sections
        of its own — register, fees, safeguarding — and putting its rail BESIDE
        this one would mean two left-hand columns, which is unusable. So while
        somebody is inside it, this rail becomes the madrasah's own list with
        a way back out at the top.

        It is the SAME rail, not a second one. The drawer, the escape key, the
        focus handling, the logo in the corner and the sign-out are behaviours
        this file already gets right, and a second implementation would be a
        second place for each of them to be wrong. That is the exact bug this
        project spent a day removing from the Admin Centre. One shell; the
        caller says what goes in it. */
    var sections = opts.sections || null;
    var label = sections ? (opts.area || "Madrasah") : "Admin Centre";

    out.push('<div class="ashell-top"><a href="' + esc(up(HOME.href)) +
             '" title="Back to the Admin Centre">' +
             '<img src="' + esc(up("img/masjid-logo.png")) +
             '" alt="Taiyabah Masjid" width="220" height="62">' +
             "<strong>" + esc(label) + "</strong></a></div>");

    out.push('<nav aria-label="Everywhere you can go">');

    //  The way out is the first row, and it says where it goes. Inside a
    //  sub-area the Admin Centre is not "home" — it is BACK, and somebody who
    //  has gone two levels in needs to see that before they see anything else.
    out.push('<div class="ashell-group">' +
             row(sections
                   ? { key: "__back", href: HOME.href, icon: "grid",
                       name: "← Admin Centre",
                       what: "Out of the madrasah, back to everything else" }
                   : HOME,
                 opts.current) + "</div>");

    /*  ------------------------------------------------------------------
        GROUPS OPEN AND CLOSE, AND THE RULE IS THE LENGTH OF THE RAIL.
        ------------------------------------------------------------------
        Asked for: "the main sections should be expandable if needed or like
        a drop down." The "if needed" is doing the work, so here is the rule.

        The Admin Centre's rail is six groups and about a dozen rows. Every
        one of them fits, and collapsing a list somebody can already read
        whole costs a click and gains nothing. The madrasah's rail is a
        different animal — nine groups, and with fees and incidents opened
        out it is past forty rows, most of them not built yet. Showing all of
        that at once buries Register under a wall of "soon".

        So: under LONG_RAIL rows everything stays open and nothing changes.
        Over it, the group you are standing in is open and the rest are shut,
        which turns the rail into a map you drill into rather than a list you
        scroll. Either way, whatever the person opens or closes is remembered
        for next time and beats the rule.

        <details>/<summary>, not a div and a click handler. It is keyboard
        operable, it announces expanded/collapsed to a screen reader, it can
        be opened by find-in-page, and IT STILL WORKS WITH NO JAVASCRIPT —
        which matters because this rail is how somebody leaves a screen that
        has just failed.                                                    */
    /*  A ROW NOT MEANT FOR THIS ACCOUNT IS NOT DRAWN.

        The Admin Centre's own list has always worked this way — every area
        carries `needs` and visible() filters on it. An area's OWN sections
        did not, because when the madrasah rail was written everybody who
        could reach it was an administrator.

        That stopped being true the moment the madrasah role existed. A
        teaching account has no business being shown "DBS & checks" at all:
        the database refuses it either way, but a menu row you are refused
        every time you press it teaches people the system is broken, and
        naming the safeguarding screens to somebody who cannot open them is
        not a courtesy either.

        NONE OF THIS IS THE SECURITY. Every one of those screens asks
        verified_admin() in Postgres and would refuse a teaching account with
        the rail hand-edited. This is about what a menu should say. */
    var groups = sections ? forRoles(sections, opts.roles) : visible(opts.roles);
    var rows = 0;
    groups.forEach(function (g) { rows += g.areas.length; });
    var openAll = rows <= LONG_RAIL;
    var scope = sections ? ("md:" + (opts.area || "madrasah")) : "admin";

    groups.forEach(function (g) {
      var key  = scope + ":" + g.label.toLowerCase().replace(/[^a-z0-9]+/g, "-");
      var here = g.areas.some(function (a) { return a.key === opts.current; });
      var open = remembered(key);
      if (open === null) open = openAll || here;

      out.push('<details class="ashell-sec" data-sec="' + esc(key) + '"' +
               (open ? " open" : "") + ">" +
                 '<summary class="ashell-lab">' +
                   "<span>" + esc(g.label) + "</span>" +
                   '<span class="ashell-caret" aria-hidden="true">' + CARET + "</span>" +
                 "</summary>" +
                 '<div class="ashell-group">' +
                 g.areas.map(function (a) { return row(a, opts.current); }).join("") +
                 "</div>" +
               "</details>");
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

    /*  Set BEFORE railHtml() runs, because up() is called all the way through
        it. A page two folders down passes depth:2; everything else says
        nothing and gets the "../" it has always had. */
    depth = Math.max(1, parseInt(opts.depth, 10) || 1);

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
      //  The eyebrow names the PLACE, not the product. On a madrasah screen it
      //  said "Admin Centre" over the word "Staff", which reads as the wrong
      //  staff list — the masjid's, not the madrasah's.
      head.innerHTML = '<span class="eyebrow">' +
                       esc(opts.area || "Admin Centre") + "</span>" +
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

    /*  REMEMBERING WHICH GROUPS ARE OPEN.

        One listener on the rail rather than one per group, and `true` on the
        end because `toggle` does not bubble — it is one of a small handful of
        events that do not, along with focus and blur, so a delegated listener
        has to catch it going down instead. Wiring this per-<details> would
        work today and break the moment the rail is redrawn.

        Nothing here decides what is open; the markup already did. This only
        writes down what the person chose. */
    rail.addEventListener("toggle", function (ev) {
      var sec = ev.target;
      if (!sec || sec.tagName !== "DETAILS" || !sec.hasAttribute("data-sec")) return;
      remember(sec.getAttribute("data-sec"), sec.open);
    }, true);

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

  /*  `visible` is the one the Admin Centre home uses. GROUPS and ICON stay
      exported because a screen may want an icon, but nothing should filter
      GROUPS by hand — that is how the second menu got written. */
  w.AdminShell = { mount: mount, visible: visible, GROUPS: GROUPS, ICON: ICON };
})(window, document);
