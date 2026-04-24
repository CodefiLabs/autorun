# status.json — Structure and Usage in autorun

Documentation-only analysis. Describes what exists in the codebase; does not propose changes.

Date: 2026-04-24
Scope: `/Users/kk/Sites/CodefiLabs/autorun`

---

## 1. Exact schema of status.json

The initial schema is written by `orchestrate.md` step 2 (`/Users/kk/Sites/CodefiLabs/autorun/commands/orchestrate.md:111-141`). Subsequent mutations add an overall `status` field and `completed_at` at the top level (written in `/Users/kk/Sites/CodefiLabs/autorun/commands/merge.md:386-387`).

### Top-level fields

| Field | Type | Set by | Notes |
|---|---|---|---|
| `plan_path` | string | `orchestrate.md:114` | Absolute path to the master plan. |
| `plan_name` | string | `orchestrate.md:115` | Derived kebab-case name of the master plan file (strip path + extension). Also used as the directory name under `~/.autorun/orchestration/`. |
| `project_slug` | string | `orchestrate.md:116` | Short slug (max ~20 chars) used for tmux session naming (`<slug>_stage-<N>`) and log file naming (`<slug>-monitor.log`). Derivation rules in `orchestrate.md:62-66`: strip leading `YYYY-MM-DD-`, strip `wave\d+-?` prefix, take first 2-3 kebab words. |
| `project_root` | string | `orchestrate.md:117` | Absolute path to the git project root (from `git rev-parse --show-toplevel`). |
| `base_branch` | string | `orchestrate.md:118` | The branch active when orchestration started (`git rev-parse --abbrev-ref HEAD`). All stage worktrees branch off it and all merges target it — explicitly not necessarily `main`/`master`. |
| `created_at` | ISO 8601 timestamp | `orchestrate.md:119` | UTC. |
| `stages` | object | `orchestrate.md:120-137` | Map: stage number (string key) → stage object. See schema below. |
| `current_wave` | integer | `orchestrate.md:138` | 1-indexed. Incremented atomically in `merge.md:292-298`. |
| `waves` | array of arrays of integers | `orchestrate.md:139` | Example: `[[1], [2,3,4], [5]]` — each inner array is a topological wave. |
| `status` | string (optional) | `merge.md:385` | Added only at the very end when all waves complete; set to `"completed"`. |
| `completed_at` | ISO 8601 timestamp (optional) | `merge.md:386` | Added only at the very end (UTC). |
| `integration_check` | string (optional) | `merge.md:403-405` | Optional field — "a command or plan path"; when present, `merge.md` chains to it via `chain-next.sh` after final completion. Not written by `orchestrate.md`; presumably set manually or by an unseen writer. |

### Per-stage fields (`stages.<N>`)

| Field | Type | Notes |
|---|---|---|
| `status` | string | One of `pending`, `in_progress`, `completed`, `failed` (see §2). Flipped to `completed` in `merge.md:178`. No script writes `in_progress` or `failed` explicitly in the files examined — the initial value is `pending` and terminal is `completed`; `failed` is read but the write path isn't in the scripts examined. |
| `name` | string | Human-readable stage title. |
| `depends_on` | array of integers | Stage numbers that must complete first. |
| `branch` | string \| null | Stage branch name. Initialized `null`. |
| `context_file` | string | Absolute path to `$ORCH_DIR/stages/stage-N-context.md`. |
| `plan_file` | string \| null | Populated later — read in `check-orchestration-progress.sh:122`. |
| `started_at` | timestamp \| null | Stage-level start. Initialized `null`. |
| `completed_at` | timestamp \| null | Set to a UTC ISO 8601 string in `merge.md:179`. |
| `phases` | object | Per-phase sub-records. See below. |

### Per-phase fields (`stages.<N>.phases.<phase>`)

Phase names used: `setup`, `research`, `create_plan`, `implement`, `merge`, `triage`. Only `research`, `create_plan`, `implement`, `merge` are pre-created in the initial schema (`orchestrate.md:131-135`). `triage` is added on-the-fly by `update-phase-status.sh` (see `start.md:174`). `setup` appears only in the usage help of `update-phase-status.sh:19`.

Each phase object has:
- `started_at` — timestamp \| null
- `completed_at` — timestamp \| null

The `implement` phase additionally tracks:
- `current_phase` — integer \| null (progress indicator)
- `total_phases` — integer \| null (total implementation sub-phases)

The phase-auto-create code in `update-phase-status.sh:47-48` only sets `started_at`/`completed_at` when creating a phase lazily; `current_phase`/`total_phases` get added by passing those field names as arguments (`update-phase-status.sh:14-15`).

---

## 2. Possible stage statuses

Authoritative enumeration in `/Users/kk/Sites/CodefiLabs/autorun/scripts/check-orchestration-progress.sh:69-74`:

