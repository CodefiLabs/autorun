"""Orchestration stats aggregator.

Usage:
    python3 scripts/orchestration-stats.py STATUS_FILE [LOG_FILE] [PROJECT_ROOT]

Reads status.json, monitor log, JSONL transcripts, and git log; writes
markdown + JSON reports to ~/.autorun/reports/<plan_name>.{md,json}
and prints a terminal summary to stdout.
"""
import json, os, re, sys, glob, subprocess
from datetime import datetime, timezone
from pathlib import Path


# --- helpers ---

def parse_ts(s):
    if s is None:
        return None
    s = s.rstrip('Z')
    if '+' not in s and 'T' in s:
        s += '+00:00'
    return datetime.fromisoformat(s)


def duration_s(started, completed, now_fallback=None):
    if started is None:
        return None
    end = completed if completed is not None else now_fallback
    if end is None:
        return None
    d = (end - started).total_seconds()
    return max(0.0, d)


def fmt_duration(seconds):
    if seconds is None:
        return "N/A"
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    if h:
        return f"{h}h {m}m {s}s"
    if m:
        return f"{m}m {s}s"
    return f"{s}s"


def fmt_tokens(n):
    if n is None or n == 0:
        return "0"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}K"
    return str(n)


# Pricing per million tokens — verified against anthropic.com/pricing 2026-04-19
MODEL_PRICING = {
    'claude-opus-4-7':    {'input': 15.0, 'output': 75.0, 'cache_write': 18.75, 'cache_read': 1.50},
    'claude-opus-4-6':    {'input': 15.0, 'output': 75.0, 'cache_write': 18.75, 'cache_read': 1.50},
    'claude-sonnet-4-6':  {'input': 3.0,  'output': 15.0, 'cache_write': 3.75,  'cache_read': 0.30},
}
MODEL_ALIASES = {
    'anthropic/claude-opus-4.7':   'claude-opus-4-7',
    'anthropic/claude-opus-4.6':   'claude-opus-4-6',
    'anthropic/claude-sonnet-4.6': 'claude-sonnet-4-6',
}


def normalize_model(model_str):
    if model_str in MODEL_PRICING:
        return model_str
    if model_str in MODEL_ALIASES:
        return MODEL_ALIASES[model_str]
    for key in MODEL_PRICING:
        if key in model_str:
            return key
    return model_str


# --- load ---

def load_status(path):
    with open(path) as f:
        return json.load(f)


# --- timeline ---

def derive_stage_start(phases):
    starts = []
    for p in phases.values():
        if isinstance(p, dict):
            ts = parse_ts(p.get('started_at'))
            if ts:
                starts.append(ts)
    return min(starts) if starts else None


def compute_timeline(status):
    now = datetime.now(timezone.utc)
    created = parse_ts(status['created_at'])
    stages = status['stages']
    waves = status.get('waves', [])

    stage_timelines = {}
    all_completed = True
    for sid, st in stages.items():
        s_start = derive_stage_start(st.get('phases', {}))
        s_end = parse_ts(st.get('completed_at'))
        if s_end is None:
            all_completed = False

        phase_durations = {}
        for pname, pdata in st.get('phases', {}).items():
            if not isinstance(pdata, dict):
                continue
            ps = parse_ts(pdata.get('started_at'))
            pc = parse_ts(pdata.get('completed_at'))
            phase_durations[pname] = duration_s(ps, pc, now)

        stage_timelines[sid] = {
            'name': st.get('name', f'Stage {sid}'),
            'status': st.get('status', 'unknown'),
            'started_at': s_start.isoformat() if s_start else None,
            'completed_at': st.get('completed_at'),
            'duration_s': duration_s(s_start, s_end, now),
            'in_progress': s_end is None,
            'phases': phase_durations,
            'depends_on': st.get('depends_on', []),
        }

    total_wall = duration_s(created, now if not all_completed else max(
        (parse_ts(st.get('completed_at')) for st in stages.values() if st.get('completed_at')),
        default=now
    ))

    wave_timelines = []
    for wi, wave_stages in enumerate(waves):
        w_starts = []
        w_ends = []
        w_in_progress = False
        for sid in wave_stages:
            st = stage_timelines.get(str(sid), {})
            if st.get('started_at'):
                w_starts.append(parse_ts(st['started_at']))
            if st.get('completed_at'):
                w_ends.append(parse_ts(st['completed_at']))
            if st.get('in_progress'):
                w_in_progress = True
        wave_timelines.append({
            'wave': wi + 1,
            'stages': wave_stages,
            'duration_s': duration_s(
                min(w_starts) if w_starts else None,
                max(w_ends) if w_ends and not w_in_progress else None,
                now if w_in_progress else None
            ),
            'in_progress': w_in_progress,
        })

    completed_count = sum(1 for st in stages.values() if st.get('status') == 'completed')

    return {
        'total_wall_s': total_wall,
        'created_at': status['created_at'],
        'all_completed': all_completed,
        'completed_count': completed_count,
        'total_stages': len(stages),
        'stages': stage_timelines,
        'waves': wave_timelines,
    }


