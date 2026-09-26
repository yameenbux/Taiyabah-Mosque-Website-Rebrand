# Pupils roll rebuild — part one — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the roll of 552 pupils usable — paginated, sortable, filterable, with per-row actions — so it opens in about one screen instead of 28.6 on the desk and 37.9 on a phone.

**Architecture:** No database change and no new RPC. `madrasah_roll()` already returns all 552 rows as marks-only, and one call stays one call. A new `filtered()` function returns the matching rows in sort order; `drawRows()` renders one page of that array; `drawPager()` draws the controls. Search and every filter therefore see the whole roll, and pagination applies to what they leave — which is better than the system being copied, where a search has to round-trip to find a child on page 4.

**Tech Stack:** ES5 browser JavaScript only (`var`, `function`, no arrow/const/let — `.finally()` is accepted precedent). Generated into `portal/pupils/` by `tools/build_pupils_screen.py`. Playwright tests in `_test/pupils_test.py` against a local static server with a pinned `window.supabase` stub.

**Spec:** `docs/superpowers/specs/2026-09-26-pupils-screen-and-pupil-page-design.md`

## Global Constraints

- **ES5 only in browser JavaScript.** `var` and `function`; no arrow functions, `const`, `let`, template literals or `Object.assign`.
- **Never edit `portal/pupils/app.js` or `index.html` by hand.** Edit `tools/pupils_module.js` and the generator, then run `python3 tools/build_pupils_screen.py`.
- **Every new stylesheet rule set opens with `[hidden] { display: none !important; }`** — `[hidden]` has attribute-selector specificity and loses to a plain class otherwise. `portal/pupils/pupils.css` already has this; do not remove it.
- **The list says WHETHER, the record says WHAT.** No detail column (`medical`, `allergies`, `send_detail`, `ehcp_detail`, `address`, `notes`) may reach the list. Marks only.
- **Every class used in markup must be defined in a linked stylesheet or inline `<style>`**, or `_test/admin_shell_test.py` fails. `HOOKS_ONLY = {"inv-r", "pp-r"}` is the only exemption list.
- **Real pupil and teacher names never enter the repository.** Test fixtures use invented names.
- **A check that asserts something EXISTS is not a check that it WORKS.** Every new check is watched failing before it is trusted.

## Review Focus

Five things the spec implies, that a reasonable person would hit, and that no task's happy path exercises. Each has its test added to the task that owns the code.

1. **Filtering while on a later page shows an empty table.** Narrow to 12 results while on page 4 and the slice is past the end — the screen reads "no pupils match" when twelve do. Page must reset to 1 on any filter, search or page-size change. *(Task 1)*
2. **The pupil with no gender disappears.** 236 + 315 = 551, not 552. Selecting Boys then Girls must not imply the roll is 551, and "Everyone" must always show all 552. *(Task 3)*
3. **Sorting by age puts unknown ages first.** A null age compares as less than every number, so the children whose date of birth is missing float to the top as though they were newborns. Unknowns sort last in both directions. *(Task 2)*
4. **The Actions button opens the record instead of the menu.** The button sits inside `<tr class="pu-row">`, which has a click handler that opens the child. Without `stopPropagation` every menu click also opens a record — and that record write an audit row, so the mistake is recorded 552 times over. *(Task 4)*
5. **A menu left open when the page changes points at a pupil who is no longer on screen.** Changing page, sort or filter must close any open menu. *(Task 4)*

---

### Task 1: Pagination, page size, and a count line that reconciles

**Files:**
- Modify: `tools/pupils_module.js` — add `filtered()`, `PAGE`, `PER`, `drawPager()`; rewrite `drawRows()` to render a slice
- Modify: `tools/build_pupils_screen.py` — add the pager markup and the page-size control
- Modify: `portal/pupils/pupils.css` — `.pu-pager`, `.pu-page`, `.pu-per`
- Test: `_test/pupils_test.py`

**Interfaces:**
- Produces: `filtered()` returns an Array of row objects that match the current search, class filter and figure filter, in current sort order. Tasks 2 and 3 extend it; Task 4 reads it to find the row a menu belongs to.
- Produces: `PAGE` (1-based integer), `PER` (25 | 50 | 100), `resetPage()` which sets `PAGE = 1`.

- [ ] **Step 1: Write the failing tests**

