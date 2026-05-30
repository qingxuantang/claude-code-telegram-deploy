# macOS recovery script

Standalone, drop-in copy of the manual fix script installed by [`../../platforms/macos.md`](../../platforms/macos.md). The deploy step installs this to `~/Desktop/` on the target Mac; the copy here exists so anyone can read / audit / `curl` it directly without running the full skill.

## What's here

| File | Installs to (target machine) | When it runs |
|---|---|---|
| `fix-telegram-daemon.command` | `~/Desktop/fix-telegram-daemon.command` | Manually, whenever the operator double-clicks it — typically after Telegram stops responding |

> macOS-only. The Windows equivalent (different mechanism — bot.pid race, not launchd/tmux failure modes) lives in [`../windows/`](../windows/).

## What `fix-telegram-daemon.command` does

Idempotent manual self-heal that diagnoses the current state and takes one of five actions:

| Detected state | Action |
|---|---|
| **Multiple `bun server.ts` processes** (token contention) | Walk each bun's parent chain; keep the one whose grand/parent is the daemon's `claude`, kill the rest |
| **`bun` is gone, `claude` is alive** | `kill` claude — `start-claude.sh`'s while-loop respawns the whole chain fresh |
| **`claude` is gone, `tmux` session is up** | Wait up to 60 s for auto-restart. Only if the pane is idle after that, inject a manual `start-claude.sh` call |
| **`tmux` session 'claude' is gone** | `tmux new-session -d -s claude ~/start-claude.sh` |
| **Everything is healthy** | Send one confirmation Telegram message, log "no repair needed", exit 0 |

Logs to `~/fix-telegram-daemon.log` (append-mode).

### Why this is safe to run defensively

- All five branches are idempotent: re-running converges to the same end state.
- The "everything healthy" branch is a no-op (one Telegram message + exit 0). Safe to double-click whenever you're unsure.
- The kill-and-respawn branches have ~15 s of daemon downtime, but Telegram queues inbound messages server-side for 24 h, so nothing is lost.

## Implementation notes (the parts that took the longest to get right)

### PID detection uses `ps aux | awk`, not `pgrep -f`

When this script is invoked from inside a running `claude` session (e.g. someone asks "fix the daemon" and Claude shells out to it), the subprocess sandbox prevents `pgrep -f` from seeing its own ancestors. `ps aux` has no such restriction and works in every context. Discovery cost: one production debug session where pgrep returned an empty PID set despite the process being visibly alive.

### Telegram notifications via direct `curl`, not MCP

The whole point of running this script is that the MCP pipeline may be broken. So notifications go to `https://api.telegram.org/bot${BOT_TOKEN}/sendMessage` directly. This means the user gets visible feedback ("repair started", "repair complete", "repair failed") even when `mcp__plugin_telegram_telegram__reply` is completely dead.

### `BOT_TOKEN` is read from `~/.claude/channels/telegram/.env` at run time

The published script ships **without secrets** — the token is loaded from the user's existing `.env` file, the same one the daemon itself reads. If the `.env` is missing or unreadable, notifications are skipped silently and the kill/restart logic still runs.

### `CHAT_ID` is substituted by the install step

The published script contains the literal placeholder `<CHAT_ID>`. The deploy-telegram skill's `platforms/macos.md` install step uses `sed` to replace it with the operator's Telegram user_id at deploy time. If the placeholder is still present at run time (someone manually copied the script without running the install step), notifications are skipped silently and the kill/restart logic still runs.

### `tmux send-keys` only fires when the pane is idle

If `claude` is dead but `tmux` is still up, the script waits up to 60 s for `start-claude.sh`'s while-loop to auto-respawn. If that times out, it checks `tmux display-message -t claude -p '#{pane_current_command}'`. **Only if the current pane command is not `bash`/`sh`** (i.e. the pane is actually idle) does it inject `exec bash $START_SCRIPT`. This prevents the script from spamming Enter into a still-running `start-claude.sh` and corrupting its state.

## When you need this script

- You sent a Telegram message from your phone and Claude didn't reply within ~30 s
- `ps aux | grep "bun server.ts"` shows zero or multiple `bun` processes
- `tmux ls` no longer shows the `claude` session
- After waking the Mac from sleep and Telegram seems unresponsive
- Anytime "just try the fix script" is easier than diagnosing manually

In any of those cases: double-click the script on the Desktop, wait ~30 s, send a Telegram message again. If it still doesn't reply, check `~/fix-telegram-daemon.log` for the last run's output and consult [`../../references/troubleshooting.md`](../../references/troubleshooting.md).

## Quick install (if you want to skip the rest of the skill and just get the recovery script)

From a Terminal on the target Mac:

```bash
# Substitute <REPO> with the path to your local clone, OR curl from GitHub raw:
REPO="<path-to-claude-code-telegram-deploy-clone>/skills/deploy-telegram/scripts/macos"
cp "$REPO/fix-telegram-daemon.command" "$HOME/Desktop/fix-telegram-daemon.command"
chmod +x "$HOME/Desktop/fix-telegram-daemon.command"

# Replace <CHAT_ID> with your Telegram user_id so the script can notify you.
sed -i.bak "s|<CHAT_ID>|YOUR_TELEGRAM_USER_ID_HERE|" "$HOME/Desktop/fix-telegram-daemon.command"
rm "$HOME/Desktop/fix-telegram-daemon.command.bak"
```

(BOT_TOKEN does not need substitution — the script reads it from `~/.claude/channels/telegram/.env` at run time.)

## What this script does NOT do

- It does NOT fix the underlying race or restart cause — it just brings the daemon back to a known-good state. Root-cause docs live in [`../../references/post-deploy-hardening.md`](../../references/post-deploy-hardening.md).
- It does NOT migrate any state. Just kills + restarts processes.
- It does NOT touch `settings.json`, `.env`, or any plugin files. Safe to run with any in-flight skill or config.
- It does NOT auto-fire on reboot. macOS launchd will respawn the daemon's main supervisor (`com.openclaw.claude-telegram.plist`) on its own. This script is purely a manual safety net for when something gets stuck mid-recovery.

## License

Same as the parent repo. See [`../../../../LICENSE`](../../../../LICENSE).