# --- code metrics ---

def compute_code_metrics(project_root, created_at):
    if not project_root or not os.path.isdir(project_root):
        return {'error': f'project_root not found: {project_root}'}

    try:
        base = subprocess.run(
            ['git', 'log', '--before', created_at, '--pretty=%H', '-1'],
            cwd=project_root, capture_output=True, text=True
        ).stdout.strip()
        if not base:
            base = 'HEAD~100'

        log_out = subprocess.run(
            ['git', 'log', '--pretty=%H%x09%s', f'{base}..HEAD'],
            cwd=project_root, capture_output=True, text=True
        ).stdout.strip()
        commits = [l for l in log_out.split('\n') if l.strip()] if log_out else []

        stat_out = subprocess.run(
            ['git', 'diff', '--shortstat', base, 'HEAD'],
            cwd=project_root, capture_output=True, text=True
        ).stdout.strip()

        files_changed = 0
        lines_added = 0
        lines_removed = 0
        if stat_out:
            fm = re.search(r'(\d+) files? changed', stat_out)
            am = re.search(r'(\d+) insertions?', stat_out)
            rm = re.search(r'(\d+) deletions?', stat_out)
            files_changed = int(fm.group(1)) if fm else 0
            lines_added = int(am.group(1)) if am else 0
            lines_removed = int(rm.group(1)) if rm else 0

        test_total = 0
        conflict_total = 0
        for line in commits:
            parts = line.split('\t', 1)
            if len(parts) < 2:
                continue
            subject = parts[1]
            for tm in re.finditer(r'\((\d+)\s*(?:tests|unit tests|integration tests|cases)\)', subject):
                test_total += int(tm.group(1))
            for tm in re.finditer(r'with\s+(\d+)\s+(?:unit|integration)?\s*tests?', subject):
                test_total += int(tm.group(1))
            for cm in re.finditer(r'resolve\s+(\d+)\s+conflicts?', subject, re.IGNORECASE):
                conflict_total += int(cm.group(1))

        return {
            'commits_total': len(commits),
            'files_changed': files_changed,
            'lines_added': lines_added,
            'lines_removed': lines_removed,
            'tests_total': test_total,
            'merge_conflicts': conflict_total,
            'base_commit': base[:8],
        }
    except Exception as e:
        return {'error': str(e)}


# --- parallelism ---

