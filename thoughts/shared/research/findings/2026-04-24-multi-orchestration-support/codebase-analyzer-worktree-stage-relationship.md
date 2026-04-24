# Worktree ↔ Orchestration Stage Relationship

Analysis of how worktrees relate to orchestration stages in the autorun repo.

Scope of primary sources read:
- `/Users/kk/Sites/CodefiLabs/autorun/commands/orchestrate.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/merge.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/start.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/research_codebase.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/create_plan.md`
- `/Users/kk/Sites/CodefiLabs/autorun/commands/implement_plan.md`
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/chain-next.sh`
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/monitor-orchestration.sh`
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/check-orchestration-progress.sh`
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/validate-orchestration.sh`

---

## 1. Worktrees per orchestration run — one per stage

Each stage gets its own worktree. Waves are just topological groupings of stages; there is no wave-level worktree.

At orchestrate-time, Wave 1 stages are launched via a `tmux new-session` invocation per stage. The `--worktree` flag on the `claude` CLI creates an isolated worktree named after the stage:

`/Users/kk/Sites/CodefiLabs/autorun/commands/orchestrate.md:172-178`:
```bash
SESSION_NAME="${PROJECT_SLUG}_stage-${STAGE_NUM}"
CONTEXT_FILE="$ORCH_DIR/stages/stage-${STAGE_NUM}-context.md"

tmux new-session -d -s "$SESSION_NAME" -n "s${STAGE_NUM}" \
  "claude --worktree 'stage-${STAGE_NUM}' '/autorun:start $CONTEXT_FILE'"
```

The same pattern is used for launching subsequent waves from `merge.md` once the previous wave has fully merged (`/Users/kk/Sites/CodefiLabs/autorun/commands/merge.md:327-333`):
```bash
SESSION_NAME="${PROJECT_SLUG}_stage-${STAGE}"
CONTEXT_FILE="$ORCH_DIR/stages/stage-${STAGE}-context.md"
tmux new-session -d -s "$SESSION_NAME" -n "s${STAGE}" \
  "claude --worktree 'stage-${STAGE}' '/autorun:start $CONTEXT_FILE'"
```

The orchestrate.md header confirms the rationale: "`--worktree` provides isolation for parallel stages." (`orchestrate.md:180`, repeated at `merge.md:342`).

Total worktrees created over the lifetime of one orchestration run = total stages in the plan (one per stage). There is no per-wave or per-phase worktree — phases (research → create_plan → implement → merge) all run inside the same stage worktree.

---

## 2. Where worktrees are created (path pattern)

The `claude --worktree 'stage-${STAGE_NUM}'` flag delegates worktree creation to the `claude` CLI itself; `orchestrate.md`, `merge.md`, and `start.md` never specify the filesystem path. What they pass is a worktree **label/name** ("stage-1", "stage-2", ...), not a path.

