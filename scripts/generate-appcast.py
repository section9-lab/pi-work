"""Publish one architecture's authenticated Sparkle feed alongside its DMG."""
import argparse
import base64
import email.utils
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DOWNLOADS = "https://github.com/section9-lab/pi-work/releases/download"


def generate(version, architecture, dmg, output, sign_tool, key, notes="", download_base=DOWNLOADS):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected a numeric release version")
    if architecture not in ("arm64", "x86_64"):
        raise ValueError("Unsupported release architecture")
    expected_name = f"PiWork-{version}-macos-{architecture}.dmg"
    if dmg.name != expected_name or not dmg.is_file() or dmg.stat().st_size == 0:
        raise ValueError("Expected the nonempty release DMG for this version and architecture")
    if len(base64.b64decode(key.strip(), validate=True)) != 32:
        raise ValueError("Expected a Sparkle Ed25519 private seed")

    def sign(path, *arguments):
        result = subprocess.run([str(sign_tool), "--ed-key-file", "-", *arguments, str(path)],
                                input=key, text=True, capture_output=True, check=False)
        if result.returncode:
            # Never forward a process environment or signing material to CI logs.
            raise RuntimeError(f"Sparkle signing failed for {path.name}")
        return result.stdout.strip()

    signature = sign(dmg, "-p")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Invalid Sparkle archive signature")
    ET.register_namespace("sparkle", SPARKLE)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "PiWork"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"PiWork {version}"
    ET.SubElement(item, "pubDate").text = email.utils.formatdate(usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = version
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "13.0.0"
    if notes:
        ET.SubElement(item, "description").text = notes
    ET.SubElement(item, "enclosure", {
        "url": f"{download_base}/v{version}/{expected_name}",
        f"{{{SPARKLE}}}edSignature": signature,
        "length": str(dmg.stat().st_size),
        "type": "application/octet-stream",
    })
    output.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(rss).write(output, encoding="utf-8", xml_declaration=True)
    sign(output)  # Sparkle embeds the feed signature; do not mutate it afterwards.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--architecture", choices=["arm64", "x86_64"], required=True)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--sign-tool", type=Path, required=True)
    parser.add_argument("--notes", type=Path)
    args = parser.parse_args()
    key = os.environ.get("SPARKLE_ED25519_PRIVATE_KEY", "")
    if not key:
        parser.error("SPARKLE_ED25519_PRIVATE_KEY is required; unsigned app releases are not published")
    generate(args.version, args.architecture, args.dmg, args.output, args.sign_tool, key,
             args.notes.read_text() if args.notes and args.notes.is_file() else "")


if __name__ == "__main__":
    main()
