# Windows recovery scripts

Standalone, drop-in copies of the Step 11 self-heal artifacts from [`../../platforms/windows.md`](../../platforms/windows.md). The deploy step installs these to `%USERPROFILE%\` and the Desktop on the target machine; the copies here exist so anyone can read / audit / `curl` them directly without running the full skill.

## What's here

| File | Installs to (target machine) | When it runs |
|---|---|---|
| `fix-daemon.ps1` | `%USERPROFILE%\fix-daemon.ps1` | (a) automatically by the `ClaudeCodeTelegramDaemonHeal` Scheduled Task, 90 s after each user logon; (b) manually whenever the operator suspects Telegram has gone silent |
| `Fix Claude Telegram Daemon.cmd` | `%USERPROFILE%\Desktop\Fix Claude Telegram Daemon.cmd` | Manual double-click recovery (calls `fix-daemon.ps1`) |

## What `fix-daemon.ps1` does

Idempotent post-boot self-heal:

1. Enumerates every `bun.exe` process; walks the parent chain to find each one's "root parent" claude.exe.
2. If the root parent's command line does NOT contain `--channels`, that bun belongs to the Desktop App (which loaded the Telegram plugin in `--plugin-dir` skills mode) and is contending for the bot's `getUpdates` slot. **Kill it.**
3. Kill the daemon's `claude.exe` (`--channels` mode) too, so `start-claude.ps1`'s while-loop respawns it with a fresh bun.
4. Wait 20 s, then verify end state (`daemon-claude=1, bun=2`) and a clean Telegram `getUpdates`.
5. Append a timestamped result line to `%USERPROFILE%\fix-daemon.log`.

End state is deterministic: **daemon-solo**, regardless of who originally won the post-boot race.

### Why this is safe to run defensively

Even when the daemon is already healthy, the kill + respawn is harmless:

- Just-launched daemon has no session context to lose
- Just-launched Desktop App is unlikely to be actively using `mcp__plugin_telegram_telegram__*` tools yet
- ~15 s daemon downtime is invisible to the user — Telegram queues messages server-side for 24 h
- Idempotent: re-running converges to the same end state

Result: an unconditional defensive run, 90 s after each logon, converts a probabilistic race into a guaranteed outcome.

## When you need this script

You'll know the daemon has gone silent when:

- You send a Telegram message from your phone and Claude doesn't reply within ~30 s
- `Get-Process bun` from PowerShell shows bun processes, but their `ParentProcessId` traces back to the Desktop App's `claude.exe` (with `--plugin-dir`) instead of the daemon's `claude.exe` (with `--channels`)
- The daemon's PowerShell window (if visible) shows "Listening for channel messages" but no inbound traffic appears

In any of those cases: double-click the desktop shortcut, wait ~30 s, send a Telegram message again. If it still doesn't reply, check `%USERPROFILE%\fix-daemon.log` for the last run's output and check [`../../references/troubleshooting.md`](../../references/troubleshooting.md).

## Why root cause exists at all

`server.ts` (the Telegram plugin's bun MCP server) writes `~/.claude/channels/telegram/bot.pid` on startup and SIGTERMs whatever PID was there before. Whichever bun starts LAST wins the bot. On Windows, the Desktop App's `claude.exe` is launched with `--plugin-dir telegram` (skills mode) when `enabledPlugins.telegram@claude-plugins-official: true` is in any merged settings; `server.ts` then unconditionally starts a Telegram long-poll. So both the daemon and Desktop App's claude.exe spawn a competing bun. Race outcome: non-deterministic.

The Scheduled Task in Step 11b makes this deterministic by forcing a daemon-wins outcome 90 s into every session.

Full design context: [`../../references/post-deploy-hardening.md`](../../references/post-deploy-hardening.md) §4 ("Desktop App vs CLI bot-token contention") and the [Step 11 callouts](../../platforms/windows.md) in the platform overlay.

## Why these files are pure ASCII

`Fix Claude Telegram Daemon.cmd` is written entirely in ASCII — no em-dashes, no smart quotes, no Chinese punctuation. Reason: `cmd.exe` on Chinese-locale Windows reads `.cmd` / `.bat` files using the system ANSI codepage (GBK), NOT UTF-8. UTF-8 multi-byte characters get split at codepage boundaries and the leftover bytes are interpreted as commands, producing the cryptic `'M' 不是内部或外部命令` error (or similar single-letter "command not found" messages).

`fix-daemon.ps1` does use a few non-ASCII characters in its comments (em-dashes, etc.) — PowerShell reads `.ps1` as UTF-8 by default and tolerates them fine. If you want to be extra paranoid for cross-locale portability, strip them.

If you copy these files manually (instead of running the Step 11a/11c install commands), write them with these exact encodings:

```powershell
# .ps1 — UTF-8 without BOM is fine
[System.IO.File]::WriteAllText("$env:USERPROFILE\fix-daemon.ps1", $content, [System.Text.UTF8Encoding]::new($false))

# .cmd — ASCII only, no BOM
[System.IO.File]::WriteAllText("$env:USERPROFILE\Desktop\Fix Claude Telegram Daemon.cmd", $cmdContent, [System.Text.ASCIIEncoding]::new())
```

## Quick install (if you want to skip the rest of the skill and just get the recovery scripts)

From a PowerShell on the target Windows machine:

```powershell
# Substitute <REPO> with the path to your local clone, OR curl from GitHub raw:
$repo = "<path-to-claude-code-telegram-deploy-clone>\skills\deploy-telegram\scripts\windows"
Copy-Item "$repo\fix-daemon.ps1" "$env:USERPROFILE\fix-daemon.ps1"
Copy-Item "$repo\Fix Claude Telegram Daemon.cmd" "$env:USERPROFILE\Desktop\Fix Claude Telegram Daemon.cmd"
```

For the auto-fire Scheduled Task (Step 11b in the platform overlay), see [`../../platforms/windows.md`](../../platforms/windows.md) — it's a one-time `Register-ScheduledTask` invocation that you can copy-paste.

## What this script does NOT do

- It does NOT fix the underlying race — it just makes the outcome deterministic. The root cause (Anthropic plugin loading races between Desktop App and CLI daemon) lives in Claude Code itself.
- It does NOT migrate any state. Just kills + restarts processes.
- It does NOT touch settings.json, `.env`, or any plugin files. Safe to run with any in-flight skill or config.
- It does NOT modify the Scheduled Task itself. If `ClaudeCodeTelegramDaemonHeal` was disabled, this script still works manually — it just won't auto-fire on next boot.

## License

Same as the parent repo. See [`../../../../LICENSE`](../../../../LICENSE).
