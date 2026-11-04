#!/usr/bin/env python3
"""Attribute `sample` profiles from the diagnosis harness.

Two views per profile:
1. Top-of-stack leaves: aggregated by symbol and by module ("in <lib>"). This
   shows where the sampled thread actually was.
2. Ancestor share: the sum of printed cumulative counts on call-graph lines
   containing a curated symbol. Line counts double-count nested repeats and
   deduplicated subtrees, so treat these as order-of-magnitude shares while
   deciding WHERE to dig, not percentages. Python 3.9 compatible.
"""
import argparse
import collections
import pathlib
import re
import sys

LINE_COUNT = re.compile(r"\s*(\d+)\s+(.*)")
IN_MODULE = re.compile(r"\(in ([^) ]+)\)")
TOP_ROW = re.compile(r"^\s{8}(\S+)\s*\(in ([^)]+)\)\s*(\d+)?\s*$")

CATEGORIES = {
    "SwiftUI layout engine": ["SwiftUI", "SwiftUICore", "AttributeGraph"],
    "AppKit view layout": ["AppKit"],
    "Text typesetting": ["CoreText"],
    "Markdown parse": ["cmark", "MarkdownUI"],
    "PiWork app code": ["PiWorkTests", "PiWork"],
    "Allocation/retain": ["libsystem_malloc", "libswiftCore", "CoreFoundation"],
}
MODULE_CATEGORY = {}
for category, modules in CATEGORIES.items():
    for module in modules:
        MODULE_CATEGORY[module] = category

# Curated ancestors: rare enough to have only a few line matches and always
# on the streaming/layout path of the diagnosis test.
ANCESTORS = [
    "NSHostingView.beginTransaction",
    "ViewGraphRootValueUpdater",
    "GraphHost.flushTransactions",
    "AG::Subgraph::update",
    "GeometryReaderLayout.placeSubviews",
    "ScrollViewLayoutComputer",
    "StackLayout.UnmanagedImplementation.placeChildren",
    "LayoutProxy.size(in:)",
    "UnaryLayoutEngine.sizeThatFits",
    "StyledTextLayoutEngine.sizeThatFits",
    "MarkdownContent",
    "MarkdownUI",
    "AssistantMarkdownView",
    "AssistantMarkdownPresentation.render",
    "AssistantMarkdownCache",
    "SessionStore.receive(_:)",
    "TranscriptMessagePresentation.refresh",
    "PiChatMessage.init(message:",
    "CoreTypesetter",
]


def parse_top_of_stack(lines: list) -> (collections.Counter, collections.Counter):
    symbols, modules = [], []
    for line in lines:
        top = TOP_ROW.match(line)
        if top:
            symbol, module, count = top.group(1), top.group(2), top.group(3)
            value = int(count) if count else 5  # section prints rows when >=5
            symbols.append((symbol, module, value))
    by_symbol = collections.Counter()
    by_module = collections.Counter()
    for symbol, module, value in symbols:
        by_symbol[(symbol, module)] += value
        by_module[module] += value
    return by_symbol, by_module


def parse_ancestors(lines: list) -> dict:
    totals = {}
    for pattern in ANCESTORS:
        total = 0
        matches = 0
        for line in lines:
            count_match = LINE_COUNT.match(line)
            if count_match and pattern in count_match.group(2):
                total += int(count_match.group(1))
                matches += 1
        if matches:
            totals[pattern] = (total, matches)
    return totals


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("profiles", nargs="+")
    parser.add_argument("--top", type=int, default=18)
    args = parser.parse_args()

    for path in args.profiles:
        lines = pathlib.Path(path).read_text(errors="replace").splitlines()
        stack_total = 0
        for line in lines:
            if "Total number in stack" in line:
                match = re.search(r"stack[^:]*:\s*(\d+)", line)
                if match:
                    stack_total = int(match.group(1))
        by_symbol, by_module = parse_top_of_stack(lines)
        print(f"\n== {pathlib.Path(path).name} ==")
        print(f"top-of-stack rows parsed: {sum(by_symbol.values())}"
              + (f" (total in stack {stack_total})" if stack_total else ""))
        print(f"? module: samples")
        for module, value in by_module.most_common(15):
            print(f"  {module:34} {value}")
        print("?? top leaves:")
        for (symbol, module), value in by_symbol.most_common(args.top):
            print(f"  {value:6} {module:22} {symbol[:80]}")
        ancestors = parse_ancestors(lines)
        if ancestors:
            print("?? ancestor shares (approx line-count sums):")
            for pattern, (total, matches) in sorted(
                    ancestors.items(), key=lambda item: -item[1][0]):
                print(f"  {total:8} across {matches:2} matches: {pattern}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
