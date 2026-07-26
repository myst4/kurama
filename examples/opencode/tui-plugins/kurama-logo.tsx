// @ts-nocheck
/** @jsxImportSource @opentui/solid */
// kurama-logo — replaces OpenCode's splash logo with the Kurama wordmark.
//
// GENERATED FILE — edit assets/banner/wordmark.txt, then run
// `node scripts/gen-logo-plugin.mjs`. Never hand-edit the art below.
//
// The TUI host declares the `home_logo` slot with mode:"replace", so registering
// it substitutes the default logo rather than stacking under it. Note the host
// does NOT pick a single winner: if a second plugin also registers `home_logo`,
// both logos render. Install one logo plugin at a time.
import type { TuiPlugin } from "@opencode-ai/plugin/tui"
import { useTerminalDimensions } from "@opentui/solid"
import { createMemo } from "solid-js"

const id = "kurama-logo"

// Same palette as scripts/banner.sh: FRESH 255,160,90 / DIM 90,45,15.
const SOLID = "#ffa05a"
const SHADOW = "#5a2d0f"

const WIDTH = 95
const HEIGHT = 10

// One entry per wordmark row: a list of colour runs, { t: text, s: shadow }.
const ROWS: { t: string; s: boolean }[][] = [[{"t":"███      ▄███   ███       ███   █████████████        ████       █████   ▄████        ████      ","s":false}],[{"t":"███","s":false},{"t":"▒▒","s":true},{"t":" ▄█████▀","s":false},{"t":"▒▒","s":true},{"t":" ███","s":false},{"t":"▒▒","s":true},{"t":"     ███","s":false},{"t":"▒▒","s":true},{"t":" ███▀▀▀▀▀▀▀███","s":false},{"t":"▒▒","s":true},{"t":"     ██████","s":false},{"t":"▒","s":true},{"t":"     █████▄","s":false},{"t":"▒","s":true},{"t":" █████","s":false},{"t":"▒▒","s":true},{"t":"     ██████","s":false},{"t":"▒","s":true},{"t":"    ","s":false}],[{"t":"███","s":false},{"t":"▒","s":true},{"t":"▄█████▀","s":false},{"t":"▒▒▒▒","s":true},{"t":" ███","s":false},{"t":"▒▒","s":true},{"t":"     ███","s":false},{"t":"▒▒","s":true},{"t":" ███","s":false},{"t":"▒▒▒▒▒▒▒","s":true},{"t":"███","s":false},{"t":"▒▒","s":true},{"t":"    ███████▄","s":false},{"t":"▒","s":true},{"t":"    ██████▄██████","s":false},{"t":"▒▒","s":true},{"t":"    ███████▄","s":false},{"t":"▒","s":true},{"t":"   ","s":false}],[{"t":"████████▀","s":false},{"t":"▒▒▒▒","s":true},{"t":"   ███","s":false},{"t":"▒▒","s":true},{"t":"     ███","s":false},{"t":"▒▒","s":true},{"t":" ███▄▄▄▄▄▄▄███","s":false},{"t":"▒▒","s":true},{"t":"   ▄███▀████","s":false},{"t":"▒▒","s":true},{"t":"   █████████████","s":false},{"t":"▒▒","s":true},{"t":"   ▄███▀████","s":false},{"t":"▒▒","s":true},{"t":"  ","s":false}],[{"t":"██████","s":false},{"t":"▒▒▒▒▒","s":true},{"t":"     ███","s":false},{"t":"▒▒","s":true},{"t":"     ███","s":false},{"t":"▒▒","s":true},{"t":" █████████████","s":false},{"t":"▒▒","s":true},{"t":"   ████","s":false},{"t":"▒▒","s":true},{"t":"███▄","s":false},{"t":"▒","s":true},{"t":"   ███","s":false},{"t":"▒","s":true},{"t":"█████████","s":false},{"t":"▒▒","s":true},{"t":"   ████","s":false},{"t":"▒▒","s":true},{"t":"███▄","s":false},{"t":"▒","s":true},{"t":"  ","s":false}],[{"t":"████████▄       ███","s":false},{"t":"▒▒","s":true},{"t":"     ███","s":false},{"t":"▒▒","s":true},{"t":" ███████▄","s":false},{"t":"▒▒▒▒▒▒▒","s":true},{"t":"  ████▄▄▄████","s":false},{"t":"▒▒","s":true},{"t":"  ███","s":false},{"t":"▒▒","s":true},{"t":"████","s":false},{"t":"▒","s":true},{"t":"███","s":false},{"t":"▒▒","s":true},{"t":"  ████▄▄▄████","s":false},{"t":"▒▒","s":true},{"t":" ","s":false}],[{"t":"███","s":false},{"t":"▒","s":true},{"t":"▀█████▄     ███","s":false},{"t":"▒▒","s":true},{"t":"     ███","s":false},{"t":"▒▒","s":true},{"t":" ███▀█████▄▄     █████████████","s":false},{"t":"▒","s":true},{"t":"  ███","s":false},{"t":"▒▒","s":true},{"t":"▀▀▀▀","s":false},{"t":"▒","s":true},{"t":"███","s":false},{"t":"▒▒","s":true},{"t":" █████████████","s":false},{"t":"▒","s":true},{"t":" ","s":false}],[{"t":"███","s":false},{"t":"▒▒","s":true},{"t":" ▀█████▄   ███▄▄▄▄▄▄▄███","s":false},{"t":"▒▒","s":true},{"t":" ███","s":false},{"t":"▒▒▒","s":true},{"t":"▀█████▄   ███▀","s":false},{"t":"▒▒▒▒▒▒","s":true},{"t":"███","s":false},{"t":"▒▒","s":true},{"t":" ███","s":false},{"t":"▒▒","s":true},{"t":"  ","s":false},{"t":"▒▒▒","s":true},{"t":"███","s":false},{"t":"▒▒","s":true},{"t":" ███▀","s":false},{"t":"▒▒▒▒▒▒","s":true},{"t":"███","s":false},{"t":"▒▒","s":true}],[{"t":"███","s":false},{"t":"▒▒","s":true},{"t":"   ","s":false},{"t":"▒","s":true},{"t":"▀███","s":false},{"t":"▒▒","s":true},{"t":" █████████████","s":false},{"t":"▒▒","s":true},{"t":" ███","s":false},{"t":"▒▒","s":true},{"t":"   ▀▀███","s":false},{"t":"▒▒","s":true},{"t":" ███","s":false},{"t":"▒▒▒","s":true},{"t":"    ▀██","s":false},{"t":"▒▒","s":true},{"t":" ███","s":false},{"t":"▒▒","s":true},{"t":"     ███","s":false},{"t":"▒▒","s":true},{"t":" ███","s":false},{"t":"▒▒▒","s":true},{"t":"    ▀██","s":false},{"t":"▒▒","s":true}],[{"t":"  ","s":false},{"t":"▒▒▒","s":true},{"t":"      ","s":false},{"t":"▒▒▒▒","s":true},{"t":"   ","s":false},{"t":"▒▒▒▒▒▒▒▒▒▒▒▒▒","s":true},{"t":"   ","s":false},{"t":"▒▒▒","s":true},{"t":"     ","s":false},{"t":"▒▒▒▒▒","s":true},{"t":"   ","s":false},{"t":"▒▒▒","s":true},{"t":"       ","s":false},{"t":"▒▒▒","s":true},{"t":"   ","s":false},{"t":"▒▒▒","s":true},{"t":"       ","s":false},{"t":"▒▒▒","s":true},{"t":"   ","s":false},{"t":"▒▒▒","s":true},{"t":"       ","s":false},{"t":"▒▒▒","s":true}]]

const COMPACT = "✦ KURAMA ✦"

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
