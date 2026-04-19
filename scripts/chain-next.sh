#!/usr/bin/env bash
set -euo pipefail

# chain-next.sh - Launch a claude command in a tmux window/session
#
# Usage: chain-next.sh <claude-command> [window-name] [target-session] [work-dir] [close-caller]
#
# Default: new-window in target-session (or current session if inside tmux)
# Fallback: new detached session if no target and not inside tmux
#
# Args:
#   close-caller: set to "close" to kill the calling tmux window after the new one is created
#
# Examples:
#   chain-next.sh "/autorun:create_plan ~/.autorun/research/2025-01-08-auth-flow.md" "create_plan" "stage-3"
#   chain-next.sh "/autorun:implement_plan ~/.autorun/plans/2025-01-08-auth-flow.md" "implement"
#   chain-next.sh "/autorun:start ..." "stage-1" "" "/path/to/worktree"
#   chain-next.sh "/autorun:start ..." "stage-1" "" "" "close"

CLAUDE_CMD="${1:?Usage: chain-next.sh <claude-command> [window-name] [target-session] [work-dir] [close-caller]}"
WINDOW_NAME="${2:-autorun}"
TARGET_SESSION="${3:-}"
WORK_DIR="${4:-}"
CLOSE_CALLER="${5:-}"

# Auto-detect worktree CWD when WORK_DIR not explicitly provided
if [[ -z "$WORK_DIR" ]]; then
  _git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
  _git_common=$(git rev-parse --git-common-dir 2>/dev/null || true)
  if [[ -n "$_git_dir" && -n "$_git_common" && "$_git_dir" != "$_git_common" ]]; then
    WORK_DIR=$(git rev-parse --show-toplevel)
  fi
fi

# Set up logging
LOG_DIR="${HOME}/.autorun/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/${WINDOW_NAME}-$(date +%Y%m%d-%H%M%S).log"

# Ensure tmux server is running (idempotent — no-op if already running,
# starts server if not). Prevents "no server running" errors from
# subsequent list-sessions/has-session calls.
tmux start-server 2>/dev/null || {
  echo "[chain-next] ERROR: Failed to start tmux server" >&2
  exit 1
}

# --- Build wrapper script ---
# Instead of escaping CLAUDE_CMD inline (which breaks with long strings
# containing quotes, ellipses, dashes, parens through tmux → shell → claude
# interpretation layers), write the command to a temp file and create a
# wrapper script that reads it at runtime. Zero quoting issues.

CMD_FILE=$(mktemp "${TMPDIR:-/tmp}/chain-next-XXXXXX.cmd")
printf '%s' "$CLAUDE_CMD" > "$CMD_FILE"

WRAPPER=$(mktemp "${TMPDIR:-/tmp}/chain-next-XXXXXX.sh")

# Part 1: Embed current environment (expanded at write time).
# tmux windows inherit the server's env, not the client's — critical vars
# like PATH and API keys would be missing without explicit forwarding.
{
  echo '#!/usr/bin/env bash'
  printf 'export PATH=%q\n' "$PATH"
  printf 'export HOME=%q\n' "$HOME"
  printf 'export SHELL=%q\n' "${SHELL:-/bin/bash}"
  printf 'export TERM=%q\n' "${TERM:-xterm-256color}"
  # Forward all CLAUDE_* and ANTHROPIC_* env vars (API keys, config, etc.)
  while IFS='=' read -r name value; do
    [[ -n "$name" ]] && printf 'export %s=%q\n' "$name" "$value"
  done < <(env | grep -E '^(CLAUDE_|ANTHROPIC_)' || true)
  # Embed file paths for runtime use
  printf 'CMD_FILE=%q\n' "$CMD_FILE"
  printf 'SELF=%q\n' "$WRAPPER"
  printf 'LOG_FILE=%q\n' "$LOG_FILE"
} > "$WRAPPER"

# Part 2: Runtime logic (quoted heredoc — no expansion at write time)
cat >> "$WRAPPER" <<'ENDSCRIPT'

log() { echo "[chain-next] $*"; echo "[chain-next] $*" >> "$LOG_FILE" 2>/dev/null; }

# Verify claude CLI is available in this environment
if ! command -v claude &>/dev/null; then
  log "ERROR: 'claude' command not found in PATH"
  log "PATH=$PATH"
  log "Install: npm install -g @anthropic-ai/claude-code"
  exec "${SHELL:-/bin/bash}"
fi

