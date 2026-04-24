# Orchestration Lifecycle Analysis: `.orchestration.json`

**Date**: 2026-04-24
**Scope**: Full lifecycle of `.orchestration.json` across the autorun pipeline
**Repo**: `/Users/kk/Sites/CodefiLabs/autorun`

This document describes how `.orchestration.json` is created, read, validated, and removed across the pipeline commands and scripts as they exist today.

---

## 1. Creation

### Where it is created

`.orchestration.json` is created in exactly one place: inside `start.md` when it detects that it is running in "orchestrated mode" (i.e. the `$ARGUMENTS` value resolves to a stage context file containing `## Orchestration` metadata).

- File: `/Users/kk/Sites/CodefiLabs/autorun/commands/start.md`
- Section: "Orchestrated Mode" (lines 144–192)
- Concrete creation at lines 163–171:

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

The file is written to the current working directory. In orchestrated runs the CWD is the stage's git worktree root (spawned by `orchestrate.md` or `merge.md` via `claude --worktree 'stage-${STAGE_NUM}' ...`).

### Upstream values

The values are derived from the stage context file that `start.md` receives as its argument. `start.md` extracts them as described at lines 146–157:

- `stage_number` from the context file's `## Orchestration` block
- `orchestration_dir` from the context file
- `session_name` derived as `${PROJECT_SLUG}_stage-${STAGE_NUM}` where `PROJECT_SLUG` is read from `status.json`:
  ```bash
  PROJECT_SLUG=$(python3 -c "import json; print(json.load(open('$STATUS_FILE')).get('project_slug', ''))")
  ```
  (start.md:160)
- `chain_on_complete` is constructed literally as `"/autorun:merge $ORCH_DIR $STAGE_NUM"`

### Schema (fields actually written)

From `start.md:164-171`, the file contains exactly four fields:

| Field | Type | Origin | Example |
|---|---|---|---|
| `stage_number` | string (quoted scalar) | stage context file | `"3"` |
| `orchestration_dir` | string (abs path) | stage context file | `"/Users/kk/.autorun/orchestration/wave-2-master-plan"` |
| `session_name` | string | `${PROJECT_SLUG}_stage-${STAGE_NUM}` | `"token-audit_stage-3"` |
| `chain_on_complete` | string (slash-command) | `"/autorun:merge $ORCH_DIR $STAGE_NUM"` | `"/autorun:merge /Users/kk/.autorun/orchestration/wave-2-master-plan 3"` |

`stage_number` is a single scalar — the heredoc writes it without array brackets, and every downstream consumer dereferences it as a scalar (see §6 below).

### When it is created

`.orchestration.json` is created at the very start of a stage's pipeline run (as soon as `start.md` enters the "Orchestrated Mode" branch), before the stage is routed to QUICK/MEDIUM/LARGE and before `start.md` triggers `update-phase-status.sh ... triage completed_at` (start.md:173-174).

### What else is created around it (for context)

The higher-level orchestration directory (`~/.autorun/orchestration/<plan-name>/`) is created earlier by `orchestrate.md` Step 2 (lines 80–159). That directory contains `status.json`, `events.jsonl`, and `stages/stage-N-context.md` files. `.orchestration.json` is a per-worktree **pointer** from the stage worktree back to that shared orchestration directory.

---

## 2. Readers and consumers

Every consumer reads `.orchestration.json` from `WORKTREE_ROOT = git rev-parse --show-toplevel`.

### 2a. `commands/research_codebase.md` (LARGE pipeline)

- Phase audit block (lines 30–40): calls `validate-orchestration.sh` first, then if valid, reads `stage_number` and derives `status.json` from `orchestration_dir`:
  ```bash
  STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
  STATUS_FILE=$(python3 -c "import json; d=json.load(open('$WORKTREE_ROOT/.orchestration.json')); import os; print(os.path.join(d['orchestration_dir'], 'status.json'))")
  ```
  Then runs `update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" research started_at`.