```python
        # --- pagination --------------------------------------------------------
        many = [dict(ROLL[0], id="x%d" % i, name="Pupil %d" % i,
                     legacy_ref=str(2000 + i)) for i in range(120)]
        pg = open_page(b, roll=many, health=dict(HEALTH, on_roll=120))
        check("only one page of pupils is drawn",
              pg.locator("tr.pu-row").count() == 50)
        check("the count line says what is shown and out of how many",
              "1" in pg.inner_text("#pu-count") and "120" in pg.inner_text("#pu-count"),
              pg.inner_text("#pu-count"))
        check("there is a pager", pg.locator(".pu-pager").count() >= 1)
        pg.locator('.pu-page[data-page="2"]').first.click()
        pg.wait_for_timeout(300)
        check("page two draws the next fifty",
              pg.locator("tr.pu-row").count() == 50)
        check("and starts at the fifty-first pupil",
              "2050" in pg.inner_text("#pu-rows"), pg.inner_text("#pu-rows")[:80])
        pg.locator('.pu-per[data-per="100"]').first.click()
        pg.wait_for_timeout(300)
        check("asking for a hundred per page draws a hundred",
              pg.locator("tr.pu-row").count() == 100)

        #  REVIEW FOCUS 1. Narrowing the list while on a later page must not
        #  leave the slice past the end, which renders as "no pupil matches"
        #  when pupils do.
        pg.locator('.pu-per[data-per="25"]').first.click()
        pg.wait_for_timeout(200)
        pg.locator('.pu-page[data-page="4"]').first.click()
        pg.wait_for_timeout(200)
        check("we are on page four", pg.locator("tr.pu-row").count() == 25)
        pg.fill("#pu-q", "Pupil 11")
        pg.wait_for_timeout(300)
        n = pg.locator("tr.pu-row").count()
        check("searching from page four still shows the matches", n > 0, n)
        check("and does not claim there are none",
              pg.locator("#pu-empty").is_hidden())
        pg.close()
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 _test/pupils_test.py`
Expected: FAIL — `.pu-pager` does not exist, and 120 rows are drawn rather than 50.

- [ ] **Step 3: Split filtering from drawing**

In `tools/pupils_module.js`, add state beside the others:

```javascript
    var PAGE = 1;             // which page of the filtered roll is shown
    var PER  = 50;            // how many rows a page holds
```

Add `filtered()` above `drawRows()`:

```javascript
    //  THE FILTERED ROLL, IN ORDER. Pagination applies to what the filters
    //  leave, not to the data - so a search still sees all 552 children and
    //  the file being looked at is the one on screen. The system this
    //  replaces paginates server-side, so finding a child on page 4 costs a
    //  round trip.
    function filtered() {
      var out = [];
      for (var i = 0; i < ROWS.length; i++) {
        if (matches(ROWS[i])) out.push(ROWS[i]);
      }
      return out;
    }

    function resetPage() { PAGE = 1; }
```

- [ ] **Step 4: Render a slice, and draw the pager**

Replace the top of `drawRows()` so it walks the page rather than the roll:

```javascript
    function drawRows() {
      var body = el("pu-rows");
      if (!body) return;
      var rows = filtered();
      var pages = Math.max(1, Math.ceil(rows.length / PER));
      if (PAGE > pages) PAGE = pages;
      var from = (PAGE - 1) * PER;
      var page = rows.slice(from, from + PER);
      var out = [];
      for (var i = 0; i < page.length; i++) {
        var r = page[i];
```

(The body of the loop is unchanged; delete the `if (!matches(r)) continue;` line and the `n++`, and close the loop over `page`.)

Replace the count and empty-state block at the bottom with:

```javascript
      body.innerHTML = out.join("");
      var empty = el("pu-empty");
      if (empty) {
        empty.hidden = rows.length > 0;
        empty.textContent = ROWS.length
          ? "No pupil matches that."
          : "There are no pupils on the roll yet.";
      }
      var c = el("pu-count");
      if (c) {
        //  SAY WHICH OF HOW MANY. "137 pupils" while 50 are on screen is a
        //  count somebody has to reconcile in their head.
        c.textContent = rows.length === 0 ? "no pupils"
          : rows.length <= PER
            ? (rows.length === 1 ? "1 pupil" : rows.length + " pupils")
            : "Showing " + (from + 1) + "–" + Math.min(from + PER, rows.length)
              + " of " + rows.length;
      }
      drawPager(rows.length, pages);
    }

    //  THE PAGER. Numbered pages with the current one marked, first and last
    //  always reachable, and an ellipsis rather than 12 buttons.
    function drawPager(total, pages) {
      var hosts = document.querySelectorAll(".pu-pager");
      var h = "";
      if (pages > 1) {
        h += '<div class="pu-pages">';
        h += '<button type="button" class="pu-page" data-page="'
           + (PAGE - 1) + '"' + (PAGE === 1 ? " disabled" : "")
           + ">Back</button>";
        var shown = [], p;
        for (p = 1; p <= pages; p++) {
          if (p === 1 || p === pages || Math.abs(p - PAGE) <= 1) shown.push(p);
        }
        var last = 0;
        for (var i = 0; i < shown.length; i++) {
          p = shown[i];
          if (last && p - last > 1) h += '<span class="pu-gap">…</span>';
          h += '<button type="button" class="pu-page'
             + (p === PAGE ? " is-on" : "") + '" data-page="' + p + '"'
             + (p === PAGE ? ' aria-current="page"' : "") + ">" + p + "</button>";
          last = p;
        }
        h += '<button type="button" class="pu-page" data-page="' + (PAGE + 1)
           + '"' + (PAGE === pages ? " disabled" : "") + ">Next</button></div>";
      }
      h += '<div class="pu-pers"><span>Per page</span>';
      var opts = [25, 50, 100];
      for (var k = 0; k < opts.length; k++) {
        h += '<button type="button" class="pu-per'
           + (PER === opts[k] ? " is-on" : "") + '" data-per="' + opts[k]
           + '">' + opts[k] + "</button>";
      }
      h += "</div>";
      for (var j = 0; j < hosts.length; j++) hosts[j].innerHTML = h;
    }
```

