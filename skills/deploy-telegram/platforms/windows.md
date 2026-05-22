# Platform overlay: Windows

Windows-native execution steps for the deploy-telegram skill. Read [`../SKILL.md`](../SKILL.md) first for the universal contract and architecture; read [`../references/`](../references/) for the "why" behind each step. This file is the **how**.

## Provenance

End-to-end deployed and verified on **2026-05-21** on:
- Windows 11 Pro 26100
- Claude Code Desktop app 2.1.142 (bundled `claude.exe` reused as the daemon binary)
- Bun 1.3.14
- Node.js 22.14.0

Validation included the full Telegram phone → daemon → reply tool → phone roundtrip with a freshly-created `@BotFather` test bot.

## What's NOT verified

- Multi-user Windows setups (only single-user single-domain tested)
- Windows Server SKUs (only Windows 11 client tested)
- Headless / Task Scheduler-only first launch (the validation operator dismissed dialogs in a visible window; the "headless answer-file" trick is noted but untested)
- File uploads from Telegram routed through `~/telegram-inbox/` (mover task is registered and running, but no file was actually sent during validation)
- Plugin/Bun upgrades — re-applying Step 4b after a `claude plugin install` should work, but was not exercised post-deployment

## 🚫 Windows-specific do-not

In addition to the universal do-not list in [`../SKILL.md`](../SKILL.md):

1. **Do NOT write `settings.json` / `.env` / `.claude.json` with `Out-File -Encoding utf8`** — PowerShell adds a UTF-8 BOM that the Telegram plugin's `^(\w+)=(.*)$` regex won't match. Use `[System.IO.File]::WriteAllText(path, content, [System.Text.UTF8Encoding]::new($false))`.
2. **Do NOT store hook command paths with backslashes** in `settings.json`. Claude Code routes hook commands through MSYS `/usr/bin/bash`, which strips `\` as escape chars. Use forward slashes: `C:/Users/...`.
3. **Do NOT use `ConvertTo-Json` to overwrite `settings.json`** — most users have pre-existing hooks (analytics tools, custom workflows, etc.). Always read + merge + write.
4. **Do NOT commit `start-claude.ps1` to git** — it contains the OAuth token if Step 2's auth check failed and you fell back to an explicit token.

## Required inputs

| Variable | Format | Notes |
|---|---|---|
| `$env:BOT_TOKEN` | `<digits>:<hash>` | From `@BotFather /newbot`. **Must be a fresh bot**. |

Optional (only if Step 2's auth check fails):
| `$env:CLAUDE_CODE_OAUTH_TOKEN` | `sk-ant-oat01-...` | From `claude setup-token` in a separate cmd window |

Auto-detected:
| `$env:CLAUDE_EXE` | absolute path | Latest under `%APPDATA%\Claude\claude-code\<version>\claude.exe` |
| `$env:BUN_EXE` | absolute path | `%USERPROFILE%\.bun\bin\bun.exe` |

## Network check (pre-flight)

```powershell
foreach ($url in 'https://api.telegram.org','https://github.com','https://api.anthropic.com') {
    try {
        $null = Invoke-WebRequest $url -TimeoutSec 10 -UseBasicParsing -Method Head -ErrorAction Stop
        "PASS: $url"
    } catch {
        # 401/404/etc. all proven reachable — only timeouts and DNS failures are real
        if ($_.Exception.Message -match 'status code|404|401|403') {
            "PASS (status code expected): $url"
        } else {
            "FAIL: $url  ($($_.Exception.Message))"
        }
    }
}
```

All three must pass. If any fails: mainland-China networks block Telegram and often slow GitHub. Use a VPN or accept that the daemon won't be reachable. `api.anthropic.com` returns 404 to `HEAD /` (no real root endpoint) — that **proves the host is reachable**, not a failure.

---

## Step 1 — 🤖 Locate prerequisites

```powershell
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw "Node.js not found. Install: winget install OpenJS.NodeJS"
}
"Node: $(node --version)"

