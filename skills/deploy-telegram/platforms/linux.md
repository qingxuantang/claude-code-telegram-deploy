# Platform overlay: Linux

Linux execution steps for the deploy-telegram skill. Read [`../SKILL.md`](../SKILL.md) first for the universal contract and architecture; read [`../references/`](../references/) for the "why". This file is the **how**.

Linux is the **original target platform** for this skill — the macOS and Windows ports both descend from it. Linux is also the only platform where this skill supports both **remote** (controller agent SSH-ing to a server) and **local self-execution** (agent runs on the same machine, e.g. OpenClaw migrating to Claude Code in place).

## Provenance

Production-deployed across **four servers** (HK / SG / JP) from 2026-04-07 to 2026-05-06. Layered with hot-fixes for:
- 409 zombie poller (Step 8)
- `--plugin-dir` vs `--channels` mutual exclusion
- Channel permission relay (Step 4b)
- Self-edit guard via PermissionRequest hook (Step 7c, commit `1273e2e` substring-match upgrade)
- Long-session attention drift (no fix, only mitigation via daily restart)
- `~/.claude/` inbox guard (Step 7c.5)

## What changed in this version vs the pre-refactor `skills/deploy-telegram/SKILL.md`

1. **Step 3 (`.claude.json`) and Step 4 (`settings.json`) are now additive merges** instead of destructive overwrites. Previously the skill's `cat > <file> << EOF` would wipe any pre-existing `permissions`, `mcpServers`, `hooks`, or `projects` content. Backported from the macOS overlay's Python-based merge after multiple production incidents on dual-track (OpenClaw + Claude Code) servers.
2. **Step 10 (CLAUDE.md rules) now installs BOTH the channel-routing-rule AND the no-interactive-select-rule.** Previously only the channel-routing-rule was installed. The no-interactive-select-rule prevents `AskUserQuestion` deadlock — discovered in production on Mac, applies equally to Linux. See [`../references/claude-md-rules.md`](../references/claude-md-rules.md) §"Rule 2".
3. **Step 7c hook registration is now additive.** Previously a fresh install would replace the entire `PreToolUse` / `PermissionRequest` array, clobbering other tools' hooks (e.g. analytics, custom workflows). Backported from Windows overlay's lessons.

## 🚫 Linux-specific do-not

In addition to the universal do-not list in [`../SKILL.md`](../SKILL.md):

1. **Do NOT use mainland-China servers.** Telegram and GitHub are blocked. Use HK / SG / JP / US / EU.
2. **Do NOT skip `loginctl enable-linger <user>`.** Without it, user-level systemd services stop when the user's last login session ends.
3. **Do NOT forget to source NVM in `~/.bashrc` AND `start-claude.sh`.** Non-interactive shells don't load NVM by default; you'll get `claude: command not found` in the supervisor.
4. **Do NOT mix the `$SSH_CMD` wrapper styles.** The skill is written remote-first (`$SSH_CMD bash -s << EOF`); set `SSH_CMD=""` for local self-execution and the wrapper degrades cleanly. Do NOT fork the skill into separate "remote" and "local" versions.

## Execution mode (Linux-only flexibility)

Define `SSH_CMD` **once** before Step 1:

| Mode | When | `SSH_CMD` definition |
|---|---|---|
| **Remote** | Controller agent (laptop / jump host) targets a server | `SSH_CMD="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=15 ${SSH_USER}@${SSH_HOST}"` |
| **Local self-execution** | Agent runs on the target host itself (e.g. OpenClaw deploying CC beside itself) | `SSH_CMD=""` |

Every step is wrapped in `$SSH_CMD bash -s << EOF ... EOF`. With `SSH_CMD=""` this collapses to `bash -s << EOF ... EOF`, a plain local heredoc.

### 🪞 Self-execution caveats (when OpenClaw migrates to CC on same host)

1. **Don't kill yourself.** Do not stop OpenClaw during deploy. Parallel install, not takeover.
2. **Same Linux user.** Whatever user runs `claude` later must own `~/.claude/`, `~/CLAUDE.md`, `~/start-claude.sh`.
3. **OAuth token still needs a browser.** Ask the human to run `claude setup-token` on their laptop.
4. **New Telegram bot.** Never reuse the OpenClaw bot — two long-pollers = 409 Conflict.
5. **Cron / WhatsApp / Slack stay running.** Don't touch other channels.

