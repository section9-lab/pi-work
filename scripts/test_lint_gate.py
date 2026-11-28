import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts/lint_gate.py"
LINT_SH = ROOT / "scripts/lint.sh"
BUDGET = ROOT / "scripts/lint-budget.json"


def run_gate(mode: str, report: list, budget: Path, extra: list[str] = ()) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
        json.dump(report, handle)
        report_path = handle.name
    try:
        return subprocess.run(
            [sys.executable, str(GATE), mode,
             "--report", report_path,
             "--budget", str(budget),
             "--root", str(ROOT), *extra],
            capture_output=True,
            text=True,
        )
    finally:
        os.unlink(report_path)


def violation(rule: str, path: str, line: int = 1) -> dict:
    return {
        "rule_id": rule,
        "file": str(ROOT / path),
        "line": line,
        "reason": f"{rule} reason that changes with the measured size: {line}",
        "severity": "error",
    }


class LintGateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.budget_path = Path(self.directory.name) / "budget.json"
        self.budget_path.write_text(json.dumps({
            "version": 1,
            "groups": {
                "file_length|PiWork/Big.swift": 1,
                "line_length|PiWork/Big.swift": 3,
            },
        }))

    def test_matching_counts_pass(self):
        report = [
            violation("file_length", "PiWork/Big.swift", 2600),
            violation("line_length", "PiWork/Big.swift", 12),
            violation("line_length", "PiWork/Big.swift", 40),
            violation("line_length", "PiWork/Big.swift", 90),
        ]

        result = run_gate("check", report, self.budget_path)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_drifted_line_numbers_and_reasons_still_pass(self):
        # Same rule, same file, same count, but the file grew and every reason
        # string now quotes a different number: SwiftLint's own baseline fails
        # here, the count-based budget must not.
        report = [
            violation("file_length", "PiWork/Big.swift", 3000),
            violation("line_length", "PiWork/Big.swift", 15),
            violation("line_length", "PiWork/Big.swift", 44),
            violation("line_length", "PiWork/Big.swift", 91),
        ]

        result = run_gate("check", report, self.budget_path)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_one_extra_violation_in_the_same_file_fails(self):
        report = [
            violation("file_length", "PiWork/Big.swift", 2600),
            violation("line_length", "PiWork/Big.swift", 12),
            violation("line_length", "PiWork/Big.swift", 40),
            violation("line_length", "PiWork/Big.swift", 90),
            violation("line_length", "PiWork/Big.swift", 120),
        ]

        result = run_gate("check", report, self.budget_path)

        self.assertEqual(result.returncode, 1)
        self.assertIn("line_length  PiWork/Big.swift", result.stderr)
        self.assertIn("预算 3，当前 4", result.stderr)

    def test_violation_in_an_unbudgeted_file_fails(self):
        result = run_gate("check", [violation("no_print", "PiWork/New.swift")], self.budget_path)

        self.assertEqual(result.returncode, 1)
        self.assertIn("no_print  PiWork/New.swift", result.stderr)

    def test_write_records_relative_paths_and_counts(self):
        report = [
            violation("file_length", "PiWork/Big.swift", 2600),
            violation("line_length", "PiWork/Big.swift", 12),
        ]

        result = run_gate("write", report, self.budget_path)

        self.assertEqual(result.returncode, 0, result.stderr)
        written = json.loads(self.budget_path.read_text())
        self.assertEqual(written["version"], 1)
        self.assertEqual(
            written["groups"],
            {
                "file_length|PiWork/Big.swift": 1,
                "line_length|PiWork/Big.swift": 1,
            },
        )

    def test_paths_outside_the_repository_keep_their_absolute_form(self):
        outside = {"rule_id": "no_print", "file": "/elsewhere/Probe.swift", "line": 1,
                   "reason": "probe", "severity": "error"}

        run_gate("write", [outside], self.budget_path)

        written = json.loads(self.budget_path.read_text())
        self.assertEqual(written["groups"], {"no_print|/elsewhere/Probe.swift": 1})

    def test_partial_runs_do_not_report_untouched_files_as_paid_down(self):
        result = run_gate("check", [], self.budget_path, extra=["--partial"])

        self.assertEqual(result.returncode, 0)
        self.assertNotIn("收紧预算", result.stderr)

    def test_full_runs_suggest_tightening_paid_down_groups(self):
        result = run_gate("check", [], self.budget_path)

        self.assertEqual(result.returncode, 0)
        self.assertIn("收紧预算", result.stderr)

    def test_committed_budget_is_sorted_and_consistent(self):
        payload = json.loads(BUDGET.read_text())

        self.assertEqual(payload["version"], 1)
        keys = list(payload["groups"])
        self.assertEqual(keys, sorted(keys))
        for key, count in payload["groups"].items():
            rule, separator, path = key.partition("|")
            self.assertTrue(separator, f"预算键缺少分隔符: {key}")
            self.assertTrue(rule)
            self.assertFalse(os.path.isabs(path), f"预算里的路径必须是相对路径: {key}")
            self.assertGreaterEqual(count, 1)

    def test_lint_script_uses_the_budget_gate(self):
        script = LINT_SH.read_text()
        self.assertIn("lint_gate.py", script)
        self.assertIn("scripts/lint-budget.json", script)
        commands = [line for line in script.splitlines() if not line.lstrip().startswith("#")]
        offenders = [line for line in commands if "--baseline" in line]
        self.assertEqual(offenders, [], "lint.sh 不应再调用 SwiftLint 的 --baseline")


if __name__ == "__main__":
    unittest.main()
