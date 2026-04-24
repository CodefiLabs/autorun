#!/usr/bin/env bash
# Remove an orchestration entry from <worktree-root>/.orchestration.json.
# Usage: unregister-orchestration.sh <worktree-root> <session-name>
#
# If the file has no more entries after removal, deletes the file.
# No-op if the file doesn't exist.
set -euo pipefail

WORKTREE_ROOT="${1:?Usage: unregister-orchestration.sh <worktree-root> <session-name>}"
SESSION_NAME="${2:?Missing session name}"

ORCH_FILE="$WORKTREE_ROOT/.orchestration.json"
[[ -f "$ORCH_FILE" ]] || exit 0

LOCK_DIR="${ORCH_FILE}.lock"
while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 0.1; done
trap "rmdir '$LOCK_DIR' 2>/dev/null" EXIT

python3 - "$ORCH_FILE" "$SESSION_NAME" << 'PYEOF'
import json, os, sys

orch_file, session = sys.argv[1], sys.argv[2]

try:
    with open(orch_file) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError):
    # Corrupt or unreadable — just remove it
    try: os.remove(orch_file)
    except OSError: pass
    sys.exit(0)

# v1 compat: single flat object
if "orchestrations" not in data:
    if data.get("session_name") == session:
        os.remove(orch_file)
    sys.exit(0)

# v2: remove this entry
data.get("orchestrations", {}).pop(session, None)

if not data.get("orchestrations"):
    os.remove(orch_file)
else:
    tmp = orch_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.rename(tmp, orch_file)
PYEOF

rmdir "$LOCK_DIR" 2>/dev/null
trap - EXIT
