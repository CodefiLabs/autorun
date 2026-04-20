#!/usr/bin/env bash
set -euo pipefail

# monitor-orchestration.sh - Active orchestration monitor with stall detection
#
# Usage: monitor-orchestration.sh [orchestration-dir] [interval-seconds] [snapshot-gap-seconds]
#
# Monitors tmux sessions for orchestrated runs. Takes two capture-pane snapshots
# per check (separated by a configurable gap) and diffs them to detect stalls.
# Auto-sends "continue" to sessions stuck at an idle prompt.
#
# Unlike check-orchestration-progress.sh (passive/read-only dashboard), this
# script actively intervenes when stalls are detected.
#
# Arguments:
#   orchestration-dir   Path to orchestration dir (contains status.json).
#                       Auto-detects most recent if omitted.
#   interval-seconds    Seconds between checks (default: 600 / 10min)
#   snapshot-gap-seconds  Gap between capture-pane snapshots (default: 60)

ORCH_DIR="${1:-}"
CHECK_INTERVAL="${2:-600}"
SNAPSHOT_GAP="${3:-60}"

# Auto-detect orchestration dir if not provided
if [[ -z "$ORCH_DIR" ]]; then
  ORCH_BASE="$HOME/.autorun/orchestration"
  if [[ -d "$ORCH_BASE" ]]; then
    STATUS_CANDIDATE=$(find "$ORCH_BASE" -name "status.json" -maxdepth 2 -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
    if [[ -n "$STATUS_CANDIDATE" ]]; then
      ORCH_DIR=$(dirname "$STATUS_CANDIDATE")
    fi
  fi
  if [[ -z "$ORCH_DIR" ]]; then
    echo "ERROR: No orchestration directory found. Pass path as first argument."
    exit 1
  fi
fi

STATUS_FILE="$ORCH_DIR/status.json"
if [[ ! -f "$STATUS_FILE" ]]; then
  echo "ERROR: status.json not found at $STATUS_FILE"
  exit 1
fi

SLUG=$(python3 -c "import json; print(json.load(open('$STATUS_FILE'))['project_slug'])" 2>/dev/null)
PROJECT_ROOT=$(python3 -c "import json; print(json.load(open('$STATUS_FILE'))['project_root'])" 2>/dev/null)
PLAN_NAME=$(python3 -c "import json; print(json.load(open('$STATUS_FILE'))['plan_name'])" 2>/dev/null)

LOG_DIR="$HOME/.autorun/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/${SLUG}-monitor.log"

SNAP_DIR=$(mktemp -d)
trap 'rm -rf "$SNAP_DIR"' EXIT

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
separator() { printf '%.0s─' $(seq 1 80) | tee -a "$LOG_FILE"; echo | tee -a "$LOG_FILE"; }

get_stage_statuses() {
    python3 -c "
import json
with open('$STATUS_FILE') as f:
    data = json.load(f)
wave = data.get('current_wave', '?')
print(f'Current wave: {wave}')
print(f'Waves: {data[\"waves\"]}')
print()
completed = 0
total = len(data['stages'])
for num, stage in sorted(data['stages'].items(), key=lambda x: int(x[0])):
    status = stage['status']
    name = stage['name']
    if status == 'completed':
        completed += 1
    phase_info = ''
    phases = stage.get('phases', {})
    for p in ['research', 'create_plan', 'implement', 'merge']:
        ph = phases.get(p, {})
        if isinstance(ph, dict) and ph.get('started_at') and not ph.get('completed_at'):
            phase_info = f' [{p}]'
            if p == 'implement':
                cur = ph.get('current_phase')
                tot = ph.get('total_phases')
                if cur and tot:
                    phase_info = f' [implement {cur}/{tot}]'
    print(f'  Stage {num:>2}: {status:<15} {name:<35} {phase_info}')
print()
print(f'Progress: {completed}/{total} stages completed')
" 2>&1
}

all_terminal() {
    python3 -c "
import json
with open('$STATUS_FILE') as f:
    data = json.load(f)
terminal = sum(1 for s in data['stages'].values() if s['status'] in ('completed', 'failed'))
total = len(data['stages'])
completed = sum(1 for s in data['stages'].values() if s['status'] == 'completed')
failed = sum(1 for s in data['stages'].values() if s['status'] == 'failed')
if terminal == total:
    if failed > 0:
        print(f'DONE_WITH_FAILURES:{completed}/{total} completed, {failed} failed')
    else:
        print('ALL_COMPLETE')
else:
    print('RUNNING')
" 2>/dev/null
}

get_stage_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep "^${SLUG}_stage-" \
        || true
}

