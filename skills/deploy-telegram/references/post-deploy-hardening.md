# Post-deploy hardening: incidents and what they taught us

Initial deploy success is not steady state. This page consolidates the production incidents observed across all three platforms and the permanent fixes folded back into the deploy steps. Reading this is not required to use the skill — but if you suspect upstream changes have eroded a fix, this is where the rationale lives.

Incidents are grouped by failure mode, not platform, because most lessons apply universally even when the implementation differs.

---

## §1. Trust dialog persistence (macOS, Linux first-launch)

**Symptom**: After a reboot or `pkill claude`, the freshly-spawned daemon blocks on:

```
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No, exit
```

Inbound Telegram messages queue silently. The user gets no replies.

**Root cause**: `~/.claude.json` stores per-cwd trust state at `projects.<cwd>.hasTrustDialogAccepted`. Default is `false`. Pressing Enter flips it to `true` for that cwd — but only that one cwd. After a Mac reboot or fresh launchd start, something (Desktop App, CC upgrade, an unknown) sometimes flips it back to `false`, re-prompting on every wrapper restart.

**Fix**: Explicitly patch the field as a deterministic deploy step:

```python
import json, os
p = os.path.expanduser('~/.claude.json')
d = json.load(open(p))
projects = d.setdefault('projects', {})
projects.setdefault(os.path.expanduser('~'), {})['hasTrustDialogAccepted'] = True
json.dump(d, open(p, 'w'), indent=2)
```

Platform overlays:
- **macOS** ([`platforms/macos.md`](../platforms/macos.md) Step 7c): explicit patch step
- **Linux** ([`platforms/linux.md`](../platforms/linux.md)): the original `tmux send-keys Enter` handles first-launch; reboots usually keep trust state on Linux. Patch suggested as defense-in-depth in headless deployments.
- **Windows**: deploy-time visible PowerShell window with the human pressing Enter (Step 8 in [`platforms/windows.md`](../platforms/windows.md)). No reboot resurfacing issue observed since CC stores the answer the same way as Linux/macOS — explicit patch added as defense-in-depth.

---

## §2. `AskUserQuestion` deadlock (universal, but discovered on macOS)

**Symptom**: Daemon goes unresponsive for an extended period (1 h 15 min in the production incident on Mac mini, 2026-05). Telegram user sends messages, no replies. SSH-ing into the daemon's tmux pane reveals an `AskUserQuestion` widget waiting for keyboard input that no one can provide.

**Root cause**: `AskUserQuestion` (and similar numbered-picker widgets) block the main input stream until someone hits arrow keys + Enter **locally**. Inbound channel messages cannot drive them. MCP stdio reaches its idle timeout; the reply tool's response queue silently fills and is dropped.

**Fix**: A hard rule in CLAUDE.md (Rule 2 in [`claude-md-rules.md`](./claude-md-rules.md)) forbidding the model from invoking any select / numbered-picker widget, regardless of mode. The rule applies even in pure terminal mode because a channel can be attached later, and any lingering picker locks it out.

Recovery for an already-stuck session: kill the daemon (`pkill claude` / `Stop-ScheduledTask`) and restart. The session's context is lost.

---

## §3. Claude Code native binary auto-update breakage (macOS, less common on Linux)

**Symptom**: After CC auto-updates, the daemon's `while true; do claude ...; done` loop produces a tight crash/respawn at ~3s interval:

```
Error: claude native binary not installed
Claude exited. Restarting in 3s...
Error: claude native binary not installed
...
```

**Root cause**: `npm install -g @anthropic-ai/claude-code@latest` is supposed to pull a platform-specific optional dependency (`@anthropic-ai/claude-code-darwin-arm64`, `linux-x64`, etc.). Sometimes — observed on macOS Apple Silicon — the optional dep doesn't get pulled, leaving the launcher invoking a `claude.js` that immediately errors on the missing native binary.

**Fix**: Self-healing in `start-claude.sh`'s loop. Before each `claude --channels` invocation:

1. Run `claude --version`. If it succeeds, proceed.
2. If it fails with `"native binary not installed"`, run `npm install -g @anthropic-ai/claude-code@latest`. Verify it healed.
3. **Notify the user directly via Telegram Bot API** (since MCP reply tool is unavailable while claude is broken): `curl https://api.telegram.org/bot<token>/sendMessage`
4. Apply exponential backoff (60s → 300s → 900s → 1800s) if self-heal fails repeatedly, so a real outage doesn't burn through 10-minute reinstalls in a tight loop.

**Platform applicability**:
- **macOS** ([`platforms/macos.md`](../platforms/macos.md) Step 7.1): self-heal integrated into `start-claude.sh`. The macOS deploy was the original site of this incident.
- **Linux**: same risk in principle; Linux skill could be enhanced with the same logic. As of writing, not observed in production on Linux servers.
- **Windows**: the daemon reuses the **bundled `claude.exe` from the Desktop App's directory**, which Anthropic manages via its own auto-updater (not npm). The npm optional-dep failure mode doesn't apply. If the Desktop App's bundled binary breaks, the user would need to reinstall the Desktop App — out of scope for this skill.

---

## §4. Desktop App vs CLI bot-token contention (macOS-specific currently, but worth understanding)

**Symptom** (macOS only, as of 2026-05): both the Claude Desktop App and a CLI `claude` session running on the same Mac under the same user. Both read `~/.claude/settings.json`. If `enabledPlugins.telegram@claude-plugins-official: true` is set at user scope, both processes try to load the plugin. The Telegram plugin's bun MCP server makes a `getUpdates` call. Two long-pollers on the same bot token → HTTP 409 Conflict → only the most recently-started consumer wins, the other loses all messages.

