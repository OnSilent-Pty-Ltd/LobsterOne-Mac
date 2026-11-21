import type { EngineInterface } from 'claude-code'

import type { Brand, BrandMode, Palette } from '../types'

// Folders that hold projects rather than being one: ~/Desktop/OnReplay, ~/Documents/Projects/vivi.
const CONTAINERS = /^(desktop|documents|downloads|projects|code|dev|src|repos|repositories|workspace|workspaces|sites|github|developer|work|clients)$/i

// Never a project: the app's own folders, caches, dotfolders.
const NOT_PROJECTS = /^(library|applications|\..*)$/i

// Folders not worth walking into for a logo.
const SKIP = /^(node_modules|pods|build|dist|out|target|coverage|vendor|deriveddata|\.?venv|__pycache__|tmp|temp|archive.*|backup.*|screenshots?|test|tests|__tests__|fixtures?|examples?|storybook-static|\..*)$/i

const MAX_DEPTH = 4
const MAX_DIRS = 400

// Square marks first: they read at 20 px, where a wide wordmark doesn't.
const CANDIDATES: { pattern: RegExp; score: number; format: 'svg' | 'png' }[] = [
  { pattern: /^favicon\.svg$/i, score: 100, format: 'svg' },
  { pattern: /^(icon|mark|logo-?mark|logomark|brandmark)\.svg$/i, score: 95, format: 'svg' },
  { pattern: /^apple-touch-icon.*\.png$/i, score: 88, format: 'png' },
  { pattern: /^logo.*\.svg$/i, score: 80, format: 'svg' },
  { pattern: /^favicon.*\.png$/i, score: 75, format: 'png' },
  { pattern: /^(icon|app-?icon)\.png$/i, score: 72, format: 'png' },
  { pattern: /^logo.*\.png$/i, score: 65, format: 'png' },
]

// What an Svg element can carry: its source is held to 131,072 characters, base64 grows by a third.
const MAX_BYTES = { svg: 90_000, png: 90_000 }

/** The home folder a path sits in, and the parts below it. */
const splitHome = (path: string) => {
  const match = /^(\/Users\/[^/]+|\/home\/[^/]+)((?:\/[^/]+)*)\/?$/.exec(path)

  return match === null ? null : { home: match[1]!, parts: match[2]!.split('/').filter(Boolean) }
}

/** The project a folder belongs to: the first folder below the containers, or null. */
export const projectRoot = (cwd: string): string | null => {
  const split = splitHome(cwd)

  if (split === null || split.parts.length === 0 || NOT_PROJECTS.test(split.parts[0]!)) {
    return null
  }

  let i = 0
  while (i < split.parts.length - 1 && CONTAINERS.test(split.parts[i]!)) {
    i++
  }

  const name = split.parts[i]!

  return CONTAINERS.test(name) ? null : `${split.home}/${split.parts.slice(0, i + 1).join('/')}`
}

const baseName = (path: string) => path.slice(path.lastIndexOf('/') + 1)

const squash = (text: string) => text.toLowerCase().replace(/[^a-z0-9]/g, '')

/** The folder's name, or the README title's spelling of it ("vivi" → "Vivi"). */
async function projectName($: EngineInterface, root: string) {
  const folder = baseName(root)

  try {
    const readme = await $.fs.read(`${root}/README.md`, { length: 2048 })
    const title = /^#\s+(.+?)\s*$/m.exec(String(readme))?.[1]

    if (title !== undefined && squash(title) === squash(folder)) {
      return title
    }
  } catch {
    // No README: the folder's name stands.
  }

  return folder
}

type Found = { path: string; score: number; format: 'svg' | 'png' }

/** The best-scoring logo under the root, walked breadth first and bounded. */
async function findLogo($: EngineInterface, root: string, cwd: string): Promise<Found | null> {
  const queue: { dir: string; depth: number }[] = [{ dir: root, depth: 0 }]
  let best: Found | null = null
  let walked = 0

  while (queue.length > 0 && walked < MAX_DIRS) {
    const { dir, depth } = queue.shift()!
    walked++

    let entries
    try {
      entries = await $.fs.list(dir)
    } catch {
      continue
    }

    for (const entry of entries) {
      const path = `${dir}/${entry.name}`

      if (entry.kind === 'dir') {
        if (depth < MAX_DEPTH && !SKIP.test(entry.name)) {
          queue.push({ dir: path, depth: depth + 1 })
        }
        continue
      }

      const candidate = entry.kind === 'file' ? CANDIDATES.find(c => c.pattern.test(entry.name)) : undefined

      if (candidate === undefined || entry.size === 0 || entry.size > MAX_BYTES[candidate.format]) {
        continue
      }

      let score = candidate.score - depth * 3
      // The repo the session is in speaks for itself first.
      if (cwd !== root && path.startsWith(`${cwd}/`)) {
        score += 6
      }
      if (/\/(brand|branding|logos?)(\/|$)/i.test(dir)) {
        score += 4
      }
      if (/(dark|white|inverse|mono|black|old|legacy|draft|copy)/i.test(entry.name)) {
        score -= 15
      }

      if (best === null || score > best.score) {
        best = { path, score, format: candidate.format }
      }
    }
  }

  return best
}

