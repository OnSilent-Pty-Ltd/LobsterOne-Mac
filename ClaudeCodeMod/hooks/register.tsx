import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, ThemeSetArgs, TurnStepChunk } from 'claude-code'

import type { Brand, CrewRun, Health, Pulse } from '../types'
import { CRITTER, discover, projectRoot } from './brand'
import { DONE_MS, clean, crewSvg, describeCall, memberFor, portrait } from './crew'
import type { Member } from './crew'
import { makeColors } from './make-colors.js'

// Every project wears its own brand: the logo and name on the left of the band and, where the
// project's colours are known, a theme for the whole session made from them. A project states its
// brand in .claude/brand.json; one without gets what its logo says (brand.ts).

/** The session's theme in this project's colours; null when they aren't known or wouldn't paint. */
function themeFor(brand: Brand | null): ThemeSetArgs['colors'] | null {
  const palette = brand?.palette
  if (brand === null || palette === undefined || palette === null) {
    return null
  }
  const { light, dark, ...roles } = palette
  try {
    const { theme, problems } = makeColors({
      label: brand.name,
      roles,
      ...(light === undefined ? {} : { light: { gray: { anchors: light as { 'surface-0': string; 'text-primary': string } } } }),
      ...(dark === undefined ? {} : { dark: { gray: { anchors: dark as { 'surface-0': string; 'text-primary': string } } } }),
    })
    // Desktop ignores a theme with one of these, so send none rather than one that won't draw.
    return problems.some(line => line.startsWith("Desktop won't paint")) ? null : theme
  } catch {
    return null
  }
}

// The project whose theme this module set, so it clears only its own: a clear takes down any
// mod's theme, so it happens only on moving to a project with none of its own.
let themedFor: string | null = null

async function wear($: EngineInterface, brand: Brand | null) {
  const colors = themeFor(brand)
  if (colors !== null && brand !== null) {
    await $.theme.set({ colors })
    themedFor = brand.root
  } else if (themedFor !== null) {
    await $.theme.clear()
    themedFor = null
  }
}

// The repo the session sits in below the project, e.g. "Robocog---Mac"; empty at the root.
const subfolder = (cwd: string, root: string | null) =>
  root !== null && cwd.startsWith(`${root}/`) ? cwd.slice(root.length + 1).split('/')[0] ?? '' : ''

const brandAtom = atom({ plugin: 'lobsterone', key: 'brand' } as const, null as Brand | null)

// LobsterOne crew members running in this session, oldest first.
const crewAtom = atom({ plugin: 'lobsterone', key: 'crew' } as const, [] as CrewRun[])

// What an earlier version or a bad write left is read as no crew.
const isRun = (run: unknown): run is CrewRun => {
  const r = run as Partial<CrewRun> | null
  return (
    typeof r === 'object' && r !== null && typeof r.agentId === 'string' && typeof r.name === 'string' &&
    typeof r.status === 'string' && (r.state === 'working' || r.state === 'done' || r.state === 'failed') &&
    (r.title === null || typeof r.title === 'string') && (r.face === null || typeof r.face === 'string') &&
    (r.endedAt === null || typeof r.endedAt === 'number') &&
    (r.toolUseId === undefined || r.toolUseId === null || typeof r.toolUseId === 'string')
  )
}

// Text an earlier version stored is cleaned again on the way out.
const crewOf = (runs: unknown): CrewRun[] =>
  Array.isArray(runs)
    ? runs.filter(isRun).map(r => ({ ...r, name: clean(r.name), title: r.title === null ? null : clean(r.title), status: clean(r.status) }))
    : []

async function readCrew($: EngineInterface): Promise<CrewRun[]> {
  return crewOf(await read($, crewAtom))
}

// Faces drawn side by side; more than this shows as "+N".
const CREW_FACES = 3

// How often the timer looks for a change of folder: every 12 samples, about 5 s.
const CWD_EVERY = 12

// ---- Health and activity ----------------------------------------------------------------------

const SAMPLE_MS = 400
const SAMPLES = 60 // 24 seconds of history

const pulse = atom({ plugin: 'lobsterone', key: 'pulse' } as const, {
  health: 'idle',
  beats: [],
  phases: [],
} as Pulse)

// Activity this recent keeps the dot green, so the dot and the head of the trace never disagree.
const RECENT_SAMPLES = 3