def compute_parallelism(status, timeline_data):
    stages = status['stages']
    waves = status.get('waves', [])
    now = datetime.now(timezone.utc)

    intervals = []
    serial_total = 0.0
    for sid, st in stages.items():
        s_start = derive_stage_start(st.get('phases', {}))
        s_end = parse_ts(st.get('completed_at'))
        if s_start is None:
            continue
        end = s_end if s_end else now
        dur = max(0.0, (end - s_start).total_seconds())
        serial_total += dur
        intervals.append((s_start, end))

    max_concurrent = 0
    if intervals:
        events = []
        for start, end in intervals:
            events.append((start, 1))
            events.append((end, -1))
        events.sort(key=lambda x: (x[0], x[1]))
        current = 0
        for _, delta in events:
            current += delta
            max_concurrent = max(max_concurrent, current)

    created = parse_ts(status['created_at'])
    latest_end = max((iv[1] for iv in intervals), default=now)
    wall_clock = max(1.0, (latest_end - created).total_seconds())
    parallelism_factor = serial_total / wall_clock if wall_clock > 0 else 1.0

    wave_sizes = [len(w) for w in waves]

    return {
        'max_concurrent': max_concurrent,
        'serial_total_s': serial_total,
        'wall_clock_s': wall_clock,
        'parallelism_factor': round(parallelism_factor, 2),
        'wave_sizes': wave_sizes,
        'wave_count': len(waves),
    }


# --- tokens ---

def compute_tokens(status):
    created_at = parse_ts(status['created_at'])
    stages = status['stages']
    jsonl_base = os.path.expanduser(
        '~/.claude/projects/-Users-kk-Sites-CodefiLabs-agents-tractionstudio-ai--claude-worktrees-stage-'
    )

    per_model = {}
    per_stage = {}
    total_sessions = 0

    for sid in sorted(stages.keys(), key=int):
        if int(sid) == 0:
            continue

        stage_dir = f"{jsonl_base}{sid}"
        jsonl_files = glob.glob(os.path.join(stage_dir, '*.jsonl'))

        stage_tokens = {'input': 0, 'output': 0, 'cache_write': 0, 'cache_read': 0}
        stage_sessions = set()
        stage_lines = 0

        for fpath in jsonl_files:
            try:
                with open(fpath) as f:
                    for line in f:
                        try:
                            d = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if d.get('type') != 'assistant':
                            continue
                        usage = d.get('message', {}).get('usage')
                        if not usage:
                            continue
                        ts = parse_ts(d.get('timestamp'))
                        if ts and created_at and ts < created_at:
                            continue

                        stage_lines += 1
                        sess = d.get('sessionId')
                        if sess:
                            stage_sessions.add(sess)

                        model = normalize_model(d.get('message', {}).get('model', 'unknown'))
                        if model not in per_model:
                            per_model[model] = {'input': 0, 'output': 0, 'cache_write': 0, 'cache_read': 0}

                        inp = usage.get('input_tokens', 0)
                        out = usage.get('output_tokens', 0)
                        cw = usage.get('cache_creation_input_tokens', 0)
                        cr = usage.get('cache_read_input_tokens', 0)

                        per_model[model]['input'] += inp
                        per_model[model]['output'] += out
                        per_model[model]['cache_write'] += cw
                        per_model[model]['cache_read'] += cr

                        stage_tokens['input'] += inp
                        stage_tokens['output'] += out
                        stage_tokens['cache_write'] += cw
                        stage_tokens['cache_read'] += cr
            except (OSError, IOError):
                continue

        session_count = len(stage_sessions)
        total_sessions += session_count
        per_stage[sid] = {
            'tokens': stage_tokens,
            'sessions': session_count,
            'lines_parsed': stage_lines,
        }

    total_cost = 0.0
    unknown_models = []
    for model, counts in per_model.items():
        pricing = MODEL_PRICING.get(model)
        if pricing:
            cost = (
                counts['input'] * pricing['input'] / 1_000_000
                + counts['output'] * pricing['output'] / 1_000_000
                + counts['cache_write'] * pricing['cache_write'] / 1_000_000
                + counts['cache_read'] * pricing['cache_read'] / 1_000_000
            )
            per_model[model]['cost'] = round(cost, 2)
            total_cost += cost
        else:
            per_model[model]['cost'] = None
            unknown_models.append(model)

    grand_total = {'input': 0, 'output': 0, 'cache_write': 0, 'cache_read': 0}
    for counts in per_model.values():
        for k in grand_total:
            grand_total[k] += counts[k]

    return {
        'per_model': per_model,
        'per_stage': per_stage,
        'total': grand_total,
        'total_cost': round(total_cost, 2),
        'total_sessions': total_sessions,
        'unknown_models': unknown_models,
    }


