#!/usr/bin/env node
// gen-logo-plugin.mjs — banner wordmark → startup logo plugin, one per harness.
//
// assets/banner/wordmark.txt is the single source of the Kurama wordmark: the
// same art scripts/banner.sh prints. This script compiles it into the two agent
// plugins that draw it at startup, so the terminal banner and the agents can
// never drift apart or be transcribed by hand.
//
//   opencode → examples/opencode/tui-plugins/kurama-logo.tsx
//   pi       → examples/pi/extensions/kurama-logo.ts
//
// Two harnesses, two very different contracts for the same art:
//
//   opencode: the TUI is a SolidJS app on @opentui. Its host declares a
//     `home_logo` slot with mode:"replace", so a plugin registering that slot
//     SUBSTITUTES the default logo instead of stacking beneath it. Each <text>
//     element carries exactly ONE `fg` colour, so a row mixing solid glyphs with
//     the bevel shadow (`▒`) cannot be a single <text>: every row is pre-split
//     into RUNS of consecutive same-colour characters, rendered as a row box of
//     one <text> per run.
//
//   pi: extensions are auto-discovered from ~/.pi/agent/extensions/*.ts — no npm
//     package, no settings.json entry. The header contract is
//     ctx.ui.setHeader(() => ({ render(width): string[] })), i.e. plain strings
//     carrying raw ANSI, so each row is pre-rendered into ONE truecolor string
//     the same way banner.sh emits colour.
//
// ANSI trap (cost one debugging round, do not undo): the escape strings must
// carry the REAL ESC byte (0x1b) at generation time — hence ESC below is the
// JS escape \u001b, which the runtime turns into that byte — and JSON.stringify
// then re-escapes it into the six-character \u001b sequence the emitted file
// stores, which TypeScript parses back into ESC. Assembling the sequence from a
// literal backslash instead makes Pi print the escapes on screen as plain text.
//
// Colours mirror scripts/banner.sh:34-37 (FRESH 255,160,90 / DIM 90,45,15).
// Every glyph in the wordmark (█ ▀ ▄ ▒ and space) is single-column and BMP, so
// String.length equals the display width and padEnd() aligns the rows.
//
// Usage:
//   node scripts/gen-logo-plugin.mjs                            # write BOTH committed artifacts
//   node scripts/gen-logo-plugin.mjs --check                    # verify BOTH, exit 3 if stale
//   node scripts/gen-logo-plugin.mjs --target=pi in.txt out.ts  # explicit one-off
//   node scripts/gen-logo-plugin.mjs --target=pi in.txt         # → stdout
//
// Zero dependencies (node builtins only); fully deterministic.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..");
const DEFAULT_IN = join(REPO, "assets", "banner", "wordmark.txt");

// The bevel shadow glyph. Everything else renders in the solid colour.
const SHADOW_GLYPH = "▒";

// Same palette as scripts/banner.sh, in the notation each harness wants.
const SOLID_HEX = "#ffa05a";
const SHADOW_HEX = "#5a2d0f";
const SOLID_RGB = "255;160;90";
const SHADOW_RGB = "90;45;15";
const COMPACT = "✦ KURAMA ✦";

// A real ESC byte — see the ANSI trap note above.
const ESC = "\u001b";

// Split one line into runs of consecutive same-colour characters. Spaces join
// whichever run precedes them: with no bg set, a space's fg paints nothing.
function toRuns(line) {
  const out = [];
  for (const ch of line) {
    const shadow = ch === SHADOW_GLYPH;
    const last = out[out.length - 1];
    if (last && last.s === shadow) last.t += ch;
    else out.push({ t: ch, s: shadow });
  }
  return out;
}

// Parse the wordmark once into the shape both emitters consume.
function parseWordmark(text) {
  const raw = text.replace(/\r/g, "").replace(/\n+$/, "");
  const lines = raw.split("\n").map((l) => l.replace(/\s+$/, ""));
  const width = lines.reduce((m, l) => Math.max(m, l.length), 0);
  const padded = lines.map((l) => l.padEnd(width, " "));
  return { width, padded, rows: padded.map(toRuns) };
}

