# Troubleshooting: cross-platform decision tree

Symptoms first, then per-platform diagnostic commands. If you have a deploy that **completed without error** but Telegram is silent, follow this from the top.

## Symptom: phone sends a message, no reply

### Step 1: is the daemon process alive?

| Platform | Command | Healthy output |
|---|---|---|
| Linux | `systemctl --user status claude-telegram` | `active (running)` |
| macOS | `launchctl list \| grep com.openclaw` | both `claude-telegram` and `tg-inbox-mover` with a PID in column 1 |
| Windows | `Get-ScheduledTask ClaudeCodeTelegramDaemon \| Get-ScheduledTaskInfo` AND `Get-Process bun,claude` | task `Running` (or Ready if no logon yet); claude.exe + 2 bun.exe processes |

If missing or repeatedly failing: see Step 1b.

### Step 1b: read the supervisor's log

| Platform | Command |
|---|---|
| Linux | `journalctl --user -u claude-telegram -n 80` |
| macOS | `tail -80 ~/Library/Logs/claude-telegram.log` |
| Windows | `Get-ScheduledTaskInfo ClaudeCodeTelegramDaemon \| Select LastTaskResult` (codes: `267009`=running, `267011`=task exited immediately) — for stderr, run `start-claude.ps1` manually in a visible PowerShell to see the error |

Common patterns:
- `claude --version: native binary not installed` → macOS auto-update issue; see [`post-deploy-hardening.md`](./post-deploy-hardening.md) §3
- `409 Conflict` → another long-poller (zombie bun?). `pkill -f 'bun.*server.ts'` (or Windows equivalent) and restart
- `command not found: claude` → PATH issue in supervisor's environment; check `start-claude.{sh,ps1}` PATH setup
- Repeated `duplicate session: claude` on macOS → death-spiral; verify wrapper script (Step 7.2) exists and KeepAlive plist references the wrapper, not tmux directly. See [`process-supervisors.md`](./process-supervisors.md) §macOS

### Step 2: is the tmux session / hidden window alive? (Linux/macOS only)

```bash
tmux ls | grep claude
tmux capture-pane -t claude -p | tail -30
```

- **No session**: on Linux this means systemd hasn't (re-)launched the unit; check Step 1. On macOS the wrapper polls every 30s and recreates; force it with `pkill -f start-claude-launchd-wrapper.sh` (KeepAlive restarts within ~10s).
- **Session present but pane shows trust dialog** → Step 7c didn't take effect. Apply the trust patch from [`post-deploy-hardening.md`](./post-deploy-hardening.md) §1.
- **Session present but pane shows "native binary not installed"** → see [`post-deploy-hardening.md`](./post-deploy-hardening.md) §3.

For Windows: there's no tmux. The daemon runs in a hidden PowerShell window. To inspect, either:
- Stop the task, run `start-claude.ps1` manually in a visible window
- Or redirect daemon stdout to a log file (edit `start-claude.ps1` to add `*> "$env:USERPROFILE\claude-daemon.log"`) and `Get-Content -Tail 50`

### Step 3: is claude in "Listening" state?

```bash
# Linux / macOS
tmux capture-pane -t claude -p | grep "Listening for channel messages"
```

For Windows: run `start-claude.ps1` manually in a visible window and watch for `Listening for channel messages from: plugin:telegram@claude-plugins-official`.

- **Not present, pane content looks normal** → first launch hasn't completed yet; wait 15–30s.
- **Not present, pane is empty / stuck** → `bun server.ts` crashed. See Step 4.
- **Present, but phone still gets no reply** → routing problem (`reply` tool not being called). See Step 5.

### Step 4: is the Bun MCP server running as a child of claude?

| Platform | Command |
|---|---|
| Linux | `pgrep -P $(pgrep -f 'claude --dangerously') bun` |
| macOS | same as Linux |
| Windows | `Get-WmiObject Win32_Process -Filter "Name='bun.exe'" \| Select ProcessId, ParentProcessId` — check ParentProcessId points to claude.exe |

