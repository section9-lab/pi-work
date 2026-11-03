import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "ci/Package.resolved"
PREPARE = ROOT / "scripts/prepare-swift-packages.sh"
ACTION = ROOT / ".github/actions/prepare-macos-dependencies/action.yml"
WARMUP = ROOT / ".github/workflows/cache-macos-dependencies.yml"


class NativeDependencyConfigurationTests(unittest.TestCase):
    def test_committed_lock_matches_direct_project_dependencies(self):
        lock = json.loads(LOCK.read_text())
        self.assertIn(lock["version"], (2, 3))
        pins = {pin["location"].removesuffix(".git"): pin for pin in lock["pins"]}
        packages = (ROOT / "project.yml").read_text().split("\npackages:\n", 1)[1].split("\ntargets:", 1)[0]
        declarations = re.findall(r"(?m)^  ([\w-]+):\n((?:    .*(?:\n|$))+)", packages)
        self.assertGreaterEqual(len(declarations), 3)
        for name, declaration in declarations:
            with self.subTest(package=name):
                url = re.search(r"url: (\S+)", declaration).group(1)
                pin = pins[url.removesuffix(".git")]
                version = re.search(r"exactVersion: (\S+)", declaration)
                revision = re.search(r"revision: (\S+)", declaration)
                self.assertTrue(version or revision, "Release dependencies must be pinned")
                if version:
                    self.assertEqual(pin["state"]["version"], version.group(1))
                if revision:
                    self.assertEqual(pin["state"]["revision"], revision.group(1))
        for pin in pins.values():
            self.assertRegex(pin["state"]["revision"], r"^[0-9a-f]{40}$")

    def test_cache_key_is_toolchain_architecture_and_lock_specific_not_release_specific(self):
        action = ACTION.read_text()
        self.assertIn("actions/cache@v4", action)
        self.assertIn("runner.os", action)
        self.assertIn("runner.arch", action)
        self.assertIn("xcodebuild -version", action)
        self.assertIn("ci/Package.resolved", action)
        self.assertIn("scripts/fetch-sparkle-tools.sh", action)
        self.assertNotIn("github.sha", action)
        self.assertNotIn("github.ref", action)
        self.assertNotIn("hashFiles('project.yml')", action)
        self.assertNotIn("DerivedData", action)
        self.assertNotIn("restore-keys:", action)

    def test_default_branch_warms_the_same_action_for_both_release_architectures(self):
        warmup = WARMUP.read_text()
        release = (ROOT / ".github/workflows/release-macos.yml").read_text()
        self.assertIn("branches: [main]", warmup)
        self.assertIn("workflow_dispatch:", warmup)
        self.assertIn("macos-15-intel", warmup)
        self.assertIn("runner: macos-15\n", warmup)
        self.assertIn("ci/Package.resolved", warmup)
        self.assertIn("scripts/prepare-swift-packages.sh", warmup)
        for workflow in (warmup, release):
            self.assertIn("uses: ./.github/actions/prepare-macos-dependencies", workflow)
        self.assertNotIn("gh release", warmup)
        self.assertNotIn("secrets.", warmup)

    def test_exact_cache_hits_stage_the_lockfile_without_resolving_again(self):
        action = ACTION.read_text()
        self.assertIn("--stage-only", action)
        self.assertIn("steps.swift-cache.outputs.cache-hit != 'true'", action)


class SwiftPackagePreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "ci").mkdir()
        (self.root / "bin").mkdir()
        shutil.copyfile(PREPARE, self.root / "scripts/prepare-swift-packages.sh")
        shutil.copyfile(LOCK, self.root / "ci/Package.resolved")
        self.capture = self.root / "arguments.json"
        self.cache = self.root / "shared packages with spaces"
        self.env = dict(os.environ, PATH=f"{self.root / 'bin'}:{os.environ['PATH']}",
                        SWIFT_PACKAGE_CACHE_PATH=str(self.cache), CI_TEST_CAPTURE=str(self.capture))
        fake_xcode = self.root / "bin/xcodebuild"
        fake_xcode.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, sys
