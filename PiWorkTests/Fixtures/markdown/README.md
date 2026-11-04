# Complex Markdown benchmark fixture

`performance-complex.md` is used by the opt-in native benchmark:

```bash
bash scripts/benchmark-markdown-isolation.sh
```

The full document is 4,609 UTF-8 bytes before substituting `{{TITLE}}`, `{{INDEX}}`, and `{{SALT}}`. It includes heading levels 1–6; seven fenced blocks labelled Swift, TypeScript, Python, SQL, JSON, diff, and Bash; long code lines; a five-column aligned table; nested ordered/unordered/task lists; nested blockquotes; inline emphasis/code/links; a thematic break; escaping; and mixed Chinese/English/emoji. It has no remote images or network-dependent resources. Language labels do not imply that the app performs syntax highlighting.

Two workloads are deliberately separate:

- **Dense, cold-open only:** 1,000 source messages; the initial 100-row window contains 80 full documents and 20 short user messages. This is the extreme document-density stress case.
- **Mixed, complete scenarios:** the same 1,000 source IDs; each 100-row window contains 10 full documents, 70 shorter Markdown replies (headings, code, table, nested list, quote), and 20 short user messages. This permits repeated historical navigation without making the entire experiment an hour-long stress run.

In either workload, each streamed response concatenates **two full documents**, not the shorter variant. Roughly 150 equal-character chunks at 50 Hz intentionally split Markdown constructs, including code fences and table syntax. Baseline and candidate receive byte-identical input for the same iteration.

Both initial windows contain 100 rows. The baseline grows to a 300-row historical window; the candidate keeps 100 and advances 60 with 40 overlapping rows. The benchmark also compares equal historical coverage so that fewer rows per action is not mistaken for equal work.

The driver first runs the shared correctness checks, then separately verifies the final text in actual mounted `AssistantMarkdownPresentation` instances. If the baseline's visible-renderer check reproduces the known stale-final-text result, it is recorded as a **correctness failure**, not silently passed. A `stream_live` sample with `final_render_valid = 0` is retained for diagnosis but excluded from speedup ratios. The candidate must pass that check.

The candidate exists only in a staged `build/MarkdownIsolationBenchmark/` copy. This fixture and its driver do not change production rendering or add an always-running performance test to normal XCTest runs.
