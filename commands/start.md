---
description: Smart entry point for autorun pipeline — triages tasks and routes to appropriate pipeline
model: opus
---

# Autorun Start

You are the entry point for automated code change pipelines. Your job is to analyze what the user wants, classify it by scope, and route to the right pipeline.

## Arguments

**TASK_DESCRIPTION_OR_CONTEXT**: $ARGUMENTS (required)

Either:
- Plain text task description (e.g., "Fix the login redirect bug")
- A path to a context file (e.g., `~/.autorun/orchestration/.../stage-N-context.md`)

## Execution

Do NOT use AskUserQuestion — this is a headless autorun command (except for EPIC tier, which uses the review file pattern).

### Orchestration detection helper

Run this once at the top of execution to detect whether this session is part of an active orchestration. Sets `$IN_ORCHESTRATED` and populates `$STAGE_NUM`/`$ORCH_DIR`/`$STATUS_FILE`/`$SESSION_NAME`/`$CHAIN_ON_COMPLETE` on success:

```bash
if CTX=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-orchestration-context.sh "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null); then
  eval "$CTX"
  IN_ORCHESTRATED=true
else
  IN_ORCHESTRATED=false
fi
```

### Step 1: Triage

Read any provided files fully. Then perform a self-classification analysis:

<analysis>
- What is the core request?
- Is the scope/approach already clear, or does it need codebase research?
- How many files/systems are likely involved?
- Is this self-contained or multi-stage/multi-system?
→ Classify: QUICK / MEDIUM / LARGE / EPIC
</analysis>

Classification criteria:

| Tier | Criteria |
|------|----------|
| **QUICK** | ≤2 files, obvious change, no context needed (typo fix, config tweak, simple bug with known location) |
| **MEDIUM** | Needs a plan but scope is understood (new endpoint, component refactor, test addition) |
| **LARGE** | Needs codebase research before planning (unfamiliar area, cross-cutting concern, complex integration) |
| **EPIC** | Multi-system, multi-stage, weeks of work (architecture redesign, new subsystem, large migration) |

Route immediately based on classification. No user confirmation except for EPIC.

### Step 2: Route

Before routing, derive a `TASK_SLUG` for meaningful tmux session names:
- If task is a **file path**: use the basename without extension, lowercased, spaces/underscores → hyphens, max 30 chars. E.g. `/path/to/make-api-call-bug-report.md` → `make-api-call-bug-report`
- If task is **plain text**: take the first 3–4 significant words, lowercased, non-alphanumeric → hyphens, max 30 chars. E.g. `Fix the login redirect bug` → `fix-login-redirect-bug`

Use `<phase>-<slug>` as the window name for all non-orchestrated chaining commands (e.g. `cp-make-api-call-bug-report`, `research-fix-login-redirect`, `ip-quick-config-fix`).

#### QUICK → implement_plan directly

Write a minimal inline plan to `~/.autorun/plans/YYYY-MM-DD-quick-<slug>.md`.

**If in orchestrated mode** (`$IN_ORCHESTRATED` is `true` — i.e. an entry for the current tmux session exists in `.orchestration.json`), include YAML frontmatter with `chain_on_complete`:
```
---
chain_on_complete: "/autorun:merge <ORCH_DIR> <STAGE_NUM>"
---
# Quick Fix: <description>

## Phase 1: <change>

### Changes Required:
**File**: `path/to/file`
**Changes**: <what to change>

### Success Criteria:
#### Automated Verification:
- [ ] <relevant checks>
```

**If NOT in orchestrated mode**, write the plan without frontmatter (current behavior):
```
# Quick Fix: <description>

## Phase 1: <change>

### Changes Required:
**File**: `path/to/file`
**Changes**: <what to change>

### Success Criteria:
#### Automated Verification:
- [ ] <relevant checks>
```

Then chain:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:implement_plan <plan-path>" "ip-$TASK_SLUG" "" "" ""
```

#### MEDIUM → create_plan → implement_plan

Chain directly to create_plan with the task description:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:create_plan $TASK_DESCRIPTION" "cp-$TASK_SLUG" "" "" ""
```

#### LARGE → research_codebase → create_plan → implement_plan

