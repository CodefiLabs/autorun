---
date: 2026-04-24T00:00:00Z
researcher: Kevin Kirchner
git_commit: 19f5d916a0622afb2171d8a5c90c9f0817ea99cc
branch: main
repository: autorun
topic: "Could .orchestration.json support multiple orchestrations at once, eliminating the stale-file cleanup?"
tags: [research, codebase, orchestration, state-management, worktrees]
status: complete
last_updated: 2026-04-24
last_updated_by: Kevin Kirchner
---

# Research: Multi-orchestration support in `.orchestration.json`

**Date**: 2026-04-24
**Researcher**: Kevin Kirchner
**Git Commit**: 19f5d916a0622afb2171d8a5c90c9f0817ea99cc
**Branch**: main
**Repository**: autorun

## Research Question

In light of commit `19f5d91` ("make sure old orchestration files are removed when starting a new one"), could/should `.orchestration.json` be able to hold multiple orchestrations at once, so the file wouldn't need to be removed and a new autorun session wouldn't get confused? How could that work?

This research documents how `.orchestration.json` is used today — its schema, lifecycle, readers/writers, cardinality assumptions, and how commands detect "orchestrated mode" — as the factual basis for answering that design question in the accompanying implementation plan.

## Summary

`.orchestration.json` today is a **single-orchestration, single-worktree file**: exactly one object written by `start.md` at the worktree root when a stage enters orchestrated mode, read by four phases (`research_codebase`, `create_plan`, `implement_plan`, and `start.md`'s defensive branch) to recover their stage context, and removed three different ways (stale-detection, post-merge cleanup, start.md's defensive call).

The schema is flat and hard-coded for one stage — `stage_number` is always a scalar, and every downstream site uses `...['stage_number']` as a single value. Identity of an orchestration is keyed by `orchestration_dir` (which lives at `$HOME/.autorun/orchestration/<plan-name>/`, not in a worktree). The natural unique ID for a running stage is the tmux session name `${PROJECT_SLUG}_stage-${STAGE_NUM}`, which is already stored as `session_name` in the file and already drives all inter-phase chaining.

The staleness problem addressed by commit `19f5d91` arises in exactly one scenario: the **non-worktree case** (main repo, or a worktree that survived beyond its merge). In the normal orchestrated path, the worktree is removed by `merge.md` Step 6 and `.orchestration.json` goes with it. The new `validate-orchestration.sh` treats staleness as a condition to *delete* the file and return "not orchestrated"; commit `19f5d91` is a patch to avoid a new `start.md` run inheriting stale state.

A multi-orchestration schema would decouple **signal** ("am I orchestrated?") from **identity** ("which orchestration am I part of?") by keying entries on the session name. A command would look itself up rather than inheriting whatever single object happens to be in the file. This would eliminate the staleness class of bugs but requires changes to four commands and the creation of new register/unregister/lookup helper scripts.

All concrete facts below are backed by file:line citations.

## Detailed Findings

### 1. Schema and creation site

`.orchestration.json` is written in exactly one place: `start.md`'s orchestrated-mode branch (commands/start.md:163-171).

```bash
# Write .orchestration.json for downstream pipeline phases
cat > .orchestration.json << EOF
{
  "stage_number": "$STAGE_NUM",
  "orchestration_dir": "$ORCH_DIR",
  "session_name": "${PROJECT_SLUG}_stage-${STAGE_NUM}",
  "chain_on_complete": "/autorun:merge $ORCH_DIR $STAGE_NUM"
}
EOF
```

Fields (from commands/start.md:164-171):

| Field | Type | Origin | Example |
|---|---|---|---|
| `stage_number` | string | stage context file's `## Orchestration` block | `"3"` |
| `orchestration_dir` | abs path | stage context file | `/Users/kk/.autorun/orchestration/wave-2-master-plan` |
| `session_name` | string | `${PROJECT_SLUG}_stage-${STAGE_NUM}` | `token-audit_stage-3` |
| `chain_on_complete` | slash-command | `"/autorun:merge $ORCH_DIR $STAGE_NUM"` | `/autorun:merge /Users/kk/.autorun/orchestration/wave-2-master-plan 3` |

`PROJECT_SLUG` comes from `status.json` via `python3 -c "import json; print(json.load(open('$STATUS_FILE')).get('project_slug', ''))"` (commands/start.md:160).

### 2. Readers (and what they use each field for)

Every reader resolves the file via `WORKTREE_ROOT=$(git rev-parse --show-toplevel)` (e.g. commands/research_codebase.md:34, commands/create_plan.md:59, commands/implement_plan.md:24).

