# Platform overlay: macOS

macOS-native execution steps for the deploy-telegram skill. Read [`../SKILL.md`](../SKILL.md) first for the universal contract and architecture; read [`../references/`](../references/) for the "why". This file is the **how**.

## Provenance

Production-deployed on **Mac mini (Darwin 24.6.0 arm64)** from 2026-05-14, with five production fixes layered on by 2026-05-22. The fixes are folded into the steps below (see "Real-world lesson" callouts). The fifth fix (FDA grant, Step 7e) was discovered after 8 days of apparent success — the deploy looked complete but Bash/Read tools silently failed on TCC-protected paths.

## What's NOT verified

- Intel Macs (only Apple Silicon tested; the self-heal logic in Step 7.1 handles both via the npm optional-dep mechanism, but the cross-arch reinstall path was not exercised)
- macOS 13/14 specifically (tested on macOS 15 / Sequoia)
- Multi-user macOS setups (only single-user tested)

## 🚫 macOS-specific do-not

In addition to the universal do-not list in [`../SKILL.md`](../SKILL.md):

1. **Do NOT translate `tmux new-session -d` directly into a launchd plist's `ProgramArguments`** — death-spiral. Always use the wrapper script (Step 7.2). See [`../references/process-supervisors.md`](../references/process-supervisors.md) §macOS.
2. **Do NOT use GNU sed syntax** (`sed -i 's/.../.../'`). BSD sed requires an empty backup-suffix: `sed -i '' 's/.../.../'`. The skill uses BSD sed throughout.
3. **Do NOT install Telegram plugin at user scope** if Claude Desktop App is on the same Mac. Use `--scope local` (Step 5). See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §4.
4. **Do NOT overwrite `~/.claude.json`** — Desktop App stores 23 KB of state there. Always merge (Step 3).
5. **Do NOT run `sudo npm install -g`** — creates root-owned files in `/usr/local` that conflict with brew. Use `~/.npm-global/` prefix instead.
6. **Do NOT assume the launchd chain inherits Full Disk Access for `claude.exe` subprocesses** — it doesn't. `claude.exe` is hardened-runtime; macOS TCC resets the responsible-process chain for subprocesses of hardened binaries. A launchd-only deploy gets `errno=1 EPERM` on `~/Downloads`, `~/Documents`, `~/Desktop`, and other TCC-protected paths — silent functional incompleteness. The skill MUST grant FDA explicitly to `claude.exe` (Step 7e) or the deploy is broken. See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §11.

## Required inputs

| Variable | Format | Notes |
|---|---|---|
| `BOT_TOKEN` | `<digits>:<hash>` | From `@BotFather /newbot`. **Must be a fresh bot**. |
| `CLAUDE_OAUTH_TOKEN` | `sk-ant-oat01-...` | From `claude setup-token` (browser-based; can run on any Mac and paste back) |
| `USER_TELEGRAM_ID` | digits | Telegram user_id; obtainable via `@userinfobot` or post-pairing |

Optional:

| `DESKTOP_APP_CWD` | absolute path | Desktop App's typical cwd (e.g. an external volume where the operator habitually launches Claude) — only needed if `Step 7d` defense-in-depth scope override is desired |

## Network check (pre-flight)

```bash
echo "=== Network Check ==="
for url in https://api.telegram.org https://github.com; do
  curl -sf --max-time 10 -o /dev/null "$url" \
    && echo "PASS: $url reachable" \
    || echo "FAIL: $url unreachable"
done
# Anthropic API root returns 404 (no auth) — check connection succeeded
RES=$(curl -s --max-time 10 -o /dev/null -w "HTTP %{http_code}" https://api.anthropic.com/)
if [[ "$RES" =~ ^HTTP\ [0-9]{3}$ ]]; then
  echo "PASS: api.anthropic.com reachable ($RES)"
else
  echo "FAIL: api.anthropic.com unreachable"
fi
```

All three must pass.

---

## Step 0 — 🤖 Pre-flight environment check

```bash
set -e

echo "=== macOS version ==="
sw_vers

echo "=== required tools ==="
for t in brew node npm python3 curl; do
  if command -v $t >/dev/null 2>&1; then
    echo "  ✓ $t: $($t --version 2>&1 | head -1)"
  else
    echo "  ✗ $t: MISSING — install before continuing"
    exit 1
  fi
done

NODE_MAJOR=$(node --version | grep -oE '[0-9]+' | head -1)
if [ "$NODE_MAJOR" -lt 20 ]; then
  echo "FATAL: Node $NODE_MAJOR is too old; install Node 20+ (brew install node@22)"
  exit 1
fi
```

If any check fails:
- **brew missing** → `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
- **node missing or too old** → `brew install node@22` then ensure `/opt/homebrew/opt/node@22/bin` is on PATH

## Step 1 — 🤖 Install missing dependencies (tmux, bun)

```bash
if ! command -v tmux >/dev/null 2>&1; then
  brew install tmux
fi
echo "TMUX: $(tmux -V)"

if [ ! -f "$HOME/.bun/bin/bun" ]; then
  curl -fsSL https://bun.sh/install | bash 2>&1 | tail -3
fi
echo "BUN: $($HOME/.bun/bin/bun --version)"
```

## Step 2 — 🤖 Install Claude Code if missing (and self-heal native binary)

```bash
if ! command -v claude >/dev/null 2>&1; then
  # User-scope npm install (no sudo). If permission errors, configure ~/.npm-global/ prefix first.
  npm install -g @anthropic-ai/claude-code