- [ ] **Step 5: Wire the controls, and reset the page on every narrowing**

In `wire()`, change `refilter()` and add the pager delegate:

```javascript
      //  REVIEW FOCUS 1. Narrowing the list while on page 4 leaves the slice
      //  past the end of the result, and the screen says "No pupil matches
      //  that" while twelve do. Every narrowing goes back to page one.
      function refilter() { closeRecord(); resetPage(); drawRows(); }
      if (q) q.addEventListener("input", refilter);
      if (c) c.addEventListener("change", refilter);

      var pagers = document.querySelectorAll(".pu-pager");
      for (var pi = 0; pi < pagers.length; pi++) {
        pagers[pi].addEventListener("click", function (e) {
          var pb = e.target.closest ? e.target.closest(".pu-page") : null;
          var pr = e.target.closest ? e.target.closest(".pu-per") : null;
          if (pb && !pb.disabled) {
            PAGE = parseInt(pb.getAttribute("data-page"), 10) || 1;
            closeRecord(); drawRows();
            var top = el("pu-roll");
            if (top && top.scrollIntoView) top.scrollIntoView({block: "start"});
          } else if (pr) {
            PER = parseInt(pr.getAttribute("data-per"), 10) || 50;
            resetPage(); closeRecord(); drawRows();
          }
        });
      }
```

The figure tiles also narrow the list, so their handler calls `resetPage()` before `drawRows()`.

- [ ] **Step 6: Add the markup and the styles**

In `tools/build_pupils_screen.py`, put `<div class="pu-pager"></div>` immediately above the table and again below it, and give the roll card `id="pu-roll"`.

In `portal/pupils/pupils.css`:

```css
/*  THE PAGER.
    Above and below the table, because a person who has read to the bottom of
    fifty rows should not scroll back up to ask for the next fifty.          */
.pu-pager     { display:flex; flex-wrap:wrap; gap:12px; align-items:center;
                justify-content:space-between; margin:12px 0; }
.pu-pages     { display:flex; gap:4px; align-items:center; flex-wrap:wrap; }
.pu-page      { min-width:36px; min-height:36px; padding:6px 10px;
                border:1px solid var(--line); border-radius:8px;
                background:var(--card); color:var(--ink); cursor:pointer;
                font:inherit; font-size:14px; }
.pu-page:hover:not([disabled]) { border-color:var(--gold-ink); }
.pu-page.is-on{ background:var(--ink); color:var(--card); border-color:var(--ink);
                font-weight:700; }
.pu-page[disabled] { opacity:.4; cursor:default; }
.pu-gap       { padding:0 4px; color:var(--muted); }
.pu-pers      { display:flex; gap:4px; align-items:center;
                color:var(--muted); font-size:13px; }
.pu-per       { min-width:34px; min-height:32px; padding:4px 8px;
                border:1px solid var(--line); border-radius:8px;
                background:var(--card); color:var(--ink); cursor:pointer;
                font:inherit; font-size:13px; }
.pu-per.is-on { background:var(--ink); color:var(--card); border-color:var(--ink); }
```

- [ ] **Step 7: Run the tests**

Run: `python3 tools/build_pupils_screen.py && python3 _test/pupils_test.py`
Expected: PASS, with the new checks counted.

- [ ] **Step 8: Prove the new checks bite**

Temporarily change `resetPage()` to do nothing, rebuild, and re-run. Expected: the Review Focus 1 checks fail. Restore, rebuild, re-run, expect PASS.

- [ ] **Step 9: Commit**

```bash
git add tools/pupils_module.js tools/build_pupils_screen.py portal/pupils/ _test/pupils_test.py
git commit -m "The roll opens in one screen instead of twenty-eight"
```

---

### Task 2: Sticky column headers, and sorting

**Files:**
- Modify: `tools/pupils_module.js` — `SORT`, `SORTDIR`, sorting inside `filtered()`, header click handler
- Modify: `tools/build_pupils_screen.py` — make the sortable headers buttons
- Modify: `portal/pupils/pupils.css` — `.pu-th`, `.pu-sortable`, sticky `thead`
- Test: `_test/pupils_test.py`

**Interfaces:**
- Consumes: `filtered()` from Task 1.
- Produces: `SORT` (one of `"ref"`, `"name"`, `"age"`, `"class"`), `SORTDIR` (`1` ascending, `-1` descending).

