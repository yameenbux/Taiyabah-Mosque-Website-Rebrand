"""A class the committee wrote, and a class they invented.

15 September 2026. `043` let the masjid open, close, rename and re-size a
class. It could not let them ADD one, and the screen said so: the website held
more about a course than the table did — which sessions it runs, what the
experience question asks, the wording shown when sign-ups are shut — and none
of it was anywhere but a hard-coded object in the page.

`047` put that content in the database. This checks both halves of what it
bought.

WHAT THIS GUARDS

  *  1  AMENDING A CLASS CHANGES THE PAGE. The heading, the one-line
        description, the opening paragraph, the fact strip and the "what to
        know" list all come from the database now, and the two hand-written
        pages are updated in place rather than regenerated — they are not the
        same shape as each other and flattening them into one template would
        quietly degrade the two best-written pages on the site.

  *  2  A CLASS THE PAGE HAS NEVER HEARD OF IS BUILT FROM NOTHING: a card on
        the Education index and a page of its own, reachable by clicking.

  *  3  IT IS ACTUALLY REACHABLE. `pages` was a STATIC NodeList captured at
        load, so a page added afterwards was invisible to showPage() — the URL
        would change, the old page would stay on screen, and nothing would
        throw. This is the check that would have caught that.

  *  4  A HALF-WRITTEN CLASS IS NOT PUBLISHED. A masthead over an empty body
        is worse than no page at all, so a class whose copy is incomplete is
        skipped entirely rather than drawn badly.

  *  5  THE FORM IS BUILT FROM THE COMMITTEE'S WORDS. The session labels and
        the experience question come from the database, so renaming "Men's
        class" to "Brothers" changes the radio button and nothing else.

  *  6  NOTHING IS EVER INJECTED AS MARKUP. This is the only content on the
        site typed straight onto a public page by somebody who is not a
        developer. It is written with DOM calls, and a heading containing a
        script tag has to arrive as literal text.

  *  7  FAILURE TAKES NOTHING AWAY. The built-in pages stay exactly as the
        build left them.

Run:  python3 _test/class_pages_test.py
"""
from playwright.sync_api import sync_playwright
import functools
import http.server
import json
import os
import socketserver
import sys
import threading

ROOT = os.environ.get("SITE_ROOT") or os.path.abspath(
    os.path.join(os.path.dirname(__file__), ".."))
os.chdir(ROOT)
socketserver.TCPServer.allow_reuse_address = True


