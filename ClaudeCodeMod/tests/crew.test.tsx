import { expect, mock, test } from 'claude-code/testing'
import type { AgentInfo, On } from 'claude-code'

const INSIDE = '/Users/sam/Desktop/LobsterOne/Robocog---Mac'

const BAND = (surface: 'terminal' | 'desktop', columns = 160) =>
  ({
    plugin: 'lobsterone',
    surface,
    component: 'AbovePrompt',
    props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 10, bodyColumns: columns, scroll: { offset: 0, bodyRows: 10 }, view: {} },
  }) as const

const WREN = `---
name: security-reviewer
description: "Wren. Reads a change for security problems before it ships."
tools: Read, Grep, Glob, Bash
lobsterone-crew: 1
lobsterone-name: "Wren"
lobsterone-face: wren
lobsterone-title: "Security reviewer"
---

You are Wren.
`

const PLAIN = `---
name: helper
description: "The person's own agent."
---
`

// The crew's drawing in a mounted desktop band, found by what it says.
type Mounted = { findAll: (q: { type: string }) => Promise<{ props: Record<string, unknown> }[]> }
const crewDrawing = async (ui: Mounted) => (await ui.findAll({ type: 'Svg' })).find(svg => /^Wren, /.test(String(svg.props.alt)))

const END = { answer: '', durationMs: 10, isAborted: false } as const

// A session with two subagents running: Wren, hired by the app, and an agent of the person's own.
const AGENTS = [
  { id: 'a-wren', type: 'security-reviewer', description: 'review', status: 'running' },
  { id: 'a-helper', type: 'helper', description: 'help', status: 'running' },
]

// `projectAgents`: agent files the project itself has in .claude/agents.
const engine = (on: On, agents = AGENTS, projectAgents: string[] = []) => {
  on('fs.exists', (_, e) => ({ value: projectAgents.some(name => e.path === `${INSIDE}/.claude/agents/${name}.md`) }))
  on('session.cwd', () => ({ value: INSIDE }))
  on('session.root', () => ({ value: INSIDE }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('theme.set', () => ({ value: { isDrawn: true, requestId: 'theme' } }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('tool.call', () => ({ result: {} }))
  on('env.get', () => ({ value: '/Users/sam' }))
  on('agent.list', () => ({ value: agents as unknown as AgentInfo[] }))
  on('fs.read', (_, e) => {
    if (e.path === '/Users/sam/.claude/agents/security-reviewer.md') return { value: WREN }
    if (e.path === '/Users/sam/.claude/agents/helper.md') return { value: PLAIN }
    // A cloned repo's own agent, dressed as Wren.
    if (e.path === `${INSIDE}/.claude/agents/impostor.md`) return { value: WREN }
    if (e.path.endsWith('/crew-wren.jpg') && e.as === 'bytes') return { value: { base64: 'V1JFTg==' } }
    throw new Error('ENOENT')
  })
}

test('a crew member at work shows its face, name and what it is reading', async ($, on) => {
  engine(on)
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'review the diff', turnId: 'w1', agentId: 'a-wren' })
  await $.tool.call({ tool: 'Read', file_path: `${INSIDE}/Sources/LobsterOne/Services/AuthService.swift`, agentId: 'a-wren' })
  await clock.advance(400)

  const ui = await $.ui.mount(BAND('desktop'))
  const drawing = await crewDrawing(ui)
  const source = String(drawing?.props.source)

  expect(source).toContain('data:image/jpeg;base64,V1JFTg==')
  expect(source).toContain('<tspan class="name">Wren</tspan>')
  expect(source).toContain('<tspan class="say" dx="6">reading AuthService.swift</tspan>')
  // No taller than the LobsterOne lockup beside it.
  expect(Number(drawing?.props.height)).toBeLessThanOrEqual(24)
  expect(String(drawing?.props.alt)).toBe('Wren, security reviewer: reading AuthService.swift')
  await ui.unmount()

  const terminal = await $.ui.mount(BAND('terminal'))
  expect(await terminal.find({ type: 'Text', text: /^Wren$/ })).toBeDefined()
  await terminal.unmount()
})

test("the person's own agents and the main loop never show", async ($, on) => {
  engine(on)
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'go', turnId: 'm1' })
  await $.turn.start({ text: 'help', turnId: 'h1', agentId: 'a-helper' })
  await $.tool.call({ tool: 'Bash', command: 'ls', agentId: 'a-helper' })
  await clock.advance(400)

  const ui = await $.ui.mount(BAND('desktop'))
  expect(await ui.findAll({ type: 'Svg' })).toHaveLength(3)
  await ui.unmount()
})

test('a command shows its first words and never an inline value', async ($, on) => {
  engine(on)
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'review', turnId: 'w1', agentId: 'a-wren' })
  await $.tool.call({ tool: 'Bash', command: 'TOKEN=abc123 git diff --stat', agentId: 'a-wren' })
  await clock.advance(400)

  const ui = await $.ui.mount(BAND('desktop'))
  const drawing = await crewDrawing(ui)
  expect(String(drawing?.props.alt)).toBe('Wren, security reviewer: running git diff')
  expect(String(drawing?.props.source)).not.toContain('abc123')
  await ui.unmount()
})

test('a finished run says done, then leaves the band', async ($, on) => {
  engine(on)
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'review', turnId: 'w1', agentId: 'a-wren' })
  await $.turn.complete({ ...END, turnId: 'w1', reason: 'answer', agentId: 'a-wren' })
  await clock.advance(400)

  let ui = await $.ui.mount(BAND('desktop'))
  expect(String((await crewDrawing(ui))?.props.alt)).toMatch(/: done$/)
  await ui.unmount()

  await clock.advance(11_000)
  ui = await $.ui.mount(BAND('desktop'))
  expect(await crewDrawing(ui)).toBeUndefined()
  await ui.unmount()
})

