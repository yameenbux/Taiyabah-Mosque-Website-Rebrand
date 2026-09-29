/* ===========================================================================
   Taiyabah Masjid — Madrasah, the administrators' view
   Bolton Central Islamic Society · Registered charity 1041569

   WHAT THIS REPLACED
   ------------------
   /portal/ was live and broken. Its index.html was the madrasah sign-in page;
   its app.js was a copy of the admin-centre signpost, which looks for elements
   called `no-signout` and `list-signout` that this page has never had. So it
   threw `Cannot read properties of null (reading 'addEventListener')` on every
   load and rendered nothing past the spinner. Nobody reported it, because
   nobody had a reason to open it yet.

   The sign-in, two-step and enrolment flow below is the one from /access/,
   unchanged — same shell, same views, same ids. That is deliberate: a second
   hand-written copy of an authentication flow is a second place for it to be
   wrong, and this project has already lost a portal to exactly that.

   WHAT THIS PAGE DOES NOT DO
   --------------------------
   It holds no pupil record and reads none. There is nothing to read: the
   database has no madrasah tables yet, and must not have until the work listed
   on the page itself is finished. A madrasah roll is Article 9 data.

   A teacher lands on the teachers' page and a parent is sent on to the
   parents' portal at portal/parent/. Somebody with none of those is told so,
   and what to do, rather than being shown an administrator's console.
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

  /* =========================================================================
     IS THIS A PARENT? (29 September)

     A PARENT HAS NO ROW IN user_roles, ON PURPOSE - a row would make
     current_masjid() resolve for them and widen what the staff gates might
     show (db/119, slice 1). A parent is somebody is_parent() says is one,
     because madrasah_parent_logins has their login. This page used to decide
     who somebody was from user_roles alone, so a parent fell through every
     branch into "no access" - or, when the message was the old one, into a
     staff page that said the parents' side was not built. It had been built
     for days.

     ASKED BEFORE THE TWO-STEP PROMPT, NOT AFTER. A parent has no second
     factor and the parents' portal does not ask for one, but routeAfterPassword
     below sends every account with no authenticator to enrol one. So the
     first real parent to sign in here would be told to install an
     authenticator app for a portal that does not want it. The answer has to
     exist before that decision, which is why it is not in mount().

     WHERE IT SITS AGAINST THE STAFF ROLES. Somebody who is a parent AND holds
     admin, madrasah or teacher is treated as staff - the same rule mount()
     already applies to an administrator who also teaches: they are here to
     do the job, and the parents' portal is one address away. (db/119's
     health check reports that combination as a fault, so it should not
     occur; this is what happens if it does.) A parent is asked about staff
     roles only once is_parent() has said yes, so staff pay for one small
     call and nothing else.

     IT NEVER HOLDS THE PAGE UP. The answer is true, false, or null for
     "could not tell", and null - a failed call, a refusal, three seconds of
     silence - behaves exactly as this page always did. A slow answer is
     dropped, not waited for.                                               */
  var PARENT_CHECK_MS = 3000;
  var parentState = null;      // true = a parent and nothing else; false/null = not, or unknown

  function isParentOnly() {
    return new Promise(function (resolve) {
      var done = false;
      function finish(v) { if (!done) { done = true; clearTimeout(timer); resolve(v); } }
      var timer = setTimeout(function () { finish(null); }, PARENT_CHECK_MS);
      try {
        sb.rpc("is_parent").then(function (res) {
          if (!res || res.error) { finish(null); return; }
          if (res.data !== true) { finish(false); return; }
          //  A parent. Are they also staff? Local session read, then one row query.
          sb.auth.getSession().then(function (s) {
            var u = s && s.data && s.data.session && s.data.session.user;
            if (!u) { finish(null); return; }
            sb.from("user_roles").select("role").eq("user_id", u.id).then(function (r) {
              if (!r || r.error) { finish(null); return; }
              var staff = (r.data || []).some(function (x) {
                return x.role === "admin" || x.role === "madrasah" || x.role === "teacher";
              });
              finish(!staff);
            }, function () { finish(null); });
          }, function () { finish(null); });
        }, function () { finish(null); });
      } catch (e) { finish(null); }
    });
  }

  //  Same origin, same stored session: the parents' portal signs them straight in.
  function goToParentPortal() {
    try { window.location.replace("parent/"); return true; } catch (e) { return false; }
  }

  function loadIdentity() {
    return sb.auth.getUser().then(function (res) {
      var user = res.data && res.data.user;
      if (!user) throw new Error("No active session.");
      return Promise.all([
        sb.from("profiles").select("full_name, email, must_change_password")
          .eq("id", user.id).maybeSingle(),
        sb.from("user_roles").select("role").eq("user_id", user.id)
      ]).then(function (out) {
        var errs = [];
        if (out[0].error) errs.push("profiles — " + out[0].error.message);
        if (out[1].error) errs.push("user_roles — " + out[1].error.message);
        return {
          user: user,
          profile: out[0].data || {},
          roles: (out[1].data || []).map(function (r) { return r.role; }),
          //  See mustChangeGate(). A password somebody else chose is a ticket.
          mustChange: !!(out[0].data && out[0].data.must_change_password),
          //  See isParentOnly(). Only ever true when the redirect could not be made.
          isParent: parentState === true,
          errors: errs
        };
      });
    });
  }

  /* =========================================================================
     THE CLAIM
     ======================================================================= */
  /* =========================================================================
     THE VOLUNTEER LIST

     WHAT THIS PAGE IS FOR. Migration 023 stores registrations. Until this
     page existed there was exactly one way to read them back: SQL in the
     Supabase editor — which nobody in the office is going to run, so the
     registrations would pile up unread and the form would have been a way of
     collecting people's mobile numbers for nothing.

     That mistake has now been made twice on this site: the course sign-ups in
     September, and Gift Aid the same week. Turning a form on and giving a
     human a way to read it back are two jobs, and only the first one feels
     finished.

     THE QUESTION THE COMMITTEE ACTUALLY ASKED is not "who registered" but
     "have we got enough people to open?" — so the counts are at the top and
     the list is underneath, rather than the other way round.
     ======================================================================= */
  /* =========================================================================
     THE MADRASAH, AS AN ADMINISTRATOR SEES IT

     Modelled on the shape of the system the masjid uses today — four headline
     counts, then the areas — so that whoever has to switch recognises where
     they are. Not modelled on its contents: this database holds no pupil
     record, and will not until the work listed on the page is done.

     THE FOUR FIGURES ARE NOT THIS SYSTEM'S. They are what the current system
     holds, typed in below, and the page says so twice: once in the panel above
     them and once on every tile. That is not excessive. A number on the screen
     an administrator lands on becomes a number reported to the committee, and
     "539 pupils" would be true of the masjid and false of this database.

     NOTHING IS CLICKABLE, deliberately, and the tiles are DIVs rather than
     dead buttons. A control that looks pressable and does nothing teaches
     people the page is broken, and then they stop reporting when it really is.
     ======================================================================= */
  var madrasah = (function () {

    /* Typed in, in one place, with the date they were read. When the import
       happens this whole object goes and the counts come from the database —
       which is why every figure the page draws goes through here rather than
       being written into the HTML. */
    /*  TWO OF THESE FOUR ARE NOW THIS DATABASE'S OWN, AND TWO ARE NOT.

        Until 18 September every figure here belonged to the system this
        replaces, and the page said so on every tile. Then the staff and the
        classes were imported — and for a few hours this page went on saying
        "nothing has been imported yet" underneath forty teachers that had
        been. A page that states the opposite of the truth is worse than one
        that says nothing, because somebody acts on it.

        So `mine` marks the tiles this database can answer for. Those get
        their number from madrasah_overview() at load; the other two keep
        their caveat, because it is still true of them. */
    /*  THREE OF THESE FOUR ARE NOW THIS DATABASE'S OWN, AND IT WAS WRONG FOR
        A DAY THAT THEY WERE NOT.

        On 18 September the pupils were imported and this object was not
        changed, so the page went on showing **539 Students** with the words
        "In the madrasah's current system, not imported" underneath, beneath a
        panel reading "it holds no pupil records at all" — while 543 children
        sat in madrasah_pupils. All three statements were false, and the
        figure was wrong by four on top of that.

        That is the exact failure the note below warned about when the STAFF
        were imported a week earlier, repeated one table later. A page an
        administrator lands on is the page whose numbers reach the committee.

        So the three tiles this database can answer for now take their number
        from madrasah_overview(), and the fourth — Contacts — keeps its caveat
        because it is still true of it: there is no families table yet. The
        day that is imported, its `n` goes and `mine` goes on, and nothing
        else here changes.                                                   */
    var CURRENT = {
      as_at: "13 September 2026",
      where: "the madrasah\u2019s current system",
      counts: [
        { n: null, key: "pupils", mine: true, k: "Children",
          s: "Every child on the roll. The most sensitive thing the masjid holds." },
        { n: null, key: "staff", mine: true, k: "Teachers",
          s: "Who teaches, which classes they take, the days they are in and whether their DBS is in date." },
        { n: null, key: "classes", mine: true, k: "Classes",
          s: "Every class and who is responsible for it." },
        { n: 962, k: "Contacts",
          s: "Parents and guardians — who to ring, and who may collect." }
      ]
    };

    //  Filled by madrasah_overview() before draw() runs. Null until then, and
    //  a tile with a null number says so rather than showing a nought — "0
    //  teachers" and "not loaded yet" are different things and only one of
    //  them is alarming.
    var MINE = null;
    var TODAY = null;

    /* What each area is FOR, in the words somebody in the office would use.
       Written now rather than when it is built: the description is the brief,
       and a brief written after the screen is a description. */
    var AREAS = [
      { t: "Students",
        d: "The roll. Which class each child is in, who brings them, what the " +
           "masjid has been told about medical needs, and who may collect them." },
      { t: "Teachers",
        d: "Who teaches, what they take, and — the part the current system " +
           "tracks and this one does not yet — whether their DBS is in date." },
      { t: "Classes",
        d: "Groups and times, how full each one is, and which teacher is " +
           "responsible for it on any given day." },
      { t: "Contacts",
        d: "Parents and guardians, kept once and linked to their children, so " +
           "a changed phone number is changed in one place rather than four." }
    ];

    /* The gate, stated on the page it gates. The project's own record says the
       DPIA must be finished before the first real pupil record is entered, and
       that the first pupil record IS the next milestone. A list like this kept
       in a document gets read once. */
    /*  THIS WAS A LIST OF THINGS TO DO BEFORE THE FIRST PUPIL RECORD, AND
        THE FIRST PUPIL RECORD WAS CREATED ON 18 SEPTEMBER.

        543 of them. So a list headed "Before the first pupil record", with
        every item un-ticked, was describing a gate that had already been
        walked through - and sitting directly under a panel that said pupils
        had not been imported. Three separate statements of the same untruth
        on one screen.

        A compliance list that is wrong is worse than no compliance list. It
        gets read once, found to be stale, and thereafter ignored - including
        on the day one of its items genuinely is outstanding.

        So each item now carries its STATE and how that state is known.
        `done` is only set where there is something to point at: the masjid
        confirming it, or the database itself. Two items are left open because
        nobody has told me they are finished, and guessing on those two is
        precisely the failure this rewrite is fixing.                        */
    /*  THREE STATES, NOT TWO, AND THE MIDDLE ONE IS THE POINT.
    
        This list was done / not done. Asked, reasonably: "hasn't this updated?
        we have created these?" — because the assessment, the privacy notice
        and the breach procedure were all written on 19 September, and the
        screen still said STILL OUTSTANDING against all three.
    
        The screen was RIGHT and it was USELESS, which is a combination worth
        naming. Writing a document is not completing the action:
    
            Article 13 is discharged by TELLING PARENTS, not by having a file.
            A breach procedure is not adopted until somebody is named in it.
            A lawful basis is not recorded until the document carrying it is
            signed.
    
        So none of them could honestly be ticked. But "still outstanding — it
        needs to exist before it is needed" against a procedure that now exists
        tells the reader nothing true, and it hides the fact that the work is
        finished and the decision is somebody else's.
    
        Hence a third state: WITH THE TRUSTEES. Written, waiting on a signature
        or on somebody being named. It is not done and the screen does not
        pretend it is — but it says where the thing actually is, and `what`
        says the one action that closes it.
    
        A two-state list forces a lie in one direction or the other whenever
        real work sits between starting and finishing. Most of the work on a
        list like this sits exactly there.                                   */
    var BEFORE = [
      /*  ADDED 20 SEPTEMBER WHEN THE FEES SECTION WAS BUILT, AND MOVED TO
          "WITH THE TRUSTEES" THE SAME DAY WHEN THE WORK WAS DONE.

          It was written here as outstanding because migration 068 created
          two tables holding a parent's name, email address and telephone
          number, and the v1.0 assessment scoped children and staff — a
          guardian is neither.

          That is now closed on our side. The assessment is at v1.1 and the
          privacy notice at v1.1; both cover parents, the reminder, and the
          two clocks the fee record sits on. What is left is a signature,
          which is why this reads the same as the three below it.

          It stays on the list rather than disappearing, because writing a
          document is not completing an action — the same reason the other
          three are here.                                                  */
      { t: "Parents' contact details are covered by the assessment", waiting: true,
        d: "The fees section holds a parent's name, email address and " +
           "telephone number for each family. That was outside the v1.0 " +
           "assessment, which scoped children and staff. The assessment is " +
           "now at v1.1 and covers it — the lawful basis, the retention, " +
           "three new risks about sending email about money, and five new " +
           "measures. The privacy notice is at v1.1 with a section written " +
           "for parents about what is held about them.",
        what: "Sign v1.1 rather than v1.0. Action A11 in it says fee " +
              "reminders must not be switched on until the privacy notice " +
              "has actually reached parents \u2014 writing to somebody about " +
              "money using details they were never told you held is the " +
              "wrong order to do this in." },

      { t: "Data protection impact assessment", waiting: true,
        d: "Written and dated 19 September 2026 — twenty pages, twelve risks, " +
           "nine actions. It is not complete until a trustee signs it, because " +
           "the decisions it records take effect on signature.",
        what: "A trustee and a named Data Protection Lead sign the last page." },

      { t: "Issue a privacy notice to parents and staff", waiting: true,
        d: "Written, nine pages, covering children in Part A and staff in " +
           "Part B. It is not issued, and Article 13 is discharged by TELLING " +
           "people — not by having the document. 543 children’s records are " +
           "held and no notice has reached a parent yet. This is still the " +
           "most significant gap on this page.",
        what: "Fill in the Data Protection Lead’s contact details, delete the " +
              "instruction box, then hand it out and put it on the website." },

      { t: "Agree a breach procedure with a 72-hour route to the ICO",
        waiting: true,
        d: "Written, eleven pages, with the seven steps, ten worked examples, " +
           "a breach record and the register. It is not adopted, and an " +
           "unadopted procedure names nobody — which is the single most common " +
           "reason the 72 hours is missed.",
        what: "Name a Lead, a DEPUTY and technical support with mobile numbers, " +
              "then sign it. The deputy is not optional: 72 hours does not pause " +
              "for a weekend." },

      { t: "Write down the lawful basis and the Article 9 condition",
        waiting: true,
        d: "Decided and written into the assessment: legitimate interests under " +
           "Article 6(1)(f), and Article 9(2)(d) — the condition for a " +
           "not-for-profit religious body keeping records about its own members.",
        what: "Closes automatically when the assessment above is signed. Nothing " +
              "separate to do." },

      { t: "Register with the ICO", done: true,
        d: "Confirmed by the masjid. Charities pay the tier 1 fee of £52 " +
           "regardless of size. Processing this data without it is an offence." },

      { t: "Confirm the data can actually come out of the current system",
        done: true,
        d: "Answered by doing it. 543 pupil records, 45 classes and 40 staff " +
           "came across on 18 September, so the export works and nobody has to " +
           "re-key anything — which was the single biggest risk to this " +
           "project, and it is now behind us." },

      { t: "Make two-step a database rule for pupil tables, not a page rule",
        done: true,
        d: "Done, and stronger than it was asked for. madrasah_pupils and " +
           "madrasah_pupil_classes have row-level security FORCED with no " +
           "policies at all, so the tables cannot be read directly by anyone — " +
           "every route in goes through a function that calls verified_admin(), " +
           "which is is_aal2() and is_admin(). A page rule could be bypassed by " +
           "calling the API; there is no API call that reaches these tables." },

      /*  ADDED 19 SEPTEMBER, out of the DPIA's own risk register. The roll was
          COPIED from the previous system, not moved, so the masjid is running
          two sets of the same children's records and remains responsible for
          both. Nothing on this screen said so. */
      { t: "Delete the children’s records from the previous system",
        done: false,
        d: "The roll was copied across on 18 September, not moved. Until those " +
           "records are deleted at source the masjid holds two copies of the " +
           "same 543 children, one of them in a system it has stopped using and " +
           "is no longer actively governing. Retention, security and subject " +
           "access all apply to that copy too.",
        what: "Confirm this system is correct, then delete at source and record " +
              "the date." }
    ];

    /* Named so nothing is quietly forgotten at changeover. NOT a plan — some
       of this the masjid may not need, and copying the old system feature for
       feature is how you inherit somebody else's decisions. */
    var REST = [
      "Register", "Teacher logs", "Fees", "Events and trips", "Incidents",
      "Messages", "Newsletters and SMS", "Student diary", "Homework",
      "Exams and tests", "End-of-year reports", "Merits and achievements",
      "Products", "Settings"
    ];

    /*  WHO GETS THE CONSOLE.

        It was administrators and nobody else, because when this was written
        an administrator was the only kind of person who could reach the
        madrasah at all. Migration 055 added a `madrasah` role for the
        madrasah's own staff, and if this gate had been left alone they would
        have signed in, been handed the role, and landed on "you have no
        access here" — a role that grants nothing is worse than no role,
        because somebody has been told they were given one.

        WIDER HERE DOES NOT MEAN WIDER EVERYWHERE. This opens the console.
        Every screen reached from it asks the database its own question, and
        staff, DBS, fees and admissions all ask verified_admin(). See the note
        beside ADMIN and BOTH in nav.js. */
    function canSee(identity) {
      return identity.roles.indexOf("admin") !== -1
          || identity.roles.indexOf("madrasah") !== -1;
    }

    /* WHAT A TEACHER WILL BE ABLE TO DO.
       Written now, in the words somebody in a classroom would use, rather than
       when it is built — the list IS the brief, and a list written afterwards
       is a description. Anything the masjid needs that is missing here is
       cheaper to add today than after the screens exist. */
    /*  WHAT IS NOT BUILT YET. "Take the register" was the first item on this
        list until 28 September, when a teacher signed in, saw a live Register
        in the rail and a card for their own class - and then this list telling
        them the register was coming soon. A list of promises that includes
        something already delivered teaches people not to believe the rest of
        it. Raising a concern is also live in the register screen, so it is
        marked rather than promised. */
    var TEACHER = [
      { t: "Raise a concern", live: true,
        d: "Open a child from your register and report an incident or a " +
           "safeguarding worry. It is logged with your name against it." },
      { t: "Write up the lesson",
        d: "What was covered and how far the class got, so whoever takes them " +
           "next week is not starting from a guess." },
      { t: "Record how each child is getting on", live: true, href: "progress/",
        d: "Sabaq, sabqi and manzil for each child in your class, with a note " +
           "for the parent and a note for yourself. You choose what a family " +
           "sees; your own note is never shown to them." },
      { t: "Set and see homework",
        d: "What was set, who has done it, and who needs chasing." },
      { t: "End-of-year reports",
        d: "Build the report from what is already recorded across the year " +
           "instead of writing it from memory in one weekend." },
      { t: "Message a parent",
        d: "Through the masjid, so the conversation is on the record and " +
           "nobody has to give out a personal number." },
      { t: "See your classes and times",
        d: "When you are on, which room, and who is covering when you cannot " +
           "be there." }
    ];

    /* WHAT A PARENT CAN DO, AND WHAT THEY CANNOT YET. Rewritten 29 September:
       this was a list of eight promises headed "none of it is built", and
       four of the eight were built. A row with `live` and an href is a link
       into portal/parent/; every other row is still a promise, and the
       heading above the list says so. Fees, collection permissions and
       end-of-year reports are genuinely not built and are not marked. */
    var PARENT = [
      { t: "Tell the masjid your child is absent", live: true, href: "parent/absence/",
        d: "Before the lesson, in a few seconds, so the teacher is not ringing " +
           "round to find out." },
      { t: "See how your child is getting on", live: true, href: "parent/progress/",
        d: "Sabaq, sabqi and manzil, and a note from the teacher, for what the " +
           "teacher has chosen to share with you." },
      { t: "See attendance", live: true, href: "parent/attendance/",
        d: "Evening by evening, and who recorded it." },
      { t: "Message the office", live: true, href: "parent/messages/",
        d: "Write to the madrasah and read the reply, instead of ringing " +
           "between 5 and 7." },
      { t: "See what the madrasah holds about your children", live: true, href: "parent/",
        d: "Their details, medical notes and allergies, and who is on your family record. " +
           "Something wrong? Tell the office from there and they will correct it." },
      { t: "Pay the fees",
        d: "Online, at any hour, with a receipt. Not built: fees are still " +
           "paid at the office." },
      { t: "Say who may collect them",
        d: "Who is allowed to take your child home, and who is not. Not built: " +
           "tell the teacher or the office." },
      { t: "End-of-year reports",
        d: "The report, when it is ready. Not built." }
    ];

    /*  A TEACHER'S OWN CLASSES.
        -------------------------------------------------------------------
        madrasah_my_classes() returns the classes this teacher teaches and no
        others. The list is short - most teach one or two - so it is cards
        rather than a table, sized for a thumb, because a teacher opens this
        standing up at ten past five.

        THE REGISTER IS THE ONLY LINK. Everything else a teacher might expect
        to tap is still being built, and a row that loads and then refuses
        teaches somebody the system is broken rather than that the job is not
        theirs yet.  */
    /*  THE PASSWORD GATE.

      Deliberately plain and deliberately final: one field, one rule, and no
      way past it. There is no "remind me later", because later is the same
      drawer with the same slip in it.

      NO EMAIL RESET EXISTS for these accounts - not one member of staff has
      an email address, which is why the initial password was on paper in the
      first place - so the screen says who to ask rather than offering a link
      that goes nowhere.                                                     */
  /*  THE PASSWORD GATE IS AN OVERLAY, AND IT CARRIES ITS OWN STYLES.
   *
   *  The first version of this appended a styled <section> into the page and
   *  set `hidden` on everything else. On the generated screens that looked
   *  right, and on the one page a teacher actually lands on after signing in
   *  - portal/index.html - it produced a mess: the card spread the full width
   *  of the window with its left third underneath the rail, the portal drew
   *  itself underneath, and the rail sat there offering Admin Centre.
   *
   *  Three separate reasons, all the same shape:
   *
   *    1. .pw-gate's layout rules live in admin/screen.css. The portal landing
   *       page loads fonts.css and shell.css only, so the card had no width,
   *       no padding and no max-width.
   *    2. Hiding things with the `hidden` attribute depends on
   *       [hidden]{display:none !important}, which is declared in each
   *       SCREEN stylesheet. The landing page loads none of them.
   *    3. It hid .bk, .ashell and .ashell-bar. It never hid the rail on a
   *       page whose rail is .shell, and it never stopped a request already
   *       in flight from un-hiding a panel when it came back.
   *
   *  So this version assumes nothing about the page it is on. It injects the
   *  handful of rules it needs, and it covers the viewport rather than asking
   *  the rest of the document to please get out of the way. A gate that works
   *  only where the right stylesheet happens to be loaded is not a gate.
   */
  function mustChangeGate(identity) {
    //  OWN STYLES, INJECTED ONCE. Everything the overlay needs, so that it
    //  does not matter which stylesheets this particular page loaded.
    if (!document.getElementById("pw-gate-css")) {
      var st = document.createElement("style");
      st.id = "pw-gate-css";
      st.textContent =
        "#pw-shade{position:fixed;top:0;right:0;bottom:0;left:0;z-index:2147483000;"
        + "background:#f7f3ec;overflow:auto;-webkit-overflow-scrolling:touch;"
        + "display:block;padding:24px 16px 64px;}"
        + "#pw-shade *{box-sizing:border-box;}"
        + "#pw-gate{max-width:520px;margin:6vh auto 0;background:#fffdf8;"
        + "border:1px solid #e7ddcc;border-radius:14px;padding:28px 30px;"
        + "box-shadow:0 10px 30px rgba(60,35,20,.10);"
        + "font-family:ui-sans-serif,system-ui,-apple-system,'Segoe UI',sans-serif;"
        + "color:#2b2118;}"
        + "#pw-gate h2{margin:0 0 10px;font-size:1.5rem;line-height:1.25;"
        + "font-family:Georgia,'Times New Roman',serif;color:#5b1226;}"
        + "#pw-gate p{margin:0 0 16px;line-height:1.6;font-size:1rem;}"
        + "#pw-gate .pw-fld{display:block;margin:0 0 14px;}"
        + "#pw-gate .pw-fld span{display:block;margin-bottom:6px;font-size:.9rem;"
        + "font-weight:600;letter-spacing:.01em;}"
        + "#pw-gate .pw-fld input{display:block;width:100%;padding:11px 12px;"
        + "font-size:1rem;border:1px solid #cdbfa8;border-radius:8px;"
        + "background:#fff;color:inherit;}"
        + "#pw-gate .pw-fld input:focus{outline:3px solid #b9903f;outline-offset:1px;}"
        + "#pw-gate .pw-hint{font-size:.9rem;color:#6d6155;}"
        + "#pw-gate .pw-err{margin:0 0 14px;padding:10px 12px;border-radius:8px;"
        + "background:#fdecec;border:1px solid #e4b4b4;color:#8a1c1c;font-size:.95rem;}"
        + "#pw-gate button{display:block;width:100%;margin:4px 0 16px;padding:13px 16px;"
        + "font-size:1.02rem;font-weight:700;cursor:pointer;border:0;border-radius:9px;"
        + "background:#c8a34a;color:#2b2118;font-family:inherit;}"
        + "#pw-gate button:disabled{opacity:.6;cursor:default;}"
        //  Declared here too, because the page underneath may not declare it.
        + "#pw-shade [hidden]{display:none !important;}";
      document.head.appendChild(st);
    }

    var who = (identity.profile && identity.profile.full_name) || "";
    /*  ITS OWN ESCAPE, AND THE REASON IT NEEDS ONE.
        This overlay is deliberately self-contained — its own styles, its own
        markup, nothing borrowed from the page it lands on — because it has to
        work on whichever screen a person happens to open first. The greeting
        was the one line that broke that rule: it called the module's esc(),
        which is a LOCAL of another function in every one of these files, so
        it threw "esc is not defined" the moment it tried to greet anybody by
        name. Every teacher login carries a name, and every one of them is
        created with must_change_password set, so this was the first thing
        all 39 would have met. The second time this project has had a fault
        that made every teacher login unusable; the first was four NULL
        columns in auth.users (db/094). Found 29 September by the parent
        portal's own test suite, which met it because a parent meets this
        screen before any other. */
    function pwEsc(v) {
      return String(v == null ? "" : v)
        .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
    }

    var shade = document.createElement("div");
    shade.id = "pw-shade";
    shade.setAttribute("role", "dialog");
    shade.setAttribute("aria-modal", "true");
    shade.setAttribute("aria-labelledby", "pw-gate-h");
    shade.innerHTML =
      '<section id="pw-gate">'
      + '<h2 id="pw-gate-h">Choose your own password</h2>'
      + "<p>Assalamu alaikum" + (who ? ", " + pwEsc(who) : "")
      + ". The password you were given was written on a slip of paper, so it "
      + "is not private. Choose one only you know before going any further.</p>"
      + '<div class="pw-err" id="pw-err" hidden></div>'
      //  THE CURRENT PASSWORD, ASKED FOR ON PURPOSE.
      //
      //  Supabase is set to require it, and that setting is worth keeping.
      //  These screens get opened on a shared machine in the masjid office.
      //  Without it, anybody who finds a session somebody left signed in can
      //  change the password and own the account outright; with it they
      //  cannot, because the slip is in the teacher's pocket.
      //
      //  It is the password they typed a moment ago, so this is one line of
      //  friction, once, ever. Asking is also more robust than carrying what
      //  they typed on the sign-in screen: this gate has to work on a page
      //  opened fresh days later with the session still valid.
      + '<label class="pw-fld"><span>The password from your slip</span>'
      + '<input type="password" id="pw-now" autocomplete="current-password"></label>'
      + '<label class="pw-fld"><span>Your new password</span>'
      + '<input type="password" id="pw-one" autocomplete="new-password"></label>'
      + '<label class="pw-fld"><span>Type it again</span>'
      + '<input type="password" id="pw-two" autocomplete="new-password"></label>'
      + '<p class="pw-hint">At least ten characters. Something you can '
      + "remember and nobody could guess &mdash; three unrelated words is "
      + "better than one word with numbers after it.</p>"
      + '<button type="button" id="pw-go">Save it and carry on</button>'
      + '<p class="pw-hint">There is no email reset on a madrasah login, '
      + "because the madrasah does not hold your email address. If you forget "
      + "this one, the office has to set you a new one.</p>"
      + "</section>";

    //  LAST CHILD OF BODY, so it paints above anything that mounts later -
    //  the rail mounts itself into the document and would otherwise arrive
    //  after us.
    document.body.appendChild(shade);

    //  Belt and braces, not the mechanism. The overlay is what stops the page
    //  being READ; this stops it being TABBED INTO behind the overlay, which
    //  a sighted person never notices and a keyboard or screen-reader user
    //  hits immediately.
    //
    //  EVERY SIBLING, not a list of class names. The first version named
    //  ".bk, .ashell, .ashell-bar" and missed .md-lead and .tc-classes on the
    //  one page this actually runs on, because a list of selectors is a guess
    //  about a page you are not looking at. "Everything except me" needs no
    //  such guess and cannot go stale when a screen adds a container.
    var sib = document.body.children;
    for (var i = sib.length - 1; i >= 0; i--) {
      var n = sib[i];
      if (n === shade || n.tagName === "SCRIPT" || n.tagName === "STYLE") continue;
      n.setAttribute("hidden", "hidden");
      n.setAttribute("aria-hidden", "true");
      //  setProperty WITH "important", not style.display = "none".
      //  admin/shell.css carries  body.has-ashell .shell{display:block
      //  !important}  and an inline declaration without !important loses to
      //  an !important one in a stylesheet. The rail stayed on screen behind
      //  the gate until this line said important too. Same collision this
      //  project hit with the print stylesheets.
      n.style.setProperty("display", "none", "important");
    }
    //  And stop the document scrolling underneath on a phone.
    document.documentElement.style.overflow = "hidden";
    document.body.style.overflow = "hidden";

    var one = document.getElementById("pw-now");
    if (one && one.focus) { try { one.focus(); } catch (e) {} }

    function fail(m) {
      var e = document.getElementById("pw-err");
      if (e) { e.textContent = m; e.removeAttribute("hidden"); }
    }

    document.getElementById("pw-go").addEventListener("click", function () {
      var now = document.getElementById("pw-now").value;
      var a = document.getElementById("pw-one").value;
      var b = document.getElementById("pw-two").value;
      if (!now) { fail("Put in the password from your slip first."); return; }
      if (a.length < 10) { fail("That is too short. Ten characters or more."); return; }
      if (a !== b) { fail("The two do not match."); return; }
      if (a === now) { fail("That is the same password. Choose a different one."); return; }
      var go = document.getElementById("pw-go");
      go.disabled = true; go.textContent = "Saving…";
      //  current_password, IN SNAKE CASE, AND THE CASE IS THE WHOLE POINT.
      //
      //  The API is Go, and its struct field is
      //      CurrentPassword *string `json:"current_password,omitempty"`
      //  so current_password is the only spelling it reads.
      //
      //  One Supabase docs page shows updateUser({ currentPassword }) in
      //  JavaScript, and a newer client maps that to the snake_case field
      //  before sending. THE VENDORED CLIENT DOES NO SUCH MAPPING - its
      //  updateUser builds the body as Object.assign({}, attributes) with no
      //  whitelist and no transform. So camelCase went out as camelCase, the
      //  server saw no current_password at all, and said so.
      //
      //  Sending the snake_case name works either way: a client that maps
      //  camelCase still passes an unrecognised key straight through, and Go
      //  ignores JSON fields it does not know.
      sb.auth.updateUser({ password: a, current_password: now }).then(function (res) {
        if (res.error) throw new Error(res.error.message);
        return sb.rpc("clear_must_change_password");
      }).then(function () {
        //  Straight back in, rather than asking them to sign in again with
        //  the password they have just this second chosen.
        document.documentElement.style.overflow = "";
        document.body.style.overflow = "";
        window.location.reload();
      })["catch"](function (e) {
        go.disabled = false; go.textContent = "Save it and carry on";
        var m = (e && e.message) ? e.message : "";
        //  SAY THE USEFUL THING. The API's own wording for a wrong current
        //  password is about fields and parameters, which tells a teacher
        //  nothing about what to do next.
        //  DO NOT CLAIM TO KNOW WHICH. The API returns the SAME words when
        //  the current password is missing as when it is wrong, so "that is
        //  not the password on your slip" was a guess dressed as a fact - and
        //  it was the wrong guess: the password was right and the field name
        //  was not. Say what to check, not what went wrong.
        if (/current password|invalid.*credential|not correct/i.test(m)) {
          fail("That was not accepted. Check the password from your slip is "
               + "exactly as printed, capital letters and dashes included. If "
               + "it still will not take it, the office can set you a new one.");
        } else if (/weak|pwned|compromis|breach/i.test(m)) {
          fail("That password has appeared in a known data breach. Please "
               + "choose a different one.");
        } else {
          fail("That could not be saved. " + m);
        }
      });
    });
  }


  //  ---------------------------------------------------------------
  //  TONIGHT
  //  ---------------------------------------------------------------
  function drawTonight(d, toTake, children, marked, away) {
    var host = el("tc-tonight"), lab = el("tc-tonight-lab"), gate = el("tc-gate");
    if (!host) return;

    //  THE GATE, IN WORDS, READ FIRST. attendance_permitted() travels with
    //  the classes, so the teacher is told why the register will not open
    //  BEFORE they walk into a room and try to take it - and before the
    //  Tonight tiles below, which it governs. See the Sept 28 report, item
    //  1: three separate elements once kept inviting a teacher to "take
    //  the register" directly underneath this same sentence saying there
    //  was nothing to do. permitted is checked for the exact boolean
    //  true/false Postgres sends, never merely truthy/falsy.
    var p = d.permitted || {};
    var permitted = (p.permitted === true);
    //  THREE STATES, NOT TWO. permitted READS FALSE FOR BOTH "known
    //  forbidden" (p.permitted === false) AND "not known to be allowed"
    //  (p.permitted missing, null, or anything else) - which correctly
    //  fail-closes every invitation on this page either way. But the GATE
    //  TEXT used to speak only on the strict false, so a missing/malformed
    //  permitted left a teacher with no invitation AND no reason: a locked
    //  page saying nothing. Reviewed 28 September - that reads as the
    //  system being broken, not closed, and sends a teacher back to paper.
    //  So the gate now speaks in the "unknown" case too, with its own
    //  short line that does not invent a reason it does not have (never
    //  the 330-families sentence below, which is a specific claim this
    //  branch has no evidence for).
    if (gate) {
      if (p.permitted === true) {
        gate.hidden = true;
      } else if (p.permitted === false) {
        gate.textContent = "The register is not open yet. " + (p.why || "")
          + " The office is doing this \u2014 there is nothing for you to do "
          + "about it, and your class list below is correct in the meantime.";
        gate.hidden = false;
      } else {
        gate.textContent = "The register is not open at the moment. The "
          + "office can say why.";
        gate.hidden = false;
      }
    }

    var tiles = [];
    tiles.push({
      n: children,
      k: children === 1 ? "child in your care" : "children in your care",
      s: "On the roll of your class"
         + (d.rows && d.rows.length > 1 ? "es" : "") + " tonight."
    });

    //  THE "STILL TO TAKE" TILE ONLY APPEARS WHEN MARKING IS ACTUALLY
    //  PERMITTED. #tc-gate above already says there is nothing to do and
    //  why, when it is not - a tile reading "1 REGISTER STILL TO TAKE"
    //  right beside that sentence contradicted it in production. The
    //  class list itself (drawMyClasses(), below) still shows - the gate
    //  promises the roll is correct - only the invitation to act stands
    //  down.
    //
    //  "A register taken tomorrow is somebody remembering." now lives in
    //  ONE place - the outstanding-registers prompt (drawMyClasses(),
    //  below), where it argues for acting now. Said twice on one screen it
    //  read as a template that had slipped rather than as a point.
    if (permitted && toTake !== null) {
      tiles.push(toTake === 0
        ? { n: "\u2713", k: "every register taken",
            s: "Nothing left to do on the register tonight." }
        : { n: toTake,
            k: toTake === 1 ? "register still to take" : "registers still to take",
            s: "Still to take tonight." });
    }

    //  Only once somebody has started. See the note above.
    if (marked > 0) {
      tiles.push({ n: marked - away, k: "here tonight",
                   s: away === 0 ? "Nobody marked away."
                      : away + (away === 1 ? " marked away." : " marked away.") });
    }

    host.innerHTML = tiles.map(function (t) {
      return '<div class="md-count">'
           + '<span class="n">' + esc(t.n) + "</span>"
           + '<span class="k">' + esc(t.k) + "</span>"
           + '<span class="s">' + esc(t.s) + "</span></div>";
    }).join("");
    if (lab) lab.hidden = false;
  }

  function drawMyClasses() {
      var host = el("tc-classes");
      if (!host) return;
      sb.rpc("madrasah_my_classes").then(function (res) {
        if (res.error) throw new Error(res.error.message);
        var d = res.data || {};
        if (d.allowed === false) { host.innerHTML = ""; return; }
        var when = el("tc-when");
        var rows = d.rows || [];

        if (!rows.length) {
          //  SAID IN WORDS. A teacher whose login is not joined to a staff
          //  row would otherwise see an empty screen and conclude the system
          //  had lost them.
          host.innerHTML = '<div class="tc-none">' +
            esc(d.why || "No classes are recorded against you yet. Ask the " +
                         "office to put you against your classes.") + "</div>";
          if (when) when.textContent = "";
          return;
        }

        //  DONE MEANS HANDED IN, AND ONLY THAT. A register is finished when
        //  the database says state === 'submitted' (db/118 sends it) - not
        //  when every child happens to carry a mark. A teacher who marks all
        //  twelve and presses Save but not Hand-in has NOT handed anything
        //  in, and the office is told so on Monday; this page used to read
        //  "every register taken - nothing left to do" for that very class.
        //  A class with nobody on its roll is not due (register_due() says
        //  so and submit_register() refuses it), so it is neither "taken"
        //  nor "still to take": it is counted in neither.
        var done = 0, due = 0, children = 0, marked = 0, away = 0;
        for (var i = 0; i < rows.length; i++) {
          if (rows[i].on_roll > 0) {
            due++;
            if (rows[i].state === "submitted") done++;
          }
          children += (rows[i].on_roll || 0);
          marked   += (rows[i].marked  || 0);
          away     += (rows[i].away    || 0);
        }
        var toTake = due - done;

        //  TONIGHT, IN THREE NUMBERS AND NO NAMES.
        //
        //  Every figure here is summed from the classes this teacher
        //  actually teaches, so it is theirs and not the madrasah's. Not one
        //  child is named: this page sits open on a desk in a room people
        //  walk through, and "ten children" is a fact somebody can glance at
        //  while "these ten children" is a record left on display.
        //
        //  A number with nothing to do about it is not a tile. "Here
        //  tonight" only appears once a register has actually been started,
        //  because 0 of 10 before the lesson begins reads as an empty room
        //  rather than as a register nobody has taken yet.
        drawTonight(d, due === 0 ? null : toTake, children, marked, away);

        //  permitted READ ONCE HERE TOO, the same exact-boolean test
        //  drawTonight() just used for #tc-gate and the "still to take"
        //  tile - so the class-card action and the "Your classes" line
        //  below can never disagree with what the gate and the tile just
        //  said.
        var p = d.permitted || {};
        var permitted = (p.permitted === true);

        //  THE OUTSTANDING NAG. GATED ON THE SAME attendance_permitted()
        //  drawTonight() JUST READ TO DRAW #tc-gate, ABOVE.
        //
        //  Right now attendance_permitted() is false: 330 families have not
        //  been told about the register, and mark_register() refuses every
        //  mark until they are. Not one mark has ever been made, so
        //  my_registers_outstanding() answering a real number is not a job
        //  a teacher can act on - #tc-gate already says so, in these exact
        //  words: "there is nothing for you to do about it". A nag drawn
        //  UNDERNEATH that sentence, saying registers are waiting and to
        //  take them now, would tell the same teacher two contradictory
        //  things on one screen and send them to a link that will refuse
        //  them. So this is only ever fetched, let alone drawn, once
        //  permitted reads exactly true.
        if (permitted) {
          sb.rpc("my_registers_outstanding").then(function (res) {
            if (res.error) return;
            var od = res.data || {}, orows = od.rows || [], box = el("tc-outstanding");
            if (!box) return;
            //  THE BACKLOG, NOT THE BARE TOTAL. my_registers_outstanding()
            //  (db/104) windows current_date-14 TO current_date INCLUSIVE
            //  OF TONIGHT - checked against its own source rather than
            //  assumed - so its bare count double-counts the same evening
            //  the Tonight tile above already names as "N register(s)
            //  still to take", under a different word ("still to hand
            //  in") for what reads as the same fact. Excluding tonight's
            //  own date (d.on_date - the server's own idea of today,
            //  never the browser's clock, which can disagree with it near
            //  midnight) leaves only registers from EARLIER evenings,
            //  which is the different question this prompt actually
            //  answers. See the Sept 28 report, item 2.
            var earlier = [];
            for (var i = 0; i < orows.length; i++) {
              if (orows[i].on_date !== d.on_date) earlier.push(orows[i]);
            }
            var n = earlier.length;
            //  THE BACKLOG STARTS WHEN THE REGISTER OPENED (db/117). The
            //  database floors the window at the day the last family was
            //  told, and sends `note` in words - "Counted from 3 October,
            //  when the register opened." - so a short list is not mistaken
            //  for a short memory. Nobody is ever invited to hand in a
            //  register for an evening nobody was allowed to take one.
            if (!n) {
              //  Nothing earlier than tonight. If that is because the
              //  register opened TONIGHT, say so - a bare silence reads as
              //  "you are all caught up", which is not what happened.
              if (od.opened_on && od.opened_on === d.on_date) {
                box.textContent = "The register opened tonight, so there "
                  + "are no earlier registers to hand in.";
                box.hidden = false;
              }
              return;
            }
            box.innerHTML = "<strong>" + esc(n)
              + (n === 1 ? " earlier register is" : " earlier registers are")
              + " still to hand in.</strong> "
              + "A register taken tomorrow is somebody remembering. "
              + (od.note ? esc(od.note) + " " : "")
              + '<a href="register/">Take them now</a>';
            box.hidden = false;
          })["catch"](function () { /* the page is useful without it */ });
        }

        if (when) {
          //  STANDS DOWN WITH THE GATE. "1 register still to take" beside
          //  "Your classes" is the same invitation #tc-gate has just
          //  refused, in different words - see the Sept 28 report, item 1.
          when.textContent = (!permitted || due === 0) ? "" : toTake === 0
            ? "Every register is taken."
            : toTake +
              (toTake === 1 ? " register" : " registers") +
              " still to take.";
        }

        host.innerHTML = rows.map(function (c) {
          //  handedIn is the ONLY "done". allMarked is a different and
          //  smaller fact - every child has a mark - and is used for one
          //  thing: telling the teacher the last step is still theirs.
          var handedIn = (c.state === "submitted");
          var allMarked = (c.on_roll > 0 && c.marked >= c.on_roll);
          var body = "<strong>" + esc(c.name) + "</strong>" +
            '<span class="tc-q">' + esc(c.on_roll) +
              (c.on_roll === 1 ? " child" : " children") +
              (c.i_am_the_main_teacher ? "" : " \u00b7 you assist") + "</span>";
          //  NOT PERMITTED: THE ROLL IS STILL SHOWN - #tc-gate promises
          //  the class list is correct in the meantime, and it is - but
          //  NOTHING ON THE CARD INVITES THE TEACHER TO ACT: no "Take the
          //  register" label, and no link, because the screen it pointed
          //  to would refuse them. A plain, unlinked card rather than an
          //  <a> - see the Sept 28 report, item 1.
          //  A class with nobody on its roll is not due, and the register
          //  screen would refuse it: no invitation, exactly as when locked.
          if (!permitted || !(c.on_roll > 0)) {
            return '<div class="tc-class tc-class-locked">' + body + "</div>";
          }
          return '<a class="tc-class' + (handedIn ? " is-done" : "") +
            '" href="register/">' + body +
            '<span class="tc-state">' +
              (handedIn ? "Register taken \u00b7 " + esc(c.away) + " away"
                        : (allMarked ? "Marked \u00b7 not handed in yet \u2192"
                                     : "Take the register \u2192")) +
              "</span></a>";
        }).join("");
      })["catch"](function (e) {
        var n = el("tc-error");
        if (n) {
          n.textContent = "Your classes would not load. " +
            (e && e.message ? e.message : "");
          n.hidden = false;
        }
      });
    }

    function drawRoleList(id, items) {
      var box = el(id);
      if (!box) return;
      box.innerHTML = items.map(function (i) {
        //  A TICK MEANS DONE EVERYWHERE ELSE ON THIS SITE. Every row in this
        //  list carried one while the heading above it said "coming soon",
        //  which is the same mark meaning the opposite thing two inches
        //  apart. Built rows keep the tick and say so; the rest get a plain
        //  bullet, because a promise is not an achievement.
        var live = !!i.live;
        //  A BUILT ROW WITH SOMEWHERE TO GO IS A LINK, WHOLE. A tick that says
        //  "open now" on a row that cannot be pressed teaches people the page
        //  is broken. Only a row that is live AND has an href is a link; every
        //  other row stays a plain block, exactly as before.
        var tag = (live && i.href) ? "a" : "div";
        return "<" + tag + ' class="rl-item' + (live ? " rl-live" : "") + '"' +
          (tag === "a" ? ' href="' + esc(i.href) + '"' : "") + ">" +
          '<span class="rl-mark" aria-hidden="true">' +
            (live ? "\u2713" : "\u00b7") + "</span>" +
          "<span><b>" + esc(i.t) +
            (live ? ' <em class="rl-tag">open now</em>' : "") +
          "</b><span>" + esc(i.d) + "</span></span>" +
        "</" + tag + ">";
      }).join("");
    }

    function esc(v) {
      return String(v === null || v === undefined ? "" : v)
        .replace(/[&<>"']/g, function (c) {
          return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;",
                    '"': "&quot;", "'": "&#39;" })[c];
        });
    }

    /*  WHAT NEEDS DOING — THE WHOLE POINT OF A PAGE CALLED THAT.

        REWRITTEN 19 SEPTEMBER, because the old one was reported as messy and
        was. It drew one job as a paragraph, a second paragraph explaining it,
        nineteen name chips, and a button — a wall of text for one fact, with
        no room for the second job even though there was one.

        A JOB IS A NUMBER, A SENTENCE, AND SOMEWHERE TO GO. Nothing else.
        One tile each, same shape every time, so the eye can count them. The
        number is large because it is the thing somebody scans for; the
        sentence says what it means in words, because "10" on its own is not
        a job; the link goes to the screen that fixes it, because a dashboard
        that tells you about a problem and leaves you to find the screen is
        a worse version of a note on the fridge.

        WHAT IS *NOT* HERE IS THE DESIGN.

          - No names. The DBS tile used to list nineteen teachers' names on
            the landing page. That is the page on the monitor when somebody
            walks past the office, in every screenshot, on every shared
            screen in a meeting. The names are one press away on the staff
            screen, where somebody chose to go and where they belong.

          - No tile for a job that does not exist. A count of nought is not
            drawn at all rather than drawn as a reassuring green nought: nine
            tiles of which seven say 0 is a screen people stop reading, and
            then they stop seeing the two that matter. When everything is
            clear the page says so in one line.

          - Nothing about fees or attendance. Neither is built. A tile
            reading "0 unpaid" when nothing collects fees is not neutral,
            it is false.

        SEVERITY IS THE ORDER, and it is decided here rather than by where a
        field happens to sit in the JSON. Safeguarding first, always.        */
    var JOBS = [
      {
        key: "dbs",
        rank: 1,
        //  Not a plain count: the three states mean different things and the
        //  worst of them decides the colour.
        n: function (m) { return (m.dbs_needs_attention || []).length; },
        of: function (m) { return m.staff; },
        tone: function (m) {
          var p = m.dbs_needs_attention || [];
          return p.some(function (x) { return x.state === "overdue"; }) ? "bad"
               : p.some(function (x) { return x.state === "none"; })    ? "bad"
               : "warn";
        },
        title: function (n, of) {
          return n + " of " + of + " staff need their DBS check looked at";
        },
        why: function (m) {
          var p = m.dbs_needs_attention || [];
          var none = p.filter(function (x) { return x.state === "none"; }).length;
          var over = p.filter(function (x) { return x.state === "overdue"; }).length;
          var soon = p.filter(function (x) { return x.state === "due_soon"; }).length;
          var bits = [];
          if (none) bits.push(none + " with nothing on file at all");
          if (over) bits.push(over + (over === 1 ? " overdue" : " overdue"));
          if (soon) bits.push(soon + " falling due within 90 days");
          return bits.join(", ") + ". A certificate has no expiry printed on " +
                 "it, so each date has to be keyed in from the certificate " +
                 "itself — nothing here has been invented.";
        },
        go: "staff/#dbs", goWord: "Open the staff list"
      },
      {
        key: "main_teacher",
        rank: 2,
        n: function (m) { return m.classes_no_main_teacher; },
        of: function (m) { return m.classes; },
        tone: function () { return "warn"; },
        title: function (n, of) {
          return n + " of " + of + " classes have no main teacher";
        },
        why: function () {
          return "The import worked out the main teacher for thirty-five " +
                 "classes from who was listed against them. These are the ones " +
                 "it could not, so nobody is recorded as answerable for the " +
                 "register.";
        },
        go: "classes/", goWord: "Open the classes"
      },
      {
        key: "no_class",
        rank: 3,
        n: function (m) { return m.pupils_without_class; },
        of: function (m) { return m.pupils; },
        tone: function () { return "bad"; },
        title: function (n, of) {
          return n + (n === 1 ? " child is" : " children are") +
                 " on the roll and in no class";
        },
        why: function () {
          return "A child in no class is on no register, so nobody notices " +
                 "when they stop coming. That is the safeguarding question a " +
                 "register exists to answer.";
        },
        go: "classes/", goWord: "Open the classes"
      },
      {
        key: "side",
        rank: 4,
        n: function (m) { return m.staff_without_side; },
        of: function (m) { return m.staff; },
        tone: function () { return "warn"; },
        title: function (n) {
          return n + (n === 1 ? " member" : " members") + " of staff have no side recorded";
        },
        why: function () {
          return "They appear in neither the sisters’ nor the brothers’ " +
                 "list. The staff screen keeps them in a group of their own so " +
                 "they cannot go missing, but somebody has to choose.";
        },
        go: "staff/", goWord: "Open the staff list"
      },
      {
        key: "days",
        rank: 5,
        n: function (m) { return m.staff_without_days; },
        of: function (m) { return m.staff; },
        tone: function () { return "mild"; },
        title: function (n, of) {
          return n + " of " + of + " staff have no days recorded";
        },
        why: function () {
          return "Which evenings they are in. Not urgent, and it is what a " +
                 "cover rota will need the day somebody builds one.";
        },
        go: "staff/", goWord: "Open the staff list"
      },
      {
        key: "admissions",
        rank: 0,
        n: function (m) { return m.admissions_waiting; },
        of: function () { return null; },
        tone: function () { return "bad"; },
        title: function (n) {
          return n + (n === 1 ? " admission form is" : " admission forms are") +
                 " waiting to be read";
        },
        why: function () {
          return "A family filled in the form on the website. Nothing on this " +
                 "system has been opened it yet, and they are waiting on an answer.";
        },
        go: null, goWord: null
      },
      {
        key: "purge",
        rank: 6,
        n: function (m) { return m.archive_going_soon; },
        of: function (m) { return m.archive_total; },
        tone: function () { return "warn"; },
        title: function (n) {
          return n + (n === 1 ? " archived record is" : " archived records are") +
                 " about to be deleted for good";
        },
        why: function () {
          return "Inside the last thirty days of the three years a removed " +
                 "record is kept. After that it is destroyed and cannot be " +
                 "brought back. This is the only clock in the madrasah that " +
                 "cannot be stopped, so it is worth a look before it runs out.";
        },
        go: "archive/", goWord: "Open the archive"
      }
    ];

    function jobHtml(j, m) {
      var n  = Number(j.n(m)) || 0;
      var of = j.of(m);
      return '<div class="md-job md-job-' + esc(j.tone(m)) + '" data-job="' + esc(j.key) + '">' +
        '<div class="md-job-n">' + esc(n) + "</div>" +
        '<div class="md-job-b">' +
          '<span class="md-job-t">' + esc(j.title(n, of)) + "</span>" +
          '<span class="md-job-w">' + esc(j.why(m)) + "</span>" +
        "</div>" +
        (j.go
          ? '<a class="md-job-go" href="' + esc(j.go) + '">' + esc(j.goWord) + "</a>"
          : '<span class="md-job-soon">No screen for this yet</span>') +
      "</div>";
    }

    /*  WHAT NEEDS DOING NOW COMES FROM THE DATABASE, NOT FROM THIS FILE.
        -----------------------------------------------------------------
        JOBS below decided what was waiting by reading madrasah_overview()
        and applying rules written here, in JavaScript, on one page. That
        was fine while there were three of them. It stopped being fine the
        moment the register, the applications, the privacy notice and the
        families nobody can ring all became things somebody has to do: each
        would have been another rule in this file, and the Today screen and
        the screens themselves would have disagreed about what counted
        within a fortnight.

        madrasah_today() decides now, once, next to the data. This draws
        what it returns. JOBS is kept for the two jobs that have no screen
        yet, which is the one thing the database cannot know.  */
    function todayHtml(it) {
      return '<div class="md-job md-job-' + esc(TONE[it.tone] || "warn") +
             '" data-job="' + esc(it.key) + '">' +
        '<div class="md-job-n">' + esc(it.count) + "</div>" +
        '<div class="md-job-b">' +
          '<span class="md-job-t">' + esc(it.title) + "</span>" +
          '<span class="md-job-w">' + esc(it.said) + "</span>" +
        "</div>" +
        '<a class="md-job-go" href="' + esc(it.href) + '">' +
          esc(it.action) + "</a>" +
      "</div>";
    }
    //  The page's own three tones, which its stylesheet already knows.
    var TONE = { bad: "bad", now: "warn", quiet: "ok" };

    function drawNeedsDoing() {
      var box = el("md-doing");
      if (!box) return;

      if (TODAY && TODAY.items) {
        if (!TODAY.items.length) {
          box.innerHTML = '<div class="md-clear">' +
            "<b>Nothing is waiting.</b> Every register is taken, nobody is " +
            "waiting to hear from the madrasah, and every family can be " +
            "reached. This list fills itself when something needs you." +
            "</div>";
          return;
        }
        box.innerHTML = TODAY.items.map(todayHtml).join("");
        return;
      }

      //  madrasah_today() did not answer. Fall back to what this page always
      //  did rather than showing nothing: a stale list is worse than a fresh
      //  one and far better than a blank panel on the screen somebody opens
      //  to find out whether anything is wrong.
      if (!MINE) return;
      var live = JOBS.filter(function (j) { return (Number(j.n(MINE)) || 0) > 0; })
                     .sort(function (a, b) { return a.rank - b.rank; });

      if (!live.length) {
        box.innerHTML = '<div class="md-clear">' +
          "<b>Nothing is waiting.</b> Every check is in date, every class has a " +
          "main teacher, and every child on the roll is in a class. " +
          "</div>";
        return;
      }
      box.innerHTML = live.map(function (j) { return jobHtml(j, MINE); }).join("");
    }

    function draw() {
      var counts = el("md-counts");
      if (counts) {
        counts.innerHTML = CURRENT.counts.map(function (c) {
          var n = c.mine ? (MINE && MINE[c.key]) : c.n;
          //  The caveat travels with the number ON EVERY TILE, because
          //  somebody screenshots one for a committee paper and the number
          //  goes without the panel above it.
          var note = c.mine
            ? "<br><b>In this system, and up to date.</b>"
            : "<br><b>In " + esc(CURRENT.where) + ", not imported.</b>";
          return '<div class="md-count' + (c.mine ? " md-count-mine" : "") + '">' +
            '<span class="n">' + (n === null || n === undefined ? "&mdash;" : esc(n)) + "</span>" +
            '<span class="k">' + esc(c.k) + "</span>" +
            '<span class="s">' + esc(c.s) + note + "</span>" +
          "</div>";
        }).join("");
      }

      //  The "What this will hold" cards were drawn here. Removed with
      //  their markup on 19 September - the rail already lists every unbuilt
      //  screen with a "soon" tag, so these repeated it in four times the
      //  space on the one page that is about today. AREAS is kept as the
      //  brief for those screens; nothing draws it.

      var before = el("md-before-list");
      if (before) {
        /*  THREE STATES, TOLD APART BY MORE THAN COLOUR. A tick, a pen and
            an empty ring, plus the words — because roughly one man in twelve
            cannot separate the green from the amber, and this is a list
            somebody will be asked to act on.

            Done items are NOT hidden once ticked. A finished item removed
            takes its evidence with it, and the next person to ask "did we
            ever register with the ICO?" has nothing to read. */
        var MARK = { done: "\u2713", waiting: "\u270e", todo: "\u25cb" };
        var WORD = { done: "Done", waiting: "With the trustees",
                     todo: "Still outstanding" };
        var state = function (x) {
          return x.done ? "done" : x.waiting ? "waiting" : "todo";
        };

        before.innerHTML = BEFORE.map(function (bf) {
          var st = state(bf);
          return '<li class="md-' + st + '">' +
            '<span class="md-tick" aria-hidden="true">' + MARK[st] + "</span>" +
            "<span><b>" + esc(bf.t) + "</b>" +
            '<span class="md-state">' + WORD[st] + "</span>" +
            "<span>" + esc(bf.d) + "</span>" +
            //  WHAT CLOSES IT. A status list that says a thing is outstanding
            //  and not what would finish it is a list that gets read once.
            (bf.what
              ? '<span class="md-next"><b>To close it:</b> ' + esc(bf.what) + "</span>"
              : "") +
            "</span></li>";
        }).join("");

        var nWait = BEFORE.filter(function (x) { return state(x) === "waiting"; }).length;
        var nTodo = BEFORE.filter(function (x) { return state(x) === "todo"; }).length;
        var h = el("md-before-h");
        if (h) {
          var bits = [];
          if (nWait) bits.push(nWait + " with the trustees");
          if (nTodo) bits.push(nTodo + " still to start");
          h.textContent = bits.length
            ? "Data protection \u2014 " + bits.join(", ")
            : "Data protection \u2014 all confirmed";
        }
      }

      var rest = el("md-rest");
      if (rest) {
        rest.innerHTML = REST.map(function (r) {
          return "<span>" + esc(r) + "</span>";
        }).join("");
      }

      var lead = el("md-lead");
      if (lead && MINE) {
        //  Rewritten once the real figures are in hand. The markup's own
        //  wording is the pre-import one and stays in the HTML as the honest
        //  default for anybody who loads this page with the call failing.
        /*  THIS SENTENCE HAS BEEN WRONG TWICE, THE SAME WAY, A WEEK APART:
            once when the staff were imported and it still said nothing was,
            and again on the 18th when the pupils were. Both times it was
            written as a fixed sentence describing a state of affairs; both
            times the state of affairs moved and the sentence did not.

            So it is no longer a sentence about what has been imported. It is
            BUILT FROM THE FIGURES THE DATABASE JUST RETURNED, which means it
            cannot disagree with the tiles underneath it - the two are the
            same numbers read twice. The only thing still named by hand is
            Contacts, because its absence is the fact.                       */
        var held = [];
        if (MINE.pupils)  held.push(MINE.pupils + " children");
        if (MINE.staff)   held.push(MINE.staff + " teachers");
        if (MINE.classes) held.push(MINE.classes + " classes");
        lead.innerHTML = held.length
          ? "<p>" + "<strong>This system holds " + esc(held.join(", ")) + ".</strong> " +
            "Everything below is read from it. <strong>Families and contacts are " +
            "the exception</strong> \u2014 that tile is still what the masjid\u2019s " +
            "current system holds, because there is nowhere here to put them yet."
          : "<p><strong>Nothing has been read back yet.</strong> The figures below are " +
            "not this system\u2019s. Reload the page; if it says this again, the " +
            "database is not answering.</p>";
      }
      if (lead) {
        /*  A SIBLING, NOT A TRAILING LINE, so the band can put it on the
            right-hand end and the statement can keep a readable measure on
            the left. The block then fills the width without anything
            stopping in the middle of the screen.

            And it names WHICH figure it dates. It used to read "Figures as
            at 13 September" under four tiles, three of which are now read
            live from the database and one of which is not — so the date
            was wrong about three quarters of what it sat under. */
        var when = document.createElement("div");
        when.className = "md-when";
        when.textContent = "Contacts figure as at " + CURRENT.as_at +
                           ". The other three are live.";
        lead.appendChild(when);
      }
    }

    return {
      mount: function (identity) {
        var panel = el("md-panel"), noaccess = el("app-noaccess");

        /* THREE PAGES BEHIND ONE DOOR, AND A FOURTH FOR THE PARENT WHO IS SENT
           ON. An administrator gets the console; a teacher gets the teachers'
           page; a parent is sent to portal/parent/.

           Admin is checked FIRST and on its own: somebody who is both an
           administrator and a teacher is here to administer. Teacher comes
           second for the same reason - a teacher who is also a parent is
           here to teach.

           A PARENT IS DECIDED BEFORE ANY OF THIS, in routeAfterPassword(),
           from is_parent() - never from a role row, because parents have none
           by design. By the time this function runs a parent has already been
           sent on, and the only way one reaches the branch below is that the
           redirect could not be made (or, in the old data, a `parent` row
           exists). It was placed there and not here because this function is
           reached only AFTER the two-step prompt, and a parent has no second
           factor. The order that matters is: staff roles win, then a parent is
           a parent, then nothing. */
        //  A PASSWORD SOMEBODY ELSE CHOSE IS A TICKET, NOT A PASSWORD.
        //  Nothing is drawn - no panel, no rail, no data - until this
        //  account has one of its own. See db/093.
        if (identity.mustChange) { mustChangeGate(identity); return; }

        var shown = null;
        if (canSee(identity)) {
          shown = panel;

          /*  THE REAL FIGURES, AND WHAT NEEDS DOING.

              Asked for once, here, rather than by each tile: six round trips
              is six ways to half-load a screen, and this page has already had
              a version that rendered with nothing in it.

              draw() runs whether or not this answers. If it does not, the
              tiles show an em dash and the page keeps the pre-import wording
              from the markup — which is out of date but TRUE of pupils, and a
              stale caveat is safer than a missing one. */
          //  BOTH, AND NEITHER BLOCKS THE PAGE. madrasah_overview() fills
          //  the counts; madrasah_today() fills what needs doing. Either may
          //  fail and the page still draws - see the note above.
          Promise.all([
            sb.rpc("madrasah_overview").then(function (res) {
              if (!res.error && res.data) { MINE = res.data; }
            }).catch(function () { /* draw() copes */ }),
            sb.rpc("madrasah_today").then(function (res) {
              if (!res.error && res.data && res.data.allowed !== false) {
                TODAY = res.data;
              }
            }).catch(function () { /* drawNeedsDoing() falls back */ })
          ]).then(function () { draw(); drawNeedsDoing(); });
        } else if (identity.roles.indexOf("teacher") !== -1) {
          shown = el("tc-panel");
          //  THEIR NAME, NOT THEIR EMAIL. The email on a teacher login is a
          //  handle the system invented - test.teacher.57b9@... - and
          //  greeting somebody with it is worse than greeting them with
          //  nothing. Fall back to the plain salam rather than to the
          //  address.
          drawRoleList("tc-list", TEACHER);
          drawMyClasses();
        } else if (identity.isParent === true ||
                   identity.roles.indexOf("parent") !== -1) {
          //  THE FALLBACK. Normally unreachable: a parent has been sent to
          //  portal/parent/ before this page draws. What it shows is true
          //  about what is built and links to it.
          shown = el("pa-panel");
          drawRoleList("pa-list", PARENT);
        }

        if (!shown) {
          if (panel) panel.hidden = true;
          var who = el("na-email");
          if (who) who.textContent = identity.user.email;
          if (noaccess) noaccess.hidden = false;
          return;
        }
        if (noaccess) noaccess.hidden = true;
        shown.hidden = false;

        /* Full width, and the brand panel goes with it — the same rule as the
           staff screen. A form wants 420px; a dashboard does not. It happens
           here rather than in the markup so that somebody who never gets past
           the sign-in card keeps the two-column page. */
        var shell = document.querySelector(".shell");
        if (shell) shell.classList.add("wide-mode");

        var top = el("app-top");
        if (top) {
          top.hidden = false;
          el("app-top-email").textContent = identity.user.email;
          //  "Madrasah" is right for all three, but a teacher and a parent are
          //  looking at their own portal and should be told so.
          //  The admin centre refuses a teacher or a parent, so offering them
          //  a link to it is offering them a closed door. Theirs is a page
          //  with nowhere else to go, which is honest at this stage.
          var back = el("app-top-back");
          if (back) back.hidden = shown !== panel;

          var where = el("app-top-where");
          if (where) {
            where.textContent = shown === panel ? "Madrasah"
              : shown === el("tc-panel") ? "Madrasah \u2014 teachers"
              : "Madrasah \u2014 parents";
          }
        }
        ["app-who", "app-roles", "app-signout"].forEach(function (id) {
          var n = el(id);
          if (n) n.hidden = true;
        });

        var out = el("app-signout-top");
        if (out && !out.wired) {
          out.wired = true;
          out.addEventListener("click", function () {
            sb.auth.signOut().then(function () {
              //  Back out of wide mode, or the sign-in card returns full width
              //  with no brand panel beside it and signing out visibly breaks
              //  the page you land on.
              var s = document.querySelector(".shell");
              if (s) s.classList.remove("wide-mode");
              el("signin-email").value = "";
              el("signin-password").value = "";
              setError("signin-error", "");
              show("view-signin");
            });
          });
        }

        //  Only the console has anything to draw; the two landing pages were
        //  filled in above, before the panel was shown.
        if (shown === panel) draw();
      }
    };
  })();

  function renderApp(identity) {
    //  THE RAIL. Mounted here and nowhere else: this function runs only
    //  once the page knows who is signed in, so the list of areas can
    //  never be drawn for somebody who is not. It is a convenience, not
    //  a permission — see admin/shell.js.

    /*  WAIT FOR THE TWO DEFERRED SCRIPTS, but only while the page is still
        being read.

        shell.js and nav.js are `defer`, so they run at DOMContentLoaded. The
        sign-in check is a promise chain, and against a warm session it can
        settle FIRST — at which point window.AdminShell is undefined, the
        `if` below is false, and the page renders with no rail at all. No
        error, nothing in the console; it simply looks like the rail was
        never built. It cost an afternoon on the staff screen before it was
        spotted there, and the same shape was sitting here.

        Only while readyState is "loading", so a genuinely missing file leaves
        a rail-less page rather than a page that hangs for ever. */
    if (document.readyState === "loading" &&
        !(window.AdminShell && window.MadrasahNav)) {
      document.addEventListener("DOMContentLoaded", function () {
        renderApp(identity);
      }, { once: true });
      return;
    }

    if (window.AdminShell) {
      AdminShell.mount({
        /*  THE MADRASAH'S OWN RAIL, not the site's.

            This page IS the madrasah's front screen, so while somebody is on
            it the left-hand column should list the madrasah's sections — not
            Hall Hire and Gift Aid, which are a different building. Without
            this, the Staff screen at portal/staff/ was live and completely
            unreachable: nothing on the site linked to it. */
        sections: (window.MadrasahNav || {}).SECTIONS,
        area:    'Madrasah',
        current: 'md-today',
        /*  THE HEADING GREETS A TEACHER AND BRIEFS AN ADMINISTRATOR.
            "What needs doing" is the right heading for somebody who opens
            this forty times a term to clear a list. Sitting directly above
            "Assalamu alaikum, Ustadh Ibrahim Patel" it read as an
            instruction barked over a greeting. A teacher opens this once a
            week, in the dark, before teaching ten children for an hour
            unpaid; the heading can be the salam and lose nothing. */
        title:   (identity.roles.indexOf('admin') === -1
                  && identity.roles.indexOf('teacher') !== -1)
                   ? ('Assalamu alaikum'
                      + ((identity.profile && identity.profile.full_name)
                          ? ', ' + identity.profile.full_name : ''))
                   //  "What needs doing" is an administrator's heading. Over
                   //  the parents' fallback or the no-access message it was a
                   //  staff title on a page that is not for staff - seen on
                   //  the screenshot, not by a test.
                   : ((identity.roles.indexOf('admin') !== -1 ||
                       identity.roles.indexOf('madrasah') !== -1)
                      ? 'What needs doing'
                      : (identity.isParent === true ||
                         identity.roles.indexOf('parent') !== -1)
                         ? 'The parents\u2019 portal' : 'Madrasah'),
        roles:   identity.roles || [],
        //  A parent has no role row. Without this the rail reads them as an
        //  account with no role and offers the Admin Centre. See shell.js.
        parent:  identity.isParent === true,
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
    try { madrasah.mount(identity); } catch (e) {
      if (window.console) console.warn("madrasah panel unavailable:", e);
    }
  }

  // Decides where to send someone once their password has been accepted.
  function routeAfterPassword() {
    //  A PARENT FIRST - see isParentOnly(). Before the two-step decision, so
    //  that somebody with no authenticator is never asked to make one.
    return isParentOnly().then(function (parent) {
      parentState = parent;
      if (parent === true) {
        if (goToParentPortal()) return;
        //  The redirect did not fire. Show the fallback panel, with its link.
        return loadIdentity().then(renderApp);
      }
      return afterParentCheck();
    });
  }

  function afterParentCheck() {
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
