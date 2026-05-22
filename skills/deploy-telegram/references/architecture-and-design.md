# Architecture and design

The deploy-telegram skill produces a long-running Claude Code instance that listens for messages over Telegram and replies through the same channel. This page explains the moving parts that are **identical across Linux, macOS, and Windows** — platform-specific glue lives in `platforms/<os>.md`.

## Process model (universal)

```
┌────────────────────┐
│  Telegram (Phone)  │
└──────────┬─────────┘
           │ Bot API long-poll (HTTPS, port 443)
           v
┌────────────────────┐
│  bun runtime       │  Telegram plugin MCP server
│  server.ts         │  reads bot token from .env
│  (Anthropic        │  delegates auth via access.json
│   official plugin) │
└──────────┬─────────┘
           │ stdio (MCP protocol — JSON-RPC over pipes)
           v
┌────────────────────┐
│  claude.exe / claude  Daemon process started with
│  --channels        │  --channels plugin:telegram@claude-plugins-official
│                    │  Bun is a child process of claude
└──────────┬─────────┘
           │ filesystem, git, bash, all tools
           v
┌────────────────────┐
│  Host OS           │  Linux / macOS / Windows — platform-specific
│  + process         │   supervisor keeps daemon alive across reboots
│    supervisor      │   (see references/process-supervisors.md)
└────────────────────┘
```

Critical relationships:

- **Bun is a child of claude**, not the other way around. When `claude` starts with `--channels plugin:<name>`, the plugin's `.mcp.json` tells claude to spawn `bun run` with the plugin source. The bun process is therefore tied to that claude's lifetime — kill claude, kill bun.
- **The bun process is the long-poller**. It calls `getUpdates` on `https://api.telegram.org/bot<TOKEN>/...` forever (until SIGINT/SIGTERM/stdin-close).
- **There can be only one long-poller per bot token** — Telegram returns HTTP 409 Conflict if a second `getUpdates` starts. This is the root cause of every "messages disappear" bug.

## The two `channelsEnabled` modes

Claude Code 2.1.x has two ways a plugin can be loaded:

| Mode | CLI flag | settings.json | What plugin does |
|---|---|---|---|
| **Skills mode** | `--plugin-dir <path>` | (irrelevant) | Plugin tools exposed via MCP; **no channel polling** |
| **Channels mode** | `--channels plugin:<name>` | requires `channelsEnabled: true` | Plugin spawns its long-poller (bun); channel notifications routed to/from the Claude session |

**Mutually exclusive**: never use both for the same plugin in the same invocation — the debug log will say `Channel notifications skipped: ... source mismatch`.

A nuance: when the Telegram plugin is enabled at user-scope (`enabledPlugins.telegram@claude-plugins-official: true`), **both** Desktop App and daemon spawn bun for it — Desktop App via `--plugin-dir` (skills mode, intended for tool exposure), daemon via `--channels` (channels mode, intended for long-polling). But `server.ts` itself **doesn't differentiate** between modes — it always starts the Telegram long-poll on init. So on Windows you get **two competing bun processes** racing for the bot's getUpdates slot.

Salvation comes from `server.ts:60-68`'s **`bot.pid` stale-poller-kill mechanism**: each bun on startup reads `~/.claude/channels/telegram/bot.pid`, SIGTERMs whatever PID is recorded there, then writes its own PID. Whichever bun starts LATER wins. Empirically the daemon Scheduled Task fires before Desktop App finishes GUI startup, so daemon's bun usually wins (Desktop App's claude.exe doesn't aggressively re-spawn its bun after the first kill). When this race goes wrong, manual `Stop-Process` on Desktop App's bun unblocks recovery — see [`post-deploy-hardening.md`](./post-deploy-hardening.md) §4 for diagnosis + recovery + an optional permanent-fix sketch.

## The `server.ts` patch (universal)

The Telegram plugin's `server.ts` declares an opt-in capability:

```typescript
capabilities: {
  ...
  'claude/channel/permission': {},  // ← THIS LINE must be commented out
  ...
}
```