# Bundled claude.exe — pick latest version directory
$claudeRoot = "$env:APPDATA\Claude\claude-code"
if (-not (Test-Path $claudeRoot)) {
    throw "Claude Code Desktop app not installed (no $claudeRoot). Install it first from https://claude.com/claude-code."
}
$latest = Get-ChildItem $claudeRoot -Directory | Sort-Object @{Expression={[version]$_.Name}} -Descending | Select-Object -First 1
$env:CLAUDE_EXE = Join-Path $latest.FullName "claude.exe"
if (-not (Test-Path $env:CLAUDE_EXE)) { throw "claude.exe missing at $env:CLAUDE_EXE" }
"CLAUDE_EXE: $env:CLAUDE_EXE  (version $(& $env:CLAUDE_EXE --version))"

# Bun
$env:BUN_EXE = "$env:USERPROFILE\.bun\bin\bun.exe"
if (-not (Test-Path $env:BUN_EXE)) {
    "Bun NOT FOUND — installing..."
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm bun.sh/install.ps1 | iex"
}
"BUN_EXE: $env:BUN_EXE  (version $(& $env:BUN_EXE --version))"
```

> Why bundled `claude.exe` instead of `npm install -g`: the Desktop App's installer already manages the binary and auto-updates it. Reusing avoids duplicate installs and version drift between the two instances. **See [`../references/architecture-and-design.md`](../references/architecture-and-design.md)** for the two-instance coexistence model.

## Step 2 — 🤖 Verify auth (Desktop App credentials are usually inherited)

```powershell
if (-not (Test-Path "$env:USERPROFILE\.claude.json")) {
    @{ hasCompletedOnboarding = $true; hasAcknowledgedCostThreshold = $true } |
        ConvertTo-Json |
        Out-File "$env:USERPROFILE\.claude.json" -Encoding utf8
}

$authResult = & $env:CLAUDE_EXE auth status 2>&1
if ($authResult -match '"loggedIn":\s*true' -or $authResult -match 'logged in') {
    "OK: bundled CLI inherits Desktop app auth — no separate OAuth token needed"
} else {
    Write-Warning @"
Bundled CLI does not see Desktop app auth. You must:
  1. Open a separate PowerShell window
  2. Run: & '$env:CLAUDE_EXE' setup-token
  3. Browser opens — complete OAuth flow
  4. Paste the sk-ant-oat01-... token back into THIS window:
     `$env:CLAUDE_CODE_OAUTH_TOKEN = '<paste>'`
  5. Re-run Step 2
"@
}
```

## Step 3 — 🤖 Patch settings.json (ADDITIVE MERGE — never overwrite)

> **Critical Windows lesson** (2026-05-21): the first version of this step destructively overwrote `settings.json`, erasing the operator's existing PreToolUse + PostToolUse hooks from a third-party analytics tool. Recovery required the `.bak` snapshot. See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §5.

```powershell
$settingsPath = "$env:USERPROFILE\.claude\settings.json"
New-Item -ItemType Directory -Force -Path (Split-Path $settingsPath) | Out-Null

# Backup before mutating
$backup = "$settingsPath.before-deploy-telegram.bak"
if ((Test-Path $settingsPath) -and -not (Test-Path $backup)) {
    Copy-Item $settingsPath $backup
    "Backed up existing settings.json -> $backup"
}

if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
} else {
    $settings = New-Object PSObject
}

# Required for Telegram channel — overwrite to ensure correct value
if ($settings.PSObject.Properties.Name -contains 'channelsEnabled') {
    $settings.channelsEnabled = $true
} else {
    $settings | Add-Member -NotePropertyName channelsEnabled -NotePropertyValue $true
}

# Recommended permissions config — only set if user hasn't already configured
if (-not $settings.permissions) {
    $perms = New-Object PSObject
    $perms | Add-Member -NotePropertyName allow -NotePropertyValue @("Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Glob(*)", "Grep(*)", "WebSearch(*)", "WebFetch(*)", "NotebookEdit(*)", "mcp__*")
    $perms | Add-Member -NotePropertyName deny -NotePropertyValue @()
    $perms | Add-Member -NotePropertyName defaultMode -NotePropertyValue "bypassPermissions"
    $settings | Add-Member -NotePropertyName permissions -NotePropertyValue $perms
} else {
    if (-not $settings.permissions.defaultMode -or $settings.permissions.defaultMode -ne 'bypassPermissions') {
        if ($settings.permissions.PSObject.Properties.Name -contains 'defaultMode') {
            $settings.permissions.defaultMode = 'bypassPermissions'
        } else {
            $settings.permissions | Add-Member -NotePropertyName defaultMode -NotePropertyValue 'bypassPermissions'
        }
        "Set permissions.defaultMode = bypassPermissions"
    }
}