class Q(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass


httpd = socketserver.TCPServer(("127.0.0.1", 0), functools.partial(Q, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d/" % httpd.server_address[1]

fails = []


def check(ok, why):
    if not ok:
        fails.append(why)


def page(key, **over):
    p = {
        "name": "A Class", "tagline": "A one-line description.",
        "intro": "An opening paragraph about the class.",
        "facts": [{"k": "Time", "v": "6–7pm"}, {"k": "Places", "v": "12"}],
        "rules": [{"k": "When", "v": "Tuesdays."}, {"k": "Who for", "v": "Adults."}],
        "cohorts": [{"key": "mens", "label": "Men's class"},
                    {"key": "womens", "label": "Women's class"}],
        "exp_label": "How much do you know already?",
        "exp": [{"key": "none", "label": "Nothing at all"},
                {"key": "some", "label": "A little"}],
        "open": "Fill in the form below.",
        "closed": "Ring the office to be told about the next one.",
        "tile": {"tag": "Weekly", "p": "A tile paragraph.", "meta": "15 places"},
    }
    p.update(over)
    return p


def course(key, **over):
    c = {"key": key, "name": "A Class", "is_open": True, "capacity": 12,
         "sort_order": 9, "cohort_mode": "separate", "places_left": 4,
         "page": page(key)}
    c.update(over)
    return c


#  The two that are compiled into the page, as they really are.
ARABIC = course("arabic", name="Arabic Classes", capacity=15, sort_order=1,
                places_left=3,
                page=page("arabic", name="Arabic Classes",
                          tagline="AMENDED tagline for the Arabic class.",
                          intro="AMENDED opening paragraph.",
                          facts=[{"k": "Time", "v": "8–9pm"}],
                          rules=[{"k": "When", "v": "AMENDED — Wednesdays."}],
                          cohorts=[{"key": "mens", "label": "Brothers"},
                                   {"key": "womens", "label": "Sisters"}]))
GHUSL = course("ghusl", name="Ghusl Workshop", capacity=15, sort_order=2,
               page=page("ghusl", name="Ghusl Workshop"))

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    def home(rows, status=200):
        pg = b.new_page(viewport={"width": 1280, "height": 900})
        seen = []
        pg.on("pageerror", lambda e: seen.append(str(e)[:160]))
        pg.route("**/rest/v1/rpc/courses_public", lambda r: r.fulfill(
            status=status, content_type="application/json",
            body=json.dumps(rows) if status == 200 else "no"))
        for stub in ("**/rest/v1/notices_live*", "**/rest/v1/site_content*"):
            pg.route(stub, lambda r: r.fulfill(
                status=200, content_type="application/json", body="[]"))
        pg.goto(BASE, wait_until="load", timeout=45000)
        pg.wait_for_timeout(1500)
        return pg, seen

    # ------------------------------------------- 1 and 5. amending a class
    pg, seen = home([ARABIC, GHUSL])
    r = pg.evaluate("""() => {
      const p = document.querySelector('[data-page="svc-edu-arabic"]');
      const host = document.querySelector('.course-reg[data-course="arabic"]');
      return {
        h1:    p.querySelector('.section-head h1').textContent,
        tag:   p.querySelector('.section-head p').textContent,
        intro: p.querySelector('.svc-detail-facts > p').textContent,
        facts: [...p.querySelectorAll('.svc-facts .svc-fact')].map(f => f.textContent),
        rules: [...p.querySelectorAll('.adm-rules dt')].map(d => d.textContent),
        labels: [...host.querySelectorAll('.yn2 label')].map(l => l.textContent.trim()),
        expQ:  (host.querySelector('label[for$="exp"]') || {}).textContent || '',
        lead:  (host.querySelector('.cform-lead') || {}).textContent || ''
      };
    }""")
    check(r["h1"] == "Arabic Classes", "the heading was not applied: %r" % r["h1"])
    check("AMENDED" in r["tag"],
          "the one-line description still says what the build compiled in, so "
          "amending a class changes nothing a visitor sees: %r" % r["tag"][:80])
    check("AMENDED" in r["intro"], "the opening paragraph was not applied")
    check(r["facts"] == ["Time8–9pm"],
          "the fact strip is %r — it should be the single fact from the "
          "database, replacing the two compiled in" % r["facts"])
    check(r["rules"] == ["When"],
          "the what-to-know list is %r, so the database did not replace it" % r["rules"])
    check(r["labels"] == ["Brothers", "Sisters"],
          "the session buttons say %r. Renaming a session in the portal must "
          "change the radio button and nothing else." % r["labels"])
    check("How much do you know already?" in r["expQ"],
          "the experience question was not taken from the database: %r" % r["expQ"])
    check("3 places" in r["lead"],
          "the places-left line is %r" % r["lead"][:90])
    check(seen == [], "the page threw: %s" % seen[:2])
    pg.close()

    # ------------------------- 2 and 3. a class the page has never heard of
    NEW = course("tajwid", name="Tajwīd Classes", sort_order=3,
                 page=page("tajwid", name="Tajwīd Classes",
                           tagline="Reciting the Qur'an as it should be read.",
                           intro="A paragraph about tajwīd."))
    pg, seen = home([ARABIC, GHUSL, NEW])
    r = pg.evaluate("""() => {
      const tile = [...document.querySelectorAll('.edu-grid .edu-tile')]
                     .find(t => t.getAttribute('data-nav') === 'svc-edu-tajwid');
      const pageEl = document.querySelector('[data-page="svc-edu-tajwid"]');
      const soon = document.querySelector('.edu-grid .edu-tile.is-soon');
      const tiles = [...document.querySelectorAll('.edu-grid .edu-tile')];
      return {
        tile: !!tile,
        tileH: tile ? tile.querySelector('.et-h').textContent : null,
        beforeSoon: !!(tile && soon) && tiles.indexOf(tile) < tiles.indexOf(soon),
        page: !!pageEl,
        h1: pageEl ? pageEl.querySelector('h1').textContent : null,
        host: !!document.querySelector('.course-reg[data-course="tajwid"] form'),
        rules: pageEl ? [...pageEl.querySelectorAll('.adm-rules dt')].map(d=>d.textContent) : []
      };
    }""")
    check(r["tile"], "no card was added to the Education index for the new class, "
                     "so there is no way to reach it")
    check(r["tileH"] == "Tajwīd Classes", "the card is headed %r" % r["tileH"])
    check(r["beforeSoon"],
          "the new class was placed after the 'More courses — coming soon' "
          "placeholder, which belongs last")
    check(r["page"], "no page was built for the new class")
    check(r["h1"] == "Tajwīd Classes", "the new page is headed %r" % r["h1"])
    check(r["host"], "the new page has no registration form on it")
    check(r["rules"] == ["When", "Who for"],
          "the new page's what-to-know list is %r" % r["rules"])

    #  3. and it can actually be navigated to.
    #
    #  Via the Education page, because that is where the card lives and the
    #  card is invisible until that page is the active one — this site is one
    #  document with thirty-odd sections in it, only one of them shown. The
    #  first version of this clicked the card straight from the home page and
    #  timed out on "element is not visible", which was the test being wrong
    #  about the site rather than the site being wrong.
    #  Getting TO the Education page is setup, not the thing being tested, and
    #  at 1280px there is no link to it that Playwright considers visible —
    #  they all sit inside sections that are not currently shown. So the event
    #  is dispatched on the anchor itself.
    #
    #  This still obeys the rule in the README: navigate by clicking real
    #  links, never by calling showPage(). A dispatched click runs the site's
    #  own handler and would fail if that handler were broken; showPage() is
    #  hoisted and would work even then, which is why it is banned.
    pg.evaluate("""() => {
      const l = document.querySelector('[data-nav="svc-education"]');
      if (l) l.click();
    }""")
    pg.wait_for_timeout(500)
    pg.click('.edu-grid .edu-tile[data-nav="svc-edu-tajwid"]')
    pg.wait_for_timeout(600)
    nav = pg.evaluate("""() => {
      const el = document.querySelector('[data-page="svc-edu-tajwid"]');
      return { active: el.classList.contains('page-active'),
               others: [...document.querySelectorAll('.page.page-active')].length,
               hash: location.hash };
    }""")
    check(nav["active"],
          "clicking the new class's card did NOT bring its page up. `pages` "
          "used to be a static NodeList captured at load, which made every "
          "page added afterwards unreachable while nothing threw.")
    check(nav["others"] == 1, "%d pages are active at once" % nav["others"])
    check(nav["hash"] == "#svc-edu-tajwid", "the address bar says %r" % nav["hash"])
    check(seen == [], "the page threw: %s" % seen[:2])
    pg.close()

    # ------------------------------------------ 4. a half-written class
    HALF = course("halfdone", name="Half Done",
                  page=page("halfdone", intro="", rules=[]))
    pg, seen = home([ARABIC, GHUSL, HALF])
    r = pg.evaluate("""() => ({
      page: !!document.querySelector('[data-page="svc-edu-halfdone"]'),
      tile: [...document.querySelectorAll('.edu-grid .edu-tile')]
              .some(t => t.getAttribute('data-nav') === 'svc-edu-halfdone')
    })""")
    check(r["page"] is False,
          "a class with no opening paragraph and no what-to-know rows was given "
          "a page anyway. A masthead over an empty body is worse than no page.")
    check(r["tile"] is False, "a half-written class was advertised on the index")
    check(seen == [], "the page threw: %s" % seen[:2])
    pg.close()

    # ------------------------------------------------- 6. nothing is markup
    POISON = '<img src=x onerror="window.__pwned=1">'
    EVIL = course("evil", name=POISON,
                  page=page("evil", name=POISON, tagline=POISON, intro=POISON,
                            rules=[{"k": "When", "v": POISON}]))
    pg, seen = home([ARABIC, GHUSL, EVIL])
    r = pg.evaluate("""() => {
      const el = document.querySelector('[data-page="svc-edu-evil"]');
      return { pwned: !!window.__pwned,
               imgs: el ? el.querySelectorAll('img').length : -1,
               h1: el ? el.querySelector('h1').textContent : null };
    }""")
    check(r["pwned"] is False,
          "A CLASS NAME WAS EXECUTED AS HTML. This is the only content on the "
          "site typed straight onto a public page by somebody who is not a "
          "developer, which is exactly why it is built with DOM calls.")
    check(r["imgs"] == 0, "%d images were parsed out of the poisoned copy" % r["imgs"])
    check(r["h1"] == POISON, "the poisoned name was not rendered as literal text")
    check(seen == [], "the page threw: %s" % seen[:2])
    pg.close()

    # --------------------------------- 7. failure leaves the build's pages
    for label, rows, status in (("a 500", [], 500), ("an empty list", [], 200)):
        pg, seen = home(rows, status)
        r = pg.evaluate("""() => {
          const p = document.querySelector('[data-page="svc-edu-arabic"]');
          return { h1: p.querySelector('.section-head h1').textContent,
                   rules: [...p.querySelectorAll('.adm-rules dt')].map(d=>d.textContent),
                   form: !!document.querySelector('.course-reg[data-course="arabic"] form') };
        }""")
        check(r["h1"] == "Arabic Classes", "%s changed the heading" % label)
        check(len(r["rules"]) == 5,
              "%s left the Arabic page with %d what-to-know rows instead of the "
              "five the build compiled in" % (label, len(r["rules"])))
        check(r["form"], "%s took the registration form away" % label)
        check(seen == [], "%s made the page throw: %s" % (label, seen[:2]))
        pg.close()

    b.close()

print("\n" + ("ALL PASS — a class amended, a class invented, one half-written "
              "and refused, and a poisoned one rendered as text"
              if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails[:20])))
sys.exit(1 if fails else 0)
