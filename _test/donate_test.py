"""The donation page — choose what for, how often, how much, then one button.

14 September 2026.

WHAT THIS FILE GUARDS:

  * 1  the chooser exists in full: three purposes, two frequencies, six
       amounts. Losing one is the kind of change nobody notices
  * 2  WITH NO PAYMENT LINKS the button cannot be pressed, says so, and the
       bank details carry the page. A dead gold button on a donation page is
       the worst possible outcome — it looks like the masjid took the money
  * 3  WITH LINKS the button carries the RIGHT url for the chosen combination
  * 4  the purpose rides as client_reference_id rather than needing its own
       link. Thirty-six links is not a thing anybody would maintain
  * 5  switching frequency keeps the grid the same shape — amounts with no
       link grey out rather than disappearing
  * 6  Gift Aid is mentioned once there is a checkout to reach, and not
       before. The long declaration lives on Stripe's page
  * 7  nothing on this page uploads or collects anything

Run:  python3 _test/donate_test.py
"""
from playwright.sync_api import sync_playwright
import sys, os, re, http.server, socketserver, threading, functools

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
PAGE = "http://127.0.0.1:%d/index.html" % httpd.server_address[1]

fails = []
D = '[data-page="donate"] '


def check(cond, msg):
    if not cond:
        fails.append(msg)


#  Fills the link table in the page's own closure. The page reads DONATE_LINKS
#  once, so this has to run before its IIFE — hence an init script that leaves
#  a value for the page to find rather than reaching into it afterwards.
FILL = """
(function(){
  var REAL = {
    once:    { '5':'https://buy.stripe.test/o5',  '10':'https://buy.stripe.test/o10',
               '25':'https://buy.stripe.test/o25', '50':'https://buy.stripe.test/o50',
               '100':'https://buy.stripe.test/o100', other:'https://buy.stripe.test/oany' },
    monthly: { '5':'https://buy.stripe.test/m5',  '10':'https://buy.stripe.test/m10',
               '25':'https://buy.stripe.test/m25', '50':'', '100':'', other:'' }
  };
  //  The page builds its own object literal, so the only honest way in is to
  //  let it build it and then rewrite it before the first render. A
  //  MutationObserver on the card is enough: the pills appear on first render.
  document.addEventListener('DOMContentLoaded', function(){
    var i = setInterval(function(){
      var host = document.getElementById('dn-amounts');
      if (!host || !host.children.length) return;
      clearInterval(i);
      window.__FILLED = REAL;
    }, 40);
  });
})();
"""


def open_donate(b, fill=False):
    pg = b.new_page(viewport={"width": 1360, "height": 1000})
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:220]))
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1100)
    pg.evaluate("""() => { const a = document.querySelector('[data-nav="donate"]');
                           if (a) a.click(); }""")
    pg.wait_for_timeout(600)
    return pg, errs


def pills(pg, box):
    return pg.eval_on_selector_all(
        D + "#" + box + " .dn-pill",
        "els => els.map(e => ({k: e.dataset.k, on: e.getAttribute('aria-pressed'),"
        " off: e.disabled, t: e.innerText.replace(/\\s+/g,' ').trim()}))")