**Root cause**: On macOS, the Desktop App's claude invocation **does** include `--channels` (or some equivalent that activates channel polling) when channels are enabled in settings.json. So both Desktop App and the deploy-telegram daemon become long-poll competitors.

**Fix**: Install the Telegram plugin at **local scope** of the daemon's launch cwd (`$HOME`), not user scope. This writes the enable-flag to `$HOME/.claude/settings.local.json` instead of `~/.claude/settings.json`. The plugin then only auto-loads when `claude` starts from `$HOME` — which the daemon's launcher always does (`cd ~`), but the Desktop App doesn't.

For belt-and-suspenders, the macOS deploy can also write `enabledPlugins.telegram@...: false` to the Desktop App's typical cwd's local settings (Step 7d, optional).

**Windows**: investigated three times across 2026-05-21 → 2026-05-22; **conclusion evolved**:

| Investigation | Conclusion | Status |
|---|---|---|
| 2026-05-21 morning, right after deploy | "Windows doesn't contend" — Desktop App uses `--plugin-dir`, not `--channels`, so won't spawn its own bun | ❌ **wrong** — observation was a transient state before Desktop App had picked up `enabledPlugins.telegram=true` from the just-written settings.json |
| 2026-05-21 night, post-reboot | Windows **does** contend: both Desktop App's claude.exe (with `--plugin-dir <plugin-cache>`) and daemon claude.exe (with `--channels`) spawn bun for the same plugin. Both bun processes race for the bot's `getUpdates` slot. | confirmed |
| 2026-05-22 night, post-reboot | Contention exists, **but `server.ts`'s built-in `bot.pid` stale-poller-kill mechanism provides self-healing** (`server.ts:60-68` reads `bot.pid`, SIGTERMs the existing poller, writes own PID). Empirically the daemon Scheduled Task spawns bun slightly faster than GUI Desktop App, so daemon's bun usually establishes first; when Desktop App's bun then starts and kills daemon's via SIGTERM, daemon's while-loop respawns a new bun that kills Desktop App's. In one observed case (2026-05-22), Desktop App's claude.exe didn't aggressively re-spawn its bun after the first kill — so daemon-bun-2 ended up alone. Net outcome: **most reboots, daemon ends up solo**. | empirical, race-dependent |

### Symptom of a lost race (rare but possible)

Post-boot, `Get-Process bun` shows bun processes but their parent is Desktop App's claude.exe (cmd contains `--plugin-dir`), not daemon's (`--channels`). Daemon claude.exe alive with no bun children. Telegram messages don't reach Claude.

### Recovery if you lose the race

```powershell
# Kill Desktop App's bun children (anything not parented by --channels claude.exe)
Get-CimInstance Win32_Process -Filter "Name='bun.exe'" | ForEach-Object {
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)"
    if ($parent.CommandLine -notlike '*--channels*') { Stop-Process -Id $_.ProcessId -Force }
}
# Kill daemon claude.exe to force a fresh bun spawn (while-loop will restart in 3s)
Get-CimInstance Win32_Process -Filter "Name='claude.exe'" |
    Where-Object { $_.CommandLine -like '*--channels*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
# Daemon's new bun will write bot.pid; Desktop App's claude.exe typically doesn't re-spawn bun after being killed once
```

### Optional permanent fix (untested; reserved for high-reliability setups)

The "negative local override" approach: set `enabledPlugins.telegram@claude-plugins-official: false` in `<desktop-app-cwd>/.claude/settings.local.json` (e.g. `D:\projects\.claude\settings.local.json` if the user opens the Desktop App project from `D:\projects`). Daemon must launch from a different cwd (e.g. `$env:USERPROFILE`) where the override is absent. **Untested in production** — the self-healing race was sufficient for our validation deployments, so we did not roll this out. The trade-off: requires the operator to commit to a separate daemon cwd (forfeiting any `D:\projects\CLAUDE.md` auto-loading by the daemon).

### Why we don't recommend the local override by default

1. The current self-healing covers most reboot cases (4 of 4 in our validation period; 1 needed manual `Stop-Process` after a botched debugging session, not after a clean reboot)
2. Forcing a different daemon cwd loses the project-local CLAUDE.md affinity that operators usually want
3. The recovery command above is one PowerShell snippet — manageable as an occasional manual step

**Linux**: not affected — no Linux Desktop App ships an integrated CC session, only the CLI. There's nothing to contend with.

---

## §5. Settings file overwrite clobbering user state (universal)

**Symptom**: After running the skill, some pre-existing setting that the user / another tool had configured is gone:

- A user-installed analytics PreToolUse hook erased (observed on the 2026-05-21 Windows validation deploy — the operator had a third-party tool-usage reporter wired up)
- Desktop App's per-cwd `projects.<cwd>` state in `~/.claude.json` erased (would have been observed on macOS if the skill ran the Linux pattern, hence the macOS skill explicitly avoids it)
- Custom MCP servers in `mcpServers` erased
- User-customized `permissions.allow` shortened

**Root cause**: The original Linux skill's Steps 3 and 4 use bash here-doc `cat > <file> << EOF` which fully overwrites. Whatever the file used to contain is destroyed silently.

**Fix**: All overlays now **merge additively**:

- **macOS** uses inline Python (`json.load` → mutate → `json.dump`)
- **Windows** uses PowerShell (`Get-Content -Raw | ConvertFrom-Json` → mutate → `ConvertTo-Json | WriteAllText`)
- **Linux** should adopt the macOS Python pattern (current overlay still uses `cat > EOF`; planned fix as part of this refactor)

Before any mutation: copy the file to `<path>.before-deploy-telegram.bak`. Idempotent on re-runs (only backs up if no backup exists). Gives the user a clean undo path.

> **`~/.claude.json` deserves extra care.** On macOS the Desktop App writes ~23 KB of session/project state there (`projects`, `oauthAccount`, `tipsHistory`, `cachedGrowthBookFeatures`, `seenNotifications`, etc.). Overwriting it would log the user out of Desktop App and lose months of cached state. **Always merge, never replace.**

---

## §6. UserPromptSubmit hook doesn't fire on channel messages (production bug 2026-05-06)

**Symptom**: `~/.claude/CLAUDE.md` and `~/CLAUDE.md` both correctly contain the channel routing rule. The `~/telegram-routing-hook.sh` (UserPromptSubmit hook) is correctly registered in `settings.json`. But the daemon still drifts after a long session — Claude writes to stdout instead of calling the reply tool. Inspection of the jsonl session log shows **zero** occurrences of the "TELEGRAM ROUTING MANDATORY" string the hook should inject.

**Root cause**: Channel-routed messages go through a different code path inside Claude Code's input handler — `queue dequeue → user message`, which **bypasses `UserPromptSubmit`** entirely. The hook fires correctly for terminal-typed messages but never for Telegram pushes.

**Implication**: The routing hook is **defense-in-depth, not a guarantee**. It still helps when:
- The user types reminders from the daemon's terminal (rare in production)
- Future Claude Code versions route channel messages through `UserPromptSubmit` (potentially planned)
- It's installed for free anyway and may help with channel modes not yet invented

But the **primary defense remains the CLAUDE.md rule** + post-compact mitigation (currently no defense beyond "be more aggressive about restarting the daemon every few days").

---

## §7. Long-session attention drift (production bug 2026-05-06)

**Symptom**: A claude daemon that has been running for ~49 hours suddenly stops calling the reply tool for Telegram messages, even though it was working perfectly for the first 48 hours. The drift is cliff-like, not gradual.

**Root cause**: After many `compact` operations in a long session, model attention to the CLAUDE.md rule erodes. Once one turn skips the reply tool successfully (no immediate consequence visible to the model), subsequent turns follow the pattern.

**Mitigation** (not a fix): restart the daemon every ~24 hours. The simplest cron approach is to schedule a "midnight kill + relaunch" Task. Out of scope for the deploy skill itself.

**Long-term fix** (not implemented): a watchdog that monitors the bot's `getUpdates` for high-latency / dropped acks and force-restarts. The Mac skill's self-heal logic could be extended to detect this case.

---

## §8. Slash commands over Telegram don't work (universal architectural limit)

**Symptom**: User sends `/model opus`, `/clear`, `/compact`, `/cost`, `/help` from Telegram. Instead of switching models / clearing context / etc., Claude either replies "I can't change my own model" or processes the literal string as a normal user prompt.

**Root cause**: Claude Code's slash-command parser only intercepts input typed **directly into the local terminal**. Messages arriving via the Telegram channel plugin are injected into the prompt stream **after** the CLI's input parser, so the model sees the literal string `/model opus` as a normal user message.

**Implications** (this is a hard architectural limit, not a bug to be patched):

- Cannot switch model from Telegram. To change: edit `start-claude.{sh,ps1}` to add `--model <name>` (or set `env.ANTHROPIC_MODEL` in settings.json), then kill+relaunch the daemon.
- Cannot clear context (`/clear`), compact (`/compact`), check cost (`/cost`) from Telegram. For clear context remotely: restart the daemon (fresh session has empty context).
- The pairing slash commands (`/telegram:access pair <code>` / `policy allowlist`) MUST be entered in the daemon's terminal — see [`pairing-and-access.md`](./pairing-and-access.md).

This is documented in every platform overlay as an "operating note", not as a bug.

---

## §9. Mainland-China network access (deployment-level)

**Symptom**: Server can't reach `api.telegram.org`. Bun fails on every long-poll. Plugin install via `claude plugin install` fails on GitHub fetches.

**Root cause**: Telegram and GitHub are blocked from mainland-China public networks.

**Fix**: Deploy to a server outside mainland China (HK, SG, JP, US, EU all confirmed working). VPN-on-host is possible but fragile.

**Windows local deploy**: this same constraint applies to your local network. If your home network is mainland-China-blocked, neither the Bun long-poll nor `claude plugin install` will work even from a Windows desktop. A consumer VPN on the Windows machine itself solves this.

---

## §10. server.ts UTF-8 corruption (Windows, non-UTF-8 ANSI codepages)

### Symptom

Daemon shows "**1 MCP server failed · /mcp**" in its TUI, and `/mcp` detail page reports the telegram plugin's MCP server as `× failed`. Status doesn't include an error reason. Telegram messages queue up at `getUpdates` (`ok=true, msgs>0`) and no consumer drains them. Daemon's claude.exe is alive but has **zero bun children**.

Surfaces in production on:
- 2026-05-21, a Windows 11 validation PC (Chinese locale, GBK as ANSI codepage). Discovered after a reboot ~6 hours into the deploy. Diagnosis went down three wrong rabbit holes (Desktop App contention, `--scope local` plugin install, `--setting-sources` flag) before manual `bun run` invocation revealed the real error.