- **No bun child**: the daemon didn't pass `--channels`. Verify `start-claude.{sh,ps1}` includes `--channels plugin:telegram@claude-plugins-official`.
- **Bun running but on Telegram side getUpdates returns 409**: another long-poller exists somewhere. Kill all bun processes with the plugin path in their cmdline, then restart the daemon.

#### Step 4 (sub-check before 4a): is the plugin actually **enabled**?

Check `claude plugin list`. If it shows `× disabled` despite `~/.claude/settings.json` having `enabledPlugins.telegram@claude-plugins-official: true`, you're hitting the **CC 2.1.149+ plugin loader change** — user-scope `enabledPlugins` is no longer respected; only local-scope `<cwd>/.claude/settings.local.json` is. See [`post-deploy-hardening.md`](./post-deploy-hardening.md) §12.

Symptoms when this is the cause:
- `claude --channels` daemon process alive, but **zero bun children** (despite `--channels` flag being correct)
- `claude plugin list` → `× disabled`
- Manual `bun run --cwd <plugin-cache> --shell=bun --silent start` works fine
- No 409 conflict, no parse errors, daemon silently does nothing

Fix:

```bash
# Linux / macOS — cd to the daemon's launch cwd FIRST
cd <DAEMON_CWD>      # usually $HOME, but match start-claude.sh's `cd`
claude plugin enable telegram@claude-plugins-official
claude plugin list   # should now show "enabled"
ls -la <DAEMON_CWD>/.claude/settings.local.json   # should exist with enabledPlugins
```

```powershell
# Windows — cd to the daemon's launch cwd FIRST (match start-claude.ps1's Set-Location)
Set-Location <DAEMON_CWD>
& $env:CLAUDE_EXE plugin enable telegram@claude-plugins-official
& $env:CLAUDE_EXE plugin list   # should now show "enabled"
Get-Content "<DAEMON_CWD>\.claude\settings.local.json" -Raw
```

Then restart the daemon so it picks up the new local-scope enable. If `plugin list` still shows disabled after enable, double-check you ran `plugin enable` in the **exact same cwd** as start-claude's `cd` / `Set-Location`.

#### Step 4a: if `/mcp` shows the MCP server as **"failed"** (bun spawn or parse failure)

The Claude TUI shows `1 MCP server failed · /mcp` near the prompt indicator. Running `/mcp` inside the daemon's session shows the server detail with status `× failed` and "spawn args" but **no error reason**. To get the actual error, run bun manually with the exact same args claude was using:

```powershell
# Windows — copy the args verbatim from the /mcp detail page
$bun = "$env:USERPROFILE\.bun\bin\bun.exe"
$cwd = "$env:USERPROFILE\.claude\plugins\cache\claude-plugins-official\telegram\<VERSION>"
$env:TELEGRAM_BOT_TOKEN = (Get-Content "$env:USERPROFILE\.claude\channels\telegram\.env" -Raw) -replace 'TELEGRAM_BOT_TOKEN=','' -replace '\s',''
& $bun run --cwd $cwd --shell=bun --silent start 2>&1 | Select-Object -First 30
```

```bash
# Linux / macOS
cd ~/.claude/plugins/cache/claude-plugins-official/telegram/<VERSION>
TELEGRAM_BOT_TOKEN=$(grep -oP '(?<=TELEGRAM_BOT_TOKEN=).*' ~/.claude/channels/telegram/.env) \
  bun run --shell=bun --silent start 2>&1 | head -30
```

Common stderr patterns:

