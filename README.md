# autorun

Headless multi-stage code change pipeline for [Claude Code](https://claude.ai/code). Research, plan, implement, and merge autonomously via tmux and git worktrees.

## Install

```bash
# Add the CodefiLabs marketplace (one-time)
/plugin marketplace add codefilabs/marketplace

# Install autorun
/plugin install autorun@codefilabs
```

## Prerequisites

Autorun requires **tmux**, **python3**, **git**, and the **claude** CLI.

Check your setup:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh
```

Install missing dependencies:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh --install
```

Or install tmux directly:

```bash
# macOS
brew install tmux

# Ubuntu/Debian
sudo apt-get install tmux
```

## Commands

| Command | Description |
|---------|-------------|
| `/autorun:start <task>` | Smart entry point — triages by scope (QUICK/MEDIUM/LARGE/EPIC) and routes to the right pipeline |
| `/autorun:research_codebase <task>` | Parallel codebase research with specialized sub-agents |
| `/autorun:create_plan <task or handoff>` | Create a phased implementation plan through iterative research |
| `/autorun:implement_plan <plan-path>` | Execute a plan phase-by-phase with verification teams |
| `/autorun:orchestrate <master-plan>` | Parse a staged master plan and launch parallel stages via git worktrees |
| `/autorun:merge <orch-dir> <stage>` | Merge a completed stage branch, launch next wave if ready |

## How it works

```
/autorun:start "add caching to the API layer"
       |
  [triage: QUICK / MEDIUM / LARGE / EPIC]
       |
   LARGE → research_codebase → create_plan → implement_plan
   MEDIUM → create_plan → implement_plan
   QUICK → implement_plan (inline plan)
   EPIC → interactive brainstorm → orchestrate (parallel stages)
```

Each pipeline stage chains to the next in a fresh tmux window, giving every phase a clean context window. For EPIC tasks, `orchestrate` launches multiple stages in parallel git worktrees — each running its own research/plan/implement pipeline — and `merge` handles branch integration and wave progression.

### Runtime data

All runtime state lives in `~/.autorun/`:

```
~/.autorun/
  research/       # Research documents
  plans/          # Implementation plans
  review/         # Human-in-the-loop review files
  orchestration/  # Per-plan stage status and context
  logs/           # tmux session logs
```

## License

MIT