// What counts as activity: each streamed piece of model output is one, a tool call is a big one.
const weigh = (chunk: TurnStepChunk) => {
  switch (chunk.kind) {
    case 'text':
    case 'thinking':
    case 'input':
      return 1
    case 'tool':
      return 4
    default:
      return 0
  }
}

const COLOR: Record<Health, string> = {
  working: '#2FA36B',
  idle: '#A8A097',
  error: '#D2413A',
}

const LABEL: Record<Health, string> = { working: 'working', idle: 'idle', error: 'error' }

const GRAPH_W = 132
const GRAPH_NARROW = 72
const GRAPH_H = 24

// The trace, ECG style: a faint grid, a soft glow under a crisp line, a bright head at the newest
// sample. Each stretch keeps the colour of the state it was drawn in, so a turn that just ended
// stays green as it scrolls away while the head goes grey.
const graphSvg = (beats: number[], phases: Health[], health: Health, width = GRAPH_W) => {
  const offset = beats.length - SAMPLES
  const values = Array.from({ length: SAMPLES }, (_, i) => beats[offset + i] ?? 0)
  const states = Array.from({ length: SAMPLES }, (_, i) => phases[phases.length - SAMPLES + i] ?? 'idle')
  states[SAMPLES - 1] = health
  const peak = Math.max(8, ...values)
  const floor = GRAPH_H - 3
  const step = width / (SAMPLES - 1)
  const points = values.map((v, i) => `${(i * step).toFixed(1)},${(floor - Math.sqrt(v / peak) * (GRAPH_H - 6)).toFixed(1)}`)

  // A segment from sample i-1 to i takes the state of sample i.
  const runs: { state: Health; from: number; to: number }[] = []
  for (let i = 1; i < SAMPLES; i++) {
    const last = runs[runs.length - 1]
    if (last !== undefined && last.state === states[i]) {
      last.to = i
    } else {
      runs.push({ state: states[i]!, from: i - 1, to: i })
    }
  }
  const lines = runs
    .map(run => {
      const pts = points.slice(run.from, run.to + 1).join(' ')
      const color = COLOR[run.state]
      return `<polyline points="${pts}" fill="none" stroke="${color}" stroke-opacity="0.25" stroke-width="4" stroke-linejoin="round" stroke-linecap="round"/><polyline points="${pts}" fill="none" stroke="${color}" stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/>`
    })
    .join('')
  const head = points[SAMPLES - 1]!.split(',')
  const grid = [6, 12, 18].map(y => `<line x1="0" x2="${width}" y1="${y}" y2="${y}"/>`).join('')
  const ticks = Array.from({ length: 11 }, (_, i) => `<line y1="0" y2="${GRAPH_H}" x1="${(i * width / 10).toFixed(1)}" x2="${(i * width / 10).toFixed(1)}"/>`).join('')

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${GRAPH_H}" width="${width}" height="${GRAPH_H}"><g stroke="#A8A097" stroke-opacity="0.18" stroke-width="0.5">${grid}${ticks}</g>${lines}<circle cx="${head[0]}" cy="${head[1]}" r="2" fill="${COLOR[health]}"/></svg>`
}

// The dot. Green breathes while working; white is ringed so it reads on beige; red is steady.
const dotSvg = (health: Health) => {
  const fill = health === 'working' ? COLOR.working : health === 'error' ? COLOR.error : '#FFFFFF'
  const ring = health === 'idle' ? '<circle cx="8" cy="8" r="4.5" fill="none" stroke="#A8A097" stroke-width="1"/>' : ''
  const halo =
    health === 'working'
      ? `<circle cx="8" cy="8" r="4" fill="${fill}" opacity="0.5"><animate attributeName="r" values="4;7.5;4" dur="1.4s" repeatCount="indefinite"/><animate attributeName="opacity" values="0.5;0;0.5" dur="1.4s" repeatCount="indefinite"/></circle>`
      : ''

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16">${halo}<circle cx="8" cy="8" r="4.5" fill="${fill}"/>${ring}</svg>`
}

const SPARKS = '▁▂▃▄▅▆▇█'