fi

# CC auto-update can leave the native binary missing — pre-check
VERSION_OUT=$(claude --version 2>&1)
if echo "$VERSION_OUT" | grep -q "native binary not installed"; then
  echo "WARN: claude native binary missing — reinstalling to fetch optional deps"
  npm install -g @anthropic-ai/claude-code@latest 2>&1 | tail -3
fi
echo "CLAUDE: $(claude --version 2>&1 | head -1)"
```

> If `npm install -g` fails with permission errors, configure npm's prefix to a user-writable directory:
> ```
> mkdir -p ~/.npm-global
> npm config set prefix ~/.npm-global
> # add ~/.npm-global/bin to PATH (in ~/.zshrc or ~/.bash_profile)
> ```
> **Never** run `sudo npm install -g`.

## Step 3 — 🤖 Patch ~/.claude.json (MERGE, never overwrite)

> **Critical macOS lesson**: Desktop App stores 23 KB of state in `~/.claude.json` (`oauthAccount`, per-cwd `projects`, `tipsHistory`, `cachedGrowthBookFeatures`, `seenNotifications`, etc.). Overwriting it logs the user out and loses months of cached state. See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §5.

```bash
python3 << 'PY'
import json, os
p = os.path.expanduser('~/.claude.json')
d = json.load(open(p)) if os.path.exists(p) else {}
d['hasCompletedOnboarding'] = True
d['hasAcknowledgedCostThreshold'] = True
json.dump(d, open(p, 'w'), indent=2)
print(f"OK: patched {p}, preserved {len(d)} keys")
PY
```

## Step 4 — 🤖 Write ~/.claude/settings.json (MERGE into existing)

```bash
mkdir -p ~/.claude

python3 << 'PY'
import json, os
p = os.path.expanduser('~/.claude/settings.json')
d = json.load(open(p)) if os.path.exists(p) else {}

perms = d.setdefault('permissions', {})
allow = set(perms.get('allow', []))
allow.update(["Bash(*)", "Read(*)", "Write(*)", "Edit(*)", "Glob(*)", "Grep(*)", "WebSearch(*)", "WebFetch(*)", "NotebookEdit(*)", "mcp__plugin_telegram_telegram__*"])
# NOTE: CC 2.1.170+ rejects a bare "mcp__*" in allow rules — globs are only
# permitted in the tool position after a literal mcp__<server>__ prefix.
# Drop any legacy "mcp__*" left over from older installs so it doesn't warn:
allow.discard("mcp__*")
perms['allow'] = sorted(allow)
perms.setdefault('deny', [])
perms['defaultMode'] = 'bypassPermissions'

d['channelsEnabled'] = True
d['skipDangerousModePermissionPrompt'] = True

json.dump(d, open(p, 'w'), indent=4)
print(f"OK: settings.json merged at {p}")
PY
```

> `channelsEnabled: true` is mandatory; `permissions.defaultMode: "bypassPermissions"` is the only setting that actually silences permission prompts. See [`../references/architecture-and-design.md`](../references/architecture-and-design.md).

## Step 5 — 🤖 Install Telegram plugin AT LOCAL SCOPE

> **Critical macOS-specific scope difference**: install at **local scope** of the daemon's launch cwd (`$HOME`), not user scope. On a Mac that also runs Claude Desktop App, user-scope plugins are loaded by both processes — both spawn bun MCP servers — both contend for the bot token (409 Conflict). Local-scope confines the plugin to the daemon. See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §4.

```bash
cd ~

export CLAUDE_CODE_OAUTH_TOKEN='__CLAUDE_OAUTH_TOKEN__'   # substitute the actual token
export PATH="$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"

claude plugin marketplace add anthropics/claude-plugins-official 2>&1 | tail -2 || true
claude plugin marketplace update claude-plugins-official 2>&1 | tail -2
claude plugin uninstall telegram@claude-plugins-official 2>&1 | tail -2 || true
claude plugin install telegram@claude-plugins-official --scope local 2>&1 | tail -3

# CC 2.1.149+ defense-in-depth: explicit enable to ensure local-scope
# settings.local.json carries enabledPlugins.telegram=true. `install --scope local`
# should also enable, but 2.1.149's plugin loader bug observed on Windows 2026-05-26
# makes the explicit step worth keeping as a safety net.
# See ../references/post-deploy-hardening.md §12.
claude plugin enable telegram@claude-plugins-official 2>&1 | tail -2

claude plugin list 2>&1 | grep -q 'telegram.*enabled' \
  || { echo "FATAL: plugin install/enable failed. Output:"; claude plugin list 2>&1; exit 1; }
test -f "$HOME/.claude/settings.local.json" \
  || { echo "FATAL: settings.local.json missing at \$HOME/.claude/"; exit 1; }
echo "OK: telegram plugin installed AND enabled at LOCAL scope (cwd=$HOME)"
```

> **DO NOT use `--plugin-dir` with `--channels`** — see [`../references/architecture-and-design.md`](../references/architecture-and-design.md).

## Step 5b — 🤖 Patch plugin server.ts (BSD sed syntax)

```bash
F="$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts"
if [ ! -f "$F" ]; then
  echo "FATAL: server.ts not found at $F"; exit 1
fi

[ ! -f "$F.bak" ] && cp "$F" "$F.bak"

# BSD sed requires '' as backup suffix (GNU sed doesn't)
sed -i '' "s|'claude/channel/permission': {},|// 'claude/channel/permission': {}, // DISABLED: relays tool prompts to TG despite --dangerously-skip-permissions|" "$F"