### Root cause

`server.ts` was corrupted by a tool reading the file with the **system ANSI codepage** instead of explicit UTF-8, then writing it back. On Chinese Windows the ANSI codepage is **GBK**, which mis-reads emoji bytes (e.g. `'✅'` and `'❌'` at line 937) and produces mojibake on writeback. The corruption is invisible to a casual reader of the file (it just looks weird), but **bun parses TypeScript strictly as UTF-8 and errors out** at the first malformed byte sequence.

Manual bun invocation reveals the exact error:

```
error: Expected " =" but found "閴?"
    at C:\Users\<user>\.claude\plugins\cache\claude-plugins-official\telegram\0.0.6\server.ts:937:74
error: Unexpected ?
    at C:\Users\<user>\.claude\plugins\cache\claude-plugins-official\telegram\0.0.6\server.ts:937:75
Bun v1.3.14 (Windows x64)
```

### What corrupted the file

Most likely candidate: **PowerShell 5.1's `Get-Content` without `-Encoding UTF8`** in the skill's Step 4b patch step. Windows PowerShell 5.1 defaults to the system codepage for I/O — on Chinese Windows, that's GBK. So:

1. UTF-8 emoji `'✅'` (3 bytes `0xE2 0x9C 0x85`) is read as 1–2 GBK characters (mojibake)
2. `-replace` operates on the mojibake string (doesn't touch line 937)
3. `[System.IO.File]::WriteAllText(..., UTF8Encoding($false))` writes the mojibake-as-UTF-8 back
4. Result: line 937 emoji is now corrupted bytes

The corruption is **silent at patch time** — the patched line (393) IS correctly modified; the unrelated line 937 is collateral damage. Bun fails to parse only when claude tries to start it for the first time after the corruption — could be hours or days later.

### Permanent fix (in skill's Step 4b)

Always read and write `server.ts` with **explicit UTF-8 encoding**:

```powershell
# Read
$content = [System.IO.File]::ReadAllText($serverTs, [System.Text.UTF8Encoding]::new($false))
# ... modify $content ...
# Write
[System.IO.File]::WriteAllText($serverTs, $content, [System.Text.UTF8Encoding]::new($false))
```

**Do not** use `Get-Content -Raw` without `-Encoding UTF8` in PowerShell 5.1. (PowerShell 7+ defaults to UTF-8 and is safe.) Linux/macOS shells handle UTF-8 transparently — bash/sed inherit the locale and most modern systems use `en_US.UTF-8` / similar. Only Windows + non-UTF-8 locale is affected.

### Recovery (if you already hit this)

The skill's Step 4b creates `server.ts.bak` **before** patching, on first run. If you have that backup, just restore it and re-patch with the correct encoding:

```powershell
$pluginDir = "$env:USERPROFILE\.claude\plugins\marketplaces\claude-plugins-official\external_plugins\telegram"
$cacheDir = (Get-ChildItem "$env:USERPROFILE\.claude\plugins\cache\claude-plugins-official\telegram" -Directory | Sort-Object Name -Descending | Select-Object -First 1).FullName

# Restore both source and cache
Copy-Item "$pluginDir\server.ts.bak" "$pluginDir\server.ts" -Force
Copy-Item "$cacheDir\server.ts.bak" "$cacheDir\server.ts" -Force

# Re-apply patch with explicit UTF-8
foreach ($f in "$pluginDir\server.ts", "$cacheDir\server.ts") {
    $content = [System.IO.File]::ReadAllText($f, [System.Text.UTF8Encoding]::new($false))
    $patched = $content -replace "(?m)^(\s*)'claude/channel/permission':\s*\{\},", "`$1// 'claude/channel/permission': {}, // DISABLED: relays tool prompts to TG"
    if ($patched -ne $content) {
        [System.IO.File]::WriteAllText($f, $patched, [System.Text.UTF8Encoding]::new($false))
    }
}

