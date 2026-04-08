---
description: Merge completed stage branch back to base branch and launch next wave if ready
---

# Merge Stage

You are tasked with merging a completed stage's branch back into the base branch (the branch that was active when orchestration started — NOT necessarily `main`/`master`), updating orchestration status, and launching the next wave of stages if all current wave stages are complete.

## Arguments

**$ARGUMENTS format:** `<orchestration-dir> <stage-number>`

Example: `~/.autorun/orchestration/wave-2-master-plan 3`

- `orchestration-dir`: Path to the orchestration directory containing `status.json` and stage context files
- `stage-number`: The stage number that just completed

If arguments are missing or malformed, write a review file asking for clarification, then wait.

## Review File Pattern (How to Ask Questions)

**CRITICAL**: Whenever you need to ask the user questions, present issues, or request manual intervention, you MUST use the review file pattern instead of asking directly in the console:

1. **Create a review file** at `~/.autorun/review/YYYY-MM-DD-HHMMSS-summary.md`
   - Ensure directory exists: `mkdir -p ~/.autorun/review`
   - Use current timestamp and a brief kebab-case summary
2. **Write the review file** with context, questions, and `**Your answer**:` placeholders
3. **Run the watch script**: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-for-review.sh <file_path>`
4. **Read the updated file** after the script exits, then continue based on answers.

## Phase Audit (orchestrated mode only)

After parsing arguments, update the merge phase status. Since merge.md receives `<orchestration-dir>` and `<stage-number>` as arguments, use those directly:
```bash
# Parse args first
ORCH_DIR="<first-arg>"
STAGE_NUM="<second-arg>"
STATUS_FILE="$ORCH_DIR/status.json"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" merge started_at
```

This should be done as the **first action** in Step 1 (after parsing arguments), before any merge operations begin.

## Execution

Do NOT use AskUserQuestion — this is a headless autorun command. All work is delegated to contained Tasks for context isolation.

### Step 1: Parse Arguments and Read Status (contained Task)

Spawn a single `general-purpose` Task to parse arguments and gather orchestration state. Pass it:
- The raw `$ARGUMENTS` string
- Instructions to read and return the full orchestration state

The Task should:

1. **Parse arguments**:
   ```bash
   ORCH_DIR="<first-arg>"
   STAGE_NUM="<second-arg>"
   ```

2. **Read status.json** from `$ORCH_DIR/status.json`

3. **Identify the completed stage** from `status.json` using `STAGE_NUM`:
   - Get the stage's branch name and determine which wave it belongs to
   - Verify the stage is currently marked as `in_progress`

4. **Detect project root**:
   ```bash
   PROJECT_ROOT=$(python3 -c "import json; print(json.load(open('$ORCH_DIR/status.json'))['project_root'])")
   ```

5. **Extract the base branch** from status.json:
   ```bash
   BASE_BRANCH=$(python3 -c "import json; print(json.load(open('$ORCH_DIR/status.json'))['base_branch'])")
   ```
   This is the branch that was active when orchestration started — all merges target this branch.

The Task should return:
- `ORCH_DIR` - orchestration directory path
- `STAGE_NUM` - the completed stage number
- `PROJECT_ROOT` - absolute path to the project root
- `BASE_BRANCH` - the branch to merge into (from status.json)
- `STAGE_BRANCH` - the branch name for this stage
- `CURRENT_WAVE` - the current wave number
- `TOTAL_WAVES` - total number of waves
- `WAVES` - the full waves array
- Full `status.json` contents for subsequent steps
- Any errors if parsing/reading fails

If parsing fails, return error details so a review file can be written.

### Step 2: Merge Stage Branch into Base Branch (contained Task)

Spawn a single `general-purpose` Task to perform the git merge. Pass it all values from Step 1 (including `BASE_BRANCH`).

The Task should:

1. **Acquire the orchestration lock** before any git operations:
   ```bash
   LOCK_FILE="$ORCH_DIR/.merge.lock"
   exec 9>"$LOCK_FILE"
   flock -w 30 9 || { echo "ERROR: Could not acquire lock after 30s"; exit 1; }
   ```

2. **Merge the stage branch into the base branch** (the branch from status.json, NOT necessarily main/master):
   ```bash
   cd "$PROJECT_ROOT"

   # BASE_BRANCH comes from status.json — it's the branch that was active when orchestration started
   git checkout "$BASE_BRANCH"
   git merge "$STAGE_BRANCH" --no-edit
   ```

3. **If merge conflict occurs**, attempt autonomous resolution before escalating:

   a. **Identify conflicting files** from `git diff --name-only --diff-filter=U`

   b. **Research intent of both sides** — for each conflicting file, search:
      - `~/.autorun/plans/` for any plan that references this file (read relevant phases)
      - `~/.autorun/research/` for research docs covering this file or its module
      - `git log --oneline -20` on each conflicting file to understand recent history

   c. **Resolve with both intents preserved** — using the context gathered, edit the conflict markers to keep what both sides were trying to accomplish. When intent is clear from the plans, this is usually straightforward (each stage was scoped to a different concern).

   d. **Commit the resolution** with a message explaining what was merged and why:
      ```bash
      git add <resolved-files>
      git commit -m "merge: resolve conflict in <file> keeping both <side-A-intent> and <side-B-intent>"
      ```

   e. **Document the decision** — append a note to `$ORCH_DIR/conflicts.md` describing what was found and how it was resolved.

   f. **Only write a review file as absolute last resort** — if the conflicting changes are directly contradictory (e.g., two stages both deleted the same function but replaced it differently, with no way to satisfy both intents simultaneously) AND no plans/research provide enough context to make a call. In that case, commit everything resolvable first, document what was committed, then surface only the truly ambiguous piece for human input.

4. **Do NOT clean up the worktree or branch yet** — cleanup is deferred to the final step to avoid destroying the session's CWD before subsequent Tasks can run.

5. **Release the lock** (automatic when subshell exits)

The Task should return:
- `MERGE_SUCCESS` - true/false
- `BASE_BRANCH` - which branch was merged into
- `CONFLICT_DETAILS` - if autonomous resolution failed, the unresolvable conflict information

If autonomous conflict resolution fails completely (truly contradictory changes with no way to determine intent), do NOT proceed to Step 3. Instead, write a review file with only the unresolvable conflicts. All resolvable conflicts should already be committed by step 3f above.

### Step 3: Update Status and Check Wave Completion (contained Task)

Spawn a single `general-purpose` Task to atomically update status.json and determine next actions. Pass it:
- The orchestration directory path
- The completed stage number
- The waves array from status.json

The Task should:

1. **Acquire the orchestration lock**:
   ```bash
   LOCK_FILE="$ORCH_DIR/.merge.lock"
   exec 9>"$LOCK_FILE"
   flock -w 60 9 || { echo "ERROR: Could not acquire lock after 60s"; exit 1; }
   ```

2. **Re-read status.json** (it may have been updated by another merge process since Step 1):
   ```bash
   STATUS=$(cat "$ORCH_DIR/status.json")
   ```

3. **Update the completed stage and check wave completion** atomically:
   ```bash
   python3 << 'PYEOF'
   import json, os
   from datetime import datetime, timezone

   with open("ORCH_DIR/status.json", "r") as f:
       status = json.load(f)

   # Update the completed stage
   status["stages"][str(STAGE_NUM)]["status"] = "completed"
   status["stages"][str(STAGE_NUM)]["completed_at"] = datetime.now(timezone.utc).isoformat()

   # Determine which wave this stage belongs to
   current_wave_idx = status["current_wave"] - 1  # 0-indexed for waves array
   current_wave_stages = status["waves"][current_wave_idx]

   # Check if all stages in the current wave are complete
   all_complete = all(
       status["stages"][str(s)]["status"] == "completed"
       for s in current_wave_stages
   )

   has_more_waves = (current_wave_idx + 1) < len(status["waves"])

   # Write atomically
   tmp = "ORCH_DIR/status.json.tmp"
   with open(tmp, "w") as f:
       json.dump(status, f, indent=2)
   os.rename(tmp, "ORCH_DIR/status.json")

   print(json.dumps({
       "all_wave_complete": all_complete,
       "has_more_waves": has_more_waves,
       "current_wave": status["current_wave"],
       "total_waves": len(status["waves"]),
       "wave_stages_status": [
           {"stage": s, "status": status["stages"][str(s)]["status"]}
           for s in current_wave_stages
       ]
   }))
   PYEOF
   ```

4. **Release the lock** (automatic when subshell exits)

The Task should return:
- `ALL_WAVE_COMPLETE` - whether all stages in the current wave are done
- `HAS_MORE_WAVES` - whether there are more waves after the current one
- `CURRENT_WAVE` - the current wave number
- `TOTAL_WAVES` - total number of waves
- `WAVE_STAGES_STATUS` - status of each stage in the current wave

### Step 4: Launch Next Wave (if applicable)

**Only proceed here if Step 3 returned `ALL_WAVE_COMPLETE=true` AND `HAS_MORE_WAVES=true`.**

If the current wave is NOT complete (other stages still running), update the merge phase status and print a status message, then exit:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$ORCH_DIR/status.json" "$STAGE_NUM" merge completed_at
```
```
Stage [N] merged successfully. Wave [W] still in progress ([X]/[Y] stages complete).
```

