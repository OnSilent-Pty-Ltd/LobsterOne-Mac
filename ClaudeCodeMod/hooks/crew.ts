import type { EngineInterface } from 'claude-code'

import type { CrewRun } from '../types'

// LobsterOne's crew: Claude Code agents the app hired, marked in their charter's frontmatter.
// The band shows each one's face and what it is doing while it runs in this session.

// Where the portraits are: beside the mod, where the LobsterOne app copies them when it adds the
// mod, then in the installed app itself (the Xcode build flattens its resources).
function portraitDirs($: EngineInterface): string[] {
  return [`${$.plugin.root}/portraits`, '/Applications/LobsterOne.app/Contents/Resources']
}

// A finished run stays in the band this long, marked done, then goes.
export const DONE_MS = 10_000

export type Member = { name: string; face: string | null; title: string | null }

// Text the band draws from a charter or a tool call: no control characters, so nothing reaches a
// terminal as an escape sequence, and short.
export const clean = (text: string, max = 40) => text.replace(/[\u0000-\u001f\u007f-\u009f]/g, '').trim().slice(0, max)

// The frontmatter fields CrewInstaller writes. A charter without the marker is the person's own agent.
export const parseCharter = (text: string): Member | null => {
  const lines = text.split('\n')
  if (lines[0]?.trim() !== '---') {
    return null
  }
  const end = lines.findIndex((line, i) => i > 0 && line.trim() === '---')
  const fields = new Map<string, string>()
  for (const line of lines.slice(1, end < 0 ? lines.length : end)) {
    const match = /^([a-z-]+):\s*(.*)$/.exec(line)
    if (match !== null) {
      fields.set(match[1]!, match[2]!.trim().replace(/^"(.*)"$/, '$1'))
    }
  }
  const name = clean(fields.get('lobsterone-name') ?? '')
  if (!fields.has('lobsterone-crew') || name === '') {
    return null
  }
  const title = clean(fields.get('lobsterone-title') ?? '')

  return { name, face: fields.get('lobsterone-face') ?? null, title: title === '' ? null : title }
}

// The agent type as Claude Code records it is the charter's file name; a plugin's agents
// (`plugin:name`) and anything with a path in it are never the crew's.
const isPlainType = (type: string) => /^[A-Za-z0-9_-]+$/.test(type)

const members = new Map<string, Member | null>()

/**
 * The crew member an agent type is, read from its charter in ~/.claude/agents, the one folder the
 * app hires into. A project's own agents are never crew, so a cloned repo can't borrow a face.
 */
export async function memberFor($: EngineInterface, type: string): Promise<Member | null> {
  if (!isPlainType(type)) {
    return null
  }
  // A project's agent of the same name is the one Claude Code runs: it is not the member hired.
  // Without a project root to check, nobody is treated as crew.
  const root = await $.session.root().catch(() => null)
  if (root === null) {
    return null
  }
  const key = `${root}:${type}`
  const known = members.get(key)
  if (known !== undefined) {
    return known
  }
  if (await $.fs.exists(`${root}/.claude/agents/${type}.md`).catch(() => true)) {
    members.set(key, null)
    return null
  }
  const home = await $.env.get('HOME')
  const text = home === undefined ? null : await $.fs.read(`${home}/.claude/agents/${type}.md`).catch(() => null)
  const member = text === null ? null : parseCharter(text)
  members.set(key, member)

  return member
}

const faces = new Map<string, string | null>()

/** The portrait as base64 JPEG, or null when no copy is on this Mac. */
export async function portrait($: EngineInterface, face: string): Promise<string | null> {
  if (!/^[a-z0-9-]+$/.test(face)) {
    return null
  }
  const known = faces.get(face)
  if (known !== undefined) {
    return known
  }
  let found: string | null = null
  for (const dir of portraitDirs($)) {
    const bytes = await $.fs.read(`${dir}/crew-${face}.jpg`, { as: 'bytes' }).catch(() => null)
    if (bytes !== null) {
      found = bytes.base64
      break
    }
  }
  faces.set(face, found)

  return found
}

const basename = (path: unknown) => (typeof path === 'string' ? path.slice(path.lastIndexOf('/') + 1) : '')

