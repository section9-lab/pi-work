#!/usr/bin/env python3
"""Lint budget gate with keys that cannot drift.

SwiftLint's own `--baseline` matches a violation by file, line and message. That
breaks for every size-based rule: `file_length` reports its violation *at the
last line of the file* and writes the length into the message, so any edit that
changes a file's size makes an already grandfathered violation look new. The
same happens to `type_body_length`, `function_body_length` and
`cyclomatic_complexity` whenever the measured thing changes size.

This gate keeps the intent ("only new violations fail") with a stable key: the
number of violations per (rule, file) pair. Consequences, by design:

- the same rule in the same file with the same count stays grandfathered, no
  matter how the line numbers or the measured sizes move;
- one extra violation, or a violation in a file that never had one, fails;
- fixing one violation and adding another *in the same file under the same
  rule* passes. That is the price for a key that does not drift; per-file
  review has to catch that swap.

Usage:
    lint_gate.py check --report report.json --budget scripts/lint-budget.json
    lint_gate.py write --report report.json --budget scripts/lint-budget.json

Both accept `--root` (defaults to the repository containing this script).
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import sys

BUDGET_VERSION = 1


def load_report(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as handle:
        text = handle.read().strip()
    if not text:
        return []
    try:
        report = json.loads(text)
    except json.JSONDecodeError as error:
        raise SystemExit(f"lint_gate: 无法解析 SwiftLint 报告 {path}: {error}")
    if not isinstance(report, list):
        raise SystemExit(f"lint_gate: SwiftLint 报告不是数组: {path}")
    return report


def relative(path: str, root: str) -> str:
    resolved = os.path.abspath(path)
    root = os.path.abspath(root)
    if resolved == root or resolved.startswith(root + os.sep):
        return os.path.relpath(resolved, root)
    return path


def group(report: list[dict], root: str) -> collections.Counter:
    counts: collections.Counter = collections.Counter()
    for violation in report:
        rule = violation.get("rule_id")
        path = violation.get("file")
        if not rule or not path:
            raise SystemExit(f"lint_gate: 违规记录缺少 rule_id/file: {violation}")
        counts[f"{rule}|{relative(path, root)}"] += 1
    return counts


def load_budget(path: str) -> dict[str, int]:
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or not isinstance(data.get("groups"), dict):
        raise SystemExit(f"lint_gate: 预算文件格式不对: {path}")
    budget = {}
    for key, count in data["groups"].items():
        if not isinstance(count, int) or count < 0:
            raise SystemExit(f"lint_gate: 预算里的计数必须是正整数: {key} -> {count!r}")
        budget[str(key)] = count
    return budget


def describe(key: str) -> str:
    rule, _, path = key.partition("|")
    return f"  {rule}  {path}"


def check(report_path: str, budget_path: str, root: str, partial: bool = False) -> int:
    actual = group(load_report(report_path), root)
    budget = load_budget(budget_path)

    new = []
    for key, count in sorted(actual.items()):
        allowed = budget.get(key, 0)
        if count > allowed:
            new.append((key, allowed, count))

    # A partial run only lints some files, so "absent from the report" is not
    # evidence that the debt was paid; only compare groups it actually saw.
    inspected = {key.partition("|")[2] for key in actual}
    tightened = sorted(
        (key, budget[key], actual.get(key, 0))
        for key in budget
        if budget[key] > actual.get(key, 0)
        and (not partial or key.partition("|")[2] in inspected)
    )

    total = sum(actual.values())
    if new:
        print(f"lint: 发现 {len(new)} 组新增违规（不在 scripts/lint-budget.json 里）:", file=sys.stderr)
        for key, allowed, count in new:
            print(f"{describe(key)}  预算 {allowed}，当前 {count}", file=sys.stderr)
        print(
            "lint: 修掉这些违规；如果确实是需要长期保留的存量，跑 scripts/lint.sh baseline 并说明原因。",
            file=sys.stderr,
        )
        return 1

    print(f"lint: {total} 条存量违规都在预算内，没有新增。")
    if tightened:
        print(
            f"lint: 有 {len(tightened)} 组比预算少（还债了），可以跑 scripts/lint.sh baseline 收紧预算。",
            file=sys.stderr,
        )
    return 0


def write(report_path: str, budget_path: str, root: str) -> int:
    actual = group(load_report(report_path), root)
    payload = {
        "version": BUDGET_VERSION,
        "groups": dict(sorted(actual.items())),
    }
    os.makedirs(os.path.dirname(budget_path) or ".", exist_ok=True)
    with open(budget_path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    print(f"lint: 预算已写入 {budget_path}：{len(actual)} 组 / {sum(actual.values())} 条违规。")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="PiWork lint budget gate")
    parser.add_argument("mode", choices=("check", "write"))
    parser.add_argument("--report", required=True)
    parser.add_argument("--budget", required=True)
    parser.add_argument("--root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    parser.add_argument(
        "--partial",
        action="store_true",
        help="只 lint 了一部分文件，不要报告其它文件“比预算少”",
    )
    arguments = parser.parse_args(argv)

    if arguments.mode == "write":
        return write(arguments.report, arguments.budget, arguments.root)
    return check(arguments.report, arguments.budget, arguments.root, arguments.partial)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