// Each of these once put part of a secret in the band.
const LEAKS: [string, string][] = [
  ["TOKEN='abc def' psql", 'running a command'],
  ['export "API_KEY=sk-live-123"', 'running export'],
  ['mysql --password=hunter2', 'running mysql'],
  ['mysql -phunter2', 'running mysql'],
  ['psql postgres://user:pass@host/db', 'running psql'],
  ['curl https://user:token@example.com', 'running curl'],
  ['echo sk-ant-abcdef', 'running echo'],
  ['TOKEN=a\\ b psql', 'running a command'],
  ["PASS='correct horse battery staple' gpg", 'running a command'],
  ['/usr/bin/git status', 'running git status'],
]

for (const [command, shown] of LEAKS) {
  test(`the band shows "${shown}" for ${command}`, async ($, on) => {
    engine(on)
    const clock = mock.clock(on)
    await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
    await $.turn.start({ text: 'review', turnId: 'w1', agentId: 'a-wren' })
    await $.tool.call({ tool: 'Bash', command, agentId: 'a-wren' })
    await clock.advance(400)

    const ui = await $.ui.mount(BAND('desktop'))
    expect(String((await crewDrawing(ui))?.props.alt)).toBe(`Wren, security reviewer: ${shown}`)
    await ui.unmount()
  })
}

test("a project's own agent dressed as crew never shows", async ($, on) => {
  engine(on, [{ id: 'a-imp', type: 'impostor', description: 'x', status: 'running' }])
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'hi', turnId: 'i1', agentId: 'a-imp' })
  await clock.advance(400)

  const ui = await $.ui.mount(BAND('desktop'))
  expect(await crewDrawing(ui)).toBeUndefined()
  await ui.unmount()
})

test('control characters in a file name never reach the band', async ($, on) => {
  engine(on)
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'terminal', isInteractive: true })
  await $.turn.start({ text: 'review', turnId: 'w1', agentId: 'a-wren' })
  await $.tool.call({ tool: 'Read', file_path: `${INSIDE}/a\u001b]52;c;aGk=\u0007.txt`, agentId: 'a-wren' })
  await clock.advance(400)

  const ui = await $.ui.mount(BAND('terminal'))
  const status = await ui.find({ type: 'Text', text: /^reading/ })
  expect(status?.children.join('')).toBe('reading a]52;c;aGk=.txt')
  await ui.unmount()
})

test('a file name with markup in it is drawn as text, not markup', async ($, on) => {
  engine(on)
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'review', turnId: 'w1', agentId: 'a-wren' })
  await $.tool.call({ tool: 'Read', file_path: `${INSIDE}/<image href="x">&.txt`, agentId: 'a-wren' })
  await clock.advance(400)

  const ui = await $.ui.mount(BAND('desktop'))
  const source = String((await crewDrawing(ui))?.props.source)
  expect(source).toContain('reading &lt;image href=&quot;x&quot;&gt;&amp;.txt')
  expect(source).not.toContain('href="x"')
  await ui.unmount()
})

test("a project's agent under a crew member's name runs as the project's, not as crew", async ($, on) => {
  engine(on, AGENTS, ['security-reviewer'])
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'review', turnId: 'w1', agentId: 'a-wren' })
  await clock.advance(400)

  const ui = await $.ui.mount(BAND('desktop'))
  expect(await crewDrawing(ui)).toBeUndefined()
  await ui.unmount()
})




test('when the band is narrow the name goes first, then the bubble', async ($, on) => {
  engine(on)
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'review', turnId: 'w1', agentId: 'a-wren' })
  await $.tool.call({ tool: 'Read', file_path: `${INSIDE}/crew.ts`, agentId: 'a-wren' })
  await clock.advance(400)

  const sources: string[] = []
  for (const columns of [160, 69, 60]) {
    const ui = await $.ui.mount(BAND('desktop', columns))
    sources.push(String((await crewDrawing(ui))?.props.source))
    await ui.unmount()
  }
  const [wide, narrow, tight] = sources
  expect(wide).toContain('>Wren</tspan>')
  expect(narrow).not.toContain('>Wren</tspan>')
  expect(narrow).toContain('>reading crew.ts</tspan>')
  expect(tight).not.toContain('class="bubble"')
  expect(tight).toContain('data:image/jpeg')
})

test('a long status is cut short before the bubble goes, and the band keeps its height', async ($, on) => {
  engine(on)
  const clock = mock.clock(on)
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'review', turnId: 'w1', agentId: 'a-wren' })
  await $.tool.call({ tool: 'Read', file_path: `${INSIDE}/LobsterOneSaverView.swift`, agentId: 'a-wren' })
  await clock.advance(400)

  const ui = await $.ui.mount(BAND('desktop', 72))
  const drawing = await crewDrawing(ui)
  const source = String(drawing?.props.source)
  expect(source).toContain('class="bubble"')
  expect(source).toMatch(/>reading [^<]*…<\/tspan>/)
  expect(Number(drawing?.props.height)).toBeLessThanOrEqual(24)
  const trace = (await ui.findAll({ type: 'Svg' })).find(svg => String(svg.props.alt).startsWith('Session activity'))
  expect(trace?.props.width).toBe(72)
  await ui.unmount()
})