**Phase audit blocks** (all three do the same thing):
- commands/research_codebase.md:32-40 — calls `validate-orchestration.sh`, then reads `stage_number` and derives `status.json` path from `orchestration_dir`; runs `update-phase-status.sh ... research started_at`.
- commands/create_plan.md:57-65 — same pattern for `create_plan started_at`.
- commands/implement_plan.md:22-30 — same pattern for `implement started_at`.

**Chain sites** (pass `session_name` + `stage_number` into `chain-next.sh`):
- commands/research_codebase.md:284-299 — builds `SESSION_ARG` and window name `s${STAGE_NUM}-cp`, chains to create_plan.
- commands/create_plan.md:408-429 — builds `s${STAGE_NUM}-ip`, chains to implement_plan (with `close` arg).
- commands/implement_plan.md:286-305 — builds `s${STAGE_NUM}-ip-p${NEXT}` between phases.
- commands/implement_plan.md:310-331 — builds `s${STAGE_NUM}-merge`, chains to merge.

**`chain_on_complete` consumers**:
- commands/create_plan.md:252-275 — reads `chain_on_complete` during plan writing and copies it into the plan's YAML frontmatter.
- commands/implement_plan.md:263-272 — falls back to reading `chain_on_complete` from `.orchestration.json` if the plan's frontmatter has none.

**`start.md` non-orchestrated defensive read** (commands/start.md:53-57) — calls `validate-orchestration.sh` before chaining, so a stale file is removed and doesn't affect downstream phases.

Commands that do **not** read `.orchestration.json`:
- `merge.md` — receives `<orchestration-dir>` and `<stage-number>` as explicit `$ARGUMENTS` (commands/merge.md:10-18).
- `chain-next.sh` — orchestration-agnostic; takes session, window, work-dir, close-caller as args (scripts/chain-next.sh:20-24).
- `update-phase-status.sh` — works off `status.json` directly.
- `monitor-orchestration.sh`, `check-orchestration-progress.sh` — auto-detect the most recent `status.json` independently.

### 3. Deletion paths (three distinct)

**A. `scripts/validate-orchestration.sh` — staleness sweep**

Introduced by commit `19f5d91`. Deletes `.orchestration.json` when:
- `orchestration_dir` key missing or directory doesn't exist (scripts/validate-orchestration.sh:15-19)
- `$ORCH_DIR/status.json` missing (scripts/validate-orchestration.sh:22-26)
- Stage already marked `completed` in status.json (scripts/validate-orchestration.sh:34-38)

Callers: commands/start.md:56 (defensive), commands/research_codebase.md:35, commands/create_plan.md:60, commands/implement_plan.md:25.

**B. `merge.md` Step 6 — post-merge cleanup** (commands/merge.md:418-438)

```bash
if [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  # In a worktree — remove the whole worktree (implicitly removes .orchestration.json)
  cd "$MAIN_REPO"
  git worktree remove --force "$WORKTREE_PATH" 2>/dev/null
  ...
else
  # Not in a worktree — explicit rm
  if [[ -f "$WORKTREE_PATH/.orchestration.json" ]]; then
    rm "$WORKTREE_PATH/.orchestration.json"
  fi
fi
```

**C. `start.md` non-orchestrated defensive call** (commands/start.md:53-57)

Calls `validate-orchestration.sh` at the top of the non-orchestrated branch to purge any leftover `.orchestration.json` from a prior orchestration. This is the patch introduced by commit `19f5d91`.

### 4. Cardinality — what is one-to-one vs many-to-one today

**One worktree per stage.**
- commands/orchestrate.md:176-178 creates wave-1 worktrees, one per stage: `claude --worktree 'stage-${STAGE_NUM}' ...`
- commands/merge.md:331-333 creates next-wave worktrees the same way.

**One `.orchestration.json` per worktree.**
- commands/start.md:164-171 writes exactly one file via heredoc. No code path merges into an existing file or writes multiple.

**One orchestration per `$HOME/.autorun/orchestration/<plan-name>/`.**
- commands/orchestrate.md:86-90 uses `$PLAN_NAME` (kebab-cased master plan filename) as the directory. No per-run timestamp or UUID — different plan names coexist but same-name collides (this is the problem commit `19f5d91` partially addresses).

**Stage topology:**
- One orchestration → one `orchestration_dir` → one `status.json` (commands/orchestrate.md:111-141).
- One orchestration → N stages (keys in `status.json["stages"]`).
- Each stage → one worktree + one tmux session `${PROJECT_SLUG}_stage-${N}` + one `.orchestration.json`.

### 5. `stage_number` usage — always a single scalar

Every call site dereferences `stage_number` as a scalar, never iterates:

- commands/research_codebase.md:36, :290 — `STAGE_NUM=$(python3 -c "...['stage_number']")`
- commands/create_plan.md:61, :416 — same pattern
- commands/implement_plan.md:26, :296, :321 — same pattern
- scripts/validate-orchestration.sh:13, :29-31 — uses `STAGE_NUM` to index `status['stages'][str($STAGE_NUM)]`

Derived identifiers (all treat stage number as scalar):
- Tmux window names: `s${STAGE_NUM}-cp`, `s${STAGE_NUM}-ip`, `s${STAGE_NUM}-ip-p${NEXT}`, `s${STAGE_NUM}-merge`
- Session name: `${PROJECT_SLUG}_stage-${STAGE_NUM}` (commands/start.md:161, commands/orchestrate.md:173, commands/merge.md:329)
- Worktree name: `stage-${STAGE_NUM}` (commands/orchestrate.md:177, commands/merge.md:332)
- Chain command: `/autorun:merge $ORCH_DIR $STAGE_NUM` (commands/start.md:169)

### 6. Orchestrated-mode detection — two tiers

**Strong (validated) detection**: `validate-orchestration.sh` exits 0. Used at phase audit blocks (research_codebase.md:32-40, create_plan.md:57-65, implement_plan.md:22-30) and at start.md's defensive cleanup (start.md:53-57). This both detects AND cleans stale files.

**Weak (file-exists) detection**: `[[ -f "$WORKTREE_ROOT/.orchestration.json" ]]`. Used at chain sites (research_codebase.md:288, create_plan.md:254, create_plan.md:414, implement_plan.md:267, implement_plan.md:294, implement_plan.md:316). These sites assume phase-audit already ran and the file is still valid.

### 7. Tmux session name is a natural unique ID for a stage