## Required inputs

| Variable | Format | Notes |
|---|---|---|
| `SSH_HOST` | IP / hostname | Only for remote mode |
| `SSH_USER` | string | Default `ubuntu` |
| `SSH_PORT` | integer | Default `22` |
| `BOT_TOKEN` | `<digits>:<hash>` | From `@BotFather /newbot`. **Must be a fresh bot**. |
| `CLAUDE_TOKEN` | `sk-ant-oat01-...` | From `claude setup-token` on a machine with a browser |

## Network check (pre-flight)

```bash
$SSH_CMD bash -s << 'EOF'
echo "=== Network Check ==="
curl -sf --max-time 10 "https://api.telegram.org" >/dev/null 2>&1 \
  && echo "PASS: api.telegram.org" \
  || echo "FAIL: api.telegram.org (mainland-China network?)"
curl -sf --max-time 10 "https://github.com" >/dev/null 2>&1 \
  && echo "PASS: github.com" \
  || echo "FAIL: github.com"
# Anthropic API root returns 404 (no real / endpoint) — check connection succeeded
RES=$(curl -s --max-time 10 -o /dev/null -w "HTTP %{http_code}" https://api.anthropic.com/)
[[ "$RES" =~ ^HTTP\ [0-9]{3}$ ]] \
  && echo "PASS: api.anthropic.com ($RES)" \
  || echo "FAIL: api.anthropic.com"
EOF
```

All three must pass.

---

## Step 1 — 🤖 Install Node.js (if missing)

```bash
$SSH_CMD bash -s << 'EOF'
set -e

if command -v node >/dev/null 2>&1; then
  NODE_MAJOR=$(node --version | grep -oP '(?<=v)\d+')
  if [ "$NODE_MAJOR" -ge 20 ]; then
    echo "OK: Node.js $(node --version) already installed"
    exit 0
  fi
fi

if command -v sudo >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - 2>&1 | tail -3
  sudo apt-get install -y nodejs 2>&1 | tail -3
else
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | tail -3
  apt-get install -y nodejs 2>&1 | tail -3
fi

echo "INSTALLED: Node.js $(node --version)"
EOF
```

## Step 2 — 🤖 Install Claude Code, tmux, Bun

```bash
$SSH_CMD bash -s << 'EOF'
set -e

if ! command -v claude >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    sudo npm install -g @anthropic-ai/claude-code 2>&1 | tail -1
  else
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -1
  fi
fi
echo "CLAUDE: $(claude --version)"

if ! command -v tmux >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq tmux >/dev/null 2>&1
  else
    apt-get update -qq && apt-get install -y -qq tmux >/dev/null 2>&1
  fi
fi
echo "TMUX: $(tmux -V)"

if [ ! -f "$HOME/.bun/bin/bun" ]; then
  curl -fsSL https://bun.sh/install | bash 2>&1 | tail -1
fi
echo "BUN: $($HOME/.bun/bin/bun --version)"
EOF
```

## Step 3 — 🤖 Patch ~/.claude.json (MERGE, never overwrite)

> **Backported from macOS** — previously this step used `cat > ~/.claude.json << CJSON` which wiped any existing keys (e.g. `projects`, `oauthAccount`, `tipsHistory`). Even on headless Linux servers, this matters in dual-track deployments where OpenClaw has written its own state. See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §5.

```bash
$SSH_CMD bash -s << ENDAUTH
set -e

python3 << 'PY'
import json, os
p = os.path.expanduser('~/.claude.json')
d = json.load(open(p)) if os.path.exists(p) else {}
d['hasCompletedOnboarding'] = True
d['hasAcknowledgedCostThreshold'] = True
json.dump(d, open(p, 'w'), indent=2)
print(f"OK: patched {p}, preserved {len(d)} keys")
PY

# Verify auth
RESULT=\$(CLAUDE_CODE_OAUTH_TOKEN='${CLAUDE_TOKEN}' claude auth status 2>&1)
echo "\$RESULT"
echo "\$RESULT" | grep -q '"loggedIn": true' || { echo "FATAL: Auth failed. Regenerate with: claude setup-token"; exit 1; }
echo "OK: Auth verified"
ENDAUTH
```

