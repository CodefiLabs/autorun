---
description: Document codebase as-is with research output to ~/.autorun/research/
model: opus
---

# Research Codebase

You are tasked with conducting comprehensive research across the codebase to answer user questions by spawning parallel sub-agents and synthesizing their findings.

## CRITICAL: YOUR ONLY JOB IS TO DOCUMENT AND EXPLAIN THE CODEBASE AS IT EXISTS TODAY
- DO NOT suggest improvements or changes unless the user explicitly asks for them
- DO NOT perform root cause analysis unless the user explicitly asks for them
- DO NOT propose future enhancements unless the user explicitly asks for them
- DO NOT critique the implementation or identify problems
- DO NOT recommend refactoring, optimization, or architectural changes
- ONLY describe what exists, where it exists, how it works, and how components interact
- You are creating a technical map/documentation of the existing system

## Review File Pattern (How to Ask Questions)

**CRITICAL**: Whenever you need to ask the user questions or request input, you MUST use the review file pattern instead of asking directly in the console:

1. **Create a review file** at `~/.autorun/review/YYYY-MM-DD-HHMMSS-summary.md`
   - Ensure directory exists: `mkdir -p ~/.autorun/review`
   - Use current timestamp and a brief kebab-case summary
2. **Write the review file** with context, questions, and `**Your answer**:` placeholders
3. **Run the watch script**: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/watch-for-review.sh <file_path>`
4. **Read the updated file** after the script exits, then continue based on answers.

## Phase Audit (orchestrated mode only)

Before starting research, validate `.orchestration.json` in the worktree root is active (not stale from a prior run), then update the phase status:
```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
if bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-orchestration.sh "$WORKTREE_ROOT"; then
  STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
  STATUS_FILE=$(python3 -c "import json; d=json.load(open('$WORKTREE_ROOT/.orchestration.json')); import os; print(os.path.join(d['orchestration_dir'], 'status.json'))")
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" research started_at
fi
```

## Steps to follow after receiving the research query:

1. **Initial context gathering (contained setup Task)**:

   If the user mentions specific files, spawn a single `general-purpose` setup Task to read and decompose the research question in an isolated context. The Task prompt should include:
   - All files mentioned by the user (tickets, docs, JSON) to read FULLY (no limit/offset)
   - The user's research question/topic
   - Instructions to analyze and decompose the question into composable research areas
   - Instructions to identify specific components, patterns, or concepts to investigate
   - Instructions to consider which directories, files, or architectural patterns are relevant

   The Task should return:
   - **Files Read**: Each file with a brief summary of contents
   - **Research Decomposition**: The question broken into specific, focused research areas
   - **Suggested Agents**: Which specialized agents (codebase-locator, codebase-analyzer, etc.) should investigate which areas
   - **Key Context**: Important details from the files that inform the research direction

   After the setup Task completes, create a research plan using TodoWrite based on its decomposition.

   If no specific files are mentioned, skip the Task and decompose the research question yourself, then create the TodoWrite plan.

2. **Agent roster assembly (contained discovery Task)**:

   After the setup Task (or your own decomposition) completes, spawn a single `general-purpose` Task to design the ideal constellation of agents for this specific research mission. Pass it the full output from step 1 — the decomposed research areas, key context, and any files read — and instruct it to:

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

   - Study the mission's subject matter, domains, and challenges deeply enough to understand what kinds of expertise and perspective would produce the richest, most illuminating documentation of this particular system
   - Scan `~/.claude/agents/`, `./.claude/agents/`, and the project's `.claude/agents/` directory (if any exist) for available agent definitions that might contribute
   - Draw inspiration from `docs/foaled-agents/` (the FOALED personality framework: Fighter, Operator, Accomplisher, Leader, Engineer, Developer with their four thinking methodologies) — but treat these as just one palette among limitless possibilities. The FOALED types are a starting point, not a ceiling.
   - Think far beyond conventional software roles. The most valuable perspective for understanding a system might come from a forensic accountant who traces hidden dependencies, a cartographer who maps uncharted territory and names its features, a field biologist who observes complex ecosystems without disturbing them, a journalist who finds the story buried in facts, a museum curator who knows how to organize knowledge so others can navigate it, an archaeologist who reads layers of decisions in code strata, a detective who follows evidence chains across seemingly unrelated scenes, or a translator who bridges the gap between what code says and what it means. The best agent for this research mission might not exist in any template — define it from scratch based on what THIS investigation needs.
   - Prioritize cognitive diversity across multiple dimensions: time horizon (what does this code look like right now vs how did it evolve vs where is it headed), scale (individual function behavior vs module interactions vs system-wide patterns), modality (structural/architectural vs behavioral/runtime vs narrative/intentional), and temperament (meticulous cataloger vs curious explorer vs pattern-recognizer vs connection-finder)
   - Seek productive tension — agents whose observations naturally complement and enrich each other. A roster that all looks at the same layer produces flat documentation. A roster with genuine diversity of attention produces understanding that reveals what no single perspective could see.
   - Ensure coverage of both depth (thorough investigation of the mission's core areas) and breadth (unexpected angles that surface what domain-focused agents overlook)
   - Every agent must be able to work autonomously and asynchronously in parallel, each contributing their unique lens independently

   The Task should return:
   - **Available Agents**: Any existing agent definitions found in `~/.claude/agents/`, `./.claude/agents/`, or the project's `.claude/agents/` relevant to this mission, with notes on what each would contribute
   - **Recommended Roster**: A curated list of agents uniquely suited to THIS specific research mission. For each:
     - **Name**: A distinctive, evocative identifier that captures their essence
     - **Perspective**: The unique angle they bring that no other agent on the roster covers
     - **Thinking style**: How they approach investigation — their methodology, temperament, and cognitive mode
     - **Mission-specific value**: The specific gap they fill or blind spot they illuminate for THIS research question
     - **Agent type**: Whether to use an existing agent definition or spawn as `general-purpose` with a tailored prompt describing their perspective
     - **Write Access**: These agents should be able to Write their research findings to files
   - **Roster Rationale**: Why this particular combination produces richer documentation than any subset would — what understanding emerges from their combined observations that none could produce alone

   Use the roster output to inform which agents you spawn in the next step and how you prompt them.

3. **Spawn parallel sub-agent tasks for comprehensive research:**

   **CRITICAL — File-based output to preserve context window:**
   Before spawning agents, create a scratch directory for this research session:
   ```
   mkdir -p ~/.autorun/research/.scratch/YYYY-MM-DD-description/
   ```
   (Use the same date-description slug you'll use for the final document.)

   **Every sub-agent prompt MUST include these instructions:**
   - Write your complete findings to `~/.autorun/research/.scratch/YYYY-MM-DD-description/{agent-name}.md`
   - Include all file paths, line numbers, code snippets, and detailed analysis in the file
   - Return ONLY: (1) the file path you wrote to, and (2) a 1-2 sentence summary of what you found
   - Do NOT return your full findings as text — write them to the file instead

   Create multiple Task agents to research different aspects concurrently. We have specialized agents that know how to do specific research tasks:

   **For codebase research:**
   - Use the **codebase-locator** agent to find WHERE files and components live
   - Use the **codebase-analyzer** agent to understand HOW specific code works (without critiquing it)
   - Use the **pattern-finder** agent to find examples of existing patterns (without evaluating them)

   **IMPORTANT**: All agents are documentarians, not critics. They will describe what exists without suggesting improvements or identifying issues.

   **For thoughts directory:**
   - Use the **thoughts-finder** agent to discover what documents exist about the topic
   - Use the **thoughts-reader** agent to extract key insights from specific documents (only the most relevant ones)

   **For web research:**

   - Use the **web-researcher**, **perplexity-researcher**, and **deepwiki-researcher** for external documentation and resources
   - IF you use web research agents, instruct them to write LINKS in their scratch file, and remind yourself to INCLUDE those links in your final report

   The key is to use these agents intelligently:
   - Start with locator agents to find what exists
   - Then use analyzer agents on the most promising findings to document how they work
   - Run multiple agents in parallel when they're searching for different things
   - Each agent knows its job - just tell it what you're looking for
   - Don't write detailed prompts about HOW to search - the agents already know
   - Remind agents they are documenting, not evaluating or improving
   - **Every agent writes to its scratch file and returns only path + summary**

4. **Wait for all sub-agents, then synthesize via contained Task:**
   - IMPORTANT: Wait for ALL sub-agent tasks to complete before proceeding
   - You should now have only short summaries + file paths in your context (not full research content)
   - Spawn a single `general-purpose` **synthesis Task** and pass it:
     - The user's original research question
     - The scratch directory path: `~/.autorun/research/.scratch/YYYY-MM-DD-description/`
     - The list of scratch file paths returned by sub-agents
     - The 1-2 sentence summaries from each agent (so it knows what to expect)
     - Instructions to read ALL scratch files, then synthesize findings into a cohesive narrative
   - The synthesis Task should:
     - Read every scratch file in the directory
     - Prioritize live codebase findings as primary source of truth
     - Use thoughts/ findings as supplementary historical context
     - Connect findings across different components
     - Include specific file paths and line numbers for reference
     - Verify all thoughts/ paths are correct (e.g., thoughts/allison/ not thoughts/shared/ for personal files)
     - Highlight patterns, connections, and architectural decisions
     - Write a **consolidated synthesis document** to `~/.autorun/research/.scratch/YYYY-MM-DD-description/_synthesis.md`
     - Return ONLY: the synthesis file path and a brief summary of key findings
   - **Gather metadata for the research document:**
     - Gather git metadata: `git rev-parse HEAD`, `git branch --show-current`, basename of the repo root
     - Filename: `~/.autorun/research/YYYY-MM-DD-description.md`
     - Format: `YYYY-MM-DD-description.md` where:
       - YYYY-MM-DD is today's date
       - description is a brief kebab-case description of the research topic
     - Example: `2025-01-08-authentication-flow.md`
     - Ensure the directory exists: `mkdir -p ~/.autorun/research`
   - **Generate research document:**
     Spawn a single `general-purpose` Task to produce the final document. Pass it:
     - The synthesis file path: `~/.autorun/research/.scratch/YYYY-MM-DD-description/_synthesis.md`
     - The git metadata gathered in step 5 (commit hash, branch, repo name)
     - The final output path: `~/.autorun/research/YYYY-MM-DD-description.md`
     - The user's original research question
     - The document template below

   The Task should read the synthesis file and format the final research document.
   It should return ONLY: the output file path and a 2-3 sentence summary.

   Structure the document with YAML frontmatter followed by content:
     ```markdown
     ---
     date: [Current date and time with timezone in ISO format]
     git_commit: [Current commit hash]
     branch: [Current branch name]
     repository: [Repository name]
     topic: "[User's Question/Topic]"
     tags: [research, codebase, relevant-component-names]
     status: complete
     last_updated: [Current date in YYYY-MM-DD format]
     ---
   
     # Research: [User's Question/Topic]
   
     **Date**: [Current date and time with timezone]
     **Git Commit**: [Current commit hash]
     **Branch**: [Current branch name]
     **Repository**: [Repository name]
   
     ## Research Question
     [Original user query]
   
     ## Summary
     [High-level documentation of what was found, answering the user's question by describing what exists]
   
     ## Detailed Findings

     ### [Component/Area 1]
     - Description of what exists (@file.ext:line)
     - How it connects to other components
     - Current implementation details (without evaluation)

     ### [Component/Area 2]
     ...

     ## Code References
     - @path/to/file.py:123 - Description of what's there
     - @another/file.ts:45-67 - Description of the code block

     ## Architecture Documentation
     [Current patterns, conventions, and design implementations found in the codebase]

     ## Historical Context (from thoughts/)
     [Relevant insights from thoughts/ directory with references]
     - @thoughts/shared/something.md - Historical decision about X
     - @thoughts/local/notes.md - Past exploration of Y
     Note: Paths exclude "searchable/" even if found there

     ## Related Research
     [Links to other research documents in ~/.autorun/research/]

     ## Open Questions
     [Any areas that need further investigation]
     ```

5. **Finalize, present, and chain (contained wrap-up Task):**

   Spawn a single `general-purpose` Task to handle all finalization in an isolated context. Pass it the research document path and instruct it to:

   - **Add GitHub permalinks (if applicable)**: Check `git branch --show-current` and `git status`. If on main/master or pushed, get repo info via `gh repo view --json owner,name` and replace local file references in the document with permalinks (`https://github.com/{owner}/{repo}/blob/{commit}/{file}#L{line}`)
   - **Generate a concise summary** of key findings with important file references
   - **Clean up scratch files**: `rm -rf ~/.autorun/research/.scratch/YYYY-MM-DD-description/`
   After the Task completes, present its returned summary and the research document path to the user.

   **Write the handoff file** for downstream `create_plan.md`:
   ```bash
   mkdir -p ~/.autorun/research/.handoff
   ```
   Write `~/.autorun/research/.handoff/YYYY-MM-DD-description.md` (using the same date-description slug as the research document) containing:
   ```markdown
   # Research Handoff: <description>

   ## Synthesis Path
   <path to the research document written above>

   ## Key Findings Summary
   <3-5 bullet points from the synthesis>

   ## Scope Assessment
   <brief scope assessment from the synthesis>

   ## Files Referenced
   <list of key file paths discovered during research>
   ```

   **Before chaining**, commit the research document, handoff file, and any supporting files:

   1. Stage only the files you changed (do NOT use `git add -A`):
      ```bash
      git add <research-doc> <other-files-if-any>
      ```
   2. Commit:
      ```bash
      git commit -m "research: <brief description of what was documented>"
      ```

   Then chain to the next phase directly using Bash (do NOT spawn a Task for this — run it yourself):

   1. Detect the tmux session name and window name:
      ```bash
      WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
      SESSION_ARG=""
      WINDOW_NAME="cp"
      CLOSE_ARG=""
      if [[ -f "$WORKTREE_ROOT/.orchestration.json" ]]; then
        SESSION_ARG=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json')).get('session_name', ''))")
        STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
        WINDOW_NAME="s${STAGE_NUM}-cp"
        CLOSE_ARG="close"

        # Update phase status
        STATUS_FILE=$(python3 -c "import json; d=json.load(open('$WORKTREE_ROOT/.orchestration.json')); import os; print(os.path.join(d['orchestration_dir'], 'status.json'))")
        bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" research completed_at
      fi
      echo "Session: '${SESSION_ARG:-<none>}', Window: '$WINDOW_NAME'"
      ```
   2. Run chain-next.sh directly via Bash (substitute the actual handoff file path):
      ```bash
      bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:create_plan <handoff-path>" "$WINDOW_NAME" "$SESSION_ARG" "" "$CLOSE_ARG"
      ```

## Important notes:
- **CONTEXT WINDOW PROTECTION**: Sub-agents write findings to scratch files and return only paths + 1-2 sentence summaries. Synthesis and document generation happen in contained Tasks that read from those files. The main thread should never hold full research content.
- Always use parallel Task agents to maximize efficiency and minimize context usage
- Always run fresh codebase research - never rely solely on existing research documents
- The thoughts/ directory provides historical context to supplement live findings
- Focus on finding concrete file paths and line numbers for developer reference
- Research documents should be self-contained with all necessary context
- Each sub-agent prompt should be specific and focused on read-only documentation operations
- Document cross-component connections and how systems interact
- Include temporal context (when the research was conducted)
- Link to GitHub when possible for permanent references
- Keep the main agent focused on synthesis, not deep file reading
- Have sub-agents document examples and usage patterns as they exist
- Explore all of thoughts/ directory, not just research subdirectory
- **CRITICAL**: You and all sub-agents are documentarians, not evaluators
- **REMEMBER**: Document what IS, not what SHOULD BE
- **NO RECOMMENDATIONS**: Only describe the current state of the codebase
- **File reading**: Always read mentioned files FULLY (no limit/offset) before spawning sub-tasks
- **Critical ordering**: Follow the numbered steps exactly
  - ALWAYS read mentioned files first before spawning sub-tasks (step 1)
  - ALWAYS wait for all sub-agents to complete before synthesizing (step 4)
  - ALWAYS gather metadata before writing the document (step 5 before step 6)
  - NEVER write the research document with placeholder values
- **Path handling**: The thoughts/searchable/ directory contains hard links for searching
  - Always document paths by removing ONLY "searchable/" - preserve all other subdirectories
  - Examples of correct transformations:
    - `thoughts/searchable/allison/old_stuff/notes.md` → `thoughts/allison/old_stuff/notes.md`
    - `thoughts/searchable/shared/prs/123.md` → `thoughts/shared/prs/123.md`
    - `thoughts/searchable/global/shared/templates.md` → `thoughts/global/shared/templates.md`
  - NEVER change allison/ to shared/ or vice versa - preserve the exact directory structure
  - This ensures paths are correct for editing and navigation
- **Frontmatter consistency**:
  - Always include frontmatter at the beginning of research documents
  - Keep frontmatter fields consistent across all research documents
  - Update frontmatter when adding follow-up research
  - Use snake_case for multi-word field names (e.g., `last_updated`, `git_commit`)
  - Tags should be relevant to the research topic and components studied
