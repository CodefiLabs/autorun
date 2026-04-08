#!/usr/bin/env bash
set -euo pipefail

# update-phase-status.sh - Update phase timestamps in status.json
#
# Usage: update-phase-status.sh <status-file> <stage-number> <phase-name> <field> [value]
#
# Fields: started_at, completed_at, current_phase, total_phases
# If value is omitted for timestamp fields, uses current UTC timestamp.
#
# Examples:
#   update-phase-status.sh /path/to/status.json 1 research started_at
#   update-phase-status.sh /path/to/status.json 1 research completed_at
#   update-phase-status.sh /path/to/status.json 1 implement current_phase 3
#   update-phase-status.sh /path/to/status.json 1 implement total_phases 5

STATUS_FILE="${1:?Usage: update-phase-status.sh <status-file> <stage-number> <phase-name> <field> [value]}"
STAGE_NUMBER="${2:?Missing stage number}"
PHASE_NAME="${3:?Missing phase name (setup|research|create_plan|implement|merge)}"
FIELD="${4:?Missing field (started_at|completed_at|current_phase|total_phases)}"
VALUE="${5:-}"

# Auto-generate timestamp for timestamp fields if value not provided
if [[ -z "$VALUE" && ("$FIELD" == "started_at" || "$FIELD" == "completed_at") ]]; then
  VALUE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

if [[ -z "$VALUE" ]]; then
  echo "ERROR: value required for field '$FIELD'" >&2
  exit 1
fi

# Lock, update, unlock
LOCK_DIR="${STATUS_FILE}.lock"
while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 0.1; done
trap "rmdir '$LOCK_DIR' 2>/dev/null" EXIT

python3 -c "
import json, sys

with open('$STATUS_FILE') as f:
    data = json.load(f)

stage = data['stages'].get('$STAGE_NUMBER', {})
if 'phases' not in stage:
    stage['phases'] = {}
if '$PHASE_NAME' not in stage['phases']:
    stage['phases']['$PHASE_NAME'] = {'started_at': None, 'completed_at': None}

# Set the field
try:
    val = int('$VALUE')
except ValueError:
    val = '$VALUE'

stage['phases']['$PHASE_NAME']['$FIELD'] = val
data['stages']['$STAGE_NUMBER'] = stage

with open('$STATUS_FILE', 'w') as f:
    json.dump(data, f, indent=2)
"

rmdir "$LOCK_DIR" 2>/dev/null
trap - EXIT
