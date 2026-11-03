import { open, realpath } from "node:fs/promises";
import { isAbsolute, join, relative, resolve, sep } from "node:path";

const maximumBytes = 256 * 1024;

async function readBounded(path: string): Promise<string | undefined> {
  const file = await open(path, "r");
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > maximumBytes) return undefined;
    const bytes = Buffer.alloc(maximumBytes + 1);
    let length = 0;
    while (length < bytes.length) {
      const read = await file.read(bytes, length, bytes.length - length, length);
      if (read.bytesRead === 0) break;
      length += read.bytesRead;
    }
    return length <= maximumBytes ? bytes.subarray(0, length).toString("utf8") : undefined;
  } finally { await file.close(); }
}

/** Local, bounded, read-only preview. A package manifest cannot expose files outside its root. */
export async function readPackageChangelog(root: string | undefined, from: string, to: string): Promise<string | undefined> {
  if (!root || from === to) return undefined;
  try {
    const manifestText = await readBounded(join(root, "package.json"));
    if (!manifestText) return undefined;
    const manifest = JSON.parse(manifestText);
    const configured = manifest?.pi?.changelogPath;
    const path = configured === undefined ? "CHANGELOG.md" : configured;
    if (typeof path !== "string" || !path || isAbsolute(path)) return undefined;
    const base = await realpath(root), target = await realpath(resolve(base, path));
    const inside = relative(base, target);
    if (inside === ".." || inside.startsWith(`..${sep}`) || isAbsolute(inside)) return undefined;
    const text = await readBounded(target);
    if (!text) return undefined;
    const version = /^##\s+\[?v?(\d+\.\d+\.\d+(?:-[\da-z.-]+)?(?:\+[\da-z.-]+)?)\]?(?:\s|$)/i;
    const entries: string[] = [];
    let current: string[] | undefined;
    for (const line of text.replace(/^\uFEFF/, "").split(/\r?\n/)) {
      if (line.startsWith("## ")) {
        if (current) entries.push(current.join("\n").trim());
        const match = version.exec(line);
        current = match && Bun.semver.order(match[1]!, from) > 0 && Bun.semver.order(match[1]!, to) <= 0 ? [line] : undefined;
      } else current?.push(line);
    }
    if (current) entries.push(current.join("\n").trim());
    return entries.length ? entries.join("\n\n") : undefined;
  } catch {
    // Missing, invalid or oversized changelogs never turn a successful package
    // update into a failure, and paths/content are not written to diagnostics.
    return undefined;
  }
}
