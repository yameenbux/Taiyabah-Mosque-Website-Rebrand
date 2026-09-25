"""What the public site and the portal actually cost to open.

NOT a pass/fail suite. It prints numbers, three runs each, so a change can be
judged against a before. Timings are from the browser's own Performance API,
not from Python's clock, which measures the harness as much as the page.

    python3 _test/perf_measure.py [--cold]

--cold throttles to a slow connection and 4x slower CPU, which is closer to
the phone somebody actually opens this on in a corridor than a container with
no network latency at all.
"""
import http.server
import json
import os
import socketserver
import statistics
import sys
import threading

from playwright.sync_api import sync_playwright

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
COLD = "--cold" in sys.argv
RUNS = 3


class Quiet(http.server.SimpleHTTPRequestHandler):
    """Serves gzip, because GitHub Pages does and the answer changes.

    The first version of this harness served everything uncompressed. It
    reported 633 KB for index.html and made the HTML look like the single
    biggest cost on a slow connection — about two and a half seconds of
    invented transfer time. GitHub Pages gzips it to 184 KB. Optimising
    against that number would have meant tearing up the page structure to
    fix a problem that only existed in the test.

    A measurement that does not match how the thing is actually served is
    not a measurement of the thing.
    """

    def log_message(self, *a):
        pass

    def end_headers(self):
        http.server.SimpleHTTPRequestHandler.end_headers(self)

    def send_head(self):
        import gzip
        import io
        import posixpath
        import urllib.parse

        path = self.translate_path(self.path)
        if os.path.isdir(path):
            path = os.path.join(path, "index.html")
        if not os.path.exists(path) or os.path.isdir(path):
            return http.server.SimpleHTTPRequestHandler.send_head(self)

        ctype = self.guess_type(path)
        compressible = any(ctype.startswith(p) for p in
                           ("text/", "application/javascript",
                            "application/json", "image/svg"))
        accepts = "gzip" in (self.headers.get("Accept-Encoding") or "")

        with open(path, "rb") as f:
            body = f.read()

        headers = [("Content-type", ctype)]
        if compressible and accepts:
            buf = io.BytesIO()
            with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=6) as gz:
                gz.write(body)
            body = buf.getvalue()
            headers.append(("Content-Encoding", "gzip"))

        self.send_response(200)
        for k, v in headers:
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        return io.BytesIO(body)


socketserver.TCPServer.allow_reuse_address = True
httpd = socketserver.TCPServer(
    ("127.0.0.1", 0), lambda *a: Quiet(*a, directory=ROOT))
threading.Thread(target=httpd.serve_forever, daemon=True).start()
BASE = "http://127.0.0.1:%d" % httpd.server_address[1]

#  The numbers that correspond to what somebody experiences, in order:
#  when the page stops being blank, when the biggest thing on it appears,
#  and how much the layout jumped while they were trying to read it.
SCRIPT = """() => {
  const nav = performance.getEntriesByType('navigation')[0] || {};
  const paints = {};
  for (const p of performance.getEntriesByType('paint')) paints[p.name] = p.startTime;
  let lcp = 0;
  for (const e of performance.getEntriesByType('largest-contentful-paint') || []) lcp = e.startTime;
  const res = performance.getEntriesByType('resource');
  const byType = {};
  for (const r of res) {
    const k = r.initiatorType || 'other';
    byType[k] = byType[k] || { n: 0, bytes: 0, ms: 0 };
    byType[k].n++;
    byType[k].bytes += r.transferSize || 0;
    byType[k].ms = Math.max(byType[k].ms, r.responseEnd);
  }
  return {
    ttfb: nav.responseStart || 0,
    domInteractive: nav.domInteractive || 0,
    domContentLoaded: nav.domContentLoadedEventEnd || 0,
    loadEvent: nav.loadEventEnd || 0,
    firstPaint: paints['first-paint'] || 0,
    firstContentfulPaint: paints['first-contentful-paint'] || 0,
    lcp: lcp,
    htmlBytes: nav.transferSize || 0,
    resources: res.length,
    byType: byType,
  };
}"""


def measure(browser, path, label, after_load_ms=1200, width=1366, dpr=1):
    runs = []
    for _ in range(RUNS):
        ctx = browser.new_context(
            viewport={"width": width, "height": 900},
            device_scale_factor=dpr,
            #  Cache off for every run: the question is what a first-time
            #  visitor waits for, and a warm cache answers a different one.
            bypass_csp=True)
        pg = ctx.new_page()
        if COLD:
            cdp = ctx.new_cdp_session(pg)
            cdp.send("Network.emulateNetworkConditions", {
                "offline": False, "latency": 150,
                "downloadThroughput": 1_600_000 / 8,
                "uploadThroughput": 750_000 / 8})
            cdp.send("Emulation.setCPUThrottlingRate", {"rate": 4})
        pg.goto(BASE + path, wait_until="load")
        pg.wait_for_timeout(after_load_ms)
        runs.append(pg.evaluate(SCRIPT))
        ctx.close()

    def med(k):
        return statistics.median(r[k] for r in runs)

    print("\n%s   %s" % (label, path))
    print("   TTFB                    %7.0f ms" % med("ttfb"))
    print("   first contentful paint  %7.0f ms" % med("firstContentfulPaint"))
    print("   largest contentful paint%7.0f ms" % med("lcp"))
    print("   DOM interactive         %7.0f ms" % med("domInteractive"))
    print("   load event              %7.0f ms" % med("loadEvent"))
    print("   html transferred        %7.0f KB" % (med("htmlBytes") / 1024))
    print("   sub-resources           %7.0f" % med("resources"))
    bt = runs[-1]["byType"]
    for k in sorted(bt, key=lambda x: -bt[x]["bytes"]):
        v = bt[k]
        print("      %-12s %3d files  %7.0f KB  last finished %6.0f ms"
              % (k, v["n"], v["bytes"] / 1024, v["ms"]))
    return {k: med(k) for k in
            ("firstContentfulPaint", "lcp", "domInteractive", "loadEvent")}


def main():
    print("=" * 66)
    print("throttled: slow 3G-ish, 4x CPU" if COLD
          else "unthrottled (container speed - treat as a floor, not a promise)")
    print("=" * 66)
    with sync_playwright() as p:
        b = p.chromium.launch()
        measure(b, "/index.html", "PUBLIC SITE  desktop 1366")
        measure(b, "/index.html", "PUBLIC SITE  phone 390 @2x", width=390, dpr=2)
        measure(b, "/portal/", "PORTAL shell")
        measure(b, "/portal/fees/", "FEES landing")
        measure(b, "/portal/classes/", "CLASSES")
        b.close()
    httpd.shutdown()


if __name__ == "__main__":
    main()
