#!/usr/bin/env bash
# Prints orchestration context for the current tmux session.
# Usage: get-orchestration-context.sh <worktree-root>
#
# Exit 0 → printed STAGE_NUM=, ORCH_DIR=, STATUS_FILE=, SESSION_NAME=, CHAIN_ON_COMPLETE= on stdout,
#          with values shlex-quoted so they're safe to consume with `eval`.
# Exit 1 → no active orchestration context for this session (no file, no entry, or stale entry).
#
# Staleness is detected silently (no deletions, no messages on stderr for common "not orchestrated" cases).
# The file is never modified by this script.
#
# Session lookup order: $AUTORUN_SESSION_OVERRIDE (for testing), then `tmux display-message -p '#S'`.
set -euo pipefail

WORKTREE_ROOT="${1:?Usage: get-orchestration-context.sh <worktree-root>}"
ORCH_FILE="$WORKTREE_ROOT/.orchestration.json"

[[ -f "$ORCH_FILE" ]] || exit 1

SESSION_NAME="${AUTORUN_SESSION_OVERRIDE:-$(tmux display-message -p '#S' 2>/dev/null || echo '')}"
[[ -n "$SESSION_NAME" ]] || exit 1

python3 - "$ORCH_FILE" "$SESSION_NAME" << 'PYEOF'
import json, os, shlex, sys

orch_file, session = sys.argv[1], sys.argv[2]

try:
    with open(orch_file) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(1)

# v1 schema compat: single flat object → treat as one entry keyed by its own session_name
if "orchestrations" not in data:
    if data.get("session_name") == session:
        entry = data
    else:
        sys.exit(1)
else:
    entry = data.get("orchestrations", {}).get(session)
    if not entry:
        sys.exit(1)

orch_dir = entry.get("orchestration_dir", "")
stage_num = entry.get("stage_number", "")
if not orch_dir or not os.path.isdir(orch_dir):
    sys.exit(1)

status_file = os.path.join(orch_dir, "status.json")
if not os.path.isfile(status_file):
    sys.exit(1)

try:
    with open(status_file) as f:
        status = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(1)

stage_status = status.get("stages", {}).get(str(stage_num), {}).get("status", "unknown")
if stage_status == "completed":
    sys.exit(1)

# shlex.quote makes values safe for `eval` consumers, crucial for chain_on_complete which
# contains a full slash-command string with spaces.
print(f"STAGE_NUM={shlex.quote(str(entry.get('stage_number', '')))}")
print(f"ORCH_DIR={shlex.quote(orch_dir)}")
print(f"STATUS_FILE={shlex.quote(status_file)}")
print(f"SESSION_NAME={shlex.quote(str(entry.get('session_name', '')))}")
print(f"CHAIN_ON_COMPLETE={shlex.quote(str(entry.get('chain_on_complete', '')))}")
PYEOF