# Claude Code uses ❯ as its idle prompt character
is_at_idle_prompt() {
    local snapshot_file="$1"
    grep -q '^❯ *$' "$snapshot_file" 2>/dev/null
}

check_wave_transition() {
    python3 -c "
import json
with open('$STATUS_FILE') as f:
    data = json.load(f)
waves = data['waves']
current = data.get('current_wave', 1)
idx = current - 1
if idx >= len(waves):
    print('ALL_WAVES_DONE')
    exit(0)
current_stages = waves[idx]
all_done = all(data['stages'][str(s)]['status'] in ('completed', 'failed') for s in current_stages)
if all_done and idx + 1 < len(waves):
    next_stages = waves[idx + 1]
    next_launched = any(data['stages'][str(s)]['status'] != 'pending' for s in next_stages)
    if not next_launched:
        print(f'WAVE_GAP: wave {current} complete but wave {current+1} (stages {next_stages}) not launched')
    else:
        print(f'WAVE_OK: wave {current+1} is running')
elif all_done:
    print('ALL_WAVES_DONE')
else:
    in_progress = [s for s in current_stages if data['stages'][str(s)]['status'] not in ('completed', 'failed')]
    print(f'WAVE_RUNNING: wave {current} — stages {in_progress} still in progress')
" 2>&1
}

check_dead_sessions() {
    python3 -c "
import json, subprocess
with open('$STATUS_FILE') as f:
    data = json.load(f)
for num, stage in sorted(data['stages'].items(), key=lambda x: int(x[0])):
    if stage['status'] in ('in_progress', 'pending'):
        phases = stage.get('phases', {})
        has_activity = any(
            isinstance(ph, dict) and ph.get('started_at') and not ph.get('completed_at')
            for ph in phases.values()
        )
        if not has_activity:
            continue
        session = '${SLUG}_stage-' + num
        result = subprocess.run(['tmux', 'has-session', '-t', session], capture_output=True)
        if result.returncode != 0:
            print(f'DEAD: Stage {num} ({stage[\"name\"]}) has active phases but session {session} is gone')
" 2>&1
}