- Chain step (lines 284–299): reads `session_name` and `stage_number` to build the tmux session arg and window name (`s${STAGE_NUM}-cp`), and calls `update-phase-status.sh ... research completed_at`.

### 2b. `commands/create_plan.md`

- Phase audit block (lines 56–65): same pattern as research_codebase — validate, then read `stage_number`, derive `status.json` path, mark `create_plan started_at`.
- Orchestration context check (lines 252–261): before writing the plan file, checks for `.orchestration.json` and extracts `chain_on_complete`:
  ```bash
  CHAIN_ON_COMPLETE=$(python3 -c "import json; print(json.load(open('$(pwd)/.orchestration.json'))['chain_on_complete'])")
  ```
  If present, the plan is written with YAML frontmatter:
  ```yaml
  ---
  chain_on_complete: "/autorun:merge ~/.autorun/orchestration/<plan-name> <stage-number>"
  ---
  ```
  (create_plan.md:269-275). This propagates the merge instruction into the plan so that `implement_plan.md` has a second source of truth.
- Chain step (lines 408–429): reads `session_name` and `stage_number` to build `SESSION_ARG`, `WINDOW_NAME=s${STAGE_NUM}-ip`, and `CLOSE_ARG=close`; calls `update-phase-status.sh ... create_plan completed_at`.

### 2c. `commands/implement_plan.md`

- Phase audit block (lines 22–30): same validate-then-update pattern, marking `implement started_at` on first invocation.
- Chain to next phase (lines 286–305): reads `session_name` and `stage_number` to name the next phase's tmux window (`s${STAGE_NUM}-ip-p${NEXT}`).
- **`chain_on_complete` fallback** (lines 264–272): when all phases are checked off, it first checks the plan's YAML frontmatter for `chain_on_complete`; if absent there, it falls back to reading `.orchestration.json`:
  ```bash
  if [[ -f "$WORKTREE_ROOT/.orchestration.json" ]]; then
    CHAIN_ON_COMPLETE=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json')).get('chain_on_complete', ''))")
  fi
  ```
- Final chain to merge (lines 310–331): reads `session_name` and `stage_number` once more to name the window `s${STAGE_NUM}-merge` and to run `update-phase-status.sh ... implement completed_at` before chaining.

### 2d. `commands/merge.md`

`merge.md` does **not** read `.orchestration.json` for its own logic — it receives `<orchestration-dir>` and `<stage-number>` as explicit command-line arguments (merge.md:10-18). It operates against `$ORCH_DIR/status.json` directly.

It does touch `.orchestration.json` once, as part of cleanup (see §3 below).

### 2e. `commands/start.md` (non-orchestrated branch — defensive read)

In the non-orchestrated branch, `start.md` calls `validate-orchestration.sh` defensively before chaining, to clean up any stale `.orchestration.json` left behind from a prior orchestration run (start.md:53-57):

```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-orchestration.sh "$WORKTREE_ROOT" 2>/dev/null || true
```

### 2f. `scripts/validate-orchestration.sh`

Reads `.orchestration.json` to determine validity (see §4).

### 2g. `scripts/chain-next.sh`

`chain-next.sh` itself does **not** read `.orchestration.json`. It receives the session name and working directory as explicit arguments. Auto-detection at lines 27–33 discovers the worktree CWD from git (`git rev-parse --show-toplevel`) when `WORK_DIR` is not passed, which is independent of `.orchestration.json`.

### 2h. `scripts/update-phase-status.sh` and `scripts/monitor-orchestration.sh`

Neither reads `.orchestration.json`. They work off `status.json` and `events.jsonl` in the orchestration directory directly.

### Summary of what readers do with it

| Field | Used by |
|---|---|
| `stage_number` | research_codebase.md, create_plan.md, implement_plan.md (all phase audits, chains, and window naming) |
| `orchestration_dir` | all three phase audits — derives `status.json` path for `update-phase-status.sh` |
| `session_name` | all three chain steps — passed to `chain-next.sh` as `TARGET_SESSION` so new windows open in the stage's tmux session |
| `chain_on_complete` | create_plan.md (copies into plan frontmatter); implement_plan.md (fallback source when plan has no frontmatter) |

