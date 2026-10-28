#!/usr/bin/env python3
"""Build an immutable PiWork adapter package, without building the macOS app."""
import argparse
import gzip
import hashlib
import json
import re
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
DOWNLOAD_BASE = "https://github.com/section9-lab/pi-work/releases/download/"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def package(payload, metadata, architecture, output):
    runtime = metadata["piWorkRuntime"]
    version = runtime["version"]
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", version):
        raise ValueError("Runtime version must be numeric")
    if architecture not in ("arm64", "x86_64"):
        raise ValueError("Unsupported architecture")
    pi_version = metadata["dependencies"]["@earendil-works/pi-coding-agent"]
    files = {}
    for path in sorted(payload.rglob("*")):
        if path.is_symlink():
            raise ValueError("Runtime packages cannot contain symbolic links")
        if path.is_file():
            relative = path.relative_to(payload).as_posix()
            if relative not in ("pi-work-agent-host", "bun") and not relative.startswith(("theme/", "export-html/")):
                raise ValueError(f"Unexpected payload file: {relative}")
            files[relative] = sha256(path)
    if not {"pi-work-agent-host", "bun"}.issubset(files) or not all(
        any(path.startswith(prefix) for path in files) for prefix in ("theme/", "export-html/")
    ):
        raise ValueError("Host executable, Bun, theme, and HTML export assets are required")
    if len(files) > 4096 or sum((payload / path).stat().st_size for path in files) > 768 * 1024 * 1024:
        raise ValueError("Runtime payload exceeds the client size limit")
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"PiWorkRuntime-{version}-macos-{architecture}.tar.gz"
    with archive.open("wb") as destination:
        with gzip.GzipFile(filename="", mode="wb", fileobj=destination, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as tar:
                for relative in files:
                    path = payload / relative
                    entry = tarfile.TarInfo(relative)
                    entry.size = path.stat().st_size
                    entry.mode = 0o755 if relative in ("pi-work-agent-host", "bun") else 0o644
                    with path.open("rb") as source:
                        tar.addfile(entry, source)
    manifest = {
        "schemaVersion": 1,
        "version": version,
        "piVersion": pi_version,
        "apiVersion": runtime["apiVersion"],
        "acpVersion": 1,
        "minimumAppVersion": runtime["minimumAppVersion"],
        "maximumAppVersion": runtime.get("maximumAppVersion"),
        "minimumMacOSVersion": runtime["minimumMacOSVersion"],
        "architecture": architecture,
        "url": f"{DOWNLOAD_BASE}runtime-v{version}/{archive.name}",
        "byteCount": archive.stat().st_size,
        "sha256": sha256(archive),
        "files": files,
    }
    if manifest["byteCount"] > 256 * 1024 * 1024:
        raise ValueError("Runtime archive exceeds the client download limit")
    (output / f"runtime-{architecture}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--architecture", required=True, choices=["arm64", "x86_64"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--bun", default="bun")
    args = parser.parse_args()
    bun_executable = shutil.which(args.bun) or str(Path(args.bun).resolve())
    host_root = REPOSITORY / "AgentHost"
    metadata = json.loads((host_root / "package.json").read_text())
    sdk = host_root / "node_modules/@earendil-works/pi-coding-agent"
    installed = json.loads((sdk / "package.json").read_text())["version"]
    if installed != metadata["dependencies"]["@earendil-works/pi-coding-agent"]:
        raise ValueError("Installed SDK differs from the pinned dependency")
    with tempfile.TemporaryDirectory(prefix="pi-work-runtime-") as scratch:
        payload = Path(scratch)
        host = payload / "pi-work-agent-host"
        target = "arm64" if args.architecture == "arm64" else "x64"
        subprocess.run([bun_executable, "build", "--compile", "--no-compile-autoload-bunfig",
                        f"--target=bun-darwin-{target}", "src/main.ts", "--outfile", str(host)],
                       cwd=host_root, check=True)
        for source, destination in [("core/export-html", "export-html"), ("modes/interactive/theme", "theme")]:
            shutil.copytree(sdk / "dist" / source, payload / destination)
        bun = payload / "bun"
        shutil.copyfile(bun_executable, bun)
        bun.chmod(0o755)
        for executable in (host, bun):
            subprocess.run(["/usr/bin/lipo", str(executable), "-verify_arch", args.architecture], check=True)
            subprocess.run(["/usr/bin/codesign", "--force", "--preserve-metadata=entitlements", "--sign", "-", str(executable)], check=True)
            subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(executable)], check=True)
        package(payload, metadata, args.architecture, args.output.resolve())


if __name__ == "__main__":
    main()