/** The first saturated colour an SVG fills or strokes with, for the terminal's name. */
const accentOf = (svg: string) => {
  for (const [, hex] of svg.matchAll(/#([0-9a-f]{6})\b/gi)) {
    const n = parseInt(hex!, 16)
    const [r, g, b] = [(n >> 16) & 255, (n >> 8) & 255, n & 255]
    const max = Math.max(r, g, b)
    const min = Math.min(r, g, b)

    if (max - min > 60 && max > 70) {
      return `#${hex!.toUpperCase()}`
    }
  }

  return null
}

/** The logo boxed in a 20 px square drawing, its proportions kept. */
const boxed = (format: 'svg' | 'png', base64: string) => {
  const type = format === 'svg' ? 'image/svg+xml' : 'image/png'

  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" width="20" height="20"><image href="data:${type};base64,${base64}" x="0" y="0" width="20" height="20" preserveAspectRatio="xMidYMid meet"/></svg>`
}

// The stand-in for a project with no logo: a little pixel creature in Claude's terracotta,
// drawn on a 12 by 10 grid. B is body, E an eye, anything else empty.
const CRITTER_ROWS = [
  '...BBBBBB...',
  '..BBBBBBBB..',
  '..BBEBBEBB..',
  '..BBEBBEBB..',
  'BBBBBBBBBBBB',
  'BBBBBBBBBBBB',
  '..BBBBBBBB..',
  '..BBBBBBBB..',
  '..B.B..B.B..',
  '..B.B..B.B..',
]

const pixels = (mark: string) =>
  CRITTER_ROWS.flatMap((row, y) => [...row].map((cell, x) => (cell === mark ? `M${x} ${y}h1v1h-1z` : ''))).join('')

/** The pixel creature, square, crisp at any size; its eyes blink now and then. */
export const CRITTER = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-1 -2 14 14" width="20" height="20" shape-rendering="crispEdges"><path fill="#D97757" d="${pixels('B')}"/><path fill="#141210" d="${pixels('E')}"><animate attributeName="opacity" values="1;1;0;1" keyTimes="0;0.94;0.97;1" dur="4.5s" repeatCount="indefinite"/></path></svg>`

// A project states its brand in .claude/brand.json, in the repo the session is in or at the
// project's root; it wins over anything guessed. Paths in it are relative to the project root.
//
//   {
//     "name": "LobsterOne",
//     "logo": "brand/mark.svg",
//     "lockup": "brand/lockup.svg",
//     "colors": {
//       "accent": "#C84B20", "success": "#3F7D66",
//       "light": { "surface-0": "#F5F0EA", "text-primary": "#0A0A0A" },
//       "dark": { "surface-0": "#141210", "text-primary": "#F5F0EA" }
//     }
//   }
//
// Everything but "name" is optional. A file that doesn't parse is ignored, as if absent.
const BRAND_FILE = '.claude/brand.json'

const HEX = /^#[0-9a-fA-F]{6}$/
const ROLES = ['accent', 'success', 'danger', 'warning', 'pro'] as const
const ANCHORS = ['surface-0', 'surface-1', 'surface-2', 'surface-3', 'text-primary', 'text-secondary', 'text-muted'] as const

// A path in the brand file, kept inside the project: no absolute paths, no way up.
const inside = (root: string, path: unknown) =>
  typeof path === 'string' && path !== '' && !path.startsWith('/') && !path.split('/').includes('..') ? `${root}/${path}` : null

const modeOf = (value: unknown): BrandMode | undefined => {
  if (typeof value !== 'object' || value === null) {
    return undefined
  }
  const mode: BrandMode = {}
  for (const anchor of ANCHORS) {
    const hex = (value as Record<string, unknown>)[anchor]
    if (typeof hex === 'string' && HEX.test(hex)) {
      mode[anchor] = hex
    }
  }
  // makeColors needs both of these to use a mode at all.
  return mode['surface-0'] !== undefined && mode['text-primary'] !== undefined ? mode : undefined
}

const paletteOf = (colors: unknown): Palette | null => {
  if (typeof colors !== 'object' || colors === null) {
    return null
  }
  const given = colors as Record<string, unknown>
  if (typeof given.accent !== 'string' || !HEX.test(given.accent)) {
    return null
  }
  const palette: Palette = { accent: given.accent }
  for (const role of ROLES) {
    const hex = given[role]
    if (typeof hex === 'string' && HEX.test(hex)) {
      palette[role] = hex
    }
  }
  const light = modeOf(given.light)
  const dark = modeOf(given.dark)
  if (light !== undefined) palette.light = light
  if (dark !== undefined) palette.dark = dark
  return palette
}

// A wide lockup's width at the band's 24 px height, from its viewBox; capped so it can't crowd the band.
const lockupWidth = (svg: string) => {
  const box = /viewBox\s*=\s*"\s*[-\d.]+[\s,]+[-\d.]+[\s,]+([\d.]+)[\s,]+([\d.]+)\s*"/.exec(svg)
  const ratio = box === null ? 0 : Number(box[1]) / Number(box[2])
  return ratio > 0 && Number.isFinite(ratio) ? Math.min(220, Math.round(24 * ratio)) : null
}

type BrandFile = { name: string; logo: string | null; lockup: string | null; palette: Palette | null }

/** The project's brand.json, from the repo the session is in first, then the project root; null if none parses. */
async function readBrandFile($: EngineInterface, root: string, cwd: string): Promise<(BrandFile & { at: string }) | null> {
  const repo = cwd.startsWith(`${root}/`) ? `${root}/${cwd.slice(root.length + 1).split('/')[0]}` : null
  for (const at of [repo, root]) {
    if (at === null) {
      continue
    }
    try {
      const raw = JSON.parse(String(await $.fs.read(`${at}/${BRAND_FILE}`))) as Record<string, unknown>
      const name = typeof raw.name === 'string' ? raw.name.replace(/[\u0000-\u001f\u007f-\u009f]/g, '').trim().slice(0, 60) : ''
      if (name === '') {
        continue
      }
      return { at, name, logo: inside(at, raw.logo), lockup: inside(at, raw.lockup), palette: paletteOf(raw.colors) }
    } catch {
      // Absent or not JSON: try the next place, then guess.
    }
  }
  return null
}

/** A logo file as the band's 20 px drawing, or null when it can't be read or is too big. */
async function logoFrom($: EngineInterface, path: string): Promise<{ logo: string; svg: string | null } | null> {
  const format = /\.svg$/i.test(path) ? 'svg' : /\.png$/i.test(path) ? 'png' : null
  if (format === null) {
    return null
  }
  try {
    const { base64 } = (await $.fs.read(path, { as: 'bytes' })) as { base64: string }
    if (base64.length > (MAX_BYTES[format] * 4) / 3) {
      return null
    }
    return { logo: boxed(format, base64), svg: format === 'svg' ? String(await $.fs.read(path)) : null }
  } catch {
    return null
  }
}

/** The project's name, logo, colours and lockup, from its brand.json or found on disk; null outside a project. */
export async function discover($: EngineInterface, cwd: string): Promise<Brand | null> {
  const root = projectRoot(cwd)

  if (root === null) {
    return null
  }

  const file = await readBrandFile($, root, cwd)
  if (file !== null) {
    const drawn = file.logo === null ? null : await logoFrom($, file.logo)
    let lockup: Brand['lockup'] = null
    if (file.lockup !== null && /\.svg$/i.test(file.lockup)) {
      const svg = await $.fs.read(file.lockup).then(String).catch(() => null)
      const width = svg === null || svg.length > MAX_BYTES.svg ? null : lockupWidth(svg)
      // Drawn as an Svg element's source, which starts at <svg: no XML prolog or comments before it.
      const at = svg === null ? -1 : svg.indexOf('<svg')
      lockup = svg === null || width === null || at < 0 ? null : { source: svg.slice(at), width }
    }
    const accent = file.palette?.accent ?? (drawn?.svg == null ? null : accentOf(drawn.svg))
    return {
      root,
      name: file.name,
      logo: drawn?.logo ?? CRITTER,
      logoPath: drawn === null ? null : file.logo,
      accent,
      lockup,
      palette: file.palette ?? (accent === null ? null : { accent }),
      fromFile: true,
    }
  }

  const [name, found] = await Promise.all([projectName($, root), findLogo($, root, cwd)])
  const drawn = found === null ? null : await logoFrom($, found.path)
  const accent = drawn?.svg == null ? null : accentOf(drawn.svg)

  return {
    root,
    name,
    logo: drawn?.logo ?? CRITTER,
    logoPath: drawn === null ? null : found?.path ?? null,
    accent,
    lockup: null,
    palette: accent === null ? null : { accent },
    fromFile: false,
  }
}