---

## 3. Deletion

There are three distinct deletion paths.

### 3a. `scripts/validate-orchestration.sh` — stale detection

This script is the primary deletion mechanism during the pipeline's active life. It deletes `.orchestration.json` when it detects staleness:

File: `/Users/kk/Sites/CodefiLabs/autorun/scripts/validate-orchestration.sh`

- Line 10: exits 1 if the file doesn't exist (no deletion needed)
- Lines 15–19: deletes if `orchestration_dir` from the file doesn't exist on disk:
  ```bash
  if [[ -z "$ORCH_DIR" ]] || [[ ! -d "$ORCH_DIR" ]]; then
    echo "[orchestration] Removing stale .orchestration.json — orchestration dir not found: ${ORCH_DIR:-<empty>}" >&2
    rm "$ORCH_FILE"
    exit 1
  fi
  ```
- Lines 22–26: deletes if `status.json` is missing:
  ```bash
  if [[ ! -f "$STATUS_FILE" ]]; then
    echo "[orchestration] Removing stale .orchestration.json — status.json missing" >&2
    rm "$ORCH_FILE"
    exit 1
  fi
  ```
- Lines 34–38: deletes if the stage is already marked `completed` in status.json:
  ```bash
  if [[ "$STAGE_STATUS" == "completed" ]]; then
    echo "[orchestration] Removing stale .orchestration.json — stage $STAGE_NUM already completed" >&2
    rm "$ORCH_FILE"
    exit 1
  fi
  ```
- Line 40: exits 0 (valid, keep file) if none of the above triggered.

Callers of `validate-orchestration.sh`:
- `start.md:56` (non-orchestrated defensive cleanup)
- `research_codebase.md:35` (phase audit)
- `create_plan.md:60` (phase audit)
- `implement_plan.md:25` (phase audit)

### 3b. `commands/merge.md` Step 6 — post-merge cleanup

File: `/Users/kk/Sites/CodefiLabs/autorun/commands/merge.md`, lines 412–438

After the stage branch has been merged, Step 6 cleans up. The behavior depends on whether the current location is a worktree:

```bash
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
  echo "Not in a worktree — skipping worktree removal"
  if [[ -f "$WORKTREE_PATH/.orchestration.json" ]]; then
    rm "$WORKTREE_PATH/.orchestration.json"
    echo ".orchestration.json removed"
  fi
fi
```

- **Inside a worktree** (the normal orchestrated path): the whole worktree is removed, which implicitly removes `.orchestration.json` along with it.
- **Not in a worktree** (fallback case): the file is explicitly `rm`'d at line 434.

The merge.md comment at lines 412–414 explains the step is deferred to the end to avoid destroying the session CWD before other Tasks can run.

### 3c. `start.md` non-orchestrated defensive cleanup

See §2e above. When `start.md` runs in non-orchestrated mode, it proactively calls `validate-orchestration.sh`, which deletes the file if it's stale. This prevents a leftover `.orchestration.json` from a previous orchestrated run from incorrectly making a fresh ad-hoc run look like part of an orchestration.

---

## 4. Validation rules

`scripts/validate-orchestration.sh` embodies the validation contract. The file is considered VALID (exit 0, keep) only when all four of the following hold:

1. The file exists at `$WORKTREE_ROOT/.orchestration.json` (line 10).
2. The `orchestration_dir` key is non-empty and the directory exists on disk (lines 12, 15–19).
3. `$ORCH_DIR/status.json` exists (lines 21–26).
4. The stage status in `status.json` for `stage_number` is NOT `completed` (lines 28–38).

Any failure of (2), (3), or (4) triggers `rm "$ORCH_FILE"` before exit.

---

## 5. Worktree ↔ orchestration_dir relationship

### Worktree (where `.orchestration.json` lives)

