#!/usr/bin/env python3
"""Merge immutable runtime descriptors, retaining compatible older releases."""
import argparse
import json
from pathlib import Path


def merge(previous, releases):
    if previous.get("schemaVersion") != 1:
        raise ValueError("Unsupported channel schema")
    indexed = {(entry["version"], entry["architecture"]): entry for entry in previous["releases"]}
    for entry in releases:
        key = (entry["version"], entry["architecture"])
        if key in indexed and indexed[key] != entry:
            raise ValueError("Published runtime versions are immutable")
        indexed[key] = entry
    entries = sorted(indexed.values(), key=lambda entry: tuple(map(int, entry["version"].split("."))), reverse=True)
    # Two architectures for each of the most recent 64 releases.
    return {"schemaVersion": 1, "releases": entries[:128]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--previous", type=Path, required=True)
    args = parser.parse_args()
    previous = json.loads(args.previous.read_text()) if args.previous.exists() else {"schemaVersion": 1, "releases": []}
    releases = [json.loads(path.read_text()) for path in args.artifacts.glob("runtime-*.json")
                if path.name != "runtime-index.json"]
    if {entry["architecture"] for entry in releases} != {"arm64", "x86_64"}:
        raise ValueError("Both native runtime architectures are required")
    (args.artifacts / "runtime-index.json").write_text(json.dumps(merge(previous, releases), indent=2) + "\n")


if __name__ == "__main__":
    main()
