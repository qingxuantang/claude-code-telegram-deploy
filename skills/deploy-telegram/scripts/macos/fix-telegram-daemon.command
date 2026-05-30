#!/bin/bash
# fix-telegram-daemon.command
# Double-click to repair the Claude Code <-> Telegram pipeline on macOS.
# Idempotent — safe to run even when everything is already healthy.
#
# What this script handles (5 scenarios):
#   1. Multiple `bun server.ts` processes (token contention) — kill the
#      ones whose process tree does NOT trace back to the daemon's claude.
#   2. bun is gone but claude is alive — kill claude so the
#      `start-claude.sh` tmux loop respawns the whole chain fresh.
#   3. claude is gone but the `claude` tmux session is still up — wait
#      up to 60 s for auto-restart; only inject a manual `start-claude.sh`
#      call if the tmux pane is idle after the wait.
#   4. tmux session 'claude' is gone entirely — recreate it.
#   5. Everything is already healthy — send one confirmation message
#      to Telegram and exit 0.
#
# Implementation notes:
#   - PID detection uses `ps aux | awk`, not `pgrep -f`. Inside a
#     subprocess sandbox (e.g. when run from within a running claude
#     session), pgrep cannot see ancestor processes; `ps aux` has no
#     such limitation.
#   - Telegram notifications go via a direct `curl` to the Bot API —
#     no MCP dependency, so they work even when the whole pipeline is
#     dead.
#   - BOT_TOKEN is read from ~/.claude/channels/telegram/.env at run
#     time, so this script is portable and ships without secrets.
#   - CHAT_ID is substituted at install time by the deploy-telegram
#     skill's platforms/macos.md install step. If the placeholder
#     `<CHAT_ID>` is still present at run time, Telegram notifications
#     are skipped (the kill/restart logic still runs).
#   - Log: ~/fix-telegram-daemon.log (append-mode).

ENV_FILE="$HOME/.claude/channels/telegram/.env"
BOT_TOKEN=""
if [ -r "$ENV_FILE" ]; then
    BOT_TOKEN=$(awk -F= '/^TELEGRAM_BOT_TOKEN=/{ sub(/^TELEGRAM_BOT_TOKEN=/, "", $0); gsub(/[[:space:]"\047]/, "", $0); print; exit }' "$ENV_FILE")
fi
CHAT_ID='<CHAT_ID>'
LOG="$HOME/fix-telegram-daemon.log"
START_SCRIPT="$HOME/start-claude.sh"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG"; }

tg() {
    # Skip notifications if token or chat_id is missing / un-substituted.
    [ -z "$BOT_TOKEN" ] && return 0
    case "$CHAT_ID" in '<CHAT_ID>'|''|'<'*'>') return 0 ;; esac
    curl -sf --max-time 8 -X POST \
        "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=$1" \
        >/dev/null 2>&1
}

# `ps aux | awk` works inside subprocess sandboxes where `pgrep -f` fails.
get_claude_pid() {
    ps aux | awk '/claude --dangerously-skip-permissions/ && !/awk/ {print $2}' | head -1
}
get_bun_pids() {
    ps aux | awk '/bun server\.ts/ && !/awk/ {print $2}'
}

echo "========================================="
echo "  Claude Telegram Daemon Fix — $(ts)"
echo "========================================="
log "=== Fix started ==="

