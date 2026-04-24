---
description: Implement technical plans from ~/.autorun/plans with verification
---

# Implement Plan

You are tasked with implementing an approved technical plan from `~/.autorun/plans/`. These plans contain phases with specific changes and success criteria.

## Review File Pattern (How to Ask Questions)

**CRITICAL**: Whenever you need to ask the user questions, present issues, or request manual verification, you MUST use the review file pattern instead of asking directly in the console:

1. **Create a review file** at `~/.autorun/review/YYYY-MM-DD-HHMMSS-summary.md`
   - Ensure directory exists: `mkdir -p ~/.autorun/review`
   - Use current timestamp and a brief kebab-case summary
2. **Write the review file** with context, questions, and `**Your answer**:` placeholders
3. **Run the watch script**: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-for-review.sh <file_path>`
4. **Read the updated file** after the script exits, then continue based on answers.

## Phase Audit (orchestrated mode only)

Before starting implementation, validate `.orchestration.json` in the worktree root is active (not stale from a prior run), then update the phase status:
```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
if bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-orchestration.sh "$WORKTREE_ROOT"; then
  STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
  STATUS_FILE=$(python3 -c "import json; d=json.load(open('$WORKTREE_ROOT/.orchestration.json')); import os; print(os.path.join(d['orchestration_dir'], 'status.json'))")
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" implement started_at
fi
```

**Note**: Only call `implement started_at` on the **first invocation** (when no phases have checkmarks yet). If resuming from a previous phase (checkmarks already exist), skip this call since the implement phase is already in progress.

## Getting Started

When given a plan path, spawn a single `general-purpose` setup Task to gather context in an isolated subagent. The Task prompt should include:
- The plan file path to read FULLY
- Instructions to also read ALL files mentioned in the plan (no limit/offset - full reads)
- Instructions to check for existing checkmarks (`- [x]`) to identify completed work
- Instructions to analyze how the pieces fit together

The Task should return:
- **Plan Summary**: Overview of what the plan implements, total phases, current progress
- **Phase Status**: Which phases are complete (checkmarked) vs remaining
- **Files Analyzed**: Each file mentioned in the plan with a brief summary of its current state
- **Starting Point**: Which phase/step to begin with and why
- **Key Context**: Important patterns, conventions, or constraints discovered in the files

After the setup Task completes, create a todo list from its output to track your progress, then start implementing phase by phase.

If no plan path provided, ask for one.

## Implementation Philosophy

Plans are carefully designed, but reality can be messy. Your job is to:
- Follow the plan's intent while adapting to what you find
- Implement each phase fully before moving to the next
- Verify your work follows respective patterns in the broader codebase context
- Update checkboxes in the plan as you complete sections

When things don't match the plan exactly, think about why and communicate clearly. The plan is your guide, but your judgment matters too.

## Phase Execution: Assemble, Implement, Verify

Each phase of the plan is its own mission with its own challenges. Before beginning a phase, assemble a fresh team of agents tailored to that phase's specific needs.

### 1. Phase roster assembly (contained discovery Task)

Before starting each phase, spawn a single `general-purpose` Task to design the ideal constellation of agents for THIS specific phase. Pass it:
- The full plan context from the setup Task (plan summary, files analyzed, key context)
- The specific phase you're about to implement — its changes, files involved, success criteria
- What was learned from previous phases (if any) — surprises encountered, patterns that emerged, assumptions that proved wrong

Instruct it to:

   Based on this phase's scope, design an appropriately-sized roster:

   SIMPLE phase (1-2 files, single concern):
     → 2-3 agents max. Skip FOALED framework scan. Pick the 2-3 most obvious specialties.

   STANDARD phase (3-10 files, a few systems):
     → 3-4 agents. Brief agent directory scan. FOALED as inspiration, not prescription.

   COMPLEX phase (multi-system, architectural, external integrations):
     → Full roster assembly as currently designed. FOALED framework fully engaged.

- Study this phase's specific changes, the files it touches, the integration points it creates, and the verification it demands — deeply enough to understand what kinds of expertise and perspective would catch problems early, surface hidden risks, and ensure the highest quality execution of THIS phase specifically
- Scan `~/.claude/agents/`, `./.claude/agents/`, and the project's `.claude/agents/` directory (if any exist) for available agent definitions that might contribute to this phase
- Draw inspiration from `docs/foaled-agents/` (the FOALED personality framework: Fighter, Operator, Accomplisher, Leader, Engineer, Developer with their four thinking methodologies) — but treat these as just one palette among limitless possibilities. The FOALED types are a starting point, not a ceiling.
- Think far beyond conventional software roles. A database migration phase might need a data archaeologist who understands how schema changes ripple through years of accumulated state, a traffic controller who sequences operations so nothing collides, and a demolition expert who knows which walls are load-bearing. An API integration phase might need a diplomat who negotiates between two systems with different assumptions, a customs inspector who validates everything crossing the boundary, and a stress tester who finds the breaking point before users do. A UI phase might need a stage designer who understands how visual hierarchy guides attention, a accessibility advocate who experiences the interface through different abilities, and a performance choreographer who ensures smooth motion under constrained resources. The best agents for THIS phase might not exist in any template — define them from scratch based on what this specific work demands.
- Prioritize cognitive diversity across multiple dimensions: attention style (big-picture integration vs fine-grained detail), risk posture (what could go wrong vs what could go right vs what's most likely), verification philosophy (trust-but-verify vs prove-it-first vs test-in-production), and temperament (methodical sequencer vs adaptive improviser vs pattern-matching troubleshooter)
- Seek productive tension — agents whose instincts naturally complement each other during execution. A phase roster that all works the same way will miss the same things. A roster with genuine diversity of craft catches what any single approach would overlook.
- Ensure coverage of both depth (mastery of the phase's core technical domains) and breadth (awareness of second-order effects — performance implications, user experience impact, operational burden, security surface area — that focused implementers tend to defer)
- Every agent must be able to work autonomously and asynchronously in parallel, each contributing their unique lens independently

The Task should return:
- **Available Agents**: Any existing agent definitions found in `~/.claude/agents/`, `./.claude/agents/`, or the project's `.claude/agents/` relevant to this phase, with notes on what each would contribute
- **Recommended Roster**: A curated list of agents uniquely suited to THIS specific phase. For each:
  - **Name**: A distinctive, evocative identifier that captures their essence
  - **Perspective**: The unique angle they bring that no other agent on the roster covers
  - **Thinking style**: How they approach implementation — their methodology, temperament, and cognitive mode
  - **Phase-specific value**: The specific gap they fill or blind spot they illuminate for THIS phase's work
  - **Agent type**: Whether to use an existing agent definition or spawn as `general-purpose` with a tailored prompt describing their perspective
- **Roster Rationale**: Why this particular combination produces higher quality implementation of this phase than any subset would — what vigilance emerges from their combined attention that none could sustain alone

Use the roster output to inform which agents you spawn for debugging, verification, or exploration tasks during that phase's implementation. When the phase completes, the roster dissolves — the next phase gets its own team assembled fresh for its own challenges.

### 2. Spawn the implementation team

- Identify the **first unchecked phase** — that is your current phase
- Create a todo list with only the steps for the **current phase** (not all remaining phases)
- Spawn the recommended roster using an agent-team with `CreateTeam()`
- Assign tasks to respective team members to start implementing in parallel 

#### If you encounter a mismatch in understanding, instruct team agents to do the following:

- STOP and think deeply about why the plan can't be followed

- FIRST, ask other team agents for recommendations 

- SECOND, if recommendations must require human input

  - Write a review file at `~/.autorun/review/YYYY-MM-DD-HHMMSS-plan-mismatch.md`:

  ```markdown
  # Review: Plan Mismatch in Phase [N]
  
  ## Context
  Implementing plan: `[plan path]`
  Hit a mismatch that needs your input.
  
  ## Issue
  
  ### Expected (from plan)
  [what the plan says]
  
  ### Found (in codebase)
  [actual situation]
  
  ### Why This Matters
  [explanation of impact]
  
  ## How should I proceed?
  Options:
  1. [Option A - e.g., adapt the plan to match reality]
  2. [Option B - e.g., fix the codebase to match the plan]
  3. [Option C - e.g., skip this part]
  
  **Your answer**:
  ```


---

  *Edit this file with your answers and save. The process will continue automatically.*

  ```
