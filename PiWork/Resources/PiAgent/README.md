# Optional standalone Pi binaries (not committed to git)

This folder is populated by `scripts/fetch-pi-binary.sh`, which downloads the
official standalone `pi` coding-agent release binaries from
https://github.com/earendil-works/pi/releases for both Apple Silicon
(`arm64/pi`) and Intel (`x64/pi`).

These binaries are only useful for manual upstream debugging. They are not
included in the app and are not required for a normal build. Fetch them with:

```bash
./scripts/fetch-pi-binary.sh
```

Production builds compile `AgentHost/src/main.ts` with Bun and embed the
matching self-contained Agent Host under `Contents/Resources/AgentHost`. The
Host contains the Pi SDK, so end users do not need Bun, Node, npm, or a
separate `pi` installation.