pathlib.Path(os.environ["CI_TEST_CAPTURE"]).write_text(json.dumps(sys.argv[1:]))
print("fixture Xcode diagnostic output", flush=True)
if os.environ.get("CI_TEST_MUTATE_LOCK"):
    path = pathlib.Path("pi-work.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
    data = json.loads(path.read_text())
    data["pins"][0]["state"]["revision"] = "0" * 40
    path.write_text(json.dumps(data))
sys.exit(int(os.environ.get("CI_TEST_XCODE_EXIT", "0")))
''')
        fake_xcode.chmod(0o755)

    def run_prepare(self, *arguments):
        return subprocess.run(
            ["bash", str(self.root / "scripts/prepare-swift-packages.sh"), *arguments],
            env=self.env,
            text=True,
            capture_output=True,
        )

    def test_resolves_once_into_explicit_shared_cache_using_committed_lock(self):
        result = self.run_prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        args = json.loads(self.capture.read_text())
        self.assertIn("-resolvePackageDependencies", args)
        self.assertIn("-onlyUsePackageVersionsFromResolvedFile", args)
        self.assertIn("-disableAutomaticPackageResolution", args)
        self.assertEqual(args[args.index("-clonedSourcePackagesDirPath") + 1], str(self.cache))
        generated = self.root / "pi-work.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        self.assertEqual(json.loads(generated.read_text()), json.loads(LOCK.read_text()))
        self.assertTrue(self.cache.is_dir())

    def test_stage_only_copies_the_committed_lock_without_invoking_xcode(self):
        result = self.run_prepare("--stage-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        generated = self.root / "pi-work.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        self.assertEqual(json.loads(generated.read_text()), json.loads(LOCK.read_text()))
        self.assertTrue(self.cache.is_dir())
        self.assertFalse(self.capture.exists())

    def test_dependency_drift_is_rejected(self):
        self.env["CI_TEST_MUTATE_LOCK"] = "1"
        result = self.run_prepare()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Package.resolved", result.stderr)
        self.assertEqual((self.root / "ci/Package.resolved").read_bytes(), LOCK.read_bytes())

    def test_resolution_failure_is_not_masked(self):
        self.env["CI_TEST_XCODE_EXIT"] = "17"
        self.assertEqual(self.run_prepare().returncode, 17)

    def test_missing_cache_path_fails_before_invoking_xcode(self):
        del self.env["SWIFT_PACKAGE_CACHE_PATH"]
        self.assertNotEqual(self.run_prepare().returncode, 0)
        self.assertFalse(self.capture.exists())

    def assert_xcode_failure_is_preserved(self, step_name, log_name):
        workflow = (ROOT / ".github/workflows/release-macos.yml").read_text()
        step = workflow.split(f"- name: {step_name}\n", 1)[1].split("      - name:", 1)[0]
        script = textwrap.dedent(step.split("run: |\n", 1)[1])
        script = script.replace("${{ matrix.arch }}", "arm64").replace("${{ matrix.suffix }}", "arm64")
        self.env.update(CI_TEST_XCODE_EXIT="17", RUNNER_TEMP=str(self.root),
                        PROJECT_VERSION="0.0.1", GITHUB_ENV=str(self.root / "github-env"))
        result = subprocess.run(["bash", "-e", "-c", script], env=self.env,
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 17, result.stderr)
        self.assertIn("fixture Xcode diagnostic output", (self.root / "BuildDiagnostics" / log_name).read_text())

    def test_test_pipeline_keeps_diagnostics_and_propagates_failure(self):
        self.assert_xcode_failure_is_preserved("Run application tests", "application-tests.log")

    def test_archive_pipeline_keeps_diagnostics_and_propagates_failure(self):
        self.assert_xcode_failure_is_preserved("Build archive", "archive.log")


if __name__ == "__main__":
    unittest.main()