# --- reliability ---

def compute_reliability(log_path):
    if not log_path or not os.path.isfile(log_path):
        return {'error': f'log not found: {log_path}', 'checks': 0, 'stalls': 0, 'recoveries': 0, 'dead': 0, 'wave_gaps': 0}

    try:
        with open(log_path) as f:
            content = f.read()
    except (OSError, IOError) as e:
        return {'error': str(e), 'checks': 0, 'stalls': 0, 'recoveries': 0, 'dead': 0, 'wave_gaps': 0}

    return {
        'checks': len(re.findall(r'CHECK #', content)),
        'stalls': len(re.findall(r'NO CHANGE.*likely stalled', content)),
        'recoveries': len(re.findall(r'Sent.*continue', content)),
        'dead': len(re.findall(r'DEAD:', content)),
        'wave_gaps': len(re.findall(r'WAVE_GAP', content)),
    }


# --- render terminal ---

def render_terminal(m):
    status = m['status']
    tl = m['timeline']
    code = m['code']
    par = m['parallelism']
    tok = m['tokens']
    rel = m['reliability']

    lines = []
    sep = '=' * 60

    lines.append(sep)
    lines.append(f"  Orchestration: {status.get('plan_name', 'unknown')}")
    if tl['all_completed']:
        lines.append(f"  Status: Completed ({tl['completed_count']}/{tl['total_stages']} stages)")
    else:
        lines.append(f"  Status: In Progress ({tl['completed_count']}/{tl['total_stages']} stages)")
    lines.append(f"  Wall clock: {fmt_duration(tl['total_wall_s'])}")
    lines.append(sep)

    lines.append("")
    lines.append("  TIMELINE")
    lines.append("  " + "-" * 56)
    for wi, w in enumerate(tl['waves']):
        prog = " (in progress)" if w.get('in_progress') else ""
        lines.append(f"  Wave {w['wave']}: {fmt_duration(w['duration_s'])}{prog}  [{len(w['stages'])} stages]")
    lines.append("")

    if not code.get('error'):
        lines.append("  CODE")
        lines.append("  " + "-" * 56)
        lines.append(f"  Commits: {code['commits_total']}  |  Files: {code['files_changed']}")
        lines.append(f"  Lines: +{code['lines_added']} / -{code['lines_removed']}")
        if code['tests_total']:
            lines.append(f"  Tests: {code['tests_total']}  |  Merge conflicts: {code['merge_conflicts']}")
        lines.append("")

    lines.append("  PARALLELISM")
    lines.append("  " + "-" * 56)
    lines.append(f"  Max concurrent: {par['max_concurrent']}  |  Factor: {par['parallelism_factor']}x")
    lines.append(f"  Waves: {par['wave_count']}  |  Sizes: {par['wave_sizes']}")
    lines.append("")

    lines.append("  TOKENS & COST")
    lines.append("  " + "-" * 56)
    for model, counts in tok['per_model'].items():
        cost_str = f"${counts['cost']:.2f}" if counts.get('cost') is not None else "unknown"
        total_tok = counts['input'] + counts['output'] + counts['cache_write'] + counts['cache_read']
        lines.append(f"  {model}: {fmt_tokens(total_tok)} tokens, {cost_str}")
    lines.append(f"  Total: {fmt_tokens(sum(tok['total'].values()))} tokens, ${tok['total_cost']:.2f}")
    lines.append(f"  Sessions: {tok['total_sessions']}")
    lines.append("")

    if not rel.get('error'):
        lines.append("  RELIABILITY")
        lines.append("  " + "-" * 56)
        lines.append(f"  Monitor checks: {rel['checks']}  |  Stalls: {rel['stalls']}")
        lines.append(f"  Auto-recoveries: {rel['recoveries']}  |  Dead: {rel['dead']}")
        lines.append(f"  Wave gaps: {rel['wave_gaps']}")
        lines.append("")

    lines.append(sep)
    return '\n'.join(lines)


