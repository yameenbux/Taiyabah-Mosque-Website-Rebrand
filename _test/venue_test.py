"""/venue/ — hall bookings and nikāḥ requests in one list.

Written 7 September 2026, when hall hire moved to whole-day booking, and
extended the same day when the deposit became what books the date
(migration 017). The office's only view of a booking is this page, so it has
to render four different shapes correctly: a paid whole-day hall booking that
is already booked and must NOT offer Confirm or Decline, a kitchen-only
booking still awaiting a decision, a booking taken under the old session model
that has no rate on file, and a nikāḥ request.

The stub is frozen with Object.defineProperty before the page's own scripts
run — the vendored Supabase build declares `var supabase` at global scope and
would otherwise overwrite a plain assignment, leaving every assertion running
against a sign-in screen.
"""
from playwright.sync_api import sync_playwright
import sys, json, http.server, socketserver, threading, functools, os, datetime

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PAGE = "http://127.0.0.1:%d/venue/" % httpd.server_address[1]

fails, errs = [], []


def check(cond, msg):
    if not cond:
        fails.append(msg)


def button(page, row_id, act):
    """The button for one action, or a recorded failure and None.

    Returning None rather than letting Playwright raise matters: when a button
    legitimately disappears — which is exactly what migration 017 does to
    Confirm and Decline — the suite must go on and report every assertion, not
    abort on a traceback and hide the rest.
    """
    node = page.query_selector('.bk-item[data-id="%s"] .bk-btn[data-act="%s"]' % (row_id, act))
    if node is None:
        fails.append("no %r button on booking %s" % (act, row_id))
    return node


def pos(order, row_id, where):
    """Index of a row, or a recorded failure and a sentinel that sorts last.

    order.index() raises ValueError when the row is missing, and a traceback
    aborts the whole suite and hides every assertion after it. That has
    happened four times on this project; it is why button() exists, and this
    is the same guard for ordering.
    """
    if row_id not in order:
        fails.append("%s is not in the list at all (%s)" % (row_id, where))
        return 10 ** 6
    return order.index(row_id)


SOON = (datetime.date.today() + datetime.timedelta(days=20)).isoformat()
LATER = (datetime.date.today() + datetime.timedelta(days=45)).isoformat()
OLD = (datetime.date.today() + datetime.timedelta(days=60)).isoformat()
STUCK = (datetime.date.today() + datetime.timedelta(days=50)).isoformat()
GONE  = (datetime.date.today() + datetime.timedelta(days=70)).isoformat()
LIVE  = (datetime.date.today() + datetime.timedelta(days=75)).isoformat()

_now = datetime.datetime.now(datetime.timezone.utc)
def _iso(**kw):
    return (_now + datetime.timedelta(**kw)).strftime("%Y-%m-%dT%H:%M:%SZ")

# Deliberately NOT round numbers: the ordering assertion has to fail if the
# sort falls back to booking_date or created_at, and equal timestamps would
# let it pass by luck.
PAID_RECENT = _iso(hours=-2)      # money landed two hours ago  -> must be first
PAID_OLDER  = _iso(days=-5)       # money landed five days ago
HOLD_DEAD   = _iso(minutes=-40)   # thirty-minute hold, forty minutes ago
HOLD_LIVE   = _iso(minutes=+18)   # still in Stripe right now
MADE_DEAD   = _iso(minutes=-70)   # submitted seventy minutes ago
MADE_LIVE   = _iso(minutes=-12)   # submitted twelve minutes ago

# The exact set of columns migration 017 grants the office. Anything the
# portal tries to write outside this list is refused by Postgres at runtime,
# which the office would see as an unexplained "couldn't save that".
ALLOWED = {"status", "office_notes", "handled_at", "deposit_status",
           "extras_p", "balance_status", "balance_paid_at",
           # nikah_requests names its handled column differently
           "reviewed_at",
           # migration 018 — the office records a fee paid in cash
           "fee_status", "fee_amount_p", "fee_paid_at"}

