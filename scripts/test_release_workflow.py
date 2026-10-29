import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
WORKFLOW_PATH = REPOSITORY_ROOT / ".github/workflows/release-macos.yml"
PROJECT_PATH = REPOSITORY_ROOT / "project.yml"
INFO_PLIST_PATH = REPOSITORY_ROOT / "PiWork/Resources/Info.plist"
AGENT_HOST_LOCK_PATH = REPOSITORY_ROOT / "AgentHost/bun.lock"
AGENT_HOST_PACKAGE_PATH = REPOSITORY_ROOT / "AgentHost/package.json"


class ReleaseWorkflowTests(unittest.TestCase):
    def workflow_text(self):
        self.assertTrue(
            WORKFLOW_PATH.is_file(),
            "The tag-triggered macOS release workflow must exist.",
        )
        return WORKFLOW_PATH.read_text()

    def test_version_tag_triggers_release(self):
        workflow = self.workflow_text()

        self.assertIn("tags:", workflow)
        self.assertIn('"v*"', workflow)
        self.assertIn("GITHUB_REF_NAME", workflow)
        self.assertIn("PROJECT_VERSION", workflow)

    def test_installed_app_reports_the_marketing_version(self):
        project = PROJECT_PATH.read_text()
        info_plist = INFO_PLIST_PATH.read_text()

        self.assertIn(
            'CFBundleShortVersionString: "$(MARKETING_VERSION)"',
            project,
        )
        self.assertIn("<string>$(MARKETING_VERSION)</string>", info_plist)

    def test_release_builds_native_arm64_and_x86_64_packages(self):
        workflow = self.workflow_text()

        self.assertIn("macos-15", workflow)
        self.assertIn("macos-15-intel", workflow)
        self.assertIn("arch: arm64", workflow)
        self.assertIn("arch: x86_64", workflow)

    def test_release_uses_ad_hoc_signing_without_notarization(self):
        workflow = self.workflow_text()

        self.assertIn("CODE_SIGNING_ALLOWED=NO", workflow)
        self.assertIn(
            'codesign --force --deep --preserve-metadata=entitlements,flags,runtime --sign - "$app_path"',
            workflow,
        )
        self.assertIn('codesign --force --sign - "$dmg_path"', workflow)
        self.assertNotIn("notarytool", workflow)
        self.assertNotIn("stapler", workflow)

    def test_release_requires_no_apple_credentials(self):
        workflow = self.workflow_text()

        for secret_name in (
            "MACOS_CERTIFICATE_P12",
            "MACOS_CERTIFICATE_PASSWORD",
            "APPLE_ID",
            "APPLE_APP_SPECIFIC_PASSWORD",
            "APPLE_TEAM_ID",
        ):
            self.assertNotIn(secret_name, workflow)

    def test_release_notes_disclose_gatekeeper_warning(self):
        workflow = self.workflow_text()

        self.assertIn("not notarized by Apple", workflow)
        self.assertIn("Gatekeeper warning", workflow)

    def test_release_publishes_both_dmg_artifacts(self):
        workflow = self.workflow_text()

        self.assertIn("contents: write", workflow)
        self.assertIn("actions/upload-artifact", workflow)
        self.assertIn("actions/download-artifact", workflow)
        self.assertIn("gh release create", workflow)

    def test_release_frees_build_storage_before_creating_dmg(self):
        workflow = self.workflow_text()

        self.assertIn("- name: Reclaim build storage", workflow)
        cleanup = workflow.index("- name: Reclaim build storage")
        package = workflow.index("- name: Create ad-hoc signed DMG")

        self.assertLess(cleanup, package)
        self.assertIn('-derivedDataPath "$derived_data_path"', workflow)
        self.assertIn('rm -rf "$DERIVED_DATA_PATH"', workflow)
        self.assertIn('mv "$app_path" "$staging_path/PiWork.app"', workflow)
        self.assertIn('rm -rf "$ARCHIVE_PATH"', workflow)

    def test_release_preallocates_dmg_capacity(self):
        workflow = self.workflow_text()

        self.assertIn('staging_size_mb="$(du -sm "$staging_path" | awk', workflow)
        self.assertIn('dmg_size_mb="$((staging_size_mb + 256))"', workflow)
        self.assertIn('-size "${dmg_size_mb}m"', workflow)

    def test_release_cli_targets_repository_without_checkout(self):
        workflow = self.workflow_text()

        self.assertIn("GH_REPO: ${{ github.repository }}", workflow)

    def test_nested_executables_use_notarizable_signatures(self):
        project = PROJECT_PATH.read_text()
        hardened_signing_lines = [
            line
            for line in project.splitlines()
            if "/usr/bin/codesign" in line and "--options runtime" in line
        ]

        self.assertEqual(2, len(hardened_signing_lines))
        for line in hardened_signing_lines:
            self.assertIn("--timestamp", line)
            self.assertIn("--preserve-metadata=entitlements", line)

    def test_agent_host_lockfile_is_usable_without_private_registry_credentials(self):
        lockfile = AGENT_HOST_LOCK_PATH.read_text()

        self.assertFalse(
            ".codeartifact." in lockfile,
            "The Agent Host lockfile must use a registry available to clean CI runners.",
        )

    def test_compiled_agent_host_does_not_autoload_project_bunfig(self):
        project = PROJECT_PATH.read_text()
        package = AGENT_HOST_PACKAGE_PATH.read_text()

        self.assertIn("--no-compile-autoload-bunfig", project)
        self.assertEqual(2, package.count("--no-compile-autoload-bunfig"))


if __name__ == "__main__":
    unittest.main()