# ── Read current state ────────────────────────────────
CLAUDE_PID=$(get_claude_pid)
BUN_PIDS=($(get_bun_pids))
BUN_COUNT=${#BUN_PIDS[@]}
TMUX_OK=$(tmux has-session -t claude 2>/dev/null && echo yes || echo no)

log "claude PID:    ${CLAUDE_PID:-none}"
log "bun PIDs:      ${BUN_PIDS[*]:-none}  (count=$BUN_COUNT)"
log "tmux 'claude': $TMUX_OK"

# ── Case 1: multiple bun (token contention) ───────────
if [ "$BUN_COUNT" -gt 1 ]; then
    log "WARN $BUN_COUNT bun processes — bot-token contention detected"
    tg "WARN Claude daemon: $BUN_COUNT bun processes contending for bot token, cleaning up..."

    # The daemon's bun should descend (one or two levels) from the
    # current claude process. Anything else is the rogue one.
    KEEP_BUN=""
    if [ -n "$CLAUDE_PID" ]; then
        for pid in "${BUN_PIDS[@]}"; do
            ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
            gppid=$(ps -o ppid= -p "$ppid" 2>/dev/null | tr -d ' ')
            if [ "$gppid" = "$CLAUDE_PID" ] || [ "$ppid" = "$CLAUDE_PID" ]; then
                KEEP_BUN="$pid"; break
            fi
        done
    fi

    for pid in "${BUN_PIDS[@]}"; do
        [ "$pid" = "$KEEP_BUN" ] && continue
        log "  killing rogue bun PID $pid"
        kill "$pid" 2>/dev/null
    done
    sleep 2

    BUN_PIDS=($(get_bun_pids))
    BUN_COUNT=${#BUN_PIDS[@]}
fi

# ── Case 2: bun is dead but claude is alive → kill claude so start-claude.sh respawns ──
if [ "$BUN_COUNT" -eq 0 ] && [ -n "$CLAUDE_PID" ]; then
    log "WARN bun missing, claude ($CLAUDE_PID) alive → killing claude to trigger respawn"
    tg "Claude daemon: bun long-poll vanished, restarting claude..."
    kill "$CLAUDE_PID" 2>/dev/null
    sleep 5

    for i in $(seq 1 8); do
        NC=$(get_claude_pid); NB=$(get_bun_pids | head -1)
        if [ -n "$NC" ] && [ -n "$NB" ]; then
            log "OK respawn complete: claude=$NC  bun=$NB"
            tg "OK Claude daemon recovered. claude=$NC"
            echo ""; echo "OK Repair complete, Telegram pipeline restored."; sleep 3; exit 0
        fi
        log "  waiting for respawn... ($i/8)"
        sleep 5
    done

    log "FAIL respawn timed out"
    tg "FAIL Claude daemon respawn timed out — run: tmux attach -t claude"
    echo ""; echo "FAIL respawn timeout — inspect manually."; sleep 5; exit 1

# ── Case 3: claude died, tmux still up ───────────────
elif [ -z "$CLAUDE_PID" ] && [ "$TMUX_OK" = "yes" ]; then
    log "WARN claude not running, tmux up → waiting up to 60 s for auto-restart"
    tg "WARN Claude daemon process gone, waiting for auto-restart..."

    for i in $(seq 1 12); do
        NC=$(get_claude_pid)
        if [ -n "$NC" ]; then
            sleep 4; NB=$(get_bun_pids | head -1)
            log "OK claude auto-restarted: claude=$NC  bun=${NB:-spawning}"
            tg "OK Claude daemon auto-recovered. claude=$NC"
            echo ""; echo "OK claude auto-restarted, pipeline restored."; sleep 3; exit 0
        fi
        log "  waiting... ($i/12)"
        sleep 5
    done

    # 60 s passed and claude still hasn't come back — only inject a manual
    # `start-claude.sh` call if the tmux pane is idle (no bash/sh running).
    log "auto-restart timed out; checking tmux pane state"
    PANE_CMD=$(tmux display-message -t claude -p '#{pane_current_command}' 2>/dev/null)
    log "  tmux pane current command: ${PANE_CMD:-unknown}"

    if [ "$PANE_CMD" != "bash" ] && [ "$PANE_CMD" != "sh" ]; then
        log "  pane idle, injecting start-claude.sh"
        tmux send-keys -t claude "exec bash $START_SCRIPT" Enter
        sleep 10
        NC=$(get_claude_pid)
        if [ -n "$NC" ]; then
            tg "OK Claude daemon recovered after manual inject. claude=$NC"
            echo ""; echo "OK Repair complete."; sleep 3; exit 0
        fi
    else
        log "  start-claude.sh still running, continuing to wait"
    fi

    tg "FAIL Claude daemon could not auto-recover — run: tmux attach -t claude"
    echo ""; echo "FAIL inspect manually: tmux attach -t claude"; sleep 5; exit 1

# ── Case 4: tmux session is gone ──────────────────────
elif [ "$TMUX_OK" = "no" ]; then
    log "WARN tmux session 'claude' missing — recreating"
    tg "WARN Claude daemon: tmux session gone, recreating..."
    export PATH="$HOME/.bun/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:$PATH"
    tmux new-session -d -s claude "$START_SCRIPT"
    sleep 12

    NC=$(get_claude_pid)
    if [ -n "$NC" ]; then
        log "OK tmux recreated, claude=$NC"
        tg "OK Claude daemon: tmux session recreated. claude=$NC"
        echo ""; echo "OK Recreation complete."; sleep 3; exit 0
    else
        tg "FAIL Claude daemon: tmux recreated but claude did not start — check $START_SCRIPT"
        echo ""; echo "FAIL inspect manually: $START_SCRIPT"; sleep 5; exit 1
    fi

# ── Case 5: everything healthy ────────────────────────
else
    log "OK system healthy: claude=$CLAUDE_PID  bun=${BUN_PIDS[0]}"
    echo ""
    echo "OK Claude daemon and Telegram pipeline are healthy — no repair needed."
    echo "   claude PID : $CLAUDE_PID"
    echo "   bun PID    : ${BUN_PIDS[0]}"
    echo ""
    tg "OK Claude daemon healthy (claude=$CLAUDE_PID, bun=${BUN_PIDS[0]}). No repair needed."
    sleep 3; exit 0
fi