- A git worktree is spawned per stage by `orchestrate.md:176-178` and `merge.md:331-333`:
  ```bash
  tmux new-session -d -s "$SESSION_NAME" -n "s${STAGE_NUM}" \
    "claude --worktree 'stage-${STAGE_NUM}' '/autorun:start $CONTEXT_FILE'"
  ```
- `claude --worktree 'stage-${STAGE_NUM}'` creates/attaches to a worktree named by the stage number.
- `.orchestration.json` is written at the worktree root by `start.md:163-171`.
- Downstream pipeline commands resolve the worktree root via `WORKTREE_ROOT="$(git rev-parse --show-toplevel)"`.

### orchestration_dir (where `status.json` and `events.jsonl` live)

- Created by `orchestrate.md:86-90` as `$HOME/.autorun/orchestration/$PLAN_NAME/`:
  ```bash
  ORCH_DIR="$HOME/.autorun/orchestration/$PLAN_NAME"
  mkdir -p "$ORCH_DIR/stages"
  ```
- Contains:
  - `status.json` — shared state across all stages (orchestrate.md:111-141). Fields include `plan_path`, `plan_name`, `project_slug`, `project_root`, `base_branch`, `created_at`, `stages` (keyed by stage number, with per-phase timestamps), `current_wave`, `waves`.
  - `events.jsonl` — append-only event log; written by `orchestrate.md:143-158` (`orchestration_started`), `update-phase-status.sh:63-76` (`phase_status` events), `merge.md:199-220` (`merge_complete`, `wave_complete`), `merge.md:303-312` (`wave_started`), `merge.md:388-400` (`orchestration_complete`), and `monitor-orchestration.sh:241, 244, 259, 269` (`stall_detected`, `stall_continue_sent`, `wave_gap_detected`, `session_dead`).
  - `stages/stage-N-context.md` — per-stage context files (orchestrate.md:92-109).
  - `.merge.lock` — flock file for concurrency protection (merge.md:100-103, 157-160, 264-267).
  - Optional `conflicts.md` — merge conflict notes (merge.md:131-132).

### The relationship

- `.orchestration.json` lives in the **worktree** and contains the absolute path back to the shared **orchestration_dir** via its `orchestration_dir` field.
- The orchestration_dir does NOT live inside a worktree — it lives under `$HOME/.autorun/orchestration/` and is shared across all stage worktrees for a given plan.
- Given `.orchestration.json`, consumers derive `status.json` via `os.path.join(d['orchestration_dir'], 'status.json')` (e.g. research_codebase.md:37, create_plan.md:62, implement_plan.md:27).
- The `stage_number` in `.orchestration.json` is the index into `status.json`'s `stages` object (e.g. `status["stages"][str(STAGE_NUM)]`).

---

## 6. Cardinality: one worktree per orchestration? per stage? shared?

### Observed cardinality in the code today

**One worktree per stage.** Every worktree creation site uses `--worktree 'stage-${STAGE_NUM}'`:

- `orchestrate.md:176-178` creates wave-1 worktrees, one per stage.
- `merge.md:331-333` creates next-wave worktrees, one per stage.

**One `.orchestration.json` per worktree.** `start.md:164-171` writes exactly one file per worktree using the heredoc at that line. No code path creates multiple `.orchestration.json` files or merges into an existing one.

**One orchestration per `$HOME/.autorun/orchestration/<plan-name>/`.** `orchestrate.md:86-90` uses `$PLAN_NAME` as the directory. `orchestrate.md:57-60` derives `PLAN_NAME` from the master plan filename.

### Relationship between orchestrations and worktrees

- One **orchestration** (a single master plan invocation) → one `orchestration_dir` with one `status.json`.
- One orchestration → N **stages** (enumerated in `status.json` under `stages`).
- Each stage → one **worktree**, one tmux session (`${PROJECT_SLUG}_stage-${STAGE_NUM}`), one `.orchestration.json` inside that worktree.
- Stages within the same orchestration → share the same `orchestration_dir` (via the `orchestration_dir` field of their respective `.orchestration.json` files).

