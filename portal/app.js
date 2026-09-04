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
  function show(view) {
    VIEWS.forEach(function (v) {
      var n = el(v);
      if (n) n.hidden = v !== view;
    });
  }

  // --- the areas ------------------------------------------------------------
  //
  // `needs` is the role that opens each one. Today only administrators reach
  // this page at all, so every entry says "admin" — but the list is filtered
  // rather than hard-coded, so that opening it up to hall office staff or
  // teachers later is a one-line change and not a rewrite.
  //
  // Only areas that actually exist are listed. Nothing here advertises a
  // portal that has not been built.
  var AREAS = [
    {
      href:  "../venue/",
      title: "Hall Hire & Nikāḥ",
      desc:  "Everything the public has asked for through the website: Astley Hall " +
             "bookings and nikāḥ dates, in one list. Ring the enquirer, then record " +
             "what was agreed.",
      needs: ["admin", "hall_office"]
    },
    {
      // Added 4 September 2026. Sign-ups had been going live into the database
      // with nothing anywhere to read them back — a test registration for the
      // Arabic class arrived, got a reference number, and could not be found
      // by anybody. Turning a form on and giving it somewhere to land are two
      // jobs, and only the first had been done.
      href:  "../courses/",
      title: "Adult classes",
      desc:  "Who has signed up for Arabic and the Ghusl workshop, how many places " +
             "are left, and who is on the waiting list.",
      needs: ["admin"]
    },
    {
      href:  "../portal/",
      title: "Madrasah portal",
      desc:  "Pupils, classes and staff. Holds children's records, so it is the " +
             "most tightly held area on the site.",
      needs: ["admin", "teacher"]
    }
  ];

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

  function renderList(identity) {
    el("list-name").textContent  = nameOf(identity);
    el("list-email").textContent = identity.user.email;

    var chips = el("list-roles");
    chips.innerHTML = "";
    identity.roles.forEach(function (r) {
      var chip = document.createElement("span");
      chip.className = "role-chip role-" + r;
      chip.textContent = r.replace(/_/g, " ");
      chips.appendChild(chip);
    });

    var wrap = el("list-dests");
    wrap.innerHTML = "";
    AREAS.filter(function (a) {
      return a.needs.some(function (n) { return identity.roles.indexOf(n) !== -1; });
    }).forEach(function (a) {
      var link = document.createElement("a");
      link.className = "dest";
      link.href = a.href;

      var t = document.createElement("div");
      t.className = "t";
      t.appendChild(document.createTextNode(a.title));
      var arrow = document.createElement("span");
      arrow.className = "arrow";
      arrow.setAttribute("aria-hidden", "true");
      arrow.textContent = "→";
      t.appendChild(arrow);

      var d = document.createElement("div");
      d.className = "d";
      d.textContent = a.desc;

      var w = document.createElement("span");
      w.className = "w";
      w.textContent = "Asks for your code";

      link.appendChild(t); link.appendChild(d); link.appendChild(w);
      wrap.appendChild(link);
    });

    show("view-list");
  }

  // --- on arrival -----------------------------------------------------------
  sb.auth.getSession().then(function (res) {
    var session = res.data && res.data.session;
    if (!session || !session.user) { show("view-signedout"); return; }

    return loadIdentity().then(function (identity) {
      if (identity.roles.indexOf("admin") === -1) { noAccess(identity); return; }
      renderList(identity);
    });
  }).catch(function (err) {
    if (window.console) console.warn("portals:", err && err.message);
    noAccess(null,
      "We couldn't check what this account has access to just now. " +
      "Please try again in a moment.");
  });

})();
