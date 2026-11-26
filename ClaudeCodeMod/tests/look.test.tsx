import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const INSIDE = '/Users/sam/Desktop/LobsterOne/Robocog---Mac'
const OUTSIDE = '/Users/sam/Desktop/LobsterOneOther'

const BAND = (surface: 'terminal' | 'desktop') =>
  ({
    plugin: 'lobsterone',
    surface,
    component: 'AbovePrompt',
    props: { hasSurvey: false, isCollapsed: false, isWorking: false, maxRows: 10, bodyColumns: 80, scroll: { offset: 0, bodyRows: 10 }, view: {} },
  }) as const

// The engine beneath: a session in `cwd`, turns that echo their id.
const engine = (on: On, cwd: string) => {
  on('session.cwd', () => ({ value: cwd }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('theme.set', () => ({ value: { isDrawn: true, requestId: 'theme' } }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
}

const END = { answer: '', durationMs: 10, isAborted: false } as const

// LobsterOne's own .claude/brand.json, as the app's repo keeps it.
const BRAND = JSON.stringify({
  name: 'LobsterOne',
  lockup: '.claude/brand/lockup.svg',
  colors: {
    accent: '#C84B20',
    success: '#3F7D66',
    light: { 'surface-0': '#F5F0EA', 'surface-1': '#FAF7F3', 'surface-2': '#FFFFFF', 'text-primary': '#0A0A0A' },
    dark: { 'surface-0': '#141210', 'surface-1': '#1B1916', 'surface-2': '#221F1B', 'text-primary': '#F5F0EA' },
  },
})
const LOCKUP = '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 132 24"><text>LobsterOne</text></svg>'

test('a project with a brand.json wears its colours, and its lockup leads the band', async ($, on) => {
  const ROOT = '/Users/sam/Desktop/LobsterOne'
  const themes: unknown[] = []
  on('session.cwd', () => ({ value: `${ROOT}/Robocog---Mac` }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('theme.set', (_, e) => {
    themes.push(e.colors)
    return { value: { isDrawn: true, requestId: 'theme' } }
  })
  on('fs.read', (_, e) => {
    if (e.path === `${ROOT}/.claude/brand.json`) return { value: BRAND }
    if (e.path === `${ROOT}/.claude/brand/lockup.svg`) return { value: LOCKUP }
    throw new Error('ENOENT')
  })
  const clock = mock.clock(on)
  await $.session.start({ cwd: `${ROOT}/Robocog---Mac`, surface: 'desktop', isInteractive: true })
  await clock.advance(10)

  expect(themes).toHaveLength(1)
  expect(JSON.stringify(themes[0])).toContain('#')
  const ui = await $.ui.mount(BAND('desktop'))
  const lead = (await ui.findAll({ type: 'Svg' }))[0]
  expect(String(lead?.props.source).startsWith('<svg')).toBe(true)
  expect(lead?.props.width).toBe(132)
  expect(lead?.props.alt).toBe('LobsterOne')
  expect(await ui.find({ type: 'Text', text: /Robocog---Mac/ })).toBeDefined()
  await ui.unmount()
})

test("a project whose logo has a colour is themed from it", async ($, on) => {
  const ROOT = '/Users/sam/Desktop/Acme'
  const themes: unknown[] = []
  on('session.cwd', () => ({ value: ROOT }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('theme.set', (_, e) => {
    themes.push(e.colors)
    return { value: { isDrawn: true, requestId: 'theme' } }
  })
  on('fs.list', (_, e) => ({ value: e.path === ROOT ? [{ name: 'logo.svg', kind: 'file', size: 60, mtimeMs: 0, isLink: false }] : [] }))
  on('fs.read', (_, e) => {
    if (e.path === `${ROOT}/logo.svg`) return { value: e.as === 'bytes' ? { base64: 'PHN2Zy8+' } : '<svg><path fill="#5B8DEF"/></svg>' }
    throw new Error('ENOENT')
  })
  const clock = mock.clock(on)
  await $.session.start({ cwd: ROOT, surface: 'desktop', isInteractive: true })
  await clock.advance(10)

  expect(themes).toHaveLength(1)
})

test('a project with no colours of its own keeps the app look', async ($, on) => {
  const ROOT = '/Users/sam/Documents/Projects/vivi'
  const calls: string[] = []
  on('session.cwd', () => ({ value: ROOT }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('theme.set', () => {
    calls.push('set')
    return { value: { isDrawn: true, requestId: 'theme' } }
  })
  on('theme.clear', () => {
    calls.push('clear')
    return { value: { isDrawn: false, reason: 'cleared' } }
  })
  const clock = mock.clock(on)
  await $.session.start({ cwd: ROOT, surface: 'desktop', isInteractive: true })
  await clock.advance(10)

  // Nothing set, and nothing cleared: a clear would take down another mod's theme.
  expect(calls).toEqual([])
})

test('a session elsewhere keeps the app look', async ($, on) => {
  const labels: string[] = []
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('theme.set', () => {
    labels.push('set')

    return { value: { isDrawn: true, requestId: 'theme' } }
  })

  await $.session.start({ cwd: OUTSIDE, surface: 'desktop', isInteractive: true })

  expect(labels).toEqual([])
})

for (const surface of ['terminal', 'desktop'] as const) {
  test(`the band shows the repo and an idle dot on ${surface}`, async ($, on) => {
    engine(on, INSIDE)
    const ui = await $.ui.mount(BAND(surface))

    expect(await ui.find({ type: 'Text', text: /Robocog---Mac/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /^idle$/ })).toBeDefined()
    await ui.unmount()
  })

  test(`a running turn turns the dot green on ${surface}`, async ($, on) => {
    engine(on, INSIDE)
    await $.turn.start({ text: 'go', turnId: 't1' })
    const ui = await $.ui.mount(BAND(surface))

    expect(await ui.find({ type: 'Text', text: /^working$/ })).toBeDefined()
    await ui.unmount()
  })

  test(`a turn that dies on an error turns it red until the next on ${surface}`, async ($, on) => {
    engine(on, INSIDE)
    await $.turn.start({ text: 'go', turnId: 't1' })
    await $.turn.complete({ ...END, turnId: 't1', reason: 'error' })
    let ui = await $.ui.mount(BAND(surface))

    expect(await ui.find({ type: 'Text', text: /^error$/ })).toBeDefined()
    await ui.unmount()

    await $.turn.start({ text: 'again', turnId: 't2' })
    await $.turn.complete({ ...END, turnId: 't2', reason: 'answer' })
    ui = await $.ui.mount(BAND(surface))

    expect(await ui.find({ type: 'Text', text: /^idle$/ })).toBeDefined()
    await ui.unmount()
  })

  test(`another project shows its own name and repo on ${surface}`, async ($, on) => {
    engine(on, '/Users/sam/Desktop/TigerSoup/TigerSoup---Frontend')
    const ui = await $.ui.mount(BAND(surface))

    expect(await ui.find({ type: 'Text', text: /^TigerSoup$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /TigerSoup---Frontend/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /LobsterOne/ })).toBeUndefined()
    await ui.unmount()
  })

  test(`outside any project the band keeps only the health on ${surface}`, async ($, on) => {
    engine(on, '/Users/sam/Library/Application Support/Claude')
    const ui = await $.ui.mount(BAND(surface))

    expect(await ui.find({ type: 'Text', text: /^idle$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Claude|Library/ })).toBeUndefined()
    await ui.unmount()
  })
}

test('activity outside any turn turns the dot green, then it settles to idle', async ($, on) => {
  engine(on, INSIDE)
  const clock = mock.clock(on)
  on('tool.call', () => ({ result: {} }))
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  await clock.advance(400)

  let ui = await $.ui.mount(BAND('desktop'))
  expect(await ui.find({ type: 'Text', text: /^working$/ })).toBeDefined()
  await ui.unmount()

  await clock.advance(2000)
  ui = await $.ui.mount(BAND('desktop'))
  expect(await ui.find({ type: 'Text', text: /^idle$/ })).toBeDefined()
  await ui.unmount()
})

test('a burst from a finished turn keeps its green while the head goes grey', async ($, on) => {
  engine(on, INSIDE)
  const clock = mock.clock(on)
  on('tool.call', () => ({ result: {} }))
  await $.session.start({ cwd: INSIDE, surface: 'desktop', isInteractive: true })
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.tool.call({ tool: 'Bash', command: 'ls' })
  await clock.advance(400)
  await $.turn.complete({ ...END, turnId: 't1', reason: 'answer' })
  await clock.advance(800)

  const ui = await $.ui.mount(BAND('desktop'))
  const svgs = await ui.findAll({ type: 'Svg' })
  const trace = String(svgs[1]?.props.source)

  expect(await ui.find({ type: 'Text', text: /^idle$/ })).toBeDefined()
  expect(trace).toContain('stroke="#2FA36B"')
  expect(trace).toContain('stroke="#A8A097" stroke-width="1.5"')
  await ui.unmount()
})

test('a stored 0.2.0 pulse with no phases still draws', async ($, on) => {
  engine(on, INSIDE)
  on('state.get', () => ({ value: { value: { health: 'idle', beats: [0, 3, 5] }, version: 1 } }))
  const ui = await $.ui.mount(BAND('desktop'))

  expect(await ui.find({ type: 'Text', text: /^idle$/ })).toBeDefined()
  await ui.unmount()
})

test('a project found on disk draws its favicon, from the repo the session is in first', async ($, on) => {
  const ROOT = '/Users/sam/Desktop/OnReplay'
  const tree: Record<string, { name: string; kind: 'file' | 'dir'; size: number }[]> = {
    [ROOT]: [
      { name: 'Astro', kind: 'dir', size: 0 },
      { name: 'Expo', kind: 'dir', size: 0 },
      { name: 'node_modules', kind: 'dir', size: 0 },
      { name: 'README.md', kind: 'file', size: 20 },
    ],
    [`${ROOT}/Astro`]: [{ name: 'public', kind: 'dir', size: 0 }],
    [`${ROOT}/Astro/public`]: [{ name: 'favicon.svg', kind: 'file', size: 60 }],
    [`${ROOT}/Expo`]: [{ name: 'assets', kind: 'dir', size: 0 }],
    [`${ROOT}/Expo/assets`]: [{ name: 'icon.png', kind: 'file', size: 4000 }],
  }
  const listed: string[] = []
  on('fs.list', (_, e) => {
    const dir = String(e.path)
    listed.push(dir)
    return { value: (tree[dir] ?? []).map(entry => ({ ...entry, mtimeMs: 0, isLink: false })) }
  })
  on('fs.read', (_, e) => {
    if (e.path.endsWith('README.md')) return { value: '# OnReplay\n' }
    return { value: e.as === 'bytes' ? { base64: 'PHN2Zy8+' } : '<svg fill="#E5484D"/>' }
  })
  engine(on, `${ROOT}/Astro`)
  const clock = mock.clock(on)
  await $.session.start({ cwd: `${ROOT}/Astro`, surface: 'desktop', isInteractive: true })
  await clock.advance(10)

  const desktop = await $.ui.mount(BAND('desktop'))
  const logo = String((await desktop.findAll({ type: 'Svg' }))[0]?.props.source)
  expect(logo).toContain('data:image/svg+xml;base64,PHN2Zy8+')
  expect(await desktop.find({ type: 'Text', text: /^OnReplay$/ })).toBeDefined()
  await desktop.unmount()

  // The terminal has no picture: the name takes the logo's colour.
  const terminal = await $.ui.mount(BAND('terminal'))
  expect((await terminal.find({ type: 'Text', text: /^OnReplay$/ }))?.props.color).toBe('#E5484D')
  await terminal.unmount()

  expect(listed).not.toContain(`${ROOT}/node_modules`)
})

test('a project with no logo gets the pixel creature', async ($, on) => {
  engine(on, '/Users/sam/Documents/Projects/vivi')
  const ui = await $.ui.mount(BAND('desktop'))
  const svgs = await ui.findAll({ type: 'Svg' })

  expect(String(svgs[0]?.props.source)).toContain('fill="#D97757"')
  expect(await ui.find({ type: 'Text', text: /^vivi$/ })).toBeDefined()
  await ui.unmount()
})

test('outside any project the creature stands in on the left', async ($, on) => {
  engine(on, '/Users/sam/Library/Application Support/Claude')
  const ui = await $.ui.mount(BAND('desktop'))
  const svgs = await ui.findAll({ type: 'Svg' })

  expect(svgs.length).toBe(3)
  expect(String(svgs[0]?.props.source)).toContain('fill="#D97757"')
  await ui.unmount()
})

test('the logo and the name sit side by side in one row', async ($, on) => {
  engine(on, '/Users/sam/Desktop/OnReplay')
  const ui = await $.ui.mount(BAND('desktop'))
  const boxes = await ui.findAll({ type: 'Box' })
  const left = boxes.find(box => box.props.flexShrink === 0)
  const kinds = ((left?.children ?? []) as { type: string }[]).map(child => child.type)

  expect(left?.props.flexDirection).toBe('row')
  expect(left?.props.flexWrap).toBe('nowrap')
  expect(kinds).toEqual(['Svg', 'Text'])
  expect(await ui.find({ type: 'Text', text: /^OnReplay$/ })).toBeDefined()
  await ui.unmount()
})

test('moving to a project with no colours takes down the theme this mod set, once', async ($, on) => {
  const ROOT = '/Users/sam/Desktop/LobsterOne'
  let cwd = `${ROOT}/Robocog---Mac`
  const calls: string[] = []
  on('session.cwd', () => ({ value: cwd }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('theme.set', () => {
    calls.push('set')
    return { value: { isDrawn: true, requestId: 'theme' } }
  })
  on('theme.clear', () => {
    calls.push('clear')
    return { value: { isDrawn: false, reason: 'cleared' } }
  })
  on('fs.read', (_, e) => {
    if (e.path === `${ROOT}/.claude/brand.json`) return { value: BRAND }
    throw new Error('ENOENT')
  })
  const clock = mock.clock(on)
  await $.session.start({ cwd, surface: 'desktop', isInteractive: true })
  await clock.advance(10)

  cwd = '/Users/sam/Documents/Projects/vivi'
  await clock.advance(5000)
  await clock.advance(5000)

  expect(calls).toEqual(['set', 'clear'])
})
