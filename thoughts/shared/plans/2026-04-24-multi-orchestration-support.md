# Multi-orchestration support in `.orchestration.json` — Implementation Plan

## Overview

Evolve `.orchestration.json` from a single-orchestration file to a session-keyed registry of active orchestrations. This eliminates the staleness class of bugs that commit `19f5d91` patches, because a command in tmux session X is unaffected by entries for session Y — stale or not. The file becomes an additive registry (entries are explicitly registered on stage start and unregistered on merge), not a single-object overwrite that must be cleaned up.

## Current State Analysis

See `thoughts/shared/research/2026-04-24-multi-orchestration-support.md` for the full factual basis. Summary of the relevant mechanics:

- `.orchestration.json` lives at `$WORKTREE_ROOT/.orchestration.json` and contains a single flat object with `stage_number`, `orchestration_dir`, `session_name`, `chain_on_complete` (commands/start.md:164-171).
- Four readers (`start.md` defensive, `research_codebase.md`, `create_plan.md`, `implement_plan.md`) and three deleters (`validate-orchestration.sh`, `merge.md` Step 6, `start.md` defensive) touch the file.
- The natural unique ID of a stage is its tmux session name `${PROJECT_SLUG}_stage-${STAGE_NUM}`, already stored in the `session_name` field.
- Staleness happens only when `merge.md` doesn't run (e.g., stage abandoned mid-flight) or runs outside a worktree — worktree removal normally sweeps the file.

## Desired End State

After this plan is complete:

- `.orchestration.json` is a session-keyed dict: `{"version": 2, "orchestrations": {"<session-name>": {...}}}`.
- Commands identify their orchestration context by looking up their own tmux session name (`tmux display-message -p '#S'`) in the registry.
- A stale entry for session Y cannot pollute a command running in session X. Staleness is handled silently at read time (entry with invalid `orchestration_dir`/`status.json` or `completed` stage returns "not orchestrated").
- `scripts/validate-orchestration.sh` is deleted; its callers use `get-orchestration-context.sh` instead.
- `merge.md` explicitly unregisters its session rather than deleting the whole file.
- Old v1 files are auto-migrated to v2 on first read/write, so existing worktrees mid-flight at the time of the change keep working.

### Verification

- Run the orchestrated pipeline end-to-end on a small master plan; observe `.orchestration.json` accumulates one entry per concurrent stage, entries are removed by merge, and the file is deleted when the last entry is unregistered.
- Run the non-orchestrated pipeline in a directory that already has a stale v1 `.orchestration.json`; observe the command treats it as non-orchestrated (no false positive) and does not error.

### Key Discoveries

- Tmux session name is available via `tmux display-message -p '#S'` inside the claude-command environment launched by `chain-next.sh` (verified during research — returned the current session name).
- The `mkdir <dir>.lock` atomic-lock pattern is already used by `scripts/update-phase-status.sh:34-36`; reusing it for `.orchestration.json` writes keeps the codebase consistent.
- `chain-next.sh` itself does not read `.orchestration.json` (scripts/chain-next.sh:20-24) — it receives `TARGET_SESSION` as an arg. So no changes are needed there; commands just pass the looked-up `session_name`.
- `merge.md` already receives `<orchestration-dir>` and `<stage-number>` as explicit arguments (commands/merge.md:10-18) and doesn't read `.orchestration.json` for logic — so the unregister hook only needs to plug into Step 6 cleanup.

## What We're NOT Doing

- Not changing the one-worktree-per-stage topology.
- Not introducing env-vars as an alternative orchestration-context source. The file stays the source of truth; `TMUX` env provides the lookup key only.
- Not GC-ing stale entries at read time by rewriting the file. The lookup silently returns "not found" for a stale entry; explicit GC only happens in `unregister-orchestration.sh` (removes one entry, deletes file if empty).
- Not changing the on-disk layout of `~/.autorun/orchestration/<plan-name>/` (status.json, events.jsonl, stages/).
- Not changing event types emitted to events.jsonl.
- Not changing how `monitor-orchestration.sh` or `check-orchestration-progress.sh` locate orchestrations (they read status.json directly, not `.orchestration.json`).
- Not supporting concurrent orchestrations sharing a worktree (remains out of scope even though the new schema makes it technically possible).