- [ ] **Step 1: Write the failing tests**

```python
        # --- sorting -----------------------------------------------------------
        mixed = [
            dict(ROLL[0], id="s1", name="Zahra Test", legacy_ref="9001",
                 date_of_birth="2010-01-01", classes=["Girls Class 1"]),
            dict(ROLL[0], id="s2", name="Adam Test", legacy_ref="9002",
                 date_of_birth="2018-01-01", classes=["Boys Year 1"]),
            #  REVIEW FOCUS 3. No date of birth. A null age must not sort as
            #  though the child were newborn.
            dict(ROLL[0], id="s3", name="Musa Test", legacy_ref="9003",
                 date_of_birth=None, classes=["Boys Year 2A"]),
        ]
        pg = open_page(b, roll=mixed, health=dict(HEALTH, on_roll=3))
        pg.click('.pu-sortable[data-sort="name"]')
        pg.wait_for_timeout(300)
        order = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('tr.pu-row .pu-who'),
            function (n) { return n.innerText.split('\\n')[0].trim(); })""")
        check("sorting by name puts Adam first", order[0].startswith("Adam"), order)
        pg.click('.pu-sortable[data-sort="name"]')
        pg.wait_for_timeout(300)
        order = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('tr.pu-row .pu-who'),
            function (n) { return n.innerText.split('\\n')[0].trim(); })""")
        check("clicking again reverses it", order[0].startswith("Zahra"), order)

        pg.click('.pu-sortable[data-sort="age"]')
        pg.wait_for_timeout(300)
        ages = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('tr.pu-row'),
            function (tr) { return tr.children[2].innerText.trim(); })""")
        check("sorting by age puts the unknown one LAST, not first",
              "not known" in ages[-1], ages)
        pg.click('.pu-sortable[data-sort="age"]')
        pg.wait_for_timeout(300)
        ages = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('tr.pu-row'),
            function (tr) { return tr.children[2].innerText.trim(); })""")
        check("and still last when the order is reversed", "not known" in ages[-1], ages)

        check("the header row is sticky",
              pg.evaluate("""() => getComputedStyle(
                  document.querySelector('#pu-roll thead th')).position""") == "sticky")
        pg.close()
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 _test/pupils_test.py`
Expected: FAIL — `.pu-sortable` does not exist.

- [ ] **Step 3: Sort inside `filtered()`**

```javascript
    var SORT = "";            // "" keeps the server's surname order
    var SORTDIR = 1;          // 1 ascending, -1 descending

    //  UNKNOWN SORTS LAST, BOTH WAYS.
    //  A child with no date of birth has no age, and null compares as less
    //  than every number - so the children the office most needs to chase
    //  float to the top of an ascending sort looking like newborns, and
    //  vanish from the bottom of a descending one. Missing is not small.
    function cmp(a, b) {
      var x, y;
      if (SORT === "age")        { x = age(a.date_of_birth); y = age(b.date_of_birth); }
      else if (SORT === "ref")   { x = a.legacy_ref;  y = b.legacy_ref; }
      else if (SORT === "class") { x = (a.classes || [])[0]; y = (b.classes || [])[0]; }
      else                       { x = a.name;        y = b.name; }
      var xm = (x === null || x === undefined || x === "");
      var ym = (y === null || y === undefined || y === "");
      if (xm && ym) return 0;
      if (xm) return 1;
      if (ym) return -1;
      if (typeof x === "string") return x.localeCompare(y) * SORTDIR;
      return (x < y ? -1 : x > y ? 1 : 0) * SORTDIR;
    }
```

and at the end of `filtered()`, before returning: `if (SORT) out.sort(cmp);`

- [ ] **Step 4: Make the headers buttons and wire them**

In the generator, each sortable header becomes:

```html
<th><button type="button" class="pu-sortable" data-sort="ref">Reference</button></th>
```

for `ref`, `name`, `age` and `class`; Teacher, Family and To read stay plain `<th>`.

In `wire()`:

```javascript
      var head = document.querySelector("#pu-roll thead");
      if (head) head.addEventListener("click", function (e) {
        var b = e.target.closest ? e.target.closest(".pu-sortable") : null;
        if (!b) return;
        var k = b.getAttribute("data-sort");
        if (SORT === k) { SORTDIR = -SORTDIR; } else { SORT = k; SORTDIR = 1; }
        //  Sorting reorders the whole result, so the page you were on no
        //  longer means anything.
        resetPage(); closeRecord(); drawRows(); markSort();
      });

    function markSort() {
      var bs = document.querySelectorAll(".pu-sortable");
      for (var i = 0; i < bs.length; i++) {
        var on = bs[i].getAttribute("data-sort") === SORT;
        bs[i].setAttribute("aria-sort",
          on ? (SORTDIR === 1 ? "ascending" : "descending") : "none");
        bs[i].className = "pu-sortable" + (on ? " is-on" : "");
      }
    }
```

