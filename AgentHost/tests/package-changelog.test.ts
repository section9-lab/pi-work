import { expect, test } from "bun:test";
import { mkdtemp, mkdir, writeFile, symlink, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readPackageChangelog } from "../src/package-changelog.ts";

test("package changelogs include only newly installed versions and stay inside the package", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-work-changelog-"));
  try {
    const pkg = join(root, "package");
    await mkdir(join(pkg, "docs"), { recursive: true });
    await writeFile(join(pkg, "package.json"), JSON.stringify({ pi: { changelogPath: "docs/CHANGES.md" } }));
    await writeFile(join(pkg, "docs/CHANGES.md"), "## [2.0.0]\nFuture\n## 1.3.0 - date\nNew capability\n## [1.2.0]\nEarlier\n");
    expect(await readPackageChangelog(pkg, "1.2.0", "1.3.0")).toBe("## 1.3.0 - date\nNew capability");
    expect(await readPackageChangelog(pkg, "1.3.0", "1.3.0")).toBeUndefined();
    await writeFile(join(pkg, "package.json"), "{}");
    await writeFile(join(pkg, "CHANGELOG.md"), "## [1.3.0]\nStable release\n## [1.3.0-beta.1]\nPreview");
    expect(await readPackageChangelog(pkg, "1.3.0-beta.1", "1.3.0")).toBe("## [1.3.0]\nStable release");
    await writeFile(join(pkg, "CHANGELOG.md"), "x".repeat(256 * 1024 + 1));
    expect(await readPackageChangelog(pkg, "1.2.0", "1.3.0")).toBeUndefined();
    await writeFile(join(root, "private.md"), "## 1.3.0\nMUST NOT LEAK");
    for (const changelogPath of ["../private.md", join(root, "private.md"), "docs/linked.md", ""]) {
      if (changelogPath === "docs/linked.md") await symlink(join(root, "private.md"), join(pkg, changelogPath));
      await writeFile(join(pkg, "package.json"), JSON.stringify({ pi: { changelogPath } }));
      expect(await readPackageChangelog(pkg, "1.2.0", "1.3.0")).toBeUndefined();
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});