If all waves are complete (no more waves), skip to Step 5.

If the current wave IS complete and there are more waves:

First, spawn a single `general-purpose` Task to verify dependencies and bump the wave (under lock). Pass it:
- The orchestration directory, project root, and plan name
- The next wave's stage numbers

The Task should:

1. **Acquire the orchestration lock**:
   ```bash
   LOCK_FILE="$ORCH_DIR/.merge.lock"
   exec 9>"$LOCK_FILE"
   flock -w 60 9 || { echo "ERROR: Could not acquire lock after 60s"; exit 1; }
   ```

2. **Re-read status.json** and verify all dependencies for each next-wave stage are met:
   ```bash
   python3 -c "
   import json
   status = json.load(open('$ORCH_DIR/status.json'))
   for stage in NEXT_WAVE_STAGES:
       deps = status['stages'][str(stage)]['depends_on']
       for d in deps:
           if status['stages'][str(d)]['status'] != 'completed':
               print(f'BLOCKED: stage {stage} dependency {d} not complete')
               exit(1)
   print('OK')
   "
   ```

3. **Bump current_wave** in status.json (atomically):
   ```bash
   python3 -c "
   import json, os
   with open('$ORCH_DIR/status.json') as f:
       data = json.load(f)
   data['current_wave'] = data['current_wave'] + 1
   tmp = '$ORCH_DIR/status.json.tmp'
   with open(tmp, 'w') as f:
       json.dump(data, f, indent=2)
   os.rename(tmp, '$ORCH_DIR/status.json')
   "
   ```