| Output | Cause | Fix |
|---|---|---|
| `error: Expected " =" but found "閴?"` or other Unicode mojibake at `server.ts:937` | `server.ts` file got corrupted by being read/written in a non-UTF-8 codepage (e.g. GBK on Chinese Windows). Emoji `'✅'`/`'❌'` bytes got reinterpreted. | Restore `server.ts` from `server.ts.bak` (kept by the Step 4b patch step), then re-apply patch with explicit UTF-8 encoding. See [`post-deploy-hardening.md`](./post-deploy-hardening.md) §"server.ts UTF-8 corruption". |
| `Cannot find module ...` | `bun install` never finished or `node_modules/` got deleted | `cd <plugin-cache-dir>; bun install` |
| `TELEGRAM_BOT_TOKEN required` | `.env` not loaded — either missing, has BOM (Windows), or wrong path | See "Symptom: `.env` token not loaded" below |
| `getMe ... 401 Unauthorized` | Bot token is invalid / revoked | Regenerate via `@BotFather /revoke` then `/token` |

### Step 5: is the Telegram bot side healthy?

```bash
curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?limit=1&timeout=0" | head -c 200
```

| Response | Meaning |
|---|---|
| `"ok":true` (no `description` key) | Bot side healthy; bug is in the daemon's processing |
| `"ok":false, "error_code":409, "description":"Conflict: ..."` | Another long-poller alive. Kill it. |
| `"ok":false, "error_code":401, "description":"Unauthorized"` | Bot token is invalid / revoked. Regenerate via `@BotFather /revoke` then `/token`. |
| Timeout / DNS failure | Network issue. Test `curl https://api.telegram.org/`. |

### Step 6: routing — is the reply tool being called?

If everything above is healthy but you still get no reply:

```bash
# Linux / macOS — find the most recent jsonl session log
ls -t ~/.claude/projects/*/sessions/*.jsonl | head -3
# Search for the reply tool name
grep -c 'plugin:telegram:telegram - reply' <latest.jsonl>
```

- **Zero hits** → Claude is forgetting to call the reply tool. Re-install the CLAUDE.md rule (see [`claude-md-rules.md`](./claude-md-rules.md)) and restart the daemon. Long-session drift is a known limit (see [`post-deploy-hardening.md`](./post-deploy-hardening.md) §7).
- **Hits present but phone sees nothing** → the tool is being called but failing silently. Check pane for the call's response; common failure: `chat_id` mismatch.

For Windows: jsonl session logs live at `%USERPROFILE%\.claude\projects\<slug>\sessions\<id>.jsonl`. Same diagnostic.

### Step 7: hook diagnostics

If you see `PreToolUse:* hook error` repeatedly in the pane:

```
| Failed with non-blocking status code: /usr/bin/bash:
| line 1: <some-path>: command not found
```

**Windows-specific footgun** — the registered hook command path uses backslashes. MSYS bash (which Claude Code routes hook commands through) strips `\` as escape chars. Fix: re-register hooks with forward slashes (`C:/Users/.../hook.cmd`). See `platforms/windows.md` Step 7.

**Linux / macOS**: less common. Check the hook script is executable (`chmod 700`) and its first line is `#!/bin/bash`. Test stand-alone: `echo '{"hook_event_name":"PreToolUse","tool_input":{"file_path":"~/.bashrc"}}' | ~/bypass-claude-folder.sh` — should output JSON, not error.

---

## Symptom: Telegram uploads (image/PDF) freeze the session

Discussed in detail in [`architecture-and-design.md`](./architecture-and-design.md) §"Inbox mover".

Quick check: is the inbox mover running?

| Platform | Command |
|---|---|
| Linux | `systemctl --user status tg-inbox-mover.path` → `active` |
| macOS | `launchctl list \| grep tg-inbox-mover` → present with last-exit 0 |
| Windows | `Get-ScheduledTask ClaudeTelegramInboxMover` → State `Running` |