- [ ] **Step 5: Style the header, and make it stick**

```css
/*  THE HEADER STAYS PUT.
    Measured at 552 rows: by row 300 the headings had scrolled away entirely
    and nothing on screen said which column held the class and which the
    teacher. Sticky costs one line and fixes the worst of it.               */
#pu-roll thead th { position:sticky; top:0; z-index:2;
                    background:var(--card); box-shadow:0 1px 0 var(--line); }
.pu-sortable  { background:none; border:0; padding:0; font:inherit;
                color:inherit; cursor:pointer; display:inline-flex;
                align-items:center; gap:4px; }
.pu-sortable::after { content:"↕"; opacity:.35; font-size:11px; }
.pu-sortable.is-on::after { content:"↑"; opacity:1; }
.pu-sortable.is-on[aria-sort="descending"]::after { content:"↓"; }
.pu-sortable:hover { color:var(--gold-ink); }
```

- [ ] **Step 6: Run the tests**

Run: `python3 tools/build_pupils_screen.py && python3 _test/pupils_test.py`
Expected: PASS.

- [ ] **Step 7: Prove the null-age check bites**

Temporarily change `cmp` so `xm` returns `-1` instead of `1`, rebuild, re-run. Expected: both "unknown last" checks fail. Restore and re-run.

- [ ] **Step 8: Commit**

```bash
git add tools/pupils_module.js tools/build_pupils_screen.py portal/pupils/ _test/pupils_test.py
git commit -m "The headings stay put, and the columns sort"
```

---

### Task 3: Filters — teacher, and boys or girls

**Files:**
- Modify: `tools/pupils_module.js` — `matches()` gains teacher and gender; teacher list built from the roll
- Modify: `tools/build_pupils_screen.py` — the two controls
- Modify: `portal/pupils/pupils.css` — `.pu-side`
- Test: `_test/pupils_test.py`

**Interfaces:**
- Consumes: `filtered()`, `resetPage()` from Task 1.
- Produces: `SIDE` (`""` | `"male"` | `"female"`) and a `#pu-teacher` select whose options come from the roll's distinct `teacher` values.

- [ ] **Step 1: Write the failing tests**

```python
        # --- boys and girls ----------------------------------------------------
        #  REVIEW FOCUS 2. One real pupil has no gender recorded. 236 + 315 is
        #  551, not 552, and a filter must never make that child unreachable.
        sides = [
            dict(ROLL[0], id="g1", name="Boy One",  gender="male",   teacher="Apa A"),
            dict(ROLL[0], id="g2", name="Girl One", gender="female", teacher="Apa B"),
            dict(ROLL[0], id="g3", name="No Gender", gender=None,    teacher="Apa B"),
        ]
        pg = open_page(b, roll=sides, health=dict(HEALTH, on_roll=3))
        check("everyone is shown to begin with", pg.locator("tr.pu-row").count() == 3)
        pg.select_option("#pu-side", "male")
        pg.wait_for_timeout(300)
        check("boys only shows the boy", pg.locator("tr.pu-row").count() == 1)
        pg.select_option("#pu-side", "female")
        pg.wait_for_timeout(300)
        check("girls only shows the girl", pg.locator("tr.pu-row").count() == 1)
        check("and the count says which of how many, so the missing one shows",
              "of 3" in pg.inner_text("#pu-count"), pg.inner_text("#pu-count"))
        pg.select_option("#pu-side", "")
        pg.wait_for_timeout(300)
        check("everyone brings back all three, including the one with no gender",
              pg.locator("tr.pu-row").count() == 3)

        # --- teacher -----------------------------------------------------------
        pg.select_option("#pu-teacher", "Apa B")
        pg.wait_for_timeout(300)
        check("the teacher filter narrows to that teacher's pupils",
              pg.locator("tr.pu-row").count() == 2)
        check("the teacher list is built from the roll, not hard-coded",
              pg.locator("#pu-teacher option").count() == 3)
        pg.close()
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 _test/pupils_test.py`
Expected: FAIL — `#pu-side` does not exist.

- [ ] **Step 3: Extend `matches()`**

```javascript
      var side = el("pu-side") ? el("pu-side").value : "";
      var tchr = el("pu-teacher") ? el("pu-teacher").value : "";
      //  ON THE CHILD'S OWN RECORD, not the class's side. A pupil with no
      //  gender recorded belongs to neither Boys nor Girls and appears only
      //  under Everyone - which is why Everyone is the default and the count
      //  always says "of 552".
      if (side && r.gender !== side) return false;
      if (tchr && r.teacher !== tchr) return false;
```

- [ ] **Step 4: Build the teacher list from the roll**

In `load()`, after `ROWS` is set:

```javascript
        //  The teachers are whoever is actually teaching somebody on this
        //  roll. A hard-coded list goes stale the day a teacher leaves.
        var seen = {}, names = [];
        for (var t = 0; t < ROWS.length; t++) {
          var nm = ROWS[t].teacher;
          if (nm && !seen[nm]) { seen[nm] = 1; names.push(nm); }
        }
        names.sort();
        var tsel = el("pu-teacher");
        if (tsel && tsel.options.length <= 1) {
          for (var u = 0; u < names.length; u++) {
            var to = document.createElement("option");
            to.value = names[u]; to.textContent = names[u];
            tsel.appendChild(to);
          }
        }
```

- [ ] **Step 5: Add the controls**

In the generator, beside the class select:

```html
<select id="pu-side" aria-label="Boys or girls">
  <option value="">Everyone</option>
  <option value="male">Boys</option>
  <option value="female">Girls</option>
</select>
<select id="pu-teacher" aria-label="Teacher">
  <option value="">Any teacher</option>
</select>
```

Wire both to `refilter` in `wire()`.

- [ ] **Step 6: Run the tests**

Run: `python3 tools/build_pupils_screen.py && python3 _test/pupils_test.py`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add tools/pupils_module.js tools/build_pupils_screen.py portal/pupils/ _test/pupils_test.py
git commit -m "Filter by teacher, and by boys or girls without losing anybody"
```

---

### Task 4: A per-row Actions menu with nothing dead in it

**Files:**
- Modify: `tools/pupils_module.js` — the Actions cell, `MENU`, `closeMenu()`, the delegate
- Modify: `tools/build_pupils_screen.py` — the Actions column header
- Modify: `portal/pupils/pupils.css` — `.pu-acts`, `.pu-act`, `.pu-menu`
- Test: `_test/pupils_test.py`

**Interfaces:**
- Consumes: `filtered()`, `resetPage()`, `drawRows()`.
- Produces: `MENU` (the open row's id, or `null`), `closeMenu()`.

- [ ] **Step 1: Write the failing tests**

```python
        # --- the actions menu --------------------------------------------------
        pg = open_page(b)
        check("every row has an actions button",
              pg.locator(".pu-act").count() == pg.locator("tr.pu-row").count())
        pg.locator(".pu-act").first.click()
        pg.wait_for_timeout(300)
        check("the menu opens", pg.locator(".pu-menu").count() == 1)

        #  REVIEW FOCUS 4. The button lives inside a <tr> that opens the child
        #  on click. Without stopPropagation, opening the menu ALSO opens the
        #  record - and opening a record writes an audit row, so the mistake
        #  is recorded every time.
        check("opening the menu does NOT open the record",
              pg.locator("#pu-record").is_hidden())
        calls = pg.evaluate("() => window.__calls.map(function(c){return c.name;})")
        check("and does not call madrasah_pupil_one",
              "madrasah_pupil_one" not in calls, calls)

        items = pg.evaluate("""() => Array.prototype.map.call(
            document.querySelectorAll('.pu-menu a, .pu-menu button'),
            function (n) { return {t: n.innerText.trim(),
                                   dead: n.hasAttribute('disabled')
                                      || n.getAttribute('href') === '#'
                                      || n.className.indexOf('soon') !== -1}; })""")
        check("the menu has entries", len(items) >= 4, items)
        check("and NOT ONE of them is dead",
              all(not i["dead"] for i in items), items)
        check("Register and Incidents are absent, because they are not built",
              not any(i["t"] in ("Register", "Incidents", "Class History",
                                 "Portal Login") for i in items), items)

        #  REVIEW FOCUS 5. A menu left open across a page change points at a
        #  pupil who is no longer on screen.
        pg.close()
        many = [dict(ROLL[0], id="y%d" % i, name="Pupil %d" % i,
                     legacy_ref=str(3000 + i)) for i in range(80)]
        pg = open_page(b, roll=many, health=dict(HEALTH, on_roll=80))
        pg.locator(".pu-act").first.click()
        pg.wait_for_timeout(200)
        check("a menu is open", pg.locator(".pu-menu").count() == 1)
        pg.locator('.pu-page[data-page="2"]').first.click()
        pg.wait_for_timeout(300)
        check("changing page closes it", pg.locator(".pu-menu").count() == 0)
        pg.close()
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 _test/pupils_test.py`
Expected: FAIL — `.pu-act` does not exist.

- [ ] **Step 3: Draw the cell**

At the end of each row in `drawRows()`, after the flags cell:

```javascript
          + '<td class="pu-acts">'
          + '<button type="button" class="pu-act" aria-haspopup="true"'
          + ' aria-expanded="' + (MENU === r.id ? "true" : "false") + '">'
          + 'Actions</button>'
          + (MENU === r.id ? menuFor(r) : "") + "</td></tr>");