if (-not ($settings.PSObject.Properties.Name -contains 'skipDangerousModePermissionPrompt')) {
    $settings | Add-Member -NotePropertyName skipDangerousModePermissionPrompt -NotePropertyValue $true
}

# IMPORTANT: write without BOM
$json = $settings | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))
"OK: $settingsPath updated additively"
```

> `channelsEnabled: true` is mandatory; `permissions.defaultMode: "bypassPermissions"` is the only setting that actually silences permission prompts. See [`../references/architecture-and-design.md`](../references/architecture-and-design.md) for the rationale.
>
> **Shared with Desktop App**: this file is read by both the daemon and the Desktop App. If you want different permissions per instance, fork the settings: pass `--settings <other-path>` in `start-claude.ps1`.

## Step 4 — 🤖 Install Telegram plugin

```powershell
# Plugin marketplace is global; idempotent.
& $env:CLAUDE_EXE plugin marketplace add anthropics/claude-plugins-official 2>&1 | Out-Null
& $env:CLAUDE_EXE plugin marketplace update claude-plugins-official 2>&1 | Select-Object -Last 1

# Clean install — uninstall first to avoid stale state.
# IMPORTANT: when no plugin is installed yet, `plugin uninstall` writes to stderr
# and exits non-zero. That's expected. Localize $ErrorActionPreference for this line.
$prevPref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $env:CLAUDE_EXE plugin uninstall telegram@claude-plugins-official 2>&1 | Out-Null
$ErrorActionPreference = $prevPref

& $env:CLAUDE_EXE plugin install telegram@claude-plugins-official 2>&1 | Select-Object -Last 3

# Verify
$plugList = & $env:CLAUDE_EXE plugin list 2>&1
if ($plugList -match 'telegram') {
    "OK: telegram plugin installed"
} else {
    throw "Plugin install failed. Output: $plugList"
}
```

> **NEVER use `--plugin-dir` with `--channels`**. See [`../references/architecture-and-design.md`](../references/architecture-and-design.md) for the two-mode mutually-exclusive design.

> **Scope choice on Windows**: user scope (default) works most of the time despite the Desktop App also loading the plugin via `--plugin-dir` and spawning a competing bun. `server.ts`'s `bot.pid` SIGTERM mechanism is self-healing and the daemon (Scheduled Task) usually beats the GUI Desktop App in the bun-spawn race. **If after a Windows reboot you find Telegram not responding**, run the manual recovery in [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §4 ("Recovery if you lose the race") — one PowerShell snippet kills Desktop App's bun and restarts the daemon. **Initial conclusion on 2026-05-21 that "Windows doesn't contend" was incorrect** and has been retracted in the references doc.

## Step 4b — 🤖 Patch plugin to disable channel-permission relay

> **Critical Windows lesson** (2026-05-21 incident — see [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §"server.ts UTF-8 corruption"): **always read `server.ts` with explicit UTF-8 encoding**. On Chinese-locale Windows (or any non-UTF-8 ANSI codepage), PowerShell 5.1's `Get-Content` defaults to the system codepage (e.g. GBK) and corrupts the file's emoji bytes (`'✅'`, `'❌'`). The corruption surfaces later as `Bun parse error at server.ts:937 — Expected " =" but found "閴?"`, and the daemon's `/mcp` shows "1 MCP server failed".

```powershell
$pluginRoot = "$env:USERPROFILE\.claude\plugins\marketplaces\claude-plugins-official\external_plugins\telegram"
$serverTs = Join-Path $pluginRoot "server.ts"
if (-not (Test-Path $serverTs)) { throw "server.ts not found at $serverTs (plugin install may have failed)" }

$backup = "$serverTs.bak"
if (-not (Test-Path $backup)) { Copy-Item $serverTs $backup }