## Implementation Approach

Three phases, strictly additive until Phase 3's cleanup:

1. **Phase 1**: Create the three new helper scripts (`get-`, `register-`, `unregister-orchestration.sh`) with built-in self-tests. At the end of this phase the helpers exist but nothing calls them yet — the old pipeline still works.
2. **Phase 2**: Wire the helpers into the five commands (`start.md`, `research_codebase.md`, `create_plan.md`, `implement_plan.md`, `merge.md`). After this phase the v2 schema is live; v1 files are auto-migrated on first read/write by the helpers.
3. **Phase 3**: Delete `scripts/validate-orchestration.sh` and grep-verify zero callers remain.

---

## Phase 1: Create helper scripts (additive)

### Overview

Create three new bash scripts under `scripts/`. Each script is self-contained with no dependency on command-side changes. Each script is exercised by a standalone self-test block at the end of this phase.

### Changes Required

#### 1. `scripts/get-orchestration-context.sh`

**File**: `scripts/get-orchestration-context.sh` (new, chmod +x)

**Purpose**: Look up the orchestration context for the current tmux session. Prints `KEY=value` lines on stdout for `eval` consumption. Exits 1 if no active orchestration context for this session (including stale entries).

**Contents**:

```bash
#!/usr/bin/env bash
# Prints orchestration context for the current tmux session.
# Usage: get-orchestration-context.sh <worktree-root>
#
# Exit 0 → printed STAGE_NUM=, ORCH_DIR=, STATUS_FILE=, SESSION_NAME=, CHAIN_ON_COMPLETE= on stdout,
#          with values shlex-quoted so they're safe to consume with `eval`.
# Exit 1 → no active orchestration context for this session (no file, no entry, or stale entry).
#
# Staleness is detected silently (no deletions, no messages on stderr for common "not orchestrated" cases).
# The file is never modified by this script.
#
# Session lookup order: $AUTORUN_SESSION_OVERRIDE (for testing), then `tmux display-message -p '#S'`.
set -euo pipefail

WORKTREE_ROOT="${1:?Usage: get-orchestration-context.sh <worktree-root>}"
ORCH_FILE="$WORKTREE_ROOT/.orchestration.json"

[[ -f "$ORCH_FILE" ]] || exit 1

SESSION_NAME="${AUTORUN_SESSION_OVERRIDE:-$(tmux display-message -p '#S' 2>/dev/null || echo '')}"
[[ -n "$SESSION_NAME" ]] || exit 1

python3 - "$ORCH_FILE" "$SESSION_NAME" << 'PYEOF'
import json, os, shlex, sys

orch_file, session = sys.argv[1], sys.argv[2]

try:
    with open(orch_file) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(1)

# v1 schema compat: single flat object → treat as one entry keyed by its own session_name
if "orchestrations" not in data:
    if data.get("session_name") == session:
        entry = data
    else:
        sys.exit(1)
else:
    entry = data.get("orchestrations", {}).get(session)
    if not entry:
        sys.exit(1)

orch_dir = entry.get("orchestration_dir", "")
stage_num = entry.get("stage_number", "")
if not orch_dir or not os.path.isdir(orch_dir):
    sys.exit(1)

status_file = os.path.join(orch_dir, "status.json")
if not os.path.isfile(status_file):
    sys.exit(1)

try:
    with open(status_file) as f:
        status = json.load(f)
except (json.JSONDecodeError, OSError):
    sys.exit(1)

stage_status = status.get("stages", {}).get(str(stage_num), {}).get("status", "unknown")
if stage_status == "completed":
    sys.exit(1)

# shlex.quote makes values safe for `eval` consumers, crucial for chain_on_complete which
# contains a full slash-command string with spaces.
print(f"STAGE_NUM={shlex.quote(str(entry.get('stage_number', '')))}")
print(f"ORCH_DIR={shlex.quote(orch_dir)}")
print(f"STATUS_FILE={shlex.quote(status_file)}")
print(f"SESSION_NAME={shlex.quote(str(entry.get('session_name', '')))}")
print(f"CHAIN_ON_COMPLETE={shlex.quote(str(entry.get('chain_on_complete', '')))}")
PYEOF
```