run_check() {
    local check_num="$1"
    separator
    log "CHECK #$check_num — $(date '+%a %b %d %H:%M')"
    separator

    local sessions
    sessions=$(get_stage_sessions)

    log "Sessions:"
    if [ -z "$sessions" ]; then
        log "  (no stage sessions found)"
    else
        echo "$sessions" | while IFS= read -r s; do log "  $s"; done
    fi

    log ""
    log "Status:"
    get_stage_statuses | while IFS= read -r line; do log "  $line"; done

    log ""
    log "Worktrees:"
    git -C "$PROJECT_ROOT" worktree list 2>/dev/null \
        | while IFS= read -r line; do log "  $line"; done

    log ""
    log "Recent commits (last 2h):"
    local found_commits=false
    for branch in $(git -C "$PROJECT_ROOT" branch --list 'worktree-stage-*' 2>/dev/null | sed 's/^[* ]*//'); do
        local last_commit
        last_commit=$(git -C "$PROJECT_ROOT" log "$branch" --since="2 hours ago" --oneline -1 2>/dev/null || true)
        if [[ -n "$last_commit" ]]; then
            log "  $branch: $last_commit"
            found_commits=true
        fi
    done
    if [[ "$found_commits" == "false" ]]; then
        log "  (no recent commits)"
    fi

    if [ -z "$sessions" ]; then
        log ""
        log "No active sessions to capture. Checking for dead sessions..."
        check_dead_sessions | while IFS= read -r line; do log "  $line"; done
        return
    fi

    log ""
    log "Snapshot 1:"
    echo "$sessions" | while IFS= read -r session; do
        log "  --- $session ---"
        tmux capture-pane -t "$session" -p 2>/dev/null | tail -30 > "$SNAP_DIR/${session}.snap1"
        tail -10 "$SNAP_DIR/${session}.snap1" | while IFS= read -r line; do log "    $line"; done
    done

    log ""
    log "Waiting ${SNAPSHOT_GAP}s for snapshot 2..."
    sleep "$SNAPSHOT_GAP"

    log ""
    log "Snapshot 2 + comparison:"
    echo "$sessions" | while IFS= read -r session; do
        log "  --- $session ---"
        tmux capture-pane -t "$session" -p 2>/dev/null | tail -30 > "$SNAP_DIR/${session}.snap2"
        tail -10 "$SNAP_DIR/${session}.snap2" | while IFS= read -r line; do log "    $line"; done

        if diff -q "$SNAP_DIR/${session}.snap1" "$SNAP_DIR/${session}.snap2" >/dev/null 2>&1; then
            log "  ⚠ NO CHANGE — likely stalled"
            printf '%s\n' "$(python3 -c "import json,datetime; print(json.dumps({'ts':datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ'),'type':'stall_detected','session':'$session','stage':'$session'.split('_stage-')[-1] if '_stage-' in '$session' else None,'check_num':$check_num,'orch_dir':'$ORCH_DIR'}))")" >> "$ORCH_DIR/events.jsonl" 2>/dev/null
            if is_at_idle_prompt "$SNAP_DIR/${session}.snap2"; then
                tmux send-keys -t "$session" "continue" Enter 2>/dev/null
                printf '%s\n' "$(python3 -c "import json,datetime; print(json.dumps({'ts':datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ'),'type':'stall_continue_sent','session':'$session','stage':'$session'.split('_stage-')[-1] if '_stage-' in '$session' else None,'check_num':$check_num,'orch_dir':'$ORCH_DIR'}))")" >> "$ORCH_DIR/events.jsonl" 2>/dev/null
                log "  ↳ Sent 'continue' to $session"
            fi
        else
            log "  ✓ Output changed — progressing"
        fi
    done

    log ""
    log "Wave status:"
    local wave_status
    wave_status=$(check_wave_transition)
    log "  $wave_status"
    if echo "$wave_status" | grep -q "WAVE_GAP"; then
        log "  ⚠ ATTENTION: Next wave needs manual launch or merge.md didn't fire"
        printf '%s\n' "$(python3 -c "import json,datetime; print(json.dumps({'ts':datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ'),'type':'wave_gap_detected','detail':'''$wave_status''','check_num':$check_num,'orch_dir':'$ORCH_DIR'}))")" >> "$ORCH_DIR/events.jsonl" 2>/dev/null
    fi

    local dead
    dead=$(check_dead_sessions)
    if [ -n "$dead" ]; then
        log ""
        log "Dead sessions:"
        echo "$dead" | while IFS= read -r line; do
            log "  $line"
            printf '%s\n' "$(python3 -c "import json,datetime,re; m=re.search(r'Stage\s+(\d+)','''$line'''); print(json.dumps({'ts':datetime.datetime.now(datetime.UTC).strftime('%Y-%m-%dT%H:%M:%SZ'),'type':'session_dead','stage':int(m.group(1)) if m else None,'detail':'''$line''','check_num':$check_num,'orch_dir':'$ORCH_DIR'}))")" >> "$ORCH_DIR/events.jsonl" 2>/dev/null
        done
    fi

    separator
}

# --- Main ---
log ""
separator
log "ORCHESTRATION MONITOR STARTED"
log "Plan: $PLAN_NAME"
log "Orchestration: $ORCH_DIR"
log "Slug: $SLUG"
log "Project: $PROJECT_ROOT"
log "Interval: ${CHECK_INTERVAL}s ($((CHECK_INTERVAL / 60))min)"
log "Snapshot gap: ${SNAPSHOT_GAP}s"
log "Log: $LOG_FILE"
log "PID: $$"
separator

check_num=0
while true; do
    check_num=$((check_num + 1))

    terminal_state=$(all_terminal)
    if [[ "$terminal_state" == "ALL_COMPLETE" ]]; then
        separator
        log "ALL STAGES COMPLETED"
        get_stage_statuses | while IFS= read -r line; do log "  $line"; done
        log ""
        log "Running stats aggregation..."
        python3 "$(dirname "$0")/orchestration-stats.py" "$STATUS_FILE" "$LOG_FILE" "$PROJECT_ROOT" 2>&1 | while IFS= read -r line; do log "  $line"; done || true
        separator
        log "MONITOR EXITING — orchestration complete"
        exit 0
    elif [[ "$terminal_state" == DONE_WITH_FAILURES* ]]; then
        separator
        log "ORCHESTRATION FINISHED WITH FAILURES: ${terminal_state#DONE_WITH_FAILURES:}"
        get_stage_statuses | while IFS= read -r line; do log "  $line"; done
        log ""
        log "Running stats aggregation..."
        python3 "$(dirname "$0")/orchestration-stats.py" "$STATUS_FILE" "$LOG_FILE" "$PROJECT_ROOT" 2>&1 | while IFS= read -r line; do log "  $line"; done || true
        separator
        log "MONITOR EXITING — all stages in terminal state"
        exit 1
    fi

    run_check "$check_num"

    log "Next check in ${CHECK_INTERVAL}s..."
    log ""
    sleep "$CHECK_INTERVAL"
done