```

and:

```javascript
    var MENU = null;          // the row whose actions menu is open, or null

    //  ONLY WHAT EXISTS.
    //  The system this replaces offers nine actions. Four of them - Register,
    //  Incidents, Class History and Portal Login - are `soon: true` in the
    //  rail or do not exist at all, and four dead entries repeated down 552
    //  rows teaches people not to open the menu. They arrive when their
    //  screens do, which is the rule nav.js already states for the rail.
    function menuFor(r) {
      var fam = r.family
        ? '<a class="pu-mi" href="../fees/families/">Family &amp; fees</a>' : "";
      return '<div class="pu-menu" role="menu">'
        + '<button type="button" class="pu-mi" data-do="open">Open record</button>'
        + '<button type="button" class="pu-mi" data-do="edit">Amend details</button>'
        + '<a class="pu-mi" href="../fees/">Fees</a>'
        + fam
        + '<button type="button" class="pu-mi" data-do="archive">Archive</button>'
        + "</div>";
    }

    function closeMenu() { if (MENU) { MENU = null; return true; } return false; }
```

- [ ] **Step 4: Handle the clicks, without letting them reach the row**

In `wire()`, inside the existing `#pu-rows` click handler, before anything else:

```javascript
        //  REVIEW FOCUS 4. The button is inside the row, and the row opens a
        //  child. Stop here or every menu click also opens a record - and
        //  madrasah_pupil_one() writes an audit row, so the wrong thing is
        //  written down as well as shown.
        var act = e.target.closest ? e.target.closest(".pu-act") : null;
        if (act) {
          e.stopPropagation(); e.preventDefault();
          var tr = act.closest("tr.pu-row");
          var id = tr ? tr.getAttribute("data-id") : null;
          MENU = (MENU === id) ? null : id;
          drawRows();
          return;
        }
        var mi = e.target.closest ? e.target.closest(".pu-mi") : null;
        if (mi) {
          e.stopPropagation();
          var what = mi.getAttribute("data-do");
          var rid = MENU;
          if (!what) return;            // a real link; let it navigate
          e.preventDefault();
          MENU = null;
          if (what === "open")    { openRecord(rid); }
          else if (what === "edit")    { openRecord(rid, true); }
          else if (what === "archive") { askArchive(rid); }
          return;
        }
```

`drawPager`'s handler and `refilter()` both call `closeMenu()` before `drawRows()`.

- [ ] **Step 5: Style it**

```css
/*  THE ACTIONS MENU.
    Anchored to its own cell so it cannot be clipped by the table's overflow,
    and drawn above the sticky header's z-index.                            */
.pu-acts      { position:relative; white-space:nowrap; }
.pu-act       { min-height:34px; padding:5px 10px; font:inherit; font-size:13px;
                border:1px solid var(--line); border-radius:8px;
                background:var(--card); color:var(--ink); cursor:pointer; }
.pu-act:hover { border-color:var(--gold-ink); }
.pu-menu      { position:absolute; right:0; top:100%; z-index:5; min-width:170px;
                display:flex; flex-direction:column; padding:4px;
                background:var(--card); border:1px solid var(--line);
                border-radius:10px; box-shadow:0 6px 20px rgba(0,0,0,.14); }
.pu-mi        { display:block; width:100%; text-align:left; font:inherit;
                font-size:14px; padding:8px 10px; border:0; border-radius:6px;
                background:none; color:var(--ink); cursor:pointer;
                text-decoration:none; }
.pu-mi:hover  { background:var(--line); }
```

- [ ] **Step 6: Run the tests**

Run: `python3 tools/build_pupils_screen.py && python3 _test/pupils_test.py`
Expected: PASS.

- [ ] **Step 7: Prove the propagation check bites**

Remove the `e.stopPropagation()` from the `.pu-act` branch, rebuild, re-run. Expected: "opening the menu does NOT open the record" fails. Restore and re-run.

- [ ] **Step 8: Commit**

```bash
git add tools/pupils_module.js tools/build_pupils_screen.py portal/pupils/ _test/pupils_test.py
git commit -m "An actions menu with nothing dead in it"
```

---

### Task 5: The sibling panel becomes one line, and the phone gets its pupils back

**Files:**
- Modify: `tools/pupils_module.js` — `drawSuggestions()` renders a line that expands
- Modify: `portal/pupils/pupils.css` — `.pu-sugg-line`, the phone figure strip
- Test: `_test/pupils_test.py`

**Interfaces:** Consumes `SUGG` (unchanged shape).

- [ ] **Step 1: Write the failing tests**

```python
        # --- the sibling line --------------------------------------------------
        pairs = {"allowed": True, "rows": [
            dict(SUGG["rows"][0], id="s%d" % i) for i in range(56)]}
        pg = open_page(b, sugg=pairs)
        check("56 pairs draw ONE line, not 56 rows",
              pg.locator(".pu-sugg-row").count() == 0)
        check("and the line says how many",
              "56" in pg.inner_text(".pu-sugg-line"))
        pg.locator(".pu-sugg-line button").first.click()
        pg.wait_for_timeout(300)
        check("opening it shows the pairs",
              pg.locator(".pu-sugg-row").count() == 56)
        pg.close()

        # --- the phone's first screen ------------------------------------------
        pg = open_page(b, width=390, height=900)
        first = pg.evaluate("""() => {
            var r = document.querySelector('tr.pu-row');
            if (!r) return null;
            var b = r.getBoundingClientRect();
            return b.top; }""")
        check("a pupil is on the phone's FIRST screen, not three screens down",
              first is not None and first < 900, first)
        pg.close()
```

