---
description: Execute a staged master plan by decomposing into parallel stages
model: opus
---

# Orchestrate Master Plan

You are tasked with executing a staged master plan by parsing its dependency graph and launching `start.md` for each stage in topological wave order. Each stage is triaged independently — `start.md` routes it to the appropriate pipeline (QUICK / MEDIUM / LARGE) based on scope.

## Arguments

**MASTER_PLAN_PATH**: $ARGUMENTS (required)

The path to a master plan file containing stages with dependency information OR instructions for the master plan.

If no arguments are provided, write a review file asking for the master plan path, then wait.

## Review File Pattern (How to Ask Questions)

**CRITICAL**: Whenever you need to ask the user questions, you MUST use the review file pattern:

1. **Create a review file** at `~/.autorun/review/YYYY-MM-DD-HHMMSS-summary.md`
   - Ensure directory exists: `mkdir -p ~/.autorun/review`
2. **Write the review file** with context, questions, and `**Your answer**:` placeholders
3. **Run the watch script**: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-for-review.sh <file_path>`
4. **Read the updated file** after the script exits, then continue based on answers.

## Execution

Do NOT use AskUserQuestion — this is a headless autorun command. All work is delegated to contained Tasks for context isolation.

### Step 1: Parse Master Plan and Compute Waves (contained Task)

Spawn a single `general-purpose` Task to parse the master plan. Pass it:
- The master plan file path from `$ARGUMENTS`
- Instructions to read the FULL plan file

The Task should:

1. **Read the master plan** in its entirety
2. **Extract all stages** — each stage has:
   - A stage number
   - A stage name/title
   - Dependencies (which stages must complete before this one can start)
   - A description of the stage's scope, goals, and key deliverables (NOT detailed phases — those will be determined by `create_plan` later)
3. **Compute topological waves** — groups of stages that can run in parallel:
   - Wave 1: all stages with no dependencies
   - Wave 2: stages whose dependencies are all in wave 1
   - Wave N: stages whose dependencies are all in waves 1 through N-1
   - If circular dependencies are detected, return an error
4. **Detect the project root and current branch** from git:
   ```bash
   PROJECT_ROOT=$(git rev-parse --show-toplevel)
   BASE_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
   ```
   The `BASE_BRANCH` is the branch that was active when orchestration started — all stage worktrees will branch off it, and all merges will target it (NOT necessarily `main`/`master`).
5. **Derive a plan name** from the master plan filename:
   - Strip path and extension
   - Convert to kebab-case
   - Example: `wave_2_master_plan.md` → `wave-2-master-plan`
6. **Generate a project_slug** from the plan name:
   - Strip leading date pattern (`YYYY-MM-DD-`)
   - Strip `wave\d+-?` prefix
   - Take first 2-3 kebab words, max 20 chars
   - Examples: `2026-02-20-wave2-token-design-audit` → `token-audit`, `wave2-pixel-perfect-visual-qa` → `pixel-qa`

The Task should return:
- `PLAN_NAME` - derived kebab-case name
- `PROJECT_SLUG` - short slug for session naming
- `PLAN_PATH` - absolute path to the master plan
- `PROJECT_ROOT` - absolute path to the project root
- `BASE_BRANCH` - the branch that was active when orchestration started (merge target)
- `STAGES` - a list of stages, each with: number, name, dependencies, and a scope description summarizing that stage's goals and deliverables
- `WAVES` - the computed wave groups (array of arrays of stage numbers)
- `TOTAL_STAGES` - count of stages
- `TOTAL_WAVES` - count of waves

If the plan cannot be parsed or has circular dependencies, return the error details so a review file can be written.

### Step 2: Create Orchestration Directory and Stage Context Files (contained Task)

Spawn a single `general-purpose` Task to create the orchestration directory structure and write stage context files. Pass it all values from Step 1 (including `PROJECT_SLUG`).

The Task should:

1. **Create the orchestration directory**:
   ```bash
   ORCH_DIR="$HOME/.autorun/orchestration/$PLAN_NAME"
   mkdir -p "$ORCH_DIR/stages"
   ```

2. **Write a context file for each stage** at `$ORCH_DIR/stages/stage-N-context.md`:
   ```markdown
   # Stage N: Stage Name Here

   ## Scope
   [The stage's scope description extracted from the master plan]

   ## Dependencies
   - Depends on: Stage X, Stage Y (or "None" for wave 1 stages)

   ## Orchestration
   orchestration_dir: ~/.autorun/orchestration/plan-name/
   stage_number: N
   status_file: ~/.autorun/orchestration/plan-name/status.json
   base_branch: <branch>
   ```

   These are NOT implementation plans — they're context documents that `start.md` will use to triage the stage and route it to the appropriate pipeline. The detailed phases will be determined by `create_plan` after research.

3. **Write the initial status.json** at `$ORCH_DIR/status.json`:
   ```json
   {
     "plan_path": "<absolute path to master plan>",
     "plan_name": "<plan-name>",
     "project_slug": "<slug>",
     "project_root": "<project root>",
     "base_branch": "<branch active when orchestration started>",
     "created_at": "<ISO 8601 timestamp>",
     "stages": {
       "1": {
         "status": "pending",
         "name": "<stage name>",
         "depends_on": [],
         "branch": null,
         "context_file": "<absolute path to stage-1-context.md>",
         "plan_file": null,
         "started_at": null,
         "completed_at": null,
         "phases": {
           "research": { "started_at": null, "completed_at": null },
           "create_plan": { "started_at": null, "completed_at": null },
           "implement": { "started_at": null, "completed_at": null, "current_phase": null, "total_phases": null },
           "merge": { "started_at": null, "completed_at": null }
         }
       }
     },
     "current_wave": 1,
     "waves": [[1], [2,3,4], ...]
   }
   ```

4. **Emit `orchestration_started` event** to `$ORCH_DIR/events.jsonl` alongside the status.json write:
   ```python
   import json, datetime, os
   events_path = os.path.join(ORCH_DIR, "events.jsonl")
   with open(events_path, "a") as f:
       f.write(json.dumps({
           "ts": datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "type": "orchestration_started",
           "plan_name": plan_name,
           "project_slug": project_slug,
           "project_root": project_root,
           "total_stages": len(stages),
           "total_waves": len(waves),
           "waves": waves,
           "orch_dir": ORCH_DIR,
       }) + "\n")
   ```

The Task should return:
- `ORCH_DIR` - absolute path to orchestration directory
- `STATUS_FILE` - absolute path to status.json
- `PROJECT_SLUG` - the project slug (passed through from Step 1)
- `CONTEXT_FILES` - list of stage context file paths written
- Confirmation that all files were created successfully

### Step 3: Launch Wave 1 Stages

For each stage in wave 1, create a tmux session directly via Bash (do NOT spawn Tasks for this). Run all stage launches **in parallel** as separate Bash tool calls:

```bash
SESSION_NAME="${PROJECT_SLUG}_stage-${STAGE_NUM}"
CONTEXT_FILE="$ORCH_DIR/stages/stage-${STAGE_NUM}-context.md"

tmux new-session -d -s "$SESSION_NAME" -n "s${STAGE_NUM}" \
  "claude --worktree 'stage-${STAGE_NUM}' '/autorun:start $CONTEXT_FILE'"
```

`start.md` will triage the stage scope and route to the appropriate pipeline. `--worktree` provides isolation for parallel stages.

This kicks off the pipeline: `start.md` triages → routes to appropriate pipeline → `merge`.
- Success/failure status and any error details

### Step 4: Launch Orchestration Monitor

After all wave 1 sessions are created, launch the monitor in its own tmux session:

```bash
MONITOR_SESSION="${PROJECT_SLUG}_monitor"

tmux new-session -d -s "$MONITOR_SESSION" -n "monitor" \
  "bash ${CLAUDE_PLUGIN_ROOT}/scripts/monitor-orchestration.sh $ORCH_DIR"
```

The monitor runs autonomously alongside the orchestration:
- Takes two capture-pane snapshots ~60s apart for each active session to detect stalls (not just one — the diff confirms whether output is actually changing)
- Auto-sends `continue` to sessions stuck at an idle `❯` prompt (common after API errors or rate limits)
- Detects dead sessions (status says active but tmux session is gone)
- Detects wave gaps (current wave complete but next wave not launched)
- Logs everything to `~/.autorun/logs/${PROJECT_SLUG}-monitor.log`
- Exits automatically when all stages reach a terminal state (completed or failed)

## Output

After all Tasks complete, print a summary:

```
Orchestration launched:
  Master Plan:    <plan-path>
  Plan Name:      <plan-name>
  Orchestration:  ~/.autorun/orchestration/<plan-name>/
  Status File:    ~/.autorun/orchestration/<plan-name>/status.json

  Total Stages: N
  Total Waves:  M
  Waves: [[1], [2,3,4], [5], ...]

  Wave 1 launched (N stages):
    Stage 1: <stage-name>
      Branch:   stage-1-<name>
      Session:  ${PROJECT_SLUG}_stage-1
      Pipeline: start.md → triage → appropriate pipeline → merge

  Pending waves (will be launched by merge.md as dependencies complete):
    Wave 2: stages 2, 3, 4
    Wave 3: stages 5
    ...

Monitor session: ${PROJECT_SLUG}_monitor
Monitor log:     ~/.autorun/logs/${PROJECT_SLUG}-monitor.log
Sessions:        tmux list-sessions | grep ${PROJECT_SLUG}
Status:          cat ~/.autorun/orchestration/<plan-name>/status.json
```

## How It Connects

```
orchestrate (parse plan, write stage context files, launch wave 1)
  → start.md (per stage — triages scope, routes to pipeline)
    → [QUICK: implement_plan]
    → [MEDIUM: create_plan → implement_plan]
    → [LARGE: research_codebase → create_plan → implement_plan]
    → merge (merges branch, checks wave completion, launches next wave)
      → start.md (next wave stages — triage and route again)
        → ... until all waves complete
```

- **This command** parses the master plan, writes stage context files, and launches wave 1 via `start.md` with `--worktree`
- **start.md** triages each stage's scope and routes to the appropriate pipeline (QUICK / MEDIUM / LARGE)
- **research_codebase** (LARGE only) researches the codebase, writes a handoff file
- **create_plan** creates a detailed phased plan. Detects orchestration context and adds `chain_on_complete` to the plan frontmatter
- **implement_plan** executes the phases. When done, chains to merge via `chain_on_complete`
- **merge** merges the stage branch back, checks wave completion, launches next wave via `start.md`

## If You Get Stuck

When something isn't working as expected:
- First, make sure you've read and understood the master plan fully
- Check if the plan format matches what the parser expects
- Write a review file describing the issue and asking for guidance (use the review file pattern above)