```bash
case "$status" in
  pending)     icon="[ ]"; ((pending++)) ;;
  in_progress) icon="[~]"; ((in_progress++)) ;;
  completed)   icon="[x]"; ((completed++)) ;;
  failed)      icon="[!]"; ((failed++)) ;;
  *)           icon="[?]" ;;
esac
```

Stage-level status values: `pending`, `in_progress`, `completed`, `failed`.

- `pending` — set at initialization (`orchestrate.md:122`).
- `completed` — set by `merge.md:178`.
- `in_progress`, `failed` — read by `monitor-orchestration.sh:98-100, 158`, `check-orchestration-progress.sh`, and `merge.md` (terminal-state check), but no explicit writer to these values exists in the files examined.

**Phase-level** has no status enum. Phases are tracked solely by presence/absence of `started_at` and `completed_at` timestamps (see derivation at `monitor-orchestration.sh:78-81`: a phase is "active" if `started_at` is set and `completed_at` is not).

**Overall orchestration status** (top-level `status` field): only value observed is `"completed"` (set in `merge.md:385`).

**Terminal-state classification** (from `monitor-orchestration.sh:98-100`): `completed` and `failed` are treated as terminal; `ALL_COMPLETE` requires every stage to be `completed`; `DONE_WITH_FAILURES` when all are terminal but at least one is `failed`.

---

## 3. orchestration_dir path construction

Defined in `/Users/kk/Sites/CodefiLabs/autorun/commands/orchestrate.md:87-89`:

```bash
ORCH_DIR="$HOME/.autorun/orchestration/$PLAN_NAME"
mkdir -p "$ORCH_DIR/stages"
```

- Base: `$HOME/.autorun/orchestration/`
- Subdirectory: `$PLAN_NAME` — the derived kebab-case name of the master plan file (`orchestrate.md:57-60`: strip path and `.md` extension, convert to kebab-case; example: `wave_2_master_plan.md` → `wave-2-master-plan`).
- **No timestamp** is embedded in the path. The directory name is purely derived from the plan filename.
- Only `created_at` (top-level ISO 8601 string in status.json) captures creation time.

Directory contents after initialization:

```
~/.autorun/orchestration/<plan-name>/
  status.json
  events.jsonl                           # appended to, never pre-created
  stages/
    stage-1-context.md
    stage-2-context.md
    ...
  .merge.lock                            # flock target (merge.md:102, 158, 268)
  status.json.lock                       # mkdir-based lock dir (update-phase-status.sh:34)
  status.json.tmp                        # atomic-write intermediate (merge.md:194)
  conflicts.md                           # optional, on autonomous conflict resolution (merge.md:132)
```

The recent commit `19f5d91` ("make sure and old orchestration files are removed when starting a new one") is relevant to dir reuse semantics — but the exact cleanup logic wasn't located in the files examined. The validator `scripts/validate-orchestration.sh` handles per-worktree stale `.orchestration.json` files (see §6), not stale `~/.autorun/orchestration/<plan-name>/` directories themselves.

---

## 4. events.jsonl format

Path: `$ORCH_DIR/events.jsonl` — one JSON object per line (JSON Lines / newline-delimited JSON).

### Common fields on every event

- `ts` — UTC ISO 8601 timestamp with `Z` suffix, formatted `"%Y-%m-%dT%H:%M:%SZ"`
- `type` — event type discriminator
- `plan_name` — copied from status.json
- `project_slug` — copied from status.json
- `orch_dir` — absolute path to the orchestration directory

### Event types observed

| Type | Emitted in | Additional fields |
|---|---|---|
| `orchestration_started` | `orchestrate.md:147-158` | `project_root`, `total_stages`, `total_waves`, `waves` |
| `phase_status` | `update-phase-status.sh:64-74` | `stage` (int), `phase` (name), `field`, `value` |
| `merge_complete` | `merge.md:204-210` | `stage`, `wave` |
| `wave_complete` | `merge.md:212-220` | `wave`, `stages` (array), `has_more_waves` |
| `wave_started` | `merge.md:303-312` | `wave`, `stages` (array) |
| `orchestration_complete` | `merge.md:391-400` | `total_stages`, `total_waves` |
| `stall_detected` | `monitor-orchestration.sh:241` | `session`, `stage`, `check_num` |
| `stall_continue_sent` | `monitor-orchestration.sh:244` | `session`, `stage`, `check_num` |
| `wave_gap_detected` | `monitor-orchestration.sh:259` | `detail`, `check_num` |
| `session_dead` | `monitor-orchestration.sh:269` | `stage`, `detail`, `check_num` |

The monitor-emitted events use single `orch_dir` field but omit `plan_name`/`project_slug` — they only include `orch_dir`.

The file is append-only: `open(events_path, "a")`. No rotation or archival logic was observed. All writes use `json.dumps(...) + '\n'`.