### Can multiple orchestrations share a worktree?

No code path shares a worktree between orchestrations. Worktree names are `stage-N` where N is a stage number, and every worktree is created fresh in `orchestrate.md` or `merge.md` and removed in `merge.md` Step 6 after the stage completes. `start.md`'s defensive cleanup (start.md:53-57) also assumes the worktree is single-use: it removes any stale `.orchestration.json` rather than augmenting it.

---

## 7. `stage_number` usage — always singular

Every read treats `stage_number` as a single scalar. No consumer iterates over it or treats it as a list.

Concrete call sites (all using `...['stage_number']` as a scalar):

- `research_codebase.md:36` — `STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")`
- `research_codebase.md:290` — same pattern in the chain step
- `create_plan.md:61` — same pattern (phase audit)
- `create_plan.md:416` — same pattern (chain step)
- `implement_plan.md:26` — same pattern (phase audit)
- `implement_plan.md:296` — same pattern (chain to next phase)
- `implement_plan.md:321` — same pattern (chain to merge)
- `validate-orchestration.sh:13` — `STAGE_NUM=$(python3 -c "import json; print(json.load(open('$ORCH_FILE'))['stage_number'])" ...)`
- `validate-orchestration.sh:29-31` — uses `STAGE_NUM` to index `status['stages'][str($STAGE_NUM)]`

Derived values also treat it as scalar:
- Tmux window names: `s${STAGE_NUM}-cp`, `s${STAGE_NUM}-ip`, `s${STAGE_NUM}-ip-p${NEXT}`, `s${STAGE_NUM}-merge` (research_codebase.md:291, create_plan.md:417, implement_plan.md:297, implement_plan.md:319).
- Session name: `${PROJECT_SLUG}_stage-${STAGE_NUM}` (start.md:161, orchestrate.md:173, merge.md:329).
- Worktree name: `stage-${STAGE_NUM}` (orchestrate.md:177, merge.md:332).
- Chain command: `/autorun:merge $ORCH_DIR $STAGE_NUM` (start.md:169).
- `update-phase-status.sh` second argument: a single stage number (see `update-phase-status.sh:17-18` expecting `STAGE_NUMBER`).

The schema written by `start.md:164-171` quotes `stage_number` as a string (e.g. `"stage_number": "3"`). The `python3` reads coerce it through `str(...)` or integer conversion where needed (`validate-orchestration.sh:31`, `update-phase-status.sh:52-56`).

---

## 8. Orchestrated mode detection per command

Each pipeline command detects orchestrated mode in its own way, but the common signal is the presence of `.orchestration.json` at `$WORKTREE_ROOT`.

### 8a. `orchestrate.md`

Does not detect — it IS the command that starts orchestrated mode. It receives the master plan path as an argument and creates the orchestration_dir, stage context files, and status.json.

### 8b. `start.md`

Detects orchestrated mode by inspecting `$ARGUMENTS`: if the argument is a path to a stage context file with an `## Orchestration` section (containing `orchestration_dir`, `stage_number`, `status_file`, `base_branch`), it enters the "Orchestrated Mode" branch (start.md:144-192). Otherwise, it runs the non-orchestrated branch (QUICK/MEDIUM/LARGE/EPIC triage).

### 8c. `research_codebase.md`

Phase Audit block (lines 32–40). The detection predicate is: `validate-orchestration.sh` returns exit 0. The check wraps phase-update logic:

```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
if bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-orchestration.sh "$WORKTREE_ROOT"; then
  STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
  ...
fi
```

At the chain step (line 288), detection is a simple file existence test:
```bash
if [[ -f "$WORKTREE_ROOT/.orchestration.json" ]]; then
```

### 8d. `create_plan.md`

Phase Audit (lines 56–65): same `validate-orchestration.sh` pattern.

Orchestration context check (lines 252–261, which runs during plan writing): a file existence test on `$(pwd)/.orchestration.json`, used to decide whether to add `chain_on_complete` frontmatter.

