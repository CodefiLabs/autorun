---
description: Create detailed implementation plans in ~/.autorun/plans/ through interactive research
model: opus
---

# Implementation Plan

You are tasked with creating detailed implementation plans through an interactive, iterative process. You should be skeptical, thorough, and work collaboratively with the user to produce high-quality technical specifications.

## Review File Pattern (How to Ask Questions)

**CRITICAL**: Whenever you need to ask the user questions, present options, or request feedback, you MUST use the review file pattern instead of asking directly in the console:

1. **Create a review file** at `~/.autorun/review/YYYY-MM-DD-HHMMSS-summary.md`
   - Ensure directory exists: `mkdir -p ~/.autorun/review`
   - Use current timestamp and a brief kebab-case summary
   - Example: `2025-01-08-143022-initial-questions.md`

2. **Write the review file** with this structure:
   ```markdown
   # Review: [Brief Summary]
   
   ## Context
   [Brief context about what stage of planning we're at and what you've found so far]
   
   ## Questions / Feedback Requested
   
   ### 1. [Topic]
   [Question details, options, or findings to review]
   
   **Your answer**:


   ### 2. [Topic]
   [Question details]

   **Your answer**:


---
   *Edit this file with your answers and save. The process will continue automatically.*
   ```

3. **Run the watch script** to open the file and wait for edits:
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-for-review.sh ~/.autorun/review/YYYY-MM-DD-HHMMSS-summary.md
   ```

4. **Read the updated file** after the script exits, then continue based on the user's answers.

**Naming convention for review files:**
- *-plan-review.md` - When the draft plan is ready for review
- `*-clarifications.md` - When follow-up questions arise

## Phase Audit (orchestrated mode only)

Before starting planning, validate `.orchestration.json` in the worktree root is active (not stale from a prior run), then update the phase status:
```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
if bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-orchestration.sh "$WORKTREE_ROOT"; then
  STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
  STATUS_FILE=$(python3 -c "import json; d=json.load(open('$WORKTREE_ROOT/.orchestration.json')); import os; print(os.path.join(d['orchestration_dir'], 'status.json'))")
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" create_plan started_at
fi
```

## Initial Response

When this command is invoked:

1. **Check if parameters were provided**:
   - If a file path or task description was provided as a parameter, skip the default message
   - Immediately read any provided files FULLY
   - Begin the research process

## Handoff Detection

When this command is invoked with arguments:

1. **Check if the argument is a handoff file path** — does it match `~/.autorun/research/.handoff/*.md`?
2. **If handoff provided**:
   - Read the handoff file fully
   - Read the synthesis document referenced in the handoff's "## Synthesis Path" section
   - Skip Step 1 (context gathering), Step 1.2 (roster assembly), and the research portion of Step 1.3 entirely
   - Proceed directly to Step 3 (Detailed Plan Writing) using the synthesis as input
   - **Exception**: If during plan writing the synthesis lacks specific detail needed (exact function signatures, test patterns, edge cases), spawn 1-2 targeted research agents for that specific gap — but do NOT re-run the full research suite