# --- render markdown ---

def render_markdown(m):
    status = m['status']
    tl = m['timeline']
    code = m['code']
    par = m['parallelism']
    tok = m['tokens']
    rel = m['reliability']

    lines = []
    lines.append(f"# Orchestration Report: {status.get('plan_name', 'unknown')}")
    lines.append("")

    lines.append("## Overview")
    lines.append("")
    if tl['all_completed']:
        lines.append(f"- **Status**: Completed ({tl['completed_count']}/{tl['total_stages']} stages)")
    else:
        lines.append(f"- **Status**: In Progress ({tl['completed_count']}/{tl['total_stages']} stages)")
    lines.append(f"- **Started**: {tl['created_at']}")
    lines.append(f"- **Wall clock**: {fmt_duration(tl['total_wall_s'])}")
    lines.append(f"- **Project**: {status.get('project_slug', 'unknown')}")
    lines.append("")

    lines.append("## Timeline")
    lines.append("")

    lines.append("### Per-Wave")
    lines.append("")
    lines.append("| Wave | Stages | Duration | Status |")
    lines.append("|------|--------|----------|--------|")
    for w in tl['waves']:
        st = "In Progress" if w.get('in_progress') else "Complete"
        lines.append(f"| {w['wave']} | {len(w['stages'])} ({', '.join(str(s) for s in w['stages'])}) | {fmt_duration(w['duration_s'])} | {st} |")
    lines.append("")

    lines.append("### Per-Stage")
    lines.append("")
    lines.append("| Stage | Name | Duration | Status | Phases |")
    lines.append("|-------|------|----------|--------|--------|")
    for sid in sorted(tl['stages'].keys(), key=int):
        st = tl['stages'][sid]
        phases_str = ', '.join(
            f"{p}: {fmt_duration(d)}" for p, d in st['phases'].items() if d is not None
        )
        status_str = "In Progress" if st['in_progress'] else st['status'].title()
        dur_str = fmt_duration(st['duration_s'])
        if st['in_progress']:
            dur_str += " (in progress)"
        lines.append(f"| {sid} | {st['name']} | {dur_str} | {status_str} | {phases_str} |")
    lines.append("")

    lines.append("## Code")
    lines.append("")
    if code.get('error'):
        lines.append(f"Error computing code metrics: {code['error']}")
    else:
        lines.append(f"- **Commits**: {code['commits_total']}")
        lines.append(f"- **Files changed**: {code['files_changed']}")
        lines.append(f"- **Lines**: +{code['lines_added']} / -{code['lines_removed']}")
        lines.append(f"- **Tests**: {code['tests_total']}")
        lines.append(f"- **Merge conflicts resolved**: {code['merge_conflicts']}")
    lines.append("")

    lines.append("## Parallelism")
    lines.append("")
    lines.append(f"- **Max concurrent stages**: {par['max_concurrent']}")
    lines.append(f"- **Parallelism factor**: {par['parallelism_factor']}x (serial time / wall clock)")
    lines.append(f"- **Wave count**: {par['wave_count']}")
    lines.append(f"- **Wave sizes**: {par['wave_sizes']}")
    lines.append("")

    lines.append("## Tokens & Cost")
    lines.append("")
    lines.append("### Per-Model")
    lines.append("")
    lines.append("| Model | Input | Output | Cache Write | Cache Read | Cost |")
    lines.append("|-------|-------|--------|-------------|------------|------|")
    for model, counts in tok['per_model'].items():
        cost_str = f"${counts['cost']:.2f}" if counts.get('cost') is not None else "N/A"
        lines.append(f"| {model} | {fmt_tokens(counts['input'])} | {fmt_tokens(counts['output'])} | {fmt_tokens(counts['cache_write'])} | {fmt_tokens(counts['cache_read'])} | {cost_str} |")
    lines.append(f"| **Total** | {fmt_tokens(tok['total']['input'])} | {fmt_tokens(tok['total']['output'])} | {fmt_tokens(tok['total']['cache_write'])} | {fmt_tokens(tok['total']['cache_read'])} | **${tok['total_cost']:.2f}** |")
    lines.append("")

    lines.append("### Per-Stage")
    lines.append("")
    lines.append("| Stage | Input | Output | Cache Write | Cache Read | Sessions |")
    lines.append("|-------|-------|--------|-------------|------------|----------|")
    for sid in sorted(tok['per_stage'].keys(), key=int):
        st = tok['per_stage'][sid]
        t = st['tokens']
        lines.append(f"| {sid} | {fmt_tokens(t['input'])} | {fmt_tokens(t['output'])} | {fmt_tokens(t['cache_write'])} | {fmt_tokens(t['cache_read'])} | {st['sessions']} |")
    lines.append("")
    lines.append(f"**Total sessions**: {tok['total_sessions']}")
    lines.append("")

    lines.append("## Reliability")
    lines.append("")
    if rel.get('error'):
        lines.append(f"Monitor log not available: {rel['error']}")
    else:
        lines.append(f"- **Monitor checks**: {rel['checks']}")
        lines.append(f"- **Stalls detected**: {rel['stalls']}")
        lines.append(f"- **Auto-recoveries**: {rel['recoveries']}")
        lines.append(f"- **Dead sessions**: {rel['dead']}")
        lines.append(f"- **Wave gaps**: {rel['wave_gaps']}")
    lines.append("")

    return '\n'.join(lines)


