/**
 * Renders docs/diagrams/*.mmd to the SVGs the README embeds.
 *
 * Why files rather than ```mermaid fences in the README: GitHub renders mermaid
 * but cannot animate it, and these connectors carry a travelling dash so you
 * can see which way the information actually moves. The .mmd sources stay in
 * the repository so a diagram is still text somebody can edit and diff, rather
 * than a picture nobody can change.
 *
 *   node tools/build_diagrams.mjs
 *
 * Needs a Chromium for mermaid-cli. With none on the machine, mermaid-cli
 * fetches its own; with one already there, point at it:
 *
 *   PUPPETEER_EXECUTABLE_PATH=/path/to/chrome node tools/build_diagrams.mjs
 *
 * MMDC overrides how mermaid-cli is run (default: npx -y @mermaid-js/mermaid-cli),
 * for a machine that has it installed already and no wish to re-resolve it.
 */
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const SRC = "docs/diagrams";

/**
 * The masjid's own palette — the plum and gold of the site's own CSS, as CSS custom
 * properties inside the SVG. Declared light-first on :root and redefined under
 * prefers-color-scheme: an SVG loaded through <img> still honours the host
 * page's colour scheme, so the diagrams follow GitHub's theme instead of
 * glowing white in a dark one.
 */
const STYLE = `
  :root {
    --paper:#F5F1E8; --paper-2:#EDE7DD; --ink:#261B22; --ink-2:#6E616A;
    --board:#3C0B2A; --board-ink:#F5F1E8;
    --rule:#C9BFB2; --brass:#7A5D14; --brass-2:#C6A24C;
    --ok:#3F7A46; --wait:#8A6A18;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --paper:#1E0715; --paper-2:#2A0E1F; --ink:#F3EFE3; --ink-2:#BBA9B4;
      --board:#14040E; --board-ink:#F5F1E8;
      --rule:#5E1844; --brass:#C6A24C; --brass-2:#DCBB63;
      --ok:#7FC49B; --wait:#D8B266;
    }
  }

  svg { background: var(--paper); }
  .cluster rect { fill: var(--paper-2) !important; stroke: var(--rule) !important; }
  .cluster-label .nodeLabel, .cluster span { fill: var(--ink-2) !important; color: var(--ink-2) !important; }
  .edgeLabel .labelBkg, .edgeLabel rect { fill: var(--paper) !important; }
  .edgeLabel, .edgeLabel * {
    color: var(--ink-2) !important; fill: var(--ink-2) !important;
    background: transparent !important; font-size: 12px !important;
  }
  .edgeLabel .labelBkg { fill: var(--paper) !important; }
  /* NO font-family override here. Mermaid measures every label and sizes each
     box BEFORE this stylesheet is appended, so changing the face afterwards
     reflows text inside boxes built for a different font and silently clips
     the last line. Mermaid embeds the face it measured with — leave it be. */

  /* The travelling dash. One rule, every connector. */
  .flowchart-link {
    stroke: var(--brass-2) !important;
    stroke-width: 1.6px !important;
    stroke-dasharray: 10 8 !important;
    animation: tm-flow 1.15s linear infinite;
  }
  @keyframes tm-flow { from { stroke-dashoffset: 18; } to { stroke-dashoffset: 0; } }
  .arrowMarkerPath { fill: var(--brass-2) !important; stroke: var(--brass-2) !important; }

  /* Somebody who has asked their machine for less movement gets a still
     picture rather than a stuttering one. */
  @media (prefers-reduced-motion: reduce) {
    .flowchart-link { animation: none; stroke-dasharray: none !important; }
  }
`;

const files = readdirSync(SRC).filter((f) => f.endsWith(".mmd")).sort();
if (!files.length) throw new Error(`No .mmd files in ${SRC}`);

const work = mkdtempSync(join(tmpdir(), "mmd-"));
const cfg = join(work, "puppeteer.json");
writeFileSync(cfg, JSON.stringify({ args: ["--no-sandbox", "--disable-dev-shm-usage"] }));

/* Mermaid re-wraps a label at 200px by default, which breaks the lines the
   .mmd author already chose and leaves tall, narrow boxes of three-word rows.
   Widening it lets the <br/> in the source be the line break it looks like.
   This is applied during measurement, so unlike a font swap it is safe. */
const mcfg = join(work, "mermaid.json");
writeFileSync(mcfg, JSON.stringify({
  flowchart: { wrappingWidth: 560, padding: 12, nodeSpacing: 46, rankSpacing: 58 },
}));

const runner = (process.env.MMDC || "npx -y @mermaid-js/mermaid-cli").split(" ");

for (const file of files) {
  const out = join(SRC, file.replace(/\.mmd$/, ".svg"));
  execFileSync(runner[0], [...runner.slice(1), "-i", join(SRC, file), "-o", out,
                           "-p", cfg, "-c", mcfg, "-b", "transparent", "-q"],
               { stdio: "inherit" });

  // mermaid emits exactly one <style> block; append rather than replace, so its
  // own layout rules survive.
  let svg = readFileSync(out, "utf8");
  const at = svg.indexOf("</style>");
  if (at === -1) throw new Error(`No <style> block in ${out} — mermaid output changed`);
  svg = svg.slice(0, at) + STYLE + svg.slice(at);
  writeFileSync(out, svg);
  console.log(`${out}  ${(svg.length / 1024).toFixed(1)} kB`);
}