grep -q "^ *// 'claude/channel/permission'" "$F" \
  && echo "OK: channel-permission relay disabled" \
  || { echo "WARNING: patch did not apply — plugin may have changed upstream."; exit 1; }
```

> Re-apply after plugin updates. See [`../references/architecture-and-design.md`](../references/architecture-and-design.md) §"The server.ts patch".

## Step 6 — 🤖 Configure bot token

```bash
mkdir -p ~/.claude/channels/telegram
echo "TELEGRAM_BOT_TOKEN=__BOT_TOKEN__" > ~/.claude/channels/telegram/.env   # substitute actual token
chmod 600 ~/.claude/channels/telegram/.env
echo "OK: bot token configured"
```

## Step 7 — 🤖 Write launcher + wrapper + plists + hooks + mover

Seven files. All paths absolute (launchd does not expand `~`).

### Step 7.1 — `~/start-claude.sh` (launcher with self-heal)

The inner loop. Includes **self-healing for CC auto-update breakage** — when CC updates and the npm optional dependency is missing, the launcher detects it, runs `npm install`, and notifies the user via direct Telegram API (since MCP reply tool is unavailable while claude is broken). See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §3.

```bash
cat > ~/start-claude.sh << 'STARTEOF'
#!/bin/bash
export CLAUDE_CODE_OAUTH_TOKEN='__CLAUDE_OAUTH_TOKEN__'
export TELEGRAM_BOT_TOKEN='__BOT_TOKEN__'
export PATH="$HOME/.bun/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:$PATH"

USER_TELEGRAM_ID='__USER_TELEGRAM_ID__'

ts() { date '+%Y-%m-%d %H:%M:%S'; }

tg_notify() {
    local text="$1"
    [ -z "$TELEGRAM_BOT_TOKEN" ] && return 0
    curl -sf --max-time 8 -X POST \
        "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${USER_TELEGRAM_ID}" \
        --data-urlencode "text=${text}" \
        >/dev/null 2>&1
}

self_heal_native_binary() {
    echo "[$(ts)] Native binary missing. Self-healing via npm install -g @latest" >&2
    tg_notify "🔧 Claude Code detected a broken native binary after auto-update. Self-healing via npm install (~10 min). Will resume listening when done."

    npm install -g @anthropic-ai/claude-code@latest 2>&1 | tail -5 >&2

    if claude --version >/dev/null 2>&1; then
        local ver
        ver=$(claude --version 2>&1 | head -1)
        echo "[$(ts)] Self-heal OK: ${ver}" >&2
        tg_notify "✅ Self-heal complete: ${ver}. Resuming Telegram listening."
        return 0
    fi
    echo "[$(ts)] Self-heal FAILED" >&2
    tg_notify "⚠️ Self-heal failed. Manual intervention needed: SSH into the Mac and check ~/Library/Logs/claude-telegram.log + npm install errors."
    return 1
}

cd ~
FAIL_STREAK=0
while true; do
    if ! version_out=$(claude --version 2>&1); then
        if echo "$version_out" | grep -q "native binary not installed"; then
            if self_heal_native_binary; then
                FAIL_STREAK=0
            else
                FAIL_STREAK=$((FAIL_STREAK + 1))
                # Exponential backoff: 60s, 300s, 900s, 1800s, then cap
                case $FAIL_STREAK in
                    1) sleep 60 ;;
                    2) sleep 300 ;;
                    3) sleep 900 ;;
                    *) sleep 1800 ;;
                esac
                continue
            fi
        else
            echo "[$(ts)] claude --version failed (non-binary reason): $version_out" >&2
            sleep 10
            continue
        fi
    fi

    claude --dangerously-skip-permissions \
      --channels plugin:telegram@claude-plugins-official
    echo "[$(ts)] Claude exited. Restarting in 3s..."
    sleep 3
done
STARTEOF
chmod 700 ~/start-claude.sh
```

### Step 7.2 — `~/start-claude-launchd-wrapper.sh` (launchd supervisor target)

The script launchd actually watches. Maintains the tmux session and gives launchd a process to keep alive. **macOS replacement for systemd's `RemainAfterExit=yes`.** See [`../references/process-supervisors.md`](../references/process-supervisors.md) §macOS for the death-spiral analysis.

```bash
cat > ~/start-claude-launchd-wrapper.sh << 'WRAPEOF'
#!/bin/bash
export PATH="/opt/homebrew/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"

if ! tmux has-session -t claude 2>/dev/null; then
  tmux new-session -d -s claude /Users/__USER__/start-claude.sh
fi

while tmux has-session -t claude 2>/dev/null; do
  sleep 30
done

exit 1
WRAPEOF

sed -i '' "s|__USER__|$(whoami)|g" ~/start-claude-launchd-wrapper.sh
chmod 700 ~/start-claude-launchd-wrapper.sh
```

### Step 7.3 — `~/Library/LaunchAgents/com.openclaw.claude-telegram.plist`

```bash
mkdir -p ~/Library/LaunchAgents ~/Library/Logs

cat > ~/Library/LaunchAgents/com.openclaw.claude-telegram.plist << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.claude-telegram</string>
    <key>ProgramArguments</key>
    <array>
        <string>\${HOME}/start-claude-launchd-wrapper.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>\${HOME}/Library/Logs/claude-telegram.log</string>
    <key>StandardErrorPath</key>
    <string>\${HOME}/Library/Logs/claude-telegram.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLISTEOF

# launchd does NOT expand \${HOME} inside plists. Substitute now.
sed -i '' "s|\\\${HOME}|$HOME|g" ~/Library/LaunchAgents/com.openclaw.claude-telegram.plist
plutil -lint ~/Library/LaunchAgents/com.openclaw.claude-telegram.plist
```

### Step 7.4 — `~/tg-inbox-move.sh` + WatchPaths plist

```bash
mkdir -p ~/telegram-inbox

cat > ~/tg-inbox-move.sh << 'MOVEREOF'
#!/bin/bash
mkdir -p /Users/__USER__/telegram-inbox /Users/__USER__/.claude/channels/telegram/inbox
find /Users/__USER__/.claude/channels/telegram/inbox -maxdepth 1 -type f -exec mv {} /Users/__USER__/telegram-inbox/ \;
MOVEREOF
sed -i '' "s|__USER__|$(whoami)|g" ~/tg-inbox-move.sh
chmod 700 ~/tg-inbox-move.sh

cat > ~/Library/LaunchAgents/com.openclaw.tg-inbox-mover.plist << MOVERPLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.openclaw.tg-inbox-mover</string>
    <key>ProgramArguments</key>
    <array>
        <string>\${HOME}/tg-inbox-move.sh</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>\${HOME}/.claude/channels/telegram/inbox</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>\${HOME}/Library/Logs/tg-inbox-mover.log</string>
    <key>StandardErrorPath</key>
    <string>\${HOME}/Library/Logs/tg-inbox-mover.log</string>
</dict>
</plist>
MOVERPLISTEOF
sed -i '' "s|\\\${HOME}|$HOME|g" ~/Library/LaunchAgents/com.openclaw.tg-inbox-mover.plist
plutil -lint ~/Library/LaunchAgents/com.openclaw.tg-inbox-mover.plist
```

## Step 7b — 🤖 Install hooks

### Step 7b.1 — `~/bypass-claude-folder.sh`

```bash
cat > ~/bypass-claude-folder.sh << 'HOOKEOF'
#!/bin/bash
input=$(cat)
HOOK_HOME="$HOME" python3 - "$input" << 'PY'
import sys, json, os
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)

event = d.get("hook_event_name", "")
ti = d.get("tool_input", {}) or {}
home = os.environ.get("HOOK_HOME", "")

SENSITIVE_DIR_SUBSTRINGS = ("/.claude/", "/.config/")
SENSITIVE_BASENAMES = {".claude", ".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile", ".zshenv", ".gitconfig", ".npmrc", ".env", ".envrc", ".claude.json"}
SENSITIVE_CMD_TOKENS = ("/.claude/", "/.config/", "/.bashrc", "/.bash_profile", "/.profile", "/.zshrc", "/.zprofile", "/.zshenv", "/.gitconfig", "/.npmrc", "/.env", "/.envrc", "/.claude.json", "~/.claude/", "~/.config/", "~/.bashrc", "~/.bash_profile", "~/.profile", "~/.zshrc", "~/.zprofile", "~/.zshenv", "~/.gitconfig", "~/.npmrc", "~/.env", "~/.envrc", "~/.claude.json")

def expand_path(p):
    if p.startswith("~/"): return home + p[1:]
    if p == "~": return home
    return p

def path_is_sensitive(p):
    if not p: return False
    expanded = expand_path(p)
    if any(s in expanded for s in SENSITIVE_DIR_SUBSTRINGS): return True
    return os.path.basename(expanded.rstrip("/")) in SENSITIVE_BASENAMES

def cmd_is_sensitive(cmd):
    if not cmd: return False
    return any(tok in cmd for tok in SENSITIVE_CMD_TOKENS)

path = ti.get("file_path") or ti.get("notebook_path") or ""
if path_is_sensitive(path): pass
elif ti.get("command") and cmd_is_sensitive(ti["command"]): pass
else: sys.exit(0)

if event == "PreToolUse":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "permissionDecisionReason": "auto-allow sensitive path via bypass-claude-folder hook"}}))
elif event == "PermissionRequest":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}))
PY
HOOKEOF
chmod 700 ~/bypass-claude-folder.sh
```

> Substring matching covers project-nested `.claude/` dirs. See [`../references/architecture-and-design.md`](../references/architecture-and-design.md) §"Permission-bypass hook".

### Step 7b.2 — `~/telegram-routing-hook.sh`

```bash
cat > ~/telegram-routing-hook.sh << 'ROUTEEOF'
#!/bin/bash
input=$(cat)
python3 - "$input" << 'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
user_input = d.get("tool_input", {}).get("prompt", "") or ""
if "telegram" in user_input.lower() and ("<-" in user_input or chr(8592) in user_input):
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "TELEGRAM ROUTING MANDATORY: This message came from Telegram. You MUST call plugin:telegram:telegram reply MCP tool with chat_id to send your response. Terminal output is INVISIBLE to the Telegram user. Do NOT skip the reply tool call."}}))
PY
ROUTEEOF
chmod 700 ~/telegram-routing-hook.sh
```

> Known limitation: see [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §6.

### Step 7b.3 — Register hooks in settings.json

```bash
python3 << 'PY'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p))
hooks = d.setdefault("hooks", {})

def add_hook(event, cmd):
    existing = hooks.get(event, [])
    if not any(cmd in str(h) for h in existing):
        existing.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})
        hooks[event] = existing