# Restart daemon — its bun will now parse cleanly
Stop-ScheduledTask -TaskName ClaudeCodeTelegramDaemon -ErrorAction SilentlyContinue
Get-Process bun, claude -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -eq 'bun' -or (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.Id)").CommandLine -like '*--channels*'
} | Stop-Process -Force -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName ClaudeCodeTelegramDaemon
```

If you **don't** have the `.bak` (e.g. you wiped the plugin cache or skipped Step 4b's patch and corrupted via a different tool), reinstall the plugin from scratch:

```powershell
& $CLAUDE_EXE plugin uninstall telegram@claude-plugins-official
Remove-Item "$env:USERPROFILE\.claude\plugins\cache\claude-plugins-official\telegram" -Recurse -Force -ErrorAction SilentlyContinue
& $CLAUDE_EXE plugin install telegram@claude-plugins-official
# Now re-apply the patch using the UTF-8-safe Step 4b code
```

### Diagnostic shortcut

To detect this **before** bun crashes (e.g. as part of a post-deploy verification):

```powershell
# True if file has been UTF-8-corrupted via GBK round-trip
$bytes = [System.IO.File]::ReadAllBytes("$env:USERPROFILE\.claude\plugins\marketplaces\claude-plugins-official\external_plugins\telegram\server.ts")
# Look for the "閴" mojibake byte sequence (E9 96 B4 in UTF-8)
$corrupted = $false
for ($i = 0; $i -lt $bytes.Length - 2; $i++) {
    if ($bytes[$i] -eq 0xE9 -and $bytes[$i+1] -eq 0x96 -and $bytes[$i+2] -eq 0xB4) { $corrupted = $true; break }
}
if ($corrupted) { "server.ts is GBK-corrupted; restore from .bak" } else { "server.ts UTF-8 clean" }
```

### Why this wasn't caught in initial validation

The first deploy on 2026-05-21 worked end-to-end because:
- The patch was applied **once** with the buggy code, producing the corrupted file
- The corruption was at line 937 (permission-reply emoji code path)
- The first roundtrip test ("哈喽" → reply) didn't exercise that code path
- bun started fine on first launch (the parse error doesn't fire until bun tries to parse the file — and bun caches parsed JS, so a hot bun process keeps working until restarted)
- A Windows reboot later (6 hours after deploy), Scheduled Task spawned a **fresh** bun, which freshly parsed server.ts, hit the corruption, and failed

This is a **dormant** failure mode: it can sit undiscovered for any amount of time and surface on the next daemon restart. Recommend adding the diagnostic check above to your post-deploy health check.

---

## §11. macOS hardened-runtime `claude.exe` lacks Full Disk Access out of the box (macOS-only)

### Symptom

Deploy succeeds — launchd agents loaded, tmux session alive, claude listening, bun spawning correctly, scope isolation in place, bot token owned exclusively by the daemon. Telegram user sends `cat ~/Downloads/<file>` or asks Claude to analyze a file in `~/Documents/`. Claude reports `errno=1 EPERM` ("Operation not permitted") — even though `os.path.exists()` returns True and the user can read the file via the Desktop App's Bash tool.

The deploy appears complete by every standard check (process tree, getUpdates, pairing, reply roundtrip), but is **functionally incomplete** for any file work on TCC-protected paths.

### Root cause

`claude.exe` (the npm-installed binary at `~/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`) is a hardened-runtime, code-signed Mach-O. Verified via `codesign -dv`:

- `flags=0x10000(runtime)` ← hardened runtime ON
- `Identifier=com.anthropic.claude-code`
- `TeamIdentifier=Q6L2SF6YDW` (Anthropic)

macOS TCC inheritance is based on the **responsible process**, not just the parent process. For unhardened binaries (`/bin/bash`, `/bin/cat`, `tmux`, etc.), responsible-process flows through fork normally. For hardened binaries, the system **resets** the chain — subprocess TCC checks evaluate against the hardened binary, not its launchd ancestor.

Even though the launchd chain (`launchd → wrapper → tmux → start-claude.sh`) inherits user-domain FDA fine, **`claude.exe` resets it**, and any Bash tool / Python / sh subprocess gets TCC-evaluated against `claude.exe`'s own grants — which are empty by default.

### Misleading test (don't repeat this mistake)

The first diagnosis on 2026-05-22 tested:

```bash
launchctl bsexec <wrapper-PID> /bin/cat ~/Downloads/<file>
# exit 0, content output
```

…and (wrongly) concluded "the entire launchd-spawned tree has FDA, the EPERM claim must be a hallucination."

**The test was a false positive for the wrong code path.** `/bin/cat` is unhardened, so it inherited launchd-domain FDA. The actual code path inside Claude's Bash tool is:

```
launchd → wrapper → tmux → start-claude.sh → claude.exe (HARDENED, TCC RESET) → spawn /bin/bash → cat
```

which has the TCC reset at `claude.exe` and was never tested. **Always test the exact code path of the failing process, not a convenient adjacent one** — the lesson generalizes to any sandbox / permission system (Linux capabilities, Windows MIC, etc.).

This same false-positive trap is **why the FDA self-check rule installed by Step 9b lives in CLAUDE.md (executed via the Claude Bash tool), not in `start-claude.sh`**. A shell-level probe inside `start-claude.sh` would run as unhardened `/bin/bash` and report success even when `claude.exe` itself is grant-less.

### Permanent fix (macos.md Step 7e)

Add `claude.exe` to System Settings → Privacy & Security → Full Disk Access. One-time per Mac, GUI-only (TCC.db is SIP-protected; `tccutil` can reset but not grant). After grant:

```bash
pkill -f 'claude .*--channels plugin:telegram@claude-plugins-official'
# start-claude.sh's while-true loop respawns claude; new process inherits the new TCC grant
sleep 15
# subprocesses can now read protected paths
```

### Re-application after CC updates

`npm install -g @anthropic-ai/claude-code@latest` (the self-heal path in Step 7.1) replaces `claude.exe`. TCC matches by path + signing identity. Same-Anthropic-signed updates typically preserve the grant. If a future update changes signing identity (new TeamIdentifier or unsigned), the grant is lost and Step 7e must be re-run. Symptom is recurring EPERM after CC upgrade — the FDA self-check rule (Rule 3 in [`claude-md-rules.md`](./claude-md-rules.md)) installed by Step 9b catches this automatically and pings the user via Telegram on the next session start.

### Diagnostic commands

```bash
# Verify claude.exe is hardened (sanity check; Anthropic 2.1.x+ always is)
codesign -dv ~/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe 2>&1 | grep -E "flags|Identifier"
# Output should include "flags=0x10000(runtime)" and "TeamIdentifier=Q6L2SF6YDW"

# Visually inspect FDA list (no programmatic way; TCC.db is SIP-protected)
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

