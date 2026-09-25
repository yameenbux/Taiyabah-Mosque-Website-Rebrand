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

   The teachers' and parents' views are not built. A teacher signing in here
   is told so rather than being shown an administrator's console.
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
    var TEACHER = [
      { t: "Take the register",
        d: "Mark who is in, who is late and who is absent, from a phone, at the " +
           "start of the lesson rather than on paper to be typed up later." },
      { t: "Write up the lesson",
        d: "What was covered and how far the class got, so whoever takes them " +
           "next week is not starting from a guess." },
      { t: "Record how each child is getting on",
        d: "Sabaq, sabqi and manzil, merits and the things worth telling a " +
           "parent — kept against the child rather than in a notebook." },
      { t: "Set and see homework",
        d: "What was set, who has done it, and who needs chasing." },
      { t: "End-of-year reports",
        d: "Build the report from what is already recorded across the year " +
           "instead of writing it from memory in one weekend." },
      { t: "Message a parent",
        d: "Through the masjid, so the conversation is on the record and " +
           "nobody has to give out a personal number." },
      { t: "See your classes and times",
        d: "Who is in your group, when you are on, and who is covering." },
      { t: "Raise a concern",
        d: "An incident or a safeguarding worry, logged properly and sent " +
           "straight to the people who must see it." }
    ];

    /* WHAT A PARENT WILL BE ABLE TO DO. Deliberately starts with the two
       things families actually ring the office about — fees and absence —
       rather than with the reports, which is what a school system would put
       first. */
    var PARENT = [
      { t: "Pay the fees",
        d: "Online, at any hour, with a receipt — instead of finding cash and " +
           "catching somebody at the office between 5 and 7." },
      { t: "Tell the masjid your child is absent",
        d: "Before the lesson, in a few seconds, so the teacher is not ringing " +
           "round to find out." },
      { t: "See how your child is getting on",
        d: "What they are learning, how they are doing, and the end-of-year " +
           "report when it is ready." },
      { t: "Keep your details right",
        d: "A new phone number, a new address, a change of school — changed " +
           "once and right everywhere, rather than told to somebody and lost." },
      { t: "Say who may collect them",
        d: "Who is allowed to take your child home, and who is not. The masjid " +
           "keeps to what you put here." },
      { t: "Tell us about medical needs and allergies",
        d: "So the person in the room on the day knows, and it does not depend " +
           "on somebody remembering." },
      { t: "See homework and what was covered",
        d: "What was set and when it is due, so you can help." },
      { t: "Enrol another child",
        d: "Without filling the same form in again for a family the masjid " +
           "already knows." }
    ];

    function drawRoleList(id, items) {
      var box = el(id);
      if (!box) return;
      box.innerHTML = items.map(function (i) {
        return '<div class="rl-item">' +
          '<span class="rl-mark" aria-hidden="true">\u2713</span>' +
          "<span><b>" + esc(i.t) + "</b><span>" + esc(i.d) + "</span></span>" +
        "</div>";
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

    function drawNeedsDoing() {
      var box = el("md-doing");
      if (!box || !MINE) return;

      //  A job with nothing in it is not drawn. See the note above JOBS.
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

        /* THREE PAGES BEHIND ONE DOOR. An administrator gets the console; a
           teacher and a parent each get a page about their own portal. Until
           today they got "your side has not been built" and a sign-out button,
           which is a true sentence and a useless screen.

           Admin is checked FIRST and on its own: somebody who is both an
           administrator and a teacher is here to administer. */
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
          sb.rpc("madrasah_overview").then(function (res) {
            if (!res.error && res.data) { MINE = res.data; }
          }).catch(function () { /* draw() copes */ })
            .then(function () { draw(); drawNeedsDoing(); });
        } else if (identity.roles.indexOf("teacher") !== -1) {
          shown = el("tc-panel");
          drawRoleList("tc-list", TEACHER);
        } else if (identity.roles.indexOf("parent") !== -1) {
          shown = el("pa-panel");
          drawRoleList("pa-list", PARENT);
        }

        if (!shown) {
          if (panel) panel.hidden = true;
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
        title:   'What needs doing',
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
    try { madrasah.mount(identity); } catch (e) {
      if (window.console) console.warn("madrasah panel unavailable:", e);
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