# Read command from temp file (eliminates all quoting/escaping issues)
if [[ ! -f "$CMD_FILE" ]]; then
  log "ERROR: Command file missing: $CMD_FILE"
  log "The temp file may have been cleaned up before the wrapper ran."
  exec "${SHELL:-/bin/bash}"
fi
CLAUDE_CMD=$(cat "$CMD_FILE")
rm -f "$CMD_FILE" "$SELF"

log "Starting claude at $(date)"
log "Command: ${CLAUDE_CMD:0:200}$([ ${#CLAUDE_CMD} -gt 200 ] && echo '...')"

claude --model claude-sonnet-4-6 "$CLAUDE_CMD"
EXIT_CODE=$?
log "claude exited with code $EXIT_CODE at $(date)"

# Disable remain-on-exit now that we've reached the interactive shell.
# It was set as a safety net to keep the pane visible on early crashes;
# no longer needed since the shell below keeps the pane alive.
tmux set-option -p remain-on-exit off 2>/dev/null || true

exec "${SHELL:-/bin/bash}"
ENDSCRIPT

chmod +x "$WRAPPER"

# Capture old window before creating new one
OLD_WINDOW_ID=""
if [[ "$CLOSE_CALLER" == "close" && -n "${TMUX:-}" ]]; then
  OLD_WINDOW_ID=$(tmux display-message -p '#{window_id}')
fi

# Detect if the user's terminal is inside tmux (Bash tool strips $TMUX).
# Check if the tmux server is running and has an attached client.
USER_SESSION=""
if [[ -z "${TMUX:-}" ]]; then
  # Find the most recently attached session as the best guess for the user's session
  USER_SESSION=$(tmux list-sessions -F '#{session_attached} #{session_name}' 2>/dev/null \
    | awk '$1 > 0 {print $2; exit}' || true)
fi

# Determine which session to add a window to
NEW_WINDOW_TARGET=""
if [[ -n "$TARGET_SESSION" ]] && tmux has-session -t "$TARGET_SESSION" 2>/dev/null; then
  tmux new-window -t "$TARGET_SESSION" -n "$WINDOW_NAME" \
    ${WORK_DIR:+-c "$WORK_DIR"} \
    "$WRAPPER"
  NEW_WINDOW_TARGET="${TARGET_SESSION}:${WINDOW_NAME}"
elif [[ -n "${TMUX:-}" ]]; then
  tmux new-window -n "$WINDOW_NAME" \
    ${WORK_DIR:+-c "$WORK_DIR"} \
    "$WRAPPER"
  NEW_WINDOW_TARGET="${WINDOW_NAME}"
elif [[ -n "$USER_SESSION" ]]; then
  # Claude's Bash tool doesn't set $TMUX, but the user is in tmux.
  # Create a new window in their attached session instead of a detached one.
  tmux new-window -t "$USER_SESSION" -n "$WINDOW_NAME" \
    ${WORK_DIR:+-c "$WORK_DIR"} \
    "$WRAPPER"
  NEW_WINDOW_TARGET="${USER_SESSION}:${WINDOW_NAME}"
  echo "Created window '$WINDOW_NAME' in tmux session: $USER_SESSION"
else
  # Truly not in tmux — create a detached session
  SESSION_NAME="$WINDOW_NAME"
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    SESSION_NAME="${WINDOW_NAME}-$(date +%s)"
  fi
  tmux new-session -d -s "$SESSION_NAME" -n "$WINDOW_NAME" \
    ${WORK_DIR:+-c "$WORK_DIR"} \
    "$WRAPPER"
  NEW_WINDOW_TARGET="${SESSION_NAME}:${WINDOW_NAME}"
  echo "Started tmux session: $SESSION_NAME"
  echo "Attach with: tmux attach -t $SESSION_NAME"
fi

# Post-creation setup
if [[ -n "$NEW_WINDOW_TARGET" ]]; then
  # Safety net: keep pane alive if wrapper crashes before reaching exec $SHELL.
  # The wrapper disables this once it reaches the interactive shell at the end.
  tmux set-option -t "$NEW_WINDOW_TARGET" remain-on-exit on 2>/dev/null || true

  # Capture terminal output to log via tmux pipe-pane (preserves TTY for claude's TUI)
  sleep 0.3
  tmux pipe-pane -t "$NEW_WINDOW_TARGET" -o "cat >> '${LOG_FILE}'" 2>/dev/null || true
fi

# Auto-close the calling window after the new one is created
if [[ -n "$OLD_WINDOW_ID" ]]; then
  nohup bash -c "sleep 1 && tmux kill-window -t '$OLD_WINDOW_ID' 2>/dev/null" >/dev/null 2>&1 &
fi