- Run the watch script, then read the updated file to get guidance

## Phase Verification: Assemble a Testing Team

After implementing a phase's changes, run the plan's automated success criteria first (usually `make check test`), fix any failures, then assemble a fresh verification team before declaring the phase complete.

### 2. Verification roster assembly (contained discovery Task)

After automated checks pass, spawn a single `general-purpose` Task to design the ideal constellation of testing and verification agents for what THIS phase just built. Pass it:
- What was implemented in this phase — the changes made, files touched, integrations created
- The phase's success criteria (both automated and manual) from the plan
- The automated check results (what passed, what was fixed)
- Any concerns or edge cases that surfaced during implementation
Instruct it to:

- Study what was just built — the new code paths, the boundaries it crosses, the assumptions it makes, the ways it could fail — deeply enough to understand what kinds of testing expertise would expose problems before they reach users
- Scan `~/.claude/agents/`, `./.claude/agents/`, and the project's `.claude/agents/` directory (if any exist) for available agent definitions suited to verification. The `manual-test-runner` agent (`~/.claude/agents/manual-test-runner.md`) should almost always be included — it specializes in executing step-by-step testing procedures with precision, handling interactive sessions, API testing, browser-based verification via Chrome DevTools, and producing structured pass/fail reports.
- Draw inspiration from `docs/foaled-agents/` (the FOALED personality framework) — but treat these as just one palette among limitless possibilities for verification perspectives.
- Think far beyond conventional QA roles. A verification team for a database migration might need a data integrity auditor who checks every row survived the journey, a rollback rehearser who proves the undo path works before anyone needs it, and a performance profiler who measures whether the new schema still handles peak load. A verification team for an API change might need a contract enforcer who validates every response against the documented schema, a chaos monkey who sends malformed requests to find what breaks, and a backwards-compatibility detective who checks whether existing clients still work. A verification team for a UI change might need a screen reader narrator who experiences the interface without sight, a slow-connection simulator who reveals what happens when assets take seconds to load, and a state archaeologist who navigates every possible sequence of user actions to find orphaned states. The best verification agents for THIS phase might not exist in any template — define them from the specific risks this implementation introduces.
- Prioritize diversity of failure imagination: what could go wrong structurally (code correctness, type safety, logic errors), operationally (performance, reliability, resource usage), experientially (user-facing behavior, error messages, edge cases), and systemically (integration effects, side effects on other components, data consistency)
- Seek complementary verification styles — agents who test at different levels of abstraction, from unit-level precision to end-to-end journey validation. A verification team that only runs unit tests misses integration failures. A team that only does smoke tests misses subtle regressions.
- Every agent must be able to verify independently and in parallel, each probing from their own angle

