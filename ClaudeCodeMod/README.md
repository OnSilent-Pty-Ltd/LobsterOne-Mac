# LobsterOne for Claude Code

The band LobsterOne adds above Claude Code's prompt, and the look it gives each session.

- Your project's name and logo on the left, and the repo you're in.
- A live trace of what Claude is doing, and a dot: working, idle or error.
- Your LobsterOne crew while they work: a face and a speech bubble saying what they're doing.
- The session in your project's colours, in the Claude Code app.

The LobsterOne app adds it from Settings, Tools (or its setup guide), keeps it up to date with the
app and removes it cleanly. You don't install it by hand.

## Your project's look

The mod finds a logo in your project and takes its colour. To say exactly how your project looks,
add `.claude/brand.json` at the project's root (or in one repo of it):

```json
{
  "name": "Acme",
  "logo": "brand/mark.svg",
  "lockup": "brand/lockup.svg",
  "colors": {
    "accent": "#5B8DEF",
    "light": { "surface-0": "#F7F8FA", "text-primary": "#111418" },
    "dark": { "surface-0": "#121417", "text-primary": "#F2F4F7" }
  }
}
```

Only `name` is needed. Paths are relative to the folder holding `.claude/`, and stay inside it.

- `logo`: a square SVG or PNG, drawn at 20 px.
- `lockup`: a wide SVG of mark and wordmark, drawn 24 px tall in place of logo and name.
- `colors.accent`: the colour the theme is built around. Also `success`, `danger`, `warning`, `pro`.
- `colors.light` and `colors.dark`: `surface-0` (the page) and `text-primary` are needed for a
  mode to count; `surface-1` to `surface-3`, `text-secondary` and `text-muted` are optional.

A theme Claude Code wouldn't draw (too little contrast) isn't sent, and the app keeps its look.
