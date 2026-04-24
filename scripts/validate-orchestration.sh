#!/usr/bin/env bash
# Validates .orchestration.json in WORKTREE_ROOT is still active.
# Removes the file if stale (orch dir missing, status.json missing, stage already completed).
# Exit 0 → valid active orchestration. Exit 1 → no orchestration or stale file removed.
set -euo pipefail

WORKTREE_ROOT="${1:?Usage: validate-orchestration.sh <worktree-root>}"
ORCH_FILE="$WORKTREE_ROOT/.orchestration.json"

[[ -f "$ORCH_FILE" ]] || exit 1

ORCH_DIR=$(python3 -c "import json; print(json.load(open('$ORCH_FILE'))['orchestration_dir'])" 2>/dev/null || echo "")
STAGE_NUM=$(python3 -c "import json; print(json.load(open('$ORCH_FILE'))['stage_number'])" 2>/dev/null || echo "")

if [[ -z "$ORCH_DIR" ]] || [[ ! -d "$ORCH_DIR" ]]; then
  echo "[orchestration] Removing stale .orchestration.json — orchestration dir not found: ${ORCH_DIR:-<empty>}" >&2
  rm "$ORCH_FILE"
  exit 1
fi

STATUS_FILE="$ORCH_DIR/status.json"
if [[ ! -f "$STATUS_FILE" ]]; then
  echo "[orchestration] Removing stale .orchestration.json — status.json missing" >&2
  rm "$ORCH_FILE"
  exit 1
fi

STAGE_STATUS=$(python3 -c "
import json
s = json.load(open('$STATUS_FILE'))
print(s.get('stages', {}).get(str($STAGE_NUM), {}).get('status', 'unknown'))
" 2>/dev/null || echo "unknown")

if [[ "$STAGE_STATUS" == "completed" ]]; then
  echo "[orchestration] Removing stale .orchestration.json — stage $STAGE_NUM already completed" >&2
  rm "$ORCH_FILE"
  exit 1
fi

exit 0
