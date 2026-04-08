#!/usr/bin/env bash
set -euo pipefail

# check-orchestration-progress.sh - Monitor orchestration stage progress
#
# Usage: check-orchestration-progress.sh [status-file] [interval-minutes]
#
# Checks tmux windows for stage activity and reads status.json every N minutes.
# Defaults: status file from most recent orchestration, 20 minute interval.

STATUS_FILE="${1:-}"
INTERVAL="${2:-20}"
INTERVAL_SECS=$((INTERVAL * 60))

# Auto-detect status file if not provided
if [[ -z "$STATUS_FILE" ]]; then
  ORCH_BASE="$HOME/.autorun/orchestration"
  if [[ -d "$ORCH_BASE" ]]; then
    # Find most recently modified status.json
    STATUS_FILE=$(find "$ORCH_BASE" -name "status.json" -maxdepth 2 -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
  fi
  if [[ -z "$STATUS_FILE" ]]; then
    echo "ERROR: No status.json found. Pass path as first argument."
    exit 1
  fi
fi

echo "=== Orchestration Progress Monitor ==="
echo "Status file: $STATUS_FILE"
echo "Check interval: every ${INTERVAL} minutes"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Press Ctrl+C to stop"
echo ""

check_progress() {
  local now
  now=$(date '+%Y-%m-%d %H:%M:%S')
  echo "========================================"
  echo "Progress check: $now"
  echo "========================================"
  echo ""

  # Read status.json
  if [[ ! -f "$STATUS_FILE" ]]; then
    echo "WARNING: Status file not found: $STATUS_FILE"
    return
  fi

  local plan_name
  plan_name=$(python3 -c "import json; d=json.load(open('$STATUS_FILE')); print(d.get('plan_name','unknown'))" 2>/dev/null || echo "unknown")
  echo "Plan: $plan_name"
  echo ""

  # Count statuses
  local pending=0 in_progress=0 completed=0 failed=0
  local stages
  stages=$(python3 -c "
import json
d = json.load(open('$STATUS_FILE'))
for num, s in sorted(d['stages'].items(), key=lambda x: int(x[0])):
    print(f\"{num}|{s['status']}|{s['name']}|{s.get('branch','')}|{s.get('started_at','')}\")
" 2>/dev/null)

  printf "%-7s %-12s %-30s %-35s %s\n" "Stage" "Status" "Name" "Branch" "Started"
  printf "%-7s %-12s %-30s %-35s %s\n" "-----" "----------" "----------------------------" "---------------------------------" "-------------------"

  while IFS='|' read -r num status name branch started; do
    local icon
    case "$status" in
      pending)     icon="[ ]"; ((pending++)) ;;
      in_progress) icon="[~]"; ((in_progress++)) ;;
      completed)   icon="[x]"; ((completed++)) ;;
      failed)      icon="[!]"; ((failed++)) ;;
      *)           icon="[?]" ;;
    esac
    printf "%-7s %-12s %-30s %-35s %s\n" "$num" "$icon $status" "$name" "$branch" "$started"
  done <<< "$stages"

  local total=$((pending + in_progress + completed + failed))
  echo ""
  echo "Summary: $completed/$total completed | $in_progress in progress | $pending pending | $failed failed"
  echo ""

  # Check tmux windows
  echo "Active tmux windows:"
  if tmux list-windows -F '  #{window_name} (#{pane_current_command})' 2>/dev/null | grep -i stage; then
    :
  else
    echo "  (none found)"
  fi
  echo ""

  # Check for recent git activity on stage branches
  echo "Recent commits on stage branches (last 2h):"
  local project_root
  project_root=$(python3 -c "import json; print(json.load(open('$STATUS_FILE'))['project_root'])" 2>/dev/null || echo ".")
  local found_commits=false
  for branch in $(git -C "$project_root" branch --list 'stage-*' 2>/dev/null | sed 's/^[* ]*//' ); do
    local last_commit
    last_commit=$(git -C "$project_root" log "$branch" --since="2 hours ago" --oneline -1 2>/dev/null || true)
    if [[ -n "$last_commit" ]]; then
      echo "  $branch: $last_commit"
      found_commits=true
    fi
  done
  if [[ "$found_commits" == "false" ]]; then
    echo "  (no recent commits)"
  fi
  echo ""

  # Check for plan files (status.json field + scan ~/.autorun/plans/)
  echo "Plan files:"
  local orch_dir
  orch_dir=$(dirname "$STATUS_FILE")
  local found_plans=false

  # Check status.json plan_file field
  for ctx in "$orch_dir"/stages/stage-*-context.md; do
    local stage_num
    stage_num=$(basename "$ctx" | sed 's/stage-\([0-9]*\)-.*/\1/')
    local plan_file
    plan_file=$(python3 -c "import json; print(json.load(open('$STATUS_FILE'))['stages']['$stage_num'].get('plan_file') or '')" 2>/dev/null || echo "")
    if [[ -n "$plan_file" ]]; then
      echo "  Stage $stage_num: $plan_file"
      found_plans=true
    fi
  done

  # Also scan ~/.autorun/plans/ for matching plan files
  local plan_name
  plan_name=$(python3 -c "import json; print(json.load(open('$STATUS_FILE')).get('plan_name',''))" 2>/dev/null || echo "")
  if [[ -d "$HOME/.autorun/plans" ]]; then
    for pf in "$HOME/.autorun/plans"/*.md; do
      [[ -f "$pf" ]] || continue
      echo "  $(basename "$pf")"
      found_plans=true
    done
  fi
  if [[ "$found_plans" == "false" ]]; then
    echo "  (none found)"
  fi
  echo ""

  # All done check
  if [[ $completed -eq $total && $total -gt 0 ]]; then
    echo "*** ALL STAGES COMPLETE ***"
    exit 0
  fi
  if [[ $in_progress -eq 0 && $pending -eq 0 && $failed -gt 0 ]]; then
    echo "*** ALL REMAINING STAGES FAILED — intervention needed ***"
  fi
}

# Run immediately, then loop
check_progress

while true; do
  sleep "$INTERVAL_SECS"
  check_progress
done