# Functional test — must route through claude.exe's subprocess chain
# (run via the Claude Bash tool inside the daemon's session, not via launchctl bsexec)
cat ~/Downloads/.DS_Store >/dev/null 2>&1 && echo "FDA OK" || echo "FDA STILL MISSING"
```

### Discovery timeline

- 2026-05-14 → 2026-05-21: macOS deploy lives in production, four hardening fixes layered on. All file work via Telegram happens to target `~/Library/`, `~/code/`, etc. — paths NOT covered by TCC defaults. No EPERM observed.
- 2026-05-22: First Telegram request to read `~/Downloads/<file>` fails with EPERM. Two-phase investigation: Phase 1 misled by `launchctl bsexec` false positive (saw exit 0, concluded "launchd-spawned tree has FDA"). Phase 2 isolated the responsible-process reset by `codesign -dv` + manual System Settings inspection. Step 7e written and verified.
- 8-day delay between deploy completion and discovery is what makes this failure mode dangerous — operators may declare a deploy "done" and find out months later when a user happens to request a Downloads file.

### Cross-platform applicability

The failure mode is **macOS-specific** (TCC is a macOS subsystem). Linux servers and Windows machines don't have an equivalent failure path because:

- **Linux**: no hardened-runtime concept for npm-installed Node binaries. Subprocess permissions inherit via standard Unix uid/gid; FDA-style sandboxing isn't a thing outside container runtimes.
- **Windows**: claude.exe is unsigned-or-MS-signed Node binary; UAC/MIC operate on a different model (per-process integrity level, not responsible-process reset). The Windows deploy hasn't exhibited an analogous EPERM mode.

The general **design principle** ("self-check at the same TCC/sandbox layer the failure happens at") does carry forward — if Windows or Linux add a future restriction analogous to macOS hardened-runtime + TCC, the same CLAUDE.md-rule-via-Bash-tool pattern applies. Worth re-evaluating for each platform on major OS updates.

---

## §12. Claude Code 2.1.149+ ignores user-scope `enabledPlugins` for `--channels` auto-load (universal)

### Symptom

Deploy completes; `claude plugin install telegram@claude-plugins-official` succeeds; `~/.claude/settings.json` contains `enabledPlugins.telegram@claude-plugins-official: true`. But:

- `claude plugin list` shows the plugin as `× disabled`
- Daemon's `claude --channels plugin:telegram@claude-plugins-official` starts, stays alive, but **does not spawn bun**
- No 409, no error, daemon TUI may show "Listening for channel messages" but functionally nothing flows
- Manual `bun run --cwd <plugin-cache-dir> ...` works perfectly (so it's not a server.ts / token / network issue)

Empirically observed on Windows after the Desktop App auto-updated from 1.8089 → 1.8555 (which bumped bundled `claude-code` from 2.1.142 → 2.1.149) on 2026-05-26. After a reboot, the previously-working daemon went silent. Diagnosis took ~30 min and went through several wrong leads (battery policy on Scheduled Task, hardcoded version path, dynamic version pick) before `claude plugin list` showing `× disabled` revealed the real cause.

### Root cause

Claude Code 2.1.149 changed the plugin-loading semantics:

- **Pre-2.1.149**: `enabledPlugins.<name>: true` in **any** of the merged-in settings files (user, project, local) was enough to enable the plugin
- **2.1.149+**: only **local-scope** `<cwd>/.claude/settings.local.json` is consulted for `enabledPlugins`. User-scope `~/.claude/settings.json` is **silently ignored** for this specific field

So a deploy that ran `claude plugin install` without `--scope local` (which writes user-scope) leaves the plugin "registered" but "disabled" from 2.1.149's loader's perspective. `claude --channels` sees the plugin name on the command line but, finding no local-scope enable, skips spawning its MCP server (bun).

Not announced as a breaking change in CC release notes (as of writing) — discovered empirically.

### Fix

After `claude plugin install`, **explicitly** run `claude plugin enable telegram@claude-plugins-official` from the cwd the daemon will use. This writes the local-scope `settings.local.json`:

```bash
# Linux / macOS — from the daemon's launch cwd (typically $HOME)
cd ~
claude plugin install telegram@claude-plugins-official   # or --scope local on Mac
claude plugin enable telegram@claude-plugins-official    # writes ~/.claude/settings.local.json
```

```powershell
# Windows — from the daemon's launch cwd (typically $env:USERPROFILE)
Set-Location $env:USERPROFILE
& $claudeExe plugin install telegram@claude-plugins-official
& $claudeExe plugin enable telegram@claude-plugins-official   # writes ...\.claude\settings.local.json
```

Verify with `claude plugin list` — should now show `√ enabled`. Verify by inspecting `<cwd>/.claude/settings.local.json` exists and contains `"enabledPlugins": { "telegram@claude-plugins-official": true }`.

### cwd-coupling caveat

`settings.local.json` is **per-cwd**. If the daemon's launcher script (`start-claude.sh` / `start-claude.ps1`) later changes its `cd` / `Set-Location` to a different directory, the enable doesn't follow — daemon will show plugin disabled again. **Re-run `claude plugin enable` from any new daemon cwd**, or design the deploy to lock the daemon cwd at install time.

Failure pattern: operator deploys at `$HOME`, plugin enabled, daemon works. Later edits `start-claude.sh` to `cd /opt/projects` for project-context reasons. Next daemon restart: plugin shows disabled because `/opt/projects/.claude/settings.local.json` doesn't exist. Wastes time re-diagnosing.

### Side benefit: less Desktop App contention

Local-scope install also reduces the Desktop App contention discussed in §4 (macOS) / its Windows variant. Since the Desktop App's claude.exe usually runs from a different cwd than the daemon's, it won't auto-load a plugin enabled only at the daemon's cwd's local scope. **Net upgrade: 2.1.149's restriction effectively forces the same isolation pattern Mac always recommended.**

### Re-application after CC updates

`npm install -g @anthropic-ai/claude-code@latest` / Desktop App auto-update / cache wipe → may not touch `settings.local.json`, so the enable typically survives. But if a future CC version changes the local-scope file location or schema, the enable could be lost silently. The CLAUDE.md no-self-check rule for "is plugin enabled" doesn't exist today; add it as a CLAUDE.md rule (similar to macOS FDA self-check Rule 3) if this becomes a recurring problem.

### Diagnostic check

```bash
# Linux / macOS
claude plugin list | grep telegram   # must show "enabled", not "disabled"
test -f <daemon-cwd>/.claude/settings.local.json && \
  jq -r '.enabledPlugins."telegram@claude-plugins-official"' <daemon-cwd>/.claude/settings.local.json