3. **If no handoff** (plain text task description or file path that's not a handoff):
   - Run the full research process as currently designed

## Process Steps

### Step 1: Context Gathering & Initial Analysis

1. **Initial file reading (contained setup Task)**:

   Spawn a single `general-purpose` Task to read and analyze all mentioned files in an isolated context. The Task prompt should include:
   - The list of ALL files mentioned by the user (task descriptions, research docs, plans, JSON files)
   - Instructions to read each file FULLY (no limit/offset) and extract: purpose, key requirements, constraints, relevant code paths
   - Instructions to cross-reference requirements across files and assess scope
   - A required output format returning: files read (with summaries), consolidated requirements, key discoveries, scope assessment, assumptions needing verification, and suggested areas for deeper codebase research

   Wait for the setup Task to complete before proceeding.

2. **Agent roster assembly (contained discovery Task)**:

   Spawn a single `general-purpose` Task to design the ideal constellation of agents for this specific planning mission. Pass it the full output from the setup Task — the consolidated requirements, key discoveries, scope assessment, and suggested research areas — and instruct it to:

   Based on this task's scope, design an appropriately-sized roster:

   SIMPLE scope (1-2 files, single concern):
     → 2-3 agents max. Skip FOALED framework scan. Pick the 2-3 most obvious specialties.
     → No need to scan agent directories — use general-purpose with focused prompts.

   STANDARD scope (3-10 files, a few systems):
     → 3-4 agents. Brief agent directory scan. FOALED as inspiration, not prescription.
     → One distinctive perspective beyond obvious roles (not six).

   COMPLEX scope (multi-system, architectural, external integrations):
     → Full roster assembly as currently designed. FOALED framework fully engaged.
     → 4-6 agents with genuine cognitive diversity.

   - Study the mission's subject matter, domains, and challenges deeply enough to understand what kinds of expertise and perspective would produce the most thorough, well-considered implementation plan
   - Scan `~/.claude/agents/`, `./.claude/agents/`, and the project's `.claude/agents/` directory (if any exist) for available agent definitions that might contribute
   - Draw inspiration from `docs/foaled-agents/` (the FOALED personality framework: Fighter, Operator, Accomplisher, Leader, Engineer, Developer with their four thinking methodologies) — but treat these as just one palette among limitless possibilities. The FOALED types are a starting point, not a ceiling.
   - Think far beyond conventional software roles. The most valuable perspective for planning an implementation might come from a structural engineer who understands load-bearing walls you can't move, a chess grandmaster who thinks several moves ahead, a trial lawyer who anticipates every counterargument before it's made, a logistics coordinator who sees bottlenecks before they form, a film editor who knows what to cut to make the story stronger, a wilderness guide who reads terrain and chooses routes that avoid hazards, an ER triage nurse who knows what to prioritize when everything seems urgent, or a bridge builder who understands both shores before starting construction. The best agent for this planning mission might not exist in any template — define it from scratch based on what THIS plan needs.
   - Prioritize cognitive diversity across multiple dimensions: time horizon (immediate implementation detail vs long-term maintenance implications), risk orientation (optimistic pathfinder vs cautious risk-mapper vs pragmatic trade-off navigator), scale (individual code changes vs module integration vs system-wide architecture), and temperament (meticulous planner vs creative problem-solver vs skeptical assumption-challenger vs empathetic user-advocate)
   - Seek productive tension — agents whose perspectives naturally challenge and sharpen each other's thinking. A planning roster that all sees the same risks produces blind spots. A roster with genuine diversity of foresight catches what any single viewpoint would miss.
   - Ensure coverage of both depth (deep expertise in the plan's core technical domains) and breadth (unexpected angles — business impact, user experience, operational burden, future maintainability — that pure technical planners overlook)
   - Every agent must be able to work autonomously and asynchronously in parallel, each contributing their unique lens independently

   The Task should return:
   - **Available Agents**: Any existing agent definitions found in `~/.claude/agents/`, `./.claude/agents/`, or the project's `.claude/agents/` relevant to this mission, with notes on what each would contribute
   - **Recommended Roster**: A curated list of agents uniquely suited to THIS specific planning mission. For each:
     - **Name**: A distinctive, evocative identifier that captures their essence
     - **Perspective**: The unique angle they bring that no other agent on the roster covers
     - **Thinking style**: How they approach planning — their methodology, temperament, and cognitive mode
     - **Mission-specific value**: The specific gap they fill or blind spot they illuminate for THIS plan
     - **Agent type**: Whether to use an existing agent definition or spawn as `general-purpose` with a tailored prompt describing their perspective
     - **Write Access**: These agents should be able to Write their research findings to files
   - **Roster Rationale**: Why this particular combination produces a more robust plan than any subset would — what foresight emerges from their combined perspectives that none could produce alone

   Use the roster output to inform which agents you spawn in the next step and how you prompt them.

3. **Spawn research tasks to gather deeper context**:

   **CRITICAL — File-based output to preserve context window:**
   Before spawning agents, create a scratch directory for this planning session:
   ```
   mkdir -p ~/.autorun/plans/.scratch/YYYY-MM-DD-description/
   ```
   (Use the same date-description slug you'll use for the final plan.)

   **Every research agent prompt MUST include these instructions:**
   - Write your complete findings to `~/.autorun/plans/.scratch/YYYY-MM-DD-description/{agent-name}.md`
   - Include all file paths, line numbers, code snippets, and detailed analysis in the file
   - Return ONLY: (1) the file path you wrote to, and (2) a 1-2 sentence summary of what you found
   - Do NOT return your full findings as text — write them to the file instead

   Using the setup Task's suggested research areas, spawn specialized agents in parallel:

   - Use the **codebase-locator** agent to find all files related to the task
   - Use the **codebase-analyzer** agent to understand how the current implementation works
   - Use the **web-researcher**, **perplexity-researcher**, and **deepwiki-researcher** for external documentation and resources
   - If relevant, use the **thoughts-finder** agent to find any existing thoughts documents about this feature
   These agents will:
   - Find relevant source files, configs, and tests
   - Identify the specific directories to focus on (e.g., if WUI is mentioned, they'll focus on humanlayer-wui/)
   - Trace data flow and key functions
   - Write detailed explanations with file:line references to their scratch file

4. **Synthesize research via contained Task**:
   - You should now have only short summaries + file paths in your context (not full research content)
   - Spawn a single `general-purpose` **synthesis Task** and pass it:
     - The scratch directory path: `~/.autorun/plans/.scratch/YYYY-MM-DD-description/`
     - The list of scratch file paths returned by research agents
     - The 1-2 sentence summaries from each agent
     - The consolidated requirements from the setup Task
     - Instructions to read ALL scratch files, cross-reference findings with the requirements, and produce a consolidated research brief
   - The synthesis Task should:
     - Read every scratch file in the directory
     - Cross-reference the task requirements with actual code findings
     - Identify any discrepancies or misunderstandings
     - Note assumptions that need verification
     - Determine true scope based on codebase reality
     - Write a **consolidated research brief** to `~/.autorun/plans/.scratch/YYYY-MM-DD-description/_synthesis.md`
     - Return ONLY: the synthesis file path and a brief summary of key findings, scope assessment, and any open questions

5. **Only if the synthesis surfaces genuine questions that research couldn't answer**, create a review file at `~/.autorun/review/YYYY-MM-DD-HHMMSS-initial-questions.md` using the review file pattern above. Only ask questions requiring human judgment (business logic, design preferences, ambiguous requirements). If the synthesis answered everything, skip this and proceed directly to Step 2.

### Step 2: Research & Discovery

After initial analysis (and any clarifications if needed):

1. **If the user corrects any misunderstanding**:
   - DO NOT just accept the correction
   - Spawn new research tasks to verify the correct information
   - Read the specific files/directories they mention
   - Only proceed once you've verified the facts yourself

2. **Create a research todo list** using TodoWrite to track exploration tasks

3. **Spawn parallel sub-tasks for comprehensive research**:
   - Create multiple Task agents to research different aspects concurrently
   - Use the same scratch directory from Step 1: `~/.autorun/plans/.scratch/YYYY-MM-DD-description/`
   - **Every agent prompt MUST include the file-based output instructions** (write to scratch file, return only path + 1-2 sentence summary)
   - Use the right agent for each type of research:

   **For deeper investigation:**
   - **codebase-locator** - To find more specific files (e.g., "find all files that handle [specific component]")
   - **codebase-analyzer** - To understand implementation details (e.g., "analyze how [system] works")
   - **pattern-finder** - To find similar features we can model after

   **For historical context:**
   - **thoughts-finder** - To find any research, plans, or decisions about this area
   - **thoughts-reader** - To extract key insights from the most relevant documents

   **For web research:**
   
   - **deepwiki-researcher** - for in depth documentation and resources on specific public GitHub repositories
   - **perplexity-researcher** - for in depth documentation on resources without public GitHub repositories
   
   Each agent knows how to:
   - Find the right files and code patterns
   - Identify conventions and patterns to follow
   - Look for integration points and dependencies
   - Write specific file:line references to their scratch file
   - Find tests and examples
   
3. **Synthesize second-round research via contained Task**:
   - Spawn a single `general-purpose` synthesis Task with the scratch directory, new file paths, and summaries
   - It should read all scratch files (including any from Step 1), synthesize into a consolidated brief
   - Write the updated synthesis to `~/.autorun/plans/.scratch/YYYY-MM-DD-description/_synthesis.md`
   - Return ONLY: the file path and a brief summary of key findings and design options

4. **Only if the synthesis surfaces genuinely ambiguous design decisions** (multiple valid approaches where picking wrong would be costly, or unclear requirements that research couldn't resolve), create a review file at `~/.autorun/review/YYYY-MM-DD-HHMMSS-design-decisions.md` using the review file pattern. Otherwise, make the best decision based on research and proceed directly to Step 3. Do NOT ask for approval of phasing, structure, or anything you can reasonably decide yourself.

### Step 3: Detailed Plan Writing

Once aligned on approach:

1. **Write the plan via contained Task**: Spawn a single `general-purpose` Task to write the plan. Pass it:
   - The synthesis file path: `~/.autorun/plans/.scratch/YYYY-MM-DD-description/_synthesis.md`
   - The user's answers from any review files
   - The plan output path and template (below)
   - The orchestration context check instructions (below)

   The Task should read the synthesis file, apply the user's design decisions, and write the final plan.
   It should return ONLY: the plan file path and a 2-3 sentence summary of what the plan covers.

   After the Task completes, clean up scratch files: `rm -rf ~/.autorun/plans/.scratch/YYYY-MM-DD-description/`

2. **Check for orchestration context**: Before writing the plan, check if `.orchestration.json` exists in the current working directory (the worktree root):
   ```bash
   if [[ -f "$(pwd)/.orchestration.json" ]]; then
     # Read the orchestration metadata
     ORCH_DATA=$(cat "$(pwd)/.orchestration.json")
     # Extract chain_on_complete value
     CHAIN_ON_COMPLETE=$(python3 -c "import json; print(json.load(open('$(pwd)/.orchestration.json'))['chain_on_complete'])")
   fi
   ```
   If found, the plan is part of a staged orchestration. You MUST include `chain_on_complete` in the plan's YAML frontmatter (see template below).

2. **Write the plan** to `~/.autorun/plans/YYYY-MM-DD-description.md`
   - Ensure the directory exists: `mkdir -p ~/.autorun/plans`
   - Format: `YYYY-MM-DD-description.md` where:
     - YYYY-MM-DD is today's date
     - description is a brief kebab-case description
   - Example: `2025-01-08-improve-error-handling.md`
   - **If orchestration context was found**, add YAML frontmatter to the plan file:
     ```yaml
     ---
     chain_on_complete: "/autorun:merge ~/.autorun/orchestration/<plan-name> <stage-number>"
     ---
     ```
     This tells `implement_plan` to chain to `merge.md` when all phases are complete, instead of just stopping.

3. **Use this template structure**:

````markdown
# [Feature/Task Name] Implementation Plan

## Overview

[Brief description of what we're implementing and why]

## Current State Analysis

[What exists now, what's missing, key constraints discovered]

## Desired End State

[A Specification of the desired end state after this plan is complete, and how to verify it]

### Key Discoveries:
- [Important finding with @file:line reference]
- [Pattern to follow]
- [Constraint to work within]

## What We're NOT Doing

[Explicitly list out-of-scope items to prevent scope creep]

## Implementation Approach

[High-level strategy and reasoning]

## Phase 1: [Descriptive Name]

### Overview
[What this phase accomplishes]

### Changes Required:

#### 1. [Component/File Group]
**File**: @path/to/file.ext
**Changes**: [Summary of changes]

```[language]
// Specific code to add/modify
```

### Success Criteria:

#### Automated Verification:
- [ ] Migration applies cleanly: `make migrate`
- [ ] Unit tests pass: `make test-component`
- [ ] Type checking passes: `npm run typecheck`
- [ ] Linting passes: `make lint`
- [ ] Integration tests pass: `make test-integration`

#### Manual Verification (executed by `@agents/manual-test-runner.md`):
- [ ] Feature works as expected when tested via UI
- [ ] Performance is acceptable under load
- [ ] Edge case handling verified
- [ ] No regressions in related features

**Implementation Note**: After completing this phase and all automated verification passes, use `@agents/manual-test-runner.md` to execute the manual verification steps before proceeding to the next phase.

---

## Phase 2: [Descriptive Name]

[Similar structure with both automated and manual success criteria...]

---

## Testing Strategy

### Unit Tests:
- [What to test]
- [Key edge cases]

### Integration Tests:
- [End-to-end scenarios]

### Manual Testing Steps:
1. [Specific step to verify feature]
2. [Another verification step]
3. [Edge case to test manually]

## Performance Considerations

[Any performance implications or optimizations needed]

## Migration Notes

[If applicable, how to handle existing data/systems]

## References

- Related research: @~/.autorun/research/[relevant].md
- Similar implementation: @[file:line]
````

### Step 5: Review (contained Task, RARELY needed)

**CRITICAL: Do NOT use this step for approval-seeking questions** like "does this phasing look good?" or "are you happy with this approach?" — those block the chain-next.sh pipeline. Make your best judgment and move on.

**Only use this step if there is a genuinely ambiguous requirement or a high-stakes design decision** where picking wrong would be costly and research couldn't resolve it. Examples of valid questions:
- "The requirements mention 'real-time sync' — do you mean WebSockets, SSE, or polling? This fundamentally changes the architecture."
- "Should we keep backward compatibility with the v1 API or is a breaking change acceptable?"

Examples of questions you must NOT ask (just decide):
- "Does this phasing look good?"
- "Are you comfortable with this approach?"
- "Should I proceed?"
- "Which of these two similar approaches do you prefer?" (just pick the better one)

If you do need to ask, spawn a `general-purpose` Task to write a review file at `~/.autorun/review/YYYY-MM-DD-HHMMSS-plan-clarifications.md`, run the watch script, read the response, and update the plan.

If there are no genuinely blocking questions (which should be the common case), skip this step entirely and proceed to Step 6.

### Step 6: Chain to implementation

**Before chaining**, commit all changes from this phase (the plan file and any supporting files):

1. Stage only the files you changed (do NOT use `git add -A`):
   ```bash
   git add <plan-file> <other-files-if-any>
   ```
2. Commit:
   ```bash
   git commit -m "create plan: <brief description>"
   ```

Then chain directly using Bash (do NOT spawn a Task for this — run it yourself):

1. Detect the tmux session name and window name:
   ```bash
   WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
   SESSION_ARG=""
   WINDOW_NAME="ip"
   CLOSE_ARG=""
   if [[ -f "$WORKTREE_ROOT/.orchestration.json" ]]; then
     SESSION_ARG=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json')).get('session_name', ''))")
     STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
     WINDOW_NAME="s${STAGE_NUM}-ip"
     CLOSE_ARG="close"

     # Update phase status
     STATUS_FILE=$(python3 -c "import json; d=json.load(open('$WORKTREE_ROOT/.orchestration.json')); import os; print(os.path.join(d['orchestration_dir'], 'status.json'))")
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" create_plan completed_at
   fi
   echo "Session: '${SESSION_ARG:-<none>}', Window: '$WINDOW_NAME'"
   ```
2. Run chain-next.sh directly via Bash (substitute the actual plan path):
   ```bash
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:implement_plan <plan-path>" "$WINDOW_NAME" "$SESSION_ARG" "" "$CLOSE_ARG"
   ```

## Important Guidelines

0. **Protect the Context Window**:
   - All research agents write findings to scratch files, return only paths + 1-2 sentence summaries
   - Synthesis and plan writing happen in contained Tasks that read from those files
   - The main thread should never hold full research content — only summaries and file paths
   - Clean up scratch files after the plan is written

1. **Be Skeptical**:
   - Question vague requirements
   - Identify potential issues early
   - Ask "why" and "what about"
   - Don't assume - verify with code

2. **Be Autonomous by Default, Interactive Only When Blocked**:
   - Write the full plan using your best judgment from research
   - Only use the review file pattern for genuinely ambiguous requirements or high-stakes design decisions that research couldn't resolve
   - Do NOT pause for approval of phasing, structure, or approach — just decide and proceed
   - The goal is to chain to implementation as fast as possible

3. **Be Thorough**:
   - Read all context files COMPLETELY before planning
   - Research actual code patterns using parallel sub-tasks
   - Include specific file paths and line numbers
   - Write measurable success criteria with clear automated vs manual distinction
   - automated steps should use `make` whenever possible - for example `make -C humanlayer-wui check` instead of `cd humanlayer-wui && bun run fmt`

4. **Be Practical**:
   - Focus on incremental, testable changes
   - Consider migration and rollback
   - Think about edge cases
   - Include "what we're NOT doing"

5. **Track Progress**:
   - Use TodoWrite to track planning tasks
   - Update todos as you complete research
   - Mark planning tasks complete when done

6. **No Open Questions in Final Plan**:
   - If you encounter open questions during planning, STOP
   - Research or ask for clarification immediately
   - Do NOT write the plan with unresolved questions
   - The implementation plan must be complete and actionable
   - Every decision must be made before finalizing the plan

## Success Criteria Guidelines

**Always separate success criteria into two categories:**

1. **Automated Verification** (can be run by execution agents):
   - Commands that can be run: `make test`, `npm run lint`, etc.
   - Specific files that should exist
   - Code compilation/type checking
   - Automated test suites

2. **Manual Verification** (executed by `@agents/manual-test-runner.md`):
   - UI/UX functionality
   - Performance under real conditions
   - Edge cases that are hard to automate
   - User acceptance criteria

**Format example:**
```markdown
### Success Criteria:

#### Automated Verification:
- [ ] Database migration runs successfully: `make migrate`
- [ ] All unit tests pass: `go test ./...`
- [ ] No linting errors: `golangci-lint run`
- [ ] API endpoint returns 200: `curl localhost:8080/api/new-endpoint`

#### Manual Verification (executed by `@agents/manual-test-runner.md`):
- [ ] New feature appears correctly in the UI
- [ ] Performance is acceptable with 1000+ items
- [ ] Error messages are user-friendly
- [ ] Feature works correctly on mobile devices
```

## Common Patterns

### For Database Changes:
- Start with schema/migration
- Add store methods
- Update business logic
- Expose via API
- Update clients

### For New Features:
- Research existing patterns first
- Start with data model
- Build backend logic
- Add API endpoints
- Implement UI last

### For Refactoring:
- Document current behavior
- Plan incremental changes
- Maintain backwards compatibility
- Include migration strategy

## Sub-task Spawning Best Practices

When spawning research sub-tasks:

1. **Spawn multiple tasks in parallel** for efficiency
2. **Each task should be focused** on a specific area
3. **Provide detailed instructions** including:
   - Exactly what to search for
   - Which directories to focus on
   - What information to extract
   - Expected output format
4. **Be EXTREMELY specific about directories**:
   - Include the full path context in your prompts
5. **Specify read-only tools** to use
6. **Request specific file:line references** in responses
7. **Wait for all tasks to complete** before synthesizing
8. **Verify sub-task results**:
   - If a sub-task returns unexpected results, spawn follow-up tasks
   - Cross-check findings against the actual codebase
   - Don't accept results that seem incorrect

Example of spawning multiple tasks:
```python
# Spawn these tasks concurrently:
tasks = [
    Task("Research database schema", db_research_prompt),
    Task("Find API patterns", api_research_prompt),
    Task("Investigate UI components", ui_research_prompt),
    Task("Check test patterns", test_research_prompt)
]
```

## Example Interaction Flow

```
User: /create_plan We need to add caching to the API layer. Here's the requirements doc: docs/caching-requirements.md

[Agent reads requirements file fully, spawns research tasks, waits for results]

[Agent writes ~/.autorun/review/2025-01-08-143022-initial-questions.md with findings and questions]

[Agent runs: bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-for-review.sh ~/.autorun/review/2025-01-08-143022-initial-questions.md]

[Review file opens, user edits answers and saves]

[Watch script detects save, exits]

[Agent reads updated review file, continues with answers]

[Process repeats for research findings, plan structure, and plan review steps]
```