function emitOpencode({ width, rows }) {
  return `// @ts-nocheck
/** @jsxImportSource @opentui/solid */
// kurama-logo — replaces OpenCode's splash logo with the Kurama wordmark.
//
// GENERATED FILE — edit assets/banner/wordmark.txt, then run
// \`node scripts/gen-logo-plugin.mjs\`. Never hand-edit the art below.
//
// The TUI host declares the \`home_logo\` slot with mode:"replace", so registering
// it substitutes the default logo rather than stacking under it. Note the host
// does NOT pick a single winner: if a second plugin also registers \`home_logo\`,
// both logos render. Install one logo plugin at a time.
import type { TuiPlugin } from "@opencode-ai/plugin/tui"
import { useTerminalDimensions } from "@opentui/solid"
import { createMemo } from "solid-js"

const id = "kurama-logo"

// Same palette as scripts/banner.sh: FRESH 255,160,90 / DIM 90,45,15.
const SOLID = "${SOLID_HEX}"
const SHADOW = "${SHADOW_HEX}"

const WIDTH = ${width}
const HEIGHT = ${rows.length}

// One entry per wordmark row: a list of colour runs, { t: text, s: shadow }.
const ROWS: { t: string; s: boolean }[][] = ${JSON.stringify(rows)}

const COMPACT = "${COMPACT}"

const Logo = () => {
  const dim = useTerminalDimensions()
  // The full wordmark only fits when the terminal can hold it; below that we
  // degrade to a single line instead of breaking the prompt layout.
  const full = createMemo(() => {
    const t = dim()
    return t.width >= WIDTH + 4 && t.height >= HEIGHT + 8
  })

  return (
    <box flexDirection="column" alignItems="center">
      {full()
        ? ROWS.map((row) => (
            <box flexDirection="row">
              {row.map((r) => (
                <text fg={r.s ? SHADOW : SOLID} selectable={false}>
                  {r.t}
                </text>
              ))}
            </box>
          ))
        : <text fg={SOLID} selectable={false}>{COMPACT}</text>}
    </box>
  )
}

const tui: TuiPlugin = async (api) => {
  api.slots.register({
    id,
    order: 100,
    slots: {
      home_logo() {
        return <Logo />
      },
    },
  })
}

const plugin = { id, tui }
export default plugin
`;
}

function emitPi({ width, padded, rows }) {
  // Pre-render every row as ONE truecolor string: Pi's header contract is
  // render(width) => string[], plain text carrying raw ANSI.
  const ansiRows = padded.map((line) =>
    toRuns(line)
      .map((r) => `${ESC}[38;2;${r.s ? SHADOW_RGB : SOLID_RGB}m${r.t}${ESC}[39m`)
      .join(""),
  );
  const compactAnsi = `${ESC}[38;2;${SOLID_RGB}m${COMPACT}${ESC}[39m`;

  return `// kurama-logo — Kurama wordmark as the Pi startup header.
//
// Generated from assets/banner/wordmark.txt by scripts/gen-logo-plugin.mjs.
// Do not edit the art by hand — re-run the generator.
//
// Pi auto-discovers extensions in ~/.pi/agent/extensions/*.ts, so this file
// needs no npm package and no entry in settings.json. Unlike the opencode
// plugin, Pi's header contract is render(width) => string[], i.e. plain
// strings carrying raw ANSI — the same truecolor escapes scripts/banner.sh
// emits. Deliberately no imports: keeping this dependency-free means it does
// not care where Pi's own type packages resolve from.

const WIDTH = ${width}
const HEIGHT = ${rows.length}

// Pre-colored rows. Same palette as scripts/banner.sh (fresh 255,160,90 /
// dim 90,45,15), with the bevel shadow (▒) in the dim tone.
const ROWS: string[] = ${JSON.stringify(ansiRows)}

const COMPACT = ${JSON.stringify(compactAnsi)}
const COMPACT_WIDTH = ${[...COMPACT].length}

function center(line: string, lineWidth: number, width: number): string {
  const pad = Math.max(0, Math.floor((width - lineWidth) / 2))
  return " ".repeat(pad) + line
}

export default function (pi: any) {
  pi.on("session_start", async (_event: any, ctx: any) => {
    if (!ctx.hasUI) return

    ctx.ui.setHeader(() => ({
      render(width: number): string[] {
        const rows = process.stdout.rows ?? 0
        // Same degradation ladder as the opencode plugin: full art, one-line
        // fallback, or nothing at all on a cramped terminal.
        if (width >= WIDTH + 4 && rows >= HEIGHT + 8) {
          return ROWS.map((line) => center(line, WIDTH, width))
        }
        if (width >= COMPACT_WIDTH + 4) {
          return [center(COMPACT, COMPACT_WIDTH, width)]
        }
        return []
      },
      invalidate() {},
    }))
  })
}
`;
}