// The terminal's trace, as runs of one colour each, by the state each sample was taken in.
const sparkRuns = (beats: number[], phases: Health[], health: Health, width: number) => {
  const values = Array.from({ length: width }, (_, i) => beats[beats.length - width + i] ?? 0)
  const states = Array.from({ length: width }, (_, i) => phases[phases.length - width + i] ?? 'idle')
  states[width - 1] = health
  const peak = Math.max(8, ...values)
  const runs: { state: Health; text: string }[] = []

  values.forEach((v, i) => {
    const char = SPARKS[Math.min(7, Math.round(Math.sqrt(v / peak) * 7))]!
    const last = runs[runs.length - 1]
    if (last !== undefined && last.state === states[i]) {
      last.text += char
    } else {
      runs.push({ state: states[i]!, text: char })
    }
  })

  return runs
}

// The folder whose project is being looked up now, so two lookups never run at once.
let finding: string | null = null

// Finds the project's brand when the session's project is not the one already found, and wears it.
async function refreshBrand($: EngineInterface, cwd: string) {
  const root = projectRoot(cwd)
  const known = await read($, brandAtom)

  if (finding === root || (known?.root ?? null) === root) {
    return
  }

  finding = root
  try {
    const brand = await discover($, cwd)
    await update($, brandAtom, () => brand)
    await wear($, brand)
  } finally {
    finding = null
  }
}

type Found = { member: Member; type: string }

// Which crew member each agent run is, looked up once per run: null for an agent that isn't crew.
const lookups = new Map<string, Promise<Found | null>>()

// Agent calls not yet tied to a run, by agent type, oldest first: `agent.spawn` names the call's
// `tool_use_id`, and the run that type starts next is the one that call started.
const spawns = new Map<string, string[]>()

function takeSpawn(type: string): string | null {
  const queue = spawns.get(type) ?? []
  const id = queue.shift() ?? null
  if (queue.length === 0) {
    spawns.delete(type)
  }
  return id
}

function lookup($: EngineInterface, agentId: string): Promise<Found | null> {
  let found = lookups.get(agentId)
  if (found === undefined) {
    found = $.agent
      .list()
      .then(agents => {
        const agent = agents.find(a => a.id === agentId)
        if (agent === undefined) {
          // Not listed yet: ask again on the run's next event rather than remember "not crew".
          lookups.delete(agentId)
          return null
        }
        return memberFor($, agent.type).then(member => (member === null ? null : { member, type: agent.type }))
      })
      .catch(() => {
        lookups.delete(agentId)
        return null
      })
    lookups.set(agentId, found)
  }
  return found
}

// Changes one run in the band, adding it on first sight. Waits on the lookup, so changes land in
// the order they were made and an agent that isn't crew never shows.
function setRun($: EngineInterface, agentId: string, change: Partial<CrewRun>): Promise<void> {
  return lookup($, agentId)
    .then(async found => {
      if (found === null) {
        return
      }
      await update($, crewAtom, stored => {
        const runs = crewOf(stored)
        const at = runs.findIndex(r => r.agentId === agentId)
        const base: CrewRun = runs[at] ?? {
          agentId,
          ...found.member,
          status: 'starting',
          state: 'working',
          endedAt: null,
          toolUseId: takeSpawn(found.type),
        }
        const changed = { ...base, ...change }
        return at < 0 ? [...runs, changed] : runs.map((r, i) => (i === at ? changed : r))
      })
    })
    .catch(() => undefined)
}

