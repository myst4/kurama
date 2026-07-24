#!/usr/bin/env node
// gen-braille.mjs — deterministic 1-bit ASCII grid → Unicode Braille raster.
//
// The banner art (assets/banner/fox.txt) is a single-color Braille raster in the
// U+2800–U+28FF block. Each Braille glyph packs a 2-wide × 4-tall dot matrix — the
// densest monochrome "pixel" cell a monospace terminal offers. Authoring 8 dots
// per glyph by hand is error-prone, so the fox is drawn as a plain 1-bit
// silhouette in assets/banner/fox-grid.txt ('#' = ink, everything else = blank)
// which a human can read and edit at a glance, and THIS script packs that grid
// into Braille rows.
//
// Dot-bit layout inside one cell (Unicode Braille numbering 1..8):
//     (col0,row0)=0x01   (col1,row0)=0x08
//     (col0,row1)=0x02   (col1,row1)=0x10
//     (col0,row2)=0x04   (col1,row2)=0x20
//     (col0,row3)=0x40   (col1,row3)=0x80
//   codepoint = 0x2800 + bits.  bits == 0 → a plain space (keeps leading/interior
//   blanks trimmable and centering cheap, exactly like gentle's rose array).
//
// Usage:
//   node scripts/gen-braille.mjs                 # fox-grid.txt → fox.txt (defaults)
//   node scripts/gen-braille.mjs in.txt          # in.txt → stdout
//   node scripts/gen-braille.mjs in.txt out.txt  # in.txt → out.txt
//   node scripts/gen-braille.mjs --check         # regenerate defaults in memory and
//                                                # fail (exit 3) if fox.txt is stale
//
// Zero dependencies (node builtins only); fully deterministic.

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..");
const DEFAULT_IN = join(REPO, "assets", "banner", "fox-grid.txt");
const DEFAULT_OUT = join(REPO, "assets", "banner", "fox.txt");

// A grid cell is "ink" when it is one of these glyphs; every other character
// (space, '.', '-', etc.) is treated as blank. '#' is the canonical ink glyph;
// the others are accepted so a grid can use '.' as a visible background.
const INK = new Set(["#", "*", "@", "o", "O", "X"]);

// Per-cell dot bit for a (dotCol, dotRow) offset, dotCol ∈ {0,1}, dotRow ∈ {0..3}.
const DOT_BITS = [
  [0x01, 0x02, 0x04, 0x40], // col 0, rows 0..3
  [0x08, 0x10, 0x20, 0x80], // col 1, rows 0..3
];

function gridToBraille(text) {
  // Split into lines, drop a single trailing newline's empty tail, and strip CRs.
  const rows = text.replace(/\r/g, "").replace(/\n$/, "").split("\n");
  const width = rows.reduce((m, r) => Math.max(m, r.length), 0);

  const ink = (gx, gy) => {
    const row = rows[gy];
    if (row === undefined) return false;
    const ch = row[gx];
    return ch !== undefined && INK.has(ch);
  };

  const cellCols = Math.ceil(width / 2);
  const cellRows = Math.ceil(rows.length / 4);
  const out = [];

  for (let cy = 0; cy < cellRows; cy++) {
    let line = "";
    for (let cx = 0; cx < cellCols; cx++) {
      let bits = 0;
      for (let dc = 0; dc < 2; dc++) {
        for (let dr = 0; dr < 4; dr++) {
          if (ink(cx * 2 + dc, cy * 4 + dr)) bits |= DOT_BITS[dc][dr];
        }
      }
      line += bits === 0 ? " " : String.fromCodePoint(0x2800 + bits);
    }
    out.push(line.replace(/\s+$/g, ""));
  }
  // Trim leading/trailing all-blank rows so the raster is tight.
  while (out.length && out[0].trim() === "") out.shift();
  while (out.length && out[out.length - 1].trim() === "") out.pop();
  return out.join("\n") + "\n";
}

function main(argv) {
  const args = argv.slice(2);
  const check = args.includes("--check");
  const positional = args.filter((a) => !a.startsWith("--"));

  if (check) {
    const generated = gridToBraille(readFileSync(DEFAULT_IN, "utf8"));
    let current = "";
    try {
      current = readFileSync(DEFAULT_OUT, "utf8");
    } catch {
      current = "";
    }
    if (generated !== current) {
      process.stderr.write(
        `fox.txt is stale — run: node scripts/gen-braille.mjs\n`,
      );
      process.exit(3);
    }
    process.stderr.write("fox.txt is up to date.\n");
    return;
  }

  const inPath = positional[0] ?? DEFAULT_IN;
  const braille = gridToBraille(readFileSync(inPath, "utf8"));

  // With no positional args at all, write the committed default; otherwise honor
  // an explicit out path, else print to stdout.
  const outPath =
    positional.length === 0 ? DEFAULT_OUT : positional[1];
  if (outPath) {
    writeFileSync(outPath, braille);
    process.stderr.write(`wrote ${outPath}\n`);
  } else {
    process.stdout.write(braille);
  }
}

main(process.argv);