Facts that support this:
- Every stage is launched into a tmux session named `${PROJECT_SLUG}_stage-${STAGE_NUM}` (commands/orchestrate.md:173, commands/merge.md:329, commands/start.md:161).
- The session name is already stored in `.orchestration.json` as `session_name` (commands/start.md:167).
- `tmux display-message -p '#S'` returns the current session name — this was verified in-repo during research (returned `agents` from the researcher's current tmux session). The `TMUX` env var is inherited through tmux's server env, so commands running inside the pipeline (launched via `chain-next.sh` which keeps them in-session) retain access.
- Two stages in the same orchestration cannot share a session name because `STAGE_NUM` differs.
- Two stages from different orchestrations cannot collide because `PROJECT_SLUG` is derived per-plan and stage-number scopes are per-plan.

### 8. Why staleness happens today

The only mechanism by which `.orchestration.json` can persist past its useful life is the non-worktree case at commands/merge.md:431-437: if merge runs outside a worktree, it explicitly `rm`s the file. But if merge never runs (stage abandoned mid-flight, user Ctrl-C'd, etc.), the file persists.

Concretely, the staleness scenarios that `validate-orchestration.sh` handles:
- `orchestration_dir` was deleted or moved (scripts/validate-orchestration.sh:15-19)
- `status.json` was corrupted or removed (scripts/validate-orchestration.sh:22-26)
- The stage was completed by another code path but cleanup didn't remove the file (scripts/validate-orchestration.sh:34-38)

The fourth possible state — "the orchestration completed but this specific worktree still has the old file" — collapses into case 3 because stage status goes to `completed`.

### 9. status.json schema (relevant for multi-orchestration design)

From commands/orchestrate.md:111-141:

```json
{
  "plan_path": "...",
  "plan_name": "...",
  "project_slug": "...",
  "project_root": "...",
  "base_branch": "...",
  "created_at": "ISO",
  "stages": {
    "1": { "status": "pending|in_progress|completed|failed", "name": "...", "depends_on": [], "branch": null, "context_file": "...", "plan_file": null, "started_at": null, "completed_at": null, "phases": { "research": {...}, "create_plan": {...}, "implement": {...}, "merge": {...} } }
  },
  "current_wave": 1,
  "waves": [[1], [2,3,4], ...]
}
```

Stage status values are enumerated at scripts/check-orchestration-progress.sh:69-74: `pending`, `in_progress`, `completed`, `failed`.

### 10. events.jsonl event types (context)

10 distinct event types are emitted (scattered across commands/orchestrate.md:143-158, scripts/update-phase-status.sh:63-76, commands/merge.md:199-220, commands/merge.md:300-312, commands/merge.md:388-400, scripts/monitor-orchestration.sh):

`orchestration_started`, `phase_status`, `merge_complete`, `wave_complete`, `wave_started`, `orchestration_complete`, `stall_detected`, `stall_continue_sent`, `wave_gap_detected`, `session_dead`.

All carry `ts`, `type`, `orch_dir` plus type-specific fields.

## Code References

- @commands/start.md:53-57 — defensive `validate-orchestration.sh` call (added in commit `19f5d91`)
- @commands/start.md:144-192 — orchestrated-mode branch; creation of `.orchestration.json`
- @commands/start.md:163-171 — concrete heredoc writing the file
- @commands/research_codebase.md:32-40 — phase audit (validated detection)
- @commands/research_codebase.md:284-299 — chain step (reads session_name, stage_number)
- @commands/create_plan.md:57-65 — phase audit
- @commands/create_plan.md:252-275 — orchestration context check during plan writing
- @commands/create_plan.md:408-429 — chain step
- @commands/implement_plan.md:22-30 — phase audit
- @commands/implement_plan.md:263-272 — chain_on_complete fallback
- @commands/implement_plan.md:286-331 — chain steps (between phases, to merge)
- @commands/merge.md:418-438 — Step 6 cleanup (non-worktree branch added in commit `19f5d91`)
- @commands/orchestrate.md:86-90 — orchestration_dir creation
- @commands/orchestrate.md:111-141 — status.json initial schema
- @commands/orchestrate.md:176-178 — wave-1 worktree spawn
- @commands/merge.md:331-333 — next-wave worktree spawn
- @scripts/validate-orchestration.sh — entire file (40 lines; staleness validator)
- @scripts/update-phase-status.sh — entire file (uses `mkdir $LOCK_DIR` atomic lock pattern)
- @scripts/chain-next.sh:20-24,127-143 — argument surface + tmux targeting

## Architecture Documentation

**State files at play in a stage's life**:
- Per-stage per-worktree: `.orchestration.json` (created by start.md, read by 3 phases, deleted by 3 paths)
- Per-orchestration shared: `$HOME/.autorun/orchestration/<plan-name>/status.json`, `events.jsonl`, `stages/stage-N-context.md`, `.merge.lock`, optional `conflicts.md`
- Global: `$HOME/.autorun/plans/`, `$HOME/.autorun/research/`, `$HOME/.autorun/review/`, `$HOME/.autorun/logs/`

**Concurrency pattern (existing)**:
- `update-phase-status.sh:34-36` uses `mkdir $LOCK_DIR` as atomic lock (busy-wait `while ! mkdir ...`), with `trap` cleanup.
- `merge.md:100-103, 157-160, 264-267` uses `flock` on `$ORCH_DIR/.merge.lock` for multi-minute holds.

**tmux session naming convention**:
- Stage sessions: `${PROJECT_SLUG}_stage-${STAGE_NUM}` (e.g. `token-audit_stage-3`)
- Stage windows within the session: `s${STAGE_NUM}` (initial), then `s${STAGE_NUM}-<phase>` for each phase
- Non-orchestrated sessions: freestanding `cp-<slug>`, `research-<slug>`, `ip-<slug>` (commands/start.md:51)

## Historical Context (from git)

- Commit `19f5d91` (the commit motivating this research) — adds `validate-orchestration.sh` and wires it into all four phase-audit sites plus start.md's defensive path. Also adds the explicit `rm` at merge.md's non-worktree branch.
- Commit `8c7a915` ("update start.md to have better naming change chaining") — introduced the `<phase>-<slug>` naming scheme used today.
- Commit `226471f` ("chain-next: always spawn new session when no TARGET_SESSION given") — establishes the invariant that orchestrated runs always have a session to target, non-orchestrated always make a fresh one.
- Commit `35a6ce3` / `5914462` / `798be17` — version bumps around the 0.2.0 series.

## Findings Files

Full agent findings are preserved for deeper reference:
- @thoughts/shared/research/findings/2026-04-24-multi-orchestration-support/codebase-analyzer-orchestration-lifecycle.md — full lifecycle trace, all fields, all deletion paths
- @thoughts/shared/research/findings/2026-04-24-multi-orchestration-support/codebase-analyzer-worktree-stage-relationship.md — worktree-per-stage invariant, chain-next's orchestration-agnostic contract
- @thoughts/shared/research/findings/2026-04-24-multi-orchestration-support/codebase-analyzer-status-json.md — status.json schema, event types, monitor auto-detection

## Related Research

None prior — this is the first research document under `thoughts/shared/research/` for this repo.

## Open Questions

None. The research question is answered: `.orchestration.json` is structurally single-orchestration today, but every piece of identity needed to key multiple orchestrations (session name, stage number, orchestration_dir) is already present in the schema and in the runtime environment. The plan document addresses the design.
