// Status line de OpenCode: uso de la suscripción Go (5h / semana / mes) con reinicio.
// Se carga desde cli.json -> plugins: ["./statusline"].
import { Plugin } from "@opencode/plugin/tui"
import { StyledText, fg as styledFg } from "@opentui/core"
import { createSignal } from "solid-js"

const POLL_MS = 60_000
const FREE_POLL_MS = 120_000
const SIDEBAR_BREAKPOINT = 120
const CONFIG_DIR = process.env.XDG_CONFIG_HOME
  ? `${process.env.XDG_CONFIG_HOME}/opencode`
  : `${process.env.HOME ?? ""}/.config/opencode`

const FREE_SCRIPT_CANDIDATES = [
  process.env.OPENCODE_FREE_QUOTA_SCRIPT,
  `${CONFIG_DIR}/statusline/free-quota.sh`,
  `${process.env.HOME ?? ""}/Documents/repositorios/opencode-config/scripts/free-quota.sh`,
].filter((value): value is string => !!value)

const OK = "#22c55e"
const WARN = "#f97316"
const DANGER = "#ef4444"
const MUTED = "#6b7280"
const EMPTY = "#3f3f46"
const TEXT = "#e4e4e7"
const CARD_BG = "#131316"
const CARD_BORDER = "#3f3f46"
const MONTHS = ["ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic"]

type Meter = { percent: number; limited: boolean; resetsAt: number }
type GoLimits = { rolling?: Meter; weekly?: Meter; monthly?: Meter }

type FreeQuota = {
  window_start: string
  window_end: string
  used: { calls: number; tokens: number; cache_read: number }
  reference: { calls: number | null; tokens: number | null; at: string; transient: boolean }
  floor_calls: number
  remaining: { calls: [number, number]; tokens: [number, number] } | null
  reference_stale: boolean
  blocks_in_window: number
  last_block: string
  last_block_transient: boolean
}

const BAR_CELLS = 14

function pct(n: number) {
  const v = Math.max(0, Math.min(100, n))
  return `${v < 10 ? v.toFixed(1) : Math.round(v)}%`
}

function barCells(n: number, width = BAR_CELLS) {
  const v = Math.max(0, Math.min(100, n))
  const cells = Math.round((v / 100) * width)
  // Con muy poco uso, una celda llena se lee mejor que una barra vacía junto a "1.0%".
  if (cells === 0 && v > 0) return 1
  return Math.max(0, Math.min(width, cells))
}

function fmtDuration(ms: number, compact = false) {
  if (!Number.isFinite(ms) || ms <= 0) return "ahora"
  const mins = Math.floor(ms / 60_000)
  const d = Math.floor(mins / 1440)
  const h = Math.floor((mins % 1440) / 60)
  const m = mins % 60
  if (compact) {
    if (d > 0) return `${d}d`
    if (h > 0) return `${h}h${m}m`
    return `${m}m`
  }
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  return `${m}m`
}

function mixHex(from: string, to: string, amount: number) {
  const a = parseInt(from.slice(1), 16)
  const b = parseInt(to.slice(1), 16)
  const channel = (shift: number) => {
    const left = (a >> shift) & 0xff
    const right = (b >> shift) & 0xff
    return Math.round(left + (right - left) * amount)
  }
  return `#${[channel(16), channel(8), channel(0)]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("")}`
}

// Verde hasta 25%, naranja al 50%, rojo desde 75%.
function colorFor(n: number) {
  const value = Math.max(0, Math.min(100, n))
  if (value <= 25) return OK
  if (value <= 50) return mixHex(OK, WARN, (value - 25) / 25)
  if (value <= 75) return mixHex(WARN, DANGER, (value - 50) / 25)
  return DANGER
}

