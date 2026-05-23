# CLAUDE.md rules to install (universal)

Every successful deploy of this skill appends **two** rule blocks to **both** `~/CLAUDE.md` (or `%USERPROFILE%\CLAUDE.md`) and `~/.claude/CLAUDE.md`. The rules are platform-agnostic — they're plain markdown text about agent behavior, not commands.

**Why both files**: Claude Code loads two layers of CLAUDE.md — `~/.claude/CLAUDE.md` (user-level, always loaded) and `~/CLAUDE.md` (project-level, loaded based on launch cwd). On long-running sessions, the model can re-read the user-level file mid-session and that becomes the dominant authority in context. A rule installed only in the project-level file gets effectively shadowed; the silent-drop bug returns.

Both blocks are fenced with HTML markers, so the install step is **idempotent** — re-running on a server that already has the rule is a no-op, and the markers protect adjacent CLAUDE.md content from being clobbered.

---

## Rule 1: Channel Routing Rule

**Purpose**: Force Claude to use the `plugin:telegram:telegram - reply` MCP tool for Telegram replies. Without this, Claude writes a beautiful reply to the terminal that the Telegram user never sees — observed on **every** deploy that omits this rule.

```markdown

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

### Telegram file uploads

User-uploaded files (images, PDFs, xlsx, etc.) arrive at `~/telegram-inbox/`
on Linux/macOS or `%USERPROFILE%\telegram-inbox\` on Windows. **Do not** read
from `~/.claude/channels/telegram/inbox/` — that path triggers a hard-coded
sensitive-file guard that no bypass flag silences. The inbox-mover
(systemd path-unit / launchd WatchPaths / FileSystemWatcher Task) moves files
out of `~/.claude/` within ~50 ms of landing.
<!-- END: channel-routing-rule -->
```

> **Production lesson** (2026-04 multi-server deployment): if the rule is installed only in `~/CLAUDE.md` (project-level), a session that runs for ~1 day starts to drift — the model re-reads `~/.claude/CLAUDE.md` (user-level) during introspection, finds no routing rule there, and the previously-loaded project rule loses dominance. Telegram replies stop going through the reply tool. **Always install in both files**.

> **Cannot fully prevent silent-drop via this rule alone** — after many `compact` operations the model may still forget. The `UserPromptSubmit` hook (see [`architecture-and-design.md`](./architecture-and-design.md) §"Telegram routing hook") is a code-level defense for the same failure mode.

---

## Rule 2: No Interactive Selects / Numbered Pickers (HARD RULE)

**Purpose**: Prevent `AskUserQuestion` and similar widget-driven dialogs from deadlocking the session. Originally documented as a macOS post-deploy lesson (a 1 h 15 min production outage on Mac mini, 2026-05); applies to **all platforms** because the failure mode is in the channel-vs-widget interaction, not the OS.

```markdown

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
```

> **Production lesson** (2026-05-14 → 2026-05-21 hardening window, validated on a Mac mini): a single `AskUserQuestion` widget invocation locked the entire session for 1 h 15 min. MCP stdio reached its idle timeout. The reply tool's response queue silently filled and was dropped. Only `pkill claude` recovered, at the cost of losing session context. The rule promotes the behavior from "best practice" to "deterministic do-not-do".

---

## Rule 3: macOS FDA Self-Check on Session Start (macOS-only)

**Purpose**: detect missing Full Disk Access grants on `claude.exe` early, before a user request hits the silent `errno=1 EPERM` failure mode. Discovered 2026-05-22 — Anthropic ships `claude.exe` as hardened-runtime + code-signed, which causes macOS TCC to **reset the responsible-process chain** for subprocesses. Result: even when the entire launchd → wrapper → tmux → start-claude.sh chain has user-domain FDA, claude's own Bash/Read tool subshells get evaluated against `claude.exe`'s own (empty by default) TCC grants, and any file access under `~/Downloads`, `~/Documents`, `~/Desktop`, etc. fails with EPERM.

The fix is a one-time GUI grant (see [`../platforms/macos.md`](../platforms/macos.md) Step 7e + [`./post-deploy-hardening.md`](./post-deploy-hardening.md) §11). This rule provides **self-detection** so the daemon proactively warns the user via Telegram instead of failing silently mid-conversation.

**Critical design constraint**: the probe must execute via Claude's Bash tool (path: `claude.exe → spawn shell → cat`), NOT from `start-claude.sh` (path: `launchd → bash → tmux → bash → cat`, all unhardened, inherits launchd-domain FDA → false-positive trap). This is why the rule lives in CLAUDE.md (read by the model on session start) rather than in the launcher script.

```markdown

<!-- BEGIN: macos-fda-self-check-rule -->
## macOS FDA Self-Check on Session Start (macOS-only)

On every Claude Code session start (including launchd-respawns after `pkill claude`
or after `self_heal_native_binary` reinstalls), execute this self-check **exactly
once** via the Bash tool, **before processing any user message**:

```bash
cat ~/Downloads/.DS_Store >/dev/null 2>&1
echo "fda_probe_exit=$?"
```

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
```

> **Why this rule is macOS-only**: Linux has no TCC subsystem. Windows has UAC + MIC but they don't apply the same hardened-runtime responsible-process reset to npm-installed binaries. The failure mode is unique to macOS + Anthropic's hardened distribution. Installing this rule on Linux/Windows would just add noise (the probe always succeeds there). The Linux and Windows platform overlays do **not** install this rule.

> **Re-grant after CC updates**: `npm install -g @anthropic-ai/claude-code@latest` (incl. the self-heal path) replaces `claude.exe`. TCC matches by path + signing identity. As long as Anthropic ships future versions with the same TeamIdentifier (`Q6L2SF6YDW`), the grant persists. If a future update changes signing identity, the grant is lost and Step 7e must be repeated — this self-check rule catches that recurrence on the next launchd respawn.

---

## Install order

In each platform overlay's deploy step:

1. Append Rule 1 to `~/CLAUDE.md` (or `%USERPROFILE%\CLAUDE.md`)
2. Append Rule 1 to `~/.claude/CLAUDE.md`
3. Append Rule 2 to `~/CLAUDE.md`
4. Append Rule 2 to `~/.claude/CLAUDE.md`
5. **macOS only**: append Rule 3 to `~/CLAUDE.md`
6. **macOS only**: append Rule 3 to `~/.claude/CLAUDE.md`

Each append uses `grep -q '<!-- BEGIN: <marker> -->'` first to skip if already present. Order doesn't matter (rules are independent); appending all even if some were already present is safe.

After installing the rules, **restart the daemon** so it reloads CLAUDE.md. The platform overlays handle this as part of the deploy.
