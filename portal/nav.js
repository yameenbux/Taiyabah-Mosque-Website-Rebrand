/* ===========================================================================
   THE MADRASAH PORTAL'S OWN SECTIONS.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   18 September 2026

   Handed to AdminShell.mount({ sections: MadrasahNav.SECTIONS, ... }), which
   swaps the site rail for this list while somebody is inside the madrasah and
   puts "← Admin Centre" at the top. One rail implementation, two lists — see
   the long comment in admin/shell.js about why this is not a second rail.

   ---------------------------------------------------------------------------
   THIS IS THE SHAPE OF THE SYSTEM IT REPLACES, AND NONE OF ITS APPEARANCE.
   ---------------------------------------------------------------------------
   The masjid runs IBEAMS today: one left-hand nav, a list, row actions. That
   arrangement is right and is kept, because whoever has to switch should
   recognise where they are. What is NOT kept is how it looks — the green
   header bars, the four blue buttons on every row, the badge pills. This
   project has already been told once, correctly:

       "you have just copied and pasted the design i showed, use our own
        designs as i dont want it to be seen as copied."

   Recolouring somebody else's layout is not designing it.

   ---------------------------------------------------------------------------
   WHAT WAS DROPPED FROM ITS MENU, AND WHY
   ---------------------------------------------------------------------------
     RATE US              vendor self-promotion.
     Help & Support       that is the vendor's helpdesk, not a feature of this
                          madrasah. Ours is a runbook, not a nav section.
     Forums               needs daily moderation nobody is resourced for. It
                          sits empty or it becomes a liability.
     Products             the website already has a Shop. Two shops is the
                          two-lists problem this project spent a day removing
                          from the Admin Centre.
     Tools                an unnamed catch-all. Whatever is in it belongs
                          somewhere named.
     Newsletters/SMS      SMS costs per message and needs another account. The
                          masjid now has email AND push to its own app, both
                          built and working. Folded into "Talking to families",
                          and the SMS half dropped.
     Student Diary        belongs on the child's own record, not as its own
                          section of the building.
     Administration       two settings menus in one product. One here.
       + Settings/Preferences

   WHAT WAS ADDED
     Admissions           /apply/ is live on the website and writes to
                          admission_applications, and NOTHING READS THEM. A
                          family applies and it lands where nobody works. That
                          is a gap today, not a nice-to-have.
     DBS & checks         the old system shows a check has lapsed. Telling
                          somebody it lapses in ninety days is a different
                          product, and it is the clearest thing this can do
                          better than what it replaces.
     Absence follow-up    a register records who was in. It does not notice a
                          child quietly stopping, which is the safeguarding
                          question. Sits under Register when that is built.

   ---------------------------------------------------------------------------
   `soon: true` MEANS NOT BUILT, AND IT IS NOT A LINK.

   The whole shape is listed from the first day, because a three-row rail tells
   a volunteer nothing about where this is going. But an unbuilt row renders as
   a <span> — not clickable, not focusable, visibly muted, tagged "soon". A
   control that looks pressable and does nothing teaches people the screen is
   broken, and then they stop reporting it when it really is. That is already
   written down about the tiles on this page; it applies to its rail too.

   Take `soon` off a row on the day its screen exists. Nothing else changes.
   =========================================================================== */
(function (w) {
  "use strict";

  w.MadrasahNav = {
    SECTIONS: [
      { label: "Today", areas: [
        { key: "md-today",   href: "portal/",  icon: "sun",   name: "What needs doing",
          what: "The madrasah at a glance, and anything waiting" }
      ]},

      /*  WHO IS HERE. The four registers of people and places. "Families"
          rather than the old system's "Contacts": a contact is a family, not
          a separate species of record, and calling it Contacts is why the
          same mother appears three times under three children. */
      { label: "Who is here", areas: [
        { key: "md-pupils",   href: "portal/pupils/",   icon: "child",  name: "Pupils",
          soon: true },
        { key: "md-families", href: "portal/families/", icon: "home",   name: "Families",
          soon: true },
        /*  `soon` until portal/classes/ exists. It was briefly listed as a
            live link to a folder with no index.html in it — a 404 reached
            from the rail, which is precisely what `soon` is here to prevent.
            The data is already loaded (42 classes) and the screen is next. */
        { key: "md-classes",  href: "portal/classes/",  icon: "book",   name: "Classes",
          soon: true },
        { key: "md-staff",    href: "portal/staff/",    icon: "people", name: "Staff",
          what: "Teachers, the classes they take, the days they are in, and their DBS" }
      ]},

      { label: "The week", areas: [
        { key: "md-register", href: "portal/register/", icon: "tick",  name: "Register",
          soon: true },
        { key: "md-homework", href: "portal/homework/", icon: "pen",   name: "Homework",
          soon: true },
        { key: "md-lessons",  href: "portal/lessons/",  icon: "book",  name: "Lesson log",
          soon: true }
      ]},

      { label: "Money", areas: [
        { key: "md-fees",     href: "portal/fees/",     icon: "pound", name: "Fees",
          soon: true }
      ]},

      /*  KEEPING CHILDREN SAFE, as its own group with a plain name.

          The old system scatters this: "Incidents" in the middle of the list
          and "FIRE/DRILL" alone at the bottom under Help and Rate Us. A fire
          roll-call IS a safeguarding record — it is the list of who was in the
          building — and filing it next to the vendor's feedback link says
          something about how it was thought of. */
      { label: "Keeping children safe", areas: [
        { key: "md-concerns", href: "portal/concerns/", icon: "shield", name: "Concerns & incidents",
          soon: true },
        { key: "md-fire",     href: "portal/fire/",     icon: "shield", name: "Fire drill & roll call",
          soon: true },
        { key: "md-dbs",      href: "portal/staff/#dbs", icon: "lock", name: "DBS & checks",
          what: "Who is checked, who is due, and who has nothing on file" }
      ]},

      { label: "Talking to families", areas: [
        { key: "md-messages", href: "portal/messages/", icon: "chat",   name: "Messages",
          soon: true },
        { key: "md-notices",  href: "portal/notices/",  icon: "notice", name: "Notices to parents",
          soon: true }
      ]},

      { label: "Progress", areas: [
        { key: "md-merits",   href: "portal/merits/",   icon: "star",  name: "Merits",
          soon: true },
        { key: "md-exams",    href: "portal/exams/",    icon: "tick",  name: "Exams & tests",
          soon: true },
        { key: "md-reports",  href: "portal/reports/",  icon: "book",  name: "End-of-year reports",
          soon: true }
      ]},

      { label: "Admissions", areas: [
        { key: "md-admissions", href: "portal/admissions/", icon: "inbox",
          name: "Applications", soon: true }
      ]},

      { label: "Settings", areas: [
        { key: "md-settings", href: "portal/settings/", icon: "lock", name: "Madrasah settings",
          soon: true }
      ]}
    ]
  };
})(window);