# Expected output: true
```

```powershell
# Windows
& $claudeExe plugin list | Select-String 'telegram.*enabled'
(Get-Content "$DAEMON_CWD\.claude\settings.local.json" -Raw | ConvertFrom-Json).enabledPlugins
```

### Why we discovered this only on Windows

Reboot exposed the problem because the daemon process needs to re-load settings on each launch. On Linux production servers (rarely rebooted), the old daemon process kept running with cached plugin state from the pre-2.1.149 install, masking the bug. On Mac, the skill already uses `--scope local` install which (depending on 2.1.149's exact semantics) may write local-scope enable as a side effect. Windows, with frequent reboots and user-scope install, was the most exposed.

---

## §13. macOS manual recovery script — `fix-telegram-daemon.command` (macOS-only)

### Problem

On macOS the daemon can land in any of four broken states that all look the same to the user (Telegram messages stop being answered):

1. `bun server.ts` crashed but the parent `claude` is still alive — no respawn happens because nothing notices the bun is gone.
2. Two `bun server.ts` processes are alive, contending for the bot token (a Desktop App's `claude --plugin-dir` and the daemon's `claude --channels` both spawned one). Whichever issued the most recent `bot.pid` SIGTERM wins — and on Mac this is non-deterministic, same as Windows §4.
3. `claude` died but the supervising tmux session is still up. `start-claude.sh`'s while-loop *should* respawn it, but launchd / tmux / shell timing can occasionally leave the pane stuck.
4. The whole `claude` tmux session is gone — usually a launchd hiccup after a heavy sleep/wake cycle.

Manually diagnosing which one and applying the right remedy is annoying and error-prone, especially for a non-developer operator. We want a one-click recovery.

### Solution

`fix-telegram-daemon.command` is installed by Step 10 of [`../platforms/macos.md`](../platforms/macos.md) to `~/Desktop/`. Double-clicking it triggers a five-branch decision tree:

| Detected state | Action |
|---|---|
| Multiple `bun server.ts` | Walk each bun's parent chain; keep the one whose grand/parent is the daemon's `claude`, `kill` the rest |
| `bun` gone, `claude` alive | `kill` claude — `start-claude.sh`'s while-loop respawns the chain fresh (~15 s downtime) |
| `claude` gone, `tmux` up | Wait up to 60 s for auto-restart; only `tmux send-keys` if the pane is provably idle |
| `tmux` session gone | `tmux new-session -d -s claude ~/start-claude.sh` |
| Everything healthy | Send one "all good" Telegram message, exit 0 |

All five branches are idempotent — re-running converges to the same end state.

### Why this is structured the way it is

**`ps aux \| awk` instead of `pgrep -f`**: when the script runs from within a `claude` subprocess (e.g. operator asks Claude over Telegram to "run the fix script for me"), the subprocess sandbox prevents `pgrep -f` from seeing its own ancestors. `ps aux | awk` has no such restriction and works in every context.

**Direct `curl` to Bot API for notifications, not the MCP `reply` tool**: the whole point of running this script is that the MCP pipeline may be broken. So `tg()` posts to `https://api.telegram.org/bot${BOT_TOKEN}/sendMessage` directly. The user gets visible feedback ("starting repair", "repair complete", "repair failed") even when `mcp__plugin_telegram_telegram__reply` is fully dead.

**`BOT_TOKEN` is read from `~/.claude/channels/telegram/.env` at run time, not hardcoded**: the script in this repo ships with **no secrets**. The deploy-telegram skill writes `.env` during Step 6, so by the time the script gets installed in Step 10, the token is already there. If the `.env` is missing or unreadable, notifications are skipped silently and the kill/restart logic still runs.

**`CHAT_ID` is `<CHAT_ID>` until install time**: Step 10 uses `sed` to substitute the operator's Telegram user_id. If the placeholder is still present at run time (someone copied the script manually without the install step), notifications are skipped silently and the kill/restart logic still runs.

**`tmux send-keys` is guarded by an idle check**: if `claude` is dead but `tmux` is still up, the script waits up to 60 s for `start-claude.sh`'s while-loop to auto-respawn. Only if that times out *and* `tmux display-message -p '#{pane_current_command}'` returns something other than `bash` / `sh` (i.e. the pane is actually idle) does it inject `exec bash $START_SCRIPT`. This prevents the script from spamming `Enter` into a still-running `start-claude.sh` and corrupting its state.

### Why NOT auto-fire on logon (unlike Windows)