Indirect evidence of the filesystem layout comes from `monitor-orchestration.sh:201-208`, which lists local branches prefixed with `worktree-stage-*` to check for recent commits:
```bash
for branch in $(git -C "$PROJECT_ROOT" branch --list 'worktree-stage-*' 2>/dev/null | sed 's/^[* ]*//'); do
    last_commit=$(git -C "$PROJECT_ROOT" log "$branch" --since="2 hours ago" --oneline -1 2>/dev/null || true)
    ...
done
```
That implies branches are named `worktree-stage-<N>`; the actual worktree directories live wherever the `claude --worktree` CLI places them (not specified in this repo's scripts).

When cleanup runs in `merge.md:420-424`, the worktree location is discovered at runtime via git metadata rather than being hardcoded:
```bash
WORKTREE_PATH="$(git rev-parse --show-toplevel)"
if [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  IN_WORKTREE=true
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  MAIN_REPO="$(git rev-parse --git-common-dir | sed 's|/\.git/worktrees/.*||')"
  ...
```
That sed strip (`/\.git/worktrees/...`) confirms worktrees live under `<main-repo>/.git/worktrees/<name>` from git's perspective (this is how `git-common-dir` points there), but the checkout directory where `show-toplevel` returns is wherever the `claude` CLI decided to place it.

Net: **the worktree path is chosen by the `claude --worktree <label>` CLI, not by this codebase's scripts.** The stage number appears only in the label ("stage-N") and in the local branch name (`worktree-stage-N` per the monitor script).

---

## 3. Can the main (non-worktree) checkout ever run an orchestration stage?

Yes, under specific conditions — the non-worktree code path is explicitly handled in `merge.md:431-437`:
```bash
else
  echo "Not in a worktree — skipping worktree removal"
  if [[ -f "$WORKTREE_PATH/.orchestration.json" ]]; then
    rm "$WORKTREE_PATH/.orchestration.json"
    echo ".orchestration.json removed"
  fi
fi
```

This branch fires when `git rev-parse --git-dir` equals `git rev-parse --git-common-dir`, i.e. the merge is running in the main checkout.

The conditions under which this happens:

1. **A single-tier (non-orchestrated) run in the main repo.** `start.md:53-57` clears any stale `.orchestration.json` in the worktree root at triage time for non-orchestrated runs:
   ```bash
   WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-orchestration.sh "$WORKTREE_ROOT" 2>/dev/null || true
   ```
   If the user runs `/autorun:start` directly in the main checkout (e.g. for a QUICK or MEDIUM task), the whole pipeline happens there, and if `.orchestration.json` was left behind by a prior run, the non-worktree cleanup branch in `merge.md` is the final sweeper.

2. **Stale `.orchestration.json` from a prior orchestration.** `validate-orchestration.sh` (`/Users/kk/Sites/CodefiLabs/autorun/scripts/validate-orchestration.sh:10-38`) removes the file when:
   - `orchestration_dir` is missing from disk
   - `status.json` is missing
   - The stage is already marked `completed`
   
   Each pipeline phase (`research_codebase.md:33-40`, `create_plan.md:58-65`, `implement_plan.md:23-30`) calls `validate-orchestration.sh` before updating phase status, which means a stale file in the main repo is gated from being treated as live orchestration.

3. **If someone invokes `/autorun:merge <orch-dir> <stage-num>` from the main repo directly** (rather than via chain_on_complete from a stage worktree), the non-worktree branch of `merge.md:431-437` is what cleans up the stray `.orchestration.json`.

In normal orchestrated operation, the merge Task runs inside the stage worktree (the one `chain-next.sh` placed it in via `WORK_DIR`), so it takes the `IN_WORKTREE=true` branch. The non-worktree branch is a defensive cleanup for the case where the merge (or prior phases) end up executing in the main checkout.

---

## 4. How `chain-next.sh` passes context to the next phase

**`chain-next.sh` does NOT read `.orchestration.json`.** It is a pure command launcher — it passes:
- A complete claude command string (argument 1) through a temp file to avoid quoting issues
- A window name (argument 2)
- A target tmux session (argument 3) — appends to that session if it exists, else creates a new session
- A working directory (argument 4) — where to chdir before running claude
- A close-caller flag (argument 5) — whether to kill the calling tmux window after the new one is created

See the arg parsing at `/Users/kk/Sites/CodefiLabs/autorun/scripts/chain-next.sh:20-24`:
```bash
CLAUDE_CMD="${1:?Usage: chain-next.sh <claude-command> [window-name] [target-session] [work-dir] [close-caller]}"
WINDOW_NAME="${2:-autorun}"
TARGET_SESSION="${3:-}"
WORK_DIR="${4:-}"
CLOSE_CALLER="${5:-}"
```

State is passed two ways, neither of which is `.orchestration.json`:

**(a) In the claude command itself.** The caller embeds everything the next phase needs in the command string. E.g. from `create_plan.md:428`:
```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/chain-next.sh "/autorun:implement_plan <plan-path>" "$WINDOW_NAME" "$SESSION_ARG" "" "$CLOSE_ARG"
```
The plan path (which holds the detailed phases) is baked into the command string.

**(b) Via the worktree's filesystem.** Because `chain-next.sh:27-33` auto-detects the worktree CWD when `WORK_DIR` isn't passed:
```bash
if [[ -z "$WORK_DIR" ]]; then
  _git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
  _git_common=$(git rev-parse --git-common-dir 2>/dev/null || true)
  if [[ -n "$_git_dir" && -n "$_git_common" && "$_git_dir" != "$_git_common" ]]; then
    WORK_DIR=$(git rev-parse --show-toplevel)
  fi
fi
```
…the new tmux window opens in the same worktree. That means when the next phase runs `git rev-parse --show-toplevel` and reads `.orchestration.json`, it finds the file written by `start.md:163-171`:
```bash
cat > .orchestration.json << EOF
{
  "stage_number": "$STAGE_NUM",
  "orchestration_dir": "$ORCH_DIR",
  "session_name": "${PROJECT_SLUG}_stage-${STAGE_NUM}",
  "chain_on_complete": "/autorun:merge $ORCH_DIR $STAGE_NUM"
}
EOF
```

So the contract is: `start.md` writes `.orchestration.json` once at the top of each stage; `chain-next.sh` just keeps subsequent windows pointed at the same worktree; downstream phases (`research_codebase.md`, `create_plan.md`, `implement_plan.md`) read the file themselves after calling `validate-orchestration.sh`.

`chain-next.sh` is context-blind about orchestration. All the context-passing logic is in the commands that call it.

---

## 5. Can two orchestrations collide in the same worktree/main repo?

### Two orchestrations, same worktree path simultaneously

Possible in principle, because the `claude --worktree 'stage-N'` label is relative to the current project root. If two orchestrations run against the same project root and both pick `stage-1`, `stage-2`, ... labels, they would collide on both:
- Worktree label (`stage-1`) — git will refuse to create a second worktree with the same label.
- Branch name (`worktree-stage-1` per `monitor-orchestration.sh:201`) — git will refuse to create a second branch with the same name.

There is no scoping by `plan_name` or `project_slug` in the `--worktree` label. The `project_slug` appears only in the **tmux session name** (`${PROJECT_SLUG}_stage-${STAGE_NUM}`, `orchestrate.md:173` and `merge.md:329`), which prevents tmux session collisions but does not prevent worktree-path collisions.

The failure mode is deferred to the `claude --worktree` CLI, not handled by the autorun scripts.

### Two orchestrations, both running in the main repo

The main repo holds exactly one `.orchestration.json` at any time (`start.md:163-171` writes it at the repo root, `validate-orchestration.sh:17` removes it when stale, `merge.md:433` removes it on merge). If two orchestrations both tried to use the main checkout (non-worktree) simultaneously, they would overwrite each other's `.orchestration.json`, and the phase status updates, merge, and cleanup would point at whichever orchestration wrote last.

The orchestrated flow avoids this by always spawning stages into their own worktrees via `--worktree`. The main repo runs only for non-orchestrated (direct-invocation) `/autorun:start` calls, and there is no locking that would prevent two such calls from stepping on each other's `.orchestration.json` if one were accidentally present.

---

## 6. Where each command runs: main repo vs. worktree

### `orchestrate` (setup) — runs in main repo

`orchestrate.md:52-56` detects the project root:
```bash
PROJECT_ROOT=$(git rev-parse --show-toplevel)
BASE_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
```
It writes stage context files to `~/.autorun/orchestration/<plan-name>/stages/` and `status.json` to `~/.autorun/orchestration/<plan-name>/status.json` — both outside any project worktree. It then launches Wave 1 tmux sessions where each one spawns a `claude --worktree 'stage-N'`. `orchestrate` itself never enters a worktree.

### `start` (stage triage) — runs inside the stage worktree

Each `tmux new-session` launched by `orchestrate.md:172-178` or `merge.md:327-333` invokes `claude --worktree 'stage-${STAGE_NUM}' '/autorun:start $CONTEXT_FILE'`, so `start.md` executes inside the freshly-created stage worktree. That is where `.orchestration.json` gets written (`start.md:163-171`).

For non-orchestrated direct invocations, `start.md` runs wherever the user invoked it from (typically the main repo).

### `research_codebase` — runs inside the stage worktree (orchestrated) or main repo (non-orchestrated)

Chained from `start.md:189` via `chain-next.sh` with `$SESSION_ARG=${PROJECT_SLUG}_stage-N` and no explicit `WORK_DIR`. Because `chain-next.sh:27-33` auto-detects the worktree CWD and the new window is created inside the existing stage tmux session, it runs in the worktree. `research_codebase.md:33-40` reads `.orchestration.json` from the worktree root via `validate-orchestration.sh`.

For non-orchestrated LARGE-tier runs, there is no `.orchestration.json`, so the phase-audit block is skipped and research happens in whatever dir `start.md` was launched from.

### `create_plan` — runs inside the stage worktree (orchestrated) or main repo (non-orchestrated)

Same mechanism as research_codebase: chained from either `start.md:185` (MEDIUM) or `research_codebase.md:302` (after LARGE research). `chain-next.sh` auto-detects the worktree and opens the new window there. `create_plan.md:58-65` reads `.orchestration.json` from the worktree root.

### `implement_plan` — runs inside the stage worktree (orchestrated) or main repo (non-orchestrated)

Chained from either `start.md:181` (QUICK) or `create_plan.md:428` (after MEDIUM/LARGE plan). Same worktree inheritance pattern. `implement_plan.md:23-30` reads `.orchestration.json` from the worktree root.

### `merge` — runs inside the stage worktree (initially), then cds back to main repo

The merge command is invoked via `chain_on_complete` in the plan frontmatter after implement_plan finishes. It starts in the worktree (that's where implement_plan was running). Step 2 of `merge.md:107-113` performs the actual git merge in the MAIN repo — it explicitly `cd "$PROJECT_ROOT"` and checks out `BASE_BRANCH` there:
```bash
cd "$PROJECT_ROOT"
git checkout "$BASE_BRANCH"
git merge "$STAGE_BRANCH" --no-edit
```

The worktree cleanup is deferred to Step 6 (`merge.md:412-438`), which explicitly notes: "It is deferred to here because the merge session's CWD may be the worktree itself. If the worktree is removed earlier (e.g., in Step 2), all subsequent Task spawns fail because their session CWD no longer exists."

---

## 7. What happens after `merge` runs

Two paths, from `merge.md:419-438`:

### In-worktree path
```bash
if [ "$(git rev-parse --git-dir)" != "$(git rev-parse --git-common-dir)" ]; then
  IN_WORKTREE=true
  BRANCH="$(git rev-parse --abbrev-ref HEAD)"
  MAIN_REPO="$(git rev-parse --git-common-dir | sed 's|/\.git/worktrees/.*||')"

  cd "$MAIN_REPO"
  git worktree remove --force "$WORKTREE_PATH" 2>/dev/null
  git worktree prune
  git branch -D "$BRANCH" 2>/dev/null
  echo "Worktree cleaned up: $WORKTREE_PATH"
```
- The worktree is force-removed
- The stage's branch (e.g. `worktree-stage-3`) is deleted
- `git worktree prune` removes any dangling worktree metadata
- `.orchestration.json` disappears along with the worktree itself

Failures are non-fatal (`merge.md:440`): "The worktree may already be gone if another process cleaned it up."

### Non-worktree path
```bash
else
  echo "Not in a worktree — skipping worktree removal"
  if [[ -f "$WORKTREE_PATH/.orchestration.json" ]]; then
    rm "$WORKTREE_PATH/.orchestration.json"
    echo ".orchestration.json removed"
  fi
fi
```
- No worktree to remove (the merge ran in the main checkout)
- If a stray `.orchestration.json` exists in the main checkout, it gets deleted explicitly
- No branch deletion happens — presumably because the merge in the main repo is running on the same branch (nothing to delete) or the branch is whatever the user checked out

`status.json` in `~/.autorun/orchestration/<plan-name>/` is updated earlier in Step 3 regardless of path (`merge.md:168-231`), with the stage marked completed and events emitted.

---

## 8. `TARGET_SESSION` argument to `chain-next.sh`

`chain-next.sh:22` defines it: `TARGET_SESSION="${3:-}"`. Its presence determines whether chain-next.sh adds a window to an existing tmux session or creates a new session.

The key logic is at `/Users/kk/Sites/CodefiLabs/autorun/scripts/chain-next.sh:126-143`:
```bash
NEW_WINDOW_TARGET=""
if [[ -n "$TARGET_SESSION" ]] && tmux has-session -t "$TARGET_SESSION" 2>/dev/null; then
  tmux new-window -t "$TARGET_SESSION" -n "$WINDOW_NAME" \
    ${WORK_DIR:+-c "$WORK_DIR"} \
    "$WRAPPER"
  NEW_WINDOW_TARGET="${TARGET_SESSION}:${WINDOW_NAME}"
else
  SESSION_NAME="$WINDOW_NAME"
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    SESSION_NAME="${WINDOW_NAME}-$(date +%s)"
  fi
  tmux new-session -d -s "$SESSION_NAME" -n "$WINDOW_NAME" \
    ${WORK_DIR:+-c "$WORK_DIR"} \
    "$WRAPPER"
  NEW_WINDOW_TARGET="${SESSION_NAME}:${WINDOW_NAME}"
  echo "Started tmux session: $SESSION_NAME"
  echo "Attach with: tmux attach -t $SESSION_NAME"
fi
```

Behavior:

**`TARGET_SESSION` present and that session exists** — orchestrated mode. The next phase opens as a **new window inside the existing stage session** (named `${PROJECT_SLUG}_stage-${STAGE_NUM}`). This keeps the whole phase chain for one stage grouped under one tmux session. Combined with `CLOSE_CALLER="close"` (set whenever the caller is in orchestrated mode — e.g. `start.md:181`, `create_plan.md:418`, `research_codebase.md:292`), the previous phase's window is killed ~1s after the new window is created (`chain-next.sh:157-159`), so the session always holds roughly one active window per stage.

The session exists because `orchestrate.md:172-178` created it with `tmux new-session -d -s "$SESSION_NAME"` before the first `claude --worktree` call. `TARGET_SESSION` carries the session name between phases so the chain remains visible/attachable at `tmux attach -t ${PROJECT_SLUG}_stage-N`.

**`TARGET_SESSION` empty (or points to a non-existent session)** — unorchestrated mode. The script creates a **brand new tmux session** named after `WINDOW_NAME`. If a session of that name already exists, it appends the current Unix timestamp to disambiguate (`chain-next.sh:135-136`):
```bash
if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  SESSION_NAME="${WINDOW_NAME}-$(date +%s)"
fi
```
This is the path for direct `/autorun:start` invocations outside orchestration, where each new phase spawns its own fresh session (prints "Attach with: tmux attach -t $SESSION_NAME" for the user).

The comment at `chain-next.sh:123-125` summarizes the design intent:
```
#   TARGET_SESSION given → add a window inside that session (orchestrated stage sessions)
#   No TARGET_SESSION  → always create a new named tmux session (keeps user's terminal clean)
```

Callers pass empty string for `TARGET_SESSION` in non-orchestrated branches (`start.md:98`, `:105`, `:112`, `:141`) and pass `"$SESSION_ARG"` in orchestrated branches (`start.md:181`, `:185`, `:189` via the `$SESSION_ARG` that was computed from `.orchestration.json`; plus `create_plan.md:428` and `research_codebase.md:302` which read the same file).

---

## Summary of the mental model

- **Worktree = stage**, not phase and not wave. All four phases (research, create_plan, implement, merge-start) for a single stage run in the same worktree, chained via tmux windows within one session.
- **tmux session = stage**. Named `${PROJECT_SLUG}_stage-${N}`. Windows within the session are phases. `CLOSE_CALLER="close"` keeps roughly one window active at a time.
- **Orchestration state is file-based**:
  - Global: `~/.autorun/orchestration/<plan-name>/status.json` + `events.jsonl`
  - Per-stage: `<worktree>/.orchestration.json` (stage num + orch dir + session name + chain_on_complete)
- **`chain-next.sh` is orchestration-agnostic**. It ferries claude commands and inherits/targets tmux sessions; all the orchestration context lives in `.orchestration.json` + the embedded command strings.
- **Merge does git work in the main repo, then cleans the worktree**. The non-worktree branch handles the case where merge ended up running in the main checkout directly.
