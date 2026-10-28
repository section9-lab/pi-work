import hashlib
import importlib.util
import json
import tarfile
import tempfile
import unittest
from pathlib import Path


def load_script(name):
    path = Path(__file__).with_name(name + ".py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


packager = load_script("package-agent-runtime")
publisher = load_script("publish-agent-runtime-index")


class AgentRuntimePackageTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.payload = self.root / "payload"
        for relative in ["pi-work-agent-host", "bun", "theme/theme.json", "export-html/template.html"]:
            path = self.payload / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(relative.encode())
        self.metadata = {
            "piWorkRuntime": {"version": "1.0.0", "apiVersion": 1,
                              "minimumAppVersion": "0.1.10", "minimumMacOSVersion": "13.0"},
            "dependencies": {"@earendil-works/pi-coding-agent": "0.84.1"},
        }

    def package(self):
        return packager.package(self.payload, self.metadata, "arm64", self.root / "dist")

    def test_manifest_covers_archive_and_every_payload_file(self):
        manifest = self.package()
        archive = self.root / "dist" / manifest["url"].split("/")[-1]
        self.assertEqual(manifest["sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        self.assertEqual(manifest["byteCount"], archive.stat().st_size)
        with tarfile.open(archive) as tar:
            self.assertEqual(set(tar.getnames()), set(manifest["files"]))
            for entry in tar:
                self.assertTrue(entry.isfile())
                self.assertEqual(hashlib.sha256(tar.extractfile(entry).read()).hexdigest(),
                                 manifest["files"][entry.name])

    def test_archive_is_reproducible(self):
        first = self.package()
        self.assertEqual(first, self.package())

    def test_symlinks_are_rejected(self):
        (self.payload / "theme/link").symlink_to("theme.json")
        with self.assertRaises(ValueError):
            self.package()

    def test_missing_assets_are_rejected(self):
        (self.payload / "theme/theme.json").unlink()
        with self.assertRaises(ValueError):
            self.package()

    def test_unexpected_payload_files_are_rejected(self):
        (self.payload / "extra-executable").write_bytes(b"unexpected")
        with self.assertRaises(ValueError):
            self.package()

    def test_versions_cannot_escape_release_directory(self):
        self.metadata["piWorkRuntime"]["version"] = "../../outside"
        with self.assertRaises(ValueError):
            self.package()

    def test_published_versions_cannot_be_replaced(self):
        manifest = self.package()
        previous = {"schemaVersion": 1, "releases": [manifest]}
        with self.assertRaises(ValueError):
            publisher.merge(previous, [{**manifest, "sha256": "changed"}])

    def test_channel_preserves_older_compatibility_ranges(self):
        older = self.package()
        newer = {**older, "version": "1.1.0", "minimumAppVersion": "0.2.0"}
        index = publisher.merge({"schemaVersion": 1, "releases": [older]}, [newer])
        self.assertEqual(index["releases"], [newer, older])

    def test_channel_can_be_rebuilt_idempotently(self):
        manifest = self.package()
        previous = {"schemaVersion": 1, "releases": [manifest]}
        self.assertEqual(publisher.merge(previous, [manifest]), previous)

    def test_runtime_release_does_not_replace_latest_app_release(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/release-agent-runtime.yml").read_text()
        self.assertIn('"runtime-v*"', workflow)
        self.assertIn("--latest=false", workflow)
        self.assertIn("Smoke test packaged runtime", workflow)
        self.assertIn("bun run typecheck", workflow)
        self.assertIn("bun test", workflow)


if __name__ == "__main__":
    unittest.main()