Note: the script intentionally does NOT mutate the file. It is read-only. Staleness is silent — no stderr output, no deletion. Cleanup is the job of `unregister-orchestration.sh` at merge time. The `AUTORUN_SESSION_OVERRIDE` env var exists solely to make the script testable outside tmux.

#### 2. `scripts/register-orchestration.sh`

**File**: `scripts/register-orchestration.sh` (new, chmod +x)

**Purpose**: Upsert a single orchestration entry into `.orchestration.json` at the worktree root. Auto-migrates a v1 file to v2 on first write. Uses the `mkdir $LOCK_DIR` atomic lock pattern already used by `update-phase-status.sh`.

**Contents**:

```bash
#!/usr/bin/env bash
# Register or update an orchestration entry in <cwd>/.orchestration.json.
# Usage: register-orchestration.sh <session-name> <stage-number> <orchestration-dir> <chain-on-complete>
#
# Atomically upserts the entry keyed by <session-name>. Auto-migrates v1 (flat object) to v2 on first run.
set -euo pipefail

SESSION_NAME="${1:?Usage: register-orchestration.sh <session> <stage> <orch-dir> <chain>}"
STAGE_NUM="${2:?Missing stage number}"
ORCH_DIR="${3:?Missing orchestration dir}"
CHAIN_ON_COMPLETE="${4:-}"

ORCH_FILE="$(pwd)/.orchestration.json"
LOCK_DIR="${ORCH_FILE}.lock"

# Atomic lock (same pattern as update-phase-status.sh)
while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 0.1; done
trap "rmdir '$LOCK_DIR' 2>/dev/null" EXIT

python3 - "$ORCH_FILE" "$SESSION_NAME" "$STAGE_NUM" "$ORCH_DIR" "$CHAIN_ON_COMPLETE" << 'PYEOF'
import json, os, sys
from datetime import datetime, timezone

orch_file, session, stage_num, orch_dir, chain = sys.argv[1:6]

data = {}
if os.path.isfile(orch_file):
    try:
        with open(orch_file) as f:
            data = json.load(f)
    except json.JSONDecodeError:
        data = {}

# Migrate v1 → v2 (flat object with session_name → orchestrations dict)
if "orchestrations" not in data:
    if isinstance(data, dict) and "session_name" in data:
        data = {"version": 2, "orchestrations": {data["session_name"]: data}}
    else:
        data = {"version": 2, "orchestrations": {}}

data["version"] = 2
# Upsert: if a v1 migration produced an entry with the same session key, it is
# overwritten here with fresh values. This is intentional (re-running a stage
# re-registers it) — not a collision error.
data["orchestrations"][session] = {
    "stage_number": stage_num,
    "orchestration_dir": orch_dir,
    "session_name": session,
    "chain_on_complete": chain,
    "registered_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}

tmp = orch_file + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
os.rename(tmp, orch_file)
PYEOF

rmdir "$LOCK_DIR" 2>/dev/null
trap - EXIT
```

#### 3. `scripts/unregister-orchestration.sh`

**File**: `scripts/unregister-orchestration.sh` (new, chmod +x)

**Purpose**: Remove a single session's entry from `.orchestration.json`. Deletes the file entirely if no entries remain. No-op if the file doesn't exist.

**Contents**:

```bash
#!/usr/bin/env bash
# Remove an orchestration entry from <worktree-root>/.orchestration.json.
# Usage: unregister-orchestration.sh <worktree-root> <session-name>
#
# If the file has no more entries after removal, deletes the file.
# No-op if the file doesn't exist.
set -euo pipefail

WORKTREE_ROOT="${1:?Usage: unregister-orchestration.sh <worktree-root> <session-name>}"
SESSION_NAME="${2:?Missing session name}"

ORCH_FILE="$WORKTREE_ROOT/.orchestration.json"
[[ -f "$ORCH_FILE" ]] || exit 0

LOCK_DIR="${ORCH_FILE}.lock"
while ! mkdir "$LOCK_DIR" 2>/dev/null; do sleep 0.1; done
trap "rmdir '$LOCK_DIR' 2>/dev/null" EXIT

python3 - "$ORCH_FILE" "$SESSION_NAME" << 'PYEOF'
import json, os, sys

orch_file, session = sys.argv[1], sys.argv[2]

try:
    with open(orch_file) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError):
    # Corrupt or unreadable — just remove it
    try: os.remove(orch_file)
    except OSError: pass
    sys.exit(0)

# v1 compat: single flat object
if "orchestrations" not in data:
    if data.get("session_name") == session:
        os.remove(orch_file)
    sys.exit(0)

# v2: remove this entry
data.get("orchestrations", {}).pop(session, None)

if not data.get("orchestrations"):
    os.remove(orch_file)
else:
    tmp = orch_file + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.rename(tmp, orch_file)
PYEOF

rmdir "$LOCK_DIR" 2>/dev/null
trap - EXIT
```

### Success Criteria

#### Automated Verification

- [ ] `bash -n scripts/get-orchestration-context.sh` (syntax check) passes
- [ ] `bash -n scripts/register-orchestration.sh` passes
- [ ] `bash -n scripts/unregister-orchestration.sh` passes
- [ ] All three scripts are executable (`test -x scripts/get-orchestration-context.sh` etc.)
- [ ] Self-test (runs in a temp dir with fake status.json; uses `AUTORUN_SESSION_OVERRIDE` so no tmux is required):
  1. `register-orchestration.sh` creates a v2 file with one entry.
  2. `register-orchestration.sh` called a second time with a different session adds a second entry (file has 2).
  3. `AUTORUN_SESSION_OVERRIDE=<session1> get-orchestration-context.sh <dir>` prints context for session1 and exits 0.
  4. `AUTORUN_SESSION_OVERRIDE=unknown get-orchestration-context.sh <dir>` exits 1.
  5. `AUTORUN_SESSION_OVERRIDE=<session1> get-orchestration-context.sh <dir>` exits 1 when `orchestration_dir` does not exist on disk.
  6. `AUTORUN_SESSION_OVERRIDE=<session1> get-orchestration-context.sh <dir>` exits 1 when `status.json` reports stage as `completed`.
  7. `unregister-orchestration.sh <dir> <session1>` removes the entry; file still exists with the other entry.
  8. `unregister-orchestration.sh <dir> <session2>` removes the last entry; file is deleted.
  9. `register-orchestration.sh` migrates a v1 file (written by hand with the old flat schema) to v2 and adds the new entry, preserving the old entry keyed by its `session_name`.