- [ ] **Step 2: Run to verify it fails**

Run: `python3 _test/pupils_test.py`
Expected: FAIL — `.pu-sugg-line` does not exist, and the first row sits far below 900px.

- [ ] **Step 3: Collapse the panel**

```javascript
    var SUGGOPEN = false;

    //  ONE LINE, NOT FIFTY-SIX ROWS.
    //  The fixture holds one pair and the madrasah holds 56, so this panel
    //  rendered three screens of review work above the roll and nothing in
    //  the suite could see it. The finding is not thrown away - deleting it
    //  would leave 56 pairs in the database with nothing showing them, and
    //  families drive sibling discounts - it is one line until asked for.
    //  It points at Families when that screen exists.
    function drawSuggestions() {
      var host = el("pu-sugg");
      if (!host) return;
      if (!SUGG.length) { host.hidden = true; host.innerHTML = ""; return; }
      host.hidden = false;
      var h = '<p class="pu-sugg-line">'
        + (SUGG.length === 1
            ? "One pair of children might be siblings. "
            : SUGG.length + " pairs of children might be siblings. ")
        + '<button type="button" class="pu-linkish">'
        + (SUGGOPEN ? "Hide" : "Review") + "</button></p>";
      if (SUGGOPEN) { h += '<div class="pu-sugg-rows">' + suggRows() + "</div>"; }
      host.innerHTML = h;
    }
```

`suggRows()` is the existing loop body, unchanged, returning the string.

- [ ] **Step 4: Give the phone its pupils back**

```css
/*  THE PHONE'S FIRST SCREEN HELD NO PUPIL.
    Measured: heading, seven figure tiles stacked two-across, then the
    sibling panel - a teacher in a corridor scrolled past all of it before
    reaching a child. On a phone the figures become one swipeable row.      */
@media (max-width: 720px) {
  .pu-figs    { display:flex; overflow-x:auto; gap:10px; padding-bottom:6px;
                scroll-snap-type:x mandatory; -webkit-overflow-scrolling:touch; }
  .pu-fig     { flex:0 0 auto; min-width:132px; scroll-snap-align:start; }
  .pu-head-t p { display:none; }
}
.pu-sugg-line { margin:0; }
.pu-linkish   { background:none; border:0; padding:0; font:inherit;
                color:var(--gold-ink); text-decoration:underline;
                cursor:pointer; }
```

- [ ] **Step 5: Run the tests**

Run: `python3 tools/build_pupils_screen.py && python3 _test/pupils_test.py`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add tools/pupils_module.js portal/pupils/ _test/pupils_test.py
git commit -m "One line for the sibling pairs, and a phone that opens on pupils"
```

---

### Task 6: Verify against 552 rows

- [ ] **Step 1: Run every suite**

```bash
python3 - <<'PY'
import subprocess, glob, sys
tests=[t for t in sorted(glob.glob("_test/*.py"))
       if not any(k in t for k in ("_shots","perf_measure","measure_test"))]
bad=[]
for t in tests:
    r=subprocess.run([sys.executable,t],capture_output=True,text=True,timeout=600)
    o=r.stdout+r.stderr
    if r.returncode!=0 or ("FAIL" in o and "FAILURES: 0" not in o): bad.append(t)
print("%d suites, %d not clean" % (len(tests), len(bad)))
for t in bad: print("  "+t)
PY
```

Expected: `0 not clean`.

- [ ] **Step 2: Measure the scroll depth**

Run: `python3 _test/pupils_shots.py /tmp/claude-0/after`
Expected: desk and phone both around **1 screen**, down from 28.6 and 37.9.

- [ ] **Step 3: Look at the pictures**

Read the desk and phone first-screen images. Three times this month a screenshot has found what the tests could not.

- [ ] **Step 4: Commit and hand over**

---

## Self-review

**Spec coverage.** Pagination, page size, count line — Task 1. Sticky headers and sorting — Task 2. Class, teacher and boys/girls filters — Task 3 (class already existed). Actions menu with only live entries — Task 4. Sibling line and phone figure strip — Task 5. Status filter, export and the pupil page are parts two and three of the spec, deliberately not here.

**Placeholders.** None: every step carries the code.

**Type consistency.** `filtered()` returns an Array in all four tasks that use it; `resetPage()`, `closeMenu()` and `closeRecord()` are called with no arguments everywhere; `MENU` holds a row id string or null throughout.

**Review Focus.** All five have a test in the task that owns the code: page reset (1), the genderless pupil (3), null ages sorting last (2), stopPropagation (4), menu closed on page change (4). Three of the five also have an explicit "prove it bites" step.
