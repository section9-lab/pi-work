# App updates

PiWork uses the pinned Sparkle 2.10.1 package for application updates on macOS 13
and later. Sparkle replaces the former GitHub API checker and browser download
flow. Pi Coding Agent is bundled and updated only with PiWork; it has no separate
update flow.

## User flow

- Check on launch and daily while running, respecting Sparkle's saved automatic
  check preference. Settings → General exposes this preference and manual checks.
- Show **Update** beside the account at the bottom of the sidebar when a new
  version is available. Keep manual checks in Software Update settings and the
  app menu. There is no main-window update banner or modal update offer.
- Clicking **Update** while idle authorizes download, signature verification,
  replacement, and normal macOS quit/relaunch. No second install click is needed
  unless a task starts before the update can safely restart.
- While any Chat, Work, or scheduled task is opening, submitting, running,
  awaiting approval, or stopping, Update and Restart clicks do nothing. Their
  hover/accessibility hint asks the user to finish all tasks and click again.
  Finishing tasks never starts a queued update or restart.
- If a task starts during download/preparation, keep the update prepared and show
  **Restart**. Check live task activity again before relaunching, including
  Sparkle's relaunch delegate and retry callback. Use the scheduler's live runs,
  rather than persisted run history, so an old interrupted run cannot block updates.
- Show download/extraction progress. Downloads can be cancelled before extraction;
  failed checks and downloads can be retried. Show compact progress in the sidebar.
- Keep conversations and configuration in Application Support. The agent runtime
  stays inside the app bundle and is replaced with the app.
  Sparkle manages replacement and installation recovery; the Host handles normal
  stdin EOF when the application quits.

The first version containing this updater must be installed manually by users
of earlier releases. Subsequent updates use the in-app flow.

## Release integration

The app loads `appcast-arm64.xml` or `appcast-x86_64.xml` from the latest GitHub
Release. CI signs the final DMG and its architecture-specific feed with Ed25519.
Both feeds and DMGs are uploaded before the Release becomes public. The minimum
system version in each feed is 13.0.0. `CFBundleVersion` follows
`MARKETING_VERSION`, so Sparkle can compare successive app releases.

`SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction` are enabled. The app
contains the public key; the private seed is the repository's
`SPARKLE_ED25519_PRIVATE_KEY` Actions Secret. An owner backup is kept under
`~/Library/Application Support/pi-work-release-signing/` with directory mode
0700 and key mode 0600. Keep this key backed up; never commit or log it.

`scripts/fetch-sparkle-tools.sh` verifies the official distribution checksum.
`scripts/generate-appcast.py` signs both archive and feed and rejects missing
keys, mismatched filenames, and invalid versions. No separate hosting service
or GitHub API credentials are needed by the app.

## Verification

```sh
bash scripts/fetch-sparkle-tools.sh
python3 -m unittest scripts/test_appcast.py scripts/test_release_workflow.py
bash scripts/test-app-updates.sh
bash scripts/test-native.sh
```

The standalone checks cover consent, cancellation, download progress, error
retention, architecture routing, active-task guards, and explicit restart after
tasks finish. They render six-language light/dark account rows at sidebar widths
220/260/420 points. XCTest adds controller tests in the existing application
test target. Full XCTest requires Xcode.

For a real local installation test:

```sh
bash scripts/build-app-update-preview.sh
python3 -m http.server 8769 --bind 127.0.0.1 --directory build/app-update-qa/public
open ~/Library/Caches/pi-work/AppUpdateQA/PiWorkUpdateQA.app
```

This fixture uses its own bundle identifier, disposable signing seed, local
feed, and writable app directory. On macOS 26.6, one click upgraded 1.0.0 to
1.0.1 and relaunched the new version. Flipping one byte in the signed DMG was
rejected before extraction while 1.0.0 stayed running; restoring the original
DMG and retrying upgraded and relaunched successfully. The installed PiWork
application and user conversations were not involved in these checks.

The fixture's **Task running** toggle also exercises the production task gate:
clicking Update while busy does not download anything, clearing the toggle does
not queue an upgrade, and a task started during a throttled download leaves 1.0.0
running with Restart visible. Restart is inert while busy; after clearing the
toggle, only another explicit click installs and relaunches 1.0.1.