function human(n: number) {
  if (!Number.isFinite(n)) return "—"
  if (n >= 1e9) return `${(n / 1e9).toFixed(2)}B`
  if (n >= 1e6) return `${(n / 1e6).toFixed(2)}M`
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}k`
  return String(Math.round(n))
}

function parseTs(value?: string) {
  if (!value) return 0
  const t = Date.parse(value.replace(" ", "T"))
  return Number.isFinite(t) ? t : 0
}

function clock(value?: string) {
  const t = parseTs(value)
  if (!t) return "—"
  const d = new Date(t)
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`
}

function fmtDay(value?: string) {
  const t = parseTs(value)
  if (!t) return "—"
  const d = new Date(t)
  return `${d.getDate()} ${MONTHS[d.getMonth()]} ${clock(value)}`
}

export default Plugin.define({
  id: "statusline",
  setup(context) {
    const [go, setGo] = createSignal<GoLimits | null>(null)
    const [failed, setFailed] = createSignal(false)
    const [free, setFree] = createSignal<FreeQuota | null>(null)
    const [freeFailed, setFreeFailed] = createSignal(false)
    const [freeHover, setFreeHover] = createSignal(false)
    const [freePinned, setFreePinned] = createSignal(false)
    const freeOpen = () => freeHover() || freePinned()

    const location = () => context.location ?? context.data.location.default()

    async function refreshUsage() {
      try {
        const response: any = await (context.client as any).experimental.usage.limits({
          location: location(),
        })
        const info = response?.data?.data ?? response?.data ?? null
        setGo(info?.go ?? null)
        setFailed(false)
      } catch {
        setFailed(true)
      }
    }

    async function refreshFree() {
      try {
        const { existsSync } = await import("node:fs")
        const script = FREE_SCRIPT_CANDIDATES.find((candidate) => existsSync(candidate))
        if (!script) throw new Error("no se encontró free-quota.sh")
        const { execFile } = await import("node:child_process")
        const { promisify } = await import("node:util")
        const { stdout } = await promisify(execFile)("/bin/bash", [script, "--json"], {
          timeout: 20_000,
          maxBuffer: 1024 * 1024,
        })
        const info = JSON.parse(String(stdout)) as FreeQuota
        if (!info?.used || !info?.reference) throw new Error("respuesta incompleta")
        setFree(info)
        setFreeFailed(false)
      } catch {
        setFreeFailed(true)
      }
    }

    refreshUsage()
    refreshFree()
    const timer = setInterval(refreshUsage, POLL_MS)
    const freeTimer = setInterval(refreshFree, FREE_POLL_MS)

    // Ancho del terminal: con sidebar el host oculta nuestra línea del footer,
    // sin sidebar (paneles estrechos de herdr) mostramos la versión corta.
    const rendererWidth = () => {
      const value = (context.renderer as any)?.width
      return typeof value === "number" ? value : 0
    }
    const rendererHeight = () => {
      const value = (context.renderer as any)?.height
      return typeof value === "number" ? value : 0
    }
    const [width, setWidth] = createSignal(rendererWidth())
    const [height, setHeight] = createSignal(rendererHeight())
    const widthTimer = setInterval(() => {
      const current = rendererWidth()
      if (current > 0 && current !== width()) setWidth(current)
      const rows = rendererHeight()
      if (rows > 0 && rows !== height()) setHeight(rows)
    }, 1_000)
    const wide = () => (width() || rendererWidth()) > SIDEBAR_BREAKPOINT

    // Este runtime no aplica color a <span> ni acepta StyledText en `content`:
    // solo colorea cada <text> por separado. Para que las barras arranquen en la
    // misma columna, la etiqueta va en una caja fija que no se encoge y la fila
    // ocupa todo el ancho disponible.
    const Label = (props: { text: string }) => (
      <box width={5} flexShrink={0}>
        <text fg={MUTED}>{props.text}</text>
      </box>
    )

    const BarRow = (props: { label: string; meter: Meter }) => {
      const color = () => (props.meter.limited ? DANGER : colorFor(props.meter.percent))
      const filled = () => barCells(props.meter.percent)
      const percent = () => (props.meter.limited ? "límite" : pct(props.meter.percent))
      return (
        <box flexDirection="row" width="100%" flexShrink={0}>
          <Label text={props.label} />
          {filled() > 0 ? <text fg={color()}>{"█".repeat(filled())}</text> : null}
          {filled() < BAR_CELLS ? (
            <text fg={EMPTY}>{"░".repeat(BAR_CELLS - filled())}</text>
          ) : null}
          <text fg={color()}>{`  ${percent().padStart(4)}`}</text>
          <text fg={MUTED}>{`  ↺${fmtDuration(props.meter.resetsAt - Date.now(), true)}`}</text>
        </box>
      )
    }

    const FreeRow = (props: { quota: FreeQuota }) => {
      const quota = props.quota
      const refCalls = quota.reference?.calls ?? 0
      const refTokens = quota.reference?.tokens ?? 0
      const calls = refCalls > 0 ? (quota.used.calls / refCalls) * 100 : 0
      const tokens = refTokens > 0 ? (quota.used.tokens / refTokens) * 100 : 0
      const value = Math.max(calls, tokens)
      const color = quota.reference_stale ? WARN : colorFor(value)
      const filled = barCells(Math.min(100, value))
      const reset = parseTs(quota.window_end) - Date.now()
      const percent = refCalls > 0 || refTokens > 0 ? `${Math.round(value)}%` : "—"
      return (
        <box flexDirection="row" width="100%" flexShrink={0}>
          <Label text="free" />
          {filled > 0 ? <text fg={color}>{"█".repeat(filled)}</text> : null}
          {filled < BAR_CELLS ? (
            <text fg={EMPTY}>{"░".repeat(BAR_CELLS - filled)}</text>
          ) : null}
          <text fg={color}>{`  ${percent.padStart(4)}`}</text>
          <text fg={MUTED}>{`  ↺${fmtDuration(reset, true)}`}</text>
        </box>
      )
    }

    const FreeOverlay = () => {
      const quota = free()
      if (!quota || !freeOpen()) return null

      const refCalls = quota.reference?.calls ?? 0
      const refTokens = quota.reference?.tokens ?? 0
      const remainCalls = Math.max(0, refCalls - quota.used.calls)
      const remainTokens = Math.max(0, refTokens - quota.used.tokens)
      const stale = quota.reference_stale
      const callsRatio = refCalls > 0 ? (quota.used.calls / refCalls) * 100 : 0
      const tokensRatio = refTokens > 0 ? (quota.used.tokens / refTokens) * 100 : 0
      const callsColor = stale ? WARN : colorFor(callsRatio)
      const tokensColor = stale ? WARN : colorFor(tokensRatio)

      const cardWidth = 54
      const cardHeight = 12
      const terminalWidth = (context.renderer as any)?.terminalWidth
      const terminalHeight = (context.renderer as any)?.terminalHeight
      const screenWidth =
        typeof terminalWidth === "number" && terminalWidth > 0
          ? terminalWidth
          : width() || rendererWidth() || 80
      const screenHeight =
        typeof terminalHeight === "number" && terminalHeight > 0
          ? terminalHeight
          : height() || rendererHeight() || 24
      const left = Math.max(0, Math.floor((screenWidth - cardWidth) / 2))
      const top = Math.max(0, Math.floor((screenHeight - cardHeight) / 2))

      const row = (label: string, children: any) => (
        <box flexDirection="row" gap={1}>
          <box width={8}>
            <text fg={MUTED}>{label}</text>
          </box>
          {children}
        </box>
      )

      const lastBlock = quota.last_block
        ? `${fmtDay(quota.last_block)} · ${quota.last_block_transient ? "transitorio" : "duro"}`
        : "ninguno"

      return (
        <box
          position="absolute"
          left={left}
          top={top}
          width={cardWidth}
          height={cardHeight}
          border
          borderStyle="rounded"
          borderColor={CARD_BORDER}
          backgroundColor={CARD_BG}
          title="Límites free · estimado"
          titleColor={MUTED}
          titleAlignment="center"
          padding={1}
          flexDirection="column"
        >
          {row(
            "ventana",
            <text fg={TEXT}>{`${fmtDay(quota.window_start)} → ${fmtDay(quota.window_end)}`}</text>,
          )}
          {row(
            "llamadas",
            <>
              <text fg={callsColor}>{`${quota.used.calls} / ${refCalls}`}</text>
              <text fg={MUTED}>{stale ? "recalibrando" : `restan ${remainCalls}`}</text>
            </>,
          )}
          {row(
            "tokens",
            <>
              <text fg={tokensColor}>{`${human(quota.used.tokens)} / ${human(refTokens)}`}</text>
              <text fg={MUTED}>{stale ? "recalibrando" : `restan ${human(remainTokens)}`}</text>
            </>,
          )}
          {row("caché", <text fg={TEXT}>{`${human(quota.used.cache_read)} leídos`}</text>)}
          {row("429", <text fg={TEXT}>{lastBlock}</text>)}
          {row(
            "reinicio",
            <text fg={TEXT}>{`en ${fmtDuration(parseTs(quota.window_end) - Date.now())}`}</text>,
          )}
          <text> </text>
          <text fg={MUTED}>{freePinned() ? "clic de nuevo para soltar" : "clic en la fila para fijar"}</text>
        </box>
      )
    }

    function usageBlock() {
      const limits = go()
      const quota = free()
      const hasGo = !!(limits?.rolling || limits?.weekly || limits?.monthly)

      if (!hasGo && !quota) {
        return (
          <box flexDirection="column">
            <text fg={MUTED}>Límites</text>
            <text fg={MUTED}>{failed() && freeFailed() ? "uso n/d" : "…"}</text>
          </box>
        )
      }

      return (
        <box flexDirection="column">
          <text fg={MUTED}>Límites</text>
          <box flexDirection="column" gap={1}>
            {limits?.rolling ? <BarRow label="5h" meter={limits.rolling} /> : null}
            {limits?.weekly ? <BarRow label="sem" meter={limits.weekly} /> : null}
            {limits?.monthly ? <BarRow label="mes" meter={limits.monthly} /> : null}
            {quota ? (
              <box
                flexDirection="column"
                onMouseOver={() => setFreeHover(true)}
                onMouseOut={() => setFreeHover(false)}
                onMouseDown={() => {
                  const next = !freePinned()
                  setFreePinned(next)
                  if (!next) setFreeHover(false)
                }}
              >
                <FreeRow quota={quota} />
              </box>
            ) : (
              <text fg={MUTED}>{`free ${freeFailed() ? "n/d" : "…"}`}</text>
            )}
          </box>
        </box>
      )
    }

    const meterBits = (label: string, meter: Meter) => {
      const color = meter.limited ? DANGER : colorFor(meter.percent)
      return (
        <>
          <text fg={MUTED}>{`${label} `}</text>
          <text fg={color}>{meter.limited ? "límite" : pct(meter.percent)}</text>
          <text fg={MUTED}>{` ↺${fmtDuration(meter.resetsAt - Date.now(), true)}`}</text>
        </>
      )
    }

    function statusLine() {
      const limits = go()
      if (!limits) {
        return <text fg={failed() ? DANGER : MUTED}>{failed() ? "uso n/d" : ""}</text>
      }

      // En paneles estrechos (herdr con varios paneles) solo 5h y semana: el mes
      // no cabe con los reinicios y es el límite menos urgente.
      const narrow = width() > 0 && width() < 100

      return (
        <box flexDirection="row">
          {limits.rolling ? meterBits("5h", limits.rolling) : null}
          {limits.weekly ? (
            <>
              <text fg={MUTED}>{" · "}</text>
              {meterBits("sem", limits.weekly)}
            </>
          ) : null}
          {limits.monthly && !narrow ? (
            <>
              <text fg={MUTED}>{" · "}</text>
              {meterBits("mes", limits.monthly)}
            </>
          ) : null}
        </box>
      )
    }

    context.ui.slot({
      append: "prompt.footer.status",
      render: () => (wide() ? null : statusLine()),
    })

    context.ui.slot({
      append: "home.footer.status",
      render: () => statusLine(),
    })

    context.ui.slot({
      append: "sidebar.footer",
      render: () => usageBlock(),
    })

    context.ui.slot({
      append: "app",
      render: () => <FreeOverlay />,
    })

    context.keymap.layer(() => ({
      mode: "global",
      commands: [
        {
          id: "statusline.usage",
          title: "Ver uso (Go y free)",
          group: "Statusline",
          palette: true,
          slash: { name: "uso" },
          run: async () => {
            try {
              await Promise.all([refreshUsage(), refreshFree()])
              const limits = go()
              const goLines: string[] = []
              if (!limits) {
                goLines.push(
                  failed()
                    ? "Go        no se pudo leer el uso"
                    : "Go        sin suscripción en este workspace",
                )
              } else {
                const rows = [
                  ["5 horas", limits.rolling],
                  ["Semanal", limits.weekly],
                  ["Mensual", limits.monthly],
                ] as const
                goLines.push(
                  ...rows
                    .filter(([, meter]) => !!meter)
                    .map(([label, meter]) => {
                      const item = meter as Meter
                      return `${label.padEnd(9)} ${pct(item.percent).padStart(6)} usado  ·  ${
                        item.limited ? "LÍMITE ALCANZADO" : "disponible"
                      }  ·  reinicia en ${fmtDuration(item.resetsAt - Date.now())}`
                    }),
                )
              }

              const quota = free()
              const freeLines: string[] = ["", "Free (estimado)"]
              if (!quota) {
                freeLines.push(freeFailed() ? "sin datos" : "…")
              } else {
                const ref = quota.reference?.calls ?? null
                const stale = quota.reference_stale || !ref
                freeLines.push(
                  `llamadas  ${quota.used.calls} usadas${ref ? ` · techo ${ref}` : ""}${
                    stale ? " · referencia vieja" : ""
                  }`,
                )
                freeLines.push(
                  `tokens    ${human(quota.used.tokens)} usados${
                    quota.reference?.tokens ? ` · techo ${human(quota.reference.tokens)}` : ""
                  } · ${human(quota.used.cache_read)} caché`,
                )
                if (!stale && quota.remaining) {
                  freeLines.push(
                    `quedan    ${quota.remaining.calls[1]} llam · ${human(quota.remaining.tokens[1])} tok`,
                  )
                }
                freeLines.push(
                  `ventana   reinicia en ${fmtDuration(parseTs(quota.window_end) - Date.now())}`,
                )
                freeLines.push(
                  quota.blocks_in_window > 0
                    ? `bloqueos  ${quota.blocks_in_window} · último ${clock(quota.last_block)}${
                        quota.last_block_transient ? " (transitorio)" : ""
                      }`
                    : "bloqueos  ninguno",
                )
              }

              const message = [...goLines, ...freeLines].join("\n")
              await context.ui.dialog.alert({ title: "Uso de OpenCode", message })
            } catch (err) {
              await context.ui.toast.show({
                message: `No se pudo mostrar el uso: ${err instanceof Error ? err.message : String(err)}`,
                variant: "error",
              })
            }
          },
        },
      ],
      bindings: ["statusline.usage"],
    }))

    return () => {
      clearInterval(timer)
      clearInterval(freeTimer)
      clearInterval(widthTimer)
    }
  },
})