export const register: Register = on => {
  let hits = 0
  let beats: number[] = []
  let phases: Health[] = []
  // Activity heard while no turn was known to run, now and per sample.
  let stray = 0
  let strays: number[] = []
  let ticking = false
  let lastError = false
  const running = new Set<string>()


  // Working: a turn is running, or anything moved in the last ~1.2 s (model calls the app makes
  // between turns, a turn that began before this module loaded).
  const isBusy = () => stray > 0 || strays.slice(-RECENT_SAMPLES).some(b => b > 0)

  const bump = (n: number) => {
    hits += n
    if (running.size === 0) {
      stray += n
    }
  }

  const healthNow = (isWorking = false): Health =>
    running.size > 0 || isWorking || isBusy() ? 'working' : lastError ? 'error' : 'idle'

  let tickCount = 0
  on('session.start', async ($, e, next) => {
    // A theme goes with the module that set it, so a reload or a new start puts the project's back
    // straight away from what was stored; the walk below finds it fresh for a new project.
    const known = await read($, brandAtom)
    if (known !== null && known.root === projectRoot(e.cwd)) {
      await wear($, known)
    }

    // After a reload: keep only runs whose agent is still at work.
    const live = await $.agent.list().catch(() => [])
    const atWork = new Set(live.filter(a => a.status === 'running' || a.status === 'pending' || a.status === 'waiting').map(a => a.id))
    await update($, crewAtom, runs => crewOf(runs).filter(r => r.state === 'working' && atWork.has(r.agentId)))

    if (!ticking) {
      ticking = true
      const stored = await read($, pulse)
      beats = (stored.beats ?? []).slice(-SAMPLES)
      phases = (stored.phases ?? []).slice(-SAMPLES)

      // The walk for a logo runs off the start, so the first prompt never waits on it.
      $.clock.after(0, () => refreshBrand($, e.cwd))

      $.clock.every(SAMPLE_MS, async () => {
        tickCount++
        if (tickCount % CWD_EVERY === 0) {
          void refreshBrand($, await $.session.cwd())
        }

        // A finished run leaves the band a few seconds after it ends.
        const crew = await readCrew($)
        if (crew.some(r => r.endedAt !== null)) {
          const now = await $.clock.now()
          if (crew.some(r => r.endedAt !== null && now - r.endedAt > DONE_MS)) {
            await update($, crewAtom, runs => crewOf(runs).filter(r => r.endedAt === null || now - r.endedAt <= DONE_MS))
          }
        }

        const sample = hits
        const health = healthNow()
        hits = 0
        strays = [...strays, stray].slice(-SAMPLES)
        stray = 0
        const before = await read($, pulse)
        const wasFlat = beats.every(b => b === 0)

        beats = [...beats, sample].slice(-SAMPLES)
        phases = [...phases, health].slice(-SAMPLES)

        // Nothing to move: skip the redraw so an idle session costs nothing.
        if (sample === 0 && wasFlat && before.health === health && before.beats.length > 0) {
          return
        }

        await update($, pulse, () => ({ health, beats, phases }))
      })
    }

    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    running.add(e.turnId)

    if (e.agentId === undefined) {
      lastError = false
    } else {
      void setRun($, e.agentId, { status: 'starting', state: 'working', endedAt: null })
    }

    hits += 2
    await update($, pulse, p => ({ ...p, health: healthNow() }))

    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    running.delete(e.turnId)

    if (e.agentId === undefined) {
      lastError = e.reason === 'error'
    } else {
      const failed = e.reason === 'error'
      const endedAt = await $.clock.now()
      void setRun($, e.agentId, {
        state: failed ? 'failed' : 'done',
        status: failed ? 'stopped on an error' : e.isAborted ? 'stopped' : 'done',
        endedAt,
      })
    }

    await update($, pulse, p => ({ ...p, health: healthNow() }))

    return next(e)
  })

  on('turn.step', async function* ($, e, next) {
    const stream = next(e)
    let piece = await stream.next()

    while (piece.done !== true) {
      bump(weigh(piece.value))
      yield piece.value
      piece = await stream.next()
    }

    return piece.value
  })

  on('tool.call', ($, e, next) => {
    bump(3)

    if (e.agentId !== undefined) {
      void setRun($, e.agentId, { status: describeCall(e.tool, e as unknown as Record<string, unknown>) })
    }

    return next(e)
  })

  // An Agent call starting a crew member: remember its row, so the bubble can sit under it.
  on('agent.spawn', ($, e, next) => {
    const queue = spawns.get(e.subagentType) ?? []
    spawns.set(e.subagentType, [...queue, e.tool_use_id].slice(-8))

    return next(e)
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) {
      return next(e)
    }

    const cwd = await $.session.cwd()
    const state = await read($, pulse)
    const health: Health = e.props.isWorking ? 'working' : state.health
    const stored = await read($, brandAtom)
    const root = projectRoot(cwd)
    // A brand found for another folder is not this one's: draw the name alone until it is found.
    const brand = stored !== null && stored.root === root ? stored : null
    const name = brand?.name ?? (root === null ? null : root.slice(root.lastIndexOf('/') + 1))
    const lockup = brand?.lockup ?? null
    const repo = subfolder(cwd, root)

    // The crew at work: faces for the latest few, and words for the newest one still working.
    const crew = await readCrew($)
    const shown = crew.slice(-CREW_FACES)
    const lead = [...crew].reverse().find(r => r.state === 'working') ?? crew[crew.length - 1]
    const more = crew.length - shown.length

    // The terminal has no Svg: the name in the brand's colour, a sparkline and a coloured dot.
    if (e.surface === 'terminal') {
      const { Box, Text } = $.ui.resolve(e)
      const width = Math.max(8, Math.min(24, e.props.bodyColumns - 40))
      const accent = brand?.palette?.accent ?? brand?.accent ?? undefined

      return (
        <Box flexDirection="row" justifyContent="space-between" flexGrow={1}>
          <Box flexDirection="row" gap={2}>
            <Box flexDirection="row" gap={1}>
              {name !== null && <Text bold color={accent}>{clean(name, 60)}</Text>}
              {repo !== '' && <Text dimColor>{clean(repo, 60)}</Text>}
            </Box>
            {lead !== undefined && (
              <Box flexDirection="row" gap={1}>
                <Text color={COLOR[lead.state === 'working' ? 'working' : lead.state === 'failed' ? 'error' : 'idle']}>◉</Text>
                <Text bold>{lead.name}</Text>
                <Text dimColor>{lead.status}</Text>
                {crew.length > 1 && <Text dimColor>+{crew.length - 1}</Text>}
              </Box>
            )}
          </Box>
          <Box flexDirection="row" gap={1}>
            <Box flexDirection="row">
              {sparkRuns(state.beats, state.phases ?? [], health, width).map(run => (
                <Text color={COLOR[run.state]}>{run.text}</Text>
              ))}
            </Box>
            <Text color={health === 'idle' ? 'white' : COLOR[health]}>●</Text>
            <Text dimColor>{LABEL[health]}</Text>
          </Box>
        </Box>
      )
    }

    const { Box, Svg, Text } = $.ui.resolve(e)
    const pictures = await Promise.all(shown.map(run => (run.face === null ? null : portrait($, run.face))))

    // The face is never taller than the logo beside it. The room left for the crew is an estimate:
    // the band's cells at about 8px each, less the project on the left and the trace on the right.
    const logo = lockup === null ? 20 : 24
    const left = (lockup === null ? 20 + (name?.length ?? 0) * 8 : lockup.width) + repo.length * 7.5 + 24
    // While the crew is at work the trace narrows to give the bubble room.
    const graphW = lead === undefined ? GRAPH_W : GRAPH_NARROW
    const right = graphW + 16 + LABEL[health].length * 7 + 32
    const room = Math.max(0, e.props.bodyColumns * 8 - left - right)
    // The faces and a speech bubble beside them, all in the band's row: a mod's drawing is clipped
    // to the band, so the bubble can't float above the head without making the band taller.
    const drawn = lead === undefined ? null : crewSvg(shown, pictures, lead, { size: logo, room })
    const said = shown.map(run => `${run.name}${run.title === null ? '' : `, ${run.title.toLowerCase()}`}: ${run.status}`).join('; ')

    return (
      <Box flexDirection="row" justifyContent="space-between" alignItems="center" flexGrow={1}>
        {/* The project on the left, and the crew at work right after it. */}
        <Box flexDirection="row" flexWrap="nowrap" alignItems="center" gap={2}>
          {/* Logo, name and repo side by side, one row that never wraps; each a direct child. */}
          <Box flexDirection="row" flexWrap="nowrap" flexShrink={0} alignItems="center" gap={1}>
            {lockup !== null && <Svg source={lockup.source} alt={name ?? 'Project'} width={lockup.width} height={24} />}
            {lockup === null && <Svg source={brand?.logo ?? CRITTER} alt={name === null ? 'Claude Code' : `${name} logo`} width={20} height={20} />}
            {lockup === null && name !== null && <Text bold>{name}</Text>}
            {repo !== '' && <Text dimColor>{repo}</Text>}
          </Box>
          {drawn !== null && (
            <Box flexDirection="row" flexWrap="nowrap" alignItems="center" gap={1}>
              <Svg source={drawn.source} alt={said} width={drawn.width} height={drawn.height} />
              {more > 0 && <Text dimColor>+{more}</Text>}
            </Box>
          )}
        </Box>
        <Box flexDirection="row" alignItems="center" gap={1}>
          <Svg source={graphSvg(state.beats, state.phases ?? [], health, graphW)} alt={`Session activity, ${LABEL[health]}`} width={graphW} height={GRAPH_H} />
          <Svg source={dotSvg(health)} alt={`Session ${LABEL[health]}`} width={16} height={16} />
          <Text dimColor>{LABEL[health]}</Text>
        </Box>
      </Box>
    )
  })
}