STUB = r"""
(function () {
  var DB = window.__DB = { roles: ["admin"], writes: [], reads: [], rpcs: [] };

  DB.halls = [
    // Deposit PAID. The payment confirmed it (017) — nobody in the office did.
    { id:"h1", created_at:"2026-09-06T23:00:00Z", booking_date:"__SOON__",
      hire_type:"halls", halls_count:2, session_slot:null, hall:null, kitchen:null,
      reference:"HH-26-0001", deposit_status:"paid",
      deposit_paid_at:"__PAID_OLDER__", hold_expires_at:null,
      base_amount_p:50000, extras_p:15400,
      balance_status:"unpaid", balance_paid_at:null,
      first_name:"Imran", last_name:"Ali", address:"12 Astley Street, Bolton",
      phone:"07700900111", status:"confirmed", office_notes:null,
      handled_at:"2026-09-06T09:05:00Z" },
    // Kitchen only, still open, deposit money sitting with Stripe wrongly.
    { id:"h2", created_at:"2026-09-06T10:00:00Z", booking_date:"__LATER__",
      hire_type:"halls", halls_count:null, session_slot:null, hall:null, kitchen:null,
      reference:"HH-26-0002", deposit_status:"refund_due",
      deposit_paid_at:null, hold_expires_at:null,
      base_amount_p:12500, extras_p:0,
      balance_status:"unpaid", balance_paid_at:null,
      first_name:"Sara", last_name:"Bi", address:"9 Green Street, Bolton",
      phone:"07700900222", status:"new", office_notes:null, handled_at:null },
    // Taken under the OLD model. No rate on file — that combination is not on
    // the current price list and must never be rendered as £0.00.
    { id:"h3", created_at:"2026-08-01T10:00:00Z", booking_date:"__OLD__",
      hire_type:"halls", halls_count:1, session_slot:"evening", hall:"3", kitchen:true,
      reference:"HH-26-0003", deposit_status:"unpaid",
      deposit_paid_at:null, hold_expires_at:null,
      base_amount_p:null, extras_p:0,
      balance_status:"unpaid", balance_paid_at:null,
      first_name:"Zaid", last_name:"Hussain", address:"4 Mill Street, Bolton",
      phone:"07700900333", status:"confirmed", office_notes:"Agreed on the phone",
      handled_at:"2026-08-02T10:00:00Z" }
    ,
    // PAID but the status never moved — a half-written row. Still booked.
    { id:"h4", created_at:"2026-09-06T09:00:00Z", booking_date:"__STUCK__",
      hire_type:"halls", halls_count:3, session_slot:null, hall:null, kitchen:null,
      reference:"HH-26-0004", deposit_status:"paid",
      deposit_paid_at:"__PAID_RECENT__", hold_expires_at:null,
      base_amount_p:70000, extras_p:0,
      balance_status:"unpaid", balance_paid_at:null,
      first_name:"Bilal", last_name:"Khan", address:"22 Deane Road, Bolton",
      phone:"07700900444", status:"new", office_notes:null, handled_at:null }
    ,
    // Opened the checkout and walked away. The hold lapsed forty minutes ago,
    // the date has already released itself, and nothing in the database will
    // ever touch this row again. Before 11 September 2026 this sat in "New
    // requests" looking exactly like somebody waiting for a phone call.
    { id:"h5", created_at:"__MADE_DEAD__", booking_date:"__GONE__",
      hire_type:"halls", halls_count:1, session_slot:null, hall:null, kitchen:null,
      reference:"HH-26-0005", deposit_status:"awaiting",
      deposit_paid_at:null, hold_expires_at:"__HOLD_DEAD__",
      base_amount_p:30000, extras_p:0,
      balance_status:"unpaid", balance_paid_at:null,
      first_name:"Walked", last_name:"Away", address:"1 Gone Street, Bolton",
      phone:"07700900555", status:"new", office_notes:null, handled_at:null },
    // In Stripe's checkout RIGHT NOW. Eighteen minutes left on the hold, so
    // "sent to pay" is still true and must still be what it says.
    { id:"h6", created_at:"__MADE_LIVE__", booking_date:"__LIVE__",
      hire_type:"halls", halls_count:1, session_slot:null, hall:null, kitchen:null,
      reference:"HH-26-0006", deposit_status:"awaiting",
      deposit_paid_at:null, hold_expires_at:"__HOLD_LIVE__",
      base_amount_p:30000, extras_p:0,
      balance_status:"unpaid", balance_paid_at:null,
      first_name:"Still", last_name:"Paying", address:"2 Live Street, Bolton",
      phone:"07700900666", status:"new", office_notes:null, handled_at:null }
  ];
  DB.halls[1].hire_type = "kitchen_only";
  DB.nikah = [
    // Fee PAID, but still awaiting the office's decision. This is the shape
    // migration 018 exists to make possible, and the one most likely to be
    // broken by somebody "making it consistent with the hall".
    { id:"n1", submitted_at:"2026-09-06T09:30:00Z", reference:"NK-26-0001",
      preferred_date:"__SOON__", alternative_date:null, slot:"after_zuhr",
      preferred_time:"13:15", guests_estimate:40,
      contact_name:"Yusuf Patel", contact_role:"family",
      contact_phone:"07700900555", contact_email:"yusuf@example.test",
      notes:null, status:"new", office_notes:null, reviewed_at:null,
      fee_status:"paid", fee_amount_p:10000, fee_paid_at:"2026-09-06T09:40:00Z" },
    // Fee owed back — the family paid for a date the masjid declined.
    { id:"n2", submitted_at:"2026-09-05T09:30:00Z", reference:"NK-26-0002",
      preferred_date:"__LATER__", alternative_date:null, slot:"after_asr",
      preferred_time:"16:00", guests_estimate:null,
      contact_name:"Aisha Malik", contact_role:"bride",
      contact_phone:"07700900666", contact_email:"aisha@example.test",
      notes:null, status:"declined", office_notes:"Imam away", reviewed_at:"2026-09-05T12:00:00Z",
      fee_status:"refund_due", fee_amount_p:20000, fee_paid_at:"2026-09-05T10:00:00Z" },
    // Nothing paid yet.
    { id:"n3", submitted_at:"2026-09-06T11:30:00Z", reference:"NK-26-0003",
      preferred_date:"__OLD__", alternative_date:null, slot:"flexible",
      preferred_time:null, guests_estimate:null,
      contact_name:"Bilal Ahmed", contact_role:"groom",
      contact_phone:"07700900777", contact_email:"bilal@example.test",
      notes:null, status:"new", office_notes:null, reviewed_at:null,
      fee_status:"unpaid", fee_amount_p:null, fee_paid_at:null }
  ];

  function copy(v){ return JSON.parse(JSON.stringify(v)); }

  function makeQ(table) {
    var q = {
      _op:"select", _patch:null, _filters:[],
      select:function(){ return q; },
      order:function(){ return q; },
      eq:function(c,v){ q._filters.push([c,v]); return q; },
      update:function(p){ q._op="update"; q._patch=p; return q; },
      maybeSingle:function(){ return run().then(function(r){
        return { data:(r.data && r.data[0]) || null, error:r.error }; }); },
      then:function(a,b){ return run().then(a,b); }
    };
    function run(){
      if (q._op === "update") {
        DB.writes.push({ table:table, patch:copy(q._patch), filters:copy(q._filters) });
        return Promise.resolve({ data:null, error:null });
      }
      DB.reads.push(table);
      if (table === "profiles")
        return Promise.resolve({ data:[{ full_name:"An Administrator", email:"admin@example.test" }], error:null });
      if (table === "user_roles")
        return Promise.resolve({ data:DB.roles.map(function(r){ return { role:r }; }), error:null });
      if (table === "hall_bookings")   return Promise.resolve({ data:copy(DB.halls), error:null });
      if (table === "nikah_requests")  return Promise.resolve({ data:copy(DB.nikah), error:null });
      return Promise.resolve({ data:[], error:null });
    }
    return q;
  }

  var client = {
    auth: {
      getSession:function(){ return Promise.resolve({ data:{ session:{ user:{ id:"u1" } } }, error:null }); },
      getUser:function(){ return Promise.resolve({ data:{ user:{ id:"u1", email:"admin@example.test" } }, error:null }); },
      signOut:function(){ return Promise.resolve({ error:null }); },
      signInWithPassword:function(){ return Promise.resolve({ error:{ message:"not used" } }); },
      mfa:{
        getAuthenticatorAssuranceLevel:function(){
          return Promise.resolve({ data:{ currentLevel:"aal2", nextLevel:"aal2" }, error:null }); },
        listFactors:function(){ return Promise.resolve({ data:{ totp:[{ id:"f1" }] }, error:null }); }
      }
    },
    from:function(t){ return makeQ(t); },
    rpc:function(name, args){
      DB.rpcs.push({ name:name, args:copy(args || {}) });
      return Promise.resolve({ data:null, error:null });
    }
  };

  var stub = { createClient:function(){ return client; } };
  Object.defineProperty(window, "supabase", { value:stub, writable:false, configurable:false });
  window.__STUB = stub;
})();
""".replace("__SOON__", SOON).replace("__LATER__", LATER).replace("__OLD__", OLD).replace("__STUCK__", STUCK).replace("__GONE__", GONE).replace("__LIVE__", LIVE).replace("__PAID_RECENT__", PAID_RECENT).replace("__PAID_OLDER__", PAID_OLDER).replace("__HOLD_DEAD__", HOLD_DEAD).replace("__HOLD_LIVE__", HOLD_LIVE).replace("__MADE_DEAD__", MADE_DEAD).replace("__MADE_LIVE__", MADE_LIVE)

