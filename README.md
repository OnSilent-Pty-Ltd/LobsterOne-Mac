# LobsterOne for Mac

A native macOS menu bar app for people who code with AI agents. It shows how much of your Claude Code, Codex and Mistral Vibe allowance you've used, and how fast you're going.

The source is public so you can check exactly what the app does with your data. Start with **[PRIVACY.md](PRIVACY.md)**: it lists everything that leaves your Mac, where it goes, and what the app changes on your disk.

## What it does

- **Usage in the menu bar.** Tokens for Claude Code, Codex and Mistral Vibe, your Codex rate limits, and your real Claude five-hour and seven-day limits, with a warning when you're on pace to hit them.
- **Crew.** Hire ready-made Claude Code agents (a reviewer, an upkeep checker and others) and schedule when to send them off.
- **Sound cues.** Hear when an agent starts, finishes, or is waiting on you. The packs are built from NASA, NOAA and other recordings.
- **AWS costs.** Your AWS spend next to your AI spend, fetched straight from AWS with your own credentials.
- **Dictation.** Hold a key, speak, and the words land where your cursor is. Runs on your Mac with Apple's speech model (macOS 26).
- **Screensaver** showing your numbers, and notifications from your LobsterOne account and team.
- **Updates itself** through Sparkle, with signed releases.

## Requirements

- macOS 14 (Sonoma) or later. Dictation needs macOS 26.
- A [LobsterOne](https://lobsterone.ai) account.

## Building

You need Xcode 26: dictation uses the macOS 26 SDK.

```bash
swift build
```

```bash
swift test
```

The Swift package is for development and tests. Release builds come from the Xcode project, `LobsterOne/LobsterOne.xcodeproj`, which adds the menu-bar-only setting, the `lobsterone://` URL scheme, signing and Sparkle.

The source exists twice: `Sources/LobsterOne/` for the package and `LobsterOne/LobsterOne/` for Xcode. They must stay identical. CI fails if they drift, so change both.

The screensaver is built separately with `ScreenSaver/build.sh`.

## Layout

```
Sources/LobsterOne/
  Services/   scanners, API clients, sign-in, config files, dictation, sound cues
  Models/     data types and parsing for each tool's session files
  UI/         menu bar, popover, settings, setup
  Team/       crew roles, the installer that writes agent files, the calendar
  AWS/        a small signed client for Cost Explorer, Organizations and STS
  Costs/      AWS cost figures
Tests/LobsterOneTests/
ScreenSaver/
scripts/      release, icon and sound-building scripts
```

## Releases

Every merge to `main` that passes Build & Test is built, signed with OnSilent Pty Ltd's Developer ID, notarised, signed for Sparkle and published to `releases.lobsterone.ai`. Merges that only change Markdown files don't release. See `.github/workflows/release.yml`. The latest build is always at
`https://releases.lobsterone.ai/mac/LobsterOne-latest.dmg`.

Builds you make yourself aren't signed with our keys, so they won't receive updates from us.

## Contributing

Issues and pull requests are welcome. For anything bigger than a fix, open an issue first so we can agree on the approach. Report security problems privately: see [SECURITY.md](SECURITY.md).

## Licence

The code is under the [Apache License 2.0](LICENSE), copyright 2026 OnSilent Pty Ltd.

The licence covers the code only. The LobsterOne name and logo, Garry, the crew portraits and the pack artwork are not licensed for reuse. The fonts are under the SIL Open Font License (each licence file sits next to its font). The sound recordings come from third parties under their own terms, credited in the app, and aren't covered by the Apache licence.
