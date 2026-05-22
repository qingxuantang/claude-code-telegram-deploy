---
name: deploy-telegram
description: Deploy Claude Code on a Linux / macOS / Windows host and connect it to Telegram for remote access. Multi-platform: a thin core that detects the target platform and routes to the matching overlay under platforms/. All shared concepts (architecture, server.ts patch, hooks, CLAUDE.md rules, troubleshooting) live in references/.
disable-model-invocation: false
---

# Agent Runbook: Deploy Claude Code + Telegram Channel

This skill produces a long-running Claude Code instance ("the daemon") that listens for messages over Telegram and replies through the same channel. The daemon is a **second** Claude Code process — it runs alongside whatever Claude Code instance is invoking this skill (e.g. a Desktop app on the operator's machine), sharing `~/.claude/skills/` and `~/CLAUDE.md` so personality / skills are consistent, but with **separate processes and separate contexts** so the daemon's 24/7 Telegram traffic doesn't interrupt the operator's work.

## Provenance

This skill exists in three production-deployed platform overlays, validated end-to-end on real hardware:

| Platform | Overlay | Validation |
|---|---|---|
| Linux | [`platforms/linux.md`](./platforms/linux.md) | Four production servers (HK / SG / JP) from 2026-04-07 to 2026-05-06; hot-fixes layered for 409 polling, channel permission relay, self-edit guard, long-session drift |
| macOS | [`platforms/macos.md`](./platforms/macos.md) | Mac mini (Darwin 24.6.0 arm64) from 2026-05-14 to 2026-05-21; four production incidents (trust dialog, AskUserQuestion deadlock, native binary auto-update, Desktop App bot contention) folded into the deploy |
| Windows | [`platforms/windows.md`](./platforms/windows.md) | Windows 11 Pro 26100 + Claude Code Desktop 2.1.142 + Bun 1.3.14 on 2026-05-21; end-to-end Telegram roundtrip verified |

## Required input (universal — collect before starting)

| Parameter | Format | How to obtain |
|---|---|---|
| `BOT_TOKEN` | `<digits>:<hash>` (e.g. `123456789:AAH...`) | Create via Telegram `@BotFather /newbot`. **Must be a fresh bot**, never one already in use by another long-poller. |
| `CLAUDE_OAUTH_TOKEN` | `sk-ant-oat01-...` (Linux/macOS only) | Run `claude setup-token` on a machine with a browser. **Skipped on Windows** — the daemon reuses Desktop App's existing auth. |
| `USER_TELEGRAM_ID` | digits (optional but recommended) | The operator's Telegram user_id. Obtainable via `@userinfobot` or post-pairing. Used for self-heal notifications on macOS. |

## Architecture (universal — detail in references)

```
┌────────────────────┐
│ Telegram (Phone)   │
└─────────┬──────────┘
          │ Bot API long-poll (HTTPS)
          v
┌────────────────────┐
│ bun runtime        │  Telegram plugin MCP server
│ server.ts          │  (child process of claude — kept alive by it)
└─────────┬──────────┘
          │ stdio (MCP protocol)
          v
┌────────────────────┐
│ claude daemon      │  Started with --channels plugin:telegram@claude-plugins-official
│  --channels flag   │  channelsEnabled: true in settings.json
└─────────┬──────────┘
          │ filesystem, git, bash, all tools
          v
┌────────────────────┐
│ Host OS            │  Platform-specific process supervisor keeps daemon
│  + supervisor      │  alive across reboots and crashes
└────────────────────┘
```

Deep dive in [`references/architecture-and-design.md`](./references/architecture-and-design.md).

## Universal do-not (read before any platform overlay)

1. **Do NOT reuse a Telegram bot** that another tool (e.g. OpenClaw, another Claude Code deployment) is already long-polling. Two `getUpdates` consumers on the same token → HTTP 409 Conflict → both lose messages. Always create a **fresh bot** via `@BotFather /newbot`.
2. **Do NOT combine `--plugin-dir` with `--channels`** in the daemon's startup command. They produce "inline source mismatch" and channel notifications are silently dropped.
3. **Do NOT skip `channelsEnabled: true`** in `~/.claude/settings.json`. Without it, inbound messages are silently dropped (debug log says `Channel notifications skipped`).
4. **Do NOT overwrite `~/.claude.json` / `~/.claude/settings.json`**. Many users have pre-existing state (Desktop App's `projects` cache; third-party analytics hooks; custom `mcpServers`). Always merge. The platform overlays do this via Python (Linux/macOS) or PowerShell (Windows).
5. **Do NOT deploy from mainland-China networks.** Telegram and GitHub are blocked. Use HK / SG / JP / US / EU.
6. **Do NOT skip the `server.ts` patch** (Step 4b/5b in every overlay) on a deployment that uses Telegram. Without it, every tool call pops an Allow/Deny card in the Telegram client.

## Execution

### Step 0 — Detect target platform and route

```bash
case "$(uname -s)" in
    Linux*)    PLATFORM=linux   ;;
    Darwin*)   PLATFORM=macos   ;;
    CYGWIN*|MINGW*|MSYS*) PLATFORM=windows ;;
    *)         PLATFORM=unknown ;;
esac

# Windows from PowerShell:
# $PLATFORM = if ($IsWindows) { "windows" } elseif ($IsMacOS) { "macos" } elseif ($IsLinux) { "linux" } else { "unknown" }
```

If the controller agent is on a different machine than the target (e.g. local Claude Code SSHing into a remote server), `PLATFORM` must reflect the **target**, not the controller. Linux overlay has explicit handling for this in `SSH_CMD` mode.

### Step 1 — Read the platform overlay and execute its steps

| If `PLATFORM=` | Read and execute |
|---|---|
| `linux` | [`platforms/linux.md`](./platforms/linux.md) — Steps 1–11 (includes `SSH_CMD` for remote vs local, OpenClaw self-execution caveats) |
| `macos` | [`platforms/macos.md`](./platforms/macos.md) — Steps 0–9c (assumes local self-execution; includes launchd wrapper pattern + Desktop App scope isolation) |
| `windows` | [`platforms/windows.md`](./platforms/windows.md) — Steps 1–10 (assumes local self-execution; uses Scheduled Task + visible-window manual dialog dismissal) |

Each overlay is **self-sufficient for execution** — once you've picked your platform, you don't need to bounce back to this SKILL.md for command details. Cross-references in each overlay point only to `references/<topic>.md` for the **why** behind decisions.

### Step 2 — Universal post-deploy verification

Regardless of platform, the deploy is considered successful when **all five** of these are true:

1. **Daemon process is alive** and shows `Listening for channel messages from: plugin:telegram@claude-plugins-official` in its pane.
2. **Bun MCP server is a child of claude** — confirms the `--channels` invocation worked. (`ps` on Linux/macOS, `Get-Process` on Windows.)
3. **`curl 'https://api.telegram.org/bot<TOKEN>/getUpdates?limit=1&timeout=0'` returns `"ok":true`** — no 409 conflict.
4. **Both CLAUDE.md rule blocks are installed** in both `~/CLAUDE.md` and `~/.claude/CLAUDE.md`. Verify with `grep -l '<!-- BEGIN: channel-routing-rule -->' ~/CLAUDE.md ~/.claude/CLAUDE.md` (and likewise for `no-interactive-select-rule`).
5. **End-to-end test**: phone sends a message, the daemon's pane shows `← telegram · <user_id>: <text>`, claude calls `plugin:telegram:telegram - reply`, the phone receives the reply within a few seconds.

If any step fails → [`references/troubleshooting.md`](./references/troubleshooting.md).

## References (universal knowledge)

The execution steps in each `platforms/<os>.md` reference these documents for **why** decisions were made. Read them when:

| Read this | When you want to understand |
|---|---|
| [`references/architecture-and-design.md`](./references/architecture-and-design.md) | The bun-as-child-of-claude relationship, why `channelsEnabled` + `--channels` are both required, the server.ts patch rationale, hook design, inbox mover design |
| [`references/claude-md-rules.md`](./references/claude-md-rules.md) | Both CLAUDE.md rule blocks (channel-routing + no-interactive-select), why both files (`~/CLAUDE.md` and `~/.claude/CLAUDE.md`), idempotent install protocol |
| [`references/pairing-and-access.md`](./references/pairing-and-access.md) | `/telegram:access pair <code>` + `policy allowlist` flow, access.json structure, re-pairing |
| [`references/process-supervisors.md`](./references/process-supervisors.md) | systemd vs launchd vs Task Scheduler comparison, why macOS needs a wrapper script, why Linux gets `RemainAfterExit=yes`, why Windows uses Scheduled Task instead of Service |
| [`references/post-deploy-hardening.md`](./references/post-deploy-hardening.md) | The production incidents that shaped this skill: trust dialog persistence, AskUserQuestion deadlock, native binary auto-update breakage, Desktop App bot contention, settings overwrite clobbering user state, UserPromptSubmit bypass on channel messages, long-session drift, slash-commands-over-Telegram architectural limit |
| [`references/troubleshooting.md`](./references/troubleshooting.md) | Cross-platform decision tree for diagnosing "phone sends a message, no reply" and other common symptoms |

## Operating notes (universal)

- **Slash commands over Telegram do NOT work.** This is a hard architectural limit of the channel plugin: Claude Code's CLI parser only intercepts commands typed directly into the terminal, not channel-injected. See [`references/post-deploy-hardening.md`](./references/post-deploy-hardening.md) §8.
- **One bot, one daemon, one machine.** Don't try to share a bot token across servers (409). If you want Telegram on multiple Claude Code deployments, create one bot per deployment.
- **Long-session drift mitigation**: schedule a nightly daemon restart. The model's attention to CLAUDE.md rules can erode after many `compact` operations. See [`references/post-deploy-hardening.md`](./references/post-deploy-hardening.md) §7.
- **Plugin upgrades require re-applying the server.ts patch** (Step 4b/5b). The `.bak` copy is preserved on first run; you can verify by checking for `// 'claude/channel/permission'` in the patched file.

## Compatibility

| | Linux | macOS | Windows |
|---|---|---|---|
| Tested versions | Ubuntu 22.04 / 24.04 | macOS 15 (Sequoia), Apple Silicon | Windows 11 Pro 26100 |
| Process supervisor | systemd `--user` | launchd | Task Scheduler |
| Watcher backend | inotify (path-unit) | FSEvents (WatchPaths plist) | `ReadDirectoryChangesW` (PowerShell `FileSystemWatcher`) |
| Shell | bash | bash / zsh | PowerShell |
| Sed flavor | GNU sed | BSD sed | (`-replace` operator) |
| Self-execution mode | yes (via `SSH_CMD=""`) | yes (default) | yes (default) |
| Remote SSH mode | yes (via `SSH_CMD="ssh ..."`) | (use Linux overlay if SSH-ing to a Mac) | no |
| Desktop App coexistence | n/a (no Desktop App on Linux) | requires `--scope local` install | Race condition on boot; `bot.pid` SIGTERM in `server.ts` is self-healing and daemon usually wins, but rare losses require manual `Stop-Process` on Desktop App's bun. See [`references/post-deploy-hardening.md`](./references/post-deploy-hardening.md) §4. |

## Background

As of April 5, 2026, Anthropic blocked OpenClaw from using Claude Pro/Max subscriptions. This skill (along with its sibling `../migrate-openclaw/`) provides a first-party alternative using Claude Code's native Channels feature.