// Every target: its committed artifact and the emitter that builds it.
const TARGETS = {
  opencode: {
    out: join(REPO, "examples", "opencode", "tui-plugins", "kurama-logo.tsx"),
    emit: emitOpencode,
    label: "kurama-logo.tsx",
  },
  pi: {
    out: join(REPO, "examples", "pi", "extensions", "kurama-logo.ts"),
    emit: emitPi,
    label: "kurama-logo.ts",
  },
};

function readIfPresent(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function main(argv) {
  const args = argv.slice(2);
  const check = args.includes("--check");
  const targetArg = args.find((a) => a.startsWith("--target="));
  const target = targetArg ? targetArg.split("=")[1] : "";
  const positional = args.filter((a) => !a.startsWith("--"));

  if (target && !TARGETS[target]) {
    process.stderr.write(
      `gen-logo-plugin: unknown --target '${target}' (use 'opencode' or 'pi')\n`,
    );
    process.exit(2);
  }

  // --check regenerates EVERY committed artifact in memory (both come from the
  // same wordmark, so a single edit can staleify both) and reports all of them.
  if (check) {
    const wm = parseWordmark(readFileSync(DEFAULT_IN, "utf8"));
    const stale = Object.entries(TARGETS)
      .filter(([, t]) => t.emit(wm) !== readIfPresent(t.out))
      .map(([, t]) => t.label);
    if (stale.length > 0) {
      process.stderr.write(
        `${stale.join(" and ")} stale — run: node scripts/gen-logo-plugin.mjs\n`,
      );
      process.exit(3);
    }
    process.stderr.write("kurama-logo.tsx and kurama-logo.ts are up to date.\n");
    return;
  }

  // With no positional args at all, write every committed artifact.
  if (positional.length === 0) {
    const wm = parseWordmark(readFileSync(DEFAULT_IN, "utf8"));
    for (const [name, t] of Object.entries(TARGETS)) {
      if (target && target !== name) continue;
      mkdirSync(dirname(t.out), { recursive: true });
      writeFileSync(t.out, t.emit(wm));
      process.stderr.write(`wrote ${t.out}\n`);
    }
    return;
  }

  // An explicit input needs an explicit target: the two emitters produce
  // different languages, so there is no safe default to guess here.
  if (!target) {
    process.stderr.write(
      "gen-logo-plugin: --target=opencode|pi is required with an explicit input path\n",
    );
    process.exit(2);
  }

  const wm = parseWordmark(readFileSync(positional[0], "utf8"));
  const source = TARGETS[target].emit(wm);
  const outPath = positional[1];
  if (outPath) {
    mkdirSync(dirname(outPath), { recursive: true });
    writeFileSync(outPath, source);
    process.stderr.write(`wrote ${outPath}\n`);
  } else {
    process.stdout.write(source);
  }
}

main(process.argv);