# CRITICAL: read as UTF-8 explicitly. PowerShell 5.1 default codepage on Chinese
# Windows is GBK, which mis-reads UTF-8 emoji bytes -> corrupts on writeback.
$content = [System.IO.File]::ReadAllText($serverTs, [System.Text.UTF8Encoding]::new($false))
$patched = $content -replace "(?m)^(\s*)'claude/channel/permission':\s*\{\},", "`$1// 'claude/channel/permission': {}, // DISABLED: relays tool prompts to TG despite --dangerously-skip-permissions"

if ($patched -eq $content) {
    Write-Warning "Patch did not match — plugin source may have changed upstream. Inspect $serverTs manually."
} else {
    [System.IO.File]::WriteAllText($serverTs, $patched, [System.Text.UTF8Encoding]::new($false))
    "OK: channel-permission relay disabled in $serverTs"
}
```

> **Re-apply after plugin updates.** Any `claude plugin install` or marketplace update overwrites `server.ts`. The `.bak` copy is preserved on first run. See [`../references/architecture-and-design.md`](../references/architecture-and-design.md) §"The server.ts patch" for why this matters.

## Step 5 — 🤖 Configure bot token (UTF-8 no BOM, ACL locked)

```powershell
$telegramDir = "$env:USERPROFILE\.claude\channels\telegram"
New-Item -ItemType Directory -Force -Path $telegramDir | Out-Null

# CRITICAL: UTF-8 without BOM
$envContent = "TELEGRAM_BOT_TOKEN=$env:BOT_TOKEN`n"
[System.IO.File]::WriteAllText("$telegramDir\.env", $envContent, [System.Text.UTF8Encoding]::new($false))

# NTFS ACL: lock to current user (Windows equivalent of chmod 600)
$acl = Get-Acl "$telegramDir\.env"
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "$env:USERDOMAIN\$env:USERNAME", "FullControl", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl "$telegramDir\.env" $acl

"OK: bot token written to $telegramDir\.env"
```

## Step 6 — 🤖 Create start-claude.ps1 (the daemon launcher)

```powershell
$startScript = "$env:USERPROFILE\start-claude.ps1"
$bunDir = Split-Path $env:BUN_EXE

$startContent = @"
# Auto-generated by deploy-telegram skill. Do not commit (contains tokens).
`$env:PATH = '$bunDir;' + `$env:PATH

Set-Location `$env:USERPROFILE
while (`$true) {
    try {
        & '$env:CLAUDE_EXE' --dangerously-skip-permissions ``
            --channels plugin:telegram@claude-plugins-official
    } catch {
        Write-Host "claude.exe threw: `$_"
    }
    Write-Host "Claude exited. Restarting in 3s..."
    Start-Sleep -Seconds 3
}
"@

[System.IO.File]::WriteAllText($startScript, $startContent, [System.Text.UTF8Encoding]::new($false))

# Lock ACL
$acl = Get-Acl $startScript
$acl.SetAccessRuleProtection($true, $false)
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "$env:USERDOMAIN\$env:USERNAME", "FullControl", "Allow"
)
$acl.SetAccessRule($rule)
Set-Acl $startScript $acl

"OK: $startScript"
```

## Step 7 — 🤖 Install bypass-claude-folder hook

```powershell
$hookScript = "$env:USERPROFILE\bypass-claude-folder.ps1"

$hookContent = @'
$inputText = [Console]::In.ReadToEnd()
try { $d = $inputText | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }

$evt = $d.hook_event_name
$ti = $d.tool_input