4. **Release the lock**

Return verification that dependencies are met and wave counter is bumped.

Then, launch each next-wave stage directly via Bash (do NOT spawn Tasks for this). Run all stage launches **in parallel** as separate Bash tool calls.

First, read the `project_slug` from status.json to construct the session name:
```bash
PROJECT_SLUG=$(python3 -c "import json; print(json.load(open('$ORCH_DIR/status.json')).get('project_slug', ''))")
```

Then for each stage, create a new tmux **session** (not window) using `tmux new-session`:
```bash
SESSION_NAME="${PROJECT_SLUG}_stage-${STAGE}"
CONTEXT_FILE="$ORCH_DIR/stages/stage-${STAGE}-context.md"
tmux new-session -d -s "$SESSION_NAME" -n "s${STAGE}" \
  "claude --worktree 'stage-${STAGE}' '/autorun:start $CONTEXT_FILE'"
```

Each stage gets its own dedicated tmux session named `<project_slug>_stage-<N>`.

Also update the merge phase status to completed before launching the next wave:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$ORCH_DIR/status.json" "$STAGE_NUM" merge completed_at
```

`start.md` will triage the stage scope and route to the appropriate pipeline. `--worktree` provides isolation for parallel stages.

### Step 5: Final Summary (if all waves complete)

**Only reach here if ALL waves are complete (Step 3 returned `ALL_WAVE_COMPLETE=true` AND `HAS_MORE_WAVES=false`).**

First, update the merge phase status for this stage:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$ORCH_DIR/status.json" "$STAGE_NUM" merge completed_at
```