---

## 5. How monitor-orchestration.sh finds an orchestration

`/Users/kk/Sites/CodefiLabs/autorun/scripts/monitor-orchestration.sh:21-38` — auto-detection when no argument is provided:

```bash
ORCH_DIR="${1:-}"
# ...
if [[ -z "$ORCH_DIR" ]]; then
  ORCH_BASE="$HOME/.autorun/orchestration"
  if [[ -d "$ORCH_BASE" ]]; then
    STATUS_CANDIDATE=$(find "$ORCH_BASE" -name "status.json" -maxdepth 2 -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)
    if [[ -n "$STATUS_CANDIDATE" ]]; then
      ORCH_DIR=$(dirname "$STATUS_CANDIDATE")
    fi
  fi
```

Behavior:
- If a path is passed as argument 1, it uses that directly (first argument is `orchestration-dir`).
- Otherwise, it scans `$HOME/.autorun/orchestration` with `find … -name status.json -maxdepth 2`, sorts by modification time (`ls -t`), and takes the most recently modified — the single most recent `status.json` wins.
- If none is found, it exits with an error (`monitor-orchestration.sh:34-37`).

The same auto-detection pattern exists in `check-orchestration-progress.sh:16-26`.

The monitor is launched in two places without an explicit path:
- `start.md:200-207` — background monitor after non-EPIC pipeline routing, relying on auto-detect.
- `orchestrate.md:190-191` — launches with `$ORCH_DIR` explicit after wave 1.

Only one orchestration's monitor process is expected at a time — `start.md:202` uses `pgrep -f "monitor-orchestration.sh"` to skip launching if one is already running.

---

## 6. `~/.autorun/` directory conventions

Documented in `/Users/kk/Sites/CodefiLabs/autorun/README.md:69-78`:

```
~/.autorun/
  research/       # Research documents
  plans/          # Implementation plans
  review/         # Human-in-the-loop review files
  orchestration/  # Per-plan stage status and context
  logs/           # tmux session logs
```

### Subdirectory uses observed in scripts/commands

| Path | Purpose | Referenced in |
|---|---|---|
| `~/.autorun/orchestration/<plan-name>/` | One orchestration dir per plan (see §3) | `orchestrate.md:88`, all monitor/check scripts |
| `~/.autorun/orchestration/<plan-name>/status.json` | State record for one orchestration | `orchestrate.md:111`, `merge.md`, `update-phase-status.sh`, `monitor-orchestration.sh`, `check-orchestration-progress.sh`, `orchestration-stats.py` |
| `~/.autorun/orchestration/<plan-name>/events.jsonl` | Append-only events (§4) | same set |
| `~/.autorun/orchestration/<plan-name>/stages/stage-N-context.md` | Per-stage context passed to `start.md` | `orchestrate.md:92-107`, `check-orchestration-progress.sh:118` |
| `~/.autorun/plans/` | Implementation plan files; naming `YYYY-MM-DD-<name>.md` or `YYYY-MM-DD-<name>-master.md` | `start.md:61` (`quick-<slug>.md`), `start.md:135` (`-master.md`), `check-orchestration-progress.sh:132-138` (flat scan), `merge.md:122` (plan search during conflict resolution) |
| `~/.autorun/research/` | Research documents | `research_codebase.md` frontmatter |
| `~/.autorun/research/.handoff/` | Research → create_plan handoff files | `create_plan.md:80` |
| `~/.autorun/research/.scratch/YYYY-MM-DD-description/` | Per-session scratch for parallel sub-agents | `research_codebase.md:107-108` |
| `~/.autorun/review/` | Human-in-the-loop review files; naming `YYYY-MM-DD-HHMMSS-summary.md` | `orchestrate.md:22-26`, `merge.md:24-28`, every command file |
| `~/.autorun/logs/` | tmux session logs and monitor logs | `chain-next.sh:36-38` (`$WINDOW_NAME-YYYYMMDD-HHMMSS.log`), `monitor-orchestration.sh:50-52` (`<slug>-monitor.log`) |
| `~/.autorun/reports/` | Stats reports from `orchestration-stats.py` | `orchestration-stats.py:664-668` (writes `<plan_name>.md` and `<plan_name>.json`) |
| `~/.autorun/orchestration/<plan-name>/.merge.lock` | `flock` target for cross-process coordination | `merge.md:102, 158, 268` |

### Per-worktree session state

`.orchestration.json` is written to the git worktree root, not under `~/.autorun/`. It is the bridge file used by downstream pipeline phases to find their parent orchestration's status.json:

- Written by `start.md:163-171` (orchestrated mode) with fields: `stage_number`, `orchestration_dir`, `session_name`, `chain_on_complete`.
- Read by `research_codebase.md:36-37`, `create_plan.md:61-62`, `implement_plan.md:26-27` to locate the parent status.json.
- Validated by `/Users/kk/Sites/CodefiLabs/autorun/scripts/validate-orchestration.sh` — removes it as stale if the orchestration dir is gone, status.json is missing, or the stage is already `completed` (`validate-orchestration.sh:15-38`).
- Cleaned up by `merge.md:432-436` after merge, and by `start.md:53-57` on non-orchestrated re-entry.

---

## 7. Multi-orchestration / multi-run tracking patterns

### Coexistence of multiple orchestrations

- Different `plan_name` values produce different directories (`~/.autorun/orchestration/<plan-name>/`) and can coexist on disk simultaneously.
- Same `plan_name` collides — the path is purely a function of the plan filename, with no timestamp or run-id suffix (see §3). Recent commit `19f5d91` ("make sure and old orchestration files are removed when starting a new one") indicates reuse of the same plan name overwrites prior state.

### Disambiguators that exist

| Disambiguator | Scope | Source |
|---|---|---|
| `plan_name` | Orchestration directory name + reports filename | `orchestrate.md:88`, `orchestration-stats.py:666` |
| `project_slug` | tmux session names (`<slug>_stage-<N>`) + monitor log filename (`<slug>-monitor.log`) | `orchestrate.md:173`, `monitor-orchestration.sh:52`, `merge.md:329` |
| `stage_number` | Per-stage context files, worktree names, branch names | `orchestrate.md:174`, `merge.md:330` |

### No observed mechanisms for

- **Per-user** separation — everything is under `$HOME/.autorun/`, single-user.
- **Per-timestamp / per-run-id** orchestration directories — the path format has no timestamp or UUID; only `created_at` inside status.json captures it.
- **Registry or index** of concurrent orchestrations — there is no top-level file listing active orchestrations.

### Auto-detection picks most-recent, not all

- `monitor-orchestration.sh:29` and `check-orchestration-progress.sh:20` both use `find … -name status.json -maxdepth 2 -print0 | xargs -0 ls -t | head -1`, selecting the single most-recently-modified `status.json`. Other concurrent orchestrations are not enumerated by these tools.
- `start.md:202` uses `pgrep -f monitor-orchestration.sh` to gate launching a second monitor — assumes one monitor process at a time.

### Parallelism within a single orchestration

Multiple stages within the same orchestration run in parallel:
- Each in its own git worktree (`--worktree 'stage-N'` argument to `claude` in `orchestrate.md:176-177`, `merge.md:331-333`).
- Each in its own tmux session (`${PROJECT_SLUG}_stage-${N}`).
- State coordinated via the single shared `status.json`, protected by:
  - `flock` on `$ORCH_DIR/.merge.lock` (`merge.md:102-103, 158-160, 268-270`).
  - `mkdir`-based lock at `$STATUS_FILE.lock` for phase updates (`update-phase-status.sh:33-36`).
  - Atomic write: write to `status.json.tmp`, then `os.rename()` (`merge.md:194-197`, `merge.md:295-298`).

This parallelism is internal to one orchestration; it is not a multi-orchestration pattern.

---

## Key file references

- `/Users/kk/Sites/CodefiLabs/autorun/commands/orchestrate.md` — initializes status.json (`:111-141`), defines path (`:87-89`), emits `orchestration_started` event (`:143-158`).
- `/Users/kk/Sites/CodefiLabs/autorun/commands/merge.md` — flips stage `status` to `completed` (`:178-179`), bumps `current_wave` (`:292-298`), emits `merge_complete`/`wave_complete`/`wave_started`/`orchestration_complete` events.
- `/Users/kk/Sites/CodefiLabs/autorun/commands/start.md` — orchestrated mode writes `.orchestration.json` (`:163-171`) and calls phase updates.
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/update-phase-status.sh` — lazy-creates phase records, writes timestamp fields, emits `phase_status` events.
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/monitor-orchestration.sh` — auto-detects most recent orchestration (`:26-38`), active monitor with stall detection, emits `stall_detected` / `stall_continue_sent` / `wave_gap_detected` / `session_dead`.
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/check-orchestration-progress.sh` — passive/read-only dashboard with the same auto-detection pattern and the authoritative status enum.
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/orchestration-stats.py` — consumes status.json, events.jsonl (indirectly via log), git log, and Claude JSONL transcripts; writes `~/.autorun/reports/<plan_name>.{md,json}`.
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/validate-orchestration.sh` — per-worktree `.orchestration.json` validator.
- `/Users/kk/Sites/CodefiLabs/autorun/scripts/chain-next.sh` — tmux session/window launcher that writes logs under `~/.autorun/logs/`.
- `/Users/kk/Sites/CodefiLabs/autorun/README.md:69-78` — canonical description of `~/.autorun/` subdirectory layout.