# --- render json ---

def render_json(m):
    def default_serializer(obj):
        if isinstance(obj, datetime):
            return obj.isoformat()
        return str(obj)

    return json.dumps({
        'status': {
            'plan_name': m['status'].get('plan_name'),
            'project_slug': m['status'].get('project_slug'),
            'project_root': m['status'].get('project_root'),
            'created_at': m['status'].get('created_at'),
            'current_wave': m['status'].get('current_wave'),
            'total_stages': len(m['status'].get('stages', {})),
            'total_waves': len(m['status'].get('waves', [])),
        },
        'timeline': m['timeline'],
        'code': m['code'],
        'parallelism': m['parallelism'],
        'tokens': m['tokens'],
        'reliability': m['reliability'],
    }, indent=2, default=default_serializer)


# --- main ---

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 orchestration-stats.py STATUS_FILE [LOG_FILE] [PROJECT_ROOT]", file=sys.stderr)
        sys.exit(1)

    status_file = sys.argv[1]
    status = load_status(status_file)

    log_file = sys.argv[2] if len(sys.argv) > 2 else None
    project_root = sys.argv[3] if len(sys.argv) > 3 else None

    if log_file is None:
        slug = status.get('project_slug', 'unknown')
        log_file = os.path.expanduser(f"~/.autorun/logs/{slug}-monitor.log")
    if project_root is None:
        project_root = status.get('project_root')

    metrics = {
        'status': status,
        'timeline': compute_timeline(status),
        'code': compute_code_metrics(project_root, status['created_at']),
        'parallelism': compute_parallelism(status, None),
        'tokens': compute_tokens(status),
        'reliability': compute_reliability(log_file),
    }

    print(render_terminal(metrics))

    reports_dir = os.path.expanduser('~/.autorun/reports')
    os.makedirs(reports_dir, exist_ok=True)
    plan = status.get('plan_name', 'unknown')
    Path(f'{reports_dir}/{plan}.md').write_text(render_markdown(metrics))
    Path(f'{reports_dir}/{plan}.json').write_text(render_json(metrics))
    print(f"\nReports written to {reports_dir}/{plan}.{{md,json}}")


if __name__ == '__main__':
    main()
