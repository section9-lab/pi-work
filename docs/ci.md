# macOS release CI

The release workflow still tests and packages both native architectures. Dependency caching does not reuse Debug/Release object files, remove Intel tests, or bypass signature and packaged-image checks.

## Dependency caches

`.github/actions/prepare-macos-dependencies` prepares two caches:

- Swift package checkouts and binary artifacts in `$RUNNER_TEMP/PiWorkSourcePackages`. The key includes runner OS, architecture, the selected Xcode version/build, and `ci/Package.resolved`.
- Sparkle signing tools in `build/Sparkle-2.10.1`. The key includes runner OS, architecture, and the download script, which pins and verifies the upstream archive checksum.

Tests and the Release archive both use the shared Swift package directory from independent matrix jobs. Their compiled products remain in separate, disposable DerivedData directories. Cache keys intentionally exclude the app version, tag and source commit so normal app releases can reuse unchanged dependencies. An exact cache hit only stages the committed lockfile; the explicit package-resolution pass runs on cache misses, while both Xcode commands still enforce the pinned lockfile.

### Why a separate warm-up workflow exists

GitHub caches created on one tag are not available to a different tag. Tag workflows can, however, restore caches from the repository's default branch.

`Cache macOS dependencies` therefore warms both architectures on `main` when dependency/project/cache configuration changes. It can also be dispatched manually on `main` after a cache expires. It neither builds the app nor publishes a release. The release workflow does not depend on warm-up succeeding: a cache miss downloads and resolves the pinned dependencies normally.

For the first optimized release, let the main-branch warm-up finish before pushing the release tag. Later runs report exact cache hits in the Actions job summary. A cold cache is expected to be slower than a warm cache; only real release runs can establish the net speedup.

## Updating Swift dependencies

`ci/Package.resolved` is the committed lockfile because XcodeGen's generated `.xcodeproj` is ignored by Git.

When changing a dependency in `project.yml`:

1. Generate the project with `xcodegen generate`.
2. Resolve the intended dependency changes with Xcode, without the release workflow's strict resolution flags.
3. Review and copy `pi-work.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` into `ci/Package.resolved`.
4. Commit the project and lockfile together. CI rejects implicit changes to pinned identities, locations or revisions.

Run the CI configuration and preparation-script regression checks locally:

```sh
python3 -m unittest scripts/test_release_workflow.py scripts/test_ci_dependencies.py
```

The preparation-script checks use a fake `xcodebuild` to verify shared paths, strict resolution, lockfile drift rejection and exit-code propagation; they do not replace an actual Xcode release run.

## Release job layout and diagnostics

Architecture-independent validation runs once on the faster ARM runner: Agent Host type-checking, Bun tests, packaging checks, app-update checks, project-change checks and runtime-recovery checks remain individually timed. Native XCTest and Release packaging each retain ARM64 and Intel matrix coverage.

The test and package matrices run independently, so Debug XCTest compilation no longer blocks the unrelated Release archive. Publishing waits for validation plus every test and package matrix job. This keeps the same release gates while placing the two clean Xcode builds on parallel critical paths.

Both Xcode invocations enable `-showBuildTimingSummary`. Their complete stdout/stderr logs are uploaded, including on failure, and retained for seven days:

- `PiWorkTestDiagnostics-*` contains `application-tests.log`: dependency preparation/build, test execution and Xcode's build timing summary.
- `PiWorkBuildDiagnostics-*` contains `archive.log`: Release archive build and its timing summary.

The existing `PiWorkTests-*` XCTest result bundles remain available separately. Diagnostic artifacts do not match the release job's `PiWork-*` installer download pattern. Shell pipelines use `pipefail`, so capturing logs with `tee` cannot turn an Xcode failure into a successful release.