The Windows version (`fix-daemon.ps1`) is registered as a Scheduled Task that fires 90 s after each logon, because the Windows bot.pid race is a *guaranteed* contention every reboot. macOS doesn't have the same boot-time guarantee — the daemon's launchd plist + `start-claude.sh` while-loop already handle most reboot cases cleanly. The Mac script stays **manual-only**: a defensive safety net when sleep/wake or transient launchd issues leave the daemon stuck, not an unconditional reboot ritual.

If you want symmetry with Windows, you can wrap `fix-telegram-daemon.command` in a launchd `RunAtLoad=true` plist — but the trade-off (extra ~15 s daemon downtime on every login, for negligible reliability gain on most macOS deployments) is not worth it by default.

### Production validation

The script was developed and field-tested across multiple incidents on the Mac mini deployment (Darwin 24.6.0 arm64) between 2026-05-22 and 2026-05-31, refining the five-branch decision tree from production observations of each failure mode.

### What this section does NOT cover

- The script does not address the **root cause** of any of the four broken states — it just brings the daemon back to a known-good state. Root causes for the contention case are in §4; for UTF-8 corruption-induced crashes in §10; for 2.1.149 plugin-load failure in §12.

---

## §14. Claude Code 2.1.170+ rejects bare `mcp__*` in `allow` rules (universal)

### Symptom

On launch (daemon window or any `claude` session), a startup warning appears:

```
Settings Warning
  ~/.claude/settings.json
   └ permissions
     └ allow: Invalid permission rule "mcp__*" was skipped: Wildcard tool name
       "mcp__*" is not supported in allow rules. An allow pattern must name the
       scope it widens — globs are permitted only in the tool position after a
       literal mcp__<server>__ prefix. Deny and ask rules accept wildcards anywhere.
  The values listed above were skipped; the rest of the file is in effect.
```

`/doctor` also flags it as a setup issue. The rest of `settings.json` still loads — this is a warning, not a fatal error — but it prints on every launch and is noise.

### Cause

Earlier versions of this skill wrote `"mcp__*"` into `permissions.allow` to auto-allow all MCP tools. **Claude Code 2.1.170 tightened `allow`-rule validation**: a glob in an allow rule may now appear *only* in the tool position after a literal `mcp__<server>__` prefix. `deny` and `ask` rules still accept wildcards anywhere — only `allow` is restricted. A bare `mcp__*` (glob in the server position) is therefore rejected and skipped.

### Fix

Replace the bare wildcard with a server-scoped one. For this skill the only MCP server that matters is the Telegram plugin, whose tools are namespaced `mcp__plugin_telegram_telegram__*`:

```jsonc
// permissions.allow
"NotebookEdit(*)",
"mcp__plugin_telegram_telegram__*"   // was: "mcp__*"
```

> Note: this skill always sets `permissions.defaultMode: "bypassPermissions"`, under which the entire `allow` list is redundant (everything is allowed regardless). So removing `mcp__*` outright is equally valid functionally. The server-scoped rule is kept only to preserve intent for operators who later switch `defaultMode` away from bypass.

The platform install steps now write the valid rule on fresh installs, and the Windows overlay's else-branch (existing-`permissions` case) actively strips any legacy `mcp__*` so a re-deploy self-heals an older install. Linux/macOS use a `set()`-based merge that `.discard("mcp__*")`s the legacy value on every run.

### To fix an already-deployed machine without re-running the skill

```bash
# Linux / macOS
python3 - <<'PY'
import json, os
p = os.path.expanduser('~/.claude/settings.json')
d = json.load(open(p))
allow = [a for a in d.get('permissions', {}).get('allow', []) if a != 'mcp__*']
if 'mcp__plugin_telegram_telegram__*' not in allow:
    allow.append('mcp__plugin_telegram_telegram__*')
d['permissions']['allow'] = allow
json.dump(d, open(p, 'w'), indent=4)
print('fixed')
PY
```

```powershell
# Windows (UTF-8, no BOM)
$p = "$env:USERPROFILE\.claude\settings.json"
$j = Get-Content $p -Raw | ConvertFrom-Json
$j.permissions.allow = @($j.permissions.allow | Where-Object { $_ -ne 'mcp__*' })
if ($j.permissions.allow -notcontains 'mcp__plugin_telegram_telegram__*') {
    $j.permissions.allow += 'mcp__plugin_telegram_telegram__*'
}
[System.IO.File]::WriteAllText($p, ($j | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
```

Restart the daemon (or just wait for the next launch) for the warning to clear.

---

## Verifying a healthy deployment

After running the skill, the following sanity checks should all pass:

1. **Daemon process tree present** — see [`troubleshooting.md`](./troubleshooting.md) for the expected per-platform tree.
2. **No 409 from Telegram**: `curl 'https://api.telegram.org/bot<TOKEN>/getUpdates?limit=1&timeout=0'` returns `"ok":true`.
3. **Daemon's pane shows "Listening for channel messages"** (Linux/macOS via `tmux capture-pane`; Windows via the visible window or by tailing log).
4. **End-to-end test**: phone sends a message, the daemon logs `← telegram · <user_id>: <text>`, claude calls `plugin:telegram:telegram - reply`, the phone receives the reply.
5. **No hook errors in pane**: search for `hook error` — none expected.
6. **CLAUDE.md rules present**: `grep -l 'BEGIN: channel-routing-rule' ~/CLAUDE.md ~/.claude/CLAUDE.md` returns both paths.

If any check fails, see [`troubleshooting.md`](./troubleshooting.md).