## Step 4 — 🤖 Write ~/.claude/settings.json (MERGE into existing)

> **Backported from macOS** — previously used `cat > ... << SETTINGS` overwrite. Now preserves existing `permissions.allow` additions, `mcpServers`, custom `hooks`. See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §5.

```bash
$SSH_CMD bash -s << 'EOF'
set -e
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
EOF
```

> `channelsEnabled: true` is mandatory; `permissions.defaultMode: "bypassPermissions"` is the only setting that actually silences permission prompts. See [`../references/architecture-and-design.md`](../references/architecture-and-design.md).

## Step 5 — 🤖 Install Telegram plugin (+ explicit local-scope enable for CC 2.1.149+)

> **Critical 2.1.149+ behavior change** (discovered on Windows 2026-05-26, applies to all platforms): Claude Code 2.1.149 stopped honoring `enabledPlugins.<name>: true` in user-scope `~/.claude/settings.json` when deciding whether to auto-load a plugin for `--channels`. The flag is now only read from **local-scope** `<cwd>/.claude/settings.local.json`. Symptom: daemon starts, `claude plugin list` shows `× disabled` despite settings.json having `true`, claude never spawns bun, Telegram silently goes dark. The explicit `plugin enable` line below writes local-scope settings at `$HOME/.claude/settings.local.json` (since the daemon's start-claude.sh runs `cd ~` before invoking claude). See [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §12.

```bash
$SSH_CMD bash -s << ENDPLUGIN
set -e
export CLAUDE_CODE_OAUTH_TOKEN='${CLAUDE_TOKEN}'
export PATH="\$HOME/.bun/bin:\$PATH"

# The plugin enable below writes <cwd>/.claude/settings.local.json. The daemon's
# start-claude.sh runs `cd ~` first, so we enable from \$HOME here to match.
cd "\$HOME"
mkdir -p "\$HOME/.claude"

claude plugin marketplace add anthropics/claude-plugins-official 2>&1 || true
claude plugin marketplace update claude-plugins-official 2>&1 | tail -1

claude plugin uninstall telegram@claude-plugins-official 2>/dev/null || true
claude plugin install telegram@claude-plugins-official 2>&1 | tail -1

# CRITICAL: explicit enable. 2.1.149+ ignores user-scope enabledPlugins for --channels.
# This writes \$HOME/.claude/settings.local.json which the daemon (cd ~) reads.
claude plugin enable telegram@claude-plugins-official 2>&1 | tail -2

# Verify
claude plugin list 2>&1 | grep -q 'telegram.*enabled' \\
  || { echo "FATAL: Plugin not enabled. Output:"; claude plugin list 2>&1; exit 1; }
test -f "\$HOME/.claude/settings.local.json" \\
  || { echo "FATAL: settings.local.json missing — 'plugin enable' did not write to expected location"; exit 1; }
echo "OK: telegram plugin installed AND enabled (local scope at \$HOME)"
ENDPLUGIN
```

> **NEVER use `--plugin-dir` with `--channels`** — see [`../references/architecture-and-design.md`](../references/architecture-and-design.md) §"The two channelsEnabled modes".
>
> **If you change `start-claude.sh`'s `cd ~` to a different cwd**, re-run this step from that cwd — `settings.local.json` is per-directory.
>
> **Linux scope on older CC** (pre-2.1.149): user scope worked. Linux servers typically don't run a desktop Claude.app so contention wasn't an issue. With 2.1.149+'s explicit local-scope requirement, this is now an aligned, hardened deploy regardless of CC version.

## Step 5b — 🤖 Patch plugin server.ts (GNU sed)

```bash
$SSH_CMD bash -s << 'EOF'
set -e
F=$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
if [ ! -f "$F" ]; then
  echo "FATAL: telegram plugin server.ts not found at $F"; exit 1
fi
[ ! -f "$F.bak" ] && cp "$F" "$F.bak"
# GNU sed: no backup suffix required (unlike BSD sed)
sed -i "s|'claude/channel/permission': {},|// 'claude/channel/permission': {}, // DISABLED: relays tool prompts to TG despite --dangerously-skip-permissions|" "$F"
grep -q "^ *// 'claude/channel/permission'" "$F" \
  && echo "OK: channel permission relay disabled" \
  || { echo "WARNING: patch did not apply — plugin may have changed upstream."; exit 1; }
EOF
```

> Re-apply after plugin updates. See [`../references/architecture-and-design.md`](../references/architecture-and-design.md) §"The server.ts patch".

## Step 6 — 🤖 Configure bot token

```bash
$SSH_CMD bash -s << ENDBOT
set -e
mkdir -p ~/.claude/channels/telegram
echo "TELEGRAM_BOT_TOKEN=${BOT_TOKEN}" > ~/.claude/channels/telegram/.env
chmod 600 ~/.claude/channels/telegram/.env
echo "OK: bot token configured"
ENDBOT
```

## Step 7 — 🤖 Create startup script + systemd service

```bash
$SSH_CMD bash -s << ENDSETUP
set -e

# --- Launcher with auto-restart loop ---
cat > ~/start-claude.sh << 'STARTEOF'
#!/bin/bash
export CLAUDE_CODE_OAUTH_TOKEN='${CLAUDE_TOKEN}'
export TELEGRAM_BOT_TOKEN='${BOT_TOKEN}'
export PATH="\$HOME/.bun/bin:\$PATH"
# Source NVM if installed (non-interactive shells don't load it by default)
[ -s "\$HOME/.nvm/nvm.sh" ] && \. "\$HOME/.nvm/nvm.sh"
cd ~
while true; do
    claude --dangerously-skip-permissions \
      --channels plugin:telegram@claude-plugins-official
    echo "Claude exited. Restarting in 3s..."
    sleep 3
done
STARTEOF
chmod 700 ~/start-claude.sh

# --- systemd user service ---
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/claude-telegram.service << SVCEOF
[Unit]
Description=Claude Code with Telegram Channel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/tmux new-session -d -s claude %h/start-claude.sh
ExecStop=/usr/bin/tmux kill-session -t claude
RemainAfterExit=yes
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF

# Enable lingering — allows user services without active login
sudo loginctl enable-linger \$(whoami) 2>/dev/null || loginctl enable-linger \$(whoami) 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable claude-telegram.service

echo "OK: startup script + systemd service created"
echo "    Service will auto-start on reboot"
ENDSETUP
```

> See [`../references/process-supervisors.md`](../references/process-supervisors.md) §Linux for why `RemainAfterExit=yes` + `Restart=on-failure` is the canonical pattern.

## Step 7b — 🤖 systemd path-unit for inbox mover

```bash
$SSH_CMD bash -s << 'EOF'
set -e

mkdir -p ~/telegram-inbox ~/.config/systemd/user

cat > ~/.config/systemd/user/tg-inbox-mover.path << 'PATHEOF'
[Unit]
Description=Watch Telegram channel inbox for new files

[Path]
PathChanged=%h/.claude/channels/telegram/inbox
Unit=tg-inbox-mover.service

[Install]
WantedBy=default.target
PATHEOF

cat > ~/.config/systemd/user/tg-inbox-mover.service << 'SVCEOF'
[Unit]
Description=Move Telegram uploads out of ~/.claude/ to avoid sensitive-file guard

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'mkdir -p %h/telegram-inbox && find %h/.claude/channels/telegram/inbox -maxdepth 1 -type f -exec mv -t %h/telegram-inbox/ {} +'
SVCEOF

# Drain any history files
mv ~/.claude/channels/telegram/inbox/* ~/telegram-inbox/ 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now tg-inbox-mover.path

echo "OK: tg-inbox-mover.path active. Files will land in ~/telegram-inbox/"
EOF
```

> See [`../references/architecture-and-design.md`](../references/architecture-and-design.md) §"Inbox mover" for why this exists.

## Step 7c — 🤖 Install bypass-claude-folder hook (additive)

> **Updated 2026-05-04 to use substring matching** instead of `$HOME`-anchored prefix. Catches project-nested `.claude/` dirs. See git commit `1273e2e` and [`../references/architecture-and-design.md`](../references/architecture-and-design.md) §"Permission-bypass hook".

```bash
$SSH_CMD bash -s << 'EOF'
set -e

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
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "permissionDecisionReason": "auto-allow sensitive path via bypass-claude-folder hook (substring match)"}}))
elif event == "PermissionRequest":
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {"behavior": "allow"}}}))
PY
HOOKEOF
chmod +x ~/bypass-claude-folder.sh

# Additively register in settings.json — don't clobber existing hooks
python3 << 'PYEOF'
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
json.dump(d, open(p, "w"), indent=4)
print("OK: bypass hook registered additively")
PYEOF
EOF
```

## Step 7d — 🤖 Install Telegram routing hook

```bash
$SSH_CMD bash -s << 'EOF'
set -e

cat > ~/telegram-routing-hook.sh << 'HOOKEOF'
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
HOOKEOF
chmod +x ~/telegram-routing-hook.sh

python3 << 'PYEOF'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p))
hooks = d.setdefault("hooks", {})

existing = hooks.get("UserPromptSubmit", [])
cmd = os.path.expanduser("~/telegram-routing-hook.sh")
if not any(cmd in str(h) for h in existing):
    existing.append({"matcher": "", "hooks": [{"type": "command", "command": cmd}]})
    hooks["UserPromptSubmit"] = existing
json.dump(d, open(p, "w"), indent=4)
print("OK: routing hook registered additively")
PYEOF
EOF
```

> Known limitation: channel-routed messages may bypass `UserPromptSubmit` — see [`../references/post-deploy-hardening.md`](../references/post-deploy-hardening.md) §6.

## Step 8 — 🤖 Launch and dismiss first-launch dialogs (tmux automation)

```bash
$SSH_CMD bash -s << 'EOF'
set -e

# Kill zombies that could 409
tmux kill-session -t claude 2>/dev/null || true
sleep 1
pkill -f 'claude --dangerously' 2>/dev/null || true
pkill -f 'bun.*server.ts' 2>/dev/null || true
sleep 2

tmux new-session -d -s claude ~/start-claude.sh
sleep 12

# Dialog 1: "Trust this folder?" — Enter accepts default
tmux send-keys -t claude Enter
sleep 4

# Dialog 2: "Bypass permissions?" — Down arrow + Enter
OUTPUT=$(tmux capture-pane -t claude -p 2>&1)
if echo "$OUTPUT" | grep -q "Yes, I accept"; then
  tmux send-keys -t claude Down
  sleep 0.5
  tmux send-keys -t claude Enter
  sleep 12
fi

for i in 1 2 3; do
  OUTPUT=$(tmux capture-pane -t claude -p 2>&1)
  if echo "$OUTPUT" | grep -q "Listening for channel messages"; then
    echo "SUCCESS: Claude Code is running and listening for Telegram messages"
    exit 0
  fi
  sleep 5
done

echo "WARNING: Could not confirm 'Listening' state. Last pane content:"
tmux capture-pane -t claude -p 2>&1 | tail -15
echo "See ../references/troubleshooting.md"
exit 1
EOF
```

## Step 9 — 🤖 Start systemd service for reboot persistence

```bash
$SSH_CMD bash -s << 'EOF'
systemctl --user start claude-telegram.service 2>/dev/null || true
echo "OK: systemd service active — auto-starts on reboot"
EOF
```

## Step 10 — 🤖 Install both CLAUDE.md rule blocks

> **Backported from Mac**: previously this step (formerly Step 9b) only installed the channel-routing rule. Now also installs the no-interactive-select rule — a Mac production lesson (1 h 15 min outage from `AskUserQuestion` deadlock) that applies equally on Linux. See [`../references/claude-md-rules.md`](../references/claude-md-rules.md).

```bash
$SSH_CMD bash -s << 'EOF'
set -e

install_block() {
  local F=$1
  local MARKER=$2
  shift 2
  local BLOCK="$*"
  mkdir -p "$(dirname "$F")"
  touch "$F"
  if grep -q "$MARKER" "$F"; then
    echo "  Already present: $F ($MARKER)"
    return
  fi
  echo "$BLOCK" >> "$F"
  echo "  Appended: $F ($MARKER)"
}

RULE_CHANNEL=$(cat << 'EOFRULE'

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

### Telegram file uploads (Linux / systemd path-unit)

User-uploaded files are auto-moved by `tg-inbox-mover.path` from
`~/.claude/channels/telegram/inbox/` to `~/telegram-inbox/`. Always read from
`~/telegram-inbox/`. Never touch paths under `~/.claude/channels/` —
CC's hardcoded sensitive-file guard will freeze your session.
<!-- END: channel-routing-rule -->
EOFRULE
)

RULE_NOSELECT=$(cat << 'EOFRULE2'

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
EOFRULE2
)

install_block ~/CLAUDE.md '<!-- BEGIN: channel-routing-rule -->' "$RULE_CHANNEL"
install_block ~/.claude/CLAUDE.md '<!-- BEGIN: channel-routing-rule -->' "$RULE_CHANNEL"
install_block ~/CLAUDE.md '<!-- BEGIN: no-interactive-select-rule -->' "$RULE_NOSELECT"
install_block ~/.claude/CLAUDE.md '<!-- BEGIN: no-interactive-select-rule -->' "$RULE_NOSELECT"

# Restart so CLAUDE.md reloads
tmux kill-session -t claude 2>/dev/null || true
sleep 2
tmux new-session -d -s claude ~/start-claude.sh
sleep 12

tmux send-keys -t claude Enter
sleep 4
OUTPUT=$(tmux capture-pane -t claude -p 2>&1)
if echo "$OUTPUT" | grep -q "Yes, I accept"; then
  tmux send-keys -t claude Down
  sleep 0.5
  tmux send-keys -t claude Enter
  sleep 12
fi

for i in 1 2 3 4; do
  OUTPUT=$(tmux capture-pane -t claude -p 2>&1)
  if echo "$OUTPUT" | grep -q "Listening for channel messages"; then
    echo "SUCCESS: Claude reloaded with both rules active"
    exit 0
  fi
  sleep 5
done
echo "WARNING: post-restart listening state not confirmed."
tmux capture-pane -t claude -p 2>&1 | tail -15
exit 1
EOF
```

## Step 11 — 👤 Telegram pairing

```bash
# After the human gets a 6-character pairing code from the bot:
$SSH_CMD bash -s << ENDPAIR
tmux send-keys -t claude '/telegram:access pair ${PAIR_CODE}' Enter
sleep 8
tmux send-keys -t claude Enter
sleep 3
tmux send-keys -t claude '/telegram:access policy allowlist' Enter
sleep 5
tmux send-keys -t claude Enter
sleep 3
echo "OK: Paired and secured"
ENDPAIR
```

Then ask the human to send a test message from Telegram. Confirm a reply comes back.

> Full pairing details in [`../references/pairing-and-access.md`](../references/pairing-and-access.md).

## File manifest

| Path | Purpose | Perms |
|---|---|---|
| `~/.claude.json` | Onboarding bypass (MERGED) | 644 |
| `~/.claude/settings.json` | Permissions + channelsEnabled + hooks (MERGED) | 644 |
| `~/.claude/channels/telegram/.env` | Bot token | 600 |
| `~/.claude/channels/telegram/access.json` | Paired users + policy (auto) | 644 |
| `~/start-claude.sh` | Launcher with auto-restart | 700 |
| `~/bypass-claude-folder.sh` | Sensitive-path bypass hook | 700 |
| `~/telegram-routing-hook.sh` | Routing reminder hook | 700 |
| `~/.config/systemd/user/claude-telegram.service` | Daemon supervisor | 644 |
| `~/.config/systemd/user/tg-inbox-mover.path` | inotify watcher unit | 644 |
| `~/.config/systemd/user/tg-inbox-mover.service` | mover service | 644 |
| `~/CLAUDE.md` + `~/.claude/CLAUDE.md` | Both rule blocks installed | 644 |
| `~/telegram-inbox/` | Safe destination for uploads | 755 |

## Compatibility

- **Tested distros**: Ubuntu 22.04, Ubuntu 24.04, Debian 12
- **Other distros**: should work; package commands (`apt-get`) need substitution for `dnf` / `pacman` / etc. Skill currently assumes `apt-get`.
- **Architecture**: x86_64 and arm64 both supported (Claude Code npm package has both)
- **Local self-execution mode**: supported via empty `SSH_CMD=""` — used by `migrate-openclaw` when OpenClaw migrates to Claude Code in place