If not running: restart it. If running but files still freeze the session: check the destination dir exists and is writable (`~/telegram-inbox/` or `%USERPROFILE%\telegram-inbox\`).

---

## Symptom: `.env` token "not loaded" despite file having the token

Specific to Windows where PowerShell's `Out-File -Encoding utf8` writes a BOM that `server.ts`'s regex doesn't match. See [`post-deploy-hardening.md`](./post-deploy-hardening.md) §5 (subsumed by "settings overwrite" lessons).

BOM check on the `.env` file:

```powershell
$bytes = [System.IO.File]::ReadAllBytes("$env:USERPROFILE\.claude\channels\telegram\.env")
"First 3 bytes: $($bytes[0..2] -join ',')"  # MUST NOT be 239,187,191
```

On Linux/macOS the equivalent (`hexdump -C ~/.claude/channels/telegram/.env | head -1`) should also not show `ef bb bf`, but this is rare since standard Unix tools never write BOM.

Fix: rewrite the `.env` using a BOM-free method:

- Linux/macOS: `echo "TELEGRAM_BOT_TOKEN=$TOKEN" > ~/.claude/channels/telegram/.env`
- Windows: `[System.IO.File]::WriteAllText($path, "TELEGRAM_BOT_TOKEN=$TOKEN`n", [System.Text.UTF8Encoding]::new($false))`

---

## Symptom: daemon works but CLAUDE.md rules aren't being followed

```bash
# Verify both rule blocks are present in both files
for F in ~/CLAUDE.md ~/.claude/CLAUDE.md ; do
  echo "=== $F ==="
  grep -c 'BEGIN: channel-routing-rule' $F
  grep -c 'BEGIN: no-interactive-select-rule' $F
done
```

Expect `1` for each rule in each file. If `0`, re-run the relevant deploy step (Step 9b / Step 10 depending on overlay).

If both rules are present but the daemon still doesn't follow them: **restart the daemon** (a running daemon caches CLAUDE.md at startup; manually-edited rules don't apply until a fresh session). See [`process-supervisors.md`](./process-supervisors.md) for restart commands per platform.

---

## Symptom (Windows): double-clicked `.cmd` shortcut errors with `'M' 不是内部或外部命令` or similar single-letter error

cmd.exe on Chinese-locale Windows (any non-UTF-8 ANSI codepage, but Chinese GBK is the common one) reads `.cmd`/`.bat` files using the **system ANSI codepage, NOT UTF-8**. If the file contains UTF-8 non-ASCII bytes (em-dash `—`, smart quotes `“”`, Chinese punctuation, etc.), cmd splits at misinterpreted byte boundaries and tries to execute leftover residue bytes as commands. Symptom: `'<single-letter>' 不是内部或外部命令` errors, often two or three in a row, before the actual command runs (if it runs at all).

### Diagnose

```powershell
$bytes = [System.IO.File]::ReadAllBytes("<path-to-cmd-file>")
$nonAscii = $bytes | Where-Object { $_ -gt 0x7F }
"non-ASCII bytes: $($nonAscii.Count) (any value > 0 means cmd.exe may misinterpret)"
```

### Fix

Rewrite the file as pure ASCII (replace `—` with `--`, smart quotes with plain, drop any Chinese characters). Write with `[System.Text.ASCIIEncoding]::new()` instead of `[System.Text.UTF8Encoding]::new($false)`.

`.ps1` files are NOT affected — PowerShell reads them as UTF-8 and tolerates non-ASCII fine. The issue is strictly `.cmd`/`.bat` files because they're parsed by cmd.exe.

---

## Symptom: claude session worked for hours, then suddenly stopped replying

This is the **long-session drift** failure (see [`post-deploy-hardening.md`](./post-deploy-hardening.md) §7). Recovery:

1. Restart the daemon — fresh session has clean attention to CLAUDE.md.
2. Don't try to "wake it up" with another Telegram message; the drift is locked in until restart.
3. Long-term: schedule a nightly restart via cron / `launchd` calendar interval / Task Scheduler trigger.

---

## Symptom (macOS): Bash / Read tool returns `Operation not permitted` (errno=1, EPERM) on `~/Downloads`/`~/Documents`/`~/Desktop`

This is the **hardened-`claude.exe` TCC reset** issue, macOS-specific. See [`post-deploy-hardening.md`](./post-deploy-hardening.md) §11 for the full root-cause explanation.

### Diagnose

```bash
# 1. Confirm it's EPERM, not ENOENT (different fix entirely)
# Bash tool output:
#   "Operation not permitted" -> EPERM (errno=1)   ← this section's issue
#   "No such file or directory" -> ENOENT (errno=2), wrong path, not this issue
# In Python: print(e.errno) explicitly; 1=EPERM, 2=ENOENT, 13=EACCES.
# Note: ENOENT and EPERM can coexist — fix the path first, then re-check for EPERM.

# 2. Confirm claude.exe is hardened (Anthropic 2.1.x+ always is)
codesign -dv ~/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe 2>&1 | grep -E "flags|TeamIdentifier"
# Should include "flags=0x10000(runtime)" and "TeamIdentifier=Q6L2SF6YDW".

# 3. Visually inspect the FDA list
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
# claude.exe should be listed with toggle ON.
```

### Fix

Follow `../platforms/macos.md` Step 7e (FDA grant + claude restart). Summary:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
# In FDA pane: unlock -> + -> Cmd+Shift+G ->
#   /Users/<USER>/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/
#   select claude.exe -> Open -> ensure toggle ON
# Then:
pkill -f 'claude .*--channels'
sleep 15
```

### Verify

Run **through the daemon's Bash tool** (so the path goes claude.exe → spawn shell → cat — the only path that exercises the TCC reset):

```bash
cat ~/Downloads/<known-file> | head -1   # should output content, exit 0
```

> **Do NOT** verify with `launchctl bsexec ... /bin/cat ...` — that goes through unhardened `/bin/cat` and gives a false-positive "FDA OK" because the unhardened intermediate inherits launchd-domain FDA. The only valid test is via the daemon's own Bash tool (which routes through hardened `claude.exe`).

### Self-detection

The `macos-fda-self-check-rule` (Rule 3 in [`claude-md-rules.md`](./claude-md-rules.md), installed by macos.md Step 9b) makes the daemon **auto-detect** this state on every session start (including post-respawn after `pkill claude` or post-self-heal-reinstall). If FDA is missing, the daemon proactively `reply`s to the configured Telegram user with the exact fix steps. Make sure that rule is present in both `~/CLAUDE.md` and `~/.claude/CLAUDE.md`:

```bash
grep -l 'BEGIN: macos-fda-self-check-rule' ~/CLAUDE.md ~/.claude/CLAUDE.md
# expected: both paths
```

---

## Last-resort: full nuke + reinstall

If diagnostics aren't converging and you want to start fresh **without losing the bot/pairing**:

```bash
# Linux
systemctl --user stop claude-telegram tg-inbox-mover
rm -rf ~/.claude/plugins/marketplaces/claude-plugins-official  # forces re-clone
claude plugin install telegram@claude-plugins-official
# then re-run skill from Step 4b (the server.ts patch)

# macOS
launchctl bootout gui/$(id -u)/com.openclaw.claude-telegram
launchctl bootout gui/$(id -u)/com.openclaw.tg-inbox-mover
# then same as Linux

# Windows
Stop-ScheduledTask ClaudeCodeTelegramDaemon, ClaudeTelegramInboxMover
Get-Process bun,claude -ErrorAction SilentlyContinue | Stop-Process -Force
Remove-Item -Recurse "$env:USERPROFILE\.claude\plugins\marketplaces\claude-plugins-official"
# re-run plugin install + Step 4b
```

The bot token in `~/.claude/channels/telegram/.env` and the pairing state in `access.json` survive a plugin reinstall. So your bot is still paired after the nuke; you just need to re-deploy and the daemon picks up where it left off.

If even this doesn't help: the issue is likely in the deploy itself (settings, hooks, env vars). Compare your `~/.claude/settings.json` against a known-good reference in the skill's `references/` directory.
