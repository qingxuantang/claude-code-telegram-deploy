# fix-daemon.ps1
# Idempotent post-boot self-heal for the Claude Code Telegram daemon.
#
# Why this exists: on Windows boot, both the Desktop App and the daemon
# Scheduled Task may spawn a bun for the Telegram plugin. Whichever
# runs `bot.pid` SIGTERM last wins the bot; the other goes silent. The
# daemon usually wins by spawn-order luck, but not always — and when
# the Desktop App wins, the daemon's claude.exe stays alive but has no
# bun child, so Telegram messages silently queue server-side.
#
# This script:
#   0. Ensures the supervisor (start-claude.ps1) is alive. If the
#      ClaudeCodeTelegramDaemon task was terminated — most commonly
#      because it hit its ExecutionTimeLimit (Windows kills the task at
#      that point, and RestartCount does NOT cover a time-limit kill) —
#      nobody respawns the daemon, so Steps 1-2 would just leave
#      daemon-claude=0. This step re-launches the task to rebuild it.
#   1. Kills any bun whose root parent is NOT `claude --channels`
#      (i.e. the Desktop App's bun, which contends for bot.pid).
#   2. Kills the daemon's claude.exe itself so start-claude.ps1's
#      while-loop respawns it fresh — even when no contention was
#      found. Harmless: ~15 s downtime, no message loss (Telegram
#      queues for 24 h server-side).
#
# End state: daemon-solo regardless of who initially won the race.
# Safe to re-run.
#
# Two ways to invoke:
#   - Automatically: registered as the `ClaudeCodeTelegramDaemonHeal`
#     Scheduled Task by Step 11b of platforms/windows.md (fires once
#     per logon, 90 s after).
#   - Manually: double-click the desktop shortcut, or run from any
#     PowerShell:  & "$env:USERPROFILE\fix-daemon.ps1"
#
# Log: ~/fix-daemon.log (appended each run; rotate manually if it grows).

$ErrorActionPreference = 'Continue'
$log = "$env:USERPROFILE\fix-daemon.log"
function Log($msg) {
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $msg" | Out-File $log -Append -Encoding utf8
}

Log "=== fix-daemon start ==="

# 0. Ensure the supervisor (start-claude.ps1) is alive. If it's gone — most
#    commonly because the ClaudeCodeTelegramDaemon task hit its ExecutionTimeLimit
#    and Windows terminated it (RestartCount does NOT rescue a time-limit kill) —
#    nobody respawns the daemon, and the kill steps below would just leave
#    daemon-claude=0. Rebuild the supervisor by (re)starting the task first.
$supervisor = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*start-claude.ps1*' }
if (-not $supervisor) {
    Log "supervisor (start-claude.ps1) NOT running — starting ClaudeCodeTelegramDaemon task to rebuild it"
    try {
        Start-ScheduledTask -TaskName 'ClaudeCodeTelegramDaemon' -ErrorAction Stop
        for ($i = 0; $i -lt 15; $i++) {
            Start-Sleep -Seconds 2
            $supervisor = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -like '*start-claude.ps1*' }
            if ($supervisor) { break }
        }
        if ($supervisor) { Log "  supervisor rebuilt (PID=$(($supervisor | Select-Object -First 1).ProcessId))" }
        else { Log "  WARN supervisor still down after starting task — check ClaudeCodeTelegramDaemon" }
    } catch {
        Log "  failed to start ClaudeCodeTelegramDaemon task: $($_.Exception.Message)"
    }
} else {
    Log "supervisor alive (PID=$(($supervisor | Select-Object -First 1).ProcessId))"
}

# 1. Find all bun.exe processes and identify which ones belong to a
#    NON-daemon parent (i.e. Desktop App's claude.exe with --plugin-dir).
$contendingBuns = @()
Get-CimInstance Win32_Process -Filter "Name='bun.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
    $bunPid = $_.ProcessId
    $parent = Get-CimInstance Win32_Process -Filter "ProcessId=$($_.ParentProcessId)" -ErrorAction SilentlyContinue
    # bun's direct parent is usually a `bun run` wrapper; the wrapper's parent is claude.exe
    if ($parent -and $parent.Name -eq 'bun.exe') {
        $grandparent = Get-CimInstance Win32_Process -Filter "ProcessId=$($parent.ParentProcessId)" -ErrorAction SilentlyContinue
        $rootCmd = if ($grandparent) { $grandparent.CommandLine } else { '' }
    } else {
        $rootCmd = if ($parent) { $parent.CommandLine } else { '' }
    }
    if ($rootCmd -notlike '*--channels*') {
        $contendingBuns += $bunPid
        Log "contending bun PID=$bunPid root-parent-cmd=$($rootCmd -replace ' +',' ' | ForEach-Object { $_.Substring(0,[Math]::Min(80,$_.Length)) })"
    }
}

foreach ($p in $contendingBuns) {
    try { Stop-Process -Id $p -Force -ErrorAction Stop; Log "  killed contending bun $p" }
    catch { Log ("  failed to kill {0}: {1}" -f $p, $_.Exception.Message) }
}
if ($contendingBuns.Count -eq 0) { Log "no contending bun found (daemon may already be solo)" }

# 2. Kill daemon claude (--channels) so start-claude.ps1's while-loop
#    respawns it with a fresh bun.
$daemonClaudes = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*--channels*' }
foreach ($c in $daemonClaudes) {
    try { Stop-Process -Id $c.ProcessId -Force -ErrorAction Stop; Log "killed daemon claude $($c.ProcessId)" }
    catch { Log "failed to kill daemon claude $($c.ProcessId): $($_.Exception.Message)" }
}

# 3. Wait for while-loop respawn + new bun to come up
Start-Sleep -Seconds 20

# 4. Verify final state
$bunCount = (Get-Process bun -ErrorAction SilentlyContinue).Count
$daemonCount = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*--channels*' }).Count
Log "after-state: daemon-claude=$daemonCount, bun=$bunCount (expect: 1 daemon-claude, 2 bun)"

# 5. Telegram health check (best-effort; failure here is non-fatal — script's job is done)
try {
    $tokenLine = (Get-Content "$env:USERPROFILE\.claude\channels\telegram\.env" -Raw -ErrorAction Stop)
    $token = ($tokenLine -replace 'TELEGRAM_BOT_TOKEN=','' -replace '\s','')
    $r = Invoke-RestMethod "https://api.telegram.org/bot$token/getUpdates?limit=1&timeout=0" -TimeoutSec 8
    Log "telegram getUpdates: ok=$($r.ok), msgs-queued=$($r.result.Count)"
    if (-not $r.ok) { Log "  WARN telegram returned error: $($r.description)" }
} catch {
    Log "telegram check failed: $($_.Exception.Message)"
}

Log "=== fix-daemon done ==="