$sensitiveDirSubstrings = @('/.claude/', '\.claude\', '/.config/', '\.config\')
$sensitiveBasenames = @('.claude','.bashrc','.bash_profile','.profile','.zshrc','.zprofile','.zshenv','.gitconfig','.npmrc','.env','.envrc','.claude.json')
$sensitiveCmdTokens = @('/.claude/','\.claude\','/.config/','\.config\','/.bashrc','\.bashrc','/.profile','\.profile','/.gitconfig','\.gitconfig','/.npmrc','\.npmrc','/.env','\.env','/.envrc','\.envrc','/.claude.json','\.claude.json','~/.claude/','~/.config/','~/.bashrc','~/.profile')

function Test-SensitivePath($p) {
    if (-not $p) { return $false }
    foreach ($s in $sensitiveDirSubstrings) { if ($p -like "*$s*") { return $true } }
    $base = Split-Path $p -Leaf
    if ($base -in $sensitiveBasenames) { return $true }
    return $false
}
function Test-SensitiveCmd($cmd) {
    if (-not $cmd) { return $false }
    foreach ($t in $sensitiveCmdTokens) { if ($cmd -like "*$t*") { return $true } }
    return $false
}

$path = $null
if ($ti.file_path) { $path = $ti.file_path } elseif ($ti.notebook_path) { $path = $ti.notebook_path }

$matched = $false
if ($path -and (Test-SensitivePath $path)) { $matched = $true }
elseif ($ti.command -and (Test-SensitiveCmd $ti.command)) { $matched = $true }

if (-not $matched) { exit 0 }

if ($evt -eq 'PreToolUse') {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'allow'; permissionDecisionReason = 'auto-allow sensitive path (Windows port)' } } | ConvertTo-Json -Depth 5 -Compress
} elseif ($evt -eq 'PermissionRequest') {
    @{ hookSpecificOutput = @{ hookEventName = 'PermissionRequest'; decision = @{ behavior = 'allow' } } } | ConvertTo-Json -Depth 5 -Compress
}
'@
[System.IO.File]::WriteAllText($hookScript, $hookContent, [System.Text.UTF8Encoding]::new($false))

# .cmd wrapper because .ps1 isn't auto-executed by Claude Code hooks
$hookCmd = "$env:USERPROFILE\bypass-claude-folder.cmd"
$cmdContent = "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$hookScript`""
[System.IO.File]::WriteAllText($hookCmd, $cmdContent, [System.Text.UTF8Encoding]::new($false))

# CRITICAL: forward-slash path for the JSON value (bash escape lesson)
$hookCmdFwd = ($hookCmd -replace '\\', '/')

# Additively merge into settings.json — never replace existing arrays
$settingsPath = "$env:USERPROFILE\.claude\settings.json"
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
if (-not $settings.hooks) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force
}

$bypassEntry = @{ matcher = ""; hooks = @(@{ type = "command"; command = $hookCmdFwd }) }

foreach ($evt in @('PreToolUse', 'PermissionRequest')) {
    $existing = @()
    if ($settings.hooks.PSObject.Properties.Name -contains $evt) {
        $existing = @($settings.hooks.$evt)
    }
    $alreadyHas = $false
    foreach ($e in $existing) {
        if (($e | ConvertTo-Json -Compress -Depth 5) -match 'bypass-claude-folder') { $alreadyHas = $true }
    }
    if (-not $alreadyHas) { $existing += $bypassEntry }

    if ($settings.hooks.PSObject.Properties.Name -contains $evt) {
        $settings.hooks.$evt = $existing
    } else {
        $settings.hooks | Add-Member -NotePropertyName $evt -NotePropertyValue $existing -Force
    }
    "  $evt now has $($existing.Count) hook(s)"
}

$json = $settings | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))
"OK: bypass hook installed (forward-slash path, additive merge)"
```

> Why forward-slash paths and additive merge: see [`../references/architecture-and-design.md`](../references/architecture-and-design.md) §"Permission-bypass hook" and [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §5.

## Step 7b — 🤖 Install Telegram routing hook

```powershell
$tgHookScript = "$env:USERPROFILE\telegram-routing-hook.ps1"

$tgHookContent = @'
$inputText = [Console]::In.ReadToEnd()
try { $d = $inputText | ConvertFrom-Json -ErrorAction Stop } catch { exit 0 }
$prompt = ""
if ($d.tool_input.prompt) { $prompt = $d.tool_input.prompt }
$lower = $prompt.ToLower()
$hasArrow = $prompt.Contains("<-") -or $prompt.Contains([char]0x2190)
if ($lower.Contains("telegram") -and $hasArrow) {
    @{ hookSpecificOutput = @{ hookEventName = "UserPromptSubmit"; additionalContext = "TELEGRAM ROUTING MANDATORY: This message came from Telegram. You MUST call plugin:telegram:telegram reply MCP tool with chat_id to send your response. Terminal output is INVISIBLE to the Telegram user. Do NOT skip the reply tool call." } } | ConvertTo-Json -Depth 5 -Compress
}
'@
[System.IO.File]::WriteAllText($tgHookScript, $tgHookContent, [System.Text.UTF8Encoding]::new($false))