with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1. THE CHOOSER IS ALL THERE
    # =====================================================================
    pg, errs = open_donate(b)
    purp = [x["k"] for x in pills(pg, "dn-purpose")]
    check(purp == ["general", "sadaqah", "lillah"],
          "the purposes are wrong: %r" % purp)
    freq = [x["k"] for x in pills(pg, "dn-freq")]
    check(freq == ["once", "monthly", "jummah"],
          "the frequencies are wrong: %r" % freq)
    #  Friday Pay, by its label rather than its key — the committee asked for
    #  that wording, and a key nobody sees is not what was agreed.
    flabels = " ".join(x["t"] for x in pills(pg, "dn-freq"))
    check("Friday Pay" in flabels, "Friday Pay is not offered: %r" % flabels)
    amts = [x["k"] for x in pills(pg, "dn-amounts")]
    check(amts == ["5", "10", "25", "50", "100", "other"],
          "the amounts are wrong: %r" % amts)
    #  Every amount the masjid asked for, by its label, not just its key.
    labels = " ".join(x["t"] for x in pills(pg, "dn-amounts"))
    for want in ["£5", "£10", "£25", "£50", "£100", "Other"]:
        check(want in labels, "%s is not offered: %r" % (want, labels))

    # =====================================================================
    #  2. NO LINKS — THE BUTTON MUST NOT BE PRESSABLE
    # =====================================================================
    go = pg.query_selector(D + "#dn-go")
    check(go.get_attribute("aria-disabled") == "true",
          "THE DONATE BUTTON IS PRESSABLE WITH NO PAYMENT LINK BEHIND IT")
    check(go.get_attribute("href") in (None, ""),
          "the donate button has an href with no link configured: %r"
          % go.get_attribute("href"))
    check("not available" in pg.text_content(D + "#dn-go-main").lower(),
          "the button does not say it is unavailable: %r"
          % pg.text_content(D + "#dn-go-main"))
    check(pg.is_visible(D + "#dn-soon"),
          "nothing tells the donor card giving is not open yet")
    check(pg.is_visible(D + ".bank-card"),
          "the bank details are not there to carry the page")
    check(not pg.is_visible(D + "#dn-ga-note"),
          "the Gift Aid line shows with no checkout to reach")
    check(not pg.is_visible(D + "#dn-card-note"),
          "the note describing a checkout shows with no checkout")

    # =====================================================================
    #  7. NOTHING IS COLLECTED HERE
    # =====================================================================
    #  The zakāt warning moved out of its own section and into the card, at
    #  the point where somebody chooses Sadaqah. It must not have been lost in
    #  the move — a donor giving zakāt to a general fund is a religious
    #  problem, not a formatting one.
    card = re.sub(r"\s+", " ", pg.text_content(D + "#dn-give"))
    check("Zak" in card and "not taken here" in card,
          "the zakāt warning is no longer in the giving card: %r" % card[:200])
    check("01204" in card, "the zakāt line does not give the office number")

    #  THE ORDER AND THE SPLIT, asked for explicitly. Both are the kind of
    #  thing a later CSS tidy-up undoes without anybody noticing.
    order = pg.evaluate("""() => {
        const p = document.querySelector('[data-page="donate"] .page-body');
        const y = s => p.querySelector(s).getBoundingClientRect().top;
        return { where: y('.dn-top'), give: y('.dn-main'), bank: y('.dn-bank') }; }""")
    check(order["where"] < order["give"],
          "'Where your giving goes' is no longer above the giving card")
    split = pg.evaluate("""() => {
        const a = document.querySelector('[data-page="donate"] .dn-main').getBoundingClientRect();
        const c = document.querySelector('[data-page="donate"] .dn-bank').getBoundingClientRect();
        return { side: Math.abs(a.top - c.top) < 40,
                 pct: Math.round(100 * a.width / (a.width + c.width)) }; }""")
    check(split["side"], "the giving card and the bank details are not side by side")
    check(65 <= split["pct"] <= 73,
          "the split is %d/%d, not 70/30" % (split["pct"], 100 - split["pct"]))

    #  THREE ACROSS, TWO ROWS. Asked for explicitly, and measured rather than
    #  taken from the CSS — six in a line and three in a line are both
    #  "grid-template-columns" until you look at where they land.
    rows = pg.evaluate("""() => {
        const t = [...document.querySelectorAll('[data-page="donate"] #dn-amounts .dn-pill')]
          .map(e => Math.round(e.getBoundingClientRect().top));
        return [...new Set(t)].length; }""")
    check(rows == 2, "the amounts are on %d row(s), not two rows of three" % rows)
    h = pg.evaluate("""() => Math.round(document.querySelector(
        '[data-page="donate"] #dn-amounts .dn-pill').getBoundingClientRect().height)""")
    check(h >= 70, "the amount buttons are only %dpx tall — they were made "
                   "bigger on purpose" % h)

    inputs = pg.eval_on_selector_all(D + "input, " + D + "textarea",
                                     "els => els.map(e => e.type || 'textarea')")
    check(inputs == [], "this page has form fields on it: %r" % inputs)
    check(errs == [], "the donate page threw: %s" % errs)
    pg.close()

    # =====================================================================
    #  3-6. WITH LINKS
    #
    #  The page holds DONATE_LINKS in a closure, so rather than reaching into
    #  it the links are rewritten in the BUILT page and it is reloaded. That
    #  also proves the thing that actually matters: that pasting links into
    #  that object is all the masjid has to do.
    # =====================================================================
    src = open("index.html", encoding="utf-8").read()
    LIVE = ("      once:    { '5':'https://buy.stripe.test/o5', '10':'https://buy.stripe.test/o10', "
            "'25':'https://buy.stripe.test/o25', '50':'https://buy.stripe.test/o50', "
            "'100':'https://buy.stripe.test/o100', other:'https://buy.stripe.test/oany' },\n"
            "      monthly: { '5':'https://buy.stripe.test/m5', '10':'https://buy.stripe.test/m10', "
            "'25':'https://buy.stripe.test/m25', '50':'', '100':'', other:'' },\n"
            "      jummah:  { '5':'https://buy.stripe.test/f5', '10':'', "
            "'25':'', '50':'', '100':'', other:'' }")
    old = ("      once:    { '5':'', '10':'', '25':'', '50':'', '100':'', other:'' },\n"
           "      monthly: { '5':'', '10':'', '25':'', '50':'', '100':'', other:'' },\n"
           "      jummah:  { '5':'', '10':'', '25':'', '50':'', '100':'', other:'' }")
    if old not in src:
        fails.append("the link table is not where the test expects it — "
                     "pasting links in may not be a one-place change any more")
    else:
        open("_donate_live.html", "w", encoding="utf-8").write(src.replace(old, LIVE, 1))
        try:
            pg = b.new_page(viewport={"width": 1360, "height": 1000})
            errs2 = []
            pg.on("pageerror", lambda e: errs2.append(str(e)[:220]))
            pg.goto("http://127.0.0.1:%d/_donate_live.html" % httpd.server_address[1],
                    wait_until="load")
            pg.wait_for_timeout(1100)
            pg.evaluate("""() => { const a = document.querySelector('[data-nav="donate"]');
                                   if (a) a.click(); }""")
            pg.wait_for_timeout(600)

            go = pg.query_selector(D + "#dn-go")
            href = go.get_attribute("href") or ""
            #  3: the default selection is one-off, £25, the masjid.
            check("/o25" in href, "the default button does not point at the £25 "
                                  "one-off link: %r" % href)
            #  4: the purpose rides along rather than needing its own link.
            check("client_reference_id=general" in href,
                  "the purpose is not attached to the payment: %r" % href)

            pg.click(D + '#dn-purpose .dn-pill[data-k="lillah"]')
            pg.wait_for_timeout(200)
            href = pg.get_attribute(D + "#dn-go", "href") or ""
            check("client_reference_id=lillah" in href,
                  "choosing Lillah did not change what is sent: %r" % href)
            check("/o25" in href,
                  "choosing a purpose changed the AMOUNT link: %r" % href)

            pg.click(D + '#dn-amounts .dn-pill[data-k="50"]')
            pg.wait_for_timeout(200)
            check("/o50" in (pg.get_attribute(D + "#dn-go", "href") or ""),
                  "choosing £50 did not change the link")
            check("50" in pg.text_content(D + "#dn-go-main"),
                  "the button does not name the amount: %r"
                  % pg.text_content(D + "#dn-go-main"))

            #  5: switching to monthly must not reshape the grid.
            before = len(pills(pg, "dn-amounts"))
            pg.click(D + '#dn-freq .dn-pill[data-k="monthly"]')
            pg.wait_for_timeout(250)
            after = pills(pg, "dn-amounts")
            check(len(after) == before,
                  "the amount grid changed shape when frequency changed: %d -> %d"
                  % (before, len(after)))
            offs = [x["k"] for x in after if x["off"]]
            check(offs == ["50", "100", "other"],
                  "the wrong amounts are unavailable monthly: %r" % offs)
            #  £50 was chosen and has no monthly link — the button must refuse
            #  rather than send somebody to a one-off page for a monthly gift.
            check(pg.get_attribute(D + "#dn-go", "aria-disabled") == "true",
                  "THE BUTTON STAYED PRESSABLE FOR A COMBINATION WITH NO LINK")

            pg.click(D + '#dn-amounts .dn-pill[data-k="10"]')
            pg.wait_for_timeout(200)
            href = pg.get_attribute(D + "#dn-go", "href") or ""
            check("/m10" in href, "the monthly £10 link is not used: %r" % href)
            check("month" in pg.text_content(D + "#dn-go-main").lower(),
                  "the button does not say the gift is monthly: %r"
                  % pg.text_content(D + "#dn-go-main"))

            #  6: Gift Aid appears now there is a checkout to read it about.
            check(pg.is_visible(D + "#dn-ga-note"),
                  "nothing mentions Gift Aid when card giving is live — that is "
                  "25p in every eligible pound a donor never learns was on offer")
            #  The long declaration belongs on Stripe's page now, not here.
            check(pg.query_selector(D + ".ga-decl") is None,
                  "the full Gift Aid declaration is still on the page")
            check(not pg.is_visible(D + "#dn-soon"),
                  "the 'opens shortly' note still shows with links configured")
            #  GOLD. `.donate-cta` sets a plum background and is defined LATER
            #  in the stylesheet, so `.dn-go` alone lost on source order —
            #  same specificity is not the same as winning. Asserted on the
            #  computed value, which is the only thing that would have caught it.
            bg = pg.evaluate("""() => getComputedStyle(
                document.querySelector('[data-page="donate"] #dn-go')).backgroundColor""")
            check("198, 162, 76" in bg,
                  "the donate button is not gold — it is the page's one action "
                  "and every chosen pill beside it is plum: %s" % bg)
            # =============================================================
            #  7. FRIDAY PAY
            #
            #  Added 14 September 2026. Stripe bills a weekly subscription
            #  every seven days FROM THE DAY IT STARTS; there is no way to
            #  anchor it to a Friday from a Payment Link. The gift is still
            #  weekly and still the same size, so the feature is sound — but
            #  a masjid page that promises a day it cannot deliver is not,
            #  and a donor who notices has been misled by their own masjid.
            #  The note is therefore part of the feature, not decoration,
            #  and this asserts it is on screen and says "seven days".
            # =============================================================
            pg.click(D + '#dn-freq .dn-pill[data-k="jummah"]')
            pg.wait_for_timeout(250)
            pg.click(D + '#dn-amounts .dn-pill[data-k="5"]')
            pg.wait_for_timeout(220)

            href = pg.get_attribute(D + "#dn-go", "href") or ""
            check("/f5" in href, "the Friday Pay £5 link is not used: %r" % href)
            #  Still carries the designation — a weekly Lillah is a Lillah.
            pg.click(D + '#dn-purpose .dn-pill[data-k="lillah"]')
            pg.wait_for_timeout(220)
            href = pg.get_attribute(D + "#dn-go", "href") or ""
            check("client_reference_id=lillah" in href,
                  "Friday Pay loses the purpose: %r" % href)

            main = pg.text_content(D + "#dn-go-main") or ""
            check("Friday" in main,
                  "the button does not say the gift repeats every Friday: %r" % main)

            note = (pg.text_content(D + "#dn-freq-hint") or "")
            check(pg.is_visible(D + "#dn-freq-hint") and "seven days" in note,
                  "THE PAGE PROMISES FRIDAY WITHOUT SAYING STRIPE TAKES IT "
                  "EVERY SEVEN DAYS FROM THE DAY YOU START: %r" % note)

            #  The amounts with no Friday link grey out, same as monthly, and
            #  the grid keeps its shape.
            fri = pills(pg, "dn-amounts")
            check(len(fri) == before,
                  "the amount grid changed shape on Friday Pay: %d -> %d"
                  % (before, len(fri)))
            check([x["k"] for x in fri if x["off"]] == ["10", "25", "50", "100", "other"],
                  "the wrong amounts are unavailable on Friday Pay: %r"
                  % [x["k"] for x in fri if x["off"]])

            #  And the one-off note must NOT be showing — a single gift that
            #  told people it repeats would be the worst version of this.
            pg.click(D + '#dn-freq .dn-pill[data-k="once"]')
            pg.wait_for_timeout(220)
            check(not pg.is_visible(D + "#dn-freq-hint"),
                  "a one-off gift is being described as recurring: %r"
                  % pg.text_content(D + "#dn-freq-hint"))

            check(errs2 == [], "the donate page threw with links: %s" % errs2)
            pg.close()
        finally:
            if os.path.exists("_donate_live.html"):
                os.remove("_donate_live.html")
    b.close()

httpd.shutdown()
if fails:
    print("\nFAILURES (%d):" % len(fails))
    for f in fails:
        print("  " + f)
    sys.exit(1)
print("\nALL PASS")
