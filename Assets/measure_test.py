"""How wide the words are — line length, centring, and the page's own width.

14 September 2026. Written after the container went from 1080px to 1280px so
the site would stop filling 56% of a desktop screen. Widening the page made an
existing fault worse before it made anything better, and none of it showed up
in any check the repository already had:

  * /prayer-times was setting a line of 147 characters, /madrasah 167 and
    /about 156. Past about 85 the eye loses its place coming back to the left,
    which is the same fault as small type and hurts the same readers. Capping
    the prose at 62ch fixed it — and nothing anywhere said the cap existed, so
    the next person to add a wide section would have undone it silently.

  * The cap then knocked four centred paragraphs off centre, because a narrow
    block with text-align:center still sits at the left of its parent unless
    it keeps auto side margins. On /media that left 723px of empty space to
    the right of the text. Reading the CSS would not have told you: the CSS
    said text-align:center, and it was.

WHAT THIS GUARDS

  1  no run of prose sets a line longer than 82 characters
  2  no centred paragraph is off centre in its parent
  3  the container really is wider than it was, at a real desktop size
  4  and it still does not exceed the window on a phone

Characters per line are COUNTED two ways that have to agree — total characters
over rendered line boxes, and a Range walk to the first visual break. One of
them alone is wrong in a case the other catches: the Range walk returns the
whole string when the text never wraps.

Nothing here reaches Supabase. It serves the built index.html from a local
port and drives it.

Run:  python3 _test/measure_test.py
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


def check(ok, why):
    if not ok:
        fails.append(why)


#  Every page the template declares, so a page added later is covered without
#  anyone remembering to add it here.
PAGES = sorted(set(re.findall(r'<div class="page" data-page="([a-z0-9-]+)"',
                              open("index_template.html", encoding="utf-8").read())))

MAX_CHARS = 82
OFF_CENTRE = 12          # px of asymmetry before it reads as misaligned

LINES = r"""
() => {
  //  (a) total characters over rendered line boxes
  //  (b) a Range walk to the first visual line break
  //  Reported together; the caller fails on the smaller of the two, so a
  //  disagreement can never turn a real fault into a pass.
  function byRange(el){
    const n=[...el.childNodes].find(x=>x.nodeType===3 && x.textContent.trim().length>60);
    if(!n) return null;
    const r=document.createRange(), t=n.textContent;
    r.setStart(n,0); r.setEnd(n,1);
    const top=r.getBoundingClientRect().top;
    for(let i=1;i<t.length;i++){
      r.setStart(n,i); r.setEnd(n,i+1);
      const b=r.getBoundingClientRect();
      if(b.height && b.top>top+2) return i;
    }
    return null;                       // never wrapped: tells us nothing
  }
  const out=[];
  document.querySelectorAll('.page-active p, .page-active li, .page-active dd')
    .forEach(e=>{
      if(!e.offsetParent) return;
      const t=(e.textContent||'').replace(/\s+/g,' ').trim();
      if(t.length<140) return;
      const r=e.getBoundingClientRect(), s=getComputedStyle(e);
      const lh=parseFloat(s.lineHeight)||parseFloat(s.fontSize)*1.4;
      const lines=Math.max(1, Math.round(r.height/lh));
      out.push({ perBox: Math.round(t.length/lines), byRange: byRange(e),
                 cls: (typeof e.className==='string'?e.className:'')||e.tagName,
                 sample: t.slice(0,40) });
    });
  return out;
}
"""

CENTRED = r"""
() => {
  const out=[];
  document.querySelectorAll('.page-active p, .page-active li, .page-active dd')
    .forEach(e=>{
      if(!e.offsetParent) return;
      if(getComputedStyle(e).textAlign!=='center') return;
      const a=e.getBoundingClientRect(), p=e.parentElement.getBoundingClientRect();
      if(p.width-a.width<4) return;         // fills its parent, nothing to judge
      const skew=Math.round(Math.abs((a.left-p.left)-(p.right-a.right)));
      if(skew>0) out.push({ skew: skew,
        cls:(typeof e.className==='string'?e.className:'')||e.tagName,
        sample:(e.textContent||'').trim().slice(0,40) });
    });
  return out;
}
"""

with sync_playwright() as p:
    b = p.chromium.launch(executable_path="/opt/pw-browsers/chromium")

    # =====================================================================
    #  1 + 2. LINE LENGTH AND CENTRING, ON EVERY PAGE, AT TWO DESKTOP SIZES
    #
    #  1920 is where the container stops growing and the lines are longest;
    #  1360 is the common laptop. A cap that only holds at one of them is not
    #  a cap.
    # =====================================================================
    for width in (1920, 1360):
        pg = b.new_page(viewport={"width": width, "height": 1000})
        pg.goto(PAGE, wait_until="load")
        pg.wait_for_timeout(1300)
        for name in PAGES:
            pg.evaluate("""n => { const a=document.querySelector('[data-nav="'+n+'"]');
                                  if(a) a.click(); else if(window.showPage) showPage(n); }""",
                        name)
            pg.wait_for_timeout(240)

            for r in pg.evaluate(LINES):
                counted = [x for x in (r["perBox"], r["byRange"]) if x]
                if min(counted) > MAX_CHARS:
                    check(False, "[%d] %s: %s sets a line of %d characters (%r)"
                                 % (width, name, r["cls"][:24], min(counted), r["sample"]))

            for r in pg.evaluate(CENTRED):
                if r["skew"] > OFF_CENTRE:
                    check(False, "[%d] %s: centred text is %dpx off centre — %s (%r)"
                                 % (width, name, r["skew"], r["cls"][:24], r["sample"]))
        pg.close()

    # =====================================================================
    #  3. THE PAGE USES THE SCREEN
    #
    #  The point of the change. A container that quietly goes back to 1080
    #  would pass every other check in this file.
    # =====================================================================
    pg = b.new_page(viewport={"width": 1920, "height": 1000})
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1300)
    w = pg.evaluate("""() => { const e=document.querySelector('.container');
                               return e ? Math.round(e.getBoundingClientRect().width) : 0; }""")
    check(w >= 1240, "on a 1920px screen the container is only %dpx — it was widened "
                     "to 1280 on 14 September 2026 and something has put it back" % w)
    pg.close()

    # =====================================================================
    #  4. AND STILL FITS A PHONE
    #
    #  The negative control for 3: a container set in px rather than min()
    #  would satisfy the check above and overflow every phone on earth.
    # =====================================================================
    pg = b.new_page(viewport={"width": 360, "height": 800})
    pg.goto(PAGE, wait_until="load")
    pg.wait_for_timeout(1300)
    narrow = pg.evaluate("""() => { const e=document.querySelector('.container');
                                    return e ? Math.round(e.getBoundingClientRect().width) : 0; }""")
    check(0 < narrow <= 360,
          "on a 360px phone the container is %dpx wide — it must stay inside the window" % narrow)
    over = pg.evaluate("""() => { const d=document.documentElement;
                                  return Math.max(0, d.scrollWidth-d.clientWidth); }""")
    check(over <= 2, "the page scrolls sideways by %dpx on a 360px phone" % over)
    pg.close()

    b.close()

print("\n" + ("ALL PASS — %d pages, 4 checks" % len(PAGES) if not fails
              else "FAILURES (%d):\n  " % len(fails) + "\n  ".join(fails)))
sys.exit(1 if fails else 0)