When this capability is declared, Claude Code forwards every tool-call permission check (Edit/Write/Bash/...) to Telegram as an Allow/Deny inline-keyboard card — **independent of** `--dangerously-skip-permissions`, `permissions.allow`, `permissions.defaultMode: bypassPermissions`, or `skipDangerousModePermissionPrompt`. The Telegram user gets spammed with permission cards on every operation.

The fix is to comment out that one line. Then channel sessions fall back to the terminal permission flow, which the bypass flags correctly handle.

**Re-apply after plugin updates** — `claude plugin marketplace update` or a fresh install overwrites `server.ts`. All three platform overlays make a `.bak` copy on first run; you can detect a needed re-patch by checking whether `// 'claude/channel/permission'` is present.

Platform-specific patch implementations:

- **Linux**: `sed -i 's/...//g'` (GNU sed)
- **macOS**: `sed -i '' 's/...//g'` (BSD sed requires empty backup suffix)
- **Windows**: PowerShell `(Get-Content -Raw) -replace ... | Set-Content` (or `[System.IO.File]::WriteAllText` to avoid BOM)

## Permission-bypass hook (PreToolUse + PermissionRequest)

Claude Code has **hard-coded `alwaysAskRule` guards** for sensitive paths:

- Anywhere under `~/.claude/` (substring match — also catches project-nested `.claude/` dirs like `workspace/<project>/.claude/skills/`)
- Anywhere under `~/.config/`
- Common dotfile basenames: `.bashrc`, `.bash_profile`, `.profile`, `.zshrc`, `.zprofile`, `.zshenv`, `.gitconfig`, `.npmrc`, `.env`, `.envrc`, `.claude.json`

These guards fire **independently of** all `permissions.*` settings and `--dangerously-skip-permissions`. In a Telegram-driven deployment, the guard pops a blocking dialog in the daemon's pane (which the human can't reach) and the session freezes silently.

The fix is a `PreToolUse` + `PermissionRequest` hook that auto-allows tool calls whose paths match the guarded patterns. The hook is the same conceptually on all platforms but implemented in different languages:

- **Linux / macOS**: bash wrapper that pipes JSON to a Python `python3 - "$input" << 'PY' ... PY` heredoc. Cross-platform Python script.
- **Windows**: pure PowerShell (`bypass-claude-folder.ps1`) with a `.cmd` wrapper, since `.ps1` files aren't auto-executable by Claude Code's hook runner. **Critical**: hook command paths in `settings.json` must use forward slashes (`C:/Users/...`); backslashes get mangled by MSYS bash that Claude Code uses on Windows.

The hook decision algorithm:

1. Read JSON from stdin
2. Check `hook_event_name` — must be `PreToolUse` or `PermissionRequest`
3. Extract `tool_input.file_path` / `tool_input.notebook_path` / `tool_input.command`
4. Match against:
   - Substring list of sensitive directory components (e.g. `/.claude/`)
   - Basename list of sensitive filenames
   - For Bash commands: token-scan the command string for sensitive paths
5. If match → emit `{"hookSpecificOutput": {"hookEventName": ..., "permissionDecision": "allow"} | {"decision": {"behavior": "allow"}}}`
6. If no match → exit silently (default permission flow proceeds)

Substring matching is essential — without it, project-nested `.claude/` directories aren't covered. (See git history for the prefix-vs-substring lesson, commit `1273e2e`.)

## Telegram routing hook (UserPromptSubmit)

After several `compact` operations in a long session, Claude tends to "forget" to call the `plugin:telegram:telegram - reply` MCP tool — it generates a beautiful reply in the terminal that the Telegram user never sees. CLAUDE.md rules alone don't reliably defend against this: `compact` summaries don't preserve them.

The `UserPromptSubmit` hook fires every time a message enters the session. If the message contains the channel marker `← telegram` (or its arrow variant `<-`), the hook injects `additionalContext`:

