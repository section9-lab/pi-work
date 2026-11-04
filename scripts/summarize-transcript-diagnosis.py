#!/usr/bin/env python3
"""Summarize transcript live-diagnosis logs; fail loudly on incomplete data.

Parses LIVE_DIAG_RESULT, LIVE_DIAG_STAGES and LIVE_DIAG_SAMPLE lines from
`--run-dir`. A scenario counts as valid only when its log contains a result
line with the expected published sequence AND (when requested by the
registry) a completion that includes the mounted-render check. Missing
samples are failures by default; `--relaxed` only downgrades them to
warnings and always reports them. The summarize-transcript-acceptance
lesson applies: absent data must not be reported as a pass.
"""
import argparse
import json
import pathlib
import re
import sys

RESULT = re.compile(
    r"LIVE_DIAG_RESULT mode=(\S+) rows=(\d+) input_ms=([0-9.]+) store_ms=(-?[0-9.]+)"
    r" render_ms=(-?[0-9.]+) wall_ms=([0-9.]+) cpu_ms=([0-9.]+)"
    r" seq=(\d+)/(\d+) gap_p95_ms=([0-9.]+) gap_max_ms=([0-9.]+)"
)
STAGES_HEADER = "LIVE_DIAG_STAGES "
COUNTERS = re.compile(
    r"received=(\d+) received_seq=(-?\d+) processed=(\d+) processed_seq=(-?\d+)"
    r" published=(\d+) published_seq=(-?\d+)"
)
SAMPLE = re.compile(r"LIVE_DIAG_SAMPLE elapsed_ms=(\d+)")


def parse_log(path: pathlib.Path) -> dict:
    data = {
        "log": path.name, "results": [], "stages": [],
        "samples": [], "errors": [],
    }
    lines = path.read_text(errors="replace").splitlines()
    for index, line in enumerate(lines):
        match = RESULT.search(line)
        if match:
            data["results"].append(dict(zip(
                ["mode", "rows", "input_ms", "store_ms", "render_ms", "wall_ms",
                 "cpu_ms", "seq", "expected", "gap_p95_ms", "gap_max_ms"],
                match.groups())))
        if line.strip().startswith(STAGES_HEADER):
            emitted_match = re.search(r"emitted=(\d+)", line)
            # Sanity builds may print the counters on the same line as the
            # header or directly after it; accept both.
            for candidate in [line] + lines[index + 1:index + 3]:
                counters_match = COUNTERS.search(candidate)
                if counters_match:
                    entry = dict(zip(
                        ["received", "received_seq", "processed", "processed_seq",
                         "published", "published_seq"],
                        counters_match.groups()))
                    if emitted_match:
                        entry["emitted"] = int(emitted_match.group(1))
                    data["stages"].append(entry)
                    break
        sample_match = SAMPLE.search(line)
        if sample_match:
            data["samples"].append(int(sample_match.group(1)))
        if line.startswith("LIVE_OBSERVATION") or " store_complete_ms=" in line:
            data["errors"].append(line.strip())
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenarios-json", required=True)
    parser.add_argument("--run-dir", help="directory with per-scenario logs")
    parser.add_argument("--names", nargs="*", help="required scenario names; default all")
    parser.add_argument("--list-names", action="store_true")
    parser.add_argument("--relaxed", action="store_true")
    args = parser.parse_args()

    scenarios = json.load(open(args.scenarios_json))
    if args.list_names:
        print(" ".join(s["name"] for s in scenarios))
        return 0
    required = args.names or [s["name"] for s in scenarios]
    by_name = {s["name"]: s for s in scenarios}
    missing = [name for name in required if name not in by_name]
    for name in missing:
        print(f"error: unknown scenario {name}", file=sys.stderr)
    run_dir = pathlib.Path(args.run_dir) if args.run_dir else None

    table = []
    invalid = list(missing)
    for name in required:
        scenario = by_name[name]
        entry = {"scenario": name, "valid": False, "notes": []}
        if run_dir:
            path = run_dir / f"{name}.log"
            data = parse_log(path) if path.exists() else {"results": [], "stages": [], "samples": []}
            entry.update(data)
        if not entry.get("results"):
            entry["notes"].append("missing LIVE_DIAG_RESULT")
            invalid.append(name)
            table.append(entry)
            continue
        result = entry["results"][-1]
        entry["result"] = result
        if result["seq"] != result["expected"]:
            entry["notes"].append(
                f"sequence incomplete {result['seq']}/{result['expected']}")
            invalid.append(name)
        elif result["store_ms"] == "-1.0" and scenario["expect_complete"]:
            entry["notes"].append("store did not finish")
            invalid.append(name)
        elif scenario["expect_render"] and result["render_ms"] == "-1.0":
            entry["notes"].append("mounted render check missing")
            invalid.append(name)
        else:
            entry["valid"] = True
        table.append(entry)

    json_path = run_dir / "results.json" if run_dir else None
    if json_path:
        if run_dir.is_dir():
            json_path.write_text(json.dumps(table, indent=2, sort_keys=True) + "\n")
        else:
            print(f"error: run directory does not exist: {run_dir}", file=sys.stderr)
            return 1

    lines_md = [
        "| scenario | valid | input_ms | store_ms | publish_lag_ms | cpu_ms | seq | notes |",
        "|---|---|---:|---:|---:|---:|---|---|",
    ]
    for entry in table:
        result = entry.get("result")
        if not result:
            lines_md.append(
                f"| {entry['scenario']} | NO | - | - | - | - | - | "
                + "; ".join(entry["notes"]) + " |")
            continue
        lag = max(0.0, float(result["store_ms"]) - float(result["input_ms"]))
        lines_md.append(
            f"| {entry['scenario']} | {'YES' if entry['valid'] else 'NO'}"
            f" | {float(result['input_ms']):.0f} | {float(result['store_ms']):.0f}"
            f" | {lag:.0f} | {float(result['cpu_ms']):.0f}"
            f" | {result['seq']}/{result['expected']}"
            f" | {'; '.join(entry['notes']) or '-'} |")
    summary = "\n".join(lines_md) + "\n"
    if run_dir:
        (run_dir / "summary.md").write_text(summary)
    print(summary)

    for entry in table:
        stages = entry.get("stages") or []
        if not entry.get("results") or not stages:
            continue
        result, final = entry["results"][-1], stages[-1]
        emitted, received = final.get("emitted"), int(final["received"])
        backlog = emitted - received if emitted is not None else None
        print(
            f"{entry['scenario']}: emitted={emitted} received={received}"
            f" processed={final['processed']} published_seq={final['published_seq']}"
            f" samples={len(entry.get('samples', []))}"
            + (f" receive_backlog={backlog}" if backlog is not None else ""))
        if entry.get("samples"):
            print(f"{entry['scenario']}: sample_elapsed_ms="
                  + ",".join(str(s) for s in entry["samples"]))

    if invalid:
        if args.relaxed:
            print(f"relaxed summary: invalid scenarios: {sorted(set(invalid))}",
                  file=sys.stderr)
            return 0
        print(f"error: invalid or missing scenarios: {sorted(set(invalid))}",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