add_hook("PreToolUse", os.path.expanduser("~/bypass-claude-folder.sh"))
add_hook("PermissionRequest", os.path.expanduser("~/bypass-claude-folder.sh"))
add_hook("UserPromptSubmit", os.path.expanduser("~/telegram-routing-hook.sh"))

json.dump(d, open(p, "w"), indent=4)
print("OK: hooks registered in settings.json")
PY
```

## Step 7c — 🤖 Patch hasTrustDialogAccepted (macOS-specific)

> **Without this**, every fresh `claude` invocation in `$HOME` blocks on the "Trust this folder?" dialog. Since launchd restarts the wrapper across reboots, every reboot leaves the daemon hung on an invisible dialog. See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §1.

```bash
python3 << 'PY'
import json, os
p = os.path.expanduser('~/.claude.json')
d = json.load(open(p))
projects = d.setdefault('projects', {})
projects.setdefault(os.path.expanduser('~'), {})['hasTrustDialogAccepted'] = True
json.dump(d, open(p, 'w'), indent=2)
print(f"OK: hasTrustDialogAccepted=true for {os.path.expanduser('~')}")
PY
```

## Step 7d — 🟡 AUTO-FIRST: Desktop App scope isolation (optional defense-in-depth)

**Only run if `DESKTOP_APP_CWD` was provided.** Step 5 already isolated the plugin to local scope of `$HOME`. This step adds a defense-in-depth override to Desktop App's typical cwd.

```bash
DESKTOP_APP_CWD='__DESKTOP_APP_CWD__'
if [ -d "/Applications/Claude.app" ] && [ -n "$DESKTOP_APP_CWD" ]; then
  mkdir -p "$DESKTOP_APP_CWD/.claude"
  TARGET="$DESKTOP_APP_CWD/.claude/settings.local.json"
  python3 << PY
import json, os
p = "$TARGET"
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault('enabledPlugins', {})['telegram@claude-plugins-official'] = False
json.dump(d, open(p, 'w'), indent=2)
print(f"OK: enabledPlugins.telegram=false written to {p}")
PY
else
  echo "SKIP: Desktop App not installed OR DESKTOP_APP_CWD not provided"
fi
```

## Step 7e — 👤 MANUAL: Grant Full Disk Access to `claude.exe`

> **Critical macOS lesson** (production discovery 2026-05-22, see [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §11): without this step the deploy is **functionally incomplete**. `claude.exe` is hardened-runtime + Anthropic-signed; macOS TCC resets the responsible-process chain for subprocesses of hardened binaries, so Bash / Read tools inside the daemon's Claude session return `errno=1 EPERM` on `~/Downloads`, `~/Documents`, `~/Desktop`, and other TCC-protected paths — even though `os.path.exists()` returns True. The launchd → wrapper → tmux → start-claude.sh chain inherits user-domain FDA fine because every link is unhardened; `claude.exe` is the layer that breaks the chain.

**Mandatory step that cannot be automated.** macOS TCC.db is SIP-protected; only GUI grants work and only the human user can perform them. `tccutil` can reset but not grant.

### Procedure

Open System Settings directly to the FDA pane:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
```

In the FDA pane:

1. Click the lock icon → unlock (Touch ID / password)
2. Click the **+** button
3. In the file picker: `Cmd+Shift+G` → paste this path (substitute your username):
   ```
   /Users/<USER>/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/
   ```
4. Select `claude.exe` → Open
5. Confirm `claude.exe` appears in the FDA list and the toggle is **ON**

### Restart so the grant takes effect

The currently-running claude process holds a TCC cache from before the grant. Restart it:

```bash
pkill -f 'claude .*--channels plugin:telegram@claude-plugins-official'
# start-claude.sh's while-true loop respawns claude in ~12 s with the new TCC grant in effect
sleep 15
```

### Verify

```bash
# Through the daemon's Bash tool (the path that goes claude.exe -> spawn shell -> cat):
cat ~/Downloads/.DS_Store >/dev/null 2>&1 && echo "FDA OK" || echo "FDA STILL MISSING"
```

Expected: `FDA OK`.

> **Do NOT verify with `launchctl bsexec`** — that test path is unhardened `/bin/cat`, inherits launchd-domain FDA correctly, and gives a false positive. The probe MUST traverse `claude.exe`'s subprocess chain. See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §11 for the misleading-test analysis.

### Re-grant after CC updates

`npm install -g @anthropic-ai/claude-code@latest` (incl. the self-heal path in Step 7.1) replaces `claude.exe`. TCC matches by path + signing identity. As long as Anthropic ships future versions with the same TeamIdentifier (`Q6L2SF6YDW`), the grant persists across updates. If a future update changes signing identity, the grant is lost and Step 7e must be repeated. Symptom is the same recurring EPERM after a CC upgrade. The FDA self-check rule installed in Step 9b (Rule 3) catches this automatically on the next session start.

## Step 8 — 🤖 Bootstrap launchd agents

```bash
UID_NUM=$(id -u)

# Defensive: bootout existing (idempotent — silent on first run)
launchctl bootout gui/$UID_NUM/com.openclaw.claude-telegram 2>&1 | grep -v "Could not find" || true
launchctl bootout gui/$UID_NUM/com.openclaw.tg-inbox-mover 2>&1 | grep -v "Could not find" || true

launchctl bootstrap gui/$UID_NUM ~/Library/LaunchAgents/com.openclaw.claude-telegram.plist
launchctl bootstrap gui/$UID_NUM ~/Library/LaunchAgents/com.openclaw.tg-inbox-mover.plist

launchctl list | grep "com.openclaw" \
  || { echo "FATAL: launchd agents did not load"; exit 1; }
echo "OK: both agents bootstrapped"
```