Chain step (line 414): file existence test on `$WORKTREE_ROOT/.orchestration.json`.

### 8e. `implement_plan.md`

Phase Audit (lines 22–30): same `validate-orchestration.sh` pattern.

`chain_on_complete` fallback (line 267): file existence test on `$WORKTREE_ROOT/.orchestration.json`, consulted only if the plan's YAML frontmatter has no `chain_on_complete`.

Chain to next phase (line 294) and chain to merge (line 316): file existence tests.

### 8f. `merge.md`

`merge.md` does not detect orchestrated mode via `.orchestration.json` — it is itself an orchestration-specific command and assumes it is always in orchestrated mode (its arguments `<orchestration-dir> <stage-number>` come from upstream). It does a worktree detection at cleanup time (merge.md:420-421) to decide whether to remove the worktree or just delete `.orchestration.json`.

### Two tiers of detection

- **Strong (validated)**: `validate-orchestration.sh` — used by phase audit blocks in research_codebase.md, create_plan.md, implement_plan.md, and by defensive cleanup in start.md. This both detects AND cleans stale files.
- **Weak (file-exists only)**: `[[ -f "$WORKTREE_ROOT/.orchestration.json" ]]` — used at chain sites in research_codebase.md, create_plan.md, implement_plan.md, and at the orchestration context check inside create_plan.md.

---

## 9. End-to-end lifecycle trace

For a single stage in an orchestrated run:

1. **orchestrate.md** creates `$HOME/.autorun/orchestration/<plan>/` with `status.json`, `events.jsonl`, and `stages/stage-N-context.md`. It spawns a tmux session with `claude --worktree 'stage-N' '/autorun:start <context-file>'`.

2. **start.md** (orchestrated mode) reads the context file, writes `.orchestration.json` at the worktree root (start.md:164-171), runs `update-phase-status.sh ... triage completed_at`, triages QUICK/MEDIUM/LARGE, and chains to the appropriate pipeline via `chain-next.sh`.

3. **research_codebase.md** (LARGE only) validates `.orchestration.json`, marks `research started_at`, does research, commits, reads `.orchestration.json` again to build chain args, marks `research completed_at`, chains to create_plan.

4. **create_plan.md** validates `.orchestration.json`, marks `create_plan started_at`, gathers research, reads `.orchestration.json` to extract `chain_on_complete` for plan frontmatter, writes the plan with frontmatter, reads `.orchestration.json` for chain args, marks `create_plan completed_at`, chains to implement_plan.

5. **implement_plan.md** validates `.orchestration.json`, marks `implement started_at`, executes phases. Between phases, reads `.orchestration.json` for tmux window naming. When all phases complete, reads the plan frontmatter for `chain_on_complete` (falling back to `.orchestration.json` if absent), reads `.orchestration.json` once more for chain args, marks `implement completed_at`, chains to merge.

6. **merge.md** marks `merge started_at`, acquires the orchestration lock, merges `stage-N` branch into `base_branch`, atomically updates `status.json` to mark the stage completed, writes `merge_complete` event. If the wave is complete and more waves remain, bumps `current_wave` and spawns the next wave's stage sessions (each of which starts at step 2 for its own worktree). Marks `merge completed_at`. Finally (Step 6), removes the worktree — which removes `.orchestration.json` along with it.

If at any point the pipeline is re-run in a worktree where orchestration has ended (stage already `completed`, or orchestration_dir gone), `validate-orchestration.sh` deletes the stale `.orchestration.json` and returns non-zero, causing phase-audit blocks to skip and downstream chain sites to treat the run as non-orchestrated.

---

## Key file paths

- `/Users/kk/Sites/CodefiLabs/autorun/commands/orchestrate.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/start.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/research_codebase.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/create_plan.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/implement_plan.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/merge.md`
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/chain-next.sh`
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/validate-orchestration.sh`
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/update-phase-status.sh`
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/monitor-orchestration.sh`
