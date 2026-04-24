#!/usr/bin/env bash
# Register or update an orchestration entry in <cwd>/.orchestration.json.
# Usage: register-orchestration.sh <session-name> <stage-number> <orchestration-dir> <chain-on-complete>
#
# Atomically upserts the entry keyed by <session-name>. Auto-migrates v1 (flat object) to v2 on first run.
set -euo pipefail

SESSION_NAME="${1:?Usage: register-orchestration.sh <session> <stage> <orch-dir> <chain>}"
STAGE_NUM="${2:?Missing stage number}"
ORCH_DIR="${3:?Missing orchestration dir}"
CHAIN_ON_COMPLETE="${4:-}"

ORCH_FILE="$(pwd)/.orchestration.json"
LOCK_DIR="${ORCH_FILE}.lock"

# Atomic lock (same pattern as update-phase-status.sh)
while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 0.1; done
trap "rmdir '$LOCK_DIR' 2>/dev/null" EXIT

python3 - "$ORCH_FILE" "$SESSION_NAME" "$STAGE_NUM" "$ORCH_DIR" "$CHAIN_ON_COMPLETE" << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone

orch_file, session, stage_num, orch_dir, chain = sys.argv[1:6]

data = {}
if os.path.isfile(orch_file):
    try:
        with open(orch_file) as f:
            data = json.load(f)
    except json.JSONDecodeError:
        data = {}

# Migrate v1 → v2 (flat object with session_name → orchestrations dict)
if "orchestrations" not in data:
    if isinstance(data, dict) and "session_name" in data:
        data = {"version": 2, "orchestrations": {data["session_name"]: data}}
    else:
        data = {"version": 2, "orchestrations": {}}

data["version"] = 2
# Upsert: if a v1 migration produced an entry with the same session key, it is
# overwritten here with fresh values. This is intentional (re-running a stage
# re-registers it) — not a collision error.
data["orchestrations"][session] = {
    "stage_number": stage_num,
    "orchestration_dir": orch_dir,
    "session_name": session,
    "chain_on_complete": chain,
    "registered_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}

tmp = orch_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.rename(tmp, orch_file)
PYEOF

rmdir "$LOCK_DIR" 2>/dev/null
trap - EXIT