## Step 9 — 🤖 First-launch verification

```bash
sleep 15  # let claude + bun start

for i in 1 2 3 4 5; do
  if tmux capture-pane -t claude -p 2>&1 | grep -q "Listening for channel messages"; then
    echo "SUCCESS: Claude Code listening for Telegram messages"
    break
  fi
  sleep 5
done

if ! tmux capture-pane -t claude -p 2>&1 | grep -q "Listening for channel messages"; then
  echo "WARNING: 'Listening' state not confirmed. Last pane content:"
  tmux capture-pane -t claude -p 2>&1 | tail -20
  echo "See ../references/troubleshooting.md"
  exit 1
fi

# Verify the full process chain
ps -ax -o pid,ppid,command | grep -E "tmux.*claude|start-claude|claude --dangerously|bun.*server\.ts" | grep -v grep
```

Expected process tree:

```
launchd
└── start-claude-launchd-wrapper.sh
    └── tmux new-session ... start-claude.sh
        └── claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official
            └── bun run --cwd .../telegram/<ver> --shell=bun --silent start
                └── bun server.ts   ← long-polls Telegram bot
```

## Step 9b — 🤖 Install both CLAUDE.md rule blocks

```bash
install_block() {
  local F=$1
  local MARKER=$2
  local BLOCK=$3
  mkdir -p "$(dirname "$F")"
  touch "$F"
  if grep -q "$MARKER" "$F"; then
    echo "  Already present: $F ($MARKER)"
    return
  fi
  echo "$BLOCK" >> "$F"
  echo "  Appended: $F ($MARKER)"
}

RULE_CHANNEL=$(cat << 'EOF'

<!-- BEGIN: channel-routing-rule -->
## Channel Routing Rule (highest priority)

**General principle**: Reply on the *same platform* the message came from.
Telegram in → Telegram reply tool out. Terminal in → stdout out. Never cross.

When the incoming message is tagged `← telegram · <user_id>:`, you **must**
reply by calling the `plugin:telegram:telegram - reply` MCP tool targeted at
the same `chat_id`. Terminal output alone is invisible to the Telegram user.

1. Every user-visible Telegram reply must go through the reply tool.
2. Do not assume the Telegram user can see terminal output.
3. If a tool call fails, retry; do not silently drop the reply.
4. Do not cross-route: never answer a Telegram message by printing only to
   the terminal, and never push a terminal-only task into Telegram.
5. This rule overrides any default "just print to stdout" behavior.
6. Even if you already printed text to the terminal, you must still issue a
   reply tool call afterwards — terminal output does not count as a reply.

### Telegram file uploads (macOS / launchd path watcher)

Telegram uploads are auto-moved by `com.openclaw.tg-inbox-mover` from
`~/.claude/channels/telegram/inbox/` to `~/telegram-inbox/`. Always read from
`~/telegram-inbox/`. Never touch paths under `~/.claude/channels/` —
CC's hardcoded sensitive-file guard will freeze your session.
<!-- END: channel-routing-rule -->
EOF
)

RULE_NOSELECT=$(cat << 'EOF'

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
EOF
)

RULE_FDA=$(cat << 'EOF'

<!-- BEGIN: macos-fda-self-check-rule -->
## macOS FDA Self-Check on Session Start (macOS-only)

On every Claude Code session start (including launchd-respawns after `pkill claude`
or after `self_heal_native_binary` reinstalls), execute this self-check **exactly
once** via the Bash tool, **before processing any user message**:

\`\`\`bash
cat ~/Downloads/.DS_Store >/dev/null 2>&1
echo "fda_probe_exit=$?"
\`\`\`

Fallback: if `~/Downloads/.DS_Store` doesn't exist, try `~/Desktop/.DS_Store`. If
neither exists, skip the probe (note it in `feedback.md` and proceed — most Macs
have at least one).

**If `fda_probe_exit=0`**: FDA grant is functional. Continue normally; do NOT send
any user-facing message — silent OK.

**If `fda_probe_exit=1` (EPERM)**: `claude.exe` is missing its Full Disk Access
grant. **Immediately call `plugin:telegram:telegram - reply` to the configured
user with this message verbatim**:

> ⚠️ FDA grant missing for claude.exe. Bash/Read tools will return EPERM on
> ~/Downloads, ~/Documents, ~/Desktop. Fix: open System Settings → Privacy &
> Security → Full Disk Access → add
> `/Users/<USER>/.npm-global/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe`
> → toggle ON → then run `pkill -f 'claude .*--channels'` so I pick up the new
> grant on the next launchd respawn.

Continue normal listening afterward — the absence of FDA doesn't break Telegram
messaging itself; only file ops on protected paths fail. The user can still talk
to you, and you can still do non-file work while waiting for them to fix it. Do
NOT enter a tight retry loop checking the grant — wait for the next session start
(post-respawn).
<!-- END: macos-fda-self-check-rule -->
EOF
)

install_block ~/CLAUDE.md '<!-- BEGIN: channel-routing-rule -->' "$RULE_CHANNEL"
install_block ~/.claude/CLAUDE.md '<!-- BEGIN: channel-routing-rule -->' "$RULE_CHANNEL"
install_block ~/CLAUDE.md '<!-- BEGIN: no-interactive-select-rule -->' "$RULE_NOSELECT"
install_block ~/.claude/CLAUDE.md '<!-- BEGIN: no-interactive-select-rule -->' "$RULE_NOSELECT"
# macOS-only Rule 3 (FDA self-check). See references/claude-md-rules.md "Install order".
install_block ~/CLAUDE.md '<!-- BEGIN: macos-fda-self-check-rule -->' "$RULE_FDA"
install_block ~/.claude/CLAUDE.md '<!-- BEGIN: macos-fda-self-check-rule -->' "$RULE_FDA"
```