```
TELEGRAM ROUTING MANDATORY: This message came from Telegram. You MUST call
plugin:telegram:telegram reply MCP tool with chat_id to send your response.
Terminal output is INVISIBLE to the Telegram user. Do NOT skip the reply tool call.
```

This makes the routing instruction fresh in the model's context **every single turn that needs it**, regardless of compact erosion.

> **Known limitation** (discovered 2026-05-06 on a Linux production deployment): channel-routed messages may go through a different code path that bypasses `UserPromptSubmit`. The hook is still useful for terminal-injected reminders, but it is **not** a guaranteed safety net for channel messages. CLAUDE.md rules remain the primary defense.

## Inbox mover (avoid hard-coded sensitive-file guard on uploads)

When a Telegram user uploads a file (image, PDF, xlsx, …), the plugin drops it into `~/.claude/channels/telegram/inbox/`. Any `cp` / `mv` / `Read` of that path triggers Claude Code's sensitive-file guard (because the path starts with `~/.claude/`). This guard is **not bypassed** by any of `--dangerously-skip-permissions`, `permissions.allow`, `permissions.defaultMode: bypassPermissions`, or `skipDangerousModePermissionPrompt`. The session freezes on an invisible dialog.

The architectural fix is to **move uploads out of `~/.claude/` the instant they land**. CLAUDE.md is then patched to instruct Claude to look at `~/telegram-inbox/` (the safe destination) rather than the original path.

Per-platform watcher implementations:

| Platform | Mechanism | Detection latency |
|---|---|---|
| **Linux** | `systemd --user` path-unit with inotify | ~1 ms |
| **macOS** | launchd plist with `WatchPaths` (FSEvents) | ~100 ms |
| **Windows** | PowerShell `FileSystemWatcher` running under a Scheduled Task | ~50 ms |

All three are "sub-second", which is well inside the window before Claude tries to read the file.

## Files written by the deploy

Every platform writes the same logical artifacts, just at platform-canonical paths:

| Logical role | Linux / macOS path | Windows path |
|---|---|---|
| Onboarding bypass | `~/.claude.json` (merged) | `%USERPROFILE%\.claude.json` (merged) |
| Settings | `~/.claude/settings.json` (merged) | `%USERPROFILE%\.claude\settings.json` (merged) |
| Bot token | `~/.claude/channels/telegram/.env` (chmod 600 / NTFS ACL) | same path, UTF-8 no BOM |
| Pairing state | `~/.claude/channels/telegram/access.json` (auto) | same |
| Daemon launcher | `~/start-claude.sh` | `%USERPROFILE%\start-claude.ps1` |
| Bypass hook | `~/bypass-claude-folder.sh` | `%USERPROFILE%\bypass-claude-folder.ps1` + `.cmd` wrapper |
| Routing hook | `~/telegram-routing-hook.sh` | `%USERPROFILE%\telegram-routing-hook.ps1` + `.cmd` wrapper |
| Inbox mover | `~/tg-inbox-move.sh` / inotify path-unit / launchd plist | `%USERPROFILE%\tg-inbox-mover.ps1` + Scheduled Task |
| Safe upload landing dir | `~/telegram-inbox/` | `%USERPROFILE%\telegram-inbox\` |
| Process supervisor unit | systemd `claude-telegram.service` / launchd `com.openclaw.claude-telegram.plist` | Scheduled Task `ClaudeCodeTelegramDaemon` |

## What's intentionally NOT in this skill

- **Telegram bot creation** — must come from `@BotFather`, human-only step
- **OAuth token generation** — `claude setup-token` requires an interactive browser; skill instructs the human to run it on a machine with a browser and paste back the token
- **CLAUDE.md project content** — the skill only appends two universal rule blocks (see [`claude-md-rules.md`](./claude-md-rules.md)); your project personality / instructions are your own
- **User pairing** — `/telegram:access pair <code>` requires the human's Telegram client to fetch a code first; the skill prepares the command but the human runs it

These are documented as 👤 MANUAL steps in each platform overlay.