The Task should return:
- **Available Agents**: Existing agent definitions suited to verification, with notes on what each tests
- **Recommended Verification Roster**: A curated list of testers uniquely suited to verifying THIS phase. For each:
  - **Name**: A distinctive identifier that captures their verification specialty
  - **What they test**: The specific aspect of the implementation they probe
  - **How they test**: Their methodology — what commands they run, what they inspect, what they compare
  - **What failure looks like**: The specific problems they're designed to catch
  - **Agent type**: Whether to use an existing agent definition (like `manual-test-runner`) or spawn as `general-purpose` with a tailored verification prompt
- **Coverage Map**: What aspects of the phase's implementation each agent covers, ensuring no significant risk goes unexamined
- **Chrome DevTools integration**: Any success criteria item that involves a browser, UI, API response, or visual output should be verified using the Chrome DevTools MCP tools (screenshots, DOM inspection, network requests, console errors). Do not skip browser verification for UI changes — this is now fully automatable.
- The `manual-test-runner` agent should be removed from the roster only when the phase is entirely non-UI (pure data migration, CLI tooling, background jobs with no browser-observable output).

---

### 3. Spawn the verification team

**CRITICAL — File-based output to preserve context window:**
Before spawning verification agents, create a scratch directory for this phase's verification:
```
mkdir -p ~/.autorun/plans/.scratch/YYYY-MM-DD-description/phase-N-verify/
```
(Use the plan's date-description slug and the current phase number.)

**Every verification agent prompt MUST include these instructions:**
- Write your complete verification results to `~/.autorun/plans/.scratch/YYYY-MM-DD-description/phase-N-verify/{agent-name}.md`
- Include all commands run, their output, pass/fail status, and detailed analysis in the file
- Return ONLY: (1) the file path you wrote to, (2) PASS or FAIL, and (3) a 1-2 sentence summary
- Do NOT return your full results as text — write them to the file instead

Using the roster output, spawn all verification agents in parallel. Each agent should receive:
- A description of what was implemented and where (files, line ranges, endpoints)
- Their specific verification mission from the roster
- The plan's success criteria relevant to their area
- Their scratch file path for writing results
- Access to run commands, read files, and use browser tools as needed

Wait for all verification agents to complete. You should now have only PASS/FAIL + short summaries in context.

**If any agent reported FAIL**, spawn a single `general-purpose` synthesis Task to read the failing agents' scratch files and produce a consolidated issues report. Fix the issues, then re-run the relevant verification agents.

**If all agents reported PASS**, spawn a single `general-purpose` synthesis Task to read all scratch files and produce a brief verification summary at `~/.autorun/plans/.scratch/YYYY-MM-DD-description/phase-N-verify/_summary.md`. It should return ONLY the file path and a 1-2 sentence confirmation.

---

### 4. Update progress and proceed

After the verification team's findings are resolved:
- Update your progress in both the plan and your todos
- Check off completed verification items in the plan file itself using Edit
- If the plan has manual verification steps for this phase, use `@agents/manual-test-runner.md` to execute them — include pass/fail results in the verification summary and check them off once passed
- If everything passed cleanly and there are no outstanding questions, concerns, or unresolved issues, **chain to the next phase in a new tmux window** (see "Chain to next phase" below)
- **Only pause for human input via review file** if the `@agents/manual-test-runner.md` surfaces failures that require human judgment, or there are blockers you can't resolve on your own. In those cases, write a review file at `~/.autorun/review/YYYY-MM-DD-HHMMSS-phase-N-verification.md`:
  ```markdown
  # Review: Phase [N] - Human Input Needed

  ## Context
  Phase [N] of plan `[plan path]` is complete. Automated checks and agent verification passed.

  ## Verification Summary
  - [x] [Automated check 1]: passed
  - [x] [Automated check 2]: passed
  - [Agent name]: [what they verified and found]

  ## Why I'm Pausing
  [Explain specifically what needs human input — unresolved failures from @agents/manual-test-runner.md, or blockers]

  ### 1. [Item needing human input]
  **Your answer/result**:


---
  *Edit this file with your answers and save. The process will continue automatically.*
  ```

  Run the watch script, then read the updated file to get results.

### Chain to next phase

When a phase is complete (all verification passed, progress updated, no human input needed or human input resolved), **chain to the next phase in a fresh session** rather than continuing in the current context.

First, determine if there ARE more unchecked phases remaining in the plan. If all phases are complete (every phase checkbox is checked), determine the `chain_on_complete` value:

1. Check the plan's YAML frontmatter for a `chain_on_complete` field
2. If not found in frontmatter, check `.orchestration.json` in the worktree root as a fallback:
   ```bash
   WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
   if [[ -f "$WORKTREE_ROOT/.orchestration.json" ]]; then
     CHAIN_ON_COMPLETE=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json')).get('chain_on_complete', ''))")
   fi
   ```

- **If `chain_on_complete` was found** (from either source): This plan is part of a staged orchestration. Chain to the specified command instead of re-running implement_plan. For example, `chain_on_complete: "/autorun:merge ~/.autorun/orchestration/wave-2-master-plan 3"` means this stage is done and should trigger the merge workflow.
- **If no `chain_on_complete` from either source**: The plan is standalone and all work is done. Print a completion summary and stop.

**Before chaining**, commit all changes from this phase:

1. Stage only the files you changed (do NOT use `git add -A`):
   ```bash
   git add <file1> <file2> ...
  ```
2. Commit with a message describing the phase work:
   ```bash
   git commit -m "phase N: <brief description of what was implemented>"
   ```

**If unchecked phases remain**, chain directly using Bash (do NOT spawn a Task for this — run it yourself):

1. Detect the tmux session name, window name, and determine the next phase number (`NEXT` = the phase number you're chaining TO):
   ```bash
   WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
   SESSION_ARG=""
   WINDOW_NAME="ip-p${NEXT}"
   CLOSE_ARG=""
   if [[ -f "$WORKTREE_ROOT/.orchestration.json" ]]; then
     SESSION_ARG=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json')).get('session_name', ''))")
     STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
     WINDOW_NAME="s${STAGE_NUM}-ip-p${NEXT}"
     CLOSE_ARG="close"
   fi
   echo "Session: '${SESSION_ARG:-<none>}', Window: '$WINDOW_NAME'"
   ```
2. Run chain-next.sh directly via Bash (substitute the actual plan path and NEXT phase number):
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:implement_plan <plan-path>" "$WINDOW_NAME" "$SESSION_ARG" "" "$CLOSE_ARG"
   ```
3. The new tmux window reads the plan, finds existing checkmarks, and picks up from the first unchecked phase.

**If all phases are complete and chaining to `chain_on_complete`**, chain directly using Bash (do NOT spawn a Task):

1. Detect session name and window name:
   ```bash
   WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
   SESSION_ARG=""
   WINDOW_NAME="merge"
   CLOSE_ARG=""
   if [[ -f "$WORKTREE_ROOT/.orchestration.json" ]]; then
     SESSION_ARG=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json')).get('session_name', ''))")
     STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
     WINDOW_NAME="s${STAGE_NUM}-merge"
     CLOSE_ARG="close"

     # Update phase status — implement is complete
     STATUS_FILE=$(python3 -c "import json; d=json.load(open('$WORKTREE_ROOT/.orchestration.json')); import os; print(os.path.join(d['orchestration_dir'], 'status.json'))")
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" implement completed_at
   fi
   echo "Session: '${SESSION_ARG:-<none>}', Window: '$WINDOW_NAME'"
   ```
2. Run chain-next.sh directly via Bash:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "<chain_on_complete value>" "$WINDOW_NAME" "$SESSION_ARG" "" "$CLOSE_ARG"
   ```

This gives each phase a fresh context window and clean state.


## If You Get Stuck

When something isn't working as expected:
- First, make sure you've read and understood all the relevant code
- Consider if the codebase has evolved since the plan was written
- Write a review file describing the issue and asking for guidance (use the review file pattern above)

Use sub-tasks sparingly - mainly for targeted debugging or exploring unfamiliar territory.

## Resuming Work

If the plan has existing checkmarks:
- Trust that completed work is done
- Pick up from the first unchecked item
- Verify previous work only if something seems off

Remember: You're implementing a solution, not just checking boxes. Keep the end goal in mind and maintain forward momentum.
