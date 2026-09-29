/* ===========================================================================
   THE PARENTS' PORTAL'S OWN RAIL.

   Taiyabah Masjid · Bolton Central Islamic Society · Charity 1041569
   29 September 2026

   Handed to AdminShell.mount({ sections: ParentNav.SECTIONS, roles: ["parent"] })
   by the generated parent screens (tools/build_parent_screens.py).

   THIS IS NOT portal/nav.js WITH ROWS REMOVED, AND THE DIFFERENCE MATTERS.
   The staff list carries every madrasah row with a `needs` on it, and the
   shell hides the rows a role may not open. That is the right design for
   staff, who share one list. For a parent it would still be wrong, because a
   list that is FILTERED can be mis-filtered: one row with `needs` missing and
   a parent is looking at Fees. This file has no staff row in it at all, so
   there is nothing to filter and nothing to get wrong. A parent is never
   shown a staff screen's name, not even greyed out - it tells them something
   about the building that is not theirs to know, and it is one more thing to
   ring the office about.

   NO `needs` ANYWHERE. Every row here is for every parent; the database is
   what decides which children a parent sees (my_parent_children()), and no
   row in a rail is a permission.

   `soon: true` MEANS NOT BUILT, AND IT IS NOT A LINK. shell.js draws it as a
   muted <span> tagged "soon", with no href and no focus stop. There is no such
   row today: Progress was the last one and came off on 29 September, the day
   db/127 gave it a screen. A row that looks pressable and does nothing teaches
   people the page is broken, so the next unbuilt screen goes in with `soon`
   and comes off the day it exists.
   =========================================================================== */
(function (w) {
  "use strict";

  w.ParentNav = {
    SECTIONS: [
      { label: "Your children", areas: [
        { key: "pt-children",   href: "portal/parent/",            icon: "child", name: "My children",
          what: "What the madrasah holds about each of your children" },
        { key: "pt-attendance", href: "portal/parent/attendance/", icon: "tick",  name: "Attendance",
          what: "Evening by evening, and who recorded it" },
        { key: "pt-progress",   href: "portal/parent/progress/",   icon: "book",  name: "Progress",
          what: "What your child's teacher has chosen to share" },
        { key: "pt-absence",    href: "portal/parent/absence/",    icon: "pen",   name: "Report an absence",
          what: "Tell the madrasah a child will be away or late" }
      ]},
      { label: "Talk to us", areas: [
        { key: "pt-messages",   href: "portal/parent/messages/",   icon: "chat",  name: "Messages",
          what: "Write to the madrasah office and read the reply" }
      ]}
    ]
  };
})(window);
