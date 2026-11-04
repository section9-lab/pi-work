#!/usr/bin/env python3
"""Summarize benchmark JSON lines without mixing different scenarios/metrics."""
import json
import pathlib
import statistics
import sys

root = pathlib.Path(sys.argv[1])
groups = {}
records = []
for path in sorted(root.glob('run-*.log')):
    for line in path.read_text().splitlines():
        if line.startswith('MARKDOWN_PERF '):
            row = json.loads(line.removeprefix('MARKDOWN_PERF '))
            records.append(row)
            groups.setdefault((row['scenario'], row['batch']), []).append(row)
(root / 'results.json').write_text(json.dumps(records, indent=2) + '\n')
print('# Markdown window benchmark\n')
print('Release; real ChatView at 840 × 640 pt; deterministic in-process host; A/B/B/A.\n')
print('| Scenario / metric | n (40/100) | 40 median | 100 median | 100/40 |')
print('| --- | ---: | ---: | ---: | ---: |')
for scenario in sorted({key[0] for key in groups}):
    a, b = groups.get((scenario, 40), []), groups.get((scenario, 100), [])
    if not a or not b:
        raise SystemExit(f'Missing comparison for {scenario}')
    for metric in ['wall_ms', 'cpu_ms', 'first_frame_ms', 'gap_p95_ms', 'gap_max_ms', 'gaps_over_16_7_pct']:
        if metric not in a[0]:
            continue
        x, y = (statistics.median(row[metric] for row in values) for values in [a, b])
        print(f'| {scenario} / {metric} | {len(a)}/{len(b)} | {x:.2f} | {y:.2f} | {y/x:.2f}× |' if x else
              f'| {scenario} / {metric} | {len(a)}/{len(b)} | {x:.2f} | {y:.2f} | — |')
print('\n## Wall-time spread (ms)\n')
print('| Scenario | 40 min–max | 100 min–max |')
print('| --- | ---: | ---: |')
for scenario in sorted({key[0] for key in groups}):
    ranges = []
    for batch in [40, 100]:
        values = [row['wall_ms'] for row in groups[(scenario, batch)]]
        ranges.append(f'{min(values):.1f}–{max(values):.1f}')
    print(f'| {scenario} | {ranges[0]} | {ranges[1]} |')
print('\nWall includes polling/settling. Empty control includes a fixed 100 ms wait. '
      'Streaming runs at 50 events/s for 100 deltas with production 200 ms Markdown coalescing. '
      'Gaps measure main-actor scheduling + forced layout, not GPU FPS. '
      'Cold means new content, not a fresh process/filesystem cache. '
      'Remote timings exclude actual disk/RPC/network latency. '
      'Warm means re-mounting an already-open session, not clicking between two different sessions.')