$tgHookCmd = "$env:USERPROFILE\telegram-routing-hook.cmd"
[System.IO.File]::WriteAllText($tgHookCmd, "@echo off`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$tgHookScript`"", [System.Text.UTF8Encoding]::new($false))

$tgHookCmdFwd = ($tgHookCmd -replace '\\', '/')

$settingsPath = "$env:USERPROFILE\.claude\settings.json"
$settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
if (-not $settings.hooks) {
    $settings | Add-Member -NotePropertyName hooks -NotePropertyValue (New-Object PSObject) -Force
}
$tgEntry = @{ matcher = ""; hooks = @(@{ type = "command"; command = $tgHookCmdFwd }) }
$existing = @()
if ($settings.hooks.PSObject.Properties.Name -contains 'UserPromptSubmit') {
    $existing = @($settings.hooks.UserPromptSubmit)
}
$already = $false
foreach ($e in $existing) {
    if (($e | ConvertTo-Json -Compress -Depth 5) -match 'telegram-routing-hook') { $already = $true }
}
if (-not $already) { $existing += $tgEntry }

if ($settings.hooks.PSObject.Properties.Name -contains 'UserPromptSubmit') {
    $settings.hooks.UserPromptSubmit = $existing
} else {
    $settings.hooks | Add-Member -NotePropertyName UserPromptSubmit -NotePropertyValue $existing -Force
}

$json = $settings | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($settingsPath, $json, [System.Text.UTF8Encoding]::new($false))
"OK: routing hook installed"
```

> Known limitation: channel-routed messages may bypass `UserPromptSubmit` — see [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §6. The hook is defense-in-depth; the CLAUDE.md rules (Step 10) are primary.

## Step 7c — 🤖 Install inbox mover (FileSystemWatcher + Scheduled Task)

```powershell
$moverScript = "$env:USERPROFILE\tg-inbox-mover.ps1"
$inboxSrc = "$env:USERPROFILE\.claude\channels\telegram\inbox"
$inboxDst = "$env:USERPROFILE\telegram-inbox"
New-Item -ItemType Directory -Force -Path $inboxSrc, $inboxDst | Out-Null

$moverContent = @"
`$src = '$inboxSrc'
`$dst = '$inboxDst'
New-Item -ItemType Directory -Force -Path `$src, `$dst | Out-Null

Get-ChildItem `$src -File -ErrorAction SilentlyContinue | ForEach-Object {
    try { Move-Item -LiteralPath `$_.FullName -Destination `$dst -Force } catch {}
}

`$watcher = New-Object System.IO.FileSystemWatcher
`$watcher.Path = `$src
`$watcher.IncludeSubdirectories = `$false
`$watcher.NotifyFilter = [System.IO.NotifyFilters]'FileName, LastWrite, Size'
`$watcher.EnableRaisingEvents = `$true

`$action = {
    `$path = `$Event.SourceEventArgs.FullPath
    `$dst = `$Event.MessageData
    1..10 | ForEach-Object {
        try { Move-Item -LiteralPath `$path -Destination `$dst -Force -ErrorAction Stop; return }
        catch { Start-Sleep -Milliseconds 100 }
    }
}

Register-ObjectEvent `$watcher 'Created' -Action `$action -MessageData `$dst | Out-Null
Register-ObjectEvent `$watcher 'Renamed' -Action `$action -MessageData `$dst | Out-Null
while (`$true) { Start-Sleep -Seconds 3600 }
"@
[System.IO.File]::WriteAllText($moverScript, $moverContent, [System.Text.UTF8Encoding]::new($false))

# Scheduled Task to run mover at logon, hidden, restart on failure
$taskName = "ClaudeTelegramInboxMover"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$moverScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settingsTask = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 365)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settingsTask -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $taskName

"OK: Scheduled Task '$taskName' registered and started"
```

> See [`../references/architecture-and-design.md`](../references/architecture-and-design.md) §"Inbox mover" for why this exists. After this step, your CLAUDE.md must instruct Claude to look at `%USERPROFILE%\telegram-inbox\` — Step 10 below installs the rule that says so.

## Step 8 — 👤+🤖 Register daemon Task and launch visible window for first-run dialogs

```powershell
$taskName = "ClaudeCodeTelegramDaemon"
$startScript = "$env:USERPROFILE\start-claude.ps1"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$startScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$settingsTask = New-ScheduledTaskSettingsSet -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Days 365)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settingsTask -Principal $principal -Force | Out-Null
"OK: Scheduled Task '$taskName' registered (auto-starts at next logon)"

"`nLaunching daemon ONCE in a VISIBLE PowerShell window so you can dismiss first-launch dialogs."
"In the new window that opens:"
"  1. Press Enter to accept 'Trust this folder?'"
"  2. Use arrow keys to select 'Yes, I accept' for 'Bypass permissions?' and press Enter"
"  3. Wait for 'Listening for channel messages' to appear (10-30 seconds)"
"  4. Keep the window open — pairing in Step 9 needs it visible."

Start-Process powershell.exe -ArgumentList "-NoProfile","-NoExit","-ExecutionPolicy","Bypass","-File","`"$startScript`""
"`nVisible-launch window spawned. After pairing succeeds (Step 9), you can close it; the Scheduled Task will take over on next logon."
```

> **Why visible-window manual launch instead of `tmux send-keys`**: Linux/macOS servers are headless and use tmux automation. Windows local PC has a human at the keyboard — two keypresses beat 200 lines of fragile SendKeys simulation. See [`../references/process-supervisors.md`](../references/process-supervisors.md) §Windows.

## Step 9 — 👤 Telegram pairing

After the daemon's visible window shows `Listening for channel messages from: plugin:telegram@claude-plugins-official`:

1. Open Telegram on your phone, find your bot, send any message (e.g. `hi`)
2. The bot replies with a 6-character pairing code (e.g. `ef9e47`)
3. **Click the visible daemon window to give it focus**, then type:
   ```
   /telegram:access pair <CODE>
   ```
   Press Enter. Wait 5-10s.
4. Then type:
   ```
   /telegram:access policy allowlist
   ```
   Press Enter. Wait 5s.
5. Send a test message from Telegram. The bot should reply.

> Cannot automate this on Windows (no tmux send-keys). Full pairing details in [`../references/pairing-and-access.md`](../references/pairing-and-access.md).

## Step 10 — 🤖 Install both CLAUDE.md rule blocks

```powershell
$ruleChannel = @'

<!-- BEGIN: channel-routing-rule -->
## Channel Routing Rule (highest priority)

**General principle**: Reply on the *same platform* the message came from.
Telegram in -> Telegram reply tool out. Terminal in -> stdout out. Never cross.

When the incoming message is tagged `<- telegram - <user_id>:`, you **must**
reply by calling the `plugin:telegram:telegram - reply` MCP tool targeted at
the same `chat_id`. Terminal output alone is invisible to the Telegram user.

1. Every user-visible Telegram reply must go through the reply tool.
2. Do not assume the Telegram user can see terminal output.
3. If a tool call fails, retry; do not silently drop the reply.
4. Do not cross-route: never answer a Telegram message by printing only to
   the terminal, and never push a terminal-only task into Telegram.
5. This rule overrides any default "just print to stdout" behavior.
6. Even if you already printed text to the terminal, you must still issue a
   reply tool call afterwards - terminal output does not count as a reply.

### Telegram file uploads (Windows)

User-uploaded files arrive at `%USERPROFILE%\telegram-inbox\` (NOT at
`%USERPROFILE%\.claude\channels\telegram\inbox\` - that path triggers a
hard-coded sensitive-file guard). The inbox-mover Scheduled Task moves files
within ~50 ms. Always read from `%USERPROFILE%\telegram-inbox\`.
<!-- END: channel-routing-rule -->
'@

$ruleNoSelect = @'

<!-- BEGIN: no-interactive-select-rule -->
## No Interactive Selects / Numbered Pickers (HARD RULE)

**Never invoke `AskUserQuestion`, numbered select dialogs, or any other widget
that waits for local keyboard input — regardless of session mode (terminal,
Telegram channel, anything).**

**Why**: These widgets block the main input stream until someone hits arrow
keys + Enter locally. Inbound channel messages cannot drive them. A select
dialog locked one production deployment for 1 h 15 min; MCP stdio timed out;
the reply tool went silently dead; recovery required killing the daemon and
losing the session's context.

**Instead**: write the question + options as plain prose (with a brief
recommendation up front). Send via the appropriate channel (reply tool in
channel mode, stdout in terminal mode). Parse the answer from the user's
next free-form text message.

**Scope**: Hard rule, no exceptions. Applies even in pure terminal mode — a
channel can be attached later, and any lingering picker locks it out.
<!-- END: no-interactive-select-rule -->
'@

function Install-Block {
    param([string]$Path, [string]$Block, [string]$Marker)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType File -Force -Path $Path | Out-Null
    }
    $content = Get-Content $Path -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains($Marker)) {
        "  Already present: $Path ($Marker)"
        return
    }
    Add-Content -Path $Path -Value $Block -Encoding UTF8
    "  Appended: $Path ($Marker)"
}

Install-Block "$env:USERPROFILE\CLAUDE.md" $ruleChannel "<!-- BEGIN: channel-routing-rule -->"
Install-Block "$env:USERPROFILE\.claude\CLAUDE.md" $ruleChannel "<!-- BEGIN: channel-routing-rule -->"
Install-Block "$env:USERPROFILE\CLAUDE.md" $ruleNoSelect "<!-- BEGIN: no-interactive-select-rule -->"
Install-Block "$env:USERPROFILE\.claude\CLAUDE.md" $ruleNoSelect "<!-- BEGIN: no-interactive-select-rule -->"
"OK: both rules installed in both CLAUDE.md files"
```

> Restart the daemon after this step to reload CLAUDE.md:
> ```powershell
> Stop-ScheduledTask -TaskName ClaudeCodeTelegramDaemon -ErrorAction SilentlyContinue
> Get-Process bun,claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq '' } | Stop-Process -Force
> # close the visible PowerShell window from Step 8
> Start-ScheduledTask -TaskName ClaudeCodeTelegramDaemon
> ```

## File manifest

| Path | Purpose |
|---|---|
| `%USERPROFILE%\.claude.json` | Onboarding bypass (merged) |
| `%USERPROFILE%\.claude\settings.json` | Permissions + channelsEnabled + hooks (merged) |
| `%USERPROFILE%\.claude\channels\telegram\.env` | Bot token (UTF-8 no BOM, ACL locked) |
| `%USERPROFILE%\start-claude.ps1` | Daemon launcher with auto-restart |
| `%USERPROFILE%\bypass-claude-folder.ps1` + `.cmd` | Sensitive-path bypass hook (forward-slash paths in JSON) |
| `%USERPROFILE%\telegram-routing-hook.ps1` + `.cmd` | Routing reminder hook |
| `%USERPROFILE%\tg-inbox-mover.ps1` | FileSystemWatcher mover script |
| `%USERPROFILE%\telegram-inbox\` | Safe destination for uploads |
| Scheduled Task `ClaudeCodeTelegramDaemon` | Daemon auto-start at logon (hidden) |
| Scheduled Task `ClaudeTelegramInboxMover` | Mover auto-start at logon (hidden) |
| `%USERPROFILE%\CLAUDE.md` + `~/.claude/CLAUDE.md` | Both rule blocks installed |

## Operating notes

- **Slash commands over Telegram don't work** — see [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §8. To change model, edit `start-claude.ps1` to add `--model <name>`, then restart the daemon.
- **Daemon stops when user logs off** — by design (Interactive logon type Scheduled Task). For 24/7 on a Windows server, switch the Task to `S4U` or password-based logon — out of scope here.
- **Hooks load at session startup** — settings.json edits to hooks don't take effect until next daemon restart.

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName ClaudeCodeTelegramDaemon -Confirm:$false
Unregister-ScheduledTask -TaskName ClaudeTelegramInboxMover -Confirm:$false
Get-Process bun -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process claude -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -eq '' } | Stop-Process -Force
Remove-Item "$env:USERPROFILE\start-claude.ps1","$env:USERPROFILE\bypass-claude-folder.*","$env:USERPROFILE\telegram-routing-hook.*","$env:USERPROFILE\tg-inbox-mover.ps1" -ErrorAction SilentlyContinue
```

Desktop app and its credentials are untouched. To remove the channel routing / no-select rules from CLAUDE.md, manually delete the marked blocks.
