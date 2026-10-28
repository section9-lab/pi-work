# Independent agent runtime updates

PiWork can update its Agent Host, embedded Pi SDK, Bun package manager, themes, and HTML export assets
without replacing the application. Settings → General → pi-coding-agent offers
the newest **compatible PiWork runtime**, not an untested upstream npm release.
Installation leaves running tasks alone. The update activates on the next launch;
a pending update can be cancelled, and an active downloaded runtime can be restored
to its previous version from the same settings section.

## Compatibility and integrity boundary

- Schema v1 describes an immutable runtime version, Pi version, CPU architecture,
  minimum macOS version, minimum/optional maximum app version, runtime API v1,
  and ACP v1. The channel retains older releases for older compatible apps.
- Downloads must come from the fixed `section9-lab/pi-work` GitHub release path.
  HTTPS redirects are limited to GitHub's release asset hosts. The manifest and
  archive are size bounded; archives are downloaded to disk.
- The archive's SHA-256 and every extracted file's SHA-256 must match the manifest.
  USTAR extraction accepts only declared regular files: no links, special files,
  duplicate entries, absolute paths, traversal, or unexpected files. Expanded
  content is bounded. Both Mach-O executables must contain the declared CPU
  architecture and their code signatures must verify before execution.
- A temporary configuration directory is used for the pre-install process probe.
  The process must report the exact adapter/Pi versions, API contract, ACP session
  capabilities, all supported PiWork capabilities, and successfully answer
  settings and model-catalog requests. Its bundled Bun must also start within
  a bounded timeout. Provider credentials and existing project configuration are
  not used by this probe.
- Version folders are immutable. `selection.json` is replaced atomically. A trial
  marker is written before first activation and cleared after the real startup
  handshake and settings check. An interrupted trial, failed startup, changed
  executable/resource, or unexpected runtime exit selects the previous verified
  runtime, ultimately falling back to the bundled runtime. A read-only or damaged
  runtime store also leaves the bundled host usable.
- A corrupted inactive cache can be replaced with a fully verified copy of the
  same release, so a failed candidate can be retried. The running runtime and
  its rollback copy are never overwritten by installation.
- Existing service restart events reload session projections. Interrupted prompts
  fail through the existing disconnect path; tool actions are never replayed by
  the updater. Rollback changes the runtime selection, not completed user work.

The release repository over HTTPS is the publisher trust root. SHA-256 detects
corruption; the current ad-hoc code signature checks executable integrity and is
not a Developer ID attestation. No application-bundle files are rewritten.

## Publish a runtime without an app release

1. Adapt `AgentHost` to the intended upstream Pi SDK. Keep its three Pi dependencies
   aligned, update `bun.lock`, and run type checking and adapter tests. This does
   not require changing the app marketing version.
2. Bump `AgentHost/package.json` → `piWorkRuntime.version`. Set honest app/macOS
   compatibility bounds. Bump the runtime API contract for incompatible changes;
   existing apps will reject that API until they implement it. Preserve on-disk
   session/settings compatibility with rollback versions.
3. Push a matching tag, for example `runtime-v1.0.1`. The dedicated workflow tests
   both native architectures, builds/packages the hosts, verifies signatures, and
   runs a real process smoke test on each package before publishing.
4. Immutable assets live on `runtime-vVERSION` releases. The stable channel is
   `agent-runtime-stable/runtime-index.json`; publishing merges compatibility
   history. Runtime releases use `--latest=false`, so app update checks continue
   to use the latest ordinary app release.

The channel must be published once before online runtime checks can succeed. No
upstream latest-version endpoint or terminal installation is used as a substitute.

Local verification (requires macOS Command Line Tools and the existing pinned Bun):

```sh
python3 -m unittest scripts/test_agent_runtime_package.py scripts/test_release_workflow.py
bash scripts/test-agent-runtime.sh
python3 scripts/package-agent-runtime.py --architecture arm64 --output build/AgentRuntime
bash scripts/test-agent-runtime.sh build/AgentRuntime/runtime-arm64.json
```

Use `--architecture x86_64` on Intel. The runtime checks use production Swift
sources and do not require an XCTest host app. The normal Xcode application/test
build remains the check for app-bundle integration and UI behavior.