- [ ] Tmux-wrapper self-test: spawn a throwaway tmux window running a shell that (a) registers a session, (b) calls `get-orchestration-context.sh` WITHOUT `AUTORUN_SESSION_OVERRIDE`, and (c) writes the result to a file. Verify the file contains the expected `SESSION_NAME=...` line matching the tmux window's session. This confirms `TMUX` env is inherited through tmux's own spawning path (not just the `chain-next.sh` wrapper's explicit `CLAUDE_*`/`ANTHROPIC_*` forwarding). If this fails, add `AUTORUN_SESSION` forwarding to `chain-next.sh` and document in Phase 2.

#### Manual Verification

- [ ] The three new scripts exist in `scripts/` and are tracked by git.
- [ ] No existing script references any of the new scripts yet (Phase 1 is additive).

**Implementation Note**: After completing Phase 1, pause for manual confirmation that the self-test sequence passes before proceeding to Phase 2.

---

## Phase 2: Wire helpers into the five commands

### Overview

Replace the current `.orchestration.json` read/write/delete call sites with calls to the new helpers. After this phase, the v2 schema is live throughout the pipeline; v1 files are auto-migrated by the helpers on first touch.

### Changes Required

#### 1. `commands/start.md`

**File**: `commands/start.md`

**Change A** — Replace the non-orchestrated defensive `validate-orchestration.sh` block (lines 53-57) with a no-op (remove the block entirely):

Before:
```bash
**In non-orchestrated mode** (task is not a stage context file), clean up any stale `.orchestration.json` left by a prior orchestration run before chaining — otherwise downstream phases will incorrectly treat this repo as an active orchestration stage:
```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-orchestration.sh "$WORKTREE_ROOT" 2>/dev/null || true
```
```

After: delete this entire block (section header plus bash fenced code). The new registry design handles staleness at read time, so no pre-emptive cleanup is required in non-orchestrated start.

**Change B** — Replace the `cat > .orchestration.json << EOF ... EOF` heredoc at lines 163-171 with a call to `register-orchestration.sh`:

Before:
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

After:
```bash
# Register this stage's orchestration context in .orchestration.json (session-keyed registry)
SESSION_NAME="${PROJECT_SLUG}_stage-${STAGE_NUM}"
bash ${CLAUDE_PLUGIN_ROOT}/scripts/register-orchestration.sh \
  "$SESSION_NAME" \
  "$STAGE_NUM" \
  "$ORCH_DIR" \
  "/autorun:merge $ORCH_DIR $STAGE_NUM"
```

**Change C** — Update the "If in orchestrated mode" detection at line 63 and the section "Orchestrated Mode" at line 144 to describe the new registry. Specifically, wherever the doc says `.orchestration.json exists`, clarify that detection is now "an entry for the current tmux session exists in `.orchestration.json`". The QUICK-tier branch (lines 63-79) continues to check for file existence plus session-match via a small helper snippet:

Insert this helper near the top of the file so all branches can use it:
```bash
# Helper: detect orchestrated mode for this session
# Sets $IN_ORCHESTRATED="true" and populates $STAGE_NUM/$ORCH_DIR/etc on success
if CTX=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-orchestration-context.sh "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null); then
  eval "$CTX"
  IN_ORCHESTRATED=true
else
  IN_ORCHESTRATED=false
fi
```

The QUICK branch's "If in orchestrated mode" conditional (start.md:63) then keys off `$IN_ORCHESTRATED`.

#### 2. `commands/research_codebase.md`

**File**: `commands/research_codebase.md`

**Change A** — Replace the Phase Audit block (lines 32-40):

Before:
```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
if bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-orchestration.sh "$WORKTREE_ROOT"; then
  STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
  STATUS_FILE=$(python3 -c "import json; d=json.load(open('$WORKTREE_ROOT/.orchestration.json')); import os; print(os.path.join(d['orchestration_dir'], 'status.json'))")
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" research started_at
fi
```

After:
```bash
WORKTREE_ROOT="$(git rev-parse --show-toplevel)"
if CTX=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-orchestration-context.sh "$WORKTREE_ROOT" 2>/dev/null); then
  eval "$CTX"
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" research started_at
fi
```

**Change B** — Replace the chain step block (lines 284-299) to use the same helper. The existing block reads `session_name` and `stage_number` from `.orchestration.json`; replace those reads with `eval "$CTX"`:

Before:
```bash
if [[ -f "$WORKTREE_ROOT/.orchestration.json" ]]; then
  SESSION_ARG=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json')).get('session_name', ''))")
  STAGE_NUM=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json'))['stage_number'])")
  WINDOW_NAME="s${STAGE_NUM}-cp"
  CLOSE_ARG=close
  STATUS_FILE=$(python3 -c "import json; d=json.load(open('$WORKTREE_ROOT/.orchestration.json')); import os; print(os.path.join(d['orchestration_dir'], 'status.json'))")
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" research completed_at
fi
```

After:
```bash
if CTX=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-orchestration-context.sh "$WORKTREE_ROOT" 2>/dev/null); then
  eval "$CTX"
  SESSION_ARG="$SESSION_NAME"
  WINDOW_NAME="s${STAGE_NUM}-cp"
  CLOSE_ARG=close
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/update-phase-status.sh "$STATUS_FILE" "$STAGE_NUM" research completed_at
fi
```

#### 3. `commands/create_plan.md`

**File**: `commands/create_plan.md`

**Change A** — Phase Audit block (lines 57-65): same transformation as research_codebase Change A. Replace with the `get-orchestration-context.sh` pattern, setting phase to `create_plan started_at`.

**Change B** — Orchestration context check during plan writing (lines 252-275): the existing block reads `chain_on_complete` from `.orchestration.json` to stamp it into plan frontmatter. Replace with the helper:

Before:
```bash
if [[ -f "$(pwd)/.orchestration.json" ]]; then
  # Extract orchestration metadata
  ORCH_DATA=$(cat "$(pwd)/.orchestration.json")
  # Extract chain_on_complete value
  CHAIN_ON_COMPLETE=$(python3 -c "import json; print(json.load(open('$(pwd)/.orchestration.json'))['chain_on_complete'])")
fi
```

After:
```bash
if CTX=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-orchestration-context.sh "$(pwd)" 2>/dev/null); then
  eval "$CTX"
  # CHAIN_ON_COMPLETE is now populated from the registered entry
fi
```

**Change C** — Chain step block (lines 408-429): same transformation as research_codebase Change B, but with `WINDOW_NAME="s${STAGE_NUM}-ip"` and phase `create_plan completed_at`.

#### 4. `commands/implement_plan.md`

**File**: `commands/implement_plan.md`

**Change A** — Phase Audit block (lines 22-30): same pattern, with phase `implement started_at`.

**Change B** — `chain_on_complete` fallback (lines 263-272): The existing block checks `.orchestration.json` as a fallback source of `chain_on_complete` when plan frontmatter has none. Replace with the helper:

Before:
```bash
if [[ -f "$WORKTREE_ROOT/.orchestration.json" ]]; then
  CHAIN_ON_COMPLETE=$(python3 -c "import json; print(json.load(open('$WORKTREE_ROOT/.orchestration.json')).get('chain_on_complete', ''))")
fi
```

After:
```bash
if CTX=$(bash ${CLAUDE_PLUGIN_ROOT}/scripts/get-orchestration-context.sh "$WORKTREE_ROOT" 2>/dev/null); then
  eval "$CTX"
  # CHAIN_ON_COMPLETE is now set from the registered entry
fi
```

**Change C** — Chain to next phase block (lines 286-305): replace with helper-based lookup; `WINDOW_NAME="s${STAGE_NUM}-ip-p${NEXT}"`.

**Change D** — Chain to merge block (lines 310-331): replace with helper-based lookup; `WINDOW_NAME="s${STAGE_NUM}-merge"`; phase `implement completed_at`.

#### 5. `commands/merge.md`

**File**: `commands/merge.md`

**Change** — Replace the Step 6 cleanup block at lines 418-438 to unregister the session entry instead of `rm`'ing the file. The `SESSION_NAME` is derivable from `$PROJECT_SLUG` and `$STAGE_NUM` (both already in scope from earlier steps):

Before:
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
else
  echo "Not in a worktree — skipping worktree removal"
  if [[ -f "$WORKTREE_PATH/.orchestration.json" ]]; then
    rm "$WORKTREE_PATH/.orchestration.json"
    echo ".orchestration.json removed"
  fi
fi
```

After:
```bash
PROJECT_SLUG=$(python3 -c "import json; print(json.load(open('$ORCH_DIR/status.json')).get('project_slug', ''))")
SESSION_NAME="${PROJECT_SLUG}_stage-${STAGE_NUM}"

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
  bash ${CLAUDE_PLUGIN_ROOT}/scripts/unregister-orchestration.sh "$WORKTREE_PATH" "$SESSION_NAME"
  echo "Unregistered $SESSION_NAME from $WORKTREE_PATH/.orchestration.json"
fi
```

Note: `PROJECT_SLUG` and `$STAGE_NUM` are already available in the merge.md execution context (`STAGE_NUM` from args parsing at Step 1, `PROJECT_SLUG` is read identically at commands/merge.md:324 for the next-wave launch case). The re-read at the top of the cleanup block is safe and cheap.

### Success Criteria

#### Automated Verification

- [ ] `grep -rn "\.orchestration\.json" commands/` returns only occurrences in comments or in the `tmp` path — no direct reads/writes via `cat`/`python3 -c "json.load(...)"` or `[[ -f ... ]]` branches remain.
- [ ] `grep -rn "validate-orchestration" commands/ scripts/` returns zero matches (other than the still-existing script file itself, deleted in Phase 3).
- [ ] `grep -rn "register-orchestration\|unregister-orchestration\|get-orchestration-context" commands/` returns one caller per expected site (1 in start, 1-3 in research_codebase, 1-3 in create_plan, 1-4 in implement_plan, 1 in merge).
- [ ] Command markdown files parse as valid markdown (`find commands -name '*.md' -print0 | xargs -0 grep -c '^```bash$'` returns expected counts — no unclosed fences).

#### Manual Verification

- [ ] Run an end-to-end LARGE-tier non-orchestrated pipeline (`/autorun:start "Fix foo bug"` in a clean repo) — confirm no `.orchestration.json` is created and the run completes.
- [ ] Run an end-to-end orchestrated single-stage pipeline on a small master plan — confirm `.orchestration.json` appears at the worktree root with v2 schema during the run, and is removed (or the worktree is removed) at merge time.
- [ ] Simulate a two-stage wave by hand: register two sessions into the same `.orchestration.json`, then unregister one. Confirm the other entry survives intact.
- [ ] Place a v1 `.orchestration.json` (the old flat-object schema) at a repo root and trigger `register-orchestration.sh` via `start.md` — confirm the file is auto-migrated to v2 with both the old and new entries.

**Implementation Note**: After completing Phase 2, pause for manual confirmation before proceeding to Phase 3.

---

## Phase 3: Delete `validate-orchestration.sh`

### Overview

With all callers migrated to `get-orchestration-context.sh`, `validate-orchestration.sh` is dead code. Delete it.

### Changes Required

#### 1. Delete `scripts/validate-orchestration.sh`

**File**: `scripts/validate-orchestration.sh` → `git rm`

**Pre-delete check**: verify zero callers remain:

```bash
grep -rn "validate-orchestration" commands/ scripts/
# Expected output: empty
```

If the check returns matches, do NOT delete — revisit Phase 2 to find the miss.

### Success Criteria

#### Automated Verification

- [ ] `scripts/validate-orchestration.sh` no longer exists.
- [ ] `grep -rn "validate-orchestration" commands/ scripts/` returns zero matches.
- [ ] `grep -rn "validate-orchestration" .` returns matches only inside `thoughts/` (the research and plan documents reference the historical script).
- [ ] Pipeline commands still parse correctly (no broken references in command markdown).

#### Manual Verification

- [ ] End-to-end orchestrated pipeline runs without referencing the deleted script (confirmed by absence of `validate-orchestration` in pipeline logs).

**Implementation Note**: Commit this phase as a separate commit titled e.g. `remove validate-orchestration.sh (superseded by orchestration registry)` to keep the cleanup distinct from the registry introduction.

---

## Testing Strategy

### Unit-like tests (in Phase 1 self-test block)

- `register-orchestration.sh` creates a valid v2 file.
- `register-orchestration.sh` is additive (second call doesn't overwrite first entry).
- `register-orchestration.sh` auto-migrates a hand-crafted v1 file.
- `get-orchestration-context.sh` resolves context for the current session; returns 1 for unregistered sessions and stale entries (three staleness subcases: missing orch dir, missing status.json, stage completed).
- `unregister-orchestration.sh` removes one entry; removes file when last entry gone; v1 compat when session matches.

### Integration tests

- **Orchestrated single-stage**: run a one-stage master plan end-to-end. Observe `.orchestration.json` appear at register time, persist through phases, and disappear at merge time (via worktree removal).
- **Orchestrated multi-stage wave**: run a two-stage wave. Observe each stage's worktree has its own `.orchestration.json` with one entry. Merge one stage first, then the other. (These are different worktrees, so there is no shared file — this just confirms the per-worktree invariant still holds.)
- **Non-orchestrated with stale v1 file**: manually place a stale v1 `.orchestration.json` at the main repo root, then run `/autorun:start "quick fix"`. Expected: the old file is silently ignored (no staleness-detection noise), the non-orchestrated flow runs, and any downstream `get-orchestration-context.sh` call returns "not orchestrated" (exit 1). The old file is NOT deleted during the non-orchestrated run (by design — no sweep), but it will be migrated + updated the next time an orchestrated run writes to it.

### Manual testing steps

1. From the repo root, run the Phase 1 self-test script (created inline in that phase).
2. Clone or create a test repo with a trivial master plan (1 stage, 1 phase).
3. Run `/autorun:orchestrate <master-plan>` and watch the pipeline through merge.
4. Inspect `.orchestration.json` at the worktree root during the run — confirm v2 schema with one entry.
5. After merge, confirm the worktree is removed (normal case) or the entry is unregistered (non-worktree case).

## Performance Considerations

- The registry file is expected to stay small (one entry per concurrent stage, bounded by wave width — typically ≤ 5 stages). JSON read/write latency is negligible.
- `tmux display-message` is a cheap local IPC call (~ms).
- Lock contention on `.orchestration.json.lock` is bounded by the low write rate (once per stage at register, once per stage at unregister) and the same pattern is already used heavily by `update-phase-status.sh` without issues.

## Migration Notes

- **v1 → v2 auto-migration**: the first time `register-orchestration.sh` runs against a v1 file, it converts the flat object to `{"version": 2, "orchestrations": {"<session-name>": <old-object>}}`. The old session's entry is preserved.
- **Mid-flight orchestrations** (stages already running when this change lands): the old heredoc in `start.md` has already created a v1 file in those worktrees. Subsequent phase-audit reads go through `get-orchestration-context.sh`, which has explicit v1 compat (reads flat objects if `orchestrations` key is absent and `session_name` matches). Subsequent writes (only merge.md's unregister) also have v1 compat. So in-flight stages continue to work end-to-end with no manual intervention.
- **Repos with stale v1 files on disk**: `get-orchestration-context.sh` silently returns "not orchestrated" for stale v1 files (the v1 branch still applies `orchestration_dir`/`status.json` staleness checks). The file is left in place until the next orchestrated run writes to it; at that point it is migrated to v2.

## References

- Research: `thoughts/shared/research/2026-04-24-multi-orchestration-support.md`
- Commit motivating this change: `19f5d91` — "make sure and old orchestration files are removed when starting a new one"
- Similar lock pattern: `scripts/update-phase-status.sh:34-36`

## Research Findings

Full agent findings are preserved in the findings directory:
- `thoughts/shared/research/findings/2026-04-24-multi-orchestration-support/codebase-analyzer-orchestration-lifecycle.md`
- `thoughts/shared/research/findings/2026-04-24-multi-orchestration-support/codebase-analyzer-worktree-stage-relationship.md`
- `thoughts/shared/research/findings/2026-04-24-multi-orchestration-support/codebase-analyzer-status-json.md`