Chain to research_codebase with the task description:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:research_codebase $TASK_DESCRIPTION" "research-$TASK_SLUG" "" "" ""
```

#### EPIC → Interactive brainstorm → master plan → orchestrate

This is the only tier involving meaningful user interaction.

1. Ask clarifying questions via review file — constraints, priorities, non-starters, target timeline:
   ```bash
   mkdir -p ~/.autorun/review
   ```
   Write review file at `~/.autorun/review/YYYY-MM-DD-HHMMSS-epic-triage.md` with questions about scope, constraints, priorities, and non-starters.
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-for-review.sh <review-file-path>
   ```
   Read updated file.

2. Do brief, cursory research (1-2 agents maximum — enough to validate assumptions, not full research):
   - Spawn 1-2 focused `codebase-locator` or `codebase-analyzer` Tasks
   - Write findings to scratch files, return only summaries

3. Ask follow-up questions if research uncovered surprises (via review file)

4. Generate `~/.autorun/plans/YYYY-MM-DD-<name>-master.md` with waves/stages structure:
   - Each stage has: number, name, dependencies, scope description
   - Dependencies define which stages can run in parallel (waves)

5. Chain to orchestrate:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:orchestrate <master-plan-path>" "orch" "" "" ""
   ```

### Orchestrated Mode

If `$ARGUMENTS` is a path to a stage context file (contains `## Orchestration` section with `orchestration_dir`, `stage_number`, `status_file`, `base_branch`):

1. Read the context file fully
2. Extract the `## Scope` section as the task description
3. Extract orchestration metadata
4. Write `.orchestration.json` to the working directory (worktree root) — this file is read by all downstream pipeline phases (`research_codebase.md`, `create_plan.md`, `implement_plan.md`) for session naming, phase status updates, and chain-on-complete routing
5. Triage the scope as QUICK / MEDIUM / LARGE (never EPIC for individual stages)
6. Route accordingly, but pass orchestration context through chain args

For orchestrated mode, adjust chain commands to include session naming:
```bash
STAGE_NUM=<from context>
STATUS_FILE=<from context>
ORCH_DIR=<from context>
PROJECT_SLUG=$(python3 -c "import json; print(json.load(open('$STATUS_FILE')).get('project_slug', ''))")
SESSION_ARG="${PROJECT_SLUG}_stage-${STAGE_NUM}"

# Register this stage's orchestration context in .orchestration.json (session-keyed registry)
SESSION_NAME="${PROJECT_SLUG}_stage-${STAGE_NUM}"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/register-orchestration.sh \
  "$SESSION_NAME" \
  "$STAGE_NUM" \
  "$ORCH_DIR" \
  "/autorun:merge $ORCH_DIR $STAGE_NUM"

# Update status
bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" triage completed_at

# Route to appropriate pipeline
case $TIER in
  QUICK)
    # Write inline plan, chain to implement_plan
    WINDOW_NAME="s${STAGE_NUM}-ip"
    bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:implement_plan <plan>" "$WINDOW_NAME" "$SESSION_ARG" "" "close"
    ;;
  MEDIUM)
    WINDOW_NAME="s${STAGE_NUM}-cp"
    bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:create_plan <context>" "$WINDOW_NAME" "$SESSION_ARG" "" "close"
    ;;
  LARGE)
    WINDOW_NAME="s${STAGE_NUM}-research"
    bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:research_codebase <context>" "$WINDOW_NAME" "$SESSION_ARG" "" "close"
    ;;
esac
```

### Step 3: Start Monitor (non-EPIC tiers only)

After chaining to the pipeline, always start the orchestration monitor as a background process **in the current session**. This lets the user stay here and watch progress without attaching to any other session. The monitor auto-detects the most recent orchestration and exits gracefully if none is found.

**Skip this step for EPIC tier** — `orchestrate.md` starts the monitor after launching wave 1.

```bash
# Always start monitor if not already running (auto-detects orchestration, exits cleanly if none)
if ! pgrep -f "monitor-orchestration.sh" > /dev/null 2>&1; then
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/monitor-orchestration.sh &
  echo "Monitor started (PID $!) — auto-detecting most recent orchestration"
else
  echo "Monitor already running (PID $(pgrep -f monitor-orchestration.sh))"
fi
```

## Review File Pattern (EPIC tier only)

**CRITICAL**: For EPIC tier only, when asking user questions, use the review file pattern:
1. Create a review file at `~/.autorun/review/YYYY-MM-DD-HHMMSS-summary.md`
2. Write with context, questions, and `**Your answer**:` placeholders
3. Run: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-for-review.sh <file_path>`
4. Read the updated file after the script exits