REASON = "Double booked with a funeral service, trustees agreed"
# What the next window.prompt() will be answered with. Mutable so the test can
# try a too-short reason first and a real one after.
reply = ["no"]

with sync_playwright() as p:
    b = p.chromium.launch()
    pg = b.new_page(viewport={"width": 1280, "height": 1000})
    pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.on("console", lambda m: errs.append("console: " + m.text) if m.type == "error" else None)
    pg.on("dialog", lambda d: d.accept(reply[0]))
    pg.add_init_script(STUB)
    pg.goto(PAGE)
    pg.wait_for_timeout(1000)

    # 0. is the stub the client the page actually used?
    check(pg.evaluate("window.supabase === window.__STUB"),
          "the page replaced the stub — every assertion below would be meaningless")
    check("hall_bookings" in pg.evaluate("window.__DB.reads"), "the portal never read hall_bookings")

    check(pg.eval_on_selector("#bk-panel", "e=>!e.hidden"), "the bookings panel is hidden from an admin")

    # ========================================================================
    #  0b. WHAT THE OFFICE SEES WHEN THE PAGE OPENS
    #
    #  The assertions that matter most in this file, and the newest.
    #
    #  Migration 017 made paying the deposit confirm the booking outright, so
    #  a paid hall booking is 'confirmed' the moment the money lands and never
    #  passes through 'new'. The page still landed on "New requests" — which
    #  showed the office every hirer who ABANDONED the checkout and hid every
    #  hirer who actually paid. Reported on 11 September 2026 as "there is no
    #  way in the admin centre to know they have paid online", which was the
    #  visible half of it.
    #
    #  Nothing below clicks a tab first. That is the whole point: this is the
    #  screen somebody opens.
    # ========================================================================
    landed = pg.eval_on_selector(".bk-tab.on", "e=>e.dataset.filter")
    check(landed == "recent",
          "the portal lands on %r, so a paid booking is not on the first screen" % landed)

    open_txt = pg.inner_text("#bk-list")
    opening = pg.eval_on_selector_all(".bk-item", "els=>els.map(e=>e.dataset.id)")

    # THE HEADLINE REGRESSION, stated plainly. h1 is the ordinary shape of a
    # hall booking after migration 017: paid, and therefore already confirmed.
    # It was invisible on the opening screen for four days because "New
    # requests" means status = 'new' and a paid booking is never 'new'.
    check("h1" in opening,
          "A PAID, CONFIRMED BOOKING IS NOT ON THE SCREEN THE OFFICE OPENS")
    # Recent shows everything, so nothing can be hiding on another tab.
    total = pg.evaluate("window.__DB.halls.length + window.__DB.nikah.length")
    check(len(opening) == total,
          "the opening screen shows %d of %d records — something is hidden on another tab"
          % (len(opening), total))

    check("HH-26-0004" in open_txt,
          "A DEPOSIT PAID TWO HOURS AGO IS NOT ON THE SCREEN THE OFFICE OPENS")
    check("deposit paid" in open_txt.lower(),
          "nothing on the opening screen says a deposit has been paid")
    check("paid 2 hours ago" in open_txt.lower() or "paid an hour ago" in open_txt.lower(),
          "the opening screen does not say WHEN the money landed")

    # Ordered by what happened, not by when the form was filled in or when the
    # booking is. h4 was requested after h1 and is further away in the diary;
    # it is first only because its payment is the most recent event.
    order = pg.eval_on_selector_all(".bk-item", "els=>els.map(e=>e.dataset.id)")
    stamps = pg.eval_on_selector_all(".bk-item", "els=>els.map(e=>e.dataset.activity)")
    check(all(stamps[i] >= stamps[i + 1] for i in range(len(stamps) - 1)),
          "Recent is not in newest-activity order: %r" % list(zip(order, stamps))[:5])
    # The claim that actually matters, and the one a sort by booking_date or
    # by created_at would both get wrong: h4 was requested at the same time as
    # h1 and is FURTHER away in the diary, and comes first purely because its
    # payment is the more recent event.
    check(pos(order, "h4", "Recent") < pos(order, "h1", "Recent"),
          "a deposit paid two hours ago sorts below one paid five days ago")
    check(pos(order, "h4", "Recent") < pos(order, "h3", "Recent"),
          "a payment from this morning sorts below a booking handled in August")

    # An abandoned checkout is still listed — the office may want to ring them
    # — but must never read as somebody waiting for a decision.
    gone = pg.query_selector('.bk-item[data-id="h5"]')
    check(gone is not None, "an abandoned checkout has vanished entirely")
    if gone is not None:
        g = gone.inner_text().lower()
        check("checkout abandoned" in g,
              "a lapsed hold is not labelled as an abandoned checkout")
        check("sent to pay" not in g,
              "a lapsed hold still claims the hirer is on their way to pay")
        check("never paid, date released" in g,
              "the office is not told the date went back on sale")
        check("left to pay" not in g,
              "a lapsed hold still counts down as though somebody were paying")
        check("bk-gone" in (gone.get_attribute("class") or ""),
              "an abandoned checkout is styled identically to a live request")

    # ...and one that genuinely IS in Stripe right now must be untouched by
    # that. Eighteen minutes left on the hold.
    live = pg.query_selector('.bk-item[data-id="h6"]')
    check(live is not None, "a live checkout is missing from the list")
    if live is not None:
        l = live.inner_text().lower()
        check("deposit not paid" in l,
              "a live checkout does not say the deposit is NOT paid")
        check("left to pay" in l,
              "a live hold does not say how long the hirer has left: %r" % l[:160])
        check("checkout abandoned" not in l,
              "a hold with eighteen minutes left is called abandoned")
        check("bk-gone" not in (live.get_attribute("class") or ""),
              "a live checkout is greyed out as though it had lapsed")

    # The count is "what happened this week", not the size of the table.
    check(pg.inner_text("#bk-n-recent").strip().isdigit(),
          "the Recent tab has no count")

    # And the structural fact underneath the whole complaint: New requests
    # contains no paid hall booking, because paying confirms it.
    pg.click('.bk-tab[data-filter="new"]'); pg.wait_for_timeout(300)
    new_ids = pg.eval_on_selector_all(".bk-item", "els=>els.map(e=>e.dataset.id)")
    # h1 is the ordinary case: paid, therefore confirmed, therefore NOT a
    # request anybody has to decide. h4 is the deliberate half-written row —
    # paid but its status never moved — and it belongs here precisely because
    # something is wrong with it.
    check("h1" not in new_ids,
          "a PAID and CONFIRMED booking appears under New requests — nobody has to decide it")
    check("h4" in new_ids,
          "the half-written row (paid, status never moved) has disappeared from New")
    new_txt = pg.inner_text("#bk-list")
    check("h5" not in new_ids or "checkout abandoned" in new_txt.lower(),
          "an abandoned checkout sits in New requests unlabelled")

    pg.click('.bk-tab[data-filter="all"]')
    pg.wait_for_timeout(300)
    txt = pg.inner_text("#bk-list")

    # 1. a new whole-day booking
    check("2 halls" in txt, "a two-hall booking is not described as two halls")
    check("whole day" in txt.lower(), "a new booking does not say it is whole-day")
    check("kitchen and cleaning included" in txt.lower(),
          "the office is not told the kitchen and cleaning are included")

    # 2. kitchen only
    check("Kitchen only" in txt, "a kitchen-only booking is not described as one")

    # 3. a booking taken under the old model, rendered as it was taken
    check("Evening" in txt and "Hall 3" in txt,
          "an old session booking lost what it actually was")
    check("old session rates" in txt.lower(),
          "an old booking is not marked as taken under the old rates")

    # 4. nothing from the retired model leaks into a new booking's line
    first = pg.eval_on_selector_all(".bk-item", "els=>els.map(e=>e.innerText)")
    new_line = [t for t in first if "Imran" in t]
    detail = new_line[0].split("\n")[1] if new_line else ""
    check("Hall 1" not in detail and "Hall 3" not in detail and "Evening" not in detail
          and "with kitchen" not in detail,
          "a new booking is described with the old hall/session wording: %r" % detail)

    # 4b. deposit state — the office cannot act on what it cannot see
    check("HH-26-0001" in txt, "booking references are not shown")
    check("deposit paid" in txt.lower(), "a paid deposit is not shown")
    check("refund due" in txt.lower(), "a deposit owed back is not shown")
    rf = pg.query_selector("#bk-tab-refunds")
    check(rf is not None and not rf.is_hidden(),
          "the refund-due tab is hidden even though one is due")
    # Two, not one: a hall deposit and a nikāḥ fee are both money the masjid
    # holds and cannot keep. The nikāḥ half is checked properly at 5h.
    check(pg.inner_text("#bk-n-rf").strip() == "2",
          "the refund count is wrong: %s" % pg.inner_text("#bk-n-rf").strip())
    pg.click("#bk-tab-refunds"); pg.wait_for_timeout(300)
    only = sorted(pg.eval_on_selector_all(".bk-item", "els=>els.map(e=>e.dataset.id)"))
    check(only == ["h2", "n2"],
          "the refund tab does not narrow to those needing refunding: %s" % only)
    pg.click('.bk-tab[data-filter="all"]'); pg.wait_for_timeout(300)

    # ---------------------------------------------------------------------
    # 5. MIGRATION 017 — the deposit is what books the date.
    #
    # The masjid's decision on 7 September 2026: once £100 has been taken the
    # date is sold. The office does not get to confirm what has already been
    # paid for, and it must not be able to decline it with one click, because
    # declining after payment means the masjid has somebody's money and no
    # date to give them.
    # ---------------------------------------------------------------------
    paid = pg.query_selector('.bk-item[data-id="h1"]')
    acts = [b.inner_text().strip()
            for b in paid.query_selector_all(".bk-btn")]
    check("Confirm" not in acts,
          "a booking that has already been paid for still offers Confirm: %s" % acts)
    check("Decline" not in acts,
          "a paid booking can still be declined in one click: %s" % acts)
    check("Balance received" in acts, "no way to record the balance on a paid booking: %s" % acts)
    check("Cancel & refund" in acts,
          "a paid booking cannot be cancelled at all — there has to be a way out: %s" % acts)
    check("Save notes" in acts, "notes cannot be saved on a paid booking: %s" % acts)

    # 5a. and the same rule on a row whose status never moved. Without this
    #     the assertion above would pass for the wrong reason — h1 is already
    #     confirmed, so it would show no Confirm button either way.
    stuck = pg.query_selector('.bk-item[data-id="h4"]')
    sacts = [x.inner_text().strip() for x in stuck.query_selector_all(".bk-btn")]
    check("Confirm" not in sacts,
          "a paid booking still shows Confirm because its status stayed 'new': %s" % sacts)
    check("Decline" not in sacts,
          "a paid booking can be declined because its status stayed 'new': %s" % sacts)
    check("Cancel & refund" in sacts,
          "the half-written paid row has no way out at all: %s" % sacts)

    # 5b. the arithmetic, spelled out so the office never has to do it.
    #     £500 base + £154 extras − £100 deposit = £554 outstanding.
    m1 = paid.query_selector(".bk-money").inner_text().replace("\n", " ")
    for want in ["£500", "base", "£154", "extras", "£100", "deposit",
                 "£554", "outstanding"]:
        check(want in m1, "the money line is missing %r: %r" % (want, m1))

    # 5c. no deposit paid means the whole amount is owed, deposit not deducted.
    kit = pg.query_selector('.bk-item[data-id="h2"]')
    m2 = kit.query_selector(".bk-money").inner_text().replace("\n", " ")
    check("£125" in m2, "the kitchen-only base rate is not shown: %r" % m2)
    check("deposit" not in m2.lower(),
          "a £100 deposit was deducted from a booking that never paid one: %r" % m2)

    # 5d. a booking with no rate on file. £0.00 would be a lie and NaN would be
    #     a bug the office reports as "the portal is broken".
    old = pg.query_selector('.bk-item[data-id="h3"]')
    m3 = old.query_selector(".bk-money").inner_text()
    check("No rate on file" in m3, "a booking with no stored rate does not say so: %r" % m3)
    check("NaN" not in m3, "a missing rate rendered as NaN: %r" % m3)
    check("£0" not in m3, "a missing rate rendered as £0: %r" % m3)
    check("NaN" not in txt, "NaN appears somewhere in the list")

    # 5e. the balance tab: only confirmed hall bookings, only inside 30 days.
    bt = pg.query_selector("#bk-tab-balance")
    check(bt is not None and not bt.is_hidden(),
          "the balance tab is hidden even though a balance is due inside 30 days")
    check(pg.inner_text("#bk-n-bal").strip() == "1", "the balance count is wrong")
    pg.click("#bk-tab-balance"); pg.wait_for_timeout(300)
    owing = pg.eval_on_selector_all(".bk-item", "els=>els.map(e=>e.dataset.id)")
    check(owing == ["h1"],
          "the balance tab does not narrow to the one owing inside 30 days: %s" % owing)
    pg.click('.bk-tab[data-filter="all"]'); pg.wait_for_timeout(300)

    # ---------------------------------------------------------------------
    # 5f. MIGRATION 018 — a nikāḥ fee is NOT a deposit.
    #
    # The masjid does not publish its nikāḥ diary, so the site cannot know
    # whether a date is free and a payment cannot buy one. n1 has paid its
    # fee and is still awaiting the office's decision; it must therefore
    # still offer Agree date and Decline. If those ever disappear, somebody
    # has copied the hall's behaviour across and the masjid is selling dates
    # the imam may not be free for.
    # ---------------------------------------------------------------------
    nk = pg.query_selector('.bk-item[data-id="n1"]')
    check(nk is not None, "the paid nikāḥ request is not in the list at all")
    if nk:
        nacts = [x.inner_text().strip() for x in nk.query_selector_all(".bk-btn")]
        check("Agree date" in nacts,
              "a paid nikāḥ fee removed the office's decision: %s" % nacts)
        check("Decline" in nacts,
              "the office can no longer decline a nikāḥ it has been paid for: %s" % nacts)
        check("Confirm" not in nacts,
              "a nikāḥ says Confirm rather than Agree date: %s" % nacts)

        ntxt = nk.inner_text()
        check("fee paid" in ntxt.lower(), "a paid nikāḥ fee is not shown: %r" % ntxt)
        check("£100" in ntxt, "the amount paid is not shown: %r" % ntxt)
        check("member rate" in ntxt.lower(),
              "which rate was paid is not shown, so a wrong one is invisible: %r" % ntxt)
        # The wording must never suggest the date is settled.
        check("deposit" not in ntxt.lower(),
              "a nikāḥ fee is described as a deposit: %r" % ntxt)
        check(nk.query_selector(".bk-dep") is None,
              "a nikāḥ row carries the deposit badge, which means 'this date is sold'")
        check(nk.query_selector(".bk-fee-pill") is not None,
              "a paid nikāḥ fee has no badge of its own")

    # 5g. an unpaid one offers both rates, and says what they are.
    nk3 = pg.query_selector('.bk-item[data-id="n3"]')
    if nk3:
        n3acts = [x.inner_text().strip() for x in nk3.query_selector_all(".bk-btn")]
        check("£100 received" in n3acts and "£200 received" in n3acts,
              "the office cannot record a nikāḥ fee paid in cash: %s" % n3acts)
        check("£100 members, £200 otherwise" in nk3.inner_text(),
              "an unpaid nikāḥ row does not say what the fee is: %r" % nk3.inner_text())

    # 5h. a nikāḥ fee owed back must reach the refunds tab. Before 018 that
    #     tab looked only at hall deposits, so a nikāḥ refund was invisible.
    check(pg.inner_text("#bk-n-rf").strip() == "2",
          "the refund count does not include the nikāḥ fee owed back: %s"
          % pg.inner_text("#bk-n-rf").strip())
    pg.click("#bk-tab-refunds"); pg.wait_for_timeout(300)
    ref_ids = sorted(pg.eval_on_selector_all(".bk-item", "els=>els.map(e=>e.dataset.id)"))
    check(ref_ids == ["h2", "n2"],
          "the refunds tab does not show both kinds of refund: %s" % ref_ids)
    pg.click('.bk-tab[data-filter="all"]'); pg.wait_for_timeout(300)

    # 5i. recording a cash fee writes the fee columns and NOT the status.
    b_fee = button(pg, "n3", "fee_200")
    if b_fee: b_fee.click()
    pg.wait_for_timeout(500)
    fw = pg.evaluate("window.__DB.writes")
    check(len(fw) == 1, "recording a nikāḥ fee did not write, saw %d" % len(fw))
    if fw:
        check(fw[0]["table"] == "nikah_requests",
              "the fee was written to %r" % fw[0]["table"])
        keys = sorted(fw[0]["patch"].keys())
        check(keys == ["fee_amount_p", "fee_paid_at", "fee_status", "office_notes"],
              "recording a nikāḥ fee wrote %s" % keys)
        check(fw[0]["patch"]["fee_amount_p"] == 20000,
              "the wrong amount was recorded: %r" % fw[0]["patch"])
        check("status" not in fw[0]["patch"],
              "recording a nikāḥ fee also moved the request's status — "
              "paying does not agree a date")
        check("reviewed_at" not in fw[0]["patch"],
              "recording a nikāḥ fee stamped it as reviewed")

    # Sections 6 and 7 count writes from zero. Keep every write for the
    # granted-columns check at 6c, then clear the log, rather than teaching
    # each later assertion to skip over the fee write above.
    pg.evaluate("window.__DB.allWrites = window.__DB.writes.slice(); "
                "window.__DB.writes = [];")

    # 6. the office may still only write the columns it is granted.
    #    Done on the UNPAID booking, because the paid one no longer has a
    #    Confirm button at all — which is the point of this migration.
    item = pg.query_selector('.bk-item[data-id="h2"]')
    item.query_selector("[data-notes]").fill("Rang, they are not going ahead")
    # Declining, not confirming. A hall booking nobody has paid for no longer
    # HAS a Confirm button — see 6c — so the column-grant check rides on the
    # action the office does still have.
    b_conf = button(pg, "h2", "declined")
    if b_conf: b_conf.click()
    pg.wait_for_timeout(500)
    w = pg.evaluate("window.__DB.writes")
    check(len(w) == 1, "expected one write, saw %d" % len(w))
    if w:
        keys = sorted(w[0]["patch"].keys())
        check(keys == ["extras_p", "handled_at", "office_notes", "status"],
              "the portal wrote %s" % keys)
        check(w[0]["table"] == "hall_bookings", "the write went to %r" % w[0]["table"])
        blob = json.dumps(w[0]["patch"]).lower()
        for gone in ["hire_type", "halls_count", "session_slot", "kitchen", "hall",
                     "phone", "address", "base_amount_p", "reference", "stripe"]:
            check(gone not in blob, "the portal tried to write %r" % gone)

    # ========================================================================
    #  6c. THE OFFICE CANNOT SELL A DATE NOBODY HAS PAID FOR
    #
    #  Reported 11 September 2026: a test booking with no deposit showed as
    #  CONFIRMED. It had been confirmed thirty seconds after it was requested
    #  — by somebody pressing Confirm. Migration 017 made paying the
    #  confirmation and removed the office's NEED to confirm; it did not
    #  remove the button, and nothing in the database refused the write.
    #
    #  The button is gone here AND migration 021 refuses the UPDATE. Both, not
    #  either: on this project a check that only exists in JavaScript does not
    #  exist. _test_unpaid_not_booked.sql is the other half.
    # ========================================================================
    unpaid = pg.query_selector('.bk-item[data-id="h6"]')     # in checkout now
    check(unpaid is not None, "the live-checkout booking is missing")
    if unpaid is not None:
        uacts = [x.inner_text().strip() for x in unpaid.query_selector_all(".bk-btn")]
        check("Confirm" not in uacts,
              "AN UNPAID HALL BOOKING STILL OFFERS CONFIRM: %s" % uacts)
        check(any("cash" in a.lower() for a in uacts),
              "no way to record a deposit taken at the counter: %s" % uacts)
        check("Decline" in uacts,
              "an unpaid request can no longer be declined: %s" % uacts)
        u = unpaid.inner_text().lower()
        check("deposit not paid" in u,
              "an unpaid booking does not plainly say the deposit is not paid")

    # A nikāḥ request is NOT a hall booking and still needs a human decision —
    # the masjid does not publish its nikāḥ diary, so nothing can agree a date
    # except a person. Removing that button would be a different bug.
    nk = pg.query_selector('.bk-item[data-id="n3"]')
    if nk is not None:
        nacts = [x.inner_text().strip() for x in nk.query_selector_all(".bk-btn")]
        check("Agree date" in nacts,
              "a nikāḥ request lost the office's decision button: %s" % nacts)

    # Taking cash is an RPC, not an UPDATE. "The money arrived" and "the date
    # is sold" are one event; splitting them into a status write is how they
    # drift apart, and it would also lose who recorded the payment.
    pg.evaluate("window.__DB.writes = []; window.__DB.rpcs = [];")
    b_cash = pg.query_selector('.bk-item[data-id="h6"] .bk-btn[data-act="cash_deposit"]')
    check(b_cash is not None, "no cash-deposit button to press")
    if b_cash is not None:
        b_cash.click()
        pg.wait_for_timeout(600)
        rpcs = pg.evaluate("window.__DB.rpcs")
        writes = pg.evaluate("window.__DB.writes")
        names = [c["name"] for c in rpcs]
        check("record_cash_deposit" in names,
              "taking cash did not go through record_cash_deposit: %r" % names)
        check(len(writes) == 0,
              "taking cash also wrote columns directly: %r" % writes)
        if "record_cash_deposit" in names:
            args = [c["args"] for c in rpcs if c["name"] == "record_cash_deposit"][0]
            check(args.get("p_reference") == "HH-26-0006",
                  "the cash deposit was recorded against %r" % args.get("p_reference"))
            check(args.get("p_amount_p") == 10000,
                  "the cash deposit was not £100: %r" % args.get("p_amount_p"))

    pg.evaluate("window.__DB.writes = []; window.__DB.rpcs = [];")
    pg.click('.bk-tab[data-filter="all"]'); pg.wait_for_timeout(300)

    # 6b. recording the balance writes the balance columns and nothing else.
    pg.wait_for_timeout(300)
    b_bal = button(pg, "h1", "balance_paid")
    if b_bal: b_bal.click()
    pg.wait_for_timeout(500)
    # The write log was cleared at the end of 6c, so this is the only one.
    w = pg.evaluate("window.__DB.writes")
    check(len(w) == 1, "recording a balance did not write, saw %d writes" % len(w))
    if w:
        keys = sorted(w[0]["patch"].keys())
        check(keys == ["balance_paid_at", "balance_status", "extras_p", "office_notes"],
              "recording a balance wrote %s" % keys)
        check(w[0]["patch"]["balance_status"] == "paid",
              "the balance was not marked paid: %r" % w[0]["patch"])
        check("status" not in w[0]["patch"],
              "recording a balance also moved the booking's status — it is already confirmed")

    # 6c. every write, across every action, stays inside the granted set.
    every = set()
    for row in (pg.evaluate("window.__DB.allWrites || []")
                + pg.evaluate("window.__DB.writes")):
        every |= set(row["patch"].keys())
    check(every <= ALLOWED,
          "the portal writes columns the office is not granted: %s" % sorted(every - ALLOWED))

    # 7. cancelling a paid booking is NOT an UPDATE. It has to go through
    #    cancel_paid_booking(), which insists on a written reason and audits it,
    #    because it always means sending £100 back to somebody.
    before = len(pg.evaluate("window.__DB.writes"))

    # 7a. a too-short reason cancels nothing. "no" is what somebody types when
    #     they meant to press something else, and it must not refund £100.
    reply[0] = "no"
    b_can = button(pg, "h1", "cancel_refund")
    if b_can: b_can.click()
    pg.wait_for_timeout(500)
    check(len(pg.evaluate("window.__DB.rpcs")) == 0,
          "a two-letter reason was enough to cancel a paid booking and refund it")
    check(len(pg.evaluate("window.__DB.writes")) == before,
          "an abandoned cancellation still wrote to the booking")
    still = [b.inner_text().strip()
             for b in pg.query_selector_all('.bk-item[data-id="h1"] .bk-btn')]
    check(all(b.strip() != "" for b in still) and "Cancel & refund" in still,
          "the buttons were left disabled after an abandoned cancellation: %s" % still)
    check(not pg.eval_on_selector('.bk-item[data-id="h1"] .bk-btn',
                                  "e=>e.disabled"),
          "the buttons stayed disabled after the office changed its mind")

    # 7c. a real reason goes through the RPC.
    reply[0] = REASON
    b_can = button(pg, "h1", "cancel_refund")
    if b_can: b_can.click()
    pg.wait_for_timeout(600)
    rpcs = pg.evaluate("window.__DB.rpcs")
    names = [r["name"] for r in rpcs]
    check("cancel_paid_booking" in names,
          "cancelling a paid booking did not call cancel_paid_booking: %s" % names)
    cp = [r for r in rpcs if r["name"] == "cancel_paid_booking"]
    if cp:
        args = cp[0]["args"]
        check(args.get("p_reference") == "HH-26-0001",
              "cancel_paid_booking was given the wrong booking: %r" % args)
        check(args.get("p_reason") == REASON,
              "the typed reason was not passed through: %r" % args)
    check(len(pg.evaluate("window.__DB.writes")) == before,
          "cancelling a paid booking also fired a direct UPDATE — it must not")

    # 8. mobile
    pg.set_viewport_size({"width": 390, "height": 844})
    pg.wait_for_timeout(200)
    width = pg.evaluate("document.documentElement.scrollWidth")
    check(width <= 392, "horizontal overflow at 390px (%dpx)" % width)

    pg.close()
    b.close()

httpd.shutdown()
print("JS errors:", errs or "none")
print("FAILURES:", len(fails))
for f in fails:
    print("  -", f)
sys.exit(1 if (fails or errs) else 0)
