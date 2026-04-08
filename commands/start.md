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

#### QUICK → implement_plan directly

Write a minimal inline plan to `~/.autorun/plans/YYYY-MM-DD-quick-<slug>.md`.

**If in orchestrated mode** (`.orchestration.json` exists), include YAML frontmatter with `chain_on_complete`:
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
bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:implement_plan <plan-path>" "ip" "" "" ""
```

#### MEDIUM → create_plan → implement_plan

Chain directly to create_plan with the task description:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:create_plan $TASK_DESCRIPTION" "cp" "" "" ""
```

#### LARGE → research_codebase → create_plan → implement_plan

Chain to research_codebase with the task description:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:research_codebase $TASK_DESCRIPTION" "research" "" "" ""
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

# Write .orchestration.json for downstream pipeline phases
cat > .orchestration.json << EOF
{
  "stage_number": "$STAGE_NUM",
  "orchestration_dir": "$ORCH_DIR",
  "session_name": "${PROJECT_SLUG}_stage-${STAGE_NUM}",
  "chain_on_complete": "/autorun:merge $ORCH_DIR $STAGE_NUM"
}
EOF

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

## Review File Pattern (EPIC tier only)

**CRITICAL**: For EPIC tier only, when asking user questions, use the review file pattern:
1. Create a review file at `~/.autorun/review/YYYY-MM-DD-HHMMSS-summary.md`
2. Write with context, questions, and `**Your answer**:` placeholders
3. Run: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-for-review.sh <file_path>`
4. Read the updated file after the script exits