// Programs whose second word is a subcommand worth showing ("git diff"). For any other program the
// second word may be anything (a password, a URL with a token, a key being echoed), so only the
// program's name shows.
const SUBCOMMANDS = new Set(['git', 'gh', 'npm', 'pnpm', 'yarn', 'bun', 'npx', 'swift', 'cargo', 'go', 'docker', 'kubectl', 'make', 'brew', 'xcodebuild', 'claude'])

// "running git diff", "running psql": the program, past any VAR=value and with its folder dropped,
// and a plain subcommand after it for the programs above. Nothing else from the command shows.
const commandWords = (command: unknown) => {
  if (typeof command !== 'string') {
    return ''
  }
  const words = command.trim().split(/\s+/)
  const first = words.findIndex(word => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(word))
  // A quote, escape or expansion before the program means a value may run on past a space,
  // and the word taken for the program could be part of it.
  if (first < 0 || words.slice(0, first).some(word => /['"\\$`]/.test(word))) {
    return ''
  }
  const program = words[first]!.slice(words[first]!.lastIndexOf('/') + 1)
  if (!/^[A-Za-z0-9._+-]{1,24}$/.test(program) || program.startsWith('-')) {
    return ''
  }
  const sub = words[first + 1]
  return sub !== undefined && SUBCOMMANDS.has(program) && /^[a-z][a-z-]{0,19}$/.test(sub) ? `${program} ${sub}` : program
}

/** What a tool call says the agent is doing, in a few words. */
export const describeCall = (tool: string, input: Record<string, unknown>): string => {
  switch (tool) {
    case 'Read':
      return clean(`reading ${basename(input.file_path)}`)
    case 'Grep':
    case 'Glob':
      return 'searching'
    case 'Bash': {
      const words = commandWords(input.command)
      return words === '' ? 'running a command' : `running ${words}`
    }
    case 'Edit':
    case 'MultiEdit':
    case 'Write':
      return clean(`editing ${basename(input.file_path)}`)
    case 'WebFetch':
    case 'WebSearch':
      return 'reading the web'
    default:
      return 'working'
  }
}

const RING = { working: '#2FA36B', done: '#A8A097', failed: '#D2413A' } as const

// Text that goes into the drawing's markup: a file name or a charter could carry any of these.
const esc = (text: string) => text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')

// One face in a circle `size` across, ringed by how its run stands; the initial where no portrait
// is found. `id` keeps each face's clip apart when several share a drawing.
const faceGroup = (run: CrewRun, jpeg: string | null, id: string, size: number) => {
  const c = size / 2
  const r = c - 2 // the picture's radius, inside the ring
  const ring = RING[run.state]
  const breathe =
    run.state === 'working'
      ? `<circle cx="${c}" cy="${c}" r="${r + 0.75}" fill="none" stroke="${ring}" stroke-width="1.5" opacity="0.6"><animate attributeName="stroke-width" values="1.5;3.5;1.5" dur="1.4s" repeatCount="indefinite"/><animate attributeName="opacity" values="0.6;0;0.6" dur="1.4s" repeatCount="indefinite"/></circle>`
      : ''
  const picture =
    jpeg === null
      ? `<circle cx="${c}" cy="${c}" r="${r}" fill="#C84B20"/><text x="${c}" y="${c + size * 0.16}" text-anchor="middle" class="initial" style="font-size:${Math.round(size * 0.45)}px">${esc(run.name.slice(0, 1))}</text>`
      : `<image href="data:image/jpeg;base64,${jpeg}" x="${c - r}" y="${c - r}" width="${2 * r}" height="${2 * r}" clip-path="url(#${id})" preserveAspectRatio="xMidYMid slice"${run.state === 'working' ? '' : ' opacity="0.7"'}/>`

  return `<defs><clipPath id="${id}"><circle cx="${c}" cy="${c}" r="${r}"/></clipPath></defs>${breathe}${picture}<circle cx="${c}" cy="${c}" r="${r + 0.75}" fill="none" stroke="${ring}" stroke-width="1.5"/>`
}

// Widths of the system sans (SF Pro) in ems, by kind of character, so the bubble hugs its text
// without measuring it. Close for plain words and file names; a little wide is the safe side.
const EM: [RegExp, number][] = [
  [/[ijl.,:;'|!]/, 0.24],
  [/[ frt\-()[\]\/]/, 0.33],
  [/[mwMW@]/, 0.82],
  [/[A-Z]/, 0.66],
  [/[0-9]/, 0.58],
  [/[a-z_]/, 0.53],
]

/** The text cut to at most `max` characters, "…" included; never splits a character such as an emoji. */
export const shorten = (text: string, max: number) => {
  const chars = Array.from(text)
  return chars.length <= max ? text : `${chars.slice(0, max - 1).join('').trimEnd()}…`
}

const textWidth = (text: string, size: number, bold = false) => {
  let em = 0
  for (const char of text) {
    em += EM.find(([kind]) => kind.test(char))?.[1] ?? 0.6
  }
  return Math.ceil(em * size * (bold ? 1.06 : 1))
}

const BUBBLE_H = 20
// Fewer characters than this say nothing useful: the bubble goes and the face stays.
const MIN_SAID = 8
const TAIL = 5

export type CrewFit = {
  /** The face's size: never taller than the project's logo on the left of the band. */
  size: number
  /** How wide the drawing may be, an estimate; null for no limit. */
  room: number | null
}

/**
 * The crew at work as one drawing, no taller than a face: their faces in a row, and beside them a
 * speech bubble, its tail at the faces, with the lead's name and what it is doing. A mod's drawing
 * is clipped to the band, so the bubble sits beside the head rather than above it. Where `room` is
 * short the name goes first, then the bubble, leaving the faces. `width` and `height` are what the
 * band gives the Svg.
 */
export const crewSvg = (runs: CrewRun[], pictures: (string | null)[], lead: CrewRun, fit: CrewFit) => {
  const size = fit.size
  const step = Math.round(size * 0.82) // faces overlap a little, like a row of heads
  const faces = runs
    .map((run, i) => `<g transform="translate(${i * step} 0)">${faceGroup(run, pictures[i] ?? null, `f${i}`, size)}</g>`)
    .join('')
  const facesW = (runs.length - 1) * step + size

  const x = facesW + TAIL + 2 // the bubble's left edge; its tail reaches back toward the face
  // Tight room: the name goes first, then the status is cut short, then the bubble goes.
  const fits = (w: number) => fit.room === null || x + w + 1 <= fit.room
  const nameW = textWidth(lead.name, 12, true)
  const full = 10 + nameW + 6 + textWidth(lead.status, 11.5) + 11
  const withName = fits(full)
  const pill = (text: string) => 10 + textWidth(text, 11.5) + 11
  const cut = (n: number) => shorten(lead.status, n + 1)
  let said = lead.status
  if (!withName && !fits(pill(said))) {
    let n = lead.status.length - 1
    while (n >= MIN_SAID && !fits(pill(cut(n)))) n--
    said = n >= MIN_SAID ? cut(n) : ''
  }
  const bubbleW = said === '' ? 0 : withName ? full : pill(said)

  const height = Math.max(size, BUBBLE_H + 1)
  const fy = (height - size) / 2
  const y = (height - BUBBLE_H) / 2
  const r = BUBBLE_H / 2
  const mid = y + r
  const bubble =
    bubbleW === 0
      ? ''
      : `<path class="bubble" d="M${x} ${mid - 3.5} L${x - TAIL} ${mid} L${x} ${mid + 3.5} V${y + BUBBLE_H - r} a${r} ${r} 0 0 0 ${r} ${r} H${x + bubbleW - r} a${r} ${r} 0 0 0 0 ${-BUBBLE_H} H${x + r} a${r} ${r} 0 0 0 ${-r} ${r} Z"/>` +
        `<text x="${x + 10}" y="${mid + 4}">${withName ? `<tspan class="name">${esc(lead.name)}</tspan><tspan class="say" dx="6">` : '<tspan class="say">'}${esc(said)}</tspan></text>`

  const width = Math.ceil(bubbleW === 0 ? facesW : x + bubbleW + 1)
  const style =
    '<style>text{font-family:-apple-system,"Helvetica Neue",Arial,sans-serif}.name{font-size:12px;font-weight:600;fill:#0A0A0A}.say{font-size:11.5px;fill:#3D3833}.bubble{fill:#FFFFFF;stroke:#D6CFC6;stroke-width:1;stroke-linejoin:round}.initial{font-weight:600;fill:#FFFFFF}@media (prefers-color-scheme:dark){.name{fill:#F5F0EA}.say{fill:#D6CFC6}.bubble{fill:#2C2823;stroke:#4A443D}}</style>'
  const source = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}">${style}<g transform="translate(0 ${fy})">${faces}</g>${bubble}</svg>`

  return { source, width, height }
}


