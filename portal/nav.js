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
   The madrasah's current system is arranged as one left-hand nav, a list, and
   row actions. That arrangement is right and is kept, because whoever has to
   switch should recognise where they are. What is NOT kept is how it looks —
   the green header bars, the four blue buttons on every row, the badge pills.
   This project has already been told once, correctly:

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
     Administration       KEPT, but four rows of the eight rather than all
       + Settings/Preferences  eight — see the long note beside that group
                          below. Backup and System are refused rather than
                          deferred, and the second Settings menu is the
                          duplication this project removed from the Admin
                          Centre a week ago.

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

  /*  WHO A ROW IS FOR.

      ADMIN is an administrator of the masjid: everything. MADRASAH is the
      role added in migration 055 for the madrasah's own staff, and it reaches
      the TEACHING side only — classes, the register, homework, the pupils in
      front of them. Not staff records, not DBS, not fees, not admissions.

      Decided with the masjid, and worth writing down because it looks
      ungenerous until you say what is behind those doors: the DBS screen
      names sixteen people working with children for whom nothing is on file.
      That is the most sensitive list in the building. It does not need to be
      the default view for every madrasah volunteer, and a role that reaches
      it is a role nobody can hand out casually.

      An area with no `needs` is shown to anybody who can open the portal.   */
  var ADMIN = ["admin"];
  var BOTH  = ["admin", "madrasah"];

  w.MadrasahNav = {
    SECTIONS: [
      { label: "Today", areas: [
        { key: "md-today",   href: "portal/",  icon: "sun",   name: "What needs doing",
          needs: BOTH,
          what: "The madrasah at a glance, and anything waiting" }
      ]},

      /*  WHO IS HERE. The four registers of people and places. "Families"
          rather than the old system's "Contacts": a contact is a family, not
          a separate species of record, and calling it Contacts is why the
          same mother appears three times under three children. */
      { label: "Who is here", areas: [
        { key: "md-pupils",   href: "portal/pupils/",   icon: "child",  name: "Pupils",
          needs: BOTH, soon: true },
        { key: "md-families", href: "portal/families/", icon: "home",   name: "Families",
          needs: BOTH, soon: true },
        { key: "md-classes",  href: "portal/classes/",  icon: "book",   name: "Classes",
          needs: BOTH, soon: true },
        //  STAFF IS ADMIN ONLY, and this is where the DBS figures live.
        { key: "md-staff",    href: "portal/staff/",    icon: "people", name: "Staff",
          needs: ADMIN,
          what: "Teachers, the classes they take, the days they are in, and their DBS" }
      ]},

      { label: "The week", areas: [
        { key: "md-register", href: "portal/register/", icon: "tick",  name: "Register",
          needs: BOTH, soon: true },
        { key: "md-homework", href: "portal/homework/", icon: "pen",   name: "Homework",
          needs: BOTH, soon: true },
        { key: "md-lessons",  href: "portal/lessons/",  icon: "book",  name: "Lesson log",
          needs: BOTH, soon: true }
      ]},

      /*  ====================================================================
          FEES — TEN ROWS WERE ASKED FOR, SEVEN ARE HERE. THE REASONS:

          Fees Dashboard   KEPT, and it is simply "Fees". The landing screen
                           of a section IS its dashboard; listing both means
                           two rows that open the same page, and whichever
                           somebody clicks second teaches them the menu is
                           unreliable.
          Query Fees       DROPPED. That is a search box, not a section. Every
                           list in this portal already has one at the top, and
                           a menu row that opens a list so you can search it is
                           a row between you and the list.
          Annual Report    KEPT. Trustees need it and it feeds the charity's
                           annual return.
          Direct Debit     DROPPED. There are no direct debits. The masjid
            Stats          takes cards through Stripe and bank transfers by
                           reference. A screen of statistics about a payment
                           method nobody uses is an empty screen that somebody
                           will one day report as broken.
          Bank Transfers   KEPT, and moved UP. This is where most madrasah fees
                           actually arrive at a Bolton masjid, and matching a
                           transfer to a family is the real daily job. The old
                           system marked it "new"; here it is the second row.
          Send Receipts    KEPT as part of a payment, NOT as its own section.
                           A receipt somebody has to remember to go and send is
                           a receipt that does not get sent. It goes out when
                           the payment is recorded, and this row is only for
                           sending one again.
          Outstanding /    KEPT. After taking money, this is the most useful
            Reminders      screen in the section.
          Fees Adjustments RENAMED "Discounts & waivers". A masjid gives
                           sibling discounts and waives fees for families in
                           hardship. "Adjustment" is accountancy for it and
                           hides what is actually being decided, which is
                           something a committee should be able to see.
          Contributions    DROPPED. Money given on top of fees is a DONATION,
                           and donations already have a screen in the Admin
                           Centre with Gift Aid attached to it. Two places to
                           look at money coming in is the two-lists problem
                           this project spent a day removing.
          Fees Structure   KEPT. What a class costs and how the sibling
                           discount works.

          ADDED: Refunds. A family leaves in November having paid the year.

          AND THE ONE THAT IS NOT A SCREEN. GIFT AID CANNOT BE CLAIMED ON
          MADRASAH FEES. A fee buys a place in a class, which makes it payment
          for a service and not a gift, and HMRC treats it accordingly. The
          masjid already claims Gift Aid on donations and the machinery is
          right there in the Admin Centre, so somebody will eventually join the
          two. Whoever builds the fees screens: there is no Gift Aid tick box
          on this side, and that is not an oversight.
          ==================================================================== */
      { label: "Fees", areas: [
        { key: "md-fees",        href: "portal/fees/",        icon: "pound", name: "Fees",
          needs: ADMIN, soon: true },
        { key: "md-transfers",   href: "portal/fees/transfers/", icon: "pound",
          name: "Bank transfers", needs: ADMIN, soon: true },
        { key: "md-outstanding", href: "portal/fees/owing/",  icon: "inbox",
          name: "Outstanding & reminders", needs: ADMIN, soon: true },
        { key: "md-discounts",   href: "portal/fees/discounts/", icon: "pound",
          name: "Discounts & waivers", needs: ADMIN, soon: true },
        { key: "md-refunds",     href: "portal/fees/refunds/", icon: "pound",
          name: "Refunds", needs: ADMIN, soon: true },
        { key: "md-structure",   href: "portal/fees/structure/", icon: "book",
          name: "What things cost", needs: ADMIN, soon: true },
        { key: "md-fees-year",   href: "portal/fees/annual/", icon: "star",
          name: "Annual report", needs: ADMIN, soon: true }
      ]},

      /*  ====================================================================
          KEEPING CHILDREN SAFE, as its own group with a plain name.

          The old system scatters this: "Incidents" in the middle of the list
          and "FIRE/DRILL" alone at the bottom under Help and Rate Us. A fire
          roll-call IS a safeguarding record - it is the list of who was in the
          building - and filing it next to the vendor's feedback link says
          something about how it was thought of.

          THREE INCIDENT ROWS WERE ASKED FOR AND THERE ARE TWO. "Recent
          Incidents" and "Add Incident" are not two sections; they are a list
          and the button on it, which is how Staff already works. It matters
          more here than anywhere else in the portal: a menu row that opens a
          blank incident form lets somebody file a report without ever seeing
          that the same concern was logged last week by somebody else. Two
          half-reports about one child do not add up to a pattern, and the
          pattern is the entire reason these records exist. So the list comes
          first and Add is on it.
          ==================================================================== */
      { label: "Keeping children safe", areas: [
        { key: "md-concerns", href: "portal/concerns/", icon: "shield",
          name: "Concerns & incidents", needs: ADMIN, soon: true },
        { key: "md-safe-reports", href: "portal/concerns/reports/", icon: "star",
          name: "Safeguarding reports", needs: ADMIN, soon: true },
        { key: "md-fire",     href: "portal/fire/",     icon: "shield",
          name: "Fire drill & roll call", needs: ADMIN, soon: true },
        { key: "md-dbs",      href: "portal/staff/#dbs", icon: "lock", name: "DBS & checks",
          needs: ADMIN,
          what: "Who is checked, who is due, and who has nothing on file" }
      ]},

      { label: "Talking to families", areas: [
        { key: "md-messages", href: "portal/messages/", icon: "chat",   name: "Messages",
          needs: BOTH, soon: true },
        { key: "md-notices",  href: "portal/notices/",  icon: "notice", name: "Notices to parents",
          needs: BOTH, soon: true }
      ]},

      { label: "Progress", areas: [
        { key: "md-merits",   href: "portal/merits/",   icon: "star",  name: "Merits",
          needs: BOTH, soon: true },
        { key: "md-exams",    href: "portal/exams/",    icon: "tick",  name: "Exams & tests",
          needs: BOTH, soon: true },
        { key: "md-reports",  href: "portal/reports/",  icon: "book",  name: "End-of-year reports",
          needs: BOTH, soon: true }
      ]},

      { label: "Admissions", areas: [
        { key: "md-admissions", href: "portal/admissions/", icon: "inbox",
          name: "Applications", needs: ADMIN, soon: true }
      ]},

      /*  ====================================================================
          ADMINISTRATION - FOUR OF THE EIGHT THAT WERE ASKED FOR.

          Admin Staff      KEPT, and it SHOWS rather than grants. It lists
                           everybody who can open this portal and why. Changing
                           that happens in the Admin Centre, because two screens
                           that both grant access is how somebody is removed in
                           one and quietly left in the other.
          School Profile   KEPT. The masjid's own name, address, contact and
                           images - including the email banner.
          Academic Year    KEPT. Terms and year labels. The register cannot be
                           built without it.
          Calendar /       KEPT, and it is the one that changes something. Those
            Holidays       dates are presently TYPED INTO the website's source
                           and can only be changed by a developer. Now the
                           madrasah amends them and the public page reads them.

          Backup           NOT BUILT, and this one is a refusal rather than a
                           tidy-up. Supabase already takes automated backups of
                           this database; a Backup button either does nothing
                           real, or it hands somebody a file of children's
                           records to carry around on a laptop. There is no
                           DPIA and no ICO registration yet. If the masjid wants
                           an export it should be a named, audited, one-record-
                           at-a-time thing with a reason attached, not a button
                           on a menu.
          System           NOT BUILT. Vendor diagnostics. Nothing a masjid does.
          Settings         NOT BUILT HERE - there is already "Madrasah settings"
                           at the foot of this rail. Two settings menus in one
                           product is exactly what was removed from the Admin
                           Centre a week ago.
          Audits           NOT BUILT HERE, and it should be built. 1,049 audit
                           rows exist and nothing shows them to anybody - hall
                           bookings, donations, invitations, failed
                           notifications. That belongs in the Admin Centre where
                           it covers the whole masjid, not in the madrasah where
                           it would need a second one later for everything else.
          ==================================================================== */
      { label: "Administration", areas: [
        { key: "md-people",   href: "portal/people/",   icon: "people",
          name: "Admin staff", needs: ADMIN,
          what: "Who can open the madrasah portal, and why" },
        { key: "md-profile",  href: "portal/profile/",  icon: "home",
          name: "School profile", needs: ADMIN,
          what: "The masjid's name, address, contact details and its images" },
        { key: "md-year",     href: "portal/year/",     icon: "book",
          name: "Academic year", needs: ADMIN, soon: true },
        { key: "md-calendar", href: "portal/calendar/", icon: "sun",
          name: "Calendar & holidays", needs: BOTH,
          what: "The whole year on one page, and the dates the website prints" }
      ]},

      { label: "Settings", areas: [
        { key: "md-settings", href: "portal/settings/", icon: "lock", name: "Madrasah settings",
          needs: ADMIN, soon: true }
      ]}
    ]
  };
})(window);
