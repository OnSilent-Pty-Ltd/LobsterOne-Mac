/** working: a turn is running. idle: nothing is. error: the last turn died on an API error. */
export type Health = 'working' | 'idle' | 'error'

/**
 * What the band draws: the health now, activity per 400 ms sample, oldest first, and the health
 * each sample was taken in. `phases` is absent in what 0.2.0 stored.
 */
export type Pulse = { health: Health; beats: number[]; phases?: Health[] }

/** One mode's page and text colours, as a project's brand.json gives them (six-digit hex). */
export type BrandMode = Partial<
  Record<'surface-0' | 'surface-1' | 'surface-2' | 'surface-3' | 'text-primary' | 'text-secondary' | 'text-muted', string>
>

/**
 * The colours a session takes on in this project: an accent at least, and from a brand.json the
 * other roles and each mode's page and text colours.
 */
export type Palette = {
  accent: string
  success?: string
  danger?: string
  warning?: string
  pro?: string
  light?: BrandMode
  dark?: BrandMode
}

/**
 * The project the session is in: its root folder, its name, its logo as a ready Svg source (null
 * when none was found), the file it came from, and a colour taken from it. `lockup`, a wide mark
 * and wordmark drawn in place of logo and name, and `palette`, the session's theme, come from the
 * project's .claude/brand.json, or for `palette` from the logo's colour; `fromFile` says which.
 * The three are absent in what 0.7 stored.
 */
export type Brand = {
  root: string
  name: string
  logo: string | null
  logoPath: string | null
  accent: string | null
  lockup?: { source: string; width: number } | null
  palette?: Palette | null
  fromFile?: boolean
}

/**
 * A LobsterOne crew member running in this session, as the band shows it: which agent run, who it
 * is (from its charter), what it is doing in a few words, and whether it is still at it. `endedAt`
 * is set when the run ends; the band drops it a few seconds later. Absent before 0.6.0.
 */
export type CrewRun = {
  agentId: string
  name: string
  face: string | null
  title: string | null
  status: string
  state: 'working' | 'done' | 'failed'
  endedAt: number | null
  /** The Agent call that started the run, whose transcript row carries the bubble; absent before 0.7.0. */
  toolUseId?: string | null
}

declare module 'claude-code' {
  interface PluginState {
    'lobsterone': { pulse: Pulse; brand: Brand | null; crew: CrewRun[] }
  }
}