Then spawn a single `general-purpose` Task to generate the final summary. Pass it the orchestration directory path.

The Task should:

1. **Read the final status.json**
2. **Generate a completion summary**:
   ```
   ========================================
   ORCHESTRATION COMPLETE
   ========================================
   Plan: <plan-name>
   Waves completed: <total-waves>
   Stages completed: <total-stages>

   Wave 1:
     Stage 1: <name> - completed at <timestamp>

   Wave 2:
     Stage 2: <name> - completed at <timestamp>
     Stage 3: <name> - completed at <timestamp>
     Stage 4: <name> - completed at <timestamp>

   ...

   Started:  <overall-start-time>
   Finished: <now>
   Duration: <elapsed>
   ========================================
   ```

3. **Update status.json** with overall completion:
   ```python
   status["status"] = "completed"
   status["completed_at"] = datetime.now(timezone.utc).isoformat()
   ```

4. **Optionally chain to integration check**: If the status.json contains an `integration_check` field (a command or plan path), launch it:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "$INTEGRATION_CMD" "integration"
   ```

The Task should return the formatted summary string.

Print the summary to the console.

### Step 6: Clean Up Worktree and Branch (ALWAYS — final step)

**This step runs at the very end, regardless of which path was taken (wave in progress, next wave launched, or all complete).** It is deferred to here because the merge session's CWD may be the worktree itself. If the worktree is removed earlier (e.g., in Step 2), all subsequent Task spawns fail because their session CWD no longer exists.

Run cleanup directly via Bash:

```bash
# Detect if we're in a worktree
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
if [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  IN_WORKTREE=true
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  MAIN_REPO="$(git rev-parse --git-common-dir | sed 's|/\.git/worktrees/.*||')"

  cd "$MAIN_REPO"
  git worktree remove --force "$WORKTREE_PATH" 2>/dev/null
  git worktree prune
  git branch -D "$BRANCH" 2>/dev/null
  echo "Worktree cleaned up: $WORKTREE_PATH"
else
  echo "Not in a worktree — no cleanup needed"
fi
```

Failures are non-fatal (the worktree may already be gone if another process cleaned it up).

## Concurrency Safety

Multiple stages in a wave may finish around the same time, each triggering their own `merge.md` invocation. The design handles this safely:

1. **File locking**: Every read/write of `status.json` is protected by `flock` on `$ORCH_DIR/.merge.lock`
2. **Atomic writes**: status.json is written to a `.tmp` file first, then atomically renamed
3. **Re-read after lock**: After acquiring the lock, status.json is always re-read to get the latest state
4. **Single wave launcher**: Only the merge invocation that sees ALL wave stages complete (after re-reading under lock) will trigger the next wave launch. Others mark their stage complete and exit.

## Error Handling

- **Lock timeout**: If the lock cannot be acquired within 30-60 seconds, write a review file explaining the situation
- **Merge conflict**: Attempt autonomous resolution using plans/research context; only write a review file for truly unresolvable contradictions
- **Worktree removal failure**: Log warning but continue (the merge is what matters)
- **Branch deletion failure**: Log warning but continue (branch may have been deleted by another process)
- **Status.json missing**: Write a review file — the orchestration directory may be corrupt
- **Stage not found in status.json**: Write a review file — arguments may be wrong

## Output

After all steps complete, print a status message:

If wave still in progress:
```
Stage [N] merged into [base-branch] successfully.
Wave [W]: [X]/[Y] stages complete. Waiting for remaining stages.
Cleanup: [worktree cleaned up | not in a worktree]
```

If next wave launched:
```
Stage [N] merged into [base-branch] successfully.
Wave [W] complete! Launching wave [W+1] with [Z] stages...
  - Stage [A]: [name] → start.md → triage → pipeline → merge
  - Stage [B]: [name] → start.md → triage → pipeline → merge
Cleanup: [worktree cleaned up | not in a worktree]
```

If all waves complete:
```
[final summary from Step 5]
```
