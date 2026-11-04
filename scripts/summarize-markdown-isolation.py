#!/usr/bin/env python3
"""Aggregate successful same-binary baseline/combined benchmark runs."""
import collections
import json
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
groups = collections.defaultdict(list)
records = []
for path in sorted(root.glob('run-*.log')):
    text = path.read_text()
    if 'with 0 failures' not in text or 'error:' in text:
        raise SystemExit(f'Refusing incomplete/failed run: {path.name}')
    for line in text.splitlines():
        if line.startswith('ISOLATION_PERF '):
            row = json.loads(line.removeprefix('ISOLATION_PERF '))
            records.append(row)
            groups[(row['density'], row['scenario'], row['variant'])].append(row)
assert records, 'No samples'
(root / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
print('# Complex Markdown: baseline 100 vs fixed-100 + isolated text\n')
print('Same instrumented Release binary within each A/B batch; 840 × 640 pt; deterministic Host. '
      'Per-row n is authoritative. Driver default is dense A/B plus mixed A/B/B/A.\n')
if min(map(len, groups.values())) < 3:
    print('**Exploratory sample count:** some cells have fewer than three observations; do not infer a stable cross-machine speedup.\n')
print('| Scenario / metric | n A/B | Baseline median | Combined median | B/A | Change |')
print('| --- | ---: | ---: | ---: | ---: | ---: |')
metrics = ['final_render_valid', 'wall_ms', 'cpu_ms', 'first_frame_ms', 'rows', 'actions', 'process_peak_rss_mb', 'input_ms', 'completion_lag_ms', 'gap_p95_ms', 'gap_max_ms',
           'projection_calls', 'source_rows_scanned', 'local_deliveries', 'parent_events_skipped',
           'markdown_publishes', 'markdown_initializations']
scenarios = sorted({(key[0], key[1]) for key in groups})
for density, scenario in scenarios:
    a, b = groups[(density, scenario, 'baseline')], groups[(density, scenario, 'combined')]
    assert a and b, f'Missing A/B: {scenario}'
    invalid = any(row.get('final_render_valid', 1) != 1 for row in a + b)
    if invalid:
        print(f'| {density} / {scenario} | {len(a)}/{len(b)} | INVALID: final-render check failed | see raw data | no speedup comparison | — |')
    for metric in metrics:
        if invalid and metric != 'final_render_valid':
            continue
        if metric not in a[0]:
            continue
        x, y = (statistics.median(row[metric] for row in group) for group in [a, b])
        ratio = f'{y/x:.2f}×' if x else '—'
        delta = f'{(y/x-1)*100:+.1f}%' if x else '—'
        print(f'| {density} / {scenario} / {metric} | {len(a)}/{len(b)} | {x:.2f} | {y:.2f} | {ratio} | {delta} |')
print('\n## Wall-time ranges (ms)\n')
print('| Scenario | Baseline min–max | Combined min–max |')
print('| --- | ---: | ---: |')
for density, scenario in scenarios:
    spans = []
    for variant in ['baseline', 'combined']:
        rows = groups[(density, scenario, variant)]
        if any(row.get('final_render_valid', 1) != 1 for row in rows):
            spans.append('INVALID: final text incomplete')
            continue
        values = [row['wall_ms'] for row in rows]
        spans.append(f'{min(values):.1f}–{max(values):.1f}')
    print(f'| {density} / {scenario} | {spans[0]} | {spans[1]} |')
print('\nAn invalid final-render check censors the entire live-stream speedup comparison; '
      'successful collection logs do not mean the baseline renderer passed correctness. '
      'See renderer-check-*.log separately. RSS is the process cumulative peak in MiB, not a scenario-local allocation delta. '
      'Counters include instrumentation, not a predicted SwiftUI redraw count. '
      'Streaming uses the same ~150 content deltas at 50 Hz through the real reducer and Markdown presentation; '
      'sampling gaps include forced layout and are not GPU FPS. '
      'History action counters are cumulative within the history section; coverage totals compare the same source range '
      'and include all navigation actions. Both initial windows are 100 rows. '
      'The candidate shifts 60 with 40 overlap; the baseline expands to 300. '
      'Remote Host timings exclude actual I/O. No synthetic busy loop or dummy render workload is used.')
