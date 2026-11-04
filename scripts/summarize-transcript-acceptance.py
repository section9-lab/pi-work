#!/usr/bin/env python3
"""Summarize all frozen production runs, preserving failures and unequal work."""
import json
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
gate_file = root / 'acceptance-gates.json'
if not gate_file.exists():
    gate_file = pathlib.Path(__file__).parent / 'transcript-acceptance-gates.json'
gates = json.loads(gate_file.read_text())
records, failures = [], []
for path in sorted(root.glob('run-*.log')):
    text = path.read_text()
    if "with 0 failures" not in text or "Test Suite 'Selected tests' passed" not in text:
        failures.append(f'Failed or incomplete process: {path.name}')
    for line in text.splitlines():
        if line.startswith('TRANSCRIPT_ACCEPTANCE_PERF '):
            records.append(json.loads(line.split(' ', 1)[1]))
groups = {}
for row in records:
    groups.setdefault((row['density'], row['scenario'], row['variant']), []).append(row)
summary, checks = [], []
required_scenarios = gates.get('required_scenarios', {
    'mixed': ['open_cold_1000', 'history_coverage_300', 'open_cached_1000', 'stream_live', 'stream_history', 'resume_latest', 'remote_coverage_200'],
    'dense': ['open_cold_1000'],
})
for density, scenarios in required_scenarios.items():
    for scenario in scenarios:
        for variant in ['reference', 'after']:
            count = len(groups.get((density, scenario, variant), []))
            if count < gates['minimum_samples_per_variant_and_density']:
                failures.append(f'Missing required samples: {density}/{scenario}/{variant}: {count}')
for density, scenario in sorted({(d, s) for d, s, _ in groups}):
    pair = {label: groups.get((density, scenario, variant), [])
            for label, variant in [('before', 'reference'), ('after', 'after')]}
    entry = {'density': density, 'scenario': scenario, 'samples': {v: len(r) for v, r in pair.items()}, 'medians': {}}
    for variant, rows in pair.items():
        entry['medians'][variant] = {key: statistics.median(r[key] for r in rows if key in r)
            for key in ['wall_ms', 'cpu_ms', 'process_peak_rss_mb', 'gap_p95_ms', 'completion_lag_ms', 'actions', 'covered_sources', 'rows', 'final_render_valid', 'markdown_publishes']
            if any(key in r for r in rows)}
        if len(rows) < gates['minimum_samples_per_variant_and_density']:
            failures.append(f'Insufficient samples: {density}/{scenario}/{variant}: {len(rows)}')
    valid = all(r.get('final_render_valid', 1) == 1 for rows in pair.values() for r in rows)
    entry['ratio_censored'] = scenario == 'stream_live' and not valid
    for rows in pair.values():
        for row in rows:
            if scenario == 'stream_live' and row.get('final_render_valid') != 1:
                failures.append(f'Incomplete final renderer: {row["run"]}')
    if pair['before'] and pair['after'] and not entry['ratio_censored']:
        before, after = entry['medians']['before'], entry['medians']['after']
        entry['after_before_ratios'] = {k: after[k] / before[k] for k in ['wall_ms', 'cpu_ms', 'process_peak_rss_mb'] if before.get(k, 0)}
        for key, gate in [('wall_ms', 'gated_wall_scenarios'), ('cpu_ms', 'gated_cpu_scenarios')]:
            if scenario in gates[gate]:
                ratio = entry['after_before_ratios'][key]
                checks.append({'scenario': scenario, 'density': density, 'metric': key, 'ratio': ratio, 'passed': ratio <= gates['maximum_median_regression_ratio']})
        if scenario in gates['gated_rss_scenarios']:
            ratio = entry['after_before_ratios']['process_peak_rss_mb']
            checks.append({'scenario': scenario, 'density': density, 'metric': 'process_peak_rss_mb', 'ratio': ratio, 'passed': ratio <= gates['maximum_median_regression_ratio']})
        if scenario == 'history_coverage_300':
            for key in ['wall_ms', 'cpu_ms']:
                ratio = (after[key] / after['covered_sources']) / (before[key] / before['covered_sources'])
                checks.append({'scenario': scenario, 'density': density, 'metric': key + '_per_source', 'ratio': ratio, 'passed': ratio <= gates['maximum_median_regression_ratio']})
    summary.append(entry)
for check in checks:
    if not check['passed']:
        failures.append(f'Regression: {check}')
result = {'baseline': 'Corrected reference: production row/parser delivery; original whole-parent projection and 100..300 navigation. Not the invalid unmodified original.', 'gates': gates, 'passed': not failures, 'failures': failures, 'checks': checks, 'summary': summary, 'records': records}
(root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
lines = ['# Production transcript acceptance', '', f'Performance gates: {"PASS" if result["passed"] else "FAIL"}', '', '| Density / scenario | N reference/after | Wall ms reference → after | CPU ms reference → after |', '|---|---:|---:|---:|']
for entry in summary:
    a, b = entry['medians'].get('before', {}), entry['medians'].get('after', {})
    suffix = ' (live ratio censored: invalid final render)' if entry['ratio_censored'] else ''
    lines.append(f'| {entry["density"]} / {entry["scenario"]}{suffix} | {entry["samples"]["before"]}/{entry["samples"]["after"]} | {a.get("wall_ms", 0):.1f} → {b.get("wall_ms", 0):.1f} | {a.get("cpu_ms", 0):.1f} → {b.get("cpu_ms", 0):.1f} |')
lines += ['', '## Failures', *([f'- {f}' for f in failures] or ['None.']), '', 'History coverage is 300 vs 320 older sources, not identical work. Remote coverage is exactly 200 sources in both. RSS is cumulative process peak. Main-thread gap is scheduling plus forced layout, not GPU FPS.']
(root / 'summary.md').write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
sys.exit(0 if result['passed'] else 1)
