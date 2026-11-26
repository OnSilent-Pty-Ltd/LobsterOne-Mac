# What LobsterOne for Mac does with your data

This page describes the Mac app in this repository, as the code stands. The LobsterOne service and website are covered by the [privacy policy at lobsterone.ai](https://lobsterone.ai/privacy/). If the two ever disagree about the app, the code is the truth, and we want to hear about it: **privacy@lobsterone.ai**.

## What leaves your Mac

### To LobsterOne

Sent over HTTPS to `ingest.lobsterone.ai`, `api.lobsterone.ai` and `auth.lobsterone.ai`, tagged with this Mac's LobsterOne API key.

**Claude Code sessions.** Every minute while you're active (every five when idle), the app reads new lines in `~/.claude/projects/` and sends, per session:

- session ID, parent session ID and whether it's a subagent
- the project folder name, with the `/Users/<you>/` part removed
- start time, session title and git branch
- token counts by type and by model, message counts, subagent counts
- **the first 500 characters of the session's first prompt**
- counts of tool calls, tool errors, files changed, plan-mode and normal turns
- for each tool call: the tool's name, whether it failed, when it ran, and **the file path it read or edited** (Read, Write, Edit), the search pattern (Glob) or the folder searched (Grep)

These let you track your usage per project and per client. The folder name groups sessions by project, and your tag rules use it to file them under a client. The first prompt and the file paths show you which project or client a session was for. Only you see them; team admins see totals per person.

You can turn off the prompt opening, the title and the file paths in **Settings → Tools → What Claude Code sends**. With it off, the app still sends usage numbers, the project folder and the git branch. Turning it off applies from then on; it doesn't delete what was already sent.

The rest of the conversation is not sent: later prompts, Claude's replies, file contents and command output.

**Claude Code telemetry.** During setup the app adds Claude Code's own OpenTelemetry settings to `~/.claude/settings.json`, so Claude Code sends its usage metrics and events to `ingest.lobsterone.ai`. What goes is decided by Claude Code and described in its monitoring documentation. The app doesn't turn on `OTEL_LOG_USER_PROMPTS`, so Claude Code leaves prompt text out.

**Codex.** The app reads `~/.codex/sessions/` and sends token counts by model, lines added and removed (counted on your Mac from completed patches), and your Codex rate-limit percentages, reset times and plan type. It also sets Codex's own OpenTelemetry log export to `ingest.lobsterone.ai` in `~/.codex/config.toml`, with `log_user_prompt = false` and traces off. Which events go is decided by Codex.

**Mistral Vibe.** The app reads `~/.vibe/sessions/` and sends token counts by model.

**Claude subscription usage.** Your five-hour and seven-day usage percentages, Sonnet and Opus percentages, extra credits used, monthly limit, subscription type and rate-limit tier (see "To Anthropic" below).

**Notifications.** If you allow notifications: Apple's push token for this Mac and your time zone, so alerts can hold off during your night.

**Your account.** Signing in uses `auth.lobsterone.ai` (email or GitHub). The app then creates, lists and revokes API keys for this Mac, and fetches your quota, notifications and the daily leaderboard. It also fetches a policy from LobsterOne that can tell the app to pause uploads, for example when this version is too old.

### To Anthropic

To show your real Claude subscription usage, the app calls `api.anthropic.com/api/oauth/usage` with the sign-in token Claude Code already saved on your Mac. It reads that token from `~/.claude/.credentials.json` or, if that file doesn't exist, from the Keychain item Claude Code created, using `/usr/bin/security`. **macOS doesn't ask you first, and neither does the app.** The token goes only to Anthropic, never to LobsterOne. When the token has expired, the app runs `claude -p /usage` so Claude Code refreshes it itself.

### To AWS

Only if you set up AWS costs. The app calls AWS Cost Explorer, Organizations and STS directly, signing the requests with your AWS credentials, which come from `~/.aws/` or keys you paste into the app (kept in your Keychain). The figures stay on your Mac. Nothing about your AWS account is sent to LobsterOne.

### To check for updates

Once an hour the app fetches `releases.lobsterone.ai/mac/appcast.xml` to look for a new version. It doesn't send a system profile.

## What stays on your Mac

- **Dictation.** Audio and text are handled by Apple's on-device speech model. Nothing is recorded or sent.
- **Keys and tokens.** Your LobsterOne API key, sign-in tokens and any pasted AWS keys are kept in your login Keychain under `com.lobsterone.mac`.
- **AWS cost figures**, as above.
- **The debug log** keeps its last 300 lines in memory for Settings → About → Diagnostics, and writes every line to `~/Library/Logs/LobsterOne/debug.log` (up to about 6 MB across three rotating files) so older problems can still be traced. It records what the app fetched and whether it worked, never whole tokens or keys: anything that looks like one is replaced with `[redacted]` before it is written. Nothing in it is sent anywhere unless you copy it out yourself.
- **The scan cache** in `~/Library/Caches/LobsterOne/`. It records how far each session file has been read, so lines aren't sent twice.

## What the app changes on your Mac

Each file it edits gets a `.lobsterone-backup` copy first, where noted.

| File | What it writes | When |
|------|----------------|------|
| `~/.claude/settings.json` (backup) | Claude Code telemetry settings, including your LobsterOne API key in plain text. Sound-cue hooks that run `afplay` | Setup, and when you turn on sounds |
| `~/.codex/config.toml` | An `[otel]` section with your API key | Setup, if Codex is installed |
| `~/.codex/hooks.json` (backup), `~/.vibe/hooks.toml` (backup) | Sound-cue hooks that run `afplay` | When you turn on sounds |
| `~/.lobsterone/config.json` | A copy of the telemetry settings, used to repair them | Setup |
| `~/.claude/agents/` and `~/.claude/agent-memory/` | Agent files for crew you hire. Only files the app wrote are ever changed or removed | When you hire or let go of crew |
| `~/Library/Application Support/LobsterOne/ClaudeCode/` | The LobsterOne mod for Claude Code (the band above the prompt), installed into Claude Code at user scope with its own `claude plugin` commands. It reads your project's name, logo and colours on your Mac to draw the band and sends nothing. Removing it uninstalls the plugin and deletes the folder | When you add the mod (Settings → Tools, or the setup guide) |
| `~/.zshrc`, `~/.bashrc`, `~/.zprofile`, `~/.bash_profile` | Comments out old telemetry lines | Only when you choose that fix in Diagnostics |

## Stopping it

- **Turn off "Session openings and file paths"** (Settings → Tools) to keep the prompt opening, session title and file paths on your Mac while still tracking usage.
- **Disconnect a tool** (Settings → Tools) to stop its uploads and take LobsterOne's telemetry settings out of it. For Claude Code, the session upload stops within a minute and stays stopped until you connect it again.
- **Sign out** (Settings, or the menu) stops every upload, revokes this Mac's API key, and offers to remove the telemetry settings from Claude Code, Codex and Mistral Vibe.
- **Quitting** stops the app's own uploads. Claude Code and Codex keep sending their telemetry until those settings are removed, which signing out offers to do. You can also delete the `OTEL_*` and `CLAUDE_CODE_ENABLE_TELEMETRY` keys yourself, and the `[otel]` section in `~/.codex/config.toml`.
- **To delete what has been sent**, email privacy@lobsterone.ai. Session details, including first prompts and file paths, are kept until you ask.

## Checking for yourself

All of this can be confirmed in the source. The places to look:

- `Sources/LobsterOne/Services/ClaudeSessionScanner.swift` and `Models/ClaudeScannerModels.swift`: Claude Code sessions
- `Services/CodexSessionScanner.swift`, `Services/MistralVibeSessionScanner.swift`: Codex and Mistral Vibe
- `Services/ConfigService.swift`: the telemetry settings written to each tool
- `Services/APIClient.swift`, `Services/AuthService.swift`: everything else sent to LobsterOne
- `Services/AnthropicAPIClient.swift`, `Services/ClaudeCredentialService.swift`: the Anthropic call and the token it uses
- `AWS/`: the AWS calls