> See [`../references/claude-md-rules.md`](../references/claude-md-rules.md) for why both rules and both files.

> Restart daemon to reload CLAUDE.md:
> ```bash
> launchctl bootout gui/$(id -u)/com.openclaw.claude-telegram
> launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.claude-telegram.plist
> ```

## Step 9c — 👤 Telegram pairing

```bash
# After the human gets a 6-character pairing code from the bot:
tmux send-keys -t claude "/telegram:access pair __CODE__" Enter
sleep 8
tmux send-keys -t claude Enter   # confirm any follow-up
sleep 3

tmux send-keys -t claude '/telegram:access policy allowlist' Enter
sleep 5
tmux send-keys -t claude Enter
sleep 3
```

Verify by examining `~/.claude/channels/telegram/access.json`:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["<USER_TELEGRAM_ID>"],
  "groups": {},
  "pending": {}
}
```

Then send a test message from the phone and confirm a reply lands.

> Full pairing details in [`../references/pairing-and-access.md`](../references/pairing-and-access.md).

## Step 10 — 🤖 Install desktop fix script (`fix-telegram-daemon.command`)

> **Why this exists**: when the Telegram pipeline goes silent (bun crashed, claude died, tmux session vanished, or two `bun` processes are contending for the bot token), the operator wants a single double-click to get back to a known-good state. This step deploys [`../scripts/macos/fix-telegram-daemon.command`](../scripts/macos/fix-telegram-daemon.command) to the user's Desktop and substitutes their Telegram user_id so the script can notify them about repair progress.

> **Idempotent and defensive**: see the script's standalone [README](../scripts/macos/README.md) for the five-case decision tree. Safe to run on a healthy system (just sends one "all good" Telegram message and exits 0).

The script lives as a standalone file in this repo at [`../scripts/macos/fix-telegram-daemon.command`](../scripts/macos/fix-telegram-daemon.command). **Preferred install** copies it from the skill directory:

```bash
# Primary path: skill is installed at the canonical location
SKILL_SCRIPTS="$HOME/.claude/skills/deploy-telegram/scripts/macos"
DEST="$HOME/Desktop/fix-telegram-daemon.command"

if [ -r "$SKILL_SCRIPTS/fix-telegram-daemon.command" ]; then
    cp "$SKILL_SCRIPTS/fix-telegram-daemon.command" "$DEST"
    echo "OK: copied from $SKILL_SCRIPTS"
else
    # Fallback for cases where the skill is loaded from a non-canonical
    # path (e.g. URL-loaded skill). The heredoc below mirrors
    # scripts/macos/fix-telegram-daemon.command — keep these in sync if
    # you modify either. (Trimmed for brevity; canonical version lives
    # in scripts/macos/.)
    cat > "$DEST" <<'FIXEOF'
#!/bin/bash
# fix-telegram-daemon.command — see scripts/macos/ for the full source.
# Idempotent manual self-heal for the Claude Code <-> Telegram pipeline.

ENV_FILE="$HOME/.claude/channels/telegram/.env"
BOT_TOKEN=""
if [ -r "$ENV_FILE" ]; then
    BOT_TOKEN=$(awk -F= '/^TELEGRAM_BOT_TOKEN=/{ sub(/^TELEGRAM_BOT_TOKEN=/, "", $0); gsub(/[[:space:]"\047]/, "", $0); print; exit }' "$ENV_FILE")
fi
CHAT_ID='<CHAT_ID>'
LOG="$HOME/fix-telegram-daemon.log"
START_SCRIPT="$HOME/start-claude.sh"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }
tg() {
    [ -z "$BOT_TOKEN" ] && return 0
    case "$CHAT_ID" in '<CHAT_ID>'|''|'<'*'>') return 0 ;; esac
    curl -sf --max-time 8 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" --data-urlencode "text=$1" >/dev/null 2>&1
}

CLAUDE_PID=$(ps aux | awk '/claude --dangerously-skip-permissions/ && !/awk/ {print $2}' | head -1)
BUN_PIDS=($(ps aux | awk '/bun server\.ts/ && !/awk/ {print $2}'))
BUN_COUNT=${#BUN_PIDS[@]}
TMUX_OK=$(tmux has-session -t claude 2>/dev/null && echo yes || echo no)

log "=== Fix started ===  claude=${CLAUDE_PID:-none}  bun=${BUN_PIDS[*]:-none}  tmux=$TMUX_OK"

if [ "$BUN_COUNT" -gt 1 ]; then
    KEEP=""
    [ -n "$CLAUDE_PID" ] && for pid in "${BUN_PIDS[@]}"; do
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        gppid=$(ps -o ppid= -p "$ppid" 2>/dev/null | tr -d ' ')
        if [ "$gppid" = "$CLAUDE_PID" ] || [ "$ppid" = "$CLAUDE_PID" ]; then KEEP="$pid"; break; fi
    done
    for pid in "${BUN_PIDS[@]}"; do [ "$pid" = "$KEEP" ] && continue; kill "$pid" 2>/dev/null; log "killed rogue bun $pid"; done
    sleep 2
fi

if [ -z "$(ps aux | awk '/bun server\.ts/ && !/awk/ {print $2}')" ] && [ -n "$CLAUDE_PID" ]; then
    kill "$CLAUDE_PID" 2>/dev/null; log "killed claude $CLAUDE_PID for respawn"
    tg "Claude daemon: restarting..."; sleep 15
elif [ -z "$CLAUDE_PID" ] && [ "$TMUX_OK" = "no" ]; then
    export PATH="$HOME/.bun/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:$PATH"
    tmux new-session -d -s claude "$START_SCRIPT"; log "recreated tmux session"
    tg "Claude daemon: tmux recreated"; sleep 12
fi

NC=$(ps aux | awk '/claude --dangerously-skip-permissions/ && !/awk/ {print $2}' | head -1)
NB=$(ps aux | awk '/bun server\.ts/ && !/awk/ {print $2}' | head -1)
log "=== Fix done ===  claude=${NC:-none}  bun=${NB:-none}"
[ -n "$NC" ] && [ -n "$NB" ] && tg "OK Claude daemon healthy (claude=$NC, bun=$NB)" && exit 0
tg "FAIL Claude daemon could not be recovered — run: tmux attach -t claude"
exit 1
FIXEOF
    echo "OK: wrote fallback to $DEST (full version in scripts/macos/)"
fi

chmod +x "$DEST"

# Substitute the operator's Telegram user_id into the CHAT_ID placeholder.
# USER_TELEGRAM_ID is one of the universal Required inputs for this skill;
# if you do not have it yet, run /telegram:access list after Step 9c to
# read it from access.json's allowFrom array.
if [ -n "$USER_TELEGRAM_ID" ]; then
    sed -i.bak "s|<CHAT_ID>|$USER_TELEGRAM_ID|g" "$DEST"
    rm "$DEST.bak"
    echo "OK: substituted CHAT_ID=$USER_TELEGRAM_ID"
else
    echo "WARN: USER_TELEGRAM_ID not set — fix script will run without Telegram notifications until you sed it in manually"
fi
```

Verify the install:

```bash
# 1. File exists, is executable, no placeholder left
test -x "$HOME/Desktop/fix-telegram-daemon.command" && echo "OK: executable"
grep -q '<CHAT_ID>' "$HOME/Desktop/fix-telegram-daemon.command" \
    && echo "WARN: <CHAT_ID> placeholder still present — sed it manually" \
    || echo "OK: CHAT_ID substituted"

# 2. Dry-run the healthy path: BOT_TOKEN should be readable from .env
awk -F= '/^TELEGRAM_BOT_TOKEN=/{print "OK: BOT_TOKEN in .env (len=" length($2) ")"}' \
    "$HOME/.claude/channels/telegram/.env"
```

Tell the user: **"Double-click `fix-telegram-daemon.command` on your Desktop if Telegram ever stops responding. Safe to run anytime — it diagnoses first, only acts if needed, sends you a Telegram message either way."**

Full design notes (when to use, what each branch does, why `ps aux | awk` instead of `pgrep -f`, why direct `curl` instead of MCP) live in the script's [README](../scripts/macos/README.md).

## File manifest

| Path | Purpose | Perms |
|---|---|---|
| `~/.claude.json` | Onboarding + per-cwd trust (MERGED) | 600 |
| `~/.claude/settings.json` | Permissions + channelsEnabled + hooks (MERGED) | 644 |
| `~/.claude/settings.local.json` | Local-scope `enabledPlugins.telegram: true` | 644 |
| `~/.claude/channels/telegram/.env` | Bot token | 600 |
| `~/start-claude.sh` | Launcher with self-heal | 700 |
| `~/start-claude-launchd-wrapper.sh` | launchd target — supervises tmux | 700 |
| `~/bypass-claude-folder.sh` | Sensitive-path bypass hook | 700 |
| `~/telegram-routing-hook.sh` | Routing reminder hook | 700 |
| `~/tg-inbox-move.sh` | WatchPaths target | 700 |
| `~/Library/LaunchAgents/com.openclaw.claude-telegram.plist` | Main supervisor plist | 644 |
| `~/Library/LaunchAgents/com.openclaw.tg-inbox-mover.plist` | WatchPaths plist | 644 |
| `~/CLAUDE.md` + `~/.claude/CLAUDE.md` | Three rule blocks installed (channel routing + no-interactive-select + macOS-FDA-self-check) | 644 |
| `~/Library/Logs/claude-telegram.log` | launchd stderr/stdout | 644 |
| `~/telegram-inbox/` | Safe destination for uploads | 755 |
| `~/Desktop/fix-telegram-daemon.command` | Manual recovery (Step 10) — double-click when Telegram goes silent | 755 |
| `~/fix-telegram-daemon.log` | Recovery script log (written each run, append-mode) | 644 |
| **System Settings FDA grant for `claude.exe`** | One-time GUI grant (Step 7e) to give claude subprocesses TCC access to protected paths | n/a (GUI, SIP-protected TCC.db) |

## Compatibility

- **macOS version**: 12 (Monterey) or later (`launchctl bootstrap` syntax)
- **Architecture**: Apple Silicon (arm64) and Intel (x86_64) both supported
- **Claude Desktop App coexistence**: supported via Step 5 (local-scope) + Step 7d (defense-in-depth)
- **Tested**: production on Mac mini (Darwin 24.6.0 arm64), 2026-05-14 → 2026-05-22 (FDA fix discovered 2026-05-22 after 8 days of apparent success)
